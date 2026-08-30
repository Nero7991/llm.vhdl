#!/usr/bin/env bash
# run_synth.sh -- TRACK NWFIX, 2026-08-29.  SNAPSHOT, lives in the scratch tree.
#
# It is deliberately NOT in the repo and is never edited while it is running:
# TRACK NWROM measured (its section 7.1) that editing a bash script a running
# instance is reading resumes that instance at a byte offset that no longer
# means what it did, and killed a batch's sentinel that way.
#
# Every point goes through TRACK LUTDIET's sim/ooc_lutdiet_run.sh and
# sim/ooc_lutdiet_ports.tcl UNMODIFIED, with the same flags TRACK NORMADAPT and
# TRACK NWROM used, so these numbers sit on the same scale as theirs.
#
# NOTE THE ABSENCE.  There is no `sim/ooc_nwrom_loopfix.tcl` here and no
# `maxLoopLimit` anywhere.  The whole point is that the fixed loader elaborates
# with the tool at its DEFAULT limit.
#
# NO HARDWARE.  synth_design and report_* only.
#
# usage: run_synth.sh <tag>:<rtldir>:<image-or-empty> ...
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
    IFS=: read -r tag rtld img <<<"$spec"
    wait_for_vivado_idle
    echo "== $tag start $(date -Is) rtl=$rtld image='$img' avail=$(free -g | awk '/^Mem:/{print $7}')G"
    if [ -n "$img" ] && [ ! -r "$img" ]; then
        echo "== $tag ABORT: image '$img' is not readable"
        continue
    fi
    if [ -n "$img" ]; then
        LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
          bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" ooc_normadapt "$OUT" \
               "$SCR/$rtld" "NORM_W_IMAGE=$img"
    else
        LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
          bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" ooc_normadapt "$OUT" \
               "$SCR/$rtld"
    fi
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
done
echo "NWFIX_SYNTH_ALL_DONE"
