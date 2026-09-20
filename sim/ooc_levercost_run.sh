#!/usr/bin/env bash
# sim/ooc_levercost_run.sh -- TRACK LEVERCOST, 2026-09-20.
#
# A/B OOC DRAWS FOR THE FOUR THROUGHPUT LEVERS, one Vivado at a time, each with
# an object-level census and a PER-CLOCK synthesis-stage timing estimate
# (sim/ooc_levercost.tcl).  Modelled on sim/ooc_bmover_run.sh: closure by
# reading the whole rtl/ directory, presence gate by /proc/PID/exe, LINE-
# ANCHORED sentinel, RSS sampler, cgroup peak WITH the swap figure beside it.
#
# WHY EACH LEVER IS DRAWN IN ITS OWN UNIT AND NOT IN THE CARD TOP.  The card
# top does not synthesise.  `grep -c 'Finished RTL Elaboration'` is ZERO across
# TWELVE `fk33_card` / `fk33_llama_top` attempts on TWO machines
# (hw/fk33/ooc_c_in_card.tcl), and the single best-behaved of them ran 47 h
# under MemoryHigh=24G wanting at least 39.1 GiB and did not finish
# (hw/fk33/ooc_card_dcp.tcl).  A five-arm A/B against that top has no recorded
# instance of one arm terminating.  So the rule here is: draw each lever in the
# SMALLEST ENTITY THAT CLOSES ITS LOGIC CONE, and say plainly which levers have
# no such entity.
#
# THE ARMS.
#
#   apop_ctrl / apop_fast   target matvec_int4_desc_axi, FAST_POP false/true.
#     TRACK AIDLE measured FAST_POP on `weight_streamer` OOC as ZERO LUT (27
#     LUT4 become LUT5) and core-clock WNS 11.709 -> 11.285.  It labelled the
#     0.424 ns a LOWER BOUND because out of context the consumer side is a
#     PORT: in the card, `w_ready` carries `xq_cnt > 0` from `matvec_core`, and
#     `pop_w <= all_v and w_ready` fans back to all 27 FIFO read enables
#     (rtl/weight_streamer.vhd:251-264).  `matvec_core` and `weight_streamer`
#     are BOTH inside `matvec_int4`, inside `matvec_int4_desc_axi` -- so THIS
#     draw closes the cone AIDLE left open, at the card's own 27-lane geometry.
#
#   brecur4 / brecur16      target gdn_block, RECUR_LANES 4/16.
#     TRACK BRECUR measured +48 DSP, +9 BRAM, +7,865 LUT on `gdn_recur_pipe`.
#     This draws the enclosing block, because the parts do not sum across
#     synthesis contexts and the pipe's delta is not the block's.
#
#   cswp_off / cswp_on      target attn_block, SWEEP_PIPE false/true.
#     ONLY RUNNABLE ONCE TRACK CSWEEP HAS COMMITTED.  As of this script's
#     writing `SWEEP_PIPE` exists only in an uncommitted working copy of
#     rtl/attn_block.vhd; the runner refuses the arm rather than measuring a
#     half-edited file.
#
#   A_DRAIN_WIDE has NO arm and that is the finding, not an omission.  It lives
#   in the `ga_desc` generate block of rtl/llama_top.vhd (generated into
#   rtl/fk33_llama_top.vhd), which is not an entity.  The smallest entity
#   containing it IS the card top, i.e. the job that has never finished.
#
# GENERICS ARE READ FROM THE GENERATORS, NOT FROM PROSE:
#   A: hw/fk33/gen_fk33_engine.py lines 84-95 (BLK 32, ROWS_IF 48, NPORTS_W 24,
#      NPORTS_S 3, AXI_DW 256, ADDR_W 40, MAXCOLS/MAXROWS_BFP 17408,
#      FIFO_DEPTH 512, MAXB/MAXOUT/DESC_MAXB 16) plus DUAL_CLK true and
#      USE_XEXP_PORT true (hw/fk33/gen_pcieep.py sets CONFIG.USE_XEXP_PORT on
#      the card's engine cell) and CB_STYLE "regs" (its default).  Every one
#      equals the entity default and is passed ANYWAY, so the draw cannot
#      depend on a default staying put.
#
# MEMORY.  Each draw runs under `systemd-run --user --scope -p MemoryHigh=$CAP`
# and BOTH `memory.peak` and `memory.swap.current` are read back, because a
# capped job's resident set IS the cap and the rest is in the swapfile -- the
# recorded 47 h card run read 24.4 GB resident and 15.7 GB swap at the same
# instant.  A peak at the cap is flagged `at_cap=YES` and is the cap, not the
# appetite.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${LC_OUTDIR:-$HOME/levercost_ooc}"
VIV="${LC_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${LC_CAP:-8G}"
ONLY="${LC_ONLY:-apop_ctrl apop_fast brecur4 brecur16}"
mkdir -p "$OUT"

