#!/usr/bin/env bash
# Mutation test for rtl/rmsnorm_bf.vhd and ref/rmsnorm_bf_vec.c.
#
# WHAT tb_rmsnorm_bf ACTUALLY CHECKS, established by reading it before any
# mutation was written.  Its own header states it: BIT-EXACT, NOT WITHIN A
# TOLERANCE.  It compares every o_mant element and every o_exp against the
# vector file and asserts nothing else, plus three defensive header asserts
# (vector shape, Q, and that the vectors' E_EPS/M_EPS match the ones the bench
# recomputes from its own EPS generic).  Its verdict phrase is
# "rmsnorm_bf: bit-exact with the C reference on all <n> cases".
#
# The accuracy question is answered in ref/rmsnorm_bf_vec.c, which carries a
# second, independent double path and PRINTS four figures.  It prints them and
# does not gate on any of them: the only non-zero return in that generator is
# bf_fail, which fires on a violated width bound, not on accuracy.  So as
# committed, NOTHING in the suite fails when rmsnorm_bf's arithmetic drifts
# away from the definition -- only when the two integer transcriptions drift
# apart.  rtl/rmsnorm_bf.vhd:84 claims "mutation-tested: 14 of 18 deliberate
# RTL faults are caught"; that was prose with no harness behind it, and this
# file is the harness.
#
# THIS SCRIPT SUPPLIES THE ACCURACY GATE, in the harness -- not in the RTL,
# not in the bench, not in the generator.  Nothing under rtl/, ref/ or
# sim/tb_*.vhd is edited; every mutation is applied to a COPY.
#
# THREE CLASSES:
#   RTL  -- rtl/rmsnorm_bf.vhd only.  Must fail bit-exactness.
#   C    -- ref/rmsnorm_bf_vec.c only.  Must fail bit-exactness.
#   BOTH -- the same recipe change in each.  Must LEAVE bit-exactness green.
#           Only the double oracle can see these, and this unit exists
#           because exactly such an error shipped in rmsnorm_rs.vhd.
#
# sim/rmsnorm_bf_vec.txt is COMMITTED, so sim/regress.sh never regenerates it
# and a C-side mutation would change nothing there.  Every run below generates
# its own vectors into a private workdir.  VERIFIED: the generator at its
# defaults reproduces the committed file byte for byte.
#
# Usage: bash sim/mutate_rmsnorm_bf.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  NELEM=<n>  SEED=<n>  Q=<n>  EPS=<f>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/rmsnorm_bf.vhd
REF=ref/rmsnorm_bf_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-200}"
NELEM="${NELEM:-128}"
SEED="${SEED:-20260826}"
QQ="${Q:-12}"
EPS="${EPS:-1.0e-6}"
mkdir -p "$SCRATCH"

# MEASURED on the unmutated pair at these arguments:
#   worst rel err of the GAIN vs double, MODEL range:  1.8019e-05 (case 79)
#   worst abs err of the OUTPUT vs double:             0.7704 LSB (case 79)
# The MODEL-range gain figure is the sensitive one and is the metric the
# design study used to reject the absolute-grid recipe, so it is the primary
# gate.  The whole-sweep gain figure (2.3539e-03) is deliberately NOT gated:
# it is set by the 2^-Q output grid of inv32 at gains near 0.06, which is
# quantization and not the block-floating recipe, and gating it would report a
# correct unit as broken.  Both numbers below are BASELINES with headroom, not
# bounds derived from the recipe.
ACC_GAIN="${ACC_GAIN:-3.0e-5}"
ACC_LSB="${ACC_LSB:-1.0}"

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
    patch_file "$RTL" "$dir/rmsnorm_bf.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/rmsnorm_bf.vhd"
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
  ( cd "$dir" && ./gen v.txt "$NCASE" "$NELEM" "$SEED" "$QQ" "$EPS" ) \
      >/dev/null 2>"$dir/gen.err"
  local grc=$?
  if [ $grc -ne 0 ] || [ ! -s "$dir/v.txt" ]; then
    NKILL=$((NKILL+1))
    printf '%-4s KILLED   by the GENERATOR OWN GUARD (rc %d)            -- %s\n' \
        "$tag" "$grc" "$desc"
    grep -m1 -E "out of the asserted range|not normalised|aborted" "$dir/gen.err" \
      | cut -c1-140 | sed 's/^/       /'
    return
  fi

  for f in fixed_luts_pkg fixed_pkg util_pkg; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "rtl/$f.vhd" >/dev/null 2>&1
  done
  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/rmsnorm_bf.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_rmsnorm_bf.vhd >/dev/null 2>&1

  # 900ms is a backstop only: the honest run takes 61 us of simulated time and
  # 7 s of wall time.  A mutant that DEADLOCKS runs to the stop time, so the
  # timeout, not the stop time, is what bounds the cost of a hang.
  ( cd "$dir" && timeout 300 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_rmsnorm_bf -gVECS=v.txt -gNCASE="$NCASE" -gN="$NELEM" -gQ="$QQ" \
      --max-stack-alloc=0 --stop-time=900ms ) >"$dir/run.log" 2>&1

  local bx acc
  if grep -q "bit-exact with the C reference on all" "$dir/run.log"; then
    bx=PASS
  else
    bx=FAIL
  fi
  acc=$(python3 - "$dir/gen.err" "$ACC_GAIN" "$ACC_LSB" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
g = re.search(r"GAIN vs double, MODEL range:\s+([0-9.eE+-]+)", t)
l = re.search(r"worst abs err of the OUTPUT vs double: ([0-9.eE+-]+) LSB", t)
if not g or not l:
    print("NOFIG"); sys.exit()
gv, lv = float(g.group(1)), float(l.group(1))
bad = (gv > float(sys.argv[2])) or (lv > float(sys.argv[3]))
print(("FAIL " if bad else "pass ") + "%.4e gain / %.4f LSB" % (gv, lv))
PY
)
  if [ "$bx" = FAIL ] || [ "${acc%% *}" = FAIL ]; then
    NKILL=$((NKILL+1))
    printf '%-4s KILLED   bit-exact %-4s  oracle %s   -- %s\n' "$tag" "$bx" "$acc" "$desc"
    if [ "$bx" = FAIL ]; then
      grep -m1 -E "MISMATCH|DIFFERS|assertion|error" "$dir/run.log" \
        | cut -c1-150 | sed 's/^/       /'
    fi
  else
    NSURV=$((NSURV+1))
    printf '%-4s SURVIVED bit-exact %-4s  oracle %s   -- %s\n' "$tag" "$bx" "$acc" "$desc"
  fi
}

