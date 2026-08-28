#!/usr/bin/env bash
# Mutation test for rtl/attn_twiddle.vhd.  Same discipline as
# sim/mutate_attn_gate.sh and sim/mutate_attn_emit.sh: every mutation is
# well-formed VHDL and in bounds, so a KILL is the checker noticing and not the
# language noticing, and a SURVIVOR is investigated by READING the code rather
# than assumed to be equivalent.
#
# Every mutation is of the ARCHITECTURE BODY.  A mutation of a GENERIC DEFAULT
# tests nothing when the testbench's generic map overrides it, and
# tb_attn_twiddle passes NPAIR, TBL, POS_W, Q_W and PHI_W explicitly.
#
# Usage:  bash sim/mutate_attn_twiddle.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>   NPAIR=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_twiddle.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_twiddle_vec.txt}"
NCASE="${NCASE:-24}"
NPAIR="${NPAIR:-32}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_twiddle_vec" ref/attn_twiddle_vec.c -lm -I ref \
    || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_twiddle_vec" \
      "$(basename "$VECS")" "$NCASE" "$NPAIR" ) || exit 2
fi

# Configuration C's TW_GAP is 11 for a MEASURED reason: the pipeline is 8
# stages deep, so a consumer gap shorter than that never blocks the output long
# enough to distinguish a DUT that freezes the pipeline from one that lets it
# run under a held valid.  A hold test whose ack is prompter than the thing
# being held has tested nothing -- attn_softmax's M6 survives at lag 3 and is
# killed at 9, and attn_kv_quant's M6 is an equivalent mutant at M_GAP = 0.
#
# Configuration B ties every ready high.  It is kept because every run in this
# subsystem so far has shown the DEGENERATE configuration is NOT strictly
# weaker: it is the only one that catches an explicit done_r clear inside the
# ack branch.
#
# --stop-time is 20ms, not the 900ms the earlier scripts here use.  The longest
# LEGITIMATE run is 96 us, so 20 ms is a 200x margin, and a mutation that HANGS
# runs to the stop time -- at 900 ms that is 90 million simulated cycles per
# hung run, which turned a five-minute suite into an hour once already.
cfg_name() { case "$1" in
  A) echo "shipped: tw_ready period 3, done ack lag 4";;
  B) echo "DEGENERATE: every ready tied high, no lag anywhere";;
  C) echo "slow consumer: tw_ready period 11 (> the 8-stage pipeline), ack 9";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gTW_GAP=3 -gACK_LAG=4";;
  B) echo "-gTW_GAP=0 -gACK_LAG=0";;
  C) echo "-gTW_GAP=11 -gACK_LAG=9";;
esac; }
CFGS="A B C"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_twiddle.vhd" "$old" "$new" <<'PY'
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
  for f in util_pkg imrope_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_twiddle.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_twiddle.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_twiddle \
         -gNCASE="$NCASE" -gNPAIR="$NPAIR" -gVECS="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=20ms \
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
        | sed 's/^/        /' | cut -c1-180
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "==================== mutations of attn_twiddle ===================="
echo "golden: $VECS   positions: $NCASE   pairs: $NPAIR"

# ---- site R1, the phase ---------------------------------------------------
mutate N1 "the W bus mux reads the next pair's constant" \
"            s1_w   <= to_unsigned(IMROPE_W(j_iss), PHI_W);" \
"            s1_w   <= to_unsigned(IMROPE_W((j_iss+1) mod NPAIR), PHI_W);"

mutate N2 "the position is read LIVE instead of from its latched copy (RULE 2)" \
"            s2_pr <= pos_l * s1_w;" \
"            s2_pr <= pos * s1_w;"

mutate N3 "the phase takes the HIGH window of the product, not the low" \
"            s3_ps <= s2_pr(PHI_W-1 downto 0);
            s3_pc <= s2_pr(PHI_W-1 downto 0) + QUARTER;" \
"            s3_ps <= s2_pr(POS_W+PHI_W-1 downto POS_W);
            s3_pc <= s2_pr(POS_W+PHI_W-1 downto POS_W) + QUARTER;"

mutate N4 "the cosine is taken a quarter turn BEHIND instead of ahead" \
"            s3_pc <= s2_pr(PHI_W-1 downto 0) + QUARTER;" \
"            s3_pc <= s2_pr(PHI_W-1 downto 0) - QUARTER;"

mutate N5 "the cosine is taken a HALF turn ahead" \
"            s3_pc <= s2_pr(PHI_W-1 downto 0) + QUARTER;" \
"            s3_pc <= s2_pr(PHI_W-1 downto 0) + QUARTER + QUARTER;"

