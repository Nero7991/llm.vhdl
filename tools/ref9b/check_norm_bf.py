#!/usr/bin/env python3
"""Check `vec_oracle.norm_bf` bit-exact against ref/rmsnorm_bf_vec.c.

TWO SOURCES OF TRUTH, both the C:

  1. sim/rmsnorm_bf_vec.txt, the committed vector file the C emits and
     sim/tb_rmsnorm_bf.vhd is gated on: every case's o_mant and o_exp.
     Its header carries (ncase, N, Q, E_EPS, M_EPS); E_EPS/M_EPS are asserted
     against the Python's own resolution of eps before any case is compared.

  2. A tiny C harness compiled from the C file's core (GDN_CHAIN_INCLUDE
     drops its main) and run on vectors THIS script generates -- including
     the x_exp 19 embedding shape (mantissa rms ~6428, absmax ~23040), which
     is the case the 2026-09-19 debugging note is about and which the C's own
     case list does not construct.  Requires a C compiler; skipped with a
     loud line if none is found.

The comparison is exact.  A tolerance here would hide a transcription error.

usage: check_norm_bf.py [--vec sim/rmsnorm_bf_vec.txt] [--no-c]
exit 0 only if every compared element and exponent agrees.
"""
import argparse
import math
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import vec_oracle as VO  # noqa: E402

C_HARNESS = r"""
#define GDN_CHAIN_INCLUDE 1
#include "%s"
/* stdin: N Q EPS then per case: xe we then N xm then N wm.  stdout: o_exp
 * then N o per case.  Ends at EOF. */
int main(void)
{
    int q; double e;
    if (scanf("%%d %%d %%lf", &N, &q, &e) != 3) return 2;
    Q = q; EPS = e;
    bf_resolve_eps();
    static int16_t xm[8192], wm[8192];
    int xe, we;
    while (scanf("%%d %%d", &xe, &we) == 2) {
        for (int i = 0; i < N; i++) { int v; scanf("%%d", &v); xm[i] = (int16_t)v; }
        for (int i = 0; i < N; i++) { int v; scanf("%%d", &v); wm[i] = (int16_t)v; }
        bf_out r;
        rmsnorm_bf_int(xm, xe, wm, we, &r);
        printf("%%d", r.o_exp);
        for (int i = 0; i < N; i++) printf(" %%d", r.o[i]);
        printf("\n");
    }
    return bf_fail ? 2 : 0;
}
"""


def check_vec_file(path):
    with open(path) as fp:
        ncase, n, q, e_eps, m_eps = [int(t) for t in fp.readline().split()]
        # the Python's own resolution of eps = 1e-6, as the docstring states
        eps = 1e-6
        py_e = 30 - int(math.floor(math.log2(eps)))
        py_m = int(round(eps * 2.0 ** py_e))
        if (py_e, py_m) != (e_eps, m_eps):
            print("check_norm_bf: E_EPS/M_EPS mismatch: file %d/%d python %d/%d"
                  % (e_eps, m_eps, py_e, py_m))
            return 1, 0
        bad = 0
        for c in range(ncase):
            hdr = [int(t) for t in fp.readline().split()]
            _c, xe, we, oe = hdr
            xm = [int(t) for t in fp.readline().split()]
            wm = [int(t) for t in fp.readline().split()]
            om = [int(t) for t in fp.readline().split()]
            o, o_exp, _d = VO.norm_bf(xm, xe, wm, we, Q=q, eps=eps)
            if o_exp != oe or o != om:
                nb = sum(1 for a, b in zip(o, om) if a != b)
                print("check_norm_bf: VEC case %d xe %d: o_exp py %d c %d, "
                      "%d/%d elements differ" % (c, xe, o_exp, oe, nb, n))
                bad += 1
    print("check_norm_bf: vec file %s: %d cases x %d elements, %d cases differ"
          % (path, ncase, n, bad))
    return bad, ncase


