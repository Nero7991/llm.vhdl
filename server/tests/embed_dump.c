/* server/tests/embed_dump.c -- print what server/embed_mv4i.c gathers, so an
 * INDEPENDENT implementation can be compared against it byte for byte.
 *
 * This is not a self-test.  It is the C side of a comparison whose other sides
 * are `tools/embed_gather.py` (numpy, a different addressing expression),
 * `ref/matvec_int4.c`'s `get_widx`/`get_scale` via
 * server/tests/embed_ref_oracle.c (per-element addressing), and the BF16 GGUF
 * (which never touches the packed file).  A round trip through this file's own
 * decoder would prove nothing.  tools/check_embed_c.py drives all of it.
 *
 * Output is one text line per token, deliberately trivial to parse:
 *
 *   TOK <id> EXP <x_exp> VALEXP <val_exp> AMAX <amax> ADDR <t> <rr> <p> <half>
 *            <q> <k> <w_off> <s_off> <nbytes>
 *   MANT <m0> <m1> ... <m_{K-1}>
 *   VALS <v0> <v1> ... <v_{K-1}>          (only with --vals)
 *
 * NO HARDWARE.  This opens one ordinary file read-only.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../embed_mv4i.h"

static void usage(void)
{
    fprintf(stderr,
        "usage: embed_dump --mv4i FILE [--tokens a,b,c] [--recipe wide|d32]\n"
        "                  [--mutant N] [--vals] [--list-mutants] [--info]\n");
    exit(2);
}

int main(int argc, char **argv)
{
    const char *path = NULL, *toklist = "0";
    int recipe = PL_EMBED_RECIPE_WIDE, mutant = 0, want_vals = 0, info = 0;
    pl_embed_mv4i_t *e = NULL;
    int16_t *mant; int32_t *vals;
    int K, i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mv4i") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--tokens") && i + 1 < argc) toklist = argv[++i];
        else if (!strcmp(argv[i], "--recipe") && i + 1 < argc) {
            const char *r = argv[++i];
            if (!strcmp(r, "wide")) recipe = PL_EMBED_RECIPE_WIDE;
            else if (!strcmp(r, "d32")) recipe = PL_EMBED_RECIPE_D32;
            else usage();
        }
        else if (!strcmp(argv[i], "--mutant") && i + 1 < argc) mutant = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vals")) want_vals = 1;
        else if (!strcmp(argv[i], "--info")) info = 1;
        else if (!strcmp(argv[i], "--list-mutants")) {
            int m;
            for (m = 0; m < PL_EMBED_MUT_COUNT; m++)
                printf("%d %s\n", m, pl_embed_mv4i_mutant_name(m));
            return 0;
        }
        else usage();
    }
    if (!path) usage();

    if (pl_embed_mv4i_open(path, recipe, &e)) return 1;
    if (mutant) {
        if (pl_embed_mv4i_set_mutant(e, mutant)) {
            fprintf(stderr, "embed_dump: mutant %d refused.  A build without\n"
                            "  -DEMBED_MV4I_MUTANTS cannot select a defect, which\n"
                            "  is the point; build the check target.\n", mutant);
            return 3;
        }
        fprintf(stderr, "embed_dump: MUTANT ACTIVE -- %s\n",
                pl_embed_mv4i_mutant_name(mutant));
    }
    K = pl_embed_mv4i_n_embd(e);
    printf("INFO %s\n", pl_embed_mv4i_describe(e));
    printf("SHAPE M %d K %d\n", pl_embed_mv4i_n_vocab(e), K);
    if (info) { pl_embed_mv4i_close(e); return 0; }

    mant = (int16_t *)malloc(sizeof(int16_t) * (size_t)K);
    vals = (int32_t *)malloc(sizeof(int32_t) * (size_t)K);
    if (!mant || !vals) return 1;

    {
        char *buf = strdup(toklist), *save = NULL, *tokstr;
        for (tokstr = strtok_r(buf, ",", &save); tokstr;
             tokstr = strtok_r(NULL, ",", &save)) {
            int tok = atoi(tokstr);
            int32_t x_exp = 0, val_exp = 0;
            int t = 0, rr = 0, p = 0, half = 0, q = 0, k = 0;
            uint64_t woff = 0, soff = 0, nb = 0;
            long amax = 0;

            if (pl_embed_mv4i_row_int(e, tok, vals, K, &val_exp)) return 4;
            if (pl_embed_mv4i(e, tok, mant, K, &x_exp)) return 4;
            pl_embed_mv4i_addr(e, tok, &t, &rr, &p, &half, &q, &k,
                               &woff, &soff, &nb);
            for (i = 0; i < K; i++) {
                long a = vals[i] < 0 ? -(long)vals[i] : (long)vals[i];
                if (a > amax) amax = a;
            }
            printf("TOK %d EXP %d VALEXP %d AMAX %ld ADDR %d %d %d %d %d %d "
                   "%llu %llu %llu\n",
                   tok, (int)x_exp, (int)val_exp, amax, t, rr, p, half, q, k,
                   (unsigned long long)woff, (unsigned long long)soff,
                   (unsigned long long)nb);
            fputs("MANT", stdout);
            for (i = 0; i < K; i++) printf(" %d", (int)mant[i]);
            fputc('\n', stdout);
            if (want_vals) {
                fputs("VALS", stdout);
                for (i = 0; i < K; i++) printf(" %ld", (long)vals[i]);
                fputc('\n', stdout);
            }
        }
        free(buf);
    }
    printf("BYTES %llu GATHERS %llu\n",
           (unsigned long long)pl_embed_mv4i_bytes_read(e),
           (unsigned long long)pl_embed_mv4i_gathers(e));
    free(mant); free(vals);
    pl_embed_mv4i_close(e);
    return 0;
}
