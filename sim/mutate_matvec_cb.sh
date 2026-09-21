#!/usr/bin/env bash
# sim/mutate_matvec_cb.sh -- the IQ4_NL codebook's WRITE PATH, mutated.
#
# WHY THIS EXISTS, AND WHY IT IS NOT A SECTION OF sim/mutate_matvec_core.sh.
#
# sim/mutate_matvec_core.sh measures what `tb_matvec_core` can see, against
# `ref/matvec_int4.c`, over three weight traces.  Its class CB has four rows and
# THREE OF THE FOUR SURVIVED every trace (see
# docs/debugging/2026-08-29_subsystem-a-mutations.md section 4.3): that bench
# writes the codebook once, before the first `start`, and never again, so the
# branches those mutations change are never taken.  Adding rows there would
# have measured the same blind spot more precisely.
#
# The pre-authorised congestion fallback -- the codebook to LUTRAM, which is
# roughly 7.1x on 86,992 primitives and costs zero throughput -- replaces one
# replica per ROW with one per LANE.  DERIVED from the FK33 geometry
# (`ROWS_IF = 48`, `BLK = 32`): 48 replicas becomes 48*32 = 1,536, a factor of
# 32.  That is the number Oren attached to his approval, and it is the size of
# the write-coherency surface, not of the area win.
#
# So this script measures the WRITE PATH itself, against the two benches that
# drive it, and it does so BEFORE the change rather than after.  Its most
# valuable output is not the kill ratio.  It is the two lists at the end:
#
#   * mutations that SURVIVE today and would survive under LUTRAM too -- these
#     are the parts of the write path nothing is watching;
#   * the assert-neutered column, which answers the one question the fallback
#     turns on: does the VALUE oracle still catch this if `P_CB_CHK` is
#     disturbed?  A change that multiplies the replica count by 32 is exactly
#     the kind of change that gets `P_CB_CHK` rewritten.
#
# ---------------------------------------------------------------------------
# THE TWO BENCHES, AND WHAT EACH IS FOR
# ---------------------------------------------------------------------------
#   C  sim/tb_matvec_cb_contract.vhd   the write CONTRACT: writes outside idle
#      and under reset are dropped; the table survives reset; the cb_we/start
#      interlock holds from both sides; an un-loaded codebook decodes to zero;
#      every emitted lane is equal, which is replica coherency seen at the
#      OUTPUT rather than through an internal assertion.
#   L  sim/tb_matvec_cb_lockstep.vhd   the LOAD SCHEDULE: the same codebook
#      loaded twenty cycles before start and one cycle before start must give a
#      bit-identical result, with a different-codebook teeth check.
#   M  sim/tb_matvec_core.vhd           the ABSOLUTE value oracle, stage by
#      stage against `ref/matvec_int4.c` on the committed `sim/tr.txt`.  It is
#      here because C and L are RELATIONAL: they compare runs against each
#      other and have no model of what a codebook SHOULD produce.  A mutation
#      that corrupts every load in the same way is invisible to both and
#      obvious to M.  MEASURED: K7a is exactly that mutation.
#
# ---------------------------------------------------------------------------
# THE TWO ASSERT MODES, AND WHY THE SECOND ONE IS THE POINT
# ---------------------------------------------------------------------------
#   A  matvec_core as it is.  `P_CB_CHK`'s three assertions are live.
#   N  the same, with `P_CB_CHK`'s assertions demoted to `severity note`.
#
# A row that is KILLED in A and SURVIVES in N is a row that ONLY the internal
# assertion catches.  That is not a criticism of the assertion -- section 5 of
# docs/debugging/2026-08-27_matvec-codebook-replication.md establishes that the
# assertion is the right instrument and that no behavioural bench replaces it.
# It is a dependency, and a dependency that the LUTRAM change stands on top of
# needs to be written down before the change, not discovered after it.
#
# ---------------------------------------------------------------------------
# THREE VERDICTS, AND A CONTROL
# ---------------------------------------------------------------------------
#   KILL   a bench reported a failed property, or the core's own assertion
#          fired.  The mechanism is recorded: `v` = the bench's value oracle,
#          `a` = matvec_core's internal assertion, `va` = both.
#   ABRT   the run stopped without a verdict: a bound violation, a hang to
#          --stop-time, a wall-clock timeout, or no recognisable line at all.
#          Counted as a kill, worth less than one: it is the language noticing
#          rather than a checker, and the same mutation in hardware would read
#          a neighbouring array entry in silence.
#   surv   the bench printed its PASS line.
#
# The CTRL row is the UNMUTATED design through this same path.  A harness whose
# control does not survive is measuring its own configuration, and every kill
# in the table below it is unearned.  This script REFUSES TO CONTINUE if CTRL
# is not `surv` in all four columns.
#
# ---------------------------------------------------------------------------
# NOTHING UNDER rtl/ IS EDITED.  Every mutation is applied to a COPY in a
# private scratch directory.
# ---------------------------------------------------------------------------
#
# Usage: bash sim/mutate_matvec_cb.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>   MODES="A N"
set -uo pipefail

