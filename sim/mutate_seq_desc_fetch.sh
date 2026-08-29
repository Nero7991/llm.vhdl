#!/usr/bin/env bash
# Mutation test for rtl/seq_desc_fetch.vhd.
#
# A passing testbench proves nothing until it has been shown to FAIL on a
# deliberately broken design.  Each mutation below removes exactly one of the
# mechanisms the unit exists for, and the table at the end records which
# configuration killed it -- because "killed by some configuration" is a much
# weaker statement than "killed by the configuration you would have run".
#
# Two traps this project has already paid for and that this script avoids:
#
#  - A mutation that trips a LANGUAGE check has not tested your checker.  The
#    first seam-3 mutation on gdn_emit_chain ran off the end of a slice; the
#    run "failed", but it failed on a VHDL bounds check.  Every mutation here
#    is in-bounds and well-formed, and changes behaviour rather than legality.
#  - A mutation that survives is not automatically test blindness.  It may be
#    an equivalent mutant, and the difference is established by READING the
#    code, not by assuming.  See the notes printed at the end.
#
# The source file is never modified: each mutant is a copy in a scratch dir.
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
SRC=rtl/seq_desc_fetch.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

# The configurations.  They differ in exactly the way the header of
# tb_seq_desc_fetch says matters: how far ahead the memory runs and how far
# behind the units run.
cfg_name() { case "$1" in
  A) echo "prefetch far ahead  (URAM_LAT=1 JOB_LAT=120)";;
  B) echo "units instant       (URAM_LAT=1 JOB_LAT=0)";;
  C) echo "re-arms on ack, done still high (STALE_HOLD=6 READY_EARLY JOB_LAT=40)";;
  D) echo "done on own timer   (DONE_STYLE=2)";;
  E) echo "one-cycle unit err  (ERR_AT=200 LATE_ERR)";;
  F) echo "stale epoch echo    (EPOCH_BAD_AT=137)";;
  G) echo "unit hangs past the watchdog, then pulses done in S_ABORT";;
esac; }
cfg_args() { case "$1" in
  A) echo "-gURAM_LAT=1 -gJOB_LAT=120 -gLAT_SKEW=11 -gTOKENS=1";;
  B) echo "-gURAM_LAT=1 -gJOB_LAT=0 -gLAT_SKEW=0 -gTOKENS=1";;
  C) echo "-gSTALE_HOLD=6 -gREADY_EARLY=true -gJOB_LAT=40 -gLAT_SKEW=0 -gURAM_LAT=1 -gTOKENS=1";;
  D) echo "-gDONE_STYLE=2 -gDONE_HOLD=6 -gJOB_LAT=5 -gLAT_SKEW=2 -gTOKENS=1";;
  E) echo "-gERR_AT=200 -gLATE_ERR=true -gTOKENS=1";;
  F) echo "-gEPOCH_BAD_AT=137 -gTOKENS=1";;
  G) echo "-gHANG_AT=90 -gDONE_STYLE=1 -gJOB_LAT=5 -gTOKENS=1";;
esac; }
CFGS="A B C D E F G"

# One mutant: name, then a python expression pair (old, new) applied literally.
mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/seq_desc_fetch.vhd" "$old" "$new" <<'PY'
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
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/seq_desc_fetch.vhd" \
       > "$dir/analyze.log" 2>&1; then
    echo "$tag: DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,5p "$dir/analyze.log"
    return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/seq_tbl_pkg.vhd >/dev/null 2>&1
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_seq_desc_fetch.vhd >/dev/null 2>&1

  local killers="" survivors="" aborts="" rcv v
  for c in $CFGS; do
    ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_desc_fetch \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1
    rcv=$?
    v=$(python3 "$MUTV" "$dir/run_$c.log" tb_seq_desc_fetch "$rcv")
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
      grep -E "MOVED|is [0-9-]+, expected|wedged|never completed" "$dir/run_$c.log" \
        | head -2 | sed 's/^/        /'
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

echo "=================== mutations of seq_desc_fetch ==================="

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
"entity seq_desc_fetch is" \
"entity seq_desc_fetch is"

mutate M1 "two-bank descriptor shadow -> ONE bank (the prefetch writes the live descriptor)" \
'              f_bank <= other(live_bank);' \
'              f_bank <= live_bank;'

mutate M2 "S_ISSUE no longer refuses to start a unit that is still asserting done" \
'            if u_ready(cur_unit) = '"'"'1'"'"' and u_done(cur_unit) = '"'"'0'"'"' then' \
'            if u_ready(cur_unit) = '"'"'1'"'"' then'

mutate M3 "err and epoch are re-latched every cycle done is high, not frozen at first sight" \
'          if (armed(u) = '"'"'1'"'"' or (start_acc = '"'"'1'"'"' and cur_unit = u))
             and u_done(u) = '"'"'1'"'"' and done_seen(u) = '"'"'0'"'"' then' \
'          if (armed(u) = '"'"'1'"'"' or (start_acc = '"'"'1'"'"' and cur_unit = u))
             and u_done(u) = '"'"'1'"'"' then'

mutate M4 "the sticky capture is no longer gated on the unit having a job outstanding" \
'          if (armed(u) = '"'"'1'"'"' or (start_acc = '"'"'1'"'"' and cur_unit = u))
             and u_done(u) = '"'"'1'"'"' and done_seen(u) = '"'"'0'"'"' then' \
'          if u_done(u) = '"'"'1'"'"' and done_seen(u) = '"'"'0'"'"' then'

mutate M5 "the job-epoch comparison at completion is removed" \
'            if epoch_seen(cur_unit) /= epoch_r then' \
'            if false then'

mutate M6 "END_TOKEN is not counted, so the accounting identity is off by one" \
'              pf_take  <= '"'"'1'"'"';
              steps_r  <= steps_r + 1;' \
'              pf_take  <= '"'"'1'"'"';'

mutate M7 "S_WAIT samples the RAW done instead of the sticky bit" \
'            if done_seen(cur_unit) = '"'"'1'"'"' then
              state <= S_COMPLETE;' \
'            if u_done(cur_unit) = '"'"'1'"'"' then
              state <= S_COMPLETE;'

mutate M8 "S_ABORT samples the RAW done instead of the sticky bit" \
'            if done_seen(cur_unit) = '"'"'1'"'"' or wdog >= WDOG_LIMIT then' \
'            if u_done(cur_unit) = '"'"'1'"'"' or wdog >= WDOG_LIMIT then'

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
