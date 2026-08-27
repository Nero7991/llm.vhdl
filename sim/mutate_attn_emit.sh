#!/usr/bin/env bash
# Mutation test for rtl/attn_emit.vhd.  Same discipline as
# sim/mutate_attn_gate.sh, sim/mutate_attn_recip.sh and
# sim/mutate_attn_softmax.sh: every mutation is well-formed VHDL and in bounds,
# so a KILL is the checker noticing and not the language noticing, and a
# SURVIVOR is investigated by READING the code rather than assumed equivalent.
#
# Every mutation is of the ARCHITECTURE BODY.  A mutation of a GENERIC DEFAULT
# tests nothing when the testbench's generic map overrides it, and tb_attn_emit
# passes NGRP, GRP_N, IN_W, MANT_W, EXP_W, TARGET_MSB and SH_MAX explicitly.
# (attn_kv_quant's M5 was first written that way and "survived" while being
# identical to the original.)
#
# Usage:  bash sim/mutate_attn_emit.sh
# Env:    SCRATCH=<dir>  VECS=<vector file>  NCASE=<n>  NGRP=<n>  GRP_N=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_emit.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_emit_vec.txt}"
NCASE="${NCASE:-40}"
NGRP="${NGRP:-2}"
GRP_N="${GRP_N:-48}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_emit_vec" ref/attn_emit_vec.c -lm -I ref || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_emit_vec" \
      "$(basename "$VECS")" "$NCASE" "$NGRP" "$GRP_N" ) || exit 2
fi

# Configuration C's M_GAP is 11 for a MEASURED reason: the emit pass is a
# 7-stage pipeline, so a consumer gap shorter than that never blocks the output
# long enough to distinguish a DUT that freezes the pipeline from one that lets
# it run under a held valid.  A hold test whose ack is prompter than the thing
# being held has tested nothing -- attn_softmax's M6 survives at lag 3 and is
# killed at 9, and attn_kv_quant's M6 is an equivalent mutant at M_GAP = 0.
#
# Configuration B removes every gap and ties every ready high.  It is kept
# because the attn_softmax and attn_recip runs both showed the DEGENERATE
# configuration is NOT strictly weaker: it is the only one that catches an
# explicit `done_r` clear inside the ack branch.
cfg_name() { case "$1" in
  A) echo "shipped: m_ready period 3, done ack lag 4";;
  B) echo "DEGENERATE: every ready tied high, no lag anywhere";;
  C) echo "slow consumer: m_ready period 11 (> the 7-stage pipeline), ack 9";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gM_GAP=3 -gACK_LAG=4";;
  B) echo "-gM_GAP=0 -gACK_LAG=0";;
  C) echo "-gM_GAP=11 -gACK_LAG=9";;
esac; }
CFGS="A B C"

# --stop-time is 20ms, not the 900ms the earlier scripts in this directory use.
# The longest LEGITIMATE run here is 514 us (configuration C), so 20 ms is a
# 39x margin -- and a mutation that HANGS runs to the stop time, so 900 ms
# costs ~90 million simulated cycles per hung run and turns a 5-minute suite
# into an hour.  A stop time far above the longest real run buys nothing and
# is paid for by every hang.

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_emit.vhd" "$old" "$new" <<'PY'
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
  ghdl -a --std=08 -frelaxed --workdir="$dir" rtl/util_pkg.vhd >/dev/null 2>&1
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_emit.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_emit.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_emit \
         -gNCASE="$NCASE" -gNGRP="$NGRP" -gGRP_N="$GRP_N" -gVECS="$VECS" \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=20ms \
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

echo "====================== mutations of attn_emit ======================"
echo "golden: $VECS   layers: $NCASE   groups: $NGRP x $GRP_N"

# ---- the block-floating contract ------------------------------------------
mutate E1 "the pack shift is one too large" \
"            sh_v := p_msb - TARGET_MSB;" \
"            sh_v := p_msb - TARGET_MSB + 1;"

mutate E2 "the pack shift is one too small" \
"            sh_v := p_msb - TARGET_MSB;" \
"            sh_v := p_msb - TARGET_MSB - 1;"

mutate E3 "the pack FLOORS: the round bias is dropped" \
"              bias_r <= shift_left(to_signed(1, ACC_W),
                                   to_integer(shp_r) - 1);" \
"              bias_r <= to_signed(0, ACC_W);"

mutate E4 "pass B ROUNDS the alignment while pass A floors it" \
"              if m3_v = '1' then
                m4_al <= shift_right(m3_x, to_integer(m3_sh));
              end if;" \
"              if m3_v = '1' then
                if m3_sh = 0 then
                  m4_al <= m3_x;
                else
                  m4_al <= shift_right(m3_x
                             + shift_left(to_signed(1, IN_W),
                                          to_integer(m3_sh) - 1),
                             to_integer(m3_sh));
                end if;
              end if;"

