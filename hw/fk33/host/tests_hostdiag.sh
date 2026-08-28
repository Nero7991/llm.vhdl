#!/usr/bin/env bash
# tests_hostdiag.sh -- regression tests for the host-side diagnostic tooling.
#
# NO card, NO root, NO FPGA, NO reboot.  Every case is a synthetic sysfs tree
# built to mirror the real one exactly: $PCID entries are symlinks into a
# devices/ hierarchy, so a bridge's children are found the same way the kernel
# presents them.
#
# WHY THESE PARTICULAR CASES
# --------------------------
# On 2026-08-28 fk33_go.sh mis-diagnosed the first FK33 fit.  Every case below
# is either the situation that produced a wrong answer, or a situation the tool
# already handled correctly and must go on handling.  A fix that turns one
# wrong answer into a different wrong answer is not a fix, so the "already
# worked" cases are as load-bearing as the regression ones.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

GO=./fk33_go.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

# ------------------------------------------------------------ tree building
# mkbridge ROOT bdf maxspeed maxwidth curspeed curwidth secbus
mkbridge () {
    local r=$1 b=$2
    mkdir -p "$r/devices/pci0000:00/$b"
    printf '%s\n' "$3" > "$r/devices/pci0000:00/$b/max_link_speed"
    printf '%s\n' "$4" > "$r/devices/pci0000:00/$b/max_link_width"
    printf '%s\n' "$5" > "$r/devices/pci0000:00/$b/current_link_speed"
    printf '%s\n' "$6" > "$r/devices/pci0000:00/$b/current_link_width"
    printf '%s\n' "$7" > "$r/devices/pci0000:00/$b/secondary_bus_number"
    printf '0x8086\n' > "$r/devices/pci0000:00/$b/vendor"
    printf '0x7a38\n' > "$r/devices/pci0000:00/$b/device"
    mkdir -p "$r/bus/pci/devices"
    ln -sfn "../../../devices/pci0000:00/$b" "$r/bus/pci/devices/$b"
}
# mkdev ROOT parent_bdf bdf vendor device
mkdev () {
    local r=$1 p=$2 b=$3
    mkdir -p "$r/devices/pci0000:00/$p/$b"
    printf '%s\n' "$4" > "$r/devices/pci0000:00/$p/$b/vendor"
    printf '%s\n' "$5" > "$r/devices/pci0000:00/$p/$b/device"
    printf '0x1e24\n'  > "$r/devices/pci0000:00/$p/$b/subsystem_vendor"
    printf '0x%016x 0x%016x 0x0\n' $((0x4802b00000)) $((0x4802b1ffff)) \
        > "$r/devices/pci0000:00/$p/$b/resource"
    for _ in 2 3 4 5 6; do
        printf '0x0000000000000000 0x0000000000000000 0x0\n' \
            >> "$r/devices/pci0000:00/$p/$b/resource"
    done
    ln -sfn "../../../devices/pci0000:00/$p/$b" "$r/bus/pci/devices/$b"
}
# A powered card on USB, so stage A PASSES.  This is essential: the wrong
# verdict being reproduced here ("check the 6-pin aux lead") was printed while
# stage A had already proven card power.
mkusb () {
    local r=$1
    mkdir -p "$r/bus/usb/devices/1-10"
    printf '0403\n'    > "$r/bus/usb/devices/1-10/idVendor"
    printf '6010\n'    > "$r/bus/usb/devices/1-10/idProduct"
    printf 'SQRL\n'    > "$r/bus/usb/devices/1-10/manufacturer"
    printf 'SQRL FK\n' > "$r/bus/usb/devices/1-10/product"
    printf '153300000607\n' > "$r/bus/usb/devices/1-10/serial"
}
newtree () {
    local r="$TMP/$1"; rm -rf "$r"; mkdir -p "$r/bus/pci/devices" "$r/bus/pci/slots"
    mkusb "$r"; echo "$r"
}

# The real pre-fit baseline of this machine, verbatim from host/pci_baseline.txt.
write_baseline () {
    cat > "$1" <<'EOF'
# fk33 PCI baseline -- 2026-08-27T21:25:45-06:00 -- kernel 6.8.0-138-generic
# columns: BRIDGE maxspeed maxwidth curspeed curwidth secbus nchildren
BRIDGE 0000:00:1c.0 8.0GT/sPCIe 1 2.5GT/sPCIe 0 4 0
BRIDGE 0000:00:1c.2 8.0GT/sPCIe 1 5.0GT/sPCIe 1 5 1
BRIDGE 0000:00:1c.4 16.0GT/sPCIe 4 2.5GT/sPCIe 4 6 2
# columns: SLOT name address adapter power curspeed
# columns: DEV bdf vendor device
EOF
}

