/* tools/lmhead_window_equiv.c -- do the 15 lm_head descriptor windows compute
 * the same logits as one job would?
 *
 * THE QUESTION.  `rtl/matvec_int4_desc_axi.vhd:683-688` refuses a job whose
 * n_rows exceeds MAXROWS_BFP (17,408), so the 248,320-row `output.weight` has
 * to be issued as 15 windows: 14 x 17,376 + 5,056.  `tools/gen_lmhead_windows.py`
 * proves the windows TILE -- row cover exact, byte cover exact across all 27
 * sub-regions -- but that is arithmetic on the layout.  Nothing had ever
 * COMPUTED the two and compared them.  A byte cover can be exact while the
 * bases are wrong: worklog OI-1 case 19 measured 4 of 100 elements wrong from a
 * mis-aimed base, with the job reporting success.
 *
 * WHAT THIS DOES.  Runs `ref/matvec_int4.c` -- the bit-exact reference the RTL
 * itself is validated against -- once over the whole tensor and once per
 * window, on the same activation vector, and compares the concatenated window
 * outputs to the single-job output ELEMENT BY ELEMENT.
 *
 * WHY RAW MODE.  MODE_BFP normalizes by an ns scanned over the rows present in
 * THAT job, so 15 windows legitimately produce 15 different mantissa grids and
 * a bit comparison of mantissas would be meaningless.  MODE_RAW emits
 * `sat32(round_shift(acc, out_shift))` per row with no cross-row term at all,
 * which is the quantity a window either reproduces or does not.  This is also
 * the mode the lm_head step is issued in (`rtl/llama_top.vhd:737-741`).
 *
 * HOW A WINDOW IS EXPRESSED.  Exactly as `tools/gen_mv4i_desc.py:331-345` does
 * it: advance every weight sub-region base by `skip_tiles * nb * port_b` and
 * every scale sub-region base by `(skip_tiles * nb / grp) * port_b`, and set
 * n_rows to the window length.  Those two lines are the whole descriptor
 * mechanism, and they are what is under test here.
 *
 *   cc -O2 -Wall -Wextra -o lmhead_window_equiv tools/lmhead_window_equiv.c
 *   ./lmhead_window_equiv OUTPUT.weight.mv4i [--maxrows 17408] [--mutate N]
 *
 * --mutate is the teeth check: N selects a defect that MUST make the comparison
 * fail.  A checker never shown to fail has not been shown to work.
 */

