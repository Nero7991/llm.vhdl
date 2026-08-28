#!/usr/bin/env bash
# Mutation test for rtl/attn_rope.vhd.  Same discipline as the other four
# scripts in this directory: every mutation is well-formed VHDL and in bounds,
# so a KILL is the checker noticing and not the language noticing, and a
# SURVIVOR is investigated by READING the code rather than assumed equivalent.
#
# Every mutation is of the ARCHITECTURE BODY.  A mutation of a GENERIC DEFAULT
# tests nothing when the testbench overrides it, and tb_attn_rope maps
# HEAD_DIM, N_ROT, MANT_W, Q and EXP_W explicitly.
#
# Usage:  bash sim/mutate_attn_rope.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_rope.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_rope_vec.txt}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_rope_vec" ref/attn_rope_vec.c -lm -I ref || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_rope_vec" \
      "$(basename "$VECS")" ) || exit 2
fi

# Configuration C's ACK_LAG is 9 for a MEASURED reason: the read path is 2
# cycles and the rotate pipeline is 4, so the deepest thing a held output has
# to freeze is 6 stages.  A hold test whose ack is prompter than the thing
# being held has tested nothing -- attn_softmax's M6 survives at lag 3 and is
# killed at 9, and attn_kv_quant's M6 is an equivalent mutant at zero gap.
#
# Configuration B ties every ready high and offers the twiddle with no gap.
# It is kept because in this subsystem the DEGENERATE configuration keeps
# being the only one that catches something: here it caught the FIRST version
# of this unit's own out-of-step guard, which fired in S_HDR at 95 ns on
# entirely correct producer behaviour.  With any twiddle gap at all the
# producer is carried past S_HDR before it asserts, so no other configuration
# can reach that state.
#
# --stop-time is 40ms.  The longest LEGITIMATE run is 411 us, so that is a
# 97x margin, and a mutation that HANGS runs to the stop time -- at 900 ms
# that is 90 million simulated cycles per hung run, which turned a five-minute
# suite into an hour once already.
cfg_name() { case "$1" in
  A) echo "shipped: twiddle gap 3, consumer lag 4";;
  B) echo "DEGENERATE: every ready tied high, no gap anywhere";;
  C) echo "slow consumer: twiddle gap 11, ack lag 9 (> the 6-deep path)";;
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
  python3 - "$SRC" "$dir/attn_rope.vhd" "$old" "$new" <<'PY'
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
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_rope.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_rope.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_rope \
         -gVEC="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=40ms \
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
      grep -E "report error|report failure|error:" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-180
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "==================== mutations of attn_rope ===================="
echo "golden: $VECS"

# ---- THE PAIRING.  This is the whole reason the unit exists. --------------
mutate P1 "the pair partner is the ADJACENT element, ggml NORMAL not IMROPE" \
"                raddr_r <= to_unsigned(ri, AW);
                cv(1)   <= '1';
                ri      <= ri + 1;
              end if;
              -- R1: capture x1 and read buf and the twiddle -- bus muxes only" \
"                raddr_r <= to_unsigned((ri mod NPAIR)*2 + 1, AW);
                cv(1)   <= '1';
                ri      <= ri + 1;
              end if;
              -- R1: capture x1 and read buf and the twiddle -- bus muxes only"

mutate P2 "buf is read one pair ahead, so x0 and x1 come from different pairs" \
"                r1_x0 <= buf(rot_rd);" \
"                r1_x0 <= buf((rot_rd+1) mod NPAIR);"

mutate P3 "the twiddle index trails the pair index by one" \
"                r1_c  <= tw_c(rot_rd);
                r1_s  <= tw_s(rot_rd);" \
"                r1_c  <= tw_c((rot_rd+NPAIR-1) mod NPAIR);
                r1_s  <= tw_s((rot_rd+NPAIR-1) mod NPAIR);"

mutate P4 "cos and sin are swapped" \
"                r1_c  <= tw_c(rot_rd);
                r1_s  <= tw_s(rot_rd);" \
"                r1_c  <= tw_s(rot_rd);
                r1_s  <= tw_c(rot_rd);"

# ---- THE KERNEL -----------------------------------------------------------
mutate P5 "the first output ADDS the cross term instead of subtracting" \
"            r3_d0 <= resize(r2_p00, ACC_W) - resize(r2_p01, ACC_W);" \
"            r3_d0 <= resize(r2_p00, ACC_W) + resize(r2_p01, ACC_W);"

mutate P6 "the second output SUBTRACTS the cross term instead of adding" \
"            r3_d1 <= resize(r2_p10, ACC_W) + resize(r2_p11, ACC_W);" \
"            r3_d1 <= resize(r2_p10, ACC_W) - resize(r2_p11, ACC_W);"

mutate P7 "the four products pair x with the wrong twiddle" \
"            r2_p00 <= r1_x0 * r1_c;
            r2_p01 <= r1_x1 * r1_s;" \
"            r2_p00 <= r1_x0 * r1_s;
            r2_p01 <= r1_x1 * r1_c;"

mutate P8 "the kernel FLOORS instead of rounding: the bias is dropped" \
"            r4_b0 <= r3_d0 + BIAS;
            r4_b1 <= r3_d1 + BIAS;" \
"            r4_b0 <= r3_d0;
            r4_b1 <= r3_d1;"

mutate P9 "the round bias is a half ulp too small" \
"    := shift_left(to_signed(1, ACC_W), Q-1);" \
"    := shift_left(to_signed(1, ACC_W), Q-2);"

