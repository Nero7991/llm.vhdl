#!/usr/bin/env bash
# Mutation test for rtl/gdn_recur.vhd and ref/gdn_recur_vec.c (B 2.1.4).
#
# WHAT sim/tb_gdn_recur.vhd ACTUALLY CHECKS, read out of the file before
# anything was mutated.  It is the only two-way bench in subsystem B where BOTH
# ways have teeth:
#
#   (a) BIT-EXACTNESS against the fixed path in the vector file -- every state
#       mantissa, se_new, e_o, o_acc and err_se -- counted into nexact and
#       asserted.  It catches transcription-into-VHDL errors precisely and
#       CANNOT catch an error in the recipe, because both sides share it.
#   (b) THE DOUBLE ORACLE, in a different number system: worst state error in
#       LSB of the unit's own grid against TOL_S, and the output dot normalised
#       by its term norm against TOL_O.  Unlike gdn_silu, gdn_scalar-before-
#       2026-08-29 and rmsnorm_bf, this one is ASSERTED, so sim/regress.sh can
#       fail it.  It is the only thing that can see a BOTH-class mutation.
#
# THREE CLASSES, and the split is the whole point:
#   RTL  -- rtl/gdn_recur.vhd only.  Must fail (a).
#   C    -- ref/gdn_recur_vec.c only.  Must fail (a).
#   BOTH -- the same recipe change in each.  (a) STAYS GREEN by construction;
#           only (b) can see it.  These are the rows that measure whether the
#           accuracy gate is worth anything.
#
# THE HARNESS HAS THREE STATES, NOT TWO.  A mutation that makes the DUT abort
# -- a bound check, a shape assertion, the unit's own `diff outside s18` -- gets
# no verdict line at all.  Scoring "no mismatch line" as a survivor would count
# those as passes; that is the defect TRACK B-GATE introduced and caught in its
# own harness on 2026-08-29.  ABORT is a separate verdict, COUNTED AS A KILL,
# and named separately because the language stopped the run rather than the
# checker noticing.
#
# Nothing under rtl/, ref/ or sim/ is edited: every mutation is applied to a
# COPY in a private scratch directory, and the generator is re-run there.
# VERIFIED: the generator run from the repo root reproduces the committed
# sim/gdn_recur_vec.txt byte for byte, so a mutant's vectors differ from the
# committed ones only by the mutation.
#
# THE SEED MATTERS AND THE COMMITTED ONE IS NOT SPECIAL.  ref/gdn_recur_vec.c
# hardcodes rs_ = 20260825.  MEASURED over 52 seeds (a patched copy taking the
# seed as argv[4]; see docs/debugging/2026-08-29_gdn-recur-coverage-and-dm.md):
# the honest unit's worst state error ranges 1.51 to 15.43 LSB and its worst
# output figure 8.1e-6 to 7.9e-4.  So a MAX-only gate on one seed is not a
# statement about the unit, and the aggregate this script computes carries a
# COUNT as well, for the reason B-GATE measured on rmsnorm_bf: a real defect
# can sit inside the honest max range while moving the count by 10x.
#
#
# CORRECTED 2026-08-29 (TRACK B-SEED).  A SECOND sweep, 30 seeds and a
# different seed set, puts the honest worst state error at 32.12 LSB at seed
# 20260101 -- 2.08x the 52-seed maximum of 15.43 quoted above.  Two sweeps
# disagreeing by 2.08x on the maximum is the finding: this statistic has a
# heavy tail, no feasible seed count bounds it, and the COUNT is the figure
# that carries the gate.  AGG_WS was raised accordingly, below.
#
# Usage: bash sim/mutate_gdn_recur.sh
# Env:   SCRATCH=<dir>
#
# THERE IS NO SEED KNOB, and there was never a working one.  A `SEED` variable
# used to be declared here and printed in the header, but ref/gdn_recur_vec.c
# takes no seed argument and this script never passed it one, so every run was
# the hardcoded 20260825 while the header claimed otherwise.  Removed
# 2026-08-29 rather than left to mislead.  To sweep, patch a COPY of the
# generator in a scratch directory (replace the `rs_ = 20260825ULL;`
# assignment), verify it is byte-identical to sim/gdn_recur_vec.txt at the
# default seed BEFORE trusting anything it produces, and sweep that.
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_recur.vhd
REF=ref/gdn_recur_vec.c
TB=sim/tb_gdn_recur.vhd
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"

