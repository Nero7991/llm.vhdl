#!/usr/bin/env bash
# Mutation test for rtl/attn_block.vhd's SCORE_EARLY, the early hand-over of
# the K record header to attn_score_q12.
#
# WHAT IS UNDER TEST.  SCORE_EARLY moves WHEN `sq_hdrv` is raised and nothing
# else.  The header bits are the same bits, the partials are the same partials
# in the same order, the beats do not move and no arithmetic changes, so the
# whole claim is "the values are identical with it on and with it off".  A
# claim of that shape is worth exactly what its ORACLE is worth, so every row
# below is judged by sim/tb_attn_kv_seam.vhd against ref/attn_block_seq_vec.c:
# Q1 the output values bit for bit over a multi-token sequence, Q2 the record
# image in memory at C spec 2.2's address, Q3 the beat that arrives against
# the beat that was asked for, Q4 the handshake.
#
# EVERY ROW IS RUN TWICE, and the second run is the point.
#
#   ON   the mutation with -gSCORE_EARLY=true.   It should KILL.
#   OFF  the SAME mutation with -gSCORE_EARLY=false.  For a mutation of the
#        new path it must SURVIVE, and that is the ATTRIBUTION CONTROL: it
#        says the kill belongs to SCORE_EARLY and not to an older property
#        that the edit happened to trip.
#
# THE NEW ASSERT GETS A TWO-SIDED TEST, which is the part this script does
# that its SWEEP_PIPE predecessor could not.  SCORE_EARLY rests on one new
# assumption -- `kr_hdr` stands unchanged for every beat of a record -- and
# rows H0 and H7 break it in the two opposite directions:
#
#   H0  only beat 0's header is right.  SCORE_EARLY reads beat 0, so its
#       VALUES are right and the assert is the only thing that can see the
#       violation.  The OFF arm reads the last beat and must be killed by
#       the oracle, which is what proves the mutant is real rather than inert.
#   H7  only the LAST beat's header is right.  SCORE_EARLY reads beat 0, so
#       its values are WRONG and the oracle must kill it with the assert
#       disabled.  The OFF arm reads the last beat and must survive.
#
# Between them they say whether the assert is a NEW detection (H0) or merely
# a better-located diagnostic (H7), and the answer is allowed to differ per
# row.  A row that does NOT bite is reported under its own name and kept: it
# measures the oracle's resolution floor, which is the most useful line here.
#
# Usage:  bash sim/mutate_attn_score_early.sh
# Env:    SCRATCH=<dir>
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Same guard, same reasons, as sim/mutate_attn_sweep_pipe.sh.
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
VECARGS="64 4 2 16 16 4 2 2"   # HEAD_DIM N_QH N_KVH KV_BLOCK N_ROT NTOK NLAY SEED
STOP=40ms

FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/divider_rs.vhd rtl/imrope_pkg.vhd
       rtl/rmsnorm_rs.vhd rtl/attn_recip.vhd rtl/attn_twiddle.vhd
       rtl/attn_kv_axi.vhd rtl/attn_block.vhd sim/tb_attn_kv_seam.vhd"

cc -O2 -w -I ref -o "$SCRATCH/genseq" ref/attn_block_seq_vec.c -lm || exit 2

NKILL=0; NABORT=0; NSURV=0; NTOT=0; NBAD=0; Z0SEEN=0
declare -A VERD

