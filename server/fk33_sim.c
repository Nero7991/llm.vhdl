/* fk33_sim.c -- a model of the seam engine, behind the transport interface.
 *
 * READ THE "WHAT IT IS NOT" BLOCK IN fk33_seam.h BEFORE BELIEVING A NUMBER
 * THAT CAME OUT OF THIS FILE.  It does not run a transformer, it does not
 * model subsystem A, and its default logits are a deterministic synthetic
 * function with no relationship to Qwen3.5-9B.  It exists so the HOST code can
 * be executed and mutated while the card cannot route.
 *
 * It is deliberately strict.  Every check the contract states is enforced
 * here, including the ones a real card might be sloppy about, because the
 * point of a test double is to be the harshest legal implementation:
 *
 *   * `done` is latched and is NEVER set on an error, so a host that polls
 *     `done` alone hangs -- and the test that proves it hangs is in
 *     server/tests/.
 *   * a reserved field that is not zero is refused, not ignored.
 *   * a block that straddles the HBM stack line is refused, even though a
 *     real card would happily read the wrong bytes and report success.
 *   * SEQ_POS must equal the card's own next position; the host's KV
 *     bookkeeping being one step out is otherwise invisible.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fk33_transport.h"
#include "fk33_seam.h"

/* ------------------------------------------------------- sparse AXI memory */

#define PAGE_SHIFT 16
#define PAGE_SIZE  (1u << PAGE_SHIFT)
#define NBUCKET    4096

typedef struct page {
    uint64_t     idx;
    struct page *next;
    unsigned char b[PAGE_SIZE];
} page;

typedef struct {
    page *bucket[NBUCKET];
} sparse;

static page *page_get(sparse *s, uint64_t idx, int create)
{
    size_t h = (size_t)(idx * 1099511628211ull >> 20) % NBUCKET;
    page *p = s->bucket[h];
    while (p) { if (p->idx == idx) return p; p = p->next; }
    if (!create) return NULL;
    p = (page *)calloc(1, sizeof *p);
    if (!p) return NULL;
    p->idx = idx;
    p->next = s->bucket[h];
    s->bucket[h] = p;
    return p;
}

static void sparse_free(sparse *s)
{
    size_t i;
    for (i = 0; i < NBUCKET; i++) {
        page *p = s->bucket[i];
        while (p) { page *n = p->next; free(p); p = n; }
        s->bucket[i] = NULL;
    }
}

static int sparse_rw(sparse *s, uint64_t addr, void *buf, size_t len, int wr)
{
    unsigned char *b = (unsigned char *)buf;
    while (len) {
        uint64_t pi  = addr >> PAGE_SHIFT;
        size_t   off = (size_t)(addr & (PAGE_SIZE - 1));
        size_t   n   = PAGE_SIZE - off; if (n > len) n = len;
        page *p = page_get(s, pi, wr);
        if (!p) {
            if (wr) return -1;
            memset(b, 0, n);            /* unwritten HBM reads as zero */
        } else if (wr) {
            memcpy(p->b + off, b, n);
        } else {
            memcpy(b, p->b + off, n);
        }
        addr += n; b += n; len -= n;
    }
    return 0;
}

/* ------------------------------------------------------------- the model */

typedef struct {
    fk33_sim_opts o;
    sparse        mem;
    uint32_t      reg[FK33_SEAM_SPAN / 4];
    int           next_pos;         /* the card's own KV position */
    uint32_t      hist;             /* FNV-1a over every step since SEQ_RESET */
    int           kv_valid;
    uint32_t      status;
    uint32_t      err_info;
    uint32_t      cycles;
    int32_t      *logit_buf;
    int16_t      *x_buf;
    char          desc[192];
    unsigned long n_go;
} sim_ctx;

