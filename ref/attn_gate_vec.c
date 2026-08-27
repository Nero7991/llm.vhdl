/* ref/attn_gate_vec.c -- vectors and golden for rtl/attn_gate.vhd.
 *
 * Subsystem C, sites 6b/6c/6d/6e: the output stage's per-element chain, from
 * the softmax accumulator and the raw gate word to the pre-pack value.
 *
 *     t[d]  : s24 = round_shift( o[d] * r, p + 1 )              site 6b
 *     sh          = qg_exp - 12
 *     zg[d] : s32 = round_shift( g_mant[d], sh )      sh >= 0    site 6c
 *                 = sat32( g_mant[d] << -sh )         sh <  0
 *     g15[d]: u16 = SIG(zg[d]), Q15, clamped to [0, 32767]       site 6d
 *     y[d]  : s24 = round_shift( t[d] * g15[d], 15 )             site 6e
 *
 * WHY THESE FOUR ARE ONE UNIT.  They are the C spec's own element-sequential
 * pipeline (3.5): one element per cycle, the reciprocal-multiply and the gate
 * activation running side by side on the same element and meeting at the gate
 * multiply.  Splitting them would create an interface between two halves of a
 * single cycle-per-element datapath and buy nothing.
 *
 * WHY IT WAS PICKED.  It is the only consumer of attn_recip's (p, r) pair and
 * the only producer of attn_emit's input, so it is the single unit that joins
 * the four already-verified ones -- attn_kv_quant (step 4), attn_score_q12
 * (steps 5b/6), attn_softmax (step 7) and attn_recip (step 8a) -- to the end of
 * the pipeline.  It also carries the last unbuilt nonlinearity in subsystem C.
 *
 * -------------------------------------------------------------------------
 * THE SIGMOID IS NOT COPIED FROM THE RTL, IT IS RECOMPUTED.  `SIG_ROM` in
 * rtl/fixed_luts_pkg.vhd is a 513-entry Q30 table over z in [-16, 16] at step
 * 1/16.  This file rebuilds that table from libm with llround rather than
 * transcribing the VHDL's numbers, deliberately: a transcription would make a
 * table drift invisible, while an independent construction makes it a
 * testbench FAILURE on the first vector.  ORACLE 3 then checks the rebuilt
 * table against sigmoid() to half an ulp, so the table is validated rather
 * than trusted.
 *
 * DOUBLE ORACLE, five checks, none sharing the integer path:
 *
 *   ORACLE 1, site 6b against double, with a DERIVED bound.  t must match
 *     o * 2^14 / s to within |o|/2^(p+1) + 0.5: the first term is the
 *     reciprocal's own floor error (attn_recip's r is floor(2^(p+15)/s), so
 *     it understates 1/s by less than 2^-(p+15) and the product understates by
 *     less than |o| * 2^-(p+15) * 2^14 = |o|/2^(p+1)), the second is the
 *     round.  `s` is generated here and (p, r) come from attn_recip_vec.c's
 *     core, included below; the CHECK uses 1.0/s in double and nothing else.
 *     attn_recip_vec.c's own ORACLE 4 deliberately declined to emit a golden
 *     for t, on the grounds that a golden for a value the unit does not
 *     produce is a claim about the wrong unit.  This is the unit that produces
 *     it.
 *
 *   ORACLE 2, site 6c recomputed EXACTLY in double.  zg must equal
 *     clip(floor(g_mant * 2^(12 - qg_exp) + 0.5)) on the right branch and
 *     clip(g_mant * 2^(12 - qg_exp)) on the left, evaluated with ldexp and
 *     floor and nothing else.  Exact where it matters: |g_mant| <= 2^15 and
 *     the shifted value is compared against the s32 rails, both far inside a
 *     double's 2^53.  The output grid's Q is written as a SECOND literal
 *     (ATTN_GT_Q_ORACLE) and is deliberately NOT defined in terms of
 *     ATTN_GT_Q -- attn_score_q12_vec.c records that sharing that constant let
 *     a mutation of 12 to 11 pass both of its oracles, because the golden
 *     moved with the path.
 *
 *   ORACLE 3, the sigmoid.  A transcendental, so the magnitude check needs a
 *     bound; every part of the bound is DERIVED and the exact invariants are
 *     asserted alongside it as equalities and inequalities, not as tolerances:
 *
 *     3a  TABLE.  |SIG_ROM[k] - sigmoid(z_k) * 2^30| <= 0.5 for all 513
 *         entries.  Half an ulp, exactly, not a tolerance.
 *     3b  MAGNITUDE.  |g15 - sigmoid(zg/2^12) * 2^15| <= 2.0397 counts.
 *         Derived, not chosen: linear interpolation of a twice-differentiable
 *         f over a step h errs by at most max|f''| h^2 / 8, and sigmoid'' =
 *         s(1-s)(1-2s) peaks at 1/(6*sqrt 3) = 0.0962250, so at h = 1/16 the
 *         chord error is 0.0962250/(8*256) * 2^15 = 1.5396 counts; the Q15
 *         round adds 0.5 and the table's own half ulp adds 0.5/2^15.  The
 *         measured worst over the whole s32 domain is 2.0292, inside it.
 *     3c  CHORD DIRECTION.  sigmoid is CONVEX for z < 0 and CONCAVE for z > 0,
 *         and z = 0 is exactly a table entry (k = 256), so no interval
 *         straddles the inflection.  A chord therefore lies ABOVE the curve
 *         below zero and BELOW it above zero, and the interpolation must sit
 *         on the corresponding side:  interp >= true - 1.5  for z < 0 (the
 *         1.5 admits one floor ulp from the >> Q and half a table ulp) and
 *         interp <= true + 0.5  for z > 0 (a floor can only reduce it).  This
 *         is what separates a correct interpolation from one that rounds where
 *         it should floor, or from a nearest-entry lookup: both stay inside
 *         3b's magnitude bound and neither survives this.
 *     3d  GRID EQUALITY.  Where frac = 0 the interpolation must return the
 *         table entry EXACTLY, and at zg = 0 in particular g15 must be
 *         16384 exactly.  Not a bound.
 *     3e  CLAMPS, exactly.  zg <= -16*2^12 gives 0 and zg >= 16*2^12 gives
 *         32767, and nothing else does either... except that the interpolated
 *         branch reaches 32767 too, from zg = 40927 upward, because
 *         round_shift(SIG_ROM[511], 15) is already 32768 before the clamp.
 *         That is checked as a reachability fact, not assumed.
 *     3f  MONOTONICITY, over a dedicated ascending sweep of the whole domain:
 *         zg1 < zg2 implies g15(zg1) <= g15(zg2).  Exact, no tolerance.  A
 *         sign error inside the index split violates this immediately while
 *         staying inside every magnitude bound on random data.
 *
 *   ORACLE 4, site 6e locally.  |y - t*g15/2^15| <= 0.5 exactly -- the round
 *     is the only operation, so this admits nothing else.
 *
 *   ORACLE 5, the whole chain against double, bound COMPOSED from the parts:
 *     |y - (o * 2^14 / s) * sigmoid(zg_real)| <=
 *          sigmoid * (|o|/2^(p+1) + 0.5)  +  |t| * 2.0397/2^15  +  0.5
 *     which is the only check that would catch a chain that is internally
 *     consistent but scaled wrong -- a Q moved on both sides at once.
 *
 * SATURATION, and which of the three is REACHABLE.  Site 6c's sat32 is
 * reachable and legal: a gate word with a small qg_exp shifts left past s32,
 * and the sigmoid then clamps anyway, so the vector set contains it and the
 * count is a golden.  Site 6b's s24 saturate is NOT reachable under contract
 * -- |o/s| <= 127 because o is a convex combination of v_aligned values with
 * |v_aligned| <= 127, so |t| < 127 * 2^14 < 2^21 -- and site 6e's cannot fire
 * once t is bounded, since g15 < 2^15.  Both are width guards.  The generator
 * therefore keeps |o| <= 127*s and asserts the two never fire; the testbench
 * violates the contract deliberately in a final probe phase, the way
 * tb_attn_recip drives s = 0, because a guard no vector reaches is a comment.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_gate_vec attn_gate_vec.c -lm
 * Usage: ./attn_gate_vec [out.txt] [ncase] [n]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

#define ATTN_RECIP_INCLUDE
#include "attn_recip_vec.c"

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_GT_Q         12   /* the gate argument's grid, the score grid   */
#define ATTN_GT_GQ        15   /* the sigmoid output's Q                     */
#define ATTN_GT_T_W       24
#define ATTN_GT_Y_W       24
#define ATTN_GT_LSH_CLAMP 32
#define ATTN_GT_SIG_N     512  /* SIG_ROM intervals over [-16, 16]           */

