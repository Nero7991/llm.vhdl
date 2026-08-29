/* server/tests/embed_ref_oracle.c -- THE ORACLE THAT IS NOT MINE.
 *
 * This reproduces `ref/run9b.c`'s embedding stage exactly:
 *
 *     embed(tok, RX):  for k in 0..HIDDEN-1: t[k] = w_deq(&m->f, tok, k)
 *     reg_put(RX, t):  e = floor(log2(amax)); exp = 14 - e;
 *                      mant[i] = sat16(floor(v[i] * 2^exp + 0.5))
 *     w_deq(f, r, k):  ldexp(codebook[get_widx(f,r,k)] * get_scale(f,r,k/32)
 *                            / 32768.0, -w_exp)
 *
 * and it does so by INCLUDING `ref/matvec_int4.c` with MV4I_LIB defined, which
 * is what `ref/run9b.c` itself does.  So the addressing here is
 * `get_widx`/`get_scale` -- per element, recomputing the sub-region and the beat
 * for every weight -- and it shares no line of code with
 * `server/embed_mv4i.c`'s two-contiguous-reads gather.
 *
 * WHY THIS PARTICULAR ORACLE.  `ref/run9b.c` is the whole-model 9B reference:
 * rung 2 (INT4 weights, f32 activations) and rung 3 (INT4 weights, int16 BFP
 * activations), the artefact that makes a first token falsifiable.  Its
 * measured results -- 0.1252 relative RMS at the logits for the weight format,
 * 0.00313 more for the activation format, all three rungs agreeing on the next
 * token at all five reference positions -- were obtained WITH this embedding.
 * So agreeing with this function is not merely agreeing with another decoder:
 * it is agreeing with the activation the rest of the pipeline was verified
 * against.  That is the evidence behind the which-copy decision in
 * docs/debugging/2026-08-29_host-embedding-gather.md section 5.
 *
 * NOTHING IS EDITED IN ref/.  This file only includes it.
 * NO HARDWARE: one ordinary file, mapped read-only.
 */
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MV4I_LIB
#include "../../ref/matvec_int4.c"   /* mv4i_parse, get_widx, get_scale */

/* ref/run9b.c::w_deq, character for character. */
static double w_deq(const mv4i_file *f, int r, int k)
{
    int8_t cb = f->h.codebook[get_widx(f, r, k)];
    uint16_t sc = get_scale(f, r, k / MV4I_BLOCK);
    return ldexp((double)cb * (double)sc / 32768.0, -f->h.w_exp);
}

/* ref/run9b.c::reg_put, bfp branch, character for character. */
static int reg_put(const double *v, int n, int16_t *m)
{
    double amax = 0;
    int i, exp;
    for (i = 0; i < n; i++) { double a = fabs(v[i]); if (a > amax) amax = a; }
    if (amax == 0) { for (i = 0; i < n; i++) m[i] = 0; return 0; }
    exp = 14 - (int)floor(log2(amax));
    for (i = 0; i < n; i++) {
        double s = ldexp(v[i], exp);
        long long q = (long long)floor(s + 0.5);       /* half toward +inf */
        m[i] = mv4i_sat16(q);
    }
    return exp;
}

int main(int argc, char **argv)
{
    const char *path = NULL, *toklist = "0";
    int i, fd, K;
    struct stat st;
    const uint8_t *img;
    mv4i_file f;
    double *v; int16_t *m;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mv4i") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--tokens") && i + 1 < argc) toklist = argv[++i];
        else { fprintf(stderr, "usage: embed_ref_oracle --mv4i F [--tokens a,b]\n");
               return 2; }
    }
    if (!path) { fprintf(stderr, "embed_ref_oracle: --mv4i is required\n"); return 2; }

    fd = open(path, O_RDONLY);
    if (fd < 0 || fstat(fd, &st)) { perror(path); return 1; }
    img = (const uint8_t *)mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (img == MAP_FAILED) { perror("mmap"); return 1; }
    if (mv4i_parse(&f, img, (size_t)st.st_size)) {
        fprintf(stderr, "embed_ref_oracle: %s: mv4i_parse refused it\n", path);
        return 1;
    }
    K = (int)f.h.K;
    printf("SHAPE M %u K %d\n", f.h.M, K);
    v = (double *)malloc(sizeof(double) * (size_t)K);
    m = (int16_t *)malloc(sizeof(int16_t) * (size_t)K);
    if (!v || !m) return 1;

    {
        char *buf = strdup(toklist), *save = NULL, *s;
        for (s = strtok_r(buf, ",", &save); s; s = strtok_r(NULL, ",", &save)) {
            int tok = atoi(s), exp, k;
            if (tok < 0 || (uint32_t)tok >= f.h.M) {
                fprintf(stderr, "embed_ref_oracle: token %d outside 0 .. %u\n",
                        tok, f.h.M - 1);
                return 4;
            }
            for (k = 0; k < K; k++) v[k] = w_deq(&f, tok, k);
            exp = reg_put(v, K, m);
            printf("TOK %d EXP %d\n", tok, exp);
            fputs("MANT", stdout);
            for (k = 0; k < K; k++) printf(" %d", (int)m[k]);
            fputc('\n', stdout);
        }
        free(buf);
    }
    free(v); free(m);
    return 0;
}
