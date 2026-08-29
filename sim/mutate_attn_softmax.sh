#!/usr/bin/env bash
# Mutation test for rtl/attn_softmax.vhd.  Same discipline as
# sim/mutate_seq_region_lock.sh: every mutation is well-formed VHDL and in
# bounds, so a KILL is the checker noticing and not the language noticing, and
# a SURVIVOR is investigated by reading the code rather than assumed to be
# equivalent.
#
# Two lessons already paid for elsewhere in this project are honoured here:
#
#   * A mutation of a GENERIC DEFAULT tests nothing when the testbench's
#     generic map overrides it.  tb_attn_softmax passes P_W, Q, ROM_N, E_W and
#     S_W explicitly, so every mutation below is of the ARCHITECTURE BODY or of
#     a constant declared inside it.  (attn_kv_quant's M5 was first written as
#     a VREF_INIT generic-default mutation and "survived" while being identical
#     to the original.)
#
#   * A run with no back-pressure does not test the back-pressure path.  Config
#     B ties both acks high, which is the degenerate configuration; two of the
#     mutations below are genuinely EQUIVALENT there and killed only in A and C.
#     Reading a survivor in B as a passing result would be the mistake.
#
# Usage:  bash sim/mutate_attn_softmax.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>
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
SRC=rtl/attn_softmax.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_softmax_vec.txt}"
NCASE="${NCASE:-44}"
NPOS="${NPOS:-24}"
mkdir -p "$SCRATCH"

# The golden must exist and must be the one the oracles passed on.
if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_softmax_vec" ref/attn_softmax_vec.c -lm || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_softmax_vec" \
      "$(basename "$VECS")" "$NCASE" "$NPOS" ) || exit 2
fi

# The rescale sequence is 5 states long, so a rescale ack lag BELOW 5 acks the
# pass before it would have fallen anyway and cannot distinguish a held
# rs_valid from a pulsed one -- M6 survives at lag 3 and is killed at 9.  A is
# therefore the configuration that exercises both holds; C is kept precisely to
# show that the short lag does NOT, which is the same shape as attn_kv_quant's
# M6 being an equivalent mutant at M_GAP = 0.
cfg_name() { case "$1" in
  A) echo "shipped: done ack lag 4, rescale ack lag 9 -- both holds exercised";;
  B) echo "DEGENERATE: both acks tied high, no back-pressure anywhere";;
  C) echo "short array pass: rescale ack lag 3, below the 5-state sequence";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gACK_LAG=4 -gRS_ACK_LAG=9";;
  B) echo "-gACK_LAG=0 -gRS_ACK_LAG=0";;
  C) echo "-gACK_LAG=4 -gRS_ACK_LAG=3";;
esac; }
CFGS="A B C"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_softmax.vhd" "$old" "$new" <<'PY'
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
  for f in fixed_luts_pkg fixed_pkg util_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_softmax.vhd" \
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
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_softmax.vhd \
       >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_softmax \
         -gNCASE="$NCASE" -gVECS="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=900ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_attn_softmax "$rcv" sim/hsk_chk.vhd)
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

echo "==================== mutations of attn_softmax ===================="
echo "golden: $VECS   cases: $NCASE"

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
"entity attn_softmax is" \
"entity attn_softmax is"

mutate M1 "the grid snap FLOORS instead of ceiling, so the maximum's own z is positive" \
"            ceil_v := resize(sc_h, MG_W) + to_signed(GRID_CNT - 1, MG_W);" \
"            ceil_v := resize(sc_h, MG_W);"

mutate M2 "the rise test is NOT strict, so a repeated maximum costs a rescale pass" \
"            elsif sc_ceil > m_g then      -- STRICT; see the header" \
"            elsif sc_ceil >= m_g then"

mutate M7 "the cone's Q30 to Q12 conversion floors instead of rounding half up" \
"          x9_sum <= resize(x8_int, ROM_W+1) + CONE_BIAS;" \
"          x9_sum <= resize(x8_int, ROM_W+1);"

mutate M8 "the offset is narrowed with resize -- THE DEFECT FOUND ON 2026-08-27" \
"          off_v  := x2_z + OFF_MID;
          x3_off <= unsigned(off_v(OFF_W-1 downto 0));" \
"          x3_off <= unsigned(resize(x2_z + OFF_MID, OFF_W));"

