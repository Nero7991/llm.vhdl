#!/usr/bin/env bash
# Analyze and run tb_seq_region_lock over the stream-skew matrix and the fault
# set.  See the testbench header for why each generic exists; the short version
# is that the three streams the lock arbitrates -- the write strobes, the
# exponent writes and the issue/complete edges -- are skewed independently,
# because any configuration that keeps them tidy tests none of the mechanisms.
#
# GHDL mcode: `ghdl -e` produces no binary and silently succeeds, so `ghdl -r`
# is run directly.  --max-stack-alloc=0 is needed for the 491-step plan, which
# is a function-local temporary.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for f in util_pkg model_cfg_pkg seq_region_lock; do
  ghdl -a --std=08 -frelaxed --workdir="$WORK" "rtl/$f.vhd"
done
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/seq_tbl_pkg.vhd
ghdl -a --std=08 -frelaxed --workdir="$WORK" sim/tb_seq_region_lock.vhd

run() {
  local name="$1"; shift
  echo "=== $name ==="
  ghdl -r --std=08 -frelaxed --workdir="$WORK" tb_seq_region_lock \
    "$@" --max-stack-alloc=0 --stop-time=400ms 2>&1 \
    | grep -vE "metavalue" \
    | grep -E "PASS|FAIL|report error|ok  step|walk finished" || true
  echo
}

echo "############ stream skew: the whole 9B token must walk clean ############"
run "writes fast, job slow"          -gWR_N=6  -gWR_GAP=0 -gJOB_LAT=12 -gSTRICT=true
run "writes slow, job instant"       -gWR_N=3  -gWR_GAP=3 -gJOB_LAT=0  -gSTRICT=true
run "one write, zero latency"        -gWR_N=1  -gWR_GAP=0 -gJOB_LAT=0  -gSTRICT=true

echo "############ writes that outlive their job (D section 8.2) #############"
run "3 write strobes after every completion" -gWR_TAIL=3 -gJOB_LAT=20
run "1 late strobe, slow write stream"       -gWR_TAIL=1 -gWR_GAP=2 -gWR_N=3 -gJOB_LAT=0

echo "############ hazard A3: exponent write into a HELD region ##############"
run "rogue exponent write at step 8 (a GDN mixer step)"   -gXW_AT=8
run "rogue exponent write at step 110 (a residual step)"  -gXW_AT=110

echo "############ descriptor faults, rejected BEFORE the unit starts ########"
run "dst_offset is not the fill pointer -> ERR_DESC(3)" -gBAD_OFF_AT=3
run "consumes a region nobody produced  -> ERR_LOCK(2)" -gBAD_CONS_AT=100
# Deliberately a different step from BAD_OFF_AT: at step 4 an off-by-one
# offset ALSO overruns QKV, so the two checks reject the same stimulus and
# testing them together tests neither.
run "row count overruns the region     -> ERR_DESC(3)" -gBAD_ROWS_AT=3
