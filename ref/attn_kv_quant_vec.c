/* ref/attn_kv_quant_vec.c -- vectors and golden for rtl/attn_kv_quant.vhd.
 *
 * Subsystem C, step 4: the KV-cache write-side quantizer.  One head vector of
 * `dim` int16 mantissas sharing ONE source exponent goes in; a block-floating
 * record of `dim` int8 mantissas with one exponent PER 32-element block comes
 * out, together with the write-time `v_ref` min-fold that the read side later
 * uses to align V.
 *
 *     amax[b] = max over the KV_BLOCK values of block b of |x[d]|
 *     sh[b]   = max(0, msb_pos(amax[b]) - 6)          msb_pos(0) = 0
 *     mant[d] = sat8( round_shift(x[d], sh[d / KV_BLOCK]) )
 *     e[b]    = src_exp - sh[b]
 *     v_ref  <- min(v_ref, min over b of e[b])        V vectors only
 *
 * WHY -6, stated because it is the constant the whole record format turns on.
 * An int8 mantissa carries 7 magnitude bits, so the target is msb_pos == 6:
 * that leaves amax in [64, 127] after the shift, i.e. the block uses at least
 * six of its seven magnitude bits.  -5 wastes a bit of every block; -7
 * saturates every block's peak.  Neither is visible in a value check that
 * compares the reference against itself, which is exactly why the double
 * oracle below tests the GRID and not only the values.
 *
 * DOUBLE ORACLE, three independent checks.  The integer path above is what the
 * RTL must match bit for bit, so it cannot also be the only thing that decides
 * whether the recipe is right -- a golden that shares machinery with the DUT
 * certifies broken units, which is how B's l2norm collapse survived 55 passing
 * cases.  Every case is therefore ALSO evaluated in double, from the real
 * values the (x, src_exp) pair denotes, reusing NONE of the integer helpers:
 *
 *   ORACLE 1, the mantissa itself, recomputed EXACTLY in double.  Given the
 *     emitted exponent, mant[d] must equal clip(floor(x_real * 2^e + 0.5)),
 *     evaluated entirely in floating point with no shift, no integer division
 *     and none of mv4i_arith.h.  This is exact rather than approximate, and
 *     that is worth stating: x_real * 2^e = x * 2^-sh with |x| < 2^16 and
 *     sh <= 9, so every intermediate is a dyadic rational a double holds
 *     without loss, and floor(v + 0.5) IS round-half-toward-plus-infinity.
 *     So the bound is ZERO mismatches, not a tolerance.  An earlier version of
 *     this check compared mant[d] against [-128, 127] and was a TAUTOLOGY --
 *     mant is an int8_t, so the compiler folded it away and warned.  A check
 *     the language guarantees has tested nothing.
 *
 *   ORACLE 1b, the same thing as a value error, reported in LSB of the
 *     block's own output grid, so the size of the residual is visible and not
 *     merely its absence.  The bound is 0.5 and it is DERIVED: the only error
 *     source is the round, which lies in (-0.5, +0.5] output LSB with 0.5
 *     attained exactly at a tie.  Unlike gdn_head_emit there is no alignment
 *     floor upstream -- one source exponent, no per-element alignment -- so
 *     there is no second error term and the bound is tight rather than
 *     generous.  Saturated elements are excluded here (their error is a clip,
 *     which is unbounded by construction) but NOT excluded from oracle 1,
 *     which clips in double and so covers them too.
 *
 *   ORACLE 2, grid.  ratio = amax_real * 2^e[b] is the peak magnitude of the
 *     block measured in output LSB.  It must be < 128 (or the peak does not
 *     fit int8), and it must be >= 64 whenever e[b] != src_exp (or the shift
 *     threw away a magnitude bit it did not have to).  This is computed from
 *     the double inputs and the emitted exponent alone and shares nothing with
 *     the integer path, so it is what actually pins the -6.  A quantizer that
 *     is self-consistently wrong about the target msb passes oracle 1 and
 *     fails this one.
 *
 * Saturation is REACHABLE and is not a corner the generator has to contrive:
 * amax = 255 gives sh = 1, and round_shift(255, 1) = 128, one past int8.
 *
 * THE v_ref INIT IS NOT NEUTRAL.  It is +127, a maximum, because the fold is a
 * MINIMUM and the read side right-shifts every V block by (e[b] - v_ref).  An
 * init of 0 makes v_ref 0 for any sequence whose exponents are all positive,
 * so every V block is right-shifted by its full exponent and the cache's
 * precision is destroyed -- while every structural check still passes, because
 * the shifts are still right shifts and nothing overflows.  Case 6 below pins
 * the init by folding a vector whose exponents are all far above zero.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_kv_quant_vec attn_kv_quant_vec.c -lm
 * Usage: ./attn_kv_quant_vec [out.txt] [ncase] [dim] [kv_block]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

/* ---- the core, guarded so a later chain reference can #include it --------
 * Same convention as ref/gdn_head_emit_vec.c and ref/rmsnorm_bf_vec.c: define
 * ATTN_KV_QUANT_INCLUDE before including this file to get the arithmetic
 * without the RNG or main().                                              */

