/* rmsnorm_bf_vec -- full-path reference vectors for rtl/rmsnorm_bf.vhd.
 *
 * WHAT THIS IS AND WHY IT IS NOT ref/rmsnorm_eps_vec.c.
 * rmsnorm_eps_vec settled the DESIGN: it models the gain 1/sqrt(mean+eps)
 * only, computes the square root in double, and answers "does the
 * block-floating form track ggml over the measured range".  It says nothing
 * about the rest of the unit -- the Newton rsqrt and its seed ROM, the weight
 * multiply, the max|raw| scan, shift_total, the emit rounding and saturation,
 * and o_exp.  Every one of those is a place a transcription can be wrong
 * while the gain is perfect.  This file models the WHOLE integer datapath,
 * bit for bit, and emits vectors that sim/tb_rmsnorm_bf.vhd checks with NO
 * tolerance.
 *
 * TWO INDEPENDENT PATHS, ON PURPOSE.
 *   1. rmsnorm_bf_int() -- the exact integer recipe, in the same order and at
 *      the same widths as the RTL, including every truncation.  This is what
 *      the testbench compares against, bit-exactly.
 *   2. rmsnorm_bf_dbl() -- the ideal result in double, computed from the int16
 *      inputs and the exponents alone.  It shares NO helper with (1): no
 *      shift, no msb scan, no rsqrt seed, no rounding rule.  It is written as
 *      the mathematical definition and nothing else.
 *
 * The second one is not optional and it is not decoration.  A golden that
 * shares machinery with the DUT certifies broken units: that is exactly how
 * the l2norm collapse of 2026-08-25 survived 55 passing cases, and it is why
 * tb_rmsnorm_rs.vhd -- whose golden is rmsnorm.vhd itself -- passes at every
 * magnitude while both units emit all zeros
 * (docs/debugging/2026-08-26_rmsnorm-magnitude-window.md).  Path (1) alone
 * would reproduce a wrong recipe faithfully.  Path (2) is the only thing in
 * this file that can notice the recipe is wrong at all.
 *
 * WHERE THE SWEEP RANGE COMES FROM.  Measured, not chosen: 963,486,720
 * samples of build_norm_gated's input on Qwen3.8-27B-Q4_K_M put log2(rms(o))
 * in [-29.63, -0.54], and 77.4% of samples have mean(x^2) < eps.  So the
 * eps-dominated region is the COMMON case, not a corner, and the sweep is
 * weighted into it rather than spread uniformly over round numbers.  The same
 * document records that sweeping [-30, +6] instead -- a range the model does
 * not occupy -- overstated the design's error by 66x.
 *
 * Build: cc -O2 -Wall -Wextra -o rmsnorm_bf_vec rmsnorm_bf_vec.c -lm
 * Usage: ./rmsnorm_bf_vec <out.txt> [ncase] [n] [seed] [Q] [eps]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>

/* ------------------------------------------------------------------------
 * Generics.  Mirrors of the RTL's, so a sweep here and a sweep of the DUT's
 * generics stay in step.
 */
static int    N   = 128;
static int    Q   = 12;
static double EPS = 1.0e-6;

/* Elaboration-time epsilon, resolved exactly as the RTL's E_EPS / M_EPS_C
 * constants are.  E_EPS is chosen so the mantissa normalises into
 * [2^30, 2^31), which is what makes it fit a 32-bit signed for ANY eps and
 * puts it on the grid the rsqrt seed already expects. */
static int     E_EPS;
static int64_t M_EPS;

/* The seed ROM, copied verbatim from rtl/fixed_luts_pkg.vhd.  It is COPIED
 * rather than shared through a header on purpose: the point of this file is to
 * be an independent transcription of the same specification, and a shared
 * table would make one class of RTL error (a table read at the wrong index
 * grid) undetectable.  If the ROM in the RTL ever changes, this must be
 * updated by hand and the mismatch will be loud rather than silent. */
static const int64_t RSQRT_ROM[64] = {
    1073741824, 1065450257, 1057347856, 1049427536, 1041682578, 1034106604, 1026693558, 1019437682,
    1012333500, 1005375799,  998559613,  991880210,  985333074,  978913898,  972618566,  966443148,
     960383883,  954437177,  948599586,  942867814,  937238702,  931709222,  926276469,  920937655,
     915690104,  910531246,  905458609,  900469818,  895562589,  890734723,  885984104,  881308694,
     876706528,  872175715,  867714429,  863320910,  858993459,  854730438,  850530263,  846391405,
     842312387,  838291779,  834328203,  830420321,  826566842,  822766514,  819018128,  815320510,
     811672525,  808073073,  804521086,  801015531,  797555404,  794139734,  790767575,  787438013,
     784150157,  780903145,  777696137,  774528319,  771398898,  768307107,  765252196,  762233438
};
static const int64_t INV_SQRT2_C = 759250125;    /* 2^30 / sqrt(2), Q30 */
static const int64_t THREE_Q30   = 3LL << 30;

/* ------------------------------------------------------------------------
 * Bit-level primitives that reproduce numeric_std EXACTLY.
 *
 * These exist because C's operators are not the VHDL ones.  Getting this
 * wrong is the single most likely way for a "golden" to be quietly different
 * from the unit it certifies, so each one names the VHDL construct it stands
 * for.
 */

