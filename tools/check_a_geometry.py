#!/usr/bin/env python3
"""Do all the places that state subsystem A's ROWS_IF and MAXROWS_BFP agree?

THE DEFECT CLASS.  TRACK TOKIO spent a whole track on ONE instance of it
(`80d3a61`): the schedule generator emitted a descriptor the descriptor plane
refuses, and nothing anywhere said so until the RTL was made the judge.  The
two numbers that decide it are stated FIVE times in this tree, in three
languages, with nothing connecting them:

  1. sim/seq_tbl_pkg.vhd            A_ROWS_IF / A_MAXROWS_BFP  (VHDL constants)
  2. rtl/matvec_int4_desc_axi.vhd   ROWS_IF / MAXROWS_BFP      (generic defaults)
  3. hw/fk33/gen_fk33_engine.py     ROWS_IF / MAXROWS_BFP      (Python literals)
  4. hw/fk33/rtl/fk33_engine.vhd    the GENERATED instantiation, which OVERRIDES
                                    (2) and is therefore what the card carries
  5. sim/tb_mv4i_desc_image.vhd     RI / MAXROWS_BFP           (bench generics)

`sim/tb_a_geom.vhd` checks 1 against 2, at elaboration and behaviourally, and
that is the pair a VHDL gate row can reach.  It CANNOT reach 3, because no
elaboration reads a Python literal, and 3 is the one that decides the build.
Hence this file.

WHY IT IS NOT A GATE ROW.  `sim/regress.sh` discovers rows from `sim/tb_*.vhd`
and its only non-VHDL hook runs a `ref/*.c` generator; `ref/**` belongs to
another track today, so wiring this in would mean editing a file this track
does not own.  Recorded as an open item rather than done badly.

Run it:  python3 tools/check_a_geometry.py [--verbose]
Exit 0 if every site agrees, 1 otherwise.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def find(path, pattern, what):
    """The single match of `pattern` in `path`, or a recorded miss.

    A pattern that stops matching is reported as MISSING and fails the check.
    A silent zero-match would turn this whole file into decoration the first
    time somebody reformats a declaration, which is the failure mode a
    source-scraping check has and an elaboration check does not.
    """
    full = os.path.join(REPO, path)
    if not os.path.exists(full):
        return None, "%s: file does not exist" % path
    with open(full) as fp:
        text = fp.read()
    m = re.findall(pattern, text)
    if len(m) != 1:
        return None, ("%s: %d matches for %s (expected exactly 1); the "
                      "declaration moved and this check has gone blind"
                      % (path, len(m), what))
    return int(m[0]), None


SITES = [
    # (label, path, rows_if pattern, maxrows pattern)
    ("seq_tbl_pkg (the schedule)", "sim/seq_tbl_pkg.vhd",
     r"constant\s+A_ROWS_IF\s*:\s*natural\s*:=\s*(\d+)\s*;",
     r"constant\s+A_MAXROWS_BFP\s*:\s*natural\s*:=\s*(\d+)\s*;"),
    ("matvec_int4_desc_axi (entity defaults)", "rtl/matvec_int4_desc_axi.vhd",
     r"\n\s*ROWS_IF\s*:\s*positive\s*:=\s*(\d+)\s*;",
     r"\n\s*MAXROWS_BFP\s*:\s*positive\s*:=\s*(\d+)\s*;"),
    ("gen_fk33_engine.py (the build script)", "hw/fk33/gen_fk33_engine.py",
     r"\nROWS_IF\s*=\s*(\d+)\b",
     r"\nMAXROWS_BFP\s*=\s*(\d+)\b"),
    ("fk33_engine.vhd (the GENERATED instantiation)", "hw/fk33/rtl/fk33_engine.vhd",
     r"constant\s+ROWS_IF\s*:\s*positive\s*:=\s*(\d+)\s*;",
     r"MAXROWS_BFP\s*=>\s*(\d+)\s*,"),
    ("tb_mv4i_desc_image (bench generics)", "sim/tb_mv4i_desc_image.vhd",
     r"\n\s*RI\s*:\s*positive\s*:=\s*(\d+)\s*;",
     r"\n\s*MAXROWS_BFP\s*:\s*positive\s*:=\s*(\d+)\s*;"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    rows, maxr, errs = {}, {}, []
    for label, path, rp, mp in SITES:
        r, e = find(path, rp, "ROWS_IF")
        if e:
            errs.append(e)
        else:
            rows[label] = r
        m, e = find(path, mp, "MAXROWS_BFP")
        if e:
            errs.append(e)
        else:
            maxr[label] = m

    print("# subsystem A geometry, every site that states it")
    print("# %-46s %8s %12s" % ("site", "ROWS_IF", "MAXROWS_BFP"))
    for label, path, _rp, _mp in SITES:
        print("  %-46s %8s %12s"
              % (label, rows.get(label, "?"), maxr.get(label, "?")))

    rc = 0
    for e in errs:
        print("MISSING: " + e)
        rc = 1
    for name, d in (("ROWS_IF", rows), ("MAXROWS_BFP", maxr)):
        vals = set(d.values())
        if len(vals) > 1:
            print("DISAGREEMENT on %s: %s" % (name, sorted(vals)))
            for k, v in sorted(d.items()):
                print("    %-46s %d" % (k, v))
            rc = 1
    if rc == 0:
        print("# every site agrees: ROWS_IF = %d, MAXROWS_BFP = %d"
              % (next(iter(set(rows.values()))), next(iter(set(maxr.values())))))
        print("# NOTE this is a SOURCE SCRAPE, not an elaboration.  It cannot "
              "see a value computed at run time, and it goes blind if a "
              "declaration is reformatted -- which is why a missing match is "
              "an ERROR above and not a skip.  The elaboration-time and "
              "behavioural half of this question is sim/tb_a_geom.vhd.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
