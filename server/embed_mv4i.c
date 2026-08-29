/* server/embed_mv4i.c -- see embed_mv4i.h for what this is and which copy of
 * the embedding it reads.  Nothing here has run against the card.
 *
 * THIS IS A THIRD INDEPENDENT IMPLEMENTATION OF SPEC 6.5a's LAYOUT, AND THAT
 * IS DELIBERATE.  `ref/matvec_int4.c` addresses one WEIGHT AT A TIME
 * (`get_widx(f, r, k)` recomputes the sub-region and the beat per element) and
 * `tools/embed_gather.py` addresses a whole row in numpy.  This file addresses
 * a row as TWO CONTIGUOUS READS, which is the shape a driver issues and the
 * shape an on-card gatherer would issue, and it shares no arithmetic with
 * either.  A round trip through my own decoder would prove nothing (CLAUDE.md's
 * `m7`); three implementations that disagree about nothing, plus a BF16 oracle
 * that never touches the packed file, is the check.  It is run by
 * tools/check_embed_c.py.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "embed_mv4i.h"

#define MV4I_MAGIC      0x4D563449u   /* "MV4I" */
#define MV4I_BLOCK      32
#define MV4I_HDR_BYTES  4096
#define MV4I_MAX_SUB    64
#define TARGET_MSB      14            /* 16 - 2, the BFP headroom this repo uses */

struct pl_embed_mv4i_s {
    int fd;
    char path[512];
    char desc[1024];

    /* spec 6.4 header fields */
    uint32_t M, K, scale_offset, n_scale_sub;
    uint16_t version, flags, rows_if, nports_w, block, axi_dw;
    int32_t  w_exp, out_shift;
    int8_t   codebook[16];
    uint64_t w_sub_offset[MV4I_MAX_SUB];
    uint64_t s_sub_offset[MV4I_MAX_SUB];

    /* spec 6.5a derived geometry */
    int nb;               /* ceil(K / BLOCK), blocks per row                */
    int tiles;            /* ceil(M / ROWS_IF)                              */
    int port_b;           /* AXI_DW / 8, bytes per beat of one sub-region   */
    int row_b;            /* BLOCK / 2, bytes of one row's chunk            */
    int rows_per_beat;    /* port_b / row_b                                 */
    int scales_per_beat;  /* port_b / 2                                     */
    int grp;              /* scale groups per superword; must be 1 here     */
    size_t sub_bytes;     /* bytes of one sub-region, whole tensor          */
    size_t read_bytes;    /* nb * port_b, the size of each of the two reads */

    int scale_offset_only;  /* pre-6.5a file: the scale table is one region */
    int recipe;
    int mutant;

    unsigned char *wbuf, *sbuf;
    int32_t *vals;

    uint64_t bytes_read, gathers;
};

/* ------------------------------------------------------- little arithmetic */

static int32_t floor_shr32(int32_t v, int sh)
{
    /* C's >> on a negative signed value is implementation-defined.  Spelt out
     * so this file does not depend on gcc doing the arithmetic shift. */
    if (sh <= 0) return v;
    if (v >= 0) return (int32_t)((uint32_t)v >> sh);
    return (int32_t)(-(int32_t)(((uint32_t)(-(int64_t)v) + ((1u << sh) - 1u)) >> sh));
}

static int64_t round_shift64(int64_t v, int sh, int truncate)
{
    /* mv4i_round_shift: round half toward +infinity, no bias at sh == 0.
     * Extended to NEGATIVE sh, which a BFP encode of a small row needs and
     * which is exact.  `truncate` is PL_EMBED_MUT_TRUNCATE. */
    if (sh == 0) return v;
    if (sh < 0)  return v << (-sh);
    if (truncate) {
        if (v >= 0) return v >> sh;
        return -(((-v) + ((int64_t)1 << sh) - 1) >> sh);
    }
    {
        int64_t t = v + ((int64_t)1 << (sh - 1));
        if (t >= 0) return t >> sh;
        return -(((-t) + ((int64_t)1 << sh) - 1) >> sh);
    }
}

