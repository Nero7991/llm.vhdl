#!/usr/bin/env python3
"""Pack subsystem B's four learned GDN constants into the HBM image the card
reads them from, and declare where that image lives.

    pack_gdn_consts.py --gguf G --manifest M --out DIR/gdn_const.bin
                       [--hex PATH] [--shape 9b|sim] [--blocks N]
                       [--attn-interval N] [--norm-reduce mean|slice]
                       [--check]
    pack_gdn_consts.py --selftest

THE CONTRACT is docs/2026-09-18_b-constants-path.md, and this file is its
Track B.  Until that document, every configuration of rtl/llama_top.vhd
served the conv weights, ssm_dt_bias, ssm_a and the ssm_norm gain from `m12`,
a hash, on the card as much as in the bench.  A 1.5 MiB ROM does not fit
(449.5 of 672 BRAM tiles in use), so the constants go to HBM per layer and
rtl/gdn_state_store.vhd fetches them as a fourth, load-only phase of its
per-job sequence.  This tool writes that region and nothing else about the
model changes: the weights, the GDN state, kv_base, the descriptor arena and
the host blocks all keep their addresses, and the image is paid for out of
the KV arena's top, the account the descriptor arena already draws on.

THE PER-LAYER IMAGE, every field a little-endian int16, at the 9B shape:

    0x00000 .. 0x0FFFF  conv weights, word[t*QKVN + ch] = W[ch][t]
                        t = 0 OLDEST tap .. KCONV-1 NEWEST (this token's
                        column), ch in q | k | v order (q 0..2047, k
                        2048..4095, v 4096..8191)
    0x10000 .. 0x1003F  ssm_dt_bias[32]        Q(dt_e)
    0x10040 .. 0x1007F  ssm_a[32]              Q(a_e), every value <= 0
    0x10080 .. 0x1017F  ssm_norm[128]          Q(w_exp)
    0x10180             cw_exp[0]  (q)         int16
    0x10182             cw_exp[1]  (k)
    0x10184             cw_exp[2]  (v)
    0x10186             dt_e
    0x10188             a_e
    0x1018A             w_exp
    0x1018C .. 0x101FF  zero

66048 B = 129 bursts of 512 B; layer L (the GDN ordinal `js_layer`, 0..23,
NOT the block index) at `gdn_const_base + L * 66048`.  At the sim shape
(`mk_shape_scaled`: KCONV 4, QKVN 256, VAL_HEADS 4, DIM 32) the same layout
holds with those dimensions and a 2560 B layer.

WHERE THE AXIS ORDER COMES FROM, because a transposed conv weight is a wrong
number with no structural symptom.  Three sources were read and they agree:

  * `ref/run9b.c:612-613` (the rung-3 reference) indexes the flat GGUF tensor
    as `cw[c * KCONV + i]`, multiplies taps `i < KCONV-1` against the stored
    OLDER columns and tap `KCONV-1` against `mixed`, this token's column.
  * The gguf reader presents `blk.L.ssm_conv1d.weight` (ne = [4, 8192],
    ne0 fastest) as `data.shape == (8192, 4)`, so `data[ch, t]` IS
    `cw[ch*KCONV + t]`; MEASURED 2026-09-18 on Qwen3.5-9B-BF16.gguf.
  * `rtl/llama_top.vhd`'s `cvdata_p` fills bit slice `(t*LANES + ln)*16` with
    tap t for lane ln and takes `t = KC-1` from `qkv_b`, the current column.

So `W[ch][t] = data[ch, t]`, newest last, and the packer never transposes.

THE EXPONENTS are chosen PER VECTOR PER LAYER (three conv segments, dt, a,
norm) as the largest `e` in [-64, 63] with `max|v| * 2^e <= 32767`, and are
written into the image, so the RTL never assumes a scale.  Every exponent is
a count of fraction bits, `value = mant * 2^-e`, which is
`gdn_scalar.to_q_wide`'s convention (rtl/gdn_scalar.vhd:161-173).

`--shape sim` packs the SAME layout at `mk_shape_scaled` from the 9B tensors
REDUCED the way `tools/gen_llama_top_weights.py` reduces the A weights the
bench runs against: a conv weight, a dt bias and an ssm_a are per-OUTPUT-ROW
quantities of A jobs whose rows that tool SLICES (`W[r0:r0+rows]`), so they
are sliced here the same way -- sim channel c of segment s is real channel
`real_seg_base[s] + c`, sim head h is real head h.  The ssm_norm gain is a
per-DIM vector and takes `reduce_gain()` from the same tool, MEAN by default:
its docstring has the arithmetic for why a copied `sum` is wrong by K/n.

`--selftest` needs no GGUF.  It packs a fake 9B model from random floats and
checks the image against the CONTRACT'S LITERAL BYTE OFFSETS (0x10000,
0x10040, 0x10080, 0x10180, 66048), not against this file's own variables;
then it runs seven mutant packers -- taps reversed, channel-major, exponent
off by one, dt/a swapped, layers in block order, pad not zero, exponent as a
byte -- and requires each to be caught, reporting WHICH check caught it.

NO HARDWARE.  This opens the GGUF read-only (mmap; the 18 GB file is never
read past the four small tensors per layer) and writes two files and one
manifest.
"""

import argparse
import datetime
import hashlib
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hbm_map as HM                     # noqa: E402  the ONE HBM address space
import gen_layer_program as GLP          # noqa: E402  the ONE layer enumeration
from gen_llama_top_weights import reduce_gain   # noqa: E402  the ONE gain rule

SCALAR_WORDS = HM.GDN_CONST_SCALAR_WORDS          # 256 words = 512 B
N_EXP = HM.GDN_CONST_N_EXP                        # 6
BURST = HM.GDN_CONST_BURST_BYTES                  # 512
EXP_MIN, EXP_MAX = -64, 63
MANT_MAX = 32767
# rtl/llama_map_pkg.vhd mk_shape_scaled: conv_kernel => 4 in both branches.
SIM_KCONV = 4
DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"

