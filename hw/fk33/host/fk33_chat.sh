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
EMB="${FK33_EMBED:-/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i}"
QTK="${FK33_QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
RUN="${FK33_RUNDIR:-$REPO/build_artifacts_tok/chat_run}"
mkdir -p "$RUN"

# WHICH IMAGE IS ON THE CARD DECIDES WHICH MANIFEST WE MAY USE, AND THIS USED
# TO BE A HARDCODED DEFAULT.  MEASURED 2026-09-20, twice in one hour: this
# script defaulted to the flat image while the card held the lane-striped one,
# and the mismatch DESTROYED 35 weight objects.  Both manifests put the
# descriptor arena at 0x1ffadd000, so the flat descriptors overwrote the
# striped ones; and run_prompt programmed the flat kv_base into the KV seam
# register, so subsystem C wrote its records into the weight image.  The flat
# KV slot grid at 24 tokens predicts those 35 objects exactly, 0 missed and 0
# extra.  Before the KV base became a host-programmed register that same
# mistake only produced a wrong answer; now it costs the image.
#
# So: ask the CARD what it is holding, and refuse anything else.
PROBE="$REPO/hw/fk33/host/fk33_resident_image.py"
if [[ -n "${FK33_MODEL_DIR:-}" ]]; then
    M="$FK33_MODEL_DIR"
    if ! python3 "$PROBE" --check "$M/manifest.json" > "$RUN/resident.log" 2>&1; then
        cat "$RUN/resident.log" >&2
        echo "fk33_chat.sh: REFUSING to run.  FK33_MODEL_DIR does not describe" >&2
        echo "  the image on the card.  Driving it would corrupt the weights," >&2
        echo "  not merely give a wrong answer.  Load that image first with" >&2
        echo "  fk33_load_weights.py load <manifest> --verify, or unset" >&2
        echo "  FK33_MODEL_DIR to use whatever is resident." >&2
        exit 1
    fi
else
    # No preference stated: use what is actually loaded.
    mapfile -t RESIDENT < <(python3 "$PROBE" 2>"$RUN/resident.log") || true
    if [[ ${#RESIDENT[@]} -eq 0 ]]; then
        cat "$RUN/resident.log" >&2
        echo "fk33_chat.sh: no image this script knows about is on the card." >&2
        echo "  Load one with fk33_load_weights.py load <manifest> --verify." >&2
        exit 1
    fi
    M="${RESIDENT[0]}"
    if [[ ${#RESIDENT[@]} -gt 1 ]]; then
        echo "note       ${#RESIDENT[@]} known images place their weight pieces identically;" >&2
        echo "           using $M" >&2
        echo "           (they differ only in the GDN state and KV regions, which hold no" >&2
        echo "            file bytes to probe.  Set FK33_MODEL_DIR to be explicit.)" >&2
    fi
    echo "resident   $M  (probed on the card, not assumed)"
fi

# THE CACHED TOKEN PROGRAM BELONGS TO ONE MANIFEST.  Regenerating only when
# token.dtbl is absent reintroduces exactly the defect above by the back door:
# a run directory built against the flat manifest would be replayed against a
# striped image.  Key the cache on the manifest path.
if [[ ! -f "$RUN/manifest.used" ]] || [[ "$(cat "$RUN/manifest.used")" != "$M/manifest.json" ]]; then
    rm -f "$RUN/token.dtbl" "$RUN/token.rel" "$RUN/token.arena"
fi
# The token program: generated once per run directory, verified on HBM each time.
if [[ ! -f "$RUN/token.dtbl" ]]; then
    python3 "$REPO/tools/gen_layer_program.py" --token --shape 9b --manifest "$M/manifest.json" \
        --x-exp 0 --d-table "$RUN/token.dtbl" --rel-file "$RUN/token.rel" \
        --arena-image "$RUN/token.arena" > "$RUN/gen.log" 2>&1
    printf '%s\n' "$M/manifest.json" > "$RUN/manifest.used"
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
