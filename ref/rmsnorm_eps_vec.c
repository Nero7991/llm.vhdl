/* rmsnorm_eps_vec -- does a Q-scaled RMSNorm WITH the model's epsilon actually
 * reproduce ggml over the measured activation range?
 *
 * WHY THIS EXISTS.  rtl/rmsnorm.vhd and rtl/rmsnorm_rs.vhd compute
 * x / sqrt(mean(x^2)) with no epsilon, and floor the divisor with
 * "if shifted_r < 1 then msq_r <= 1", which at Q = 12 is an epsilon of 2^-12 =
 * 2.44e-4 against the model's 1e-6 -- 244x too large.  Measured on the real
 * model, that floor sits ABOVE the median activation, so the unit applies a
 * gain of 64 where ggml applies 901: 14x wrong on the typical sample, not on a
 * corner.  Full account: docs/debugging/2026-08-26_rmsnorm-magnitude-window.md.
 *
 * THE QUESTION THIS ANSWERS is not "is eps a good idea" -- ggml computes
 * x/sqrt(mean+eps) and the hardware must match it, so that is settled.  It is
 * "what Q does the fixed-point form need to track ggml across the range that
 * actually occurs", measured rather than argued.
 *
 * Two constraints fight each other and both are in here:
 *   - eps enters as an integer 2^Q * eps, so Q must be >= 20 for it to exist
 *     at all (2^12 * 1e-6 = 0.0041, below one LSB) and >= 24 for resolution.
 *   - num = S << Q must fit s64.  At N = 128 the exact worst case is
 *     S < 2^37, so Q <= 25 is a HARD ceiling.  The RTL's own assert permits
 *     S < 2^46, which is 512x looser and would let S << Q overflow silently
 *     at any Q >= 17 -- harmless at the shipped Q = 12, a real hazard the
 *     moment Q moves.  That assert has to be tightened WITH Q.
 *
 * The golden is DOUBLE, not a second integer path.  A second integer path
 * agrees with a wrong recipe; that is exactly how the l2norm collapse of
 * 2026-08-25 survived 55 passing cases.
 *
 * Build: cc -O2 -Wall -Wextra -o rmsnorm_eps_vec rmsnorm_eps_vec.c -lm
 * Usage: ./rmsnorm_eps_vec [Q] [eps] [n]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

#define round_shift(v, sh) mv4i_round_shift((v), (sh))

static int    Q   = 24;
static double EPS = 1e-6;
static int    N   = 128;
static int    EXB = 0;    /* extra fractional bits used ONLY for the eps add */
static int    MODE = 0;   /* 0 = absolute-grid (the RTL's shape), 1 = floating */
static int    MB  = 30;   /* mantissa bits kept in the floating form */

/* The fixed-point norm, structured exactly as rmsnorm_rs does it, with the
 * clamp REPLACED by the model's epsilon.  Returns the gain 2^Q / sqrt(mean+eps)
 * as an integer, or -1 if an intermediate would overflow. */
static int64_t gain_fixed(const int16_t *xm, int xe, int *ovf)
{
    *ovf = 0;
    int64_t S = 0;
    for (int i = 0; i < N; i++) S += (int64_t)xm[i] * (int64_t)xm[i];

    /* The width relation the RTL asserts, tightened to match Q.  62 - Q is the
     * exact headroom: anything larger and S << Q leaves s64. */
    if (S >= ((int64_t)1 << (62 - Q))) { *ovf = 1; return -1; }

    int64_t num = S << Q;                       /* 2^Q * sum */
    int lg = 0; { int t = N; while (t >>= 1) lg++; }
    int64_t msq = round_shift(num, lg);         /* 2^Q * mean(xm^2) */

    /* Undo the input exponent: mean(x_real^2) = mean(xm^2) * 2^-2xe. */
    int sh = 2 * xe;
    if (sh > 62) sh = 62;
    if (sh < -62) sh = -62;
    if (sh >= 0) msq = round_shift(msq, sh);
    else {
        if (msq > (int64_t)1 << (62 + sh)) { *ovf = 1; return -1; }
        msq <<= -sh;
    }

    /* THE FIX.  Not "if msq < 1 then msq = 1", which is an epsilon set by Q.
     * The model's epsilon, converted into this grid ONCE. */
    /* EXB exists because Q alone cannot carry eps accurately.  eps enters as
     * the integer round(2^Q * eps), and at Q = 24 that is round(16.777) = 17,
     * a +1.33% error in eps and so a -0.66% error in the gain -- everywhere
     * eps dominates, which the measured range says is most of it.  Raising Q
     * does not fix it: Q <= 25 is a hard width ceiling and lands on
     * round(33.55) = 34, the same +1.33%.  So eps is added on a grid EXB bits
     * finer than the one Q sets.  That costs a shift, not precision, because
     * msq is small wherever the eps term is the one that matters. */
    int64_t eps_q = (int64_t)llround(ldexp(EPS, Q + EXB));
    if (msq > (int64_t)1 << (62 - EXB)) { *ovf = 1; return -1; }
    msq = (msq << EXB) + eps_q;
    if (msq <= 0) return 0;

    /* gain = 2^Q / sqrt(msq / 2^Q) = 2^Q * 2^(Q/2) / sqrt(msq).  Computed in
     * double HERE on purpose: this reference is answering whether the GRID is
     * adequate, not reimplementing the Newton rsqrt, whose own error is
     * measured separately in the l2norm work. */
    double mean_real = ldexp((double)msq, -(Q + EXB));
    return (int64_t)llround(ldexp(1.0 / sqrt(mean_real), Q));
}

