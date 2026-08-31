#!/usr/bin/env bash
# oracle_run.sh -- TRACK GAIN16, 2026-08-30.  Run the 266,240-element ROM
# oracle for one (shape, mutant) pair.  One GHDL at a time.
#
# usage: oracle_run.sh <tag> <llama_top.vhd> [mutant]
#
# NO HARDWARE.  GHDL simulation only.
set -u
REPO=${REPO:-/home/orencollaco/GitHub/llama.vhdl}
SD=${SD:-/mnt/storage/gain16}
IMG=${IMG:-/mnt/storage/nwfix/img/norm_w_9b.hex}
RES=$REPO/hw/fk33/results/gain16_2026-08-30

TAG="${1:?usage: oracle_run.sh <tag> <llama_top.vhd> [mutant]}"
SRC="${2:?}"
MUT="${3:-}"

mkdir -p "$SD/w_$TAG"
LT="$SD/lt_$TAG.vhd"
cp "$SRC" "$LT"
if [ -n "$MUT" ]; then
    python3 "$RES/mutate.py" "$LT" "$LT.m" "$MUT" || exit 9
    mv "$LT.m" "$LT"
fi

python3 "$REPO/sim/ooc_normadapt_extract.py" "$LT" "$SD/top_$TAG.vhd" || exit 9
python3 "$RES/mkprobe.py" "$SD/top_$TAG.vhd" "$SD/probe_$TAG.vhd"    || exit 9

W="$SD/w_$TAG"
cp "$REPO"/rtl/*.vhd "$W"/
rm -f "$W/llama_top.vhd"
cp "$SD/probe_$TAG.vhd" "$W/ooc_normadapt_top.vhd"
cp "$RES/gain16_romoracle.vhd" "$W"/

ghdl -i --std=08 --workdir="$W" "$W"/*.vhd            > "$SD/build_$TAG.log" 2>&1
ghdl -m --std=08 --workdir="$W" gain16_romoracle     >> "$SD/build_$TAG.log" 2>&1
BRC=$?
if [ "$BRC" -ne 0 ]; then
    echo "GAIN16_ORACLE_ROW $TAG mutant=${MUT:-none} verdict=BUILD_FAIL rc=$BRC"
    tail -5 "$SD/build_$TAG.log"
    exit 0
fi

( ulimit -s unlimited
  ghdl -r --std=08 --workdir="$W" gain16_romoracle \
       "-gNORM_W_IMAGE=$IMG" -gNVEC=65 -gNN=4096 \
       --max-stack-alloc=0 --stop-time=40ms
) > "$SD/out_$TAG.txt" 2>&1
# rc off the SUBSHELL, never off a pipeline: an rc read off a pipeline is the
# pipeline's rc, and that trap hid a SIGSEGV in TRACK GWTWO's probe.
RC=$?

V=INDETERMINATE
if grep -q "GAIN16_ORACLE PASS" "$SD/out_$TAG.txt"; then V=PASS; fi
if grep -q "GAIN16_ORACLE FAIL" "$SD/out_$TAG.txt"; then V=FAIL; fi
echo "GAIN16_ORACLE_ROW $TAG mutant=${MUT:-none} verdict=$V rc=$RC $(grep -o 'compared=[0-9]* mismatched=[0-9]* never_written=[0-9]* wrong_nidx=[0-9]*' "$SD/out_$TAG.txt" | head -1)"
grep -m1 "FIRST MISMATCH" "$SD/out_$TAG.txt" || true
