#!/usr/bin/env python3
"""Top-k logits of the 27B from a FINAL residual row (l_out-63 at one position), on the CPU:
rmsnorm(x) * output_norm.weight, then output.weight (Q6_K, dequantised by gguf-py in row
chunks).  Validated by feeding llama.cpp's own l_out-63: it must reproduce llama.cpp's
argmax and top-k logprobs.

usage: lmhead_from_x.py --ref REF.r9bs [--tok T]        llama.cpp's l_out-63 at tok T (default last)
       lmhead_from_x.py --card XOUT_B.txt               the card's R_X after die B's last GO"""
import sys, argparse; sys.path.insert(0, '/home/orencollaco/GitHub/llama.vhdl/tools/ref9b')
import numpy as np, r9bs
from gguf import GGUFReader
from gguf.quants import dequantize
GG = '/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf'
ap = argparse.ArgumentParser(); ap.add_argument('--ref'); ap.add_argument('--tok', type=int)
ap.add_argument('--card'); ap.add_argument('--k', type=int, default=10)
ap.add_argument('--show', default='7732,5449,1206,2064,89454')
a = ap.parse_args()
if a.card:
    t = open(a.card).read().split(); assert t[0] == 'exp'
    x = np.array([int(v) for v in t[2:]], dtype=np.float64) * 2.0 ** -int(t[1]); src = 'card ' + a.card
else:
    recs = [r for r in r9bs.read(a.ref) if r.name == 'l_out-63']
    tk = a.tok if a.tok is not None else max(r.tok for r in recs)
    x = [r for r in recs if r.tok == tk][-1].value; src = 'llama.cpp l_out-63 tok %d' % tk
R = GGUFReader(GG); T = {t.name: t for t in R.tensors}
eps = float(R.fields['qwen35.attention.layer_norm_rms_epsilon'].parts[-1][0])
w = np.asarray(T['output_norm.weight'].data, dtype=np.float64).reshape(-1)
xn = x / np.sqrt((x * x).mean() + eps) * w
ow = T['output.weight']; raw = ow.data; nv = raw.shape[0]
logits = np.empty(nv)
for s in range(0, nv, 16384):
    W = dequantize(raw[s:s + 16384], ow.tensor_type).astype(np.float32)
    logits[s:s + W.shape[0]] = W.astype(np.float64) @ xn
lp = logits - (np.log(np.exp(logits - logits.max()).sum()) + logits.max())
top = np.argsort(-logits)[:a.k]
print('source', src, '| n_vocab', nv, '| eps', eps)
for i, v in enumerate(top): print('top%-2d %6d logit %9.4f logprob %8.4f' % (i + 1, v, logits[v], lp[v]))
for v in [int(s) for s in a.show.split(',') if s]:
    print('id %6d rank %d logit %9.4f logprob %8.4f' % (v, int((logits > logits[v]).sum()) + 1, logits[v], lp[v]))
print('LMHEAD_ARGMAX %d' % top[0])
