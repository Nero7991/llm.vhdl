#!/usr/bin/env bash
# Run sim/tb_llama_top.vhd with the seam capture on, and emit the text stream
# tools/ref9b/capture_to_r9bs.py parses.
#
# WHY A SCRIPT AND NOT A LINE IN A DOCUMENT.  The golden captures under
# tools/ref9b/golden/ are committed artefacts, and an artefact whose recipe
# lives only in prose is an artefact nobody can reproduce.  Every golden in
# that directory is `bash tools/ref9b/capture_llama_top.sh <config>` and
# nothing else.
#
# Usage:  bash tools/ref9b/capture_llama_top.sh {real|seq|stub} [outfile]
# Env:    SCRATCH=<dir>   keep the work directory
#
# THE THREE CONFIGURATIONS ARE THE THREE GATE ROWS, and their generics are
# copied from the wrappers rather than invented:
#   real  = sim/tb_llama_top_real.vhd   (real A, B, C, rmsnorm_rs, real weights)
#   seq   = sim/tb_llama_top_seq.vhd    (the KV cache, 3 tokens, ATTN_INT = 2)
#   stub  = sim/tb_llama_top.vhd's own defaults (attention is the ramp stub)
# NRUNS is forced to 1: only run 0 is captured, every run starts from a reset,
# so runs 1..N-1 cost wall time and change nothing in the file.
set -uo pipefail
cd "$(dirname "$0")/../.."
CFG="${1:-real}"
OUT="${2:-}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
W="$SCRATCH/work"
rm -rf "$W"; mkdir -p "$W/run"

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
       rtl/matvec_int4.vhd rtl/sampler_stream.vhd rtl/llama_top.vhd
       sim/tb_llama_top.vhd"

case "$CFG" in
  real) G="-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex" ;;
  seq)  G="-gBLOCKS=4 -gATTN_INT=2 -gNTOK=3 -gC_REAL=true -gATTN_HD=64
           -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true" ;;
  stub) G="" ;;
  *) echo "unknown configuration $CFG (real|seq|stub)"; exit 2 ;;
esac
[ -z "$OUT" ] && OUT="$PWD/tools/ref9b/golden/llama_top_${CFG}.txt"

for f in $FILES; do
  if ! ghdl -a --std=08 -frelaxed --workdir="$W" "$f" >> "$W/analyze.log" 2>&1; then
    echo "DID NOT ANALYZE: $f"; sed -n 1,6p "$W/analyze.log"; exit 2
  fi
done
ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex" "$W/run/" 2>/dev/null

( cd "$W/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed --workdir=".." \
    tb_llama_top $G -gNRUNS=1 -gCAPTURE=cap.txt \
    --max-stack-alloc=0 --stop-time=900ms > run.log 2>&1 )
rc=$?
grep -a "RESULT:\|seam capture wrote" "$W/run/run.log" | sed 's/^.*(report note): //'
if [ ! -s "$W/run/cap.txt" ]; then
  echo "NO CAPTURE WAS WRITTEN (ghdl rc=$rc).  A run that died has captured "
  echo "nothing, and an empty file compares equal to another empty file."
  exit 3
fi
mkdir -p "$(dirname "$OUT")"
cp "$W/run/cap.txt" "$OUT"
echo "wrote $OUT ($(grep -ac '^SEAM' "$OUT") records)"
echo "scratch: $SCRATCH"
