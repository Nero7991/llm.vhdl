#!/usr/bin/env python3
"""logit_compare.py -- the token-0 LOGIT VECTOR, card against reference.

WHAT WAS ALREADY HERE AND IS NOT REPEATED.  `check_token.py` owns the
DECISION: the argmax, whether two producers agree on it, the MARGIN that
decision had (absolutely and in units of the vector's own RMS) and whether the
tie rule was reached.  `seam_bisect.py --mode exact` owns the same-format,
one-LSB, which-element comparison over the ~490 region seams.  This script owns
the one thing neither does: the WHOLE 248,320-element vector at token 0, on a
common scale, as a distribution rather than as a decision.

WHY TOKEN 0 AND NOTHING AFTER IT.  Greedy decoding makes position k+1 depend on
the card's own choice at position k.  Token-level agreement past token 0 is NOT
expected here (INT4 weights plus Q12 activations against a BF16 reference), so
the moment the two disagree they are no longer running the same sequence and a
vector comparison at position 1 is comparing two different inputs.  Token 0 is
the only position at which card and reference provably start from identical
state, so it is the only position this script will compare.

WHAT INT4 MAKES MEANINGFUL, AND WHAT IT MAKES DECORATION
--------------------------------------------------------
MEASURED and recorded in this directory's README: at the logits, the INT4
weight format alone costs **0.1252 relative RMS** against the BF16 anchor, and
the int16 BFP activation format a further 0.00313 on top of it.  So:

  MEANINGFUL
    * argmax agreement, and the MARGIN it had.  A decision, with a stated
      resolution; check_token.py prints it and this script defers to it.
    * the RANK the reference's argmax holds in the card's vector, and the
      converse.  Rank is invariant to every monotone rescaling, so it survives
      the one degree of freedom (the shared exponent) that the card's format
      has and the reference's does not.
    * TOP-K OVERLAP.  Same reason, and it degrades gracefully: k = 20 asks a
      question k = 1 cannot, namely whether the card's ordering is right in the
      neighbourhood where the decision was close.
    * RELATIVE RMS *AFTER* the best-fit scale is removed, read AGAINST the
      0.1252 baseline and not against zero.
    * PER-WINDOW statistics.  The 9B lm_head is 15 A jobs (rows 0, 17376,
      ... 243264; tools/gen_lmhead_windows.py owns the tiling).  A defect in
      one shard's base, its weights or its exponent is a per-window signal and
      is invisible in any whole-vector aggregate.
    * a pure ROTATION or a pure SCALE, which are reported by name because both
      are structural defects that an argmax comparison can miss entirely.

  NOT MEANINGFUL, AND PRINTED ONLY SO NOBODY QUOTES IT AS IF IT WERE
    * MAX ABSOLUTE DIFFERENCE against a flat threshold.  There is no threshold
      that both admits INT4 and excludes a defect: at 0.1252 relative RMS the
      largest single-element difference is a property of the quantiser.  It is
      printed WITH ITS INDEX because the index localises, not because the
      magnitude judges.
    * MAX RELATIVE DIFFERENCE per element.  A logit near zero makes the
      denominator near zero and the ratio unbounded; the floor used is stated
      on the line and the figure is still dominated by the smallest reference
      values rather than by the worst error.
    * RAW-SCALE statistics before the best-fit alpha is removed.  The card
      publishes `mant * 2^-exp` and the reference publishes a float; an
      exponent that is off by one makes every raw figure wrong by 2x and
      changes no decision.  The raw line exists to EXPOSE that case (alpha then
      reads exactly 2.0 and the scaled residual collapses), not to be quoted.
    * an absolute PEARSON r.  Two vectors dominated by the same large-magnitude
      structure correlate at 0.99 while disagreeing about every near tie.  The
      useful reading is a CHANGE in it against a recorded baseline.

  THIS SCRIPT THEREFORE HAS NO DEFAULT PASS/FAIL ON ANY MAGNITUDE.  The
  README's rule for `seam_bisect.py` -- "a flat threshold is meaningless in
  cross mode; always pass --baseline" -- applies here with more force, because
  there is exactly one seam and no per-seam profile to fall back on.  Gates are
  opt-in (`--require-argmax`, `--max-rel-rms-scaled`), and a run without one
  reports and exits 0.

WHAT AN ABSENT VECTOR MEANS, AND WHY IT IS NOT SILENCE
------------------------------------------------------
The bitstream that produced the first inference on 2026-09-20 is the v2 window
seam, which publishes the sampler's ARGMAX and its shared exponent and no
logits row at all (rtl/fk33_seam.vhd:91-94; pl_backend.c:1243 refuses one).
`run_prompt --dump-logits` on such a card writes LOGIT_EXP and TOKEN and no
LOGITS record.  Every vector section below then prints UNAVAILABLE and the
verdict says which measurement was not made.  A comparator that printed a pass
over a vector it never read is this project's most-recorded defect class, so
absence is reported in the verdict line, never skipped.

Usage:
    python3 logit_compare.py CARD.r9bs REF.r9bs [--tok N] [--topk 1,5,20]
                             [--require-argmax] [--max-rel-rms-scaled X]
                             [--no-windows]
    python3 logit_compare.py --selftest          # teeth; no model file needed
    python3 logit_compare.py --mutate KIND --in A.r9bs --out B.r9bs

Exit status:
    0  the comparison ran (and every opt-in gate passed)
    1  an opt-in gate failed (--require-argmax, --max-rel-rms-scaled)
    2  NOT MEASURED.  A file would not read, the two vectors are different
       lengths, or -- the case that matters on the shipping card -- one side
       carries no LOGITS record at all.  2 is never a comparison result and is
       deliberately NOT 0: a run that read no vector must not be quotable as a
       run that found no difference.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", ".."))
import r9bs                                                  # noqa: E402
# The .r9bs WRITER lives in capture_to_r9bs.py and this uses that one rather
# than packing the struct a third time.  The name is private to that module by
# convention only; a second copy of the record layout is the thing actually
# worth avoiding (seam_stream.h and r9bs.py are already two).
from capture_to_r9bs import _write_rec, MAGIC, VERSION_S32   # noqa: E402

LOGITS_NAME = "LOGITS"
TOKEN_NAME = "TOKEN"
EXP_NAME = "LOGIT_EXP"
# A PARTIAL VECTOR MUST CARRY ITS OWN COVERAGE, added by TRACK SMPWIN
# 2026-09-20.  `LOGITS_ROWS` is s32, n = 2: (row_start, n_rows).  A LOGITS
# record SHORTER than the reference's and WITHOUT this record is refused, not
# aligned at zero: "the first n rows" is an assumption, and a subset silently
# assumed to start at 0 produces a perfectly well-formed comparison of the
# wrong rows.
ROWS_NAME = "LOGITS_ROWS"
# Written by tools/ref9b/smpwin_sweep.py.  Recognised here ONLY so that a
# prefix-argmax sweep is named rather than reported as a generic absent
# vector: it is not a vector and no statistic in this file applies to it.
PREFIX_NAME = "SMP_PREFIX_ARGMAX"


# --------------------------------------------------------------- the windows
def lmhead_windows(n_vocab):
    """[(row_start, n_rows)] for the 9B lm_head, from the ONE derivation.

    tools/gen_lmhead_windows.py owns the rule (a window may begin only on a
    tile boundary, so the stride is floor(MAXROWS_BFP/ROWS_IF)*ROWS_IF =
    17,376, not MAXROWS_BFP).  Imported rather than restated; if the import
    fails -- a stripped tree, a different checkout -- this returns None and the
    per-window section says UNAVAILABLE instead of inventing a tiling."""
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "..", "tools"))
        import gen_lmhead_windows as W
        _, wins = W.plan(n_vocab, 48, 17408)
        return wins
    except Exception:
        return None


# ------------------------------------------------------------------ reading
class Side(object):
    """One stream's token-0 view: the vector (or None), the exponent, the
    producer's own TOKEN (or None)."""

    def __init__(self, path, tok):
        self.path = path
        self.tok = tok
        self.vec = None          # float64 values on the file's own scale
        self.raw = None          # the integer mantissas, where the kind has any
        self.exp = None
        self.kind = None
        self.token = None        # the producer's own argmax, if it reported one
        self.exp_record = None
        self.rows = None         # (row_start, n_rows) when the vector is partial
        self.prefix_sweep = False
        for rec in r9bs.read(path):
            if rec.tok != tok:
                continue
            if rec.name == ROWS_NAME and rec.n == 2:
                self.rows = (int(rec.raw[0]), int(rec.raw[1]))
            elif rec.name == PREFIX_NAME:
                self.prefix_sweep = True
            if rec.name == LOGITS_NAME:
                self.vec = rec.value
                self.raw = rec.raw
                self.exp = rec.exp
                self.kind = rec.kindname
            elif rec.name == TOKEN_NAME and rec.n == 1:
                self.token = int(rec.raw[0])
            elif rec.name == EXP_NAME and rec.n == 1:
                self.exp_record = int(rec.raw[0])

    def describe(self):
        if self.vec is None:
            extra = ""
            if self.prefix_sweep:
                extra = ("  [this file is a PREFIX-ARGMAX SWEEP, not a "
                         "vector; compare it with "
                         "tools/ref9b/smpwin_sweep.py compare]")
            return ("%s: NO %s record at tok %d (LOGIT_EXP %s, TOKEN %s)%s"
                    % (os.path.basename(self.path), LOGITS_NAME, self.tok,
                       self.exp_record, self.token, extra))
        cov = ""
        if self.rows is not None:
            cov = " rows [%d,%d)" % (self.rows[0], self.rows[0] + self.rows[1])
        return ("%s: %s n=%d%s kind=%s exp=%s rms=%.6g TOKEN=%s"
                % (os.path.basename(self.path), LOGITS_NAME, len(self.vec),
                   cov, self.kind, self.exp,
                   float(np.sqrt((self.vec * self.vec).mean())), self.token))


