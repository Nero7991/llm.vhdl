#!/usr/bin/env python3
"""smpwin_sweep.py -- the ONE logit-level measurement the shipping bitstream
can actually make: the lm_head PREFIX-ARGMAX CHAIN, card against reference.

TRACK SMPWIN, 2026-09-20.  Closes the open item LOGITCMP left in
docs/debugging/2026-09-20_the-card-cannot-publish-a-logit-vector.md section 7:
"Whether `--probe-smp` under `--upto` gives a usable per-window prefix argmax.
DERIVED ... Nothing has run it."

=============================================================================
WHAT THE CARD CAN AND CANNOT PUBLISH.  READ THIS BEFORE USING ANYTHING BELOW.
=============================================================================
THERE IS NO SAMPLER VALUE WINDOW.  The seam registers at 0x58/0x5C/0x60 are
`A_WIN_SEL`, `A_WIN_ADDR` and `A_WIN_DATA` (`rtl/fk33_seam.vhd:378-380`) and
they are the FOUR INDIRECT WINDOWS -- `W_DESC=0`, `W_REL=1`, `W_XIN=2`,
`W_XOUT=3` (`:513-517`).  None of them is a sampler window:

  * W_DESC and W_REL are the descriptor program and the release mask, written
    once per model and READABLE BACK.  (That readback is used below; it is the
    only card-side proof of WHICH program the card is running.)
  * W_XIN is the activation push.
  * W_XOUT is the region file, through `hr_reg`/`hr_addr`/`hr_data`, and on
    this silicon it reads ZERO at every address: `hw/fk33/gen_fk33_card.py`
    passes `HOST_WINDOW=false` and `rtl/region_mem.vhd:414-416` is then
    `hr_data <= (others => '0')`.

AND THE LOGITS ARE NOT IN A REGION EVEN IF THAT WINDOW WORKED.  An lm_head
window is 17,376 rows against `REGMAX = 4096`, and `rtl/seq_desc_fetch.vhd:502-507`
refuses a job that names a destination region AND sets a route flag, so every
`FLG_TO_SMP` job has `dst = R_NONE` by construction.  The logits go to the
sampler and nowhere else.

WHAT DOES CROSS THE SEAM is three numbers, `hw/fk33/gen_pcieep.py:1316-1318`:
`smp_token` (0x44 ARGMAX), `smp_n` (0x64) and `smp_exp` (0x48 LOGIT_EXP).  The
card even says so itself: `CAPS_FLAGS = 0x3D` (`rtl/fk33_seam.vhd:503`) has
bit 2 SAMPLER SET and **bit 3 LOGITS CLEAR**.

=============================================================================
WHAT IS THEREFORE MEASURABLE, AND WHY IT IS WORTH 15 GOs
=============================================================================
`rtl/llama_top.vhd:6960` clears the sampler on `go` and NOT per job, and the
15 lm_head windows are issued ascending, each carrying `FLG_TO_SMP`
(`tools/gen_layer_program.py:493`).  So a token truncated after lm_head window
k reports the argmax over vocabulary rows `[0, sum of the first k windows)`.
Fifteen such runs give the PREFIX-ARGMAX CHAIN, and the reference's own chain
is computable exactly from its LOGITS record.

=============================================================================
AND IT IS A LOCALISER, NOT A VALIDATOR.  MEASURE THE HEADROOM BEFORE RUNNING IT
=============================================================================
The first draft of this file said "15 comparisons instead of 1".  MEASURED
2026-09-20 against the only 9B reference capture that exists (prompt id
248045, `tok0.r9bs`), that claim is FALSE:

     k  row_start   n_rows   win_argmax   win_max      gap to global
     1          0    17376          846   +12.782196   +0.000000
     2      17376    17376        20139    +7.610809   +5.171387
     ...
    13     208512    17376       209838    +2.569733   +10.212463

The winner is in WINDOW 1 and beats every later window's maximum by 5.17 to
10.21 logits, so the reference's prefix chain is the constant 846 -- ONE
distinct value, not fifteen.  The reference vector's rms is 2.508 and INT4
costs 0.1252 relative rms (tools/ref9b/README.md), i.e. about 0.314 absolute,
so the smallest of those gaps is roughly SIXTEEN error scales.  DERIVED: on
this prompt the card's chain is constant 846 too unless something is grossly
broken, and 14 of the 15 GOs confirm something that was already near-certain.

Worse, the one bit they do carry -- "did a later window produce a value above
the window-1 maximum" -- IS ALREADY IN THE ARGMAX THE SHIPPING PROGRAM
REPORTS, because that program folds all 15 windows into one running maximum.

So the honest use is narrow and it is real:

  RUN THIS WHEN THE CARD'S FULL-TOKEN ARGMAX ALREADY DISAGREES WITH THE
  REFERENCE.  Then the chain NAMES THE WINDOW that introduced the wrong
  maximum -- 1/15th of the vocabulary, and a per-window base or stride defect
  is exactly the recorded OI-3 family ("a well-formed base at the wrong
  bytes", undetectable by the gateware).  `next` bisects it in 4 GOs.

  DO NOT RUN IT AS A ROUTINE CHECK on a prompt whose reference headroom is
  large.  `expect --ref` prints the per-window gaps; if the winner's window is
  1 and the gaps are many error scales, the sweep is predicted to be constant
  and has nothing to add.

THE INDEX IS A FOLD COUNT, NOT THE CARD'S `smp_idx`, AND THAT IS WHY `SMP_N`
IS A GUARD AND NOT A STATISTIC.  `rtl/sampler_stream.vhd:51-62` keeps its own
`idx`, incremented once per folded logit from 0 at `clr`, and publishes
`token <= best_i` from THAT counter.  `llama_top` computes an `s_idx` out of
the beat's own index field and publishes it on `smp_idx` -- and `smp_idx` is
wired to NOTHING (`gen_pcieep.py` carries `smp_token`, `smp_n` and `smp_exp`
across the seam and not `smp_idx`).  Consequence: if a single beat is lost,
every later index shifts by the number of logits in it and the reported argmax
is a well-formed number for the wrong row.  `smp_n` (`n_fold`,
`llama_top.vhd:6996`) counts exactly the folds, so `smp_n == expected` is the
condition under which the index means anything at all.

=============================================================================
WHAT THIS DOES NOT MEASURE
=============================================================================
  * ANY LOGIT VALUE.  No margin, no top-2 gap, no RMS, no correlation.  The
    card publishes no value at any address.  A "margin between the top logit
    and its neighbours" is NOT reachable on this bitstream, by any sequence of
    GOs, and this tool refuses to print one.
  * PER-WINDOW argmax.  A prefix is not a window: the chain names the RECORD
    HOLDERS, and a window whose own maximum never beat the running maximum is
    invisible in it.  See `plan --explain`.

=============================================================================
USAGE
=============================================================================
  smpwin_sweep.py plan  [--n-vocab N] [--first-lm-step S]
        The 15 rows: k, --upto, the rows each prefix covers, the expected
        SMP_N and TBL_LEN, and the generator command for each.  Pure
        arithmetic; touches nothing.

  smpwin_sweep.py expect --ref REF.r9bs --out EXPECT.json
        The reference's own prefix-argmax chain AND the per-window headroom
        that says whether the chain can carry any information at all.

  smpwin_sweep.py next --sweep SWEEP.json --ref-argmax N
        Which k to run NEXT, by bisection on "is the running maximum still
        the reference's argmax".  4 GOs instead of 15.

  smpwin_sweep.py ingest --sweep SWEEP.json --k K --capture CAP.txt
        Parse ONE captured step (the generator's PROBE line, run_prompt's
        prefill line, and `fk33ctl.py seam`'s output, in one file), run every
        structural guard on it, and append it.  REFUSES on any guard failure;
        a refused step is not recorded.

  smpwin_sweep.py pack --sweep SWEEP.json --out CARD.r9bs
        The sweep as an .r9bs stream (the project's one capture format).

  smpwin_sweep.py compare CARD.r9bs REF.r9bs
        The verdict.  Exit 0 agree, 1 diverge, 2 not measured.

  smpwin_sweep.py --selftest          teeth; no card and no model needed
  smpwin_sweep.py --mutate KIND --in A.json --out B.json
"""

