/* ref/attn_twiddle_vec.c -- vectors and golden for rtl/attn_twiddle.vhd.
 *
 * Subsystem C, sites R1/R2: stateless generation of the IMROPE twiddle pair
 * for one position, one (cos, sin) per rotated dim pair.
 *
 *     W[j]    : u32 = round( 2^32 * base^(-j/NPAIR) / (2*pi) )   turns/position
 *     phi[j]  : u32 = low32( pos * W[j] )                        site R1, exact mod 2^32
 *     idx     = phi >> FRACW           frac = phi & (2^FRACW - 1)
 *     sin[j]  : s16 = SIN[idx] + floor_shr( (SIN[idx+1] - SIN[idx]) * frac, FRACW )
 *     cos[j]  : s16 = the same lookup evaluated at phi + 2^30    an exact quarter turn
 *
 * WHY STATELESS AND NOT A PER-POSITION ROM.  rtl/rope_rom_pkg.vhd is the
 * per-position form and it is what v1.0 uses at 512 positions.  At the 27B
 * geometry the same shape is MAXCTX x 32 pairs x 2 tables x 16 b = 58 RAMB36
 * at 2K context and about 930 at the 32K cap, which the C spec rejects
 * outright.  This is 32 u32 constants plus one 1,024-entry table and does not
 * scale with the context length at all.
 *
 * THE TABLES ARE RECOMPUTED HERE, NOT READ FROM THE RTL'S PACKAGE.
 * tools/gen_imrope_pkg.py emits rtl/imrope_pkg.vhd; this file rebuilds both
 * tables from libm and never looks at that output.  It is a deliberate
 * deviation from subsystem A's 6.4 "one tool emits both" discipline: for a
 * table defined by a closed-form formula, two independent computations that
 * must agree BIT FOR BIT is a stronger check than one computation used twice,
 * and the bit-exact testbench is then the drift detector.  ORACLE 1 checks the
 * rebuilt table against libm to half an ulp on top of that, so the table is
 * validated rather than trusted.
 *
 * -------------------------------------------------------------------------
 * THE INDEPENDENT-ORACLE QUESTION, ANSWERED BEFORE THE UNIT WAS BUILT.
 * attn_qk_norm was skipped because wrapping rmsnorm_rs leaves only a replay of
 * the same algorithm to check against.  That is NOT the situation here: sin
 * and cos are TRANSCENDENTALS, so every value this unit produces can be
 * checked against libm at the exact real angle inside a bound derived from
 * three named sources, and the exact invariants below are properties of the
 * sine function and of the table's symmetry rather than of this arithmetic.
 * Nothing in the checks shares a shift, a rounding rule or a table lookup with
 * the path.
 *
 * DOUBLE ORACLE, seven checks:
 *
 *   ORACLE 1, the TABLE, to half an ulp.  |SIN[i] - 32767*sin(2*pi*i/1024)|
 *     <= 0.5 for all 1,024 entries.  Exact, not a tolerance.
 *
 *   ORACLE 2, the TABLE'S EXACT SYMMETRIES.  SIN[i + 512] == -SIN[i] and
 *     SIN[512 - i] == SIN[i] as integer equalities, plus SIN[0] = 0,
 *     SIN[256] = 32767, SIN[512] = 0, SIN[768] = -32767, and SIN
 *     non-decreasing on [0, 256].  A table built on the wrong grid step, or
 *     over the wrong span, breaks these immediately while staying inside any
 *     magnitude bound that admits interpolation error.
 *
 *   ORACLE 3, the PHASE against the real angle, with a DERIVED bound.
 *     phi/2^32 must equal frac_part( pos * base^(-j/NPAIR) / (2*pi) ) to
 *     within pos * 2^-33 turns, computed with fmod in double.  The bound is
 *     derived, not chosen: |W[j] - true| <= 0.5 by the rounding, so
 *     |pos*W[j] - pos*true| <= pos/2, which is pos*2^-33 turns.  The path
 *     wraps by taking the low 32 bits of an integer product; the check wraps
 *     with fmod on a real.  They share nothing.
 *
 *   ORACLE 4, sin AND cos against libm at the true angle, DERIVED bound.
 *     Three named sources, summed:
 *       (a) the W rounding, 2*pi*pos*2^-33 rad, times 32767
 *       (b) the interpolation chord.  sin is twice differentiable with
 *           max|sin''| = 1, so a linear interpolation over a step of
 *           2*pi/1024 errs by at most (2*pi/1024)^2/8 = 4.71e-6 rad, times
 *           32767 = 0.1543 counts
 *       (c) the two table entries' own half ulp, which the interpolation
 *           carries through unchanged, plus the interpolation's own FLOOR,
 *           which costs up to 1 count
 *     At pos = 2047 that is 0.049 + 0.154 + 1.5 = 1.70 counts, and the C spec
 *     predicts "about 2 Q15 ulp".  Evaluated per position rather than fixed.
 *
 *   ORACLE 5, the CHORD DIRECTION, which no magnitude bound can see.  sin is
 *     CONCAVE on [0, pi] and CONVEX on [pi, 2*pi], and the table's grid points
 *     land exactly on 0, pi/2, pi and 3*pi/2, so no interpolation interval
 *     straddles an inflection.  A chord therefore lies BELOW the curve on
 *     [0, pi] and ABOVE it on [pi, 2*pi], and the interpolation must sit on
 *     the corresponding side.  This is what separates a correct interpolation
 *     from one that rounds where it should floor, or from a nearest-entry
 *     lookup: both stay inside ORACLE 4 and neither survives this.
 *
 *   ORACLE 6, PYTHAGORAS, a property of the PAIR that neither component's own
 *     check sees.  |sin^2 + cos^2 - 32767^2| must sit inside
 *     2*32767*E + 2*E^2 with E the ORACLE 4 bound.  It is the only check that
 *     is a statement about cos and sin TOGETHER.
 *
 *   ORACLE 7, pos = 0 EXACTLY, and the grid points exactly.  At pos = 0 every
 *     phi is 0, so sin must be 0 and cos must be 32767 with no interpolation
 *     at all; and wherever frac = 0 the interpolation must return the table
 *     entry itself.  Equalities, not bounds.
 *
 * AND THE IMROPE DISPATCH EQUIVALENCE (C spec 3.11's deliverable).  The
 * hardware builds the COLLAPSED form -- one angle stream, no sector mux --
 * because in text mode all three live sectors carry the same position.  This
 * file implements the FULL sector dispatch and asserts the equivalence BY
 * ENUMERATION over every (pos, j), so if a multimodal input path or the MTP
 * block ever enters scope the divergence is caught in the reference rather
 * than on silicon.  See the note at imrope_dispatch_phi() for exactly how much
 * that enumeration does and does not establish.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_twiddle_vec attn_twiddle_vec.c -lm
 * Usage: ./attn_twiddle_vec [out.txt] [ncase] [npair]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_TW_NPAIR   32          /* N_ROT / 2                             */
