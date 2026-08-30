#!/usr/bin/env python3
"""TRACK PIECES -- teeth for the four consumers' `pieces` handling.

Every row mutates the striped manifest's PIECE MODEL and asks four consumers
what they say.  A checker never shown to refuse has not been shown to work.

THE ATTRIBUTION CONTROL IS THE RIGHT-HAND COLUMNS, not the verdict.  Three arms
per mutant:

  NEW      everything this track added, on.
  P-OFF    `hbm_map.manifest_piece_fails()` neutered.  The per-piece REGIONS
           survive, so this separates "the region model caught it" from "one of
           the P1..P6 rules caught it".
  FLAT     `file_pieces()` forced back to one contiguous extent per object,
           i.e. the code as it stood before this track.  A kill that also
           appears here belonged to an OLDER property and this track may not
           claim it.

Rows that do NOT bite are printed under their own names.  They are the
resolution floor and they are the most useful line in the table.

No card, no /dev, no Vivado.  Everything below is in-memory except the four
`fk33_run_job.make_plan` rows, which read one .mv4i off disk.
"""
import copy
import json
import os
import sys

REPO = "/home/orencollaco/GitHub/llama.vhdl"
sys.path.insert(0, os.path.join(REPO, "tools"))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33", "host"))
import hbm_map as HM                                            # noqa: E402
import gen_mv4i_desc as G                                       # noqa: E402
import fk33_load_weights as LW                                  # noqa: E402

STRP = ("/mnt/storage/llama-models/qwen35-9b-mv4i-noembd-striped/"
        "manifest.json")
ROOT = os.path.dirname(STRP)
TARGET = "blk.0.ffn_gate.weight.mv4i"
SEG = 0x1000_0000

_ORIG_FILE_PIECES = HM.file_pieces
_ORIG_PIECE_FAILS = HM.manifest_piece_fails


def _flat_file_pieces(e):
    """`file_pieces()` as it did not exist: the pre-change contiguous model."""
    return [dict(index=0, kind="whole", lane=None, file_offset=0,
                 hbm_offset=int(e["hbm_offset"]), nbytes=int(e["nbytes"]),
                 segment=None, segment_declared=None)]


def arm(name):
    HM.file_pieces = _ORIG_FILE_PIECES
    HM.manifest_piece_fails = _ORIG_PIECE_FAILS
    if name == "P-OFF":
        HM.manifest_piece_fails = lambda mani: []
    elif name == "FLAT":
        HM.file_pieces = _flat_file_pieces
        HM.manifest_piece_fails = lambda mani: []


# ------------------------------------------------------------- the consumers
def c_hbm_map(mani):
    try:
        return HM.plan(copy.deepcopy(mani)).check()
    except SystemExit as e:
        return ["hbm_map refused: %s" % e]
    except Exception as e:                                # pragma: no cover
        return ["hbm_map raised %s: %s" % (type(e).__name__, e)]


def c_load_weights(mani):
    ents = LW.select(mani, None)
    try:
        bad = LW.preflight(mani, ents, ROOT, need_files=False)
    except Exception as e:
        return ["preflight raised %s: %s" % (type(e).__name__, e)]
    # Attribute inside the tool: its own per-extent checks vs the whole-map
    # verdict it borrows from hbm_map, which is already a column of its own.
    return [m for m in bad
            if not m.startswith(("WHOLE MAP:", "REGION BLOCK:"))]


def c_gen_desc(mani):
    e = next(x for x in mani["files"] if x["file"] == TARGET)
    try:
        h = G.Mv4iHeader(os.path.join(ROOT, TARGET))
        G.build_descriptor(h, int(e["hbm_offset"]), 100, -6,
                           pieces=G.piece_extents(e))
    except G.DescError as ex:
        return [str(ex)]
    except Exception as ex:
        return ["build_descriptor raised %s: %s" % (type(ex).__name__, ex)]
    return []


CONSUMERS = [("hbm_map", c_hbm_map),
             ("load_weights", c_load_weights),
             ("gen_desc", c_gen_desc)]


