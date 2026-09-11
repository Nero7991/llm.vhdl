#!/usr/bin/env python3
"""Does the host's seam register map agree with the RTL that implements it?

WHY THIS EXISTS
---------------
`server/pl_backend.c` drives the card through `server/fk33_seam.h`.  The thing
that answers is `rtl/fk33_seam.vhd`, an AXI4-Lite slave with its own offset
constants.  Nothing compared the two.  As of 2026-09-11 `tools/` held eight
checkers -- A geometry, KV map, HBM stacks, embeddings, behavioural ports -- and
none for the one interface that decides whether a card bitstream can be DRIVEN
at all.

A drift here is silent and expensive in a specific way: it cannot be caught by
any bench, because the host header is C and the decode is VHDL and no simulation
in this repository links the two.  It presents on hardware as a card that
configures, links, identifies, and then does nothing or returns rubbish -- after
a multi-hour build.  That is the same shape as the recorded KV-geometry defect,
which would have produced a working bitstream computing garbage.

WHAT IT CHECKS
--------------
The RTL is authoritative: every `constant A_<NAME> : natural := 16#..#` in
fk33_seam.vhd must have a host `#define FK33_SEAM_<NAME> 0x..` with the SAME
value.  The reverse direction is checked too, so a register the host believes in
and the RTL does not implement is also a failure.

THE ALIAS IS DELIBERATE AND IS NOT A SILENT PASS.  Two registers are spelled
differently on the two sides -- RTL `A_DESC_LO`/`A_DESC_HI` against host
`FK33_SEAM_DESC_PTR_LO`/`_HI` -- at identical offsets 0x38/0x3C.  They are
listed explicitly below and PRINTED as aliased rows, because a checker that
quietly normalises names can no longer tell a rename from a mismatch.

Exit 0 if every row passes, 1 otherwise.  Prints one line per row so a row that
was never compared is visible rather than absent.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(REPO, "rtl", "fk33_seam.vhd")
HDR = os.path.join(REPO, "server", "fk33_seam.h")
ENG_RTL = os.path.join(REPO, "rtl", "matvec_int4_desc_pkg.vhd")
ENG_HDR = os.path.join(REPO, "hw", "fk33", "host", "fk33_regs.h")

# RTL name -> host name, where the two sides spell the same register differently.
ALIASES = {"DESC_LO": "DESC_PTR_LO", "DESC_HI": "DESC_PTR_HI"}

# Host FK33_SEAM_* defines that are NOT register offsets, so the reverse check
# must not demand an RTL constant for them.  Each is a value, a magic number or
# a window/span, not an address.
NOT_OFFSETS = {"BASE", "SPAN", "DINFO_ABSENT", "ID_MAGIC"}


def read_rtl(path=RTL):
    src = open(path).read()
    out = {}
    for m in re.finditer(
            r"^\s*constant\s+A_([A-Z0-9_]+)\s*:\s*natural\s*:=\s*16#([0-9A-Fa-f]+)#",
            src, re.M):
        out[m.group(1)] = int(m.group(2), 16)
    return out


def read_hdr(path=HDR):
    src = open(path).read()
    out = {}
    for m in re.finditer(
            r"^\s*#define\s+FK33_SEAM_([A-Z0-9_]+)\s+0x([0-9A-Fa-f]+)", src, re.M):
        out[m.group(1)] = int(m.group(2), 16)
    return out


def read_seam_ec(path=RTL):
    """The SEAM's 4-bit error space, from fk33_seam.vhd."""
    src = open(path).read()
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"^\s*constant\s+EC_([A-Z0-9_]+)\s*:\s*natural\s*:=\s*(\d+)",
                                 src, re.M)}


def read_eng_ec(path=ENG_RTL):
    """SUBSYSTEM A's 4-bit error space. A DIFFERENT NAMESPACE -- see below."""
    src = open(path).read()
    return {m.group(1): int(m.group(2), 16)
            for m in re.finditer(
                r"^\s*constant\s+EC_([A-Z0-9_]+)\s*:\s*std_logic_vector\(3 downto 0\)\s*:=\s*x\"([0-9A-Fa-f])\"",
                src, re.M)}


def read_host_prefixed(path, prefix):
    src = open(path).read()
    return {m.group(1): int(m.group(2), 16)
            for m in re.finditer(r"^\s*#define\s+%s([A-Z0-9_]+)\s+0x([0-9A-Fa-f]+)"
                                 % re.escape(prefix), src, re.M)}


def read_magic(path=RTL):
    m = re.search(r'constant\s+ID_MAGIC\s*:\s*std_logic_vector\(31 downto 0\)\s*:=\s*x"([0-9A-Fa-f]{8})"',
                  open(path).read())
    return None if not m else int(m.group(1), 16)


