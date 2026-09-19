#!/usr/bin/env python3
"""The bisect, at the SCALED shape a GHDL run can actually reach.

WHY THIS EXISTS AND WHY IT IS NOT `seam_bisect.py`.  `seam_bisect.py` compares
a capture against the whole-model 9B reference.  MEASURED 2026-08-29: that
comparison stops at the FIRST seam with `length 4096 vs 64`, because
`sim/tb_llama_top.vhd` runs `mk_shape_scaled` -- hidden 64 against the model's
4096 -- and a 9B token in GHDL is DERIVED at about 35,000x the work of a scaled
one.  So the 9B reference bisects a CARD; it cannot bisect a simulation, and no
amount of format plumbing changes that.

WHAT THIS DOES INSTEAD.  A STEPWISE oracle.  For every step whose op has an
independent model, it takes the machine's OWN captured inputs, recomputes the
output, and compares bit-for-bit.  The first step that disagrees is the answer.

That structure buys two things a whole-model reference cannot:

  * it needs a model of ONE op, not of the whole token, so it exists today;
  * it can check `R_XN`, which the 9B reference explicitly CANNOT (finding D2:
    the top-level norm weight is a synthetic ramp, so those seams have no
    counterpart in the model).  Locally the ramp is known exactly.

AND WHAT IT CANNOT DO, WHICH IS THE HALF THAT MATTERS.  A stepwise oracle is
blind wherever it has no model.  BOTH `R_Y` families have an
integration-level model as of 2026-08-29.  Subsystem C's is
`tools/ref9b/attn_oracle.py` driving `ref/attn_block_cap_vec.c`, because
subsystem C's whole input is three captured regions plus the KV records earlier
tokens wrote from theirs.  Subsystem B's is `tools/ref9b/gdn_oracle.py` driving
`ref/gdn_block_cap_vec.c`.  B was believed unreachable because its input
includes a recurrent state no region holds -- true of subsystem B, and never
true of THIS TOP LEVEL, whose every unit-B input is a captured region or a
deterministic function of an index.  That sentence was written when
`rtl/llama_top.vhd` drove `tk0` high on every token, so the state was written
and never read; since defect B-TOP-1 was fixed on 2026-08-29 the state DOES
carry, and `ref/gdn_block_cap_vec.c` -- which already allocated one per layer
and ran layer-major -- carries it.  A clean run of this tool therefore does NOT mean the
token is right.  It means: no step that
has a model computed something other than what its model says, given the
machine's own inputs.  The coverage table is printed for exactly that reason
and should be read before the verdict.

usage:
  bisect_scaled.py capture.txt --blocks 4 --attn-int 4 --attn-hd 16 \
      [--tok 0] [--norm real|rs|anchor|mean] [--w-image sim/llama_top_w_b4_pool.hex]
      [--no-a] [-v]
"""
import argparse
import os
import subprocess
import sys
import tempfile

import attn_oracle as AO
import gdn_oracle as GO
import scaled_plan as SP
import vec_oracle as VO

HERE = os.path.dirname(os.path.abspath(__file__))
NPORTS_W = 4
BEATS = 64
SUB_BYTES = 4096
A_MEM_BASE = 0x100000
A_JOB_STRIDE = 0x8000


# ------------------------------------------------------------------ the capture
class Rec:
    __slots__ = ("name", "tok", "layer", "kind", "exp", "v")

    def __init__(self, name, tok, layer, kind, exp, v):
        self.name, self.tok, self.layer = name, tok, layer
        self.kind, self.exp, self.v = kind, exp, v


