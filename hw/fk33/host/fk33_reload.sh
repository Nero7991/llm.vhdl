#!/usr/bin/env bash
# Reload the FK33 over JTAG with the PCIe bus taken down and brought back up
# around it.  ONE command, run with sudo:
#
#     sudo hw/fk33/host/fk33_reload.sh                  # default engine bitstream
#     sudo hw/fk33/host/fk33_reload.sh path/to.bit      # a specific one
#     sudo hw/fk33/host/fk33_reload.sh --with-vccint    # also raise VCCINT first
#
# WHY THE BUS HAS TO COME DOWN.  Reconfiguring the FPGA while the xdma driver is
# bound is the documented way to hang the host: the endpoint vanishes
# mid-transaction and later MMIO reads return all-ones or raise a bus error.
# JTAG configuration takes tens of seconds against the ~100 ms PCIe allows from
# PERST to the first config read, so the device cannot be reset in place.  Hence
# remove -> configure -> rescan.
#
# NEVER `modprobe xdma`.  The kernel ships an unrelated in-tree module of the
# same name (drivers/dma/xilinx, AMD XRT dmaengine) with ZERO PCI aliases: it
# loads, binds nothing, and no amount of rescanning brings the real driver in.
# Always insmod the absolute path.  poll_mode=1 keeps MSI-X out of the picture.
#
# ROOT AND NON-ROOT ARE BOTH NEEDED, which is the whole reason this script
# exists.  rmmod/remove/rescan/insmod need root; Vivado must NOT run as root, so
# the configure step drops back to the invoking user.
set -euo pipefail

CARD_SERIAL="${FK33_CARD:-153300000607A}"     # card 1, the one in the slot
DEV="${FK33_PCI_DEV:-0000:06:00.0}"
WITH_VCCINT=0
BIT=""

for a in "$@"; do
    case "$a" in
        --with-vccint) WITH_VCCINT=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) BIT="$a" ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Run me with sudo: sudo $0 $*" >&2; exit 1; }
REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" ]] || { echo "Run via sudo from your own account, not a root shell." >&2; exit 1; }
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

FK33_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ -n "$BIT" ]] || BIT="$FK33_DIR/bit/fk33_pcieep_eng.bit"
[[ -f "$BIT" ]] || { echo "BITSTREAM_MISSING $BIT" >&2; exit 1; }
# ABSOLUTE, before anything changes directory.  The configure step below runs
# `cd "$FK33_DIR" && ./pcieep.sh` with EP_BIT="$BIT", so a path given relative
# to the repo root (`hw/fk33/bit/x.bit`, the documented form) passed THIS
# check and then failed inside pcieep.sh as BITSTREAM_MISSING, after the bus
# had already been taken down.  MEASURED 2026-09-19 06:34: the card came back
# on the exit trap still carrying the previous bitstream, with nothing in the
# transcript saying so except one line in the middle.
BIT=$(readlink -f "$BIT")
KO="$REAL_HOME/GitHub/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko"
[[ -f "$KO" ]] || { echo "XDMA_KO_MISSING $KO" >&2; exit 1; }

asuser () { sudo -u "$REAL_USER" -H env HOME="$REAL_HOME" "$@"; }

# Resolve by absolute path.  These live in /usr/sbin, which is not guaranteed to
# be on sudo's secure_path, and a not-found tool makes an `if` read as "no".
LSMOD=$(command -v lsmod || echo /usr/sbin/lsmod)
RMMOD=$(command -v rmmod || echo /usr/sbin/rmmod)
INSMOD=$(command -v insmod || echo /usr/sbin/insmod)
LSPCI=$(command -v lspci || echo /usr/bin/lspci)
for t in "$LSMOD" "$RMMOD" "$INSMOD" "$LSPCI"; do
    [[ -x "$t" ]] || { echo "TOOL_MISSING $t" >&2; exit 1; }
done

echo "=== plan ==="
echo "  card       $CARD_SERIAL   (PCI $DEV)"
echo "  bitstream  $BIT"
echo "             $(stat -c %s "$BIT") bytes, $(stat -c %y "$BIT" | cut -d. -f1)"
echo "  driver     $KO"
echo "  VCCINT     $([[ $WITH_VCCINT = 1 ]] && echo 'raise via probe bitstream' || echo 'assume already raised (--with-vccint to raise)')"
echo

# ---------------------------------------------------------------- pre-flight
echo "=== pre-flight ==="
# Capture, do not `... | grep -q .`.  A guard built on a pipeline's exit status
# fails OPEN when anything upsets the pipeline, and this one decides whether it
# is safe to yank a live PCIe device.  Capturing the text and testing it makes
# the guard depend on the ANSWER rather than on the plumbing.
#
# Not a hypothetical: on the 2026-08-29 run the identical `lsmod | grep -qE` a
# few lines down evaluated FALSE while the module was demonstrably loaded, so
# rmmod was skipped and the later insmod failed with "File exists".  I did NOT
# establish why.  A SIGPIPE-plus-pipefail theory was tested and REFUTED (the
# pipeline returns 0 here, not 141).  The leading remaining suspect is PATH:
# lsmod is /usr/sbin/lsmod and this runs under sudo's secure_path.  Hence both
# the absolute-path lookup and the loud reporting below -- the next run
# diagnoses itself instead of failing silently again.
HOLDERS="$(lsof /dev/xdma0_* 2>/dev/null || true)"
if [[ -n "$HOLDERS" ]]; then
    echo "REFUSING: something still holds a /dev/xdma* node:" >&2
    printf '%s\n' "$HOLDERS" >&2
    exit 1
