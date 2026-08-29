#!/usr/bin/env bash
# tools/ref9b_bfp_equiv.sh -- run the whole reg_put / bfp_pack equivalence test.
#
# Three stages, in this order, because each one controls for something the next
# one would otherwise assume:
#
#   1. SCORE   -- the C transcription of rtl/bfp_pack.vhd against the SHIPPING
#                 entity run in GHDL.  Until this passes, nothing below means
#                 anything: a comparison against a wrong transcription is a
#                 comparison against my reading of the RTL, not the RTL.
#   2. TEETH   -- seven mutants of the transcription, to show SCORE can fail.
#                 Mutants that do NOT bite are printed under their own names;
#                 they are this harness's resolution floor.
#   3. COMPARE -- the verified transcription against ref/run9b.c's reg_put.
#
# No hardware.  GHDL only, in a scratch directory, writing nothing into the
# repository.  Nothing here is a sim/regress.sh gate row: regress.sh globs
# sim/tb_*.vhd and tb/tb_*.vhd only (SUITE_DIRS, regress.sh:783).
#
# Usage: bash tools/ref9b_bfp_equiv.sh [scratch_dir]

set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCR=${1:-${TMPDIR:-/tmp}/ref9b_bfp_equiv.$$}
mkdir -p "$SCR" || exit 2
cd "$SCR" || exit 2

CASES=800
CFGS=("16 12" "172 12" "8 0" "16 20" "64 12")

echo "== analyse rtl/bfp_pack.vhd and the driver =="
ghdl -a --std=08 --work=work \
     "$REPO/rtl/util_pkg.vhd" "$REPO/rtl/fixed_luts_pkg.vhd" \
     "$REPO/rtl/fixed_pkg.vhd" "$REPO/rtl/bfp_pack.vhd" \
     "$REPO/tools/ref9b_bfp_equiv_tb.vhd" || exit 2

echo "== build the comparator =="
gcc -O2 -Wall -Wextra -I "$REPO/ref" -o bfpeq "$REPO/tools/ref9b_bfp_equiv.c" -lm || exit 2
for m in 1 2 3 4 5 6 7; do
  gcc -O2 -w -I "$REPO/ref" -DREF9B_BFPEQ_MUT="$m" \
      -o "bfpeq_m$m" "$REPO/tools/ref9b_bfp_equiv.c" -lm || exit 2
done

rc=0
for cfg in "${CFGS[@]}"; do
  set -- $cfg; N=$1; Q=$2
  ./bfpeq --n "$N" --q "$Q" --cases "$CASES" --emit "c_${N}_${Q}.txt" >/dev/null || exit 2
  ghdl -r --std=08 ref9b_bfp_equiv_tb -gN="$N" -gQ="$Q" \
       -gVEC="c_${N}_${Q}.txt" > "rtl_${N}_${Q}.txt" 2>&1 || exit 2

  echo
  echo "== N=$N Q=$Q =="
  ./bfpeq --n "$N" --q "$Q" --cases "$CASES" --score "rtl_${N}_${Q}.txt" | tail -1 || rc=1

  if [ "$N" = 16 ] && [ "$Q" = 12 ]; then
    echo "-- teeth: mutants of the transcription, scored against the same RTL run"
    for m in 1 2 3 4 5 6 7; do
      out=$("./bfpeq_m$m" --n "$N" --q "$Q" --cases "$CASES" --score "rtl_${N}_${Q}.txt" | tail -1)
      case "$out" in
        *BIT-IDENTICAL*) echo "   m$m DOES NOT BITE -- $out" ;;
        *)               echo "   m$m bites          -- $out" ;;
      esac
    done
  fi

  ./bfpeq --n "$N" --q "$Q" --cases "$CASES" --compare
done

echo
echo "scratch: $SCR"
exit $rc
