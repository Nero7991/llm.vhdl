#!/usr/bin/env bash
# run_synth.sh -- TRACK GAIN16, 2026-08-30.  SNAPSHOT of what was run.
#
# THE QUESTION.  The composed design ROUTES (TRACK ROUTE2, 166cbd4) and BRAM is
# the last resource that does not fit: 253.5 used of 372.5 available inside
# pb_core, so +119.0 headroom without the gain image and -16.0 with the landed
# GW = 1 image's 135 tiles.  TRACK GWTWO closed 36 of the 52 and named two
# undrawn candidates for the last 16.  This script draws them.
#
# WHAT IS DRAWN.  One `ooc_normadapt` per STORAGE SHAPE, where a shape is a
# list of slice widths (low bits first) for the gain ROM.  `head` is the
# shipping file with no rewrite; every other point differs from it only in that
# ROM's shape.  sw11 and sw9 are LOSSY AREA PROBES and are labelled as such
# everywhere -- they exist to measure the tiles-vs-width curve, which is the
# thing the two candidate encodings' cost actually rests on.
#
# WHY DSP IS IN THE TABLE.  ROUTE2 measured the routed composition DSP-bound at
# 2,177 of 2,700 = 80.63% of pb_core against LUT's 68.33%, with every congested
# window DSP-saturated.  A BRAM lever that spends a DSP is a regression even if
# it wins 20 tiles.  ooc_lutdiet_ports.tcl reports dsp in the same CSV row.
#
# THE MEMORY BUDGET, STATED BEFORE DISPATCH:
#   BC-250 total 14 GB, MEASURED free 13 GB, swap 45 GB free, load 0.03, and
#   ZERO Vivado present by the /proc/PID/exe gate below.
#   This job: ONE Vivado at a time.  MEASURED precedent for the identical
#   configuration -- TRACK GWTWO's gw1, same script, same flags -- peaked at
#   11.59 GiB summed /proc RSS in 421 s.  So 1 x ~11.6 GiB against 14 GB with
#   MemoryHigh=11G reclaiming into swap.  Points run STRICTLY SEQUENTIALLY.
#   The workstation lane is held by TRACK ROUTE2 and is not touched.
#
# NO HARDWARE.  synth_design / report_* only.  Nothing here opens a target,
# programs a device, or touches /dev/xdma*.
set -u

REPO=${REPO:-/home/orencollaco/GitHub/llama.vhdl}
SCR=${SCR:-/home/labuser/gain16}
OUT=$SCR/out
IMG=${IMG:-/home/labuser/rmswire/img/norm_w_9b.hex}
mkdir -p "$OUT"

# GATE ON PRESENCE, NEVER ON A COUNT, AND READ /proc/PID/exe AND NOT argv.
vivado_rss_kib () {
    local s=0 p exe rss
    for p in /proc/[0-9]*; do
        exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
        case "$exe" in
            */unwrapped/lnx64.o/vivado)
                rss=$(awk '/^VmRSS:/{print $2}' "$p/status" 2>/dev/null)
                s=$(( s + ${rss:-0} )) ;;
        esac
    done
    echo "$s"
}

if [ "$(vivado_rss_kib)" -ne 0 ]; then
    echo "GAIN16_ABORT: a Vivado is already present on this box."
    exit 9
fi

[ -r "$IMG" ] || { echo "GAIN16_ABORT: no gain image at $IMG"; exit 9; }
echo "GAIN16_IMAGE $(md5sum "$IMG")"

for tag in "$@"; do
    rtld="$SCR/rtl_$tag"
    [ -d "$rtld" ] || { echo "GAIN16_ABORT: no rtl dir $rtld"; exit 9; }
    echo "== $tag start $(date -Is) rtl=$rtld avail=$(free -g | awk '/^Mem:/{print $7}')G"
    echo "== $tag topmd5 $(md5sum "$rtld/ooc_normadapt_top.vhd")"
    LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
    systemd-run --user --scope --quiet \
         --unit="gain16-$tag" \
         -p MemoryHigh=11G -p MemoryAccounting=yes \
         -- bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" ooc_normadapt "$OUT" \
                 "$rtld" "NORM_W_IMAGE=$IMG"
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
    cat "$OUT/mem_$tag.txt" 2>/dev/null
done
echo "GAIN16_SYNTH_ALL_DONE"
