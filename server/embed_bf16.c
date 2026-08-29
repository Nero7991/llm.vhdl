/* server/embed_bf16.c -- see embed_bf16.h.  Nothing here has run against the
 * card.
 *
 * WHY IT INCLUDES ../ref/embed_bf16.c RATHER THAN LINKING IT.  The GGUF row
 * reader has to be readable by BOTH `ref/run9b.c` (the whole-model reference,
 * which must move first) and this host provider, and the two live in
 * directories with different build systems.  Duplicating the parser would be
 * the `m7` mutant by construction: two copies of one misunderstanding that
 * agree with each other.  So there is ONE parser, in `ref/`, and this file
 * makes a single translation unit out of it -- the same shape
 * `server/tests/embed_ref_oracle.c` already uses for `ref/matvec_int4.c` and
 * `ref/run9b.c` uses for the same file.  `server/Makefile` therefore needs no
 * cross-directory object rule.
 *
 * WHAT THIS FILE ADDS ON TOP OF THE READER: the BFP pack, and only that.  The
 * pack is `ref/run9b.c`'s `reg_put`, expressed on the same float64 input with
 * the same three rules, so the host row and the reference row are the same
 * numbers by construction and are CHECKED to be bit-identical by
 * tools/check_embed_bf16.py.
 */
#define _GNU_SOURCE
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "embed_bf16.h"
#include "../ref/embed_bf16.h"

#define TARGET_MSB 14           /* 16 - 2, the BFP headroom this repo uses */

struct pl_embed_bf16_s {
    emb_bf16_t *r;
    double     *v;
    int         n;
    int         mutant;
    char        desc[1152];
};

int pl_embed_bf16_open(const char *gguf_path, const char *tensor,
                       pl_embed_bf16_t **out)
{
    if (!out) return -1;
    *out = NULL;
    pl_embed_bf16_t *e = calloc(1, sizeof *e);
    if (!e) return -1;
    if (emb_bf16_open(gguf_path, tensor, &e->r)) { free(e); return -1; }
    e->n = emb_bf16_ne0(e->r);
    e->v = malloc(sizeof(double) * (size_t)e->n);
    if (!e->v) { emb_bf16_close(e->r); free(e); return -1; }
    snprintf(e->desc, sizeof e->desc, "%s", emb_bf16_describe(e->r));
    *out = e;
    return 0;
}

void pl_embed_bf16_close(pl_embed_bf16_t *e)
{
    if (!e) return;
    emb_bf16_close(e->r);
    free(e->v);
    free(e);
}

int pl_embed_bf16_row(pl_embed_bf16_t *e, int token_id, double *v, int n)
{
    if (!e || !v) return -1;
    return emb_bf16_row(e->r, token_id, v, n);
}

/* The pack.  ref/run9b.c reg_put, value for value:
 *   exp  = 14 - floor(log2(amax))
 *   mant = sat16(floor(v * 2^exp + 0.5))          round half toward +inf
 *   value[j] = mant[j] * 2^(-exp)                 THIS repository's sign
 * An all-zero row takes exp = 0 and all-zero mantissas, which is what reg_put
 * does and is why the checks skip zero rows rather than dividing by them. */
int pl_embed_bf16(void *user, int token_id, int16_t *mant, int n_embd,
                  int32_t *exp)
{
    pl_embed_bf16_t *e = (pl_embed_bf16_t *)user;
    if (!e || !mant || !exp) return -1;
    if (n_embd != e->n) {
        fprintf(stderr, "pl_embed_bf16: caller wants %d elements, %s has ne0 = "
                "%d.  Refused rather than truncated: a short embedding row is a "
                "plausible-looking wrong answer.\n", n_embd,
                emb_bf16_describe(e->r), e->n);
        return -1;
    }
    if (emb_bf16_row(e->r, token_id, e->v, e->n)) return -4;

    int target = TARGET_MSB;
    int truncate = 0;
#ifdef EMBED_BF16_MUTANTS
    if (e->mutant == PL_EMBED_BF16_MUT_TARGET_MSB) target = TARGET_MSB - 1;
    if (e->mutant == PL_EMBED_BF16_MUT_TRUNCATE)   truncate = 1;
#endif

    double amax = 0;
    for (int j = 0; j < e->n; j++) {
        double a = fabs(e->v[j]);
        if (a > amax) amax = a;
    }
    int32_t ex;
    if (amax == 0) {
        ex = 0;
        for (int j = 0; j < e->n; j++) mant[j] = 0;
    } else {
        ex = (int32_t)(target - (int)floor(log2(amax)));
        for (int j = 0; j < e->n; j++) {
            double s = ldexp(e->v[j], ex);
            long long q = truncate ? (long long)s
                                   : (long long)floor(s + 0.5);
            if (q >  32767) q =  32767;
            if (q < -32768) q = -32768;
            mant[j] = (int16_t)q;
        }
    }
#ifdef EMBED_BF16_MUTANTS
    if (e->mutant == PL_EMBED_BF16_MUT_EXPSIGN) ex = -ex;
#endif
    *exp = ex;
    return 0;
}

int      pl_embed_bf16_n_embd (const pl_embed_bf16_t *e) { return e ? e->n : 0; }
int      pl_embed_bf16_n_vocab(const pl_embed_bf16_t *e)
{ return e ? (int)emb_bf16_ne1(e->r) : 0; }
uint64_t pl_embed_bf16_bytes_read(const pl_embed_bf16_t *e)
{ return e ? emb_bf16_bytes_read(e->r) : 0; }
uint64_t pl_embed_bf16_gathers(const pl_embed_bf16_t *e)
{ return e ? emb_bf16_gathers(e->r) : 0; }
const char *pl_embed_bf16_describe(const pl_embed_bf16_t *e)
{ return e ? e->desc : ""; }

static const char *const pl_mut_names[PL_EMBED_BF16_MUT_COUNT] = {
    "clean (control)",
    "bf16 taken as the LOW half of the f32",
    "row + 1",
    "tensor offset treated as absolute",
    "alignment ignored",
    "row read column-major (stride ne1)",
    "tensor found by index 0, not by name",
    "bf16 sign bit dropped",
    "*exp returned negated",
    "BFP headroom TARGET_MSB 14 -> 13",
    "BFP pack truncates instead of rounding",
};

const char *pl_embed_bf16_mutant_name(int m)
{
    if (m < 0 || m >= PL_EMBED_BF16_MUT_COUNT) return "(no such mutant)";
    return pl_mut_names[m];
}

int pl_embed_bf16_set_mutant(pl_embed_bf16_t *e, int m)
{
#ifdef EMBED_BF16_MUTANTS
    if (!e || m < 0 || m >= PL_EMBED_BF16_MUT_COUNT) return -1;
    e->mutant = m;
    /* 1..7 belong to the reader; 8..10 to the pack.  Both numbering spaces are
     * the same numbers on purpose, so the mutation table reads as one list. */
    if (m < EMB_BF16_MUT_COUNT) return emb_bf16_set_mutant(e->r, m);
    return emb_bf16_set_mutant(e->r, EMB_BF16_MUT_NONE);
#else
    (void)e;
    if (m == PL_EMBED_BF16_MUT_NONE) return 0;
    fprintf(stderr, "pl_embed_bf16: mutant %d refused.  A build without "
            "-DEMBED_BF16_MUTANTS cannot select a defect, which is the point\n",
            m);
    return -1;
#endif
}

/* ONE translation unit.  See the banner. */
#include "../ref/embed_bf16.c"
