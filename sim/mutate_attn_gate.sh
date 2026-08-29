#!/usr/bin/env bash
# Mutation test for rtl/attn_gate.vhd.  Same discipline as
# sim/mutate_attn_recip.sh and sim/mutate_attn_softmax.sh: every mutation is
# well-formed VHDL and in bounds, so a KILL is the checker noticing and not the
# language noticing, and a SURVIVOR is investigated by READING the code rather
# than assumed to be equivalent.
#
# Every mutation below is of the ARCHITECTURE BODY.  A mutation of a GENERIC
# DEFAULT tests nothing when the testbench's generic map overrides it, and
# tb_attn_gate passes N, O_W, R_W, P_W, G_W, Q, GQ, T_W, Y_W, SIG_N and
# LSH_CLAMP explicitly.  (attn_kv_quant's M5 was first written that way and
# "survived" while being identical to the original.)
#
# Usage:  bash sim/mutate_attn_gate.sh
# Env:    SCRATCH=<dir>   VECS=<vector file>   NCASE=<n>   NELEM=<n>
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
SRC=rtl/attn_gate.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
VECS="${VECS:-$SCRATCH/attn_gate_vec.txt}"
NCASE="${NCASE:-35}"
NELEM="${NELEM:-64}"
mkdir -p "$SCRATCH"

if [ ! -f "$VECS" ]; then
  cc -O2 -w -o "$SCRATCH/attn_gate_vec" ref/attn_gate_vec.c -lm -I ref || exit 2
  ( cd "$(dirname "$VECS")" && "$SCRATCH/attn_gate_vec" \
      "$(basename "$VECS")" "$NCASE" "$NELEM" ) || exit 2
fi

# Three configurations, and the third one's Y_GAP is 20 for a MEASURED reason:
# the pipeline is 17 stages deep, so a consumer lag shorter than that never
# blocks the output for long enough to distinguish a DUT that freezes the
# pipeline from one that lets it run underneath a held valid.  A hold test
# whose ack is prompter than the thing being held has tested nothing -- the
# attn_softmax note (M6 survives at lag 3, killed at 9) and attn_kv_quant's M6
# being an equivalent mutant at M_GAP = 0 are the same shape.
#
# Configuration B removes every gap.  It is kept because the attn_softmax and
# attn_recip runs both showed the DEGENERATE configuration is NOT strictly
# weaker: it is the only one that catches an explicit `done_r` clear inside the
# ack branch, which the lagged ones miss entirely.
cfg_name() { case "$1" in
  A) echo "shipped: x gap 2, y gap 5, done ack lag 4";;
  B) echo "DEGENERATE: no gaps anywhere, every ready tied high";;
  C) echo "slow consumer: x gap 1, y gap 20 (> the 17-stage pipeline), ack 12";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gX_GAP=2 -gY_GAP=5 -gACK_LAG=4";;
  B) echo "-gX_GAP=0 -gY_GAP=0 -gACK_LAG=0";;
  C) echo "-gX_GAP=1 -gY_GAP=20 -gACK_LAG=12";;
esac; }
CFGS="A B C"

# --stop-time is 20ms, not the 900ms the earlier scripts in this directory use.
# The longest LEGITIMATE run here is 491 us (configuration C), so 20 ms is a
# 40x margin -- and a mutation that HANGS runs to the stop time, so 900 ms
# costs ~90 million simulated cycles for every hung run.  MEASURED: at 900 ms
# one hung configuration of this 17-stage DUT ran for over 25 minutes of wall
# time and had to be killed.  A stop time far above the longest real run buys
# nothing and is paid for by every hang.

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/attn_gate.vhd" "$old" "$new" <<'PY'
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
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/attn_gate.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_attn_gate.vhd \
       >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_attn_gate \
         -gNCASE="$NCASE" -gN="$NELEM" -gVECS="$VECS" $(cfg_args "$c") \
         --max-stack-alloc=0 --stop-time=20ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_attn_gate "$rcv")
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
      grep -E "report error" "$dir/run_$c.log" | head -1 \
        | sed 's/^/        /' | cut -c1-180
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

echo "====================== mutations of attn_gate ======================"
echo "golden: $VECS   heads: $NCASE   elements: $NELEM"

