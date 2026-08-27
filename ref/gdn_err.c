/* ref/gdn_err.c -- recurrence error bound for subsystem B (Gated DeltaNet).
 *
 * Answers the gating question of
 *   docs/superpowers/specs/2026-08-21-gated-deltanet-design.md  section 2.10:
 *
 *   "The state is requantized to int16 EVERY token, and the result feeds back
 *    through the recurrence, so quantization error compounds across a sequence
 *    in a way that C's write-once KV cache never does.  Nothing in this spec
 *    bounds that error."
 *
 * The program runs the SAME recurrence three ways over the same driving
 * inputs and reports divergence as a function of token position:
 *
 *   ORACLE  double precision, state in double        -- truth
 *   FLOAT   IEEE binary32, state in float            -- the error floor of an
 *                                                       fp32 implementation,
 *                                                       so the int16 number
 *                                                       has something to be
 *                                                       compared against
 *   FIXED   exactly spec section 2.1.4, state in intW mantissas with one
 *           int8 exponent per column j              -- the thing under test
 *
 * W is a build/run-time knob (--wbits) so "if int16 is insufficient, what is
 * the minimum width that is" can be answered by measurement rather than by
 * argument.  W = 16 is the spec's format.
 *
 * WHAT IS DELIBERATELY *NOT* MEASURED HERE.  The conv1d, silu, the L2 norms,
 * softplus/sigmoid/exp and the output rmsnorm+z gate are NOT modelled.  They
 * are feed-forward: their error is per-token and cannot compound, so they are
 * section 3 per-site rounding work, not section 2.10 work.  This file isolates
 * the ONE loop in subsystem B that carries state across tokens.  By default the
 * ORACLE is fed the DEQUANTIZED FIXED-POINT INPUTS (--inq exact), so the
 * divergence reported is caused by the feedback path alone and not by input
 * quantization riding along.  --inq real feeds the oracle the true float inputs
 * instead, which adds a per-token non-compounding term; both are reported so
 * the two effects are never blurred.
 *
 * WIDTH DISCIPLINE.  Every fixed-point intermediate is int64_t and every shift
 * goes through mv4i_floor_shr / mv4i_round_shift (matvec_int4.c's generated
 * primitives, reused verbatim), because C's >> on a negative signed value is
 * implementation-defined before C23.  Bounds asserted at runtime.
 *
 * Build:  cc -O2 -Wall -Wextra -fopenmp -o gdn_err gdn_err.c -lm
 *         (OpenMP is optional; heads are independent so results are identical.)
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>

#ifdef NDEBUG
#error "gdn_err.c must be built with assertions enabled (no -DNDEBUG)"
#endif

#include "mv4i_arith.h"

#define floor_shr(v, sh)   mv4i_floor_shr((v), (sh))
#define round_shift(v, sh) mv4i_round_shift((v), (sh))
#define msb_pos_u(a)       mv4i_msb_pos_u((a))

/* ------------------------------------------------------------------ shapes */
/* Qwen3.8-27B GDN, spec section 4.  VERIFIED against the GGUF metadata of
 * /mnt/storage/llama-models/Qwen3.8-27B-Q4_K_M.gguf on 2026-08-24:
 *   qwen35.ssm.state_size     = 128   -> S   (head_k_dim = head_v_dim)
 *   qwen35.ssm.group_count    = 16    -> H_k (key heads)
 *   qwen35.ssm.time_step_rank = 48    -> H_v (value heads)
 *   qwen35.ssm.inner_size     = 6144  -> d_inner = H_v * S
 *   qwen35.ssm.conv_kernel    = 4
 *   qwen35.block_count = 64, qwen35.full_attention_interval = 4 -> 48 GDN layers
 * This closes the "GDN dims NOT verified against the GGUF" caveat of B 2.9. */
#define S_DIM   128
#define HV_MAX  48
#define HK_RATIO 3      /* 48 value heads / 16 key heads: 3 v-heads per k-head */

