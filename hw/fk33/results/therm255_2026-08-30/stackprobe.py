#!/usr/bin/env python3
"""Sample the two HBM stack temperature codes at the highest rate the BAR
allows, and report how often they disagree.

READ ONLY.  Touches THERM_TEMPS (0xB008) and THERM_STATUS (0xB000) and
nothing else.  It never writes a register, so it cannot clear a counter or
perturb the guard.

The question it exists to answer, from
docs/debugging/2026-08-30_therm255-is-two-stacks-not-two-copies.md:

    Are the two stacks routinely unequal, or only transiently at crossings?

That decides whether the fix is to drop the equality term outright or to
hold it off for N ms, so the shape of the disagreement matters more than
its rate.  Two very different worlds produce the same average:

  * many SHORT disagreements straddling a code change  -> a hold-off works
  * few LONG ones, or a persistent offset              -> a hold-off does
    not work at any N, and the equality term has to go

so this records RUN LENGTHS, not just a count.
"""
import sys, time, collections
sys.path.insert(0, "hw/fk33/host")
import fk33ctl as C

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
TAG = sys.argv[2] if len(sys.argv) > 2 else "run"

m = C.Mmio()
rd = m.rd
TEMPS, STATUS = C.THERM_TEMPS, C.THERM_STATUS

# Field positions are read off rtl: w_temps(16 downto 10) <= h0_acc,
# w_temps(23 downto 17) <= h1_acc, die in the low 10 bits.
def split(v):
    return (v & 0x3FF), ((v >> 10) & 0x7F), ((v >> 17) & 0x7F)

samples = 0
pairs = collections.Counter()
runs = collections.Counter()      # length of each consecutive-unequal run
cur = 0
trip0 = (rd(STATUS) >> 16) & 0xFF
st_seen = 0

t_end = time.time() + DUR
t0 = time.time()
while time.time() < t_end:
    for _ in range(2000):                 # amortise the clock call
        v = rd(TEMPS)
        s = rd(STATUS)
        die, h0, h1 = split(v)
        pairs[(h0, h1)] += 1
        st_seen |= s
        samples += 1
        if h0 != h1:
            cur += 1
        elif cur:
            runs[cur] += 1
            cur = 0
if cur:
    runs[cur] += 1
el = time.time() - t0
trip1 = (rd(STATUS) >> 16) & 0xFF

uneq = sum(n for (a, b), n in pairs.items() if a != b)
print(f"tag              {TAG}")
print(f"samples          {samples} in {el:.2f} s  ({samples/el:,.0f}/s, "
      f"{el/samples*1e6:.2f} us per two-register sample)")
print(f"trips            {trip0} -> {trip1}   (delta {trip1-trip0})")
print(f"STATUS bit30 (disagreement sticky) ever seen set: "
      f"{'YES' if st_seen & (1<<30) else 'no'}")
print(f"unequal samples  {uneq} of {samples}  ({100.0*uneq/samples:.4f} %)")
print("distinct (h0,h1) pairs, most common first:")
for (a, b), n in pairs.most_common(12):
    print(f"    h0={a:3d} h1={b:3d}  {n:9d}  {100.0*n/samples:7.4f} %"
          f"{'   <-- UNEQUAL' if a != b else ''}")
if runs:
    tot = sum(runs.values())
    ln = sorted(runs)
    print(f"consecutive-unequal runs: {tot} runs, "
          f"min {ln[0]} max {ln[-1]} samples "
          f"({ln[0]*el/samples*1e6:.1f} us to {ln[-1]*el/samples*1e6:.1f} us)")
    for L in ln[:10]:
        print(f"    run of {L:5d} samples x {runs[L]}")
else:
    print("consecutive-unequal runs: NONE -- the two stacks never disagreed "
          "in this window")
