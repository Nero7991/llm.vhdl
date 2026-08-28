#!/usr/bin/env bash
# Analyze and run tb_seq_vec_res: subsystem D's residual accumulate, bit-exact
# against ref/seq_vec_res_vec.c over the whole configuration sweep.
#
# NO CONFIGURATION IS PRIVILEGED.  In particular ACK_LAG = 0 -- a done_ack tied
# high -- is NOT the weak case: it is the only one that catches a `done`
# register cleared inside the ack branch, which is how the gdn_head_emit defect
# was found, and the lagged cases are the only ones that catch a `done` that is
# a bare pulse.  Neither is strictly weaker than the other, so both ship.
# ACK_LAG = 20 exceeds the unit's own 11-state count, per the project rule that
# a consumer lag must outlast the producer's state machine.
#
# LANES IS SWEPT TOO, against the SAME vector file.  The C reference is
# element-serial and has no notion of lanes at all, so re-running it at 4, 8 and
# 16 lanes is a check that the lane masking and the group addressing are right
# and not merely self-consistent -- and it is only possible because the
# reference shares no machinery with the RTL.
#
# GHDL mcode: `ghdl -e` produces no binary and silently succeeds, so `ghdl -r`
# is run directly.  --max-stack-alloc=0 is needed because the vector arrays are
# 4,096-element process variables.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NCASE="${NCASE:-64}"
SEED="${SEED:-12345}"

cc -O2 -w -o "$WORK/seq_vec_res_vec" ref/seq_vec_res_vec.c -lm
( cd "$WORK" && ./seq_vec_res_vec seq_vec_res_vec.txt "$NCASE" "$SEED" )

for f in util_pkg model_cfg_pkg seq_vec_res; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_seq_vec_res.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_seq_vec_res \
      -gNCASE="$NCASE" "$@" --max-stack-alloc=0 --stop-time=900ms 2>&1 ) \
    | grep -E "PASS|FAIL|report error|assertion|MEASURED" | head -4 || true
  echo
}

echo "################ the completion handshake (defect class (b)) ############"
run "done_ack tied HIGH (degenerate, catches a clear in the ack branch)" -gACK_LAG=0
run "done_ack lagged 4"                                                  -gACK_LAG=4
run "done_ack lagged 20 (longer than the unit's 11 states)"              -gACK_LAG=20

echo "################ the issue handshake ####################################"
run "start held 3 cycles PAST the accept"        -gSTART_TAIL=3 -gACK_LAG=0
run "start held past the accept, ack lagged"     -gSTART_TAIL=3 -gACK_LAG=20
run "7 idle cycles between jobs"                 -gGAP=7

echo "################ the region ports ######################################"
run "polite memory: no 'X' between reads"        -gRD_POISON=false
run "out of place: the source must be untouched" -gIN_PLACE=false -gACK_LAG=0
run "out of place, ack lagged"                   -gIN_PLACE=false -gACK_LAG=20

echo "################ the padding poison, BOTH SIGNS #########################"
# THE SIGN OF THE POISON IS A CONFIGURATION, not a cosmetic constant.  A lane
# masked out of the final partial group takes no part in the magnitude fold, so
# the chosen shift says nothing about its accumulator and it can overrun the
# int16 clamp in EITHER direction.  With the historical +21845 it always
# overran POSITIVELY, so the unit's negative-saturation branch was never once
# executed by this bench in any configuration -- it was first reached by
# sim/tb_seq_vec_seam.sh, and it contained an out-of-range `to_signed` that
# emitted a numeric_std truncation warning on every execution.
run "padding poison NEGATIVE (reaches the negative clamp)" -gPOISON=-21846
run "padding poison negative, out of place, ack lagged" \
    -gPOISON=-21846 -gIN_PLACE=false -gACK_LAG=20

echo "################ the lane count, same vectors ###########################"
run "LANES = 4"   -gLANES=4  -gACK_LAG=0
run "LANES = 16"  -gLANES=16 -gACK_LAG=4
run "LANES = 4, out of place, ack lagged, start held" \
    -gLANES=4 -gIN_PLACE=false -gACK_LAG=20 -gSTART_TAIL=2
