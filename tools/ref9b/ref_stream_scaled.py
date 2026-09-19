#!/usr/bin/env python3
"""Emit the REFERENCE side of a `--mode exact` comparison, at the SCALED shape.

WHY THIS EXISTS.  `tools/ref9b/capture_to_r9bs.py` turns a `sim/tb_llama_top.vhd`
seam capture into `.r9bs`, and `seam_bisect.py --mode exact` compares two
`.r9bs` streams bit for bit.  Until this file there was nothing to put on the
other side of that comparison:

  * the whole-model 9B reference (`ref/run9b`) is the WRONG SHAPE.  MEASURED
    2026-08-29 by running it: `seam_bisect.py --mode exact ref_bfp.r9bs
    llama_top_real.r9bs` reports `FIRST DIVERGENCE: R_X.embed at element -1 --
    length 4096 vs 64` and 0 of 63 seams identical.  Every seam differs, none
    of them for a reason about the design.  That is not a plumbing problem and
    no format work fixes it: `sim/tb_llama_top.vhd` runs `mk_shape_scaled`
    (hidden 64) and the model is hidden 4096.
  * a second GHDL run is not a reference, it is the same implementation.

So the reference side has to be built from the INDEPENDENT models that already
exist -- `vec_oracle.py`, `attn_oracle.py`, `ref/matvec_int4.c` via
`mv_step_oracle` -- which is exactly what `bisect_scaled.py` compares against.
This file emits those same expectations as a stream instead of as a verdict.

WHAT IS AND IS NOT INDEPENDENT HERE, because this is the whole value of the
artefact.  Each expectation is computed from the capture's OWN inputs for that
step, by a model written separately from the RTL.  It is a STEPWISE reference,
not a whole-model one: a wrong value at step k is fed to step k+1 as given, so
a clean comparison says "no step that has a model computed something other than
what its model says", and does NOT say the token is right.

SEAMS WITH NO MODEL ARE OMITTED, NOT COPIED.  Copying the capture into the
reference for an unmodelled seam would make `--mode exact` report agreement it
has not established -- a round trip wearing an oracle's clothes, which is the
`m7` mutant this project has on record.  `seam_bisect.exact()` skips a seam
absent from either stream, so omission is the honest encoding.  The omitted
list is printed to stderr on every run and written into the sidecar
`<out>.coverage`.

usage:
  ref_stream_scaled.py capture.txt -o ref.r9bs \\
      --blocks 4 --attn-int 4 --attn-hd 16 --norm real \\
      --w-image sim/llama_top_w_b4_pool.hex
  seam_bisect.py ref.r9bs capture.r9bs --mode exact --tok 0 -v
"""
import argparse
import os
import struct
import sys

import bisect_scaled as BS
import attn_oracle as AO
import gdn_oracle as GO
import scaled_plan as SP
import vec_oracle as VO

MAGIC = b"R9BS"
VERSION = 1
VERSION_S32 = 2
KIND_BFP16, KIND_S32 = 1, 2
_PACK = {KIND_BFP16: "h", KIND_S32: "i"}
_HDR = struct.Struct("<IIiiii")


def _write_rec(fp, name, tok, layer, exp, values, kind=KIND_BFP16):
    nm = name.encode("utf-8")
    fp.write(_HDR.pack(len(nm), len(values), tok, layer, kind, exp))
    fp.write(nm)
    fp.write(struct.pack("<%d%s" % (len(values), _PACK[kind]), *values))