RTL="$REPO/rtl"

# ---- THE PRESENCE GATE, by /proc/PID/exe and never by a command line.  A
# command line can be spoofed and, worse, MATCHES SIBLINGS: this project has
# measured `ps -eo args | grep unwrapped/lnx64.o/vivado` counting four bash
# processes and a grep as Vivado, and a /proc loop matching the script text
# that was searching for it.  /proc/PID/exe is the kernel's view.
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
  echo "LEVERCOST_WAIT $(date -Is): a Vivado is present here ($(rss_now) GB summed); re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "LEVERCOST_ABORT: no vivado on PATH"; exit 9; }

# ---- The card's subsystem-A geometry, from hw/fk33/gen_fk33_engine.py.
AGEN="BLK=32 ROWS_IF=48 NPORTS_W=24 NPORTS_S=3 AXI_DW=256 ADDR_W=40 MAXCOLS=17408 MAXROWS_BFP=17408 FIFO_DEPTH=512 MAXB=16 MAXOUT=16 DESC_MAXB=16 DUAL_CLK=true USE_XEXP_PORT=true CHECK_JOB_INDEX=false CB_STYLE=regs"
# Two clocks: the core domain the lever lives in, and the HBM AXI domain that
# owns the global worst path and hides the effect if you quote it.
ACLK="s_axi_aclk=13.333 m_aclk=4.000"

# ---- Subsystem B at 9B, from rtl/fk33_llama_top.vhd's u_gdn generic map
# (line 5654) resolved against the card's B_* generics.  RECUR_LANES is the
# variable and is appended per arm.
#
# PASSING THESE IS NOT OPTIONAL HERE.  `gdn_block`'s OWN default RECUR_LANES is
# 32 (rtl/gdn_block.vhd, "section 3.1's assumption") while the CARD passes 4,
# so a draw that relied on the entity default would measure an eight-times
# wider recurrence than ships and both arms would be wrong.
BGEN="KEY_HEADS=16 VAL_HEADS=32 DIM=128 KCONV=4 LAYERS=24 CONV_LANES=4 RECUR_SLOTS=16 L2_LANES=4 SILU_LANES=8 RMS_LANES=4 STRICT_PRODUCER=true"

# ---- Subsystem C at 9B, from rtl/fk33_llama_top.vhd's u_attn generic map
# (line 7247).  Filled in by the caller via LC_CGEN once TRACK CSWEEP has
# committed; empty here means the cswp arms use entity defaults, which is
# exactly the mistake BGEN's note describes, so the arms refuse to run without
# it.
CGEN="${LC_CGEN:-}"

echo "LEVERCOST_ENV host=$(hostname) repo=$REPO out=$OUT cap=$CAP"
echo "LEVERCOST_SHA $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 'no-git-here')"
free -m | head -2

USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "LEVERCOST_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "LEVERCOST_CGROUP systemd-run --user unavailable; plain run, RSS sampler only"
fi

