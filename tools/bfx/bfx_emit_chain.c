/* bfx_emit_chain -- subsystem B's output emit chain, driven from f32 tensors.
 *
 * WHAT IT IS.  Sites 12, F1 and 13 of subsystem B, i.e. the whole per-block
 * emit chain:
 *
 *     head emit (BFP requantize of the recurrence output)
 *       -> rmsnorm_bf   (the output norm, WITH the epsilon)
 *       -> gdn_silu     (the z gate)
 *       -> gated product and the per-card head fold onto one y_exp
 *
 * This is ref/gdn_emit_chain_vec.c's scope.  The difference is the driver: that
 * file drives the chain from a random-number generator, this one drives it from
 * the real activations of a running Qwen3.8-27B forward pass, which is the only
 * thing that can price the FORMAT rather than the transcription.
 *
 * THE CORES ARE INCLUDED, NOT TRANSCRIBED.  rmsnorm_bf_vec.c and gdn_silu_vec.c
 * are #included with GDN_CHAIN_INCLUDE, the same mechanism gdn_emit_chain_vec.c
 * uses.  Copying their arithmetic here would create a second, drifting
 * definition of the recipe whose divergence nothing would notice.
 *
 * THE TRAP THAT COMES WITH THAT MECHANISM.  Guarding out main() also guards out
 * every setup call main() was making.  When gdn_emit_chain_vec.c first included
 * rmsnorm_bf_vec.c, M_EPS stayed 0 -- an epsilon of ZERO, silently -- and when
 * it included gdn_silu_vec.c the sigmoid table was all zeros.  Both produced
 * confident wrong numbers rather than errors.  bfx_init() therefore calls BOTH
 * setup functions and then ASSERTS that each one actually took effect, on the
 * principle that a check which cannot fail is not a check.
 *
 * TWO PATHS, ON PURPOSE.
 *   bfx_emit_chain_fx()  the integer recipe, the thing under test.
 *   bfx_emit_chain_dbl() the same chain in double, from the same f32 inputs,
 *                        sharing no integer helper.
 * The second is not decoration.  Substituted into the forward pass it must
 * reproduce the unmodified perplexity; if it does not, the fault is in this
 * file's understanding of the tensor layout or of the chain's structure, and
 * every fixed-point number measured through it would be that fault plus the
 * format.  A wrong head stride produces a plausible, wrong perplexity.
 */

#define GDN_CHAIN_INCLUDE
#include "../../ref/rmsnorm_bf_vec.c"
#include "../../ref/gdn_silu_vec.c"

#include <assert.h>

/* -------------------------------------------------------------- setup */

/* rmsnorm_bf_vec.c keeps N, Q and EPS as file-scope statics and resolves the
 * epsilon in bf_resolve_eps().  They are reachable from here because this file
 * IS that translation unit after the include. */
void bfx_init(int n, int q, double eps)
{
    N   = n;
    Q   = q;
    EPS = eps;

    bf_resolve_eps();       /* sets E_EPS and M_EPS; skipping it means eps = 0 */
    fx_init();              /* fills _fx_sig_lut_q; skipping it means sigma = 0 */

    /* Assert the setup actually happened.  Both failure modes above are silent
     * and both have already occurred once in this project. */
    if (M_EPS == 0) {
        fprintf(stderr, "bfx_init: M_EPS is 0 -- epsilon resolved to ZERO\n");
        abort();
    }
    if (_fx_sig_lut_q[256] == 0 || _fx_sig_lut_q[512] == 0) {
        fprintf(stderr, "bfx_init: sigmoid LUT is zero -- fx_init did not run\n");
        abort();
    }
    /* sigma(0) must be 0.5 in Q15 = 16384, +/- one LSB. */
    int32_t s0 = sigma_q15_from_q12(0);
    if (s0 < 16380 || s0 > 16388) {
        fprintf(stderr, "bfx_init: sigma_q15(0) = %d, expected ~16384\n", s0);
        abort();
    }
}

/* --------------------------------------------------- f32 -> int16 BFP */

/* The project's convention throughout subsystem B is value = mant * 2^(-e),
 * with the mantissa an int16 whose magnitude peaks just under 2^15.  Choose e
 * so that max|mant| lands in [2^14, 2^15).  An all-zero vector has no defined
 * exponent; 0 is used and the mantissas are zero, which is the identity under
 * every downstream shift.
 *
 * Returns e.  Writes n int16 mantissas. */
static int bfp_quant(const float *x, int n, int16_t *m)
{
    double mx = 0.0;
    for (int i = 0; i < n; i++) {
        double a = fabs((double)x[i]);
        if (a > mx) mx = a;
    }
    if (mx == 0.0) {
        for (int i = 0; i < n; i++) m[i] = 0;
        return 0;
    }
    int e = 14 - (int)floor(log2(mx));
    for (int i = 0; i < n; i++) {
        double v = ldexp((double)x[i], e);
        long r = lround(v);
        if (r >  32767) r =  32767;
        if (r < -32768) r = -32768;
        m[i] = (int16_t)r;
    }
    return e;
}

