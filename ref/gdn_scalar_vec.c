/* ref/gdn_scalar_vec.c -- vectors for rtl/gdn_scalar.vhd (B 2.1.3 scalar path).
 *
 * Emits, per case, the FIXED path (what the RTL must reproduce bit for bit)
 * and a DOUBLE oracle computed in real arithmetic (what the recipe is trying
 * to approximate).  The two are independent by construction: the oracle never
 * touches a LUT, a shift or an integer grid.  A golden that re-transcribed the
 * same integer recipe would only measure self-consistency -- for an
 * approximation kernel that is worth nothing.
 *
 * Usage: gdn_scalar_vec <sp_q>            (grid for the scalar path)
 */
#include "fx.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static int SP_Q = 12;

/* 2.1.3 site 3: Q conversion of a (mantissa, exp) pair onto the SP_Q grid.
   sh >= 0 -> round half toward +inf ; sh < 0 -> exact saturating left. */
static int32_t to_q(int32_t m, int e)
{
    int sh = e - SP_Q;
    int64_t r;
    if (sh >= 0) {
        if (sh > 62) return 0;
        r = ((int64_t)m + (1LL << sh >> 1)) >> sh;   /* half toward +inf */
    } else {
        int s = -sh;
        if (s > 40) s = 40;
        r = (int64_t)m << s;
    }
    if (r >  0x7FFFFFFF) r =  0x7FFFFFFF;
    if (r < -0x80000000LL) r = -0x80000000LL;
    return (int32_t)r;
}

/* Site 3 on a wide grid: same rounding, but NO saturation.  Values that
   cannot matter (beyond +/-16*2^q) are returned already past the clamp
   rather than wrapped or pinned to the s32 rail. */
static int64_t to_q_wide(int32_t m, int e)
{
    int sh = e - SP_Q;
    if (sh >= 0) {
        if (sh > 62) return 0;
        return ((int64_t)m + (1LL << sh >> 1)) >> sh;
    }
    int s = -sh;
    if (s > 40) return (m >= 0) ? (1LL << 45) : -(1LL << 45);
    return (int64_t)m << s;
}

static int64_t rshift_r(int64_t v, int s)      /* round half toward +inf */
{
    if (s <= 0) { if (-s > 40) return 0; return v << (-s); }
    if (s > 62) return 0;
    return (v + (1LL << s >> 1)) >> s;
}

