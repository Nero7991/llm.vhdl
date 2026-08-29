/* ref/run9b.c -- a whole-model numeric reference for Qwen3.5-9B.
 *
 * ===========================================================================
 * THE QUESTION THIS FILE ANSWERS
 * ===========================================================================
 * Before it, `ref/` held exactly one whole-model reference and it was
 * stories260K.  Every 9B claim in the repository was per-unit or per-seam, so
 * "the card produced its first token" was UNFALSIFIABLE: the card emits *a*
 * token and nothing here could distinguish the right one from a wrong one, and
 * on-card numeric debugging had no stream to diff against.
 *
 * ===========================================================================
 * FLOAT OR FIXED POINT -- THE DECISION, AND ITS DEFENCE
 * ===========================================================================
 * BOTH, LAYERED, with the gap between the layers MEASURED rather than assumed.
 * There are three rungs and each one isolates exactly one thing:
 *
 *   rung 1  llama.cpp on the BF16 GGUF                tools/ref9b/dump_llamacpp
 *           The ALGORITHM oracle.  Not written here, not written by anyone on
 *           this project, exercised by a large user base against the published
 *           checkpoint.  This is the answer to the m7 mutant: a reference and
 *           an RTL that share their author's wrong idea agree with each other
 *           and are both wrong, and the only escape from that is an
 *           implementation whose author never read our spec.  It is also the
 *           same anchor that certified this project's tokenizer bit-exactly
 *           over 53,409 strings, so the method has precedent here.
 *
 *   rung 2  this file, --acts f32                     INT4 weights, f64 acts
 *           Reads the REAL PACKED BYTES (the .mv4i files the card will read
 *           from HBM) and dequantizes them, but carries activations in double.
 *           rung1 -> rung2 is therefore the cost of the INT4 WEIGHT FORMAT and
 *           of nothing else.
 *
 *   rung 3  this file, --acts bfp                     the hardware model
 *           Every value that lives in a `llama_top` REGION is an int16
 *           mantissa vector with one shared exponent, exactly as
 *           `rtl/llama_top.vhd:792` stores it, and every matvec is
 *           `ref/matvec_int4.c` run BIT-EXACTLY on those bytes.  rung2 ->
 *           rung3 is the cost of the ACTIVATION format.
 *
 * WHICH COPY OF THE EMBEDDING THE RUNGS EVALUATE -- CHANGED 2026-08-29.
 * The embedding row is an ACTIVATION, not a weight, and it was read from the
 * packed INT4 set only because `token_embd.weight` happened to be packed
 * alongside the weight tensors.  It is now read from the BF16 GGUF by default
 * (`--embed gguf`), which is roughly 2,000x more accurate at the activation.
 * MEASURED, that buys 2.3% at the logits on the token the headline quotes
 * (0.12524 -> 0.12237 relative RMS for the weight format), 0.7% averaged over
 * the five reference positions, and it makes TWO OF THE FIVE slightly worse.
 * Every next token and every top-5 is unchanged.  `--embed mv4i` still
 * reproduces the pre-2026-08-29 stream BYTE FOR BYTE.  See `embed()` below and
 * docs/debugging/2026-08-29_embedding-bf16-upgrade.md.
 *
 * WHAT IS BIT-EXACT HERE AND WHAT IS NOT.  Say it plainly, because a reference
 * that overstates itself is worse than none:
 *
 *   BIT-EXACT   every subsystem A job.  The arithmetic is `mv4i_matvec` from
 *               ref/matvec_int4.c, which is already trusted by several tracks,
 *               on the real packed bytes, and the four rounding primitives
 *               come from ref/mv4i_arith.h, which tools/gen_arith.py generates
 *               into BOTH this and rtl/mv4i_arith_pkg.vhd from one description.
 *               Given the same input region, this file's A output is the
 *               hardware's A output or one of them is defective.
 *
 *   NOT EXACT   everything between two A jobs: the norms, the 4-tap conv, the
 *               SiLU, the softplus, the sigmoid, the L2 norm, the delta-rule
 *               recurrence, the attention kernel, the SwiGLU and the residual
 *               add.  Those are computed in double and re-packed to the region
 *               format on the way out.  A fixed-point transcription of them
 *               WOULD be bit-exact and is deliberately NOT attempted here: the
 *               RTL's recipes for those live in ~20 units with no composed
 *               description at the 9B shape, and re-deriving them from the
 *               specs is precisely how a second implementation of the same
 *               misunderstanding gets written.  Subsystem B and C tracks own
 *               that work; when it lands, each stage drops into the hooks
 *               marked FX-HOOK below and the claim strengthens one stage at a
 *               time, each with its own measured gap.
 *
 * SO WHAT MAKES THIS TRUSTWORTHY, AND WHAT WOULD MAKE IT CONFIDENTLY WRONG.
 *   Trustworthy: every seam is compared against rung 1, which no one here
 *   wrote; the weights are the card's own bytes rather than a re-quantization;
 *   the A arithmetic is a reference other tracks already depend on.
 *   Confidently wrong: if llama.cpp's `qwen35` implementation is itself wrong
 *   for this checkpoint, all three rungs agree and all three are wrong.  That
 *   is a single point of failure and it is NOT closed by anything in this
 *   repository.  The cheapest partial defence -- comparing generated text
 *   against the published model card -- is not a numeric check and is not
 *   claimed as one.
 *
 * ===========================================================================
 * SEAM NAMES COME FROM THE RTL, NOT FROM THE SPEC
 * ===========================================================================
 * The names below are `rtl/llama_map_pkg.vhd`'s REGION names, because a region
 * is what the hardware can actually be asked for: `hr_reg`/`hr_addr`/`hr_data`
 * (rtl/llama_top.vhd:483-485, combinational at :1005) reads any element of any
 * region.  The step order is `sim/seq_tbl_pkg.vhd`'s descriptor table.  The
 * mapping onto llama.cpp's node names lives in tools/ref9b/seam_map.py, and
 * the places where the two DISAGREE are listed in
 * docs/debugging/2026-08-29_9b-whole-model-reference.md section 3.
 *
 * Build:  cc -O2 -Wall -Wextra -I ref -o ref/run9b ref/run9b.c -lm
 *         (assertions must stay ON; ref/matvec_int4.c refuses -DNDEBUG)
 */

#define MV4I_LIB
#include "matvec_int4.c"          /* mv4i_parse, mv4i_matvec, get_widx, get_scale */
#include "embed_bf16.c"           /* the BF16 embedding row, straight from the GGUF */

#include <math.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "../tools/ref9b/seam_stream.h"

/* ------------------------------------------------------------------ shape */
/* MEASURED against the GGUF's own metadata on 2026-08-29 (see the write-up
 * section 2); identical to rtl/model_cfg_pkg.vhd's QWEN35_9B record, which
 * until now had never been checked against a 9B checkpoint at all because
 * there was none on this machine. */
enum {
    N_LAYER   = 32,
    ATTN_INT  = 4,        /* attention when (il+1) % ATTN_INT == 0 */
    HIDDEN    = 4096,
    FFN       = 12288,
    VOCAB     = 248320,

    LIN_KH    = 16,       /* GDN key heads   = ssm.group_count      */
    LIN_VH    = 32,       /* GDN value heads = ssm.time_step_rank   */
    LIN_HD    = 128,      /* GDN head dim    = ssm.state_size       */
    KCONV     = 4,
    KEY_DIM   = LIN_KH * LIN_HD,   /* 2048 */
    VAL_DIM   = LIN_VH * LIN_HD,   /* 4096 */
    CONV_DIM  = 2 * KEY_DIM + VAL_DIM, /* 8192 */

