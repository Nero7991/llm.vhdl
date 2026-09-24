# llm.vhdl web UI

A copy of the llama.cpp web UI (`tools/ui` of llama.cpp, upstream commit
`bdffafa5df64`, MIT, see `LICENSE.llama.cpp` and `README.llama.cpp.md`),
rebranded and served by `server/llmvhdl_server.py`, which answers its requests
on the FK33 cards.

## Use

```bash
make -C server run_prompt libqwen35chat.so
python3 server/llmvhdl_server.py            # two cards; --mode single for one
```

Then open `http://<host>:8000/`. The server needs both cards on a bitstream
with their images loaded (the same state `hw/fk33/host/fk33_chat2.sh` needs).

## What differs from upstream

- `APP_NAME` is `llm.vhdl`, the PWA description and the search page title say
  so, and the "server not reachable" splash names `llmvhdl_server.py` instead
  of `llama-server`.
- `tests/`, `docs/`, `.storybook/` and the llama.cpp CMake embedding
  (`CMakeLists.txt`, `embed.cpp`, `sources.cmake`) were not copied.
- `dist/` is committed, so the server runs without node.

## Rebuild

```bash
cd ui && npm ci && npm run build        # writes dist/
```

`node_modules` is not committed (about 700 MB). `.npmrc` keeps upstream's
`ignore-scripts=true` and `min-release-age=7`.

## What the server does not do

Greedy decoding only (the card returns its argmax, so the sampling sliders are
ignored), one request at a time, and every turn re-prefills the whole
conversation (about 0.17 s per token on the pair). No images, audio or tools.
