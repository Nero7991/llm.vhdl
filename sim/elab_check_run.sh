#!/usr/bin/env bash
# sim/elab_check_run.sh -- TRACK ELABCLASS, 2026-09-20.  RUNS ON EITHER BOX.
#
# THE SCHEDULED DISCRIMINATOR.  One `synth_design -rtl` per row of the table
# below: the card's own configuration, plus every generic value that a lever
# reaches and NO SYNTHESISER HAS EVER BEEN GIVEN.
#
# WHAT IT IS FOR.  A generic whose value changes which statements ELABORATE has
# a failure mode no bench in this repository can see.  GHDL evaluates the
# branch a run actually takes; Vivado unrolls every loop and folds every index
# statically.  TRACK HDRCOST measured the consequence: `SCORE_HDR_TREE=1` had
# passed a 20-point bit-exact grid against two C oracles, a 23-row mutation
# suite with attribution controls, and five green gate groups, and the first
# Vivado ever pointed at it died in 49 seconds on
# `[Synth 8-11324] array index 8 out of range`.
#
# WHAT IT IS NOT FOR.  It says NOTHING about area and NOTHING about timing.
# That is deliberate: a check that also measured those would cost an hour a row
# and would not be scheduled, which is the state this repository was already in.
#
# THE FIRST ROW IS THE TEETH ROW AND IT MUST FAIL.  `teeth` elaborates the
# PRE-FIX `rtl/attn_score_q12.vhd` (from `e1d5898^`) at the card's geometry and
# is expected to report `[Synth 8-11324]`.  A checker never shown to fail has
# not been shown to work, and `-rtl` is a cheaper mode than the one HDRCOST
# used -- if it ever stops folding indices, this row goes green and says so.
# `c_base` is its ATTRIBUTION CONTROL: the same tree and the same geometry with
# the lever OFF, which must PASS, so a `teeth` failure belongs to the lever and
# not to the harness.
#
# WHERE IT BELONGS IN THE SCHEDULE.  It needs a Vivado lane, so it CANNOT run
# on every `sim/regress.sh` gate.  It belongs
#   * before any `hw/fk33/pcieep_build.sh` that changes a generic, and
#   * on any commit that touches a generic declaration or a generic map, and
#   * nightly, when a lane is free.
# MEASURED runtimes are in the write-up; the short rows are seconds.
#
# NO HARDWARE.  synth_design -rtl and report_* only.
#
# ONE VIVADO, gated on PRESENCE via /proc/PID/exe.  Never on a command line:
# `pgrep -f` and any /proc/*/cmdline loop match the searching script's own
# text, which has killed the shell five times in this project.
#
# USAGE:
#   EC_ROOT=<tree> EC_OUTDIR=<dir> [EC_ROWS="teeth c_base ..."] \
#     bash sim/elab_check_run.sh
# The tree must carry rtl/*.vhd, mutant/attn_score_q12.vhd (for the teeth row)
# and gen/{norm_w_9b,qkn_9b}.hex (the card rows read them at elaboration).

set -u
ROOT="${EC_ROOT:-$HOME/elabclass}"
OUT="${EC_OUTDIR:-$ROOT/out}"
VIV="${EC_VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh}"
CAP="${EC_CAP:-11G}"
TCL="${EC_TCL:-$ROOT/sim/elab_check.tcl}"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# THE CARD'S OWN CONFIGURATION, copied from the GENERATED VHDL and not from the
# generator's Python.  `hw/fk33/gen_fk33_card.py` applies FK33_* trim overrides
# to its ARGS list AFTER construction, so the Python literals are not what is
# built; `hw/fk33/rtl/fk33_card.vhd:222-243` is.  Twenty-two generics.  A
# generic absent from this list takes rtl/fk33_llama_top.vhd's declared
# default, which is a VALUE and not a blank -- so this string is the card, and
# anything that differs from it is a configuration no bitstream has ever held.
DCARD="A_DESC=true B_STATE_AXI=true B_SRC_REAL=true B_CONST_HBM=true"
DCARD="$DCARD C_KV_AXI=true HOST_WINDOW=false C_REAL=true NORM_REAL=true"
DCARD="$DCARD SWG_REAL=true SMP_EN=true C_N_ROT=64 C_KV_BLOCK=32"
DCARD="$DCARD C_KV_ADDR_W=33 C_K_BASE_CH=282672640 C_V_BASE_CH=318324224"
DCARD="$DCARD C_MAXPOS=65536 C_CTXLEN=65536 WDOG_LIMIT=4000000"
DCARD="$DCARD A_ROWS_IF=48 A_JOB_STRIDE=262144"
# The two image paths are absolute in the generated file and must point at THIS
# tree, not at the workstation's checkout.
#
# PASS THE PATH BARE.  MEASURED 2026-09-20: the documented `-generic
# {NAME="value"}` form, written here as `NAME={"..."}` so Tcl's list parser
# would hand the VHDL quotes through, put the BRACES in the string --
# `Parameter NORM_W_IMAGE bound to: {"/home/.../norm_w_9b.hex"} - type: string`
# and then `ERROR: [Synth 8-3302] unable to open file
# '{"/home/.../norm_w_9b.hex"}' in 'r' mode`.  A brace is only special to Tcl at
# the START of a word, so it survived as data.  Vivado takes a bare value for a
# `string` generic and quoting it is what breaks it.
#
# THIS IS WHY THE `d_card` CONTROL ROW EXISTS.  The failure looked exactly like
# a design failure -- three anchored `ERROR:` lines naming the RTL -- and the
# only thing that said otherwise is that the row which MUST pass did not.
DCARD="$DCARD NORM_W_IMAGE=$ROOT/gen/norm_w_9b.hex"
DCARD="$DCARD C_QKN_IMAGE=$ROOT/gen/qkn_9b.hex"