# --------------------------------------------------------------- statistics
def ranks_of(v, idx):
    """1-based rank of element `idx` when v is sorted descending.  Ties are
    counted STRICTLY: rank = 1 + #{j : v[j] > v[idx]}, so a tie for first
    reports rank 1 for both and the tie is visible in the count, not hidden by
    an arbitrary sort order."""
    return int(1 + np.count_nonzero(v > v[idx]))


def topk(v, k):
    if k >= len(v):
        return set(range(len(v)))
    part = np.argpartition(-v, k - 1)[:k]
    return set(int(i) for i in part)


def detect_shift(a, b, span=3):
    """Is `a` the reference ROTATED?  A lane-order or per-window base defect
    moves every value to a neighbouring index, which leaves the multiset
    identical, the argmax off by a constant, and every magnitude statistic
    looking like noise -- so it is worth naming.

    THE FIRST VERSION OF THIS TESTED `np.array_equal`, AND IT COULD NEVER
    FIRE.  MEASURED by this file's own selftest, 2026-09-20: the `rot1` row
    reported `rotation=None` while the vector WAS rotated, because the card
    side is `mant * 2^-exp` and the reference side is a float, so the two never
    match bit-for-bit whatever the alignment.  An exact test is the right
    instrument for a same-format comparison (that is seam_bisect.py --mode
    exact) and the wrong one here.  The test is therefore RELATIVE: a shift
    wins when its residual is at least 10x smaller than the aligned residual.
    The factor is stated rather than tuned -- INT4 costs 0.1252 relative RMS
    and a wrong alignment costs order 1, so the two are two decades apart and
    nothing between them is being resolved."""
    # NORMALISE BOTH TO UNIT RMS FIRST.  A best-fit alpha cannot be used here:
    # under a rotation the two vectors are uncorrelated, alpha collapses
    # towards zero and dividing by it explodes the card side.  RMS is defined
    # whatever the alignment.
    ra = float(np.sqrt((a * a).mean()))
    rb = float(np.sqrt((b * b).mean()))
    if ra == 0.0 or rb == 0.0:
        return None
    a, b = a / ra, b / rb
    denom = float(np.sqrt(((a - b) ** 2).mean()))
    if denom == 0.0:
        return None
    best, best_r = None, denom
    for s in range(-span, span + 1):
        if s == 0:
            continue
        r = float(np.sqrt(((a - np.roll(b, s)) ** 2).mean()))
        if r < best_r:
            best, best_r = s, r
    if best is not None and best_r * 10.0 < denom:
        return best
    return None