/* msb position of a positive value, 0 for 0. */
static int msb_pos_u64(uint64_t v){ int p = 0; while (v >>= 1) p++; return p; }

/* MODE 1 -- the structural fix.
 *
 * The absolute-grid recipe above rescales mean into a FIXED 2^-Q grid before
 * adding eps, so at the crossover (rms ~ 1e-3, where mean ~ eps and the sum
 * genuinely needs both terms) mean has already been shifted down to a fraction
 * of one LSB and rounded away.  No value of Q rescues that: resolving mean at
 * log2(rms) = -13 wants Q ~ 30, and Q <= 25 is a hard s64 ceiling at N = 128.
 *
 * So do not rescale to a fixed grid.  Keep mean in the block-floating form it
 * already arrives in, express eps in the same form once, align to the LARGER
 * of the two exponents, and add.  Then whichever term is negligible is the one
 * that rounds away, which is the correct behaviour rather than an artefact.
 * Relative precision is then flat across the whole range instead of collapsing
 * at the one place the epsilon exists to handle.
 *
 * Hardware note: the align is a barrel shift and the sum is a wide add.  This
 * project's timing rule forbids both in series in one FSM state, so they land
 * in separate states -- one extra cycle on a path that runs once per row. */
static int64_t gain_float(const int16_t *xm, int xe, int *ovf)
{
    *ovf = 0;
    int64_t S = 0;
    for (int i = 0; i < N; i++) S += (int64_t)xm[i] * (int64_t)xm[i];
    int lg = 0; { int t = N; while (t >>= 1) lg++; }

    /* Both terms are carried as (m, e) meaning the value m * 2^-e, so a LARGER
     * e is a FINER grid and therefore a SMALLER value at equal mantissa. */

    /* mean = S * 2^-lg * 2^-2xe, with S renormalised to MB bits. */
    int64_t m_mean; int e_mean;
    if (S == 0) { m_mean = 0; e_mean = 0; }
    else {
        int p  = msb_pos_u64((uint64_t)S);
        int sh = MB - 1 - p;
        m_mean = (sh >= 0) ? (S << sh) : round_shift(S, -sh);
        e_mean = lg + 2*xe + sh;
    }

    /* eps in the same form, resolved ONCE at build time, normalised to MB bits
     * so it carries full relative precision no matter what Q is. */
    int e_eps = MB - 1 - (int)floor(log2(EPS));
    int64_t m_eps = (int64_t)llround(ldexp(EPS, e_eps));

    /* Align to the LARGER VALUE (the smaller e) and let the negligible term
     * round away.  That is the whole point: at the crossover both survive,
     * and outside it the one that vanishes is the one that should. */
    int64_t acc; int e_out;
    if (m_mean == 0)            { acc = m_eps;  e_out = e_eps; }
    else if (e_mean == e_eps)   { acc = m_mean + m_eps; e_out = e_mean; }
    else if (e_mean > e_eps) {                       /* mean is the smaller */
        int d = e_mean - e_eps;
        acc = (d >= 63 ? 0 : round_shift(m_mean, d)) + m_eps;
        e_out = e_eps;
    } else {                                         /* eps is the smaller */
        int d = e_eps - e_mean;
        acc = m_mean + (d >= 63 ? 0 : round_shift(m_eps, d));
        e_out = e_mean;
    }
    if (acc <= 0) return 0;

    double mean_real = ldexp((double)acc, -e_out);
    return (int64_t)llround(ldexp(1.0 / sqrt(mean_real), Q));
}

/* Random-vector stress.  The octave sweep above uses flat mantissas so that
 * rms is exactly a power of two, which is the right shape for locating a rail
 * but exercises exactly one value of S per octave.  This exercises the
 * normalisation with S spread across its whole range, including the ragged
 * cases where msb_pos lands mid-mantissa. */
