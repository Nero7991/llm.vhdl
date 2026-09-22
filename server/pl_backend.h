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
 * THE EMBEDDING PROVIDER NOW EXISTS.  `server/embed_mv4i.c` reads a packed
 * `.mv4i` embedding tensor with two contiguous reads per token and BFP-packs
 * the row; pass `pl_embed_mv4i` and a `pl_embed_mv4i_t *` opened by
 * `pl_embed_mv4i_open()`.  The paragraph above describing this file as
 * shipping "two implementations of nothing" was true until 2026-08-29 and is
 * kept because the interface argument it makes is still the reason the seam
 * takes a callback at all.  Which COPY of the embedding it reads, and the
 * evidence for that choice, is in embed_mv4i.h and in
 * docs/debugging/2026-08-29_host-embedding-gather.md.
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
 * the row's shared block exponent.  Return 0, or negative on failure.
 *
 * THE SIGN OF `*exp` IS THIS REPOSITORY'S, NOT THE OTHER ONE:
 * `value[j] = mant[j] * 2^(-*exp)`.  `tools/pack_int4.py` fixes it,
 * `rtl/bfp_pack.vhd` implements it and `ref/run9b.c`'s `reg_t` restates it.  A
 * provider that returned the negated exponent would be wrong by a factor of
 * 2^(2*exp) and every structural check in this tree would still pass; that is
 * mutant c11 in tools/check_embed_c.py, and only a value-level oracle sees it. */
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

    /* BAR offset of the seam register block.  0 -> FK33_SEAM_BASE. */
    uint32_t seam_base;

    /* HBM addresses.  ZERO MEANS DERIVE, and derived is the intended path.
     *
     * These used to be three hardcoded constants -- 0x00E0000000 /
     * 0x00E1000000 / 0x00E2000000 -- and all three sat INSIDE the weight
     * image: 0xE0000000 is 3.5 GiB, and `weights_end` is 0x12F203000 in the
     * shipped `qkvpad` set and 0x10C006000 in the post-drop `noembd` set.
     * TRACK EMBDROP found it; it was never caused by the drop, the drop only
     * changed the number they had to clear.  A replacement constant would be
     * the same defect with a different number: `kv_base` moved
     * 0x1_33A0_3000 -> 0x1_1080_6000 when the image shrank, so every address
     * downstream of the image moves whenever the image does.
     *
     * So a zero here means "allocate me one", and pl_derive_bases() below does
     * it top-down from the top of HBM out of the shape alone (n_embd, n_vocab,
     * max_chunk).  A NON-zero value is taken as given and CHECKED: alignment,
     * the stack line, mutual overlap, and -- when `manifest_path` or
     * `hbm_reserved_end` says where the image ends -- overlap with the image,
     * which is refused at open time rather than found by a wrong token. */
    uint64_t x_base;              /* activation block; 0 -> derive */
    uint64_t l_base;              /* logits block;     0 -> derive */
    uint64_t desc_ptr;            /* per-token D program, 512-B aligned; 0 -> derive */

    /* The subsystem A descriptor arena, which `tools/gen_layer_program.py`
     * places and which used to be invisible here.  See pl_hbm_bases.
     *
     *   desc_arena_bytes  0  -> nothing was declared HERE.  With a manifest
     *                           that is normal: fk33_manifest_read() requires
     *                           hbm.desc_arena_base / _bytes and pl_open takes
     *                           them from there.  With NO manifest and no
     *                           value here, pl_open REFUSES -- as of
     *                           2026-08-29 an undeclared arena is a refusal,
     *                           not the warning it used to be.
     *                     >0 -> checked, and placed by pl_place_desc_arena()
     *                           if desc_arena_base is 0.
     *   desc_arena_base   an explicit base, which OUTRANKS the manifest for a
     *                     caller that actually ran gen_layer_program.py with
     *                     --desc-base.  Checked, never trusted. */
    uint64_t desc_arena_base;
    uint64_t desc_arena_bytes;
    /* v2 only: subsystem B's recurrent-state base.  0 -> the manifest's
     * hbm.gdn_state_base.  With no manifest it must be stated, and a v2
     * open with neither is refused. */
    uint64_t gdn_state_base;
    /* v2 only: subsystem B's learned-constant image base
     * (docs/2026-09-18_b-constants-path.md).  0 -> the manifest's
     * hbm.gdn_const_base, which is itself optional; if that is also absent
     * the seam register FK33_SEAM_BCB_LO/HI is written 0 and pl_open warns,
     * because a B_CONST_HBM card handed 0 reads its constants out of the
     * first weight tensor.  See fk33_manifest.h for why absent is not a
     * refusal. */
    uint64_t gdn_const_base;
    /* v2 only, on a card advertising FK33_CAP_ENG_KV_BASE: subsystem C's KV
     * cache base (2026-09-20, docs/debugging/2026-09-20_the-kv-cache-base-
     * is-compiled-into-the-bitstream.md).  0 -> the manifest's hbm.kv_base.
     * V is DERIVED, never stated: V = K + KV_MAXPOS * kv_bytes_per_token /
     * 2 with KV_MAXPOS read from the card, so the pair is the card's own
     * geometry laid at the image's kv_base.  With no manifest both kv_base
     * and kv_bytes_per_token must be stated here, and the extent is checked
     * only against hbm_size (and the arena when stated); with a manifest it
     * is checked against the space below gdn_const/the arena, and an image
     * whose free KV space is smaller than the card's pair is REFUSED at
     * open.  A card WITHOUT the capability ignores both: its base is
     * compiled in and pl_open says so once on stderr. */
    uint64_t kv_base;
    uint64_t kv_bytes_per_token;

    /* Where the card's own bytes end.  Two ways to say it, and either is
     * enough; the manifest is preferred because it is the artefact the loader
     * actually used.
     *
     *   manifest_path      a packed set's manifest.json.  hbm.size,
     *                      hbm.weights_end, hbm.gdn_state_base/_bytes and
     *                      hbm.kv_base are read from it and the host's blocks
     *                      are placed above all of them.
     *   hbm_reserved_end   the same answer as one number, for a caller with no
     *                      manifest (the simulated card has no weight image at
     *                      all, so 0 is honest there).
     *
     * With NEITHER, no overlap check is possible and pl_open says so once, on
     * stderr, rather than pretending the derived address is safe. */
    const char *manifest_path;
    uint64_t    hbm_reserved_end;
    uint64_t    hbm_size;         /* 0 -> the manifest's, else FK33_HBM_TOP */

    /* ---------------------------------------------------- THE v2 PROGRAM
     * Subsystem D's descriptor program and its release-mask table, which a v2
     * card takes through the WIN_DESC and WIN_REL windows because it has no
     * HBM master to fetch them with.  `tools/gen_layer_program.py --token`
     * emits both; `pl_load_hex_words()` below parses its text format.
     *
     * REQUIRED on a v2 card and REFUSED on a v1 one, rather than ignored in
     * either direction: a host that supplies a program to a card that fetches
     * its own is a host confused about which card it has, and that confusion
     * is the thing this seam's version register exists to prevent.
     *
     * `desc_words` counts 32-BIT HALVES, low half first.  `tbl_len` counts
     * DESCRIPTORS including the END_TOKEN, and `rtl/fk33_seam.vhd:746-761`
     * bounds it against the window capacity two ways -- `tbl_len <= REL_ENT`
     * and `tbl_len * 8 <= DESC_WORDS` -- so 8 sixty-four-bit words per
     * descriptor is not a convention here, it is the card's arithmetic. */
    const uint32_t *desc_prog;    /* 32-bit halves, low half first */
    int             desc_words;
    const uint32_t *rel_tbl;      /* one entry per descriptor */
    int             rel_words;
    int             tbl_len;      /* descriptors, END_TOKEN included */

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

    /* THE IMAGE INTERLOCK (2026-09-20, server/fk33_imglock.h).
     *
     * `pl_open` reads the 512-byte image record out of the descriptor arena
     * and refuses to program the card's bases if it describes a DIFFERENT
     * image from `manifest_path`.  That refusal is unconditional and needs no
     * flag: a record that disagrees is always wrong.
     *
     * This flag decides the OTHER case -- a card with NO record at all, which
     * is a card nobody can say anything about.  On the real transport it is
     * forced to 1, because there `kv_base` is a register subsystem C writes
     * through and an unverified manifest costs weight objects (MEASURED:
     * 35 of them).  A simulated or file-backed card has no loaded image to
     * disagree with and its HBM reads as zero, so 0 there is honest and the
     * absence is reported rather than refused.  A test sets it to 1 on the
     * FILE transport to exercise the hardware branch without hardware. */
    int require_image_lock;
} pl_open_opts;