/* ------------------------------------------------------------------- rng */
/* splitmix64 -> xoshiro-free, deterministic, no libc rand dependence. */
static uint64_t rng_s;
static inline uint64_t rng_next(void)
{
    uint64_t z = (rng_s += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static inline double rng_u01(void)   /* [0,1) */
{
    return (double)(rng_next() >> 11) * (1.0 / 9007199254740992.0);
}
static double rng_gauss(void)
{
    static int have = 0; static double spare;
    if (have) { have = 0; return spare; }
    double u, v, s;
    do { u = 2.0*rng_u01() - 1.0; v = 2.0*rng_u01() - 1.0; s = u*u + v*v; }
    while (s >= 1.0 || s == 0.0);
    double f = sqrt(-2.0*log(s)/s);
    spare = v*f; have = 1; return u*f;
}

/* ------------------------------------------------------------------ config */
typedef struct {
    int    T;            /* tokens */
    int    HV;           /* value heads simulated */
    int    W;            /* state mantissa width, bits (16 = spec) */
    double rho_k;        /* token-to-token correlation of the k/q direction */
    double rho_v;        /* token-to-token correlation of v */
    double beta_fix;     /* if >= 0, beta held at this value; else sigmoid(N(mu,1)) */
    double beta_mu;
    double eg_fix;       /* if >= 0, eg held at this value for every head */
    int    eg_layer;     /* else: take the 48 real exp(g) of this GDN layer */
    int    eg_worst;     /* else: take the HV largest real exp(g) in the model */
    double v_scale;      /* stdev of the v channels */
    double outlier_p;    /* fraction of v channels that are 30x outliers */
    int    inq_real;     /* 1 = oracle sees true float inputs, 0 = dequantized */
    /* ---- decay-precision isolation (added 2026-08-26) --------------------
     * The 2026-08-25 bound could not see the decay factor's own quantization
     * error at all: with --inq exact the oracle is fed the SAME Q15 eg the
     * fixed path uses, so the term cancels, and --inq-real bundles it with
     * every other input.  These two knobs isolate it and nothing else.
     *   eg_bits        the number of fractional bits the decay factor is
     *                  produced with (spec 1.5: Q15; the superseded EXP_ROM
     *                  emitted Q12).  The value is still CARRIED in the Q15
     *                  field the datapath expects -- eg_q = round(eg*2^N)
     *                  << (15-N) -- so no shift in the recurrence changes and
     *                  this measures the ROM's output precision, which is
     *                  exactly what 1.5 argues about.
     *   eg_oracle_real the oracle keeps the TRUE double eg while the fixed
     *                  path gets the quantized one.  Every other input stays
     *                  exact-dequantized, so the reported divergence is the
     *                  decay term alone.  This is the control the 2026-08-25
     *                  document's open list asks for by name. */
    int    eg_bits;
    int    eg_oracle_real;
    /* ---- beta-precision isolation (added 2026-08-26, same class) ---------
     * Spec 1.5 says beta "gets the same treatment for uniformity (it scales
     * the correction term, where error is self-limiting -- Q15 is cheap
     * insurance, not a requirement; section 3 may argue it back down with an
     * error analysis)".  That error analysis had never been possible: beta's
     * oracle shares the QUANTIZED value by default, exactly the cancellation
     * that hid the decay term, and --inq-real bundles beta with k, q and v so
     * it cannot be isolated either.  These two knobs isolate beta alone, so
     * the sentence can be tested rather than inherited.
     *
     * Note the reference quantizes beta at Q16 (uint16, b * 65536), not the
     * Q15 section 1.5 describes.  That discrepancy is the spec audit's F8 and
     * is NOT resolved here; beta_bits counts fractional bits, so beta_bits=16
     * is the shipped behaviour and 15 is what the spec text says. */
    int    beta_bits;
    int    beta_oracle_real;
    int    se_init;      /* spec 2.1.4 SE_INIT (default 0, as written) */
    int    fix_init;     /* 1 = at tk=0 exclude the (zero) state from e_u's min,
                            i.e. e_u = e_kd.  Superseded by tk0_ed/eg0_ed below,
                            which subsume it; kept so the older runs reproduce. */
    /* ---- the 2026-08-26 amendment to 2.1.4, ADOPTED, all default ON -------
     * These three are the same generics carried by rtl/gdn_recur.vhd and
     * ref/gdn_recur_vec.c, with the same names and the same meaning, so this
     * file measures the recipe the spec actually specifies.  Set all three to
     * 0 (or pass --pinned) to reproduce the superseded numbers.
     *   d_norm  quantize d on its own grid instead of the pinned shift of 16
     *   tk0_ed  a masked operand's phantom exponent must not enter e_d's min
     *   eg0_ed  extend that rule from tk = 0 to eg = 0 mid-sequence, which is
     *           the same masked-operand shape and which tk0 does not flag  */
    int    d_norm;
    int    tk0_ed;
    int    eg0_ed;
    uint64_t seed;
    const char *egfile;
    const char *csv;
} cfg_t;

/* --------------------------------------------------- real exp(g) from GGUF */
static double eg_tab[64*HV_MAX]; static int eg_lay[64*HV_MAX]; static int eg_n = 0;

static void eg_load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        int L, h; double e, a, d;
        if (sscanf(line, "%d %d %lf %lf %lf", &L, &h, &e, &a, &d) == 5) {
            eg_lay[eg_n] = L; eg_tab[eg_n++] = e;
        }
    }
    fclose(f);
}
static int dcmp(const void *a, const void *b)
{ double x = *(const double*)a, y = *(const double*)b; return x < y ? 1 : x > y ? -1 : 0; }

