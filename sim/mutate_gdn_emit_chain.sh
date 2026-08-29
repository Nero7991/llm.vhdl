#!/usr/bin/env bash
# Mutation test for rtl/gdn_emit_chain.vhd and ref/gdn_emit_chain_vec.c.
#
# WHAT tb_gdn_emit_chain ACTUALLY CHECKS, established by reading it before any
# mutation was written.  It is bit-exact and nothing else: per block it checks
# the emitted element COUNT, y_exp, and every one of HEADS*DIM y elements
# against the vector file, and prints
# "tb_gdn_emit_chain: PASS -- <n> blocks x <h> heads x <d> bit-exact".  It also
# reports refused-column cycles and can be made to assert on them with
# STRICT=true.  There is NO tolerance and NO real-valued check in the bench.
#
# THE ACCURACY GATE FOR THIS UNIT IS IN THE GENERATOR, and unlike gdn_silu and
# rmsnorm_bf it really is a gate: ref/gdn_emit_chain_vec.c evaluates the whole
# chain a second time in double, sharing none of the integer helpers, and
# returns 1 with "FAIL: end-to-end error is far larger than the composed
# quantization can explain" when the worst error exceeds 8.0 LSB of the output
# grid.  That bound is stated in the generator as a SANITY bound, not a derived
# one, and it is roughly 5x the measured baseline.  This script therefore
# reports the generator's own verdict AND a tighter harness gate (ACC_LSB), so
# a mutation that degrades accuracy without reaching 8.0 is still visible.
#
# THREE CLASSES:
#   RTL  -- rtl/gdn_emit_chain.vhd only.  These are SEQUENCER and SEAM faults,
#           which is what this unit is: the four sub-units have their own
#           mutation scripts.  Must fail bit-exactness (or trip an assert).
#   C    -- ref/gdn_emit_chain_vec.c only.  Must fail bit-exactness.
#   BOTH -- the same seam change in the chain RTL AND the chain reference.
#           Must LEAVE bit-exactness green.  Only the end-to-end double oracle
#           can see these, and seam 4 is the reason: it is an exponent SUM, and
#           an error in it scales the whole block by a power of two, which
#           looks like a plausible answer rather than a broken one.  The
#           bench's own header says seam 4 "cannot be checked by inspection at
#           all"; these entries are the measurement of that.
#
# sim/gdn_emit_chain_vec.txt is COMMITTED, so sim/regress.sh never regenerates
# it and a C-side mutation would change nothing there.  Every run below
# generates its own vectors into a private workdir.  VERIFIED: the generator at
# `3 24 128` and at `6 24 128` is deterministic, and at `6 24 128` it
# reproduces the committed file byte for byte.
#
# COST.  MEASURED: one honest run is 44.4 us of simulated time and 53 s of wall
# time at NB=3.  NB defaults to 2 here for that reason.  --stop-time is 150 us,
# not the 300 ms regress.sh uses, because a mutant that DEADLOCKS runs to the
# stop time and 300 ms of this design is hours of wall clock; `timeout` is the
# real bound and the stop time is a backstop with about a 5x margin.
#
# Usage: bash sim/mutate_gdn_emit_chain.sh
# Env:   SCRATCH=<dir>  NB=<blocks>  HEADS=<n>  DIM=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
RTL=rtl/gdn_emit_chain.vhd
REF=ref/gdn_emit_chain_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NB="${NB:-2}"
HEADS="${HEADS:-24}"
DIM="${DIM:-128}"
# Z_DELAY defaults to 0 because that is what sim/regress.sh runs (its row
# passes OVERLAP/COL_GAP/STRICT/SILU_LANES/RMS_LANES and leaves Z_DELAY at the
# bench default).  It is a knob here because R6 below is only killable with it
# raised, which is the single most consequential result in this file.
Z_DELAY="${Z_DELAY:-0}"
# Z_LATE is the value R6 is re-run at.  MEASURED reason for 600: head_emit
# needs DIM columns at COL_GAP=4, i.e. 512 cycles, before it raises done, so
# any z delay under that still arrives early and masks the defect.
Z_LATE="${Z_LATE:-600}"
mkdir -p "$SCRATCH"

