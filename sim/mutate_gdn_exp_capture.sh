#!/usr/bin/env bash
# Mutation test for rtl/gdn_exp_capture.vhd.
#
# WHAT sim/tb_gdn_exp_capture.vhd ACTUALLY CHECKS, read out of the file before
# anything was mutated.  Unlike every other B unit this one has NO vector file
# and NO C reference: the golden is an independent behavioural model written in
# the bench itself (a plain VHDL array plus a saturating counter, against a
# block RAM plus a read-modify-write FSM).  So there is exactly ONE class of
# mutation here -- RTL -- and one verdict:
#
#   * every valid tap of e_t is compared against the model, per (token, layer,
#     segment), over 6 tokens x 4 layers x 3 segments = 72 captures;
#   * tvalid is compared against the model's saturating count;
#   * tk = 0 is asserted separately (exactly one valid tap, the newest);
#   * one seq_rst is applied at the end and tvalid must go all-zero.
#
# A mismatch increments nerr and the run ends at `severity failure`.
#
# THE HARNESS HAS THREE STATES, NOT TWO.  A mutation that makes the DUT abort
# -- a range violation on cnt, an index out of bounds, an assertion inside the
# unit -- produces no PASS line and no "FAIL --" line either.  Scoring "no FAIL
# line" as a survivor would count those as passes, which is the exact defect
# TRACK B-GATE introduced and caught in its own harness on 2026-08-29.  ABORT
# is therefore a separate verdict and is COUNTED AS A KILL, but it is reported
# under its own name because it is a language-level kill rather than the
# checker noticing, and is worth less than a FAIL.
#
# Nothing under rtl/ or sim/ is edited: every mutation is applied to a COPY in
# a private scratch directory.
#
# Usage: bash sim/mutate_gdn_exp_capture.sh
# Env:   SCRATCH=<dir>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_exp_capture.vhd
TB=sim/tb_gdn_exp_capture.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

NKILL=0; NSURV=0; NABORT=0; NTOT=0

patch_file() {
  python3 - "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# $1 tag, $2 desc, then old new [old new ...]
mutate() {
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"

  if [ $# -gt 0 ]; then
    patch_file "$RTL" "$dir/gdn_exp_capture.vhd" "$@" || {
      echo "$tag  ANCHOR FAILED -- a mutation that did not apply has tested nothing"
      return; }
  else
    cp "$RTL" "$dir/gdn_exp_capture.vhd"
  fi

  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_exp_capture.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" "$TB" >>"$dir/analyze.log" 2>&1

  ( cd "$dir" && timeout 300 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_exp_capture --max-stack-alloc=0 --stop-time=200ms ) \
      >"$dir/run.log" 2>&1
  local rc=$?

  local verdict
  if   grep -q "tb_gdn_exp_capture: PASS" "$dir/run.log"; then verdict=SURVIVED
  elif grep -q "tb_gdn_exp_capture: FAIL" "$dir/run.log"; then verdict=KILLED
  else verdict=ABORT
  fi

  local n
  n=$(grep -c "severity error\|: e_t got\|tvalid mismatch\|exactly one tap" \
        "$dir/run.log" 2>/dev/null || true)

  case "$verdict" in
    KILLED)   NKILL=$((NKILL+1)) ;;
    ABORT)    NABORT=$((NABORT+1)); NKILL=$((NKILL+1)) ;;
    SURVIVED) NSURV=$((NSURV+1)) ;;
  esac
  local why=""
  if [ "$verdict" = ABORT ]; then
    why=$(grep -m1 -o "error:.*" "$dir/run.log" | cut -c1-52)
    [ -z "$why" ] && why="rc=$rc, no verdict line"
  fi
  printf '%-4s %-8s %-4s %-52s -- %s\n' "$tag" "$verdict" "$n" "$why" "$desc"
}

echo "================= mutations of gdn_exp_capture ======================"
echo "one class only (RTL); the golden is the bench's own behavioural model."
echo "columns: tag | verdict | mismatch lines | abort reason | description"
echo "ABORT counts as a KILL but is named separately: the language stopped the"
echo "run, the checker did not notice anything."
echo

# ---- the control.  A harness whose unmutated run does not survive is measuring
#      its own build, not the unit.
mutate M0 "CONTROL: unmutated"

echo
echo "---- the shift register itself ----------------------------------------"

mutate M1 "the capture shifts the WRONG WAY: the new exponent lands in tap 0" \
"            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & mem_q(WW-1 downto 8);" \
"            mem(cap_addr_r) <= mem_q(WW-9 downto 0)
                             & std_logic_vector(cap_exp_r);"

mutate M2 "the shift drops TWO taps per capture instead of one" \
"            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & mem_q(WW-1 downto 8);" \
"            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & mem_q(WW-9 downto 8) & x\"00\";"

