#!/usr/bin/env bash
# Mutation test for rtl/attn_score_q12.vhd's HDR_TREE -- the comparison tree
# for e_min and the parallel per-block subtracts that replace the unit's
# one-compare-per-cycle, one-subtract-per-cycle header scan.
#
# WHAT IS UNDER TEST, AND WHY THE CLAIM IS NARROW.  HDR_TREE changes HOW
# e_min and shb[] are computed and nothing about WHAT they are.  The tree
# folds the same NBLK exponents with the same `<`, the subtracts are the
# same subtracts with the same clamp, the partials arrive in the same order
# and the accumulate pipeline is untouched.  So the whole claim is "the
# values are identical at every HDR_TREE", and a claim of that shape is
# worth exactly what its ORACLE is worth.
#
# THE ORACLE IS ref/attn_score_q12_vec.c, THIS UNIT'S OWN, via
# sim/tb_attn_score_q12.vhd.  That generator carries three double-precision
# oracles that share none of the RTL's fixed-point machinery, and the bench
# checks four things a value comparison alone would not: s_q12, s_sat, the
# CONSTANT s_exp, and -- the one that matters here -- that p_ready is high
# before the first partial and never falls under the stream.  The last is
# why a tree that raised p_ready one state EARLY is visible at all: the
# bench drives partials with NO regard for p_ready, so an early p_ready
# takes partials against shifts that have not been computed yet.
#
# EVERY ROW IS RUN TWICE, and the second run is the point.
#
#   ON   the mutation with -gHDR_TREE=1.  It should KILL.
#   OFF  the SAME mutation with -gHDR_TREE=0, the legacy scan, where every
#        mutated line is inside `if HDR_TREE = 0 then ... else` and is dead.
#        It must SURVIVE, and that is the ATTRIBUTION CONTROL: it says the
#        kill belongs to the tree and not to an older property the edit
#        happened to trip.  A row that dies in BOTH arms mutated shared
#        code, not the tree, and its kill is not attributable here.
#
# TWO ROWS ARE UNREACHABLE AT ANY POWER-OF-TWO NBLK AND ARE RUN AT NBLK = 5
# AS WELL.  The odd-level carry -- the entry with no partner at a level with
# an odd number of live entries -- cannot execute when NBLK is 8, 4 or 2,
# which is every geometry this design is built at.  Mutating it at NBLK = 8
# therefore measures NOTHING, and a SURVIVED there would be an unreachable
# mutant reported as a resolution floor, which is the error this project has
# already recorded twice.  Rows T3 and T5 are run at both NBLK values and
# the two results are reported separately.
#
# Usage:  bash sim/mutate_attn_score_hdr.sh
# Env:    SCRATCH=<dir>
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Same guard, same reasons, as sim/mutate_attn_score_early.sh.
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

MUTV="$MUT_REPO/sim/mutverdict.py"
GHDL="${GHDL:-ghdl}"
cd "$MUT_REPO"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
STOP=2ms

FILES="rtl/util_pkg.vhd rtl/attn_score_q12.vhd sim/tb_attn_score_q12.vhd"

cc -O2 -w -I ref -o "$SCRATCH/gensq" ref/attn_score_q12_vec.c -lm || exit 2

NKILL=0; NABORT=0; NSURV=0; NTOT=0
declare -A VERD

