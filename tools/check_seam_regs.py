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
CARD_GEN = os.path.join(REPO, "hw", "fk33", "gen_fk33_card.py")
PCIEEP_GEN = os.path.join(REPO, "hw", "fk33", "gen_pcieep.py")
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


def read_caps(path=RTL):
    """CAPS_FLAGS_V -- what the bitstream tells the host it implements."""
    m = re.search(r'constant\s+CAPS_FLAGS_V\s*:\s*std_logic_vector\(31 downto 0\)'
                  r'\s*:=\s*x"([0-9A-Fa-f]{8})"', open(path).read())
    return None if not m else int(m.group(1), 16)


def read_cap_bits(path=HDR):
    return {m.group(1): 1 << int(m.group(2))
            for m in re.finditer(r"^\s*#define\s+FK33_CAP_([A-Z_]+)\s+\(1u\s*<<\s*(\d+)\)",
                                 open(path).read(), re.M)}


def read_card_bool(name, path=CARD_GEN):
    """A boolean generic the CARD passes. None means it does not set it."""
    m = re.search(r'"--generic",\s*"%s=(true|false)"' % re.escape(name),
                  open(path).read())
    return None if not m else (m.group(1) == "true")


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

    # --- CAPS_FLAGS MUST NOT ADVERTISE WHAT THE BITSTREAM LACKS. ---
    # rtl/fk33_seam.vhd calls CAPS_FLAGS "What this bitstream ACTUALLY
    # implements, so a host cannot discover it by trying", and notes bit 1
    # being 0 is "the honest report".  MEASURED 2026-09-11: bit 2, "sampler
    # argmax published", is SET while the card leaves SMP_EN at its default of
    # FALSE, which ties the whole logits stream off.  So the seam tells the
    # host it has a sampler that is not in the design.  A host that believes it
    # waits for an argmax that never arrives, on hardware, with no error.
    caps, bits = read_caps(), read_cap_bits()
    smp = read_card_bool("SMP_EN")
    smp_on = bool(smp)          # absent => llama_top's default, which is false
    if caps is None or not bits:
        rows.append(("REFUSED", "CAPS_FLAGS", "could not read CAPS_FLAGS_V or the FK33_CAP_* bits")); fail += 1
    else:
        for capname, want_on in (("SAMPLER", smp_on), ("LOGITS", smp_on)):
            bit = bits.get(capname)
            if bit is None:
                rows.append(("note", "CAPS:%s" % capname, "host defines no FK33_CAP_%s" % capname))
                continue
            advertised = bool(caps & bit)
            if advertised != want_on:
                rows.append(("REFUSED", "CAPS:%s" % capname,
                             "CAPS_FLAGS_V=0x%08X %s the bit, card SMP_EN=%s -- the bitstream "
                             "%s a capability it %s"
                             % (caps, "SETS" if advertised else "CLEARS",
                                "unset (default false)" if smp is None else smp,
                                "ADVERTISES" if advertised else "hides",
                                "does not have" if advertised else "has"))); fail += 1
            else:
                rows.append(("ok", "CAPS:%s" % capname,
                             "advertised=%s, card SMP_EN=%s" % (advertised, smp_on)))

    # --- CAPS bit 5, ENG_KV_BASE (2026-09-20): advertised iff the seam
    # implements A_KVK_LO and A_KV_MAXPOS AND gen_pcieep.py wires the seam's
    # d_kv_k_base to the card's kv_k_base.  Derived from the THING on both
    # sides, not from either copy of the flag: a bit set with the register
    # unwired would tell the host its base reaches C when it reaches nothing,
    # which is the 2026-09-20 defect with a capability bit on top.
    if caps is not None and bits:
        bit = bits.get("ENG_KV_BASE")
        have_reg = "KVK_LO" in rtl and "KV_MAXPOS" in rtl
        try:
            gen = open(PCIEEP_GEN).read()
        except OSError:
            gen = ""
        wired = bool(re.search(r'\(\s*"d_kv_k_base"\s*,\s*"kv_k_base"\s*\)', gen)
                     and re.search(r'\(\s*"d_kv_v_base"\s*,\s*"kv_v_base"\s*\)', gen))
        if bit is None:
            rows.append(("note", "CAPS:ENG_KV_BASE", "host defines no FK33_CAP_ENG_KV_BASE"))
        else:
            advertised = bool(caps & bit)
            want = have_reg and wired
            if advertised != want:
                rows.append(("REFUSED", "CAPS:ENG_KV_BASE",
                             "CAPS_FLAGS_V=0x%08X %s bit 5; seam registers %s, gen_pcieep "
                             "SEAM_TO_CARD wiring %s -- the flag and the thing disagree"
                             % (caps, "SETS" if advertised else "CLEARS",
                                "present" if have_reg else "ABSENT",
                                "present" if wired else "ABSENT"))); fail += 1
            else:
                rows.append(("ok", "CAPS:ENG_KV_BASE",
                             "advertised=%s, A_KVK_LO/A_KV_MAXPOS=%s, seam->card wiring=%s"
                             % (advertised, have_reg, wired)))

    # --- CAPS bit 7, NORM_HBM (2026-09-24).  NOT in the static constant: it is
    # OR'd in at the read from the CAP_NORM_HBM generic, which gen_pcieep sets
    # from the card's own NORM_HBM.  So: the constant must CLEAR bit 7 (or a
    # ROM-path card would claim it), the seam must OR it in from a generic
    # that defaults to 0, and gen_pcieep must set that generic.
    if caps is not None and bits:
        bit = bits.get("NORM_HBM")
        seam_src = open(RTL).read() if os.path.exists(RTL) else ""
        try:
            gen = open(PCIEEP_GEN).read()
        except OSError:
            gen = ""
        g_ok = bool(re.search(r"CAP_NORM_HBM\s*:\s*natural\s*:=\s*0\s*;", seam_src))
        or_ok = bool(re.search(r"if\s+CAP_NORM_HBM\s*=\s*1\s+then\s+rv\(7\)\s*:=\s*'1'", seam_src))
        set_ok = "CONFIG.CAP_NORM_HBM" in gen
        if bit is None:
            rows.append(("note", "CAPS:NORM_HBM", "host defines no FK33_CAP_NORM_HBM"))
        elif bit != (1 << 7) or (caps & bit) or not (g_ok and or_ok and set_ok):
            rows.append(("REFUSED", "CAPS:NORM_HBM",
                         "host bit %#x (want 0x80), static CAPS_FLAGS_V %s it, seam generic "
                         "default-0 %s, OR at read %s, gen_pcieep sets it %s"
                         % (bit, "SETS" if caps & bit else "clears", g_ok, or_ok, set_ok))); fail += 1
        else:
            rows.append(("ok", "CAPS:NORM_HBM",
                         "bit 7 from the CAP_NORM_HBM generic (default 0), set by gen_pcieep from the card"))

    for verdict, name, why in rows:
        print("  %-8s %-14s %s" % (verdict, name, why))
    print("check_seam_regs: %d rows, %d refused (rtl=%d host_offsets=%d)"
          % (len(rows), fail, len(rtl), len(hdr)))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
