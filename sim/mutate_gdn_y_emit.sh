#!/usr/bin/env bash
# Mutation test for rtl/gdn_y_emit.vhd and ref/gdn_y_emit_vec.c.
#
# WHAT tb_gdn_y_emit ACTUALLY CHECKS, established by reading the file before
# anything was mutated, because a mutation aimed at something the bench never
# claimed to cover teaches nothing.  Its header says NO TOLERANCE, and the
# stimulus process checks FIVE things per case (lines 177-206):
#
#   1. the emitted element COUNT equals HEADS*DIM
#   2. o_last coincides with the FINAL o_valid, not one element either side
#   3. y_exp, exact
#   4. o_sat, exact
#   5. every y element, bit-exact against the vector file
#
# plus, in the overlap phase, block 2's values re-checked and an OVERLAP
# THROUGHPUT bound (line 258) against the OCYC_BOUND generic, default 17000.
# MEASURED baseline 15,390 cycles double buffered against 18,462 with the
# banks collapsed, so the bound sits between them.
#
# The overlap phase is NOT a back-pressure test, despite reading like one.
# MEASURED (see R12): in_ready never falls anywhere in this bench, because two
# blocks driven into two banks can never fill both.  It is a throughput test
# and a second correctness pass, and nothing else.
#
# ONE OF THOSE FIVE IS CHECKED IN ONE DIRECTION ONLY, and it is not visible
# from the bench.  MEASURED from the generator's own summary at the shipped
# arguments:
#
#   saturated elements: 0   all-zero cases: 7   (-32768)^2 products: 18432
#
# NOTHING SATURATES.  v_sat is 0 in all 48 cases, so check 4 only ever
# confirms o_sat LOW.  A DUT with the saturation detect removed passes; only
# one with it stuck high fails.  R13 and C3 below are the two halves of that
# measurement, and C3 is an EQUIVALENT MUTANT for exactly this reason.  The
# saturation path of this unit is unverified, in both transcriptions.
#
# THE ACCURACY GATE IS REAL AND IT IS IN THE GENERATOR, NOT THE BENCH.
# ref/gdn_y_emit_vec.c lines 217-222 end with
#   if (worst >= 1.0) { fprintf(stderr, "  FAIL: reaches 1.0 LSB, ..."); return 1; }
# and print "worst error vs double oracle: <x> LSB of the output grid" either
# way.  The bound is DERIVED: the alignment floor loses < 2^-sh output LSB and
# the requantize round <= 0.5, so < 1.0 always.  MEASURED baseline 0.7500 LSB
# at case 4, shape 4, sh = 0, max alignment shift 2 -- i.e. the baseline
# already sits at three quarters of the gate, entirely from the alignment
# floor.  So the BOTH class does NOT need a gate invented by this script; it
# needs the generator's own exit code read, which is what happens below.
#
# THREE CLASSES:
#   RTL  -- rtl/gdn_y_emit.vhd only.  Must fail the bench.
#   C    -- ref/gdn_y_emit_vec.c only.  Must fail the bench.  Whether the
#           oracle ALSO moves is the resolution measurement.
#   BOTH -- the same recipe change in each.  Must leave the bench GREEN and
#           can only be caught by the double oracle.
#
# sim/gdn_y_emit_vec.txt is COMMITTED, so sim/regress.sh never regenerates it
# and a mutation of the generator would change nothing there.  Every run below
# generates its own vectors into a private workdir.  VERIFIED: the generator
# at these arguments reproduces the committed file byte for byte.
#
# Usage: bash sim/mutate_gdn_y_emit.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  HEADS=<n>  DIM=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_y_emit.vhd
REF=ref/gdn_y_emit_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-48}"
HEADS="${HEADS:-24}"
DIM="${DIM:-128}"
mkdir -p "$SCRATCH"

