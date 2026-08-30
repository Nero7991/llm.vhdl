/* ref/attn_block_vec.c
 *
 * Subsystem C's BLOCK-LEVEL oracle: gated grouped-query attention for one
 * layer and one token, computed end to end in fixed point, bit-exact.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS, and what it is worth.
 * =====================================================================
 *
 * Before it, subsystem C had ten unit-verified leaves and NO block-level
 * reference of any kind.  `sim/tb_attn_block.vhd` said so in its own header
 * ("WHAT IS DELIBERATELY NOT CHECKED: the VALUES") and checked seven
 * structural properties instead -- element count, handshake invariance across
 * three consumer configurations, the ordering rule, lost beats, an exponent
 * SCALING identity, the descriptor guard, and the bypass address property.
 * Every one of those is a property of the plumbing.  Correct units wired to
 * each other WRONGLY -- K and V transposed, a head misaligned, RoPE dropped,
 * the gate read from the Q half -- passes all seven, because none of them
 * looks at a number.  That is the hole this file closes.
 *
 * =====================================================================
 * INDEPENDENCE: what this oracle shares with the RTL, stated exactly.
 * =====================================================================
 *
 * It shares NO CODE.  It does not include `ref/fx.h`, it does not call any
 * `ref/attn_*_vec.c`, and it is not a composition of the per-unit references
 * in the order the RTL happens to wire them.  A composition would carry a
 * shared misunderstanding of the DATAFLOW straight through, and the dataflow
 * is exactly what is unchecked.
 *
 * The structure below is written from the MODEL definition of gated GQA
 * attention and not from `rtl/attn_block.vhd`'s phase machine:
 *
 *     for each query head qh:
 *         q  = rope(rmsnorm(x_q[qh],  q_norm_w), pos)
 *         k  = rope(rmsnorm(x_k[kvh], k_norm_w), pos)      kvh = qh / G
 *         v  = x_v[kvh]                                     no norm, no rope
 *         s  = softmax_over_positions( q . k_p / sqrt(head_dim) )
 *         o  = sum_p s_p * v_p
 *         y  = o * sigmoid(gate[qh])                        gate = 2nd half
 *
 * with the cache holding the earlier positions and the current position
 * attended from the freshly quantized record.  Which head reads which K, that
 * V is neither normed nor roped, that the gate is the SECOND half of each
 * head's wq output, that RoPE rotates only the first N_ROT dims and pairs
 * (j, j+NPAIR), that the sum runs over positions and the product over dims --
 * all of that is asserted here from the model, so an RTL that wires it
 * differently DIVERGES rather than agreeing.
 *
 * WHAT IS NECESSARILY SHARED, because bit-exactness cannot be had without it:
 * the per-site fixed-point NUMERICS.  The block does not compute attention in
 * the reals; it computes one specific fixed-point approximation of it -- a
 * block-floating quantizer, a table-interpolated exp, an online softmax with
 * grid-snapped rescaling, a restoring-divider reciprocal, a table-interpolated
 * sigmoid, and a block-floating pack.  A float oracle would not be bit-exact
 * with any of them, so each site's rounding rule, shift direction, saturation
 * rail and width is transcribed here from the C spec's site definitions (the
 * same definitions each unit's header states).  That is a real limit and it is
 * stated rather than hidden: this oracle checks the COMPOSITION, and the
 * per-site numerics remain the business of the ten unit benches, each of which
 * has its own independent double-precision oracle.
 *
 * The five constant tables are RECOMPUTED here from their defining formulas
 * with libm, not read from the rtl packages or from ref/fx.h:
 *
 *     RSQRT_ROM(k) = round(2^30 / sqrt(1 + k/64))            k = 0..63
 *     EXP_ROM(k)   = round(2^30 * exp(-16 + k/16))           k = 0..256
 *     SIG_ROM(k)   = round(2^30 / (1 + exp(16 - k/16)))      k = 0..512
 *     SIN_TBL(i)   = round(32767 * sin(2*pi*i/1024))         i = 0..1023
 *     IMROPE_W(j)  = round(2^32 * 1e7^(-j/32) / (2*pi))      j = 0..31
 *
 * so a drift between the packages and their stated generation formulas is a
 * bit-exact FAILURE on the first vector rather than a shared error.  (Checked:
 * all 1,890 entries agree with rtl/fixed_luts_pkg.vhd and rtl/imrope_pkg.vhd.)
 *
 * =====================================================================
 * THE PROCESSING ORDER IS PART OF THE NUMERIC CONTRACT.
 * =====================================================================
 *
 * The softmax is ONLINE, so the order the positions are folded in changes the
 * bits.  C spec 3.1 pins it: [cur_pos, 0, 1, ..., cur_pos-1] -- the bypassed
 * current position first, then the cache ascending.  That is a statement of
 * the algorithm, taken from the spec, and it is reproduced here.  If the RTL
 * sweeps in a different order the two disagree, which is the intended
 * behaviour of a check and not a fragility.
 *
 * ONE ALGEBRAIC SIMPLIFICATION IS MADE, and it is exact.  The RTL runs ONE
 * uniform rescale pass over the whole group whenever ANY head rises, giving
 * the heads that did not rise f = 2^Q.  round_shift(a * 2^Q, Q) = a exactly
 * for every a (the bias 2^(Q-1) is strictly less than 2^Q, so the floor adds
 * nothing), so a per-head rescale-on-rise is bit-identical.  This is the same
 * identity the array's own reference checks as an equality at site 5d.
 *
 * =====================================================================
 * USAGE
 * =====================================================================
 *
 *   attn_block_vec <outfile> [HEAD_DIM N_QH N_KVH KV_BLOCK N_ROT POS LEN SEED]
 *
 * Writes the STIMULUS and the expected output to <outfile>.  The stimulus is
 * in the file rather than recomputed in VHDL on purpose: a bench that
 * regenerated it would have two sources of truth for the inputs, and a
 * divergence between them would read as an arithmetic failure.
 *
 * =====================================================================
 * ONE TOKEN IS A FUNCTION, 2026-08-28.
 * =====================================================================
 *
 * `attn_token()` below is exactly what `main()` used to be inline; the split
 * is mechanical and the single-token output is byte-identical across it
 * (MEASURED at three geometries by md5 before and after).  It exists so that
 * `ref/attn_block_seq_vec.c` can call it once per token of a SEQUENCE with a
 * cache that is what the earlier tokens WROTE rather than a synthetic one --
 * which is the only way to check the append, and the append is what one token
 * at cur_pos = 0 can never reach.  Defining ATTN_BLOCK_VEC_NO_MAIN before
 * including this file suppresses the main() below; the arithmetic is never
 * copied, because two copies of an oracle drift and the drift is invisible.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

/* ---------------------------------------------------------------------
 * fixed widths and grids.  Every one of these is the generic attn_block
 * passes to the unit that owns the site.
 * ------------------------------------------------------------------- */
