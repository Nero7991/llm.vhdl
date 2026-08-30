#!/usr/bin/env python3
"""TRACK STRIPEREADY -- teeth for fk33_stripe_experiment.py, with attribution.

Eight mutants x four arms.  The arms exist because a kill is not evidence about
a NEW check unless an arm with that check REMOVED survives the same mutant --
this project has twice credited a change with detections an older property
already made (STRIPEPATH's OFF/PRE columns, TOKENSTRIPE's first table).

  NEW    the working tree
  NOG1   G1 removed: the manifest-shape rules (lane_stripe present, something
         actually striped, the control actually flat)
  NOG2C  G2's CENSUS rules removed: flat-is-one-channel, striped-is-many,
         at-most-N-lanes-per-channel.  The oracle that DERIVES the bases is
         left in
  NOG2O  G2's ORACLE refusal removed: the exact-key join of a sub-region's file
         offset onto a manifest piece.  The census rules are left in

Every arm is built by ANCHORED string replacement on the shipping file and the
build ABORTS if an anchor is not found.  A sed that matches nothing and reports
success is a recorded trap in this repo.

Two mutants are EXPECTED TO SURVIVE and are reported under their own names.
They measure this checker's resolution floor, which is the most useful column
in the table and the easiest one to delete.

Writes only into $STRIPEREADY_SCRATCH (default /mnt/storage/track-stripeready/
teeth), which is a farm of symlinks to the model dirs plus one manifest.json
per arm.  It never writes into a model directory.
"""
import copy
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "hw", "fk33", "host", "fk33_stripe_experiment.py")
SCRATCH = os.environ.get("STRIPEREADY_SCRATCH",
                         "/mnt/storage/track-stripeready/teeth")
FLAT = os.environ.get("STRIPEREADY_FLAT",
                      "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd")
STRP = os.environ.get("STRIPEREADY_STRIPED",
                      "/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped")
SEG = (8 << 30) // 32

# ---- the arms.  (name, [(anchor, replacement), ...]) -----------------------
G1_ANCHORS = [
    ('if "lane_stripe" not in sman.get("hbm", {}):', 'if False:'),
    ("if nstr == 0:", "if False:"),
    ("if nflat_str != 0:", "if False:"),
]
# G2's census family, at BOTH scopes.  G2 is the four measurement tensors and
# G2b is all 249; they are one rule read twice, so one arm disables both.  An
# arm that removed only the per-tensor half would still be killed by the
# whole-image half and would attribute nothing.
G2C_ANCHORS = [
    ('if cf["striped"]:', "if False:"),
    ('if len(cf["distinct"]) != 1:', "if False:"),
    ('if not cs["striped"]:', "if False:"),
    ('if len(cs["distinct"]) < MIN_STRIPED_SEGS:', "if False:"),
    ('if cs["maxlanes"] > MAX_LANES_PER_SEG:', "if False:"),
    ("if worst:", "if False:"),
]
# G2b ALONE removed, so a mutant that only the whole-image scope can see
# (M9: a collapsed tensor that this run does not measure) attributes to it.
G2B_ANCHORS = [("if worst:", "if False:")]
G2O_ANCHORS = [
    ("if o not in by_off:", "if False:"),
    ("bases.append(by_off[o])", "bases.append(by_off.get(o, 0))"),
]
ARMS = [("NEW", []), ("NOG1", G1_ANCHORS), ("NOG2C", G2C_ANCHORS),
        ("NOG2B", G2B_ANCHORS), ("NOG2O", G2O_ANCHORS)]


def build_arm(name, subs):
    src = open(SRC).read()
    for anchor, repl in subs:
        if src.count(anchor) != 1:
            sys.exit("arm %s: anchor %r occurs %d times in %s, expected 1.  "
                     "A replacement that matches nothing and reports success "
                     "is exactly the failure this check exists to prevent."
                     % (name, anchor, src.count(anchor), SRC))
        src = src.replace(anchor, repl)
    d = os.path.join(SCRATCH, "arm_" + name)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "fk33_stripe_experiment.py")
    with open(p, "w") as fp:
        fp.write(src)
    return p


