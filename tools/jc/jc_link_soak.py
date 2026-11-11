#!/usr/bin/env python3
"""tools/jc/jc_link_soak.py -- spec 2026-11-04 section 4, silicon step 1: frames over the fitted
lane for SECONDS, counted by die B's deframer (plan Task 8 Step 2).

    jc_link_soak.py --sock S --a A --b B [--seconds 600] [--base 0x20000]

Die A runs one position (role A, host row, prompt [1]) and then holds frame 0 while it waits
for a token; the tool RESENDs that frame for SECONDS with RESEND_CAP at its maximum. Die B
(role B, MAX_NEW 1) consumed frame 0, so every resent frame that arrives intact is a STALE
frame (SEQPOS_BAD) and every corrupted one a CRC failure (jc_link_rx checks the CRC first).

ACCOUNTING (final fix pass 2026-11-11, Task 8 amendment): with no link-down, every frame gets
one verdict, except that a corruption of the framing itself can MERGE two frames into one
verdict (a lost tlast: the next frame's first beat lands where the CRC was due) or SPLIT one
frame into two (an early tlast: the tail is parsed from a header). Either costs at most one
verdict per CRC failure, so the tool requires |resends - (crc_fails + seqpos_bad)| <= crc_fails
and refuses anything wider. With a link-down the accounting is not checked (beats are lost).
Ends ^SOAK_PASS (0 CRC failures), ^SOAK_FER <rate> (failures measured), or ^SOAK_FAIL <why>.
Every unclean exit ABORTs both dies. A real run is the main session's or Oren's (a broker
client on the board); NO direct hardware access."""
import argparse, sys, time
import jc_loop as L


def accounting_ok(res, crc, sp, dn):
    """The verdicts close on the resends to within one per CRC failure (merge or split); not
    checked across a link-down."""
    return dn != 0 or abs(res - (crc + sp)) <= crc


def soak(a, A, B):
    n = A.rd("CAPS") & 0xFFFF
    for d in (A, B):
        if d.rd("STATUS") & 3 == L.S_RUN:
            print("soak: die %s was running; ABORT and wait" % d.name)
            L.abort_and_wait(d)
    L.setup(A, [1], 1, -1, 1, 1, 0xFFFFFFFF)
    L.setup(B, [1], 1, -1, 2, 2, 3)
    L.start(B)
    L.start(A)
    rows = L.row_source(argparse.Namespace(synthetic=True, mv4i=None))
    t0 = time.time()
    while not (A.rd("STATUS") & 8):                      # A: NEED_TOKEN, frame 0 sent and held
        if A.rd("STATUS") & 4:
            L.send_row(A, rows, n)
        if time.time() - t0 > 60:
            return "SOAK_FAIL die %s never reached NEED_TOKEN" % A.name
    t1 = time.time()
    while B.rd("FRAMES_GOOD") < 1 and time.time() - t1 < 10:
        pass
    if B.rd("FRAMES_GOOD") != 1:
        return ("SOAK_FAIL die %s did not take frame 0 (FRAMES_GOOD %d, CRC_FAILS %d)"
                % (B.name, B.rd("FRAMES_GOOD"), B.rd("CRC_FAILS")))
    t0, k = time.time(), 0
    while time.time() - t0 < a.seconds:
        L.resend(A)
        k += 1
        if k % 1000 == 0:
            print("soak: %d s, %d resends, crc_fails %d" % (time.time() - t0, A.rd("RESENDS"), B.rd("CRC_FAILS")))
    time.sleep(0.5)
    res, crc, sp, dn = A.rd("RESENDS"), B.rd("CRC_FAILS"), B.rd("SEQPOS_BAD"), B.rd("LINK_DOWNS")
    print("soak: resends %d crc_fails %d seqpos_bad %d link_downs %d over %d s" % (res, crc, sp, dn, a.seconds))
    if not accounting_ok(res, crc, sp, dn):
        return ("SOAK_FAIL accounting: resends %d vs crc_fails %d + seqpos_bad %d differs by more than "
                "crc_fails" % (res, crc, sp))
    if crc == 0 and dn == 0:
        return "SOAK_PASS frames=%d crc_fails=0 link_downs=0" % res
    return "SOAK_FER %.3g frames=%d crc_fails=%d link_downs=%d" % (crc / max(res, 1), res, crc, dn)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x20000)
    a = ap.parse_args(argv)
    try:
        br = L.Broker(a.sock)
        A, B = L.Die(br, a.a, a.base), L.Die(br, a.b, a.base)
    except OSError as e:
        print("SOAK_FAIL %s" % e)
        return 1
    try:
        line = soak(a, A, B)
    except (RuntimeError, OSError, ValueError, KeyError) as e:
        line = "SOAK_FAIL %s" % e
    finally:
        L.abort_all([A, B])          # A holds frame 0 waiting for a token: never leave it running
    print(line)
    return 0 if line.startswith(("SOAK_PASS", "SOAK_FER")) else 1


if __name__ == "__main__":
    sys.exit(main())
