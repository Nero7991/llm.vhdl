#!/usr/bin/env python3
"""Exhaustive BFS deriving CoE.resync()'s fixed TMS sequence (fix round 2, item 2).

Property required (review, 2026-10-05): a single TMS bit sequence, applied with TDI
held at 1 throughout, that is safe to send from EVERY one of the TAP's 16 possible
starting states -- "safe" meaning it never transitions into Update-IR while fewer than
24 bits are known to have been freshly shifted into the (24-bit, two-device) IR shift
register during this sequence, and it ends with every starting hypothesis parked in the
SAME state, Run-Test/Idle (so a caller -- ir_scan, ir_shift_all_ones -- can rely on a
single precondition after resync() returns).

Model, deliberately conservative (never credits any pre-resync shifting, so it cannot
be fooled by a shift session that was already partway through when resync() was
called): track, for each of the 16 starting hypotheses, (tap_state, ones) where `ones`
saturates at 24 and increments by 1 on every TMS=0 self-loop taken WHILE ALREADY in
Shift-IR (TDI=1 shifts a fresh '1' into the register each such cycle), is held
unchanged while parked in Exit1-IR/Pause-IR/Exit2-IR (the register does not shift
there, only Shift-IR does), and is reset to 0 on every arrival at Shift-IR via
Capture-IR (redundant under this conservative model -- it is never credited above 0
before a full fresh 24-cycle dwell regardless -- kept explicit for clarity; arrival via
Exit2-IR instead PRESERVES the running count, since no data was lost holding there).
All 16 hypotheses advance in lockstep on each chosen bit (it is ONE physical TMS line);
a bit is rejected immediately if it would drive ANY hypothesis into Update-IR with
ones < 24 -- that transition is the latch the review is closing, so the search must
never take it, not even transiently.

Run directly: prints the derived sequence and its length, and a line confirming every
one of the 16 starting hypotheses reaches Run-Test/Idle with no unsafe Update-IR visit.
`tools/jc/test_coe.py::test_resync_sequence_is_derived_safely` replays the same model
against the committed `coe._RESYNC_TMS` and must agree with this script's output.
"""
import sys
sys.path.insert(0, "/home/orencollaco/GitHub/llama.vhdl/tools")
from jc import coe
from collections import deque

N_STATES = 16
TARGET = coe.RUN_TEST_IDLE

def step(hyp, bit):
    """hyp: tuple of 16 (tap, ones) pairs, one per starting hypothesis.
    Returns (new_hyp, ok); ok is False iff this bit is unsafe for at least one hypothesis."""
    out = []
    for tap, ones in hyp:
        new_ones = ones
        if tap == coe.SHIFT_IR and bit == 0:
            new_ones = min(24, ones + 1)
        new_tap = coe.TAP_NEXT[tap][bit]
        if new_tap == coe.UPDATE_IR and new_ones < 24:
            return None, False
        if new_tap == coe.SHIFT_IR and tap == coe.CAPTURE_IR:
            new_ones = 0
        out.append((new_tap, new_ones))
    return tuple(out), True

def search(max_len=80):
    start = tuple((s, 0) for s in range(N_STATES))
    seen = {start: ()}
    q = deque([start])
    while q:
        hyp = q.popleft()
        seq = seen[hyp]
        if all(tap == TARGET for tap, _ in hyp):
            return seq
        if len(seq) >= max_len:
            continue
        for bit in (0, 1):
            nxt, ok = step(hyp, bit)
            if ok and nxt not in seen:
                seen[nxt] = seq + (bit,)
                q.append(nxt)
    return None

def verify(seq):
    """Replays the sequence against all 16 start states with the same conservative
    model, independently of the search (a check on the search's own output)."""
    for s0 in range(N_STATES):
        hyp_tap, hyp_ones = s0, 0
        for bit in seq:
            new_ones = hyp_ones
            if hyp_tap == coe.SHIFT_IR and bit == 0:
                new_ones = min(24, hyp_ones + 1)
            new_tap = coe.TAP_NEXT[hyp_tap][bit]
            if new_tap == coe.UPDATE_IR and new_ones < 24:
                return False, s0, "unsafe Update-IR, ones=%d" % new_ones
            if new_tap == coe.SHIFT_IR and hyp_tap == coe.CAPTURE_IR:
                new_ones = 0
            hyp_tap, hyp_ones = new_tap, new_ones
        if hyp_tap != TARGET:
            return False, s0, "ended at state %d, not RUN_TEST_IDLE" % hyp_tap
    return True, None, None

if __name__ == "__main__":
    seq = search()
    if seq is None:
        print("NO SAFE SEQUENCE FOUND within max_len")
        sys.exit(1)
    ok, bad_s0, why = verify(seq)
    print("length", len(seq))
    print("sequence", list(seq))
    print("independent verify:", "OK" if ok else "FAILED start=%d %s" % (bad_s0, why))
    if not ok:
        sys.exit(1)
