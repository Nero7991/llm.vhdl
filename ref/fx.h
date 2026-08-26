#ifndef FX_H
#define FX_H

#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* Fixed-point primitives for the llama.vhdl golden model.
 *
 * This header is the arithmetic oracle the Plan 3 RTL must match bit-for-bit,
 * so every RUNTIME datapath primitive (block-fp quantize, requant, rsqrt, exp,
 * sigmoid, RoPE twiddle) is integer-only. Floating point appears ONLY at
 * (a) LUT-build init below and (b) the analysis/dump boundary (fx_bfp_get and
 * the fx_bfp_from_float exponent search, which correspond to an integer
 * count-leading-zeros + arithmetic shift in hardware).
 *
 * "Qq" convention: a real value v is stored as the integer round(v * 2^q).
 */

#define FX_INV_SQRT2_Q30  (759250125LL)   /* round(2^-0.5 * 2^30) */

/* -----------------------------------------------------------------------
 * Static LUT storage (file-scope, filled by fx_init / fx_rope_init).
 * All runtime LUTs hold integers so the RTL has an exact target.
 * --------------------------------------------------------------------- */

/* rsqrt seed: 64 entries over mantissa m in [1,2); entry k -> m = 1 + k/64.
 * Stored Q30: round((1/sqrt(m)) * 2^30). */
static int64_t _fx_rsqrt_seed[64];

/* exp: 257 samples of exp(z) over z in [-16,0], stored Q30 (exp(z) in (0,1]). */
static int64_t _fx_exp_lut_q[257];

/* sigmoid: 513 samples over z in [-16,16], stored Q30 (sigmoid in (0,1)). */
static int64_t _fx_sig_lut_q[513];
static int64_t _fx_sp_lut_q[257];

/* rope tables: filled by fx_rope_init. Capacity = 512 positions * 4 freqs
 * (head_size=8 -> half=4). head_size=16 (half=8) would need 4096; guarded. */
#define FX_ROPE_MAX_ENTRIES (4096)   /* 512 pos * 8 half (head_size=16 max) */
static int16_t _fx_cos_tbl[FX_ROPE_MAX_ENTRIES];
static int16_t _fx_sin_tbl[FX_ROPE_MAX_ENTRIES];
static int     _fx_rope_head_size = 0;

/* -----------------------------------------------------------------------
 * fx_init — build all runtime LUTs from float references (init-time only);
 * idempotent.
 * --------------------------------------------------------------------- */
static inline void fx_init(void)
{
    static int done = 0;
    if (done) return;
    done = 1;

    for (int k = 0; k < 64; k++) {
        double m = 1.0 + (double)k / 64.0;              /* [1,2) */
        _fx_rsqrt_seed[k] = llround((1.0 / sqrt(m)) * (double)(1LL << 30));
    }
    for (int k = 0; k <= 256; k++) {
        double z = -16.0 + (double)k * (16.0 / 256.0);  /* [-16,0] */
        _fx_exp_lut_q[k] = llround(exp(z) * (double)(1LL << 30));
    }
    for (int k = 0; k <= 512; k++) {
        double z = -16.0 + (double)k * (32.0 / 512.0);  /* [-16,16] */
        _fx_sig_lut_q[k] = llround((1.0 / (1.0 + exp(-z))) * (double)(1LL << 30));
    }
    /* softplus correction term, log(1+exp(z)) on [-16,0]; see fx_softplus_q.
       Deliberately the SAME geometry as the exp table (257 entries, step
       1/16, Q30) so the RTL evaluates both with one interpolator. */
    for (int k = 0; k <= 256; k++) {
        double z = -16.0 + (double)k * (16.0 / 256.0);  /* [-16,0] */
        _fx_sp_lut_q[k] = llround(log1p(exp(z)) * (double)(1LL << 30));
    }
}

/* Highest set-bit index of a positive value (priority encoder in HW). */
static inline int fx_msb64(uint64_t x)
{
    int p = 0;
    while (x >>= 1) p++;
    return p;
}

