#!/usr/bin/env bash
# Mutation test for rtl/gdn_silu.vhd and ref/gdn_silu_vec.c.
#
# WHAT tb_gdn_silu ACTUALLY CHECKS, stated before anything is mutated, because
# a mutation aimed at something the bench never claimed to cover teaches
# nothing.  Its header says it plainly: BIT-EXACTNESS ONLY.  It compares
# o_data against the y column of the vector file and nothing else.  The
# accuracy question -- how far the integer recipe sits from silu(x) in real
# arithmetic -- is answered in ref/gdn_silu_vec.c, which computes
# x/(1+exp(-x)) in double and PRINTS the worst absolute and relative error.
#
# IT PRINTS THEM.  It does not gate on them, and neither does the bench.  So
# as committed, subsystem B has NO automatic check on gdn_silu's accuracy at
# all: a recipe error present in both the C and the VHDL is invisible to the
# whole suite.  That is the same shape the audit records for gdn_scalar
# ("reported, not asserted") and it is true here too.
#
# SUPERSEDED, 2026-08-29, AND KEPT AS THE SECOND OPINION.  The two paragraphs
# above describe the state before this date and are left standing because they
# are what the ACC_LSB / ACC_REL numbers were measured against.
# sim/tb_gdn_silu.vhd now carries its OWN real-valued oracle and gates on it at
# severity error, so the accuracy claim is reachable from sim/regress.sh
# instead of only from this script.  Two columns are printed per mutation:
#
#   oracle  -- the GENERATOR's figures, parsed from its stderr.  A claim about
#              the C's y column.  This is the pre-2026-08-29 gate.
#   bench   -- the BENCH's figures, parsed from the run log.  A claim about the
#              DUT's own o_data.  This is what regress.sh now fails on.
#
# They are not the same claim: the generator's column cannot see an RTL-only
# accuracy defect at all, because the generator never runs the RTL.  Where the
# two disagree, the disagreement IS the measurement.
#
# ACC_LSB / ACC_REL are MEASURED baselines with headroom, not derived bounds,
# and so are the bench's own generic defaults.  Nothing in rtl/ or sim/ is
# edited to make a mutation bite; every mutation runs against a COPY.
#
# THREE CLASSES, and the third is the only one that can reach a shared recipe
# error:
#   RTL  -- rtl/gdn_silu.vhd only.  Must fail bit-exactness.
#   C    -- ref/gdn_silu_vec.c only.  Must fail bit-exactness.  Whether it
#           also moves the accuracy figures is the interesting part.
#   BOTH -- the same recipe change in each.  Must LEAVE bit-exactness green,
#           and can only be caught by the double oracle.
#
# sim/gdn_silu_vec.txt is COMMITTED, so sim/regress.sh never regenerates it
# and a mutation of the generator would change nothing there.  Every run below
# therefore generates its own vectors into a private workdir.  Verified: the
# generator at its defaults reproduces the committed file byte for byte.
#
# Usage: bash sim/mutate_gdn_silu.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  NELEM=<n>  SEED=<n>  ARGQ=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_silu.vhd
REF=ref/gdn_silu_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-256}"
NELEM="${NELEM:-128}"
SEED="${SEED:-20260826}"
ARGQ="${ARGQ:-12}"
mkdir -p "$SCRATCH"