# SELF-ISOLATE.  bash reads a script lazily by byte offset, so an edit to this
# file while an instance runs resumes the shell mid-token.  sim/regress.sh and
# sim/mutate_matvec_core.sh do the same thing for the same reason.
if [ -z "${MUTCB_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_matvec_cb.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_matvec_cb.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUTCB_ISOLATED=1 MUTCB_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUTCB_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/matvec_core.vhd
TB_C=sim/tb_matvec_cb_contract.vhd
TB_L=sim/tb_matvec_cb_lockstep.vhd
TB_M=sim/tb_matvec_core.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
MODES="${MODES:-A N S}"
CBSTYLE="${CBSTYLE:-regs}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""
# THE LEDGER.  TRACK CBANCHOR, 2026-09-20.  Before this, a dead anchor printed
# one loud line and the script still exited 0 -- so the only arithmetic tell
# was that KILLED + ABORTED + SURVIVED did not add up to the total, which
# nobody computes.  MEASURED at 0b34200: nine rows printed ANCHOR FAILED and
# `kill ratio: 0 KILLED + 0 ABORTED = 0 of 20;  11 SURVIVED` was the summary,
# rc 0.  TRACK REANCHOR fixed the same shape in two other harnesses; this one
# was NOT among them.  A row that did not run is now named in a block of its
# own and the script exits nonzero.
DEAD_TAGS=""
ONLY_ASSERT_TAGS=""
MODEL_EARNED_TAGS=""

# ---------------------------------------------------------------------------
# 1. THE PATCHER.  A mutation whose anchor is not unique has tested nothing, so
#    a non-unique or absent anchor is a hard error, never a silent skip.
#    `--neuter` additionally demotes P_CB_CHK's assertions, and it is applied
#    to a region located by its process name rather than by line number.
# ---------------------------------------------------------------------------
patch_file() {  # patch_file <src> <dst> <neuter-list> [old new]...
  python3 - "$@" <<'PY'
import sys
src, dst, neuter = sys.argv[1], sys.argv[2], sys.argv[3]
pairs = sys.argv[4:]
s = open(src).read()

# ---------------------------------------------------------------------------
# SCOPES, STATED IN CODE.  TRACK CBANCHOR, 2026-09-20.
#
# TRACK REANCHOR MEASURED that five of its 27 dead rows died with NOTHING
# INSIDE THE ANCHOR EDITED: a second, textually identical copy of a block
# appeared elsewhere in the file and a once-unique anchor became ambiguous.
# Uniqueness is a property of the FILE, not of the anchor, so an anchor that
# is unique today buys nothing tomorrow.
#
# This file already carries that hazard, MEASURED 2026-09-20:
#
#   "for c in 0 to CB_COPIES-1 loop"                  matches TWICE
#       (P_CB's write loop, and P_CB_MODEL's compare loop)
#   "if cb_we = '1' and st = S_IDLE and rst = '0' then"
#       appears in P_CB at 8 spaces of indent and in P_CB_MODEL at 6.
#       The ONLY discriminator is whitespace, which is exactly as fragile as
#       REANCHOR's discriminating comment -- and mutating P_CB_MODEL's copy
#       would edit the ORACLE rather than the design under test, which scores
#       as a survival for the worst possible reason.
#
# So an anchor may be prefixed "@SCOPE@" to require uniqueness INSIDE a named
# region rather than in the whole file.  A scope is two CODE landmarks: a
# process header, which must match exactly once in the file, and the first
# "end process;" after it.  Nothing here depends on a comment.
SCOPES = {
    "P_CB":       "  P_CB : process(clk)",
    "P_CB_CHK":   "  P_CB_CHK : process(clk)",
    "P_CB_MODEL": "  P_CB_MODEL : process(clk)",
}
SCOPE_END = "\n  end process;"

def scope_span(s, name):
    head = SCOPES[name]
    n = s.count(head)
    if n != 1:
        sys.stderr.write("SCOPE %s HEAD MATCHED %d TIMES, expected 1\n" % (name, n))
        sys.exit(2)
    a = s.index(head)
    b = s.find(SCOPE_END, a + len(head))
    if b < 0:
        sys.stderr.write("SCOPE %s HAS NO end process; AFTER ITS HEAD\n" % name)
        sys.exit(2)
    return a, b + len(SCOPE_END)

for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    scope = None
    if old.startswith("@"):
        j = old.index("@", 1)
        scope, old = old[1:j], old[j+1:]
        if scope not in SCOPES:
            sys.stderr.write("ANCHOR %d NAMES UNKNOWN SCOPE %s\n" % (i // 2, scope))
            sys.exit(2)
    lo, hi = scope_span(s, scope) if scope else (0, len(s))
    region = s[lo:hi]
    n = region.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES%s, expected 1\n"
                         % (i // 2, n, (" IN SCOPE " + scope) if scope else ""))
        sys.exit(2)
    s = s[:lo] + region.replace(old, new) + s[hi:]
# NEUTER is now a comma-separated list of PROCESS NAMES, not a flag, because
# there are two independent checkers in this file and the whole point of the
# attribution control is to disable exactly one of them at a time.  Each name
# carries the number of asserts it is expected to contain: a region that has
# grown or shrunk is a hard error, never a silent partial neuter.
EXPECT = {"P_CB_CHK": 3, "P_CB_MODEL": 3}
# THE PIN IS NOT A PROCESS, so it is neutered by substitution rather than by
# demoting a severity.  CHK_CB_RANKS is an out-of-range `natural` constant --
# the idiom this project uses BECAUSE Vivado silently ignores
# `assert ... severity failure` in synthesis -- so it fires at ELABORATION and
# there is no severity to demote.  Mode P sets it to a constant 0, which is
# the design exactly as it stood before TRACK CBFANOUT added the pin.  This is
# THE ATTRIBUTION CONTROL for the pin: a row KILLED in A and surv in P is a
# kill the pin earned and that nothing older in the project can see.
PIN_DECL = "  constant CHK_CB_RANKS : natural := cb_rank_chk_f;"
PIN_OFF  = "  constant CHK_CB_RANKS : natural := 0;"
for name in [x for x in neuter.split(",") if x]:
    if name == "CHK_CB_RANKS":
        if s.count(PIN_DECL) != 1:
            sys.stderr.write("NEUTER: CHK_CB_RANKS declaration matched %d times\n"
                             % s.count(PIN_DECL)); sys.exit(2)
        s = s.replace(PIN_DECL, PIN_OFF)
        continue
    if name not in EXPECT:
        sys.stderr.write("NEUTER: unknown process %s\n" % name); sys.exit(2)
    a = s.index("%s : process(clk)" % name)
    b = s.index("end process;", a)
    region = s[a:b]
    if region.count("severity failure;") != EXPECT[name]:
        sys.stderr.write("NEUTER: expected %d asserts in %s, found %d\n"
                         % (EXPECT[name], name, region.count("severity failure;")))
        sys.exit(2)
    s = s[:a] + region.replace("severity failure;", "severity note;") + s[b:]
open(dst, "w").write(s)
PY
}

# ---------------------------------------------------------------------------
# 2. RUN ONE MUTANT AGAINST ONE BENCH
# ---------------------------------------------------------------------------
run_bench() {  # run_bench <workdir> <top> ; echoes verdict|mechanism|detail
  local dir="$1" top="$2"
  local rd="$dir/run_$top"
  local extra=()
  mkdir -p "$rd"
  if [ "$top" = tb_matvec_core ]; then
    extra=(-gTRACE="$REPO/sim/tr.txt" -gRI=4 -gSTALL=0)
  fi
  # CBSTYLE=distributed re-runs the WHOLE table against lever C's granularity
  # (one codebook per LANE, 32x the copies at the FK33 shape).  Every bench in
  # this harness now carries the generic, so the write-coherency surface the
  # change opens is measured by the same mutations rather than argued about.
  extra+=(-gCB_STYLE="$CBSTYLE")
  # --stop-time=200us is ~22x the honest run (MEASURED: tb_matvec_cb_contract
  # finishes at 8.875 us, tb_matvec_cb_lockstep at 3.6 us, tb_matvec_core at
  # 4.905 us), so a mutation that HANGS is caught in simulated time rather than
  # by a wall-clock timeout.
  ( cd "$rd" && timeout 300 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" \
      "$top" "${extra[@]}" --stop-time=200us --stop-delta=2000000 ) \
      >"$dir/log_$top" 2>&1
  local rc=$?
  python3 - "$dir/log_$top" "$rc" "$top" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc, top = int(sys.argv[2]), sys.argv[3]

# ORDER MATTERS.  The bench's own diagnostics are consulted BEFORE ghdl's
# epilogue, because a severity-failure assert STOPS the run and ghdl then
# prints `ghdl:error: assertion failed` -- a parser that reads that first
# scores a real KILL as an ABORT.  That exact error cost sim/mutate_matvec_
# core.sh a whole run on 2026-08-29 and is recorded in its source.
if top == "tb_matvec_core":
    # this bench announces success with a sentence, not with "PASS"
    passed = "RTL matches ref/matvec_int4.c at every stage" in log
    tot = re.search(r"TOTAL: (\d+) stage \+ (\d+) output values compared, (\d+) mismatches", log)
    if tot and int(tot.group(3)) != 0:
        passed = False
    val = (re.search(r"\(report error\): ([A-Z ]*MISMATCH[^\n]*)", log)
           or re.search(r"tb_matvec_core\.vhd:\d+:\d+:@[^:]*:"
                        r"\((?:assertion|report) failure\): ([^\n]*)", log))
    if val is None and tot and int(tot.group(3)) != 0:
        val = re.match(r"(.*)", "%s mismatches at TOTAL" % tot.group(3))
else:
    passed  = ("%s: PASS" % top) in log
    # the value oracle: this bench's own FAIL lines, or its final tally assert
    val  = re.search(r"%s\.vhd:\d+:\d+:@[^:]*:\((?:report|assertion) (?:error|failure)\):"
                     r"\s*(%s: (?:FAIL|\d+ codebook)[^\n]*)" % (top, top), log)
# the structural oracle: matvec_core's own P_CB_CHK
core = re.search(r"matvec_core\.vhd:\d+:\d+:@[^:]*:\((?:assertion|report) failure\):"
                 r"\s*(matvec_core: [^\n]*)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)
lang  = re.search(r"ghdl[^:]*:error: (.+)", log)

mech = ("v" if val else "") + ("a" if core else "")
if val or core:
    d = (val.group(1) if val else core.group(1)).strip()
    print("KILL|%s|%s" % (mech, d[:64]))
elif passed:
    print("SURV||PASS")
elif bound:
    print("ABRT||%s" % bound.group(1).strip()[:64])
elif re.search(r"simulation stopped by --stop-time|simulation stopped @", log):
    print("ABRT||hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABRT||wall-clock timeout 300s -- never terminated")
elif lang:
    print("ABRT||%s" % lang.group(1).strip()[:64])
else:
    print("ABRT||no PASS line and no error -- no verdict at all")
PY
}

# ---------------------------------------------------------------------------
# 3. mutate <tag> <expect> <desc> [old new]...
#    <expect> is what this script's author predicted, printed alongside the
#    measurement so a surprise is visible rather than absorbed.
# ---------------------------------------------------------------------------
mutate() {
  local tag="$1" expect="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"

  local cols="" any_kill=0 any_abort=0 all_surv=1 detail=""
  local killed_A=0 killed_N=0 killed_S=0
  local m d0 v mech det
  for m in $MODES; do
    local mdir="$dir/$m"
    mkdir -p "$mdir/work"
    # A = everything live.  N = P_CB_CHK demoted, so the question is whether
    # the model catches it alone.  S = P_CB_MODEL demoted, which is EXACTLY the
    # design as it stood before the model was added -- the attribution control.
    # A row that is KILL in A and surv in S is a kill the model EARNED; one
    # that is KILL in S too was already caught and the model only agreed.
    local neut=""
    [ "$m" = N ] && neut="P_CB_CHK"
    [ "$m" = S ] && neut="P_CB_MODEL"
    [ "$m" = X ] && neut="P_CB_CHK,P_CB_MODEL"
    # P = TRACK CBFANOUT's elaboration pin neutered.  See the note in
    # patch_file: this is the attribution control for CHK_CB_RANKS.
    #
    # 2026-09-21, TRACK CBREVERT: CHK_CB_RANKS NO LONGER EXISTS -- 0b34200 is
    # reverted -- so mode P now makes patch_file fail its declaration count and
    # every row in that column lands in the DEAD_TAGS ledger with a nonzero
    # exit.  THAT IS WHY THIS LINE IS KEPT RATHER THAN DELETED.  CBANCHOR's own
    # recorded trap is that "an unknown mode is not an error, it is mode A": if
    # this branch were removed, MODES="A P S" would silently run P as a second
    # unneutered copy of A and print a plausible table.  Failing loudly is the
    # better failure.  Do not put P in MODES on this tree.
    [ "$m" = P ] && neut="CHK_CB_RANKS"
    if [ $# -gt 0 ]; then
      patch_file "$RTL" "$mdir/matvec_core.vhd" "$neut" "$@" || {
        printf '%-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$desc"
        DEAD_TAGS="$DEAD_TAGS $tag"
        return; }
    else
      patch_file "$RTL" "$mdir/matvec_core.vhd" "$neut" || {
        printf '%-6s NEUTER FAILED -- tested nothing -- %s\n' "$tag" "$desc"
        DEAD_TAGS="$DEAD_TAGS $tag"
        return; }
    fi
    local f ok=1
    for f in "$REPO/rtl/util_pkg.vhd" "$REPO/rtl/mv4i_arith_pkg.vhd" \
             "$mdir/matvec_core.vhd" "$REPO/$TB_C" "$REPO/$TB_L" "$REPO/$TB_M"; do
      if ! "$GHDL" -a --std=08 -frelaxed --workdir="$mdir/work" "$f" \
             >>"$mdir/analyze.log" 2>&1; then ok=0; break; fi
    done
    if [ "$ok" = 0 ]; then
      printf '%-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
        "$tag" "$desc"
      DEAD_TAGS="$DEAD_TAGS $tag"
      sed -n 1,3p "$mdir/analyze.log"; return
    fi
    local b top
    for b in C L M; do
      case "$b" in
        C) top=tb_matvec_cb_contract ;;
        L) top=tb_matvec_cb_lockstep ;;
        M) top=tb_matvec_core ;;
      esac
      IFS='|' read -r v mech det <<< "$(run_bench "$mdir" "$top")"
      case "$v" in
        KILL)  cols="$cols $m$b:KILL($mech)"; any_kill=1; all_surv=0
               [ "$m" = A ] && killed_A=1; [ "$m" = N ] && killed_N=1
               [ "$m" = S ] && killed_S=1 ;;
        ABRT)  cols="$cols $m$b:ABRT      "; any_abort=1; all_surv=0
               [ "$m" = A ] && killed_A=1; [ "$m" = N ] && killed_N=1
               [ "$m" = S ] && killed_S=1 ;;
        *)     cols="$cols $m$b:surv      " ;;
      esac
      [ -z "$detail" ] && [ "$v" != SURV ] && detail="$m$b: $det"
    done
  done

  local verdict
  if [ "$all_surv" = 1 ]; then
    verdict="SURVIVED"; NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"
  elif [ "$any_kill" = 1 ]; then
    verdict="KILLED  "; NKILL=$((NKILL+1))
  else
    verdict="ABORTED "; NABORT=$((NABORT+1))
  fi
  if [ "$killed_A" = 1 ] && [ "$killed_N" = 0 ]; then
    ONLY_ASSERT_TAGS="$ONLY_ASSERT_TAGS $tag"
  fi
  # THE ATTRIBUTION CONTROL.  Killed with everything live, and NOT killed with
  # only P_CB_MODEL demoted, means nothing that existed before the model caught
  # it.  Anything not on this list was already covered, and crediting the model
  # with it would overstate what it is worth maintaining.
  if [ "$killed_A" = 1 ] && [ "$killed_S" = 0 ] && [[ " $MODES " == *" S "* ]]; then
    MODEL_EARNED_TAGS="$MODEL_EARNED_TAGS $tag"
  fi
  printf '%-6s %s %s  -- %s\n' "$tag" "$verdict" "$cols" "$desc"
  [ -n "$detail" ] && printf '       %s\n' "$detail"
  printf '       expected: %s\n' "$expect"
}

echo "======================================================================="
echo " sim/mutate_matvec_cb.sh -- the codebook write path"
echo " columns: <mode><bench>   A = all checks live"
echo "   N = P_CB_CHK demoted   -- does P_CB_MODEL catch it alone?"
echo "   S = P_CB_MODEL demoted -- THE ATTRIBUTION CONTROL: the design exactly"
echo "       as it stood before the model was added.  KILL in A and surv in S"
echo "       is the only pattern that credits the model with a detection."
echo " CB_STYLE = '"'"'$CBSTYLE'"'"'  (regs = the shipping register bank + 16:1 mux per"
echo "   lane; distributed = lever C, one codebook copy per LANE)"
echo "   bench C = tb_matvec_cb_contract  L = tb_matvec_cb_lockstep"
echo "         M = tb_matvec_core on the committed sim/tr.txt, vs ref/matvec_int4.c"
echo " KILL(v) = the bench's value oracle;  KILL(a) = matvec_core's assertion"
echo "======================================================================="
echo

# ---------------------------------------------------------------------------
# 4. THE CONTROL.  Unmutated design, same path, all four columns.
# ---------------------------------------------------------------------------
echo "---- CONTROL ----------------------------------------------------------"
mutate CTRL "surv in all four columns" \
  "the UNMUTATED design through this same path"
if [ "$NSURV" != 1 ] && [ -z "$ONLY" ]; then
  echo
  echo "REFUSING TO CONTINUE: the control did not survive.  Every kill below"
  echo "it would be unearned -- it would be measuring this harness's own"
  echo "configuration, not the mutations.  Logs: $SCRATCH/CTRL"
  exit 2
fi
# The control is a row, not a mutation.  Leaving it in the tallies would put
# "CTRL" at the head of the survivor list, which is exactly the list a reader
# scans for things nothing watches.
NSURV=0; NTOT=0; SURV_TAGS=""

echo
echo "---- class K1: ACCEPTANCE -- when is a command captured ----------------"

mutate K1a "KILL, both mechanisms: this is the A-MUT C2 gap this bench closes" \
  "the idle gate is dropped, so writes are accepted while an operation runs" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cb_we = '1' and rst = '0' then"

# MEASURED: SURVIVES, and it is REDUNDANCY rather than a coverage hole.  The
# trailing `if rst = '1' then cbw_v <= (others => '0'); end if;` in the same
# process overrides the capture on the same edge, so the `rst = '0'` term in
# the gate is belt and braces.  K1d removes BOTH and IS killed, which is what
# distinguishes the two cases.  Do not "clean up" either one alone.
mutate K1b "SURVIVE (measured; predicted KILL): the trailing rst clear of cbw_v already covers it -- see K1d" \
  "the reset gate is dropped, so writes are accepted while rst is asserted" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cb_we = '1' and st = S_IDLE then"

mutate K1c "KILL: strictly weaker gate than either of K1a/K1b alone" \
  "both gates dropped: cb_we alone is enough to capture a command" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cb_we = '1' then"

mutate K1d "KILL(v) on C: this is K1b with the redundancy removed, and it is what proves run 5 has teeth" \
  "the reset gate is dropped AND so is the trailing rst clear of cbw_v, so a write offered under reset actually lands" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cb_we = '1' and st = S_IDLE then" \
"      if rst = '1' then
        cbw_v <= (others => '0');
      end if;" \
"      if false then
        cbw_v <= (others => '0');
      end if;"

echo
echo "---- class K2: LATENCY -- where the write sits relative to the watch ---"

# ---------------------------------------------------------------------------
# RE-ANCHORED 2026-09-20 BY TRACK CBANCHOR, after TRACK CBFANOUT (0b34200)
# replicated the write COMMAND per ROW (CB_RANKS) instead of per COPY.  Three
# things moved and all nine rows of classes K2, K3 and K7 died on them:
#
#   1. the command registers are now CB_RANKS wide, not CB_COPIES wide, so
#      every anchor naming "CB_COPIES-1 downto 0" in their declaration died;
#   2. the write reads cbw_*(cb_rank_of(c)), not cbw_*(c);
#   3. THE ONE THAT IS NOT MECHANICAL: the single loop that both WROTE cb and
#      CAPTURED the command was split into two loops with different bounds and
#      different induction variables (c over copies, r over ranks).  Any
#      mutation that added a pipeline stage used to put the stage's own
#      assignments next to the write, in one anchor.  That anchor no longer
#      exists in any form, so K2b and K3c are re-anchored in TWO places each:
#      the write, and the tail of the W0 rank loop.
#
# The body anchors are scoped "@P_CB@" rather than trusted to be unique in the
# file.  P_CB_MODEL contains near-identical text at a different indent, and
# mutating the ORACLE instead of the design would score as a survival.
#
# CORRECTION 2026-09-21, TRACK CBREVERT: 0b34200 IS REVERTED IN THE RTL AND
# THESE NINE ROWS ARE BACK ON THEIR PRE-CHANGE ANCHORS.  Nothing above is
# withdrawn -- it is the record of why they died and what repaired them, and
# the loop-split cause it names is exactly what had to be undone here: K2b and
# K3c go from TWO anchors each back to ONE spanning the write and the command
# capture, because the two loops are one loop again.
#
# WHAT IS KEPT FROM CBANCHOR, DELIBERATELY, BECAUSE IT IS ORTHOGONAL TO THE
# RTL FORM: the "@P_CB@" scopes, the DEAD_TAGS ledger, the per-process neuter
# with its assert census, and the corrected K2b/K2c legends.  MEASURED on the
# reverted tree: every one of the restored anchors matches exactly ONCE in the
# whole file AND exactly once inside P_CB, so the scopes change no verdict
# today and remain the insurance CBANCHOR wrote them to be.  But
# "for c in 0 to CB_COPIES-1 loop" matches TWICE on this tree (P_CB and
# P_CB_MODEL), so the hazard is real and is one careless anchor away.
#
# CB_RANKS, cb_rank_of, cb_ranks_f, cb_rank_chk_f and CHK_CB_RANKS DO NOT
# EXIST on this tree (MEASURED: grep count 0 in rtl/matvec_core.vhd).  Class
# K10 and mode P are therefore RETIRED below rather than re-anchored: their
# subject is gone, which is the one disposition no amount of anchor repair can
# substitute for.
# ---------------------------------------------------------------------------

mutate K2a "KILL(a): the WATCHED register moves, so P_CB_CHK sees st = S_RUN" \
  "the command capture is one cycle late (cb_we registered ahead of the gate)" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbwe_q : std_logic := '0';" \
"@P_CB@        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cbwe_q = '1' and st = S_IDLE and rst = '0' then" \
"@P_CB@      -- rst kills a command in flight but deliberately does NOT clear cb: the" \
"      cbwe_q <= cb_we;
      -- rst kills a command in flight but deliberately does NOT clear cb: the"

# The EXPECTED verdict changed with the re-anchor and the change is recorded
# rather than absorbed.  The legend below is the original one; P_CB_MODEL did
# not exist when it was written, and an extra stage below cbw_v is exactly
# what an independent model of the write path built from the PORTS can see.
# TRACK CBFANOUT measured the same mutation at the new structure under the
# name M5_deepen and reports KILL in A, KILL with the pin off, SURVIVE with
# P_CB_MODEL demoted.  Measured here rather than inherited.
mutate K2b "ORIGINAL LEGEND: SURVIVE -- a stage AFTER cbw_v moves the write without moving the watch point.  NOW EXPECT KILL in A/N and surv in S: P_CB_MODEL was added after that legend and sees the extra stage" \
  "a broadcast stage is added BELOW the command register: cbw_v/a/d are unchanged, the write is one cycle later" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_v2 : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_a2 : cba_arr := (others => (others => '0'));
  signal cbw_d2 : cbd_arr := (others => (others => '0'));" \
"@P_CB@        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v2(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a2(c)))) <= signed(cbw_d2(c));
        end if;
        cbw_v2(c) <= cbw_v(c);
        cbw_a2(c) <= cbw_a(c);
        cbw_d2(c) <= cbw_d(c);"

