#!/usr/bin/env bash
# Simulate the two free-running-domain modules:
#   rtl/fk33_aux.vhd     against a behavioural MCP45xx digital pot
#   rtl/fk33_thermal.vhd against a driven set of temperature sensors
#
# This is the gate on the autonomous VCCINT controller, and it is not optional
# before any change to that state machine.  The controller moves a real power
# rail on an ES1 die with no host in the loop, so the assertion that it writes
# wiper 68 and nothing else has to be checked by a machine, not by reading.
#
# It also exercises the reference-clock frequency measurement over a full
# one-second window, which is the register that separates "the host gated the
# PCIe SRC clock" from "the clock is there and the link never trained".
#
# The thermal guard is the second gate, and it is not optional either.  It is
# the only thing in this bitstream that stops the part and the HBM stacks
# cooking during a long inference run -- SYSMON's own over-temperature alarm
# trips at 101 C, which is above the -2LE sustained rating of 100 C, says
# nothing about HBM, and shuts the device down when it fires.  A threshold that
# has never been crossed in simulation is not implemented, it is written down,
# so the testbench crosses every one of them, including the stale-sensor and
# stuck-at-zero paths that a value comparison alone gets wrong.
#
# ~45 s.  No card, no license beyond what Vivado already needs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HERE="$PWD"
WORK="${SIM_WORK:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/auxsim}"
mkdir -p "$WORK"

source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$WORK"

# The DUT is VHDL-93 so it matches what Vivado synthesises; the testbench needs
# 2008 for to_hstring and std.env.finish.
#
# TRAP, hit on 2026-08-28 while adding the second testbench: xelab and xsim
# write their OWN xelab.log / xsim.log into the working directory, whatever the
# shell redirection says.  Two runs in one directory therefore overwrite each
# other's logs, and the first testbench's result silently becomes the second's.
# Each run gets its own directory.
run_tb () {
    local dir="$1" rtl="$2" tb="$3" top="$4" tag="$5"
    rm -rf "$WORK/$dir"
    mkdir -p "$WORK/$dir"
    cd "$WORK/$dir"
    xvhdl       "$rtl" > compile_rtl.log 2>&1
    xvhdl -2008 "$tb"  > compile_tb.log  2>&1
    xelab -L unisim "$top" -s sim        > elab.log 2>&1
    xsim sim -runall                     > /dev/null 2>&1
    grep -E "^Note:|^Failure:|^Error:" xsim.log | grep -v "^Time:" || true
    if grep -q "$tag PASS" xsim.log; then
        echo "$tag PASS"
        return 0
    fi
    echo "$tag FAIL -- see $WORK/$dir/xsim.log"
    return 1
}

rc=0
run_tb aux   "$HERE/rtl/fk33_aux.vhd"     "$HERE/sim/tb_fk33_aux.vhd" \
             tb_fk33_aux     TB_FK33_AUX     || rc=1
run_tb therm "$HERE/rtl/fk33_thermal.vhd" "$HERE/sim/tb_fk33_thermal.vhd" \
             tb_fk33_thermal TB_FK33_THERMAL || rc=1
exit $rc
