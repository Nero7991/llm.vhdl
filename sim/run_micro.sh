#!/usr/bin/env bash
# Run the single-lane micro-synths on the REAL FK33 part and grade.
#
# The part matters and the grade matters.  docs/fpga-hardware-recon.md pins the
# FK33 at xcvu33p-fsvh2104-2L-e -- the LOW-POWER grade, not the -2 used for the
# first sizing sweep.  Sizing on -2 and deploying on -2L is how an Fmax margin
# evaporates between spreadsheet and bitstream.
#
#   bash sim/run_micro.sh [c|b|both]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
part="${MICRO_PART:-xcvu33p-fsvh2104-2L-e}"
period="${MICRO_PERIOD:-3.333}"     # 300 MHz, the fabric clock section 13 assumes
which="${1:-both}"

source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh

run() {
  local top="$1"; shift
  echo "======== $top on $part at ${period}ns ========"
  ( cd "$here" && vivado -mode batch -nojournal -log "ooc_micro/${top}.log" \
      -source ooc_micro.tcl -tclargs "$part" "$period" "$top" "$@" ) \
    | tee "$here/ooc_micro/${top}.stdout.log" | grep -E 'MICRO|WARNING:|ERROR'
}

mkdir -p "$here/ooc_micro"
[[ "$which" == "c" || "$which" == "both" ]] && run micro_c_lane micro/micro_c_lane.vhd
[[ "$which" == "b" || "$which" == "both" ]] && run micro_b_lane micro/micro_b_lane.vhd
echo "ALL_MICRO_DONE"
