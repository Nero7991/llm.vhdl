/* ref/gdn_y_emit_vec.c -- vectors and golden for rtl/gdn_y_emit.vhd.
 *
 * Subsystem B SITE 13: the gated-norm product and the 24-head renormalization
 * to a single y_exp.  Per the spec's step 7 and build_norm_gated
 * (qwen35.cpp:247-255), each head is gated AFTER the norm, and all heads on a
 * card are then folded onto one exponent because ssm_out takes a single scale
 * for the whole 24 x 128 vector.
 *
 *     p[h][j]  = o_mant[h][j] * z_mant[h][j]        int16 * int16, exact in s32
 *     e_p[h]   = o_exp[h] + z_exp[h]
 *     e_y_raw  = min over h of e_p[h]
 *     p_al     = floor_shr(p[h][j], e_p[h] - e_y_raw)
 *     sh       = max(0, msb_pos(max|p_al|) - 14)
 *     y[h][j]  = sat16(round_shift(p_al, sh))
 *     y_exp    = e_y_raw - sh
 *
 * The head count is 24, NOT 16.  48 GDN value heads split by head across 2
 * cards.  16 is the KEY head count and is a different quantity.  Both head
 * types are 128 wide so nothing catches the confusion structurally; the spec
 * said 16 in two places until 2026-08-26.
 *
 * DOUBLE ORACLE.  The integer path above is what the RTL must match bit for
 * bit, so it cannot also be the only correctness check -- a golden sharing
 * machinery with the DUT certifies broken units, which is how B's l2norm
 * collapse survived 55 passing cases.  Every case is therefore ALSO evaluated
 * in double from the real values the (mant, exp) pairs denote, reusing none of
 * the integer helpers, and the two are compared in LSB of the OUTPUT grid.
 *
 * Build: cc -O2 -Wall -Wextra -o gdn_y_emit_vec gdn_y_emit_vec.c -lm
 * Usage: ./gdn_y_emit_vec [out.txt] [ncase] [heads] [dim]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

#define floor_shr(v, s)   mv4i_floor_shr((v), (s))
#define round_shift(v, s) mv4i_round_shift((v), (s))

static int msb_pos_u(uint64_t v){ int p = 0; while (v >>= 1) p++; return p; }

static int16_t sat16(int64_t v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

static uint64_t rs = 20260827ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }
/* uniform int16 including -32768, which is the value the asymmetric range
 * makes special: (-32768)^2 = 2^30 exactly, the attainable product maximum. */