def gen_cases(n, seed=20260919):
    """Vectors the C's own list does not construct."""
    rnd = random.Random(seed)
    cases = []

    def bell(a):
        return int((rnd.random() + rnd.random() + rnd.random() - 1.5) * 2.0 * a)

    # The embedding: x_exp 19, mantissa rms ~6428, absmax ~19000-23000,
    # gain 1.0 +- 1/8 at w_exp 12.  Five draws.
    for _ in range(5):
        xm = [max(-32768, min(32767, bell(6428.0))) for _ in range(n)]
        wm = [4096 + rnd.randint(-512, 511) for _ in range(n)]
        cases.append(("embed", xm, 19, wm, 12))
    # The same mantissas across the whole model range of log2(rms), so the
    # mean-smaller, eps-smaller and tie branches are all exercised.
    for xe in (0, 10, 16, 20, 22, 23, 24, 26, 30, 36, 40, 44):
        xm = [max(-32768, min(32767, bell(6428.0))) for _ in range(n)]
        wm = [4096 + rnd.randint(-512, 511) for _ in range(n)]
        cases.append(("xe%d" % xe, xm, xe, wm, 12))
    # x_exp < 0 and the saturation rail
    xm = [rnd.randint(-300, 299) for _ in range(n)]
    wm = [rnd.randint(2000, 7999) for _ in range(n)]
    cases.append(("xexp_neg", xm, -4, wm, 12))
    xm = [32767 if i % 2 == 0 else -32768 for i in range(n)]
    cases.append(("sat", xm, 15, [4096] * n, 12))
    cases.append(("zero", [0] * n, 0, [4096] * n, 12))
    return cases


def check_c_harness(n, q, eps):
    cc = None
    for cand in ("cc", "gcc", "clang"):
        try:
            subprocess.run([cand, "--version"], capture_output=True, check=True)
            cc = cand
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    if cc is None:
        print("check_norm_bf: NO C COMPILER FOUND; the embedding-case check "
              "against the C harness DID NOT RUN")
        return 1, 0
    src = os.path.join(REPO, "ref", "rmsnorm_bf_vec.c")
    with tempfile.TemporaryDirectory(prefix="normbf.") as td:
        cpath = os.path.join(td, "h.c")
        with open(cpath, "w") as fp:
            fp.write(C_HARNESS % src)
        exe = os.path.join(td, "h")
        r = subprocess.run([cc, "-O1", "-o", exe, cpath, "-lm"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("check_norm_bf: C harness failed to compile:\n" + r.stderr)
            return 1, 0
        cases = gen_cases(n)
        lines = ["%d %d %g" % (n, q, eps)]
        for _tag, xm, xe, wm, we in cases:
            lines.append("%d %d" % (xe, we))
            lines.append(" ".join(str(v) for v in xm))
            lines.append(" ".join(str(v) for v in wm))
        r = subprocess.run([exe], input="\n".join(lines) + "\n",
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("check_norm_bf: C harness exited %d:\n%s" % (r.returncode, r.stderr))
            return 1, 0
        outs = [ln.split() for ln in r.stdout.strip().splitlines()]
        if len(outs) != len(cases):
            print("check_norm_bf: C harness returned %d results for %d cases"
                  % (len(outs), len(cases)))
            return 1, 0
        bad = 0
        for (tag, xm, xe, wm, we), out in zip(cases, outs):
            c_oe = int(out[0])
            c_o = [int(t) for t in out[1:]]
            o, o_exp, d = VO.norm_bf(xm, xe, wm, we, Q=q, eps=eps)
            nb = sum(1 for a, b in zip(o, c_o) if a != b)
            rms = math.sqrt(sum(v * v for v in xm) / n) * 2.0 ** -xe
            ok = (o_exp == c_oe and nb == 0)
            print("check_norm_bf: C %-9s xe %3d log2rms %7.2f o_exp py %3d c %3d "
                  "diff %d/%d gain %.6g ideal %.6g %s"
                  % (tag, xe, math.log2(rms) if rms > 0 else float("-inf"),
                     o_exp, c_oe, nb, n, d["gain"], d["ideal_gain"],
                     "ok" if ok else "MISMATCH"))
            if not ok:
                bad += 1
        return bad, len(cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vec", default=os.path.join(REPO, "sim", "rmsnorm_bf_vec.txt"))
    ap.add_argument("--no-c", action="store_true")
    ap.add_argument("--n", type=int, default=128)
    a = ap.parse_args()
    bad1, n1 = check_vec_file(a.vec)
    bad2, n2 = (0, 0) if a.no_c else check_c_harness(a.n, 12, 1e-6)
    tot_bad = bad1 + bad2
    print("check_norm_bf: %s -- %d of %d cases agree with the C"
          % ("PASS" if tot_bad == 0 else "FAIL", n1 + n2 - tot_bad, n1 + n2))
    return 1 if tot_bad else 0


if __name__ == "__main__":
    sys.exit(main())
