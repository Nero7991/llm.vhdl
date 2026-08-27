#!/usr/bin/env bash
# Staged, read-only PCIe diagnosis for the FK33, cheapest and most diagnostic
# checks first.  Every stage states what it isolates.
#
# Run as a normal user; it will say which stages want root for full detail
# rather than demanding it.  It changes nothing.
#
#   ./fk33_pcie_check.sh              auto-detect the endpoint
#   FK33_BDF=0000:03:00.0 ./fk33_pcie_check.sh
#   FK33_RP=0000:00:1c.0  ./fk33_pcie_check.sh    root port, if not auto-found
set -uo pipefail

say () { printf '\n=== %s ===\n' "$*"; }
verdict () { printf '  %-6s %s\n' "$1" "$2"; }

# The slot the card has been seated in before is the free chipset x4 port
# 00:1c.0.  That is the default guess; override with FK33_RP.
RP="${FK33_RP:-0000:00:1c.0}"

say "STAGE 1  is anything there at all"
# Isolates: whether the FPGA presented a config space.  Nothing about DMA,
# nothing about the driver.  Two independent ways of naming the same device,
# because the vendor ID depends on what the bitstream was built with.
FOUND="$(lspci -Dnn | grep -iE 'xilinx|1e24:' || true)"
if [[ -n "$FOUND" ]]; then
    echo "$FOUND"
    BDF="${FK33_BDF:-$(echo "$FOUND" | head -1 | cut -d' ' -f1)}"
    verdict PASS "endpoint at $BDF"
else
    BDF="${FK33_BDF:-}"
    verdict FAIL "no Xilinx or 1e24 device in lspci"
    echo "  This alone does NOT tell you whether the link trained.  Go to stage 2:"
    echo "  the ROOT PORT reports link state even when nothing enumerates, and"
    echo "  that is what separates a physical-layer failure from a config-space"
    echo "  failure."
fi

say "STAGE 2  root port link state ($RP)"
# Isolates: the physical and data link layers, independently of whether any
# device answered configuration reads.  This is the single most diagnostic
# thing on the host and it works when stage 1 finds nothing.
if ! lspci -s "$RP" >/dev/null 2>&1; then
    verdict SKIP "no such root port; find it with: lspci -tv"
else
    if [[ $EUID -ne 0 ]]; then
        echo "  (LnkSta needs root for the full capability dump; re-run with sudo"
        echo "   for this stage only)"
    fi
    LNK="$(lspci -vvv -s "$RP" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|SltSta:' || true)"
    echo "${LNK:-  (no link capability lines readable)}"
    STA="$(echo "$LNK" | grep 'LnkSta:' || true)"
    case "$STA" in
        *"Width x0"*)
            verdict FAIL "width x0: LINK TRAINING FAILED"
            echo "  Nothing is on the other end electrically, or the FPGA is not"
            echo "  configured, or there is no reference clock.  Distinguish:"
            echo "    - LED 6 on the card shows user_lnk_up; if it never changes"
            echo "      state the endpoint block is not even out of reset"
            echo "    - JTAG: hw/fk33/pcieep.sh --check.  If its AXI-Lite read"
            echo "      SUCCEEDS the link is up and this reading is stale, so"
            echo "      rescan.  If it hangs, the two agree and the fault is"
            echo "      upstream of the fabric."
            ;;
        *"Width x4"*)  verdict PASS "width x4, as designed" ;;
        *"Width x1"*|*"Width x2"*)
            verdict WARN "link trained NARROWER than x4"
            echo "  Lanes 1-3 are not making it through.  On a bare slot that is"
            echo "  a solder or contact problem; through the MCIO adapters it is"
            echo "  the cable or the adapter's lane mapping.  Not a design fault."
            ;;
        *) verdict INFO "read LnkSta above by hand" ;;
    esac
    case "$STA" in
        *"2.5GT/s"*) echo "  NOTE: trained at Gen1.  A Gen3-capable link that settles at"
                     echo "        Gen1 is a signal-integrity result, not a config error." ;;
        *"5GT/s"*)   echo "  NOTE: trained at Gen2, not Gen3.  Same reading as above." ;;
        *"8GT/s"*)   echo "  Gen3, as designed." ;;
    esac
fi