# run_case <tag> <desc> <mutdir> <extra ghdl args...>
run_case() {
  local tag="$1" desc="$2" mutdir="$3"; shift 3
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  # --- THE ANCHOR SENTINEL.  BADMUT is neither KILLED nor SURVIVED: it says
  # --- the mutation was never applied, so this row measured NOTHING about the
  # --- oracle.  Row Z0 is the harness's own teeth and MUST reach this branch.
  if [ "$mutdir" = __ANCHOR_FAIL__ ]; then
    echo "$tag  BADMUT (anchor matched 0 times -- the mutation was NOT applied)   -- $desc"
    VERD[$tag]=BADMUT
    if [ "$tag" = Z0 ]; then
      echo "        Z0 is the SELF-TEETH row: BADMUT here is the REQUIRED outcome."
      Z0SEEN=1
    else
      echo "        NOT a survival.  The anchor text has drifted under the file."
      NBAD=$((NBAD+1))
    fi
    return
  fi
  rm -rf "$dir"; mkdir -p "$dir/run"
  ( cd "$dir/run" && "$SCRATCH/genseq" attn_block_seq_vec.txt $VECARGS ) \
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
  ( cd "$dir/run" && timeout -k 5 900 "$GHDL" -r --std=08 -frelaxed \
      --workdir=.. tb_attn_kv_seam "$@" --max-stack-alloc=0 \
      --stop-time="$STOP" > run.log 2>&1 )
  local rcv=$?
  local v
  v=$(python3 "$MUTV" "$dir/run/run.log" tb_attn_kv_seam "$rcv")
  VERD[$tag]=$v
  if [ "$v" = PASS ]; then
    NSURV=$((NSURV+1)); echo "$tag  SURVIVED   -- $desc"
  elif [ "$v" = KILLED ]; then
    NKILL=$((NKILL+1)); echo "$tag  KILLED     -- $desc"
    grep -avE "metavalue" "$dir/run/run.log" \
      | grep -aE "MISMATCH|Q1 --|Q2 --|Q3 --|Q4 --|Q5 --|sweep read pos|kr_en was|vr_en was|same cycle|kr_hdr changed" \
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
  # A FAILED ANCHOR MUST NOT LOOK LIKE AN UNMUTATED RUN.  This line used to
  # echo the EMPTY STRING, and run_case reads an empty mutdir as "use the repo
  # file" -- so a mutation whose anchor text had drifted ran the PRISTINE
  # design and was reported SURVIVED.  MEASURED 2026-09-20 by TRACK MUTAUDIT:
  # with an impossible anchor this script's first mutant row printed SURVIVED,
  # and the only tell was one python line on stderr, above the table and
  # absent from any committed copy of it.  The sentinel makes it a loud BADMUT
  # row instead, and row Z0 below is the standing proof that it still does.
  if [ $? -ne 0 ]; then echo "__ANCHOR_FAIL__"; return; fi
  echo "$dir"
}

# The assert SCORE_EARLY adds, quoted once so every row that disables it
# disables the same text.
ASSERT_OLD="                assert kr_hdr = khdr"
ASSERT_NEW="                assert true or kr_hdr = khdr"

echo "=========================================================================="
echo " SCORE_EARLY mutation test -- oracle sim/tb_attn_kv_seam vs"
echo " ref/attn_block_seq_vec.c, every row run ON and OFF"
echo "=========================================================================="

# --- the two anchors, unmutated -----------------------------------------
run_case A_on  "ANCHOR: unmutated, SCORE_EARLY=true  (must SURVIVE)" "" \
         -gSCORE_EARLY=true
run_case A_off "ANCHOR: unmutated, SCORE_EARLY=false (must SURVIVE)" "" \
         -gSCORE_EARLY=false

# ---------------------------------------------------------------------------
# Z0: THE TEETH OF THIS HARNESS ITSELF.  A mutation anchor is TEXT, and text
# drifts under the file it points into.  This row's anchor is deliberately
# impossible, so the only correct outcome is BADMUT.  If it ever reports
# SURVIVED, every other SURVIVED in this table is suspect, because it would
# mean an unapplied mutation is indistinguishable from an inert one.  It costs
# one python invocation and no simulation.
# ---------------------------------------------------------------------------
D=$(mutate_rtl Z0 rtl/attn_block.vhd \
  "THIS TEXT IS NOT IN THE FILE AND MUST NOT BE PUT IN IT" "nor this")
run_case Z0 "SELF-TEETH: impossible anchor (MUST report BADMUT, never SURVIVED)" "$D"

