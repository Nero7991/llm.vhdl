#!/usr/bin/env bash
# Is a running pcieep build actually alive, or has it failed and orphaned?
#
# WHY THIS EXISTS
# ---------------
# MEASURED 2026-09-11.  A card build failed at 02:10:47 -- the parent Vivado hit
# FK33_SYNTH_MAX_MIN, fk33_assert_run_done raised, Vivado exited -- and was
# still holding 19.4 GB and 5.0 cores at 06:00, with its systemd unit reporting
# ActiveState=active and Result=success.  Nothing reported an ending, so the
# failure was invisible for four hours.
#
# The mechanism, measured by reading /proc/PID/fd/1 across the unit:
#   launch_runs spawns `loader -exec vrs ...` as a CHILD of the main Vivado, so
#   it inherits the main Vivado's stdout -- the pipe to `tee`.  The main Vivado
#   exits; the detached run survives still holding the pipe's write end; `tee`
#   never sees EOF; `bash` blocks on the pipeline; the cgroup never empties.
#
# So NEITHER of the obvious checks works:
#   - unit state       -> stays `active` forever, precisely BECAUSE it failed
#   - presence of vivado -> true in both the healthy and the failed case
#
# The signal is the PAIR: main Vivado gone WHILE run processes are still live.
# Both are resolved by /proc/PID/cwd, which a command line cannot spoof, and
# never by pgrep -f (which has killed the shell five times in this project).
#   main Vivado -> cwd is BUILD_ROOT
#   run Vivado  -> cwd is BUILD_ROOT/fk33_pcieep/fk33_pcieep.runs/<run>
#
#   ./build_health.sh          report, exit 0 healthy / 2 orphaned / 1 idle
#   BUILD_ROOT=... ./build_health.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

B="${BUILD_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep}"

main=0; run=0; rss=0; runcwd=""
for q in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    e=$(readlink "/proc/$q/exe" 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) ;; *) continue;; esac
    w=$(readlink "/proc/$q/cwd" 2>/dev/null)
    r=$(awk '/VmRSS/{print $2}' "/proc/$q/status" 2>/dev/null)
    # SCOPE BOTH TO THIS BUILD_ROOT.  Found by the mutant on 2026-09-11: an
    # unscoped */fk33_pcieep.runs/* counted runs belonging to ANY build tree,
    # so a wrong or stale BUILD_ROOT reported a healthy build as orphaned.
    case "$w" in
        "$B"/fk33_pcieep/fk33_pcieep.runs/*) run=$((run+1)); runcwd="$w";;
        "$B")                                main=$((main+1));;
        *) continue;;
    esac
    rss=$(( rss + ${r:-0} ))
done

printf 'BUILD_ROOT   %s\n' "$B"
printf 'main Vivado  %d (cwd = BUILD_ROOT)\n' "$main"
printf 'run Vivado   %d%s\n' "$run" "${runcwd:+  (${runcwd##*/})}"
printf 'total RSS    %.2f GB\n' "$(echo "scale=4; $rss/1048576" | bc)"

# TEST SEAM: exercises the DECISION branches only.  It deliberately cannot
# validate the MEASUREMENT above, which is what the scoping bug lived in.
main="${FK33_HEALTH_TEST_MAIN:-$main}"
run="${FK33_HEALTH_TEST_RUN:-$run}"

if (( main == 0 && run > 0 )); then
    echo
    echo 'ORPHANED.  The main Vivado is gone but the run is still going, which'
    echo 'means the build ALREADY FAILED and left the run behind.  Its systemd'
    echo 'unit will report active indefinitely and will never tell you this.'
    echo 'Stop it by unit, cgroup-wide:  systemctl --user stop <unit>.service'
    exit 2
fi
if (( main == 0 && run == 0 )); then
    echo; echo 'IDLE.  No Vivado for this BUILD_ROOT.  The lane is free.'
    exit 1
fi
echo; echo 'HEALTHY.  The main Vivado is alive, so the build still owns its run.'
exit 0
