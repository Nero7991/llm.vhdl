/* server/pl_backend.c -- v2 of the host seam.  See pl_backend.h, then
 * fk33_seam.h.  Nothing here has ever run against the card.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "pl_backend.h"
#include "fk33_transport.h"
#include "fk33_seam.h"

/* How long to wait for a GO.  The token budget is 38.27 ms
 * (docs/2026-08-28_token-io-path.md); a prefill chunk of 512 is 512 of those,
 * so 60 s covers the largest legal chunk with two orders of margin and still
 * fails in a human-noticeable time rather than hanging a server thread. */
#define PL_GO_TIMEOUT_MS 60000

struct pl_ctx {
    fk33_transport *t;
    uint32_t base;

    int n_vocab, n_embd, n_layer, max_ctx, max_chunk;
    uint64_t x_base, l_base, desc_ptr;
    uint64_t x_stride, l_stride;

    pl_embed_fn embed;
    void       *embed_user;

    int next_pos;

    unsigned last_err;
    uint32_t last_err_info;

    uint64_t to_card, from_card, gos;
    int go_timeout_ms;

    /* One activation staging buffer, reused.  x_stride bytes. */
    unsigned char *xbuf;
    /* One logits staging buffer, l_stride bytes, allocated lazily because a
     * greedy-only server never needs it and it is ~1 MB. */
    unsigned char *lbuf;

    char desc[320];
};

/* ------------------------------------------------------------- synthetic */

int pl_embed_synthetic(void *user, int token_id,
                       int16_t *mant, int n_embd, int32_t *exp)
{
    int i;
    uint32_t h = 2166136261u ^ (uint32_t)token_id;
    (void)user;
    for (i = 0; i < n_embd; i++) {
        h ^= (uint32_t)i; h *= 16777619u;
        mant[i] = (int16_t)((int32_t)(h >> 16) - 32768);
    }
    *exp = -8;
    return 0;
}

/* ------------------------------------------------------------- register IO */

static int rd(pl_ctx *c, uint32_t off, uint32_t *v)
{ return c->t->reg_read32(c->t->ctx, c->base + off, v); }

static int wr(pl_ctx *c, uint32_t off, uint32_t v)
{ return c->t->reg_write32(c->t->ctx, c->base + off, v); }

static int wr64(pl_ctx *c, uint32_t lo, uint32_t hi, uint64_t v)
{
    int rc = wr(c, lo, (uint32_t)(v & 0xFFFFFFFFu));
    if (rc) return rc;
    return wr(c, hi, (uint32_t)(v >> 32));
}

static double pl_now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* THE ONLY CORRECT WAIT.  `done` is latched and is NEVER set on an error, so a
 * done-only poller hangs forever -- the descriptor-format document states this
 * for subsystem A and the simulated card reproduces it under
 * fault_never_done.  Poll (done | err). */
static int seam_wait(pl_ctx *c, uint32_t *status_out)
{
    uint32_t st = 0;
    double t0 = pl_now_s();

    for (;;) {
        if (rd(c, FK33_SEAM_STATUS, &st)) return -2;
        if (st & (FK33_ST_DONE | FK33_ST_ERR)) break;
        if ((pl_now_s() - t0) * 1000.0 > (double)c->go_timeout_ms) {
            if (status_out) *status_out = st;
            fprintf(stderr,
                "[pl_backend] TIMEOUT after %d ms with STATUS=0x%08X.\n"
                "  Neither done nor err is set.  If busy is high the card is\n"
                "  still working; if it is not, the GO was never taken.\n",
                c->go_timeout_ms, st);
            return -4;
        }
    }
    if (status_out) *status_out = st;
    if (st & FK33_ST_ERR) {
        uint32_t info = 0;
        c->last_err = FK33_ST_ERRCODE(st);
        rd(c, FK33_SEAM_ERR_INFO, &info);
        c->last_err_info = info;
        return -3;
    }
    if (!(st & FK33_ST_DONE)) return -4;
    c->last_err = FK33_SEAM_ERR_NONE;
    c->last_err_info = 0;
    return 0;
}

/* --------------------------------------------------------------- lifecycle */

void pl_open_opts_default(pl_open_opts *o)
{
    memset(o, 0, sizeof *o);
    o->transport = PL_TRANSPORT_SIM;
    o->seam_base = FK33_SEAM_BASE_PROPOSED;
    /* Inside the LOWER HBM stack, well above anything the bring-up program
     * touches and below the stack line at 0x1_0000_0000.  These are
     * placeholders in the sense that the residency map and the shipped
     * manifest disagree about the whole layout; they are NOT placeholders in
     * the sense of being unchecked -- fk33_seam_check_blocks runs on them. */
    o->x_base   = 0x00E0000000ull;
    o->l_base   = 0x00E1000000ull;
    o->desc_ptr = 0x00E2000000ull;
    o->embed    = pl_embed_synthetic;
    o->max_chunk = 0;
}

