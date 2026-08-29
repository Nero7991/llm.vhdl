#!/usr/bin/env bash
# ooc_compose_run.sh -- TRACK COMPOSE, 2026-08-29.
#
# Runs sim/ooc_compose_bcd.tcl for ONE target, in its own Vivado invocation,
# and records the peak resident set of the whole process tree.
#
# WHY ONE AT A TIME.  This is a 31 GB box on which systemd-oomd once killed 275
# processes in one event, and TRACK BUILD-E2E measured the full FK33 build
# peaking at 25.0 GiB.  Running two Vivados concurrently is how that repeats.
#
# WHY THE SENTINEL CHECK.  A Vivado run can print full success and then die on
# a Tcl error afterwards; two tracks were caught by this on 2026-08-29.  This
# script exits non-zero unless "COMPOSE_DONE <target>" is the recorded last
# action, regardless of what the last log line says.
#
# NO HARDWARE.  Synthesis only.  This script never opens a target, never calls
# program_hw_devices, and never touches /dev/xdma*.
set -u

TARGET="${1:?usage: ooc_compose_run.sh <target> <outdir> <rtldir>}"
OUT="${2:?}"
RTL="${3:?}"

VIVADO="${VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado}"
TCL="$(cd "$(dirname "$0")" && pwd)/ooc_compose_bcd.tcl"

mkdir -p "$OUT"
LOG="$OUT/run_$TARGET.log"
MEM="$OUT/mem_$TARGET.txt"

echo "== ooc_compose_run $TARGET : $(date -Is)" | tee "$LOG"
free -g | tee -a "$LOG"

COMPOSE_TARGET="$TARGET" COMPOSE_OUT="$OUT" COMPOSE_RTL="$RTL" \
  "$VIVADO" -mode batch -nojournal -notrace \
            -log "$OUT/vivado_$TARGET.log" \
            -source "$TCL" >>"$LOG" 2>&1 &
VPID=$!

# Sample the peak RSS of the whole tree.  /usr/bin/time -v reports the max of a
# single child rather than the tree, which understates a tool that forks.
PEAK=0
while kill -0 "$VPID" 2>/dev/null; do
    # Sum RSS over the FULL descendant tree, not just direct children: the
    # `vivado` entry point is a shell script that execs a loader, so the process
    # doing the work is a grandchild and `--ppid` alone reports ~7 MiB.
    S=$(ps -e -o pid=,ppid=,rss= 2>/dev/null | awk -v root="$VPID" '
        { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; n=NR }
        END {
          inset[root]=1
          for (pass=0; pass<12; pass++)
            for (i=1;i<=n;i++) if (inset[ppid[i]]) inset[pid[i]]=1
          s=0
          for (i=1;i<=n;i++) if (inset[pid[i]]) s+=rss[i]
          print s+0
        }')
    if [ "${S:-0}" -gt "$PEAK" ]; then PEAK=$S; fi
    sleep 5
done
wait "$VPID"; RC=$?

printf 'peak_rss_kib=%s peak_rss_gib=%.2f exit=%s\n' \
       "$PEAK" "$(echo "$PEAK" | awk '{print $1/1048576}')" "$RC" | tee "$MEM"

if grep -q "^COMPOSE_DONE $TARGET\$" "$LOG"; then
    echo "SENTINEL OK: COMPOSE_DONE $TARGET"
else
    echo "SENTINEL MISSING for $TARGET -- the run did NOT reach the end of the script."
    exit 9
fi
exit "$RC"