#define MV4I_LIB 1
#include "../ref/matvec_int4.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *p, size_t *n)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)len);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) {
        fprintf(stderr, "short read on %s\n", p); exit(2);
    }
    fclose(f); *n = (size_t)len; return b;
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    int maxrows = 17408, mutate = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--maxrows") && i + 1 < argc) maxrows = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mutate") && i + 1 < argc) mutate = atoi(argv[++i]);
        else path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: %s FILE.mv4i [--maxrows N] [--mutate N]\n",
                         argv[0]); return 1; }

    size_t len; uint8_t *img = slurp(path, &len);
    mv4i_file f;
    if (mv4i_parse(&f, img, len)) { fprintf(stderr, "parse failed\n"); return 2; }

    const int M = (int)f.h.M, K = (int)f.h.K, RI = f.h.rows_if;
    const int NB = f.nb, GRP = f.grp, PB = f.port_b;
    const int NPW = f.h.nports_w, NPS = (int)f.h.n_scale_sub;
    printf("file     %s\n", path);
    printf("shape    M=%d K=%d  ROWS_IF=%d nb=%d grp=%d port_b=%d "
           "nports_w=%d n_scale_sub=%d\n", M, K, RI, NB, GRP, PB, NPW, NPS);

    /* Deterministic activation vector: the same xorshift32 seed and range the
     * reference's own --crosscheck uses, so the numbers are reproducible and
     * are not all-positive or tiny. */
    int16_t *x = malloc(sizeof(int16_t) * (size_t)K);
    uint32_t st = 2463534242u;
    for (int k = 0; k < K; k++) {
        st ^= st << 13; st ^= st >> 17; st ^= st << 5;
        x[k] = (int16_t)((int32_t)(st % 20001) - 10000);
    }

    /* ---- the single job */
    mv4i_result full = { malloc(4 * (size_t)M), NULL, NULL, 0, 0, 0, 0 };
    if (!full.y_data) { fprintf(stderr, "oom\n"); return 2; }
    if (mv4i_matvec(&f, x, 0, M, K, MV4I_MODE_RAW, &full)) {
        fprintf(stderr, "whole-tensor job refused\n"); return 2;
    }
    printf("whole    1 job, %d rows, y_exp=%d sat=%d\n", M, full.y_exp,
           full.sat_event);

    /* ---- the windows, plan() of tools/gen_lmhead_windows.py */
    int stride = (maxrows / RI) * RI;
    if (stride <= 0) { fprintf(stderr, "MAXROWS_BFP below one tile\n"); return 2; }
    int nwin = (M + stride - 1) / stride;
    printf("windows  %d, stride %d rows (MAXROWS_BFP=%d, floor to ROWS_IF)\n",
           nwin, stride, maxrows);

    int32_t *win = malloc(4 * (size_t)stride);
    long long checked = 0, bad = 0;
    int first_bad_win = -1, first_bad_row = -1, exp_bad = 0;

    for (int w = 0; w < nwin; w++) {
        int rs = w * stride;
        int nr = (M - rs < stride) ? (M - rs) : stride;
        int skip_tiles = rs / RI;
        long long w_skip = (long long)skip_tiles * NB * PB;
        long long s_skip = ((long long)skip_tiles * NB / GRP) * PB;
        if ((long long)skip_tiles * NB % GRP) {
            fprintf(stderr, "window %d lands mid-superword\n", w); return 2;
        }

        mv4i_file g = f;                       /* same image, shifted bases */
        for (int p = 0; p < NPW; p++) g.h.w_sub_offset[p] += (uint64_t)w_skip;
        for (int q = 0; q < NPS; q++) g.h.s_sub_offset[q] += (uint64_t)s_skip;
        g.h.M = (uint32_t)nr;

        switch (mutate) {
        case 0: break;
        case 1:  /* one weight base off by a single beat, only on window 3 */
            if (w == 3) g.h.w_sub_offset[0] += (uint64_t)PB;
            break;
        case 2:  /* scale skip computed with the WEIGHT stride (grp ignored).
                  * A NO-OP at GRP = 1, where w_skip == s_skip by arithmetic.
                  * Kept, and reported as not biting, because that is exactly
                  * the resolution floor of this check: the `/ grp` divisor in
                  * gen_mv4i_desc.py:337 is UNEXERCISED at this geometry and a
                  * defect in it can only be caught at GRP > 1. */
            for (int q = 0; q < NPS; q++)
                g.h.s_sub_offset[q] += (uint64_t)(w_skip - s_skip);
            break;
        case 3:  /* windows all read from row 0: the "n_rows alone" bug */
            for (int p = 0; p < NPW; p++) g.h.w_sub_offset[p] -= (uint64_t)w_skip;
            for (int q = 0; q < NPS; q++) g.h.s_sub_offset[q] -= (uint64_t)s_skip;
            break;
        case 4:  /* one row short: the window no longer covers the tensor */
            if (nr > 1) nr -= 1;
            break;
        case 5:  /* one SCALE base off by a single beat, only on window 3.
                  * Mutant 2 cannot bite here, so without this one nothing
                  * would show that the scale sub-regions are read at all. */
            if (w == 3) g.h.s_sub_offset[0] += (uint64_t)PB;
            break;
        default: fprintf(stderr, "unknown mutant %d\n", mutate); return 1;
        }

        mv4i_result r = { win, NULL, NULL, 0, 0, 0, 0 };
        if (mv4i_matvec(&g, x, 0, nr, K, MV4I_MODE_RAW, &r)) {
            fprintf(stderr, "window %d refused\n", w); return 2;
        }
        if (r.y_exp != full.y_exp) exp_bad++;

        long long wbad = 0;
        for (int i = 0; i < nr; i++) {
            checked++;
            if (rs + i >= M || win[i] != full.y_data[rs + i]) {
                if (!bad) { first_bad_win = w; first_bad_row = rs + i; }
                bad++; wbad++;
            }
        }
        printf("  win %2d rows %6d .. %6d (%5d)  y_exp=%d  mismatches %lld\n",
               w, rs, rs + nr - 1, nr, r.y_exp, wbad);
    }

    printf("\nelements compared %lld of %d\n", checked, M);
    printf("y_exp differing windows %d\n", exp_bad);
    if (checked != M) {
        printf("FAIL the windows do not cover the tensor exactly\n");
        return 1;
    }
    if (bad || exp_bad) {
        printf("FAIL %lld element mismatches, first at window %d row %d\n",
               bad, first_bad_win, first_bad_row);
        return 1;
    }
    printf("PASS 15-window and single-job logits are bit-identical\n");
    return 0;
}