mutate K2c "ORIGINAL LEGEND: SURVIVE, the write lands one cycle EARLIER, which is still legal.  NOW EXPECT KILL by P_CB_MODEL, which pins the DEPTH at CB_WR_LAT rather than only the legality of the landing cycle.  The fanout fix silently undone, in its most direct form: the port drives all CB_COPIES write enables again" \
  "the command registers are bypassed: cb is written straight from cb_addr/cb_data" \
"@P_CB@        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then
          cb(c)(to_integer(unsigned(cb_addr))) <= signed(cb_data);
        end if;"

echo
echo "---- class K3: LOCKSTEP -- can two replicas hold different tables ------"

mutate K3a "KILL(a) in mode A.  Mode N is the question: does the lane oracle see it alone?" \
  "replica 1 skips a write whenever replica 0 takes one (the A-MUT C1 shape)" \
"@P_CB@        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v(c) = '1' and (c = 0 or cbw_v(0) = '0') then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;"

mutate K3b "KILL in both modes: replicas 1..N never hold anything, so the lanes disagree at the output" \
  "only replica 0 is ever written; the rest keep their initialiser forever" \
"@P_CB@        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v(c) = '1' and c = 0 then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;"

# NOTE THE INDEX.  The split is still over COPIES and not over RANKS, and that
# is the row's meaning rather than an oversight: what P_CB_CHK guards is that
# no two COPIES of cb hold different tables, so the mutation that attacks it
# must skew copies.  A skew over RANKS is a different mutation (TRACK
# CBFANOUT's M4_rankskew) and is not this row.
# 2026-09-21, TRACK CBREVERT: there are no ranks on this tree, so M4_rankskew
# has no subject and the note reduces to its first sentence.  It is kept
# because the sentence is the row's meaning and it did not change.
mutate K3c "KILL(a) only: the divergence is TRANSIENT, so a per-cycle assertion sees it and an output oracle cannot" \
  "the upper half of the replica bank writes one cycle late -- the shape a two-level command broadcast tree produces, which is what 1,536 replicas would need" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_v2 : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_a2 : cba_arr := (others => (others => '0'));
  signal cbw_d2 : cbd_arr := (others => (others => '0'));" \
"@P_CB@        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if c < CB_COPIES/2 then
          if cbw_v(c) = '1' then
            cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
          end if;
        else
          if cbw_v2(c) = '1' then
            cb(c)(to_integer(unsigned(cbw_a2(c)))) <= signed(cbw_d2(c));
          end if;
        end if;
        cbw_v2(c) <= cbw_v(c);
        cbw_a2(c) <= cbw_a(c);
        cbw_d2(c) <= cbw_d(c);"

