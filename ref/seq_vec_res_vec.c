/* seq_vec_res_vec -- reference model and vectors for rtl/seq_vec_res.vhd,
 * subsystem D's residual accumulate (opcode OP_VEC_RES).
 *
 * WHAT THE UNIT COMPUTES.  Two block-floating-point vectors, each `n` int16
 * mantissas with ONE shared exponent, are added and the result is written back
 * as a block-floating-point vector with a NEW shared exponent:
 *
 *      value_i = x[i] * 2^-ex  +  e[i] * 2^-ee        (the mathematical job)
 *      out[i] * 2^-oexp  ~=  value_i                  (what is written)
 *
 * The exponent is a NUMBER OF FRACTIONAL BITS, so a LARGER exponent is a FINER
 * scale and a SMALLER value for the same mantissa.  That is the convention
 * rtl/bfp_pack.vhd already uses (`o_exp = Q - shift`), and getting it backwards
 * inverts the whole alignment.
 *
 * THE NUMERIC CONTRACT, which did not exist before this file.  D's design spec
 * leaves D-vec's arithmetic entirely open; every rule below is a DECISION, and
 * each one is stated with the reason it was taken rather than left implicit in
 * the RTL:
 *
 *  1. ALIGN TO THE FINER GRID, CLAMPED.  Both operands are brought to a common
 *     grid q before adding, so no input bit is thrown away when the exponents
 *     are close -- which is the normal case, because both operands come from
 *     the same residual stream.  q = max(ex, ee) would be exact but lets the
 *     LARGER-magnitude operand (the one with the SMALLER exponent) be shifted
 *     up without bound, which overflows any fixed accumulator.  So q is clamped
 *     to min(ex,ee) + SHMAX with SHMAX = ACC_W - MANT_W - 1 = 15, which is the
 *     largest left shift a 16-bit mantissa can take and still leave room in a
 *     32-bit accumulator for the second operand and the carry.
 *
 *     The clamp is not a corner case being papered over: it is the statement
 *     that when two exponents differ by more than 15, the operand with the
 *     larger exponent is smaller than half an LSB of the other and rounding it
 *     away is the CORRECT answer, not an approximation of one.
 *
 *  2. ROUND HALF TOWARD +INFINITY on every right shift, and never a C `>>` on
 *     a negative value (implementation-defined before C23).  Same rule as
 *     bfp_pack and as mv4i_arith's site 2/3/4; implemented locally here rather
 *     than included, so the reference shares no line of arithmetic with any
 *     package the RTL uses.
 *
 *  3. THE OUTPUT EXPONENT IS DRIVEN BY THE MAXIMUM, exactly as bfp_pack:
 *     p = msb_pos(max_i |acc_i|), sh = max(0, p - KEEP) with KEEP = MANT_W - 2,
 *     oexp = q - sh.  Two consequences worth stating because they are checked:
 *       - at sh = 0 the result is EXACT: out[i] == acc[i], no rounding at all;
 *       - at sh > 0 exactly one element can saturate, by exactly one LSB, and
 *         only when the rounding of the maximum crosses 2^15.  The clamp is
 *         kept (it is the difference between 32767 and -32768 in one element)
 *         and reported in `sat`, not hidden.
 *
 *  4. TWO PASSES, NO SCRATCH.  The maximum is not known until every element has
 *     been formed, so the shift cannot be chosen on a single pass.  The unit
 *     therefore reads both sources TWICE and recomputes the sum, rather than
 *     spilling a 32-bit intermediate to a scratch memory as D's skeleton spec
 *     section 2.5 budgets for the swiglu step.  For THIS op the recomputation
 *     is one shift and one add, which is free, and the scratch would be
 *     4096 x 32 bits = 4 RAMB36 that buys nothing.  This is a departure from
 *     the spec's budget and it is deliberate; it does not apply to swiglu,
 *     whose recomputation would be a second LUT read and a second multiply.
 *
 * THE GOLDEN IS A DOUBLE ORACLE, NOT A SECOND INTEGER PATH.  A reference that
 * recomputed the same integer recipe would agree with a wrong recipe.  Five
 * oracles, none of which restates the recipe:
 *
 *   O1  REAL-VALUED.  |out*2^-oexp - (x*2^-ex + e*2^-ee)| against a derived
 *       bound, in long double, from the ORIGINAL inputs.  Every quantity here
 *       is a dyadic rational inside long double's 64-bit significand, so the
 *       comparison is exact and the bound is checked with <=, not a tolerance.
 *   O2  NORMALISATION RANGE, as exact integer inequalities: at sh > 0 the
 *       largest output magnitude is in [2^KEEP, 2^15]; at sh = 0 the output IS
 *       the accumulator.  A shift one too large or one too small fails this
 *       without any reference to how the shift was computed.
 *   O3  A DIFFERENT ARITHMETIC.  Form the sum ONCE, exactly, in 64 bits at the
 *       unclamped grid max(ex,ee), then round it ONCE to grid q.  That must
 *       equal the two-shift path.  It is a theorem
 *       (round(A*2^k + B, k) = A + round(B, k), because the left-shifted
 *       operand is an exact multiple of the output LSB), not a construction,
 *       so it is a real check on the clamp and on the per-operand rounding.
 *   O6  ROUNDING DIRECTION, as an exact two-sided integer inequality with no
 *       magnitude bound and no floating point: round-half-up puts the residual
 *       in [-2^(sh-1), 2^(sh-1)), truncation puts it in [0, 2^sh).  Added
 *       because widening O1's bound and truncating together left every other
 *       oracle silent -- O1 was the only thing pinning the rounding rule.
 *   O5  THE CLAMP, PINNED FROM BOTH SIDES.  Where the exponents are close
 *       enough that exactness is affordable, the accumulator must be EXACT --
 *       which kills a clamp one notch too TIGHT, the direction that loses
 *       precision silently and that every other oracle rescales with.  And
 *       SHMAX is asserted statically, from MANT_W and ACC_W, to be the largest
 *       left shift a full-scale mantissa survives.
 *   O4  EXPONENT-SHIFT INVARIANCE.  Adding the same k to BOTH input exponents
 *       must leave every output mantissa bit-identical and move oexp by exactly
 *       k.  The unit may depend on the DIFFERENCE of the exponents and on
 *       nothing else; any absolute-exponent dependence dies here.
 *
 * Build: cc -O2 -Wall -Wextra -o seq_vec_res_vec seq_vec_res_vec.c -lm
 * Usage: ./seq_vec_res_vec <out.txt> [ncase] [seed]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ---- shape.  MANT_W and ACC_W are the RTL's generics; SHMAX and KEEP are
 * DERIVED from them here and re-derived independently in the RTL, so a change
 * to one that is not mirrored in the other is a vector-file shape mismatch and
 * not a silent disagreement. ---------------------------------------------- */
