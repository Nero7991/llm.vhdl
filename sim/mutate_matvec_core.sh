#!/usr/bin/env bash
# Mutation test for rtl/matvec_core.vhd -- subsystem A's arithmetic core.
#
# WHY THIS EXISTS.  Before 2026-08-29 subsystem A had ZERO mutation scripts
# while subsystem B had thirty, and A is the only subsystem that has ever been
# put into an FK33 bitstream (hw/fk33/rtl/fk33_engine.vhd), is 67.98% of the
# design's LUT and 99.94% of its DSP, and is the unit every other track's
# oracle leans on because ref/matvec_int4.c is treated as trusted throughout
# the tree.  The verification culture here is strong and had simply never been
# pointed at A.
#
# ---------------------------------------------------------------------------
# WHAT sim/tb_matvec_core ACTUALLY CHECKS, read out of the file before anything
# was mutated
# ---------------------------------------------------------------------------
# It is a STAGE-LEVEL value oracle, and it is the good kind: every expected
# intermediate comes from `ref/matvec_int4 --trace`, so there is no
# hand-written expectation anywhere and a divergence localizes to one stage
# (PARTIAL / CONTRIB / ACC / YMANT / YDATA / NS / YEXP / SATEV) rather than
# appearing as a wrong output that has to be bisected.  Eight passes:
#
#   PASS 1  BFP      "00"  n_rows = trace M
#   PASS 2  PARTIAL  "10"  n_rows = trace M
#   PASS 3  BFP      "00"  n_rows = MAXR      (64, top of the declared range)
#   PASS 4  RAW      "01"  n_rows = trace M
#   PASS 5  RAW      "01"  n_rows = MAXR-RI+1 (61, ragged top tile)
#   PASS 6  RAW      "01"  n_rows = MAXR      (64, full top tile)
#   PASS 7  PARTIAL  "10"  n_rows = MAXR+1    (65, above MAXROWS_BFP)
#   PASS 8  RAW      "01"  n_rows = MAXR+1    (65, above MAXROWS_BFP, OI-10)
#
# It ends with `assert nbad = 0 and ybad = 0` at severity failure, so the
# VALUE contract has real teeth.  This script does not add a gate; it measures
# the one that is already there.
#
# ---------------------------------------------------------------------------
# THE STIMULUS IS THE LIMIT, NOT THE CHECKER -- AND THAT IS THIS SCRIPT'S
# CENTRAL RESULT
# ---------------------------------------------------------------------------
# sim/regress.sh:778 runs this bench with `-gTRACE=../tr.txt`, and sim/tr.txt
# is ONE committed file.  MEASURED, by decoding its own header:
#
#     DIMS 8 96 3 3 2 5 4       M=8  K=96  NB=3  out_shift=3 w_exp=2 x_exp=5 RI=4
#     SATEV 0
#
# Three properties of that shape decide what the gate can and cannot see, and
# none of them is a property of the checker:
#
#   (1) K = 96 = 3 * 32 EXACTLY, so the last scale block is FULL.  Spec 6.2's
#       COLUMN MASK -- `if k < n_cols` at rtl/matvec_core.vhd:699, which exists
#       because the IQ4_NL codebook has no zero entry and index 0 decodes to
#       -127, so padding must be MASKED and never zero-filled -- is never
#       exercised.  Not weakly exercised: there is not one masked column in the
#       entire gate run.
#   (2) M = 8 = 2 * 4 EXACTLY, and PASS 3 uses n_rows = 64 = 16 * 4.  Those are
#       the only two BFP passes, so NO BFP PASS EVER HAS A RAGGED TILE, and the
#       pad mask in the amax fold (`if re3_ok(rr) = '1'` at :880, whose comment
#       says "a pad row folded into amax would inflate ns and crush every real
#       mantissa") is never exercised either.  PASSES 5 and 6 do have a ragged
#       tile, but they are RAW, and raw mode computes no amax and no ns at all.
#   (3) SATEV 0, and NB = 3.  ref/matvec_int4.c has an ADVERSARIAL trace mode
#       (`--trace out M K RI 1`) built specifically so sat_event is compared
#       against something other than zero -- its own comment says "Without it
#       the flag was wired through three testbenches and never once compared,
#       which is how the RTL came to assert it in PARTIAL mode ... undetected".
#       The gate does not use it.  MEASURED, the mode needs NB > 16 to reach
#       2^31 at all: `--trace t 8 96 4 1` still yields SATEV 0, and only
#       `--trace t 8 1024 4 1` yields SATEV 1.
#
# So this script runs every mutation against THREE traces and reports which
# one killed it.  The A column is what sim/regress.sh sees today; anything
# killed only by P or S is a hole in the STIMULUS that the checker would have
# caught for free had it been fed.
#
# MEASURED, 2026-08-29, 57 mutations, after the two bench strengthenings this
# script's own survivors motivated (see sim/tb_matvec_core.vhd's xmem poison
# and PASS 9):
#
#     trace A alone kills 36 of 57      <- what sim/regress.sh sees today
#     trace P alone kills 40 of 57
#     trace S alone kills 30 of 57
#     union            44 of 57 (36 KILLED + 8 ABORT), 13 survivors
#
#     killed by P but NOT by A:  D1 D2 D18 B13
#     killed by S but NOT by A:  D16 B10 R3 A5
#     killed by A but SURVIVING S: D5 D11 D14 D17 B4 B7 R7 A1 A2 A3
#
# READ THE LAST LINE OF THAT BLOCK BEFORE ASSUMING THE ADVERSARIAL TRACE IS
# THE STRONG ONE.  It is the WEAKEST of the three.  Its construction puts the
# SAME number in every product in the array, so a rounding-mode change is
# invisible (everything is already at the rail) and a structural adder-tree
# change is invisible by symmetry -- D5 drops the odd operand of a node, and
# 2*p equals p+p.  Saturation coverage and value diversity are opposed, and
# no single trace supplies both.  S must be run ALONGSIDE a diverse trace,
# never instead of one.
#
#   A  `--trace t 8   96 4 0`  the committed gate trace.  VERIFIED byte-for-byte
#                              identical to sim/tr.txt on every run, and the
#                              script REFUSES TO RUN if it is not -- otherwise
#                              the A column would not be a statement about the
#                              gate.
#   P  `--trace t 6  100 4 0`  RAGGED both ways.  M=6 is not a multiple of RI=4,
#                              so PASS 1 and PASS 2 have a ragged tile in BFP;
#                              K=100 is not a multiple of BLK=32, so the last
#                              block carries 28 MASKED columns.  M=6 <= 60 is
#                              required: the bench's shape-override passes score
#                              rows at and above the trace's M against ZERO, so
#                              a trace with M > MAXR-RI is misjudged by the
#                              bench itself, not by the RTL.  (MEASURED: a
#                              64x1024 trace makes the HONEST core report
#                              STAGE MISMATCH PARTIAL r=61.  See the trap
#                              section of the debugging note.)
#   S  `--trace t 8 1024 4 1`  ADVERSARIAL: every weight at codebook index 0
#                              (-127), every scale 32767, every activation
#                              -32768, out_shift 0.  NB=32 drives acc past 2^31
#                              so sat32 clamps on every row.  SATEV 1.
#
# ---------------------------------------------------------------------------
# BRANCH TAGGING
# ---------------------------------------------------------------------------
# matvec_core's out_mode branches are MUTUALLY EXCLUSIVE and the bench drives
# all three, so an untagged table would read as a poor kill rate when the real
# statement is per-branch.  Every row carries the branch that elaborates the
# mutated line:
#
#   ALL      every pass reaches it (the shared datapath: products, adder tree,
#            scale multiply, floor_shr, accumulate, row end stages 1-3)
#   BFP      out_mode = "00" only: ybuf, S_SCAN, ns, S_EMIT, sat16   (P1, P3)
#   RAW      out_mode = "01" only                                     (P4,5,6,8)
#   PART     out_mode = "10" only                                     (P2, P7)
#   NOTBFP   the `out_mode /= "00"` y_we path                          (RAW+PART)
#   IDLE     the S_IDLE descriptor check, before any mode is chosen
#   CB       the codebook write path and its P_CB_CHK invariants
#
# ---------------------------------------------------------------------------
# THREE VERDICTS.  ABORT IS COUNTED AS A KILL BUT REPORTED SEPARATELY.
# ---------------------------------------------------------------------------
# A harness that scores "no MISMATCH line" as a pass reports a run that DIED
# as a survivor.  Three tracks discovered that independently on 2026-08-28.
# Here:
#   KILL   the bench printed a nonzero mismatch count, or fired one of its own
#          severity-failure asserts (COVERAGE, y_exp, SAT_EVENT, err).
#   ABORT  ghdl stopped the run: an out-of-bounds index, a range violation, a
#          timeout, or no TOTAL line at all.  Counted as a kill -- the mutant
#          did not survive -- but it is worth LESS than a KILL, because it is
#          the language noticing rather than the checker, and in hardware the
#          same mutation would silently read a neighbouring array entry.
#   SURV   the bench printed its final "RTL matches ref/matvec_int4.c at every
#          stage, in all three out_mode values" line with zero mismatches.
#
# ---------------------------------------------------------------------------
# NOTHING UNDER rtl/ OR ref/ IS EDITED.  Every mutation is applied to a COPY in
# a private scratch directory.  ref/matvec_int4.c is READ as the oracle and
# compiled from a copy; TRACK RY-ORACLE owns it.
# ---------------------------------------------------------------------------
#
# Usage: bash sim/mutate_matvec_core.sh
# Env:   SCRATCH=<dir>   ONLY=<tag-substring>   TRACES="A P S"
set -uo pipefail

