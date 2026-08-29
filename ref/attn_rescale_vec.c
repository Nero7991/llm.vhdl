/* ref/attn_rescale_vec.c -- the C REFERENCE for subsystem C site 5d, the
 * softmax rescale multiply, and the golden generator for
 * sim/tb_attn_rescale.vhd.
 *
 *     o'[d] = round_shift(o[d] * f, 12)      -- half toward +infinity
 *
 * with o a signed ACC_W = 36 accumulator (spec 2.1.4 bounds |o| <= 2^30, the
 * extra bits are margin) and f an unsigned Q12 factor, f <= 4096 (spec 5c:
 * f = 4096 exactly at k = 0, f <= 3848 for k >= 1, f = 0 for k > 256).
 *
 * WHY THIS FILE EXISTS AT ALL, GIVEN THAT rtl/attn_rescale_skel.vhd IS A
 * PRICING SKELETON AND NOT AN IMPLEMENTATION.  The skeleton's whole purpose is
 * to find out whether a shared rescale unit can be built in ONE DSP48E2
 * instead of two.  The only way it can be is by splitting the 36-bit operand
 * into two chunks and making two passes through one tile.  That decomposition
 * is ARITHMETIC I am introducing, it is not in the spec, and it is exactly the
 * kind of thing that is easy to get wrong in the sign handling -- and a
 * skeleton that synthesises to 1 DSP while computing the wrong function
 * reports a number for a structure nobody can build.  So the chunked form has
 * to be proved bit-identical to the direct product BEFORE its DSP count means
 * anything.  That proof is what this file and its testbench are for.
 *
 * THE INDEPENDENT-ORACLE QUESTION, ANSWERED BEFORE THE SKELETON WAS WRITTEN.
 * The double oracle here is not strained, it is unusually clean:
 *
 *   - |o*f| <= 2^35 * 2^12 = 2^47 < 2^53, so an IEEE754 double holds the
 *     product EXACTLY.  ORACLE 1 computes it in double and demands exact
 *     equality with the int64 product.  Binary64 multiplication and int64
 *     multiplication share no machinery whatsoever.
 *   - a rotation-free identity exists at f = 4096: the rescale is o' = o
 *     EXACTLY (spec 3.1).  ORACLE 3 checks it with no arithmetic at all.
 *   - MONOTONICITY in o at fixed f is a property of the map, not a replay of
 *     it (ORACLE 8).
 *
 * That is the opposite of attn_qk_norm, twice declined because the only
 * available check there was a replay of the same algorithm.
 *
 * EIGHT ORACLES:
 *
 *   ORACLE 1, THE PRODUCT IN EXACT DOUBLE.  Stated above.  Exact equality, no
 *     tolerance, because the product is exactly representable.
 *
 *   ORACLE 2, THE ROUNDED RESULT IN EXACT DOUBLE.  p + 2048 is <= 2^47 + 2^11,
 *     still exact, so floor((p + 2048)/4096) is computed in double with floor()
 *     and compared for exact equality.  This checks the SHIFT independently of
 *     mv4i_round_shift's integer division.
 *
 *   ORACLE 3, f = 4096 IS THE IDENTITY, exactly.  y == o with no slack.  This
 *     is spec 3.1's own identity and it is the one check that involves no
 *     fixed-point machinery on either side.
 *
 *   ORACLE 4, f = 0 GIVES 0, exactly.  round_shift(0, 12) = floor(2048/4096)
 *     = 0.  Cheap, and it pins the underflow branch that spec 5c reaches
 *     whenever k > 256.
 *
 *   ORACLE 5, THE CHUNK IDENTITY -- the one that protects the skeleton.  With
 *     SPLIT = 17,
 *         a_hi = o >> 17 (ARITHMETIC, sign-propagating),   19 bits signed
 *         a_lo = o & (2^17 - 1),                           17 bits unsigned
 *     the reference asserts BOTH
 *         o           == a_hi * 2^17 + a_lo
 *         o * f       == (a_hi * f) * 2^17 + (a_lo * f)
 *     exactly, for every case.  The second is the identity the two-pass
 *     structure rests on.  It is stated here, in the reference, mutation-tested
 *     here, and only then used by the RTL.  Note a_lo is UNSIGNED: taking it
 *     signed is the classic error and ORACLE 5 is what catches it.
 *
 *   ORACLE 6, THE ROUNDING MODE, as an INEQUALITY no magnitude bound can see.
 *     round_shift is half toward PLUS INFINITY.  On an exact tie -- p congruent
 *     to 2048 modulo 4096 -- half-toward-+inf, half-away-from-zero and
 *     half-to-even give three different answers for NEGATIVE p.  Ties of both
 *     signs are planted deliberately (see the shape list) and the oracle
 *     demands the +infinity answer.  A tolerance of even one LSB would admit
 *     all three.
 *
 *   ORACLE 7, THE RANGE, which is what licenses having no saturation logic.
 *     |o| <= 2^(ACC_W-1) and f <= 4096 give |y| <= 2^(ACC_W-1), so the result
 *     always fits the accumulator it is written back to.  Checked on every
 *     case rather than argued.
 *
 *   ORACLE 9, BOTH CHUNKS FIT A DSP48E2 PORT.  27x18 signed.  This is the
 *     oracle that licenses the "1 DSP" claim itself: a split that recombines
 *     perfectly but produces a 30-bit chunk still needs two tiles, and no
 *     recombination oracle can see that.  Stated against the PART.
 *
 *   ORACLE 8, MONOTONICITY.  f >= 0, so o1 <= o2 implies y1 <= y2.  Checked by
 *     sorting each fixed-f family.  A property of the map; a sign error in the
 *     chunking breaks it while leaving individual magnitudes plausible.
 *
 * COVERAGE ASSERTIONS FAIL, THEY DO NOT WARN, and they are written against the
 * two failure modes that actually threaten this file.  The first is the
 * constant-subject trap: a field that never varies makes every check on it a
 * comment.  The second is newer and subtler -- two values agreeing at a single
 * point is a coincidence, not an agreement -- so every structural identity
 * here is required to hold at SEVERAL points of each kind, not one: at least
 * two negative o with a non-zero low chunk, at least two exact ties of each
 * sign, and at least two o on each side of the chunk boundary.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

#define ATTN_RS_ACC_W  36
#define ATTN_RS_F_W    13
#define ATTN_RS_RSH    12
#define ATTN_RS_SPLIT  17
#define ATTN_RS_FONE   4096          /* the identity factor, spec 5c k = 0 */

