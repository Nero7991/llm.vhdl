#!/usr/bin/env bash
# Build the PCIe Gen3 x4 XDMA endpoint bitstream for the FK33.
#
# Run this on a machine that is not doing anything else.  Vivado has OOM-killed
# this workstation before (see the DevOps notes on systemd-oomd taking the whole
# code-server cgroup); prefer the BC-250, or run under claude-tmux --mem.
#
# Expect ~1-1.5 h.  Nothing here touches the card.
#
#   ./pcieep_build.sh            full build, through to a bitstream
#   ./pcieep_build.sh --bd-only  block design, address map and validation only.
#                                MEASURED: about 3 minutes, 3.4 GB peak, no
#                                synthesis.  Run this after any edit to
#                                gen_pcieep.py -- it catches every class of
#                                error that is not a timing or placement
#                                result, at 1/20th of the cost.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FK33_DIR="$PWD"   # hw/fk33; line 72 cds into BUILD_ROOT and never returns

BD_ONLY=0
[[ "${1:-}" == "--bd-only" ]] && BD_ONLY=1

BUILD_ROOT="${BUILD_ROOT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep}"

echo "=== regenerating the build script from the probe build ==="
python3 gen_i2cprobe.py
# The subsystem-A wrapper.  Generated, not committed-and-forgotten, because the
# HBM port map in gen_pcieep.py and the master count in gen_fk33_engine.py have
# to agree and there is no way to check that at build time cheaply.
python3 gen_fk33_engine.py
python3 gen_pcieep.py

# Board-free gates, cheapest first.  Each has caught something that would
# otherwise only surface at the far end of an hour-long build, or on the one
# afternoon the card is in the slot.
echo "=== board-free gates ==="
python3 check_pcieep_xdc.py
make -C host --no-print-directory check
./host/selftest_nocard.sh | tail -1
# The host-side decoders, including the thermal one.  These were only run by
# host/fk33_go.sh, which needs a card; the build gate is where they belong
# because a decoder that misreports a dead bus as a cold, unprotected card is a
# board-free defect.
(cd host && python3 tests_fk33ctl.py | tail -1)
# Two gates in one script.  The autonomous VCCINT controller writes a real power
# rail with no host in the loop, so simulating it against a behavioural pot is
# the only thing standing between a typo in an I2C bit order and an ES1 die at
# the wrong voltage.  The thermal guard is the only thing that stops the part
# and the HBM stacks cooking during a long run, and every one of its thresholds
# -- including the stale-sensor and stuck-at-zero paths -- is crossed there.
./sim_aux.sh | grep -E "PASS|FAIL"
# The JTAG probe's own decode, against fixed vectors from the RTL simulation and
# with no hardware.  It is the only path that can read the thermal guard with
# the PCIe link down, and a Tcl error in it aborts the whole script on its first
# register -- which reads exactly like a dead card.  One such error was already
# found this way: `expr {0x$hz}` is not valid Tcl.
AUXPROBE_SELFTEST=1 tclsh tcl/aux_probe.tcl | tail -1
# The JTAG-AXI master selector, against stubs.  Ten scripts used to pick the
# master by ordinal; hw_axi_1 was jtag_axil on the first-light build and
# jtag_aux on the thermal build, from this same source tree, and an unmapped
# read returns a decode sentinel rather than erroring -- so the wrong pick is
# SILENT.  Two of these scripts write a power rail and four bit-bang the board
# I2C bus.  The cases that matter are the REFUSALS, which is exactly why they
# need a gate: a refusal path nobody has made fire is not a refusal path.
AXISEL_SELFTEST=1 tclsh tcl/axi_select.tcl | tail -1

mkdir -p "$BUILD_ROOT"
cp build_fk33_pcieep.tcl "$BUILD_ROOT/"

echo "=== building in $BUILD_ROOT ==="
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$BUILD_ROOT"
if (( BD_ONLY )); then
    FK33_STOP_AFTER_BD=1 vivado -mode batch -nojournal -log build.log \
        -source build_fk33_pcieep.tcl 2>&1 | tee build.stdout
else
    vivado -mode batch -nojournal -log build.log -source build_fk33_pcieep.tcl \
        2>&1 | tee build.stdout
