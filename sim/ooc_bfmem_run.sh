#!/usr/bin/env bash
# sim/ooc_bfmem_run.sh -- 2026-09-19.
#
# THE AREA DRAW FOR rmsnorm_bf_mem, BESIDE ITS SAME-SESSION CONTROL.
#
# TWO POINTS, ONE SESSION, ONE TOOL AT A TIME:
#   bf_mem   rmsnorm_bf_mem  N=4096 LANES=4
#   rs_mem   rmsnorm_rs_mem  N=4096 LANES=4   the same-session control
#
# WHY THE CONTROL IS DRAWN AGAIN AND NOT QUOTED.  rs_mem's recorded figures
# (4,825 LUT / 1,629 FF / 6 BRAM / 40 DSP / WNS +0.971 at 5.0 ns,
# hw/fk33/results/rmsmux_2026-08-30/) were drawn from a tree three weeks old
# with this same flow.  Drawing it again in the same session makes the
# comparison a measurement rather than an argument, and shows the draw-to-draw
# scatter at this size (TRACK SCATTER measured 1.55x on a memory-like
# structure; RMSMUX measured its two identical draws of rs_mem agreeing).
#
# WHY sim/ooc_lutdiet_ports.tcl AND NOT A SCRIPT OF MY OWN.  That script drew
# the 4,825 this result is compared against.  It is used UNMODIFIED; this
# runner only sets its documented environment variables.  Its numbers come
# from report_utilization plus a get_cells census, never from the log.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BFMEM_OUT:-/mnt/storage/bfmem/area}"
VIV="${BFMEM_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
mkdir -p "$OUT"

# ---- THE RTL DIRECTORY IS THE UNIT'S CLOSURE, NOT ALL OF rtl/.
# sim/ooc_lutdiet_ports.tcl globs every .vhd in the directory it is given.
# MEASURED 2026-09-19 on the BC-250: with LUTDIET_RTL=$REPO/rtl the run
# read rtl/ooc_gdnadapt_top.vhd, a stale area-draw extraction that names an
# undeclared `b_const_hbm`, and Vivado ABORTED THE WHOLE synth_design after
# rmsnorm_bf_mem itself had synthesised cleanly (7 errors, none in the
# unit).  So the flow gets a directory of symlinks to the six files the two
# units need and nothing else.  Same flow, same script, narrower glob.
RTLC="$OUT/rtl_closure"
mkdir -p "$RTLC"
for f in util_pkg fixed_luts_pkg fixed_pkg vec_mem rmsnorm_bf_mem rmsnorm_rs_mem; do
  ln -sf "$REPO/rtl/$f.vhd" "$RTLC/$f.vhd"
done

# ---- THE PRESENCE GATE, by /proc/PID/exe and never by a command line.
# One tool shows FOUR processes under `pgrep -x vivado` and FIVE under an
# argv filter (forked synthesis workers inherit argv), and an argv filter also
# matches sibling shells that merely carry the text.  Gate on presence.
vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}
rss_now() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*)
      awk -v p=$p '/VmRSS/{s+=$2} END{print s}' /proc/$p/status;; esac
  done | awk '{s+=$1} END {printf "%.2f", s/1048576}'
}
if vivado_present; then
  echo "BFMEM_ABORT: a Vivado is already present here ($(rss_now) GB summed)."
  echo "One tool per box."
  exit 9
fi

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "BFMEM_ABORT: no vivado on PATH"; exit 9; }

echo "BFMEM_ENV host=$(hostname) repo=$REPO out=$OUT sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
free -g | head -2

draw() {   # $1 = top   $2 = tag
  local top="$1" tag="$2" log="$OUT/run_$2.log" peak=0 cur
  echo "=== BFMEM draw $tag ($top) begin $(date -Is) ==="
  ( cd "$OUT" && LUTDIET_TARGET="$top" LUTDIET_TAG="$tag" LUTDIET_OUT="$OUT" \
      LUTDIET_RTL="$RTLC" LUTDIET_GEN="N=4096 LANES=4" \
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
  # THE SENTINEL, line-anchored: the log carries the script's own text.
  if ! grep -qE "^LUTDIET_DONE $top" "$log"; then
    echo "BFMEM_FAIL $tag: no LUTDIET_DONE sentinel (rc=$rc, peak ${peak} GB)"
    tail -20 "$log"
    return 1
  fi
  echo "BFMEM_OK $tag rc=$rc peak_rss=${peak}GB"
  grep -E "^LUTDIET_(RESULT|SYNTH_VS_OPT|CENSUS)" "$log"
  return 0
}

rc=0
draw rmsnorm_bf_mem bf_mem || rc=1
draw rmsnorm_rs_mem rs_mem || rc=1
echo "=== BFMEM_TABLE (from result_*.csv, i.e. report_utilization + census) ==="
for t in bf_mem rs_mem; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s/^/$t: /"
done
echo "BFMEM_ALLDONE rc=$rc"
exit $rc