# K3d WAS NOT TRACK CBFANOUT'S M1_collapse, AND ON THIS TREE M1_collapse HAS
# NO SUBJECT AT ALL.  That note read: M1_collapse rewrites cb_rank_of to return
# 0, so the elaboration pin fires and no bench ever runs, whereas K3d leaves
# the map alone and takes the address and data of the write from copy 0 at the
# WRITE SITE, which the pin cannot see.  2026-09-21, TRACK CBREVERT: the map
# and the pin are both reverted out of the RTL, so only the second half is
# still a statement about anything.  K3d is unchanged in meaning and is the
# pure behavioural equivalent mutant it has always been: nothing in the
# functional closure can tell a master/follower codebook from a replicated one.
# It is also, now, the ONLY row in this harness that models the fanout
# collapse, K10b having been retired with the construct it mutated.
mutate K3d "SURVIVE: a true equivalent mutant today, because every command register holds the same command.  Named so the master/follower design is not silently reachable" \
  "every replica writes off replica 0's command registers (master/follower, the design the RTL comment rejects by construction)" \
"@P_CB@          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
"          cb(c)(to_integer(unsigned(cbw_a(0)))) <= signed(cbw_d(0));"

echo
echo "---- class K4: INTERLOCK -- cb_we in S_IDLE is not a start edge --------"

