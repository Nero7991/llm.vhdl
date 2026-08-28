#!/usr/bin/env bash
# Run sim/probe_abc_ports.vhd: does D's real 491-step Qwen3.5-9B token schedule
# ever have two of subsystems A, B and C active at once?
#
# Three questions, three configurations, and they do NOT have the same answer:
#
#   1. COMPUTE windows only (TAIL = 0).  This is the claim the specs make
#      (D O13, B section 2.7, C section 2.7) and the claim the die-allocation
#      document's port mux quotes.
#   2. PORT windows (TAIL > 0).  A unit's `done` does not imply its AXI reads
#      have retired.  This is the claim the port mux actually NEEDS.
#   3. NEGATIVE CONTROL.  A unit made to compute past its own ack.  The probe
#      must report overlap, or a zero from configurations 1 and 2 is worthless.
#
# GHDL here is the mcode backend, so `ghdl -r <entity>` is run directly.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in util_pkg model_cfg_pkg seq_desc_fetch; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/seq_tbl_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/probe_abc_ports.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  ghdl -r --std=08 -frelaxed --workdir="$WORK" probe_abc_ports \
    "$@" --max-stack-alloc=0 --stop-time=2000ms 2>&1 \
    | sed -e 's/^[^:]*:[0-9]*:[0-9]*:@[^:]*:(report [a-z]*): //' \
    | grep -vE '^$'
  echo
}

echo "############ 1. compute windows, the spec's claim ############"
run "no AXI tail, fast descriptor memory" -gURAM_LAT=1
run "no AXI tail, slow descriptor memory" -gURAM_LAT=23
run "no AXI tail, two tokens"             -gURAM_LAT=1 -gTOKENS=2

echo "############ 2. port windows, the claim the mux needs ############"
run "A tail 4 cycles"    -gTAIL_A=4
run "A tail 32 cycles"   -gTAIL_A=32
run "A tail 200 cycles"  -gTAIL_A=200
run "A/B/C tails 200"    -gTAIL_A=200 -gTAIL_B=200 -gTAIL_C=200

echo "############ 3. negative control: the checker must have teeth ############"
run "unit A computes 50 cycles past its ack" -gINJECT_LATE=50 -gINJECT_UNIT=0
run "unit B computes 50 cycles past its ack" -gINJECT_LATE=50 -gINJECT_UNIT=1
