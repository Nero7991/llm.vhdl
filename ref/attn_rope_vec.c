/* ref/attn_rope_vec.c -- vectors and golden for rtl/attn_rope.vhd.
 *
 * Subsystem C, step 3: the NEOX-paired IMROPE rotation of one head vector.
 *
 *   for j in 0 .. NPAIR-1, with the twiddle pair (c, s) for that j:
 *       y[j]         : s16 = sat16( round_shift( x[j]*c - x[j+NPAIR]*s, 15 ) )
 *       y[j+NPAIR]   : s16 = sat16( round_shift( x[j]*s + x[j+NPAIR]*c, 15 ) )
 *   for i in N_ROT .. HEAD_DIM-1:
 *       y[i] = x[i]                                     bit-identical
 *
 * The block exponent is PRESERVED: the twiddle >> 15 keeps mantissas at the
 * same scale, so the caller's exponent passes through untouched.
 *
 * PAIRING IS (j, j+NPAIR), NOT (2j, 2j+1), AND THE TWO ARE DIFFERENT
 * ROTATIONS.  rtl/rope.vhd was written for stories260K, which is ggml's
 * GGML_ROPE_TYPE_NORMAL and pairs ADJACENT elements.  Qwen3.5/3.8 is
 * GGML_ROPE_TYPE_IMROPE, which dispatches through rotate_pairs(n_dims,
 * n_dims/2, ...) and therefore pairs HALVES.  A unit that used the adjacent
 * convention would produce plausible garbage on every vector, so the generator
 * plants a shape (shape 6) on which the two conventions cannot agree, rather
 * than relying on random data to separate them.
 *
 * ONLY THE FIRST N_ROT DIMS ROTATE.  GGUF rope.dimension_count is 64 against a
 * head_dim of 256, so 192 of the 256 dims pass through untouched.  That is an
 * EXACT equality and it is ORACLE 3; an off-by-one in the boundary or an
 * indexing error shows up there immediately and in no other check.
 *
 * WHY THIS UNIT AND WHY NOW.  It extends the contiguous verified run BACKWARDS:
 * attn_kv_quant (step 4) is already verified and K enters it post-RoPE, so
 * with attn_twiddle (sites R1/R2) and this unit, steps 3 through 8 are one
 * chain rather than two fragments.
 *
 * THE INDEPENDENT-ORACLE QUESTION, ANSWERED BEFORE THE UNIT WAS BUILT.  The
 * rotation is exact integer arithmetic given (c, s), so a naive "check" would
 * be a replay -- the attn_qk_norm situation.  It is not, for three reasons,
 * and each is a separate oracle below:
 *   - the twiddles come from a TRANSCENDENTAL, so the whole rotation can be
 *     checked against cos/sin at the exact real angle inside a derived bound
 *     (ORACLE 1);
 *   - a rotation is ORTHOGONAL, and norm preservation is a property of the
 *     rotation group rather than of this arithmetic (ORACLE 2);
 *   - the pass-through region and pos = 0 are exact equalities that no
 *     fixed-point machinery participates in (ORACLES 3 and 4).
 * None of the four shares a shift, a rounding rule or a table with the path.
 *
 * DOUBLE ORACLE, six checks:
 *
 *   ORACLE 1, the rotation against double at the TRUE angle, DERIVED bound.
 *     The target is the Q15 rotation -- (32767/32768) times the real one,
 *     because this convention encodes 1.0 as 32767 and divides by 32768, so
 *     the twiddle pair is a rotation shrunk by exactly 1 - 2^-15.  Then
 *     (x0*c - x1*s)/2^15 differs from that target by at most
 *     (|x0| + |x1|) * E_tw / 2^15, where E_tw is attn_twiddle's own derived
 *     three-term bound, and the round adds at most 0.5.  Both terms are
 *     derived, neither is chosen.  Comparing against the UNSHRUNK rotation
 *     instead leaves the 2^-15 factor unmodelled and fails on correct data
 *     wherever the output is large; see the note at the bound itself.
 *
 *   ORACLE 2, NORM PRESERVATION.  A rotation is orthogonal, so
 *     |y|^2 = |x|^2 exactly in the reals.  With y = Rx + e and |e_i| <= B from
 *     ORACLE 1, Cauchy-Schwarz gives
 *         | |y|^2 - |x|^2 |  <=  2*|x|*B*sqrt(2) + 2*B^2
 *     This is the only check that is a statement about the PAIR, and it is the
 *     one that cannot be satisfied by any implementation that is not actually
 *     a rotation -- a scale error, a swapped sign in one of the four products,
 *     or a shear all pass a per-component magnitude bound more easily than
 *     they pass this.
 *
 *   ORACLE 3, the PASS-THROUGH, exactly.  y[i] == x[i] for every i >= N_ROT,
 *     as integer equality.  The generator additionally requires that region to
 *     contain at least two distinct values, because a pass-through check over
 *     an all-zero tail is vacuous.
 *
 *   ORACLE 4, pos = 0, exactly.  Then c = 32767 and s = 0, so the rotation
 *     degenerates to y = round_shift(x*32767, 15) on both halves -- a near
 *     identity with a KNOWN one-sided shrink, not the identity.  Asserted as
 *     an equality rather than approximated.
 *
 *   ORACLE 5, SATURATION, which is REACHABLE and is therefore a value.
 *     |x0*c - x1*s| / 2^15 can reach |x0| + |x1|, which exceeds 32767 whenever
 *     both components are large and the angle is near an eighth turn.  The
 *     count is emitted as a golden and the generator requires it to be
 *     non-zero, and requires the saturation to be REACHED FROM BOTH SIDES.
 *
 *   ORACLE 6, the ROUNDING MODE.  round_shift is half toward PLUS infinity, so
 *     the exact quotient q = (x0*c - x1*s)/2^15 must satisfy
 *         y - 1 < q <= y + 0.5          (before saturation)
 *     computed in double.  A floor violates the upper half and a
 *     round-half-to-even violates it on exact ties.  ORACLE 1's bound admits
 *     0.5 either way and cannot see this.
 *
 * Build: cc -O2 -Wall -Wextra -o attn_rope_vec attn_rope_vec.c -lm
 * Usage: ./attn_rope_vec [out.txt] [ncase] [head_dim] [n_rot]
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>
#include "mv4i_arith.h"

#define ATTN_TWIDDLE_INCLUDE
#include "attn_twiddle_vec.c"

/* ---- the core, guarded so a later chain reference can #include it -------- */

