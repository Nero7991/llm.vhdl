#ifndef FX_H
#define FX_H

#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

/* -----------------------------------------------------------------------
 * Static LUT storage (file-scope, filled by fx_init / fx_rope_init)
 * --------------------------------------------------------------------- */

/* rsqrt: 64-entry seed LUT over mantissa in [1,4) normalised to [0,63] */
static double  _fx_rsqrt_lut[64];

/* exp: 256-entry over z in [-16, 0], stored as doubles */
static double  _fx_exp_lut[257];   /* +1 sentinel */

/* sigmoid: 512-entry over z in [-16, 16], stored as doubles */
static double  _fx_sig_lut[513];   /* +1 sentinel */

/* rope: allocated by fx_rope_init */
#define FX_ROPE_MAX_ENTRIES (4096)   /* 512 pos * (64/2) head_dim max */
static int16_t _fx_cos_tbl[FX_ROPE_MAX_ENTRIES];
static int16_t _fx_sin_tbl[FX_ROPE_MAX_ENTRIES];
static int     _fx_rope_head_size = 0;

/* -----------------------------------------------------------------------
 * fx_init — build all LUTs; idempotent
 * --------------------------------------------------------------------- */
static inline void fx_init(void)
{
    static int done = 0;
    if (done) return;
    done = 1;

    /* rsqrt seed LUT: 64 entries covering normalised mantissa m in [1,4).
     * We map entry k -> m = 1 + k*(4-1)/64 = 1 + k*3/64.
     * seed = 1/sqrt(m). */
    for (int k = 0; k < 64; k++) {
        double m = 1.0 + k * (3.0 / 64.0);
        _fx_rsqrt_lut[k] = 1.0 / sqrt(m);
    }

    /* exp LUT: 256 entries over z in [-16, 0].
     * entry k -> z = -16 + k*(16/256) = -16 + k/16.
     * _fx_exp_lut[256] = exp(0) = 1 (sentinel). */
    for (int k = 0; k <= 256; k++) {
        double z = -16.0 + k * (16.0 / 256.0);
        _fx_exp_lut[k] = exp(z);
    }

    /* sigmoid LUT: 512 entries over z in [-16, 16].
     * entry k -> z = -16 + k*(32/512) = -16 + k/16.
     * _fx_sig_lut[512] sentinel. */
    for (int k = 0; k <= 512; k++) {
        double z = -16.0 + k * (32.0 / 512.0);
        _fx_sig_lut[k] = 1.0 / (1.0 + exp(-z));
    }
}

/* -----------------------------------------------------------------------
 * Block floating-point
 * --------------------------------------------------------------------- */

/* Quantize float vector x[n] to int16 block-fp mantissas m[n].
 * Returns exponent e: value ~= m[j] * 2^(-e).
 * Chooses largest e in [0,30] s.t. round(x[j]*2^e) fits int16. */
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
    /* find largest e in [0,30] with round(mx * 2^e) <= 32767 */
    int e = 0;
    for (int t = 30; t >= 0; t--) {
        if (lroundf(mx * (float)(1 << t)) <= 32767) { e = t; break; }
    }
    for (int j = 0; j < n; j++) {
        long r = lroundf(x[j] * (float)(1 << e));
        if (r >  32767) r =  32767;
        if (r < -32768) r = -32768;
        m[j] = (int16_t)r;
    }
    return e;
}

/* Reconstruct element j as float. */
static inline float fx_bfp_get(const int16_t *m, int e, int j)
{
    return (float)m[j] / (float)(1 << e);
}

/* -----------------------------------------------------------------------
 * Fixed-point requantisation
 * --------------------------------------------------------------------- */

/* Decompose positive float scale into (mult, shift) with mult a signed
 * 31-bit-range integer and shift in [0,31], so mult/2^shift ~= scale
 * to >= 20 fractional bits. */
static inline void fx_make_scale(float scale, int32_t *mult, int *shift)
{
    if (scale == 0.0f) { *mult = 0; *shift = 0; return; }
    /* shift = 30 - floor(log2(scale)), clamped to [0,31] */
    int s = 30 - (int)floor(log2((double)scale));
    if (s < 0) s = 0;
    if (s > 31) s = 31;
    *shift = s;
    long r = lround((double)scale * (double)(1LL << s));
    if (r >  0x7FFFFFFF) r =  0x7FFFFFFF;
    if (r < -0x7FFFFFFF) r = -0x7FFFFFFF;
    *mult = (int32_t)r;
}

