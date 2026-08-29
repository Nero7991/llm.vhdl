/* ref/attn_recip_vec.c -- vectors and golden for rtl/attn_recip.vhd.
 *
 * Subsystem C, step 8a: turn the online softmax's denominator into a
 * multiplicative reciprocal, one query head at a time on one shared divider.
 *
 *     p = msb_pos(s)                    msb_pos(0) = 0, NORMATIVE
 *     r = floor( 2^(p + R_Q) / s )      R_Q = 15
 *
 * and the consumer (site 6b, attn_gate) then computes
 *
 *     t[d] = round_shift( o[d] * r, p + 1 )
 *
 * which is o/s expressed in Q(R_Q - 1) = Q14.
 *
 * WHY p IS NOT A FREE PARAMETER, and why the pair (p, r) travels together.
 * 2^p <= s < 2^(p+1) by the definition of msb_pos, so 2^(p+R_Q)/s lies in
 * (2^(R_Q-1), 2^R_Q] and therefore r lies in [2^(R_Q-1), 2^R_Q] -- a 16-bit
 * unsigned, with the top value 2^15 reached exactly when s is a power of two.
 * That is the whole reason for normalising by p rather than dividing by a
 * fixed power: it pins the reciprocal to a KNOWN 15-bit window whatever s is,
 * so the downstream multiply is 24 x 16 and fits one DSP48E2 tile, and it
 * bounds the relative error at 2^-14 uniformly.  A fixed numerator would give
 * a reciprocal whose width varies with the context length.
 *
 * WHY IT IS A DIVIDE AND NOT A RECIPROCAL LUT.  rtl/divider_rs.vhd exists
 * because Vivado's `/` produced WRONG quotients on silicon in this design
 * while every operand was bit-perfect (see that file's header for the measured
 * numbers).  A LUT-plus-Newton reciprocal would be an approximation whose
 * error would have to be re-derived here; the restoring divider is exact,
 * costs 0 DSP, and runs once per query head per layer -- 12 x 16 = 192 divides
 * per token per card, against a NW-cycle divide, which is under 9,000 cycles
 * of a 1.3-million-cycle subsystem.  There is no throughput case for anything
 * cleverer.
 *
 * s = 0 IS UNREACHABLE, AND IS HANDLED ANYWAY.  attn_softmax snaps its running
 * maximum UP to the grid, so the largest score's own z lies in
 * [-(2^GRID_SH - 1), 0] and its weight is at least exp(-255/4096)*4096 = 3849.
 * So s >= 3849 for any head with at least one position, and p >= 11.  A zero s
 * would make divider_rs produce unspecified-but-bounded garbage (its own header
 * says so), which is exactly the kind of silent value this project has been
 * bitten by, so it is trapped and flagged rather than divided.
 *
 * DOUBLE ORACLE, four checks, and ORACLE 1 never performs a division:
 *
 *   ORACLE 1, the floor, checked by MULTIPLICATION.  r = floor(N/s) if and
 *     only if  r*s <= N < (r+1)*s.  Both products are exact in int64
 *     (r <= 2^15, s < 2^26, so r*s < 2^41), and the check shares no code with
 *     the divider, no rounding rule, and no shift.  Checking a division by
 *     dividing again in double would be the restatement trap
 *     attn_score_q12_vec.c's ORACLE 2 note describes; this cannot be.
 *
 *   ORACLE 2, the RANGE, which is what the u16 declaration rests on.
 *     2^p <= s < 2^(p+1) and 2^(R_Q-1) <= r <= 2^R_Q, as exact inequalities.
 *     A p one too small makes r overflow 16 bits; a p one too large halves the
 *     precision.  Neither shows up as a wrong VALUE anywhere -- the pair is
 *     self-consistent either way -- which is why the range is checked directly.
 *
 *   ORACLE 3, the reciprocal against double.  0 <= 1/s - r/2^(p+R_Q) <
 *     2^-(p+R_Q), computed with 1.0/s and ldexp and nothing else.  It is
 *     ONE-SIDED on purpose: floor rounds toward zero, so the fixed-point
 *     reciprocal must never EXCEED the true one.  A round-to-nearest divider
 *     violates the lower half while staying inside any magnitude tolerance --
 *     the same shape as attn_score_q12's ORACLE 3.
 *
 *   ORACLE 4, what the pair is FOR.  The consumer's t = round_shift(o*r, p+1)
 *     must match o*2^(R_Q-1)/s in double within a DERIVED bound:
 *     |o|/2^(p+1) from the reciprocal's own floor, plus 0.5 for the round.
 *     This is the only check that would catch a (p, r) pair that is internally
 *     consistent but scaled wrong, e.g. R_Q off by one with the shift moved to
 *     match.  The o values are generated for this oracle and are deliberately
 *     NOT emitted to the vector file: attn_recip does not compute t, attn_gate
 *     does, and a golden for a value the unit does not produce would be a
 *     claim about the wrong unit.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_recip_vec attn_recip_vec.c -lm
 * Usage: ./attn_recip_vec [out.txt] [ncase] [nhead]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_RC_R_Q  15     /* the numerator's exponent above p, C spec 8   */