# Subsystem C at the card's 9B geometry, from rtl/fk33_llama_top.vhd's u_attn
# generic map resolved against model_cfg_pkg's QWEN35_9B.  Byte-identical to
# the string TRACK HDRCOST used, so its rows and these are the same draw.
# HEAD_DIM 256 / KV_BLOCK 32 gives NBLK = 8, which is the geometry HDRCOST's
# failure needed: at a smaller bench NBLK the bad index may be in range.
CGEN="HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8 POS_W=17"
CGEN="$CGEN MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true"

# D's SwiGLU width at 9B.  `swiglu_mem` is drawn standalone as well as through
# the top, because a leaf draw isolates the unit from the adapter around it.
SWGN=12288

# Subsystem A's engine cell, from hw/fk33/gen_fk33_engine.py:83-95.  That file
# is the generator of `hw/fk33/rtl/fk33_engine.vhd`, so these twelve values
# ARE the card's, and `matvec_int4_desc_axi` is instantiated from the generated
# file and from nowhere in rtl/ -- a grep over rtl/*.vhd alone cannot see it.
AGEN="BLK=32 ROWS_IF=48 NPORTS_W=24 NPORTS_S=3 AXI_DW=256 ADDR_W=40"
AGEN="$AGEN MAXCOLS=17408 MAXROWS_BFP=17408 FIFO_DEPTH=512 MAXB=16 MAXOUT=16"
AGEN="$AGEN DESC_MAXB=16 FAST_POP=true DUAL_CLK=true"

# row -> top, mode, EC_EXTRA, generics.  Keep the CHEAP rows first: a truncated
# batch must still land the new information, which is the ordering rule this
# project's batch 2 used.
row_top() {
  case "$1" in
    teeth|c_base|c_tree) echo attn_block;;
    swg_base|swg_w1|swg_w8) echo swiglu_mem;;
    a_base|a_chkjob) echo matvec_int4_desc_axi;;
    d_card|d_hostwin|d_adw|d_swgw1|d_swgw8|d_normanchor) echo fk33_llama_top;;
    *) return 1;;
  esac
}
row_extra() {
  # ONLY the teeth row reads the mutant directory.
  case "$1" in teeth) echo "$ROOT/mutant";; *) echo "";; esac
}
row_gen() {
  case "$1" in
    teeth)    echo "$CGEN SWEEP_PIPE=true SCORE_HDR_TREE=1";;
    c_base)   echo "$CGEN SWEEP_PIPE=true SCORE_HDR_TREE=0";;
    c_tree)   echo "$CGEN SWEEP_PIPE=true SCORE_HDR_TREE=1";;
    swg_base) echo "N=$SWGN Q=12 LANES=1 WIDE_IO=false";;
    swg_w1)   echo "N=$SWGN Q=12 LANES=1 WIDE_IO=true";;
    swg_w8)   echo "N=$SWGN Q=12 LANES=8 WIDE_IO=true";;
    a_base)   echo "$AGEN CHECK_JOB_INDEX=false";;
    a_chkjob) echo "$AGEN CHECK_JOB_INDEX=true";;
    d_card)   echo "$DCARD";;
    d_hostwin) echo "$DCARD HOST_WINDOW=true";;
    d_adw)    echo "$DCARD A_DRAIN_WIDE=true";;
    d_swgw1)  echo "$DCARD SWG_WIDE=true SWG_LANES=1";;
    d_swgw8)  echo "$DCARD SWG_WIDE=true SWG_LANES=8";;
    d_normanchor) echo "$DCARD NORM_ANCHOR=true";;
    *) return 1;;
  esac
}
# What the row is EXPECTED to do.  A row whose expectation is `fail` and which
# passes is as much a result as the other way round: it means the check lost
# its teeth.
row_expect() {
  case "$1" in teeth) echo fail;; *) echo pass;; esac
}