# --stop-time is 30ms, not the 900ms several older scripts use.  MEASURED: the
# longest LEGITIMATE run is 4.585 ms of simulated time (7.2 s wall), so 30 ms
# is a 6.5x margin -- and a mutation that HANGS runs to the stop time, so
# 900 ms would cost 30x more wall clock for every mutant that hangs.  MEASURED
# on the run recorded in the report: none of these actually hang, but the
# equivalent mutation in sim/mutate_gdn_head_emit.sh does, so the bound stays.
STOP="${STOP:-30ms}"

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
    patch_file "$RTL" "$dir/gdn_y_emit.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/gdn_y_emit.vhd"
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
  # The generator RETURNS NONZERO when its own oracle trips, and it does so
  # AFTER fclose(), so the vectors exist either way.  A nonzero exit here is a
  # RESULT, not a broken run: it is the oracle verdict.
  ( cd "$dir" && ./gen v.txt "$NCASE" "$HEADS" "$DIM" ) >/dev/null 2>"$dir/gen.err"
  local grc=$?
  if [ ! -s "$dir/v.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NO VECTORS"; sed -n 1,3p "$dir/gen.err"; return
  fi

  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_y_emit.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_y_emit.vhd \
       >/dev/null 2>&1

  ( cd "$dir" && timeout 900 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_y_emit -gVECS=v.txt -gHEADS="$HEADS" -gDIM="$DIM" \
      --max-stack-alloc=0 --stop-time="$STOP" ) >"$dir/run.log" 2>&1

  local bench why acc
  if grep -q "tb_gdn_y_emit: PASS" "$dir/run.log"; then
    bench=PASS; why=""
  else
    bench=FAIL
    # Which of the bench's checks actually noticed.  A mutation that only ever
    # trips one of them has told us which check is load bearing.
    if   grep -q "OVERLAP THROUGHPUT" "$dir/run.log"; then why="throughput"
    elif grep -q "o_last at element"  "$dir/run.log"; then why="o_last"
    elif grep -q "elements, want"     "$dir/run.log"; then why="count"
    elif grep -q "o_sat mismatch"     "$dir/run.log"; then why="o_sat"
    elif grep -q "y_exp got"          "$dir/run.log"; then why="y_exp"
    elif grep -q ": got .* want "     "$dir/run.log"; then why="y value"
    # The bench's accuracy gate, added 2026-08-29.  Listed AFTER the bit-exact
    # claims deliberately: when both fire, the bit-exact one is the sharper
    # diagnosis, and the accuracy gate is the one that matters only when the
    # bit-exact check is green by construction, i.e. the BOTH class.
    # The bench's NORMALISATION check, added 2026-08-29.  It is listed BEFORE
    # the accuracy gate because when both fire it is the sharper diagnosis: it
    # names an output-grid error, which is the one class no error measured in
    # LSB of that grid can see.
    elif grep -q "NORMALISATION failed" "$dir/run.log"; then why="normalisation"
    elif grep -q "OUT OF TOLERANCE"   "$dir/run.log"; then
      why="accuracy: $(sed -n 's/.*OUT OF TOLERANCE -- \(worst\|mean\|the oracle saw\|[0-9]* elements\).*/\1/p' "$dir/run.log" | head -1)"
    elif grep -q "assertion failure"  "$dir/run.log"; then why="RTL assert"
    else why="no verdict (hang/timeout)"
    fi
  fi
  acc=$(python3 - "$dir/gen.err" "$grc" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"worst error vs double oracle: ([0-9.eE+-]+) LSB", t)
v = m.group(1) if m else "?"
print(("FAIL " if sys.argv[2] != "0" else "pass ") + v + " LSB")
PY
)
  if [ "$bench" = FAIL ] || [ "${acc%% *}" = FAIL ]; then
    NKILL=$((NKILL+1))
    printf '%-4s KILLED   bench %-4s %-22s oracle %-14s -- %s\n' \
      "$tag" "$bench" "${why:+[$why]}" "$acc" "$desc"
  else
    NSURV=$((NSURV+1))
    printf '%-4s SURVIVED bench %-4s %-22s oracle %-14s -- %s\n' \
      "$tag" "$bench" "" "$acc" "$desc"
  fi
}

