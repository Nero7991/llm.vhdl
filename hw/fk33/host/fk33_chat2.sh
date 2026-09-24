#!/usr/bin/env bash
# fk33_chat2.sh "question" [max_new] [run_prompt args...]  -- ask a model split across TWO cards.
#   Anything after max_new goes to run_prompt verbatim (--reference, --ids-out).
#
# 2026-09-21, docs/superpowers/specs/2026-09-21-two-card-pipeline-design.md.
# Card 0 (/dev/xdma0_*) holds blocks 0..k-1 and ends with the residual in
# R_X; card 1 (/dev/xdma1_*) holds blocks k..N-1 plus the LM head.  The host
# carries R_X and its block exponent between them (server/pl_pipeline.c).
#
# Each card is prepared exactly as fk33_chat.sh prepares one: the image
# record on the card decides the manifest (never assumed), the token program
# is generated per card from that manifest with the card's block range, the
# descriptor arena is loaded and verified, and the GDN state is zeroed.  The
# block range is read off each manifest's own file list, not typed here.
#
# Both cards must carry a bitstream with FK33_CAP_XEXP_OUT (fk33ctl.py seam
# shows caps bit 6); pl_read_xout refuses an older one.
#
# Opens /dev/xdma* -- a human runs this, never a subagent.
set -euo pipefail
Q="${1:?usage: fk33_chat2.sh \"question\" [max_new]}"
MAXNEW="${2:-256}"
EXTRA=("${@:3}")   # captured HERE: a later `set -- $GB` replaces the positional parameters (MEASURED 2026-09-23: "${@:3}" at the exec was empty)
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
EMB="${FK33_EMBED:-/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i}"
QTK="${FK33_QTK:-$REPO/build_artifacts_tok/qwen35_9b.qtk}"
RUNBASE="${FK33_RUNDIR:-$REPO/build_artifacts_tok/chat2_run}"
IMGFP="$REPO/hw/fk33/host/fk33_imgfp.py"
CTL="$REPO/hw/fk33/host/fk33ctl.py"

# The block range a manifest holds, from its own tensors.  Prints "lo:hi".
blocks_of() {
    python3 - "$1" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
b = sorted({int(x.group(1)) for e in m["files"]
            for x in [re.match(r"blk\.(\d+)\.", e.get("tensor") or "")] if x})
if not b: raise SystemExit("no blocks in " + sys.argv[1])
if b != list(range(b[0], b[-1] + 1)): raise SystemExit("blocks are not contiguous in " + sys.argv[1])
print("%d:%d" % (b[0], b[-1]))
PY
}
has_head() { python3 -c "import json,sys; print(any(e.get('tensor')=='output.weight' for e in json.load(open(sys.argv[1]))['files']))" "$1"; }

# THE NORM GAIN ROWS (2026-09-23, plan Task 2).  A card built with NORM_HBM
# (build 19 on) reads each RMSNorm gain row from the constants image at
# hbm.norm_const_offset; an image packed before that has no rows there, and the
# card would normalise with whatever bytes sit above the GDN layers, silently.
# The bitstream does not yet announce NORM_HBM in CAPS_FLAGS, so the host
# cannot tell the two apart and the IMAGE must carry the rows.  Images with
# rows run on build 18 too (it ignores them), so the `-nh` images are safe on
# either.  FK33_ALLOW_NO_NORM_ROWS=1 is for a build-18 card with an old image,
# and ONLY that.
norm_rows_ok() {
    python3 -c "import json,sys; sys.exit(0 if 'norm_const_rows' in json.load(open(sys.argv[1]))['hbm'] else 1)" "$1"
}
declare -a M RUN RANGE DEV
# WHICH NODE IS WHICH CARD (2026-09-24).  The xdma node numbers follow the
# order the driver binds the endpoints, and MEASURED that day they SWAP on
# every JTAG reload of either card.  So the roles are assigned from the image
# each node holds: card 0 is the node whose image has no LM head.  Nodes are
# only a transport; the image record is the identity.
DEV=(/dev/xdma0 /dev/xdma1)
FIRSTRES=$(FK33_USER=/dev/xdma0_user FK33_H2C=/dev/xdma0_h2c_0 FK33_C2H=/dev/xdma0_c2h_0 python3 "$IMGFP" which 2>/dev/null) || FIRSTRES=""
if [[ -n "$FIRSTRES" && "$(has_head "$FIRSTRES")" == "True" ]]; then
    DEV=(/dev/xdma1 /dev/xdma0)
    echo "nodes      xdma1 holds the first half and xdma0 the second (they swap on reload); using them in that order"
