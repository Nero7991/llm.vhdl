#!/usr/bin/env bash
# Mutation test for rtl/gdn_head_emit.vhd and ref/gdn_head_emit_vec.c.
#
# WHAT tb_gdn_head_emit ACTUALLY CHECKS, established by reading the file
# before anything was mutated, because a mutation aimed at something the bench
# never claimed to cover teaches nothing:
#
#   1. o_mant, bit-exact against the vector file, every column of every case.
#   2. o_e_head, exact.
#   3. o_sat, exact, in BOTH directions (it is compared, not merely observed).
#   4. An OVERLAP THROUGHPUT bound: 4 heads driven back-to-back must complete
#      in <= 1300 cycles (line 231).  MEASURED baseline 1202 double buffered,
#      1586 with the banks collapsed, so the bound sits between them.
#   5. The overlap phase re-checks e_head and o_mant on the snapped results,
#      so a defect that only appears under back-pressure is in scope.
#
# AND ONE THING IT DOES NOT CHECK, contrary to how it reads at a glance.
# `ready_fell` is computed and then printed at line 258 as
#   report "... back-pressure asserted at least once: " & boolean'image(...)
# at severity NOTE.  It is never compared, never counted into `nerr`.  A DUT
# whose in_ready never falls passes this bench.  That is a REPORTED, NOT
# ASSERTED property, the same shape the audit records for gdn_scalar's double
# oracle, and R11 below is the mutation that demonstrates it: it is caught by
# the throughput bound, not by the back-pressure line.
#
# THE ACCURACY GATE IS REAL AND IT IS IN THE GENERATOR, NOT THE BENCH.
# ref/gdn_head_emit_vec.c lines 209-215 end with
#   if (worst_rel >= 1.0) { fprintf(stderr, "  FAIL: reaches 1.0 LSB, ..."); return 1; }
# and print "worst error vs double oracle: <x> LSB of the output grid" either
# way.  The bound is DERIVED, not guessed: the alignment floor loses < 2^-sh
# output LSB and the requantize round <= 0.5 output LSB, so < 1.0 in every
# case.  MEASURED baseline at the shipped arguments: 0.5000 LSB, case 0.
# So the BOTH class here does NOT need a gate invented by this script; it
# needs the generator's own exit code to be read, which is what happens below.
#
# THREE CLASSES:
#   RTL  -- rtl/gdn_head_emit.vhd only.  Must fail the bench.
#   C    -- ref/gdn_head_emit_vec.c only.  Must fail the bench.  Whether the
#           oracle ALSO moves is the resolution measurement.
#   BOTH -- the same recipe change in each.  Must leave the bench GREEN and
#           can only be caught by the double oracle.
#
# sim/gdn_head_emit_vec.txt is COMMITTED, so sim/regress.sh never regenerates
# it and a mutation of the generator would change nothing there.  Every run
# below generates its own vectors into a private workdir.  VERIFIED: the
# generator at these arguments reproduces the committed file byte for byte.
#
# Usage: bash sim/mutate_gdn_head_emit.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  DIM=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_head_emit.vhd
REF=ref/gdn_head_emit_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-64}"
DIM="${DIM:-128}"
mkdir -p "$SCRATCH"

