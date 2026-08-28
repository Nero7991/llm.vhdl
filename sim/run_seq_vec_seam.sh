#!/usr/bin/env bash
# Analyse and run tb_seq_vec_seam: subsystem D's D-ctrl / D-vec seam, with
# FIVE real units in the loop -- seq_desc_fetch, seq_opdec, seq_region_lock,
# seq_vec_issue and seq_vec_res -- walking a descriptor table and executing a
# chain of in-place residuals bit-exactly against ref/seq_vec_chain_vec.c.
#
# WHY A CHAIN AND NOT A BAG OF CASES.  The residual reads X, writes X and
# publishes X's new exponent, and the next residual reads that exponent back
# out of the region lock.  So the feedback path runs through all five units and
# a single lost, stale, swapped or misrouted exponent desynchronises every
# remaining step rather than perturbing one.  A bag of cases with the exponents
# handed in by the testbench cannot test that path at all, because then the
# testbench IS the path.
#
# NO CONFIGURATION IS PRIVILEGED, and the sweep is over the ENGINE side.  The
# ack that closes this seam is generated inside `seq_desc_fetch`'s S_COMPLETE
# and is not tunable from outside, so the ack-tied-high / ack-lagged pair that
# `sim/run_seq_vec_res.sh` sweeps lives there and not here.  What IS tunable
# here is every producer around the adapter: the descriptor memory, the four
# stub units, and the two stub D-vec engines that sit behind the same adapter
# as the real residual.  Those engines carry the completion-discipline sweep:
# `done` as a level, as a one-cycle pulse and on its own timer, `ready`
# re-armed while a completion is still held, a start left unaccepted for longer
# than the adapter's own state count, and a `y_exp` valid for exactly one cycle.
#
# VREADY_GAP = 20 exceeds BOTH the adapter's 8 states and seq_vec_res's 11, per
# the project rule that a lag must outlast the producer's state machine.
#
# GHDL mcode: `ghdl -e` produces no binary and silently succeeds, so `ghdl -r`
# is run directly.  --max-stack-alloc=0 is needed because the chain vectors and
# the descriptor table are function-local temporaries.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NELEM="${NELEM:-250}"
NRES="${NRES:-8}"
SEED="${SEED:-20260827}"

cc -O2 -w -I ref -o "$WORK/seq_vec_chain_vec" ref/seq_vec_chain_vec.c -lm
( cd "$WORK" && ./seq_vec_chain_vec seq_vec_chain_vec.txt "$NELEM" "$NRES" "$SEED" )

for f in util_pkg model_cfg_pkg seq_desc_fetch seq_region_lock seq_opdec \
         seq_vec_res seq_vec_issue; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/seq_tbl_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_seq_vec_seam.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  ( cd "$WORK" && ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_seq_vec_seam \
      -gNELEM="$NELEM" -gNRES="$NRES" "$@" \
      --max-stack-alloc=0 --stop-time=900ms 2>&1 ) \
    | grep -vE "metavalue" \
    | grep -E "PASS|FAIL|report error|report warning|truncated|ok  err|residuals verified" \
    | head -6 || true
  echo
}

echo "########## the seam, walked clean under four independent skews ##########"
run "memory fast, stub units slow (the prefetch gets far ahead)" \
    -gURAM_LAT=1  -gJOB_LAT=40 -gLAT_SKEW=7 -gSTRICT=true
run "memory fast, stub units instant" \
    -gURAM_LAT=1  -gJOB_LAT=0  -gLAT_SKEW=0 -gSTRICT=true
run "memory slow, stub units instant (starves the walker)" \
    -gURAM_LAT=12 -gJOB_LAT=0  -gLAT_SKEW=0 -gSTRICT=true
run "memory slow, stub units slow" \
    -gURAM_LAT=12 -gJOB_LAT=30 -gLAT_SKEW=3

echo "###### the D-vec engine handshake, behind the same adapter #############"
run "engine done is a LEVEL held until the adapter's ack (degenerate)" \
    -gVDONE_STYLE=0 -gVTAKEN_LAG=0 -gVREADY_GAP=0
run "engine done is a ONE-CYCLE PULSE (the withdrawn convention)" \
    -gVDONE_STYLE=1
run "engine done drops on its own timer, not on the ack" \
    -gVDONE_STYLE=2 -gVDONE_HOLD=5
run "engine re-arms ready while still driving done" \
    -gVDONE_STYLE=0 -gVREADY_EARLY=true
run "engine leaves start unaccepted for 20 cycles (> the adapter's 8 states)" \
    -gVTAKEN_LAG=20
run "engine ready withheld 20 cycles after every completion" \
    -gVREADY_GAP=20
run "engine y_exp valid for exactly ONE cycle of done" \
    -gVEXP_DECAY=0 -gVLAT=17

echo "###### the stub units' completion discipline (the other producer) ######"
run "stub done is a one-cycle pulse"          -gDONE_STYLE=1
run "stub done stays asserted PAST its ack"   -gSTALE_HOLD=6 -gJOB_LAT=40
run "stub re-arms on the ack while still driving done" \
    -gSTALE_HOLD=6 -gREADY_EARLY=true -gJOB_LAT=40 -gURAM_LAT=1

echo "############ the lane count, against the SAME chain vectors #############"
run "LANES = 4"  -gLANES=4
run "LANES = 16" -gLANES=16
run "LANES = 4, slow memory, engine pulse, ready gap" \
    -gLANES=4 -gURAM_LAT=12 -gVDONE_STYLE=1 -gVREADY_GAP=9

echo "############ two tokens back to back ####################################"
run "two tokens (the chain is reloaded and re-walked)" -gTOKENS=2

echo "################ faults, one at a time ##################################"
# n_rows = 2**VN_W: the LOCK accepts it (the region is that large) and the
# ADAPTER must reject it.  This is the lm_head truncation trap at this seam --
# a region-scoped count that does not fit the engines' port must be an error
# and not a silent resize.
run "a D-vec step whose element count does not fit the engine port (step 2)" \
    -gROWS_BIG_AT=2
run "the same, on a norm rather than a residual (step 3)" \
    -gROWS_BIG_AT=3
# A generator that APPENDS into a D-vec destination.  XN is not released and
# the region is sized for two copies, so the lock's append-only rule ACCEPTS
# the offset and only the adapter can catch it: a two-pass renormalise cannot
# append, because its output exponent is a property of the whole region.
run "a generator that appends into a D-vec destination" \
    -gOFF_APPEND=true

echo "############ the real 9B element count, one skew ########################"
echo "  (NELEM=4096 NRES=16: 16 x 1,047 cycles of residual, ~2 minutes)"
NELEM=4096 NRES=16 bash -c '
  set -e
  cd "'"$WORK"'"
  ./seq_vec_chain_vec big.txt 4096 16 '"$SEED"'
  ghdl -r --std=08 -frelaxed --workdir="'"$WORK"'" tb_seq_vec_seam \
    -gNELEM=4096 -gNRES=16 -gVECS=big.txt -gURAM_LAT=1 -gJOB_LAT=40 \
    --max-stack-alloc=0 --stop-time=900ms 2>&1 | grep -vE "metavalue" \
    | grep -E "PASS|FAIL|report error|residuals verified" | head -4 || true
'