# ------------------------------------------------------------- the mutations
def tgt(m):
    return next(x for x in m["files"] if x["file"] == TARGET)


def M_control(m):
    return "the striped manifest, untouched"


def M1(m):
    tgt(m)["pieces"][1]["hbm_offset"] += SEG
    return "one weight piece moved a whole 256 MiB segment up"


def M2(m):
    tgt(m)["pieces"][1]["hbm_offset"] += 1
    return "one weight piece misaligned by 1 byte"


def M3(m):
    p = tgt(m)["pieces"]
    p[2]["hbm_offset"] = p[1]["hbm_offset"]
    return "two pieces of one tensor given the SAME address"


def M4(m):
    tgt(m)["pieces"][1]["segment"] = 31
    return "a piece's segment LABEL changed, its address untouched"


def M5(m):
    p = tgt(m)["pieces"][1]
    p["hbm_offset"] += 0x0C00_0000            # still inside its own segment
    return "a piece moved INSIDE its own segment's free tail"


def M6(m):
    tgt(m)["pieces"][1]["nbytes"] -= 4096
    return "one piece 4096 B short, so the pieces no longer tile the file"


def M7(m):
    p = tgt(m)["pieces"]
    p[1], p[2] = p[2], p[1]
    return "two pieces swapped in the list, file offsets non-monotonic"


def M8(m):
    e = tgt(m)
    e["hbm_offset"] = e["pieces"][5]["hbm_offset"]
    return "the object's hbm_offset points at piece 5, not the header"


def M9(m):
    e = tgt(m)
    e["stack"] = 1 - int(e["stack"])
    return "the object's declared stack flipped"


def M10(m):
    m["hbm"]["lane_stripe"]["segment_bytes"] //= 2
    return "the declared stripe granule halved to 128 MiB"


def M11(m):
    del tgt(m)["pieces"][1]
    return "one weight piece deleted from the list"


def M13(m):
    tgt(m)["pieces"][1]["nbytes"] = 4096
    return "a weight piece shrunk below the job's own read span"


def M14(m):
    p = tgt(m)["pieces"]
    p[1]["file_offset"] += 4096
    p[2]["file_offset"] += 4096
    p[1]["nbytes"] -= 4096
    return "a piece's file_offset shifted off the header's own 0x38 table"


def M12(m):
    a = tgt(m)["pieces"]
    b = next(x for x in m["files"]
             if x.get("pieces") and x["file"] != TARGET
             and x["M"] == tgt(m)["M"] and x["K"] == tgt(m)["K"])["pieces"]
    a[1]["hbm_offset"], b[1]["hbm_offset"] = b[1]["hbm_offset"], a[1]["hbm_offset"]
    return ("two tensors of the SAME shape swap one lane arena "
            "(PACKSTRIPE M9)")


MUTS = [("control", M_control), ("M1", M1), ("M2", M2), ("M3", M3),
        ("M4", M4), ("M5", M5), ("M6", M6), ("M7", M7), ("M8", M8),
        ("M9", M9), ("M10", M10), ("M11", M11), ("M13", M13), ("M14", M14),
        ("M12", M12)]


# ------------------------------------------ the fifth consumer, on real files
#
# `fk33_run_job.make_plan` is not in the table above because it builds the C
# oracle from ref/mv_fk33_tr and reads the 28 MB tensor, so it is run on a
# subset, from disk, in its own pass.  It is the one consumer whose check is
# CROSS-LANGUAGE, and the split base check is what this pass exercises.
RUNJOB_ROWS = ["control", "M1", "M3", "M6", "M11", "M13", "M14", "M5"]


