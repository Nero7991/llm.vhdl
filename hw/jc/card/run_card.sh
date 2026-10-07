#!/usr/bin/env bash
# hw/jc/card/run_card.sh -- Jungle Cat 27B card: the full build, orchestrated.
#
#   run_card.sh [--dry-run] <root> [part] [allow_neg]
#
# What it does (Task 9 brief):
#   1. copies the TRACKED tree into <root>/src via `git archive HEAD`;
#   2. applies build12_levers_off.patch there, refusing if it does not apply cleanly;
#   3. records HEAD and the patch's sha256 into <root>/PROVENANCE.txt;
#   4. regenerates the 27B card wrapper and the Jungle Cat BD/XDC/top IN THAT TREE
#      (hw/fk33/gen_fk33_card.py under the pinned JC_CARD_ENV, then
#      hw/jc/card/gen_jc_card.py in place) and checks both ran;
#   5. runs Vivado under hw/jc/loader/run_capped.sh: MemoryHigh=24G, a 30 GiB swap
#      guard (CLAUDE.md's measured card-build shape: ~47 GB including swap under a
#      tighter cap, so this one is watched the same way);
#   6. harvests the utilisation, timing, CDC and hierarchical utilisation reports,
#      and the bitstream, into <root>/results;
#   7. writes the JCCARD_DONE or JCCARD_FAIL <reason> sentinel -- anchored
#      (grep -qE '^JCCARD_(DONE|FAIL)'), and written by this script reading
#      Vivado's OWN log line, never by a timeout or an exit code alone
#      (CLAUDE.md: "a completion signal that also fires on failure is not one").
#
# --dry-run prints every command this script would run and every parameter binding
# (part, CLK_CORE_MHZ, the memory cap and the swap guard) and exits 0. It touches
# NOTHING: no git, no Vivado, no filesystem write, not even <root>. That is
# deliberate -- the one thing a dry run must prove is what WOULD run, not that the
# directory handling works.
#
# No hardware access, ever: this script only calls Vivado in batch/-source mode on
# a Tcl file that contains no xsdb/hw_server/program/jtag call (global-constraints.md).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
if [ $# -lt 1 ]; then
  echo "usage: $0 [--dry-run] <root> [part] [allow_neg]" >&2
  exit 2
fi
ROOT=$1
PART=${2:-xcvu35p-fsvh2104-2L-e}
ALLOW_NEG=${3:-}
if [ -n "$ALLOW_NEG" ] && [ "$ALLOW_NEG" != "allow_neg" ]; then
  echo "usage: $0 [--dry-run] <root> [part] [allow_neg]" >&2
  exit 2
fi

PATCH="$REPO/hw/fk33/results/card_build20_2026-09-24/build12_levers_off.patch"
CLK_CORE_MHZ=200
MEM_HIGH=24G
SWAP_KILL_BYTES=32212254720   # 30 GiB, the project's standing card-build swap guard
UNIT="jccard_$(date +%s)_$$"
SRC="$ROOT/src"
PROJDIR="$ROOT/proj"
RESULTS="$ROOT/results"
BUILD_LOG="$ROOT/build.log"

echo "JCCARD_RUN root=$ROOT part=$PART clk_core_mhz=$CLK_CORE_MHZ mem_high=$MEM_HIGH swap_kill_bytes=$SWAP_KILL_BYTES allow_neg=${ALLOW_NEG:-no}"

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  fi
}

jccard_fail() {
  echo "JCCARD_FAIL $1"
  exit 1
}

# ---- 1. the tracked tree -----------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $SRC"
  echo "+ git -C $REPO archive HEAD | tar -x -C $SRC"
else
  mkdir -p "$SRC" || jccard_fail "mkdir $SRC"
  git -C "$REPO" archive HEAD | tar -x -C "$SRC" \
    || jccard_fail "git archive HEAD into $SRC"
fi

# ---- 2. the levers patch, refusing on anything but a clean apply -------------------
run git -C "$SRC" apply --check "$PATCH"
if [ "$DRY_RUN" != 1 ]; then
  git -C "$SRC" apply --check "$PATCH" \
    || jccard_fail "build12_levers_off.patch does not apply cleanly to $SRC"
fi
run git -C "$SRC" apply "$PATCH"
if [ "$DRY_RUN" != 1 ]; then
  git -C "$SRC" apply "$PATCH" || jccard_fail "build12_levers_off.patch apply (after a clean --check) at $SRC"
fi

# ---- 3. provenance: HEAD and the patch's sha256 ------------------------------------
run git -C "$REPO" rev-parse HEAD
run sha256sum "$PATCH"
if [ "$DRY_RUN" != 1 ]; then
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD) || jccard_fail "git rev-parse HEAD"
  PATCH_SHA=$(sha256sum "$PATCH" | awk '{print $1}')
  {
    echo "head=$HEAD_SHA"
    echo "patch=$PATCH"
    echo "patch_sha256=$PATCH_SHA"
    echo "part=$PART"
    echo "clk_core_mhz=$CLK_CORE_MHZ"
  } > "$ROOT/PROVENANCE.txt"
fi

# ---- 4. regenerate the 27B card wrapper and the JC card BD/XDC/top, in $SRC -------
# JC_CARD_ENV (hw/jc/card/gen_jc_card.py), build 27B-1's generics: FK33_A_ROWS_IF
# unset, FK33_C_KV_BLOCK=16, FK33_C_MAXPOS=16384, FK33_MODEL=QWEN38_27B. This makes
# hw/fk33/rtl/fk33_card.vhd's GENSTAMP equal JC_CARD_ENV, which gen_jc_card.py then
# runs IN PLACE (card_is_jc() becomes true) instead of its scratch-copy path.
run env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
  -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
  FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
  python3 hw/fk33/gen_fk33_card.py
