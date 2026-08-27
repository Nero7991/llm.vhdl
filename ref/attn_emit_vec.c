/* ref/attn_emit_vec.c -- vectors and golden for rtl/attn_emit.vhd.
 *
 * Subsystem C, site 6f: renormalize the whole layer's gated attention output
 * onto ONE block-floating grid and pack it to int16.
 *
 *     e_min      = min over g of e_grid[g]
 *     y_al[i]    = floor_shr( y_pre[i], e_grid[g(i)] - e_min )
 *     amax       = max over i of |y_al[i]|            msb_pos(0) = 0
 *     shp        = max(0, msb_pos(amax) - TARGET_MSB)
 *     y_mant[i]  = sat16( round_shift(y_al[i], shp) )
 *     y_exp      = e_min - shp
 *
 * WHY THE GRIDS DIFFER IN THE FIRST PLACE.  `v_ref` is per KV head, so the
 * card's query heads sit on TWO grids: e_grid[kvh] = v_ref[layer][kvh] + 14
 * (the 14 is site 6b's precision gain, R_Q - 1).  A single y_exp has to serve
 * all of them, so one grid is chosen and the other is shifted down to it.
 *
 * WHY THE MINIMUM AND NOT THE MAXIMUM.  Aligning to the minimum makes every
 * shift a RIGHT shift, so no element can overflow while being aligned and the
 * alignment can be done in place with no wider intermediate.  Aligning to the
 * maximum would need left shifts, and an element already near the s24 rail
 * would have to grow.  This is the same policy attn_score_q12 uses on its
 * block exponents and for the same reason; ORACLE 3 asserts it as an exact
 * inequality rather than leaving it as a comment.
 *
 * WHY THE ALIGNMENT FLOORS AND THE PACK ROUNDS.  Two roundings in series on
 * one value double-round, so exactly one of them is allowed to round.  The
 * pack is the one that rounds because it is the one whose error reaches the
 * output; the alignment floors.  ORACLE 4 is what pins that, because ORACLE 1's
 * bound is DERIVED to admit the alignment floor and therefore cannot tell a
 * floor from a round -- a round is strictly inside it.  attn_score_q12_vec.c
 * records finding exactly that by mutation.
 *
 * WHY IT PAIRS WITH attn_gate.  y_pre is that unit's output, one s24 element
 * per cycle, and this unit is its only consumer.  Together they are the whole
 * of C's step 8 after the reciprocal, and with attn_kv_quant, attn_score_q12,
 * attn_softmax and attn_recip they make steps 4 through 8 a contiguous
 * verified run.
 *
 * DOUBLE ORACLE, five checks, none sharing the integer path:
 *
 *   ORACLE 1, the whole pack against floating point, with a bound DERIVED per
 *     case rather than chosen.  The real value of element i is
 *     y_pre[i] * 2^-e_grid[g], and the emitted value is y_mant[i] * 2^-y_exp.
 *     In units of the OUTPUT LSB the alignment floor costs up to 2^-shp and
 *     the pack round costs up to 0.5, so
 *         | y_mant[i] - y_pre[i] * 2^(e_min - e_grid[g]) / 2^shp |
 *              <= 2^-shp + 0.5
 *     evaluated with ldexp and nothing else.  It grows as the output grid gets
 *     COARSER than the input, which is the regime shp > 0 lives in.  A fixed
 *     tolerance would be vacuous there and would fail on correct data at
 *     shp = 0.
 *
 *   ORACLE 2, the PEAK WINDOW, as an exact inequality.  This is what pins
 *     TARGET_MSB and it is the only check that sees an exponent that is right
 *     by one: when amax != 0, the largest aligned magnitude must land in
 *     [2^TARGET_MSB, 2^(TARGET_MSB+1)) after the shift if shp > 0, and below
 *     2^(TARGET_MSB+1) if shp = 0.  A shp one too small makes every mantissa
 *     twice too large and y_exp one too high, which denotes the SAME real
 *     value and is invisible to any check that reconstructs the value --
 *     attn_kv_quant's write-up records that failure verbatim.
 *
 *   ORACLE 3, the alignment DIRECTION and the minimum, exactly.  e_min must be
 *     the true minimum of e_grid, and every alignment shift must be >= 0.
 *     Taking the maximum instead passes ORACLE 1 on any case whose grids are
 *     equal and fails only where they differ, so it is asserted rather than
 *     sampled.
 *
 *   ORACLE 4, the FLOOR of the alignment, separated from a round by an
 *     INEQUALITY and not by a magnitude.  With true = y_pre * 2^-(e_grid-e_min)
 *     computed in double,
 *         true - 1 < y_al <= true
 *     A round violates the upper half on any element whose discarded bits are
 *     at least half an LSB.  ORACLE 1 cannot see this because its bound admits
 *     the floor.
 *
 *   ORACLE 5, saturation, and the ASYMMETRY that falls out of the peak window.
 *     sat16 has two rails and only ONE of them ever clips, which is a DERIVED
 *     fact and not an observation:
 *
 *       shp is defined so that amax < 2^(shp + TARGET_MSB + 1) = 2^(shp+15),
 *       and |y_al| <= amax for every element, so y_al / 2^shp lies strictly
 *       inside (-2^15, 2^15).  round_shift is floor(v/2^shp + 1/2), so the top
 *       end reaches exactly 2^15 = 32768 -- which sat16 clips to 32767, the
 *       ONLY value it ever clips -- and the bottom end reaches exactly
 *       -2^15 = -32768, which is REPRESENTABLE in int16 and passes through
 *       untouched.
 *
 *     So every mantissa lies in [-32768, 32767], asserted here as an exact
 *     inequality on every element, and sat16's LOW branch is a pure width
 *     guard that no legal input reaches.  The generator requires both ends to
 *     be hit, because they are hit by different mechanisms and a vector set
 *     that reaches neither lets a DUT that wraps at either one pass.
 *
 *     THE FIRST VERSION OF THIS PARAGRAPH WAS WRONG, and it is kept here as a
 *     correction rather than silently fixed.  It argued that y_al + 2^(shp-1)
 *     > -2^(shp+15) + 2^(shp-1) makes the floor "at least -2^15 + 1", i.e.
 *     that -32768 is unreachable.  That step is false: floor of anything in
 *     (-32768.0, -32767.5] is -32768, not -32767.  A single element at
 *     -(2^21 - 1) with equal grids gives amax = 2^21 - 1, shp = 6 and
 *     round_shift(-2097151, 6) = floor(-32767.484) = -32768 exactly.  The
 *     generator's own coverage assertion is what exposed it: it demanded a
 *     value the wrong derivation had declared impossible, could not produce
 *     it, and the search for a shape that would produce it found the algebra
 *     error instead.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_emit_vec attn_emit_vec.c -lm
 * Usage: ./attn_emit_vec [out.txt] [ncase] [ngrp] [grp_n]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_EM_IN_W      24    /* attn_gate's y_pre                        */
