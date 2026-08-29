#!/usr/bin/env python3
"""tools/embed_gather.py -- fetch ONE embedding row out of a packed .mv4i
tensor and BFP-encode it, plus the oracle that says the fetch is right.

WHAT THIS IS FOR.  `token_embd.weight` is 248,320 x 4,096 and is packed in
subsystem A's INT4 tile-lane layout (spec 6.5a), the same layout every other
matvec tensor uses.  Streaming it through A to select one row is absurd, so
the row has to be GATHERED.  Whoever does the gathering -- the host per
spec D 3.2, or a future on-card unit -- needs the addressing recipe and the
integer arithmetic, and needs them to be the SAME recipe so the two cannot
produce different tokens.  This file is that recipe, in Python, with an
oracle.

THE ADDRESSING RESULT, which is the part worth reading.  A row of a 6.5a
tensor is NOT scattered across the 24 weight sub-regions.  Derivation:

  * the tile word for (tile t, block b) is ROWS_IF*BLOCK*4 bits, with row r
    of the tile at bits (r+1)*128-1 downto r*128, row 0 at the LSB
    (tools/pack_int4.py:455-467, and spec 6.5a);
  * sub-region p is bytes [p*32, (p+1)*32) of that word at AXI_DW = 256;
  * 32 bytes is exactly TWO rows' 16-byte chunks.

So at ROWS_IF = 48 / AXI_DW = 256, row `rr` of a tile lives ENTIRELY inside
weight sub-region `rr // 2`, in the low or high 16 bytes of a beat according
to `rr & 1`.  Beats inside a sub-region run tile-major then block, so the
whole row's nibbles for all NB blocks are `NB` CONSECUTIVE beats.  At
NB = 128 that is one contiguous 4,096-byte read, of which 2,048 bytes are
this row.

Scales are the same shape one level up: a superword is nsub_s * AXI_DW bits
= 48 uint16 = one scale per row of the tile, and scale sub-region q is bytes
[q*32, (q+1)*32) of it, i.e. rows 16q .. 16q+15.  So row `rr`'s scales are
uint16 index `rr % 16` of `NB` consecutive beats in scale sub-region
`rr // 16` -- a second contiguous 4,096-byte read.

**TWO contiguous 4 KB reads is the whole gather.**  No cross-lane assembly,
no strided descriptor, no 27-master fan-in.  That is what makes an on-card
gatherer cheap enough to be worth costing, and it is why this file exists
before any decision about who does the gather.

THE ORACLE, and why a round trip would not have been one.  Three decoders:

  direct       the recipe above.  This is what a driver or a fabric unit
               implements.
  reassemble   rebuild the FULL tile word from all NPORTS_W sub-regions and
               read the row out of it, and rebuild the full superword from
               all n_scale_sub sub-regions.  Shares no addressing arithmetic
               with `direct`; it is the shape tools/pack_int4.py's own
               crosscheck() uses.
  gguf         dequantize the row from the ORIGINAL BF16 GGUF.

`direct` vs `reassemble` is a two-decoder agreement and would pass for two
decoders that are wrong the same way -- the m7 failure mode recorded in
CLAUDE.md.  `gguf` is the one that cannot: it never touches the packed file.
It cannot be bit-exact (the packing is lossy by construction), so it is
checked as a CORRELATION and a relative-error bound, which is enough to kill
any layout error, because a wrong layout returns another token's weights and
those are uncorrelated.

THE ARITHMETIC, and a correction to spec D 3.2.  D 3.2 prescribes
"dequantize the INT4 row with the same integer arithmetic as A 7.4
(codebook[idx] * scale, floor >> 15 per block), then BFP-pack".  Taken
literally that shifts right by 15 and THEN searches for a block exponent, so
the value lands in [-127, 127] and 8 of the 16 mantissa bits are dead before
the pack ever runs.  `RECIPE_D32` implements it literally; `RECIPE_WIDE`
defers the >> 15 into the pack's own shift, which is what rtl/embed.vhd
already does for the stories260K path (it BFP-encodes `mant * mult` at full
width).  --compare measures the difference against the GGUF.

Usage:
    tools/embed_gather.py --mv4i FILE.mv4i --token 12345 [--recipe wide]
    tools/embed_gather.py --mv4i FILE.mv4i --selftest [--n 64] [--gguf G]
    tools/embed_gather.py --mv4i FILE.mv4i --compare --gguf G [--n 64]
    tools/embed_gather.py --mv4i FILE.mv4i --mutate [--gguf G]
"""

import argparse
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_mv4i_desc import Mv4iHeader, DescError, MV4I_HDR_BYTES  # noqa: E402

