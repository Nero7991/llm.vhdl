#!/usr/bin/env bash
# Put the FK33 endpoint bitstream into SPI flash, so the FPGA configures itself
# at power-on instead of waiting for JTAG.
#
#   ./flash.sh --status   read-only: what is the card doing right now?
#   ./flash.sh --backup   copy the SQRL FACTORY image out of flash.  DO FIRST.
#   ./flash.sh --mcs      build our .mcs.  NO HARDWARE NEEDED.
#   ./flash.sh --program  erase and write our image.  Refuses without a backup.
#   ./flash.sh --preload  fallback if the ES1 revision check blocks Vivado
#   ./flash.sh --check    report local artifacts only.  NO HARDWARE NEEDED.
#   ./flash.sh            the whole sequence, backup first
#
# Every mode that touches the flash also requires --yes-destroy-flash on the
# command line, and accepts --dry-run to print what it would do and stop.
#
# WHY
# ---
# A JTAG-configured FK33 can never enumerate on this host.  PCIe wants a
# trained link roughly 100 ms after PERST# deasserts; JTAG configuration takes
# far longer, so the BIOS gives up and hides the root port.  See
# docs/2026-08-28_fk33-first-fit-handoff.md section 0.  Flash boot is the fix.
#
# ############################################################################
# # THE CARD IS RUNNING SQRL'S FACTORY IMAGE OUT OF THIS FLASH.              #
# #                                                                          #
# # Measured 2026-08-28, enumerated on this host:                            #
# #   06:00.0 Serial controller [0700]: Squirrels Research Labs              #
# #           ForestKitten 33 [1e24:1533] (rev a3), behind root port 00:1d.0 #
# #                                                                          #
# # That image is not in this repository and cannot be rebuilt.  Erasing it  #
# # without a backup is irreversible and the only replacement source is      #
# # SQRL.  --program REFUSES to run until --backup has produced a file that  #
# # check_flash_backup.py accepts.                                           #
# ############################################################################
#
# READBACK IS ITSELF A JTAG CONFIGURATION.  There is no way to read the flash
# without the FPGA driving it, so --backup loads a programmer bitstream and
# therefore OVERWRITES the factory design running in SRAM.  The card drops off
# the PCIe bus and stays off until a power cycle.  That is fine and reversible
# WHILE THE FLASH IS INTACT, which is exactly why the backup goes first.
# "Back up before any JTAG configuration" is not achievable; "back up before
# anything irreversible" is.
#
# ORDER, AND WHY IT IS THIS ORDER
# -------------------------------
#   0. ./flash.sh --status        read-only.  Confirms JTAG works and reports
#                                 VCCINT, without disturbing the running card.
#   1. ./pcieep.sh                raise VCCINT 0.678 -> ~0.717 V.  This DOES
#                                 reconfigure the FPGA, but it is reversible by
#                                 power cycle while the flash is intact, and a
#                                 readback taken below the 0.698 V floor risks
#                                 being quietly wrong, which is worse than no
#                                 backup at all.  The pot wiper is volatile but
#                                 survives reconfiguration, so it stays raised
#                                 for the rest of this power cycle.
#   2. ./flash.sh --backup        copy the factory image out and validate it.
#   3. ./flash.sh --program       erase and write ours.
#   4. full power down, mains off, power on.  A WARM reboot is not enough: the
#      FPGA keeps whatever it was last configured with and never re-reads flash.
#   5. ./flash.sh --status        did it configure from flash, and at what
#                                 VCCINT.  Run BEFORE reconfiguring anything.
#   6. host: lspci -nn | grep -i xilinx    (ours is 10ee:9034, SQRL's 1e24:1533)
#
# THE CONFIGURATION-TIME BUDGET IS TIGHT.  Our payload is 12,227,820 bytes,
# about 192 ms at the nominal CONFIGRATE, against a window of roughly 200 ms
# that must also contain link training.  The factory image proves the window is
# beatable on this exact board; it does not prove OUR payload beats it.  A
# too-slow configuration presents EXACTLY as the hidden root port already seen,
# which is what --status exists to tell apart.
# docs/debugging/2026-08-28_fk33-spi-flash-boot.md has the arithmetic.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BITDIR="${FK33_BITDIR:-$PWD/bit}"
export FK33_BIT="${FK33_BIT:-$BITDIR/fk33_pcieep.bit}"
export FK33_MCS="${FK33_MCS:-$BITDIR/fk33_pcieep.mcs}"
export FK33_BACKUP="${FK33_BACKUP:-$BITDIR/fk33_factory_backup.mcs}"

