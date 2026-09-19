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
# Usage:  bash tools/ref9b/capture_llama_top.sh {real|seq|stub|bconst|qkn|swg} [outfile]
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
#   bconst = sim/tb_llama_top_bconst.vhd  (real, 3 tokens, B on its real
#            inputs and the packed constants image; added 2026-09-18)
#   qkn    = sim/tb_llama_top_qkn.vhd     (real, 3 tokens, C on the model's
#            QK-norm gains from sim/llama_top_qkn_b4.hex; added 2026-09-18)
#   swg    = sim/tb_llama_top_swg.vhd     (real, 3 tokens, the REAL swiglu_mem
#            on OP_VEC_SWG via SWG_REAL; added 2026-09-19)
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
       rtl/gdn_conv_tap_mem.vhd rtl/gdn_exp_mem.vhd
       rtl/gdn_state_axi.vhd rtl/gdn_state_mem.vhd
       rtl/gdn_recur_pipe.vhd rtl/gdn_scalar.vhd rtl/gdn_silu.vhd
       rtl/gdn_y_emit.vhd rtl/imrope_pkg.vhd rtl/l2norm_rs.vhd
       rtl/llama_map_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/rmsnorm_bf.vhd
       rtl/rmsnorm_rs.vhd rtl/seq_desc_fetch.vhd rtl/seq_opdec.vhd
       rtl/seq_region_lock.vhd rtl/seq_vec_issue.vhd rtl/seq_vec_res.vhd
       rtl/stream_fifo.vhd sim/seq_tbl_pkg.vhd rtl/attn_recip.vhd
       rtl/attn_twiddle.vhd rtl/axi_rd_port.vhd rtl/gdn_emit_chain.vhd
       rtl/matvec_core.vhd rtl/weight_streamer.vhd sim/llama_sched_pkg.vhd
       rtl/attn_block.vhd rtl/attn_kv_axi.vhd rtl/gdn_block.vhd
       rtl/gdn_conv_w_mem.vhd
       rtl/gdn_state_store.vhd rtl/gdn_job_seq.vhd
       rtl/matvec_int4.vhd rtl/sampler_stream.vhd
       rtl/vec_mem.vhd rtl/rmsnorm_rs_mem.vhd rtl/rmsnorm_bf_mem.vhd
       rtl/swiglu_mem.vhd
       rtl/llama_top.vhd
       sim/tb_llama_top.vhd"

# `rtl/vec_mem.vhd` AND `rtl/rmsnorm_rs_mem.vhd` ADDED 2026-08-30 BY TRACK
# GWTWO, AND THE GATE HAD BEEN RED SINCE `47c9d9c` WITHOUT THEM.  TRACK RMSWIRE
# wired `rmsnorm_rs_mem` into `rtl/llama_top.vhd:2190`, and this list is
# HAND-MAINTAINED, so from that commit onward `llama_top` did not analyse:
#
#   rtl/llama_top.vhd:2190:27: unit "rmsnorm_rs_mem" not found in library "work"
#   DID NOT ANALYZE: rtl/llama_top.vhd
#   SEAMGATE FAIL -- the capture produced no seam records (rc=2).
#
# and `sim:seamgate_{real,stub,seq}` -- three GATE ROWS, not a private harness
# -- failed for every track on the box.  MEASURED by TRACK GWTWO against a
# pristine `git archive HEAD` tree at `8ff9010`, i.e. with no GWTWO change
# present, so it is not caused by anything that track did.
#
# THIS IS THE FOURTH CONSUMER OF A HAND-MAINTAINED CLOSURE TO BREAK THE SAME
# WAY.  TRACK RMSWIRE found and fixed three (`sim/mutate_llama_top_*.sh`) and
# recorded the lesson -- "`regress.sh` computes its own closure and stayed
# green throughout, so the gate structurally cannot catch this class" -- and
# then missed this one, which is the only one of the four that IS a gate row.
# `regress.sh` cannot help here either: it delegates to `seamgate.sh`, which
# delegates to this list, so its own closure logic never sees these files.
#
# The ordering is load bearing: `vec_mem` before `rmsnorm_rs_mem` (which
# instantiates three of them at :377/:381/:385) and both before `llama_top`.
#
# ADDED OUTSIDE TRACK GWTWO'S STATED OWNERSHIP, deliberately and flagged here
# so the dispatcher can reverse it: the alternative was to leave the shared
# gate red at HEAD, where the next track to run it cannot tell this failure
# apart from its own.
#
# `rtl/swiglu_mem.vhd` ADDED 2026-09-19 with the `swg` configuration: it is
# instantiated by rtl/llama_top.vhd's `gsr` arm (SWG_REAL), so llama_top does
# not analyse without it whatever configuration is being captured.  Ordering:
# after vec_mem (which it instantiates three times) and before llama_top.
#
# `rtl/gdn_conv_w_mem.vhd` ADDED 2026-09-18 BY TRACK G (the B constants gate
# rows), AND THE SAME THREE ROWS HAD BEEN RED SINCE e212f04 WITHOUT IT.  The
# B constants path's track A gave `gdn_state_store` a fourth phase whose conv
# weights live in a new memory, instantiated at rtl/gdn_state_store.vhd:798,
# and this list did not follow.  MEASURED by analysing `LIST_FILES=1`'s own
# output in order:
#
#   rtl/gdn_state_store.vhd:798:24: unit "gdn_conv_w_mem" not found in library "work"
#   DID NOT ANALYZE: rtl/gdn_state_store.vhd
#
# THE FIFTH CONSUMER OF THIS HAND-MAINTAINED CLOSURE TO BREAK THE SAME WAY,
# and the entry above, written after the fourth, did not prevent it -- an
# entry in a comment is not a check.  The ordering is load bearing again:
# `gdn_conv_w_mem` before `gdn_state_store`, which instantiates it.

