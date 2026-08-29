/* server/embed_mv4i.h -- the REAL embedding provider: gather one row out of a
 * packed `.mv4i` INT4 tensor, dequantize it, and BFP-pack it to the int16 +
 * one-exponent form `pl_embed_fn` promises.
 *
 * WHY THIS FILE EXISTS.  TRACK EMBDROP removed `token_embd.weight` from the
 * packed HBM image (`--drop token_embd.weight`,
 * docs/debugging/2026-08-29_token-embd-drop.md), so the card no longer holds
 * the embedding at all and the host must.  `pl_embed_fn` was the landing place
 * TRACK SERVER left for exactly this; the only implementations were
 * `pl_embed_synthetic`, which is not a model of anything, and NULL, which is an
 * error.  This is the one that reads real weights.
 *
 * WHICH COPY OF THE EMBEDDING, AND WHY IT IS NOT THE GGUF.
 * ------------------------------------------------------
 * Two copies exist and they are NOT numerically equivalent:
 *
 *   packed  `token_embd.weight.mv4i`, 572,207,104 B, INT4 + per-32 scales
 *   source  `Qwen3.5-9B-BF16.gguf`,   2,034,237,440 B of BF16 for this tensor
 *
 * This file reads the PACKED one, and the deciding evidence is not size.  It is
 * that `ref/run9b.c`'s `embed()` -- the whole-model 9B reference, the only
 * artefact in this repository that can say whether a first token is the right
 * token -- gathers the embedding from `token_embd.weight` in the PACKED set
 * through `w_deq`, and its rung-2 / rung-3 numbers (the 0.1252 relative RMS the
 * weight format costs at the logits, and all three rungs agreeing on the next
 * token at all five reference positions) were MEASURED with that INT4
 * embedding in place.  Feeding the card a BF16-derived row would be feeding it
 * an activation the reference never evaluated.  See
 * docs/debugging/2026-08-29_host-embedding-gather.md section 5 for the full
 * argument and for what the GGUF choice would have changed.
 *
 * THE RECIPE IS `wide`, NOT SPEC D 3.2 AS WRITTEN.
 * ------------------------------------------------
 * D 3.2 says "codebook[idx] * scale, floor >> 15 per block, then BFP-pack".
 * Taken literally the `>> 15` happens BEFORE the pack, the row lands in
 * [-127, 127], and eight of the sixteen mantissa bits are dead.  MEASURED by
 * `tools/embed_gather.py --compare` over 48 rows against the BF16 GGUF: mean
 * relative error 0.22794 written literally against 0.08630 with the shift
 * folded into the pack's own shift, a factor of 2.641; and under the literal
 * recipe a decoded row is not separable from its NEIGHBOUR (matched 0.157 ..
 * 0.705 against mismatched 0.731 .. 5.361, a 3.6 % gap).  `PL_EMBED_RECIPE_D32`
 * exists so a check can be shown to tell the two apart.  Do not ship it.
 *
 * THE READ SHAPE.  Two contiguous `nb * (AXI_DW/8)`-byte reads per token, one
 * from weight sub-region `rr / rows_per_beat` and one from scale sub-region
 * `rr / scales_per_beat`, both at byte offset `t * nb * port_b` inside it.  At
 * the shipped geometry (ROWS_IF 48, AXI_DW 256, BLOCK 32, K 4096) that is
 * exactly two 4,096-byte reads.  `pread` rather than `mmap`: the read shape is
 * then literally the two bursts a driver or an on-card gatherer would issue,
 * and an SBC does not have to map 546 MiB to answer a 4 KB question.
 *
 * SIGN CONVENTION OF `*exp`.  This repository's, everywhere:
 * `value[j] = mant[j] * 2^(-exp)`.  `tools/pack_int4.py` fixes it,
 * `rtl/bfp_pack.vhd` implements it, and `ref/run9b.c`'s `reg_t` states it.  A
 * provider that returned the other sign would be wrong by 2^(2*exp) and every
 * structural check in the tree would pass.
 *
 * NOT VERIFIED: nothing here has run against the card, and nothing in this
 * tree may open /dev/xdma*.
 */
#ifndef EMBED_MV4I_H
#define EMBED_MV4I_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pl_embed_mv4i_s pl_embed_mv4i_t;