#define ATTN_RP_Q       15      /* the twiddle's Q, and the kernel's shift    */
#define ATTN_RP_MANT_W  16      /* A's activation memory holds int16          */

/* Restated independently for the oracles.  See attn_score_q12_vec.c: a
 * constant shared between the thing under test and the thing testing it is not
 * a check, it is a restatement. */
#define ATTN_RP_Q_ORACLE 15

typedef struct { int nsat; } attn_rope_t;

static void attn_rope(const int32_t *x, int head_dim, int n_rot,
                      const int32_t *cs, const int32_t *sn,
                      int32_t *y, attn_rope_t *o)
{
    int npair = n_rot / 2;
    o->nsat = 0;
    for (int j = 0; j < npair; j++) {
        int64_t x0 = x[j], x1 = x[j + npair];
        int64_t c = cs[j], s = sn[j];
        int64_t r0 = mv4i_round_shift(x0*c - x1*s, ATTN_RP_Q);
        int64_t r1 = mv4i_round_shift(x0*s + x1*c, ATTN_RP_Q);
        int32_t m0 = mv4i_sat16(r0), m1 = mv4i_sat16(r1);
        if ((int64_t)m0 != r0) o->nsat++;
        if ((int64_t)m1 != r1) o->nsat++;
        y[j] = m0;
        y[j + npair] = m1;
    }
    /* The unrotated tail, bit-identical.  N_ROT = 64 of head_dim = 256. */
    for (int i = n_rot; i < head_dim; i++) y[i] = x[i];
}

#ifndef ATTN_ROPE_INCLUDE

static uint64_t rp = 20260903ULL;
static uint32_t rrnd(void){ rp ^= rp<<13; rp ^= rp>>7; rp ^= rp<<17; return (uint32_t)(rp>>32); }