def main():
    rtl, hdr = read_rtl(), read_hdr()
    rows, fail = [], 0

    # A checker whose input is empty reports nothing and looks like a pass.
    if not rtl:
        print("  REFUSED no A_<NAME> offset constants found in %s" % RTL)
        return 1
    if not hdr:
        print("  REFUSED no FK33_SEAM_<NAME> defines found in %s" % HDR)
        return 1

    for name in sorted(rtl):
        want = ALIASES.get(name, name)
        tag = "" if want == name else "  [aliased: RTL A_%s = host FK33_SEAM_%s]" % (name, want)
        if want not in hdr:
            rows.append(("REFUSED", name,
                         "RTL implements 0x%02X, host header has no FK33_SEAM_%s%s"
                         % (rtl[name], want, tag)))
            fail += 1
        elif hdr[want] != rtl[name]:
            rows.append(("REFUSED", name,
                         "RTL 0x%02X vs host 0x%02X -- the host would drive the WRONG register%s"
                         % (rtl[name], hdr[want], tag)))
            fail += 1
        else:
            rows.append(("ok", name, "0x%02X both sides%s" % (rtl[name], tag)))

    # Reverse: a register the host believes in that the RTL does not implement.
    aliased_hosts = set(ALIASES.values())
    for name in sorted(hdr):
        if name in NOT_OFFSETS or name.startswith("ERR_") or name in aliased_hosts:
            continue
        if name not in rtl:
            rows.append(("REFUSED", name,
                         "host defines FK33_SEAM_%s = 0x%02X but NO RTL constant implements it"
                         % (name, hdr[name])))
            fail += 1

    # --- ID_MAGIC: the FIRST thing the host reads. A mismatch here means the
    # host does not believe it is talking to the card at all. ---
    magic, want_magic = read_magic(), hdr.get("ID_MAGIC")
    if magic is None:
        rows.append(("REFUSED", "ID_MAGIC", "no ID_MAGIC constant in %s" % RTL)); fail += 1
    elif want_magic is None:
        rows.append(("REFUSED", "ID_MAGIC", "host header defines no FK33_SEAM_ID_MAGIC")); fail += 1
    elif magic != want_magic:
        rows.append(("REFUSED", "ID_MAGIC",
                     "RTL 0x%08X vs host 0x%08X -- the host would REJECT the card outright"
                     % (magic, want_magic))); fail += 1
    else:
        rows.append(("ok", "ID_MAGIC", "0x%08X both sides" % magic))

    # --- TWO ERROR NAMESPACES, CHECKED SEPARATELY AND DELIBERATELY NOT MERGED.
    # fk33_seam.vhd's header says it outright: "D's OWN 4-bit err_code IS NOT
    # THE SEAM'S 4-bit code".  The same NAME means different NUMBERS in each --
    # DESC is 0x3 in A's space and 0x6 in the seam's.  A checker that pooled
    # them would report a false mismatch, and "fixing" one to match the other
    # would break a live contract.  So each is compared only against ITS OWN
    # host prefix, and the collisions are printed as evidence the split is real.
    for label, ec, host, prefix in (
            ("seam", read_seam_ec(), read_host_prefixed(HDR, "FK33_SEAM_ERR_"), "FK33_SEAM_ERR_"),
            ("eng", read_eng_ec(), read_host_prefixed(ENG_HDR, "FK33_ENG_EC_"), "FK33_ENG_EC_")):
        if not ec:
            rows.append(("REFUSED", "%s:EC_*" % label, "no EC_ constants parsed -- a checker with no input reports nothing")); fail += 1
            continue
        for name in sorted(ec):
            if name not in host:
                rows.append(("note", "%s:%s" % (label, name),
                             "RTL raises EC_%s=0x%X; host has no %s%s (not fatal: host may never see it)"
                             % (name, ec[name], prefix, name)))
            elif host[name] != ec[name]:
                rows.append(("REFUSED", "%s:%s" % (label, name),
                             "RTL 0x%X vs host 0x%X -- a fault would be MISREPORTED"
                             % (ec[name], host[name]))); fail += 1
            else:
                rows.append(("ok", "%s:%s" % (label, name), "0x%X both sides" % ec[name]))

    # The namespaces MUST stay distinct. If they ever agree on every shared
    # name, someone has merged them and the seam header's rule is gone.
    se, en = read_seam_ec(), read_eng_ec()
    shared = sorted(set(se) & set(en))
    diff = [n for n in shared if se[n] != en[n]]
    rows.append(("ok" if diff or not shared else "REFUSED", "NAMESPACES",
                 "shared names %s; differing %s -- the two error spaces are distinct, as fk33_seam.vhd requires"
                 % (shared or "none", diff or "NONE")))
    if shared and not diff:
        fail += 1

    for verdict, name, why in rows:
        print("  %-8s %-14s %s" % (verdict, name, why))
    print("check_seam_regs: %d rows, %d refused (rtl=%d host_offsets=%d)"
          % (len(rows), fail, len(rtl), len(hdr)))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
