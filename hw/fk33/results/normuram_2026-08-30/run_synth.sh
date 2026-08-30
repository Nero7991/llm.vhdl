#!/usr/bin/env bash
# run_synth.sh -- TRACK NORMURAM, 2026-08-30.  SNAPSHOT, lives in the scratch
# tree and is NEVER edited while it is running: TRACK NWROM measured (its
# section 7.1) that editing a bash script a running instance is reading resumes
# that instance at a byte offset that no longer means what it did.
#
# Every point goes through TRACK LUTDIET's sim/ooc_lutdiet_run.sh and
# sim/ooc_lutdiet_ports.tcl UNMODIFIED, with the same flags TRACK NORMADAPT,
# TRACK NWROM and TRACK NWFIX used, so these numbers sit on the same scale as
# theirs.  No `maxLoopLimit` anywhere: the tool runs at its DEFAULT limit.
#
# NO HARDWARE.  synth_design and report_* only.
#
# usage: run_synth.sh <tag>:<rtldir>:<image-or-empty> ...
set -u

REPO=/home/orencollaco/GitHub/llama.vhdl
SCR=/mnt/storage/normuram
OUT=$SCR/out
mkdir -p "$OUT"

# GATE ON PRESENCE AND ON SUMMED RSS, NEVER ON A COUNT.  Vivado's launcher is
# a chain of bash scripts also named `vivado`, so `pgrep -x vivado` shows FOUR
# processes for one tool -- and the unwrapped-path filter shows FIVE, because
# the tool forks parallel-synthesis workers that inherit the parent's argv.
# A count therefore means nothing in either form.  MEASURED and corrected in
# CLAUDE.md at abe39a4 on 2026-08-30.
#
# AND A COUNT OF ZERO IS NOT AN ALL-CLEAR EITHER.  A run that is loading a
# checkpoint is between peaks, so a momentarily quiet box says nothing about
# the next thirty seconds.  That is the race that hung this box on 2026-08-30.
# This script is therefore run ONLY on an explicit go from the dispatcher, and
# this gate is a backstop for a point that starts while an earlier one of MY
# OWN points is still finishing.
PATIENCE=3600
MINAVAIL_G=16

# READ /proc/PID/exe, NOT argv.  MEASURED here at 08:23 on 2026-08-30: an
# argv match on the unwrapped path found 3,532 KiB of "vivado" with ZERO
# Vivados on the box, because a long-lived tool-wrapper shell carried the
# pattern in its own command line, and this waiter then slept for eleven
# minutes against a lane that was free.  That is the CLAUDE.md self-match
# trap, which is usually stated for `pgrep -f` and applies identically to
# `ps -eo args=`.  The executable link cannot be spoofed by a command line.
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

wait_for_vivado_idle () {
    local t0 avail rss
    t0=$(date +%s)
    while :; do
        rss=$(vivado_rss_kib)
        [ "$rss" -eq 0 ] && return 0
        if [ $(( $(date +%s) - t0 )) -ge "$PATIENCE" ]; then
            avail=$(free -g | awk '/^Mem:/{print $7}')
            if [ "$avail" -ge "$MINAVAIL_G" ]; then
                echo "== patience expired; vivado rss $((rss/1024))M, ${avail}G available, proceeding"
                return 0
            fi
        fi
        sleep 10
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
echo "NORMURAM_SYNTH_ALL_DONE"
