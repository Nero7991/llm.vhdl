/* server/pl_backend.h -- v2 of the host seam: PREFILL, then DECODE RETURNING
 * LOGITS, with the host owning the loop.
 *
 * v1 (server/pl_backend_axu3eg.h, retained) handed the card a prompt and got a
 * token stream back.  That was right for the AXU3EG and is wrong for the FK33.
 * The contract that replaces it -- what crosses, in which direction, in what
 * units, and who owns each piece of state -- is in server/fk33_seam.h, and the
 * prose with the derivations and the rejected alternatives is
 * docs/2026-08-29_host-card-seam.md.  READ fk33_seam.h BEFORE THIS FILE; in
 * particular, read the block in it that says the engine described does not
 * exist yet.
 *
 * This header is the host's half.  Everything below runs today against the
 * simulated card and none of it has ever run against silicon.
 *
 * WHAT THE HOST OWNS, AND THEREFORE WHAT IS IN THIS FILE
 * -----------------------------------------------------
 *   the loop            pl_prefill / pl_decode; the caller drives them
 *   the sampler         NOT here.  The caller gets logits and samples.  That
 *                       is the entire point of the move: temperature, top_p,
 *                       seeds, logit bias and speculative decoding all become
 *                       ordinary software the moment logits cross.
 *   KV bookkeeping      pl_seq_pos / pl_seq_reset.  The KV BYTES stay on the
 *                       card and never cross PCIe (17,408 B/token would be the
 *                       whole link budget); what crosses is a position index.
 *   the embedding gather  pl_embed_fn below.  The card does not gather.
 *
 * THE EMBEDDING PROVIDER IS AN INTERFACE, NOT AN IMPLEMENTATION
 * ------------------------------------------------------------
 * Reading a packed embedding row, dequantizing it and BFP-packing it is
 * backlog item 4 ("Token I/O: embedding and LM head"), which owns `rtl/` and
 * `tools/` and is not this track.  `docs/2026-08-28_token-io-path.md` section
 * 8 already carries the addressing (two contiguous 4 KB reads per token) and
 * a MEASURED correction to the dequantize recipe: folding the `>>15` into the
 * BFP pack's own shift moves mean relative error from 0.22794 to 0.08630, a
 * factor of 2.641, and under the as-written recipe a decoded row is not
 * separable from its neighbour.  `tools/embed_gather.py --recipe wide` is the
 * reference.
 *
 * So this file takes a CALLBACK and ships two implementations of nothing:
 * `pl_embed_synthetic` (deterministic, explicitly not a model of anything) and
 * NULL, which is an error.  When item 4 lands, one function is written and
 * passed in.  That is the whole integration.
 *
 * NOT VERIFIED, and this list is the honest state of the file:
 *   * nothing here has been run against the card, and nothing in this tree may
 *     open /dev/xdma* (see the tripwire in fk33_transport.h);
 *   * no logits produced by any path here are numerically meaningful -- there
 *     is no whole-model 9B reference in the repository (backlog item 12) and
 *     the simulated card's logits are synthetic by construction;
 *   * the seam register block's BAR offset is PROPOSED and only
 *     `hw/fk33/gen_pcieep.py` can decide it;
 *   * the descriptor program pl_run_opts.desc_ptr points at is OI-4: nothing
 *     emits one.
 */
#ifndef PL_BACKEND_H
#define PL_BACKEND_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pl_ctx pl_ctx;

/* Fill `mant` with n_embd int16 BFP mantissas for `token_id` and set `*exp` to
 * the row's shared block exponent.  Return 0, or negative on failure. */
typedef int (*pl_embed_fn)(void *user, int token_id,
                           int16_t *mant, int n_embd, int32_t *exp);

/* A deterministic synthetic embedding.  NOT A MODEL OF ANYTHING: it exists so
 * the plumbing can be exercised, and it is a pure function of the token id so
 * a test can predict the simulated card's argmax exactly.  Passing this to a
 * real card would compute confident nonsense, which is why pl_open logs a
 * warning every time it is used. */
int pl_embed_synthetic(void *user, int token_id,
                       int16_t *mant, int n_embd, int32_t *exp);

typedef enum {
    PL_TRANSPORT_SIM = 0,   /* server/fk33_sim.c, the test double */
    PL_TRANSPORT_FILE,      /* three ordinary files; the real code, no engine */
    PL_TRANSPORT_CHARDEV    /* /dev/xdma0_* -- THE SWAP POINT, requires a human */
} pl_transport_kind;

