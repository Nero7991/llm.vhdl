/* server/tests/embed_bf16_dump.c -- print what server/embed_bf16.c gathers, so
 * INDEPENDENT implementations can be compared against it bit for bit.
 *
 * This is not a self-test.  It is the C side of a comparison whose other sides
 * are `gguf-py`'s GGUFReader (a parser nobody here wrote, reading the same
 * file) and -- the sharper one -- `model.input_embed` inside a rung-1 anchor
 * stream, which is llama.cpp's OWN embedding row for the same token, produced
 * by a loader nobody here wrote through a code path that shares nothing with
 * this one.  A round trip through this file's own reader would prove nothing.
 * tools/check_embed_bf16.py drives all of it.
 *
 * Output mirrors server/tests/embed_dump.c line for line, so the two can be
 * diffed by eye and by script:
 *
 *   TOK <id> EXP <x_exp> AMAX <amax as %.17g> OFF <absolute byte offset>
 *   MANT <m0> ... <m_{ne0-1}>
 *   RAW  <hex0> ... <hex_{ne0-1}>        (only with --raw)
 *   VALS <v0> ... <v_{ne0-1}>            (only with --vals, %.17g)
 *
 * NO HARDWARE.  This opens one ordinary file read-only.
 */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../embed_bf16.h"
#include "../../ref/embed_bf16.h"

static void usage(void)
{
    fprintf(stderr,
        "usage: embed_bf16_dump --gguf FILE [--tensor NAME] [--tokens a,b,c]\n"
        "                       [--mutant N] [--raw] [--vals]\n"
        "                       [--list-mutants] [--info]\n");
    exit(2);
}

int main(int argc, char **argv)
{
    const char *path = NULL, *tensor = NULL, *toklist = "0";
    int mutant = 0, want_raw = 0, want_vals = 0, info = 0, i;
    pl_embed_bf16_t *e = NULL;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--gguf") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--tensor") && i + 1 < argc) tensor = argv[++i];
        else if (!strcmp(argv[i], "--tokens") && i + 1 < argc) toklist = argv[++i];
        else if (!strcmp(argv[i], "--mutant") && i + 1 < argc) mutant = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--raw"))  want_raw = 1;
        else if (!strcmp(argv[i], "--vals")) want_vals = 1;
        else if (!strcmp(argv[i], "--info")) info = 1;
        else if (!strcmp(argv[i], "--list-mutants")) {
            int m;
            for (m = 0; m < PL_EMBED_BF16_MUT_COUNT; m++)
                printf("%d %s\n", m, pl_embed_bf16_mutant_name(m));
            return 0;
        }
        else usage();
    }
    if (!path) usage();

    if (pl_embed_bf16_open(path, tensor, &e)) return 1;
    if (mutant) {
        if (pl_embed_bf16_set_mutant(e, mutant)) {
            fprintf(stderr, "embed_bf16_dump: mutant %d refused.  A build "
                    "without\n  -DEMBED_BF16_MUTANTS cannot select a defect, "
                    "which is the point.\n", mutant);
            return 3;
        }
        fprintf(stderr, "embed_bf16_dump: MUTANT ACTIVE -- %s\n",
                pl_embed_bf16_mutant_name(mutant));
    }

    int K = pl_embed_bf16_n_embd(e);
    printf("INFO %s\n", pl_embed_bf16_describe(e));
    printf("SHAPE M %d K %d\n", pl_embed_bf16_n_vocab(e), K);
    if (info) { pl_embed_bf16_close(e); return 0; }

    int16_t  *mant = malloc(sizeof(int16_t) * (size_t)K);
    double   *v    = malloc(sizeof(double)  * (size_t)K);
    uint16_t *raw  = malloc(sizeof(uint16_t) * (size_t)K);
    if (!mant || !v || !raw) return 1;

    char *buf = strdup(toklist), *save = NULL, *tokstr;
    for (tokstr = strtok_r(buf, ",", &save); tokstr;
         tokstr = strtok_r(NULL, ",", &save)) {
        int tok = atoi(tokstr);
        int32_t x_exp = 0;
        double amax = 0;

        if (pl_embed_bf16_row(e, tok, v, K)) return 4;
        if (pl_embed_bf16(e, tok, mant, K, &x_exp)) return 4;
        for (i = 0; i < K; i++) { double a = fabs(v[i]); if (a > amax) amax = a; }

        printf("TOK %d EXP %d AMAX %.17g OFF %llu\n", tok, (int)x_exp, amax,
               (unsigned long long)(pl_embed_bf16_bytes_read(e)));
        fputs("MANT", stdout);
        for (i = 0; i < K; i++) printf(" %d", (int)mant[i]);
        fputc('\n', stdout);
        if (want_raw) {
            /* Straight out of the reader, so the comparison can skip float
             * entirely; bf16 -> f32 is exact, but saying so is not proving it. */
            fputs("RAW", stdout);
            for (i = 0; i < K; i++) {
                /* Recovering the pattern from the float is lossless ONLY if
                 * the low 16 bits of the f32 really are zero, which is the
                 * definition of a bf16-sourced value.  Checked, not assumed:
                 * if the reader ever widened something else, this fires. */
                float f = (float)v[i];
                uint32_t bits;
                memcpy(&bits, &f, 4);
                if (bits & 0xFFFFu) {
                    fprintf(stderr, "\nembed_bf16_dump: element %d of token %d "
                            "has non-zero low 16 bits (0x%08x); that value did "
                            "not come from a bf16\n", i, tok, bits);
                    return 5;
                }
                raw[i] = (uint16_t)(bits >> 16);
                printf(" %04x", raw[i]);
            }
            fputc('\n', stdout);
        }
        if (want_vals) {
            fputs("VALS", stdout);
            for (i = 0; i < K; i++) printf(" %.17g", v[i]);
            fputc('\n', stdout);
        }
    }
    free(buf);

    printf("BYTES %llu GATHERS %llu\n",
           (unsigned long long)pl_embed_bf16_bytes_read(e),
           (unsigned long long)pl_embed_bf16_gathers(e));
    free(mant); free(v); free(raw);
    pl_embed_bf16_close(e);
    return 0;
}
