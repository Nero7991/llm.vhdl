#!/usr/bin/env bash
# sim/ooc_bnarrow_run.sh -- TRACK BNARROWSYN, 2026-09-20.
#
# FOUR OOC DRAWS OF gdn_state_store AT THE 9B GEOMETRY, one Vivado at a time,
# each with an object-level primitive census and a synthesis-stage timing
# estimate at 13.333 ns and 5.0 ns (sim/ooc_bnarrow.tcl).  It is
# sim/ooc_bmover_run.sh (TRACK BMOVERSYN, 4bc5f48) with the arms changed and
# with a second CLOSURE directory, for the reason in the next paragraph.
#
#   ctrl   PIPE WIDE MAXOUT=8, NWIDE=false      THE CARD PATH TODAY (control)
#   nw     PIPE WIDE MAXOUT=8, NWIDE=true       TRACK BNARROW's ask
#   nwu    nw + CONV_STYLE=ultra                the two conv memories in URAM
#   d12    nw with the 12-bank wider-word conv tap store  (the REJECTED arm)
#
# WHY TWO CLOSURES.  `ctrl` and `nw` read the repository's own RTL through
# symlinks, so their numbers are this tree's.  `nwu` and `d12` need a source
# change in files this track does NOT own, so each gets a closure of its own
# holding a PATCHED COPY of the one or two files it changes and symlinks for
# the rest.  Pricing a rejected option honestly means building it; committing
# it into another track's file does not follow from that.  The patches are
# written by this script (below) so the diff is visible rather than implied.
#
# THE GENERICS ARE llama_top's u_state GENERIC MAP AT 9B, read from
# rtl/llama_top.vhd:5125 and hw/fk33/rtl/fk33_card.vhd (B_CONST_HBM => true),
# the same set TRACK BMOVERSYN used, so its four draws and these four are
# comparable: VAL_HEADS 32, DIM 128, RECUR_LANES 4, LAYERS 24, KEY_HEADS 16,
# KCONV 4, CONV_LANES 4, MANT/EXP/CONV bytes 1048576/4096/49152,
# LAYER_STRIDE 1101824, MAXB 16, CONST_EN true, CONST_STRIDE/BYTES 66048.
# `ctrl` here is BMOVERSYN's `wp8` re-drawn in THIS tree, because 748ff91
# changed four of the seven files the draw reads and a comparison needs both
# ends from one tree (CLAUDE.md).
#
# MEMORY.  Each draw runs under `systemd-run --user --same-dir --scope
# -p MemoryHigh=$CAP` and the cgroup's memory.peak is read back WHILE THE
# SCOPE EXISTS.  A peak AT the cap is the cap, not the appetite; the runner
# says which.  The /proc/PID/exe RSS sampler runs regardless.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BN_OUT_DIR:-$HOME/bnarrow_ooc}"
VIV="${BN_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${BN_CAP:-10G}"
ONLY="${BN_ONLY:-ctrl nw nwu d12}"
mkdir -p "$OUT"

CLOSURE_FILES="util_pkg gdn_state_mem gdn_exp_mem gdn_conv_tap_mem gdn_conv_w_mem gdn_state_axi gdn_state_store"

# ---- CLOSURE 1: the repository's files, unmodified, by symlink.
RTLC="$OUT/rtl_closure"
mkdir -p "$RTLC"
for f in $CLOSURE_FILES; do ln -sf "$REPO/rtl/$f.vhd" "$RTLC/$f.vhd"; done