echo "==================== mutations of rmsnorm_bf ======================="
echo "cases $NCASE x $NELEM, seed $SEED, Q $QQ, eps $EPS"
echo "accuracy gate supplied by THIS SCRIPT: model-range gain <= $ACC_GAIN,"
echo "output <= $ACC_LSB LSB.  The committed bench gates bit-exactness only."
echo
echo "---- class RTL: rtl/rmsnorm_bf.vhd alone.  Must fail bit-exactness ----"

mutate R1 "S_SEED2: the rsqrt ROM is indexed one bit high" --rtl \
"            rq_y     <= to_signed(RSQRT_ROM(to_integer(mant(29 downto 24))), 32);" \
"            rq_y     <= to_signed(RSQRT_ROM(to_integer(mant(30 downto 25))), 32);"

mutate R2 "S_RQ: the SECOND Newton iteration never updates y" --rtl \
"              when 18 => rq_y    <= resize(shift_right(mr_p_dy, 31), 32);
                         state <= S_RQ_RT1;" \
"              when 18 => state <= S_RQ_RT1;"

mutate R3 "S_RQ_FOLD: rq_d divides out Q, not e_out (the rmsnorm_rs defect)" --rtl \
"            rq_d := rq_p - e_out_r;   -- e_out, NOT Q: msq_r is no" \
"            rq_d := rq_p - Q;         -- e_out, NOT Q: msq_r is no"

mutate R4 "S_SHIFT2: the emit round bias is dropped (truncate)" --rtl \
"            if st = 0 then emit_bias <= (others => '0');
            else           emit_bias <= shift_left(to_signed(1, 64), st - 1);
            end if;" \
"            emit_bias <= (others => '0');"

mutate R5 "S_SHIFT2: one bit less headroom in the emit shift (msb-13)" --rtl \
"            if msb_p - 14 < 0 then st := 0; else st := msb_p - 14; end if;" \
"            if msb_p - 13 < 0 then st := 0; else st := msb_p - 13; end if;"