    ATT_QH    = 16,
    ATT_KVH   = 4,
    ATT_HD    = 256,
    N_ROT     = 64,
};
#define RMS_EPS   1e-6
#define ROPE_BASE 1.0e7

/* ------------------------------------------------------------- mutants ----
 * TEETH.  A checker never shown to fail has not been shown to work, and the
 * thing being checked here is not one unit but the whole chain: this file, the
 * seam map, and the bisect.  So the risky decisions are each reachable as a
 * compile-time mutant, chosen because each one is a defect a careful person
 * would plausibly write, not an arbitrary bit flip:
 *
 *   1 QG_BLOCK    read R_QG as [all q | all gate] instead of interleaved
 *                 per head.  This is THE most likely real defect in subsystem
 *                 C's consumer, because [all q | all gate] is what every other
 *                 fused projection in this model does.
 *   2 L2_EPS      l2norm as x/sqrt(sum+eps) instead of x/max(sqrt(sum),eps)
 *   3 VHEAD       GDN value head h reads key head h/2 instead of h%16
 *   4 ROPE_PAIR   RoPE pairs (2i, 2i+1) instead of NeoX (i, i+32)
 *   5 GATE_ORDER  ssm_norm AFTER the z gate, so the gate enters the statistic
 *   6 SOFTPLUS    softplus without ggml's hard passthrough above 20
 *   7 RMS_EPS_OUT rmsnorm eps added outside the sqrt
 *   8 QKV_UNPAD   read the three qkv segments at the UNPADDED starts 0/2048/
 *                 4096 rather than the packer's tile-aligned 0/2064/4128
 *   9 GQA         attention q head h maps to kv head h%4 instead of h/4
 *
 * Build one with -DREF9B_MUT=n.  A mutant that the bisect does NOT locate is
 * reported under its own name in the write-up: those rows measure the harness's
 * resolution floor and they are the most valuable line in the table.
 */
#ifndef REF9B_MUT
#define REF9B_MUT 0
#endif

/* ------------------------------------------------------------------ index */
typedef struct { char name[8]; int row_start, n_rows, logical_row; } seg_t;

typedef struct {
    char      tensor[64];
    char      file[80];
    int       M, K, w_exp, out_shift, nseg;
    seg_t     seg[4];
    /* lazily mapped */
    const uint8_t *img; size_t len; mv4i_file f; int parsed;
} mvw_t;

typedef struct { char name[64]; long off, nbytes; int ne0, ne1; } f32e_t;

static mvw_t  *g_mv; static int g_nmv;
static f32e_t *g_f32; static int g_nf32;
static const float *g_blob; static size_t g_blob_len;
static char g_dir[512];

static void die(const char *m) { fprintf(stderr, "run9b: %s\n", m); exit(1); }

static const uint8_t *map_file(const char *path, size_t *len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); exit(1); }
    struct stat st;
    if (fstat(fd, &st)) { perror(path); exit(1); }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    close(fd);
    *len = (size_t)st.st_size;
    return (const uint8_t *)p;
}

static void load_index(const char *dir)
{
    char p[600];
    snprintf(g_dir, sizeof g_dir, "%s", dir);
    snprintf(p, sizeof p, "%s/index.txt", dir);
    FILE *fp = fopen(p, "r");
    if (!fp) { perror(p); die("run tools/ref9b/make_index.py first"); }

    g_mv  = calloc(512, sizeof *g_mv);
    g_f32 = calloc(512, sizeof *g_f32);
    char line[4096];
    while (fgets(line, sizeof line, fp)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char kind[16];
        if (sscanf(line, "%15s", kind) != 1) continue;
        if (!strcmp(kind, "MV4I")) {
            mvw_t *m = &g_mv[g_nmv];
            int off = 0, got;
            got = sscanf(line, "%*s %63s %79s %d %d %d %d %d%n",
                         m->tensor, m->file, &m->M, &m->K,
                         &m->w_exp, &m->out_shift, &m->nseg, &off);
            if (got != 7) die("bad MV4I line");
            const char *q = line + off;
            for (int s = 0; s < m->nseg; s++) {
                int n2 = 0;
                if (sscanf(q, " %7s %d %d %d%n", m->seg[s].name,
                           &m->seg[s].row_start, &m->seg[s].n_rows,
                           &m->seg[s].logical_row, &n2) != 4)
                    die("bad MV4I segment");
                q += n2;
            }
            g_nmv++;
        } else if (!strcmp(kind, "BLOB")) {
            char rel[128]; sscanf(line, "%*s %127s", rel);
            char full[700]; snprintf(full, sizeof full, "%s/%s", dir, rel);
            g_blob = (const float *)map_file(full, &g_blob_len);
        } else if (!strcmp(kind, "F32")) {
            f32e_t *e = &g_f32[g_nf32];
            if (sscanf(line, "%*s %63s %ld %ld %d %d",
                       e->name, &e->off, &e->nbytes, &e->ne0, &e->ne1) != 5)
                die("bad F32 line");
            g_nf32++;
        }
    }
    fclose(fp);
    if (!g_blob) die("index has no BLOB record");
}

static mvw_t *mv(const char *tensor)
{
    for (int i = 0; i < g_nmv; i++) if (!strcmp(g_mv[i].tensor, tensor)) {
        mvw_t *m = &g_mv[i];
        if (!m->parsed) {
            char full[700]; snprintf(full, sizeof full, "%s/%s", g_dir, m->file);
            m->img = map_file(full, &m->len);
            if (mv4i_parse(&m->f, m->img, m->len)) die("mv4i_parse refused a packed file");
            /* The index and the file header are two independent statements of
             * the same geometry.  Disagreeing about M or K silently would make
             * every row window wrong, so it is a refusal, not a warning. */
            if ((int)m->f.h.M != m->M || (int)m->f.h.K != m->K ||
                m->f.h.w_exp != m->w_exp || m->f.h.out_shift != m->out_shift)
                die("index disagrees with the .mv4i header");
            m->parsed = 1;
        }
        return m;
    }
    fprintf(stderr, "run9b: no packed tensor %s\n", tensor);
    exit(1);
}

static const float *f32t(const char *name, int *n)
{
    for (int i = 0; i < g_nf32; i++) if (!strcmp(g_f32[i].name, name)) {
        if (n) *n = (int)(g_f32[i].nbytes / 4);
        return g_blob + g_f32[i].off / 4;
    }
    fprintf(stderr, "run9b: no f32 tensor %s\n", name);
    exit(1);
}

/* --------------------------------------------------------------- the seam */
/* A region as `llama_top` stores it: int16 mantissas plus ONE shared exponent,
 * value = mant * 2^-exp (tools/pack_int4.py:14 fixes the sign of the
 * convention).  In --acts f32 the mantissa array is unused and `v` carries the
 * value directly; the two are kept in one struct so every stage below reads
 * `reg_get`/`reg_put` and no stage has to know which mode it is in. */
typedef struct { int n, exp; int16_t *m; double *v; } reg_t;

static int   g_bfp = 1;            /* --acts bfp (default) or f32 */
static FILE *g_seam = NULL;
static int   g_tok = 0;
static long  g_recs = 0;

static reg_t reg_new(int n)
{
    reg_t r; r.n = n; r.exp = 0;
    r.m = calloc((size_t)n, sizeof *r.m);
    r.v = calloc((size_t)n, sizeof *r.v);
    if (!r.m || !r.v) die("out of memory");
    return r;
}