/* --------------------------------------------------------------- BFP pack */
/* bfp_pack semantics (spec 2.1.1/2.1.3): choose the exponent from the block
 * amax so the largest mantissa lands in the top bit of the intW field. */
static int bfp_exp_for(const double *x, int n, int W)
{
    double amax = 0.0;
    for (int i = 0; i < n; i++) { double a = fabs(x[i]); if (a > amax) amax = a; }
    if (amax == 0.0) return 0;
    /* want round(amax * 2^e) <= 2^(W-1)-1 with the msb as high as possible */
    int e = (int)floor((double)(W - 1) - log2(amax)) ;
    while (llround(ldexp(amax, e)) > ((1LL << (W-1)) - 1)) e--;
    while (llround(ldexp(amax, e+1)) <= ((1LL << (W-1)) - 1)) e++;
    return e;
}
static int64_t satW(int64_t v, int W)
{
    int64_t hi = ((int64_t)1 << (W-1)) - 1, lo = -((int64_t)1 << (W-1));
    if (v > hi) return hi;
    if (v < lo) return lo;
    return v;
}

/* ------------------------------------------------------- per-head workspace */
typedef struct {
    /* FIXED state: column-major, smant[j][i], one exponent per column */
    int64_t smant[S_DIM][S_DIM];
    int     se[S_DIM];
    /* ORACLE and FLOAT states */
    double  sd[S_DIM][S_DIM];   /* [j][i] to match */
    float   sf[S_DIM][S_DIM];
    /* running metrics */
    double  err_state, nrm_state, err_out, nrm_out;
    double  abs_state;          /* ||s_fixed - s_oracle||, absolute */
    double  errf_state, errf_out;
    int     sat_events, se_range_err;
} head_t;

