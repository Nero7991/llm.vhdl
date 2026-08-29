#!/usr/bin/env python3
"""check_token.py -- ONE automatic verdict on the quantity that decides a token.

WHY THIS EXISTS.  Until 2026-08-29 `ref/run9b.c` computed the argmax and
PRINTED it; the stream did not carry it.  So of the ~490 seams the 9B reference
emits, the ONE that actually decides the output was the only one whose
comparison was a human reading two terminals.  `ref/run9b.c` now writes a
`TOKEN` record (S32, exp 0, n = 1) and this script is the comparison.

WHAT IT COMPARES, AND WHY THE TWO KINDS OF ROW ARE LABELLED DIFFERENTLY.

  REPORTED   the file carries a `TOKEN` record.  That is the PRODUCER'S OWN
             argmax -- run9b's `argmax_first`, or, in a hardware or GHDL
             capture, `rtl/sampler_stream.vhd`'s running maximum.  Whether two
             REPORTED rows are two INDEPENDENT argmax implementations depends
             on which producers they are, and this script cannot tell: a card
             capture against run9b is two implementations, while run9b
             `--acts bfp` against run9b `--acts f32` is ONE implementation over
             two different logits vectors.  The second is still worth running
             (it says the activation format does not move the token) but it is
             not evidence about the argmax code.

  DERIVED    the file has no `TOKEN` record, so this script takes the argmax of
             its logits vector itself.  A DERIVED row IS A ROUND TRIP FOR THAT
             PRODUCER: it can never disagree with that producer's own logits,
             so it says nothing whatever about that producer's argmax code.
             It is still an oracle ACROSS producers, which is the whole point
             for the llama.cpp anchor -- `dump_llamacpp` sees only the graph,
             and sampling happens outside the graph, so the anchor HAS no
             argmax to report (tools/ref9b/seam_map.py:38-42).

So the load-bearing comparison this script makes today is
`run9b`'s REPORTED token against the anchor's DERIVED one: an INT4 fixed-point
model written here against llama.cpp's BF16 f32 graph written by somebody else.
That is the m7-mutant defence at the token.

WHAT AN ARGMAX AGREEMENT DOES NOT MEAN.  MEASURED at the scaled shape
(docs/debugging/2026-08-29_logits-seam-model.md section 5.7): argmax 101 at
11199, runner-up 120 at 10389, so the smallest single-element change that moves
the token was -811, about 0.198 of the logits' RMS -- while the LOGITS record
resolves ONE LSB.  Two producers agreeing on a token are therefore agreeing
about a decision with a MARGIN, not about their logits; every error below the
margin is invisible here and every error above it need not be.  So the margin
is printed for every row that carries a logits vector, in absolute terms and in
units of that vector's own RMS, and it is part of the verdict rather than a
footnote.  A comparison of the vectors themselves is `seam_bisect.py`.

THE TIE RULE IS REPORTED SEPARATELY because it is the part a second
implementation gets wrong silently.  `rtl/sampler_stream.vhd` seeds index 0 and
displaces only on a strict `>`, so the FIRST maximum wins; `run9b.c`'s
`argmax_first` and `bisect_scaled.py`'s do the same.  Wherever the top two
values are DISTINCT that rule is never reached, so agreement is not evidence
about it.  This script says `TIE` when it is reached and `distinct` when it is
not, so nobody can read an agreement as covering it.

Usage:
    python3 check_token.py A.r9bs B.r9bs [...]  [--tok N]... [--expect ID]...
    python3 check_token.py A.r9bs --mutate-token TOK=ID   # teeth: see below

Exit status: 0 if every stream agrees at every token position they share (and
matches every --expect), 1 otherwise.  A disagreement is a FAILURE, not a
warning: two rungs picking different tokens is the defect this whole directory
exists to find.
"""
import argparse
import sys

import numpy as np

import r9bs
from seam_map import SEAMS

# The anchor's node name for the logits comes from the map rather than from a
# second literal here, so a map change cannot leave this file quietly wrong.
_LOGIT_NAMES = ["LOGITS"] + [a for (r, a, _s, _x) in SEAMS
                             if r == "LOGITS" and a]