# SELF-ISOLATE.  bash reads a script lazily by byte offset, so an edit to this
# file while an instance runs resumes the shell mid-token.  sim/regress.sh:287
# does the same thing for the same reason.  MUT_ISOLATED guards the re-exec.
if [ -z "${MUT_ISOLATED:-}" ]; then
  __self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  __tmp="$(mktemp -t mutate_matvec_core.XXXXXX.sh)"
  cp "$__self" "$__tmp" || exit 2
  if ! bash -n "$__tmp" 2>/dev/null; then
    echo "mutate_matvec_core.sh: the private copy does not parse -- the" \
         "original was probably mid-write.  Refusing to run." >&2
    rm -f "$__tmp"; exit 2
  fi
  export MUT_ISOLATED=1 MUT_REAL_DIR="$(dirname "$__self")"
  bash "$__tmp" "$@"; __rc=$?
  rm -f "$__tmp"; exit $__rc
fi

cd "${MUT_REAL_DIR:-$(dirname "$0")}/.."
REPO="$PWD"
RTL=rtl/matvec_core.vhd
ARITH=rtl/mv4i_arith_pkg.vhd
REF=ref/matvec_int4.c
TB=sim/tb_matvec_core.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
ONLY="${ONLY:-}"
TRACES="${TRACES:-A P S}"
GHDL="${GHDL:-ghdl}"
mkdir -p "$SCRATCH"