# --stop-time is 20ms, not the 900ms several older scripts use.  MEASURED: the
# longest LEGITIMATE run is 266.8 us of simulated time (0.4 s wall), so 20 ms
# is a 75x margin -- and a mutation that HANGS runs to the stop time, so 900 ms
# would cost ~45x more wall clock for every hung mutant.  R13 hangs on purpose.
STOP="${STOP:-20ms}"

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
    patch_file "$RTL" "$dir/gdn_head_emit.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  else
    cp "$RTL" "$dir/gdn_head_emit.vhd"
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
  ( cd "$dir" && ./gen v.txt "$NCASE" "$DIM" ) >/dev/null 2>"$dir/gen.err"
  local grc=$?
  if [ ! -s "$dir/v.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NO VECTORS"; sed -n 1,3p "$dir/gen.err"; return
  fi

  if ! ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/gdn_head_emit.vhd" \
         >"$dir/analyze.log" 2>&1; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    sed -n 1,4p "$dir/analyze.log"; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_head_emit.vhd \
       >/dev/null 2>&1

  ( cd "$dir" && timeout 600 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_head_emit -gVECS=v.txt -gNCASE="$NCASE" -gDIM="$DIM" \
      --max-stack-alloc=0 --stop-time="$STOP" ) >"$dir/run.log" 2>&1

  local bench why acc
  if grep -q "tb_gdn_head_emit: PASS" "$dir/run.log"; then
    bench=PASS; why=""
  else
    bench=FAIL
    # Which of the bench's five claims actually noticed.  A mutation that only
    # ever trips one of them has told us which check is load bearing.
    if   grep -q "OVERLAP THROUGHPUT"  "$dir/run.log"; then why="throughput"
    elif grep -q "o_sat mismatch"      "$dir/run.log"; then why="o_sat"
    elif grep -q "e_head got"          "$dir/run.log"; then why="e_head"
    elif grep -q "mant got"            "$dir/run.log"; then why="o_mant"
    # The bench's accuracy gate, added 2026-08-29.  It is listed AFTER the
    # bit-exact claims deliberately: when both fire, the bit-exact one is the
    # sharper diagnosis, and the accuracy gate is the one that matters only
    # when the bit-exact check is green by construction, i.e. the BOTH class.
    # The bench's NORMALISATION check, added 2026-08-29.  It is listed BEFORE
    # the accuracy gate because when both fire it is the sharper diagnosis: it
    # names an output-grid error, which is the one class no error measured in
    # LSB of that grid can see.
    elif grep -q "NORMALISATION failed" "$dir/run.log"; then why="normalisation"
    elif grep -q "OUT OF TOLERANCE"    "$dir/run.log"; then
      why="accuracy: $(sed -n 's/.*OUT OF TOLERANCE -- \(worst\|mean\|the oracle saw\|[0-9]* elements\).*/\1/p' "$dir/run.log" | head -1)"
    elif grep -q "assertion failure"   "$dir/run.log"; then why="RTL assert"
    else why="no verdict (hang/timeout)"
    fi
  fi
  # The oracle verdict: the generator's own exit code, plus the figure it
  # prints.  Nothing in this script decides the bound; ref/ does.
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

echo "=================== mutations of gdn_head_emit ====================="
echo "cases $NCASE x DIM $DIM, stop-time $STOP"
echo "bench gate: bit-exact o_mant + e_head + o_sat, a 1300-cycle overlap bound,"
echo "            and (since 2026-08-29) FOUR accuracy figures against the bench's"
echo "            own real-valued oracle, which excludes NOTHING: max 1.5 LSB,"
echo "            <=120 elements past 0.5 LSB, mean 0.200 LSB, floor 8192 elements."
echo "oracle gate: ref/gdn_head_emit_vec.c's own 1.0 output-LSB bound (baseline 0.5000)."
echo "            NOTE this column EXCLUDES a whole case when any column saturated,"
echo "            which is what makes it read 0.0000 and pass on B4.  The bench"
echo "            column is the one to read for the BOTH class."
echo
echo "---- class RTL: rtl/gdn_head_emit.vhd alone.  Must fail the bench ----"

# R1 is an EXPECTED SURVIVOR and is kept for that reason.  MEASURED with a
# probe on a copy of the generator:
#
#   PROBE cases where round-aligned amax differs: 2; where its msb_pos differs: 0
#
# Rounding the alignment in pass B genuinely changes amax in 2 of the 64 cases,
# but amax has exactly ONE consumer -- msb_pos(amax) -- and msb_pos is
# unchanged in all 64.  So sh_h, e_head and every output column are identical
# and no observer at this unit's interface can see the difference.  amax is
# not a port.  This is not an equivalent mutant in general; it is a mutant
# whose effect does not reach an output on this stimulus, and no bench written
# against this interface could kill it.  R2 is the same edit on pass C, where
# the value DOES reach an output, and it dies.
mutate R1 "pass B ALIGNS BY ROUNDING instead of flooring (amax diverges)" --rtl \
"              p3_al <= shift_right(p2_acc, p2_shj);
            end if;

            -- stage 4: absolute value ALONE" \
"              if p2_shj = 0 then
                p3_al <= p2_acc;
              else
                p3_al <= shift_right(p2_acc
                          + shift_left(to_signed(1, 40), p2_shj - 1), p2_shj);
              end if;
            end if;

            -- stage 4: absolute value ALONE"

mutate R2 "pass C aligns by ROUNDING, so the alignment is double-rounded" --rtl \
"              p3_al <= shift_right(p2_acc, p2_shj);   -- same FLOOR alignment" \
"              if p2_shj = 0 then
                p3_al <= p2_acc;
              else
                p3_al <= shift_right(p2_acc
                          + shift_left(to_signed(1, 40), p2_shj - 1), p2_shj);
              end if;"

mutate R3 "sh_h keeps 15 mantissa bits, not 14" --rtl \
"                if msb_pos(amax) - 14 > 0 then
                  sh_h <= msb_pos(amax) - 14;
                  e_head_r <= e_h - to_signed(msb_pos(amax) - 14, 8);" \
"                if msb_pos(amax) - 15 > 0 then
                  sh_h <= msb_pos(amax) - 15;
                  e_head_r <= e_h - to_signed(msb_pos(amax) - 15, 8);"

mutate R4 "e_h is the MAXIMUM of the column exponents, not the minimum" --rtl \
"          if wr_idx = 0 or in_e_o < e_h_b(wb) then" \
"          if wr_idx = 0 or in_e_o > e_h_b(wb) then"

mutate R5 "the requantize round bias is dropped (truncate)" --rtl \
"                p4_bsum <= p3_al + bias;" \
"                p4_bsum <= p3_al;"

mutate R6 "e_head is e_h PLUS sh_h, not minus (a power-of-two scale error)" --rtl \
"                  e_head_r <= e_h - to_signed(msb_pos(amax) - 14, 8);" \
"                  e_head_r <= e_h + to_signed(msb_pos(amax) - 14, 8);"

mutate R7 "sat16's positive rail is 32766" --rtl \
"    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);" \
"    if    v >  to_signed( 32766, v'length) then return to_signed( 32766, 16);"

mutate R8 "o_sat is never raised (the flag is tied low)" --rtl \
"                sat_r <= '1';
              end if;" \
"                sat_r <= '0';
              end if;"

mutate R9 "o_sat is raised on every head (the flag is tied high)" --rtl \
"            sat_r <= '0';
            if pending(rb) = '1' then" \
"            sat_r <= '1';
            if pending(rb) = '1' then"

mutate R10 "the absolute value is one's complement, not two's" --rtl \
"              if p3_al < 0 then p4_abs <= unsigned(-p3_al);" \
"              if p3_al < 0 then p4_abs <= unsigned(not p3_al);"

# R11 is the mutation that shows which check carries the double buffer, and it
# is deliberately CONSISTENT: both in_ready AND the DUT's own accept condition
# are moved together, so the unit becomes genuinely single-banked rather than
# merely mis-reporting its readiness.  No column is lost and no value changes;
# the producer just stalls.  MEASURED first attempt: moving in_ready ALONE
# made the bench's handshake disagree with the DUT's accept condition, the
# stream desynchronised and the run hung, which kills for the wrong reason and
# proves nothing about the throughput bound.
#
# Note what does NOT notice R11: `ready_fell` at tb:258 is a `report ...
# severity note`, printed and never compared, so a back-pressure property the
# bench appears to test is not tested.  The 1300-cycle bound is the whole
# check for the double buffer.
mutate R11 "the double buffer is collapsed: one bank at a time, consistently" --rtl \
"  in_ready <= not pending(wb);" \
"  in_ready <= not (pending(0) or pending(1));" \
"        if in_valid = '1' and pending(wb) = '0' then" \
"        if in_valid = '1' and pending(0) = '0' and pending(1) = '0' then"

# R12 is the INCONSISTENT version on purpose: in_ready lies, the DUT still
# refuses columns while its bank is full, and the producer walks on.  Columns
# are LOST, which is the exact failure the port exists to prevent.  MEASURED:
# it is caught as a HANG at the stop time (snap_n never reaches 4), not as a
# wrong value.  Under sim/regress.sh that is a TIMEOUT, which is reported in
# its own bucket rather than as a failure -- worth knowing.
# GREP-VERIFIED: the bench reads in_ready only at line 101 (an observation
# feeding the un-asserted ready_fell) and line 216 (the overlap handshake), so
# neither R11 nor R12 can affect the 64-case main phase at all.
mutate R12 "in_ready is tied high, so columns are dropped by a full bank" --rtl \
"  in_ready <= not pending(wb);" \
"  in_ready <= '1';"

# The trap the RTL comment at line 472-477 names explicitly.  An explicit
# done_r clear inside the o_ack branch is a LATER assignment to the same
# signal and wins, destroying the pulse whenever o_ack is tied high -- which
# is the bench's default.  It HANGS rather than failing a compare, so it costs
# the full stop time; that is the reason STOP is 20ms and not 900ms.
mutate R13 "an explicit done_r clear inside the o_ack branch" --rtl \
"            if o_ack = '1' then
              -- Release the bank ONLY here" \
"            if o_ack = '1' then
              done_r <= '0';
              -- Release the bank ONLY here"

echo
echo "---- class C: ref/gdn_head_emit_vec.c alone.  Must fail the bench ----"
echo "     (whether the oracle ALSO moves is the resolution measurement)"

# The L6 analogue: a defect the ORACLE is structurally blind to.  The oracle
# skips any case where sat_any is set (line 168, `if (!sat_any && ...)`), so a
# saturation-rail error cannot move worst_rel at all.  Only bit-exactness sees
# it.
mutate C1 "sat16's positive rail is 32766 in the C model" --c \
"    if (v >  32767) return  32767;" \
"    if (v >  32766) return  32766;"

mutate C2 "msb_pos_u returns one too many, so sh_h is one too large" --c \
"static int msb_pos_u(uint64_t v){ int p = 0; while (v >>= 1) p++; return p; }" \
"static int msb_pos_u(uint64_t v){ int p = 1; while (v >>= 1) p++; return p; }"

mutate C3 "the model's o_sat is never set, so the flag column is always 0" --c \
"            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }" \
"            if (r > 32767 || r < -32768) { nsat++; }"

echo
echo "---- class BOTH: the same recipe change in the C AND the RTL ----------"
echo "     (the bench MUST stay green; only the double oracle can see these)"

mutate B1 "every column is aligned one bit too far (shj + 1)" \
  --rtl \
"              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h);
              -- e_h is the minimum" \
"              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h) + 1;
              -- e_h is the minimum" \
"              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h);
              if shj_v < 0" \
"              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h) + 1;
              if shj_v < 0" \
  --c \
"            int shj = e_o[j] - e_h; if (shj > 63) shj = 63;" \
"            int shj = e_o[j] - e_h + 1; if (shj > 63) shj = 63;"

