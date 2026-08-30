#!/usr/bin/env bash
# Mutation test for rtl/axi_rd_port.vhd's COMMON BODY and its SINGLE-CLOCK
# `g_sc` generate -- the two gates that hang off `run`, the R-channel accept
# term, the AR attributes, the level margin, and the flush handshake.
#
# WHY A SECOND SCRIPT ON THE SAME FILE.  sim/mutate_axi_rd_port_dual.sh already
# exists and mutates this file, but ONLY inside `g_dc`: the `start` toggle
# synchroniser, the `run` level crossing and the reset synchroniser.  It runs
# the DUAL_CLK = true configuration, in which `g_sc` is not elaborated at all.
# So before this file existed, the branch that EVERY gate row and every AXU3EG
# build takes -- and the concurrent assignments above both generates, which
# both configurations share -- had no mutation coverage.  Row N8 of
# docs/WORKLOG.md names that hole; this is it.  Read the two tables together.
#
# ---------------------------------------------------------------------------
# WHAT JUDGES IT, AND WHY FIVE CONFIGURATIONS
# ---------------------------------------------------------------------------
# sim/tb_axi_rd_port.vhd, at five points of its generic space:
#
#   gate   MAXOUT=2  DEPTH=64  STALL=3 QSTALL=0  the row sim/regress.sh runs
#   deep   MAXOUT=16 DEPTH=512 STALL=0 QSTALL=0  the FK33 numbers, no stalls
#   tight  MAXOUT=1  DEPTH=32  STALL=5 QSTALL=0  one burst in flight, heavy R stall
#   brim   MAXOUT=4  DEPTH=32  STALL=0 QSTALL=3  slave never stalls, CONSUMER does
#   brim2  MAXOUT=2  DEPTH=32  STALL=2 QSTALL=2  both sides stall
#   starve MAXOUT=16 DEPTH=16  STALL=0 QSTALL=9  smallest FIFO, slowest consumer
#
# The six are not decoration.  MAXOUT and DEPTH are what the FSM's AR throttle
# compares, and with QSTALL = 0 the FIFO never approaches DEPTH: the consumer
# holds q_ready high for the whole job, so the level is drained as fast as the
# slave fills it.  MEASURED by the bench's own occupancy witness, high-water
# mark over the run:
#
#   gate 26 of 64      deep 43 of 512     tight 11 of 32
#   brim 25 of 32      brim2 30 of 32     starve 12 of 16
#
# -- but read the CORRECTION below and the `track` comment in
# sim/tb_axi_rd_port.vhd before quoting any of those six numbers: they are an
# upper bound on occupancy, not occupancy.
#
# Only the last two put the level anywhere near DEPTH, and only there does
# `f_level + pr + want <= DEPTH` (rtl/axi_rd_fsm.vhd:223) actually bind.
#
# MEASURED AND REJECTED, 2026-08-29 -- DO NOT REDO THIS EXPECTING A DIFFERENT
# ANSWER.  `brim` and `brim2`, and the QSTALL generic they exist to drive, were
# added on the hypothesis that filling the FIFO would kill A5, A8, A9, C1 and
# C2 -- five rows that all look like ways to overrun it.  It killed NONE OF
# THEM.  The same eleven mutations survive with five configurations as with
# three.  The reason is structural and is worth stating once: the R channel is
# BACKPRESSURED.  `rready` is `f_ir` in S_RUN, so if the FSM over-issues, the
# FIFO simply stops accepting and the slave waits -- no beat is lost, no
# counter drifts, and the job finishes correctly, just later.  DEPTH, MAXOUT
# and LVL_MARGIN as the FSM is TOLD them are throughput parameters of this
# unit, not correctness ones, and no amount of stimulus makes them correctness
# ones.  A5 goes further and is provably equivalent -- see its own comment.
#
# The two configurations are kept anyway, for two reasons that are NOT
# mutation kills: they take the throttle's false branch, and they make the
# bench's occupancy witness report a number worth reading.  Do not present
# them as a coverage win.
#
# --------------------------------------------------------------------------
# CORRECTION, 2026-08-29 (TRACK ASURV).  THE PARAGRAPH ABOVE IS HALF WITHDRAWN,
# AND THE HALF THAT IS WRONG IS THE CONCLUSION, NOT THE MEASUREMENT.
# --------------------------------------------------------------------------
# What actually held: with the checks that existed, QSTALL killed nothing.
# What does NOT hold: "no amount of stimulus makes them correctness ones", and
# the decision not to build the witness that would have shown it.
#
# `rvalid and not rready` was tried, found to read 0, and written off as
# "measuring something the design makes impossible".  It IS impossible -- for
# the CORRECT design.  That is what makes it an invariant rather than a dead
# probe, and a witness that reads 0 on a correct design and non-zero on a
# broken one is the definition of a check.  It is now
# `sim/tb_axi_rd_port.vhd`'s CHK_FLOW assert, and it kills TWO of the rows
# that paragraph lists:
#
#   C2 (FIFO built half the depth the FSM throttles against) dies at `brim`,
#      34 refused beats -- a configuration THAT PARAGRAPH'S OWN WORK ADDED.
#      The stimulus was right all along; the detector was missing.
#   C1 (FSM told the FIFO is twice as deep) dies at `starve`, 5 refused beats.
#      MEASURED that it does NOT die at any of the other five, which is why
#      `starve` exists: DEPTH=16 is one burst's worth and QSTALL=9 is the
#      slowest consumer in the table.
#
# The corrected statement: DEPTH and MAXOUT DRIFT -- one number reaching the
# FSM and a different one reaching the FIFO -- is a correctness defect of the
# throttle, observable with no data loss at all.  DEPTH and MAXOUT moved
# CONSISTENTLY, and LVL_MARGIN moved either way, remain throughput or
# range-declaration changes; see the A8 comment for why LVL_MARGIN was never a
# throughput parameter either.  A5 is unaffected and is still provably
# equivalent.
#
# The occupancy witness that paragraph shipped is ALSO over-reported; the
# correction and its measurement are in sim/tb_axi_rd_port.vhd's `track`
# comment.  Do not quote its high-water numbers as FIFO occupancy.
#
# Any row caught by exactly one configuration names which one in the caught-by
# column, and that column is the useful part of the table.
#
# ---------------------------------------------------------------------------
# FOUR VERDICTS.  ONLY TWO OF THEM ARE EVIDENCE ABOUT THE BENCH.
# ---------------------------------------------------------------------------
#   KILL   the bench's own counter or one of its checks fired.
#   ABORT  ghdl stopped the run: an RTL assert, a bound check, or a hang.
#          Counted as caught, reported separately -- an abort says the design
#          is broken, not that this bench can tell you what is wrong with it.
#   SURV   the bench printed "0 bad beats" in every configuration.
#   VOID   the anchor did not match, or the mutant did not analyze.  A
#          mutation that will not compile has tested NOTHING, and scoring it
#          as a kill is the specific mistake that once made a script report
#          seven of seven CAUGHT while ghdl could not open a file at all.
#          VOID is never counted as a kill and is printed in full.
#
# THE SURVIVORS ARE THE POINT.  A row that survives every configuration
# measures this bench's resolution floor -- it names, in executable form, a
# change to the RTL that nothing here can see.  Every one is listed by tag at
# the bottom.  Do not delete a surviving row to make the table look better.
#
# Nothing under rtl/ is edited; every mutation is applied to a COPY.
#
# Usage: bash sim/mutate_axi_rd_port.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>
set -uo pipefail

