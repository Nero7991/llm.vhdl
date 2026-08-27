#!/usr/bin/env bash
# Prove the three ORDERING GUARDS have teeth.
#
# WHY THIS SCRIPT EXISTS.  A guard added AFTER a fix is worthless unless it is
# shown to fail BEFORE it.  The defect shape is the one found in `gdn_conv` on
# 2026-08-27 (`docs/debugging/2026-08-27_gdn-conv-eseg-published-late.md`): a
# scalar that qualifies a stream was assigned in the unit's FINAL state, so
# every beat it described had already been handed over.  The VALUE was right;
# only its TIME was wrong, and every testbench that samples the scalar at
# `done` passes on such a unit.
#
# All three D units are CLEAN as shipped, so there is nothing here for the
# guards to catch on the real RTL.  This script therefore breaks a COPY of
# each unit in exactly the gdn_conv way -- publish the scalar one clocked
# state later than the valid that claims it -- and requires the guard to fail.
# A break that does not fail is a guard that is a comment.
#
# GHDL mcode: `ghdl -e` produces no binary and silently succeeds, so `ghdl -r`
# is run directly.  --max-stack-alloc=0 is needed for the 491-step table.
set -uo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
rc=0

# break <tag> <unit> <tb> <want-regex> <old> <new> <extra ghdl -r args...>
#
# `want` is the message the ORDERING GUARD itself must produce.  Requiring only
# "the broken copy failed" is not enough: a break can be caught by an unrelated
# check that was already there, and the guard then still has no teeth of its
# own.  That happened here on the first attempt -- see break D1a.
break_one() {
  local tag="$1" unit="$2" tb="$3" want="$4" old="$5" new="$6"; shift 6
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "rtl/$unit.vhd" "$dir/$unit.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("BREAK ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo "$tag: ANCHOR FAILED"; rc=1; return; fi

  for f in util_pkg model_cfg_pkg seq_desc_fetch seq_region_lock seq_opdec; do
    [ "$f" = "$unit" ] && continue
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/$unit.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: BROKEN COPY DID NOT ANALYZE -- it has tested nothing"
    sed -n 1,4p "$dir/analyze.log"; rc=1; return
  fi
  # Re-analyze the dependants against the broken unit, then the testbench.
  for f in seq_opdec; do
    [ "$f" = "$unit" ] && continue
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" "sim/$tb.vhd" >/dev/null 2>&1

  timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" "$tb" \
    "$@" --max-stack-alloc=0 --stop-time=400ms > "$dir/run.log" 2>&1
  if grep -q "$tb: PASS" "$dir/run.log"; then
    echo "$tag  NO TEETH -- the broken copy PASSED"
    rc=1
  elif grep -qE "$want" "$dir/run.log"; then
    echo "$tag  TEETH -- the expected check fires:"
    grep -mE "$want" -m 1 "$dir/run.log" 2>/dev/null | head -1 \
      | sed 's/^/        /' | cut -c1-200 \
      || grep -E "$want" "$dir/run.log" | head -1 | sed 's/^/        /' | cut -c1-200
  else
    echo "$tag  CAUGHT BY SOMETHING ELSE -- the broken copy fails, but not on"
    echo "        the ordering guard, so the guard is not what has the teeth:"
    grep -E "report error|assertion (failure|error)" "$dir/run.log" | head -1 \
      | sed 's/^/        /' | cut -c1-200
    rc=1
  fi
}

echo "=== 1. seq_desc_fetch: publish the live-bank decode one cycle late ==="
# `lv_w` is a concurrent alias of the live bank, so job_w_exp / job_out_shift /
# job_const_exp are already correct on the first cycle of job_valid.  Register
# it and they become correct only on the SECOND cycle -- the exact gdn_conv
# shape, one clocked state late.
# The expected killer here is the PRE-EXISTING per-unit `job_digest` check, not
# ord_chk: the digest compares every cycle `job_valid` is high, so a decode that
# is one cycle late is already covered.  Recorded as its own break because
# "ord_chk did not fire" is the informative half -- it is what sent the teeth
# demonstration to D1b.
break_one D1a seq_desc_fetch tb_seq_desc_fetch \
'JOB SHADOW MOVED' \
'  lv_w <= dw(live_bank);' \
'  ord_break : process(clk) is
  begin
    if rising_edge(clk) then
      lv_w <= dw(live_bank);
    end if;
  end process;' -gURAM_LAT=1 -gJOB_LAT=40

echo
echo "=== 1b. seq_desc_fetch: withdraw the decode BEFORE job_cmp ==="
# D1a is caught first by the pre-existing per-unit `job_digest` check, which
# compares every cycle `job_valid` is high, so it does NOT demonstrate that
# ord_chk has teeth of its own.  This break is the DUAL and lands in the one
# window the digest check cannot see: `job_valid` falls in S_COMPLETE and
# `job_cmp` rises the cycle AFTER, so a decode that has already moved on to
# the next descriptor by then is invisible to every existing check and is read
# by `seq_opdec` at exactly that instant.
break_one D1b seq_desc_fetch tb_seq_desc_fetch \
'job scalar CHANGED after the first' \
'  lv_w <= dw(live_bank);' \
"  lv_w <= dw(other(live_bank)) when jvalid_r = '0' else dw(live_bank);" \
-gURAM_LAT=1 -gJOB_LAT=40

echo
echo "=== 2. seq_opdec: capture the exponent at job_cmp, not at first done ==="
# The register then updates on the SAME edge as cmp_valid, so the lock latches
# the previous job's exponent and y_exp_taken pulses one cycle late.
break_one D2 seq_opdec tb_seq_opdec \
'y_exp_taken pulsed AFTER cmp_valid' \
"        if x_armed = '1' and x_taken = '0' and u_done(x_unit) = '1' then" \
"        if x_armed = '1' and x_taken = '0' and job_cmp = '1' then" \
-gURAM_LAT=1 -gJOB_LAT=40

echo
echo "=== 3. seq_region_lock: register the exponent read port ==="
# A registered read port answers with whatever slot the address held LAST, so
# the capture is unreadable in the cycle it is claimed for.
break_one D3 seq_region_lock tb_seq_region_lock \
'in the first cycle after its own commit' \
'  exp_rd_data  <= exp_cap(reg_idx(exp_rd_region)*SEGS + to_integer(exp_rd_seg))
                  when exp_rd_region < NREG and exp_rd_seg < SEGS
                  else (others => '"'"'0'"'"');' \
'  ord_break : process(clk) is
  begin
    if rising_edge(clk) then
      if exp_rd_region < NREG and exp_rd_seg < SEGS then
        exp_rd_data <= exp_cap(reg_idx(exp_rd_region)*SEGS
                               + to_integer(exp_rd_seg));
      else
        exp_rd_data <= (others => '"'"'0'"'"');
      end if;
    end if;
  end process;'

echo
echo "scratch dir with every broken copy and every log: $SCRATCH"
exit $rc