mutate K4a "KILL: run 7a holds cb_we high with start high and requires no done" \
  "the empty cb_we arm of the main process is deleted, so start can be honoured on the same edge as a codebook write (the A-MUT C3 shape)" \
"      elsif cb_we = '1' and st = S_IDLE then" \
"      elsif false then"

echo
echo "---- class K5: POWER-UP -- what an un-loaded codebook holds -------------"

mutate K5a "KILL: run 0 requires an un-loaded codebook to emit zero" \
  "cb loses its initialiser -- the LUTRAM INIT string, which distributed RAM has instead of a reset" \
"  signal cb : cb_bank_t := (others => (others => (others => '0')));" \
"  signal cb : cb_bank_t;"

mutate K5b "KILL: same property, non-metavalue form" \
  "cb initialises to all ones rather than all zeros" \
"  signal cb : cb_bank_t := (others => (others => (others => '0')));" \
"  signal cb : cb_bank_t := (others => (others => (others => '1')));"

echo
echo "---- class K6: RESET -- the table outlives it --------------------------"

mutate K6a "KILL(v) on C: run 6 pulses rst between two runs and requires the same answer" \
  "rst clears the codebook, so a host that loaded it once at bring-up silently loses it" \
"      if rst = '1' then
        cbw_v <= (others => '0');
      end if;" \
"      if rst = '1' then
        cbw_v <= (others => '0');
        cb <= (others => (others => (others => '0')));
      end if;"