RECIPE_D32 = "d32"      # spec D 3.2, literally: floor >> 15, then pack
RECIPE_WIDE = "wide"    # keep the 15 fractional bits, let the pack place them

# The GGUF oracle is LOSSY on both sides -- the pack throws away real
# precision -- so it cannot ask "is this bit-exact".  The only question it can
# answer is "is this the RIGHT ROW", and these two numbers are where the answer
# separates.  They are MEASURED, not chosen: --separation prints the two
# populations they sit between (matched decode vs. the neighbouring row's
# GGUF).  Do not tighten them to catch quantization loss; that is what
# --compare is for.
RELERR_MAX = 0.35
CORR_MIN = 0.90

# ...and they are only separable for RECIPE_WIDE.  MEASURED by --separation
# over 47 matched / 47 mismatched pairs at n = 48:
#
#   recipe  matched relerr        mismatched relerr     verdict
#   wide    0.0783 .. 0.1267      0.7116 .. 5.3071      5.6x gap, gateable
#   d32     0.1570 .. 0.7054      0.7306 .. 5.3614      3.6% gap, NOT gateable
#
# That is not a defect in the oracle.  It is a measurement of RECIPE_D32: the
# literal spec-D-3.2 shift destroys so much of the row that the decoded row is
# barely distinguishable from its NEIGHBOUR.  --recipe d32 therefore runs the
# decoder agreement and the BFP check but declares the GGUF gate advisory.
GATEABLE = {RECIPE_WIDE: True, RECIPE_D32: False}


# ---------------------------------------------------------------- arithmetic
# Bit-for-bit ref/mv4i_arith.h.  Re-implemented rather than wrapped: this file
# is a reference the RTL will be checked against, and a reference that called
# the other reference would be checking one thing.

def floor_shr(v, sh):
    """mv4i_floor_shr.  Python's >> is already floor for negative ints."""
    if sh <= 0:
        return v
    return v >> sh


def round_shift(v, sh):
    """mv4i_round_shift: round half toward +infinity, no bias at sh = 0.

    Extended to NEGATIVE sh, which mv4i_arith.h has no need for and this file
    does: a BFP encode of a small-magnitude vector shifts LEFT.  A left shift
    is exact, so there is no rounding question at sh < 0."""
    if sh == 0:
        return v
    if sh < 0:
        return v << (-sh)
    return floor_shr(v + (1 << (sh - 1)), sh)


def sat16(v):
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return v


def msb_pos(a):
    """mv4i_msb_pos_u.  msb_pos(0) = 0 is NORMATIVE."""
    a = int(a)
    if a == 0:
        return 0
    return a.bit_length() - 1


TARGET_MSB = 14         # 16 - 2, the BFP headroom every unit in this repo uses


def bfp_pack(vals, val_exp):
    """BFP-encode integers that represent `true * 2^val_exp`.

    Returns (mant list, x_exp) under this repository's convention
    `value[j] = mant[j] * 2^(-x_exp)`.

    sh = msb_pos(amax) - TARGET_MSB, and it is deliberately NOT clamped at 0:
    rtl/embed.vhd searches e downward from 30 and accepts a LEFT shift, which
    is the same choice.  Clamping would leave a row whose amax is 127 sitting
    in 7 of the 16 available bits."""
    amax = max((abs(int(v)) for v in vals), default=0)
    if amax == 0:
        return [0] * len(vals), val_exp
    sh = msb_pos(amax) - TARGET_MSB
    mant = [sat16(round_shift(int(v), sh)) for v in vals]
    return mant, val_exp - sh


# ------------------------------------------------------------------ decoders

