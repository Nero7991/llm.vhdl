#!/usr/bin/env python3
"""Tests for fk33ctl.py that need no card, no driver and no root.

Two things are checked, and both are checked by BREAKING them:

  1. the wiper floor.  Lower wiper means higher VCCINT, so the floor is the
     overvoltage guard.  The standing hardware instruction is that VCCINT must
     never be taken to 0.85 V and that the target is wiper 68 / ~0.717 V.  A
     guard that has never been seen to refuse anything is not evidence.

  2. the -1 / all-ones / all-zeroes classifier.  A read that never happened
     must not be reported as a read that returned the wrong data.
"""
import io
import os
import sys
import unittest.mock as mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fk33ctl                                          # noqa: E402

FAILS = []


def check(label, cond, detail=""):
    if cond:
        print(f"    ok   {label}")
    else:
        print(f"    FAIL {label}{': ' + detail if detail else ''}")
        FAILS.append(label)


class FakeMmio:
    """Records every write.  Reads return whatever the script needs to keep
    the bit-bang going; the point is the write log, not the traffic."""

    def __init__(self):
        self.writes = []

    def rd(self, off):
        return 0x2   # SDA high: every ACK reads as 1, i.e. NACK.  Fine here.

    def wr(self, off, val):
        self.writes.append((off, val))


print("--- 1. the wiper floor is 68, and it is enforced at the write itself")
check("W_FLOOR is 68", fk33ctl.W_FLOOR == 68, f"got {fk33ctl.W_FLOOR}")
check("W_ABSOLUTE_FLOOR is 68", fk33ctl.W_ABSOLUTE_FLOOR == 68)

i2c = fk33ctl.I2C.__new__(fk33ctl.I2C)
i2c.m = FakeMmio()

for w in (0, 1, 59, 60, 64, 67):
    try:
        i2c.pot_write(fk33ctl.POT_ADDR, w)
        check(f"pot_write({w}) must be refused", False, "it was accepted")
    except ValueError as e:
        check(f"pot_write({w}) refused", "below the floor" in str(e))

print("--- 1b. and the sanctioned values are still allowed, so the guard is")
print("        a floor and not a wall")
for w in (68, 69, 100, 128, 255):
    n_before = len(i2c.m.writes)
    try:
        i2c.pot_write(fk33ctl.POT_ADDR, w)
        check(f"pot_write({w}) accepted", len(i2c.m.writes) > n_before)
    except ValueError as e:
        check(f"pot_write({w}) accepted", False, str(e))

print("--- 1c. out-of-range values are still rejected as before")
for w in (-1, 256, 1000):
    try:
        i2c.pot_write(fk33ctl.POT_ADDR, w)
        check(f"pot_write({w}) rejected", False, "accepted")
    except ValueError as e:
        check(f"pot_write({w}) rejected", "out of range" in str(e))

print("--- 1d. 60 used to be the floor.  Prove the change is real by showing")
print("        the OLD floor value is now refused")
try:
    i2c.pot_write(fk33ctl.POT_ADDR, 60)
    check("the old floor 60 is now refused", False, "still accepted")
except ValueError:
    check("the old floor 60 is now refused", True)

print("--- 1e. 0.85 V is roughly wiper 0-ish on this pot; nothing near it is")
print("        reachable by any argument to pot_write")
reachable = []
for w in range(0, 256):
    try:
        i2c.pot_write(fk33ctl.POT_ADDR, w)
        reachable.append(w)
    except ValueError:
        pass
check("the lowest writable wiper is exactly 68",
      reachable and min(reachable) == 68, f"min={min(reachable) if reachable else None}")

print("--- 2. a failed read must never be described as wrong data")
d_ones = fk33ctl.describe_dead_word(0xFFFFFFFF)
d_neg1 = fk33ctl.describe_dead_word(-1)
d_zero = fk33ctl.describe_dead_word(0)
d_junk = fk33ctl.describe_dead_word(0x12345678)
check("all-ones says NOT A VALUE", "NOT A VALUE" in d_ones)
check("-1 is classified the same as all-ones", d_neg1 == d_ones)
check("all-ones does NOT claim a bitstream mismatch",
      "not this bitstream" not in d_ones)
check("all-zeroes says NOT A VALUE", "NOT A VALUE" in d_zero)
check("all-zeroes names reset/unclocked, not a mismatch",
      "unclocked or held" in d_zero and "not this bitstream" not in d_zero)
check("a genuine wrong value IS called a mismatch",
      "genuine value mismatch" in d_junk and "NOT A VALUE" not in d_junk)
check("the three cases produce three different messages",
      len({d_ones, d_zero, d_junk}) == 3)

print("--- 3. cmd_id must route each case through the classifier")
for magic, expect, forbid in (
        (fk33ctl.ID_MAGIC, "OK --", "NOT A VALUE"),
        (0xFFFFFFFF, "NOT A VALUE", "not this bitstream"),
        (0x00000000, "NOT A VALUE", "not this bitstream"),
        (0xDEADBEEF, "genuine value mismatch", "NOT A VALUE")):
    fake = FakeMmio()
    fake.rd = lambda off, _m=magic: _m if off == fk33ctl.ID_MAGIC_OFF else 0x20260828
    buf = io.StringIO()
    with mock.patch.object(fk33ctl, "Mmio", lambda *a, **k: fake), \
         mock.patch.object(fake, "close", lambda: None, create=True), \
         mock.patch("sys.stdout", buf):
        fk33ctl.cmd_id(None)
    out = buf.getvalue()
    check(f"magic 0x{magic:08x} -> '{expect}'", expect in out, out.strip())
    check(f"magic 0x{magic:08x} does not say '{forbid}'", forbid not in out)

print()
if FAILS:
    print(f"FK33CTL_TESTS FAIL ({len(FAILS)})")
    sys.exit(1)
print("FK33CTL_TESTS OK")