/* shift_right(signed, natural).  Fills with the SIGN bit, and a count at or
 * beyond the width leaves all sign bits -- 0 for a positive value, -1 for a
 * negative one.  C's >> on a negative signed is implementation-defined, and a
 * count >= 64 is undefined outright, so neither is used. */
static int64_t vsrl_a(int64_t v, int sh)
{
    if (sh <= 0) return v;
    if (sh >= 64) return (v < 0) ? -1 : 0;
    int64_t d = (int64_t)1 << sh;
    int64_t q = v / d;
    if (v % d != 0 && v < 0) q -= 1;             /* floor, not truncate */
    return q;
}

/* shift_left(signed(63 downto 0), natural).  Bits shifted past the top are
 * DROPPED, and a count >= 64 leaves zero.  The RTL relies on that at
 * S_RQ_FIN1, where the rounding bias 1 << (-rq_E - 1) legitimately runs off
 * the end of the word for a deeply negative rq_E and must become 0, not UB. */
static int64_t vsll64(int64_t v, int sh)
{
    if (sh <= 0) return v;
    if (sh >= 64) return 0;
    return (int64_t)(((uint64_t)v) << sh);
}

/* resize(signed, w) when w SHRINKS the operand: numeric_std keeps the sign bit
 * and the rightmost w-1 bits, so it is not a plain mask and not a saturation.
 * Every narrowing site in the RTL is bounded by an assert, so in a passing run
 * this is the identity -- but modelling it as the identity would hide exactly
 * the case where an assert is wrong. */
static int64_t vresize(int64_t v, int w)
{
    if (w >= 64) return v;
    uint64_t low = (uint64_t)v & ((((uint64_t)1) << (w - 1)) - 1);
    int64_t  r   = (int64_t)low;
    if (v < 0) r -= ((int64_t)1) << (w - 1);
    return r;
}

/* The RTL's MSB scan, which is a loop over bits 0..62 recording the LAST set
 * one.  msb(0) = 0 is therefore normative here as it is in mv4i_arith.h --
 * the scan simply never fires and p keeps its initial 0. */
static int vmsb63(int64_t v)
{
    int p = 0;
    for (int i = 0; i <= 62; i++) if ((v >> i) & 1) p = i;
    return p;
}

/* ------------------------------------------------------------------------
 * PATH 1: the integer datapath, state by state.
 *
 * The state names in the comments are the RTL's, so a divergence can be
 * bisected by state rather than by guesswork.
 */
typedef struct {
    int      o_exp;
    int16_t  o[8192];
    /* diagnostics, not part of the compare */
    int64_t  S, msq, inv32, max_raw;
    int      shift_total, e_out, saturations;
} bf_out;

static int bf_fail;      /* set when a run trips a bound the RTL asserts */

/* Branch coverage of the integer path.
 *
 * A vector set that passes proves only what it reached.  This project has
 * already been burned by a sweep that stopped two octaves short of a hard
 * failure and reported the rail REFUTED, so the generator counts the branches
 * it drove and names the ones it did not.  An unreached branch is reported as
 * unverified rather than left for the reader to assume. */
enum { COV_S0, COV_SHS_UP, COV_SHS_DN, COV_MEAN_SMALLER, COV_EPS_SMALLER,
       COV_D_CLAMP, COV_ODD, COV_EVEN, COV_E_UP, COV_E_DN, COV_E_BIG,
       COV_CLAMP_HI, COV_CLAMP_LO, COV_ST0, COV_SAT_HI, COV_SAT_LO, COV_NCOV };
static long cov[COV_NCOV];
static const char *cov_name[COV_NCOV] = {
    "S = 0 (mean exactly zero)",
    "S renormalise shifts LEFT (shs >= 0)",
    "S renormalise shifts RIGHT (shs < 0)",
    "mean is the smaller term",
    "eps is the smaller term",
    "alignment distance clamped at 63",
    "rq_d odd (1/sqrt2 fold)",
    "rq_d even",
    "rq_E >= 0 (inv32 shifts LEFT)",
    "rq_E < 0 (inv32 shifts RIGHT, rounded)",
    "rq_E > 32 (inv32 pinned to 2^31-1)",
    "inv32 clamped HIGH",
    "inv32 clamped LOW (to zero)",
    "shift_total = 0 (no emit shift)",
    "emit saturates at +32767",
    "emit saturates at -32768"
};

