#!/usr/bin/env bash
# Mutation test for rtl/attn_recip.vhd.  Same discipline as
# sim/mutate_attn_softmax.sh and sim/mutate_seq_region_lock.sh: every mutation
# is well-formed VHDL and in bounds, so a KILL is the checker noticing and not
# the language noticing, and a SURVIVOR is investigated by reading the code
# rather than assumed to be equivalent.
#
# Every mutation below is of the ARCHITECTURE BODY.  A mutation of a GENERIC
# DEFAULT tests nothing when the testbench's generic map overrides it, and
# tb_attn_recip passes S_W, R_W, R_Q, NW and DW explicitly.  (attn_kv_quant's
# M5 was first written that way and "survived" while being identical to the
# original.)
#
# Usage:  bash sim/mutate_attn_recip.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>   NHEAD=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_recip.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_recip_vec.txt}"
NCASE="${NCASE:-24}"
NHEAD="${NHEAD:-12}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_recip_vec" ref/attn_recip_vec.c -lm || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_recip_vec" \
      "$(basename "$VECS")" "$NCASE" "$NHEAD" ) || exit 2
fi

# The divide is 44 cycles and the pair is offered once per head, so a
# consumer-ready lag of 5 is long enough to distinguish a HELD r_valid from a
# pulsed one; config B removes both lags and is the degenerate case, kept
# because the attn_softmax run showed the degenerate configuration is not
# strictly weaker -- it is the only one that catches an explicit `done_r` clear
# inside the ack branch.
cfg_name() { case "$1" in
  A) echo "shipped: ready lag 5, done ack lag 4";;
  B) echo "DEGENERATE: both prompt, no back-pressure anywhere";;
  C) echo "slow gate: ready lag 20, done ack lag 12";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gR_READY_LAG=5 -gACK_LAG=4";;
  B) echo "-gR_READY_LAG=0 -gACK_LAG=0";;
  C) echo "-gR_READY_LAG=20 -gACK_LAG=12";;
esac; }
CFGS="A B C"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_recip.vhd" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo "$tag: ANCHOR FAILED"; return; fi
  for f in util_pkg divider_rs; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_recip.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_recip.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_recip \
         -gNCASE="$NCASE" -gNHEAD="$NHEAD" -gVECS="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=900ms \
         > "$dir/run_$c.log" 2>&1 && grep -q "PASS" "$dir/run_$c.log"; then
      survivors="$survivors $c"
    else
      killers="$killers $c"
    fi
  done
  if [ -n "$killers" ]; then
    echo "$tag  KILLED by:$killers   survived:${survivors:- -}   -- $desc"
    for c in $killers; do
      echo "      [$c $(cfg_name "$c")]"
      grep -E "report error" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-170
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "===================== mutations of attn_recip ====================="
echo "golden: $VECS   layers: $NCASE   heads: $NHEAD"

# ---- the numeric contract -------------------------------------------------
mutate N1 "p is one too large" \
"            p_r <= to_unsigned(msb_pos_u(s_l), PW);" \
"            p_r <= to_unsigned(msb_pos_u(s_l) + 1, PW);"

mutate N2 "the numerator's exponent drops R_Q by one" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q, sh_r'length);" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q-1, sh_r'length);"

mutate N3 "the numerator omits p, so the reciprocal is not normalised" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q, sh_r'length);" \
"            sh_r  <= to_unsigned(R_Q, sh_r'length);"

mutate N4 "msb_pos returns the LOWEST set bit rather than the highest" \
"    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;" \
"    for i in a'high downto a'low loop
      if a(i) = '1' then p := i; end if;
    end loop;"

mutate N5 "the numerator is built by shifting 2 rather than 1" \
"            num_r  <= shift_left(to_unsigned(1, NW), to_integer(sh_r));" \
"            num_r  <= shift_left(to_unsigned(2, NW), to_integer(sh_r));"

mutate N6 "the quotient is truncated to R_W instead of saturated" \
"            if qv > to_unsigned(2**R_W - 1, NW) then
              r_r   <= (others => '1');
              ovr_r <= '1';     -- unreachable; the reference's oracle 2 proves
            else                -- r <= 2^R_Q < 2^R_W.  A width guard.
              r_r <= resize(qv, R_W);
            end if;" \
"            r_r <= resize(qv, R_W);"

mutate N7 "the s = 0 trap is removed and the divider is asked for x/0" \
"            if s_l = 0 then" \
"            if false then"

# ---- the divider seam ------------------------------------------------------
mutate N8 "the divider's start is held for two cycles instead of one" \
"          when S_DIV =>
            div_st <= '0';" \
"          when S_DIV =>
            div_st <= '1';"

mutate N9 "the quotient is captured one cycle after done instead of at it" \
"            if div_done = '1' then
              quo_r <= unsigned(div_quo);
              state <= S_SAT;
            end if;" \
"            if div_busy = '0' and div_st = '0' then
              quo_r <= unsigned(div_quo);
              state <= S_SAT;
            end if;"

# ---- the interface contract, RULE 1 and RULE 2 ----------------------------
mutate N10 "the denominator is read LIVE instead of from its latched copy (RULE 2)" \
"  div_den <= std_logic_vector(resize(s_l, DW));" \
"  div_den <= std_logic_vector(resize(s_in, DW));"

mutate N11 "the msb scan reads the live port instead of the latched copy (RULE 2)" \
"            p_r <= to_unsigned(msb_pos_u(s_l), PW);" \
"            p_r <= to_unsigned(msb_pos_u(s_in), PW);"

mutate N12 "the pair is withdrawn without a ready (RULE 1)" \
"          when S_OUT =>
            if r_ready = '1' then
              r_v_r <= '0';" \
"          when S_OUT =>
            r_v_r <= '0';
            if r_ready = '1' then"

# NOTE on how NOT to write this one.  The obvious mutation -- asserting done_r
# in S_SAT -- is a NO-OP and survives everything, because the trailing
# `if state /= S_DONE then done_r <= '0'` at the bottom of the process is a
# LATER assignment and wins.  That is the same asymmetry the RULE 1 comment in
# the RTL describes from the other direction, and a survivor there would have
# been read as "the property is untested" when in fact the mutation was.  The
# version below leaves S_OUT for S_DONE without waiting for the ready, which the
# trailing clear cannot undo.
mutate N13 "done is reached before the last pair has been accepted" \
"          when S_OUT =>
            if r_ready = '1' then" \
"          when S_OUT =>
            if last_l = '1' then state <= S_DONE; end if;
            if r_ready = '1' then"

mutate N14 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate N15 "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then" \
"          when S_DONE =>
            done_r <= '1';
            if true then"

echo "==================================================================="
