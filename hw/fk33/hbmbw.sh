#!/usr/bin/env bash
# Program the HBM bandwidth bitstream and run the sweep.
#
# Configuration MUST go through xsdb, not the Vivado hardware manager: see
# tcl/program.tcl for the spurious ES1 revision check that blocks the Vivado
# path on this die.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
BW_ROOT="${BW_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/hbmbw}"
export FK33_BIT="$BW_ROOT/fk33_hbmbw/fk33_hbmbw.runs/impl_1/bd_wrapper.bit"
[[ -f "$FK33_BIT" ]] || { echo "BITSTREAM_MISSING $FK33_BIT" >&2; exit 1; }
echo "bitstream: $FK33_BIT ($(stat -c %s "$FK33_BIT") bytes, $(stat -c %y "$FK33_BIT" | cut -d. -f1))"

pkill -f "[b]in/unwrapped/lnx64.o/hw_server" 2>/dev/null || true
pkill -f "[b]in/unwrapped/lnx64.o/cs_server" 2>/dev/null || true
sleep 2
python3 - <<'PY'
import fcntl, os, re, subprocess
out = subprocess.run(['lsusb'], capture_output=True, text=True).stdout
m = re.search(r'Bus (\d+) Device (\d+): ID 0403:6010', out)
if not m:
    raise SystemExit('FK33 FTDI not present -- card powered?')
p = '/dev/bus/usb/%s/%s' % (m.group(1), m.group(2))
fd = os.open(p, os.O_WRONLY)
try:
    fcntl.ioctl(fd, ord('U') << 8 | 20, 0)   # USBDEVFS_RESET
finally:
    os.close(fd)
print('cable reset:', p)
PY
sleep 3
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
echo "=== configuring (xsdb) ==="
timeout 300 xsdb tcl/program.tcl 2>&1 | grep -E "FPGA_PROG|xcvu33p|JTAG2AXI|Debug Hub" || true
sleep 3
echo "=== sweep ==="
exec timeout "${JTAG_TIMEOUT:-600}" vivado -mode batch -nojournal -log tcl/hbmbw.log -source tcl/hbmbw.tcl
