/* server/embed_bf16.h -- the BF16 embedding provider: gather one row out of
 * the ORIGINAL GGUF, BF16-widen it exactly, and BFP-pack it to the int16 +
 * one-exponent form `pl_embed_fn` promises.
 *
 * THE SIBLING OF server/embed_mv4i.c, NOT ITS REPLACEMENT.  Both are built,
 * both are shipped, and `llama_server`/`pl_open` choose between them.  The INT4
 * provider stays because every old measurement was taken with it and has to
 * stay reproducible.
 *
 * WHY THE UPGRADE.  The embedding row is an ACTIVATION, not a weight: it is the
 * input to the whole model, and it was INT4 only because it happened to be
 * packed alongside the weight tensors.  MEASURED by TRACK HOSTEMB over 48
 * corner-forced rows, both packed to int16 BFP by the same rule and both scored
 * against the BF16 GGUF row:
 *
 *     packed INT4 -> BFP int16   mean relerr 0.086295
 *     GGUF BF16   -> BFP int16   mean relerr 0.000048        a factor of 1,803
 *
 * re-measured here at 2,151x on a different 48 corner-forced rows: the ratio
 * is a property of the sample, the worst cases are identical, read it as
 * roughly two thousand.
 *
 * THE ORDER WAS THE SAFETY PROPERTY, and it was followed: `ref/run9b.c` reads
 * the GGUF embedding FIRST (`--embed gguf`, now its default), the whole-model
 * reference was re-run on that basis, and only then was this provider written.
 * A host that switched first would be feeding the card an activation no rung of
 * the reference had ever evaluated.  The re-established headline numbers, beside
 * the old ones, are in docs/debugging/2026-08-29_embedding-bf16-upgrade.md.
 *
 * THE READ SHAPE.  ONE contiguous `2 * n_embd`-byte `pread` per token (8,192 B
 * at the 9B shape), against the INT4 provider's TWO 4,096-byte reads.  Same
 * bandwidth, one fewer syscall, no dequantize.  `pread` rather than `mmap` for
 * the reason `embed_mv4i.h` gives and which this file inherits: an SBC does not
 * map 1.9 GiB to answer an 8 KiB question.  MEASURED: the difference in peak
 * RSS between the two providers is a few hundred KiB.  The 2.03 GB figure that
 * appeared in the decision is STORAGE, not resident memory.
 *
 * THE PACK IS `ref/run9b.c`'s `reg_put`, VALUE-FOR-VALUE: shift so the largest
 * magnitude lands in bit 14, round half toward +inf, saturate to int16, and
 * `value[j] = mant[j] * 2^(-exp)`.  A provider that returned the other sign of
 * `exp` would be wrong by 2^(2*exp) and every structural check in this tree
 * would still pass; that is mutant b8 below.
 *
 * NOT VERIFIED: nothing here has run against the card, and nothing in this
 * tree may open /dev/xdma*.
 */
#ifndef EMBED_BF16_PROVIDER_H
#define EMBED_BF16_PROVIDER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pl_embed_bf16_s pl_embed_bf16_t;

/* Open a GGUF and locate `tensor` (NULL means "token_embd.weight").
 * Returns 0, or negative with a message on stderr. */
int  pl_embed_bf16_open(const char *gguf_path, const char *tensor,
                        pl_embed_bf16_t **out);
void pl_embed_bf16_close(pl_embed_bf16_t *e);

/* The pl_embed_fn.  `user` is the pl_embed_bf16_t *. */
int  pl_embed_bf16(void *user, int token_id,
                   int16_t *mant, int n_embd, int32_t *exp);

/* The row before the pack, as float64.  Exposed because the two failure modes
 * -- wrong bytes and wrong pack -- are worth separating, and because the
 * bit-exact oracle (llama.cpp's own embedding rows) lives at this level. */
int  pl_embed_bf16_row(pl_embed_bf16_t *e, int token_id, double *v, int n);

int      pl_embed_bf16_n_embd (const pl_embed_bf16_t *e);
int      pl_embed_bf16_n_vocab(const pl_embed_bf16_t *e);
uint64_t pl_embed_bf16_bytes_read(const pl_embed_bf16_t *e);
uint64_t pl_embed_bf16_gathers   (const pl_embed_bf16_t *e);
const char *pl_embed_bf16_describe(const pl_embed_bf16_t *e);

/* --------------------------------------------------------------- mutants
 * Compiled in only under -DEMBED_BF16_MUTANTS.  1..7 are the GGUF-reader
 * mutants of ref/embed_bf16.h, reachable through this provider; 8..10 are the
 * pack-stage ones, which the reader cannot express. */
#define PL_EMBED_BF16_MUT_NONE        0
#define PL_EMBED_BF16_MUT_EXPSIGN     8   /* *exp returned negated            */
#define PL_EMBED_BF16_MUT_TARGET_MSB  9   /* BFP headroom 14 -> 13            */
#define PL_EMBED_BF16_MUT_TRUNCATE   10   /* pack truncates, not rounds       */
#define PL_EMBED_BF16_MUT_COUNT      11

int         pl_embed_bf16_set_mutant(pl_embed_bf16_t *e, int mutant);
const char *pl_embed_bf16_mutant_name(int mutant);

#ifdef __cplusplus
}
#endif

#endif /* EMBED_BF16_PROVIDER_H */