# e_h stops being a minimum and becomes simply column 0's exponent.  Every
# column on a FINER grid than column 0 then gets a clamped shift of 0 and is
# silently reinterpreted on the wrong grid -- a defect that is bit-exact by
# construction because both transcriptions do it.  The C side gains the same
# `shj < 0` clamp the RTL already has, so the two remain the same recipe.
mutate B2 "e_h is column 0's exponent, not the minimum over the head" \
  --rtl \
"          if wr_idx = 0 or in_e_o < e_h_b(wb) then
            e_h_b(wb) <= in_e_o;
          end if;" \
"          if wr_idx = 0 then
            e_h_b(wb) <= in_e_o;
          end if;" \
  --c \
"        int e_h = e_o[0];
        for (int j = 1; j < DIM; j++) if (e_o[j] < e_h) e_h = e_o[j];" \
"        int e_h = e_o[0];" \
"            int shj = e_o[j] - e_h; if (shj > 63) shj = 63;" \
"            int shj = e_o[j] - e_h; if (shj < 0) shj = 0; if (shj > 63) shj = 63;"

mutate B3 "the requantize truncates instead of rounding, in BOTH" \
  --rtl \
"                p4_bsum <= p3_al + bias;" \
"                p4_bsum <= p3_al;" \
  --c \
