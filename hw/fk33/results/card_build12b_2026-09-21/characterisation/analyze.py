#!/usr/bin/env python3
"""Bin per-token intervals from tstamp.py output by sequence position.
usage: analyze.py <ts> <out> <temp.log> <start_epoch>"""
import sys, re
ts, out, tlog, t0 = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
reads = [(float(a), int(b)) for a, b in
         (l.split("\t") for l in open(ts) if not l.startswith("#"))]
txt = open(out).read()
m = re.search(r"prefill\s+(\d+) ids", txt); n_prompt = int(m.group(1))
m = re.search(r"decode\s+(\d+) ids generated", txt); n_gen = int(m.group(1))
tm = re.search(r"timing.*", txt); print(tm.group(0) if tm else "no timing line")
print("prompt ids %d, generated %d, reads %d" % (n_prompt, n_gen, len(reads)))
# reads[0] is the 'resident' banner; reads[1] is the first token (end of prefill).
# The trailing reads are the "\n" + decode/timing/bytes summary lines.
tok = reads[1:1 + n_gen]
t_first = tok[0][0] - reads[0][0]
print("prefill: %d positions in %.3f s = %.4f s/pos (first token at %.3f s)"
      % (n_prompt, t_first, t_first / n_prompt, tok[0][0]))
# decode token k (k>=1) was produced at position n_prompt + k - 1 fed, i.e. the GO
# ran at position p = n_prompt + k - 1; interval = tok[k] - tok[k-1]
iv = [(n_prompt + k - 1, tok[k][0] - tok[k - 1][0]) for k in range(1, len(tok))]
bins = [(0, 128), (128, 256), (256, 512), (512, 1024), (1024, 1536), (1536, 2100)]
print("\n%-12s %6s %10s %8s" % ("positions", "n", "s/token", "tok/s"))
for lo, hi in bins:
    v = [d for p, d in iv if lo <= p < hi]
    if v:
        mean = sum(v) / len(v)
        print("%-12s %6d %10.4f %8.3f" % ("%d-%d" % (lo, hi), len(v), mean, 1 / mean))
# least-squares slope
n = len(iv); sx = sum(p for p, _ in iv); sy = sum(d for _, d in iv)
sxx = sum(p * p for p, _ in iv); sxy = sum(p * d for p, d in iv)
b = (n * sxy - sx * sy) / (n * sxx - sx * sx); a = (sy - b * sx) / n
print("\nfit: interval = %.4f s + %.3e s/pos  ->  %.0f cycles + %.1f cycles/pos at 75 MHz"
      % (a, b, a * 75e6, b * 75e6))
res = [d - (a + b * p) for p, d in iv]
print("residual rms %.2e s, max |res| %.2e s" % ((sum(r * r for r in res) / n) ** .5, max(abs(r) for r in res)))
# temperature
temps = [(int(l.split()[0]) - t0, l.split()[1]) for l in open(tlog) if not l.split()[1].startswith("poller")]
temps = [(t, float(v)) for t, v in temps if v not in ("", "None")]
pre = [v for t, v in temps if t < 0]; runp = [(t, v) for t, v in temps if 0 <= t <= reads[-1][0]]; run = [v for t, v in runp]
print("\ntemp: pre-run %d samples mean %.1f C (min %.1f max %.1f)" % (len(pre), sum(pre)/len(pre), min(pre), max(pre)))
print("temp: during %d samples mean %.1f C, min %.1f, max %.1f" % (len(run), sum(run)/len(run), min(run), max(run)))
for lo, hi in [(0, 120), (120, 300), (300, 600), (600, 900), (900, 1200), (1200, 2000)]:
    v = [x for t, x in runp if lo <= t < hi]
    if v: print("  t=%4d-%4d s: mean %.1f C max %.1f C (%d)" % (lo, hi, sum(v)/len(v), max(v), len(v)))