# R6, R7, R10 and R12 are EXPECTED SURVIVORS and are kept for that reason.
# Each is a different kind of limit and the kinds are not interchangeable.
# Every claim below is MEASURED, either by the bit-exact run itself (an
# RTL-only mutation that passes bit-exactness has produced byte-identical
# output on 200 cases x 128 elements, which IS the measurement of
# equivalence on this stimulus) or by instrumenting a copy of the generator.
#
#   R6  EQUIVALENT MUTANT, and the equivalence is structural, not accidental.
#       Normalising S to bit 31 instead of bit 30 doubles m_mean and raises
#       e_mean by one, so the represented VALUE m_mean * 2^-e_mean is
#       unchanged.  Downstream: when mean is the smaller term, d rises by one
#       and align = (2*m_mean) >> (d+1) = m_mean >> d exactly, including the
#       truncation, so msq and e_out are literally unchanged.  When eps is the
#       smaller term, msq doubles and e_out rises by one, so rq_d = rq_p -
#       e_out is unchanged and the normalised rsqrt mantissa is the same.  The
#       normalisation point of this block-floating form is a free parameter.
#   R7  COVERAGE HOLE **and** an equivalent mutant, which is worth separating.
#       MEASURED with a probe on a copy of the generator: `PROBE e_mean ==
#       E_EPS ties: 0` over 200 cases, so the branch this mutation moves is
#       never taken.  And ref/rmsnorm_bf_vec.c already argues it is equivalent
#       anyway: at d = 0 both branches compute m_mean + M_EPS with e_out =
#       e_mean = E_EPS.  So no stimulus could kill this one either.
#   R10 EQUIVALENT MUTANT BY CONSTRUCTION, and it is a warning about how to
#       write a rail mutation.  It moves the COMPARE from `om > 32767` to
#       `om > 32766` but leaves the emitted constant at 32767, so the only
#       input it changes behaviour for is om = 32767, which then takes the
#       saturate branch and emits 32767 -- the same value.  R13 is the same
#       site done properly, with the emitted constant moved too, and it dies.
#       C1 is the C-side version, and it dies, which is what shows the rail
#       itself is well covered (MEASURED: 640 saturations at +32767).
#   R12 CONFIRMS A DOCUMENTED CLAIM rather than exposing a weak bench.
#       rtl/rmsnorm_bf.vhd:95-98 states in prose that rounding the alignment
#       instead of truncating it is "invisible at every Q tested".  This entry
#       is RTL-only, so if the claim were false it would fail bit-exactness
#       against an unmutated C.  It does not, and neither does C2, the same
#       perturbation from the C side.  The aligned term is by construction the
#       negligible one, so a 1-LSB perturbation of it is far below the output
#       grid: neither check can see it and neither should be widened to.
mutate R6 "S_INV2: S renormalises to bit 31, not bit 30" --rtl \
"            shs_r  <= 30 - s_msb;
            e_mean <= LOG2N + 2 * xe + (30 - s_msb);" \
"            shs_r  <= 31 - s_msb;
            e_mean <= LOG2N + 2 * xe + (31 - s_msb);"

mutate R7 "S_INV4: the e_mean = E_EPS tie flips to the other branch" --rtl \
"            elsif e_mean > E_EPS then                     -- mean is the smaller" \
"            elsif e_mean >= E_EPS then                    -- mean is the smaller"

mutate R8 "S_RQ_FOLD: rq_E is one too small, so inv32 is halved" --rtl \
"            rq_E  <= Q - 30 - rq_he;" \
"            rq_E  <= Q - 31 - rq_he;"

mutate R9 "S_RQ_FOLD: the odd-rq_d 1/sqrt2 fold is dropped" --rtl \
"              rq_yfin <= resize(shift_right(mr_p_rt, 30), 32);
              rq_he   := (rq_d - 1) / 2;" \
"              rq_yfin <= rq_y;
              rq_he   := (rq_d - 1) / 2;"

mutate R10 "S_EMIT: the +32767 saturation rail is one low" --rtl \
"                if    om > 32767  then" \
"                if    om > 32766  then"

mutate R11 "S_INV6: the epsilon term is dropped when mean is the smaller" --rtl \
"            if mean_smaller then msq_r <= align_r  + M_EPS_C;" \
"            if mean_smaller then msq_r <= align_r;"

mutate R13 "S_EMIT: the +32767 rail EMITS 32766 (R10 done properly)" --rtl \
"                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(32767, 16));" \
"                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(32766, 16));"

# R14 IS AN EXPECTED SURVIVOR ON A STRUCTURALLY DEAD BRANCH, and it is here so
# that the deadness is measured rather than asserted.  Both
# rtl/rmsnorm_bf.vhd:92 and ref/rmsnorm_bf_vec.c's coverage report already
# claim the -32768 rail is unreachable by construction: shift_total puts
# max_raw >> shift_total inside [2^14, 2^15) and emit_bias is non-negative.
# MEASURED, from the generator's own branch table on the unmutated run:
#   emit saturates at +32767                 640
#   emit saturates at -32768                 NOT REACHED, unverified: 0
# So this survivor is a statement about the stimulus AND about the datapath,
# and it is not a hole a wider sweep could close.
mutate R14 "S_EMIT: the -32768 rail EMITS -32767 (a dead branch)" --rtl \
"                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(-32768, 16));" \
"                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(-32767, 16));"