def compare(card, ref, ks=(1, 5, 20), want_windows=True, out=sys.stdout):
    """Returns (findings dict, structural_ok)."""
    f = {}
    print("CARD  %s" % card.describe(), file=out)
    print("REF   %s" % ref.describe(), file=out)

    # ---------------------------------------------------------- the decision
    f["token_card"] = card.token
    f["token_ref"] = ref.token
    if card.token is not None and ref.token is not None:
        f["token_agree"] = int(card.token == ref.token)
        print("TOKEN card %s, reference %s -- %s   (the MARGIN and the tie "
              "rule are check_token.py's; run it on the same two files)"
              % (card.token, ref.token,
                 "AGREE" if card.token == ref.token else "DISAGREE"), file=out)
    else:
        f["token_agree"] = None
        print("TOKEN one side reports none (card %s, reference %s); a DERIVED "
              "argmax is a round trip for its own producer, so it is taken "
              "below only from the vectors" % (card.token, ref.token), file=out)

    if card.vec is None or ref.vec is None:
        who = []
        if card.vec is None:
            who.append("card")
        if ref.vec is None:
            who.append("reference")
        print("VECTOR UNAVAILABLE: no %s record on the %s side.  Every "
              "statistic below is NOT MEASURED, which is not the same as "
              "agreement." % (LOGITS_NAME, " and the ".join(who)), file=out)
        f["vector"] = "UNAVAILABLE"
        # NOT OK, AND THE FIRST VERSION SAID OTHERWISE.  MEASURED 2026-09-20
        # against the SIMULATED v2 card: this returned True whenever EITHER
        # side had a vector, so a run with no card vector at all printed the
        # ordinary "the comparison ran" verdict and exited 0.  That is this
        # repository's "a checker that printed PASS over an object it never
        # read", reproduced by the author of the warning.  An absent vector is
        # a measurement that did not happen and the exit status has to say so.
        f["_ok"] = False
        return f, False

    # ------------------------------------------------------- PARTIAL VECTORS
    # A card that returns only PART of the row is a real future configuration
    # (a windowed DMA, a per-shard read-back), and the honest failure mode is
    # not "refuse everything" -- it is "report only what a subset supports".
    # The coverage must be DECLARED, never inferred from the length.
    subset = None
    n_full = len(ref.vec) if ref.rows is None else None
    if card.rows is not None:
        r0, nr = card.rows
        if nr != len(card.vec):
            print("STRUCTURAL: %s says %d rows and the %s record holds %d.  "
                  "A coverage claim that does not match its own payload "
                  "describes neither." % (ROWS_NAME, nr, LOGITS_NAME,
                                          len(card.vec)), file=out)
            f["vector"] = "ROWS_PAYLOAD_MISMATCH"
            return f, False
        if r0 < 0 or r0 + nr > len(ref.vec):
            print("STRUCTURAL: the card claims rows [%d,%d) and the reference "
                  "has %d.  The claimed rows are not inside the reference's "
                  "vocabulary." % (r0, r0 + nr, len(ref.vec)), file=out)
            f["vector"] = "ROWS_OUT_OF_RANGE"
            return f, False
        subset = (r0, nr)
    elif len(card.vec) != len(ref.vec):
        print("STRUCTURAL: card n=%d, reference n=%d, and the card carries no "
              "%s record.  Two vectors of different lengths are not two "
              "measurements of one quantity, and WHICH rows the shorter one "
              "covers is not recoverable from its length -- aligning it at "
              "row 0 would be a guess that produces a well-formed comparison "
              "of the wrong rows.  Nothing is compared."
              % (len(card.vec), len(ref.vec), ROWS_NAME), file=out)
        f["vector"] = "LENGTH_MISMATCH"
        return f, False

    if subset is not None:
        r0, nr = subset
        a, b = card.vec, ref.vec[r0:r0 + nr]
        n_full = len(ref.vec)
        print("SUBSET the card covers rows [%d,%d) of %d (%.2f%%).  Every "
              "figure below is over THOSE ROWS ONLY."
              % (r0, r0 + nr, n_full, 100.0 * nr / n_full), file=out)
        print("       NOT MEASURED, and not the same as agreement: the "
              "whole-vector argmax, its rank, whole-vector top-k, and any "
              "window the subset does not fully contain.", file=out)
        f["subset_row_start"], f["subset_n_rows"] = r0, nr
    else:
        a, b = card.vec, ref.vec
        n_full = len(ref.vec)
    n = len(a)
    f["vector"] = "present" if subset is None else "partial"
    f["_ok"] = True
    f["n"] = n
    f["n_full"] = n_full

    # ------------------------------------------------------------- structure
    sh = detect_shift(a, b)
    f["rotation"] = sh
    if sh is not None:
        print("ROTATION the card's vector is EXACTLY the reference rotated by "
              "%+d elements.  Every value is present and every INDEX is wrong; "
              "this is a lane-order or per-window base defect, not a numerical "
              "one." % sh, file=out)

    ia, ib = int(np.argmax(a)), int(np.argmax(b))
    off = subset[0] if subset else 0
    f["argmax_card_vec"], f["argmax_ref_vec"] = ia + off, ib + off
    f["rank_ref_in_card"] = ranks_of(a, ib)
    f["rank_card_in_ref"] = ranks_of(b, ia)
    if subset is None:
        f["argmax_vec_agree"] = int(ia == ib)
        print("ARGMAX(vector) card %d, reference %d -- %s" %
              (ia, ib, "agree" if ia == ib else "DISAGREE"), file=out)
        print("RANK  the reference's argmax is rank %d in the card's vector; "
              "the card's argmax is rank %d in the reference's.  (Rank "
              "survives any monotone rescaling, which is the card's one spare "
              "degree of freedom.)"
              % (f["rank_ref_in_card"], f["rank_card_in_ref"]), file=out)
    else:
        # A SUBSET CANNOT REPORT A WHOLE-VECTOR ARGMAX, and the field is left
        # None rather than filled with the local one: a caller reading
        # `argmax_vec_agree` must get "not measured", not a number that
        # happens to be about 7% of the vocabulary.
        f["argmax_vec_agree"] = None
        f["argmax_subset_agree"] = int(ia == ib)
        print("ARGMAX(subset) card row %d, reference row %d -- %s.  This is "
              "the maximum WITHIN rows [%d,%d) and says nothing about the "
              "whole vector."
              % (ia + off, ib + off, "agree" if ia == ib else "DISAGREE",
                 off, off + n), file=out)
        print("RANK(subset) reference's subset argmax is rank %d in the "
              "card's subset; the card's is rank %d in the reference's.  "
              "Ranks are WITHIN the subset."
              % (f["rank_ref_in_card"], f["rank_card_in_ref"]), file=out)
        if card.token is not None:
            print("TOKEN RETRACTED for this run: the TOKEN line above is the "
                  "producer's own claim about the whole row, and this file "
                  "carries %.2f%% of it.  It is not corroborated here."
                  % (100.0 * n / n_full), file=out)
            f["token_agree"] = None

    for k in ks:
        ov = len(topk(a, k) & topk(b, k))
        f["topk_%d" % k] = ov
        print("TOPK%s k=%-3d overlap %d of %d"
              % ("(subset)" if subset else "  ", k, ov, min(k, n)), file=out)

    # ----------------------------------------------------------- the scales
    bb = float(np.dot(b, b))
    alpha = float(np.dot(a, b) / bb) if bb > 0 else float("nan")
    f["alpha"] = alpha
    f["alpha_log2"] = float(np.log2(abs(alpha))) if alpha not in (0.0,) and np.isfinite(alpha) else float("nan")
    print("SCALE best-fit alpha = %.9g (log2 %.6f): the single factor that "
          "minimises ||card - alpha*ref||.  A shared-exponent error off by one "
          "reads as exactly 2.0 or 0.5 here and changes no decision."
          % (alpha, f["alpha_log2"]), file=out)

    def block(tag, x, y):
        d = x - y
        rms_y = float(np.sqrt((y * y).mean()))
        rel_rms = float(np.sqrt((d * d).mean()) / rms_y) if rms_y > 0 else float("nan")
        i_abs = int(np.argmax(np.abs(d)))
        floor = rms_y * 1e-3
        rel = np.abs(d) / np.maximum(np.abs(y), floor)
        i_rel = int(np.argmax(rel))
        f["%s_rel_rms" % tag] = rel_rms
        f["%s_max_abs" % tag] = float(np.abs(d)[i_abs])
        f["%s_max_abs_i" % tag] = i_abs
        f["%s_max_rel" % tag] = float(rel[i_rel])
        f["%s_max_rel_i" % tag] = i_rel
        f["%s_ndiff" % tag] = int(np.count_nonzero(d))
        print("%-6s rel_rms %.6g | max|diff| %.6g at %d | max rel %.6g at %d "
              "(floor = ref_rms*1e-3 = %.4g) | %d of %d elements differ"
              % (tag, rel_rms, f["%s_max_abs" % tag], i_abs,
                 f["%s_max_rel" % tag], i_rel, floor,
                 f["%s_ndiff" % tag], n), file=out)
        return d

    print("-- RAW SCALE (the files' own units; quote only to expose a scale "
          "error) --", file=out)
    block("raw", a, b)
    print("-- COMMON SCALE (the card divided by alpha, residual in reference "
          "units; THIS is the line to read against the 0.1252 INT4 baseline) --",
          file=out)
    d = block("scaled", a / alpha if alpha not in (0.0,) and np.isfinite(alpha) else a, b)

    # ---------------------------------------------------------- correlation
    am, bm = a - a.mean(), b - b.mean()
    den = float(np.sqrt(np.dot(am, am) * np.dot(bm, bm)))
    f["pearson"] = float(np.dot(am, bm) / den) if den > 0 else float("nan")
    ra = np.empty(n, dtype=np.float64); ra[np.argsort(a)] = np.arange(n)
    rb = np.empty(n, dtype=np.float64); rb[np.argsort(b)] = np.arange(n)
    ram, rbm = ra - ra.mean(), rb - rb.mean()
    dens = float(np.sqrt(np.dot(ram, ram) * np.dot(rbm, rbm)))
    f["spearman"] = float(np.dot(ram, rbm) / dens) if dens > 0 else float("nan")
    print("CORR  pearson %.9f, spearman %.9f.  Read a CHANGE in these against "
          "a recorded baseline; an absolute 0.99 is what two vectors sharing "
          "the same large-magnitude structure give while disagreeing about "
          "every near tie." % (f["pearson"], f["spearman"]), file=out)

    # ---------------------------------------------------------- distribution
    rms_b = float(np.sqrt((b * b).mean()))
    e = np.abs(d) / rms_b if rms_b > 0 else np.abs(d)
    qs = [50, 90, 99, 99.9]
    vals = np.percentile(e, qs)
    for q, v in zip(qs, vals):
        f["err_p%s" % q] = float(v)
    f["err_max"] = float(e.max())
    print("DIST  |residual|/ref_rms: p50 %.6g, p90 %.6g, p99 %.6g, p99.9 %.6g, "
          "max %.6g" % (vals[0], vals[1], vals[2], vals[3], e.max()), file=out)
    order = np.argsort(np.abs(b))
    print("      by |reference| decile (0 = smallest logits):", file=out)
    for dec in range(10):
        lo, hi = dec * n // 10, (dec + 1) * n // 10
        sl = order[lo:hi]
        print("        d%-2d |ref| %9.4g..%-9.4g  mean|res|/ref_rms %.6g"
              % (dec, float(np.abs(b)[sl].min()), float(np.abs(b)[sl].max()),
                 float(e[sl].mean())), file=out)

    # ----------------------------------------------------------- per window
    # THE TILING IS A PROPERTY OF THE VOCABULARY, NOT OF WHAT WAS CAPTURED.
    # Passing `n` here for a subset would derive a DIFFERENT 15-window plan
    # from the subset's length and then report shard numbers that correspond
    # to no shard the card ever ran.
    wins = lmhead_windows(n_full) if want_windows else None
    if wins is None:
        print("WINDOW UNAVAILABLE: the lm_head tiling could not be imported "
              "from tools/gen_lmhead_windows.py, so no per-shard section is "
              "printed (rather than one invented here).", file=out)
        f["windows"] = None
    else:
        print("-- PER lm_head WINDOW (%d jobs; a wrong shard base, shard "
              "weight set or shard exponent is a PER-WINDOW signal and is "
              "invisible in every aggregate above) --" % len(wins), file=out)
        worst = (None, -1.0)
        nskip = 0
        for w, (r0, nr) in enumerate(wins):
            if subset is not None:
                s0, sn = subset
                if r0 < s0 or r0 + nr > s0 + sn:
                    # PARTIALLY COVERED WINDOWS ARE SKIPPED, NOT TRUNCATED.
                    # A window statistic computed over the part of the window
                    # that happens to be present is not that window's
                    # statistic, and it would read exactly like one.
                    print("      w%-2d rows %6d..%-6d NOT COVERED by the "
                          "subset" % (w, r0, r0 + nr - 1), file=out)
                    nskip += 1
                    continue
                r0 = r0 - s0
            aw, bw = a[r0:r0 + nr], b[r0:r0 + nr]
            bbw = float(np.dot(bw, bw))
            al = float(np.dot(aw, bw) / bbw) if bbw > 0 else float("nan")
            rw = float(np.sqrt((bw * bw).mean()))
            dw = aw / al - bw if np.isfinite(al) and al != 0 else aw - bw
            rr = float(np.sqrt((dw * dw).mean()) / rw) if rw > 0 else float("nan")
            la, lb = int(np.argmax(aw)), int(np.argmax(bw))
            g0 = wins[w][0]
            print("      w%-2d rows %6d..%-6d alpha %.9g  rel_rms %.6g  local "
                  "argmax %6d/%-6d %s" % (w, g0, g0 + nr - 1, al, rr, la, lb,
                                          "ok" if la == lb else "DIFFER"),
                  file=out)
            if rr > worst[1]:
                worst = (w, rr)
        if nskip:
            print("      %d of %d windows NOT COVERED; a window the subset "
                  "does not fully contain is not reported at all."
                  % (nskip, len(wins)), file=out)
        f["windows"] = len(wins) - nskip
        f["window_worst"] = worst[0]
        f["window_worst_rel_rms"] = worst[1]
        print("      worst window w%s at rel_rms %.6g" % worst, file=out)
    return f, True


