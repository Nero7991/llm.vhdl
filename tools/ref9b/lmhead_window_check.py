#!/usr/bin/env python3
"""lmhead_window_check.py -- the fifteen lm_head windows, checked as a SET.

THE QUESTION THIS ANSWERS, and the one it deliberately does NOT.

TRACK LOGITS verified `output.weight`'s 15 windows as GEOMETRY -- row cover,
byte cover, descriptor acceptance, exponent invariance -- and left this open:

    Whether 15 windows produce the same 248,320 logits as one hypothetical
    job.  [...]  it would have to be `ref/matvec_int4.c` against itself,
    windowed and not.

**That numeric comparison was MEASURED to be an IDENTITY, not a round trip, and
is therefore not built here.**  `mv4i_matvec` (ref/matvec_int4.c:329) takes no
row offset -- its signature is `(f, x_mant, x_exp, n_rows, n_cols, out_mode,
out)` and its body is `for (int r = 0; r < n_rows; r++) ... get_widx(f, r, k)`,
so row r of the output is always row r of the FILE.  The only way to express a
window in that model is to compute the prefix `[0, row_start + n_rows)` and
slice it, which is exactly what `ref/run9b.c:a_job` does.  The elements a
"windowed" result would be compared against are then literally the same array
elements the single call wrote.  The difference is not merely likely to be
zero; it CANNOT be anything else, for any schedule whatever, including a
schedule that overlaps, gaps or reverses the windows.  Running it and reporting
the zero would be worse than not running it: a forced result presented as
evidence.

So the two things such a check is worth doing FOR are separated here:

  * A WINDOWING/INDEX BUG -- a wrong `row_start`, `n_rows`, stride or count.
    Already covered without arithmetic, by `tools/gen_lmhead_windows.py`'s row
    cover and per-sub-region byte cover, and by `sim/tb_seq_tbl_shape`'s
    "15 lm_head windows covering 248320 of 248320 rows".  It is re-checked
    below from the EMITTED descriptors rather than from the loop that made
    them, because that is cheap and it is the only part of the geometry this
    file needs in order to reason about the rest.

  * A SHARED ERROR IN THE MATVEC MODEL -- not catchable by any model-against-
    itself comparison, windowed or not, and not catchable here either.  What
    covers that is `sim/run_matvec.sh` at the unit level and rung 1
    (`dump_llamacpp`, llama.cpp's own graph) at the whole-model level.

WHAT THIS FILE ADDS, WHICH NOTHING ELSE COVERS.  The 15 descriptors carry ~12
scalar fields each.  Fourteen of those fields must be IDENTICAL across all 15
windows, because the windows differ only in which rows they cover.  A single
window emitted with a different `out_shift`, `w_exp`, `src`, `blk`,
`const_base`, `dst`, `K` or `M` would produce 17,376 wrong logits inside a
schedule whose row cover and byte cover are both perfect, and every existing
check would stay green:

  * `gen_lmhead_windows.py` checks cover and acceptance, not agreement.
  * `tb_seq_tbl_shape` counts rows.
  * `seam_bisect --mode exact` compares LOGITS as one vector, so it WOULD see
    it -- but only once a capture exists at the 9B shape, and none does.
  * `check_token.py` sees it only if it moves the argmax past the runner-up,
    which at the measured margins it usually will not.

`rel` is the one field that legitimately differs, on the LAST window only, and
it is named rather than exempted: a check that quietly skips a field is the
same defect as a check that quietly skips a seam.

WHERE THE SCHEDULE COMES FROM.  `tools/gen_layer_program.py --json`, run as a
subprocess, so the descriptors are the EMITTED ones and this file contains no
second copy of the window arithmetic to agree with itself.

Usage:
    python3 lmhead_window_check.py --manifest M.json [--x-exp 5]
    python3 lmhead_window_check.py --manifest M.json --mutate out_shift@3
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

LM_TENSOR = "output.weight"

# Fields of the emitted A-job record that must agree across every window.
JOB_SAME = ["tensor", "w_exp", "out_shift", "M", "K", "ok"]
# Fields of the emitted STEP record that must agree across every window.
STEP_SAME = ["opcode", "opname", "unit", "src", "src2", "dst", "dst_off",
             "n_cols", "blk", "const_base"]
# Fields that legitimately differ, NAMED rather than silently skipped.
PER_WINDOW = {
    "row_start": "the window's first row -- the whole point of the set",
    "n_rows": "17,376 on windows 0..13 and 5,056 on the last",
    "desc_addr": "each descriptor is at its own address",
    "w_beats": "proportional to n_rows",
    "s_beats": "proportional to n_rows",
    "step": "the step index in the program",
    "idx": "the step index in the program",
    "logical_row": "the unpadded row this window starts at",
    "segment": "the manifest segment name",
    "reason": "empty on an accepted descriptor",
    "ordinal": "the per-step ordinal",
    "rel": "the region-release marker, set on the LAST window only",
}


def emit(manifest, x_exp, one_job, extra=()):
    out = os.path.join(tempfile.mkdtemp(prefix="lmwin."), "prog.json")
    cmd = [sys.executable, os.path.join(REPO, "tools", "gen_layer_program.py"),
           "--token", "--shape", "9b", "--manifest", manifest,
           "--x-exp", str(x_exp), "--json", out] + list(extra)
    if one_job:
        cmd.append("--one-lmhead-job")
    r = subprocess.run(cmd, capture_output=True, text=True)
    # A NONZERO EXIT IS EXPECTED for --one-lmhead-job and is not an error here.
    # gen_layer_program.py exits 1 when any emitted descriptor would be
    # REFUSED by the gateware, and the one-job lm_head is refused BY DESIGN
    # (n_rows 248,320 > MAXROWS_BFP) -- that refusal is the reason the window
    # set exists.  So the JSON, not the exit code, is the result; a run that
    # wrote no JSON is the real failure.
    if not os.path.exists(out):
        raise SystemExit("gen_layer_program.py wrote no JSON (exit %d):\n%s\n%s"
                         % (r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    return json.load(open(out))


def lm_rows(prog):
    """(a_job, step) pairs for every lm_head job, in program order."""
    steps = {s["idx"]: s for s in prog["steps"]}
    out = []
    for j in prog["a_jobs"]:
        if j.get("tensor") == LM_TENSOR:
            out.append((j, steps[j["step"]]))
    out.sort(key=lambda p: p[0]["step"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--x-exp", type=int, default=5)
    ap.add_argument("--mutate", metavar="FIELD@W",
                   help="TEETH.  Perturb FIELD of window W in the decoded "
                        "program before checking, e.g. out_shift@3, "
                        "row_start@7, n_rows@14")
    a = ap.parse_args()

    prog = emit(a.manifest, a.x_exp, one_job=False)
    single = emit(a.manifest, a.x_exp, one_job=True)
    wins = lm_rows(prog)
    ones = lm_rows(single)

    if a.mutate:
        f, _, w = a.mutate.partition("@")
        w = int(w)
        for d in (wins[w][0], wins[w][1]):
            if f in d:
                old = d[f]
                d[f] = old + 1 if isinstance(old, int) else str(old) + "X"
                print("  MUTATED window %d field %r: %r -> %r"
                      % (w, f, old, d[f]))
                break
        else:
            raise SystemExit("no field %r on window %d" % (f, w))

    bad = 0
    print("# %d lm_head window(s) emitted; the --one-lmhead-job form emits %d"
          % (len(wins), len(ones)))
    if not wins:
        print("NO lm_head JOB WAS EMITTED AT ALL.  An empty check is not a "
              "pass.")
        return 1

    # ---- 1. the single job, and why the set exists at all ------------------
    for j, _s in ones:
        print("# the one-job form: row_start %d n_rows %d -> accepted=%s  %s"
              % (j["row_start"], j["n_rows"], j["ok"], j["reason"]))
        if j["ok"]:
            print("  !! the gateware ACCEPTS a %d-row lm_head descriptor.  The "
                  "windowed set is then no longer forced, and the reason this "
                  "check exists has changed." % j["n_rows"])
            bad += 1

    # ---- 2. the tiling, from the emitted fields ---------------------------
    M = wins[0][0]["M"]
    r = 0
    tiling_bad = 0
    for i, (j, _s) in enumerate(wins):
        if j["row_start"] != r:
            print("  TILING: window %d starts at %d, expected %d (a %s of %d "
                  "rows)" % (i, j["row_start"], r,
                             "gap" if j["row_start"] > r else "overlap",
                             abs(j["row_start"] - r)))
            tiling_bad += 1
        r = j["row_start"] + j["n_rows"]
    if r != M:
        print("  TILING: the set covers %d rows, the tensor has %d" % (r, M))
        tiling_bad += 1
    if tiling_bad:
        # A GREEN LINE MUST NOT FOLLOW A FINDING.  The first version printed
        # the "cover exactly once" line unconditionally, so a mutated
        # row_start produced two TILING failures AND a sentence saying the
        # tiling was exact.  A reader skimming would have believed the last
        # line printed.
        bad += tiling_bad
    else:
        print("# tiling: %d windows cover rows 0..%d exactly once, from the "
              "emitted row_start/n_rows" % (len(wins), M))

    # ---- 2b. relations among the PER-WINDOW fields ------------------------
    # These need no constant from anywhere: they are statements about the SET.
    # Without them `w_beats`, `s_beats` and `desc_addr` would be declared
    # per-window and then checked by nothing at all, which is how a field ends
    # up exempt rather than covered.  MEASURED at the 9B shape: mutating any
    # of the three survived the first version of this file.
    by_rows = {}
    for i, (j, _s) in enumerate(wins):
        by_rows.setdefault(j["n_rows"], []).append((i, j["w_beats"],
                                                    j["s_beats"]))
    for n, group in sorted(by_rows.items()):
        wb = {g[1] for g in group}
        sb = {g[2] for g in group}
        if len(wb) > 1 or len(sb) > 1:
            print("  BEATS: windows with n_rows = %d do not agree on their "
                  "beat counts: %s" % (n, group))
            bad += 1
    for i, (j, _s) in enumerate(wins):
        if j["s_beats"] != j["w_beats"]:
            print("  BEATS: window %d has w_beats %d and s_beats %d; the two "
                  "sub-region streams cover the same rows and must agree"
                  % (i, j["w_beats"], j["s_beats"]))
            bad += 1
    order = sorted(by_rows)
    for lo, hi in zip(order, order[1:]):
        if by_rows[hi][0][1] < by_rows[lo][0][1]:
            print("  BEATS: n_rows %d needs %d beats but n_rows %d needs %d; "
                  "beats must not fall as rows rise"
                  % (lo, by_rows[lo][0][1], hi, by_rows[hi][0][1]))
            bad += 1
    strides = {wins[i + 1][0]["desc_addr"] - wins[i][0]["desc_addr"]
               for i in range(len(wins) - 1)}
    if len(strides) > 1 or (strides and min(strides) <= 0):
        print("  DESC_ADDR: the 15 descriptors are not at a single ascending "
              "stride: %s" % sorted(strides))
        bad += 1
    else:
        print("# per-window relations: s_beats == w_beats everywhere, equal "
              "n_rows give equal beats, descriptors at a constant stride of "
              "%d bytes" % (strides.pop() if strides else 0))
    # `rel` releases the SOURCE region, and the source is read by all 15
    # windows, so exactly one of them may carry it and it must be the last.
    # Released early, the region the remaining windows read is free to be
    # overwritten; released never, the region is held for the whole token.
    relw = [i for i, (_j, s) in enumerate(wins) if s.get("rel")]
    if relw != [len(wins) - 1]:
        print("  REL: the source-region release is on window(s) %s; it must be "
              "on the LAST window and no other, or the region is freed while "
              "later windows still read it" % (relw or "none"))
        bad += 1
    else:
        print("# rel: the source region is released on the last window only")

    # ---- 3. field agreement, which is what nothing else checks ------------
    for name, keys, pick in (("a_job", JOB_SAME, 0), ("step", STEP_SAME, 1)):
        for k in keys:
            vals = {}
            for i, pair in enumerate(wins):
                vals.setdefault(pair[pick].get(k, "<absent>"), []).append(i)
            if len(vals) > 1:
                print("  FIELD %s.%s DIFFERS ACROSS WINDOWS: %s"
                      % (name, k, "; ".join("%r on window(s) %s" % (v, ws)
                                            for v, ws in vals.items())))
                bad += 1
    print("# field agreement: %d a_job field(s) and %d step field(s) checked "
          "identical across all %d windows"
          % (len(JOB_SAME), len(STEP_SAME), len(wins)))

    # ---- 4. the fields that legitimately differ, NAMED --------------------
    seen = set(wins[0][0]) | set(wins[0][1])
    unclassified = sorted(seen - set(JOB_SAME) - set(STEP_SAME)
                          - set(PER_WINDOW))
    if unclassified:
        # A NEW FIELD IS NOT A PASS.  A generator that grows a field this file
        # has never seen would otherwise be checked for nothing at all, and the
        # verdict would not change.
        print("  UNCLASSIFIED FIELD(S) %s: this checker does not know whether "
              "they must agree across windows, so it is not checking them.  "
              "Classify them in JOB_SAME/STEP_SAME or PER_WINDOW."
              % unclassified)
        bad += 1
    print("# %d field(s) are per-window by design and are named, not skipped: "
          "%s" % (len(PER_WINDOW), ", ".join(sorted(PER_WINDOW))))

    # ---- 5. the raw exponent, which is what lets 15 windows share one -----
    # rtl/matvec_core.vhd's RAW publication is y_exp = w_exp + x_exp -
    # out_shift with NO per-job ns term.  sampler_stream takes ONE smp_exp for
    # the whole token, so if this were not window-invariant the concatenation
    # would be meaningless whatever the values were.
    exps = {j["w_exp"] + a.x_exp - j["out_shift"] for j, _s in wins}
    if len(exps) != 1:
        print("  RAW EXPONENT is not window-invariant: %s.  A single smp_exp "
              "for the token cannot then be right." % sorted(exps))
        bad += 1
    else:
        print("# raw y_exp = w_exp + x_exp - out_shift = %d on every window, "
              "so one smp_exp covers the token" % exps.pop())

    if bad:
        print("LM HEAD WINDOW SET: FAIL (%d finding(s))" % bad)
        return 1
    print("LM HEAD WINDOW SET: the %d windows tile the vocabulary exactly "
          "once and agree on every field that is not per-window.  This says "
          "NOTHING about the matvec arithmetic, which is shared by every "
          "window and is checked at the unit by sim/run_matvec.sh and at the "
          "whole model by rung 1." % len(wins))
    return 0


if __name__ == "__main__":
    sys.exit(main())
