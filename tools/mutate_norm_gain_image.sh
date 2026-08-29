#!/usr/bin/env bash
# Teeth for the OTHER half of the gain path: the GENERATOR, and the `--gguf`
# arm of tools/norm_w_bisect.py that re-derives the gains from the model.
#
# sim/mutate_normw.sh mutates the RTL and judges it with the committed image.
# That leaves one hole open, and it is the m7-mutant hole this project already
# has on record: if the IMAGE is wrong in a way the RTL faithfully reproduces,
# the seam oracle reads the image, agrees with the machine, and reports 9/9.
# `--gguf` is what closes it -- it re-derives the gains from the GGUF with a
# second implementation of the reduction, so the image is under test too.
#
# Every mutation here changes what the generator WRITES.  A row is killed if
# `IMAGE vs MODEL` is non-zero.  Rows that need an RTL run to make their point
# say so.
#
# Usage:  bash tools/mutate_norm_gain_image.sh [scratch-dir]
# Env:    GGUF=<path>
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SCRATCH="${1:-$(mktemp -d)}"
GGUF="${GGUF:-/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf}"
CAP="${CAP:-$SCRATCH/cap_normw.txt}"
mkdir -p "$SCRATCH"

gen () {                             # $1 = tag -> prints its private dir
  local tag d
  tag="$1"
  d="$SCRATCH/g_$tag"
  rm -rf "$d"; mkdir -p "$d"
  cp "$REPO/tools/gen_llama_top_weights.py" "$d/gen.py"
  cp "$REPO/tools/pack_int4.py" "$d/pack_int4.py"
  echo "$d"
}

judge () {                           # $1 = tag, $2 = image
  local out
  out=""
  out=$(python3 "$REPO/tools/norm_w_bisect.py" "$CAP" --gains "$2" \
        --gguf "$GGUF" 2>&1 | grep -E "^# IMAGE vs MODEL|^# [0-9]+ of [0-9]+ R_XN")
  echo "$out" | tr '\n' '|'
}

if [ ! -s "$CAP" ]; then
  echo "capturing the clean run first (needed to judge the seams)"
  SCRATCH="$SCRATCH/cap" bash "$REPO/tools/capture_normw.sh" "$CAP" >/dev/null 2>&1
fi

echo "== the gain GENERATOR's mutation table =="
echo "   killed = 'IMAGE vs MODEL' non-zero.  The R_XN line is printed too so"
echo "   a row that the image-vs-model arm catches and the seam arm does NOT"
echo "   is visible as such -- that difference is the point of this file."
echo

for m in base sum wrongmap revfile wexp13; do
  d=$(gen "$m")
  case "$m" in
    base)    : ;;
    sum)     python3 - "$d/gen.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
o="    return w.reshape(n, K // n).mean(axis=1)"
n="    return w.reshape(n, K // n).sum(axis=1)"
assert o in s; open(p,'w').write(s.replace(o,n,1))
PY
             ;;
    wrongmap) python3 - "$d/gen.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
o='        emit(OP_NORM, tens=f"blk.{b}.post_attention_norm.weight")'
n='        emit(OP_NORM, tens=f"blk.{b}.attn_norm.weight")'
assert o in s; open(p,'w').write(s.replace(o,n,1))
PY
             ;;
    revfile) python3 - "$d/gen.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
o="                for v in q:"
n="                for v in q[::-1]:"
assert o in s; open(p,'w').write(s.replace(o,n,1))
PY
             ;;
    wexp13)  : ;;
  esac
  extra=""
  [ "$m" = "wexp13" ] && extra="--norm-w-exp 13"
  # shellcheck disable=SC2086
  if ! python3 "$d/gen.py" --gguf "$GGUF" --blocks 4 --attn-interval 4 \
        --reduce pool --out "$d/w.hex" --norm-out "$d/nw.hex" $extra \
        > "$d/gen.log" 2>&1; then
    printf "%-9s GENERATOR REFUSED: %s\n" "$m" "$(tail -1 "$d/gen.log")"
    continue
  fi
  if [ "$m" = "wexp13" ]; then
    v=$(python3 "$REPO/tools/norm_w_bisect.py" "$CAP" --gains "$d/nw.hex" \
        --gguf "$GGUF" --norm-w-exp 13 2>&1 \
        | grep -E "^# IMAGE vs MODEL|^# [0-9]+ of [0-9]+ R_XN" | tr '\n' '|')
  else
    v=$(judge "$m" "$d/nw.hex")
  fi
  printf "%-9s %s\n" "$m" "$v"
done
echo
echo "scratch: $SCRATCH"
