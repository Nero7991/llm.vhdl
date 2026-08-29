/* ref/attn_softmax_vec.c -- vectors and golden for rtl/attn_softmax.vhd.
 *
 * Subsystem C, step 7: the ONLINE softmax for one query head.  A stream of Q12
 * scores goes in, one per cached position; a stream of Q12 PV weights `e_p`
 * comes out, together with the rescale factors `f` the accumulator array needs
 * and the final denominator `s`.
 *
 *     m'      = ceil_grid( max(m_g, score_q12) )      grid = 2^GRID_SH counts
 *     on a rise, k = (m' - m_g) >> GRID_SH            EXACT, see below
 *               f = round_shift( EXP_ROM[256 - k], 18 )   for k <= 256
 *                 = 0                                     for k >  256
 *               s = round_shift( s * f, 12 )
 *               m_g = m'
 *     z       = score_q12 - m_g                       always <= 0
 *     e_p     = exp_cone(z)                           u13, e_p <= 4096
 *     s      += e_p
 *
 * WHY THE GRID SNAP IS THE WHOLE DESIGN.  The running maximum is kept snapped
 * UP to a multiple of 2^GRID_SH = 256 Q12 counts, which is exactly 1/16 in real
 * units, which is exactly one EXP_ROM index step (the table spans z in [-16, 0]
 * over 256 intervals).  That is not a rounding convenience: it is what makes
 * `k` an EXACT integer on every maximum rise, so the rescale factor
 * exp(m_old - m_new) is a direct TABLE ENTRY -- EXP_ROM[256-k] -- and not
 * another interpolation.  An unsnapped maximum would need a second cone
 * evaluation per rescale and would make the rescale factor inexact in a way
 * that compounds over every subsequent position.  The snap costs at most one
 * grid step of extra headroom, i.e. e_p is at most 4096 rather than exactly
 * 4096 at the maximum, which is a 6.4 percent loss of one code point and
 * nothing else.
 *
 * WHY ceil AND NOT floor.  z = score - m_g must be <= 0 for every score,
 * including the one that just set the maximum, because the cone is defined only
 * for z <= 0 and because e_p must not exceed 4096.  Rounding the maximum DOWN
 * to the grid would make the maximum's own z positive.  `ceil_grid` on a
 * negative value is `((v + 255) >> 8) << 8` with an ARITHMETIC right shift,
 * i.e. a floor-shift of the biased value; a logical shift or a C `/` would
 * truncate toward zero and be wrong for exactly the negative scores that
 * dominate this workload.
 *
 * WHY k > 256 MUST BE A SEPARATE BRANCH, and what that branch does NOT buy.
 * EXP_ROM has 257 entries, so 256 - k is a NEGATIVE index for k > 256: out of
 * bounds in C and outside the address range of the RTL's ROM.  The branch is
 * therefore required for RANGE.  It is NOT required for VALUE, and that was
 * checked rather than assumed: clamping the INDEX to 0 instead of the FACTOR to
 * 0 gives round_shift(EXP_ROM[0], 18) = round_shift(121, 18) = 0, the same
 * answer, because exp(-16) is below half a Q12 count.  So an index clamp is an
 * EQUIVALENT mutation of this file and no oracle can separate the two; what
 * separates them is the ROM's address range in hardware.  Said plainly here
 * because the opposite claim is the sort that reads well and is false.
 *
 * THE FIRST POSITION IS NOT A RESCALE.  There is no sentinel maximum.  The
 * first score of a head sets m_g directly with no `f` emitted, because s and
 * the accumulator o are both zero at that instant and a rescale of zero is a
 * no-op.  A sentinel of -2^31 would work arithmetically -- it produces k far
 * above 256 and therefore f = 0 -- but it costs one full rescale pass over
 * 1,536 accumulators per head per layer for nothing, and it makes the first
 * position's behaviour depend on a magic constant instead of on a flag.
 *
 * THE CONE IS EXACTLY fx_exp_q(z, 12), NARROWED.  ref/fx.h builds its table as
 * llround(exp(z) * 2^30) over z in [-16, 0] at 257 points, and
 * rtl/fixed_luts_pkg.vhd's EXP_ROM is that same table (verified entry for entry
 * on 2026-08-27).  This file rebuilds it with the same recipe rather than
 * including fx.h, so the generator has no dependency on fx_init(); the double
 * oracles below never touch the table at all, they call exp() directly, so the
 * table being shared with the RTL does not weaken them.
 *
 * DOUBLE ORACLE, four independent checks, none sharing the integer path:
 *
 *   ORACLE 1, the final denominator against a BATCH double sum.  The whole
 *     point of an online softmax is that the running rescale reproduces the
 *     batch answer, so the batch answer is the check:
 *         s_true = sum over i of exp( (score_i - m_final) / 2^12 ) * 2^12
 *     summed in double with no rescale, no grid and no table.  The tolerance is
 *     DERIVED PER CASE and not chosen: an error bound is propagated alongside
 *     the integer path, growing by one cone bound per position and by
 *     (err * f/4096 + s_true * 0.5/4096 + 0.5) at each rescale -- the three
 *     terms being the previous error scaled, the relative error of f itself,
 *     and the rescale's own round.  A fixed tolerance would be vacuous on the
 *     monotone-rising shape and would fail on correct data elsewhere.  This is
 *     the trap ref/gdn_y_emit_vec.c fell into with a threshold that passed by
 *     luck, and the reason attn_score_q12's oracle 1 derives its bound too.
 *
 *   ORACLE 2, every e_p against exp() directly.  The cone is a linear
 *     interpolation of a CONVEX function over a grid step of h = 1/16, so its
 *     error is bounded by (h^2/8) * max f'' on the interval, which in Q12
 *     counts is 2^12 * (1/2048) * exp(z + 1/16) = 2.129 * exp(z); plus 0.5 for
 *     the final round and a hair for the Q30 floor.  Checked per value.
 *
 *   ORACLE 3, the DIRECTION of the interpolation.  Oracle 2's bound admits an
 *     error on either side, so it cannot tell a chord from a secant.  exp is
 *     convex, so a chord lies ABOVE it: e_p must satisfy e_p >= true - 1.
 *     A cone that interpolated the wrong way, or that floored where it should
 *     round, violates this while staying inside oracle 2.  This is the same
 *     one-sided structural check as attn_score_q12's oracle 3, and it exists
 *     for the same reason: a magnitude bound cannot see a direction.
 *
 *   ORACLE 4, the grid invariants, checked exactly rather than approximately.
 *     m_g is a multiple of 2^GRID_SH; m_g is >= every score seen so far, so
 *     every z is <= 0; every rise has k >= 1 and (m' - m_g) divisible by
 *     2^GRID_SH.  The divisibility is what makes k exact, and it is an
 *     equality, so it is checked as one.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_softmax_vec attn_softmax_vec.c -lm
 * Usage: ./attn_softmax_vec [out.txt] [ncase] [npos]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_SM_Q        12     /* the softmax grid, C spec step 6 and 7      */