echo
echo "---- class K7: ADDRESS -- which entry a command writes ------------------"

# MEASURED: killed by bench M ONLY.  The prediction that C would catch it was
# wrong, and the reason is the one structural fact about this bench worth
# carrying away: C and L are RELATIONAL.  Every load is corrupted the SAME way,
# so every run agrees with every other run and the whole self-consistent world
# is wrong together.  Only an ABSOLUTE oracle -- ref/matvec_int4.c -- has an
# opinion about what the table should contain.
mutate K7a "KILL(v) on M ONLY (measured; predicted C too): a table wrong the same way every time is invisible to a relational bench" \
  "the write address is taken LIVE from cb_addr instead of the registered cbw_a" \
"@P_CB@          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
"          cb(c)(to_integer(unsigned(cb_addr))) <= signed(cbw_d(c));"

mutate K7b "KILL(v) on M only: C and L are relational and cannot see a table that is wrong the same way every time" \
  "the write data is taken LIVE from cb_data instead of the registered cbw_d" \
"@P_CB@          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
"          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cb_data);"

echo
echo "---- class K8: THE REPLICA SELECT -- protected by coherency, by nothing else"

mutate K8a "SURVIVE: equivalent while the replicas are coherent, which is the whole point of the row" \
  "every row reads replica 0 (the per-row replication undone at the READ side)" \