# LIST_FILES=1 prints the analysis closure and exits, so tools/ref9b/
# golden_status.sh can ask "did any file this capture READ change?" without
# owning a second copy of the list.  Two copies of a file list is how a
# staleness check ends up blind to the one file that moved.
if [ "${LIST_FILES:-0}" = "1" ]; then
  echo $FILES sim/llama_top_w_b4_pool.hex sim/llama_top_const_b4.hex sim/llama_top_qkn_b4.hex
  exit 0
fi

# EVERY ROW CARRIES ITS GENERICS **AND** THE MATCHING bisect_scaled.py ARGS,
# because those two are one fact written twice and the second copy is where a
# gate goes quietly wrong.  `tools/ref9b/bisect_scaled.py` re-derives the plan
# from --blocks/--attn-int/--attn-hd and REFUSES a capture the plan does not
# describe (`check_against_capture`), so a drift in those three is caught -- but
# --norm is NOT checkable that way.  Guessing --norm wrong makes every norm seam
# read as a defect; that is first-bisect trap T5, already paid for once.  So the
# `B` string lives here, one line under the `G` string it must agree with, and
# `LIST_BISECT=1` is how tools/ref9b/seamgate.sh reads it instead of holding a
# second copy -- the same rule LIST_FILES=1 exists for.
#
# A FOURTH CONFIGURATION, `bconst`, ADDED 2026-09-18 (TRACK G).  It is `real`
# plus three tokens and subsystem B on the MODEL'S OWN INPUTS AND CONSTANTS:
# B_STATE_AXI (the tiered state store), B_SRC_REAL (taps, alpha, beta from the
# regions) and B_CONST_HBM (the conv weights, ssm_dt_bias, ssm_a and the
# ssm_norm weight loaded from sim/llama_top_const_b4.hex, the packed sim-shape
# image, by the store's fourth phase).  The generics are
# sim/tb_llama_top_bconst.vhd's, copied.  The `real`, `seq` and `stub` rows
# elaborate B_SRC_REAL = false and see m12 stand-ins; this is the row where B
# computes on what the model would give it, and the ONLY one whose R_Y
# depends on the constants image.
#
# ITS B MODEL NEEDS AN ARGUMENT bisect_scaled.py CANNOT TAKE.  The oracle for
# these constants is `tools/ref9b/gdn_oracle.py --b-const IMAGE.bin`, and
# bisect_scaled.py has no --b-const pass-through (its GO.predict call at
# bisect_scaled.py:359 does not carry one).  So the `B` string holds only what
# BOTH comparators accept -- bisect_scaled.py runs it with `--no-b` and models
# every seam but R_Y -- and the `O` string below holds the oracle-only part,
# which seamgate.sh appends when it runs gdn_oracle.py on the SAME capture for
# the R_Y seams.  gdn_oracle.py accepts the whole `B` string unchanged (its
# C-side and norm-side flags are declared there as accepted-and-ignored for
# exactly this reason).  `LIST_ORACLE=1` reads `O` the way `LIST_BISECT=1`
# reads `B`; an empty `O` means "one comparator, as before".
case "$CFG" in
  real) G="-gBLOCKS=4 -gATTN_INT=4 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex"
        B="--blocks 4 --attn-int 4 --attn-hd 16 --norm real
           --w-image sim/llama_top_w_b4_pool.hex" ;;
  bconst)
        G="-gBLOCKS=4 -gATTN_INT=4 -gNTOK=3 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex -gMAXPOS=8
           -gB_STATE_AXI=true -gB_SRC_REAL=true -gB_CONST_HBM=true
           -gB_CONST_IMAGE=llama_top_const_b4.hex"
        B="--blocks 4 --attn-int 4 --attn-hd 16 --norm real
           --w-image sim/llama_top_w_b4_pool.hex --b-src-real"
        O="--b-const sim/llama_top_const_b4.bin" ;;
  # A FIFTH CONFIGURATION, `qkn`, ADDED 2026-09-18 (TRACK F).  `real` plus
  # three tokens and subsystem C on the MODEL'S QK-NORM GAINS: C_QKN_IMAGE
  # names sim/llama_top_qkn_b4.hex (tools/gen_qkn_image.py at this shape,
  # blk.3's attn_q_norm/attn_k_norm sliced to 16 elements), which replaces
  # the `qkn_const` ramp the other four rows elaborate.  The generics are
  # sim/tb_llama_top_qkn.vhd's, copied.  ONE comparator: bisect_scaled.py
  # carries `--qkn-image` straight through to attn_oracle.py, which reads the
  # same file, so the `B` string holds everything and `O` is empty.  This is
  # the only row whose attention R_Y depends on the gain image; without
  # `--qkn-image` in `B` the ramp model judges an image machine and the
  # three attention seams FAIL (the attribution control seamgate.sh records).
  qkn)  G="-gBLOCKS=4 -gATTN_INT=4 -gNTOK=3 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex -gMAXPOS=8
           -gC_QKN_IMAGE=llama_top_qkn_b4.hex"
        B="--blocks 4 --attn-int 4 --attn-hd 16 --norm real
           --w-image sim/llama_top_w_b4_pool.hex
           --qkn-image sim/llama_top_qkn_b4.hex" ;;
  # A SIXTH CONFIGURATION, `swg`, ADDED 2026-09-19.  `real` plus three
  # tokens and the REAL SwiGLU on OP_VEC_SWG: SWG_REAL puts rtl/swiglu_mem.vhd
  # (Q12 silu(g)*u with rtl/bfp_pack.vhd's pack) behind llama_top's `gsr`
  # adapter in place of the `g*u / 2**MANT_W` stand-in every other row
  # elaborates.  The generics are sim/tb_llama_top_swg.vhd's, copied.  ONE
  # comparator: bisect_scaled.py's `--swg real` selects
  # vec_oracle.swg_real for the R_H seams, so the `B` string holds everything
  # and `O` is empty.  This is the only row whose R_H is SwiGLU; without
  # `--swg real` the stand-in model judges the real machine and the twelve
  # R_H seams FAIL (the attribution control seamgate.sh records).
  swg)  G="-gBLOCKS=4 -gATTN_INT=4 -gNTOK=3 -gC_REAL=true -gATTN_HD=16
           -gNORM_REAL=true -gNORM_ANCHOR=false
           -gW_IMAGE=llama_top_w_b4_pool.hex -gMAXPOS=8
           -gSWG_REAL=true"
        B="--blocks 4 --attn-int 4 --attn-hd 16 --norm real
           --w-image sim/llama_top_w_b4_pool.hex --swg real" ;;
  seq)  G="-gBLOCKS=4 -gATTN_INT=2 -gNTOK=3 -gC_REAL=true -gATTN_HD=64
           -gKV_BLOCK=16 -gN_ROT=16 -gMAXPOS=8 -gKV_AXI=true"
        B="--blocks 4 --attn-int 2 --attn-hd 64 --norm anchor
           --kv-block 16 --n-rot 16" ;;
  stub) G=""
        B="--blocks 4 --attn-int 4 --attn-hd 32 --norm anchor" ;;
  *) echo "unknown configuration $CFG (real|seq|stub|bconst|qkn|swg)"; exit 2 ;;