#define ATTN_RC_S_W  26     /* the denominator's declared width             */
#define ATTN_RC_R_W  16     /* the reciprocal's declared width              */

/* Restated independently for the oracles.  See attn_score_q12_vec.c's ORACLE 2
 * note: a constant shared between the thing under test and the thing testing it
 * is not a check, it is a restatement.  A mutation of ATTN_RC_R_Q must not move
 * the golden with the path. */
#define ATTN_RC_R_Q_ORACLE 15

typedef struct {
    int     p;
    int32_t r;
    int     zero;   /* s was 0: unreachable, trapped rather than divided */
    int     ovr;    /* r left the R_W field: unreachable, a width guard  */
} attn_recip_t;

static void attn_recip(uint64_t s, attn_recip_t *o)
{
    o->zero = 0; o->ovr = 0;
    if (s == 0) {
        /* msb_pos(0) = 0 would give r = floor(2^15 / 0).  Trapped. */
        o->zero = 1; o->p = 0; o->r = 0;
        return;
    }
    o->p = mv4i_msb_pos_u(s);
    uint64_t num = (uint64_t)1 << (o->p + ATTN_RC_R_Q);
    uint64_t q   = num / s;                 /* exact floor; both are exact */
    if (q > ((uint64_t)1 << ATTN_RC_R_W) - 1) {
        q = ((uint64_t)1 << ATTN_RC_R_W) - 1;
        o->ovr = 1;                          /* unreachable; see ORACLE 2 */
    }
    o->r = (int32_t)q;
}

#ifndef ATTN_RECIP_INCLUDE

