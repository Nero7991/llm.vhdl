#!/usr/bin/env python3
"""Offline weight packer for subsystem A.

Reads a tensor from a GGUF file, requantizes it to subsystem A's INT4 format,
and emits the packed file that ref/matvec_int4.c parses and the RTL streams.

Implements exactly:
  docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md
  6.1 quantization, 6.4 file layout, 6.5 / 6.5a bit ordering (NORMATIVE),
  14.1 generics

The format, for reference:

    w[r][k] = codebook[idx[r][k]] * (scale[r][b] / 2^15) * 2^-w_exp

  idx    : 4-bit index into a 16-entry int8 codebook, default IQ4_NL
  scale  : uint15 (0..32767), Q15, one per BLOCK=32 weights within a row
  w_exp  : one signed integer per matrix, carried in the header

Usage:
  pack_int4.py MODEL.gguf TENSOR_NAME OUT.mv4i [--rows-if 4] [--verify]
  pack_int4.py --list MODEL.gguf

GEOMETRY (2026-08-27).  The port count is DERIVED from the invariant, not
assumed.  Spec 6.5:

    NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4

This file used to set `nports = rows_if`, which is that identity evaluated at
BLOCK=32 and AXI_DW=128 and true nowhere else.  It made `--rows-if 80` emit a
plausible 80-sub-region file that no design can consume -- not an error, a
WRONG FILE.  AXI_DW is now an explicit input, the port count falls out of it,
the value is recorded in the header at 0x1E so a consumer can check rather than
infer, and geometries nothing implements are REFUSED.  See check_geometry().

GENERAL LAYOUT (2026-08-28, spec 6.5a).  The byte layout used to be pinned at
AXI_DW=128, where one AXI lane is exactly one row's BLOCK*4 = 128-bit chunk.
That is the "ROWS_IF=4 coincidence" 6.5 calls load-bearing, and it does not hold
on the FK33, whose HBM SAXI ports are 256 bits and where one lane spans two
rows.  6.5a states the general rule and this file emits it:

  * the TILE WORD for (tile t, block b) is ROWS_IF*BLOCK*4 bits with row r of
    the tile at bits (r+1)*BLOCK*4-1 downto r*BLOCK*4, row 0 at the LSB;
  * weight sub-region p carries bit slice p of every tile word, t-major then b;
  * n_scale_sub = lcm(ROWS_IF*16, AXI_DW) / AXI_DW, the SCALE SUPERWORD is
    n_scale_sub*AXI_DW bits and holds GRP = n_scale_sub*AXI_DW/(ROWS_IF*16)
    consecutive scale groups, and scale sub-region q carries bit slice q of it.

At ROWS_IF=4, AXI_DW=128 slice p IS row p and n_scale_sub is 1, so this
generalises the old code rather than changing it: repacking the {1,2,4,8} x 128
set produces BYTE-IDENTICAL files (checked, see docs/debugging/).
"""

import argparse
import math
import struct
import sys
import os

import numpy as np

# gguf-py from the local llama.cpp checkout
for _p in ("/mnt/storage/llama-dflash2-src/gguf-py",
           os.path.expanduser("~/GitHub/llama.cpp.upstream/gguf-py")):
    if os.path.isdir(_p):
        sys.path.insert(0, _p)
        break
from gguf.gguf_reader import GGUFReader          # noqa: E402
from gguf import quants                          # noqa: E402

# ------------------------------------------------------------------ constants

MAGIC       = 0x4D563449          # "MV4I"
VERSION     = 1
BLOCK       = 32                  # spec 6.1
HDR_BYTES   = 4096                # spec 6.4
AXI_DW_DEF  = 128                 # bits, per AXI master; AXU3EG HP port width
OUT_SHIFT_MAX = 40                # spec 7.4


class GeometryError(ValueError):
    """A (ROWS_IF, BLOCK, AXI_DW) triple this repository cannot pack."""


AXI4_WIDTHS = (8, 16, 32, 64, 128, 256, 512, 1024)   # AXI4 legal data widths


def n_scale_sub(rows_if: int, axi_dw: int) -> int:
    """Scale sub-region count, spec 6.5a: lcm(ROWS_IF*16, AXI_DW) / AXI_DW.

    Equivalently the SMALLEST n >= 1 for which n whole beats hold a whole
    number of scale groups.  Minimality is not cosmetic: a larger n that also
    divides describes a DIFFERENT file, so packer and RTL have to agree on
    which one, and "the smallest" is the only choice that needs no extra field.

    n = 1 whenever the group fits a beat (ROWS_IF*16 <= AXI_DW and divides),
    which is every AXU3EG geometry, so this is a generalisation and not a
    change.
    """
    sw = rows_if * 16
    return math.lcm(sw, axi_dw) // axi_dw


def scale_groups_per_super(rows_if: int, axi_dw: int) -> int:
    """GRP of spec 6.5a: scale groups carried by one superword."""
    return n_scale_sub(rows_if, axi_dw) * axi_dw // (rows_if * 16)