_VEC_KEYS = ["vector", "argmax_vec_agree", "rank_ref_in_card",
             "rank_card_in_ref", "topk_1", "topk_5", "topk_20", "rotation",
             "alpha_log2", "scaled_rel_rms", "scaled_ndiff",
             "scaled_max_abs_i", "window_worst"]


def sig_line(f, keys=None):
    """One canonical line per run.  The teeth table reads THIS, so every field
    in it must be one a mutation can move, and two different mutations must not
    produce the same line.

    TWO LINES, NOT ONE, AND THE SPLIT IS THE ATTRIBUTION.  `sig_line` carries
    `token_agree`, which is the DECISION and which check_token.py already
    owns; `vsig_line` carries only what this script adds.  A mutant that moves
    SIG and leaves VSIG identical was caught by the pre-existing instrument and
    this one contributed nothing to that kill."""
    if keys is None:
        keys = ["vector", "token_agree"] + _VEC_KEYS[1:]
    parts = []
    for k in keys:
        if k not in f:
            continue
        v = f[k]
        if isinstance(v, float):
            v = "%.6g" % v
        parts.append("%s=%s" % (k, v))
    return "SIG " + " ".join(parts)


def vsig_line(f):
    return "V" + sig_line(f, keys=_VEC_KEYS)