MODE="${1:-full}"
ALLOW_NO_BACKUP=0
DRY_RUN=0
CONSENT=0
for a in "$@"; do
    case "$a" in
        --force-no-backup)   ALLOW_NO_BACKUP=1 ;;
        --dry-run)           DRY_RUN=1 ;;
        --yes-destroy-flash) CONSENT=1 ;;
    esac
done

# A backup file sitting on disk is not consent, and neither is having typed a
# mode name.  Anything that reaches program_hw_devices reconfigures the FPGA,
# and anything that reaches program_hw_cfgmem erases a flash that cannot be
# un-erased.  Both now require saying so on the command line.
#
# WHY THIS EXISTS: on 2026-08-28 this script's own guard was defeated by a test
# harness that forged a backup file to see "how far --program gets".  It got as
# far as `Erase Operation successful` and destroyed the SQRL factory image.
# There is no partway on an erase.  See section 10.4 of
# docs/debugging/2026-08-28_fk33-spi-flash-boot.md.
# THE SINGLE CHOKEPOINT.  Every invocation of ./jtag.sh in this script goes
# through run_jtag, so the consent and dry-run checks cannot be bypassed by an
# edit that forgets to call them.  The previous design put the check inside
# each mode's function and one of the two edits silently did not apply, which
# is how `--backup --dry-run` ran for real.  One door, not three.
#
# FK33_JTAG_CMD lets the whole script be exercised with no hardware at all:
#   FK33_JTAG_CMD=echo ./flash.sh --program --yes-destroy-flash
# prints the command instead of running it.  Use that to test.  Never test a
# destructive path by running it and seeing how far it gets.
JTAG_CMD="${FK33_JTAG_CMD:-./jtag.sh}"

# NOTE THE ABSENCE OF A PIPE, AND DO NOT ADD ONE.
#
# `run_jtag ... | grep ...` puts run_jtag in a SUBSHELL, so the `exit` inside
# require_consent only leaves the subshell and the script sails on.  That is
# how `--backup --dry-run` printed its "nothing was touched" banner and then
# carried on to the next stage.  A refusal that does not refuse is worse than
# no refusal, because it reads as a working guard.
#
# So run_jtag redirects to a log FILE (redirection does not fork a subshell)
# and the caller filters the file afterwards with filter_log.
run_jtag () {           # $1 = tcl script, $2 = timeout, $3 = what it does
    local tcl="$1" tmo="$2" what="$3"
    require_consent "$what" "$tcl"
    JTAG_TIMEOUT="${JTAG_TIMEOUT:-$tmo}" $JTAG_CMD "$tcl" > "$RUNLOG" 2>&1 || true
}

RUNLOG="${FK33_RUNLOG:-$PWD/tcl/flash_run.out}"

filter_log () {         # $1 = first marker, $2 = last marker alternation
    grep -vE "^# " "$RUNLOG" | sed -n "/$1/,/$2/p"
}

require_consent () {
    local what="$1"
    if (( DRY_RUN )); then
        echo "DRY RUN: would $what"
        echo "  command: JTAG_TIMEOUT=... ./jtag.sh $2"
        echo "  env:     FK33_MCS=$FK33_MCS"
        echo "           FK33_BACKUP=$FK33_BACKUP"
        echo "           FK33_ALLOW_NO_BACKUP=${FK33_ALLOW_NO_BACKUP:-0}"
        echo "  Nothing was touched.  Drop --dry-run to do it for real."
        exit 0
    fi
    if (( ! CONSENT )); then
        echo "REFUSING: this would $what" >&2
        echo "  That reconfigures the FPGA and, for --program, erases a flash" >&2
        echo "  whose contents cannot be rebuilt from this repository." >&2
        echo "  Add --yes-destroy-flash to proceed, or --dry-run to see the" >&2
        echo "  exact command without running it." >&2
        exit 1
    fi
}

