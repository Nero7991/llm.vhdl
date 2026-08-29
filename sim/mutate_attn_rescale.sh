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

# ---------------------------------------------------------------------------
# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Several agents share this repo and the one who gets hit is not the one who
# edited the file.  So take a private copy, refuse it if it does not parse
# (which is what a half-written source looks like), and re-exec that.  Same
# guard, same reasons, as sim/regress.sh:307.  MUT_NO_REEXEC=1 disables it.
if [ -z "${MUT_REPO:-}" ]; then
  MUT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
  export MUT_REPO
fi
if [ -z "${MUT_SELF:-}" ] && [ -z "${MUT_NO_REEXEC:-}" ]; then
  _self="$(mktemp -t mutself.XXXXXXXX.sh)" || exit 2
  if ! cat "${BASH_SOURCE[0]}" > "$_self"; then
    rm -f "$_self"; echo "could not take a private copy" >&2; exit 2
  fi
  if ! "${BASH:-/bin/bash}" -n "$_self" 2>/dev/null; then
    rm -f "$_self"
    echo "the private copy does not parse -- this script was probably being" >&2
    echo "  written at the instant it was copied.  Try again." >&2
    exit 2
  fi
  chmod 0700 "$_self"; export MUT_SELF="$_self"
  exec "${BASH:-/bin/bash}" "$_self" "$@"
fi
trap 'if [ -n "${MUT_SELF:-}" ]; then rm -f "$MUT_SELF"; fi' EXIT

# THREE VERDICTS, NOT TWO.  This harness used to judge a mutation with
#   ghdl -r ... && grep -q PASS
# under which a run that DIED -- an elaboration error, a language bound check,
# the DUT's own assert, a wedge to --stop-time -- scored as a KILL even though
# the checker never ran.  sim/mutverdict.py separates the two: KILLED means the
# CHECKER noticed and said so, ABORT means the run never reached a verdict the
# checker owns.  An ABORT is reported under its own name and counted apart.
# Read the header of sim/mutverdict.py for the full rule.
MUTV="$MUT_REPO/sim/mutverdict.py"
NKILL=0; NABORT=0; NSURV=0; NTOT=0
cd "$MUT_REPO"
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
  NTOT=$((NTOT+1))
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

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_rescale \
         -gVEC="$VECS" $(cfg_args "$c") --stop-time=60ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_attn_rescale "$rcv")
    case "$v" in
      PASS)   survivors="$survivors $c" ;;
      KILLED) killers="$killers $c" ;;
      *)      aborts="$aborts $c(${v#ABORT:})" ;;
    esac
  done
  if [ -n "$killers" ]; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED by:$killers   aborted:${aborts:- -}   survived:${survivors:- -}   -- $desc"
    for c in $killers; do
      echo "      [$c $(cfg_name "$c")]"
      grep -E "report error|assertion failure" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-170
    done
  elif [ -n "$aborts" ]; then
    NABORT=$((NABORT+1))
    echo "$tag  ABORT   aborted:$aborts   survived:${survivors:- -}   -- $desc"
    echo "      the run DIED before the checker reached a verdict, so the checker"
    echo "      was NOT shown to catch this.  Not counted as a kill."
    for c in $aborts; do
      tail -2 "$dir/run_${c%%(*}.log" | sed "s|^|        [${c}] |" | cut -c1-180
    done
  else
    NSURV=$((NSURV+1))
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "============ mutations of attn_rescale_skel ============"
echo "golden: $VECS"

# ---- THE CHUNK SPLIT.  The whole 1-DSP claim rests on these. -------------
# ---- THE CONTROL, run BEFORE any mutation ---------------------------------
# A MUTATION TABLE READ AGAINST A CONFIGURATION THAT FAILS ON THE CLEAN DESIGN
# MEASURES NOTHING.  Every row in such a column is a "kill" the mutation did
# not earn, and a mutation whose only killer is that column has not been shown
# to be visible to the checker at all.  sim/mutate_seq_tbl_shape.sh has always
# run a control; the multi-config harnesses did not.
#
# MEASURED 2026-08-29, and this is why the row exists: sim/mutate_attn_emit.sh
# config B (-gM_GAP=0 -gACK_LAG=0) WEDGED ON THE UNMUTATED DESIGN -- 20 ms of
# simulated time, not one line of output, not even the heartbeat.  Under the
# old two-way judging that silence scored as a KILL on all 22 rows, and two of
# them had no other evidence.
#
# FIXED 2026-08-29, same day, in sim/tb_attn_emit.vhd, and the diagnosis in the
# note that first reported it was WRONG about the mechanism.  It is not that
# done_r cleared in the cycle it was raised.  At ACK_LAG = 0 the ack already
# stands when the unit completes, so `done` is legally high for exactly ONE
# cycle -- and the bench waited for the TWO instances' done signals
# SEQUENTIALLY, `while done /= '1'` then `while done1 /= '1'`.  MEASURED by
# instrumenting a scratch copy: the one-group instance has no S_EMIN pass and
# finishes TWO CYCLES EARLIER (done1 at tick 217, done at tick 219), so the
# first loop consumed done1's whole pulse and the second waited forever.  The
# bench now latches each pulse as it is seen.  Configuration B is
# A=PASS B=PASS C=PASS on the clean design; the control row proves it on every
# run rather than asking anyone to trust this paragraph.
#
# The control goes through the SAME mutate() path as every other row, with the
# substitution deliberately an identity, so it exercises the same analyze, the
# same generics and the same classifier rather than a hand-rolled copy of them.
# It is counted in the totals, and it is the one row where SURVIVED is the
# right answer: the clean design survives because there is nothing wrong with
# it.  Any config listed as aborted or killed here invalidates that config's
# column in everything below.
mutate CTL "CONTROL: the UNMUTATED design.  Every config must say SURVIVED" \
"entity attn_rescale_skel is" \
"entity attn_rescale_skel is"

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

echo
echo "--------------------------------------------------------------------"
echo "verdicts: $NKILL killed by the checker, $NABORT aborted before the"
echo "  checker reached a verdict, $NSURV survived, of $NTOT attempted."
echo "  An ABORT is NOT a kill: the run died and the checker never spoke."
echo "  The CTL row is one of those $NTOT and is a CONTROL, not a mutation:"
echo "  it is the unmutated design and SURVIVED is its correct answer, so the"
echo "  mutation-only figures are one lower in whichever column it landed in."
echo "  $(( NTOT - NKILL - NABORT - NSURV )) mutation(s) never ran at all"
echo "  (anchor failure or did-not-analyze); those are printed above."
echo "scratch dir with every mutant and every log: $SCRATCH"
