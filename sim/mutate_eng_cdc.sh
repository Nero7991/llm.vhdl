#!/usr/bin/env bash
# sim/mutate_eng_cdc.sh -- teeth for sim/tb_eng_cdc.vhd against
# rtl/fk33_eng_cdc.vhd (and the rtl/async_fifo.vhd it instantiates).
# TRACK ACLK, 2026-09-20.
#
# Every row states its EXPECTED verdict, and the rows expected to SURVIVE are
# the point of the table: they are the resolution floor of a zero-delay RTL
# simulation.  A functional bench samples atomically, so a binary pointer
# crosses as cleanly as a gray one and a one-flop synchroniser is as good as
# two; those defects are reached only by Vivado `report_cdc` (ASYNC_REG, the
# gray property) and by sim/gray_check.sh, never by this bench.  Reporting
# them as survivors under their own names is what makes the killed rows
# readable -- see sim/mutate_async_fifo.sh's G1/G2 for the same argument.
#
# Nothing under rtl/ or sim/ is edited.  Every mutation is applied to a COPY.
#
# Verdicts:  KILL   the bench's own checks failed (report error / FAIL line)
#            ABORT  ghdl stopped the run (an RTL assert, a bound, --stop-time)
#            SURV   the bench passed on the mutant
#            VOID   the mutant did not compile or the sed did not apply
# A row whose verdict differs from its expectation FAILS the script.
#
# Usage: bash sim/mutate_eng_cdc.sh      Env: SCRATCH=<dir> GHDL=<ghdl> ONLY=<tag>
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GHDL="${GHDL:-ghdl}"
SCRATCH="${SCRATCH:-$REPO/sim/scratch_mutate_eng_cdc}"
ONLY="${ONLY:-}"
mkdir -p "$SCRATCH"

SRCS="rtl/util_pkg.vhd rtl/async_fifo.vhd rtl/fk33_eng_cdc.vhd sim/tb_eng_cdc.vhd"

pass=0; fail=0; rows=""

# mutate <tag> <file> <expect> <description> <old> <new>
mutate() {
  local tag="$1" file="$2" expect="$3" desc="$4" old="$5" new="$6"
  [ -n "$ONLY" ] && [ "$ONLY" != "$tag" ] && return
  local d="$SCRATCH/$tag"; rm -rf "$SCRATCH/$tag"; mkdir -p "$d/rtl" "$d/sim"
  for f in $SRCS; do cp "$REPO/$f" "$d/$f"; done
  local verdict
  if ! grep -qF -- "$old" "$d/$file"; then
    verdict=VOID
  else
    python3 - "$d/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, "anchor occurs %d times" % s.count(old)
open(p, "w").write(s.replace(old, new))
PY
    ( cd "$d" && "$GHDL" -a --std=08 $SRCS && "$GHDL" -e --std=08 tb_eng_cdc ) > "$d/build.log" 2>&1
    if [ $? -ne 0 ]; then
      verdict=VOID
    else
      ( cd "$d" && timeout 600 "$GHDL" -r --std=08 tb_eng_cdc --stop-time=20ms ) > "$d/run.log" 2>&1
      local rc=$?
      if grep -qE "tb_eng_cdc: PASS" "$d/run.log" && ! grep -qE "CHECK FAIL|\(report error\)" "$d/run.log"; then
        verdict=SURV
      elif grep -qE "CHECK FAIL|tb_eng_cdc: FAIL" "$d/run.log"; then
        verdict=KILL
      else
        verdict=ABORT
      fi
    fi
  fi
  local mark="ok"
  if [ "$verdict" = "$expect" ]; then pass=$((pass+1)); else fail=$((fail+1)); mark="<== UNEXPECTED"; fi
  printf '%-4s %-6s expect %-6s %s   %s\n' "$tag" "$verdict" "$expect" "$mark" "$desc"
}

