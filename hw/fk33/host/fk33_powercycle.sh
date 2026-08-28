#!/usr/bin/env bash
# fk33_powercycle.sh -- was that a warm reboot, or was card power interrupted?
#
#   ./fk33_powercycle.sh              read the latch over JTAG and classify
#   ./fk33_powercycle.sh --stamp-only record the current state, do not read
#   ./fk33_powercycle.sh --show       print the stored stamp and exit
#   ./fk33_powercycle.sh --selftest   classifier tests, no card, no JTAG
#
# WHAT THE LATCH IS
# -----------------
# The FK33's VCCINT digital pot at I2C 0x2c holds its wiper in VOLATILE
# storage.  It resets to the factory 128 when the card loses power, and it
# SURVIVES a warm reboot of the host.  Measured 2026-08-28:
#
#     after a warm reboot:  wiper=64   VCCINT=0.7203 V
#     after a power cycle:  wiper=128  VCCINT=0.6786 V
#
# So the wiper is a latch recording whether card power was actually
# interrupted.  Nothing else on this system reports that.  It is what proved
# the FPGA had stayed configured across a BIOS visit and a reboot, and hence
# that the BIOS was presenting no bridge for a card that WAS configured and in
# spec during POST -- which is the finding the whole first-fit diagnosis rests
# on.  It was the single most useful probe of the exercise and it was only
# being read by accident, as a side effect of the START line of pcieep.sh.
# This makes it a check in its own right.
#
# THIS SCRIPT NEVER WRITES THE POT.  host/potlatch.tcl has no write path for a
# data byte at all: see its header.  A latch you can accidentally write is not
# a latch, and the wiper floor lives in the tools that legitimately move it.
#
# WHY A STAMP FILE
# ----------------
# The wiper alone is ambiguous.  128 means "power was interrupted" only if the
# wiper had previously been stepped away from 128; otherwise it means nothing
# happened yet.  So each successful read records the wiper together with the
# kernel's boot_id, which changes on every boot, warm or cold.  Comparing the
# two answers the real question:
#
#     boot_id changed + wiper still moved  ->  WARM REBOOT, power maintained
#     boot_id changed + wiper back at 128  ->  POWER WAS INTERRUPTED
#     boot_id same    + wiper still moved  ->  nothing happened since
#
# and where the pair cannot decide, this says so rather than guessing.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
cd "$HERE"

STAMP="${FK33_POT_STAMP:-$HERE/pot_latch_stamp.txt}"
W_DEFAULT=128
V_FLOOR=0.698          # the -2L grade floor

boot_id () { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown; }