# R12 IS AN EXPECTED SURVIVOR AND IS KEPT FOR THAT REASON.  rtl/rmsnorm_bf.vhd
# lines 95-98 claim, in prose, that "a one-LSB perturbation of the mean
# mantissa -- rounding the alignment instead of truncating it ... is invisible
# at every Q tested".  That is a claim about the OUTPUT, and this entry is the
# measurement of it: the mutation is RTL-only, so if the claim is false it
# fails bit-exactness against an unmutated C.  A survivor here CONFIRMS the
# claim rather than exposing a weak bench, and C2 below is the same
# perturbation seen from the C side.
mutate R12 "S_INV5: the alignment ROUNDS instead of truncating" --rtl \
"              align_r <= shift_right(m_mean_r, d_r);" \
"              align_r <= shift_right(m_mean_r + shift_left(to_signed(1, 64),
                                        maximum(d_r - 1, 0)), d_r);"

echo
echo "---- class C: ref/rmsnorm_bf_vec.c alone.  Must fail bit-exactness ----"
echo "     (whether the oracle ALSO moves is the resolution measurement)"

mutate C1 "the emit saturation limit is 32766, one below int16 max" --c \
"        if (om > 32767)       { r->o[j] =  32767; r->saturations++; cov[COV_SAT_HI]++; }" \
"        if (om > 32766)       { r->o[j] =  32766; r->saturations++; cov[COV_SAT_HI]++; }"

mutate C2 "the alignment ROUNDS instead of truncating (mirror of R12)" --c \
"    else if (mean_smaller) align = vsrl_a(m_mean, d);" \
"    else if (mean_smaller) align = vsrl_a(m_mean + (d > 0 ? (1LL << (d-1)) : 0), d);"

mutate C3 "the rsqrt ROM is indexed one bit high" --c \
"    int64_t rq_y     = RSQRT_ROM[(mant >> 24) & 0x3F];" \
"    int64_t rq_y     = RSQRT_ROM[(mant >> 25) & 0x3F];"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (bit-exactness MUST stay green; only the oracle can see these)"

# B1 is the flagship.  It reintroduces exactly the defect this unit exists to
# fix: rmsnorm_rs.vhd divides the rsqrt exponent out against Q because it
# assumes a fixed 2^-Q grid, and rmsnorm_bf's msq is on 2^-e_out instead.
mutate B1 "the rsqrt exponent is divided out against Q, not e_out" \
  --rtl \
"            rq_d := rq_p - e_out_r;   -- e_out, NOT Q: msq_r is no" \
"            rq_d := rq_p - Q;         -- e_out, NOT Q: msq_r is no" \
  --c \
"    int     rq_d = rq_p - e_out;" \
"    int     rq_d = rq_p - Q;"

mutate B2 "the SMALLER of mean and eps is dropped instead of added in" \
  --rtl \
"            if mean_smaller then msq_r <= align_r  + M_EPS_C;
            else                 msq_r <= m_mean_r + align_r;" \
"            if mean_smaller then msq_r <= M_EPS_C;
            else                 msq_r <= m_mean_r;" \
  --c \
"    int64_t msq = mean_smaller ? (align + M_EPS) : (m_mean + align);" \
"    int64_t msq = mean_smaller ? M_EPS : m_mean;"

mutate B3 "the emit shift keeps one bit less headroom (msb-13)" \
  --rtl \
"            if msb_p - 14 < 0 then st := 0; else st := msb_p - 14; end if;" \
"            if msb_p - 13 < 0 then st := 0; else st := msb_p - 13; end if;" \
  --c \
"    int st    = msb_p - 14; if (st < 0) st = 0;" \
"    int st    = msb_p - 13; if (st < 0) st = 0;"

mutate B4 "rq_E is one too small in both, so the gain is halved" \
  --rtl \
"            rq_E  <= Q - 30 - rq_he;" \
"            rq_E  <= Q - 31 - rq_he;" \
  --c \
"    int rq_E = Q - 30 - rq_he;" \
"    int rq_E = Q - 31 - rq_he;"

mutate B5 "ONE Newton iteration instead of two, in both" \
  --rtl \
"              when 18 => rq_y    <= resize(shift_right(mr_p_dy, 31), 32);
                         state <= S_RQ_RT1;" \
"              when 18 => state <= S_RQ_RT1;" \
  --c \
"    for (int it = 0; it < 2; it++) {" \
"    for (int it = 0; it < 1; it++) {"

mutate B6 "the emit round-half-up bias is dropped in BOTH (truncate)" \
  --rtl \
"            if st = 0 then emit_bias <= (others => '0');
            else           emit_bias <= shift_left(to_signed(1, 64), st - 1);
            end if;" \
"            emit_bias <= (others => '0');" \
  --c \
"    int64_t emit_bias = (st == 0) ? 0 : vsll64(1, st - 1);" \
"    int64_t emit_bias = 0;"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
