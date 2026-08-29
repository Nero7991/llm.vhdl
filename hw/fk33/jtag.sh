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
import fcntl, os, sys, glob

# Pick the FK33's FTDI by SERIAL, not by "first match in lsusb".
#
# WHY THIS EXISTS.  This block used to be:
#     m = re.search(r'Bus (\d+) Device (\d+): ID 0403:6010', out)
# re.search returns the FIRST match, so with the second FK33 attached
# (2026-08-29) every run reset whichever card enumerated first, no matter what
# FK33_TARGET said.  Measured: a backup correctly bound to 153300001366A at the
# Vivado layer printed `cable reset: /dev/bus/usb/001/010`, which is the OTHER
# card.  Benign here (USBDEVFS_RESET re-enumerates the FTDI bridge; it does not
# reconfigure the FPGA or touch flash) but it is the same defect class that
# tcl/target_select.tcl removed one layer up, and a reset landing on a card
# mid-JTAG would abort that card's transfer.
#
# Same rule as target_select.tcl: REFUSE RATHER THAN GUESS.  One FTDI, use it.
# More than one and no FK33_TARGET, abort and print the list.  No fallback to
# "the first one", because a fallback is what makes the hazard silent.
#
# sysfs rather than `lsusb -v`: iSerial via lsusb -v needs to open the device
# to read string descriptors, whereas /sys/bus/usb/devices/*/serial is a plain
# world-readable file, and it carries busnum/devnum alongside it.

def enumerate_ftdi():
    found = []
    for d in sorted(glob.glob('/sys/bus/usb/devices/*')):
        try:
            with open(os.path.join(d, 'idVendor')) as f:  vid = f.read().strip()
            with open(os.path.join(d, 'idProduct')) as f: pid = f.read().strip()
        except OSError:
            continue
        if (vid, pid) != ('0403', '6010'):
            continue
        def rd(n):
            try:
                with open(os.path.join(d, n)) as f: return f.read().strip()
            except OSError:
                return ''
        found.append({'serial': rd('serial'), 'bus': rd('busnum'),
                      'dev': rd('devnum'), 'path': d})
    return found

devs = enumerate_ftdi()
if not devs:
    raise SystemExit('FK33 FTDI not present -- card powered?')

want = os.environ.get('FK33_TARGET', '').strip()
if want:
    # MATCH IN BOTH DIRECTIONS.  sysfs reports the serial as '153300001366'
    # but the Vivado JTAG target name -- which is what FK33_TARGET is normally
    # set to -- is '153300001366A', with a trailing letter sysfs does not carry.
    # A one-directional `want in serial` matches NOTHING and refuses every run.
    # Caught by teeth-check before this shipped, not by reasoning about it.
    hits = [d for d in devs
            if d['serial'] and (want in d['serial'] or d['serial'] in want)]
    if len(hits) != 1:
        for d in devs:
            sys.stderr.write('    %s  bus %s dev %s\n' % (d['serial'], d['bus'], d['dev']))
        raise SystemExit('FK33_TARGET=%s matches %d of %d FTDI devices'
                         % (want, len(hits), len(devs)))
    devs = hits
elif len(devs) > 1:
    for d in devs:
        sys.stderr.write('    %s  bus %s dev %s\n' % (d['serial'], d['bus'], d['dev']))
    raise SystemExit('REFUSING TO GUESS: %d FK33 FTDI devices present and '
                     'FK33_TARGET is not set.' % len(devs))

d = devs[0]
p = '/dev/bus/usb/%s/%s' % (d['bus'].zfill(3), d['dev'].zfill(3))
# FK33_USB_NORESET=1 reports the selection and stops.  This exists so the
# selection rule can be teeth-checked without actually resetting a cable, which
# would abort any JTAG transfer in flight on that card.
if os.environ.get('FK33_USB_NORESET', '') not in ('', '0'):
    print('cable reset SKIPPED (FK33_USB_NORESET): would reset %s  (serial %s)'
          % (p, d['serial'] or 'unknown'))
    raise SystemExit(0)
fd = os.open(p, os.O_WRONLY)
try:
    fcntl.ioctl(fd, ord('U') << 8 | 20, 0)   # USBDEVFS_RESET
finally:
    os.close(fd)
print('cable reset: %s  (serial %s)' % (p, d['serial'] or 'unknown'))
PY
sleep 3
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
# `< /dev/null` for the same reason as in pcieep.sh's prog(): a batch tool
# that keeps a tty on stdin can block after its script finishes, and the
# timeout that catches it reports 124, which reads as a hang in the DESIGN
# rather than in the harness.  Vivado batch is better behaved than xsdb here,
# but the failure mode costs 7 minutes to observe and the redirect costs
# nothing.
exec timeout "${JTAG_TIMEOUT:-420}" vivado -mode batch -nojournal \
     -log "${1%.tcl}.log" -source "$1" < /dev/null