draw() {   # $1 = tag   $2 = target entity   $3 = generics   $4 = clocks
  local tag="$1" target="$2" gen="$3" clk="$4"
  local log="$OUT/run_$tag.log" peak=0 cur unit="lc_${tag}_$$"
  local t0=$(date +%s)
  echo "=== LEVERCOST draw $tag target=$target begin $(date -Is) ==="
  rm -f "$OUT/cgroup_$tag.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && LC_TAG="$tag" LC_TARGET="$target" LC_OUT="$OUT" LC_RTL="$RTL" \
        LC_GEN="$gen" LC_CLK="$clk" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$tag.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$tag.log' -source '$REPO/sim/ooc_levercost.tcl'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && LC_TAG="$tag" LC_TARGET="$target" LC_OUT="$OUT" LC_RTL="$RTL" \
        LC_GEN="$gen" LC_CLK="$clk" \
        vivado -mode batch -nojournal -log "$OUT/vivado_$tag.log" \
               -source "$REPO/sim/ooc_levercost.tcl" ) > "$log" 2>&1 &
  fi
  local pid=$!
  local cgpeak="NA" cgswap="NA" cgdir=""
  while kill -0 $pid 2>/dev/null; do
    cur=$(rss_now); [ -z "$cur" ] && cur=0
    awk -v a="$cur" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak="$cur"
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_$tag.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_$tag.txt")"
    fi
    # Both figures, read at the same instant.  RESIDENT ALONE IS NOT THE
    # FOOTPRINT of a capped job: the card OOC read 24.4 GB resident and
    # 15.7 GB swap together, and only the sum is the appetite.
    if [ -n "$cgdir" ] && [ -r "$cgdir/memory.peak" ]; then
      cgpeak=$(cat "$cgdir/memory.peak")
      # `memory.swap.current` IS A LEVEL, NOT A PEAK -- the kernel offers no
      # `memory.swap.peak` -- so it must be MAXED HERE or the figure recorded
      # is whatever happened to be in swap at the last poll before exit.
      # MEASURED 2026-09-20: apop_ctrl's first draw recorded 1,024 MB this way
      # while apop_fast was observed MID-RUN at 3,891 MB, so the first figure
      # understated the job's appetite by nearly 3 GB and did it silently.
      if [ -r "$cgdir/memory.swap.current" ]; then
        s=$(cat "$cgdir/memory.swap.current")
        if [ "$cgswap" = "NA" ] || [ "$s" -gt "$cgswap" ]; then cgswap="$s"; fi
      fi
    fi
    sleep 5
  done
  wait $pid; local rc=$?
  local wall=$(( $(date +%s) - t0 ))
  local capb; capb=$(numfmt --from=iec "${CAP%G}G" 2>/dev/null || echo 0)
  local cgmb="NA" swmb="NA" atcap="no"
  if [ "$cgpeak" != "NA" ]; then
    cgmb=$(( cgpeak / 1048576 ))
    [ "$capb" -gt 0 ] && [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap="YES"
  fi
  [ "$cgswap" != "NA" ] && swmb=$(( cgswap / 1048576 ))
  echo "tag=$tag target=$target peak_rss_gb=$peak cgroup_peak_mb=$cgmb cgroup_swap_mb=$swmb at_cap=$atcap wall_s=$wall rc=$rc" > "$OUT/mem_$tag.txt"
  # THE SENTINEL, LINE-ANCHORED: this log contains the tcl's own source text,
  # so an unanchored grep matches the script that writes the line.
  if ! grep -qE "^LEVERCOST_DONE $tag\$" "$log"; then
    echo "LEVERCOST_FAIL $tag: no LEVERCOST_DONE sentinel (rc=$rc, peak ${peak} GB, cgroup ${cgmb} MB, swap ${swmb} MB, wall ${wall} s)"
    grep -E "^ERROR|^CRITICAL WARNING" "$OUT/vivado_$tag.log" 2>/dev/null | head -10
    tail -25 "$log"
    return 1
  fi
  echo "LEVERCOST_OK $tag rc=$rc peak_rss=${peak}GB cgroup_peak=${cgmb}MB swap=${swmb}MB at_cap=$atcap wall=${wall}s"
  grep -E "^LEVERCOST_(RESULT|SYNTH_VS_OPT|CENSUS|WORST_GLOBAL|WORST_CLK|CLKMADE|CLKMISS|READ|GENERICS)" "$log"
  # The two messages this project has recorded as lying, in both directions.
  # A count of exactly 100 is Vivado's message LIMIT, not a census.
  echo "LEVERCOST_LOGMSG $tag synth_8-10226=$(grep -c 'Synth 8-10226' "$OUT/vivado_$tag.log") synth_8-7186=$(grep -c 'Synth 8-7186' "$OUT/vivado_$tag.log")"
  grep -E 'Synth 8-10226|Synth 8-7186' "$OUT/vivado_$tag.log" | head -3
  return 0
}

rc=0
for t in $ONLY; do
  case "$t" in
    apop_ctrl) draw apop_ctrl matvec_int4_desc_axi "$AGEN FAST_POP=false" "$ACLK" || rc=1;;
    apop_fast) draw apop_fast matvec_int4_desc_axi "$AGEN FAST_POP=true"  "$ACLK" || rc=1;;
    # THE GENERICS TEETH.  TRACK AIDLE's recorded trap 6: "three OOC draws
    # agreeing to the digit is indistinguishable from a harness that ignores
    # its generics."  FAST_POP is EXPECTED to move almost nothing, so if
    # apop_ctrl and apop_fast agree, that agreement is only a result if this
    # harness is known to respond to generics at all.  This arm halves the
    # port count and MUST move the area by a large margin; if it does not,
    # every other number here is void.  NPORTS_W*AXI_DW = ROWS_IF*BLK*4 is
    # asserted in weight_streamer.vhd:175, so ROWS_IF halves with it:
    # 12*256 = 3072 = 24*32*4.
    apop_teeth)
      draw apop_teeth matvec_int4_desc_axi \
        "BLK=32 ROWS_IF=24 NPORTS_W=12 NPORTS_S=3 AXI_DW=256 ADDR_W=40 MAXCOLS=17408 MAXROWS_BFP=17408 FIFO_DEPTH=512 MAXB=16 MAXOUT=16 DESC_MAXB=16 DUAL_CLK=true USE_XEXP_PORT=true CHECK_JOB_INDEX=false CB_STYLE=regs FAST_POP=false" \
        "$ACLK" || rc=1;;
    brecur4)   draw brecur4  gdn_block "$BGEN RECUR_LANES=4"  "clk=13.333" || rc=1;;
    brecur16)  draw brecur16 gdn_block "$BGEN RECUR_LANES=16" "clk=13.333" || rc=1;;
    cswp_off|cswp_on)
      if ! grep -q "SWEEP_PIPE" "$RTL/attn_block.vhd" 2>/dev/null; then
        echo "LEVERCOST_SKIP $t: rtl/attn_block.vhd carries no SWEEP_PIPE here"; continue
      fi
      if [ -z "$CGEN" ]; then
        echo "LEVERCOST_SKIP $t: LC_CGEN is empty; refusing to draw attn_block on"
        echo "  entity defaults (HEAD_DIM 256 / N_QH 16 / LAYERS 8) which are NOT"
        echo "  the card's 9B shape.  Pass LC_CGEN with the u_attn generic map."
        continue
      fi
      case "$t" in
        cswp_off) draw cswp_off attn_block "$CGEN SWEEP_PIPE=false" "clk=13.333" || rc=1;;
        cswp_on)  draw cswp_on  attn_block "$CGEN SWEEP_PIPE=true"  "clk=13.333" || rc=1;;
      esac;;
    *) echo "LEVERCOST_ABORT unknown tag $t"; rc=1;;
  esac
done
echo "=== LEVERCOST_TABLE (report_utilization + census, per arm) ==="
for t in $ONLY; do
  [ -f "$OUT/result_$t.csv" ] && tail -1 "$OUT/result_$t.csv" | sed "s/^/$t: /"
  [ -f "$OUT/mem_$t.txt" ] && sed "s/^/$t: /" "$OUT/mem_$t.txt"
done
echo "LEVERCOST_ALLDONE rc=$rc"
exit $rc