/* The BUILT-IN synthetic logits.  Deterministic and input-dependent, so a
 * plumbing test has teeth: change one activation mantissa and the argmax
 * moves.  It is NOT a model of anything.  The shape is chosen so that the
 * argmax is easy to predict by hand in a test:
 *
 *     logit[v] = ((position * 2654435761 + token_id * 40503 + v * 97) & 0xFFFF)
 *                 - 32768  + (v == pick ? 1 << 20 : 0)
 *     pick     = (hist * 31 + position * 7 + fold(x_mant)) mod n_vocab
 *
 * so the argmax is `pick`, exactly.
 *
 * `hist` IS THE POINT AND IT WAS NOT THERE AT FIRST.  The first version used
 * `token_id` where `hist` now is, so the answer depended only on the LAST
 * step's token and its position.  MEASURED consequence: in
 * server/tests/server_e2e.py, two different 25-id prompts ending in the same
 * token produced the same expected token, so the check could not have seen a
 * prefill that dropped, duplicated or reordered any earlier token.  Coverage
 * of the input space was not coverage of the output space.
 *
 * `hist` is an FNV-1a chain over (token_id, position, fold(x_mant)) for every
 * step since the last SEQ_RESET -- which is, crudely, the one structural
 * property a transformer prefill actually has: the answer depends on the whole
 * prefix.  It is still not a model of anything. */
static uint32_t fold_x(const int16_t *x, int n)
{
    uint32_t h = 2166136261u;
    int i;
    for (i = 0; i < n; i++) { h ^= (uint32_t)(uint16_t)x[i]; h *= 16777619u; }
    return h;
}

static int default_logits(void *user, int position, int token_id,
                          const int16_t *x_mant, int32_t x_exp,
                          int32_t *logits, int32_t *logit_exp)
{
    sim_ctx *s = (sim_ctx *)user;
    int nv = s->o.n_vocab, v;
    uint32_t fx = fold_x(x_mant, s->o.n_embd);
    uint32_t pick;

    s->hist = (s->hist ^ (uint32_t)token_id) * 16777619u;
    s->hist = (s->hist ^ (uint32_t)position) * 16777619u;
    s->hist = (s->hist ^ fx)                 * 16777619u;
    pick = ((uint32_t)s->hist * 31u + (uint32_t)position * 7u + fx) % (uint32_t)nv;
    for (v = 0; v < nv; v++) {
        uint32_t r = ((uint32_t)position * 2654435761u
                      + (uint32_t)token_id * 40503u + (uint32_t)v * 97u) & 0xFFFFu;
        logits[v] = (int32_t)r - 32768;
    }
    logits[pick] += (1 << 20);
    *logit_exp = x_exp - 3;      /* an arbitrary but reproducible relationship */
    return 0;
}

void fk33_sim_opts_default(fk33_sim_opts *o)
{
    memset(o, 0, sizeof *o);
    o->n_vocab  = 248320;   /* rtl/model_cfg_pkg.vhd QWEN35_9B; see fk33_seam.h */
    o->n_layer  = 32;
    o->n_embd   = 4096;
    o->max_ctx  = 4096;     /* the residency map allows 198,415; a test double
                             * that reserves that much is a test double nobody
                             * runs.  The host reads this from CAPS. */
    o->max_chunk = 512;
}

static void fail(sim_ctx *s, unsigned code, uint32_t info)
{
    s->status = FK33_ST_ERR | (code << 8);   /* NOTE: done is NOT set */
    s->err_info = info;
}

static int rd_u32(sim_ctx *s, uint64_t a, uint32_t *v)
{ return sparse_rw(&s->mem, a, v, 4, 0); }

