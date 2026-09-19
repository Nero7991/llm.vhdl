#!/usr/bin/env python3
"""Hold `vec_oracle.swg_real` to the C it transcribes, and to the 9B reference.

Three checks, each reported with numbers:

  1. THE TABLE.  `vec_oracle.SIG_ROM` (regenerated from fx_init()'s formula)
     against mem/luts/sig_lut.mem, the file rtl/fixed_luts_pkg.vhd is
     generated from.  vec_oracle already refuses to import on a mismatch;
     this prints the count so the check is visible.

  2. THE C.  A harness built from ref/fx.h with ref/test_swiglu.c's
     `swiglu_fx` body (float hb, `lroundf(hb * 4096.0f)`, fx_sigmoid_q,
     the two >> 12) exposing the per-element int64 `out_q`, run on random
     BFP vectors at several exponent pairs, against swg_real's pre-pack
     `out`.  The ONE known disagreement is the Q-conversion rounding rule
     for exp > Q -- the RTL rounds half toward +infinity, lroundf half away
     from zero, so a negative mantissa exactly on a half differs by one
     Q12 LSB -- and every disagreement is classified: it must be exactly
     that case or the check fails.  For exp <= Q the two are identical.

  3. THE 9B BLOCK-3 CASE.  R_G-3 (exp 14), R_U-3 (exp 13) from a tok0.r9bs
     capture through swg_real, against the double-precision R_H-3 the
     reference wrote.  NOT bit-identical by construction (the reference is
     double silu; this is a Q12 table), so what is reported is the
     correlation, the max relative error against max|H|, the rms relative
     error, and the same numbers for a Q-only variant (double silu, then the
     same Q12 grid and pack) so the sigmoid table's share of the error is
     separable from the grid's.

usage:  check_swg_real.py [--r9bs tok0.r9bs] [--layer 3] [--n 4096] [--seed 7]
"""
import argparse
import math
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import vec_oracle as VO  # noqa: E402

C_SRC = r"""
#include "fx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
/* ref/test_swiglu.c's swiglu_fx, with out_q exposed instead of folded back
   into a float.  Same body otherwise. */
int main(int argc, char **argv) {
    fx_init();
    int eg = atoi(argv[1]), eu = atoi(argv[2]);
    float sg = ldexpf(1.0f, -eg), su = ldexpf(1.0f, -eu);
    long g, u;
    while (scanf("%ld %ld", &g, &u) == 2) {
        float hb = (float)g * sg, hb2 = (float)u * su;
        int32_t v_q  = (int32_t)lroundf(hb  * 4096.0f);
        int32_t h2_q = (int32_t)lroundf(hb2 * 4096.0f);
        int32_t sig  = fx_sigmoid_q(v_q, 12);
        int64_t silu_q = ((int64_t)v_q * sig) >> 12;
        int64_t out_q  = (silu_q * h2_q) >> 12;
        printf("%d %d %d %lld\n", v_q, h2_q, sig, (long long)out_q);
    }
    return 0;
}
"""


def build_c(tmp):
    src = os.path.join(tmp, "swg_c.c")
    exe = os.path.join(tmp, "swg_c")
    with open(src, "w") as fp:
        fp.write(C_SRC)
    subprocess.check_call(["cc", "-O2", "-I", os.path.join(REPO, "ref"), "-o",
                           exe, src, "-lm"])
    return exe


def run_c(exe, g, u, eg, eu):
    inp = "".join("%d %d\n" % (a, b) for a, b in zip(g, u))
    out = subprocess.run([exe, str(eg), str(eu)], input=inp, text=True,
                         capture_output=True, check=True).stdout
    return [tuple(int(x) for x in ln.split()) for ln in out.splitlines()]


def check_table():
    mem = os.path.join(REPO, "mem", "luts", "sig_lut.mem")
    vals = [int(l) for l in open(mem) if l.strip()]
    diff = sum(1 for a, b in zip(vals, VO.SIG_ROM) if a != b)
    print("TABLE  sig_lut.mem vs fx_init() formula: %d of 513 differ"
          % diff)
    return diff == 0


def check_c(exe, n, seed):
    rng = random.Random(seed)
    ok = True
    cases = [(14, 13), (12, 12), (9, 10), (8, 8), (0, 0), (13, 15), (16, 14)]
    for eg, eu in cases:
        g = [rng.randint(-32768, 32767) for _ in range(n)]
        u = [rng.randint(-32768, 32767) for _ in range(n)]
        # Plant exact half ties on the conversion where exp > Q.
        if eg > 12:
            for i in range(0, n, 7):
                g[i] = -(rng.randint(1, 2000) * (1 << (eg - 12)) + (1 << (eg - 13)))
        if eu > 12:
            for i in range(0, n, 5):
                u[i] = -(rng.randint(1, 2000) * (1 << (eu - 12)) + (1 << (eu - 13)))
        c = run_c(exe, g, u, eg, eu)
        pre = []
        for a, b in zip(g, u):
            v_q = VO.bfp_to_qq(a, eg)
            h2_q = VO.bfp_to_qq(b, eu)
            sig = VO.sigmoid_q(v_q)
            silu = VO.vresize(VO.vsrl_a(v_q * sig, 12), 32)
            pre.append((v_q, h2_q, sig, VO.vresize(VO.vsrl_a(silu * h2_q, 12), 32)))
        nd = 0
        nties = 0
        nwrap = 0
        unexplained = 0
        for i in range(n):
            if c[i] == pre[i]:
                continue
            nd += 1
            # Classify.  (a) The C's out_q is int64 and the RTL's out is
            # resize32: same v_q/h2_q/sig and the C's value wraps to the
            # RTL's -- the documented wrap.  (b) A NEGATIVE mantissa on an
            # exact half of the conversion, where lroundf rounds away (down)
            # and the RTL rounds up (+1 LSB).
            if c[i][:3] == pre[i][:3] and VO.vresize(c[i][3], 32) == pre[i][3]:
                nwrap += 1
                continue
            tie_g = eg > 12 and g[i] < 0 and (abs(g[i]) % (1 << (eg - 12))) == (1 << (eg - 13))
            tie_u = eu > 12 and u[i] < 0 and (abs(u[i]) % (1 << (eu - 12))) == (1 << (eu - 13))
            if (tie_g or tie_u) and abs(c[i][0] - pre[i][0]) <= 1 \
                    and abs(c[i][1] - pre[i][1]) <= 1:
                nties += 1
            else:
                unexplained += 1
                if unexplained <= 3:
                    print("    UNEXPLAINED i=%d g=%d u=%d C=%s py=%s"
                          % (i, g[i], u[i], c[i], pre[i]))
        print("C      eg=%3d eu=%3d n=%d  differ=%d  of which: half-ties "
              "(exp>Q, negative, RTL rounds up) %d, resize32 wraps %d, "
              "UNEXPLAINED %d" % (eg, eu, n, nd, nties, nwrap, unexplained))
        if unexplained:
            ok = False
    return ok