/* Restated independently for the oracles.  See the ORACLE 2 paragraph: a
 * constant shared between the thing under test and the thing testing it is not
 * a check, it is a restatement. */
#define ATTN_GT_Q_ORACLE  12
#define ATTN_GT_GQ_ORACLE 15

/* The Q30 sigmoid table, REBUILT from libm rather than transcribed from
 * rtl/fixed_luts_pkg.vhd.  See the header. */
static int64_t sig_rom[ATTN_GT_SIG_N + 1];
static int     sig_rom_ready = 0;

static void sig_rom_init(void)
{
    for (int k = 0; k <= ATTN_GT_SIG_N; k++) {
        double z = -16.0 + (double)k * 32.0 / (double)ATTN_GT_SIG_N;
        sig_rom[k] = llround((1.0 / (1.0 + exp(-z))) * (double)(1LL << 30));
    }
    sig_rom_ready = 1;
}

typedef struct {
    int64_t interp;   /* the Q30 interpolation, before the Q15 round       */
    int     k;        /* table index, -1 on either clamp                    */
    int     frac;     /* interpolation fraction, Qq                         */
    int32_t g15;      /* the Q15 result, clamped to [0, 32767]              */
    int     lo_clamp, hi_clamp;
} attn_sig_t;

/* Site 6d.  fixed_pkg.sigmoid_q's arithmetic with the output stage pinned to
 * Q15 half-toward-plus-infinity and the top clamped to 32767 rather than
 * 32768, which is the C spec's deliberate 3.1e-5 deviation so g fits u16. */