# SELF-ISOLATE -- see sim/regress.sh for why.  bash reads a script lazily by
# byte offset, so an edit while an instance runs resumes it mid-token.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_axi_rd_port.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_axi_rd_port.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/axi_rd_port.vhd
TB=sim/tb_axi_rd_port.vhd
DEPS="rtl/util_pkg.vhd rtl/stream_fifo.vhd rtl/async_fifo.vhd rtl/axi_rd_fsm.vhd"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

# name : ghdl generic argv.  The order is the order the table reports.
# `starve` added 2026-08-29 (TRACK ASURV).  It is the ONLY configuration in
# which the FIFO is small enough (DEPTH=16, one burst's worth) and the consumer
# slow enough (QSTALL=9) that a throttle told the wrong DEPTH actually runs the
# FIFO out of room.  Without it C1 and C2 both survive; with it and the
# CHK_FLOW invariant in sim/tb_axi_rd_port.vhd both die.
#
# READ THIS TOGETHER WITH SECTION 6.1 OF
# docs/debugging/2026-08-29_acov-subsystem-a-coverage-gaps.md, which added
# QSTALL, measured that it killed ZERO rows, and concluded the FIFO parameters
# are throughput-only.  The stimulus was right and the conclusion was wrong:
# what was missing was a DETECTOR, not a stimulus.  `brim` (QSTALL=3), which
# that section shipped, is what kills C2 here.
CFG_NAMES="gate deep tight brim brim2 starve"
cfg_args() {
  case "$1" in
    gate)   echo "-gMAXOUT=2 -gDEPTH=64 -gSTALL=3 -gQSTALL=0 -gSEED=1" ;;
    deep)   echo "-gMAXOUT=16 -gDEPTH=512 -gSTALL=0 -gQSTALL=0 -gSEED=7" ;;
    tight)  echo "-gMAXOUT=1 -gDEPTH=32 -gSTALL=5 -gQSTALL=0 -gSEED=3" ;;
    brim)   echo "-gMAXOUT=4 -gDEPTH=32 -gSTALL=0 -gQSTALL=3 -gSEED=5" ;;
    brim2)  echo "-gMAXOUT=2 -gDEPTH=32 -gSTALL=2 -gQSTALL=2 -gSEED=8" ;;
    starve) echo "-gMAXOUT=16 -gDEPTH=16 -gSTALL=0 -gQSTALL=9 -gSEED=4" ;;
  esac
}

