#!/usr/bin/env python3
"""Offline weight packer for subsystem A.

Reads a tensor from a GGUF file, requantizes it to subsystem A's INT4 format,
and emits the packed file that ref/matvec_int4.c parses and the RTL streams.

Implements exactly:
  docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md
  6.1 quantization, 6.4 file layout, 6.5 bit ordering (NORMATIVE), 14.1 generics

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


def check_geometry(rows_if: int, axi_dw: int, emitting: bool = True) -> int:
    """Return NPORTS_W for this geometry, or raise GeometryError.

    THE POINT OF THIS FUNCTION is to refuse rather than to guess.  Three
    separate conditions, each with its own reason, because collapsing them into
    one "unsupported" message is what makes the next person guess again:

    1. The 6.5 invariant must divide.  NPORTS_W is a count of AXI masters; a
       fractional one is not a smaller design, it is no design.

    2. The BYTE LAYOUT is only defined at AXI_DW = 128.  At 128 bits with
       BLOCK = 32 one lane is exactly one row's 128-bit chunk, which is the
       "ROWS_IF = 4 coincidence" spec 6.5 calls load-bearing and tells you not
       to assume elsewhere.  At AXI_DW = 256 -- the FK33's HBM SAXI width -- a
       lane spans two rows and the interleave inside a sub-region is a
       different, UNSPECIFIED thing.  Spec 14.5 says so outright and defers it
       until the HBM streamer is designed.  So we refuse; we do not invent it.

    3. The scale region must fit ONE sub-region.  rtl/weight_streamer.vhd:107
       asserts `AXI_DW >= ROWS_IF*16 and AXI_DW mod ROWS_IF*16 = 0` and its own
       comment says the multi-sub-region case "is not implemented".  A file
       claiming n_scale_sub = 1 for a geometry that needs more is a file whose
       scale stream silently runs out.

    Rule 1 is ARITHMETIC and always applies: a geometry whose port count does
    not divide has no size worth reporting either.  Rules 2 and 3 are
    NOT-IMPLEMENTED-YET limits on this repository, not on the format, so
    `emitting=False` waives them for --audit, which computes sizes and writes no
    bytes.  Both waived rules describe the same total number of bytes; they
    differ only in how those bytes are cut into sub-regions, which is precisely
    why a size is still meaningful and a FILE is not.

    Use unmet_reasons() to ask which of 2 and 3 a geometry violates without
    catching an exception.
    """
    lane_bits = rows_if * BLOCK * 4
    if axi_dw <= 0 or lane_bits % axi_dw:
        raise GeometryError(
            f"6.5 invariant does not divide: ROWS_IF*BLOCK*4 = {lane_bits} bits "
            f"is not a whole number of {axi_dw}-bit ports "
            f"(ROWS_IF={rows_if}, BLOCK={BLOCK})")
    nports = lane_bits // axi_dw

    if emitting:
        why = unmet_reasons(rows_if, axi_dw)
        if why:
            raise GeometryError(" ".join(why))

    return nports


def unmet_reasons(rows_if: int, axi_dw: int):
    """Which not-implemented-yet limits this geometry runs into, as prose.

    Separate from check_geometry so --audit can REPORT them next to the sizes
    instead of refusing, and so the emit path can list all of them at once
    rather than whichever happens to be tested first.
    """
    out = []
    if axi_dw != AXI_DW_DEF:
        out.append(
            f"The sub-region BYTE LAYOUT is undefined at AXI_DW={axi_dw}. Only "
            f"{AXI_DW_DEF} is specified: there one lane is exactly one row's "
            f"chunk (spec 6.5, the 'ROWS_IF=4 coincidence'), and that is the "
            f"layout this packer emits. At {axi_dw} bits a lane spans "
            f"{axi_dw // (BLOCK * 4)} rows and the interleave within a "
            f"sub-region has never been written down -- spec 14.5 defers it "
            f"until the HBM weight_streamer exists. I do not know the legal "
            f"set for the FK33 and will not guess one.")
    sw = rows_if * 16
    if axi_dw < sw or axi_dw % sw:
        out.append(
            f"The scale region needs more than one sub-region at "
            f"ROWS_IF={rows_if}: {sw} scale bits per cycle against a "
            f"{axi_dw}-bit port. rtl/weight_streamer.vhd:104-110 states this "
            f"is not implemented (spec 14.5 item 2). The header carries "
            f"n_scale_sub for it; nothing reads it yet.")
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
        if t.name != name:
            continue
        raw = t.data
        qt = t.tensor_type
        if str(qt).endswith("F32"):
            flat = raw.astype(np.float32)
        else:
            flat = quants.dequantize(raw, qt).astype(np.float32)
        ne = [int(x) for x in t.shape]
        K, M = ne[0], (ne[1] if len(ne) > 1 else 1)
        return flat.reshape(M, K)
    raise KeyError(f"tensor {name!r} not in {path}")


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

    Returns (NB, tiles, nports, sub_sz, scl_sz, total).
    """
    nports = check_geometry(rows_if, axi_dw, emitting=emitting)
    NB     = (K + BLOCK - 1) // BLOCK      # 6.3 ceil, K padded to a whole block
    tiles  = (M + rows_if - 1) // rows_if
    port_b = axi_dw // 8                   # bytes of each word this port holds
    sub_sz = align4k(tiles * NB * port_b)
    scl_sz = align4k(tiles * NB * rows_if * 2)
    total  = HDR_BYTES + sub_sz * nports + scl_sz
    return NB, tiles, nports, sub_sz, scl_sz, total