NKILL=0; NABORT=0; NSURV=0; NTOT=0
SURV_TAGS=""

# ---------------------------------------------------------------------------
# 0. THE ORACLE, AND THE SELF-TEST THAT MAKES THE `A` COLUMN MEAN ANYTHING
# ---------------------------------------------------------------------------
echo "=== building ref/matvec_int4.c (READ ONLY -- compiled from a copy) ==="
cp "$REF" "$SCRATCH/matvec_int4_oracle.c"
if ! cc -O2 -w -I ref -o "$SCRATCH/mv4i" "$SCRATCH/matvec_int4_oracle.c" -lm \
        2>"$SCRATCH/oracle_cc.log"; then
  echo "ORACLE DID NOT BUILD -- nothing below would mean anything:"
  sed -n 1,10p "$SCRATCH/oracle_cc.log"; exit 2
fi

gen_trace() {  # gen_trace <name> <M> <K> <RI> <sat>
  "$SCRATCH/mv4i" --trace "$SCRATCH/tr_$1.txt" "$2" "$3" "$4" "$5" >/dev/null \
    || { echo "trace $1 generation FAILED"; exit 2; }
}
gen_trace A 8   96 4 0
gen_trace P 6  100 4 0
gen_trace S 8 1024 4 1

if ! cmp -s "$SCRATCH/tr_A.txt" sim/tr.txt; then
  echo "REFUSING TO RUN: trace A is not byte-identical to sim/tr.txt."
  echo "The A column's whole claim is that it is the trace sim/regress.sh:778"
  echo "gates on.  Without that this script measures nothing about the gate."
  exit 2
fi
echo "trace A byte-identical to sim/tr.txt  (MEASURED, this run)"
for t in A P S; do
  printf 'trace %s  %s  %s\n' "$t" \
    "$(grep -m1 '^DIMS' "$SCRATCH/tr_$t.txt")" \
    "$(grep -m1 '^SATEV' "$SCRATCH/tr_$t.txt")"
done
echo

# ---------------------------------------------------------------------------
# 1. THE PATCHER.  A mutation whose anchor is not unique has tested nothing,
#    so a non-unique or absent anchor is a hard error, never a silent skip.
# ---------------------------------------------------------------------------
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
# 2. RUN ONE MUTANT AGAINST ONE TRACE
# ---------------------------------------------------------------------------
run_trace() {  # run_trace <dir> <trace-letter> ; echoes  verdict|detail
  local dir="$1" t="$2"
  local rd="$dir/run_$t"
  mkdir -p "$rd"
  # --stop-time=2ms is 65x the longest HONEST run (MEASURED: trace A finishes
  # at 4.905 us, P at 5.785 us, S at 30.425 us), so a mutation that HANGS --
  # B11 and B12 both do -- is caught by simulated time in seconds rather than
  # by a wall-clock timeout in minutes.  The wall-clock timeout stays as a
  # backstop for a mutation that makes the simulator itself diverge.
  ( cd "$rd" && timeout 240 "$GHDL" -r --std=08 -frelaxed --workdir="$dir/work" \
      tb_matvec_core -gTRACE="$SCRATCH/tr_$t.txt" -gRI=4 -gSTALL=0 \
      --stop-time=2ms --stop-delta=2000000 ) >"$dir/log_$t" 2>&1
  local rc=$?
  python3 - "$dir/log_$t" "$rc" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
rc  = int(sys.argv[2])
tot  = re.search(r"TOTAL: (\d+) stage \+ (\d+) output values compared, (\d+) mismatches", log)
done = "RTL matches ref/matvec_int4.c at every stage" in log

# ORDER MATTERS HERE, AND GETTING IT WRONG COST THIS SCRIPT A WHOLE RUN.
#
# A severity-failure assert STOPS the simulation, so `done` is absent and the
# TOTAL line usually is too -- the bench asserts per-pass long before it gets
# there.  ghdl-mcode then prints its own `ghdl:error: assertion failed`
# epilogue.  A first version of this parser tested for that ghdl line before
# testing for the bench's diagnostics, so a mutation the CHECKER caught was
# reported as an ABORT.  MEASURED on D5: the log holds
#   "BFP: 64 stage values compared, 64 mismatches"
#   "(assertion failure): RTL DIVERGES FROM THE C REFERENCE"
#   "ghdl-mcode:error: assertion failed"
# and it was scored ABORT.  That is the same class of error as scoring a dead
# run as a survivor, one square over: it understates what the bench can see.
#
# So: the bench's OWN diagnostics are consulted FIRST, and only a log with
# none of them falls through to the language-level cases.  Note ghdl writes
# `(assertion failure)` for a bare `assert`, and `(report failure)` for a
# `report ... severity failure`; the bench uses both forms.
checker = re.search(r"(?:tb_matvec_core|matvec_core)\.vhd:\d+:\d+:@[^:]*:"
                    r"\((?:assertion|report) failure\): (.+)", log)
mismatch = re.search(r"\(report error\): ([A-Z ]*MISMATCH[^\n]*)", log)
lang = re.search(r"ghdl[^:]*:error: (.+)", log)
bound = re.search(r"(index \([-\d]+\) out of bounds[^\n]*|bound check failure[^\n]*|"
                  r"value [-\d]+ out of range[^\n]*)", log)

if done and tot and int(tot.group(3)) == 0:
    print("SURV|%s stage + %s out, 0 mism" % (tot.group(1), tot.group(2)))
elif tot and int(tot.group(3)) != 0:
    print("KILL|%s mismatches at TOTAL" % tot.group(3))
elif checker:
    print("KILL|%s" % checker.group(1).strip()[:50])
elif mismatch:
    print("KILL|%s" % mismatch.group(1).strip()[:50])
elif bound:
    print("ABORT|%s" % bound.group(1).strip()[:50])
elif re.search(r"simulation stopped by --stop-time|simulation stopped @", log):
    print("ABORT|hung: reached --stop-time with no verdict")
elif rc == 124:
    print("ABORT|wall-clock timeout 240s -- never terminated")
elif lang:
    print("ABORT|%s" % lang.group(1).strip()[:50])
else:
    print("ABORT|no TOTAL line and no error -- no verdict at all")
PY
}

