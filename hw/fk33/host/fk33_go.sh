#!/usr/bin/env bash
# fk33_go.sh -- THE one command to run after the FK33 is in the slot.
#
#   ./fk33_go.sh              run every stage, print a per-stage verdict
#   ./fk33_go.sh --selftest   everything checkable with NO card at all.
#   ./fk33_go.sh --baseline   snapshot the PCI topology WITHOUT the card.
#                             Run this BEFORE powering off to fit the card.
#   ./fk33_go.sh --diff       the baseline diff on its own, nothing else.
#   ./fk33_go.sh --hbm        also run the HBM round trip at the end
#   ./fk33_go.sh --quiet      verdict lines only
#
# It is READ-ONLY and needs no root.  Anything that needs root is printed as
# an exact command to copy, never run: this user has no passwordless sudo and
# a script that silently blocks on a password prompt is worse than one that
# does not try.
#
# WHY A BASELINE
# --------------
# The hardest failure to diagnose is "nothing enumerated", because a PCI
# device that never answers is indistinguishable from a slot that was always
# empty.  The root port is the only observer that still works, and to read it
# you must first know WHICH root port -- which is exactly the thing you cannot
# look up once the card is in and silent.  So we record every bridge and every
# slot tonight; tomorrow any port whose presence-detect or link width MOVED is
# the card's port, by construction, with no guessing.
#
# WHY THE DIFF LOOKS FOR PORTS THAT VANISHED
# ------------------------------------------
# CORRECTED 2026-08-28, after this script confidently mis-diagnosed the first
# fit.  It used to look only for a port that was EMPTY in the baseline and
# became OCCUPIED.  That is right for ADDING a card to a free slot.  The FK33
# was SWAPPED into 0000:00:1c.4, which had held an RTX 3090, and after the fit
# that bridge was absent from config space entirely, because a PCH root port
# that saw nothing train at POST is hidden by the BIOS.  Nothing "appeared",
# so the script guessed a root port, measured the wrong one in stages B, C and
# D, and concluded "points at power or seating" -- after its own stage A had
# already passed on card power.
#
# A bridge that DISAPPEARS between the baseline and now is a strong and highly
# specific signal, and it is the opposite of a power fault: an unpowered card
# cannot remove a root port from config space, only the firmware can.  So the
# diff now covers every bridge in both directions and a disappearance is its
# own diagnosis, with its own remedy.
#
# WHY sysfs AND NOT `lspci -vvv`
# ------------------------------
# LnkSta lives in the PCIe capability, past the 64 config bytes an unprivileged
# reader is allowed, so `lspci -vvv` prints "Capabilities: <access denied>" and
# the single most diagnostic check in the whole procedure yields NOTHING when
# run as a normal user.  The kernel already exports the same two fields as
# current_link_speed / current_link_width, world-readable.  Measured on this
# box with an empty port: max_link_width 1, current_link_width 0.
set -uo pipefail
# Absolute self path BEFORE the cd: --help used to sed "$0", which stops
# resolving the moment the script chdirs out from under a relative invocation.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")"

BASELINE="${FK33_BASELINE:-$PWD/pci_baseline.txt}"
VID=10ee
DID=9034
SUBSYS=1e24

DO_HBM=0; QUIET=0; MODE=run
for a in "$@"; do
    case "$a" in
        --baseline) MODE=baseline ;;
        --selftest) MODE=selftest ;;
        --diff)     MODE=diff ;;
        --hbm)      DO_HBM=1 ;;
        --quiet|-q) QUIET=1 ;;
        -h|--help)  sed -n '2,21p' "$SELF"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- reporting
FIRST_FAIL=""; FIRST_FAIL_WHY=""
say  () { (( QUIET )) || printf '\n--- %s\n' "$*"; }
info () { (( QUIET )) || printf '      %s\n' "$*"; }
pass () { printf '  PASS  %-4s %s\n' "$1" "$2"; }
warn () { printf '  WARN  %-4s %s\n' "$1" "$2"; }
fail () { printf '  FAIL  %-4s %s\n' "$1" "$2"
          [[ -z "$FIRST_FAIL" ]] && { FIRST_FAIL="$1"; FIRST_FAIL_WHY="$2"; }; return 0; }

# ------------------------------------------------------------- sysfs helpers
#
# FK33_SYSFS relocates the whole sysfs view.  It exists so the baseline diff --
# the part that got the first fit wrong -- can be exercised against synthetic
# topologies with no card and no reboot, including the exact topology that
# produced the wrong answer.  A diagnosis that can only be tested by refitting
# hardware is a diagnosis that never gets tested.
SYSFS="${FK33_SYSFS:-/sys}"
PCID="$SYSFS/bus/pci/devices"
SLOTD="$SYSFS/bus/pci/slots"
USBD="$SYSFS/bus/usb/devices"
rd () { cat "$1" 2>/dev/null || echo "?"; }

SLOTMAP="$PWD/fk33_slotmap.sh"
# One line naming the physical connector behind a root port, or an explicit
# "unknown".  Never guessed from a link width: that guess cost a power cycle.
connector_of () {
    if [[ -x "$SLOTMAP" ]]; then
        "$SLOTMAP" --lookup "$1" 2>/dev/null | head -1
    else
        echo "connector for $1: UNKNOWN -- $SLOTMAP is missing"
    fi
}