static void run_go(sim_ctx *s, uint32_t ctrl)
{
    uint64_t xb = ((uint64_t)s->reg[FK33_SEAM_X_BASE_HI / 4] << 32)
                | s->reg[FK33_SEAM_X_BASE_LO / 4];
    uint64_t lb = ((uint64_t)s->reg[FK33_SEAM_L_BASE_HI / 4] << 32)
                | s->reg[FK33_SEAM_L_BASE_LO / 4];
    uint64_t dp = ((uint64_t)s->reg[FK33_SEAM_DESC_PTR_HI / 4] << 32)
                | s->reg[FK33_SEAM_DESC_PTR_LO / 4];
    int pos    = (int)s->reg[FK33_SEAM_SEQ_POS / 4];
    int nstep  = (int)s->reg[FK33_SEAM_N_STEP / 4];
    int all    = (ctrl & FK33_CTRL_LOGITS_ALL) != 0;
    uint64_t xs = fk33_x_stride(s->o.n_embd);
    uint64_t ls = fk33_l_stride(s->o.n_vocab);
    int k, rc;

    s->n_go++;
    s->status = FK33_ST_BUSY;
    s->err_info = 0;

    if (s->o.fault_err_on_go) { fail(s, FK33_SEAM_ERR_DESC, 0xDEAD); return; }

    if (nstep <= 0 || nstep > (s->o.max_chunk ? s->o.max_chunk : 512)) {
        fail(s, FK33_SEAM_ERR_NSTEP, (uint32_t)nstep); return;
    }
    if (pos < 0 || pos + nstep > s->o.max_ctx) {
        fail(s, FK33_SEAM_ERR_POS, (uint32_t)pos); return;
    }
    if (pos != s->next_pos) {
        fail(s, FK33_SEAM_ERR_SEQ, (uint32_t)s->next_pos); return;
    }
    if ((xb % FK33_BLOCK_ALIGN) || (lb % FK33_BLOCK_ALIGN)) {
        fail(s, FK33_SEAM_ERR_ALIGN, 0); return;
    }
    if (dp == 0) { fail(s, FK33_SEAM_ERR_DESC, 0); return; }
    if (dp % 512u) { fail(s, FK33_SEAM_ERR_ALIGN, 1); return; }
    {
        int e = fk33_seam_check_blocks(xb, xs * (uint64_t)nstep,
                                       lb, ls * (uint64_t)(all ? nstep : 1));
        if (e) { fail(s, (unsigned)e, 2); return; }
    }

    for (k = 0; k < nstep; k++) {
        uint64_t xa = xb + xs * (uint64_t)k;
        uint32_t rsv_lo = 1, rsv_hi = 1;
        int32_t  x_exp = 0;
        uint32_t tok = 0, xe = 0;
        int32_t  lexp = 0;

        rd_u32(s, xa + 0, &xe);
        memcpy(&x_exp, &xe, 4);          /* no int32 vs uint32 pointer aliasing */
        rd_u32(s, xa + 4, &tok);
        rd_u32(s, xa + 8, &rsv_lo);
        rd_u32(s, xa + 12, &rsv_hi);
        if (rsv_lo || rsv_hi) { fail(s, FK33_SEAM_ERR_RSVD, (uint32_t)k); return; }

        sparse_rw(&s->mem, xa + FK33_SEAM_HDR_BYTES, s->x_buf,
                  (size_t)s->o.n_embd * 2, 0);

        rc = s->o.logits_fn(s->o.user ? s->o.user : (void *)s,
                            pos + k, (int)tok, s->x_buf, x_exp,
                            s->logit_buf, &lexp);
        if (rc) { fail(s, FK33_SEAM_ERR_DESC, (uint32_t)k); return; }

        if (all || k == nstep - 1) {
            uint64_t la = lb + ls * (uint64_t)(all ? k : 0);
            uint64_t z = 0;
            int32_t  am = 0;
            int      v, nv = s->o.n_vocab;
            size_t   nbytes = (size_t)nv * 4;

            for (v = 1; v < nv; v++)
                if (s->logit_buf[v] > s->logit_buf[am]) am = v;   /* first max on ties */

            if (s->o.fault_short_logits) nbytes /= 2;

            sparse_rw(&s->mem, la + 0, &lexp, 4, 1);
            sparse_rw(&s->mem, la + 4, &am, 4, 1);
            sparse_rw(&s->mem, la + 8, &z, 8, 1);
            sparse_rw(&s->mem, la + FK33_SEAM_HDR_BYTES, s->logit_buf, nbytes, 1);

            if (!s->o.fault_stale_argmax) {
                s->reg[FK33_SEAM_ARGMAX / 4]    = (uint32_t)am;
                s->reg[FK33_SEAM_LOGIT_EXP / 4] = (uint32_t)lexp;
            }
        }
    }

    s->next_pos = pos + nstep;
    s->kv_valid = 1;
    s->cycles = (uint32_t)nstep * 1000u;

    if (s->o.fault_never_done) { s->status = FK33_ST_BUSY; return; }
    s->status = FK33_ST_DONE;
}