# ------------------------------------------------------------- classification
# classify <status> <wiper> <vccint_axi> <vccint_drp>
# Reads $STAMP.  Prints a verdict.  Exit 0 warm/no-change, 1 power interrupted,
# 2 could not be determined, 3 the read itself failed.
classify () {
    local status="$1" wiper="$2" vaxi="$3" vdrp="$4"
    local now_boot; now_boot="$(boot_id)"
    local s_boot="" s_wiper="" s_when=""
    if [[ -f "$STAMP" ]]; then
        s_boot="$(awk -F= '$1=="boot_id"{print $2}' "$STAMP")"
        s_wiper="$(awk -F= '$1=="wiper"{print $2}'  "$STAMP")"
        s_when="$(awk -F= '$1=="when"{print $2}'    "$STAMP")"
    fi

    # ---- the read itself.  A failed JTAG-AXI transaction reports as -1, and
    # -1 is NOT a wiper value.  Comparing it against 128 would say "the pot
    # answered with the wrong value" about a path that never answered.
    case "$status" in
      axi_dead)
        echo "RESULT  UNDETERMINED -- the AXI path never answered"
        echo "  Every register read returned -1.  That is a FAILED transaction,"
        echo "  not data, and not a wiper value: nothing here is a reading that"
        echo "  can be compared with 128."
        echo "  Cause, in order of likelihood:"
        echo "    1. the ENDPOINT bitstream is loaded.  Its whole AXI fabric is"
        echo "       clocked by xdma/axi_aclk and reset by xdma/axi_aresetn,"
        echo "       both released only once the PCIe link is up, so JTAG-AXI"
        echo "       is dead by design until then.  This is EXPECTED and is not"
        echo "       a card fault."
        echo "    2. no bitstream with a JTAG-AXI master is loaded at all."
        echo "  Load the probe bitstream and re-read:   cd .. && ./probe.sh"
        return 3 ;;
      no_target)
        echo "RESULT  UNDETERMINED -- no JTAG target"
        echo "  The card may be unpowered, or hw_server is holding the FTDI."
        echo "  Check card power first:  lsusb -d 0403:6010"
        return 3 ;;
      no_axi_master)
        echo "RESULT  UNDETERMINED -- the design has no JTAG-AXI master"
        echo "  A bitstream is loaded but it exposes no hw_axi, so the pot"
        echo "  cannot be reached.  Load the probe bitstream:  cd .. && ./probe.sh"
        return 3 ;;
      ok) ;;
      *)  echo "RESULT  UNDETERMINED -- unrecognised status '$status'"; return 3 ;;
    esac
    if [[ "$wiper" == "-1" ]]; then
        echo "RESULT  UNDETERMINED -- the pot did not acknowledge"
        echo "  The AXI path works (it returned real data), but I2C address"
        echo "  0x2c NACKed or SDA never released.  That is a DIFFERENT fault"
        echo "  from the AXI path being dead, and a different fault again from"
        echo "  a wiper that reads an unexpected value.  Check the bus:"
        echo "      ../jtag.sh tcl/i2cident.tcl"
        return 3
    fi
    if ! [[ "$wiper" =~ ^[0-9]+$ ]]; then
        echo "RESULT  UNDETERMINED -- wiper '$wiper' is not a number"
        return 3
    fi

    echo "wiper           $wiper   (factory power-up default $W_DEFAULT)"
    [[ "$vaxi" != na ]] && printf 'VCCINT (AXI)    %s V\n' "$vaxi"
    [[ "$vdrp" != na ]] && printf 'VCCINT (JTAG DRP) %s V   -- independent of the AXI fabric\n' "$vdrp"
    if [[ "$vdrp" != na ]] && awk -v v="$vdrp" -v f="$V_FLOOR" 'BEGIN{exit !(v+0 < f+0)}'; then
        echo "  BELOW the $V_FLOOR V floor for the -2L grade."
    fi
    echo "boot_id now     $now_boot"
    if [[ -z "$s_boot" ]]; then
        echo "boot_id stamped (none)"
        echo
        echo "RESULT  BASELINE ONLY -- no previous reading to compare against"
        echo "  A single wiper value cannot answer the question on its own."
        if [[ "$wiper" == "$W_DEFAULT" ]]; then
            echo "  $wiper is the factory default, which is equally consistent with"
            echo "  'power was cycled' and with 'the wiper was never stepped'."
        else
            echo "  $wiper is NOT the factory default, so the wiper HAS been"
            echo "  stepped and power has NOT been interrupted since it was."
        fi
        echo "  This reading is now stamped.  Re-run after the next reboot or"
        echo "  power cycle and it will answer definitively."
        return 2
    fi
    echo "boot_id stamped $s_boot  (wiper $s_wiper at $s_when)"
    echo

    if [[ "$now_boot" == "$s_boot" ]]; then
        if [[ "$wiper" == "$s_wiper" ]]; then
            echo "RESULT  NO REBOOT AND NO POWER CYCLE since the last reading."
            echo "  Same boot_id, same wiper.  Whatever you are diagnosing, the"
            echo "  card has not been power cycled in the meantime."
            return 0
        fi
        if [[ "$wiper" == "$W_DEFAULT" ]]; then
            echo "RESULT  POWER WAS INTERRUPTED, without a host reboot."
            echo "  The host did not reboot (same boot_id) but the wiper is back"
            echo "  at the factory $W_DEFAULT.  The card lost power on its own:"
            echo "  the aux 6-pin lead, or a rail dropping out.  The FPGA will"
            echo "  also have lost its configuration."
            return 1
        fi
        echo "RESULT  the wiper moved $s_wiper -> $wiper within this boot."
        echo "  Not a power event: something stepped the pot.  Expected if a"
        echo "  VCCINT step ran since the last reading."
        return 0
    fi

    # boot_id changed: the host rebooted.  Warm or cold is exactly the question.
    if [[ "$wiper" != "$W_DEFAULT" ]]; then
        echo "RESULT  WARM REBOOT -- card power was NOT interrupted."
        echo "  The host rebooted (boot_id changed) and the wiper is still $wiper,"
        echo "  not the factory $W_DEFAULT.  The volatile wiper survived, so the"
        echo "  card's power rail was maintained across the reboot, and the FPGA"
        echo "  therefore also kept its configuration across that POST."
        echo "  This is the reading that makes 'the BIOS presented no bridge for"
        echo "  a card that WAS configured during POST' a measurement rather"
        echo "  than an assumption."
        return 0
    fi
    if [[ "$s_wiper" == "$W_DEFAULT" ]]; then
        echo "RESULT  UNDETERMINED -- the latch was not armed."
        echo "  The host rebooted and the wiper reads the factory $W_DEFAULT, but"
        echo "  it read $W_DEFAULT before the reboot as well.  A latch that was"
        echo "  never set cannot record anything.  Step VCCINT first, then this"
        echo "  check answers every later reboot:"
        echo "      cd .. && ./pcieep.sh          (its stage 2 steps the wiper)"
        return 2
    fi
    echo "RESULT  POWER CYCLE -- card power WAS interrupted."
    echo "  The host rebooted and the wiper went $s_wiper -> $W_DEFAULT, the"
    echo "  factory default.  The volatile wiper was lost, so the card's power"
    echo "  rail dropped.  The FPGA is unconfigured and VCCINT is back at its"
    echo "  power-up value, below the $V_FLOOR V floor for the -2L grade."
    echo "  Re-run the configure and VCCINT sequence:  cd .. && ./pcieep.sh"
    return 1
}

