#!/usr/bin/env bash
# ooc_compose4_run.sh -- TRACK COMPOSE4, 2026-08-29.
#
# Drive sim/ooc_compose4_pnr.tcl through its stages, one Vivado at a time.
#
#   elab      synth_design -rtl only.  Minutes.  Catches every binding, width
#             and visibility error in the generated top before an hour is spent.
#   synth     full out-of-context synthesis, checkpointed.
#   impl_pb   opt + place + phys_opt + route INSIDE a pb_core-shaped pblock.
#             This is the real question: pb_core is CLOCKREGION_X0Y0:X6Y3 and
#             hw/fk33/build_fk33_pcieep.tcl:1749 errors if the shipping build's
#             range is anything else.
#   impl_dev  the same, unconstrained on the whole die.  Run SECOND, because a
#             failure to place inside pb_core and a success on the whole die
#             are two different findings and both are worth having.
#
# NO HARDWARE.  Nothing here opens a cable, a target or a device.
#
# ONE VIVADO AT A TIME.  Three other tracks are synthesising on this box, the
# box has 31 GB, and systemd-oomd killed a 275-process cgroup here on
# 2026-07-04.  Each stage blocks until no other vivado is running, with the
# same bounded-patience fallback TRACK NORMADAPT measured to be necessary (a
# strict "wait for zero" livelocks against a track running many short points
# back to back).
#
# usage:  bash sim/ooc_compose4_run.sh <scratch-dir> [stage ...]
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCR="${1:-/mnt/storage/compose4}"
shift || true
STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(elab synth impl_pb impl_dev)

export PATH=/tools/Xilinx/2023.2/Vivado/2023.2/bin:$PATH
OUT="$SCR/out"
LOGS="$SCR/logs"
TREE="$SCR/tree"
mkdir -p "$OUT" "$LOGS"

PATIENCE="${C4_PATIENCE:-3600}"
BIGRSS_KIB="${C4_BIGRSS:-4194304}"
MINAVAIL_G="${C4_MINAVAIL:-18}"

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
                echo "== patience expired; $n small vivado(s), avail=${avail}G -- proceeding"
                return 0
            fi
        fi
        sleep 20
    done
}

# Peak RSS of the stage, sampled, because /usr/bin/time -v reports the peak of
# the SHELL when vivado forks SYNTH_DESIGN_PARENT workers.  Counting
# `unwrapped/lnx64.o/vivado` processes overstates concurrency for the same
# reason (measured by another track tonight), so this sums the whole tree.
sample_mem () {
    local out="$1"; shift
    ( while :; do
        ps -eo rss=,comm= | awk '$2 ~ /vivado|rdiArgs|synth/ {s+=$1} END {print s}'
        sleep 20
      done ) > "$out" &
    echo $!
}

run_stage () {
    local stage="$1"; shift
    local log="$LOGS/$stage.stdout"
    echo "== $stage START $(date -Is)  avail=$(free -g | awk '/^Mem:/{print $7}')G"
    wait_for_vivado_idle
    local mp; mp=$(sample_mem "$LOGS/$stage.mem")
    ( set -x; env "$@" vivado -mode batch -nojournal \
        -log "$LOGS/$stage.vivado.log" \
        -source "$REPO/sim/ooc_compose4_pnr.tcl" ) > "$log" 2>&1
    local rc=$?
    kill "$mp" 2>/dev/null
    local peak; peak=$(sort -n "$LOGS/$stage.mem" 2>/dev/null | tail -1)
    echo "== $stage rc=$rc peakRSS_kib=${peak:-NA} $(date -Is)"
    grep -E '^C4_(DONE|UTIL|TIMING|ROUTE_STATUS|CLKWNS|BUFG|SYNTH_SECONDS|OPT_SECONDS|PLACE_SECONDS|ROUTE_SECONDS|PHYSOPT_SECONDS|PBLOCK_RANGE)' "$log" || true
    # THE SENTINEL, not the exit code and not the last log line.  A Vivado run
    # can print full success and then die on a Tcl error afterwards; that has
    # happened in this project (`lsort -stride` after a complete synthesis).
    if ! grep -q "^C4_DONE" "$log"; then
        echo "== $stage NO SENTINEL -- treating as FAILED"
        grep -E '^ERROR' "$log" | head -20
        return 1
    fi
    return 0
}

for s in "${STAGES[@]}"; do
    case "$s" in
    elab)
        run_stage elab C4_RTL="$TREE/rtl" C4_FK33RTL="$TREE/hw/fk33/rtl" \
            C4_STAGE=elab C4_TAG=c4 C4_OUT="$OUT" || exit 1
        ;;
    synth)
        run_stage synth C4_RTL="$TREE/rtl" C4_FK33RTL="$TREE/hw/fk33/rtl" \
            C4_STAGE=synth C4_TAG=c4 C4_OUT="$OUT" || exit 1
        ;;
    impl_pb)
        run_stage impl_pb C4_STAGE=impl C4_TAG=c4pb C4_OUT="$OUT" \
            C4_DCP="$OUT/c4_synth.dcp" C4_PBLOCK=1 || echo "== impl_pb FAILED, continuing"
        ;;
    impl_dev)
        run_stage impl_dev C4_STAGE=impl C4_TAG=c4dev C4_OUT="$OUT" \
            C4_DCP="$OUT/c4_synth.dcp" C4_PBLOCK=0 || echo "== impl_dev FAILED, continuing"
        ;;
    *) echo "unknown stage $s"; exit 2;;
    esac
done
echo "COMPOSE4_RUN_ALL_DONE $(date -Is)"