/* float -> region.  The rule is bfp_pack's (rtl/bfp_pack.vhd:9-10):
 * shift so the largest magnitude lands in bit 14, round half toward +inf,
 * saturate to int16.  It is expressed on a float input rather than on
 * bfp_pack's int32 Q-grid input, so it is VALUE-equivalent and NOT claimed
 * bit-identical; that is one of the gaps the write-up prices. */
static void reg_put(reg_t *r, const double *v)
{
    if (!g_bfp) { memcpy(r->v, v, sizeof(double) * (size_t)r->n); r->exp = 0; return; }
    double amax = 0;
    for (int i = 0; i < r->n; i++) { double a = fabs(v[i]); if (a > amax) amax = a; }
    if (amax == 0) { r->exp = 0; for (int i = 0; i < r->n; i++) r->m[i] = 0; }
    else {
        int e = (int)floor(log2(amax));
        r->exp = 14 - e;
        for (int i = 0; i < r->n; i++) {
            double s = ldexp(v[i], r->exp);
            long long q = (long long)floor(s + 0.5);   /* half toward +inf */
            r->m[i] = mv4i_sat16(q);
        }
    }
    for (int i = 0; i < r->n; i++) r->v[i] = ldexp((double)r->m[i], -r->exp);
}

static const double *reg_get(const reg_t *r) { return r->v; }

/* Emit a region as a seam.  In bfp mode the record is BFP16, which is what a
 * hardware capture can be compared against EXACTLY.  In f32 mode it is F32. */
static void seam(const char *name, int layer, const reg_t *r)
{
    if (!g_seam) return;
    int rc;
    if (g_bfp) rc = r9bs_write_bfp(g_seam, name, g_tok, layer, r->m,
                                   (uint32_t)r->n, r->exp);
    else {
        float *tmp = malloc(sizeof(float) * (size_t)r->n);
        for (int i = 0; i < r->n; i++) tmp[i] = (float)r->v[i];
        rc = r9bs_write_f32(g_seam, name, g_tok, layer, tmp, (uint32_t)r->n);
        free(tmp);
    }
    if (rc) die("seam write failed");
    g_recs++;
}

static void seam_f32(const char *name, int layer, const double *v, int n)
{
    if (!g_seam) return;
    float *tmp = malloc(sizeof(float) * (size_t)n);
    for (int i = 0; i < n; i++) tmp[i] = (float)v[i];
    if (r9bs_write_f32(g_seam, name, g_tok, layer, tmp, (uint32_t)n))
        die("seam write failed");
    free(tmp);
    g_recs++;
}

/* The argmax, written out rather than inlined, because the TIE RULE is the
 * part a second implementation gets wrong silently.  `rtl/sampler_stream.vhd`
 * seeds its candidate with index 0 and displaces it only on a STRICT `>`, so
 * the FIRST maximum wins.  `tools/ref9b/bisect_scaled.py:argmax_first` is the
 * same rule again on the scaled side.  NOTE the rule is UNEXERCISED wherever
 * the logits are all distinct, which they are on the reference prompt -- so
 * agreement between the three rungs is not evidence about ties. */
static int argmax_first(const double *v, int n)
{
    int bi = 0;
    for (int i = 1; i < n; i++) if (v[i] > v[bi]) bi = i;
    return bi;
}

/* The TOKEN seam: the argmax this reference itself picked.
 *
 * WHY IT IS A RECORD AND NOT A printf.  Until 2026-08-29 run9b computed the
 * argmax and PRINTED it, so the one quantity that decides a token was the only
 * one in the whole stream that could not be compared without a human reading
 * stdout.  A card capture emits `TOKEN` as S32 (tools/ref9b/seam_stream.h, and
 * sim/tb_llama_top.vhd's stream collector), so this side emits S32 too and
 * `seam_bisect --mode exact` compares it bit-for-bit.
 *
 * AND IT IS EXACT EVEN THOUGH `LOGITS` HERE CANNOT BE.  This reference writes
 * LOGITS as F32 while the design publishes raw s32, so those two kinds will
 * never compare exactly; a token INDEX has no such problem.  So the seam that
 * decides the token is exactly comparable even where the vector behind it is
 * not.  What that buys is bounded, and section 5.7 of
 * docs/debugging/2026-08-29_logits-seam-model.md measured the bound: an argmax
 * moves only when a logit crosses the runner-up, so a TOKEN agreement is
 * silent about every smaller error, and a LOGITS agreement is silent about a
 * sampler that reduced the right values wrongly. */
static void seam_token(int best)
{
    if (!g_seam) return;
    int32_t v = (int32_t)best;
    if (r9bs_write_s32(g_seam, "TOKEN", g_tok, -1, &v, 1, 0))
        die("seam write failed");
    g_recs++;
}

/* --------------------------------------------------------------- matvec */
/* Dequantized weight, for rung 2.  get_widx/get_scale are matvec_int4.c's own
 * accessors, so the BYTE LAYOUT is read by exactly one implementation and this
 * mode cannot disagree with the exact mode about which weight is which. */
static double w_deq(const mv4i_file *f, int r, int k)
{
    int8_t cb = f->h.codebook[get_widx(f, r, k)];
    uint16_t sc = get_scale(f, r, k / MV4I_BLOCK);
    return ldexp((double)cb * (double)sc / 32768.0, -f->h.w_exp);
}

/* One subsystem A job: rows [row0, row0+nrows) of `tensor` applied to `x`.
 *
 * WHY IT GOES THROUGH RAW MODE AND SCANS ITSELF.  mv4i_matvec has no row
 * WINDOW: it computes rows 0..n_rows-1.  The fused attn_qkv is three jobs at
 * tile-aligned starts 0 / 2064 / 4128, each with its OWN block exponent, so a
 * window is exactly what is needed.  Rather than re-derive the arithmetic, the
 * job runs in RAW mode -- which is the same accumulate and the same
 * `round_shift(acc, out_shift)`, with no BFP scan -- and the scan is then done
 * over the window using the SAME generated primitives from ref/mv4i_arith.h.
 * `--selftest` checks that a full-range window reproduces MV4I_MODE_BFP
 * bit-for-bit, which is the only thing that makes this substitution safe. */
static void a_job(const char *tensor, int seg, const reg_t *x, reg_t *y)
{
    mvw_t *m = mv(tensor);
    if (seg >= m->nseg) die("segment out of range");
    int row0 = m->seg[seg].row_start, nrows = m->seg[seg].n_rows;
#if REF9B_MUT == 8
    row0 = m->seg[seg].logical_row;                        /* MUTANT 8 */
#endif
    if (y->n != nrows) die("destination region has the wrong length");
    if (x->n != m->K) die("source region has the wrong length");

    if (!g_bfp) {
        for (int r = 0; r < nrows; r++) {
            double acc = 0;
            for (int k = 0; k < m->K; k++) acc += w_deq(&m->f, row0 + r, k) * x->v[k];
            y->v[r] = acc;
        }
        y->exp = 0;
        return;
    }

    static int32_t *ybuf; static int ybuf_n;
    int need = row0 + nrows;
    if (need > ybuf_n) { ybuf = realloc(ybuf, sizeof(int32_t) * (size_t)need); ybuf_n = need; }
    mv4i_result res;
    res.y_data = ybuf; res.y_mant = NULL; res.y_acc = NULL;
    if (mv4i_matvec(&m->f, x->m, x->exp, need, m->K, MV4I_MODE_RAW, &res))
        die("mv4i_matvec refused a job");

    uint64_t amax = 0;
    for (int r = 0; r < nrows; r++) {
        int64_t a = ybuf[row0 + r]; if (a < 0) a = -a;
        if ((uint64_t)a > amax) amax = (uint64_t)a;
    }
    int ns = mv4i_msb_pos_u(amax) - 14; if (ns < 0) ns = 0;
    for (int r = 0; r < nrows; r++)
        y->m[r] = mv4i_sat16(mv4i_round_shift((int64_t)ybuf[row0 + r], ns));
    y->exp = m->f.h.w_exp + x->exp - m->f.h.out_shift - ns;
    for (int r = 0; r < nrows; r++) y->v[r] = ldexp((double)y->m[r], -y->exp);
}

