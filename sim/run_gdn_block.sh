#!/usr/bin/env bash
# Build and run tb_gdn_block across a matrix of PRODUCER SKEWS and diff the
# dumps against the maximally-ahead run.
#
# WHY A MATRIX AND NOT A RUN.  Every unit inside gdn_block is already bit-exact
# individually.  What has never been checked is the seams, and every seam
# defect found in subsystem B this week -- the unlatched w_mant, the one-cycle
# done pulse, the tvalid skew -- was numerically plausible and invisible to the
# configuration in which every producer runs maximally ahead.  The property
# under test is therefore not "the numbers are right", it is:
#
#     THE OUTPUT IS BIT-IDENTICAL UNDER EVERY PRODUCER SKEW.
#
# The reference point is the one that would be reported clean by a naive
# testbench: all producers eager, nothing moving after it is taken.
#
# GHDL here is the mcode backend: `ghdl -e` produces NO binary and silently
# succeeds, so `ghdl -r <entity>` is run directly.  Analysis order is load
# bearing: fixed_luts_pkg -> fixed_pkg -> util_pkg, then units, then the tb.
# A FRESH workdir every time, because the B RTL changes daily and a stale one
# gives "obsoleted by" rather than a result.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in util_pkg fixed_luts_pkg fixed_pkg \
         gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain \
         gdn_conv gdn_exp_capture gdn_scalar l2norm_rs gdn_recur_pipe \
         gdn_block; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_gdn_block.vhd

# --max-stack-alloc=0 because the testbench builds the whole initial state
# memory in one function return value; ghdl-mcode's 128 KB default rejects it
# at DIM=128 with "declaration of a too large object", not with a VHDL error.
#
# NLAY is the layer axis, and it is OFF for the skew matrix on purpose.  The
# matrix asks "does a producer skew change the output"; the layer phase asks a
# different question and triples the runtime of every point that carries it
# (13 s -> 37 s, MEASURED 2026-08-29).  It gets its own section below, where
# it is swept against the skews that could plausibly interact with it.
NLAY="-gNLAYER=1"
run () {   # run <name> <extra generics...>
  local name="$1"; shift
  ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_gdn_block \
      "-gOUTFILE=$name.txt" $NLAY "$@" --max-stack-alloc=0 --stop-time=200ms ) \
    2>&1 | grep -E "CYCLES|PASS|failure|error|FOLD|non-interference" \
    | sed "s/^/  [$name] /"
}

echo "=== reference: every producer maximally ahead ==="
run ref

# One axis at a time, so a failure names its own cause.
echo "=== skew matrix ==="
run z1      -gZ_DELAY=1
run z7      -gZ_DELAY=7
run z31     -gZ_DELAY=31
run wmove   -gW_MOVE=true
run scmove  -gSC_MOVE=true
run cwmove  -gCW_MOVE=true
run capbusy -gCAP_BUSY=true
# CV_GAP is the axis for the STRAIGHT-THROUGH silu path.  gdn_conv's output
# now feeds u_silu_conv with no buffer between them, so the block depends on
# where gdn_conv's internal phase boundaries fall: CV_GAP stretches pass A and
# moves both the S_SH edge that publishes e_seg and the first output beat that
# freezes the block's copy of it.
run cvgap1  -gCV_GAP=1
run cvgap3  -gCV_GAP=3
run all     -gZ_DELAY=5 -gW_MOVE=true -gSC_MOVE=true -gCW_MOVE=true \
            -gCAP_BUSY=true -gCV_GAP=2

# A faster column producer, and its dump is compared against its OWN reference:
# changing RECUR_LANES changes the state memory word shape, so a `ref` diff
# would be meaningless.  ISSUE_GAP puts the arrival period back where the emit
# chain can meet it -- see the deadline experiment at the end, and
# docs/debugging/2026-08-27_gdn-block-top-level.md.  At ISSUE_GAP=0 this
# configuration DROPS COLUMNS, deliberately, and that is the finding.
echo "=== faster column producer (RECUR_LANES=8, arrival 32*(4+gap)) ==="
run fastref -gRECUR_LANES=8 -gISSUE_GAP=1
run fastall -gRECUR_LANES=8 -gISSUE_GAP=1 -gZ_DELAY=5 -gW_MOVE=true \
            -gSC_MOVE=true -gCW_MOVE=true -gCAP_BUSY=true