/* Fill `o` with the defaults: simulated transport, 9B shape, synthetic
 * embedding, and x_base/l_base/desc_ptr = 0, meaning DERIVE them. */
void pl_open_opts_default(pl_open_opts *o);

/* ---------------------------------------------------------------------------
 * Where the host's three blocks go, and why it is a derivation.
 *
 * Allocated TOP-DOWN from the top of HBM, 4 KB-aligned, in the order
 * desc / logits / activations.  Top-down because the only thing growing from
 * the bottom is the card's own image, and the only thing growing from
 * `kv_base` upward is the KV cache: coming down from the top means the host's
 * blocks are the first thing an image growth collides with, and that collision
 * is a refusal at open time, not a corruption.
 *
 * `kv_tokens_cost` is what those blocks cost the KV cache, at the manifest's
 * own kv_bytes_per_token.  It is reported rather than hidden because it is the
 * real price of this placement.
 *
 * hbm_top == 0 means FK33_HBM_TOP.  reserved_end == 0 means "unknown", and
 * then no overlap check is performed and none is claimed.  Returns 0, or a
 * FK33_SEAM_ERR_* code.
 * ------------------------------------------------------------------------- */
typedef struct {
    uint64_t x_base, x_span;
    uint64_t l_base, l_span;
    uint64_t desc_ptr, desc_span;
    uint64_t hbm_top, reserved_end;
    uint64_t kv_tokens_cost;

    /* THE FOURTH REGION, AND THE ONE THIS STRUCT USED NOT TO KNOW ABOUT.
     *
     * `tools/gen_layer_program.py` places subsystem A's per-job descriptor
     * arena, and it too anchored at the TOP of HBM.  MEASURED 2026-08-29 at
     * the 9B shape: the arena landed at 0x1_FFFD_9000 and took 153,664 B out
     * of the logits row -- 38,416 float32 slots, the top 15.47% of the
     * 248,320-entry vocabulary -- plus 3,584 B of the D program page.
     * Whichever master wrote last won, and the symptom is a wrong token with
     * no fault raised anywhere.  Neither allocator could see the other:
     * pl_check_bases() had no concept of an arena, and gen_layer_program.py
     * has no concept of these three blocks.
     *
     * ZERO SPAN MEANS "NOT DECLARED", AND pl_check_bases() NOW REFUSES IT.
     * It used to pass, with pl_open printing a note; TRACK ADDRARENA recorded
     * that as the live hazard, because a note reads as "checked".  A layout
     * that is about to be used and does not say where subsystem A's
     * descriptors are is incomplete, and incomplete is refused.
     *
     * THE MECHANISM IS DECIDED (Oren, 2026-08-29): the manifest's `hbm` region
     * block is the authority.  pl_place_desc_arena() remains, because the
     * ALLOCATION RULE has to live somewhere the C can be checked against, and
     * tools/hbm_map.py --check-c compiles this file and requires the two to
     * agree; but the shipping path reads hbm.desc_arena_base and does not
     * call it. */
    uint64_t arena_base, arena_span;
} pl_hbm_bases;

