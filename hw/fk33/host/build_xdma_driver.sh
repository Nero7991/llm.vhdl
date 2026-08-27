#!/usr/bin/env bash
# Fetch and build the Xilinx XDMA Linux driver.  NO ROOT NEEDED for this script.
#
# It deliberately stops short of installing anything.  The root commands are
# printed at the end so they can be read before they are run -- installing a
# kernel module is the one step here that can take the machine down, and this
# box has a history of exactly that (see the 2026-08-19 driver incident).
#
# This can and should be run BEFORE the card is installed.  It settles the one
# host-side question that has nothing to do with the card: whether the driver
# even compiles against this kernel.
set -euo pipefail

SRC_ROOT="${SRC_ROOT:-$HOME/GitHub/dma_ip_drivers}"
KVER="$(uname -r)"

echo "=== kernel $KVER ==="
if [[ ! -d /lib/modules/$KVER/build ]]; then
    echo "MISSING: /lib/modules/$KVER/build"
    echo "  ROOT STEP: sudo apt-get install --no-install-recommends linux-headers-$KVER"
    exit 1
fi
echo "headers present: /lib/modules/$KVER/build"

if [[ ! -d "$SRC_ROOT" ]]; then
    echo "=== cloning dma_ip_drivers ==="
    git clone --depth 1 https://github.com/Xilinx/dma_ip_drivers "$SRC_ROOT"
else
    echo "=== using existing $SRC_ROOT ==="
    git -C "$SRC_ROOT" log --oneline -1
fi

cd "$SRC_ROOT/XDMA/linux-kernel"
echo "=== building the module ==="
# The module only.  `make` at the top of XDMA/linux-kernel also builds the
# userspace tools, which is fine, but the module is the thing that can fail.
make -C xdma clean >/dev/null 2>&1 || true
if ! make -C xdma 2>&1 | tee /tmp/xdma-build.log | tail -40; then
    echo
    echo "BUILD FAILED.  This is a known class of problem, not a dead end:"
    echo "  * dma_ip_drivers tracks kernel API churn slowly.  On 6.x the usual"
    echo "    breakages are class_create() losing its THIS_MODULE argument,"
    echo "    get_user_pages_remote()/pin_user_pages() signature changes, and"
    echo "    the removal of MODULE_SUPPORTED_DEVICE."
    echo "  * check for a branch or tag matching this kernel before patching:"
    echo "      git -C $SRC_ROOT branch -a; git -C $SRC_ROOT tag"
    echo "  * the full log is /tmp/xdma-build.log"
    exit 1
fi

KO="$SRC_ROOT/XDMA/linux-kernel/xdma/xdma.ko"
[[ -f "$KO" ]] || { echo "no xdma.ko produced"; exit 1; }
echo
echo "BUILT $KO"
modinfo "$KO" | grep -E "^(filename|version|vermagic|parm)" || true
echo
echo "Confirm vermagic starts with $KVER above.  If it does not, the module was"
echo "built against the wrong headers and insmod will refuse it."

echo "=== building the test tools ==="
make -C tools >/dev/null 2>&1 || echo "  (tools build failed; not required)"

cat <<EOF

================================ ROOT STEPS ================================
Nothing above touched the system.  These are the commands that need root, in
order.  Do NOT run them from a code-server terminal: a session teardown will
kill the module load mid-flight and leave dpkg or the module half-configured
(the 2026-08-19 failure mode).  Use claude-tmux, or systemd-run --unit.

  # 1. load, in POLL mode first.  Polling removes MSI-X from the picture, so a
  #    DMA failure cannot be an interrupt misconfiguration in disguise.
  sudo insmod $KO poll_mode=1

  # 2. if the module loads but no /dev/xdma0_* appears, the driver did not
  #    bind, which is a device-ID mismatch and nothing else.  Read the real IDs
  #    and force the bind:
  lspci -nn | grep -i xilinx
  echo "<VID> <DID>" | sudo tee /sys/bus/pci/drivers/xdma/new_id

  # 3. make the char devices usable without root:
  sudo tee /etc/udev/rules.d/60-xdma.rules >/dev/null <<'RULE'
KERNEL=="xdma*", MODE="0666"
RULE
  sudo udevadm control --reload && sudo udevadm trigger

  # 4. only once poll mode is proven end to end, switch to interrupts:
  sudo rmmod xdma && sudo insmod $KO

  # 5. persistent install, LAST, and only after all of the above works:
  sudo make -C $SRC_ROOT/XDMA/linux-kernel install
  sudo depmod -a
============================================================================
EOF
