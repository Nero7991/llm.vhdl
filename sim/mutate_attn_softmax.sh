#!/usr/bin/env bash
# Mutation test for rtl/attn_softmax.vhd.  Same discipline as
# sim/mutate_seq_region_lock.sh: every mutation is well-formed VHDL and in
# bounds, so a KILL is the checker noticing and not the language noticing, and
# a SURVIVOR is investigated by reading the code rather than assumed to be
# equivalent.
#
# Two lessons already paid for elsewhere in this project are honoured here:
#
#   * A mutation of a GENERIC DEFAULT tests nothing when the testbench's
#     generic map overrides it.  tb_attn_softmax passes P_W, Q, ROM_N, E_W and
#     S_W explicitly, so every mutation below is of the ARCHITECTURE BODY or of
#     a constant declared inside it.  (attn_kv_quant's M5 was first written as
#     a VREF_INIT generic-default mutation and "survived" while being identical
#     to the original.)
#
#   * A run with no back-pressure does not test the back-pressure path.  Config
#     B ties both acks high, which is the degenerate configuration; two of the
#     mutations below are genuinely EQUIVALENT there and killed only in A and C.
#     Reading a survivor in B as a passing result would be the mistake.
#
# Usage:  bash sim/mutate_attn_softmax.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_softmax.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_softmax_vec.txt}"
NCASE="${NCASE:-44}"
NPOS="${NPOS:-24}"
mkdir -p "$SCRATCH"

# The golden must exist and must be the one the oracles passed on.
if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_softmax_vec" ref/attn_softmax_vec.c -lm || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_softmax_vec" \
      "$(basename "$VECS")" "$NCASE" "$NPOS" ) || exit 2
fi

# The rescale sequence is 5 states long, so a rescale ack lag BELOW 5 acks the
# pass before it would have fallen anyway and cannot distinguish a held
# rs_valid from a pulsed one -- M6 survives at lag 3 and is killed at 9.  A is
# therefore the configuration that exercises both holds; C is kept precisely to
# show that the short lag does NOT, which is the same shape as attn_kv_quant's
# M6 being an equivalent mutant at M_GAP = 0.
cfg_name() { case "$1" in
  A) echo "shipped: done ack lag 4, rescale ack lag 9 -- both holds exercised";;
  B) echo "DEGENERATE: both acks tied high, no back-pressure anywhere";;
  C) echo "short array pass: rescale ack lag 3, below the 5-state sequence";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gACK_LAG=4 -gRS_ACK_LAG=9";;
  B) echo "-gACK_LAG=0 -gRS_ACK_LAG=0";;
  C) echo "-gACK_LAG=4 -gRS_ACK_LAG=3";;
esac; }
CFGS="A B C"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_softmax.vhd" "$old" "$new" <<'PY'
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
  for f in fixed_luts_pkg fixed_pkg util_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_softmax.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_softmax.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_softmax \
         -gNCASE="$NCASE" -gVECS="$VECS" $(cfg_args "$c") \
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

echo "==================== mutations of attn_softmax ===================="
echo "golden: $VECS   cases: $NCASE"

# ---- the numeric contract -------------------------------------------------
mutate M1 "the grid snap FLOORS instead of ceiling, so the maximum's own z is positive" \
"            ceil_v := resize(sc_h, MG_W) + to_signed(GRID_CNT - 1, MG_W);" \
"            ceil_v := resize(sc_h, MG_W);"

mutate M2 "the rise test is NOT strict, so a repeated maximum costs a rescale pass" \
"            elsif sc_ceil > m_g then      -- STRICT; see the header" \
"            elsif sc_ceil >= m_g then"

mutate M7 "the cone's Q30 to Q12 conversion floors instead of rounding half up" \
"          x9_sum <= resize(x8_int, ROM_W+1) + CONE_BIAS;" \
"          x9_sum <= resize(x8_int, ROM_W+1);"

mutate M8 "the offset is narrowed with resize -- THE DEFECT FOUND ON 2026-08-27" \
"          off_v  := x2_z + OFF_MID;
          x3_off <= unsigned(off_v(OFF_W-1 downto 0));" \
"          x3_off <= unsigned(resize(x2_z + OFF_MID, OFF_W));"

mutate M12 "the table-delta width is one bit narrow, so the top of the ROM truncates" \
"  constant DLT_W : integer := rom_delta_w;               -- 26" \
"  constant DLT_W : integer := rom_delta_w - 1;"

mutate M13 "frac clamped to 2^Q-1 at the top index instead of reaching 2^Q" \
"            x4_frac <= to_unsigned(2**Q, FRAC_W);" \
"            x4_frac <= to_unsigned(2**Q - 1, FRAC_W);"

mutate M14 "frac forced to 0 at the top index, so e_p tops out at EXP_ROM(255)" \
"            x4_frac <= to_unsigned(2**Q, FRAC_W);" \
"            x4_frac <= to_unsigned(0, FRAC_W);"

mutate M9 "k > ROM_N clamps the ROM INDEX rather than the FACTOR" \
"            if k_ok = '1' then
              f_r <= f_sum(CONE_SH+E_W-1 downto CONE_SH);
            else
              f_r <= (others => '0');
            end if;" \
"            f_r <= f_sum(CONE_SH+E_W-1 downto CONE_SH);"

mutate M10 "the first position is treated as an ordinary rise against m_g = 0" \
"            if first_r = '1' then" \
"            if (first_r = '1') and false then"

# ---- the concurrency contract ---------------------------------------------
mutate M3 "the DRAIN is removed, so s is rescaled with weights still in the cone" \
"          when S_DRAIN =>
            if inflight = 0 then
              state <= S_K;
            end if;" \
"          when S_DRAIN =>
            state <= S_K;"

mutate M11 "done is signalled before the cone has drained" \
"          when S_FIN =>
            if inflight = 0 then
              state <= S_DONE;
            end if;" \
"          when S_FIN =>
            state <= S_DONE;"

mutate M15 "the fold reads the cone output one cycle early" \
"        if ep_v_r = '1' then
          acc := resize(s_r, S_W+1) + resize(ep_r, S_W+1);" \
"        if x_v(CONE_ST) = '1' then
          acc := resize(s_r, S_W+1) + resize(ep_r, S_W+1);"

# ---- the interface contract, RULE 1 and RULE 2 ----------------------------
mutate M4 "the score is read LIVE instead of from its latched copy (RULE 2)" \
"            zv := resize(sc_h, Z_W) - resize(m_g, Z_W);" \
"            zv := resize(sc_q12, Z_W) - resize(m_g, Z_W);"

# M5 and M5b are the SAME class of defect written two ways, and they are killed
# by DIFFERENT configurations.  M5 is the gdn_head_emit anti-pattern the RTL
# comment warns about -- an explicit clear inside the ack branch is a LATER
# assignment that wins, which destroys the pulse outright when done_ack is tied
# high and does nothing at all when it is lagged.  M5b is a genuine one-cycle
# pulse.  Neither configuration alone catches both.
mutate M5 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate M5b "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then" \
"          when S_DONE =>
            done_r <= '1';
            if true then"

mutate M6 "the rescale pass is pulsed instead of held until the array acks (RULE 1)" \
"          when S_RS =>
            if rs_tk = '1' then
              state <= S_ZED;
            end if;" \
"          when S_RS =>
            rs_v_r <= '0';
            state  <= S_ZED;"

echo "==================================================================="
