#!/usr/bin/env bash
# Mutation test of the C REFERENCE, ref/attn_twiddle_vec.c, run BEFORE any RTL
# existed.  Same discipline as sim/mutate_ref_attn_rope.sh: a KILL requires an
# ORACLE's own message, not a non-zero exit and not a coverage counter.
#
# NOTE ON WHAT IS AND IS NOT MUTATED HERE.  tw_W and tw_SIN are built from libm
# inside this file and are NOT read from rtl/imrope_pkg.vhd, which is what makes
# the pair a double oracle at all.  Mutating the table build therefore tests
# ORACLE 1 (the table against libm to half an ulp) and ORACLE 2 (the table's
# exact symmetries) directly, which is the point: those two are the only checks
# standing between a mis-generated table and a green run.
#
# Usage: bash sim/mutate_ref_attn_twiddle.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  NPAIR=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=ref/attn_twiddle_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-24}"
NPAIR="${NPAIR:-32}"
mkdir -p "$SCRATCH"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/m.c" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("MUTATION ANCHOR MATCHED %d TIMES, expected 1\n" % n)
    sys.exit(2)
open(dst, "w").write(s.replace(old, new))
PY
  if [ $? -ne 0 ]; then echo "$tag  ANCHOR FAILED"; return; fi
  if ! cc -O2 -w -o "$dir/m" "$dir/m.c" -lm -I ref 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./m v.txt "$NCASE" "$NPAIR" ) > "$dir/out.log" 2> "$dir/err.log"
  local rc=$?
  if grep -q "FAIL oracle" "$dir/err.log"; then
    echo "$tag  killed by $(grep -m1 -o 'FAIL oracle [0-9]*' "$dir/err.log")  -- $desc"
  elif grep -q "FAIL " "$dir/err.log"; then
    echo "$tag  killed by $(grep -m1 -o 'FAIL [a-z ]*' "$dir/err.log")  -- $desc"
  elif grep -qi "COVERAGE" "$dir/err.log"; then
    echo "$tag  COVERAGE ONLY -- no oracle noticed.  Investigate: $desc"
  elif [ $rc -ne 0 ]; then
    echo "$tag  NON-ZERO EXIT, no oracle message  -- $desc"
  else
    echo "$tag  SURVIVED  -- $desc"
  fi
}

echo "======= mutations of ref/attn_twiddle_vec.c (the REFERENCE) ======="

# ---- the frequency ladder, site R1 ---------------------------------------
mutate T1 "the base is 1e6 instead of the GGUF rope.freq_base of 1e7" \
'#define ATTN_TW_BASE    1.0e7' \
'#define ATTN_TW_BASE    1.0e6'

mutate T2 "the ladder exponent uses NPAIR-1, an off-by-one in the spacing" \
'                    pow(ATTN_TW_BASE, -(double)j / (double)ATTN_TW_NPAIR)' \
'                    pow(ATTN_TW_BASE, -(double)j / (double)(ATTN_TW_NPAIR-1))'

mutate T3 "the ladder climbs instead of descending (sign of the exponent)" \
'                    pow(ATTN_TW_BASE, -(double)j / (double)ATTN_TW_NPAIR)' \
'                    pow(ATTN_TW_BASE,  (double)j / (double)ATTN_TW_NPAIR)'

mutate T4 "the turn normalisation drops the 2*pi, so W is in radians" \
'                    / (2.0 * M_PI));' \
'                    );'

# ---- the sine table ------------------------------------------------------
mutate T5 "the table is built with cos where sin is meant" \
'        tw_SIN[i] = (int32_t)llround((double)ATTN_TW_QMAX *
                      sin(2.0 * M_PI * (double)(i % ATTN_TW_TBL)' \
'        tw_SIN[i] = (int32_t)llround((double)ATTN_TW_QMAX *
                      cos(2.0 * M_PI * (double)(i % ATTN_TW_TBL)'

mutate T6 "the table amplitude is 32768, one over the Q15 rail" \
'#define ATTN_TW_QMAX    32767' \
'#define ATTN_TW_QMAX    32768'

mutate T7 "the table TRUNCATES instead of rounding to nearest" \
'        tw_SIN[i] = (int32_t)llround((double)ATTN_TW_QMAX *' \
'        tw_SIN[i] = (int32_t)((double)ATTN_TW_QMAX *'

mutate T8 "the table is built over half a turn, so it is not periodic" \
'                          / (double)ATTN_TW_TBL));' \
'                          / (double)(2*ATTN_TW_TBL)));'

# ---- the lookup, site R2 --------------------------------------------------
mutate T9 "the index and fraction split one bit low" \
'    uint32_t idx  = phi >> ATTN_TW_FRACW;
    uint32_t frac = phi & (((uint32_t)1 << ATTN_TW_FRACW) - 1u);' \
'    uint32_t idx  = phi >> (ATTN_TW_FRACW-1);
    uint32_t frac = phi & (((uint32_t)1 << (ATTN_TW_FRACW-1)) - 1u);'

mutate T10 "the interpolation is dropped, nearest lower entry only" \
'    return lo + (int32_t)mv4i_floor_shr((int64_t)(hi - lo) * (int64_t)frac,
                                        ATTN_TW_FRACW);' \
'    return lo;'

mutate T11 "the interpolation runs backwards, lo and hi swapped" \
'    int32_t  lo   = tw_SIN[idx];
    int32_t  hi   = tw_SIN[(idx + 1u) % ATTN_TW_TBL];' \
'    int32_t  lo   = tw_SIN[(idx + 1u) % ATTN_TW_TBL];
    int32_t  hi   = tw_SIN[idx];'

mutate T12 "the interpolation shift ROUNDS instead of flooring" \
'    return lo + (int32_t)mv4i_floor_shr((int64_t)(hi - lo) * (int64_t)frac,
                                        ATTN_TW_FRACW);' \
'    return lo + (int32_t)mv4i_round_shift((int64_t)(hi - lo) * (int64_t)frac,
                                        ATTN_TW_FRACW);'

# ---- the quarter-turn cosine ---------------------------------------------
mutate T13 "the cosine is taken a quarter turn BEHIND instead of ahead" \
'    o->c = tw_lookup(o->phi + ATTN_TW_QUARTER, NULL, NULL);' \
'    o->c = tw_lookup(o->phi - ATTN_TW_QUARTER, NULL, NULL);'

mutate T14 "the cosine is taken a HALF turn ahead" \
'    o->c = tw_lookup(o->phi + ATTN_TW_QUARTER, NULL, NULL);' \
'    o->c = tw_lookup(o->phi + 2u*ATTN_TW_QUARTER, NULL, NULL);'

# ---- the phase itself -----------------------------------------------------
mutate T15 "the phase takes the HIGH 32 bits of pos*W, not the low" \
'    o->phi = (uint32_t)((uint64_t)pos * (uint64_t)tw_W[j]);   /* site R1 */' \
'    o->phi = (uint32_t)(((uint64_t)pos * (uint64_t)tw_W[j]) >> 32);   /* site R1 */'

echo "======= end ======="