/* The lm_head job.  rtl/llama_top's schedule runs it with out_mode = 1 (raw)
 * and dst = R_NONE, i.e. it computes the logits and THROWS THEM AWAY -- see
 * the write-up section 3, defect D1.  Here they are kept, because a reference
 * whose last step discards the answer cannot say whether a token is right. */
static void lm_head(const reg_t *x, double *logits)
{
    mvw_t *m = mv("output.weight");
    if (!g_bfp) {
        for (int r = 0; r < VOCAB; r++) {
            double acc = 0;
            for (int k = 0; k < m->K; k++) acc += w_deq(&m->f, r, k) * x->v[k];
            logits[r] = acc;
        }
        return;
    }
    static int32_t *yb;
    if (!yb) yb = malloc(sizeof(int32_t) * VOCAB);
    mv4i_result res; res.y_data = yb; res.y_mant = NULL; res.y_acc = NULL;
    if (mv4i_matvec(&m->f, x->m, x->exp, VOCAB, m->K, MV4I_MODE_RAW, &res))
        die("lm_head refused");
    int e = m->f.h.w_exp + x->exp - m->f.h.out_shift;
    for (int r = 0; r < VOCAB; r++) logits[r] = ldexp((double)yb[r], -e);
}

/* --------------------------------------------------------- FX-HOOK stages */
/* Every function below is rung 2/3's float stand-in for an RTL unit.  When a
 * subsystem B or C track lands a composed fixed-point recipe at the 9B shape,
 * it replaces the body here and the write-up gains one more measured gap. */

static void rmsnorm(const double *x, const float *w, int n, double *o)
{
    double s = 0; for (int i = 0; i < n; i++) s += x[i] * x[i];
#if REF9B_MUT == 7
    double inv = 1.0 / (sqrt(s / n) + RMS_EPS);   /* MUTANT 7 */
#else
    double inv = 1.0 / sqrt(s / n + RMS_EPS);
#endif
    for (int i = 0; i < n; i++) o[i] = x[i] * inv * (double)w[i];
}

/* ggml_l2_norm: scale = 1/max(sqrt(SUM x^2), eps).  SUM not mean, MAX not add.
 * Both differences from rmsnorm are real and both are easy to get wrong. */
static void l2norm(double *x, int n)
{
    double s = 0; for (int i = 0; i < n; i++) s += x[i] * x[i];
#if REF9B_MUT == 2
    double d = sqrt(s + RMS_EPS);                 /* MUTANT 2 */
#else
    double d = sqrt(s); if (d < RMS_EPS) d = RMS_EPS;
#endif
    for (int i = 0; i < n; i++) x[i] /= d;
}

static double silu(double x)    { return x / (1.0 + exp(-x)); }
static double sigmoidd(double x){ return 1.0 / (1.0 + exp(-x)); }
/* ggml_softplus clamps: returns x verbatim above 20. */
#if REF9B_MUT == 6
static double softplus(double x){ return log1p(exp(x)); }   /* MUTANT 6 */
#else
static double softplus(double x){ return x > 20.0 ? x : log1p(exp(x)); }
#endif

/* ------------------------------------------------------------ model state */
typedef struct {
    double *conv_state;   /* [N_LAYER][KCONV-1][CONV_DIM] GDN layers only */
    double *rec_state;    /* [N_LAYER][LIN_VH][LIN_HD key][LIN_HD val]    */
    double *kcache, *vcache; /* [N_LAYER][MAXPOS][ATT_KVH*ATT_HD]         */
    int     maxpos;
} state_t;

static int is_attn(int il) { return ((il + 1) % ATTN_INT) == 0; }