report_local () {
    local f
    for f in "$FK33_BIT" "$FK33_MCS" "$FK33_BACKUP"; do
        printf '  %-28s ' "$(basename "$f")"
        if [[ -f "$f" ]]; then
            printf '%12s bytes  %s\n' "$(stat -c %s "$f")" \
                   "$(stat -c %y "$f" | cut -d. -f1)"
        else
            printf '%12s\n' "MISSING"
        fi
    done
}

# ---------------------------------------------------------------- backup gate
# The single most important check in this script.  A backup file that exists is
# not a backup: an all-0xFF or all-0x00 readback is a FAILED READ that produces
# a plausible 32 MB file.  check_flash_backup.py looks for the Xilinx sync word
# instead of trusting the file's size.
require_backup () {
    if (( ALLOW_NO_BACKUP )); then
        cat <<'EOF'

  ##########################################################################
  # --force-no-backup: proceeding with NO copy of the SQRL factory image.  #
  # It will be destroyed by the erase and the only replacement source is   #
  # SQRL.  This is your decision, recorded here so it was not an accident. #
  ##########################################################################

EOF
        export FK33_ALLOW_NO_BACKUP=1
        return 0
    fi
    if [[ ! -s "$FK33_BACKUP" ]]; then
        echo "NO_BACKUP: $FK33_BACKUP is missing or empty." >&2
        echo "  The card is running SQRL's factory image out of this flash." >&2
        echo "  Run  ./flash.sh --backup  first." >&2
        echo "  Or  ./flash.sh --program --force-no-backup  to destroy it." >&2
        exit 1
    fi
    echo "=== validating the factory backup before touching the flash ==="
    if ! ./check_flash_backup.py "$FK33_BACKUP"; then
        echo "BACKUP_REJECTED: refusing to erase.  Re-run ./flash.sh --backup." >&2
        exit 1
    fi
}

mcs_is_stale () {
    [[ ! -f "$FK33_MCS" ]] && return 0
    [[ "$FK33_BIT" -nt "$FK33_MCS" ]] && return 0
    return 1
}

build_mcs () {
    [[ -f "$FK33_BIT" ]] || { echo "BITSTREAM_MISSING $FK33_BIT" >&2; exit 1; }
    echo "=== .bit -> .mcs (no hardware) ==="
    # Deliberately NOT through ./jtag.sh: that resets the FTDI cable first and
    # fails outright when the card is unpowered, which this stage does not need.
    ( source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
      timeout 900 vivado -mode batch -nojournal \
          -log tcl/flash_mcs.log -source tcl/flash_mcs.tcl ) 2>&1 \
        | grep -vE "^# " | sed -n '/MCS_BEGIN/,/MCS_OK\|MCS_FAIL/p'
}

backup_flash () {
    cat <<'EOF'
=== reading the SQRL factory image out of flash ===
This reconfigures the FPGA, so the card WILL disappear from the PCIe bus for
the rest of this power cycle.  The flash is untouched, so a power cycle brings
the factory image straight back.  Reading 32 MB over JTAG takes a long time.
EOF
    run_jtag tcl/flash_backup.tcl 7200 \
        "reconfigure the FPGA and read the whole flash back"
    filter_log BACKUP_BEGIN 'BACKUP_OK\|BACKUP_FAIL'
    echo "=== validating what came back ==="
    ./check_flash_backup.py "$FK33_BACKUP" --bin "${FK33_BACKUP%.mcs}.bin"
}

program_flash () {
    [[ -f "$FK33_MCS" ]] || { echo "MCS_MISSING $FK33_MCS -- run ./flash.sh --mcs" >&2; exit 1; }
    require_backup
    echo "=== erasing the flash and writing our image ==="
    run_jtag tcl/flash_program.tcl 3600 \
        "ERASE the SPI flash and write our image"
    filter_log FLASH_BEGIN 'FLASH_OK\|FLASH_FAIL'
}