"                resize(cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) * xw, 28);" \
"                resize(cb(0)(idx) * xw, 28);"

mutate K8b "SURVIVE: same reason as K8a, and the pair is the evidence that NO functional bench can test the select" \
  "the replica select is rotated by one, so every row reads its neighbour's copy" \
"                resize(cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) * xw, 28);" \
"                resize(cb(((rr*BLK + j) / CB_LANES_PER_COPY + 1) mod CB_COPIES)(idx) * xw, 28);"

echo
echo "---- class K9: PER-LANE STALENESS -- the lever-C failure mode, MODELLED --"
echo "     Today there is one replica per ROW, so a single LANE cannot hold a"
echo "     stale table.  Lever C gives every lane its own copy and makes that"
echo "     the primary failure mode.  This row models the RESULT of it -- one"
echo "     lane decoding one entry differently from every other lane -- so the"
echo "     claim that the oracle is ready for lever C is demonstrated rather"
echo "     than argued.  The N column is the one that matters: it says the"
echo "     lane-equality oracle catches it WITHOUT P_CB_CHK."

mutate K9a "KILL(v) in BOTH modes on C: the lane-equality oracle localises to the single lane, with no help from P_CB_CHK" \
  "lane (rr=1, j=0) decodes one entry one step off -- what a single stale per-lane replica looks like at the read" \
"              tr(0)(rr*BLK + j) <=
                resize(cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) * xw, 28);" \
"              if rr = 1 and j = 0 then
                tr(0)(rr*BLK + j) <=
                  resize((cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) + 1) * xw, 28);
              else
                tr(0)(rr*BLK + j) <=
                  resize(cb((rr*BLK + j) / CB_LANES_PER_COPY)(idx) * xw, 28);
              end if;"

echo
echo "---- class K10: RETIRED 2026-09-21 -- ITS SUBJECT IS REVERTED OUT ------"
echo "     TRACK CBREVERT: 0b34200 is reverted in rtl/matvec_core.vhd, so"
echo "     CB_RANKS, cb_rank_of, cb_ranks_f, cb_rank_chk_f and CHK_CB_RANKS do"
echo "     NOT EXIST on this tree (MEASURED: grep count 0).  K10a and K10b"
echo "     mutate a constant declaration that is gone, and mode P neuters a"
echo "     pin that is gone.  RETIRE is the only honest disposition: an anchor"
echo "     cannot be repaired onto a construct that was deleted, and leaving"
echo "     the rows in would put two dead-anchor lines in the ledger on every"
echo "     run -- loud, but permanently loud, which trains a reader to ignore"
echo "     the ledger.  (The failure strings themselves are deliberately NOT"
echo "     spelled out in this narrative: a log that contains the needle a"
echo "     reader greps for is this project's recorded self-match trap.)"
echo "     They are commented out below WITH THEIR ANCHORS"
echo "     VERBATIM: if the per-row codebook is ever rebuilt, uncommenting"
echo "     them is the whole of the repair."
echo "     WHAT IS LOST BY RETIRING THEM, STATED RATHER THAN ABSORBED: the"
echo "     only instrument that could see the copy-to-rank map at all.  K3d"
echo "     remains and models the collapse at the write site instead, and it"
echo "     SURVIVES -- which is the same resolution floor reported from the"
echo "     other side.  Nothing in this harness now scores a fanout lever."
echo
echo "     THE RETIRED NARRATIVE, KEPT BECAUSE THE FLOOR IT DESCRIBES IS REAL:"
echo "     TRACK CBFANOUT (0b34200) replicated the write COMMAND per ROW"
echo "     instead of per COPY, cutting max fanout per command bit 1,536 -> 48"
echo "     on the net that carried all ten worst paths of the FAILED build 10."
echo "     Because every rank holds the SAME command, any surjection copy ->"
echo "     rank is functionally identical, so NO simulation can score the map."
echo "     That is a resolution floor, and it is exactly the condition this"
echo "     project calls its standing failure class: a lever that does nothing"
echo "     and looks like it worked.  The only instrument is the elaboration"
echo "     pin CHK_CB_RANKS, and mode P is its attribution control."
echo "     THESE ROWS EXIST BECAUSE CBFANOUT'S OWN TEETH TABLE WAS NOT"
echo "     REPRODUCIBLE FROM THE REPO: its M-rows lived in a scratch harness"
echo "     that was never committed.  Run with MODES=\"A P S\"."
echo
echo "     THEY BITE ONLY AT CBSTYLE=distributed, AND THE REASON IS THE BENCH"
echo "     GEOMETRY RATHER THAN THE PIN.  MEASURED 2026-09-20, TRACK CBANCHOR:"
echo "     at CBSTYLE=regs both rows SURVIVE all twelve columns.  tb_matvec_core"
echo "     runs ROWS_IF=4 BLK=32, so regs gives CB_LANES_PER_COPY=32 and"
echo "     CB_COPIES=4 -- and then CB_RANKS is already 4, so K10a is LITERALLY"
echo "     THE IDENTITY, and CB_RANKS=1 still satisfies both halves of the"
echo "     fanout bound (1 <= ROWS_IF=4 and 4/1 <= BLK=32), so K10b is a legal"
echo "     configuration rather than a defect.  That is the pin behaving"
echo "     correctly: at four copies there is no fanout problem to have.  It is"
echo "     recorded because the harness DEFAULTS to CBSTYLE=regs, so a reader"
echo "     running it with no environment set sees two SURVIVED rows and could"
echo "     conclude the pin has no teeth.  It has teeth at the geometry that"
echo "     ships (CB_COPIES=1,536), and CBSTYLE=distributed is the nearest"
echo "     reachable proxy for it."

