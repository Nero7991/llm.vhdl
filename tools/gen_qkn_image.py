#!/usr/bin/env python3
"""gen_qkn_image.py -- TRACK F, 2026-09-18.

Write `rtl/llama_top.vhd`'s `C_QKN_IMAGE`: the model's QK-norm gains,
`blk.L.attn_q_norm.weight` and `blk.L.attn_k_norm.weight`, one q and one k
vector per ATTENTION layer in the order the schedule visits them, at a fixed
exponent.

FORMAT (what the loader in rtl/llama_top.vhd `gcr` reads): one 4-hex-digit
two's complement int16 per line, element 0 first, `attn_hd` elements per
vector, vectors in attention-layer ordinal order, q then k per layer, so
`2 * n_attn_layers * attn_hd` lines.  Mantissas are round(g * 2**qkn_exp).
No header: the RTL reads it with `hread`, one value per line and nothing else.

WHICH LAYERS, AND IN WHICH ORDER.  Taken from `tools/gen_llama_top_weights.py`'s
`build_plan`, not re-derived: the plan emits one `blk.B.attn_q.weight` A job
per attention block in schedule order, and the block index B of the k-th such
job is the layer whose ordinal is k.  That is the same `job_ordinal` the C job
carries (`rtl/llama_top.vhd`, `c_layer <= j_lay`), so entry 2k of the image is
what the block reads at `c_layer = k`.  Deriving the order here from
`(b + 1) % attn_interval == 0` would be a second copy of the schedule rule,
and two copies is how an image and its consumer drift.

THE SIM SHAPE.  `mk_shape_scaled(blocks, attn_interval, attn_hd)` keeps the
attention regions at 64 (q) and 32 (k, v) elements and splits them into
`64/attn_hd` q heads and `32/attn_hd` kv heads of `attn_hd` each, and
`gen_llama_top_weights.py` cuts the A jobs that produce them as ROW SLICES of
the real tensors (`r0 = 0`, the first `rows` rows).  The real `attn_q.weight`
is `[h0 q(256) | h0 gate(256) | h1 q(256) | ...]` (ref/run9b.c), so sim head
h's q dim i is real head 0's q channel `2*attn_hd*h + i`, and sim kv head h's
k dim i is real kv head 0's channel `attn_hd*h + i`.  The RTL applies ONE
gain vector per port to every head (as the model does: the gain is per
head-dim, shared across heads), so no single `attn_hd`-element vector is
exact for more than one sim head.  `--reduce slice` (the DEFAULT) takes
`g[:attn_hd]`, which is exact for sim head 0 and pairs with the row slice the
A jobs already take; `--reduce mean` takes `reduce_gain()`'s group means, the
partner of `--reduce pool`, which is offered for symmetry with the norm image
and is exact for no head.  Either is STIMULUS: the sim image exists so the
machine and the oracle read the same numbers, and the oracle takes the same
file (`tools/ref9b/attn_oracle.py --qkn-image`).  At the 9B shape
(`attn_hd 256`) there is no reduction and the choice is moot.

usage:
  gen_qkn_image.py --gguf G --blocks N --attn-interval K --attn-hd HD \\
      --out FILE [--reduce slice|mean] [--qkn-exp 12] [--stats CSV]

NO HARDWARE.  Reads a gguf (mmap) and writes a text file.
"""

import argparse, os, re, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_llama_top_weights as G          # noqa: E402
import pack_int4 as P                      # noqa: E402
from gguf import GGUFReader                # noqa: E402

DEFAULT_GGUF = "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf"
_ATTN_Q = re.compile(r"^blk\.(\d+)\.attn_q\.weight$")


def attn_blocks_in_schedule_order(blocks, attn_interval):
    """Block index of every attention layer, ordinal order, from build_plan."""
    plan = G.build_plan(blocks, attn_interval)
    out = []
    for st in plan:
        if st["op"] != G.OP_A or not isinstance(st["tens"], str):
            continue
        m = _ATTN_Q.match(st["tens"])
        if m:
            out.append(int(m.group(1)))
    return out


def tensor_names(blocks, attn_interval):
    """The (q_norm, k_norm) tensor names per attention layer, ordinal order."""
    return [("blk.%d.attn_q_norm.weight" % b, "blk.%d.attn_k_norm.weight" % b)
            for b in attn_blocks_in_schedule_order(blocks, attn_interval)]


def reduce_qkn(g, hd, mode):
    """`slice` is g[:hd]; `mean` is reduce_gain's group mean.  See the header."""
    if mode == "slice":
        return G.reduce_gain(g, hd, "slice")
    return G.reduce_gain(g, hd, "mean")


def build(gguf, blocks, attn_interval, attn_hd, reduce, qkn_exp):
    """Returns (lines, stats): the image as a list of 4-hex-digit strings and
    one (ordinal, block, port, tensor, min, max, max_abs_mant) per vector."""
    names = tensor_names(blocks, attn_interval)
    want = {}
    for k, (qn, kn) in enumerate(names):
        want[qn] = (k, "q")
        want[kn] = (k, "k")
    rd = GGUFReader(gguf, "r")
    got = {}
    for t in rd.tensors:
        if t.name in want:
            got[t.name] = P.tensor_as_mk(t).reshape(-1).astype(np.float64)
    missing = set(want) - set(got)
    assert not missing, "tensors not in the gguf: %s" % sorted(missing)[:4]

    lines, stats = [], []
    for k, (b, (qn, kn)) in enumerate(zip(
            attn_blocks_in_schedule_order(blocks, attn_interval), names)):
        for port, nm in (("q", qn), ("k", kn)):
            g = got[nm]
            assert g.size % attn_hd == 0, (nm, g.size, attn_hd)
            gr = reduce_qkn(g, attn_hd, reduce)
            assert gr.size == attn_hd, (nm, gr.size)
            q = G.quantize_gain(gr, qkn_exp)
            for v in q:
                lines.append("%04x" % (int(v) & 0xFFFF))
            stats.append((k, b, port, nm, float(gr.min()), float(gr.max()),
                          int(np.abs(q).max())))
    assert len(lines) == 2 * len(names) * attn_hd, len(lines)
    return lines, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default=DEFAULT_GGUF)
    ap.add_argument("--blocks", type=int, default=32)
    ap.add_argument("--attn-interval", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=256,
                    help="the shape's attn_head_dim: 256 at 9B, 16 in the "
                         "`real` bench configuration (mk_shape_scaled)")
    ap.add_argument("--reduce", choices=["slice", "mean"], default="slice",
                    help="how a 256-element gain becomes an --attn-hd one; "
                         "see the header.  No effect at 256.")
    ap.add_argument("--qkn-exp", type=int, default=12,
                    help="rtl/llama_top.vhd's C_QKN_EXP (default 12); the "
                         "mantissas are round(g * 2**this)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stats", default=None)
    a = ap.parse_args()

    lines, stats = build(a.gguf, a.blocks, a.attn_interval, a.attn_hd,
                         a.reduce, a.qkn_exp)
    with open(a.out, "w") as f:
        for l in lines:
            f.write(l + "\n")
    nl = len(stats) // 2
    sys.stderr.write("wrote %s: %d attention layers x 2 x %d = %d lines, "
                     "reduce=%s qkn_exp=%d, max |mant| %d\n"
                     % (a.out, nl, a.attn_hd, len(lines), a.reduce, a.qkn_exp,
                        max(s[6] for s in stats)))
    if a.stats:
        with open(a.stats, "w") as f:
            f.write("ordinal,block,port,tensor,min,max,max_abs_mant\n")
            for s in stats:
                f.write(",".join(str(x) for x in s) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