#define ATTN_TW_TBL     1024        /* sine table entries, one full turn      */
#define ATTN_TW_FRACW   22          /* 32 - log2(TBL)                         */
#define ATTN_TW_QMAX    32767       /* Q15                                    */
#define ATTN_TW_BASE    1.0e7       /* GGUF qwen35.rope.freq_base             */
#define ATTN_TW_QUARTER 0x40000000u /* a quarter turn in u32 phase            */

/* Restated independently for the oracles.  attn_score_q12_vec.c records that
 * sharing a constant between the thing under test and the thing testing it let
 * a mutation of it pass both oracles, because the golden moved with the path.
 * These MUST NOT be defined in terms of the constants above. */
#define ATTN_TW_TBL_ORACLE  1024
#define ATTN_TW_QMAX_ORACLE 32767
#define ATTN_TW_BASE_ORACLE 1.0e7

static uint32_t tw_W[ATTN_TW_NPAIR];
static int32_t  tw_SIN[ATTN_TW_TBL + 1];   /* entry TBL duplicates entry 0 */

static void attn_tw_init(void)
{
    for (int j = 0; j < ATTN_TW_NPAIR; j++)
        tw_W[j] = (uint32_t)llround(pow(2.0, 32) *
                    pow(ATTN_TW_BASE, -(double)j / (double)ATTN_TW_NPAIR)
                    / (2.0 * M_PI));
    for (int i = 0; i <= ATTN_TW_TBL; i++)
        tw_SIN[i] = (int32_t)llround((double)ATTN_TW_QMAX *
                      sin(2.0 * M_PI * (double)(i % ATTN_TW_TBL)
                          / (double)ATTN_TW_TBL));
}

