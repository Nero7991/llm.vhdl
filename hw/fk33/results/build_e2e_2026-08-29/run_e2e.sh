#!/usr/bin/env bash
# TRACK BUILD-E2E: run the FK33 PCIe endpoint build end to end from the
# regenerated build script, from sources, with no checkpoint shortcut.
#
# Deliberately NOT `set -e`: the whole point is to observe how the build ends,
# including a failure, and to print a sentinel either way.  A wrapper that
# exits on the first non-zero status is a wrapper whose sentinel never prints,
# which is exactly the failure mode this run exists to rule out.

SCRATCH=/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/e2e
REPO=/home/orencollaco/GitHub/llama.vhdl

echo "E2E_WRAPPER_START $(date -Is)"
echo "E2E_HOST $(hostname)  load: $(cat /proc/loadavg)"
echo "E2E_GIT_HEAD $(cd $REPO && git rev-parse HEAD)"
echo "E2E_GIT_DESC $(cd $REPO && git log --oneline -1)"
echo "E2E_BUILD_ROOT ${BUILD_ROOT:-unset}"

echo "==== E2E_INPUT_MD5_BEFORE ===="
( cd "$REPO" && md5sum \
    hw/fk33/build_fk33_pcieep.tcl hw/fk33/fk33_pcieep.xdc hw/fk33/fk33_pblock.xdc \
    hw/fk33/build_fk33_i2cprobe.tcl hw/fk33/fk33_i2cprobe.xdc \
    hw/fk33/rtl/fk33_engine.vhd hw/fk33/rtl/fk33_aux.vhd hw/fk33/rtl/fk33_thermal.vhd \
    rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/matvec_int4_desc_pkg.vhd \
    rtl/stream_fifo.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd \
    rtl/weight_streamer.vhd rtl/act_mem_striped.vhd rtl/matvec_core.vhd \
    rtl/matvec_int4.vhd rtl/matvec_int4_desc_axi.vhd ) | tee "$SCRATCH/md5_before.txt"

echo "==== E2E_BUILD_BEGIN $(date -Is) ===="
cd "$REPO/hw/fk33" || { echo "E2E_WRAPPER_DONE rc=99 (cannot cd)"; exit 99; }
./pcieep_build.sh
RC=$?
echo "==== E2E_BUILD_END $(date -Is) rc=$RC ===="

echo "==== E2E_INPUT_MD5_AFTER ===="
( cd "$REPO" && md5sum \
    hw/fk33/build_fk33_pcieep.tcl hw/fk33/fk33_pcieep.xdc hw/fk33/fk33_pblock.xdc \
    hw/fk33/build_fk33_i2cprobe.tcl hw/fk33/fk33_i2cprobe.xdc \
    hw/fk33/rtl/fk33_engine.vhd hw/fk33/rtl/fk33_aux.vhd hw/fk33/rtl/fk33_thermal.vhd \
    rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/matvec_int4_desc_pkg.vhd \
    rtl/stream_fifo.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd rtl/axi_rd_port.vhd \
    rtl/weight_streamer.vhd rtl/act_mem_striped.vhd rtl/matvec_core.vhd \
    rtl/matvec_int4.vhd rtl/matvec_int4_desc_axi.vhd ) | tee "$SCRATCH/md5_after.txt"
if diff -q "$SCRATCH/md5_before.txt" "$SCRATCH/md5_after.txt" >/dev/null; then
    echo "E2E_INPUTS_STABLE yes -- no input file changed under the build"
else
    echo "E2E_INPUTS_STABLE NO -- AN INPUT FILE CHANGED DURING THE BUILD:"
    diff "$SCRATCH/md5_before.txt" "$SCRATCH/md5_after.txt"
fi

# The sentinel the brief demands.  A Vivado run can print full success and then
# die on a Tcl error afterwards, so the only thing that means "the whole script
# ran" is a marker emitted by its LAST line, anchored so the echoed source
# cannot match it.
BL="${BUILD_ROOT}/build.log"
echo "==== E2E_SENTINEL ===="
if [ -f "$BL" ]; then
    grep -c '^FK33_BUILD_DONE' "$BL" | sed 's/^/E2E_FK33_BUILD_DONE_count=/'
    echo "E2E_LOG_LAST3:"; tail -3 "$BL"
else
    echo "E2E_NO_BUILD_LOG at $BL"
fi

PK=$(cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/fk33-e2e.service/memory.peak 2>/dev/null || echo unknown)
echo "E2E_CGROUP_MEMORY_PEAK_BYTES $PK"
echo "E2E_WRAPPER_DONE rc=$RC $(date -Is)"
exit $RC