echo "===================== mutations of gdn_y_emit ======================"
echo "cases $NCASE x $HEADS heads x $DIM, stop-time $STOP"
echo "bench gate: count + o_last + y_exp + o_sat + bit-exact y, a 17000-cycle bound,"
echo "            and (since 2026-08-29) FOUR accuracy figures against the bench's"
echo "            own real-valued oracle, which excludes NOTHING: max 1.5 LSB,"
echo "            <=12000 elements past 0.5 LSB, mean 0.350 LSB, floor 147456."
echo "oracle gate: ref/gdn_y_emit_vec.c's own 1.0 output-LSB bound (baseline 0.7500)."
echo "            NOTE this column EXCLUDES a whole case when any element saturated,"
echo "            which is what empties it on B4 and makes it read 0.0000 and pass."
echo "            The bench column is the one to read for the BOTH class."
echo
echo "---- class RTL: rtl/gdn_y_emit.vhd alone.  Must fail the bench -------"

# R1 is an EXPECTED SURVIVOR, kept for that reason, and it is the same shape
# as gdn_head_emit's R1.  MEASURED with a probe on a copy of the generator:
#
#   PROBE cases where round-aligned amax differs: 0 of 48; msb_pos differs: 0
#
# amax's ONLY consumer is msb_pos(amax), and on this stimulus the rounded and
# floored alignments do not even produce a different amax, let alone a
# different msb_pos.  sh_r, y_exp and every output element are therefore
# identical, and amax is not a port.  No bench written against this interface
# could kill it.  R2 is the same edit on pass C, where the value DOES reach an
# output, and it dies.
mutate R1 "pass B ALIGNS BY ROUNDING instead of flooring (amax only)" --rtl \
"              p4_al <= shift_right(p3_prod, p3_shj);
            end if;

            -- stage 5: absolute value ALONE" \
"              if p3_shj = 0 then
                p4_al <= p3_prod;
              else
                p4_al <= shift_right(p3_prod
                          + shift_left(to_signed(1, 32), p3_shj - 1), p3_shj);
              end if;
            end if;

            -- stage 5: absolute value ALONE"

mutate R2 "pass C aligns by ROUNDING, so the alignment is double-rounded" --rtl \
"              p4_al <= shift_right(p3_prod, p3_shj);   -- same FLOOR alignment" \
"              if p3_shj = 0 then
                p4_al <= p3_prod;
              else
                p4_al <= shift_right(p3_prod
                          + shift_left(to_signed(1, 32), p3_shj - 1), p3_shj);
              end if;"

mutate R3 "sh keeps 15 mantissa bits, not 14" --rtl \
"                if msb_pos(amax) - 14 > 0 then
                  sh_r    <= msb_pos(amax) - 14;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 14, 8);" \
"                if msb_pos(amax) - 15 > 0 then
                  sh_r    <= msb_pos(amax) - 15;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 15, 8);"

mutate R4 "e_y_raw is the MAXIMUM of the head exponents, not the minimum" --rtl \
"            if w_h = 0 or in_e < e_y_b(wb) then" \
"            if w_h = 0 or in_e > e_y_b(wb) then"

mutate R5 "the requantize round bias is dropped (truncate)" --rtl \
"                p5_bsum <= p4_al + bias;" \
"                p5_bsum <= p4_al;"

mutate R6 "y_exp is e_y_raw PLUS sh, not minus (a power-of-two scale error)" --rtl \
"                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 14, 8);" \
"                  y_exp_r <= e_y_raw + to_signed(msb_pos(amax) - 14, 8);"

mutate R7 "the gate is dropped: the product is o*o, not o*z" --rtl \
"          a_prod <= in_o * in_z;" \
"          a_prod <= in_o * in_o;"

mutate R8 "o_last is taken one pipeline stage early" --rtl \
"              o_last_r  <= p5_l;" \
"              o_last_r  <= p4_l;"

mutate R9 "the per-head exponent mux is stuck on head 0 in pass B" --rtl \
"              p2_ep   <= ep(rb*HEADS + p1_h);
              p2_prod <= signed(mem_q);
            end if;

            -- stage 3: the narrow exponent subtract ALONE" \
"              p2_ep   <= ep(rb*HEADS + 0);
              p2_prod <= signed(mem_q);
            end if;

            -- stage 3: the narrow exponent subtract ALONE"

