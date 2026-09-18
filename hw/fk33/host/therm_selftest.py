#!/usr/bin/env python3
"""Fire the thermal guard on purpose, at room temperature, and prove it halts.

WHY THIS EXISTS.  Everything verified on silicon so far is the guard's
REPORTING path: it says 35.3 C, die_valid=1, armed=1, HALTED no.  Nothing has
ever made it say HALTED yes.  A protection mechanism that has never been
observed to fire is a protection mechanism that has never been tested, and the
first time it matters is the worst time to discover it is mis-wired.

HOW IT FIRES WITHOUT HEAT.  SYSMON carries its own programmable temperature
comparator, user_temp_alarm_out, whose trip and reset points live in DRP
registers 0x50 and 0x54.  Those are writable at runtime.  Drop the trip point
BELOW the current die temperature and SYSMON asserts the alarm exactly as it
would at 90 C.  The alarm is an independent hardware comparator that shares no
logic with the fabric guard's own comparison, so this exercises the real
sysmon_alarm -> cause -> halt -> compute_halt path end to end.

WHAT MAKES THE RESULT MEAN ANYTHING.  The canary is a counter that advances in
the compute domain ONLY while the guard is releasing work.  "Canary frozen
while halted" proves nothing on its own, because a canary that is broken and
always frozen would give the same reading.  So this test measures the canary
THREE times: advancing before the halt, frozen during it, advancing again
after.  The before-measurement is the control and it is not optional.

WHAT IT REFUSES TO TOUCH.  DRP 0x53 is the OT limit, whose low nibble arms an
automatic device shutdown (INIT_53 = 0xBFD3 on this build).  It is the
die-destruction backstop and it is deliberately left at 101 C.  Writing it low
would trigger a real power-down.  This script has an address ALLOWLIST of
exactly two registers, so no typo can reach 0x53.

REVERSIBILITY.  DRP writes persist only until the next FPGA configuration, so
a reconfigure restores the 90/75 points even if this script dies halfway.  The
restore is in a finally block regardless.

    ./therm_selftest.py            # run it
    ./therm_selftest.py --status   # read the alarm registers, write nothing
"""
import os
import sys
import time
import struct
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fk33ctl import (Mmio, THERM_STATUS, THERM_TEMPS, THERM_TRIP,
                     THERM_CANARY, THERM_CTL, THERM_KEY, THERM_CAUSE,
                     describe_dead_word)

# ---------------------------------------------------------------- addresses
#
# system_management_wiz_0 is assigned at AXI-Lite 0x3000 (build_fk33_pcieep.tcl:
# assign_bd_address -offset 0x00003000 ... system_management_wiz_0/S_AXI_LITE).
# The wizard maps the SYSMON DRP file uniformly at
#
#       AXI offset = base + 0x400 + 4 * drp_addr
#
# THE WINDOW STARTS AT +0x400, NOT +0x200.  The 7-series XADC Wizard puts its
# status file at +0x200 and its control file at +0x300, and assuming the
# UltraScale System Management Wizard did the same put every address here
# 0x200 low: drp(0x00) landed on 0x3200, which is unmapped, and read back a
# temperature of -279.4 C.
#
# The offset below is not arithmetic, it is IDENTIFICATION.  A read-only dump
# of the whole 4K window finds 0xBFD3 at 0x354c, and 0xBFD3 is INIT_53, this
# build's OT limit, with the low nibble 0x3 that arms automatic shutdown.  That
# one distinctive word anchors DRP 0x53, and from it 0x50 and 0x54 fall at
# 0x3540 and 0x3550 -- where the dump duly finds 0xBA51 (90 C) and 0xB2C0
# (75 C), the two points gen_pcieep.py asked for.  It also reproduces
# fk33ctl.py's working SYSMON_TEMP = 0x3400 from DRP 0x00.
SYSMON_BASE = 0x3000


def drp(a):
    return SYSMON_BASE + 0x400 + 4 * a


DRP_TEMP        = 0x00     # measured temperature, read only
DRP_ALARM_TRIP  = 0x50     # user temperature alarm, upper (assert) point
DRP_OT_TRIP     = 0x53     # OT limit.  NEVER WRITTEN.  Listed so it is named.
DRP_ALARM_RESET = 0x54     # user temperature alarm, lower (deassert) point

# The allowlist.  Not a convention, an enforcement: wr() below refuses anything
# else, so the OT register cannot be reached by a mistyped constant.
WRITABLE = {drp(DRP_ALARM_TRIP), drp(DRP_ALARM_RESET)}

# The build's configured points, from gen_pcieep.py:
#   CONFIG.TEMPERATURE_ALARM_TRIGGER {90}  CONFIG.TEMPERATURE_ALARM_RESET {75}
CFG_TRIP_C, CFG_RESET_C = 90, 75