NKILL=0; NABORT=0; NSURV=0; NVOID=0; NTOT=0
SURV_TAGS=""; VOID_TAGS=""

# ---------------------------------------------------------------------------
# THE UNIQUENESS GATE.  MEASURED 2026-08-29: sim/mv4i_desc_mutations.py's
# --apply returns on the FIRST row whose name matches, so a duplicated tag
# silently tests one edit twice and another never -- and the table looks full
# either way.  TRACK ERRINFO hit it.  Here the tags live in the script, so the
# gate is a pre-pass over the mutate() call sites of THIS file, and it is
# teeth-checked below by TEETH=dup.
# ---------------------------------------------------------------------------
uniq_gate() {
  local src="$1"
  python3 - "$src" <<'PY'
import re, sys, collections
tags = re.findall(r'^\s*mutate\s+([A-Za-z0-9_]+)\s', open(sys.argv[1]).read(), re.M)
dup = [t for t, n in collections.Counter(tags).items() if n > 1]
if dup:
    sys.stderr.write("DUPLICATE MUTATION TAGS: %s\n" % " ".join(sorted(dup)))
    sys.exit(3)
print("%d tags, all distinct" % len(tags))
PY
}
if ! UG=$(uniq_gate "${MUT_REAL_DIR}/mutate_axi_rd_port.sh" 2>&1); then
  echo "REFUSING TO RUN: $UG"; exit 3
fi
echo "tag uniqueness gate: $UG"

# TEETH for the gate itself.  A checker never shown to fail has not been shown
# to work, so this runs it against a copy of this script with one tag
# duplicated and requires it to REFUSE.
teeth_uniq() {
  local t="$SCRATCH/teeth_dup.sh"
  sed 's/^mutate A6 /mutate A5 /' "${MUT_REAL_DIR}/mutate_axi_rd_port.sh" >"$t"
  if uniq_gate "$t" >/dev/null 2>&1; then
    echo "TEETH FAILED: the uniqueness gate accepted a duplicated tag"; exit 3
  fi
  echo "tag uniqueness gate TEETH: a duplicated A5 is refused -- the gate bites"
}
teeth_uniq

analyze_into() {   # analyze_into <workdir> <mutated-rtl-path> <logfile>
  local wd="$1" mut="$2" log="$3" f
  for f in $DEPS; do
    "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$REPO/$f" >>"$log" 2>&1 || return 1
  done
  "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$mut" >>"$log" 2>&1 || return 1
  "$GHDL" -a --std=08 -frelaxed --workdir="$wd" "$REPO/$TB" >>"$log" 2>&1 || return 1
  return 0
}