/* -----------------------------------------------------------------------
 * Block floating-point: vector -> int16 mantissas + shared exponent e,
 * value ~= m[j] * 2^(-e). e may be NEGATIVE for large-magnitude vectors
 * (a right shift), so vectors above +-32767 quantize instead of saturating.
 * --------------------------------------------------------------------- */
static inline int fx_bfp_from_float(int16_t *m, const float *x, int n)
{
    float mx = 0.0f;
    for (int j = 0; j < n; j++) {
        float a = fabsf(x[j]);
        if (a > mx) mx = a;
    }
    if (mx == 0.0f) {
        for (int j = 0; j < n; j++) m[j] = 0;
        return 14;
    }
    /* largest e in [-30,30] with round(mx * 2^e) <= 32767 (e<0 => right shift) */
    int e = -30;
    for (int t = 30; t >= -30; t--) {
        double sc = (t >= 0) ? (double)mx * (double)(1LL << t)
                             : (double)mx / (double)(1LL << (-t));
        if (llround(sc) <= 32767) { e = t; break; }
    }
    for (int j = 0; j < n; j++) {
        double sc = (e >= 0) ? (double)x[j] * (double)(1LL << e)
                             : (double)x[j] / (double)(1LL << (-e));
        long r = llround(sc);
        if (r >  32767) r =  32767;
        if (r < -32768) r = -32768;
        m[j] = (int16_t)r;
    }
    return e;
}

/* Reconstruct element j as float (analysis/dump boundary). Handles e<0. */
static inline float fx_bfp_get(const int16_t *m, int e, int j)
{
    return (e >= 0) ? (float)m[j] / (float)(1LL << e)
                    : (float)m[j] * (float)(1LL << (-e));
}

/* -----------------------------------------------------------------------
 * Fixed-point requantisation.
 * --------------------------------------------------------------------- */

/* Decompose positive float scale into (mult, shift), mult in signed 31-bit
 * range and shift in [0,31], so mult/2^shift ~= scale to >= 20 fractional
 * bits. Init-time helper. Saturating for pathologically large scales. */
static inline void fx_make_scale(float scale, int32_t *mult, int *shift)
{
    if (scale <= 0.0f) { *mult = 0; *shift = 0; return; }
    int s = 30 - (int)floor(log2((double)scale));
    if (s < 0) s = 0;
    if (s > 31) s = 31;
    *shift = s;
    double val = (double)scale * (double)(1LL << s);
    long r = llround(val);
    if (r >  0x7FFFFFFF) r =  0x7FFFFFFF;   /* guards scale > ~2^(31-s) */
    if (r < -0x7FFFFFFF) r = -0x7FFFFFFF;
    *mult = (int32_t)r;
}

/* Fixed-point requant: round(acc * mult / 2^shift), saturated to int32.
 * Rounding tie-break: round half toward +infinity (add half then arithmetic
 * shift right). RTL must use the same convention. */
