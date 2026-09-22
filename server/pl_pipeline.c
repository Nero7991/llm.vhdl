/* server/pl_pipeline.c -- two cards, one model, the host carries R_X.
 * See pl_pipeline.h.  2026-09-21. */
#define _POSIX_C_SOURCE 200809L
#include "pl_pipeline.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct plp_ctx {
    pl_ctx  *c0, *c1;
    int      n_embd;
    int16_t *row;          /* n_embd, the hop buffer */
};

static double g_read = 0, g_write = 0;
static unsigned long g_hops = 0;

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

int plp_open(pl_ctx *c0, pl_ctx *c1, plp_ctx **out)
{
    plp_ctx *p;
    if (!c0 || !c1 || !out) return -1;
    if (pl_version(c0) < 2 || pl_version(c1) < 2) return -1;
    if (pl_n_embd(c0) != pl_n_embd(c1) || pl_n_embd(c0) <= 0) return -1;
    p = (plp_ctx *)calloc(1, sizeof *p);
    if (!p) return -1;
    p->c0 = c0; p->c1 = c1; p->n_embd = pl_n_embd(c0);
    p->row = (int16_t *)calloc((size_t)p->n_embd, sizeof(int16_t));
    if (!p->row) { free(p); return -1; }
    *out = p;
    return 0;
}

void plp_close(plp_ctx *p)
{
    if (!p) return;
    free(p->row);
    free(p);
}

int plp_seq_reset(plp_ctx *p)
{
    int rc;
    if (!p) return -1;
    rc = pl_seq_reset(p->c0);
    if (rc) return rc;
    return pl_seq_reset(p->c1);
}

int plp_seq_pos(const plp_ctx *p)
{
    return p ? pl_seq_pos(p->c1) : -1;
}

/* Card 0 has just completed position pos: carry R_X into card 1 and run it
 * at the same position.  The GO on card 1 is inside pl_decode_row and is
 * NOT counted as hop time; only the read and the push are. */
static int hop_and_run1(plp_ctx *p, int *argmax)
{
    int32_t e = 0;
    int rc;
    double t0, t1;
    t0 = now_s();
    rc = pl_read_xout(p->c0, p->row, &e);
    t1 = now_s();
    g_read += t1 - t0;
    if (rc) return rc;
    /* The push is the first thing pl_decode_row does; the GO follows.  We
     * cannot separate the two from here without a second entry point, so
     * the write figure below includes card 1's GO and is an upper bound
     * on the push.  pl_host_timing's per-card numbers give the GO share. */
    rc = pl_decode_row(p->c1, p->row, e, NULL, NULL, argmax);
    g_write += now_s() - t1;
    g_hops++;
    return rc;
}

/* Both cards must be at the same position before every step; a skipped or
 * repeated hop would otherwise run card 1 over the wrong history and
 * produce a plausible token.  -6 is this layer's own code. */
static int aligned(const plp_ctx *p)
{
    return pl_seq_pos(p->c0) == pl_seq_pos(p->c1);
}

int plp_prefill(plp_ctx *p, const int *ids, int n, int *argmax)
{
    int k, rc, am0 = -1;
    if (!p || !ids || n <= 0) return -1;
    if (!aligned(p)) return -6;
    for (k = 0; k < n; k++) {
        /* SERIAL in phase 0; see the header. */
        rc = pl_decode(p->c0, ids[k], NULL, NULL, &am0);
        if (rc < 0) return rc;
        rc = hop_and_run1(p, argmax);
        if (rc < 0) return rc;
    }
    return n;
}

int plp_decode(plp_ctx *p, int id, int *argmax)
{
    int rc, am0 = -1;
    if (!p) return -1;
    if (!aligned(p)) return -6;
    rc = pl_decode(p->c0, id, NULL, NULL, &am0);
    if (rc < 0) return rc;
    return hop_and_run1(p, argmax);
}

void plp_hop_timing(double *read_s, double *write_s, unsigned long *hops)
{
    if (read_s)  *read_s  = g_read;
    if (write_s) *write_s = g_write;
    if (hops)    *hops    = g_hops;
}
