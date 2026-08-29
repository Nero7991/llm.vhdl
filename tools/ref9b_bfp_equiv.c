/* tools/ref9b_bfp_equiv.c
 *
 * Closes one explicitly unverified claim in
 * docs/debugging/2026-08-29_9b-whole-model-reference.md section 9:
 *
 *   "The float-to-BFP repack is VALUE-equivalent to rtl/bfp_pack.vhd, not
 *    proven bit-identical to it.  bfp_pack shifts an int32 Q-grid input;
 *    reg_put shifts a double.  The rule (shift so the max lands in bit 14),
 *    round half toward +inf, saturate) is the same and the exponent
 *    convention is the same, but no test compares them."
 *
 * This program is that test.  It has three parts and they are deliberately
 * separated, because two of them could each be wrong on their own:
 *
 *   1. `hw_rule` -- a C transcription of rtl/bfp_pack.vhd.  A transcription is
 *      not evidence about the RTL; it is evidence about my reading of the RTL.
 *      So `--emit` writes the SAME cases to a text file that
 *      tools/ref9b_bfp_equiv_tb.vhd feeds to the shipping entity, and
 *      `--score` compares this function against what the entity PRINTED.  The
 *      project rule is that the RTL wins, so the RTL is what runs.
 *
 *   2. `ref_rule` -- a transcription of ref/run9b.c's `reg_put`, the reference
 *      stream's repack.  Kept verbatim in shape (same branch order, same
 *      primitives) so a reader can diff it against run9b.c by eye.
 *
 *   3. `--compare` -- hw_rule against ref_rule over the same values, with the
 *      divergences CLASSIFIED rather than counted.  A count would say the two
 *      differ; the classification says on WHICH INPUTS, which is the only form
 *      a bring-up engineer can act on.
 *
 * THE APPLES-TO-APPLES FRAMING, stated because it is an assumption and not a
 * fact.  bfp_pack's input is an int32 on grid 2^-Q; reg_put's input is a
 * double.  The comparison feeds reg_put the real number the hardware's int32
 * denotes, v[i] = u[i] * 2^-Q.  That is the best case for agreement: it grants
 * the reference a perfect interior.  Every divergence found under it is
 * therefore a LOWER BOUND on the real divergence, never an artefact of a
 * mismatched input.
 *
 * Mutants: -DREF9B_BFPEQ_MUT=n perturbs hw_rule only, so `--score` (against
 * the RTL) is the checker under test.  A mutant that --score does not catch is
 * reported by name; it measures the resolution floor of this harness.
 *
 * Build:  gcc -O2 -Wall -Wextra -I ref -o tools/ref9b_bfp_equiv \
 *              tools/ref9b_bfp_equiv.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#include "mv4i_arith.h"   /* mv4i_round_shift, mv4i_sat16, mv4i_msb_pos_u */

#ifndef REF9B_BFPEQ_MUT
#define REF9B_BFPEQ_MUT 0
#endif

#define MAXN 256