#define MANT_W 16
#define ACC_W  32
#define SHMAX  (ACC_W - MANT_W - 1)      /* 15 */
#define KEEP   (MANT_W - 2)              /* 14 */
#define NMAX   4096

/* ---- local arithmetic.  Deliberately NOT ref/mv4i_arith.h: that header has a
 * generated VHDL twin (rtl/mv4i_arith_pkg.vhd), and a reference that shares its
 * rounding rule with the RTL agrees with a wrong rounding rule. ------------ */
static int64_t floor_shr(int64_t v, int sh)
{
    if (sh <= 0) return v;
    if (sh >= 63) return (v < 0) ? -1 : 0;   /* 1<<63 is UB, and this is exact */
    int64_t d = (int64_t)1 << sh, q = v / d;
    if (v % d != 0 && v < 0) q -= 1;         /* C truncates; we floor */
    return q;
}
static int64_t round_half_up(int64_t v, int sh)
{
    if (sh <= 0) return v;
    /* NOT floor_shr's `(v < 0) ? -1 : 0` shortcut, and the difference is real:
     * the half-LSB bias is added BEFORE the floor, so once 2^(sh-1) exceeds
     * |v| the result is 0 for BOTH signs.  Every v reaching here is an int16
     * mantissa or a 32-bit accumulator, so |v| < 2^32 and sh >= 33 is exactly
     * that condition.  Copying the floor_shr shortcut would return -1 for
     * negative mantissas at wide alignment shifts -- reachable, because the
     * exponent fields are 16-bit signed and nothing bounds their difference.
     * Stating it directly also avoids the 1 << 63 overflow, which is UB. */
    if (sh >= 33) return 0;
    return floor_shr(v + ((int64_t)1 << (sh - 1)), sh);
}
/* msb_pos(0) = 0 is NORMATIVE, and it is what makes an all-zero vector take
 * sh = 0 and keep its exponent instead of inventing one. */