def check_geometry(rows_if: int, axi_dw: int, emitting: bool = True) -> int:
    """Return NPORTS_W for this geometry, or raise GeometryError.

    THE POINT OF THIS FUNCTION is to refuse rather than to guess.  It used to
    refuse three things.  Spec 6.5a (2026-08-28) settled two of them -- the
    byte layout at AXI_DW != 128, and n_scale_sub > 1 -- so those are now
    IMPLEMENTED rather than refused, and this file emits them.  What is left is
    the set that is still genuinely undefined:

    1. The 6.5 invariant must divide.  NPORTS_W is a count of AXI masters; a
       fractional one is not a smaller design, it is no design.  ARITHMETIC,
       always applies, so --audit cannot waive it either: a geometry with no
       port count has no size worth reporting.

    2. AXI_DW must be an AXI4 data width.  6.5a's slice rule is happy with any
       multiple of 8, but axi_rd_port derives ARSIZE as clog2(AXI_DW/8) and
       AXI4 defines no other width, so a 96-bit "port" is a file for a bus that
       cannot exist.  Also arithmetic, also unwaivable.

    3. The sub-region offset table must fit the 4 KB header.  It starts at 0x38
       and carries NPORTS_W + n_scale_sub u64 entries (6.4).  This one IS
       waived by emitting=False: the byte count is still well defined, only the
       FILE is not, which is exactly the distinction --audit wants.

    Use unmet_reasons() to ask what a geometry violates without catching an
    exception.

    DELIBERATELY NOT REFUSED: a master count larger than the target board has
    ports.  That is a property of the board, not of the format, and the packer
    has no business knowing it -- the emit path PRINTS the master count so the
    caller can check it against spec 13's 30 usable HBM ports.
    """
    lane_bits = rows_if * BLOCK * 4
    if axi_dw <= 0 or lane_bits % axi_dw:
        raise GeometryError(
            f"6.5 invariant does not divide: ROWS_IF*BLOCK*4 = {lane_bits} bits "
            f"is not a whole number of {axi_dw}-bit ports "
            f"(ROWS_IF={rows_if}, BLOCK={BLOCK})")
    if axi_dw not in AXI4_WIDTHS:
        raise GeometryError(
            f"AXI_DW={axi_dw} is not an AXI4 data width "
            f"({', '.join(str(w) for w in AXI4_WIDTHS)})")
    nports = lane_bits // axi_dw

    if emitting:
        why = unmet_reasons(rows_if, axi_dw)
        if why:
            raise GeometryError(" ".join(why))

    return nports


def unmet_reasons(rows_if: int, axi_dw: int):
    """Which emit-path limits this geometry runs into, as prose.

    Separate from check_geometry so --audit can REPORT them next to the sizes
    instead of refusing, and so the emit path can list all of them at once
    rather than whichever happens to be tested first.

    Only rule 3 lives here now.  Rules 1 and 2 are arithmetic and raise from
    check_geometry on both paths; the byte-layout and single-scale-sub-region
    refusals that used to live here were closed by spec 6.5a and are gone.
    """
    out = []
    if axi_dw <= 0 or axi_dw not in AXI4_WIDTHS or (rows_if * BLOCK * 4) % axi_dw:
        return out                      # check_geometry raises on these first
    nports = rows_if * BLOCK * 4 // axi_dw
    nss = n_scale_sub(rows_if, axi_dw)
    need = 0x38 + 8 * (nports + nss)
    if need > HDR_BYTES:
        out.append(
            f"The sub-region offset table does not fit the 4 KB header: "
            f"NPORTS_W={nports} plus n_scale_sub={nss} is {nports + nss} u64 "
            f"entries from 0x38, ending at {need} bytes against "
            f"{HDR_BYTES} (spec 6.4). Widening the header is a format change, "
            f"not a packer change.")
    return out

# spec 6.1 default codebook.  MUST NOT contain -128 (spec 7.4): with cb=-128 and
# x_mant=-32768 a 32-term block partial reaches exactly 2^27 and overflows s28
# by one.  IQ4_NL's minimum is -127, so the constraint costs nothing.
IQ4_NL = np.array([-127, -104, -83, -65, -49, -35, -22, -10,
                      1,   13,  25,  38,  53,  69,  89, 113], dtype=np.int8)


def align4k(n: int) -> int:
    return (n + 4095) & ~4095


def _wrap(text: str, width: int):
    out, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            out.append(line); line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        out.append(line)
    return out


# ------------------------------------------------------------------ GGUF input

def read_tensor(path: str, name: str) -> np.ndarray:
    """Dequantize one GGUF tensor to float32, shaped (M, K) row-major.

    GGUF stores shape as (ne0, ne1) with ne0 the fastest axis.  For a weight
    matrix, ne0 is the INPUT dim (K) and ne1 the OUTPUT dim (M), so y = W . x
    consumes rows of length K.  This returns (M, K).
    """
    rd = GGUFReader(path, "r")
    for t in rd.tensors:
        if t.name == name:
            return tensor_as_mk(t)
    raise KeyError(f"tensor {name!r} not in {path}")


def tensor_as_mk(t) -> np.ndarray:
    """The same thing for an ALREADY-OPEN GGUF tensor object.

    A model-wide packer opens the file once and walks `rd.tensors`; re-opening
    a GGUFReader per tensor re-parses the whole metadata block, which is
    seconds each and minutes over 250 tensors.  read_tensor() is now a thin
    lookup in front of this so both paths cannot drift on the (M, K)
    convention, which is the part that is easy to get backwards.
    """
    raw = t.data
    qt = t.tensor_type
    # copy=False on both paths.  Nothing downstream mutates W, and on
    # token_embd / output (1.017e9 weights) the defensive copy is a 4 GB
    # transient on top of the 4 GB result, which is the difference between
    # a job that runs beside a Vivado build and one that OOMs the box.
    if str(qt).endswith("F32"):
        flat = raw.astype(np.float32, copy=False)
    else:
        flat = quants.dequantize(raw, qt).astype(np.float32, copy=False)
    ne = [int(x) for x in t.shape]
    K, M = ne[0], (ne[1] if len(ne) > 1 else 1)
    return flat.reshape(M, K)


def is_matvec(name: str, ne) -> bool:
    """Does subsystem A pack this tensor, or does it stay F32?

    SINGLE AUTHORITY for the split, the way packed_layout() is the single
    authority for the size.  --audit reports totals from this and the model
    packer emits from it, so a packed set and its audit cannot classify a
    tensor differently -- which is the only way the two can ever disagree
    about how big the model is.

    A handles 2D matvec weights.  Norms, biases, ssm_a and the 4-tap conv1d
    are 1D or tiny and stay in their native form.

    `ne` is the GGUF shape, ne0-fastest, i.e. ne[0] = K and ne[1] = M.
    """
    ne = [int(v) for v in ne]
    K = ne[0]
    M = ne[1] if len(ne) > 1 else 1
    return (len(ne) > 1 and M > 1 and K > 1
            and not name.endswith("ssm_conv1d.weight"))


def list_tensors(path: str) -> None:
    rd = GGUFReader(path, "r")
    for t in rd.tensors:
        shp = "x".join(str(int(v)) for v in t.shape)
        print(f"{t.name:44s} {str(t.tensor_type).split('.')[-1]:10s} {shp}")


# ------------------------------------------------------- quantization (spec 6.1)

