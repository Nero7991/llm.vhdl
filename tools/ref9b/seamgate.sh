#!/usr/bin/env bash
# tools/ref9b/seamgate.sh -- THE SEAM COMPARISON AS ONE VERDICT.
#
#   bash tools/ref9b/seamgate.sh {real|seq|stub}
#
# Exit 0 = PASS, non-zero = not green.  Designed to be a `sim/regress.sh` row
# (`sim:seamgate_<cfg>`), and to be runnable on its own with the same meaning.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS, AND HOW IT DIFFERS FROM THE LANDMARKS ALREADY IN THE GATE
# ---------------------------------------------------------------------------
# `sim/tb_llama_top_real.vhd` and its siblings carry four pinned landmarks
# (`EXP_X0`, `EXP_XSUM`, `EXP_XALL`, `EXP_STEPH`).  A landmark is a CHANGE
# DETECTOR: it says a number moved from a value somebody once wrote down.  It
# cannot say whether the old value was right, and when a legitimate `rtl/`
# change moves it, the operator re-pins it -- at which point the gate is green
# again and has learned nothing about whether the NEW numbers are correct.
#
# This row is the other instrument.  For every step of the descriptor plan that
# has an independent model, `tools/ref9b/bisect_scaled.py` takes the MACHINE'S
# OWN CAPTURED INPUTS, recomputes that step, and compares bit for bit.  It does
# not ask "did this change"; it asks "is this what the model says", and when
# the answer is no it names the SEAM and the ELEMENT.
#
# ---------------------------------------------------------------------------
# WHY THIS ONE CAN BE A GATE ROW WHEN THE GOLDEN DIFF COULD NOT
# ---------------------------------------------------------------------------
# `tools/ref9b/golden_status.sh` rejected a gate row that diffs a fresh capture
# against `tools/ref9b/golden/llama_top_*.txt`, and the reason was decisive: a
# committed artefact goes RED on every legitimate `rtl/` change that reaches
# the path, so the gate would be red all day with nothing wrong.  MEASURED
# 2026-08-29 by TRACK REF-TOKEN: the `real` golden was already not provably
# current hours after being written, four closure files having moved.
#
# NOTHING COMMITTED IS READ HERE.  Both sides are computed fresh, at gate time,
# from the tree as it stands:
#
#   the machine side  = a live GHDL run of sim/tb_llama_top.vhd
#   the model side    = tools/ref9b/{scaled_plan,vec_oracle,attn_oracle}.py and
#                       ref/{matvec_int4,attn_block_cap_vec}.c, re-run on that
#                       run's own captured inputs
#
# So a legitimate `rtl/` change that moves every number stays GREEN as long as
# the RTL still agrees with its independent model.  The gate goes red in
# exactly one case: the RTL and the model disagree.  That is not a false
# positive -- it is the question somebody has to answer, and answering it is
# cheaper here than after the numbers are pinned.
#
# The residual, stated plainly: landing a new fixed-point RECIPE in `rtl/`
# turns this row red until the model in `tools/ref9b/` follows it.  That is
# deliberate.  A recipe whose model has not been updated is a recipe with no
# oracle, and this project has already shipped one of those (`l2norm_rs` had a
# tolerance and no model).  Moving RTL and model together is the requirement,
# not an inconvenience the gate imposes.
#
# ---------------------------------------------------------------------------
# THREE DISTINCT RED VERDICTS, BECAUSE THEY MEAN DIFFERENT THINGS
# ---------------------------------------------------------------------------
#   DIVERGENCE  a modelled seam disagrees with its model.  The machine is
#               wrong, or the model is.  The seam and element are named.
#   PLAN DRIFT  `bisect_scaled.py` refuses the capture because its mirror of
#               the descriptor plan no longer describes it (rc 2).  THE MODEL
#               IS STALE; the machine has not been judged at all.  Reported
#               separately so nobody reads it as a value defect.
#   COVERAGE    every compared seam matched, but FEWER seams were compared than
#               the floor recorded below.  This is the failure mode that
#               otherwise passes silently: TRACK LOGITS found `exact()` walking
#               a name list and comparing 54 of 57 while the verdict line read
#               like full coverage.  A gate that can lose its own coverage and
#               still print PASS is decoration.
#
# ---------------------------------------------------------------------------
# THE FLOORS ARE MEASURED, AND THEY ARE THE PART THAT NEEDS RE-MEASURING
# ---------------------------------------------------------------------------
# MEASURED 2026-08-29 on a pristine `git archive 5578132` tree, GHDL 1.0.0
# mcode, with SMP=1 so the LOGITS and TOKEN records are present:
#
#   cfg   tokens  seams present  checked  not checked        capture wall time
#   real     1         64           61    R_Y-0,1,2 (B)            38 s
#   stub     1         64           60    R_Y-0,1,2 (B) + R_Y-3    29 s
#                                         (the attention ramp stub)
#   seq      3         61/tok       59    R_Y-0,2 (B)             ~110 s
#
# RAISED 2026-08-29 by TRACK RY-MODEL, re-MEASURED on a pristine
# `git archive 9ad4c14` tree with `tools/ref9b/gdn_oracle.py` driving
# `ref/gdn_block_cap_vec.c`, which models subsystem B's `R_Y`:
#
#   cfg   tokens  seams present  checked  not checked
#   real     1         64           64    -- nothing --
#   stub     1         64           63    R_Y-3 (the attention ramp stub)
#   seq      3         61/tok       61    -- nothing --
#
# The `real` and `seq` rows now have NO unmodelled seam at all, and `stub`'s
# one remaining exclusion is the `-32768 + i` ramp `rtl/llama_top.vhd:3037`
# writes when `C_REAL` is false -- which is not attention and has nothing to
# model.  Raising these floors is what landing a subsystem B model should do.
# LOWERING one is a decision, and it has to be made here, in a diff, rather
# than absorbed silently by a verdict line.
#
# WHAT FULL COVERAGE STILL DOES NOT MEAN, because the number 64 of 64 invites
# exactly the wrong reading.  Every seam having a model does not make the model
# STIMULUS rich: at these configurations `B_SRC_REAL` is false, so subsystem
# B's conv taps, alpha and beta are `m12` stand-ins and `R_Y` depends on the
# capture only through `R_Z` and the three `R_QKV` exponents.  A defect that
# only shows on activation-derived taps is out of reach of this row until
# something runs `B_SRC_REAL`.  See
# docs/debugging/2026-08-29_ry-model-subsystem-b.md.
#
# ---------------------------------------------------------------------------
# `seq` IS NOT `real` WITH MORE TOKENS.  IT IS THE ONLY ROW THAT SEES THE
# RECURRENCE, AND SINCE 2026-08-29 THAT IS A REAL DIFFERENCE.
# ---------------------------------------------------------------------------
# `real` and `stub` run ONE token.  Subsystem B is a recurrent architecture and
# `rtl/gdn_recur_pipe.vhd` masks the state read at `tk0`, so at a single token
# NOTHING downstream of the recurrent state can be exercised, whatever the top
# level drives.  Until defect B-TOP-1 was fixed the top level drove `tk0` high
# at EVERY token, so `seq` could not see it either: `mutate_seamgate.sh` S10
# (the decay rounding bias deleted) and S11 (the per-layer term deleted from
# llama_top's B state address) both survived all three rows.
#
# They no longer survive `seq`.  They still survive `real` and `stub`, and that
# is arithmetic and not a gap to be closed: one token has no previous state.
# A B-side mutation must be run at `seq` before "it survived" means anything.
# docs/debugging/2026-08-29_btop1-b-recurrence.md.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
CFG="${1:-real}"

