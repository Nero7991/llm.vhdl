/* ref/run_fx.c
 * Fork of run_i16.c.  forward_fx() is the fixed-point golden model.
 *
 * INTEGER (bit-exact) parts of the datapath: all matmul dot-products
 * (int16 block-fp activation x int16 weight -> int64 accumulate) and the
 * nonlinear KERNELS (fx_rsqrt for RMSNorm, fx_exp_q for softmax, fx_sigmoid_q
 * for SwiGLU, Q1.15 fx_cos/fx_sin for RoPE).
 *
 * FLOAT (tolerance-grade) glue that still connects those integer parts:
 * the RMSNorm normalize+weight multiply, the softmax reciprocal/divide, the
 * attention V-weighted sum (V not yet quantised), the residual adds, and the
 * matmul dequant back to the residual stream.  Consequence for the goldens:
 *   - BIT-EXACT oracles: fx_matvec_wq_l0 (int16 in/weights + raw int64 acc)
 *     and fx_tokens_greedy (greedy argmax is robust to the glue's float noise,
 *     which is exactly why fp-vs-fx stays 200/200 COHERENT EXACT).
 *   - TOLERANCE-GRADE oracles (~+-1 int16 LSB): fx_rmsnorm_l0, fx_rope_l0,
 *     fx_softmax_l0_h0, fx_swiglu_l0, fx_layer0_out -- these snapshot a
 *     float-glued intermediate then quantise to int16 BFP, so Plan 3 RTL must
 *     compare them within a small tolerance, not bit-for-bit.  (Making the glue
 *     integer end-to-end -- a fully bit-exact datapath -- is a documented
 *     future refinement; not required for token-match, which argmax carries.)
 *
 * Coherence baseline: apply_i16_fakequant runs UNCONDITIONALLY, so the fp
 * "reference" that forward() computes for run_tokens.sh already uses int16-
 * quantised weights.  "COHERENT EXACT" therefore means the integer datapath
 * matches float-math-on-int16-weights (isolating datapath quant from weight
 * quant), not fp32 originals.
 *
 * Activations are block-fp quantised to int16 per matmul call; weights are
 * per-row int16 fake-quant stored as float multiples of their row scale
 * (mantissas recovered on the fly).
 *
 * New flags (parsed in main):
 *   --fx    select forward_fx() instead of forward() in the generate loop
 *   --dump  write fixed-point golden vectors to mem/golden/fx_*.txt (Task 6)
 *
 * Every token decided in generate() is logged to stderr as "TOKID <n>"
 * so run_tokens.sh can grep and compare the fp vs --fx streams.
 */

#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <string.h>
#include <assert.h>
#include <fcntl.h>
#if defined _WIN32
    #include "win.h"
#else
    #include <unistd.h>
    #include <sys/mman.h>
    #include <sys/stat.h>
    #include <sys/types.h>
#endif
#include <errno.h>

#include "fx.h"
#include "llama_fx.h"

/* Global mode flags set by main() before generate() is called. */
static int g_use_fx = 0;   /* --fx: use forward_fx() */
static int g_dump   = 0;   /* --dump: write golden vectors to mem/golden/fx_*.txt */

/* ----------------------------------------------------------------------------
 * Golden-vector dump helpers (Task 6).
 *
 * Active only when g_dump is set.  All paths are relative to CWD (repo root),
 * which gen_golden_fx.sh ensures before invoking the binary.
 *
 * File format (per-file layout documented beside each helper):
 *   BFP section: line1 = n, line2 = "EXP <e>", line3 = n int16s space-sep.
 *   Value reconstructed as: v[j] = m[j] * 2^(-e).
 * -------------------------------------------------------------------------- */

/* Write one BFP section to an already-open FILE*. */
static void write_bfp_section(FILE *f, const float *v, int n)
{
    int16_t *m = (int16_t *)malloc(n * sizeof(int16_t));
    if (!m) { fprintf(stderr, "[dump] malloc failed\n"); return; }
    int e = fx_bfp_from_float(m, v, n);
    fprintf(f, "%d\n", n);
    fprintf(f, "EXP %d\n", e);
    for (int j = 0; j < n; j++) {
        fprintf(f, "%d", (int)m[j]);
        if (j < n - 1) fputc(' ', f);
    }
    fputc('\n', f);
    free(m);
}

/* fx_rmsnorm_l0.txt — two BFP sections: input x (att RMSNorm in), output xb. */
static void dump_rmsnorm_l0(const float *x_in, const float *x_out, int n)
{
    FILE *f = fopen("mem/golden/fx_rmsnorm_l0.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_rmsnorm_l0.txt\n"); return; }
    write_bfp_section(f, x_in,  n);
    write_bfp_section(f, x_out, n);
    fclose(f);
}

/* fx_rmsnorm_l0_w.txt — one BFP section: layer-0 att RMS weight quantised to
 * int16 block-fp.  This is the w_mant/w_exp representation the RTL consumes.
 * Using fx_bfp_from_float is identical to what the RTL's input port carries. */
static void dump_rmsnorm_l0_w(const float *w, int n)
{
    FILE *f = fopen("mem/golden/fx_rmsnorm_l0_w.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_rmsnorm_l0_w.txt\n"); return; }
    write_bfp_section(f, w, n);
    fclose(f);
}

/* fx_rope_l0.txt — four BFP sections: q_pre, k_pre, q_post, k_post. */
static void dump_rope_l0(const float *q_pre, int q_len,
                          const float *k_pre, int k_len,
                          const float *q_post, const float *k_post)
{
    FILE *f = fopen("mem/golden/fx_rope_l0.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_rope_l0.txt\n"); return; }
    write_bfp_section(f, q_pre,  q_len);
    write_bfp_section(f, k_pre,  k_len);
    write_bfp_section(f, q_post, q_len);
    write_bfp_section(f, k_post, k_len);
    fclose(f);
}

/* fx_softmax_l0_h0.txt — two BFP sections: scores_in, probs_out (head 0). */
static void dump_softmax_l0_h0(const float *scores, int n, const float *probs)
{
    FILE *f = fopen("mem/golden/fx_softmax_l0_h0.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_softmax_l0_h0.txt\n"); return; }
    write_bfp_section(f, scores, n);
    write_bfp_section(f, probs,  n);
    fclose(f);
}

/* fx_swiglu_l0.txt — three BFP sections: hb_in (w1 out), hb2_in (w3 out), gated_out. */
static void dump_swiglu_l0(const float *hb_in, const float *hb2_in,
                             int n, const float *hb_out)
{
    FILE *f = fopen("mem/golden/fx_swiglu_l0.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_swiglu_l0.txt\n"); return; }
    write_bfp_section(f, hb_in,  n);
    write_bfp_section(f, hb2_in, n);
    write_bfp_section(f, hb_out, n);
    fclose(f);
}

/* fx_matvec_wq_l0.txt:
 *   line 1: d n   (output rows, input cols)
 *   line 2: EXP <xe>   (shared activation block exponent)
 *   line 3: n int16 activation mantissas
 *   then d rows, each: <n int16 weight mantissas> <int64 accumulator>
 * Re-computes mantissas from the fake-quantized float weights (same formula
 * as matmul_fx); results are bit-identical to what the datapath computed.
 */
static void dump_matvec_wq_l0(const float *x, const float *w, int n, int d)
{
    FILE *f = fopen("mem/golden/fx_matvec_wq_l0.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_matvec_wq_l0.txt\n"); return; }

    int16_t *xm = (int16_t *)malloc(n * sizeof(int16_t));
    if (!xm) { fclose(f); return; }
    int xe = fx_bfp_from_float(xm, x, n);

    fprintf(f, "%d %d\n", d, n);
    fprintf(f, "EXP %d\n", xe);
    for (int j = 0; j < n; j++) {
        fprintf(f, "%d", (int)xm[j]);
        if (j < n - 1) fputc(' ', f);
    }
    fputc('\n', f);

    for (int i = 0; i < d; i++) {
        const float *row = w + (size_t)i * n;
        float mx = 0.0f;
        for (int j = 0; j < n; j++) {
            float a = fabsf(row[j]);
            if (a > mx) mx = a;
        }
        float wscale = (mx > 0.0f) ? mx / 32767.0f : 1.0f;
        int64_t acc = 0;
        for (int j = 0; j < n; j++) {
            long wl = lroundf(row[j] / wscale);
            if (wl >  32767) wl =  32767;
            if (wl < -32767) wl = -32767;
            int16_t wm = (int16_t)wl;
            fprintf(f, "%d", (int)wm);
            if (j < n - 1) fputc(' ', f);
            acc += (int64_t)wm * (int64_t)xm[j];
        }
        fprintf(f, " %lld\n", (long long)acc);
    }

    free(xm);
    fclose(f);
}

/* fx_layer0_out.txt — one BFP section: residual stream x after full layer 0. */
static void dump_layer0_out(const float *x, int n)
{
    FILE *f = fopen("mem/golden/fx_layer0_out.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_layer0_out.txt\n"); return; }
    write_bfp_section(f, x, n);
    fclose(f);
}

/* fx_layer0_in.txt — one BFP section: residual x fed INTO layer 0 at DUMP_POS. */
static void dump_layer0_in(const float *x, int n)
{
    FILE *f = fopen("mem/golden/fx_layer0_in.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_layer0_in.txt\n"); return; }
    write_bfp_section(f, x, n);
    fclose(f);
}