# run_case <tag> <desc> <mutdir> <nblk> <extra ghdl args...>
run_case() {
  local tag="$1" desc="$2" mutdir="$3" nblk="$4"; shift 4
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  if [ "$mutdir" = __ANCHOR_FAIL__ ]; then
    echo "$tag  BADMUT (anchor matched 0 times -- the mutation was NOT applied)  -- $desc"
    echo "        NOT a survival.  Nothing was measured about the oracle."
    VERD[$tag]=BADMUT; NABORT=$((NABORT+1)); return
  fi
  rm -rf "$dir"; mkdir -p "$dir/run"
  ( cd "$dir/run" && "$SCRATCH/gensq" attn_score_q12_vec.txt 64 "$nblk" 4 ) \
      >/dev/null 2>&1 || { echo "$tag  VECGEN FAILED"; VERD[$tag]=VECGEN; return; }
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    if ! "$GHDL" -a --std=08 -frelaxed --workdir="$dir" "$src" \
         >> "$dir/analyze.log" 2>&1; then
      echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)  -- $desc"
      sed -n 1,4p "$dir/analyze.log"; VERD[$tag]=NOBUILD; return
    fi
  done
  ( cd "$dir/run" && timeout -k 5 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir=.. tb_attn_score_q12 -gNBLK="$nblk" "$@" \
      --max-stack-alloc=0 --stop-time="$STOP" > run.log 2>&1 )
  local rcv=$?
  local v
  v=$(python3 "$MUTV" "$dir/run/run.log" tb_attn_score_q12 "$rcv")
  VERD[$tag]=$v
  if [ "$v" = PASS ]; then
    NSURV=$((NSURV+1)); echo "$tag  SURVIVED   -- $desc"
  elif [ "$v" = KILLED ]; then
    NKILL=$((NKILL+1)); echo "$tag  KILLED     -- $desc"
    grep -avE "metavalue" "$dir/run/run.log" \
      | grep -aE "s_q12 got|s_sat got|s_exp is|p_ready FELL|ovr asserted|OVERRUN PHASE|err asserted|hdr_taken|FAIL" \
      | head -1 | sed 's/^/        /' | cut -c1-170
  else
    NABORT=$((NABORT+1)); echo "$tag  ABORT (${v#ABORT:})  -- $desc"
    echo "        the run DIED before the checker reached a verdict, so the"
    echo "        checker was NOT shown to catch this.  Not counted as a kill."
    tail -2 "$dir/run/run.log" | sed 's/^/        /' | cut -c1-170
  fi
}

