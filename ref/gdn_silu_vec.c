/* gdn_silu_vec -- reference vectors for rtl/gdn_silu.vhd, spec 2.1.3.
 *
 *   x_q12 = Q12(sm, e)                                  -- site 3's rule
 *   sm'   = round_shift( sm * sigma_q15(x_q12), 15 )    -- exponent PRESERVED
 *
 * WHY sigma is a Q12-IN / Q15-OUT function and not fx_sigmoid_q.
 * fx.h's fx_sigmoid_q takes one q for both input and output.  2.1 pins silu's
 * ARGUMENT at Q12 (its error does not compound, unlike the scalar path's,
 * which 2.1.3 moved to Q18) and the sigma OUTPUT at Q15, so the shipped
 * Q12-in/Q12-out table is wrong at the output end by 3 bits.  The B spec's
 * reuse table already flags this as a 3 deliverable: "Q12 in/out as shipped;
 * 2.1 pins beta and the decay factor at Q15 out, so the table must be
 * regenerated".  This is that regeneration, done as a mixed-precision read of
 * the SAME Q30 table rather than a second table: the ROM is Q30 either way,
 * only the index grid and the final rounding differ.
 *
 * The golden is a DOUBLE oracle, not a second integer path.  A reference that
 * recomputed the same integer recipe would agree with a wrong recipe.
 *
 * Build: cc -O2 -Wall -Wextra -o gdn_silu_vec gdn_silu_vec.c -lm
 * Usage: ./gdn_silu_vec <out.txt> [ncase] [n] [seed] [arg_q]
 *
 * arg_q defaults to 12, which 2.1 pins.  It is a parameter for the same
 * reason SP_Q was in gdn_scalar: so the cost of the pinned choice is measured
 * against the alternatives rather than asserted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"
#include "fx.h"

#define round_shift(v, sh) mv4i_round_shift((v), (sh))
#define floor_shr(v, sh)   mv4i_floor_shr((v), (sh))

/* 2.1.3 site 3, the Q conversion rule, stated for BOTH branches because e is
 * data-dependent and unbounded in both directions. */
static int ARG_Q = 12;

static int32_t to_q12(int64_t x, int e)
{
    int sh = e - ARG_Q;
    if (sh >= 0) {
        if (sh > 62) return 0;
        return (int32_t)round_shift(x, sh);
    } else {
        int k = -sh;
        if (k > 40) return (x > 0) ? INT32_MAX : (x < 0 ? INT32_MIN : 0);
        int64_t v = x << k;
        if (v >  INT32_MAX) return INT32_MAX;
        if (v <  INT32_MIN) return INT32_MIN;
        return (int32_t)v;
    }
}

/* sigma: Q12 argument in, Q15 out, off the shared Q30 table. */
static int32_t sigma_q15_from_q12(int32_t z_q12)
{
    const int64_t one12 = 1LL << ARG_Q;
    if ((int64_t)z_q12 <= -16LL * one12) return 0;
    if ((int64_t)z_q12 >=  16LL * one12) return 1 << 15;

    int64_t offset = (int64_t)z_q12 + 16LL * one12;
    int64_t idx_fp = offset * 16;
    int k = (int)(idx_fp >> ARG_Q);
    if (k > 511) k = 511;
    if (k < 0)   k = 0;
    int64_t frac = idx_fp - ((int64_t)k << ARG_Q);

    int64_t lo = _fx_sig_lut_q[k];
    int64_t hi = _fx_sig_lut_q[k + 1];
    int64_t interp_q30 = lo + (((hi - lo) * frac) >> ARG_Q);

    int64_t r = round_shift(interp_q30, 30 - 15);
    if (r < 0) r = 0;
    if (r > (1LL << 15)) r = 1LL << 15;
    return (int32_t)r;
}