ROWS="${EC_ROWS:-teeth c_base c_tree swg_base swg_w1 swg_w8 a_base a_chkjob d_card d_hostwin d_adw d_swgw1 d_swgw8 d_normanchor}"

vivado_present() {
  local p e
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    e=$(readlink /proc/$p/exe 2>/dev/null) || continue
    case "$e" in *unwrapped/lnx64.o/vivado*) return 0;; esac
  done
  return 1
}

while vivado_present; do
  echo "ELABCLASS_WAIT $(date -Is): a Vivado is present here; re-check in 120 s"
  sleep 120
done

[ -f "$VIV" ] && . "$VIV"
command -v vivado >/dev/null || { echo "ELABCLASS_ABORT: no vivado on PATH"; exit 9; }

echo "ELABCLASS_ENV host=$(hostname) root=$ROOT out=$OUT cap=$CAP"
echo "ELABCLASS_TREE_SHA $(cat "$ROOT/HEAD_SHA.txt" 2>/dev/null || echo unknown)"
echo "ELABCLASS_MANIFEST $(sha256sum "$ROOT/manifest.sha256" 2>/dev/null | cut -d' ' -f1)"
free -m | head -2

# THE MEMORY CAP SILENTLY DISAPPEARS OVER `ssh host 'bash -s'`, AND THE ONLY
# TELL IS ONE LINE OF LOG.  MEASURED 2026-09-20 on the BC-250: a non-login ssh
# session carries no `XDG_RUNTIME_DIR` and no `DBUS_SESSION_BUS_ADDRESS`, so
# `systemd-run --user` fails, this driver falls through to `USE_SD=0` and runs
# Vivado UNCAPPED while printing that it has done so.  Nothing errors.  On a
# 14 GB box with no WoL watchdog, an uncapped run is exactly the condition that
# once left it needing a physical power-cycle.  Set them here rather than
# relying on the caller's environment, and READ the ELABCLASS_CGROUP line.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=/run/user/$(id -u)/bus}"
export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

USE_SD=0
if systemd-run --user --scope --quiet -p MemoryHigh=1G true 2>/dev/null; then
  USE_SD=1; echo "ELABCLASS_CGROUP systemd-run --user scope available, cap $CAP"
else
  echo "ELABCLASS_CGROUP systemd-run --user unavailable; plain run"
fi

