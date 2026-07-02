/* ref/run_fx.c
 * Fork of run_i16.c.  All matmuls in forward_fx() run via integer
 * block-fp; nonlinearities (RMSNorm, RoPE, attention, softmax, SwiGLU)
 * stay in float for now.  Activations are block-fp quantised to int16
 * per matmul call; weights are per-row int16 fake-quant stored as float
 * multiples of their row scale (mantissas recovered on the fly).
 *
 * New flags (parsed in main):
 *   --fx    select forward_fx() instead of forward() in the generate loop
 *   --dump  reserved no-op (will be wired in Task 6)
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
#endif

#include "fx.h"

/* Global mode flags set by main() before generate() is called. */
static int g_use_fx = 0;   /* --fx: use forward_fx() */
static int g_dump   = 0;   /* --dump: no-op until Task 6 */

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

/* ----------------------------------------------------------------------------
 * forward_fx — copy of forward() with matmul() replaced by matmul_fx()
 * -------------------------------------------------------------------------- */
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

    /* Token embedding lookup (not a matmul — stays float). */
    float* content_row = w->token_embedding_table + token * dim;
    memcpy(x, content_row, dim * sizeof(*x));

    for (unsigned long long l = 0; l < (unsigned long long)p->n_layers; l++) {

        /* Attention RMSNorm (integer). */
        rmsnorm_fx(s->xb, x, w->rms_att_weight + l*dim, dim);

        int loff = l * p->seq_len * kv_dim;
        s->k = s->key_cache   + loff + pos * kv_dim;
        s->v = s->value_cache + loff + pos * kv_dim;

        /* QKV matmuls — integer block-fp. */
        matmul_fx(s->q,  s->xb, w->wq + l*dim*dim,    dim, dim);
        matmul_fx(s->k,  s->xb, w->wk + l*dim*kv_dim, dim, kv_dim);
        matmul_fx(s->v,  s->xb, w->wv + l*dim*kv_dim, dim, kv_dim);

        /* RoPE (float, uses fx.h tables only for validation in later tasks). */
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

        /* Multi-head attention (float). */
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

        /* Output projection — integer block-fp. */
        matmul_fx(s->xb2, s->xb, w->wo + l*dim*dim, dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb2[i];

        /* FFN RMSNorm (integer). */
        rmsnorm_fx(s->xb, x, w->rms_ffn_weight + l*dim, dim);

        /* FFN gate/up matmuls — integer block-fp. */
        matmul_fx(s->hb,  s->xb, w->w1 + l*dim*hidden_dim, dim, hidden_dim);
        matmul_fx(s->hb2, s->xb, w->w3 + l*dim*hidden_dim, dim, hidden_dim);

        /* SwiGLU nonlinearity (float). */
        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= (1.0f / (1.0f + expf(-val)));
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        /* FFN down projection — integer block-fp. */
        matmul_fx(s->xb, s->hb, w->w2 + l*dim*hidden_dim, hidden_dim, dim);
        for (int i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    /* Final RMSNorm (integer) + classifier (int block-fp). */
    rmsnorm_fx(x, x, w->rms_final_weight, dim);
    matmul_fx(s->logits, x, w->wcls, p->dim, p->vocab_size);
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

static void generate(Transformer *transformer, Tokenizer *tokenizer,
                     Sampler *sampler, char *prompt, int steps) {
    char *empty_prompt = "";
    if (prompt == NULL) prompt = empty_prompt;

    int num_prompt_tokens = 0;
    int* prompt_tokens = (int*)malloc((strlen(prompt) + 3) * sizeof(int));
    encode(tokenizer, prompt, 1, 0, prompt_tokens, &num_prompt_tokens);
    if (num_prompt_tokens < 1) {
        fprintf(stderr, "something is wrong, expected at least 1 prompt token\n");
        exit(EXIT_FAILURE);
    }

    long start = 0;
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

        if (next == 1) break; /* BOS signals end-of-sequence */

        char* piece = decode(tokenizer, token, next);
        safe_printf(piece);
        fflush(stdout);
        token = next;

        if (start == 0) start = time_in_ms();
    }
    printf("\n");

    if (pos > 1) {
        long end = time_in_ms();
        fprintf(stderr, "achieved tok/s: %f\n", (pos - 1) / (double)(end - start) * 1000);
    }
    free(prompt_tokens);
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
    fprintf(stderr, "  --dump      reserved no-op (Task 6)\n");
    exit(EXIT_FAILURE);
}

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
        fprintf(stderr, "[run_fx] --dump flag set (no-op until Task 6)\n");

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
#endif /* TESTING */