mutate P10 "the kernel shifts Q-1, one bit short" \
"            sh0 := shift_right(r4_b0, Q);
            sh1 := shift_right(r4_b1, Q);" \
"            sh0 := shift_right(r4_b0, Q-1);
            sh1 := shift_right(r4_b1, Q-1);"

mutate P11 "the shift is LOGICAL, so a negative rotation becomes huge positive" \
"            sh0 := shift_right(r4_b0, Q);" \
"            sh0 := signed(shift_right(unsigned(r4_b0), Q));"

mutate P12 "the two outputs are written to each other's slots" \
"            y_d_r <= sat_m(sh0);
            y_i_r <= to_unsigned(r_j(4), AW);
            y_v_r <= '1';
            buf2(r_j(4)) <= sat_m(sh1);" \
"            y_d_r <= sat_m(sh1);
            y_i_r <= to_unsigned(r_j(4), AW);
            y_v_r <= '1';
            buf2(r_j(4)) <= sat_m(sh0);"

# ---- SATURATION -----------------------------------------------------------
mutate P13 "saturation is removed, so a large rotation WRAPS" \
"            y_d_r <= sat_m(sh0);" \
"            y_d_r <= resize(sh0, MANT_W);"

mutate P14 "the positive rail is one short" \
"  constant M_MAX : signed(MANT_W-1 downto 0) := not smin(MANT_W);" \
"  constant M_MAX : signed(MANT_W-1 downto 0) := not smin(MANT_W) - 1;"

mutate P15 "rope_sat is never raised, so the quality event is lost" \
"              sat_r <= '1';       -- REACHABLE on legal data; a quality event" \
"              sat_r <= sat_r;     -- REACHABLE on legal data; a quality event"

mutate P16 "rope_sat is sticky ACROSS jobs -- not cleared at start" \
"              sat_r <= '0'; err_r <= '0'; hdr_r <= '0';" \
"              err_r <= '0'; hdr_r <= '0';"

# ---- THE ROTATED / PASS-THROUGH BOUNDARY ---------------------------------
mutate P17 "the unrotated tail starts one dim late, leaving one dim stale" \
"                ri    <= N_ROT;
                pi_o  <= N_ROT;" \
"                ri    <= N_ROT+1;
                pi_o  <= N_ROT+1;"

mutate P18 "the rotation runs one pair past N_ROT into the pass-through region" \
"              if ri < N_ROT then
                raddr_r <= to_unsigned(ri, AW);" \
"              if ri < N_ROT+1 then
                raddr_r <= to_unsigned(ri, AW);"

mutate P19 "the pass-through region is emitted with a stale index" \
"                y_i_r <= to_unsigned(pi_o, AW);
                y_v_r <= '1';
                pi_o  <= pi_o + 1;" \
"                y_i_r <= to_unsigned(pi_o, AW);
                y_v_r <= '1';"

# ---- ORDERING BETWEEN THE THREE EMIT SOURCES -----------------------------
mutate P20 "S_OUT2 begins while rotated pairs are still in flight" \
"              if rot_rd = NPAIR and rv = (rv'range => '0') then" \
"              if rot_rd = NPAIR then"

mutate P21 "the second half is emitted in reverse order" \
"                y_i_r <= to_unsigned(NPAIR + o2_rd, AW);" \
"                y_i_r <= to_unsigned(N_ROT-1 - o2_rd, AW);"

mutate P22 "the second half's DATA is read in reverse, index unchanged" \
"                y_d_r <= buf2(o2_rd);" \
"                y_d_r <= buf2(NPAIR-1 - o2_rd);"

# ---- BACK-PRESSURE.  RULE 1 and the freeze. -------------------------------
mutate P23 "the pipeline advances under an unaccepted output (the element is lost)" \
"  en <= '0' when (y_v_r = '1' and y_ready = '0') else '1';" \
"  en <= '1';"

mutate P24 "the memory is left ENABLED while the address is frozen" \
"  x_re      <= en when (state = S_LOAD or state = S_ROT or state = S_PASS)" \
"  x_re      <= '1' when (state = S_LOAD or state = S_ROT or state = S_PASS)"

mutate P25 "done is a PULSE instead of held (RULE 1)" \
"              if done_ack = '1' then
                -- Do NOT clear done_r here." \
"              if done_ack = '1' then
                done_r <= '0';
                -- Do NOT clear done_r here."

mutate P26 "the exponent is read LIVE at publish instead of from its latch (RULE 2)" \
"            yexp_r <= exp_l;" \
"            yexp_r <= x_exp;"

# ---- THE ORDERING RULE: the header must precede the first element ---------
mutate P27 "the header is published in the LAST phase, after elements have flowed" \
"          when S_HDR =>
            yexp_r <= exp_l;
            hdr_r  <= '1';
            state  <= S_LOAD;" \
"          when S_HDR =>
            yexp_r <= exp_l;
            state  <= S_LOAD;
          when S_PASS =>
            hdr_r  <= '1';"

# ---- THE LOAD PHASE -------------------------------------------------------
mutate P28 "S_LOAD ends on the memory fill alone, ignoring the twiddle count" \
"              if ld_wr = NPAIR and tw_n = NPAIR then" \
"              if ld_wr = NPAIR then"

mutate P29 "a twiddle pair is taken without checking tw_valid" \
"              if tw_valid = '1' and tw_rdy = '1' then" \
"              if tw_rdy = '1' then"

mutate P30 "the DLT-free x capture writes buf one slot high" \
"                buf(ld_wr) <= signed(x_rdata);" \
"                buf((ld_wr+1) mod NPAIR) <= signed(x_rdata);"

echo "==================== end ===================="