int pl_derive_bases(int n_embd, int n_vocab, int max_chunk,
                    uint64_t hbm_top, uint64_t reserved_end,
                    uint64_t kv_bytes_per_token, pl_hbm_bases *out);

/* Place the subsystem A descriptor arena in the first 4 KB-aligned block below
 * `x_base`, and re-run pl_check_bases().  `arena_bytes` 0 is now an ERROR:
 * clearing the arena produces exactly the incomplete layout that is no longer
 * legal.
 *
 * This is the ALLOCATION RULE, and after 2026-08-29 it is not the shipping
 * path: `tools/pack_model_fk33.py` runs the same rule once, at pack time, and
 * writes the answer into the manifest.  It stays here because
 * `tools/hbm_map.py --check-c` compiles this translation unit and requires the
 * Python allocator and this one to agree address for address -- that check is
 * the only evidence either of them is right.  Returns 0, or FK33_SEAM_ERR_*. */
int pl_place_desc_arena(pl_hbm_bases *b, uint64_t arena_bytes);

/* The check the derivation is not allowed to skip, exported so a caller that
 * supplies its own bases can run it first.  `reserved_end` 0 disables only the
 * image-overlap half; alignment, the stack line, the top of HBM and mutual
 * overlap are always checked.
 *
 * IT ALSO REQUIRES A DECLARED ARENA (arena_span != 0) as of 2026-08-29.  A
 * caller that only wants the three host blocks derived calls pl_derive_bases(),
 * which runs the geometry half and does not demand the fourth region it has
 * not placed.  Returns 0, or a FK33_SEAM_ERR_* code. */
int pl_check_bases(const pl_hbm_bases *b);

/* ---------------------------------------------------------------------------
 * Parse `tools/gen_layer_program.py`'s text output, one value per line.
 *
 * THE TWO FILES ARE IN DIFFERENT NOTATIONS and it is not obvious from looking
 * at them, which is why this takes a format rather than a flag:
 *
 *   .dtbl   16 HEX digits, a 64-bit descriptor word.  Yields TWO 32-bit
 *           halves, low half first, which is the order WIN_DESC takes.
 *   .rel    14 BINARY digits, MSB first -- `write_rel()` at
 *           gen_layer_program.py:972 emits one character per region, and
 *           NREGION is 14.  A line like `10000000000000` is 0x2000, not
 *           0x10000000000000.
 *
 * MEASURED 2026-09-17: reading the .rel as hex is accepted by strtoull and
 * produces values ~2^52, which pl_open would then have written into the
 * release window as silently wrong masks.  It was caught only because this
 * loader refuses a value that does not fit the width it was asked for.  That
 * refusal is the reason the format is a parameter now.
 *
 * Returns the number of 32-bit words written to *out (malloc'd, caller frees),
 * or negative.  This is a convenience and not part of the seam: a caller that
 * already has the program in memory passes it straight to pl_open.
 * ------------------------------------------------------------------------- */