# ---- site 6b, the reciprocal-multiply --------------------------------------
# ---- THE CONTROL, run BEFORE any mutation ---------------------------------
# A MUTATION TABLE READ AGAINST A CONFIGURATION THAT FAILS ON THE CLEAN DESIGN
# MEASURES NOTHING.  Every row in such a column is a "kill" the mutation did
# not earn, and a mutation whose only killer is that column has not been shown
# to be visible to the checker at all.  sim/mutate_seq_tbl_shape.sh has always
# run a control; the multi-config harnesses did not.
#
# MEASURED 2026-08-29, and this is why the row exists: sim/mutate_attn_emit.sh
# config B (-gM_GAP=0 -gACK_LAG=0) WEDGES ON THE UNMUTATED DESIGN -- 20 ms of
# simulated time, not one line of output, not even the heartbeat.  Under the
# old two-way judging that silence scored as a KILL on all 22 rows, and two of
# them had no other evidence.
#
# The control goes through the SAME mutate() path as every other row, with the
# substitution deliberately an identity, so it exercises the same analyze, the
# same generics and the same classifier rather than a hand-rolled copy of them.
# It is counted in the totals, and it is the one row where SURVIVED is the
# right answer: the clean design survives because there is nothing wrong with
# it.  Any config listed as aborted or killed here invalidates that config's
# column in everything below.
mutate CTL "CONTROL: the UNMUTATED design.  Every config must say SURVIVED" \
"entity attn_gate is" \
"entity attn_gate is"

mutate M1 "site 6b shifts p instead of p+1" \
"            tsh   <= resize(p_l, SHW) + to_unsigned(1, SHW);" \
"            tsh   <= resize(p_l, SHW);"

mutate M2 "site 6b FLOORS: the round bias is dropped" \
"            tbias <= shift_left(to_signed(1, PR_W), to_integer(tsh) - 1);" \
"            tbias <= to_signed(0, PR_W);"

mutate M3 "the branch decision includes sh = 0 in the LEFT branch" \
"            if shv < 0 then
              is_left <= '1';" \
"            if shv <= 0 then
              is_left <= '1';"

mutate M4 "the right-shift clamp is one lower than G_W" \
"  constant RSH_CLAMP : integer := G_W;" \
"  constant RSH_CLAMP : integer := G_W - 1;"

mutate M5 "the left-shift clamp is lowered from LSH_CLAMP to LSH_CLAMP-1" \
"              if sv > LSH_CLAMP then sv := LSH_CLAMP; end if;" \
"              if sv > LSH_CLAMP-1 then sv := LSH_CLAMP-1; end if;"

# ---- the sigmoid cone -------------------------------------------------------
mutate M6 "the cone offset is narrowed with resize instead of sliced (THE TRAP)" \
"            off_v  := s6_z + OFF_MID;
            s7_off <= unsigned(off_v(OFF_W-1 downto 0));" \
"            off_v  := s6_z + OFF_MID;
            s7_off <= unsigned(resize(off_v, OFF_W));"

mutate M7 "the cone interpolation ROUNDS where it must floor" \
"            s12_int <= s11_l + resize(s11_prd(DLT_W+FRAC_W-1 downto Q), ROM_W);" \
"            s12_int <= s11_l + resize(shift_right(s11_prd
                         + to_unsigned(2**(Q-1), DLT_W+FRAC_W), Q), ROM_W);"

mutate M8 "the ROM index is taken from the LOW bits of the offset" \
"            s8_idx  <= s7_off(GRID_SH+IDX_W-1 downto GRID_SH);" \
"            s8_idx  <= s7_off(IDX_W-1 downto 0);"

mutate M9 "the interpolation is dropped, nearest lower entry only" \
"            s8_frac <= s7_off(GRID_SH-1 downto 0)
                       & to_unsigned(0, Q - GRID_SH);" \
"            s8_frac <= to_unsigned(0, Q);"

mutate M10 "the u16 clamp is 2^GQ, not 2^GQ - 1" \
"  constant G15_MAX : integer := 2**GQ - 1;              -- 32767, the pinned top" \
"  constant G15_MAX : integer := 2**GQ;                  -- 32768"

