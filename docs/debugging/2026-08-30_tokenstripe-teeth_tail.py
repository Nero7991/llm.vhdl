#!/usr/bin/env python3
"""TRACK TOKENSTRIPE -- teeth for the lm-head TAIL of fk33_run_token.py.

The claim under test is NOT that `j.pieces` detects anything.  It is the
opposite: that it detects NOTHING, that its value is 405 bases made right, and
that the refusal the token path needs was ALREADY there before this change.

Arms:
  NEW    the working tree
  TOKPRE fk33_run_token.py at its last commit, everything else at HEAD

A row on which both arms refuse is a row an EXISTING property already covered,
and this change is credited with nothing on it.  Mutants are STRIPEPATH's,
targeting `output.weight.mv4i`, which is the tensor the tail actually reads."""
import copy
import json
import os
import subprocess
import sys

TS = "/mnt/storage/track-tokenstripe"
REPO = "/home/orencollaco/GitHub/llama.vhdl"
STRP = "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/manifest.json"
MODEL = os.path.dirname(STRP)
MUT = os.path.join(TS, "tailmut")
SEG = 268435456
LM = "output.weight.mv4i"
ARMS = [("NEW", REPO), ("TOKPRE", os.path.join(TS, "arm_TOKPRE"))]


def lm(m):
    return next(f for f in m["files"] if f["file"] == LM)


def T1(m):
    p = lm(m)["pieces"][2]
    p["hbm_offset"] += SEG
    p["segment"] += 1


def T2(m):
    lm(m)["pieces"][2]["hbm_offset"] += 1


def T3(m):
    e = lm(m)
    e["pieces"][3]["hbm_offset"] = e["pieces"][2]["hbm_offset"]
    e["pieces"][3]["segment"] = e["pieces"][2]["segment"]


def T4(m):
    lm(m)["pieces"][2]["segment"] = 31


def T7(m):
    del lm(m)["pieces"][2]


def T9(m):
    p = lm(m)["pieces"][2]
    p["hbm_offset"] = (1 << 32) - 524288
    p["segment"] = p["hbm_offset"] // SEG


def T10(m):
    e = lm(m)
    e["hbm_offset"] = e["pieces"][5]["hbm_offset"]


def T11(m):
    lm(m)["pieces"][2]["nbytes"] *= 2


def T12(m):
    """All 27 lane pieces of the lm-head into ONE pseudo-channel.  STRIPEPATH's
    hole: it is a structurally valid layout that defeats the whole point."""
    e = lm(m)
    base = e["pieces"][1]["hbm_offset"]
    off = 0
    for p in e["pieces"][1:]:
        p["hbm_offset"] = base + off
        p["segment"] = (base + off) // SEG
        off += int(p["nbytes"])


ROWS = [
    ("control", "the striped manifest, untouched", None),
    ("T1", "one lm-head piece moved a whole 256 MiB segment up", T1),
    ("T2", "one lm-head piece misaligned by 1 byte", T2),
    ("T3", "two lm-head pieces given the SAME address", T3),
    ("T4", "a piece's segment LABEL changed, address untouched", T4),
    ("T7", "one lm-head piece deleted from the list", T7),
    ("T9", "a piece straddling the 4 GiB HBM STACK boundary", T9),
    ("T10", "the object's hbm_offset points at piece 5, not the header", T10),
    ("T11", "one piece's nbytes doubled", T11),
    ("T12", "ALL 27 lm-head lanes into ONE pseudo-channel", T12),
]


def main():
    base = json.load(open(STRP))
    # THE TRAP THIS AVOIDS: `make_tail` opens `output.weight.mv4i` beside the
    # manifest, so a mutated manifest written into a bare scratch directory
    # makes EVERY row die on FileNotFoundError -- including the control, and a
    # column in which the control dies attributes nothing.  STRIPEPATH hit the
    # same shape with an incomplete symlink tree (its trap 5).  MUT is a full
    # symlink farm of the striped model with one real manifest.json.
    os.makedirs(MUT, exist_ok=True)
    for f in os.listdir(MODEL):
        if f == "manifest.json":
            continue
        d = os.path.join(MUT, f)
        if not os.path.lexists(d):
            os.symlink(os.path.join(MODEL, f), d)
    print("%-8s %-52s %s" % ("mutant", "what it does",
                             "  ".join("%-8s" % a for a, _ in ARMS)))
    tally = {a: 0 for a, _ in ARMS}
    for name, what, fn in ROWS:
        m = copy.deepcopy(base)
        if fn:
            fn(m)
        path = os.path.join(MUT, "manifest.json")
        with open(path, "w") as fp:
            json.dump(m, fp)
        cells = []
        for arm, repo in ARMS:
            env = dict(os.environ, TS_REPO=repo)
            p = subprocess.run(
                [sys.executable, os.path.join(TS, "tail_desc_dump.py"), path,
                 os.path.join(TS, "tailmut_out.json")],
                capture_output=True, text=True, env=env)
            killed = p.returncode != 0
            cells.append("KILL" if killed else "-")
            if killed and name != "control":
                tally[arm] += 1
        print("%-8s %-52s %s" % (name, what,
                                 "  ".join("%-8s" % c for c in cells)))
        os.remove(path)
    print("kills (control excluded): %s"
          % "  ".join("%s=%d" % (a, tally[a]) for a, _ in ARMS))
    print("INDEPENDENT kills earned by this change: %d"
          % (tally["NEW"] - tally["TOKPRE"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
