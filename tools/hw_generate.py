#!/usr/bin/env python3
"""hw_generate.py -- run the PL transformer on the AXU3EG and print the story.

Drives the llama_engine_axi core over the board's serial console (the Linux
side's networking on this board is intermittent; serial always works), reads the
generated token ids back over AXI, and detokenizes them on the host.

  usage:  python3 tools/hw_generate.py [-n N] [-p /dev/ttyUSB3] [--ids]

The engine is autonomous: START makes it teacher-force the SYNTHESIZED prompt
("Once upon a time" = ids 1,403,407,261,378) and then greedily generate to
NGEN=24 positions.  Greedy argmax + a baked prompt means every run produces the
SAME text -- see README/CLAUDE.md for what it takes to vary it.

Register map (base 0x80110000): 0x00 CTRL(w, bit0=START), 0x04 STATUS(b0=done),
0x08 COUNT, 0x20 ID=0x6C6C6D31, 0x40+4i TOKEN[i].
"""
import argparse
import os
import sys
import time

import serial

from detok import decode, load_vocab

BASE = 0x80110000
NGEN = 24


def sh(ser, cmd, timeout=45.0):
    """Run one shell command on the board, return its stdout."""
    sentinel = "ZZQ_DONE_ZZQ"
    ser.write(b"\r")
    ser.flush()
    time.sleep(0.3)
    ser.reset_input_buffer()
    ser.write((cmd + " ; echo " + sentinel + "\r").encode())
    ser.flush()
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            if buf.count(sentinel.encode()) >= 2:
                break
    text = buf.decode(errors="replace")
    return "\n".join(l for l in text.splitlines() if sentinel not in l)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--port", default="/dev/ttyUSB3")
    ap.add_argument("-n", "--ntok", type=int, default=NGEN,
                    help="how many of the generated tokens to show (max %d)" % NGEN)
    ap.add_argument("--ids", action="store_true", help="also print the raw token ids")
    args = ap.parse_args()

    ser = serial.Serial(args.port, 115200, timeout=0.2)
    ser.dtr = False
    ser.rts = False
    time.sleep(0.2)

    ident = sh(ser, "devmem 0x%08X" % (BASE + 0x20), 20)
    if "6C6C6D31" not in ident.upper():
        sys.exit("engine not found at 0x%08X (ID read: %r).\n"
                 "Is the llama bitstream loaded?  /tftpboot/system.bit.bin should be "
                 "the GOLDEN24 build." % (BASE + 0x20, ident.strip()))

    n = max(1, min(args.ntok, NGEN))
    idx = " ".join(str(i) for i in range(n))
    out = sh(ser,
             "devmem 0x%08X 32 1; sleep 16; "
             "printf 'CNT=%%s ' $(devmem 0x%08X); printf 'TOK:'; "
             "for i in %s; do printf ' %%d' $(devmem $((0x%08X+4*i))); done; echo"
             % (BASE + 0x00, BASE + 0x08, idx, BASE + 0x40),
             70)

    # The console echoes the command back, and that echo also contains "TOK:"
    # (plus the `for i in 0 1 2 ...` index list), so take the LAST occurrence and
    # stop at the end of that line -- the echo is never the last one.
    if "TOK:" not in out:
        sys.exit("no token readback from the board; raw console said:\n" + out)
    tail = out.split("TOK:")[-1].splitlines()[0]
    ids = [int(t) for t in tail.split() if t.lstrip("-").isdigit()]
    if len(ids) != n:
        sys.exit("expected %d tokens, parsed %d from %r\nfull console:\n%s"
                 % (n, len(ids), tail, out))

    words = load_vocab()
    # id 1 = BOS; the engine's stream starts at the first real token.
    story = decode([1] + ids, words)
    if args.ids:
        print("ids:", " ".join(str(i) for i in ids))
    print(story)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