fi

BIT="$BUILD_ROOT/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit"

echo
echo "=== things in the log that must be read, not assumed ==="
# Each of these is a way this build can succeed and still be wrong.
grep -E "^FK33_PCIE_IDS" build.log || echo "  MISSING FK33_PCIE_IDS -- the device ID the driver has to match is unknown"
grep -E "^FK33_LNKLED" build.log || echo "  MISSING FK33_LNKLED -- link LED status unknown"
# The aux domain is the only thing in this bitstream that is readable with the
# PCIe link down.  Every line below is a way it can be silently absent or
# silently wrong, and each one has to be READ.
grep -E "^FK33_AUX LNK" build.log || echo "  MISSING FK33_AUX LNK -- user_lnk_up wiring unknown"
# TRAP, found on 2026-08-28 after the first thermal build: Vivado echoes every
# line of the sourced Tcl into build.log prefixed with "#".  A plain grep for an
# alarm string therefore matches the *puts statement that would print it*, not
# the printed line, so all three alarms below fired on a completely healthy
# build.  An alarm that fires every time is worse than no alarm: it trains the
# reader to ignore it.  Every grep that decides something must therefore be
# anchored to the start of the line, where only real output can be.
grep -E "^FK33_CFG MISSING AUX CELL" build.log && \
    echo "  ^^ AN AUX CELL IS MISSING; the bitstream is blind with the link down" || true
grep -E "^FK33_AUX_CLKCHECK" build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
grep -E "^FK33_AUX_VIOLATION" build.log && \
    echo "  ^^ AN AUX PIN SHARES A NET WITH xdma/axi_aclk. The read path is not independent." || true
# THERMAL.  Each line below is a way this build can come out with a thermal
# guard that is present, closes timing, and is blind.  SYSMON's own OT alarm
# trips at 101 C -- above the -2LE sustained rating, silent about HBM, and its
# consequence is a shutdown that takes the card off the PCIe bus -- so a blind
# fabric guard means there is effectively no thermal management at all.
echo "--- thermal guard (SYSMON config must have TAKEN, not just been asked for) ---"
grep -E "^FK33_SYSMON" build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
grep -E "^FK33_THERM " build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
grep -E "^FK33_THERM FAIL" build.log && \
    echo "  ^^ THE THERMAL GUARD IS BLIND. Do not run a sustained workload on this." || true
grep -E "^FK33_THERMCLK" build.log || \
    echo "  (impl-stage check; only printed by a full build)"
# The thresholds as they exist in the ROUTED NETLIST.  Everything above reads a
# block-design parameter, which is a request; the SYSMONE4 primitive's INIT_5x
# attributes are the configuration registers the bitstream actually loads, so
# these lines are the only proof that the trip points in the artefact are the
# ones this design asked for.  The OT line also answers, from the artefact
# rather than from a datasheet, whether SYSMON will power the device down by
# itself.
grep -E "^FK33_SYSMONI" build.log || \
    echo "  (impl-stage check; only printed by a full build)"
echo "--- the free-running clock and the debug hub (both must be present) ---"
grep -E "^FK33_AUXCLK" build.log || echo "  MISSING FK33_AUXCLK -- the aux clock may be UNCONSTRAINED"
grep -E "^FK33_HUBCLK" build.log || echo "  MISSING FK33_HUBCLK -- the debug hub may still be on the dead MMCM output"
grep -E "^FK33_TIMING" build.log || echo "  MISSING FK33_TIMING"
grep -E "^FK33_BITSTREAM" build.log || echo "  MISSING FK33_BITSTREAM"
echo "--- GT and PCIe placement (confirms the x4 link landed in quad 227) ---"
grep -iE "GTYE4_CHANNEL|GTYE4_COMMON|PCIE4C" fk33_pcieep_util.rpt 2>/dev/null || \
    echo "  no utilization report -- check the impl run"
