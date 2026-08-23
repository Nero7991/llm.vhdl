#!/bin/bash
# hw/deploy_board.sh -- stage the subsystem A bitstream and boot image for the
# AXU3EG's TFTP boot path, then (optionally) reboot the board.
#
# HOW THIS BOARD BOOTS.  U-Boot's saved bootcmd TFTPs BOTH artifacts from this
# host on every power-on:
#
#   tftpboot 0x10000000 ${serverip}:system.bit.bin && fpga load 0 0x10000000 ${filesize}
#   tftpboot 0x10000000 ${serverip}:image.ub       && bootm 0x10000000
#
# So deploying is a file copy plus a reboot.  There is no SD card to swap and
# the bitstream is NOT inside image.ub -- the FIT carries only kernel, FDT and
# ramdisk.  `fpga load` wants the RAW bitstream, which is what bootgen's
# -process_bitstream bin emits; a .bit still has its header and would need
# `loadb` instead.
#
# THE ROOTFS IS A RAM INITRD.  Nothing written on the board survives a reboot,
# so the driver is pushed over ssh after each boot rather than installed.
#
# ROLLBACK is a copy in the other direction plus a reboot.  Both previous
# artifacts are kept; if a bad image.ub leaves the board unable to boot, U-Boot
# is still reachable on the serial console and re-fetches whatever is in
# /tftpboot at that moment.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIT="$REPO/hw/mv_bringup/mv_bringup.runs/impl_1/design_mv_wrapper.bit"
UB="$HOME/GitHub/zcu106-2023.2-axu3eg/images/linux/image.ub.patched"
STAMP="pre-mv-2026-08-23"
BOARD="${BOARD:-192.0.2.101}"

[ -f "$BIT" ] || { echo "no bitstream at $BIT -- run build_bringup.tcl all" >&2; exit 1; }
[ -f "$UB"  ] || { echo "no patched image at $UB -- run hw/patch_dtb.sh" >&2; exit 1; }

# ---------------------------------------------------------------- bitstream
export PATH="/tools/Xilinx/2023.2/Vivado/2023.2/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$BIT" "$WORK/design_mv_wrapper.bit"
cat > "$WORK/gen.bif" <<BIF
all:
{
  design_mv_wrapper.bit
}
BIF
( cd "$WORK" && bootgen -arch zynqmp -image gen.bif -process_bitstream bin -w on >/dev/null )
BIN="$WORK/design_mv_wrapper.bit.bin"
[ -s "$BIN" ] || { echo "bootgen produced no .bin" >&2; exit 1; }

# A raw bitstream for this part is a fixed size; a short file means bootgen
# half-ran and `fpga load` would configure the PL with garbage.
sz=$(stat -c %s "$BIN")
[ "$sz" -gt 5000000 ] || { echo "suspicious .bin size $sz" >&2; exit 1; }
echo "bitstream: $sz bytes  md5 $(md5sum "$BIN" | cut -d' ' -f1)"

# ------------------------------------------------------------------- stage
for f in system.bit.bin image.ub; do
  [ -f "/tftpboot/$f.$STAMP" ] || cp -a "/tftpboot/$f" "/tftpboot/$f.$STAMP"
done
cp -a "$BIN" /tftpboot/system.bit.bin
cp -a "$UB"  /tftpboot/image.ub
echo "staged:"
ls -l /tftpboot/system.bit.bin /tftpboot/image.ub | sed 's/^/  /'
echo "rollback: cp /tftpboot/system.bit.bin.$STAMP /tftpboot/system.bit.bin"
echo "          cp /tftpboot/image.ub.$STAMP       /tftpboot/image.ub"

[ "${1:-}" = "--reboot" ] || { echo "(not rebooting; pass --reboot)"; exit 0; }

echo "=== rebooting $BOARD at $(date +%T) ==="
sshpass -p root ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 "root@$BOARD" 'reboot' 2>/dev/null || true
# The board TFTPs 113 MB plus a 5.5 MB bitstream before the kernel even starts.
# Do not touch the serial console during this: a keystroke interrupts U-Boot
# autoboot and strands the board at the ZynqMP> prompt.
for i in $(seq 1 40); do
  sleep 10
  if ping -c1 -W1 "$BOARD" >/dev/null 2>&1 \
     && sshpass -p root ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 "root@$BOARD" true 2>/dev/null; then
    echo "board back at $(date +%T) after $((i*10))s"
    exit 0
  fi
done
echo "board did not come back within 400s -- check the serial console (/dev/ttyUSB0, 115200)" >&2
exit 1
