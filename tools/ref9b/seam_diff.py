#!/usr/bin/env python3
"""Exact, SET-COMPLETE comparison of two same-format seam streams.

WHY THIS EXISTS ALONGSIDE seam_bisect.py --mode exact, WHICH ALREADY COMPARES
TWO STREAMS.  `seam_bisect.exact` walks `seam_map.SEAMS` and does

    if k not in A or k not in B: continue

so a seam that is in BOTH files but not in the map is never compared and is
never mentioned.  The summary line counts only what it looked at.  That is
fine for the artefact seam_map was written for -- the real 9B model, whose
attention interval is 4 -- and it is WRONG for a simulation capture:
`sim/tb_llama_top_seq.vhd` runs `ATTN_INT = 2`, so its attention blocks are at
indices 1 and 3, its seams are named `R_QG-1`, `R_KIN-1`, ..., and seam_map
knows none of them because layer 1 of the real model is a GDN layer.  MEASURED
2026-08-29: `seam_bisect.py --mode exact` on two such captures compares 45 of
the 63 records and says "45 seams identical" without a word about the other 18.

So this file compares the SET, not a list: every record in either file is
accounted for, in one of four buckets, and a record present in only one file
is a DIFFERENCE and not an omission.  The order walked is the reference
stream's own file order, which is execution order for every producer here.

WHAT A CLEAN RESULT FROM THIS TOOL MEANS, STATED SO IT CANNOT BE OVERREAD.
Two captures agreeing is a CHARACTERISATION result: the machine computes the
same numbers it computed before.  It is not a correctness result and no amount
of it becomes one.  `tools/ref9b/vec_oracle.py` is the file in this directory
that compares against something other than the machine itself.

usage:
    seam_diff.py golden.r9bs suspect.r9bs [--tok N] [-v] [--max-report K]
    seam_diff.py golden.txt  suspect.txt   (a .txt is parsed as the capture
                                            text format, so no conversion step
                                            is needed to diff two captures)
"""
import argparse
import os
import sys

import numpy as np

import r9bs


def _load(path):
    """Return {(name, tok): Record} for a .r9bs, or for a capture .txt."""
    if path.endswith(".txt"):
        import tempfile
        import capture_to_r9bs
        fd, tmp = tempfile.mkstemp(suffix=".r9bs")
        os.close(fd)
        capture_to_r9bs.text_to_r9bs(path, tmp, check_names=False)
        try:
            return r9bs.index(tmp)
        finally:
            os.unlink(tmp)
    return r9bs.index(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("golden")
    ap.add_argument("suspect")
    ap.add_argument("--tok", type=int, default=None,
                    help="restrict to one token index (default: every token)")
    ap.add_argument("--max-report", type=int, default=6)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    A = _load(a.golden)
    B = _load(a.suspect)
    if a.tok is not None:
        A = {k: v for k, v in A.items() if k[1] == a.tok}
        B = {k: v for k, v in B.items() if k[1] == a.tok}

    # File order of the GOLDEN is execution order.  r9bs.index is a dict and
    # Python dicts preserve insertion order, so this is the stream's order and
    # not an alphabetical one -- which would put R_X-10 before R_X-2 and make
    # "the FIRST divergence" a lie.
    order = list(A.keys())
    only_a = [k for k in order if k not in B]
    only_b = [k for k in B if k not in A]

    same = 0
    diffs = []
    for k in order:
        if k not in B:
            continue
        ra, rb = A[k], B[k]
        if ra.kind != rb.kind:
            diffs.append((k, -1, "kind %d vs %d" % (ra.kind, rb.kind)))
        elif ra.n != rb.n:
            diffs.append((k, -1, "length %d vs %d" % (ra.n, rb.n)))
        elif ra.exp != rb.exp or not (ra.raw == rb.raw).all():
            d = np.nonzero(ra.raw != rb.raw)[0]
            i = int(d[0]) if d.size else -1
            worst = int(np.abs(ra.raw.astype(np.int64)
                               - rb.raw.astype(np.int64)).max()) if d.size else 0
            diffs.append((k, i,
                          "exp %d vs %d, %d of %d mantissas differ, "
                          "max |delta| %d" % (ra.exp, rb.exp, d.size, ra.n, worst)))
        else:
            same += 1
            if a.verbose:
                print("  %-16s tok %d  identical (%d values, exp %d)"
                      % (k[0], k[1], ra.n, ra.exp))

    print("# exact set compare: %d records in %s, %d in %s"
          % (len(A), a.golden, len(B), a.suspect))
    print("# %d identical, %d differ, %d only in the golden, %d only in the "
          "suspect" % (same, len(diffs), len(only_a), len(only_b)))
    for k in only_a[:a.max_report]:
        print("  MISSING FROM SUSPECT: %s tok %d" % k)
    for k in only_b[:a.max_report]:
        print("  EXTRA IN SUSPECT:     %s tok %d" % k)
    for (k, i, why) in diffs[:a.max_report]:
        print("  %-16s tok %d  first differing element %d -- %s"
              % (k[0], k[1], i, why))

    if only_a or only_b or diffs:
        if diffs:
            k, i, why = diffs[0]
            print("\nFIRST DIVERGENCE: %s tok %d at element %d -- %s"
                  % (k[0], k[1], i, why))
        else:
            print("\nNO VALUE DIFFERED, but the record SETS differ, which is "
                  "a difference: a seam that vanished is not a seam that "
                  "agreed.")
        return 1
    print("\nEVERY RECORD IN BOTH STREAMS IS BIT-IDENTICAL, AND THE RECORD "
          "SETS ARE EQUAL.")
    print("That is a characterisation result: the machine computes what it "
          "computed before.  It is not a statement that the numbers are "
          "right -- see tools/ref9b/vec_oracle.py for that claim.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