write_stamp () {   # write_stamp <wiper>
    { echo "boot_id=$(boot_id)"
      echo "wiper=$1"
      echo "when=$(date -Is)"
    } > "$STAMP"
    echo "stamped: $STAMP"
}

# ------------------------------------------------------------------ selftest
do_selftest () {
    local rc=0 tmp out got
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    local S="$tmp/stamp"
    local BOOT_A="aaaaaaaa-0000-0000-0000-000000000001"
    local BOOT_NOW; BOOT_NOW="$(boot_id)"
    # classify() reads $STAMP, which is resolved once at load time, so it has
    # to be repointed here rather than passed as an env prefix.  (Getting this
    # wrong made every case report "BASELINE ONLY" and, had the expectations
    # been looser, would have looked like a pass.)
    STAMP="$S"

    mkstamp () { printf 'boot_id=%s\nwiper=%s\nwhen=2026-08-28T00:00:00-06:00\n' "$1" "$2" > "$S"; }
    check () {  # check <label> <want-exit> <want-substring> <status> <wiper> ...
        local label="$1" wexit="$2" wtext="$3"; shift 3
        out="$(classify "$@" 2>&1)"; got=$?
        if [[ "$got" == "$wexit" ]] && grep -qF -- "$wtext" <<<"$out"; then
            echo "    ok   $label"
        else
            echo "    FAIL $label: exit $got (want $wexit)"
            sed 's/^/         /' <<<"$out"; rc=1
        fi
    }

    echo "--- DEFECT 3: a failed AXI read is -1 and must NOT read as a value"
    rm -f "$S"
    check "axi_dead is its own verdict, not a wrong wiper" 3 \
          "the AXI path never answered" axi_dead -1 na na
    out="$(classify axi_dead -1 na na 2>&1)"
    if grep -qE 'POWER CYCLE|WARM REBOOT' <<<"$out"; then
        echo "    FAIL a dead AXI path was classified as a power verdict"; rc=1
    else
        echo "    ok   a dead AXI path yields NO power verdict at all"
    fi
    grep -q 'FAILED transaction' <<<"$out" \
        && echo "    ok   says -1 is a failed transaction, not data" \
        || { echo "    FAIL does not explain what -1 is"; rc=1; }
    # The trap that started this: -1 vs 128 must be different messages.
    mkstamp "$BOOT_A" 64
    local a b
    a="$(classify axi_dead -1 na na 2>&1)"
    b="$(classify ok 128 0.6786 0.6786 2>&1)"
    if [[ "$a" == "$b" ]]; then
        echo "    FAIL 'link down' and 'value mismatch' produce the same message"; rc=1
    else
        echo "    ok   link down and genuine value mismatch are distinct messages"
    fi

    echo "--- DEFECT 3: a pot NACK (-1 wiper on a LIVE bus) is distinct again"
    check "pot NACK is not the same as a dead AXI path" 3 \
          "the pot did not acknowledge" ok -1 0.7203 0.7203
    out="$(classify ok -1 0.72 0.72 2>&1)"
    grep -q 'DIFFERENT fault' <<<"$out" \
        && echo "    ok   explicitly separates the two -1 sources" \
        || { echo "    FAIL does not distinguish pot NACK from dead AXI"; rc=1; }

    echo "--- DEFECT 4: the real 2026-08-28 measurements must classify correctly"
    mkstamp "$BOOT_A" 64
    check "warm reboot: boot changed, wiper still 64" 0 \
          "WARM REBOOT -- card power was NOT interrupted" ok 64 0.7203 0.7203
    check "power cycle: boot changed, wiper back to 128" 1 \
          "POWER CYCLE -- card power WAS interrupted" ok 128 0.6786 0.6786

    echo "--- DEFECT 4: the ambiguous cases must say so, not guess"
    mkstamp "$BOOT_A" 128
    check "wiper 128 before AND after: the latch was never armed" 2 \
          "the latch was not armed" ok 128 0.6786 0.6786
    rm -f "$S"
    check "no stamp at all: baseline only, no verdict claimed" 2 \
          "BASELINE ONLY" ok 64 0.7203 0.7203

    echo "--- DEFECT 4: same boot means no reboot happened"
    mkstamp "$BOOT_NOW" 64
    check "same boot_id, same wiper" 0 "NO REBOOT AND NO POWER CYCLE" ok 64 0.72 0.72
    mkstamp "$BOOT_NOW" 64
    check "same boot_id, wiper reset: power lost without a reboot" 1 \
          "POWER WAS INTERRUPTED, without a host reboot" ok 128 0.6786 0.6786
    mkstamp "$BOOT_NOW" 128
    check "same boot_id, wiper stepped: not a power event" 0 \
          "the wiper moved 128 -> 68 within this boot" ok 68 0.7177 0.7177

    echo "--- other read failures are undetermined, never a power verdict"
    mkstamp "$BOOT_A" 64
    check "no JTAG target"        3 "no JTAG target"        no_target     -1 na na
    check "no JTAG-AXI master"    3 "no JTAG-AXI master"    no_axi_master -1 na na
    check "garbage wiper"         3 "is not a number"       ok            xx na na

    echo "--- the VCCINT floor must be reported when it is breached"
    mkstamp "$BOOT_A" 64
    out="$(classify ok 128 0.6786 0.6786 2>&1)"
    grep -q "BELOW the $V_FLOOR V floor" <<<"$out" \
        && echo "    ok   0.6786 V flagged against the 0.698 V -2L floor" \
        || { echo "    FAIL floor breach not reported"; rc=1; }
    out="$(classify ok 64 0.7203 0.7203 2>&1)"
    grep -q "BELOW the $V_FLOOR V floor" <<<"$out" \
        && { echo "    FAIL 0.7203 V wrongly flagged as below the floor"; rc=1; } \
        || echo "    ok   0.7203 V is not flagged"

    echo "--- SAFETY: nothing in this tooling can write the pot"
    # Comments are allowed to NAME pot_write (the header explains its absence);
    # code is not.  Strip comment lines before looking.
    if grep -v '^[[:space:]]*#' potlatch.tcl | grep -q 'pot_write'; then
        echo "    FAIL potlatch.tcl contains a pot_write path"; rc=1
    else
        echo "    ok   potlatch.tcl has no pot_write in executable code"
    fi
    grep -q 'pot_write' potlatch.tcl \
        && echo "    ok   (and the header does explain why it is absent)" || true
    # Every AXI write must target the GPIO tri-state or data register, which
    # are what drive the I2C lines.  create_hw_axi_txn spans several lines, so
    # match the whole command, not one line of it -- a single-line grep passed
    # this check for the wrong reason while it was still being written.
    local badw
    badw="$(awk '
        /create_hw_axi_txn/ { buf=$0; while (buf !~ /-type (read|write)/ && (getline line) > 0) buf = buf " " line
                              if (buf ~ /-type write/ && buf !~ /\$TRI/ && buf !~ /\$DAT/) print NR": "buf }
    ' potlatch.tcl)"
    if [[ -n "$badw" ]]; then
        echo "    FAIL potlatch.tcl writes something other than the GPIO regs"
        sed 's/^/         /' <<<"$badw"; rc=1
    else
        echo "    ok   every AXI write targets only the GPIO TRI/DAT registers"
    fi
    # And prove that check has teeth, by running it against a file that DOES
    # write the pot.  A guard never seen to fire is not a guard.
    sed 's/-address \$DAT -data 0x00000000/-address 0x2c -data 0x00000040/' \
        potlatch.tcl > "$tmp/evil.tcl"
    badw="$(awk '
        /create_hw_axi_txn/ { buf=$0; while (buf !~ /-type (read|write)/ && (getline line) > 0) buf = buf " " line
                              if (buf ~ /-type write/ && buf !~ /\$TRI/ && buf !~ /\$DAT/) print NR": "buf }
    ' "$tmp/evil.tcl")"
    [[ -n "$badw" ]] && echo "    ok   the check FIRES on a deliberately poisoned copy" \
        || { echo "    FAIL the write-target check cannot detect a bad write"; rc=1; }

    echo "--- END TO END through the real entry point, with a stubbed reader"
    # Exercises the argument plumbing and the stamping rule, which the direct
    # classify() calls above do not touch.
    local ST="$tmp/e2e_stamp"
    printf 'boot_id=%s\nwiper=64\nwhen=2026-08-28T00:00:00-06:00\n' "$BOOT_A" > "$ST"
    printf '#!/bin/sh\necho "POTLATCH status=ok wiper=64 vccint_axi=0.7203 vccint_drp=0.7180 die_drp=44.0"\n' \
        > "$tmp/reader_ok"; chmod +x "$tmp/reader_ok"
    out="$(FK33_POT_STAMP="$ST" FK33_POTLATCH_CMD="$tmp/reader_ok" "$SELF" 2>&1)"; got=$?
    if (( got == 0 )) && grep -q 'WARM REBOOT' <<<"$out" && grep -q 'stamped:' <<<"$out"; then
        echo "    ok   end to end: warm reboot verdict, and the stamp is updated"
    else
        echo "    FAIL end-to-end warm reboot: exit $got"; sed 's/^/         /' <<<"$out"; rc=1
    fi
    grep -q '^wiper=64' "$ST" && echo "    ok   the new reading was stamped" \
        || { echo "    FAIL stamp not written"; rc=1; }

    printf '#!/bin/sh\necho "POTLATCH status=axi_dead reg=0x00009004 raw=-1"\n' \
        > "$tmp/reader_dead"; chmod +x "$tmp/reader_dead"
    printf 'boot_id=%s\nwiper=64\nwhen=2026-08-28T00:00:00-06:00\n' "$BOOT_A" > "$ST"
    out="$(FK33_POT_STAMP="$ST" FK33_POTLATCH_CMD="$tmp/reader_dead" "$SELF" 2>&1)"; got=$?
    if (( got == 3 )) && grep -q 'the AXI path never answered' <<<"$out"; then
        echo "    ok   end to end: a dead AXI path exits 3 with its own message"
    else
        echo "    FAIL end-to-end axi_dead: exit $got"; sed 's/^/         /' <<<"$out"; rc=1
    fi
    # A failed read must NOT be stamped, or the latch is armed with a lie and
    # every later comparison is wrong.
    grep -q '^wiper=64' "$ST" && echo "    ok   a FAILED read did not overwrite the stamp" \
        || { echo "    FAIL a failed read corrupted the stamp"; rc=1; }

    printf '#!/bin/sh\necho "nothing useful"\n' > "$tmp/reader_silent"; chmod +x "$tmp/reader_silent"
    out="$(FK33_POT_STAMP="$ST" FK33_POTLATCH_CMD="$tmp/reader_silent" "$SELF" 2>&1)"; got=$?
    if (( got == 3 )) && grep -q 'TOOLING failure' <<<"$out"; then
        echo "    ok   no POTLATCH line at all is called a tooling failure,"
        echo "         explicitly not evidence about the card"
    else
        echo "    FAIL silent reader: exit $got"; sed 's/^/         /' <<<"$out"; rc=1
    fi

    echo "--- SAFETY: the wiper floor in fk33ctl.py is 68, not 60"
    if grep -qE '^W_FLOOR, W_DEFAULT = 68, 128' fk33ctl.py; then
        echo "    ok   fk33ctl.py W_FLOOR is 68"
    else
        echo "    FAIL fk33ctl.py W_FLOOR is not 68"; rc=1
    fi
    if python3 tests_fk33ctl.py >/dev/null 2>&1; then
        echo "    ok   tests_fk33ctl.py passes (floor enforced at pot_write)"
    else
        echo "    FAIL tests_fk33ctl.py fails; run it directly"; rc=1
    fi

    echo
    (( rc == 0 )) && echo "FK33_POWERCYCLE_SELFTEST OK" || echo "FK33_POWERCYCLE_SELFTEST FAIL"
    return $rc
}