if [[ -z "${BDF:-}" ]]; then
    echo
    echo "Stop here until stage 1 finds a device.  Recovery, in increasing order"
    echo "of disruption, all ROOT:"
    echo "  sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
    echo "  # secondary bus reset on the root port -- reasserts PERST# to the"
    echo "  # card, which resets the PCIe block.  It should NOT deconfigure the"
    echo "  # FPGA, because PERST lands on an ordinary I/O pin (BE24), not on"
    echo "  # PROG_B -- but that is inferred from the board file, not verified."
    echo "  # Re-check over JTAG afterwards that the bitstream is still loaded."
    echo "  sudo setpci -s $RP BRIDGE_CONTROL=40:40; sleep 1"
    echo "  sudo setpci -s $RP BRIDGE_CONTROL=00:40; sleep 1"
    echo "  sudo sh -c 'echo 1 > /sys/bus/pci/rescan'"
    exit 1
fi

say "STAGE 3  endpoint link and BARs ($BDF)"
# Isolates: whether the BIOS/kernel could actually allocate address space for
# the device.  A device that enumerates but gets no BAR is a resource problem,
# not a card problem, and the fix is in BIOS (Above 4G Decoding).
lspci -vvv -s "$BDF" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|Region [0-9]:|MaxPayload|Capabilities: \[.*MSI' || \
    echo "  (needs root for the full dump)"
for r in /sys/bus/pci/devices/$BDF/resource[0-9]; do
    [[ -e "$r" ]] || continue
    printf '  %s  %s bytes\n' "$(basename "$r")" "$(stat -c %s "$r")"
done
if grep -q . /sys/bus/pci/devices/$BDF/resource 2>/dev/null; then
    awk 'NR<=4 && $1!="0x0000000000000000" {printf "  BAR%d 0x%s .. 0x%s\n", NR-1, substr($1,3), substr($2,3)}' \
        /sys/bus/pci/devices/$BDF/resource
    verdict PASS "BARs assigned"
else
    verdict FAIL "no BAR resources"
    echo "  ROOT/BIOS: enable Above 4G Decoding.  The XDMA BARs are 64-bit"
    echo "  prefetchable and a 32-bit-only window can fail to place them."
fi

say "STAGE 4  driver bind"
# Isolates: purely a device-ID match question.  A bound driver with no engines
# is a different fault from no bind at all.
DRV="$(basename "$(readlink -f /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null || true)"
if [[ "$DRV" == "xdma" ]]; then
    verdict PASS "bound to xdma"
elif [[ -n "$DRV" && "$DRV" != "." ]]; then
    verdict WARN "bound to '$DRV', not xdma"
else
    verdict FAIL "no driver bound"
    ID="$(cat /sys/bus/pci/devices/$BDF/vendor 2>/dev/null) $(cat /sys/bus/pci/devices/$BDF/device 2>/dev/null)"
    echo "  The device IDs are ${ID//0x/}.  If the xdma module is loaded, this is"
    echo "  a match-table miss and nothing more.  ROOT:"
    echo "    echo \"${ID//0x/}\" | sudo tee /sys/bus/pci/drivers/xdma/new_id"
fi

say "STAGE 5  character devices"
# Isolates: whether the driver identified the DMA engines inside the device.
# Bind without engines means the driver reached config space but the AXI side
# is not responding, which points at the bitstream, not the link.
ls -l /dev/xdma* 2>/dev/null || verdict FAIL "no /dev/xdma* nodes"
if [[ -e /dev/xdma0_user ]]; then
    verdict PASS "/dev/xdma0_user present (AXI-Lite BAR reachable)"
fi
if [[ -e /dev/xdma0_h2c_0 && -e /dev/xdma0_c2h_0 ]]; then
    verdict PASS "H2C and C2H engines identified"
else
    verdict WARN "DMA engine nodes missing"
    echo "  dmesg | grep -i xdma  -- the probe log names each engine it finds."
fi

say "STAGE 6  kernel log"
dmesg 2>/dev/null | grep -iE 'xdma|pcieport.*'"${BDF##*:}"'|AER|Corrected error|Bus error' | tail -20 \
    || echo "  (dmesg needs root on this system: sudo dmesg | grep -i xdma)"

cat <<'EOF'

Next, once stages 1-5 pass:
    ./fk33ctl.py sysmon      MMIO only, no DMA.  Cross-check the die
                             temperature against what JTAG reported.
    ./fk33ctl.py selftest    4 KB DMA round trip through HBM.
    ./fk33ctl.py bench       throughput, which sets the cold-load time.
EOF