/* --------------------------------------------------------------- one layer */
static void layer_gdn(int il, state_t *S, reg_t *RX, int pos)
{
    (void)pos;
    char nm[80], tn[80];
    static reg_t RXN, RQ, RK, RV, RZ, RB, RA, RY, RER, RG, RU, RH;
    if (!RXN.n) {
        RXN = reg_new(HIDDEN); RQ = reg_new(KEY_DIM); RK = reg_new(KEY_DIM);
        RV  = reg_new(VAL_DIM); RZ = reg_new(HIDDEN); RB = reg_new(LIN_VH);
        RA  = reg_new(LIN_VH);  RY = reg_new(VAL_DIM); RER = reg_new(HIDDEN);
        RG  = reg_new(FFN); RU = reg_new(FFN); RH = reg_new(FFN);
    }
    double *t = malloc(sizeof(double) * (size_t)FFN);

    /* --- OP_VEC_NORM  R_X -> R_XN --------------------------------------- */
    snprintf(tn, sizeof tn, "blk.%d.attn_norm.weight", il);
    rmsnorm(reg_get(RX), f32t(tn, NULL), HIDDEN, t);
    reg_put(&RXN, t);
    snprintf(nm, sizeof nm, "R_XN-%d", il); seam(nm, il, &RXN);

    /* --- three A jobs into R_QKV, one per segment, one exponent each ----- */
    snprintf(tn, sizeof tn, "blk.%d.attn_qkv.weight", il);
    a_job(tn, 0, &RXN, &RQ); snprintf(nm, sizeof nm, "R_QKV.q-%d", il); seam(nm, il, &RQ);
    a_job(tn, 1, &RXN, &RK); snprintf(nm, sizeof nm, "R_QKV.k-%d", il); seam(nm, il, &RK);
    a_job(tn, 2, &RXN, &RV); snprintf(nm, sizeof nm, "R_QKV.v-%d", il); seam(nm, il, &RV);

    snprintf(tn, sizeof tn, "blk.%d.attn_gate.weight", il);
    a_job(tn, 0, &RXN, &RZ); snprintf(nm, sizeof nm, "R_Z-%d", il); seam(nm, il, &RZ);
    snprintf(tn, sizeof tn, "blk.%d.ssm_beta.weight", il);
    a_job(tn, 0, &RXN, &RB); snprintf(nm, sizeof nm, "R_BETA-%d", il); seam(nm, il, &RB);
    snprintf(tn, sizeof tn, "blk.%d.ssm_alpha.weight", il);
    a_job(tn, 0, &RXN, &RA); snprintf(nm, sizeof nm, "R_ALPHA-%d", il); seam(nm, il, &RA);

    /* --- OP_B_JOB  R_QKV -> R_Y  (subsystem B) --------------------------- */
    double *mixed = malloc(sizeof(double) * CONV_DIM);
    memcpy(mixed,                 reg_get(&RQ), sizeof(double) * KEY_DIM);
    memcpy(mixed + KEY_DIM,       reg_get(&RK), sizeof(double) * KEY_DIM);
    memcpy(mixed + 2 * KEY_DIM,   reg_get(&RV), sizeof(double) * VAL_DIM);

    /* 4-tap causal depthwise conv, then SiLU.  ggml_ssm_conv:
     *   out[c] = sum_{i<4} in[t+i, c] * W[i, c],  no bias.
     * The state holds the previous KCONV-1 columns. */
    int nc; const float *cw = f32t((snprintf(tn, sizeof tn,
                    "blk.%d.ssm_conv1d.weight", il), tn), &nc);
    if (nc != KCONV * CONV_DIM) die("ssm_conv1d has an unexpected size");
    double *cs = S->conv_state + (size_t)il * (KCONV - 1) * CONV_DIM;
    double *conv = malloc(sizeof(double) * CONV_DIM);
    for (int c = 0; c < CONV_DIM; c++) {
        double acc = 0;
        for (int i = 0; i < KCONV - 1; i++)
            acc += cs[(size_t)i * CONV_DIM + c] * (double)cw[(size_t)c * KCONV + i];
        acc += mixed[c] * (double)cw[(size_t)c * KCONV + (KCONV - 1)];
        conv[c] = silu(acc);
    }
    for (int i = 0; i < KCONV - 2; i++)
        memcpy(cs + (size_t)i * CONV_DIM, cs + (size_t)(i + 1) * CONV_DIM,
               sizeof(double) * CONV_DIM);
    memcpy(cs + (size_t)(KCONV - 2) * CONV_DIM, mixed, sizeof(double) * CONV_DIM);

    double *qc = conv, *kc = conv + KEY_DIM, *vc = conv + 2 * KEY_DIM;
    for (int h = 0; h < LIN_KH; h++) { l2norm(qc + h * LIN_HD, LIN_HD);
                                       l2norm(kc + h * LIN_HD, LIN_HD); }

    const float *ssm_a  = f32t((snprintf(tn, sizeof tn, "blk.%d.ssm_a", il), tn), NULL);
    const float *dt_b   = f32t((snprintf(tn, sizeof tn, "blk.%d.ssm_dt.bias", il), tn), NULL);
    double beta[LIN_VH], gdec[LIN_VH];
    for (int h = 0; h < LIN_VH; h++) {
        beta[h] = sigmoidd(reg_get(&RB)[h]);
        /* ssm_a already holds -exp(A_log): the converter negates and exps. */
        gdec[h] = softplus(reg_get(&RA)[h] + (double)dt_b[h]) * (double)ssm_a[h];
    }

    /* delta rule.  S[i][j], i = key index, j = value index.  Value head h
     * reads key/query head h % LIN_KH -- the tiled broadcast, which the GGUF
     * conversion has already reordered the V rows to match. */
    double *st = S->rec_state + (size_t)il * LIN_VH * LIN_HD * LIN_HD;
    double *out = malloc(sizeof(double) * VAL_DIM);
    const double qscale = 1.0 / sqrt((double)LIN_HD);
    for (int h = 0; h < LIN_VH; h++) {
        double *Sh = st + (size_t)h * LIN_HD * LIN_HD;
#if REF9B_MUT == 3
        int kh_i = h / 2;                          /* MUTANT 3 */
#else
        int kh_i = h % LIN_KH;
#endif
        const double *kh = kc + kh_i * LIN_HD;
        const double *qh = qc + kh_i * LIN_HD;
        const double *vh = vc + h * LIN_HD;
        double d = exp(gdec[h]);
        for (int i = 0; i < LIN_HD * LIN_HD; i++) Sh[i] *= d;
        double delta[LIN_HD];
        for (int j = 0; j < LIN_HD; j++) {
            double s = 0;
            for (int i = 0; i < LIN_HD; i++) s += Sh[(size_t)i * LIN_HD + j] * kh[i];
            delta[j] = (vh[j] - s) * beta[h];
        }
        for (int i = 0; i < LIN_HD; i++) {
            double ki = kh[i]; double *row = Sh + (size_t)i * LIN_HD;
            for (int j = 0; j < LIN_HD; j++) row[j] += ki * delta[j];
        }
        for (int j = 0; j < LIN_HD; j++) {
            double s = 0;
            for (int i = 0; i < LIN_HD; i++) s += Sh[(size_t)i * LIN_HD + j] * qh[i];
            out[h * LIN_HD + j] = s * qscale;
        }
    }

    /* output norm then z gate.  ORDER MATTERS: normalise first, THEN multiply
     * by silu(z).  The gate does not enter the RMS statistic. */
    const float *sn = f32t((snprintf(tn, sizeof tn, "blk.%d.ssm_norm.weight", il), tn), NULL);
    for (int h = 0; h < LIN_VH; h++) {
        double nb[LIN_HD];
#if REF9B_MUT == 5
        double pre[LIN_HD];                        /* MUTANT 5 */
        for (int j = 0; j < LIN_HD; j++)
            pre[j] = out[h * LIN_HD + j] * silu(reg_get(&RZ)[h * LIN_HD + j]);
        rmsnorm(pre, sn, LIN_HD, nb);
        for (int j = 0; j < LIN_HD; j++) t[h * LIN_HD + j] = nb[j];
#else
        rmsnorm(out + h * LIN_HD, sn, LIN_HD, nb);
        for (int j = 0; j < LIN_HD; j++)
            t[h * LIN_HD + j] = nb[j] * silu(reg_get(&RZ)[h * LIN_HD + j]);
#endif
    }
    reg_put(&RY, t);
    snprintf(nm, sizeof nm, "R_Y-%d", il); seam(nm, il, &RY);

    /* --- OP_A_JOB R_Y -> R_ER, then OP_VEC_RES --------------------------- */
    snprintf(tn, sizeof tn, "blk.%d.ssm_out.weight", il);
    a_job(tn, 0, &RY, &RER);
    snprintf(nm, sizeof nm, "R_ER-%d", il); seam(nm, il, &RER);
    for (int i = 0; i < HIDDEN; i++) t[i] = reg_get(RX)[i] + reg_get(&RER)[i];
    reg_put(RX, t);
    snprintf(nm, sizeof nm, "R_X.attn-%d", il); seam(nm, il, RX);

    /* --- FFN tail -------------------------------------------------------- */
    snprintf(tn, sizeof tn, "blk.%d.post_attention_norm.weight", il);
    rmsnorm(reg_get(RX), f32t(tn, NULL), HIDDEN, t);
    reg_put(&RXN, t);
    snprintf(nm, sizeof nm, "R_XN.ffn-%d", il); seam(nm, il, &RXN);
    snprintf(tn, sizeof tn, "blk.%d.ffn_gate.weight", il);
    a_job(tn, 0, &RXN, &RG); snprintf(nm, sizeof nm, "R_G-%d", il); seam(nm, il, &RG);
    snprintf(tn, sizeof tn, "blk.%d.ffn_up.weight", il);
    a_job(tn, 0, &RXN, &RU); snprintf(nm, sizeof nm, "R_U-%d", il); seam(nm, il, &RU);
    for (int i = 0; i < FFN; i++) t[i] = silu(reg_get(&RG)[i]) * reg_get(&RU)[i];
    reg_put(&RH, t);
    snprintf(nm, sizeof nm, "R_H-%d", il); seam(nm, il, &RH);
    snprintf(tn, sizeof tn, "blk.%d.ffn_down.weight", il);
    a_job(tn, 0, &RH, &RER);
    snprintf(nm, sizeof nm, "R_ER.ffn-%d", il); seam(nm, il, &RER);
    for (int i = 0; i < HIDDEN; i++) t[i] = reg_get(RX)[i] + reg_get(&RER)[i];
    reg_put(RX, t);
    snprintf(nm, sizeof nm, "R_X-%d", il); seam(nm, il, RX);

    free(t); free(mixed); free(conv); free(out);
}