/* fx_layer0_kv.txt — (pos+1) K BFP sections then (pos+1) V BFP sections.
 * key_cache and val_cache are already-RoPE'd (for K) / raw (for V) float arrays,
 * laid out as [pos_t * kv_dim + elem]. */
static void dump_layer0_kv(const float *key_cache, const float *val_cache,
                            int n_pos, int kv_dim)
{
    FILE *f = fopen("mem/golden/fx_layer0_kv.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_layer0_kv.txt\n"); return; }
    for (int t = 0; t < n_pos; t++)
        write_bfp_section(f, key_cache + t * kv_dim, kv_dim);
    for (int t = 0; t < n_pos; t++)
        write_bfp_section(f, val_cache + t * kv_dim, kv_dim);
    fclose(f);
}

/* fx_embed.txt — one BFP section per prompt token (order matches
 * mem/golden/prompt_tokens.txt): token_embedding_table[token] re-BFP-encoded
 * with fx_bfp_from_float (via write_bfp_section), exactly as forward_fx's
 * raw (float) embedding-lookup row is block-fp quantised the moment it hits
 * the first matmul_fx/rmsnorm_fx call. Golden for embed.vhd's ROM-lookup +
 * BFP re-quantise output (Plan 4 Task 3). */
static void dump_embed_prompt(const float *table, const int *tokens, int n_tokens, int dim)
{
    FILE *f = fopen("mem/golden/fx_embed.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_embed.txt\n"); return; }
    for (int i = 0; i < n_tokens; i++) {
        const float *row = table + (size_t)tokens[i] * dim;
        write_bfp_section(f, row, dim);
    }
    fclose(f);
}

/* fx_lmhead.txt — golden for lm_head.vhd + sampler.vhd (Plan 4 Task 3).
 *   1. One BFP section: the final-rmsnorm x fed to the classifier (dim=DIM).
 *   2. VOCAB lines: raw int32 logit[v] = fx_scale_mul(dot(x, embed_row_v),
 *      mult_v, shift_v) -- bit-identical to what lm_head.vhd computes.
 *      Recomputed here from the (already fake-quant'd) tied embedding table
 *      using the SAME per-row scale scheme as dump_weight_matrix/matmul_fx.
 *      NOT dequantised by the activation exponent (x_exp) -- lm_head.vhd
 *      intentionally skips that division since it's a common factor across
 *      all 512 rows and therefore doesn't affect argmax.
 *   3. One final line: the argmax index over those raw logits (first max on
 *      ties, matching sample_argmax) -- the oracle "next token" used by
 *      sampler.vhd's golden. */
static void dump_lmhead(const float *x, int dim, const float *table, int vocab)
{
    FILE *f = fopen("mem/golden/fx_lmhead.txt", "w");
    if (!f) { fprintf(stderr, "[dump] cannot open fx_lmhead.txt\n"); return; }

    write_bfp_section(f, x, dim);

    int16_t *xm = (int16_t *)malloc(dim * sizeof(int16_t));
    if (!xm) { fclose(f); return; }
    fx_bfp_from_float(xm, x, dim);

    int32_t best_logit = 0;
    int     best_idx   = 0;
    for (int v = 0; v < vocab; v++) {
        const float *row = table + (size_t)v * dim;
        float mx = 0.0f;
        for (int j = 0; j < dim; j++) { float a = fabsf(row[j]); if (a > mx) mx = a; }
        float wscale = (mx > 0.0f) ? mx / 32767.0f : 1.0f;
        int32_t mult; int shift;
        fx_make_scale(wscale, &mult, &shift);

        int64_t acc = 0;
        for (int j = 0; j < dim; j++) {
            long wl = lroundf(row[j] / wscale);
            if (wl >  32767) wl =  32767;
            if (wl < -32767) wl = -32767;
            acc += (int64_t)(int16_t)wl * (int64_t)xm[j];
        }
        int32_t logit = fx_scale_mul(acc, mult, shift);
        fprintf(f, "%d\n", logit);
        if (v == 0 || logit > best_logit) { best_logit = logit; best_idx = v; }
    }
    fprintf(f, "%d\n", best_idx);

    free(xm);
    fclose(f);
}

/* Dump one weight matrix as per-element int16 mantissas (.mem) and per-row
 * scale factors (two separate files: _mult.mem and _shift.mem).
 * Uses the same per-row quantisation as matmul_fx.  `dir` has no trailing
 * slash (e.g. "mem/weights_l0" or "mem/weights/L0"). */
static void dump_weight_matrix(const char *dir, const char *name, const float *w, int rows, int cols)
{
    char path_m[512], path_mult[512], path_shft[512];
    snprintf(path_m,    sizeof(path_m),    "%s/%s.mem",       dir, name);
    snprintf(path_mult, sizeof(path_mult), "%s/%s_mult.mem",  dir, name);
    snprintf(path_shft, sizeof(path_shft), "%s/%s_shift.mem", dir, name);

    FILE *fm   = fopen(path_m,    "w");
    FILE *fmul = fopen(path_mult, "w");
    FILE *fsh  = fopen(path_shft, "w");
    if (!fm || !fmul || !fsh) {
        fprintf(stderr, "[dump] cannot open weight files for %s\n", name);
        if (fm)  fclose(fm);
        if (fmul) fclose(fmul);
        if (fsh) fclose(fsh);
        return;
    }

    for (int i = 0; i < rows; i++) {
        const float *row = w + (size_t)i * cols;
        float mx = 0.0f;
        for (int j = 0; j < cols; j++) {
            float a = fabsf(row[j]);
            if (a > mx) mx = a;
        }
        float wscale = (mx > 0.0f) ? mx / 32767.0f : 1.0f;
        int32_t mult; int shift;
        fx_make_scale(wscale, &mult, &shift);

        for (int j = 0; j < cols; j++) {
            long wl = lroundf(row[j] / wscale);
            if (wl >  32767) wl =  32767;
            if (wl < -32767) wl = -32767;
            fprintf(fm, "%ld\n", wl);
        }
        fprintf(fmul, "%d\n", (int)mult);
        fprintf(fsh,  "%d\n", shift);
    }
    fclose(fm); fclose(fmul); fclose(fsh);
}

/* Create dir if it doesn't exist (mkdir -p semantics for a single path
 * component or a "parent/child" style path — parent is assumed to already
 * exist or be creatable in one mkdir call, which holds for the paths used
 * here: "mem/weights" and "mem/weights/L<n>" are created in that order). */
static void ensure_dir(const char *path)
{
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "[dump] mkdir(%s) failed: %s\n", path, strerror(errno));
    }
}


/* Dump one rmsnorm weight vector as BFP int16 mantissas (.mem) + exponent
 * (_exp.txt) into <dir>. This is the format layer.vhd / rmsnorm.vhd consume
 * (mant + single block exponent), NOT the per-row mult/shift matmul scheme. */
static void dump_rmsnorm_weight(const char *dir, const char *name, const float *w, int n)
{
    char path_m[512], path_e[512];
    snprintf(path_m, sizeof(path_m), "%s/%s.mem",     dir, name);
    snprintf(path_e, sizeof(path_e), "%s/%s_exp.txt", dir, name);

    int16_t *m = (int16_t *)malloc(n * sizeof(int16_t));
    if (!m) { fprintf(stderr, "[dump] malloc failed for %s\n", name); return; }
    int e = fx_bfp_from_float(m, w, n);

    FILE *fm = fopen(path_m, "w");
    FILE *fe = fopen(path_e, "w");
    if (!fm || !fe) {
        fprintf(stderr, "[dump] cannot open rmsnorm weight files for %s\n", name);
        free(m);
        if (fm) fclose(fm);
        if (fe) fclose(fe);
        return;
    }
    for (int j = 0; j < n; j++) fprintf(fm, "%d\n", (int)m[j]);
    fprintf(fe, "%d\n", e);
    fclose(fm); fclose(fe);
    free(m);
}

/* dump_layer0_weights is defined after the struct typedefs below. */

/* ----------------------------------------------------------------------------
 * Transformer model (identical to run_i16.c)
 * -------------------------------------------------------------------------- */

typedef struct {
    int dim;
    int hidden_dim;
    int n_layers;
    int n_heads;
    int n_kv_heads;
    int vocab_size;
    int seq_len;
} Config;

typedef struct {
    float* token_embedding_table;    /* (vocab_size, dim) */
    float* rms_att_weight;           /* (layer, dim) */
    float* rms_ffn_weight;           /* (layer, dim) */
    float* wq;                       /* (layer, dim, n_heads * head_size) */
    float* wk;                       /* (layer, dim, n_kv_heads * head_size) */
    float* wv;                       /* (layer, dim, n_kv_heads * head_size) */
    float* wo;                       /* (layer, n_heads * head_size, dim) */
    float* w1;                       /* (layer, hidden_dim, dim) */
    float* w2;                       /* (layer, dim, hidden_dim) */
    float* w3;                       /* (layer, hidden_dim, dim) */
    float* rms_final_weight;         /* (dim,) */
    float* wcls;
} TransformerWeights;

typedef struct {
    float *x;           /* (dim,) */
    float *xb;          /* (dim,) */
    float *xb2;         /* (dim,) */
    float *hb;          /* (hidden_dim,) */
    float *hb2;         /* (hidden_dim,) */
    float *q;           /* (dim,) */
    float *k;
    float *v;
    float *att;         /* (n_heads, seq_len) */
    float *logits;
    float* key_cache;   /* (layer, seq_len, kv_dim) */
    float* value_cache; /* (layer, seq_len, kv_dim) */
} RunState;