/* Site R2.  One lookup with linear interpolation, FLOOR on the shift -- the
 * same mode the exp and sigmoid cones use, and the mode ORACLE 5 pins. */
static int32_t tw_lookup(uint32_t phi, int *idx_out, uint32_t *frac_out)
{
    uint32_t idx  = phi >> ATTN_TW_FRACW;
    uint32_t frac = phi & (((uint32_t)1 << ATTN_TW_FRACW) - 1u);
    int32_t  lo   = tw_SIN[idx];
    int32_t  hi   = tw_SIN[(idx + 1u) % ATTN_TW_TBL];
    if (idx_out)  *idx_out  = (int)idx;
    if (frac_out) *frac_out = frac;
    return lo + (int32_t)mv4i_floor_shr((int64_t)(hi - lo) * (int64_t)frac,
                                        ATTN_TW_FRACW);
}

typedef struct {
    uint32_t phi;
    int32_t  c, s;
    int      idx;
    uint32_t frac;
} attn_tw_t;

static void attn_twiddle(uint32_t pos, int j, attn_tw_t *o)
{
    o->phi = (uint32_t)((uint64_t)pos * (uint64_t)tw_W[j]);   /* site R1 */
    o->s = tw_lookup(o->phi, &o->idx, &o->frac);
    o->c = tw_lookup(o->phi + ATTN_TW_QUARTER, NULL, NULL);
}

/* ---- the FULL IMROPE sector dispatch, for the 3.11 equivalence ----------
 * GGUF qwen35.rope.dimension_sections = [11, 11, 10, 0], which sums to 32 =
 * N_ROT/2, so the fourth (theta_e) sector is unreachable and the first three
 * partition the pairs.  In DECODE-ONLY TEXT mode p_t = p_h = p_w = pos.
 *
 * WHAT THE ENUMERATION BELOW ESTABLISHES, AND WHAT IT DOES NOT.  It shows that
 * the collapsed single-angle form equals the dispatched form for every (pos,
 * j) in the vector set.  That conclusion does NOT depend on the sector ORDER:
 * whether ggml assigns sectors in blocks or interleaved, all three live
 * sectors carry the SAME position in text mode, so any assignment gives the
 * same angle.  The block form below is therefore sufficient to establish the
 * equivalence and is NOT a claim about ggml's interleave.  What it would fail
 * to catch is a fourth sector becoming reachable, or the positions diverging
 * -- which is exactly the multimodal / MTP case the check exists for, and both
 * of those are caught by the assertions rather than by the ordering. */
static const int tw_sections[4] = { 11, 11, 10, 0 };

