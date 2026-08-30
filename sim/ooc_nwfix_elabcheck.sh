#!/usr/bin/env bash
# ooc_nwfix_elabcheck.sh -- TRACK NWFIX, 2026-08-29.
#
# Two guards on the norm gain image, in cost order, and the cheap one runs
# first so the expensive one is never spent on a fault the cheap one can name.
#
#  GUARD 1 (free, no tool).  Read the image's geometry and say whether any
#  ELABORATION LOOP would exceed Vivado's per-loop-statement limit of 65,536
#  iterations.  This is the check whose absence cost TRACK NWROM a synthesis
#  run: the failure it diagnoses is reported by Vivado twenty minutes in, as
#  "loop limit (65536) exceeded" pointing at a `while` loop, which names the
#  symptom and not the cause.  It is HERE and not in VHDL on purpose --
#  MEASURED by TRACK NWROM over three OOC runs, Vivado silently ignores
#  `assert ... severity failure` during synthesis, and an out-of-range `natural`
#  constant fails with no message at all beyond `bound check failure`.  A
#  VHDL-side guard on this is weak by construction.
#
#  GUARD 2 (one Vivado elaboration).  Actually elaborate the adapter at the
#  real shape with the real image, at the tool's DEFAULT loop limit, through
#  `sim/ooc_nwfix_elabcheck.tcl`.  Guard 1 is a model of the tool; guard 2 is
#  the tool.  Only guard 2 can see a defect of a shape nobody predicted.
#
# NO HARDWARE.  synth_design -rtl only.
#
# usage: ooc_nwfix_elabcheck.sh <image> <NN> <rtldir> [top] [outdir]
#        ooc_nwfix_elabcheck.sh <image> <NN> --geometry-only
set -u

IMG="${1:?usage: ooc_nwfix_elabcheck.sh <image> <NN> <rtldir> [top] [outdir]}"
NN="${2:?}"
RTL="${3:?}"
TOP="${4:-ooc_normadapt}"
OUT="${5:-.}"

# Vivado's default elaboration loop limit, MEASURED by TRACK NWROM by bracket:
# NW_N = 9 (36,864 lines) elaborated, NW_N = 17 (69,632) did not, and the tool
# reports the number itself in [Synth 8-403].
LIMIT=65536

if [ ! -r "$IMG" ]; then
    echo "NWFIX_GEOM_FAIL image '$IMG' is not readable"
    exit 2
fi

LINES=$(wc -l < "$IMG")
if [ $(( LINES % NN )) -ne 0 ]; then
    echo "NWFIX_GEOM_FAIL '$IMG' has $LINES lines, which is not a whole number"
    echo "NWFIX_GEOM_FAIL of $NN-element norm ops.  llama_top refuses this."
    exit 2
fi
OPS=$(( LINES / NN ))
echo "NWFIX_GEOM image=$IMG lines=$LINES nn=$NN ops=$OPS limit=$LIMIT"

# The loader reads the image as an OUTER loop over norm ops and an INNER loop
# over elements.  Vivado's limit is per loop STATEMENT and not cumulative over
# nesting -- MEASURED: TRACK NWROM's `nw_bnd65` point elaborated the same
# 65 x 4096 = 266,240 nested body executions with no override at all.  So the
# two numbers that matter are the two loop bounds, and NOT their product.
BAD=0
if [ "$OPS" -ge "$LIMIT" ]; then
    echo "NWFIX_GEOM_FAIL the outer loop would run $OPS times, at or over $LIMIT."
    BAD=1
fi
if [ "$NN" -ge "$LIMIT" ]; then
    echo "NWFIX_GEOM_FAIL the inner loop would run $NN times, at or over $LIMIT."
    BAD=1
fi
if [ "$LINES" -ge "$LIMIT" ]; then
    echo "NWFIX_GEOM_NOTE $LINES lines is over the $LIMIT limit, so a loader"
    echo "NWFIX_GEOM_NOTE that reads ONE LINE PER ITERATION of a single loop"
    echo "NWFIX_GEOM_NOTE cannot elaborate this image.  llama_top's does not;"
    echo "NWFIX_GEOM_NOTE it counts in groups of NN.  If [Synth 8-403] appears"
    echo "NWFIX_GEOM_NOTE below, that structure has been reintroduced."
fi
if [ "$BAD" -ne 0 ]; then
    echo "NWFIX_GEOM_FAIL geometry alone rules this image out."
    exit 2
fi
echo "NWFIX_GEOM_PASS both loop bounds are under $LIMIT"

if [ "$RTL" = "--geometry-only" ]; then
    exit 0
fi

VIVADO="${VIVADO:-/tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado}"
TCL="$(cd "$(dirname "$0")" && pwd)/ooc_nwfix_elabcheck.tcl"
mkdir -p "$OUT"
LOG="$OUT/nwfix_elabcheck.log"

NWFIX_TOP="$TOP" NWFIX_RTL="$RTL" NWFIX_GEN="NORM_W_IMAGE=$IMG" \
  "$VIVADO" -mode batch -nojournal -notrace \
            -log "$OUT/vivado_nwfix_elabcheck.log" \
            -source "$TCL" >"$LOG" 2>&1
RC=$?

if grep -q "^NWFIX_ELAB_PASS $TOP\$" "$LOG"; then
    echo "NWFIX_ELABCHECK PASS  $TOP with $IMG ($OPS ops x $NN elements)"
    exit 0
fi
echo "NWFIX_ELABCHECK FAIL  $TOP with $IMG (vivado rc=$RC)"
grep -E "^ERROR|^NWFIX_ELAB_FAIL" "$LOG" | head -20
exit 1