static uint64_t rs = 20260830ULL;
static uint32_t rnd32(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

#define MAXHEAD 32

/* The smallest denominator attn_softmax can produce for a head with at least
 * one position: the largest score's own z is in [-(2^8 - 1), 0], so its weight
 * is at least round(exp(-255/4096) * 4096) = 3849. */
#define S_MIN_REACHABLE 3849u
#define S_MAX_DECLARED  ((1u << ATTN_RC_S_W) - 1u)

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_recip_vec.txt";
    int ncase = (argc > 2) ? atoi(argv[2]) : 24;
    int nhead = (argc > 3) ? atoi(argv[3]) : 12;   /* 12 query heads per card */
    rs = vec_seed(argc, argv, 4, 20260830ULL);
    if (nhead > MAXHEAD) nhead = MAXHEAD;

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d\n", ncase, nhead,
            ATTN_RC_S_W, ATTN_RC_R_W, ATTN_RC_R_Q);

    long n_o1 = 0, n_o2 = 0, n_o3 = 0, n_o4 = 0;
    double worst4 = 0.0; int worst4_c = -1;
    long n_pow2 = 0, n_exact = 0, n_inexact = 0, n_rmax = 0, n_rmin = 0;
    long n_pmin = 0, n_pmax = 0;
    int p_lo = 99, p_hi = -1;

    for (int c = 0; c < ncase; c++) {
        uint32_t sv[MAXHEAD];
        for (int h = 0; h < nhead; h++) {
            /* Shapes, chosen for what is easy to get wrong:
             *  0  s exactly 2^p        -- r = 2^R_Q exactly, the TOP of the u16
             *                             range and the only value that needs
             *                             the 16th bit.  A unit that declared
             *                             r as 15 bits passes everything else
             *  1  s = 2^p + 1          -- r one step below the top
             *  2  s = 2^(p+1) - 1      -- r at the BOTTOM, 2^(R_Q-1), where a
             *                             p one too large would overflow
             *  3  s = the smallest s   -- the value attn_softmax actually
             *     attn_softmax can       floors at, and the p = 11 end
             *     produce
             *  4  s = the declared max -- the p = S_W-1 end, which is what the
             *                             divider's NW width is sized on
             *  5  s = 3 * 2^(p-1)      -- an exact division, remainder 0, so
             *                             the floor is a no-op and a unit that
             *                             rounds instead still passes
             *  else random over the reachable range
             */
            int shape = (h < 6) ? h : (int)(rnd32() % 6u);
            int p = 11 + (int)(rnd32() % (uint32_t)(ATTN_RC_S_W - 12));
            uint32_t s;
            switch (shape) {
            case 0: s = 1u << p; break;
            case 1: s = (1u << p) + 1u; break;
            case 2: s = (1u << (p + 1)) - 1u; break;
            case 3: s = S_MIN_REACHABLE; break;
            case 4: s = S_MAX_DECLARED; break;
            case 5: s = 3u << (p - 1); break;
            default:
                s = (1u << p) | (rnd32() & ((1u << p) - 1u));
                break;
            }
            if (s < S_MIN_REACHABLE) s = S_MIN_REACHABLE;
            if (s > S_MAX_DECLARED)  s = S_MAX_DECLARED;
            sv[h] = s;
        }

        for (int h = 0; h < nhead; h++) {
            attn_recip_t r;
            uint64_t s = sv[h];
            attn_recip(s, &r);

            uint64_t N = (uint64_t)1 << (r.p + ATTN_RC_R_Q_ORACLE);

            /* ---- ORACLE 1: the floor, by MULTIPLICATION only ------------- */
            if (!((uint64_t)r.r * s <= N && N < ((uint64_t)r.r + 1) * s)) {
                if (n_o1 < 8) fprintf(stderr,
                    "  FAIL oracle 1: case %d head %d s %llu r %d p %d -- "
                    "r*s = %llu, N = %llu, (r+1)*s = %llu; r is not floor(N/s)\n",
                    c, h, (unsigned long long)s, r.r, r.p,
                    (unsigned long long)((uint64_t)r.r * s),
                    (unsigned long long)N,
                    (unsigned long long)(((uint64_t)r.r + 1) * s));
                n_o1++;
            }

            /* ---- ORACLE 2: the range the u16 declaration rests on -------- */
            if (!(((uint64_t)1 << r.p) <= s && s < ((uint64_t)1 << (r.p + 1)))) {
                if (n_o2 < 8) fprintf(stderr,
                    "  FAIL oracle 2: case %d head %d p %d does not bracket "
                    "s %llu\n", c, h, r.p, (unsigned long long)s);
                n_o2++;
            }
            if (!(r.r >= (1 << (ATTN_RC_R_Q_ORACLE - 1))
                  && r.r <= (1 << ATTN_RC_R_Q_ORACLE))) {
                if (n_o2 < 8) fprintf(stderr,
                    "  FAIL oracle 2: case %d head %d r %d is outside "
                    "[2^%d, 2^%d]\n", c, h, r.r,
                    ATTN_RC_R_Q_ORACLE - 1, ATTN_RC_R_Q_ORACLE);
                n_o2++;
            }
            if (r.ovr) {
                fprintf(stderr, "  FAIL: case %d head %d saturated r, which "
                                "oracle 2 says is unreachable\n", c, h);
                n_o2++;
            }

            /* ---- ORACLE 3: the reciprocal against double, ONE-SIDED ------ */
            {
                double approx = ldexp((double)r.r, -(r.p + ATTN_RC_R_Q_ORACLE));
                double truth  = 1.0 / (double)s;
                double slack  = ldexp(1.0, -(r.p + ATTN_RC_R_Q_ORACLE));
                if (approx > truth + 1e-18 || approx < truth - slack) {
                    if (n_o3 < 8) fprintf(stderr,
                        "  FAIL oracle 3: case %d head %d r/2^(p+%d) = %.17g is "
                        "not in (1/s - 2^-(p+%d), 1/s] = (%.17g, %.17g]\n",
                        c, h, ATTN_RC_R_Q_ORACLE, approx, ATTN_RC_R_Q_ORACLE,
                        truth - slack, truth);
                    n_o3++;
                }
            }

            /* ---- ORACLE 4: what the pair is FOR -------------------------- */
            for (int t = 0; t < 6; t++) {
                /* |o| <= 2^30 is the C spec's accumulator bound:
                 * 2^11 positions x 2^12 weight x 2^7 mantissa. */
                int64_t o = (int64_t)(rnd32() & 0x3FFFFFFFu);
                if (t & 1) o = -o;
                if (t == 4) o = 0;
                if (t == 5) o = (int64_t)1 << 30;
                int64_t tv = mv4i_round_shift(o * (int64_t)r.r, r.p + 1);
                double  tr = ldexp((double)o, ATTN_RC_R_Q_ORACLE - 1)
                             / (double)s;
                double  bnd = ldexp(fabs((double)o), -(r.p + 1)) + 0.5;
                double  e   = fabs((double)tv - tr);
                double  ratio = e / bnd;
                if (ratio > worst4) { worst4 = ratio; worst4_c = c; }
                if (ratio > 1.0) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: case %d head %d o %lld -- t %lld "
                        "against o*2^%d/s = %.4f, error %.4f over the derived "
                        "bound %.4f\n", c, h, (long long)o, (long long)tv,
                        ATTN_RC_R_Q_ORACLE - 1, tr, e, bnd);
                    n_o4++;
                }
            }

            if ((s & (s - 1)) == 0) n_pow2++;
            if (N % s == 0) n_exact++; else n_inexact++;
            if (r.r == (1 << ATTN_RC_R_Q_ORACLE))     n_rmax++;
            if (r.r == (1 << (ATTN_RC_R_Q_ORACLE-1))) n_rmin++;
            if (r.p < p_lo) p_lo = r.p;
            if (r.p > p_hi) p_hi = r.p;
            if (r.p == 11)              n_pmin++;
            if (r.p == ATTN_RC_S_W - 1) n_pmax++;
        }

        fprintf(f, "%d %d\n", c, nhead);
        for (int h = 0; h < nhead; h++) fprintf(f, "%u ", sv[h]);
        fprintf(f, "\n");
        for (int h = 0; h < nhead; h++) {
            attn_recip_t r; attn_recip(sv[h], &r);
            fprintf(f, "%d ", r.p);
        }
        fprintf(f, "\n");
        for (int h = 0; h < nhead; h++) {
            attn_recip_t r; attn_recip(sv[h], &r);
            fprintf(f, "%d ", r.r);
        }
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_recip_vec: %d layers x %d heads -> %s\n",
            ncase, nhead, out);
    fprintf(stderr, "  oracle 4  worst |t - o*2^14/s| / derived bound: %.4f "
                    "(case %d)\n", worst4, worst4_c);
    fprintf(stderr, "  p in [%d, %d]; s a power of two %ld, exact divisions "
                    "%ld, inexact %ld\n", p_lo, p_hi, n_pow2, n_exact,
            n_inexact);
    fprintf(stderr, "  r at the top of the u16 window %ld, at the bottom %ld; "
                    "p = 11 %ld, p = %d %ld\n",
            n_rmax, n_rmin, n_pmin, ATTN_RC_S_W - 1, n_pmax);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld quotients are not the "
                                "floor\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld range violations\n",
                        n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld reciprocals on the wrong "
                                "side of 1/s\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld downstream products "
                                "outside the derived bound\n", n_o4); fail = 1; }
    /* Absent coverage is a FAILURE of the generator, not a note: a vector set
     * that never reaches r = 2^15 lets a 15-bit reciprocal pass, and one that
     * never divides exactly lets a rounding divider pass. */
    if (n_pow2 == 0 || n_exact == 0 || n_inexact == 0 || n_rmax == 0
        || n_rmin == 0 || n_pmin == 0 || n_pmax == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- pow2 %ld, exact %ld, inexact "
                        "%ld, r=2^15 %ld, r=2^14 %ld, p=11 %ld, p=%d %ld; "
                        "every one must be non-zero\n",
                n_pow2, n_exact, n_inexact, n_rmax, n_rmin, n_pmin,
                ATTN_RC_S_W - 1, n_pmax);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: every r is the exact floor by multiplication, p "
                    "brackets s and r sits in [2^14, 2^15], the reciprocal "
                    "never exceeds 1/s, and the downstream product is inside "
                    "the derived bound\n");
    return 0;
}

#endif /* ATTN_RECIP_INCLUDE */