static int sim_reg_read32(void *c, uint32_t off, uint32_t *v)
{
    sim_ctx *s = (sim_ctx *)c;
    uint32_t o;
    if (off < FK33_SEAM_BASE
        || off >= FK33_SEAM_BASE + FK33_SEAM_SPAN || (off & 3u)) {
        *v = 0xFFFFFFFFu;               /* BAR mapped, nothing answering */
        return 0;
    }
    o = off - FK33_SEAM_BASE;
    switch (o) {
    case FK33_SEAM_ID:         *v = FK33_SEAM_ID_MAGIC; return 0;
    case FK33_SEAM_VERSION:    *v = FK33_SEAM_VERSION_1; return 0;
    case FK33_SEAM_CAPS_VOCAB: *v = (uint32_t)s->o.n_vocab; return 0;
    case FK33_SEAM_CAPS_EMBD:  *v = ((uint32_t)s->o.n_layer << 16)
                                  | ((uint32_t)s->o.n_embd & 0xFFFFu); return 0;
    case FK33_SEAM_CAPS_CTX:   *v = (uint32_t)s->o.max_ctx; return 0;
    case FK33_SEAM_STATUS:     *v = s->status; return 0;
    case FK33_SEAM_ERR_INFO:   *v = s->err_info; return 0;
    case FK33_SEAM_CYCLES:     *v = s->cycles; return 0;
    default:                   *v = s->reg[o / 4]; return 0;
    }
}

static int sim_reg_write32(void *c, uint32_t off, uint32_t v)
{
    sim_ctx *s = (sim_ctx *)c;
    uint32_t o;
    if (off < FK33_SEAM_BASE
        || off >= FK33_SEAM_BASE + FK33_SEAM_SPAN || (off & 3u))
        return 0;                        /* writes to nothing are dropped */
    o = off - FK33_SEAM_BASE;
    if (o == FK33_SEAM_CTRL) {
        if (v & FK33_CTRL_SEQ_RESET) {
            s->next_pos = 0; s->kv_valid = 0; s->hist = 2166136261u;
            s->status = FK33_ST_DONE; s->err_info = 0;
        }
        if (v & FK33_CTRL_GO)
            run_go(s, v);
        return 0;                        /* CTRL is write-only, self-clearing */
    }
    s->reg[o / 4] = v;
    return 0;
}

static int sim_mem_read(void *c, uint64_t a, void *b, size_t n)
{ return sparse_rw(&((sim_ctx *)c)->mem, a, b, n, 0); }

static int sim_mem_write(void *c, uint64_t a, const void *b, size_t n)
{ return sparse_rw(&((sim_ctx *)c)->mem, a, (void *)(uintptr_t)b, n, 1); }

static void sim_close(void *c)
{
    sim_ctx *s = (sim_ctx *)c;
    sparse_free(&s->mem);
    free(s->logit_buf); free(s->x_buf);
    free(s);
}

static const char *sim_describe(void *c) { return ((sim_ctx *)c)->desc; }

