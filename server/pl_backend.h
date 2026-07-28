/* server/pl_backend.h -- run generation on the PL transformer instead of the CPU.
 *
 * IMPORTANT SHAPE NOTE.  This is deliberately NOT a `forward_hw()` drop-in for
 * llama2.c's forward().  forward() returns the LOGITS for one position and the
 * caller's sampler picks a token from them -- but engine_shared does not expose
 * logits at all: during the FPGA fit rounds its parallel `logits` port was left
 * OPEN precisely so synthesis would prune the 512-way register + demux (that is
 * what took lm_head from 39.5K to 762 LUT).  The core streams logits internally
 * into a running-argmax sampler and exposes only the chosen token per position,
 * and it runs the whole autoregressive loop itself.
 *
 * So the honest seam is GENERATION-level: hand the PL a prompt, get the token
 * stream back.  Consequences the server has to respect:
 *   * GREEDY ONLY.  There is no temperature/top-p in hardware, so a request that
 *     asks for sampling cannot be served by the PL.
 *   * prompt + generated <= MAXPOS (24) tokens total.
 *   * ONE run at a time -- the engine is a single shared resource.
 */
#ifndef PL_BACKEND_H
#define PL_BACKEND_H

#ifdef __cplusplus
extern "C" {
#endif

/* Map the engine and check its ID.  clock_mhz > 0 also sets the PL clock (80 is
 * the fastest that meets worst-case timing).  Returns 0 on success, <0 if the
 * engine is not there (no /dev/mem, wrong bitstream, not root). */
int pl_open(int clock_mhz);

/* Total positions the core runs (NGEN) and its KV depth (MAXPOS). */
int pl_ngen(void);
int pl_maxpos(void);

/* Encode `text` to token ids (BOS first).  Returns count or <0 if it will not
 * fit in `max`. */
int pl_encode(const char *text, int *ids, int max);

/* Run the engine on the given prompt ids and write the FULL emitted stream to
 * `out`.  Returns the number of tokens emitted, or <0 on error.
 * Note the stream begins with the prompt's own continuation: out[0..nprompt-2]
 * are prompt[1..nprompt-1] (teacher forcing), so freshly GENERATED tokens start
 * at index nprompt-1. */
int pl_generate(const int *prompt, int nprompt, int *out, int max_out);

/* Detokenize one id, given the previous id (for the post-BOS space rule). */
int pl_piece(int tok, int prev, char *dst, int dstlen);

/* Human-readable description of the mapped engine, for logs / /v1/models. */
const char *pl_describe(void);

#ifdef __cplusplus
}
#endif

#endif /* PL_BACKEND_H */