"            int64_t r = round_shift(o_al[j], sh_h);" \
"            int64_t r = floor_shr(o_al[j], sh_h);"

# B4 is EXPECTED TO SURVIVE and is kept for exactly that reason.  The oracle
# accumulates only when `!sat_any` (generator line 168), and sat_any is a
# WHOLE-CASE flag: one saturating column excludes all DIM of them.  MEASURED
# with a probe on a copy of the generator:
#
#   PROBE cases with sat_any at the 16-bit rail: 8 of 64; at a 15-bit rail: 49 of 64
#
# and the generator separately reports "all-zero heads: 15".  49 + 15 = 64, so
# under this mutation the ONLY cases the oracle still measures are the fifteen
# all-zero heads, whose error is identically zero -- which is why the run
# prints "worst error vs double oracle: 0.0000 LSB" rather than a smaller
# nonzero number.  The oracle is not merely insensitive here, it has been
# emptied.  The bench cannot fire either, because both transcriptions agree.
# That is a real blind spot in the pair and it is reported, not patched.
mutate B4 "the output rail drops from 16 bits to 15, in BOTH" \
  --rtl \
"    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);
    elsif v < to_signed(-32768, v'length) then return to_signed(-32768, 16);" \
"    if    v >  to_signed( 16383, v'length) then return to_signed( 16383, 16);
    elsif v < to_signed(-16384, v'length) then return to_signed(-16384, 16);" \
"              if rnd > to_signed(32767, 40) or rnd < to_signed(-32768, 40) then" \
"              if rnd > to_signed(16383, 40) or rnd < to_signed(-16384, 40) then" \
  --c \
"    if (v >  32767) return  32767;
    if (v < -32768) return -32768;" \
"    if (v >  16383) return  16383;
    if (v < -16384) return -16384;" \
"            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }" \
"            if (r > 16383 || r < -16384) { sat_any = 1; nsat++; }"