score_one() {   # score_one <log> <rc>  -> KILL|... / ABORT|... / SURV|...
  python3 - "$1" "$2" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
log = "\n".join(l for l in log.splitlines() if "metavalue detected" not in l)

tot  = re.search(r"axi_rd_port: (-?\d+) bad beats", log)
# THE CHECKER'S OWN DIAGNOSTICS COME FIRST.  A run that reports its own error
# and THEN aborts is a CAUGHT mutation; reading the abort first scores it as
# the weaker verdict, which is the mistake A-MUT made and paid a run for.
diag = re.search(r"tb_axi_rd_port\.vhd:\d+:\d+:@[^:]*:\(report error\): (.+)", log)
tbf  = re.search(r"tb_axi_rd_port\.vhd:\d+:\d+:@[^:]*:\((?:assertion|report) failure\): (.+)", log)
rtlg = re.search(r"(?:stream_fifo|async_fifo|axi_rd_fsm|axi_rd_port)\.vhd:\d+:\d+:@[^:]*:"
                 r"\((?:assertion|report) failure\): (.+)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
lang = re.search(r"(?:ghdl[^:]*|[^\s:]+):error: (.+)", log)
hung = re.search(r"simulation stopped (by --stop-time|@)", log)

if tot and int(tot.group(1)) == 0 and "0 bad beats" in log and rc == 0:
    print("SURV|0 bad beats")
elif diag:
    print("KILL|%s" % diag.group(1).strip()[:56])
elif tot and int(tot.group(1)) != 0:
    print("KILL|%s bad beats" % tot.group(1))
elif tbf:
    print("KILL|%s" % tbf.group(1).strip()[:56])
elif rtlg:
    print("ABORT|%s" % rtlg.group(1).strip()[:56])
elif bound:
    print("ABORT|%s" % bound.group(1).strip()[:56])
elif hung:
    print("ABORT|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|wall-clock timeout -- never terminated")
elif lang:
    print("ABORT|%s" % lang.group(1).strip()[:56])
else:
    print("ABORT|no verdict line and no error at all")
PY
}

patch_file() {
  python3 - "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i // 2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# ---------------------------------------------------------------------------
# THE CONTROL.  Run FIRST and in every configuration.  A red table below a
# broken control is a statement about the harness, not about the RTL.
# ---------------------------------------------------------------------------
echo
echo "=== control: the UNMUTATED rtl/axi_rd_port.vhd, all six configurations ==="
mkdir -p "$SCRATCH/control/work"
if ! analyze_into "$SCRATCH/control/work" "$REPO/$RTL" "$SCRATCH/control/analyze.log"; then
  echo "CONTROL DID NOT ANALYZE -- nothing below would mean anything:"
  tail -8 "$SCRATCH/control/analyze.log"; exit 2
fi
for c in $CFG_NAMES; do
  mkdir -p "$SCRATCH/control/$c"
  # shellcheck disable=SC2086
  ( cd "$SCRATCH/control/$c" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
      --workdir="$SCRATCH/control/work" tb_axi_rd_port $(cfg_args "$c") \
      --stop-time=200ms --stop-delta=2000000 ) >"$SCRATCH/control/$c.log" 2>&1
  crc=$?
  cres=$(score_one "$SCRATCH/control/$c.log" "$crc")
  printf '  %-6s %s\n' "$c" "$cres"
  if [ "${cres%%|*}" != "SURV" ]; then
    echo "CONTROL FAILED in configuration $c -- nothing below would mean anything:"
    grep -v "metavalue detected" "$SCRATCH/control/$c.log" | tail -10; exit 2
  fi
done

mutate() {   # mutate <tag> <class> <desc> <old> <new> [<old> <new> ...]
  local tag="$1" cls="$2" desc="$3"; shift 3
  if [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]]; then return; fi
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$SCRATCH/$tag"
  mkdir -p "$dir/work"

  if ! patch_file "$REPO/$RTL" "$dir/axi_rd_port.vhd" "$@" 2>"$dir/patch.log"; then
    NVOID=$((NVOID+1)); VOID_TAGS="$VOID_TAGS $tag"
    printf '%-4s %-5s VOID     ANCHOR FAILED -- TESTED NOTHING           -- %s\n' \
      "$tag" "$cls" "$desc"
    sed -n 1,2p "$dir/patch.log"; return
  fi

  if ! analyze_into "$dir/work" "$dir/axi_rd_port.vhd" "$dir/analyze.log"; then
    NVOID=$((NVOID+1)); VOID_TAGS="$VOID_TAGS $tag"
    printf '%-4s %-5s VOID     DID NOT ANALYZE -- TESTED NOTHING         -- %s\n' \
      "$tag" "$cls" "$desc"
    grep -m2 -i error "$dir/analyze.log" | sed 's/^/         /'; return
  fi

  local worst="SURV" det="0 bad beats" caught="" c res v
  for c in $CFG_NAMES; do
    mkdir -p "$dir/$c"
    # shellcheck disable=SC2086
    ( cd "$dir/$c" && timeout 300 "$GHDL" -r --std=08 -frelaxed \
        --workdir="$dir/work" tb_axi_rd_port $(cfg_args "$c") \
        --stop-time=200ms --stop-delta=2000000 ) >"$dir/$c.log" 2>&1
    local rc=$?
    res=$(score_one "$dir/$c.log" "$rc"); v="${res%%|*}"
    if [ "$v" != "SURV" ]; then
      caught="$caught $c"
      # KILL outranks ABORT: a named diagnostic is better evidence than a stop.
      if [ "$worst" = "SURV" ] || { [ "$worst" = "ABORT" ] && [ "$v" = "KILL" ]; }; then
        worst="$v"; det="${res#*|}"
      fi
    fi
  done

  case "$worst" in
    KILL)  NKILL=$((NKILL+1));  v="KILLED  " ;;
    ABORT) NABORT=$((NABORT+1)); v="ABORT   " ;;
    *)     NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"; v="SURVIVED" ;;
  esac
  printf '%-4s %-5s %s %-46s by[%s] -- %s\n' \
    "$tag" "$cls" "$v" "$det" "${caught:- none}" "$desc"
}

