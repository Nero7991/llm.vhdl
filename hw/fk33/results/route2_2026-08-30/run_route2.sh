#!/usr/bin/env bash
# run_route2.sh -- TRACK ROUTE2, 2026-08-30.  Driver for sim/ooc_compose4_pnr.tcl.
#
# NO HARDWARE.  synth_design / opt_design / place_design / route_design /
# report_* only.  Nothing here opens a cable, a target or a device.
#
#   run_route2.sh <stage> <tag> [extra env]
#
# THE COMPLETION GATE IS THE SENTINEL, NOT THE WAITER.  `C4_DONE <stage> <tag>`
# is the last thing the Tcl prints, and Vivado can print full success and then
# die on a Tcl error afterwards.  A harness reporting that it finished waiting
# is a fact about the harness, not about the job.  So this script requires BOTH
# the sentinel AND the report file, and exits non-zero otherwise.
set -u
STAGE="${1:?stage}"; TAG="${2:?tag}"
ROOT=/mnt/storage/route2_2026-08-30
LOG="$ROOT/log/${STAGE}_${TAG}.log"
export C4_STAGE="$STAGE" C4_TAG="$TAG"
export C4_OUT="${C4_OUT:-$ROOT/out}"
export C4_RTL="${C4_RTL:-$ROOT/tree/rtl}"
export C4_FK33RTL="${C4_FK33RTL:-$ROOT/tree/hw/fk33/rtl}"
export C4_THREADS="${C4_THREADS:-8}"
mkdir -p "$C4_OUT" "$ROOT/log"

# ONE VIVADO PER BOX.  Gate on PRESENCE via /proc/PID/exe, never on a count and
# never on `ps ... args=`: MEASURED 2026-08-30 that the argv filter matches
# sibling bash and grep processes, and that one tool shows as four or five.
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  e=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
  case "$e" in *unwrapped/lnx64.o/vivado*)
    echo "ROUTE2 ABORT: a Vivado is already running (pid $p)."; exit 3;; esac
done

source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$ROOT/tree"
systemd-run --user --scope --unit="route2-${STAGE}-${TAG}-$$" \
  -p MemoryHigh="${ROUTE2_MEMHIGH:-22G}" \
  vivado -mode batch -nojournal -notrace \
         -log "$ROOT/log/vivado_${STAGE}_${TAG}.log" \
         -source "$ROOT/tree/sim/ooc_compose4_pnr.tcl" >"$LOG" 2>&1
RC=$?
echo "ROUTE2 vivado_rc=$RC"
if ! grep -q "^C4_DONE $STAGE $TAG\$" "$LOG"; then
  echo "ROUTE2 FAIL: sentinel 'C4_DONE $STAGE $TAG' absent from $LOG"; exit 4
fi
echo "ROUTE2 SENTINEL OK"
exit $RC
