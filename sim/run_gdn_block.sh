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
run () {   # run <name> <extra generics...>
  local name="$1"; shift
  ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_gdn_block \
      "-gOUTFILE=$name.txt" "$@" --max-stack-alloc=0 --stop-time=200ms ) \
    2>&1 | sed "s/^/  [$name] /"
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
run all     -gZ_DELAY=5 -gW_MOVE=true -gSC_MOVE=true -gCW_MOVE=true -gCAP_BUSY=true

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
for n in z1 z7 z31 wmove scmove cwmove capbusy all; do
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

# ---- the emit chain's per-head deadline, MEASURED -----------------------
# gdn_recur_pipe cannot be stalled, so the arrival period is a CORRECTNESS
# parameter, not a performance one.  HEAD_GAP lengthens it by exactly one
# cycle per step, which turns the deadline into a measurement instead of a sum
# of three units' documented latencies (that sum over-estimates it by 52).
# Expect DROP at 366 and PASS at 367 for DIM=128, SILU_LANES=16, RMS_LANES=4.
echo "=== per-head deadline, DIM=128 SILU_LANES=16 RMS_LANES=4 ==="
DL="-gKEY_HEADS=2 -gVAL_HEADS=4 -gDIM=128 -gTOKENS=1 -gSILU_LANES=16"
DL="$DL -gRMS_LANES=4 -gL2_LANES=4 -gRECUR_LANES=64 -gRECUR_SLOTS=32"
for g in 0 109 110 111 256; do
  if ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_gdn_block \
         $DL "-gHEAD_GAP=$g" -gOUTFILE=dl.txt --max-stack-alloc=0 \
         --stop-time=200ms ) >/dev/null 2>&1; then
    echo "  arrival $((256+g)) cycles/head: no column refused"
  else
    echo "  arrival $((256+g)) cycles/head: COLUMN DROPPED"
  fi
done

exit $fail