echo
echo "======================================================================="
echo " mutations of rtl/axi_rd_port.vhd (common body + g_sc),"
echo " judged by sim/tb_axi_rd_port.vhd in six configurations"
echo "======================================================================="
echo "tag  class verdict  detail                                         caught-by -- what was changed"

# --- class AR: the address-channel attributes, shared by both generates -----
# The bench's slave asserts both, at severity failure, so these land as ABORT.
# That is the honest verdict: the slave stops the run, it does not count a bad
# beat.  Both are here because the FK33's HBM slave is AXI3 and would answer a
# wrong burst type or size with silence, not with an assert.
mutate A1 AR "arsize one below clog2(BYTES) -- 8-byte beats claimed on a 16-byte bus" \
  '  arsize  <= std_logic_vector(to_unsigned(clog2(BYTES), 3));' \
  '  arsize  <= std_logic_vector(to_unsigned(clog2(BYTES) - 1, 3));'

mutate A2 AR "arburst FIXED instead of INCR -- every beat of a burst at one address" \
  '  arburst <= "01";                                  -- INCR' \
  '  arburst <= "00";                                  -- INCR'

# --- class RUN: the four gates that hang off the run level ------------------
mutate A3 RUN "rready deasserted outside S_RUN -- the drain can never complete" \
  "  rready_i <= f_ir when run_f = '1' else '1';" \
  "  rready_i <= f_ir when run_f = '1' else '0';"