def quantize(W: np.ndarray, cb: np.ndarray, row_chunk: int = 4096):
    """(M,K) float32 -> (idx uint8 (M,NB,32), scale uint16 (M,NB), w_exp int).

    w_exp is global and chosen so the largest weight maps near the codebook
    extreme; scale is per 32-weight block so small blocks keep their precision.

    The per-block scale is chosen by SEARCH, not by amax alone.  Setting the
    block extreme onto the codebook extreme is the obvious choice and it is
    measurably poor: IQ4_NL's spacing is non-uniform (gaps 11..24 in codebook
    units), so the amax-anchored scale leaves the bulk of a Gaussian block in
    the coarse region and costs ~10% relative error on a matvec.  Trying a
    spread of candidate scales and keeping the least-squares winner per block
    is what llama.cpp's quantize_row_iq4_nl_impl does, and it is cheap.
    """
    M, K = W.shape
    NB = (K + BLOCK - 1) // BLOCK

    cbf = cb.astype(np.float32)
    cb_amax = float(np.abs(cbf).max())                   # 127 for IQ4_NL
    mids = (cbf[:-1] + cbf[1:]) * 0.5

    gmax = float(np.abs(W).max())
    if gmax == 0.0:
        return (np.zeros((M, NB, BLOCK), np.uint8),
                np.zeros((M, NB), np.uint16), 0)

    # target = w * 2^w_exp must satisfy |target| <= cb_amax, since the largest
    # representable magnitude is cb_amax * scale/2^15 and scale/2^15 < 1.
    w_exp = int(math.floor(math.log2(cb_amax / gmax)))

    # candidate multipliers on the amax-anchored scale
    mults = np.array([0.80, 0.86, 0.90, 0.94, 0.97, 1.00, 1.03, 1.07],
                     dtype=np.float32)

    idx_out = np.zeros((M, NB, BLOCK), dtype=np.uint8)
    scl_out = np.zeros((M, NB), dtype=np.uint16)

    # spec 6.4 pins pad fill to 0x00, and the least-squares search must not be
    # biased by padding.  Zero-padded targets quantize to searchsorted(mids,0)=8
    # (codebook value 1, nibble 0x8), not 0 -- so without this the packer emits
    # 0x88 bytes in the final block of any K % 32 != 0 tensor, defeating the
    # byte-identical-files property 6.4 exists to provide, and the pad terms
    # skew the scale chosen for the real weights sharing that block.
    valid = np.ones((NB, BLOCK), dtype=np.float32)
    valid.reshape(-1)[K:] = 0.0
    pad3 = np.broadcast_to((valid == 0.0)[None, :, :], (1, NB, BLOCK))

    for r0 in range(0, M, row_chunk):                    # bound peak memory
        r1 = min(M, r0 + row_chunk)
        Wp = np.zeros((r1 - r0, NB * BLOCK), dtype=np.float32)  # PAD FILL = 0
        Wp[:, :K] = W[r0:r1]
        tgt = Wp.reshape(r1 - r0, NB, BLOCK) * np.float32(2.0 ** w_exp)

        amax = (np.abs(tgt) * valid[None]).max(axis=2)   # (rows, NB), pads excluded
        base = amax * np.float32(32768.0 / cb_amax)

        best_err = np.full(amax.shape, np.inf, dtype=np.float32)
        best_scl = np.zeros(amax.shape, dtype=np.uint16)
        best_idx = np.zeros(tgt.shape, dtype=np.uint8)

        for m in mults:
            sc = np.clip(np.rint(base * m), 0, 32767).astype(np.uint16)
            s = sc.astype(np.float32) / np.float32(32768.0)
            s_safe = np.where(s > 0.0, s, np.float32(1.0))[:, :, None]
            q = tgt / s_safe
            ix = np.searchsorted(mids, q).astype(np.uint8)
            err = (((cbf[ix] * s_safe - tgt) ** 2) * valid[None]).sum(axis=2)
            win = err < best_err
            best_err = np.where(win, err, best_err)
            best_scl = np.where(win, sc, best_scl)
            w3 = np.broadcast_to(win[:, :, None], ix.shape)
            best_idx = np.where(w3, ix, best_idx)

        best_idx[np.broadcast_to((best_scl == 0)[:, :, None], best_idx.shape)] = 0
        best_idx[np.broadcast_to(pad3, best_idx.shape)] = 0      # 6.4 pad fill
        idx_out[r0:r1] = best_idx
        scl_out[r0:r1] = best_scl

    return idx_out, scl_out, w_exp


def segment_row_plan(seg_rows, rows_if: int):
    """Pad each row SEGMENT up to a whole number of ROWS_IF tiles.

    WHY THIS EXISTS.  A fused tensor whose rows are several logically separate
    matrices -- the GDN block's `attn_qkv`, which is q | k | v -- is issued as
    one matvec JOB PER SEGMENT, so that each segment gets its own BFP block
    exponent (`seq_opdec` infers the exponent segment from `dst_offset`).  A
    job that does not start at row 0 is a ROW WINDOW, and a window can only
    begin on a TILE boundary, because a sub-region's beats run tile-major and
    the window is expressed by advancing every base by whole tiles
    (`tools/gen_mv4i_desc.py:build_descriptor`).  At the 9B shape the segments
    are 2048 | 2048 | 4096 and ROWS_IF is 48:

        2048 mod 48 = 32     4096 mod 48 = 16

    so neither of the last two segments starts on a tile boundary and neither
    window is expressible.  Padding each segment up to the next multiple of
    ROWS_IF moves the starts to 0, 2064 and 4128, all multiples of 48.

    WHAT THE PAD ROWS CONTAIN: nothing.  They are zero rows, which `quantize`
    turns into scale = 0 and idx = 0 -- the same bytes `pack` already writes
    for the trailing tile padding of any M not divisible by ROWS_IF.  They are
    numerically inert twice over: a pad row sits at an index >= the job's
    `n_rows`, and BOTH the reference (`ref/matvec_int4.c`, "SCAN DOMAIN is
    r < n_rows ONLY") and the gateware (`rtl/matvec_core.vhd`, the `re3_ok`
    mask on the amax fold) exclude such a row from the BFP amax scan and from
    the emitted result.  And even if some future consumer did fold them in, a
    magnitude of zero cannot change a MAX, so the shared exponent is unmoved in
    either direction.  There is no per-tile shared exponent in this format --
    `scale` is per row per BLOCK of 32 and `w_exp` is per matrix -- so a tile
    of mostly zeros has nothing to shift.

    `seg_rows` is the LOGICAL segment lengths, in order.  Returns
    (m_padded, plan) where plan is one dict per segment with `row_start` (in
    the padded matrix), `n_rows` (the logical length, unchanged), `pad` and
    `src_start` (in the unpadded matrix).  The LAST segment is NOT padded here:
    nothing follows it, and `pack` already rounds the file up to a whole tile.
    """
    if rows_if <= 0:
        raise ValueError("rows_if must be positive")
    if not seg_rows or any(int(n) <= 0 for n in seg_rows):
        raise ValueError("seg_rows must be a non-empty list of positive ints")
    plan = []
    dst = src = 0
    last = len(seg_rows) - 1
    for i, n in enumerate(seg_rows):
        n = int(n)
        pad = 0 if i == last else (-n) % rows_if
        plan.append(dict(index=i, src_start=src, row_start=dst,
                         n_rows=n, pad=pad))
        dst += n + pad
        src += n
    return dst, plan