# ------------------------------------------------------------------ mutants
MUTANTS = {
    "clean":     "the card dump reproduced from the reference with no change. "
                 "CONTROL: every check must be silent.",
    "lsb1":      "ONE non-argmax element moved by one LSB.  Prices the "
                 "comparator's RESOLUTION on the raw s32 seam.",
    "swap12":    "the top two elements' VALUES exchanged, so the argmax moves "
                 "to the runner-up.",
    "exp1":      "the shared exponent lowered by one: every value doubles, no "
                 "ordering changes.",
    "rot1":      "the whole vector rotated by one element.",
    "trunc":     "the payload truncated mid-record.",
    "common":    "the SAME one-LSB change applied to BOTH files.  EXPECTED TO "
                 "SURVIVE: a differential comparator cannot see an error its "
                 "two inputs share.",
    "tokenbias": "the TOKEN record moved to the runner-up index, the VECTOR "
                 "untouched -- the dump-file shape of fk33_sim's "
                 "fault_argmax_bias, a sampler reporting an index its own row "
                 "does not support.  EXPECTED TO SURVIVE every VECTOR section "
                 "(no value differs) and to be killed by check_token.py.  THE "
                 "ATTRIBUTION ROW: it is the one mutant this script must NOT "
                 "be credited with.",
    "novec":     "the LOGITS record removed, leaving LOGIT_EXP and TOKEN.  "
                 "This is the v2 card, and the required report is UNAVAILABLE "
                 "rather than agreement.",
}


def read_all(path):
    return list(r9bs.read(path))


def write_all(path, recs, ver=VERSION_S32):
    with open(path, "wb") as fp:
        fp.write(MAGIC)
        fp.write(np.uint32(ver).tobytes())
        for r in recs:
            _write_rec(fp, r.name, r.tok, r.layer, r.kind, r.exp,
                       [int(x) if r.kind != 0 else float(x) for x in r.raw])


def mutate(src, dst, kind):
    """Apply one named mutation to a dump.  Operates on the FILE, never on the
    RTL, exactly as mutate_logits.sh's L0/L1 rows do for the capture."""
    recs = read_all(src)
    lg = [r for r in recs if r.name == LOGITS_NAME]
    if kind == "clean":
        pass
    elif kind == "lsb1":
        r = lg[0]
        v = np.array(r.raw)
        i = 0 if int(np.argmax(v)) != 0 else 1
        v[i] += 1
        r.raw = v
    elif kind == "swap12":
        r = lg[0]
        v = np.array(r.raw)
        o = np.argsort(-v)
        v[o[0]], v[o[1]] = v[o[1]], v[o[0]]
        r.raw = v
        for t in recs:
            if t.name == TOKEN_NAME:
                t.raw = np.array([int(o[1])], dtype=t.raw.dtype)
    elif kind == "exp1":
        lg[0].exp -= 1
    elif kind == "rot1":
        r = lg[0]
        r.raw = np.roll(np.array(r.raw), 1)
        for t in recs:
            if t.name == TOKEN_NAME:
                t.raw = np.array([int(np.argmax(r.raw))], dtype=t.raw.dtype)
    elif kind == "rot1_valuesonly":
        r = lg[0]
        r.raw = np.roll(np.array(r.raw), 1)
    elif kind == "common":
        r = lg[0]
        v = np.array(r.raw)
        i = 0 if int(np.argmax(v)) != 0 else 1
        v[i] += 1
        r.raw = v
    elif kind == "tokenbias":
        r = lg[0]
        v = np.array(r.raw)
        runner = int(np.argsort(-v)[1])
        for t in recs:
            if t.name == TOKEN_NAME:
                t.raw = np.array([runner], dtype=t.raw.dtype)
    elif kind == "novec":
        recs = [r for r in recs if r.name != LOGITS_NAME]
    elif kind == "trunc":
        write_all(dst, recs)
        sz = os.path.getsize(dst)
        with open(dst, "r+b") as fp:
            fp.truncate(sz - 64)
        return
    else:
        raise SystemExit("mutate: unknown mutation %r (%s)"
                         % (kind, " ".join(sorted(MUTANTS))))
    write_all(dst, recs)


# ----------------------------------------------------------------- selftest
def _synth(n=248320, seed=7):
    """A reference vector at the REAL 9B vocabulary, so the 15-window section
    is exercised rather than collapsing to the single window every smaller n
    gives.  MEASURED on the committed reference (tools/ref9b, tok0.r9bs): the
    9B LOGITS seam is n = 248,320, rms 2.508, min -11.23, max +12.78, so the
    distribution below is the right order of magnitude and the argmax is put
    just above the tail the way a real one is.

    The two properties the mutations need: a strictly-decided argmax (so
    swap12 and tokenbias are unambiguous) and a distinct runner-up."""
    rng = np.random.RandomState(seed)
    ref = rng.normal(0.0, 2.5, n).astype(np.float64)
    # CLIPPED, because the max of 248,320 draws from N(0, 2.5) is about 11.2
    # and would otherwise contend with the planted top two.  The top two must
    # be DISTINCT and decided, or swap12 and tokenbias mutate nothing.
    ref = np.clip(ref, -11.0, 11.0)
    ref[123] = 12.75                     # the decided argmax
    ref[54321] = 12.00                   # the distinct runner-up
    return ref


