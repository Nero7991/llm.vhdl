/* ref/attn_mac_array_vec.c -- vectors and golden for rtl/attn_mac_array.vhd.
 *
 * Subsystem C's MAC ARRAY: the replicated element the C spec calls
 * `attn_lane` + `attn_score_tree` + `attn_acc`, which had no RTL and no
 * reference at all before this file.  Everything else on C's read path
 * (attn_score_q12, attn_softmax, attn_recip, attn_gate, attn_emit) was built
 * against a stream this array is the only possible producer of, so until it
 * exists those units are five verified halves of a bridge with no span.
 *
 * WHAT THE ARRAY COMPUTES.  Three modes, sharing one multiplier per lane,
 * from C spec 3.1 and 3.2:
 *
 *   score    partial[qh][b] = sum over t in [0,DT) of q[qh][b*DT+t]*k[b*DT+t]
 *                             q s16, k s8, one block per cycle, per-head tree
 *   PV       o[qh][b*DT+t] += e[qh] * v[b*DT+t]
 *                             e u13 (<= 2^Q), v s8 -- v is ALREADY the
 *                             right-shifted v_aligned, so |v| <= 127
 *   rescale  o[qh][d]        = round_shift(o[qh][d] * f[qh], Q)
 *                             f u13, round half toward +infinity (site 5d)
 *
 * WHY THE SCORE PARTIAL IS PER BLOCK AND NOT PER VECTOR.  attn_score_q12
 * consumes exactly NBLK partials and aligns them by e_k[b] before summing,
 * because the KV record carries ONE EXPONENT PER 32-ELEMENT BLOCK (C spec
 * 2.1.1).  An array that reduced all 256 products into one number would make
 * that alignment impossible and would silently put eight different power-of-two
 * grids into one sum.  So DT = KV_BLOCK is not a tuning knob: it is the block
 * structure of the cache, and one MAC cycle spans exactly one exponent block.
 *
 * WHY THE RESCALE MODE IS ON THE LANE AT ALL.  The accumulator is s36 and
 * 36 > 27, so the rescale operand does not fit one DSP48E2 tile while the score
 * (16x8) and PV (13x8) operands each fit with room to spare.  That single fact
 * is what makes the lane 2 DSP rather than 1 and is 89% of C's DSP budget
 * (C skeleton 3.2, 3.6).  It is modelled here so the reference prices the same
 * structure the RTL builds.
 *
 * THE ROUNDING SITES, and both are C spec 2.1.5 / 3.2 sites, not new:
 *   site 5d   round_shift(o*f, Q)   round half toward +infinity
 *   sites 2/3 are NOT here: the score alignment lives in attn_score_q12 and
 *             the V alignment lives in the block, before this unit.  This unit
 *             sees v ALREADY aligned, which is why its operand is s8 and not
 *             s16, and getting that boundary wrong is the difference between a
 *             1-DSP and a 2-DSP PV mode.
 *
 * =========================== DOUBLE ORACLE ===========================
 *
 * A result is trusted here only when two implementations that share NO
 * machinery agree bit-exactly.  Six checks, and each says what it controls for:
 *
 *   ORACLE 1  Every score partial recomputed in DOUBLE precision, with no
 *             integer machinery anywhere in the path, and required to be
 *             EXACTLY equal.  Legitimate because every product is < 2^22 and
 *             the sum is < 2^27, both far inside the 2^53 where double
 *             represents integers exactly -- so "close enough" is not a
 *             tolerance here, it is equality.  This is the independent
 *             implementation; it shares no shift, no cast and no accumulator
 *             with the golden path.
 *
 *   ORACLE 2  Every score partial recomputed with __int128 accumulation in
 *             REVERSE index order.  Controls for two different things from
 *             oracle 1: an overflow the int32 path would wrap silently, and
 *             any order dependence.  Integer addition is associative, so a
 *             disagreement here is a real defect and never a rounding artefact.
 *
 *   ORACLE 3  The width bound |partial| <= DT * 2^(QW-1) * 2^(KW-1), asserted
 *             per case rather than argued once.  This is the premise
 *             attn_score_q12's own s32 width argument rests on
 *             (ref/attn_score_q12_vec.c: |partial| < 2^27), so if this array
 *             ever violates it the downstream unit is wrong and nothing else
 *             would say so.
 *
 *   ORACLE 4  The WHOLE accumulator trajectory replayed by a second,
 *             independently written routine that uses __int128 throughout and
 *             computes the rescale by FLOOR DIVISION rather than by an
 *             arithmetic shift:
 *                 floor(n / 2^Q) = n/2^Q - ((n % 2^Q != 0 && n < 0) ? 1 : 0)
 *             The shift and the division are different machinery and they
 *             disagree on exactly the case that is easiest to get wrong,
 *             negative operands, which is why this oracle is worth having and
 *             a second copy of `>> Q` would not be.
 *
 *   ORACLE 5  The rescale identity.  At f = 2^Q the rescale must leave every
 *             accumulator BIT-IDENTICAL, for negative accumulators too.  C
 *             spec 3.1 relies on this: heads whose maximum did not rise ride
 *             the same uniform pass with f = 4096, so a rescale that is not an
 *             exact identity there corrupts every head that did not rescale.
 *             It is checked as an exact equality on real data, not asserted.
 *
 *   ORACLE 6  The DSP48E2 port fit, checked as arithmetic rather than quoted:
 *             score and PV operands must fit 27x18 signed, and the rescale
 *             operand must NOT.  If a width change ever made all three fit,
 *             C's entire DSP budget would be wrong by a factor of two and no
 *             value check would notice.
 *
 * ============================ MUTATION TEST ============================
 *
 * Run with `--mutate` to apply each mutation in turn and report which oracle
 * kills it.  A property that has never fired is not a property.  Mutations are
 * deliberately the ones a plausible implementation would contain:
 *
 *   M1  score tree drops the last term            (an off-by-one on the loop)
 *   M2  rescale rounds half toward zero           (>> without the bias)
 *   M3  rescale rounds half away from zero        (bias on magnitude)
 *   M4  PV treats e as signed 13-bit              (sign-extends 4096)
 *   M5  PV treats v as unsigned                   (the classic s8 mistake)
 *   M6  rescale applied AFTER the PV of the same position, not before
 *   M7  score partial summed across blocks        (one number per head)
 *   M8  rescale identity broken at f = 2^Q        (>> Q+1)
 *
 * Build:  cc -O2 -o ref/attn_mac_array_vec ref/attn_mac_array_vec.c
 * Run:    ./ref/attn_mac_array_vec [outfile] [ncase] [QH] [DT] [ACCN] [NPOS]
 *         ./ref/attn_mac_array_vec --mutate
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "vec_seed.h"   /* the seed convention; see that header */

