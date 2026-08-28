#!/usr/bin/env bash
# Mutation test of the SEAM REFERENCE, ref/seq_vec_chain_vec.c, run BEFORE the
# seam RTL exists.
#
# WHY THIS RUNS FIRST, AGAIN.  Same argument as sim/mutate_ref_seq_vec_res.sh:
# the RTL is going to be checked bit-exactly against this generator's output,
# so a wrong generator makes a wrong DUT green.  What is different here is WHAT
# is being certified.  The per-op reference certifies one residual; this one
# certifies the CHAIN -- that the exponent a step publishes is the exponent the
# next step consumes -- and its oracles are C1 (the exact running sum, in
# integers, against an accumulated bound) and C2 (whole-chain shift
# invariance).  Neither restates the recipe.
#
# A KILL REQUIRES AN ORACLE'S OWN MESSAGE.  "ORACLE FAIL" is the per-step set
# inherited from ref/seq_vec_res_vec.c; "CHAIN ORACLE FAIL" is C1 or C2.  A
# COVERAGE HOLE is reported separately and is NOT scored as a kill: it means
# the chain changed shape and no oracle noticed, which is a different and worse
# result than a kill.
#
# TWO CLASSES OF MUTATION, and the second is the one that matters:
#   - mutations of the CHAIN MODEL (the feedback, the data recorded).  An
#     oracle must catch them.
#   - mutations of the ORACLES THEMSELVES, with the model left alone.  Each of
#     those must ALSO be caught, by the run failing on correct data -- that is
#     what shows the oracle is tight rather than decorative.  A bound that is
#     merely widened cannot fail on a correct chain, so widening one is scored
#     only in a COMPOUND with a real defect (the attn_recip N13 trap, hit again
#     by the per-op reference and recorded there as R13).
#
# Usage: bash sim/mutate_ref_seq_vec_chain.sh
# Env:   SCRATCH=<dir>  N=<elements>  NRES=<steps>  SEED=<n>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=ref/seq_vec_chain_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
N="${N:-250}"
NRES="${NRES:-8}"
SEED="${SEED:-20260827}"
mkdir -p "$SCRATCH"
NKILL=0; NSURV=0; NTOT=0
EXPECT_COV=0

mutate() {
  local tag="$1" desc="$2"; shift 2
  local dir="$SCRATCH/$tag"
  NTOT=$((NTOT+1))
  rm -rf "$dir"; mkdir -p "$dir"
  cp ref/seq_vec_res_vec.c "$dir/"
  python3 - "$SRC" "$dir/m.c" "$@" <<'PY'
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
  if ! cc -O2 -w -I "$dir" -o "$dir/m" "$dir/m.c" -lm 2>"$dir/cc.log"; then
    echo "$tag  DID NOT COMPILE -- a mutation that will not build has tested nothing"
    return
  fi
  ( cd "$dir" && ./m v.txt "$N" "$NRES" "$SEED" ) > "$dir/out.log" 2> "$dir/err.log"
  local rc=$?
  if grep -q "CHAIN ORACLE FAIL" "$dir/err.log"; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED by $(grep -m1 -o 'CHAIN ORACLE FAIL ([^)]*)' "$dir/err.log")  -- $desc"
  elif grep -q "ORACLE FAIL" "$dir/err.log"; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED by the per-step $(grep -m1 -o 'ORACLE FAIL ([^)]*)' "$dir/err.log")  -- $desc"
  elif grep -q "exceeds the exact grid" "$dir/err.log"; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED by C1's exact-grid guard  -- $desc"
  elif grep -q "accumulator overflowed" "$dir/err.log"; then
    NKILL=$((NKILL+1))
    echo "$tag  KILLED by the accumulator-overflow trap (not an oracle)  -- $desc"
  elif grep -q "COVERAGE HOLE" "$dir/err.log"; then
    if [ "$EXPECT_COV" = 1 ]; then
      NKILL=$((NKILL+1))
      echo "$tag  KILLED by the C3 coverage gate  -- $desc"
    else
      echo "$tag  COVERAGE ONLY -- no oracle noticed, a property simply stopped"
      echo "         being reached.  Investigate: $desc"
    fi
  elif [ $rc -ne 0 ]; then
    echo "$tag  NON-ZERO EXIT, no oracle message  -- $desc"
  else
    NSURV=$((NSURV+1))
    echo "$tag  SURVIVED  -- $desc"
  fi
}

echo "========= mutations of the CHAIN MODEL in ref/seq_vec_chain_vec.c ======="

mutate C1a "the feedback is cut: every step re-reads the INITIAL exponent" \
'        ex = j.oexp;
    }
}' \
'        ex = ex0 + shift;
    }
}'