# MEASURED baselines for THIS script's own aggregate, at the committed seed,
# with headroom.  Baselines, not bounds derived from the recipe:
#   worst state 8.955 LSB, median 0.577, 29 physical columns past 1 LSB.
# RETUNED 2026-08-29 (TRACK B-SEED).  AGG_WS 24.0 -> 48.0: over a SECOND
# 40-seed sweep the honest aggregate maximum is 32.12 LSB (seed 20260101), so
# 24.0 fired on the HONEST unit at 1 of 40.  48.0 is 1.49x that.  MEASURED
# BOTH WAYS: kill ratio unchanged at 24 of 33, because no mutation's aggregate
# max lands between 24 and 48 -- the agg-FAIL rows read 32660.6, 32660.6,
# 2600.3, 9.27, 10.45, 1.166e7 and 2261.7, and the two under 48 are caught by
# AGG_N1 (199 and 130 against a gate of 66), not by AGG_WS.
# AGG_MED and AGG_N1 are NOT changed: over the same 40 seeds they range
# 0.5303 .. 0.6362 and 12 .. 44 and fire on 0 of 40.
AGG_WS="${AGG_WS:-48.0}"     # baseline 8.955, 40-seed max 32.12
AGG_MED="${AGG_MED:-0.90}"   # baseline 0.577, 40-seed max 0.6362
AGG_N1="${AGG_N1:-66}"       # baseline 29,    40-seed max 44

