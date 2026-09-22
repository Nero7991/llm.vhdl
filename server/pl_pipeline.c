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
    int      serial;       /* 1: the serial prefill baseline */
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

void plp_set_serial(plp_ctx *p, int serial) { if (p) p->serial = serial ? 1 : 0; }
int  plp_serial(const plp_ctx *p) { return p ? p->serial : 0; }

/* Card 0 has just completed a position: carry R_X into card 1 and ISSUE
 * its GO.  Timed: the read of R_X, then the push plus the GO write.  The
 * wait for card 1 is the caller's, so it can overlap card 0's next
 * position with it. */
static int hop_issue(plp_ctx *p)
{
    int32_t e = 0;
    int rc;
    double t0, t1;
    t0 = now_s();
    rc = pl_read_xout(p->c0, p->row, &e);
    t1 = now_s();
    g_read += t1 - t0;
    if (rc) return rc;
    rc = pl_decode_row_async(p->c1, p->row, e);
    g_write += now_s() - t1;
    if (rc) return rc;
    g_hops++;
    return 0;
}

/* The serial form: hop, then wait for card 1. */
static int hop_and_run1(plp_ctx *p, int *argmax)
{
    int rc = hop_issue(p);
    if (rc) return rc;
    return pl_wait(p->c1, NULL, argmax);
}

/* On an error mid-overlap a GO may still be outstanding on either card.
 * Collect it (result discarded) so the pair is left with nothing pending
 * and the caller's next verb is refused for the divergence, not for -7. */
static void drain(plp_ctx *p)
{
    int am = -1;
    if (pl_pending(p->c0)) pl_wait(p->c0, NULL, &am);
    if (pl_pending(p->c1)) pl_wait(p->c1, NULL, &am);
}

/* Both cards must be at the same position before every step; a skipped or
 * repeated hop would otherwise run card 1 over the wrong history and
 * produce a plausible token.  -6 is this layer's own code. */
static int aligned(const plp_ctx *p)
{
    return pl_seq_pos(p->c0) == pl_seq_pos(p->c1);
}

static int prefill_serial(plp_ctx *p, const int *ids, int n, int *argmax)
{
    int k, rc, am0 = -1;
    for (k = 0; k < n; k++) {
        rc = pl_decode(p->c0, ids[k], NULL, NULL, &am0);
        if (rc < 0) return rc;
        rc = hop_and_run1(p, argmax);
        if (rc < 0) return rc;
    }
    return n;
}

/* THE OVERLAP.  Per position k: wait for card 0 (position k), read R_X
 * BEFORE re-issuing card 0 (the next GO overwrites the window), issue card
 * 0 at k+1, wait for card 1 (position k-1) so its windows are free, then
 * push R_X and issue card 1 at k.  Card 1's last GO is collected after the
 * loop and carries the prompt's argmax.  Every wait is on the card whose
 * GO was issued longest ago, so the host never stalls on the wrong one. */
static int prefill_overlap(plp_ctx *p, const int *ids, int n, int *argmax)
{
    int k, rc, am0 = -1, am1 = -1;
    rc = pl_decode_async(p->c0, ids[0]);
    if (rc) return rc;
    for (k = 0; k < n; k++) {
        rc = pl_wait(p->c0, NULL, &am0);
        if (rc < 0) { drain(p); return rc; }
        {
            int32_t e = 0;
            double t0 = now_s();
            rc = pl_read_xout(p->c0, p->row, &e);
            g_read += now_s() - t0;
            if (rc) { drain(p); return rc; }
            if (k + 1 < n) {
                rc = pl_decode_async(p->c0, ids[k + 1]);
                if (rc) { drain(p); return rc; }
            }
            if (k > 0) {
                rc = pl_wait(p->c1, NULL, &am1);
                if (rc < 0) { drain(p); return rc; }
            }
            t0 = now_s();
            rc = pl_decode_row_async(p->c1, p->row, e);
            g_write += now_s() - t0;
            if (rc) { drain(p); return rc; }
            g_hops++;
        }
    }
    rc = pl_wait(p->c1, NULL, argmax);
    if (rc < 0) { drain(p); return rc; }
    return n;
}

int plp_prefill(plp_ctx *p, const int *ids, int n, int *argmax)
{
    if (!p || !ids || n <= 0) return -1;
    if (!aligned(p)) return -6;
    if (pl_pending(p->c0) || pl_pending(p->c1)) return -7;
    return p->serial ? prefill_serial(p, ids, n, argmax)
                     : prefill_overlap(p, ids, n, argmax);
}

int plp_decode(plp_ctx *p, int id, int *argmax)
{
    int rc, am0 = -1;
    if (!p) return -1;
    if (!aligned(p)) return -6;
    if (pl_pending(p->c0) || pl_pending(p->c1)) return -7;
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