typedef struct {
    Config config;
    TransformerWeights weights;
    RunState state;
    int fd;
    float* data;
    ssize_t file_size;
} Transformer;

static void malloc_run_state(RunState* s, Config* p) {
    int kv_dim = (p->dim * p->n_kv_heads) / p->n_heads;
    s->x    = calloc(p->dim,        sizeof(float));
    s->xb   = calloc(p->dim,        sizeof(float));
    s->xb2  = calloc(p->dim,        sizeof(float));
    s->hb   = calloc(p->hidden_dim, sizeof(float));
    s->hb2  = calloc(p->hidden_dim, sizeof(float));
    s->q    = calloc(p->dim,        sizeof(float));
    s->key_cache   = calloc(p->n_layers * p->seq_len * kv_dim, sizeof(float));
    s->value_cache = calloc(p->n_layers * p->seq_len * kv_dim, sizeof(float));
    s->att    = calloc(p->n_heads * p->seq_len, sizeof(float));
    s->logits = calloc(p->vocab_size,            sizeof(float));
    if (!s->x || !s->xb || !s->xb2 || !s->hb || !s->hb2 || !s->q
     || !s->key_cache || !s->value_cache || !s->att || !s->logits) {
        fprintf(stderr, "malloc failed!\n"); exit(EXIT_FAILURE);
    }
}

static void free_run_state(RunState* s) {
    free(s->x); free(s->xb); free(s->xb2);
    free(s->hb); free(s->hb2); free(s->q);
    free(s->att); free(s->logits);
    free(s->key_cache); free(s->value_cache);
}

static void memory_map_weights(TransformerWeights *w, Config* p,
                                float* ptr, int shared_weights) {
    int head_size = p->dim / p->n_heads;
    unsigned long long n_layers = p->n_layers;
    w->token_embedding_table = ptr;    ptr += p->vocab_size * p->dim;
    w->rms_att_weight = ptr;           ptr += n_layers * p->dim;
    w->wq = ptr;                       ptr += n_layers * p->dim * (p->n_heads * head_size);
    w->wk = ptr;                       ptr += n_layers * p->dim * (p->n_kv_heads * head_size);
    w->wv = ptr;                       ptr += n_layers * p->dim * (p->n_kv_heads * head_size);
    w->wo = ptr;                       ptr += n_layers * (p->n_heads * head_size) * p->dim;
    w->rms_ffn_weight = ptr;           ptr += n_layers * p->dim;
    w->w1 = ptr;                       ptr += n_layers * p->dim * p->hidden_dim;
    w->w2 = ptr;                       ptr += n_layers * p->hidden_dim * p->dim;
    w->w3 = ptr;                       ptr += n_layers * p->dim * p->hidden_dim;
    w->rms_final_weight = ptr;         ptr += p->dim;
    ptr += p->seq_len * head_size / 2;
    ptr += p->seq_len * head_size / 2;
    w->wcls = shared_weights ? w->token_embedding_table : ptr;
}

/* dump_layer0_weights — emit all 7 weight matrices and 2 rmsnorm weights for
 * layer 0 to mem/weights_l0/. Assumes w has already been fake-quant'd for
 * the matmul weights; rmsnorm weights use raw float (not fake-quant'd). */
static void dump_layer0_weights(TransformerWeights *w, Config *p)
{
    int dim    = p->dim;
    int kv_dim = (p->dim * p->n_kv_heads) / p->n_heads;
    int hidden = p->hidden_dim;

    dump_weight_matrix("mem/weights_l0", "wq", w->wq, dim,    dim);
    dump_weight_matrix("mem/weights_l0", "wk", w->wk, kv_dim, dim);
    dump_weight_matrix("mem/weights_l0", "wv", w->wv, kv_dim, dim);
    dump_weight_matrix("mem/weights_l0", "wo", w->wo, dim,    dim);
    dump_weight_matrix("mem/weights_l0", "w1", w->w1, hidden, dim);
    dump_weight_matrix("mem/weights_l0", "w3", w->w3, hidden, dim);
    dump_weight_matrix("mem/weights_l0", "w2", w->w2, dim,    hidden);
    dump_rmsnorm_weight("mem/weights_l0", "att_rmsnorm_w", w->rms_att_weight, dim);
    dump_rmsnorm_weight("mem/weights_l0", "ffn_rmsnorm_w", w->rms_ffn_weight, dim);
}

/* dump_all_weights (Plan 4 Task 1) — emit every layer's 7 weight matrices +
 * 2 rmsnorm vectors to mem/weights/L<l>/, plus the (tied) token embedding
 * table and the final rmsnorm vector to mem/weights/.  Matmul weights and the
 * embedding use the int16 mantissa + per-row mult/shift scheme
 * (dump_weight_matrix, consumed by mac_array via scale_mul); the rmsnorm
 * vectors use the BFP mantissa + single-exponent scheme (dump_rmsnorm_weight),
 * which is what rmsnorm.vhd / layer.vhd consume (mant + _exp.txt) — matching
 * the mem/weights_l0/ layer-0 format so the WDIR-parameterized layer reads
 * L<l>/ identically. Indexes w->wq/wk/... directly by layer, so this runs once
 * from forward_fx's one-shot dump guard, not inside the per-layer forward loop. */
static void dump_all_weights(TransformerWeights *w, Config *p)
{
    int dim    = p->dim;
    int kv_dim = (p->dim * p->n_kv_heads) / p->n_heads;
    int hidden = p->hidden_dim;
    int vocab  = p->vocab_size;
    long long L = p->n_layers;

    ensure_dir("mem/weights");

    for (long long l = 0; l < L; l++) {
        char dir[512];
        snprintf(dir, sizeof(dir), "mem/weights/L%lld", l);
        ensure_dir(dir);

        dump_weight_matrix(dir, "wq", w->wq + l*dim*dim,        dim,    dim);
        dump_weight_matrix(dir, "wk", w->wk + l*dim*kv_dim,     kv_dim, dim);
        dump_weight_matrix(dir, "wv", w->wv + l*dim*kv_dim,     kv_dim, dim);
        dump_weight_matrix(dir, "wo", w->wo + l*dim*dim,        dim,    dim);
        dump_weight_matrix(dir, "w1", w->w1 + l*dim*hidden,     hidden, dim);
        dump_weight_matrix(dir, "w3", w->w3 + l*dim*hidden,     hidden, dim);
        dump_weight_matrix(dir, "w2", w->w2 + l*hidden*dim,     dim,    hidden);
        dump_rmsnorm_weight(dir, "att_rmsnorm_w", w->rms_att_weight + l*dim, dim);
        dump_rmsnorm_weight(dir, "ffn_rmsnorm_w", w->rms_ffn_weight + l*dim, dim);
    }

    /* Tied embedding table (lm_head == token_embedding_table for this
     * checkpoint — confirmed via memory_map_weights()/apply_i16_fakequant(),
     * which set w->wcls = w->token_embedding_table when shared_weights). */
    dump_weight_matrix("mem/weights", "embed", w->token_embedding_table, vocab, dim);

    /* Final RMSNorm vector. */
    dump_rmsnorm_weight("mem/weights", "final_rmsnorm_w", w->rms_final_weight, dim);
}

static void read_checkpoint(char* checkpoint, Config* config,
                             TransformerWeights* weights,
                             int* fd, float** data, ssize_t* file_size) {
    FILE *file = fopen(checkpoint, "rb");
    if (!file) { fprintf(stderr, "Couldn't open file %s\n", checkpoint); exit(EXIT_FAILURE); }
    if (fread(config, sizeof(Config), 1, file) != 1) { exit(EXIT_FAILURE); }
    int shared_weights = config->vocab_size > 0 ? 1 : 0;
    config->vocab_size = abs(config->vocab_size);
    fseek(file, 0, SEEK_END);
    *file_size = ftell(file);
    fclose(file);
    *fd = open(checkpoint, O_RDONLY);
    if (*fd == -1) { fprintf(stderr, "open failed!\n"); exit(EXIT_FAILURE); }
    *data = mmap(NULL, *file_size, PROT_READ, MAP_PRIVATE, *fd, 0);
    if (*data == MAP_FAILED) { fprintf(stderr, "mmap failed!\n"); exit(EXIT_FAILURE); }
    float* weights_ptr = *data + sizeof(Config)/sizeof(float);
    memory_map_weights(weights, config, weights_ptr, shared_weights);
}

static void build_transformer(Transformer *t, char* checkpoint_path) {
    read_checkpoint(checkpoint_path, &t->config, &t->weights,
                    &t->fd, &t->data, &t->file_size);
    malloc_run_state(&t->state, &t->config);
}

static void free_transformer(Transformer* t) {
    if (t->data != MAP_FAILED) { munmap(t->data, t->file_size); }
    if (t->fd != -1) { close(t->fd); }
    free_run_state(&t->state);
}

/* ----------------------------------------------------------------------------
 * Neural-net blocks
 * -------------------------------------------------------------------------- */

static void rmsnorm(float* o, float* x, float* weight, int size) {
    float ss = 0.0f;
    for (int j = 0; j < size; j++) ss += x[j] * x[j];
    ss /= size;
    ss += 1e-5f;
    ss = 1.0f / sqrtf(ss);
    for (int j = 0; j < size; j++) o[j] = weight[j] * (ss * x[j]);
}