static void layer_attn(int il, state_t *S, reg_t *RX, int pos)
{
    char nm[80], tn[80];
    static reg_t RXN, RQG, RKIN, RVIN, RY, RER, RG, RU, RH;
    if (!RXN.n) {
        RXN = reg_new(HIDDEN); RQG = reg_new(2 * ATT_QH * ATT_HD);
        RKIN = reg_new(ATT_KVH * ATT_HD); RVIN = reg_new(ATT_KVH * ATT_HD);
        RY = reg_new(HIDDEN); RER = reg_new(HIDDEN);
        RG = reg_new(FFN); RU = reg_new(FFN); RH = reg_new(FFN);
    }
    double *t = malloc(sizeof(double) * (size_t)FFN);

    snprintf(tn, sizeof tn, "blk.%d.attn_norm.weight", il);
    rmsnorm(reg_get(RX), f32t(tn, NULL), HIDDEN, t);
    reg_put(&RXN, t);
    snprintf(nm, sizeof nm, "R_XN-%d", il); seam(nm, il, &RXN);

    snprintf(tn, sizeof tn, "blk.%d.attn_q.weight", il);
    a_job(tn, 0, &RXN, &RQG); snprintf(nm, sizeof nm, "R_QG-%d", il); seam(nm, il, &RQG);
    snprintf(tn, sizeof tn, "blk.%d.attn_k.weight", il);
    a_job(tn, 0, &RXN, &RKIN); snprintf(nm, sizeof nm, "R_KIN-%d", il); seam(nm, il, &RKIN);
    snprintf(tn, sizeof tn, "blk.%d.attn_v.weight", il);
    a_job(tn, 0, &RXN, &RVIN); snprintf(nm, sizeof nm, "R_VIN-%d", il); seam(nm, il, &RVIN);

    /* R_QG's 8192 rows are INTERLEAVED PER HEAD:
     *   [h0 q(256) | h0 gate(256) | h1 q(256) | h1 gate(256) | ...]
     * That is fixed by llama.cpp's two ggml_view_3d calls with row stride
     * 2*head_dim.  Reading it as [all q | all gate] gives a plausible, wrong
     * answer on every head but the first, which is exactly the failure mode
     * this reference exists to make visible. */
    double *q = malloc(sizeof(double) * ATT_QH * ATT_HD);
    double *g = malloc(sizeof(double) * ATT_QH * ATT_HD);
    for (int h = 0; h < ATT_QH; h++)
        for (int d = 0; d < ATT_HD; d++) {
#if REF9B_MUT == 1
            q[h * ATT_HD + d] = reg_get(&RQG)[h * ATT_HD + d];               /* MUTANT 1 */
            g[h * ATT_HD + d] = reg_get(&RQG)[ATT_QH * ATT_HD + h * ATT_HD + d];
#else
            q[h * ATT_HD + d] = reg_get(&RQG)[h * 2 * ATT_HD + d];
            g[h * ATT_HD + d] = reg_get(&RQG)[h * 2 * ATT_HD + ATT_HD + d];
#endif
        }

    const float *qn = f32t((snprintf(tn, sizeof tn, "blk.%d.attn_q_norm.weight", il), tn), NULL);
    const float *kn = f32t((snprintf(tn, sizeof tn, "blk.%d.attn_k_norm.weight", il), tn), NULL);
    double *k = malloc(sizeof(double) * ATT_KVH * ATT_HD);
    for (int h = 0; h < ATT_QH; h++)  { double b[ATT_HD];
        rmsnorm(q + h * ATT_HD, qn, ATT_HD, b); memcpy(q + h * ATT_HD, b, sizeof b); }
    for (int h = 0; h < ATT_KVH; h++) { double b[ATT_HD];
        rmsnorm(reg_get(&RKIN) + h * ATT_HD, kn, ATT_HD, b);
        memcpy(k + h * ATT_HD, b, sizeof b); }

    /* RoPE.  n_rot = 64 with head_dim = 256, so dims 64..255 are COPIED, not
     * rotated.  NeoX pairing (i, i+32).  For text-only input llama.cpp's
     * interleaved M-RoPE reduces exactly to this: all three live sections
     * carry the same position.  theta_i = pos * 1e7^(-2i/64). */
    for (int h = 0; h < ATT_QH + ATT_KVH; h++) {
        double *v = (h < ATT_QH) ? q + h * ATT_HD : k + (h - ATT_QH) * ATT_HD;
        for (int i = 0; i < N_ROT / 2; i++) {
            double th = (double)pos * pow(ROPE_BASE, -2.0 * i / (double)N_ROT);
            double c = cos(th), s = sin(th);
#if REF9B_MUT == 4
            int i0 = 2 * i, i1 = 2 * i + 1;                 /* MUTANT 4 */
#else
            int i0 = i, i1 = i + N_ROT / 2;
#endif
            double a = v[i0], b = v[i1];
            v[i0] = a * c - b * s; v[i1] = a * s + b * c;
        }
    }

    /* KV cache, then GQA attention.  scale = 1/sqrt(256). */
    double *kc = S->kcache + ((size_t)il * S->maxpos) * ATT_KVH * ATT_HD;
    double *vc = S->vcache + ((size_t)il * S->maxpos) * ATT_KVH * ATT_HD;
    memcpy(kc + (size_t)pos * ATT_KVH * ATT_HD, k, sizeof(double) * ATT_KVH * ATT_HD);
    memcpy(vc + (size_t)pos * ATT_KVH * ATT_HD, reg_get(&RVIN),
           sizeof(double) * ATT_KVH * ATT_HD);

    const double scale = 1.0 / sqrt((double)ATT_HD);
    double *att = malloc(sizeof(double) * (size_t)(pos + 1));
    for (int h = 0; h < ATT_QH; h++) {
#if REF9B_MUT == 9
        int kvh = h % ATT_KVH;                             /* MUTANT 9 */
#else
        int kvh = h / (ATT_QH / ATT_KVH);
#endif
        double mx = -INFINITY;
        for (int p = 0; p <= pos; p++) {
            double s = 0; const double *kp = kc + ((size_t)p * ATT_KVH + kvh) * ATT_HD;
            for (int d = 0; d < ATT_HD; d++) s += q[h * ATT_HD + d] * kp[d];
            att[p] = s * scale; if (att[p] > mx) mx = att[p];
        }
        double sum = 0;
        for (int p = 0; p <= pos; p++) { att[p] = exp(att[p] - mx); sum += att[p]; }
        for (int d = 0; d < ATT_HD; d++) {
            double acc = 0;
            for (int p = 0; p <= pos; p++)
                acc += att[p] * vc[((size_t)p * ATT_KVH + kvh) * ATT_HD + d];
            t[h * ATT_HD + d] = acc / sum;
        }
    }
    /* the gate is the RAW projection: not q-normed, not roped */
    for (int i = 0; i < HIDDEN; i++) t[i] *= sigmoidd(g[i]);
    reg_put(&RY, t);
    snprintf(nm, sizeof nm, "R_Y-%d", il); seam(nm, il, &RY);

    snprintf(tn, sizeof tn, "blk.%d.attn_output.weight", il);
    a_job(tn, 0, &RY, &RER);
    snprintf(nm, sizeof nm, "R_ER-%d", il); seam(nm, il, &RER);
    for (int i = 0; i < HIDDEN; i++) t[i] = reg_get(RX)[i] + reg_get(&RER)[i];
    reg_put(RX, t);
    snprintf(nm, sizeof nm, "R_X.attn-%d", il); seam(nm, il, RX);

    snprintf(tn, sizeof tn, "blk.%d.post_attention_norm.weight", il);
    rmsnorm(reg_get(RX), f32t(tn, NULL), HIDDEN, t);
    reg_put(&RXN, t);
    snprintf(nm, sizeof nm, "R_XN.ffn-%d", il); seam(nm, il, &RXN);
    snprintf(tn, sizeof tn, "blk.%d.ffn_gate.weight", il);
    a_job(tn, 0, &RXN, &RG); snprintf(nm, sizeof nm, "R_G-%d", il); seam(nm, il, &RG);
    snprintf(tn, sizeof tn, "blk.%d.ffn_up.weight", il);
    a_job(tn, 0, &RXN, &RU); snprintf(nm, sizeof nm, "R_U-%d", il); seam(nm, il, &RU);
    for (int i = 0; i < FFN; i++) t[i] = silu(reg_get(&RG)[i]) * reg_get(&RU)[i];
    reg_put(&RH, t);
    snprintf(nm, sizeof nm, "R_H-%d", il); seam(nm, il, &RH);
    snprintf(tn, sizeof tn, "blk.%d.ffn_down.weight", il);
    a_job(tn, 0, &RH, &RER);
    snprintf(nm, sizeof nm, "R_ER.ffn-%d", il); seam(nm, il, &RER);
    for (int i = 0; i < HIDDEN; i++) t[i] = reg_get(RX)[i] + reg_get(&RER)[i];
    reg_put(RX, t);
    snprintf(nm, sizeof nm, "R_X-%d", il); seam(nm, il, RX);

    free(t); free(q); free(g); free(k); free(att);
}

