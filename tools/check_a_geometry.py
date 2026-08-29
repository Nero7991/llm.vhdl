#!/usr/bin/env python3
"""Do all the places that state subsystem A's build geometry agree?

Four numbers now: ROWS_IF, MAXROWS_BFP, NPORTS_W and NPORTS_S.

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

NPORTS_W / NPORTS_S WERE ADDED 2026-08-29 BY TRACK SCHED-FIX, after exactly
the failure this file was written for happened again to the other two numbers.
Both schedule generators wrote `nsub_w = 29`, `nsub_s = 4` into descriptor
word 3 -- the superseded ROWS_IF=58 port budget, see
`docs/2026-08-27_weight-path-audit.md:459` -- while the build has run at
24 and 3 since ROWS_IF settled at 48.  `matvec_int4_desc_axi.vhd:695-698`
refuses a descriptor whose word 3 disagrees with the build, with EC_GEOM,
before `start`.  Nothing anywhere held the two together, so the pair sat wrong
for a fortnight and 311 of 311 A jobs in the token program carried it.

The numbers are stated in MORE places than ROWS_IF is, and two of them are
artefacts rather than source: `manifest.json`'s `geometry.nports_w` and every
packed `.mv4i` file's own header (`nports_w` at 0x1A, `n_scale_sub` at 0x34).
Those two are checked by `tools/dprog_oracle.py` against the emitted program,
which is the right place for them; this file covers the SOURCE sites, which is
what a tree without the 6.7 GB packed set can still check.

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

# The port counts.  A DIFFERENT site list, because the set of files that state
# NPORTS is not the set that states ROWS_IF -- `gen_mv4i_desc.py` writes them
# into every packed header and states neither of the other two, and
# `tb_mv4i_desc_image` states the other two and not these.  Merging the tables
# would mean inventing a pattern that matches nothing for four of the rows,
# and a pattern that matches nothing is how this file goes blind.
NPORT_SITES = [
    ("seq_tbl_pkg (the schedule)", "sim/seq_tbl_pkg.vhd",
     r"constant\s+A_NPORTS_W\s*:\s*natural\s*:=\s*(\d+)\s*;",
     r"constant\s+A_NPORTS_S\s*:\s*natural\s*:=\s*(\d+)\s*;"),
    ("matvec_int4_desc_axi (entity defaults)", "rtl/matvec_int4_desc_axi.vhd",
     r"\n\s*NPORTS_W\s*:\s*positive\s*:=\s*(\d+)\s*;",
     r"\n\s*NPORTS_S\s*:\s*positive\s*:=\s*(\d+)\s*;"),
    ("gen_fk33_engine.py (the build script)", "hw/fk33/gen_fk33_engine.py",
     r"\nNPORTS_W\s*=\s*(\d+)\b",
     r"\nNPORTS_S\s*=\s*(\d+)\b"),
    ("fk33_engine.vhd (the GENERATED instantiation)", "hw/fk33/rtl/fk33_engine.vhd",
     r"constant\s+NPORTS_W\s*:\s*positive\s*:=\s*(\d+)\s*;",
     r"constant\s+NPORTS_S\s*:\s*positive\s*:=\s*(\d+)\s*;"),
    ("gen_mv4i_desc.py (what every .mv4i header carries)",
     "tools/gen_mv4i_desc.py",
     r"FK33\s*=\s*dict\([^)]*?nports_w\s*=\s*(\d+)",
     r"FK33\s*=\s*dict\([^)]*?nports_s\s*=\s*(\d+)"),
]

# A LITERAL ON THE EMIT PATH IS THE FAILURE THIS FILE MISSED ONCE ALREADY.
# The two schedule generators now take nsub_w/nsub_s from A_NPORTS_W/A_NPORTS_S,
# and both read the encoded word back and assert it at elaboration.  Neither
# guard survives somebody writing a bare integer at the `mk_desc` call again,
# so that shape is refused here by inspection.  The VHDL half cannot do this:
# `nsub_w => 29` elaborates perfectly.
NO_LITERAL_NSUB = [
    ("sim/seq_tbl_pkg.vhd", r"nsub_w\s*=>\s*(\d+)"),
    ("sim/seq_tbl_pkg.vhd", r"nsub_s\s*=>\s*(\d+)"),
    ("sim/llama_sched_pkg.vhd", r"nsub_w\s*=>\s*(\d+)"),
    ("sim/llama_sched_pkg.vhd", r"nsub_s\s*=>\s*(\d+)"),
]


def collect(sites, name_a, name_b):
    """Both fields at every site, plus the misses, as two dicts and a list."""
    a, b, errs = {}, {}, []
    for label, path, pa, pb in sites:
        v, e = find(path, pa, name_a)
        if e:
            errs.append(e)
        else:
            a[label] = v
        v, e = find(path, pb, name_b)
        if e:
            errs.append(e)
        else:
            b[label] = v
    return a, b, errs


def table(title, sites, col_a, col_b, a, b):
    print(title)
    print("# %-50s %8s %12s" % ("site", col_a, col_b))
    for label, _p, _pa, _pb in sites:
        print("  %-50s %8s %12s"
              % (label, a.get(label, "?"), b.get(label, "?")))


def agree(name, d):
    """0 if every site agrees on `name`, 1 otherwise, printing the split."""
    vals = set(d.values())
    if len(vals) > 1:
        print("DISAGREEMENT on %s: %s" % (name, sorted(vals)))
        for k, v in sorted(d.items()):
            print("    %-50s %d" % (k, v))
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    rows, maxr, errs = collect(SITES, "ROWS_IF", "MAXROWS_BFP")
    npw, nps, errs2 = collect(NPORT_SITES, "NPORTS_W", "NPORTS_S")
    errs += errs2

    table("# subsystem A geometry, every site that states it",
          SITES, "ROWS_IF", "MAXROWS_BFP", rows, maxr)
    print()
    table("# subsystem A port counts, every site that states them",
          NPORT_SITES, "NPORTS_W", "NPORTS_S", npw, nps)

    rc = 0
    for e in errs:
        print("MISSING: " + e)
        rc = 1
    for name, d in (("ROWS_IF", rows), ("MAXROWS_BFP", maxr),
                    ("NPORTS_W", npw), ("NPORTS_S", nps)):
        rc |= agree(name, d)

    # The literal-on-the-emit-path guard.  Reported even when everything else
    # agrees, because a literal that happens to be RIGHT today is the state the
    # tree was in before 2026-08-29 and is the thing that silently goes stale.
    for path, pat in NO_LITERAL_NSUB:
        full = os.path.join(REPO, path)
        if not os.path.exists(full):
            print("MISSING: %s does not exist" % path)
            rc = 1
            continue
        hits = re.findall(pat, open(full).read())
        if hits:
            print("LITERAL nsub in %s: %s -- must be A_NPORTS_W / A_NPORTS_S, "
                  "or the elaboration read-back in build_table is checking a "
                  "number nothing holds to the build" % (path, sorted(set(hits))))
            rc = 1

    if rc == 0:
        print()
        print("# every site agrees: ROWS_IF = %d, MAXROWS_BFP = %d, "
              "NPORTS_W = %d, NPORTS_S = %d"
              % (next(iter(set(rows.values()))), next(iter(set(maxr.values()))),
                 next(iter(set(npw.values()))), next(iter(set(nps.values())))))
        print("# and no literal nsub_w/nsub_s survives on either schedule "
              "generator's emit path.")
        print("# NOTE this is a SOURCE SCRAPE, not an elaboration.  It cannot "
              "see a value computed at run time, and it goes blind if a "
              "declaration is reformatted -- which is why a missing match is "
              "an ERROR above and not a skip.  The elaboration-time and "
              "behavioural half of this question is sim/tb_a_geom.vhd; the "
              "packed model's own bytes are tools/dprog_oracle.py.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