mutate M11 "the low domain compare is < instead of <=" \
"            if s5_z <= Z_LO then s6_lo <= '1'; else s6_lo <= '0'; end if;" \
"            if s5_z <  Z_LO then s6_lo <= '1'; else s6_lo <= '0'; end if;"

mutate M12 "the high domain compare is > instead of >=" \
"            if s5_z >= Z_HI then s6_hi <= '1'; else s6_hi <= '0'; end if;" \
"            if s5_z >  Z_HI then s6_hi <= '1'; else s6_hi <= '0'; end if;"

mutate M13 "the table delta is one bit narrow" \
"            s10_dlt  <= resize(s9_h - s9_l, DLT_W);" \
"            s10_dlt  <= resize(s9_h - s9_l, DLT_W-1) & '0';"

mutate M14 "the cone's Q30 -> Q15 round bias is dropped" \
"  constant CONE_BIAS : unsigned(ROM_W downto 0)
    := to_unsigned(2**(CONE_SH-1), ROM_W+1);" \
"  constant CONE_BIAS : unsigned(ROM_W downto 0)
    := to_unsigned(0, ROM_W+1);"

# ---- site 6e ----------------------------------------------------------------
mutate M15 "site 6e shifts GQ-1 instead of GQ" \
"            yv := shift_right(s16_ys, GQ);" \
"            yv := shift_right(s16_ys, GQ-1);"

mutate M16 "site 6e's round bias is dropped" \
"            s16_ys  <= s15_yp + to_signed(2**(GQ-1), YP_W);" \
"            s16_ys  <= s15_yp;"

# ---- the interface contract, RULE 1, RULE 2 and the ordering rule -----------
mutate M17 "the reciprocal is read LIVE instead of from its latched copy (RULE 2)" \
"            s2_pr <= s1_o * signed('0' & r_l);" \
"            s2_pr <= s1_o * signed('0' & r_in);"

mutate M18 "the gate exponent is latched one state LATE (the gdn_conv shape)" \
"          when S_CFG1 =>
            shv   <= resize(qge_l, EXP_W+2) - to_signed(Q, EXP_W+2);" \
"          when S_CFG1 =>
            qge_l <= qg_exp;
            shv   <= resize(qg_exp, EXP_W+2) - to_signed(Q, EXP_W+2);"

mutate M19 "cfg_taken is published after the head instead of at the latch" \
"              cfg_tk <= '1';          -- RULE 2: the instant, made observable" \
"              cfg_tk <= '0';"

mutate M20 "done reverts to a bare one-cycle pulse, done_ack ignored (RULE 1)" \
"          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then" \
"          when S_DONE =>
            done_r <= '1';
            if true then"

mutate M21 "an explicit done_r clear inside the ack branch (the gdn_head_emit shape)" \
"            if done_ack = '1' then" \
"            if done_ack = '1' then
              done_r <= '0';"

mutate M22 "done is reached before the pipeline has DRAINED" \
"            if pipe_e = '1' then
              state <= S_DONE;
            end if;" \
"            state <= S_DONE;"

mutate M23 "the pipeline advances under a blocked output (elements are lost)" \
"  adv <= '1' when (v(DEPTH) = '0' or y_ready = '1') else '0';" \
"  adv <= '1';"

mutate M24 "x_ready ignores the stall, so elements are taken with nowhere to put them" \
"  x_rdy <= '1' when (state = S_RUN and n_in < N and adv = '1') else '0';" \
"  x_rdy <= '1' when (state = S_RUN and n_in < N) else '0';"

mutate M25 "site 6b's s24 saturate removed, so a violated bound WRAPS" \
"            t_p(5) <= sat_t(tv);
            if tv /= resize(sat_t(tv), PR_W) then
              ovr_r <= '1';   -- unreachable under |o| <= 127*s; a width guard
            end if;" \
"            t_p(5) <= resize(tv, T_W);"

mutate M26 "site 6c's sat32 removed, so a large gate argument WRAPS" \
"            if zsel > resize(Z_MAX, LS_W) then
              s5_z   <= Z_MAX; zsat_r <= '1';
            elsif zsel < resize(Z_MIN, LS_W) then
              s5_z   <= Z_MIN; zsat_r <= '1';
            else
              s5_z <= resize(zsel, Z_W);
            end if;" \
"            s5_z <= resize(zsel(Z_W-1 downto 0), Z_W);"

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