#define ATTN_EM_MANT_W    16    /* A's activation memory holds int16        */
#define ATTN_EM_TARGET    (ATTN_EM_MANT_W - 2)   /* 14; see ORACLE 2        */

/* Restated independently for the oracles.  attn_score_q12_vec.c records that
 * sharing a constant between the thing under test and the thing testing it let
 * a mutation of it pass both oracles, because the golden moved with the path.
 * This MUST NOT be defined in terms of ATTN_EM_TARGET. */
#define ATTN_EM_TARGET_ORACLE 14

typedef struct {
    int      e_min;
    int      shp;
    int      y_exp;
    uint64_t amax;      /* over the ALIGNED values */
    int      nsat;
    int      err;       /* an alignment shift came out negative */
} attn_emit_t;

/* One pass over the whole layer.  y_al is written back so the oracles can see
 * the aligned intermediate; the RTL recomputes it in its second pass rather
 * than storing it, which is a scratch-memory decision and not a numeric one. */
static void attn_emit(const int64_t *y_pre, const int *e_grid,
                      int ngrp, int grp_n,
                      int64_t *y_al, int32_t *y_mant, attn_emit_t *o)
{
    int n = ngrp * grp_n;
    o->err = 0; o->nsat = 0;

    o->e_min = e_grid[0];
    for (int g = 1; g < ngrp; g++)
        if (e_grid[g] < o->e_min) o->e_min = e_grid[g];

    uint64_t amax = 0;
    for (int i = 0; i < n; i++) {
        int g  = i / grp_n;
        int sh = e_grid[g] - o->e_min;
        if (sh < 0) { o->err = 1; sh = 0; }      /* unreachable: e_min is a min */
        if (sh > 63) sh = 63;
        int64_t a = mv4i_floor_shr(y_pre[i], sh);
        y_al[i] = a;
        uint64_t m = (a < 0) ? (uint64_t)(-a) : (uint64_t)a;
        if (m > amax) amax = m;
    }
    o->amax = amax;

    int p = mv4i_msb_pos_u(amax);            /* msb_pos(0) = 0, NORMATIVE */
    o->shp = p - ATTN_EM_TARGET;
    if (o->shp < 0) o->shp = 0;
    o->y_exp = o->e_min - o->shp;

    for (int i = 0; i < n; i++) {
        int64_t r = mv4i_round_shift(y_al[i], o->shp);
        int32_t m = mv4i_sat16(r);
        if ((int64_t)m != r) o->nsat++;
        y_mant[i] = m;
    }
}