# UG580 transfer function, same constants the RTL uses (fk33_thermal.vhd
# C_TDEN and sysmon_degc), not fk33ctl.py's rounded 507.6.
T_SCALE, T_OFFS = 507.5921310, 279.42657680


def code_of(degc):
    """Degrees C -> a 16-bit alarm register value.

    The alarm registers hold the measurement's TOP 12 BITS, so the low nibble
    is masked off.  Leaving junk there does not break anything, but it makes
    the read-back comparison below fail for no reason.
    """
    c = int(round((degc + T_OFFS) * 65536.0 / T_SCALE))
    return max(0, min(0xFFFF, c)) & 0xFFF0


def degc_of(code):
    return code * T_SCALE / 65536.0 - T_OFFS


def rd(m, off):
    return m.rd(off)


def wr(m, off, val):
    if off not in WRITABLE:
        raise SystemExit(
            f"REFUSED: {off:#06x} is not in the writable allowlist.\n"
            f"Only the user temperature alarm trip ({drp(DRP_ALARM_TRIP):#06x}) "
            f"and reset ({drp(DRP_ALARM_RESET):#06x}) may be written.\n"
            f"DRP 0x53 ({drp(DRP_OT_TRIP):#06x}) is the OT shutdown limit and is "
            f"never a legitimate target.")
    m.wr(off, val)


# ---------------------------------------------------------------- reporting

def status_line(st):
    return (f"halted={st & 1}  warn={(st >> 1) & 1}  armed={(st >> 2) & 1}  "
            f"die_valid={(st >> 3) & 1}  hbm_valid={(st >> 4) & 1}  "
            f"alarm_live={(st >> 26) & 1}  alarm_sticky={(st >> 27) & 1}  "
            f"trips={(st >> 16) & 0xFF}  "
            f"cause={THERM_CAUSE.get((st >> 8) & 0xF, '?')}")


def canary_rate(m, seconds=0.5):
    """Return (delta, elapsed).  Delta is toggles seen in the aux domain."""
    a = rd(m, THERM_CANARY)
    t0 = time.time()
    time.sleep(seconds)
    b = rd(m, THERM_CANARY)
    return (b - a) & 0xFFFFFFFF, time.time() - t0


def show_alarm_regs(m):
    t = rd(m, drp(DRP_ALARM_TRIP))
    r = rd(m, drp(DRP_ALARM_RESET))
    o = rd(m, drp(DRP_OT_TRIP))
    print(f"  alarm trip   DRP 0x50 @ {drp(DRP_ALARM_TRIP):#06x} = {t:#06x}"
          f"  = {degc_of(t):6.1f} C")
    print(f"  alarm reset  DRP 0x54 @ {drp(DRP_ALARM_RESET):#06x} = {r:#06x}"
          f"  = {degc_of(r):6.1f} C")
    print(f"  OT limit     DRP 0x53 @ {drp(DRP_OT_TRIP):#06x} = {o:#06x}"
          f"  = {degc_of(o & 0xFFF0):6.1f} C   (never written)")
    return t, r


def wait_for(m, want_halted, timeout=3.0):
    """Poll THERM_STATUS until halted matches, or time out.  Returns (ok, st)."""
    end = time.time() + timeout
    st = rd(m, THERM_STATUS)
    while time.time() < end:
        st = rd(m, THERM_STATUS)
        if (st & 1) == want_halted:
            return True, st
        time.sleep(0.01)
    return False, st