# ---------------------------------------------------------------------------
# 3. mutate <tag> <branch> <desc>  [--rtl old new ...] [--arith old new ...]
# ---------------------------------------------------------------------------
mutate() {
  local tag="$1" br="$2" desc="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$tag" != *"$ONLY"* ]] && return
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir/work"

  local mode="" rtl_args=() ar_args=()
  for a in "$@"; do
    case "$a" in
      --rtl)   mode=rtl ;;
      --arith) mode=arith ;;
      *) if [ "$mode" = rtl ]; then rtl_args+=("$a"); else ar_args+=("$a"); fi ;;
    esac
  done

  if [ ${#rtl_args[@]} -gt 0 ]; then
    patch_file "$RTL" "$dir/matvec_core.vhd" "${rtl_args[@]}" || {
      printf '%-5s %-6s ANCHOR FAILED (rtl) -- tested nothing -- %s\n' \
        "$tag" "$br" "$desc"; return; }
  else
    cp "$RTL" "$dir/matvec_core.vhd"
  fi
  if [ ${#ar_args[@]} -gt 0 ]; then
    patch_file "$ARITH" "$dir/mv4i_arith_pkg.vhd" "${ar_args[@]}" || {
      printf '%-5s %-6s ANCHOR FAILED (arith) -- tested nothing -- %s\n' \
        "$tag" "$br" "$desc"; return; }
  else
    cp "$ARITH" "$dir/mv4i_arith_pkg.vhd"
  fi

  # analyse.  A mutation that will not compile has tested nothing, and must
  # never be scored as a kill.
  local f ok=1
  for f in "$REPO/rtl/util_pkg.vhd" "$dir/mv4i_arith_pkg.vhd" \
           "$dir/matvec_core.vhd" "$REPO/$TB"; do
    if ! "$GHDL" -a --std=08 -frelaxed --workdir="$dir/work" "$f" \
           >>"$dir/analyze.log" 2>&1; then ok=0; break; fi
  done
  if [ "$ok" = 0 ]; then
    printf '%-5s %-6s DID NOT ANALYZE -- a mutation that will not compile has tested nothing -- %s\n' \
      "$tag" "$br" "$desc"
    sed -n 1,3p "$dir/analyze.log"; return
  fi

  local cols="" any_kill=0 any_abort=0 all_surv=1 detail=""
  local t v d
  for t in $TRACES; do
    IFS='|' read -r v d <<< "$(run_trace "$dir" "$t")"
    case "$v" in
      KILL)  cols="$cols $t:KILL "; any_kill=1; all_surv=0 ;;
      ABORT) cols="$cols $t:ABRT "; any_abort=1; all_surv=0 ;;
      *)     cols="$cols $t:surv " ;;
    esac
    [ -z "$detail" ] && [ "$v" != SURV ] && detail="$t: $d"
  done

  local verdict
  if [ "$all_surv" = 1 ]; then
    verdict="SURVIVED"; NSURV=$((NSURV+1)); SURV_TAGS="$SURV_TAGS $tag"
  elif [ "$any_kill" = 1 ]; then
    verdict="KILLED  "; NKILL=$((NKILL+1))
  else
    verdict="ABORT   "; NABORT=$((NABORT+1))
  fi
  printf '%-5s %-6s %s %s  %-52s -- %s\n' \
    "$tag" "$br" "$verdict" "$cols" "$detail" "$desc"
}