static int16_t sat16_64(int64_t v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

/* mv4i_msb_pos_u.  msb_pos(0) = 0 is NORMATIVE. */
static int msb_pos_u(uint64_t a)
{
    int p = 0;
    if (!a) return 0;
    while (a >>= 1) p++;
    return p;
}

static uint16_t rd_u16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd_u32(const unsigned char *p)
{ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t rd_u64(const unsigned char *p)
{ return (uint64_t)rd_u32(p) | ((uint64_t)rd_u32(p + 4) << 32); }

static uint64_t u_gcd(uint64_t a, uint64_t b) { while (b) { uint64_t t = a % b; a = b; b = t; } return a; }

/* ------------------------------------------------------------------ mutants */

const char *pl_embed_mv4i_mutant_name(int m)
{
    switch (m) {
    case PL_EMBED_MUT_NONE:       return "c0 clean (control)";
    case PL_EMBED_MUT_NIBBLE:     return "c1 nibble order swapped";
    case PL_EMBED_MUT_HALF:       return "c2 wrong half of the beat";
    case PL_EMBED_MUT_WSUB:       return "c3 weight sub-region + 1";
    case PL_EMBED_MUT_TILE:       return "c4 tile + 1";
    case PL_EMBED_MUT_SSUB:       return "c5 scale sub-region + 1";
    case PL_EMBED_MUT_SIDX:       return "c6 scale index within beat + 1";
    case PL_EMBED_MUT_BLOCKMAJOR: return "c7 beats read block-major not tile-major";
    case PL_EMBED_MUT_CODEBOOK:   return "c8 codebook reversed";
    case PL_EMBED_MUT_TARGET_MSB: return "c9 BFP headroom TARGET_MSB 14 -> 13";
    case PL_EMBED_MUT_TRUNCATE:   return "c10 BFP pack truncates instead of rounding";
    case PL_EMBED_MUT_EXPSIGN:    return "c11 x_exp returned with the wrong sign";
    case PL_EMBED_MUT_SCALE_BE:   return "c12 scales read big-endian";
    default:                      return "(no such mutant)";
    }
}

int pl_embed_mv4i_set_mutant(pl_embed_mv4i_t *e, int m)
{
#ifdef EMBED_MV4I_MUTANTS
    if (!e || m < 0 || m >= PL_EMBED_MUT_COUNT) return -1;
    e->mutant = m;
    return 0;
#else
    (void)e; (void)m;
    return -1;    /* a shipped build cannot select a defect */
#endif
}

#ifdef EMBED_MV4I_MUTANTS
#define MUT(e, m) ((e)->mutant == (m))
#else
#define MUT(e, m) (0)
#endif

/* ----------------------------------------------------------------- open */

static int hdr_fail(const char *path, const char *what)
{
    fprintf(stderr, "pl_embed_mv4i: %s: %s\n", path, what);
    return -1;
}

static ssize_t pread_all(int fd, void *buf, size_t n, uint64_t off)
{
    unsigned char *p = (unsigned char *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = pread(fd, p + got, n - got, (off_t)(off + got));
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return (ssize_t)got;      /* short: caller decides */
        got += (size_t)r;
    }
    return (ssize_t)got;
}

int pl_embed_mv4i_open(const char *path, int recipe, pl_embed_mv4i_t **out)
{
    unsigned char hdr[MV4I_HDR_BYTES];
    pl_embed_mv4i_t *e;
    unsigned i;
    uint64_t sw, need;

    if (!path || !out) return -1;
    if (recipe != PL_EMBED_RECIPE_WIDE && recipe != PL_EMBED_RECIPE_D32) {
        fprintf(stderr, "pl_embed_mv4i: recipe %d is neither WIDE nor D32\n", recipe);
        return -1;
    }
    e = (pl_embed_mv4i_t *)calloc(1, sizeof *e);
    if (!e) return -1;
    e->recipe = recipe;
    e->fd = open(path, O_RDONLY);
    if (e->fd < 0) {
        fprintf(stderr, "pl_embed_mv4i: %s: %s\n", path, strerror(errno));
        free(e); return -1;
    }
    snprintf(e->path, sizeof e->path, "%s", path);
    if (pread_all(e->fd, hdr, sizeof hdr, 0) != (ssize_t)sizeof hdr)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "shorter than the 4 KB header"); }

    if (rd_u32(hdr + 0x00) != MV4I_MAGIC)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "magic is not MV4I"); }
    e->version    = rd_u16(hdr + 0x04);
    e->flags      = rd_u16(hdr + 0x06);
    e->M          = rd_u32(hdr + 0x08);
    e->K          = rd_u32(hdr + 0x0C);
    e->w_exp      = (int32_t)rd_u32(hdr + 0x10);   /* SIGNED, two's complement */
    e->out_shift  = (int32_t)rd_u32(hdr + 0x14);
    e->rows_if    = rd_u16(hdr + 0x18);
    e->nports_w   = rd_u16(hdr + 0x1A);
    e->block      = rd_u16(hdr + 0x1C);
    e->axi_dw     = rd_u16(hdr + 0x1E);
    for (i = 0; i < 16; i++) e->codebook[i] = (int8_t)hdr[0x20 + i];
    e->scale_offset = rd_u32(hdr + 0x30);
    e->n_scale_sub  = rd_u32(hdr + 0x34);

    /* 0x1E was "reserved (0)" until 2026-08-27.  ref/matvec_int4.c reads a zero
     * there as 128 for one reason: 128 is the only width the layout was ever
     * defined at.  Same rule here, so the two cannot disagree about an old file. */
    if (e->axi_dw == 0) e->axi_dw = 128;

    if (e->block != MV4I_BLOCK)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "BLOCK is not 32"); }
    if (e->rows_if == 0 || e->nports_w == 0)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "ROWS_IF or NPORTS_W is zero"); }
    if (e->axi_dw % 8 || e->axi_dw > 1024)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "AXI_DW is not an AXI4 data width"); }
    if (e->nports_w > MV4I_MAX_SUB)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "NPORTS_W exceeds the offset-table bound"); }
    if ((uint32_t)e->nports_w * e->axi_dw != (uint32_t)e->rows_if * e->block * 4u)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "spec 6.5 invariant NPORTS_W*AXI_DW == ROWS_IF*BLOCK*4 fails"); }
    if (e->M == 0 || e->K == 0)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "M or K is zero"); }
    for (i = 0; i < 16; i++)
        if (e->codebook[i] == -128)
        { pl_embed_mv4i_close(e); return hdr_fail(path, "codebook entry -128 is forbidden (7.4)"); }

    /* spec 6.5a scale geometry, re-derived rather than trusted. */
    sw = (uint64_t)e->rows_if * 16u;
    {
        uint64_t nss = sw / u_gcd(sw, (uint64_t)e->axi_dw);
        if (e->n_scale_sub == 0) {          /* pre-6.5a file: one sub-region */
            e->n_scale_sub = 1;
            e->s_sub_offset[0] = e->scale_offset;
            e->scale_offset_only = 1;
        }
        if ((uint64_t)e->n_scale_sub != nss) {
            char m[128];
            snprintf(m, sizeof m, "n_scale_sub is %u, spec 6.5a says %llu",
                     e->n_scale_sub, (unsigned long long)nss);
            pl_embed_mv4i_close(e); return hdr_fail(path, m);
        }
        if (e->n_scale_sub > MV4I_MAX_SUB)
        { pl_embed_mv4i_close(e); return hdr_fail(path, "n_scale_sub exceeds the offset-table bound"); }
        e->grp = (int)((uint64_t)e->n_scale_sub * e->axi_dw / sw);
    }
    if (0x38 + 8 * ((size_t)e->nports_w + e->n_scale_sub) > MV4I_HDR_BYTES)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "offset table does not fit the 4 KB header"); }
    for (i = 0; i < e->nports_w; i++)
        e->w_sub_offset[i] = rd_u64(hdr + 0x38 + 8 * i);
    if (!e->scale_offset_only)
        for (i = 0; i < e->n_scale_sub; i++)
            e->s_sub_offset[i] = rd_u64(hdr + 0x38 + 8 * (size_t)e->nports_w + 8 * i);

    e->nb     = (int)((e->K + MV4I_BLOCK - 1) / MV4I_BLOCK);
    e->tiles  = (int)((e->M + e->rows_if - 1) / e->rows_if);
    e->port_b = e->axi_dw / 8;
    e->row_b  = e->block / 2;
    e->sub_bytes  = (size_t)e->tiles * (size_t)e->nb * (size_t)e->port_b;
    e->read_bytes = (size_t)e->nb * (size_t)e->port_b;

    if (e->port_b % e->row_b) {
        char m[160];
        snprintf(m, sizeof m, "AXI_DW = %u is not a whole number of %d-byte row "
                 "chunks; the two-contiguous-reads gather does not apply",
                 e->axi_dw, e->row_b);
        pl_embed_mv4i_close(e); return hdr_fail(path, m);
    }
    e->rows_per_beat   = e->port_b / e->row_b;
    e->scales_per_beat = e->port_b / 2;
    if (e->scales_per_beat == 0)
    { pl_embed_mv4i_close(e); return hdr_fail(path, "AXI_DW < 16: a scale straddles two sub-regions"); }
    if (e->grp != 1) {
        char m[160];
        /* GRP > 1 packs several (t, b) groups into one superword, so the scale
         * beat index stops being t*nb+b and the second read stops being
         * contiguous.  Refuse rather than guess; `tools/embed_gather.py`, the
         * reference this is checked against, refuses on the same rule. */
        snprintf(m, sizeof m, "GRP = %d; this gather is derived for GRP = 1 only",
                 e->grp);
        pl_embed_mv4i_close(e); return hdr_fail(path, m);
    }

    /* Every declared sub-region must actually be inside the file. */
    need = 0;
    for (i = 0; i < e->nports_w; i++) {
        uint64_t end = e->w_sub_offset[i] + e->sub_bytes;
        if (end > need) need = end;
    }
    for (i = 0; i < e->n_scale_sub; i++) {
        uint64_t end = e->s_sub_offset[i] + e->sub_bytes;
        if (end > need) need = end;
    }
    {
        off_t sz = lseek(e->fd, 0, SEEK_END);
        if (sz < 0 || (uint64_t)sz < need) {
            char m[192];
            snprintf(m, sizeof m, "file is %lld bytes but its own offset table "
                     "reaches %llu; the image is truncated",
                     (long long)sz, (unsigned long long)need);
            pl_embed_mv4i_close(e); return hdr_fail(path, m);
        }
    }

    e->wbuf = (unsigned char *)malloc(e->read_bytes);
    e->sbuf = (unsigned char *)malloc(e->read_bytes);
    e->vals = (int32_t *)malloc(sizeof(int32_t) * (size_t)e->K);
    if (!e->wbuf || !e->sbuf || !e->vals) { pl_embed_mv4i_close(e); return -1; }

    snprintf(e->desc, sizeof e->desc,
             "mv4i %s M=%u K=%u ROWS_IF=%u AXI_DW=%u BLOCK=%u nports_w=%u "
             "n_scale_sub=%u nb=%d tiles=%d w_exp=%d recipe=%s read=%zuB x2",
             e->path, e->M, e->K, e->rows_if, e->axi_dw, e->block, e->nports_w,
             e->n_scale_sub, e->nb, e->tiles, e->w_exp,
             recipe == PL_EMBED_RECIPE_WIDE ? "wide" : "d32", e->read_bytes);

    *out = e;
    return 0;
}