/* The oracle's own copies.  Deliberately separate #defines: a mutation of the
 * recipe must not silently move the check with it. */
#define ATTN_RS_RSH_ORACLE   12
#define ATTN_RS_SPLIT_ORACLE 17

static int64_t attn_rescale(int64_t o, int64_t f)
{
    return mv4i_round_shift(o * f, ATTN_RS_RSH);
}

#ifndef ATTN_RESCALE_INCLUDE

static uint64_t rs = 0x5eed5eedULL;
static uint64_t rnd(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return rs; }

/* A value that is representable in ACC_W bits, two's complement. */
static int64_t clamp_acc(int64_t v)
{
    int64_t lim = (int64_t)1 << (ATTN_RS_ACC_W - 1);
    while (v >=  lim) v -= (lim << 1);
    while (v <  -lim) v += (lim << 1);
    return v;
}

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_rescale_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 512;
    rs = vec_seed(argc, argv, 3, 0x5eed5eedULL);

    int64_t *ov = malloc(sizeof(int64_t) * (size_t)ncase);
    int64_t *fv = malloc(sizeof(int64_t) * (size_t)ncase);
    int64_t *yv = malloc(sizeof(int64_t) * (size_t)ncase);
    if (!ov || !fv || !yv) return 1;

    const int64_t ACC_LIM = (int64_t)1 << (ATTN_RS_ACC_W - 1);
    const int64_t SPBIT   = (int64_t)1 << ATTN_RS_SPLIT;
    const int64_t SPMASK  = SPBIT - 1;

    /* ---- the stimulus -------------------------------------------------
     * Shaped, not sampled.  The three things that can break the chunked
     * product are the SIGN of o, whether the low chunk is non-zero, and
     * whether the low partial CARRIES into the high one.  Random operands hit
     * the first two and essentially never hit an exact rounding tie, so the
     * ties are planted. */
    for (int c = 0; c < ncase; c++) {
        int64_t o, f;
        /* OFFSET BY TWO, and it is load-bearing.  The two o = 0 shapes must
         * not land at cases 0 and 1: a consumer's pipeline flushes ZEROS from
         * its reset state, and a golden whose first entries are also zero
         * cannot distinguish "the pipeline had no fill" from "the fill
         * coincided with the golden".  sim/tb_attn_rescale.vhd hit exactly
         * that and passed two cases it had never actually checked.  Two values
         * agreeing is not agreement. */
        int shape = (c + 2) % 16;
        switch (shape) {
        case 0:  o = 0;                              f = ATTN_RS_FONE; break;
        case 1:  o = 0;                              f = 0;            break;
        /* the chunk boundary, both sides, both signs -- more than one of each
         * so ORACLE 5 cannot pass on a coincidence */
        case 2:  o =  SPBIT - 1;                     f = 3848;         break;
        case 3:  o =  SPBIT;                         f = 3848;         break;
        case 4:  o = -SPBIT + 1;                     f = 3847;         break;
        case 5:  o = -SPBIT;                         f = 3847;         break;
        case 6:  o =  SPBIT + 1;                     f = 1;            break;
        case 7:  o = -SPBIT - 1;                     f = 1;            break;
        /* negative with a NON-ZERO low chunk: the case where taking a_lo
         * signed instead of unsigned gives the wrong answer */
        case 8:  o = -(int64_t)((rnd() % (uint64_t)ACC_LIM) | 1u);
                 f = (int64_t)(rnd() % 4097u);                         break;
        case 9:  o = -((int64_t)3 * SPBIT + 12345);  f = 2731;         break;
        /* the accumulator rails, which the DECLARED width must survive even
         * though spec 2.1.4 bounds the live range at 2^30 */
        case 10: o =  ACC_LIM - 1;                   f = ATTN_RS_FONE; break;
        case 11: o = -ACC_LIM;                       f = ATTN_RS_FONE; break;
        /* the spec's live bound, both signs */
        case 12: o =  ((int64_t)1 << 30) - 1;        f = 3848;         break;
        case 13: o = -((int64_t)1 << 30);            f = 3848;         break;
        default: o = clamp_acc((int64_t)(rnd() % (uint64_t)(ACC_LIM*2)) - ACC_LIM);
                 f = (int64_t)(rnd() % 4097u);                         break;
        }

        /* PLANT EXACT ROUNDING TIES, both signs, several of each.  An exact tie
         * needs o*f congruent to 2^11 modulo 2^12.  With f odd, choosing
         * o = t * inverse(f) mod 2^12 lands one; f = 1 is the easy carrier and
         * is used so the tie is exact by construction rather than by search. */
        if (shape == 14 || shape == 15) {
            f = 1;
            /* p = o*1 = o, so a tie is exactly o congruent to 2048 modulo
             * 4096.  Both signs are built by CONSTRUCTION from a multiple of
             * 4096 rather than by reducing, because C's % truncates toward
             * zero and would give the wrong residue on the negative side.
             *
             * The first version added a random positive multiple of 4096 to a
             * negative base of -2^20.  With the multiplier reaching 2^12 the
             * sum overwhelmed the base and every "negative" tie came out
             * POSITIVE -- 64 positive ties and zero negative ones.  The
             * coverage assertion caught it, which is the entire reason it is
             * an assertion and not a printed count. */
            int64_t k = (int64_t)(rnd() % (1u << 20));
            if (shape == 14) o =  (k + 1) * 4096 + 2048;
            else             o = -((k + 1) * 4096) + 2048;
            o = clamp_acc(o);
        }

        ov[c] = o; fv[c] = f; yv[c] = attn_rescale(o, f);
    }

    /* ================= THE ORACLES ================= */
    long n1=0,n2=0,n3=0,n4=0,n5=0,n6=0,n7=0,n8=0,n9=0;
    long n_tie_pos=0, n_tie_neg=0, n_negloe=0, n_hi_set=0, n_hi_clr=0;
    long n_carry=0, n_fone=0, n_fzero=0, n_rail=0;
    long n_opos=0, n_oneg=0, n_ozero=0;

    for (int c = 0; c < ncase; c++) {
        int64_t o = ov[c], f = fv[c], y = yv[c], p = o * f;

        /* ---- ORACLE 1: the product, in EXACT double ---------------------- */
        double pd = (double)o * (double)f;
        if (pd != (double)p) {
            if (n1 < 8) fprintf(stderr,
                "  FAIL oracle 1: case %d -- o %lld f %lld, int64 product %lld "
                "but the exact double product is %.1f\n",
                c, (long long)o, (long long)f, (long long)p, pd);
            n1++;
        }

        /* ---- ORACLE 2: the rounded result, in EXACT double ---------------- */
        double yd = floor((pd + (double)(1 << (ATTN_RS_RSH_ORACLE-1)))
                          / (double)((int64_t)1 << ATTN_RS_RSH_ORACLE));
        if (yd != (double)y) {
            if (n2 < 8) fprintf(stderr,
                "  FAIL oracle 2: case %d -- y %lld but floor((p + 2^%d)/2^%d) "
                "in exact double is %.1f\n",
                c, (long long)y, ATTN_RS_RSH_ORACLE-1, ATTN_RS_RSH_ORACLE, yd);
            n2++;
        }

        /* ---- ORACLE 3: f = 4096 is the IDENTITY, exactly ------------------ */
        if (f == ATTN_RS_FONE) {
            n_fone++;
            if (y != o) {
                if (n3 < 8) fprintf(stderr,
                    "  FAIL oracle 3: case %d -- f = 4096 must be the identity, "
                    "o %lld but y %lld\n", c, (long long)o, (long long)y);
                n3++;
            }
        }

        /* ---- ORACLE 4: f = 0 gives 0, exactly ---------------------------- */
        if (f == 0) {
            n_fzero++;
            if (y != 0) {
                if (n4 < 8) fprintf(stderr,
                    "  FAIL oracle 4: case %d -- f = 0 must give 0, got %lld\n",
                    c, (long long)y);
                n4++;
            }
        }

        /* ---- ORACLE 5: THE CHUNK IDENTITY, both forms --------------------- */
        {
            int64_t a_hi = o >> ATTN_RS_SPLIT_ORACLE;      /* arithmetic */
            int64_t a_lo = o & ((((int64_t)1) << ATTN_RS_SPLIT_ORACLE) - 1);
            int64_t rec  = a_hi * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE) + a_lo;
            int64_t prec = (a_hi * f) * (((int64_t)1) << ATTN_RS_SPLIT_ORACLE)
                         + (a_lo * f);
            /* THE WIDTHS, and they are not decoration.  int64 arithmetic
             * WRAPS modulo 2^64, and ((uint64_t)o >> 17) << 17 is bit-identical
             * to o with its low 17 bits cleared -- so the recombination above
             * gives back o EXACTLY even when a_hi was produced by a LOGICAL
             * shift that destroyed the sign.  Mutation S6 proved this: it
             * survived every equality here.  The RTL has no 64-bit wraparound
             * to rescue it -- a_hi is a HI_W-bit signal -- so the property that
             * actually transfers is that each chunk FITS the width the RTL
             * declares for it.  Checking the ranges is what closes that gap.  */
            int64_t hi_lim = ((int64_t)1) << (ATTN_RS_ACC_W - ATTN_RS_SPLIT_ORACLE);
            int64_t lo_lim = ((int64_t)1) << ATTN_RS_SPLIT_ORACLE;
            int bad_w = (a_hi >= hi_lim || a_hi < -hi_lim
                         || a_lo < 0 || a_lo >= lo_lim);
            if (bad_w) {
                if (n5 < 8) fprintf(stderr,
                    "  FAIL oracle 5: case %d -- o %lld splits to hi %lld "
                    "(must fit %d signed bits) lo %lld (must fit %d unsigned "
                    "bits); the recombination can still be exact because int64 "
                    "wraps, but the RTL's narrow signals will not\n",
                    c, (long long)o, (long long)a_hi,
                    ATTN_RS_ACC_W - ATTN_RS_SPLIT_ORACLE + 1,
                    (long long)a_lo, ATTN_RS_SPLIT_ORACLE);
                n5++;
            }
            if (rec != o || prec != p) {
                if (n5 < 8) fprintf(stderr,
                    "  FAIL oracle 5: case %d -- o %lld splits to hi %lld lo "
                    "%lld, recombining gives %lld and the chunked product "
                    "gives %lld against %lld\n",
                    c, (long long)o, (long long)a_hi, (long long)a_lo,
                    (long long)rec, (long long)prec, (long long)p);
                n5++;
            }
            if (a_lo != 0 && o < 0) n_negloe++;
            if ((o >> ATTN_RS_SPLIT_ORACLE) != 0) n_hi_set++; else n_hi_clr++;
            /* a CARRY out of the low partial into the high one: the low
             * partial exceeds the split, so the recombination is not a plain
             * concatenation and a fabric adder is genuinely required. */
            if (a_lo * f >= (((int64_t)1) << ATTN_RS_SPLIT_ORACLE)) n_carry++;
        }

        /* ---- ORACLE 6: the ROUNDING MODE on an exact tie ------------------ */
        {
            int64_t m = p & ((((int64_t)1) << ATTN_RS_RSH_ORACLE) - 1);
            if (m == (((int64_t)1) << (ATTN_RS_RSH_ORACLE-1))) {
                if (p >= 0) n_tie_pos++; else n_tie_neg++;
                /* half toward +infinity, stated without reusing round_shift */
                int64_t up = (p + (((int64_t)1) << (ATTN_RS_RSH_ORACLE-1)))
                           / (((int64_t)1) << ATTN_RS_RSH_ORACLE);
                /* p + 2048 is an exact multiple of 4096 on a tie, so C's
                 * truncating division is exact here and the mode is pinned
                 * without borrowing mv4i_floor_shr. */
                if (y != up) {
                    if (n6 < 8) fprintf(stderr,
                        "  FAIL oracle 6: case %d -- exact tie at p %lld, half "
                        "toward +infinity is %lld but y is %lld\n",
                        c, (long long)p, (long long)up, (long long)y);
                    n6++;
                }
            }
        }

        /* ---- ORACLE 7: the RANGE, which licenses no saturation ------------ */
        if (y >= ACC_LIM || y < -ACC_LIM) {
            if (n7 < 8) fprintf(stderr,
                "  FAIL oracle 7: case %d -- y %lld does not fit ACC_W = %d, "
                "so the write-back would need saturation logic the skeleton "
                "does not price\n", c, (long long)y, ATTN_RS_ACC_W);
            n7++;
        }

        /* ---- ORACLE 9: BOTH CHUNKS FIT A DSP48E2 OPERAND PORT ------------
         * This is the oracle that licenses the whole "1 DSP" claim.  A
         * DSP48E2 multiplier is 27x18 signed.  The two-pass structure is only
         * worth anything if EACH partial product fits ONE tile, so each chunk
         * must fit the 27-bit A port while f fits the 18-bit B port.  Stated
         * against the part, not against the split: a split of 30 recombines
         * perfectly and still needs two tiles, so the recombination oracles
         * cannot see it. */
        {
            int hi_w = ATTN_RS_ACC_W - ATTN_RS_SPLIT_ORACLE + 1; /* signed */
            int lo_w = ATTN_RS_SPLIT_ORACLE + 1;                 /* + sign bit */
            int f_w  = ATTN_RS_F_W + 1;                          /* + sign bit */
            if (hi_w > 27 || lo_w > 27 || f_w > 18) {
                if (n9 < 4) fprintf(stderr,
                    "  FAIL oracle 9: the split gives a %d-bit high chunk and a "
                    "%d-bit low chunk against the DSP48E2's 27-bit A port, with "
                    "f at %d bits against the 18-bit B port -- a partial product "
                    "does not fit one tile, so the two-pass structure buys "
                    "nothing\n", hi_w, lo_w, f_w);
                n9++;
            }
        }

        if (o > 0) n_opos++; else if (o < 0) n_oneg++; else n_ozero++;
        if (o == ACC_LIM-1 || o == -ACC_LIM) n_rail++;
    }

    /* ---- ORACLE 8: MONOTONICITY in o at fixed f ------------------------- */
    for (int c = 0; c < ncase; c++) {
        for (int d = c+1; d < ncase; d++) {
            if (fv[c] != fv[d]) continue;
            int64_t olo = ov[c], ylo = yv[c], ohi = ov[d], yhi = yv[d];
            if (olo > ohi) { int64_t t;
                             t=olo; olo=ohi; ohi=t; t=ylo; ylo=yhi; yhi=t; }
            if (olo < ohi && ylo > yhi) {
                if (n8 < 8) fprintf(stderr,
                    "  FAIL oracle 8: monotonicity broken at f %lld -- o %lld "
                    "gives %lld but the larger o %lld gives %lld\n",
                    (long long)fv[c], (long long)olo, (long long)ylo,
                    (long long)ohi, (long long)yhi);
                n8++;
            }
        }
    }

    /* ================= THE VECTORS ================= */
    FILE *fp = fopen(out, "w");
    if (!fp) { perror(out); return 1; }
    fprintf(fp, "%d %d %d %d %d\n", ncase, ATTN_RS_ACC_W, ATTN_RS_F_W,
            ATTN_RS_RSH, ATTN_RS_SPLIT);
    for (int c = 0; c < ncase; c++)
        fprintf(fp, "%016llx %d %016llx\n",
                (unsigned long long)(uint64_t)ov[c], (int)fv[c],
                (unsigned long long)(uint64_t)yv[c]);
    fclose(fp);

    fprintf(stderr, "attn_rescale_vec: %d cases -> %s\n", ncase, out);
    fprintf(stderr, "  o neg %ld pos %ld zero %ld, at an ACC_W rail %ld\n",
            n_oneg, n_opos, n_ozero, n_rail);
    fprintf(stderr, "  high chunk non-zero %ld, zero %ld; negative o with a "
            "non-zero low chunk %ld; low partial carries %ld\n",
            n_hi_set, n_hi_clr, n_negloe, n_carry);
    fprintf(stderr, "  exact ties: positive %ld negative %ld; f = 4096 cases "
            "%ld, f = 0 cases %ld\n", n_tie_pos, n_tie_neg, n_fone, n_fzero);

    /* ============ COVERAGE.  THESE FAIL, THEY DO NOT WARN ============ */
    int bad = 0;
