#!/usr/bin/env bash
# fk33_slotmap.sh -- does a PCI root port have a physical card slot behind it?
#
#   ./fk33_slotmap.sh                  classify every root port
#   ./fk33_slotmap.sh --lookup BDF     classify one root port
#   ./fk33_slotmap.sh --capture        print the exact root command to run
#   ./fk33_slotmap.sh --selftest       parser tests, no root, no hardware
#
# Exit codes for --lookup:
#   0  the port HAS an SMBIOS System Slot entry: a connector is wired to it
#   1  the port has NO entry: NOT CONFIRMED as a card slot (see the asymmetry
#      note below -- this is weaker evidence than a 0, not its mirror image)
#   3  unknown: no usable SMBIOS capture, so no claim is made either way
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-28 the FK33 was moved to `0000:00:1c.0` on the strength of a
# COMMENT in host/fk33_pcie_check.sh describing it as "the only free port".
# It is not a card slot.  `lspci -vv -s 00:1c.0` reports
# `SltCap: HotPlug+ Surprise+ PwrCtrl- MRL-` and `SltSta: PresDet-` with the
# card supposedly in it, and at Gen3 x1 with hotplug and no power controller
# it is almost certainly the M.2 Key-E Wi-Fi socket.  The move cost a power
# cycle and tested nothing.  A hand-maintained comment cannot be an authority
# for this, so the mapping is DERIVED here and reported as "unknown" wherever
# it cannot be derived.
#
# WHAT SMBIOS TYPE 9 IS GOOD FOR, AND WHAT IT IS NOT
# --------------------------------------------------
# READ THIS BEFORE EXTENDING THIS SCRIPT.  The obvious use of `dmidecode -t
# slot` -- reading the slot width and the silk-screen name out of it -- is
# WRONG on this board, and acting on it would repeat the original mistake in a
# new form.  Measured on the Gigabyte Z790 AERO G, BIOS F12, 2026-08-28:
#
#   * It reports `0000:00:1c.4` as "Type: x1 PCI Express, Length: Short".
#     That port demonstrably ran a Gen4 x4 RTX 3090, and the pre-fit baseline
#     recorded it as `16.0GT/sPCIe 4 ... 2 children`, i.e. LnkCap x4.
#   * All five entries say "Current Usage: In Use", which cannot be true.
#   * It lists exactly ONE x16 slot; the board has three x16-length connectors
#     (PCIEX16 CPU-attached, plus PCIEX4_1 and PCIEX4_2 wired x4 off the PCH).
#   * The designations J6B2 / J6B1 / J6D1 / J7B1 / J8B4 are Intel
#     customer-reference-board names, not Gigabyte silk screen.
#
# So Designation, Type, Length and Current Usage are vendor BOILERPLATE here
# and this script deliberately does not present any of them as fact.
#
# What survives, and it is the part that matters: type 9 is the BIOS's STATIC
# table of which root ports have a physical connector wired to them, and an
# entry is present whether or not the port is currently enumerated.  So the
# PRESENCE of an entry is trustworthy even when every field inside it is not.
# On this board that alone settles the question that cost the power cycle:
# 00:1c.4 HAS an entry, so the FK33 was in a legitimate connector all along and
# the slot was never the fault; 00:1c.0 has none.
#
# THE ASYMMETRY, AND DO NOT FLATTEN IT
# ------------------------------------
# Presence and absence are NOT mirror images, and treating them as such would
# be a new version of the original error.  This board's table has only five
# records, all Intel reference boilerplate, for a board with three x16-length
# connectors plus M.2 sockets: it is demonstrably INCOMPLETE.  Proof from this
# machine on 2026-08-28: `0000:00:1d.0` has NO type 9 entry and yet an FK33 is
# enumerated behind it right now.
#
# So:
#   an entry present  ->  there IS a connector.  Strong, act on it.
#   an entry absent   ->  NOT CONFIRMED.  Weak.  It is consistent with an
#                         onboard device, an undescribed socket, or simply a
#                         connector the vendor's table omits.  Never report it
#                         as "this is not a slot"; report it as not confirmed,
#                         and say so louder when a device is enumerated behind
#                         it, because that is direct proof the table is wrong.
#
# ROOT
# ----
# `dmidecode` needs root and this user has no passwordless sudo.  So this
# script NEVER calls sudo and never blocks on a password.  It reads, in order:
#
#   1. $FK33_DMI                       an explicit capture file
#   2. ./dmidecode_slots.txt           a cached capture next to this script
#   3. `dmidecode -t slot`             only if we already happen to be root
#
# and if none of those work it says exactly what it could not determine and
# prints the one command for a human to run.  Degrading loudly is the point;
# a tool that silently needs root is how the first mistake happened.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"