/* -------------------------------------------------------------- embedding */
/* THE EMBEDDING ROW IS AN ACTIVATION, NOT A WEIGHT, AND IT HAS TWO SOURCES.
 *
 * It is the input to the whole model.  Until 2026-08-29 this file read it from
 * the PACKED INT4 set, and it did so for one reason only: `token_embd.weight`
 * happened to be packed alongside the weight tensors, so the same loader
 * carried it.  MEASURED by TRACK HOSTEMB over 48 corner-forced rows, both
 * packed to int16 BFP by the same `reg_put` rule and both scored against the
 * BF16 GGUF row:
 *
 *     packed INT4 -> BFP int16   mean relerr 0.086295   worst 0.126667
 *     GGUF BF16   -> BFP int16   mean relerr 0.000048   worst 0.000425
 *
 * a factor of 1,803, against the 0.1252 relative RMS that the INT4 *weight*
 * format costs at the logits.  Oren took the decision to upgrade, and the ORDER
 * is the safety property: this file moves FIRST and the host second, because a
 * host that switched first would be feeding the card an activation no rung of
 * this reference had ever evaluated.
 *
 * BOTH SOURCES STAY SELECTABLE.  `--embed gguf` (the DEFAULT) reads the BF16
 * row out of `Qwen3.5-9B-BF16.gguf`; `--embed mv4i` reads the packed row, which
 * is what every number published before 2026-08-29 was measured with.  Those
 * numbers must stay re-derivable, so the old path is a flag and not a comment.
 *
 * WHAT THE SOURCE DOES AND DOES NOT CHANGE ABOUT THE THREE RUNGS.  Nothing
 * about the rung structure: rung 2 (`--acts f32`) still isolates the INT4
 * WEIGHT format and rung 3 (`--acts bfp`) still adds the int16 BFP ACTIVATION
 * format.  What changes is that under `--embed gguf` the embedding is no longer
 * one of the INT4-quantized tensors, so `rung1 -> rung2` at `R_X.embed` becomes
 * a pure BF16-vs-f64 comparison and is essentially zero.  That is the point of
 * the upgrade and it is measured in
 * docs/debugging/2026-08-29_embedding-bf16-upgrade.md.
 *
 * `--embed gguf` also lets this reference run against a packed set that has no
 * `token_embd.weight` at all, which is what TRACK EMBDROP's `noembd` set is. */
#define EMBED_SRC_GGUF 0
#define EMBED_SRC_MV4I 1

static int         g_embed_src = EMBED_SRC_GGUF;
static const char *g_gguf =
    "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf";
static emb_bf16_t *g_eb = NULL;

static void embed(int tok, reg_t *RX)
{
    double *t = malloc(sizeof(double) * HIDDEN);
    if (!t) die("out of memory");
    if (g_embed_src == EMBED_SRC_GGUF) {
        if (!g_eb) {
            if (emb_bf16_open(g_gguf, EMB_BF16_TENSOR, &g_eb))
                die("the BF16 embedding could not be opened.  Give --gguf PATH,\n"
                    "  or ask for the old packed embedding with --embed mv4i "
                    "(which is\n  what every number published before 2026-08-29 "
                    "was measured with).\n  It is NOT silently substituted: an "
                    "unannounced fallback to a 1,803x\n  coarser activation is "
                    "exactly the failure this flag exists to prevent");
            if (emb_bf16_ne0(g_eb) != HIDDEN)
                die("the GGUF embedding row length is not HIDDEN");
            if (emb_bf16_ne1(g_eb) != VOCAB)
                die("the GGUF embedding row count is not VOCAB");
        }
        if (emb_bf16_row(g_eb, tok, t, HIDDEN)) die("embedding row refused");
    } else {
        mvw_t *m = mv("token_embd.weight");
        for (int k = 0; k < HIDDEN; k++) t[k] = w_deq(&m->f, tok, k);
    }
    reg_put(RX, t);
    free(t);
}

/* -------------------------------------------------------------- self test */
/* THE ONE CHECK THAT MAKES a_job's RAW+own-scan SUBSTITUTION SAFE.  A window
 * covering the whole matrix must reproduce MV4I_MODE_BFP exactly.  If it does
 * not, every seam in the stream is suspect and the run refuses to continue. */
static int selftest(void)
{
    const char *names[] = { "blk.0.ssm_out.weight", "blk.3.attn_k.weight",
                            "blk.0.ffn_down.weight", NULL };
    int bad = 0;
    for (int t = 0; names[t]; t++) {
        mvw_t *m = mv(names[t]);
        reg_t x = reg_new(m->K), y = reg_new(m->seg[0].n_rows);
        for (int i = 0; i < m->K; i++)
            x.m[i] = (int16_t)(((i * 2654435761u) >> 17) - 16384);
        x.exp = 3;
        for (int i = 0; i < m->K; i++) x.v[i] = ldexp((double)x.m[i], -x.exp);

        int16_t *ref_m = malloc(sizeof(int16_t) * (size_t)m->M);
        int32_t *ref_d = malloc(sizeof(int32_t) * (size_t)m->M);
        mv4i_result r; r.y_data = ref_d; r.y_mant = ref_m; r.y_acc = NULL;
        if (mv4i_matvec(&m->f, x.m, x.exp, m->M, m->K, MV4I_MODE_BFP, &r))
            die("selftest: BFP reference refused");
        a_job(names[t], 0, &x, &y);
        int diff = (y.exp != r.y_exp);
        for (int i = 0; i < m->M; i++) if (y.m[i] != ref_m[i]) diff++;
        printf("SELFTEST %-28s M=%-7d exp %d vs %d  mismatches=%d  %s\n",
               names[t], m->M, y.exp, r.y_exp, diff, diff ? "IS NOT EXACT" : "exact");
        bad += diff ? 1 : 0;
        free(ref_m); free(ref_d);
    }
    return bad;
}