class PackedTensor(object):
    """A memory-mapped .mv4i, with its 6.5a geometry resolved once."""

    def __init__(self, path):
        self.h = Mv4iHeader(path)
        h = self.h
        self.mm = np.memmap(path, dtype=np.uint8, mode="r")
        self.port_b = h.axi_dw // 8               # bytes per beat
        self.row_b = h.block // 2                 # bytes of one row-chunk
        self.rows_per_beat = self.port_b // self.row_b
        if self.port_b % self.row_b:
            raise DescError("AXI_DW = %d is not a whole number of %d-byte row "
                            "chunks; this gather recipe does not apply"
                            % (h.axi_dw, self.row_b))
        self.scales_per_beat = self.port_b // 2
        self.nb = h.nb
        self.tiles = h.tiles(h.M)
        self.sub_bytes = h.sub_bytes()
        self.w_off = list(h.w_sub_offset)
        self.s_off = list(h.s_sub_offset)
        if h.grp != 1:
            # GRP > 1 packs several (t, b) groups into one superword and the
            # scale beat index stops being t*NB+b.  Refuse rather than guess.
            raise DescError("GRP = %d; this gather is derived for GRP = 1 only"
                            % h.grp)

    # -- decoder 1: the addressing recipe an implementation uses
    def nibbles_direct(self, tok):
        h = self.h
        t, rr = divmod(tok, h.rows_if)
        p = rr // self.rows_per_beat
        half = rr % self.rows_per_beat
        start = self.w_off[p] + (t * self.nb) * self.port_b
        blob = self.mm[start:start + self.nb * self.port_b]
        beats = np.asarray(blob).reshape(self.nb, self.port_b)
        chunk = beats[:, half * self.row_b:(half + 1) * self.row_b]
        return self._nibbles_from_chunk(chunk)

    def scales_direct(self, tok):
        h = self.h
        t, rr = divmod(tok, h.rows_if)
        q = rr // self.scales_per_beat
        k = rr % self.scales_per_beat
        start = self.s_off[q] + (t * self.nb) * self.port_b
        blob = self.mm[start:start + self.nb * self.port_b]
        beats = np.asarray(blob).reshape(self.nb, self.port_b)
        pair = beats[:, 2 * k:2 * k + 2].copy()
        return pair.view("<u2").reshape(self.nb).astype(np.int64)

    # -- decoder 2: rebuild the whole word, then read the row out of it
    def nibbles_reassemble(self, tok):
        h = self.h
        t, rr = divmod(tok, h.rows_if)
        word = np.zeros((self.nb, h.nports_w, self.port_b), dtype=np.uint8)
        for p in range(h.nports_w):
            start = self.w_off[p] + (t * self.nb) * self.port_b
            blob = self.mm[start:start + self.nb * self.port_b]
            word[:, p, :] = np.asarray(blob).reshape(self.nb, self.port_b)
        # the word is the ROWS_IF row-chunks concatenated, row 0 at byte 0
        word = word.reshape(self.nb, h.rows_if, self.row_b)
        return self._nibbles_from_chunk(word[:, rr, :])

    def scales_reassemble(self, tok):
        h = self.h
        t, rr = divmod(tok, h.rows_if)
        sup = np.zeros((self.nb, h.n_scale_sub, self.port_b), dtype=np.uint8)
        for q in range(h.n_scale_sub):
            start = self.s_off[q] + (t * self.nb) * self.port_b
            blob = self.mm[start:start + self.nb * self.port_b]
            sup[:, q, :] = np.asarray(blob).reshape(self.nb, self.port_b)
        flat = sup.reshape(self.nb, h.n_scale_sub * self.port_b)
        allsc = flat.copy().view("<u2").reshape(self.nb, -1)
        return allsc[:, rr].astype(np.int64)

    def _nibbles_from_chunk(self, chunk):
        """(NB, row_b) bytes -> (NB, BLOCK) codebook indices.

        Nibble order is pack_int4.py:455's: weight j even -> low nibble of
        byte j//2, odd -> high."""
        lo = (chunk & 0x0F).astype(np.int64)
        hi = (chunk >> 4).astype(np.int64)
        out = np.empty((chunk.shape[0], chunk.shape[1] * 2), dtype=np.int64)
        out[:, 0::2] = lo
        out[:, 1::2] = hi
        return out

    # -- the row, as integers
    def row_int(self, tok, decoder="direct", recipe=RECIPE_D32):
        """The dequantized row as integers, plus the exponent they carry.

        Returns (values, val_exp) with `true_weight = value * 2^(-val_exp)`.

        RECIPE_D32   value = floor((cb[idx] * scale) >> 15), val_exp = w_exp
        RECIPE_WIDE  value = cb[idx] * scale,                val_exp = w_exp+15
        """
        h = self.h
        if tok < 0 or tok >= h.M:
            raise DescError("token %d outside 0 .. %d" % (tok, h.M - 1))
        if decoder == "direct":
            idx = self.nibbles_direct(tok)
            sc = self.scales_direct(tok)
        elif decoder == "reassemble":
            idx = self.nibbles_reassemble(tok)
            sc = self.scales_reassemble(tok)
        else:
            raise DescError("unknown decoder %r" % decoder)
        cb = np.array(h.codebook, dtype=np.int64)
        prod = cb[idx] * sc[:, None]                  # (NB, BLOCK)
        if recipe == RECIPE_D32:
            v = prod >> 15                            # numpy >> is floor
            return v.reshape(-1)[:h.K], h.w_exp
        if recipe == RECIPE_WIDE:
            return prod.reshape(-1)[:h.K], h.w_exp + 15
        raise DescError("unknown recipe %r" % recipe)

    def row_bfp(self, tok, decoder="direct", recipe=RECIPE_D32):
        v, ve = self.row_int(tok, decoder=decoder, recipe=recipe)
        return bfp_pack(list(int(x) for x in v), ve)