# --- E1: se_rdy armed on EVERY captured K beat, not only the first ------
# The arm is supposed to fire once per record.  Armed on every beat it
# re-arms behind its own hand-over, so the NEXT position is handed the
# header that is in `khdr` at the moment the score units next go idle --
# which is the position that has just finished, not the one about to run.
D=$(mutate_rtl E1 rtl/attn_block.vhd \
  "              if (SWEEP_PIPE and pk_cnt = 0) or ((not SWEEP_PIPE) and rbi = 0)
              then
                se_rdy <= '1';
              else" \
  "              se_rdy <= '1';
              if false
              then
                null;
              else")
run_case E1_on  "E1 se_rdy armed on every K beat, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E1_off "E1 same edit,                    SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- E1c: THE ATTRIBUTION CONTROL FOR E1 --------------------------------
# E1 is stopped by the new assert, which means the VALUE ORACLE was never
# shown to catch it.  This row is the same mutant with the assert disabled,
# and it is the only thing that can say whether the assert is carrying its
# own weight on this defect or merely arriving first.
D=$(mutate_rtl E1c rtl/attn_block.vhd \
  "              if (SWEEP_PIPE and pk_cnt = 0) or ((not SWEEP_PIPE) and rbi = 0)
              then
                se_rdy <= '1';
              else" \
  "              se_rdy <= '1';
              if false
              then
                null;
              else" \
  "$ASSERT_OLD" "$ASSERT_NEW")
run_case E1c_on "E1c E1 with the NEW ASSERT DISABLED, SCORE_EARLY=true" "$D" -gSCORE_EARLY=true

# --- E1b: E1 BUILT PROPERLY --------------------------------------------
# E1 as written above is a BAD MUTANT and its own result says so.  It
# replaced the `if` that guards BOTH the arm and the assert, so the assert
# then ran on beat 0 -- where `khdr` legitimately still holds the PREVIOUS
# record's header -- and fired for a reason that has nothing to do with the
# mutation.  Its ABORT is not a detection, and E1c (the same edit with the
# assert disabled) SURVIVING says the value oracle sees nothing either.
#
# E1b makes the same behavioural change -- `se_rdy` set on every captured K
# beat -- while leaving the assert's guard exactly where it was.  This is
# the row that actually tests whether arming more than once per record is
# visible to anything.
D=$(mutate_rtl E1b rtl/attn_block.vhd \
  "              if (SWEEP_PIPE and pk_cnt = 0) or ((not SWEEP_PIPE) and rbi = 0)
              then
                se_rdy <= '1';" \
  "              se_rdy <= '1';
              if (SWEEP_PIPE and pk_cnt = 0) or ((not SWEEP_PIPE) and rbi = 0)
              then
                se_rdy <= '1';")
run_case E1b_on  "E1b se_rdy armed on every K beat, assert guard intact, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E1b_off "E1b same edit,                                         SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- E2: the idle guard dropped from the arm ----------------------------
# `all_zero(sq_busy)` is what makes the hand-over safe without reading the
# phase.  A score unit takes a header only in S_IDLE, so an arm that fires
# while one is busy raises `sq_hdrv` into a unit that cannot answer.
D=$(mutate_rtl E2 rtl/attn_block.vhd \
  "          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy) then" \
  "          elsif se_rdy = '1' and se_sent = '0' then")
run_case E2_on  "E2 arm not gated on the score units being idle, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E2_off "E2 same edit,                                   SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- E3: se_sent never cleared, so P_HDR skips for ever -----------------
D=$(mutate_rtl E3 rtl/attn_block.vhd \
  "            if SCORE_EARLY and se_sent = '1' then
              se_sent <= '0';" \
  "            if SCORE_EARLY and se_sent = '1' then")
run_case E3_on  "E3 se_sent never cleared at P_HDR, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E3_off "E3 same edit,                      SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- E4: P_HDR's fallback removed ---------------------------------------
# The fallback is what serves the BYPASS position, which reads no record and
# therefore never arms the early hand-over.  Removing it is the mutant for
# the claim "the fallback is not dead code".
D=$(mutate_rtl E4 rtl/attn_block.vhd \
  "            if SCORE_EARLY and se_sent = '1' then
              se_sent <= '0';
              blk <= 0;
              ph <= P_SCORE;
            else" \
  "            if SCORE_EARLY then
              se_sent <= '0';
              blk <= 0;
              ph <= P_SCORE;
            else")
run_case E4_on  "E4 P_HDR always skips, bypass gets no header, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E4_off "E4 same edit,                                 SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- E5: the disjointness gate removed ----------------------------------
# `ph /= P_HDR` is what keeps the arm and P_HDR from both driving `sq_hdrv`
# in one delta, where the later assignment wins silently.  This project has
# recorded that exact shape once already at the `vhdr` capture.
D=$(mutate_rtl E5 rtl/attn_block.vhd \
  "        if SCORE_EARLY and ph /= P_HDR then" \
  "        if SCORE_EARLY then")
run_case E5_on  "E5 arm and P_HDR both drive sq_hdrv, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case E5_off "E5 same edit,                        SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- H0: the header is right ONLY on beat 0 -----------------------------
# rtl/attn_kv_axi.vhd replays the record header with every beat.  This
# mutant breaks that for beats 1..NBLK-1 and leaves beat 0 correct, which is
# the direction in which SCORE_EARLY's VALUES stay right and only the new
# assert can see anything.
HMUT_OLD="            q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);"
D=$(mutate_rtl H0 rtl/attn_kv_axi.vhd "$HMUT_OLD" \
  "            if s = 0 then
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0)
                          xor std_logic_vector(resize(q_blk(s), NBLK*EXP_W));
            else
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);
            end if;")
run_case H0_on  "H0 kr_hdr right only on beat 0, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case H0_off "H0 same edit,                   SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- H0c: THE ATTRIBUTION CONTROL FOR THE NEW ASSERT ---------------------
D=$(mutate_rtl H0c rtl/attn_kv_axi.vhd "$HMUT_OLD" \
  "            if s = 0 then
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0)
                          xor std_logic_vector(resize(q_blk(s), NBLK*EXP_W));
            else
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);
            end if;")
if [ -n "$D" ]; then
  D2=$(mutate_rtl H0c_ab rtl/attn_block.vhd "$ASSERT_OLD" "$ASSERT_NEW")
  cp "$D2"/attn_block.vhd "$D"/ 2>/dev/null
fi
run_case H0c_on "H0c H0 with the NEW ASSERT DISABLED, SCORE_EARLY=true" "$D" -gSCORE_EARLY=true

# --- H7: the header is right ONLY on the LAST beat ----------------------
# The opposite direction.  SCORE_EARLY reads beat 0 and is therefore WRONG,
# and the old path reads the last beat and is right -- so this row says
# whether the value oracle can see a header taken from the wrong beat at all.
D=$(mutate_rtl H7 rtl/attn_kv_axi.vhd "$HMUT_OLD" \
  "            if s = 0 then
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0)
                          xor std_logic_vector(resize(
                                to_unsigned(NBLK-1, NBLK*EXP_W)
                                - resize(q_blk(s), NBLK*EXP_W),
                                NBLK*EXP_W));
            else
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);
            end if;")
run_case H7_on  "H7 kr_hdr right only on the LAST beat, SCORE_EARLY=true"  "$D" -gSCORE_EARLY=true
run_case H7_off "H7 same edit,                          SCORE_EARLY=false" "$D" -gSCORE_EARLY=false

# --- H7c: the same, with the new assert disabled ------------------------
D=$(mutate_rtl H7c rtl/attn_kv_axi.vhd "$HMUT_OLD" \
  "            if s = 0 then
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0)
                          xor std_logic_vector(resize(
                                to_unsigned(NBLK-1, NBLK*EXP_W)
                                - resize(q_blk(s), NBLK*EXP_W),
                                NBLK*EXP_W));
            else
              q_hdr(s) <= hdr_r(hit_slot)(NBLK*EXP_W-1 downto 0);
            end if;")
if [ -n "$D" ]; then
  D2=$(mutate_rtl H7c_ab rtl/attn_block.vhd "$ASSERT_OLD" "$ASSERT_NEW")
  cp "$D2"/attn_block.vhd "$D"/ 2>/dev/null
fi
run_case H7c_on "H7c H7 with the NEW ASSERT DISABLED, SCORE_EARLY=true" "$D" -gSCORE_EARLY=true

# --- E6: EXPECTED NOT TO BITE, and kept for that reason -----------------
# The arm waits one extra cycle before raising sq_hdrv.  Same header, same
# units, same order, later by one cycle.  A value oracle cannot see a pure
# schedule change and must not be credited with seeing it; the guard for
# this class is sim/tb_csweep_rate.vhd's SLOPE_MAX_X100 ceiling.
D=$(mutate_rtl E6 rtl/attn_block.vhd \
  "          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy) then
            sq_hdrv <= '1';" \
  "          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy)
                and ph /= P_RECK then
            sq_hdrv <= '1';")
run_case E6_on  "E6 arm delayed past P_RECK (INTENDED as schedule-only)" "$D" -gSCORE_EARLY=true

# --- E7: THE INERT ROW E6 FAILED TO BE ----------------------------------
# E6 was WRITTEN as the honest non-biting row -- a pure schedule change that
# a value oracle cannot see -- and it is not one.  Gating the arm on
# `ph /= P_RECK` does not delay the hand-over, it MOVES it: the arm then
# fires at the next moment the score units are idle, which is P_EPW of the
# SAME position, and `khdr` at that instant belongs to the position just
# finished.  So E6 hands the next position the previous position's header
# and is a functional mutant wearing a schedule mutant's description.
#
# E7 is the row E6 was meant to be.  `rbv(2) = '0'` holds the arm off for
# the cycles on which a capture is landing, so the hand-over happens about
# seven cycles later, still inside P_RECK, with the same header, the same
# units and the same order.  If the oracle sees this, something is wrong
# with the oracle; if it does not, that is the resolution floor and the
# guard for the class is sim/tb_csweep_rate.vhd's SLOPE_MAX_X100.
D=$(mutate_rtl E7 rtl/attn_block.vhd \
  "          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy) then
            sq_hdrv <= '1';" \
  "          elsif se_rdy = '1' and se_sent = '0' and all_zero(sq_busy)
                and rbv(2) = '0' then
            sq_hdrv <= '1';")
run_case E7_on  "E7 arm held off while a capture lands (EXPECT SURVIVE)" "$D" -gSCORE_EARLY=true

echo "=========================================================================="
printf ' TOTAL %d   KILLED %d   SURVIVED %d   ABORT %d   BADMUT %d\n' \
       "$NTOT" "$NKILL" "$NSURV" "$NABORT" "$NBAD"
echo " Per-row verdicts:"
for k in Z0 A_on A_off E1_on E1_off E1c_on E1b_on E1b_off E2_on E2_off \
         E3_on E3_off \
         E4_on E4_off E5_on E5_off H0_on H0_off H0c_on H7_on H7_off \
         H7c_on E6_on E7_on; do
  printf '   %-8s %s\n' "$k" "${VERD[$k]:-NOTRUN}"
done
echo "=========================================================================="
echo " HOW TO READ IT.  There is no single expected table here, because two"
echo " of the rows exist to MEASURE something rather than to confirm it:"
echo "   A_on A_off                the anchors; anything but PASS invalidates"
echo "                             every other row in the run"
echo "   E1..E5 _on                the new path, seen by the value oracle"
echo "   E1..E5 _off               attribution: the kill must belong to"
echo "                             SCORE_EARLY and not to an older property"
echo "   H0_on                     the new assert should fire"
echo "   H0c_on                    if it SURVIVES, the assert is the ONLY"
echo "                             detector of a mid-record header change in"
echo "                             the direction that leaves values right"
echo "   H0_off                    must KILL, or H0 is an inert mutant and"
echo "                             H0c proves nothing"
echo "   H7_on / H7c_on            the opposite direction: if H7c KILLS, the"
echo "                             assert is a better-located DIAGNOSTIC and"
echo "                             NOT a new detection for that direction"
echo "   H7_off                    must SURVIVE (the old path reads the beat"
echo "                             that is still correct)"
echo "   E6_on                     EXPECTED to survive.  A pure schedule"
echo "                             change is invisible to a value oracle by"
echo "                             construction; the ceiling in"
echo "                             sim/tb_csweep_rate.vhd is its guard."
echo "=========================================================================="

# THE HARNESS'S OWN VERDICT, and Z0 is half of it.  A run in which Z0 did not
# reach BADMUT has not shown that this script can tell an unapplied mutation
# from an inert one, and every SURVIVED it printed is worth less than it looks.
if [ "${Z0SEEN:-0}" -ne 1 ]; then
  echo "Z0 SELF-TEETH DID NOT FIRE: this harness cannot distinguish an anchor"
  echo "  that matched nothing from a mutation the checks tolerate.  Every"
  echo "  SURVIVED above is unverified."
  exit 1
fi
if [ "${NBAD:-0}" -ne 0 ]; then
  echo "$NBAD row(s) BADMUT: their anchor text has drifted under the RTL and"
  echo "  they tested nothing.  Fix the anchors before reading this table."
  exit 1
fi