def argmax_first(v):
    """`rtl/sampler_stream.vhd`'s rule: index 0 is the seed, a later index
    displaces it only on a STRICT `>`, so the FIRST maximum wins on a tie.
    Written out rather than calling numpy.argmax so the tie rule is visible --
    numpy.argmax happens to agree, but agreeing by coincidence is not the same
    as stating the rule."""
    bi = 0
    for i in range(1, len(v)):
        if v[i] > v[bi]:
            bi = i
    return bi


class Row:
    __slots__ = ("path", "tok", "token", "how", "n", "top1", "top2",
                 "gap", "rms", "tied", "logit_name", "reported", "derived",
                 "selfbad")

    def __init__(self, path, tok):
        self.path, self.tok = path, tok
        self.token = self.how = self.logit_name = None
        self.n = self.top1 = self.top2 = self.gap = self.rms = None
        self.tied = None
        self.reported = self.derived = None
        self.selfbad = False


def scan(path):
    """path -> {tok: Row}.  One pass; a stream can be 250k floats per token.

    THE RECONCILIATION IS DELIBERATELY AFTER THE WALK, NOT INSIDE IT, and that
    is a defect this file already had.  The first version decided REPORTED vs
    DERIVED as each record arrived.  `ref/run9b.c` writes LOGITS and then
    TOKEN, so the logits set the row to DERIVED and the later TOKEN record
    overwrote it without ever re-checking -- and a mutation that moved the
    logits while leaving the TOKEN record alone (a producer disagreeing with
    ITSELF, which is exactly what a broken sampler looks like) passed silently.
    MEASURED: mutations T3 and T4 of tools/ref9b/mutate_token.py both survived
    the first version and both are killed now.  Record ORDER is not something a
    reader of a stream may assume.
    """
    rows = {}
    for rec in r9bs.read(path):
        if rec.name == "TOKEN":
            r = rows.setdefault(rec.tok, Row(path, rec.tok))
            if r.reported is not None:
                raise SystemExit("%s: two TOKEN records at token %d"
                                 % (path, rec.tok))
            r.reported = int(rec.raw[0])
        elif rec.name in _LOGIT_NAMES:
            r = rows.setdefault(rec.tok, Row(path, rec.tok))
            v = rec.value
            if r.logit_name is not None:
                raise SystemExit("%s: two logits records at token %d (%s and "
                                 "%s); this script cannot tell which decides"
                                 % (path, rec.tok, r.logit_name, rec.name))
            r.logit_name = rec.name
            r.n = len(v)
            i1 = argmax_first(v)
            r.top1 = float(v[i1])
            # The runner-up is the largest value at any OTHER index.  Masking
            # the winner rather than sorting keeps this O(n) on 248,320 values.
            w = v.copy()
            w[i1] = -np.inf
            i2 = int(np.argmax(w))
            r.top2 = float(w[i2])
            r.gap = r.top1 - r.top2
            r.rms = float(np.sqrt((v * v).mean()))
            r.tied = (r.gap == 0.0)
            r.derived = i1

    for t, r in sorted(rows.items()):
        if r.reported is not None:
            r.token, r.how = r.reported, "REPORTED"
            if r.derived is not None and r.derived != r.reported:
                # The producer's own argmax disagrees with its own logits.
                # That is a defect IN THAT PRODUCER, and no cross-stream
                # comparison would name it as such -- both streams could still
                # report the same token while one of them is not the argmax of
                # the vector it published.
                r.selfbad = True
                print("  !! %s tok %d: its TOKEN record says %d but the argmax "
                      "of its own %s is %d -- the producer disagrees with "
                      "ITSELF, so at most one of the two records is right"
                      % (path, t, r.reported, r.logit_name, r.derived))
        elif r.derived is not None:
            r.token, r.how = r.derived, "DERIVED"
    return rows