def build(capture, tok, blocks, attn_int, attn_hd, norm, norm_exp, norm_w_exp,
          norm_q, w_image, kv_block, n_rot, qkn_exp, attn_fold, no_a,
          conv_lanes=4, b_src_real=False, kmap="mod"):
    """(list of (name, layer, exp, values, kind), list of (name, why-omitted))."""
    recs = BS.read_capture(capture)
    by = {}
    for r in recs:
        k = (r.name, r.tok)
        if k in by:
            raise SystemExit("duplicate record %s tok %d" % k)
        by[k] = r

    shape = SP.Shape(blocks, attn_int, attn_hd)
    steps = SP.build(shape)
    prod = SP.producers(steps)

    # THE SAME REFUSAL `bisect_scaled.py` MAKES, AND FOR THE SAME REASON.  A
    # plan that has drifted from the RTL emits a reference whose seams are
    # offset by one step, which reports a divergence at the wrong place -- the
    # one output a bisect exists to produce.  Refuse rather than emit.
    drift = SP.check_against_capture(steps, {k: len(v.v) for k, v in by.items()},
                                     tok)
    if drift:
        for m in drift[:10]:
            sys.stderr.write("  " + m + "\n")
        raise SystemExit("the plan mirror does not describe this capture; "
                         "refusing to emit a reference stream")

    w = BS.Weights(w_image)
    out, omitted = [], []

    def _is_stub_ramp(r):
        return all(r.v[i] == -32768 + (i % 4096) for i in range(len(r.v)))

    stub_c = [b for b in range(shape.blocks) if shape.is_attn(b)
              and ("R_Y-%d" % b, tok) in by
              and _is_stub_ramp(by[("R_Y-%d" % b, tok)])]
    stub_named = set("R_Y-%d" % b for b in stub_c)
    for b in stub_c:
        omitted.append(("R_Y-%d" % b,
                        "this run elaborated the ATTENTION STUB, not "
                        "attn_block; there is no attention to model"))

    cpred = {}
    if not stub_c and any(shape.is_attn(b) for b in range(shape.blocks)):
        ctoks = sorted(set(r.tok for r in recs))
        try:
            cpred, _b, _v = AO.predict(by, shape, ctoks, kv_block, n_rot,
                                       qkn_exp, False, attn_fold)
        except SystemExit as e:
            cpred = {}
            omitted.append(("(subsystem C)",
                            "the R_Y model refused this capture: %s" % e))

    # Subsystem B's R_Y, modelled here for the first time.  It is possible
    # because `rtl/llama_top.vhd:3270` drives `tk0` high on every token, so the
    # recurrent state is written and never read and `R_Y` is a pure function of
    # one token's inputs.  See tools/ref9b/gdn_oracle.py's header for the bound
    # that comes with that, and note that an OMITTED seam is the honest
    # encoding the day it stops holding -- never a copy of the capture.
    bpred = {}
    if any(not shape.is_attn(b) for b in range(shape.blocks)):
        btoks = sorted(set(r.tok for r in recs))
        try:
            bpred, _bf = GO.predict(by, shape, btoks, conv_lanes, b_src_real,
                                    kmap)
        except SystemExit as e:
            bpred = {}
            omitted.append(("(subsystem B)",
                            "the R_Y model refused this capture: %s" % e))

    for st in steps:
        if st.op == SP.OP_END:
            continue
        if st.dst is None:
            # THE LOGITS SEAM.  Modelled here for the first time.  `dst =
            # R_NONE` says no REGION can hold the result (at the 9B shape
            # region_max is 12,288 against a 248,320-row vocabulary), not that
            # the result is discarded: rtl/llama_top.vhd's SMP_EN route
            # streams it, raw s32, into rtl/sampler_stream.vhd.  When the
            # capture carries that stream, the model is the SAME A oracle
            # every other A job uses, read in RAW out_mode.
            if ("LOGITS", tok) not in by:
                omitted.append(("LOGITS",
                                "no LOGITS record in the capture: this run "
                                "elaborated SMP_EN = false"))
                continue
            if no_a:
                omitted.append(("LOGITS", "--no-a"))
                continue
            src = prod[st.i]["src"]
            x = by[(src, tok)]
            if len(x.v) != st.n_cols:
                omitted.append(("LOGITS", "source %s has %d values, the job "
                                          "reads %d" % (src, len(x.v),
                                                        st.n_cols)))
                continue
            _m, _e, raw, raw_exp = BS.run_a_oracle_full(
                st.i, st.n_rows, st.n_cols, st.w_exp, st.out_shift,
                x.v, x.exp, w)
            got = by[("LOGITS", tok)]
            out.append(("LOGITS", got.layer, raw_exp, [int(v) for v in raw],
                        KIND_S32))
            # The argmax OF THE MODEL'S OWN LOGITS.  Taking it over the
            # capture's values instead would make the comparison a round trip.
            if ("TOKEN", tok) in by:
                out.append(("TOKEN", by[("TOKEN", tok)].layer, 0,
                            [BS.argmax_first(raw)], KIND_S32))
            else:
                omitted.append(("TOKEN", "no TOKEN record in the capture"))
            continue
        if (st.seam, tok) not in by:
            omitted.append((st.seam, "not present in the capture"))
            continue
        got = by[(st.seam, tok)]
        src, src2 = prod[st.i]["src"], prod[st.i]["src2"]

        if st.op == SP.OP_A:
            if no_a:
                omitted.append((st.seam, "--no-a"))
                continue
            x = by[(src, tok)]
            if len(x.v) != st.n_cols:
                omitted.append((st.seam, "source %s has %d values, the job "
                                         "reads %d" % (src, len(x.v), st.n_cols)))
                continue
            exp_v, exp_e = BS.run_a_oracle(st.i, st.n_rows, st.n_cols, st.w_exp,
                                           st.out_shift, x.v, x.exp, w)
        elif st.op == SP.OP_RES:
            x, e = by[(src, tok)], by[(src2, tok)]
            exp_v, exp_e, _sh, _sat = VO.res(x.v, e.v, x.exp, e.exp)
        elif st.op == SP.OP_SWG:
            g, u = by[(src, tok)], by[(src2, tok)]
            exp_v, exp_e = VO.swg(g.v, u.v, g.exp, u.exp)
        elif st.op == SP.OP_NORM:
            x = by[(src, tok)]
            if norm == "real":
                # 2026-09-19: the composed top's D-vec norm is rmsnorm_bf_mem
                # (docs/debugging/2026-09-19_the-embedding-sits-below-the-
                # norms-window.md), so "real" is the block-floating model.
                wv = VO.norm_w_const(len(x.v), norm_w_exp)
                exp_v, exp_e, _d = VO.norm_bf(x.v, x.exp, wv, norm_w_exp, norm_q)
            elif norm == "rs":
                # The unit the top instantiated BEFORE 2026-09-19, kept for
                # comparison against captures taken with it.  It floors rms
                # at 2^-6 and is wrong on the 9B embedding by design.
                wv = VO.norm_w_const(len(x.v), norm_w_exp)
                exp_v, exp_e, _d = VO.norm_rs(x.v, x.exp, wv, norm_w_exp, norm_q)
            elif norm == "anchor":
                exp_v, exp_e = VO.norm_anchor(x.v, x.exp, norm_exp)
            else:
                exp_v, exp_e = VO.norm_mean(x.v, x.exp)
        elif st.op == SP.OP_C and (st.seam, tok) in cpred:
            exp_e, exp_v = cpred[(st.seam, tok)]
        elif st.op == SP.OP_C and st.seam in stub_named:
            continue
        elif st.op == SP.OP_B and (st.seam, tok) in bpred:
            exp_e, exp_v = bpred[(st.seam, tok)]
        else:
            omitted.append((st.seam, "subsystem %s has no integration-level "
                                     "model" % st.op))
            continue
        out.append((st.seam, got.layer, exp_e, [int(v) for v in exp_v],
                    KIND_BFP16))

    # The embedding is the bench's own input, not a computed seam.  It has no
    # model here and is deliberately NOT carried across from the capture.
    if ("R_X.embed", tok) in by and not any(r[0] == "R_X.embed" for r in out):
        omitted.append(("R_X.embed", "the bench writes it; it is an INPUT to "
                                     "the model, not an output of one"))
    return out, omitted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--tok", default="0",
                    help="a token index, or 'all' to emit every token the "
                         "capture contains into one stream, which is what "
                         "capture_to_r9bs.py produces on the other side")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=32)
    ap.add_argument("--norm", choices=("real", "rs", "anchor", "mean"),
                    default="anchor",
                    help="real = rmsnorm_bf (the top's unit since 2026-09-19); "
                         "rs = rmsnorm_rs, the unit it replaced")
    ap.add_argument("--norm-exp", type=int, default=12)
    ap.add_argument("--norm-w-exp", type=int, default=12)
    ap.add_argument("--norm-q", type=int, default=12)
    ap.add_argument("--w-image", default=None)
    ap.add_argument("--kv-block", type=int, default=4)
    ap.add_argument("--n-rot", type=int, default=8)
    ap.add_argument("--qkn-exp", type=int, default=12)
    ap.add_argument("--attn-fold", default="perlayer",
                    choices=("perlayer", "shared", "pertoken"))
    ap.add_argument("--no-a", action="store_true")
    ap.add_argument("--conv-lanes", type=int, default=4,
                    help="rtl/llama_top.vhd's B_CONV_LANES.  NOT in the "
                         "capture; a wrong legal value is a wrong conv weight")
    ap.add_argument("--b-src-real", action="store_true",
                    help="rtl/llama_top.vhd's B_SRC_REAL")
    ap.add_argument("--kmap", default="mod", choices=("mod", "div"),
                    help="which key head feeds value head h in subsystem B")
    a = ap.parse_args()

    if a.tok == "all":
        toks = sorted(set(r.tok for r in BS.read_capture(a.capture)))
    else:
        toks = [int(a.tok)]

    out, omitted = [], []
    for t in toks:
        o, om = build(a.capture, t, a.blocks, a.attn_int, a.attn_hd,
                      a.norm, a.norm_exp, a.norm_w_exp, a.norm_q, a.w_image,
                      a.kv_block, a.n_rot, a.qkn_exp, a.attn_fold, a.no_a,
                      a.conv_lanes, a.b_src_real, a.kmap)
        out += [(n, t, l, e, v, k) for (n, l, e, v, k) in o]
        omitted += [("tok %d %s" % (t, n), why) for n, why in om]

    ver = VERSION_S32 if any(r[5] == KIND_S32 for r in out) else VERSION
    with open(a.out, "wb") as fp:
        fp.write(MAGIC)
        fp.write(struct.pack("<I", ver))
        for name, t, layer, exp, vals, kind in out:
            _write_rec(fp, name, t, layer, exp, vals, kind)

    cov = a.out + ".coverage"
    with open(cov, "w") as fp:
        fp.write("# reference stream %s, tokens %s\n"
                 % (a.out, ",".join(str(t) for t in toks)))
        fp.write("# %d seams MODELLED, %d seams OMITTED (no model).\n"
                 % (len(out), len(omitted)))
        fp.write("# An omitted seam is absent from the stream, so "
                 "seam_bisect.py --mode exact\n# SKIPS it.  A clean compare "
                 "says nothing whatever about these:\n")
        for n, why in omitted:
            fp.write("OMITTED %-14s %s\n" % (n, why))
    sys.stderr.write("wrote %s: %d seams modelled, %d omitted, format "
                     "version %d (see %s)\n"
                     % (a.out, len(out), len(omitted), ver,
                        os.path.basename(cov)))
    for n, why in omitted:
        sys.stderr.write("  OMITTED %-14s %s\n" % (n, why))
    return 0


if __name__ == "__main__":
    sys.exit(main())