/* ---- parameters, defaults matched to sim/tb_attn_mac_array.vhd ---------- */
static int QH   = 2;    /* query heads per tile; 6 at 27B (the GQA group)    */
static int DT   = 8;    /* elements per beat;   32 at 27B (= KV_BLOCK)        */
static int ACCN = 4;    /* accumulators per lane; 8 at 27B (HEAD_DIM/DT)      */
static int NPOS = 6;    /* positions swept per case                          */

#define QW 16           /* q mantissa width                                  */
#define KW  8           /* cache mantissa width                              */
#define EW 13           /* e_p / f width, u13                                */
#define QS 12           /* the Q of e_p and f; round_shift amount            */
#define AW 36           /* accumulator width                                 */

/* ---- mutation switches, all zero on the golden path -------------------- */
static int M1,M2,M3,M4,M5,M6,M7,M8;

/* ---- deterministic PRNG, xorshift; no libc rand ------------------------ */
static uint32_t rs  = 0xC0FFEEu;
static uint32_t rs0 = 0xC0FFEEu;   /* the seed, kept for the mutant loop */
static uint32_t rnd32(void){ rs^=rs<<13; rs^=rs>>17; rs^=rs<<5; return rs; }

/* ---- the golden arithmetic ------------------------------------------- */

/* round half toward +infinity by s.  The project's site-1/4/5d/6b mode.  */
static int64_t round_shift(int64_t x, int s)
{
    if (s <= 0) return x;
    if (M2) return x >> s;                                   /* MUTATION */
    if (M3) {                                                /* MUTATION */
        int64_t b = ((int64_t)1 << (s-1));
        return (x >= 0) ? ((x + b) >> s) : -(((-x) + b) >> s);
    }
    return (x + ((int64_t)1 << (s-1))) >> s;
}