static void rmsnorm_bf_int(const int16_t *xm, int xe,
                           const int16_t *wm, int we, bf_out *r)
{
    int lg = 0; { int t = N; while (t >>= 1) lg++; }        /* LOG2N */

    /* ---- S_ACC: the exact sum of squares.  Lane order is irrelevant: this
     * is an exact integer sum, which is the whole reason the RTL's
     * LANES-parallel reduction is bit-exact rather than merely close. */
    int64_t S = 0;
    for (int i = 0; i < N; i++) S += (int64_t)xm[i] * (int64_t)xm[i];
    r->S = S;

    /* The bound the RTL asserts.  It is attained EXACTLY, not approached:
     * xm = -32768 gives xm^2 = 2^30, so an all -32768 vector reaches
     * N * 2^30 = 2^(30+lg).  See the note in the RTL. */
    if (S < 0 || S > (int64_t)1 << (30 + lg)) {
        fprintf(stderr, "rmsnorm_bf_vec: S = %lld out of the asserted range\n",
                (long long)S);
        bf_fail = 1;
    }

    /* ---- S_INV1 / S_INV2: renormalise S to a 31-bit mantissa and carry the
     * exponent with it.  mean = S * 2^-lg * 2^-2xe, so in (m, e) form m = S
     * and e = lg + 2xe; shifting the mantissa by shs shifts e with it. */
    int s_msb  = vmsb63(S);
    int shs    = 30 - s_msb;
    int e_mean = lg + 2 * xe + shs;

    /* ---- S_INV3 */
    int64_t m_mean;
    if (S == 0)      { m_mean = 0; cov[COV_S0]++; }
    else if (shs >= 0) { m_mean = vsll64(S, shs);  cov[COV_SHS_UP]++; }
    else               { m_mean = vsrl_a(S, -shs); cov[COV_SHS_DN]++; }

    /* ---- S_INV4: align to the LARGER value, i.e. the SMALLER e.  A larger e
     * is a finer grid and so a smaller value at equal mantissa.  Note the
     * e_mean == E_EPS tie goes to the "eps is smaller" branch with d = 0,
     * which is the same arithmetic either way. */
    int d, mean_smaller, e_out;
    if (S == 0) {
        /* mean is exactly zero, so the sum is eps alone and e_mean is
         * meaningless.  Without this branch a garbage e_mean drives the
         * alignment. */
        d = 0; mean_smaller = 1; e_out = E_EPS;
    } else if (e_mean > E_EPS) {
        d = e_mean - E_EPS; if (d > 63) { d = 63; cov[COV_D_CLAMP]++; }
        mean_smaller = 1; e_out = E_EPS; cov[COV_MEAN_SMALLER]++;
    } else {
        d = E_EPS - e_mean; if (d > 63) { d = 63; cov[COV_D_CLAMP]++; }
        mean_smaller = 0; e_out = e_mean; cov[COV_EPS_SMALLER]++;
    }

    /* ---- S_INV5: TRUNCATING, no rounding bias.  The term shifted here is by
     * construction the negligible one; over 14,800 random vectors rounding
     * and truncating agree to five significant figures, so the rounding form
     * would cost a bias state and a 64-bit add state for nothing. */
    int64_t align;
    if (S == 0)           align = 0;
    else if (mean_smaller) align = vsrl_a(m_mean, d);
    else                   align = vsrl_a(M_EPS,  d);

    /* ---- S_INV6 */
    int64_t msq = mean_smaller ? (align + M_EPS) : (m_mean + align);
    r->msq = msq; r->e_out = e_out;

    /* ---- S_SEED1 / S_SEED2: normalise msq so bit 30 is set, then index the
     * ROM on bits 29..24 of the normalised mantissa. */
    int      rq_p = vmsb63(msq);
    uint64_t A    = (uint64_t)msq;
    uint64_t mant = (rq_p <= 30) ? (A << (30 - rq_p)) : (A >> (rq_p - 30));
    if (((mant >> 30) & 1) == 0) {
        fprintf(stderr, "rmsnorm_bf_vec: rsqrt mantissa not normalised to Q30\n");
        bf_fail = 1;
    }
    int64_t rq_smant = (int64_t)(uint32_t)mant;         /* signed(31 downto 0) */
    int64_t rq_y     = RSQRT_ROM[(mant >> 24) & 0x3F];

    /* ---- S_RQ: two Newton iterations, y <- y*(3 - m*y^2)/2 in Q30.
     * The RTL spends three FSM steps per multiply to buy MREG+PREG; the
     * arithmetic those steps perform is exactly the four lines below per
     * iteration, and the step count is a timing artefact with no numeric
     * content.  Modelling the cadence here would add nothing and would couple
     * the golden to the pipeline shape, which is the coupling to avoid. */
    for (int it = 0; it < 2; it++) {
        int64_t y2   = vresize(vsrl_a(vresize(rq_y * rq_y, 66), 30), 32);
        int64_t my2  = vresize(rq_smant * y2, 66);
        int64_t diff = vresize(THREE_Q30 - vresize(vsrl_a(my2, 30), 34), 34);
        int64_t prod = vresize(diff * rq_y, 66);
        rq_y = vresize(vsrl_a(prod, 31), 32);
    }

    /* ---- S_RQ_FOLD.  rq_d = rq_p - e_out, NOT rq_p - Q: msq is no longer on
     * a fixed 2^-Q grid, it is on 2^-e_out.  An odd rq_d leaves half an
     * octave that the halving cannot take, so it is folded into the mantissa
     * by 1/sqrt(2).
     *
     * VHDL's `mod` takes the sign of its RIGHT operand and C's `%` takes the
     * sign of its left, so the two disagree for a negative rq_d -- but only
     * in sign, never in whether the result is zero, and only the zero test is
     * used.  VHDL's `/` and C's `/` both truncate toward zero, so (rq_d-1)/2
     * and rq_d/2 agree exactly.  rq_d IS negative in the whole eps-dominated
     * region, so this is not a hypothetical. */
    int     rq_d = rq_p - e_out;
    int64_t rq_yfin;
    int     rq_he;
    if ((rq_d % 2) != 0) {
        rq_yfin = vresize(vsrl_a(rq_y * INV_SQRT2_C, 30), 32);
        rq_he   = (rq_d - 1) / 2;
        cov[COV_ODD]++;
    } else {
        rq_yfin = rq_y;
        rq_he   = rq_d / 2;
        cov[COV_EVEN]++;
    }
    int rq_E = Q - 30 - rq_he;

    /* ---- S_RQ_FIN1 / FIN2 / FIN3 / CLAMP.  Split three ways in the RTL for
     * timing; the value is one rounded shift and a clamp into u31. */
    int64_t rq_bias = (rq_E >= 0) ? 0 : vsll64(1, (-rq_E) - 1);
    int64_t rq_sum  = rq_yfin + rq_bias;
    int64_t rq_shifted;
    if (rq_E > 32)      { rq_shifted = 2147483647LL;            cov[COV_E_BIG]++; }
    else if (rq_E >= 0) { rq_shifted = vsll64(rq_yfin, rq_E);    cov[COV_E_UP]++;  }
    else                { rq_shifted = vsrl_a(rq_sum, -rq_E);    cov[COV_E_DN]++;  }

    int64_t inv32 = rq_shifted;
    if (inv32 > 2147483647LL) { inv32 = 2147483647LL; cov[COV_CLAMP_HI]++; }
    if (inv32 < 0)            { inv32 = 0;            cov[COV_CLAMP_LO]++; }
    r->inv32 = inv32;

    /* ---- S_RAW: raw = (xm * inv32) * wm.  Narrowed s16 x s32 -> s48 then
     * s48 x s17 -> s64 in the RTL; lossless because |xm| <= 32768 and
     * |inv32| <= 2^31-1 give |xm*inv| < 2^46, and |wm| <= 32768 then gives
     * |raw| < 2^61.  The resizes are modelled anyway so a violated bound
     * shows up as a mismatch rather than as a silently correct answer. */
    int64_t raw[8192];
    int64_t max_raw = 0;
    for (int j = 0; j < N; j++) {
        int64_t xi = vresize((int64_t)xm[j] * inv32, 48);
        raw[j] = vresize(xi * (int64_t)wm[j], 64);
        int64_t a = raw[j] < 0 ? -raw[j] : raw[j];
        if (a > max_raw) max_raw = a;          /* a maximum: order-independent */
    }
    r->max_raw = max_raw;

    /* ---- S_SHIFT1 / S_SHIFT2 */
    int msb_p = vmsb63(max_raw);
    int st    = msb_p - 14; if (st < 0) st = 0;
    r->shift_total = st;
    r->o_exp = xe + we + Q - st;
    if (st == 0) cov[COV_ST0]++;
    int64_t emit_bias = (st == 0) ? 0 : vsll64(1, st - 1);

    /* ---- S_EMIT: raw is RECOMPUTED here in the RTL rather than stored,
     * which is forbidden to change (rmsnorm.vhd records that the stored form
     * inferred as uninitialised distributed RAM and produced non-deterministic
     * hardware).  The value is identical, so the model reuses it. */
    r->saturations = 0;
    for (int j = 0; j < N; j++) {
        int64_t om = vsrl_a(raw[j] + emit_bias, st);
        if (om > 32767)       { r->o[j] =  32767; r->saturations++; cov[COV_SAT_HI]++; }
        else if (om < -32768) { r->o[j] = -32768; r->saturations++; cov[COV_SAT_LO]++; }
        else                    r->o[j] = (int16_t)om;
    }
}

