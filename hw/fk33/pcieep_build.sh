#!/usr/bin/env bash
# Build the PCIe Gen3 x4 XDMA endpoint bitstream for the FK33.
#
# Run this on a machine that is not doing anything else.  Vivado has OOM-killed
# this workstation before (see the DevOps notes on systemd-oomd taking the whole
# code-server cgroup); prefer the BC-250, or run under claude-tmux --mem.
#
# Expect ~1-1.5 h.  Nothing here touches the card.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BUILD_ROOT="${BUILD_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep}"

echo "=== regenerating the build script from the probe build ==="
python3 gen_i2cprobe.py
python3 gen_pcieep.py

mkdir -p "$BUILD_ROOT"
cp build_fk33_pcieep.tcl "$BUILD_ROOT/"

echo "=== building in $BUILD_ROOT ==="
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$BUILD_ROOT"
vivado -mode batch -nojournal -log build.log -source build_fk33_pcieep.tcl \
    2>&1 | tee build.stdout

BIT="$BUILD_ROOT/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit"

echo
echo "=== things in the log that must be read, not assumed ==="
# Each of these is a way this build can succeed and still be wrong.
grep -E "FK33_PCIE_IDS" build.log || echo "  MISSING FK33_PCIE_IDS -- the device ID the driver has to match is unknown"
grep -E "FK33_LNKLED" build.log || echo "  MISSING FK33_LNKLED -- link LED status unknown"
grep -E "FK33_TIMING" build.log || echo "  MISSING FK33_TIMING"
grep -E "FK33_BITSTREAM" build.log || echo "  MISSING FK33_BITSTREAM"
echo "--- GT and PCIe placement (confirms the x4 link landed in quad 227) ---"
grep -iE "GTYE4_CHANNEL|GTYE4_COMMON|PCIE4C" fk33_pcieep_util.rpt 2>/dev/null || \
    echo "  no utilization report -- check the impl run"
echo "--- unmatched constraints (should be ZERO now; any is a real error) ---"
grep -c "12-584" build.log || true

[[ -f "$BIT" ]] && echo "BITSTREAM $BIT ($(stat -c %s "$BIT") bytes)" \
                || { echo "BITSTREAM_MISSING"; exit 1; }
echo
echo "Next: export FK33_BIT=$BIT  and run ./pcieep.sh"