fk33_transport *fk33_transport_open_sim(const void *opts_v)
{
    const fk33_sim_opts *in = (const fk33_sim_opts *)opts_v;
    fk33_sim_opts def;
    sim_ctx *s;
    fk33_transport *t;

    if (!in) { fk33_sim_opts_default(&def); in = &def; }

    s = (sim_ctx *)calloc(1, sizeof *s);
    if (!s) return NULL;
    s->o = *in;
    if (s->o.max_chunk <= 0) s->o.max_chunk = 512;
    if (!s->o.logits_fn) { s->o.logits_fn = default_logits; s->o.user = NULL; }

    s->logit_buf = (int32_t *)calloc((size_t)s->o.n_vocab, 4);
    s->x_buf     = (int16_t *)calloc((size_t)s->o.n_embd, 2);
    if (!s->logit_buf || !s->x_buf) { sim_close(s); return NULL; }

    s->hist   = 2166136261u;
    s->status = FK33_ST_DONE;   /* idle looks like "the last job finished" */
    snprintf(s->desc, sizeof s->desc,
             "SIMULATED card (NOT hardware, NOT a numeric reference) "
             "vocab=%d embd=%d layer=%d ctx=%d",
             s->o.n_vocab, s->o.n_embd, s->o.n_layer, s->o.max_ctx);

    t = (fk33_transport *)calloc(1, sizeof *t);
    if (!t) { sim_close(s); return NULL; }
    t->reg_read32 = sim_reg_read32;
    t->reg_write32 = sim_reg_write32;
    t->mem_read = sim_mem_read;
    t->mem_write = sim_mem_write;
    t->close = sim_close;
    t->describe = sim_describe;
    t->ctx = s;
    return t;
}

/* ------------------------------------------------------ shared seam checks */

int fk33_seam_check_blocks(uint64_t x_base, uint64_t x_bytes,
                           uint64_t l_base, uint64_t l_bytes)
{
    if ((x_base % FK33_BLOCK_ALIGN) || (l_base % FK33_BLOCK_ALIGN))
        return FK33_SEAM_ERR_ALIGN;
    if (x_base + x_bytes > FK33_HBM_TOP || l_base + l_bytes > FK33_HBM_TOP)
        return FK33_SEAM_ERR_POS;
    /* The stack rule.  A block may sit wholly below the line or wholly above
     * it; a block that crosses it is read by an engine port that can only see
     * one side, so the far half comes back as whatever that port's own stack
     * holds at those addresses.  It reads back CORRECTLY over the host port,
     * which is what makes it silent. */
    if (x_base < FK33_HBM_STACK_LINE && x_base + x_bytes > FK33_HBM_STACK_LINE)
        return FK33_SEAM_ERR_STACK;
    if (l_base < FK33_HBM_STACK_LINE && l_base + l_bytes > FK33_HBM_STACK_LINE)
        return FK33_SEAM_ERR_STACK;
    /* Overlap.  Nothing on the card checks this and a logits row landing on
     * the activation block is a wrong answer, not a fault. */
    if (x_base < l_base + l_bytes && l_base < x_base + x_bytes)
        return FK33_SEAM_ERR_RSVD;
    return 0;
}

const char *fk33_seam_strerror(unsigned code)
{
    switch (code) {
    case FK33_SEAM_ERR_NONE:  return "no error";
    case FK33_SEAM_ERR_POS:   return "out of range: SEQ_POS + N_STEP past the KV capacity, or a block past the top of HBM";
    case FK33_SEAM_ERR_NSTEP: return "N_STEP is zero or above the chunk cap";
    case FK33_SEAM_ERR_ALIGN: return "a block base is not 64-byte aligned";
    case FK33_SEAM_ERR_STACK: return "a block straddles the HBM stack boundary";
    case FK33_SEAM_ERR_RSVD:  return "a reserved field was not zero, or the blocks overlap";
    case FK33_SEAM_ERR_DESC:  return "the descriptor program was refused";
    case FK33_SEAM_ERR_HALT:  return "the thermal guard refused the GO";
    case FK33_SEAM_ERR_SEQ:   return "SEQ_POS is not the card's next position";
    default:                  return "unknown seam error";
    }
}