static void attn_sigmoid_q15(int32_t zg, attn_sig_t *o)
{
    const int64_t one_q = (int64_t)1 << ATTN_GT_Q;
    o->k = -1; o->frac = 0; o->interp = 0;
    o->lo_clamp = 0; o->hi_clamp = 0;

    if ((int64_t)zg <= -16 * one_q) { o->lo_clamp = 1; o->g15 = 0;     return; }
    if ((int64_t)zg >=  16 * one_q) { o->hi_clamp = 1; o->g15 = 32767; return; }

    int64_t offset = (int64_t)zg + 16 * one_q;         /* in (0, 2^17)      */
    int64_t idx_fp = offset * 16;                      /* Qq                */
    int k = (int)(idx_fp >> ATTN_GT_Q);
    /* Unreachable given the two clamps above -- offset < 2^17 makes k <= 511
     * -- and kept because fixed_pkg keeps it. */
    if (k > ATTN_GT_SIG_N - 1) k = ATTN_GT_SIG_N - 1;
    if (k < 0) k = 0;
    int64_t frac = idx_fp - ((int64_t)k << ATTN_GT_Q);

    int64_t lo = sig_rom[k], hi = sig_rom[k + 1];
    /* The >> Q is a FLOOR on a non-negative product (SIG_ROM is monotone
     * increasing and frac >= 0), which is what ORACLE 3c's asymmetric bound
     * accounts for. */
    int64_t interp = lo + (((hi - lo) * frac) >> ATTN_GT_Q);

    int64_t r = mv4i_round_shift(interp, 30 - ATTN_GT_GQ);
    if (r < 0) r = 0;
    if (r > 32767) r = 32767;

    o->k = k; o->frac = (int)frac; o->interp = interp; o->g15 = (int32_t)r;
}

typedef struct {
    int64_t t;
    int32_t zg;
    int32_t g15;
    int64_t y;
    int     t_sat, z_sat, y_sat;
    attn_sig_t sig;
} attn_gate_t;

static int64_t sat_w(int64_t v, int w, int *ev)
{
    int64_t hi = ((int64_t)1 << (w - 1)) - 1;
    int64_t lo = -((int64_t)1 << (w - 1));
    if (v > hi) { if (ev) *ev = 1; return hi; }
    if (v < lo) { if (ev) *ev = 1; return lo; }
    return v;
}

static void attn_gate(int64_t o_acc, int32_t r, int p,
                      int32_t g_mant, int qg_exp, attn_gate_t *out)
{
    out->t_sat = 0; out->z_sat = 0; out->y_sat = 0;

    /* ---- site 6b ------------------------------------------------------- */
    int64_t tv = mv4i_round_shift(o_acc * (int64_t)r, p + 1);
    out->t = sat_w(tv, ATTN_GT_T_W, &out->t_sat);

    /* ---- site 6c, the two-branch rule, restated because the operand
     * differs from the score's.  Identical in shape to attn_score_q12. ---- */
    int sh = qg_exp - ATTN_GT_Q;
    int64_t zv;
    if (sh >= 0) {
        zv = mv4i_round_shift((int64_t)g_mant, sh);
    } else {
        int l = -sh;
        /* EXACT, not an approximation: |g_mant| < 2^15, so a left shift of 32
         * already carries any non-zero word past 2^31 and saturates, and a
         * larger shift saturates to the same value with the same sign.  A zero
         * word gives zero at every shift.  ORACLE 2 uses the TRUE shift. */
        if (l > ATTN_GT_LSH_CLAMP) l = ATTN_GT_LSH_CLAMP;
        zv = (int64_t)g_mant << l;
    }
    out->zg = mv4i_sat32(zv, &out->z_sat);

    /* ---- site 6d ------------------------------------------------------- */
    attn_sigmoid_q15(out->zg, &out->sig);
    out->g15 = out->sig.g15;

    /* ---- site 6e ------------------------------------------------------- */
    int64_t yv = mv4i_round_shift(out->t * (int64_t)out->g15, ATTN_GT_GQ);
    out->y = sat_w(yv, ATTN_GT_Y_W, &out->y_sat);
}

#ifndef ATTN_GATE_INCLUDE

static uint64_t gs = 20260831ULL;
static uint32_t grnd(void){ gs ^= gs<<13; gs ^= gs>>7; gs ^= gs<<17; return (uint32_t)(gs>>32); }

#define MAXN 512

/* Derived in the header, ORACLE 3b.  max|sigmoid''| = 1/(6 sqrt 3). */
#define SIG_CHORD_BOUND (0.09622504486493763 / (8.0 * 256.0) * 32768.0)
#define SIG_BOUND       (SIG_CHORD_BOUND + 0.5 + 0.5 / 32768.0)