# --------------------------------------------------------------------- main
case "${1:-}" in
    --selftest) do_selftest; exit $? ;;
    --show)     if [[ -f "$STAMP" ]]; then cat "$STAMP"; else echo "no stamp at $STAMP"; exit 1; fi; exit 0 ;;
    -h|--help)  sed -n '2,50p' "$SELF"; exit 0 ;;
    --stamp-only|"") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

echo "=== FK33 power-cycle latch (VCCINT digital-pot wiper, volatile) ==="
echo "reading over JTAG.  This is READ ONLY; the pot is never written here."
# FK33_POTLATCH_CMD exists so the reader can be replaced in tests.  The real
# reader runs Vivado over JTAG, which cannot be part of a no-hardware test.
READER="${FK33_POTLATCH_CMD:-}"
if [[ -n "$READER" ]]; then
    RAW="$($READER 2>&1 | grep '^POTLATCH')"
else
    RAW="$(cd .. && JTAG_TIMEOUT="${JTAG_TIMEOUT:-240}" ./jtag.sh host/potlatch.tcl 2>&1 | grep '^POTLATCH')"
fi
if [[ -z "$RAW" ]]; then
    echo "RESULT  UNDETERMINED -- potlatch.tcl produced no POTLATCH line."
    echo "  Vivado did not get far enough to report anything.  This is a"
    echo "  TOOLING failure and says nothing about the card in either"
    echo "  direction.  Read hw/fk33/host/potlatch.log."
    exit 3
fi
echo "$RAW"
echo
kv () { sed -n "s/.* $1=\\([^ ]*\\).*/\\1/p" <<<"$RAW" | head -1; }
STATUS="$(kv status)"; WIPER="$(kv wiper)"; VAXI="$(kv vccint_axi)"; VDRP="$(kv vccint_drp)"
classify "${STATUS:-unknown}" "${WIPER:--1}" "${VAXI:-na}" "${VDRP:-na}"
rc=$?
# Only stamp a reading that actually is one.  Stamping a failure would arm the
# latch with a lie and corrupt every later comparison.
if [[ "$STATUS" == ok && "$WIPER" =~ ^[0-9]+$ ]]; then
    echo
    write_stamp "$WIPER"
fi
exit $rc