static int msb_pos_u(uint64_t a)
{
    int r = 0;
    for (int i = 0; i < 64; i++) if (a & ((uint64_t)1 << i)) r = i;
    return r;
}
static int64_t iabs64(int64_t v) { return v < 0 ? -v : v; }

/* ---- the recipe ---------------------------------------------------------- */
typedef struct {
    int      n, ex, ee;
    int16_t  x[NMAX], e[NMAX];
    int16_t  out[NMAX];
    int32_t  acc[NMAX];
    int      q, sx, se, p, sh, oexp, sat;
} job_t;

/* MUT_* below are the mutation points used by sim/mutate_ref_seq_vec_res.sh.
 * They are ordinary code; the script rewrites them textually. */
static void recipe(job_t *j)
{
    int qmax = j->ex > j->ee ? j->ex : j->ee;
    int qmin = j->ex < j->ee ? j->ex : j->ee;

    j->q  = (qmax - qmin > SHMAX) ? (qmin + SHMAX) : qmax;   /* MUT_Q */
    j->sx = j->q - j->ex;
    j->se = j->q - j->ee;

    uint64_t orv = 0;
    for (int i = 0; i < j->n; i++) {
        int64_t a = (j->sx >= 0) ? ((int64_t)j->x[i] << j->sx)
                                 : round_half_up((int64_t)j->x[i], -j->sx);
        int64_t b = (j->se >= 0) ? ((int64_t)j->e[i] << j->se)
                                 : round_half_up((int64_t)j->e[i], -j->se);
        int64_t s = a + b;                                   /* MUT_ADD */
        if (s > INT32_MAX || s < INT32_MIN) {
            fprintf(stderr, "seq_vec_res_vec: accumulator overflowed %lld -- "
                    "the SHMAX clamp is wrong\n", (long long)s);
            exit(2);
        }
        j->acc[i] = (int32_t)s;
        orv |= (uint64_t)iabs64(s);                          /* MUT_OR */
    }

    /* The OR of the magnitudes has the same highest set bit as the MAXIMUM of
     * the magnitudes, because msb_pos is monotone and OR preserves the top bit.
     * Stated here because the RTL uses the OR (no carry chain, so it closes
     * timing where an 8-way 32-bit max compare would not) and the two must be
     * the same number. */
    j->p    = msb_pos_u(orv);
    j->sh   = j->p - KEEP; if (j->sh < 0) j->sh = 0;          /* MUT_SH */
    j->oexp = j->q - j->sh;                                   /* MUT_OEXP */

    j->sat = 0;
    for (int i = 0; i < j->n; i++) {
        int64_t r = round_half_up((int64_t)j->acc[i], j->sh); /* MUT_RND */
        if (r >  32767) { r =  32767; j->sat = 1; }           /* MUT_SAT */
        if (r < -32768) { r = -32768; j->sat = 1; }
        j->out[i] = (int16_t)r;
    }
}

/* ---- oracles ------------------------------------------------------------- */
static int nfail = 0;
static void bad(const job_t *j, const char *what, int i)
{
    fprintf(stderr, "ORACLE FAIL (%s) case n=%d ex=%d ee=%d q=%d sh=%d "
            "oexp=%d elem %d: x=%d e=%d acc=%ld out=%d\n",
            what, j->n, j->ex, j->ee, j->q, j->sh, j->oexp, i,
            i < 0 ? 0 : j->x[i], i < 0 ? 0 : j->e[i],
            i < 0 ? 0L : (long)j->acc[i], i < 0 ? 0 : j->out[i]);
    nfail++;
}

static long double ldexp2(long double m, int e) /* m * 2^e, exact for our range */
{
    long double r = m;
    while (e > 0) { r *= 2.0L; e--; }
    while (e < 0) { r /= 2.0L; e++; }
    return r;
}

