#!/usr/bin/env python3
"""Read-only: sample SYSMON current-sense aux channels (raw 16-bit fractions, scale UNKNOWN)
on one card. Usage: FK33_USER=/dev/xdmaN_user isample.py <seconds> <label>"""
import sys, time, statistics
sys.path.insert(0, "/home/orencollaco/GitHub/llama.vhdl/hw/fk33/host")
import fk33ctl as F
m = F.Mmio()
CH = {"VCCINT_I": 0x15, "VCCHBM_I": 0x1c, "VCCBRAM_I": 0x1d}
dur, lab = float(sys.argv[1]), sys.argv[2]
s = {k: [] for k in CH}; v = []
t0 = time.time()
while time.time() - t0 < dur:
    for k, a in CH.items():
        s[k].append(m.rd(0x3400 + 4 * a) & 0xffff)
    v.append(F.vccint(m, 1))
    time.sleep(0.02)
out = " ".join("%s med %d p90 %d max %d" % (k, statistics.median(x), sorted(x)[int(.9*len(x))], max(x)) for k, x in s.items())
print("ISAMPLE %s %s n=%d VCCINT %.4f die %.1f %s" % (lab, F.USER, len(v), statistics.median(v), F.die_temp(m), out))