echo "======================================================================="
echo " mutations of rtl/matvec_core.vhd, judged by sim/tb_matvec_core.vhd"
echo " columns: A = the committed gate trace (sim/tr.txt, 8x96, SATEV 0)"
echo "          P = ragged, 6x100 (ragged BFP tile AND 28 masked columns)"
echo "          S = adversarial, 8x1024 sat (NB=32, SATEV 1)"
echo " KILL = the checker fired.  ABRT = ghdl stopped the run (counted as a"
echo " kill, worth less).  surv = the bench printed its final match line."
echo "======================================================================="
echo
echo "---- class ALL: the shared datapath.  Every pass reaches these --------"

mutate D1 ALL "the spec 6.2 COLUMN MASK is removed: pad columns decode through the codebook, and index 0 is -127, not 0" \
  --rtl \
"            if k < n_cols then" \
"            if k < n_cols + BLK then"

mutate D2 ALL "the column mask is off by one at the top (k <= n_cols)" \
  --rtl \
"            if k < n_cols then" \
"            if k <= n_cols then"

mutate D3 ALL "the product resize truncates one bit (28 -> 23)" \
  --rtl \
"                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);" \
"                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 23);"

# EXPECTED SURVIVOR by construction: integer addition is commutative, so
# swapping the two operands of an adder-tree node cannot change any value.
# It is here to measure that the harness is not scoring noise -- a table in
# which EVERY mutation dies is a table whose oracle is suspect.
mutate D4 ALL "adder-tree level 1's two operands are swapped (commutative)" \
  --rtl \
"                tr(l)(rr*BLK + i)  <= tr(l-1)(rr*BLK + 2*i)
                                    + tr(l-1)(rr*BLK + 2*i + 1);" \
"                tr(l)(rr*BLK + i)  <= tr(l-1)(rr*BLK + 2*i + 1)
                                    + tr(l-1)(rr*BLK + 2*i);"

mutate D5 ALL "adder-tree level 1 drops its odd operand (a half-sum)" \
  --rtl \
"                tr(l)(rr*BLK + i)  <= tr(l-1)(rr*BLK + 2*i)
                                    + tr(l-1)(rr*BLK + 2*i + 1);" \
"                tr(l)(rr*BLK + i)  <= tr(l-1)(rr*BLK + 2*i)
                                    + tr(l-1)(rr*BLK + 2*i);"

mutate D6 ALL "the fabric levels read tr instead of trn (the reclaim split of 15.4a is undone in the wrong direction)" \
  --rtl \
"                trn(l)(rr*BLK + i) <= trn(l-1)(rr*BLK + 2*i)
                                    + trn(l-1)(rr*BLK + 2*i + 1);" \
"                trn(l)(rr*BLK + i) <= tr(l-1)(rr*BLK + 2*i)
                                    + tr(l-1)(rr*BLK + 2*i + 1);"

mutate D7 ALL "the scale multiply reads the wrong tree root (rr*BLK + 1)" \
  --rtl \
"            sprod(rr) <= trn(LVL)(rr*BLK) * signed('0' & scp(P_PART)(rr));" \
"            sprod(rr) <= trn(LVL)(rr*BLK + 1) * signed('0' & scp(P_PART)(rr));"

mutate D8 ALL "the scale is read one pipeline stage early (scp(P_PART-1))" \
  --rtl \
"            sprod(rr) <= trn(LVL)(rr*BLK) * signed('0' & scp(P_PART)(rr));" \
"            sprod(rr) <= trn(LVL)(rr*BLK) * signed('0' & scp(P_PART-1)(rr));"

mutate D9 ALL "the uint15 scale is taken as SIGNED (the '0' & guard is dropped), so a scale over 32767 goes negative" \
  --rtl \
"            sprod(rr) <= trn(LVL)(rr*BLK) * signed('0' & scp(P_PART)(rr));" \
"            sprod(rr) <= trn(LVL)(rr*BLK) * signed(scp(P_PART)(rr));"

mutate D10 ALL "SITE 1's shift is 14, not 15" \
  --rtl \
"            contrib(rr) <= resize(floor_shr(sprod(rr), 15), 29);" \
"            contrib(rr) <= resize(floor_shr(sprod(rr), 14), 29);"

mutate D11 ALL "SITE 1 rounds instead of flooring (7.4 says floor)" \
  --rtl \
"            contrib(rr) <= resize(floor_shr(sprod(rr), 15), 29);" \
"            contrib(rr) <= resize(round_shift(sprod(rr), 15), 29);"

mutate D12 ALL "the accumulator never restarts on the tag first bit, so tiles accumulate into each other" \
  --rtl \
"            if tg(P_CONTRIB).first = '1' then an := resize(contrib(rr), 48);" \
"            if false then an := resize(contrib(rr), 48);"

mutate D13 ALL "row end fires on the FIRST block of a tile, not the last" \
  --rtl \
"            if tg(P_CONTRIB).last = '1' then
              ta_val(rr*64+63 downto rr*64) <= std_logic_vector(resize(an, 64));" \
"            if tg(P_CONTRIB).first = '1' then
              ta_val(rr*64+63 downto rr*64) <= std_logic_vector(resize(an, 64));"