#define ATTN_SM_GRID_SH   8     /* 2^8 Q12 counts = 1/16 = one EXP_ROM step   */
#define ATTN_SM_ROM_N   256     /* EXP_ROM spans index 0..256                 */
#define ATTN_SM_S_W      26     /* the s accumulator, C spec step 7           */

/* The Q of the grid, restated independently of ATTN_SM_Q for the oracles.
 * See attn_score_q12_vec.c's ORACLE 2 note: a constant shared between the thing
 * under test and the thing testing it is not a check, it is a restatement.  A
 * mutation of ATTN_SM_Q from 12 to 11 must not move the golden with the path. */
#define ATTN_SM_Q_ORACLE 12
#define ATTN_SM_GRID_ORACLE 16.0   /* grid steps per unit of z: 2^12 / 2^8    */

static int64_t sm_exp_rom[ATTN_SM_ROM_N + 1];

/* Identical recipe to ref/fx.h's _fx_exp_lut_q, which is identical entry for
 * entry to rtl/fixed_luts_pkg.vhd's EXP_ROM.  Built here rather than included
 * so the generator does not depend on fx_init(). */
static void sm_rom_init(void)
{
    for (int k = 0; k <= ATTN_SM_ROM_N; k++) {
        double z = -16.0 + (double)k * (16.0 / (double)ATTN_SM_ROM_N);
        sm_exp_rom[k] = llround(exp(z) * (double)(1LL << 30));
    }
}