int main(int argc, char **argv)
{
    fx_init();
    if (argc > 1) SP_Q = atoi(argv[1]);

    /* deterministic LCG so the vector set is reproducible */
    uint64_t st = 0x9E3779B97F4A7C15ULL;
    #define NEXT() (st = st * 6364136223846793005ULL + 1442695040888963407ULL, \
                    (uint32_t)(st >> 33))

    int NC = 320;
    printf("%d %d\n", NC, SP_Q);

    for (int c = 0; c < NC; c++) {
        int32_t al_m, dt_m, a_m, b_m;
        int al_e, dt_e, a_e, b_e;

        if (c < 64) {
            /* PHYSICAL: the ranges the real Qwen3.8 weights occupy.
               ssm_a ~ -0.04, dt bias ~ -3.5, alpha small. */
            al_m = (int32_t)(NEXT() % 2001) - 1000;   al_e = 14;
            dt_m = -(int32_t)(NEXT() % 30000) - 2000; dt_e = 12;
            a_m  = -(int32_t)(NEXT() % 3000) - 1;     a_e  = 16;
            b_m  = (int32_t)(NEXT() % 60000) - 30000; b_e  = 12;
        } else if (c < 128) {
            /* wide exponents, both shift directions of site 3 */
            al_m = (int32_t)(NEXT() % 65535) - 32767; al_e = (int)(NEXT() % 25) - 4;
            dt_m = (int32_t)(NEXT() % 65535) - 32767; dt_e = (int)(NEXT() % 25) - 4;
            a_m  = -(int32_t)(NEXT() % 32767) - 1;    a_e  = (int)(NEXT() % 25) - 4;
            b_m  = (int32_t)(NEXT() % 65535) - 32767; b_e  = (int)(NEXT() % 25) - 4;
        } else if (c < 192) {
            /* softplus threshold region: |arg| near and beyond 16 */
            al_m = (int32_t)(NEXT() % 65535) - 32767; al_e = 11;
            dt_m = (int32_t)(NEXT() % 65535) - 32767; dt_e = 11;
            a_m  = -(int32_t)(NEXT() % 32767) - 1;    a_e  = 15;
            b_m  = (int32_t)(NEXT() % 65535) - 32767; b_e  = 11;
        } else if (c < 256) {
            /* drive g into the exp clamp at -16 and to the eg -> 0 floor */
            al_m = (int32_t)(NEXT() % 4000);          al_e = 10;
            dt_m = (int32_t)(NEXT() % 30000);         dt_e = 10;
            a_m  = -(int32_t)(NEXT() % 24768) - 8000; a_e  = 8;   /* stays inside s16 */
            b_m  = (int32_t)(NEXT() % 65535) - 32767; b_e  = 10;
        } else {
            /* degenerate corners: zeros, extremes of every mantissa */
            int pick = c % 8;
            al_m = (pick & 1) ? 0 : ((pick & 2) ? 32767 : -32768); al_e = 12;
            dt_m = (pick & 2) ? 0 : ((pick & 4) ? 32767 : -32768); dt_e = 12;
            a_m  = (pick & 4) ? -1 : -32768;                       a_e  = 12;
            b_m  = (pick & 1) ? 0 : ((pick & 4) ? 32767 : -32768); b_e  = 12;
        }

        /* ---------------- fixed path ----------------
           The softplus argument is formed on a WIDE grid and clamped ONCE.
           2.1.3 as written converts alpha and dt to Q separately and adds
           "in s32", which saturates each term before the add -- and two
           opposite-sign saturations cancel: a true argument of -34826 is
           computed as -1, turning a closed gate (eg 4) into an open one
           (eg 32768).  See docs/debugging/2026-08-26_gdn-scalar-path.md.
           Clamping to +/-16*2^q loses nothing: softplus is the identity
           above +16 and zero below -16 on every grid this model uses. */
        int64_t arg  = to_q_wide(al_m, al_e) + to_q_wide(dt_m, dt_e);
        int64_t lim  = 16LL << SP_Q;

        /* softplus on the wide grid.  Only the NEGATIVE tail may be clamped:
           below -16 the function is zero to well under an LSB.  The positive
           tail must NOT be clamped -- there softplus is the identity, so the
           argument's magnitude is exactly what propagates into g through the
           multiply by a, and pinning it at +16 turns a saturated gate into a
           wide-open one (case 88: eg 30280 against a true 0.0037). */
        int64_t sp;
        if      (arg <= -lim) sp = 0;
        else if (arg >=  lim) sp = arg;                 /* 1.1(f) identity */
        else                  sp = fx_softplus_q((int32_t)arg, SP_Q);

        int64_t gp   = sp * (int64_t)a_m;
        int64_t g64  = rshift_r(gp, a_e);
        if (g64 > 0) g64 = 0;                          /* min(0, .) guard */
        int64_t gmin = -16LL << SP_Q;
        int err_g = (g64 < gmin);                      /* clamped, 2.1.6 */
        if (g64 < gmin) g64 = gmin;
        int32_t g_q  = (int32_t)g64;

        int32_t eg_sp = fx_exp_q(g_q, SP_Q);
        /* output format is pinned Q15 regardless of the internal grid */
        int64_t eg_o  = rshift_r(eg_sp, SP_Q - 15);
        if (eg_o > 32768) eg_o = 32768;
        if (eg_o < 0) eg_o = 0;

        int32_t bq     = to_q(b_m, b_e);
        int32_t beta_sp = fx_sigmoid_q(bq, SP_Q);
        int64_t beta_o = rshift_r(beta_sp, SP_Q - 16);
        /* the recurrence port is unsigned(15 downto 0); Q16 1.0 = 65536 does
           not fit, so the top of the range saturates one LSB low. */
        if (beta_o > 65535) beta_o = 65535;
        if (beta_o < 0) beta_o = 0;

        /* ---------------- double oracle (no LUT, no grid) ------------- */
        double al_r = ldexp((double)al_m, -al_e);
        double dt_r = ldexp((double)dt_m, -dt_e);
        double a_r  = ldexp((double)a_m,  -a_e);
        double b_r  = ldexp((double)b_m,  -b_e);
        double sp_r = log1p(exp(al_r + dt_r));
        if (al_r + dt_r > 30.0) sp_r = al_r + dt_r;    /* avoid inf in exp */
        double g_r  = a_r * sp_r;
        if (g_r > 0) g_r = 0;
        if (g_r < -16.0) g_r = -16.0;
        double eg_r = exp(g_r) * 32768.0;
        double be_r = (1.0 / (1.0 + exp(-b_r))) * 65536.0;
        if (be_r > 65535.0) be_r = 65535.0;

        printf("%d %d %d %d %d %d %d %d  %lld %lld %d  %.6f %.6f\n",
               al_m, al_e, dt_m, dt_e, a_m, a_e, b_m, b_e,
               (long long)eg_o, (long long)beta_o, err_g,
               eg_r, be_r);
    }
    return 0;
}