/* O1.  Never touches the integer path: it re-states the JOB, not the recipe. */
static void oracle_real(const job_t *j)
{
    for (int i = 0; i < j->n; i++) {
        long double want = ldexp2((long double)j->x[i], -j->ex)
                         + ldexp2((long double)j->e[i], -j->ee);
        long double got  = ldexp2((long double)j->out[i], -j->oexp);
        long double err  = got - want; if (err < 0) err = -err;
        /* half an LSB of the alignment grid (the clamped operand's rounding)
         * plus half an LSB of the output grid (the final rounding), plus one
         * whole output LSB where the saturating clamp fired. */
        long double bound = ldexp2(0.5L, -j->q) + ldexp2(0.5L, -j->oexp);
        if (j->sat) bound += ldexp2(1.0L, -j->oexp);
        if (err > bound) { bad(j, "O1 real-valued", i); return; }
    }
}

/* O2.  Exact integer inequalities on the NORMALISATION, with no reference to
 * how the shift was computed. */
static void oracle_range(const job_t *j)
{
    int64_t mx = 0;
    for (int i = 0; i < j->n; i++) {
        int64_t a = iabs64(j->out[i]); if (a > mx) mx = a;
    }
    if (j->sh == 0) {
        for (int i = 0; i < j->n; i++)
            if ((int64_t)j->out[i] != (int64_t)j->acc[i]) {
                bad(j, "O2 sh=0 must be exact", i); return;
            }
    } else {
        if (mx < ((int64_t)1 << KEEP) || mx > ((int64_t)1 << (MANT_W - 1))) {
            bad(j, "O2 normalisation range", -1); return;
        }
    }
    /* O2b: the max-driven shift must leave EVERY element inside one LSB of the
     * int16 range before the clamp, so saturation can never be more than a
     * 1-LSB event.  A shift one too small breaks this on the maximum element. */
    for (int i = 0; i < j->n; i++) {
        int64_t r = round_half_up((int64_t)j->acc[i], j->sh);
        if (r > 32768 || r < -32768) { bad(j, "O2b pre-clamp magnitude", i); return; }
    }
}

/* O3.  Form the sum ONCE, exactly, at the unclamped grid, then round ONCE. */
static void oracle_wide(const job_t *j)
{
    int q0 = j->ex > j->ee ? j->ex : j->ee;
    int q1 = j->ex < j->ee ? j->ex : j->ee;
    /* The unclamped grid is the whole point of this oracle, and at a large
     * exponent difference the unclamped sum does not fit int64: a 16-bit
     * mantissa shifted up by 60 is 76 bits.  Skipping is honest; widening to
     * __int128 would only move the wall.  The cases that exercise the deep
     * clamp are covered by O1 and O5 instead, and by the RTL comparison. */
    if (q0 - q1 > 45) return;
    for (int i = 0; i < j->n; i++) {
        int64_t full = ((int64_t)j->x[i] << (q0 - j->ex))
                     + ((int64_t)j->e[i] << (q0 - j->ee));
        int64_t want = round_half_up(full, q0 - j->q);
        if (want != (int64_t)j->acc[i]) { bad(j, "O3 wide single-rounding", i); return; }
    }
}

/* O6.  THE ROUNDING DIRECTION, as an exact two-sided integer inequality, with
 * no magnitude bound and no floating point anywhere.
 *
 * WHY IT EXISTS.  Mutating O1's bound wide AND truncating the final requantise
 * (mutation R13) left the whole oracle set silent: O1 was the ONLY thing
 * pinning the rounding direction, because O2's exactness branch is vacuous at
 * sh = 0 (where floor and round-half-up are the same function) and O2b/O3 are
 * stated in terms of round_half_up itself.  One oracle for one rule is one
 * oracle too few.
 *
 * round_half_up(v, sh) = floor((v + 2^(sh-1)) / 2^sh) implies, exactly,
 *      -2^(sh-1)  <=  v - r*2^sh  <  2^(sh-1)
 * whereas truncation gives  0 <= v - r*2^sh < 2^sh  and ceiling gives the
 * mirror image.  Half of each range is shared, so no single element separates
 * them -- but over a vector some element lands in the half that does. */
