#!/usr/bin/env python3
"""Decide whether an FK33 flash readback is a real backup or a failed read.

    ./check_flash_backup.py bit/fk33_factory_backup.mcs [--bin out.bin]

Exit 0 only if the file plausibly contains a Xilinx bitstream.

WHY THIS EXISTS
---------------
A readback that returns all 0xFF, or all 0x00, is a FAILED READ.  It is not an
empty flash and it is not an erased flash.  It produces a 32 MB file that
passes every "does it exist and is it non-empty" test and is worthless, and we
would only find out after erasing the thing it was supposed to protect.

This is the same class of trap already recorded in
docs/2026-08-28_fk33-first-fit-handoff.md section 5: a failed JTAG-AXI
transaction reports as -1, not as an error, so a script that string-compares
the result concludes "answered with the wrong value" when in fact nothing
answered at all.  A backup file is exactly that shape of lie.

WHAT A REAL XILINX BITSTREAM LOOKS LIKE IN FLASH
------------------------------------------------
Raw configuration data (the .bit file's header is NOT in flash) begins with
0xFF padding, then the bus-width detect pattern, then the sync word:

    FF FF ... FF   00 00 00 BB   11 22 00 44   FF FF FF FF   AA 99 55 66
                   ^bus width    ^bus width    ^pad          ^SYNC

The sync word 0xAA995566 is the load-bearing one: the configuration engine
hunts for it and nothing happens without it.  If it is absent from the whole
32 MB, whatever we read back is not a bitstream and must not be trusted as a
restore image.
"""

import argparse
import sys
from collections import Counter

SYNC = bytes.fromhex("AA995566")
BUSWIDTH = bytes.fromhex("000000BB")


def read_ihex(path):
    """Decode an Intel HEX (.mcs) file into a flat bytearray.

    Handles record types 00 (data), 01 (EOF), 02 (segment address) and
    04 (extended linear address).  Vivado emits 04 for anything over 64 KB.
    """
    data = bytearray()
    base = 0
    with open(path, "r") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or not line.startswith(":"):
                continue
            try:
                raw = bytes.fromhex(line[1:])
            except ValueError:
                raise SystemExit("line %d: not valid hex: %r" % (lineno, line[:32]))
            if len(raw) < 5:
                raise SystemExit("line %d: record too short" % lineno)
            count, addr_hi, addr_lo, rectype = raw[0], raw[1], raw[2], raw[3]
            payload = raw[4:4 + count]
            if (sum(raw) & 0xFF) != 0:
                raise SystemExit("line %d: checksum mismatch" % lineno)
            addr = (addr_hi << 8) | addr_lo
            if rectype == 0x00:
                off = base + addr
                if off + count > len(data):
                    data.extend(b"\xff" * (off + count - len(data)))
                data[off:off + count] = payload
            elif rectype == 0x01:
                break
            elif rectype == 0x04:
                base = int.from_bytes(payload, "big") << 16
            elif rectype == 0x02:
                base = int.from_bytes(payload, "big") << 4
            else:
                raise SystemExit("line %d: unhandled record type 0x%02X" % (lineno, rectype))
    return data


def load(path):
    if path.lower().endswith((".mcs", ".hex")):
        return read_ihex(path)
    with open(path, "rb") as fh:
        return bytearray(fh.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--bin", help="also write the decoded bytes here")
    ap.add_argument("--min-bytes", type=int, default=1 << 20,
                    help="reject anything smaller (default 1 MiB)")
    args = ap.parse_args()

    try:
        data = load(args.path)
    except FileNotFoundError:
        print("BACKUP_CHECK_FAIL: no such file: %s" % args.path)
        return 1

    n = len(data)
    print("  file        %s" % args.path)
    print("  decoded     %d bytes (%.2f MiB)" % (n, n / (1 << 20)))

    if n < args.min_bytes:
        print("BACKUP_CHECK_FAIL: only %d bytes decoded; a real readback of the"
              " 32 MB device is much larger." % n)
        return 1

    hist = Counter(data)
    ff = hist.get(0xFF, 0)
    zz = hist.get(0x00, 0)
    print("  0xFF bytes  %d (%.2f%%)" % (ff, 100.0 * ff / n))
    print("  0x00 bytes  %d (%.2f%%)" % (zz, 100.0 * zz / n))
    print("  distinct    %d byte values" % len(hist))

    if ff == n:
        print("BACKUP_CHECK_FAIL: the readback is entirely 0xFF.  That is a"
              " FAILED READ, not an empty flash.  Do not trust it and do not"
              " erase anything.")
        return 1
    if zz == n:
        print("BACKUP_CHECK_FAIL: the readback is entirely 0x00.  That is a"
              " FAILED READ (the flash is not driving the bus, or the"
              " programmer bitstream is not running).")
        return 1
    if len(hist) < 16:
        print("BACKUP_CHECK_FAIL: only %d distinct byte values in %d bytes."
              "  That is not a bitstream; it is a stuck bus." % (len(hist), n))
        return 1

    sync = data.find(SYNC)
    bw = data.find(BUSWIDTH)
    if sync < 0:
        print("BACKUP_CHECK_FAIL: the Xilinx sync word AA995566 does not appear"
              " anywhere in the readback.  Whatever this is, it is not a"
              " bitstream and cannot be used to restore the card.")
        return 1

    print("  sync word   AA995566 at offset 0x%06X" % sync)
    if bw >= 0:
        print("  bus width   000000BB at offset 0x%06X" % bw)
    print("  sync count  %d" % data.count(SYNC))

    # Where the image stops.  Everything above the last non-0xFF byte is
    # unwritten flash, so this estimates how much of the 32 MB the factory
    # actually uses.  Reported, not enforced: a golden/MultiBoot layout can
    # legitimately place a second image high in the device.
    tail = n
    while tail > 0 and data[tail - 1] == 0xFF:
        tail -= 1
    print("  last data   offset 0x%06X (%.2f MiB used)" % (tail, tail / (1 << 20)))

    if args.bin:
        with open(args.bin, "wb") as fh:
            fh.write(data)
        print("  decoded to  %s" % args.bin)

    print("BACKUP_CHECK_OK: this looks like a genuine flash image.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