#define MANT_W 16          /* activation mantissa                       */
#define CM_W    8          /* KV cache mantissa                         */
#define ACC_W  36          /* PV accumulator                            */
#define E_W    13          /* e_p and f, u13                            */
#define S_W    26          /* the softmax denominator                   */
#define P_W    32          /* score / partial                           */
#define T_W    24          /* site 6b's t                               */
#define Y_W    24          /* site 6e's y_pre                           */
#define QG     12          /* the Q12 grid                              */
#define GQ     15          /* the sigmoid output's Q, and rope's Q       */
#define R_Q    15          /* the reciprocal's Q                        */
#define ROM_N 256          /* EXP_ROM intervals                         */
#define SIG_N 512          /* SIG_ROM intervals                         */
#define TW_TBL 1024        /* sine table entries                        */

#define LSH_CLAMP 32
#define RSH_CLAMP 32

/* ---------------------------------------------------------------------
 * the tables, recomputed from their defining formulas
 * ------------------------------------------------------------------- */
static int64_t RSQRT_ROM[64];
static int64_t EXP_ROM[ROM_N + 1];
static int64_t SIG_ROM[SIG_N + 1];
static int     SIN_TBL[TW_TBL];
static uint32_t IMROPE_W[32];

static int64_t rnd_half_away(double x)
{
    return (int64_t)llround(x);
}

static void tables_init(void)
{
    int k;
    for (k = 0; k < 64; k++)
        RSQRT_ROM[k] = rnd_half_away((1.0 / sqrt(1.0 + (double)k / 64.0))
                                     * (double)(1LL << 30));
    for (k = 0; k <= ROM_N; k++)
        EXP_ROM[k] = rnd_half_away(exp(-16.0 + (double)k * (16.0 / ROM_N))
                                   * (double)(1LL << 30));
    for (k = 0; k <= SIG_N; k++) {
        double z = -16.0 + (double)k * (32.0 / SIG_N);
        SIG_ROM[k] = rnd_half_away((1.0 / (1.0 + exp(-z)))
                                   * (double)(1LL << 30));
    }
    for (k = 0; k < TW_TBL; k++)
        SIN_TBL[k] = (int)rnd_half_away(32767.0
                        * sin(2.0 * M_PI * (double)k / (double)TW_TBL));
    for (k = 0; k < 32; k++)
        IMROPE_W[k] = (uint32_t)rnd_half_away(
            4294967296.0 * pow(1e7, -(double)k / 32.0) / (2.0 * M_PI));
}

/* ---------------------------------------------------------------------
 * the primitives every site is written in terms of.
 *
 * asr  -- arithmetic right shift, i.e. FLOOR.  C's >> on a signed value is
 *         implementation-defined for negatives before C++20/C23, so it is
 *         written as a floor divide and not relied on.
 * round_shift(v, s) = asr(v + 2^(s-1), s), i.e. round half toward +infinity.
 *         This is the ONE rounding rule this design uses, at every site.
 * msb_pos(0) = 0 is NORMATIVE, not a convenience: it is what makes an
 *         all-zero block take shift 0 rather than a left shift.
 * ------------------------------------------------------------------- */
static int64_t asr64(int64_t v, int s)
{
    if (s <= 0) return v;
    if (s >= 63) return v < 0 ? -1 : 0;
    if (v >= 0) return v >> s;
    return -(((-v) + ((1LL << s) - 1)) >> s);
}

static int64_t round_shift(int64_t v, int s)
{
    if (s <= 0) return v;
    return asr64(v + (1LL << (s - 1)), s);
}

static int msb_pos_u(uint64_t a)
{
    int p = 0, i;
    for (i = 0; i < 63; i++) if ((a >> i) & 1ULL) p = i;
    return p;
}

static int64_t sat_to(int64_t v, int w)
{
    int64_t hi = (1LL << (w - 1)) - 1, lo = -(1LL << (w - 1));
    if (v > hi) return hi;
    if (v < lo) return lo;
    return v;
}

static int clog2i(int n)
{
    int r = 0;
    while ((1 << r) < n) r++;
    return r;
}

/* ---------------------------------------------------------------------
 * SITE: RMSNorm, block-floating in and out.
 *
 * From the definition:  o[i] = x[i] * w[i] / sqrt(mean(x^2)), with the whole
 * vector renormalised onto one int16 grid afterwards.  In fixed point:
 *
 *   S        = sum x[i]^2                                  exact
 *   msq      = (S << Q + N/2) >> log2(N)                   the mean, Qq
 *   msq      = msq scaled by 2^(-2*x_exp), clamped to >= 1
 *   inv      = rsqrt(msq)                                  Q(Q), s32
 *   raw[i]   = (x[i] * inv) * w[i]                          exact in s64
 *   st       = max(0, msb_pos(max|raw|) - (16-2))
 *   o[i]     = sat16(round_shift(raw[i], st))
 *   o_exp    = x_exp + w_exp + Q - st
 *
 * The rsqrt is a Q30 seed table plus TWO Newton iterations, y <- y*(3-m*y^2)/2,
 * with the odd-exponent half-power folded through 1/sqrt(2) in Q30.
 * ------------------------------------------------------------------- */
static int32_t rms_rsqrt(int64_t msq, int q)
{
    uint64_t A;
    int p, k, d, he, E, sh;
    int64_t mant, smant, y, y2, my2, diff, yfin, r;

    if (msq < 1) msq = 1;
    A = (uint64_t)msq;
    p = msb_pos_u(A);
    mant = (p <= 30) ? (int64_t)(A << (30 - p)) : (int64_t)(A >> (p - 30));
    smant = mant & 0xFFFFFFFFLL;
    y = RSQRT_ROM[(mant >> 24) & 63];
    for (k = 0; k < 2; k++) {
        y2   = asr64(y * y, 30);
        my2  = asr64(smant * y2, 30);
        diff = (3LL << 30) - my2;
        y    = asr64(diff * y, 31);
    }
    d = p - q;
    /* VHDL `mod` returns the sign of the right operand, so d mod 2 is never
     * negative.  C's % is not, hence the fold.  (d-1) and d are both EVEN on
     * the branch that divides them, so truncation and floor coincide. */
    if (((d % 2) + 2) % 2 != 0) {
        yfin = asr64(y * 759250125LL, 30);      /* 2^30 / sqrt(2) */
        he   = (d - 1) / 2;
    } else {
        yfin = y;
        he   = d / 2;
    }
    E = q - 30 - he;
    if (E > 32)      r = 2147483647LL;
    else if (E >= 0) r = yfin << E;
    else             r = asr64(yfin + (1LL << (-E - 1)), -E);
    if (r > 2147483647LL) r = 2147483647LL;
    if (r < 0)            r = 0;
    return (int32_t)r;
}

