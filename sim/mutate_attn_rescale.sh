#!/usr/bin/env bash
# Mutation test for rtl/attn_rescale_skel.vhd.  Same discipline as
# sim/mutate_attn_rope.sh: every mutation is well-formed VHDL and in bounds, so
# a KILL is the checker noticing and not the language noticing, and a SURVIVOR
# is investigated by READING the code rather than assumed equivalent.
#
# WHY A PRICING SKELETON IS MUTATION-TESTED AT ALL.  attn_lane_skel is not, and
# correctly so: it re-expresses arithmetic the spec already pins, so the only
# question is what it costs.  This one is different.  Its SEQ_MULT = true
# branch introduces a chunk decomposition that is NOT in the spec, and the file
# exists to claim that branch costs one DSP48E2 instead of two.  A structure
# that synthesises to 1 DSP while computing the wrong function prices something
# nobody can build, so the arithmetic has to be defended as hard as any
# shipping unit's.
#
# FOUR CONFIGURATIONS, because this unit has two arithmetic branches and its
# only back-pressure is the enable:
#   A  the hypothesis, with a stall shorter than the pipeline
#   B  the hypothesis, DEGENERATE -- enable tied high, nothing ever freezes
#   C  the hypothesis, a stall of 11 (longer than the 5-deep pipeline), the
#      hierarchical mux, and 4 lanes
#   D  the ANCHOR branch, the single-cycle product the spec measured at 2 DSP
#
# Configuration B is kept because in this subsystem the degenerate shape keeps
# being the only one that catches something (attn_rope's P25, and its S_HDR
# guard).  Configuration C exists because a hold test whose stall is shorter
# than the thing being held has tested nothing.
#
# Usage: bash sim/mutate_attn_rescale.sh
# Env:   SCRATCH=<dir>  VECS=<vector file>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=rtl/attn_rescale_skel.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_rescale_vec.txt}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_rescale_vec" ref/attn_rescale_vec.c -lm -I ref \
    || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_rescale_vec" \
      "$(basename "$VECS")" 512 ) || exit 2
fi

cfg_name() { case "$1" in
  A) echo "hypothesis, stall 3";;
  B) echo "hypothesis, DEGENERATE: enable tied high";;
  C) echo "hypothesis, stall 11 (> the 5-deep pipe), hierarchical mux, 4 lanes";;
  D) echo "the ANCHOR branch: single-cycle 36x13, enable tied high";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gSEQ_MULT=true  -gMUX_FLAT=true  -gLANES_SERVED=2 -gEN_GAP=3";;
  B) echo "-gSEQ_MULT=true  -gMUX_FLAT=true  -gLANES_SERVED=2 -gEN_GAP=0";;
  C) echo "-gSEQ_MULT=true  -gMUX_FLAT=false -gLANES_SERVED=4 -gEN_GAP=11";;
  D) echo "-gSEQ_MULT=false -gMUX_FLAT=true  -gLANES_SERVED=2 -gEN_GAP=0";;
esac; }
CFGS="A B C D"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_rescale_skel.vhd" "$old" "$new" <<'PY'
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
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" \
       "$dir/attn_rescale_skel.vhd" > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,3p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_rescale.vhd \
       >/dev/null 2>&1

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_rescale \
         -gVEC="$VECS" $(cfg_args "$c") --stop-time=60ms \
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
      grep -E "report error|assertion failure" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-170
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "============ mutations of attn_rescale_skel ============"
echo "golden: $VECS"

# ---- THE CHUNK SPLIT.  The whole 1-DSP claim rests on these. -------------
mutate R1 "the low chunk is taken SIGNED instead of unsigned" \
"            a_v := resize(signed('0' & unsigned(o_v(SPLIT-1 downto 0))), AW);" \
"            a_v := resize(o_v(SPLIT-1 downto 0), AW);"

mutate R2 "the high chunk is taken UNSIGNED, so a negative accumulator loses its sign" \
"            a_v := resize(o_v(ACC_W-1 downto SPLIT), AW);" \
"            a_v := resize(signed('0' & unsigned(o_v(ACC_W-1 downto SPLIT))), AW);"

mutate R3 "the two chunks are swapped between the passes" \
"          if ph = '0' then
            a_v := resize(signed('0' & unsigned(o_v(SPLIT-1 downto 0))), AW);
          else
            a_v := resize(o_v(ACC_W-1 downto SPLIT), AW);
          end if;" \
"          if ph = '1' then
            a_v := resize(signed('0' & unsigned(o_v(SPLIT-1 downto 0))), AW);
          else
            a_v := resize(o_v(ACC_W-1 downto SPLIT), AW);
          end if;"

mutate R4 "the low chunk takes one bit too many, so the chunks overlap" \
"            a_v := resize(signed('0' & unsigned(o_v(SPLIT-1 downto 0))), AW);" \
"            a_v := resize(signed('0' & unsigned(o_v(SPLIT downto 0))), AW);"

