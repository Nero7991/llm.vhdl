#!/bin/sh
# ref/gen_golden_fx.sh — regenerate fixed-point golden vectors from the integer model.
# Run from repo root: sh ref/gen_golden_fx.sh
# Produces mem/golden/fx_*.txt (seven files).
set -e
cd "$(dirname "$0")/.."
mkdir -p mem/golden
gcc -O3 -o ref/run_fx ref/run_fx.c -lm
./ref/run_fx ref/stories260K.bin -z ref/tok512.bin -t 0 -i "Once upon a time" -n 200 --fx --dump 2>/dev/null >/dev/null
for f in fx_rmsnorm_l0 fx_rmsnorm_l0_w fx_rope_l0 fx_softmax_l0_h0 fx_swiglu_l0 fx_matvec_wq_l0 fx_layer0_out fx_tokens_greedy; do
  test -s "mem/golden/$f.txt" || { echo "MISSING mem/golden/$f.txt"; exit 1; }
done
tl=$(wc -l < mem/golden/fx_tokens_greedy.txt)
[ "$tl" -eq 200 ] || { echo "fx_tokens_greedy.txt: expected 200 lines, got $tl"; exit 1; }
echo "golden fx files OK"; ls mem/golden/fx_*.txt
echo ""
echo "Golden grades for Plan 3 RTL comparison:"
echo "  BIT-EXACT   : fx_matvec_wq_l0 (int16 in/weights + int64 acc), fx_tokens_greedy"
echo "  TOLERANCE   : fx_rmsnorm_l0, fx_rope_l0, fx_softmax_l0_h0, fx_swiglu_l0,"
echo "                fx_layer0_out (float glue snapshot; compare within ~+-2 int16 LSB)"