static uint64_t rs;
static uint32_t rnd(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "gdn_silu_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 256;
    int n     = (argc > 3) ? atoi(argv[3]) : 128;
    rs        = (argc > 4) ? strtoull(argv[4], NULL, 10) : 20260826ULL;
    ARG_Q     = (argc > 5) ? atoi(argv[5]) : 12;
    if (rs == 0) rs = 1;
    fx_init();

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d\n", ncase, n);

    /* TWO metrics, because one of them is a trap.
     * Relative error alone reports 33% on a result whose true value is 1.5 LSB
     * of its own grid -- that is the quantizer working correctly, not an
     * error, and quoting it would be the same mistake as measuring a grid
     * defect in LSB of the grid it corrupts.  So: absolute error in LSB is the
     * honest metric for a quantizer, and relative error is reported ONLY where
     * the magnitude is well clear of the grid (>= 16 LSB), where it means
     * something. */
    double worst_lsb = 0.0; int wl_case = -1;
    double worst_rel = 0.0; int wr_case = -1; long nrel = 0;
    long nz = 0, nsat = 0;

    for (int c = 0; c < ncase; c++) {
        /* e is swept over a band wide enough to exercise BOTH branches of the
         * Q12 rule and both saturation rails, not just the comfortable middle.
         * A generator that only produces mid-range e certifies nothing about
         * the guards, which is the lesson the gdn_scalar work already paid for. */
        int e;
        int sel = c % 8;
        if      (sel == 0) e = -30;          /* deep left shift, saturating */
        else if (sel == 1) e = -12;
        else if (sel == 2) e =  12;          /* sh = 0, the identity branch */
        else if (sel == 3) e =  40;          /* deep right shift, flushes to 0 */
        else               e = (int)(rnd() % 61) - 30;

        int16_t sm[4096];
        for (int i = 0; i < n; i++) {
            uint32_t r = rnd();
            /* a mix of full-range and small magnitudes: silu's interesting
             * region is near zero, and a uniform draw over int16 almost never
             * lands there once e shifts it. */
            if ((r & 3) == 0) sm[i] = (int16_t)((int32_t)(r >> 16) % 64);
            else              sm[i] = (int16_t)(r >> 16);
        }

        fprintf(f, "%d %d\n", c, e);
        for (int i = 0; i < n; i++) fprintf(f, "%d ", sm[i]);
        fprintf(f, "\n");

        for (int i = 0; i < n; i++) {
            int32_t xq  = to_q12(sm[i], e);
            if (xq == INT32_MAX || xq == INT32_MIN) nsat++;
            int32_t sig = sigma_q15_from_q12(xq);
            int64_t y   = round_shift((int64_t)sm[i] * sig, 15);
            /* 2.1.3: |silu(x)| <= |x| since sigma <= 1, so y cannot leave
             * int16 on the same grid.  Checked, not assumed. */
            if (y > 32767 || y < -32768) {
                fprintf(stderr, "gdn_silu_vec: y left int16 at case %d i %d: "
                        "%lld from sm %d sig %d\n", c, i, (long long)y,
                        sm[i], sig);
                return 2;
            }
            if (y == 0 && sm[i] != 0) nz++;
            fprintf(f, "%d ", (int)y);

            /* double oracle, different number system */
            double xd = ldexp((double)sm[i], -e);
            double yd = xd / (1.0 + exp(-xd));
            double yd_lsb = ldexp(yd, e);            /* the true value, in LSB */
            double lsb = fabs((double)y - yd_lsb);
            if (lsb > worst_lsb) { worst_lsb = lsb; wl_case = c; }
            if (fabs(yd_lsb) >= 16.0) {
                double rel = fabs((double)y - yd_lsb) / fabs(yd_lsb);
                nrel++;
                if (rel > worst_rel) { worst_rel = rel; wr_case = c; }
            }
        }
        fprintf(f, "\n");
    }
    fclose(f);
    fprintf(stderr, "gdn_silu_vec: %d cases x %d -> %s (ARG_Q=%d)\n",
            ncase, n, out, ARG_Q);
    fprintf(stderr, "  worst abs err vs double oracle: %.4f LSB (case %d)\n",
            worst_lsb, wl_case);
    fprintf(stderr, "  worst rel err where |y| >= 16 LSB: %.6e (case %d, %ld samples)\n",
            worst_rel, wr_case, nrel);
    fprintf(stderr, "  Q12 saturations: %ld   nonzero flushed to zero: %ld\n", nsat, nz);
    return 0;
}