# every PCI-to-PCI bridge, i.e. every possible root port
bridges () {
    local d
    for d in "$PCID"/*; do
        [[ -e "$d/secondary_bus_number" ]] || continue
        basename "$d"
    done
}

# children of a bridge, counting ONLY real devices.  The obvious
# ls "$PCID/$b"/0000:* also matches the pcie SERVICE entries
# (0000:00:1c.0:pcie001 and friends), which made an empty port look
# populated -- it reported 3 children for a slot with nothing in it.
kids () {
    local d c=0
    for d in "$PCID/$1"/0000:*; do
        [[ -e "$d/vendor" ]] && c=$((c+1))
    done
    echo "$c"
}

snapshot () {
    local b n
    echo "# fk33 PCI baseline -- $(date -Is) -- kernel $(uname -r)"
    echo "# columns: BRIDGE maxspeed maxwidth curspeed curwidth secbus nchildren"
    for b in $(bridges); do
        n=$(kids "$b")
        printf 'BRIDGE %s %s %s %s %s %s %s\n' "$b" \
            "$(rd "$PCID/$b/max_link_speed"     | tr -d ' ' )" \
            "$(rd "$PCID/$b/max_link_width")" \
            "$(rd "$PCID/$b/current_link_speed" | tr -d ' ' )" \
            "$(rd "$PCID/$b/current_link_width")" \
            "$(rd "$PCID/$b/secondary_bus_number")" "$n"
    done
    echo "# columns: SLOT name address adapter power curspeed"
    for s in "$SLOTD"/*; do
        [[ -d "$s" ]] || continue
        printf 'SLOT %s %s %s %s %s\n' "$(basename "$s")" \
            "$(rd "$s/address")" "$(rd "$s/adapter")" "$(rd "$s/power")" \
            "$(rd "$s/cur_bus_speed" | tr -d ' ')"
    done
    echo "# columns: DEV bdf vendor device"
    for d in "$PCID"/*; do
        printf 'DEV %s %s %s\n' "$(basename "$d")" \
            "$(rd "$d/vendor")" "$(rd "$d/device")"
    done
}

# ------------------------------------------------------------- baseline diff
#
# Emits one machine-readable record per CHANGED bridge, in both directions.
# Consumed by stage B and printed verbatim by --diff.
#
#   GONE  bdf maxspeed maxwidth curwidth nkids     in the baseline, absent now
#   NEW   bdf maxspeed maxwidth curwidth nkids     absent in the baseline
#   WIDTH bdf wasempty wascurwidth nowcurwidth     link width moved
#   KIDS  bdf wasempty waskids    nowkids         child count moved
#
# "wasempty" is 1 when the port had no children in the baseline.  A width move
# on an ALREADY-OCCUPIED port is not evidence of anything (a GPU dropping to x8
# at idle is normal), so it is emitted but tagged, and stage B does not act on
# it.  A port VANISHING is emitted whether it was occupied or not, because
# either way only the firmware can do it.
bridge_diff () {
    [[ -f "$BASELINE" ]] || return 0
    local b ms mw cs cw sb nk now_cw now_nk wasempty
    while read -r _ b ms mw cs cw sb nk; do
        if [[ ! -e "$PCID/$b" ]]; then
            printf 'GONE %s %s %s %s %s\n' "$b" "$ms" "$mw" "$cw" "$nk"
            continue
        fi
        wasempty=0; [[ "$nk" == 0 ]] && wasempty=1
        now_cw="$(rd "$PCID/$b/current_link_width")"
        now_nk="$(kids "$b")"
        [[ "$now_cw" != "$cw" ]] && printf 'WIDTH %s %s %s %s\n' "$b" "$wasempty" "$cw" "$now_cw"
        [[ "$now_nk" != "$nk" ]] && printf 'KIDS %s %s %s %s\n'  "$b" "$wasempty" "$nk"  "$now_nk"
    done < <(grep '^BRIDGE' "$BASELINE")
    for b in $(bridges); do
        grep -q "^BRIDGE $b " "$BASELINE" && continue
        printf 'NEW %s %s %s %s %s\n' "$b" \
            "$(rd "$PCID/$b/max_link_speed" | tr -d ' ')" "$(rd "$PCID/$b/max_link_width")" \
            "$(rd "$PCID/$b/current_link_width")" "$(kids "$b")"
    done
}

diff_human () {
    local kind b a c d e
    if [[ ! -f "$BASELINE" ]]; then
        echo "  no baseline at $BASELINE -- nothing to diff against."
        echo "  Run ./fk33_go.sh --baseline with the card OUT."
        return 0
    fi
    local any=0
    while read -r kind b a c d e; do
        any=1
        case "$kind" in
          GONE)  printf '  GONE   %s  was max %s x%s, current x%s, %s device(s)\n' "$b" "$a" "$c" "$d" "$e"
                 printf '         the BRIDGE ITSELF is no longer in config space\n' ;;
          NEW)   printf '  NEW    %s  max %s x%s, current x%s, %s device(s)\n' "$b" "$a" "$c" "$d" "$e" ;;
          WIDTH) printf '  WIDTH  %s  current width %s -> %s  (port was %s in the baseline)\n' \
                        "$b" "$c" "$d" "$([[ "$a" == 1 ]] && echo EMPTY || echo occupied)" ;;
          KIDS)  printf '  KIDS   %s  %s -> %s device(s) behind it  (port was %s in the baseline)\n' \
                        "$b" "$c" "$d" "$([[ "$a" == 1 ]] && echo EMPTY || echo occupied)" ;;
        esac
    done < <(bridge_diff)
    (( any )) || echo "  no bridge changed in either direction since the baseline."
}

if [[ "$MODE" == diff ]]; then
    echo "baseline: $BASELINE"
    [[ -f "$BASELINE" ]] && echo "taken:    $(head -1 "$BASELINE" | cut -d' ' -f5-)"
    echo
    diff_human
    exit 0
fi

if [[ "$MODE" == baseline ]]; then
    snapshot > "$BASELINE"
    echo "baseline written: $BASELINE"
    grep -c '^BRIDGE' "$BASELINE" | xargs printf '  %s bridges\n'
    grep -c '^SLOT'   "$BASELINE" | xargs printf '  %s hotplug slots\n'
    grep -c '^DEV'    "$BASELINE" | xargs printf '  %s devices\n'
    echo
    echo "Bridges with an EMPTY secondary bus right now (candidate slots):"
    awk '$1=="BRIDGE" && $8==0 {printf "  %s  max %s x%s  cur %s x%s\n",$2,$3,$4,$5,$6}' "$BASELINE"
    exit 0
fi

if [[ "$MODE" == selftest ]]; then
    # Everything that can be settled with NO card.  Run it tonight, and run it
    # again after any edit.  It deliberately does NOT fake a card for the real
    # run: a green rehearsal that hides a real gap is worse than a red one.
    rc=0
    echo "=== 1. host program compiles and every printf format matches ==="
    make --no-print-directory check || rc=1
    echo
    echo "=== 2. host program logic, against seeded and corrupted files ==="
    ./selftest_nocard.sh || rc=1
    echo
    echo "=== 2b. the host DIAGNOSTIC tooling, against synthetic topologies ==="
    # These are the checks that would have caught the 2026-08-28 first-fit
    # mis-diagnosis.  They need no card, so there is no excuse for skipping.
    ./tests_hostdiag.sh    | tail -1 | grep -q OK && echo "  ok      tests_hostdiag.sh" \
        || { ./tests_hostdiag.sh; rc=1; }
    ./fk33_slotmap.sh --selftest    | tail -1 | grep -q OK && echo "  ok      fk33_slotmap.sh --selftest" \
        || { ./fk33_slotmap.sh --selftest; rc=1; }
    ./fk33_powercycle.sh --selftest | tail -1 | grep -q OK && echo "  ok      fk33_powercycle.sh --selftest" \
        || { ./fk33_powercycle.sh --selftest; rc=1; }
    python3 tests_fk33ctl.py        | tail -1 | grep -q OK && echo "  ok      tests_fk33ctl.py" \
        || { python3 tests_fk33ctl.py; rc=1; }
    echo
    echo "=== 3. XDC against the real package file ==="
    python3 ../check_pcieep_xdc.py >/dev/null 2>&1 \
        && echo "FK33_XDC_CHECK OK" || { python3 ../check_pcieep_xdc.py; rc=1; }
    echo
    echo "=== 4. everything the procedure references actually exists ==="
    for f in ../pcieep.sh ../pcieep_build.sh ../jtag.sh ../check_pcieep_xdc.py \
             ../tcl/program.tcl ../tcl/vccint_step.tcl ../tcl/pcieep_jtag.tcl \
             ../tcl/telemetry.tcl ../tcl/hbmdiag.tcl \
             build_xdma_driver.sh fk33_pcie_check.sh fk33ctl.py fk33_bringup.c \
             fk33_slotmap.sh fk33_powercycle.sh potlatch.tcl \
             tests_hostdiag.sh tests_fk33ctl.py; do
        if [[ -e "$f" ]]; then printf '  ok      %s\n' "$f"
        else printf '  MISSING %s\n' "$f"; rc=1; fi
    done
    if [[ -f dmidecode_slots.txt ]]; then
        printf '  ok      dmidecode_slots.txt (%s slot records)\n' \
               "$(grep -c 'System Slot Information' dmidecode_slots.txt)"
    else
        printf '  MISSING dmidecode_slots.txt -- run:  ./fk33_slotmap.sh --capture\n'
        printf '          (needs root once; every later run reads the cache)\n'
    fi
    for f in ../pcieep.sh ../pcieep_build.sh ../jtag.sh build_xdma_driver.sh \
             fk33_pcie_check.sh fk33ctl.py fk33_go.sh \
             fk33_slotmap.sh fk33_powercycle.sh tests_hostdiag.sh; do
        [[ -x "$f" ]] || { printf '  NOT EXECUTABLE %s\n' "$f"; rc=1; }
    done
    echo
    echo "=== 5. bitstreams, saved somewhere that survives a reboot ==="
    # /tmp on this box is emptied at every boot (D /tmp in tmpfiles.d, and
    # systemd-tmpfiles-setup runs --remove --boot), and fitting the card needs
    # a power-off.  A bitstream still in the build scratchpad is a bitstream
    # you will not have tomorrow.
    ../save_bitstream.sh --check || rc=1
    echo
    echo "=== 6. the xdma module ==="
    KO="${FK33_KO:-$HOME/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko}"
    if [[ -f "$KO" ]]; then
        vm="$(modinfo -F vermagic "$KO" 2>/dev/null)"
        printf '  ok      %s\n  vermagic %s\n' "$KO" "$vm"
        [[ "$vm" == "$(uname -r)"* ]] || { echo "  MISMATCH: built against a different kernel, insmod will refuse it"; rc=1; }
        if modinfo -F alias "$KO" 2>/dev/null | grep -qi "v0000${VID^^}d0000${DID^^}"; then
            echo "  ok      $VID:$DID is in the module ID table"
        else
            echo "  MISSING $VID:$DID is NOT in the module ID table"; rc=1
        fi
    else
        printf '  MISSING %s -- run ./build_xdma_driver.sh\n' "$KO"; rc=1
    fi
    if grep -qE '^xdma ' /proc/modules; then echo "  note    an xdma module is ALREADY loaded"; fi
    if [[ -e /lib/modules/$(uname -r)/kernel/drivers/dma/xilinx/xdma.ko ]]; then
        echo "  note    the kernel also ships an UNRELATED in-tree module named"
        echo "          xdma (drivers/dma/xilinx, XRT dmaengine, 0 PCI ids)."
        echo "          Never 'modprobe xdma' -- always insmod the absolute path."
    fi
    echo
    echo "=== 7. PCI baseline ==="
    if [[ -f "$BASELINE" ]]; then
        printf '  ok      %s (%s)\n' "$BASELINE" "$(head -1 "$BASELINE" | cut -d' ' -f6)"
    else
        printf '  MISSING %s -- run ./fk33_go.sh --baseline BEFORE fitting the card\n' "$BASELINE"; rc=1
    fi
    echo
    (( rc == 0 )) && echo "FK33_GO_SELFTEST OK -- everything testable without a card passes." \
                  || echo "FK33_GO_SELFTEST FAIL"
    exit $rc
fi

echo "================================================================"
echo " FK33 PCIe bring-up -- one command, staged verdicts"
echo " $(date -Is)   kernel $(uname -r)"
echo "================================================================"
echo
echo "  >>> STOP.  The FK33 does NOT run on slot power.  If the 6-pin aux"
echo "  >>> lead from the PSU is not plugged into the card, nothing below"
echo "  >>> can possibly pass and the fans and LEDs stay dark.  Look at"
echo "  >>> the card before reading any output.  <<<"

# =============================================================== STAGE A
say "STAGE A  card powered at all (FT2232H housekeeping)"
info "isolates: the aux 6-pin lead and the on-card 3V3 housekeeping rail."
info "This is alive with no host driver, no bitstream and no PCIe link."
FTPATH=""
for s in "$USBD"/*; do
    [[ -f "$s/idVendor" ]] || continue
    [[ "$(rd "$s/idVendor")" == 0403 && "$(rd "$s/idProduct")" == 6010 ]] || continue
    if [[ "$(rd "$s/manufacturer")" == Xilinx || "$(rd "$s/product")" == *"SQRL"* ]]; then
        FTPATH="$s"; break
    fi
done
if [[ -n "$FTPATH" ]]; then
    pass A "FT2232H '$(rd "$FTPATH/product")' serial $(rd "$FTPATH/serial") -- the card has power"
else
    fail A "no Xilinx/SQRL FT2232H on USB"
    info "The 6-pin aux lead is the first thing to check.  A generic 0403:6010"
    info "from another debug adapter does NOT count and is why this matches on"
    info "the manufacturer string, not the VID:PID alone."
    info "If the card is powered and the JTAG USB lead is simply not plugged"
    info "into the host, this stage is a false alarm -- everything after it"
    info "still stands on its own."
fi
info "This stage says the card has power NOW.  It cannot say whether power was"
info "interrupted since the last time you looked, and several diagnoses turn on"
info "that.  The VCCINT pot wiper is a latch that records it:"
info "    ./fk33_powercycle.sh       warm reboot, or a real power cycle"

# =============================================================== STAGE B
say "STAGE B  which root port, and does it see a card"
info "isolates: physical presence, independently of link training."
RP=""; RPWHY=""; RP_VANISHED=""
# 0. the full baseline diff, printed BEFORE any verdict.  The first fit was
#    mis-diagnosed partly because the raw diff was never shown: the operator
#    saw only the conclusion, and the conclusion was wrong.
if [[ -f "$BASELINE" ]]; then
    info "baseline diff (every bridge, both directions):"
    diff_human | sed 's/^/  /'
fi
# 1. definitive: an enumerated FK33 tells us its own parent.
EP="$(grep -il "^0x$VID\$" "$PCID"/*/vendor 2>/dev/null | while read -r f; do
        d="$(dirname "$f")"
        [[ "$(rd "$d/device")" == "0x$DID" ]] && basename "$d"
     done | head -1)"