#define S_MIN_REACHABLE_G 3849u
#define S_MAX_DECLARED_G  ((1u << ATTN_RC_S_W) - 1u)

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_gate_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 32;
    int N     = (argc > 3) ? atoi(argv[3]) : 64;
    if (N > MAXN) N = MAXN;

    sig_rom_init();

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d %d\n", ncase, N, ATTN_GT_Q, ATTN_GT_GQ,
            ATTN_GT_T_W, ATTN_GT_Y_W);

    long n_o1 = 0, n_o2 = 0, n_o3 = 0, n_o4 = 0, n_o5 = 0;
    double w1 = 0.0, w3 = 0.0, w5 = 0.0;
    int w3_zg = 0;

    /* ---- ORACLE 3a: the table itself, half an ulp, before anything runs -- */
    {
        double worst = 0.0; int worst_k = -1;
        for (int k = 0; k <= ATTN_GT_SIG_N; k++) {
            double z = -16.0 + (double)k / 16.0;
            double e = fabs((double)sig_rom[k]
                            - (1.0 / (1.0 + exp(-z))) * (double)(1LL << 30));
            if (e > worst) { worst = e; worst_k = k; }
        }
        if (worst > 0.5) {
            fprintf(stderr, "  FAIL oracle 3a: SIG_ROM[%d] is %.4f ulp from "
                            "sigmoid, over the half-ulp the table claims\n",
                    worst_k, worst);
            n_o3++;
        }
        fprintf(stderr, "  oracle 3a  worst table entry error: %.4f Q30 ulp "
                        "(k = %d)\n", worst, worst_k);
    }

    /* ---- ORACLE 3b/3c/3d EXHAUSTIVELY over the interpolated domain -------
     * The per-element checks below run on the vector set, and the vector set
     * is shaped for the CORNERS, so it is not a sweep and cannot be relied on
     * to contain the tightest point of the chord.  It did not: mutation G7 --
     * the interpolation ROUNDING where it must floor, which is exactly the
     * defect the chord-direction oracle exists to catch -- SURVIVED the
     * per-element checks over 2,240 elements and is killed here.  The
     * interpolated domain is only zg in [-16*2^12, 16*2^12], i.e. 131,073
     * points, so it can be swept exhaustively and there is no reason to
     * sample it.
     *
     * This is the same lesson as attn_softmax's coverage assertion, one step
     * further on: a coverage COUNTER tells you a corner was reached, but for a
     * property that must hold at every point of a small domain the honest
     * check is the whole domain. */
    {
        long b3b = 0, b3c = 0, b3d = 0;
        double worst = 0.0; int worst_z = 0;
        for (int64_t zg = -16 * (1 << ATTN_GT_Q);
             zg <= 16 * (1 << ATTN_GT_Q); zg++) {
            attn_sig_t sg; attn_sigmoid_q15((int32_t)zg, &sg);
            double z  = ldexp((double)zg, -ATTN_GT_Q_ORACLE);
            double sv = 1.0 / (1.0 + exp(-z));
            double e  = fabs((double)sg.g15 - sv * 32768.0);
            if (e > worst) { worst = e; worst_z = (int)zg; }
            if (e > SIG_BOUND) {
                if (b3b < 4) fprintf(stderr,
                    "  FAIL oracle 3b (sweep): zg %lld -- g15 %d against "
                    "sigmoid*2^15 = %.4f, error %.4f over the derived bound "
                    "%.4f\n", (long long)zg, sg.g15, sv * 32768.0, e,
                    SIG_BOUND);
                b3b++;
            }
            if (sg.k >= 0) {
                double t30 = sv * (double)(1LL << 30);
                if (z < 0.0 && (double)sg.interp < t30 - 1.5) {
                    if (b3c < 4) fprintf(stderr,
                        "  FAIL oracle 3c (sweep): zg %lld < 0 -- the chord of "
                        "a CONVEX function must not fall below it: interp "
                        "%lld against %.1f\n", (long long)zg,
                        (long long)sg.interp, t30);
                    b3c++;
                }
                if (z > 0.0 && (double)sg.interp > t30 + 0.5) {
                    if (b3c < 4) fprintf(stderr,
                        "  FAIL oracle 3c (sweep): zg %lld > 0 -- the chord of "
                        "a CONCAVE function must not rise above it: interp "
                        "%lld against %.1f\n", (long long)zg,
                        (long long)sg.interp, t30);
                    b3c++;
                }
                if (sg.frac == 0 && sg.interp != sig_rom[sg.k]) {
                    if (b3d < 4) fprintf(stderr,
                        "  FAIL oracle 3d (sweep): zg %lld is on the grid "
                        "(k %d) but interp %lld is not SIG_ROM[%d] = %lld\n",
                        (long long)zg, sg.k, (long long)sg.interp, sg.k,
                        (long long)sig_rom[sg.k]);
                    b3d++;
                }
            }
        }
        fprintf(stderr, "  oracle 3b  worst over the EXHAUSTIVE domain sweep: "
                        "%.4f counts at zg %d, against the derived %.4f\n",
                worst, worst_z, SIG_BOUND);
        if (b3b) { fprintf(stderr, "  FAIL oracle 3b (sweep): %ld\n", b3b);
                   n_o3++; }
        if (b3c) { fprintf(stderr, "  FAIL oracle 3c (sweep): %ld\n", b3c);
                   n_o3++; }
        if (b3d) { fprintf(stderr, "  FAIL oracle 3d (sweep): %ld\n", b3d);
                   n_o3++; }
    }

    /* ---- ORACLE 3f: monotonicity, on its own ascending sweep -------------
     * Separate from the vector set on purpose: the vectors are shaped for the
     * corners and are not ordered, and monotonicity is a statement about the
     * ORDER, so it needs a sweep that has one. */
    {
        long bad = 0; int32_t prev = -1;
        for (int64_t zg = -70000; zg <= 70000; zg++) {
            attn_sig_t sg; attn_sigmoid_q15((int32_t)zg, &sg);
            if (sg.g15 < prev) {
                if (bad < 4) fprintf(stderr,
                    "  FAIL oracle 3f: g15 fell from %d to %d at zg %lld\n",
                    prev, sg.g15, (long long)zg);
                bad++;
            }
            prev = sg.g15;
        }
        /* And on the far rails, where the clamps take over. */
        {
            attn_sig_t a, b;
            attn_sigmoid_q15(INT32_MIN, &a);
            attn_sigmoid_q15(INT32_MAX, &b);
            if (a.g15 != 0 || b.g15 != 32767) {
                fprintf(stderr, "  FAIL oracle 3e: the s32 rails give %d and "
                                "%d, want 0 and 32767\n", a.g15, b.g15);
                n_o3++;
            }
        }
        if (bad) { fprintf(stderr, "  FAIL oracle 3f: %ld monotonicity "
                                   "violations\n", bad); n_o3++; }
    }

    long n_left = 0, n_right = 0, n_sh0 = 0, n_zsat = 0;
    long n_zzero = 0, n_grid = 0, n_lo = 0, n_hi = 0, n_hi_interp = 0;
    long n_w1 = 0, n_w2 = 0;
    long n_oneg = 0, n_opos = 0, n_ozero = 0, n_tzero = 0;
    long n_yneg = 0, n_ypos = 0, n_g16min = 0, n_g16max = 0;
    long n_k0 = 0, n_kmax = 0;

    for (int c = 0; c < ncase; c++) {
        /* ---- the head's reciprocal, from attn_recip's own core ---------- */
        uint32_t s;
        {
            int shape = c % 6;
            int p = 11 + (int)(grnd() % (uint32_t)(ATTN_RC_S_W - 12));
            switch (shape) {
            case 0: s = 1u << p; break;                     /* r = 2^15      */
            case 1: s = (1u << (p + 1)) - 1u; break;         /* r = 2^14      */
            case 2: s = S_MIN_REACHABLE_G; break;            /* p = 11        */
            case 3: s = S_MAX_DECLARED_G; break;             /* p = S_W-1     */
            default: s = (1u << p) | (grnd() & ((1u << p) - 1u)); break;
            }
            if (s < S_MIN_REACHABLE_G) s = S_MIN_REACHABLE_G;
            if (s > S_MAX_DECLARED_G)  s = S_MAX_DECLARED_G;
        }
        attn_recip_t rc; attn_recip(s, &rc);

        /* ---- the gate exponent.  Shapes chosen for what is easy to get
         * wrong, and every one of the six is a different branch. ---------- */
        int qg_exp;
        switch (c % 7) {
        case 0: qg_exp = ATTN_GT_Q; break;        /* sh = 0, no shift at all */
        case 1: qg_exp = 4;  break;               /* sh = -8: EVERY zg lands
                                                   * exactly on a table entry */
        case 2: qg_exp = 0;  break;               /* sh = -12: the clamps     */
        case 3: qg_exp = 40; break;               /* sh = 28: zg collapses to
                                                   * 0, so g15 = 16384        */
        case 4: qg_exp = -20; break;              /* sh = -32: sat32 fires    */
        case 5: qg_exp = ATTN_GT_Q - 1; break;    /* sh = -1: the ONLY shape
                                                   * that reaches the END
                                                   * intervals k = 0 and
                                                   * k = SIG_N-1 without
                                                   * falling into a clamp.
                                                   * At sh = 0 the whole s16
                                                   * range is inside +-2^15
                                                   * and never approaches
                                                   * +-16*2^12 at all; at
                                                   * sh <= -8 the step is a
                                                   * whole table interval or
                                                   * more, so the only value
                                                   * landing in the end
                                                   * interval is the clamp
                                                   * itself.  The coverage
                                                   * assertion below is what
                                                   * said so.                */
        default: qg_exp = 6 + (int)(grnd() % 16u); break;
        }
        if (qg_exp >= ATTN_GT_Q) n_right++; else n_left++;
        if (qg_exp == ATTN_GT_Q) n_sh0++;

        int64_t ov[MAXN]; int32_t gv[MAXN];
        /* |o| <= 127*s is the contract (o is a convex combination of
         * v_aligned values with |v_aligned| <= 127) and |o| <= 2^30 is the C
         * spec's accumulator bound.  Both are respected so the s24 saturate
         * stays unreachable; the testbench violates it deliberately instead. */
        int64_t obound = 127LL * (int64_t)s;
        if (obound > (int64_t)1 << 30) obound = (int64_t)1 << 30;

        for (int d = 0; d < N; d++) {
            int oshape = d % 5;
            int64_t o;
            switch (oshape) {
            case 0: o = 0; break;
            case 1: o =  obound; break;
            case 2: o = -obound; break;
            case 3: o = (int64_t)(grnd() % 3u) - 1; break;   /* t = 0 region */
            default: {
                uint64_t m = ((uint64_t)grnd() << 32) | grnd();
                o = (int64_t)(m % (uint64_t)(obound + 1));
                if (grnd() & 1u) o = -o;
                break; }
            }
            ov[d] = o;

            int gshape = d % 11;
            int32_t g;
            switch (gshape) {
            case 0: g = 0; break;
            case 1: g = -32768; break;      /* the asymmetric end of int16 */
            case 2: g =  32767; break;
            /* One count in from each end.  With qg_exp = 11 these are the
             * values that land in the FIRST and LAST table intervals while
             * -32768 and +32767 doubled land on or past the clamp, so they
             * are the only way k = 0 and k = SIG_N-1 are reached at all. */
            case 3: g = -32767; break;
            case 4: g =  32766; break;
            case 5: g = (int32_t)(grnd() % 33u) - 16; break;   /* near zero */
            case 6: g = (int32_t)(grnd() % 512u) - 256; break;
            /* THE TWO WITNESSES FOR THE INTERPOLATION'S ROUNDING MODE, and
             * they are planted rather than sampled because the witness set is
             * TWO POINTS WIDE.  Over the whole interpolated domain of 131,071
             * gate arguments there are exactly two -- zg = -6334 and
             * zg = 17992 -- at which rounding the Q30 interpolation instead of
             * flooring it changes the Q15 output at all (5755 vs 5756, and
             * 32367 vs 32368).  Everywhere else the +1 in Q30 is absorbed by
             * the >> 15.  At qg_exp = 12 the Q12 conversion is the identity,
             * so these g_mant values ARE those zg.
             *
             * MEASURED, not assumed: RTL mutation M7 -- the interpolation
             * rounding where it must floor, which is precisely the defect the
             * chord-direction oracle exists to pin -- SURVIVED all three
             * handshake configurations over 2,240 elements before these two
             * shapes existed, and the C reference's own per-element check
             * missed it too until the domain sweep was added.  A random
             * generator needs ~65,000 elements per witness to find one by
             * luck.  Same lesson as attn_softmax's z = 0: the coverage
             * assertion, not the sample size. */
            case 7: g = -6334; break;
            case 8: g =  17992; break;
            default: g = (int32_t)(grnd() & 0xFFFFu) - 32768; break;
            }
            gv[d] = g;
        }

        /* ---- run and check ---------------------------------------------- */
        int64_t tv[MAXN], yv[MAXN]; int32_t zv[MAXN], gq[MAXN];
        long case_zsat = 0;

        for (int d = 0; d < N; d++) {
            attn_gate_t g;
            attn_gate(ov[d], rc.r, rc.p, gv[d], qg_exp, &g);
            tv[d] = g.t; zv[d] = g.zg; gq[d] = g.g15; yv[d] = g.y;
            if (g.z_sat) case_zsat++;

            if (g.t_sat || g.y_sat) {
                fprintf(stderr, "  FAIL: case %d elem %d saturated site 6%c, "
                        "which the |o| <= 127*s contract makes unreachable\n",
                        c, d, g.t_sat ? 'b' : 'e');
                n_o1++;
            }

            /* ---- ORACLE 1: site 6b against double ----------------------- */
            {
                double truth = ldexp((double)ov[d], ATTN_RC_R_Q_ORACLE - 1)
                               / (double)s;
                double bnd = ldexp(fabs((double)ov[d]), -(rc.p + 1)) + 0.5;
                double e = fabs((double)g.t - truth);
                double ratio = e / bnd;
                if (ratio > w1) w1 = ratio;
                if (ratio > 1.0) {
                    if (n_o1 < 8) fprintf(stderr,
                        "  FAIL oracle 1: case %d elem %d o %lld -- t %lld "
                        "against o*2^14/s = %.4f, error %.4f over the derived "
                        "bound %.4f\n", c, d, (long long)ov[d],
                        (long long)g.t, truth, e, bnd);
                    n_o1++;
                }
            }

            /* ---- ORACLE 2: site 6c recomputed exactly in double --------- */
            {
                double scaled = ldexp((double)gv[d],
                                      ATTN_GT_Q_ORACLE - qg_exp);
                double want = (qg_exp >= ATTN_GT_Q_ORACLE)
                                ? floor(scaled + 0.5) : scaled;
                if (want >  2147483647.0) want =  2147483647.0;
                if (want < -2147483648.0) want = -2147483648.0;
                if ((double)g.zg != want) {
                    if (n_o2 < 8) fprintf(stderr,
                        "  FAIL oracle 2: case %d elem %d g_mant %d qg_exp %d "
                        "-- zg %d, double says %.1f\n",
                        c, d, gv[d], qg_exp, g.zg, want);
                    n_o2++;
                }
            }

            /* ---- ORACLE 3b/3c/3d/3e: the sigmoid ----------------------- */
            {
                double z = ldexp((double)g.zg, -ATTN_GT_Q_ORACLE);
                double sg = 1.0 / (1.0 + exp(-z));
                double e = fabs((double)g.g15 - sg * 32768.0);
                /* 3b applies over the WHOLE domain, clamps included, and
                 * that is a derived fact rather than a convenience: at the low
                 * clamp the true value is sigmoid(-16)*2^15 = 0.0037 against
                 * an output of 0, and at the high clamp it is
                 * 32768*(1 - 1.1e-7) = 32767.996 against an output of 32767,
                 * so the C spec's pinned 3.1e-5 deviation costs 0.996 counts
                 * -- inside the 2.0397 the interpolation already needs.
                 * Excluding the clamps would have been the easy thing to write
                 * and would have left the clamp VALUES unchecked by any
                 * magnitude oracle. */
                {
                    if (e > w3) { w3 = e; w3_zg = g.zg; }
                    if (e > SIG_BOUND) {
                        if (n_o3 < 8) fprintf(stderr,
                            "  FAIL oracle 3b: case %d elem %d zg %d -- g15 %d "
                            "against sigmoid*2^15 = %.4f, error %.4f over the "
                            "derived bound %.4f\n", c, d, g.zg, g.g15,
                            sg * 32768.0, e, SIG_BOUND);
                        n_o3++;
                    }
                }
                /* 3c and 3d apply only where the interpolation actually ran;
                 * sig.k is -1 on either clamp. */
                if (g.sig.k >= 0) {
                    double t30 = sg * (double)(1LL << 30);
                    if (z < 0.0 && (double)g.sig.interp < t30 - 1.5) {
                        if (n_o3 < 8) fprintf(stderr,
                            "  FAIL oracle 3c: case %d elem %d zg %d < 0 -- "
                            "the chord of a CONVEX function must not fall "
                            "below it: interp %lld against %.1f\n",
                            c, d, g.zg, (long long)g.sig.interp, t30);
                        n_o3++;
                    }
                    if (z > 0.0 && (double)g.sig.interp > t30 + 0.5) {
                        if (n_o3 < 8) fprintf(stderr,
                            "  FAIL oracle 3c: case %d elem %d zg %d > 0 -- "
                            "the chord of a CONCAVE function must not rise "
                            "above it: interp %lld against %.1f\n",
                            c, d, g.zg, (long long)g.sig.interp, t30);
                        n_o3++;
                    }
                    /* 3d, grid equality. */
                    if (g.sig.frac == 0) {
                        n_grid++;
                        if (g.sig.interp != sig_rom[g.sig.k]) {
                            if (n_o3 < 8) fprintf(stderr,
                                "  FAIL oracle 3d: case %d elem %d zg %d is on "
                                "the grid (k %d) but interp %lld is not "
                                "SIG_ROM[%d] = %lld\n", c, d, g.zg, g.sig.k,
                                (long long)g.sig.interp, g.sig.k,
                                (long long)sig_rom[g.sig.k]);
                            n_o3++;
                        }
                    }
                    if (g.zg == 0) {
                        n_zzero++;
                        if (g.g15 != 16384) {
                            fprintf(stderr, "  FAIL oracle 3d: sigmoid(0) is "
                                    "%d, want 16384 exactly\n", g.g15);
                            n_o3++;
                        }
                    }
                    if (g.sig.k == 0) n_k0++;
                    if (g.sig.k == ATTN_GT_SIG_N - 1) n_kmax++;
                    /* The interpolated branch reaching the u16 top.  This
                     * counter read ZERO until the `clamped` exclusion above
                     * was removed, because it was nested inside a guard that
                     * excluded g15 == 32767 by construction -- a coverage
                     * counter that could not count.  It is the same class of
                     * mistake as a guard no vector reaches. */
                    if (g.g15 == 32767) n_hi_interp++;
                }
                if (g.sig.lo_clamp && g.g15 != 0) {
                    fprintf(stderr, "  FAIL oracle 3e: the low clamp gave %d, "
                            "want 0\n", g.g15); n_o3++;
                }
                if (g.sig.hi_clamp && g.g15 != 32767) {
                    fprintf(stderr, "  FAIL oracle 3e: the high clamp gave %d, "
                            "want 32767\n", g.g15); n_o3++;
                }
                if (g.g15 < 0 || g.g15 > 32767) {
                    fprintf(stderr, "  FAIL oracle 3e: g15 %d is outside "
                            "[0, 32767]\n", g.g15); n_o3++;
                }
            }

            /* ---- ORACLE 4: site 6e locally, the round and nothing else -- */
            {
                double want = (double)g.t * (double)g.g15 / 32768.0;
                if (fabs((double)g.y - want) > 0.5) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: case %d elem %d -- y %lld against "
                        "t*g15/2^15 = %.4f, over the half-count a round can "
                        "move it\n", c, d, (long long)g.y, want);
                    n_o4++;
                }
            }

            /* ---- ORACLE 5: the whole chain, bound COMPOSED -------------- */
            {
                double z  = ldexp((double)g.zg, -ATTN_GT_Q_ORACLE);
                double sg = 1.0 / (1.0 + exp(-z));
                double tr = ldexp((double)ov[d], ATTN_RC_R_Q_ORACLE - 1)
                            / (double)s;
                double want = tr * sg;
                double bt = ldexp(fabs((double)ov[d]), -(rc.p + 1)) + 0.5;
                double bnd = sg * bt
                           + fabs((double)g.t) * SIG_BOUND / 32768.0 + 0.5;
                /* Applies over the whole domain for the same reason 3b
                 * does: the clamp deviation is inside SIG_BOUND, which is
                 * exactly the term the composed bound carries for it. */
                {
                    double e = fabs((double)g.y - want);
                    double ratio = e / bnd;
                    if (ratio > w5) w5 = ratio;
                    if (ratio > 1.0) {
                        if (n_o5 < 8) fprintf(stderr,
                            "  FAIL oracle 5: case %d elem %d -- y %lld "
                            "against (o*2^14/s)*sigmoid = %.4f, error %.4f "
                            "over the composed bound %.4f\n", c, d,
                            (long long)g.y, want, e, bnd);
                        n_o5++;
                    }
                }
            }

            if (ov[d] < 0) n_oneg++; else if (ov[d] > 0) n_opos++;
            else n_ozero++;
            if (g.t == 0) n_tzero++;
            if (g.y < 0) n_yneg++; else if (g.y > 0) n_ypos++;
            if (g.zg == -6334) n_w1++;
            if (g.zg == 17992) n_w2++;
            if (gv[d] == -32768) n_g16min++;
            if (gv[d] ==  32767) n_g16max++;
            if (g.sig.lo_clamp) n_lo++;
            if (g.sig.hi_clamp) n_hi++;
        }
        n_zsat += case_zsat;

        fprintf(f, "%d %u %d %d %d %ld\n", c, s, rc.p, rc.r, qg_exp,
                case_zsat);
        for (int d = 0; d < N; d++) fprintf(f, "%lld ", (long long)ov[d]);
        fprintf(f, "\n");
        for (int d = 0; d < N; d++) fprintf(f, "%d ", gv[d]);
        fprintf(f, "\n");
        for (int d = 0; d < N; d++) fprintf(f, "%lld ", (long long)tv[d]);
        fprintf(f, "\n");
        for (int d = 0; d < N; d++) fprintf(f, "%d ", gq[d]);
        fprintf(f, "\n");
        for (int d = 0; d < N; d++) fprintf(f, "%lld ", (long long)yv[d]);
        fprintf(f, "\n");
        (void)zv;
    }
    fclose(f);

    fprintf(stderr, "attn_gate_vec: %d heads x %d elements -> %s\n",
            ncase, N, out);
    fprintf(stderr, "  oracle 1  worst |t - o*2^14/s| / derived bound: %.4f\n",
            w1);
    fprintf(stderr, "  oracle 3b worst |g15 - sigmoid*2^15|: %.4f counts "
                    "against the derived %.4f (at zg %d)\n", w3, SIG_BOUND,
            w3_zg);
    fprintf(stderr, "  oracle 5  worst chain error / composed bound: %.4f\n",
            w5);
    fprintf(stderr, "  branches: right %ld left %ld sh=0 %ld sat32 %ld\n",
            n_right, n_left, n_sh0, n_zsat);
    fprintf(stderr, "  sigmoid: zg=0 %ld on-grid %ld low clamp %ld high clamp "
                    "%ld 32767 from the interpolation %ld k=0 %ld k=%d %ld\n",
            n_zzero, n_grid, n_lo, n_hi, n_hi_interp, n_k0,
            ATTN_GT_SIG_N - 1, n_kmax);
    fprintf(stderr, "  interpolation rounding witnesses: zg=-6334 %ld, "
                    "zg=17992 %ld -- the ONLY two points in the whole domain "
                    "where a round instead of a floor changes g15\n",
            n_w1, n_w2);
    fprintf(stderr, "  o: neg %ld pos %ld zero %ld; t zero %ld; y neg %ld pos "
                    "%ld; g_mant -32768 %ld 32767 %ld\n",
            n_oneg, n_opos, n_ozero, n_tzero, n_yneg, n_ypos, n_g16min,
            n_g16max);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld\n", n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld\n", n_o4); fail = 1; }
    if (n_o5) { fprintf(stderr, "  FAIL oracle 5: %ld\n", n_o5); fail = 1; }

    /* Absent coverage is a FAILURE of the generator, not a note.  This is the
     * assertion that found the z = 0 resize defect in attn_softmax: a vector
     * set that never reaches a corner lets a unit that gets that corner wrong
     * pass everything.  Every counter below names a corner that is reachable
     * and that a plausible defect lives at. */
    if (n_left == 0 || n_right == 0 || n_sh0 == 0 || n_zsat == 0
        || n_zzero == 0 || n_grid == 0 || n_lo == 0 || n_hi == 0
        || n_hi_interp == 0 || n_k0 == 0 || n_kmax == 0
        || n_oneg == 0 || n_opos == 0 || n_ozero == 0 || n_tzero == 0
        || n_yneg == 0 || n_ypos == 0 || n_g16min == 0 || n_g16max == 0
        || n_w1 == 0 || n_w2 == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- left %ld right %ld sh0 %ld "
                "sat32 %ld zg0 %ld grid %ld loclamp %ld hiclamp %ld "
                "hi-from-interp %ld k0 %ld kmax %ld o- %ld o+ %ld o0 %ld t0 "
                "%ld y- %ld y+ %ld g=-32768 %ld g=32767 %ld round-witness "
                "%ld %ld; every one must be non-zero\n",
                n_left, n_right, n_sh0, n_zsat, n_zzero, n_grid, n_lo, n_hi,
                n_hi_interp, n_k0, n_kmax, n_oneg, n_opos, n_ozero, n_tzero,
                n_yneg, n_ypos, n_g16min, n_g16max, n_w1, n_w2);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: t inside the reciprocal's derived bound, the Q12 "
                    "gate conversion exact in double on both branches, the "
                    "sigmoid inside its convexity bound and on the correct "
                    "side of the chord with the grid points exact and the "
                    "clamps exact, and the whole chain inside the composed "
                    "bound\n");
    return 0;
}

#endif /* ATTN_GATE_INCLUDE */