mutate R5 "the high chunk starts one bit low, so a bit is counted twice" \
"            a_v := resize(o_v(ACC_W-1 downto SPLIT), AW);" \
"            a_v := resize(o_v(ACC_W-1 downto SPLIT-1), AW);"

# ---- THE RECOMBINATION ---------------------------------------------------
mutate R6 "the high partial is weighted by 2^(SPLIT-1), one bit short" \
"          acc_p    <= acc_p + shift_left(resize(p_reg, PW), SPLIT);" \
"          acc_p    <= acc_p + shift_left(resize(p_reg, PW), SPLIT-1);"

mutate R7 "the high partial REPLACES the low one instead of adding to it" \
"          acc_p    <= acc_p + shift_left(resize(p_reg, PW), SPLIT);" \
"          acc_p    <= shift_left(resize(p_reg, PW), SPLIT);"

mutate R8 "the low partial is shifted as well, so both are weighted" \
"        elsif ph_pipe(2) = '0' then
          -- the LOW pass lands first
          acc_p    <= resize(p_reg, PW);" \
"        elsif ph_pipe(2) = '0' then
          -- the LOW pass lands first
          acc_p    <= shift_left(resize(p_reg, PW), SPLIT);"

# ---- THE PHASE, which is what pairs the two passes ----------------------
mutate R9 "the recombination reads the phase one stage early" \
"        elsif ph_pipe(2) = '0' then" \
"        elsif ph_pipe(1) = '0' then"

mutate R10 "the phase is re-derived from the live toggle instead of carried" \
"        elsif ph_pipe(2) = '0' then" \
"        elsif ph = '0' then"

mutate R11 "the phase pipeline is one stage shorter" \
"        ph_pipe(2) <= ph_pipe(1);" \
"        ph_pipe(2) <= ph;"

mutate R12 "the entry advances every cycle, so the two passes read DIFFERENT accumulators" \
"          if ph = '1' then ent <= ent + 1; end if;   -- advance after the high pass" \
"          ent <= ent + 1;"

mutate R13 "the entry advances after the LOW pass instead of the high one" \
"          if ph = '1' then ent <= ent + 1; end if;   -- advance after the high pass" \
"          if ph = '0' then ent <= ent + 1; end if;   -- advance after the high pass"

# ---- THE READ MUX, the second open question -----------------------------
mutate R14 "the flat mux selects the next entry" \
"          sel := to_integer(ent(30 downto 0)) mod NSRC;" \
"          sel := (to_integer(ent(30 downto 0)) + 1) mod NSRC;"

mutate R15 "the hierarchical mux loses its lane stride, so it reads one lane only" \
"          sel := (to_integer(ent(30 downto 0)) mod LANES_SERVED) * ACC_N;" \
"          sel := (to_integer(ent(30 downto 0)) mod LANES_SERVED) * 0;"

mutate R16 "the hierarchical mux strides by 1, so both entries come from one lane" \
"          sel := (to_integer(ent(30 downto 0)) mod LANES_SERVED) * ACC_N;" \
"          sel := (to_integer(ent(30 downto 0)) mod LANES_SERVED) * 1;"

# ---- THE ROUNDING, spec 5d ----------------------------------------------
mutate R17 "the round bias is dropped, so the shift FLOORS" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH);" \
"        r_v   := shift_right(acc_p, RSH);"

mutate R18 "the round bias is a half ulp too small" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH);" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-2), RSH);"

mutate R19 "the output shift is one bit short" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH);" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH-1);"

mutate R20 "the shift is LOGICAL, so a negative rescale becomes huge positive" \
"        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH);" \
"        r_v   := signed(shift_right(unsigned(acc_p + shift_left(to_signed(1, PW), RSH-1)), RSH));"

# ---- THE OPERAND, and RULE 2's spirit -----------------------------------
mutate R21 "f is carried as a SIGNED 13-bit value, so f >= 4096 goes negative" \
"        b_reg <= signed('0' & f_in);" \
"        b_reg <= resize(signed(f_in), BW);"

mutate R22 "the anchor branch narrows the accumulator to the chunk width" \
"          a_reg <= resize(o_v, AW);" \
"          a_reg <= resize(o_v(SPLIT-1 downto 0), AW);"

# ---- THE FREEZE ---------------------------------------------------------
mutate R23 "the entry counter advances even while the unit is disabled" \
"      elsif en = '1' then
        if SEQ_MULT then" \
"      else
        if SEQ_MULT then"

# ---- THE COMPLETION FLAG, which sets the cadence ------------------------
mutate R24 "the completion flag is raised on BOTH passes, doubling the publish rate" \
"          acc_p    <= resize(p_reg, PW);
          sum_done <= '0';" \
"          acc_p    <= resize(p_reg, PW);
          sum_done <= '1';"

mutate R25 "the completion flag is read one cycle late" \
"        v_reg <= sum_done;" \
"        v_reg <= not sum_done;"

echo "============ end ============"