# R10 is an EXPECTED SURVIVOR and it is the SAME structural reason as R1,
# reached by a different route.  MEASURED with a probe on a copy of the
# generator:
#
#   PROBE ones-complement amax differs in 10 of 48 cases; its msb_pos differs in 0
#
# One's complement gives |v| - 1 for negatives, so amax genuinely changes in 10
# cases -- but amax's only consumer is msb_pos(amax), and |v| - 1 has a lower
# msb only when |v| is an exact power of two AND is the unique maximum.  That
# never happens here.  NOTE the same mutation KILLS in
# sim/mutate_gdn_head_emit.sh, where the stimulus does produce such a case, so
# this is a property of THIS case set, not of the recipe.
mutate R10 "the absolute value is one's complement, not two's" --rtl \
"              if p4_al < 0 then p5_abs <= unsigned(-p4_al);" \
"              if p4_al < 0 then p5_abs <= unsigned(not p4_al);"

# R11 is deliberately CONSISTENT: in_ready AND the DUT's own accept condition
# move together, so the unit becomes genuinely single-banked rather than
# merely mis-reporting readiness.  No element is lost and no value changes;
# the producer stalls.  This is the only mutation the OCYC_BOUND check exists
# for, and the bench's own generic comment cites the same 18,462 measurement.
mutate R11 "the double buffer is collapsed: one bank at a time, consistently" --rtl \
"  in_ready <= not pending(wb);" \
"  in_ready <= not (pending(0) or pending(1));" \
"        if in_valid = '1' and pending(wb) = '0' then" \
"        if in_valid = '1' and pending(0) = '0' and pending(1) = '0' then"

# R12 IS AN EXPECTED SURVIVOR AND IT IS THE MOST IMPORTANT LINE IN THIS FILE.
# rtl/gdn_y_emit.vhd:94-97 calls in_ready "MANDATORY, not a convenience", yet
# tying it high changes nothing this bench can see.  MEASURED, by running an
# otherwise untouched gdn_y_emit with an added
#   assert not (in_valid = '1' and pending(wb) = '1') ... severity note
# through the whole of tb_gdn_y_emit:
#
#   PROBE BACKPRESSURE fired 0 times
#
# in_ready NEVER FALLS anywhere in this bench.  The 48 main cases wait for
# `done` between cases, so both banks are always empty, and the overlap phase
# drives exactly TWO blocks into exactly TWO banks -- one short of the number
# that would fill them.  So the port is completely unverified: a DUT with no
# back-pressure at all passes.  Contrast tb_gdn_head_emit, which drives FOUR
# heads into two banks; the identical mutation there is caught (as a hang).
# Closing this needs a third block in the overlap phase, which is a BENCH
# change and is deliberately NOT made here.
mutate R12 "in_ready is tied high, so elements are dropped by a full bank" --rtl \
"  in_ready <= not pending(wb);" \
"  in_ready <= '1';"

# R13 and C3 are the two halves of the saturation measurement.  R13 forces
# o_sat HIGH and dies on check 4; C3 removes the model's sat flag and cannot
# die, because nothing saturates in this stimulus.  Together they show the
# check is one-directional here.
mutate R13 "o_sat is raised on every block (the flag is tied high)" --rtl \
"          when S_IDLE =>
            sat_r <= '0';" \
"          when S_IDLE =>
            sat_r <= '1';"

# EXPECTED SURVIVOR.  MEASURED two ways: the generator reports "saturated
# elements: 0", and a probe counting elements that land exactly ON a rail
# reports
#
#   PROBE elements landing exactly on a 16-bit rail: 0
#
# so neither the clamp nor its boundary is ever reached and moving the rail by
# one cannot change any output.  This is a COVERAGE HOLE in the stimulus, not
# an equivalent mutant: a saturating case set would kill it.  C1 is the same
# hole seen from the C.  Note the whole saturation path of this unit -- the
# clamp, the o_sat flag, and the oracle's sat_any exclusion -- rests on a
# branch this case set never takes.
mutate R14 "sat16's positive rail is 32766" --rtl \
"    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);" \
"    if    v >  to_signed( 32766, v'length) then return to_signed( 32766, 16);"