/* ------------------------------------------------------------------ */
/* 1. The hardware rule, transcribed from rtl/bfp_pack.vhd.            */
/*                                                                     */
/* S_MAX  : max_abs = max_i |in[i]|            (unsigned vector)       */
/*          p_msb   = msb_pos_u(max_abs)       (msb_pos_u(0) = 0)      */
/*          sh      = p_msb - 14, clamped at 0                         */
/*          o_exp   = Q - sh                                           */
/* S_PACK : o_mant[i] = sat16(round_half_up(in[i] >> sh))              */
/*                                                                     */
/* This is the same rule ref/matvec_int4.c's `bfp_pack_vec` (:565)     */
/* already carries for the matvec path, which is why the matvec seams  */
/* of the reference are NOT affected by anything found here.           */
/* ------------------------------------------------------------------ */
static int hw_rule(const int32_t *u, int n, int Q, int16_t *mant)
{
    uint64_t amax = 0;
    for (int i = 0; i < n; i++) {
        int64_t a = (int64_t)u[i];
        uint64_t m = (uint64_t)(a < 0 ? -a : a);
        if (m > amax) amax = m;
    }

#if REF9B_BFPEQ_MUT == 2
    /* m2: msb_pos(0) = -1 rather than the NORMATIVE 0. */
    int p_msb = (amax == 0) ? -1 : mv4i_msb_pos_u(amax);
#else
    int p_msb = mv4i_msb_pos_u(amax);
#endif

#if REF9B_BFPEQ_MUT == 5
    int sh = p_msb - 15;              /* m5: off by one in the target bit */
#else
    int sh = p_msb - 14;
#endif

#if REF9B_BFPEQ_MUT == 1
    /* m1: no clamp.  This is exactly the reference's rule: always normalise,
     * left-shifting when the block is quiet.  bfp_pack CANNOT do this. */
#else
    if (sh < 0) sh = 0;
#endif

    for (int i = 0; i < n; i++) {
        int64_t r;
        if (sh < 0) {
            r = (int64_t)u[i] << (-sh);
        } else {
#if REF9B_BFPEQ_MUT == 3
            r = mv4i_floor_shr((int64_t)u[i], sh);      /* m3: no round bias */
#elif REF9B_BFPEQ_MUT == 6
            /* m6: apply the bias even at sh = 0. */
            r = (sh == 0) ? (int64_t)u[i] + 1 : mv4i_round_shift((int64_t)u[i], sh);
#else
            r = mv4i_round_shift((int64_t)u[i], sh);
#endif
        }
#if REF9B_BFPEQ_MUT == 4
        /* m4: symmetric saturation, -32767 instead of -32768. */
        if (r >  32767) r =  32767;
        if (r < -32767) r = -32767;
        mant[i] = (int16_t)r;
#else
        mant[i] = mv4i_sat16(r);
#endif
    }

#if REF9B_BFPEQ_MUT == 7
    return Q + sh;                    /* m7: sign of the shift term */
#else
    return Q - sh;
#endif
}

/* ------------------------------------------------------------------ */
/* 2. The reference rule, transcribed from ref/run9b.c `reg_put`.      */
/* Kept in the same shape as the original so it can be diffed by eye.  */
/* ------------------------------------------------------------------ */
static int ref_rule(const double *v, int n, int16_t *mant)
{
    double amax = 0;
    for (int i = 0; i < n; i++) { double a = fabs(v[i]); if (a > amax) amax = a; }
    if (amax == 0) {
        for (int i = 0; i < n; i++) mant[i] = 0;
        return 0;                                  /* reg_put: r->exp = 0 */
    }
    int e   = (int)floor(log2(amax));
    int exp = 14 - e;
    for (int i = 0; i < n; i++) {
        double s = ldexp(v[i], exp);
        long long q = (long long)floor(s + 0.5);   /* half toward +inf */
        mant[i] = mv4i_sat16(q);
    }
    return exp;
}

/* ------------------------------------------------------------------ */
/* Case generation.  Named edge cases first, then a magnitude sweep.   */
/* ------------------------------------------------------------------ */
static uint64_t rng_s = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
    rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
    return rng_s;
}

typedef struct { int32_t u[MAXN]; const char *tag; } case_t;

static int gen_cases(case_t *c, int cap, int n)
{
    int k = 0;
    #define PUT(TAG) do { if (k < cap) { c[k].tag = (TAG); k++; } } while (0)
    #define ZERO()   do { for (int i = 0; i < n; i++) c[k].u[i] = 0; } while (0)

    /* Named edges.  Each one exists because a specific clause of bfp_pack or
     * of reg_put is only reachable from it. */
    ZERO();                                   PUT("all-zero");
    ZERO(); c[k].u[0] = 1;                    PUT("single-lsb");
    ZERO(); c[k].u[0] = -1;                   PUT("single-lsb-neg");
    ZERO(); c[k].u[0] = 16384;                PUT("max-at-bit14");
    ZERO(); c[k].u[0] = 16383;                PUT("just-below-bit14");
    ZERO(); c[k].u[0] = 32767;                PUT("int16-max");
    ZERO(); c[k].u[0] = -32768;               PUT("int16-min");
    ZERO(); c[k].u[0] = 32768;                PUT("one-past-int16");
    ZERO(); c[k].u[0] = 65535;                PUT("bias-saturates");
    ZERO(); c[k].u[0] = -65535;               PUT("bias-saturates-neg");
    ZERO(); c[k].u[0] = 65536;                PUT("pow2-boundary");
    ZERO(); c[k].u[0] = 2147483647;           PUT("int32-max");
    ZERO(); c[k].u[0] = -2147483647 - 1;      PUT("int32-min");
    ZERO(); for (int i = 0; i < n; i++) c[k].u[i] = (i & 1) ? -3 : 3;
                                              PUT("quiet-alternating");
    ZERO(); for (int i = 0; i < n; i++) c[k].u[i] = (int32_t)(1 << (i % 15));
                                              PUT("power-ladder");
    ZERO(); c[k].u[0] = 40000; c[k].u[1] = -40000; c[k].u[2] = 1;
                                              PUT("negative-tie");

    /* Magnitude sweep: one decade of exponent per band, so both the sh = 0
     * (quiet) and sh > 0 (loud) branches are reached many times. */
    for (int bits = 1; bits <= 31 && k < cap; bits++) {
        for (int rep = 0; rep < 24 && k < cap; rep++) {
            for (int i = 0; i < n; i++) {
                uint64_t r = rnd();
                int64_t  m = (int64_t)(r & (((uint64_t)1 << bits) - 1));
                if (r & 0x8000000000000000ull) m = -m;
                if (m >  2147483647LL) m =  2147483647LL;
                if (m < -2147483648LL) m = -2147483648LL;
                c[k].u[i] = (int32_t)m;
            }
            PUT("sweep");
        }
    }
    #undef PUT
    #undef ZERO
    return k;
}

