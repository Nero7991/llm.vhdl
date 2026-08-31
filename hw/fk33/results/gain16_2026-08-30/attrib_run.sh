#!/usr/bin/env bash
# attrib_run.sh -- TRACK GAIN16, 2026-08-30.  THE ATTRIBUTION CONTROL.
#
# For every mutant the new 266,240-element ROM oracle kills, run the SAME
# mutant through the PRE-EXISTING gate row `sim:tb_llama_top_normw` and record
# whether that row would have caught it anyway.  A kill an existing property
# would have caught does not belong to the new check.  MEASURED 2026-08-29:
# without this control a track would have credited its new check with four
# detections instead of three.
#
# Each row is a PRISTINE `git archive` of the pinned SHA with exactly one file
# replaced, so a red row cannot be somebody else's in-flight edit.
#
# usage: attrib_run.sh <tag> <llama_top.vhd> [mutant]
#
# NO HARDWARE.  GHDL simulation only.
set -u
REPO=${REPO:-/home/orencollaco/GitHub/llama.vhdl}
SD=${SD:-/mnt/storage/gain16/attrib}
SHA=${SHA:?SHA must be pinned by the caller as its own step}
RES=$REPO/hw/fk33/results/gain16_2026-08-30

TAG="${1:?usage: attrib_run.sh <tag> <llama_top.vhd> [mutant]}"
SRC="${2:?}"
MUT="${3:-}"

T="$SD/t_$TAG"
mkdir -p "$T"
git -C "$REPO" archive "$SHA" | tar -x -C "$T"

cp "$SRC" "$T/rtl/llama_top.vhd"
if [ -n "$MUT" ]; then
    python3 "$RES/mutate.py" "$T/rtl/llama_top.vhd" "$T/rtl/llama_top.vhd.m" "$MUT" || exit 9
    mv "$T/rtl/llama_top.vhd.m" "$T/rtl/llama_top.vhd"
fi

MV4I_FK33_FILE=/nonexistent REGRESS_SCRATCH="$SD/s_$TAG" \
  bash "$T/sim/regress.sh" --only tb_llama_top_normw --jobs 1 \
  > "$SD/reg_$TAG.log" 2>&1
RC=$?
# Read the OVERALL line, never the "REGRESSION: PASS" line: --only takes a
# SUBSTRING, a non-match still prints REGRESSION: PASS, and the only tell is
# PASS 0.
OV=$(grep -oE "OVERALL +PASS +[0-9]+ +FAIL +[0-9]+" "$SD/reg_$TAG.log" | tr -s " " | tail -1)
echo "GAIN16_ATTRIB_ROW $TAG mutant=${MUT:-none} rc=$RC ${OV:-NO_OVERALL_LINE}"