def selftest(tmpdir, out=sys.stdout):
    """Self-contained teeth.  No model, no GGUF, no capture: a synthetic
    reference, the card dump derived from it, and every mutation in MUTANTS
    applied to the dump.  A row PASSES when its SIG line differs from the
    clean control's in the way its `expect` says, and a row marked survive
    PASSES when the line is IDENTICAL to the control's."""
    import subprocess
    ref = _synth()
    n = len(ref)
    exp = 15
    refp = os.path.join(tmpdir, "ref.r9bs")
    with open(refp, "wb") as fp:
        fp.write(MAGIC); fp.write(np.uint32(VERSION_S32).tobytes())
        _write_rec(fp, LOGITS_NAME, 0, -1, 0, 0, [float(x) for x in ref])
        _write_rec(fp, TOKEN_NAME, 0, -1, 2, 0, [int(np.argmax(ref))])
    # The card dump: the same numbers as raw s32 with a shared exponent, which
    # is what run_prompt --dump-logits writes.  Rounding is the only
    # difference, so the clean control is near-exact rather than exact and the
    # comparator is exercised on a real quantisation rather than on identity.
    mant = np.round(ref * (2.0 ** exp)).astype(np.int64)
    cardp = os.path.join(tmpdir, "card.r9bs")
    with open(cardp, "wb") as fp:
        fp.write(MAGIC); fp.write(np.uint32(VERSION_S32).tobytes())
        _write_rec(fp, LOGITS_NAME, 0, -1, 2, exp, [int(x) for x in mant])
        _write_rec(fp, EXP_NAME, 0, -1, 2, 0, [exp])
        _write_rec(fp, TOKEN_NAME, 0, -1, 2, 0, [int(np.argmax(mant))])

    import io
    def run(cp, rp):
        buf = io.StringIO()
        try:
            f, ok = compare(Side(cp, 0), Side(rp, 0), out=buf)
        except ValueError as e:
            return {"structural_error": str(e)}, False, buf.getvalue()
        return f, ok, buf.getvalue()

    base_f, base_ok, _ = run(cardp, refp)
    base_sig, base_vsig = sig_line(base_f), vsig_line(base_f)
    print("CONTROL  %s" % base_sig, file=out)
    print("CONTROL  %s" % base_vsig, file=out)
    if base_f.get("argmax_vec_agree") != 1 or base_f.get("token_agree") != 1:
        print("SELFTEST FAIL the clean control does not agree with itself; "
              "nothing below means anything", file=out)
        return 1

    rows, npass, nfail = [], 0, 0
    order = ["clean", "lsb1", "swap12", "exp1", "rot1", "trunc", "common",
             "tokenbias", "novec"]
    # SCORED PER FIELD, NOT ON "THE SIGNATURE MOVED".
    #
    # MEASURED 2026-09-20, and this is why: the first version scored every row
    # as "the VECTOR signature differs from the control's".  Two deliberate
    # mutants of THIS FILE -- the rotation detector forced to return None, and
    # the best-fit alpha forced to 1.0 -- then passed all nine rows, because
    # `rot1` also moves rank and top-k and `exp1` also moves scaled_rel_rms.
    # A coarse did-anything-move test cannot attribute a kill to the check
    # that was supposed to make it, which is this repository's recorded
    # "credited with a kill an existing property would have caught anyway".
    #
    # Each row therefore names the FIELD its check owns.  `pred` takes the
    # mutant's findings and the control's and returns True when THAT field
    # behaved as the mutation requires.
    def same_vec(f, c):
        return vsig_line(f) == vsig_line(c)

    expect = {
        "clean":     (lambda f, c: same_vec(f, c),
                      "the control repeated through the mutator: VSIG identical"),
        "lsb1":      (lambda f, c: (f.get("scaled_max_abs_i") == 0
                                    and f.get("argmax_vec_agree") == 1),
                      "the max residual moves to the mutated element (index 0) "
                      "and the argmax does not move: one LSB, LOCATED"),
        "swap12":    (lambda f, c: (f.get("argmax_vec_agree") == 0
                                    and f.get("rank_ref_in_card") == 2
                                    and f.get("rank_card_in_ref") == 2
                                    and f.get("topk_1") == 0
                                    and f.get("topk_5") == 5),
                      "argmax disagrees, each side's argmax is rank 2 in the "
                      "other, k=1 overlap 0 and k=5 overlap 5"),
        # MEASURED 2026-09-20: the control's own alpha_log2 is 9.84e-09, not
        # zero -- the quantiser's bias -- so the property is that the mutant
        # moves it by EXACTLY one octave RELATIVE TO THE CONTROL, not that it
        # lands on 1.0.  The residual comparison needs no tolerance at all:
        # halving is exact in binary floating point and the two agree to the
        # last bit (d = 0.0).
        "exp1":      (lambda f, c: (abs(f.get("alpha_log2", 0)
                                        - c.get("alpha_log2", 0) - 1.0) < 1e-12
                                    and f.get("scaled_rel_rms")
                                        == c.get("scaled_rel_rms")),
                      "alpha_log2 moves by EXACTLY one octave from the control "
                      "and the common-scale residual is bit-identical to it: a "
                      "pure scale, named as one"),
        "rot1":      (lambda f, c: f.get("rotation") == 1,
                      "the rotation is named by name and by amount"),
        "trunc":     ("error",
                      "a short file must raise, not compare a prefix"),
        "common":    (lambda f, c: same_vec(f, c),
                      "SURVIVES by construction: both inputs moved together"),
        "tokenbias": (lambda f, c: same_vec(f, c),
                      "SURVIVES the vector; check_token.py's kill"),
        # The `_ok` half of this row is not decoration: without it the row
        # passed while the script exited 0 on a vector it had never read.
        "novec":     (lambda f, c: (f.get("vector") == "UNAVAILABLE"
                                    and f.get("_ok") is False),
                      "reported UNAVAILABLE *and* refused a success status: "
                      "not measured is not agreement"),
    }
    for k in order:
        mp = os.path.join(tmpdir, "mut_%s.r9bs" % k)
        rp = refp
        try:
            mutate(cardp, mp, k)
            if k == "common":
                rp = os.path.join(tmpdir, "ref_common.r9bs")
                recs = read_all(refp)
                for r in recs:
                    if r.name == LOGITS_NAME:
                        v = np.array(r.raw, dtype=np.float64)
                        i = 0 if int(np.argmax(v)) != 0 else 1
                        v[i] += 2.0 ** -exp
                        r.raw = v.astype(np.float32)
                write_all(rp, recs)
        except SystemExit as e:
            rows.append((k, "SETUP-FAIL", str(e))); nfail += 1; continue
        f, ok, _ = run(mp, rp)
        pred, why = expect[k]
        err = "structural_error" in f
        sig = "ERROR " + f["structural_error"] if err else sig_line(f)
        vsig = "ERROR" if err else vsig_line(f)
        if pred == "error":
            good = err
        else:
            good = (not err) and bool(pred(f, base_f))
        rows.append((k, "PASS" if good else "FAIL", sig,
                     "vector-same" if (not err and vsig == base_vsig)
                     else ("vector-ERROR" if err else "vector-MOVED"), why))
        if good:
            npass += 1
        else:
            nfail += 1

    # ------------------------------------- the ATTRIBUTION CONTROL, per row
    # check_token.py already existed and already compares the TOKEN record.
    # For every mutant, the question "which instrument made this kill" is
    # answered by running THAT script on the same pair with this one disabled.
    here = os.path.dirname(os.path.abspath(__file__))
    ctpath = os.path.join(here, "check_token.py")
    attr = {}

    def check_token_on(path):
        return subprocess.call([sys.executable, ctpath, path, refp],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)

    # THE ATTRIBUTION INSTRUMENT IS ITSELF CALIBRATED FIRST, and it has to be.
    # MEASURED 2026-09-20: run from a COPY of this file in a scratch directory,
    # `check_token.py` was not beside it, `python3 <missing>` exits 2, and the
    # column read KILLS for every row INCLUDING the clean control -- an
    # attribution table that credits the other instrument with everything,
    # printed with no error.  Exactly this repository's "a checker that printed
    # PASS over an object it never read".  So: the file must exist, and it must
    # be SILENT on the clean pair.  If either fails the column is VOID and says
    # so rather than being read.
    attr_ok = os.path.exists(ctpath) and check_token_on(cardp) == 0
    for k in order:
        mp = os.path.join(tmpdir, "mut_%s.r9bs" % k)
        if not attr_ok:
            attr[k] = "VOID"
            continue
        if not os.path.exists(mp):
            attr[k] = "n/a"
            continue
        attr[k] = "KILLS" if check_token_on(mp) != 0 else "silent"
    if not attr_ok:
        print("ATTRIBUTION VOID: %s is %s, so the existing-instrument column "
              "below says nothing.  A column that reads KILLS everywhere is "
              "what a MISSING comparator looks like, not what a sensitive one "
              "looks like."
              % (ctpath,
                 "absent" if not os.path.exists(ctpath)
                 else "not silent on the clean pair"), file=out)

    print("", file=out)
    print("%-10s %-6s %-12s %-12s %s"
          % ("mutant", "row", "this script", "check_token", "what it prices"),
          file=out)
    for k, st, sig, vs, why in rows:
        print("%-10s %-6s %-12s %-12s %s"
              % (k, st, vs, attr.get(k, "?"), MUTANTS[k]), file=out)
        print("%-10s        required: %s" % ("", why), file=out)
        print("%-10s        %s" % ("", sig), file=out)
    print("", file=out)
    if not attr_ok:
        nfail += 1
        print("SELFTEST the attribution column was VOID; that is a failure of "
              "this test, not a detail", file=out)
    print("SELFTEST %s  %d pass, %d fail, %d rows" %
          ("PASS" if nfail == 0 else "FAIL", npass, nfail, len(rows)), file=out)
    return 0 if nfail == 0 else 1