run_go () {   # run_go <sysfs root> <baseline file>
    FK33_SYSFS="$1" FK33_BASELINE="$2" $GO 2>&1
}

# want / wantnot assert on the whole captured output of one run.
want    () { grep -qF -- "$2" <<<"$1" && return 0; echo "    FAIL missing: $2"; fails=$((fails+1)); }
wantnot () { grep -qF -- "$2" <<<"$1" && { echo "    FAIL present but must not be: $2"; fails=$((fails+1)); }; return 0; }
wantre  () { grep -qE -- "$2" <<<"$1" && return 0; echo "    FAIL no match for /$2/"; fails=$((fails+1)); }

BL="$TMP/baseline.txt"; write_baseline "$BL"

# ===========================================================================
echo "=== CASE 1  the 2026-08-28 regression: card SWAPPED into an OCCUPIED"
echo "===         slot, and the BIOS then hid that root port entirely ==="
# 1c.4 held an RTX 3090 in the baseline.  The FK33 replaced it, nothing trained
# at POST, and the bridge is gone.  1c.0 and 1c.2 are unchanged.
R="$(newtree case1)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "2.5 GT/s PCIe" 0 4
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
OUT1="$(run_go "$R" "$BL")"
want    "$OUT1" "PASS  A"
want    "$OUT1" "GONE   0000:00:1c.4"
want    "$OUT1" "a root port that existed in the baseline is GONE from config space"
want    "$OUT1" "This is NOT a power or seating"
wantnot "$OUT1" "Check the 6-pin aux lead and reseat."
wantnot "$OUT1" "no root port appeared or changed state since the baseline"
# It must NOT silently substitute 1c.0, the one port empty in the baseline.
wantnot "$OUT1" "assuming root port 0000:00:1c.0"
wantnot "$OUT1" "PASS  B    root port 0000:00:1c.0"
wantnot "$OUT1" "capability: 8.0 GT/s PCIe x1"
want    "$OUT1" "the card's root port is not in config space, so there IS no link state"
want    "$OUT1" "DO NOT RESCAN."
wantnot "$OUT1" "    sudo setpci -s 0000:00:1c.0"
want    "$OUT1" "The root port 0000:00:1c.4 is GONE from config space."
# The SMBIOS capture says 1c.4 has a real connector, so the tool must actively
# talk the operator OUT of moving the card, which is what happened last time.
want    "$OUT1" "slot behind 0000:00:1c.4: YES"
want    "$OUT1" "So the SLOT IS NOT THE FAULT"

# ===========================================================================
echo
echo "=== CASE 2  the case that ALREADY worked: a brand new root port appears"
echo "===         with the FK33 enumerated behind it ==="
R="$(newtree case2)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "2.5 GT/s PCIe" 0 4
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
mkbridge "$R" 0000:00:1c.4 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 4 6
mkdev    "$R" 0000:00:1c.4 0000:06:00.0 0x10de 0x2204
mkdev    "$R" 0000:00:1c.4 0000:06:00.1 0x10de 0x1aef
mkbridge "$R" 0000:00:1d.0 "16.0 GT/s PCIe" 4 "8.0 GT/s PCIe" 4 7
mkdev    "$R" 0000:00:1d.0 0000:07:00.0 0x10ee 0x9034
OUT2="$(run_go "$R" "$BL")"
want    "$OUT2" "NEW    0000:00:1d.0"
want    "$OUT2" "PASS  B    root port 0000:00:1d.0"
want    "$OUT2" "parent of the enumerated endpoint 0000:07:00.0"
want    "$OUT2" "PASS  C    width x4"
want    "$OUT2" "PASS  D    endpoint 0000:07:00.0"
wantnot "$OUT2" "GONE"
wantnot "$OUT2" "DO NOT RESCAN."

# ===========================================================================
echo
echo "=== CASE 3  a new root port appears but NOTHING enumerates behind it:"
echo "===         the port is visible, so a rescan IS the right remedy ==="
R="$(newtree case3)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "2.5 GT/s PCIe" 0 4
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
mkbridge "$R" 0000:00:1c.4 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 4 6
mkdev    "$R" 0000:00:1c.4 0000:06:00.0 0x10de 0x2204
mkdev    "$R" 0000:00:1c.4 0000:06:00.1 0x10de 0x1aef
mkbridge "$R" 0000:00:1d.0 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 0 7
OUT3="$(run_go "$R" "$BL")"
want    "$OUT3" "PASS  B    root port 0000:00:1d.0"
want    "$OUT3" "the BIOS unhid it"
want    "$OUT3" "FAIL  C    width x0 -- LINK TRAINING FAILED"
want    "$OUT3" "sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
want    "$OUT3" "sudo setpci -s 0000:00:1d.0 BRIDGE_CONTROL=40:40"
wantnot "$OUT3" "DO NOT RESCAN."