echo
echo "---- class C: ref/gdn_y_emit_vec.c alone.  Must fail the bench -------"
echo "     (whether the oracle ALSO moves is the resolution measurement)"

# EXPECTED SURVIVOR, the mirror of R14 and the same measured cause: with
# "saturated elements: 0" the sat16 rail is never reached in the model either.
mutate C1 "sat16's positive rail is 32766 in the C model" --c \
"    if (v >  32767) return  32767;" \
"    if (v >  32766) return  32766;"

mutate C2 "msb_pos_u returns one too many, so sh is one too large" --c \
"static int msb_pos_u(uint64_t v){ int p = 0; while (v >>= 1) p++; return p; }" \
"static int msb_pos_u(uint64_t v){ int p = 1; while (v >>= 1) p++; return p; }"

# EXPECTED SURVIVOR and an EQUIVALENT MUTANT on this stimulus: sat_any is
# never set (measured 0 saturated elements), so deleting the assignment
# changes no emitted value.  Note it is NOT equivalent in general -- it would
# also disable the oracle's saturation EXCLUSION, which on a saturating case
# set would change the reported figure.  Here there is nothing to exclude.
mutate C3 "the model's sat flag is never set" --c \
"            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }" \
"            if (r > 32767 || r < -32768) { nsat++; }"

mutate C4 "the model multiplies in int16, so the product wraps" --c \
"                int64_t p = (int64_t)om[i] * (int64_t)zm[i];  /* exact in s32 */" \
"                int64_t p = (int16_t)(om[i] * zm[i]);"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (the bench MUST stay green; only the double oracle can see these)"

mutate B1 "every element is aligned one bit too far (shj + 1)" \
  --rtl \
"              shj_v := to_integer(p2_ep - e_y_raw);
              -- e_y_raw is the minimum" \
"              shj_v := to_integer(p2_ep - e_y_raw) + 1;
              -- e_y_raw is the minimum" \
"              shj_v := to_integer(p2_ep - e_y_raw);
              if shj_v < 0" \
"              shj_v := to_integer(p2_ep - e_y_raw) + 1;
              if shj_v < 0" \
  --c \
"            int shj = ep[h] - e_y_raw; if (shj > 63) shj = 63;" \
"            int shj = ep[h] - e_y_raw + 1; if (shj > 63) shj = 63;"

# e_y_raw stops being a minimum and becomes simply head 0's exponent.  Heads
# on a FINER grid then get a clamped shift of 0 and are silently reinterpreted
# on the wrong grid.  The C side gains the same `shj < 0` clamp the RTL
# already has, so the two remain the same recipe rather than two recipes.
mutate B2 "e_y_raw is head 0's exponent, not the minimum over the block" \
  --rtl \
"            if w_h = 0 or in_e < e_y_b(wb) then
              e_y_b(wb) <= in_e;
            end if;" \
"            if w_h = 0 then
              e_y_b(wb) <= in_e;
            end if;" \
  --c \
"        int e_y_raw = ep[0];
        for (int h = 1; h < H; h++) if (ep[h] < e_y_raw) e_y_raw = ep[h];" \
"        int e_y_raw = ep[0];" \
"            int shj = ep[h] - e_y_raw; if (shj > 63) shj = 63;" \
"            int shj = ep[h] - e_y_raw; if (shj < 0) shj = 0; if (shj > 63) shj = 63;"

# B3 IS A SURVIVOR BY 1.2e-14 AND THAT IS THE WHOLE POINT OF RECORDING IT.
# Truncating the requantize in both transcriptions drives the worst error to
# the bound and then stops one representable step short.  MEASURED by
# reprinting the generator's own figure at %.17g instead of %.4f:
#
#   worst error vs double oracle: 0.99999999999998757 LSB   (case 36)
#
# The gate is `if (worst >= 1.0)`, so it misses by 1.2e-14 and the run prints
# "OK".  The displayed "1.0000" in the table below is the %.4f rounding, NOT a
# pass at exactly 1.0.  The SAME mutation in sim/mutate_gdn_head_emit.sh lands
# on exactly 1.0 (MEASURED: "worst error vs double oracle: 1 LSB", case 7) and
# DOES fail.  One recipe error, two opposite verdicts, decided by whether the
# worst case happens to be a representable double.  The bound is sound; it is
# simply attained in the limit, which is what the generator's own comment
# already says.  Do not "fix" this by loosening the bound to 1.0 - epsilon:
# that would make the correct unit's 0.75 baseline the only margin left.
mutate B3 "the requantize truncates instead of rounding, in BOTH" \
  --rtl \