def apply_segment_padding(W: np.ndarray, m_padded: int, plan):
    """Insert the pad rows of `segment_row_plan` into an (M, K) float array.

    The pad rows are left at 0.0.  `quantize` maps an all-zero row to scale 0
    and idx 0 (its `best_scl == 0` branch), which is the exact byte pattern
    `pack` already writes for trailing tile padding, so the padded file and the
    unpadded one agree byte-for-byte wherever a real row lands.
    """
    if W.shape[0] != sum(p["n_rows"] for p in plan):
        raise ValueError("segment plan covers %d rows, tensor has %d"
                         % (sum(p["n_rows"] for p in plan), W.shape[0]))
    out = np.zeros((m_padded, W.shape[1]), dtype=W.dtype)
    for p in plan:
        out[p["row_start"]:p["row_start"] + p["n_rows"]] = \
            W[p["src_start"]:p["src_start"] + p["n_rows"]]
    return out


def calibrate_out_shift(K: int) -> int:
    """spec 7.4: pick out_shift so sat32 cannot fire on the worst-case acc.

    |contrib| < 2^27 per block and NB blocks, so |acc| < NB * 2^27.  We need
    |acc| >> out_shift <= 2^31.  This is the SAFE bound with no activation
    calibration; BFP normalization (ns) recovers the dynamic range afterwards,
    so being conservative here costs headroom rather than accuracy.
    """
    NB = (K + BLOCK - 1) // BLOCK
    bits = 27 + math.ceil(math.log2(NB)) if NB > 1 else 27
    return max(0, min(OUT_SHIFT_MAX, bits - 31))


# ---------------------------------------------------------- emission (6.4/6.5)

def packed_layout(M: int, K: int, rows_if: int,
                  axi_dw: int = AXI_DW_DEF, emitting: bool = True):
    """The 6.4/6.5 file layout, as pure arithmetic on the shape.

    SINGLE AUTHORITY for how large a packed tensor is.  pack() below emits it
    and --audit sums it across a whole model; neither re-derives it, because a
    second copy of this arithmetic is exactly the drift this project keeps
    getting bitten by.

    Per-sub-region size is `tiles * NB * (axi_dw/8)`, i.e. the bytes ONE PORT
    supplies of each consumed word.  At AXI_DW=128 that is the old
    `BLOCK//2 = 16`, so this generalises rather than changes the AXU3EG
    numbers; the assertion in pack() checks that it still divides exactly.

    The SCALE region is now n_scale_sub equally sized sub-regions (6.5a), each
    one beat wide, and is rounded up to a whole SUPERWORD rather than to a
    whole group.  At AXI_DW=128 that rounding is invisible: n_scale_sub is 1,
    the superword is one beat, and the old formula
    `align4k(tiles*NB*ROWS_IF*2)` already rounded past it to 4 KB.  It is only
    written this way because the RTL pops whole superwords, so a file whose
    last one is short would starve the scale stream on the final tile.

    Returns (NB, tiles, nports, sub_sz, nss, scl_sub_sz, total).
    """
    nports = check_geometry(rows_if, axi_dw, emitting=emitting)
    NB     = (K + BLOCK - 1) // BLOCK      # 6.3 ceil, K padded to a whole block
    tiles  = (M + rows_if - 1) // rows_if
    port_b = axi_dw // 8                   # bytes of each word this port holds
    sub_sz = align4k(tiles * NB * port_b)

    nss    = n_scale_sub(rows_if, axi_dw)
    grp    = scale_groups_per_super(rows_if, axi_dw)
    nsuper = (tiles * NB + grp - 1) // grp
    scl_sub_sz = align4k(nsuper * port_b)

    total  = HDR_BYTES + sub_sz * nports + scl_sub_sz * nss
    return NB, tiles, nports, sub_sz, nss, scl_sub_sz, total