# A4 IS AN EQUIVALENT MUTANT, and the argument is the FLUSH, not the stimulus.
# S_DRAIN is ALWAYS followed by S_CLR/S_CLR2 (rtl/axi_rd_fsm.vhd, S_DRAIN's
# only exit), those states hold `clr`, and rtl/stream_fifo.vhd:73 clears the
# WHOLE fifo on `rst = '1' or flush = '1'`.  So whatever a drain writes is gone
# before S_RUN, and the FIFO's state entering S_RUN is empty either way.  If
# the FIFO is full while the drain writes, rtl/stream_fifo.vhd:64 drops
# `i_ready` and the write is refused silently -- there is no overflow assert
# for it to trip either.
# THE ATTRIBUTION: row B4, which disables the flush outright, is KILLED by
# every configuration.  The detector for residue exists and bites; A4's residue
# is removed before it can be read.  Row PD of sim/mutate_axi_rd_port_dual.sh
# is the same edit and also survives, at three clock ratios.
mutate A4 RUN "FIFO accepts write data outside S_RUN -- EQUIVALENT MUTANT, the flush removes it" \
  "  f_iv     <= rvalid when run_f = '1' else '0';" \
  "  f_iv     <= rvalid;"

# A5 IS AN EQUIVALENT MUTANT, PROVED RATHER THAN MEASURED, and is kept for
# exactly that reason.  `rready_i` is `f_ir` in S_RUN and '1' otherwise, and
# the FSM's throttle guarantees `f_level + pr + want <= DEPTH`, so `f_ir` is
# never low -- therefore `rvalid and rready_i` and `rvalid` are the same
# expression on every legal trace.  No configuration of this bench, and no
# consumer stall rate, can make it bite.  Do not "fix" the bench for it.
mutate A5 RUN "beat counted on rvalid alone -- EQUIVALENT MUTANT, see above" \
  '  beat_f   <= rvalid and rready_i;' \
  '  beat_f   <= rvalid;'

mutate A6 RUN "q_valid ungated -- the abandoned job's residue is offered to the consumer" \
  "  q_valid <= f_qv when run_c = '1' else '0';" \
  "  q_valid <= f_qv;"

# A7 IS AN EQUIVALENT MUTANT IN THIS CONFIGURATION AND ONLY IN THIS ONE.
# In g_sc `run_c <= run_f` is a plain wire, so the window in which the gate is
# removed is exactly the window in which `f_iv` is gated OFF -- the FIFO can
# then hold only the previous job's residue, which the flush is about to
# discard anyway, and rtl/stream_fifo.vhd:99 pops only `if ocnt > 0 and
# q_ready = '1'`, so a pop on an empty FIFO is a no-op.
#
# UNDER DUAL_CLK IT IS NOT EQUIVALENT AND NOTHING CATCHES IT.  There
# `run_c <= run_s2`, twice synchronised, so it rises up to two core cycles
# AFTER run_f -- and the async FIFO may already hold job data in that window.
# An ungated `f_qr` pops those words while `q_valid` is suppressed and they are
# LOST.  rtl/axi_rd_port.vhd's header argues "late is the safe direction" for
# q_valid; that argument holds only because f_qr carries the same late gate.
# MEASURED 2026-08-29: row P8 of sim/mutate_axi_rd_port_dual.sh is exactly this
# edit and SURVIVES all three clock ratios, so sim/tb_axi_rd_port_dual.vhd does
# not see it either.  Reported, not fixed -- that bench is not this script's.
mutate A7 RUN "q_ready ungated -- equivalent in g_sc, NOT under DUAL_CLK (see above)" \
  "  f_qr    <= q_ready when run_c = '1' else '0';" \
  "  f_qr    <= q_ready;"