static int rmsnorm(const int *x, const int *w, int n, int x_exp, int w_exp,
                   int q, int *o)
{
    int64_t S = 0, num, msq, bias, sum, shifted, mx = 0, raw;
    int i, sh, st, msb, up;

    for (i = 0; i < n; i++) S += (int64_t)x[i] * (int64_t)x[i];
    num = S << q;
    msq = asr64(num + (int64_t)(n / 2), clog2i(n));
    if (x_exp >= 0) { up = 0; sh = 2 * x_exp;    if (sh > 62) sh = 62; }
    else            { up = 1; sh = -(2 * x_exp); if (sh > 62) sh = 62; }
    bias    = (up || sh == 0) ? 0 : (1LL << (sh - 1));
    sum     = msq + bias;
    shifted = up ? (msq << sh) : asr64(sum, sh);
    msq     = (shifted < 1) ? 1 : shifted;

    {
        int32_t inv = rms_rsqrt(msq, q);
        int64_t p1;
        for (i = 0; i < n; i++) {
            p1  = (int64_t)x[i] * (int64_t)inv;
            raw = p1 * (int64_t)w[i];
            if (raw < 0 ? (-raw > mx) : (raw > mx)) mx = raw < 0 ? -raw : raw;
        }
        msb = msb_pos_u((uint64_t)mx);
        st  = msb - (MANT_W - 2);
        if (st < 0) st = 0;
        for (i = 0; i < n; i++) {
            p1  = (int64_t)x[i] * (int64_t)inv;
            raw = p1 * (int64_t)w[i];
            o[i] = (int)sat_to(round_shift(raw, st), MANT_W);
        }
    }
    return x_exp + w_exp + q - st;
}

/* ---------------------------------------------------------------------
 * SITE: the IMROPE twiddle, and the rotation.
 *
 * The phase is TURNS in u32, so the angle reduction is the natural wrap of a
 * 32-bit product and there is no range reduction.  cos is the SAME lookup a
 * quarter turn along, which is exact in binary.
 *
 * Only the first N_ROT dims rotate, and the pairing is (j, j+NPAIR) -- halves,
 * not adjacent elements.  Qwen3.5/3.8 is GGML_ROPE_TYPE_IMROPE, which
 * dispatches through rotate_pairs(n_dims, n_dims/2), so pairing adjacent
 * elements is a DIFFERENT rotation and not a relabelling.
 * ------------------------------------------------------------------- */
static void twiddle(int pos, int npair, int *cs, int *sn)
{
    const int idx_w = 10, fracw = 32 - 10;   /* TBL = 1024 */
    int j;
    for (j = 0; j < npair; j++) {
        uint32_t phi = (uint32_t)((uint64_t)(uint32_t)pos
                                  * (uint64_t)IMROPE_W[j]);
        uint32_t phc = phi + (1u << 30);
        uint32_t is = phi >> fracw, fs = phi & ((1u << fracw) - 1u);
        uint32_t ic = phc >> fracw, fc = phc & ((1u << fracw) - 1u);
        int64_t ds = (int64_t)SIN_TBL[(is + 1) & (TW_TBL - 1)]
                   - (int64_t)SIN_TBL[is];
        int64_t dc = (int64_t)SIN_TBL[(ic + 1) & (TW_TBL - 1)]
                   - (int64_t)SIN_TBL[ic];
        (void)idx_w;
        sn[j] = (int)((int64_t)SIN_TBL[is] + asr64(ds * (int64_t)fs, fracw));
        cs[j] = (int)((int64_t)SIN_TBL[ic] + asr64(dc * (int64_t)fc, fracw));
    }
}

static void rope(const int *x, int n, int n_rot, int pos, int *y)
{
    int npair = n_rot / 2, j, i;
    int cs[512], sn[512];
    twiddle(pos, npair, cs, sn);
    for (i = 0; i < n; i++) y[i] = x[i];
    for (j = 0; j < npair; j++) {
        int64_t x0 = x[j], x1 = x[j + npair];
        int64_t c = cs[j], s = sn[j];
        y[j]         = (int)sat_to(round_shift(x0 * c - x1 * s, GQ), MANT_W);
        y[j + npair] = (int)sat_to(round_shift(x0 * s + x1 * c, GQ), MANT_W);
    }
}

/* ---------------------------------------------------------------------
 * SITE: the KV-cache block-floating quantizer.
 *
 *   amax[b] = max |x[d]| over the block
 *   sh[b]   = max(0, msb_pos(amax[b]) - (CM_W - 2))
 *   mant[d] = sat8(round_shift(x[d], sh[b]))
 *   e[b]    = src_exp - sh[b]
 * ------------------------------------------------------------------- */
static void kv_quant(const int *x, int n, int kvblk, int src_exp,
                     int *mant, int *e)
{
    int nblk = n / kvblk, b, t, sh_max = MANT_W - 1 - (CM_W - 2);
    for (b = 0; b < nblk; b++) {
        int64_t amax = 0;
        int sh;
        for (t = 0; t < kvblk; t++) {
            int64_t a = x[b * kvblk + t];
            if (a < 0) a = -a;
            if (a > amax) amax = a;
        }
        sh = msb_pos_u((uint64_t)amax) - (CM_W - 2);
        if (sh < 0) sh = 0;
        if (sh > sh_max) sh = sh_max;
        e[b] = src_exp - sh;
        for (t = 0; t < kvblk; t++)
            mant[b * kvblk + t] =
                (int)sat_to(round_shift(x[b * kvblk + t], sh), CM_W);
    }
}

/* ---------------------------------------------------------------------
 * SITE: score alignment and the Q12 conversion.
 *
 *   e_min     = min over b of e_k[b]
 *   score     = sum over b of ( partial[b] asr (e_k[b] - e_min) )
 *   score_exp = q_exp + e_min + KQ_SHIFT           kq_scale = 2^-KQ_SHIFT
 *   sh        = score_exp - Q
 *   score_q12 = round_shift(score, sh)     sh >= 0
 *             = sat32(score << -sh)        sh <  0
 * ------------------------------------------------------------------- */