# -------------------------------------------------------------- gguf oracle
def gguf_rows(gguf_path, tensor, toks):
    """The BF16 rows straight out of the GGUF, as float32.

    Deliberately NOT via gguf.quants.dequantize on the whole tensor: that
    materialises 4 GB for a 4 KB question.  BF16 is the top 16 bits of an
    IEEE float32, so the widening is a shift."""
    for p in ("/mnt/storage/llama-dflash2-src/gguf-py",
              os.path.expanduser("~/GitHub/llama.cpp.upstream/gguf-py")):
        if os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)
    from gguf.gguf_reader import GGUFReader
    rd = GGUFReader(gguf_path, "r")
    t = None
    for cand in rd.tensors:
        if cand.name == tensor:
            t = cand
            break
    if t is None:
        raise DescError("%s: tensor %r not present" % (gguf_path, tensor))
    if not str(t.tensor_type).endswith("BF16"):
        raise DescError("%s: %s is %s, this reader handles BF16 only"
                        % (gguf_path, tensor, t.tensor_type))
    out = {}
    for tok in toks:
        bits = np.asarray(t.data[tok]).copy().view("<u2").astype(np.uint32)
        out[tok] = (bits << 16).view(np.float32).astype(np.float64)
    return out


# ----------------------------------------------------------------- checking
def relerr(approx, exact):
    """Relative error of a whole row, in the norm that matters for a matvec:
    ||approx - exact|| / ||exact||.  Per-element relative error is the wrong
    statistic here -- a weight near zero has unbounded relative error and no
    influence."""
    num = float(np.linalg.norm(approx - exact))
    den = float(np.linalg.norm(exact))
    return num / den if den > 0 else (0.0 if num == 0 else float("inf"))


def bfp_to_float(mant, x_exp):
    return np.asarray(mant, dtype=np.float64) * (2.0 ** (-x_exp))