#define ATTN_KVQ_TARGET_MSB 6   /* int8 keeps 7 magnitude bits; see header */

/* Quantize one head vector.  Returns 1 if any element saturated.
 * `mant` receives `dim` int8 values, `e_blk` receives `dim / kv_block` of
 * them.  Nothing here is allowed to use double: this is the bit-exact path. */
static int attn_kv_quant(const int16_t *x, int dim, int kv_block, int src_exp,
                         int8_t *mant, int8_t *e_blk)
{
    int nblk = dim / kv_block;
    int sat_any = 0;

    for (int b = 0; b < nblk; b++) {
        uint64_t amax = 0;
        for (int j = 0; j < kv_block; j++) {
            /* llabs on the promoted int is safe for INT16_MIN, where a bare
             * negation inside int16_t would overflow. */
            uint64_t a = (uint64_t)llabs((long long)x[b * kv_block + j]);
            if (a > amax) amax = a;
        }
        int sh = mv4i_msb_pos_u(amax) - ATTN_KVQ_TARGET_MSB;
        if (sh < 0) sh = 0;

        /* e = src_exp - sh must survive int8.  src_exp is int8 and sh <= 9
         * (an int16 magnitude reaches msb_pos 15), so the worst case is
         * -128 - 9 = -137 and the record's exponent byte cannot hold it.
         * The RTL asserts the same bound; the generator must not emit a case
         * that would trip it, so this is a hard error rather than a clamp. */
        int e = src_exp - sh;
        if (e > 127 || e < -128) {
            fprintf(stderr, "attn_kv_quant: e[%d] = %d does not fit int8 "
                            "(src_exp %d, sh %d)\n", b, e, src_exp, sh);
            exit(2);
        }
        e_blk[b] = (int8_t)e;

        for (int j = 0; j < kv_block; j++) {
            int d = b * kv_block + j;
            int64_t r = mv4i_round_shift((int64_t)x[d], sh);
            if (r >  127) { r =  127; sat_any = 1; }
            if (r < -128) { r = -128; sat_any = 1; }
            mant[d] = (int8_t)r;
        }
    }
    return sat_any;
}

/* The write-time min-fold.  Reset value is +127; see the header for why that
 * is load-bearing rather than a convenient sentinel. */
#define ATTN_KVQ_VREF_INIT 127

static int attn_v_ref_fold(int v_ref, const int8_t *e_blk, int nblk)
{
    for (int b = 0; b < nblk; b++)
        if ((int)e_blk[b] < v_ref) v_ref = (int)e_blk[b];
    return v_ref;
}

#ifndef ATTN_KV_QUANT_INCLUDE