int main(int argc, char **argv)
{
    int n = 16, Q = 12, cap = 4096;
    const char *emit = NULL, *score = NULL;
    int do_compare = 0, verbose = 0;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--n")       && i + 1 < argc) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--q")       && i + 1 < argc) Q = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--cases")   && i + 1 < argc) cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--emit")    && i + 1 < argc) emit = argv[++i];
        else if (!strcmp(argv[i], "--score")   && i + 1 < argc) score = argv[++i];
        else if (!strcmp(argv[i], "--compare"))                 do_compare = 1;
        else if (!strcmp(argv[i], "--verbose"))                 verbose = 1;
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }
    if (n < 1 || n > MAXN) { fprintf(stderr, "n out of range\n"); return 2; }
    if (cap > 20000) cap = 20000;

    case_t *cs = calloc((size_t)cap, sizeof *cs);
    if (!cs) { fprintf(stderr, "oom\n"); return 2; }
    int nc = gen_cases(cs, cap, n);
    printf("MUT %d  N %d  Q %d  CASES %d\n", REF9B_BFPEQ_MUT, n, Q, nc);

    if (emit) {
        FILE *fp = fopen(emit, "w");
        if (!fp) { perror(emit); return 2; }
        for (int c = 0; c < nc; c++) {
            for (int i = 0; i < n; i++)
                fprintf(fp, "%s%d", i ? " " : "", cs[c].u[i]);
            fputc('\n', fp);
        }
        fclose(fp);
        printf("EMIT %s %d cases\n", emit, nc);
    }

    /* ---- 1. hw_rule scored against what the RTL actually printed ---- */
    if (score) {
        FILE *fp = fopen(score, "r");
        if (!fp) { perror(score); return 2; }
        int bad = 0, seen = 0, rtl_cases = -1;
        char line[16384];
        int16_t hm[MAXN];
        while (fgets(line, sizeof line, fp)) {
            if (!strncmp(line, "CASES ", 6)) { rtl_cases = atoi(line + 6); continue; }
            if (strncmp(line, "OUT ", 4)) continue;
            char *p = line + 4;
            int idx = (int)strtol(p, &p, 10);
            int rexp = (int)strtol(p, &p, 10);
            if (idx < 0 || idx >= nc) { printf("SCORE-BAD stray case %d\n", idx); bad++; continue; }
            int hexp = hw_rule(cs[idx].u, n, Q, hm);
            int diff = 0;
            if (hexp != rexp) diff = 1;
            for (int i = 0; i < n; i++) {
                int mv = (int)strtol(p, &p, 10);
                if (mv != (int)hm[i]) diff = 1;
            }
            seen++;
            if (diff) {
                bad++;
                if (bad <= 8)
                    printf("SCORE-MISMATCH case %d (%s): rtl_exp %d c_exp %d\n",
                           idx, cs[idx].tag, rexp, hexp);
            }
        }
        fclose(fp);

        /* AN EMPTY COMPARISON MUST NOT READ AS A PASSING ONE.  Measured
         * 2026-08-29: without the two guards below, scoring against a log that
         * held only a GHDL error printed "SCORE 0 compared, 0 mismatched --
         * BIT-IDENTICAL".  That is the same defect as `regress.sh --only`
         * printing PASS on PASS 0, reproduced inside a tool written to check
         * for exactly that class.  A checker that cannot tell "nothing was
         * checked" from "everything passed" has not been shown to work. */
        if (seen == 0) {
            printf("SCORE-BAD no OUT lines parsed from %s -- the RTL run "
                   "produced nothing to compare\n", score);
            bad++;
        }
        if (rtl_cases < 0) {
            printf("SCORE-BAD %s has no CASES trailer -- the RTL run did not "
                   "reach the end of its vector file\n", score);
            bad++;
        } else if (rtl_cases != seen) {
            printf("SCORE-BAD rtl reported %d cases, %d OUT lines parsed\n",
                   rtl_cases, seen);
            bad++;
        }

        printf("SCORE %d compared, %d mismatched vs rtl/bfp_pack.vhd -- %s\n",
               seen, bad, bad ? "TRANSCRIPTION DISAGREES WITH THE RTL" : "BIT-IDENTICAL");
        if (bad) { free(cs); return 1; }
    }

    /* ---- 2. hw_rule against ref_rule, classified ---- */
    if (do_compare) {
        long same = 0, exp_diff = 0, mant_diff = 0, val_diff = 0;
        long quiet = 0, hw_sat = 0, ref_sat = 0, zero_case = 0;
        long exp_diff_quiet = 0, exp_diff_loud = 0;
        double worst_rel = 0; int worst_case_i = -1;
        int16_t hm[MAXN], rm[MAXN];
        double v[MAXN];

        for (int c = 0; c < nc; c++) {
            for (int i = 0; i < n; i++) v[i] = ldexp((double)cs[c].u[i], -Q);
            int he = hw_rule(cs[c].u, n, Q, hm);
            int re = ref_rule(v, n, rm);

            /* Is this block quiet, i.e. would bfp_pack leave sh = 0? */
            uint64_t amax = 0;
            for (int i = 0; i < n; i++) {
                int64_t a = cs[c].u[i]; uint64_t m = (uint64_t)(a < 0 ? -a : a);
                if (m > amax) amax = m;
            }
            int is_quiet = (amax == 0) || (mv4i_msb_pos_u(amax) <= 14);
            if (amax == 0) zero_case++;
            if (is_quiet) quiet++;

            int hs = 0, rs = 0;
            for (int i = 0; i < n; i++) {
                if (hm[i] == 32767 || hm[i] == -32768) hs = 1;
                if (rm[i] == 32767 || rm[i] == -32768) rs = 1;
            }
            hw_sat += hs; ref_sat += rs;

            int ed = (he != re), md = 0;
            for (int i = 0; i < n; i++) if (hm[i] != rm[i]) md = 1;

            /* Value divergence: the reconstructed reals. */
            double wr = 0;
            for (int i = 0; i < n; i++) {
                double a = ldexp((double)hm[i], -he);
                double b = ldexp((double)rm[i], -re);
                double d = fabs(a - b);
                double s = fabs(a) > fabs(b) ? fabs(a) : fabs(b);
                double rel = (s > 0) ? d / s : (d > 0 ? 1.0 : 0.0);
                if (rel > wr) wr = rel;
            }
            if (wr > worst_rel) { worst_rel = wr; worst_case_i = c; }

            if (ed) { exp_diff++; if (is_quiet) exp_diff_quiet++; else exp_diff_loud++; }
            if (md) mant_diff++;
            if (wr > 0) val_diff++;
            if (!ed && !md) same++;

            if (verbose && (ed || md) && c < 20)
                printf("CMP case %-20s hw_exp %4d ref_exp %4d  quiet %d  worst_rel %.3e\n",
                       cs[c].tag, he, re, is_quiet, wr);
        }

        printf("COMPARE cases %d\n", nc);
        printf("  identical (exp and every mantissa) : %ld\n", same);
        printf("  exponent differs                   : %ld  (quiet %ld, loud %ld)\n",
               exp_diff, exp_diff_quiet, exp_diff_loud);
        printf("  some mantissa differs              : %ld\n", mant_diff);
        printf("  reconstructed VALUE differs        : %ld\n", val_diff);
        printf("  blocks bfp_pack leaves un-shifted  : %ld  (all-zero %ld)\n",
               quiet, zero_case);
        printf("  cases where bfp_pack saturates     : %ld\n", hw_sat);
        printf("  cases where reg_put  saturates     : %ld\n", ref_sat);
        printf("  worst relative value divergence    : %.6e (case %d %s)\n",
               worst_rel, worst_case_i,
               worst_case_i >= 0 ? cs[worst_case_i].tag : "-");
    }

    free(cs);
    return 0;
}