# --- class LVL: the one constant both the FIFO and the FSM are given --------
# Its whole reason for existing is that the two must not drift, so the two
# halves are mutated SEPARATELY: changing both together is the safe edit and
# would prove nothing.
#
# BOTH A8 AND A9 ARE EQUIVALENT MUTANTS IN g_sc, PROVED, and the reason is NOT
# the throttle.  LVL_MARGIN does not appear in the throttle at all.  Its only
# uses are rtl/axi_rd_port.vhd:142 (the local f_level signal's range),
# :209/:281 (the FSM generic) and :291 (async_fifo's OUT_MARGIN, g_dc ONLY) --
# and inside rtl/axi_rd_fsm.vhd it appears ONLY in `f_level : in integer range
# 0 to 2*DEPTH + LVL_MARGIN`.  Nothing reads it.  So in the single-clock
# configuration these two edits narrow a declared range from 0..2*DEPTH+3 to
# 0..2*DEPTH and change nothing else.  rtl/stream_fifo.vhd:67 drives
# `level <= mcnt + ocnt + inflight` with mcnt <= DEPTH, ocnt <= 2 (the do_rd
# guard) and inflight <= 1, so the largest value ever driven is DEPTH+3, which
# is below 2*DEPTH for every DEPTH >= 3 and for all six configurations here.
# A bound check therefore cannot fire.
#
# This CORRECTS section 6.1 of
# docs/debugging/2026-08-29_acov-subsystem-a-coverage-gaps.md, which grouped
# LVL_MARGIN with DEPTH and MAXOUT as "throughput parameters of this unit".
# DEPTH and MAXOUT are; LVL_MARGIN is a range declaration and is not a
# parameter of the behaviour in either sense.
#
# In g_dc it IS load-bearing -- async_fifo's level really is offset by
# OUT_MARGIN and really does wrap during the four-phase clear (see
# rtl/axi_rd_fsm.vhd's f_level comment).  Row PG of
# sim/mutate_axi_rd_port_dual.sh is the drift version there and also survives.
mutate A8 LVL "LVL_MARGIN 3 -> 0 in BOTH -- EQUIVALENT MUTANT in g_sc, see above" \
  '  constant LVL_MARGIN : natural := 3;' \
  '  constant LVL_MARGIN : natural := 0;'