static uint64_t rs = 20260826ULL;
static uint32_t rnd(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

static void stress(int mode)
{
    int16_t xm[8192];
    double worst = 0; int worst_k = 0; long novf = 0, n = 0;
    for (int k = -30; k <= 6; k++) {
        for (int trial = 0; trial < 400; trial++) {
            /* random mantissas, random amplitude within the octave */
            int amp = 1 + (rnd() % 32767);
            double sum = 0;
            for (int i = 0; i < N; i++) {
                int v = (int)(rnd() % (2u*amp+1u)) - amp;
                xm[i] = (int16_t)v;
                sum += (double)v * (double)v;
            }
            if (sum == 0) continue;
            int xe = 14 - k;
            int ovf; int64_t g = mode ? gain_float(xm, xe, &ovf)
                                      : gain_fixed(xm, xe, &ovf);
            if (ovf) { novf++; continue; }
            double mean_real = ldexp(sum / N, -2*xe);
            double g_want = 1.0 / sqrt(mean_real + EPS);
            double g_got  = ldexp((double)g, -Q);
            double rel = fabs(g_got - g_want) / g_want;
            n++;
            if (rel > worst) { worst = rel; worst_k = k; }
        }
    }
    printf("# STRESS mode=%s  n=%ld  worst_rel=%.4e at log2(rms)~%d  ovf=%ld\n",
           mode ? "floating" : "absolute-grid", n, worst, worst_k, novf);
}

int main(int argc, char **argv)
{
    if (argc > 1) Q   = atoi(argv[1]);
    if (argc > 2) EPS = atof(argv[2]);
    if (argc > 3) N   = atoi(argv[3]);
    if (argc > 4) EXB  = atoi(argv[4]);
    if (argc > 5) MODE = atoi(argv[5]);
    if (argc > 6) MB   = atoi(argv[6]);

    printf("# rmsnorm_eps_vec  Q=%d  eps=%.3e  N=%d  EXB=%d  MODE=%s  MB=%d\n",
           Q, EPS, N, EXB, MODE ? "floating" : "absolute-grid", MB);
    { double want = ldexp(EPS, Q + EXB), got = llround(want);
      printf("# EPSGRID %.6f %.0f %.6f\n", want, got,
             want > 0 ? 100.0*fabs(got-want)/want : 0.0); }
    printf("# eps in this grid: 2^Q * eps = %.4f %s\n", ldexp(EPS, Q),
           ldexp(EPS, Q) < 1.0 ? "  <-- UNREPRESENTABLE, below one LSB" : "");
    printf("# width ceiling: S must be < 2^%d (Q <= 25 at N=128)\n", 62 - Q);
    printf("#\n# %-10s %-14s %-14s %-12s %s\n",
           "log2(rms)", "gain_fixed", "gain_double", "rel_err", "note");

    /* Sweep rms_real across the MEASURED range of the real model, which is
     * log2 rms in [-25.25, -1.13] on Qwen3.8-27B, plus margin on both ends so
     * the rails are visible rather than assumed. */
    int16_t xm[8192];
    double worst = 0.0; int worst_k = 0; long novf = 0;

    for (int k = -30; k <= 6; k++) {
        /* Flat mantissas so rms_real is exactly 2^k: xm = 16384, xe = 14 - k. */
        for (int i = 0; i < N; i++) xm[i] = 16384;
        int xe = 14 - k;

        int ovf;
        int64_t g = MODE ? gain_float(xm, xe, &ovf) : gain_fixed(xm, xe, &ovf);
        double rms_real = ldexp(1.0, k);
        double g_want   = 1.0 / sqrt(rms_real * rms_real + EPS);

        if (ovf) { novf++;
            printf("  %-10d %-14s %-14.6g %-12s OVERFLOW\n", k, "-", g_want, "-");
            continue; }

        double g_got = ldexp((double)g, -Q);
        double rel   = fabs(g_got - g_want) / g_want;
        if (rel > worst) { worst = rel; worst_k = k; }
        printf("  %-10d %-14.6g %-14.6g %-12.3e %s\n", k, g_got, g_want, rel,
               rel > 1e-3 ? "  <-- OFF" : "");
    }

    stress(MODE);
    printf("#\n# worst relative gain error over the swept range: %.4e at log2(rms)=%d\n",
           worst, worst_k);
    printf("# overflow cases: %ld\n", novf);
    printf("# VERDICT: Q=%d %s\n", Q,
           (worst < 1e-3 && novf == 0) ? "TRACKS ggml across the measured range"
                                       : "DOES NOT track ggml across the range");
    return 0;
}