def runjob_pass(base, scratch):
    import fk33_run_job as R
    out = []
    for name, fn in MUTS:
        if name not in RUNJOB_ROWS:
            continue
        m = copy.deepcopy(base)
        what = fn(m)
        d = os.path.join(scratch, name)
        os.makedirs(d, exist_ok=True)
        for e in m["files"]:
            src = os.path.realpath(os.path.join(ROOT, e["file"]))
            dst = os.path.join(d, e["file"])
            if not os.path.exists(dst):
                os.symlink(src, dst)
        mp = os.path.join(d, "manifest.json")
        with open(mp, "w") as fp:
            json.dump(m, fp)

        class A:
            pass
        a = A()
        a.mv4i = os.path.join(d, TARGET)
        a.manifest = mp
        a.rows = 100
        a.x_exp = -6
        a.out_mode = 0
        a.no_cb_load = False
        a.addr_w = 40
        a.slot = 0
        a.seed = 1
        a.xamp = None
        a.cc = "cc"
        scr = os.path.join(d, "scr")
        os.makedirs(scr, exist_ok=True)
        try:
            p = R.make_plan(a, scr)
            bad = [c for c in p["xchecks"] if not c[3]]
            if bad:
                out.append((name, what, "xcheck FAIL %d of %d: %s"
                            % (len(bad), len(p["xchecks"]),
                               ", ".join(c[0] for c in bad[:4]))))
            else:
                out.append((name, what, "-- SURVIVES -- %d of %d agree"
                            % (len(p["xchecks"]), len(p["xchecks"]))))
        except Exception as e:
            out.append((name, what, "REFUSED %s: %s"
                        % (type(e).__name__, str(e).split("\n")[0][:90])))
    return out


def main():
    base = json.load(open(STRP))
    print("teeth over %s" % STRP)
    print("  format   %r" % base["format"])
    print("  objects  %d, striped %d, extents %d"
          % (len(base["files"]),
             sum(1 for e in base["files"] if e.get("pieces")),
             sum(len(e.get("pieces") or [1]) for e in base["files"])))
    print("  target   %s" % TARGET)
    print()
    hdr = ("%-8s %-58s %-30s %-9s %-9s" %
           ("mutant", "what it does", "killed by (NEW)", "P-OFF", "FLAT"))
    print(hdr)
    print("-" * len(hdr))
    survivors = []
    rc = 0
    for name, fn in MUTS:
        rows = {}
        what = None
        for a in ("NEW", "P-OFF", "FLAT"):
            arm(a)
            m = copy.deepcopy(base)
            what = fn(m)
            hits = []
            for cname, c in CONSUMERS:
                out = c(m)
                if out:
                    hits.append(cname)
            rows[a] = hits
        arm("NEW")
        killed = ",".join(rows["NEW"]) or "-- SURVIVES --"
        print("%-8s %-58s %-30s %-9s %-9s"
              % (name, what[:58], killed,
                 ",".join(rows["P-OFF"]) or "none",
                 ",".join(rows["FLAT"]) or "none"))
        if name == "control":
            if rows["NEW"]:
                print("     CONTROL IS NOT CLEAN -- every row below is void: %r"
                      % rows["NEW"])
                rc = 1
        elif not rows["NEW"]:
            survivors.append((name, what))
    print()
    print("THE `FLAT` COLUMN CARRIES NO ATTRIBUTION AND IS PRINTED TO SAY SO.")
    print("  With `file_pieces()` forced back to one contiguous extent per")
    print("  object, the CONTROL dies too: the pre-change consumers refuse a")
    print("  v2 manifest wholesale (249 fictitious overlaps, PACKSTRIPE 7.1).")
    print("  A column in which every row including the control fails cannot")
    print("  tell an old property from a new one.  `P-OFF` is the arm that")
    print("  attributes, and it is the one to read.")
    print()
    print("SURVIVORS -- the resolution floor, named:")
    for n, w in survivors:
        print("  %-6s %s" % (n, w))
    if not survivors:
        print("  none")

    if "--runjob" in sys.argv:
        print()
        print("fk33_run_job.make_plan -- the CROSS-LANGUAGE consumer, on disk")
        for n, w, v in runjob_pass(base, "/mnt/storage/track-pieces/teeth"):
            print("  %-8s %-56s %s" % (n, w[:56], v))
    return rc


if __name__ == "__main__":
    sys.exit(main())