def sample_tokens(M, n, seed=12345):
    """A spread that deliberately includes the structural corners: row 0, the
    last row, the rows either side of every kind of boundary this layout has
    (tile, beat-half, scale sub-region), and the first row of the PARTIAL last
    tile.  Random sampling alone reaches none of those with any reliability."""
    rows_if = 48
    corners = [0, 1, 2, 15, 16, 17, 31, 32, 33,
               rows_if - 1, rows_if, rows_if + 1,
               2 * rows_if - 1, 2 * rows_if,
               M - 1, M - 2,
               (M // rows_if) * rows_if,          # first row of the last tile
               (M // rows_if) * rows_if - 1]
    corners = sorted(set(c for c in corners if 0 <= c < M))
    rng = np.random.RandomState(seed)
    extra = list(rng.randint(0, M, size=max(0, n - len(corners))))
    return corners + [int(x) for x in extra]


def selftest(pt, gguf, tensor, toks, recipe, verbose=True, quiet_fail=False):
    """Returns a dict of counters.  Nothing here is a round trip."""
    r = dict(n=len(toks), decoder_mismatch=0, bfp_mismatch=0,
             gguf_checked=0, gguf_worst=0.0, gguf_bad=0,
             corr_worst=1.0, zero_rows=0)
    ref = gguf_rows(gguf, tensor, toks) if gguf else None
    for tok in toks:
        vd, ed = pt.row_int(tok, "direct", recipe)
        vr, er = pt.row_int(tok, "reassemble", recipe)
        if ed != er or not np.array_equal(vd, vr):
            r["decoder_mismatch"] += 1
            if verbose and not quiet_fail:
                bad = int(np.count_nonzero(np.asarray(vd) != np.asarray(vr)))
                print("  token %d: direct and reassemble differ in %d of %d"
                      % (tok, bad, len(vd)))
            continue
        md, xd = bfp_pack(list(int(x) for x in vd), ed)
        mr, xr = bfp_pack(list(int(x) for x in vr), er)
        if xd != xr or md != mr:
            r["bfp_mismatch"] += 1
            continue
        if ref is not None:
            exact = ref[tok]
            got = bfp_to_float(md, xd)
            if float(np.linalg.norm(exact)) == 0.0:
                r["zero_rows"] += 1
                continue
            e = relerr(got, exact)
            c = float(np.corrcoef(got, exact)[0, 1]) if np.std(got) > 0 else 0.0
            r["gguf_checked"] += 1
            r["gguf_worst"] = max(r["gguf_worst"], e)
            r["corr_worst"] = min(r["corr_worst"], c)
            if e > RELERR_MAX or c < CORR_MIN:
                r["gguf_bad"] += 1
                if verbose and not quiet_fail:
                    print("  token %d: relerr %.4f corr %.4f -- outside the "
                          "gate%s" % (tok, e, c,
                                      "" if GATEABLE.get(recipe) else
                                      " (advisory for this recipe)"))
    return r


def separation(pt, gguf, tensor, toks, recipe):
    """MEASURE the two populations RELERR_MAX / CORR_MIN sit between.

    A threshold nobody measured is a threshold nobody can defend.  This runs
    the decode of row `t` against the GGUF row `t` (MATCHED) and against the
    GGUF row `t+1` (MISMATCHED), which is the smallest possible addressing
    error, and prints both distributions.  If the two populations overlap, the
    gate is worthless and this says so."""
    need = sorted(set(list(toks) + [min(pt.h.M - 1, t + 1) for t in toks]))
    ref = gguf_rows(gguf, tensor, need)
    mt_e, mt_c, ms_e, ms_c = [], [], [], []
    for tok in toks:
        nxt = min(pt.h.M - 1, tok + 1)
        if nxt == tok:
            continue
        m, xe = pt.row_bfp(tok, "direct", recipe)
        got = bfp_to_float(m, xe)
        if np.std(got) == 0:
            continue
        for tgt, le, lc in ((tok, mt_e, mt_c), (nxt, ms_e, ms_c)):
            exact = ref[tgt]
            if float(np.linalg.norm(exact)) == 0.0 or np.std(exact) == 0:
                continue
            le.append(relerr(got, exact))
            lc.append(float(np.corrcoef(got, exact)[0, 1]))
    def rng(v):
        return (min(v), max(v), sum(v) / len(v)) if v else (0, 0, 0)
    me = rng(mt_e); mc = rng(mt_c); se = rng(ms_e); sc = rng(ms_c)
    print("recipe %s, %d matched pairs, %d mismatched (row t decoded vs row "
          "t+1's GGUF)" % (recipe, len(mt_e), len(ms_e)))
    print("  relerr  MATCHED   min %.4f  max %.4f  mean %.4f" % me)
    print("  relerr  MISMATCH  min %.4f  max %.4f  mean %.4f" % se)
    print("  corr    MATCHED   min %.4f  max %.4f  mean %.4f" % mc)
    print("  corr    MISMATCH  min %.4f  max %.4f  mean %.4f" % sc)
    gap_e = se[0] - me[1]
    gap_c = mc[0] - sc[1]
    print("  gates   RELERR_MAX %.2f  CORR_MIN %.2f" % (RELERR_MAX, CORR_MIN))
    print("  margin  relerr worst-matched %.4f .. best-mismatched %.4f "
          "(gap %+.4f)" % (me[1], se[0], gap_e))
    print("  margin  corr   worst-matched %.4f .. best-mismatched %.4f "
          "(gap %+.4f)" % (mc[0], sc[1], gap_c))
    ok = (me[1] < RELERR_MAX < se[0]) and (sc[1] < CORR_MIN < mc[0])
    print("  SEPARATION %s" % ("CLEAN" if ok else
                               "OVERLAPS -- the gate cannot be trusted"))
    return ok


# ------------------------------------------------------------------- mutants
def _mutate_nibble_order(pt):
    orig = pt._nibbles_from_chunk

    def swapped(chunk):
        lo = (chunk & 0x0F).astype(np.int64)
        hi = (chunk >> 4).astype(np.int64)
        out = np.empty((chunk.shape[0], chunk.shape[1] * 2), dtype=np.int64)
        out[:, 0::2] = hi          # MUTANT: even weight takes the HIGH nibble
        out[:, 1::2] = lo
        return out
    pt._nibbles_from_chunk = swapped
    return lambda: setattr(pt, "_nibbles_from_chunk", orig)


def _mutate_half(pt):
    orig = pt.nibbles_direct

    def flipped(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        p = rr // pt.rows_per_beat
        half = 1 - (rr % pt.rows_per_beat)          # MUTANT: wrong half of the beat
        start = pt.w_off[p] + (t * pt.nb) * pt.port_b
        blob = pt.mm[start:start + pt.nb * pt.port_b]
        beats = np.asarray(blob).reshape(pt.nb, pt.port_b)
        return pt._nibbles_from_chunk(
            beats[:, half * pt.row_b:(half + 1) * pt.row_b])
    pt.nibbles_direct = flipped
    return lambda: setattr(pt, "nibbles_direct", orig)


def _mutate_subregion(pt):
    orig = pt.nibbles_direct

    def offby(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        p = min(h.nports_w - 1, rr // pt.rows_per_beat + 1)   # MUTANT: p + 1
        half = rr % pt.rows_per_beat
        start = pt.w_off[p] + (t * pt.nb) * pt.port_b
        blob = pt.mm[start:start + pt.nb * pt.port_b]
        beats = np.asarray(blob).reshape(pt.nb, pt.port_b)
        return pt._nibbles_from_chunk(
            beats[:, half * pt.row_b:(half + 1) * pt.row_b])
    pt.nibbles_direct = offby
    return lambda: setattr(pt, "nibbles_direct", orig)


def _mutate_tile(pt):
    orig = pt.nibbles_direct

    def offby(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        t = min(pt.tiles - 1, t + 1)                          # MUTANT: tile + 1
        p = rr // pt.rows_per_beat
        half = rr % pt.rows_per_beat
        start = pt.w_off[p] + (t * pt.nb) * pt.port_b
        blob = pt.mm[start:start + pt.nb * pt.port_b]
        beats = np.asarray(blob).reshape(pt.nb, pt.port_b)
        return pt._nibbles_from_chunk(
            beats[:, half * pt.row_b:(half + 1) * pt.row_b])
    pt.nibbles_direct = offby
    return lambda: setattr(pt, "nibbles_direct", orig)


def _mutate_scale_sub(pt):
    orig = pt.scales_direct

    def offby(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        q = min(h.n_scale_sub - 1, rr // pt.scales_per_beat + 1)  # MUTANT: q + 1
        k = rr % pt.scales_per_beat
        start = pt.s_off[q] + (t * pt.nb) * pt.port_b
        blob = pt.mm[start:start + pt.nb * pt.port_b]
        beats = np.asarray(blob).reshape(pt.nb, pt.port_b)
        return beats[:, 2 * k:2 * k + 2].copy().view("<u2") \
                    .reshape(pt.nb).astype(np.int64)
    pt.scales_direct = offby
    return lambda: setattr(pt, "scales_direct", orig)


def _mutate_scale_index(pt):
    orig = pt.scales_direct

    def offby(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        q = rr // pt.scales_per_beat
        k = (rr % pt.scales_per_beat + 1) % pt.scales_per_beat   # MUTANT: k + 1
        start = pt.s_off[q] + (t * pt.nb) * pt.port_b
        blob = pt.mm[start:start + pt.nb * pt.port_b]
        beats = np.asarray(blob).reshape(pt.nb, pt.port_b)
        return beats[:, 2 * k:2 * k + 2].copy().view("<u2") \
                    .reshape(pt.nb).astype(np.int64)
    pt.scales_direct = offby
    return lambda: setattr(pt, "scales_direct", orig)


def _mutate_beat_stride(pt):
    """Read the row's beats from the RIGHT sub-region but block-major rather
    than tile-major, i.e. stride by `tiles` instead of running consecutively.
    This is the mutation a reader that mixed up the two orderings makes."""
    orig = pt.nibbles_direct

    def strided(tok):
        h = pt.h
        t, rr = divmod(tok, h.rows_if)
        p = rr // pt.rows_per_beat
        half = rr % pt.rows_per_beat
        base = pt.w_off[p]
        rows = []
        for b in range(pt.nb):
            off = base + (b * pt.tiles + t) * pt.port_b
            rows.append(np.asarray(pt.mm[off:off + pt.port_b]))
        beats = np.stack(rows)
        return pt._nibbles_from_chunk(
            beats[:, half * pt.row_b:(half + 1) * pt.row_b])
    pt.nibbles_direct = strided
    return lambda: setattr(pt, "nibbles_direct", orig)


def _mutate_bfp_clamp(pt):
    """Clamp the BFP shift at 0, i.e. spec-D-3.2-as-written with no left
    shift.  This one is EXPECTED not to change the represented VALUE at all,
    only the mantissa scaling -- it is in the table to measure exactly that."""
    return None     # handled specially in run_mutations


def _mutate_target_msb(pt):
    """One less bit of BFP headroom.  Both decoders shift identically, so the
    decoder-agreement check CANNOT see it, and the GGUF is far too coarse.
    In the table to measure the floor, not to be passed."""
    import sys as _s
    m = _s.modules[__name__]
    orig = m.TARGET_MSB
    m.TARGET_MSB = 13
    def undo():
        m.TARGET_MSB = orig
    return undo


def _mutate_round_bias(pt):
    """Truncate instead of round-half-toward-+inf in the BFP pack.  Same
    reason as m8: a half-LSB change that no check here resolves."""
    import sys as _s
    m = _s.modules[__name__]
    orig = m.round_shift
    def trunc(v, sh):
        if sh == 0:
            return v
        if sh < 0:
            return v << (-sh)
        return v >> sh
    m.round_shift = trunc
    def undo():
        m.round_shift = orig
    return undo


def _mutate_codebook_reversed(pt):
    """Reverse the 16-entry codebook.  Nothing in the packed file constrains
    it, so only an external oracle can object."""
    orig = list(pt.h.codebook)
    pt.h.codebook = list(reversed(orig))
    def undo():
        pt.h.codebook = orig
    return undo


MUTANTS = [
    ("m1 nibble order swapped", _mutate_nibble_order),
    ("m2 wrong half of the beat", _mutate_half),
    ("m3 weight sub-region + 1", _mutate_subregion),
    ("m4 tile + 1", _mutate_tile),
    ("m5 scale sub-region + 1", _mutate_scale_sub),
    ("m6 scale index within beat + 1", _mutate_scale_index),
    ("m7 beats read block-major not tile-major", _mutate_beat_stride),
    ("m8 codebook reversed", _mutate_codebook_reversed),
    ("m9 BFP headroom TARGET_MSB 14 -> 13", _mutate_target_msb),
    ("m10 BFP pack truncates instead of rounding", _mutate_round_bias),
]


def run_mutations(pt, gguf, tensor, toks, recipe):
    print("mutation table -- a row is KILLED if the check refuses it")
    print("%-42s %-8s %s" % ("mutant", "verdict", "what fired"))
    gate = GATEABLE.get(recipe, False)
    clean = selftest(pt, gguf, tensor, toks, recipe, verbose=False)
    ok = (clean["decoder_mismatch"] == 0 and clean["bfp_mismatch"] == 0
          and (clean["gguf_bad"] == 0 or not gate))
    print("%-42s %-8s %s" % ("m0 clean (control)", "PASS" if ok else "FAIL",
                             "must PASS or the table means nothing"))
    killed = 0
    for name, fn in MUTANTS:
        undo = fn(pt)
        try:
            res = selftest(pt, gguf, tensor, toks, recipe, verbose=False,
                           quiet_fail=True)
        finally:
            undo()
        fired = []
        if res["decoder_mismatch"]:
            fired.append("decoder disagreement %d/%d"
                         % (res["decoder_mismatch"], res["n"]))
        if res["bfp_mismatch"]:
            fired.append("bfp %d" % res["bfp_mismatch"])
        if res["gguf_bad"]:
            fired.append("gguf %d/%d worst relerr %.3f corr %.3f"
                         % (res["gguf_bad"], res["gguf_checked"],
                            res["gguf_worst"], res["corr_worst"]))
        verdict = "KILLED" if fired else "SILENT"
        if fired:
            killed += 1
        print("%-42s %-8s %s" % (name, verdict, ", ".join(fired) or
                                 "NOTHING -- this is the resolution floor"))
    print("killed %d of %d" % (killed, len(MUTANTS)))
    return killed == len(MUTANTS) and ok


# --------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mv4i", required=True)
    ap.add_argument("--gguf",
                    default="/mnt/storage/llama-models/qwen35-9b/"
                            "Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--tensor", default=None,
                    help="GGUF tensor name (default: from the .mv4i filename)")
    ap.add_argument("--token", type=int, default=None)
    ap.add_argument("--recipe", choices=(RECIPE_D32, RECIPE_WIDE),
                    default=RECIPE_WIDE)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--compare", action="store_true",
                    help="both recipes against the GGUF, side by side")
    ap.add_argument("--mutate", action="store_true")
    ap.add_argument("--separation", action="store_true",
                    help="measure the populations RELERR_MAX/CORR_MIN sit "
                         "between, rather than asserting them")
    ap.add_argument("--n", type=int, default=48)
    ap.add_argument("--no-gguf", action="store_true")
    a = ap.parse_args(argv)

    pt = PackedTensor(a.mv4i)
    tensor = a.tensor or os.path.basename(a.mv4i)[:-len(".mv4i")]
    gguf = None if a.no_gguf else a.gguf
    if gguf and not os.path.exists(gguf):
        sys.stderr.write("gguf %s not present; continuing without the "
                         "external oracle\n" % gguf)
        gguf = None

    if a.token is not None:
        mant, xe = pt.row_bfp(a.token, "direct", a.recipe)
        v, ve = pt.row_int(a.token, "direct", a.recipe)
        print("token         %d" % a.token)
        print("geometry      M=%d K=%d ROWS_IF=%d AXI_DW=%d nb=%d w_exp=%d"
              % (pt.h.M, pt.h.K, pt.h.rows_if, pt.h.axi_dw, pt.nb, pt.h.w_exp))
        t, rr = divmod(a.token, pt.h.rows_if)
        print("addressing    tile=%d row_in_tile=%d w_sub=%d half=%d "
              "s_sub=%d s_idx=%d"
              % (t, rr, rr // pt.rows_per_beat, rr % pt.rows_per_beat,
                 rr // pt.scales_per_beat, rr % pt.scales_per_beat))
        print("weight read   0x%X .. 0x%X (%d bytes, contiguous)"
              % (pt.w_off[rr // pt.rows_per_beat] + t * pt.nb * pt.port_b,
                 pt.w_off[rr // pt.rows_per_beat] + (t + 1) * pt.nb * pt.port_b,
                 pt.nb * pt.port_b))
        print("scale read    0x%X .. 0x%X (%d bytes, contiguous)"
              % (pt.s_off[rr // pt.scales_per_beat] + t * pt.nb * pt.port_b,
                 pt.s_off[rr // pt.scales_per_beat] + (t + 1) * pt.nb * pt.port_b,
                 pt.nb * pt.port_b))
        print("recipe        %s   val_exp=%d" % (a.recipe, ve))
        print("x_exp         %d   (value = mant * 2^-x_exp)" % xe)
        print("mant[0:8]     %s" % " ".join(str(x) for x in mant[:8]))
        print("amax(mant)    %d" % max(abs(x) for x in mant))
        return 0

    toks = sample_tokens(pt.h.M, a.n)

    if a.compare:
        if not gguf:
            sys.stderr.write("--compare needs the GGUF\n")
            return 2
        ref = gguf_rows(gguf, tensor, toks)
        print("%-8s %-14s %-14s" % ("", RECIPE_D32, RECIPE_WIDE))
        worst = {RECIPE_D32: 0.0, RECIPE_WIDE: 0.0}
        tot = {RECIPE_D32: 0.0, RECIPE_WIDE: 0.0}
        n = 0
        for tok in toks:
            exact = ref[tok]
            if float(np.linalg.norm(exact)) == 0.0:
                continue
            row = []
            for rec in (RECIPE_D32, RECIPE_WIDE):
                m, xe = pt.row_bfp(tok, "direct", rec)
                e = relerr(bfp_to_float(m, xe), exact)
                worst[rec] = max(worst[rec], e)
                tot[rec] += e
                row.append(e)
            n += 1
        print("rows compared %d" % n)
        for rec in (RECIPE_D32, RECIPE_WIDE):
            print("%-10s mean relerr %.5f   worst %.5f"
                  % (rec, tot[rec] / n, worst[rec]))
        print("ratio       d32 / wide mean = %.3fx"
              % ((tot[RECIPE_D32] / n) / (tot[RECIPE_WIDE] / n)))
        return 0

    if a.separation:
        if not gguf:
            sys.stderr.write("--separation needs the GGUF\n")
            return 2
        return 0 if separation(pt, gguf, tensor, toks, a.recipe) else 1

    if a.mutate:
        return 0 if run_mutations(pt, gguf, tensor, toks, a.recipe) else 1

    if a.selftest:
        r = selftest(pt, gguf, tensor, toks, a.recipe)
        print("tokens checked          %d" % r["n"])
        print("direct vs reassemble    %d mismatches" % r["decoder_mismatch"])
        print("bfp pack disagreement   %d" % r["bfp_mismatch"])
        if gguf:
            print("checked against GGUF    %d (%d all-zero rows skipped)"
                  % (r["gguf_checked"], r["zero_rows"]))
            print("worst relative error    %.5f" % r["gguf_worst"])
            print("worst correlation       %.5f" % r["corr_worst"])
            print("rows the GGUF rejects   %d" % r["gguf_bad"])
        gate = GATEABLE.get(a.recipe, False)
        if gguf and not gate:
            print("NOTE  the GGUF gate is ADVISORY for recipe %s: its matched "
                  "and mismatched populations overlap (see --separation), so "
                  "`rows the GGUF rejects` above is reported, not enforced."
                  % a.recipe)
        ok = (r["decoder_mismatch"] == 0 and r["bfp_mismatch"] == 0
              and (r["gguf_bad"] == 0 or not gate))
        print("SELFTEST %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1

    ap.error("one of --token, --selftest, --compare, --mutate")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DescError as e:
        sys.stderr.write("embed_gather: %s\n" % e)
        sys.exit(2)