static int64_t score_q12(const int64_t *partial, const int *e_k, int nblk,
                         int q_exp, int kq_sh)
{
    int b, emin = e_k[0], sexp, sv;
    int64_t acc = 0, score;
    for (b = 1; b < nblk; b++) if (e_k[b] < emin) emin = e_k[b];
    for (b = 0; b < nblk; b++) {
        int s = e_k[b] - emin;
        if (s < 0) s = 0;
        if (s > 63) s = 63;
        acc += asr64(partial[b], s);
    }
    score = sat_to(acc, P_W);
    sexp  = q_exp + emin + kq_sh;
    if (sexp < QG) {
        sv = QG - sexp;
        if (sv > LSH_CLAMP) sv = LSH_CLAMP;
        return sat_to(score << sv, P_W);
    }
    sv = sexp - QG;
    if (sv > RSH_CLAMP) sv = RSH_CLAMP;
    return sat_to(round_shift(score, sv), P_W);
}

/* ---------------------------------------------------------------------
 * SITE: the exp cone.  exp(z) for z <= 0, Q12 in, u13 out, from a Q30 table
 * over [-16, 0] on a 1/16 grid with integer linear interpolation and a FLOOR
 * on the interpolation, a ROUND on the output rescale.
 * ------------------------------------------------------------------- */
static int64_t exp_cone(int64_t z)
{
    const int grid_sh = 8, idx_w = 8, cone_sh = 30 - QG;
    int64_t off, lo, hi, dlt, prod, intv, sum;
    int idx;
    int64_t frac;

    if (z <= -16LL * (1LL << QG)) return 0;
    if (z > 0) z = 0;
    off = z + 16LL * (1LL << QG);
    if (off & (1LL << 16)) {          /* off == 16*2^Q exactly, i.e. z == 0 */
        idx  = ROM_N - 1;
        frac = 1LL << QG;
    } else {
        idx  = (int)((off >> grid_sh) & ((1 << idx_w) - 1));
        frac = (off & ((1LL << grid_sh) - 1)) << (QG - grid_sh);
    }
    lo   = EXP_ROM[idx];
    hi   = EXP_ROM[idx + 1];
    dlt  = hi - lo;
    prod = dlt * frac;
    intv = lo + (prod >> QG);
    sum  = intv + (1LL << (cone_sh - 1));
    return (sum >> cone_sh) & ((1LL << E_W) - 1);
}

/* ---------------------------------------------------------------------
 * SITE: the sigmoid cone.  Q30 table over [-16, 16] on a 1/16 grid, both ends
 * REACHED by real data, output clamped to Q15 [0, 32767].
 * ------------------------------------------------------------------- */
static int64_t sig_cone(int64_t z)
{
    const int grid_sh = 8, idx_w = 9, cone_sh = 30 - GQ, g15_max = (1 << GQ) - 1;
    int64_t off, lo, hi, dlt, prod, intv, sum, slice;
    int idx;
    int64_t frac;

    if (z <= -16LL * (1LL << QG)) return 0;
    if (z >=  16LL * (1LL << QG)) return g15_max;
    off  = z + 16LL * (1LL << QG);
    idx  = (int)((off >> grid_sh) & ((1 << idx_w) - 1));
    frac = (off & ((1LL << grid_sh) - 1)) << (QG - grid_sh);
    lo   = SIG_ROM[idx];
    hi   = SIG_ROM[idx + 1];
    dlt  = hi - lo;
    prod = dlt * frac;
    intv = lo + (prod >> QG);
    sum  = intv + (1LL << (cone_sh - 1));
    slice = (sum >> cone_sh) & ((1LL << (GQ + 1)) - 1);
    if (slice > g15_max) slice = g15_max;
    return slice;
}

/* ---------------------------------------------------------------------
 * SITE: the reciprocal.  p = msb_pos(s), r = floor(2^(p+R_Q) / s).
 * ------------------------------------------------------------------- */
static void recip(int64_t s, int *p_out, int64_t *r_out)
{
    int p;
    int64_t r;
    if (s == 0) { *p_out = 0; *r_out = 0; return; }
    p = msb_pos_u((uint64_t)s);
    r = (1LL << (p + R_Q)) / s;
    if (r > 65535) r = 65535;
    *p_out = p;
    *r_out = r;
}

/* =====================================================================
 * the stimulus.  A function of the index and nothing else.
 * =================================================================== */
static uint32_t hsh(int a, int b)
{
    uint64_t t;
    uint32_t x;
    t = (uint64_t)(uint32_t)(a % 1048576) * 1103515245ULL;
    x = (uint32_t)t + (uint32_t)((b % 100000) * 12345);
    x ^= x >> 15;
    t = (uint64_t)x * 668265261ULL;
    x = (uint32_t)t;
    x ^= x >> 13;
    return x;
}
static int m12(int a, int b) { return (int)(hsh(a, b) & 0xFFF) - 2048; }

/* =====================================================================
 * ONE TOKEN.
 *
 * This is the whole of the model: it was inline in main() until 2026-08-28
 * and the split is mechanical.  It reads the cache at (h * CSTRIDE + pos),
 * folds this token's own record into the caller's running `vref`, optionally
 * generates a synthetic cache (single-token mode) and optionally APPENDS the
 * record it just wrote at position CPOS (sequence mode).  `vref` is NOT reset
 * here: it is a per-SEQUENCE minimum and resetting it per token is C spec
 * 2.1.4's silent-truncation failure.
 * =================================================================== */