# ---- farms ------------------------------------------------------------------

def farm(tag, model_dir, manifest_obj):
    d = os.path.join(SCRATCH, "farm_" + tag)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    for n in os.listdir(model_dir):
        if n == "manifest.json":
            continue
        os.symlink(os.path.join(model_dir, n), os.path.join(d, n))
    with open(os.path.join(d, "manifest.json"), "w") as fp:
        json.dump(manifest_obj, fp)
    return d


def load(p):
    with open(os.path.join(p, "manifest.json")) as fp:
        return json.load(fp)


# ---- the mutants ------------------------------------------------------------

def collapse_clean(sman, target):
    """T12 as a pure SAME-SIZE PERMUTATION -- the clean version.

    Each of `target`'s payload pieces that is not already in segment S swaps
    `hbm_offset` with a same-size piece of ANOTHER tensor that is.  Every
    address stays occupied by exactly one piece of exactly the same size, so no
    arena occupancy moves, nothing overlaps, no gap appears and the stack line
    is untouched.  MEASURED: hbm_map, check_hbm_stack, weights_residency,
    gen_layer_program --token and gen_lmhead_windows ALL return rc=0 on it.
    """
    m = copy.deepcopy(sman)
    byname = {f["file"]: f for f in m["files"]}
    tf = byname[target]
    sz = max(set(int(p["nbytes"]) for p in tf["pieces"]),
             key=lambda z: sum(1 for p in tf["pieces"] if int(p["nbytes"]) == z))
    pay = [p for p in tf["pieces"] if int(p["nbytes"]) == sz]
    S = int(pay[0]["hbm_offset"]) // SEG
    donors = [(f["file"], i)
              for f in m["files"] if f["file"] != target and f.get("pieces")
              for i, p in enumerate(f["pieces"])
              if int(p["hbm_offset"]) // SEG == S and int(p["nbytes"]) == sz]
    di = 0
    for p in pay:
        if int(p["hbm_offset"]) // SEG == S:
            continue
        if di >= len(donors):
            sys.exit("collapse_clean(%s): only %d same-size donors in segment "
                     "%d, need more" % (target, len(donors), S))
        fn, i = donors[di]
        di += 1
        q = byname[fn]["pieces"][i]
        p["hbm_offset"], q["hbm_offset"] = \
            int(q["hbm_offset"]), int(p["hbm_offset"])
        p["segment"] = int(p["hbm_offset"]) // SEG
        q["segment"] = int(q["hbm_offset"]) // SEG
    return m



def mutants(fman, sman, target):
    out = [("control", "the shipping pair, untouched", FLAT, STRP, False)]

    m = copy.deepcopy(sman)
    del m["hbm"]["lane_stripe"]
    out.append(("M1", "hbm.lane_stripe deleted", FLAT,
                farm("m1", STRP, m), True))

    m = copy.deepcopy(sman)
    for f in m["files"]:
        f.pop("pieces", None)
    out.append(("M2", "every `pieces` list removed", FLAT,
                farm("m2", STRP, m), True))

    out.append(("M3", "the FLAT manifest in the striped slot", FLAT, FLAT, True))
    out.append(("M4", "the STRIPED manifest in the flat slot", STRP, STRP, True))

    # T12, laid out so nothing overlaps: the defect striping exists to remove.
    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == target:
            pcs = sorted(f["pieces"], key=lambda p: int(p["file_offset"]))
            cur = int(pcs[0]["hbm_offset"]) // SEG * SEG
            for p in pcs:
                p["hbm_offset"] = cur
                p["segment"] = cur // SEG
                cur += (int(p["nbytes"]) + 4095) // 4096 * 4096
            f["hbm_offset"] = int(pcs[0]["hbm_offset"])
    out.append(("M5", "T12 collapsed onto the header's segment (OVERLAPS)",
                FLAT, farm("m5", STRP, m), True))

    # M5b IS THE ROW THAT MATTERS, and M5 above is the trap I hit first.
    # M5 rebases the pieces onto the segment its 4 KB HEADER piece lives in,
    # which is segment 0 -- where the f32 blob and the descriptor arena are --
    # so it OVERLAPS and `tools/hbm_map.py` and `tools/weights_residency.py`
    # catch it for a reason that has nothing to do with lane collapse.  A T12
    # that other properties catch anyway measures nothing about this check.
    m = collapse_clean(sman, target)
    out.append(("M5b", "T12 CLEAN: same-size permutation, nothing overlaps",
                FLAT, farm("m5b", STRP, m), True))

    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == target:
            f["pieces"][3]["file_offset"] = \
                int(f["pieces"][3]["file_offset"]) + 4096
    out.append(("M6", "a piece cut off the header's own 0x38 table", FLAT,
                farm("m6", STRP, m), True))

    # EXPECTED TO SURVIVE.  A piece moved to another 4 KB-aligned address
    # inside the segment its own lane already owns is a legal placement; a rule
    # that refused it would fail on a correct configuration.  STRIPEPATH's T5.
    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == target:
            p = f["pieces"][5]
            p["hbm_offset"] = int(p["hbm_offset"]) + 4096
    out.append(("M7", "a piece moved 4 KB INSIDE its own segment (EXPECT "
                "SURVIVE)", FLAT, farm("m7", STRP, m), False))

    # EXPECTED TO SURVIVE.  The census reads ADDRESS BITS [32:28] and never a
    # piece's `segment` LABEL, deliberately: PACKSTRIPE's T3 is the recorded
    # case of a check that counted the label and certified a layout it never
    # saw.  A label-only change must therefore be invisible HERE, and is caught
    # by tools/hbm_map.py's PIECES P5 instead.
    m = copy.deepcopy(sman)
    for f in m["files"]:
        if f["file"] == target:
            f["pieces"][7]["segment"] = 31
    out.append(("M8", "a piece's `segment` LABEL changed (EXPECT SURVIVE)",
                FLAT, farm("m8", STRP, m), False))
    # M9 IS THE ONE ONLY THE WHOLE-IMAGE SCOPE CAN SEE.  Same clean collapse,
    # applied to a tensor this run does NOT measure.  G2's four-tensor census
    # passes it; G2b's 249-tensor census does not.  Without this row G2b would
    # be credited with nothing and would look like decoration.
    off_target = "blk.5.ffn_up.weight.mv4i"
    out.append(("M9", "T12 CLEAN on a tensor this run does NOT measure",
                FLAT, farm("m9", STRP, collapse_clean(sman, off_target)), True))
    return out


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    fman, sman = load(FLAT), load(STRP)
    target = "blk.0.ffn_gate.weight.mv4i"
    arms = [(n, build_arm(n, s)) for n, s in ARMS]
    rows = mutants(fman, sman, target)

    print("TRACK STRIPEREADY teeth -- target %s" % target)
    print("%-8s %-52s %s" % ("mutant", "what it does",
                             "  ".join("%-6s" % n for n, _ in arms)))
    ok = True
    nok = 0
    tally = {n: 0 for n, _ in arms}
    for name, what, fdir, sdir, want_kill in rows:
        cells = []
        for an, path in arms:
            p = subprocess.run([sys.executable, path, "precheck",
                                "--flat", fdir, "--striped", sdir],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            killed = p.returncode != 0
            cells.append("KILL  " if killed else "--    ")
            if killed and name != "control":
                tally[an] += 1
        new_killed = cells[0].startswith("KILL")
        good = (new_killed == want_kill)
        ok = ok and good
        nok += 1 if good else 0
        print("%-8s %-52s %s   %s"
              % (name, what, "  ".join(cells), "ok" if good else "WRONG"))
    print("")
    print("kills per arm (control excluded): %s"
          % "  ".join("%s=%d" % (n, tally[n]) for n, _ in arms))
    print("rows behaving as designed: %d of %d" % (nok, len(rows)))
    print("TEETH: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