# RETIRED 2026-09-21 BY TRACK CBREVERT.  Verbatim, anchors included.  Both
# rows were MEASURED green by TRACK CBANCHOR at CBSTYLE=distributed
# (ABRT(pin) in A, N and S; SURVIVE all three benches in P), so what follows
# is a working pair of rows waiting for its RTL, not a draft.
#
# mutate K10a "ABRT(pin) in A and S, surv in P: the pin is the sole witness.  This is CBFANOUT's M2_percopy, verified independently  MEASURED at CBSTYLE=distributed (CB_COPIES=64).  At CBSTYLE=regs this mutation is the IDENTITY and SURVIVES -- see the class note." \
#   "CB_RANKS forced back to CB_COPIES -- the fanout fix undone, i.e. exactly the structure build 10 built and failed at WNS -5.819 ns" \
# "  constant CB_RANKS : positive := cb_ranks_f(CB_COPIES, ROWS_IF);" \
# "  constant CB_RANKS : positive := CB_COPIES;"
#
# mutate K10b "ABRT(pin) in A and S, surv in P: same as K10a at the other extreme.  This is CBFANOUT's M1_collapse, and it is K3d expressed in the map rather than at the write site  MEASURED at CBSTYLE=distributed (CB_COPIES=64).  At CBSTYLE=regs CB_RANKS=1 is inside the fanout bound and SURVIVES -- see the class note." \
#   "CB_RANKS forced to 1 -- one command register for all CB_COPIES copies, max fanout 1,536 again from the other end" \
# "  constant CB_RANKS : positive := cb_ranks_f(CB_COPIES, ROWS_IF);" \
# "  constant CB_RANKS : positive := 1;"

echo
echo "---- CANNOT BITE YET -- becomes live only under the LUTRAM fallback ----"
cat <<'LEVERC'
     These are NOT runnable rows.  Each names a mutation that the current
     structure has nothing to be false about, states what makes it live under
     lever C, and names the instrument that would catch it.  They are kept
     here rather than in a document because the person who takes lever C will
     read this file.

     L1  WRITE_MODE at the same address.  `cb` is a flop array read
         combinationally, so a read concurrent with a write has exactly one
         semantics and no attribute selects it.  Distributed RAM has a real
         WRITE_MODE.  NOT reachable from a behavioural bench either -- a VHDL
         array model reproduces whatever the code says, not what the primitive
         does.  Instrument: post-synthesis simulation against the UNISIM
         model, or an OOC netlist read.  There is no simulation-only substitute.

     L2  The RAM INIT string.  K5a and K5b cover the BEHAVIOURAL half: the
         initialiser must exist and must be zero, and run 0 of
         tb_matvec_cb_contract is what enforces it.  Whether Vivado actually
         emits INIT_00.. on the inferred RAM, rather than dropping it, is
         invisible to GHDL.  Instrument: OOC synth plus a netlist property
         read.  NOTE this is the one lever-C risk the CURRENT design has
         already retired: `rst` deliberately does not clear `cb` (see K6a), so
         the reset behaviour is already what distributed RAM can offer.

     L3  Did the tool actually build the replicas?  Today `dont_touch` on `cb`
         is what stops equivalent-register-removal merging them back into one.
         A RAM has no such merge, but a tool that cannot see the copy select
         as lane-static can infer ONE table with many read ports, which is the
         pre-fix design wearing the new structure's name.  Invisible to every
         simulation.  Instrument: report_utilization RAMD/RAMS counts against
         DERIVED expected = CB_COPIES * 16 * 8 bits.

     L4  The physical write-enable decode at 1,536 replicas.  K3c is the
         BEHAVIOURAL proxy and it is live today -- and it is the only row in
         the table above that NOTHING but P_CB_CHK catches.  What cannot bite
         today is the physical half: whether the enable tree that lever C
         needs, in order not to reintroduce the 1,536-fanout net this whole
         change exists to remove, is balanced.  Instrument: STA, not
         simulation.

     THE ONE INSTRUCTION FOR WHOEVER TAKES LEVER C, and it comes out of K2b
     rather than out of judgement: P_CB_CHK's `st` invariant watches
     `cbw_v(0)`, which is the command register and NOT the write.  K2b adds a
     broadcast stage BELOW that register -- exactly the shape a 1,536-replica
     command path needs -- and SURVIVES all six columns.  If lever C deepens
     the command path, the invariant must be re-aimed at the LAST stage, or it
     becomes vacuous without any test noticing.

     THE ORACLE IS ALREADY LEVER-C READY, and this is the reason for the
     shape.  tb_matvec_cb_contract drives every row with IDENTICAL nibbles,
     scale and activations, so any replica that goes stale changes exactly the
     rows that read it.  Under per-lane replicas a stale lane (rr,j) changes
     row rr's tree sum and the lane-equality oracle sees it with no change to
     the bench.  What it still cannot see is a TRANSIENT divergence during a
     load -- that is K3c, and that is P_CB_CHK's job for good.
LEVERC

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORTED = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
echo "survivors (nothing in the closure watches these):$SURV_TAGS"
echo "killed ONLY with P_CB_CHK live (the assertion is the sole witness):$ONLY_ASSERT_TAGS"
echo "ATTRIBUTION CONTROL -- killed in A and NOT in S, so P_CB_MODEL earned it"
echo "  and nothing that existed before it would have caught it:$MODEL_EARNED_TAGS"
echo "scratch dir with every mutant and all four logs: $SCRATCH"
echo "======================================================================="

# THE LEDGER, PRINTED AND ENFORCED.  A row that did not run is not a pass and
# is not a survival; it is missing evidence, and it must be impossible to read
# this output and not see it.
if [ -n "$DEAD_TAGS" ]; then
  echo
  echo "=== ROWS THAT DID NOT RUN:$(set -- $DEAD_TAGS; echo $#) ==="
  echo "   $DEAD_TAGS"
  echo "Each printed ANCHOR FAILED / NEUTER FAILED / DID NOT ANALYZE above and"
  echo "tested NOTHING.  They are counted in the total and in no verdict, so"
  echo "the tallies above do not add up and that is deliberate.  Exiting 1."
  exit 1
fi
echo "=== every anchor matched; no row was skipped ==="
