#!/usr/bin/env bash
# Mutation test for rtl/attn_recip.vhd.  Same discipline as
# sim/mutate_attn_softmax.sh and sim/mutate_seq_region_lock.sh: every mutation
# is well-formed VHDL and in bounds, so a KILL is the checker noticing and not
# the language noticing, and a SURVIVOR is investigated by reading the code
# rather than assumed to be equivalent.
#
# Every mutation below is of the ARCHITECTURE BODY.  A mutation of a GENERIC
# DEFAULT tests nothing when the testbench's generic map overrides it, and
# tb_attn_recip passes S_W, R_W, R_Q, NW and DW explicitly.  (attn_kv_quant's
# M5 was first written that way and "survived" while being identical to the
# original.)
#
# Usage:  bash sim/mutate_attn_recip.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>   NHEAD=<n>
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
SRC=rtl/attn_recip.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_recip_vec.txt}"
NCASE="${NCASE:-24}"
NHEAD="${NHEAD:-12}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_recip_vec" ref/attn_recip_vec.c -lm || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_recip_vec" \
      "$(basename "$VECS")" "$NCASE" "$NHEAD" ) || exit 2
fi

# The divide is 44 cycles and the pair is offered once per head, so a
# consumer-ready lag of 5 is long enough to distinguish a HELD r_valid from a
# pulsed one; config B removes both lags and is the degenerate case, kept
# because the attn_softmax run showed the degenerate configuration is not
# strictly weaker -- it is the only one that REACTS to an explicit `done_r` clear
# inside the ack branch.
#
# 2026-08-29: "REACTS", not "catches".  Until that date the reaction was a
# DEADLOCK, and a deadlock is the absence of a detection: nothing was ever
# learned about what the checker would have said.  sim/hsk_chk.vhd now states
# the done/done_ack contract as a property, so that row is a named checker
# kill -- and its non-hanging sibling H1, which NO configuration reacted to,
# is killed in all three.
cfg_name() { case "$1" in
  A) echo "shipped: ready lag 5, done ack lag 4";;
  B) echo "DEGENERATE: both prompt, no back-pressure anywhere";;
  C) echo "slow gate: ready lag 20, done ack lag 12";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gR_READY_LAG=5 -gACK_LAG=4";;
  B) echo "-gR_READY_LAG=0 -gACK_LAG=0";;
  C) echo "-gR_READY_LAG=20 -gACK_LAG=12";;
esac; }
CFGS="A B C"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_recip.vhd" "$old" "$new" <<'PY'
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
  for f in util_pkg divider_rs; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_recip.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  # sim/hsk_chk.vhd is PART OF THE CHECKER, not part of the design: it is
  # the done/done_ack contract as a property.  It has to be analysed before
  # the bench that instantiates it, and it has to be NAMED to
  # sim/mutverdict.py below, or a clause firing is classified
  # ABORT:DUTASSERT(hsk_chk.vhd) rather than KILLED.
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/hsk_chk.vhd \
       >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_recip.vhd \
       >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_recip \
         -gNCASE="$NCASE" -gNHEAD="$NHEAD" -gVECS="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=900ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_attn_recip "$rcv" sim/hsk_chk.vhd)
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
      # "report failure" as well as "report error": sim/hsk_chk.vhd's clauses
      # are severity failure, deliberately (see its header), so a handshake
      # kill prints no "report error" line at all and this used to show the
      # kill with an empty reason.
      grep -aE "report (error|failure)" "$dir/run_$c.log" | head -1 \
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

echo "===================== mutations of attn_recip ====================="
echo "golden: $VECS   layers: $NCASE   heads: $NHEAD"

# ---- the numeric contract -------------------------------------------------
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
"entity attn_recip is" \
"entity attn_recip is"

mutate N1 "p is one too large" \
"            p_r <= to_unsigned(msb_pos_u(s_l), PW);" \
"            p_r <= to_unsigned(msb_pos_u(s_l) + 1, PW);"

mutate N2 "the numerator's exponent drops R_Q by one" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q, sh_r'length);" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q-1, sh_r'length);"

mutate N3 "the numerator omits p, so the reciprocal is not normalised" \
"            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q, sh_r'length);" \
"            sh_r  <= to_unsigned(R_Q, sh_r'length);"

mutate N4 "msb_pos returns the LOWEST set bit rather than the highest" \
"    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;" \
"    for i in a'high downto a'low loop
      if a(i) = '1' then p := i; end if;
    end loop;"

mutate N5 "the numerator is built by shifting 2 rather than 1" \
"            num_r  <= shift_left(to_unsigned(1, NW), to_integer(sh_r));" \
"            num_r  <= shift_left(to_unsigned(2, NW), to_integer(sh_r));"