# MEASURED on the unmutated pair at these arguments:
#   worst abs err vs double oracle: 1.8442 LSB (case 31)
#   worst rel err where |y| >= 16 LSB: 4.948839e-02 (case 10)
# The gate sits just above each, so a mutation that degrades accuracy at all
# is caught and the baseline itself is not marginal.  These are BASELINES, not
# bounds derived from the recipe: the Q12 argument grid is coarse and 4.9% is
# what it costs.
#
# RETUNED 2026-08-29 (TRACK B-SEED): ACC_LSB 2.0 -> 3.5.  "The gate sits just
# above each" was true of the committed seed only.  MEASURED over 40 generator
# seeds the honest worst abs error ranges 1.8158 .. 2.7271 LSB and the
# committed 1.8442 is its 5th percentile, so 2.0 fired on the HONEST unit at
# 33 of 40 seeds (82%).  3.5 is the SAME standard as the bench's
# ACC_MAXLSB_M = 3500, so the two gates cannot drift apart, and it is 1.28x
# the 40-seed maximum.
# MEASURED BOTH WAYS: kill ratio unchanged at 15 of 19.  One row, C2 (2.7431
# LSB), loses this column and is still killed by bit-exactness; B4 (2.5702
# LSB) keeps its kill through ACC_REL, whose figure moves 4.9488e-2 ->
# 5.7289e-2.
#
# ACC_REL IS LEFT AT 5.5e-2 ON PURPOSE.  MEASURED over the same 40 seeds the
# honest range is 4.159e-2 .. 4.971e-2, so it fires on 0 of 40 -- but the real
# margin is 1.11x, not the comfortable figure the text above implies, and B4
# is killed at 5.7289e-2, only 15% above the honest maximum.  Widening it
# would delete B4's only remaining detection; tightening it would go red on an
# honest seed.  It is left exactly where it is, with the margin recorded.
ACC_LSB="${ACC_LSB:-3.5}"
ACC_REL="${ACC_REL:-5.5e-2}"

# The BENCH-side gate.  Default deliberately EMPTY so the bench runs at its own
# committed generic defaults and this script measures the gate sim/regress.sh
# actually applies, rather than a private one that could drift away from it.
# Widen it for a measurement pass with, e.g.
#   BACC="-gACC_MAXLSB_M=2000000000 -gACC_NEAR_MAX=1000000 -gACC_MIN_CHECK=0"
# which is the form the raw figures in the write-up were collected with.
BACC="${BACC:-}"

NKILL=0; NSURV=0; NTOT=0

# Apply a list of old/new pairs to one file.  An anchor that does not match
# EXACTLY once aborts: a mutation applied zero times is a false survivor and a
# mutation applied twice is not the mutation described.
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
        sys.stderr.write("ANCHOR %d MATCHED %d TIMES, expected 1\n" % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
}

