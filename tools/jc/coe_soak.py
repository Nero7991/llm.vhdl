"""Measure how long the Jungle Cat BMC keeps one CoE connection alive while it streams.

Sends only status-poll slots (nwords = 0, flags = 0: the loader writes nothing to HBM and
checks no sequence), keeps `depth` commands in flight like a real load, and prints when and
how the connection ended. Comparing a run at 27 MHz with one at 13.5 MHz separates the
causes of the ~290 s connection life measured on 2026-10-06: about the same time means a
timer; about twice the time means a byte or command count.

MAIN SESSION ONLY: this opens the JTAG path (USER4 on the chosen die, BYPASS elsewhere,
through the vetted CoE client).

  python3 tools/jc/coe_soak.py --bmc <ip> --die A --chain AB [--hz 13500000] [--max-secs 900]
"""
import argparse, time, sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from jc import jc_frame as F
from jc.coe_load import CoeTransport, status_of

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--bmc", required=True)
    p.add_argument("--die", required=True, choices=["A", "B"])
    p.add_argument("--chain", required=True, choices=["AB", "BA"])
    p.add_argument("--hz", type=int, default=27_000_000)
    p.add_argument("--max-secs", type=float, default=900.0)
    a = p.parse_args(argv)
    if not 0 < a.hz <= 27_000_000:
        p.error("--hz must be in (0, 27000000]")
    t = CoeTransport(a.bmc, a.die, a.chain, hz=a.hz)
    t.open_scan()
    poll = F.poll_slot()
    t0 = time.monotonic(); sent = got = bad = 0; last_print = t0
    why = "max-secs reached"
    try:
        while time.monotonic() - t0 < a.max_secs:
            while len(t.pending) < t.depth:
                t.send(poll); sent += 1
            tdo = t.recv(); got += 1
            if got % 2000 == 0:
                st = status_of(tdo, t.status_offset)
                if st.get("magic") != F.MAGIC_STAT:
                    bad += 1
            now = time.monotonic()
            if now - last_print >= 30:
                print("JCSOAK_PROGRESS secs=%.0f slots=%d bytes=%d" % (now - t0, got, got * F.SLOT_BYTES), flush=True)
                last_print = now
    except BaseException as e:
        why = "%s: %s" % (type(e).__name__, e)
    dt = time.monotonic() - t0
    print("JCSOAK_END hz=%d secs=%.1f slots=%d bytes=%d commands=%d bad_magic=%d reason=%s"
          % (a.hz, dt, got, got * F.SLOT_BYTES, sent, bad, why), flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