NKILL=0; NSURV=0; NABORT=0; NTOT=0

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
    patch_file "$RTL" "$dir/gdn_recur.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED -- a mutation that did not apply has tested nothing"; return; }
  else
    cp "$RTL" "$dir/gdn_recur.vhd"
  fi
  if [ ${#c_args[@]} -gt 0 ]; then
    patch_file "$REF" "$dir/gen.c" "${c_args[@]}" || {
      echo "$tag  C ANCHOR FAILED -- a mutation that did not apply has tested nothing"; return; }
  else
    cp "$REF" "$dir/gen.c"
  fi

  if ! cc -O2 -w -I ref -o "$dir/gen" "$dir/gen.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  # run from the REPO ROOT: the generator opens ref/gdn_eg_qwen3_27b.txt by a
  # path relative to cwd, and silently exits(1) if it is not there.
  "$dir/gen" "$dir/v.txt" 1 1 >/dev/null 2>"$dir/gen.err"
  if [ ! -s "$dir/v.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NOTHING"; sed -n 1,3p "$dir/gen.err"; return
  fi

  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_recur.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" "$TB" >>"$dir/analyze.log" 2>&1

  ( cd "$dir" && timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_recur -gVECS=v.txt --max-stack-alloc=0 --stop-time=900ms ) \
      >"$dir/run.log" 2>&1

  local res
  res=$(python3 - "$dir/run.log" "$dir/v.txt" "$AGG_WS" "$AGG_MED" "$AGG_N1" <<'PY'
import re, sys, statistics
log = open(sys.argv[1], errors="replace").read()

# LIVENESS FIRST.  The two verdicts below are read off markers that a run
# which died early cannot print, so "no failure marker" must never be read as
# "passed" without separate evidence that the run reached the end.  The bench
# prints its measurement summary unconditionally as its last act, which is
# exactly what makes it usable as the liveness marker.
ran = "physically realizable ones, worst vs the" in log

# (a) bit-exactness.  One report line per offending case, plus a summary
# assertion; either is conclusive.
if "NOT BIT-EXACT vs C" in log or "is NOT bit-exact with the C recipe" in log:
    bx = "FAIL"
elif ran:
    bx = "pass"
else:
    bx = "DEAD"

# (b) the BENCH's own oracle gates -- the only verdict sim/regress.sh can fail.
# FOUR gates now: the two maxima, the two counts, and the floor.
if ("OUT OF TOLERANCE vs ORACLE" in log or "outside oracle tolerance" in log
        or "past 1 state LSB, over the gate" in log
        or "past 4 state LSB, over the gate" in log
        or "columns reached the" in log):
    bench = "FAIL"
elif ran:
    bench = "pass"
else:
    bench = "DEAD"

m = re.search(r"worst vs the double ORACLE is ([0-9.eE+-]+) state LSB and "
              r"([0-9.eE+-]+) of the output", log)
bws, bwo = (float(m.group(1)), float(m.group(2))) if m else (float('nan'),)*2

# (c) this script's own aggregate over the file's OWN two oracle columns.  It
# compares the C fixed path against the C double oracle, so it is a statement
# about the RTL only because (a) has separately proved them bit-identical.
# Carries a COUNT as well as a max: B-GATE measured that a max alone cannot
# separate a real defect from an honest seed on units shaped like this.
ws = []
f = open(sys.argv[2])
ncase, dim = map(int, f.readline().split())
for _ in range(ncase):
    hd = f.readline().split()
    phys = int(hd[0])
    f.readline(); f.readline(); f.readline()          # smant, kn, qs
    snew = list(map(int, f.readline().split()))
    t = f.readline().split()
    se_new, err = int(t[0]), int(t[3])
    ur = list(map(float, f.readline().split()))
    f.readline()                                       # orr, onorm
    if phys != 1 or err != 0:
        continue
    ws.append(max(abs(snew[i] - ur[i] * 2.0 ** se_new) for i in range(dim)))
if ws:
    wmax = max(ws); wmed = statistics.median(ws); n1 = sum(1 for x in ws if x > 1.0)
else:
    wmax = wmed = float('nan'); n1 = -1
bad = (not ws) or wmax > float(sys.argv[3]) or wmed > float(sys.argv[4]) \
      or n1 > int(sys.argv[5])
print("%s|%s|%s|bench %8.3f / %.2e   agg max %8.3f med %.3f n>1LSB %3d  n %3d" %
      (bx, bench, "FAIL" if bad else "pass", bws, bwo, wmax, wmed, n1, len(ws)))
PY
)
  if [ -z "$res" ]; then res="DEAD|DEAD|DEAD|(no analysis)"; fi
  local bx="${res%%|*}"; local rest="${res#*|}"
  local bench="${rest%%|*}"; rest="${rest#*|}"
  local agg="${rest%%|*}"; local fig="${rest#*|}"

  local verdict
  if [ "$bx" = DEAD ] && [ "$bench" = DEAD ]; then
    verdict=ABORT; NABORT=$((NABORT+1)); NKILL=$((NKILL+1))
  elif [ "$bx" != pass ] || [ "$bench" != pass ] || [ "$agg" != pass ]; then
    verdict=KILLED; NKILL=$((NKILL+1))
  else
    verdict=SURVIVED; NSURV=$((NSURV+1))
  fi
  printf '%-4s %-4s %-8s exact %-4s bench %-4s agg %-4s  %s  -- %s\n' \
    "$tag" "$cls" "$verdict" "$bx" "$bench" "$agg" "$fig" "$desc"
}

echo "===================== mutations of gdn_recur ========================"
echo "seed 20260825 (ref/gdn_recur_vec.c hardcodes it; there is no knob),"
echo "384 cases, 274 of them physically realizable and checked"
echo "against the double oracle.  columns:"
echo "  exact = the bench's bit-exact verdict (severity error, gated)"
echo "  bench = the bench's ORACLE gate, the only one sim/regress.sh can fail"
echo "  agg   = this script's own aggregate: max $AGG_WS LSB, median $AGG_MED,"
echo "          at most $AGG_N1 physical columns past 1 LSB"
echo

mutate M0 CTRL "CONTROL: unmutated"

echo
echo "---- class RTL: rtl/gdn_recur.vhd alone.  Must fail bit-exactness ----"

mutate R1 RTL "site 6's w18 rounding bias is dropped on the sk-dot path" --rtl \
"              w18r(k) <= resize(shift_right(m1(k) + to_signed(2**12, 33), 13), 19);" \
"              w18r(k) <= resize(shift_right(m1(k), 13), 19);"

mutate R2 RTL "ske is se_j + 16, not se_j + 17" --rtl \
"              ske   <= resize(se_j, 16) + 17 - (p - 14);" \
"              ske   <= resize(se_j, 16) + 16 - (p - 14);"

mutate R3 RTL "site 7 normalizes sk to 15 bits, not 16" --rtl \
"            p := msb_pos(sk_abs);
            if p - 14 > 0 then
              sk_sh <= p - 14;
              sk_bi <= shift_left(to_signed(1, 42), p - 15);
              ske   <= resize(se_j, 16) + 17 - (p - 14);" \
"            p := msb_pos(sk_abs);
            if p - 13 > 0 then
              sk_sh <= p - 13;
              sk_bi <= shift_left(to_signed(1, 42), p - 14);
              ske   <= resize(se_j, 16) + 17 - (p - 13);"

mutate R4 RTL "stage 3 takes the MAX of the two exponents, not the min" --rtl \
"            elsif ev_i < ske_i then             ed_i := ev_i;
            else                                ed_i := ske_i; end if;" \
"            elsif ev_i > ske_i then             ed_i := ev_i;
            else                                ed_i := ske_i; end if;"

mutate R5 RTL "the eg = 0 masked-operand arm is dropped at e_d (EG0_ED half off)" --rtl \
"            if (tk0 = '1' or (EG0_ED and eg = 0)) and TK0_ED then ed_i := ev_i;" \
"            if (tk0 = '1') and TK0_ED then ed_i := ev_i;"

mutate R6 RTL "the eg = 0 masked-operand arm is dropped at e_u (the other half)" --rtl \
"            if tk0 = '1' or (EG0_ED and eg = 0) then
              eu_i := ekd_i;                 -- the masked zero has no exponent" \
"            if tk0 = '1' then
              eu_i := ekd_i;                 -- the masked zero has no exponent"

mutate R7 RTL "sat16's positive rail is one low" --rtl \
"    if    v >  32767 then return to_signed( 32767, 16);" \
"    if    v >  32766 then return to_signed( 32766, 16);"

mutate R8 RTL "sat16's negative rail is one high" --rtl \
"    elsif v < -32768 then return to_signed(-32768, 16);" \
"    elsif v < -32767 then return to_signed(-32767, 16);"

mutate R9 RTL "the final requantize keeps 14 bits, not 15" --rtl \
"            amax := amp(0);
            p := msb_pos(amax);
            if p - 14 > 0 then
              shq    <= p - 14;
              bias_q <= shift_left(to_signed(1, 35), p - 15);" \
"            amax := amp(0);
            p := msb_pos(amax);
            if p - 13 > 0 then
              shq    <= p - 13;
              bias_q <= shift_left(to_signed(1, 35), p - 14);"

mutate R10 RTL "the final requantize's rounding bias is dropped" --rtl \
"              bias_q <= shift_left(to_signed(1, 35), p - 15);" \
"              bias_q <= (others => '0');"

mutate R11 RTL "e_o is se_new + 17" --rtl \
"            e_o    <= resize(e_u - shq + 18, 8);" \
"            e_o    <= resize(e_u - shq + 17, 8);"

mutate R12 RTL "2.1.6's range check drops the e_o arm (se_new only)" --rtl \
"            if (e_u - shq) > 127 or (e_u - shq) < -128
               or (e_u - shq + 18) > 127 or (e_u - shq + 18) < -128 then" \
"            if (e_u - shq) > 127 or (e_u - shq) < -128 then"

mutate R13 RTL "stage 3's two alignment shifts are swapped" --rtl \
"            diff <= resize(shift_right(resize(v_j, 18), p), 18)
                  - resize(shift_right(skm, q), 18);" \
"            diff <= resize(shift_right(resize(v_j, 18), q), 18)
                  - resize(shift_right(skm, p), 18);"

mutate R14 RTL "D_NORM keeps 11 bits of d, not 15" --rtl \
"            p := msb_pos(dabs);
            if p - 14 > 0 then
              shd   <= p - 14;
              dbias <= shift_left(to_signed(1, 35), p - 15);" \
"            p := msb_pos(dabs);
            if p - 10 > 0 then
              shd   <= p - 10;
              dbias <= shift_left(to_signed(1, 35), p - 11);"

mutate R15 RTL "stage 4's two output shifts su and sk2 are swapped" --rtl \
"            su <= p; sk2 <= q;" \
"            su <= q; sk2 <= p;"

mutate R16 RTL "site 7's rounding bias is dropped (skm truncates)" --rtl \
"              sk_bi <= shift_left(to_signed(1, 42), p - 15);" \
"              sk_bi <= (others => '0');"

mutate R17 RTL "tk0 no longer masks the STATE READ, so it enters the sk dot" --rtl \
"                if tk0 = '1' then
                  sf(k) <= (others => '0');
                else
                  sf(k) <= signed(s_in((base+k+1)*16-1 downto (base+k)*16));
                end if;" \
"                sf(k) <= signed(s_in((base+k+1)*16-1 downto (base+k)*16));"

mutate R18 RTL "the output dot uses q BEFORE the pipeline aligns it (q2, not q3)" --rtl \
"              m3(k) <= resize(smr(k) * q3(k), 42);" \
"              m3(k) <= resize(smr(k) * q2(k), 42);"

# EXPECTED SURVIVOR, and a TRUE EQUIVALENT MUTANT.  The amax tree reduces a
# MAXIMUM, so replacing a strict compare with a non-strict one changes which of
# two EQUAL operands is kept and never changes the value kept.  No stimulus can
# separate them.  Kept because it measures the floor: this table cannot detect
# a change that provably cannot alter an output.
mutate R19 RTL "the amax reduction keeps the later of two equal operands" --rtl \
"                if amp(k + half) > amp(k) then amp(k) <= amp(k + half); end if;" \
"                if amp(k + half) >= amp(k) then amp(k) <= amp(k + half); end if;"

echo
echo "---- class C: ref/gdn_recur_vec.c alone.  Must fail bit-exactness ----"

mutate C1 C "the C normalizes sk to 15 bits against the RTL's 16" --c \
"        int sh_sk = msb_pos_u((uint64_t)llabs(sk_acc)) - 14;" \
"        int sh_sk = msb_pos_u((uint64_t)llabs(sk_acc)) - 13;"

mutate C2 C "the C's e_kd is 16 + e_dm against the RTL's 15 + e_dm" --c \
"        int e_kd = 15 + e_dm;" \
"        int e_kd = 16 + e_dm;"

mutate C3 C "the C's v is floored onto e_d one bit harder than the RTL's" --c \
"        int s1 = e_v - e_d, s2 = ske - e_d;" \
"        int s1 = e_v - e_d + 1, s2 = ske - e_d;"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ---------"
echo "     (bit-exactness stays green by construction; only the oracle sees)"

mutate B1 BOTH "stage 3 floors skm ONE MORE BIT onto e_d (the site root-caused 2026-08-29)" \
  --rtl \
"            q := to_integer(ske - e_d);
            if q < 0 then q := 0; elsif q > 63 then q := 63; end if;" \
"            q := to_integer(ske - e_d) + 1;
            if q < 0 then q := 0; elsif q > 63 then q := 63; end if;" \
  --c \
"        int s1 = e_v - e_d, s2 = ske - e_d;" \
"        int s1 = e_v - e_d, s2 = ske - e_d + 1;"

mutate B2 BOTH "site 6's w18 rounding bias is dropped in BOTH (truncate)" \
  --rtl \
"              w18r(k) <= resize(shift_right(m1(k) + to_signed(2**12, 33), 13), 19);" \
"              w18r(k) <= resize(shift_right(m1(k), 13), 19);" \
  --rtl \
"                w18a(base+k) <= resize(shift_right(m1(k) + to_signed(2**12, 33), 13), 19);" \
"                w18a(base+k) <= resize(shift_right(m1(k), 13), 19);" \
  --c \
"            w18[i]     = round_shift(w, 13);" \
"            w18[i]     = floor_shr(w, 13);"

mutate B3 BOTH "the final requantize truncates instead of rounding, in BOTH" \
  --rtl \
"              bias_q <= shift_left(to_signed(1, 35), p - 15);" \
"              bias_q <= (others => '0');" \
  --c \
"        for (int i = 0; i < DIM; i++) snew[i] = mv4i_sat16(round_shift(u[i], sh));" \
"        for (int i = 0; i < DIM; i++) snew[i] = mv4i_sat16(floor_shr(u[i], sh));"

mutate B4 BOTH "site 7's skm truncates instead of rounding, in BOTH" \
  --rtl \
"              sk_bi <= shift_left(to_signed(1, 42), p - 15);" \
"              sk_bi <= (others => '0');" \
  --c \
"        int64_t skm = round_shift(sk_acc, sh_sk);" \
"        int64_t skm = floor_shr(sk_acc, sh_sk);"

mutate B5 BOTH "d_m truncates instead of rounding, in BOTH" \
  --rtl \
"            p := msb_pos(dabs);
            if p - 14 > 0 then
              shd   <= p - 14;
              dbias <= shift_left(to_signed(1, 35), p - 15);" \
"            p := msb_pos(dabs);
            if p - 14 > 0 then
              shd   <= p - 14;
              dbias <= (others => '0');" \
  --c \
"        int64_t d_m  = round_shift(draw, shd);" \
"        int64_t d_m  = floor_shr(draw, shd);"

mutate B6 BOTH "D_NORM keeps 11 bits of d instead of 15, in BOTH" \
  --rtl \
"            p := msb_pos(dabs);
            if p - 14 > 0 then
              shd   <= p - 14;
              dbias <= shift_left(to_signed(1, 35), p - 15);" \
"            p := msb_pos(dabs);
            if p - 10 > 0 then
              shd   <= p - 10;
              dbias <= shift_left(to_signed(1, 35), p - 11);" \
  --c \
"        if (d_norm) { shd = msb_pos_u((uint64_t)llabs(draw)) - 14; if (shd < 0) shd = 0; }" \
"        if (d_norm) { shd = msb_pos_u((uint64_t)llabs(draw)) - 10; if (shd < 0) shd = 0; }"

# THE FLAGSHIP.  This reintroduces, in both languages at once, exactly the
# defect the 2026-08-26 amendment was written to remove: the eg = 0 arm of the
# masked-operand rule.  docs/debugging/2026-08-26_gdn-first-token-dm-grid.md
# measures it at 7 of 8 failing columns and a 110% error on the whole column's
# contribution to the output dot.  If the gate cannot see this one, the gate is
# decoration.
mutate B7 BOTH "EG0_ED is removed in BOTH: the eg = 0 masked operand is back in both grids" \
  --rtl \
"            if (tk0 = '1' or (EG0_ED and eg = 0)) and TK0_ED then ed_i := ev_i;" \
"            if (tk0 = '1') and TK0_ED then ed_i := ev_i;" \
  --rtl \
"            if tk0 = '1' or (EG0_ED and eg = 0) then
              eu_i := ekd_i;                 -- the masked zero has no exponent" \
"            if tk0 = '1' then
              eu_i := ekd_i;                 -- the masked zero has no exponent" \
  --c \
"        int masked = tk0 || (eg == 0);" \
"        int masked = tk0;"

mutate B8 BOTH "TK0_ED is removed at e_d in BOTH: the tk = 0 phantom grid is back" \
  --rtl \
"            if (tk0 = '1' or (EG0_ED and eg = 0)) and TK0_ED then ed_i := ev_i;" \
"            if false and TK0_ED then ed_i := ev_i;" \
  --c \
"        if (masked && tk0_ed) e_d = e_v;" \
"        if (0 && tk0_ed) e_d = e_v;"

mutate B9 BOTH "D_NORM is removed in BOTH: d_m goes back to the pinned e_d grid" \
  --rtl \
"            if D_NORM then state <= S_DN1; else state <= S_D4; end if;" \
"            state <= S_D4;" \
  --c \
"        if (d_norm) { shd = msb_pos_u((uint64_t)llabs(draw)) - 14; if (shd < 0) shd = 0; }" \
"        if (0) { shd = msb_pos_u((uint64_t)llabs(draw)) - 14; if (shd < 0) shd = 0; }"

mutate B10 BOTH "stage 4 drops the min: e_u is always se_j + 2 when not masked" \
  --rtl \
"            elsif sej_i < ekd_i then
              eu_i := sej_i;
            else
              eu_i := ekd_i;
            end if;" \
"            else
              eu_i := sej_i;
            end if;" \
  --c \
"        int e_u  = masked ? e_kd : ((se_j + 2 < e_kd) ? se_j + 2 : e_kd);" \
"        int e_u  = masked ? e_kd : (se_j + 2);"

echo
echo "kill ratio: $NKILL killed ($NABORT of them by ABORT), $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
