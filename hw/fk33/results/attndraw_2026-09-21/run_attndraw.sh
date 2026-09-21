#!/usr/bin/env bash
# sim/ooc_scorehdr_run.sh (run as run_hdrcost.sh on the BC-250) -- TRACK HDRCOST, 2026-09-20.  RUNS ON THE BC-250.
#
# THREE ARMS OF `attn_block` AT THE CARD'S 9B GENERICS, each drawn twice:
# phase 1 synth+opt+census+DCP, phase 2 place+route+cone timing, in SEPARATE
# Vivado processes so the routing phase does not inherit synthesis's peak.
#
#   base   SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=0   the control
#   tree   SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=1   the proposal
#   early  SWEEP_PIPE=true SCORE_EARLY=true  SCORE_HDR_TREE=0   the incumbent
#
# EACH OF `tree` AND `early` DIFFERS FROM `base` IN EXACTLY ONE GENERIC.  The
# recorded failure this shape exists to avoid: two composed runs compared as a
# one-variable KV_BLOCK experiment that in fact differed in FIVE things, whose
# 1.120 ns result reached three documents before it fell.  `tree` and `early`
# are NOT compared to each other directly as a one-variable pair -- they
# differ in two generics -- they are each compared to the shared control and
# the two deltas are what is quoted.
#
# THE CONTROL THAT MUST NOT MOVE: every resource outside the score cone.
# `SCORE_HDR_TREE` is passed STRAIGHT THROUGH `attn_block` to
# `attn_score_q12`'s `HDR_TREE` and is used for nothing else in the block
# (rtl/attn_block.vhd:1123 is its only other occurrence), so `u_arr`, `u_sm`,
# the KV path and the norm path must be bit-identical between `base` and
# `tree`.  If they are not, the arms differ in something unrecorded and no
# number here is admissible.  The per-instance cone census and the
# hierarchical utilization report are what show it.
#
# ORDER: base, tree, early.  base+tree answers the gating question (what does
# the lever cost); early is the comparator.  A truncated batch still lands the
# new information, which is the ordering rule LEVERCOST's batch 2 used.
#
# MEMORY.  MemoryHigh=11G and NOT HIGHER.  This box has 14 GB and no WoL
# watchdog; a pcieep build at 12G made it completely unreachable and needed a
# physical power-cycle only Oren can perform.  LEVERCOST measured this exact
# `attn_block` draw at cgroup peak 8,195 MB (AT its 8G cap) with 5,253 MB of
# swap beside it, so the appetite is over 8 GB and 11G may also be reached --
# BOTH figures are read back and `at_cap=YES` is printed when the peak is the
# cap.  A capped peak is the cap, not the appetite, and is never quoted as one.
#
# ONE VIVADO, gated on PRESENCE via /proc/PID/exe -- never on a command line,
# which matches siblings and the searching script's own text.
#
# NO HARDWARE.  synth/opt/place/route/report only.

set -u
ROOT="${SH_ROOT:-$HOME/attndraw}"
OUT="${SH_OUTDIR:-$ROOT/out}"
VIV="${SH_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${SH_CAP:-11G}"
PERIOD="${SH_PERIOD:-13.333}"
ARMS="${SH_ARMS:-base tree early}"
PHASES="${SH_PHASES:-synth pnr}"
mkdir -p "$OUT"

# Subsystem C at 9B, from rtl/fk33_llama_top.vhd's u_attn generic map,
# resolved against model_cfg_pkg's QWEN35_9B.  Identical to the string TRACK
# LEVERCOST used for its cswp arms, so its cswp_off row and this batch's base
# row are comparable on everything except SWEEP_PIPE and the tree generic.
#   HEAD_DIM 256, N_QH 16, N_KVH 4 -> G = 4 score units, NBLK = 256/32 = 8.
# attn_block's OWN defaults differ (POS_W is 16, not 17), so passing them is
# load-bearing and not decoration.
CGEN="HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8 POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true"

arm_gen() {
  case "$1" in
    coff)  echo "$CGEN SWEEP_PIPE=false SCORE_EARLY=false SCORE_HDR_TREE=0";;
    con)   echo "$CGEN SWEEP_PIPE=true  SCORE_EARLY=true  SCORE_HDR_TREE=0";;
    spon)  echo "$CGEN SWEEP_PIPE=true  SCORE_EARLY=false SCORE_HDR_TREE=0";;
    base)  echo "$CGEN SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=0";;
    tree)  echo "$CGEN SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=1";;
    early) echo "$CGEN SWEEP_PIPE=true SCORE_EARLY=true  SCORE_HDR_TREE=0";;
    tree2) echo "$CGEN SWEEP_PIPE=true SCORE_EARLY=false SCORE_HDR_TREE=2";;
    *) return 1;;
  esac
}

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

while vivado_present; do
  echo "HDRCOST_WAIT $(date -Is): a Vivado is present here ($(rss_now) GB summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "HDRCOST_ABORT: no vivado on PATH"; exit 9; }

echo "HDRCOST_ENV host=$(hostname) root=$ROOT out=$OUT cap=$CAP period=$PERIOD"
echo "HDRCOST_TREE_SHA $(cat "$ROOT/HEAD_SHA.txt" 2>/dev/null || echo unknown)"
echo "HDRCOST_MANIFEST $(sha256sum "$ROOT/manifest.sha256" 2>/dev/null | cut -d' ' -f1)"
free -m | head -2

USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "HDRCOST_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "HDRCOST_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

# $1 phase (synth|pnr)  $2 tag  $3.. env assignments
runviv() {
  local phase="$1" tag="$2"; shift 2
  local script sentinel
  case "$phase" in
    synth) script="$ROOT/sim/ooc_scorehdr.tcl";     sentinel="SCOREHDR_SDONE";;
    pnr)   script="$ROOT/sim/ooc_scorehdr_pnr.tcl"; sentinel="SCOREHDR_PDONE";;
  esac
  local log="$OUT/${phase}_$tag.log" peak=0 cur unit="hc_${phase}_${tag}_$$"
  local t0=$(date +%s)
  echo "=== HDRCOST $phase $tag begin $(date -Is) ==="
  rm -f "$OUT/cgroup_${phase}_$tag.txt"
  while vivado_present; do
    echo "HDRCOST_LANE_BUSY $(date -Is) $(rss_now) GB summed; wait 120 s"; sleep 120
  done
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && env "$@" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_${phase}_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_${phase}_$tag.log' -source '$script'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && env "$@" \
        vivado -mode batch -nojournal -log "$OUT/vivado_${phase}_$tag.log" \
               -source "$script" ) > "$log" 2>&1 &
  fi
  local pid=$!
  local cgpeak="NA" cgswap="NA" cgdir=""
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_${phase}_$tag.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_${phase}_$tag.txt")"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.high" ] && [ ! -s "$OUT/high_${phase}_$tag.txt" ]; then
      # THE CAP, READ BACK OUT OF THE SCOPE'S OWN CGROUP.  Two measured
      # failures this guards: `systemd-run --user` silently doing nothing when
      # the ssh session carries no XDG_RUNTIME_DIR, so Vivado runs UNCAPPED;
      # and a readback written as `systemd-run ... bash -c '... $cg ...'` whose
      # $cg was eaten by systemd's own command-line expansion, so it read
      # /sys/fs/cgroup/memory.high, said "No such file", and exited 0.
      # Here $cgdir is resolved by THIS shell from the cgroup path the payload
      # itself wrote, and the value is recorded rather than asserted.
      echo "cgdir=$cgdir memory.high=$(cat "$cgdir/memory.high")" > "$OUT/high_${phase}_$tag.txt"
      cat "$OUT/high_${phase}_$tag.txt"
    fi
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      # memory.swap.current is a LEVEL and the kernel offers no
      # memory.swap.peak, so it is MAXED here.  LEVERCOST measured a draw
      # recording 1,024 MB this way while a sibling was observed mid-run at
      # 3,891 MB: read once at exit, the figure understates by GB, silently.
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
  echo "phase=$phase tag=$tag peak_rss_gb=$peak cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" \
    | tee "$OUT/mem_${phase}_$tag.txt"
  # LINE-ANCHORED sentinel.  The log holds this script's and the tcl's own
  # source text, so an unanchored grep matches the thing that writes the line.
  if ! grep -qE "^$sentinel $tag\$" "$log"; then
    echo "HDRCOST_FAIL $phase $tag: no $sentinel sentinel (rc=$rc, wall ${wall}s, cgroup ${cgmb}MB, swap ${swmb}MB)"
    grep -E "^ERROR|^CRITICAL WARNING" "$OUT/vivado_${phase}_$tag.log" 2>/dev/null | head -10
    tail -30 "$log"
    return 1
  fi
  echo "HDRCOST_OK $phase $tag rc=$rc cgroup_peak=${cgmb}MB swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^SCOREHDR_" "$log"
  echo "HDRCOST_LOGMSG $phase $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_${phase}_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_${phase}_$tag.log")"
  return 0
}

rc=0
for a in $ARMS; do
  g=$(arm_gen "$a") || { echo "HDRCOST_ABORT unknown arm $a"; rc=1; continue; }
  case " $PHASES " in *" synth "*)
    runviv synth "$a" SH_TAG="$a" SH_OUT="$OUT" SH_RTL="$ROOT/rtl" \
                      SH_GEN="$g" SH_PERIOD="$PERIOD" || { rc=1; continue; };;
  esac
  case " $PHASES " in *" pnr "*)
    runviv pnr "$a" SH_TAG="$a" SH_OUT="$OUT" SH_DCP="$OUT/post_opt_$a.dcp" \
                    SH_PERIOD="$PERIOD" SH_NPATH=200 || rc=1;;
  esac
done

echo "=== HDRCOST_TABLE ==="
for a in $ARMS; do
  [ -f "$OUT/synth_$a.csv" ] && tail -1 "$OUT/synth_$a.csv" | sed "s/^/synth $a: /"
  [ -f "$OUT/pnr_$a.csv" ]   && tail -1 "$OUT/pnr_$a.csv"   | sed "s/^/pnr   $a: /"
  for p in synth pnr; do
    [ -f "$OUT/mem_${p}_$a.txt" ] && sed "s/^/mem   /" "$OUT/mem_${p}_$a.txt"
  done
done
echo "HDRCOST_ALLDONE rc=$rc"
exit $rc