mutate M3 "the word is REPLACED rather than shifted (only the current tap survives)" \
"            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & mem_q(WW-1 downto 8);" \
"            mem(cap_addr_r) <= std_logic_vector(cap_exp_r)
                             & (WW-9 downto 0 => '0');"

echo
echo "---- addressing --------------------------------------------------------"

mutate M4 "the capture address transposes layer and segment" \
"              a := cap_layer * SEGS + cap_seg;" \
"              a := cap_seg * LAYERS + cap_layer;"

mutate M5 "the READ address transposes layer and segment (capture does not)" \
"              a := rd_layer * SEGS + rd_seg;" \
"              a := rd_seg * LAYERS + rd_layer;"

echo
echo "---- tap validity, the masked-operand property this unit exists for -----"

mutate M6 "mask_of is off by one: the oldest valid tap is dropped" \
"      if t >= kk - n then v(t) := '1'; end if;" \
"      if t >= kk - n + 1 then v(t) := '1'; end if;"

mutate M7 "mask_of is off by one the other way: one INVALID tap is declared valid" \
"      if t >= kk - n then v(t) := '1'; end if;" \
"      if t >= kk - n - 1 then v(t) := '1'; end if;"

mutate M8 "tvalid is built from the CAPTURE entry's count, not the read entry's" \
"            tvalid_r <= mask_of(cnt(rd_addr_r), K);" \
"            tvalid_r <= mask_of(cnt(cap_addr_r), K);"

mutate M9 "the tap counter saturates at K-1, so the oldest tap is never valid" \
"            if cnt(cap_addr_r) < K then" \
"            if cnt(cap_addr_r) < K-1 then"

mutate M10 "the tap counter is never incremented (tvalid stays all-zero)" \
"            if cnt(cap_addr_r) < K then
              cnt(cap_addr_r) <= cnt(cap_addr_r) + 1;
            end if;" \
"            if false then
              cnt(cap_addr_r) <= cnt(cap_addr_r) + 1;
            end if;"

mutate M11 "the counter's saturation guard is deleted (it runs past K)" \
"            if cnt(cap_addr_r) < K then
              cnt(cap_addr_r) <= cnt(cap_addr_r) + 1;
            end if;" \
"            cnt(cap_addr_r) <= cnt(cap_addr_r) + 1;"

mutate M12 "seq_rst does not clear the counters" \
"        if seq_rst = '1' then
          -- Only the counters.  Every tap that tvalid will report as valid is
          -- written before it can be read, so clearing the words would be
          -- 4,608 bits of reset fanout for nothing.
          cnt <= (others => 0);
        end if;" \
"        if false then
          cnt <= (others => 0);
        end if;"

echo
echo "---- the handshakes ----------------------------------------------------"

mutate M13 "rd_ack is asserted a cycle early, before e_t/tvalid are stable" \
"            elsif rd_req = '1' then
              a := rd_layer * SEGS + rd_seg;" \
"            elsif rd_req = '1' then
              rd_ack_r   <= '1';
              a := rd_layer * SEGS + rd_seg;"

mutate M14 "the read is served straight out of the array, skipping the RMW settle" \
"            e_t_r    <= mem_q;" \
"            e_t_r    <= mem(rd_addr_r);"

mutate M15 "a READ wins over a capture in S_IDLE, so a capture can be dropped" \
"            if cap_req = '1' then
              a := cap_layer * SEGS + cap_seg;" \
"            if cap_req = '1' and rd_req = '0' then
              a := cap_layer * SEGS + cap_seg;"

mutate M16 "cap_ready never drops, so a caller can start a second capture inside the RMW" \
"              ready_r    <= '0';
              state      <= S_CAP_RD;" \
"              ready_r    <= '1';
              state      <= S_CAP_RD;"

# EXPECTED SURVIVOR, and a TRUE EQUIVALENT MUTANT rather than a stimulus gap.
# S_CAP_RD exists to give "one cycle for the synchronous read to land in mem_q"
# (the unit's own comment), but mem_q is assigned in S_IDLE, so it is already
# stable at the START of the next state whichever state that is.  Deleting the
# hop is therefore unobservable, and the finding is about the UNIT: it spends
# one cycle per capture doing nothing.  Reported, not fixed -- a capture is not
# a hot path and the cycle buys a clean separation between the array read and
# the shift.
mutate M17 "the RMW's read-settle cycle is deleted (S_IDLE goes straight to S_CAP_WR)" \
"              ready_r    <= '0';
              state      <= S_CAP_RD;" \
"              ready_r    <= '0';
              state      <= S_CAP_WR;"

echo
echo "kill ratio: $NKILL killed ($NABORT of them by ABORT), $NSURV survived, of $NTOT"
echo "scratch dir with every mutant and its log: $SCRATCH"
