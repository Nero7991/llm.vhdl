#!/usr/bin/env bash
# sim/ooc_scorehdr_run2.sh (run as run_hdrcost2.sh on the BC-250) -- TRACK HDRCOST batch 2, RUNS ON THE BC-250.
#
# Chained behind batch 1.  Two jobs:
#
#   basereport   re-report base's ROUTED checkpoint.  Batch 1's route FINISHED
#                (1,416 s, routed clk WNS 3.101, 0 failing endpoints of
#                250,281) and then the reporting section died on
#                `[Common 17-54] The object 'timing_path' does not have a
#                property 'LOGIC_DELAY'`, so the cone numbers were never
#                emitted.  `post_route_base.dcp` was written BEFORE the
#                reports, which is the only reason this costs five minutes
#                instead of another forty.
#
#   treefix      the ONE-LINE candidate fix for the synthesis defect batch 1
#                found: `SCORE_HDR_TREE=1` does not synthesise at NBLK = 8.
#                `ERROR: [Synth 8-11324] array index 8 out of range
#                [rtl/attn_score_q12.vhd:488]`, 49 s in.  Reads
#                $HOME/hdrcost_fix/rtl, whose only difference from
#                $HOME/hdrcost/rtl is that one loop bound (verified by cmp,
#                file by file: exactly one of 114 differs).
#
# CHAINED ON THE SENTINEL OF THE JOB AHEAD, THEN GATED ON PRESENCE.  Presence
# alone is a lane check and not a queue: two waiters on a free lane both start,
# which is the condition that hung the workstation in August.  The sentinel
# says the work before me finished; presence says nothing else grabbed the
# lane meanwhile.  Neither alone is enough.

set -u
ROOT="${SH_ROOT:-$HOME/hdrcost}"
FIXROOT="${SH_FIXROOT:-$HOME/hdrcost_fix}"
OUT="${SH_OUTDIR:-$ROOT/out}"
VIV="${SH_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${SH_CAP:-11G}"
PERIOD="${SH_PERIOD:-13.333}"
CGEN="HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8 POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true"

vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}

# ---- 1. THE SENTINEL OF THE JOB AHEAD, line-anchored.  The log contains this
# script's own text and batch 1's, so an unanchored grep matches the searcher.
echo "HDRCOST2_CHAIN waiting on batch 1's own sentinel in $OUT/driver.log"
until grep -aqE '^HDRCOST_ALLDONE' "$OUT/driver.log" 2>/dev/null; do sleep 60; done
echo "HDRCOST2_CHAIN batch 1 sentinel seen $(date -Is)"
# ---- 2. and only then the lane check.
while vivado_present; do echo "HDRCOST2_WAIT lane busy $(date -Is)"; sleep 60; done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "HDRCOST2_ABORT: no vivado on PATH"; exit 9; }
echo "HDRCOST2_ENV host=$(hostname) out=$OUT cap=$CAP"
echo "HDRCOST2_FIXMANIFEST $(sha256sum "$FIXROOT/manifest_fix.sha256" | cut -d' ' -f1)"
free -m | head -2

runviv() {
  local phase="$1" tag="$2"; shift 2
  local script sentinel
  case "$phase" in
    synth) script="$ROOT/sim/ooc_scorehdr.tcl";     sentinel="SCOREHDR_SDONE";;
    pnr)   script="$ROOT/sim/ooc_scorehdr_pnr.tcl"; sentinel="SCOREHDR_PDONE";;
  esac
  local log="$OUT/${phase}_$tag.log" unit="hc2_${phase}_${tag}_$$"
  local t0=$(date +%s)
  while vivado_present; do echo "HDRCOST2_LANE_BUSY $(date -Is); wait 60 s"; sleep 60; done
  echo "=== HDRCOST2 $phase $tag begin $(date -Is) ==="
  rm -f "$OUT/cg2_${phase}_$tag.txt"
  ( cd "$OUT" && env "$@" \
      systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
      bash -c "cat /proc/self/cgroup > '$OUT/cg2_${phase}_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_${phase}_$tag.log' -source '$script'" ) > "$log" 2>&1 &
  local pid=$! cgpeak="NA" cgswap="NA" cgdir="" s
  while kill -0 $pid 2>/dev/null; do
    if [ -z "$cgdir" ] && [ -s "$OUT/cg2_${phase}_$tag.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cg2_${phase}_$tag.txt")"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      # a LEVEL, not a peak: max-tracked or it understates by GB, silently.
      if [ -r "$cgdir/memory.swap.current" ]; then
        s=$(cat "$cgdir/memory.swap.current")
        if [ "$cgswap" = "NA" ] || [ "$s" -gt "$cgswap" ]; then cgswap="$s"; fi
      fi
    fi
    sleep 5
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "$CAP" 2>/dev/null || echo 0)
  local cgmb="NA" swmb="NA" atcap="no"
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    [ "$capb" -gt 0 ] && [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap="YES"
  fi
  [ "$cgswap" != "NA" ] && swmb=$(( cgswap / 1048576 ))
  echo "phase=$phase tag=$tag cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" \
    | tee "$OUT/mem2_${phase}_$tag.txt"
  if ! grep -qE "^$sentinel $tag\$" "$log"; then
    echo "HDRCOST2_FAIL $phase $tag: no $sentinel (rc=$rc, wall ${wall}s)"
    grep -aE "^ERROR" "$OUT/vivado_${phase}_$tag.log" 2>/dev/null | head -8
    tail -25 "$log"; return 1
  fi
  echo "HDRCOST2_OK $phase $tag rc=$rc cgroup_peak=${cgmb}MB swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  grep -aE "^SCOREHDR_" "$log"
  return 0
}

rc=0
# 1. base, report-only, from the routed checkpoint batch 1 already produced.
runviv pnr basereport SH_TAG=basereport SH_OUT="$OUT" \
       SH_DCP="$OUT/post_route_base.dcp" SH_REPORT_ONLY=1 \
       SH_PERIOD="$PERIOD" SH_NPATH=200 || rc=1

# 2. the fix: synth then place+route, reading the FIXED rtl root.
runviv synth treefix SH_TAG=treefix SH_OUT="$OUT" SH_RTL="$FIXROOT/rtl" \
       SH_GEN="$CGEN SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=1" \
       SH_PERIOD="$PERIOD" \
  && runviv pnr treefix SH_TAG=treefix SH_OUT="$OUT" \
       SH_DCP="$OUT/post_opt_treefix.dcp" SH_PERIOD="$PERIOD" SH_NPATH=200 \
  || rc=1

echo "HDRCOST2_ALLDONE rc=$rc"
exit $rc