def _stats(got, ref):
    n = len(ref)
    mx = max(abs(v) for v in ref)
    err = [got[i] - ref[i] for i in range(n)]
    maxrel = max(abs(e) for e in err) / mx
    rms_ref = math.sqrt(sum(v * v for v in ref) / n)
    rms_err = math.sqrt(sum(e * e for e in err) / n)
    mg = sum(got) / n
    mr = sum(ref) / n
    cov = sum((got[i] - mg) * (ref[i] - mr) for i in range(n))
    vg = math.sqrt(sum((v - mg) ** 2 for v in got))
    vr = math.sqrt(sum((v - mr) ** 2 for v in ref))
    corr = cov / (vg * vr)
    return corr, maxrel, rms_err / rms_ref


def check_9b(path, layer):
    import r9bs
    want = {"R_G-%d" % layer, "R_U-%d" % layer, "R_H-%d" % layer}
    recs = {r.name: r for r in r9bs.read(path, want=want)}
    if len(recs) != 3:
        print("9B     %s: records %s not all present" % (path, sorted(want)))
        return False
    g, u, h = recs["R_G-%d" % layer], recs["R_U-%d" % layer], recs["R_H-%d" % layer]
    gv, uv = [int(v) for v in g.raw], [int(v) for v in u.raw]
    mant, oe, diag = VO.swg_real(gv, uv, g.exp, u.exp)
    got = [m * 2.0 ** -oe for m in mant]
    ref = [float(v) for v in h.value]
    corr, maxrel, rmsrel = _stats(got, ref)
    print("9B     R_G-%d exp %d, R_U-%d exp %d -> swg_real o_exp %d (ref R_H-%d "
          "exp %d), shift %d, max_abs %d, sat %d"
          % (layer, g.exp, layer, u.exp, oe, layer, h.exp, diag["shift"],
             diag["max_abs"], diag["saturations"]))
    print("9B     swg_real vs double R_H-%d: corr %.6f  max|err|/max|H| %.3e  "
          "rms(err)/rms(H) %.3e" % (layer, corr, maxrel, rmsrel))
    # The Q-only variant: DOUBLE silu of the SAME Q12-converted inputs, then
    # the same Q12 grid (floor, as the RTL's shifts) and the same pack.
    # Separates the sigmoid TABLE's error from the grid's.
    out2 = []
    for a, b in zip(gv, uv):
        v_q = VO.bfp_to_qq(a, g.exp)
        h2_q = VO.bfp_to_qq(b, u.exp)
        x = v_q / 4096.0
        silu = x / (1.0 + math.exp(-x)) if x > -700 else 0.0
        out2.append(int(math.floor(silu * h2_q)))
    mx2 = max(abs(v) for v in out2)
    p = mx2.bit_length() - 1 if mx2 else 0
    sh2 = max(p - 14, 0)
    m2 = [VO.sat16(((v + (1 << (sh2 - 1))) >> sh2) if sh2 else v) for v in out2]
    got2 = [m * 2.0 ** -(12 - sh2) for m in m2]
    corr2, maxrel2, rmsrel2 = _stats(got2, ref)
    print("9B     Q12-grid-only (double silu, same conversion/grid/pack): "
          "corr %.6f  max|err|/max|H| %.3e  rms(err)/rms(H) %.3e"
          % (corr2, maxrel2, rmsrel2))
    # The reference record is ITSELF a 16-bit BFP at its own exponent (the
    # r9bs kind is bfp16), so "double" above means the double silu the
    # reference computed, quantised to 2^-h.exp.  State the two grids.
    print("9B     grids: reference R_H-%d is int16 at 2^-%d; swg_real's output "
          "is int16 at 2^-%d (Q12 caps o_exp at 12: max|out_q| %d uses %d of "
          "15 mantissa bits)" % (layer, h.exp, oe, diag["max_abs"],
                                 diag["max_abs"].bit_length()))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--r9bs", default=None)
    ap.add_argument("--layer", type=int, default=3)
    ap.add_argument("--n", type=int, default=4096)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    ok = check_table()
    with tempfile.TemporaryDirectory() as tmp:
        exe = build_c(tmp)
        ok = check_c(exe, a.n, a.seed) and ok
    if a.r9bs:
        ok = check_9b(a.r9bs, a.layer) and ok
    print("check_swg_real: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