static void attn_token(int N, int N_QH, int N_KVH, int KVB, int N_ROT,
                       int CPOS, int SEED,
                       const int *qg, const int *kin, const int *vin,
                       const int *qnw, const int *knw,
                       int qg_exp, int kin_exp, int vin_exp,
                       int qn_exp, int kn_exp,
                       int synth, int append, int CSTRIDE,
                       int *ckm, int *ckh, int *cvm, int *cvh,
                       int *vref, int *ymant, int *yexp_out)
{
    int NBLK  = N / KVB;
    int G     = N_QH / N_KVH;
    int AW_D  = clog2i(N);
    int KQ_SH = AW_D / 2;
    int NPOS  = CPOS + 1;                 /* positions attended over */
    int NY    = N_QH * N;
    int *ypre = malloc(sizeof(int) * NY);
    int h, p, d, g, b, t, i;

    /* ---------------------------------------------------------------
     * The per-head fixed-point pipeline, in model order.
     * ------------------------------------------------------------- */
    {
        int *tmp   = malloc(sizeof(int) * N);
        int *tmp2  = malloc(sizeof(int) * N);
        int *kcm   = malloc(sizeof(int) * N_KVH * N);   /* current K record */
        int *kce   = malloc(sizeof(int) * N_KVH * NBLK);
        int *vcm   = malloc(sizeof(int) * N_KVH * N);   /* current V record */
        int *vce   = malloc(sizeof(int) * N_KVH * NBLK);
        int *qrot  = malloc(sizeof(int) * N_QH * N);
        int *qexp  = malloc(sizeof(int) * N_QH);
        int64_t *acc = malloc(sizeof(int64_t) * N_QH * N);

        for (h = 0; h < N_KVH; h++) {
            int koe;
            /* K: normed, roped, quantized.  The exponent chain is
             * k_norm_exp = the NORM's output exponent, never k_exp. */
            koe = rmsnorm(kin + h * N, knw, N, kin_exp, kn_exp, QG, tmp);
            rope(tmp, N, N_ROT, CPOS, tmp2);      /* rope preserves the exp */
            kv_quant(tmp2, N, KVB, koe, kcm + h * N, kce + h * NBLK);

            /* V: NEITHER normed NOR roped.  v_norm_exp = v_exp. */
            kv_quant(vin + h * N, N, KVB, vin_exp, vcm + h * N, vce + h * NBLK);

            /* v_ref is a MINIMUM folded per (layer, KV head) over every record
             * written for this SEQUENCE, initialised to +127 by the caller
             * and NOT reset per token.  This job writes exactly one record
             * per KV head and folds it in here, at write time, before the
             * sweep reads anything -- which is the order rtl/attn_block.vhd's
             * P_VQW uses and the reason the append-only invariant
             * e_v[b] >= v_ref holds for every earlier record too. */
            for (b = 0; b < NBLK; b++)
                if (vce[h * NBLK + b] < vref[h]) vref[h] = vce[h * NBLK + b];
        }

        /* THE APPEND.  The record this token writes IS what the next token
         * reads back, so in sequence mode it goes into the cache at CPOS --
         * from the quantized values, never from the pre-quantization int16,
         * because the reference attends over the quantized cache. */
        if (append) {
            for (h = 0; h < N_KVH; h++) {
                for (d = 0; d < N; d++) {
                    ckm[(h * CSTRIDE + CPOS) * N + d] = kcm[h * N + d];
                    cvm[(h * CSTRIDE + CPOS) * N + d] = vcm[h * N + d];
                }
                for (b = 0; b < NBLK; b++) {
                    ckh[(h * CSTRIDE + CPOS) * NBLK + b] = kce[h * NBLK + b];
                    cvh[(h * CSTRIDE + CPOS) * NBLK + b] = vce[h * NBLK + b];
                }
            }
        }

        /* Q heads: normed with the Q norm weights and roped.  Head qh reads
         * qg[2*N*qh .. +N); its GATE is the SECOND half, qg[.. +N .. +2N). */
        for (i = 0; i < N_QH; i++) {
            qexp[i] = rmsnorm(qg + 2 * N * i, qnw, N, qg_exp, qn_exp, QG, tmp);
            rope(tmp, N, N_ROT, CPOS, qrot + i * N);
        }

        /* The cache for positions 0..CPOS-1.
         *
         * SYNTHETIC (synth != 0, the single-token generator).  The K headers
         * are generated near the current record's own exponents so the score
         * alignment is exercised rather than annihilated; the V headers are
         * generated at or ABOVE v_ref, which is the append-only invariant the
         * site-3 shift depends on (e_v[b] >= v_ref makes the alignment
         * unconditionally a right shift).
         *
         * REAL (synth == 0, the sequence generator).  The caller has already
         * put the records the earlier tokens WROTE there, and the same
         * invariant then holds for a reason rather than by construction:
         * v_ref only ever decreases, so every record written before this one
         * has e_v[b] >= the current v_ref. */
        if (synth) {
            for (h = 0; h < N_KVH; h++) {
                int kbase = kce[h * NBLK];
                for (b = 1; b < NBLK; b++)
                    if (kce[h * NBLK + b] < kbase) kbase = kce[h * NBLK + b];
                for (p = 0; p < CPOS; p++) {
                    for (d = 0; d < N; d++) {
                        ckm[(h * CPOS + p) * N + d] =
                            (int)(hsh(9001 + SEED, (h * CPOS + p) * N + d) & 0xFF) - 128;
                        cvm[(h * CPOS + p) * N + d] =
                            (int)(hsh(9007 + SEED, (h * CPOS + p) * N + d) & 0xFF) - 128;
                    }
                    for (b = 0; b < NBLK; b++) {
                        ckh[(h * CPOS + p) * NBLK + b] =
                            kbase + (int)(hsh(9011 + SEED,
                                              (h * CPOS + p) * NBLK + b) % 3u);
                        cvh[(h * CPOS + p) * NBLK + b] =
                            vref[h] + (int)(hsh(9013 + SEED,
                                                (h * CPOS + p) * NBLK + b) % 4u);
                    }
                }
            }
        }

        /* ----------------------------------------------------------
         * The sweep.  One online softmax per query head; the PROCESSING
         * ORDER is [cur_pos, 0, 1, ..., cur_pos-1] (C spec 3.1).
         * -------------------------------------------------------- */
        {
            int64_t *sden = malloc(sizeof(int64_t) * N_QH);
            int64_t *mg   = malloc(sizeof(int64_t) * N_QH);
            int     *first= malloc(sizeof(int) * N_QH);
            const int GRID_CNT = 16 * (1 << QG) / ROM_N;
            const int GRID_SH  = 8;

            for (i = 0; i < N_QH * N; i++) acc[i] = 0;
            for (i = 0; i < N_QH; i++) { sden[i] = 0; mg[i] = 0; first[i] = 1; }

            for (h = 0; h < N_KVH; h++) {
                for (i = 0; i < NPOS; i++) {
                    int pos = (i == 0) ? CPOS : (i - 1);
                    const int *kmant, *vmant;
                    const int *kexp,  *vexp;
                    if (pos == CPOS) {
                        kmant = kcm + h * N;      kexp = kce + h * NBLK;
                        vmant = vcm + h * N;      vexp = vce + h * NBLK;
                    } else {
                        kmant = ckm + (h * CSTRIDE + pos) * N;
                        kexp  = ckh + (h * CSTRIDE + pos) * NBLK;
                        vmant = cvm + (h * CSTRIDE + pos) * N;
                        vexp  = cvh + (h * CSTRIDE + pos) * NBLK;
                    }

                    for (g = 0; g < G; g++) {
                        int qh = h * G + g;      /* GQA: contiguous grouping */
                        int64_t partial[4096], sc, ceilv, dd, kk, ff, z, ep;

                        /* the score: one dot product per exponent block */
                        for (b = 0; b < NBLK; b++) {
                            int64_t s = 0;
                            for (t = 0; t < KVB; t++)
                                s += (int64_t)qrot[qh * N + b * KVB + t]
                                   * (int64_t)kmant[b * KVB + t];
                            partial[b] = s;
                        }
                        sc = score_q12(partial, kexp, NBLK, qexp[qh], KQ_SH);

                        /* the online maximum, snapped UP to the ROM grid */
                        ceilv = (sc + (GRID_CNT - 1)) & ~(int64_t)(GRID_CNT - 1);
                        if (first[qh]) {
                            mg[qh] = ceilv; first[qh] = 0;
                        } else if (ceilv > mg[qh]) {
                            dd = ceilv - mg[qh];
                            kk = dd >> GRID_SH;
                            ff = (kk <= ROM_N)
                               ? round_shift(EXP_ROM[ROM_N - kk], 30 - QG)
                               : 0;
                            /* the rescale reaches the denominator AND every
                             * accumulator of this head, and it runs BEFORE the
                             * position's PV.  Heads that did not rise ride the
                             * same pass with f = 2^Q, which is an exact
                             * identity, so a per-head rescale is bit-identical
                             * to the block's uniform pass. */
                            sden[qh] = round_shift(sden[qh] * ff, QG);
                            for (d = 0; d < N; d++)
                                acc[qh * N + d] =
                                    sat_to(round_shift(acc[qh * N + d] * ff, QG),
                                           ACC_W);
                            mg[qh] = ceilv;
                        }
                        z  = sc - mg[qh];
                        ep = exp_cone(z);
                        sden[qh] += ep;
                        if (sden[qh] > (1LL << S_W) - 1)
                            sden[qh] = (1LL << S_W) - 1;

                        /* PV: o[d] += e_p * v_aligned[d], where the V block is
                         * aligned onto v_ref by an UNCONDITIONAL right shift. */
                        for (b = 0; b < NBLK; b++) {
                            int s = vexp[b] - vref[h];
                            if (s < 0) s = 0;
                            if (s > CM_W) s = CM_W;
                            for (t = 0; t < KVB; t++) {
                                int64_t va = asr64(vmant[b * KVB + t], s);
                                d = b * KVB + t;
                                acc[qh * N + d] =
                                    sat_to(acc[qh * N + d] + ep * va, ACC_W);
                            }
                        }
                    }
                }
            }

            /* ------------------------------------------------------
             * The output stage, per query head.
             * ---------------------------------------------------- */
            for (h = 0; h < N_KVH; h++) {
                for (g = 0; g < G; g++) {
                    int qh = h * G + g, pp, shv, is_left, lsh = 0, rsh = 0;
                    int64_t r;
                    recip(sden[qh], &pp, &r);
                    shv = qg_exp - QG;
                    if (shv < 0) { is_left = 1; lsh = -shv;
                                   if (lsh > LSH_CLAMP) lsh = LSH_CLAMP; }
                    else         { is_left = 0; rsh = shv;
                                   if (rsh > MANT_W) rsh = MANT_W; }
                    for (d = 0; d < N; d++) {
                        int64_t o = acc[qh * N + d];
                        int64_t tt = sat_to(round_shift(o * r, pp + 1), T_W);
                        int64_t gm = qg[2 * N * qh + N + d];   /* the GATE half */
                        int64_t z  = is_left ? (gm << lsh) : round_shift(gm, rsh);
                        int64_t g15, yv;
                        z = sat_to(z, 32);
                        g15 = sig_cone(z);
                        yv  = sat_to(round_shift(tt * g15, GQ), Y_W);
                        ypre[h * G * N + g * N + d] = (int)yv;
                    }
                }
            }
        }

        /* ------------------------------------------------------------
         * SITE 6f: one block-floating grid for the whole layer output.
         * e_grid(h) = v_ref[h] + R_Q - 1.
         * ---------------------------------------------------------- */
        {
            int GRP_N = G * N, emin, shp, msb;
            int64_t amax = 0;
            int *eg = malloc(sizeof(int) * N_KVH);
            for (h = 0; h < N_KVH; h++) eg[h] = vref[h] + R_Q - 1;
            emin = eg[0];
            for (h = 1; h < N_KVH; h++) if (eg[h] < emin) emin = eg[h];
            for (i = 0; i < NY; i++) {
                int sh = eg[i / GRP_N] - emin;
                int64_t a;
                if (sh < 0) sh = 0;
                if (sh > 63) sh = 63;
                a = asr64(ypre[i], sh);
                if (a < 0) a = -a;
                if (a > amax) amax = a;
            }
            msb = msb_pos_u((uint64_t)amax);
            shp = msb - (MANT_W - 2);
            if (shp < 0) shp = 0;
            if (shp > Y_W - 1 - (MANT_W - 2)) shp = Y_W - 1 - (MANT_W - 2);
            for (i = 0; i < NY; i++) {
                int sh = eg[i / GRP_N] - emin;
                if (sh < 0) sh = 0;
                if (sh > 63) sh = 63;
                ymant[i] = (int)sat_to(round_shift(asr64(ypre[i], sh), shp),
                                       MANT_W);
            }
            *yexp_out = emin - shp;
            free(eg);
        }
        free(tmp); free(tmp2); free(kcm); free(kce); free(vcm); free(vce);
        free(qrot); free(qexp); free(acc);
    }

    free(ypre);
}