# The four tensors, in the order they appear in the scalar block.
T_CONV = "blk.%d.ssm_conv1d.weight"
T_DT = "blk.%d.ssm_dt.bias"
T_A = "blk.%d.ssm_a"
T_NORM = "blk.%d.ssm_norm.weight"


# ------------------------------------------------------------------ layout

class Layout(object):
    """The per-layer image's geometry, from a shape.  Every offset below is
    DERIVED from (kconv, key_dim, val_dim, val_heads, dim); the selftest is
    what compares them with the contract's literal numbers."""

    def __init__(self, shape, kconv, name):
        self.name = name
        self.shape = shape
        self.kconv = int(kconv)
        self.key_dim = int(shape.key_dim)
        self.val_dim = int(shape.val_dim)
        self.qkvn = 2 * self.key_dim + self.val_dim
        self.val_heads = int(shape.val_heads)
        self.dim = int(shape.head_dim)
        self.seg_base = (0, self.key_dim, 2 * self.key_dim)
        self.seg_n = (self.key_dim, self.key_dim, self.val_dim)
        self.conv_words = self.kconv * self.qkvn
        self.words = self.conv_words + SCALAR_WORDS
        self.bytes_per_layer = 2 * self.words
        # word offsets of the scalar block
        self.w_dt = self.conv_words
        self.w_a = self.w_dt + self.val_heads
        self.w_norm = self.w_a + self.val_heads
        self.w_exp = self.w_norm + self.dim
        used = 2 * self.val_heads + self.dim + N_EXP
        if used > SCALAR_WORDS:
            raise SystemExit("pack_gdn_consts: the scalar block needs %d "
                             "words at shape %s, the contract gives 256"
                             % (used, name))
        if self.bytes_per_layer % BURST:
            raise SystemExit("pack_gdn_consts: %d B per layer at shape %s is "
                             "not a multiple of the %d B burst"
                             % (self.bytes_per_layer, name, BURST))
        self.blocks = [b for b in range(shape.blocks) if not shape.is_attn(b)]
        self.layers = len(self.blocks)
        self.bytes_total = self.layers * self.bytes_per_layer

    def describe(self):
        return ("shape %s: KCONV %d, QKVN %d (q %d | k %d | v %d), VAL_HEADS "
                "%d, DIM %d; %d words = %d B per layer (%d bursts), %d GDN "
                "layers = %d B"
                % (self.name, self.kconv, self.qkvn, self.key_dim,
                   self.key_dim, self.val_dim, self.val_heads, self.dim,
                   self.words, self.bytes_per_layer,
                   self.bytes_per_layer // BURST, self.layers,
                   self.bytes_total))


def layout_real(name="QWEN35_9B", ncards=1):
    """The real shape for a named rtl/model_cfg_pkg.vhd record (2026-09-23:
    generalised from layout_9b; the 27B row is gen_layer_program.QWEN38_27B).
    Same two-authority cross-check as before."""
    shapes = {"QWEN35_9B": GLP.QWEN35_9B, "QWEN38_27B": GLP.QWEN38_27B}
    if name not in shapes:
        raise SystemExit("pack_gdn_consts: no gen_layer_program Shape for %s"
                         % name)
    cfg = HM.scrape_model_cfg(name)
    s = shapes[name]
    pairs = (("blocks", s.blocks), ("attn_interval", s.attn_interval),
             ("lin_key_heads", s.key_heads), ("lin_val_heads", s.val_heads),
             ("lin_head_dim", s.head_dim))
    bad = [(k, cfg[k], v) for k, v in pairs if cfg[k] != v]
    if bad:
        raise SystemExit("pack_gdn_consts: rtl/model_cfg_pkg.vhd and "
                         "tools/gen_layer_program.py disagree on the %s "
                         "shape: %r" % (name, bad))
    if ncards != 1:
        raise SystemExit("pack_gdn_consts: only NCARDS = 1 is packed; the "
                         "per-card head split is out of scope")
    lay = Layout(s, cfg["conv_kernel"], name)
    sz = HM.arena_sizes(cfg, ncards)
    if (lay.bytes_per_layer, lay.layers, lay.bytes_total) != (
            sz["gdn_const_bytes_per_layer"], sz["gdn_const_layers"],
            sz["gdn_const_bytes"]):
        raise SystemExit("pack_gdn_consts: this layout (%d B x %d) disagrees "
                         "with hbm_map.arena_sizes() (%d B x %d)"
                         % (lay.bytes_per_layer, lay.layers,
                            sz["gdn_const_bytes_per_layer"],
                            sz["gdn_const_layers"]))
    return lay


SHAPE_RECORD = {"9b": "QWEN35_9B", "27b": "QWEN38_27B"}


def layout_9b(ncards=1):
    """The real shape, from BOTH authorities, cross-checked: rtl/model_cfg_pkg
    (via hbm_map's scrape, which is where KCONV lives) and
    gen_layer_program.QWEN35_9B (which is where the GDN layer enumeration
    lives).  They are two transcriptions of one record and a drift between
    them is a refusal, not a preference."""
    cfg = HM.scrape_model_cfg("QWEN35_9B")
    s = GLP.QWEN35_9B
    pairs = (("blocks", s.blocks), ("attn_interval", s.attn_interval),
             ("lin_key_heads", s.key_heads), ("lin_val_heads", s.val_heads),
             ("lin_head_dim", s.head_dim))
    bad = [(k, cfg[k], v) for k, v in pairs if cfg[k] != v]
    if bad:
        raise SystemExit("pack_gdn_consts: rtl/model_cfg_pkg.vhd and "
                         "tools/gen_layer_program.py disagree on the 9B "
                         "shape: %r" % bad)
    if ncards != 1:
        raise SystemExit("pack_gdn_consts: only NCARDS = 1 is packed; the "
                         "per-card head split is out of scope")
    lay = Layout(s, cfg["conv_kernel"], "9b")
    sz = HM.arena_sizes(cfg, ncards)
    if (lay.bytes_per_layer, lay.layers, lay.bytes_total) != (
            sz["gdn_const_bytes_per_layer"], sz["gdn_const_layers"],
            sz["gdn_const_bytes"]):
        raise SystemExit("pack_gdn_consts: this layout (%d B x %d) disagrees "
                         "with hbm_map.arena_sizes() (%d B x %d)"
                         % (lay.bytes_per_layer, lay.layers,
                            sz["gdn_const_bytes_per_layer"],
                            sz["gdn_const_layers"]))
    return lay