/* ------------------------------------------------------------------------
 * PATH 2: the double oracle.
 *
 * Deliberately written as the DEFINITION and nothing else.  It calls none of
 * the helpers above, knows nothing about Q, e_out, the seed ROM, shift_total
 * or saturation, and would not change if every one of them were rewritten.
 * Its only shared input with path 1 is the int16 data and the two exponents.
 */
static void rmsnorm_bf_dbl(const int16_t *xm, int xe,
                           const int16_t *wm, int we, double *out)
{
    double sum = 0.0;
    for (int i = 0; i < N; i++) {
        double xr = ldexp((double)xm[i], -xe);
        sum += xr * xr;
    }
    double g = 1.0 / sqrt(sum / (double)N + EPS);
    for (int i = 0; i < N; i++)
        out[i] = ldexp((double)xm[i], -xe) * g * ldexp((double)wm[i], -we);
}

/* ------------------------------------------------------------------------ */
static uint64_t rs;
static uint32_t rnd(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

/* Build one case's stimulus.  Returns the (xe, we) pair through the pointers.
 *
 * The generator is structured, not uniform.  A uniform draw over int16 with a
 * uniform exponent lands almost nowhere the model actually is, and the
 * measured distribution says the eps-dominated region is 77.4% of real
 * samples -- so it gets the bulk of the cases here too.  The structured cases
 * at the front are the sites where a transcription error can hide: the
 * exponent bound, the S = 0 branch, the alignment tie, the saturation rails
 * and the max|raw| scan.
 */
/* Find a case that SATURATES the emit stage, by construction rather than by
 * luck.
 *
 * Saturation is reachable but vanishingly rare on random data, and the reason
 * is worth stating because it is a property of the recipe rather than of this
 * generator.  shift_total = msb(max_raw) - 14, so max_raw >> shift_total lands
 * in [2^14, 2^15) -- inside int16 by construction.  The ONLY way out is the
 * emit rounding bias: the element that IS max_raw saturates exactly when
 * max_raw sits in the top 2^(shift_total-1) of its octave, which is one part
 * in 2^15.  Over 200 random cases the expected count is 0.006.
 *
 * The negative rail is UNREACHABLE for the same reason, and this is a
 * conclusion rather than an omission: om = floor((raw + bias) / 2^st) with
 * raw >= -max_raw and bias >= 0 gives om >= -2^15, and -32768 is inside the
 * range, so no positive bias can drive it below.  The tb therefore proves the
 * +32767 rail and cannot prove the -32768 one; that is recorded rather than
 * papered over.
 *
 * The search below is stimulus SELECTION, not golden computation -- it may
 * use the integer model freely, because what it produces is an (xm, wm, xe,
 * we) tuple and nothing else.  With every element equal, raw is the same for
 * all j so max_raw = |raw| exactly, which makes the condition a one-line test
 * over wm rather than a rejection sample at 3e-5.
 */
static int find_saturating(int16_t *xm, int16_t *wm, int *xe, int *we)
{
    static bf_out probe;
    const int A = 21341;                 /* arbitrary, not a power of two */
    for (int i = 0; i < N; i++) { xm[i] = (int16_t)A; wm[i] = 1; }
    for (int e = 10; e <= 44; e++) {
        rmsnorm_bf_int(xm, e, wm, 0, &probe);
        int64_t cst = (int64_t)A * probe.inv32;
        if (cst <= 0) continue;
        for (int u = 1; u <= 32767; u++) {
            int64_t raw = cst * (int64_t)u;
            int st = vmsb63(raw) - 14; if (st < 1) continue;
            if (vsrl_a(raw + vsll64(1, st - 1), st) > 32767) {
                for (int i = 0; i < N; i++) wm[i] = (int16_t)u;
                *xe = e; *we = 12;
                return 1;
            }
        }
    }
    return 0;
}

static void make_case(int c, int16_t *xm, int16_t *wm, int *xe, int *we)
{
    int sel = c % 40;

    /* log2(rms_real) target.  With flat mantissas near 2^14, rms_mant ~ 2^14
     * and rms_real = 2^(14-xe), so xe = 14 - k reaches log2(rms) = k.  The
     * model's measured range is k in [-29.63, -0.54]; the sweep runs a little
     * past both ends so the rails are visible rather than assumed. */
    int k;

    switch (sel) {
    case 0:   /* all zero: forces the S = 0 branch, where e_mean is garbage and
               * the sum must be epsilon alone.  On its own this does NOT test
               * that branch -- see case 11, which explains why and does. */
        for (int i = 0; i < N; i++) { xm[i] = 0; wm[i] = 12345; }
        *xe = 20; *we = 12; return;

    case 1:   /* the exact upper bound on S.  xm = -32768 gives xm^2 = 2^30
               * exactly, so N of them reach S = 2^(30+log2 N) -- the RTL's
               * assert bound, ATTAINED, not approached.  An assert written
               * with a strict < fires here on legal int16 input. */
        for (int i = 0; i < N; i++) { xm[i] = -32768; wm[i] = 32767; }
        *xe = 24; *we = 12; return;

    case 2:   /* mixed saturation, which drives |xm*inv| to the bound that
               * licenses the s48 narrowing of the first multiply */
        for (int i = 0; i < N; i++) { xm[i] = (i & 1) ? -32768 : 32767; wm[i] = -32768; }
        *xe = 26; *we = 14; return;

    case 3:   /* one large element against zeros: max|raw| comes from a SINGLE
               * lane, so a lane-parallel max that dropped a lane cannot hide */
        for (int i = 0; i < N; i++) { xm[i] = 0; wm[i] = 1000; }
        xm[N-1] = 32767;
        *xe = 22; *we = 12; return;

    case 4:   /* the same spike at the FIRST element.  Both ends, because a
               * lane-parallel reduction can lose the first or the last group
               * for different reasons. */
        for (int i = 0; i < N; i++) { xm[i] = 0; wm[i] = 1000; }
        xm[0] = 32767;
        *xe = 22; *we = 12; return;

    case 5:   /* exact powers of two: max|raw| lands on a bit boundary, where
               * the MSB scan and shift_total are most easily off by one */
        for (int i = 0; i < N; i++) { xm[i] = 1024; wm[i] = 256; }
        *xe = 24; *we = 8; return;

    case 6:   /* smallest nonzero input.  S = N, so s_msb = log2 N and the
               * renormalising shift is a deep LEFT shift, the opposite branch
               * from every large case. */
        for (int i = 0; i < N; i++) { xm[i] = 1; wm[i] = 1; }
        *xe = 0; *we = 0; return;

    case 7:   /* w = 0: raw is identically zero, so max_raw = 0 and the msb
               * scan returns its normative 0 rather than firing. */
        for (int i = 0; i < N; i++) { xm[i] = (int16_t)(rnd() >> 16); wm[i] = 0; }
        *xe = 20; *we = 12; return;

    case 8:   /* the +32767 emit rail, constructed.  See find_saturating. */
        if (find_saturating(xm, wm, xe, we)) return;
        /* Not found is a real result, not a fallback to ignore: it would mean
         * the rail is unreachable at this N and the tb cannot claim it. */
        fprintf(stderr, "rmsnorm_bf_vec: NOTE no saturating case found at "
                        "N=%d Q=%d; the +32767 rail is unproven\n", N, Q);
        for (int i = 0; i < N; i++) { xm[i] = 32767; wm[i] = 32767; }
        *xe = 20; *we = 12; return;

    case 9:   /* FAR below the model's range: xe = 80 puts log2(rms) near -66,
               * which drives e_mean - E_EPS past 63 and exercises the
               * alignment distance CLAMP.  The clamp is a guard against a
               * shift count leaving the word, and a sweep that stops at the
               * model's rails never reaches it.  Two octaves short of a rail
               * is exactly how the upper limit of the shipped unit was
               * reported REFUTED once already. */
        for (int i = 0; i < N; i++) {
            xm[i] = (int16_t)(rnd() >> 16);
            wm[i] = (int16_t)(rnd() >> 16);
        }
        *xe = 80; *we = 12; return;

    case 10:  /* FAR above it, for the other side of the same clamp: xe = -30
               * puts e_mean near -53, so E_EPS - e_mean passes 63 and the eps
               * term is the one that falls off the bottom. */
        for (int i = 0; i < N; i++) {
            xm[i] = (int16_t)(rnd() >> 16);
            wm[i] = (int16_t)(rnd() >> 16);
        }
        *xe = -30; *we = 6; return;

    case 11:  /* all zero at a small x_exp, and this one is NOT redundant with
               * case 0.  It exists because of a mutation result worth stating
               * in full, since it says what the output ports can and cannot
               * see.
               *
               * S = 0 means every xm is zero, so every raw is zero, so
               * max_raw = 0, shift_total = 0 and the output is all zeros with
               * o_exp = xe + we + Q -- whatever inv32 turned out to be.  The
               * S = 0 guards in S_INV3/4/5 are therefore INVISIBLE at
               * o_mant / o_exp by construction: deleting all three passes the
               * comparison at any x_exp.  No vector can fix that, because the
               * quantity they change never reaches an output.
               *
               * What they do change is whether the unit stays inside its own
               * stated assumptions.  Ungated, e_mean is the meaningless
               * log2 N + 2xe + 30, and once that falls far enough below E_EPS
               * the sum takes the eps-smaller branch and truncates M_EPS by
               * d = E_EPS - e_mean bits.  At eps = 1e-6 and log2 N = 7 that
               * reaches msq = 0 at xe <= -9, and msq = 0 fails the Q30
               * normalisation assert in S_SEED2.
               *
               * So xe = -12 makes the guard's absence a LOUD failure instead
               * of an invisible one.  The check is the assert, not the
               * compare -- which is the only handle there is on a branch whose
               * effect cannot propagate. */
        for (int i = 0; i < N; i++) { xm[i] = 0; wm[i] = 32767; }
        *xe = -12; *we = 0; return;

    case 12:  /* all zero at the e_mean = E_EPS crossing (xe = 6 puts the
               * meaningless e_mean at 49 against E_EPS = 50), so the ungated
               * path flips branch here without yet reaching msq = 0 */
        for (int i = 0; i < N; i++) { xm[i] = 0; wm[i] = -9999; }
        *xe = 6; *we = 3; return;

    default:
        /* The bulk.  k is weighted into the eps-dominated region because that
         * is where 77.4% of real samples sit; the crossover mean ~ eps is at
         * k ~ -9.97 and gets its own band so the alignment is exercised with
         * BOTH terms materially present, which is the one place the recipe
         * has to be right for a reason other than one term vanishing. */
        if      (sel < 19) k = -12 + (int)(rnd() % 5);      /* crossover band */
        else if (sel < 35) k = -31 + (int)(rnd() % 21);     /* eps-dominated  */
        else               k = -10 + (int)(rnd() % 12);     /* mean-dominated */
        break;
    }

    /* Random mantissas with a random amplitude inside the octave.  Flat
     * mantissas are NOT used for the bulk: they make rms exactly a power of
     * two and exercise exactly one value of S per octave, and that shape
     * understated the shipped unit's defect by two orders of magnitude
     * (6.6e-3 against a true 1.0).  Any sweep over this unit must randomise
     * the mantissas. */
    int amp = 1 + (int)(rnd() % 32767);
    for (int i = 0; i < N; i++) {
        xm[i] = (int16_t)((int)(rnd() % (2u * (unsigned)amp + 1u)) - amp);
        wm[i] = (int16_t)(rnd() >> 16);
    }
    /* xe places the octave; the amplitude drawn above is folded out so k is
     * the real log2(rms) rather than an upper bound on it. */
    double ms = 0.0;
    for (int i = 0; i < N; i++) ms += (double)xm[i] * (double)xm[i];
    ms /= (double)N;
    int lgr = (ms > 0.0) ? (int)floor(0.5 * log2(ms)) : 14;
    *xe = lgr - k;
    *we = (int)(rnd() % 25) - 4;
}

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "rmsnorm_bf_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 200;
    N         = (argc > 3) ? atoi(argv[3]) : 128;
    rs        = (argc > 4) ? strtoull(argv[4], NULL, 10) : 20260826ULL;
    Q         = (argc > 5) ? atoi(argv[5]) : 12;
    EPS       = (argc > 6) ? atof(argv[6]) : 1.0e-6;
    if (rs == 0) rs = 1;

    E_EPS = 30 - (int)floor(log2(EPS));
    M_EPS = (int64_t)llround(ldexp(EPS, E_EPS));
    if (M_EPS > 2147483647LL) {
        fprintf(stderr, "rmsnorm_bf_vec: M_EPS does not fit a VHDL integer\n");
        return 3;
    }

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    /* Header carries the ELABORATION-TIME constants as well as the shape.  The
     * testbench recomputes E_EPS and M_EPS from its own EPS generic and
     * asserts equality, which catches a mismatched epsilon before any vector
     * is compared -- a failure that would otherwise present as 200 wrong
     * cases with no indication of why. */
    fprintf(f, "%d %d %d %d %lld\n", ncase, N, Q, E_EPS, (long long)M_EPS);

    /* TWO metrics, because relative error alone is a trap on a quantizer.  An
     * output whose true value is under an LSB of its own grid reports a huge
     * relative error while the quantizer is working correctly, so absolute
     * error in LSB of the output grid is the honest metric and relative error
     * is reported only where the magnitude is well clear of the grid.  The
     * threshold is 1024 LSB and not 16: at 64 LSB half an LSB is already
     * 7.8e-3, so a lower bar reports the output word length back as if it
     * were an error in the recipe.  That is the same mistake as measuring a
     * grid defect in LSB of the grid it corrupts. */
    double worst_lsb = 0.0;  int wl_case = -1;
    double worst_rel = 0.0;  int wr_case = -1;  long nrel = 0;
    /* The gain is what the design changed, so it is measured on its own too:
     * inv32 * 2^-Q against 1/sqrt(mean+eps) in double.
     *
     * It is reported TWICE.  Over the whole sweep the worst case is set by
     * the top of the range, where the gain is small and half an LSB of the
     * fixed 2^-Q output grid of inv32 is a large fraction of it -- that is
     * output quantization, not the block-floating recipe, and the same effect
     * is what made the design study quote 8.8e-3 over [-30, +6] against
     * 1.33e-4 over the range the model occupies.  So the second figure
     * restricts to the MEASURED model range, log2(rms) in [-29.63, -0.54]
     * (963,486,720 samples, see the debugging note), which is the number that
     * says whether this unit is fit for the model. */
    double worst_gain = 0.0;  int wg_case = -1;  double wg_l2rms = 0.0;
    double worst_gain_m = 0.0; int wgm_case = -1; long n_in_model = 0;
    long nsat = 0, nzero_out = 0, neps_dom = 0;
    /* The UPPER RAIL, tracked separately from the error metrics.  inv32 is an
     * integer 2^Q / sqrt(mean+eps), so once the gain falls below 2^-Q it
     * rounds to zero and the unit emits zeros.  At Q = 12 that is
     * log2(rms) = +12.  This is the same rail the shipped unit has and it is
     * NOT what rmsnorm_bf set out to move -- the fix was the LOW end and the
     * eps.  It is quoted here because it is 12.5 octaves above the model's
     * measured maximum of 2^-0.54, so it is margin rather than a hazard, and
     * because leaving it unmeasured is how it went unnoticed the first time.
     * A rail is not an arithmetic error, so railed cases are excluded from
     * the gain error above and counted here instead. */
    long n_rail = 0; double rail_lo = 1e9;

    int16_t *xm = malloc((size_t)N * sizeof(int16_t));
    int16_t *wm = malloc((size_t)N * sizeof(int16_t));
    double  *od = malloc((size_t)N * sizeof(double));
    bf_out  *r  = malloc(sizeof(bf_out));
    if (!xm || !wm || !od || !r) { fprintf(stderr, "oom\n"); return 1; }

    for (int c = 0; c < ncase; c++) {
        int xe, we;
        make_case(c, xm, wm, &xe, &we);

        rmsnorm_bf_int(xm, xe, wm, we, r);
        if (bf_fail) { fprintf(stderr, "rmsnorm_bf_vec: aborted at case %d\n", c); return 2; }
        rmsnorm_bf_dbl(xm, xe, wm, we, od);

        fprintf(f, "%d %d %d %d\n", c, xe, we, r->o_exp);
        for (int i = 0; i < N; i++) fprintf(f, "%d ", xm[i]);
        fprintf(f, "\n");
        for (int i = 0; i < N; i++) fprintf(f, "%d ", wm[i]);
        fprintf(f, "\n");
        for (int i = 0; i < N; i++) fprintf(f, "%d ", r->o[i]);
        fprintf(f, "\n");

        nsat += r->saturations;

        /* --- gain check, path 1 against path 2, sharing nothing --- */
        double sum = 0.0;
        for (int i = 0; i < N; i++) {
            double xr = ldexp((double)xm[i], -xe);
            sum += xr * xr;
        }
        double mean = sum / (double)N;
        if (mean < EPS) neps_dom++;
        double g_want = 1.0 / sqrt(mean + EPS);
        double g_got  = ldexp((double)r->inv32, -Q);
        double grel   = fabs(g_got - g_want) / g_want;
        double l2rms = (mean > 0.0) ? 0.5 * log2(mean) : -99.0;
        if (r->inv32 == 0 && g_want > 0.0) {
            n_rail++;
            if (l2rms < rail_lo) rail_lo = l2rms;
            grel = 0.0;                      /* railed, not mis-computed */
        }
        if (grel > worst_gain) { worst_gain = grel; wg_case = c; wg_l2rms = l2rms; }
        if (l2rms >= -29.63 && l2rms <= -0.54) {
            n_in_model++;
            if (grel > worst_gain_m) { worst_gain_m = grel; wgm_case = c; }
        }

        /* --- output check, in LSB of the emitted grid --- */
        for (int i = 0; i < N; i++) {
            double want_lsb = ldexp(od[i], r->o_exp);      /* the true value, in LSB */
            /* Saturated elements are excluded from the error metrics: the
             * emitted value is deliberately not the true one there, and
             * counting the clip as an arithmetic error would drown the
             * numbers that matter.  The count is reported instead. */
            if (r->o[i] == 32767 || r->o[i] == -32768) continue;
            double lsb = fabs((double)r->o[i] - want_lsb);
            if (lsb > worst_lsb) { worst_lsb = lsb; wl_case = c; }
            if (r->o[i] == 0 && xm[i] != 0 && wm[i] != 0) nzero_out++;
            if (fabs(want_lsb) >= 1024.0) {
                double rel = lsb / fabs(want_lsb);
                nrel++;
                if (rel > worst_rel) { worst_rel = rel; wr_case = c; }
            }
        }
    }
    fclose(f);

    fprintf(stderr, "rmsnorm_bf_vec: %d cases x %d -> %s (Q=%d eps=%.3e "
                    "E_EPS=%d M_EPS=%lld)\n",
            ncase, N, out, Q, EPS, E_EPS, (long long)M_EPS);
    fprintf(stderr, "  eps-dominated cases (mean < eps): %ld of %d (%.1f%%), "
                    "against 77.4%% of real model samples\n",
            neps_dom, ncase, 100.0 * (double)neps_dom / (double)ncase);
    fprintf(stderr, "  worst rel err of the GAIN vs double, whole sweep: %.4e "
                    "(case %d, log2(rms) = %.2f)\n",
            worst_gain, wg_case, wg_l2rms);
    fprintf(stderr, "  worst rel err of the GAIN vs double, MODEL range:  %.4e "
                    "(case %d, %ld of %d cases in range)\n",
            worst_gain_m, wgm_case, n_in_model, ncase);
    fprintf(stderr, "  worst abs err of the OUTPUT vs double: %.4f LSB (case %d)\n",
            worst_lsb, wl_case);
    fprintf(stderr, "  worst rel err where |o| >= 1024 LSB: %.4e (case %d, %ld samples)\n",
            worst_rel, wr_case, nrel);
    fprintf(stderr, "  saturated elements: %ld   nonzero flushed to zero: %ld\n",
            nsat, nzero_out);
    if (n_rail)
        fprintf(stderr, "  UPPER RAIL: %ld case(s) with inv32 = 0, lowest at "
                        "log2(rms) = %.2f (model max is -0.54)\n", n_rail, rail_lo);
    else
        fprintf(stderr, "  UPPER RAIL: not reached (inv32 never underflowed)\n");

    /* The coverage report.  find_saturating's probe runs also land in these
     * counters, which is harmless: they are RTL branches either way, and the
     * point of the report is which branches were reached at all. */
    fprintf(stderr, "  branch coverage:\n");
    for (int i = 0; i < COV_NCOV; i++)
        fprintf(stderr, "    %-40s %s%ld\n", cov_name[i],
                cov[i] ? "" : "NOT REACHED, unverified: ", cov[i]);

    /* Which of the unreached ones are a GAP and which are structurally dead.
     * Saying "not reached" and stopping would leave a reader hunting for a
     * stimulus that cannot exist.  Each claim below is an argument, not an
     * observation, and each is worth re-checking if a width or a generic
     * moves.
     *
     *   rq_E >= 0 and inv32 clamped HIGH are NOT dead -- they are reached at
     *   Q >= 20 and Q >= 22 respectively, and both are covered by the generic
     *   sweep rather than by the default vector set.  The crossover is where
     *   2^Q / sqrt(eps) passes 2^31, i.e. Q > 31 - log2(1/sqrt(eps)) = 21.0
     *   at eps = 1e-6.
     *
     *   rq_E > 32 is DEAD at any usable Q.  msq lies in [2^30, 2^32) so
     *   rq_p is 30 or 31, and e_out = min(e_mean, E_EPS) <= E_EPS, so
     *   rq_d >= 30 - E_EPS and rq_E <= Q - 30 - floor(log2 eps)/2.  At
     *   eps = 1e-6 that is Q - 20, so the branch needs Q > 52.
     *
     *   inv32 clamped LOW is DEAD unconditionally.  rq_yfin and the rounding
     *   bias are both non-negative and shift_right of a non-negative value is
     *   non-negative, so rq_shifted can never be below zero.
     *
     *   emit saturating at -32768 is DEAD unconditionally, for the reason
     *   given at find_saturating: shift_total places max_raw >> shift_total
     *   inside [2^14, 2^15) and the emit bias is non-negative.
     *
     *   The alignment clamp on the EPS side (E_EPS - e_mean > 63) is reached
     *   only where the unit is already past its upper rail: it needs
     *   mean / eps > 2^63, i.e. rms > 2^21.5, and inv32 underflows to zero at
     *   rms = 2^Q. So it is exercised, but only in territory where the answer
     *   is zeros either way. */
    return 0;
}
