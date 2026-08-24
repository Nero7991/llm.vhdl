#!/usr/bin/env bash
# Place-and-route sweep of the C lane array over LANES, to price the broadcast.
#
# Runs sequentially, not in parallel: each point takes the whole machine's
# placer threads, and two Vivado runs competing for 8 threads would make the
# wall-clock worse AND make the runs non-comparable if they interfered.
#
#   bash sim/run_micro_pnr.sh [lanes...]      default: 8 16 32 64
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
part="${MICRO_PART:-xcvu33p-fsvh2104-2L-e}"
period="${MICRO_PERIOD:-3.333}"
lanes=("${@:-}")
[[ -z "${lanes[0]:-}" ]] && lanes=(8 16 32 64)

source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
mkdir -p "$here/ooc_micro"

for n in "${lanes[@]}"; do
  echo "======== LANES=$n on $part at ${period}ns ========"
  ( cd "$here" && vivado -mode batch -nojournal \
      -log "ooc_micro/pnr_L${n}.log" -source ooc_micro_pnr.tcl \
      -tclargs "$part" "$period" micro_c_array "g:LANES=$n" \
      micro/c_lane.vhd micro/micro_c_array.vhd ) \
    | grep -E '^PNR |^ERROR|^CRITICAL' || true
done
echo "PNR_SWEEP_DONE"

# The pipelined-lane sweep is the controlled comparison: same array, same
# sharing, same LANES, lane differing only by whether the DSP48E2 input
# registers are used.  Run it with:
#   MICRO_TOP=micro_c_array_p bash sim/run_micro_pnr.sh 4 8 16 32 64
