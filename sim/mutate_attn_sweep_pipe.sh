#!/usr/bin/env bash
# Mutation test for rtl/attn_block.vhd's SWEEP_PIPE, the record prefetch.
#
# WHAT IS UNDER TEST, AND WHY IT NEEDS ITS OWN SCRIPT.
# SWEEP_PIPE moves WHEN a KV record beat is issued and nothing else.  It does
# not change a beat, an order within a record, an address or any arithmetic,
# so the whole claim is "the values are identical with it on and with it off".
# A claim of that shape is only worth what its ORACLE is worth, so every row
# below is judged by sim/tb_attn_kv_seam.vhd against ref/attn_block_seq_vec.c:
# Q1 the output values bit for bit over a multi-token sequence, Q2 the record
# image in memory at C spec 2.2's address, Q3 the beat that arrives against
# the beat that was asked for, Q4 the handshake.
#
# EVERY ROW IS RUN TWICE, and the second run is the point.
#
#   ON   the mutation with -gSWEEP_PIPE=true.   It must KILL.
#   OFF  the SAME mutation with -gSWEEP_PIPE=false.  For a mutation of the
#        new path it must SURVIVE, and that is the ATTRIBUTION CONTROL: it
#        says the kill belongs to SWEEP_PIPE and not to some older property
#        that the edit happened to trip.  For a mutation of the SHARED
#        capture path it must kill in both, which says the refactor did not
#        quietly retire a check that already existed.
#
# A row that does NOT bite is reported under its own name and kept.  It
# measures the oracle's resolution floor, which is the most useful line here:
# a pure timing change is invisible to a value oracle BY CONSTRUCTION, and the
# guard for it is sim/tb_csweep_rate.vhd's slope ceiling, not this script.
#
# Usage:  bash sim/mutate_attn_sweep_pipe.sh
# Env:    SCRATCH=<dir>
set -uo pipefail

# SELF-ISOLATION.  bash reads a script by BYTE OFFSET as it runs, so editing
# this file while an instance of it is running corrupts that run silently.
# Same guard, same reasons, as sim/mutate_attn_kv_seam.sh.
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
      | grep -aE "MISMATCH|Q1 --|Q2 --|Q3 --|Q4 --|Q5 --|sweep read pos|kr_en was|vr_en was|same cycle|seam is stalled" \
      | head -1 | sed 's/^/        /' | cut -c1-170
  else
    NABORT=$((NABORT+1)); echo "$tag  ABORT (${v#ABORT:})  -- $desc"
    echo "        the run DIED before the checker reached a verdict, so the"
    echo "        checker was NOT shown to catch this.  Not counted as a kill."
    tail -2 "$dir/run/run.log" | sed 's/^/        /' | cut -c1-170
  fi
}

# mutate_rtl <tag> <file> <old> <new>  [<old2> <new2>]
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

echo "=========================================================================="
echo " SWEEP_PIPE mutation test -- oracle sim/tb_attn_kv_seam vs"
echo " ref/attn_block_seq_vec.c, every row run ON and OFF"
echo "=========================================================================="

# --- the two anchors, unmutated -----------------------------------------
run_case A_on  "ANCHOR: unmutated, SWEEP_PIPE=true  (must SURVIVE)" "" \
         -gSWEEP_PIPE=true
run_case A_off "ANCHOR: unmutated, SWEEP_PIPE=false (must SURVIVE)" "" \
         -gSWEEP_PIPE=false

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