if [ "$DRY_RUN" != 1 ]; then
  ( cd "$SRC" && env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
      -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
      -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF \
      FK33_C_KV_BLOCK=16 FK33_C_MAXPOS=16384 FK33_MODEL=QWEN38_27B \
      python3 hw/fk33/gen_fk33_card.py ) > "$ROOT/gen_fk33_card.log" 2>&1 \
    || jccard_fail "gen_fk33_card.py (see $ROOT/gen_fk33_card.log)"
fi
run env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
  -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
  -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF -u FK33_C_KV_BLOCK -u FK33_C_MAXPOS -u FK33_MODEL \
  JC_CLK_CORE_MHZ="$CLK_CORE_MHZ" python3 hw/jc/card/gen_jc_card.py
if [ "$DRY_RUN" != 1 ]; then
  ( cd "$SRC" && env -u FK33_CARD -u FK33_CB_STYLE -u FK33_ENG -u FK33_ENG_CORE_MHZ \
      -u FK33_ENG_FAST_MHZ -u FK33_ENG_SPLIT_CLK -u FK33_FLATTEN -u FK33_SYNTH_JOBS \
      -u FK33_SYNTH_THREADS -u FK33_A_ROWS_IF -u FK33_C_KV_BLOCK -u FK33_C_MAXPOS -u FK33_MODEL \
      JC_CLK_CORE_MHZ="$CLK_CORE_MHZ" python3 hw/jc/card/gen_jc_card.py ) \
    > "$ROOT/gen_jc_card.log" 2>&1 \
    || jccard_fail "gen_jc_card.py (see $ROOT/gen_jc_card.log)"
  for f in hw/jc/card/jc_card_bd.tcl hw/jc/card/jc_card.xdc hw/jc/card/jc_card_top.vhd \
           hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd; do
    [ -s "$SRC/$f" ] || jccard_fail "gen_jc_card.py did not (re)write $f in $SRC"
  done
  grep -q "^wrote " "$ROOT/gen_jc_card.log" \
    || jccard_fail "gen_jc_card.py printed no 'wrote' line (see $ROOT/gen_jc_card.log)"
fi

# ---- 5. Vivado, capped -------------------------------------------------------------
BUILD_CARD_TCL="$SRC/hw/jc/card/build_card.tcl"
VIVADO_ARGS=("$PROJDIR" "$PART")
if [ -n "$ALLOW_NEG" ]; then VIVADO_ARGS+=(allow_neg); fi
run bash "$REPO/hw/jc/loader/run_capped.sh" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
  vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$BUILD_CARD_TCL" \
  -tclargs "${VIVADO_ARGS[@]}"
if [ "$DRY_RUN" != 1 ]; then
  bash "$REPO/hw/jc/loader/run_capped.sh" "$UNIT" "$MEM_HIGH" "$SWAP_KILL_BYTES" "$ROOT" \
    vivado -mode batch -nojournal -log "$BUILD_LOG" -source "$BUILD_CARD_TCL" \
    -tclargs "${VIVADO_ARGS[@]}"
  RC=$?
  # The sentinel is read from Vivado's OWN log, anchored, never from $RC alone: a
  # killed unit (the swap guard) and a timed-out waiter both exit non-zero with no
  # JCCARD_DONE line, and that absence is what this gates on, not the number.
  if grep -qE '^JCCARD_DONE' "$BUILD_LOG"; then
    SENTINEL_OK=1
  else
    SENTINEL_OK=0
  fi
  if [ "$SENTINEL_OK" != 1 ]; then
    REASON=$(grep -E '^JCCARD_FAIL' "$BUILD_LOG" | tail -1)
    if [ -z "$REASON" ]; then
      REASON="JCCARD_FAIL no JCCARD_DONE in $BUILD_LOG (vivado rc=$RC; check the swap guard log)"
    fi
    echo "$REASON"
    exit 1
  fi
fi

# ---- 6. harvest ---------------------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "+ mkdir -p $RESULTS"
  echo "+ cp $PROJDIR/reports/{utilization,utilization_hier,timing_summary,cdc,cdc_summary}.rpt $RESULTS/"
  echo "+ cp $PROJDIR/jc_card.bit $PROJDIR/jc_card.ltx $RESULTS/"
else
  mkdir -p "$RESULTS" || jccard_fail "mkdir $RESULTS"
  for f in utilization.rpt utilization_hier.rpt timing_summary.rpt cdc.rpt cdc_summary.rpt \
           route_status.rpt clock_interaction.rpt clocks.rpt exceptions.rpt \
           exceptions_ignored.rpt bus_skew.rpt methodology.rpt drc.rpt pulse_width.rpt \
           check_timing.rpt; do
    [ -f "$PROJDIR/reports/$f" ] && cp "$PROJDIR/reports/$f" "$RESULTS/"
  done
  [ -f "$PROJDIR/jc_card.bit" ] && cp "$PROJDIR/jc_card.bit" "$RESULTS/"
  [ -f "$PROJDIR/jc_card.ltx" ] && cp "$PROJDIR/jc_card.ltx" "$RESULTS/"
  cp "$BUILD_LOG" "$RESULTS/" 2>/dev/null || true
fi

# ---- 7. the sentinel, anchored ------------------------------------------------------
if [ "$DRY_RUN" = 1 ]; then
  echo "JCCARD_DONE (dry-run: nothing was actually run)"
  exit 0
fi
echo "JCCARD_DONE"
exit 0