SYSFS="${FK33_SYSFS:-/sys}"
PCID="$SYSFS/bus/pci/devices"
CACHE="${FK33_DMI:-$HERE/dmidecode_slots.txt}"

CAPTURE_CMD="sudo dmidecode -t slot > $HERE/dmidecode_slots.txt"

BOILERPLATE_NOTE="fields inside a type 9 record (Designation, Type, Length,
    Current Usage) are unreliable vendor boilerplate on this board and are
    deliberately not reported.  Only the presence of an entry is used."

# --------------------------------------------------------------- the capture
# Sets DMI_TEXT and DMI_SRC.  Returns 1 when there is no usable capture.
DMI_TEXT=""; DMI_SRC=""
load_dmi () {
    if [[ -n "${FK33_DMI:-}" && -f "$FK33_DMI" ]]; then
        DMI_TEXT="$(cat "$FK33_DMI")"; DMI_SRC="FK33_DMI=$FK33_DMI"
    elif [[ -f "$CACHE" ]]; then
        DMI_TEXT="$(cat "$CACHE")"; DMI_SRC="cached capture $CACHE"
    elif [[ $EUID -eq 0 ]] && command -v dmidecode >/dev/null 2>&1; then
        DMI_TEXT="$(dmidecode -t slot 2>/dev/null)"; DMI_SRC="live dmidecode (running as root)"
    fi
    # A capture that parsed to nothing is not a capture.  dmidecode prints its
    # banner and a permission error and can still exit 0, so "the file exists"
    # proves nothing; only a parsed Bus Address does.
    if [[ -z "$DMI_TEXT" ]] || ! grep -q 'Bus Address:' <<<"$DMI_TEXT"; then
        DMI_TEXT=""; DMI_SRC=""
        return 1
    fi
    return 0
}

# One normalised bus address per SMBIOS type 9 record that has one.
# Deliberately extracts NOTHING else: see the boilerplate note above.
slot_ports () {
    awk '
        /System Slot Information/ { seen=1; next }
        seen && /^[ \t]*Bus Address:/ {
            sub(/^[ \t]*Bus Address:[ \t]*/, "")
            if ($0 !~ /:.*:/) $0 = "0000:" $0
            print; seen=0
        }
    ' <<<"$1" | sort -u
}

# how many type 9 records exist at all, including ones with no bus address
slot_record_count () { grep -c 'System Slot Information' <<<"$1"; }

norm_bdf () {
    local b="$1"
    [[ "$b" == *:*:* ]] || b="0000:$b"
    echo "$b"
}

present_in_configspace () { [[ -e "$PCID/$1" ]]; }

# ------------------------------------------------------------------ lookup
do_lookup () {
    local want; want="$(norm_bdf "$1")"
    if ! load_dmi; then
        echo "slot behind $want: UNKNOWN -- no SMBIOS slot capture available"
        echo "  Nothing here can say whether this port has a physical connector."
        echo "  run:  $CAPTURE_CMD"
        return 3
    fi
    if slot_ports "$DMI_TEXT" | grep -qx "$want"; then
        printf 'slot behind %s: YES -- the BIOS lists a physical connector on this port' "$want"
        present_in_configspace "$want" || printf ' (port not enumerated right now)'
        printf '  [source: %s]\n' "$DMI_SRC"
        return 0
    fi
    printf 'slot behind %s: NOT CONFIRMED -- no SMBIOS System Slot entry names this port' "$want"
    printf '  [source: %s]\n' "$DMI_SRC"
    echo "  This is WEAKER evidence than a YES, not its mirror image: this"
    echo "  board's table is incomplete (see the header).  It is consistent"
    echo "  with an onboard device, an undescribed M.2 or Wi-Fi socket, or a"
    echo "  real connector the vendor simply did not list."
    local n=0 c
    if present_in_configspace "$want"; then
        for c in "$PCID/$want"/0000:*; do [[ -e "$c/vendor" ]] && n=$((n+1)); done
        if (( n > 0 )); then
            echo "  BUT $n device(s) are enumerated behind it right now, which is"
            echo "  direct proof the SMBIOS table is incomplete for this port."
            echo "  Trust the enumeration over the table."
        else
            echo "  The port is enumerated with nothing behind it."
        fi
    fi
    echo "  Do NOT move a card here on this evidence alone.  Corroborate first:"
    echo "      sudo lspci -vv -s ${want#0000:} | grep -E 'SltCap|SltSta'"
    echo "  SltCap PwrCtrl- with SltSta PresDet- while a card is supposedly"
    echo "  seated is what identified 0000:00:1c.0 as an M.2 socket after"
    echo "  moving the FK33 there had already cost a power cycle."
    return 1
}