echo "sim/mutate_eng_cdc.sh  scratch=$SCRATCH"
# mutate2 <tag> <file> <expect> <desc> <old1> <new1> <old2> <new2>: two edits
# on ONE copy -- the attribution control for a pair of redundant waits, where
# each single mutant survives because the other half of the pair still holds.
mutate2() {
  local tag="$1" file="$2" expect="$3" desc="$4" o1="$5" n1="$6" o2="$7" n2="$8"
  [ -n "$ONLY" ] && [ "$ONLY" != "$tag" ] && return
  local d="$SCRATCH/$tag"; rm -rf "$SCRATCH/$tag"; mkdir -p "$d/rtl" "$d/sim"
  for f in $SRCS; do cp "$REPO/$f" "$d/$f"; done
  local verdict
  if ! grep -qF -- "$o1" "$d/$file" || ! grep -qF -- "$o2" "$d/$file"; then
    verdict=VOID
  else
    python3 - "$d/$file" "$o1" "$n1" "$o2" "$n2" <<'PY'
import sys
p, o1, n1, o2, n2 = sys.argv[1:6]
s = open(p).read()
assert s.count(o1) == 1 and s.count(o2) == 1
open(p, "w").write(s.replace(o1, n1).replace(o2, n2))
PY
    ( cd "$d" && "$GHDL" -a --std=08 $SRCS && "$GHDL" -e --std=08 tb_eng_cdc ) > "$d/build.log" 2>&1
    if [ $? -ne 0 ]; then
      verdict=VOID
    else
      ( cd "$d" && timeout 600 "$GHDL" -r --std=08 tb_eng_cdc --stop-time=20ms ) > "$d/run.log" 2>&1
      if grep -qE "tb_eng_cdc: PASS" "$d/run.log" && ! grep -qE "CHECK FAIL|\(report error\)" "$d/run.log"; then
        verdict=SURV
      elif grep -qE "CHECK FAIL|tb_eng_cdc: FAIL" "$d/run.log"; then
        verdict=KILL
      else
        verdict=ABORT
      fi
    fi
  fi
  local mark="ok"
  if [ "$verdict" = "$expect" ]; then pass=$((pass+1)); else fail=$((fail+1)); mark="<== UNEXPECTED"; fi
  printf '%-4s %-6s expect %-6s %s   %s\n' "$tag" "$verdict" "$expect" "$mark" "$desc"
}

echo "---- rtl/fk33_eng_cdc.vhd: the three orderings ----"
mutate W1 rtl/fk33_eng_cdc.vhd SURV "card side forwards a write WITHOUT waiting for the x FIFO to be read out (ordering 1, first half; the engine-side wait alone still orders it under this stimulus)" \
  "if sa_awvalid = '1' and sa_wvalid = '1' and x_caught = '1' then" \
  "if sa_awvalid = '1' and sa_wvalid = '1' then"
mutate W2 rtl/fk33_eng_cdc.vhd SURV "engine side executes a write without waiting for the x output stage (ordering 1, second half; the card-side wait already orders it, so this is the floor of the pair)" \
  "if req_s2 /= req_seen and x_qvalid = '0' and dx_we_r = '0' then" \
  "if req_s2 /= req_seen then"
mutate W3 rtl/fk33_eng_cdc.vhd SURV "engine side sends the done event WITHOUT waiting for the y FIFO to be read out (ordering 3, first half; the card-side wait alone still orders it)" \
  "if done_pend = '1' and y_caught = '1' then" \
  "if done_pend = '1' then"
mutate W4 rtl/fk33_eng_cdc.vhd SURV "card side raises a_job_done WITHOUT waiting for the y output stage (ordering 3, second half; the engine-side wait alone still orders it)" \
  "if dn_pend_s = '1' and y_qvalid = '0' and ay_we_r = '0' then" \
  "if dn_pend_s = '1' then"
mutate2 W12 rtl/fk33_eng_cdc.vhd KILL "BOTH x waits removed (W1 + W2): the write can execute before the last x element -- the attribution control for the pair" \
  "if sa_awvalid = '1' and sa_wvalid = '1' and x_caught = '1' then" \
  "if sa_awvalid = '1' and sa_wvalid = '1' then" \
  "if req_s2 /= req_seen and x_qvalid = '0' and dx_we_r = '0' then" \
  "if req_s2 /= req_seen then"
