#!/usr/bin/env python3
"""Check fk33_pcieep.xdc against the real package, without Vivado and without a card.

WHY THIS EXISTS
---------------
An XDC that names a package pin which does not exist on this device produces a
*warning* (`[Vivado 12-584] No ports matched`, or a placer error much later),
not an immediate failure, and the FK33 build is an hour long.  Every constraint
error found here is an hour not spent.

It checks four things, each of which has a distinct failure mode:

  1. Every PACKAGE_PIN named in the XDC exists in Vivado's own package file for
     xcvu33p-fsvh2104.  Catches a typo, and catches a pin copied from a
     different package (SQRL's sources also carry an fsvh2104 vs other-package
     mixture in places).

  2. Every PCIe lane pin the XDC still constrains maps to GTY quad 227.  This is
     the x4 claim.  If a lane from quad 226/225/224 is still live, the endpoint
     is not x4 and the Aurora quads are not free -- and the build would still
     succeed.

  3. The reference clock pins are the MGTREFCLK0 pair of quad 226.  The plan
     depends on inter-quad refclk routing; if these ever move, that assumption
     silently changes.

  4. No pin is constrained twice with conflicting PACKAGE_PIN values.

Exit status is non-zero on any failure, so this is usable as a gate.
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
XDC = os.path.join(HERE, "fk33_pcieep.xdc")
PKG = ("/tools/Xilinx/2023.2/Vivado/2023.2/data/parts/xilinx/virtexuplusHBM/"
       "public/ibis/pkg/xcvu33p_fsvh2104.pkg")

HOST_QUAD = "227"          # x4 endpoint = edge lanes 0-3 = GTY quad 227
REFCLK_QUAD = "226"        # AD9/AD8, deliberately in a different quad


def load_package():
    """pin -> package signal name, from Vivado's own IBIS package file.

    The [Pin Numbers] section is one line per NET, not per ball:

        AL2           | 343        MGTYRXP3_227                             AL2
        AE38          | 1          MGTAVCC_LS                               AE38
                                                                           |AG38
                                                                           |AJ38

    so a ball on a shared power net only ever appears as a `|BALL` continuation
    line.  Parsing only the primary lines finds 426 of the 2104 balls and would
    report perfectly real pins as nonexistent -- which is worse than not
    checking, because it would train you to ignore the check.
    """
    if not os.path.exists(PKG):
        sys.exit(f"ABORT: package file not found: {PKG}\n"
                 "Without it this check proves nothing, so it refuses to pass.")
    pins = {}
    primary = re.compile(r"^([A-Z]{1,2}\d{1,2})\s*\|\s*\d+\s+(\S+)")
    cont = re.compile(r"^\s*\|([A-Z]{1,2}\d{1,2})\s*$")
    net = None
    for line in open(PKG, errors="replace"):
        m = primary.match(line)
        if m:
            net = m.group(2)
            pins.setdefault(m.group(1), net)
            continue
        m = cont.match(line)
        if m and net:
            pins.setdefault(m.group(1), net)
    # The file's own [Number of Pins] is 426 NETS, which expand to 747 balls of
    # the package's 2104.  The missing ones are the ground balls, which IBIS
    # does not model.  That is fine for this check and is in fact the desired
    # semantics: a port constrained to a ball that is absent here is either a
    # typo or an attempt to constrain a ground ball, and both are errors.
    if len(pins) < 700:
        sys.exit(f"ABORT: only parsed {len(pins)} pins out of {PKG}; expected "
                 "747.  The format has moved and this check would give a false "
                 "pass.")
    return pins


# SQRL's XDC uses BOTH spellings, and the -dict one is the majority.  An
# earlier version of this checker only understood the bare form, saw 19 of the
# 29 live constraints, and reported OK -- a checker that quietly inspects part
# of the file is worse than none, so both forms are parsed and the count is
# printed so a future regression of the same kind is visible.
_BARE = re.compile(r"set_property\s+PACKAGE_PIN\s+(\S+)\s+\[get_ports\s+")
_DICT = re.compile(r"set_property\s+-dict\s*\{[^}]*?PACKAGE_PIN\s+(\S+)[^}]*\}\s*\[get_ports\s+")
_PORT = re.compile(r"\[get_ports\s+(\{[^}]*\}|[A-Za-z_]\w*(?:\[\d+\])?)")


def load_xdc():
    """[(port, pin, lineno)] for every live (uncommented) PACKAGE_PIN line."""
    out = []
    for n, line in enumerate(open(XDC), 1):
        if line.lstrip().startswith("#"):
            continue
        m = _BARE.search(line) or _DICT.search(line)
        if not m:
            continue
        p = _PORT.search(line)
        if not p:
            out.append((f"<unparsed port, line {n}>", m.group(1).strip(), n))
            continue
        out.append((p.group(1).strip("{}").strip(), m.group(1).strip(), n))
    return out


def main():
    pkg = load_package()
    ports = load_xdc()
    if not ports:
        sys.exit(f"ABORT: no PACKAGE_PIN constraints parsed out of {XDC}.")

    fails = []

    # ---- 1. every pin exists -------------------------------------------------
    for port, pin, n in ports:
        if pin not in pkg:
            fails.append(f"line {n}: {port} -> PACKAGE_PIN {pin} does not exist "
                         "on xcvu33p-fsvh2104")

    # ---- 4. no conflicting duplicates ---------------------------------------
    by_port = defaultdict(set)
    for port, pin, _ in ports:
        by_port[port].add(pin)
    for port, pins in by_port.items():
        if len(pins) > 1:
            fails.append(f"{port} is constrained to more than one pin: "
                         f"{sorted(pins)}")

    # ---- 2. the x4 claim -----------------------------------------------------
    lane_pins = [(p, pin, n) for p, pin, n in ports if p.startswith("pcie_")
                 and any(p.startswith(f"pcie_{d}") for d in ("rxp", "rxn", "txp", "txn"))]
    if len(lane_pins) != 16:
        fails.append(f"expected 16 live PCIe lane pins for an x4 endpoint "
                     f"(4 lanes x rxp/rxn/txp/txn), found {len(lane_pins)}")
    for port, pin, n in lane_pins:
        sig = pkg.get(pin, "")
        m = re.match(r"MGTY(RX|TX)[PN](\d)_(\d{3})", sig)
        if not m:
            fails.append(f"line {n}: {port} -> {pin} is {sig!r}, which is not a "
                         "GTY channel pin at all")
        elif m.group(3) != HOST_QUAD:
            fails.append(f"line {n}: {port} -> {pin} is {sig} = quad {m.group(3)}, "
                         f"not quad {HOST_QUAD}.  The endpoint is not confined to "
                         "one quad and the Aurora quads are not free")

    # ---- 3. refclk quad ------------------------------------------------------
    refs = [(p, pin, n) for p, pin, n in ports if "refclk" in p or "clk_p" in p or "clk_n" in p]
    seen_ref = False
    for port, pin, n in refs:
        sig = pkg.get(pin, "")
        m = re.match(r"MGTREFCLK(\d)([PN])_(\d{3})", sig)
        if m:
            seen_ref = True
            if m.group(3) != REFCLK_QUAD or m.group(1) != "0":
                fails.append(f"line {n}: {port} -> {pin} is {sig}; the design "
                             f"assumes MGTREFCLK0 of quad {REFCLK_QUAD}")
    if not seen_ref:
        fails.append("no MGTREFCLK pin is constrained; the endpoint has no "
                     "reference clock and cannot train")

    # ---- report --------------------------------------------------------------
    print(f"package  {PKG}")
    print(f"          {len(pkg)} balls parsed")
    print(f"xdc      {XDC}")
    total = sum(1 for line in open(XDC)
                if "PACKAGE_PIN" in line and not line.lstrip().startswith("#"))
    print(f"          {len(ports)} live PACKAGE_PIN constraints parsed "
          f"of {total} present, {len(lane_pins)} of them PCIe lanes")
    if len(ports) != total:
        fails.append(f"parsed {len(ports)} of {total} live PACKAGE_PIN lines; "
                     "the rest were not understood and are therefore UNCHECKED")
    for port, pin, _ in sorted(lane_pins):
        print(f"          {port:16s} {pin:5s} {pkg.get(pin, '?')}")
    for port, pin, _ in sorted(refs):
        if re.match(r"MGTREFCLK", pkg.get(pin, "")):
            print(f"          {port:16s} {pin:5s} {pkg.get(pin, '?')}")

    if fails:
        print(f"\nFK33_XDC_CHECK FAIL ({len(fails)})")
        for f in fails:
            print("  " + f)
        return 1
    print("\nFK33_XDC_CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
