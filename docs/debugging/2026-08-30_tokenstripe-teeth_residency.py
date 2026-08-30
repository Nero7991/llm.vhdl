#!/usr/bin/env python3
"""TRACK TOKENSTRIPE -- teeth for tools/weights_residency.py's gap ledger.

Arms, one per NEW rule so that each column attributes ONE check:
  NEW    the working tree
  NOGAP  NEW with the WHOLE gap ledger removed -- the outer attribution
  NOA1   NEW with the arena CONTAINMENT rule removed
  NOA2   NEW with the arena OCCUPANCY rule removed (the tail taken on trust)
  NOA3   NEW with the reserved-segment rule removed (any empty segment allowed)
  NOLIST NEW with the `stack_holes` LIST unread -- the old total-only semantic
  PRE    the file before this track

Every arm's CONTROL passes on both shipping manifests except PRE, whose control
dies on the striped one; that column therefore carries no attribution and is
printed to say so.  weights_residency never opens a .mv4i, so a mutated
manifest alone is a complete input."""
import copy
import json
import os
import subprocess
import sys

TS = "/mnt/storage/track-tokenstripe"
REPO = "/home/orencollaco/GitHub/llama.vhdl"
FLAT = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json"
STRP = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json"
MUT = os.path.join(TS, "mut")
ARMS = [("NEW", os.path.join(REPO, "tools/weights_residency.py"))] + [
    (n, os.path.join(TS, "arm_%s/tools/weights_residency.py" % n))
    for n in ("NOGAP", "NOA1", "NOA2", "NOA3", "NOLIST", "PRE")]
SEG = 268435456


def piece(m, tensor, idx):
    e = next(f for f in m["files"] if f["file"] == tensor)
    return e["pieces"][idx]


# ------------------------------------------------------------------ mutants
def R7(m):
    m["hbm"]["stack_hole_bytes"] = 0


def R12(m):
    m["hbm"]["stack_holes"][0]["offset"] += 4096


def R13(m):
    m["hbm"]["stack_holes"][0]["nbytes"] -= 4096


def R14(m):
    m["hbm"]["stack_holes"] = []