# ---- site R2, the interpolation -------------------------------------------
mutate N6 "the index and fraction split one bit low" \
"            s4_is  <= s3_ps(PHI_W-1 downto FRACW);
            s4_fs  <= s3_ps(FRACW-1 downto 0);" \
"            s4_is  <= s3_ps(PHI_W-2 downto FRACW-1);
            s4_fs  <= s3_ps(FRACW-2 downto 0) & '0';"

mutate N7 "the interpolation is dropped, nearest lower entry only" \
"            s5_shi <= to_signed(SIN_TBL(to_integer(s4_is + 1)), Q_W);" \
"            s5_shi <= to_signed(SIN_TBL(to_integer(s4_is)), Q_W);"

mutate N8 "the interpolation reaches two entries ahead" \
"            s5_shi <= to_signed(SIN_TBL(to_integer(s4_is + 1)), Q_W);" \
"            s5_shi <= to_signed(SIN_TBL(to_integer(s4_is + 2)), Q_W);"

mutate N9 "the table delta is computed with the wrong sign" \
"            sd_v := resize(s5_shi, Q_W+1) - resize(s5_slo, Q_W+1);" \
"            sd_v := resize(s5_slo, Q_W+1) - resize(s5_shi, Q_W+1);"

mutate N10 "the interpolation ROUNDS where it must floor" \
"            s8_sin <= s7_slo + resize(s7_sp(PRD_W-1 downto FRACW), Q_W);" \
"            s8_sin <= s7_slo + resize(shift_right(s7_sp
                        + to_signed(2**(FRACW-1), PRD_W), FRACW), Q_W);"

mutate N11 "the interpolation slice is one bit too high" \
"            s8_cos <= s7_clo + resize(s7_cp(PRD_W-1 downto FRACW), Q_W);" \
"            s8_cos <= s7_clo + resize(s7_cp(PRD_W-1 downto FRACW+1), Q_W);"

# N12 is the mutation that MOVED the design.  At the first DLT_W -- Q_W + 1,
# taken from the operand range rather than from the table -- it SURVIVED every
# configuration, because 17 bits and 16 bits both hold the true maximum step of
# 201 comfortably.  The width was decorative.  DLT_W is now computed from
# SIN_TBL by sin_delta_w and is 9, so one bit narrower cannot hold 201 and the
# mutation is killed.  A width that no mutation can reach is not a width, it is
# a comment -- the same lesson as a guard no vector reaches.
mutate N12 "the table delta is one bit narrower than the table needs" \
"  constant DLT_W  : integer := sin_delta_w;           -- 9" \
"  constant DLT_W  : integer := sin_delta_w - 1;"

# And the trap that the narrowing exposed, kept as its own mutation: the
# operands must NOT be narrowed before the subtract.
mutate N22 "the table delta narrows its OPERANDS instead of slicing the result" \
"            sd_v := resize(s5_shi, Q_W+1) - resize(s5_slo, Q_W+1);" \
"            sd_v := resize(resize(s5_shi, DLT_W) - resize(s5_slo, DLT_W), Q_W+1);"

mutate N13 "sin and cos are swapped at the output" \
"  tw_cos    <= s8_cos;
  tw_sin    <= s8_sin;" \
"  tw_cos    <= s8_sin;
  tw_sin    <= s8_cos;"

mutate N14 "the sine path uses the COSINE index" \
"            s5_slo <= to_signed(SIN_TBL(to_integer(s4_is)), Q_W);" \
"            s5_slo <= to_signed(SIN_TBL(to_integer(s4_ic)), Q_W);"

# ---- the interface contract, RULE 1, RULE 2 and the ordering rule ---------
mutate N15 "tw_j reads the LIVE issue counter instead of the pipeline" \
"  tw_j      <= to_unsigned(j_p(DEPTH), JW);" \
"  tw_j      <= to_unsigned(j_iss mod NPAIR, JW);"

mutate N16 "the published phase is the one two stages back" \
"            s8_phi <= s7_phi;" \
"            s8_phi <= s6_phi;"

mutate N17 "cfg_taken is never published (the ORDERING guard)" \
"              cfg_tk <= '1';          -- RULE 2: the instant, made observable" \
"              cfg_tk <= '0';"

mutate N18 "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"            done_r <= '1';
            if done_ack = '1' then" \
"            done_r <= '1';
            if true then"

mutate N19 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate N20 "done is reached before the pipeline has DRAINED" \
"            if pipe_e = '1' then
              state <= S_DONE;
            end if;" \
"            state <= S_DONE;"

mutate N21 "the pipeline advances under a blocked output (pairs are lost)" \
"  adv    <= '1' when (v(DEPTH) = '0' or tw_ready = '1') else '0';" \
"  adv    <= '1';"

echo "==================================================================="