# MEASURED on the unmutated pair: 1.2057 LSB at NB=3, 1.53 LSB at NB=6 (the
# figure the generator's own comment records).  The harness gate below is
# tighter than the generator's 8.0 so that a mutation which degrades accuracy
# without reaching the sanity bound is still reported; both verdicts are
# printed, and they are DIFFERENT columns on purpose.
ACC_LSB="${ACC_LSB:-2.5}"

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
# --rtl edits rtl/gdn_emit_chain.vhd unless --unit <name> precedes it, in
# which case that rtl/<name>.vhd is the file edited and the chain is left
# alone.  That is needed for the site-13 BOTH entry, whose RTL half lives in
# gdn_y_emit.
mutate() {
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"

  local mode="" unit="gdn_emit_chain" rtl_args=() c_args=() nextunit=0
  for a in "$@"; do
    if [ $nextunit = 1 ]; then unit="$a"; nextunit=0; continue; fi
    case "$a" in
      --unit) nextunit=1 ;;
      --rtl)  mode=rtl ;;
      --c)    mode=c ;;
      *) if [ "$mode" = rtl ]; then rtl_args+=("$a"); else c_args+=("$a"); fi ;;
    esac
  done

  local UNITS="fixed_luts_pkg fixed_pkg util_pkg gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain"
  for f in $UNITS; do cp "rtl/$f.vhd" "$dir/$f.vhd"; done
  if [ ${#rtl_args[@]} -gt 0 ]; then
    patch_file "rtl/$unit.vhd" "$dir/$unit.vhd" "${rtl_args[@]}" || {
      echo "$tag  RTL ANCHOR FAILED"; return; }
  fi
  if [ ${#c_args[@]} -gt 0 ]; then
    patch_file "$REF" "$dir/gen.c" "${c_args[@]}" || {
      echo "$tag  C ANCHOR FAILED"; return; }
  else
    cp "$REF" "$dir/gen.c"
  fi

  # The generator #includes rmsnorm_bf_vec.c and gdn_silu_vec.c from ref/, so
  # -I ref is not optional here.
  if ! cc -O2 -w -I ref -o "$dir/gen" "$dir/gen.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./gen gdn_emit_chain_vec.txt "$NB" "$HEADS" "$DIM" ) \
      >/dev/null 2>"$dir/gen.err"
  local grc=$?
  local orc="ok"
  if [ $grc -ne 0 ]; then orc="GENFAIL"; fi
  if [ ! -s "$dir/gdn_emit_chain_vec.txt" ]; then
    echo "$tag  GENERATOR PRODUCED NOTHING"; sed -n 1,3p "$dir/gen.err"; return
  fi

  local ok=1
  for f in $UNITS; do
    ghdl -a --std=08 -frelaxed --workdir="$dir" "$dir/$f.vhd" \
      >>"$dir/analyze.log" 2>&1 || ok=0
  done
  if [ $ok = 0 ]; then
    echo "$tag  DID NOT ANALYZE (a mutation that will not compile has tested nothing)"
    grep -m3 -i error "$dir/analyze.log" | sed 's/^/       /'; return
  fi
  ghdl -a --std=08 -frelaxed --workdir="$dir" sim/tb_gdn_emit_chain.vhd \
      >>"$dir/analyze.log" 2>&1

  ( cd "$dir" && timeout 200 ghdl -r --std=08 -frelaxed --workdir="$dir" \
      tb_gdn_emit_chain -gOVERLAP=true -gCOL_GAP=4 -gSTRICT=false \
      -gSILU_LANES=16 -gRMS_LANES=4 -gHEADS="$HEADS" -gZ_DELAY="$Z_DELAY" \
      --max-stack-alloc=0 --stop-time=150us ) >"$dir/run.log" 2>&1
  local rrc=$?

  local bx acc
  if grep -q "tb_gdn_emit_chain: PASS" "$dir/run.log"; then
    bx=PASS
  elif [ $rrc = 124 ]; then
    bx=HUNG
  else
    bx=FAIL
  fi
  acc=$(python3 - "$dir/gen.err" "$ACC_LSB" "$orc" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"worst end-to-end error vs the double oracle: ([0-9.eE+-]+) LSB", t)
gen = sys.argv[3]
if not m:
    print("NOFIG"); sys.exit()
v = float(m.group(1))
if gen == "GENFAIL":
    print("FAIL %.4f LSB (generator's own 8.0 gate)" % v)
elif v > float(sys.argv[2]):
    print("FAIL %.4f LSB (harness gate only)" % v)
else:
    print("pass %.4f LSB" % v)
PY
)
  if [ "$bx" != PASS ] || [ "${acc%% *}" = FAIL ]; then
    NKILL=$((NKILL+1))
    printf '%-4s KILLED   bench %-4s  oracle %s   -- %s\n' "$tag" "$bx" "$acc" "$desc"
    if [ "$bx" = FAIL ]; then
      grep -m1 -E "tb_gdn_emit_chain:.*(block|FAIL)|assertion (error|failure)" "$dir/run.log" \
        | cut -c1-150 | sed 's/^/       /'
    fi
  else
    NSURV=$((NSURV+1))
    printf '%-4s SURVIVED bench %-4s  oracle %s   -- %s\n' "$tag" "$bx" "$acc" "$desc"
  fi
}

echo "================== mutations of gdn_emit_chain ====================="
echo "$NB blocks x $HEADS heads x $DIM, OVERLAP=true COL_GAP=4 STRICT=false"
echo "bench gates bit-exactness; the generator gates the end-to-end oracle at"
echo "8.0 LSB; this script additionally gates it at $ACC_LSB LSB."
echo
echo "---- class RTL: the chain SEQUENCER and its four seams ---------------"

mutate R1 "seam 4: in_e drops the gate exponent entirely" --rtl \
"              ep_r  <= to_signed(rn_exp, 8) + z_e_held;" \
"              ep_r  <= to_signed(rn_exp, 8);"

mutate R2 "seam 4: in_e SUBTRACTS the gate exponent" --rtl \
"              ep_r  <= to_signed(rn_exp, 8) + z_e_held;" \
"              ep_r  <= to_signed(rn_exp, 8) - z_e_held;"

mutate R3 "seam 3: y_emit is fed the UNGATED z, not the silu output" --rtl \
"                ye_z <= signed(z_buf((ser_j+1)*16-1 downto ser_j*16));" \
"                ye_z <= signed(z_held((ser_j+1)*16-1 downto ser_j*16));"

mutate R4 "seam 2: y_emit is fed head_emit's mantissa, bypassing the norm" --rtl \
"                ye_o <= signed(rn_mant((ser_j+1)*16-1 downto ser_j*16));" \
"                ye_o <= signed(he_mant((ser_j+1)*16-1 downto ser_j*16));"

# R5 and R7 through R10 are EXPECTED SURVIVORS at the SHIPPED configuration,
# and every reason below was MEASURED, not argued.  Two of them are equivalent
# under the shipped timing, three are holes in what this bench drives, and one
# of the holes -- R6 -- is closed by a single generic, which is why R6 is not
# in this list.  The probe was an instrumented COPY of gdn_emit_chain.vhd
# counting four events over 2 blocks x 24 heads; at COL_GAP=1 and at COL_GAP=4
# it reported, identically:
#
#   PROBE ye_stall=0 ser_entry_stall=0 rms_gate_late=0 he_mant_changed_during_rms=0
#
#   R5  EQUIVALENT ON THIS STIMULUS, because the stimulus has no gate-exponent
#       variation to expose: ref/gdn_emit_chain_vec.c:73 sets `int we = 12,
#       z_e = 12;` and never changes either, for any block or head.  z_exp is
#       therefore constant, so reading it live is reading the held copy.  The
#       defect this line guards against needs a z_exp that MOVES between heads,
#       and no vector in this repo produces one.
#   R7  COVERAGE HOLE, and the same one gdn_y_emit's own bench has.  The B-1
#       phantom-advance only bites when the consumer is stalled at S_SER entry,
#       and MEASURED, ye_ready NEVER FALLS here: ye_stall = 0 over every cycle
#       and ser_entry_stall = 0 over every head, at both column rates.
#       gdn_y_emit is double buffered and this bench drives at most 4 blocks
#       into 2 banks, so its in_ready has no reason to go low.  Closing this
#       needs a y consumer that can stall, which the bench has no knob for.
#   R8  EQUIVALENT MUTANT BY CONSTRUCTION.  in_hfirst has exactly one consumer
#       (rtl/gdn_y_emit.vhd:276-282): it latches in_e into ep(head) and folds
#       it into the per-bank running minimum.  The chain drives ye_e from ep_r,
#       which is written once in S_RMS and held for the whole head, so
#       asserting hfirst on every element re-latches the SAME value and re-runs
#       the minimum against itself.  Idempotent, so no stimulus can separate
#       them while in_e is constant within a head -- which the chain guarantees.
#   R9  EQUIVALENT UNDER THE SHIPPED TIMING.  Releasing head_emit's result
#       register early only matters if the register is overwritten while
#       rmsnorm_bf is still reading it.  MEASURED: he_mant_changed_during_rms =
#       0, i.e. it never is, because the next head needs DIM columns to arrive
#       before its reduce can land and the norm finishes first.  The
#       CONSUME_BUDGET watchdog, not this bench's data check, is the thing that
#       would catch a real violation of that margin.
#   R10 EQUIVALENT UNDER THE SHIPPED TIMING, for the reason the RTL comment
#       states: the norm is the long pole at ~142 cycles against the gate's
#       SI_BEATS = 8 plus latency.  MEASURED: rms_gate_late = 0, so si_rd has
#       ALWAYS reached SI_BEATS by the time rn_done fires.  Widening COL_GAP
#       does not change this; it is a property of the two units''' latencies.
mutate R5 "the gate exponent is read LIVE, losing gdn_silu'''s one-cycle lead" --rtl \
"        si_e_seg <= z_e_held;" \
"        si_e_seg <= z_exp;"

# R6 IS THE HEADLINE RESULT OF THIS FILE.  It SURVIVES at the configuration
# sim/regress.sh runs and is KILLED by raising one generic.  MEASURED:
#
#   Z_DELAY    0     PASS     7   PASS    40   PASS
#   Z_DELAY  600     FAIL   2000   FAIL
#
#   at Z_DELAY = 600: "block 0 element 640 head 5 lane 0 got -6541 expected 179"
#
# CONTROL, and it is what makes the above mean anything: the UNMUTATED chain
# PASSES at Z_DELAY = 600, so the failure is the mutation and not the bench
# breaking at an untried setting.  40 is not enough because head_emit needs
# DIM columns at COL_GAP = 4 -- 512 cycles -- before done, so a z that is 40
# cycles late is still 470 cycles early.  The bench'''s own header already says
# Z_DELAY = 0 "is what MASKED the z_have defect"; the gate then runs it at 0.
# The zdelay_check below re-runs this one mutant at Z_LATE so the file
# demonstrates the finding rather than describing it.
mutate R6 "S_IDLE fires on he_done alone: the z stream goes off by one head" --rtl \
"            if he_done = '1' and z_have = '1' then" \
"            if he_done = '1' then"

mutate R7 "S_SER advances on ye_ready alone (the B-1 audit defect)" --rtl \
"            if ye_valid = '0' or ye_ready = '1' then" \
"            if ye_ready = '1' then"

mutate R8 "in_hfirst is asserted on every element, not only element 0" --rtl \
"                if ser_j = 0 then ye_hfirst <= '1'; else ye_hfirst <= '0'; end if;" \
"                ye_hfirst <= '1';"

mutate R9 "head_emit's result register is released BEFORE the norm reads it" --rtl \
"              rn_start <= '1';
              state <= S_RMS;" \
"              rn_start <= '1';
              he_ack   <= '1';
              state <= S_RMS;"

mutate R10 "S_RMS proceeds before the gate has drained (si_rd ignored)" --rtl \
"            if rn_done = '1' and si_rd = SI_BEATS then" \
"            if rn_done = '1' then"

mutate R11 "the ssm_norm weight is re-latched at every head, not at head 0" --rtl \
"              if head = 0 then
                w_held  <= w_mant;
                we_held <= w_exp;
                w_taken <= '1';
              end if;" \
"              w_held  <= w_mant;
              we_held <= w_exp;
              w_taken <= '1';"

echo
echo "---- class C: ref/gdn_emit_chain_vec.c alone -------------------------"
echo "     (must fail bit-exactness; the oracle column is the measurement)"

# EXPECTED SURVIVOR, COVERAGE HOLE, and the generator says so itself on every
# run: MEASURED "saturated elements: 0" on the unmutated vectors and on these.
# Nothing in this stimulus reaches either site-13 rail, so moving one is
# unobservable.  gdn_y_emit'''s own mutation script records the same hole.
mutate C1 "site 13 saturates at 32766, one below int16 max" --c \
"static int16_t csat16(int64_t v){ return v > 32767 ? 32767 : (v < -32768 ? -32768 : (int16_t)v); }" \
"static int16_t csat16(int64_t v){ return v > 32766 ? 32766 : (v < -32768 ? -32768 : (int16_t)v); }"

mutate C2 "site 12's per-column alignment ROUNDS instead of flooring" --c \
"                o_al[j] = mv4i_floor_shr(o_acc[h][j], shj);" \
"                o_al[j] = mv4i_round_shift(o_acc[h][j], shj);"

echo
echo "---- class BOTH: the same seam change in the chain RTL AND the C ------"
echo "     (bit-exactness MUST stay green; only the end-to-end oracle sees these)"

# B1 is the flagship and it is seam 4 exactly as the bench header describes it.
# Every ep[h] moves by one, so e_y moves by one, the relative alignments and
# therefore every emitted y element are UNCHANGED, and only y_exp moves.  The
# whole block is off by a factor of two and every integer in the file is right.
mutate B1 "seam 4: the exponent sum is one too large in both" \
  --rtl \
"              ep_r  <= to_signed(rn_exp, 8) + z_e_held;" \
"              ep_r  <= to_signed(rn_exp, 8) + z_e_held + 1;" \
  --c \
"            ep[h] = r.o_exp + z_e;" \
"            ep[h] = r.o_exp + z_e + 1;"

mutate B2 "seam 1: the head exponent handed to the norm is one too large" \
  --rtl \
"               x_mant => he_mant, x_exp => to_integer(he_e_head)," \
"               x_mant => he_mant, x_exp => to_integer(he_e_head) + 1," \
  --c \
"            rmsnorm_bf_int(o_head, e_head, wm, we, &r);" \
"            rmsnorm_bf_int(o_head, e_head + 1, wm, we, &r);"

mutate B3 "seam 3: the gate argument grid is one octave off in both" \
  --rtl \
"        si_e_seg <= z_e_held;" \
"        si_e_seg <= z_e_held + 1;" \
  --c \
"                int32_t xq  = to_q12(zm[h][j], z_e);" \
"                int32_t xq  = to_q12(zm[h][j], z_e + 1);"

# B4's RTL half is in gdn_y_emit, not in the chain.  It is kept here anyway:
# gdn_y_emit's own generator gates its oracle at 1.0 LSB while the chain gates
# at 8.0, so whether the CHAIN can still see a site-13 headroom error is a
# genuine question about this bench and not a duplicate of the unit test.
# B4 IS AN EXPECTED SURVIVOR AND IT IS A BLIND SPOT OF THE ORACLE'''S UNITS, not
# of the stimulus.  MEASURED: the mutation takes y_exp from 10 to 9 on BOTH
# blocks, i.e. it makes the output grid one octave COARSER, and the oracle
# measures error "in LSB of the OUTPUT grid".  Absolute error doubles and the
# LSB doubles with it, so the reported figure barely moves -- it went 1.1280 ->
# 0.8505, in the wrong direction.  A metric normalised by the quantity being
# mutated cannot see the mutation.  gdn_y_emit'''s own generator misses the same
# change for a different reason (its whole-case sat_any exclusion empties the
# sample), so BOTH oracles are blind to an output-grid error and neither is
# widened here.  Catching it needs an error measured in ABSOLUTE units, or a
# separate assertion on y_exp against the oracle'''s own exponent.
mutate B4 "site 13 keeps one bit less headroom (msb-13) in both" \
  --unit gdn_y_emit --rtl \
"                if msb_pos(amax) - 14 > 0 then
                  sh_r    <= msb_pos(amax) - 14;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 14, 8);" \
"                if msb_pos(amax) - 13 > 0 then
                  sh_r    <= msb_pos(amax) - 13;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 13, 8);" \
  --c \
"        int sh = cmsb_u(amax2) - 14; if (sh < 0) sh = 0;" \
"        int sh = cmsb_u(amax2) - 13; if (sh < 0) sh = 0;"

