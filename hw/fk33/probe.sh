#!/usr/bin/env bash
# Configure the I2C-probe bitstream and characterise the BB24/BA24 balls.
#   ./probe.sh            configure, then probe
#   ./probe.sh --no-prog  probe only (already configured)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export FK33_BIT="$PWD/fk33_i2cprobe/fk33_i2cprobe.runs/impl_1/bd_wrapper.bit"
if [[ "${1:-}" != "--no-prog" ]]; then
    [[ -f "$FK33_BIT" ]] || { echo "BITSTREAM_MISSING $FK33_BIT" >&2; exit 1; }
    echo "=== configuring the PROBE bitstream (xsdb) ==="
    pkill -f "[b]in/unwrapped/lnx64.o/hw_server" 2>/dev/null || true
    sleep 2
    source /tools/Xilinx/2023.2/Vitis/2023.2/settings64.sh
    timeout 300 xsdb tcl/program.tcl 2>&1 | grep -E "FPGA_PROG|xcvu33p|JTAG2AXI"
fi
JTAG_TIMEOUT=600 ./jtag.sh tcl/i2cprobe.tcl 2>&1 | grep -vE "^# " | \
    sed -n '/bitstream identity check/,/PROBE_DONE/p'