mutate C1b "the feedback is one step STALE: the exponent lags by a step" \
'        j.ex = ex;
        j.ee = eev[k] + shift;' \
'        j.ex = (k > 0) ? exv[k-1] : ex;
        j.ee = eev[k] + shift;'

mutate C1c "the two exponents are swapped at every step" \
'        j.ex = ex;
        j.ee = eev[k] + shift;' \
'        j.ex = eev[k] + shift;
        j.ee = ex;'

mutate C1d "the recorded output is the raw accumulator, not the requantised mantissa" \
'            for (int i = 0; i < n; i++) Xv[k][i] = j.out[i];' \
'            for (int i = 0; i < n; i++) Xv[k][i] = (int16_t)j.acc[i];'

mutate C1e "the data fed forward is the ORIGINAL X, not the previous output" \
'            j.x[i] = (k == 0) ? X0v[i] : Xv[k-1][i];' \
'            j.x[i] = X0v[i];'

mutate C1f "one element of the chain is dropped: element 7 never receives its ER" \
'            j.e[i] = Ev[k][i];' \
'            j.e[i] = (i == 7) ? 0 : Ev[k][i];'

echo
echo "---- checks of the CHECKS: mutate an oracle, the model left alone ------"
echo "     (each must fail on a CORRECT chain, or the oracle is a comment)"

mutate C2a "C1's bound drops the output-rounding term" \
'        if (shv[k] > 0)      bound += (__int128)1 << (GB - oexpv[k] - 1);' \
'        if (0)               bound += (__int128)1 << (GB - oexpv[k] - 1);'

# C2b AND C2c ARE EXPECTED SURVIVORS AND THEY ARE KEPT FOR THAT REASON.  A
# bound is an INEQUALITY: removing a term tightens it, and a tightened bound
# only fails if some element in the chain actually reaches it.  Neither term is
# reached here, because step 0's saturation term is 1 output LSB while its real
# error is half of one -- the round and the clamp move in opposite directions --
# and that slack of one LSB swamps the half-LSB alignment term for the rest of
# the chain.  So these two say the bound is SOUND BUT NOT TIGHT, which is worth
# knowing and is not a defect.  C2f is the entry that shows the bound is not
# vacuous: widened by a factor of 2^12 it still kills a cut feedback.
mutate C2b "C1's bound drops both alignment terms (EXPECTED SURVIVOR, see above)" \
'        if (qv[k] < ex)      bound += (__int128)1 << (GB - qv[k] - 1);
        if (qv[k] < eev[k])  bound += (__int128)1 << (GB - qv[k] - 1);' \
'        if (0)               bound += (__int128)1 << (GB - qv[k] - 1);
        if (0)               bound += (__int128)1 << (GB - qv[k] - 1);'

mutate C2c "C1's bound drops the saturation term (EXPECTED SURVIVOR, see above)" \
'        if (satv[k])         bound += (__int128)1 << (GB - oexpv[k]);' \
'        if (0)               bound += (__int128)1 << (GB - oexpv[k]);'

mutate C2d "C1 accumulates ER at the OUTPUT grid instead of its own exponent" \
'            exact[i] += (__int128)Ev[k][i] << (GB - eev[k]);' \
'            exact[i] += (__int128)Ev[k][i] << (GB - oexpv[k]);'

mutate C2e "C2 shifts only the initial exponent, not the ER exponents" \
'        j.ee = eev[k] + shift;' \
'        j.ee = eev[k];'

# A LOOSE BOUND CANNOT FAIL ON A CORRECT CHAIN, so widening C1 on its own is a
# no-op that would score a meaningless survivor.  It is only a test when the
# model is broken at the same time: this is the compound that shows C1's bound
# is what carries the weight and not merely present.
mutate C2f "C1's bound widened 2^12 AND the feedback cut (compound)" \
'            if (d > bound) {' \
'            if (d > (bound << 12)) {' \
'        ex = j.oexp;
    }
}' \
'        ex = ex0 + shift;
    }
}'

echo
echo "---- the COVERAGE gate: a chain that stops exercising the seam ---------"
echo "     (here a COVERAGE HOLE report IS the kill: C3 is the gate under test)"
EXPECT_COV=1
mutate C3a "every ER exponent equals its step's input exponent: the SHMAX clamp is never reached" \
'    static const int DELTA[] = { -1, +3, -5, +(SHMAX+1), 0, -(SHMAX+2), +7, -2 };' \
'    static const int DELTA[] = { 0, 0, 0, 0, 0, 0, 0, 0 };'
EXPECT_COV=0

echo
echo "kill ratio: $NKILL killed, $NSURV survived, of $NTOT"
echo "scratch dir with every mutant and every log: $SCRATCH"