/* exp(z) for z <= 0, Q12 in and Q12 out.  This is fx_exp_q(z, 12) with the
 * widths pinned: offset is 17 bits unsigned, the table delta is 26 bits
 * unsigned (max 65,054,728 at k = 255) and frac is 13 bits unsigned (max 4096,
 * reached only on the clamped top index), so the interpolation multiply is
 * 27x14 SIGNED and fits ONE DSP48E2 tile.  Both operands are narrowed, which is
 * the point: docs/debugging/2026-08-26_gdn-silu-unit.md records that narrowing
 * the interpolation delta ALONE changes no DSP count, because the multiplicand
 * stays wide and the product is still a cascade. */
static int32_t sm_exp_cone(int64_t z)
{
    /* The `<=` here rather than `<` is an EQUIVALENT choice, checked as
     * mutation C12: at z = -65536 exactly the table path gives
     * round_shift(EXP_ROM[0], 18) = round_shift(121, 18) = 0, the same answer.
     * Kept as `<=` only because it matches fx_exp_q verbatim. */
    if (z <= -16LL * (1LL << ATTN_SM_Q)) return 0;
    if (z > 0) z = 0;                       /* unreachable; see ORACLE 4     */

    int64_t offset = z + 16LL * (1LL << ATTN_SM_Q);      /* [0, 65536] */
    int64_t idx_fp = offset * 16;                        /* Q12 index   */
    int k = (int)(idx_fp >> ATTN_SM_Q);
    /* k reaches 256 only at z = 0 exactly.  fx_exp_q clamps the INDEX to 255
     * and lets frac run to 4096, which makes the interpolation return
     * EXP_ROM[256] = 2^30 exactly, so frac is 13 bits and not 12.
     *
     * Two nearby alternatives, measured rather than argued (mutations C3 and
     * C3b of this file):
     *   frac clamped to 4095  -- EQUIVALENT.  interp falls 15,883 short of
     *     2^30 out of a 2^18 rounding step, so the Q12 result is still 4096.
     *     No oracle can separate it and none should be expected to.
     *   frac forced to 0 in the clamp branch -- KILLED, e_p = 3848 against
     *     exp() = 4096.  That is the version that loses the top code point,
     *     and it is caught only by the grid-aligned shape 10, which exists
     *     because the coverage check reported e_p = 4096 zero times without
     *     it. */
    if (k > ATTN_SM_ROM_N - 1) k = ATTN_SM_ROM_N - 1;
    if (k < 0) k = 0;
    int64_t frac = idx_fp - ((int64_t)k << ATTN_SM_Q);   /* [0, 4096] */

    int64_t lo = sm_exp_rom[k];
    int64_t hi = sm_exp_rom[k + 1];
    int64_t interp_q30 = lo + (((hi - lo) * frac) >> ATTN_SM_Q);
    /* Q30 -> Q12, round half toward +infinity.  interp is non-negative so this
     * is mv4i_round_shift with no sign case. */
    int64_t r = mv4i_round_shift(interp_q30, 30 - ATTN_SM_Q);
    if (r < 0) r = 0;
    if (r > (1LL << ATTN_SM_Q)) r = (1LL << ATTN_SM_Q);
    return (int32_t)r;
}

/* ceil to the next multiple of 2^GRID_SH.  ARITHMETIC, so it is a true ceiling
 * for negative values; C's / would truncate toward zero and be wrong there. */
static int64_t sm_ceil_grid(int64_t v)
{
    const int64_t g = 1LL << ATTN_SM_GRID_SH;
    return mv4i_floor_shr(v + g - 1, ATTN_SM_GRID_SH) << ATTN_SM_GRID_SH;
}

typedef struct {
    int64_t m_g;        /* the snapped running maximum */
    int64_t s;          /* the denominator, Q12        */
    int     first;      /* no maximum seen yet         */
    int     n_rescale;  /* observability: C spec 3.3's rescale_max */
    int     ovf;        /* s left the S_W-bit field    */
    int     err;        /* z > 0, i.e. m_g was not an upper bound */
} attn_sm_state_t;

