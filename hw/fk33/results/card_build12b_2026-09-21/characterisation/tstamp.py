#!/usr/bin/env python3
# Timestamp every read() from stdin. One write per token from run_prompt --stream
# becomes one record: monotonic seconds, byte count. Tokens pass through to stdout.
import os, sys, time
out = open(sys.argv[1], "w")
t0 = time.monotonic()
n = 0
while True:
    b = os.read(0, 65536)
    if not b: break
    t = time.monotonic() - t0
    n += 1
    out.write("%.6f\t%d\n" % (t, len(b))); out.flush()
    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
out.write("# reads=%d\n" % n); out.close()
