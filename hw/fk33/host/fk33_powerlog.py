#!/usr/bin/env python3
"""fk33_powerlog.py -- log one FK33's SYSMON current codes next to the bench supply's
12 V reading, for calibrating the current channels (docs/2026-09-24_lab-supply-card-power.md).

    FK33_USER=/dev/xdmaN_user python3 fk33_powerlog.py <label> [seconds] [--psu /dev/ttyUSBn]

READ-ONLY on both ends. The card: MMIO reads of SYSMON only. The supply (Kiprim DC310S,
SCPI over CH340 serial, 115200 8N1, CR LF): `*IDN?`, `MEASure:VOLTage?`, `MEASure:CURRent?`
only. It never sends OUTPut, VOLTage or CURRent, so the operator owns the supply's state.
It refuses a port whose *IDN? does not name the DC310S / SPE3103, because several CH340
ports are present on this box and a port number is not an identity.

Prints one `POWERLOG` summary line per label (medians), and writes every sample to
<label>.csv in the current directory.
"""
import argparse
import csv
import statistics
import sys
import time

import serial   # pyserial

import fk33ctl as F

AUX = {"VCCINT_I": 0x15, "VCCHBM_I": 0x1c, "VCCINTIO_BRAM_I": 0x1d}
VOLT = {"VCCINT": 0x01, "VCCBRAM": 0x06}


def psu_open(port):
    s = serial.Serial(port, 115200, timeout=1.0)
    idn = q(s, "*IDN?")
    if not any(k in idn.upper() for k in ("DC310S", "SPE3103")):
        raise SystemExit("REFUSED: %s answers *IDN? with %r, not the Kiprim DC310S" % (port, idn))
    return s, idn


def q(s, cmd):
    s.reset_input_buffer()
    s.write((cmd + "\r\n").encode())
    return s.readline().decode(errors="replace").strip()


def code(m, a):
    return m.rd(0x3400 + 4 * a) & 0xffff


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("seconds", nargs="?", type=float, default=20.0)
    ap.add_argument("--psu", default="/dev/ttyUSB0")
    a = ap.parse_args()
    s, idn = psu_open(a.psu)
    m = F.Mmio()
    rows = []
    t0 = time.time()
    while time.time() - t0 < a.seconds:
        r = {"t": round(time.time() - t0, 3)}
        r.update({k: code(m, v) for k, v in AUX.items()})
        r.update({k: round(code(m, v) * 3.0 / 65536, 5) for k, v in VOLT.items()})
        r["psu_V"] = float(q(s, "MEASure:VOLTage?") or "nan")
        r["psu_A"] = float(q(s, "MEASure:CURRent?") or "nan")
        r["die_C"] = round(F.die_temp(m), 2)
        rows.append(r)
    with open(a.label + ".csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    med = {k: statistics.median(r[k] for r in rows) for k in rows[0] if k != "t"}
    print("POWERLOG %s %s n=%d psu %.3f V %.4f A = %.3f W | %s | PSU %s" % (
        a.label, F.USER, len(rows), med["psu_V"], med["psu_A"], med["psu_V"] * med["psu_A"],
        " ".join("%s %g" % (k, med[k]) for k in list(AUX) + list(VOLT) + ["die_C"]), idn))


if __name__ == "__main__":
    sys.exit(main())
