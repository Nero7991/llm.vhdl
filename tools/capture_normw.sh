#!/usr/bin/env bash
# Capture the seam stream of the REAL-GAIN configuration, sim/tb_llama_top_normw.
#
# WHY A FOURTH CONFIGURATION AND NOT A CASE IN capture_llama_top.sh.  That
# script belongs to another track today (tools/ref9b/**).  Its `real` case is
# sim/tb_llama_top_real.vhd's generic set; this is that set plus NORM_W_IMAGE,
# and nothing else, so the two captures are a controlled pair whose only
# difference is the norm gain.  When tools/ref9b is free, this belongs there as
# a `realw` case and this file should go.
#
# Usage:  bash tools/capture_normw.sh [outfile]
# Env:    SCRATCH=<dir>   keep the work directory
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
W="$SCRATCH/work"
rm -rf "$W"; mkdir -p "$W/run"

# The file list is sim/regress.sh's for the tb_llama_top family, in dependency
# order.  Kept as one list rather than sourced, because a capture that silently
# analyses a STALE llama_top is a capture of the wrong design.
FILES="rtl/fixed_luts_pkg.vhd rtl/fixed_pkg.vhd rtl/util_pkg.vhd
       rtl/model_cfg_pkg.vhd rtl/act_mem_striped.vhd rtl/async_fifo.vhd
       rtl/attn_emit.vhd rtl/attn_gate.vhd rtl/attn_kv_quant.vhd
       rtl/attn_mac_array.vhd rtl/attn_rope.vhd rtl/attn_score_q12.vhd
       rtl/attn_softmax.vhd rtl/axi_rd_fsm.vhd rtl/divider_rs.vhd
       rtl/gdn_conv.vhd rtl/gdn_exp_capture.vhd rtl/gdn_head_emit.vhd
       rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
       rtl/gdn_y_emit.vhd rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd
       rtl/llama_map_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd
       rtl/rmsnorm_rs.vhd rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
       rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
       rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
       rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
       rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/matvec_int4.vhd rtl/sampler_stream.vhd
       rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd rtl/swiglu_mem.vhd
       rtl/llama_top.vhd
       sim/tb_llama_top.vhd"

# sim/tb_llama_top_normw.vhd's generics, copied from that wrapper.  NRUNS is
# forced to 1: every run starts from a reset and only run 0 is captured, so
# runs 1..N-1 cost wall time and change nothing in the file.
G="-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
   -gNORM_REAL=true -gNORM_ANCHOR=false
   -gW_IMAGE=llama_top_w_b4_pool.hex
   -gNORM_W_IMAGE=llama_top_nw_b4_mean.hex"
[ -z "$OUT" ] && OUT="$PWD/tools/golden/llama_top_normw.txt"

for f in $FILES; do
  if ! ghdl -a --std=08 -frelaxed --workdir="$W" "$f" >> "$W/analyze.log" 2>&1; then
    echo "DID NOT ANALYZE: $f"; sed -n 1,6p "$W/analyze.log"; exit 2
  fi
done
ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex"   "$W/run/" 2>/dev/null
ln -sfn "$PWD/sim/llama_top_nw_b4_mean.hex"  "$W/run/" 2>/dev/null

( cd "$W/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed --workdir=".." \
    tb_llama_top $G -gNRUNS=1 -gCAPTURE=cap.txt \
    --max-stack-alloc=0 --stop-time=900ms > run.log 2>&1 )
rc=$?
grep -a "RESULT:\|seam capture wrote\|norm gain is" "$W/run/run.log" \
  | sed 's/^.*(report note): //'
if [ ! -s "$W/run/cap.txt" ]; then
  echo "NO CAPTURE WAS WRITTEN (ghdl rc=$rc).  A run that died has captured "
  echo "nothing, and an empty file compares equal to another empty file."
  exit 3
fi
mkdir -p "$(dirname "$OUT")"
cp "$W/run/cap.txt" "$OUT"
echo "wrote $OUT ($(grep -ac '^SEAM' "$OUT") records)"
echo "scratch: $SCRATCH"