static uint64_t rs = 20260827ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_kv_quant_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 64;
    int DIM   = (argc > 3) ? atoi(argv[3]) : 256;   /* GGUF attention.key_length,
                                                     * identical in 9B and 27B */
    int KVB   = (argc > 4) ? atoi(argv[4]) : 32;    /* C spec 2.1.1, and one
                                                     * 256-bit HBM beat        */
    rs = vec_seed(argc, argv, 5, 20260827ULL);
    if (DIM % KVB != 0) {
        fprintf(stderr, "dim %d is not a multiple of kv_block %d\n", DIM, KVB);
        return 2;
    }
    int NBLK = DIM / KVB;

    int16_t *x     = malloc(sizeof(int16_t) * DIM);
    int8_t  *mant  = malloc(sizeof(int8_t)  * DIM);
    int8_t  *e_blk = malloc(sizeof(int8_t)  * NBLK);
    double  *xd    = malloc(sizeof(double)  * DIM);
    if (!x || !mant || !e_blk || !xd) { perror("malloc"); return 2; }

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d\n", ncase, DIM, KVB);

    double worst_lsb = 0.0;  int worst_case = -1;
    double worst_hi  = 0.0;  int hi_case    = -1;   /* max ratio, must be < 128 */
    double worst_lo  = 1e30; int lo_case    = -1;   /* min ratio where sh > 0   */
    long nsat = 0, nzeroblk = 0, nmis = 0, nclip_dbl = 0;
    int v_ref = ATTN_KVQ_VREF_INIT;

    for (int c = 0; c < ncase; c++) {
        /* Case shapes chosen to hit what is easy to get wrong, not to cover
         * the space.  The first eight are fixed; the rest are random.
         *
         *  0  small values everywhere      -- every sh is 0, so round_shift is
         *                                     a no-op and only the exponent
         *                                     bookkeeping is under test.  Also
         *                                     the ONLY shape where oracle 1's
         *                                     error must be exactly zero.
         *  1  all zero                     -- pins msb_pos(0) = 0, hence
         *                                     sh = max(0, -6) = 0 and
         *                                     e = src_exp.  A quantizer that
         *                                     returns -6 here emits a LEFT
         *                                     shift and a wrong exponent.
         *  2  one block per magnitude      -- block b scaled to ~2^(b+4), so
         *                                     all NBLK exponents differ.  This
         *                                     is the shape that catches a unit
         *                                     that computes ONE exponent for
         *                                     the whole vector, which is the
         *                                     natural thing to write and is
         *                                     bfp_pack's actual semantics.
         *  3  saturation                   -- amax exactly 255 in every block,
         *                                     so sh = 1 and the peak rounds to
         *                                     128 and must clip to 127.
         *  4  INT16_MIN present            -- the asymmetric end of int16, the
         *                                     value whose negation overflows.
         *  5  powers of two and one below  -- msb_pos boundary in both
         *                                     directions, per block.
         *  6  large positive exponents     -- pins the v_ref init: with
         *                                     src_exp = 40 every e[b] is far
         *                                     above 0, so an init of 0 leaves
         *                                     v_ref at 0 and is caught here.
         *  7  negative src_exp             -- e[b] goes below zero, which the
         *                                     record's signed exponent byte
         *                                     must carry.
         */
        int shape = (c < 8) ? c : (int)(rnd32() % 8u);
        int is_v  = (int)(rnd32() & 1u);
        int src_exp;

        switch (shape) {
        case 6: src_exp = 40; break;
        case 7: src_exp = -20 - (int)(rnd32() % 10u); break;
        default: src_exp = 4 + (int)(rnd32() % 24u); break;
        }

        for (int b = 0; b < NBLK; b++) {
            for (int j = 0; j < KVB; j++) {
                int d = b * KVB + j;
                int32_t v;
                switch (shape) {
                case 0: v = (int32_t)(rnd32() % 127u) - 63; break;
                case 1: v = 0; break;
                case 2: {
                    int k = 4 + b;                       /* per-BLOCK magnitude */
                    if (k > 15) k = 15;
                    v = (int32_t)(rnd32() & (uint32_t)((1 << k) - 1));
                    if (j == 0) v = (1 << k) - 1;        /* pin this block's amax */
                    if (rnd32() & 1u) v = -v;
                    break;
                }
                case 3:
                    v = (j == 0) ? 255 : (int32_t)(rnd32() % 256u) - 128;
                    break;
                case 4:
                    v = (j == 0) ? -32768
                                 : (int32_t)(rnd32() % 65535u) - 32767;
                    break;
                case 5: {
                    int k = 1 + (int)(rnd32() % 15u);
                    v = (1 << k) - ((int32_t)(rnd32() % 2u));   /* 2^k or 2^k-1 */
                    if (rnd32() & 1u) v = -v;
                    break;
                }
                default: {
                    int k = (int)(rnd32() % 16u);
                    v = (int32_t)(rnd32() & (uint32_t)((1u << k) - 1u));
                    if (rnd32() & 1u) v = -v;
                    break;
                }
                }
                if (v >  32767) v =  32767;
                if (v < -32768) v = -32768;
                x[d] = (int16_t)v;
            }
        }

        /* ---- the integer path ------------------------------------------- */
        int sat_any = attn_kv_quant(x, DIM, KVB, src_exp, mant, e_blk);
        int v_ref_before = v_ref;
        if (is_v) v_ref = attn_v_ref_fold(v_ref, e_blk, NBLK);

        /* ---- the double oracles, sharing nothing with the above ---------- */
        for (int d = 0; d < DIM; d++)
            xd[d] = ldexp((double)x[d], -src_exp);

        for (int b = 0; b < NBLK; b++) {
            double lsb = ldexp(1.0, -(int)e_blk[b]);
            double amax_d = 0.0;

            for (int j = 0; j < KVB; j++)
                if (fabs(xd[b * KVB + j]) > amax_d) amax_d = fabs(xd[b * KVB + j]);

            for (int j = 0; j < KVB; j++) {
                int d = b * KVB + j;

                /* ORACLE 1: recompute the mantissa in double, exactly.
                 * ldexp twice rather than a multiply, so the scaling is a pure
                 * exponent adjustment and cannot introduce a rounding of its
                 * own.  floor(v + 0.5) is round-half-toward-plus-infinity,
                 * which is what round_shift means; clipping is applied here
                 * too, so saturated elements are covered rather than skipped. */
                double ideal = ldexp(xd[d], (int)e_blk[b]);
                double qd = floor(ideal + 0.5);
                int clipped = 0;
                if (qd >  127.0) { qd =  127.0; clipped = 1; }
                if (qd < -128.0) { qd = -128.0; clipped = 1; }
                if ((int)qd != (int)mant[d]) {
                    if (nmis < 8)
                        fprintf(stderr, "  FAIL oracle 1: case %d elem %d "
                                        "integer path %d, double oracle %d\n",
                                c, d, (int)mant[d], (int)qd);
                    nmis++;
                }
                if (clipped) nclip_dbl++;

                /* ORACLE 1b: the residual, in LSB of THIS block's grid.
                 * Excludes clipped elements only. */
                if (!clipped) {
                    double got = ldexp((double)mant[d], -(int)e_blk[b]);
                    double err = fabs(got - xd[d]) / lsb;
                    if (err > worst_lsb) { worst_lsb = err; worst_case = c; }
                }
            }

            /* ORACLE 2: grid.  amax measured in output LSB. */
            double ratio = amax_d / lsb;
            if (amax_d == 0.0) { nzeroblk++; }
            else {
                if (ratio > worst_hi) { worst_hi = ratio; hi_case = c; }
                /* The >= 64 half applies only where a shift actually happened.
                 * e == src_exp means sh == 0, i.e. the block was already small
                 * enough and there was nothing to gain. */
                if ((int)e_blk[b] != src_exp && ratio < worst_lo) {
                    worst_lo = ratio; lo_case = c;
                }
            }
        }
        if (sat_any) nsat++;

        /* ---- emit -------------------------------------------------------- */
        /* x is int16 and e/mant are int8, so every field fits a VHDL integer
         * and none of them needs the real-valued workaround gdn_head_emit_vec
         * uses for its s40 accumulator. */
        fprintf(f, "%d %d %d %d %d %d\n",
                c, is_v, src_exp, sat_any, v_ref_before, v_ref);
        for (int d = 0; d < DIM;  d++) fprintf(f, "%d ", (int)x[d]);
        fprintf(f, "\n");
        for (int b = 0; b < NBLK; b++) fprintf(f, "%d ", (int)e_blk[b]);
        fprintf(f, "\n");
        for (int d = 0; d < DIM;  d++) fprintf(f, "%d ", (int)mant[d]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_kv_quant_vec: %d cases x %d (%d blocks of %d) -> %s\n",
            ncase, DIM, NBLK, KVB, out);
    fprintf(stderr, "  oracle 1  worst value error: %.6f LSB of the block grid "
                    "(case %d)\n", worst_lsb, worst_case);
    fprintf(stderr, "  oracle 2  peak/LSB ratio: max %.4f (case %d), "
                    "min where sh>0 %.4f (case %d)\n",
            worst_hi, hi_case, (lo_case < 0 ? 0.0 : worst_lo), lo_case);
    fprintf(stderr, "  vectors saturating: %ld   all-zero blocks: %ld   "
                    "elements clipped by the double oracle: %ld   "
                    "final v_ref: %d\n", nsat, nzeroblk, nclip_dbl, v_ref);

    int fail = 0;
    if (nmis) {
        fprintf(stderr, "  FAIL oracle 1: %ld mantissas disagree with the "
                        "double recomputation\n", nmis);
        fail = 1;
    }
    /* > 0.5 and not >= 0.5: a tie rounds to exactly half an LSB of error, and
     * that is the correct behaviour of round-half-toward-plus-infinity, not a
     * defect.  Both sides are exact dyadic rationals in double, so the
     * comparison is exact and no epsilon is needed or wanted. */
    if (worst_lsb > 0.5) {
        fprintf(stderr, "  FAIL oracle 1: over 0.5 LSB, which a single "
                        "round-half cannot explain -- the integer recipe is "
                        "wrong, not the grid\n");
        fail = 1;
    }
    if (worst_hi >= 128.0) {
        fprintf(stderr, "  FAIL oracle 2: a block's peak reaches %.4f output "
                        "LSB and cannot fit int8 -- sh is too small\n", worst_hi);
        fail = 1;
    }
    if (lo_case >= 0 && worst_lo < 64.0) {
        fprintf(stderr, "  FAIL oracle 2: a shifted block's peak is only %.4f "
                        "output LSB, so a magnitude bit was thrown away -- sh "
                        "is too large\n", worst_lo);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: every mantissa reproduced exactly by the double "
                    "oracle, residual <= 0.5 LSB, every block's peak in "
                    "[64, 128) output LSB\n");
    return 0;
}

#endif /* ATTN_KV_QUANT_INCLUDE */
