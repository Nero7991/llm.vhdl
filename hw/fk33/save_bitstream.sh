#!/usr/bin/env bash
# Copy the fk33_pcieep bitstream OUT of /tmp before the machine is rebooted.
#
# WHY THIS EXISTS
# ---------------
# pcieep_build.sh writes into a per-session scratchpad under /tmp, and on this
# box /tmp does NOT survive a reboot.  Measured 2026-08-27:
#
#   $ grep '^D /tmp' /usr/lib/tmpfiles.d/tmp.conf
#   D /tmp 1777 root root -
#   $ systemctl cat systemd-tmpfiles-setup.service | grep ExecStart
#   ExecStart=systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev
#   $ uptime -s ; find /tmp -maxdepth 1 -printf '%TF %TT %p\n' | sort | head -1
#   2026-08-24 16:53:56
#   2026-08-24 16:54:11 /tmp/.font-unix
#
# `D` plus `--remove --boot` means the contents of /tmp are deleted at every
# boot, and nothing in /tmp predates the last one.  Fitting the FK33 requires
# a power-off.  So an hour-long build finished tonight is gone by the time the
# card is in the slot, discovered at the worst possible moment.
#
#   ./save_bitstream.sh          copy build outputs to hw/fk33/bit/
#   ./save_bitstream.sh --check  report only, exit non-zero if nothing is saved
#
# pcieep.sh prefers hw/fk33/bit/fk33_pcieep.bit when it exists.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DEST="${FK33_BITDIR:-$PWD/bit}"
SRC_BIT="${EP_BIT:-/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pcieep/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper.bit}"
SRC_DIR="$(dirname "$SRC_BIT")"
PROBE="$PWD/fk33_i2cprobe/fk33_i2cprobe.runs/impl_1/bd_wrapper.bit"

mkdir -p "$DEST"

if [[ "${1:-}" == "--check" ]]; then
    rc=0
    for f in "$DEST/fk33_pcieep.bit" "$DEST/fk33_i2cprobe.bit"; do
        if [[ -f "$f" ]]; then
            printf '  ok      %s (%s bytes, %s)\n' "$f" "$(stat -c %s "$f")" "$(stat -c %y "$f" | cut -d. -f1)"
        else
            printf '  MISSING %s\n' "$f"; rc=1
        fi
    done
    (( rc )) && echo "  /tmp is cleared on every boot.  Run ./save_bitstream.sh BEFORE powering off."
    exit $rc
fi

n=0
if [[ -f "$SRC_BIT" ]]; then
    cp -v "$SRC_BIT" "$DEST/fk33_pcieep.bit"; n=$((n+1))
    for extra in bd_wrapper.ltx; do
        [[ -f "$SRC_DIR/$extra" ]] && cp -v "$SRC_DIR/$extra" "$DEST/fk33_pcieep.ltx"
    done
else
    echo "endpoint bitstream not found yet: $SRC_BIT"
    echo "  (the build is still running, or EP_BIT needs to be set)"
fi

if [[ -f "$PROBE" ]]; then
    cp -v "$PROBE" "$DEST/fk33_i2cprobe.bit"; n=$((n+1))
else
    echo "probe bitstream not found: $PROBE"
    echo "  WITHOUT IT pcieep.sh cannot raise VCCINT, and VCCINT powers up at"
    echo "  0.678 V against a 0.698 V floor on every single power cycle."
fi

echo
echo "$n of 2 bitstreams saved to $DEST"
ls -l "$DEST" 2>/dev/null
(( n == 2 )) || exit 1