mutate2 W34 rtl/fk33_eng_cdc.vhd KILL "BOTH y waits removed (W3 + W4): done can precede the last beat -- the attribution control for the pair" \
  "if done_pend = '1' and y_caught = '1' then" \
  "if done_pend = '1' then" \
  "if dn_pend_s = '1' and y_qvalid = '0' and ay_we_r = '0' then" \
  "if dn_pend_s = '1' then"
mutate W5 rtl/fk33_eng_cdc.vhd KILL "a write no longer clears a_job_done: the previous job's done leaks into the next job's S_WAIT (ordering 2)" \
  "            done_s   <= '0';      -- (2): a write clears the previous done" \
  "            null;"
mutate W6 rtl/fk33_eng_cdc.vhd KILL "done crosses as a LEVEL (two-flop copy of d_job_done) instead of an event: the naive design" \
  "  a_job_done <= done_s;" \
  "  a_job_done <= dn_s2; -- MUTANT: level"
echo "---- resolution floor: what a zero-delay simulation cannot see ----"
mutate W7 rtl/fk33_eng_cdc.vhd SURV "the done toggle is taken from the FIRST synchroniser flop (one stage, not two): an MTBF defect, invisible in RTL sim; ASYNC_REG + report_cdc is the guard" \
  "        if dn_s2 /= dn_seen then
          dn_seen   <= dn_s2;" \
  "        if dn_s1 /= dn_seen then
          dn_seen   <= dn_s1;"
mutate W8 rtl/fk33_eng_cdc.vhd SURV "request payload and toggle flip on the SAME edge (no data-before-toggle cycle): a skew defect, invisible in RTL sim" \
  "          when S_HOLD =>
            -- data-before-toggle: one full cycle with the payload settled
            s_st <= S_TOG;" \
  "          when S_HOLD =>
            req_tog <= not req_tog;
            s_st <= S_WAIT;"
mutate2 G1 rtl/async_fifo.vhd SURV "gray encode AND decode become the identity: pointers cross as plain binary (sim/mutate_async_fifo.sh G1: the floor; sim/gray_check.sh is the guard)" \
  "    return b xor shift_right(b, 1);" \
  "    return b;" \
  "      b(i) := b(i+1) xor g(i);" \
  "      b(i) := g(i);"
mutate G2 rtl/async_fifo.vhd KILL "only the gray ENCODER becomes the identity, so encoder and decoder disagree: the control that makes G1 readable" \
  "    return b xor shift_right(b, 1);" \
  "    return b;"
echo "---- rtl/async_fifo.vhd: the full flag ----"
mutate F1 rtl/async_fifo.vhd ABORT "full flag LATE by one: a write lands at used_w = DEPTH in the overflow phase and async_fifo's own severity-failure assert stops the run" \
  "      elsif used_w = to_unsigned(DEPTH-1, AW+1) and wr_now = '1' then" \
  "      elsif used_w = to_unsigned(DEPTH, AW+1) and wr_now = '1' then"
mutate F2 rtl/async_fifo.vhd SURV "full flag EARLY by one (full at DEPTH-1): refuses one beat early; the clean phases never reach DEPTH-1 resident, so this is a stated floor of the stimulus" \
  "      if used_w >= to_unsigned(DEPTH, AW+1) then" \
  "      if used_w >= to_unsigned(DEPTH-1, AW+1) then"
echo "---- control: the unmutated tree ----"
mutate C0 rtl/fk33_eng_cdc.vhd SURV "no mutation (the sed anchor is a comment that stays a comment)" \
  "-- rtl/fk33_eng_cdc.vhd -- THE A CLOCK-DOMAIN SEAM." \
  "-- rtl/fk33_eng_cdc.vhd -- THE A CLOCK-DOMAIN SEAM. (control)"

echo "----"
echo "MUTATE_ENG_CDC rows-as-expected=$pass unexpected=$fail"
if [ "$fail" -ne 0 ]; then echo "MUTATE_ENG_CDC: FAIL"; exit 1; fi
echo "MUTATE_ENG_CDC: PASS"