/* Fixed-point requant: round(acc * mult / 2^shift), saturated to int32. */
static inline int32_t fx_scale_mul(int64_t acc, int32_t mult, int shift)
{
    int64_t p = acc * (int64_t)mult;
    int64_t r;
    if (shift == 0) {
        r = p;
    } else {
        r = (p + (1LL << (shift - 1))) >> shift;
    }
    if (r >  0x7FFFFFFF) r =  0x7FFFFFFF;
    if (r < -0x80000000LL) r = (int64_t)(-0x80000000LL);
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * Reciprocal square root — LUT seed + 2 Newton-Raphson iterations
 * --------------------------------------------------------------------- */

/* Given mean_sq_q = round(mean_sq * 2^q), return round((1/sqrt(mean_sq)) * 2^q). */
static inline int32_t fx_rsqrt(int64_t mean_sq_q, int q)
{
    if (mean_sq_q <= 0) return 0x7FFFFFFF;

    /* We want y = 1/sqrt(v) where v = mean_sq_q / 2^q.
     * Normalise v into [1,4) by finding even shift 2s:
     *   v = mantissa * 4^(-s), mantissa in [1,4)
     * Then 1/sqrt(v) = sqrt(4^s) / sqrt(mantissa) = 2^s / sqrt(mantissa).
     */
    double v = (double)mean_sq_q / (double)(1LL << q);

    /* count even right-shifts to bring v into [1,4) */
    int s = 0;
    double vn = v;
    while (vn >= 4.0) { vn /= 4.0; s++; }
    while (vn < 1.0)  { vn *= 4.0; s--; }

    /* LUT index: map vn in [1,4) -> k in [0,63] */
    int k = (int)((vn - 1.0) * (64.0 / 3.0));
    if (k < 0) k = 0;
    if (k > 63) k = 63;
    double y = _fx_rsqrt_lut[k];  /* 1/sqrt(vn_approx) */

    /* Two Newton-Raphson iterations: y = y*(3 - vn*y*y)/2 */
    y = y * (3.0 - vn * y * y) / 2.0;
    y = y * (3.0 - vn * y * y) / 2.0;

    /* Scale: 1/sqrt(v) = y * 2^(-s)
     * v = vn * 4^s, so 1/sqrt(v) = (1/sqrt(vn)) * 4^(-s/2) = y * 2^(-s). */
    double result;
    if (s >= 0) result = y / (double)(1LL << s);
    else         result = y * (double)(1LL << (-s));

    /* Convert back to Q-format */
    long r = lround(result * (double)(1LL << q));
    if (r >  0x7FFFFFFF) r =  0x7FFFFFFF;
    if (r < 0) r = 0;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * exp(z) for z <= 0, input/output Qq
 * --------------------------------------------------------------------- */

/* 256-entry LUT over z in [-16, 0], linear-interpolated. */
static inline int32_t fx_exp_q(int32_t z_q, int q)
{
    int64_t one_q = (int64_t)(1LL << q);
    int64_t lo = -16LL * one_q;

    if (z_q < (int32_t)lo) return 0;
    if (z_q > 0) z_q = 0;

    /* Map z_q into [0, 256] index range.
     * z in [-16,0]: index = (z - (-16)) / (16/256) = (z+16) * 16
     * In fixed point with q bits: index_fp = (z_q + 16*2^q) * (256/16) / 2^q
     *                                       = (z_q + 16*2^q) * 16 / 2^q
     */
    int64_t offset = (int64_t)z_q + 16LL * one_q;  /* >= 0 */
    /* index_fp = offset * 256 / (16 * 2^q) = offset * 16 / 2^q */
    int64_t idx_fp = offset * 16;  /* still has q fractional bits from one_q */
    int k = (int)(idx_fp >> q);    /* integer part */
    if (k < 0) k = 0;
    if (k > 255) k = 255;
    /* fractional part for linear interp, in [0,1) scaled to 2^q */
    int64_t frac = idx_fp - ((int64_t)k << q);  /* in [0, 2^q) */

    double lo_val = _fx_exp_lut[k];
    double hi_val = _fx_exp_lut[k + 1];
    double interp = lo_val + (hi_val - lo_val) * ((double)frac / (double)one_q);

    long r = lround(interp * (double)one_q);
    if (r < 0) r = 0;
    if (r > 0x7FFFFFFF) r = 0x7FFFFFFF;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * sigmoid(z), input/output Qq
 * --------------------------------------------------------------------- */

/* 512-entry LUT over z in [-16, 16], linear-interpolated. */
static inline int32_t fx_sigmoid_q(int32_t z_q, int q)
{
    int64_t one_q = (int64_t)(1LL << q);
    int64_t lo = -16LL * one_q;
    int64_t hi =  16LL * one_q;

    if (z_q <= (int32_t)lo) return 0;
    if (z_q >= (int32_t)hi) return (int32_t)one_q;  /* ~1.0 in Qq */

    /* Map z in [-16,16] -> index in [0,512].
     * offset = z_q + 16*2^q; step = 32*2^q / 512 = 2^q/16
     * index_fp = offset * 512 / (32 * 2^q) = offset * 16 / 2^q
     */
    int64_t offset = (int64_t)z_q + 16LL * one_q;
    int64_t idx_fp = offset * 16;   /* q fractional bits */
    int k = (int)(idx_fp >> q);
    if (k < 0) k = 0;
    if (k > 511) k = 511;
    int64_t frac = idx_fp - ((int64_t)k << q);

    double lo_val = _fx_sig_lut[k];
    double hi_val = _fx_sig_lut[k + 1];
    double interp = lo_val + (hi_val - lo_val) * ((double)frac / (double)one_q);

    long r = lround(interp * (double)one_q);
    if (r < 0) r = 0;
    if (r > (long)one_q) r = (long)one_q;
    return (int32_t)r;
}

/* -----------------------------------------------------------------------
 * RoPE cos/sin tables (Q1.15)
 * --------------------------------------------------------------------- */

/* Fill tables for seq_len positions, head_size/2 frequencies each. */
static inline void fx_rope_init(int seq_len, int head_size)
{
    _fx_rope_head_size = head_size;
    int half = head_size / 2;
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

/* Accessors: fx_cos(pos, i, head_size) -> Q1.15 cos for position pos, dim i. */
static inline int16_t fx_cos(int pos, int i, int head_size)
{
    return _fx_cos_tbl[pos * (head_size / 2) + i / 2];
}

static inline int16_t fx_sin(int pos, int i, int head_size)
{
    return _fx_sin_tbl[pos * (head_size / 2) + i / 2];
}

#endif /* FX_H */