/* =====================================================================
 * main
 * =================================================================== */
#ifndef ATTN_BLOCK_VEC_NO_MAIN
int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_block_vec.txt";
    int N       = (argc > 2) ? atoi(argv[2]) : 16;    /* HEAD_DIM   */
    int N_QH    = (argc > 3) ? atoi(argv[3]) : 4;
    int N_KVH   = (argc > 4) ? atoi(argv[4]) : 2;
    int KVB     = (argc > 5) ? atoi(argv[5]) : 4;     /* KV_BLOCK   */
    int N_ROT   = (argc > 6) ? atoi(argv[6]) : 8;
    int CPOS    = (argc > 7) ? atoi(argv[7]) : 3;     /* cur_pos    */
    int CLEN    = (argc > 8) ? atoi(argv[8]) : 4;     /* ctx_len    */
    int SEED    = (argc > 9) ? atoi(argv[9]) : 0;

    int NBLK  = N / KVB;
    int G     = N_QH / N_KVH;
    int AW_D  = clog2i(N);
    int KQ_SH = AW_D / 2;
    int NPOS  = CPOS + 1;                 /* positions attended over */
    int NY    = N_QH * N;

    int *qg, *kin, *vin, *qnw, *knw;
    int qg_exp = 12, kin_exp = 11, vin_exp = 10, qn_exp = 12, kn_exp = 12;
    int *ckm, *ckh, *cvm, *cvh;           /* the cache, positions 0..CPOS-1 */
    int *ymant;
    int *vref;
    int h, i, yexp;
    int b, d, j, t;
    FILE *f;

    tables_init();

    if (N % KVB || N_QH % N_KVH || (1 << AW_D) != N || (AW_D & 1)
        || N_ROT % 2 || N_ROT > N || G < 2 || NBLK < 2 || N_KVH < 2) {
        fprintf(stderr, "attn_block_vec: illegal shape.  N_KVH >= 2 is "
                        "REQUIRED: rtl/attn_emit.vhd assigns grp <= 1 into a "
                        "range 0 to NGRP-1, so NGRP = 1 is an immediate bound "
                        "violation (worklog OI-2).\n");
        return 2;
    }

    qg  = malloc(sizeof(int) * 2 * N * N_QH);
    kin = malloc(sizeof(int) * N * N_KVH);
    vin = malloc(sizeof(int) * N * N_KVH);
    qnw = malloc(sizeof(int) * N);
    knw = malloc(sizeof(int) * N);
    ckm = malloc(sizeof(int) * N_KVH * (CPOS ? CPOS : 1) * N);
    ckh = malloc(sizeof(int) * N_KVH * (CPOS ? CPOS : 1) * NBLK);
    cvm = malloc(sizeof(int) * N_KVH * (CPOS ? CPOS : 1) * N);
    cvh = malloc(sizeof(int) * N_KVH * (CPOS ? CPOS : 1) * NBLK);
    ymant = malloc(sizeof(int) * NY);
    vref  = malloc(sizeof(int) * N_KVH);

    for (i = 0; i < 2 * N * N_QH; i++) qg[i]  = m12(7919   + SEED, i);
    for (i = 0; i < N * N_KVH; i++)    kin[i] = m12(104729 + SEED, i);

    /* ------------------------------------------------------------------
     * V: a DELIBERATE PER-BLOCK MAGNITUDE TAPER, and it is load-bearing.
     *
     * TRACK ATTNTEETH, 2026-08-30.  `vin[i] = m12(65537 + SEED, i)` for every
     * i -- which is what stood here -- draws every element uniformly on
     * [-2048, 2047], so every block of KVB elements has its peak in the top
     * binade and kv_quant() gives EVERY block of a head THE SAME EXPONENT.
     * MEASURED at the gate shape: e0 = e1 = e2 = e3 = 6 on both KV heads.
     *
     * SEAM 2's v_ref is the MINIMUM over those exponents.  A minimum over a
     * constant vector is that constant, so the fold had nothing to fold and
     * `sim/tb_attn_block.vhd`'s P8 -- the bit-exact oracle comparison, the
     * bench's headline property -- could not see ANY defect in the reduction.
     * MEASURED: five separate one-line fold mutants (drop the last tree
     * stage, drop the reduction entirely, maximum instead of minimum, drop
     * the previous-v_ref term, drop the layer index) all PASSED it.
     *
     * The taper puts every block of a head in a DIFFERENT binade, so the
     * exponents are distinct and the minimum is a unique, identified element:
     *
     *   taper(h,b) = ((NBLK-1-b) + h*(NBLK/N_KVH)) mod NBLK, capped at 4
     *   the block with taper 0 has the largest magnitude and hence, because
     *   kv_quant writes e = src_exp - sh, the SMALLEST exponent.
     *
     * The argmin therefore sits at b = NBLK-1 on head 0 and at an interior b
     * on head 1, which is why the two heads are tapered differently: a fold
     * that silently returns element 0 is caught by both, one that returns the
     * last element is caught by head 1, and one that drops the last element
     * is caught by head 0.
     *
     * WHAT THIS COSTS, stated rather than hidden: the deepest-tapered block
     * carries 2047 >> t as its peak instead of ~2047, so its INPUT has fewer
     * distinct levels.  It does NOT cost mantissa coverage, because kv_quant
     * normalises each block to CM_W bits against its own peak -- the taper
     * moves the exponent, not the packed mantissa's range.
     *
     * The cap at 4 is the exponent range: sh = msb(amax) - (CM_W-2) is
     * clamped at 0, and a 12-bit m12 draw tapered by more than 4 has
     * msb <= 6, so sh saturates and two blocks would collide.  Distinctness
     * of ALL exponents therefore holds for NBLK <= 5; uniqueness of the
     * MINIMUM holds at every NBLK, because exactly one block has taper 0.
     * Both are ASSERTED below rather than assumed.
     * ---------------------------------------------------------------- */
    for (h = 0; h < N_KVH; h++) {
        for (b = 0; b < NBLK; b++) {
            t = ((NBLK - 1 - b) + h * (NBLK / N_KVH)) % NBLK;
            if (t > 4) t = 4;
            for (d = 0; d < KVB; d++) {
                int a;
                j = h * N + b * KVB + d;
                a = m12(65537 + SEED, j);
                if (a < -2047) a = -2047;   /* keep |a| <= 2047 so that the
                                             * anchor below is the peak */
                vin[j] = a / (1 << t);      /* truncation TOWARD ZERO, so
                                             * |vin| <= 2047 >> t */
            }
            /* Anchor the block's peak so its exponent is a function of the
             * taper alone and not of the draw.  Without this the property is
             * a lucky seed, which is the defect class this whole change
             * exists to remove. */
            vin[h * N + b * KVB] = 2047 >> t;
        }
    }
    /* The norm weights are held positive and away from zero: a weight vector
     * straddling zero makes max|raw| a property of one element and turns the
     * whole comparison into a comparison of clamps. */
    for (i = 0; i < N; i++) {
        int a = m12(31337 + SEED, i); qnw[i] = (a < 0 ? -a : a) + 256;
        a = m12(51501 + SEED, i);     knw[i] = (a < 0 ? -a : a) + 256;
    }

    /* ------------------------------------------------------------------
     * The taper's PROPERTY, asserted rather than assumed.  This generator is
     * the only thing that can make `sim/tb_attn_block.vhd`'s P8 able to see a
     * defect in the SEAM 2 fold, and a stimulus that quietly stops having
     * spread would put the bench straight back to passing broken trees with
     * nothing anywhere printing a warning.  `sim/tb_attn_block.vhd`'s P9
     * checks the same property from the other side, at the write port.
     * ---------------------------------------------------------------- */
    {
        int *vm = malloc(sizeof(int) * N);
        int *ve = malloc(sizeof(int) * NBLK);
        int bad = 0;
        for (h = 0; h < N_KVH; h++) {
            int amin, nmin = 0, argmin = -1, want, ndist = 0;
            kv_quant(vin + h * N, N, KVB, vin_exp, vm, ve);
            amin = ve[0];
            for (b = 1; b < NBLK; b++) if (ve[b] < amin) amin = ve[b];
            for (b = 0; b < NBLK; b++)
                if (ve[b] == amin) { nmin++; if (argmin < 0) argmin = b; }
            for (b = 0; b < NBLK; b++) {
                int seen = 0;
                for (d = 0; d < b; d++) if (ve[d] == ve[b]) seen = 1;
                if (!seen) ndist++;
            }
            /* taper(h,b) = ((NBLK-1-b) + h*(NBLK/N_KVH)) mod NBLK, so
             * taper == 0 at b = (NBLK-1 + h*(NBLK/N_KVH)) mod NBLK. */
            want = (NBLK - 1 + h * (NBLK / N_KVH)) % NBLK;
            fprintf(stderr, "attn_block_vec: head %d v block exponents", h);
            for (b = 0; b < NBLK; b++) fprintf(stderr, " %d", ve[b]);
            fprintf(stderr, "  argmin=%d nmin=%d ndistinct=%d\n",
                    argmin, nmin, ndist);
            if (nmin != 1) {
                fprintf(stderr, "attn_block_vec: head %d has %d blocks at the "
                        "minimum exponent; the SEAM 2 fold is unobservable "
                        "with a non-unique minimum\n", h, nmin);
                bad = 1;
            }
            if (argmin != want) {
                fprintf(stderr, "attn_block_vec: head %d argmin is block %d, "
                        "the taper puts it at %d\n", h, argmin, want);
                bad = 1;
            }
            if (NBLK <= 5 && ndist != NBLK) {
                fprintf(stderr, "attn_block_vec: head %d has %d distinct "
                        "block exponents of %d; NBLK <= 5 must give all "
                        "distinct\n", h, ndist, NBLK);
                bad = 1;
            }
        }
        if (N_KVH >= 2) {
            /* the two heads must not put the minimum at the same index, or
             * every mutant that returns one fixed element is caught or missed
             * by both together and the pair adds nothing over one head. */
            int a0, a1, e0min, e1min;
            kv_quant(vin + 0 * N, N, KVB, vin_exp, vm, ve);
            e0min = ve[0]; a0 = 0;
            for (b = 1; b < NBLK; b++) if (ve[b] < e0min) { e0min = ve[b]; a0 = b; }
            kv_quant(vin + 1 * N, N, KVB, vin_exp, vm, ve);
            e1min = ve[0]; a1 = 0;
            for (b = 1; b < NBLK; b++) if (ve[b] < e1min) { e1min = ve[b]; a1 = b; }
            if (a0 == a1) {
                fprintf(stderr, "attn_block_vec: heads 0 and 1 both put the "
                        "minimum V block exponent at block %d\n", a0);
                bad = 1;
            }
        }
        free(vm); free(ve);
        if (bad) {
            fprintf(stderr, "attn_block_vec: the V taper does not hold at this "
                    "shape.  REFUSING to write a vector file that cannot "
                    "falsify the SEAM 2 fold.\n");
            return 3;
        }
    }

    /* One token, with a SYNTHETIC cache and no append.  v_ref is a per-
     * SEQUENCE fold and this generator writes one token per sequence, so its
     * initial value +127 is set here and attn_token() only folds into it. */
    for (h = 0; h < N_KVH; h++) vref[h] = 127;
    attn_token(N, N_QH, N_KVH, KVB, N_ROT, CPOS, SEED,
               qg, kin, vin, qnw, knw,
               qg_exp, kin_exp, vin_exp, qn_exp, kn_exp,
               1, 0, CPOS, ckm, ckh, cvm, cvh, vref, ymant, &yexp);


    /* ---------------------------------------------------------------
     * the vector file
     * ------------------------------------------------------------- */
    f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d %d %d\n", N, N_QH, N_KVH, KVB, N_ROT, CPOS, CLEN);
    fprintf(f, "%d %d %d %d %d\n", qg_exp, kin_exp, vin_exp, qn_exp, kn_exp);
    for (i = 0; i < 2 * N * N_QH; i++) fprintf(f, "%d ", qg[i]);  fprintf(f, "\n");
    for (i = 0; i < N * N_KVH; i++)    fprintf(f, "%d ", kin[i]); fprintf(f, "\n");
    for (i = 0; i < N * N_KVH; i++)    fprintf(f, "%d ", vin[i]); fprintf(f, "\n");
    for (i = 0; i < N; i++)            fprintf(f, "%d ", qnw[i]); fprintf(f, "\n");
    for (i = 0; i < N; i++)            fprintf(f, "%d ", knw[i]); fprintf(f, "\n");
    for (i = 0; i < N_KVH * CPOS * N; i++)    fprintf(f, "%d ", ckm[i]); fprintf(f, "\n");
    for (i = 0; i < N_KVH * CPOS * NBLK; i++) fprintf(f, "%d ", ckh[i]); fprintf(f, "\n");
    for (i = 0; i < N_KVH * CPOS * N; i++)    fprintf(f, "%d ", cvm[i]); fprintf(f, "\n");
    for (i = 0; i < N_KVH * CPOS * NBLK; i++) fprintf(f, "%d ", cvh[i]); fprintf(f, "\n");
    fprintf(f, "%d\n", yexp);
    for (i = 0; i < NY; i++) fprintf(f, "%d ", ymant[i]); fprintf(f, "\n");
    fclose(f);
    return 0;
}
#endif  /* ATTN_BLOCK_VEC_NO_MAIN */
