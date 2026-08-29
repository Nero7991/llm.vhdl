#!/usr/bin/env bash
# Mutation test for rtl/seq_region_lock.vhd.  Same discipline as
# sim/mutate_seq_desc_fetch.sh: every mutation is well-formed and in-bounds, so
# a kill is the checker noticing and not the language noticing, and a survivor
# is investigated by reading the code rather than assumed to be equivalent.
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
SRC=rtl/seq_region_lock.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

cfg_name() { case "$1" in
  A) echo "clean walk, writes fast, job slow";;
  B) echo "late writes after every completion (WR_TAIL=3)";;
  C) echo "rogue exponent write into a HELD region (XW_AT=8)";;
  D) echo "dst_offset off by one (BAD_OFF_AT=3)";;
  E) echo "consumes a region nobody produced (BAD_CONS_AT=100)";;
  F) echo "writes slow, job instant";;
  G) echo "row count overruns the region (BAD_ROWS_AT=3)";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gWR_N=6 -gWR_GAP=0 -gJOB_LAT=12";;
  B) echo "-gWR_TAIL=3 -gJOB_LAT=20";;
  C) echo "-gXW_AT=8";;
  D) echo "-gBAD_OFF_AT=3";;
  E) echo "-gBAD_CONS_AT=100";;
  F) echo "-gWR_N=3 -gWR_GAP=3 -gJOB_LAT=0";;
  G) echo "-gBAD_ROWS_AT=3";;
esac; }
CFGS="A B C D E F G"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_region_lock.vhd" "$old" "$new" <<'PY'
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
  for f in util_pkg model_cfg_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_region_lock.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_region_lock.vhd >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_region_lock \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_seq_region_lock "$rcv")
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
        | sed 's/^/        /' | cut -c1-160
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

echo "=================== mutations of seq_region_lock ==================="

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
"entity seq_region_lock is" \
"entity seq_region_lock is"

mutate N1 "the exponent write gate ignores the HELD state (hazard A3 undone)" \
'  xw_gate <= '"'"'0'"'"' when xw_we = '"'"'1'"'"'
                      and (xw_region >= NREG or xw_seg >= SEGS
                           or (lock(reg_idx(xw_region)) = L_HELD' \
'  xw_gate <= '"'"'0'"'"' when xw_we = '"'"'1'"'"'
                      and (xw_region >= NREG or xw_seg >= SEGS
                           or (lock(reg_idx(xw_region)) = L_FREE'

mutate N2 "the write gate no longer requires a live committed job (late writes land)" \
'  wr_gate <= '"'"'1'"'"' when wr_we = '"'"'1'"'"' and jb_live = '"'"'1'"'"' and jb_prod = '"'"'1'"'"'' \
'  wr_gate <= '"'"'1'"'"' when wr_we = '"'"'1'"'"' and jb_prod = '"'"'1'"'"''

mutate N3 "append-only is not enforced: any dst_offset is accepted" \
'        elsif iss_off /= fill_ptr(d) then
          ok := '"'"'0'"'"'; code := ERR_DESC;
        end if;' \
'        end if;'

mutate N4 "a consumer may take a FREE region (reads what nobody produced)" \
'        if lock(i) = L_FREE then
          ok := '"'"'0'"'"'; code := ERR_LOCK;
        elsif lock(i) = L_HELD then' \
'        if lock(i) = L_HELD then'

mutate N5 "the exponent is captured at ISSUE instead of at the producer done" \
'            exp_cap(jb_slot) <= cmp_y_exp;
            exp_vld(jb_slot) <= '"'"'1'"'"';' \
'            exp_vld(jb_slot) <= '"'"'1'"'"';'

mutate N6 "the release mask is ignored: every consumed region goes back to VALID" \
'              if jb_rel(i) = '"'"'1'"'"' then
                lock(i)     <= L_FREE;
                fill_ptr(i) <= (others => '"'"'0'"'"');
              else
                lock(i) <= L_VALID;
              end if;' \
'              lock(i) <= L_VALID;'

mutate N7 "the completion acts on the LIVE issue ports instead of the latched job" \
'          if jb_prod = '"'"'1'"'"' and jb_dst < NREG then' \
'          if iss_prod = '"'"'1'"'"' and jb_dst < NREG then'

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