def pack(idx, scale, w_exp, M, K, rows_if, out_shift, cb,
         axi_dw: int = AXI_DW_DEF) -> bytes:
    """Emit the 6.4 file with the 6.5a byte layout.  See the module docstring.

    Written as slicing on ONE tile-word array rather than as a per-row loop,
    because the general rule IS a slice: the word is the rows concatenated with
    row 0 at the LSB, and sub-region p is its p'th AXI_DW-wide piece.  The old
    per-row loop was that same slice evaluated where a piece happens to be a
    row, and it could not express the FK33 case where a piece is two rows.
    """
    NB, tiles, nports, sub_sz, nss, scl_sub_sz, total = \
        packed_layout(M, K, rows_if, axi_dw)
    assert NB == idx.shape[1], f"NB mismatch {NB} vs {idx.shape[1]}"

    port_b = axi_dw // 8                   # bytes per beat, per sub-region
    row_b  = BLOCK // 2                    # bytes of one row-chunk, 16 at BLK=32
    word_b = rows_if * row_b               # bytes of one tile word
    assert word_b == nports * port_b, "6.5a: the tile word must slice exactly"

    buf = bytearray(total)                 # zero-filled: PAD FILL = 0x00

    # ---- header, spec 6.4 byte-pinned layout, little-endian
    struct.pack_into("<IHHII", buf, 0x00, MAGIC, VERSION, 1, M, K)
    struct.pack_into("<ii",    buf, 0x10, w_exp, out_shift)
    # 0x1E was "reserved (0)" and now carries AXI_DW.  A reader that predates
    # this sees 0, which is the documented "legacy, assume 128" encoding, so no
    # existing file or parser is invalidated.
    struct.pack_into("<HHHH",  buf, 0x18, rows_if, nports, BLOCK, axi_dw)
    buf[0x20:0x30] = cb.astype(np.int8).tobytes()
    scl_off = HDR_BYTES + sub_sz * nports
    # 0x34 is n_scale_sub.  It was hardcoded to 1, which was true of every
    # geometry the old packer would emit and is false at ROWS_IF=48/AXI_DW=256.
    struct.pack_into("<II", buf, 0x30, scl_off, nss)
    assert 0x38 + 8 * (nports + nss) <= HDR_BYTES   # checked by unmet_reasons
    for p in range(nports):
        struct.pack_into("<Q", buf, 0x38 + 8 * p, HDR_BYTES + sub_sz * p)
    for q in range(nss):
        struct.pack_into("<Q", buf, 0x38 + 8 * (nports + q),
                         scl_off + scl_sub_sz * q)

    # ---- weights.  Nibble order: weight j even -> low nibble of byte j/2, odd
    # -> high.  Then the tile word is the ROWS_IF row-chunks concatenated with
    # row 0 at the LSB, i.e. at the LOWEST byte offset, and sub-region p is
    # bytes [p*port_b, (p+1)*port_b) of it.
    idx_pad = np.zeros((tiles * rows_if, NB, BLOCK), dtype=np.uint8)
    idx_pad[:M] = idx
    lanes = idx_pad.reshape(tiles, rows_if, NB, BLOCK)          # (t, rr, b, j)
    lo = lanes[:, :, :, 0::2]
    hi = lanes[:, :, :, 1::2]
    packed = (lo | (hi << 4)).astype(np.uint8)                  # (t, rr, b, 16)
    # (t, b, rr, row_b) -> the word, flattened rr-major so row 0 is at byte 0
    word = np.ascontiguousarray(packed.transpose(0, 2, 1, 3)) \
             .reshape(tiles, NB, nports, port_b)
    for p in range(nports):
        blob = np.ascontiguousarray(word[:, :, p, :]).tobytes()  # t-major, then b
        base = HDR_BYTES + sub_sz * p
        buf[base:base + len(blob)] = blob

    # ---- scales: groups of ROWS_IF uint16 LE in (t, b) order, packed into
    # superwords of nss beats, then sliced across the nss sub-regions.
    grp    = scale_groups_per_super(rows_if, axi_dw)
    nsuper = (tiles * NB + grp - 1) // grp
    scl_pad = np.zeros((tiles * rows_if, NB), dtype=np.uint16)
    scl_pad[:M] = scale
    s = scl_pad.reshape(tiles, rows_if, NB).transpose(0, 2, 1)  # (t, b, rr)
    gb = np.frombuffer(np.ascontiguousarray(s).astype("<u2").tobytes(),
                       dtype=np.uint8)
    flat = np.zeros(nsuper * nss * port_b, dtype=np.uint8)      # PAD FILL 0x00
    flat[:gb.size] = gb
    sup = flat.reshape(nsuper, nss, port_b)
    for q in range(nss):
        blob = np.ascontiguousarray(sup[:, q, :]).tobytes()
        base = scl_off + scl_sub_sz * q
        buf[base:base + len(blob)] = blob

    return bytes(buf)


# --------------------------------------------------------------- verification

def verify(W, idx, scale, w_exp, out_shift, cb, K, trials=4):
    """Reconstruct via the spec's integer path and compare to float32.

    This is the packer's own check that its output means what the spec says;
    ref/matvec_int4.c is the authority on the integer arithmetic itself.
    """
    M, NB = scale.shape
    cbf = cb.astype(np.float64)
    deq = cbf[idx] * (scale.astype(np.float64)[:, :, None] / 32768.0) * 2.0 ** (-w_exp)
    deq = deq.reshape(M, NB * BLOCK)[:, :K]

    err = deq - W
    den = float(np.abs(W).max())
    rms = float(np.sqrt((err ** 2).mean()) / np.sqrt((W.astype(np.float64) ** 2).mean()))
    print(f"  weight reconstruction: max {float(np.abs(err).max()):.3e} "
          f"({100.0 * float(np.abs(err).max()) / den:.2f}% of max|w|), "
          f"RMS {100.0 * rms:.2f}% relative")

    rng = np.random.default_rng(0)
    rms_acc, cos_acc = 0.0, 0.0
    for _ in range(trials):
        x = rng.standard_normal(K).astype(np.float64)
        ref = W.astype(np.float64) @ x
        got = deq @ x
        rms_acc += float(np.linalg.norm(got - ref) / (np.linalg.norm(ref) + 1e-30))
        cos_acc += float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got) + 1e-30))
    rms, cos = rms_acc / trials, cos_acc / trials
    # RMS relative error is the meaningful metric; a max-over-outputs ratio is
    # dominated by whichever output happens to be near zero and overstates the
    # damage.  Cosine similarity is what a transformer layer actually cares
    # about, since a uniform scale error is absorbed downstream by the norms.
    print(f"  matvec vs float32:     RMS rel {100.0 * rms:.2f}%, "
          f"cosine {cos:.6f}")
    return rms


# --------------------------------------------------------------- cross-check

def round_shift(v, sh):
    return (v + (1 << (sh - 1))) >> sh if sh > 0 else v


