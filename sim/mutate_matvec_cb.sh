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
MODES="${MODES:-A N}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""
ONLY_ASSERT_TAGS=""

# ---------------------------------------------------------------------------
# 1. THE PATCHER.  A mutation whose anchor is not unique has tested nothing, so
#    a non-unique or absent anchor is a hard error, never a silent skip.
#    `--neuter` additionally demotes P_CB_CHK's assertions, and it is applied
#    to a region located by its process name rather than by line number.
# ---------------------------------------------------------------------------
patch_file() {  # patch_file <src> <dst> <neuter 0|1> [old new]...
  python3 - "$@" <<'PY'
import sys
src, dst, neuter = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
pairs = sys.argv[4:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i // 2, n))
        sys.exit(2)
    s = s.replace(old, new)
if neuter:
    a = s.index("P_CB_CHK : process(clk)")
    b = s.index("end process;", a)
    region = s[a:b]
    if region.count("severity failure;") != 3:
        sys.stderr.write("NEUTER: expected 3 asserts in P_CB_CHK, found %d\n"
                         % region.count("severity failure;"))
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
  local killed_A=0 killed_N=0
  local m d0 v mech det
  for m in $MODES; do
    local mdir="$dir/$m"
    mkdir -p "$mdir/work"
    local neut=0; [ "$m" = N ] && neut=1
    if [ $# -gt 0 ]; then
      patch_file "$RTL" "$mdir/matvec_core.vhd" "$neut" "$@" || {
        printf '%-6s ANCHOR FAILED -- tested nothing -- %s\n' "$tag" "$desc"
        return; }
    else
      patch_file "$RTL" "$mdir/matvec_core.vhd" "$neut" || {
        printf '%-6s NEUTER FAILED -- tested nothing -- %s\n' "$tag" "$desc"
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
               [ "$m" = A ] && killed_A=1; [ "$m" = N ] && killed_N=1 ;;
        ABRT)  cols="$cols $m$b:ABRT      "; any_abort=1; all_surv=0
               [ "$m" = A ] && killed_A=1; [ "$m" = N ] && killed_N=1 ;;
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
  printf '%-6s %s %s  -- %s\n' "$tag" "$verdict" "$cols" "$desc"
  [ -n "$detail" ] && printf '       %s\n' "$detail"
  printf '       expected: %s\n' "$expect"
}

echo "======================================================================="
echo " sim/mutate_matvec_cb.sh -- the codebook write path"
echo " columns: <mode><bench>  mode A = P_CB_CHK live, N = its asserts demoted"
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

mutate K2a "KILL(a): the WATCHED register moves, so P_CB_CHK sees st = S_RUN" \
  "the command capture is one cycle late (cb_we registered ahead of the gate)" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbwe_q : std_logic := '0';" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cbwe_q = '1' and st = S_IDLE and rst = '0' then" \
"      -- rst kills a command in flight but deliberately does NOT clear cb: the" \
"      cbwe_q <= cb_we;
      -- rst kills a command in flight but deliberately does NOT clear cb: the"

mutate K2b "SURVIVE -- and that is the finding.  A stage AFTER cbw_v moves the write without moving the watch point" \
  "a broadcast stage is added BELOW the command register: cbw_v/a/d are unchanged, the write is one cycle later" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_v2 : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_a2 : cba_arr := (others => (others => '0'));
  signal cbw_d2 : cbd_arr := (others => (others => '0'));" \
"        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v2(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a2(c)))) <= signed(cbw_d2(c));
        end if;
        cbw_v2(c) <= cbw_v(c);
        cbw_a2(c) <= cbw_a(c);
        cbw_d2(c) <= cbw_d(c);"

mutate K2c "SURVIVE: the write lands one cycle EARLIER, which is still legal.  The fanout fix silently undone" \
  "the command registers are bypassed: cb is written straight from cb_addr/cb_data" \
"        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then
          cb(c)(to_integer(unsigned(cb_addr))) <= signed(cb_data);
        end if;"

echo
echo "---- class K3: LOCKSTEP -- can two replicas hold different tables ------"

mutate K3a "KILL(a) in mode A.  Mode N is the question: does the lane oracle see it alone?" \
  "replica 1 skips a write whenever replica 0 takes one (the A-MUT C1 shape)" \
"        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v(c) = '1' and (c = 0 or cbw_v(0) = '0') then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;"

mutate K3b "KILL in both modes: replicas 1..N never hold anything, so the lanes disagree at the output" \
  "only replica 0 is ever written; the rest keep their initialiser forever" \
"        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v(c) = '1' and c = 0 then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;"

mutate K3c "KILL(a) only: the divergence is TRANSIENT, so a per-cycle assertion sees it and an output oracle cannot" \
  "the upper half of the replica bank writes one cycle late -- the shape a two-level command broadcast tree produces, which is what 1,536 replicas would need" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');" \
"  signal cbw_v : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_v2 : std_logic_vector(CB_COPIES-1 downto 0) := (others => '0');
  signal cbw_a2 : cba_arr := (others => (others => '0'));
  signal cbw_d2 : cbd_arr := (others => (others => '0'));" \
"        if cbw_v(c) = '1' then
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

mutate K3d "SURVIVE: a true equivalent mutant today, because every command register holds the same command.  Named so the master/follower design is not silently reachable" \
  "every replica writes off replica 0's command registers (master/follower, the design the RTL comment rejects by construction)" \
"          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
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
"          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
"          cb(c)(to_integer(unsigned(cb_addr))) <= signed(cbw_d(c));"

mutate K7b "KILL(v) on M only: C and L are relational and cannot see a table that is wrong the same way every time" \
  "the write data is taken LIVE from cb_data instead of the registered cbw_d" \
"          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));" \
"          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cb_data);"

echo
echo "---- class K8: THE REPLICA SELECT -- protected by coherency, by nothing else"

mutate K8a "SURVIVE: equivalent while the replicas are coherent, which is the whole point of the row" \
  "every row reads replica 0 (the per-row replication undone at the READ side)" \
"                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);" \
"                resize(cb(0)(idx) * xw, 28);"

mutate K8b "SURVIVE: same reason as K8a, and the pair is the evidence that NO functional bench can test the select" \
  "the replica select is rotated by one, so every row reads its neighbour's copy" \
"                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);" \
"                resize(cb((rr / CB_ROWS_PER_COPY + 1) mod CB_COPIES)(idx) * xw, 28);"

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
                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);" \
"              if rr = 1 and j = 0 then
                tr(0)(rr*BLK + j) <=
                  resize((cb(rr / CB_ROWS_PER_COPY)(idx) + 1) * xw, 28);
              else
                tr(0)(rr*BLK + j) <=
                  resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);
              end if;"

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
echo "scratch dir with every mutant and all four logs: $SCRATCH"
echo "======================================================================="