def layout_sim(blocks, attn_interval):
    return Layout(GLP.mk_shape_scaled(blocks, attn_interval), SIM_KCONV,
                  "sim(blocks=%d,attn_interval=%d)" % (blocks, attn_interval))


# ------------------------------------------------------------ fixed point

def choose_exp(vals):
    """The largest e in [EXP_MIN, EXP_MAX] with max|v| * 2^e <= 32767.
    Powers of two are exact in binary floating point, so the comparison is
    the same arithmetic the check performs and cannot round differently."""
    m = float(np.max(np.abs(np.asarray(vals, dtype=np.float64)))) \
        if np.size(vals) else 0.0
    if m == 0.0:
        return EXP_MAX
    e = int(np.floor(np.log2(MANT_MAX / m)))
    while m * 2.0 ** (e + 1) <= MANT_MAX:
        e += 1
    while m * 2.0 ** e > MANT_MAX:
        e -= 1
    return max(EXP_MIN, min(EXP_MAX, e))


def quant(vals, e):
    q = np.rint(np.asarray(vals, dtype=np.float64) * 2.0 ** e)
    if np.any(np.abs(q) > MANT_MAX):
        raise SystemExit("pack_gdn_consts: a value overflows int16 at e=%d "
                         "(max |q| %d); choose_exp is wrong" % (e, np.abs(q).max()))
    return q.astype(np.int64)


# ------------------------------------------------------------------ sources

class GgufSource(object):
    """The four constants of one block, as float64 arrays in the GGUF's own
    (M, K) order.  Opened once; the reader mmaps the file, so this never
    holds more than the four small tensors of one layer."""

    def __init__(self, path):
        from gguf import GGUFReader
        self.path = path
        self.rd = GGUFReader(path, "r")
        self.by_name = {t.name: t for t in self.rd.tensors}

    def get(self, name):
        t = self.by_name.get(name)
        if t is None:
            raise SystemExit("pack_gdn_consts: %s is not in %s"
                             % (name, self.path))
        if not str(t.tensor_type).endswith("F32"):
            raise SystemExit("pack_gdn_consts: %s is %s, expected F32; the "
                             "constants are stored unquantised in this set"
                             % (name, t.tensor_type))
        ne = [int(x) for x in t.shape]
        arr = np.asarray(t.data, dtype=np.float64)
        # ne0 is the fastest axis, so a 2-D tensor is (ne1, ne0) row-major.
        return arr.reshape(*reversed(ne)) if len(ne) > 1 else arr.reshape(-1)


class DictSource(object):
    def __init__(self, d, path="<dict>"):
        self.d, self.path = d, path

    def get(self, name):
        if name not in self.d:
            raise SystemExit("pack_gdn_consts: %s is not in the source" % name)
        return np.asarray(self.d[name], dtype=np.float64)


def read_block(src, b, real, want=None):
    """(W (QKVN, KCONV), dt (VH), a (VH), norm (DIM)) for block b, with the
    shapes checked against `real`, the layout of the model they came from."""
    W = src.get(T_CONV % b)
    dt = src.get(T_DT % b)
    a = src.get(T_A % b)
    nw = src.get(T_NORM % b)
    want = want or {}
    exp = dict(conv=(real.qkvn, real.kconv), dt=(real.val_heads,),
               a=(real.val_heads,), norm=(real.dim,))
    for nm, arr in (("conv", W), ("dt", dt), ("a", a), ("norm", nw)):
        if tuple(arr.shape) != exp[nm]:
            raise SystemExit(
                "pack_gdn_consts: blk.%d %s has shape %r, the %s shape wants "
                "%r.  The reader's `data` for a GGUF ne=[K, M] tensor is (M, K); "
                "a (KCONV, QKVN) here would mean the axes are transposed."
                % (b, nm, tuple(arr.shape), real.name, exp[nm]))
    if np.any(a > 0):
        raise SystemExit("pack_gdn_consts: blk.%d ssm_a has a positive entry "
                         "(max %g); the model's ssm_a is -exp(A_log) and the "
                         "RTL's decay never amplifies" % (b, float(a.max())))
    return W, dt, a, nw


def reduce_block(W, dt, a, nw, real, lay, norm_reduce):
    """The 9B constants at the sim shape.  Row SLICES for the three
    per-row quantities, `reduce_gain` for the per-dim gain; see the header."""
    Ws = np.zeros((lay.qkvn, lay.kconv))
    for s in range(3):
        rb, n, sb = real.seg_base[s], lay.seg_n[s], lay.seg_base[s]
        Ws[sb:sb + n, :] = W[rb:rb + n, :lay.kconv]
    return (Ws, dt[:lay.val_heads], a[:lay.val_heads],
            reduce_gain(nw, lay.dim, norm_reduce))


# ------------------------------------------------------------------ packing