echo "--- unmatched constraints (should be ZERO now; any is a real error) ---"
grep -c "12-584" build.log || true
# Designutils 20-1307 is "Command 'X' is not supported in the xdc constraint
# file".  It is a CRITICAL WARNING, not an error, and Vivado then SKIPS THE
# WHOLE BLOCK -- so a constraint file containing an `if` produces a clean-looking
# build with those constraints simply absent.  That cost a full build on
# 2026-08-28.  This must read 0.
echo "--- XDC commands Vivado silently skipped (must be ZERO) ---"
grep -c "Designutils 20-1307" build.log || true
echo "--- address map, read back from the tool rather than assumed ---"
grep -E "^FK33_MAP .*(xdma/M_AXI|fk33_)" build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
echo "--- the synthesis top (must be bd_wrapper, NOT fk33_engine) ---"
grep -E "^FK33_TOP" build.log || echo "  MISSING FK33_TOP -- automatic top detection may have picked the engine"
echo "--- subsystem A: ports enabled, clocked, reset and connected ---"
grep -E "^FK33_ENG " build.log || \
    echo "  (only printed by an FK33_STOP_AFTER_BD run)"
# TRAP, MEASURED on 2026-08-29 by the first FULL build ever run from this
# script (TRACK BUILD-E2E, docs/debugging/2026-08-29_build-e2e-project-run.md).
# This alarm used to be UNCONDITIONAL, and it therefore fired on every healthy
# full build.  `FK33_ENG portcheck bad=` is emitted from inside the
# `if {[info exists ::env(FK33_STOP_AFTER_BD)]}` block of the build script, so a
# full build never prints it at all and the `|| echo` arm was reached by ABSENCE
# rather than by a fault.  MEASURED both directions on the same tree: the full
# build raised the alarm, and `--bd-only` on the identical sources printed
# `FK33_ENG portcheck bad=0 (must be 0)`.
#
# It is the same class of defect this file already documents two blocks above --
# an alarm that fires every time is worse than no alarm, because it trains the
# reader to ignore it -- reached by a different route.  Anchoring to `^` was not
# enough; the condition also has to be reachable in the run being checked.
#
# So: alarm only when the line EXISTS and is non-zero, and otherwise say which
# run does emit it.  The teeth are unchanged for the run that can produce it.
if grep -qE "^FK33_ENG portcheck bad=" build.log; then
    grep -E "^FK33_ENG portcheck bad=0" build.log > /dev/null || \
        echo "  ^^ AN ENGINE PORT IS NOT ENABLED, NOT DRIVEN OR NOT CONNECTED"
else
    echo "  (portcheck is emitted only by an FK33_STOP_AFTER_BD run;" \
         "run ./pcieep_build.sh --bd-only for it)"
fi
echo "--- subsystem A after place and route (full build only) ---"
grep -E "^FK33_ENGI" build.log || \
    echo "  (impl-stage check; only printed by a full build)"
# BD 41-1377 is EXPECTED here and is NOT a fault.  32 of them are emitted
# during the 64-call exclude_seg_if sequence, while the HBM map is momentarily
# inconsistent, and none after it.  Counting them and demanding zero would fail
# every build forever.  The meaningful check is positional: nothing after the
# last exclude.  Full evidence in
# docs/debugging/2026-08-27_pcieep-bd-critical-warnings.md.
echo "--- address-overlap warnings AFTER the exclude sequence (must be zero) ---"
LAST_EXCL=$(grep -n "Excluding slave segment" build.log | tail -1 | cut -d: -f1)
if [[ -n "${LAST_EXCL:-}" ]]; then
    # NOT `| tee /dev/stderr |`.  When this script's own output is redirected to
    # a file, /dev/stderr IS that file, and tee opens it with O_TRUNC -- so the
    # whole captured build report is destroyed at this line and only the few
    # lines after it survive.  Found on 2026-08-28 after a --bd-only run left a
    # 13-line log.  Capture into a variable and print it instead.
    AFTER=$(awk -v n="$LAST_EXCL" 'NR>n && /^CRITICAL WARNING: \[BD 41-1377\]/' build.log)
    if [[ -n "$AFTER" ]]; then
        printf '%s\n' "$AFTER"
        printf '%s\n' "$AFTER" | wc -l
    else
        echo 0
    fi
else
    echo "  no exclude sequence found -- the HBM address map did not run"
fi

