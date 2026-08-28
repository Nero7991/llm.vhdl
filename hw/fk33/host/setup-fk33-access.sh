#!/usr/bin/env bash
# Make host/fk33ctl.py usable WITHOUT sudo, by loading the XDMA driver and
# giving its char devices to a group rather than to the world.
#
# Run once per boot (the module does not survive a reboot, and neither does
# the FPGA's configuration, so there is nothing to gain from loading it at
# boot time -- see REBIND below).  It needs root; everything after it does not.
#
#   sudo ./setup-fk33-access.sh
#
# WHY NOT `MODE="0666"`.  build_xdma_driver.sh prints that rule, and it is the
# one every XDMA tutorial gives.  It grants every local account read/write on
# /dev/xdma0_user (MMIO over the AXI-Lite BAR) and /dev/xdma0_{h2c,c2h}_0 (DMA
# in and out of 8 GB of HBM).  This workstation has a second user account with
# a standing VNC desktop, so "local account" is not hypothetical here.  A
# bus-mastering PCIe device is a powerful thing to hand out: this rule uses a
# GROUP and mode 0660 instead, so access is something you grant deliberately.
#
# BE CLEAR ABOUT WHAT THE GROUP BUYS ITS MEMBERS.  A member can issue arbitrary
# MMIO to the card and arbitrary DMA to and from card memory.  Whether that
# reaches HOST memory depends on the design's bus-mastering and on the IOMMU;
# do not assume it cannot.  Add people to this group the way you would add them
# to `docker`, not the way you would add them to `dialout`.
#
# REBIND, the bit that catches everyone.  Reconfiguring the FPGA over JTAG
# tears the PCIe device out from under a bound driver.  The order that works:
#
#     sudo ./setup-fk33-access.sh --unbind    # before ./pcieep.sh
#     cd .. && ./pcieep.sh                    # reconfigure
#     sudo ./setup-fk33-access.sh --rebind    # rescan + reload
#
# Doing it the other way round leaves the driver holding a device that no
# longer answers, and the failure mode is a hung process in D state, which is
# not something a userspace fix can clear.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GROUP="${FK33_GROUP:-fk33}"
RULE=/etc/udev/rules.d/60-xdma.rules
VENDOR=0x10ee
DEVICE=0x9034
ACTION="${1:-install}"

# The invoking human, not root.  sudo sets SUDO_USER; a bare root shell does
# not, and silently adding root to the group would be a confusing no-op.
TARGET_USER="${SUDO_USER:-}"

# DO NOT USE $HOME HERE.  Under sudo it is /root, so the default source path
# resolved to /root/GitHub/dma_ip_drivers and the script reported "the module
# is not built yet" about a module that was sitting built in the real user's
# home.  Take the home directory from passwd for whoever invoked sudo.
if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
    TARGET_HOME="$HOME"
fi
SRC_ROOT="${SRC_ROOT:-$TARGET_HOME/GitHub/dma_ip_drivers}"
KO="$SRC_ROOT/XDMA/linux-kernel/xdma/xdma.ko"

need_root () {
    [[ $EUID -eq 0 ]] || { echo "ERROR: $ACTION needs root.  Re-run with sudo." >&2; exit 1; }
}