# mutate_rtl <tag> <file> <old> <new>  [<old2> <new2>] ...
mutate_rtl() {
  local tag="$1" file="$2"; shift 2
  local dir="$SCRATCH/${tag}_src"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$file" "$dir/$(basename "$file")" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
args = sys.argv[3:]
for i in range(0, len(args), 2):
    old, new = args[i], args[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  # A FAILED ANCHOR MUST NOT LOOK LIKE AN UNMUTATED RUN.  This function used
  # to echo the empty string here, and run_case reads an empty mutdir as "use
  # the repo file" -- so a mutation whose anchor text had drifted ran the
  # PRISTINE design and was reported SURVIVED, with the python diagnostic
  # buried in the log above the row.  MEASURED on this script 2026-09-20:
  # row T2's anchor was broken by a shell-quoting mistake, matched 0 times,
  # and both its arms AND its ten-seed sweep reported the unmutated design as
  # an inert mutant.  That is this project's "guards that pass for the wrong
  # reason" class, inside a mutation harness, which is the one place it is
  # least visible.  The sentinel below makes it a loud row instead.
  if [ $? -ne 0 ]; then echo "__ANCHOR_FAIL__"; return; fi
  echo "$dir"
}


# seed_sweep <tag> <mutdir> <nblk> <ghdl args...>
#
# WHY THIS EXISTS, AND IT IS THE MOST USEFUL THING IN THIS SCRIPT.  A row
# that SURVIVES the committed golden has not been shown to be inert; it has
# been shown that ONE vector file does not reach it.  Those are different
# claims and this project has already recorded a golden that masked a
# mutation completely.  ref/attn_score_q12_vec.c takes a SEED as its fifth
# argument, so the same mutant can be re-run against ten independently
# drawn vector sets at no design cost at all.  A row that dies at some
# seeds and not at the committed one is a statement about the GOLDEN.  A
# row that survives all eleven is a much stronger claim to inertness --
# still not a proof, and it is not reported as one.
SWEEP_SEEDS="1 2 3 4 5 6 7 8 9 10"
seed_sweep() {
  local tag="$1" mutdir="$2" nblk="$3"; shift 3
  local dir="$SCRATCH/${tag}_seedsweep"
  if [ -n "$mutdir" ] && [ ! -r "$mutdir/attn_score_q12.vhd" ]; then
    echo "   SEEDSWEEP $tag  SKIPPED -- no mutated source at $mutdir"
    SWEEP[$tag]="BADMUT"; return
  fi
  rm -rf "$dir"; mkdir -p "$dir/run"
  local f src
  for f in $FILES; do
    src="$f"
    [ -n "$mutdir" ] && [ -r "$mutdir/$(basename "$f")" ] \
        && src="$mutdir/$(basename "$f")"
    "$GHDL" -a --std=08 -frelaxed --workdir="$dir" "$src" \
      >> "$dir/analyze.log" 2>&1 || { echo "$tag  SEEDSWEEP DID NOT ANALYZE"; return; }
  done
  local nk=0 nt=0 sd hits
  for sd in $SWEEP_SEEDS; do
    ( cd "$dir/run" && "$SCRATCH/gensq" attn_score_q12_vec.txt 64 "$nblk" 4 "$sd" ) \
        >/dev/null 2>&1 || continue
    ( cd "$dir/run" && timeout -k 5 300 "$GHDL" -r --std=08 -frelaxed \
        --workdir=.. tb_attn_score_q12 -gNBLK="$nblk" "$@" \
        --max-stack-alloc=0 --stop-time="$STOP" > "run_$sd.log" 2>&1 )
    nt=$((nt+1))
    hits=$(grep -acE "s_q12 got|s_sat got|p_ready FELL|OVERRUN PHASE|err asserted" \
             "$dir/run/run_$sd.log" 2>/dev/null)
    [ "${hits:-0}" -gt 0 ] && nk=$((nk+1))
  done
  echo "   SEEDSWEEP $tag  NBLK=$nblk  killed at $nk of $nt off-golden seeds"
  SWEEP[$tag]="$nk/$nt"
}
declare -A SWEEP

echo "=========================================================================="
echo " HDR_TREE mutation test -- oracle sim/tb_attn_score_q12 vs"
echo " ref/attn_score_q12_vec.c, every row run ON (HDR_TREE=1) and OFF (=0)"
echo "=========================================================================="

# --- the anchors, unmutated ----------------------------------------------
run_case A_on  "ANCHOR: unmutated, HDR_TREE=1, NBLK=8 (must SURVIVE)" "" 8 -gHDR_TREE=1
run_case A_off "ANCHOR: unmutated, HDR_TREE=0, NBLK=8 (must SURVIVE)" "" 8 -gHDR_TREE=0
run_case A5_on "ANCHOR: unmutated, HDR_TREE=1, NBLK=5 (must SURVIVE)" "" 5 -gHDR_TREE=1

# --- Z0: THE TEETH OF THE HARNESS ITSELF ---------------------------------
# A mutation anchor is TEXT, and text drifts under the file it points into.
# This row's anchor is deliberately impossible, so the only correct outcome
# is BADMUT.  If it ever reports SURVIVED, every other SURVIVED in this
# table is suspect, because it would mean an unapplied mutation is
# indistinguishable from an inert one.  It costs one python invocation and
# no simulation.
D=$(mutate_rtl Z0 rtl/attn_score_q12.vhd \
  "THIS TEXT IS NOT IN THE FILE AND MUST NOT BE PUT IN IT" \
  "nor this")
run_case Z0_on "Z0 impossible anchor (MUST report BADMUT, not SURVIVED)" "$D" 8 -gHDR_TREE=1

# --- T1: the comparison runs the WRONG WAY, so the tree finds the MAX ----
# The single most obvious way to get a reduction tree wrong, and the one a
# reader cannot check by inspection because both spellings look right.  The
# alignment then right-shifts by a NEGATIVE amount, which the clamp turns
# into 0, so every block lands on the wrong grid.
D=$(mutate_rtl T1 rtl/attn_score_q12.vhd \
  "                        if wv(2*i + 1) < wv(2*i) then" \
  "                        if wv(2*i + 1) > wv(2*i) then")
run_case T1_on  "T1 tree compare reversed: min becomes max, HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T1_off "T1 same edit,                              HDR_TREE=0" "$D" 8 -gHDR_TREE=0

# --- T2: A LEAF IS DROPPED from the tree --------------------------------
# The level-0 load says how many of e_l are live.  One short and the last
# block never enters the reduction, so e_min is the min over NBLK-1 of them
# and is WRONG exactly when the dropped block held the minimum.
D=$(mutate_rtl T2 rtl/attn_score_q12.vhd \
  "              if tl0 = '1' then wn := NBLK; else wn := tn; end if;" \
  "              if tl0 = '1' then wn := NBLK - 1; else wn := tn; end if;")
run_case T2_on  "T2 last leaf dropped from the tree, HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T2_off "T2 same edit,                       HDR_TREE=0" "$D" 8 -gHDR_TREE=0

# --- T3: OFF-BY-ONE ON THE LAST PARTIAL LEVEL ---------------------------
# The odd-level carry takes the entry ONE BELOW the unpaired one.  That
# entry has already been consumed as a partner at the previous iteration,
# so the mutant duplicates a value that is already represented and DROPS
# the true last one.
#
# THE FIRST VERSION OF THIS ROW WAS `2*i + 1 <= wn - 1` -> `<= wn`, and it
# is recorded here because it is a trap, not because it worked: at NBLK = 5
# that reads wv(5) out of a 0..4 array and GHDL's bound check stops the run
# before the bench reaches a verdict.  ABORT:LANG.  A mutant caught by the
# language has tested the LANGUAGE, not the oracle, and counting it as a
# kill would have credited this bench with a detection it never made.  The
# form below stays in range at every NBLK.
#
# THIS ROW IS UNREACHABLE AT NBLK = 8.  Every level of a power-of-two tree
# has an even number of live entries, so the carry is never taken and the
# mutation cannot execute.  It is run at NBLK = 8 anyway, and reported, so
# that the unreachable result stands next to the reachable one instead of
# being quietly omitted -- an unreachable mutant that SURVIVES says nothing
# about the oracle.
D=$(mutate_rtl T3 rtl/attn_score_q12.vhd \
  "                        wv(i) := wv(2*i);
                      end if;" \
  "                        wv(i) := wv(2*i - 1);
                      end if;")
run_case T3_on   "T3 partner test off by one, NBLK=8 (UNREACHABLE), HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T3_off  "T3 same edit,               NBLK=8,               HDR_TREE=0" "$D" 8 -gHDR_TREE=0
run_case T3_on5  "T3 partner test off by one, NBLK=5 (REACHABLE),   HDR_TREE=1" "$D" 5 -gHDR_TREE=1
run_case T3_off5 "T3 same edit,               NBLK=5,               HDR_TREE=0" "$D" 5 -gHDR_TREE=0

# --- T4: A SUBTRACT APPLIED TO THE WRONG BLOCK --------------------------
# The parallel subtract pass writes shb(b) from e_l(b).  Rotate the
# destination by one and every block is aligned by its NEIGHBOUR's shift.
# The set of shifts is unchanged, so a checker that only looked at the
# MULTISET of alignments would not see this.
D=$(mutate_rtl T4 rtl/attn_score_q12.vhd \
  "                shb(b) <= to_unsigned(sv, SHW);
              end loop;
              blk   <= 0;" \
  "                shb((b + 1) mod NBLK) <= to_unsigned(sv, SHW);
              end loop;
              blk   <= 0;")
run_case T4_on  "T4 per-block shifts rotated by one, HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T4_off "T4 same edit,                       HDR_TREE=0" "$D" 8 -gHDR_TREE=0

# --- T5: THE ODD ENTRY IS DISCARDED, not carried -------------------------
# `nn := (wn + 1) / 2` is what keeps an odd level's last entry alive.  Plain
# `wn / 2` throws it away at every odd level.  UNREACHABLE at NBLK = 8 for
# the same reason as T3, and run at both.
D=$(mutate_rtl T5 rtl/attn_score_q12.vhd \
  "                  nn := (wn + 1) / 2;" \
  "                  nn := wn / 2;")
run_case T5_on   "T5 odd entry discarded, NBLK=8 (UNREACHABLE), HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T5_on5  "T5 odd entry discarded, NBLK=5 (REACHABLE),   HDR_TREE=1" "$D" 5 -gHDR_TREE=1
run_case T5_off5 "T5 same edit,           NBLK=5,               HDR_TREE=0" "$D" 5 -gHDR_TREE=0

# --- T6: p_ready raised ONE STATE EARLY ---------------------------------
# The tree's whole justification is that the shifts are known before the
# first partial.  Raise p_rdy at the end of S_EMIN instead of S_SHIFTS and
# the unit accepts a partial against shb[] from the PREVIOUS header.  A
# value check alone would see this only by luck; the bench's p_ready
# discipline is what makes it a designed test rather than a hopeful one.
D=$(mutate_rtl T6 rtl/attn_score_q12.vhd \
  "              if wn = 1 then
                e_min <= wv(0);
                blk   <= 0;
                state <= S_SHIFTS;" \
  "              if wn = 1 then
                e_min <= wv(0);
                blk   <= 0;
                p_rdy <= '1';
                state <= S_SHIFTS;")
run_case T6_on  "T6 p_ready raised a state early, HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T6_off "T6 same edit,                    HDR_TREE=0" "$D" 8 -gHDR_TREE=0

# --- T7: WRITTEN TO BE INERT.  The tie rule flipped. ---------------------
# `<` keeps the earlier of two equal exponents, `<=` keeps the later.  min
# is the same VALUE either way, so this must NOT bite -- and the vector file
# leads with an equal-exponent case, so the tie path is exercised.  Reported
# under its own name whatever it does: this project has recorded a case
# where a row written to be inert was killed and the RTL, not the mutant,
# was wrong.
D=$(mutate_rtl T7 rtl/attn_score_q12.vhd \
  "                        if wv(2*i + 1) < wv(2*i) then" \
  "                        if wv(2*i + 1) <= wv(2*i) then")
run_case T7_on  "T7 tie rule flipped (INTENDED INERT), HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T7_on5 "T7 tie rule flipped (INTENDED INERT), NBLK=5, HDR_TREE=1" "$D" 5 -gHDR_TREE=1

# --- T8: WRITTEN TO BE INERT IN THE TREE AND FATAL IN THE SCAN ----------
# S_IDLE seeds e_min from block 0.  The legacy scan NEEDS that seed -- it
# only ever compares blocks 1..NBLK-1 against it.  The tree overwrites
# e_min wholesale, so removing the seed must be invisible with HDR_TREE=1
# and must KILL with HDR_TREE=0.  This is the one row whose OFF arm is
# supposed to die, and it is here as a POSITIVE CONTROL ON THE ORACLE: it
# proves the OFF configuration is not passing because the bench is asleep.
D=$(mutate_rtl T8 rtl/attn_score_q12.vhd \
  "              e_min  <= signed(e_k(EXP_W-1 downto 0));" \
  "              e_min  <= to_signed(0, EXP_W);")
run_case T8_on  "T8 S_IDLE e_min seed removed (INERT under the tree), HDR_TREE=1" "$D" 8 -gHDR_TREE=1
run_case T8_off "T8 same edit (POSITIVE CONTROL: must KILL),           HDR_TREE=0" "$D" 8 -gHDR_TREE=0


# --- THE SEED SWEEP OVER EVERY ROW THAT SURVIVED ------------------------
echo "=========================================================================="
echo " SEED SWEEP: every SURVIVING row re-run against ten OFF-GOLDEN vector"
echo " sets.  A row that dies here survived a property of the COMMITTED"
echo " vector file, not a property of the design."
echo "=========================================================================="
seed_sweep T2  "$SCRATCH/T2_src"  8 -gHDR_TREE=1
seed_sweep T3  "$SCRATCH/T3_src"  5 -gHDR_TREE=1
seed_sweep T6  "$SCRATCH/T6_src"  8 -gHDR_TREE=1
seed_sweep T7  "$SCRATCH/T7_src"  8 -gHDR_TREE=1
seed_sweep T7b "$SCRATCH/T7_src"  5 -gHDR_TREE=1
seed_sweep T8  "$SCRATCH/T8_src"  8 -gHDR_TREE=1
seed_sweep A   ""                 8 -gHDR_TREE=1

echo "--------------------------------------------------------------------------"
echo " TOTAL $NTOT   KILLED $NKILL   SURVIVED $NSURV   ABORT $NABORT"
for k in A_on A_off A5_on Z0_on T1_on T1_off T2_on T2_off T3_on T3_off T3_on5 T3_off5 \
         T4_on T4_off T5_on T5_on5 T5_off5 T6_on T6_off T7_on T7_on5 T8_on T8_off; do
  printf '   %-8s %s\n' "$k" "${VERD[$k]:-?}"
done
echo "   seed sweep (kills at off-golden seeds):"
for k in A T2 T3 T6 T7 T7b T8; do
  printf '   %-8s %s\n' "$k" "${SWEEP[$k]:-not swept}"
done
echo "--------------------------------------------------------------------------"
echo " READ THE OFF COLUMN.  A row that dies in both arms mutated shared code"
echo " and its kill is NOT attributable to HDR_TREE.  A row that survives at"
echo " NBLK = 8 and dies at NBLK = 5 was UNREACHABLE at 8 and measured nothing"
echo " there.  T8_off is the positive control: if it does not KILL, the OFF"
echo " arm's PASSes mean nothing."
