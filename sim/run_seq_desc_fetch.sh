#!/usr/bin/env bash
# Analyze and run tb_seq_desc_fetch over the producer-skew matrix and the
# fault-injection set.
#
# WHY A MATRIX AND NOT ONE RUN.  Both of the 2026-08-27 subsystem-B defects
# were invisible in the first configuration anyone tried.  The rule this script
# encodes is that the two producers -- the descriptor memory and the units --
# are skewed independently, and that BOTH extremes are run:
#
#   fast memory + slow units  -> the prefetch of step n+1 finishes while step n
#                                is still live.  This is the configuration that
#                                exercises the two-bank shadow, and the one a
#                                throughput-tuned testbench never reaches.
#   slow memory + fast units  -> D starves at S_WAITPF between every step.
#                                This is the configuration that exercises the
#                                held `start` and the turnaround.
#
# GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
# succeeds, so `ghdl -r <entity>` is run directly.  `--max-stack-alloc=0` is
# needed because the 491-descriptor table is a function-local temporary.
# `--stop-time` is a backstop only; the testbench drops `running` itself.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in util_pkg model_cfg_pkg seq_desc_fetch; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/seq_tbl_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_seq_desc_fetch.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  if ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_seq_desc_fetch \
       "$@" --max-stack-alloc=0 --stop-time=400ms 2>&1 \
     | grep -E "PASS|FAIL|error|ERROR|expected|MOVED|steps_done=|wedged" ; then :; fi
  echo
}

echo "################ producer-skew matrix (all must PASS) ################"
# The named configuration is the one the real system runs closest to.
run "skew: memory fast, units slow (prefetch far ahead)" \
    -gURAM_LAT=1  -gJOB_LAT=120 -gLAT_SKEW=11 -gSTRICT=true
run "skew: memory fast, units instant (prefetch never gets ahead)" \
    -gURAM_LAT=1  -gJOB_LAT=0   -gLAT_SKEW=0  -gSTRICT=true
run "skew: memory slow, units instant (D starves every step)" \
    -gURAM_LAT=23 -gJOB_LAT=0   -gLAT_SKEW=0  -gSTRICT=true
run "skew: memory slow, units slow" \
    -gURAM_LAT=23 -gJOB_LAT=60  -gLAT_SKEW=13 -gSTRICT=true
run "skew: turnaround gap on every unit" \
    -gURAM_LAT=3  -gJOB_LAT=9   -gLAT_SKEW=3  -gREADY_GAP=6 -gSTRICT=true

echo "################ completion discipline (all must PASS) ################"
run "done is a ONE-CYCLE PULSE, the withdrawn convention" \
    -gDONE_STYLE=1 -gJOB_LAT=5 -gLAT_SKEW=2
run "done is a level that drops on its own timer, not on the ack" \
    -gDONE_STYLE=2 -gDONE_HOLD=6 -gJOB_LAT=5 -gLAT_SKEW=2
run "done stays asserted PAST its ack (stale-done guard)" \
    -gSTALE_HOLD=5 -gJOB_LAT=4 -gLAT_SKEW=1 -gSTRICT=true
# The job must be LONG enough that the prefetch is already waiting when the
# ack lands, or D starves in S_WAITPF for longer than STALE_HOLD and never
# reaches S_ISSUE with `done` still high -- the guard then goes untested and
# the run passes for the wrong reason.  JOB_LAT=4 does exactly that.
run "unit re-arms on the ack while still driving done (stale-done guard)" \
    -gSTALE_HOLD=6 -gREADY_EARLY=true -gJOB_LAT=40 -gLAT_SKEW=0 -gURAM_LAT=1

echo "################ fault injection (each must raise its own code) #######"
run "stale job epoch echoed at step 137 -> ERR_EPOCH(7)" \
    -gEPOCH_BAD_AT=137 -gTOKENS=1
run "unit err at step 200 -> ERR_UNIT(1)" \
    -gERR_AT=200 -gTOKENS=1
run "unit err for ONE CYCLE then dropped while done is held -> ERR_UNIT(1)" \
    -gERR_AT=200 -gLATE_ERR=true -gTOKENS=1
run "region checker rejects step 64 -> ERR_LOCK(2)" \
    -gCHK_BAD_AT=64 -gTOKENS=1
run "host abort, a ONE-CYCLE pulse, at step 50 -> ERR_ABORT(8)" \
    -gABORT_AT=50 -gTOKENS=1
run "descriptor pad byte nonzero at step 300 -> ERR_DESC(3)" \
    -gPAD_BAD_AT=300 -gTOKENS=1
run "unit hangs past the watchdog, completes during the drain -> ERR_WDOG(4)" \
    -gHANG_AT=90 -gDONE_STYLE=1 -gJOB_LAT=5 -gTOKENS=1
