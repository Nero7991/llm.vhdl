#!/usr/bin/env bash
# 27B AREA PROBE on the BC-250 (2026-09-23): synthesis-only OOC of the two
# blocks the 27B shape grows, each with its 9B control on the SAME tree and
# SAME script, one Vivado at a time under MemoryHigh=11G with the cgroup read
# back from the scope's own files.  No hardware.  Sentinel: PROBE27_DONE.
set -u
ROOT="${ROOT:-$HOME/GitHub/llama.vhdl}"
OUT="${OUT:-$HOME/probe27b/out}"
VIV="${VIV:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${CAP:-11G}"
mkdir -p "$OUT"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "PROBE27_ABORT no vivado"; exit 9; }
echo "PROBE27_ENV host=$(hostname) root=$ROOT out=$OUT cap=$CAP tree=$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
vivado_present() { local p e; for p in $(ls /proc | grep -E '^[0-9]+$'); do e=$(readlink /proc/$p/exe 2>/dev/null) || continue; case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac; done; return 1; }
USE_SD=0; if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then USE_SD=1; fi
echo "PROBE27_CGROUP systemd-run=$USE_SD"
# gdn_block at 27B: the script hardcodes the 9B generics, so a sed copy is the 27B arm.
# MEASURED 2026-09-23: the copy MUST live in $ROOT/sim, because the script
# derives the repo root from its own location (`pfRoot`, ooc_gdn_block.tcl:22)
# and refuses anywhere else; the first draft put it in $OUT and the arm died in
# 12 s with rc=1 (rerun_gdn27.sh is the chained rerun).
GDN27="$ROOT/sim/ooc_gdn_block_27b_probe.tcl"
sed -e 's/VAL_HEADS=32/VAL_HEADS=48/' -e 's/LAYERS=24/LAYERS=48/' "$ROOT/sim/ooc_gdn_block.tcl" > "$GDN27"
grep -c 'VAL_HEADS=48' "$GDN27" | sed 's/^/PROBE27_GDN27_SED_HITS /'
CGEN="HEAD_DIM=256 N_KVH=4 KV_BLOCK=32 N_ROT=64 POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true SWEEP_PIPE=false SCORE_EARLY=false SCORE_HDR_TREE=0"
run_arm() {  # tag script sentinel [ENV=VAL ...]
  local tag="$1" script="$2" sentinel="$3"; shift 3
  local log="$OUT/$tag.log" unit="p27_${tag}_$$" t0=$(date +%s)
  while vivado_present; do echo "PROBE27_LANE_BUSY $(date -Is)"; sleep 120; done
  echo "=== PROBE27 arm $tag begin $(date -Is) ==="
  rm -f "$OUT/cgroup_$tag.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && env "$@" systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$tag.log' -source '$script'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && env "$@" vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" -source "$script" ) > "$log" 2>&1 &
  fi
  local pid=$! cgdir="" peak=NA swap=NA
  while kill -0 $pid 2>/dev/null; do
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_$tag.txt" ]; then cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_$tag.txt")"; [ -r "$cgdir/memory.high" ] && echo "PROBE27_CAP $tag memory.high=$(cat "$cgdir/memory.high")"; fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then peak=$(cat "$cgdir/memory.peak"); s=$(cat "$cgdir/memory.swap.current" 2>/dev/null || echo 0); [ "$swap" = NA ] || [ "$s" -gt "$swap" ] && swap=$s; fi
    sleep 10
  done
  wait $pid; local rc=$?
  echo "PROBE27_ARM $tag rc=$rc wall=$(( $(date +%s) - t0 ))s memory.peak=$peak swap.peak=$swap sentinel=$(grep -c "^$sentinel" "$log")"
  grep -E '^\| (CLB LUTs|CLB Registers|CARRY8|F7 Muxes|F8 Muxes|Block RAM Tile|URAM|DSPs) ' "$log" | head -8 | sed "s/^/PROBE27_UTIL $tag /"
  grep -E '^RESULT ' "$log" | sed "s/^/PROBE27_/"
}
# CHAINED on the first run's sentinel (gdn9 is the last arm there), then the
# presence check as the safety net.  Sentinel of this file: PROBE27_GDN27_DONE.
until grep -q '^PROBE27_DONE' "$HOME/probe27b/run27b.log"; do sleep 60; done
run_arm gdn27  "$GDN27" OOC_GDN_BLOCK_DONE
echo "PROBE27_GDN27_DONE"