# --- P1: the capture destination read from `ph` instead of the issue ----
# This is the mutant the `rbs` pipe exists for.  Under SWEEP_PIPE a V record
# is fetched while `ph` is in the score phase, so `ph` names krec for every V
# beat.  With SWEEP_PIPE off the two expressions are the same fact, which is
# exactly why the OFF row must survive.
D=$(mutate_rtl P1 rtl/attn_block.vhd \
  "  cap_v  <= rbs(2) when SWEEP_PIPE else
            '1'    when ph = P_RECV else
            '0';" \
  "  cap_v  <= '1' when ph = P_RECV else '0';")
run_case P1_on  "P1 capture destination from ph, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P1_off "P1 same edit,                  SWEEP_PIPE=false"  "$D" -gSWEEP_PIPE=false

# --- P2: the K request stops leading, so the prefetch re-reads THIS pos --
D=$(mutate_rtl P2 rtl/attn_block.vhd \
  "  kr_pos  <= (pos_i + 1) when (SWEEP_PIPE and pk_act = '1') else pos_i;" \
  "  kr_pos  <= pos_i;")
run_case P2_on  "P2 K request does not lead pos_i, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P2_off "P2 same edit,                     SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

# --- P3: the V capture index reversed inside the record -----------------
D=$(mutate_rtl P3 rtl/attn_block.vhd \
  "  cidx_v <= pv_cnt when SWEEP_PIPE else rbi;" \
  "  cidx_v <= (NBLK-1-pv_cnt) when SWEEP_PIPE else rbi;")
run_case P3_on  "P3 V blocks land reversed, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P3_off "P3 same edit,              SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

# --- P4: pv_got not cleared, so P_RECV accepts the PREVIOUS position's V -
D=$(mutate_rtl P4 rtl/attn_block.vhd \
  "                pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0; pv_got <= '0';" \
  "                pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0;")
run_case P4_on  "P4 stale pv_got accepted, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P4_off "P4 same edit,             SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

# --- P5: both streams armed at once.  The new assert must fire. ---------
D=$(mutate_rtl P5 rtl/attn_block.vhd \
  "                  pk_act <= '1'; pk_pend <= '1';
                  pk_en  <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0';" \
  "                  pk_act <= '1'; pk_pend <= '1';
                  pk_en  <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0';
                  pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0;")
run_case P5_on  "P5 K and V armed together, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P5_off "P5 same edit,              SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

# --- P5c: THE ATTRIBUTION CONTROL FOR P5.  Same mutant, assert removed. -
# If P5c also kills, the new assert was not what noticed and it is not worth
# its maintenance.  If P5c survives or aborts elsewhere, the assert is.
D=$(mutate_rtl P5c rtl/attn_block.vhd \
  "                  pk_act <= '1'; pk_pend <= '1';
                  pk_en  <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0';" \
  "                  pk_act <= '1'; pk_pend <= '1';
                  pk_en  <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_got <= '0';
                  pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0;" \
  "          assert not (pk_en = '1' and kr_rdy = '1'
                      and pv_en = '1' and vr_rdy = '1')" \
  "          assert true or not (pk_en = '1' and kr_rdy = '1'
                      and pv_en = '1' and vr_rdy = '1')")
run_case P5c_on "P5c P5 with the new assert DISABLED, SWEEP_PIPE=true" "$D" -gSWEEP_PIPE=true

# --- P6: the SHARED capture index, which both paths use -----------------
# Not a SWEEP_PIPE mutation at all.  It is here because the refactor replaced
# a literal `rbi` in the capture with `cidx_k`, and a refactor that quietly
# retired an existing check is the failure this row exists to exclude.  It
# must kill in BOTH modes.
D=$(mutate_rtl P6 rtl/attn_block.vhd \
  "  cidx_k <= pk_cnt when SWEEP_PIPE else rbi;" \
  "  cidx_k <= pk_cnt when SWEEP_PIPE else 0;")
run_case P6_on  "P6 shared K capture index pinned to 0, SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P6_off "P6 same edit,                          SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

# --- P7: EXPECTED NOT TO BITE, and kept for that reason -----------------
# The V prefetch is armed one state later (at P_SCORE entry instead of at
# P_RECK exit).  That is a pure SCHEDULE change: the same beats, the same
# order, the same records, issued later.  A value oracle cannot see it and
# must not be credited with seeing it.  The real guard for this class is the
# slope ceiling in sim/tb_csweep_rate.vhd, and this row is the measurement of
# that gap rather than a failure of this script.
D=$(mutate_rtl P7 rtl/attn_block.vhd \
  "                pv_en  <= '1'; pv_blk <= 0; pv_cnt <= 0; pv_got <= '0';
                ph <= P_HDR;" \
  "                pv_blk <= 0; pv_cnt <= 0; pv_got <= '0';
                ph <= P_HDR;" \
  "            if all_ones(sq_taken) then
              sq_hdrv <= '0';
              blk <= 0;
              ph <= P_SCORE;" \
  "            if all_ones(sq_taken) then
              sq_hdrv <= '0';
              blk <= 0;
              if SWEEP_PIPE then pv_en <= '1'; end if;
              ph <= P_SCORE;")
run_case P7_on  "P7 V prefetch armed one state later (EXPECT SURVIVE)" "$D" -gSWEEP_PIPE=true

# --- P8: the pk_pend guard removed -----------------------------------------
# THIS IS NOT A CONSTRUCTED MUTANT.  It is the state this change was actually
# in on 2026-09-20 when it was first run, and the new assert is what found
# it: `pk_en` falls on the LAST ISSUE while two captures are still in flight,
# so P_RECK re-armed the same fetch inside that window and the re-arm was
# still running when P_RECK consumed the original and armed V.  It is kept as
# a row because a defect that has happened is worth more than one invented.
D=$(mutate_rtl P8 rtl/attn_block.vhd \
  "              elsif pk_pend = '0' then
                pk_en <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_pend <= '1';" \
  "              elsif pk_en = '0' then
                pk_en <= '1'; pk_blk <= 0; pk_cnt <= 0; pk_pend <= '1';")
run_case P8_on  "P8 pk_pend guard removed (the REAL defect), SWEEP_PIPE=true"  "$D" -gSWEEP_PIPE=true
run_case P8_off "P8 same edit,                               SWEEP_PIPE=false" "$D" -gSWEEP_PIPE=false

echo "=========================================================================="
printf ' TOTAL %d   KILLED %d   SURVIVED %d   ABORT %d   BADMUT %d\n' \
       "$NTOT" "$NKILL" "$NSURV" "$NABORT" "$NBAD"
echo " Per-row verdicts:"
for k in Z0 A_on A_off P1_on P1_off P2_on P2_off P3_on P3_off P4_on P4_off \
         P5_on P5_off P5c_on P6_on P6_off P7_on P8_on P8_off; do
  printf '   %-8s %s\n' "$k" "${VERD[$k]:-NOTRUN}"
done
echo "=========================================================================="
echo " EXPECTED, and the run is only a result if it matches:"
echo "   A_on A_off              PASS   (the anchors)"
echo "   P1_on P2_on P3_on P4_on KILLED (the new path, seen by the oracle)"
echo "   P1_off P2_off P3_off P4_off PASS (attribution: the kill is SWEEP_PIPE's)"
echo "   P5_on                   KILLED (the new assert)"
echo "   P5_off                  PASS   (nothing armed, nothing to collide)"
echo "   P5c_on                  whatever it is -- if KILLED, an OLDER"
echo "                           property caught it and the assert is not"
echo "                           carrying its own weight"
echo "   P6_on P6_off            KILLED (the shared capture index, both modes)"
echo "   P8_on                   KILLED (the defect that actually happened)"
echo "   P8_off                  PASS   (attribution)"
echo "   P7_on                   PASS   (a pure schedule change; the value"
echo "                           oracle CANNOT see it, by construction)"
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
