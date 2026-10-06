#!/bin/bash
# hw/jc/loader/run_capped.sh -- run one command as a transient systemd --user unit with a
# MemoryHigh cap and a swap guard, sampling the unit's own cgroup while it runs.
#
#   run_capped.sh <unit> <MemoryHigh> <swap_kill_bytes> <logdir> <cmd...>
#
# Works locally and over ssh (`ssh host 'bash -s' -- <args> < run_capped.sh`, the
# BC-250's login shell is fish). CLAUDE.md traps handled here:
#  * systemd-run --user over ssh can silently not cap: the cap is READ BACK from the
#    unit and from the cgroup's memory.high, and both are logged.
#  * a capped job's memory.peak is the cap, not the appetite: memory.current,
#    memory.swap.current and memory.peak are sampled every 2 s while it runs.
#  * system-wide MemAvailable and SwapFree (/proc/meminfo) are sampled beside the unit's
#    counters, because the budget is the box's, not the unit's (Task 10 fix round 1).
#  * swap in use is the leading indicator: the unit is stopped once
#    memory.swap.current passes <swap_kill_bytes> (JCL_SWAPGUARD_KILL in the log).
# The exit status is the unit's; a caller still gates on the job's own sentinel.
set -uo pipefail
UNIT="$1"; MEMHIGH="$2"; SWAPKILL="$3"; LOGDIR="$4"; shift 4
mkdir -p "$LOGDIR"
LOG="$LOGDIR/${UNIT}.samples.log"
: > "$LOG"

systemd-run --user --unit="${UNIT}.service" -p "MemoryHigh=${MEMHIGH}" \
  --working-directory="$LOGDIR" --wait --collect -- "$@" &
RUNPID=$!

CGPATH=""
for i in $(seq 1 60); do
  CG=$(systemctl --user show "${UNIT}.service" -p ControlGroup --value 2>/dev/null)
  if [ -n "$CG" ] && [ -d "/sys/fs/cgroup${CG}" ]; then CGPATH="/sys/fs/cgroup${CG}"; break; fi
  sleep 0.5
done
echo "unit=${UNIT}.service cgroup=$CGPATH requested_cap=${MEMHIGH} swap_kill=${SWAPKILL}" | tee -a "$LOG"
echo "readback MemoryHigh=$(systemctl --user show "${UNIT}.service" -p MemoryHigh --value 2>/dev/null)" | tee -a "$LOG"
[ -n "$CGPATH" ] && echo "readback memory.high=$(cat "$CGPATH/memory.high" 2>/dev/null)" | tee -a "$LOG"

PEAK_CUR=0; PEAK_SWAP=0; LASTPEAK=0; MIN_AVAIL=""; MIN_SFREE=""
while kill -0 "$RUNPID" 2>/dev/null; do
  if [ -n "$CGPATH" ] && [ -r "$CGPATH/memory.current" ]; then
    cur=$(cat "$CGPATH/memory.current" 2>/dev/null || echo 0)
    swp=$(cat "$CGPATH/memory.swap.current" 2>/dev/null || echo 0)
    pk=$(cat "$CGPATH/memory.peak" 2>/dev/null || echo 0)
    [ "$cur" -gt "$PEAK_CUR" ] 2>/dev/null && PEAK_CUR=$cur
    [ "$swp" -gt "$PEAK_SWAP" ] 2>/dev/null && PEAK_SWAP=$swp
    [ "$pk" -gt "$LASTPEAK" ] 2>/dev/null && LASTPEAK=$pk
    mavail=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
    sfree=$(awk '/^SwapFree:/{print $2*1024}' /proc/meminfo)
    { [ -z "$MIN_AVAIL" ] || [ "$mavail" -lt "$MIN_AVAIL" ]; } && MIN_AVAIL=$mavail
    { [ -z "$MIN_SFREE" ] || [ "$sfree" -lt "$MIN_SFREE" ]; } && MIN_SFREE=$sfree
    echo "sample $(date +%s) current=$cur swap.current=$swp memory.peak=$pk sys.MemAvailable=$mavail sys.SwapFree=$sfree" >> "$LOG"
    if [ "$swp" -gt "$SWAPKILL" ] 2>/dev/null; then
      echo "JCL_SWAPGUARD_KILL swap.current=$swp > $SWAPKILL" | tee -a "$LOG"
      systemctl --user stop "${UNIT}.service"
    fi
  fi
  sleep 2
done
wait "$RUNPID"; RC=$?
echo "sampled_peak_current=$PEAK_CUR sampled_peak_swap=$PEAK_SWAP last_memory.peak=$LASTPEAK sys_min_MemAvailable=$MIN_AVAIL sys_min_SwapFree=$MIN_SFREE" | tee -a "$LOG"
echo "RC=$RC" | tee -a "$LOG"
exit $RC
