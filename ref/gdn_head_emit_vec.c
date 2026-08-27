/* ref/gdn_head_emit_vec.c -- vectors and golden for rtl/gdn_head_emit.vhd.
 *
 * Subsystem B stage 6, SITE 12: fold one head's per-column (o_acc, e_o) pairs
 * onto a common grid and BFP requantize.  The recipe is normative in the
 * design spec's stage 6 and is implemented in ref/gdn_err.c lines 514-523;
 * this file reproduces it EXACTLY and emits it as vectors.
 *
 *     e_h       = min over j of e_o[j]
 *     o_al[j]   = floor_shr(o_acc[j], e_o[j] - e_h)
 *     sh_h      = max(0, msb_pos(max|o_al|) - 14)
 *     o_head[j] = sat16(round_shift(o_al[j], sh_h))
 *     e_head    = e_h - sh_h
 *
 * DOUBLE ORACLE.  The integer path above is what the RTL must match bit for
 * bit, so it cannot be the only check -- a golden that shares machinery with
 * the DUT certifies broken units, which is exactly how B's l2norm collapse
 * survived 55 passing cases.  So every case is ALSO evaluated in double, from
 * the real values the (o_acc, e_o) pairs denote, with no reuse of the integer
 * helpers, and the two are compared.  The integer path is expected to differ
 * from the ideal only by the requantize's own rounding, so the check is that
 * the error stays within the grid rather than that it is zero.
 *
 * Build: cc -O2 -Wall -Wextra -o gdn_head_emit_vec gdn_head_emit_vec.c -lm
 * Usage: ./gdn_head_emit_vec [out.txt] [ncase] [dim]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static uint64_t rs = 20260826ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "gdn_head_emit_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 64;
    int DIM   = (argc > 3) ? atoi(argv[3]) : 128;

    int64_t *o_acc = malloc(sizeof(int64_t) * DIM);
    int     *e_o   = malloc(sizeof(int)     * DIM);
    int64_t *o_al  = malloc(sizeof(int64_t) * DIM);
    int16_t *o_hd  = malloc(sizeof(int16_t) * DIM);
    double  *o_dbl = malloc(sizeof(double)  * DIM);

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d\n", ncase, DIM);

    double worst_rel = 0.0; int worst_case = 0;
    long nsat = 0, nzero = 0;

    for (int c = 0; c < ncase; c++) {
        /* Case shapes chosen to hit the sites that are easy to get wrong,
         * not merely to cover the space:
         *   0  all e_o equal          -- every shj is 0, the alignment is a
         *                               no-op and sh_h alone is exercised
         *   1  all zero               -- amax = 0, msb_pos(0) = 0, so
         *                               sh_h = max(0, -14) = 0.  The
         *                               msb_pos(0) convention is load-bearing
         *                               across B and this pins it here too
         *   2  wide e_o spread        -- large shj, several columns floored
         *                               all the way to 0 or -1
         *   3  NEGATIVE near powers of two.  This is the counterexample that
         *      kills the one-pass shortcut: floor_shr rounds toward minus
         *      infinity, so -(2^k - 1) >> 1 is -2^(k-1) whose msb is k-1,
         *      while msb_pos(|v|) - 1 is k-2.  If the RTL ever computes the
         *      amax exponent without actually aligning, this case catches it
         *   4  saturation             -- values that exceed int16 after the
         *                               requantize, so sat16 is exercised in
         *                               both directions
         *   else random
         */
        int shape = (c < 5) ? c : (int)(rnd32() % 6u);

        for (int j = 0; j < DIM; j++) {
            switch (shape) {
            case 0:
                o_acc[j] = (int64_t)(rnd32() % 2000000u) - 1000000;
                e_o[j]   = 12;
                break;
            case 1:
                o_acc[j] = 0; e_o[j] = (int)(rnd32() % 40u);
                break;
            case 2:
                o_acc[j] = (int64_t)(rnd32() % 2000000u) - 1000000;
                e_o[j]   = (int)(rnd32() % 40u);
                break;
            case 3: {
                int k = 8 + (int)(rnd32() % 24u);
                int64_t mag = ((int64_t)1 << k) - 1;
                o_acc[j] = (rnd32() & 1u) ? -mag : mag;
                e_o[j]   = 10 + (int)(rnd32() % 3u);
                break;
            }
            case 4: {
                /* big enough that the requantize still overflows int16 */
                int64_t mag = ((int64_t)1 << 34) + (int64_t)(rnd32() % 1000u);
                o_acc[j] = (rnd32() & 1u) ? -mag : mag;
                e_o[j]   = 20;
                break;
            }
            default: {
                int k = (int)(rnd32() % 36u);
                int64_t mag = (k >= 63) ? 0 : ((int64_t)rnd32() & (((int64_t)1 << k) - 1));
                o_acc[j] = (rnd32() & 1u) ? -mag : mag;
                e_o[j]   = (int)(rnd32() % 48u) - 8;
                break;
            }
            }
            /* The spec's bound on the output dot is |o_acc| < 2^37 (s38); the
             * RTL asserts it, so the generator must not emit outside it or the
             * testbench would be testing an unreachable state. */
            if (o_acc[j] >=  ((int64_t)1 << 36)) o_acc[j] =  ((int64_t)1 << 36) - 1;
            if (o_acc[j] <= -((int64_t)1 << 36)) o_acc[j] = -((int64_t)1 << 36) + 1;
        }

        /* ---- the integer path, exactly as gdn_err.c stage 6 ---------------- */
        int e_h = e_o[0];
        for (int j = 1; j < DIM; j++) if (e_o[j] < e_h) e_h = e_o[j];

        uint64_t oamax = 0;
        for (int j = 0; j < DIM; j++) {
            int shj = e_o[j] - e_h; if (shj > 63) shj = 63;
            o_al[j] = floor_shr(o_acc[j], shj);
            uint64_t a = (uint64_t)llabs(o_al[j]);
            if (a > oamax) oamax = a;
        }
        int sh_h = msb_pos_u(oamax) - 14; if (sh_h < 0) sh_h = 0;
        int e_head = e_h - sh_h;

        int sat_any = 0;
        for (int j = 0; j < DIM; j++) {
            int64_t r = round_shift(o_al[j], sh_h);
            if (r > 32767 || r < -32768) { sat_any = 1; nsat++; }
            o_hd[j] = sat16(r);
        }
        if (oamax == 0) nzero++;

        /* ---- the double oracle, sharing nothing with the above ------------- */
        double worst_here = 0.0;
        for (int j = 0; j < DIM; j++) {
            o_dbl[j] = ldexp((double)o_acc[j], -e_o[j]);     /* the real value */
            double got = ldexp((double)o_hd[j], -e_head);
            double ref = o_dbl[j];
            /* One LSB of the OUTPUT grid.  Comparing against that, rather than
             * against a fixed relative tolerance, is the point: an error
             * measured in LSB of the unit's own grid cannot see a loss caused
             * by that grid being coarsened, so the denominator here is the
             * grid the result is expressed on and the numerator is the
             * absolute miss against the true value. */
            double lsb = ldexp(1.0, -e_head);
            double err = fabs(got - ref) / lsb;
            if (!sat_any && err > worst_here) worst_here = err;
        }
        if (worst_here > worst_rel) { worst_rel = worst_here; worst_case = c; }

        /* ---- emit ---------------------------------------------------------- */
        fprintf(f, "%d %d %d\n", c, e_head, sat_any);
        /* Emitted with a decimal point because the testbench reads these as
         * VHDL `real`: o_acc spans 38 bits and does not fit a VHDL integer,
         * and textio's read(real) rejects a bare integer literal.  |o_acc| <
         * 2^37 so a double holds it exactly and nothing is lost. */
        for (int j = 0; j < DIM; j++) fprintf(f, "%.1f ", (double)o_acc[j]);
        fprintf(f, "\n");
        for (int j = 0; j < DIM; j++) fprintf(f, "%d ", e_o[j]);
        fprintf(f, "\n");
        for (int j = 0; j < DIM; j++) fprintf(f, "%d ", (int)o_hd[j]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "gdn_head_emit_vec: %d cases x %d -> %s\n", ncase, DIM, out);
    fprintf(stderr, "  worst error vs double oracle: %.4f LSB of the output "
                    "grid (case %d)\n", worst_rel, worst_case);
    fprintf(stderr, "  saturated columns: %ld   all-zero heads: %ld\n", nsat, nzero);
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
     * a large sh.  gdn_y_emit_vec.c had the same too-tight threshold and
     * passed by luck.
     */
    if (worst_rel >= 1.0) {
        fprintf(stderr, "  FAIL: reaches 1.0 LSB, which the alignment floor "
                        "plus the requantize rounding cannot explain -- the "
                        "integer recipe is wrong, not the grid\n");
        return 1;
    }
    fprintf(stderr, "  OK: below the 1.0 LSB bound (align floor + requantize round)\n");
    return 0;
}
