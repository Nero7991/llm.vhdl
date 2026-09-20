#!/usr/bin/env bash
# sim/ooc_bmover_run.sh -- TRACK BMOVERSYN, 2026-09-20.
#
# FOUR OOC DRAWS OF gdn_state_store AT THE 9B GEOMETRY, one Vivado at a
# time, each with a primitive census and a synthesis-stage timing estimate at
# 13.333 ns and 5.0 ns (sim/ooc_bmover.tcl).  Modelled on
# sim/ooc_bfmem_run.sh and sim/ooc_swgmem_run.sh: closure directory of
# symlinks, presence gate by /proc/PID/exe, line-anchored sentinel, RSS
# sampler, numbers from report_utilization plus a get_cells census.
#
#   ctrl     PIPE=false WIDE=false MAXOUT=4   the shipping store
#   wp4      PIPE=true  WIDE=true  MAXOUT=4   both levers, shipping depth
#   wp8      PIPE=true  WIDE=true  MAXOUT=8   both levers, BMOVER's ask
#   w4       PIPE=false WIDE=true  MAXOUT=4   WIDE alone, to split the cost
#
# THE GENERICS ARE llama_top's u_state GENERIC MAP AT 9B, read from
# rtl/llama_top.vhd (BST_* derived from SHAPE) and hw/fk33/rtl/fk33_card.vhd
# (B_CONST_HBM => true): VAL_HEADS 32, DIM 128, RECUR_LANES 4, LAYERS 24
# (32 blocks - 8 attention), KEY_HEADS 16, KCONV 4, CONV_LANES 4,
# MANT/EXP/CONV bytes 1048576/4096/49152, LAYER_STRIDE 1101824, MAXB 16
# (min4 of 16 and the three /32 figures), CONST_EN true, CONST_STRIDE and
# CONST_BYTES 66048.  Every one but CONST_EN equals the entity default and is
# passed anyway, so the draw does not depend on a default staying put.
#
# MEMORY.  Each draw runs under `systemd-run --user --scope -p MemoryHigh=8G`
# when that works on the box, and the cgroup's memory.peak is read back.  A
# peak AT the cap is the cap, not the appetite (CLAUDE.md); the runner says
# which.  The RSS sampler runs regardless as the fallback figure.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BMOVER_OUT:-$HOME/bmover_ooc}"
VIV="${BMOVER_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${BMOVER_CAP:-8G}"
ONLY="${BMOVER_ONLY:-ctrl wp4 wp8 w4}"
mkdir -p "$OUT"

# ---- THE RTL DIRECTORY IS THE UNIT'S CLOSURE, NOT ALL OF rtl/ (see
# sim/ooc_bfmem_run.sh for the measured reason).  gdn_state_store's closure
# is itself, its four gdn_state_axi movers (util_pkg), and the four memories.
RTLC="$OUT/rtl_closure"
mkdir -p "$RTLC"
for f in util_pkg gdn_state_mem gdn_exp_mem gdn_conv_tap_mem gdn_conv_w_mem \
         gdn_state_axi gdn_state_store; do
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
# Wait for a free lane, re-checking every 2 minutes: another track may run a
# short --bd-only here.  Presence is a lane check, not a queue; this runner
# is the only multi-draw job and it chains its own draws sequentially.
while vivado_present; do
  echo "BMOVER_WAIT $(date -Is): a Vivado is present here ($(rss_now) GB summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "BMOVER_ABORT: no vivado on PATH"; exit 9; }

GEN9B="VAL_HEADS=32 DIM=128 RECUR_LANES=4 LAYERS=24 KEY_HEADS=16 KCONV=4 CONV_LANES=4 MANT_BYTES=1048576 EXP_BYTES=4096 CONV_BYTES=49152 LAYER_STRIDE=1101824 MAXB=16 CONST_EN=true CONST_STRIDE=66048 CONST_BYTES=66048"

echo "BMOVER_ENV host=$(hostname) repo=$REPO out=$OUT cap=$CAP sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
free -m | head -2

# Does systemd-run --user work here?  Probe once; fall back to plain.
USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "BMOVER_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "BMOVER_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

draw() {   # $1 = tag   $2 = extra generics
  local tag="$1" extra="$2" log="$OUT/run_$1.log" peak=0 cur unit="bmover_$1_$$"
  local t0=$(date +%s)
  echo "=== BMOVER draw $tag ($extra) begin $(date -Is) ==="
  rm -f "$OUT/cgroup_$tag.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && BMOVER_TAG="$tag" BMOVER_OUT="$OUT" BMOVER_RTL="$RTLC" \
        BMOVER_GEN="$GEN9B $extra" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$tag.log' -source '$REPO/sim/ooc_bmover.tcl'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && BMOVER_TAG="$tag" BMOVER_OUT="$OUT" BMOVER_RTL="$RTLC" \
        BMOVER_GEN="$GEN9B $extra" \
        vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
               -source "$REPO/sim/ooc_bmover.tcl" ) > "$log" 2>&1 &
  fi
  local pid=$!
  local cgpeak="NA" cgdir=""
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    # memory.peak must be read while the scope exists; it vanishes at exit.
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_$tag.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_$tag.txt")"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
    fi
    sleep 5
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "${CAP%G}G" 2>/dev/null || echo 0)
  local cgmb="NA" atcap="no"
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    # within 1% of the cap: the cap held it, so this is not the appetite
    [ "$capb" -gt 0 ] && [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap="YES"
  fi
  echo "peak_rss_gb=$peak cgroup_peak_mb=$cgmb at_cap=$atcap wall_s=$wall rc=$rc" > "$OUT/mem_$tag.txt"
  # THE SENTINEL, line-anchored: the log carries the script's own text.
  if ! grep -qE "^BMOVER_DONE $tag\$" "$log"; then
    echo "BMOVER_FAIL $tag: no BMOVER_DONE sentinel (rc=$rc, peak ${peak} GB, cgroup ${cgmb} MB, wall ${wall} s)"
    tail -20 "$log"
    return 1
  fi
  echo "BMOVER_OK $tag rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^BMOVER_(RESULT|SYNTH_VS_OPT|CENSUS|TIMING_ESTIMATE)" "$log"
  # The two lying messages, counted so the census can be reconciled.
  echo "BMOVER_LOGMSG $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_$tag.log")"
  grep -E 'Synth 8-10226|Synth 8-7186' "$OUT/vivado_$tag.log" | head -5
  return 0
}

rc=0
for t in $ONLY; do
  case "$t" in
    ctrl) draw ctrl "PIPE=false WIDE=false MAXOUT=4" || rc=1;;
    wp4)  draw wp4  "PIPE=true WIDE=true MAXOUT=4"   || rc=1;;
    wp8)  draw wp8  "PIPE=true WIDE=true MAXOUT=8"   || rc=1;;
    w4)   draw w4   "PIPE=false WIDE=true MAXOUT=4"  || rc=1;;
    *) echo "BMOVER_ABORT unknown tag $t"; rc=1;;
  esac
done
echo "=== BMOVER_TABLE (from result_*.csv, i.e. report_utilization + census) ==="
for t in $ONLY; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s/^/$t: /"
  [ -f "$OUT/mem_$t.txt" ] && sed "s/^/$t: /" "$OUT/mem_$t.txt"
done
echo "BMOVER_ALLDONE rc=$rc"
exit $rc