import argparse
import hashlib
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import r9bs                                                  # noqa: E402
from capture_to_r9bs import _write_rec, MAGIC, VERSION_S32   # noqa: E402

KIND_S32 = 2
N_VOCAB_9B = 248320
# The index of the FIRST lm_head step in the 9B token table.  MEASURED, not
# assumed: hw/fk33/results/card_swg_2026-09-20/profile/profile_striped_tok0.txt
# has 504 steps and its last 15 are `output.weight`, so the first is 489.
# `--first-lm-step` overrides it and `plan` prints it, because a shape change
# moves it and a wrong value here makes every --upto wrong in the same
# direction, which looks like a working sweep of the wrong steps.
FIRST_LM_STEP_9B = 489

PFX_ARGMAX = "SMP_PREFIX_ARGMAX"
PFX_N = "SMP_PREFIX_N"
PFX_UPTO = "SMP_PREFIX_UPTO"
PFX_TBLLEN = "SMP_PREFIX_TBLLEN"
PFX_FAULTS = "SMP_PREFIX_FAULTS"
TOKEN_NAME = "TOKEN"
EXP_NAME = "LOGIT_EXP"


# --------------------------------------------------------------- the windows
def lmhead_windows(n_vocab):
    """[(row_start, n_rows)] -- imported from the ONE derivation, never
    restated.  tools/gen_lmhead_windows.py:plan owns the rule that a window
    starts on a ROWS_IF=48 tile boundary, so the stride is
    floor(17408/48)*48 = 17,376 and NOT MAXROWS_BFP.  A second copy of that
    arithmetic here would be a second thing to be wrong."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "tools"))
    import gen_lmhead_windows as W
    _, wins = W.plan(n_vocab, 48, 17408)
    return wins


def plan_rows(n_vocab=N_VOCAB_9B, first_lm_step=FIRST_LM_STEP_9B):
    """One row per k: everything derivable without a card.

    `upto` is `first_lm_step + k` because `--upto N` keeps steps 0..N-1 and
    lm_head window k is step `first_lm_step + k - 1`.
    `tbl_len` is `upto + 1` because `--close-token` appends an END_TOKEN
    descriptor (tools/gen_layer_program.py:1346)."""
    wins = lmhead_windows(n_vocab)
    rows, pre = [], 0
    for k, (rs, nr) in enumerate(wins, 1):
        pre += nr
        rows.append(dict(k=k, upto=first_lm_step + k,
                         probe_step=first_lm_step + k - 1,
                         row_start=rs, n_rows=nr,
                         prefix_n=pre, tbl_len=first_lm_step + k + 1))
    return rows


def ref_chain(v, n_vocab=None):
    """The reference's prefix-argmax chain.

    `np.argmax` returns the FIRST maximum, which is `sampler_stream.vhd:57`'s
    tie rule ("strict '>' so the first max wins") -- the two agree by
    construction rather than by luck.  They can still differ on a tie that
    exists in one numeric format and not the other: the card compares s32
    mantissas and the reference f32 values.  A tie broken differently is a
    real disagreement to report, not an artefact to suppress, so nothing here
    rounds."""
    rows = plan_rows(n_vocab or len(v))
    if rows[-1]["prefix_n"] != len(v):
        raise ValueError("the window plan covers %d rows and the vector has "
                         "%d; they are not the same vocabulary"
                         % (rows[-1]["prefix_n"], len(v)))
    return [int(np.argmax(v[:r["prefix_n"]])) for r in rows]


# ------------------------------------------------------------- the capture
# ANCHORED, every one of them.  This project has burned three sessions on
# unanchored greps matching a log that contained the script searching it
# (CLAUDE.md, "whenever you search a haystack that can contain your own
# needle").  A capture file holds the COMMANDS as well as their output, so
# `argmax 1206` appears in the command line too; `^last job` cannot.
RE_PROBE = re.compile(
    r"^PROBE step (\d+) (\S+): FLG_TO_SMP set, dst R_NONE .*?"
    r"over this job's (\d+) output rows\s*$", re.M)
RE_PREFILL = re.compile(
    r"^prefill\s+(\d+) ids, pos (\d+), first argmax (\d+), exp (-?\d+)\s*$",
    re.M)
RE_LASTJOB = re.compile(
    r"^last job\s+seq_pos (\d+)\s+cycles (\d+)\s+argmax (\d+)\s+"
    r"logit_exp (-?\d+)\s*$", re.M)
RE_TBL = re.compile(r"^\s+tbl_len (\d+)\s+smp_n (\d+)\s*$", re.M)
RE_FAULTS = re.compile(r"^faults\s+0x([0-9a-fA-F]{8})", re.M)
RE_PROGRESS = re.compile(r"^progress\s+steps issued (\d+)", re.M)


class Refusal(Exception):
    pass


def _one(rx, text, what):
    m = rx.findall(text)
    if not m:
        raise Refusal("the capture has no %s line.  A capture missing this is "
                      "not a short capture, it is a capture of a command that "
                      "did not run" % what)
    if len(m) > 1:
        raise Refusal("the capture has %d %s lines.  Two runs in one file "
                      "cannot be attributed to one k; capture one step per "
                      "file" % (len(m), what))
    return m[0]


def parse_capture(text):
    """The five lines this sweep needs, or a Refusal naming the missing one."""
    p = _one(RE_PROBE, text, "PROBE (gen_layer_program --probe-smp)")
    pf = _one(RE_PREFILL, text, "prefill (run_prompt)")
    lj = _one(RE_LASTJOB, text, "'last job' (fk33ctl.py seam)")
    tb = _one(RE_TBL, text, "'tbl_len ... smp_n' (fk33ctl.py seam)")
    fl = _one(RE_FAULTS, text, "'faults' (fk33ctl.py seam)")
    pr = RE_PROGRESS.findall(text)
    return dict(probe_step=int(p[0]), probe_tensor=p[1], probe_rows=int(p[2]),
                prefill_argmax=int(pf[2]), logit_exp_prefill=int(pf[3]),
                seq_pos=int(lj[0]), cycles=int(lj[1]), argmax=int(lj[2]),
                logit_exp=int(lj[3]),
                tbl_len=int(tb[0]), smp_n=int(tb[1]),
                faults=int(fl, 16),
                steps_issued=int(pr[0]) if len(pr) == 1 else None,
                sha=hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16])


# ------------------------------------------------------------------- guards
# Every guard is named, every guard is individually disableable (`off`), and
# the selftest runs each mutant with the killing guard OFF as its attribution
# control.  A guard that no mutant kills is reported under its own name.
GUARDS = ("G1_PROBE", "G2_TBLLEN", "G3_SMPN", "G5_FAULTS", "G6_RANGE",
          "G7_MONOTONE", "G9_DISTINCT", "G10_COMPLETE", "G11_ANCHOR")


def check_step(row, obs, prev, seen_sha, off=()):
    """Every structural guard on ONE captured step.  Returns a list of
    findings; empty means every enabled guard passed."""
    bad = []
    if "G1_PROBE" not in off:
        # THE STALE-PROBE TRAP AT ITS SOURCE.  gen_layer_program exits non-zero
        # and prints NO `PROBE` line when the last kept step is not an A job;
        # an operator who misses that runs the PREVIOUS program and reads a
        # seam holding the PREVIOUS run's registers.  It has bitten twice.
        if obs["probe_step"] != row["probe_step"]:
            bad.append("G1_PROBE: the generator probed step %d, this k wants "
                       "step %d -- the program in this capture is not the "
                       "program for k=%d"
                       % (obs["probe_step"], row["probe_step"], row["k"]))
        if obs["probe_tensor"] != "output.weight":
            bad.append("G1_PROBE: the probed step is %r, not output.weight; "
                       "this is not an lm_head window"
                       % obs["probe_tensor"])
        if obs["probe_rows"] != row["n_rows"]:
            bad.append("G1_PROBE: the probed job has %d rows, window %d has %d"
                       % (obs["probe_rows"], row["k"], row["n_rows"]))
    if "G2_TBLLEN" not in off:
        # THE SAME TRAP FROM THE CARD'S SIDE, AND THE ONLY CARD-SIDE ONE.
        # A_TBL_LEN is a register the host wrote for THIS program; a stale seam
        # read carries the previous program's length.  G1 checks the file on
        # disk, G2 checks the silicon, and only both together rule out "the
        # right program was generated and a different one ran".
        if obs["tbl_len"] != row["tbl_len"]:
            bad.append("G2_TBLLEN: the card reports tbl_len %d, k=%d needs %d "
                       "-- the card is not running this k's program"
                       % (obs["tbl_len"], row["k"], row["tbl_len"]))
    if "G3_SMPN" not in off:
        # NOT A STATISTIC.  See the header: the published argmax is the
        # sampler's own FOLD COUNT, so an index is meaningful only if the fold
        # count is the one the plan predicts.
        if obs["smp_n"] != row["prefix_n"]:
            bad.append("G3_SMPN: smp_n %d, k=%d folds %d.  The argmax is an "
                       "index into the fold order (sampler_stream.vhd:50-62), "
                       "so a wrong fold count makes it a well-formed number "
                       "for the wrong row"
                       % (obs["smp_n"], row["k"], row["prefix_n"]))
    if "G5_FAULTS" not in off:
        if obs["faults"]:
            bad.append("G5_FAULTS: faults 0x%08x (bit0 SMP_OVF lost beats and "
                       "shifts every later index)" % obs["faults"])
    if "G6_RANGE" not in off:
        if not (0 <= obs["argmax"] < row["prefix_n"]):
            bad.append("G6_RANGE: argmax %d is outside [0,%d), the rows this "
                       "prefix folded" % (obs["argmax"], row["prefix_n"]))
    # G7 IS SKIPPED WHEN THE PREVIOUS STEP'S INDEX WAS ITSELF OUT OF RANGE.
    # MEASURED by this file's own selftest: without this, an out-of-range
    # index at k=1 makes G7 fire at k=2 as well, so G6 could never be shown
    # to own a row and the table read as two guards agreeing when it was one
    # guard's failure propagating.  A guard that cascades off another guard's
    # failure reports the same defect twice under two names.
    if ("G7_MONOTONE" not in off and prev is not None
            and 0 <= prev["argmax"] < prev["prefix_n"]):
        lo, hi = prev["prefix_n"], row["prefix_n"]
        if not (obs["argmax"] == prev["argmax"]
                or lo <= obs["argmax"] < hi):
            bad.append("G7_MONOTONE: argmax %d at k=%d is neither k=%d's %d "
                       "nor inside window %d's rows [%d,%d).  A running "
                       "maximum can only keep its holder or find a new one in "
                       "the rows just added"
                       % (obs["argmax"], row["k"], prev["k"], prev["argmax"],
                          row["k"], lo, hi))
    if "G9_DISTINCT" not in off:
        if obs["sha"] in seen_sha:
            bad.append("G9_DISTINCT: this capture is byte-identical to k=%d's."
                       "  A sweep of one file pasted fifteen times passes "
                       "every per-step check that does not read the file's "
                       "identity" % seen_sha[obs["sha"]])
    return bad


def check_sweep(sweep, off=()):
    """Sweep-level guards: completeness and the anchor."""
    bad = []
    rows = plan_rows(sweep["n_vocab"], sweep["first_lm_step"])
    have = dict((s["k"], s) for s in sweep["steps"])
    if "G10_COMPLETE" not in off:
        miss = [r["k"] for r in rows if r["k"] not in have]
        if miss:
            bad.append("G10_COMPLETE: %d of %d steps captured; missing k=%s.  "
                       "A short sweep answers a smaller question and must say "
                       "so rather than report a 15-window verdict"
                       % (len(have), len(rows),
                          ",".join(str(m) for m in miss)))
    if "G11_ANCHOR" not in off and sweep.get("full_token_argmax") is not None:
        last = have.get(rows[-1]["k"])
        if last is not None and last["argmax"] != sweep["full_token_argmax"]:
            bad.append("G11_ANCHOR: the k=15 prefix argmax is %d and the "
                       "UNTRUNCATED shipping program reports %d on the same "
                       "prompt.  k=15 IS the whole vocabulary, so these must "
                       "be the same number; they are not, and every earlier "
                       "step is therefore unattributable"
                       % (last["argmax"], sweep["full_token_argmax"]))
    return bad


# -------------------------------------------------------------------- r9bs
def _rec(name, vals, tok=0, layer=-1, exp=0):
    return (name, tok, layer, KIND_S32, exp, [int(x) for x in vals])


def pack(sweep, path):
    rows = plan_rows(sweep["n_vocab"], sweep["first_lm_step"])
    have = dict((s["k"], s) for s in sweep["steps"])
    ks = [r["k"] for r in rows if r["k"] in have]
    recs = [
        _rec(PFX_ARGMAX, [have[k]["argmax"] for k in ks]),
        _rec(PFX_N, [have[k]["smp_n"] for k in ks]),
        _rec(PFX_UPTO, [have[k]["upto"] for k in ks]),
        _rec(PFX_TBLLEN, [have[k]["tbl_len"] for k in ks]),
        _rec(PFX_FAULTS, [have[k]["faults"] for k in ks]),
    ]
    if ks:
        recs.append(_rec(EXP_NAME, [have[ks[-1]]["logit_exp"]]))
        # TOKEN is the k=15 prefix argmax, which IS the whole-vocabulary
        # argmax, so check_token.py and logit_compare.py read this file
        # unchanged.  It is written ONLY when k=15 is present: a TOKEN record
        # standing for a prefix would be a whole-vector claim from a subset,
        # which is the defect this whole file exists to refuse.
        if ks[-1] == rows[-1]["k"]:
            recs.append(_rec(TOKEN_NAME, [have[ks[-1]]["argmax"]]))
    with open(path, "wb") as fp:
        fp.write(MAGIC)
        fp.write(np.uint32(VERSION_S32).tobytes())
        for name, tok, layer, kind, exp, vals in recs:
            _write_rec(fp, name, tok, layer, kind, exp, vals)
    return len(recs)


def read_packed(path):
    out = {}
    for r in r9bs.read(path):
        out.setdefault(r.name, r)
    return out


# ----------------------------------------------------------------- compare
def compare(card_path, ref_path, out=sys.stdout, n_vocab=N_VOCAB_9B):
    """Returns (findings, status) where status is 0 agree, 1 diverge, 2 not
    measured."""
    f = {}
    card = read_packed(card_path)
    if PFX_ARGMAX not in card:
        print("CARD %s: no %s record.  This is not a prefix sweep."
              % (os.path.basename(card_path), PFX_ARGMAX), file=out)
        print("VERDICT NOT MEASURED: the card file carries no chain.",
              file=out)
        return f, 2

    # INDEX BY `upto`, NEVER BY POSITION.  MEASURED 2026-09-20, by this
    # track's own first end-to-end run: a partial sweep holding ONLY k=15 was
    # printed against the k=1 row and the verdict read "DIVERGE first at k=1,
    # rows [0,17376)" about a measurement of rows [0,248320).  A packed file
    # carries `SMP_PREFIX_UPTO` precisely so the reader never has to assume
    # the rows are the first n; assuming it is the same defect class as
    # reading a subset and reporting a whole-vector statistic.
    rows_all = plan_rows(n_vocab)
    by_upto = dict((r["upto"], r["k"]) for r in rows_all)
    raw_chain = [int(x) for x in card[PFX_ARGMAX].raw]
    raw_n = [int(x) for x in card[PFX_N].raw]
    if PFX_UPTO not in card:
        print("CARD %s: no %s record, so which windows these values belong "
              "to is unknown.  Refusing to assume they are the first %d."
              % (os.path.basename(card_path), PFX_UPTO, len(raw_chain)),
              file=out)
        return f, 2
    kk = []
    for u in card[PFX_UPTO].raw:
        if int(u) not in by_upto:
            print("CARD %s: --upto %d is not one of this shape's lm_head "
                  "windows." % (os.path.basename(card_path), int(u)),
                  file=out)
            return f, 2
        kk.append(by_upto[int(u)])
    chain = dict(zip(kk, raw_chain))
    ns = dict(zip(kk, raw_n))
    f["card_chain"] = chain
    f["card_n"] = ns

    ref_vec = None
    for r in r9bs.read(ref_path):
        if r.name == "LOGITS" and r.tok == 0:
            ref_vec = r.value
            break
    if ref_vec is None:
        print("REF  %s: no LOGITS record at tok 0.  The reference cannot "
              "produce a chain to compare against." % os.path.basename(ref_path),
              file=out)
        print("VERDICT NOT MEASURED: no reference chain.  This is not a pass.",
              file=out)
        return f, 2
    if len(ref_vec) != n_vocab:
        print("REF  %s: LOGITS n=%d, expected %d.  Refusing to compare two "
              "vocabularies." % (os.path.basename(ref_path), len(ref_vec),
                                 n_vocab), file=out)
        return f, 2

    rchain = ref_chain(ref_vec, n_vocab)
    rows = plan_rows(n_vocab)
    f["ref_chain"] = rchain

    # THE ONE STATISTIC A CHAIN SUPPORTS, AND THE REFUSAL THAT GOES WITH IT.
    print("NO LOGIT VALUE IS COMPARED HERE AND NONE CAN BE.  The card "
          "publishes an argmax, a", file=out)
    print("fold count and a shared exponent (rtl/fk33_seam.vhd:378-381, "
          "gen_pcieep.py:1316-1318)", file=out)
    print("and no value at any address, so MARGIN, TOP-2 GAP, RMS and "
          "CORRELATION are NOT MEASURED,", file=out)
    print("which is not the same as agreement.", file=out)
    print("", file=out)
    print("  k   upto  rows folded   card       ref        ", file=out)
    first_bad, n_agree = None, 0
    for r in rows:
        if r["k"] not in chain:
            print("  %2d  %4d  %9d   -- NOT CAPTURED --"
                  % (r["k"], r["upto"], r["prefix_n"]), file=out)
            continue
        ok = chain[r["k"]] == rchain[r["k"] - 1]
        n_agree += 1 if ok else 0
        if not ok and first_bad is None:
            first_bad = r["k"]
        print("  %2d  %4d  %9d   %-10d %-10d %s"
              % (r["k"], r["upto"], r["prefix_n"], chain[r["k"]],
                 rchain[r["k"] - 1], "agree" if ok else "DIFFER"), file=out)
    f["first_divergent_window"] = first_bad
    f["n_agree"] = n_agree
    f["n_compared"] = len(chain)
    f["k_captured"] = sorted(chain)

    if len(chain) < len(rows):
        print("", file=out)
        print("PARTIAL SWEEP: %d of %d windows (k=%s).  Every claim below is "
              "about those windows only."
              % (len(chain), len(rows),
                 ",".join(str(x) for x in sorted(chain))), file=out)
        print("An uncaptured window is NOT an agreeing window.", file=out)

    print("", file=out)
    if first_bad is None:
        print("VERDICT AGREE on %d of %d captured prefixes.  The card's "
              "running maximum held the same" % (n_agree, len(chain)),
              file=out)
        print("        vocabulary row as the reference's at every k "
              "captured.", file=out)
        return f, 0
    w = rows[first_bad - 1]
    before = [k for k in sorted(chain) if k < first_bad]
    print("VERDICT DIVERGE, first at the captured k=%d." % first_bad,
          file=out)
    if before:
        print("        Captured prefixes %s agree, so rows [0,%d) order the "
              "same way;"
              % (",".join(str(x) for x in before),
                 rows[before[-1] - 1]["prefix_n"]), file=out)
        print("        the disagreement is introduced somewhere in rows "
              "[%d,%d)."
              % (rows[before[-1] - 1]["prefix_n"],
                 w["row_start"] + w["n_rows"]), file=out)
    else:
        print("        No earlier prefix was captured, so this localises "
              "only to rows [0,%d)."
              % (w["row_start"] + w["n_rows"]), file=out)
    return f, 1


# ----------------------------------------------------------------- mutants
MUTANTS = ("clean", "stale_probe", "stale_seam", "offbyone", "smpn48",
           "truncated", "faults_ovf", "range", "range_k1", "nonmonotone",
           "allsame", "anchor", "chain_shift", "common")


def mutate(sweep, kind):
    s = json.loads(json.dumps(sweep))
    steps = s["steps"]
    by = dict((x["k"], x) for x in steps)
    if kind == "clean":
        pass
    elif kind == "stale_probe":
        # The generator REFUSED at k=7 and the operator captured k=6 again.
        by[7].update(dict((q, by[6][q]) for q in
                          ("probe_step", "probe_rows", "tbl_len", "smp_n",
                           "argmax", "sha")))
    elif kind == "stale_seam":
        # The HARDER shape, and the one that actually bit on silicon: the
        # PROGRAM for k=7 was generated correctly (so the PROBE line is right)
        # and the RUN did not happen, so the seam still holds k=6's registers.
        by[7].update(dict((q, by[6][q]) for q in
                          ("tbl_len", "smp_n", "argmax")))
    elif kind == "offbyone":
        # `--upto 496` instead of 497: the whole k=7 step is window 6's.
        by[7].update(dict(probe_step=by[6]["probe_step"],
                          probe_rows=by[6]["probe_rows"],
                          tbl_len=by[6]["tbl_len"], smp_n=by[6]["smp_n"]))
    elif kind == "smpn48":
        by[9]["smp_n"] -= 48          # one tile of beats lost
    elif kind == "truncated":
        s["steps"] = [x for x in steps if x["k"] <= 12]
    elif kind == "faults_ovf":
        by[4]["faults"] = 1           # smp_n left CORRECT: only G5 sees it
    elif kind == "range":
        by[5]["argmax"] = by[5]["smp_n"] + 1
    elif kind == "range_k1":
        # THE SAME DEFECT AT k=1, WHERE G7 CANNOT SEE IT.  G7 needs a previous
        # step; at k=1 there is none, so G6 is the only guard between an
        # out-of-range index and a recorded sweep.  That is the whole reason
        # G6 exists beside G7 and this row is the proof.
        by[1]["argmax"] = by[1]["smp_n"] + 1
    elif kind == "nonmonotone":
        by[11]["argmax"] = 3          # a row the earlier prefixes already lost
    elif kind == "allsame":
        for x in steps:
            x.update(dict((q, by[1][q]) for q in
                          ("probe_step", "probe_rows", "tbl_len", "smp_n",
                           "argmax", "sha")))
    elif kind == "anchor":
        # The sweep is internally perfect and the UNTRUNCATED control run
        # disagrees with it.  Only G11 can see this: nothing inside the sweep
        # is inconsistent with anything else inside the sweep.
        s["full_token_argmax"] = by[15]["argmax"] + 1
    elif kind == "chain_shift":
        # A VALID sweep whose values disagree with the reference from k=9.
        # Nothing structural may fire; `compare` must say DIVERGE at 9.
        # The new holder is the FIRST ROW OF WINDOW 9, which is inside the
        # rows k=9 adds, so G7 is satisfied and G6 is satisfied: a wrong
        # answer that is structurally indistinguishable from a right one.
        newmax = by[8]["smp_n"]
        for x in steps:
            if x["k"] >= 9:
                x["argmax"] = newmax
        # AND THE CONTROL RUN AGREES WITH IT.  A card that is consistently
        # wrong reports the same wrong argmax on the untruncated program, so
        # G11 must NOT fire here; leaving the anchor at the clean value would
        # have made this row a structural kill and hidden the point.
        s["full_token_argmax"] = newmax
    elif kind == "common":
        # Both sides wrong the same way.  Applied to the REFERENCE too by the
        # selftest, so it MUST NOT bite: the resolution floor of any
        # differential comparison.
        pass
    else:
        raise SystemExit("mutate: unknown mutation %r (%s)"
                         % (kind, " ".join(MUTANTS)))
    return s


# ---------------------------------------------------------------- selftest
def _synth_sweep(vec, n_vocab=N_VOCAB_9B, first_lm_step=FIRST_LM_STEP_9B):
    """A sweep that a PERFECT card would have produced for `vec`."""
    rows = plan_rows(n_vocab, first_lm_step)
    chain = ref_chain(vec, n_vocab)
    steps = []
    for r, a in zip(rows, chain):
        steps.append(dict(k=r["k"], upto=r["upto"],
                          probe_step=r["probe_step"],
                          probe_tensor="output.weight",
                          probe_rows=r["n_rows"],
                          argmax=a, smp_n=r["prefix_n"],
                          tbl_len=r["tbl_len"], faults=0,
                          steps_issued=None, logit_exp=-11,
                          seq_pos=1, cycles=30115246,
                          sha="%016x" % (0xA5A5000000000000 + r["k"])))
    return dict(n_vocab=n_vocab, first_lm_step=first_lm_step,
                full_token_argmax=chain[-1], steps=steps)


def _validate(sweep, off=()):
    """Run every guard over a whole sweep.  Returns the list of findings."""
    rows = dict((r["k"], r) for r in plan_rows(sweep["n_vocab"],
                                               sweep["first_lm_step"]))
    bad, seen, prev = [], {}, None
    for st in sorted(sweep["steps"], key=lambda x: x["k"]):
        r = rows[st["k"]]
        b = check_step(r, st, prev, seen, off)
        seen.setdefault(st["sha"], st["k"])
        bad.extend(b)
        prev = dict(r, argmax=st["argmax"])
    bad.extend(check_sweep(sweep, off))
    return bad


def _guards_that_fired(findings):
    return sorted(set(x.split(":")[0] for x in findings))


def selftest(tmpdir, out=sys.stdout):
    import io
    rng = np.random.default_rng(11)
    vec = rng.standard_normal(N_VOCAB_9B).astype(np.float64) * 2.5
    vec[137_004] = 13.7                      # a winner in window 8
    vec[9_311] = 12.9                        # an earlier record holder
    base = _synth_sweep(vec)

    def _write_ref(path, v):
        import struct
        with open(path, "wb") as fp:
            fp.write(MAGIC)
            fp.write(np.uint32(VERSION_S32).tobytes())
            nm = b"LOGITS"
            fp.write(struct.Struct("<IIiiii").pack(len(nm), len(v), 0, -1,
                                                   0, 0))
            fp.write(nm)
            fp.write(v.astype(np.float32).tobytes())

    ref = os.path.join(tmpdir, "ref.r9bs")
    _write_ref(ref, vec)
    # The COMMON-MODE pair: one defect present in the card chain AND in the
    # reference.  Both are regenerated from `vec2`, so the two agree perfectly
    # while both are wrong about `vec`.
    vec2 = vec.copy()
    vec2[60_001] = 20.0                      # a new winner, from window 4 on
    ref2 = os.path.join(tmpdir, "ref_common.r9bs")
    _write_ref(ref2, vec2)
    base_common = _synth_sweep(vec2)

    print("SELFTEST smpwin_sweep.py -- %d mutants over a synthetic %d-row "
          "vocabulary" % (len(MUTANTS), N_VOCAB_9B), file=out)
    print("", file=out)
    print("%-13s %-28s %-12s %s" % ("mutant", "guards that fired",
                                    "compare", "attribution control"),
          file=out)
    print("-" * 96, file=out)
    fails = 0
    # What each mutant is EXPECTED to do.  (guards, compare-status)
    # compare status: 0 agree, 1 diverge, 2 not measured, None = not run
    #
    # FOUR OF THESE WERE WRITTEN AS HYPOTHESES AND FOUR WERE WRONG.  MEASURED
    # 2026-09-20, first run of this selftest: `stale_probe` also fires
    # G9_DISTINCT (the copied capture carries the copied hash), `range` also
    # fires G7_MONOTONE (an index past the prefix is also past the window),
    # `allsame` does NOT fire G7_MONOTONE (a CONSTANT chain is monotone -- a
    # running maximum is allowed to keep its holder, so the check is blind to
    # a sweep that never moves), and `chain_shift`'s first draft did not
    # change the chain at all because the synthetic winner lives in window 8
    # and stays the winner to the end.  The table below is the MEASURED
    # behaviour with the reason recorded; it is still an assertion, because
    # any guard that stops firing breaks its row.
    expect = {
        "clean":       ([], 0),
        # G9 fires too: the mutant copies the capture hash, which is what a
        # re-read of the same file really looks like.
        "stale_probe": (["G1_PROBE", "G2_TBLLEN", "G3_SMPN", "G9_DISTINCT"],
                        None),
        "stale_seam":  (["G2_TBLLEN", "G3_SMPN"], None),
        "offbyone":    (["G1_PROBE", "G2_TBLLEN", "G3_SMPN"], None),
        "smpn48":      (["G3_SMPN"], None),
        "truncated":   (["G10_COMPLETE"], None),
        "faults_ovf":  (["G5_FAULTS"], None),
        # G6 and G7 necessarily overlap at k>1: an index past prefix_n is also
        # past the window k added.  `range_k1` is the row where they do not.
        "range":       (["G6_RANGE", "G7_MONOTONE"], None),
        "range_k1":    (["G6_RANGE"], None),
        "nonmonotone": (["G7_MONOTONE"], None),
        # NO G7 HERE, AND THAT IS THE FINDING: fifteen identical argmaxes are
        # monotone.  G2/G3 are what see it.
        "allsame":     (["G1_PROBE", "G2_TBLLEN", "G3_SMPN", "G9_DISTINCT",
                         "G11_ANCHOR"], None),
        "anchor":      (["G11_ANCHOR"], None),
        "chain_shift": ([], 1),
        "common":      ([], 0),
    }
    for kind in MUTANTS:
        s = mutate(base_common if kind == "common" else base, kind)
        found = _guards_that_fired(_validate(s))
        want_g, want_c = expect[kind]
        row_ok = (found == sorted(want_g))

        # THE COMPARE HALF.  Only run it where the sweep is structurally
        # clean; a chain that failed a guard must never reach a verdict, and
        # the selftest asserts that by not offering one.
        cstat = None
        if not found:
            card = os.path.join(tmpdir, "card_%s.r9bs" % kind)
            pack(s, card)
            buf = io.StringIO()
            # THE `common` ROW COMPARES AGAINST A REFERENCE CARRYING THE SAME
            # ERROR, which is the only construction that measures a
            # differential comparator's floor.  A `common` row that left the
            # reference alone would be a second clean row wearing a scary
            # name -- the shape of "a mutant built from the same
            # misconception as the check".
            _, cstat = compare(card, ref2 if kind == "common" else ref,
                               out=buf)
            row_ok = row_ok and (cstat == want_c)

        # THE ATTRIBUTION CONTROL: the same mutant with each firing guard
        # disabled in turn.  A guard that is the SOLE killer must leave the
        # mutant silent when it alone is off; where two guards overlap, the
        # control says so rather than crediting either.
        attr = []
        for g in found:
            rest = _guards_that_fired(_validate(s, off=(g,)))
            attr.append("%s->%s" % (g, ",".join(rest) if rest else "SILENT"))
        note = "; ".join(attr) if attr else "-- nothing fired"
        print("%-13s %-28s %-12s %s"
              % (kind, ",".join(found) if found else "(none)",
                 {0: "AGREE", 1: "DIVERGE", 2: "NOTMEAS",
                  None: "not run"}[cstat], note), file=out)
        if not row_ok:
            fails += 1
            print("    FAIL: expected guards %s and compare %s"
                  % (sorted(want_g), want_c), file=out)

    # ------------------------------------------------ the non-biting rows
    print("", file=out)
    print("MUTANTS THAT DO NOT BITE, under their own names:", file=out)
    print("  common       -- the same error in BOTH the card chain and the "
          "reference.  A differential", file=out)
    print("                  comparison cannot see it; only an independently "
          "written oracle can.", file=out)
    print("                  This is the resolution floor and it is not a "
          "defect in any guard.", file=out)
    print("  chain_shift  -- structurally PERFECT and numerically wrong.  No "
          "guard fires, by design:", file=out)
    print("                  the guards check that the measurement was made, "
          "`compare` checks what it", file=out)
    print("                  says.  A guard that fired here would be "
          "answering the question for the", file=out)
    print("                  comparator.", file=out)
    print("", file=out)
    # ----------------------------------------------------------------------
    # THE PARTIAL-ALIGNMENT ROW.  A sweep holding ONLY k=3,9,15 must report
    # its values AT k=3,9,15.  MEASURED 2026-09-20: the first version of
    # `compare` read the packed arrays POSITIONALLY and put a k=15
    # measurement on the k=1 row, then localised a divergence to "rows
    # [0,17376)" about a measurement of rows [0,248320).  That is exactly the
    # "whole-vector statistic from a subset" defect this file exists to
    # refuse, committed by this file.  The row below is the regression.
    holes = json.loads(json.dumps(base))
    holes["steps"] = [x for x in holes["steps"] if x["k"] in (3, 9, 15)]
    hpath = os.path.join(tmpdir, "card_holes.r9bs")
    pack(holes, hpath)
    buf = io.StringIO()
    hf, hs = compare(hpath, ref, out=buf)
    align_ok = (hf.get("k_captured") == [3, 9, 15] and hs == 0)
    print("PARTIAL ALIGNMENT: a sweep of k=3,9,15 lands at k=%s -> %s"
          % (hf.get("k_captured"),
             {0: "AGREE", 1: "DIVERGE", 2: "NOTMEAS"}[hs]), file=out)
    if not align_ok:
        fails += 1
        print("    FAIL: a partial sweep is being read positionally",
              file=out)
    print("", file=out)

    # THE CONTROL ON THE COMMON-MODE ROW.  `common` is only a floor
    # measurement if the same chain WOULD be caught against a reference that
    # does NOT share the defect.  Without this the row proves nothing: an
    # identical pair agrees whether or not the comparator works.
    cpath = os.path.join(tmpdir, "card_common.r9bs")
    pack(mutate(base_common, "common"), cpath)
    buf = io.StringIO()
    _, cs_clean = compare(cpath, ref, out=buf)
    print("COMMON-MODE CONTROL: the same chain against the UNSHARED "
          "reference -> %s"
          % {0: "AGREE", 1: "DIVERGE", 2: "NOTMEAS"}[cs_clean], file=out)
    if cs_clean != 1:
        fails += 1
        print("    FAIL: the common-mode pair is not actually defective, so "
              "its agreement measures nothing", file=out)
    print("", file=out)

    print("GUARDS NO MUTANT KILLS ALONE: ", end="", file=out)
    killed = set()
    for kind in MUTANTS:
        s = mutate(base_common if kind == "common" else base, kind)
        f2 = _guards_that_fired(_validate(s))
        if len(f2) == 1:
            killed.add(f2[0])
    solo = [g for g in GUARDS if g not in killed]
    print(",".join(solo) if solo else "(none -- every guard owns a row)",
          file=out)
    print("  These are CORROBORATING, not redundant, and the distinction is "
          "measurable:", file=out)
    print("  G1_PROBE reads the PROGRAM ON DISK and G2_TBLLEN reads the "
          "CARD, so `stale_seam`", file=out)
    print("  (right program generated, run never made) fires G2 and NOT G1.  "
          "Neither is ever the", file=out)
    print("  sole killer on this seam because TBL_LEN differs at every k; on "
          "a card without that", file=out)
    print("  register G1 would be the only one left.  G9_DISTINCT is "
          "subsumed by G2 here for the", file=out)
    print("  same reason and is kept for the same reason.", file=out)
    print("", file=out)
    print("SELFTEST %s: %d rows, %d fail"
          % ("PASS" if fails == 0 else "FAIL", len(MUTANTS), fails), file=out)
    return fails


# --------------------------------------------------------------------- CLI
def cmd_plan(a):
    rows = plan_rows(a.n_vocab, a.first_lm_step)
    print("lm_head prefix sweep, n_vocab=%d, first lm_head step=%d"
          % (a.n_vocab, a.first_lm_step))
    print("%3s %6s %8s %8s %11s %8s" % ("k", "--upto", "row_start", "n_rows",
                                        "prefix_n", "tbl_len"))
    for r in rows:
        print("%3d %6d %8d %8d %11d %8d"
              % (r["k"], r["upto"], r["row_start"], r["n_rows"],
                 r["prefix_n"], r["tbl_len"]))
    if a.explain:
        print("")
        print("A PREFIX IS NOT A WINDOW.  The chain names the rows at which "
              "the running maximum")
        print("changed hands; a window whose own maximum never beat the "
              "running maximum is invisible")
        print("in it.  There is no way to ask this bitstream for a "
              "per-window argmax without")
        print("rewriting the HBM arena so that only one window carries "
              "FLG_TO_SMP, and no way at")
        print("all to ask it for a logit VALUE.")
    return 0


def cmd_expect(a):
    vec = None
    for r in r9bs.read(a.ref):
        if r.name == "LOGITS" and r.tok == 0:
            vec = r.value
            break
    if vec is None:
        print("expect: %s has no LOGITS record at tok 0" % a.ref,
              file=sys.stderr)
        return 2
    ch = ref_chain(vec)
    rows = plan_rows(len(vec))
    gmax = float(vec.max())
    rms = float(np.sqrt((vec * vec).mean()))
    # THE INT4 ERROR SCALE, from tools/ref9b/README.md's MEASURED 0.1252
    # relative rms at the logits.  Stated as an assumption, not derived here.
    escale = 0.1252 * rms
    wmax, wamax = [], []
    for r in rows:
        seg = vec[r["row_start"]:r["row_start"] + r["n_rows"]]
        wmax.append(float(seg.max()))
        wamax.append(r["row_start"] + int(np.argmax(seg)))
    obj = dict(n_vocab=len(vec), chain=ch, window_max=wmax,
               window_argmax=wamax, global_max=gmax, rms=rms,
               int4_error_scale=escale,
               rows=[dict(k=r["k"], prefix_n=r["prefix_n"],
                          row_start=r["row_start"], n_rows=r["n_rows"])
                     for r in rows])
    if a.out:
        with open(a.out, "w") as fp:
            json.dump(obj, fp, indent=1)
    print("reference n=%d  rms %.4f  global max %+.6f at %d  "
          "INT4 error scale ~%.4f (0.1252 * rms)"
          % (len(vec), rms, gmax, int(np.argmax(vec)), escale))
    print("%3s %11s %10s %13s %12s %10s"
          % ("k", "ref_argmax", "win_argmax", "win_max", "gap to max",
             "gap/err"))
    for r, c, wm, wa in zip(rows, ch, wmax, wamax):
        gap = gmax - wm
        print("%3d %11d %10d %13.6f %12.6f %10s"
              % (r["k"], c, wa, wm, gap,
                 "--" if gap == 0 else "%.1f" % (gap / escale)))
    distinct = sorted(set(ch))
    print("")
    print("prefix chain distinct values: %s" % distinct)
    if len(distinct) == 1:
        gaps = [gmax - w for w in wmax if gmax - w > 0]
        wk = next(r["k"] for r in rows
                  if r["row_start"] <= distinct[0]
                  < r["row_start"] + r["n_rows"])
        print("THE CHAIN IS CONSTANT on this reference.  The winner is in "
              "window %d and every later" % wk)
        print("window's maximum is %.2f to %.2f logits below it, i.e. %.0f "
              "to %.0f INT4 error scales."
              % (min(gaps), max(gaps), min(gaps) / escale,
                 max(gaps) / escale))
        print("A 15-GO sweep on this prompt is PREDICTED to return the same "
              "number fifteen times and")
        print("therefore adds nothing to the argmax the shipping program "
              "already reports.  Run it only")
        print("to LOCALISE a disagreement that already exists, and use "
              "`next` to bisect rather than sweep.")
    return 0


def cmd_next(a):
    """Bisection: the chain is a step function (the running maximum's holder
    changes at most 14 times and only ever forwards), so finding the FIRST k
    at which the card stops agreeing with the reference is a binary search,
    not a sweep.  ceil(log2 15) = 4 GOs against 15."""
    sweep = _load_sweep(a.sweep, a.n_vocab, a.first_lm_step)
    rows = plan_rows(sweep["n_vocab"], sweep["first_lm_step"])
    have = dict((s["k"], s["argmax"]) for s in sweep["steps"])
    lo, hi = 1, len(rows)          # the answer is in [lo, hi]
    for k in sorted(have):
        if have[k] == a.ref_argmax:
            lo = max(lo, k + 1)    # agreed through k
        else:
            hi = min(hi, k)        # disagreed at k
    if lo > hi:
        print("CONTRADICTION: the captured steps say the first disagreement "
              "is both after k=%d and at or before k=%d.  The chain is not a "
              "step function, which means at least one step is not what it "
              "claims to be -- re-run the guards." % (lo - 1, hi))
        return 2
    if lo == hi and lo in have:
        print("DONE: the first window whose prefix argmax is not %d is k=%d "
              "(vocabulary rows [%d,%d))."
              % (a.ref_argmax, lo, rows[lo - 1]["row_start"],
                 rows[lo - 1]["row_start"] + rows[lo - 1]["n_rows"]))
        return 0
    if lo > len(rows):
        print("DONE: every prefix agrees with %d.  There is no divergent "
              "window." % a.ref_argmax)
        return 0
    mid = (lo + hi) // 2
    while mid in have:
        mid += 1
        if mid > hi:
            print("DONE: bracketed to k=%d." % hi)
            return 0
    r = rows[mid - 1]
    print("NEXT k=%d  (--upto %d, tbl_len %d, prefix_n %d).  Bracket is "
          "[%d,%d], %d GO(s) of bisection left."
          % (mid, r["upto"], r["tbl_len"], r["prefix_n"], lo, hi,
             max(1, (hi - lo + 1).bit_length())))
    return 0


def _load_sweep(path, n_vocab, first_lm_step):
    if os.path.exists(path):
        with open(path) as fp:
            return json.load(fp)
    return dict(n_vocab=n_vocab, first_lm_step=first_lm_step,
                full_token_argmax=None, steps=[])


def cmd_ingest(a):
    sweep = _load_sweep(a.sweep, a.n_vocab, a.first_lm_step)
    rows = dict((r["k"], r) for r in plan_rows(sweep["n_vocab"],
                                               sweep["first_lm_step"]))
    if a.k not in rows:
        print("ingest: k=%d is not in 1..%d" % (a.k, len(rows)),
              file=sys.stderr)
        return 2
    with open(a.capture) as fp:
        text = fp.read()
    try:
        obs = parse_capture(text)
    except Refusal as e:
        print("REFUSED k=%d: %s" % (a.k, e), file=sys.stderr)
        return 2
    obs["k"] = a.k
    obs["upto"] = rows[a.k]["upto"]
    obs["capture"] = os.path.abspath(a.capture)
    prev = None
    for st in sorted(sweep["steps"], key=lambda x: x["k"]):
        if st["k"] == a.k - 1:
            prev = dict(rows[st["k"]], argmax=st["argmax"])
    seen = dict((st["sha"], st["k"]) for st in sweep["steps"]
                if st["k"] != a.k)
    bad = check_step(rows[a.k], obs, prev, seen)
    if bad:
        print("REFUSED k=%d, %d guard(s):" % (a.k, len(bad)), file=sys.stderr)
        for b in bad:
            print("  " + b, file=sys.stderr)
        print("  NOT RECORDED.  Fix the step and re-run it; a recorded bad "
              "step is worse than", file=sys.stderr)
        print("  a missing one, because the sweep would then have fifteen "
              "rows.", file=sys.stderr)
        return 2
    sweep["steps"] = [s for s in sweep["steps"] if s["k"] != a.k] + [obs]
    if a.full_token_argmax is not None:
        sweep["full_token_argmax"] = a.full_token_argmax
    with open(a.sweep, "w") as fp:
        json.dump(sweep, fp, indent=1)
    print("k=%2d OK  argmax %-8d smp_n %-8d tbl_len %-4d faults 0x%08x  "
          "(%d/%d captured)"
          % (a.k, obs["argmax"], obs["smp_n"], obs["tbl_len"], obs["faults"],
             len(sweep["steps"]), len(rows)))
    return 0


def cmd_pack(a):
    with open(a.sweep) as fp:
        sweep = json.load(fp)
    bad = _validate(sweep)
    if bad and not a.allow_partial:
        print("REFUSED: %d guard(s) over the sweep:" % len(bad),
              file=sys.stderr)
        for b in bad:
            print("  " + b, file=sys.stderr)
        print("  --allow-partial packs anyway; the resulting file then has "
              "fewer than 15 rows", file=sys.stderr)
        print("  and `compare` reports PARTIAL SWEEP rather than a "
              "15-window verdict.", file=sys.stderr)
        return 2
    n = pack(sweep, a.out)
    print("wrote %s: %d records, %d of 15 windows"
          % (a.out, n, len(sweep["steps"])))
    return 0


def cmd_compare(a):
    _, st = compare(a.card, a.ref)
    return st


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--n-vocab", type=int, default=N_VOCAB_9B)
    ap.add_argument("--first-lm-step", type=int, default=FIRST_LM_STEP_9B)

    p = sub.add_parser("plan")
    p.add_argument("--explain", action="store_true")
    p.add_argument("--n-vocab", type=int, default=N_VOCAB_9B)
    p.add_argument("--first-lm-step", type=int, default=FIRST_LM_STEP_9B)
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("expect")
    p.add_argument("--ref", required=True)
    p.add_argument("--out")
    p.set_defaults(fn=cmd_expect)

    p = sub.add_parser("ingest")
    p.add_argument("--sweep", required=True)
    p.add_argument("--k", type=int, required=True)
    p.add_argument("--capture", required=True)
    p.add_argument("--full-token-argmax", type=int, default=None)
    p.add_argument("--n-vocab", type=int, default=N_VOCAB_9B)
    p.add_argument("--first-lm-step", type=int, default=FIRST_LM_STEP_9B)
    p.set_defaults(fn=cmd_ingest)

    p = sub.add_parser("next")
    p.add_argument("--sweep", required=True)
    p.add_argument("--ref-argmax", type=int, required=True)
    p.add_argument("--n-vocab", type=int, default=N_VOCAB_9B)
    p.add_argument("--first-lm-step", type=int, default=FIRST_LM_STEP_9B)
    p.set_defaults(fn=cmd_next)

    p = sub.add_parser("pack")
    p.add_argument("--sweep", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--allow-partial", action="store_true")
    p.set_defaults(fn=cmd_pack)

    p = sub.add_parser("compare")
    p.add_argument("card")
    p.add_argument("ref")
    p.set_defaults(fn=cmd_compare)

    a = ap.parse_args()
    if a.selftest:
        import tempfile
        d = tempfile.mkdtemp(prefix="smpwin_")
        return 1 if selftest(d) else 0
    if not getattr(a, "fn", None):
        ap.print_help()
        return 2
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
