#!/usr/bin/env bash
# ooc_lutdiet_run.sh -- TRACK LUTDIET, 2026-08-29.
#
# Runs sim/ooc_lutdiet_ports.tcl for ONE target, in its own Vivado invocation,
# and records the peak resident set of the whole process tree.
#
# WHY ONE AT A TIME.  31 GB box with a systemd-oomd history; TRACK COMPOSE
# measured 13.88 GiB peak on gdn_block and 12.09 on attn_block.  Two Vivados
# concurrently is how the 2026-07-04 incident repeats.
#
# WHY THE SENTINEL.  A Vivado run can print full success and then die on a Tcl
# error afterwards.  This exits 9 unless LUTDIET_DONE <target> is present.
#
# NO HARDWARE.  Synthesis only.
#
# usage: ooc_lutdiet_run.sh <tag> <top> <outdir> <rtldir> [generic ...]
set -u

TAG="${1:?usage: ooc_lutdiet_run.sh <tag> <top> <outdir> <rtldir> [generics]}"
TOP="${2:?}"
OUT="${3:?}"
RTL="${4:?}"
shift 4
GEN="$*"

VIVADO="${VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado}"
TCL="$(cd "$(dirname "$0")" && pwd)/ooc_lutdiet_ports.tcl"

mkdir -p "$OUT"
LOG="$OUT/run_$TAG.log"
MEM="$OUT/mem_$TAG.txt"

echo "== ooc_lutdiet_run tag=$TAG top=$TOP gen='$GEN' : $(date -Is)" | tee "$LOG"
df -h / /mnt/storage | tee -a "$LOG"
free -g | tee -a "$LOG"

LUTDIET_TAG="$TAG" LUTDIET_TARGET="$TOP" LUTDIET_OUT="$OUT" \
LUTDIET_RTL="$RTL" LUTDIET_GEN="$GEN" \
  "$VIVADO" -mode batch -nojournal -notrace \
            -log "$OUT/vivado_$TAG.log" \
            -source "$TCL" >>"$LOG" 2>&1 &
VPID=$!

# Peak RSS over the FULL descendant tree.  `ps --ppid` reported 7 MiB for a run
# that peaked at 13.9 GiB (COMPOSE, 2026-08-29): the vivado entry point is a
# shell script that execs a loader, so the process doing the work is a
# grandchild.
PEAK=0
while kill -0 "$VPID" 2>/dev/null; do
    S=$(ps -e -o pid=,ppid=,rss= 2>/dev/null | awk -v root="$VPID" '
        { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; n=NR }
        END { inset[root]=1
              for (pass=0; pass<12; pass++)
                for (i=1;i<=n;i++) if (inset[ppid[i]]) inset[pid[i]]=1
              s=0; for (i=1;i<=n;i++) if (inset[pid[i]]) s+=rss[i]; print s+0 }')
    if [ "${S:-0}" -gt "$PEAK" ]; then PEAK=$S; fi
    sleep 5
done
wait "$VPID"; RC=$?

printf 'tag=%s peak_rss_kib=%s peak_rss_gib=%.2f exit=%s\n' \
       "$TAG" "$PEAK" "$(echo "$PEAK" | awk '{print $1/1048576}')" "$RC" | tee "$MEM"

if grep -q "^LUTDIET_DONE $TOP\$" "$LOG"; then
    echo "SENTINEL OK: LUTDIET_DONE $TOP"
else
    echo "SENTINEL MISSING for $TAG -- the run did NOT reach the end of the script."
    exit 9
fi
exit "$RC"