#define MAXD 512

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_rope_vec.txt";
    int ncase    = (argc > 2) ? atoi(argv[2]) : 28;
    int head_dim = (argc > 3) ? atoi(argv[3]) : 96;
    int n_rot    = (argc > 4) ? atoi(argv[4]) : 64;
    if (head_dim > MAXD) head_dim = MAXD;
    if (n_rot > head_dim) n_rot = head_dim;
    int npair = n_rot / 2;

    attn_tw_init();

    static int32_t x[MAXD], y[MAXD], cs[MAXD], sn[MAXD];

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d\n", ncase, head_dim, n_rot);

    long n_o1=0,n_o2=0,n_o3=0,n_o4=0,n_o6=0;
    double w1=0.0, w2=0.0; int w1_c=-1;
    long n_sat=0, n_sat_hi=0, n_sat_lo=0, n_pos0=0, n_wrap=0;
    long n_xneg=0, n_xpos=0, n_xzero=0, n_rail=0, n_tail_nz=0;
    long n_adj_differs=0;
    uint32_t pos_seen[64]; int npos_seen=0;
    int x_distinct_min = 1 << 30;

    const int32_t X_MAX =  32767, X_MIN = -32768;

    for (int c = 0; c < ncase; c++) {
        uint32_t pos;
        switch (c % 5) {
        case 0: pos = 0; break;                 /* the exact identity case   */
        case 1: pos = 1; break;
        case 2: pos = 2047; break;              /* the largest phase         */
        case 3: pos = 4096; break;              /* wraps j = 0 several turns */
        default: pos = rrnd() % 2048u; break;
        }
        if (npos_seen < 64) pos_seen[npos_seen++] = pos;

        for (int j = 0; j < npair; j++) {
            attn_tw_t t; attn_twiddle(pos, j, &t);
            cs[j] = t.c; sn[j] = t.s;
            if ((uint64_t)pos * (uint64_t)tw_W[j] >= ((uint64_t)1 << 32))
                n_wrap++;
        }

        /* Value shapes, chosen for what is easy to get wrong:
         *  0  all zero            -- every product is zero and the tail check
         *                            would be vacuous, so it is paired with a
         *                            non-zero tail below
         *  1  both s16 rails      -- where the kernel's saturation lives
         *  2  one half zero       -- isolates the two products of each output
         *  3  the tail only       -- the rotated half is zero and the tail is
         *                            not, so ORACLE 3 carries the whole case
         *  4  large and equal     -- |x0| = |x1| near the rail with an angle
         *                            near an eighth turn is where saturation
         *                            is reached from BOTH sides
         *  6  alternating         -- x[i] = 0 for even i.  Under (j, j+NPAIR)
         *                            pairing both members of a pair have the
         *                            same parity, so a pair is (0, 0) or
         *                            (v, w); under ADJACENT pairing every pair
         *                            is (0, v).  The two conventions cannot
         *                            agree on this shape, which is why it is
         *                            planted rather than sampled
         *  else random
         */
        int vshape = c % 7;
        for (int i = 0; i < head_dim; i++) {
            int32_t v;
            switch (vshape) {
            case 0: v = 0; break;
            case 1: v = (i & 1) ? X_MAX : X_MIN; break;
            case 2: v = (i < npair) ? (int32_t)(rrnd() % 20001u) - 10000 : 0;
                    break;
            case 3: v = (i < n_rot) ? 0
                                    : (int32_t)(rrnd() % 20001u) - 10000; break;
            case 4: v = ((i & 1) ? 30000 : -30000); break;
            case 6: v = (i & 1) ? (int32_t)(rrnd() % 40001u) - 20000 : 0; break;
            default: v = (int32_t)(rrnd() & 0xFFFFu) - 32768; break;
            }
            x[i] = v;
        }
        /* Shape 0 would make the pass-through check vacuous, so give it a tail
         * that is not identically zero.  A field that never varies makes every
         * check on it meaningless -- the D owner's ordering guard passed
         * against a broken DUT for exactly that reason. */
        if (vshape == 0)
            for (int i = n_rot; i < head_dim; i++)
                x[i] = (int32_t)(i * 37 % 4001) - 2000;

        attn_rope_t r;
        attn_rope(x, head_dim, n_rot, cs, sn, y, &r);

        /* how many distinct values this case's input carries */
        {
            int d = 0;
            for (int i = 0; i < head_dim && d < 4; i++) {
                int seen = 0;
                for (int k = 0; k < i; k++) if (x[k] == x[i]) seen = 1;
                if (!seen) d++;
            }
            if (d < x_distinct_min) x_distinct_min = d;
        }

        for (int j = 0; j < npair; j++) {
            int64_t x0 = x[j], x1 = x[j + npair];
            double th = (double)pos
                      * pow(ATTN_TW_BASE_ORACLE, -(double)j/(double)npair);
            /* attn_twiddle's own derived three-term bound, restated here
             * because this unit's error inherits it. */
            double ea = (double)ATTN_TW_QMAX_ORACLE
                      * 2.0*M_PI*(double)pos*ldexp(1.0, -33);
            double eb = (double)ATTN_TW_QMAX_ORACLE
                      * (2.0*M_PI/(double)ATTN_TW_TBL_ORACLE)
                      * (2.0*M_PI/(double)ATTN_TW_TBL_ORACLE) / 8.0;
            double etw = ea + eb + 1.5;

            /* THE TARGET IS THE Q15 ROTATION, NOT THE REAL ONE, and the
             * difference is not a rounding detail.  This convention encodes
             * 1.0 as 32767 and divides by 2^15 = 32768, so the twiddle pair is
             * a rotation SHRUNK by the exact factor 32767/32768 = 1 - 2^-15.
             * Comparing against the unshrunk rotation leaves that factor as an
             * unmodelled error of |t|/2^15, which at |t| = 9,338 is 0.285
             * counts -- and the first version of this oracle did exactly that
             * and failed 17 of 1,792 components by 1 to 6 percent, all of them
             * where |t| was large.  A systematic 3 percent excess concentrated
             * on the largest values is the signature of a MISSING TERM in the
             * bound, not of a defect in the path.
             *
             * Scaling the target instead of widening the bound is the tighter
             * of the two fixes and it names the fact: the unit computes a
             * rotation that is short by one part in 32,768, uniformly, and
             * ORACLE 4 pins the same shrink exactly at pos = 0. */
            double qs = (double)ATTN_TW_QMAX_ORACLE / ldexp(1.0, ATTN_RP_Q_ORACLE);
            double t0 = qs * ((double)x0*cos(th) - (double)x1*sin(th));
            double t1 = qs * ((double)x0*sin(th) + (double)x1*cos(th));
            double bnd = ((double)llabs(x0) + (double)llabs(x1))
                       * etw / ldexp(1.0, ATTN_RP_Q_ORACLE) + 0.5;

            int sat0 = (y[j] == 32767 && t0 > 32767.0)
                    || (y[j] == -32768 && t0 < -32768.0);
            int sat1 = (y[j+npair] == 32767 && t1 > 32767.0)
                    || (y[j+npair] == -32768 && t1 < -32768.0);

            /* ---- ORACLE 1: the rotation against double ------------------ */
            if (!sat0) {
                double e = fabs((double)y[j] - t0);
                if (e/bnd > w1) { w1 = e/bnd; w1_c = c; }
                if (e > bnd) {
                    if (n_o1 < 8) fprintf(stderr,
                        "  FAIL oracle 1: case %d pair %d -- y[%d] %d against "
                        "x0*cos - x1*sin = %.4f at theta %.9f, error %.4f over "
                        "the derived bound %.4f\n", c, j, j, y[j], t0, th, e,
                        bnd);
                    n_o1++;
                }
            }
            if (!sat1) {
                double e = fabs((double)y[j+npair] - t1);
                if (e/bnd > w1) { w1 = e/bnd; w1_c = c; }
                if (e > bnd) {
                    if (n_o1 < 8) fprintf(stderr,
                        "  FAIL oracle 1: case %d pair %d -- y[%d] %d against "
                        "x0*sin + x1*cos = %.4f, error %.4f over %.4f\n",
                        c, j, j+npair, y[j+npair], t1, e, bnd);
                    n_o1++;
                }
            }

            /* ---- ORACLE 2: norm preservation, the orthogonality property - */
            if (!sat0 && !sat1) {
                /* |R_q x|^2 = (32767/32768)^2 |x|^2 exactly, since R_q is an
                 * orthogonal rotation scaled by that factor.  y = R_q x + e
                 * with |e_i| <= bnd, so Cauchy-Schwarz gives the bound below.
                 * The SCALE is part of the statement: a unit that dropped it
                 * would be off by 2*|x|^2/2^15, which on a pair near the rail
                 * is 65 counts and is not inside any of these bounds. */
                double nx = qs*qs*((double)x0*(double)x0
                                 + (double)x1*(double)x1);
                double ny = (double)y[j]*(double)y[j]
                          + (double)y[j+npair]*(double)y[j+npair];
                double nb = 2.0*sqrt(nx)*bnd*sqrt(2.0) + 2.0*bnd*bnd;
                double d = fabs(ny - nx);
                if (nb > 0.0 && d/nb > w2) w2 = d/nb;
                if (d > nb) {
                    if (n_o2 < 8) fprintf(stderr,
                        "  FAIL oracle 2: case %d pair %d -- |y|^2 = %.0f "
                        "against |x|^2 = %.0f, difference %.0f over the "
                        "derived %.0f.  A rotation is ORTHOGONAL; this is not "
                        "one\n", c, j, ny, nx, d, nb);
                    n_o2++;
                }
            }

            /* ---- ORACLE 6: the rounding mode, half toward +infinity ----- */
            if (!sat0) {
                double q = ((double)x0*(double)cs[j]
                          - (double)x1*(double)sn[j])
                         / ldexp(1.0, ATTN_RP_Q_ORACLE);
                if (!((double)y[j] - 1.0 < q + 1e-9
                      && q <= (double)y[j] + 0.5 + 1e-9)) {
                    if (n_o6 < 8) fprintf(stderr,
                        "  FAIL oracle 6: case %d pair %d -- the exact "
                        "quotient %.6f is not in (%d - 1, %d + 0.5]; the "
                        "kernel must round HALF TOWARD PLUS INFINITY\n",
                        c, j, q, y[j], y[j]);
                    n_o6++;
                }
            }

            /* ---- ORACLE 4: pos = 0 is a near identity, exactly ---------- */
            if (pos == 0) {
                int64_t e0 = mv4i_round_shift(x0 * (int64_t)ATTN_TW_QMAX_ORACLE,
                                              ATTN_RP_Q_ORACLE);
                int64_t e1 = mv4i_round_shift(x1 * (int64_t)ATTN_TW_QMAX_ORACLE,
                                              ATTN_RP_Q_ORACLE);
                if ((int64_t)y[j] != mv4i_sat16(e0)
                    || (int64_t)y[j+npair] != mv4i_sat16(e1)) {
                    if (n_o4 < 8) fprintf(stderr,
                        "  FAIL oracle 4: case %d pair %d at pos 0 -- got "
                        "(%d, %d), want (%lld, %lld).  At pos 0 the twiddle is "
                        "(32767, 0), so the rotation is a KNOWN one-sided "
                        "shrink and not the identity\n", c, j, y[j],
                        y[j+npair], (long long)mv4i_sat16(e0),
                        (long long)mv4i_sat16(e1));
                    n_o4++;
                }
            }

            if (sat0 || sat1) {
                if (y[j] == 32767 || y[j+npair] == 32767) n_sat_hi++;
                if (y[j] == -32768 || y[j+npair] == -32768) n_sat_lo++;
            }
            if (x0 < 0) n_xneg++; else if (x0 > 0) n_xpos++; else n_xzero++;
            if (x0 == X_MAX || x0 == X_MIN) n_rail++;

            /* Would the ADJACENT convention have produced a different answer
             * here?  Recorded rather than assumed: if it never would, the
             * pairing is untested. */
            if (j + npair < head_dim && 2*j + 1 < n_rot
                && x[j + npair] != x[2*j + 1]) n_adj_differs++;
        }

        /* ---- ORACLE 3: the pass-through, exactly --------------------- */
        for (int i = n_rot; i < head_dim; i++) {
            if (y[i] != x[i]) {
                if (n_o3 < 8) fprintf(stderr,
                    "  FAIL oracle 3: case %d dim %d -- the unrotated tail "
                    "must be bit-identical: got %d, want %d\n", c, i, y[i],
                    x[i]);
                n_o3++;
            }
            if (x[i] != 0) n_tail_nz++;
        }
        if (pos == 0) n_pos0++;
        n_sat += r.nsat;

        fprintf(f, "%d %u %d\n", c, pos, r.nsat);
        for (int i = 0; i < head_dim; i++) fprintf(f, "%d ", x[i]);
        fprintf(f, "\n");
        for (int i = 0; i < head_dim; i++) fprintf(f, "%d ", y[i]);
        fprintf(f, "\n");
        for (int j = 0; j < npair; j++) fprintf(f, "%d ", cs[j]);
        fprintf(f, "\n");
        for (int j = 0; j < npair; j++) fprintf(f, "%d ", sn[j]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "attn_rope_vec: %d head vectors x %d dims (%d rotated) "
            "-> %s\n", ncase, head_dim, n_rot, out);
    fprintf(stderr, "  oracle 1  worst |y - true rotation| / derived bound: "
            "%.4f (case %d)\n", w1, w1_c);
    fprintf(stderr, "  oracle 2  worst | |y|^2 - |x|^2 | / derived: %.4f\n", w2);
    fprintf(stderr, "  saturations %ld (high %ld, low %ld); pos = 0 cases %ld; "
            "phases that wrapped %ld\n", n_sat, n_sat_hi, n_sat_lo, n_pos0,
            n_wrap);
    fprintf(stderr, "  x neg %ld pos %ld zero %ld, at an s16 rail %ld; "
            "non-zero tail elements %ld\n",
            n_xneg, n_xpos, n_xzero, n_rail, n_tail_nz);

    int fail = 0;
    if (n_o1) { fprintf(stderr, "  FAIL oracle 1: %ld\n", n_o1); fail = 1; }
    if (n_o2) { fprintf(stderr, "  FAIL oracle 2: %ld\n", n_o2); fail = 1; }
    if (n_o3) { fprintf(stderr, "  FAIL oracle 3: %ld\n", n_o3); fail = 1; }
    if (n_o4) { fprintf(stderr, "  FAIL oracle 4: %ld\n", n_o4); fail = 1; }
    if (n_o6) { fprintf(stderr, "  FAIL oracle 6: %ld\n", n_o6); fail = 1; }

    /* A FIELD THAT IS CONSTANT ACROSS EVERY VECTOR MAKES EVERY CHECK ON IT
     * VACUOUS.  The D owner's ordering guard passed against a deliberately
     * broken DUT because the three fields it checked were identically zero in
     * all 491 descriptors.  Both scalars this generator emits are checked for
     * variation, and so is the input vector itself. */
    {
        int distinct = 0;
        for (int i = 0; i < npos_seen; i++) {
            int seen = 0;
            for (int k = 0; k < i; k++) if (pos_seen[k] == pos_seen[i]) seen = 1;
            if (!seen) distinct++;
        }
        if (distinct < 2) {
            fprintf(stderr, "  FAIL: `pos` takes %d distinct value(s); a field "
                    "that never varies makes every check on it vacuous\n",
                    distinct);
            fail = 1;
        }
        if (x_distinct_min < 2) {
            fprintf(stderr, "  FAIL: some case's input vector is CONSTANT, so "
                    "the pairing and the pass-through cannot be distinguished "
                    "on it\n");
            fail = 1;
        }
        fprintf(stderr, "  `pos` takes %d distinct values; every case's input "
                "carries at least %d distinct values\n", distinct,
                x_distinct_min);
    }

    /* Absent coverage is a FAILURE of the generator, not a note. */
    if (n_sat == 0 || n_sat_hi == 0 || n_sat_lo == 0 || n_pos0 == 0
        || n_wrap == 0 || n_xneg == 0 || n_xpos == 0 || n_xzero == 0
        || n_rail == 0 || n_tail_nz == 0 || n_adj_differs == 0) {
        fprintf(stderr, "  FAIL: coverage gap -- sat %ld sat-hi %ld sat-lo %ld "
                "pos0 %ld wrapped %ld x- %ld x+ %ld x0 %ld rails %ld "
                "tail-nonzero %ld adjacent-pairing-would-differ %ld; every one "
                "must be non-zero\n", n_sat, n_sat_hi, n_sat_lo, n_pos0,
                n_wrap, n_xneg, n_xpos, n_xzero, n_rail, n_tail_nz,
                n_adj_differs);
        fail = 1;
    }
    if (fail) return 1;
    fprintf(stderr, "  OK: every rotated component inside the derived bound "
            "against the true rotation, the norm preserved to the "
            "orthogonality bound, the unrotated tail bit-identical, pos = 0 "
            "exact, the rounding half toward plus infinity, and both "
            "saturation rails reached\n");
    return 0;
}

#endif /* ATTN_ROPE_INCLUDE */
