#!/usr/bin/env bash
# run_synth3.sh -- TRACK NWFIX, 2026-08-29.  SNAPSHOT in the scratch tree.
#
# Batch 2.  Adds two things run_synth.sh could not do:
#   * a per-point TOP name, for the HBM probe;
#   * a per-point RUNNER, so the same design can be measured with and without
#     TRACK NWROM's `sim/ooc_nwrom_loopfix.tcl`.
#
# WHY THE SECOND ONE EXISTS.  `nf_fix65` measured 87,254 CLB LUT where NWROM's
# `nw_lf65` -- the same table, the same image, the same rmsnorm_rs -- measured
# 82,597.  `nw_count` is an elaboration-time function that returns 65 in both
# builds and contributes no hardware, so the two designs should be identical.
# Two explanations survive that: Vivado's constant folding is path-dependent
# (NWROM measured a 24.8% spread on exactly this block), or `maxLoopLimit` /
# `rodinMoreOptions` changes something beyond the limit.  Running the FIXED RTL
# under the override discriminates them, and it is one synthesis.
#
# NO HARDWARE.  synth_design and report_* only.
#
# usage: run_synth3.sh <tag>:<rtldir>:<image-or-empty>:<top>:<plain|lf> ...
set -u

REPO=/home/orencollaco/GitHub/llama.vhdl
SCR=/mnt/storage/nwfix
OUT=$SCR/out
mkdir -p "$OUT"

PATIENCE=2700
BIGRSS_KIB=4194304
MINAVAIL_G=18

wait_for_vivado_idle () {
    local t0 n avail big
    t0=$(date +%s)
    while :; do
        n=$(ps -eo comm | grep -cx vivado)
        [ "$n" -eq 0 ] && return 0
        if [ $(( $(date +%s) - t0 )) -ge "$PATIENCE" ]; then
            avail=$(free -g | awk '/^Mem:/{print $7}')
            big=$(ps -eo comm=,rss= | awk -v b="$BIGRSS_KIB" '$1=="vivado" && $2>b' | wc -l)
            if [ "$avail" -ge "$MINAVAIL_G" ] && [ "$big" -eq 0 ]; then
                echo "== patience expired; proceeding with $n small vivado(s), avail=${avail}G"
                return 0
            fi
        fi
        sleep 5
    done
}

for spec in "$@"; do
    IFS=: read -r tag rtld img top mode <<<"$spec"
    top="${top:-ooc_normadapt}"
    mode="${mode:-plain}"
    case "$mode" in
        plain) RUNNER="$REPO/sim/ooc_lutdiet_run.sh" ;;
        lf)    RUNNER="$REPO/sim/ooc_nwrom_loopfix_run.sh" ;;
        *)     echo "== $tag ABORT: unknown mode '$mode'"; continue ;;
    esac
    wait_for_vivado_idle
    echo "== $tag start $(date -Is) rtl=$rtld top=$top mode=$mode image='$img' avail=$(free -g | awk '/^Mem:/{print $7}')G"
    if [ -n "$img" ] && [ ! -r "$img" ]; then
        echo "== $tag ABORT: image '$img' is not readable"; continue
    fi
    if [ -n "$img" ]; then
        LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
          bash "$RUNNER" "$tag" "$top" "$OUT" "$SCR/$rtld" "NORM_W_IMAGE=$img"
    else
        LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
          bash "$RUNNER" "$tag" "$top" "$OUT" "$SCR/$rtld"
    fi
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
done
echo "NWFIX_SYNTH3_ALL_DONE"