def crosscheck(path):
    """Recompute what ref/matvec_int4.c prints for the same file, independently.

    Agreement proves packer and reference interpret the 6.4/6.5 layout
    identically -- the packer -> C -> RTL bit-identity chain the spec requires.
    Python's >> on ints is already floor, which is what site 1 demands.
    """
    with open(path, "rb") as f:
        img = f.read()
    magic, ver, flags, M, K = struct.unpack_from("<IHHII", img, 0x00)
    assert magic == MAGIC, "bad magic"
    w_exp, out_shift = struct.unpack_from("<ii", img, 0x10)
    rows_if, nports, blk, axi_dw = struct.unpack_from("<HHHH", img, 0x18)
    if axi_dw == 0:
        axi_dw = AXI_DW_DEF            # legacy file, predates the field
    exp_nports = check_geometry(rows_if, axi_dw, emitting=True)
    assert nports == exp_nports, (
        f"header says NPORTS_W={nports}, the 6.5 invariant at ROWS_IF={rows_if} "
        f"BLOCK={blk} AXI_DW={axi_dw} gives {exp_nports}")
    _, nss_hdr = struct.unpack_from("<II", img, 0x30)
    nss = n_scale_sub(rows_if, axi_dw)
    assert nss_hdr == nss, (
        f"header says n_scale_sub={nss_hdr}, spec 6.5a at ROWS_IF={rows_if} "
        f"AXI_DW={axi_dw} gives {nss}")
    cb = np.frombuffer(img[0x20:0x30], dtype=np.int8).astype(np.int64)
    w_sub = [struct.unpack_from("<Q", img, 0x38 + 8 * p)[0] for p in range(nports)]
    s_sub = [struct.unpack_from("<Q", img, 0x38 + 8 * (nports + q))[0]
             for q in range(nss)]

    NB = (K + BLOCK - 1) // BLOCK
    tiles = (M + rows_if - 1) // rows_if

    st = 2463534242
    x = np.empty(K, dtype=np.int64)
    for k in range(K):
        st ^= (st << 13) & 0xFFFFFFFF; st &= 0xFFFFFFFF
        st ^= st >> 17
        st ^= (st << 5) & 0xFFFFFFFF; st &= 0xFFFFFFFF
        x[k] = (st % 20001) - 10000

    # Decode by INVERTING 6.5a rather than by re-implementing it: rebuild the
    # tile word from its nports slices, then read rows out of the word.  At
    # AXI_DW=128 a slice is a row and this reduces to the old per-row loop.
    port_b = axi_dw // 8
    row_b  = BLOCK // 2
    nbytes = tiles * NB * port_b
    word = np.zeros((tiles, NB, nports, port_b), dtype=np.uint8)
    for p in range(nports):
        word[:, :, p, :] = np.frombuffer(
            img[w_sub[p]:w_sub[p] + nbytes], dtype=np.uint8
        ).reshape(tiles, NB, port_b)
    word = word.reshape(tiles, NB, rows_if, row_b)          # (t, b, rr, bytes)

    grp    = scale_groups_per_super(rows_if, axi_dw)
    nsuper = (tiles * NB + grp - 1) // grp
    sup = np.zeros((nsuper, nss, port_b), dtype=np.uint8)
    for q in range(nss):
        sup[:, q, :] = np.frombuffer(
            img[s_sub[q]:s_sub[q] + nsuper * port_b], dtype=np.uint8
        ).reshape(nsuper, port_b)
    sc_all = sup.reshape(-1).view("<u2")[:tiles * NB * rows_if] \
                .reshape(tiles, NB, rows_if).astype(np.int64)

    idx = np.zeros((M, NB, BLOCK), dtype=np.int64)
    scale = np.zeros((M, NB), dtype=np.int64)
    for rr in range(rows_if):
        raw = word[:, :, rr, :].astype(np.int64)
        rows = np.arange(tiles) * rows_if + rr
        keep = rows < M
        idx[rows[keep], :, 0::2] = raw[keep] & 0x0F
        idx[rows[keep], :, 1::2] = raw[keep] >> 4
        scale[rows[keep]] = sc_all[keep, :, rr]

    xp = np.zeros(NB * BLOCK, dtype=np.int64); xp[:K] = x
    mask = (np.arange(NB * BLOCK).reshape(NB, BLOCK) < K).astype(np.int64)
    partial = (cb[idx] * (xp.reshape(NB, BLOCK) * mask)).sum(axis=2)
    contrib = (partial * scale) >> 15
    acc = contrib.sum(axis=1)

    raw = np.array([round_shift(int(v), out_shift) for v in acc], dtype=object)
    sat = int(any(v > 2**31 - 1 or v < -2**31 for v in raw))
    y = np.array([min(max(int(v), -2**31), 2**31 - 1) for v in raw], dtype=np.int64)
    amax = int(np.abs(y).max())
    nsh = max(0, (amax.bit_length() - 1 if amax else 0) - 14)
    mant = np.clip(np.array([round_shift(int(v), nsh) for v in y]), -32768, 32767)
    print(f"M={M} K={K} w_exp={w_exp} out_shift={out_shift} ns={nsh} "
          f"y_exp={w_exp - out_shift - nsh} mant_sum={int(mant.sum())} sat={sat}")


# ---------------------------------------------------------------------- main

# --------------------------------------------------------------- model audit