#define PL_FMT_HEX32   0   /* one 32-bit hex value per line */
#define PL_FMT_HEX64   1   /* one 64-bit hex value -> two halves, low first */
#define PL_FMT_BIN     2   /* a binary digit string, MSB first */
int pl_load_hex_words(const char *path, int fmt, uint32_t **out);

/* The seam contract version the open card reports, 1 or 2, or 0 if not open.
 * A caller that must branch -- there is no chunked prefill on v2, so
 * pl_max_chunk() is 1 there -- branches on this. */
int pl_version(const pl_ctx *c);

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
/* Host-side time accounting (seconds since process start): the X-row pushes,
 * the STATUS poll loops (and their count), and whole run_chunk calls. */
void pl_host_timing(double *push_s, double *wait_s, double *go_s, unsigned long *polls);
/* Adopt the card's current SEQ_POS as the next position; returns it. */
int pl_resume_pos(pl_ctx *c);
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
 *      -7  a GO issued by pl_go_async is still outstanding on this card
 * On -3, pl_last_error() gives the FK33_SEAM_ERR_* code and its text.
 * ------------------------------------------------------------------------- */
int pl_prefill(pl_ctx *c, const int *ids, int n,
               int32_t *logits, int32_t *logit_exp, int *argmax);

int pl_decode(pl_ctx *c, int id,
              int32_t *logits, int32_t *logit_exp, int *argmax);

/* THE TWO-CARD HOP (2026-09-21).
 * pl_read_xout: after a completed GO, the residual R_X -- n_embd int16
 * mantissas through window 3 and its block exponent from XEXP_OUT.  Returns
 * 0; -1 if the card lacks FK33_CAP_XEXP_OUT (an old bitstream: the
 * mantissas alone are meaningless, so refuse rather than guess); -2 on a
 * transport error.
 * pl_decode_row: push a caller-supplied row (bypassing the embedding
 * provider) as the X row with `exp`, and run one GO at the current
 * position.  Same contract and return values as pl_decode otherwise.  This
 * is how card 1 of a pipeline takes card 0's residual as its input. */
int pl_read_xout(pl_ctx *c, int16_t *mant, int32_t *exp);
int pl_decode_row(pl_ctx *c, const int16_t *mant, int32_t exp,
                  int32_t *logits, int32_t *logit_exp, int *argmax);

/* THE NON-BLOCKING GO (2026-09-21, for the two-card prefill overlap).
 * pl_go_async issues a GO of `n` steps at the current position and returns
 * at once (0, or a negative code); pl_wait collects it: waits for done|err,
 * advances the position, reads the argmax and the logit exponent, and
 * returns n.  pl_decode_async / pl_decode_row_async are push + pl_go_async
 * for one position.  While a GO is outstanding (pl_pending != 0) every verb
 * that pushes a row, reads R_X or issues a GO returns -7, and pl_wait with
 * nothing outstanding also returns -7; a card that is mid-token owns its
 * windows and the residual is not there until it finishes.  No logits row
 * on this path (v2 has none; use pl_decode for a v1 card). */
int pl_go_async(pl_ctx *c, int n);
int pl_wait(pl_ctx *c, int32_t *logit_exp, int *argmax);
int pl_pending(const pl_ctx *c);
int pl_decode_async(pl_ctx *c, int id);
int pl_decode_row_async(pl_ctx *c, const int16_t *mant, int32_t exp);

/* The last FK33_SEAM_ERR_* code and ERR_INFO the card reported. */
unsigned    pl_last_error(const pl_ctx *c);
uint32_t    pl_last_error_info(const pl_ctx *c);
const char *pl_last_error_str(const pl_ctx *c);

/* Counters, for the write-up rather than for the server. */
uint64_t pl_bytes_to_card(const pl_ctx *c);
uint64_t pl_bytes_from_card(const pl_ctx *c);
uint64_t pl_go_count(const pl_ctx *c);
/* v2 + FK33_CAP_ENG_KV_BASE: subsystem C's KV pair as READ BACK from the
 * card after pl_open wrote it (pl_open refuses if the read-back differs),
 * and the card's C_MAXPOS.  All 0 on a card without the capability. */
uint64_t pl_kv_k_base(const pl_ctx *c);
uint64_t pl_kv_v_base(const pl_ctx *c);
uint32_t pl_kv_maxpos(const pl_ctx *c);

#ifdef __cplusplus
}
#endif

#endif /* PL_BACKEND_H */
