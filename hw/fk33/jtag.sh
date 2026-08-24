#!/usr/bin/env bash
# Run a Vivado hardware-manager script against the FK33, recovering the cable first.
#
# Vivado batch runs leave two things behind that break the NEXT run:
#   * an hw_server process still holding the FTDI, so get_hw_targets returns
#     nothing and the error ("No matching targets found") looks like the card
#     lost power rather than like a stale lock;
#   * the FT2232 left in MPSSE mode with ftdi_sio detached from interface 0 and
#     never rebound, which libusb then will not reopen.
# A USBDEVFS_RESET fixes the second without unplugging anything, and needs no
# root because the device node is world-writable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
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
exec timeout "${JTAG_TIMEOUT:-420}" vivado -mode batch -nojournal \
     -log "${1%.tcl}.log" -source "$1"