# ---- CLOSURE 2 (`nwu`): the two conv memories' STYLE guard widened to
# accept "ultra".  Both refuse anything but "block"/"auto" through an
# out-of-range natural, which is correct for the shipping design and is
# exactly what has to move to price URAM.  Nothing else changes: the
# `ram_style` attribute already carries STYLE through verbatim.
RTLU="$OUT/rtl_ultra"
mkdir -p "$RTLU"
for f in $CLOSURE_FILES; do ln -sf "$REPO/rtl/$f.vhd" "$RTLU/$f.vhd"; done
for f in gdn_conv_tap_mem gdn_conv_w_mem; do
  rm -f "$RTLU/$f.vhd"
  sed 's/if s = "block" or s = "auto" then/if s = "block" or s = "auto" or s = "ultra" then/' \
      "$REPO/rtl/$f.vhd" > "$RTLU/$f.vhd"
  if ! cmp -s "$REPO/rtl/$f.vhd" "$RTLU/$f.vhd"; then
    echo "BNARROW_PATCH nwu $f: $(diff "$REPO/rtl/$f.vhd" "$RTLU/$f.vhd" | grep -c '^[<>]') lines differ"
  else
    echo "BNARROW_PATCH_FAIL nwu $f: the style guard did not match; the arm would be a duplicate of nw"
    exit 8
  fi
done

# ---- CLOSURE 3 (`d12`): the rejected 12-bank wider-word conv tap store.
#
# ITS SOURCE MUST NOT LIVE IN sim/, AND THIS IS NOT TIDINESS.  It declares a
# SECOND `gdn_conv_tap_mem`, and sim/regress.sh's planner globs
# `('rtl/*.vhd', 'sim/*.vhd', 'sim/micro/*.vhd', 'tb/*.vhd')` into ONE pool
# with a single `provider` slot per design unit (sim/regress.sh:1472).  A
# duplicate entity there would silently re-point every gate row that reaches
# this memory at the rejected arm.  The alternative arm therefore lives in
# the RESULTS directory, which nothing globs, as
# hw/fk33/results/bnarrow_ooc_2026-09-20/gdn_conv_tap_mem_d12.vhd.
RTLD="$OUT/rtl_d12"
mkdir -p "$RTLD"
for f in $CLOSURE_FILES; do ln -sf "$REPO/rtl/$f.vhd" "$RTLD/$f.vhd"; done
D12SRC="${BN_D12_SRC:-$REPO/hw/fk33/results/bnarrow_ooc_2026-09-20/gdn_conv_tap_mem_d12.vhd}"
if [ -f "$D12SRC" ]; then
  rm -f "$RTLD/gdn_conv_tap_mem.vhd"
  cp "$D12SRC" "$RTLD/gdn_conv_tap_mem.vhd"
  echo "BNARROW_PATCH d12 gdn_conv_tap_mem <- $D12SRC"
else
  echo "BNARROW_NOTE d12 source $D12SRC absent; the d12 arm will be skipped"
fi

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
# Presence is a LANE CHECK, NOT A QUEUE (CLAUDE.md): two waiters on it both
# start.  This runner chains its own draws sequentially and is the only
# multi-draw job on this box, so the loop below guards against another
# track's short run and nothing else.
while vivado_present; do
  echo "BNARROW_WAIT $(date -Is): a Vivado is present here ($(rss_now) GB summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "BNARROW_ABORT: no vivado on PATH"; exit 9; }

GEN9B="VAL_HEADS=32 DIM=128 RECUR_LANES=4 LAYERS=24 KEY_HEADS=16 KCONV=4 CONV_LANES=4 MANT_BYTES=1048576 EXP_BYTES=4096 CONV_BYTES=49152 LAYER_STRIDE=1101824 MAXB=16 CONST_EN=true CONST_STRIDE=66048 CONST_BYTES=66048 PIPE=true WIDE=true MAXOUT=8"

echo "BNARROW_ENV host=$(hostname) repo=$REPO out=$OUT cap=$CAP sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "BNARROW_CLOSURE_MD5"
for f in $CLOSURE_FILES; do md5sum "$REPO/rtl/$f.vhd"; done
free -m | head -2

USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "BNARROW_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "BNARROW_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