# The subsystem-vendor fallback goes through lspci, which always reads the REAL
# machine.  Under FK33_SYSFS that would mix a synthetic topology with live
# hardware and make the test lie, so it is skipped there.
if [[ -z "$EP" && -z "${FK33_SYSFS:-}" ]]; then
    EP="$(lspci -Dn 2>/dev/null | awk -v v="$VID" -v s="$SUBSYS" \
          'tolower($0) ~ v":" || tolower($0) ~ s":" {print $1; exit}')"
fi
if [[ -n "$EP" ]]; then
    RP="$(basename "$(dirname "$(readlink -f "$PCID/$EP")")")"
    [[ "$RP" == pci* ]] && RP=""     # parent was the host bridge, not a port
    RPWHY="parent of the enumerated endpoint $EP"
fi
# 2. a root port that did not exist in the baseline AT ALL.
#
# This is the case to expect, and it is worth understanding before tomorrow.
# The ACPI namespace on this board declares RP01 through RP19+, but only three
# of them have a PCI device:  RP01 -> 00:1c.0, RP03 -> 00:1c.2, RP05 -> 00:1c.4.
# The other sixteen are HIDDEN by the BIOS because nothing is connected to
# them.  So if the FK33 goes into a slot wired to one of those, a brand new
# bridge appears at a BDF that could not have been predicted tonight -- and
# its mere existence proves the card is physically present and powered, before
# any link has trained.  That makes this the strongest single piece of
# evidence available in the "nothing enumerated" case.
if [[ -z "$RP" && -f "$BASELINE" ]]; then
    b="$(bridge_diff | awk '$1=="NEW"{print $2; exit}')"
    [[ -n "$b" ]] && { RP="$b"; RPWHY="a root port that did NOT exist in the baseline; the BIOS unhid it, which by itself proves a powered card is in that slot"; }