typedef struct {
    pl_transport_kind transport;

    /* PL_TRANSPORT_FILE: a directory that will hold `user` and `dma`.
     * PL_TRANSPORT_CHARDEV: unused; the three device paths below are. */
    const char *file_dir;
    const char *dev_user, *dev_h2c, *dev_c2h;
    uint32_t    allow_hardware;   /* must be FK33_ALLOW_HARDWARE for /dev */

    /* BAR offset of the seam register block.  0 -> FK33_SEAM_BASE_PROPOSED. */
    uint32_t seam_base;

    /* HBM addresses.  Defaults are chosen inside the LOWER stack, above the
     * shipped weight image's 5,056,995,328 bytes would be OUT of the lower
     * stack -- so these must be revisited when the residency map and the
     * shipped manifest are reconciled (they currently disagree; see
     * docs/2026-08-28_token-io-path.md section 7.2).  0 -> the default. */
    uint64_t x_base;              /* activation block */
    uint64_t l_base;              /* logits block */
    uint64_t desc_ptr;            /* the per-token D program, 512-B aligned */

    /* The embedding provider.  NULL is an error; pass pl_embed_synthetic
     * explicitly to say you meant the nonsense one. */
    pl_embed_fn embed;
    void       *embed_user;

    /* PL_TRANSPORT_SIM only: a fk33_sim_opts*, or NULL for the default 9B
     * shape.  Declared void* so this header does not pull in fk33_seam.h. */
    const void *sim_opts;

    /* Largest N_STEP the host will ask for in one GO.  0 -> the card's cap. */
    int max_chunk;

    /* How long to wait for done|err before giving up.  0 -> 60000 ms, which
     * is two orders of margin over the largest legal chunk at the 38.27 ms
     * token budget.  Tests set it small so the never-done fault can be shown
     * to fire in a bounded time. */
    int go_timeout_ms;
} pl_open_opts;

/* Fill `o` with the defaults: simulated transport, 9B shape, synthetic
 * embedding, block addresses inside the lower HBM stack. */
void pl_open_opts_default(pl_open_opts *o);

/* Open, read CAPS, and check them.  Returns 0, or negative.  On success
 * *out is a context the caller frees with pl_close. */
int  pl_open(const pl_open_opts *o, pl_ctx **out);
void pl_close(pl_ctx *c);

const char *pl_describe(const pl_ctx *c);
int pl_n_vocab (const pl_ctx *c);
int pl_n_embd  (const pl_ctx *c);
int pl_n_layer (const pl_ctx *c);
int pl_max_ctx (const pl_ctx *c);
int pl_max_chunk(const pl_ctx *c);

/* Cross-check the card's reported vocabulary against another source (in
 * practice qwen35_tok_n_vocab()).  Returns 0 if they agree.
 *
 * This exists because the audit flags the number as UNVERIFIED: section 5.3
 * records that `rtl/model_cfg_pkg.vhd:70` says 248,320, the shipped Qwen3
 * tokenizer said 151,936, and NOTHING in any spec derives it.  A 1.6x
 * disagreement here is a wrong answer AND 342,560 cycles per token of wasted
 * lm_head.  Two independent artefacts agreeing is not proof, but two
 * disagreeing is proof of a defect, and that is worth one comparison. */
int pl_check_vocab(const pl_ctx *c, int n_vocab_from_tokenizer);

/* KV bookkeeping.  The bytes never cross; the position does. */
int pl_seq_reset(pl_ctx *c);
int pl_seq_pos(const pl_ctx *c);

/* ---------------------------------------------------------------------------
 * The two verbs.
 *
 * pl_prefill runs `n` tokens through the card in chunks of at most
 * pl_max_chunk(), advancing the sequence position by n.  It asks the card for
 * logits only for the LAST position, which is the only one a decoder needs;
 * pass logits = NULL to skip even that.
 *
 * pl_decode runs exactly one token.  `logits` may be NULL, in which case the
 * card's own running argmax is read from a single BAR register and the ~1 MB
 * C2H transfer is skipped entirely.  That fast path is a real difference:
 * DERIVED at the measured C2H rate of 1.11 GB/s, 993,296 bytes is 894.9 us,
 * against 4 bytes for the argmax.  A greedy server should use it; a server
 * honouring temperature or top_p cannot.
 *
 * Both return the number of positions advanced, or negative:
 *      -1  argument error          -2  transport error
 *      -3  the card reported err   -4  timeout waiting for done
 *      -5  the embedding provider failed
 * On -3, pl_last_error() gives the FK33_SEAM_ERR_* code and its text.
 * ------------------------------------------------------------------------- */
int pl_prefill(pl_ctx *c, const int *ids, int n,
               int32_t *logits, int32_t *logit_exp, int *argmax);

int pl_decode(pl_ctx *c, int id,
              int32_t *logits, int32_t *logit_exp, int *argmax);

/* The last FK33_SEAM_ERR_* code and ERR_INFO the card reported. */
unsigned    pl_last_error(const pl_ctx *c);
uint32_t    pl_last_error_info(const pl_ctx *c);
const char *pl_last_error_str(const pl_ctx *c);

/* Counters, for the write-up rather than for the server. */
uint64_t pl_bytes_to_card(const pl_ctx *c);
uint64_t pl_bytes_from_card(const pl_ctx *c);
uint64_t pl_go_count(const pl_ctx *c);

#ifdef __cplusplus
}
#endif

#endif /* PL_BACKEND_H */