def main():
    ap = argparse.ArgumentParser(
        description="compare the decided token across .r9bs streams")
    ap.add_argument("streams", nargs="+")
    ap.add_argument("--tok", type=int, action="append",
                    help="restrict to these token positions (repeatable)")
    ap.add_argument("--expect", type=int, action="append",
                    help="the token id expected at position 0, 1, ... in "
                         "order (repeatable).  A stream missing that position "
                         "is an error, not a skip")
    ap.add_argument("--mutate-token", metavar="TOK=ID", action="append",
                    help="TEETH ONLY.  Override the first stream's reported "
                         "token at position TOK with ID, in memory, to show "
                         "this checker firing.  Never use it for a real run")
    a = ap.parse_args()

    per = {}
    for p in a.streams:
        per[p] = scan(p)

    mut = {}
    for m in (a.mutate_token or []):
        k, _, v = m.partition("=")
        mut[int(k)] = int(v)
    if mut:
        first = a.streams[0]
        for k, v in mut.items():
            if k in per[first]:
                print("  MUTATED %s tok %d: reported token %d -> %d"
                      % (first, k, per[first][k].token, v))
                per[first][k].token = v
                per[first][k].how = "REPORTED*"

    toks = sorted(set().union(*[set(d) for d in per.values()]))
    if a.tok:
        toks = [t for t in toks if t in set(a.tok)]
    if not toks:
        print("NO TOKEN OR LOGITS RECORD IN ANY STREAM -- nothing was "
              "compared.  An empty comparison is not a pass.")
        return 1

    bad = 0
    print("%-6s %-34s %-9s %-8s %-9s %-11s %-9s %s"
          % ("tok", "stream", "source", "token", "n", "gap", "gap/rms", "top2"))
    for t in toks:
        seen = []
        for p in a.streams:
            r = per[p].get(t)
            if r is None:
                print("%-6d %-34s %-9s %s" % (t, p[-34:], "-",
                      "ABSENT: no TOKEN and no logits record at this position"))
                continue
            seen.append(r)
            gap = "%.6g" % r.gap if r.gap is not None else "-"
            gr = "%.5f" % (r.gap / r.rms) if r.rms else "-"
            tie = " TIE (the first-max rule IS exercised here)" if r.tied else ""
            print("%-6d %-34s %-9s %-8d %-9s %-11s %-9s %s%s"
                  % (t, p[-34:], r.how, r.token,
                     str(r.n) if r.n is not None else "-", gap, gr,
                     ("%.6g" % r.top2) if r.top2 is not None else "-", tie))
        for r in seen:
            if r.selfbad:
                bad += 1
        ids = {r.token for r in seen}
        if len(seen) >= 2 and len(ids) > 1:
            print("  DISAGREEMENT at token position %d: %s"
                  % (t, ", ".join("%s=%d" % (r.path.split("/")[-1], r.token)
                                  for r in seen)))
            bad += 1
        if a.expect and t < len(a.expect):
            want = a.expect[t]
            for r in seen:
                if r.token != want:
                    print("  EXPECTED %d at position %d, %s reported %d"
                          % (want, t, r.path, r.token))
                    bad += 1

    # THE COVERAGE LINE IS PART OF THE VERDICT.  A checker that compared one
    # stream against nothing and printed a green line is the defect class this
    # directory keeps finding; seam_bisect.exact() had exactly it until
    # 2026-08-29.  So say how many streams were actually compared, and refuse
    # to call a single-stream run a pass.
    n_reported = sum(1 for d in per.values() for t, r in d.items()
                     if t in set(toks) and r.how
                     and r.how.startswith("REPORTED"))
    n_derived = sum(1 for d in per.values() for t, r in d.items()
                    if t in set(toks) and r.how == "DERIVED")
    print("# %d stream(s), %d token position(s); %d REPORTED row(s) (the "
          "producer's own argmax), %d DERIVED (this script's argmax over that "
          "producer's own logits -- a round trip for it)"
          % (len(a.streams), len(toks), n_reported, n_derived))
    if len(a.streams) < 2 and not a.expect:
        print("ONE STREAM AND NO --expect: nothing was compared against "
              "anything.  This is not a pass.")
        return 1
    if bad:
        print("TOKEN CHECK: FAIL (%d disagreement(s))" % bad)
        return 1
    print("EVERY STREAM DECIDES THE SAME TOKEN AT EVERY COMPARED POSITION.  "
          "That is an agreement about a decision with a margin, not about the "
          "logits; see the gap/rms column and use seam_bisect.py for the "
          "vectors.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