draw() {   # $1 = tag   $2 = extra generics   $3 = closure dir
  local tag="$1" extra="$2" rtl="$3" log="$OUT/run_$1.log" peak=0 cur unit="bnarrow_$1_$$"
  local t0=$(date +%s)
  echo "=== BNARROW draw $tag ($extra) rtl=$rtl begin $(date -Is) ==="
  rm -f "$OUT/cgroup_$tag.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && BN_TAG="$tag" BN_OUT="$OUT" BN_RTL="$rtl" \
        BN_GEN="$GEN9B $extra" \
        systemd-run --user --same-dir --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$tag.log' -source '$REPO/sim/ooc_bnarrow.tcl'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && BN_TAG="$tag" BN_OUT="$OUT" BN_RTL="$rtl" \
        BN_GEN="$GEN9B $extra" \
        vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
               -source "$REPO/sim/ooc_bnarrow.tcl" ) > "$log" 2>&1 &
  fi
  local pid=$!
  local cgpeak="NA" cgswap="NA" cgdir=""
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_$tag.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_$tag.txt")"
    fi
    # memory.peak and memory.swap.current must be read while the scope exists.
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      [ -r "$cgdir/memory.swap.current" ] && cgswap=$(cat "$cgdir/memory.swap.current")
    fi
    sleep 5
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "${CAP%G}G" 2>/dev/null || echo 0)
  local cgmb="NA" swmb="NA" atcap="no"
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    # within 1% of the cap: the cap held it, so this is not the appetite
    [ "$capb" -gt 0 ] && [ $(( cgpeak / 1024 * 100 )) -ge $(( capb / 1024 * 99 )) ] && atcap="YES"
  fi
  [ "$cgswap" != "NA" ] && swmb=$(( cgswap / 1048576 ))
  echo "peak_rss_gb=$peak cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" > "$OUT/mem_$tag.txt"
  # THE SENTINEL, line-anchored: the log carries the script's own text.
  if ! grep -qE "^BNARROW_DONE $tag\$" "$log"; then
    echo "BNARROW_FAIL $tag: no BNARROW_DONE sentinel (rc=$rc, peak ${peak} GB, cgroup ${cgmb} MB, wall ${wall} s)"
    tail -25 "$log"
    return 1
  fi
  echo "BNARROW_OK $tag rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB cgroup_swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^BNARROW_(RESULT|SYNTH_VS_OPT|CENSUS|TIMING_ESTIMATE)" "$log"
  # The two lying messages, counted so the census can be reconciled.
  echo "BNARROW_LOGMSG $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_$tag.log") synth_8-5780=$(grep -c 'Synth 8-5780' "$OUT/vivado_$tag.log") synth_8-4767=$(grep -c 'Synth 8-4767' "$OUT/vivado_$tag.log")"
  grep -E 'Synth 8-10226|Synth 8-7186' "$OUT/vivado_$tag.log" | head -6
  return 0
}

rc=0
for t in $ONLY; do
  case "$t" in
    ctrl) draw ctrl "NWIDE=false" "$RTLC" || rc=1;;
    nw)   draw nw   "NWIDE=true"  "$RTLC" || rc=1;;
    nwu)  draw nwu  "NWIDE=true CONV_STYLE=ultra" "$RTLU" || rc=1;;
    d12)  if [ -f "$D12SRC" ]; then draw d12 "NWIDE=true" "$RTLD" || rc=1
          else echo "BNARROW_SKIP d12 (no $D12SRC)"; fi;;
    *) echo "BNARROW_ABORT unknown tag $t"; rc=1;;
  esac
done
echo "=== BNARROW_TABLE (from result_*.csv, i.e. report_utilization + census) ==="
for t in $ONLY; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s/^/$t: /"
  [ -f "$OUT/mem_$t.txt" ] && sed "s/^/$t: /" "$OUT/mem_$t.txt"
done
echo "BNARROW_ALLDONE rc=$rc"
exit $rc