# B5 IS THE MUTATION THAT MOTIVATED THE BENCH'S FIFTH CHECK.  It coarsens the
# output grid by a whole octave: sh_h keeps 13 mantissa bits instead of 14, so
# every column loses a bit and e_head drops by one.
#
# EVERY LSB-NORMALISED FIGURE MOVES THE SAFE WAY.  MEASURED, bench oracle:
#   worst        0.999985 -> 0.500000
#   n past 0.5   14       -> 0
#   mean         0.059422 -> 0.055006
# and the GENERATOR'S own oracle goes 0.5000 -> 0.5000 and prints OK.  Both
# oracles measure error in LSB of the OUTPUT grid; the absolute error doubles
# and the LSB doubles with it.  A metric normalised by the quantity being
# mutated cannot see the mutation, and adding digits to it never will.  The
# same edit on gdn_y_emit is that script'''s B5 and sim/mutate_gdn_emit_chain.sh'''s
# B4, where it is recorded as an expected survivor of both oracles.
#
# It is killed by the bench'''s NORMALISATION check, which is not a tolerance at
# all: sh_h > 0 implies oamax >= 2^(sh_h+14), hence the largest |o_mant| must be
# at least 2^14.  MEASURED honest floor: exactly 16384 at all 40 seeds swept.
mutate B5 "site 12 keeps one bit less headroom (msb-13), in BOTH" \
  --rtl \
"                if msb_pos(amax) - 14 > 0 then
                  sh_h <= msb_pos(amax) - 14;
                  e_head_r <= e_h - to_signed(msb_pos(amax) - 14, 8);" \
"                if msb_pos(amax) - 13 > 0 then
                  sh_h <= msb_pos(amax) - 13;
                  e_head_r <= e_h - to_signed(msb_pos(amax) - 13, 8);" \
  --c \
"        int sh_h = msb_pos_u(oamax) - 14; if (sh_h < 0) sh_h = 0;" \
"        int sh_h = msb_pos_u(oamax) - 13; if (sh_h < 0) sh_h = 0;"

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
