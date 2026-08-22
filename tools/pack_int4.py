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
AXI_DW      = 128                 # bits; spec 6.5 invariant
OUT_SHIFT_MAX = 40                # spec 7.4

# spec 6.1 default codebook.  MUST NOT contain -128 (spec 7.4): with cb=-128 and
# x_mant=-32768 a 32-term block partial reaches exactly 2^27 and overflows s28
# by one.  IQ4_NL's minimum is -127, so the constraint costs nothing.
IQ4_NL = np.array([-127, -104, -83, -65, -49, -35, -22, -10,
                      1,   13,  25,  38,  53,  69,  89, 113], dtype=np.int8)


def align4k(n: int) -> int:
    return (n + 4095) & ~4095


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

def pack(idx, scale, w_exp, M, K, rows_if, out_shift, cb) -> bytes:
    NB     = idx.shape[1]
    tiles  = (M + rows_if - 1) // rows_if
    nports = rows_if                       # 6.5 invariant at BLOCK=32, AXI_DW=128
    chunk  = BLOCK // 2                    # 16 bytes per row-block chunk
    sub_sz = align4k(tiles * NB * chunk)
    scl_sz = align4k(tiles * NB * rows_if * 2)
    total  = HDR_BYTES + sub_sz * nports + scl_sz

    buf = bytearray(total)                 # zero-filled: PAD FILL = 0x00

    # ---- header, spec 6.4 byte-pinned layout, little-endian
    struct.pack_into("<IHHII", buf, 0x00, MAGIC, VERSION, 1, M, K)
    struct.pack_into("<ii",    buf, 0x10, w_exp, out_shift)
    struct.pack_into("<HHHH",  buf, 0x18, rows_if, nports, BLOCK, 0)
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
    rows_if, nports, blk, _ = struct.unpack_from("<HHHH", img, 0x18)
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

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf")
    ap.add_argument("tensor", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--list", action="store_true", help="list tensors and exit")
    ap.add_argument("--rows-if", type=int, default=4,
                    help="ROWS_IF the file is packed for (4 AXU3EG, 80 FK33)")
    ap.add_argument("--out-shift", type=int, default=None,
                    help="override the calibrated out_shift")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--crosscheck", action="store_true",
                    help="recompute the C reference output for an existing .mv4i")
    a = ap.parse_args()

    if a.list:
        list_tensors(a.gguf)
        return 0
    if a.crosscheck:
        crosscheck(a.gguf)
        return 0
    if not a.tensor or not a.out:
        ap.error("TENSOR and OUT are required unless --list")

    print(f"reading {a.tensor} from {a.gguf}")
    W = read_tensor(a.gguf, a.tensor)
    M, K = W.shape
    print(f"  shape M={M} K={K}  ({M * K / 1e6:.1f}M weights)")

    idx, scale, w_exp = quantize(W, IQ4_NL)
    out_shift = a.out_shift if a.out_shift is not None else calibrate_out_shift(K)
    print(f"  w_exp={w_exp}  out_shift={out_shift}  NB={idx.shape[1]}")

    if a.verify:
        verify(W, idx, scale, w_exp, out_shift, IQ4_NL, K)

    blob = pack(idx, scale, w_exp, M, K, a.rows_if, out_shift, IQ4_NL)
    with open(a.out, "wb") as f:
        f.write(blob)

    bpw = len(blob) * 8.0 / (M * K)
    print(f"wrote {a.out}  {len(blob) / 1e6:.2f} MB  ({bpw:.2f} bits/weight)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
