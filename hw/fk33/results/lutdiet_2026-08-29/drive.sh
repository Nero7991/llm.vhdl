#!/usr/bin/env bash
# TRACK LUTDIET run driver.  ONE Vivado at a time, deliberately.
set -u
R=/home/orencollaco/GitHub/llama.vhdl/sim/ooc_lutdiet_run.sh
OUT=/mnt/storage/lutdiet/out
RTL=/mnt/storage/lutdiet/rtl_v
mkdir -p $OUT
log() { echo "[$(date -Is)] $*" >> $OUT/DRIVE.log; }
run() { local tag=$1; shift; log "begin $tag"; bash $R "$tag" "$@" >> $OUT/DRIVE.log 2>&1; log "end $tag rc=$?"; }

log "START pinned=$(cat /mnt/storage/lutdiet/PINNED_SHA)"

# 1-3.  Does the LUT scale with the FLAT PORT'S WIDTH?  N is the only thing
# moving; LANES, the arithmetic and the schedule are fixed.
for NN in 256 1024 4096; do
  LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
    run rms_n$NN rmsnorm_rs $OUT $RTL N=$NN LANES=4
done

# 4.  The memory-backed unit at the real D-vec shape.
LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  run mem_n4096 rmsnorm_rs_mem $OUT $RTL N=4096 LANES=4

# 5.  The SAME-CONTRACT flat control: flat unit + the flat vector storage its
# parent must supply, with the identical streaming port list.
LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  run flat_n4096 lutdiet_rms_flat $OUT $RTL N=4096 LANES=4

# 6.  C: is the same signature in attn_block?  COMPOSE ran flatten=none on B only.
LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  run attn_none attn_block $OUT $RTL HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8

# 7.  B: attribute the 360,661 LUT of glue to the SIGNALS that carry it.
LUTDIET_NOOPT=1 LUTDIET_FLATTEN=none LUTDIET_CENSUS=1 \
  run gdn_none gdn_block $OUT $RTL

log "ALLDONE"