int pl_open(const pl_open_opts *o, pl_ctx **out)
{
    pl_open_opts def;
    pl_ctx *c;
    uint32_t v = 0;
    int rc;

    if (!out) return -1;
    if (!o) { pl_open_opts_default(&def); o = &def; }
    if (!o->embed) {
        fprintf(stderr, "pl_open: opts.embed is NULL.  Pass pl_embed_synthetic\n"
                        "  explicitly if you meant the synthetic one; it is not\n"
                        "  a default, because a silently synthetic embedding is\n"
                        "  a confident wrong answer.\n");
        return -1;
    }

    c = (pl_ctx *)calloc(1, sizeof *c);
    if (!c) return -1;
    c->base = o->seam_base ? o->seam_base : FK33_SEAM_BASE_PROPOSED;
    c->embed = o->embed;
    c->embed_user = o->embed_user;
    c->x_base = o->x_base; c->l_base = o->l_base; c->desc_ptr = o->desc_ptr;

    switch (o->transport) {
    case PL_TRANSPORT_SIM:
        c->t = fk33_transport_open_sim(o->sim_opts);
        break;
    case PL_TRANSPORT_FILE:
        c->t = fk33_transport_open_filedir(o->file_dir ? o->file_dir : "fk33_file_backend");
        break;
    case PL_TRANSPORT_CHARDEV:
        c->t = fk33_transport_open_chardev(
                   o->dev_user ? o->dev_user : "/dev/xdma0_user",
                   o->dev_h2c  ? o->dev_h2c  : "/dev/xdma0_h2c_0",
                   o->dev_c2h  ? o->dev_c2h  : "/dev/xdma0_c2h_0",
                   o->allow_hardware);
        break;
    default:
        c->t = NULL;
    }
    if (!c->t) { free(c); return -2; }

    /* Identity first.  The bring-up procedure's argument applies unchanged:
     * 0xFFFFFFFF means the BAR is mapped with nothing answering and
     * 0x00000000 means the fabric is in reset, so both plausible wrong
     * answers are distinguishable from a correct one. */
    rc = rd(c, FK33_SEAM_ID, &v);
    if (rc) { pl_close(c); return -2; }
    if (v != FK33_SEAM_ID_MAGIC) {
        fprintf(stderr,
            "pl_open: seam ID at BAR+0x%X reads 0x%08X, expected 0x%08X.\n"
            "  0xFFFFFFFF = BAR mapped, nothing answering at this offset.\n"
            "  0x00000000 = the fabric is held in reset.\n"
            "  Anything else = a different bitstream, or the wrong seam_base.\n"
            "  NOTE the seam base is PROPOSED, not decided: hw/fk33/gen_pcieep.py\n"
            "  owns every BAR offset and no bitstream implements this block yet.\n",
            c->base + FK33_SEAM_ID, v, FK33_SEAM_ID_MAGIC);
        pl_close(c); return -3;
    }
    rd(c, FK33_SEAM_VERSION, &v);
    if (v != FK33_SEAM_VERSION_1) {
        fprintf(stderr, "pl_open: seam contract version %u, this host speaks %u\n",
                v, FK33_SEAM_VERSION_1);
        pl_close(c); return -3;
    }

    rd(c, FK33_SEAM_CAPS_VOCAB, &v); c->n_vocab = (int)v;
    rd(c, FK33_SEAM_CAPS_EMBD,  &v); c->n_embd = (int)(v & 0xFFFFu);
                                     c->n_layer = (int)(v >> 16);
    rd(c, FK33_SEAM_CAPS_CTX,   &v); c->max_ctx = (int)v;
    if (c->n_vocab <= 0 || c->n_embd <= 0 || c->max_ctx <= 0) {
        fprintf(stderr, "pl_open: implausible CAPS vocab=%d embd=%d ctx=%d\n",
                c->n_vocab, c->n_embd, c->max_ctx);
        pl_close(c); return -3;
    }
    c->max_chunk = o->max_chunk > 0 ? o->max_chunk : 512;
    c->go_timeout_ms = o->go_timeout_ms > 0 ? o->go_timeout_ms : PL_GO_TIMEOUT_MS;

    c->x_stride = fk33_x_stride(c->n_embd);
    c->l_stride = fk33_l_stride(c->n_vocab);

    /* The explicit host-side stack assertion the residency map asks for.  Run
     * ONCE at open, at the largest extent either block can reach, so a layout
     * that would straddle the line is refused before any DMA rather than after
     * a run of silently wrong tokens. */
    {
        int e = fk33_seam_check_blocks(c->x_base,
                                       c->x_stride * (uint64_t)c->max_chunk,
                                       c->l_base, c->l_stride);
        if (e) {
            fprintf(stderr, "pl_open: block layout refused: %s\n"
                            "  x_base=0x%llX span=%llu  l_base=0x%llX span=%llu\n",
                    fk33_seam_strerror((unsigned)e),
                    (unsigned long long)c->x_base,
                    (unsigned long long)(c->x_stride * (uint64_t)c->max_chunk),
                    (unsigned long long)c->l_base,
                    (unsigned long long)c->l_stride);
            pl_close(c); return -3;
        }
    }
    if (c->desc_ptr % 512ull) {
        fprintf(stderr, "pl_open: desc_ptr 0x%llX is not 512-byte aligned "
                        "(DESC_MAXB * AXI_DW/8 on the FK33)\n",
                (unsigned long long)c->desc_ptr);
        pl_close(c); return -3;
    }

    c->xbuf = (unsigned char *)calloc(1, (size_t)c->x_stride);
    if (!c->xbuf) { pl_close(c); return -1; }

    if (c->embed == pl_embed_synthetic)
        fprintf(stderr, "[pl_backend] WARNING: the SYNTHETIC embedding provider is in\n"
                        "  use.  It is not a model of anything.  Every token this\n"
                        "  backend produces is plumbing, not inference.\n");

    snprintf(c->desc, sizeof c->desc,
             "seam v%u @BAR+0x%X vocab=%d embd=%d layer=%d ctx=%d chunk=%d "
             "x_stride=%llu l_stride=%llu | %s",
             FK33_SEAM_VERSION_1, c->base, c->n_vocab, c->n_embd, c->n_layer,
             c->max_ctx, c->max_chunk,
             (unsigned long long)c->x_stride, (unsigned long long)c->l_stride,
             c->t->describe(c->t->ctx));

    *out = c;
    return 0;
}