fi
# 3. baseline diff: whatever MOVED is the card's port.
if [[ -z "$RP" && -f "$BASELINE" ]]; then
    # Only ports that were EMPTY in the baseline are trusted here.  A
    # populated port can retrain its own width on its own (a GPU dropping to
    # x8 at idle is normal), so "width changed" on an occupied port is not
    # evidence of anything.
    read -r b was now < <(bridge_diff | awk '$1=="WIDTH" && $3==1 {print $2, $4, $5; exit}')
    [[ -n "${b:-}" ]] && { RP="$b"; RPWHY="link width on the previously EMPTY port changed $was -> $now since the baseline"; }
    if [[ -z "$RP" ]]; then
        b="$(bridge_diff | awk '$1=="KIDS" && $3==1 && $5>$4 {print $2; exit}')"
        [[ -n "$b" ]] && { RP="$b"; RPWHY="a device appeared behind a previously empty port"; }
    fi
fi
if [[ -z "$RP" && -f "$BASELINE" ]]; then
    for s in "$SLOTD"/*; do
        [[ -d "$s" ]] || continue
        n="$(basename "$s")"; was="$(awk -v n="$n" '$1=="SLOT"&&$2==n{print $4}' "$BASELINE")"
        now="$(rd "$s/adapter")"
        if [[ -n "$was" && "$was" == 0 && "$now" == 1 ]]; then
            addr="$(rd "$s/address")"          # e.g. 0000:04:00
            for b in $(bridges); do
                [[ "$(printf '%02x' "0x$(rd "$PCID/$b/secondary_bus_number")" 2>/dev/null)" ]] || continue
                sb="$(rd "$PCID/$b/secondary_bus_number")"
                [[ "$addr" == *":$(printf '%02x' "$sb"):"* ]] && { RP="$b"; RPWHY="hotplug slot $n presence-detect went 0 -> 1"; break; }
            done
            [[ -n "$RP" ]] && break
        fi
    done
fi
# 5. NOTHING appeared or moved.  Before concluding anything, ask whether a
#    bridge VANISHED.  This is the case that used to be reported as a power or
#    seating fault, which is the exact opposite of what it means.
GONE_LIST="$(bridge_diff | awk '$1=="GONE"{print $2}')"
if [[ -n "$RP" ]]; then
    pass B "root port $RP  ($RPWHY)"
    info "$(connector_of "$RP")"
elif [[ -n "$GONE_LIST" ]]; then
    RP_VANISHED="$GONE_LIST"
    fail B "a root port that existed in the baseline is GONE from config space"
    for b in $GONE_LIST; do
        info "  vanished: $b -- $(awk -v x="$b" '$1=="BRIDGE"&&$2==x{printf "was max %s x%s, current x%s, %s device(s) behind it",$3,$4,$6,$8}' "$BASELINE")"
        cinfo="$(connector_of "$b")"; crc=$?
        info "  $cinfo"
        if (( crc == 0 )); then
            info "  So the SLOT IS NOT THE FAULT: the BIOS itself lists a physical"
            info "  connector on this port.  Do not move the card looking for a"
            info "  better slot; the card is already in a legitimate one."
        fi
    done
    info ""
    info "READ THIS BEFORE TOUCHING THE CARD.  This is NOT a power or seating"
    info "fault and reseating will not change it.  An unpowered or unseated"
    info "card cannot remove a bridge from config space; only the firmware"
    info "can.  The BIOS disables a PCH root port that saw nothing train at"
    info "POST, and a disabled port stops sourcing its 100 MHz reference"
    info "clock, so the card can never train afterwards and the port stays"
    info "disabled at every subsequent boot.  It is self-sustaining."
    info ""
    info "What this does and does not prove:"
    info "  PROVES   the firmware saw no link train on that port during POST."
    info "  DOES NOT prove the card is dead, unpowered, unseated, or that the"
    info "           bitstream is wrong.  Stage A above is the power evidence;"
    info "           if it passed, power is not the question."
    info ""
    info "Remedies, in order.  A rescan is NOT one of them -- see stage D."
    info "  1. Make the FPGA configure BEFORE the host gives up.  PCIe allows"
    info "     ~100 ms between PERST# deassertion and an expected trained"
    info "     link; JTAG configuration cannot meet that by construction.  The"
    info "     bitstream has to be in the card's SPI flash."
    info "  2. Failing that, use a port that stays visible while empty.  A"
    info "     hotplug-capable port is kept enabled and clocked so a card can"
    info "     arrive later.  Confirm it is a real card connector FIRST:"
    info "         ./fk33_slotmap.sh"
    info "     Do NOT pick one by link width.  That is what cost a power cycle"
    info "     on 2026-08-28: 0000:00:1c.0 was picked because a comment called"
    info "     it 'the only free port', and it turned out to answer"
    info "     SltCap PwrCtrl- / SltSta PresDet- with the card supposedly in"
    info "     it, i.e. almost certainly an M.2 socket."
elif [[ -f "$BASELINE" ]]; then
        fail B "no root port appeared, vanished, or changed state since the baseline"
        info "Nothing moved in EITHER direction: no new bridge, no bridge gone,"
        info "no width change, no presence-detect flip.  On this board the BIOS"
        info "HIDES a PCH root port with nothing attached, so a powered card in"
        info "a wired slot normally makes a new bridge appear even when the"
        info "link never trains.  With stage A passing on card power, the most"
        info "likely explanation left is that the card is in a slot whose root"
        info "port was ALREADY hidden at the baseline and stayed hidden."
        info "Check the 6-pin aux lead and the seating, then read:"
        info "        ./fk33_slotmap.sh"
        info "The port that was already empty in the baseline:"
        awk '$1=="BRIDGE" && $8==0 {printf "        %s  max %s x%s\n",$2,$3,$4}' "$BASELINE"
else
    fail B "no baseline file ($BASELINE) and nothing enumerated"
    info "Run  ./fk33_go.sh --baseline  with the card OUT to make this"
    info "stage able to answer.  Without it the empty ports can only be"
    info "listed, not distinguished:"
    for b in $(bridges); do
        n=$(kids "$b")
        (( n == 0 )) && info "        $b  max $(rd "$PCID/$b/max_link_speed") x$(rd "$PCID/$b/max_link_width")  EMPTY"
    done
fi
# Last resort: if nothing moved but exactly ONE port was empty in the
# baseline, read THAT port anyway and label it a guess.  x0 versus x4 on the
# only candidate slot is the single most informative number available when
# nothing enumerated, and refusing to print it because the identification is
# not certain throws away the whole point of stage C.
#
# CORRECTED 2026-08-28: this guess is now SUPPRESSED when a bridge vanished.
# That is precisely how the first fit went wrong.  The card was in 00:1c.4,
# 00:1c.4 was gone, and this fallback silently substituted 00:1c.0 -- the one
# port empty in the baseline -- so stages C and D then measured a port the card
# was never in and reported x0 and "not enumerated" about the wrong hardware.
# When a port vanished, the identity of the card's port is KNOWN, and it is the
# one that vanished; there is nothing to guess and nothing readable to measure.
if [[ -z "$RP" && -z "$RP_VANISHED" && -f "$BASELINE" ]]; then
    cands=($(awk '$1=="BRIDGE" && $8==0 {print $2}' "$BASELINE"))
    if (( ${#cands[@]} == 1 )) && [[ -e "$PCID/${cands[0]}" ]]; then
        RP="${cands[0]}"; RPGUESS=1
        info "assuming root port ${cands[0]}: it is the ONLY port that was"
        info "empty in the baseline.  Treat stage C below as a strong hint,"
        info "not proof, until something enumerates."
        info "$(connector_of "${cands[0]}")"
    fi
fi
RP="${FK33_RP:-$RP}"
RPGUESS="${RPGUESS:-0}"

# presence detect, if this port has a hotplug slot
if [[ -n "$RP" ]]; then
    sb="$(rd "$PCID/$RP/secondary_bus_number")"
    for s in "$SLOTD"/*; do
        [[ -d "$s" ]] || continue
        [[ "$(rd "$s/address")" == *":$(printf '%02x' "$sb"):"* ]] || continue
        ad="$(rd "$s/adapter")"; pw="$(rd "$s/power")"
        if [[ "$ad" == 1 ]]; then
            pass B "slot $(basename "$s") presence detect = 1, power = $pw"
            info "A card is PHYSICALLY there and the slot is powered.  If the"
            info "link below is still x0, the fault is the FPGA, the refclk or"
            info "the fingers -- NOT the seating."
        else
            fail B "slot $(basename "$s") presence detect = 0"
            info "The slot says nothing is in it.  Reseat, and confirm the aux"
            info "6-pin lead: on many carriers presence detect follows card power."
        fi
    done
fi

# =============================================================== STAGE C
say "STAGE C  link training at the root port"
info "isolates: physical + data link layers.  Works when NOTHING enumerates,"
info "which is the whole reason this stage exists."
if [[ -z "$RP" && -n "$RP_VANISHED" ]]; then
    fail C "the card's root port is not in config space, so there IS no link state"
    info "$RP_VANISHED existed in the baseline and does not exist now.  There is"
    info "no LnkSta to read, no width to compare and no presence-detect bit."
    info "That absence is not a missing measurement -- it IS the measurement,"
    info "and stage B has already given it.  Nothing here can add to it."
    info "Deliberately NOT falling back to some other port: measuring a port"
    info "the card is not in is how the 2026-08-28 fit was mis-diagnosed."
elif [[ -z "$RP" ]]; then
    fail C "no root port identified, cannot read link state"
    info "Override it by hand once you know it:  FK33_RP=0000:xx:yy.z $0"
elif [[ ! -e "$PCID/$RP" ]]; then
    fail C "root port $RP is not in config space"
    info "FK33_RP names a bridge the kernel cannot see.  Either the BDF is"
    info "wrong or the BIOS has disabled that port; ./fk33_go.sh --diff will"
    info "say which, by comparing against the baseline."
else
    MW="$(rd "$PCID/$RP/max_link_width")";  MS="$(rd "$PCID/$RP/max_link_speed")"
    CW="$(rd "$PCID/$RP/current_link_width")"; CS="$(rd "$PCID/$RP/current_link_speed")"
    info "$RP  capability: $MS x$MW   current: $CS x$CW"
    (( RPGUESS )) && info "(root port is a GUESS -- the only empty port in the baseline)"
    case "$CW" in
      0) fail C "width x0 -- LINK TRAINING FAILED"
         info "Nothing trained.  Three causes, and stage B already split them:"
         info "  presence 1 + width 0 -> FPGA unconfigured, no refclk, or GTY/"
         info "                          finger fault.  JTAG-configure, then"
         info "                          rescan (root command printed below)."
         info "  presence 0 + width 0 -> not seated, or no aux power."
         info "  LED 6 has NOT changed -> the PCIe block never left reset,"
         info "                          i.e. no reference clock." ;;
      1|2|3) if [[ "$CW" -lt "$MW" ]]; then
             fail C "width x$CW but this port can do x$MW -- LANES ARE DROPPING OUT"
             info "This is a real fault, not a slot limitation.  The port"
             info "advertises x$MW and only x$CW came up.  Contact or seating"
             info "first, then solder on the fingers, then signal integrity;"
             info "through the MCIO adapters it is the cable or the adapter's"
             info "lane mapping.  Reseat and re-run before anything else."
           else
             warn C "width x$CW, and this port's CAPABILITY is only x$MW"
             info "The link is running at the port's full width, so the lanes"
             info "that exist all came up.  The design is not limited; the PORT"
             info "is.  Whether that means the card is in the wrong connector"
             info "depends on which connector this port actually is, and that"
             info "is NOT inferable from a link width -- inferring it from a"
             info "width is exactly the error that cost a power cycle on"
             info "2026-08-28.  The authority is SMBIOS type 9:"
             info "$(connector_of "$RP")"
             info "Gen3 x1 is about 0.98 GB/s: usable for bring-up, useless"
             info "for weight loading."
           fi ;;
      4) pass C "width x4 at $CS -- the expected and correct result" ;;
      8|16) pass C "width x$CW at $CS -- wider than the x4 endpoint needs" ;;
      *) warn C "width x$CW -- read it by hand" ;;
    esac
    case "$CS" in
      "2.5 GT/s PCIe") [[ "$CW" != 0 ]] && info "NOTE trained at Gen1, not Gen3: signal integrity, not configuration." ;;
      "5.0 GT/s PCIe") info "NOTE trained at Gen2, not Gen3: same reading as above." ;;
      "8.0 GT/s PCIe") info "Gen3, as designed." ;;
    esac
    if [[ $EUID -eq 0 ]]; then
        info "root detail:"
        lspci -vvv -s "$RP" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|SltSta:' | sed 's/^/        /'
    fi
fi

# =============================================================== STAGE D
say "STAGE D  enumeration"
info "isolates: whether config space answered.  Distinct from stage C: a"
info "trained link with a wedged config space passes C and fails here."
if [[ -n "$EP" ]]; then
    pass D "endpoint $EP  $(lspci -Dnn -s "$EP" 2>/dev/null | cut -d' ' -f2-)"
    SS="$(rd "$PCID/$EP/subsystem_vendor")"
    [[ "$SS" == "0x$SUBSYS" ]] && info "subsystem vendor 0x$SUBSYS: the BOARD identifies as an FK33." \
                               || info "subsystem vendor $SS (expected 0x$SUBSYS)."
else
    fail D "no $VID:$DID and no $SUBSYS subsystem in lspci"
    # CORRECTED 2026-08-28.  This used to print the rescan command
    # unconditionally.  A rescan walks the buses BEHIND existing bridges, so
    # when the card's root port is itself absent from config space there is
    # nothing to scan behind and the command cannot possibly work -- yet it
    # was the headline remedy in exactly that case.  setpci is worse: it
    # cannot address a function that does not exist.  Which remedy is right
    # depends on which failure stage B actually found, so branch on it.
    if [[ -n "$RP_VANISHED" ]]; then
        info "DO NOT RESCAN.  It cannot work here and it is not worth trying."
        info "A rescan enumerates devices behind a bridge, and the card's"
        info "bridge ($RP_VANISHED) is not in config space at all.  There is"
        info "nothing to scan behind.  For the same reason setpci cannot"
        info "reassert PERST: you cannot setpci a function that does not exist."
        info "The remedy is the one stage B gave: get the FPGA configured"
        info "before POST finishes (SPI flash), or move to a port that stays"
        info "visible while empty, identified with ./fk33_slotmap.sh."
    elif [[ -n "$RP" && -e "$PCID/$RP" ]]; then
        info "The card may have been JTAG-configured after boot, in which case"
        info "the kernel has not looked since.  The bridge $RP IS in config"
        info "space, so a rescan is a real remedy here.  ROOT:"
        info "    sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
        info "If a rescan does not find it and stage C showed x0, reassert PERST"
        info "with a secondary bus reset, then rescan again.  ROOT:"
        info "    sudo setpci -s $RP BRIDGE_CONTROL=40:40 ; sleep 1"
        info "    sudo setpci -s $RP BRIDGE_CONTROL=00:40 ; sleep 1"
        info "    sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
        info "AFTERWARDS re-read the FPGA over JTAG: whether SQRL strapped PERST"
        info "to PROG_B in copper is not knowable from any file we hold."
    else
        info "No root port was identified, so no targeted remedy can be given."
        info "A blind rescan is cheap and harmless, but it only finds devices"
        info "behind bridges that ALREADY exist, so it will not help if the"
        info "card's port is hidden.  ROOT:"
        info "    sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
        info "Then take a baseline with the card out and re-run --diff, which"
        info "is the only thing that can distinguish the two cases."
    fi
fi

# =============================================================== STAGE E
say "STAGE E  BAR assignment"
info "isolates: whether the firmware/kernel could place 64-bit prefetchable"
info "windows.  A failure here is a BIOS resource problem, not a card fault."
if [[ -z "$EP" ]]; then
    info "skipped: nothing enumerated"
elif awk 'NR<=6 && $1!="0x0000000000000000"{f=1} END{exit !f}' "$PCID/$EP/resource"; then
    awk 'NR<=6 && $1!="0x0000000000000000"{printf "        BAR%d %s .. %s\n",NR-1,$1,$2}' "$PCID/$EP/resource"
    pass E "BARs assigned"
else
    fail E "device enumerated but NO BAR was placed"
    info "Enable Above 4G Decoding in BIOS.  The XDMA BARs are 64-bit"
    info "prefetchable and a 32-bit-only window cannot hold them."
    info "Second cause: MMIO exhaustion.  Two 32 GB GPU BAR1 apertures are"
    info "already resident on this box; dropping Resizable BAR to 'Disabled'"
    info "frees 63 GB of address space at a small GPU cost."
fi

# =============================================================== STAGE F
say "STAGE F  driver bind and character devices"
info "isolates: a device-ID match (no bind) from an AXI side that is not"
info "answering (bind, but the driver finds no engines)."
if grep -qE '^xdma ' /proc/modules; then
    info "module xdma is loaded"
else
    fail F "the xdma module is not loaded"
    info "It does NOT autoload: nothing in /lib/modules claims $VID:$DID."
    info "And do NOT use modprobe -- the kernel ships an UNRELATED in-tree"
    info "module also called xdma (drivers/dma/xilinx, the XRT dmaengine"
    info "driver, zero PCI IDs) and modprobe will load that one instead."
    info "Load ours by absolute path, in poll mode first.  ROOT:"
    info "    sudo insmod \$HOME/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko poll_mode=1"
    info "Not from a code-server terminal: use claude-tmux or systemd-run --unit."
fi
if [[ -n "$EP" ]]; then
    # readlink -f resolves a path that does NOT exist, so on an unbound device
    # this used to produce the literal string "driver" and report
    #   WARN F  0000:06:00.0 bound to 'driver', not xdma
    #   ROOT:  echo ... | sudo tee /sys/bus/pci/drivers/driver/unbind
    # which is a nonexistent path and reads as a mystery third driver.  Same
    # family as the -1 defect: a FAILED lookup rendered as a VALUE.  Test the
    # symlink itself.
    if [[ -L "$PCID/$EP/driver" ]]; then
        DRV="$(basename "$(readlink -f "$PCID/$EP/driver")")"
    else
        DRV=""
    fi
    case "$DRV" in
      xdma) pass F "$EP bound to xdma" ;;
      ""|.) fail F "$EP has no driver bound"
            info "If the module is loaded this is a match-table miss, nothing"
            info "more.  $VID:$DID IS in the table of the built module, so a"
            info "miss here means a different module got loaded.  ROOT:"
            info "    echo \"$VID $DID\" | sudo tee /sys/bus/pci/drivers/xdma/new_id" ;;
      *)    warn F "$EP bound to '$DRV', not xdma"
            info "ROOT:  echo $EP | sudo tee /sys/bus/pci/drivers/$DRV/unbind" ;;
    esac
fi
NODES=0
for n in /dev/xdma0_user /dev/xdma0_h2c_0 /dev/xdma0_c2h_0; do
    [[ -e "$n" ]] && { info "$(ls -l "$n")"; NODES=$((NODES+1)); }
done
if (( NODES == 3 )); then
    pass F "all three character devices present"
    for n in /dev/xdma0_user /dev/xdma0_h2c_0 /dev/xdma0_c2h_0; do
        [[ -r "$n" && -w "$n" ]] || { warn F "$n is not read/write for this user"
            info "ROOT:  echo 'KERNEL==\"xdma*\", MODE=\"0666\"' | sudo tee /etc/udev/rules.d/60-xdma.rules"
            info "       sudo udevadm control --reload && sudo udevadm trigger"; break; }
    done
elif (( NODES > 0 )); then
    fail F "only $NODES of 3 character devices exist"
    info "A bound driver that finds no DMA engines reached config space but"
    info "the AXI side is not responding: bitstream or user clock, not link."
    info "    sudo dmesg | grep -i xdma"
else
    [[ -n "$EP" ]] && fail F "no /dev/xdma0_* nodes"
fi

# =============================================================== STAGE G
say "STAGE G  identity, MMIO writes and the DMA round trip"
info "isolates: everything downstream of the BAR.  fk33_bringup's own stages"
info "0-4 (plus 5 with --hbm).  The identity word 0x464B3333 cannot be forged"
info "by a loaded driver, an unanswered BAR (0xFFFFFFFF) or a fabric in reset"
info "(0x00000000)."
if [[ ! -e /dev/xdma0_user ]]; then
    info "skipped: /dev/xdma0_user does not exist"
    fail G "not reached"
else
    make --no-print-directory >/dev/null 2>&1 || true
    ARGS=(); (( DO_HBM )) && ARGS+=(--hbm)
    if ./fk33_bringup "${ARGS[@]}"; then
        pass G "fk33_bringup: ALL PASS"
    else
        fail G "fk33_bringup reported a failure -- read its own FIRST-failure line above"
    fi
fi

# =============================================================== verdict
echo
echo "================================================================"
if [[ -z "$FIRST_FAIL" ]]; then
    echo " FK33_GO OK -- every stage passed."
    echo " Next:  ./fk33_go.sh --hbm      then  ./fk33_bringup --bench 1024"
    echo "================================================================"
    exit 0
fi
cat <<EOF
 FK33_GO FAIL

 FIRST failing stage: $FIRST_FAIL
   $FIRST_FAIL_WHY

 Every stage after $FIRST_FAIL is downstream of that fault and its result
 means nothing.  Start there.  The stage's own notes above name the
 remedy; the reasoning is in
   docs/2026-08-27_fk33-pcie-bringup-procedure.md
================================================================
EOF
case "$FIRST_FAIL" in
  A) echo " -> POWER.  The 6-pin aux lead. Nothing else can be diagnosed first." ;;
  B) if [[ -n "$RP_VANISHED" ]]; then
       echo " -> FIRMWARE.  The root port $RP_VANISHED is GONE from config space."
       echo "    Not a seating or power fault: only the BIOS can remove a bridge."
       echo "    Get the FPGA configured before POST finishes (SPI flash), or"
       echo "    move to a connector confirmed by ./fk33_slotmap.sh."
     else
       echo " -> SEATING or POWER.  Nothing is physically detected in any slot."
     fi ;;
  C) echo " -> LINK.  Look at LED 6 on the card, and re-read pcieep.sh --check." ;;
  D) echo " -> CONFIG SPACE.  Rescan first; that is nearly always the answer" ;;
  E) echo " -> BIOS.  Above 4G Decoding." ;;
  F) echo " -> DRIVER.  insmod by absolute path, never modprobe." ;;
  G) echo " -> FABRIC.  The link and the BAR are proven; the fault is inside." ;;
esac
exit 1