if (( BD_ONLY )); then
    grep -E "FK33_BD_VALIDATE|FK33_BD_ONLY_DONE" build.log || \
        { echo "BD CHECK DID NOT COMPLETE"; exit 1; }
    echo
    echo "Block design only.  Nothing was synthesised and no bitstream exists."
    exit 0
fi

[[ -f "$BIT" ]] && echo "BITSTREAM $BIT ($(stat -c %s "$BIT") bytes)" \
                || { echo "BITSTREAM_MISSING"; exit 1; }

# Configuration time from flash, computed from the bitstream that was actually
# produced rather than from the one in the last commit.  This is a real budget
# and it is tight: the PCIe CEM minimum is 100 ms of T_PVPERL plus the ~100 ms
# the host waits after PERST# deasserts, and everything the FPGA has to do
# after the last configuration bit -- startup, GT lock, link training -- comes
# out of what is left.  A build that goes over does not fail visibly: it
# presents as a root port the BIOS hides, which is indistinguishable from a
# card that never worked.  AUX_STATUS[1] and PERST_MS in tcl/aux_probe.tcl are
# what settle it on silicon.
python3 - "$BIT" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
# .bit header: u16 len + that many bytes, then u16 (=1), then keyed fields
# 'a'..'d' each u16-length strings, then 'e' with a u32 byte count and the raw
# configuration data.  Parsed rather than searched for 0x65, because 0x65 is a
# perfectly ordinary byte to find in a design name.
p = 2 + struct.unpack('>H', b[0:2])[0]
p += 2
n = None
while p < len(b):
    key = b[p]; p += 1
    if key == 0x65:
        n = struct.unpack('>I', b[p:p+4])[0]
        break
    ln = struct.unpack('>H', b[p:p+2])[0]
    p += 2 + ln
if n is None:
    sys.exit("FK33_CFGTIME could not parse the bitstream header")
bits = n * 8
cclk = bits / 4                          # SPIx4 = 4 bits per CCLK
print(f"FK33_CFGTIME data={n} bytes ({bits} bits), {cclk:.0f} CCLK cycles at x4")
for name, f in (("nominal 127.5 MHz", 127.5e6),
                ("-15%    108.4 MHz", 127.5e6 * 0.85),
                ("+15%    146.6 MHz", 127.5e6 * 1.15)):
    print(f"FK33_CFGTIME   {name} -> {cclk / f * 1e3:7.1f} ms")
print("FK33_CFGTIME budget: 100 ms T_PVPERL + 100 ms host wait = 200 ms, minus"
      " startup, GT lock and link training")
PY
echo

# AUTO-PRESERVE.  MEASURED 2026-09-10: a completed A-only bitstream was lost
# because this script only PRINTED the next step.  BUILD_ROOT is recreated on
# every launch, so the window between "bitstream written" and "next build
# started" is the only time the file exists, and nothing was closing it.  The
# copy is unconditional, uniquely named, and never overwrites: a build cannot
# destroy the artifact of the build before it.
#
# It deliberately does NOT touch bit/fk33_pcieep.bit -- that name is what
# pcieep.sh prefers, so promoting a fresh build to it is a decision, not a
# side effect.  Use ./save_bitstream.sh for that.
if [[ -f "$BIT" ]]; then
    _stamp="$(date +%Y%m%d_%H%M%S)"
    _tag="${FK33_BITTAG:-$([[ "${FK33_CARD:-0}" == "1" ]] && echo card || echo eng)}"
    _keep="$FK33_DIR/bit/autosave/fk33_pcieep_${_tag}_${_stamp}.bit"
    mkdir -p "$FK33_DIR/bit/autosave"
    if cp "$BIT" "$_keep"; then
        echo "FK33_AUTOSAVE $_keep ($(stat -c %s "$_keep") bytes, md5 $(md5sum "$_keep" | cut -d" " -f1))"
    else
        echo "FK33_AUTOSAVE FAILED to copy $BIT -- copy it by hand NOW, $BUILD_ROOT is wiped by the next build"
    fi
else
    echo "FK33_AUTOSAVE no bitstream at $BIT (build did not reach write_bitstream)"
fi

echo "Next: ./save_bitstream.sh   then   export EP_BIT=$BIT  and run ./pcieep.sh"
