#!/usr/bin/env bash
# run_equiv.sh -- TRACK NORMADAPT, 2026-08-29.
#
# The bit-exactness oracle for the D-vec norm adapter rewrite.  Extracts the
# `gvr` generate block from the PINNED pre-change `llama_top.vhd` and from the
# CURRENT one, analyses both alongside the pinned rest of `rtl/`, and runs
# `ooc_normadapt_equiv` at six shapes.  The reference is the PRE-CHANGE RTL,
# never the new one compared against itself.
#
# usage: run_equiv.sh <scratchdir> [current_llama_top.vhd]
#   <scratchdir>/src must be a `git archive` of the pinned tree.
#
# NO HARDWARE.  GHDL only.
set -u

SCR="${1:?usage: run_equiv.sh <scratchdir> [llama_top.vhd]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CUR="${2:-$REPO/rtl/llama_top.vhd}"

mkdir -p "$SCR/gen"
python3 "$REPO/sim/ooc_normadapt_extract.py" \
        "$SCR/src/rtl/llama_top.vhd" "$SCR/gen/ooc_normadapt_before.vhd" \
        ooc_normadapt_ref || exit 1
python3 "$REPO/sim/ooc_normadapt_extract.py" \
        "$CUR" "$SCR/gen/ooc_normadapt_after.vhd" ooc_normadapt || exit 1

W="$SCR/work"
rm -rf "$W"; mkdir -p "$W"
cd "$W" || exit 1
for f in util_pkg model_cfg_pkg llama_map_pkg fixed_luts_pkg fixed_pkg rmsnorm_rs; do
    ghdl -a --std=08 -frelaxed --workdir=. "$SCR/src/rtl/$f.vhd" || exit 1
done
ghdl -a --std=08 -frelaxed --workdir=. "$SCR/gen/ooc_normadapt_before.vhd" || exit 1
ghdl -a --std=08 -frelaxed --workdir=. "$SCR/gen/ooc_normadapt_after.vhd"  || exit 1
ghdl -a --std=08 -frelaxed --workdir=. "$HERE/ooc_normadapt_equiv.vhd"     || exit 1

rc=0
# NN, LANES.  NB = NN/LANES, so "8 8" is NB = 1 and "16 1" is LANES = 1: both
# are corners of rmsnorm_rs's banked emit and of the generate this change adds.
for cfg in "64 4" "8 8" "16 1" "128 4" "32 2" "256 8"; do
    set -- $cfg
    out=$(timeout 1800 ghdl -r --std=08 -frelaxed --workdir=. \
            ooc_normadapt_equiv -gNN_G="$1" -gLANES_G="$2" -gRESETMID=true \
            -gVERBOSE=true --max-stack-alloc=0 --stop-time=900ms 2>&1)
    prc=${PIPESTATUS[0]}
    if echo "$out" | grep -q "NORMADAPT_EQUIV PASS"; then
        echo "$out" | grep -E "NORMADAPT_EQUIV PASS|trial cls="
    else
        echo "FAIL NN=$1 LANES=$2 rc=$prc"
        echo "$out" | tail -20
        rc=1
    fi
done
exit "$rc"