find_dev () {   # echo the FK33's PCI address, or nothing
    local d
    for d in /sys/bus/pci/devices/*/; do
        [[ -r "$d/vendor" && -r "$d/device" ]] || continue
        if [[ "$(cat "$d/vendor")" == "$VENDOR" && "$(cat "$d/device")" == "$DEVICE" ]]; then
            basename "$d"; return 0
        fi
    done
    return 0
}

case "$ACTION" in
--unbind)
    need_root
    if lsmod | grep -q '^xdma'; then
        echo "removing xdma"
        rmmod xdma || { echo "rmmod refused -- something still holds it:"; lsof /dev/xdma* 2>/dev/null || true; exit 1; }
    else
        echo "xdma not loaded, nothing to remove"
    fi
    DEV="$(find_dev)"
    if [[ -n "$DEV" ]]; then
        echo "removing PCI device $DEV so the reconfigure cannot strand it"
        echo 1 > "/sys/bus/pci/devices/$DEV/remove"
    fi
    echo "SAFE TO RECONFIGURE"
    ;;

--rebind)
    need_root
    echo "rescanning the PCI bus"
    echo 1 > /sys/bus/pci/rescan
    sleep 1
    DEV="$(find_dev)"
    [[ -n "$DEV" ]] || { echo "ERROR: no $VENDOR:$DEVICE after rescan.  The FPGA is not configured as an endpoint, or the link did not train." >&2; exit 1; }
    echo "found $DEV"
    [[ -f "$KO" ]] || { echo "ERROR: $KO missing.  Run ./build_xdma_driver.sh first." >&2; exit 1; }
    lsmod | grep -q '^xdma' || insmod "$KO" poll_mode=1
    sleep 1
    ls -l /dev/xdma* 2>/dev/null || { echo "ERROR: driver loaded but created no /dev/xdma*.  Check dmesg." >&2; exit 1; }
    echo "REBIND OK"
    ;;

--status)
    # Deliberately tolerant: --status is what you run when something is wrong,
    # so no probe here may abort the report.  `grep -c` returns 1 on zero
    # matches, which under `set -e` would kill the script mid-report.
    DEV="$(find_dev)"
    echo "PCI device : ${DEV:-<absent>}"
    if lsmod | grep -q '^xdma'; then echo "module     : loaded"; else echo "module     : NOT loaded"; fi
    if [[ -f $RULE ]]; then echo "udev rule  : present ($RULE)"; else echo "udev rule  : ABSENT"; fi
    if getent group "$GROUP" >/dev/null; then echo "group      : $GROUP exists"; else echo "group      : $GROUP ABSENT"; fi
    if compgen -G "/dev/xdma*" >/dev/null; then ls -l /dev/xdma*; else echo "char devs  : none"; fi
    echo "your groups: $(id -nG)"
    if id -nG | tr ' ' '\n' | grep -qx "$GROUP"; then
        echo "membership : yes, this shell has $GROUP"
    else
        echo "membership : NO -- this shell lacks $GROUP (groups are read at login)"
    fi
    ;;

install)
    need_root
    [[ -n "$TARGET_USER" ]] || { echo "ERROR: run this with sudo from your own account, not from a root shell -- I need to know who to add to the group." >&2; exit 1; }

    getent group "$GROUP" >/dev/null || { echo "creating group $GROUP"; groupadd "$GROUP"; }
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$GROUP"; then
        echo "$TARGET_USER already in $GROUP"
    else
        echo "adding $TARGET_USER to $GROUP"
        usermod -aG "$GROUP" "$TARGET_USER"
        NEW_GROUP=1
    fi

    echo "installing $RULE"
    cat > "$RULE" <<RULE
# FK33 XDMA char devices.  Group-owned, NOT world-writable: a member can do
# arbitrary MMIO to the card and arbitrary DMA to and from its memory.
# Installed by hw/fk33/host/setup-fk33-access.sh.
KERNEL=="xdma*", GROUP="$GROUP", MODE="0660"
RULE
    udevadm control --reload
    udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || true

    if [[ ! -f "$KO" ]]; then
        echo
        echo "The module is not built yet, or is not where I looked:"
        echo "    $KO"
        echo "Run this as YOURSELF (no root needed):"
        echo "    ./build_xdma_driver.sh"
        echo "then re-run this script.  If it IS built somewhere else, pass the"
        echo "tree explicitly:  sudo SRC_ROOT=/path/to/dma_ip_drivers $0"
        exit 1
    fi

    DEV="$(find_dev)"
    if [[ -z "$DEV" ]]; then
        echo
        echo "WARNING: no $VENDOR:$DEVICE in config space, so the driver has nothing"
        echo "         to bind to.  Configure the FPGA as an endpoint first:"
        echo "             cd .. && ./pcieep.sh"
        echo "         then:  sudo $0 --rebind"
        exit 1
    fi

    lsmod | grep -q '^xdma' || { echo "loading xdma (poll_mode=1)"; insmod "$KO" poll_mode=1; sleep 1; }
    # The rule applies to devices created AFTER it is loaded, so fix up any
    # that already exist rather than telling the user to reload the module.
    if compgen -G "/dev/xdma*" >/dev/null; then
        chgrp "$GROUP" /dev/xdma*
        chmod 0660 /dev/xdma*
    fi
    ls -l /dev/xdma* 2>/dev/null || { echo "ERROR: no /dev/xdma* after load.  Check dmesg." >&2; exit 1; }

    echo
    echo "INSTALL OK"
    echo
    # Print this ALWAYS, not only when the group was created on THIS run.
    # A second run says "already in fk33" and used to skip the note, but the
    # shell the user is standing in still has the old credentials, so the very
    # next command fails with EACCES on /dev/xdma0_user and looks like the
    # rule did not work.  Whether we just added the group is irrelevant; what
    # matters is whether the CALLING shell has picked it up, and it has not.
    echo "NOTE: group membership is read at LOGIN, so the shell you are standing"
    echo "      in almost certainly does NOT have $GROUP yet, even if $TARGET_USER"
    echo "      was already a member.  A read of /dev/xdma0_user will fail with"
    echo "      Permission denied until you refresh it.  For this shell only:"
    echo "          exec newgrp $GROUP"
    echo "      New logins get it automatically.  Check with: id -nG"
    echo
    echo "Then, with no sudo:"
    echo "    ./fk33ctl.py id"
    ;;

*)
    echo "usage: $0 [install|--unbind|--rebind|--status]" >&2
    exit 2
    ;;
esac
