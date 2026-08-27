#!/usr/bin/env bash
# Mutation test for rtl/seq_vec_res.vhd.  Same discipline as the sibling
# scripts: every mutation is well-formed VHDL and in bounds, so a KILL is the
# checker noticing and not the language noticing, and a SURVIVOR is
# INVESTIGATED BY READING THE CODE rather than assumed to be equivalent.
#
# Every mutation is of the ARCHITECTURE BODY.  A mutation of a GENERIC DEFAULT
# tests nothing when the testbench's generic map overrides it (attn_kv_quant's
# M5 "survived" while being identical to the original), and tb_seq_vec_res
# passes LANES, MANT_W, ACC_W, EXP_W, ADDR_W and STRICT explicitly.
#
# The five configurations are chosen so that no two are ordered: an ack tied
# high and an ack lagged catch DIFFERENT defects, in-place and out-of-place
# exercise different halves of the region model, and the lane count changes
# which groups are partial.
#
# Usage: bash sim/mutate_seq_vec_res.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  SEED=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/seq_vec_res.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-40}"
SEED="${SEED:-12345}"
mkdir -p "$SCRATCH"

cc -O2 -w -o "$SCRATCH/gen" ref/seq_vec_res_vec.c -lm || exit 2
( cd "$SCRATCH" && ./gen seq_vec_res_vec.txt "$NCASE" "$SEED" >/dev/null 2>&1 )

cfg_name() { case "$1" in
  A) echo "done_ack TIED HIGH (degenerate)";;
  B) echo "done_ack lagged 20, longer than the FSM";;
  C) echo "out of place, ack lagged 4";;
  D) echo "LANES = 4, ack tied high";;
  E) echo "start held 3 past the accept, ack lagged 20";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gACK_LAG=0";;
  B) echo "-gACK_LAG=20";;
  C) echo "-gIN_PLACE=false -gACK_LAG=4";;
  D) echo "-gLANES=4 -gACK_LAG=0";;
  E) echo "-gSTART_TAIL=3 -gACK_LAG=20";;
esac; }
CFGS="A B C D E"

