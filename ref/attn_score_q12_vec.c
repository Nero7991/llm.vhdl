/* ref/attn_score_q12_vec.c -- vectors and golden for rtl/attn_score_q12.vhd.
 *
 * Subsystem C, steps 5b and 6: take the per-block partial dot products of one
 * query head against one cached key, align them onto a common grid, sum them,
 * and convert the result to Q12 at the point of production.
 *
 *     e_min     = min over b of e_k[b]
 *     score     = sum over b of floor_shr(partial[b], e_k[b] - e_min)
 *     score_exp = q_exp + e_min + KQ_SHIFT          kq_scale = 2^-KQ_SHIFT
 *     sh        = score_exp - 12
 *     score_q12 = round_shift(score, sh)            when sh >= 0
 *               = sat32( score << (-sh) )           when sh <  0
 *
 * WHY THE Q12 CONVERSION IS HERE AND NOT LATER, which is the whole reason this
 * is a unit rather than three lines inside the sweep.  score_exp contains
 * e_min, and e_min is the minimum over the blocks of ONE cached position, so it
 * differs from position to position.  Raw scores from different positions are
 * therefore expressed on different grids and are NOT comparable -- they cannot
 * feed the online softmax's running maximum.  Converting at the point of
 * production is what makes them comparable, and doing it anywhere later is
 * simply wrong.
 *
 * WHY IT PAIRS WITH attn_kv_quant.  e_k[] is exactly the 8-byte header
 * attn_kv_quant emits, and it is emitted BEFORE any mantissa precisely so that
 * this unit can know e_min before the first partial arrives.  Header-first is
 * not a layout convenience; it is what lets the alignment happen on the fly
 * with no buffer for the partials.
 *
 * WHY KQ_SHIFT IS 4 AND NOT A FREE PARAMETER.  kq_scale = 1/sqrt(head_dim) and
 * head_dim is 256 in BOTH target models (rtl/model_cfg_pkg.vhd: attn_head_dim
 * is 256 for QWEN35_9B and QWEN38_27B alike), so 1/sqrt(256) = 1/16 = 2^-4 and
 * the scale folds into the exponent with no multiply at all.  That is a
 * property of this head_dim, not a general one: a head_dim that is not an even
 * power of two makes kq_scale irrational and forces a real multiply.  The
 * generator takes it as a parameter so that assumption is visible.
 *
 * BOTH BRANCHES OF STEP 6 ARE REACHABLE and the generator forces each.  q_exp
 * is data-dependent (it comes out of the QK-norm, whose shift_total is not
 * derivable from any interface port), so sh is unbounded in both directions.
 * A unit that implements only the right-shift branch passes on plausible data.
 *
 * DOUBLE ORACLE, three independent checks, none sharing the integer path:
 *
 *   ORACLE 1, the whole chain against floating point.  The true score is
 *     2^-KQ_SHIFT * sum over b of partial[b] * 2^-(q_exp + e_k[b]), summed in
 *     double with no alignment, no floor and no shift, and the answer is
 *     compared in Q12 counts.  The bound is DERIVED per case rather than
 *     chosen, because it is not a constant: the alignment is a FLOOR, so each
 *     of the NBLK blocks loses up to one LSB of the aligned grid, and one
 *     aligned LSB is 2^(12 - score_exp) Q12 counts.  The Q12 round adds 0.5
 *     when sh >= 0 and exactly 0 when sh < 0, because a left shift is exact.
 *     So the bound is  NBLK * 2^(12 - score_exp) + 0.5*[sh >= 0]  and it grows
 *     as the output grid gets FINER than the input, which is exactly the
 *     regime the left-shift branch lives in.  A fixed tolerance would either
 *     be vacuous there or fail on correct data here; this is the same trap
 *     gdn_y_emit_vec.c fell into with a threshold that passed by luck.
 *
 *   ORACLE 3, the DIRECTION of the alignment.  Oracle 1's bound is derived to
 *     ADMIT NBLK alignment floors, so it cannot tell a floor from a round --
 *     a round is strictly inside the bound.  That was found by mutating this
 *     file: replacing floor_shr with round_shift in the alignment SURVIVED
 *     oracles 1 and 2.  Since floor_shr rounds toward minus infinity and
 *     round_shift does not, the two are separated by an INEQUALITY rather
 *     than a magnitude: the aligned sum must satisfy
 *         true_aligned - NBLK  <  score  <=  true_aligned
 *     where true_aligned is the same sum evaluated in double with no floor.
 *     A round violates the upper half.  The epsilon is 1e-3, which is many
 *     orders above double's rounding of a sum under 2^30 and many orders
 *     below the half-LSB a round would add.
 *
 *   ORACLE 2, step 6 alone, recomputed EXACTLY in double.  Given `score` and
 *     `score_exp`, score_q12 must equal clip(floor(score * 2^(12-score_exp)
 *     + 0.5)), evaluated with ldexp and floor and nothing else.  This is exact
 *     where it matters: in the unsaturated region |value| < 2^31 < 2^53, so a
 *     double holds every intermediate without loss, and outside it the only
 *     question is which side of the clip the value falls on, which a double
 *     answers correctly out to 2^63.  The Q of the output grid is written
 *     here as a SECOND literal (ATTN_SQ_QOUT_ORACLE) rather than reusing the
 *     integer path's constant, deliberately: sharing it let a mutation of
 *     12 to 11 pass both oracles, because the golden moved with the path.  A
 *     constant shared between the thing under test and the thing testing it is
 *     not a check, it is a restatement.  It also validates the shift CLAMP: the
 *     RTL clamps a left shift to 32 because any larger shift of a non-zero
 *     score already saturates, and this oracle uses the TRUE shift, so a clamp
 *     that is not exact would show up here.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_score_q12_vec attn_score_q12_vec.c -lm
 * Usage: ./attn_score_q12_vec [out.txt] [ncase] [nblk] [kq_shift]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_SQ_QOUT 12                 /* the Q of the softmax input grid */
