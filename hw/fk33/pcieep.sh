#!/usr/bin/env bash
# Bring the FK33 up as a PCIe endpoint, in the only order that works.
#
#   ./pcieep.sh            full sequence: VCCINT, then the endpoint, then check
#   ./pcieep.sh --no-vccint  skip the VCCINT stage (it is already raised)
#   ./pcieep.sh --check      JTAG-side check only, configure nothing
#
# WHY THE ORDER MATTERS
# ---------------------
# VCCINT powers up at 0.678 V, below the 0.698 V floor of the -2L grade, and
# the fix is a VOLATILE digital-pot wiper that is lost on every power cycle.
# The pot is driven by bit-banging I2C from the GPIO in the PROBE bitstream.
#
# Reconfiguring the FPGA does NOT power-cycle the board, so the wiper survives
# a change of bitstream.  Hence:
#
#   1. configure the PROBE bitstream          (GPIO bit-bang available)
#   2. step VCCINT 0.678 -> 0.717 V           (tcl/vccint_step.tcl, unchanged)
#   3. configure the ENDPOINT bitstream       (wiper survives; die now in spec)
#   4. host: rescan PCIe                      (see host/fk33_pcie_check.sh)
#
# Doing it the other way round -- endpoint first, then VCCINT -- does not work
# over JTAG, because in the endpoint bitstream the whole AXI fabric (including
# the JTAG-AXI masters) is clocked and reset by xdma, so it is dead until the
# link is up.  Once the link IS up, VCCINT can be raised from the host instead,
# over the AXI-Lite BAR: host/fk33ctl.py vccint.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Prefer the SAVED copies under hw/fk33/bit/.  The build writes into a
# per-session scratchpad under /tmp, and /tmp on this box is emptied at every
# boot (`D /tmp` in /usr/lib/tmpfiles.d/tmp.conf, and systemd-tmpfiles-setup
# runs with --remove --boot; verified 2026-08-27).  Fitting the card requires
# a power-off, so a bitstream left in /tmp does not survive to the moment it
# is needed.  ./save_bitstream.sh copies them here.
BITDIR="${FK33_BITDIR:-$PWD/bit}"
BUILD_ROOT="${BUILD_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep}"
if [[ -z "${EP_BIT:-}" && -f "$BITDIR/fk33_pcieep.bit" ]]; then
    EP_BIT="$BITDIR/fk33_pcieep.bit"
fi
EP_BIT="${EP_BIT:-$BUILD_ROOT/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit}"
if [[ -z "${PROBE_BIT:-}" && -f "$BITDIR/fk33_i2cprobe.bit" ]]; then
    PROBE_BIT="$BITDIR/fk33_i2cprobe.bit"
fi
PROBE_BIT="${PROBE_BIT:-$PWD/fk33_i2cprobe/fk33_i2cprobe.runs/impl_1/bd_wrapper.bit}"
case "$EP_BIT" in /tmp/*)
    echo "WARNING: the endpoint bitstream is under /tmp, which this box clears"
    echo "         at every boot.  Run ./save_bitstream.sh before powering off." ;;
esac

MODE="${1:-full}"

prog () {   # $1 = bitstream.  xsdb, not Vivado: see tcl/program.tcl.
    [[ -f "$1" ]] || { echo "BITSTREAM_MISSING $1" >&2; exit 1; }
    echo "=== configuring $(basename "$(dirname "$(dirname "$(dirname "$1")")")") ==="
    echo "    $1 ($(stat -c %s "$1") bytes, $(stat -c %y "$1" | cut -d. -f1))"
    pkill -f "[b]in/unwrapped/lnx64.o/hw_server" 2>/dev/null || true
    pkill -f "[b]in/unwrapped/lnx64.o/cs_server" 2>/dev/null || true
    sleep 2
    # `< /dev/null` IS LOAD-BEARING.  xsdb runs itself under rlwrap, which
    # holds the terminal waiting on stdin after the Tcl has finished, so a
    # SUCCESSFUL configure hung until `timeout 300` killed it -- exit 124,
    # which `set -euo pipefail` turned into a silent abort of the whole
    # sequence, after FPGA_PROG_OK had already printed.  It only ever worked
    # when stdin was not a tty, i.e. for every automated caller and for no
    # human one.  Measured: identical command with and without the redirect,
    # EXIT=124 vs EXIT=0.  tcl/program.tcl also gained an explicit `exit 0`,
    # which is correct but is NOT by itself sufficient -- rlwrap outlives it.
    ( source /tools/Xilinx/2023.2/Vitis/2023.2/settings64.sh
      FK33_BIT="$1" timeout 300 xsdb tcl/program.tcl < /dev/null ) 2>&1 \
        | grep -E "FPGA_PROG|xcvu33p|JTAG2AXI|Debug Hub"
}

if [[ "$MODE" != "--check" ]]; then
    if [[ "$MODE" != "--no-vccint" ]]; then
        prog "$PROBE_BIT"
        echo "=== stage 2: raising VCCINT (volatile, lost on power cycle) ==="
        JTAG_TIMEOUT=900 ./jtag.sh tcl/vccint_step.tcl 2>&1 | grep -vE "^# " | \
            sed -nE '/START/,/(SETTLED|ABORT|DONE)/p'
    fi
    prog "$EP_BIT"
    echo
    echo "The card is now configured as a PCIe endpoint."
    echo "If the link trains, LED 6 (RGB blue) changes state.  Note which way."
    sleep 3
fi

echo "=== stage 3: JTAG-side check of the endpoint bitstream ==="
echo "NOTE: every read below goes through xdma/axi_aclk.  If they all hang or"
echo "      return garbage, that is EXPECTED when the link is down -- it does"
echo "      not distinguish a bad bitstream from an untrained link.  A SUCCESS"
echo "      here is conclusive the other way: it means refclk, PCIe user clock"
echo "      and link-up are all real."
JTAG_TIMEOUT=300 ./jtag.sh tcl/pcieep_jtag.tcl 2>&1 | grep -vE "^# " | \
    sed -n '/PCIEEP_CHECK/,/PCIEEP_DONE/p'
