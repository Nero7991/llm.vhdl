#!/usr/bin/env bash
# ooc_nwrom_loopfix_run.sh -- TRACK NWROM, 2026-08-29.
#
# The same runner contract as TRACK LUTDIET's `sim/ooc_lutdiet_run.sh` -- same
# environment variables, same peak-RSS sampling over the whole descendant tree,
# same `LUTDIET_DONE` sentinel gate -- but sourcing `sim/ooc_nwrom_loopfix.tcl`,
# which raises Vivado's elaboration loop limit and then sources LUTDIET's
# `ooc_lutdiet_ports.tcl` UNMODIFIED.
#
# It exists because `ooc_lutdiet_run.sh` derives its Tcl path from its own
# directory and offers no override, and LUTDIET's files must not be edited.
#
# NO HARDWARE.  Synthesis only.
#
# usage: ooc_nwrom_loopfix_run.sh <tag> <top> <outdir> <rtldir> [generic ...]
set -u

TAG="${1:?usage: ooc_nwrom_loopfix_run.sh <tag> <top> <outdir> <rtldir> [gen]}"
TOP="${2:?}"
OUT="${3:?}"
RTL="${4:?}"
shift 4
GEN="$*"

VIVADO="${VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado}"
TCL="$(cd "$(dirname "$0")" && pwd)/ooc_nwrom_loopfix.tcl"

mkdir -p "$OUT"
LOG="$OUT/run_$TAG.log"
MEM="$OUT/mem_$TAG.txt"

echo "== ooc_nwrom_loopfix_run tag=$TAG top=$TOP gen='$GEN' : $(date -Is)" | tee "$LOG"
free -g | tee -a "$LOG"

LUTDIET_TAG="$TAG" LUTDIET_TARGET="$TOP" LUTDIET_OUT="$OUT" \
LUTDIET_RTL="$RTL" LUTDIET_GEN="$GEN" \
  "$VIVADO" -mode batch -nojournal -notrace \
            -log "$OUT/vivado_$TAG.log" \
            -source "$TCL" >>"$LOG" 2>&1 &
VPID=$!

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