def audit(path: str, rows_if: int, cards: int,
          axi_dw: int = AXI_DW_DEF) -> None:
    """Sum the packed size of a whole GGUF in this format, exactly.

    WHY: the v3.0 "27B fits 2 x FK33" claim came from 26.896e9 params x 4.5 bpw,
    which counts only the payload.  The real file carries a 4 KB header per
    tensor, 4 KB alignment on every one of ROWS_IF weight sub-regions plus the
    scale region, and K padded up to a whole block.  At ROWS_IF=80 that is 81
    separately-aligned regions per tensor, so the overhead is not negligible and
    it grows when a tensor is sharded.  This measures it instead of assuming it.

    Sizes come from packed_layout(), the same function pack() emits with, so an
    audit can never disagree with a file.
    """
    # --audit writes no bytes, so the byte-layout rule is relaxed here -- but
    # only that one.  A geometry whose port count does not divide, or whose
    # scale region does not fit, has no size worth reporting.
    nports = check_geometry(rows_if, axi_dw, emitting=False)
    emit_why = unmet_reasons(rows_if, axi_dw)

    rd = GGUFReader(path, "r")
    GIB = 1024.0 ** 3

    rows = []
    for t in rd.tensors:
        ne = [int(v) for v in t.shape]
        K = ne[0]
        M = ne[1] if len(ne) > 1 else 1
        params = M * K
        name = t.name
        is_mv = is_matvec(name, ne)
        if is_mv:
            whole = packed_layout(M, K, rows_if, axi_dw, emitting=False)[-1]
            # column-parallel: each card holds ceil(M/cards) rows, padded and
            # aligned on its own, so shard overhead does NOT divide by cards
            Ms = (M + cards - 1) // cards
            shard = packed_layout(Ms, K, rows_if, axi_dw, emitting=False)[-1]
        else:
            whole = params * 4          # kept as F32
            shard = whole               # replicated on every card
        rows.append((name, M, K, params, is_mv, whole, shard))

    mv   = [r for r in rows if r[4]]
    nonmv = [r for r in rows if not r[4]]
    p_mv  = sum(r[3] for r in mv)
    p_all = sum(r[3] for r in rows)
    s_whole = sum(r[5] for r in rows)
    s_shard = sum(r[6] for r in rows)
    payload = p_mv * 4.5 / 8.0

    nss = n_scale_sub(rows_if, axi_dw)
    print(f"model      {path}")
    print(f"ROWS_IF={rows_if}  AXI_DW={axi_dw}  NPORTS_W={nports}  "
          f"n_scale_sub={nss}  masters={nports + nss}  "
          f"cards={cards}  (column-parallel, M split)")
    if emit_why:
        print()
        print("  *** SIZES ONLY -- this geometry CANNOT BE PACKED ***")
        for why in emit_why:
            for i, line in enumerate(_wrap(why, 72)):
                print(f"      {'- ' if i == 0 else '  '}{line}")
    print()
    print(f"  tensors                     {len(rows):>10d}  "
          f"({len(mv)} matvec, {len(nonmv)} kept F32)")
    print(f"  params total                {p_all/1e9:>10.3f} B")
    print(f"  params in matvec weights    {p_mv/1e9:>10.3f} B")
    print()
    print(f"  payload only @ 4.5 bpw      {payload/GIB:>10.3f} GiB   "
          f"<- the figure the plan assumed")
    print(f"  packed, whole model         {s_whole/GIB:>10.3f} GiB   "
          f"({s_whole*8.0/p_mv:.3f} bits/matvec-weight)")
    print(f"  format overhead             {(s_whole-payload)/GIB:>10.3f} GiB   "
          f"({100.0*(s_whole-payload)/payload:+.1f}%)")
    print()
    print(f"  per card, ideal split       {s_whole/cards/GIB:>10.3f} GiB")
    print(f"  per card, real shards       {s_shard/GIB:>10.3f} GiB")
    print(f"  shard penalty               {(s_shard-s_whole/cards)/GIB:>10.3f} GiB")
    print()
    hbm = 8.0
    print(f"  FK33 HBM per card                 {hbm:.3f} GiB")
    print(f"  utilisation                 {100.0*s_shard/GIB/hbm:>10.1f} %"
          f"   {'FITS' if s_shard/GIB <= hbm else 'DOES NOT FIT'}")
    print()

    # ---- what is LEFT.  Weights are not the whole residency: subsystem B's
    # recurrent state is persistent, and the KV cache grows with context.  A
    # weights-only fit is not a fit.
    #
    # THE SIX NUMBERS THAT USED TO BE HERE WERE A DIFFERENT MODEL'S.
    # Until 2026-08-29 this block restated `n_gdn, n_attn = 48, 16` and
    # `d_inner, state_size = 6144, 128` as literals.  48 and 16 are the
    # Qwen3.8-27B layer counts (64 blocks / attn_interval 4); the 9B has 24
    # and 8 (32 / 4).  6144 is 27B's `d_inner` = lin_val_heads 48 x
    # lin_head_dim 128; the 9B is 32 x 128 = 4096.  And the KV term
    # `kv_heads * head_dim * 2 * 2` assumed an int16 mantissa with NO record
    # header, where `rtl/attn_kv_axi.vhd` stores an int8 BFP record with a
    # 16-byte block-exponent granule: 16 + 256 = 272 B, not 1024.  Every one
    # of those was over-reservation, so the printed context here was ~3.8x
    # too pessimistic.  TRACK KVSIZE found and fixed the same six numbers in
    # `tools/pack_model_fk33.py` (commit 0e4f98d) and flagged that this file
    # still disagreed with the packer; TRACK CGENERICS closed it.
    #
    # There is now ONE place the arenas are sized -- `hbm_map.arena_sizes()`,
    # which SCRAPES `rtl/model_cfg_pkg.vhd`, `rtl/attn_kv_axi.vhd` and
    # `rtl/gdn_block.vhd` rather than restating them.  A scrape that stops
    # matching is a hard SystemExit there, and a `--cards` the head counts do
    # not divide is refused for the same reason `model_cfg_pkg`'s
    # `val_heads_per_card` asserts it, instead of printing a fraction of a
    # head as it used to.
    MB = 1024.0 ** 2
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import hbm_map as HM                                   # noqa: E402
    sz = HM.arena_sizes(ncards=cards)
    gdn_state = float(sz["gdn_state_bytes"])          # per card, already split
    kv_tok    = float(sz["kv_bytes_per_token"])       # per card, already split
    free      = hbm * GIB - s_shard - gdn_state
    print("  residency beyond weights, per card "
          "(DERIVED by tools/hbm_map.py from rtl/, not restated here):")
    print(f"    shape            {sz['gdn_layers']} GDN + {sz['attn_layers']} "
          f"attention layers, {sz['val_heads_per_card']} val heads, "
          f"{sz['kv_heads_per_card']} kv heads")
    print(f"    GDN state/layer  {sz['gdn_state_mant_bytes_per_layer']} B "
          f"mantissas + {sz['gdn_state_exp_bytes_per_layer']} B exponents "
          f"= {sz['gdn_state_bytes_per_layer']} B")
    print(f"    KV record        {sz['kv_record_hdr_bytes']} B header + "
          f"{sz['attn_head_dim']} x {sz['kv_mantissa_bits']}/8 B mantissas "
          f"= {sz['kv_record_bytes']} B")
    print(f"    GDN recurrent state (persistent) {gdn_state/MB:>9.1f} MB")
    print(f"    KV cache per token               {kv_tok/1024:>9.1f} KiB")
    print(f"    free for KV                      {free/GIB:>9.3f} GiB")
    if kv_tok > 0:
        ctx = free / kv_tok
        print(f"    => max context                   {ctx:>9.0f} tokens")
        # The model's own ceiling, printed alongside, because the arena
        # capacity above does NOT imply the model's context fits.  At the
        # real 9B image on one card it does not: tools/hbm_map.py measures
        # 233,396 tokens of a 262,144 max_context, short by 477 MiB.  The
        # percentage here is whatever THIS gguf's shard leaves over, which
        # is only that figure when the gguf is the real packed model.
        print(f"       model max_context             {sz['max_context']:>9d} "
              f"tokens  ({100.0*min(ctx, sz['max_context'])/sz['max_context']:.0f}% "
              f"reachable at {cards} card(s))")
    print()

    worst = sorted(mv, key=lambda r: r[5] - r[3] * 4.5 / 8.0, reverse=True)[:6]
    print("  largest absolute overhead (whole-model, unsharded):")
    for n, M, K, pr, _, wh, _ in worst:
        print(f"    {n:38s} M={M:<7d} K={K:<7d} "
              f"{wh/1e6:8.2f} MB  +{wh - pr*4.5/8.0:>10.0f} B")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf")
    ap.add_argument("tensor", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--list", action="store_true", help="list tensors and exit")
    ap.add_argument("--rows-if", type=int, default=4,
                    help="ROWS_IF the file is packed for (4 on the AXU3EG, "
                         "48 on the FK33 per spec 15.2/15.3)")
    ap.add_argument("--axi-dw", type=int, default=AXI_DW_DEF,
                    help="bits per AXI read master (128 AXU3EG HP, 256 FK33 "
                         "HBM SAXI). The byte layout at any width is spec "
                         "6.5a; NPORTS_W and n_scale_sub are derived from it")
    ap.add_argument("--out-shift", type=int, default=None,
                    help="override the calibrated out_shift")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--audit", action="store_true",
                    help="sum the packed size of every tensor and exit")
    ap.add_argument("--cards", type=int, default=2,
                    help="cards to split across, for --audit")
    ap.add_argument("--crosscheck", action="store_true",
                    help="recompute the C reference output for an existing .mv4i")
    ap.add_argument("--seg-rows", default=None,
                    help="comma-separated LOGICAL row segments of a fused "
                         "tensor (e.g. 2048,2048,4096 for a GDN attn_qkv). "
                         "Each segment but the last is padded with zero rows "
                         "up to a whole ROWS_IF tile so the next segment "
                         "starts on a tile boundary and is expressible as a "
                         "row window; see segment_row_plan()")
    a = ap.parse_args()

    if a.list:
        list_tensors(a.gguf)
        return 0
    if a.audit:
        audit(a.gguf, a.rows_if, a.cards, a.axi_dw)
        return 0
    if a.crosscheck:
        crosscheck(a.gguf)
        return 0
    if not a.tensor or not a.out:
        ap.error("TENSOR and OUT are required unless --list")

    # Refuse BEFORE reading a multi-gigabyte tensor.  Failing after ~40 s of
    # dequantisation teaches the same thing at forty times the cost.
    try:
        nports = check_geometry(a.rows_if, a.axi_dw, emitting=True)
    except GeometryError as e:
        sys.stderr.write("pack_int4: refusing this geometry.\n")
        for why in (unmet_reasons(a.rows_if, a.axi_dw) or [str(e)]):
            for i, line in enumerate(_wrap(why, 72)):
                sys.stderr.write(f"  {'- ' if i == 0 else '  '}{line}\n")
        sys.stderr.write(
            "  Geometries this packer emits: any (ROWS_IF, AXI_DW) for which\n"
            "  ROWS_IF*BLOCK*4 is a whole multiple of AXI_DW, AXI_DW is an\n"
            "  AXI4 data width, and the offset table fits the 4 KB header.\n"
            "  Layout: spec 6.5a.  Known-good: ROWS_IF 4 / AXI_DW 128 (AXU3EG,\n"
            "  built) and ROWS_IF 48 / AXI_DW 256 (FK33, 24+3 masters).\n")
        return 2

    print(f"reading {a.tensor} from {a.gguf}")
    W = read_tensor(a.gguf, a.tensor)
    M, K = W.shape
    print(f"  shape M={M} K={K}  ({M * K / 1e6:.1f}M weights)")
    nss = n_scale_sub(a.rows_if, a.axi_dw)
    print(f"  geometry ROWS_IF={a.rows_if} AXI_DW={a.axi_dw} "
          f"BLOCK={BLOCK} -> NPORTS_W={nports} n_scale_sub={nss} "
          f"({nports + nss} AXI read masters)")

    if a.seg_rows:
        seg = [int(t) for t in a.seg_rows.split(",")]
        if sum(seg) != M:
            sys.stderr.write("pack_int4: --seg-rows sums to %d, the tensor "
                             "has %d rows\n" % (sum(seg), M))
            return 2
        m_pad, plan = segment_row_plan(seg, a.rows_if)
        W = apply_segment_padding(W, m_pad, plan)
        print(f"  segment padding: M {M} -> {m_pad}, starts "
              + ", ".join(str(p["row_start"]) for p in plan))
        M = m_pad

    idx, scale, w_exp = quantize(W, IQ4_NL)
    out_shift = a.out_shift if a.out_shift is not None else calibrate_out_shift(K)
    print(f"  w_exp={w_exp}  out_shift={out_shift}  NB={idx.shape[1]}")

    if a.verify:
        verify(W, idx, scale, w_exp, out_shift, IQ4_NL, K)

    blob = pack(idx, scale, w_exp, M, K, a.rows_if, out_shift, IQ4_NL, a.axi_dw)
    with open(a.out, "wb") as f:
        f.write(blob)

    bpw = len(blob) * 8.0 / (M * K)
    print(f"wrote {a.out}  {len(blob) / 1e6:.2f} MB  ({bpw:.2f} bits/weight)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