void pl_close(pl_ctx *c)
{
    if (!c) return;
    if (c->t) { c->t->close(c->t->ctx); free(c->t); }
    free(c->xbuf); free(c->lbuf);
    free(c);
}

const char *pl_describe(const pl_ctx *c) { return c ? c->desc : "(none)"; }
int pl_n_vocab (const pl_ctx *c) { return c ? c->n_vocab : 0; }
int pl_n_embd  (const pl_ctx *c) { return c ? c->n_embd  : 0; }
int pl_n_layer (const pl_ctx *c) { return c ? c->n_layer : 0; }
int pl_max_ctx (const pl_ctx *c) { return c ? c->max_ctx : 0; }
int pl_max_chunk(const pl_ctx *c) { return c ? c->max_chunk : 0; }
int pl_seq_pos (const pl_ctx *c) { return c ? c->next_pos : 0; }

unsigned    pl_last_error(const pl_ctx *c)      { return c ? c->last_err : 0; }
uint32_t    pl_last_error_info(const pl_ctx *c) { return c ? c->last_err_info : 0; }
const char *pl_last_error_str(const pl_ctx *c)
{ return fk33_seam_strerror(c ? c->last_err : 0); }
uint64_t pl_bytes_to_card(const pl_ctx *c)   { return c ? c->to_card : 0; }
uint64_t pl_bytes_from_card(const pl_ctx *c) { return c ? c->from_card : 0; }
uint64_t pl_go_count(const pl_ctx *c)        { return c ? c->gos : 0; }

int pl_check_vocab(const pl_ctx *c, int n)
{
    if (!c) return -1;
    if (c->n_vocab == n) return 0;
    fprintf(stderr,
        "pl_check_vocab: THE CARD AND THE TOKENIZER DISAGREE.  card=%d tokenizer=%d\n"
        "  The audit records this number as unverified (section 5.3):\n"
        "  rtl/model_cfg_pkg.vhd says 248320, the shipped Qwen3 tokenizer said\n"
        "  151936, and nothing in any spec derives it.  A disagreement here is\n"
        "  a wrong answer, not a warning.\n", c->n_vocab, n);
    return -1;
}

int pl_seq_reset(pl_ctx *c)
{
    uint32_t st = 0;
    if (!c) return -1;
    c->last_err = FK33_SEAM_ERR_NONE;
    c->last_err_info = 0;
    if (wr(c, FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET)) return -2;
    if (rd(c, FK33_SEAM_STATUS, &st)) return -2;
    if (st & FK33_ST_ERR) { c->last_err = FK33_ST_ERRCODE(st); return -3; }
    c->next_pos = 0;
    return 0;
}

/* ------------------------------------------------------------------ the run */

