#!/usr/bin/env bash
# TRACK CBINFER runner.  Builds the RTL variants and synthesises each one, ONE
# VIVADO AT A TIME.
#
# ONE AT A TIME IS NOT A STYLE CHOICE.  CLAUDE.md records a workstation hang
# caused by concurrent Vivados, and a single OOC synthesis has been MEASURED at
# 10.58-10.85 GB on the BC-250's 14 GB.  A second tool does not fit.  This
# script is a serial loop with no background jobs for that reason; do not
# "speed it up" by backgrounding the runs.
#
# USAGE  bash sim/cbinfer_run.sh <scratchroot> [rows] [variants...]
#
# The default variant order puts the two runs that answer the question first
# (v_regs then v_dist), so a run that is killed part way still answers it.

set -uo pipefail

ROOT="${1:?usage: cbinfer_run.sh <scratchroot> [rows] [variants...]}"
ROWS="${2:-4}"
shift 2 2>/dev/null || shift 1 2>/dev/null || true
VARIANTS=("$@")
if [ "${#VARIANTS[@]}" -eq 0 ]; then
  VARIANTS=(v_regs v_dist v_distlit v_dist_noattr v_distlit_nodt v_regs_noattr)
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

mkdir -p "$ROOT"
bash "$HERE/cbinfer_variants.sh" "$ROOT/vars" || exit 3

SETTINGS=/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
if [ ! -f "$SETTINGS" ]; then SETTINGS=/tools/Xilinx/Vivado/2023.2/settings64.sh; fi
# shellcheck disable=SC1090
source "$SETTINGS"

for v in "${VARIANTS[@]}"; do
  rd="$ROOT/vars/$v"
  wd="$ROOT/run_${v}_r${ROWS}"
  if [ ! -d "$rd" ]; then echo "no such variant dir: $rd" >&2; exit 3; fi
  mkdir -p "$wd"
  echo "=== $(date -Is)  START $v  ROWS_IF=$ROWS ==="
  ( cd "$wd" && vivado -mode batch -nojournal -log "vivado_${v}.log" \
      -source "$HERE/ooc_cbinfer.tcl" \
      -tclargs "${v}_r${ROWS}" "$rd" "rows=$ROWS" "outdir=$ROOT/out" ) \
      > "$wd/stdout.txt" 2>&1
  rc=$?
  # GATE ON A SENTINEL THE WORK ITSELF WROTE, never on the exit code alone.
  # CLAUDE.md: a Vivado run can print full success and then die on a Tcl error,
  # and a waiter that fires on a killed job is not a completion signal.
  if grep -q "CBINFER_DONE ${v}_r${ROWS}" "$wd/stdout.txt" \
     && [ -s "$ROOT/out/util_${v}_r${ROWS}.rpt" ]; then
    echo "=== $(date -Is)  OK    $v  (rc=$rc, sentinel present, report non-empty)"
  else
    echo "=== $(date -Is)  FAIL  $v  (rc=$rc, NO sentinel or missing report) ==="
    tail -30 "$wd/stdout.txt"
  fi
done

echo "--- results.csv ---"
cat "$ROOT/out/results.csv" 2>/dev/null
echo "CBINFER_RUN_ALL_DONE"