case "$CFG" in
  real) FLOOR=64 ;;
  stub) FLOOR=63 ;;
  seq)  FLOOR=61 ;;
  *) echo "SEAMGATE FAIL -- unknown configuration '$CFG' (real|seq|stub)"; exit 2 ;;
esac

# Ours to create, ours to remove; a caller-named one is the caller's and is
# kept.  Same ownership rule sim/regress.sh settled on after two agents shared
# a REGRESS_SCRATCH and deleted each other's evidence.
if [ -n "${SEAMGATE_SCRATCH:-}" ]; then
  SG="$SEAMGATE_SCRATCH"; OURS=0
else
  SG="$(mktemp -d -t seamgate.XXXXXX)"; OURS=1
fi
mkdir -p "$SG"
cleanup() { [ "$OURS" = 1 ] && [ "${KEEP:-0}" != 1 ] && rm -rf "$SG"; }
trap cleanup EXIT

CAP="$SG/cap_$CFG.txt"

# The subsystem A oracle, built into the SCRATCH tree.  Not into tools/ref9b/:
# a gate row must not write into the repository, and two concurrent runs would
# race over one path.  `ref/attn_block_cap_vec.c` is built the same way by
# tools/ref9b/attn_oracle.py, into its own tempdir.
if ! cc -O2 -Wall -DMV4I_LIB -I "$REPO/ref" -o "$SG/mv_step_oracle" \
        "$REPO/tools/ref9b/mv_step_oracle.c" -lm > "$SG/cc.log" 2>&1; then
  echo "SEAMGATE FAIL -- could not build the subsystem A oracle:"
  sed -n 1,8p "$SG/cc.log"
  exit 2