typedef struct {
    int  rise;      /* a rescale pass was emitted for this position */
    int  k;         /* the exact grid distance of the rise          */
    int  f;         /* the rescale factor, Q12                      */
    int  e_p;       /* the PV weight, Q12                           */
    int64_t z;
} attn_sm_step_t;

static void attn_sm_reset(attn_sm_state_t *st)
{
    st->m_g = 0; st->s = 0; st->first = 1;
    st->n_rescale = 0; st->ovf = 0; st->err = 0;
}

static void attn_sm_step(attn_sm_state_t *st, int32_t score, attn_sm_step_t *o)
{
    const int64_t S_MAX = (1LL << ATTN_SM_S_W) - 1;
    int64_t raw = st->first ? (int64_t)score
                            : ((int64_t)score > st->m_g ? (int64_t)score : st->m_g);
    int64_t m_new = sm_ceil_grid(raw);

    o->rise = 0; o->k = 0; o->f = 0;

    if (st->first) {
        st->m_g   = m_new;
        st->first = 0;
    } else if (m_new > st->m_g) {
        int64_t d = m_new - st->m_g;
        /* EXACT by construction: both ends are multiples of the grid.  The
         * generator asserts it (ORACLE 4) rather than relying on it. */
        int64_t k = d >> ATTN_SM_GRID_SH;
        o->rise = 1;
        o->k    = (k > 1000000) ? 1000000 : (int)k;
        if (k <= ATTN_SM_ROM_N) {
            o->f = (int)mv4i_round_shift(sm_exp_rom[ATTN_SM_ROM_N - (int)k],
                                         30 - ATTN_SM_Q);
        } else {
            o->f = 0;
        }
        st->s = mv4i_round_shift(st->s * (int64_t)o->f, ATTN_SM_Q);
        st->m_g = m_new;
        st->n_rescale++;
    }

    o->z = (int64_t)score - st->m_g;
    if (o->z > 0) st->err = 1;
    o->e_p = sm_exp_cone(o->z);

    st->s += (int64_t)o->e_p;
    if (st->s > S_MAX) { st->s = S_MAX; st->ovf = 1; }
}

#ifndef ATTN_SOFTMAX_INCLUDE

static uint64_t rs = 20260829ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