#define ATTN_SQ_LSH_CLAMP 32            /* see attn_score_q12(), derived      */

/* The output grid's Q, restated independently of ATTN_SQ_QOUT for the oracles.
 * See the ORACLE 2 paragraph in the header: this MUST NOT be defined in terms
 * of ATTN_SQ_QOUT.  12 is the softmax input grid from the C spec's step 6. */
#define ATTN_SQ_QOUT_ORACLE 12

typedef struct {
    int32_t score;      /* the aligned sum, before the Q12 conversion */
    int     e_min;
    int     score_exp;
    int     sh;         /* score_exp - 12; negative selects the left branch  */
    int32_t q12;
    int     sat;
} attn_score_q12_t;

static void attn_score_q12(const int32_t *partial, const int8_t *e_k, int nblk,
                           int q_exp, int kq_shift, attn_score_q12_t *r)
{
    int e_min = (int)e_k[0];
    for (int b = 1; b < nblk; b++) if ((int)e_k[b] < e_min) e_min = (int)e_k[b];

    /* The alignment is a FLOOR, not a round.  The Q12 conversion below rounds;
     * rounding here as well would double-round.  e_min is a MINIMUM, so every
     * shift is a right shift and no block can overflow while being aligned --
     * taking the max instead would need left shifts and could not be done in
     * place. */
    int64_t acc = 0;
    for (int b = 0; b < nblk; b++) {
        int s = (int)e_k[b] - e_min;
        if (s > 63) s = 63;
        acc += mv4i_floor_shr((int64_t)partial[b], s);
    }
    /* |partial| < 2^27 by the spec's bound (32 terms of |q| <= 32768 times
     * |k| <= 127 is under 2^27), so 8 aligned terms sum to under 2^30 and the
     * accumulator fits s32.  Stated rather than assumed, because the RTL
     * declares s32 and would wrap silently. */
    if (acc > INT32_MAX || acc < INT32_MIN) {
        fprintf(stderr, "attn_score_q12: aligned sum %lld does not fit s32\n",
                (long long)acc);
        exit(2);
    }
    r->score     = (int32_t)acc;
    r->e_min     = e_min;
    r->score_exp = q_exp + e_min + kq_shift;
    r->sh        = r->score_exp - ATTN_SQ_QOUT;
    r->sat       = 0;

    if (r->sh >= 0) {
        /* sat32 here is UNREACHABLE and is kept only as a width guard: a right
         * shift cannot grow a magnitude, so |round_shift(score, sh)| <=
         * |score| + 1 < 2^31 for any sh >= 0.  Removing it is an EQUIVALENT
         * mutation and survives every oracle -- verified, not assumed.  The
         * saturation that matters is on the left branch below, and removing
         * THAT one is killed. */
        int64_t v = mv4i_round_shift((int64_t)r->score, r->sh);
        r->q12 = mv4i_sat32(v, &r->sat);
    } else {
        /* THE CLAMP IS EXACT, not an approximation, and that is why it is safe
         * to build a 32-bit barrel shifter instead of a 63-bit one.  |score| <
         * 2^31, so a left shift of 32 already carries any non-zero score past
         * 2^31 and saturates; a larger shift saturates to the same value with
         * the same sign.  A zero score gives zero at every shift.  So clamping
         * changes no output.  Oracle 2 below uses the TRUE shift and would
         * catch it if this reasoning were wrong. */
        int l = -r->sh;
        if (l > ATTN_SQ_LSH_CLAMP) l = ATTN_SQ_LSH_CLAMP;
        int64_t v = (int64_t)r->score << l;
        r->q12 = mv4i_sat32(v, &r->sat);
    }
}