fi
export MV_STEP_ORACLE="$SG/mv_step_oracle"

# ------------------------------------------------------------------ the machine
SMP=1 SCRATCH="$SG/work" bash tools/ref9b/capture_llama_top.sh "$CFG" "$CAP" \
    > "$SG/capture.log" 2>&1
crc=$?
if [ ! -s "$CAP" ] || ! grep -aq '^SEAM' "$CAP"; then
  echo "SEAMGATE FAIL -- the capture produced no seam records (rc=$crc)."
  echo "  A run that died has captured nothing, and an empty file compares"
  echo "  equal to another empty file, so this is a FAILURE and never a pass."
  tail -6 "$SG/capture.log"
  exit 2
fi
grep -a 'RESULT:\|seam capture wrote\|logits capture:' "$SG/capture.log" | sed 's/^ *//'

# The bench's own verdict is NOT this row's verdict, but a bench that failed
# has produced a capture nobody should be comparing.
#
# AND ITS `RESULT: PASS` MEANS LESS THAN IT LOOKS, deliberately.  The capture is
# taken through `capture_llama_top.sh`, which passes the SHAPE generics and not
# the four `EXP_*` landmarks, so this run prints `P14 -- NO VALUE GATE` and its
# PASS is a statement about schedule, skew and degenerate residuals only.  That
# is the point: the landmarks are checked by `sim:tb_llama_top_real` and the
# rest of that family, and this row is the independent second instrument.  A
# mutant that fails the landmark row can therefore reach this comparison with a
# clean `RESULT: PASS`, and MEASURED 2026-08-29 one does (`mutate_seamgate.sh`
# S4).  Reading this line as a value verdict is the mistake to avoid.
if grep -aq 'RESULT: FAIL' "$SG/capture.log"; then
  echo "SEAMGATE FAIL -- sim/tb_llama_top.vhd itself reported RESULT: FAIL in"
  echo "  configuration $CFG, so the capture is of a run that did not pass its"
  echo "  own structural checks.  Fix that row first; this one cannot mean"
  echo "  anything until it is green."
  exit 1
fi

# ------------------------------------------------------------------- the model
# The bisect args come from capture_llama_top.sh, one line under the generics
# they must agree with.  Reading them beats holding a second copy: a --norm
# that disagrees with the elaborated design makes every norm seam read as a
# defect, and that trap has already been paid for once (first-bisect trap T5).
BARGS="$(LIST_BISECT=1 bash tools/ref9b/capture_llama_top.sh "$CFG")" || {
  echo "SEAMGATE FAIL -- could not read the bisect arguments for $CFG"; exit 2; }

# Every token the capture carries, taken FROM THE CAPTURE.  `seq` is three
# tokens and the other two are one; deriving it means adding NTOK to a
# configuration cannot silently leave the extra tokens unchecked.
TOKS="$(awk '$1=="SEAM"{print $3}' "$CAP" | sort -un)"
[ -n "$TOKS" ] || { echo "SEAMGATE FAIL -- no tokens in the capture"; exit 2; }

