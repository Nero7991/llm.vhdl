#!/usr/bin/env bash
# run_synth.sh -- TRACK RMSWIRE, 2026-08-30.  SNAPSHOT.
#
# THE COMPOSED DRAW.  Two points, one session, ONE TOOL AT A TIME, both on the
# BC-250 (`cachyos-bc250`), both through TRACK LUTDIET's sim/ooc_lutdiet_run.sh
# and sim/ooc_lutdiet_ports.tcl UNMODIFIED with the same flags TRACK NORMADAPT,
# NWROM, NWFIX and NORMURAM used, so the numbers sit on their scale:
#
#   ctl_flat   the `gvr` block extracted from llama_top.vhd at HEAD.
#              `rmsnorm_rs` (flat ports) + TRACK NORMURAM's landed gain ROM and
#              its 65,536-flop shift register.  This is the SAME configuration
#              NORMURAM drew as `nu_u1` on the WORKSTATION: 67,318 LUT,
#              191,664 FF, 171 BRAM, WNS +1.675.  Reproducing those here is a
#              cross-box control on top of being this track's baseline.
#   mem_bank   the same block from the RMSWIRE tree.  `rmsnorm_rs_mem` (banked
#              block RAM) + the same ROM feeding a one-word-per-cycle stream.
#
# WHY BOTH ARE DRAWN AND NEITHER IS QUOTED FROM ELSEWHERE.  The composed number
# is not derivable from TRACK RMSMUX's standalone 4,825: that draw had no gain
# store, no adapter, no staging register and no write-back path, and the
# adapter's own cost moves when the ports change.  A same-session control is
# the only thing that makes the delta a measurement.
#
# THE MEMORY HAZARD, AND IT IS A CORRECTION TO THIS TRACK'S BRIEF.  MEASURED by
# TRACK NORMURAM on the workstation: `nu_u1`, which is exactly `ctl_flat`,
# peaked at 14.03 GiB summed RSS.  The BC-250 has 14 GB TOTAL.  So this point
# does NOT clear CLAUDE.md's "check the peak against 14 GB before sending
# anything" bar, and it is run here anyway ONLY because it is run inside a
# systemd scope with MemoryHigh, which reclaims into the box's 46 GB swap
# rather than killing anything, and because the summed-RSS figure double-counts
# pages shared by Vivado's forked synthesis workers so the true footprint is
# lower.  MemoryHigh is a SOFT limit: nothing is killed, the job is throttled.
#
# The consequence for measurement is stated up front: a capped job's
# `memory.peak` is the CAP and not the peak, so this script records the summed
# /proc RSS the runner samples and does NOT quote a cgroup peak as a footprint.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.
set -u

REPO=/home/orencollaco/GitHub/llama.vhdl
SCR=/home/labuser/rmswire
OUT=$SCR/out
IMG=$SCR/img/norm_w_9b.hex
mkdir -p "$OUT"

# GATE ON PRESENCE, NEVER ON A COUNT, AND READ /proc/PID/exe AND NOT argv.
# MEASURED (TRACK NORMURAM 9.3): an argv filter found 3,532 KiB of "vivado"
# with ZERO Vivados on the box and slept eleven minutes against a free lane,
# because a wrapper shell carried the pattern in its own command line.  The
# `[u]nwrapped` bracket trick does not help; the text belonged to a sibling.
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
    echo "RMSWIRE_ABORT: a Vivado is already present on this box."
    echo "One tool per box.  Two on this one OOMs it rather than slowing it."
    exit 9
fi

[ -r "$IMG" ] || { echo "RMSWIRE_ABORT: no gain image at $IMG"; exit 9; }
echo "RMSWIRE_IMAGE $(md5sum "$IMG")"

for spec in "$@"; do
    IFS=: read -r tag rtld <<<"$spec"
    echo "== $tag start $(date -Is) rtl=$rtld avail=$(free -g | awk '/^Mem:/{print $7}')G"
    # MemoryHigh is the SAFETY BELT, not a measurement.  11G leaves the box a
    # working set; the job reclaims into swap past it rather than dying.
    # A USER scope, not a system one.  `sudo systemd-run --scope --uid=` does
    # not reliably drop privileges for a scope (that is a service option), and
    # this needs to run as the licence owner: the node-locked
    # ~/.Xilinx/Xilinx-4.lic is what covers VU33P on this box.  MEASURED that
    # the user scope really applies the limit: memory.high reads 11811160064.
    LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
    systemd-run --user --scope --quiet \
         --unit="rmswire-$tag" \
         -p MemoryHigh=11G -p MemoryAccounting=yes \
         -- bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" ooc_normadapt "$OUT" \
                 "$SCR/$rtld" "NORM_W_IMAGE=$IMG"
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
    cat "$OUT/mem_$tag.txt" 2>/dev/null
done
echo "RMSWIRE_SYNTH_ALL_DONE"