mutate E5 "msb_pos returns the LOWEST set bit rather than the highest" \
"    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;" \
"    for i in a'high downto a'low loop
      if a(i) = '1' then p := i; end if;
    end loop;"

mutate E6 "e_min is seeded from a sentinel 0 rather than from group 0" \
"              e_min  <= signed(e_grid(EXP_W-1 downto 0));" \
"              e_min  <= to_signed(0, EXP_W);"

mutate E7 "the grid scan takes the MAXIMUM instead of the minimum" \
"            if e_l(grp) < e_min then
              e_min <= e_l(grp);
            end if;" \
"            if e_l(grp) > e_min then
              e_min <= e_l(grp);
            end if;"

mutate E8 "the absolute value is narrowed back to IN_W (THE resize TRAP)" \
"              ext := resize(a4_al, IN_W+1);
              if ext < 0 then
                a5_abs <= unsigned(-ext);
              else
                a5_abs <= unsigned(ext);
              end if;" \
"              ext := resize(a4_al, IN_W+1);
              if ext < 0 then
                a5_abs <= unsigned(resize(-ext, IN_W)) & '0';
              else
                a5_abs <= unsigned(ext);
              end if;"

mutate E9 "the int16 saturate is removed, so a peak that rounds up WRAPS" \
"                m_data_r  <= sat_m(rv);
                if rv /= resize(sat_m(rv), ACC_W) then" \
"                m_data_r  <= resize(rv, MANT_W);
                if rv /= resize(sat_m(rv), ACC_W) then"

mutate E10 "the amax fold reads the UNALIGNED value" \
"              ext := resize(a4_al, IN_W+1);" \
"              ext := resize(a3_x, IN_W+1);"

mutate E11 "y_exp adds the pack shift instead of subtracting it" \
"            yexp_r <= e_min - resize(signed('0' & shp_r), EXP_W);" \
"            yexp_r <= e_min + resize(signed('0' & shp_r), EXP_W);"

# ---- the group index and the latched descriptor ---------------------------
mutate E12 "pass B reads the LIVE group counter instead of the carried one" \
"                m3_x  <= signed(x_rdata);
                m3_sh <= sh_a(m2_g);" \
"                m3_x  <= signed(x_rdata);
                m3_sh <= sh_a(i_grp);"

mutate E13 "pass A reads the LIVE group counter instead of the carried one" \
"              a3_x  <= signed(x_rdata);
              a3_sh <= sh_a(a2_g);" \
"              a3_x  <= signed(x_rdata);
              a3_sh <= sh_a(i_grp);"

mutate E14 "e_grid is read LIVE in the shift derivation instead of latched (RULE 2)" \
"            sh_v := to_integer(e_l(grp)) - to_integer(e_min);" \
"            sh_v := to_integer(signed(e_grid((grp+1)*EXP_W-1 downto grp*EXP_W)))
                    - to_integer(e_min);"

# ---- the ordering rule, RULE 1 and RULE 2 ---------------------------------
mutate E15 "y_exp is published in S_DONE, AFTER the mantissas it describes" \
"            yexp_r <= e_min - resize(signed('0' & shp_r), EXP_W);" \
"            null;"

mutate E16 "hdr_valid is raised at start, before the exponent is known" \
"              sat_r  <= '0'; err_r <= '0'; hdr_r <= '0';" \
"              sat_r  <= '0'; err_r <= '0'; hdr_r <= '1';"

mutate E17 "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"              done_r <= '1';
              if done_ack = '1' then" \
"              done_r <= '1';
              if true then"

mutate E18 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"              if done_ack = '1' then" \
"              if done_ack = '1' then
                done_r <= '0';"

mutate E19 "done is raised before the last mantissa has been accepted" \
"            if m_valid_r = '0' then
              done_r <= '1';" \
"            if true then
              done_r <= '1';"

mutate E20 "the read enable is tied high, so the freeze no longer covers it" \
"  x_re    <= '1' when state = S_SCAN else
             emit_en when state = S_EMIT else
             '0';" \
"  x_re    <= '1' when state = S_SCAN else
             '1' when state = S_EMIT else
             '0';"

mutate E21 "the emit pass advances under a blocked output (mantissas are lost)" \
"  emit_en <= '0' when (m_valid_r = '1' and m_ready = '0') else '1';" \
"  emit_en <= '1';"

mutate E22 "the index pipeline reads the live counter instead of carrying it" \
"                m_index_r <= m_idx_p(5);" \
"                m_index_r <= i_abs mod NTOT;"

echo "==================================================================="