fi
echo "  no process holds /dev/xdma*"
lspci -d 10ee: || echo "  (no Xilinx device on the bus yet)"

# Read VCCINT over the JTAG DRP.  Read-only and explicitly safe against a card
# that is enumerated and serving PCIe: it configures nothing.
echo "  reading VCCINT over JTAG DRP..."
V=$(asuser env FK33_TARGET="$CARD_SERIAL" FK33_RUNLOG=/tmp/fk33_reload_status.out \
        "$FK33_DIR/flash.sh" --status </dev/null 2>&1 \
        | grep -oP 'VCCINT=\K[0-9.]+' | head -1 || true)
echo "  VCCINT = ${V:-unknown}"
if [[ $WITH_VCCINT = 0 && -n "$V" ]]; then
    if awk -v v="$V" 'BEGIN{exit !(v < 0.698)}'; then
        echo "REFUSING: VCCINT $V V is below the 0.698 V floor for the -2L grade." >&2
        echo "          Re-run with --with-vccint to raise it first." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------- bus down
BUS_IS_DOWN=0
bring_bus_up () {
    echo
    echo "=== bus up ==="
    echo 1 > /sys/bus/pci/rescan || true
    sleep 2
    if [[ -n "$(lspci -d 10ee: || true)" ]]; then
        lspci -d 10ee:
        lspci -vv -s "${DEV#0000:}" 2>/dev/null | grep -iE 'LnkSta:|LnkCap:|Region 0' || true
        if [[ -z "$($LSMOD 2>/dev/null | grep -E '^xdma ' || true)" ]]; then
            echo "--- insmod $(basename "$KO") poll_mode=1 ---"
            "$INSMOD" "$KO" poll_mode=1 || echo "INSMOD_FAILED"
        fi
        ls -la /dev/xdma0_control /dev/xdma0_user 2>/dev/null || echo "NO /dev/xdma* NODES"
        echo "BUS_UP_OK"
    else
        echo "NO XILINX DEVICE AFTER RESCAN."
        echo "  The link did not train, or the bitstream does not bring up the endpoint."
        echo "  This is NOT necessarily fatal: JTAG still reaches the card."
        echo "BUS_UP_FAILED"
    fi
}
# If anything fails after the device is removed, still put the bus back.
trap '[[ $BUS_IS_DOWN = 1 ]] && bring_bus_up' EXIT

echo
echo "=== bus down ==="
# ORDER IS LOAD-BEARING: REMOVE THE DEVICE FIRST, THEN rmmod.
#
# MEASURED 2026-08-29: rmmod-then-remove fails with "Module xdma is in use",
# because the module's refcount is held by the bound device itself
# (/sys/module/xdma/refcnt = 1, /sys/bus/pci/drivers/xdma/0000:06:00.0).
# Removing the device unbinds it and drops the refcount to 0, after which the
# rmmod succeeds.  Doing it the other way round can never work with the card
# present, which is the only case that matters.
if [[ -e /sys/bus/pci/devices/$DEV/remove ]]; then
    echo "--- removing $DEV (this also unbinds the driver) ---"
    echo 1 > "/sys/bus/pci/devices/$DEV/remove"
    sleep 1
else
    echo "  $DEV already absent from sysfs"
fi
BUS_IS_DOWN=1

# Now the module is idle, so it can be unloaded and reloaded cleanly against
# the new bitstream.  A failure here is NOT fatal: the first run of this script
# proved the driver re-binds correctly on rescan while staying loaded, so a
# stuck rmmod costs a stale driver, not a broken card.  Report and continue.
LSMOD_OUT="$($LSMOD 2>&1 || true)"
if [[ -z "$LSMOD_OUT" ]]; then
    echo "  WARNING: '$LSMOD' produced NO output. Cannot tell if xdma is loaded."
fi
if [[ -n "$(printf '%s\n' "$LSMOD_OUT" | grep -E '^xdma ' || true)" ]]; then
    # Wait for the refcount to actually drop.  MEASURED 2026-08-29: it was
    # still 1 immediately after the device removal, so the single `sleep 1`
    # above was not enough on its own.  Bounded, and skipped entirely if it
    # never reaches 0, because a stale driver is not worth failing the run for.
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        _rc=$(cat /sys/module/xdma/refcnt 2>/dev/null || echo 0)
        [[ "$_rc" == "0" ]] && break
        sleep 1
    done
    echo "--- rmmod xdma (refcnt now ${_rc:-?}) ---"
    if [[ "${_rc:-1}" != "0" ]]; then
        echo "  refcount never reached 0; SKIPPING rmmod rather than forcing it."
        echo "  The driver re-binds on rescan, which is MEASURED to work."
    elif ! "$RMMOD" xdma; then
        echo "  RMMOD_FAILED -- continuing with the driver still loaded."
        echo "  It will re-bind on rescan; the insmod below will be skipped."
    fi
else
    echo "  xdma not loaded, per $LSMOD (nothing to rmmod)"
fi
lspci -d 10ee: || echo "  Xilinx device gone from the bus (expected)"

# ------------------------------------------------------------- configure
echo
echo "=== configure (as $REAL_USER, NOT root) ==="
PCIEEP_ARGS=()
[[ $WITH_VCCINT = 0 ]] && PCIEEP_ARGS+=(--no-vccint)
asuser env FK33_TARGET="$CARD_SERIAL" FK33_XSDB_TARGET="$CARD_SERIAL" \
           EP_BIT="$BIT" \
           bash -c "cd '$FK33_DIR' && ./pcieep.sh ${PCIEEP_ARGS[*]}" </dev/null

# bring_bus_up runs from the EXIT trap
