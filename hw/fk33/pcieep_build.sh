#!/usr/bin/env bash
# Build the PCIe Gen3 x4 XDMA endpoint bitstream for the FK33.
#
# Run this on a machine that is not doing anything else.  Vivado has OOM-killed
# this workstation before (see the DevOps notes on systemd-oomd taking the whole
# code-server cgroup); prefer the BC-250, or run under claude-tmux --mem.
#
# Expect ~1-1.5 h.  Nothing here touches the card.
#
#   ./pcieep_build.sh            full build, through to a bitstream
#   ./pcieep_build.sh --bd-only  block design, address map and validation only.
#                                MEASURED: about 3 minutes, 3.4 GB peak, no
#                                synthesis.  Run this after any edit to
#                                gen_pcieep.py -- it catches every class of
#                                error that is not a timing or placement
#                                result, at 1/20th of the cost.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BD_ONLY=0
[[ "${1:-}" == "--bd-only" ]] && BD_ONLY=1

BUILD_ROOT="${BUILD_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep}"

echo "=== regenerating the build script from the probe build ==="
python3 gen_i2cprobe.py
python3 gen_pcieep.py

# Board-free gates, cheapest first.  Each has caught something that would
# otherwise only surface at the far end of an hour-long build, or on the one
# afternoon the card is in the slot.
echo "=== board-free gates ==="
python3 check_pcieep_xdc.py
make -C host --no-print-directory check
./host/selftest_nocard.sh | tail -1

mkdir -p "$BUILD_ROOT"
cp build_fk33_pcieep.tcl "$BUILD_ROOT/"

echo "=== building in $BUILD_ROOT ==="
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$BUILD_ROOT"
if (( BD_ONLY )); then
    FK33_STOP_AFTER_BD=1 vivado -mode batch -nojournal -log build.log \
        -source build_fk33_pcieep.tcl 2>&1 | tee build.stdout
else
    vivado -mode batch -nojournal -log build.log -source build_fk33_pcieep.tcl \
        2>&1 | tee build.stdout
fi

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
echo "--- address map, read back from the tool rather than assumed ---"
grep -E "^FK33_MAP .*(xdma/M_AXI|fk33_)" build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
# BD 41-1377 is EXPECTED here and is NOT a fault.  32 of them are emitted
# during the 64-call exclude_seg_if sequence, while the HBM map is momentarily
# inconsistent, and none after it.  Counting them and demanding zero would fail
# every build forever.  The meaningful check is positional: nothing after the
# last exclude.  Full evidence in
# docs/debugging/2026-08-27_pcieep-bd-critical-warnings.md.
echo "--- address-overlap warnings AFTER the exclude sequence (must be zero) ---"
LAST_EXCL=$(grep -n "Excluding slave segment" build.log | tail -1 | cut -d: -f1)
if [[ -n "${LAST_EXCL:-}" ]]; then
    awk -v n="$LAST_EXCL" 'NR>n && /^CRITICAL WARNING: \[BD 41-1377\]/' build.log | \
        tee /dev/stderr | wc -l
else
    echo "  no exclude sequence found -- the HBM address map did not run"
fi

if (( BD_ONLY )); then
    grep -E "FK33_BD_VALIDATE|FK33_BD_ONLY_DONE" build.log || \
        { echo "BD CHECK DID NOT COMPLETE"; exit 1; }
    echo
    echo "Block design only.  Nothing was synthesised and no bitstream exists."
    exit 0
fi

[[ -f "$BIT" ]] && echo "BITSTREAM $BIT ($(stat -c %s "$BIT") bytes)" \
                || { echo "BITSTREAM_MISSING"; exit 1; }
echo
echo "Next: export FK33_BIT=$BIT  and run ./pcieep.sh"