# ===========================================================================
echo
echo "=== CASE 4  the ORIGINAL design case: a card added to a port that was"
echo "===         EMPTY in the baseline and is still visible ==="
R="$(newtree case4)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "8.0 GT/s PCIe" 1 4
mkdev    "$R" 0000:00:1c.0 0000:04:00.0 0x10ee 0x9034
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
mkbridge "$R" 0000:00:1c.4 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 4 6
mkdev    "$R" 0000:00:1c.4 0000:06:00.0 0x10de 0x2204
mkdev    "$R" 0000:00:1c.4 0000:06:00.1 0x10de 0x1aef
OUT4="$(run_go "$R" "$BL")"
want    "$OUT4" "WIDTH  0000:00:1c.0  current width 0 -> 1"
want    "$OUT4" "KIDS   0000:00:1c.0  0 -> 1"
want    "$OUT4" "PASS  B    root port 0000:00:1c.0"
want    "$OUT4" "PASS  D    endpoint 0000:04:00.0"
wantnot "$OUT4" "GONE"
wantnot "$OUT4" "DO NOT RESCAN."

# ===========================================================================
echo
echo "=== CASE 5  genuinely NOTHING moved.  The old wording was right here"
echo "===         and must survive, minus the false claim about a vanish ==="
R="$(newtree case5)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "2.5 GT/s PCIe" 0 4
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
mkbridge "$R" 0000:00:1c.4 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 4 6
mkdev    "$R" 0000:00:1c.4 0000:06:00.0 0x10de 0x2204
mkdev    "$R" 0000:00:1c.4 0000:06:00.1 0x10de 0x1aef
OUT5="$(run_go "$R" "$BL")"
want    "$OUT5" "no bridge changed in either direction since the baseline."
want    "$OUT5" "FAIL  B    no root port appeared, vanished, or changed state"
want    "$OUT5" "Check the 6-pin aux lead and the seating"
wantnot "$OUT5" "GONE   0000"
wantnot "$OUT5" "DO NOT RESCAN."
# It MAY still fall back to the one empty port, but only because none vanished.
want    "$OUT5" "assuming root port 0000:00:1c.0"

# ===========================================================================
echo
echo "=== CASE 6  an occupied port whose width merely RETRAINED must not be"
echo "===         mistaken for the card's port (a GPU idling to x8 is normal) ==="
R="$(newtree case6)"
mkbridge "$R" 0000:00:1c.0 "8.0 GT/s PCIe" 1 "2.5 GT/s PCIe" 0 4
mkbridge "$R" 0000:00:1c.2 "8.0 GT/s PCIe" 1 "5.0 GT/s PCIe" 1 5
mkdev    "$R" 0000:00:1c.2 0000:05:00.0 0x8086 0x15f3
mkbridge "$R" 0000:00:1c.4 "16.0 GT/s PCIe" 4 "2.5 GT/s PCIe" 2 6
mkdev    "$R" 0000:00:1c.4 0000:06:00.0 0x10de 0x2204
mkdev    "$R" 0000:00:1c.4 0000:06:00.1 0x10de 0x1aef
OUT6="$(run_go "$R" "$BL")"
want    "$OUT6" "WIDTH  0000:00:1c.4  current width 4 -> 2  (port was occupied in the baseline)"
wantnot "$OUT6" "PASS  B    root port 0000:00:1c.4"
wantnot "$OUT6" "GONE"

# ===========================================================================
echo
echo "=== CASE 7  the driver symlink: an UNBOUND device must not report as"
echo "===         bound to a driver called 'driver' ==="
# CASE 2's tree has an enumerated FK33 with no driver symlink at all.
want    "$OUT2" "FAIL  F    0000:07:00.0 has no driver bound"
wantnot "$OUT2" "bound to 'driver'"
wantnot "$OUT2" "/sys/bus/pci/drivers/driver/unbind"

echo
if (( fails )); then
    echo "FK33_HOSTDIAG_TESTS FAIL ($fails)"
    exit 1
fi
echo "FK33_HOSTDIAG_TESTS OK"