mutate M12 "the table-delta width is one bit narrow, so the top of the ROM truncates" \
"  constant DLT_W : integer := rom_delta_w;               -- 26" \
"  constant DLT_W : integer := rom_delta_w - 1;"

mutate M13 "frac clamped to 2^Q-1 at the top index instead of reaching 2^Q" \
"            x4_frac <= to_unsigned(2**Q, FRAC_W);" \
"            x4_frac <= to_unsigned(2**Q - 1, FRAC_W);"

mutate M14 "frac forced to 0 at the top index, so e_p tops out at EXP_ROM(255)" \
"            x4_frac <= to_unsigned(2**Q, FRAC_W);" \
"            x4_frac <= to_unsigned(0, FRAC_W);"

mutate M9 "k > ROM_N clamps the ROM INDEX rather than the FACTOR" \
"            if k_ok = '1' then
              f_r <= f_sum(CONE_SH+E_W-1 downto CONE_SH);
            else
              f_r <= (others => '0');
            end if;" \
"            f_r <= f_sum(CONE_SH+E_W-1 downto CONE_SH);"

mutate M10 "the first position is treated as an ordinary rise against m_g = 0" \
"            if first_r = '1' then" \
"            if (first_r = '1') and false then"

# ---- the concurrency contract ---------------------------------------------
mutate M3 "the DRAIN is removed, so s is rescaled with weights still in the cone" \
"          when S_DRAIN =>
            if inflight = 0 then
              state <= S_K;
            end if;" \
"          when S_DRAIN =>
            state <= S_K;"

mutate M11 "done is signalled before the cone has drained" \
"          when S_FIN =>
            if inflight = 0 then
              state <= S_DONE;
            end if;" \
"          when S_FIN =>
            state <= S_DONE;"

mutate M15 "the fold reads the cone output one cycle early" \
"        if ep_v_r = '1' then
          acc := resize(s_r, S_W+1) + resize(ep_r, S_W+1);" \
"        if x_v(CONE_ST) = '1' then
          acc := resize(s_r, S_W+1) + resize(ep_r, S_W+1);"

# ---- the interface contract, RULE 1 and RULE 2 ----------------------------
mutate M4 "the score is read LIVE instead of from its latched copy (RULE 2)" \
"            zv := resize(sc_h, Z_W) - resize(m_g, Z_W);" \
"            zv := resize(sc_q12, Z_W) - resize(m_g, Z_W);"

# M5 and M5b are the SAME class of defect written two ways, and they are killed
# by DIFFERENT configurations.  M5 is the gdn_head_emit anti-pattern the RTL
# comment warns about -- an explicit clear inside the ack branch is a LATER
# assignment that wins, which destroys the pulse outright when done_ack is tied
# high and does nothing at all when it is lagged.  M5b is a genuine one-cycle
# pulse.  Neither configuration alone catches both.
mutate M5 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate M5b "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then" \
"          when S_DONE =>
            done_r <= '1';
            if true then"

mutate M6 "the rescale pass is pulsed instead of held until the array acks (RULE 1)" \
"          when S_RS =>
            if rs_tk = '1' then
              state <= S_ZED;
            end if;" \
"          when S_RS =>
            rs_v_r <= '0';
            state  <= S_ZED;"

# ---- THE SAME DEFECT CLASS, WITHOUT THE HANG ------------------------------
# M5 above is the member of this class that HAPPENS TO DEADLOCK, and that is
# the only reason five harnesses noticed it at all.  H1 is the member that does
# NOT deadlock: `done` is raised, is held for as long as the consumer wants,
# and is then released by the next head's `start` instead of by the ack.  The
# ack has no effect on `done` whatsoever.  Every value this unit produces is still correct.
#
# MEASURED 2026-08-29 with the sim/hsk_chk.vhd instance REMOVED from
# sim/tb_attn_softmax.vhd and nothing else changed: H1 is
#     A=PASS  B=PASS  C=PASS
# a clean survivor of every configuration.  Polling for `done = '1'` cannot see
# it, because the poll is satisfied by the stale level left over from the
# previous layer, and no value check sees it because no value is wrong.  With
# the property it is KILLED in all three configurations, by clause 3, RELEASE.
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
mutate H1 "the ack has NO effect on done: it is released by the next layer's accept instead (the non-hanging sibling of M5)" \
"        if state /= S_DONE then
          done_r <= '0';
        end if;" \
"        if start = '1' then
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