#define MAXPOS 64

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_softmax_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 40;
    int npos  = (argc > 3) ? atoi(argv[3]) : 24;
    rs = vec_seed(argc, argv, 4, 20260829ULL);
    if (npos > MAXPOS) npos = MAXPOS;

    sm_rom_init();

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d\n", ncase, npos,
            ATTN_SM_Q, ATTN_SM_GRID_SH, ATTN_SM_S_W);

    long n_o1 = 0, n_o2 = 0, n_o3 = 0, n_o4 = 0;
    double worst1 = 0.0, worst2 = 0.0;
    int worst1_c = -1, worst2_c = -1;
    long nrise = 0, nzero_f = 0, nzero_ep = 0, nfullep = 0, nnorise = 0;
    long nlate_max = 0, nsat_score = 0;

    int32_t score[MAXPOS];

    for (int c = 0; c < ncase; c++) {
        /* Shapes, chosen for what is easy to get wrong:
         *  0  monotone RISING   -- a rescale at essentially every position, the
         *                          worst case for the rescale path and the only
         *                          shape where a wrong f compounds visibly
         *  1  monotone FALLING  -- exactly one maximum, set at position 0, and
         *                          no rescale at all afterwards.  A unit that
         *                          rescales unconditionally still passes a
         *                          value check on shape 0 and fails here
         *  2  constant          -- ceil_grid(m) == m, so the rise test must be
         *                          STRICT.  A `>=` there emits a rescale with
         *                          k = 0, f = 4096, which is arithmetically a
         *                          no-op and therefore invisible to the value
         *                          check -- only the rescale COUNT sees it
         *  3  random moderate
         *  4  huge jump at the end -- k > 256, so f = 0 and every earlier
         *                          weight is discarded.  A unit that clamps the
         *                          INDEX instead of the FACTOR uses exp(-16)
         *                          here and is wrong by 121 parts in 2^30
         *  5  wide spread       -- many z below -16.0, so e_p = 0; the cone's
         *                          domain guard
         *  6  near the s32 rails -- ceil_grid(2^31-1) leaves s32, which is why
         *                          m_g is carried wider than the score
         *  7  alternating high/low -- rises interleaved with deep negatives
         *  8  one position only -- the first-position path with no rescale ever
         *  9  max at the LAST position -- the rescale lands after the whole
         *                          history is accumulated, which is where a
         *                          rescale applied to the wrong side of the
         *                          accumulate shows up
         * 10  constant AND ON THE GRID -- the only shape that reaches z = 0 and
         *                          therefore e_p = 4096, the top code point.
         *                          It exists because the coverage check below
         *                          reported e_p = 4096 zero times across 40
         *                          random cases: a maximum that lands exactly
         *                          on a grid point has probability 1/256 per
         *                          case and is precisely where the cone's
         *                          index clamp (k = 256 -> k = 255 with
         *                          frac = 4096) is exercised
         * else random
         */
        int shape = (c < 11) ? c : (int)(rnd32() % 11u);
        int np = npos;
        if (shape == 8) np = 1;

        int32_t base = (int32_t)(rnd32() % 40000u) - 20000;
        if (shape == 10) base = (base >> ATTN_SM_GRID_SH) << ATTN_SM_GRID_SH;
        for (int i = 0; i < np; i++) {
            int32_t v;
            switch (shape) {
            case 0: v = base + (int32_t)(i * (int)(200 + rnd32() % 900u)); break;
            case 1: v = base - (int32_t)(i * (int)(200 + rnd32() % 900u)); break;
            case 2:
            case 10: v = base; break;
            case 4: v = (i == np - 1) ? (base + 4000000)
                                      : (base + (int32_t)(rnd32() % 500u)); break;
            case 5: v = base - (int32_t)(rnd32() % 400000u); break;
            case 6: {
                uint32_t r = rnd32() % 4u;
                if      (r == 0) v =  2147483647;
                else if (r == 1) v = -2147483647;   /* -2^31 excluded, see below */
                else if (r == 2) v =  2147483391;
                else             v = -2147483391;
                break;
            }
            case 7: v = (i & 1) ? (base + (int32_t)(rnd32() % 30000u))
                                : (base - (int32_t)(rnd32() % 900000u)); break;
            case 9: v = (i == np - 1) ? (base + 30000)
                                      : (base - (int32_t)(rnd32() % 20000u)); break;
            default: v = base + (int32_t)(rnd32() % 60000u) - 30000; break;
            }
            /* -2^31 is deliberately NOT generated.  It is representable in the
             * RTL and handled identically, but it is one past what a VHDL
             * `integer` can hold, so the testbench could not read it back from
             * this file; and it is arithmetically indistinguishable here from
             * -2^31+1, since both sit far enough below any maximum in these
             * shapes that the cone returns 0 either way.  Stated rather than
             * silently avoided. */
            if (v == (int32_t)(-2147483647 - 1)) v = -2147483647;
            score[i] = v;
        }

        attn_sm_state_t st; attn_sm_reset(&st);
        attn_sm_step_t  stp[MAXPOS];

        /* ---- the error bound, propagated alongside the integer path ------ */
        double s_true = 0.0;     /* the exact partial sum on the CURRENT grid */
        double err    = 0.0;     /* a bound on |s_int - s_true|               */
        int64_t m_seen_max = 0; int have_max = 0;

        for (int i = 0; i < np; i++) {
            int64_t m_before = st.m_g;
            int     was_first = st.first;
            attn_sm_step(&st, score[i], &stp[i]);

            /* ---- ORACLE 4: the grid invariants, exactly ------------------ */
            if ((st.m_g & ((1LL << ATTN_SM_GRID_SH) - 1)) != 0) {
                if (n_o4 < 8) fprintf(stderr,
                    "  FAIL oracle 4: case %d pos %d m_g %lld is not on the grid\n",
                    c, i, (long long)st.m_g);
                n_o4++;
            }
            if (stp[i].z > 0) {
                if (n_o4 < 8) fprintf(stderr,
                    "  FAIL oracle 4: case %d pos %d z %lld > 0 -- m_g is not an "
                    "upper bound, so the cone is out of domain\n",
                    c, i, (long long)stp[i].z);
                n_o4++;
            }
            if (stp[i].rise) {
                int64_t d = st.m_g - m_before;
                if (d <= 0 || (d & ((1LL << ATTN_SM_GRID_SH) - 1)) != 0) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: case %d pos %d rise of %lld is not a "
                        "positive multiple of the grid, so k is not exact\n",
                        c, i, (long long)d);
                    n_o4++;
                }
            }
            if (!was_first && !stp[i].rise && st.m_g != m_before) {
                if (n_o4 < 8) fprintf(stderr,
                    "  FAIL oracle 4: case %d pos %d m_g moved without a rise\n", c, i);
                n_o4++;
            }
            if (!have_max || (int64_t)score[i] > m_seen_max) {
                m_seen_max = score[i]; have_max = 1;
            }
            if (st.m_g < m_seen_max) {
                if (n_o4 < 8) fprintf(stderr,
                    "  FAIL oracle 4: case %d pos %d m_g %lld below the largest "
                    "score seen %lld\n", c, i, (long long)st.m_g,
                    (long long)m_seen_max);
                n_o4++;
            }

            /* ---- the rescale half of the error recursion ----------------- */
            if (stp[i].rise) {
                double F = (stp[i].k <= ATTN_SM_ROM_N)
                             ? exp(-(double)stp[i].k / ATTN_SM_GRID_ORACLE) : 0.0;
                /* |f/4096 - F| <= 0.5/4096 from the Q12 round of a table entry
                 * that is itself within 0.5 of exp * 2^30. */
                err = err * ((double)stp[i].f / 4096.0)
                    + s_true * (0.5 / 4096.0) + 0.5;
                s_true *= F;
                nrise++;
                if (stp[i].f == 0) nzero_f++;
            }

            /* ---- ORACLE 2 and 3: the cone, against exp() ----------------- */
            double zr   = (double)stp[i].z / 4096.0;
            double true_ep = ldexp(exp(zr), ATTN_SM_Q_ORACLE);
            /* (h^2/8) * max f'' over the containing interval, h = 1/16, in Q12
             * counts; plus the final round and the Q30 floor. */
            double bnd = ldexp(1.0, ATTN_SM_Q_ORACLE) * (1.0 / 2048.0)
                           * exp(zr + 1.0 / ATTN_SM_GRID_ORACLE)
                       + 0.5 + ldexp(1.0, ATTN_SM_Q_ORACLE - 30);
            double e2 = fabs((double)stp[i].e_p - true_ep);
            double r2 = e2 / bnd;
            if (r2 > worst2) { worst2 = r2; worst2_c = c; }
            if (r2 > 1.0) {
                if (n_o2 < 8) fprintf(stderr,
                    "  FAIL oracle 2: case %d pos %d e_p %d, exp() says %.4f, "
                    "error %.4f over the derived bound %.4f (z %lld)\n",
                    c, i, stp[i].e_p, true_ep, e2, bnd, (long long)stp[i].z);
                n_o2++;
            }
            /* exp is CONVEX, so a chord lies above it.  The only slack is the
             * final round and the table's own rounding. */
            if ((double)stp[i].e_p < true_ep - 1.0) {
                if (n_o3 < 8) fprintf(stderr,
                    "  FAIL oracle 3: case %d pos %d e_p %d is BELOW exp() "
                    "%.4f -- the interpolation of a convex function must lie "
                    "above it\n", c, i, stp[i].e_p, true_ep);
                n_o3++;
            }

            err    += bnd;
            s_true += true_ep;

            if (stp[i].e_p == 0)    nzero_ep++;
            if (stp[i].e_p == 4096) nfullep++;
            if (score[i] ==  2147483647 || score[i] == -2147483647) nsat_score++;
        }
        if (st.n_rescale == 0) nnorise++;
        if (np > 1 && stp[np-1].rise) nlate_max++;

        /* ---- ORACLE 1: the final denominator against a BATCH double sum --
         * The recurrence's s_true and the batch sum are mathematically the same
         * number; computing the batch form independently is what checks that
         * the RESCALE STRUCTURE is right and not merely self-consistent. */
        double batch = 0.0;
        for (int i = 0; i < np; i++)
            batch += ldexp(exp(((double)score[i] - (double)st.m_g) / 4096.0),
                           ATTN_SM_Q_ORACLE);
        if (fabs(batch - s_true) > 1e-6 * (batch + 1.0)) {
            fprintf(stderr, "  FAIL oracle 1 (internal): case %d online double "
                            "sum %.6f disagrees with the batch sum %.6f -- the "
                            "error recursion itself is wrong\n", c, s_true, batch);
            n_o1++;
        }
        if (!st.ovf) {
            double e1 = fabs((double)st.s - batch);
            double r1 = e1 / (err + 1e-12);
            if (r1 > worst1) { worst1 = r1; worst1_c = c; }
            if (r1 > 1.0) {
                if (n_o1 < 8) fprintf(stderr,
                    "  FAIL oracle 1: case %d final s %lld, batch double sum "
                    "%.4f, error %.4f over the derived bound %.4f\n",
                    c, (long long)st.s, batch, e1, err);
                n_o1++;
            }
        }

        /* ---- emit -------------------------------------------------------
         * m_final is emitted with a decimal point because ceil_grid of a score
         * near 2^31-1 leaves the s32 range, which a VHDL integer cannot hold;
         * the same workaround, for the same reason, as attn_score_q12_vec.c's
         * score_q12.  The scores themselves are plain integers because -2^31 is
         * deliberately not generated (see above). */
        fprintf(f, "%d %d %d %lld %.1f %d %d\n",
                c, np, st.n_rescale, (long long)st.s, (double)st.m_g,
                st.ovf, st.err);
        for (int i = 0; i < np; i++) fprintf(f, "%d ", score[i]);
        fprintf(f, "\n");
        for (int i = 0; i < np; i++) fprintf(f, "%d ", stp[i].e_p);
        fprintf(f, "\n");
        for (int i = 0; i < np; i++) fprintf(f, "%d ", stp[i].rise);
        fprintf(f, "\n");
        for (int i = 0; i < np; i++) fprintf(f, "%d ", stp[i].f);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_softmax_vec: %d cases x up to %d positions -> %s\n",
            ncase, npos, out);
    fprintf(stderr, "  oracle 1  worst |s - batch| / derived bound: %.4f (case %d)\n",
            worst1, worst1_c);
    fprintf(stderr, "  oracle 2  worst |e_p - exp| / derived bound: %.4f (case %d)\n",
            worst2, worst2_c);
    fprintf(stderr, "  rescales %ld (of which f = 0: %ld), heads with NO rescale "
                    "%ld, rescale at the last position %ld\n",
            nrise, nzero_f, nnorise, nlate_max);
    fprintf(stderr, "  e_p = 0 %ld, e_p = 4096 %ld, scores at the s32 rail %ld\n",
            nzero_ep, nfullep, nsat_score);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld cases\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld values\n", n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld values below exp()\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld grid-invariant violations\n", n_o4); fail = 1; }
    /* A vector set that never reaches one of these shapes lets a unit that gets
     * it wrong pass, so absent coverage is a FAILURE of the generator and not a
     * note.  nnorise and nzero_f are the two that were nearly missed: the first
     * covers the shape where a unit that rescales unconditionally still passes,
     * the second the k > 256 branch. */
    if (nrise == 0 || nzero_f == 0 || nnorise == 0 || nlate_max == 0
        || nzero_ep == 0 || nfullep == 0 || nsat_score == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- rises %ld, f=0 %ld, no-rise "
                        "heads %ld, last-position rise %ld, e_p=0 %ld, "
                        "e_p=4096 %ld, rail scores %ld; every one must be "
                        "non-zero\n",
                nrise, nzero_f, nnorise, nlate_max, nzero_ep, nfullep, nsat_score);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: final denominator inside the derived bound against a "
                    "batch double sum, every e_p inside the interpolation bound "
                    "and on the convex side of exp(), grid invariants exact\n");
    return 0;
}

#endif /* ATTN_SOFTMAX_INCLUDE */
