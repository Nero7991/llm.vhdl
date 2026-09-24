#!/usr/bin/env bash
# fk33_hotreset.sh -- reset ONE FK33's logic with a PCIe hot reset (secondary
# bus reset on its upstream bridge), WITHOUT reconfiguring the FPGA and without
# Vivado.  Run with sudo:
#
#     sudo hw/fk33/host/fk33_hotreset.sh 0000:06:00.0     # card 2 (MCIO riser)
#     sudo hw/fk33/host/fk33_hotreset.sh 0000:07:00.0     # card 1
#
# WHY IT WORKS (DERIVED from hw/fk33/build_fk33_pcieep.tcl, not yet measured
# when this was written).  card/rst, the port grant, the engine and the seam
# all hang off core_reset, whose ext_reset_in is xdma/axi_aresetn, and the XDMA
# core asserts axi_aresetn while its link is down.  A secondary bus reset takes
# the link down, so every unit on the card is reset.  The bitstream stays.
#
# WHAT IT ALSO RESETS.  The HBM controller's AXI and APB resets hang off the
# same net, so HBM CONTENTS MAY BE LOST.  Afterwards run
#     fk33_load_weights.py load <manifest> --verify
# for that card; it re-checks by digest and reloads only what differs.
#
# WHEN TO USE IT.  A unit wedged so that CTRL CLR_ERR clears the flag but the
# next token hangs again (MEASURED 2026-09-24: card 2's attention unit, D
# watchdog at step 85, the first C_JOB of the second half, on every token).
#
# SAFETY.  Only the two pinned card addresses are accepted.  The bridge is read
# from sysfs and must be a PCI bridge with exactly this one card below it, so a
# reset can never reach another device.  The other card keeps its bitstream,
# its HBM and its link; its /dev/xdma* nodes disappear and come back only
# because the driver is reloaded (fk33-pci down/up), and the node NUMBERS may
# swap afterwards: identify cards by `fk33ctl.py seam` and `fk33_imgfp.py
# which`, never by node number.  Nothing may hold /dev/xdma* open.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "fk33_hotreset.sh: run with sudo" >&2; exit 1; }
DEV="${1:-}"
case "$DEV" in
  0000:06:00.0|0000:07:00.0) ;;
  *) echo "usage: sudo $0 0000:06:00.0|0000:07:00.0" >&2; exit 1 ;;
esac
PATH=/usr/sbin:/usr/bin:/sbin:/bin
HELPER=/usr/local/sbin/fk33-pci
[[ -x "$HELPER" ]] || { echo "fk33_hotreset.sh: $HELPER is not installed" >&2; exit 1; }

# The bridge above the card, from the kernel's own topology, BEFORE the card
# is removed (afterwards it has no sysfs node to read).
[[ -e /sys/bus/pci/devices/$DEV ]] || { echo "fk33_hotreset.sh: $DEV is not on the bus; run '$HELPER up' first" >&2; exit 1; }
P=$(readlink -f "/sys/bus/pci/devices/$DEV")
BR=$(basename "$(dirname "$P")")
[[ "$BR" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || { echo "fk33_hotreset.sh: $DEV has no PCI bridge above it ($BR)" >&2; exit 1; }
CLS=$(cat "/sys/bus/pci/devices/$BR/class")
[[ "$CLS" == 0x0604* ]] || { echo "fk33_hotreset.sh: $BR is class $CLS, not a PCI bridge" >&2; exit 1; }
# Devices only: the bridge's directory also holds port-service entries
# (0000:00:1c.4:pcie001 ...), which are not PCI functions below it.
BELOW=$(ls /sys/bus/pci/devices/$BR/ 2>/dev/null | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$' || true)
[[ "$BELOW" == "$DEV" ]] || { echo "fk33_hotreset.sh: $BR has '$BELOW' below it, not only $DEV; refusing" >&2; exit 1; }
echo "card $DEV  bridge $BR  ($(lspci -s "$BR" | cut -d' ' -f2-))"

for p in /proc/[0-9]*; do
  # Capture, then test: `ls | grep -q` under pipefail reads a MATCH as false
  # (SIGPIPE on ls), the trap /usr/local/sbin/fk33-pci records for lsmod.
  fds=$(ls -l "$p/fd" 2>/dev/null || true)
  if [[ "$fds" == *"/dev/xdma"* ]]; then
    echo "fk33_hotreset.sh: $(basename "$p") ($(readlink "$p/exe")) holds a /dev/xdma node open; stop it first" >&2
    exit 1
  fi
done

"$HELPER" down "$DEV"
BC=$(setpci -s "$BR" BRIDGE_CONTROL.w)
echo "--- secondary bus reset on $BR (BRIDGE_CONTROL was 0x$BC) ---"
setpci -s "$BR" BRIDGE_CONTROL.w=0x40:0x40
sleep 0.2
setpci -s "$BR" BRIDGE_CONTROL.w=0x00:0x40
sleep 1
echo "BRIDGE_CONTROL now 0x$(setpci -s "$BR" BRIDGE_CONTROL.w)"
"$HELPER" up
"$HELPER" status || true
echo "HOTRESET_DONE $DEV"
echo "next: fk33ctl.py seam on each node, then fk33_load_weights.py load <manifest> --verify for $DEV"
