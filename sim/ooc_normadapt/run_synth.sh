#!/usr/bin/env bash
# run_synth.sh -- TRACK NORMADAPT, 2026-08-29.
#
# The three out-of-context area measurements for the D-vec norm adapter:
#
#   na_before  ooc_normadapt_ref     the adapter as it was, flat runtime slice
#   na_after   ooc_normadapt         the landed change, one word per element
#   na_shift   ooc_normadapt_shift   a PROBE, not landed: a shift register
#
# Each goes through TRACK LUTDIET's own `sim/ooc_lutdiet_run.sh` and
# `sim/ooc_lutdiet_ports.tcl`, UNMODIFIED, with the same flags TRACK WRITEDEC
# used (`-flatten_hierarchy none`, no `opt_design`, census on), so these numbers
# are directly comparable to LUTDIET's and WRITEDEC's without adjustment.
#
# ONE VIVADO AT A TIME.  Another track is synthesising on this box and a full
# OOC run has peaked at 13.9 GiB on 31 GB of RAM; two concurrently is how the
# 2026-07-04 systemd-oomd incident repeats.  This script BLOCKS until no
# `vivado` binary is running before each point, and runs its own three points
# strictly in sequence.
#
# NO HARDWARE.  synth_design and report_* only.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCR="${1:-/mnt/storage/normadapt}"
OUT="$SCR/out"
mkdir -p "$OUT"

# BLOCK UNTIL NO OTHER VIVADO IS RUNNING -- with a bounded patience, because a
# strict "wait for zero" livelocks against a track running many short points
# back to back: the gap between two of its runs can be shorter than the poll
# interval, so the wait never fires.  MEASURED here: the other track queued six
# small probe points and this loop sat through all of them.
#
# So: poll every 5 s for a genuine gap, and after PATIENCE seconds fall back to
# a MEMORY rule instead of a presence rule, since OOM is what the "one at a
# time" rule exists to prevent (systemd-oomd, 2026-07-04).  The fallback still
# refuses to start while any vivado is above BIGRSS_KIB resident.
PATIENCE="${NORMADAPT_PATIENCE:-2700}"
BIGRSS_KIB="${NORMADAPT_BIGRSS:-4194304}"
MINAVAIL_G="${NORMADAPT_MINAVAIL:-18}"

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
                echo "== patience $PATIENCE s expired; $n small vivado(s) running,"\
                     "avail=${avail}G, none above $((BIGRSS_KIB/1048576))G -- proceeding"
                return 0
            fi
        fi
        sleep 5
    done
}

one () {
    local tag="$1" top="$2" rtl="$3"
    wait_for_vivado_idle
    echo "== $tag start $(date -Is)  avail=$(free -g | awk '/^Mem:/{print $7}')G"
    LUTDIET_FLATTEN=none LUTDIET_NOOPT=1 LUTDIET_CENSUS=1 \
      bash "$REPO/sim/ooc_lutdiet_run.sh" "$tag" "$top" "$OUT" "$rtl"
    echo "== $tag rc=$? $(date -Is)"
    tail -1 "$OUT/result_$tag.csv" 2>/dev/null || echo "== $tag NO CSV"
}

# The three RTL directories are built by hand and each is `cmp`-verified into
# place before synthesis, because a run against a tree that does not carry the
# changed file yields a plausible wrong number:
#
#   rtl_before  pinned rtl/*.vhd  + ooc_normadapt_extract.py <pinned llama_top>  ooc_normadapt_ref
#   rtl_after   pinned rtl/*.vhd  + ooc_normadapt_extract.py <current llama_top> ooc_normadapt
#   rtl_shift   pinned rtl/*.vhd  + ooc_normadapt_extract.py <current> --shift   ooc_normadapt_shift
one na_before ooc_normadapt_ref   "$SCR/rtl_before"
one na_after  ooc_normadapt       "$SCR/rtl_after"
one na_shift  ooc_normadapt_shift "$SCR/rtl_shift"
echo "NORMADAPT_SYNTH_ALL_DONE"
