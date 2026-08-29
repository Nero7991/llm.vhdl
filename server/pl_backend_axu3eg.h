/* server/pl_backend_axu3eg.h -- run generation on the PL transformer instead of the CPU.
 *
 * SUPERSEDED FOR THE FK33, RETAINED FOR THE AXU3EG.  This is v1 of the host
 * seam and it is correct for the board it was written for: an AXU3EG with a PS
 * on the same die, an engine that runs the whole autoregressive loop, and a
 * /dev/mem mmap costing nanoseconds per access.  It is WRONG for the FK33,
 * which has no PS at all -- see server/fk33_seam.h for the four rows of the
 * table that force a different shape, and server/pl_backend.h for v2.
 *
 * Kept rather than deleted for the same reason `rtl/matvec_int4_axi.vhd` was
 * kept beside `rtl/matvec_int4_desc_axi.vhd`: the AXU3EG arm is real, it is
 * verified, and nothing about the FK33 invalidates it.  No runtime path
 * chooses between v1 and v2; the server picks one at startup by flag.
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
#ifndef PL_BACKEND_AXU3EG_H
#define PL_BACKEND_AXU3EG_H

#ifdef __cplusplus
extern "C" {
#endif

/* Map the engine and check its ID.  clock_mhz > 0 also sets the PL clock (80 is
 * the fastest that meets worst-case timing).  Returns 0 on success, <0 if the
 * engine is not there (no /dev/mem, wrong bitstream, not root). */
int plv1_open(int clock_mhz);

/* Total positions the core runs (NGEN) and its KV depth (MAXPOS). */
int plv1_ngen(void);
int plv1_maxpos(void);

/* Encode `text` to token ids (BOS first).  Returns count or <0 if it will not
 * fit in `max`. */
int plv1_encode(const char *text, int *ids, int max);

/* Run the engine on the given prompt ids and write the FULL emitted stream to
 * `out`.  Returns the number of tokens emitted, or <0 on error.
 * Note the stream begins with the prompt's own continuation: out[0..nprompt-2]
 * are prompt[1..nprompt-1] (teacher forcing), so freshly GENERATED tokens start
 * at index nprompt-1. */
int plv1_generate(const int *prompt, int nprompt, int *out, int max_out);

/* Detokenize one id, given the previous id (for the post-BOS space rule). */
int plv1_piece(int tok, int prev, char *dst, int dstlen);

/* Human-readable description of the mapped engine, for logs / /v1/models. */
const char *plv1_describe(void);

#ifdef __cplusplus
}
#endif

#endif /* PL_BACKEND_AXU3EG_H */
