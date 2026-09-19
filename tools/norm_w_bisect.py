#!/usr/bin/env python3
"""Compare the machine's `R_XN` seams against a model built from the REAL gain.

WHY THIS EXISTS, AND WHY IT IS NOT A FLAG ON `tools/ref9b/bisect_scaled.py`.
That tool's `--norm real` recomputes each norm with `VO.norm_w_const`, i.e. with
`rtl/llama_top.vhd`'s SYNTHETIC RAMP.  While the RTL's gain was that ramp, that
was the only honest thing it could do, and its own header says so: it can check
`R_XN` "because locally the ramp is known exactly".  What it could NOT do is
say whether the design normalises by the MODEL's gain, because the design did
not.  `tools/ref9b/**` belongs to another track today, so this comparison lives
here rather than as a fourth `--norm` choice; if that file is ever free it
should move there and this file should go.

WHAT IT CHECKS.  For every OP_VEC_NORM step of a captured token:

    expected = rmsnorm_bf( machine's own captured R_X, machine's own x_exp,
                           the REAL gain for that (layer, half) )

compared BIT FOR BIT, mantissa by mantissa plus the published exponent, against
the `R_XN` the machine actually wrote.

THE TWO HALVES OF THE ORACLE COME FROM DIFFERENT PLACES, which is what stops
this being a round trip:

  * the ARITHMETIC is `tools/ref9b/vec_oracle.norm_bf`, transcribed from
    `ref/rmsnorm_bf_vec.c` (the top binds rmsnorm_bf_mem since 2026-09-19;
    `--unit rs` selects `norm_rs` for captures taken before that);
  * the GAIN is the model's, and with `--gguf` it is re-derived here from the
    GGUF by a SECOND implementation of the reduction rather than read from the
    committed image, so the image itself is under test too.

AND THE CHECK IS SHOWN TO DISCRIMINATE.  `--also-ramp` runs the same comparison
with the old synthetic ramp in place of the real gain and reports it under its
own name.  A check that passes with either gain is not checking the gain, and
that is a failure mode nothing else here would catch.

usage:
  tools/norm_w_bisect.py <capture.txt> --gains sim/llama_top_nw_b4_mean.hex \\
      [--blocks 4] [--attn-int 4] [--attn-hd 16] [--tok 0] \\
      [--norm-w-exp 12] [--norm-q 12] [--also-ramp] \\
      [--gguf <path>] [--reduce mean|slice]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "ref9b"))

import bisect_scaled as BS      # read_capture only
import scaled_plan as SP
import vec_oracle as VO


def read_gains(path, n):
    """The image `gen_llama_top_weights.py --norm-out` writes, and the image
    `rtl/llama_top.vhd`'s `nw_load` reads: one 4-hex-digit two's-complement
    int16 per line, ELEMENT 0 FIRST, `n` elements per norm op.
    """
    vals = []
    with open(path) as fp:
        for lineno, line in enumerate(fp, 1):
            t = line.strip()
            if not t:
                continue
            v = int(t, 16)
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
    if len(vals) % n:
        raise SystemExit("%s: %d values is not a multiple of the norm length "
                         "%d" % (path, len(vals), n))
    return [vals[k * n:(k + 1) * n] for k in range(len(vals) // n)]


def gains_from_gguf(gguf, order, n, reduce_mode, w_exp):
    """Re-derive the gains from the model, with a SECOND implementation of the
    reduction.  Deliberately not `gen_llama_top_weights.reduce_gain`: importing
    that would make the image its own oracle, which is the `m7 mutant` failure
    this project already has on record.
    """
    import numpy as np
    sys.path.insert(0, HERE)
    import pack_int4 as P
    from gguf import GGUFReader

    want = set(order)
    raw = {}
    rd = GGUFReader(gguf, "r")
    for t in rd.tensors:
        if t.name in want:
            raw[t.name] = P.tensor_as_mk(t).reshape(-1).astype(np.float64)
    missing = want - set(raw)
    if missing:
        raise SystemExit("gains not in %s: %s" % (gguf, sorted(missing)[:4]))

    out = []
    for nm in order:
        g = raw[nm]
        k = g.size // n
        if reduce_mode == "slice":
            red = g[:n]
        else:
            # the mean of each contiguous run of k, written as an explicit
            # accumulation rather than a reshape, so a transposed grouping
            # cannot come out looking the same
            red = np.array([sum(g[c * k:(c + 1) * k]) / k for c in range(n)])
        q = [int(round(float(v) * (2.0 ** w_exp))) for v in red]
        if max(abs(x) for x in q) > 32767:
            raise SystemExit("gain for %s does not fit int16 at w_exp %d"
                             % (nm, w_exp))
        out.append(q)
    return out


def norm_tensor_order(blocks, attn_interval):
    """The OP_VEC_NORM tensors in schedule order.

    A FOURTH copy of this ordering (after `sim/llama_sched_pkg.vhd`,
    `sim/tb_llama_top.vhd`'s `seam_of` and `tools/ref9b/scaled_plan.py`), and
    it is checked rather than trusted: `scaled_plan.check_against_capture`
    refuses if the seam ordering this file assumes is not the capture's, and
    the count is asserted against 2*blocks+1 below.
    """
    order = []
    for b in range(blocks):
        order.append("blk.%d.attn_norm.weight" % b)
        order.append("blk.%d.post_attention_norm.weight" % b)
    order.append("output_norm.weight")
    return order


def compare(steps, prod, by, tok, gains, w_exp, q, label, unit="bf"):
    """One pass of the comparison.  Returns (nseam, nbad_seam, lines)."""
    lines, k, nbad = [], 0, 0
    for st in steps:
        if st.op != SP.OP_NORM:
            continue
        got = by[(st.seam, tok)]
        x = by[(prod[st.i]["src"], tok)]
        if k >= len(gains):
            raise SystemExit("%s: the capture has more norm ops than the gain "
                             "set has entries (%d)" % (label, len(gains)))
        wv = gains[k]
        if len(wv) != len(x.v):
            raise SystemExit("%s: gain %d has %d elements, the norm is %d"
                             % (label, k, len(wv), len(x.v)))
        # 2026-09-19: the top's norm is rmsnorm_bf_mem; --unit rs keeps the
        # pre-swap model for captures taken with rmsnorm_rs_mem.
        norm_fn = VO.norm_rs if unit == "rs" else VO.norm_bf
        exp_v, exp_e, diag = norm_fn(x.v, x.exp, wv, w_exp, q)
        nmis = (sum(1 for i in range(len(exp_v)) if exp_v[i] != got.v[i])
                if len(exp_v) == len(got.v) else -1)
        ebad = exp_e != got.exp
        first = ""
        if nmis:
            for i in range(min(len(exp_v), len(got.v))):
                if exp_v[i] != got.v[i]:
                    first = ("  first at element %d: expected %d, captured %d"
                             % (i, exp_v[i], got.v[i]))
                    break
        if nmis or ebad:
            nbad += 1
        lines.append("%-14s n=%-4d exp %2d vs %2d  %s%s"
                     % (st.seam, len(got.v), exp_e, got.exp,
                        ("MATCH" if not nmis and not ebad
                         else "%d of %d mantissas differ" % (nmis, len(got.v))),
                        first))
        k += 1
    return k, nbad, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--gains", required=True,
                    help="the gain image rtl/llama_top.vhd's NORM_W_IMAGE read")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=16)
    ap.add_argument("--tok", type=int, default=0)
    ap.add_argument("--norm-w-exp", type=int, default=12)
    ap.add_argument("--norm-q", type=int, default=12)
    ap.add_argument("--unit", choices=("bf", "rs"), default="bf",
                    help="bf = rmsnorm_bf_mem, the top's unit since "
                         "2026-09-19; rs = rmsnorm_rs_mem, the unit before")
    ap.add_argument("--also-ramp", action="store_true",
                    help="repeat the comparison with rtl/llama_top.vhd's OLD "
                         "synthetic ramp, to show the check discriminates")
    ap.add_argument("--gguf", default=None,
                    help="re-derive the gains from the model and check the "
                         "committed image against them")
    ap.add_argument("--reduce", choices=("mean", "slice"), default="mean")
    a = ap.parse_args()

    recs = BS.read_capture(a.capture)
    by = {}
    for r in recs:
        by[(r.name, r.tok)] = r

    shape = SP.Shape(a.blocks, a.attn_int, a.attn_hd)
    steps = SP.build(shape)
    prod = SP.producers(steps)
    drift = SP.check_against_capture(
        steps, {k: len(v.v) for k, v in by.items()}, a.tok)
    if drift:
        print("# THE PLAN MIRROR DOES NOT DESCRIBE THIS CAPTURE.  Refusing: a "
              "shifted plan reports a divergence at the wrong seam.")
        for m in drift[:10]:
            print("  " + m)
        return 2

    n = shape.hidden
    gains = read_gains(a.gains, n)
    order = norm_tensor_order(a.blocks, a.attn_int)
    if len(gains) != len(order):
        raise SystemExit("the gain image has %d entries, this shape has %d "
                         "norm ops" % (len(gains), len(order)))

    print("# tools/norm_w_bisect.py -- R_XN against a MODEL-DERIVED gain")
    print("# capture %s  token %d  shape blocks=%d attn_interval=%d hidden=%d"
          % (a.capture, a.tok, a.blocks, a.attn_int, n))
    print("# gains   %s  (%d norm ops, w_exp %d, rmsnorm_%s Q %d)"
          % (a.gains, len(gains), a.norm_w_exp, a.unit, a.norm_q))

    rc = 0
    if a.gguf:
        ref = gains_from_gguf(a.gguf, order, n, a.reduce, a.norm_w_exp)
        bad = [(k, order[k]) for k in range(len(ref)) if ref[k] != gains[k]]
        print("# IMAGE vs MODEL: %d of %d gain vectors differ%s"
              % (len(bad), len(ref),
                 "" if not bad else "  " + str(bad[:4])))
        if bad:
            rc = 1

    nseam, nbad, lines = compare(steps, prod, by, a.tok, gains,
                                 a.norm_w_exp, a.norm_q, "real", a.unit)
    print("\n# THE REAL GAIN")
    for l in lines:
        print("  " + l)
    print("# %d of %d R_XN seams match the model bit for bit"
          % (nseam - nbad, nseam))
    if nbad:
        rc = 1

    if a.also_ramp:
        ramp = [VO.norm_w_const(n, a.norm_w_exp) for _ in range(len(gains))]
        rseam, rbad, rlines = compare(steps, prod, by, a.tok, ramp,
                                      a.norm_w_exp, a.norm_q, "ramp", a.unit)
        print("\n# THE OLD SYNTHETIC RAMP, on the SAME capture.  This is the "
              "teeth check:")
        print("# if these also matched, the comparison above would not be "
              "checking the gain at all.")
        for l in rlines:
            print("  " + l)
        print("# %d of %d R_XN seams match the ramp" % (rseam - rbad, rseam))
        if rbad == 0:
            print("# THE CHECK HAS NO TEETH: the ramp matches too.")
            rc = 1

    return rc


if __name__ == "__main__":
    sys.exit(main())