void pl_embed_mv4i_close(pl_embed_mv4i_t *e)
{
    if (!e) return;
    if (e->fd >= 0) close(e->fd);
    free(e->wbuf); free(e->sbuf); free(e->vals);
    free(e);
}

int pl_embed_mv4i_n_embd (const pl_embed_mv4i_t *e) { return e ? (int)e->K : 0; }
int pl_embed_mv4i_n_vocab(const pl_embed_mv4i_t *e) { return e ? (int)e->M : 0; }
uint64_t pl_embed_mv4i_bytes_read(const pl_embed_mv4i_t *e) { return e ? e->bytes_read : 0; }
uint64_t pl_embed_mv4i_gathers   (const pl_embed_mv4i_t *e) { return e ? e->gathers : 0; }
const char *pl_embed_mv4i_describe(const pl_embed_mv4i_t *e) { return e ? e->desc : "(none)"; }

/* ------------------------------------------------------------- addressing */

/* The whole derivation, in one place, so the mutants and the trace read the
 * same arithmetic the gather does.  `mut` selects a named defect. */
static void addr_of(const pl_embed_mv4i_t *e, int tok,
                    int *t_o, int *rr_o, int *p_o, int *half_o,
                    int *q_o, int *k_o)
{
    int t  = tok / (int)e->rows_if;
    int rr = tok % (int)e->rows_if;
    int p, half, q, k;

    if (MUT(e, PL_EMBED_MUT_TILE) && t + 1 < e->tiles) t = t + 1;

    p    = rr / e->rows_per_beat;
    half = rr % e->rows_per_beat;
    if (MUT(e, PL_EMBED_MUT_WSUB) && p + 1 < (int)e->nports_w) p = p + 1;
    if (MUT(e, PL_EMBED_MUT_HALF)) half = (e->rows_per_beat - 1) - half;

    q = rr / e->scales_per_beat;
    k = rr % e->scales_per_beat;
    if (MUT(e, PL_EMBED_MUT_SSUB) && q + 1 < (int)e->n_scale_sub) q = q + 1;
    if (MUT(e, PL_EMBED_MUT_SIDX)) k = (k + 1) % e->scales_per_beat;

    if (t_o)    *t_o    = t;
    if (rr_o)   *rr_o   = rr;
    if (p_o)    *p_o    = p;
    if (half_o) *half_o = half;
    if (q_o)    *q_o    = q;
    if (k_o)    *k_o    = k;
}