esac
if [ "${LIST_BISECT:-0}" = "1" ]; then
  echo $B
  exit 0
fi
if [ "${LIST_ORACLE:-0}" = "1" ]; then
  echo ${O:-}
  exit 0
fi
GSMP=""
[ "${SMP:-0}" = "1" ] && GSMP="-gSMP_EN=true"
[ -z "$OUT" ] && OUT="$PWD/tools/ref9b/golden/llama_top_${CFG}.txt"

for f in $FILES; do
  if ! ghdl -a --std=08 -frelaxed --workdir="$W" "$f" >> "$W/analyze.log" 2>&1; then
    echo "DID NOT ANALYZE: $f"; sed -n 1,6p "$W/analyze.log"; exit 2
  fi
done
ln -sfn "$PWD/sim/llama_top_w_b4_pool.hex" "$W/run/" 2>/dev/null
# The constants image `bconst` opens by bare name (B_CONST_IMAGE); harmless
# to the other three, which never open it.
ln -sfn "$PWD/sim/llama_top_const_b4.hex" "$W/run/" 2>/dev/null
# The QK-norm gain image `qkn` opens by bare name (C_QKN_IMAGE); likewise.
ln -sfn "$PWD/sim/llama_top_qkn_b4.hex" "$W/run/" 2>/dev/null

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