fi
for i in 0 1; do
    export FK33_USER=${DEV[$i]}_user FK33_H2C=${DEV[$i]}_h2c_0 FK33_C2H=${DEV[$i]}_c2h_0
    RUN[$i]="$RUNBASE/card$i"; mkdir -p "${RUN[$i]}"
    # WHICH IMAGE IS ON THIS CARD DECIDES WHICH MANIFEST WE MAY USE.
    RES=$(python3 "$IMGFP" which 2>"${RUN[$i]}/imgfp.log") || RES=""
    if [[ -z "$RES" ]]; then
        cat "${RUN[$i]}/imgfp.log" >&2
        echo "fk33_chat2.sh: card $i carries no image record; load it with" >&2
        echo "  FK33_H2C=$FK33_H2C FK33_C2H=$FK33_C2H fk33_load_weights.py load <manifest> --verify" >&2
        exit 1
    fi
    M[$i]="$(dirname "$RES")"
    RANGE[$i]=$(blocks_of "${M[$i]}/manifest.json")
    if ! norm_rows_ok "${M[$i]}/manifest.json"; then
        if [[ "${FK33_ALLOW_NO_NORM_ROWS:-0}" == 1 ]]; then
            echo "fk33_chat2.sh: WARNING ${M[$i]}/manifest.json declares no norm gain rows; running only because FK33_ALLOW_NO_NORM_ROWS=1 (build 18 or older ONLY)" >&2
        else
            echo "fk33_chat2.sh: REFUSING: ${M[$i]}/manifest.json declares no norm gain rows (hbm.norm_const_rows).  A NORM_HBM card (build 19 on) would read wrong gains silently.  Load the -nh image, or set FK33_ALLOW_NO_NORM_ROWS=1 on a build-18 card." >&2
            exit 1
        fi
    fi
    echo "card $i     ${DEV[$i]}  ${M[$i]}  blocks ${RANGE[$i]}  (image record on the card, not assumed)"
done
[[ "$(has_head "${M[0]}/manifest.json")" == "False" ]] || { echo "fk33_chat2.sh: card 0's image carries the LM head; it must be the headless half" >&2; exit 1; }
[[ "$(has_head "${M[1]}/manifest.json")" == "True"  ]] || { echo "fk33_chat2.sh: card 1's image has no LM head" >&2; exit 1; }
[[ "${RANGE[0]#*:}" -lt "${RANGE[1]%:*}" ]] || { echo "fk33_chat2.sh: block ranges ${RANGE[0]} and ${RANGE[1]} are not card 0 below card 1" >&2; exit 1; }