# The g_sc and g_dc FSM generic maps are TEXTUALLY IDENTICAL, so every anchor
# below carries the following `port map(clk => clk, rst => rst, ...)` line,
# which is the only thing that distinguishes the single-clock instance from the
# dual-clock one (`clk => aclk, rst => frst`).  Drop that line from an anchor
# and patch_file's uniqueness check refuses the edit rather than picking one.
mutate A9 LVL "FSM told margin 0, FIFO still 3 -- EQUIVALENT MUTANT in g_sc, see A8" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => 0)
      port map(clk => clk, rst => rst, start => start_f,'

# --- class SC: the single-clock generate's own five lines -------------------
# B1 IS AN EQUIVALENT MUTANT BECAUSE THE ASSIGNMENT IS DEAD CODE.  `frst` is
# read at rtl/axi_rd_port.vhd:281 (`rst => frst`) and :291 (`wrst => frst`),
# both inside g_dc.  In g_sc the FSM and the FIFO are both handed `rst`
# directly, so nothing in that branch reads `frst` and no value assigned to it
# can be observed.  Reported by TRACK ACOV, confirmed independently here, and
# still NOT fixed -- this is a coverage track and does not edit rtl/.
mutate B1 SC "frst tied low in g_sc -- EQUIVALENT MUTANT, the assignment is dead" \
  '    frst    <= rst;' \
  "    frst    <= '0';"

mutate B2 SC "start never reaches the FSM" \
  '    start_f <= start;' \
  "    start_f <= '0';"

mutate B3 SC "run_c tied high -- the output gate is removed, not merely late" \
  '    run_c   <= run_f;' \
  "    run_c   <= '1';"

mutate B4 SC "the FIFO flush of 7.7 is disabled -- residue survives into the next job" \
  "      port map(clk => clk, rst => rst, flush => clr," \
  "      port map(clk => clk, rst => rst, flush => '0',"

mutate B5 SC "clr_done asserted permanently -- the four-phase handshake short-circuits" \
  "        if rst = '1' then ack <= '0'; else ack <= clr; end if;" \
  "        if rst = '1' then ack <= '0'; else ack <= '1'; end if;"

mutate B6 SC "clr_done never asserted -- the clear handshake never completes" \
  "        if rst = '1' then ack <= '0'; else ack <= clr; end if;" \
  "        if rst = '1' then ack <= '0'; else ack <= '0'; end if;"

# B7 IS BEHAVIOUR-PRESERVING, ONE TO TWO CYCLES EARLY.  With clr_done = clr the
# FSM leaves S_CLR on its first evaluation of that state -- but `clr_r` is
# already high by then (it was set on entry from S_DRAIN), so the FIFO still
# sees `flush = '1'` at a rising edge and rtl/stream_fifo.vhd:73 still clears
# everything; S_CLR2 then leaves immediately because clr_done has followed clr
# down.  The registered ack exists so the four-phase handshake is the SAME CODE
# in both configurations, which is what rtl/axi_rd_port.vhd's own comment says.
# THE RESOLUTION IS VISIBLE IN THIS TABLE: B5 (clr_done stuck HIGH) and B6
# (stuck LOW) both ABORT, so the bench does discriminate this handshake -- what
# it does not discriminate is a clr_done that is correct and one cycle early.
mutate B7 SC "clr_done combinational rather than registered -- one cycle early, same effect" \
  '    clr_done <= ack;' \
  '    clr_done <= clr;'

# --- class GEN: what the FSM and the FIFO are TOLD about each other ---------
# These are the drift class: the port is correct, one submodule's idea of the
# other's size is not.  MAXOUT and DEPTH bind at different points of the three
# configurations, which is why the caught-by column is the interesting one.
mutate C1 GEN "the FSM believes the FIFO is twice as deep as it is" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => 2*DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,'

mutate C2 GEN "the FIFO is built half the depth the FSM throttles against" \
  '      generic map(W => AXI_DW, DEPTH => DEPTH)' \
  '      generic map(W => AXI_DW, DEPTH => DEPTH / 2)'

# C3 IS UNOBSERVABLE IN THIS BENCH, AND THE REASON IS THE SLAVE MODEL.
# sim/tb_axi_rd_port.vhd's slave is one sequential process: it waits for
# arvalid, accepts exactly one AR, returns every beat of that burst, and only
# then loops.  So at most ONE burst is ever outstanding and `os < MAXOUT` is
# true for every MAXOUT >= 2.
# MEASURED 2026-08-29, unmutated port, gate configuration: MAXOUT = 2, 4, 16
# and 64 all finish at @3395ns with an identical occupancy trace, while
# MAXOUT = 1 finishes at @3235ns.  So the knob is LIVE and saturates at 2 --
# the survival is a slave-model limit, not a dead parameter.  Reaching it needs
# a slave that accepts ARs while it is still returning data, which is a new
# model rather than a new configuration.
mutate C3 GEN "the FSM may keep 64 bursts in flight regardless of MAXOUT -- see above" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => 64, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,'

# C4 IS A PERFORMANCE MUTATION AND IS DELIBERATELY NOT KILLED.  ARLEN = 0 is
# legal AXI3 and AXI4, every beat is delivered in order, and the bench's own
# occupancy witness drops from 26 to 4 -- correct, and 16x the AR traffic.  On
# the FK33 that is a real cost across 27 masters, but it is a cost, not a
# defect, and turning it into a kill would need an arbitrary AR-count
# threshold.  Counting it as caught would be weakening what a kill means.
mutate C4 GEN "burst length capped at one beat -- legal AXI, PERFORMANCE ONLY, see above" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => 1, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,'

# C5/C6 ARE THE BOARD ROWS.  ARLEN is eight bits here and eight bits on AXI4,
# but the FK33's HBM slave is AXI3, where it is FOUR -- so a burst longer than
# 16 beats is not slow, it is unanswerable.  Both of these SURVIVED before
# sim/tb_axi_rd_port.vhd's ARLEN_MAX assert was added; C6 sits one beat over
# the cap and exists to show the assert's resolution is the cap itself and not
# merely "very long bursts".
mutate C5 GEN "MAXB 256 -- ARLEN 255, legal AXI4 and unanswerable on the FK33's AXI3 HBM" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => 256, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,'

mutate C6 GEN "MAXB 17 -- ONE beat over the AXI3 cap, the resolution row" \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,' \
  '      generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                  MAXB => 17, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
      port map(clk => clk, rst => rst, start => start_f,'

echo
echo "======================================================================="
printf ' %d mutations: %d KILLED, %d ABORT (%d caught), %d SURVIVED, %d VOID\n' \
  "$NTOT" "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NSURV" "$NVOID"
if [ -n "$SURV_TAGS" ]; then
  echo " SURVIVORS (this bench's resolution floor, do not delete):$SURV_TAGS"
fi
if [ -n "$VOID_TAGS" ]; then
  echo " VOID (tested nothing -- fix the anchor before believing the table):$VOID_TAGS"
fi
echo " scratch: $SCRATCH"
echo "======================================================================="