def _park(m, seg, fix_arena):
    """Move ONE piece into `seg`, keeping every OTHER declaration the manifest
    makes consistent around it -- the `segment` LABEL included, because
    `hbm_map`'s PIECES P5 rule compares the label to the address and would
    otherwise be the thing that kills the row.  With `fix_arena` the vacated
    arena's declared `bytes` is corrected too, which leaves the CONTAINMENT
    rule as the only thing in the program that can still see it."""
    top = {}
    for e in m["files"]:
        for i, x in enumerate(e.get("pieces") or []):
            sg = int(x["hbm_offset"]) // SEG
            end = int(x["hbm_offset"]) + int(x["nbytes"])
            if end > top.get(sg, (0, None, None))[0]:
                top[sg] = (end, e, i)
    _end, e, i = top[3]                     # the top piece of the segment 3 arena
    x = e["pieces"][i]
    x["hbm_offset"], x["segment"] = seg * SEG, seg
    if fix_arena:
        held = max(int(y["hbm_offset"]) + int(y["nbytes"])
                   for f in m["files"] for y in (f.get("pieces") or [])
                   if int(y["hbm_offset"]) // SEG == 3)
        a = next(z for z in m["hbm"]["lane_stripe"]["segments"]
                 if z["segment"] == 3)
        a["bytes"] = held - a["base"]


def S1a(m):
    _park(m, 16, False)


def S1b(m):
    """Segment 27 is where the GDN recurrent state lives, so `hbm_map` reports
    an OVERLAP and the `weights_end` rule reports the moved end.  Both predate
    this track: the ledger is credited with NOTHING on this row, and the row is
    kept to say which segments the older properties already cover."""
    _park(m, 27, False)


def S1c(m):
    _park(m, 16, True)


def S2a(m):
    m["hbm"]["lane_stripe"]["segments"][0]["bytes"] += 4096


def S2b(m):
    m["hbm"]["lane_stripe"]["segments"][0]["bytes"] -= 4096


def S3(m):
    m["hbm"]["lane_stripe"]["reserved_segments"] = [
        s for s in m["hbm"]["lane_stripe"]["reserved_segments"] if s != 16]


def S4(m):
    m["hbm"]["stack_hole_bytes"] = 4096


def S5(m):
    """Two SAME-SIZE pieces of one tensor exchanged.  Every extent identical.
    EXPECTED NOT TO BITE: this is an address ledger, not an identity check."""
    e = next(f for f in m["files"] if f["file"] == "blk.0.ffn_gate.weight.mv4i")
    a, b = e["pieces"][1], e["pieces"][2]
    assert a["nbytes"] == b["nbytes"], (a["nbytes"], b["nbytes"])
    a["hbm_offset"], b["hbm_offset"] = b["hbm_offset"], a["hbm_offset"]


def S6(m):
    """A piece's `segment` LABEL changed, its address untouched.  EXPECTED NOT
    TO BITE *by the ledger*: every rule above reads address bits.  It is killed
    by `hbm_map`'s PIECES P5, which is why NOGAP kills it too."""
    piece(m, "blk.0.ffn_gate.weight.mv4i", 2)["segment"] = 31


FLAT_ROWS = [
    ("control", "the flat manifest, untouched", None, False),
    ("R7", "hbm.stack_hole_bytes zeroed", R7, True),
    ("R12", "a stack_holes entry moved 4 KB up", R12, True),
    ("R13", "a stack_holes entry 4 KB short, the total left alone", R13, True),
    ("R14", "the stack_holes list emptied, the total left alone", R14, True),
]
STRP_ROWS = [
    ("control", "the striped manifest, untouched", None, False),
    ("S1a", "a piece moved into RESERVED segment 16", S1a, True),
    ("S1b", "a piece parked in RESERVED segment 27 (LEDGER EARNS NOTHING)",
     S1b, False),
    ("S1c", "the same, with the vacated arena's `bytes` corrected", S1c, True),
    ("S2a", "an arena's declared `bytes` 4 KB too large", S2a, True),
    ("S2b", "an arena's declared `bytes` 4 KB too small", S2b, True),
    ("S3", "segment 16 dropped from reserved_segments", S3, True),
    ("S4", "stack_hole_bytes 4096 with an empty stack_holes list", S4, True),
    ("S5", "two SAME-SIZE pieces swapped (EXPECTED NOT TO BITE)", S5, False),
    ("S6", "a piece's segment LABEL changed (EXPECTED NOT TO BITE)", S6, False),
]


def run(arm_path, mani):
    p = subprocess.run([sys.executable, arm_path, mani],
                       capture_output=True, text=True)
    return p.returncode, p.stdout


def table(base_path, rows, title):
    base = json.load(open(base_path))
    os.makedirs(MUT, exist_ok=True)
    print("\n%s" % title)
    print("%-8s %-52s %s" % ("mutant", "what it does",
                             "  ".join("%-8s" % a for a, _ in ARMS)))
    tally = {a: 0 for a, _ in ARMS}
    behaved = 0
    for name, what, fn, expect_kill in rows:
        m = copy.deepcopy(base)
        if fn:
            fn(m)
        path = os.path.join(MUT, "manifest_%s.json" % name)
        with open(path, "w") as fp:
            json.dump(m, fp)
        cells = []
        for arm, ap in ARMS:
            rc, _out = run(ap, path)
            killed = rc != 0
            cells.append("KILL" if killed else "-")
            if killed and name != "control":
                tally[arm] += 1
        # ATTRIBUTED TO THE LEDGER only when NEW kills and NOGAP -- the same
        # file with check_gap_accounting removed entirely -- survives.  A row
        # both kill is a row some OTHER property (hbm_map, the f32 rules) would
        # have caught anyway, and the ledger is credited with nothing on it.
        ledger = cells[0] == "KILL" and cells[1] != "KILL"
        ok = (ledger == expect_kill)
        behaved += ok
        print("%-8s %-52s %s   %s" % (
            name, what, "  ".join("%-8s" % c for c in cells),
            "ok" if ok else "*** UNEXPECTED ***"))
        os.remove(path)
    print("kills per arm (control excluded): %s"
          % "  ".join("%s=%d" % (a, tally[a]) for a, _ in ARMS))
    print("rows behaving as designed: %d of %d" % (behaved, len(rows)))
    return behaved == len(rows)


def main():
    ok = table(FLAT, FLAT_ROWS, "FLAT manifest (v1) -- the inherited rows plus the new list rules")
    ok &= table(STRP, STRP_ROWS, "STRIPED manifest (v2) -- the lane arena rules")
    print("\nTEETH: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
