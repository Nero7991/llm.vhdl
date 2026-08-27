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
cd "$(dirname "$0")/.."
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

  local killers="" survivors=""
  for c in $CFGS; do
    if ghdl -r --std=08 -frelaxed --workdir="$dir" tb_seq_desc_fetch \
         $(cfg_args "$c") --max-stack-alloc=0 --stop-time=400ms \
         > "$dir/run_$c.log" 2>&1 && grep -q "PASS" "$dir/run_$c.log"; then
      survivors="$survivors $c"
    else
      killers="$killers $c"
    fi
  done

  if [ -n "$killers" ]; then
    echo "$tag  KILLED by:$killers   survived:${survivors:- -}   -- $desc"
    for c in $killers; do
      echo "      [$c $(cfg_name "$c")]"
      grep -E "MOVED|is [0-9-]+, expected|wedged|never completed" "$dir/run_$c.log" \
        | head -2 | sed 's/^/        /'
    done
  else
    echo "$tag  SURVIVED EVERY CONFIG   -- $desc"
  fi
}

echo "=================== mutations of seq_desc_fetch ==================="

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
