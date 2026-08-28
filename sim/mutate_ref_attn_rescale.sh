#!/usr/bin/env bash
# Mutation test of the C REFERENCE, ref/attn_rescale_vec.c, run BEFORE
# rtl/attn_rescale_skel.vhd existed.  Same discipline as
# sim/mutate_ref_attn_rope.sh: a KILL requires an ORACLE's own message, not a
# non-zero exit and not a coverage counter, and the two are reported apart --
# "killed by coverage" means the recipe changed in a way no oracle noticed.
#
# WHY THIS MATTERS MORE THAN USUAL HERE.  The skeleton this reference guards is
# a PRICING skeleton, and the number it will report -- one DSP48E2 instead of
# two -- is only meaningful if the two-pass chunked structure computes the same
# function as the direct product.  ORACLE 5 is the check that establishes that,
# so a mutation of the chunk split MUST die by ORACLE 5 specifically.  If it
# died only by ORACLE 1 or 2 the chunk identity would be riding on the general
# product check and would not be independently pinned.
#
# Usage: bash sim/mutate_ref_attn_rescale.sh
# Env:   SCRATCH=<dir>  NCASE=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=ref/attn_rescale_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-512}"
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
  ( cd "$dir" && ./m v.txt "$NCASE" ) > "$dir/out.log" 2> "$dir/err.log"
  local rc=$?
  if grep -q "FAIL oracle" "$dir/err.log"; then
    echo "$tag  killed by $(grep -m1 -o 'FAIL oracle [0-9]*' "$dir/err.log" | sed 's/FAIL //')  -- $desc"
  elif grep -q "COVERAGE HOLE" "$dir/err.log"; then
    echo "$tag  COVERAGE ONLY -- no oracle noticed.  Investigate: $desc"
  elif [ $rc -ne 0 ]; then
    echo "$tag  NON-ZERO EXIT, no oracle message  -- $desc"
  else
    echo "$tag  SURVIVED  -- $desc"
  fi
}

echo "======= mutations of ref/attn_rescale_vec.c (the REFERENCE) ======="

# ---- the recipe -----------------------------------------------------------
mutate S1 "the rescale shifts 11 instead of RSH = 12" \
'    return mv4i_round_shift(o * f, ATTN_RS_RSH);' \
'    return mv4i_round_shift(o * f, ATTN_RS_RSH-1);'

mutate S2 "the rescale FLOORS instead of rounding half toward +infinity" \
'    return mv4i_round_shift(o * f, ATTN_RS_RSH);' \
'    return mv4i_floor_shr(o * f, ATTN_RS_RSH);'

mutate S3 "the rescale rounds half AWAY FROM ZERO, the classic wrong mode" \
'    return mv4i_round_shift(o * f, ATTN_RS_RSH);' \
'    return (o < 0) ? -mv4i_round_shift(-o * f, ATTN_RS_RSH)
                    : mv4i_round_shift(o * f, ATTN_RS_RSH);'

mutate S4 "the identity factor is 4095, so f = 4096 stops being exact" \
'#define ATTN_RS_FONE   4096          /* the identity factor, spec 5c k = 0 */' \
'#define ATTN_RS_FONE   4095          /* the identity factor, spec 5c k = 0 */'

# ---- the CHUNK SPLIT.  These are the ones that must die by ORACLE 5. -------
mutate S5 "the low chunk is taken SIGNED instead of unsigned -- the classic error" \
'            int64_t a_lo = o & ((((int64_t)1) << ATTN_RS_SPLIT_ORACLE) - 1);' \
'            int64_t a_lo = (int64_t)(int32_t)((o << (32-ATTN_RS_SPLIT_ORACLE)) >> (32-ATTN_RS_SPLIT_ORACLE));'

mutate S6 "the high chunk shifts LOGICALLY, so a negative o loses its sign" \
'            int64_t a_hi = o >> ATTN_RS_SPLIT_ORACLE;      /* arithmetic */' \
'            int64_t a_hi = (int64_t)((uint64_t)o >> ATTN_RS_SPLIT_ORACLE);'

mutate S7 "the split is 16 bits on the high side and 17 on the low" \
'            int64_t a_hi = o >> ATTN_RS_SPLIT_ORACLE;      /* arithmetic */' \
'            int64_t a_hi = o >> (ATTN_RS_SPLIT_ORACLE+1);  /* arithmetic */'

mutate S8 "the recombination weights the high chunk by 2^16, one bit short" \
'            int64_t rec  = a_hi * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE) + a_lo;' \
'            int64_t rec  = a_hi * (((int64_t)1) << (ATTN_RS_SPLIT_ORACLE-1)) + a_lo;'

mutate S9 "the chunked PRODUCT drops the low partial entirely" \
'            int64_t prec = (a_hi * f) * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE)
                         + (a_lo * f);' \
'            int64_t prec = (a_hi * f) * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE);'

mutate S10 "the chunked product shifts the WRONG partial" \
'            int64_t prec = (a_hi * f) * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE)
                         + (a_lo * f);' \
'            int64_t prec = (a_lo * f) * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE)
                         + (a_hi * f);'

# ---- checks of the CHECKS -------------------------------------------------
mutate S11 "the ORACLE's shift moves to 11 while the recipe stays at 12" \
'#define ATTN_RS_RSH_ORACLE   12' \
'#define ATTN_RS_RSH_ORACLE   11'

mutate S12 "the ORACLE's split moves to 18 while the recipe stays at 17" \
'#define ATTN_RS_SPLIT_ORACLE 17' \
'#define ATTN_RS_SPLIT_ORACLE 18'

mutate S13 "ORACLE 7's range bound is widened by a bit, so an overflowing y passes" \
'        if (y >= ACC_LIM || y < -ACC_LIM) {' \
'        if (y >= ACC_LIM*2 || y < -ACC_LIM*2) {'

# ---- the accumulator width ------------------------------------------------
mutate S14 "the accumulator is 37 bits, so ORACLE 7's licence for no saturation moves" \
'#define ATTN_RS_ACC_W  36' \
'#define ATTN_RS_ACC_W  37'

mutate S15 "the split is 30 bits: it recombines perfectly but no longer fits a DSP port" \
'#define ATTN_RS_SPLIT_ORACLE 17' \
'#define ATTN_RS_SPLIT_ORACLE 30'

echo "======= end ======="
