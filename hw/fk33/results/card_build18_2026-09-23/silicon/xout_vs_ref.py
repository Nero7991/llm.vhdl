#!/usr/bin/env python3
"""Compare a `run_prompt --dump-xout` text file (exp E, then n_embd int16 lines) against the reference
stream's R_X-<layer> record for token 0: the exponent must match and every mantissa must be bit-exact."""
import sys; sys.path.insert(0, '/home/orencollaco/GitHub/llama.vhdl/tools/ref9b')
import r9bs, numpy as np
dump, ref, layer = sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 31
t = open(dump).read().split()
assert t[0] == 'exp', t[:2]
cexp, cm = int(t[1]), np.array([int(x) for x in t[2:]], dtype=np.int64)
r = [x for x in r9bs.read(ref) if x.name == 'R_X-%d' % layer and x.tok == 0][-1]
rm = np.frombuffer(r.raw, dtype=np.int16).astype(np.int64)
print("ref  %s exp %d n %d  first %s" % (r.name, r.exp, r.n, rm[:6].tolist()))
print("card exp %d n %d  first %s  nonzero %d" % (cexp, len(cm), cm[:6].tolist(), int((cm != 0).sum())))
ok = (cexp == r.exp) and len(cm) == r.n and bool((cm == rm).all())
if len(cm) == r.n:
    d = cm - rm; print("mismatching mantissas %d of %d; max |delta| %d" % (int((d != 0).sum()), r.n, int(np.abs(d).max())))
# Cross-format metrics.  tok0.r9bs is the llama.cpp float ANCHOR (tools/ref9b rung 1), quantised to BFP16 per seam;
# the card computes in int4/BFP, so bit-exactness against it is the wrong instrument (docs/debugging/2026-09-20, section
# 6).  Against an RTL CAPTURE the exact test above is the right one.  Both verdicts are printed and named.
cf, rf = cm.astype(float), rm.astype(float)
corr = float(np.corrcoef(cf, rf)[0, 1]) if len(cf) == len(rf) else float('nan')
rel = float(np.sqrt(((cf - rf) ** 2).mean()) / np.sqrt((rf ** 2).mean())) if len(cf) == len(rf) else float('nan')
print("anchor metrics: exp %s, corr %.5f, relative rms deviation %.4f" % ("equal" if cexp == r.exp else "DIFFERENT", corr, rel))
print("XOUT_VS_REF exact: %s   anchor: %s" % ("PASS" if ok else "FAIL",
      "PASS" if (cexp == r.exp and corr > 0.99 and rel < 0.15) else "FAIL"))
sys.exit(0 if ok else 2)