# ---------------------------------------------------------------- the test

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true",
                    help="read and decode the alarm registers, write nothing")
    ap.add_argument("--trip-c", type=float, default=None,
                    help="synthetic trip point in C (default: 5 C below die)")
    a = ap.parse_args()

    m = Mmio()
    fail = []
    # Checks that could NOT be made, as distinct from checks that failed.  A
    # PASS that quietly skipped a check is the shape this file was already
    # vulnerable to at the trip counter's 255 ceiling, so a skip is printed
    # next to the verdict rather than swallowed.
    inconclusive = []
    # Set the instant the FIRST write lands, and checked by the restore in the
    # finally block.  Without it --status, whose contract is "write nothing",
    # ran the restore on its way out and rewrote the trip register from 0xba51
    # to 0xba50.  The effect was harmless -- the low nibble is below the
    # comparator's resolution -- but a read-only mode that writes is a broken
    # read-only mode, and the next such bug will not be harmless.
    modified = False

    try:
        st = rd(m, THERM_STATUS)
        if st in (0, 0xFFFFFFFF):
            sys.exit(f"THERM_STATUS = {st:#010x}\n" + describe_dead_word(st))
        if not (st >> 31) & 1:
            sys.exit(f"THERM_STATUS = {st:#010x}\n"
                     "bit 31 is 0, so this bitstream has NO thermal guard.  "
                     "Load fk33_pcieep_therm.bit.")

        die = degc_of(rd(m, drp(DRP_TEMP)))
        print(f"die temperature   {die:.1f} C")
        print(f"THERM_STATUS      {st:#010x}")
        print(f"  {status_line(st)}")
        print("SYSMON user temperature alarm, as programmed:")
        cfg_trip, cfg_reset = show_alarm_regs(m)

        # ---- gate 1: the addresses decode to what the build asked for.
        # This is the check that makes every write below safe.  It also
        # verifies for the FIRST TIME ON SILICON that the alarm really was
        # programmed to 90/75 -- until now that was known only from a block
        # design CONFIG property, and reading a CONFIG property reads a
        # REQUEST, not an answer.
        # Compare the TOP 12 BITS only.  The comparator uses just those, and
        # the trip register reads back 0xBA51 rather than 0xBA50 -- SYSMON
        # does not clear the low nibble, so an exact match would fail on a
        # correctly programmed part.
        want_trip, want_reset = code_of(CFG_TRIP_C), code_of(CFG_RESET_C)
        cfg_trip, cfg_reset = cfg_trip & 0xFFF0, cfg_reset & 0xFFF0
        if cfg_trip != want_trip or cfg_reset != want_reset:
            sys.exit(
                f"\nSTOP.  The alarm registers do not hold the configured "
                f"{CFG_TRIP_C}/{CFG_RESET_C} C.\n"
                f"  trip  read {cfg_trip:#06x} ({degc_of(cfg_trip):.1f} C), "
                f"expected {want_trip:#06x} ({CFG_TRIP_C} C)\n"
                f"  reset read {cfg_reset:#06x} ({degc_of(cfg_reset):.1f} C), "
                f"expected {want_reset:#06x} ({CFG_RESET_C} C)\n"
                "Either the address arithmetic is wrong or the alarm was never "
                "programmed.\nEITHER WAY, DO NOT WRITE.  Writing a register "
                "whose identity is unproven is\nhow you hit DRP 0x53 by "
                "accident.")
        print(f"  OK: both match the configured {CFG_TRIP_C}/{CFG_RESET_C} C, "
              "so these addresses are the alarm registers.")

        if a.status:
            return 0

        # ---- gate 2: the card must be COLD and IDLE before a synthetic trip.
        if not (5.0 <= die <= 60.0):
            sys.exit(f"\nSTOP.  die temperature {die:.1f} C is outside the "
                     "5..60 C band this test is willing to run in.\n"
                     "Below 5 C the reading is suspect; above 60 C the card is "
                     "genuinely warm and a\nsynthetic trip would mask a real "
                     "one.")
        if st & 1:
            sys.exit("\nSTOP.  the guard is ALREADY halted.  Investigate that "
                     "first; a synthetic trip\nwould tell you nothing.")
        if not (st >> 2) & 1:
            sys.exit("\nSTOP.  armed=0, so the guard has never released "
                     "compute.  There is nothing to halt.")

        trip_c = a.trip_c if a.trip_c is not None else die - 5.0
        reset_c = trip_c - 5.0
        if trip_c >= die - 2.0:
            sys.exit(f"\nSTOP.  a trip point of {trip_c:.1f} C is not clearly "
                     f"below the die's {die:.1f} C.\nThe alarm might not "
                     "assert and the test would report a false negative.")

        trips_before = (st >> 16) & 0xFF

        # ---- the control measurement.  Without this, "frozen" proves nothing.
        d, el = canary_rate(m)
        print(f"\ncanary BEFORE     +{d} toggles in {el:.2f} s")
        if d == 0:
            sys.exit("STOP.  the canary is not advancing while the guard is "
                     "RELEASING work.\nThat is a fault in its own right, and it "
                     "makes the halt test meaningless:\na frozen canary during "
                     "the halt would prove nothing.")

        # ---- fire it
        print(f"\nlowering the SYSMON user alarm to "
              f"{trip_c:.1f} C trip / {reset_c:.1f} C reset "
              f"(die is {die:.1f} C, so it must assert)")
        modified = True
        wr(m, drp(DRP_ALARM_RESET), code_of(reset_c))
        wr(m, drp(DRP_ALARM_TRIP), code_of(trip_c))

        ok, st = wait_for(m, want_halted=1, timeout=3.0)
        print(f"THERM_STATUS      {st:#010x}")
        print(f"  {status_line(st)}")
        if not ok:
            fail.append("the guard did NOT halt when SYSMON asserted its "
                        "user temperature alarm")
        else:
            print("  HALTED, as it should be.")
            cause = (st >> 8) & 0xF
            if cause != 2:
                fail.append(f"halted, but the live cause is {cause} "
                            f"({THERM_CAUSE.get(cause, '?')}), expected 2 "
                            "(SYSMON user temperature alarm)")
            if not (st >> 26) & 1:
                fail.append("halted, but bit 26 (live SYSMON alarm) is 0")
            if not (st >> 27) & 1:
                fail.append("halted, but bit 27 (sticky SYSMON alarm) is 0")
            if not (st >> 7) & 1:
                fail.append("halted, but bit 7 (trip latched) is 0")
            trips_after = (st >> 16) & 0xFF
            if trips_before == 255:
                # INVERTED CONSUMER, fixed.  The counter SATURATES at 255
                # (rtl/fk33_thermal.vhd:1166), so at the ceiling
                # `trips_after == trips_before` is true no matter what the
                # guard did -- and this test WANTS it to move, so it reported
                # a working guard as broken.  Of the six consumers enumerated
                # in docs/debugging/2026-08-30_tripveto-every-consumer-of-a-
                # saturating-counter.md this is the only one whose failure
                # direction was safe, and it is still wrong: a false FAIL here
                # sends someone after a guard that is fine.  This check cannot
                # be made at the ceiling, so say so instead of answering.
                print(f"  trip count is SATURATED at {trips_before}; this "
                      f"check cannot run.\n  Clear it first "
                      f"(fk33ctl.py thermal --clear) and re-run.  NOT counted "
                      f"as a failure:\n  at 255 the counter cannot move and "
                      f"the guard may be perfectly healthy.")
                inconclusive.append("the trip-count-moved check: the counter "
                                    "was saturated at 255 before the test")
            elif trips_after == trips_before:
                fail.append(f"halted, but the trip count did not move "
                            f"({trips_before})")
            else:
                print(f"  trip count {trips_before} -> {trips_after}")

            tr = rd(m, THERM_TRIP)
            print(f"THERM_TRIP        {tr:#010x}  "
                  f"cause={THERM_CAUSE.get((tr >> 24) & 0xF, '?')}  "
                  f"die code={tr & 0x3FF}")
            if (tr >> 28) != 0x5:
                fail.append(f"THERM_TRIP top nibble is {tr >> 28:#x}, "
                            "expected 0x5")

            # ---- the measurement the whole test is for
            d, el = canary_rate(m)
            print(f"canary DURING     +{d} toggles in {el:.2f} s")
            if d != 0:
                fail.append(f"THE HALT DID NOT STOP THE COMPUTE DOMAIN: the "
                            f"canary advanced {d} toggles while halted")
            else:
                print("  frozen, so compute_halt reached the compute domain.")

    finally:
        # Restore unconditionally.  A dead script must not leave the card with
        # a 30 C trip point, which would halt the guard on every future run.
        try:
            if not modified:
                raise StopIteration          # nothing was written, restore nothing
            wr(m, drp(DRP_ALARM_TRIP), code_of(CFG_TRIP_C))
            wr(m, drp(DRP_ALARM_RESET), code_of(CFG_RESET_C))
            print(f"\nrestored the alarm to {CFG_TRIP_C}/{CFG_RESET_C} C")
            show_alarm_regs(m)
        except StopIteration:
            pass
        except Exception as e:
            print(f"\nRESTORE FAILED: {e}\n"
                  "Reconfigure the FPGA to put the alarm back.", file=sys.stderr)

    if not modified:
        return 0

    # ---- the release path, which is as much a part of the guard as the halt
    ok, st = wait_for(m, want_halted=0, timeout=5.0)
    print(f"THERM_STATUS      {st:#010x}")
    print(f"  {status_line(st)}")
    if not ok:
        fail.append("the guard did NOT release after the alarm cleared "
                    "(it should, once the minimum halt time has passed and "
                    "the die is below the resume point)")
    else:
        d, el = canary_rate(m)
        print(f"canary AFTER      +{d} toggles in {el:.2f} s")
        if d == 0:
            fail.append("released, but the canary did not resume -- the "
                        "compute domain did not restart")

    print()
    if fail:
        print("THERMAL SELFTEST FAILED")
        for f in fail:
            print(f"  - {f}")
        for f in inconclusive:
            print(f"  ? NOT CHECKED: {f}")
        return 1
    if inconclusive:
        print("THERMAL SELFTEST PASS, WITH CHECKS THAT COULD NOT RUN")
        for f in inconclusive:
            print(f"  ? NOT CHECKED: {f}")
        print("  A pass over a check that did not run is not a pass over that "
              "check.")
    else:
        print("THERMAL SELFTEST PASS")
    print("  the guard halted on a real SYSMON alarm, latched the cause, "
          "stopped the compute\n  domain, and released when the alarm cleared.")
    print("  NOTE the sticky bits (25/27) and the trip count are LEFT SET on "
          "purpose: they are\n  the record that this happened.  Clear with "
          "./fk33ctl.py thermal --clear.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