# `worst` only ever RISES.  A later token reporting a divergence must not
# downgrade an earlier token's PLAN DRIFT, because those two mean different
# things and the more serious one is the one that says nothing was judged.
worst=0
ntok=0
minchk=999999
for t in $TOKS; do
  ntok=$((ntok+1))
  out="$SG/bisect_$CFG.$t.txt"
  # Run from the REPOSITORY ROOT, not from tools/ref9b: the --w-image path in
  # the argument string is repo-relative, as every path in this repository's
  # scripts is.  python3 puts the SCRIPT's directory on sys.path, so the
  # `import scaled_plan` beside it still resolves.
  # shellcheck disable=SC2086
  python3 tools/ref9b/bisect_scaled.py "$CAP" $BARGS --tok "$t" > "$out" 2>&1
  brc=$?
  chk=$(awk '/^# [0-9]+ seams checked/{print $2}' "$out")
  # The counts come from bisect_scaled.py's own verdict line, never recounted
  # here.  A second count in a second place is how a coverage figure and the
  # thing it describes drift apart.
  nch=$(awk '/^# [0-9]+ seams checked/{print $8}' "$out")

  # A PYTHON TRACEBACK EXITS 1, WHICH IS ALSO THE DIVERGENCE CODE.  Reporting a
  # crashed comparator as "a seam diverged" names an innocent seam and sends
  # the next reader into the RTL; the verdict line is the only thing that
  # distinguishes them, so its ABSENCE is the test.
  if [ -z "$chk" ]; then
    echo "SEAMGATE FAIL (HARNESS) -- $CFG token $t: bisect_scaled.py produced no"
    echo "  verdict line at all (rc=$brc).  This is the COMPARATOR failing, not"
    echo "  a seam diverging.  Nothing about the machine has been judged."
    tail -12 "$out" | sed 's/^/    /'
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  [ "$chk" -lt "$minchk" ] && minchk=$chk

  if [ "$brc" = 2 ]; then
    echo "SEAMGATE FAIL (PLAN DRIFT) -- $CFG token $t: tools/ref9b's mirror of"
    echo "  the descriptor plan no longer describes this capture, so it refused"
    echo "  to compare.  THE MODEL IS STALE; the machine has NOT been judged."
    echo "  A shifted plan reports a divergence at the wrong seam, and the seam"
    echo "  is the whole output of a bisect.  Re-sync tools/ref9b/scaled_plan.py"
    echo "  with sim/llama_sched_pkg.vhd."
    sed -n '1,12p' "$out" | sed 's/^/    /'
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  if [ "$brc" != 0 ]; then
    echo "SEAMGATE FAIL (DIVERGENCE) -- $CFG token $t: a modelled seam does not"
    echo "  match its model, given the machine's own inputs."
    grep -a 'FIRST DIVERGENCE' "$out" | sed 's/^/    /'
    sed -n '/^  [A-Z_]/p' "$out" | head -8 | sed 's/^/    /'
    [ "$worst" -lt 1 ] && worst=1
    continue
  fi
  if [ "$chk" -lt "$FLOOR" ]; then
    echo "SEAMGATE FAIL (COVERAGE) -- $CFG token $t: every compared seam matched,"
    echo "  but only $chk seams were compared against the recorded floor of"
    echo "  $FLOOR.  A checker that quietly stops checking prints the same"
    echo "  verdict as one that checks everything; that is the failure TRACK"
    echo "  LOGITS found in exact() and it is not allowed back in."
    grep -a '^    NOT CHECKED' "$out" | sed 's/^/  /'
    [ "$worst" -lt 1 ] && worst=1
    continue
  fi
  echo "  token $t: $chk seams bit-exact against a model, ${nch:-?} not checked"
  grep -a '^    NOT CHECKED' "$out" | sed 's/^/  /'
done

echo
if [ "$worst" != 0 ]; then
  echo "SEAMGATE FAIL -- $CFG"
  echo "scratch kept for post-mortem: $SG"
  KEEP=1
  exit "$worst"
fi
echo "SEAMGATE PASS -- $CFG: $ntok token(s), at least $minchk seams per token"
echo "  bit-identical to an independent model driven by the machine's own"
echo "  inputs (floor $FLOOR).  This is NOT a statement that the token is"
echo "  right: read the NOT CHECKED lines above.  A wrong value at an"
echo "  unmodelled seam is passed forward AS GIVEN and every later seam still"
echo "  agrees."
echo "  AND WHEN NOTHING IS LISTED AS UNCHECKED, THE RESIDUAL MOVES RATHER"
echo "  THAN VANISHING.  Every seam then has a model, but the STIMULUS is"
echo "  still the bench's: B_SRC_REAL is false in all three configurations, so"
echo "  subsystem B sees m12 stand-in taps, and the four approximation kernels"
echo "  are INCLUDED by the models rather than independently transcribed."

exit 0