# ------------------------------------------------- partial-vector teeth
# KEPT SEPARATE FROM THE NINE-ROW TABLE ABOVE ON PURPOSE.  That table's rows
# are quoted verbatim in docs/debugging/2026-09-20_the-card-cannot-publish-a-
# logit-vector.md; adding rows to it would change a published result.  These
# rows test one added capability and are scored on their own.
def partial_selftest(tmpdir, out=sys.stdout):
    import io
    import struct
    ref = _synth()
    n_full = len(ref)
    exp = 15
    refp = os.path.join(tmpdir, "ref.r9bs")
    with open(refp, "wb") as fp:
        fp.write(MAGIC); fp.write(np.uint32(VERSION_S32).tobytes())
        _write_rec(fp, LOGITS_NAME, 0, -1, 0, 0, [float(x) for x in ref])
        _write_rec(fp, TOKEN_NAME, 0, -1, 2, 0, [int(np.argmax(ref))])

    def card(path, r0, nr, rows_rec=True, claim=None, token=True):
        mant = np.round(ref[r0:r0 + nr] * (2.0 ** exp)).astype(np.int64)
        with open(path, "wb") as fp:
            fp.write(MAGIC); fp.write(np.uint32(VERSION_S32).tobytes())
            _write_rec(fp, LOGITS_NAME, 0, -1, 2, exp,
                       [int(x) for x in mant])
            if rows_rec:
                _write_rec(fp, ROWS_NAME, 0, -1, 2, 0,
                           list(claim if claim else (r0, nr)))
            _write_rec(fp, EXP_NAME, 0, -1, 2, 0, [exp])
            if token:
                _write_rec(fp, TOKEN_NAME, 0, -1, 2, 0,
                           [int(np.argmax(ref))])
        return path

    def run(cp, **kw):
        buf = io.StringIO()
        f, ok = compare(Side(cp, 0), Side(refp, 0), out=buf, **kw)
        return f, ok, buf.getvalue()

    wins = lmhead_windows(n_full)
    w3 = wins[3]
    rows = []

    # 1. A LEGAL SUBSET: exactly windows 3..5.
    s0 = w3[0]
    sn = sum(w[1] for w in wins[3:6])
    f, ok, txt = run(card(os.path.join(tmpdir, "p_ok.r9bs"), s0, sn))
    rows.append(("subset_ok", ok,
                 f.get("vector") == "partial"
                 and f.get("argmax_vec_agree") is None
                 and f.get("token_agree") is None
                 and f.get("windows") == 3
                 and "NOT COVERED" in txt,
                 "partial; whole-vector argmax and TOKEN NOT MEASURED; "
                 "3 of 15 windows reported"))

    # 2. THE SAME BYTES WITHOUT THE COVERAGE RECORD.  This is the defect the
    #    record exists to prevent: aligned at row 0 it would compare the
    #    wrong rows and every number would look ordinary.
    f, ok, txt = run(card(os.path.join(tmpdir, "p_norows.r9bs"), s0, sn,
                          rows_rec=False))
    rows.append(("subset_norows", ok,
                 (not ok) and f.get("vector") == "LENGTH_MISMATCH",
                 "refused: LENGTH_MISMATCH, naming LOGITS_ROWS"))

    # 3. A COVERAGE CLAIM THAT DOES NOT MATCH ITS OWN PAYLOAD.
    f, ok, txt = run(card(os.path.join(tmpdir, "p_badlen.r9bs"), s0, sn,
                          claim=(s0, sn - 1)))
    rows.append(("rows_payload", ok,
                 (not ok) and f.get("vector") == "ROWS_PAYLOAD_MISMATCH",
                 "refused: the claim and the payload disagree"))

    # 4. A COVERAGE CLAIM THAT RUNS OFF THE END OF THE VOCABULARY.
    f, ok, txt = run(card(os.path.join(tmpdir, "p_oob.r9bs"), s0, sn,
                          claim=(n_full - sn + 1, sn)))
    rows.append(("rows_oob", ok,
                 (not ok) and f.get("vector") == "ROWS_OUT_OF_RANGE",
                 "refused: the claimed rows leave the vocabulary"))

    # 5. A WHOLE VECTOR THAT DECLARES FULL COVERAGE.  The control: adding the
    #    record must not change a complete comparison into a subset one.
    f, ok, txt = run(card(os.path.join(tmpdir, "p_full.r9bs"), 0, n_full))
    rows.append(("full_with_rows", ok,
                 ok and f.get("vector") == "partial"
                 and f.get("windows") == 15,
                 "accepted; all 15 windows covered"))

    # ---- THE ATTRIBUTION CONTROL.  Each refusal above is claimed by ONE
    # branch; disable that branch and the row must stop refusing.  Without
    # this the three refusals are indistinguishable from one over-eager
    # check that rejects anything unusual.
    print("PARTIAL-VECTOR TEETH (TRACK SMPWIN, 2026-09-20)", file=out)
    print("%-16s %-8s %s" % ("row", "verdict", "required"), file=out)
    nfail = 0
    for name, ok, good, why in rows:
        print("%-16s %-8s %s" % (name, "ran" if ok else "REFUSED", why),
              file=out)
        if not good:
            nfail += 1
            print("    FAIL", file=out)
    # control: with the coverage record IGNORED, does `subset_ok` still get a
    # subset verdict?  It must not -- it must fall through to the ordinary
    # length refusal, which is exactly what `subset_norows` measures.  The two
    # rows are therefore each other's control and the table says so.
    print("ATTRIBUTION: subset_ok and subset_norows are the same bytes with "
          "and without %s." % ROWS_NAME, file=out)
    print("             The only difference between 'compared, labelled "
          "SUBSET' and 'refused' is that", file=out)
    print("             record, so the coverage branch owns both rows and "
          "nothing else does.", file=out)
    print("PARTIAL SELFTEST %s: %d rows, %d fail"
          % ("PASS" if nfail == 0 else "FAIL", len(rows), nfail), file=out)
    return nfail


