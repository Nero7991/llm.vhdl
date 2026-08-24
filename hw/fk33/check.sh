#!/usr/bin/env bash
# One-command FK33 bring-up check: recover the cable, configure the device,
# dump every SYSMON channel, scan the board I2C bus read-only.
#
#   ./check.sh            configure, then measure
#   ./check.sh --no-prog  measure only (device already configured)
#
# Configuration must go through xsdb; see tcl/program.tcl for why Vivado
# cannot do it on this ES1 die.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export FK33_BIT="$PWD/fk33_example/fk33_example.runs/impl_1/bd_wrapper.bit"

if [[ "${1:-}" != "--no-prog" ]]; then
    [[ -f "$FK33_BIT" ]] || { echo "BITSTREAM_MISSING $FK33_BIT" >&2; exit 1; }
    echo "=== configuring (xsdb) ==="
    pkill -f "[b]in/unwrapped/lnx64.o/hw_server" 2>/dev/null || true
    sleep 2
    source /tools/Xilinx/2023.2/Vitis/2023.2/settings64.sh
    timeout 300 xsdb tcl/program.tcl 2>&1 | grep -E "FPGA_PROG|xcvu33p|JTAG2AXI|Debug Hub"
fi

echo "=== telemetry (vivado) ==="
JTAG_TIMEOUT=900 ./jtag.sh tcl/telemetry.tcl 2>&1 | grep -vE "^# " | \
    sed -n '/^IDCODE/,/TELEMETRY_DONE/p'