echo "=== diffs against the reference ==="
fail=0
for n in z1 z7 z31 wmove scmove cwmove capbusy cvgap1 cvgap3 all; do
  if diff -q "$WORK/ref.txt" "$WORK/$n.txt" >/dev/null; then
    echo "  $n: identical to ref"
  else
    echo "  $n: DIFFERS from ref  <-- seam defect"
    diff "$WORK/ref.txt" "$WORK/$n.txt" | head -20
    fail=1
  fi
done
if diff -q "$WORK/fastref.txt" "$WORK/fastall.txt" >/dev/null; then
  echo "  fastall: identical to fastref"
else
  echo "  fastall: DIFFERS from fastref  <-- seam defect"
  diff "$WORK/fastref.txt" "$WORK/fastall.txt" | head -20
  fail=1
fi

# ---- THE LAYER AXIS -----------------------------------------------------
# One gdn_block is time-shared across every GDN layer in rtl/llama_top.vhd
# (b_layer, rtl/llama_top.vhd:2980), so anything the block retains across
# invocations without a layer index folds every layer into every other one --
# which is exactly defect C1's shape in subsystem C.  With NLAYER=2 the bench
# runs layer 0's tokens alone, then re-runs them INTERLEAVED with layer 1's,
# and asserts inside itself that the two agree.  The check is in the bench, so
# these rows fail loudly rather than needing a diff.
#
# Teeth, MEASURED 2026-08-29: removing the layer term from gdn_exp_capture's
# address (`a := cap_layer*SEGS + cap_seg` -> `a := cap_seg`, and the same on
# the read side) PASSES at NLAYER=1 and FAILS at NLAYER=2 on invocation 3.
echo "=== the layer axis: non-interference across interleaved layers ==="
NLAY="-gNLAYER=2"
run lay
run layskew -gZ_DELAY=5 -gW_MOVE=true -gSC_MOVE=true -gCW_MOVE=true \
            -gCAP_BUSY=true -gCV_GAP=2
if diff -q "$WORK/lay.txt" "$WORK/layskew.txt" >/dev/null; then
  echo "  layskew: identical to lay"
else
  echo "  layskew: DIFFERS from lay  <-- seam defect on the layer axis"
  diff "$WORK/lay.txt" "$WORK/layskew.txt" | head -20
  fail=1
fi
NLAY="-gNLAYER=1"

# ---- what the straight-through silu saved, MEASURED ---------------------
# The point of removing the second pass is the schedule, so the cost per token
# is measured rather than estimated.  The saving is one pass over the conv
# width: `sum over segments of nch/CONV_LANES` beats, plus 4 cycles of state
# per segment.  Confirmed at three conv widths in
# docs/debugging/2026-08-27_gdn-block-silu-straight-through.md.
echo "=== cycles per token, by conv width ==="
run w1 -gTOKENS=1
run w2 -gTOKENS=1 -gKEY_HEADS=4 -gVAL_HEADS=8

# ---- the emit chain's per-head deadline, MEASURED -----------------------
# gdn_recur_pipe cannot be stalled, so the arrival period is a CORRECTNESS
# parameter, not a performance one.  HEAD_GAP lengthens it by exactly one
# cycle per step, which turns the deadline into a measurement instead of a sum
# of three units' documented latencies (that sum over-estimates it by 52).
# Expect DROP at 368 and PASS at 369 for DIM=128, SILU_LANES=16, RMS_LANES=4.
# It was 366/367 before 3c2789e made rmsnorm_bf two cycles longer; that lands
# on the per-head chain one for one.  Re-measure after ANY change inside the
# emit chain rather than inferring it from an aggregate finish time.
echo "=== per-head deadline, DIM=128 SILU_LANES=16 RMS_LANES=4 ==="
DL="-gKEY_HEADS=2 -gVAL_HEADS=4 -gDIM=128 -gTOKENS=1 -gSILU_LANES=16"
DL="$DL -gRMS_LANES=4 -gL2_LANES=4 -gRECUR_LANES=64 -gRECUR_SLOTS=32"
DL="$DL -gNLAYER=1"
for g in 0 111 112 113 256; do
  if ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_gdn_block \
         $DL "-gHEAD_GAP=$g" -gOUTFILE=dl.txt --max-stack-alloc=0 \
         --stop-time=200ms ) >/dev/null 2>&1; then
    echo "  arrival $((256+g)) cycles/head: no column refused"
  else
    echo "  arrival $((256+g)) cycles/head: COLUMN DROPPED"
  fi
done

exit $fail
