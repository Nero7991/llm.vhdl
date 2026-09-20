#!/usr/bin/env bash
# fk33_chat.sh "question" [max_new]  -- ask the card one question, stream the answer.
#
# Renders the Qwen3.5 chat template (one user message, thinking off),
# tokenizes, runs the token program on the card, and prints tokens as the
# card produces them.  Assumes the card is configured, the weight image,
# gdn_const and the descriptor arena are loaded (fk33_load_weights.py load
# --verify; fk33ctl.py load <arena> --offset hbm.desc_arena_base), and that
# no other process holds /dev/xdma*.  The GDN state is zeroed and the
# sequence position reset before every question, so questions are
# independent (no multi-turn memory).
#
# Opens /dev/xdma* -- a human runs this, never a subagent.
set -euo pipefail
Q="${1:?usage: fk33_chat.sh \"question\" [max_new]}"
MAXNEW="${2:-256}"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
M="${FK33_MODEL_DIR:-/mnt/storage/llama-models/qwen35-9b-mv4i-noembd}"
EMB="${FK33_EMBED:-/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i}"
QTK="${FK33_QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
RUN="${FK33_RUNDIR:-$REPO/build_artifacts_tok/chat_run}"
mkdir -p "$RUN"
# The token program: generated once per run directory, verified on HBM each time.
if [[ ! -f "$RUN/token.dtbl" ]]; then
    python3 "$REPO/tools/gen_layer_program.py" --token --shape 9b --manifest "$M/manifest.json" \
        --x-exp 0 --d-table "$RUN/token.dtbl" --rel-file "$RUN/token.rel" \
        --arena-image "$RUN/token.arena" > "$RUN/gen.log" 2>&1
fi
ARENA=$(python3 -c "import json;print(hex(json.load(open('$M/manifest.json'))['hbm']['desc_arena_base']))")
python3 "$REPO/hw/fk33/host/fk33ctl.py" load "$RUN/token.arena" --offset "$ARENA" --verify > "$RUN/arena.log" 2>&1 \
    || { echo "arena load/verify failed, see $RUN/arena.log" >&2; exit 1; }
# Zero the GDN recurrent state (every layer), so this question starts clean.
GB=$(python3 -c "import json;h=json.load(open('$M/manifest.json'))['hbm'];print(hex(h['gdn_state_base']), h['gdn_state_bytes'])")
set -- $GB
if [[ ! -f "$RUN/gdn_zero.bin" || $(stat -c %s "$RUN/gdn_zero.bin") -ne $2 ]]; then head -c "$2" /dev/zero > "$RUN/gdn_zero.bin"; fi
python3 "$REPO/hw/fk33/host/fk33ctl.py" load "$RUN/gdn_zero.bin" --offset "$1" --verify > "$RUN/state.log" 2>&1 \
    || { echo "state zero failed, see $RUN/state.log" >&2; exit 1; }
exec "$REPO/server/run_prompt" --allow-hardware HOST --seq-reset --v2 \
    --dtbl "$RUN/token.dtbl" --rel "$RUN/token.rel" \
    --text "$Q" --qtk "$QTK" --stream --max-new "$MAXNEW" \
    --manifest "$M/manifest.json" --mv4i "$EMB" --quiet
