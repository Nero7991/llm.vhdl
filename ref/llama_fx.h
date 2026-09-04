/* llama_fx.h — minimal in-process API for the fixed-point stories260K model.
 *
 * Implemented in ref/run_fx.c (compile it with -DLLAMA_LIB to drop its main()
 * and link it into another program, e.g. the OpenAI server). The model is the
 * fixed-point forward_fx() path — token-identical to the VHDL engine (greedy).
 *
 * Opaque handle: callers never see the Transformer/Tokenizer/Sampler internals.
 */
#ifndef LLAMA_FX_H
#define LLAMA_FX_H

#ifdef __cplusplus
extern "C" {
#endif

/* Per generated token, the decoded UTF-8 piece is handed to this callback.
 * Also used internally by the CLI (sink = stdout). Return non-zero to stop
 * generation early (e.g. max_tokens reached or a stop string matched);
 * return 0 to continue. */
typedef int (*llama_piece_cb)(const char *piece, void *user);

typedef struct LlamaCtx LlamaCtx;

/* Load the checkpoint + tokenizer once. Returns NULL on failure. Selects the
 * fixed-point (VHDL-equivalent) forward path. */
LlamaCtx *llama_load(const char *checkpoint_path, const char *tokenizer_path);

int llama_seq_len(const LlamaCtx *ctx);   /* max positions (context length) */
int llama_vocab(const LlamaCtx *ctx);     /* vocabulary size */

/* Generate up to max_tokens continuation tokens from `prompt`. temperature<=0
 * is greedy (argmax = VHDL-exact); >0 samples (top_p nucleus).
 *
 * EVERY piece is delivered to on_piece(piece, user) in order, INCLUDING the
 * leading `llama_prompt_tokens(ctx, prompt) - 1` pieces that echo the prompt
 * back.  That is llama2.c's original CLI behaviour and run_tokens.sh compares
 * against it, so it is deliberate and will not change.  A caller that wants
 * only the continuation must skip that many pieces itself; the count comes
 * from llama_prompt_tokens below.
 *
 * (This paragraph used to read "Each generated piece", which was wrong in a
 * way no caller could detect except by counting: the server was reporting
 * echoed prompt tokens as completion tokens and charging them against
 * max_tokens.)
 *
 * Stops early at BOS.
 * Returns the number of positions advanced. NOT thread-safe for one ctx (the
 * model RunState is shared) — the caller serializes concurrent generations. */
int llama_generate(LlamaCtx *ctx, const char *prompt, int max_tokens,
                   float temperature, float top_p, unsigned long long seed,
                   llama_piece_cb on_piece, void *user);

/* How many tokens `prompt` encodes to, including the BOS that the generation
 * path prepends.  `n - 1` is exactly the number of leading on_piece calls that
 * are prompt echo rather than generation. */
int llama_prompt_tokens(LlamaCtx *ctx, const char *prompt);

void llama_free(LlamaCtx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* LLAMA_FX_H */