#ifndef ATTN_EMIT_INCLUDE

static uint64_t es = 20260901ULL;
static uint32_t ernd(void){ es ^= es<<13; es ^= es>>7; es ^= es<<17; return (uint32_t)(es>>32); }

#define MAXN  4096
#define MAXG  8

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_emit_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 40;
    int ngrp  = (argc > 3) ? atoi(argv[3]) : 2;    /* KV heads per card      */
    int grp_n = (argc > 4) ? atoi(argv[4]) : 48;   /* G x D in the real build */
    if (ngrp > MAXG) ngrp = MAXG;
    if (ngrp * grp_n > MAXN) grp_n = MAXN / ngrp;
    int n = ngrp * grp_n;

    static int64_t y_pre[MAXN], y_al[MAXN];
    static int32_t y_mant[MAXN];
    int e_grid[MAXG];

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d %d\n", ncase, ngrp, grp_n, ATTN_EM_IN_W,
            ATTN_EM_MANT_W, ATTN_EM_TARGET);

    long n_o1 = 0, n_o2 = 0, n_o3 = 0, n_o4 = 0, n_o5 = 0;
    double w1 = 0.0; int w1_c = -1;
    long n_shp0 = 0, n_shpp = 0, n_eq = 0, n_diff = 0, n_zero = 0;
    long n_sat = 0, n_min16 = 0, n_bigsh = 0, n_neg = 0, n_pos = 0;
    long n_rail = 0, n_al_m1 = 0;

    const int64_t IN_MAX =  ((int64_t)1 << (ATTN_EM_IN_W - 1)) - 1;
    const int64_t IN_MIN = -((int64_t)1 << (ATTN_EM_IN_W - 1));

    for (int c = 0; c < ncase; c++) {
        /* Grid shapes, chosen for what is easy to get wrong:
         *  0  every e_grid equal    -- every shift is 0, so the alignment is a
         *                              no-op and only the pack is tested
         *  1  differ by 1           -- the smallest real alignment
         *  2  differ by a lot       -- a shift that floors small magnitudes to
         *                              0 or -1, which is where a floor and a
         *                              round part company
         *  3  descending            -- the minimum is NOT e_grid[0], which is
         *                              the only shape that catches a seed of
         *                              e_grid[0] with no scan
         *  else random
         */
        int gshape = c % 5;
        for (int g = 0; g < ngrp; g++) {
            switch (gshape) {
            case 0: e_grid[g] = 20; break;
            case 1: e_grid[g] = 20 + g; break;
            case 2: e_grid[g] = 20 + 11 * g; break;
            case 3: e_grid[g] = 20 - 7 * g; break;
            default: e_grid[g] = 4 + (int)(ernd() % 40u); break;
            }
        }

        /* Value shapes. */
        int vshape = c % 9;
        for (int i = 0; i < n; i++) {
            int64_t x;
            switch (vshape) {
            case 0: x = 0; break;                          /* the all-zero case */
            case 1:
                x = (i & 1) ? IN_MAX : IN_MIN; break;      /* the s24 rails     */
            case 2:
                /* one large element, the rest tiny: shp is set by a single
                 * value and every other mantissa is near zero */
                x = (i == n / 3) ? IN_MAX
                                 : (int64_t)(ernd() % 7u) - 3; break;
            case 8:
                /* THE PEAK AT THE LAST ELEMENT OF A GROUP.  This shape exists
                 * because of RTL mutation E13: a DUT whose pass-A shift lookup
                 * reads the LIVE group counter instead of the one carried
                 * through the pipeline takes the NEXT group's shift for the
                 * last two elements of every group.  That corrupts only amax,
                 * so it is invisible unless the PEAK is one of those elements
                 * -- and with the peak anywhere else the mutation SURVIVED all
                 * three handshake configurations over 40 layers.  It is the
                 * same shape as attn_kv_quant's carried block index and
                 * gdn_emit_chain's head 23: every value in range, the count
                 * right, and only the last element of a group wrong. */
                x = (i == grp_n - 1 || i == grp_n - 2)
                      ? -IN_MAX : (int64_t)(ernd() % 5u) - 2; break;
            case 3: {
                /* engineered so the peak rounds UP past 2^15 and saturates:
                 * an aligned magnitude of 2^15 * 2^k - 1 rounds to 2^15 */
                int k = 5;
                x = (i == 1) ? (((int64_t)1 << (15 + k)) - 1)
                             : (int64_t)(ernd() % 64u); break; }
            case 4:
                /* Engineered for the BOTTOM of the mantissa range.  A single
                 * element at -(2^21 - 1) with equal grids gives amax = 2^21-1,
                 * shp = 6 and round_shift(-2097151, 6) = -32768 exactly -- the
                 * value reached by the ROUND and not by a clip.  Nothing
                 * random produces it: it needs the peak's magnitude to sit in
                 * the top half-LSB of its own window. */
                x = (i == 2) ? -(((int64_t)1 << 21) - 1)
                             : (int64_t)(ernd() % 4096u) - 2048; break;
            case 5:
                x = -(int64_t)(ernd() % 1024u) - 1; break; /* all negative     */
            case 6: {
                uint32_t k = ernd() % 24u;
                x = (int64_t)(ernd() & ((1u << k) - 1u));
                if (ernd() & 1u) x = -x;
                break; }
            default: {
                uint64_t m = ((uint64_t)ernd() << 32) | ernd();
                x = (int64_t)(m % (uint64_t)(IN_MAX + 1));
                if (ernd() & 1u) x = -x;
                break; }
            }
            if (x > IN_MAX) x = IN_MAX;
            if (x < IN_MIN) x = IN_MIN;
            y_pre[i] = x;
        }

        attn_emit_t r;
        attn_emit(y_pre, e_grid, ngrp, grp_n, y_al, y_mant, &r);

        if (r.err) {
            fprintf(stderr, "  FAIL: case %d reported a negative alignment "
                            "shift, which e_min being a MINIMUM makes "
                            "impossible\n", c);
            n_o3++;
        }

        /* ---- ORACLE 3: the minimum and the direction, exactly ------------ */
        {
            int m = e_grid[0];
            for (int g = 1; g < ngrp; g++) if (e_grid[g] < m) m = e_grid[g];
            if (r.e_min != m) {
                fprintf(stderr, "  FAIL oracle 3: case %d e_min %d is not the "
                                "minimum %d of e_grid\n", c, r.e_min, m);
                n_o3++;
            }
            for (int g = 0; g < ngrp; g++) {
                if (e_grid[g] - r.e_min < 0) {
                    fprintf(stderr, "  FAIL oracle 3: case %d group %d aligns "
                                    "by %d, a LEFT shift\n", c, g,
                            e_grid[g] - r.e_min);
                    n_o3++;
                }
            }
        }

        for (int i = 0; i < n; i++) {
            int g = i / grp_n;

            /* ---- ORACLE 4: the alignment is a FLOOR ---------------------- */
            {
                double truth = ldexp((double)y_pre[i],
                                     -(e_grid[g] - r.e_min));
                if (!((double)y_al[i] <= truth + 1e-9
                      && (double)y_al[i] > truth - 1.0 - 1e-9)) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: case %d elem %d -- y_al %lld is not "
                        "in (%.6f, %.6f]; the alignment must FLOOR, and a "
                        "round violates the upper half\n", c, i,
                        (long long)y_al[i], truth - 1.0, truth);
                    n_o4++;
                }
            }

            /* ---- ORACLE 1: the pack against double, DERIVED bound --------
             * Written through y_exp, NOT through (e_min, shp).  The first
             * version formed the truth as
             *     ldexp(y_pre, -(e_grid - e_min) - shp)
             * which never mentions y_exp at all -- so y_exp was an EMITTED
             * GOLDEN THAT NO ORACLE READ, and reference mutation R8
             * (y_exp = e_min + shp instead of e_min - shp) SURVIVED every
             * check.  The form below is what a consumer actually does:
             * reconstruct y_mant * 2^-y_exp and compare against
             * y_pre * 2^-e_grid.  It is arithmetically the same comparison
             * and it makes y_exp load-bearing. */
            {
                double truth = ldexp((double)y_pre[i],
                                     r.y_exp - e_grid[g]);
                double bnd = ldexp(1.0, -r.shp) + 0.5;
                double e = fabs((double)y_mant[i] - truth);
                /* Saturation is a legal, checked outcome and is outside this
                 * bound by construction; ORACLE 5 covers it. */
                int saturated = (y_mant[i] == 32767 || y_mant[i] == -32768)
                                && fabs(truth) > 32767.0;
                if (!saturated) {
                    double ratio = e / bnd;
                    if (ratio > w1) { w1 = ratio; w1_c = c; }
                    if (ratio > 1.0) {
                        if (n_o1 < 8) fprintf(stderr,
                            "  FAIL oracle 1: case %d elem %d -- y_mant %d "
                            "against y_pre*2^(e_min-e_grid-shp) = %.6f, error "
                            "%.6f over the derived bound %.6f\n", c, i,
                            y_mant[i], truth, e, bnd);
                        n_o1++;
                    }
                }
            }

            if (y_mant[i] ==  32767) n_sat++;
            /* ---- ORACLE 5: the derived range, as an exact inequality ----- */
            if (y_mant[i] < -32768 || y_mant[i] > 32767) {
                if (n_o5 < 8) fprintf(stderr,
                    "  FAIL oracle 5: case %d elem %d mantissa %d is outside "
                    "[-32768, 32767], which the peak window makes impossible\n",
                    c, i, y_mant[i]);
                n_o5++;
            }
            if (y_mant[i] == -32768) n_min16++;
            if (y_al[i] < 0) n_neg++; else if (y_al[i] > 0) n_pos++;
            if (y_al[i] == -1 && y_pre[i] < -1) n_al_m1++;
            if (y_pre[i] == IN_MAX || y_pre[i] == IN_MIN) n_rail++;
        }

        /* ---- ORACLE 2: the peak window, exactly --------------------------
         * The peak is RECOMPUTED here from the aligned values rather than read
         * out of the path's own `r.amax`.  Reading r.amax makes the check
         * self-consistent with whatever the path folded: reference mutation
         * R10 (amax folded over the UNALIGNED values, so shp is set by the
         * wrong magnitude) SURVIVED, because the oracle then compared the
         * mutated amax against the shp derived from it.  A quantity shared
         * between the thing under test and the thing testing it is not a
         * check, it is a restatement -- the same trap attn_score_q12_vec.c
         * records for a shared CONSTANT, one level up. */
        {
            uint64_t peak_ref = 0;
            for (int i = 0; i < n; i++) {
                uint64_t m = (y_al[i] < 0) ? (uint64_t)(-y_al[i])
                                           : (uint64_t)y_al[i];
                if (m > peak_ref) peak_ref = m;
            }
            if (peak_ref != r.amax) {
                fprintf(stderr, "  FAIL oracle 2: case %d amax %llu is not the "
                        "peak %llu of the ALIGNED values\n", c,
                        (unsigned long long)r.amax,
                        (unsigned long long)peak_ref);
                n_o2++;
            }
        }
        /* The all-zero layer, as an exact equality.  msb_pos(0) = 0 is
         * NORMATIVE, so shp must be 0 and y_exp must be e_min untouched.  It
         * needs its own check because every mantissa is zero either way, so
         * ORACLE 1 reconstructs 0 against 0 whatever y_exp says and ORACLE 2
         * does not run at all: reference mutation R12b (msb_pos(0) treated as
         * TARGET_MSB + 6) SURVIVED both.  An arbitrary exponent on an all-zero
         * block is only harmless until something accumulates into that grid. */
        if (r.amax == 0 && (r.shp != 0 || r.y_exp != r.e_min)) {
            fprintf(stderr, "  FAIL oracle 2: case %d has amax = 0 but shp %d "
                    "and y_exp %d; msb_pos(0) = 0 is normative, so they must "
                    "be 0 and e_min = %d\n", c, r.shp, r.y_exp, r.e_min);
            n_o2++;
        }
        if (r.amax != 0) {
            uint64_t peak = r.amax >> r.shp;
            if (r.shp > 0) {
                if (!(peak >= ((uint64_t)1 << ATTN_EM_TARGET_ORACLE)
                      && peak < ((uint64_t)1 << (ATTN_EM_TARGET_ORACLE + 1)))) {
                    fprintf(stderr, "  FAIL oracle 2: case %d peak %llu after "
                            "shp %d is outside [2^%d, 2^%d)\n", c,
                            (unsigned long long)peak, r.shp,
                            ATTN_EM_TARGET_ORACLE, ATTN_EM_TARGET_ORACLE + 1);
                    n_o2++;
                }
            } else {
                if (!(peak < ((uint64_t)1 << (ATTN_EM_TARGET_ORACLE + 1)))) {
                    fprintf(stderr, "  FAIL oracle 2: case %d shp is 0 but the "
                            "peak %llu is at or above 2^%d, so it should have "
                            "been shifted\n", c, (unsigned long long)peak,
                            ATTN_EM_TARGET_ORACLE + 1);
                    n_o2++;
                }
            }
        }

        if (r.shp == 0) n_shp0++; else n_shpp++;
        if (r.shp > 8) n_bigsh++;
        if (r.amax == 0) n_zero++;
        {
            int all_eq = 1;
            for (int g = 1; g < ngrp; g++)
                if (e_grid[g] != e_grid[0]) all_eq = 0;
            if (all_eq) n_eq++; else n_diff++;
        }

        fprintf(f, "%d", c);
        for (int g = 0; g < ngrp; g++) fprintf(f, " %d", e_grid[g]);
        fprintf(f, " %d %d %d %d\n", r.e_min, r.shp, r.y_exp, r.nsat);
        for (int i = 0; i < n; i++) fprintf(f, "%lld ", (long long)y_pre[i]);
        fprintf(f, "\n");
        for (int i = 0; i < n; i++) fprintf(f, "%d ", y_mant[i]);
        fprintf(f, "\n");
    }
    fclose(f);

    /* ---- ORACLE 5: the reachable rail must actually be reached ----------- */
    if (n_sat == 0) {
        fprintf(stderr, "  FAIL oracle 5: sat16 never fired.  The peak lands "
                        "just below 2^%d after the shift and round_shift can "
                        "carry it to exactly 2^15, so a vector set that never "
                        "reaches the clip lets a DUT that wraps there pass\n",
                ATTN_EM_TARGET_ORACLE + 1);
        n_o5++;
    }
    if (n_min16 == 0) {
        fprintf(stderr, "  FAIL oracle 5: -32768 -- the most negative mantissa "
                        "the peak window allows, reached by the ROUND rather "
                        "than by a clip -- never appeared, so the bottom of "
                        "the range is untested\n");
        n_o5++;
    }

    fprintf(stderr, "attn_emit_vec: %d layers x %d groups x %d elements -> %s\n",
            ncase, ngrp, grp_n, out);
    fprintf(stderr, "  oracle 1  worst |y_mant - true| / derived bound: %.4f "
                    "(case %d)\n", w1, w1_c);
    fprintf(stderr, "  shp = 0 %ld, shp > 0 %ld, shp > 8 %ld, amax = 0 %ld\n",
            n_shp0, n_shpp, n_bigsh, n_zero);
    fprintf(stderr, "  grids equal %ld, differing %ld; aligned neg %ld pos "
                    "%ld, floored to -1 %ld\n",
            n_eq, n_diff, n_neg, n_pos, n_al_m1);
    fprintf(stderr, "  mantissas at +32767 %ld, at -32768 %ld; inputs at the "
                    "s24 rails %ld\n", n_sat, n_min16, n_rail);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld\n", n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld\n", n_o4); fail = 1; }
    if (n_o5) { fprintf(stderr, "  FAIL oracle 5: %ld\n", n_o5); fail = 1; }

    /* Absent coverage is a FAILURE of the generator, not a note.  Every
     * counter below names a corner that is reachable and that a plausible
     * defect lives at; this is the assertion class that found the z = 0 resize
     * defect in attn_softmax. */
    if (n_shp0 == 0 || n_shpp == 0 || n_bigsh == 0 || n_zero == 0
        || n_eq == 0 || n_diff == 0 || n_neg == 0 || n_pos == 0
        || n_al_m1 == 0 || n_rail == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- shp0 %ld shp>0 %ld shp>8 %ld "
                "amax0 %ld grids-eq %ld grids-diff %ld al- %ld al+ %ld "
                "floored-to--1 %ld input-rails %ld; every one must be "
                "non-zero\n", n_shp0, n_shpp, n_bigsh, n_zero, n_eq, n_diff,
                n_neg, n_pos, n_al_m1, n_rail);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: every mantissa inside the derived bound against the "
                    "double reconstruction, the peak inside its exact window, "
                    "e_min the true minimum with every alignment a right "
                    "shift, the alignment a floor rather than a round, and "
                    "both saturation corners reached\n");
    return 0;
}

#endif /* ATTN_EMIT_INCLUDE */