# --------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("streams", nargs="*", metavar="CARD.r9bs REF.r9bs")
    ap.add_argument("--tok", type=int, default=0,
                    help="the token position; only 0 is a valid comparison "
                         "(see the header), and any other value prints why")
    ap.add_argument("--topk", default="1,5,20")
    ap.add_argument("--no-windows", action="store_true")
    ap.add_argument("--require-argmax", action="store_true",
                    help="exit 1 unless the two argmaxes agree")
    ap.add_argument("--max-rel-rms-scaled", type=float, default=None,
                    help="exit 1 if the COMMON-SCALE relative RMS exceeds this."
                         "  There is no default: read the header on why a flat"
                         " threshold is meaningless without a baseline")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--partial-selftest", action="store_true",
                    help="teeth for the PARTIAL-vector path only (TRACK "
                         "SMPWIN); kept out of --selftest so the nine-row "
                         "table quoted in docs/debugging does not move")
    ap.add_argument("--mutate", metavar="KIND")
    ap.add_argument("--in", dest="src")
    ap.add_argument("--out", dest="dst")
    a = ap.parse_args()

    if a.selftest:
        import tempfile
        d = tempfile.mkdtemp(prefix="logitcmp.")
        try:
            return selftest(d)
        finally:
            for fn in os.listdir(d):
                os.unlink(os.path.join(d, fn))
            os.rmdir(d)

    if a.partial_selftest:
        import tempfile
        d = tempfile.mkdtemp(prefix="logitcmp_partial.")
        try:
            return 1 if partial_selftest(d) else 0
        finally:
            for fn in os.listdir(d):
                os.unlink(os.path.join(d, fn))
            os.rmdir(d)

    if a.mutate:
        if not a.src or not a.dst:
            ap.error("--mutate needs --in and --out")
        mutate(a.src, a.dst, a.mutate)
        print("MUTANT %s: %s -> %s" % (a.mutate, a.src, a.dst))
        return 0

    if len(a.streams) != 2:
        ap.error("give exactly two streams: the CARD dump then the REFERENCE")
    if a.tok != 0:
        print("NOTE --tok %d: past token 0 the card's input is its own previous"
              " choice, so this is not a controlled comparison.  Proceeding "
              "because you asked; do not quote it as one." % a.tok)
    ks = tuple(int(x) for x in a.topk.split(",") if x.strip())
    try:
        card = Side(a.streams[0], a.tok)
        ref = Side(a.streams[1], a.tok)
    except ValueError as e:
        print("STRUCTURAL %s" % e)
        return 2
    f, ok = compare(card, ref, ks=ks, want_windows=not a.no_windows)
    print(sig_line(f))
    if not ok:
        print("VERDICT NOT MEASURED: %s.  This is not a pass." % f["vector"])
        return 2
    bad = []
    if a.require_argmax:
        if f.get("argmax_vec_agree") is None:
            # A GATE OVER A QUANTITY THAT WAS NOT MEASURED MUST FAIL AND SAY
            # SO.  Reporting "argmax disagrees" for a partial vector would
            # name a disagreement nobody observed.
            bad.append("--require-argmax over a PARTIAL vector: the "
                       "whole-vector argmax was NOT MEASURED")
        elif not f["argmax_vec_agree"]:
            bad.append("argmax disagrees")
    if (a.max_rel_rms_scaled is not None
            and f.get("scaled_rel_rms", 0) > a.max_rel_rms_scaled):
        bad.append("scaled rel_rms %.6g > %.6g"
                   % (f["scaled_rel_rms"], a.max_rel_rms_scaled))
    if bad:
        print("VERDICT FAIL: %s" % "; ".join(bad))
        return 1
    print("VERDICT the comparison ran.  No magnitude here is a pass or a fail "
          "on its own; read the COMMON SCALE line against the 0.1252 INT4 "
          "baseline and the PER WINDOW section against itself.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