def pack_layer(lay, W, dt, a, nw, mutant=None):
    """One layer's image as bytes, plus the six exponents.  `mutant` is the
    selftest's knob and is None on every real call."""
    words = np.zeros(lay.words, dtype=np.int64)
    cw_e = []
    for s in range(3):
        sb, n = lay.seg_base[s], lay.seg_n[s]
        e = choose_exp(W[sb:sb + n, :])
        if mutant == "exp_plus_one":
            e += 1
            q = np.clip(np.rint(W[sb:sb + n, :] * 2.0 ** e), -32768, 32767)
        elif mutant == "round_half_up":
            q = np.floor(W[sb:sb + n, :] * 2.0 ** e + 0.5).astype(np.int64)
        else:
            q = quant(W[sb:sb + n, :], e)          # (n, KCONV): [ch][t]
        cw_e.append(e)
        for t in range(lay.kconv):
            tt = (lay.kconv - 1 - t) if mutant == "taps_reversed" else t
            if mutant == "channel_major":
                for c in range(n):
                    words[(sb + c) * lay.kconv + t] = q[c, tt]
            else:
                words[t * lay.qkvn + sb:t * lay.qkvn + sb + n] = q[:, tt]
    dt_e, a_e, w_e = choose_exp(dt), choose_exp(a), choose_exp(nw)
    qdt, qa, qw = quant(dt, dt_e), quant(a, a_e), quant(nw, w_e)
    if mutant == "dt_a_swapped":
        qdt, qa, dt_e, a_e = qa, qdt, a_e, dt_e
    words[lay.w_dt:lay.w_dt + lay.val_heads] = qdt
    words[lay.w_a:lay.w_a + lay.val_heads] = qa
    words[lay.w_norm:lay.w_norm + lay.dim] = qw
    exps = cw_e + [dt_e, a_e, w_e]
    if mutant == "exp_as_byte":
        # two exponents per word, low byte first: the packing a "the RTL only
        # reads the low byte" reading of the contract could produce
        for i in range(0, N_EXP, 2):
            words[lay.w_exp + i // 2] = (exps[i] & 0xFF) | ((exps[i + 1] & 0xFF) << 8)
    else:
        words[lay.w_exp:lay.w_exp + N_EXP] = exps
    if mutant == "pad_not_zero":
        words[lay.w_exp + N_EXP:] = 0x7FFF
    return words.astype("<i2").tobytes(), exps


def pack_image(lay, src, real=None, norm_reduce="mean", mutant=None,
               log=None):
    """Every GDN layer in schedule order.  `real` is the source model's
    layout when `lay` is a reduced shape; None packs `lay` from itself."""
    real = real or lay
    out, exps = [], []
    order = list(lay.blocks)
    if mutant == "layer_by_block":
        # ordinal L holds block L's constants -- an attention block's slot
        # is an empty image -- which is exactly what a `blk.L` for L in
        # range(blocks) loop produces.  Blocks past the GDN count are dropped
        # so the total size still agrees.
        order = [b for b in range(lay.shape.blocks)][:lay.layers]
    for L, b in enumerate(order):
        if lay.shape.is_attn(b):
            img, ex = bytes(lay.bytes_per_layer), [0] * N_EXP
        else:
            W, dt, a, nw = read_block(src, b, real)
            if lay is not real:
                W, dt, a, nw = reduce_block(W, dt, a, nw, real, lay,
                                            norm_reduce)
            img, ex = pack_layer(lay, W, dt, a, nw, mutant)
        if len(img) != lay.bytes_per_layer:
            raise SystemExit("pack_gdn_consts: layer %d packed to %d B, "
                             "layout says %d" % (L, len(img),
                                                 lay.bytes_per_layer))
        out.append(img)
        exps.append(ex)
        if log:
            log("layer %2d = blk.%-2d  cw_exp q/k/v %2d %2d %2d  dt_e %2d  "
                "a_e %2d  w_exp %2d" % ((L, b) + tuple(ex)))
    return b"".join(out), exps


def write_hex(path, image):
    """The same image as text: one 16-bit word per line, 4 hex digits two's
    complement, word 0 first, all layers back to back, no header -- the
    format rtl/llama_top.vhd reads NORM_W_IMAGE in."""
    w = np.frombuffer(image, dtype="<u2")
    with open(path, "w") as f:
        for v in w:
            f.write("%04x\n" % int(v))
    return len(w)


def digest(image):
    return hashlib.blake2b(image, digest_size=16).hexdigest()


# --------------------------------------------------------- the value check
#
# NOT a byte compare.  `decode_layer` reads the image at the contract's
# offsets, derived from the four dimensions only, and `check_values` compares
# what it reads against the SOURCE FLOATS within half a quantum.  That is the
# oracle: an image whose decoded values agree with the model is right, and
# one produced by a packer that agrees with itself is not thereby right.

def decode_layer(buf, lay):
    w = np.frombuffer(buf, dtype="<i2").astype(np.int64)
    if w.size != lay.words:
        raise ValueError("layer is %d words, layout says %d" % (w.size, lay.words))
    exps = [int(x) for x in w[lay.w_exp:lay.w_exp + N_EXP]]
    if any(e < EXP_MIN or e > EXP_MAX for e in exps):
        raise ValueError("exponent word(s) %r outside [%d, %d]; the six "
                         "exponents are one int16 each" % (exps, EXP_MIN,
                                                            EXP_MAX))
    conv = np.zeros((lay.qkvn, lay.kconv))
    for s in range(3):
        sb, n = lay.seg_base[s], lay.seg_n[s]
        for t in range(lay.kconv):
            conv[sb:sb + n, t] = w[t * lay.qkvn + sb:t * lay.qkvn + sb + n] \
                * 2.0 ** -exps[s]
    dt = w[lay.w_dt:lay.w_dt + lay.val_heads] * 2.0 ** -exps[3]
    a = w[lay.w_a:lay.w_a + lay.val_heads] * 2.0 ** -exps[4]
    nw = w[lay.w_norm:lay.w_norm + lay.dim] * 2.0 ** -exps[5]
    pad = w[lay.w_exp + N_EXP:]
    return conv, dt, a, nw, exps, pad


def check_values(image, lay, src, real=None, norm_reduce="mean"):
    """Every finding is a string; empty is PASS."""
    real = real or lay
    bad = []
    if len(image) != lay.bytes_total:
        return ["image is %d B, the layout says %d x %d = %d"
                % (len(image), lay.layers, lay.bytes_per_layer,
                   lay.bytes_total)]
    for L, b in enumerate(lay.blocks):
        buf = image[L * lay.bytes_per_layer:(L + 1) * lay.bytes_per_layer]
        try:
            conv, dt, a, nw, exps, pad = decode_layer(buf, lay)
        except ValueError as e:
            bad.append("layer %d (blk.%d): %s" % (L, b, e))
            continue
        W, sdt, sa, snw = read_block(src, b, real)
        if lay is not real:
            W, sdt, sa, snw = reduce_block(W, sdt, sa, snw, real, lay,
                                           norm_reduce)
        for s in range(3):
            sb, n = lay.seg_base[s], lay.seg_n[s]
            tol = 2.0 ** -(exps[s] + 1) + 1e-12
            err = np.abs(conv[sb:sb + n, :] - W[sb:sb + n, :])
            if err.max() > tol:
                i = np.unravel_index(err.argmax(), err.shape)
                bad.append("layer %d (blk.%d) conv seg %d: decoded %g at "
                           "[ch %d][t %d], source %g (tol %g, e=%d)"
                           % (L, b, s, conv[sb + i[0], i[1]], i[0], i[1],
                              W[sb + i[0], i[1]], tol, exps[s]))
            want_e = choose_exp(W[sb:sb + n, :])
            if exps[s] != want_e:
                bad.append("layer %d conv seg %d: exponent %d, the rule "
                           "gives %d" % (L, s, exps[s], want_e))
        for nm, got, want, e in (("dt", dt, sdt, exps[3]),
                                 ("a", a, sa, exps[4]),
                                 ("norm", nw, snw, exps[5])):
            tol = 2.0 ** -(e + 1) + 1e-12
            err = np.abs(got - want)
            if err.max() > tol:
                i = int(err.argmax())
                bad.append("layer %d (blk.%d) %s[%d]: decoded %g, source %g "
                           "(tol %g, e=%d)" % (L, b, nm, i, got[i], want[i],
                                               tol, e))
            if e != choose_exp(want):
                bad.append("layer %d %s: exponent %d, the rule gives %d"
                           % (L, nm, e, choose_exp(want)))
        if np.any(pad != 0):
            bad.append("layer %d: %d nonzero words in the zero pad"
                       % (L, int(np.count_nonzero(pad))))
        if np.any(a > 0):
            bad.append("layer %d: a positive ssm_a" % L)
    return bad


# ----------------------------------------------------------- the manifest

MANIFEST_KEYS = ("gdn_const_base", "gdn_const_bytes", "gdn_const_stack",
                 "gdn_const_layers", "gdn_const_bytes_per_layer",
                 "gdn_const_words_per_layer")


def manifest_extra(lay, image, out_path, mani_path, gguf, exps):
    rel = os.path.relpath(os.path.abspath(out_path),
                          os.path.dirname(os.path.abspath(mani_path)))
    if rel.startswith(".."):
        raise SystemExit("pack_gdn_consts: --out %s is not beside the "
                         "manifest; hw/fk33/host/fk33_load_weights.py "
                         "resolves hbm.gdn_const_file relative to the "
                         "manifest's directory like every other file"
                         % out_path)
    return dict(gdn_const_file=rel, gdn_const_blake2b_128=digest(image),
                gdn_const_source_gguf=os.path.abspath(gguf),
                gdn_const_generated=datetime.datetime.now().isoformat(
                    timespec="seconds"),
                gdn_const_exponents=[list(map(int, e)) for e in exps],
                gdn_const_layout="docs/2026-09-18_b-constants-path.md, "
                                 "tools/pack_gdn_consts.py")


def check_manifest(mani, lay, image, out_path, mani_path):
    """The manifest's declaration against the re-derivation."""
    bad = []
    hbm = mani.get("hbm") or {}
    missing = [k for k in MANIFEST_KEYS + ("gdn_const_blake2b_128",
                                           "gdn_const_file") if k not in hbm]
    if missing:
        return ["the manifest declares no %s; run without --check to pack "
                "and declare the region" % ", ".join(missing)]
    blk = HM.derive_gdn_const_block(mani)
    for k in MANIFEST_KEYS + ("free_after_gdn", "max_context_tokens"):
        if int(hbm[k]) != int(blk[k]):
            bad.append("hbm.%s is %s, the allocator derives %s"
                       % (k, hbm[k], blk[k]))
    if hbm["kv_extents"] != blk["kv_extents"]:
        bad.append("hbm.kv_extents are not the re-capped extents the "
                   "allocator derives")
    if int(hbm["gdn_const_bytes"]) != lay.bytes_total:
        bad.append("hbm.gdn_const_bytes %s, the image is %d B"
                   % (hbm["gdn_const_bytes"], lay.bytes_total))
    if hbm["gdn_const_blake2b_128"] != digest(image):
        bad.append("hbm.gdn_const_blake2b_128 is %s, the re-packed image "
                   "hashes to %s" % (hbm["gdn_const_blake2b_128"],
                                     digest(image)))
    rel = os.path.relpath(os.path.abspath(out_path),
                          os.path.dirname(os.path.abspath(mani_path)))
    if hbm["gdn_const_file"] != rel:
        bad.append("hbm.gdn_const_file is %r, --out is %r relative to the "
                   "manifest" % (hbm["gdn_const_file"], rel))
    return bad


# ------------------------------------------------------------------ main

def run(a):
    if a.shape in SHAPE_RECORD:
        lay, real = layout_real(SHAPE_RECORD[a.shape]), None
        if not a.manifest:
            raise SystemExit("pack_gdn_consts: --shape %s needs --manifest"
                             % a.shape)
    else:
        real = layout_9b()
        lay = layout_sim(a.blocks, a.attn_interval)
    print(lay.describe())
    src = GgufSource(a.gguf)
    image, exps = pack_image(lay, src, real, a.norm_reduce, log=print)
    print("image %d B, blake2b-128 %s" % (len(image), digest(image)))
    vb = check_values(image, lay, src, real, a.norm_reduce)
    for s in vb:
        print("FAIL  " + s)
    if vb:
        print("%d FAIL  the packed image does not decode to the source"
              % len(vb))
        return 1
    print("PASS  every decoded value is within half a quantum of the source "
          "and every exponent is the rule's")

    if a.check:
        bad = []
        try:
            with open(a.out, "rb") as f:
                on_disk = f.read()
        except OSError as e:
            bad.append("cannot read %s: %s" % (a.out, e))
            on_disk = None
        if on_disk is not None and on_disk != image:
            n = sum(1 for x, y in zip(on_disk, image) if x != y) \
                + abs(len(on_disk) - len(image))
            bad.append("%s differs from the re-packed image in %d byte(s)"
                       % (a.out, n))
        if a.hex:
            try:
                with open(a.hex) as f:
                    hx = f.read()
                want = "".join("%04x\n" % int(v) for v in
                               np.frombuffer(image, dtype="<u2"))
                if hx != want:
                    bad.append("%s is not the re-packed image as hex" % a.hex)
            except OSError as e:
                bad.append("cannot read %s: %s" % (a.hex, e))
        if a.manifest:
            with open(a.manifest) as f:
                mani = json.load(f)
            bad += check_manifest(mani, lay, image, a.out, a.manifest)
        for s in bad:
            print("FAIL  " + s)
        if bad:
            print("%d FAIL" % len(bad))
            return 1
        print("CHECK PASS  %s%s%s re-derive to the same bytes and the same "
              "declaration" % (a.out, " + " + a.hex if a.hex else "",
                               " + " + a.manifest if a.manifest else ""))
        return 0

    with open(a.out, "wb") as f:
        f.write(image)
    print("wrote %s: %d B" % (a.out, len(image)))
    if a.hex:
        n = write_hex(a.hex, image)
        print("wrote %s: %d words" % (a.hex, n))
    if a.manifest and a.shape in SHAPE_RECORD:
        with open(a.manifest) as f:
            mani = json.load(f)
        blk = HM.derive_gdn_const_block(mani)
        hbm = mani.get("hbm") or {}
        if hbm.get("gdn_const_base") is not None and \
                int(hbm["gdn_const_base"]) != blk["gdn_const_base"]:
            raise SystemExit(
                "pack_gdn_consts: the manifest already declares "
                "gdn_const_base %s and the allocator derives %s.  Nothing "
                "placed moves on a repack; if the region block changed "
                "underneath this image, say so and re-place deliberately."
                % (HM.h(int(hbm["gdn_const_base"])), HM.h(blk["gdn_const_base"])))
        extra = manifest_extra(lay, image, a.out, a.manifest, a.gguf, exps)
        before, bak = HM.write_gdn_const_block(a.manifest, blk, extra)
        print("declared in %s (backup %s):" % (a.manifest, bak))
        for k in MANIFEST_KEYS + ("free_after_gdn", "max_context_tokens"):
            b = before.get(k)
            print("  %-28s %-14s -> %s"
                  % (k, "absent" if b is None else
                     (HM.h(int(b)) if "base" in k else b),
                     HM.h(blk[k]) if "base" in k else blk[k]))
        print("  %-28s %s" % ("gdn_const_blake2b_128", extra["gdn_const_blake2b_128"]))
        print("  %-28s %s" % ("gdn_const_file", extra["gdn_const_file"]))
    return 0


# ---------------------------------------------------------------- selftest

def _fake_model(real, seed=1):
    """Random constants at the 9B dimensions with the real tensors'
    magnitudes (MEASURED maxima: conv 1.234, dt 18.5, a 77.0, norm 1.318),
    for every block of the shape, attention blocks included so a packer that
    walks blocks instead of GDN layers has something to read."""
    rng = np.random.default_rng(seed)
    d = {}
    for b in range(real.shape.blocks):
        d[T_CONV % b] = rng.uniform(-1.234, 1.234, (real.qkvn, real.kconv)) \
            * (1.0 + 0.01 * b)
        d[T_DT % b] = rng.uniform(-18.5, 18.5, real.val_heads)
        d[T_A % b] = -rng.uniform(0.0, 77.0, real.val_heads)
        d[T_NORM % b] = rng.uniform(0.0, 1.318, real.dim)
    return DictSource(d, "<fake 9B, seed %d>" % seed)


def _contract_check(image, lay, src):
    """THE CONTRACT'S OWN NUMBERS, written as literals rather than taken from
    `Layout`, so this check and the packer cannot share a wrong offset.  Only
    meaningful at the 9B shape, where the contract states them."""
    QKVN, KCONV, VH, DIM, PER = 8192, 4, 32, 128, 66048
    OFF_DT, OFF_A, OFF_NORM, OFF_EXP, OFF_PAD = \
        0x10000, 0x10040, 0x10080, 0x10180, 0x1018C
    bad = []
    if len(image) != 24 * PER:
        return ["image is %d B, the contract says 24 x 66048 = %d"
                % (len(image), 24 * PER)]
    gdn_blocks = [b for b in range(32) if (b + 1) % 4 != 0]
    for L, b in enumerate(gdn_blocks):
        buf = image[L * PER:(L + 1) * PER]
        w = np.frombuffer(buf, dtype="<i2").astype(np.int64)
        ex = w[OFF_EXP // 2:OFF_EXP // 2 + 6]
        if np.any(ex < -64) or np.any(ex > 63):
            bad.append("layer %d: exponent words at 0x10180 are %s, not six "
                       "int16 in [-64, 63]" % (L, ex.tolist()))
            continue
        W = src.get(T_CONV % b)
        for s, (sb, n) in enumerate(((0, 2048), (2048, 2048), (4096, 4096))):
            q = np.rint(W[sb:sb + n, :] * 2.0 ** int(ex[s]))
            for t in range(KCONV):
                got = w[t * QKVN + sb:t * QKVN + sb + n]
                if not np.array_equal(got, q[:, t]):
                    bad.append("layer %d seg %d tap %d: word[t*QKVN+ch] is "
                               "not round(W[ch][t] * 2^cw_exp[seg])"
                               % (L, s, t))
                    break
            m = float(np.abs(W[sb:sb + n, :]).max())
            if not (m * 2.0 ** int(ex[s]) <= 32767 < m * 2.0 ** (int(ex[s]) + 1)):
                bad.append("layer %d seg %d: cw_exp %d is not the largest e "
                           "with max|W| * 2^e <= 32767" % (L, s, int(ex[s])))
        for nm, off, n, ei, tn in (("dt", OFF_DT, VH, 3, T_DT),
                                   ("a", OFF_A, VH, 4, T_A),
                                   ("norm", OFF_NORM, DIM, 5, T_NORM)):
            v = src.get(tn % b)
            q = np.rint(v * 2.0 ** int(ex[ei]))
            if not np.array_equal(w[off // 2:off // 2 + n], q):
                bad.append("layer %d: %s at 0x%05X is not round(v * 2^e)"
                           % (L, nm, off))
            m = float(np.abs(v).max())
            if not (m * 2.0 ** int(ex[ei]) <= 32767 < m * 2.0 ** (int(ex[ei]) + 1)):
                bad.append("layer %d: %s exponent %d is not the rule's"
                           % (L, nm, int(ex[ei])))
        if np.any(w[OFF_PAD // 2:] != 0):
            bad.append("layer %d: pad 0x1018C..0x101FF is not zero" % L)
    return bad


def selftest():
    hard = 0
    rows = []

    def row(name, ok, detail=""):
        nonlocal hard
        hard += (not ok)
        rows.append((name, ok, detail))

    real = layout_9b()
    row("9B layout reproduces the contract's 66048 B x 24 = 1585152 B",
        (real.bytes_per_layer, real.layers, real.bytes_total)
        == (66048, 24, 1585152),
        "%d x %d = %d" % (real.bytes_per_layer, real.layers, real.bytes_total))
    row("9B scalar offsets are 0x10000 / 0x10040 / 0x10080 / 0x10180",
        (2 * real.w_dt, 2 * real.w_a, 2 * real.w_norm, 2 * real.w_exp)
        == (0x10000, 0x10040, 0x10080, 0x10180))
    row("9B GDN blocks are the 24 with (b+1) mod 4 != 0",
        real.blocks == [b for b in range(32) if (b + 1) % 4],
        str(real.blocks[:6]) + "...")
    src = _fake_model(real)
    image, exps = pack_image(real, src)
    cc = _contract_check(image, real, src)
    row("clean 9B image passes the literal-offset contract check", not cc,
        cc[0] if cc else "")
    vb = check_values(image, real, src)
    row("clean 9B image decodes to the source within half a quantum", not vb,
        vb[0] if vb else "")
    row("the fake model's exponents come out as the contract expects "
        "(conv 14, dt 10, a 8, norm 14 at the measured maxima)",
        all(e[0] == 14 and e[3] == 10 and e[4] == 8 and e[5] == 14
            for e in exps[:1]), str(exps[0]))
    row("choose_exp clamps an all-zero vector to 63 and a 2^80 to -64",
        (choose_exp(np.zeros(4)), choose_exp([2.0 ** 80])) == (63, -64),
        str((choose_exp(np.zeros(4)), choose_exp([2.0 ** 80]))))
    row("choose_exp is exact at the boundary: 32767 -> 0, 32767.5 -> -1",
        (choose_exp([32767.0]), choose_exp([32767.5])) == (0, -1))

    # ---- the mutant packers, each against BOTH checks, with attribution.
    # `round_half_up` is the RESOLUTION FLOOR, stated in advance: it rounds
    # exact .5 products away from zero where `rint` rounds to even, which
    # differs only on a tie, and a tie needs a float64 product with every low
    # mantissa bit zero.  It is expected NOT to bite on random data and is
    # here so the floor has a name rather than being inferred.
    mut_rows = []
    for m, expect in (("taps_reversed", True), ("channel_major", True),
                      ("exp_plus_one", True), ("dt_a_swapped", True),
                      ("layer_by_block", True), ("pad_not_zero", True),
                      ("exp_as_byte", True), ("round_half_up", False)):
        try:
            img_m, _ = pack_image(real, src, mutant=m)
        except SystemExit as e:
            mut_rows.append((m, expect, True, "refused at pack: %s" % str(e)[:60]))
            hard += (not expect)
            continue
        c1 = _contract_check(img_m, real, src)
        c2 = check_values(img_m, real, src)
        caught = bool(c1) or bool(c2)
        by = ("contract+values" if c1 and c2 else "contract" if c1
              else "values" if c2 else "neither (the floor)")
        mut_rows.append((m, expect, caught,
                         by + (": " + (c1 or c2)[0][:70] if caught else "")))
        hard += (caught != expect)
    # a byte-identical clean re-pack: determinism, so --check can compare
    img2, _ = pack_image(real, src)
    row("packing is deterministic (two packs are byte-identical)",
        img2 == image)

    # ---- the sim shape
    lay = layout_sim(4, 4)
    row("sim layout is 2560 B per layer (5 x 512), 3 layers = 7680 B",
        (lay.bytes_per_layer, lay.layers, lay.bytes_total) == (2560, 3, 7680),
        lay.describe())
    simg, sexps = pack_image(lay, src, real, "mean")
    sb = check_values(simg, lay, src, real, "mean")
    row("sim image decodes to the REDUCED source within half a quantum",
        not sb, sb[0] if sb else "")
    # the reduction, checked against gen_llama_top_weights' rules directly
    W0 = src.get(T_CONV % 0)
    conv, dt, a, nw, ex, pad = decode_layer(simg[:2560], lay)
    row("sim conv channels are the sliced rows: sim v ch 5 is real ch 4101",
        abs(conv[128 + 5, 3] - W0[4096 + 5, 3]) <= 2.0 ** -(ex[2] + 1))
    row("sim norm gain is reduce_gain(..., 32, 'mean'), not a sum",
        np.abs(nw - reduce_gain(src.get(T_NORM % 0), 32, "mean")).max()
        <= 2.0 ** -(ex[5] + 1))
    simg_s, _ = pack_image(lay, src, real, "slice")
    row("--norm-reduce slice gives a different image from mean",
        simg_s != simg)
    lay32 = layout_sim(32, 4)
    row("sim at 32 blocks is 24 layers x 2560 = 61440 B",
        (lay32.layers, lay32.bytes_total) == (24, 61440))

    # ---- hex output
    import tempfile
    with tempfile.TemporaryDirectory(prefix="pack_gdn_consts_") as td:
        hp = os.path.join(td, "x.hex")
        n = write_hex(hp, simg)
        lines = open(hp).read().split("\n")[:-1]
        w = np.frombuffer(simg, dtype="<u2")
        row("hex file has one 4-digit word per line, word 0 first, "
            "little-endian words of the .bin",
            n == len(w) == len(lines) and lines[0] == "%04x" % w[0]
            and all(len(x) == 4 for x in lines)
            and lines[lay.w_exp] == "%04x" % (sexps[0][0] & 0xFFFF))

        # ---- the allocator, on a synthetic manifest with the 9B geometry
        mani = dict(files=[dict(file="output.weight.mv4i", kind="mv4i",
                                tensor="output.weight", K=4096, M=248320,
                                hbm_offset=0, nbytes=0x1000, stack=0)],
                    hbm=dict(size=HM.HBM_TOP, stack_bytes=HM.STACK_LINE,
                             weights_end=0x1_0000_0000,
                             gdn_state_base=0x1_0000_0000,
                             gdn_state_bytes=26443776, gdn_state_stack=1,
                             kv_base=0x1_0193_8000, kv_bytes_per_token=17408,
                             kv_extents=[dict(base=0x1_0193_8000,
                                              nbytes=HM.HBM_TOP - 0x1_0193_8000,
                                              stack=1, tokens=0)]))
        mani["hbm"].update(HM.derive_region_block(mani, 311, 512))
        blk = HM.derive_gdn_const_block(mani)
        da = int(mani["hbm"]["desc_arena_base"])
        row("allocator: the region ends exactly at desc_arena_base and is "
            "4 KB aligned",
            blk["gdn_const_base"] + blk["gdn_const_bytes"] == da
            and blk["gdn_const_base"] % 4096 == 0,
            "%s..%s" % (HM.h(blk["gdn_const_base"]), HM.h(da)))
        row("allocator: the KV extent is re-capped at the region and "
            "max_context_tokens is (base - kv_base) // per",
            blk["kv_extents"][-1]["base"] + blk["kv_extents"][-1]["nbytes"]
            == blk["gdn_const_base"]
            and blk["max_context_tokens"]
            == (blk["gdn_const_base"] - 0x1_0193_8000) // 17408,
            str(blk["max_context_tokens"]))
        m2 = json.loads(json.dumps(mani))
        m2["hbm"].update(blk)
        fails = HM.plan(m2).check()
        row("allocator: the resulting map checks clean", not fails,
            fails[0] if fails else "")
        row("allocator: derivation is idempotent on a manifest that carries it",
            HM.derive_gdn_const_block(m2) == blk)
        m3 = json.loads(json.dumps(mani))
        m3["hbm"]["desc_arena_base"] = 0x1_0193_8000 + 0x1000
        try:
            HM.derive_gdn_const_block(m3)
            row("allocator REFUSES when there is no room below the arena",
                False, "returned a block")
        except SystemExit as e:
            row("allocator REFUSES when there is no room below the arena",
                "OVERLAP" in str(e) or "fault" in str(e), str(e)[:80])
        m4 = json.loads(json.dumps(mani))
        for k in HM.REGION_BLOCK_KEYS:
            m4["hbm"].pop(k, None)
        try:
            HM.derive_gdn_const_block(m4)
            row("allocator REFUSES a manifest with no region block", False)
        except SystemExit as e:
            row("allocator REFUSES a manifest with no region block",
                "desc_arena_base" in str(e))

    print("pack_gdn_consts selftest")
    for name, ok, detail in rows:
        print("  %-4s %s%s" % ("ok" if ok else "FAIL", name,
                               ("  [" + detail + "]") if detail and not ok
                               else ""))
    print()
    print("  %-18s %-6s %-6s caught by" % ("mutant packer", "expect", "caught"))
    for m, expect, caught, by in mut_rows:
        print("  %-18s %-6s %-6s %s" % (m, "yes" if expect else "no",
                                        "yes" if caught else "NO", by))
    print()
    if hard:
        print("SELFTEST FAIL  %d check(s) did not behave as designed" % hard)
        return 1
    print("SELFTEST PASS  %d checks, %d of %d mutant packers caught, every "
          "verdict the one written down for it"
          % (len(rows), sum(1 for _, _, c, _ in mut_rows if c), len(mut_rows)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--manifest", default=None,
                    help="the packed set's manifest.json; required at "
                         "--shape 9b, where the region is declared in it")
    ap.add_argument("--out", default=None, help="the .bin image to write")
    ap.add_argument("--hex", default=None,
                    help="also write the image as text, one 16-bit word per "
                         "line as 4 hex digits, word 0 first, no header")
    ap.add_argument("--shape", choices=("9b", "27b", "sim"), default="9b")
    ap.add_argument("--blocks", type=int, default=4,
                    help="--shape sim: blocks of the scaled shape")
    ap.add_argument("--attn-interval", type=int, default=4)
    ap.add_argument("--norm-reduce", choices=("mean", "slice"), default="mean",
                    help="--shape sim: how the 128-element ssm_norm gain "
                         "becomes a 32-element one (gen_llama_top_weights."
                         "reduce_gain)")
    ap.add_argument("--check", action="store_true",
                    help="re-derive the image and the declaration and compare "
                         "against --out / --hex / --manifest; write nothing")
    ap.add_argument("--selftest", action="store_true",
                    help="no GGUF, no manifest: pack a fake model and prove "
                         "the checks catch seven mutant packers")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.out:
        ap.error("--out is required")
    return run(a)


if __name__ == "__main__":
    sys.exit(main())