mutate D14 ALL "row end stage 2 FLOORS instead of rounding (SITE 2/3)" \
  --rtl \
"            re2_shv(rr) <= round_shift(re1_acc(rr), os_rep(rr));" \
"            re2_shv(rr) <= floor_shr(re1_acc(rr), os_rep(rr));"

mutate D15 ALL "row end stage 2 shifts by os_rep + 1" \
  --rtl \
"            re2_shv(rr) <= round_shift(re1_acc(rr), os_rep(rr));" \
"            re2_shv(rr) <= round_shift(re1_acc(rr), os_rep(rr) + 1);"

mutate D16 ALL "sat32 at row end is removed: the s48 is truncated to 32 bits and wraps" \
  --rtl \
"            a32 := sat32(re2_shv(rr));" \
"            a32 := resize(re2_shv(rr), 32);"

mutate D17 ALL "the activation prefetch wraps one block late, so every tile after the first reads the wrong x block" \
  --rtl \
"          if b_pf = nb_r - 1 then b_pf <= 0; else b_pf <= b_pf + 1; end if;" \
"          if b_pf = nb_r then b_pf <= 0; else b_pf <= b_pf + 1; end if;"

mutate D18 ALL "nb_r truncates instead of ceiling, so a K that is not a multiple of BLK loses its last block" \
  --rtl \
"                nb_r      <= (n_cols + BLK - 1) / BLK;              -- 6.3 ceil" \
"                nb_r      <= n_cols / BLK;                          -- 6.3 ceil"

mutate D19 ALL "the last tile is detected one tile early (rows_left <= 2*ROWS_IF)" \
  --rtl \
"            if rows_left <= ROWS_IF then st <= S_DRAIN;" \
"            if rows_left <= 2*ROWS_IF then st <= S_DRAIN;"

mutate D20 ALL "accept no longer requires a prefetched activation, so x_r is read from an empty queue" \
  --rtl \
"  accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1'
                     and xq_cnt > 0 else '0';" \
"  accept <= '1' when st = S_RUN and w_valid = '1' and s_valid = '1'
                     else '0';"

echo
echo "---- class BFP: out_mode = \"00\" only (ybuf, S_SCAN/ns, S_EMIT) -------"
echo "     reached by PASS 1 and PASS 3 ONLY"

mutate B1 BFP "ns is one too small: msb_pos_u(amax) - 15" \
  --rtl \
"            if msb_pos_u(amax) > 14 then ns_r <= msb_pos_u(amax) - 14;" \
"            if msb_pos_u(amax) > 14 then ns_r <= msb_pos_u(amax) - 15;"

mutate B2 BFP "the ns threshold is >= 14 rather than > 14" \
  --rtl \
"            if msb_pos_u(amax) > 14 then ns_r <= msb_pos_u(amax) - 14;
            else                         ns_r <= 0; end if;" \
"            if msb_pos_u(amax) >= 14 then ns_r <= msb_pos_u(amax) - 14;
            else                         ns_r <= 0; end if;"

mutate B3 BFP "the amax scan domain loses its PAD MASK: pad rows fold into amax and inflate ns" \
  --rtl \
"            if re3_ok(rr) = '1' then wm(rr) := re3_mag(rr);
            else                     wm(rr) := (others => '0'); end if;" \
"            wm(rr) := re3_mag(rr);"

mutate B4 BFP "the amax fold takes the MINIMUM of each pair, not the maximum" \
  --rtl \
"          for i in 0 to HALF-1 loop
            if wm(2*i+1) > wm(2*i) then fold(i) <= wm(2*i+1);
            else                        fold(i) <= wm(2*i); end if;
          end loop;" \
"          for i in 0 to HALF-1 loop
            if wm(2*i+1) < wm(2*i) then fold(i) <= wm(2*i+1);
            else                        fold(i) <= wm(2*i); end if;
          end loop;"

mutate B5 BFP "amax keeps the LAST magnitude rather than the running maximum" \
  --rtl \
"        if fold_v(LVLR-1) = '1' and fold((LVLR-1)*HALF) > amax then" \
"        if fold_v(LVLR-1) = '1' then"

mutate B6 BFP "the fold stages are dropped from inflight, so S_SCAN can read amax before the last tile reaches it" \
  --rtl \
"    for i in 0 to LVLR-1 loop o := o or fold_v(i); end loop;" \
"    for i in 0 to LVLR-1 loop o := o or '0'; end loop;"

mutate B7 BFP "the emit shift is floor, not round (SITE 4)" \
  --rtl \
"                em_shv(rr) <= resize(round_shift(
                                signed(ybuf_q(rr*32+31 downto rr*32)),
                                ns_rep(rr)), 32);" \
"                em_shv(rr) <= resize(floor_shr(
                                signed(ybuf_q(rr*32+31 downto rr*32)),
                                ns_rep(rr)), 32);"

