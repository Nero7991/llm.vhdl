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
EXTRA=("${@:3}")   # captured HERE: a later `set -- $GB` replaces the positional parameters (MEASURED 2026-09-23: "${@:3}" at the exec was empty)
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
#
# THERE ARE TWO WAYS TO ASK AND THEY COVER DIFFERENT GROUND.
#
#   fk33_imgfp.py    reads the 512-byte IMAGE RECORD that
#                    `fk33_load_weights.py load` writes into the descriptor
#                    arena's reserved tail.  It carries the whole PLACEMENT:
#                    the region block AND a fingerprint over every piece
#                    address.  It is the authority, and it is the only thing
#                    that separates the two striped images, which place every
#                    weight piece identically and differ only in the GDN state
#                    and KV regions -- the regions that hold no file bytes and
#                    that `kv_base` lives in.  MEASURED: their fingerprints are
#                    2431269a... and 7f9e57e3...
#   fk33_resident_image.py  reads a few hundred BYTES at addresses a candidate
#                    manifest claims.  It needs nothing to have been recorded,
#                    so it still works on a card loaded before 2026-09-20, and
#                    it is the fallback below.
#
# The record wins where it exists.  Where it does not, the byte probe must
# identify EXACTLY ONE image or this refuses: an ambiguous probe is precisely
# the striped pair, and choosing between them by position in a list is how a
# wrong kv_base gets programmed.
PROBE="$REPO/hw/fk33/host/fk33_resident_image.py"
IMGFP="$REPO/hw/fk33/host/fk33_imgfp.py"
RESIDENT_MANIFEST=$(python3 "$IMGFP" which 2>"$RUN/imgfp.log") || RESIDENT_MANIFEST=""

if [[ -n "${FK33_MODEL_DIR:-}" ]]; then
    M="$FK33_MODEL_DIR"
    if [[ -n "$RESIDENT_MANIFEST" ]]; then
        if ! python3 "$IMGFP" check "$M/manifest.json" > "$RUN/resident.log" 2>&1; then
            cat "$RUN/resident.log" >&2
            echo "fk33_chat.sh: REFUSING to run." >&2
            echo "  resident : $RESIDENT_MANIFEST" >&2
            echo "  requested: $M/manifest.json" >&2
            echo "  Driving this manifest would not merely give a wrong answer:" >&2
            echo "  subsystem C's KV base is a register this host programs, and one" >&2
            echo "  GO with the wrong one writes KV records into the weight image" >&2
            echo "  (MEASURED 2026-09-20, 35 objects)." >&2
            echo "  To use it, load it:  fk33_load_weights.py load $M/manifest.json --verify" >&2
            echo "  To use what is there, unset FK33_MODEL_DIR." >&2
            exit 1
        fi
        echo "resident   $M  (image record on the card, not assumed)"
    elif ! python3 "$PROBE" --check "$M/manifest.json" > "$RUN/resident.log" 2>&1; then
        cat "$RUN/resident.log" >&2
        echo "fk33_chat.sh: REFUSING to run.  FK33_MODEL_DIR does not describe" >&2
        echo "  the image on the card.  Driving it would corrupt the weights," >&2
        echo "  not merely give a wrong answer.  Load that image first with" >&2
        echo "  fk33_load_weights.py load <manifest> --verify, or unset" >&2
        echo "  FK33_MODEL_DIR to use whatever is resident." >&2
        exit 1
    else
        echo "resident   $M  (byte probe; this card carries NO image record, so" >&2
        echo "           the GDN state and KV regions were NOT checked.  Run" >&2
        echo "           fk33_load_weights.py verify <manifest> and then" >&2
        echo "           fk33_imgfp.py write <manifest> to make it authoritative.)" >&2
    fi
elif [[ -n "$RESIDENT_MANIFEST" ]]; then
    # The record names its own manifest, so there is nothing to choose.
    M="$(dirname "$RESIDENT_MANIFEST")"
    echo "resident   $M  (image record on the card, not assumed)"
else
    # NO RECORD.  Fall back to the byte probe, and refuse an ambiguous answer.
    cat "$RUN/imgfp.log" >&2
    mapfile -t RESIDENT < <(python3 "$PROBE" 2>"$RUN/resident.log") || true
    if [[ ${#RESIDENT[@]} -eq 0 ]]; then
        cat "$RUN/resident.log" >&2
        echo "fk33_chat.sh: no image this script knows about is on the card." >&2
        echo "  Load one with fk33_load_weights.py load <manifest> --verify." >&2
        exit 1
    fi
    if [[ ${#RESIDENT[@]} -gt 1 ]]; then
        echo "fk33_chat.sh: REFUSING to run.  ${#RESIDENT[@]} known images place" >&2
        echo "  their weight pieces identically and this card carries no image" >&2
        echo "  record, so the byte probe cannot tell them apart:" >&2
        printf '    %s\n' "${RESIDENT[@]}" >&2
        echo "  They differ only in the GDN state and KV regions -- which is" >&2
        echo "  exactly where a wrong choice writes over the weights.  Either" >&2
        echo "  reload the image (fk33_load_weights.py load <manifest> --verify," >&2
        echo "  which writes the record), or state it:" >&2
        echo "    fk33_load_weights.py verify <manifest>   # prove which one it is" >&2
        echo "    fk33_imgfp.py write <manifest>           # then record it" >&2
        exit 1
    fi
    M="${RESIDENT[0]}"
    echo "resident   $M  (byte probe; this card carries NO image record, so the" >&2
    echo "           GDN state and KV regions were NOT checked.  Run" >&2
    echo "           fk33_load_weights.py verify <manifest> and then" >&2
    echo "           fk33_imgfp.py write <manifest> to make it authoritative.)" >&2
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
    --manifest "$M/manifest.json" --mv4i "$EMB" --quiet "${EXTRA[@]}"