declare -A VERDICT WALL PEAK SWAP
rc=0
for r in $ROWS; do
  top=$(row_top "$r")   || { echo "ELABCLASS_ABORT unknown row $r"; rc=1; continue; }
  gen=$(row_gen "$r")
  ext=$(row_extra "$r")
  exp=$(row_expect "$r")
  log="$OUT/elab_$r.log"; unit="ec_${r}_$$"
  echo "=== ELABCLASS row=$r top=$top expect=$exp begin $(date -Is) ==="
  while vivado_present; do
    echo "ELABCLASS_LANE_BUSY $(date -Is); wait 120 s"; sleep 120
  done
  t0=$(date +%s)
  rm -f "$OUT/cgroup_$r.txt"
  if [ "$USE_SD" = 1 ]; then
    ( cd "$OUT" && env EC_TAG="$r" EC_TOP="$top" EC_RTL="$ROOT/rtl" EC_OUT="$OUT" \
          EC_GEN="$gen" EC_EXTRA="$ext" EC_MODE="${EC_MODE:-rtl}" \
        systemd-run --user --scope --quiet --unit="$unit" -p MemoryHigh="$CAP" \
        bash -c "cat /proc/self/cgroup > '$OUT/cgroup_$r.txt'; exec vivado -mode batch -nojournal -log '$OUT/vivado_$r.log' -source '$TCL'" ) > "$log" 2>&1 &
  else
    ( cd "$OUT" && env EC_TAG="$r" EC_TOP="$top" EC_RTL="$ROOT/rtl" EC_OUT="$OUT" \
          EC_GEN="$gen" EC_EXTRA="$ext" EC_MODE="${EC_MODE:-rtl}" \
        vivado -mode batch -nojournal -log "$OUT/vivado_$r.log" -source "$TCL" ) > "$log" 2>&1 &
  fi
  pid=$!
  cgdir=""; cgpeak="NA"; cgswap="NA"
  while kill -0 $pid 2>/dev/null; do
    if [ -z "$cgdir" ] && [ -s "$OUT/cgroup_$r.txt" ]; then
      cgdir="/sys/fs/cgroup$(sed -n 's/^0::\(.*\)$/\1/p' "$OUT/cgroup_$r.txt")"
    fi
    if [ -n "$cgdir" ]; then
      [ -r "$cgdir/memory.peak" ] && cgpeak=$(cat "$cgdir/memory.peak")
      # READ SWAP BESIDE RESIDENT.  MEASURED 2026-09-20 on the d_card row:
      # memory.peak 11,812,913,152 against memory.high 11,811,160,064 -- AT THE
      # CAP, so it is the throttle and not an appetite -- while
      # memory.swap.peak was 22,913,859,584.  DERIVED true footprint about 33 GB.
      # A resident figure alone understates this job by three times.
      if [ -r "$cgdir/memory.swap.peak" ]; then
        cgswap=$(cat "$cgdir/memory.swap.peak")
      elif [ -r "$cgdir/memory.swap.current" ]; then
        s=$(cat "$cgdir/memory.swap.current")
        if [ "$cgswap" = "NA" ] || [ "$s" -gt "$cgswap" ]; then cgswap="$s"; fi
      fi
    fi
    sleep 3
  done
  wait $pid; vrc=$?
  wall=$(( $(date +%s) - t0 ))
  cgmb="NA"; [ "$cgpeak" != "NA" ] && cgmb=$(( cgpeak / 1048576 ))
  swmb="NA"; [ "$cgswap" != "NA" ] && swmb=$(( cgswap / 1048576 ))
  capb=$(numfmt --from=iec "$CAP" 2>/dev/null || echo 0)
  atcap="no"
  [ "$cgpeak" != "NA" ] && [ "$capb" -gt 0 ] && \
    [ $(( cgpeak * 100 )) -ge $(( capb * 99 )) ] && atcap="YES"
  # LINE-ANCHORED.  The log holds this script's and the tcl's own source text,
  # so an unanchored grep matches the line that writes the line.
  if grep -qE "^ELABCHK_PASS $r\$" "$log"; then v=PASS
  elif grep -qE "^ELABCHK_FAIL $r\$" "$log"; then v=FAIL
  else v=NORESULT; fi
  VERDICT[$r]="$v"; WALL[$r]="$wall"; PEAK[$r]="$cgmb"; SWAP[$r]="$swmb"
  echo "ELABCLASS_ROW row=$r top=$top verdict=$v expect=$exp wall_s=$wall cgroup_peak_mb=$cgmb at_cap=$atcap cgroup_swap_peak_mb=$swmb rc=$vrc"
  if [ "$v" = FAIL ] || [ "$v" = NORESULT ]; then
    grep -E "^ERROR" "$OUT/vivado_$r.log" 2>/dev/null | head -8
  fi
  # A row that does not match its expectation is the only thing that sets rc.
  case "$exp:$v" in
    pass:PASS|fail:FAIL) ;;
    *) echo "ELABCLASS_UNEXPECTED row=$r expected=$exp got=$v"; rc=1;;
  esac
done

echo "=== ELABCLASS_TABLE ==="
printf "%-12s %-20s %-8s %-8s %8s %10s %10s\n" row top expect verdict wall_s peak_mb swap_mb
for r in $ROWS; do
  printf "%-12s %-20s %-8s %-8s %8s %10s %10s\n" \
    "$r" "$(row_top "$r")" "$(row_expect "$r")" "${VERDICT[$r]:-NA}" \
    "${WALL[$r]:-NA}" "${PEAK[$r]:-NA}" "${SWAP[$r]:-NA}"
done
echo "ELABCLASS_ALLDONE rc=$rc"
exit $rc