# The RTL's own comment at the ns_rep declaration says exactly this: "To
# attribute the two fixes separately, put ns_r back HERE and nowhere else."
# ns_r is constant for the whole of S_EMIT and the replica is one cycle
# behind, so master and replica agree everywhere either is read.  This is an
# EXPECTED SURVIVOR and a TRUE EQUIVALENT MUTANT, not a coverage hole: no
# stimulus can separate the two, so no bench can kill it.  It is the timing
# fix, and timing is not what a functional bench measures.
mutate B8 BFP "the emit shift reads the MASTER ns_r, not the per-lane replica (the fanout fix undone)" \
  --rtl \
"                                ns_rep(rr)), 32);" \
"                                ns_r), 32);"

# Same shape as B8 for the row-end shift, and the RTL says the same thing:
# "To attribute, put out_shift back HERE and nowhere else."  Expected
# survivor while the caller holds out_shift for the whole operation, which
# the bench does.  What os_r ACTUALLY buys is protection against a caller
# that moves out_shift mid-operation -- a stimulus this bench does not
# generate and could not, since it drives out_shift from the trace's DIMS.
mutate B9 ALL "the row-end shift reads the LIVE out_shift port, not the latched os_rep" \
  --rtl \
"            re2_shv(rr) <= round_shift(re1_acc(rr), os_rep(rr));" \
"            re2_shv(rr) <= round_shift(re1_acc(rr), out_shift);"

mutate B10 BFP "sat16 on the emitted mantissa is removed" \
  --rtl \
"                ymn := sat16(em_shv(rr));" \
"                ymn := resize(em_shv(rr), 16);"

mutate B11 BFP "the emit pointer runs one tile too far (rd_t <= tiles_r)" \
  --rtl \
"            if rd_t < tiles_r then" \
"            if rd_t <= tiles_r then"

mutate B12 BFP "S_EMIT never terminates: the done test compares against tiles_r, not tiles_r - 1" \
  --rtl \
"              if em_t = tiles_r - 1 then st <= S_DONE; end if;" \
"              if em_t = tiles_r then st <= S_DONE; end if;"

mutate B13 BFP "the emit y_mask admits one pad row (rbase + rr <= n_rows)" \
  --rtl \
"                if rbase + rr < n_rows then y_mask(rr) <= '1';" \
"                if rbase + rr <= n_rows then y_mask(rr) <= '1';"

# WORKLOG OI-8, reintroduced.  ybuf_addr exists solely to hold the
# unconditional read inside the array on the one cycle rd_t reaches TILES.
mutate B14 BFP "OI-8 reintroduced: ybuf_addr no longer clamps at TILES (read one past the end)" \
  --rtl \
"    if t >= TILES then return TILES - 1; else return t; end if;" \
"    if t > TILES then return TILES - 1; else return t; end if;"

echo
echo "---- class RAW / PART: the no-buffer modes ----------------------------"

# WORKLOG OI-10, reintroduced verbatim.  This is the defect the bench's
# PASS 8 was written for, so it is the regression guard on the guard.
mutate R1 RAW "OI-10 reintroduced: ybuf is written in RAW mode too, one tile past the array above MAXROWS_BFP" \
  --rtl \
"          if out_mode = \"00\" then ybuf(re2_t) <= ynew; end if;" \
"          if out_mode /= \"10\" then ybuf(re2_t) <= ynew; end if;"

mutate R2 PART "PARTIAL emits the ROUNDED, SATURATED value instead of the unrounded s48 (14.2)" \
  --rtl \
"              y_data(rr*64+63 downto rr*64)
                <= std_logic_vector(resize(re2_acc(rr), 64));" \
"              y_data(rr*64+63 downto rr*64)
                <= std_logic_vector(resize(a32, 64));"

mutate R3 PART "the sat_event sticky no longer excludes PARTIAL, so 14.2's mode reports a saturation it never applied" \
  --rtl \
"            if out_mode /= \"10\" and re2_shv(rr) /= resize(a32, 48) then" \
"            if re2_shv(rr) /= resize(a32, 48) then"

mutate R4 NOTBFP "the no-buffer modes never raise y_we, so nothing is emitted at all" \
  --rtl \
"          if out_mode /= \"00\" then y_we <= '1'; end if;" \
"          if false then y_we <= '1'; end if;"

mutate R5 NOTBFP "the row-end y_mask admits one pad row" \
  --rtl \
"            if rbase + rr < n_rows then
              y_mask(rr) <= '1'; re3_ok(rr) <= '1';" \
"            if rbase + rr <= n_rows then
              y_mask(rr) <= '1'; re3_ok(rr) <= '1';"

mutate R6 ALL "y_exp for BFP forgets the ns term (7.4)" \
  --rtl \
"           (w_exp + x_exp - os_r - ns_r)          when out_mode = \"00\" else" \
"           (w_exp + x_exp - os_r)                 when out_mode = \"00\" else"

mutate R7 PART "y_exp for PARTIAL carries an out_shift term its payload never had (14.2)" \
  --rtl \
"  y_exp <= (w_exp + x_exp)                        when out_mode = \"10\" else" \
"  y_exp <= (w_exp + x_exp - os_r)                 when out_mode = \"10\" else"

mutate R8 RAW "y_exp for RAW carries an ns term (raw computes no ns at all)" \
  --rtl \
"           (w_exp + x_exp - os_r);" \
"           (w_exp + x_exp - os_r - ns_r);"

echo
echo "---- class IDLE: the spec 7.6 descriptor check ------------------------"