int pl_embed_mv4i_addr(const pl_embed_mv4i_t *e, int tok,
                       int *tile, int *row_in_tile,
                       int *w_sub, int *half, int *s_sub, int *s_idx,
                       uint64_t *w_off, uint64_t *s_off, uint64_t *read_bytes)
{
    int t, rr, p, h, q, k;
    if (!e || tok < 0 || (uint32_t)tok >= e->M) return -1;
    addr_of(e, tok, &t, &rr, &p, &h, &q, &k);
    if (tile) *tile = t;
    if (row_in_tile) *row_in_tile = rr;
    if (w_sub) *w_sub = p;
    if (half) *half = h;
    if (s_sub) *s_sub = q;
    if (s_idx) *s_idx = k;
    if (w_off) *w_off = e->w_sub_offset[p] + (uint64_t)t * e->nb * e->port_b;
    if (s_off) *s_off = e->s_sub_offset[q] + (uint64_t)t * e->nb * e->port_b;
    if (read_bytes) *read_bytes = (uint64_t)e->read_bytes;
    return 0;
}

/* ---------------------------------------------------------------- the row */

int pl_embed_mv4i_row_int(pl_embed_mv4i_t *e, int tok,
                          int32_t *vals, int n, int32_t *val_exp)
{
    int t, rr, p, half, q, kk, b, j;
    uint64_t woff, soff;
    const int8_t *cb;
    int8_t cbrev[16];

    if (!e || !vals || !val_exp) return -1;
    if (tok < 0 || (uint32_t)tok >= e->M) {
        fprintf(stderr, "pl_embed_mv4i: token %d outside 0 .. %u\n", tok, e->M - 1);
        return -1;
    }
    if (n != (int)e->K) {
        fprintf(stderr, "pl_embed_mv4i: caller wants %d elements, %s has K = %u.\n"
                        "  Refused rather than truncated: a short embedding row is a\n"
                        "  plausible-looking wrong answer.\n", n, e->path, e->K);
        return -1;
    }

    addr_of(e, tok, &t, &rr, &p, &half, &q, &kk);
    woff = e->w_sub_offset[p] + (uint64_t)t * e->nb * e->port_b;
    soff = e->s_sub_offset[q] + (uint64_t)t * e->nb * e->port_b;

    if (MUT(e, PL_EMBED_MUT_BLOCKMAJOR)) {
        /* Beats strided by `tiles` instead of running consecutively: the
         * mutation a reader that swapped the two orderings makes. */
        for (b = 0; b < e->nb; b++) {
            uint64_t o = e->w_sub_offset[p] +
                         (uint64_t)((size_t)b * e->tiles + t) * e->port_b;
            if (pread_all(e->fd, e->wbuf + (size_t)b * e->port_b,
                          (size_t)e->port_b, o) != (ssize_t)e->port_b) {
                fprintf(stderr, "pl_embed_mv4i: short weight read\n"); return -2;
            }
        }
    } else if (pread_all(e->fd, e->wbuf, e->read_bytes, woff) != (ssize_t)e->read_bytes) {
        fprintf(stderr, "pl_embed_mv4i: %s: short weight read at 0x%llX\n",
                e->path, (unsigned long long)woff);
        return -2;
    }
    if (pread_all(e->fd, e->sbuf, e->read_bytes, soff) != (ssize_t)e->read_bytes) {
        fprintf(stderr, "pl_embed_mv4i: %s: short scale read at 0x%llX\n",
                e->path, (unsigned long long)soff);
        return -2;
    }
    e->bytes_read += 2ull * e->read_bytes;
    e->gathers++;

    cb = e->codebook;
    if (MUT(e, PL_EMBED_MUT_CODEBOOK)) {
        for (j = 0; j < 16; j++) cbrev[j] = e->codebook[15 - j];
        cb = cbrev;
    }

    for (b = 0; b < e->nb; b++) {
        const unsigned char *sp = e->sbuf + (size_t)b * e->port_b + 2 * (size_t)kk;
        const unsigned char *wp = e->wbuf + (size_t)b * e->port_b
                                          + (size_t)half * e->row_b;
        int32_t sc = MUT(e, PL_EMBED_MUT_SCALE_BE)
                     ? (int32_t)((uint16_t)(((uint16_t)sp[0] << 8) | sp[1]))
                     : (int32_t)((uint16_t)(sp[0] | ((uint16_t)sp[1] << 8)));
        for (j = 0; j < e->block; j++) {
            int k = b * e->block + j;
            unsigned char byte = wp[j >> 1];
            int idx;
            if (k >= (int)e->K) break;
            if (MUT(e, PL_EMBED_MUT_NIBBLE))
                idx = (j & 1) ? (byte & 0x0F) : (byte >> 4);
            else
                idx = (j & 1) ? (byte >> 4) : (byte & 0x0F);
            {
                int32_t prod = (int32_t)cb[idx] * sc;
                vals[k] = (e->recipe == PL_EMBED_RECIPE_D32)
                          ? floor_shr32(prod, 15) : prod;
            }
        }
    }
    *val_exp = (e->recipe == PL_EMBED_RECIPE_D32) ? e->w_exp : e->w_exp + 15;
    return 0;
}