static inline int32_t fx_scale_mul(int64_t acc, int32_t mult, int shift)
{
    int64_t p = acc * (int64_t)mult;
    int64_t r;
    if (shift == 0) {
        r = p;
    } else {
        r = (p + (1LL << (shift - 1))) >> shift;   /* round half up (toward +inf) */
    }
    if (r >  0x7FFFFFFF)      r =  0x7FFFFFFF;
    if (r < -0x80000000LL)    r = (int64_t)(-0x80000000LL);
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * Reciprocal square root — integer Q30 seed LUT + 2 Newton-Raphson
 * iterations, all fixed point. Given mean_sq_q = round(mean_sq * 2^q),
 * returns round((1/sqrt(mean_sq)) * 2^q).
 * --------------------------------------------------------------------- */
static inline int32_t fx_rsqrt(int64_t mean_sq_q, int q)
{
    if (mean_sq_q <= 0) return 0x7FFFFFFF;

    uint64_t A = (uint64_t)mean_sq_q;         /* represents v = A / 2^q */
    int p = fx_msb64(A);                       /* A in [2^p, 2^(p+1)) */

    /* Normalise mantissa to Q30 in [1,2): bit 30 is the implicit leading 1. */
    int64_t mant_q30 = (p <= 30) ? (int64_t)(A << (30 - p))
                                 : (int64_t)(A >> (p - 30));

    /* Seed y0 (Q30) from top 6 fraction bits of the mantissa. */
    int k = (int)((mant_q30 >> 24) & 63);
    int64_t y = _fx_rsqrt_seed[k];

    /* Two Newton iterations: y = y * (3 - mant*y^2) / 2, in Q30. */
    for (int it = 0; it < 2; it++) {
        int64_t y2  = (y * y) >> 30;                 /* Q30 */
        int64_t my2 = (mant_q30 * y2) >> 30;         /* Q30, ~1 */
        int64_t three = (int64_t)3 << 30;
        y = (y * (three - my2)) >> 31;               /* *(3-my2) then /2 (>>30 then >>1) */
    }

    /* v = mant * 2^(p-q). 1/sqrt(v) = ymant * 2^(-(p-q)/2).
     * For odd (p-q) fold 2^-0.5 into the mantissa. */
    int d = p - q;
    int64_t yfin;
    int he;
    if (d & 1) {
        yfin = (y * FX_INV_SQRT2_Q30) >> 30;
        he = (d - 1) / 2;                            /* d-1 even -> exact */
    } else {
        yfin = y;
        he = d / 2;
    }

    /* result_q = yfin * 2^(q - 30 - he). */
    int E = q - 30 - he;
    int64_t r;
    if (E >= 0) {
        if (E > 32) return 0x7FFFFFFF;               /* would overflow / saturate */
        r = yfin << E;
    } else {
        int sh = -E;
        r = (yfin + (1LL << (sh - 1))) >> sh;
    }
    if (r > 0x7FFFFFFF) r = 0x7FFFFFFF;
    if (r < 0) r = 0;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * exp(z) for z <= 0, input/output Qq. 256-interval LUT, integer linear
 * interpolation (Q30 table, no float on the call path). Requires q <= 30
 * for the down-shift path (q=12 in this model).
 * --------------------------------------------------------------------- */
static inline int32_t fx_exp_q(int32_t z_q, int q)
{
    int64_t one_q = 1LL << q;
    if ((int64_t)z_q < -16LL * one_q) return 0;
    if (z_q > 0) z_q = 0;

    int64_t offset = (int64_t)z_q + 16LL * one_q;    /* [0, 16*2^q] */
    int64_t idx_fp = offset * 16;                    /* q fractional bits */
    int k = (int)(idx_fp >> q);
    if (k > 255) k = 255;
    if (k < 0)   k = 0;
    int64_t frac = idx_fp - ((int64_t)k << q);       /* [0, 2^q] */

    int64_t lo = _fx_exp_lut_q[k];
    int64_t hi = _fx_exp_lut_q[k + 1];
    int64_t interp_q30 = lo + (((hi - lo) * frac) >> q);   /* Q30 */

    int64_t r;
    if (q <= 30) {
        int sh = 30 - q;
        r = (sh > 0) ? ((interp_q30 + (1LL << (sh - 1))) >> sh) : interp_q30;
    } else {
        r = interp_q30 << (q - 30);
    }
    if (r < 0) r = 0;
    if (r > 0x7FFFFFFF) r = 0x7FFFFFFF;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * sigmoid(z), input/output Qq. 512-interval LUT, integer interpolation.
 * --------------------------------------------------------------------- */
static inline int32_t fx_sigmoid_q(int32_t z_q, int q)
{
    int64_t one_q = 1LL << q;
    if ((int64_t)z_q <= -16LL * one_q) return 0;
    if ((int64_t)z_q >=  16LL * one_q) return (int32_t)one_q;   /* ~1.0 */

    int64_t offset = (int64_t)z_q + 16LL * one_q;
    int64_t idx_fp = offset * 16;                    /* q fractional bits */
    int k = (int)(idx_fp >> q);
    if (k > 511) k = 511;
    if (k < 0)   k = 0;
    int64_t frac = idx_fp - ((int64_t)k << q);

    int64_t lo = _fx_sig_lut_q[k];
    int64_t hi = _fx_sig_lut_q[k + 1];
    int64_t interp_q30 = lo + (((hi - lo) * frac) >> q);   /* Q30 */

    int64_t r;
    if (q <= 30) {
        int sh = 30 - q;
        r = (sh > 0) ? ((interp_q30 + (1LL << (sh - 1))) >> sh) : interp_q30;
    } else {
        r = interp_q30 << (q - 30);
    }
    if (r < 0) r = 0;
    if (r > (int64_t)one_q) r = (int64_t)one_q;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * softplus(x) = log(1 + exp(x)), input/output Qq.
 *
 * Evaluated by range reduction rather than a table over the whole domain:
 *
 *     softplus(x) = max(x, 0) + log(1 + exp(-|x|))
 *
 * The correction term is confined to [-16, 0] and to (0, ln 2], so a
 * 256-interval table carries it to the same absolute accuracy a table over
 * the full range would need 576 intervals to reach.  It also makes B's
 * threshold rule (1.1(f), "x > 20 ? x : ...") fall out for free: beyond
 * |x| = 16 the correction is 1.1e-7, below the LSB of every q this model
 * uses, so softplus(x) returns exactly x with no branch on 20.
 *
 * The index arithmetic is deliberately identical to fx_exp_q's.
 * --------------------------------------------------------------------- */
static inline int32_t fx_softplus_q(int32_t x_q, int q)
{
    int64_t one_q = 1LL << q;
    int64_t ax    = (x_q < 0) ? -(int64_t)x_q : (int64_t)x_q;
    int64_t pos   = (x_q > 0) ?  (int64_t)x_q : 0;

    int64_t corr;
    if (ax >= 16LL * one_q) {
        corr = 0;                       /* below the LSB for any q <= 22 */
    } else {
        int64_t offset = (16LL * one_q) - ax;        /* z = -|x| , shifted */
        int64_t idx_fp = offset * 16;
        int k = (int)(idx_fp >> q);
        if (k > 255) k = 255;
        if (k < 0)   k = 0;
        int64_t frac = idx_fp - ((int64_t)k << q);

        int64_t lo = _fx_sp_lut_q[k];
        int64_t hi = _fx_sp_lut_q[k + 1];
        int64_t interp_q30 = lo + (((hi - lo) * frac) >> q);

        int sh = 30 - q;
        corr = (sh > 0) ? ((interp_q30 + (1LL << (sh - 1))) >> sh) : interp_q30;
    }

    int64_t r = pos + corr;
    if (r < 0) r = 0;                   /* softplus > 0 always */
    if (r > 0x7FFFFFFF) r = 0x7FFFFFFF;
    return (int32_t)r;
}


/* -----------------------------------------------------------------------
 * RoPE cos/sin tables (Q1.15). +1.0 saturates to 32767.
 * --------------------------------------------------------------------- */
static inline void fx_rope_init(int seq_len, int head_size)
{
    int half = head_size / 2;
    if ((long)seq_len * half > FX_ROPE_MAX_ENTRIES) {
        fprintf(stderr, "fx_rope_init: %d pos * %d freqs exceeds capacity %d\n",
                seq_len, half, FX_ROPE_MAX_ENTRIES);
        exit(1);
    }
    _fx_rope_head_size = head_size;
    for (int pos = 0; pos < seq_len; pos++) {
        for (int i = 0; i < head_size; i += 2) {
            double freq = 1.0 / pow(10000.0, (double)(i % head_size) / (double)head_size);
            double val  = pos * freq;
            long cv = lround(cos(val) * 32768.0);
            long sv = lround(sin(val) * 32768.0);
            if (cv >  32767) cv =  32767;
            if (cv < -32768) cv = -32768;
            if (sv >  32767) sv =  32767;
            if (sv < -32768) sv = -32768;
            int idx = pos * half + i / 2;
            _fx_cos_tbl[idx] = (int16_t)cv;
            _fx_sin_tbl[idx] = (int16_t)sv;
        }
    }
}

static inline int16_t fx_cos(int pos, int i, int head_size)
{
    return _fx_cos_tbl[pos * (head_size / 2) + i / 2];
}

static inline int16_t fx_sin(int pos, int i, int head_size)
{
    return _fx_sin_tbl[pos * (head_size / 2) + i / 2];
}

#endif /* FX_H */