static int16_t r16(void){ return (int16_t)(rnd32() & 0xFFFFu); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "gdn_y_emit_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 48;
    int H     = (argc > 3) ? atoi(argv[3]) : 24;
    int D     = (argc > 4) ? atoi(argv[4]) : 128;
    int N     = H * D;

    int16_t *om = malloc(sizeof(int16_t) * N);
    int16_t *zm = malloc(sizeof(int16_t) * N);
    int     *ep = malloc(sizeof(int)     * H);
    int64_t *al = malloc(sizeof(int64_t) * N);
    int16_t *y  = malloc(sizeof(int16_t) * N);

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d\n", ncase, H, D);

    double worst = 0.0; int worst_case = 0;
    int worst_sh = 0, worst_shape = 0, worst_maxalign = 0;
    double shape_worst[8] = {0};
    long nsat = 0, nzero = 0, nmin16 = 0;

    for (int c = 0; c < ncase; c++) {
        /* Shapes chosen for the sites that are easy to get wrong:
         *   0  all e_p equal        -- every alignment shift is 0
         *   1  all zero             -- amax = 0, msb_pos(0) = 0, sh = 0.  The
         *                             msb_pos(0) convention is load-bearing
         *                             across B, so it is pinned here too
         *   2  wide e_p spread      -- large shifts, whole heads floored away
         *   3  both operands -32768 -- the product maximum 2^30 EXACTLY, which
         *                             is the case a strict (rather than
         *                             inclusive) width bound gets wrong.  That
         *                             off-by-one shipped in rmsnorm_bf's
         *                             assert on 2026-08-26
         *   4  negative near powers of two -- the counterexample that kills
         *                             the one-pass amax shortcut, since
         *                             floor_shr rounds toward minus infinity
         *   5  saturation           -- exceeds int16 after the requantize
         *   else random
         */
        int shape = (c < 6) ? c : (int)(rnd32() % 7u);

        for (int h = 0; h < H; h++) {
            switch (shape) {
            case 0: ep[h] = 14; break;
            case 1: ep[h] = (int)(rnd32() % 30u); break;
            case 2: ep[h] = (int)(rnd32() % 45u) - 10; break;
            case 3: ep[h] = 12; break;
            case 4: ep[h] = 10 + (int)(rnd32() % 3u); break;
            case 5: ep[h] = 8; break;
            default: ep[h] = (int)(rnd32() % 40u) - 8; break;
            }
            for (int j = 0; j < D; j++) {
                int i = h*D + j;
                switch (shape) {
                case 1: om[i] = 0; zm[i] = r16(); break;
                case 3: om[i] = -32768; zm[i] = -32768; nmin16++; break;
                case 4: {
                    int k = 4 + (int)(rnd32() % 10u);
                    int16_t mag = (int16_t)(((int)1 << k) - 1);
                    om[i] = (rnd32() & 1u) ? (int16_t)(-mag) : mag;
                    zm[i] = (int16_t)(1 + (rnd32() % 3u));
                    break;
                }
                case 5: om[i] = (rnd32() & 1u) ? -32768 : 32767;
                        zm[i] = (rnd32() & 1u) ? -32768 : 32767; break;
                default: om[i] = r16(); zm[i] = r16(); break;
                }
            }
        }

        /* ---- the integer path -------------------------------------------- */
        int e_y_raw = ep[0];
        for (int h = 1; h < H; h++) if (ep[h] < e_y_raw) e_y_raw = ep[h];

        uint64_t amax = 0;
        for (int h = 0; h < H; h++) {
            int shj = ep[h] - e_y_raw; if (shj > 63) shj = 63;
            for (int j = 0; j < D; j++) {
                int i = h*D + j;
                int64_t p = (int64_t)om[i] * (int64_t)zm[i];  /* exact in s32 */
                al[i] = floor_shr(p, shj);
                uint64_t a = (uint64_t)llabs(al[i]);
                if (a > amax) amax = a;
            }
        }
        int sh = msb_pos_u(amax) - 14; if (sh < 0) sh = 0;
        int y_exp = e_y_raw - sh;

        int sat_any = 0;
        for (int i = 0; i < N; i++) {
            int64_t r = round_shift(al[i], sh);
            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }
            y[i] = sat16(r);
        }
        if (amax == 0) nzero++;

        /* ---- the double oracle, sharing nothing with the above ------------ */
        double here = 0.0;
        for (int h = 0; h < H; h++) {
            for (int j = 0; j < D; j++) {
                int i = h*D + j;
                double ref = ldexp((double)om[i], -0) * ldexp((double)zm[i], -0);
                ref = ldexp(ref, -ep[h]);            /* the real gated product */
                double got = ldexp((double)y[i], -y_exp);
                double lsb = ldexp(1.0, -y_exp);
                double e = fabs(got - ref) / lsb;
                if (!sat_any && e > here) here = e;
            }
        }
        if (here > worst) { worst = here; worst_case = c; worst_sh = sh;
                            worst_shape = shape;
                            worst_maxalign = 0;
                            for (int h = 0; h < H; h++) {
                                int d = ep[h] - e_y_raw;
                                if (d > worst_maxalign) worst_maxalign = d;
                            } }
        if (here > shape_worst[shape]) shape_worst[shape] = here;

        /* ---- emit --------------------------------------------------------- */
        fprintf(f, "%d %d %d\n", c, y_exp, sat_any);
        for (int h = 0; h < H; h++) fprintf(f, "%d ", ep[h]);
        fprintf(f, "\n");
        for (int i = 0; i < N; i++) fprintf(f, "%d ", (int)om[i]);
        fprintf(f, "\n");
        for (int i = 0; i < N; i++) fprintf(f, "%d ", (int)zm[i]);
        fprintf(f, "\n");
        for (int i = 0; i < N; i++) fprintf(f, "%d ", (int)y[i]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "gdn_y_emit_vec: %d cases x %d heads x %d -> %s\n",
            ncase, H, D, out);
    fprintf(stderr, "  worst error vs double oracle: %.4f LSB of the output "
                    "grid (case %d)\n", worst, worst_case);
    fprintf(stderr, "  saturated elements: %ld   all-zero cases: %ld   "
                    "(-32768)^2 products: %ld\n", nsat, nzero, nmin16);
    fprintf(stderr, "  worst case had shape %d, sh = %d, max alignment shift = %d\n",
            worst_shape, worst_sh, worst_maxalign);
    for (int k = 0; k < 7; k++)
        fprintf(stderr, "    shape %d worst: %.4f LSB\n", k, shape_worst[k]);
    /* THE BOUND, derived rather than guessed.  There are TWO error sources,
     * not one, and the first version of this check counted only the second:
     *
     *   1. the alignment FLOOR loses up to (2^shj - 1)/2^shj < 1 LSB of the
     *      ALIGNED grid, and one aligned LSB is 2^-sh LSB of the output grid
     *   2. the requantize rounds, contributing <= 0.5 output LSB, and exactly
     *      0 when sh = 0 because then it is a no-op
     *
     * so the total is < 2^-sh + 0.5*[sh > 0], which is < 1.0 output LSB in
     * every case and reaches it only in the limit.  Measured: the worst case
     * has sh = 0 and a maximum alignment shift of 2, giving 3/4 of an aligned
     * LSB with NO requantize rounding at all -- 0.75, entirely source 1.
     *
     * A 0.5 threshold therefore does not test the recipe, it tests the seed:
     * it passes only when the worst element happens to land at shj = 0 or at
     * a large sh.  gdn_head_emit_vec.c had the same too-tight threshold and
     * passed by luck.
     */
    if (worst >= 1.0) {
        fprintf(stderr, "  FAIL: reaches 1.0 LSB, which the alignment floor "
                        "plus the requantize rounding cannot explain -- the "
                        "integer recipe is wrong\n");
        return 1;
    }
    fprintf(stderr, "  OK: below the 1.0 LSB bound (align floor + requantize round)\n");
    return 0;
}
