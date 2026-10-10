#!/usr/bin/env python3
"""Card R_X (run_prompt --dump-xout format: `exp E`, then n_embd int16) against llama.cpp's
l_out-<layer> at the LAST prompt position, in float.  Prints the same metrics for the
neighbouring layers and positions, so the alignment (which layer, which token) is checked
rather than assumed: the right (layer, tok) must be the best match.

usage: xout_vs_lout.py CARD.txt REF.r9bs LAYER"""
import sys; sys.path.insert(0, '/home/orencollaco/GitHub/llama.vhdl/tools/ref9b')
import r9bs, numpy as np
dump, ref, layer = sys.argv[1], sys.argv[2], int(sys.argv[3]); want_tok = int(sys.argv[4]) if len(sys.argv) > 4 else None
t = open(dump).read().split()
assert t[0] == 'exp', t[:2]
cexp = int(t[1]); cm = np.array([int(x) for x in t[2:]], dtype=np.float64)
card = cm * 2.0 ** -cexp
R = {}
for r in r9bs.read(ref):
    if r.name.startswith('l_out-'):
        R[(int(r.name.split('-')[1]), r.tok)] = r.value
last = want_tok if want_tok is not None else max(k[1] for k in R)
def metrics(x, y):
    c = float(np.corrcoef(x, y)[0, 1])
    rel = float(np.sqrt(((x - y) ** 2).mean()) / np.sqrt((y ** 2).mean()))
    s = float((x @ y) / (y @ y))
    return c, rel, s
print("card exp %d n %d  nonzero %d  rms %.4g" % (cexp, len(card), int((cm != 0).sum()), np.sqrt((card ** 2).mean())))
print("ref  last tok %d  n %d  rms(l_out-%d) %.4g" % (last, len(R[(layer, last)]), layer, np.sqrt((R[(layer, last)] ** 2).mean())))
best = None
for L in range(max(0, layer - 2), min(63, layer + 2) + 1):
    for tk in sorted({max(0, last - 1), last, min(22, last + 1)}):
        c, rel, s = metrics(card, R[(L, tk)])
        mark = '  <- target' if (L, tk) == (layer, last) else ''
        print("l_out-%-2d tok %2d  corr %.5f  rel_rms %.4f  fit_scale %.4f%s" % (L, tk, c, rel, s, mark))
        if best is None or c > best[0]: best = (c, L, tk)
print("BEST l_out-%d tok %d corr %.5f" % (best[1], best[2], best[0]))
c, rel, s = metrics(card, R[(layer, last)])
y = R[(layer, last)]; d = card - y; top = np.argsort(-np.abs(d))[:8]
print("largest |card-ref| elements:", ", ".join("%d: card %.3g ref %.3g" % (i, card[i], y[i]) for i in top))
print("XOUT_VS_LOUT layer %d tok %d corr %.5f rel_rms %.4f aligned %s" % (layer, last, c, rel, "YES" if best[1:] == (layer, last) else "NO"))
