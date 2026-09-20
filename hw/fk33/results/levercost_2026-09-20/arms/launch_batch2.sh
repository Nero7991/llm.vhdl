#!/usr/bin/env bash
# TRACK LEVERCOST batch 2, run ON the BC-250.
#
#   apop_ctrl / apop_fast  re-drawn with set_clock_groups -asynchronous, the
#                          Intra Clock Table parsed out, the top-50 path
#                          distribution dumped, and a post-opt DCP written so
#                          no future timing question costs a synthesis.
#   cswp_off / cswp_on     attn_block at the card's 9B generics, SWEEP_PIPE
#                          off/on.  attn_block.vhd here is HEAD's COMMITTED
#                          copy (bc4156f), placed by the caller -- NOT the
#                          working tree, which TRACK CSWEEP has open again.
#
# A SEPARATE OUTPUT DIRECTORY, per the project's rule about naming scratch per
# run: batch 1's numbers must stay readable beside these.
set -u
cd /home/orencollaco/GitHub/llama.vhdl
export LC_OUTDIR=/home/labuser/levercost_ooc2
export LC_CAP=8G
# ORDER MATTERS: the two `attn_block` arms are small and answer a lever nobody
# has any number for, while the two `matvec_int4_desc_axi` re-draws are ~12 min
# each and only sharpen a bound that is already stated.  Cheap-and-new first,
# so a truncated batch still lands the new information.
export LC_ONLY="cswp_off cswp_on apop_ctrl apop_fast"
# Subsystem C at 9B, from rtl/fk33_llama_top.vhd's u_attn generic map (:7247)
# resolved against model_cfg_pkg's QWEN35_9B:
#   HEAD_DIM = SHAPE.attn_head_dim = 256
#   N_QH     = SHAPE.attn_q_heads  = 16
#   N_KVH    = SHAPE.attn_kv_heads = 4
#   LAYERS   = attn_layers(SHAPE)  = blocks 32 / attn_interval 4 = 8
#   POS_W    = clog2(C_MAXPOS+1)   = clog2(65537) = 17
#   KV_BLOCK = 32, N_ROT = 64, MANT_W = 16, CM_W = 8, EXP_W = 8,
#   NORM_LANES = 1, STRICT_PRODUCER = true (all passed literally at :7249-7250)
# attn_block's OWN defaults differ (LAYERS 8 happens to match, POS_W 16 does
# NOT), so passing them is load-bearing, not decoration.
export LC_CGEN="HEAD_DIM=256 N_QH=16 N_KVH=4 KV_BLOCK=32 N_ROT=64 LAYERS=8 POS_W=17 MANT_W=16 CM_W=8 EXP_W=8 NORM_LANES=1 STRICT_PRODUCER=true"
mkdir -p "$LC_OUTDIR"
ulimit -s unlimited
setsid nohup bash sim/ooc_levercost_run.sh > "$LC_OUTDIR/driver.log" 2>&1 < /dev/null &
echo "BATCH2_LAUNCHED_PID $!"
