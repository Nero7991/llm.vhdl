#!/bin/bash
# hw/jc/pinfinder/run_capped.sh -- run one command under systemd-run --user
# with a MemoryHigh cap, on the BC-250's fish shell (invoke as
# `ssh ... 'bash -s' -- <unit> <memhigh> <cmd...> < run_capped.sh`).
#
# CLAUDE.md's trap: systemd-run --user over ssh can silently not cap, so this
# reads the cap back from the unit's own cgroup, and samples memory.current /
# memory.swap.current / memory.peak every 2 s WHILE THE JOB RUNS (backgrounded
# so the poll loop and the job are concurrent) -- a post-exit read is too late
# because the transient cgroup can already be gone.
set -uo pipefail
UNIT="$1"; MEMHIGH="$2"; shift 2
LOG="/home/orencollaco/jc_pinfinder_build/${UNIT}.samples.log"
: > "$LOG"

systemd-run --user --unit="${UNIT}.service" -p "MemoryHigh=${MEMHIGH}" --wait -- "$@" &
RUNPID=$!

CGPATH=""
for i in $(seq 1 30); do
  CGROUP=$(systemctl --user show "${UNIT}.service" -p ControlGroup --value 2>/dev/null)
  if [ -n "$CGROUP" ] && [ -d "/sys/fs/cgroup${CGROUP}" ]; then
    CGPATH="/sys/fs/cgroup${CGROUP}"
    break
  fi
  sleep 0.5
done
echo "unit=${UNIT}.service cgroup=$CGPATH requested_cap=${MEMHIGH}" | tee -a "$LOG"
echo "readback MemoryHigh=$(systemctl --user show "${UNIT}.service" -p MemoryHigh --value 2>/dev/null)" | tee -a "$LOG"

PEAK_CUR=0
PEAK_SWAP=0
while kill -0 "$RUNPID" 2>/dev/null; do
  if [ -n "$CGPATH" ] && [ -r "$CGPATH/memory.current" ]; then
    cur=$(cat "$CGPATH/memory.current" 2>/dev/null || echo 0)
    swap=$(cat "$CGPATH/memory.swap.current" 2>/dev/null || echo 0)
    peak=$(cat "$CGPATH/memory.peak" 2>/dev/null || echo 0)
    [ "$cur" -gt "$PEAK_CUR" ] 2>/dev/null && PEAK_CUR=$cur
    [ "$swap" -gt "$PEAK_SWAP" ] 2>/dev/null && PEAK_SWAP=$swap
    echo "sample $(date +%s) current=$cur swap.current=$swap memory.peak=$peak" | tee -a "$LOG"
  fi
  sleep 2
done
wait "$RUNPID"
RC=$?
echo "sampled_peak_current=$PEAK_CUR sampled_peak_swap=$PEAK_SWAP" | tee -a "$LOG"
echo "RC=$RC" | tee -a "$LOG"
exit $RC