/* -------------------------------------------------------- the chain */

/* One token's worth of the emit chain, for HG heads that share one output
 * exponent.  On the real hardware HG is 24: 48 GDN value heads split by head
 * across two cards, and ssm_out takes one scale for the whole 24 x 128 vector.
 *
 *   o    [HG][S]  attention output, f32, the recurrence's result
 *   w    [S]      ssm_norm weight, f32
 *   z    [HG][S]  the gate, f32, PRE-silu
 *   out  [HG][S]  written
 */
void bfx_emit_chain_fx(const float *o, const float *w, const float *z,
                       int HG, int S, float *out,
                       const int16_t *wm_pre, int we_pre)
{
    enum { MAXH = 64, MAXS = 256 };
    int16_t om[MAXS], zm[MAXH][MAXS], ym[MAXH][MAXS];
    int     e_p[MAXH];
    static bf_out r;                 /* 8 KB of int16, too big for the stack */
    int16_t o_out[MAXH][MAXS];

    assert(HG <= MAXH && S <= MAXS);

    for (int h = 0; h < HG; h++) {
        /* site 12: fold the head onto one exponent as an int16 BFP vector.
         * The RTL derives e_h from the per-column accumulator exponents; here
         * the recurrence ran in f32, so the equivalent information is the
         * head's own dynamic range. */
        int e_o = bfp_quant(o + (size_t)h * S, S, om);

        /* F1: the output norm, WITH the epsilon.  This is the site the
         * 2026-08-26 magnitude window document found silently emitting zeros. */
        rmsnorm_bf_int(om, e_o, wm_pre, we_pre, &r);

        /* the z gate: quantize, then gdn_silu with the exponent PRESERVED */
        int e_z = bfp_quant(z + (size_t)h * S, S, zm[h]);
        for (int j = 0; j < S; j++) {
            int32_t xq   = to_q12((int64_t)zm[h][j], e_z);
            int32_t sig  = sigma_q15_from_q12(xq);
            int64_t sm   = round_shift((int64_t)zm[h][j] * sig, 15);
            if (sm >  32767) sm =  32767;
            if (sm < -32768) sm = -32768;
            zm[h][j] = (int16_t)sm;
        }

        for (int j = 0; j < S; j++) o_out[h][j] = r.o[j];
        e_p[h] = r.o_exp + e_z;
    }

    /* site 13: the gated product and the HG-head fold onto one y_exp. */
    int e_y_raw = e_p[0];
    for (int h = 1; h < HG; h++) if (e_p[h] < e_y_raw) e_y_raw = e_p[h];

    int64_t mx = 0;
    static int64_t pal[MAXH][MAXS];
    for (int h = 0; h < HG; h++) {
        for (int j = 0; j < S; j++) {
            int64_t p = (int64_t)o_out[h][j] * (int64_t)zm[h][j];
            int64_t a = floor_shr(p, e_p[h] - e_y_raw);
            pal[h][j] = a;
            int64_t aa = a < 0 ? -a : a;
            if (aa > mx) mx = aa;
        }
    }
    int sh = 0;
    if (mx > 0) { int mp = mv4i_msb_pos_u((uint64_t)mx); sh = mp > 14 ? mp - 14 : 0; }

    for (int h = 0; h < HG; h++) {
        for (int j = 0; j < S; j++) {
            int64_t v = round_shift(pal[h][j], sh);
            if (v >  32767) v =  32767;
            if (v < -32768) v = -32768;
            ym[h][j] = (int16_t)v;
        }
    }
    int y_exp = e_y_raw - sh;

    for (int h = 0; h < HG; h++)
        for (int j = 0; j < S; j++)
            out[(size_t)h * S + j] = (float)ldexp((double)ym[h][j], -y_exp);
    (void)w;
}

/* The same chain in double, sharing no integer helper.  Substituted into the
 * forward pass this must be neutral; it is the control that proves the layout
 * and the chain structure in this file are right before any fixed-point number
 * is believed. */
void bfx_emit_chain_dbl(const float *o, const float *w, const float *z,
                        int HG, int S, float *out)
{
    for (int h = 0; h < HG; h++) {
        const float *oh = o + (size_t)h * S;
        const float *zh = z + (size_t)h * S;
        double ss = 0.0;
        for (int j = 0; j < S; j++) ss += (double)oh[j] * (double)oh[j];
        double g = 1.0 / sqrt(ss / (double)S + EPS);
        for (int j = 0; j < S; j++) {
            double n  = (double)oh[j] * g * (double)w[j];
            double zv = (double)zh[j];
            double si = zv / (1.0 + exp(-zv));
            out[(size_t)h * S + j] = (float)(n * si);
        }
    }
}

/* Quantize the norm weight once per layer.  Exposed so the caller can hoist it
 * out of the token loop: the weight does not change between tokens and
 * requantizing it 512 times per layer would be 512 identical answers. */
int bfx_quant_weight(const float *w, int S, int16_t *wm)
{
    return bfp_quant(w, S, wm);
}
