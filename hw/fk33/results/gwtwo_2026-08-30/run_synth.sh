#!/usr/bin/env bash
# run_synth.sh -- TRACK GWTWO, 2026-08-30.  SNAPSHOT of what was run.
#
# THE QUESTION.  The norm gain image is 171 RAMB36 at GW = 4 and is the
# dominant term in a BRAM sum that is 51 tiles over what pb_core has.  TRACK
# NORMURAM named `GW = 2` as "the obvious next measurement if BRAM binds" and
# never took it.  This script takes it, and takes 1 and 8 as well, because the
# question is the SHAPE OF THE CURVE and not whether one point is better.
#
# WHAT IS DRAWN.  `sim/ooc_normadapt_extract.py` pulls llama_top.vhd's `gvr`
# generate block out verbatim, so the four points differ by EXACTLY one line:
#
#     if n mod <GW> = 0 then return <GW>; else return 1; end if;
#
# and the GW = 4 source file is BYTE-IDENTICAL to rtl/llama_top.vhd at HEAD
# (md5 6f0aa7fdd349f76724c19090303b619c), which makes gw4 a same-session
# reproduction of TRACK RMSWIRE's `mem_bank` rather than a new configuration.
# If gw4 does not reproduce RMSWIRE field for field, this harness is not on
# their scale and no delta drawn against it means anything.
#
# THE MEMORY BUDGET, STATED BEFORE DISPATCH (CLAUDE.md requires the arithmetic
# to be written down, not merely done):
#   BC-250 total 14 GB, MEASURED free 13 GB, swap 46 GB, load 0.03, and
#   ZERO Vivado present by the /proc/PID/exe gate below.
#   This job: ONE Vivado at a time.  MEASURED precedent for the identical
#   configuration -- TRACK RMSWIRE's `mem_bank`, same script, same flags --
#   peaked at 11.69 GiB summed /proc RSS and completed rc=0 in 425 s.
#   So: 1 x ~11.7 GiB against 14 GB with MemoryHigh=11G reclaiming into swap.
#   The four points run STRICTLY SEQUENTIALLY.  The workstation lane is held
#   by TRACK LEVERC48 and is not touched.
#
# CORRECTION TO THE ORIGINAL SIZING IN MY BRIEF: the brief said "a gvr-region
# draw should be far smaller" than RMSWIRE's 17.3 GiB composed llama_top peak.
# It is not a different draw -- it IS RMSWIRE's draw.  RMSWIRE's `ctl_flat`
# and `mem_bank` were themselves gvr-region extractions, not llama_top, and
# 11.69 GiB is what a gvr-region draw costs.  See CORRECTION_TO_BRIEF.txt.
#
# NO HARDWARE.  synth_design / report_* only.  Nothing here opens a target,
# programs a device, or touches /dev/xdma*.
set -u

REPO=/home/orencollaco/GitHub/llama.vhdl
SCR=/home/labuser/gwtwo
OUT=$SCR/out
IMG=/home/labuser/rmswire/img/norm_w_9b.hex
mkdir -p "$OUT"

# GATE ON PRESENCE, NEVER ON A COUNT, AND READ /proc/PID/exe AND NOT argv.
# An argv filter matches sibling shells and ugrep that merely carry the text,
# and the [u]nwrapped bracket trick does not help because the text belongs to
# a different process.  MEASURED by TRACK NORMURAM: 3,532 KiB of "vivado" with
# zero Vivados running, and eleven minutes slept against a free lane.
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
    echo "GWTWO_ABORT: a Vivado is already present on this box."
    exit 9
fi

[ -r "$IMG" ] || { echo "GWTWO_ABORT: no gain image at $IMG"; exit 9; }
echo "GWTWO_IMAGE $(md5sum "$IMG")"

for G in "$@"; do
    tag="gw$G"
    rtld="$SCR/rtl_gw$G"
    [ -d "$rtld" ] || { echo "GWTWO_ABORT: no rtl dir $rtld"; exit 9; }
    echo "== $tag start $(date -Is) rtl=$rtld avail=$(free -g | awk '/^Mem:/{print $7}')G"
    echo "== $tag topmd5 $(md5sum "$rtld/ooc_normadapt_top.vhd")"
    LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
    systemd-run --user --scope --quiet \
         --unit="gwtwo-$tag" \
         -p MemoryHigh=11G -p MemoryAccounting=yes \
         -- bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" ooc_normadapt "$OUT" \
                 "$rtld" "NORM_W_IMAGE=$IMG"
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
    cat "$OUT/mem_$tag.txt" 2>/dev/null
done
echo "GWTWO_SYNTH_ALL_DONE"