# ---------------------------------------------------------------- xsdb preload
# FALLBACK for the ES1 revision check, and the reason it can work at all:
#
# The check is enforced by the CLIENT, not by the JTAG server.  hw_server merely
# reports a per-bitstream property; xsdb.tcl:7602 reads IS_REVISION_COMPATIBLE
# and refuses on its own unless -no-revision-check was passed, and Vivado's
# librdi_xicom_hw.so has the matching XHWBitstream::setSkipRevisionCheck.  So a
# programmer bitstream Vivado will not load, xsdb loads happily, and it lands in
# the part identically either way.
#
# Vivado's flash flow calls program_hw_devices on
# data/xicom/cfgmem/bitfile.zip -> bitfile/spi_xcvu33p_pullnone.bit, whose
# header names the PRODUCTION part xcvu33p-fsvh2104-1-e.  There is no es1
# variant of it in the zip.  That is the file this extracts and preloads.
PROG_BIT_NAME="${FK33_PROG_BIT_NAME:-spi_xcvu33p_pullnone.bit}"
VIVADO_ROOT="${FK33_VIVADO_ROOT:-/tools/Xilinx/2023.2/Vivado/2023.2}"

extract_programmer () {
    local zip="$VIVADO_ROOT/data/xicom/cfgmem/bitfile.zip"
    local dst="$BITDIR/$PROG_BIT_NAME"
    [[ -f "$zip" ]] || { echo "PROGRAMMER_ZIP_MISSING $zip" >&2; exit 1; }
    if [[ ! -f "$dst" ]]; then
        mkdir -p "$BITDIR"
        unzip -o -j "$zip" "bitfile/$PROG_BIT_NAME" -d "$BITDIR" >/dev/null
    fi
    [[ -f "$dst" ]] || { echo "PROGRAMMER_EXTRACT_FAILED $PROG_BIT_NAME" >&2; exit 1; }
    echo "$dst"
}

preload_programmer () {
    local pbit; pbit="$(extract_programmer)"
    require_consent "reconfigure the FPGA with the flash programmer via xsdb" \
                    tcl/program.tcl
    echo "=== fallback: loading the flash programmer via xsdb ==="
    echo "    $pbit ($(stat -c %s "$pbit") bytes)"
    echo "    header part: $(head -c 200 "$pbit" | tr -d '\0' | grep -oE 'xcvu[0-9a-z-]+' | head -1)"
    # Free the FTDI.  Deliberately pkill -x (exact process NAME), never pkill -f
    # on a command-line pattern: -f would also match any shell or editor that
    # happens to have the string on its command line, including this one.
    pkill -x -u "$(id -u)" hw_server 2>/dev/null || true
    pkill -x -u "$(id -u)" cs_server 2>/dev/null || true
    sleep 2
    ( source /tools/Xilinx/2023.2/Vitis/2023.2/settings64.sh
      FK33_BIT="$pbit" timeout 600 xsdb tcl/program.tcl ) 2>&1 \
        | grep -E "FPGA_PROG|xcvu33p"
}

read_status () {
    echo "=== card status (read only, configures nothing) ==="
    # Read only, so no consent gate, but same no-pipe discipline.
    JTAG_TIMEOUT="${JTAG_TIMEOUT:-300}" $JTAG_CMD tcl/flash_status.tcl > "$RUNLOG" 2>&1 || true
    filter_log STATUS_BEGIN STATUS_DONE
}

case "$MODE" in
    --check)
        echo "=== local artifacts ==="
        report_local
        ;;
    --mcs)
        build_mcs
        ;;
    --backup)
        backup_flash
        ;;
    --program)
        program_flash
        ;;
    --preload)
        require_backup
        preload_programmer
        # jtag.sh resets the FTDI on the way in.  That resets the CABLE, not the
        # FPGA: configuration survives a USB reset of the programmer.
        export FK33_ASSUME_LOADED=1
        program_flash
        ;;
    --status)
        read_status
        ;;
    full|--all)
        report_local
        if [[ ! -s "$FK33_BACKUP" ]] && (( ! ALLOW_NO_BACKUP )); then
            backup_flash
        else
            echo "=== factory backup already present, not re-reading ==="
        fi
        if mcs_is_stale; then build_mcs; else
            echo "=== .mcs is newer than the .bit, reusing it ==="
        fi
        program_flash
        echo
        echo "Now POWER THE HOST DOWN COMPLETELY (mains off), power it back on,"
        echo "and run  ./flash.sh --status  BEFORE configuring anything else."
        ;;
    *)
        echo "usage: ./flash.sh [--status|--backup|--mcs|--program|--preload|--check]" >&2
        echo "       --backup/--program/--preload require --yes-destroy-flash" >&2
        echo "       and accept --dry-run; --program also takes --force-no-backup" >&2
        exit 2
        ;;
esac