"                p5_bsum <= p4_al + bias;" \
"                p5_bsum <= p4_al;" \
  --c \
"            int64_t r = round_shift(al[i], sh);" \
"            int64_t r = floor_shr(al[i], sh);"

# B4 IS AN EXPECTED SURVIVOR: gdn_head_emit's blind spot exists here too, and
# for the same reason.  The oracle accumulates only when `!sat_any` (generator
# line 165), and sat_any is a WHOLE-CASE flag.  MEASURED with a probe:
#
#   PROBE cases that would saturate at a 15-bit rail: 41 of 48
#
# and the generator separately reports "all-zero cases: 7".  41 + 7 = 48, so
# under this mutation the ONLY cases the oracle still measures are the seven
# all-zero ones, whose error is identically zero -- which is why the run
# prints "worst error vs double oracle: 0.0000 LSB" rather than a smaller
# nonzero figure.  The oracle is not merely insensitive here, it has been
# emptied by its own exclusion rule.  The bench cannot fire either, because
# both transcriptions agree.  Reported, not patched.
mutate B4 "the output rail drops from 16 bits to 15, in BOTH" \
  --rtl \
"    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);
    elsif v < to_signed(-32768, v'length) then return to_signed(-32768, 16);" \
"    if    v >  to_signed( 16383, v'length) then return to_signed( 16383, 16);
    elsif v < to_signed(-16384, v'length) then return to_signed(-16384, 16);" \
"              if rnd > to_signed(32767, 32) or rnd < to_signed(-32768, 32) then" \
"              if rnd > to_signed(16383, 32) or rnd < to_signed(-16384, 32) then" \
  --c \
"    if (v >  32767) return  32767;
    if (v < -32768) return -32768;" \
"    if (v >  16383) return  16383;
    if (v < -16384) return -16384;" \
"            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }" \
"            if (r > 16383 || r < -16384) { sat_any = 1; nsat++; }"


# B5 IS THE MUTATION THAT MOTIVATED THE BENCH'S FIFTH CHECK, and it is here
# rather than only in sim/mutate_gdn_emit_chain.sh (where it is that script's
# B4) because this is the unit it edits.  It coarsens the output grid by a
# whole octave: sh keeps 13 mantissa bits instead of 14, so every mantissa
# loses a bit and y_exp drops by one.
#
# EVERY LSB-NORMALISED FIGURE MOVES THE SAFE WAY.  MEASURED, bench oracle:
#   worst        0.750000 -> 0.500000
#   n past 0.5   3492     -> 0
#   mean         0.155923 -> 0.158819
# and the GENERATOR'S own oracle goes 0.7500 -> 0.5000 and prints OK.  Both
# oracles measure error in LSB of the OUTPUT grid; the absolute error doubles
# and the LSB doubles with it.  A metric normalised by the quantity being
# mutated cannot see the mutation, and adding digits to it never will.
#
# It is killed by the bench's NORMALISATION check, which is not a tolerance at
# all: sh > 0 implies amax >= 2^(sh+14), hence the largest |y| must be at least
# 2^14.  MEASURED: it fires on 41 of 48 cases and on NOTHING else -- the
# bit-exact comparison stays green, which is what makes this a BOTH-class row.
mutate B5 "site 13 keeps one bit less headroom (msb-13), in BOTH" \
  --rtl \
"                if msb_pos(amax) - 14 > 0 then
                  sh_r    <= msb_pos(amax) - 14;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 14, 8);" \
"                if msb_pos(amax) - 13 > 0 then
                  sh_r    <= msb_pos(amax) - 13;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 13, 8);" \
  --c \
"        int sh = msb_pos_u(amax) - 14; if (sh < 0) sh = 0;" \
"        int sh = msb_pos_u(amax) - 13; if (sh < 0) sh = 0;"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
