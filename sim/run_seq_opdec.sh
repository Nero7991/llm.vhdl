#!/usr/bin/env bash
# Analyze and run tb_seq_opdec: the descriptor walker, the opcode-to-region
# decode and the region lock, wired together, walking the real per-token
# descriptor table for the model in rtl/model_cfg_pkg.vhd.
#
# The four producers are skewed INDEPENDENTLY and no configuration is
# privileged.  Counter-intuitive and already paid for once: the dangerous
# configuration for the descriptor shadow is a FAST memory and a SLOW unit,
# because that is when the prefetch of step n+1 completes while step n is still
# live.  A throughput-tuned run never gets the prefetch ahead at all.
#
# GHDL mcode: `ghdl -e` produces no binary and silently succeeds, so `ghdl -r`
# is run directly.  --max-stack-alloc=0 is needed for the 491-step table and
# the 491-step reference plan, which are function-local temporaries.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in util_pkg model_cfg_pkg seq_desc_fetch seq_region_lock seq_opdec; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/seq_tbl_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_seq_opdec.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_seq_opdec \
    "$@" --max-stack-alloc=0 --stop-time=400ms 2>&1 \
    | grep -vE "metavalue" \
    | grep -E "PASS|FAIL|report error|report warning|ok  |---- token|steps_done=" || true
  echo
}

echo "########### producer skew: the whole 9B token must walk clean ###########"
run "memory fast, units slow (prefetch far ahead)" \
    -gURAM_LAT=1  -gJOB_LAT=40 -gLAT_SKEW=7 -gSTRICT=true
run "memory fast, units instant" \
    -gURAM_LAT=1  -gJOB_LAT=0  -gLAT_SKEW=0 -gSTRICT=true
run "memory slow, units instant (starves the walker)" \
    -gURAM_LAT=12 -gJOB_LAT=0  -gLAT_SKEW=0 -gSTRICT=true
run "memory slow, units slow" \
    -gURAM_LAT=12 -gJOB_LAT=30 -gLAT_SKEW=3 -gSTRICT=true
run "turnaround gap on every unit" \
    -gREADY_GAP=4 -gJOB_LAT=9  -gLAT_SKEW=2

echo "############ completion discipline (defect class (b)) ##################"
run "done is a ONE-CYCLE PULSE (the withdrawn convention)" -gDONE_STYLE=1
run "done drops on its own timer, not on the ack"          -gDONE_STYLE=2 -gDONE_HOLD=5
run "done stays asserted PAST its ack"                     -gSTALE_HOLD=6 -gJOB_LAT=40
run "unit re-arms on the ack while still driving done" \
    -gSTALE_HOLD=6 -gREADY_EARLY=true -gJOB_LAT=40 -gURAM_LAT=1

echo "########### the write stream, skewed against the job latency ###########"
run "dense writes, one per cycle"   -gWR_N=8 -gWR_GAP=0 -gJOB_LAT=40
run "sparse writes, long gaps"      -gWR_N=1 -gWR_GAP=9 -gJOB_LAT=2
run "no writes at all"              -gWR_N=0

echo "###### the produced exponent's lifetime (O15, hazard a3) ###############"
# EXP_DECAY=0 means the stub's y_exp is valid for EXACTLY ONE CYCLE, the first
# cycle of `done`.  It is the only setting that separates capture-at-first-done
# from capture-at-job_cmp, and those differ by a wrong scale in one layer.
run "y_exp valid for one cycle, units slow"      -gEXP_DECAY=0 -gJOB_LAT=40
run "y_exp valid for one cycle, units instant"   -gEXP_DECAY=0 -gJOB_LAT=0
run "y_exp valid for one cycle, done is a pulse" -gEXP_DECAY=0 -gDONE_STYLE=1
run "y_exp valid for 3 cycles"                   -gEXP_DECAY=3 -gJOB_LAT=40

echo "###### D section 5.3's release rule against section 4.2's schedule #####"
# Not a fault injection: this is the MEASUREMENT that the two sections
# contradict each other.  XN is read by six consecutive A jobs; under 5.3 the
# first of the six frees it and the second consumes a region nobody produced.
run "REL_NAIVE -> must fail ERR_LOCK(2) at step 2" -gREL_NAIVE=true

echo "############ faults, one at a time, code AND failing step ##############"
run "rogue exponent write into a HELD region at step 8" -gXW_AT=8
run "write strobes that outlive their job"              -gWR_TAIL=2
run "src2 names a region the opcode does not read"      -gSRC2_BAD_AT=200
run "n_rows past ADDR_W with a real destination"        -gROWS_BIG_AT=300
run "a QKV offset that is not a segment boundary"       -gOFF_SEG_AT=2
