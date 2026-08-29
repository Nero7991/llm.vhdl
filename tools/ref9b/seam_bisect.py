#!/usr/bin/env python3
"""Find the FIRST seam at which two 9B streams diverge, and by how much.

NAMED seam_bisect.py, NOT bisect.py, AND THAT IS NOT COSMETIC.  A file called
bisect.py in this directory SHADOWS THE PYTHON STANDARD LIBRARY's `bisect`
module for every script run from here, and the failure surfaces far away: it
took down `random`, which took down `tempfile`, which took down Ubuntu's
apport excepthook, so an unrelated KeyError printed as an ImportError inside
the crash handler.  MEASURED 2026-08-29 while this tool was still called
bisect.py.

WHY A BISECT AND NOT A PASS/FAIL.  A pass/fail at the end of a token tells you
the card is wrong and nothing else; the whole cost of on-card numeric debugging
is in the "and nothing else".  This walks the seams in EXECUTION order and
reports the first one that moves, which is the only output that turns a wrong
token into a bounded search.

TWO MODES, and they answer different questions:

  --mode cross   two streams of DIFFERENT numeric kind (the fixed-point
                 reference against llama.cpp's float anchor, or against a
                 float simulation).  Comparison is by relative RMS, because
                 they CANNOT be bit-equal and pretending otherwise is how a
                 tolerance without a budget above it gets quoted as evidence.

                 A FLAT THRESHOLD IS USELESS HERE AND THE MEASUREMENT SAYS SO.
                 MEASURED 2026-08-29: the clean reference already sits at
                 rel_rms 0.105 against the anchor AT THE VERY FIRST SEAM, the
                 embedding, and 0.05 to 0.25 everywhere after.  That is the
                 INT4 weight format's own error, not a defect, so a flat
                 threshold either fires on all 491 seams or is set so high it
                 detects nothing.  The metric that IS informative is angular:
                 1-cos stays near 0.004 to 0.03 across all 32 layers and does
                 not compound.

                 So the real detector is --baseline: record the clean run's
                 per-seam profile once, then flag a seam whose error rises
                 ABOVE ITS OWN BASELINE by more than --factor.  That is a
                 tolerance with an error budget above it, which is the form
                 this project has repeatedly found to be the only useful one.

  --mode exact   two streams of the SAME kind (the reference against a GHDL or
                 hardware capture, both BFP16).  Comparison is bit-for-bit on
                 the mantissa array and the shared exponent, and the report
                 names the first differing ELEMENT index, not just the seam.
                 This is the mode that matters for bring-up; the tolerance mode
                 exists to validate the reference itself.

READING THE OUTPUT.  Every seam is downstream of every seam before it, so a
divergence at seam k makes every later seam meaningless.  The FIRST row of the
"diverged" list is the answer; the rest is context.  A run in which nothing
diverges prints the worst seam anyway, because "nothing exceeded the threshold"
and "the two streams agree" are not the same statement.
"""
import argparse
import sys

import numpy as np

import r9bs
from seam_map import SEAMS