/* Integer RMSNorm via fx_rsqrt (Task 3).  Identical body to test_rmsnorm.c. */
static void rmsnorm_fx(float* o, const float* x, const float* w, int n) {
    enum { RQ = 12 };
    int16_t xm[n];
    int xe = fx_bfp_from_float(xm, x, n);

    /* S = sum(xm[j]^2) ≈ sum(x_j^2) * 2^(2*xe) */
    int64_t S = 0;
    for (int j = 0; j < n; j++) S += (int64_t)xm[j] * xm[j];

    /* mean_sq_q = round(mean_sq * 2^RQ) where mean_sq = S / (n * 2^(2*xe)) */
    int64_t num = S << RQ;                      /* S * 2^RQ; fits int64 for n<=8192 */
    int64_t mean_sq_q = (num + (int64_t)n / 2) / (int64_t)n;  /* rounded /n */
    if (xe >= 0) {
        int sh = 2 * xe; if (sh > 62) sh = 62;
        if (sh > 0) mean_sq_q = (mean_sq_q + (1LL << (sh - 1))) >> sh;  /* rounded >>sh */
    } else {
        int sh = -2 * xe; if (sh > 62) sh = 62;
        mean_sq_q <<= sh;
    }
    mean_sq_q += (int64_t)llround(1e-5 * (1 << RQ));  /* eps in Qq; = 0 at RQ=12 */
    if (mean_sq_q < 1) mean_sq_q = 1;

    int32_t inv = fx_rsqrt(mean_sq_q, RQ);
    float inv_f = (float)inv / (float)(1 << RQ);
    for (int j = 0; j < n; j++) o[j] = w[j] * inv_f * x[j];
}

static void softmax(float* x, int size) {
    float max_val = x[0];
    for (int i = 1; i < size; i++) if (x[i] > max_val) max_val = x[i];
    float sum = 0.0f;
    for (int i = 0; i < size; i++) { x[i] = expf(x[i] - max_val); sum += x[i]; }
    for (int i = 0; i < size; i++) x[i] /= sum;
}

/* Integer softmax via fx_exp_q (Q12).  Identical body to test_softmax.c. */
static void softmax_fx(float* x, int n) {
    /* Find max (float ok; z = x[i]-max is always <= 0). */
    float max_val = x[0];
    for (int i = 1; i < n; i++) if (x[i] > max_val) max_val = x[i];

    /* Compute Q12 exp for each element and accumulate integer sum. */
    int32_t e_arr[n];
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        float z = x[i] - max_val;
        int32_t z_q = (int32_t)lroundf(z * 4096.0f);
        e_arr[i] = fx_exp_q(z_q, 12);
        sum += e_arr[i];
    }
    if (sum == 0) sum = 1;  /* guard: can only happen if all inputs << -16 */

    /* Normalize: probability = e_i / sum (Q12 scale cancels). */
    for (int i = 0; i < n; i++) {
        x[i] = (float)e_arr[i] / (float)sum;
    }
}

/* Integer SwiGLU/SiLU via fx_sigmoid_q (Q12).  Identical body to test_swiglu.c. */
static void swiglu_fx(float* hb, const float* hb2, int n) {
    /* SiLU(v) * w3: v*sigmoid(v)*hb2, all in Q12 fixed point. */
    for (int i = 0; i < n; i++) {
        int32_t v_q  = (int32_t)lroundf(hb[i]  * 4096.0f);
        int32_t h2_q = (int32_t)lroundf(hb2[i] * 4096.0f);
        int32_t sig  = fx_sigmoid_q(v_q, 12);                /* Q12, in [0,1] */
        int64_t silu_q = ((int64_t)v_q * sig) >> 12;         /* silu=v*sig, Q12 */
        int64_t out_q  = (silu_q * h2_q) >> 12;              /* *hb2, Q12 */
        hb[i] = (float)out_q / 4096.0f;
    }
}

/* Float matmul used by the unmodified forward() path. */
static void matmul(float* xout, float* x, float* w, int n, int d) {
    int i;
    #pragma omp parallel for private(i)
    for (i = 0; i < d; i++) {
        float val = 0.0f;
        for (int j = 0; j < n; j++) val += w[i * n + j] * x[j];
        xout[i] = val;
    }
}