echo
echo "---- the Z_DELAY cross-check: R6 at a z producer that is actually late --"
echo "     (a mutation that survives one configuration and dies in another is"
echo "      a statement about the CONFIGURATION, and it needs its control)"
zrun() {   # $1 dir  $2 z_delay  -> prints PASS/FAIL
  ( cd "$1" && timeout 400 ghdl -r --std=08 -frelaxed --workdir="$1" \
      tb_gdn_emit_chain -gOVERLAP=true -gCOL_GAP=4 -gSTRICT=false \
      -gSILU_LANES=16 -gRMS_LANES=4 -gHEADS="$HEADS" -gZ_DELAY="$2" \
      --max-stack-alloc=0 --stop-time=400us ) >"$1/zd_$2.log" 2>&1
  grep -q "tb_gdn_emit_chain: PASS" "$1/zd_$2.log" && echo PASS || echo FAIL
}
if [ -d "$SCRATCH/R6" ]; then
  ctl="$SCRATCH/zctl"; rm -rf "$ctl"; mkdir -p "$ctl"
  cp "$SCRATCH/R6/gdn_emit_chain_vec.txt" "$ctl/"
  for f in fixed_luts_pkg fixed_pkg util_pkg gdn_head_emit rmsnorm_bf gdn_silu \
           gdn_y_emit gdn_emit_chain; do
    ghdl -a --std=08 -frelaxed --workdir="$ctl" "rtl/$f.vhd" >/dev/null 2>&1
  done
  ghdl -a --std=08 -frelaxed --workdir="$ctl" sim/tb_gdn_emit_chain.vhd >/dev/null 2>&1
  echo "  CONTROL  unmutated at Z_DELAY=$Z_LATE : $(zrun "$ctl" "$Z_LATE")   (must be PASS)"
  echo "  R6       mutant    at Z_DELAY=$Z_LATE : $(zrun "$SCRATCH/R6" "$Z_LATE")   (must be FAIL)"
fi

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "  (scored at Z_DELAY=$Z_DELAY, the configuration sim/regress.sh runs;"
echo "   R6 is killable only at Z_DELAY >= ~512, see the cross-check above)"
echo "scratch dir with every mutant, its vectors and its log: $SCRATCH"
