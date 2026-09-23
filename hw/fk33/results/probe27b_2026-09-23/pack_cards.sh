#!/usr/bin/env bash
# Per-card 27B images (2026-09-23, plan Task 3), chained on the base pack.
# The base pack's .mv4i files are symlinked into each card dir so the packer
# KEEPs them (the 9B card images were made the same way); only the manifest
# and the placement are new.  Sentinel: PACK27_DONE.
set -u
REPO=/home/orencollaco/GitHub/llama.vhdl
GG=/mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf
BASE=/mnt/storage/llama-models/qwen38-27b-mv4i
BASE_PID=161586
cd "$REPO" || exit 9
# The base pack packed all 498 .mv4i files and refused at its own manifest
# (the 9B lm_head shape check, fixed in the packer since); the per-card packs
# only KEEP its files, so no base manifest is needed.
n=$(ls "$BASE"/*.mv4i | wc -l); echo "PACK27_BASE $n mv4i files"; [ "$n" = 498 ] || { echo "PACK27_ABORT expected 498 files"; exit 8; }
# card 0 has no lm_head, so the A-descriptor count (607, the full 27B program's max over its variants) is passed rather than counted.
# 16384: B and C index their arenas by the GLOBAL layer ordinal (descriptor word 3), so a card's arena spans the whole model
# (34,816 B/token, 78.7 MB of GDN state) and a 33/31 split leaves 20,679 tokens; 32768 does not fit (MEASURED 2026-09-23).
for spec in "card0-b0-32 0:32 --desc-arena-jobs 607" "card1-b33-63 33:63"; do
  set -- $spec; name=$1; range=$2; shift 2; EXTRA="$*"
  D=/mnt/storage/llama-models/qwen38-27b-$name
  mkdir -p "$D"
  for f in "$BASE"/*.mv4i; do ln -sf "$f" "$D/$(basename "$f")"; done
  echo "=== PACK27 $name blocks $range begin $(date -Is) ==="
  python3 tools/pack_model_fk33.py "$GG" "$D" --model QWEN38_27B --blocks "$range" \
    --stripe-lanes --stripe-all-segments --drop token_embd.weight \
    --card-maxpos 16384 --stripe-min-context 16384 $EXTRA > "$D/run.log" 2>&1
  rc=$?
  echo "PACK27_CARD $name rc=$rc manifest=$([ -f "$D/manifest.json" ] && echo yes || echo no)"
  grep -E '^\s*(stripe width|lane stripe|stack 0|stack 1|peak fill|KV|context|card_kv|hbm|weights)' "$D/run.log" | head -12 | sed "s/^/PACK27_LOG $name /"
  tail -3 "$D/run.log" | sed "s/^/PACK27_TAIL $name /"
  if [ -f "$D/manifest.json" ]; then
    python3 tools/pack_gdn_consts.py --shape 27b --gguf "$GG" --manifest "$D/manifest.json" --out "$D/gdn_const.bin" > "$D/gdn_const.log" 2>&1
    echo "PACK27_GDNCONST $name rc=$? $(tail -1 "$D/gdn_const.log" | cut -c1-120)"
  fi
done
echo "PACK27_DONE $(date -Is)"