static void oracle_round_dir(const job_t *j)
{
    if (j->sh == 0) return;                 /* nothing to round, nothing to say */
    int64_t half = (int64_t)1 << (j->sh - 1);
    for (int i = 0; i < j->n; i++) {
        if (j->out[i] == 32767 || j->out[i] == -32768) continue;  /* may be clamped */
        int64_t d = (int64_t)j->acc[i] - ((int64_t)j->out[i] << j->sh);
        if (d < -half || d >= half) { bad(j, "O6 rounding direction", i); return; }
    }
}

/* O5.  THE CLAMP IS PINNED FROM BOTH SIDES, and neither half restates
 * `qmin + SHMAX`.
 *   above: when the exponents are close enough that exactness is AFFORDABLE,
 *          the accumulator must be the EXACT sum -- no rounding at all.  A
 *          clamp one notch too tight rounds where it did not have to and dies
 *          here.  This is the dangerous direction: it costs precision
 *          silently, overflows nothing, and every other oracle rescales with
 *          it (O1's bound is stated in terms of q, so a smaller q LOOSENS it).
 *   below: SHMAX itself is checked once, statically, as the largest left shift
 *          a full-scale mantissa survives in the accumulator.  A clamp one
 *          notch too generous is caught by the overflow trap in `recipe`, but
 *          only on a case that happens to reach full scale, so it is worth
 *          asserting on the extreme value directly rather than waiting.
 */
static void oracle_clamp(const job_t *j)
{
    int q0 = j->ex > j->ee ? j->ex : j->ee;
    int q1 = j->ex < j->ee ? j->ex : j->ee;
    if (q0 - q1 <= SHMAX) {
        for (int i = 0; i < j->n; i++) {
            int64_t full = ((int64_t)j->x[i] << (q0 - j->ex))
                         + ((int64_t)j->e[i] << (q0 - j->ee));
            if (full != (int64_t)j->acc[i]) {
                bad(j, "O5 exactness was affordable and was not taken", i);
                return;
            }
        }
    }
    {   /* static, and deliberately re-derived from MANT_W and ACC_W rather
         * than from SHMAX, so moving SHMAX alone is caught. */
        int64_t worst = ((int64_t)1 << (MANT_W - 1)) << SHMAX;
        int64_t next  = ((int64_t)1 << (MANT_W - 1)) << (SHMAX + 1);
        if (worst + ((int64_t)1 << (MANT_W - 1)) > INT32_MAX
            || next <= INT32_MAX) {
            bad(j, "O5 SHMAX is not the largest safe left shift", -1);
        }
    }
}

/* O4.  The unit may depend on the DIFFERENCE of the exponents and nothing else. */
static void oracle_shift_invariant(const job_t *j)
{
    static job_t t;
    for (int k = -7; k <= 7; k += 7) {
        if (k == 0) continue;
        t = *j; t.ex = j->ex + k; t.ee = j->ee + k;
        recipe(&t);
        if (t.oexp != j->oexp + k) { bad(j, "O4 oexp not shift-invariant", -1); return; }
        for (int i = 0; i < j->n; i++)
            if (t.out[i] != j->out[i]) { bad(j, "O4 mantissa not shift-invariant", i); return; }
    }
}

/* ---- stimulus ------------------------------------------------------------ */
static uint64_t rs;
static uint32_t rnd(void) { rs = rs * 6364136223846793005ULL + 1442695040888963407ULL;
                            return (uint32_t)(rs >> 33); }
