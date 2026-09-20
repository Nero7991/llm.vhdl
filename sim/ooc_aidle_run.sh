#!/usr/bin/env bash
# sim/ooc_aidle_run.sh -- TRACK AIDLE, 2026-09-20.
#
# TWO OOC DRAWS OF weight_streamer AT THE FK33 GEOMETRY, one Vivado at a time,
# each with a primitive census and a synthesis-stage timing estimate at
# 13.333 ns (the 75 MHz card core clock) and 4.0 ns (the 250 MHz HBM AXI
# clock).  Modelled line for line on sim/ooc_bmover_run.sh: closure directory
# of symlinks, presence gate by /proc/PID/exe, line-anchored sentinel, RSS
# sampler, numbers from report_utilization plus a get_cells census.
#
#   ctrl   FAST_POP=false   the shipping cadence, 2 beats per 3 core cycles
#   fast   FAST_POP=true    one beat per core cycle
#
# WHAT IT PRICES.  The only difference between the two netlists is the
# read-issue condition inside all 27 FIFOs -- `(ocnt + inflight) < 2` against
# `ocnt + inflight - pop < 2`.  Everything else in the draw is held fixed, so
# the LUT/FF/CARRY8 delta is attributable to the lever and to nothing else.
# That is the whole reason the target is weight_streamer and not fk33_engine:
# ~60 LUT of signal inside ~92,000 LUT of array is not a measurement.
#
# THE 28TH FIFO IS NOT IN THIS DRAW.  matvec_int4_desc_axi's own descriptor
# read master is a 28th axi_rd_port carrying the same generic.  Its cost is
# charged in the write-up by proportion and labelled DERIVED, not MEASURED.
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
OUT="${AIDLE_OUT:-$HOME/aidle_ooc}"
VIV="${AIDLE_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${AIDLE_CAP:-8G}"
ONLY="${AIDLE_ONLY:-base ctrl fast}"
mkdir -p "$OUT"

# ---- THE RTL DIRECTORY IS THE UNIT'S CLOSURE, NOT ALL OF rtl/ (see
# sim/ooc_bfmem_run.sh for the measured reason).  weight_streamer's closure is
# itself, axi_rd_port, its FSM and BOTH FIFO flavours -- async_fifo is the one
# DUAL_CLK=true selects and stream_fifo is still elaborated by the other arm
# of the generate, so both must be readable or the read fails.
#
# COPIED, NOT SYMLINKED, and that differs from sim/ooc_bmover_run.sh on
# purpose.  On the BC-250 the repo is the destination of
# ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh, which pushes THIS BOX'S SHARED
# WORKING TREE to one path -- so a second track syncing mid-run would change
# the file under a symlink between one draw and the next and the contaminated
# draw would look ordinary (CLAUDE.md records TRACK BENABLE paying for exactly
# this).  A copy plus a checksum manifest makes the two draws provably the
# same source, and the manifest is printed so the write-up can quote it.
RTLC="$OUT/rtl_closure"
mkdir -p "$RTLC"
for f in util_pkg stream_fifo async_fifo axi_rd_fsm axi_rd_port \
         weight_streamer; do
  cp -f "$REPO/rtl/$f.vhd" "$RTLC/$f.vhd"
