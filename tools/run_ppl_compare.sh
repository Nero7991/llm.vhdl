#!/usr/bin/env bash
# Perplexity comparison for subsystem A's weight format.
#
# Measures a DIFFERENCE, not an absolute.  The round-tripped models have to be
# stored in some format, and that storage contributes its own error, so:
#
#   source   Qwen3.8-27B-Q4_K_M as shipped        -- context only
#   control  dequantize -> Q8_0                   -- isolates the storage error
#   A        dequantize -> A format -> Q8_0       -- the measurement
#
# A's true cost is ppl(A) - ppl(control).  Quoting ppl(A) against the source
# would charge subsystem A for the Q8_0 requantization as well, which is not
# its to pay.  (Measured beforehand: the Q8_0 step costs 0.53% relative weight
# error on the Q4_K tensors and exactly 0.000% on the ones already stored Q8_0,
# against A's ~8%, so the control is expected to land very close to the source.)
#
# IDENTICAL settings across all three runs, and deliberately NOT the settings
# llama-cpp-server uses: the server runs -ctk q8_0 -ctv q8_0, and a quantized KV
# cache adds its own error that would be indistinguishable from the weight error
# being measured here.  KV cache is left at full precision.
set -euo pipefail
BIN=/mnt/storage/llama-dflash2-src/build/bin/llama-perplexity
DATA=/mnt/storage/ppl-data/wikitext-2-raw/wiki.test.raw
OUT=/mnt/storage/ppl-data/results
CHUNKS="${PPL_CHUNKS:-200}"
CTX="${PPL_CTX:-512}"
mkdir -p "$OUT"

run() {
  local tag="$1" model="$2"
  if [[ ! -f "$model" ]]; then echo "SKIP $tag: $model missing"; return 0; fi
  echo "======== $tag ========"
  "$BIN" -m "$model" -f "$DATA" -c "$CTX" --chunks "$CHUNKS" \
      -ngl 99 -fa on --seed 1234 2>&1 | tee "$OUT/ppl_${tag}.log" \
    | grep -E "Final estimate|ETA|^perplexity: [0-9]" | tail -3
}

# The GPUs must be free before this runs: llama-cpp-server holds ~37 GB of the
# 48 GB, and a 27 GB model will not fit alongside it.  Stopping it needs root,
# which this script does not have, so it CHECKS rather than assumes -- silently
# falling back to partial offload would change the comparison conditions midway
# and the three runs would no longer be comparable.
#   sudo systemctl stop llama-cpp-server      # before
#   sudo systemctl start llama-cpp-server     # after
used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -rn | head -1)
if (( used > 2000 )); then
  echo "ABORT: ${used} MiB already in use on a GPU. Stop llama-cpp-server first:"
  echo "  sudo systemctl stop llama-cpp-server"
  exit 1
fi

# Which runs to do, so source/control can be measured while the A model is
# still being written.  This is not a convenience: the A file EXISTS from the
# moment its build starts, so a plain -f existence check would happily feed a
# half-written GGUF to llama-perplexity and produce a number that looks real.
# Name the tags you want explicitly.
WANT="${*:-source control A}"
want() { [[ " $WANT " == *" $1 "* ]]; }

want source  && run source  /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf
want control && run control /mnt/storage/ppl-data/qwen27b-control.gguf
want A       && run A       /mnt/storage/ppl-data/qwen27b-A.gguf

echo "======== summary ========"
for f in "$OUT"/ppl_*.log; do
  printf "%-28s %s\n" "$(basename "$f")" \
    "$(grep -oE 'Final estimate: PPL = [0-9.]+ \+/- [0-9.]+' "$f" | tail -1)"
done
