#!/usr/bin/env bash
# sim/ooc_rmsmux_run.sh -- TRACK RMSMUX, 2026-08-30.
#
# THE AREA DRAW FOR rmsnorm_rs_mem, AND THE SCATTER BETWEEN TWO OF THEM.
#
# THREE POINTS, ONE SESSION, ONE TOOL AT A TIME:
#   mem_d1  rmsnorm_rs_mem  N=4096 LANES=4
#   mem_d2  rmsnorm_rs_mem  N=4096 LANES=4   IDENTICAL COMMAND to mem_d1
#   ctl_rs  rmsnorm_rs      N=4096 LANES=4   the same-session control
#
# WHY mem_d2 IS NOT A WASTED RUN.  TRACK SCATTER MEASURED 82,597 to 128,065
# CLB LUT across five draws of a memory-like structure on this project, TWO OF
# THEM FROM THE IDENTICAL COMMAND -- a 1.55x spread.  Every area conclusion
# tonight is bounded by that number, and nobody has measured whether it applies
# at this size.  mem_d1 vs mem_d2 IS that measurement, and it is reported as a
# first-class result rather than averaged away.
#
# WHY THE CONTROL IS DRAWN HERE AND NOT QUOTED.  The composed 43,213 LUT for
# `gvr.u_rms` was drawn with NORM_W_IMAGE EMPTY (compose4_top.vhd:19), so its
# `w_mant` is a foldable constant and TRACK NWFIX measured that fold at 17,367
# LUT.  It is NOT the comparable baseline for a standalone OOC draw.  The
# comparable baseline is `rmsnorm_rs` drawn standalone in the same session with
# the same flow, which is what ctl_rs is.
#
# WHY sim/ooc_lutdiet_ports.tcl AND NOT A SCRIPT OF MY OWN.  That script drew
# the 4,798 and the 40,804 this result is compared against.  Using a different
# flow would make the comparison an argument instead of a measurement.  It is
# TRACK LUTDIET's file and is used UNMODIFIED; this runner only sets its
# documented environment variables.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${RMSMUX_OUT:-/mnt/storage/rmsmux/area}"
VIV="${RMSMUX_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
mkdir -p "$OUT"

# ---- THE PRESENCE GATE.  Never a count, by any pattern: one tool shows FOUR
# processes under `pgrep -x vivado` (a chain of bash launchers also called
# vivado) and FIVE under the unwrapped-path filter (forked parallel-synthesis
# workers inherit the parent's argv).  Gate on presence; SUM RSS for the
# footprint.  MEASURED: one real load is 10.85 GB of the BC-250's 14 GB, so an
# idle free figure is not the number that matters.
rss_now() {
  ps -eo rss,args | grep 'unwrapped/lnx64.o/vivado' | grep -v grep \
    | awk '{s+=$1} END {printf "%.2f", s/1048576}'
}
if ps -eo args | grep -q '[u]nwrapped/lnx64.o/vivado'; then
  echo "RMSMUX_ABORT: a Vivado is already present here ($(rss_now) GB summed)."
  echo "One tool per box.  Two on this one OOMs it rather than merely slowing it."
  exit 9
fi

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "RMSMUX_ABORT: no vivado on PATH"; exit 9; }

echo "RMSMUX_ENV host=$(hostname) repo=$REPO out=$OUT"
free -g | head -2
df -h /mnt/storage 2>/dev/null | tail -1

draw() {   # $1 = top   $2 = tag
  local top="$1" tag="$2" log="$OUT/run_$2.log" peak=0 cur
  echo "=== RMSMUX draw $tag ($top) begin $(date -Is) ==="
  ( cd "$OUT" && LUTDIET_TARGET="$top" LUTDIET_TAG="$tag" LUTDIET_OUT="$OUT" \
      LUTDIET_RTL="$REPO/rtl" LUTDIET_GEN="N=4096 LANES=4" \
      LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
      vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
             -source "$REPO/sim/ooc_lutdiet_ports.tcl" ) > "$log" 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    sleep 10
  done
  wait $pid; local rc=$?
  echo "$peak" > "$OUT/mem_$tag.txt"
  # THE SENTINEL.  Vivado can print full success and then die on a Tcl error,
  # so the gate is the sentinel and never the last log line or the exit code.
  if ! grep -q "LUTDIET_DONE $top" "$log"; then
    echo "RMSMUX_FAIL $tag: no LUTDIET_DONE sentinel (rc=$rc, peak ${peak} GB)"
    tail -20 "$log"
    return 1
  fi
  echo "RMSMUX_OK $tag rc=$rc peak_rss=${peak}GB"
  grep -E "LUTDIET_(RESULT|SYNTH_VS_OPT|CENSUS)" "$log"
  return 0
}

rc=0
draw rmsnorm_rs_mem mem_d1 || rc=1
draw rmsnorm_rs_mem mem_d2 || rc=1
draw rmsnorm_rs     ctl_rs || rc=1

echo "=== RMSMUX summary ==="
for t in mem_d1 mem_d2 ctl_rs; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s@^@$t,@"
done
echo "RMSMUX_RUN_DONE rc=$rc"
exit $rc
