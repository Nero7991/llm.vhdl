#!/usr/bin/env bash
# Runs on the BC-250. Written to a FILE and executed as a file, deliberately:
# MEASURED 2026-09-21, systemd-run's own command-line expansion ate $cg in a
# bash -c readback, which then read /sys/fs/cgroup/memory.high, got "No such
# file", and EXITED 0 -- a cap check that passed for the wrong reason.
set -u
H=/home/labuser/b10apportion
cd "$H"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
UNIT=b10apportion.service
systemctl --user reset-failed $UNIT 2>/dev/null
systemd-run --user --unit=$UNIT -p MemoryHigh=10G -p MemoryMax=11G \
  --working-directory=$H \
  /tools/Xilinx/2023.2/Vivado/2023.2/bin/vivado -mode batch -source $H/apportion.tcl \
  -log $H/vivado.log -journal $H/vivado.jou > $H/launch.txt 2>&1
rc=$?
echo "LAUNCH_RC=$rc"; cat $H/launch.txt
sleep 6
CG=$(systemctl --user show -p ControlGroup --value $UNIT 2>/dev/null)
echo "CGROUP=$CG"
if [ -n "$CG" ] && [ -f "/sys/fs/cgroup${CG}/memory.high" ]; then
  echo "MEMORY_HIGH_READBACK=$(cat /sys/fs/cgroup${CG}/memory.high)"
  echo "MEMORY_MAX_READBACK=$(cat /sys/fs/cgroup${CG}/memory.max)"
else
  echo "MEMORY_HIGH_READBACK=ABSENT -- CAP DID NOT APPLY, KILLING"
  systemctl --user kill $UNIT 2>/dev/null
fi
echo "ACTIVE=$(systemctl --user is-active $UNIT)"
