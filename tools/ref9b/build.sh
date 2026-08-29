#!/usr/bin/env bash
# Build tools/ref9b/dump_llamacpp against a PREBUILT llama.cpp.  Nothing in
# that tree is written to: only its public headers and its shared libraries are
# used, so the tree llama-cpp-server runs from is never rebuilt or relinked.
#
# Same policy as tools/bfx/build.sh, and for the same reason.  The difference
# is the tree: bfx targets /mnt/storage/llama-dflash2-src because it needs the
# DFlash2 fork; this tool needs `qwen35` architecture support, which is present
# in ~/GitHub/llama.cpp.upstream (MEASURED: `qwen35` is in that build's
# libllama.so and the 9B BF16 GGUF loads and decodes under it).
set -euo pipefail

LLAMA_SRC="${LLAMA_SRC:-$HOME/GitHub/llama.cpp.upstream}"
LLAMA_BUILD="${LLAMA_BUILD:-$LLAMA_SRC/build}"
D="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$D/dump_llamacpp}"

for f in "$LLAMA_SRC/include/llama.h" "$LLAMA_SRC/ggml/include/ggml.h" \
         "$LLAMA_BUILD/bin/libllama.so"; do
  [[ -e "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

g++ -O2 -std=c++17 -Wall -Wextra \
    -I"$D" -I"$LLAMA_SRC/include" -I"$LLAMA_SRC/ggml/include" \
    "$D/dump_llamacpp.cpp" \
    -o "$OUT" \
    -L"$LLAMA_BUILD/bin" -lllama -lggml -lggml-base \
    -Wl,-rpath,"$LLAMA_BUILD/bin" -lm

echo "built $OUT"
