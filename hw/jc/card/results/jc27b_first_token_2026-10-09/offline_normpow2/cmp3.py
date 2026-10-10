#!/usr/bin/env python3
"""cmp3.py A B [A B ...]: corr / rel_rms / fit_scale of A against B (B is the reference).
Each file: `exp E` + int16 mantissas (run_prompt --dump-xout, run9b --x-out bfp) or floats."""
import sys, numpy as np
def load(p):
    t = open(p).read().split()
    if t[0] == 'exp':
        return np.array([float(x) for x in t[2:]]) * 2.0 ** -int(t[1])
    return np.array([float(x) for x in t])
def metrics(x, y):
    return (float(np.corrcoef(x, y)[0, 1]),
            float(np.sqrt(((x - y) ** 2).mean()) / np.sqrt((y ** 2).mean())),
            float((x @ y) / (y @ y)))
a = sys.argv[1:]
for i in range(0, len(a), 2):
    x, y = load(a[i]), load(a[i + 1])
    assert len(x) == len(y), (a[i], len(x), a[i+1], len(y))
    c, r, s = metrics(x, y)
    print("%-34s vs %-34s corr %.5f rel_rms %.4f fit_scale %.4f" % (a[i], a[i + 1], c, r, s))