for i in 0 1; do
    export FK33_USER=${DEV[$i]}_user FK33_H2C=${DEV[$i]}_h2c_0 FK33_C2H=${DEV[$i]}_c2h_0
    R="${RUN[$i]}"; MAN="${M[$i]}/manifest.json"
    # THE CACHED TOKEN PROGRAM BELONGS TO ONE MANIFEST AND ONE GENERATOR.
    # The generator key was added 2026-09-23: that day a norm's `const_base`
    # became its gain ROW (plan Task 2), and a program cached by the older
    # generator names the BLOCK there, which a card with the row-indexed RTL
    # would read as the wrong gain, silently.
    # FK33_PAD_NORMS=0 (2026-09-24): no pad norms.  Correct ONLY on a bitstream
    # that selects the gain by the descriptor's row (build 19 on, NORM_HBM); on
    # build 18 or older it reproduces the counter bug.  Part of the cache key.
    PADN="${FK33_PAD_NORMS:-1}"
    GENV="padnorms-v1 pad=$PADN $(sha256sum "$REPO/tools/gen_layer_program.py" | cut -c1-16)"
    if [[ ! -f "$R/manifest.used" ]] || [[ "$(cat "$R/manifest.used")" != "$MAN" ]] || [[ ! -f "$R/pad.used" ]] || [[ "$(cat "$R/pad.used")" != "$GENV" ]]; then
        rm -f "$R/token.dtbl" "$R/token.rel" "$R/token.arena"
    fi
    if [[ ! -f "$R/token.dtbl" ]]; then
        HEAD=(); [[ $i -eq 0 ]] && HEAD=(--no-lmhead)
        # THE NORM GAIN TABLE IS INDEXED BY A PER-TOKEN NORM COUNTER, not by
        # the block (rtl/llama_top.vhd, NORM_W_IMAGE: "one entry per
        # OP_VEC_NORM of the token, in SCHEDULE ORDER").  MEASURED 2026-09-23:
        # card 1's first norm served block 0's gain and the pair diverged from
        # the single card at position 0/7/28; with 2*lo throwaway norms ahead
        # of block lo it reproduces the single card bit for bit.  See
        # docs/debugging/2026-09-23_the-norm-gain-is-indexed-by-a-per-token-counter.md
        LO="${RANGE[$i]%:*}"; PAD=(); [[ "$LO" -gt 0 && "$PADN" == 1 ]] && PAD=(--pad-norms $((2 * LO)))
        python3 "$REPO/tools/gen_layer_program.py" --token --shape 9b --manifest "$MAN" \
            --blocks-range "${RANGE[$i]}" "${HEAD[@]}" "${PAD[@]}" \
            --x-exp 0 --d-table "$R/token.dtbl" --rel-file "$R/token.rel" \
            --arena-image "$R/token.arena" > "$R/gen.log" 2>&1
        printf '%s\n' "$MAN" > "$R/manifest.used"; printf '%s\n' "$GENV" > "$R/pad.used"
    fi
    ARENA=$(python3 -c "import json;print(hex(json.load(open('$MAN'))['hbm']['desc_arena_base']))")
    python3 "$CTL" load "$R/token.arena" --offset "$ARENA" --verify > "$R/arena.log" 2>&1 \
        || { echo "card $i: arena load/verify failed, see $R/arena.log" >&2; exit 1; }
    GB=$(python3 -c "import json;h=json.load(open('$MAN'))['hbm'];print(hex(h['gdn_state_base']), h['gdn_state_bytes'])")
    set -- $GB
    if [[ ! -f "$R/gdn_zero.bin" || $(stat -c %s "$R/gdn_zero.bin") -ne $2 ]]; then head -c "$2" /dev/zero > "$R/gdn_zero.bin"; fi
    python3 "$CTL" load "$R/gdn_zero.bin" --offset "$1" --verify > "$R/state.log" 2>&1 \
        || { echo "card $i: state zero failed, see $R/state.log" >&2; exit 1; }
done
unset FK33_USER FK33_H2C FK33_C2H   # run_prompt names its own devices

# FK33_PROMPT_IDS (2026-09-24, fk33_ctxtest.sh): feed a token-id file instead
# of templating the question text.  A full-context prompt is ~65k tokens, far
# past what an argv string can hold, and a context test wants exact ids.
if [[ -n "${FK33_PROMPT_IDS:-}" ]]; then QARGS=(--prompt "$FK33_PROMPT_IDS" --qtk "$QTK"); else QARGS=(--text "$Q" --qtk "$QTK"); fi
exec "$REPO/server/run_prompt" --allow-hardware HOST --seq-reset --v2 \
    --dtbl "${RUN[0]}/token.dtbl" --rel "${RUN[0]}/token.rel" \
    --dtbl2 "${RUN[1]}/token.dtbl" --rel2 "${RUN[1]}/token.rel" \
    --manifest "${M[0]}/manifest.json" --manifest2 "${M[1]}/manifest.json" --dev "${DEV[0]}" --dev2 "${DEV[1]}" \
    "${QARGS[@]}" --stream --max-new "$MAXNEW" \
    --mv4i "$EMB" --quiet "${EXTRA[@]}"