done
sha256sum "$RTLC"/*.vhd > "$OUT/closure.sha256"
echo "AIDLE_CLOSURE $(wc -l < "$OUT/closure.sha256") files"
cat "$OUT/closure.sha256"

# ---- A SECOND CLOSURE AT THE PRE-CHANGE RTL, which is the control for the
# claim that FAST_POP = false costs nothing.  `ctrl` is the NEW files with the
# lever off, and Vivado should prune the unused `after_e` term entirely; if it
# does not, that is a cost paid by every build whether or not the lever is
# asked for, and it would otherwise be invisible.
#
# ALL FOUR CHANGED FILES COME FROM GIT, NOT JUST THE TWO FIFOS.  The new
# weight_streamer and axi_rd_port pass `FAST_POP =>` down, and the old FIFOs
# have no such generic -- mixing them is an elaboration error, not a control.
RTLB="$OUT/rtl_base"
mkdir -p "$RTLB"
cp -f "$RTLC"/*.vhd "$RTLB/"
#
# AIDLE_BASE_DIR OVERRIDES THE GIT READ, AND THE BC-250 NEEDS IT.  The tree
# ~/GitHub/DevOps/bc250-sync-llama-vhdl.sh lands there is git-TRACKED FILES
# ONLY -- there is no .git, so `git show` on that box reads nothing and the
# control draw would abort.  Point AIDLE_BASE_DIR at a directory holding the
# four pre-change files, copied over beside the sync.
for f in stream_fifo async_fifo axi_rd_port weight_streamer; do
  if [ -n "${AIDLE_BASE_DIR:-}" ]; then
    if ! cp -f "$AIDLE_BASE_DIR/$f.vhd" "$RTLB/$f.vhd"; then
      echo "AIDLE_ABORT: AIDLE_BASE_DIR has no $f.vhd"; exit 9
    fi
  elif ! git -C "$REPO" show "${AIDLE_BASE_REV:-HEAD}:rtl/$f.vhd" > "$RTLB/$f.vhd"; then
    echo "AIDLE_ABORT: cannot read rtl/$f.vhd at ${AIDLE_BASE_REV:-HEAD} and"
    echo "             AIDLE_BASE_DIR is unset (no .git here?)"; exit 9
  fi
done
sha256sum "$RTLB"/*.vhd > "$OUT/base.sha256"
echo "AIDLE_BASE_CLOSURE rev=${AIDLE_BASE_REV:-HEAD}"
cat "$OUT/base.sha256"
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
  echo "AIDLE_WAIT $(date -Is): a Vivado is present here ($(rss_now) GB summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "AIDLE_ABORT: no vivado on PATH"; exit 9; }

# The geometry lives in sim/ooc_aidle.tcl, which passes it explicitly; this
# runner varies ONE generic and nothing else.
GEN9B=""

echo "AIDLE_ENV host=$(hostname) repo=$REPO out=$OUT cap=$CAP sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
free -m | head -2

# Does systemd-run --user work here?  Probe once; fall back to plain.
USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "AIDLE_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "AIDLE_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

draw() {   # $1 = tag   $2 = extra generics
  local tag="$1" extra="$2" log="$OUT/run_$1.log" peak=0 cur unit="aidle_$1_$$"
  local t0=$(date +%s)
  echo "=== AIDLE draw $tag ($extra) begin $(date -Is) ==="
  rm -f "$OUT/cgroup_$tag.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && AIDLE_TAG="$tag" AIDLE_OUT="$OUT" AIDLE_RTL="${RTLSEL:-$RTLC}" \
        AIDLE_GEN="$GEN9B $extra" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$tag.log' -source '$REPO/sim/ooc_aidle.tcl'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && AIDLE_TAG="$tag" AIDLE_OUT="$OUT" AIDLE_RTL="${RTLSEL:-$RTLC}" \
        AIDLE_GEN="$GEN9B $extra" \
        vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
               -source "$REPO/sim/ooc_aidle.tcl" ) > "$log" 2>&1 &
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
  if ! grep -qE "^AIDLE_DONE $tag\$" "$log"; then
    echo "AIDLE_FAIL $tag: no AIDLE_DONE sentinel (rc=$rc, peak ${peak} GB, cgroup ${cgmb} MB, wall ${wall} s)"
    tail -20 "$log"
    return 1
  fi
  echo "AIDLE_OK $tag rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^AIDLE_(RESULT|SYNTH_VS_OPT|CENSUS|TIMING_ESTIMATE)" "$log"
  # The two lying messages, counted so the census can be reconciled.
  echo "AIDLE_LOGMSG $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_$tag.log")"
  grep -E 'Synth 8-10226|Synth 8-7186' "$OUT/vivado_$tag.log" | head -5
  return 0
}

rc=0
for t in $ONLY; do
  case "$t" in
    base) RTLSEL="$RTLB" draw base "" || rc=1;;
    ctrl) RTLSEL="$RTLC" draw ctrl "FAST_POP=false" || rc=1;;
    fast) RTLSEL="$RTLC" draw fast "FAST_POP=true"  || rc=1;;
    *) echo "AIDLE_ABORT unknown tag $t"; rc=1;;
  esac
done
echo "=== AIDLE_TABLE (from result_*.csv, i.e. report_utilization + census) ==="
for t in $ONLY; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s/^/$t: /"
  [ -f "$OUT/mem_$t.txt" ] && sed "s/^/$t: /" "$OUT/mem_$t.txt"
done
echo "AIDLE_ALLDONE rc=$rc"
exit $rc