/* Stage one activation row into c->xbuf and DMA it to slot `k`. */
static int push_x(pl_ctx *c, int k, int token_id)
{
    int32_t exp = 0;
    int rc;
    memset(c->xbuf, 0, (size_t)c->x_stride);
    rc = c->embed(c->embed_user, token_id,
                  (int16_t *)(c->xbuf + FK33_SEAM_HDR_BYTES), c->n_embd, &exp);
    if (rc) return -5;
    memcpy(c->xbuf + 0, &exp, 4);
    { uint32_t t = (uint32_t)token_id; memcpy(c->xbuf + 4, &t, 4); }
    /* bytes 8..15 stay zero: the card refuses a non-zero reserved field, and
     * the memset above is what guarantees it rather than a comment. */
    rc = c->t->mem_write(c->t->ctx, c->x_base + c->x_stride * (uint64_t)k,
                         c->xbuf, (size_t)c->x_stride);
    if (rc) return -2;
    c->to_card += c->x_stride;
    return 0;
}

/* Run one GO covering `n` steps starting at c->next_pos.  `want_logits`
 * selects whether the ~1 MB C2H happens at all. */
static int run_chunk(pl_ctx *c, int n, int want_logits,
                     int32_t *logits, int32_t *logit_exp, int *argmax)
{
    uint32_t st = 0, v = 0;
    int rc;

    if (n <= 0 || n > c->max_chunk) return -1;
    if (c->next_pos + n > c->max_ctx) return -1;

    if (wr(c, FK33_SEAM_SEQ_POS, (uint32_t)c->next_pos)) return -2;
    if (wr(c, FK33_SEAM_N_STEP,  (uint32_t)n)) return -2;
    if (wr64(c, FK33_SEAM_X_BASE_LO, FK33_SEAM_X_BASE_HI, c->x_base)) return -2;
    if (wr64(c, FK33_SEAM_L_BASE_LO, FK33_SEAM_L_BASE_HI, c->l_base)) return -2;
    if (wr64(c, FK33_SEAM_DESC_PTR_LO, FK33_SEAM_DESC_PTR_HI, c->desc_ptr)) return -2;

    c->gos++;
    if (wr(c, FK33_SEAM_CTRL, FK33_CTRL_GO)) return -2;

    rc = seam_wait(c, &st);
    if (rc) return rc;

    c->next_pos += n;

    if (argmax) {
        if (rd(c, FK33_SEAM_ARGMAX, &v)) return -2;
        *argmax = (int)v;
    }
    if (logit_exp) {
        if (rd(c, FK33_SEAM_LOGIT_EXP, &v)) return -2;
        *logit_exp = (int32_t)v;
    }

    if (want_logits && logits) {
        size_t nb = (size_t)c->n_vocab * 4;
        if (!c->lbuf) {
            c->lbuf = (unsigned char *)malloc((size_t)c->l_stride);
            if (!c->lbuf) return -1;
        }
        if (c->t->mem_read(c->t->ctx, c->l_base, c->lbuf, (size_t)c->l_stride))
            return -2;
        c->from_card += c->l_stride;
        /* The header is read back and CHECKED against the registers rather
         * than ignored.  A card whose DMA'd row and whose register disagree is
         * a card mid-update, and reading the row without noticing is exactly
         * how a stale logits vector becomes a plausible token. */
        {
            int32_t hexp = 0, hargmax = 0;
            memcpy(&hexp, c->lbuf + 0, 4);
            memcpy(&hargmax, c->lbuf + 4, 4);
            if (logit_exp && hexp != *logit_exp) return -3;
            if (argmax && hargmax != *argmax) return -3;
            if (logit_exp) *logit_exp = hexp;
            if (argmax) *argmax = hargmax;
        }
        memcpy(logits, c->lbuf + FK33_SEAM_HDR_BYTES, nb);
    }
    return n;
}

int pl_prefill(pl_ctx *c, const int *ids, int n,
               int32_t *logits, int32_t *logit_exp, int *argmax)
{
    int done = 0;
    if (!c || !ids || n <= 0) return -1;
    if (c->next_pos + n > c->max_ctx) return -1;

    while (done < n) {
        int k, chunk = n - done;
        int last;
        if (chunk > c->max_chunk) chunk = c->max_chunk;
        last = (done + chunk == n);
        for (k = 0; k < chunk; k++) {
            int rc = push_x(c, k, ids[done + k]);
            if (rc) return rc;
        }
        {
            int rc = run_chunk(c, chunk, last && logits != NULL,
                               last ? logits : NULL,
                               last ? logit_exp : NULL,
                               last ? argmax : NULL);
            if (rc < 0) return rc;
        }
        done += chunk;
    }
    return done;
}

int pl_decode(pl_ctx *c, int id,
              int32_t *logits, int32_t *logit_exp, int *argmax)
{
    int rc;
    if (!c) return -1;
    if (c->next_pos + 1 > c->max_ctx) return -1;
    rc = push_x(c, 0, id);
    if (rc) return rc;
    return run_chunk(c, 1, logits != NULL, logits, logit_exp, argmax);
}