/* Unmodified float forward pass (used when --fx is NOT set). */
static float* forward(Transformer* transformer, int token, int pos) {
    Config* p = &transformer->config;
    TransformerWeights* w = &transformer->weights;
    RunState* s = &transformer->state;
    float *x = s->x;
    int dim       = p->dim;
    int kv_dim    = (p->dim * p->n_kv_heads) / p->n_heads;
    int kv_mul    = p->n_heads / p->n_kv_heads;
    int hidden_dim = p->hidden_dim;
    int head_size  = dim / p->n_heads;

    float* content_row = w->token_embedding_table + token * dim;
    memcpy(x, content_row, dim * sizeof(*x));

    for (unsigned long long l = 0; l < (unsigned long long)p->n_layers; l++) {
        rmsnorm(s->xb, x, w->rms_att_weight + l*dim, dim);

        int loff = l * p->seq_len * kv_dim;
        s->k = s->key_cache   + loff + pos * kv_dim;
        s->v = s->value_cache + loff + pos * kv_dim;

        matmul(s->q,  s->xb, w->wq + l*dim*dim,      dim, dim);
        matmul(s->k,  s->xb, w->wk + l*dim*kv_dim,   dim, kv_dim);
        matmul(s->v,  s->xb, w->wv + l*dim*kv_dim,   dim, kv_dim);

        for (int i = 0; i < dim; i += 2) {
            int head_dim = i % head_size;
            float freq = 1.0f / powf(10000.0f, head_dim / (float)head_size);
            float val = pos * freq;
            float fcr = cosf(val), fci = sinf(val);
            int rotn = i < kv_dim ? 2 : 1;
            for (int v = 0; v < rotn; v++) {
                float* vec = v == 0 ? s->q : s->k;
                float v0 = vec[i], v1 = vec[i+1];
                vec[i]   = v0 * fcr - v1 * fci;
                vec[i+1] = v0 * fci + v1 * fcr;
            }
        }

        int h;
        #pragma omp parallel for private(h)
        for (h = 0; h < p->n_heads; h++) {
            float* q   = s->q   + h * head_size;
            float* att = s->att + h * p->seq_len;
            for (int t = 0; t <= pos; t++) {
                float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                float score = 0.0f;
                for (int i = 0; i < head_size; i++) score += q[i] * k[i];
                score /= sqrtf(head_size);
                att[t] = score;
            }
            softmax(att, pos + 1);
            float* xb = s->xb + h * head_size;
            memset(xb, 0, head_size * sizeof(float));
            for (int t = 0; t <= pos; t++) {
                float* v = s->value_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                float a = att[t];
                for (int i = 0; i < head_size; i++) xb[i] += a * v[i];
            }
        }

        matmul(s->xb2, s->xb, w->wo + l*dim*dim, dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        rmsnorm(s->xb, x, w->rms_ffn_weight + l*dim, dim);

        matmul(s->hb,  s->xb, w->w1 + l*dim*hidden_dim, dim, hidden_dim);
        matmul(s->hb2, s->xb, w->w3 + l*dim*hidden_dim, dim, hidden_dim);

        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= (1.0f / (1.0f + expf(-val)));
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        matmul(s->xb, s->hb, w->w2 + l*dim*hidden_dim, hidden_dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    rmsnorm(x, x, w->rms_final_weight, dim);
    matmul(s->logits, x, w->wcls, p->dim, p->vocab_size);
    return s->logits;
}

/* ----------------------------------------------------------------------------
 * Integer block-fp matmul
 * --------------------------------------------------------------------------
 *
 * Design: per-call approach (b) — recover int16 weight mantissas on the fly
 * from the already-fakequant'd float weights.  After apply_i16_fakequant(),
 * each w[i*n+j] == round(original / row_scale) * row_scale exactly (up to
 * float precision), so lroundf(w[i*n+j] / row_scale) gives the mantissa.
 *
 * Activation x[] is block-fp quantised once per call to int16 m[] with
 * shared exponent xe: m[j] ≈ x[j] * 2^xe.
 *
 * Output: xout[i] = fx_scale_mul(acc, mult, shift) * 2^(-xe)
 *   where acc = sum_j( wm[j] * m[j] )  (exact int64)
 *         mult/2^shift ≈ row_scale  (from fx_make_scale)
 */

#define FX_MAX_N 8192   /* comfortably exceeds stories260K hidden_dim */
static int16_t s_xm[FX_MAX_N];   /* activation mantissa buffer (serial use) */

static void matmul_fx(float* xout, float* x, float* w, int n, int d) {
    assert(n <= FX_MAX_N);

    /* Quantise the shared activation vector once. */
    int xe = fx_bfp_from_float(s_xm, x, n);
    /* Activation scale: x[j] = s_xm[j] * 2^(-xe).  Handle xe < 0 safely. */
    float inv_xe = (xe >= 0) ? (1.0f / (float)(1 << xe))
                              : (float)(1 << (-xe));

    for (int i = 0; i < d; i++) {
        const float* row = w + (size_t)i * n;

        /* Per-row weight scale: same formula as apply_i16_fakequant().
         * We run this on the fake-quant'd floats, which have the same max
         * as the original (the max element rounds to ±32767 * scale). */
        float mx = 0.0f;
        for (int j = 0; j < n; j++) {
            float a = fabsf(row[j]);
            if (a > mx) mx = a;
        }
        float wscale = (mx > 0.0f) ? mx / 32767.0f : 1.0f;
        int32_t mult; int shift;
        fx_make_scale(wscale, &mult, &shift);

        /* Recover int16 mantissas and dot-product with activation block-fp. */
        int64_t acc = 0;
        for (int j = 0; j < n; j++) {
            long wl = lroundf(row[j] / wscale);
            if (wl >  32767) wl =  32767;
            if (wl < -32767) wl = -32767;
            acc += (int64_t)(int16_t)wl * (int64_t)s_xm[j];
        }
        /* Safety: for dim<=172, max |acc| = 172*32767*32767 ~ 1.8e11 << 2^47 */
        assert(llabs(acc) < (1LL << 47));

        /* Requantise weight-scale * acc, then undo the activation exponent. */
        xout[i] = (float)fx_scale_mul(acc, mult, shift) * inv_xe;
    }
}

/* Integer RoPE rotation using Q1.15 twiddle LUTs from fx.h.
 * Identical body to rope_fx in test_rope.c. */
static void rope_fx(float* vec, int pos, int dim, int head_size) {
    for (int i = 0; i < dim; i += 2) {
        int16_t fcr = fx_cos(pos, i % head_size, head_size);
        int16_t fci = fx_sin(pos, i % head_size, head_size);
        float v0 = vec[i], v1 = vec[i+1];
        int64_t q0 = llround(v0 * 4096.0), q1 = llround(v1 * 4096.0);
        int64_t r0 = (q0 * fcr - q1 * fci + (1LL << 14)) >> 15;
        int64_t r1 = (q0 * fci + q1 * fcr + (1LL << 14)) >> 15;
        vec[i]   = (float)(r0 / 4096.0);
        vec[i+1] = (float)(r1 / 4096.0);
    }
}

/* ----------------------------------------------------------------------------
 * forward_fx — copy of forward() with matmul() replaced by matmul_fx().
 * When g_dump is set, the pos==DUMP_POS call captures layer-0 golden vectors.
 * The static dump_done guard ensures each file is written exactly once.
 * -------------------------------------------------------------------------- */
#define DUMP_POS 3   /* non-trivial: RoPE angle != 0, attention window = 4 */
static float* forward_fx(Transformer* transformer, int token, int pos) {
    Config* p = &transformer->config;
    TransformerWeights* w = &transformer->weights;
    RunState* s = &transformer->state;
    float *x = s->x;
    int dim        = p->dim;
    int kv_dim     = (p->dim * p->n_kv_heads) / p->n_heads;
    int kv_mul     = p->n_heads / p->n_kv_heads;
    int hidden_dim = p->hidden_dim;
    int head_size  = dim / p->n_heads;

    /* One-shot dump guard: fires at pos==DUMP_POS so RoPE (non-zero angle) and
     * softmax (multi-element attention window) goldens exercise real computation
     * rather than the pos=0 identity/singleton cases.  All layer-0 golden files
     * are written at this single position so the dump position is unambiguous. */
    static int dump_done = 0;
    int do_dump = g_dump && !dump_done && pos == DUMP_POS;

    /* Token embedding lookup (not a matmul — stays float). */
    float* content_row = w->token_embedding_table + token * dim;
    memcpy(x, content_row, dim * sizeof(*x));

    for (unsigned long long l = 0; l < (unsigned long long)p->n_layers; l++) {

        /* --- DUMP: capture x before att RMSNorm (layer 0 only) --- */
        float *x_in_copy = NULL;
        if (do_dump && l == 0) {
            x_in_copy = (float *)malloc(dim * sizeof(float));
            if (x_in_copy) memcpy(x_in_copy, x, dim * sizeof(float));
        }

        /* Attention RMSNorm (integer). */
        rmsnorm_fx(s->xb, x, w->rms_att_weight + l*dim, dim);

        /* --- DUMP: write rmsnorm golden + weight + Wq matvec golden (layer 0) --- */
        if (do_dump && l == 0) {
            if (x_in_copy) {
                dump_rmsnorm_l0(x_in_copy, s->xb, dim);
                dump_rmsnorm_l0_w(w->rms_att_weight + 0 * dim, dim);
                dump_layer0_in(x_in_copy, dim);
                dump_layer0_weights(w, p);
                dump_all_weights(w, p);
                free(x_in_copy);
                x_in_copy = NULL;
            }
            /* w->wq points to layer 0's Wq (offset 0*dim*dim = 0). */
            dump_matvec_wq_l0(s->xb, w->wq, dim, dim);
        }

        int loff = l * p->seq_len * kv_dim;
        s->k = s->key_cache   + loff + pos * kv_dim;
        s->v = s->value_cache + loff + pos * kv_dim;

        /* QKV matmuls — integer block-fp. */
        matmul_fx(s->q,  s->xb, w->wq + l*dim*dim,    dim, dim);
        matmul_fx(s->k,  s->xb, w->wk + l*dim*kv_dim, dim, kv_dim);
        matmul_fx(s->v,  s->xb, w->wv + l*dim*kv_dim, dim, kv_dim);

        /* --- DUMP: capture q,k before RoPE (layer 0) --- */
        float *q_pre = NULL, *k_pre = NULL;
        if (do_dump && l == 0) {
            q_pre = (float *)malloc(dim    * sizeof(float));
            k_pre = (float *)malloc(kv_dim * sizeof(float));
            if (q_pre) memcpy(q_pre, s->q, dim    * sizeof(float));
            if (k_pre) memcpy(k_pre, s->k, kv_dim * sizeof(float));
        }

        /* RoPE — integer Q1.15 twiddle tables (Task 4). */
        rope_fx(s->q, pos, dim,    head_size);   /* rotate all query dims */
        rope_fx(s->k, pos, kv_dim, head_size);   /* rotate key dims (kv_dim <= dim) */

        /* --- DUMP: write RoPE golden (layer 0) --- */
        if (do_dump && l == 0) {
            if (q_pre && k_pre)
                dump_rope_l0(q_pre, dim, k_pre, kv_dim, s->q, s->k);
            free(q_pre);  q_pre = NULL;
            free(k_pre);  k_pre = NULL;
            /* KV cache at all positions 0..pos (K is post-rope, V is pre-rope). */
            dump_layer0_kv(s->key_cache + loff, s->value_cache + loff,
                           pos + 1, kv_dim);
        }

        /* --- DUMP: compute head-0 pre-softmax scores sequentially (layer 0) ---
         * The OMP loop below runs softmax in-place, so we capture the raw scores
         * now by re-running the integer q·k dot for head 0 only. */
        float *att0_pre = NULL;
        if (do_dump && l == 0) {
            att0_pre = (float *)malloc((pos + 1) * sizeof(float));
            if (att0_pre) {
                float *q0 = s->q + 0 * head_size;
                int16_t qm[head_size];
                int qe = fx_bfp_from_float(qm, q0, head_size);
                float inv_qe = (qe >= 0) ? (1.0f / (float)(1 << qe))
                                         : (float)(1 << (-qe));
                for (int t = 0; t <= pos; t++) {
                    float *kc = s->key_cache + loff + t * kv_dim + 0 * head_size;
                    int16_t km[head_size];
                    int ke = fx_bfp_from_float(km, kc, head_size);
                    float inv_ke = (ke >= 0) ? (1.0f / (float)(1 << ke))
                                             : (float)(1 << (-ke));
                    int64_t acc = 0;
                    for (int i = 0; i < head_size; i++)
                        acc += (int64_t)qm[i] * km[i];
                    att0_pre[t] = (float)acc * inv_qe * inv_ke / sqrtf(head_size);
                }
            }
        }

        /* Multi-head attention: integer block-fp q·k dot + integer softmax. */
        int h;
        #pragma omp parallel for private(h)
        for (h = 0; h < p->n_heads; h++) {
            float* q   = s->q   + h * head_size;
            float* att = s->att + h * p->seq_len;

            /* Quantize the q-head once; k is quantized per cached timestep. */
            int16_t qm[head_size];
            int qe = fx_bfp_from_float(qm, q, head_size);
            float inv_qe = (qe >= 0) ? (1.0f / (float)(1 << qe))
                                     : (float)(1 << (-qe));

            for (int t = 0; t <= pos; t++) {
                float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                int16_t km[head_size];
                int ke = fx_bfp_from_float(km, k, head_size);
                float inv_ke = (ke >= 0) ? (1.0f / (float)(1 << ke))
                                         : (float)(1 << (-ke));
                int64_t acc = 0;
                for (int i = 0; i < head_size; i++) acc += (int64_t)qm[i] * km[i];
                float score = (float)acc * inv_qe * inv_ke;
                score /= sqrtf(head_size);
                att[t] = score;
            }
            softmax_fx(att, pos + 1);
            float* xb = s->xb + h * head_size;
            memset(xb, 0, head_size * sizeof(float));
            for (int t = 0; t <= pos; t++) {
                float* v = s->value_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                float a = att[t];
                for (int i = 0; i < head_size; i++) xb[i] += a * v[i];
            }
        }

        /* --- DUMP: write softmax golden head-0 (layer 0) ---
         * s->att + 0*seq_len now holds the post-softmax probs for head 0. */
        if (do_dump && l == 0 && att0_pre) {
            dump_softmax_l0_h0(att0_pre, pos + 1, s->att + 0 * p->seq_len);
            free(att0_pre);  att0_pre = NULL;
        }

        /* Output projection — integer block-fp. */
        matmul_fx(s->xb2, s->xb, w->wo + l*dim*dim, dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        /* FFN RMSNorm (integer). */
        rmsnorm_fx(s->xb, x, w->rms_ffn_weight + l*dim, dim);

        /* FFN gate/up matmuls — integer block-fp. */
        matmul_fx(s->hb,  s->xb, w->w1 + l*dim*hidden_dim, dim, hidden_dim);
        matmul_fx(s->hb2, s->xb, w->w3 + l*dim*hidden_dim, dim, hidden_dim);

        /* --- DUMP: capture hb, hb2 before SwiGLU (layer 0) --- */
        float *hb_copy = NULL, *hb2_copy = NULL;
        if (do_dump && l == 0) {
            hb_copy  = (float *)malloc(hidden_dim * sizeof(float));
            hb2_copy = (float *)malloc(hidden_dim * sizeof(float));
            if (hb_copy)  memcpy(hb_copy,  s->hb,  hidden_dim * sizeof(float));
            if (hb2_copy) memcpy(hb2_copy, s->hb2, hidden_dim * sizeof(float));
        }

        /* SwiGLU nonlinearity — integer fx_sigmoid_q (Task 5). */
        swiglu_fx(s->hb, s->hb2, hidden_dim);

        /* --- DUMP: write SwiGLU golden (layer 0) --- */
        if (do_dump && l == 0) {
            if (hb_copy && hb2_copy)
                dump_swiglu_l0(hb_copy, hb2_copy, hidden_dim, s->hb);
            free(hb_copy);   hb_copy  = NULL;
            free(hb2_copy);  hb2_copy = NULL;
        }

        /* FFN down projection — integer block-fp. */
        matmul_fx(s->xb, s->hb, w->w2 + l*dim*hidden_dim, hidden_dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb[i];

        /* --- DUMP: write layer-0 residual output; mark dump complete --- */
        if (do_dump && l == 0) {
            dump_layer0_out(x, dim);
            dump_done = 1;  /* prevent re-firing on subsequent forward calls */
        }
    }

    /* Final RMSNorm (integer) + classifier (int block-fp). */
    rmsnorm_fx(x, x, w->rms_final_weight, dim);
    matmul_fx(s->logits, x, w->wcls, p->dim, p->vocab_size);

    /* --- DUMP: final-rmsnorm x + 512 raw classifier logits + argmax --- */
    if (do_dump) {
        dump_lmhead(x, dim, w->wcls, p->vocab_size);
    }

    return s->logits;
}

/* ----------------------------------------------------------------------------
 * Tokenizer
 * -------------------------------------------------------------------------- */

typedef struct { char *str; int id; } TokenIndex;

typedef struct {
    char** vocab;
    float* vocab_scores;
    TokenIndex *sorted_vocab;
    int vocab_size;
    unsigned int max_token_length;
    unsigned char byte_pieces[512];
} Tokenizer;

static int compare_tokens(const void *a, const void *b) {
    return strcmp(((TokenIndex*)a)->str, ((TokenIndex*)b)->str);
}

static void build_tokenizer(Tokenizer* t, char* tokenizer_path, int vocab_size) {
    t->vocab_size  = vocab_size;
    t->vocab       = (char**)malloc(vocab_size * sizeof(char*));
    t->vocab_scores = (float*)malloc(vocab_size * sizeof(float));
    t->sorted_vocab = NULL;
    for (int i = 0; i < 256; i++) {
        t->byte_pieces[i * 2] = (unsigned char)i;
        t->byte_pieces[i * 2 + 1] = '\0';
    }
    FILE *file = fopen(tokenizer_path, "rb");
    if (!file) { fprintf(stderr, "couldn't load %s\n", tokenizer_path); exit(EXIT_FAILURE); }
    if (fread(&t->max_token_length, sizeof(int), 1, file) != 1) { fprintf(stderr, "failed read\n"); exit(EXIT_FAILURE); }
    int len;
    for (int i = 0; i < vocab_size; i++) {
        if (fread(t->vocab_scores + i, sizeof(float), 1, file) != 1) { fprintf(stderr, "failed read\n"); exit(EXIT_FAILURE); }
        if (fread(&len, sizeof(int), 1, file) != 1) { fprintf(stderr, "failed read\n"); exit(EXIT_FAILURE); }
        t->vocab[i] = (char*)malloc(len + 1);
        if (fread(t->vocab[i], len, 1, file) != 1) { fprintf(stderr, "failed read\n"); exit(EXIT_FAILURE); }
        t->vocab[i][len] = '\0';
    }
    fclose(file);
}

static void free_tokenizer(Tokenizer* t) {
    for (int i = 0; i < t->vocab_size; i++) free(t->vocab[i]);
    free(t->vocab); free(t->vocab_scores); free(t->sorted_vocab);
}

static char* decode(Tokenizer* t, int prev_token, int token) {
    char *piece = t->vocab[token];
    if (prev_token == 1 && piece[0] == ' ') piece++;
    unsigned char byte_val;
    if (sscanf(piece, "<0x%02hhX>", &byte_val) == 1)
        piece = (char*)t->byte_pieces + byte_val * 2;
    return piece;
}

static void safe_printf(char *piece) {
    if (piece == NULL || piece[0] == '\0') return;
    if (piece[1] == '\0') {
        unsigned char byte_val = piece[0];
        if (!(isprint(byte_val) || isspace(byte_val))) return;
    }
    printf("%s", piece);
}

static int str_lookup(char *str, TokenIndex *sorted_vocab, int vocab_size) {
    TokenIndex tok = { .str = str };
    TokenIndex *res = bsearch(&tok, sorted_vocab, vocab_size,
                               sizeof(TokenIndex), compare_tokens);
    return res != NULL ? res->id : -1;
}

static void encode(Tokenizer* t, char *text, int8_t bos, int8_t eos,
                   int *tokens, int *n_tokens) {
    if (text == NULL) { fprintf(stderr, "cannot encode NULL text\n"); exit(EXIT_FAILURE); }
    if (t->sorted_vocab == NULL) {
        t->sorted_vocab = malloc(t->vocab_size * sizeof(TokenIndex));
        for (int i = 0; i < t->vocab_size; i++) {
            t->sorted_vocab[i].str = t->vocab[i];
            t->sorted_vocab[i].id  = i;
        }
        qsort(t->sorted_vocab, t->vocab_size, sizeof(TokenIndex),
              compare_tokens);
    }
    char* str_buffer = malloc((t->max_token_length*2 + 1 + 2) * sizeof(char));
    size_t str_len = 0;
    *n_tokens = 0;
    if (bos) tokens[(*n_tokens)++] = 1;
    if (text[0] != '\0') {
        int dummy_prefix = str_lookup(" ", t->sorted_vocab, t->vocab_size);
        tokens[(*n_tokens)++] = dummy_prefix;
    }
    for (char *c = text; *c != '\0'; c++) {
        if ((*c & 0xC0) != 0x80) str_len = 0;
        str_buffer[str_len++] = *c;
        str_buffer[str_len]   = '\0';
        if ((*(c+1) & 0xC0) == 0x80 && str_len < 4) continue;
        int id = str_lookup(str_buffer, t->sorted_vocab, t->vocab_size);
        if (id != -1) {
            tokens[(*n_tokens)++] = id;
        } else {
            for (int i = 0; i < (int)str_len; i++)
                tokens[(*n_tokens)++] = (unsigned char)str_buffer[i] + 3;
        }
        str_len = 0;
    }
    while (1) {
        float best_score = -1e10;
        int best_id = -1, best_idx = -1;
        for (int i = 0; i < (*n_tokens - 1); i++) {
            sprintf(str_buffer, "%s%s", t->vocab[tokens[i]], t->vocab[tokens[i+1]]);
            int id = str_lookup(str_buffer, t->sorted_vocab, t->vocab_size);
            if (id != -1 && t->vocab_scores[id] > best_score) {
                best_score = t->vocab_scores[id];
                best_id    = id;
                best_idx   = i;
            }
        }
        if (best_idx == -1) break;
        tokens[best_idx] = best_id;
        for (int i = best_idx + 1; i < (*n_tokens - 1); i++)
            tokens[i] = tokens[i + 1];
        (*n_tokens)--;
    }
    if (eos) tokens[(*n_tokens)++] = 2;
    free(str_buffer);
}

/* ----------------------------------------------------------------------------
 * Sampler
 * -------------------------------------------------------------------------- */

typedef struct { float prob; int index; } ProbIndex;

typedef struct {
    int vocab_size;
    ProbIndex* probindex;
    float temperature;
    float topp;
    unsigned long long rng_state;
} Sampler;

static int sample_argmax(float* probabilities, int n) {
    int max_i = 0; float max_p = probabilities[0];
    for (int i = 1; i < n; i++) if (probabilities[i] > max_p) { max_i = i; max_p = probabilities[i]; }
    return max_i;
}

static int sample_mult(float* probabilities, int n, float coin) {
    float cdf = 0.0f;
    for (int i = 0; i < n; i++) { cdf += probabilities[i]; if (coin < cdf) return i; }
    return n - 1;
}

static int cmp_prob(const void* a, const void* b) {
    ProbIndex* a_ = (ProbIndex*)a;
    ProbIndex* b_ = (ProbIndex*)b;
    if (a_->prob > b_->prob) return -1;
    if (a_->prob < b_->prob) return  1;
    return 0;
}

static int sample_topp(float* probabilities, int n, float topp,
                        ProbIndex* probindex, float coin) {
    int n0 = 0;
    const float cutoff = (1.0f - topp) / (n - 1);
    for (int i = 0; i < n; i++) {
        if (probabilities[i] >= cutoff) {
            probindex[n0].index = i;
            probindex[n0].prob  = probabilities[i];
            n0++;
        }
    }
    qsort(probindex, n0, sizeof(ProbIndex), cmp_prob);
    float cumulative_prob = 0.0f;
    int last_idx = n0 - 1;
    for (int i = 0; i < n0; i++) {
        cumulative_prob += probindex[i].prob;
        if (cumulative_prob > topp) { last_idx = i; break; }
    }
    float r = coin * cumulative_prob, cdf = 0.0f;
    for (int i = 0; i <= last_idx; i++) {
        cdf += probindex[i].prob;
        if (r < cdf) return probindex[i].index;
    }
    return probindex[last_idx].index;
}

static void build_sampler(Sampler* sampler, int vocab_size,
                           float temperature, float topp,
                           unsigned long long rng_seed) {
    sampler->vocab_size = vocab_size;
    sampler->temperature = temperature;
    sampler->topp = topp;
    sampler->rng_state = rng_seed;
    sampler->probindex = malloc(sampler->vocab_size * sizeof(ProbIndex));
}

static void free_sampler(Sampler* sampler) { free(sampler->probindex); }

static unsigned int random_u32(unsigned long long *state) {
    *state ^= *state >> 12;
    *state ^= *state << 25;
    *state ^= *state >> 27;
    return (*state * 0x2545F4914F6CDD1Dull) >> 32;
}
static float random_f32(unsigned long long *state) {
    return (random_u32(state) >> 8) / 16777216.0f;
}

static int sample(Sampler* sampler, float* logits) {
    int next;
    if (sampler->temperature == 0.0f) {
        next = sample_argmax(logits, sampler->vocab_size);
    } else {
        for (int q = 0; q < sampler->vocab_size; q++) logits[q] /= sampler->temperature;
        softmax(logits, sampler->vocab_size);
        float coin = random_f32(&sampler->rng_state);
        if (sampler->topp <= 0 || sampler->topp >= 1)
            next = sample_mult(logits, sampler->vocab_size, coin);
        else
            next = sample_topp(logits, sampler->vocab_size, sampler->topp,
                               sampler->probindex, coin);
    }
    return next;
}

/* ----------------------------------------------------------------------------
 * Utilities
 * -------------------------------------------------------------------------- */

static long time_in_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* ----------------------------------------------------------------------------
 * INT16 fake-quantization (per-row symmetric): identical to run_i16.c.
 * Stores round(v/scale)*scale back as float so the row scale is recoverable.
 * -------------------------------------------------------------------------- */

static float* fq_i16_matrix(const float* src, long long nrows, int ncols) {
    long long total = nrows * (long long)ncols;
    float* dst = (float*)malloc(total * sizeof(float));
    if (!dst) { fprintf(stderr, "malloc failed in fq_i16_matrix\n"); exit(EXIT_FAILURE); }
    for (long long i = 0; i < nrows; i++) {
        const float* rs = src + i * ncols;
        float*       rd = dst + i * ncols;
        float mx = 0.0f;
        for (int j = 0; j < ncols; j++) { float v = fabsf(rs[j]); if (v > mx) mx = v; }
        float scale     = (mx > 0.0f) ? mx / 32767.0f : 1.0f;
        float inv_scale = (mx > 0.0f) ? 32767.0f / mx : 0.0f;
        for (int j = 0; j < ncols; j++) {
            float q = roundf(rs[j] * inv_scale);
            if (q >  32767.0f) q =  32767.0f;
            if (q < -32767.0f) q = -32767.0f;
            rd[j] = q * scale;
        }
    }
    return dst;
}

#define FQ_MAX_ALLOCS 16
static float* fq_allocs[FQ_MAX_ALLOCS];
static int    fq_alloc_count = 0;

static void apply_i16_fakequant(TransformerWeights* w, Config* p) {
    int kv_dim  = (p->dim * p->n_kv_heads) / p->n_heads;
    long long L = p->n_layers;
    int shared  = (w->wcls == w->token_embedding_table);

    float* emb = fq_i16_matrix(w->token_embedding_table, p->vocab_size, p->dim);
    fq_allocs[fq_alloc_count++] = emb; w->token_embedding_table = emb;

    float* wq = fq_i16_matrix(w->wq, L * p->dim, p->dim);
    fq_allocs[fq_alloc_count++] = wq; w->wq = wq;

    float* wk = fq_i16_matrix(w->wk, L * kv_dim, p->dim);
    fq_allocs[fq_alloc_count++] = wk; w->wk = wk;

    float* wv = fq_i16_matrix(w->wv, L * kv_dim, p->dim);
    fq_allocs[fq_alloc_count++] = wv; w->wv = wv;

    float* wo = fq_i16_matrix(w->wo, L * p->dim, p->dim);
    fq_allocs[fq_alloc_count++] = wo; w->wo = wo;

    float* w1 = fq_i16_matrix(w->w1, L * p->hidden_dim, p->dim);
    fq_allocs[fq_alloc_count++] = w1; w->w1 = w1;

    float* w2 = fq_i16_matrix(w->w2, L * p->dim, p->hidden_dim);
    fq_allocs[fq_alloc_count++] = w2; w->w2 = w2;

    float* w3 = fq_i16_matrix(w->w3, L * p->hidden_dim, p->dim);
    fq_allocs[fq_alloc_count++] = w3; w->w3 = w3;

    if (shared) {
        w->wcls = emb;
    } else {
        float* wcls = fq_i16_matrix(w->wcls, p->vocab_size, p->dim);
        fq_allocs[fq_alloc_count++] = wcls; w->wcls = wcls;
    }
    fprintf(stderr, "[i16-fq] applied int16 fake-quantization to %d weight tensors\n",
            fq_alloc_count);
}

static void free_fakequant_buffers(void) {
    for (int i = 0; i < fq_alloc_count; i++) { free(fq_allocs[i]); fq_allocs[i] = NULL; }
    fq_alloc_count = 0;
}

/* ----------------------------------------------------------------------------
 * Generation loop — dispatches forward() or forward_fx() via g_use_fx;
 * prints TOKID for every token decided (for coherence comparison).
 * -------------------------------------------------------------------------- */

/* Core generation loop shared by the CLI and the in-process library API.
 * Each GENERATED token's decoded piece goes to on_piece(piece, user) instead
 * of being printed directly, so the caller chooses the sink (stdout for the
 * CLI, an HTTP response for the server). The TOKID/stderr log and the --dump
 * golden files are kept unchanged so the CLI's golden/coherence scripts stay
 * byte-identical. Returns the number of positions advanced. */
int generate_stream(Transformer *transformer, Tokenizer *tokenizer,
                    Sampler *sampler, char *prompt, int steps,
                    llama_piece_cb on_piece, void *user) {
    char *empty_prompt = "";
    if (prompt == NULL) prompt = empty_prompt;

    int num_prompt_tokens = 0;
    int* prompt_tokens = (int*)malloc((strlen(prompt) + 3) * sizeof(int));
    encode(tokenizer, prompt, 1, 0, prompt_tokens, &num_prompt_tokens);
    if (num_prompt_tokens < 1) {
        fprintf(stderr, "something is wrong, expected at least 1 prompt token\n");
        free(prompt_tokens);
        return 0;
    }

    /* Dump prompt token ids (one per line) when --dump is set. Read-only
     * w.r.t. prompt_tokens/num_prompt_tokens -- does not mutate them. */
    if (g_dump) {
        FILE *pt_f = fopen("mem/golden/prompt_tokens.txt", "w");
        if (pt_f) {
            for (int i = 0; i < num_prompt_tokens; i++)
                fprintf(pt_f, "%d\n", prompt_tokens[i]);
            fclose(pt_f);
        } else {
            fprintf(stderr, "[dump] cannot open mem/golden/prompt_tokens.txt\n");
        }
        /* fx_embed.txt: golden BFP-encoded embedding rows for these same
         * prompt token ids (embed.vhd's TB golden; Plan 4 Task 3). */
        dump_embed_prompt(transformer->weights.token_embedding_table,
                           prompt_tokens, num_prompt_tokens,
                           transformer->config.dim);
    }

    /* Open fx_tokens_greedy.txt when --dump is set.  Written for all 200 tokens,
     * independent of the per-layer-0 dump guard in forward_fx. */
    FILE *tok_f = NULL;
    if (g_dump) {
        tok_f = fopen("mem/golden/fx_tokens_greedy.txt", "w");
        if (!tok_f)
            fprintf(stderr, "[dump] cannot open mem/golden/fx_tokens_greedy.txt\n");
    }

    int next;
    int token = prompt_tokens[0];
    int pos   = 0;
    while (pos < steps) {
        float* logits = g_use_fx ? forward_fx(transformer, token, pos)
                                 : forward(transformer, token, pos);

        if (pos < num_prompt_tokens - 1) {
            next = prompt_tokens[pos + 1];
        } else {
            next = sample(sampler, logits);
        }
        pos++;

        /* Log every decided token for run_tokens.sh comparison. */
        fprintf(stderr, "TOKID %d\n", next);
        if (tok_f) fprintf(tok_f, "%d\n", next);

        if (next == 1) break; /* BOS signals end-of-sequence */

        char* piece = decode(tokenizer, token, next);
        int stop = on_piece ? on_piece(piece, user) : 0;
        token = next;
        if (stop) break;
    }

    if (tok_f) fclose(tok_f);
    free(prompt_tokens);
    return pos;
}

/* CLI piece sink: print to stdout (the original generate() behaviour). */
static int cli_piece(const char *piece, void *user) {
    (void)user;
    safe_printf((char*)piece);
    fflush(stdout);
    return 0;   /* never stop early — run to `steps` as before */
}

/* CLI wrapper: same signature/behaviour as before — stream pieces to stdout,
 * a trailing newline, and the tok/s line. */
static void generate(Transformer *transformer, Tokenizer *tokenizer,
                     Sampler *sampler, char *prompt, int steps) {
    long t0 = time_in_ms();
    int pos = generate_stream(transformer, tokenizer, sampler, prompt, steps,
                              cli_piece, NULL);
    printf("\n");
    if (pos > 1) {
        long end = time_in_ms();
        fprintf(stderr, "achieved tok/s: %f\n",
                (pos - 1) / (double)(end - t0) * 1000);
    }
}

static void read_stdin(const char* guide, char* buffer, size_t bufsize) {
    printf("%s", guide);
    if (fgets(buffer, bufsize, stdin) != NULL) {
        size_t len = strlen(buffer);
        if (len > 0 && buffer[len - 1] == '\n') buffer[len - 1] = '\0';
    }
}

static void chat(Transformer *transformer, Tokenizer *tokenizer, Sampler *sampler,
                 char *cli_user_prompt, char *cli_system_prompt, int steps) {
    char system_prompt[512], user_prompt[512], rendered_prompt[1152];
    int num_prompt_tokens = 0;
    int* prompt_tokens = (int*)malloc(1152 * sizeof(int));
    int user_idx;
    int8_t user_turn = 1;
    int next = 0, token = 0, pos = 0;
    while (pos < steps) {
        if (user_turn) {
            if (pos == 0) {
                if (cli_system_prompt == NULL)
                    read_stdin("Enter system prompt (optional): ", system_prompt, sizeof(system_prompt));
                else
                    strcpy(system_prompt, cli_system_prompt);
            }
            if (pos == 0 && cli_user_prompt != NULL)
                strcpy(user_prompt, cli_user_prompt);
            else
                read_stdin("User: ", user_prompt, sizeof(user_prompt));
            if (pos == 0 && system_prompt[0] != '\0') {
                char tmpl[] = "[INST] <<SYS>>\n%s\n<</SYS>>\n\n%s [/INST]";
                sprintf(rendered_prompt, tmpl, system_prompt, user_prompt);
            } else {
                char tmpl[] = "[INST] %s [/INST]";
                sprintf(rendered_prompt, tmpl, user_prompt);
            }
            encode(tokenizer, rendered_prompt, 1, 0, prompt_tokens, &num_prompt_tokens);
            user_idx = 0; user_turn = 0;
            printf("Assistant: ");
        }
        if (user_idx < num_prompt_tokens) {
            token = prompt_tokens[user_idx++];
        } else {
            token = next;
        }
        if (token == 2) user_turn = 1;
        float* logits = g_use_fx ? forward_fx(transformer, token, pos)
                                 : forward(transformer, token, pos);
        next = sample(sampler, logits);
        pos++;
        if (user_idx >= num_prompt_tokens && next != 2) {
            char* piece = decode(tokenizer, token, next);
            safe_printf(piece); fflush(stdout);
        }
        if (next == 2) printf("\n");
    }
    printf("\n");
    free(prompt_tokens);
}

/* ----------------------------------------------------------------------------
 * CLI
 * -------------------------------------------------------------------------- */
#ifndef TESTING

static void error_usage(void) {
    fprintf(stderr, "Usage:   run_fx <checkpoint> [options]\n");
    fprintf(stderr, "Example: run_fx model.bin -n 256 -i \"Once upon a time\"\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -t <float>  temperature (default 1.0)\n");
    fprintf(stderr, "  -p <float>  top-p (default 0.9)\n");
    fprintf(stderr, "  -s <int>    random seed (default time)\n");
    fprintf(stderr, "  -n <int>    steps (default 256; 0 = max)\n");
    fprintf(stderr, "  -i <string> input prompt\n");
    fprintf(stderr, "  -z <string> tokenizer path\n");
    fprintf(stderr, "  -m <string> mode: generate|chat (default generate)\n");
    fprintf(stderr, "  -y <string> system prompt (chat mode)\n");
    fprintf(stderr, "  --fx        use integer block-fp forward (forward_fx)\n");
    fprintf(stderr, "  --dump      write golden vectors to mem/golden/fx_*.txt\n");
    exit(EXIT_FAILURE);
}

/* ----------------------------------------------------------------------------
 * In-process library API (llama_fx.h). Wraps the same verified path the CLI
 * uses. Compile run_fx.c with -DLLAMA_LIB to drop main() and link this.
 * -------------------------------------------------------------------------- */
struct LlamaCtx {
    Transformer transformer;
    Tokenizer   tokenizer;
};

LlamaCtx *llama_load(const char *checkpoint_path, const char *tokenizer_path) {
    LlamaCtx *c = (LlamaCtx*)calloc(1, sizeof(LlamaCtx));
    if (!c) return NULL;
    g_use_fx = 1;   /* serve the fixed-point (VHDL-equivalent) forward path */
    build_transformer(&c->transformer, (char*)checkpoint_path);
    build_tokenizer(&c->tokenizer, (char*)tokenizer_path,
                    c->transformer.config.vocab_size);
    return c;
}

int llama_seq_len(const LlamaCtx *ctx) { return ctx->transformer.config.seq_len; }
int llama_vocab(const LlamaCtx *ctx)   { return ctx->transformer.config.vocab_size; }

int llama_generate(LlamaCtx *ctx, const char *prompt, int max_tokens,
                   float temperature, float top_p, unsigned long long seed,
                   llama_piece_cb on_piece, void *user) {
    int steps = max_tokens;
    int seq   = ctx->transformer.config.seq_len;
    if (steps <= 0 || steps > seq) steps = seq;
    Sampler sampler;
    build_sampler(&sampler, ctx->transformer.config.vocab_size,
                  temperature, top_p, seed);
    int n = generate_stream(&ctx->transformer, &ctx->tokenizer, &sampler,
                            (char*)prompt, steps, on_piece, user);
    free_sampler(&sampler);
    return n;
}

void llama_free(LlamaCtx *ctx) {
    if (!ctx) return;
    free_transformer(&ctx->transformer);
    free_tokenizer(&ctx->tokenizer);
    free(ctx);
}

#ifndef LLAMA_LIB
int main(int argc, char *argv[]) {
    char *checkpoint_path = NULL;
    char *tokenizer_path  = "tokenizer.bin";
    float temperature     = 1.0f;
    float topp            = 0.9f;
    int   steps           = 256;
    char *prompt          = NULL;
    unsigned long long rng_seed = 0;
    char *mode            = "generate";
    char *system_prompt   = NULL;

    if (argc < 2) error_usage();
    checkpoint_path = argv[1];

    /* Arg parse: handles -x val short flags AND --fx / --dump boolean flags. */
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--fx") == 0) {
            g_use_fx = 1;
        } else if (strcmp(argv[i], "--dump") == 0) {
            g_dump = 1;
        } else if (argv[i][0] == '-' && strlen(argv[i]) == 2) {
            if (i + 1 >= argc) error_usage();
            char  flag = argv[i][1];
            char *val  = argv[++i];
            if      (flag == 't') temperature   = atof(val);
            else if (flag == 'p') topp           = atof(val);
            else if (flag == 's') rng_seed       = atoi(val);
            else if (flag == 'n') steps          = atoi(val);
            else if (flag == 'i') prompt         = val;
            else if (flag == 'z') tokenizer_path = val;
            else if (flag == 'm') mode           = val;
            else if (flag == 'y') system_prompt  = val;
            else error_usage();
        } else {
            error_usage();
        }
    }

    if (rng_seed <= 0)           rng_seed = (unsigned int)time(NULL);
    if (temperature < 0.0f)      temperature = 0.0f;
    if (topp < 0.0f || topp > 1.0f) topp = 0.9f;
    if (steps < 0)               steps = 0;

    Transformer transformer;
    build_transformer(&transformer, checkpoint_path);
    apply_i16_fakequant(&transformer.weights, &transformer.config);
    if (steps == 0 || steps > transformer.config.seq_len)
        steps = transformer.config.seq_len;

    /* Initialise fixed-point LUTs (idempotent). */
    fx_init();
    fx_rope_init(transformer.config.seq_len,
                 transformer.config.dim / transformer.config.n_heads);

    if (g_use_fx)
        fprintf(stderr, "[run_fx] forward path: forward_fx (integer block-fp matmul)\n");
    if (g_dump)
        fprintf(stderr, "[run_fx] --dump: will write golden vectors to mem/golden/fx_*.txt\n");

    Tokenizer tokenizer;
    build_tokenizer(&tokenizer, tokenizer_path, transformer.config.vocab_size);

    Sampler sampler;
    build_sampler(&sampler, transformer.config.vocab_size,
                  temperature, topp, rng_seed);

    if (strcmp(mode, "generate") == 0) {
        generate(&transformer, &tokenizer, &sampler, prompt, steps);
    } else if (strcmp(mode, "chat") == 0) {
        chat(&transformer, &tokenizer, &sampler, prompt, system_prompt, steps);
    } else {
        fprintf(stderr, "unknown mode: %s\n", mode);
        error_usage();
    }

    free_fakequant_buffers();
    free_sampler(&sampler);
    free_tokenizer(&tokenizer);
    free_transformer(&transformer);
    return 0;
}
#endif /* LLAMA_LIB */
#endif /* TESTING */