int pl_embed_mv4i(void *user, int tok, int16_t *mant, int n_embd, int32_t *exp)
{
    pl_embed_mv4i_t *e = (pl_embed_mv4i_t *)user;
    int32_t val_exp = 0;
    uint32_t amax = 0;
    int target = TARGET_MSB, sh, i, trunc = 0;

    if (!e || !mant || !exp) return -1;
    if (pl_embed_mv4i_row_int(e, tok, e->vals, n_embd, &val_exp)) return -1;

    if (MUT(e, PL_EMBED_MUT_TARGET_MSB)) target = TARGET_MSB - 1;
    if (MUT(e, PL_EMBED_MUT_TRUNCATE))   trunc = 1;

    for (i = 0; i < n_embd; i++) {
        int32_t v = e->vals[i];
        uint32_t a = v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v;
        if (a > amax) amax = a;
    }
    if (amax == 0) {
        /* An all-zero row.  The exponent it carries is the row's own, not 0:
         * a caller that scales by 2^-exp must get the same answer either way,
         * and reporting the row's exponent keeps the two decoders comparable. */
        for (i = 0; i < n_embd; i++) mant[i] = 0;
        *exp = MUT(e, PL_EMBED_MUT_EXPSIGN) ? -val_exp : val_exp;
        return 0;
    }
    /* sh is deliberately NOT clamped at 0.  rtl/embed.vhd searches e downward
     * from 30 and accepts a LEFT shift; clamping would leave a row whose amax
     * is 127 sitting in 7 of the 16 available bits. */
    sh = msb_pos_u(amax) - target;
    for (i = 0; i < n_embd; i++)
        mant[i] = sat16_64(round_shift64((int64_t)e->vals[i], sh, trunc));
    *exp = MUT(e, PL_EMBED_MUT_EXPSIGN) ? -(val_exp - sh) : (val_exp - sh);
    return 0;
}