mutate() {
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_vec_res.vhd" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("MUTATION ANCHOR %d MATCHED %d TIMES, expected 1\n"
                         % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  if [ $? -ne 0 ]; then echo "$tag  ANCHOR FAILED  -- $desc"; return; fi
  for f in util_pkg model_cfg_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_vec_res.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,3p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_vec_res.vhd >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ( cd "$SCRATCH" && timeout 600 ghdl -r --std=08 -frelaxed \
           --workdir="$dir" tb_seq_vec_res -gNCASE="$NCASE" $(cfg_args "$c") \
           --max-stack-alloc=0 --stop-time=900ms > "$dir/run_$c.log" 2>&1 ) \
       && grep -q "tb_seq_vec_res: PASS" "$dir/run_$c.log"; then
      survivors="$survivors $c"
    else
      killers="$killers $c"
    fi
  done
  if [ -n "$killers" ]; then
    echo "$tag  KILLED by:$killers   survived:${survivors:- -}   -- $desc"
    for c in $killers; do
      grep -mE "report error|assertion (failure|error)" -m 1 "$dir/run_$c.log" 2>/dev/null \
        | head -1 | sed "s|^|      [$c] |" | cut -c1-170 \
        || grep -E "report error|assertion" "$dir/run_$c.log" | head -1 \
             | sed "s|^|      [$c] |" | cut -c1-170
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "===================== mutations of seq_vec_res ========================="

# ---- the alignment ------------------------------------------------------
mutate N1 "the two operands' left-shift amounts are swapped" \
'            b_x(i) <= shift_left(a_x(i), sxl);
            b_e(i) <= shift_left(a_e(i), sel);' \
'            b_x(i) <= shift_left(a_x(i), sel);
            b_e(i) <= shift_left(a_e(i), sxl);'

mutate N2 "the alignment round bias is dropped (the right shift truncates)" \
"            if sxr > 0 then bias_x <= shift_left(to_signed(1, ACC_W), sxr - 1);" \
"            if false  then bias_x <= shift_left(to_signed(1, ACC_W), sxr - 1);"

# NOT "remove the clamp entirely": `j_c`, `sxl` and `sel` are declared
# `natural range 0 to SHMAX`, so an unclamped value is an out-of-bounds
# assignment and the run dies on a range check rather than on the checker.  A
# mutation the LANGUAGE catches has tested nothing about the design.  One notch
# too tight stays in bounds, loses precision silently and overflows nothing --
# which is the dangerous direction and the one the reference's O5 exists for.
mutate N3 "the SHMAX clamp is one notch too tight (silent precision loss)" \
'            if diff_v > to_unsigned(SHMAX, EXP_W+1) then c_v := SHMAX;' \
'            if diff_v > to_unsigned(SHMAX-1, EXP_W+1) then c_v := SHMAX-1;'

# NOT "clamp at 31 instead of 17": for a MANT_W mantissa every shift from
# MANT_W upward rounds to zero, so 17 and 31 give the same answer and that
# mutation is EQUIVALENT -- it survived every configuration and taught nothing.
# Clamping one notch too EARLY is the reachable error: at a shift of 15 a large
# positive mantissa rounds to 1 where the true answer is 0.
mutate N4 "the alignment right shift is clamped one notch too early" \
'  constant RMAX  : natural := MANT_W + 1;           -- right shifts beyond -> 0' \
'  constant RMAX  : natural := MANT_W - 1;           -- right shifts beyond -> 0'

# ---- the magnitude reduction and the shift -------------------------------
mutate N5 "the magnitude fold takes the raw accumulator, not its absolute value" \
'              s5(i) <= signed(resize(abs_s(s4(i)), ACC_W));' \
'              s5(i) <= s4(i);'

mutate N6 "the lane mask is ignored in the magnitude fold" \
"            if m5(i) = '1' then orfold := orfold or unsigned(s5(i)); end if;" \
"            orfold := orfold or unsigned(s5(i));"

mutate N7 "the output shift is one too large (over-normalised)" \
'            sh_v := p_r - KEEP;' \
'            sh_v := p_r - KEEP + 1;'

mutate N8 "the output shift is one too small (under-normalised)" \
'            sh_v := p_r - KEEP;' \
'            sh_v := p_r - KEEP - 1;'

mutate N9 "the output exponent moves the WRONG WAY with the shift" \
'            exp_new := j_q - to_signed(sh_v, EXP_W);' \
'            exp_new := j_q + to_signed(sh_v, EXP_W);'

mutate N10 "the output round bias is dropped (the requantise truncates)" \
'            if sh_v > 0 then
              bias_o <= shift_left(to_signed(1, ACC_W), sh_v - 1);' \
'            if false then
              bias_o <= shift_left(to_signed(1, ACC_W), sh_v - 1);'

mutate N11 "the saturating clamp is removed and the mantissa wraps" \
'              if rv > to_signed(2**(MANT_W-1) - 1, ACC_W) then' \
'              if false then'

mutate N12 "the write byte-enable is all ones: the padding lanes are written" \
'            wbe_r <= m6;' \
"            wbe_r <= (others => '1');"

# ---- defect class (a): a value read for the DURATION of the job ----------
mutate N13 "the alignment reads the LIVE exponent ports, not the job shadow" \
'            if j_d >= 0 then            -- ex >= ee, so e is the larger one' \
'            if i_exp_x >= i_exp_e then  -- MUTANT: the LIVE ports'

mutate N14 "the group count and lane mask are taken from the LIVE i_n port" \
'            nrem := to_integer(j_n(LOG2L-1 downto 0));' \
'            nrem := to_integer(i_n(LOG2L-1 downto 0));' \
'              j_ng <= resize(j_n(ADDR_W-1 downto LOG2L), GA_W+1);' \
'              j_ng <= resize(i_n(ADDR_W-1 downto LOG2L), GA_W+1);' \
'              j_ng <= resize(j_n(ADDR_W-1 downto LOG2L), GA_W+1) + 1;' \
'              j_ng <= resize(i_n(ADDR_W-1 downto LOG2L), GA_W+1) + 1;'

# ---- defect class (b): the completion -----------------------------------
mutate N15 "done is a bare one-cycle pulse (the withdrawn convention)" \
"      taken_r <= '0';
      we_r    <= '0';" \
"      taken_r <= '0';
      we_r    <= '0';
      done_r  <= '0';"

mutate N16 "done is raised before the pipeline has drained, losing the tail" \
"            elsif cptr = j_ng
                  and v6 = '0' and v5 = '0' and v4 = '0' and v3 = '0'
                  and v2 = '0' and v1 = '0' then
              -- (b) \`done_r\` is raised on the edge INTO S_DONE and there is no
              -- default clear anywhere in this process.
              done_r <= '1';" \
"            elsif cptr = j_ng and v1 = '0' then
              done_r <= '1';"

mutate N17 "ready is also high while a completion is still held" \
"  ready   <= '1' when state = S_IDLE and done_r = '0' else '0';" \
"  ready   <= '1' when state = S_IDLE else '0';"

# ---- defect class (c): a scalar published after the stream it qualifies ---
mutate N18 "the output exponent is published in S_DONE, after every beat" \
'            exp_r   <= exp_new;' \
'            null;' \
"          when S_DONE =>
            if done_ack = '1' then" \
"          when S_DONE =>
            exp_r <= j_q - to_signed(sh_r, EXP_W);
            if done_ack = '1' then"

# ---- the pass boundary, which is where the one real defect was -----------
mutate N19 "the pass-1 exit drops the cptr term and fires a group early" \
"            elsif cptr = j_ng
                  and v6 = '0' and v5 = '0' and v4 = '0' and v3 = '0'
                  and v2 = '0' and v1 = '0' then
              state <= S_SHIFT;" \
"            elsif v6 = '0' and v5 = '0' and v4 = '0' and v3 = '0'
                  and v2 = '0' and v1 = '0' then
              state <= S_SHIFT;"

mutate N20 "the write address is taken one pipeline stage early" \
'            wa_r  <= g6;' \
'            wa_r  <= g5;'

echo
echo "scratch dir with every mutant and every log: $SCRATCH"