#ifndef ATTN_SCORE_Q12_INCLUDE

static uint64_t rs = 20260828ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_score_q12_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 64;
    int NBLK  = (argc > 3) ? atoi(argv[3]) : 8;    /* 256 / 32, both models   */
    int KQ    = (argc > 4) ? atoi(argv[4]) : 4;    /* 1/sqrt(256) = 2^-4      */
    rs = vec_seed(argc, argv, 5, 20260828ULL);

    int32_t *partial = malloc(sizeof(int32_t) * NBLK);
    int8_t  *e_k     = malloc(sizeof(int8_t)  * NBLK);
    if (!partial || !e_k) { perror("malloc"); return 2; }

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d\n", ncase, NBLK, KQ);

    double worst_ratio = 0.0; int worst_case = -1;
    long nmis = 0, ndir = 0, nsat = 0, nleft = 0, nright = 0;

    for (int c = 0; c < ncase; c++) {
        /* Shapes, chosen for what is easy to get wrong:
         *  0  all e_k equal        -- every alignment shift is 0, so the floor
         *                             is a no-op and only the sum is tested
         *  1  all partials zero    -- score 0, and the Q12 conversion of zero
         *                             must be zero on BOTH branches
         *  2  wide e_k spread      -- large alignment shifts; several blocks
         *                             floor to 0 or -1, which is where the
         *                             floor-versus-round distinction shows
         *  3  sh large positive    -- the right-shift branch, deep
         *  4  sh negative          -- the LEFT-shift branch.  A unit that
         *                             implements only the right branch gets
         *                             every one of these wrong and gets all
         *                             the plausible-looking cases right
         *  5  left-branch overflow -- saturation, both signs
         *  6  negative near 2^k    -- floor_shr rounds toward minus infinity,
         *                             so -(2^k - 1) >> 1 is -2^(k-1); the
         *                             alignment must not be a magnitude shift
         *  7  small score, very negative sh -- the ONLY shape where the
         *                             left-shift CLAMP is observable.  Every
         *                             other left-branch case has a score big
         *                             enough that it saturates whatever the
         *                             clamp is, so a clamp of 16 instead of 32
         *                             passed until this shape existed.  Found
         *                             by mutation, not by inspection.
         *  else random
         */
        int shape = (c < 8) ? c : (int)(rnd32() % 8u);
        int q_exp, e_base;

        e_base = 6 + (int)(rnd32() % 12u);
        switch (shape) {
        case 3: q_exp =  40 + (int)(rnd32() % 10u); break;   /* sh >> 0 */
        case 4: q_exp = -e_base - KQ - 2 - (int)(rnd32() % 6u); break; /* sh < 0 */
        case 5: q_exp = -e_base - KQ - 20; break;            /* sh very negative */
        case 7: q_exp = -e_base - KQ - 6 - (int)(rnd32() % 26u); break;
        default: q_exp = (int)(rnd32() % 24u) - 4; break;
        }

        for (int b = 0; b < NBLK; b++) {
            int32_t p;
            switch (shape) {
            case 0: e_k[b] = (int8_t)e_base; break;
            case 1: e_k[b] = (int8_t)(e_base + (int)(rnd32() % 8u)); break;
            case 2: e_k[b] = (int8_t)(e_base + (int)(rnd32() % 30u)); break;
            case 6: e_k[b] = (int8_t)(e_base + (int)(rnd32() % 3u)); break;
            case 7: e_k[b] = (int8_t)(e_base + (int)(rnd32() % 4u)); break;
            default: e_k[b] = (int8_t)(e_base + (int)(rnd32() % 6u)); break;
            }
            switch (shape) {
            case 1: p = 0; break;
            case 5: {
                int k = 24 + (int)(rnd32() % 3u);
                p = (int32_t)(rnd32() & (uint32_t)((1u << k) - 1u));
                if (rnd32() & 1u) p = -p;
                break;
            }
            case 7:
                /* small enough that score << (-sh) does NOT saturate for the
                 * shifts this shape produces, which is what makes the clamp
                 * observable */
                p = (int32_t)(rnd32() % 64u) - 31;
                break;
            case 6: {
                int k = 4 + (int)(rnd32() % 22u);
                p = (int32_t)((1u << k) - 1u);
                if (rnd32() & 1u) p = -p;
                break;
            }
            default: {
                int k = (int)(rnd32() % 27u);
                p = (int32_t)(rnd32() & (uint32_t)((1u << k) - 1u));
                if (rnd32() & 1u) p = -p;
                break;
            }
            }
            /* The spec's bound on one block's partial: 32 terms of
             * |q| <= 32768 times |k| <= 127 is under 2^27.  The RTL's s32
             * accumulator argument depends on it, so the generator must stay
             * inside it or the testbench would be testing an unreachable
             * state. */
            if (p >=  (1 << 27)) p =  (1 << 27) - 1;
            if (p <= -(1 << 27)) p = -(1 << 27) + 1;
            partial[b] = p;
        }

        attn_score_q12_t r;
        attn_score_q12(partial, e_k, NBLK, q_exp, KQ, &r);
        if (r.sat) nsat++;
        if (r.sh < 0) nleft++; else nright++;

        /* ---- ORACLE 1: the whole chain, in double, no alignment ---------- */
        double true_real = 0.0;
        for (int b = 0; b < NBLK; b++)
            true_real += ldexp((double)partial[b], -(q_exp + (int)e_k[b]));
        true_real = ldexp(true_real, -KQ);
        double ideal_q12 = ldexp(true_real, ATTN_SQ_QOUT_ORACLE);

        if (!r.sat) {
            double err = fabs((double)r.q12 - ideal_q12);
            /* The derived bound.  NBLK floors, each worth one aligned LSB,
             * which is 2^(12 - score_exp) Q12 counts; plus the Q12 round,
             * which is 0.5 on the right branch and exactly 0 on the left. */
            double bound = (double)NBLK * ldexp(1.0, ATTN_SQ_QOUT_ORACLE - r.score_exp)
                         + ((r.sh >= 0) ? 0.5 : 0.0);
            double ratio = err / bound;
            if (ratio > worst_ratio) { worst_ratio = ratio; worst_case = c; }
        }

        /* ---- ORACLE 3: the direction of the alignment -------------------- */
        {
            int em = (int)e_k[0];
            for (int b = 1; b < NBLK; b++)
                if ((int)e_k[b] < em) em = (int)e_k[b];
            double true_al = 0.0;
            for (int b = 0; b < NBLK; b++)
                true_al += ldexp((double)partial[b], -((int)e_k[b] - em));
            if ((double)r.score > true_al + 1e-3) {
                if (ndir < 8)
                    fprintf(stderr, "  FAIL oracle 3: case %d aligned sum %lld "
                                    "EXCEEDS the unfloored sum %.6f -- the "
                                    "alignment is not flooring\n",
                            c, (long long)r.score, true_al);
                ndir++;
            }
            if ((double)r.score <= true_al - (double)NBLK - 1e-3) {
                if (ndir < 8)
                    fprintf(stderr, "  FAIL oracle 3: case %d aligned sum %lld "
                                    "is more than NBLK below the unfloored sum "
                                    "%.6f\n", c, (long long)r.score, true_al);
                ndir++;
            }
        }

        /* ---- ORACLE 2: step 6 alone, recomputed exactly ------------------ */
        double v2 = ldexp((double)r.score, ATTN_SQ_QOUT_ORACLE - r.score_exp);
        double q2 = floor(v2 + 0.5);
        if (q2 >  2147483647.0) q2 =  2147483647.0;
        if (q2 < -2147483648.0) q2 = -2147483648.0;
        if ((double)r.q12 != q2) {
            if (nmis < 8)
                fprintf(stderr, "  FAIL oracle 2: case %d integer path %lld, "
                                "double oracle %.0f (score %lld, score_exp %d, "
                                "sh %d)\n", c, (long long)r.q12, q2,
                        (long long)r.score, r.score_exp, r.sh);
            nmis++;
        }

        /* ---- emit --------------------------------------------------------
         * score_q12 is emitted with a decimal point because the testbench
         * reads it as a VHDL `real`: sat32's negative limit is -2^31, which is
         * NOT representable as a VHDL integer (the range is symmetric), so a
         * bare integer literal would be rejected or would wrap on exactly the
         * saturation case the vectors exist to test.  A double holds it
         * exactly.  Same workaround as gdn_head_emit_vec.c's s40 accumulator,
         * for the same reason. */
        fprintf(f, "%d %d %d %d %d %.1f %d\n",
                c, q_exp, r.e_min, r.score_exp, r.sh, (double)r.q12, r.sat);
        for (int b = 0; b < NBLK; b++) fprintf(f, "%d ", (int)partial[b]);
        fprintf(f, "\n");
        for (int b = 0; b < NBLK; b++) fprintf(f, "%d ", (int)e_k[b]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_score_q12_vec: %d cases x %d blocks, kq_shift %d -> %s\n",
            ncase, NBLK, KQ, out);
    fprintf(stderr, "  oracle 1  worst error / derived bound: %.4f (case %d)\n",
            worst_ratio, worst_case);
    fprintf(stderr, "  right-shift branch %ld, LEFT-shift branch %ld, "
                    "saturating %ld\n", nright, nleft, nsat);

    int fail = 0;
    if (nmis) {
        fprintf(stderr, "  FAIL oracle 2: %ld Q12 conversions disagree with the "
                        "double recomputation\n", nmis);
        fail = 1;
    }
    if (ndir) {
        fprintf(stderr, "  FAIL oracle 3: %ld cases where the aligned sum is on "
                        "the wrong side of the unfloored sum\n", ndir);
        fail = 1;
    }
    if (worst_ratio > 1.0) {
        fprintf(stderr, "  FAIL oracle 1: over the derived bound of NBLK "
                        "alignment floors plus one Q12 round -- the integer "
                        "recipe is wrong, not the grid\n");
        fail = 1;
    }
    /* A vector set that never reaches the left branch would let a unit that
     * omits it pass, so the absence of coverage is a FAILURE of the generator
     * and not merely a note. */
    if (nleft == 0 || nright == 0 || nsat == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- right %ld, left %ld, sat %ld; "
                        "all three must be non-zero or a unit that implements "
                        "only one branch passes\n", nright, nleft, nsat);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: every Q12 conversion reproduced exactly by the "
                    "double oracle, whole-chain error inside the derived "
                    "bound, alignment flooring in the right direction, both "
                    "branches and saturation covered\n");
    return 0;
}

#endif /* ATTN_SCORE_Q12_INCLUDE */