def read_capture(path):
    """The text format `tools/ref9b/capture_to_r9bs.py` defines, in order."""
    out, pend, want = [], None, 0
    with open(path) as fp:
        for lineno, line in enumerate(fp, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            f = line.split()
            if f[0] == "SEAM":
                if pend is not None and len(pend.v) != want:
                    raise SystemExit("line %d: %s declared %d values, got %d"
                                     % (lineno, pend.name, want, len(pend.v)))
                if len(f) != 7:
                    raise SystemExit("line %d: malformed SEAM" % lineno)
                pend = Rec(f[1], int(f[2]), int(f[3]), f[4], int(f[5]), [])
                want = int(f[6])
                out.append(pend)
            else:
                if pend is None:
                    raise SystemExit("line %d: values before any SEAM" % lineno)
                pend.v.extend(int(x) for x in f)
    if pend is not None and len(pend.v) != want:
        raise SystemExit("%s declared %d values, got %d"
                         % (pend.name, want, len(pend.v)))
    return out


# ------------------------------------------------------------------ the weights
def wword_synth(p, idx):
    """`sim/tb_llama_top.vhd`'s `wword`, byte for byte.

    `idx` is REDUCED before the multiply, exactly as the VHDL does it, because
    `idx*7919` overflows VHDL's 32-bit universal integer at 491 steps and the
    bench aborts.  A Python model without the reduction would silently disagree
    with the bench on every step past that point.
    """
    i2 = idx % 65536
    b = bytearray(16)
    if p == NPORTS_W:
        for l in range(8):
            x = 16384 + ((i2 * 13 + l * 7 + 3) % 16384)
            b[2 * l] = x & 0xFF
            b[2 * l + 1] = (x >> 8) & 0xFF
    else:
        for j in range(16):
            b[j] = (i2 * 7919 + p * 104729 + j * 31 + 17) % 251
    return bytes(b)


class Weights:
    def __init__(self, hex_path=None):
        self.img = None
        if hex_path:
            with open(hex_path) as fp:
                self.img = [ln.strip() for ln in fp if ln.strip()]

    def sub(self, step, p):
        """Sub-region `p` for `step`, as the bench's AXI slaves serve it.

        HOW MANY BEATS IS NOT A FREE CHOICE, AND GETTING IT WRONG LOOKS LIKE A
        DEFECT.  MEASURED 2026-08-29: supplying a fixed 64 beats made the
        oracle read zero weights for every row past 128, so `R_QG-1` at
        ATTN_HD = 64 (512 rows, 256 beats) reported "384 of 512 mantissas
        differ, first at 128" -- a perfect, plausible, and entirely
        self-inflicted divergence.

        The COMMITTED IMAGE really does hold only `A_WBEATS = 64` beats per
        sub-region; `tools/gen_llama_top_weights.py` asserts `tiles*NB <= 64`
        and refuses to emit a shape that needs more.  The SYNTHETIC `wword`
        has no such bound, so the scaled shapes that need more (ATTN_HD = 64)
        are exactly the ones that run without an image.
        """
        nbeat = BEATS if self.img is not None else SUB_BYTES // 16
        out = bytearray()
        for beat in range(nbeat):
            if self.img is None:
                addr = A_MEM_BASE + step * A_JOB_STRIDE + p * 4096 + beat * 16
                out += wword_synth(p, (addr // 16) % 16777216)
            else:
                ln = self.img[step * (NPORTS_W + 1) * BEATS + p * BEATS + beat]
                # The generator writes MSB byte first
                # (gen_llama_top_weights.py:269 `[::-1]`), so undo that to
                # recover the packed body bytes.
                out += bytes.fromhex(ln)[::-1]
        return bytes(out)


def run_a_oracle_full(step, M, K, w_exp, out_shift, x, x_exp, w):
    """One A job through ref/matvec_int4.c.

    Returns (bfp_mant, bfp_exp, raw_s32, raw_exp).  BOTH payloads come from one
    invocation because `ref/matvec_int4.c` fills `y_data` in the row loop,
    before the out_mode branch; only the reported exponent differs by `ns`.
    The RAW pair is what the LOGITS seam carries.
    """
    # MV_STEP_ORACLE lets a caller point at a binary OUTSIDE the repository.
    # tools/ref9b/seamgate.sh builds it into its own scratch directory, because
    # a gate row that writes a binary into the working tree violates
    # sim/regress.sh's "nothing is ever written into sim/" rule in spirit and
    # makes a concurrent run of the same gate race over one file in practice.
    exe = os.environ.get("MV_STEP_ORACLE") or os.path.join(HERE, "mv_step_oracle")
    if not os.path.exists(exe):
        raise SystemExit("build it first:\n  cc -O2 -Wall -DMV4I_LIB -I ref -o "
                         "tools/ref9b/mv_step_oracle tools/ref9b/mv_step_oracle.c -lm")
    fd, jp = tempfile.mkstemp(suffix=".job")
    with os.fdopen(fd, "w") as fp:
        fp.write("%d %d %d %d %d\nX\n" % (M, K, w_exp, out_shift, x_exp))
        fp.write(" ".join(str(v) for v in x) + "\n")
        for p in range(NPORTS_W + 1):
            body = w.sub(step, p)
            fp.write("SUB %d %d\n%s\n" % (p, len(body), body.hex()))
    try:
        r = subprocess.run([exe, jp], capture_output=True, text=True)
    finally:
        os.unlink(jp)
    if r.returncode:
        raise SystemExit("mv_step_oracle failed on step %d: %s" % (step, r.stderr))
    f = r.stdout.split()
    if f[0] != "Y":
        raise SystemExit("mv_step_oracle: expected Y, got %r" % f[0])
    y_exp, _ns, n = int(f[1]), int(f[2]), int(f[3])
    mant = [int(v) for v in f[4:4 + n]]
    f = f[4 + n:]
    if not f or f[0] != "YRAW":
        # An oracle binary predating the YRAW block would silently return no
        # raw payload, and the LOGITS seam would then be omitted with a reason
        # that reads like "no model" rather than "stale binary".  Say which.
        raise SystemExit("mv_step_oracle emitted no YRAW block; rebuild it:\n"
                         "  cc -O2 -Wall -DMV4I_LIB -I ref -o "
                         "tools/ref9b/mv_step_oracle "
                         "tools/ref9b/mv_step_oracle.c -lm")
    raw_exp, nr = int(f[1]), int(f[2])
    raw = [int(v) for v in f[3:3 + nr]]
    return mant, y_exp, raw, raw_exp


def run_a_oracle(step, M, K, w_exp, out_shift, x, x_exp, w):
    mant, y_exp, _raw, _re = run_a_oracle_full(step, M, K, w_exp, out_shift,
                                               x, x_exp, w)
    return mant, y_exp


def argmax_first(v):
    """`rtl/sampler_stream.vhd`'s rule, restated: index 0 is the initial
    candidate and a later index displaces it only on a STRICT `>`, so the
    FIRST maximum wins on a tie.  Written out rather than calling
    numpy.argmax so the tie rule is visible and can be mutated.
    """
    bi, bv = 0, v[0]
    for i in range(1, len(v)):
        if v[i] > bv:
            bi, bv = i, v[i]
    return bi


# ----------------------------------------------------------------------- driver
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--blocks", type=int, default=4)
    ap.add_argument("--attn-int", type=int, default=4)
    ap.add_argument("--attn-hd", type=int, default=32)
    ap.add_argument("--tok", type=int, default=0)
    ap.add_argument("--norm", choices=("real", "rs", "anchor", "mean"), default="anchor",
                    help="which OP_VEC_NORM the run elaborated.  The capture "
                         "does NOT record this and guessing it wrong makes "
                         "every norm seam diverge, which looks like a defect.")
    ap.add_argument("--swg", choices=("standin", "real"), default="standin",
                    help="which OP_VEC_SWG the run elaborated: standin = "
                         "the `g*u / 2**MANT_W` model (SWG_REAL false, the "
                         "default and every capture before 2026-09-19); "
                         "real = rtl/swiglu_mem.vhd via SWG_REAL.  NOT "
                         "recorded in the capture; the wrong choice makes "
                         "every R_H seam diverge")
    ap.add_argument("--norm-exp", type=int, default=12,
                    help="rtl/llama_top.vhd's NORM_EXP (:220, default 12), "
                         "used by --norm anchor")
    ap.add_argument("--norm-w-exp", type=int, default=12)
    ap.add_argument("--norm-q", type=int, default=12)
    ap.add_argument("--w-image", default=None,
                    help="the bench's W_IMAGE hex; omit for the synthetic wword")
    ap.add_argument("--no-a", action="store_true",
                    help="skip the subsystem A seams (they cost one process each)")
    ap.add_argument("--no-c", action="store_true",
                    help="skip the subsystem C R_Y model")
    ap.add_argument("--no-b", action="store_true",
                    help="skip the subsystem B R_Y model, which then reports "
                         "as NOT CHECKED.  Teeth for the COVERAGE branch, the "
                         "same standing as --no-a")
    # NOT IN THE CAPTURE.  A wrong --conv-lanes is a legal shape and a wrong
    # conv WEIGHT, the same hazard --kv-block carries on the C side.
    ap.add_argument("--conv-lanes", type=int, default=4,
                    help="rtl/llama_top.vhd's B_CONV_LANES")
    ap.add_argument("--b-src-real", action="store_true",
                    help="rtl/llama_top.vhd's B_SRC_REAL, which defaults FALSE "
                         "in every configuration capture_llama_top.sh runs")
    ap.add_argument("--kmap", default="mod", choices=("mod", "div"),
                    help="which key head feeds value head h in subsystem B.  "
                         "'mod' is the model (ggml_repeat tiles); 'div' is the "
                         "contiguous GQA grouping that was defect B-BLK-1")
    ap.add_argument("--kv-block", type=int, default=4)
    ap.add_argument("--n-rot", type=int, default=8)
    ap.add_argument("--qkn-exp", type=int, default=12)
    ap.add_argument("--qkn-image", default=None,
                    help="rtl/llama_top.vhd's C_QKN_IMAGE, the same file, so "
                         "the R_Y model of subsystem C reads the model's "
                         "per-layer QK-norm gains instead of the ramp.  NOT "
                         "in the capture: a run elaborated with an image and "
                         "judged without one diverges at every attention "
                         "R_Y, and the reverse likewise (that is the "
                         "attribution control tools/ref9b/seamgate.sh "
                         "records for the qkn configuration)")
    ap.add_argument("--attn-fold", default="perlayer",
                    choices=("perlayer", "shared", "pertoken"),
                    help="which v_ref fold subsystem C's model assumes.  The "
                         "DEFAULT is perlayer, which is C spec 2.1.4 and what "
                         "ref/attn_block_vec.c states.  'shared' is what a "
                         "single time-shared attn_block instance does across "
                         "more than one attention layer; it is a "
                         "CHARACTERISATION of the RTL, not the spec, and "
                         "selecting it hides defect C1.")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    recs = read_capture(a.capture)
    by = {}
    for r in recs:
        k = (r.name, r.tok)
        if k in by:
            raise SystemExit("duplicate record %s tok %d" % k)
        by[k] = r

    shape = SP.Shape(a.blocks, a.attn_int, a.attn_hd)
    steps = SP.build(shape)
    prod = SP.producers(steps)

    drift = SP.check_against_capture(steps, {k: len(v.v) for k, v in by.items()},
                                     a.tok)
    if drift:
        print("# THE PLAN MIRROR DOES NOT DESCRIBE THIS CAPTURE.  Refusing to "
              "compare, because a shifted plan reports a divergence at the "
              "wrong seam, and the seam is the whole output of a bisect.")
        for m in drift[:10]:
            print("  " + m)
        return 2

    w = Weights(a.w_image)
    checked, skipped, diverged = [], [], []

    # Subsystem C's R_Y, predicted for the WHOLE capture at once.  It has to be
    # the whole sequence and not this one token: the cache token t reads is
    # what tokens 0..t-1 wrote, and the v_ref fold spans the sequence, so a
    # per-token call would have no state to fold.
    cpred, cwhy = {}, ""
    # THE ATTENTION STUB IS DETECTED, NOT DECLARED BY A FLAG.  With C_REAL
    # false `rtl/llama_top.vhd:3037` writes y(i) = -32768 + (i mod 4096) and
    # ignores Q, K and V entirely, so running the attention model over that run
    # would report a divergence at every element of a seam that is not
    # attention at all.  `--norm` guessed wrong once and made eight norm seams
    # look defective (first-bisect trap T5); this reads the capture instead.
    def _is_stub_ramp(r):
        return all(r.v[i] == -32768 + (i % 4096) for i in range(len(r.v)))

    stub_c = [b for b in range(shape.blocks) if shape.is_attn(b)
              and ("R_Y-%d" % b, a.tok) in by
              and _is_stub_ramp(by[("R_Y-%d" % b, a.tok)])]
    stub_named = set("R_Y-%d" % b for b in stub_c)
    if stub_c:
        for b in stub_c:
            skipped.append(("R_Y-%d" % b,
                            "this run elaborated the ATTENTION STUB, not "
                            "attn_block: R_Y is llama_top:3037's -32768 + i "
                            "ramp, bit for bit"))
    if not a.no_c and not stub_c \
            and any(shape.is_attn(b) for b in range(shape.blocks)):
        ctoks = sorted(set(r.tok for r in recs))
        try:
            cpred, _cblks, _cvt = AO.predict(
                by, shape, ctoks, a.kv_block, a.n_rot, a.qkn_exp,
                False, a.attn_fold, a.qkn_image)
            cwhy = ("ref/attn_block_vec.c's attn_token() over the capture's "
                    "own R_QG/R_KIN/R_VIN, v_ref fold '%s'" % a.attn_fold)
        except SystemExit as e:
            cpred, cwhy = {}, ""
            skipped.append(("(subsystem C)",
                            "the R_Y model refused this capture: %s" % e))

    # Subsystem B's R_Y.  Predicted for the whole capture at once for the same
    # reason the C call is: the driver is layer-major and carries one state per
    # GDN layer across the sequence, so a per-token call would have no state to
    # carry.  THAT IS LOAD-BEARING NOW.  Until 2026-08-29 the top level drove
    # `tk0` high at every token and the state was inert; since defect B-TOP-1
    # was fixed it is read at every token but the first, so calling this
    # per-token would model a machine that resets its recurrence every token --
    # which is the defect, not the design.  See tools/ref9b/gdn_oracle.py.
    bpred, bwhy = {}, ""
    if not a.no_b and any(not shape.is_attn(b) for b in range(shape.blocks)):
        btoks = sorted(set(r.tok for r in recs))
        try:
            bpred, bflags = GO.predict(by, shape, btoks, a.conv_lanes,
                                       a.b_src_real, a.kmap)
            bwhy = ("ref/gdn_block_vec.c's gdn_block_token() over the capture's "
                    "own R_Z and R_QKV exponents, kmap '%s'" % a.kmap)
            for (nm, t, ec, eg, es, ys) in bflags:
                if t == a.tok:
                    print("# MODEL FLAG %s: err_conv=%d err_g=%d err_se=%d "
                          "y_sat=%d.  The MODEL hit a range condition on this "
                          "stimulus; the comparison below still stands, but a "
                          "saturating y is a weak comparison." % (nm, ec, eg,
                                                                  es, ys))
        except SystemExit as e:
            bpred, bwhy = {}, ""
            skipped.append(("(subsystem B)",
                            "the R_Y model refused this capture: %s" % e))

    for st in steps:
        if st.op == SP.OP_END:
            continue
        if st.dst is None:
            # THE LOGITS SEAM.  `dst = R_NONE` is not "the result is
            # discarded" -- rtl/llama_top.vhd routes it to the sampler under
            # SMP_EN -- it is "no region can hold it": at the 9B shape
            # region_max is 12,288 against a 248,320-row vocabulary.  So the
            # capture cannot snapshot it and emits the STREAM instead, as an
            # s32 record plus the design's own argmax.  With SMP_EN off there
            # is no such record and the seam stays unmodelled, which is the
            # state this project was in until 2026-08-29.
            if ("LOGITS", a.tok) not in by:
                skipped.append((st.seam,
                                "no LOGITS record in the capture: this run "
                                "elaborated SMP_EN = false, so the lm_head "
                                "job's result left through nothing"))
                continue
            if a.no_a:
                skipped.append((st.seam, "--no-a"))
                continue
            src = prod[st.i]["src"]
            x = by[(src, a.tok)]
            if len(x.v) != st.n_cols:
                skipped.append((st.seam, "source %s has %d values, the job "
                                         "reads %d" % (src, len(x.v), st.n_cols)))
                continue
            _m, _e, exp_v, exp_e = run_a_oracle_full(
                st.i, st.n_rows, st.n_cols, st.w_exp, st.out_shift,
                x.v, x.exp, w)
            got = by[("LOGITS", a.tok)]
            why = ("ref/matvec_int4.c in RAW out_mode on the bench's own "
                   "weight bytes")
            nbad = sum(1 for i in range(len(exp_v)) if exp_v[i] != got.v[i]) \
                if len(exp_v) == len(got.v) else -1
            ebad = (exp_e != got.exp)
            checked.append(("LOGITS", why))
            if nbad or ebad:
                first = -1
                if nbad > 0:
                    first = next(i for i in range(len(exp_v))
                                 if exp_v[i] != got.v[i])
                diverged.append(("LOGITS", first, exp_e, got.exp, nbad,
                                 len(got.v),
                                 (exp_v[first] if first >= 0 else None),
                                 (got.v[first] if first >= 0 else None)))
            if a.verbose:
                print("  %-14s %-6s %s" % ("LOGITS",
                                           "DIFFERS" if (nbad or ebad) else "ok",
                                           why))

            # THE ARGMAX, WHICH IS THE THING THAT DECIDES A TOKEN.  Taken over
            # the MODEL's logits, not over the capture's, and compared against
            # what rtl/sampler_stream.vhd produced.  Over the capture's own
            # values it would be a round trip.
            if ("TOKEN", a.tok) in by:
                want = argmax_first(exp_v)
                tgot = by[("TOKEN", a.tok)]
                checked.append(("TOKEN",
                                "argmax of the modelled logits, first-max on "
                                "ties (rtl/sampler_stream.vhd:57)"))
                if tgot.v[0] != want:
                    diverged.append(("TOKEN", 0, 0, 0, 1, 1, want, tgot.v[0]))
                if a.verbose:
                    print("  %-14s %-6s model %d, design %d"
                          % ("TOKEN", "DIFFERS" if tgot.v[0] != want else "ok",
                             want, tgot.v[0]))
            else:
                skipped.append(("TOKEN", "no TOKEN record in the capture"))
            continue
        got = by[(st.seam, a.tok)]
        src = prod[st.i]["src"]
        src2 = prod[st.i]["src2"]

        if st.op == SP.OP_A:
            if a.no_a:
                skipped.append((st.seam, "--no-a"))
                continue
            x = by[(src, a.tok)]
            if len(x.v) != st.n_cols:
                skipped.append((st.seam, "source %s has %d values, the job "
                                         "reads %d" % (src, len(x.v), st.n_cols)))
                continue
            exp_v, exp_e = run_a_oracle(st.i, st.n_rows, st.n_cols, st.w_exp,
                                        st.out_shift, x.v, x.exp, w)
            why = "ref/matvec_int4.c on the bench's own weight bytes"
        elif st.op == SP.OP_RES:
            x, e = by[(src, a.tok)], by[(src2, a.tok)]
            exp_v, exp_e, _sh, _sat = VO.res(x.v, e.v, x.exp, e.exp)
            why = "ref/seq_vec_res_vec.c recipe (REAL RTL on the other side)"
        elif st.op == SP.OP_SWG:
            g, u = by[(src, a.tok)], by[(src2, a.tok)]
            if a.swg == "real":
                exp_v, exp_e, diag = VO.swg_real(g.v, u.v, g.exp, u.exp)
                why = ("swiglu_mem (Q12 silu*u + pack), bit-exact, shift %d, "
                       "rel_rms vs the double ideal %.4g"
                       % (diag["shift"], diag["rel_rms_vs_ideal"]))
            else:
                exp_v, exp_e = VO.swg(g.v, u.v, g.exp, u.exp)
                why = "the behavioural stand-in: sequencing and exponent only"
        elif st.op == SP.OP_NORM:
            x = by[(src, a.tok)]
            if a.norm == "real":
                # 2026-09-19: the top's D-vec norm is rmsnorm_bf_mem, so the
                # real model is the block-floating one.  `rs` below is the
                # unit it replaced, for captures taken before that commit.
                wv = VO.norm_w_const(len(x.v), a.norm_w_exp)
                exp_v, exp_e, diag = VO.norm_bf(x.v, x.exp, wv, a.norm_w_exp,
                                                a.norm_q)
                why = ("rmsnorm_bf, bit-exact, rel_rms vs the double ideal "
                       "%.4g" % diag["rel_rms_vs_ideal"])
            elif a.norm == "rs":
                wv = VO.norm_w_const(len(x.v), a.norm_w_exp)
                exp_v, exp_e, diag = VO.norm_rs(x.v, x.exp, wv, a.norm_w_exp,
                                                a.norm_q)
                why = ("rmsnorm_rs (pre-2026-09-19 unit), bit-exact, rel_rms "
                       "vs the double ideal %.4g" % diag["rel_rms_vs_ideal"])
            elif a.norm == "anchor":
                exp_v, exp_e = VO.norm_anchor(x.v, x.exp, a.norm_exp)
                why = "the NORM_ANCHOR probe: sequencing and scale only"
            else:
                exp_v, exp_e = VO.norm_mean(x.v, x.exp)
                why = "the behavioural mean-removal stand-in"
        elif st.op == SP.OP_C and (st.seam, a.tok) in cpred:
            exp_e, exp_v = cpred[(st.seam, a.tok)]
            why = cwhy
        elif st.op == SP.OP_C and st.seam in stub_named:
            continue                      # already reported as the stub ramp
        elif st.op == SP.OP_B and (st.seam, a.tok) in bpred:
            exp_e, exp_v = bpred[(st.seam, a.tok)]
            why = bwhy
        else:
            skipped.append((st.seam, "subsystem %s has no integration-level "
                                     "model" % st.op))
            continue

        nbad = sum(1 for i in range(len(exp_v)) if exp_v[i] != got.v[i]) \
            if len(exp_v) == len(got.v) else -1
        ebad = (exp_e != got.exp)
        checked.append((st.seam, why))
        if nbad or ebad:
            first = -1
            if nbad > 0:
                first = next(i for i in range(len(exp_v)) if exp_v[i] != got.v[i])
            diverged.append((st.seam, first, exp_e, got.exp, nbad, len(got.v),
                             (exp_v[first] if first >= 0 else None),
                             (got.v[first] if first >= 0 else None)))
        if a.verbose:
            print("  %-14s %-6s %s" % (st.seam, "DIFFERS" if (nbad or ebad)
                                       else "ok", why))

    print("# stepwise oracle, token %d, shape blocks=%d attn_interval=%d "
          "attn_hd=%d hidden=%d ffn=%d"
          % (a.tok, shape.blocks, shape.attn_interval, shape.attn_hd,
             shape.hidden, shape.ffn))
    print("# %d seams checked against a model, %d NOT checked"
          % (len(checked), len(skipped)))
    for nm, why in skipped:
        print("    NOT CHECKED  %-14s %s" % (nm, why))
    if diverged:
        for (nm, i, ee, ge, nb, n, ev, gv) in diverged[:8]:
            if nb < 0:
                print("  %-14s LENGTH mismatch" % nm)
            else:
                print("  %-14s exp %d expected vs %d captured, %d of %d "
                      "mantissas differ, first at %d (expected %s, captured %s)"
                      % (nm, ee, ge, nb, n, i, ev, gv))
        nm, i, ee, ge, nb, n, ev, gv = diverged[0]
        print("\nFIRST DIVERGENCE: %s at element %d -- expected %s, captured %s "
              "(exponent %d vs %d, %d of %d mantissas differ)"
              % (nm, i, ev, gv, ee, ge, nb, n))
        return 1
    print("\nEVERY MODELLED SEAM MATCHES ITS MODEL BIT FOR BIT, given the "
          "machine's own inputs.")
    print("That is NOT a statement that the token is right: read the NOT "
          "CHECKED list above, and note that a wrong value at an unmodelled "
          "seam is passed forward AS GIVEN and every later seam still agrees.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