static uint32_t imrope_dispatch_phi(uint32_t p_t, uint32_t p_h, uint32_t p_w,
                                    uint32_t p_e, int j, int *sector_out)
{
    int c = 0, sec = 0;
    for (sec = 0; sec < 4; sec++) {
        if (j < c + tw_sections[sec]) break;
        c += tw_sections[sec];
    }
    if (sector_out) *sector_out = sec;
    uint32_t p = (sec == 0) ? p_t : (sec == 1) ? p_h
               : (sec == 2) ? p_w : p_e;
    return (uint32_t)((uint64_t)p * (uint64_t)tw_W[j]);
}

#ifndef ATTN_TWIDDLE_INCLUDE

static uint64_t ts = 20260902ULL;
static uint32_t trnd(void){ ts ^= ts<<13; ts ^= ts>>7; ts ^= ts<<17; return (uint32_t)(ts>>32); }

#define MAXCTX_DECL 2048

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_twiddle_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 24;
    int npair = (argc > 3) ? atoi(argv[3]) : ATTN_TW_NPAIR;
    if (npair > ATTN_TW_NPAIR) npair = ATTN_TW_NPAIR;

    attn_tw_init();

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d\n", ncase, npair, ATTN_TW_TBL, ATTN_TW_FRACW);

    long n_o1=0,n_o2=0,n_o3=0,n_o4=0,n_o5=0,n_o6=0,n_o7=0,n_disp=0;
    double w1=0.0, w4=0.0, w6=0.0; int w4_pos=-1, w4_j=-1;

    /* ---- ORACLE 1: the table against libm, half an ulp, before anything -- */
    {
        double worst = 0.0; int wk = -1;
        for (int i = 0; i < ATTN_TW_TBL_ORACLE; i++) {
            double t = (double)ATTN_TW_QMAX_ORACLE
                     * sin(2.0*M_PI*(double)i/(double)ATTN_TW_TBL_ORACLE);
            double e = fabs((double)tw_SIN[i] - t);
            if (e > worst) { worst = e; wk = i; }
        }
        w1 = worst;
        if (worst > 0.5) {
            fprintf(stderr, "  FAIL oracle 1: SIN[%d] is %.4f from "
                    "32767*sin, over the half ulp the table claims\n", wk,
                    worst);
            n_o1++;
        }
    }

    /* ---- ORACLE 2: the table's exact symmetries and monotonicity --------- */
    {
        const int T = ATTN_TW_TBL_ORACLE;
        if (tw_SIN[0] != 0 || tw_SIN[T/4] != ATTN_TW_QMAX_ORACLE
            || tw_SIN[T/2] != 0 || tw_SIN[3*T/4] != -ATTN_TW_QMAX_ORACLE) {
            fprintf(stderr, "  FAIL oracle 2: the quarter points are %d %d %d "
                    "%d, want 0 %d 0 -%d\n", tw_SIN[0], tw_SIN[T/4],
                    tw_SIN[T/2], tw_SIN[3*T/4], ATTN_TW_QMAX_ORACLE,
                    ATTN_TW_QMAX_ORACLE);
            n_o2++;
        }
        for (int i = 0; i < T/2; i++)
            if (tw_SIN[i + T/2] != -tw_SIN[i]) {
                if (n_o2 < 4) fprintf(stderr, "  FAIL oracle 2: SIN[%d] = %d "
                        "is not -SIN[%d] = %d (half-turn antisymmetry)\n",
                        i+T/2, tw_SIN[i+T/2], i, tw_SIN[i]);
                n_o2++;
            }
        for (int i = 0; i <= T/2; i++)
            if (tw_SIN[(T/2 - i + T) % T] != tw_SIN[i % T]) {
                if (n_o2 < 4) fprintf(stderr, "  FAIL oracle 2: SIN[%d] is not "
                        "SIN[%d] (reflection about pi/2)\n", T/2-i, i);
                n_o2++;
            }
        for (int i = 0; i < T/4; i++)
            if (tw_SIN[i+1] < tw_SIN[i]) {
                if (n_o2 < 4) fprintf(stderr, "  FAIL oracle 2: SIN fell from "
                        "%d to %d at i = %d, inside the rising quarter\n",
                        tw_SIN[i], tw_SIN[i+1], i);
                n_o2++;
            }
    }

    /* ---- ORACLE 5: the chord direction, EXHAUSTIVELY over the table ------
     * Swept over every interval and a fixed set of fractions rather than over
     * the vector set, for the reason attn_gate's write-up records: a property
     * that must hold at every point of a small domain is checked by sweeping
     * the domain, not by sampling it.  attn_gate's mutation G7/M7 survived the
     * sampled form and the witness set turned out to be two points wide. */
    {
        long bad = 0;
        const int T = ATTN_TW_TBL_ORACLE;
        for (int idx = 0; idx < T; idx++) {
            for (int k = 1; k < 8; k++) {
                uint32_t frac = (uint32_t)((((uint64_t)1 << ATTN_TW_FRACW) * k) / 8);
                uint32_t phi = ((uint32_t)idx << ATTN_TW_FRACW) | frac;
                int32_t v = tw_lookup(phi, NULL, NULL);
                double th = 2.0*M_PI*((double)phi / 4294967296.0);
                double tv = (double)ATTN_TW_QMAX_ORACLE * sin(th);
                /* CONCAVE on [0, pi] -> the chord is BELOW the curve, and the
                 * floor can only lower it further, so v <= tv + 0.5 (the half
                 * ulp the two table entries carry).  CONVEX on [pi, 2pi] ->
                 * the chord is ABOVE, and the floor lowers it by at most one
                 * count, so v >= tv - 1.5. */
                if (idx < T/2 && (double)v > tv + 0.5 + 1e-9) {
                    if (bad < 4) fprintf(stderr, "  FAIL oracle 5: phi %u is on "
                        "the CONCAVE half -- the chord must not rise above the "
                        "curve: %d against %.4f\n", phi, v, tv);
                    bad++;
                }
                if (idx >= T/2 && (double)v < tv - 1.5 - 1e-9) {
                    if (bad < 4) fprintf(stderr, "  FAIL oracle 5: phi %u is on "
                        "the CONVEX half -- the chord must not fall below the "
                        "curve: %d against %.4f\n", phi, v, tv);
                    bad++;
                }
            }
        }
        if (bad) { fprintf(stderr, "  FAIL oracle 5: %ld chord-direction "
                                   "violations\n", bad); n_o5++; }
    }

    long n_pos0=0, n_frac0=0, n_sneg=0, n_spos=0, n_cneg=0, n_cpos=0;
    long n_idxlo=0, n_idxhi=0, n_j0=0, n_jmax=0, n_wrap=0;
    uint32_t pos_seen[64]; int npos_seen = 0;

    for (int c = 0; c < ncase; c++) {
        /* Positions, chosen for what is easy to get wrong:
         *  0  pos = 0            -- every phi is 0; the identity case
         *  1  pos = 1            -- the smallest non-zero phase, where W[31]
         *                           = 113 gives idx 0 and a tiny fraction
         *  2  pos = MAXCTX-1     -- the largest phase, where the W-rounding
         *                           term of the bound is at its worst
         *  3  pos = 2^22 / W[0]  -- j = 0 lands near a table entry
         *  else random over the declared context
         */
        uint32_t pos;
        switch (c % 5) {
        case 0: pos = 0; break;
        case 1: pos = 1; break;
        case 2: pos = MAXCTX_DECL - 1; break;
        case 3: pos = 7; break;
        default: pos = trnd() % (uint32_t)MAXCTX_DECL; break;
        }
        if (npos_seen < 64) pos_seen[npos_seen++] = pos;

        fprintf(f, "%d %u\n", c, pos);
        for (int j = 0; j < npair; j++) {
            attn_tw_t t;
            attn_twiddle(pos, j, &t);

            /* ---- the 3.11 dispatch equivalence, by enumeration ----------- */
            {
                int sec = -1;
                uint32_t dphi = imrope_dispatch_phi(pos, pos, pos, pos, j,
                                                    &sec);
                if (dphi != t.phi) {
                    if (n_disp < 8) fprintf(stderr,
                        "  FAIL dispatch: pos %u j %d sector %d -- the full "
                        "IMROPE dispatch gives phi %u, the collapsed form "
                        "gives %u\n", pos, j, sec, dphi, t.phi);
                    n_disp++;
                }
                if (sec == 3) {
                    fprintf(stderr, "  FAIL dispatch: pos %u j %d reached "
                            "sector 3 (theta_e), which sections [11,11,10,0] "
                            "make unreachable\n", pos, j);
                    n_disp++;
                }
            }

            /* ---- ORACLE 3: the phase against the real angle -------------- */
            {
                double turns = (double)pos
                    * pow(ATTN_TW_BASE_ORACLE, -(double)j/(double)npair)
                    / (2.0*M_PI);
                double fr = turns - floor(turns);
                double got = (double)t.phi / 4294967296.0;
                double d = fabs(got - fr);
                if (d > 0.5) d = 1.0 - d;          /* the wrap is a circle */
                double bnd = (double)pos * ldexp(1.0, -33) + 1e-12;
                if (d > bnd) {
                    if (n_o3 < 8) fprintf(stderr,
                        "  FAIL oracle 3: pos %u j %d -- phi/2^32 = %.12f "
                        "against the real fractional turn %.12f, error %.3e "
                        "over the derived bound %.3e\n",
                        pos, j, got, fr, d, bnd);
                    n_o3++;
                }
            }

            /* ---- ORACLE 4: sin and cos against libm, DERIVED bound ------- */
            {
                double th = 2.0*M_PI*((double)t.phi / 4294967296.0);
                /* theta_j = pos * base^(-j/NPAIR) RADIANS.  Written as
                 * 2*pi*pos*base^(...) in the first version, which is 2*pi
                 * times the angle -- so the check compared the unit against
                 * the sine of a completely different argument and reported
                 * ratios of 39,000 against a bound of 1.67.  A magnitude that
                 * absurd is an ORACLE bug, not a DUT bug: a real defect in a
                 * Q15 interpolator cannot miss by two full amplitudes.  The
                 * tell was that ORACLE 3, which checks the same angle in
                 * TURNS, passed clean at the same time. */
                double true_th = (double)pos
                    * pow(ATTN_TW_BASE_ORACLE, -(double)j/(double)npair);
                /* (a) W rounding, (b) the chord, (c) table + floor */
                double ea = (double)ATTN_TW_QMAX_ORACLE
                          * 2.0*M_PI*(double)pos*ldexp(1.0, -33);
                double eb = (double)ATTN_TW_QMAX_ORACLE
                          * (2.0*M_PI/(double)ATTN_TW_TBL_ORACLE)
                          * (2.0*M_PI/(double)ATTN_TW_TBL_ORACLE) / 8.0;
                double ec = 1.5;
                double bnd = ea + eb + ec;
                double es = fabs((double)t.s
                        - (double)ATTN_TW_QMAX_ORACLE*sin(true_th));
                double ec2 = fabs((double)t.c
                        - (double)ATTN_TW_QMAX_ORACLE*cos(true_th));
                double worst = es > ec2 ? es : ec2;
                if (worst/bnd > w4) { w4 = worst/bnd; w4_pos=(int)pos; w4_j=j; }
                if (worst > bnd) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: pos %u j %d -- (cos, sin) = (%d, %d) "
                        "against 32767*(cos, sin)(%.9f) = (%.3f, %.3f), worst "
                        "error %.4f over the derived bound %.4f = %.4f(W) + "
                        "%.4f(chord) + %.1f(table+floor)\n",
                        pos, j, t.c, t.s, true_th,
                        (double)ATTN_TW_QMAX_ORACLE*cos(true_th),
                        (double)ATTN_TW_QMAX_ORACLE*sin(true_th),
                        worst, bnd, ea, eb, ec);
                    n_o4++;
                }
                (void)th;

                /* ---- ORACLE 6: Pythagoras, a check of the PAIR ----------- */
                /* s = q sin + ds, c = q cos + dc with |ds|, |dc| <= bnd, so
                 * s^2 + c^2 = q^2 + 2q(sin*ds + cos*dc) + ds^2 + dc^2, and by
                 * Cauchy-Schwarz |sin*ds + cos*dc| <= sqrt(ds^2 + dc^2) <=
                 * bnd*sqrt(2).  The first version wrote 2*q*bnd, dropping the
                 * sqrt(2) and the fact that BOTH components carry an error;
                 * it failed on 5 of 768 pairs at a ratio of 1.034, which is
                 * the signature of a bound that is slightly wrong rather than
                 * a value that is. */
                double q = (double)ATTN_TW_QMAX_ORACLE;
                double got = (double)t.s*(double)t.s + (double)t.c*(double)t.c;
                double pb = 2.0*q*bnd*sqrt(2.0) + 2.0*bnd*bnd;
                double pd = fabs(got - q*q);
                if (pd/pb > w6) w6 = pd/pb;
                if (pd > pb) {
                    if (n_o6 < 8) fprintf(stderr,
                        "  FAIL oracle 6: pos %u j %d -- sin^2 + cos^2 = %.0f, "
                        "which is %.0f from 32767^2, over the derived %.0f\n",
                        pos, j, got, pd, pb);
                    n_o6++;
                }
            }

            /* ---- ORACLE 7: the exact cases ------------------------------ */
            if (pos == 0) {
                n_pos0++;
                if (t.phi != 0 || t.s != 0 || t.c != ATTN_TW_QMAX_ORACLE) {
                    fprintf(stderr, "  FAIL oracle 7: at pos 0, j %d gives "
                            "phi %u (cos, sin) = (%d, %d); want 0 and "
                            "(%d, 0) with no interpolation at all\n",
                            j, t.phi, t.c, t.s, ATTN_TW_QMAX_ORACLE);
                    n_o7++;
                }
            }
            if (t.frac == 0) {
                n_frac0++;
                if (t.s != tw_SIN[t.idx]) {
                    fprintf(stderr, "  FAIL oracle 7: pos %u j %d has frac = 0 "
                            "at idx %d but sin %d is not SIN[%d] = %d\n",
                            pos, j, t.idx, t.s, t.idx, tw_SIN[t.idx]);
                    n_o7++;
                }
            }

            if (t.s < 0) n_sneg++; else if (t.s > 0) n_spos++;
            if (t.c < 0) n_cneg++; else if (t.c > 0) n_cpos++;
            if (t.idx < ATTN_TW_TBL_ORACLE/8) n_idxlo++;
            if (t.idx > 7*ATTN_TW_TBL_ORACLE/8) n_idxhi++;
            if (j == 0) n_j0++;
            if (j == npair-1) n_jmax++;
            /* the phase wrapped at least one whole turn */
            if ((uint64_t)pos * (uint64_t)tw_W[j] >= ((uint64_t)1 << 32))
                n_wrap++;

            /* phi is emitted as two 16-bit halves, NOT as one %u.  A VHDL
             * `integer` is 32 bits SIGNED, so textio cannot read a u32 above
             * 2^31 - 1 at all -- and W[0] = 683565276 times a position of 4 or
             * more is already past it.  Splitting it here is the only place
             * the split belongs; the testbench recombines with a shift. */
            fprintf(f, "%u %u %d %d ", (t.phi >> 16) & 0xFFFFu,
                    t.phi & 0xFFFFu, t.c, t.s);
        }
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_twiddle_vec: %d positions x %d pairs -> %s\n",
            ncase, npair, out);
    fprintf(stderr, "  oracle 1  worst table entry error: %.4f ulp (half is "
                    "the claim)\n", w1);
    fprintf(stderr, "  oracle 4  worst |value - 32767*trig| / derived bound: "
                    "%.4f (pos %d j %d)\n", w4, w4_pos, w4_j);
    fprintf(stderr, "  oracle 6  worst |sin^2+cos^2 - 32767^2| / derived: "
                    "%.4f\n", w6);
    fprintf(stderr, "  sin neg %ld pos %ld; cos neg %ld pos %ld; idx in the "
                    "first eighth %ld, last eighth %ld\n",
            n_sneg, n_spos, n_cneg, n_cpos, n_idxlo, n_idxhi);
    fprintf(stderr, "  pos = 0 pairs %ld; frac = 0 (exact grid) %ld; phase "
                    "wrapped a whole turn %ld\n", n_pos0, n_frac0, n_wrap);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld\n", n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld\n", n_o4); fail = 1; }
    if (n_o5) { fprintf(stderr, "  FAIL oracle 5: %ld\n", n_o5); fail = 1; }
    if (n_o6) { fprintf(stderr, "  FAIL oracle 6: %ld\n", n_o6); fail = 1; }
    if (n_o7) { fprintf(stderr, "  FAIL oracle 7: %ld\n", n_o7); fail = 1; }
    if (n_disp) { fprintf(stderr, "  FAIL: %ld dispatch divergences -- the "
                    "collapsed form is NOT the full IMROPE dispatch\n",
                    n_disp); fail = 1; }

    /* A FIELD THAT IS CONSTANT ACROSS EVERY VECTOR MAKES EVERY CHECK ON IT
     * VACUOUS.  The D owner's ordering guard passed against a deliberately
     * broken DUT for exactly this reason: the three fields it checked were
     * identically zero in all 491 descriptors.  `pos` is the only scalar this
     * generator emits, so it is the one that has to be shown to vary. */
    {
        int distinct = 0;
        for (int i = 0; i < npos_seen; i++) {
            int seen = 0;
            for (int k = 0; k < i; k++) if (pos_seen[k] == pos_seen[i]) seen = 1;
            if (!seen) distinct++;
        }
        if (distinct < 2) {
            fprintf(stderr, "  FAIL: `pos` takes %d distinct value(s) across "
                    "the vector set.  A field that never varies makes every "
                    "check on it vacuous\n", distinct);
            fail = 1;
        } else {
            fprintf(stderr, "  `pos` takes %d distinct values across %d "
                    "cases\n", distinct, ncase);
        }
    }

    /* Absent coverage is a FAILURE of the generator, not a note. */
    if (n_pos0 == 0 || n_frac0 == 0 || n_sneg == 0 || n_spos == 0
        || n_cneg == 0 || n_cpos == 0 || n_idxlo == 0 || n_idxhi == 0
        || n_j0 == 0 || n_jmax == 0 || n_wrap == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- pos0 %ld frac0 %ld sin- %ld "
                "sin+ %ld cos- %ld cos+ %ld idx-low %ld idx-high %ld j=0 %ld "
                "j=max %ld wrapped %ld; every one must be non-zero\n",
                n_pos0, n_frac0, n_sneg, n_spos, n_cneg, n_cpos, n_idxlo,
                n_idxhi, n_j0, n_jmax, n_wrap);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: the table is within half an ulp of libm and exactly "
                    "symmetric, the phase is inside its derived turn bound, "
                    "sin and cos are inside the three-term derived bound and "
                    "on the correct side of the chord, the pair satisfies "
                    "Pythagoras, pos = 0 and the grid points are exact, and "
                    "the collapsed form equals the full IMROPE dispatch on "
                    "every enumerated (pos, j)\n");
    return 0;
}

#endif /* ATTN_TWIDDLE_INCLUDE */
