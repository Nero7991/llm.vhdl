#!/bin/sh
# ref/gen_golden_fx.sh — regenerate fixed-point golden vectors from the integer model.
# Run from repo root: sh ref/gen_golden_fx.sh
# Produces mem/golden/fx_*.txt and mem/weights_l0/* files.
set -e
cd "$(dirname "$0")/.."
mkdir -p mem/golden mem/weights_l0
gcc -O3 -o ref/run_fx ref/run_fx.c -lm
./ref/run_fx ref/stories260K.bin -z ref/tok512.bin -t 0 -i "Once upon a time" -n 200 --fx --dump 2>/dev/null >/dev/null
for f in fx_rmsnorm_l0 fx_rmsnorm_l0_w fx_rope_l0 fx_softmax_l0_h0 fx_swiglu_l0 fx_matvec_wq_l0 fx_layer0_out fx_tokens_greedy fx_layer0_in fx_layer0_kv fx_embed fx_lmhead; do
  test -s "mem/golden/$f.txt" || { echo "MISSING mem/golden/$f.txt"; exit 1; }
done
for wname in wq wk wv wo w1 w3 w2; do
  test -s "mem/weights_l0/$wname.mem"       || { echo "MISSING mem/weights_l0/$wname.mem";       exit 1; }
  test -s "mem/weights_l0/${wname}_mult.mem" || { echo "MISSING mem/weights_l0/${wname}_mult.mem"; exit 1; }
  test -s "mem/weights_l0/${wname}_shift.mem"|| { echo "MISSING mem/weights_l0/${wname}_shift.mem";exit 1; }
done
for rname in att_rmsnorm_w ffn_rmsnorm_w; do
  test -s "mem/weights_l0/$rname.mem"     || { echo "MISSING mem/weights_l0/$rname.mem";     exit 1; }
  test -s "mem/weights_l0/${rname}_exp.txt"|| { echo "MISSING mem/weights_l0/${rname}_exp.txt";exit 1; }
done
tl=$(wc -l < mem/golden/fx_tokens_greedy.txt)
[ "$tl" -eq 200 ] || { echo "fx_tokens_greedy.txt: expected 200 lines, got $tl"; exit 1; }
echo "golden fx files OK"; ls mem/golden/fx_*.txt
echo "weight l0 files OK"; ls mem/weights_l0/
echo ""
echo "Golden grades for Plan 3 RTL comparison:"
echo "  BIT-EXACT   : fx_matvec_wq_l0 (int16 in/weights + int64 acc), fx_tokens_greedy"
echo "  TOLERANCE   : fx_rmsnorm_l0, fx_rope_l0, fx_softmax_l0_h0, fx_swiglu_l0,"
echo "                fx_layer0_out, fx_layer0_in, fx_layer0_kv (float glue; +-4 LSB)"
echo "  fx_embed    : embedding-lookup BFP re-quantise golden (+-2 LSB, embed.vhd)"
echo "  fx_lmhead   : classifier x-in + 512 raw int32 logits + argmax (lm_head.vhd/sampler.vhd)"