static int16_t rnd_mant(int mode)
{
    switch (mode) {
        case 0:  return (int16_t)(int32_t)(rnd() % 65536u) - 0;  /* full range wrap */
        case 1:  return (int16_t)((int32_t)(rnd() % 2001u) - 1000);
        case 2:  return (rnd() & 1) ? (int16_t)32767 : (int16_t)-32768;
        default: return (int16_t)((int32_t)(rnd() % 65536u) - 32768);
    }
}

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "seq_vec_res_vec.txt";
    int ncase = argc > 2 ? atoi(argv[2]) : 24;
    rs = (uint64_t)(argc > 3 ? atoi(argv[3]) : 12345) * 2654435761u + 1;

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 2; }
    fprintf(f, "%d %d %d %d %d\n", ncase, MANT_W, ACC_W, SHMAX, KEEP);

    static job_t j;
    int cov_sh0 = 0, cov_shpos = 0, cov_sat = 0, cov_clamp = 0;
    int cov_partial = 0, cov_neg = 0, cov_zero = 0;
    for (int c = 0; c < ncase; c++) {
        int mode = 3;
        memset(&j, 0, sizeof j);
        switch (c) {
        /* Deterministic edge cases FIRST, so a shrinking `ncase` keeps them. */
        case 0:  j.n = 8;    j.ex = 12; j.ee = 12; mode = -1; break; /* all zero */
        case 1:  j.n = 16;   j.ex = 12; j.ee = 12; mode = 1;  break; /* sh = 0 */
        case 2:  j.n = 64;   j.ex = 12; j.ee = 12 - SHMAX; mode = 3; break;
        case 3:  j.n = 64;   j.ex = 12; j.ee = 12 - SHMAX - 1; mode = 3; break;
        case 4:  j.n = 64;   j.ex = 40; j.ee = 8;  mode = 3; break;  /* deep clamp */
        /* SATURATION, and it has to be CRAFTED.  With the shift driven by the
         * maximum, |round(acc, sh)| <= 2^15 always, and the only value that
         * reaches 2^15 is max_abs = 2^(p+1) - 1 exactly -- one below the next
         * binade.  Random mantissas essentially never land there, which is why
         * 24 random cases covered the clamp ZERO times.  Note also that the
         * NEGATIVE clamp is unreachable by construction: round-half-toward-
         * +infinity of -(2^(p+1)-1) is exactly -2^15, never below it.
         * Here q = 12, sx = 0, se = 1, so acc[3] = 32767 + 2*16384 = 65535,
         * p = 15, sh = 1 and round_half_up(65535, 1) = 32768 -> clamps. */
        case 5:  j.n = 8;    j.ex = 12; j.ee = 11; mode = -1;
                 j.x[3] = 32767; j.e[3] = 16384; break;
        case 6:  j.n = 20;   j.ex = 12; j.ee = 11; mode = 3;  break; /* n % LANES */
        case 7:  j.n = 1;    j.ex = 0;  j.ee = 31; mode = 3;  break; /* n = 1 */
        case 8:  j.n = 4096; j.ex = 12; j.ee = 12; mode = 3;  break; /* the real job */
        /* THE ALIGNMENT ROUNDING, MADE VISIBLE AT THE OUTPUT.  Cases 3 and 4
         * do engage the clamp, but there the surviving operand is shifted up
         * by 15 and dominates, so a +-1 change in the clamped operand's
         * rounding is shifted straight back out again and the output is
         * identical whether that rounding is a floor or a round-half-up.  RTL
         * mutation N2 -- dropping the alignment round bias -- SURVIVED every
         * configuration on the vector set without these two.
         *
         * Construction: put the OTHER operand at zero, so nothing dominates
         * and nothing is left-shifted into the top of the accumulator.  Then
         * diff = SHMAX + 1 gives an alignment right shift of exactly 1, the
         * magnitudes stay under 2^15 so sh = 0 and the accumulator IS the
         * output, and an odd mantissa rounds up where a floor would not. */
        case 9:  j.n = 16;   j.ex = 12 + SHMAX + 1; j.ee = 12; mode = -1;
                 for (int i = 0; i < 16; i++) j.x[i] = (int16_t)(2*i*37 + 1);
                 break;
        case 10: j.n = 16;   j.ex = 12; j.ee = 12 + SHMAX + 1; mode = -1;
                 for (int i = 0; i < 16; i++) j.e[i] = (int16_t)(2*i*37 + 1);
                 break;
        /* THE DEEP CLAMP, where the alignment shift saturates.  The exponent
         * fields are 16-bit signed and nothing bounds their difference, so an
         * implementation has to decide what a shift of 60 means; here it is
         * zero for both signs, and an implementation that clamped its shifter
         * too early would return +-1 instead.  RTL mutation N4 needs these. */
        case 11: j.n = 24;   j.ex = 70; j.ee = 10; mode = 3;  break;
        case 12: j.n = 24;   j.ex = 10; j.ee = 70; mode = 3;  break;
        /* THE DEEP CLAMP'S ROUNDING, MADE VISIBLE, and this is the second time
         * the same masking trap had to be broken.  Cases 4, 11 and 12 all
         * clamp deeply, but in every one of them the surviving operand is
         * left-shifted by SHMAX and sets sh ~ 16, so the clamped operand's
         * entire contribution -- 0 or 1 -- is shifted back out and RTL
         * mutation N4 (clamp the alignment shifter one notch too early)
         * SURVIVED all of them.
         *
         * Construction: zero the OTHER operand, so nothing is left-shifted,
         * sh = 0, and the accumulator IS the output.  diff = 32 puts the
         * alignment right shift at 17, where the true answer is 0 for every
         * int16 mantissa; a shifter clamped at 15 instead returns 1 for every
         * mantissa at or above 2^14.  Zero against one, at the output. */
        case 13: j.n = 16;   j.ex = 12 + 32; j.ee = 12; mode = -1;
                 for (int i = 0; i < 16; i++)
                     j.x[i] = (int16_t)((i & 1) ? -(16384 + i*97) : (16384 + i*97));
                 break;
        case 14: j.n = 16;   j.ex = 12; j.ee = 12 + 32; mode = -1;
                 for (int i = 0; i < 16; i++)
                     j.e[i] = (int16_t)((i & 1) ? -(16384 + i*97) : (16384 + i*97));
                 break;
        default:
            j.n  = (int)(rnd() % 300u) + 1;
            j.ex = (int)(rnd() % 41u);
            j.ee = j.ex + (int)(rnd() % 65u) - 32;
            if (j.ee < 0) j.ee = 0;
            mode = (int)(rnd() % 4u);
            break;
        }
        if (mode >= 0) for (int i = 0; i < j.n; i++) { j.x[i] = rnd_mant(mode);
                                                       j.e[i] = rnd_mant(mode); }
        recipe(&j);
        oracle_real(&j);
        oracle_range(&j);
        oracle_wide(&j);
        oracle_clamp(&j);
        oracle_round_dir(&j);
        oracle_shift_invariant(&j);

        fprintf(f, "%d %d %d %d %d %d %d\n", c, j.n, j.ex, j.ee, j.oexp, j.sat, j.sh);
        for (int i = 0; i < j.n; i++) { fprintf(f, "%d ", j.x[i]); }
        fputc('\n', f);
        for (int i = 0; i < j.n; i++) { fprintf(f, "%d ", j.e[i]); }
        fputc('\n', f);
        for (int i = 0; i < j.n; i++) { fprintf(f, "%d ", j.out[i]); }
        fputc('\n', f);

        cov_sh0    += (j.sh == 0);
        cov_shpos  += (j.sh >  0);
        cov_sat    += (j.sat != 0);
        cov_clamp  += ((j.ex > j.ee ? j.ex : j.ee) != j.q);
        cov_partial+= ((j.n % 8) != 0);
        cov_neg    += (j.sx < 0 || j.se < 0);
        cov_zero   += (j.p == 0);
    }
    fclose(f);
    if (nfail) { fprintf(stderr, "seq_vec_res_vec: %d ORACLE FAILURES\n", nfail); return 1; }
    /* COVERAGE, printed every run and not on request.  A property that no case
     * reaches is untested however many oracles guard it -- the attn_recip N7
     * lesson -- and the two that are easiest to lose here are the SHMAX clamp
     * (needs |ex - ee| > 15) and the saturating clamp (needs the maximum's
     * rounding to cross 2^15).  Any zero below is a hole. */
    fprintf(stderr, "seq_vec_res_vec: %d cases, 6 oracles clean\n", ncase);
    fprintf(stderr, "  coverage: sh=0 %d | sh>0 %d | saturating clamp %d | "
            "SHMAX clamp %d | negative align shift %d | n not a multiple of 8 %d"
            " | all-zero accumulator %d\n",
            cov_sh0, cov_shpos, cov_sat, cov_clamp, cov_neg, cov_partial, cov_zero);
    if (!cov_sh0 || !cov_shpos || !cov_sat || !cov_clamp || !cov_neg
        || !cov_partial || !cov_zero) {
        fprintf(stderr, "seq_vec_res_vec: COVERAGE HOLE -- a rule above is "
                "reached by no case, so nothing tests it\n");
        return 1;
    }
    return 0;
}
