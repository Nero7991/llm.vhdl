#!/usr/bin/env bash
# Mutation test for rtl/gdn_scalar.vhd and ref/gdn_scalar_vec.c.
#
# WHAT tb_gdn_scalar ACTUALLY CHECKS, read out of the file before anything was
# mutated.  It is a two-way bench and the two ways are NOT equally armed:
#
#   (a) BIT-EXACTNESS against the fixed path in the vector file -- eg, beta
#       and err_g -- counted into bad_eg / bad_beta / bad_err and then
#       asserted at severity FAILURE ("BIT-EXACTNESS FAILED").  This is the
#       contract and it has teeth.
#   (b) THE DOUBLE ORACLE, which the file's own header calls "REPORTED against
#       a double oracle" and line 95 marks "the oracle, reported not
#       asserted".  The run prints
#           vs double oracle: eg worst <x> LSB(Q15), beta worst <y> LSB(Q16)
#       and then compares it to NOTHING.  No threshold exists in the bench,
#       and ref/gdn_scalar_vec.c has no accuracy return path either.
#
# So gdn_scalar's accuracy is gated NOWHERE, and every BOTH-class mutation
# below -- the same recipe error transcribed into the C and the VHDL alike --
# is invisible to the committed suite.  The suite reports PASS on all of them.
#
# THIS SCRIPT SUPPLIES THE GATE, in the harness, not in the RTL and not in the
# bench.  Nothing under rtl/, ref/ or sim/tb_*.vhd is edited; every mutation
# is applied to a COPY in a private scratch directory.
#
# ---------------------------------------------------------------------------
# THE eg FIGURE THE BENCH PRINTS IS ALREADY SATURATED, ON THE UNMUTATED UNIT
# ---------------------------------------------------------------------------
# MEASURED, unmutated, SP_Q = 18, against the committed vectors (which this
# generator reproduces byte for byte):
#
#   vs double oracle: eg worst 3.2768e4 LSB(Q15), beta worst 3.088008999999147 LSB(Q16)
#
# 3.2768e4 is 32768, which is the ENTIRE output range of eg.  The recipe and
# the oracle disagree by 100% of full scale on at least one case, and the
# bench prints that and passes.  Per-case analysis of the vector file
# (MEASURED, 320 cases):
#
#   median |eg_fixed - eg_oracle| = 0.0553 LSB
#   cases over    1 LSB: 87
#   cases over  100 LSB: 17
#   worst: case 262, eg_fixed 0 against eg_oracle 32768 (gate shut, truth
#          wide open), and case 270, eg_fixed 32768 against 0.003688 (gate
#          wide open, truth shut)
#
# Case 262 is al_m 32767 al_e -21, dt_m -32768 dt_e -21.  Both terms saturate
# at the +-2^45 sentinel and CANCEL, so arg becomes 0 where the true argument
# is -2^21.  That is the same failure mode the unit's own header says it
# corrected -- "two opposite-sign saturations then cancel" -- moved from the
# s32 rail to the 2^45 sentinel rather than eliminated.  It needs larger
# inputs than 2.1.3's version did; the adversarial band of the generator
# supplies them.  Whether that band is physically reachable in the 27B weights
# is NOT determined here.
#
# CONSEQUENCE FOR THE GATE: a threshold on the printed eg worst-case is
# VACUOUS, because it is already pinned at the maximum a 16-bit output can
# reach.  So this script gates on
#   * the printed BETA worst-case, which is tight and meaningful (3.088), and
#   * an AGGREGATE it computes itself over the SAME two oracle columns the
#     bench reads out of the vector file: the median eg error and the count of
#     cases past 100 LSB.
# The aggregate compares the C fixed path against the C double oracle.  That
# is a statement about the RTL only because the bench has separately proved
# the RTL bit-exact with that fixed column, so it is reported alongside the
# bit-exactness verdict and is meaningless without it.
#
# THREE CLASSES:
#   RTL  -- rtl/gdn_scalar.vhd only.  Must fail bit-exactness.
#   C    -- ref/gdn_scalar_vec.c only.  Must fail bit-exactness.
#   BOTH -- the same recipe change in each.  Must LEAVE bit-exactness green,
#           and can be caught only by the oracle the bench does not gate on.
#
# ref/gdn_scalar_vec.c writes to STDOUT and takes one argument, SP_Q.
# Verified: `./gdn_scalar_vec 18 > v.txt` reproduces sim/gdn_scalar_vec.txt
# byte for byte, so every run below regenerates its own vectors privately.
#
# Usage: bash sim/mutate_gdn_scalar.sh
# Env:   SCRATCH=<dir>  SP_Q=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_scalar.vhd
REF=ref/gdn_scalar_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
SP_Q="${SP_Q:-18}"
mkdir -p "$SCRATCH"

