#!/usr/bin/env bash
# Build tools/bfx/gdn_probe against the PREBUILT llama.cpp in
# /mnt/storage/llama-dflash2-src/build.  Nothing in that tree is written to:
# only its public headers and its shared libraries are used, so the tree that
# llama-cpp-server runs from is never rebuilt, relinked or otherwise touched.
#
# The linked libraries are libllama and libggml* only.  common/ is deliberately
# NOT linked: it is a static-ish helper layer with its own arg parser that
# changes shape between llama.cpp revisions, and every API this tool needs is
# in the stable public llama.h / ggml-backend.h surface.
set -euo pipefail

LLAMA_SRC="${LLAMA_SRC:-/mnt/storage/llama-dflash2-src}"
LLAMA_BUILD="${LLAMA_BUILD:-$LLAMA_SRC/build}"
OUT="${OUT:-$(dirname "$0")/gdn_probe}"

for f in "$LLAMA_SRC/include/llama.h" "$LLAMA_SRC/ggml/include/ggml.h" \
         "$LLAMA_BUILD/bin/libllama.so"; do
  [[ -e "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

D="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# bfx_emit_chain.c is compiled as C, not as C++.  It #includes subsystem B's
# reference generators verbatim and those are C; letting g++ compile them would
# change overload resolution and integer promotion rules underneath a recipe
# whose whole point is exact integer behaviour.
gcc -O2 -std=c11 -Wall -Wextra -c "$D/bfx_emit_chain.c" -o "$TMP/bfx.o"

g++ -O2 -std=c++17 -Wall -Wextra \
    -I"$LLAMA_SRC/include" -I"$LLAMA_SRC/ggml/include" \
    "$D/gdn_probe.cpp" "$TMP/bfx.o" \
    -o "$OUT" \
    -L"$LLAMA_BUILD/bin" -lllama -lggml -lggml-base \
    -Wl,-rpath,"$LLAMA_BUILD/bin" -lm

echo "built $OUT"