/* The two recipes of docs/2026-08-28_token-io-path.md section 5. */
#define PL_EMBED_RECIPE_WIDE 0   /* cb*scale kept whole; the pack places it   */
#define PL_EMBED_RECIPE_D32  1   /* spec D 3.2 literally: >>15, THEN pack.
                                  * MEASURED 2.641x worse.  Do not ship it.  */

/* Open a packed tensor.  Returns 0, or negative with a message on stderr.
 * `recipe` is PL_EMBED_RECIPE_WIDE unless you have a reason and a measurement. */
int  pl_embed_mv4i_open(const char *path, int recipe, pl_embed_mv4i_t **out);
void pl_embed_mv4i_close(pl_embed_mv4i_t *e);

/* The pl_embed_fn.  `user` is the pl_embed_mv4i_t *.  `n_embd` must equal the
 * file's K; a mismatch is refused rather than truncated, because a truncated
 * embedding row is a plausible-looking wrong answer. */
int  pl_embed_mv4i(void *user, int token_id,
                   int16_t *mant, int n_embd, int32_t *exp);

/* The same gather, one level lower: the dequantized row as integers plus the
 * exponent they carry (`true = value * 2^(-val_exp)`).  Exposed because the
 * cross-checks compare at this level as well as at the BFP level, and because
 * the two failure modes -- wrong bytes and wrong pack -- are worth separating. */
int  pl_embed_mv4i_row_int(pl_embed_mv4i_t *e, int token_id,
                           int32_t *vals, int n, int32_t *val_exp);

int  pl_embed_mv4i_n_embd (const pl_embed_mv4i_t *e);   /* the file's K */
int  pl_embed_mv4i_n_vocab(const pl_embed_mv4i_t *e);   /* the file's M */
uint64_t pl_embed_mv4i_bytes_read(const pl_embed_mv4i_t *e);
uint64_t pl_embed_mv4i_gathers   (const pl_embed_mv4i_t *e);
const char *pl_embed_mv4i_describe(const pl_embed_mv4i_t *e);

/* Addressing, for a driver trace and for the checks.  Any pointer may be NULL. */
int  pl_embed_mv4i_addr(const pl_embed_mv4i_t *e, int token_id,
                        int *tile, int *row_in_tile,
                        int *w_sub, int *half, int *s_sub, int *s_idx,
                        uint64_t *w_off, uint64_t *s_off, uint64_t *read_bytes);

/* --------------------------------------------------------------- mutants
 * Named, deliberate defects, compiled in only under -DEMBED_MV4I_MUTANTS so a
 * shipped binary cannot select one.  They exist to measure what each check can
 * see; a checker never shown to fail has not been shown to work.  Returns 0, or
 * -1 if this build has no mutants (which is the normal build). */
#define PL_EMBED_MUT_NONE          0
#define PL_EMBED_MUT_NIBBLE        1   /* even weight takes the HIGH nibble  */
#define PL_EMBED_MUT_HALF          2   /* the other half of the beat         */
#define PL_EMBED_MUT_WSUB          3   /* weight sub-region + 1              */
#define PL_EMBED_MUT_TILE          4   /* tile + 1                           */
#define PL_EMBED_MUT_SSUB          5   /* scale sub-region + 1               */
#define PL_EMBED_MUT_SIDX          6   /* scale index within the beat + 1    */
#define PL_EMBED_MUT_BLOCKMAJOR    7   /* beats read block-major, not tile-  */
#define PL_EMBED_MUT_CODEBOOK      8   /* codebook reversed                  */
#define PL_EMBED_MUT_TARGET_MSB    9   /* BFP headroom 14 -> 13              */
#define PL_EMBED_MUT_TRUNCATE     10   /* pack truncates instead of rounding */
#define PL_EMBED_MUT_EXPSIGN      11   /* *exp returned negated              */
#define PL_EMBED_MUT_SCALE_BE     12   /* scales read big-endian             */
#define PL_EMBED_MUT_COUNT        13

int         pl_embed_mv4i_set_mutant(pl_embed_mv4i_t *e, int mutant);
const char *pl_embed_mv4i_mutant_name(int mutant);

#ifdef __cplusplus
}
#endif

#endif /* EMBED_MV4I_H */
