# llama.vhdl OpenAI-compatible server

> **2026-09-24: the web UI on the real cards is `llmvhdl_server.py`, not this
> binary.** `python3 server/llmvhdl_server.py` serves the llama.cpp web UI
> copied into `ui/` on port 8000 and answers each chat on the two FK33s through
> `hw/fk33/host/fk33_chat2.sh` (MEASURED: coherent multi-turn answers at
> 3.2 tokens/s decode). It reuses this directory's chat template and tokenizer
> via `make libqwen35chat.so`, and `run_prompt --ids-stream`. The notes below
> about `llama_server` running only against a simulated card still describe
> `llama_server`.

A zero-dependency C++ HTTP server. **Two models live in this one binary and
they do not share a code path.**

| `--model` | what it serves | backend |
|---|---|---|
| `stories260k` (default) | the fixed-point stories260K model, token-identical to the AXU3EG VHDL engine at greedy | CPU (`ref/run_fx.c`), or the AXU3EG PL with `--pl` |
| `qwen35` | Qwen3.5-9B through the **FK33 host seam v2** | a **simulated** card, or the real transport on files |

No Python, no external libraries: libstdc++ + POSIX sockets + libc, and it
cross-compiles static for aarch64.

---

## READ THIS BEFORE RUNNING `--model qwen35`

**The tokens it produces are not inference.** There is no bitstream that
contains a transformer (the composed FK33 design does not route, OI-12), and
`rtl/llama_top.vhd:133-134` says in its own words that there is no sampler and
no lm_head output. The only card backends here are a simulation and an ordinary
file, and neither runs a transformer. On top of that, no whole-model 9B numeric
reference exists in this repository (backlog item 12), so nothing here could
tell a right token from a wrong one even if one arrived.

The server says so in its startup banner, in `/v1/models`'s `description`
field, and in a `pl_backend` warning on every open.

**What IS real and checked:**

- the **Qwen3.5 chat template** (`qwen35_chat.c`), byte-for-byte against Jinja2
  evaluating the model's own template, 2,037 of 2,037 cases;
- the **tokenizer** (`qwen35_tok.c`), bit-exact against llama.cpp over 53,409
  strings, all 248,320 ids and 1.1M codepoints, and re-confirmed here on the
  rendered prompts;
- the **seam**: byte layouts, strides, polling discipline, KV position
  bookkeeping, and every refusal the contract states, all exercised by
  `tests/seam_selftest.c` and mutation-tested;
- the **server's own request path** -- `build_chat_msgs`, HTTP, prefill,
  argmax, detokenize -- against an independently computed expected token
  (`tests/server_e2e.py`);
- the **host sampler**: temperature, `top_p`, seeds, reproducible per seed.

Nothing in this directory has ever been run against the card, and
`fk33_transport.c` refuses to open a `/dev` path without an explicit token that
nothing in this tree passes.

---

## The FK33 host seam, in one paragraph

`server/fk33_seam.h` is the contract; `docs/2026-08-29_host-card-seam.md` is
the prose with the derivations. The host owns the loop, the sampler, the
tokenizer, the chat template, the sequence position and the embedding gather.
The card owns the weights, the 32 blocks, the KV cache (which never crosses
PCIe) and the lm_head. Per position, an 8,208-byte BFP-packed activation row
goes in and a 993,296-byte int32 logits row plus one shared block exponent
comes back -- or, for a greedy caller, four bytes of argmax and no C2H at all.

### Which copy of the embedding the host gathers

Two providers ship, and they are NOT numerically equivalent:

| provider | source | per token | mean relerr at the activation |
|---|---|---|---|
| `embed_bf16.c` | `Qwen3.5-9B-BF16.gguf`, BF16 | ONE 8,192 B `pread` | **0.000040** |
| `embed_mv4i.c` | `token_embd.weight.mv4i`, INT4 | TWO 4,096 B `pread`s | 0.086123 |

`llama_server --embed auto|gguf|mv4i|synthetic` selects; `auto` (the default)
takes the BF16 copy when its file is present and PRINTS which it chose. An
explicit `gguf` or `mv4i` whose file will not open is a REFUSAL, never a quiet
downgrade to a ~2,000x coarser activation.

The BF16 copy is the one `ref/run9b.c` evaluates by default since 2026-08-29,
and the host's packed row is bit-identical to that reference's own `R_X.embed`
seam. The INT4 provider is retained because every 9B number published before
that date was measured with it and has to stay reproducible. The whole move,
with the re-established headline figures beside the old ones, is
`docs/debugging/2026-08-29_embedding-bf16-upgrade.md`.

`server/pl_backend_axu3eg.{h,c}` is v1, retained unchanged for the AXU3EG with
its symbols renamed `plv1_*`. It handed the card a prompt and got a token
stream back, which was right for a board with a PS on the same die and is wrong
for a PCIe card.

---

## Build

```sh
cd server
make            # -> ./llama_server        (dev box)
make board      # -> ./llama_server_arm    (static aarch64)
make check      # compile-only, both toolchains, no card
make test       # -> ./seam_selftest, no card, no driver, no FPGA
```

## Run

From the **repo root**, so the default model paths resolve.

```sh
# stories260K, unchanged
./server/llama_server

# Qwen3.5 through the FK33 seam, against the simulated card
./server/llama_server --model qwen35 --qtk build_artifacts_tok/qwen35_9b.qtk

# ... against the REAL transport pointed at ordinary files.  This FAILS at
# open, on purpose: a file has no engine in it, so the identity register reads
# 0x00000000 and pl_open refuses.  It is how you check the transport itself.
./server/llama_server --model qwen35 --card file --card-dir /tmp/fk33img
```

`--card` accepts only `sim` and `file`. **There is deliberately no flag that
opens `/dev/xdma*`**; see the tripwire in `fk33_transport.h` and the hardware
boundary in `CLAUDE.md`.

The `.qtk` artefact is 9 MB and is **not committed**. Regenerate it with
`tools/extract_tokenizer.py`.

## Endpoints

`GET /v1/models`, `POST /v1/chat/completions` (+ `"stream": true`),
`POST /v1/completions`, `OPTIONS *`.

Supported params: `max_tokens`, `temperature`, `top_p`, `seed`, `stop`,
`stream`. Under `--model qwen35`, also `enable_thinking` (default **false**,
which per the template emits an empty already-closed reasoning block, not
nothing -- see the header of `qwen35_tok.h`).

**Refused, with a 400 naming what:** `tools`, the `tool` role, `tool_calls`,
and image/video content parts. The chat template covers all four and this
renderer does not, and a server that renders half a template silently is
off-distribution on every affected request. `qwen35_chat.h` lists the subset.

## Verifying

```sh
# the chat template against Jinja2, and its ids against llama.cpp
python3 server/verify_chat_template.py --build
python3 server/verify_chat_template.py --build --ids \
    --gguf /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf

# a mutation must make the comparison FAIL
python3 server/verify_chat_template.py --build --mutate think-default

# the seam, no card
make -C server test

# the server's own request path, end to end, no card
python3 server/tests/server_e2e.py
```

## Notes / limits

- Generation is serialized by a mutex; one request at a time.
- No auth, TLS, tools/function-calling, or embeddings endpoint.
- `usage.prompt_tokens` is reported as 0.
- The AXU3EG `--pl` path is greedy-only and capped at the core's MAXPOS (24).
  That limitation is v1's and is the reason v2 exists.