#define COV(cond, msg) \
    do { if (!(cond)) { fprintf(stderr, "  COVERAGE HOLE: %s\n", msg); bad=1; } } while (0)

    /* The constant-subject trap: a field that never varies makes every check
     * on it a comment. */
    COV(n_opos > 0 && n_oneg > 0 && n_ozero > 0,
        "o does not take all three signs, so the sign handling in the chunk "
        "split is not exercised");
    COV(n_fone > 0 && n_fzero > 0,
        "f never reaches both 4096 and 0, so ORACLE 3 or ORACLE 4 is vacuous");
    /* The newer trap: two values agreeing once is a coincidence, not an
     * agreement.  Every structural identity must hold at SEVERAL points of
     * each kind. */
    COV(n_negloe >= 2,
        "fewer than TWO negative o with a non-zero low chunk -- the case that "
        "separates an unsigned low chunk from a signed one.  One instance "
        "could agree by coincidence");
    COV(n_hi_set >= 2 && n_hi_clr >= 2,
        "fewer than TWO o on one side of the chunk boundary, so ORACLE 5 could "
        "be passing on a single coincidence rather than on the identity");
    COV(n_tie_pos >= 2 && n_tie_neg >= 2,
        "fewer than TWO exact rounding ties of each sign -- ORACLE 6 is the "
        "only check that separates half-toward-+infinity from half-away-from-"
        "zero and half-to-even, and it needs negative ties to do it");
    COV(n_carry >= 2,
        "the low partial never carries past the split in at least two cases, "
        "so the fabric adder the two-pass structure needs is unexercised and "
        "a concatenation would pass");
    COV(n_rail > 0,
        "no case sits at an ACC_W rail, so the declared width is untested");
    COV(yv[0] != 0 && yv[1] != 0,
        "case 0 or case 1 has y = 0, which is also what a consumer's pipeline "
        "flushes out of its reset registers -- the leading golden entries must "
        "be distinguishable from a zeroed pipeline or the consumer cannot tell "
        "its fill apart from real results");
#undef COV

    long nf = n1+n2+n3+n4+n5+n6+n7+n8+n9;
    if (nf) {
        fprintf(stderr, "  ORACLE FAIL: 1:%ld 2:%ld 3:%ld 4:%ld 5:%ld 6:%ld "
                "7:%ld 8:%ld 9:%ld\n", n1,n2,n3,n4,n5,n6,n7,n8,n9);
        return 1;
    }
    if (bad) return 1;
    fprintf(stderr, "  OK: the product and its rounding match an EXACT double "
            "computation, f = 4096 is the identity and f = 0 gives zero, the "
            "17-bit chunk split recombines exactly in both the operand and the "
            "product, exact ties round toward +infinity, every result fits "
            "ACC_W, the map is monotone in o at fixed f, and both chunks fit "
            "a single DSP48E2 operand port\n");
    return 0;
}
#endif
