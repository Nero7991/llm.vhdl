#!/usr/bin/env python3
"""Catch an HBM temperature code CROSSING and record what the guard did.

READ ONLY: THERM_TEMPS (0xB008) and THERM_STATUS (0xB000).  Never writes.

Why this exists.  stackprobe.py sampled 46,286,000 times across idle and a
sustained 320-job load and found the two stacks equal in every single one,
at code 38 throughout -- but the code never MOVED in that window, so it
tested nothing about the hypothesis, which is that trips happen AT a
crossing.  The earlier 30 s-granularity CSV shows the code does move
(36 <-> 38) over ~20 min, with trip bursts alongside.

So this samples continuously and records only the EVENTS: every change of
either stack code, and every change of the trip counter, each with a
timestamp.  The question it answers is whether those two event streams
coincide.

A hard limitation, stated up front because it bounds every negative
result here: one two-register sample costs ~3.9 us, while the suspected
disagreement is a few aux clocks, order 10-30 ns.  So the probability of
CATCHING a given transient in the act is under 1%.  This probe is
therefore not built to observe the disagreement directly.  It is built to
correlate trips with crossings, which are both slow enough to see.
"""
import sys, time
sys.path.insert(0, "hw/fk33/host")
import fk33ctl as C

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 1200.0
m = C.Mmio()
rd = m.rd
TEMPS, STATUS = C.THERM_TEMPS, C.THERM_STATUS

def split(v):
    return (v & 0x3FF), ((v >> 10) & 0x7F), ((v >> 17) & 0x7F)

v = rd(TEMPS); s = rd(STATUS)
die, h0, h1 = split(v)
trips = (s >> 16) & 0xFF
print(f"start  die_raw={die} h0={h0} h1={h1} trips={trips} "
      f"STATUS=0x{s:08X}", flush=True)

samples = 0
uneq = 0
t0 = time.time()
t_end = t0 + DUR
last = (h0, h1)
last_tr = trips
while time.time() < t_end:
    for _ in range(2000):
        v = rd(TEMPS); s = rd(STATUS)
        samples += 1
        _d, a, b = split(v)
        tr = (s >> 16) & 0xFF
        if a != b:
            uneq += 1
        if (a, b) != last:
            print(f"{time.time()-t0:9.3f}  CODE  {last[0]}/{last[1]} "
                  f"-> {a}/{b}   trips={tr}"
                  f"{'   UNEQUAL' if a != b else ''}", flush=True)
            last = (a, b)
        if tr != last_tr:
            print(f"{time.time()-t0:9.3f}  TRIP  {last_tr} -> {tr}   "
                  f"codes now {a}/{b}  die_raw={_d}", flush=True)
            last_tr = tr
el = time.time() - t0
print(f"end    {samples} samples in {el:.1f} s ({samples/el:,.0f}/s), "
      f"unequal seen {uneq}, trips {trips} -> {last_tr}", flush=True)
