# llama.vhdl OpenAI-compatible server

A zero-dependency C++ HTTP server that exposes the fixed-point **stories260K**
model over the OpenAI API, so any OpenAI-compatible UI/app can talk to it.

The served model is the fixed-point C model (`ref/run_fx.c`, `forward_fx`) — it is
**token-identical to the AXU3EG VHDL engine** at greedy decoding (the whole point
of the golden model). No Python, no external libraries: just libstdc++ + POSIX
sockets, and it cross-compiles for the board.

## Heads-up: it's a story model, not a chatbot

stories260K is a **TinyStories** model. It **continues children's-story prose**;
it does **not** follow chat instructions. "Chat" here concatenates your message
text into a prompt and continues the story. Type *"Once upon a time"* and you get
a little story; ask *"what is 2+2"* and you get... more story. Greedy
(`temperature: 0`) reproduces the hardware exactly; `temperature > 0` uses the C
sampler (the argmax-only hardware does not sample).

## Build

```sh
cd server
make            # -> ./llama_server        (dev box)
make board      # -> ./llama_server_arm    (static aarch64 for PetaLinux)
```

The inference `../ref/run_fx.c` is compiled with `-DLLAMA_LIB` (no `main()`) and
linked in-process — one verified codebase, no subprocess.

## Run

From the **repo root** (so the default model paths resolve):

```sh
./server/llama_server                 # listens on 0.0.0.0:8000
# options: --port 8000 --host 0.0.0.0 --checkpoint ref/stories260K.bin --tokenizer ref/tok512.bin
```

Point any OpenAI-compatible client at the base URL **`http://<host>:8000/v1`**
(API key can be anything — auth is not enforced). CORS is open (`*`) so
browser-based UIs work.

## Endpoints

- `GET  /v1/models`
- `POST /v1/chat/completions`  (supports `"stream": true` SSE and non-stream)
- `POST /v1/completions`       (legacy text completion)
- `OPTIONS *`                  (CORS preflight)

Supported params: `max_tokens` (generated tokens, capped at the 512 context),
`temperature`, `top_p`, `seed`, `stop`, `stream`. `model` is accepted and
ignored (one model).

## Test

```sh
./server/llama_server &          # from repo root
sh server/test.sh                # curl models + chat (stream + not) + completions
```

## Board deployment (future)

`make board` produces a static aarch64 binary. Copy `llama_server_arm`, plus
`ref/stories260K.bin` and `ref/tok512.bin`, onto the AXU3EG rootfs and run it on
the PS. Later, the `llama_generate` seam is where a **PL/FPGA backend** (driving
the RTL over AXI) plugs in — the server code above stays unchanged.

## Notes / limits (v1)

- Generation is serialized by a mutex (the model's scratch buffers are shared);
  requests run one at a time. Fine for personal/board use.
- No auth, TLS, tools/function-calling, or embeddings endpoint.
- `usage.prompt_tokens` is reported as 0 (only completion tokens are counted).
