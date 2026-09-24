#!/usr/bin/env python3
"""fk33_vccint_test.py -- ONE-OFF, for the 2026-09-24 build-19 hang test that Oren
approved ("Small VCCINT raise on build 19"). Not a standing tool.

    FK33_USER=/dev/xdmaN_user python3 fk33_vccint_test.py raise     # toward ~0.740 V
    FK33_USER=/dev/xdmaN_user python3 fk33_vccint_test.py restore   # back to wiper 68

CLAUDE.md fixes VCCINT at wiper 68 (~0.717 V). This moves it at most to wiper
12, stopping at ~0.778 V (Oren's request, 2026-09-24): ABOVE the 0.698-0.742 V
window of the -2L 0.72 V point and below the 0.825 V floor of the 0.85 V point,
i.e. between characterised points, and below the 0.85 V CLAUDE.md forbids. Uses fk33ctl's own MMIO I2C
and SYSMON helpers (the card stays running).

Guards: ONE wiper step per write; readback after every write; SYSMON after
every step (median of 3); abort if the rail moves the wrong way or more than
10 mV in one step; if the rail ever exceeds 0.800 V or the die 70 C, step the wiper back UP
(voltage down) one step at a time to 68. It never writes 128 (0.678 V, below
the -2L floor) and never goes below wiper 12.
"""
import statistics
import sys
import time

import fk33ctl as F

W_STD, W_MIN = 68, 12
V_STOP, V_ABORT, DV_MAX, T_MAX = 0.778, 0.800, 0.010, 70.0
READ_CHECK = 100

# Oren, 2026-09-24, after the 0.740 V plan: "We need to test at the max voltage
# anyway (8.x (the vivado voltage)) so let's try going to around 7.8 ish".
# fk33ctl's pot_write clamps at wiper 68 by design; this ONE-OFF overrides it
# for this script's process only, down to W_MIN.
F.W_FLOOR = W_MIN


class SlowI2C(F.I2C):
    """fk33ctl's bit-bang with every line change flushed and held. The stock
    one issues posted MMIO writes back to back with no delay, and SCL/SDA are
    released to a pull-up, so a '1' can be sampled before it has risen:
    MEASURED 2026-09-24, one read NACK and one write that did not land."""
    def lines(self, scl, sda):
        self.m.wr(F.GPIO_TRI, (1 if scl else 0) | (2 if sda else 0))
        self.m.rd(F.GPIO_DAT)                  # flush the posted write
        t = time.perf_counter() + 20e-6        # >= 20 us per edge, ~15 kHz SCL
        while time.perf_counter() < t:
            pass


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
    # median of 9: card 2 SYSMON swings about +/-3 mV (MEASURED 2026-09-24, it
    # tripped the fall guard with a median of 3)
    return statistics.median(F.vccint(m) for _ in range(9))


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
    i2c = SlowI2C(m)
    reads = [i2c.pot_read(F.POT_ADDR) for _ in range(READ_CHECK)]
    bad = sum(1 for r in reads if r != reads[0] or r < 0)
    print("BUS CHECK  %d pot reads, %d bad, value %d" % (READ_CHECK, bad, reads[0]))
    if bad:
        raise SystemExit("ABORT: the I2C bus is not reliable enough to write the pot")
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
        t = F.die_temp(m)
        if t > T_MAX:
            step_up_to(m, i2c, W_STD, "ABORT die %.1f C > %.1f C" % (t, T_MAX))
            raise SystemExit(1)
        if nv > V_ABORT:
            step_up_to(m, i2c, W_STD, "ABORT %.4f V > %.4f V" % (nv, V_ABORT))
            raise SystemExit(1)
        if nv < v - 0.0035:
            step_up_to(m, i2c, W_STD, "ABORT rail FELL on a downward wiper step")
            raise SystemExit(1)
        if nv - v > DV_MAX:
            step_up_to(m, i2c, W_STD, "ABORT one step moved %.4f V" % (nv - v))
            raise SystemExit(1)
        v = nv
    print("RAISED  wiper %d  VCCINT %.4f V  (%s)" % (w, v, "target" if v >= V_STOP else "wiper floor %d" % W_MIN))


if __name__ == "__main__":
    main()
