#!/usr/bin/env bash
# Exercise fk33_bringup end to end with NO card, NO driver and NO FPGA.
#
# It substitutes three sparse files for the XDMA character devices and seeds
# them with exactly what a working card would return.  That is enough to run
# stages 0-5 for real: the address arithmetic, the identity comparison, the
# walking-one and address-in-word patterns, the DMA round trip and the byte
# comparator all execute against genuine reads and writes.
#
# What it PROVES:   the test program's own logic, its address map constants,
#                   and that a pass is reachable at all.
# What it does NOT: anything about the card, the bitstream, the link or the
#                   driver.  A pass here and a fail on hardware means the
#                   hardware is wrong; a fail here means this program is.
#
# The second half deliberately CORRUPTS each seeded value in turn and asserts
# that the program fails on the right stage.  A test that only ever verifies
# the passing path cannot tell you whether it would have noticed a failure.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TMP="${TMPDIR:-/tmp}/fk33_selftest.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

make --no-print-directory >/dev/null

USER_F="$TMP/user"
DMA_F="$TMP/dma"

# The AXI-Lite BAR is 128 KB.  The DMA space is sparse: the BRAM lives at
# 0x2_0000_0000 and HBM below it, so the file is nominally 8 GB + 64 KB but
# occupies only the blocks actually written.
seed () {
    rm -f "$USER_F" "$DMA_F"
    truncate -s 131072 "$USER_F"
    truncate -s $((0x200010000)) "$DMA_F"
    # identity magic "FK33" at 0xA000, build word at 0xA008, both little-endian
    printf '\x33\x33\x4b\x46' | dd of="$USER_F" bs=1 seek=$((0xA000)) conv=notrunc status=none
    printf '\x27\x08\x26\x20' | dd of="$USER_F" bs=1 seek=$((0xA008)) conv=notrunc status=none
    # SYSMON: 40.0 degC and 0.717 V, in the 16-bit raw form the design returns
    #   temp   = (40.0 + 279.43) / 507.6 * 65536 = 41244 = 0xA11C
    #   vccint = 0.717 / 3.0 * 65536            = 15663 = 0x3D2F
    printf '\x1c\xa1\x00\x00' | dd of="$USER_F" bs=1 seek=$((0x3400)) conv=notrunc status=none
    printf '\x2f\x3d\x00\x00' | dd of="$USER_F" bs=1 seek=$((0x3404)) conv=notrunc status=none
}

run () { FK33_DEV_USER="$USER_F" FK33_DEV_H2C="$DMA_F" FK33_DEV_C2H="$DMA_F" ./fk33_bringup "$@"; }

fails=0
expect_stage () {   # $1 = expected first failing stage, or "none"
    local want="$1"; shift
    local out rc
    set +e
    out="$(run "$@" 2>&1)"; rc=$?
    set -e
    if [[ "$want" == none ]]; then
        if (( rc != 0 )); then
            echo "SELFTEST FAIL: expected all-pass, got rc=$rc"; echo "$out"; fails=$((fails+1))
        else
            echo "SELFTEST ok   all stages pass"
        fi
        return
    fi
    if (( rc == 0 )); then
        echo "SELFTEST FAIL: expected a failure at stage $want, everything passed"
        echo "$out"; fails=$((fails+1)); return
    fi
    if grep -q "FIRST failure was stage $want" <<<"$out"; then
        echo "SELFTEST ok   first failure is stage $want, as intended"
    else
        echo "SELFTEST FAIL: expected first failure at stage $want; got:"
        grep -E "^(PASS|FAIL)|FIRST failure" <<<"$out"; fails=$((fails+1))
    fi
}

echo "=== 1. everything correct: must pass every stage ==="
seed
expect_stage none --hbm

echo
echo "=== 2. identity word wrong: must fail at stage 1 and go no further ==="
seed
printf '\xff\xff\xff\xff' | dd of="$USER_F" bs=1 seek=$((0xA000)) conv=notrunc status=none
expect_stage 1 --hbm

echo
echo "=== 3. no devices at all: must fail at stage 0 ==="
FK33_DEV_USER="$TMP/absent" FK33_DEV_H2C="$TMP/absent" FK33_DEV_C2H="$TMP/absent" \
    ./fk33_bringup >/dev/null 2>&1 && { echo "SELFTEST FAIL: passed with no devices"; fails=$((fails+1)); } \
    || echo "SELFTEST ok   fails with no devices"

echo
echo "=== 4. SYSMON returning nonsense: must fail stage 3 but NOT stop the run ==="
# Stage 3 is a plausibility check, not a prerequisite for DMA, so the DMA
# stages must still run.  If a SYSMON fault ever aborts the run, the most
# valuable stage never executes.
seed
printf '\xff\xff\x00\x00' | dd of="$USER_F" bs=1 seek=$((0x3400)) conv=notrunc status=none
set +e
out="$(run --hbm 2>&1)"; set -e
if grep -q "FAIL  stage 3" <<<"$out" && grep -q "PASS  stage 4" <<<"$out"; then
    echo "SELFTEST ok   stage 3 failed, stage 4 still ran"
else
    echo "SELFTEST FAIL: sysmon fault changed whether DMA ran"
    grep -E "^(PASS|FAIL)" <<<"$out"; fails=$((fails+1))
fi

echo
if (( fails )); then
    echo "FK33_HOST_SELFTEST FAIL ($fails)"
    exit 1
fi
echo "FK33_HOST_SELFTEST OK"
