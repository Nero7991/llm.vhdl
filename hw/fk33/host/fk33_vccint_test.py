#!/usr/bin/env python3
"""fk33_vccint_test.py -- ONE-OFF, for the 2026-09-24 build-19 hang test that Oren
approved ("Small VCCINT raise on build 19"). Not a standing tool.

    FK33_USER=/dev/xdmaN_user python3 fk33_vccint_test.py raise     # toward ~0.740 V
    FK33_USER=/dev/xdmaN_user python3 fk33_vccint_test.py restore   # back to wiper 68

CLAUDE.md fixes VCCINT at wiper 68 (~0.717 V). This moves it at most to wiper
60, stopping at 0.737 V, inside the 0.698-0.742 V window specified for -2L at
its 0.72 V operating point, and far below 0.85 V. Uses fk33ctl's own MMIO I2C
and SYSMON helpers (the card stays running).

Guards: ONE wiper step per write; readback after every write; SYSMON after
every step (median of 3); abort if the rail moves the wrong way or more than
10 mV in one step; if the rail ever exceeds 0.745 V, step the wiper back UP
(voltage down) one step at a time to 68. It never writes 128 (0.678 V, below
the -2L floor) and never goes below wiper 60.
"""
import statistics
import sys
import time

import fk33ctl as F

W_STD, W_MIN = 68, 60
V_STOP, V_ABORT, DV_MAX = 0.737, 0.745, 0.010


def pot(i2c):
    """pot_read with up to 3 tries: one NACK was MEASURED on a healthy bus
    (2026-09-24, then 6 of 6 good reads), so a single -1 is a glitch, three are not."""
    for _ in range(3):
        w = i2c.pot_read(F.POT_ADDR)
        if w >= 0:
            return w
        time.sleep(0.05)
    return -1


def rail(m):
    return statistics.median(F.vccint(m) for _ in range(3))


def set_w(i2c, w):
    if not W_MIN <= w <= 128:
        raise SystemExit("refusing wiper %d" % w)
    if i2c.pot_write(F.POT_ADDR, w) != 0:
        raise SystemExit("pot did not acknowledge wiper %d" % w)
    time.sleep(0.3)
    rb = pot(i2c)
    if rb != w:
        raise SystemExit("wiper readback %d != %d" % (rb, w))


def step_up_to(m, i2c, goal, why):
    """wiper UP one at a time (voltage down, the safe direction) to `goal`."""
    w = pot(i2c)
    v = rail(m)
    print("%s: wiper %d  %.4f V -> wiper %d" % (why, w, v, goal))
    while w < goal:
        set_w(i2c, w + 1)
        w += 1
        nv = rail(m)
        print("  wiper %3d  VCCINT %.4f V  (%+.4f)  die %.1f C" % (w, nv, nv - v, F.die_temp(m)))
        if nv > v + 0.002:
            raise SystemExit("ABORT: rail ROSE on an upward wiper step; stopping where it is")
        v = nv
    return w, v


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    m = F.Mmio()
    i2c = F.I2C(m)
    w = pot(i2c)
    v = rail(m)
    print("START  %s  wiper %d  VCCINT %.4f V  die %.1f C" % (F.USER, w, v, F.die_temp(m)))
    if w < 0 or not W_MIN <= w <= 128:
        raise SystemExit("ABORT: wiper reads %d; not touching anything" % w)
    if mode == "restore":
        w, v = step_up_to(m, i2c, W_STD, "RESTORE")
        print("RESTORED  wiper %d  VCCINT %.4f V" % (w, v))
        return
    if mode != "raise":
        raise SystemExit("usage: fk33_vccint_test.py raise|restore")
    while v < V_STOP and w > W_MIN:
        set_w(i2c, w - 1)
        w -= 1
        nv = rail(m)
        print("  wiper %3d  VCCINT %.4f V  (%+.4f)  die %.1f C" % (w, nv, nv - v, F.die_temp(m)))
        if nv > V_ABORT:
            step_up_to(m, i2c, W_STD, "ABORT %.4f V > %.4f V" % (nv, V_ABORT))
            raise SystemExit(1)
        if nv < v - 0.002:
            step_up_to(m, i2c, W_STD, "ABORT rail FELL on a downward wiper step")
            raise SystemExit(1)
        if nv - v > DV_MAX:
            step_up_to(m, i2c, W_STD, "ABORT one step moved %.4f V" % (nv - v))
            raise SystemExit(1)
        v = nv
    print("RAISED  wiper %d  VCCINT %.4f V  (%s)" % (w, v, "target" if v >= V_STOP else "wiper floor %d" % W_MIN))


if __name__ == "__main__":
    main()