def metrics(a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    d = a - b
    rms_b = float(np.sqrt((b * b).mean())) if b.size else 0.0
    rms_d = float(np.sqrt((d * d).mean())) if d.size else 0.0
    rel = rms_d / rms_b if rms_b > 0 else (0.0 if rms_d == 0 else float("inf"))
    i = int(np.argmax(np.abs(d))) if d.size else -1
    na = float(np.linalg.norm(a)) * float(np.linalg.norm(b))
    cos = float(a.dot(b) / na) if na > 0 else 1.0
    return dict(rel=rel, rms_d=rms_d, rms_b=rms_b,
                maxabs=float(np.abs(d).max()) if d.size else 0.0,
                at=i, cos=cos)


def load_baseline(path):
    base = {}
    with open(path) as fp:
        for line in fp:
            if line.startswith("#") or not line.strip():
                continue
            name, tok, rel, cos1 = line.split()
            base[(name, int(tok))] = (float(rel), float(cos1))
    return base


def cross(ref_path, anchor_path, tok, thresh, verbose,
          baseline=None, write_baseline=None, factor=3.0, floor=0.01):
    ref = r9bs.index(ref_path)
    anc = r9bs.index(anchor_path)
    base = load_baseline(baseline) if baseline else None
    rows, missing, diverged = [], [], []
    for rtl, node, off, ln in SEAMS:
        if node is None:
            # An RTL seam with no counterpart node in llama.cpp's graph --
            # TOKEN, the argmax, which is sampled outside the graph.  Not
            # "missing from the anchor": absent by construction.
            continue
        rk, ak = (rtl, tok), (node, tok)
        if rk not in ref:
            continue                        # a partial run stops early
        if ak not in anc:
            missing.append((rtl, node))
            continue
        a = ref[rk].value
        b = anc[ak].value
        b = b[off:off + ln] if ln else b[off:]
        if a.size != b.size:
            rows.append((rtl, node, dict(rel=float("inf"), rms_d=0, rms_b=0,
                                         maxabs=0, at=-1, cos=0),
                         "LENGTH %d vs %d" % (a.size, b.size)))
            diverged.append(rows[-1])
            continue
        m = metrics(a, b)
        note = ""
        if base is not None:
            bk = base.get((rtl, tok))
            if bk is None:
                note = "NO BASELINE"
                bad = False
            else:
                brel, bcos = bk
                # Two independent gates.  rel_rms catches a magnitude change; the
                # angular term catches a DIRECTION change that leaves the norm
                # alone, which is the shape a wrong permutation or a wrong head
                # mapping takes and which rel_rms alone under-reports.
                bad = (m["rel"] > factor * brel + floor or
                       (1.0 - m["cos"]) > factor * bcos + floor * floor)
                note = "base rel=%.4g" % brel
        else:
            bad = m["rel"] > thresh
        row = (rtl, node, m, note)
        rows.append(row)
        if bad:
            diverged.append(row)

    if write_baseline:
        with open(write_baseline, "w") as fp:
            fp.write("# clean-run profile: rtl_seam tok rel_rms 1-cos\n")
            for rtl, node, m, _ in rows:
                fp.write("%s %d %.9g %.9g\n" % (rtl, tok, m["rel"], 1.0 - m["cos"]))
        print("# wrote baseline %s (%d seams)" % (write_baseline, len(rows)))

    if base is not None:
        print("# cross-format compare, token %d, gate = baseline x %.3g + %.3g"
              % (tok, factor, floor))
    else:
        print("# cross-format compare, token %d, flat threshold rel_rms > %.4g "
              "(NOT a calibrated gate -- see --baseline)" % (tok, thresh))
    print("# %-16s %-26s %10s %10s %10s %9s" %
          ("rtl seam", "anchor node", "rel_rms", "max_abs", "1-cos", "at"))
    diverged_set = {id(r) for r in diverged}
    for row in rows:
        rtl, node, m, note = row
        flag = "  <== DIVERGES" if id(row) in diverged_set else ""
        if verbose or flag:
            print("  %-16s %-26s %10.4g %10.4g %10.3g %9d%s%s" %
                  (rtl, node, m["rel"], m["maxabs"], 1.0 - m["cos"], m["at"],
                   flag, ("  " + note) if note else ""))
    if missing:
        print("# %d seams had no counterpart in the anchor: %s" %
              (len(missing), ", ".join(n for _, n in missing[:6])))
    if diverged:
        rtl, node, m, note = diverged[0]
        print("\nFIRST DIVERGENCE: %s (anchor %s)  rel_rms=%.6g  max_abs=%.6g "
              "at element %d  1-cos=%.4g %s"
              % (rtl, node, m["rel"], m["maxabs"], m["at"], 1.0 - m["cos"], note))
        print("%d of %d seams over threshold." % (len(diverged), len(rows)))
        return 1
    if rows:
        worst = max(rows, key=lambda r: r[2]["rel"])
        print("\nNO SEAM OVER THRESHOLD.  Worst: %s rel_rms=%.6g (anchor %s)."
              % (worst[0], worst[2]["rel"], worst[1]))
        print("That is agreement to a tolerance, NOT bit-exactness.  "
              "See --mode exact for the claim that is.")
    return 0


def exact(a_path, b_path, tok, verbose):
    """Compare EVERY record the two streams have in common at this token.

    THE WALK IS NOT `seam_map.SEAMS`, AND THAT WAS A REAL DEFECT.  Until
    2026-08-29 this function iterated `SEAMS` and compared only the names that
    map knows.  `SEAMS` hardcodes the 9B attention interleave (attention at
    every fourth layer), so a capture at `ATTN_INT = 2` carries `R_QG-1`,
    `R_KIN-1` and `R_VIN-1`, which have no entry -- and those three seams were
    PRESENT IN BOTH STREAMS, MODELLED on the reference side, and never visited.
    MEASURED on `llama_top_seq_HEAD.r9bs`: 57 records per token present in
    both, 54 compared, verdict `54 seams identical, 0 differ`, which reads
    exactly like full coverage.  Only the opt-in `capture_to_r9bs --check-names`
    could catch it.

    So the walk is now over the INTERSECTION of the two streams, ordered by
    `SEAMS` where the map knows a name and by the reference stream's own file
    order after that, and the verdict states the compared count against the
    records present.  A checker that silently compares fewer things than it
    claims is the defect class this project keeps finding; the counts are the
    fix, and the ordering only decides which divergence is reported FIRST.
    """
    A = r9bs.index(a_path)
    B = r9bs.index(b_path)
    rank = {s[0]: i for i, s in enumerate(SEAMS)}

    # File order of the REFERENCE stream at this token, which is execution
    # order for every producer in this repository.  It is the tie-break for a
    # name `seam_map` does not know, and it is what puts such a name somewhere
    # deterministic rather than nowhere.
    a_names = [n for (n, t) in A if t == tok]
    a_pos = {n: i for i, n in enumerate(a_names)}
    b_names = [n for (n, t) in B if t == tok]

    both = [n for n in a_names if (n, tok) in B]
    both.sort(key=lambda n: (rank.get(n, len(rank)), a_pos[n]))

    only_a = [n for n in a_names if (n, tok) not in B]
    only_b = [n for n in b_names if (n, tok) not in A]
    unmapped = [n for n in both if n not in rank]

    first = None
    n_ok = n_bad = 0
    for rtl in both:
        k = (rtl, tok)
        ra, rb = A[k], B[k]
        if ra.kind != rb.kind:
            print("  %-16s KIND MISMATCH %d vs %d" % (rtl, ra.kind, rb.kind))
            n_bad += 1
            if first is None:
                first = (rtl, -1, "kind")
            continue
        bad_exp = (ra.exp != rb.exp)
        if ra.n != rb.n:
            n_bad += 1
            if first is None:
                first = (rtl, -1, "length %d vs %d" % (ra.n, rb.n))
            continue
        d = np.nonzero(ra.raw != rb.raw)[0]
        what = "mantissas" if ra.kind == r9bs.KIND_BFP16 else "values"
        if bad_exp or d.size:
            n_bad += 1
            i = int(d[0]) if d.size else -1
            if first is None:
                first = (rtl, i, "exp %d vs %d, %d of %d %s differ"
                         % (ra.exp, rb.exp, d.size, ra.n, what))
            if verbose:
                print("  %-16s exp %d/%d  %d/%d %s differ, first at %d"
                      % (rtl, ra.exp, rb.exp, d.size, ra.n, what, i))
        else:
            n_ok += 1
            if verbose:
                print("  %-16s exact (%d values, exp %d)" % (rtl, ra.n, ra.exp))

    # THE COVERAGE LINE IS PART OF THE VERDICT, NOT A FOOTNOTE.  `n_ok + n_bad`
    # is what was COMPARED; `len(a_names)` and `len(b_names)` are what each
    # stream CARRIES.  Printing only the first was how three seams per token
    # went missing without a word.
    print("# exact compare, token %d: %d seams identical, %d differ"
          % (tok, n_ok, n_bad))
    print("# coverage: compared %d of %d records present in BOTH streams; "
          "reference has %d, other has %d at this token"
          % (n_ok + n_bad, len(both), len(a_names), len(b_names)))
    if only_a or only_b:
        print("# %d record(s) are in ONE stream only and were NOT compared.  "
              "A clean verdict says nothing whatever about these:"
              % (len(only_a) + len(only_b)))
        for n in only_a[:12]:
            print("    only in %s: %s" % (a_path, n))
        for n in only_b[:12]:
            print("    only in %s: %s" % (b_path, n))
        if len(only_a) + len(only_b) > 24:
            print("    ... %d more" % (len(only_a) + len(only_b) - 24))
    if unmapped:
        # Compared here, but `--mode cross` still walks SEAMS and cannot see
        # them, and neither can anything else keyed on the map.
        print("# %d compared record(s) have no seam_map entry, so --mode cross "
              "and any map-keyed tool cannot compare them: %s"
              % (len(unmapped), ", ".join(unmapped[:8])))
    if first:
        print("\nFIRST DIVERGENCE: %s at element %d -- %s" % first)
        return 1
    print("\nEVERY COMPARED SEAM IS BIT-IDENTICAL (%d of %d present in both; "
          "%d record(s) present in only one stream were not compared)."
          % (n_ok, len(both), len(only_a) + len(only_b)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a", help="the reference stream")
    ap.add_argument("b", help="the stream under test (or the anchor)")
    ap.add_argument("--mode", choices=("cross", "exact"), default="cross")
    ap.add_argument("--tok", type=int, default=0)
    ap.add_argument("--thresh", type=float, default=0.05,
                    help="cross mode with no baseline: flat relative-RMS "
                         "threshold (default 0.05).  Uncalibrated: read the "
                         "module docstring before quoting a result from it.")
    ap.add_argument("--baseline", help="clean-run profile to gate against")
    ap.add_argument("--write-baseline", help="write this run's profile out")
    ap.add_argument("--factor", type=float, default=3.0,
                    help="a seam diverges when its error exceeds "
                         "factor * baseline + floor (default 3)")
    ap.add_argument("--floor", type=float, default=0.01)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    if a.mode == "cross":
        return cross(a.a, a.b, a.tok, a.thresh, a.verbose,
                     a.baseline, a.write_baseline, a.factor, a.floor)
    return exact(a.a, a.b, a.tok, a.verbose)


if __name__ == "__main__":
    sys.exit(main())