mutate N6 "the quotient is truncated to R_W instead of saturated" \
"            if qv > to_unsigned(2**R_W - 1, NW) then
              r_r   <= (others => '1');
              ovr_r <= '1';     -- unreachable; the reference's oracle 2 proves
            else                -- r <= 2^R_Q < 2^R_W.  A width guard.
              r_r <= resize(qv, R_W);
            end if;" \
"            r_r <= resize(qv, R_W);"

mutate N7 "the s = 0 trap is removed and the divider is asked for x/0" \
"            if s_l = 0 then" \
"            if false then"

# ---- the divider seam ------------------------------------------------------
mutate N8 "the divider's start is held for two cycles instead of one" \
"          when S_DIV =>
            div_st <= '0';" \
"          when S_DIV =>
            div_st <= '1';"

mutate N9 "the quotient is captured one cycle after done instead of at it" \
"            if div_done = '1' then
              quo_r <= unsigned(div_quo);
              state <= S_SAT;
            end if;" \
"            if div_busy = '0' and div_st = '0' then
              quo_r <= unsigned(div_quo);
              state <= S_SAT;
            end if;"

# ---- the interface contract, RULE 1 and RULE 2 ----------------------------
mutate N10 "the denominator is read LIVE instead of from its latched copy (RULE 2)" \
"  div_den <= std_logic_vector(resize(s_l, DW));" \
"  div_den <= std_logic_vector(resize(s_in, DW));"

mutate N11 "the msb scan reads the live port instead of the latched copy (RULE 2)" \
"            p_r <= to_unsigned(msb_pos_u(s_l), PW);" \
"            p_r <= to_unsigned(msb_pos_u(s_in), PW);"

mutate N12 "the pair is withdrawn without a ready (RULE 1)" \
"          when S_OUT =>
            if r_ready = '1' then
              r_v_r <= '0';" \
"          when S_OUT =>
            r_v_r <= '0';
            if r_ready = '1' then"

# NOTE on how NOT to write this one.  The obvious mutation -- asserting done_r
# in S_SAT -- is a NO-OP and survives everything, because the trailing
# `if state /= S_DONE then done_r <= '0'` at the bottom of the process is a
# LATER assignment and wins.  That is the same asymmetry the RULE 1 comment in
# the RTL describes from the other direction, and a survivor there would have
# been read as "the property is untested" when in fact the mutation was.  The
# version below leaves S_OUT for S_DONE without waiting for the ready, which the
# trailing clear cannot undo.
mutate N13 "done is reached before the last pair has been accepted" \
"          when S_OUT =>
            if r_ready = '1' then" \
"          when S_OUT =>
            if last_l = '1' then state <= S_DONE; end if;
            if r_ready = '1' then"

mutate N14 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate N15 "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then" \
"          when S_DONE =>
            done_r <= '1';
            if true then"

# ---- THE SAME DEFECT CLASS, WITHOUT THE HANG ------------------------------
# N14 above is the member of this class that HAPPENS TO DEADLOCK, and that is
# the only reason five harnesses noticed it at all.  H1 is the member that does
# NOT deadlock: `done` is raised, is held for as long as the consumer wants,
# and is then released by the next layer's first accepted denominator
# (s_taken) instead of by the ack.  The ack has no effect on `done` whatsoever.  Every value this unit produces is still correct.
#
# MEASURED 2026-08-29 with the sim/hsk_chk.vhd instance REMOVED from
# sim/tb_attn_recip.vhd and nothing else changed: H1 is
#     A=PASS  B=PASS  C=PASS
# a clean survivor of every configuration.  Polling for `done = '1'` cannot see
# it, because the poll is satisfied by the stale level left over from the
# previous layer, and no value check sees it because no value is wrong.  With
# the property it is KILLED in all three configurations -- here by clause 4,
# NO SPURIOUS DONE, because this unit's next layer starts soon enough after the
# ack that clause 3 does not reach its limit first.  The other four units are
# killed by clause 3, RELEASE.  Two clauses, one defect: that is the point of
# stating the contract rather than a symptom.
#
# The release signal is chosen per unit to be the one that SURVIVES: on
# attn_emit and attn_twiddle a clear at cfg_taken instead of at `start` lands
# one cycle later, leaves `done` still high inside the bench's ACK_LAG hold
# window, and is caught by the existing "done fell before done_ack" check in
# all three configurations.  That difference is a single cycle, and it is the
# whole distance between this class being visible and being invisible.
#
# This row is the reason sim/hsk_chk.vhd exists.  A harness whose only evidence
# for a defect class is that one member of it hangs has measured the member,
# not the class.
mutate H1 "the ack has NO effect on done: it is released by the next layer's accept instead (the non-hanging sibling of N14)" \
"        if state /= S_DONE then
          done_r <= '0';
        end if;" \
"        if s_tk = '1' then
          done_r <= '0';
        end if;"

echo "==================================================================="

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
