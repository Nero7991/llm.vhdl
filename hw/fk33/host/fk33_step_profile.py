#!/usr/bin/env python3
"""fk33_step_profile.py -- per-step cycle timeline of ONE token on the card.

Polls the seam's STEPS_ISS (issues since GO) and ISSUE_CYC (CYCLES at the
last issue) as fast as pread allows while run_prompt drives one GO, records
every (step, issue_cycle) transition it sees, and prints each step's
duration in core cycles against the D table's step listing.  A step whose
issue the poll missed is folded into its predecessor and marked '+'.

Run it FROM run_prompt's side: start this first, it waits for STEPS_ISS to
leave 0.  Opens /dev/xdma0_user (a human runs it).
"""
import os, sys, time, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fk33ctl as F
steps_txt = sys.argv[1]            # the `--print` step listing (step opcode src ...)
out_path  = sys.argv[2]
fd = os.open(F.USER, os.O_RDONLY)
def rd(off): return struct.unpack("<I", os.pread(fd, 4, off))[0]
# wait for a GO: STEPS_ISS holds the PREVIOUS token's count until GO clears
# it, so wait for it to change (to 0), then for the first issue.
t_end = time.time() + 120
n0 = rd(F.SEAM_STEPS_ISS)
while rd(F.SEAM_STEPS_ISS) == n0 and time.time() < t_end: pass
while rd(F.SEAM_STEPS_ISS) == 0 and time.time() < t_end: pass
seen = {}
last = -1; idle = 0
while True:
    n = rd(F.SEAM_STEPS_ISS); c = rd(F.SEAM_ISSUE_CYC)
    if n != last:
        seen[n] = c; last = n; idle = 0
    else:
        idle += 1
        if idle > 600000: break          # ~1 s with nothing new: token over
tot = rd(F.SEAM_CYCLES)
names = {}
for line in open(steps_txt):
    f = line.split()
    if len(f) >= 3 and f[0].isdigit():
        names[int(f[0])] = (f[1], f[-1] if f[-1] != f[1] else "")
ks = sorted(seen)
rows = []
for i, k in enumerate(ks):
    nxt = seen[ks[i+1]] if i+1 < len(ks) else tot
    dur = nxt - seen[k]
    # issue count n means step n-1 was the last issued
    st = k - 1
    gap = ks[i+1] - k if i+1 < len(ks) else 1
    rows.append((st, dur, gap))
with open(out_path, "w") as o:
    o.write("# step dur_cycles folded_steps opcode tensor\n")
    for st, dur, gap in rows:
        op, tn = names.get(st, ("?", ""))
        o.write("%d %d %d %s %s\n" % (st, dur, gap, op, tn))
    o.write("# total %d cycles, %d transitions seen of %d steps\n" % (tot, len(ks), len(names)))
print("wrote %s: %d transitions, total %d cycles" % (out_path, len(ks), tot))