# MEASURED baselines with headroom.  These are BASELINES, not bounds derived
# from the recipe.
BETA_TOL="${BETA_TOL:-4.0}"      # baseline 3.0880
EG_MED_TOL="${EG_MED_TOL:-0.10}" # baseline 0.0553
EG_N100_TOL="${EG_N100_TOL:-17}" # baseline 17

NKILL=0; NSURV=0; NTOT=0

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

# $1 tag, $2 class, $3 desc, then  --rtl old new ...  --c old new ...
mutate() {
  local tag="$1" cls="$2" desc="$3"; shift 3
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
    patch_file "$RTL" "$dir/gdn_scalar.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/gdn_scalar.vhd"
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
  ( cd "$dir" && ./gen "$SP_Q" > v.txt ) 2>"$dir/gen.err"
  if [ ! -s "$dir/v.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NOTHING"; sed -n 1,3p "$dir/gen.err"; return
  fi

  ghdl -a --std=08 -frelaxed --workdir="$dir" rtl/fixed_luts_pkg.vhd >/dev/null 2>&1
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_scalar.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_scalar.vhd >/dev/null 2>&1

  ( cd "$dir" && timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_scalar -gVEC=v.txt -gSP_Q="$SP_Q" \
      --max-stack-alloc=0 --stop-time=900ms ) >"$dir/run.log" 2>&1

  local res
  res=$(python3 - "$dir/run.log" "$dir/v.txt" \
        "$BETA_TOL" "$EG_MED_TOL" "$EG_N100_TOL" <<'PY'
import re, sys, statistics
log = open(sys.argv[1], errors="replace").read()
# (a) bit-exactness, as the bench states it
m = re.search(r"eg mismatches (\d+), beta mismatches (\d+), err_g mismatches (\d+)", log)
if m and "PASS" in log and all(int(x) == 0 for x in m.groups()):
    bx = "pass"
elif m:
    bx = "FAIL(%s/%s/%s)" % m.groups()
else:
    e = re.search(r"ghdl[^:]*:error: (.+)", log)
    bx = "DEAD:" + (e.group(1)[:28] if e else "no verdict")
# (b) the oracle the bench prints and does not gate
o = re.search(r"eg worst ([0-9.eE+-]+) LSB\(Q15\), beta worst ([0-9.eE+-]+) LSB\(Q16\)", log)
egw, bew = (float(o.group(1)), float(o.group(2))) if o else (float("nan"),)*2
# (c) the aggregate this script computes over the file's own oracle columns,
#     because (b)'s eg figure is pinned at full scale even when correct
ds = []
for ln in open(sys.argv[2]).read().split("\n")[1:]:
    f = ln.split()
    if len(f) < 13: continue
    ds.append(abs(int(f[8]) - float(f[11])))
med = statistics.median(ds) if ds else float("nan")
n100 = sum(1 for d in ds if d > 100)
bad = (bew > float(sys.argv[3])) or (med > float(sys.argv[4])) or (n100 > int(sys.argv[5]))
print("%s|%s|beta %.4f  eg med %.4f  eg>100 %d  (eg max %.0f)" %
      (bx, "FAIL" if bad else "pass", bew, med, n100, egw))
PY
)
  local bx="${res%%|*}"; local rest="${res#*|}"
  local acc="${rest%%|*}"; local fig="${rest#*|}"

  if [ "$bx" != pass ] || [ "$acc" != pass ]; then
    NKILL=$((NKILL+1))
    printf '%-4s %-4s KILLED   bit-exact %-22s oracle %-4s  %s  -- %s\n' \
      "$tag" "$cls" "$bx" "$acc" "$fig" "$desc"
  else
    NSURV=$((NSURV+1))
    printf '%-4s %-4s SURVIVED bit-exact %-22s oracle %-4s  %s  -- %s\n' \
      "$tag" "$cls" "$bx" "$acc" "$fig" "$desc"
  fi
}

echo "=================== mutations of gdn_scalar ========================="
echo "SP_Q = $SP_Q, 320 cases"
echo "bit-exactness is the BENCH's gate (severity failure)."
echo "the oracle gate is supplied by THIS SCRIPT: beta <= $BETA_TOL LSB(Q16),"
echo "eg median <= $EG_MED_TOL LSB, eg cases past 100 LSB <= $EG_N100_TOL."
echo "the bench's own printed eg worst-case is 32768 = full scale even when"
echo "the unit is CORRECT, so a threshold on it would be vacuous."
echo
echo "---- class RTL: rtl/gdn_scalar.vhd alone.  Must fail bit-exactness ----"

mutate R1 RTL "to_q_wide's saturation sentinel is 2^44, not 2^45" --rtl \
"  constant SAT_W : wide_t := shift_left(to_signed(1, wide_t'length), 45);" \
"  constant SAT_W : wide_t := shift_left(to_signed(1, wide_t'length), 44);"

# EXPECTED SURVIVOR, and an EQUIVALENT MUTANT on this stimulus rather than a
# coverage hole: the branch IS reached.  MEASURED over the 640 (mantissa,
# exponent) terms of the 320 cases:
#   terms with -sh in [37,40] and m != 0: 14
#   of those, terms with |m| <= 2^(45-s), the only ones where a cutoff of 36
#   and a cutoff of 40 can produce different values: 0
# For every one of the 14 the exact branch computes m << s, which exceeds
# SAT_W = 2^45 and is clamped back to SAT_W -- exactly what the 36 cutoff
# returns directly.  The saturation swallows the difference.  Separating 36
# from 40 needs a small mantissa at a large negative exponent, and the
# generator never draws that combination.
mutate R2 RTL "to_q_wide's left-shift cutoff is 36, not 40 (the recorded divergence)" --rtl \
"    elsif -sh > 40 then" \
"    elsif -sh > 36 then"

mutate R3 RTL "to_q_wide loses the m = 0 short circuit" --rtl \
"    if m = 0 then
      return (others => '0');          -- zero is zero on every grid
    end if;" \
"    if false then
      return (others => '0');          -- zero is zero on every grid
    end if;"

mutate R4 RTL "the softplus POSITIVE tail is clamped (defect 2 of the header)" --rtl \
"            elsif arg >= to_signed(LIM, wide_t'length) then
              sp     <= arg;" \
"            elsif arg >= to_signed(LIM, wide_t'length) then
              sp     <= to_signed(LIM, wide_t'length);"

# EXPECTED SURVIVOR, and a TRUE EQUIVALENT MUTANT.  The boundary is reached:
# MEASURED, arg == -LIM exactly in 6 of the 320 cases (and arg <= -LIM in 35).
# At arg = -LIM the mutant takes the table path with z = -|arg| = -LIM, so
# off = 0, k = 0, frac = 0, and the interpolator returns SP_ROM(0), which is
# softplus(-16) = 1.125e-7 in Q30 = 121.  rsh_r(121, 30-18) = (121+2048)>>12
# = 0, and arg is negative so the `arg > 0` add is not taken: sp = 0, which is
# what the unmutated compare assigns directly.  No stimulus can separate the
# two, so no bench could kill this.
mutate R5 RTL "the softplus negative-tail compare excludes its own boundary" --rtl \
"            if arg <= to_signed(-LIM, wide_t'length) then" \
"            if arg <  to_signed(-LIM, wide_t'length) then"

mutate R6 RTL "the interpolator's table index clamps one entry low" --rtl \
"            if kk > kmax then kk := kmax; end if;" \
"            if kk > kmax then kk := kmax - 1; end if;"

# EXPECTED SURVIVOR.  COVERAGE HOLE, not an equivalent mutant.  MEASURED over
# the vector file: a_m > 0 in 0 of 320 cases and a_m == 0 in 0 of 320, so a_m
# is strictly negative throughout.  softplus is non-negative by construction,
# so gp = sp * a_m <= 0 and g_w is never positive: the min(0, .) branch is
# structurally unreachable here.  It is 2.1.3's defensive clamp against an
# ssm_a that violates 1.1(b), and nothing in the vector set violates 1.1(b).
# A single case with a_m > 0 would separate the two, so this is a stimulus
# gap and not an equivalence.
mutate R7 RTL "the min(0, g) guard is deleted" --rtl \
"            if g_w > 0 then
              ip_z <= (others => '0');" \
"            if false then
              ip_z <= (others => '0');"

mutate R8 RTL "eg is emitted on the Q14 grid, not Q15" --rtl \
"            ee := rsh_r(resize(ip_out, 64), SP_Q - 15);" \
"            ee := rsh_r(resize(ip_out, 64), SP_Q - 14);"

mutate R9 RTL "beta's saturation rail is one low" --rtl \
"            if ee > 65535 then ee := to_signed(65535, 64); end if;" \
"            if ee > 65534 then ee := to_signed(65534, 64); end if;"

mutate R10 RTL "err_g is never raised (2.1.6's clamp report is lost)" --rtl \
"              err_g <= '1';" \
"              err_g <= '0';"

# This one dies by ABORTING rather than by a mismatch: SP_ROM and EXP_ROM have
# 257 entries, so kmax = 511 indexes past the end and ghdl reports
# "index (257) out of bounds (0 to 256)".  That is still a kill -- the bench
# does not report PASS -- but it is a language-level kill, not the checker
# noticing, so it is labelled DEAD: rather than FAIL and is worth less than the
# others.  It is kept because an out-of-bounds ROM index is a real defect shape
# and the alternative (silently reading a neighbouring table) is what would
# happen in hardware.
mutate R11 RTL "every ROM is indexed as if it had 513 entries" --rtl \
"            if ip_rom = 2 then kmax := 511; else kmax := 255; end if;" \
"            kmax := 511;"

mutate R12 RTL "rsh_r's round-half-up bias is dropped (truncate)" --rtl \
"      return shift_right(t + shift_left(to_signed(1, t'length), k), s);" \
"      return shift_right(t, s);"

echo
echo "---- class C: ref/gdn_scalar_vec.c alone.  Must fail bit-exactness ----"

mutate C1 C "the C's saturation sentinel is 2^46 against the RTL's 2^45" --c \
"#define SAT_W (1LL << 45)" \
"#define SAT_W (1LL << 46)"

mutate C2 C "the C's exact-branch saturation is removed" --c \
"    if (v >  SAT_W) v =  SAT_W;
    if (v < -SAT_W) v = -SAT_W;" \
"    if (0) v =  SAT_W;
    if (0) v = -SAT_W;"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (bit-exactness MUST stay green.  The committed bench reports PASS"
echo "      on every one of these; only the gate above sees them)"

mutate B1 BOTH "the saturation sentinel drops from 2^45 to 2^30 in BOTH" \
  --rtl \
"  constant SAT_W : wide_t := shift_left(to_signed(1, wide_t'length), 45);" \
"  constant SAT_W : wide_t := shift_left(to_signed(1, wide_t'length), 30);" \
  --c \
"#define SAT_W (1LL << 45)" \
"#define SAT_W (1LL << 30)"

mutate B2 BOTH "the softplus POSITIVE tail is clamped at +16 in BOTH" \
  --rtl \
"            elsif arg >= to_signed(LIM, wide_t'length) then
              sp     <= arg;" \
"            elsif arg >= to_signed(LIM, wide_t'length) then
              sp     <= to_signed(LIM, wide_t'length);" \
  --c \
"        else if (arg >=  lim) sp = arg;                 /* 1.1(f) identity */" \
"        else if (arg >=  lim) sp = lim;                 /* 1.1(f) identity */"

mutate B3 BOTH "the softplus negative tail is clamped at -4 in BOTH" \
  --rtl \
"            if arg <= to_signed(-LIM, wide_t'length) then" \
"            if arg <= to_signed(-LIM/4, wide_t'length) then" \
  --c \
"        if      (arg <= -lim) sp = 0;" \
"        if      (arg <= -lim/4) sp = 0;"

# EXPECTED SURVIVOR, and the most informative line in this table: it measures
# the RESOLUTION FLOOR of every aggregate available here.  The mutation
# demonstrably fires -- MEASURED, 78 of the 320 eg values changed -- but every
# statistic moves in the safe direction or not at all:
#
#                mean signed   median|.|   n>1 LSB   n>100 LSB   max
#   baseline       +803.7880      0.0553        87          17   32768
#   B4 truncate    +803.5443      0.0440        81          17   32768
#
# The mean signed error is +803.79 because 17 cases are wrong by hundreds to
# tens of thousands of LSB (the saturation-cancellation defect described at
# the top of this file).  A half-LSB rounding bias is four orders of magnitude
# below that, so it cannot be separated from it by any summary of this vector
# set.  The gate is NOT widened or made two-sided to catch it: the honest
# result is that gdn_scalar's accuracy checking cannot resolve a rounding-mode
# change while its own worst cases are at full scale.  Note this is the same
# shape as S1 in 2026-08-28_b-accuracy-transcription-vs-arithmetic.md.
mutate B4 BOTH "eg's output round-half-up bias is dropped in BOTH (truncate)" \
  --rtl \
"            ee := rsh_r(resize(ip_out, 64), SP_Q - 15);" \
"            ee := shift_right(resize(ip_out, 64), SP_Q - 15);" \
  --c \
"        int64_t eg_o  = rshift_r(eg_sp, SP_Q - 15);" \
"        int64_t eg_o  = (int64_t)eg_sp >> (SP_Q - 15);"

mutate B5 BOTH "g's lower clamp moves from -16 to -8 in BOTH" \
  --rtl \
"            elsif g_w < resize(to_signed(-LIM, 32), 68) then
              ip_z  <= to_signed(-LIM, 32);" \
"            elsif g_w < resize(to_signed(-LIM/2, 32), 68) then
              ip_z  <= to_signed(-LIM/2, 32);" \
  --c \
"        int64_t gmin = -16LL << SP_Q;" \
"        int64_t gmin = -8LL << SP_Q;"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