/* ------------------------------------------------------------------- main */
static void usage(void)
{
    fprintf(stderr,
      "usage: run9b --packed DIR [options]\n"
      "  --tokens a,b,c   token ids to run (default 760,6511,314,9338,369)\n"
      "  --out F.r9bs     write the seam stream\n"
      "  --acts bfp|f32   region format: bfp = the hardware model (default),\n"
      "                   f32 = INT4 weights with float activations\n"
      "  --embed gguf|mv4i  which copy of the EMBEDDING to gather.\n"
      "                   gguf = the BF16 row from --gguf (DEFAULT since\n"
      "                          2026-08-29; 1,803x more accurate at the\n"
      "                          activation, and the basis of the current\n"
      "                          headline numbers)\n"
      "                   mv4i = the packed INT4 row from the packed set,\n"
      "                          which is what every number published BEFORE\n"
      "                          2026-08-29 was measured with.  Kept so those\n"
      "                          stay reproducible.\n"
      "  --gguf PATH      the BF16 checkpoint --embed gguf reads\n"
      "  --layers N       stop after N layers (a cheap partial run)\n"
      "  --selftest       check a_job against MV4I_MODE_BFP and exit\n"
      "  --top K          print the top-K logits of the last token\n");
}

int main(int argc, char **argv)
{
    const char *packed = NULL, *out = NULL;
    int toks[64], ntok = 0, nlayer = N_LAYER, do_self = 0, topk = 5;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT() (i + 1 < argc ? argv[++i] : (usage(), exit(1), ""))
        if      (!strcmp(a, "--packed"))   packed = NEXT();
        else if (!strcmp(a, "--out"))      out = NEXT();
        else if (!strcmp(a, "--layers"))   nlayer = atoi(NEXT());
        else if (!strcmp(a, "--top"))      topk = atoi(NEXT());
        else if (!strcmp(a, "--selftest")) do_self = 1;
        else if (!strcmp(a, "--acts"))     g_bfp = strcmp(NEXT(), "f32") != 0;
        else if (!strcmp(a, "--gguf"))     g_gguf = NEXT();
        else if (!strcmp(a, "--embed")) {
            const char *s = NEXT();
            if      (!strcmp(s, "gguf")) g_embed_src = EMBED_SRC_GGUF;
            else if (!strcmp(s, "mv4i")) g_embed_src = EMBED_SRC_MV4I;
            else { usage(); return 1; }
        }
        else if (!strcmp(a, "--tokens")) {
            char *s = strdup(NEXT()), *p = s;
            while (p && *p) { toks[ntok++] = atoi(p); p = strchr(p, ','); if (p) p++; }
        }
        else { usage(); return 1; }
    }
    if (!packed) { usage(); return 1; }
    if (!ntok) { int d[] = {760,6511,314,9338,369}; ntok = 5; memcpy(toks, d, sizeof d); }

    load_index(packed);

    /* Open the embedding source NOW, not lazily inside the first token: a bad
     * --gguf path should cost a second, not thirty.  And PRINT which copy is in
     * use on every run, because the whole hazard this flag guards against is a
     * number quoted without its basis. */
    if (g_embed_src == EMBED_SRC_GGUF) {
        reg_t probe = reg_new(HIDDEN);
        embed(0, &probe);
        printf("EMBED gguf  %s\n", emb_bf16_describe(g_eb));
        free(probe.m); free(probe.v);
    } else {
        printf("EMBED mv4i  %s/%s  (the PRE-2026-08-29 basis)\n",
               g_dir, mv("token_embd.weight")->file);
    }
    fflush(stdout);

    if (do_self) return selftest() ? 1 : 0;

    state_t S;
    S.maxpos = ntok + 1;
    S.conv_state = calloc((size_t)N_LAYER * (KCONV - 1) * CONV_DIM, sizeof(double));
    S.rec_state  = calloc((size_t)N_LAYER * LIN_VH * LIN_HD * LIN_HD, sizeof(double));
    S.kcache = calloc((size_t)N_LAYER * S.maxpos * ATT_KVH * ATT_HD, sizeof(double));
    S.vcache = calloc((size_t)N_LAYER * S.maxpos * ATT_KVH * ATT_HD, sizeof(double));
    if (!S.conv_state || !S.rec_state || !S.kcache || !S.vcache) die("out of memory");

    if (out) {
        g_seam = fopen(out, "wb");
        if (!g_seam) { perror(out); return 1; }
        /* THE VERSION IS DECIDED BY WHAT THE RUN WILL CONTAIN, and it can be
         * decided here because only the full-model path emits the S32 TOKEN
         * record.  Declaring version 1 on a file that carries S32 is the
         * silent failure the format's version gate exists to stop: an older
         * reader would decode 32-bit values as int16 and mis-frame every
         * record after it.  Over-declaring is the fail-safe direction (a v1
         * reader stops loudly), under-declaring is not, so a partial run
         * declaring 1 is a deliberate choice and not an oversight. */
        if (r9bs_write_header_ver(g_seam, nlayer == N_LAYER ? R9BS_VERSION_S32
                                                           : R9BS_VERSION))
            die("header write failed");
    }

    reg_t RX = reg_new(HIDDEN), RXN = reg_new(HIDDEN);
    double *logits = malloc(sizeof(double) * VOCAB);
    double *t = malloc(sizeof(double) * HIDDEN);
    const float *on = f32t("output_norm.weight", NULL);

    struct timespec t0, t1;
    for (int p = 0; p < ntok; p++) {
        g_tok = p;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        embed(toks[p], &RX);
        seam("R_X.embed", -1, &RX);
        for (int il = 0; il < nlayer; il++) {
            if (is_attn(il)) layer_attn(il, &S, &RX, p);
            else             layer_gdn (il, &S, &RX, p);
        }
        if (nlayer == N_LAYER) {
            rmsnorm(reg_get(&RX), on, HIDDEN, t);
            reg_put(&RXN, t);
            seam("R_XN.final", -1, &RXN);
            lm_head(&RXN, logits);
            seam_f32("LOGITS", -1, logits, VOCAB);
            int best = argmax_first(logits, VOCAB);
            seam_token(best);
            clock_gettime(CLOCK_MONOTONIC, &t1);
            printf("TOKEN %d id=%d  argmax=%d logit=%.6f  %.2f s\n", p, toks[p],
                   best, logits[best],
                   (t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec));
            if (p == ntok - 1) {
                for (int r = 0; r < topk; r++) {
                    int b = 0; for (int v = 1; v < VOCAB; v++)
                        if (logits[v] > logits[b]) b = v;
                    printf("  TOP%d id=%d logit=%.6f\n", r, b, logits[b]);
                    logits[b] = -INFINITY;
                }
            }
        } else {
            clock_gettime(CLOCK_MONOTONIC, &t1);
            printf("TOKEN %d id=%d  (partial, %d layers)  %.2f s\n", p, toks[p], nlayer,
                   (t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec));
        }
        fflush(stdout);
    }
    if (g_seam) { fclose(g_seam); fprintf(stderr, "wrote %s: %ld records\n", out, g_recs); }
    return 0;
}
