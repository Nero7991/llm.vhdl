#!/usr/bin/env bash
# sim/run_ooc_cdc.sh -- guarded runner for sim/ooc_cdc.tcl.
#
# WHY A RUNNER AND NOT A BARE `vivado -source`.  Two reasons, both of which
# have already cost this project real time:
#
#  1. MEMORY.  A full shell build peaked at 22.81 GB RSS on this 31 GB box and
#     the 2026-07-04 systemd-oomd incident then killed 275 unrelated processes
#     in one cgroup.  Every invocation here runs inside a transient systemd
#     scope with a HARD MemoryMax, so a Vivado that misbehaves is killed alone.
#     Set MEMMAX to change it; default 6G, which is ~3x the largest OOC run
#     this script makes.
#
#  2. THE EXIT STATUS.  An incident on 2026-08-28 saw a Vivado invocation print
#     a success line and then abort silently five minutes later, with every
#     visible line saying success.  `vivado | tee` hands you tee's status, not
#     Vivado's.  ${PIPESTATUS[0]} is captured here and the run is only reported
#     OK when BOTH the exit status is 0 and the script's own DONE sentinel is
#     in the log.
#
# Usage: bash sim/run_ooc_cdc.sh <logfile> <unit> [k=v ...]
set -uo pipefail

LOG="${1:?usage: run_ooc_cdc.sh <logfile> <unit> [k=v ...]}"; shift
UNIT="${1:?unit}"; shift

MEMMAX="${MEMMAX:-6G}"
VIV="${VIV:-/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNDIR="${RUNDIR:-$(mktemp -d)}"
mkdir -p "$RUNDIR"

echo "guard: systemd-run --user --scope -p MemoryMax=$MEMMAX -p MemorySwapMax=0" >&2

# /usr/bin/time -v gives the peak RSS of the whole process tree, which is the
# number that has to be reported.  It is placed INSIDE the scope so the scope
# is what bounds it.
systemd-run --user --scope --quiet \
  -p MemoryMax="$MEMMAX" -p MemorySwapMax=0 \
  -- /usr/bin/time -v -o "$LOG.time" \
     "$VIV" -mode batch -nojournal -notrace \
            -log "$RUNDIR/vivado.log" -journal "$RUNDIR/vivado.jou" \
            -source "$HERE/ooc_cdc.tcl" -tclargs "$UNIT" "$@" \
  >"$LOG" 2>&1
rc=$?

peak=$(awk '/Maximum resident set size/{print $NF}' "$LOG.time" 2>/dev/null)
echo "run_ooc_cdc: rc=$rc peak_rss_kb=${peak:-unknown} log=$LOG" >&2

if [ "$rc" -ne 0 ]; then
  echo "run_ooc_cdc: VIVADO EXITED NON-ZERO ($rc) -- the log below is NOT a result" >&2
  tail -25 "$LOG" >&2
  exit "$rc"
fi
if ! grep -q "^OOC_CDC_DONE " "$LOG"; then
  echo "run_ooc_cdc: exit status 0 but the DONE sentinel is ABSENT -- treat as a failure" >&2
  tail -25 "$LOG" >&2
  exit 3
fi
exit 0
