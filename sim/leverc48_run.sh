#!/usr/bin/env bash
# TRACK LEVERC48.  Draw lever C at the FK33 geometry, and at whatever other
# geometry is asked for, ONE VIVADO AT A TIME.
#
# WHY THIS EXISTS BESIDE sim/cbinfer_run.sh, WHICH IT OTHERWISE DUPLICATES.
# cbinfer_run.sh REBUILDS the variant directory from the current rtl/ on every
# invocation.  That is right for a single sweep and wrong the moment a track
# also EDITS rtl/: a second invocation silently replaces the frozen sources the
# first sweep's numbers were drawn against, and the two sets of numbers then
# look comparable while referring to different files.  That is the same defect
# class as a number drawn against a stale BC-250 tree, in the other direction.
#
# So this script takes an EXPLICIT variant directory and NEVER writes to it.
# The caller freezes a tree once (sim/cbinfer_variants.sh <dir>), records the
# md5s, and every later draw names that directory.
#
# USAGE
#   bash sim/leverc48_run.sh <varsdir> <outroot> <rows> <variant> [variant...]
#
#   varsdir   a directory built by sim/cbinfer_variants.sh, READ ONLY here
#   outroot   reports, logs and results.csv land under here
#   rows      ROWS_IF (48 is the FK33 shape)
#   variant   v_regs, v_dist, ... -- subdirectories of varsdir
#
# The tag written into results.csv is <basename varsdir>_<variant>_r<rows>, so
# two trees drawn at the same geometry cannot collide in one CSV.  That naming
# IS the provenance: a row whose tag does not name the tree it came from is a
# number with no file behind it.
#
# ONE VIVADO PER BOX.  Serial by construction, no background jobs.  CLAUDE.md
# records a workstation hang caused by concurrent Vivados that cost ninety
# minutes of place-and-route and a card reprogram.  Do not "speed this up".
#
# NOT HARDWARE.  synth_design and report_* only, through sim/ooc_cbinfer.tcl.
# An OOC synthesis number is not a placed one, and lever C's claim is about CLB
# PACKING, which only placement measures.

set -uo pipefail

VARS="${1:?usage: leverc48_run.sh <varsdir> <outroot> <rows> <variant>...}"
OUT="${2:?usage: leverc48_run.sh <varsdir> <outroot> <rows> <variant>...}"
ROWS="${3:?usage: leverc48_run.sh <varsdir> <outroot> <rows> <variant>...}"
shift 3
VARIANTS=("$@")
[ "${#VARIANTS[@]}" -gt 0 ] || { echo "no variants named" >&2; exit 3; }

HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="$(cd "$VARS" && pwd)"
TREE="$(basename "$VARS")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

SETTINGS=/tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
[ -f "$SETTINGS" ] || SETTINGS=/tools/Xilinx/Vivado/2023.2/settings64.sh
# shellcheck disable=SC1090
source "$SETTINGS"

# The md5 of every source actually read, printed BEFORE any tool runs.  A draw
# whose provenance is asserted afterwards is an assertion, not a record.
echo "--- $TREE: sources as read ---"
for v in "${VARIANTS[@]}"; do
  [ -d "$VARS/$v" ] || { echo "no such variant dir: $VARS/$v" >&2; exit 3; }
  printf '%-16s %s\n' "$v" "$(md5sum "$VARS/$v/matvec_core.vhd" | cut -d' ' -f1)"
done

fail=0
for v in "${VARIANTS[@]}"; do
  tag="${TREE}_${v}_r${ROWS}"
  wd="$OUT/run_$tag"
  mkdir -p "$wd"
  echo "=== $(date -Is)  START $tag ==="
  ( cd "$wd" && vivado -mode batch -nojournal -log "vivado_${tag}.log" \
      -source "$HERE/ooc_cbinfer.tcl" \
      -tclargs "$tag" "$VARS/$v" "rows=$ROWS" "outdir=$OUT" ) \
      > "$wd/stdout.txt" 2>&1
  rc=$?
  # GATE ON A SENTINEL THE WORK ITSELF WROTE, and on the report existing.
  # A Vivado run can print full success and then die on a Tcl error, and an
  # exit code alone cannot tell those apart.
  if grep -q "CBINFER_DONE $tag" "$wd/stdout.txt" && [ -s "$OUT/util_${tag}.rpt" ]; then
    echo "=== $(date -Is)  OK    $tag (rc=$rc, sentinel present, report non-empty)"
  else
    echo "=== $(date -Is)  FAIL  $tag (rc=$rc, NO sentinel or missing report) ==="
    tail -30 "$wd/stdout.txt"
    fail=1
  fi
done

echo "--- results.csv ---"
cat "$OUT/results.csv" 2>/dev/null
[ "$fail" -eq 0 ] && echo "LEVERC48_RUN_ALL_DONE" || echo "LEVERC48_RUN_HAD_FAILURES"
exit "$fail"
