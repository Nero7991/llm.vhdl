#!/usr/bin/env python3
"""ooc_nwrom_gen_image.py -- TRACK NWROM, 2026-08-29.

Write `rtl/llama_top.vhd`'s `NORM_W_IMAGE` at the REAL 9B shape, i.e. the
un-reduced 4096-element gain, one entry per OP_VEC_NORM of the token in
schedule order.

WHY THIS AND NOT `tools/gen_llama_top_weights.py --norm-out`.  That tool exists
to feed `sim/tb_llama_top.vhd`, which runs `mk_shape_scaled` at hidden = 64, so
its `--norm-out` path reduces every 4096-element gain to 64 through
`reduce_gain`.  The question here is an AREA question at `mk_shape(MODEL, 1)`,
where `SHAPE.hidden = 4096`, so the image must be the full-width gain and no
reduction may be applied.  Everything else -- the schedule order, the tensor
names, the quantiser, the file format -- is imported from that tool rather than
restated, so there is exactly one definition of each.

The order is `build_plan`'s: `blk.L.attn_norm.weight` before the attention/GDN
half, `blk.L.post_attention_norm.weight` before the FFN half, and
`output_norm.weight` at the tail; 2*blocks+1 of them.

`--ops K` truncates to the first K norm ops, which is how the NW_N scaling
probe is taken.  It is a PREFIX of the real image, not synthetic data: the bit
statistics of a real gain are the whole reason this measurement cannot be taken
on random numbers.

NO HARDWARE.  Reads a gguf and writes a text file.
"""

import argparse, os, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))

import gen_llama_top_weights as G          # noqa: E402
import pack_int4 as P                      # noqa: E402
from gguf import GGUFReader                # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default="/mnt/storage/llama-models/qwen35-9b/"
                                      "Qwen3.5-9B-BF16.gguf")
    ap.add_argument("--blocks", type=int, default=32)
    ap.add_argument("--attn-interval", type=int, default=4)
    ap.add_argument("--hidden", type=int, default=G.R_HIDDEN)
    ap.add_argument("--norm-w-exp", type=int, default=12)
    ap.add_argument("--ops", type=int, default=0,
                    help="truncate to the first K norm ops (0 = all)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stats", default=None)
    a = ap.parse_args()

    plan = G.build_plan(a.blocks, a.attn_interval)
    need = [st["tens"] for st in plan if st["op"] == G.OP_NORM]
    assert len(need) == 2 * a.blocks + 1, (len(need), a.blocks)
    if a.ops:
        need = need[:a.ops]

    want = set(need)
    rd = GGUFReader(a.gguf, "r")
    gains = {}
    for t in rd.tensors:
        if t.name in want:
            gains[t.name] = P.tensor_as_mk(t).reshape(-1).astype(np.float64)
    missing = want - set(gains)
    assert not missing, f"norm gains not in the gguf: {sorted(missing)[:5]}"

    rows = []
    with open(a.out, "w") as f:
        for k, nm in enumerate(need):
            g = gains[nm]
            assert g.size == a.hidden, (nm, g.size, a.hidden)
            q = G.quantize_gain(g, a.norm_w_exp)
            for v in q:
                f.write("%04x\n" % (int(v) & 0xFFFF))
            rows.append((k, nm, float(g.min()), float(g.max()),
                         float(np.sqrt((g ** 2).mean())), int(np.abs(q).max())))

    sys.stderr.write("wrote %s: %d norm ops x %d elements, w_exp=%d\n"
                     % (a.out, len(need), a.hidden, a.norm_w_exp))
    if a.stats:
        with open(a.stats, "w") as f:
            f.write("op,tensor,gmin,gmax,grms,absqmax\n")
            for r in rows:
                f.write(",".join(str(x) for x in r) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