# $1 tag, $2 desc, then  --rtl old new ...  --c old new ...
mutate() {
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"

  local mode="" rtl_args=() c_args=()
  for a in "$@"; do
    case "$a" in
      --rtl) mode=rtl ;;
      --c)   mode=c ;;
      *) if [ "$mode" = rtl ]; then rtl_args+=("$a"); else c_args+=("$a"); fi ;;
    esac
  done

  if [ ${#rtl_args[@]} -gt 0 ]; then
    patch_file "$RTL" "$dir/gdn_silu.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/gdn_silu.vhd"
  fi
  if [ ${#c_args[@]} -gt 0 ]; then
    patch_file "$REF" "$dir/gen.c" "${c_args[@]}" || {
      echo "$tag  C ANCHOR FAILED"; return; }
  else
    cp "$REF" "$dir/gen.c"
  fi

  if ! cc -O2 -w -I ref -o "$dir/gen" "$dir/gen.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./gen v.txt "$NCASE" "$NELEM" "$SEED" "$ARGQ" ) \
      >/dev/null 2>"$dir/gen.err"
  if [ ! -s "$dir/v.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NOTHING"; sed -n 1,3p "$dir/gen.err"; return
  fi

  ghdl -a --std=08 -frelaxed --workdir="$dir" rtl/fixed_luts_pkg.vhd >/dev/null 2>&1
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_silu.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_silu.vhd >/dev/null 2>&1

  # shellcheck disable=SC2086
  ( cd "$dir" && timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_silu -gVECS=v.txt -gNCASE="$NCASE" -gN="$NELEM" -gARG_Q="$ARGQ" \
      $BACC --max-stack-alloc=0 --stop-time=900ms ) >"$dir/run.log" 2>&1

  local bx acc bench
  # Bit-exactness is judged on the MISMATCH report and not on the presence of
  # the success line: since 2026-08-29 the bench withholds that line when the
  # ACCURACY check fails too, so keying on it would report every accuracy kill
  # as a bit-exactness kill and hide which check did the work.
  #
  # THE THIRD STATE IS NOT OPTIONAL.  Keying on the success line used to make a
  # run that DIED -- the DUT's own assert firing, a timeout -- read as FAIL by
  # accident.  Keying on the mismatch alone makes the same run read as PASS,
  # which is worse.  So a run that never reached its own verdict is ABORT and
  # is counted as a kill in its own right.  MEASURED: R11 lands here, killed by
  # rtl/rmsnorm_bf.vhd's Q30 normalisation assert at severity failure, which
  # sim/regress.sh's FAIL_RE also matches.
  if grep -qE "mismatch\\(es\\) in" "$dir/run.log"; then
    bx=FAIL
  elif ! grep -qF "gdn_silu accuracy vs the real-valued oracle" "$dir/run.log"; then
    bx=ABORT
  else
    bx=PASS
  fi
  bench=$(python3 - "$dir/run.log" <<'PYB'
import re, sys
t = open(sys.argv[1], errors="replace").read()
m = re.search(r"worst ([0-9.eE+-]+) LSB at case (-?\d+).*?; (\d+) of (\d+) elem", t, re.S)
if not m:
    print("NOFIG"); sys.exit()
tag = "FAIL " if "OUT OF TOLERANCE" in t else "pass "
print(tag + "%.4g LSB / %s past / n=%s" % (float(m.group(1)), m.group(3), m.group(4)))
PYB
)
  # The accuracy gate this suite does not have.  Both figures come from the
  # generator's own double path, which shares no code with either integer
  # transcription.
  acc=$(python3 - "$dir/gen.err" "$ACC_LSB" "$ACC_REL" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
lsb = re.search(r"worst abs err vs double oracle: ([0-9.eE+-]+) LSB", t)
rel = re.search(r"worst rel err where \|y\| >= 16 LSB: ([0-9.eE+-]+)", t)
if not lsb or not rel:
    print("NOFIG"); sys.exit()
l, r = float(lsb.group(1)), float(rel.group(1))
bad = (l > float(sys.argv[2])) or (r > float(sys.argv[3]))
print(("FAIL " if bad else "pass ") + "%.4f LSB / %.4e rel" % (l, r))
PY
)
  if [ "$bx" != PASS ] || [ "${acc%% *}" = FAIL ] || [ "${bench%% *}" = FAIL ]; then
    NKILL=$((NKILL+1))
    printf '%-4s KILLED   bit-exact %-4s  oracle %s  bench %s  -- %s\n' \
        "$tag" "$bx" "$acc" "$bench" "$desc"
    if [ "$bx" != PASS ]; then
      grep -m1 -E "mismatch\(es\) in|assertion (error|failure)|simulation failed" \
        "$dir/run.log" | cut -c1-160 | sed 's/^/       /'
    fi
    if [ "${bench%% *}" = FAIL ]; then
      grep -m1 -E "OUT OF TOLERANCE" "$dir/run.log" | cut -c1-160 | sed 's/^/       /'
    fi
  else
    NSURV=$((NSURV+1))
    printf '%-4s SURVIVED bit-exact %-4s  oracle %s  bench %s  -- %s\n' \
        "$tag" "$bx" "$acc" "$bench" "$desc"
  fi
}

echo "===================== mutations of gdn_silu ========================"
echo "cases $NCASE x $NELEM elements, seed $SEED, ARG_Q $ARGQ"
echo "oracle column: gate supplied by THIS SCRIPT from the generator's stderr,"
echo "  <= $ACC_LSB LSB and <= $ACC_REL rel."
echo "bench column:  gate supplied by sim/tb_gdn_silu.vhd itself, at its own"
echo "  generic defaults unless BACC overrides them.  This is the gate"
echo "  sim/regress.sh fails on.  BACC='$BACC'"
echo
echo "---- class RTL: rtl/gdn_silu.vhd alone.  Must fail bit-exactness ------"

mutate R1 "S4: the Q30 -> Q15 sigma round is truncated" --rtl \
"          sg  := rsh_r(itp, 30 - 15);" \
"          sg  := shift_right(itp, 30 - 15);"

mutate R2 "S6: the output round is truncated" --rtl \
"          y := rsh_r(prod(k), 15);" \
"          y := shift_right(prod(k), 15);"

mutate R3 "S0: the M_RSH branch truncates instead of rounding" --rtl \
"              xq(k) <= resize(rsh_r(v, c_amt(k)), 32);" \
"              xq(k) <= resize(shift_right(v, c_amt(k)), 32);"

mutate R4 "S1: the ROM index is taken one bit low" --rtl \
"            kk(k) <= to_integer(offu(ARG_Q+4 downto ARG_Q-4));" \
"            kk(k) <= to_integer(offu(ARG_Q+3 downto ARG_Q-5));"

mutate R5 "S1: the interpolation fraction is dropped (nearest lower entry)" --rtl \
"            fr(k) <= offu(ARG_Q-5 downto 0) & \"0000\";" \
"            fr(k) <= (others => '0');"

mutate R6 "S2: the table delta is negated" --rtl \
"          dl(k)  <= to_signed(SIG_ROM(kk(k)+1) - SIG_ROM(kk(k)), 25);" \
"          dl(k)  <= to_signed(SIG_ROM(kk(k)) - SIG_ROM(kk(k)+1), 25);"

mutate R7 "S4: the sigma high clamp is 32767, one below unity" --rtl \
"          elsif sg > 32768  then sig(k) <= to_signed(32768, 18);" \
"          elsif sg > 32767  then sig(k) <= to_signed(32767, 18);"

# R8, R9 and R10 are EXPECTED SURVIVORS and are kept for that reason: each one
# measures a different limit of this bench, and the three limits are not the
# same kind.  Every claim below was MEASURED by instrumenting a copy of the
# generator to report the range of sh and the number of times xq lands exactly
# on a rail:
#
#   PROBE sh range [-42,28]  xq==-RAIL 0  xq==+RAIL 6
#
#   R8  COVERAGE HOLE.  sh = e_seg - ARG_Q never exceeds 28 in this stimulus,
#       so the sh > 62 flush-to-zero branch (M_ZERO here, `if (sh > 62)` in the
#       C) is NEVER TAKEN by either transcription.  The generator's comment
#       calls e = 40 "deep right shift, flushes to 0", and it does flush -- but
#       through M_RSH, not through the guard.  The guard is untested on both
#       sides.  C3 below is the same hole seen from the C.  Widening the e
#       sweep would close it; that is a generator change and is NOT made here.
#   R9  EQUIVALENT MUTANT, and the branch IS reached (-sh reaches 42).  At
#       -sh = 41 the M_LSH branch computes v << 41 with |v| <= 2^15, so
#       |v << 41| <= 2^56 -- no overflow of the 64-bit temporary -- and then
#       clamps to +-2^30, which is exactly what M_RAIL emits.  Zero maps to
#       zero in both.  So no stimulus can separate 40 from 41 and no bench
#       could kill this.
#   R10 COVERAGE HOLE, and specifically a ONE-SIDED one: xq lands exactly on
#       +RAIL six times and on -RAIL not once.  R12 is the same mutation on
#       the side that IS reached, and it dies.
mutate R8 "S-1: the flush-to-zero threshold is 61, not 62" --rtl \
"          if sh > 62 then" \
"          if sh > 61 then"

mutate R9 "S-1: the left-shift rail threshold is 41, not 40" --rtl \
"          elsif -sh > 40 then" \
"          elsif -sh > 41 then"

mutate R10 "S1: the LOW rail compare excludes its own boundary" --rtl \
"          if xq(k) <= to_signed(-RAIL, 32) then" \
"          if xq(k) <  to_signed(-RAIL, 32) then"

mutate R12 "S1: the HIGH rail compare excludes its own boundary" --rtl \
"          elsif xq(k) >= to_signed(RAIL, 32) then" \
"          elsif xq(k) >  to_signed(RAIL, 32) then"

mutate R11 "S5: the mantissa is one pipeline stage LATE (sm5, not sm4)" --rtl \
"          prod(k) <= resize(sm4(k) * sig(k), 64);" \
"          prod(k) <= resize(sm5(k) * sig(k), 64);"

echo
echo "---- class C: ref/gdn_silu_vec.c alone.  Must fail bit-exactness ------"
echo "     (whether the oracle ALSO moves is the resolution measurement)"

mutate C1 "the sigma unity clamp is 32767, one below 2^15" --c \
"    if (r > (1LL << 15)) r = 1LL << 15;" \
"    if (r > ((1LL << 15) - 1)) r = (1LL << 15) - 1;"

mutate C2 "the Q12 right-shift branch truncates instead of rounding" --c \
"        return (int32_t)round_shift(x, sh);" \
"        return (int32_t)floor_shr(x, sh);"

# EXPECTED SURVIVOR, same hole as R8 and for the same measured reason: sh
# never exceeds 28, so neither 62 nor 61 is ever compared against.
mutate C3 "the deep-right-shift cutoff is 61, not 62" --c \
"        if (sh > 62) return 0;" \
"        if (sh > 61) return 0;"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (bit-exactness MUST stay green; only the oracle can see these)"

mutate B1 "the output round-shift is 16, not 15: the whole result is halved" \
  --rtl \
"          y := rsh_r(prod(k), 15);" \
"          y := rsh_r(prod(k), 16);" \
  --c \
"            int64_t y   = round_shift((int64_t)sm[i] * sig, 15);" \
"            int64_t y   = round_shift((int64_t)sm[i] * sig, 16);"

mutate B2 "the LUT interpolation slope is halved (>> ARG_Q+1)" \
  --rtl \
"          itp := resize(lo3(k), 64) + shift_right(pr(k), ARG_Q);" \
"          itp := resize(lo3(k), 64) + shift_right(pr(k), ARG_Q + 1);" \
  --c \
"    int64_t interp_q30 = lo + (((hi - lo) * frac) >> ARG_Q);" \
"    int64_t interp_q30 = lo + (((hi - lo) * frac) >> (ARG_Q + 1));"

# The rails move to |x| = 8, not 12.  MEASURED reason: 1 - sigma(12) = 6.1e-6,
# which is 0.2 LSB of Q15, so railing at 12 changes no output integer at all
# and would have scored a meaningless survivor.  At 8 it is 3.35e-4 = 11 LSB
# of Q15, which is a real recipe error.  The ROM offset is deliberately NOT
# touched, so the index grid is identical in both transcriptions and the
# change is purely the rail.
mutate B3 "the sigma saturation rail moves from |x| = 16 to |x| = 8" \
  --rtl \
"          if xq(k) <= to_signed(-RAIL, 32) then" \
"          if xq(k) <= to_signed(-(RAIL/2), 32) then" \
"          elsif xq(k) >= to_signed(RAIL, 32) then" \
"          elsif xq(k) >= to_signed(RAIL/2, 32) then" \
  --c \
"    if ((int64_t)z_q12 <= -16LL * one12) return 0;
    if ((int64_t)z_q12 >=  16LL * one12) return 1 << 15;" \
"    if ((int64_t)z_q12 <= -8LL * one12) return 0;
    if ((int64_t)z_q12 >=  8LL * one12) return 1 << 15;"

mutate B4 "the output round-half-up bias is dropped in BOTH (truncate)" \
  --rtl \
"          y := rsh_r(prod(k), 15);" \
"          y := shift_right(prod(k), 15);" \
  --c \
"            int64_t y   = round_shift((int64_t)sm[i] * sig, 15);" \
"            int64_t y   = floor_shr((int64_t)sm[i] * sig, 15);"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