/* ------------------------------------------------------------------- main */
int main(int argc, char **argv)
{
    cfg_t c = { .T = 4096, .HV = 48, .W = 16, .rho_k = 0.0, .rho_v = 0.0,
                .beta_fix = -1.0, .beta_mu = 0.0, .eg_fix = -1.0, .eg_layer = -1,
                .eg_worst = 0, .v_scale = 1.0, .outlier_p = 0.0, .inq_real = 0,
                .eg_bits = 15, .eg_oracle_real = 0,
                .beta_bits = 16, .beta_oracle_real = 0,
                .se_init = 0, .fix_init = 0,
                .d_norm = 1, .tk0_ed = 1, .eg0_ed = 1, .seed = 12345,
                .egfile = "gdn_eg_qwen3_27b.txt", .csv = NULL };

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define ARG(name) (strcmp(a, name) == 0 && i+1 < argc)
        if      (ARG("--tokens"))    c.T        = atoi(argv[++i]);
        else if (ARG("--heads"))     c.HV       = atoi(argv[++i]);
        else if (ARG("--wbits"))     c.W        = atoi(argv[++i]);
        else if (ARG("--rho-k"))     c.rho_k    = atof(argv[++i]);
        else if (ARG("--rho-v"))     c.rho_v    = atof(argv[++i]);
        else if (ARG("--beta"))      c.beta_fix = atof(argv[++i]);
        else if (ARG("--beta-mu"))   { c.beta_mu = atof(argv[++i]); c.beta_fix = -1.0; }
        else if (ARG("--eg"))        c.eg_fix   = atof(argv[++i]);
        else if (ARG("--eg-layer"))  { c.eg_layer = atoi(argv[++i]); c.eg_fix = -1.0; }
        else if (strcmp(a, "--eg-worst") == 0) { c.eg_worst = 1; c.eg_fix = -1.0; }
        else if (ARG("--v-scale"))   c.v_scale  = atof(argv[++i]);
        else if (ARG("--outlier"))   c.outlier_p= atof(argv[++i]);
        else if (strcmp(a, "--inq-real") == 0)  c.inq_real = 1;
        else if (ARG("--eg-bits"))   c.eg_bits  = atoi(argv[++i]);
        else if (strcmp(a, "--eg-oracle-real") == 0) c.eg_oracle_real = 1;
        else if (ARG("--beta-bits")) c.beta_bits = atoi(argv[++i]);
        else if (strcmp(a, "--beta-oracle-real") == 0) c.beta_oracle_real = 1;
        else if (strcmp(a, "--fix-init") == 0)  c.fix_init = 1;
        else if (ARG("--d-norm"))    c.d_norm   = atoi(argv[++i]) != 0;
        else if (ARG("--tk0-ed"))    c.tk0_ed   = atoi(argv[++i]) != 0;
        else if (ARG("--eg0-ed"))    c.eg0_ed   = atoi(argv[++i]) != 0;
        else if (strcmp(a, "--pinned") == 0)
            { c.d_norm = 0; c.tk0_ed = 0; c.eg0_ed = 0; }
        else if (ARG("--se-init"))   c.se_init  = atoi(argv[++i]);
        else if (ARG("--seed"))      c.seed     = strtoull(argv[++i], NULL, 10);
        else if (ARG("--egfile"))    c.egfile   = argv[++i];
        else if (ARG("--csv"))       c.csv      = argv[++i];
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
        #undef ARG
    }
    if (c.HV > HV_MAX) { fprintf(stderr, "heads > %d\n", HV_MAX); return 2; }
    if (c.W < 8 || c.W > 32) { fprintf(stderr, "wbits out of range\n"); return 2; }
    if (c.eg_bits < 1 || c.eg_bits > 15) { fprintf(stderr, "eg-bits out of range (1..15)\n"); return 2; }
    if (c.beta_bits < 1 || c.beta_bits > 16) { fprintf(stderr, "beta-bits out of range (1..16)\n"); return 2; }

    rng_s = c.seed;
    eg_load(c.egfile);

    /* ---- per-head decay factor eg (uint16 Q15, spec 2.1.1) ---------------- */
    static double eg_real[HV_MAX]; static int64_t eg_q[HV_MAX];
    if (c.eg_fix >= 0.0) {
        for (int h = 0; h < c.HV; h++) eg_real[h] = c.eg_fix;
    } else if (c.eg_worst) {
        static double tmp[64*HV_MAX];
        memcpy(tmp, eg_tab, sizeof(double)*(size_t)eg_n);
        qsort(tmp, (size_t)eg_n, sizeof(double), dcmp);
        for (int h = 0; h < c.HV; h++) eg_real[h] = tmp[h];
    } else if (c.eg_layer >= 0) {
        int k = 0;
        for (int i = 0; i < eg_n && k < c.HV; i++)
            if (eg_lay[i] == c.eg_layer) eg_real[k++] = eg_tab[i];
        if (k < c.HV) { fprintf(stderr, "layer %d not a GDN layer\n", c.eg_layer); return 2; }
    } else {
        for (int h = 0; h < c.HV; h++) eg_real[h] = eg_tab[(int)(rng_next() % (uint64_t)eg_n)];
    }
    for (int h = 0; h < c.HV; h++) {
        /* produced at Q<eg_bits>, carried in the Q15 field the datapath uses */
        int64_t coarse = llround(eg_real[h] * (double)(1 << c.eg_bits));
        if (coarse > (1 << c.eg_bits)) coarse = (1 << c.eg_bits);
        if (coarse < 0)                coarse = 0;
        eg_q[h] = coarse << (15 - c.eg_bits);
        if (eg_q[h] > 32768) eg_q[h] = 32768;      /* uint16 Q15, 1.0 = 32768 */
        if (eg_q[h] < 0)     eg_q[h] = 0;
        /* --eg-oracle-real keeps the oracle on the TRUE eg, so the decay
         * quantization no longer cancels between the two number systems.
         * Default (and every pre-2026-08-26 run) dequantizes it for both. */
        if (!c.inq_real && !c.eg_oracle_real) eg_real[h] = (double)eg_q[h] / 32768.0;
    }

    /* ---- persistent driving-input generator state ------------------------ */
    int HK = (c.HV + HK_RATIO - 1) / HK_RATIO;   /* key heads feeding these v-heads */
    static double kraw[HV_MAX][S_DIM], qraw[HV_MAX][S_DIM], vraw[HV_MAX][S_DIM];
    static double vgain[HV_MAX][S_DIM];
    for (int hk = 0; hk < HK; hk++)
        for (int i = 0; i < S_DIM; i++) { kraw[hk][i] = rng_gauss(); qraw[hk][i] = rng_gauss(); }
    for (int h = 0; h < c.HV; h++)
        for (int j = 0; j < S_DIM; j++) {
            vraw[h][j] = rng_gauss();
            vgain[h][j] = (rng_u01() < c.outlier_p) ? 30.0 : 1.0;
        }

    static head_t H[HV_MAX];
    memset(H, 0, sizeof H);

    FILE *cf = NULL;
    if (c.csv) {
        cf = fopen(c.csv, "w");
        /* The last two columns are ABSOLUTE, not relative, and they are the
         * ones that test the "both numerator and denominator grow as sqrt(t)"
         * mechanism the 2026-08-25 bound argued for but never measured: a flat
         * RELATIVE error is equally consistent with a bounded absolute error
         * and with an absolute error growing at exactly the rate the state
         * norm grows.  Mean over heads of ||s_fixed - s_oracle|| and of
         * ||s_oracle||. */
        fprintf(cf, "t,state_rel_mean,state_rel_max,out_rel_mean,out_rel_max,"
                    "f32_state_rel_max,f32_out_rel_max,"
                    "state_abs_err_mean,state_nrm_mean\n");
    }

    printf("# gdn_err: S=%d HV=%d HK=%d W=%d T=%d\n", S_DIM, c.HV, HK, c.W, c.T);
    printf("# eg: %s", c.eg_fix >= 0 ? "fixed" : c.eg_worst ? "worst-real" :
                       c.eg_layer >= 0 ? "real-layer" : "real-random");
    { double mn = 1e30, mx = -1e30;
      for (int h = 0; h < c.HV; h++) { if (eg_real[h] < mn) mn = eg_real[h];
                                       if (eg_real[h] > mx) mx = eg_real[h]; }
      printf("  min=%.9f max=%.9f\n", mn, mx); }
    printf("# eg_bits=%d (Q%d decay) eg_oracle=%s\n", c.eg_bits, c.eg_bits,
           c.inq_real ? "real (--inq-real)"
                      : c.eg_oracle_real ? "REAL (decay error isolated)"
                                         : "quantized (decay error cancels)");
    printf("# se_init=%d fix_init=%d\n", c.se_init, c.fix_init);
    printf("# recipe: d_norm=%d tk0_ed=%d eg0_ed=%d  (%s)\n",
           c.d_norm, c.tk0_ed, c.eg0_ed,
           (c.d_norm && c.tk0_ed && c.eg0_ed) ? "2.1.4 AS AMENDED 2026-08-26"
                                              : "NON-DEFAULT, not the specified recipe");
    printf("# beta: %s%.4f   rho_k=%.3f rho_v=%.3f v_scale=%.3g outlier_p=%.3g inq=%s\n",
           c.beta_fix >= 0 ? "fixed " : "sigmoid(N(mu,1)) mu=",
           c.beta_fix >= 0 ? c.beta_fix : c.beta_mu,
           c.rho_k, c.rho_v, c.v_scale, c.outlier_p,
           c.inq_real ? "real-float-inputs" : "dequantized-fixed-inputs");
    printf("%8s %14s %14s %14s %14s %14s\n",
           "token", "state_rel_mu", "state_rel_max", "out_rel_mu", "out_rel_max",
           "fp32_out_max");

    /* per-token buffers */
    static int64_t kq[HV_MAX][S_DIM], qq[HV_MAX][S_DIM], vq[HV_MAX][S_DIM];
    static double  kd_[HV_MAX][S_DIM], qd_[HV_MAX][S_DIM], vd_[HV_MAX][S_DIM];
    static int64_t betaq[HV_MAX]; static double betad[HV_MAX];
    static int     e_v_seg;

    double ck = sqrt(1.0 - c.rho_k*c.rho_k), cv = sqrt(1.0 - c.rho_v*c.rho_v);

    for (int t = 0; t < c.T; t++) {
        /* ---------------- driving inputs for this token -------------------- */
        for (int hk = 0; hk < HK; hk++)
            for (int i = 0; i < S_DIM; i++) {
                kraw[hk][i] = c.rho_k*kraw[hk][i] + ck*rng_gauss();
                qraw[hk][i] = c.rho_k*qraw[hk][i] + ck*rng_gauss();
            }
        for (int h = 0; h < c.HV; h++)
            for (int j = 0; j < S_DIM; j++)
                vraw[h][j] = c.rho_v*vraw[h][j] + cv*rng_gauss();

        /* k: L2 normalized, Q15 (spec 2.1.1).  q: L2 normalized with the
         * 1/sqrt(128) fold, exp 18. */
        for (int hk = 0; hk < HK; hk++) {
            double nk = 0, nq = 0;
            for (int i = 0; i < S_DIM; i++) { nk += kraw[hk][i]*kraw[hk][i];
                                              nq += qraw[hk][i]*qraw[hk][i]; }
            nk = 1.0/sqrt(nk);
            nq = 1.0/sqrt(nq*(double)S_DIM);
            for (int i = 0; i < S_DIM; i++) {
                double kv = kraw[hk][i]*nk, qv = qraw[hk][i]*nq;
                kq[hk][i] = satW(llround(ldexp(kv, 15)), 16);
                qq[hk][i] = satW(llround(ldexp(qv, 18)), 16);
                kd_[hk][i] = c.inq_real ? kv : ldexp((double)kq[hk][i], -15);
                qd_[hk][i] = c.inq_real ? qv : ldexp((double)qq[hk][i], -18);
            }
        }
        /* v: ONE BFP exponent across the whole value segment (spec 2.1.3's
         * per-segment requantizer), not per head. */
        {
            static double vall[HV_MAX*S_DIM];
            for (int h = 0; h < c.HV; h++)
                for (int j = 0; j < S_DIM; j++)
                    vall[h*S_DIM+j] = vraw[h][j]*vgain[h][j]*c.v_scale;
            e_v_seg = bfp_exp_for(vall, c.HV*S_DIM, 16);
            for (int h = 0; h < c.HV; h++)
                for (int j = 0; j < S_DIM; j++) {
                    double x = vall[h*S_DIM+j];
                    vq[h][j] = satW(llround(ldexp(x, e_v_seg)), 16);
                    vd_[h][j] = c.inq_real ? x : ldexp((double)vq[h][j], -e_v_seg);
                }
        }
        for (int h = 0; h < c.HV; h++) {
            double b = c.beta_fix >= 0.0 ? c.beta_fix
                                         : 1.0/(1.0 + exp(-(c.beta_mu + rng_gauss())));
            /* Produced with beta_bits fractional bits, then carried in the
             * Q16 field the datapath expects, so no shift downstream changes
             * and this measures the PRODUCER's precision -- which is what
             * section 1.5's claim is about. */
            int64_t bq;
            if (c.beta_bits >= 16) {
                bq = llround(b * 65536.0);
            } else {
                double sc = (double)(1LL << c.beta_bits);
                bq = llround(b * sc) << (16 - c.beta_bits);
            }
            if (bq > 65535) bq = 65535;
            if (bq < 0)     bq = 0;              /* uint16 Q16 */
            betaq[h] = bq;
            /* beta_oracle_real keeps the TRUE beta in the oracle while the
             * fixed path gets the quantized one, so the divergence reported is
             * beta's own quantization and nothing else.  Without it the two
             * number systems share the same quantized beta and the term
             * cancels exactly -- the identical blindness that hid the decay. */
            betad[h] = (c.inq_real || c.beta_oracle_real) ? b
                     : (double)bq / 65536.0;
        }

        /* ---------------- the recurrence, per head ------------------------- */
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
        for (int h = 0; h < c.HV; h++) {
            head_t *H_ = &H[h];
            int hk = h / HK_RATIO;
            const int64_t *kn = kq[hk], *qs = qq[hk], *v = vq[h];
            const double  *kr = kd_[hk], *qr = qd_[hk], *vr = vd_[h];
            int64_t egq = eg_q[h];  double egr = eg_real[h];
            int64_t beq = betaq[h]; double ber = betad[h];

            double o_d[S_DIM]; float o_f[S_DIM]; int64_t o_acc[S_DIM]; int e_o[S_DIM];

            for (int j = 0; j < S_DIM; j++) {
                /* ================= FIXED, spec 2.1.4 ====================== */
                int se_j = (t == 0) ? c.se_init : H_->se[j];   /* spec: SE_INIT = 0 */
                int64_t w18[S_DIM];
                int64_t sk_acc = 0;
                for (int i = 0; i < S_DIM; i++) {
                    int64_t sm = (t == 0) ? 0 : H_->smant[j][i];
                    /* stage 1, site 6: prescale to W+3 bits */
                    int64_t w = sm * egq;                       /* |w| <= 2^(W-1+15) */
                    w18[i] = round_shift(w, 13);                /* grid se_j + 2 */
                    assert(llabs(w18[i]) <= (1LL << (c.W+1)));
                    /* stage 2: sk dot, no intra-sum alignment (per-column exp) */
                    sk_acc += w18[i] * kn[i];
                }
                /* site 7: normalize sk to 16 bits */
                int sh_sk = msb_pos_u((uint64_t)llabs(sk_acc)) - 14;
                if (sh_sk < 0) sh_sk = 0;
                int64_t skm = round_shift(sk_acc, sh_sk);
                int ske = se_j + 17 - sh_sk;
                assert(llabs(skm) <= 32768);

                /* stage 3, sites 8/9 -- 2.1.4 as AMENDED 2026-08-26.
                 * MASKED OPERAND: the decayed state term is identically zero
                 * either because this is the first token or because the decay
                 * gate is fully shut.  sk_acc is then 0, msb_pos(0) = 0 and
                 * ske = se_j + 17 -- an exponent describing a state that does
                 * not exist.  It must not enter the grid minimum, at EITHER
                 * selection.  Gating only tk = 0 leaves the eg = 0 columns
                 * floored right by 25-37 bits; that was measured, on the
                 * output dot rather than in LSB of the very grid the phantom
                 * exponent coarsens, which is the metric that could not see
                 * it. */
                int tk0 = (t == 0), eg0 = (egq == 0);
                int mask_ed = (tk0 || (c.eg0_ed && eg0)) && c.tk0_ed;
                /* The e_u gate differs from the RTL's in ONE respect, and only
                 * in configurations the RTL cannot express.  rtl/gdn_recur.vhd
                 * gates e_u on tk0 unconditionally -- it has no generic to turn
                 * that off, because that half was adopted earlier as --fix-init.
                 * This file predates that adoption (fix_init defaults to 0), so
                 * to keep the superseded runs reproducible the tk0 half is tied
                 * to (tk0_ed || fix_init) here.  At the adopted defaults the two
                 * agree exactly; --pinned reproduces this file's old default and
                 * --pinned --fix-init reproduces its old --fix-init runs. */
                int mask_eu = (tk0 && (c.tk0_ed || c.fix_init))
                            || (c.eg0_ed && eg0);
                int e_d;
                if (mask_ed) e_d = e_v_seg;
                else         e_d = (e_v_seg < ske) ? e_v_seg : ske;
                int s1 = e_v_seg - e_d, s2 = ske - e_d;
                if (s1 > 63) s1 = 63;
                if (s2 > 63) s2 = 63;
                int64_t diff = floor_shr(v[j], s1) - floor_shr(skm, s2);

                /* D_NORM: quantize d on its own grid.  shd = 16 reproduces the
                 * pinned form exactly (e_dm = e_d + 16 - 16 = e_d), so the flag
                 * chooses shd and nothing else -- one code path, not two. */
                int64_t draw = diff * beq;
                int shd = 16;
                if (c.d_norm) {
                    shd = msb_pos_u((uint64_t)llabs(draw)) - 14;
                    if (shd < 0) shd = 0;
                }
                int64_t d_m  = round_shift(draw, shd);
                int e_dm = e_d + 16 - shd;

                /* stage 4, sites 10/11 */
                int e_kd = 15 + e_dm;
                /* Same masked-operand rule at the second grid selection.  The
                 * tk = 0 half of this is what --fix-init used to select on its
                 * own; it is now the default and eg = 0 is included with it. */
                int e_u;
                if (mask_eu) e_u = e_kd;
                else e_u = (se_j + 2 < e_kd) ? se_j + 2 : e_kd;
                int su = se_j + 2 - e_u, sk2 = e_kd - e_u;
                if (su > 63) su = 63;
                if (sk2 > 63) sk2 = 63;
                /* su can go negative only on the masked path, where e_u = e_kd
                 * may exceed se_j + 2.  There w18 is identically zero, so the
                 * shifted value is zero for any shift and clamping cannot
                 * change a result -- it only avoids a negative shift.  The RTL
                 * clamps here for the same reason.  sk2 is never negative:
                 * e_u <= e_kd by construction on both paths.  Note w18 is zero
                 * at tk = 0 because sm is forced to 0 there, and at eg = 0
                 * because w = sm * egq = 0; both are the masked cases. */
                if (su < 0) su = 0;
                int64_t u[S_DIM]; uint64_t amax = 0;
                for (int i = 0; i < S_DIM; i++) {
                    int64_t kd = kn[i] * d_m;
                    u[i] = floor_shr(w18[i], su) + floor_shr(kd, sk2);
                    uint64_t au = (uint64_t)llabs(u[i]);
                    if (au > amax) amax = au;
                }
                int sh = msb_pos_u(amax) - (c.W - 2);
                if (sh < 0) sh = 0;
                for (int i = 0; i < S_DIM; i++) {
                    int64_t q = round_shift(u[i], sh);
                    int64_t qs2 = satW(q, c.W);
                    if (qs2 != q) H_->sat_events++;
                    H_->smant[j][i] = qs2;
                }
                int se_new = e_u - sh;
                if (se_new < -128 || se_new > 127) H_->se_range_err++;
                H_->se[j] = se_new;

                /* stage 5: output dot from the REQUANTIZED mantissas */
                int64_t oa = 0;
                for (int i = 0; i < S_DIM; i++) oa += H_->smant[j][i] * qs[i];
                o_acc[j] = oa; e_o[j] = se_new + 18;

                /* ================= ORACLE (double) ======================== */
                {
                    double skd = 0.0;
                    double *sdj = H_->sd[j];
                    for (int i = 0; i < S_DIM; i++) { sdj[i] = (t==0)?0.0:sdj[i]*egr;
                                                      skd += sdj[i]*kr[i]; }
                    double dd = (vr[j] - skd) * ber;
                    double od = 0.0;
                    for (int i = 0; i < S_DIM; i++) { sdj[i] += kr[i]*dd; od += sdj[i]*qr[i]; }
                    o_d[j] = od;
                }
                /* ================= FLOAT (binary32) ======================= */
                {
                    float skf = 0.0f, egf = (float)egr, bef = (float)ber;
                    float *sfj = H_->sf[j];
                    for (int i = 0; i < S_DIM; i++) { sfj[i] = (t==0)?0.0f:sfj[i]*egf;
                                                      skf += sfj[i]*(float)kr[i]; }
                    float df = ((float)vr[j] - skf) * bef;
                    float of = 0.0f;
                    for (int i = 0; i < S_DIM; i++) { sfj[i] += (float)kr[i]*df; of += sfj[i]*(float)qr[i]; }
                    o_f[j] = of;
                }
            } /* columns */

            /* stage 6: fold the head to one grid, then bfp requantize */
            int e_h = e_o[0];
            for (int j = 1; j < S_DIM; j++) if (e_o[j] < e_h) e_h = e_o[j];
            int64_t o_al[S_DIM]; uint64_t oamax = 0;
            for (int j = 0; j < S_DIM; j++) {
                int shj = e_o[j] - e_h; if (shj > 63) shj = 63;
                o_al[j] = floor_shr(o_acc[j], shj);
                uint64_t a = (uint64_t)llabs(o_al[j]); if (a > oamax) oamax = a;
            }
            int sh_h = msb_pos_u(oamax) - 14; if (sh_h < 0) sh_h = 0;
            int e_head = e_h - sh_h;
            double o_fx[S_DIM];
            for (int j = 0; j < S_DIM; j++)
                o_fx[j] = ldexp((double)satW(round_shift(o_al[j], sh_h), 16), -e_head);

            /* ---- metrics ------------------------------------------------- */
            double es = 0, ns = 0, ef = 0, eo = 0, no = 0, efo = 0;
            for (int j = 0; j < S_DIM; j++) {
                double sc = ldexp(1.0, -H_->se[j]);
                for (int i = 0; i < S_DIM; i++) {
                    double sx = (double)H_->smant[j][i]*sc;
                    double so = H_->sd[j][i];
                    es += (sx-so)*(sx-so); ns += so*so;
                    double sf = (double)H_->sf[j][i];
                    ef += (sf-so)*(sf-so);
                }
                double dd = o_fx[j]-o_d[j]; eo += dd*dd; no += o_d[j]*o_d[j];
                double df = (double)o_f[j]-o_d[j]; efo += df*df;
            }
            H_->abs_state = sqrt(es);
            H_->err_state = ns > 0 ? sqrt(es/ns) : 0.0;
            H_->nrm_state = sqrt(ns);
            H_->errf_state = ns > 0 ? sqrt(ef/ns) : 0.0;
            H_->err_out  = no > 0 ? sqrt(eo/no) : 0.0;
            H_->nrm_out  = sqrt(no);
            H_->errf_out = no > 0 ? sqrt(efo/no) : 0.0;
        } /* heads */

        /* ---------------- report ------------------------------------------ */
        int report = (t < 8) || (t < 128 && (t+1)%16 == 0) || ((t+1)%128 == 0) || (t == c.T-1);
        if (report || cf) {
            double sm = 0, sx = 0, om = 0, ox = 0, fsx = 0, fox = 0;
            double abs_s = 0, nrm_s = 0;
            for (int h = 0; h < c.HV; h++) {
                sm += H[h].err_state; om += H[h].err_out;
                if (H[h].err_state > sx) sx = H[h].err_state;
                if (H[h].err_out  > ox) ox = H[h].err_out;
                if (H[h].errf_state > fsx) fsx = H[h].errf_state;
                if (H[h].errf_out  > fox) fox = H[h].errf_out;
                abs_s += H[h].abs_state; nrm_s += H[h].nrm_state;
            }
            sm /= c.HV; om /= c.HV; abs_s /= c.HV; nrm_s /= c.HV;
            if (cf) fprintf(cf, "%d,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e\n",
                            t+1, sm, sx, om, ox, fsx, fox, abs_s, nrm_s);
            if (report)
                printf("%8d %14.4e %14.4e %14.4e %14.4e %14.4e\n", t+1, sm, sx, om, ox, fox);
        }
    } /* tokens */

    if (cf) fclose(cf);

    long sat = 0, rng_err = 0;
    for (int h = 0; h < c.HV; h++) { sat += H[h].sat_events; rng_err += H[h].se_range_err; }
    printf("# sat16 events: %ld   se_new out-of-int8 events: %ld\n", sat, rng_err);

    /* worst head at the end of the run */
    int wh = 0; for (int h = 1; h < c.HV; h++) if (H[h].err_out > H[wh].err_out) wh = h;
    printf("# worst head %d: eg=%.9f  state_rel=%.4e  out_rel=%.4e  (fp32 out_rel=%.4e)\n",
           wh, eg_real[wh], H[wh].err_state, H[wh].err_out, H[wh].errf_out);
    return 0;
}