/* sat to AW bits, so the golden says what a 36-bit accumulator holds. */
static int64_t sat_acc(int64_t x, int *ovr)
{
    int64_t hi = ((int64_t)1 << (AW-1)) - 1;
    int64_t lo = -((int64_t)1 << (AW-1));
    if (x > hi) { *ovr = 1; return hi; }
    if (x < lo) { *ovr = 1; return lo; }
    return x;
}

int main(int argc, char **argv)
{
    const char *out = "attn_mac_array_vec.txt";
    int ncase = 24;
    int mutate = 0;
    int ai = 1;

    if (argc > 1 && strcmp(argv[1], "--mutate") == 0) { mutate = 1; ai = 2; }
    if (argc > ai)   out   = argv[ai];
    if (argc > ai+1) ncase = atoi(argv[ai+1]);
    if (argc > ai+2) QH    = atoi(argv[ai+2]);
    if (argc > ai+3) DT    = atoi(argv[ai+3]);
    if (argc > ai+4) ACCN  = atoi(argv[ai+4]);
    if (argc > ai+5) NPOS  = atoi(argv[ai+5]);
    /* The seed is captured into rs0 and NOT only into rs, because the mutant
     * loop below re-seeds rs on every pass so that every mutant sees the same
     * stimulus.  Resetting to the literal there would silently discard the
     * seed argument -- exactly the inert-knob defect sim/mutate_gdn_recur.sh
     * carried, where a SEED knob was declared, printed and never delivered. */
    rs0 = vec_seed32(argc, argv, ai+6, 0xC0FFEEu);
    rs  = rs0;

    int N = ACCN * DT;               /* elements per head vector            */

    int16_t *q   = malloc(sizeof(int16_t) * (size_t)QH * N);
    int8_t  *k   = malloc(sizeof(int8_t)  * (size_t)N);
    int8_t  *v   = malloc(sizeof(int8_t)  * (size_t)N);
    int32_t *e   = malloc(sizeof(int32_t) * (size_t)QH);
    int32_t *f   = malloc(sizeof(int32_t) * (size_t)QH);
    int64_t *acc = malloc(sizeof(int64_t) * (size_t)QH * N);
    int64_t *ac2 = malloc(sizeof(int64_t) * (size_t)QH * N);   /* oracle 4  */
    int32_t *par = malloc(sizeof(int32_t) * (size_t)QH * ACCN);
    if(!q||!k||!v||!e||!f||!acc||!ac2||!par){ perror("malloc"); return 2; }

    /* ORACLE 6 -- the DSP port fit, arithmetic and not a quotation.        */
    {
        int score_fits = (QW <= 27 && KW <= 18) || (QW <= 18 && KW <= 27);
        int pv_fits    = (EW <= 27 && KW <= 18) || (EW <= 18 && KW <= 27);
        int rs_fits    = (AW <= 27 && EW <= 18) || (AW <= 18 && EW <= 27);
        if (!score_fits || !pv_fits) {
            fprintf(stderr, "ORACLE 6: score/PV no longer fit one DSP48E2 "
                            "tile; C's 2-DSP lane is not this design\n");
            return 3;
        }
        if (rs_fits) {
            fprintf(stderr, "ORACLE 6: the rescale operand now FITS one tile. "
                            "C's whole DSP budget assumes it does not "
                            "(36 > 27); re-price the lane before trusting "
                            "any number in the C spec's section 3\n");
            return 3;
        }
    }

    int mut_lo = mutate ? 1 : 0, mut_hi = mutate ? 8 : 0;

    for (int mut = mut_lo; mut <= mut_hi; mut++) {
        M1=M2=M3=M4=M5=M6=M7=M8=0;
        switch (mut) {
            case 1: M1=1; break;  case 2: M2=1; break;
            case 3: M3=1; break;  case 4: M4=1; break;
            case 5: M5=1; break;  case 6: M6=1; break;
            case 7: M7=1; break;  case 8: M8=1; break;
            default: break;
        }

        rs = rs0;                       /* same stimulus for every mutant   */
        long o1=0,o2=0,o3=0,o4=0,o5=0;  /* per-oracle kill counts           */
        long n_ovr = 0, n_rs = 0;

        FILE *fp = NULL;
        if (!mutate) {
            fp = fopen(out, "w");
            if (!fp) { perror(out); return 1; }
            fprintf(fp, "%d %d %d %d %d\n", ncase, QH, DT, ACCN, NPOS);
        }

        for (int c = 0; c < ncase; c++) {
            /* Shapes, chosen for what is easy to get wrong.
             *  0  q all +1, k all +1        -- the tree's term count, exactly
             *  1  everything zero           -- zero must stay zero on all modes
             *  2  q at the s16 rails        -- the widest product
             *  3  k at -128                 -- the asymmetric int8 rail, the
             *                                  value an unsigned read gets wrong
             *  4  e at the 2^Q rail (4096)  -- the u13 top, sign-extends to
             *                                  negative if read as s13
             *  5  f = 2^Q on every head     -- ORACLE 5, the exact identity
             *  6  negative accumulators     -- the rounding mode's whole
             *                                  disagreement lives here
             *  7  accumulators driven large -- the s36 width, and overflow
             *  8  an EXACT rounding tie      -- e = 2^11, v = -1, f = 1, so
             *                                  the rescale argument is exactly
             *                                  -2^11 and the three plausible
             *                                  rounding modes disagree.  Added
             *                                  because mutation M3 (round half
             *                                  AWAY from zero) SURVIVED every
             *                                  oracle on random data: the
             *                                  modes differ only on exact
             *                                  ties, which random operands
             *                                  essentially never produce.  A
             *                                  rounding mode is only tested by
             *                                  a tie.
             *  else random
             */
            int shape = (c < 9) ? c : (int)(rnd32() % 9u);

            for (int h = 0; h < QH; h++)
                for (int i = 0; i < N; i++) {
                    int32_t val;
                    switch (shape) {
                    case 0: val = 1; break;
                    case 1: val = 0; break;
                    case 2: val = (rnd32() & 1u) ? 32767 : -32768; break;
                    case 6: val = -(int32_t)(rnd32() % 30000u) - 1; break;
                    case 8: val = 0; break;
                    default: val = (int32_t)(rnd32() % 65536u) - 32768; break;
                    }
                    q[(size_t)h*N + i] = (int16_t)val;
                }

            for (int i = 0; i < (size_t)QH*N; i++) { acc[i] = 0; ac2[i] = 0; }

            if (!mutate) {
                fprintf(fp, "%d %d\n", c, shape);   /* case index, shape */
                for (int h = 0; h < QH; h++) {
                    for (int i = 0; i < N; i++)
                        fprintf(fp, "%d ", (int)q[(size_t)h*N + i]);
                    fprintf(fp, "\n");
                }
            }

            for (int p = 0; p < NPOS; p++) {
                int do_rs = 0;
                for (int i = 0; i < N; i++) {
                    int32_t kv, vv;
                    switch (shape) {
                    case 0: kv = 1; vv = 1; break;
                    case 1: kv = 0; vv = 0; break;
                    case 3: kv = -128; vv = -128; break;
                    case 7: kv = 127;  vv = 127;  break;
                    case 8: kv = 0;    vv = -1;   break;
                    default:
                        kv = (int32_t)(rnd32() % 256u) - 128;
                        vv = (int32_t)(rnd32() % 256u) - 128;
                        break;
                    }
                    k[i] = (int8_t)kv;
                    v[i] = (int8_t)vv;
                }
                for (int h = 0; h < QH; h++) {
                    switch (shape) {
                    case 1: e[h] = 0; break;
                    case 4: e[h] = 4096; break;
                    case 7: e[h] = 4096; break;
                    case 8: e[h] = 2048; break;
                    default: e[h] = (int32_t)(rnd32() % 4097u); break;
                    }
                }
                /* A rescale on some positions, and ALWAYS on shape 5 where it
                 * is the identity being tested.  p > 0 because the first
                 * position of a sweep never rescales (C spec 3.2: first_r sets
                 * m_g directly, there is no sentinel). */
                if (shape == 5 || shape == 8) do_rs = (p > 0);
                else            do_rs = (p > 0) && ((rnd32() & 3u) == 0u);
                for (int h = 0; h < QH; h++) {
                    if (shape == 8) f[h] = 1;
                    else if (shape == 5) f[h] = 1 << QS;
                    else if ((rnd32() & 7u) == 0u) f[h] = 1 << QS; /* identity
                                                    rides the uniform pass */
                    else f[h] = (int32_t)(rnd32() % 3849u); /* <= EXP_ROM(255)
                                                    >> 18, C spec 3.2 site 5c */
                }

                /* ---- score mode: one partial per (head, block) ---------- */
                for (int h = 0; h < QH; h++) {
                    for (int b = 0; b < ACCN; b++) {
                        int64_t s = 0;
                        int lim = M1 ? DT-1 : DT;             /* MUTATION M1 */
                        for (int t = 0; t < lim; t++)
                            s += (int64_t)q[(size_t)h*N + b*DT + t]
                               * (int64_t)k[b*DT + t];
                        par[h*ACCN + b] = (int32_t)s;
                    }
                    if (M7) {                                 /* MUTATION M7 */
                        int64_t t = 0;
                        for (int b = 0; b < ACCN; b++) t += par[h*ACCN + b];
                        for (int b = 0; b < ACCN; b++) par[h*ACCN + b] = (int32_t)t;
                    }
                }
                /* The oracles read the PUBLISHED partial array, not a local
                 * temporary.  That distinction is not pedantry: the first
                 * version checked the loop's own accumulator and mutation M7
                 * -- which corrupts `par` AFTER the loop -- survived every
                 * oracle.  An oracle that does not read what the file carries
                 * is checking a variable, not a result. */
                for (int h = 0; h < QH; h++)
                    for (int b = 0; b < ACCN; b++) {
                        int64_t s = par[h*ACCN + b];
                        /* ORACLE 1 -- double precision, no integer path.    */
                        {
                            double d = 0.0;
                            for (int t = 0; t < DT; t++)
                                d += (double)q[(size_t)h*N + b*DT + t]
                                   * (double)k[b*DT + t];
                            if (d != (double)s) o1++;
                        }
                        /* ORACLE 2 -- __int128, reverse order.             */
                        {
                            __int128 w = 0;
                            for (int t = DT-1; t >= 0; t--)
                                w += (__int128)q[(size_t)h*N + b*DT + t]
                                   * (__int128)k[b*DT + t];
                            if (w != (__int128)s) o2++;
                        }
                        /* ORACLE 3 -- the width bound attn_score_q12 needs. */
                        {
                            int64_t bound = (int64_t)DT
                                          * ((int64_t)1 << (QW-1))
                                          * ((int64_t)1 << (KW-1));
                            if (s > bound || s < -bound) o3++;
                        }
                    }

                /* ---- rescale then PV, in that order --------------------- */
                /* M6 swaps them.  The order is part of the numeric contract:
                 * a rescale belongs to the grid change the score at position p
                 * caused, so it must be applied to everything accumulated
                 * BEFORE p and never to p's own contribution. */
                for (int pass = 0; pass < 2; pass++) {
                    int do_now_rs = M6 ? (pass == 1) : (pass == 0);
                    if (do_now_rs) {
                        if (!do_rs) continue;
                        n_rs++;
                        for (int h = 0; h < QH; h++)
                            for (int i = 0; i < N; i++) {
                                size_t x = (size_t)h*N + i;
                                int64_t before = acc[x];
                                int sh = M8 ? QS+1 : QS;      /* MUTATION M8 */
                                int64_t r = round_shift(acc[x] * (int64_t)f[h], sh);
                                int ov = 0;
                                acc[x] = sat_acc(r, &ov);
                                n_ovr += ov;
                                /* ORACLE 5 -- exact identity at f = 2^Q.    */
                                if (f[h] == (1 << QS) && acc[x] != before) o5++;
                            }
                    } else {
                        for (int h = 0; h < QH; h++) {
                            int64_t ev = e[h];
                            if (M4 && ev >= 4096) ev -= 8192;  /* MUTATION M4 */
                            for (int b = 0; b < ACCN; b++)
                                for (int t = 0; t < DT; t++) {
                                    int64_t vv = v[b*DT + t];
                                    if (M5 && vv < 0) vv += 256; /* MUT M5 */
                                    size_t x = (size_t)h*N + b*DT + t;
                                    int ov = 0;
                                    acc[x] = sat_acc(acc[x] + ev*vv, &ov);
                                    n_ovr += ov;
                                }
                        }
                    }
                }

                /* ---- ORACLE 4: the independent replay ------------------- */
                {
                    if (do_rs) {
                        for (int h = 0; h < QH; h++)
                            for (int i = 0; i < N; i++) {
                                size_t x = (size_t)h*N + i;
                                __int128 num = (__int128)ac2[x] * (__int128)f[h]
                                             + ((__int128)1 << (QS-1));
                                __int128 den = (__int128)1 << QS;
                                __int128 qd  = num / den;
                                if (num % den != 0 && num < 0) qd -= 1;
                                __int128 hi = ((__int128)1 << (AW-1)) - 1;
                                __int128 lo = -((__int128)1 << (AW-1));
                                if (qd > hi) qd = hi;
                                if (qd < lo) qd = lo;
                                ac2[x] = (int64_t)qd;
                            }
                    }
                    for (int h = 0; h < QH; h++)
                        for (int i = 0; i < N; i++) {
                            size_t x = (size_t)h*N + i;
                            __int128 t = (__int128)ac2[x]
                                       + (__int128)e[h] * (__int128)v[i];
                            __int128 hi = ((__int128)1 << (AW-1)) - 1;
                            __int128 lo = -((__int128)1 << (AW-1));
                            if (t > hi) t = hi;
                            if (t < lo) t = lo;
                            ac2[x] = (int64_t)t;
                        }
                    for (int i = 0; i < (size_t)QH*N; i++)
                        if (ac2[i] != acc[i]) o4++;
                }

                if (!mutate) {
                    fprintf(fp, "%d %d\n", p, do_rs);   /* position, rescale? */
                    for (int i = 0; i < N; i++) fprintf(fp, "%d ", (int)k[i]);
                    fprintf(fp, "\n");
                    for (int h = 0; h < QH; h++)
                        for (int b = 0; b < ACCN; b++)
                            fprintf(fp, "%d ", (int)par[h*ACCN + b]);
                    fprintf(fp, "\n");
                    for (int h = 0; h < QH; h++) fprintf(fp, "%d ", (int)f[h]);
                    fprintf(fp, "\n");
                    for (int h = 0; h < QH; h++) fprintf(fp, "%d ", (int)e[h]);
                    fprintf(fp, "\n");
                    for (int i = 0; i < N; i++) fprintf(fp, "%d ", (int)v[i]);
                    fprintf(fp, "\n");
                }
            }

            if (!mutate) {
                for (int h = 0; h < QH; h++) {
                    for (int i = 0; i < N; i++)
                        fprintf(fp, "%.1f ", (double)acc[(size_t)h*N + i]);
                    fprintf(fp, "\n");
                }
            }
        }

        if (!mutate) {
            fclose(fp);
            printf("attn_mac_array_vec: %d cases, QH=%d DT=%d ACCN=%d NPOS=%d "
                   "-> %s\n", ncase, QH, DT, ACCN, NPOS, out);
            printf("  rescale passes %ld, accumulator saturations %ld\n",
                   n_rs, n_ovr);
            printf("  ORACLE 1 (double)      mismatches %ld\n", o1);
            printf("  ORACLE 2 (int128 rev)  mismatches %ld\n", o2);
            printf("  ORACLE 3 (width bound) violations %ld\n", o3);
            printf("  ORACLE 4 (replay/div)  mismatches %ld\n", o4);
            printf("  ORACLE 5 (f identity)  violations %ld\n", o5);
            if (o1|o2|o3|o4|o5) {
                printf("  REFERENCE DISAGREES WITH ITS OWN ORACLES\n");
                return 4;
            }
            printf("  all oracles agree\n");
        } else if (mut > 0) {
            long tot = o1+o2+o3+o4+o5;
            printf("  M%d %-34s %s  (O1=%ld O2=%ld O3=%ld O4=%ld O5=%ld)\n",
                   mut,
                   mut==1?"score tree drops last term":
                   mut==2?"rescale rounds half to zero":
                   mut==3?"rescale rounds half away from zero":
                   mut==4?"e read as signed 13-bit":
                   mut==5?"v read as unsigned":
                   mut==6?"rescale after PV, not before":
                   mut==7?"partials summed across blocks":
                          "rescale identity broken at f=2^Q",
                   tot ? "KILLED " : "SURVIVED",
                   o1,o2,o3,o4,o5);
        }
    }

    free(q); free(k); free(v); free(e); free(f);
    free(acc); free(ac2); free(par);
    return 0;
}
