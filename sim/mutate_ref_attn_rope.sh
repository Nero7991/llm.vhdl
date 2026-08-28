#!/usr/bin/env bash
# Mutation test of the C REFERENCE, ref/attn_rope_vec.c, run BEFORE any RTL
# existed.  Same discipline as sim/mutate_ref_seq_vec_res.sh.
#
# WHY THIS RUNS FIRST.  rtl/attn_rope.vhd is checked bit-exactly against this
# generator's output.  If the generator is wrong, the RTL gets made wrong to
# match it and every run is green.  The six oracles inside the reference are
# what stop that, and this script is what shows the oracles work: each mutation
# breaks the integer recipe, and an ORACLE -- not the exit code, not a coverage
# counter -- has to say so.
#
# A KILL REQUIRES AN ORACLE'S OWN MESSAGE.  Counting a non-zero exit as a kill
# would score the coverage assertions as oracles.  They are reported separately,
# because "killed by coverage" means the recipe changed in a way no oracle saw.
#
# Usage: bash sim/mutate_ref_attn_rope.sh
# Env:   SCRATCH=<dir>
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=ref/attn_rope_vec.c
SCRATCH="${SCRATCH:-$(mktemp -d)}"
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
  ( cd "$dir" && ./m v.txt ) > "$dir/out.log" 2> "$dir/err.log"
  local rc=$?
  if grep -q "FAIL oracle" "$dir/err.log"; then
    echo "$tag  killed by $(grep -m1 -o 'FAIL oracle [0-9]*' "$dir/err.log")  -- $desc"
  elif grep -qi "COVERAGE" "$dir/err.log"; then
    echo "$tag  COVERAGE ONLY -- no oracle noticed.  Investigate: $desc"
  elif [ $rc -ne 0 ]; then
    echo "$tag  NON-ZERO EXIT, no oracle message  -- $desc"
  else
    echo "$tag  SURVIVED  -- $desc"
  fi
}

echo "========= mutations of ref/attn_rope_vec.c (the REFERENCE) ========="

mutate P1 "the pairing becomes ADJACENT (2j, 2j+1) instead of (j, j+NPAIR)" \
'    for (int j = 0; j < npair; j++) {
        int64_t x0 = x[j], x1 = x[j + npair];
        int64_t c = cs[j], s = sn[j];' \
'    for (int j = 0; j < npair; j++) {
        int64_t x0 = x[2*j], x1 = x[2*j + 1];
        int64_t c = cs[j], s = sn[j];'

mutate P2 "the kernel shifts 14 instead of Q = 15" \
'        int64_t r0 = mv4i_round_shift(x0*c - x1*s, ATTN_RP_Q);' \
'        int64_t r0 = mv4i_round_shift(x0*c - x1*s, ATTN_RP_Q-1);'

mutate P3 "the kernel FLOORS instead of rounding" \
'        int64_t r1 = mv4i_round_shift(x0*s + x1*c, ATTN_RP_Q);' \
'        int64_t r1 = mv4i_floor_shr(x0*s + x1*c, ATTN_RP_Q);'

mutate P4 "sat16 removed, so a large rotation WRAPS" \
'        int32_t m0 = mv4i_sat16(r0), m1 = mv4i_sat16(r1);' \
'        int32_t m0 = (int32_t)(int16_t)r0, m1 = (int32_t)(int16_t)r1;'

mutate P5 "the first output ADDS the cross term instead of subtracting" \
'mv4i_round_shift(x0*c - x1*s, ATTN_RP_Q);' \
'mv4i_round_shift(x0*c + x1*s, ATTN_RP_Q);'

mutate P6 "the second output SUBTRACTS the cross term instead of adding" \
'mv4i_round_shift(x0*s + x1*c, ATTN_RP_Q);' \
'mv4i_round_shift(x0*s - x1*c, ATTN_RP_Q);'

mutate P7 "the two outputs are written to each other's slots" \
'        y[j] = m0;
        y[j + npair] = m1;' \
'        y[j] = m1;
        y[j + npair] = m0;'

mutate P8 "the unrotated tail starts one dim late, leaving one dim stale" \
'    for (int i = n_rot; i < head_dim; i++) y[i] = x[i];
}' \
'    for (int i = n_rot+1; i < head_dim; i++) y[i] = x[i];
}'

mutate P9 "the unrotated tail starts one dim early, overwriting a rotated dim" \
'    for (int i = n_rot; i < head_dim; i++) y[i] = x[i];
}' \
'    for (int i = n_rot-1; i < head_dim; i++) y[i] = x[i];
}'

mutate P10 "the unrotated tail is shifted by one element" \
'    for (int i = n_rot; i < head_dim; i++) y[i] = x[i];
}' \
'    for (int i = n_rot; i < head_dim-1; i++) y[i] = x[i+1];
}'

mutate P11 "cos and sin are swapped" \
'        int64_t c = cs[j], s = sn[j];
        int64_t r0' \
'        int64_t c = sn[j], s = cs[j];
        int64_t r0'

mutate P12 "the twiddle index trails the pair index by one" \
'        int64_t c = cs[j], s = sn[j];
        int64_t r0' \
'        int64_t c = cs[(j+npair-1)%npair], s = sn[(j+npair-1)%npair];
        int64_t r0'

# A CHECK OF THE CHECK.  This mutates the ORACLE, not the recipe.  If it does
# not fire, the oracle is not reading the quantity it claims to read.
mutate P13 "the ORACLE's Q moves to 14 while the recipe stays at 15" \
'#define ATTN_RP_Q_ORACLE 15' \
'#define ATTN_RP_Q_ORACLE 14'

echo "========= end ========="
