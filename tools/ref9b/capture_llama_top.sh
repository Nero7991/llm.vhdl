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
# Env:    SCRATCH=<dir>      keep the work directory
#         CAPTURE_REV=<sha>  stamp this revision in the provenance header, for
#                            a `git archive` scratch tree that has no .git
#         SMP=1           elaborate SMP_EN, so the capture also carries the
#                         LOGITS seam and the design's own argmax.
#
# WHY SMP IS A SWITCH AND NOT ALWAYS ON.  Every seam but one is snapshotted
# from the region file at a job's completion; the lm_head job has `dst =
# R_NONE` because no region can hold a vocabulary (at the 9B shape region_max
# is 12,288 against 248,320 rows), so LOGITS reaches the capture only through
# rtl/llama_top.vhd's FLG_TO_SMP stream, which exists only under SMP_EN.  With
# SMP=1 the capture gains two records per token (LOGITS, TOKEN) and the R_X
# landmark is unchanged -- the route is additive and reads nothing.  Left off
# by default so the committed goldens keep the record counts they have.
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

# LIST_FILES=1 prints the analysis closure and exits, so tools/ref9b/
# golden_status.sh can ask "did any file this capture READ change?" without
# owning a second copy of the list.  Two copies of a file list is how a
# staleness check ends up blind to the one file that moved.
if [ "${LIST_FILES:-0}" = "1" ]; then
  echo $FILES sim/llama_top_w_b4_pool.hex
  exit 0
fi

case "$CFG" in
  real) G="-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex" ;;
  seq)  G="-gBLOCKS=4 -gATTN_INT=2 -gNTOK=3 -gC_REAL=true -gATTN_HD=64
           -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true" ;;
  stub) G="" ;;
  *) echo "unknown configuration $CFG (real|seq|stub)"; exit 2 ;;
esac
GSMP=""
[ "${SMP:-0}" = "1" ] && GSMP="-gSMP_EN=true"
[ -z "$OUT" ] && OUT="$PWD/tools/ref9b/golden/llama_top_${CFG}.txt"

for f in $FILES; do
  if ! ghdl -a --std=08 -frelaxed --workdir="$W" "$f" >> "$W/analyze.log" 2>&1; then
    echo "DID NOT ANALYZE: $f"; sed -n 1,6p "$W/analyze.log"; exit 2
  fi
done
ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex" "$W/run/" 2>/dev/null

( cd "$W/run" && timeout -k 5 3600 ghdl -r --std=08 -frelaxed --workdir=".." \
    tb_llama_top $G $GSMP -gNRUNS=1 -gCAPTURE=cap.txt \
    --max-stack-alloc=0 --stop-time=900ms > run.log 2>&1 )
rc=$?
grep -a "RESULT:\|seam capture wrote\|logits capture:" "$W/run/run.log" | sed 's/^.*(report note): //'
if [ ! -s "$W/run/cap.txt" ]; then
  echo "NO CAPTURE WAS WRITTEN (ghdl rc=$rc).  A run that died has captured "
  echo "nothing, and an empty file compares equal to another empty file."
  exit 3
fi
mkdir -p "$(dirname "$OUT")"

# ---- PROVENANCE, and it is not decoration -------------------------------
# This script reads the WORKING TREE, not HEAD.  On a repository with
# concurrent tracks editing rtl/, a capture that disagrees with a committed
# golden says "another track has uncommitted edits" exactly as loudly as it
# says "the golden is stale" -- and TRACK CAPTURE lost an hour and published a
# wrong finding to that ambiguity on 2026-08-29, blaming a commit that was
# innocent.  Stamping the revision AND the dirtiness of the files that were
# actually read settles it in one line instead.
{
  echo "# captured by tools/ref9b/capture_llama_top.sh, configuration $CFG"
  # CAPTURE_REV exists because the honest way to capture at a revision on a
  # repository with concurrent tracks is `git archive <rev> | tar -x` into
  # scratch -- and a scratch extraction is not a git repository, so
  # `git rev-parse` there reports nothing.  Pass the rev you extracted.
  echo "# HEAD ${CAPTURE_REV:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown (not a git tree -- pass CAPTURE_REV)')}  SMP=${SMP:-0}"
  DIRTY="$(git status --porcelain -- rtl sim tools 2>/dev/null | grep -v '^??' | awk '{print $2}' | tr '\n' ' ')"
  if [ -n "$DIRTY" ]; then
    echo "# TREE WAS DIRTY when this was captured.  These tracked files under"
    echo "# rtl/, sim/ and tools/ differed from HEAD, so this capture is NOT a"
    echo "# capture of that commit:"
    echo "#   $DIRTY"
  else
    echo "# tree clean under rtl/, sim/ and tools/: this IS a capture of that commit"
  fi
} > "$OUT"
cat "$W/run/cap.txt" >> "$OUT"
echo "wrote $OUT ($(grep -ac '^SEAM' "$OUT") records)"
grep -a '^# HEAD\|^# TREE WAS DIRTY' "$OUT"
echo "scratch: $SCRATCH"
