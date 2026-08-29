#!/usr/bin/env bash
# Mutation test for rtl/seq_opdec.vhd.  Same discipline as the two sibling
# scripts: every mutation is well-formed VHDL and in-bounds, so a kill is the
# checker noticing and not the language noticing, and a survivor is
# INVESTIGATED BY READING THE CODE rather than assumed to be equivalent.
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
SRC=rtl/seq_opdec.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

cfg_name() { case "$1" in
  A) echo "prefetch far ahead, y_exp valid one cycle";;
  B) echo "units instant";;
  C) echo "done is a one-cycle pulse";;
  D) echo "dense writes, y_exp valid 3 cycles";;
  E) echo "rogue exponent write into a HELD region (XW_AT=8)";;
  F) echo "src2 names a region the opcode does not read (SRC2_BAD_AT=200)";;
  G) echo "REL_NAIVE, must fail ERR_LOCK at step 2";;
  H) echo "write strobes that outlive their job (WR_TAIL=2)";;
  I) echo "QKV offset not a segment boundary (OFF_SEG_AT=2)";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gURAM_LAT=1 -gJOB_LAT=40";;
  B) echo "-gJOB_LAT=0 -gLAT_SKEW=0";;
  C) echo "-gDONE_STYLE=1";;
  D) echo "-gEXP_DECAY=3 -gWR_N=8 -gWR_GAP=0";;
  E) echo "-gXW_AT=8";;
  F) echo "-gSRC2_BAD_AT=200";;
  G) echo "-gREL_NAIVE=true";;
  H) echo "-gWR_TAIL=2";;
  I) echo "-gOFF_SEG_AT=2";;
esac; }
CFGS="A B C D E F G H I"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_opdec.vhd" "$old" "$new" <<'PY'
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
  for f in util_pkg model_cfg_pkg seq_desc_fetch seq_region_lock; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_opdec.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_opdec.vhd >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_opdec \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_seq_opdec "$rcv")
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

echo "====================== mutations of seq_opdec ======================"

# ---- class (a): the check and the commit must see the SAME descriptor ----
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
"entity seq_opdec is" \
"entity seq_opdec is"

mutate O1 "the commit reads the LIVE chk_* port instead of the latch (a1)" \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT
                else c_prod when chk_req = '"'"'1'"'"' else l_prod;
  iss_dst    <= to_unsigned(HOST_REG, 8)         when tstate = T_REQ or tstate = T_CMT
                else c_dst  when chk_req = '"'"'1'"'"' else l_dst;
  iss_seg    <= "00"                             when tstate = T_REQ or tstate = T_CMT
                else c_seg  when chk_req = '"'"'1'"'"' else l_seg;
  iss_off    <= to_unsigned(0, ADDR_W)           when tstate = T_REQ or tstate = T_CMT
                else c_off  when chk_req = '"'"'1'"'"' else l_off;
  iss_n_rows <= to_unsigned(HOST_ROWS, ADDR_W)   when tstate = T_REQ or tstate = T_CMT
                else c_rows when chk_req = '"'"'1'"'"' else l_rows;
  iss_cons   <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_cons when chk_req = '"'"'1'"'"' else l_cons;
  iss_rel    <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_rel  when chk_req = '"'"'1'"'"' else l_rel;' \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT
                else c_prod;
  iss_dst    <= to_unsigned(HOST_REG, 8)         when tstate = T_REQ or tstate = T_CMT
                else c_dst;
  iss_seg    <= "00"                             when tstate = T_REQ or tstate = T_CMT
                else c_seg;
  iss_off    <= to_unsigned(0, ADDR_W)           when tstate = T_REQ or tstate = T_CMT
                else c_off;
  iss_n_rows <= to_unsigned(HOST_ROWS, ADDR_W)   when tstate = T_REQ or tstate = T_CMT
                else c_rows;
  iss_cons   <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_cons;
  iss_rel    <= (NREG-1 downto 0 => '"'"'0'"'"')         when tstate = T_REQ or tstate = T_CMT
                else c_rel;'

mutate O2 "the produced exponent is captured at job_cmp, not at first done (a3)" \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and u_done(x_unit) = '"'"'1'"'"' then' \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and job_cmp = '"'"'1'"'"' then'

mutate O3 "the captured exponent is re-latched every cycle done stays high" \
'        if x_armed = '"'"'1'"'"' and x_taken = '"'"'0'"'"' and u_done(x_unit) = '"'"'1'"'"' then' \
'        if x_armed = '"'"'1'"'"' and u_done(x_unit) = '"'"'1'"'"' then'

# ---- the decode itself ----
mutate O4 "the consume mask forgets the opcode's implied regions (B's four, C's three)" \
'    cons := opc_mask(chk_opcode);' \
'    cons := (others => '"'"'0'"'"');'

mutate O5 "the release mask is dropped: nothing is ever returned to FREE" \
'      c_rel <= rel_mask;' \
'      c_rel <= (others => '"'"'0'"'"');'

mutate O6 "n_rows is passed through even when the step has no destination region" \
'    else
      c_rows <= (others => '"'"'0'"'"');
    end if;' \
'    else
      c_rows <= resize(chk_n_rows(ADDR_W-1 downto 0), ADDR_W);
    end if;'

mutate O7 "the exponent segment is always 0: q, k and v share one capture slot" \
'      if    chk_dst_off = 0                                       then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF1, 32)              then seg := "01";
      elsif chk_dst_off = to_unsigned(MSEG_OFF2, 32)              then seg := "10";
      else' \
'      if    chk_dst_off = 0                                       then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF1, 32)              then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF2, 32)              then seg := "00";
      else'

mutate O8 "the src2 consistency check is removed" \
'            elsif extra(reg_idx(job_src2)) = '"'"'0'"'"' then' \
'            elsif false then'

# ---- token start ----
mutate O9 "the host-written X region is never published (the fourth finding, undone)" \
'  iss_prod   <= '"'"'1'"'"'                              when tstate = T_REQ or tstate = T_CMT' \
'  iss_prod   <= '"'"'0'"'"'                              when tstate = T_REQ or tstate = T_CMT'

mutate O10 "the locks are not reset between tokens" \
'  lock_rst <= '"'"'1'"'"' when rst = '"'"'1'"'"' or tstate = T_RST else '"'"'0'"'"';' \
'  lock_rst <= rst;'

mutate O11 "a mid-job lock violation is not forced into the next check (b2)" \
'                       and (c_bad = '"'"'1'"'"' or iss_ok = '"'"'0'"'"' or s_err = '"'"'1'"'"')' \
'                       and (c_bad = '"'"'1'"'"' or iss_ok = '"'"'0'"'"')'

echo
echo "scratch dir with every mutant and every log: $SCRATCH"

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
