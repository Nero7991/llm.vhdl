#!/usr/bin/env bash
# Mutation test of the C REFERENCE, ref/seq_vec_res_vec.c, run BEFORE any RTL
# exists.
#
# WHY THIS RUNS FIRST.  The RTL is going to be checked bit-exactly against this
# generator's output.  If the generator is wrong, the RTL will be made wrong to
# match it and every run will be green.  The four oracles inside the reference
# are what stop that, and this script is what shows the oracles work: each
# mutation below breaks the integer recipe, and an ORACLE -- not the exit code,
# not the coverage counter -- has to say so.
#
# A KILL REQUIRES THE ORACLE'S OWN MESSAGE.  Counting a non-zero exit as a kill
# would score the coverage check and the accumulator-overflow trap as oracles.
# Both are useful and both are reported separately below, because "killed by
# the coverage counter" means the recipe changed in a way no oracle noticed.
#
# Usage: bash sim/mutate_ref_seq_vec_res.sh
# Env:   SCRATCH=<dir>  NCASE=<n>  SEED=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=ref/seq_vec_res_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
NCASE="${NCASE:-64}"
SEED="${SEED:-12345}"
mkdir -p "$SCRATCH"

mutate() {
  local tag="$1" desc="$2" old="$3" new="$4"; shift 4
  local dir="$SCRATCH/$tag"
  rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$SRC" "$dir/m.c" "$old" "$new" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i], pairs[i+1]
    n = s.count(old)
    if n != 1:
        sys.stderr.write("MUTATION ANCHOR %d MATCHED %d TIMES, expected 1\n"
                         % (i//2, n))
        sys.exit(2)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  if [ $? -ne 0 ]; then echo "$tag  ANCHOR FAILED"; return; fi
  if ! cc -O2 -w -o "$dir/m" "$dir/m.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./m v.txt "$NCASE" "$SEED" ) > "$dir/out.log" 2> "$dir/err.log"
  local rc=$?
  if grep -q "ORACLE FAIL" "$dir/err.log"; then
    echo "$tag  KILLED by $(grep -m1 -o 'ORACLE FAIL ([^)]*)' "$dir/err.log")  -- $desc"
  elif grep -q "accumulator overflowed" "$dir/err.log"; then
    echo "$tag  KILLED by the accumulator-overflow trap (not an oracle)  -- $desc"
  elif grep -q "COVERAGE HOLE" "$dir/err.log"; then
    echo "$tag  COVERAGE ONLY -- no oracle noticed; a rule simply stopped being"
    echo "         reached.  Investigate: $desc"
  elif [ $rc -ne 0 ]; then
    echo "$tag  NON-ZERO EXIT, no oracle message  -- $desc"
  else
    echo "$tag  SURVIVED  -- $desc"
  fi
}

echo "============ mutations of ref/seq_vec_res_vec.c (the REFERENCE) ========="

mutate R1 "the SHMAX clamp is removed: align to max(ex,ee) unconditionally" \
'    j->q  = (qmax - qmin > SHMAX) ? (qmin + SHMAX) : qmax;   /* MUT_Q */' \
'    j->q  = qmax;   /* MUT_Q */'

mutate R2 "the SHMAX clamp is one too generous" \
'    j->q  = (qmax - qmin > SHMAX) ? (qmin + SHMAX) : qmax;   /* MUT_Q */' \
'    j->q  = (qmax - qmin > SHMAX+1) ? (qmin + SHMAX+1) : qmax;   /* MUT_Q */'

mutate R3 "the output shift is one too large (over-normalised)" \
'    j->sh   = j->p - KEEP; if (j->sh < 0) j->sh = 0;          /* MUT_SH */' \
'    j->sh   = j->p - KEEP + 1; if (j->sh < 0) j->sh = 0;      /* MUT_SH */'

mutate R4 "the output shift is one too small (under-normalised)" \
'    j->sh   = j->p - KEEP; if (j->sh < 0) j->sh = 0;          /* MUT_SH */' \
'    j->sh   = j->p - KEEP - 1; if (j->sh < 0) j->sh = 0;      /* MUT_SH */'

mutate R5 "the output exponent moves the WRONG WAY with the shift" \
'    j->oexp = j->q - j->sh;                                   /* MUT_OEXP */' \
'    j->oexp = j->q + j->sh;                                   /* MUT_OEXP */'

mutate R6 "the final requantise TRUNCATES instead of rounding half up" \
'        int64_t r = round_half_up((int64_t)j->acc[i], j->sh); /* MUT_RND */' \
'        int64_t r = floor_shr((int64_t)j->acc[i], j->sh);     /* MUT_RND */'

mutate R7 "the ALIGNMENT right shift truncates instead of rounding half up" \
'        int64_t b = (j->se >= 0) ? ((int64_t)j->e[i] << j->se)
                                 : round_half_up((int64_t)j->e[i], -j->se);' \
'        int64_t b = (j->se >= 0) ? ((int64_t)j->e[i] << j->se)
                                 : floor_shr((int64_t)j->e[i], -j->se);'

mutate R8 "the magnitude reduction folds the raw accumulator, not its absolute value" \
'        orv |= (uint64_t)iabs64(s);                          /* MUT_OR */' \
'        orv |= (uint64_t)s;                                  /* MUT_OR */'

mutate R9 "the saturating clamp is removed and the int16 cast wraps" \
'        if (r >  32767) { r =  32767; j->sat = 1; }           /* MUT_SAT */' \
'        if (0)          { r =  32767; j->sat = 1; }           /* MUT_SAT */'

mutate R10 "KEEP is MANT_W-1: one more magnitude bit kept than int16 holds" \
'    j->sh   = j->p - KEEP; if (j->sh < 0) j->sh = 0;          /* MUT_SH */' \
'    j->sh   = j->p - (MANT_W-1); if (j->sh < 0) j->sh = 0;    /* MUT_SH */'

mutate R11 "the two operands are subtracted rather than added" \
'        int64_t s = a + b;                                   /* MUT_ADD */' \
'        int64_t s = a - b;                                   /* MUT_ADD */'

echo
echo "---- checks of the CHECKS: mutate an oracle, the recipe left alone ------"
echo "     (each must SURVIVE nothing -- an oracle that cannot fail is a comment)"

mutate R12 "O4 shifts only ex, not both exponents, so it stops being a test" \
'        t = *j; t.ex = j->ex + k; t.ee = j->ee + k;' \
'        t = *j; t.ex = j->ex + k; t.ee = j->ee;'

# NOT "widen O1's bound" on its own: on a CORRECT recipe a looser bound cannot
# fail, so that mutation is a no-op and scores a meaningless survivor -- the
# same trap as attn_recip's N13.  To test that O1's bound is what has the teeth
# it has to be widened WHILE the recipe is broken, so this is a compound.
mutate R13 "O1's bound widened to 8 LSB AND the final requantise truncated" \
'        long double bound = ldexp2(0.5L, -j->q) + ldexp2(0.5L, -j->oexp);' \
'        long double bound = ldexp2(8.0L, -j->q) + ldexp2(8.0L, -j->oexp);' \
'        int64_t r = round_half_up((int64_t)j->acc[i], j->sh); /* MUT_RND */' \
'        int64_t r = floor_shr((int64_t)j->acc[i], j->sh);     /* MUT_RND */'

mutate R14 "the SHMAX clamp is one too TIGHT: precision lost, nothing overflows" \
'    j->q  = (qmax - qmin > SHMAX) ? (qmin + SHMAX) : qmax;   /* MUT_Q */' \
'    j->q  = (qmax - qmin > SHMAX-1) ? (qmin + SHMAX-1) : qmax;   /* MUT_Q */'

mutate R15 "SHMAX moved without MANT_W or ACC_W moving with it" \
'#define SHMAX  (ACC_W - MANT_W - 1)      /* 15 */' \
'#define SHMAX  (ACC_W - MANT_W)          /* 15 */'

echo
echo "scratch dir with every mutant and every log: $SCRATCH"