def pack(idx, scale, w_exp, M, K, rows_if, out_shift, cb,
         axi_dw: int = AXI_DW_DEF) -> bytes:
    NB, tiles, nports, sub_sz, scl_sz, total = packed_layout(M, K, rows_if, axi_dw)
    assert NB == idx.shape[1], f"NB mismatch {NB} vs {idx.shape[1]}"
    # check_geometry pins axi_dw to 128 on the emit path, so the byte layout
    # below -- lane == one row's 16-byte chunk -- is the one that applies.
    assert axi_dw == AXI_DW_DEF and nports == rows_if

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
    struct.pack_into("<II", buf, 0x30, scl_off, 1)
    for p in range(nports):
        struct.pack_into("<Q", buf, 0x38 + 8 * p, HDR_BYTES + sub_sz * p)
    struct.pack_into("<Q", buf, 0x38 + 8 * nports, scl_off)

    # ---- weights.  Sub-region p holds lane p of every 512-bit word, and at
    # ROWS_IF=4 one lane is exactly one row's 128-bit chunk (spec 6.5).
    # Nibble order: weight j even -> low nibble of byte j/2, odd -> high.
    idx_pad = np.zeros((tiles * rows_if, NB, BLOCK), dtype=np.uint8)
    idx_pad[:M] = idx
    lanes = idx_pad.reshape(tiles, rows_if, NB, BLOCK)          # (t, rr, b, j)
    lo = lanes[:, :, :, 0::2]
    hi = lanes[:, :, :, 1::2]
    packed = (lo | (hi << 4)).astype(np.uint8)                  # (t, rr, b, 16)
    for rr in range(rows_if):
        blob = packed[:, rr].reshape(-1).tobytes()              # t-major, then b
        base = HDR_BYTES + sub_sz * rr
        buf[base:base + len(blob)] = blob

    # ---- scales: for tile t, for block b, for rr in 0..ROWS_IF-1, uint16 LE
    scl_pad = np.zeros((tiles * rows_if, NB), dtype=np.uint16)
    scl_pad[:M] = scale
    s = scl_pad.reshape(tiles, rows_if, NB).transpose(0, 2, 1)  # (t, b, rr)
    blob = np.ascontiguousarray(s).astype("<u2").tobytes()
    buf[scl_off:scl_off + len(blob)] = blob

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
    cb = np.frombuffer(img[0x20:0x30], dtype=np.int8).astype(np.int64)
    w_sub = [struct.unpack_from("<Q", img, 0x38 + 8 * p)[0] for p in range(nports)]
    s_sub = struct.unpack_from("<Q", img, 0x38 + 8 * nports)[0]

    NB = (K + BLOCK - 1) // BLOCK
    tiles = (M + rows_if - 1) // rows_if

    st = 2463534242
    x = np.empty(K, dtype=np.int64)
    for k in range(K):
        st ^= (st << 13) & 0xFFFFFFFF; st &= 0xFFFFFFFF
        st ^= st >> 17
        st ^= (st << 5) & 0xFFFFFFFF; st &= 0xFFFFFFFF
        x[k] = (st % 20001) - 10000

    idx = np.zeros((M, NB, BLOCK), dtype=np.int64)
    scale = np.zeros((M, NB), dtype=np.int64)
    nbytes = tiles * NB * (BLOCK // 2)
    sc_all = np.frombuffer(img[s_sub:s_sub + tiles * NB * rows_if * 2],
                           dtype="<u2").reshape(tiles, NB, rows_if).astype(np.int64)
    for rr in range(nports):
        raw = np.frombuffer(img[w_sub[rr]:w_sub[rr] + nbytes], dtype=np.uint8)
        raw = raw.reshape(tiles, NB, BLOCK // 2).astype(np.int64)
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
        # A handles 2D matvec weights.  Norms, biases, ssm_a and the 4-tap
        # conv1d are 1D or tiny and stay in their native form.
        is_mv = len(ne) > 1 and M > 1 and K > 1 and name != "blk.0.ssm_conv1d.weight" \
                and not name.endswith("ssm_conv1d.weight")
        if is_mv:
            _, _, _, _, _, whole = packed_layout(M, K, rows_if, axi_dw,
                                                 emitting=False)
            # column-parallel: each card holds ceil(M/cards) rows, padded and
            # aligned on its own, so shard overhead does NOT divide by cards
            Ms = (M + cards - 1) // cards
            _, _, _, _, _, shard = packed_layout(Ms, K, rows_if, axi_dw,
                                                 emitting=False)
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

    print(f"model      {path}")
    print(f"ROWS_IF={rows_if}  AXI_DW={axi_dw}  NPORTS_W={nports}  "
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
    MB = 1024.0 ** 2
    n_gdn, n_attn = 48, 16
    d_inner, state_size = 6144, 128
    kv_heads, head_dim = 4, 256
    gdn_state = n_gdn * d_inner * state_size * 2 / cards      # int16, split
    kv_tok    = n_attn * kv_heads * head_dim * 2 * 2 / cards  # K+V, int16, split
    free      = hbm * GIB - s_shard - gdn_state
    print("  residency beyond weights, per card:")
    print(f"    GDN recurrent state (persistent) {gdn_state/MB:>9.1f} MB")
    print(f"    KV cache per token               {kv_tok/1024:>9.1f} KiB")
    print(f"    free for KV                      {free/GIB:>9.3f} GiB")
    if kv_tok > 0:
        print(f"    => max context                   {free/kv_tok:>9.0f} tokens")
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
                    help="ROWS_IF the file is packed for (4 on the AXU3EG; the "
                         "FK33 value is not settled, see spec 14.5)")
    ap.add_argument("--axi-dw", type=int, default=AXI_DW_DEF,
                    help="bits per AXI read master (128 AXU3EG HP; the FK33's "
                         "HBM SAXI ports are 256, which this packer REFUSES to "
                         "emit for -- the layout is undefined, spec 14.5)")
    ap.add_argument("--out-shift", type=int, default=None,
                    help="override the calibrated out_shift")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--audit", action="store_true",
                    help="sum the packed size of every tensor and exit")
    ap.add_argument("--cards", type=int, default=2,
                    help="cards to split across, for --audit")
    ap.add_argument("--crosscheck", action="store_true",
                    help="recompute the C reference output for an existing .mv4i")
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
            "  Geometries this packer emits today: BLOCK=32, AXI_DW=128,\n"
            "  ROWS_IF in {1, 2, 4, 8}.  Anything else needs the layout to be\n"
            "  specified first.\n")
        return 2

    print(f"reading {a.tensor} from {a.gguf}")
    W = read_tensor(a.gguf, a.tensor)
    M, K = W.shape
    print(f"  shape M={M} K={K}  ({M * K / 1e6:.1f}M weights)")
    print(f"  geometry ROWS_IF={a.rows_if} AXI_DW={a.axi_dw} "
          f"BLOCK={BLOCK} -> NPORTS_W={nports}")

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
