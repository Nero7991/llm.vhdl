#!/usr/bin/env bash
# sim/ooc_swgmem_run.sh -- 2026-09-19.
#
# THE AREA DRAW FOR swiglu_mem AT THE 9B SHAPE.  Modelled on
# sim/ooc_bfmem_run.sh (the norm track), same flow, same script, same
# reporting: sim/ooc_lutdiet_ports.tcl UNMODIFIED, numbers from
# report_utilization plus a get_cells census, never from the log.
#
# ONE POINT:
#   swg_mem   swiglu_mem  N=12288 Q=12    the N rtl/llama_top.vhd's `gsr`
#                                         elaborates on the card (SHAPE.ffn)
#
# The period is the script's 5.0 ns.  The card's engine clock is 75 MHz
# (13.3 ns, FK33_ENG_CORE_MHZ=75 in the shipping build), so a negative WNS
# at 5.0 ns is reported as what it is -- the OOC harness's period -- and
# NOT as a card timing verdict.  SWGMEM_PERIOD overrides it for a second
# draw at the card's period.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${SWGMEM_OUT:-/mnt/storage/swgmem/area}"
VIV="${SWGMEM_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
mkdir -p "$OUT"

# ---- THE RTL DIRECTORY IS THE UNIT'S CLOSURE, NOT ALL OF rtl/.  See
# sim/ooc_bfmem_run.sh for the measured reason (a stale extraction in rtl/
# aborted a whole synth_design).
RTLC="$OUT/rtl_closure"
mkdir -p "$RTLC"
for f in util_pkg fixed_luts_pkg fixed_pkg vec_mem swiglu_mem; do
  ln -sf "$REPO/rtl/$f.vhd" "$RTLC/$f.vhd"
done

# ---- THE PRESENCE GATE, by /proc/PID/exe and never by a command line.
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
  echo "SWGMEM_ABORT: a Vivado is already present here ($(rss_now) GB summed)."
  echo "One tool per box."
  exit 9
fi

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "SWGMEM_ABORT: no vivado on PATH"; exit 9; }

echo "SWGMEM_ENV host=$(hostname) repo=$REPO out=$OUT sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
free -g | head -2

# A period override: sim/ooc_lutdiet_ports.tcl hardcodes 5.0; a copy with the
# one line changed is drawn instead when SWGMEM_PERIOD is set.  The copy is
# byte-identical otherwise (diffed below), so the flow is the same flow.
TCL="$REPO/sim/ooc_lutdiet_ports.tcl"
if [ -n "${SWGMEM_PERIOD:-}" ]; then
  TCL="$OUT/ooc_lutdiet_ports_p${SWGMEM_PERIOD}.tcl"
  sed "s/^set period 5.0$/set period ${SWGMEM_PERIOD}/" "$REPO/sim/ooc_lutdiet_ports.tcl" > "$TCL"
  echo "SWGMEM_PERIOD $SWGMEM_PERIOD: $(diff "$REPO/sim/ooc_lutdiet_ports.tcl" "$TCL" | grep -c '^[<>]') lines differ from the shipping script"
fi

draw() {   # $1 = top   $2 = tag   $3 = generics
  local top="$1" tag="$2" log="$OUT/run_$2.log" peak=0 cur
  echo "=== SWGMEM draw $tag ($top $3) begin $(date -Is) ==="
  ( cd "$OUT" && LUTDIET_TARGET="$top" LUTDIET_TAG="$tag" LUTDIET_OUT="$OUT" \
      LUTDIET_RTL="$RTLC" LUTDIET_GEN="$3" \
      LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
      vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
             -source "$TCL" ) > "$log" 2>&1 &
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
    echo "SWGMEM_FAIL $tag: no LUTDIET_DONE sentinel (rc=$rc, peak ${peak} GB)"
    tail -20 "$log"
    return 1
  fi
  echo "SWGMEM_OK $tag rc=$rc peak_rss=${peak}GB"
  grep -E "^LUTDIET_(RESULT|SYNTH_VS_OPT|CENSUS)" "$log"
  return 0
}

rc=0
draw swiglu_mem "swg_mem${SWGMEM_PERIOD:+_p$SWGMEM_PERIOD}" "N=12288 Q=12" || rc=1
echo "=== SWGMEM_TABLE (from result_*.csv, i.e. report_utilization + census) ==="
for f in "$OUT"/result_swg_mem*.csv; do
  [ -f "$f" ] && tail -1 "$f" | sed "s|^|$(basename "$f"): |"
done
echo "SWGMEM_ALLDONE rc=$rc"
exit $rc