# ------------------------------------------------------------------- table
do_table () {
    echo "=== which root ports have a physical card slot behind them ==="
    if ! load_dmi; then
        echo
        echo "  UNKNOWN: no SMBIOS slot capture is available, so NOTHING below"
        echo "  can say whether a port has a connector.  What this script could"
        echo "  NOT determine: which root ports are card slots at all, and"
        echo "  therefore which ports it is even meaningful to move a card to."
        echo
        echo "  Fix it once, with root, and every later run is evidence-backed:"
        echo "      $CAPTURE_CMD"
        echo
        echo "  Root ports in config space right now, with NO slot information."
        echo "  Do NOT infer a connector from a link width:"
        local b n c
        for b in "$PCID"/*; do
            [[ -e "$b/secondary_bus_number" ]] || continue
            n=0
            for c in "$b"/0000:*; do [[ -e "$c/vendor" ]] && n=$((n+1)); done
            printf '      %-14s max %s x%s  %s device(s)  slot UNKNOWN\n' \
                "$(basename "$b")" \
                "$(tr -d ' ' < "$b/max_link_speed" 2>/dev/null)" \
                "$(cat "$b/max_link_width" 2>/dev/null)" "$n"
        done
        return 3
    fi

    echo "source: $DMI_SRC  ($(slot_record_count "$DMI_TEXT") System Slot records)"
    echo "NOTE: $BOILERPLATE_NOTE"
    echo
    local ports b nb n c
    ports="$(slot_ports "$DMI_TEXT")"

    printf '  %-14s %-22s %s\n' PORT "SLOT ENTRY" "IN CONFIG SPACE NOW"
    # every port named by SMBIOS, enumerated or not
    for nb in $ports; do
        if present_in_configspace "$nb"; then
            n=0
            for c in "$PCID/$nb"/0000:*; do [[ -e "$c/vendor" ]] && n=$((n+1)); done
            printf '  %-14s %-22s present, %s device(s)\n' "$nb" "YES, a connector" "$n"
        else
            printf '  %-14s %-22s ABSENT -- port hidden by the BIOS\n' "$nb" "YES, a connector"
        fi
    done
    # every enumerated root port SMBIOS does not name
    for b in "$PCID"/*; do
        [[ -e "$b/secondary_bus_number" ]] || continue
        nb="$(basename "$b")"
        grep -qx "$nb" <<<"$ports" && continue
        n=0
        for c in "$b"/0000:*; do [[ -e "$c/vendor" ]] && n=$((n+1)); done
        printf '  %-14s %-22s present, %s device(s)%s\n' "$nb" "not confirmed" "$n" \
            "$( (( n > 0 )) && echo '  <- table is incomplete here' )"
    done

    echo
    echo "  A port with a slot entry that is ABSENT from config space is a real"
    echo "  connector whose root port the BIOS disabled after nothing trained on"
    echo "  it at POST.  That is a bring-up finding, not a missing card: there"
    echo "  is no bridge to rescan behind and setpci cannot address it."
    echo
    echo "  \"not confirmed\" is NOT the same claim as \"not a slot\".  Absence of"
    echo "  an entry is weak evidence on this board, because the table is"
    echo "  incomplete; any row above marked \"table is incomplete here\" proves"
    echo "  it directly, since a device is enumerated on a port SMBIOS omits."
    echo "  Before moving a card into any port, confirm with:"
    echo "      sudo lspci -vv -s <bdf> | grep -E 'SltCap|SltSta'"
    return 0
}

# ---------------------------------------------------------------- selftest
do_selftest () {
    local tmp rc=0 out
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

    # FIXTURE: the REAL capture from this machine, 2026-08-28.  Its width and
    # designation fields are wrong (see the header); its bus addresses are not.
    local real="$HERE/dmidecode_slots.txt"

    echo "--- 1. a port WITH a slot entry is reported YES and exits 0"
    out="$(FK33_DMI="$real" "$SELF" --lookup 0000:00:1c.4; echo "rc=$?")"
    if grep -q 'YES' <<<"$out" && grep -q 'rc=0' <<<"$out"; then
        echo "    ok   $(head -1 <<<"$out")"
    else
        echo "    FAIL 00:1c.4 has a type 9 entry and must be YES: $out"; rc=1
    fi

    echo "--- 2. 00:1c.0 -- the port the first attempt wrongly moved the card to"
    out="$(FK33_DMI="$real" "$SELF" --lookup 0000:00:1c.0; echo "rc=$?")"
    if grep -q 'NOT CONFIRMED' <<<"$out" \
       && grep -q 'Do NOT move a card here on this evidence alone' <<<"$out" \
       && grep -q 'rc=1' <<<"$out"; then
        echo "    ok   00:1c.0 is not confirmed as a slot, and says so"
    else
        echo "    FAIL 00:1c.0 must be NOT CONFIRMED with a warning: $out"; rc=1
    fi

    echo "--- 2b. and it must NOT overclaim: absence is weaker than presence"
    # Reporting "this is not a card slot" would be a new wrong answer, because
    # this board's table is provably incomplete (see 2c).
    if grep -qE 'is not a card slot|NOT a card slot' <<<"$out"; then
        echo "    FAIL absence of an entry was reported as proof it is no slot"; rc=1
    else
        echo "    ok   absence reported as unconfirmed, never as disproof"
    fi

    echo "--- 2c. a port SMBIOS omits but that HAS a device behind it must be"
    echo "        flagged as proof the table is incomplete"
    mkdir -p "$tmp/sys2/bus/pci/devices/0000:00:1d.0/0000:07:00.0"
    printf '7\n' > "$tmp/sys2/bus/pci/devices/0000:00:1d.0/secondary_bus_number"
    printf '16.0 GT/s PCIe\n' > "$tmp/sys2/bus/pci/devices/0000:00:1d.0/max_link_speed"
    printf '4\n' > "$tmp/sys2/bus/pci/devices/0000:00:1d.0/max_link_width"
    printf '0x1e24\n' > "$tmp/sys2/bus/pci/devices/0000:00:1d.0/0000:07:00.0/vendor"
    out="$(FK33_SYSFS="$tmp/sys2" FK33_DMI="$real" "$SELF" --lookup 0000:00:1d.0)"
    if grep -q 'direct proof the SMBIOS table is incomplete' <<<"$out"; then
        echo "    ok   an enumerated device on an omitted port contradicts the table"
    else
        echo "    FAIL did not flag the table as incomplete: $out"; rc=1
    fi
    out="$(FK33_SYSFS="$tmp/sys2" FK33_DMI="$real" "$SELF")"
    grep -q 'table is incomplete here' <<<"$out" \
        && echo "    ok   and the table row is marked too" \
        || { echo "    FAIL table row not marked"; rc=1; }

    echo "--- 3. the unreliable fields must NEVER be presented as fact"
    # J6D1 / "x1 PCI Express" / "In Use" are all wrong for 00:1c.4.  If any of
    # them leaks into output, someone will act on it.
    out="$(FK33_DMI="$real" "$SELF"; FK33_DMI="$real" "$SELF" --lookup 0000:00:1c.4)"
    if grep -qE 'J6D1|J6B2|J6B1|J7B1|J8B4' <<<"$out"; then
        echo "    FAIL a reference-board designation leaked into the output"; rc=1
    elif grep -qE 'x1 PCI Express|x16 PCI Express|Current Usage:|Length: (Short|Long)' <<<"$out"; then
        echo "    FAIL an unreliable width/usage field leaked into the output"; rc=1
    else
        echo "    ok   no designation, width, length or usage field is reported"
    fi

    echo "--- 4. the boilerplate warning must be stated, not just implied"
    grep -q 'unreliable vendor boilerplate' <<<"$out" \
        && echo "    ok   the table says the inner fields are unreliable" \
        || { echo "    FAIL the table does not warn about the boilerplate"; rc=1; }

    echo "--- 5. a described port that is ABSENT from config space is flagged"
    # 00:1c.4 is described by SMBIOS and is hidden on this box right now.
    out="$(FK33_DMI="$real" "$SELF")"
    if grep -qE '0000:00:1c\.4.*ABSENT -- port hidden by the BIOS' <<<"$out"; then
        echo "    ok   00:1c.4 reported as a real connector whose port is hidden"
    elif grep -qE '0000:00:1c\.4.*present' <<<"$out"; then
        echo "    note 00:1c.4 is enumerated right now, so the hidden-port row"
        echo "         cannot be exercised against live sysfs; covered by 5b"
    else
        echo "    FAIL 00:1c.4 missing from the table entirely"; rc=1
    fi

    echo "--- 5b. same, against a synthetic sysfs where the port is definitely gone"
    mkdir -p "$tmp/sys/bus/pci/devices"
    out="$(FK33_SYSFS="$tmp/sys" FK33_DMI="$real" "$SELF")"
    grep -qE '0000:00:1c\.4.*ABSENT -- port hidden by the BIOS' <<<"$out" \
        && echo "    ok   hidden-port row rendered" \
        || { echo "    FAIL hidden-port row not rendered: $(grep 1c.4 <<<"$out")"; rc=1; }

    echo "--- 6. an enumerated port with NO entry is called out as not a slot"
    # Build a synthetic port 00:1c.0 that exists but is unnamed by SMBIOS.
    mkdir -p "$tmp/sys/bus/pci/devices/0000:00:1c.0"
    printf '4\n' > "$tmp/sys/bus/pci/devices/0000:00:1c.0/secondary_bus_number"
    printf '8.0 GT/s PCIe\n' > "$tmp/sys/bus/pci/devices/0000:00:1c.0/max_link_speed"
    printf '1\n' > "$tmp/sys/bus/pci/devices/0000:00:1c.0/max_link_width"
    out="$(FK33_SYSFS="$tmp/sys" FK33_DMI="$real" "$SELF")"
    grep -qE '0000:00:1c\.0.*not confirmed' <<<"$out" \
        && echo "    ok   an enumerated port with no entry reads 'not confirmed'" \
        || { echo "    FAIL: $(grep 1c.0 <<<"$out")"; rc=1; }

    echo "--- 7. with NO capture at all it must say UNKNOWN and print the command"
    out="$(FK33_DMI="$tmp/absent" "$SELF" --lookup 0000:00:01.0; echo "rc=$?")"
    if grep -q 'UNKNOWN' <<<"$out" && grep -q 'sudo dmidecode -t slot' <<<"$out" \
       && grep -q 'rc=3' <<<"$out"; then
        echo "    ok   degrades loudly, names the exact root command, exit 3"
    else
        echo "    FAIL no-capture path: $out"; rc=1
    fi

    echo "--- 8. UNKNOWN and NO must be distinguishable, never conflated"
    # The whole point: "no capture" must not read as "not a slot", or a missing
    # capture would forbid every port; and "not a slot" must not read as
    # "unknown", or the 00:1c.0 mistake becomes possible again.
    local a b
    a="$(FK33_DMI="$tmp/absent" "$SELF" --lookup 0000:00:1c.4; echo "rc=$?")"
    b="$(FK33_DMI="$real"       "$SELF" --lookup 0000:00:1c.0; echo "rc=$?")"
    if grep -q 'rc=3' <<<"$a" && grep -q 'rc=1' <<<"$b" \
       && ! grep -q 'DO NOT move a card' <<<"$a"; then
        echo "    ok   exit 3 (unknown) and exit 1 (not a slot) are distinct"
    else
        echo "    FAIL unknown and not-a-slot are conflated"; rc=1
    fi

    echo "--- 9. a capture that is only a permission error is NOT a capture"
    printf '# dmidecode 3.3\n/dev/mem: Permission denied\n' > "$tmp/denied.txt"
    out="$(FK33_DMI="$tmp/denied.txt" "$SELF" --lookup 0000:00:01.0; echo "rc=$?")"
    if grep -q 'no SMBIOS slot capture available' <<<"$out" && grep -q 'rc=3' <<<"$out"; then
        echo "    ok   an empty/denied capture is rejected, not parsed"
    else
        echo "    FAIL denied capture treated as usable: $out"; rc=1
    fi

    echo "--- 10. the SHORT bdf form must resolve identically"
    out="$(FK33_DMI="$real" "$SELF" --lookup 00:1c.4)"
    grep -q 'YES' <<<"$out" && echo "    ok   short form resolves" \
        || { echo "    FAIL short form: $out"; rc=1; }

    echo
    (( rc == 0 )) && echo "FK33_SLOTMAP_SELFTEST OK" || echo "FK33_SLOTMAP_SELFTEST FAIL"
    return $rc
}

case "${1:-}" in
    --lookup)   [[ $# -ge 2 ]] || { echo "usage: $0 --lookup 0000:00:1c.4" >&2; exit 2; }
                do_lookup "$2"; exit $? ;;
    --capture)  echo "$CAPTURE_CMD"
                echo "# dmidecode needs root and this user has no passwordless sudo,"
                echo "# so no script here will ever run it for you.  Capture once;"
                echo "# every tool then reads the cached file with no privileges."
                exit 0 ;;
    --selftest) do_selftest; exit $? ;;
    -h|--help)  sed -n '2,80p' "$SELF"; exit 0 ;;
    "")         do_table; exit $? ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
esac