mutate I1 IDLE "the BFP row bound is dropped: n_rows > MAXROWS_BFP is accepted in BFP mode" \
  --rtl \
"                 or (out_mode = \"00\" and n_rows > MAXROWS_BFP) then" \
"                 or (out_mode = \"11\" and n_rows > MAXROWS_BFP) then"

mutate I2 IDLE "the row bound applies to EVERY mode, so raw and partial above MAXROWS_BFP are rejected (7.6 admits them)" \
  --rtl \
"                 or (out_mode = \"00\" and n_rows > MAXROWS_BFP) then" \
"                 or (n_rows > MAXROWS_BFP) then"

mutate I3 IDLE "the out_shift bound is off by one (> 41)" \
  --rtl \
"                 or out_shift < 0 or out_shift > 40" \
"                 or out_shift < 0 or out_shift > 41"

mutate I4 IDLE "os_r latches out_shift + 1" \
  --rtl \
"                os_r      <= out_shift;      -- checked 0..40 immediately above" \
"                os_r      <= out_shift + 1;  -- checked 0..40 immediately above"

mutate I5 IDLE "amax is not cleared between operations" \
  --rtl \
"                amax <= (others => '0');" \
"                null;"

echo
echo "---- class CB: the codebook write path --------------------------------"
echo "     P_CB_CHK's two invariants are structural, not value checks, and"
echo "     they run in EVERY testbench that instantiates this core."

mutate C1 CB "the codebook write is given a per-copy delay, so replica 1 lags replica 0" \
  --rtl \
"        if cbw_v(c) = '1' then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;" \
"        if cbw_v(c) = '1' and (c = 0 or cbw_v(0) = '0') then
          cb(c)(to_integer(unsigned(cbw_a(c)))) <= signed(cbw_d(c));
        end if;"

mutate C2 CB "codebook writes are accepted outside idle, so the table can change under a running operation" \
  --rtl \
"        if cb_we = '1' and st = S_IDLE and rst = '0' then" \
"        if cb_we = '1' and rst = '0' then"

mutate C3 CB "the S_IDLE cb_we interlock is deleted, so start can be honoured on the same edge as the last write" \
  --rtl \
"      elsif cb_we = '1' and st = S_IDLE then" \
"      elsif false then"

# CB_ROWS_PER_COPY is 1 at every geometry the benches use, so `rr / 1` = rr
# and every replica holds the same table.  Selecting replica 0 for every row
# is then a TRUE EQUIVALENT MUTANT under this configuration.  It is here to
# state that explicitly rather than leave the replica select untested-looking:
# what makes the replicas correct is P_CB_CHK, not the select.
mutate C4 CB "every row reads codebook replica 0 (the per-row replication undone)" \
  --rtl \
"                resize(cb(rr / CB_ROWS_PER_COPY)(idx) * xw, 28);" \
"                resize(cb(0)(idx) * xw, 28);"

echo
echo "---- class ARITH: rtl/mv4i_arith_pkg.vhd, the five shared primitives ---"
echo "     GENERATED by tools/gen_arith.py.  These measure whether"
echo "     tb_matvec_core ITSELF has teeth on them, independently of the"
echo "     dedicated arith vector bench."

mutate A1 ALL "round_shift loses its round-half-up bias (truncate)" \
  --arith \
"  w := resize(v, v'length + 1)
       + shift_left(to_signed(1, v'length + 1), sh - 1);" \
"  w := resize(v, v'length + 1);"

mutate A2 ALL "round_shift rounds half toward -infinity" \
  --arith \
"  w := resize(v, v'length + 1)
       + shift_left(to_signed(1, v'length + 1), sh - 1);" \
"  w := resize(v, v'length + 1)
       + shift_left(to_signed(1, v'length + 1), sh - 1) - 1;"

mutate A3 ALL "floor_shr rounds toward zero rather than -infinity" \
  --arith \
"    if sh = 0 then return v; end if;
    return shift_right(v, sh);" \
"    if sh = 0 then return v; end if;
    if v < 0 then return -shift_right(-v, sh); end if;
    return shift_right(v, sh);"

mutate A4 ALL "sat32's negative rail is one high" \
  --arith \
"    elsif v < LO then return to_signed(-2147483648, 32);" \
"    elsif v < LO then return to_signed(-2147483647, 32);"

mutate A5 BFP "sat16's positive rail is one low" \
  --arith \
"    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);" \
"    if    v >  to_signed( 32766, v'length) then return to_signed( 32766, 16);"

mutate A6 BFP "msb_pos_u(0) returns 1, not 0 (the NORMATIVE zero case)" \
  --arith \
"    return p;                                    -- 0 when a = 0" \
"    if p = 0 then return 1; end if;
    return p;                                    -- 0 when a = 0"

echo
echo "======================================================================="
printf 'kill ratio: %d KILLED + %d ABORT = %d of %d;  %d SURVIVED\n' \
  "$NKILL" "$NABORT" "$((NKILL+NABORT))" "$NTOT" "$NSURV"
echo "survivors:$SURV_TAGS"
echo "scratch dir with every mutant, its traces and all three logs: $SCRATCH"
echo "======================================================================="
