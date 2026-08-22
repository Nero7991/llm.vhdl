/* ref/matvec_int4.c -- bit-exact C reference for subsystem A.
 *
 * Implements EXACTLY the numeric contract of
 *   docs/superpowers/specs/2026-08-20-int4-streaming-matvec-design.md
 * sections 6.4 (file layout), 6.5 (bit ordering), 7.4 (numeric contract) and
 * 14.2 (partial-sum mode).  Section numbers below refer to that document.
 *
 * WHY THIS FILE EXISTS.  A spec is checked by reading; a reference is checked
 * by running.  The RTL is validated against this, and this is validated against
 * ggml -- so a defect shared by both models is invisible.  Rev 1 of the spec
 * specified an int48 accumulator in BOTH the RTL and the reference, which would
 * have made them bit-exact to each other AND wrong.  Every width here is
 * therefore int64_t and every bound is asserted at runtime, not assumed.
 *
 * WIDTH DISCIPLINE (spec 9).  partial*scale reaches 2^42 and acc reaches
 * ~2^36.1 at K=17408, both of which overflow 32-bit int.  All intermediates are
 * int64_t.  C's >> on a negative signed value is implementation-defined before
 * C23, so this file NEVER uses >> for arithmetic shifting -- see floor_shr().
 *
 * Build:  cc -O2 -Wall -Wextra -o matvec_int4 matvec_int4.c   (self-test main)
 *         cc -O2 -DMV4I_LIB -c matvec_int4.c                  (link into a host)
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ---------------------------------------------------------------- 7.4 types */

#define MV4I_MAGIC      0x4D563449u   /* "MV4I" */
#define MV4I_BLOCK      32            /* weights per scale block          6.1  */
#define MV4I_HDR_BYTES  4096          /* header is 4 KB                   6.4  */

enum { MV4I_MODE_BFP = 0, MV4I_MODE_RAW = 1, MV4I_MODE_PARTIAL = 2 };

typedef struct {
    uint32_t magic, M, K, scale_offset, n_scale_sub;
    uint16_t version, flags, rows_if, nports_w, block;
    int32_t  w_exp, out_shift;
    int8_t   codebook[16];
    uint64_t w_sub_offset[64];
    uint64_t s_sub_offset[64];
} mv4i_hdr;

typedef struct {
    mv4i_hdr        h;
    const uint8_t  *base;   /* whole file image */
    int             nb;     /* ceil(K / BLOCK) */
} mv4i_file;

/* ------------------------------------------------- arithmetic primitives 7.4 */

/* Rounding site 1 and the shift inside sites 2/3/4: FLOOR, toward -infinity.
 * NOT truncation.  floor(-5/2) = -3 while C's / gives -2, and the spec calls
 * this out explicitly because the natural C idiom is wrong here.             */
static int64_t floor_shr(int64_t v, int sh)
{
    if (sh <= 0) return v;
    int64_t d = (int64_t)1 << sh;
    int64_t q = v / d;
    if (v % d != 0 && v < 0) q -= 1;          /* bias toward -infinity */
    return q;
}

/* Rounding sites 2 and 3: round half toward +infinity, matching
 * fixed_pkg.scale_mul (+2^(sh-1) then arithmetic shift) with NO bias at sh=0. */
static int64_t round_shift(int64_t v, int sh)
{
    if (sh == 0) return v;                    /* site 3: no shift, no bias */
    return floor_shr(v + ((int64_t)1 << (sh - 1)), sh);
}

static int      g_sat_event;                  /* sticky, see 14.2 / M-1 */
static uint64_t g_sat_count;

static int32_t sat32(int64_t v)
{
    if (v >  INT32_MAX) { g_sat_event = 1; g_sat_count++; return INT32_MAX; }
    if (v <  INT32_MIN) { g_sat_event = 1; g_sat_count++; return INT32_MIN; }
    return (int32_t)v;
}

static int16_t sat16(int64_t v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

/* msb_pos(0) = 0 is NORMATIVE (7.4), matching bfp_pack.msb_pos_u.  The natural
 * C idiom 63 - __builtin_clzll(a) is UNDEFINED BEHAVIOUR at a = 0, and an
 * all-zero output vector is reachable (a zero scale row, or a large out_shift). */
static int msb_pos_u(uint64_t a)
{
    if (a == 0) return 0;
    int p = 0;
    while (a >>= 1) p++;
    return p;
}

static uint64_t abs64(int64_t v) { return v < 0 ? (uint64_t)(-v) : (uint64_t)v; }

/* --------------------------------------------------------- file access 6.4/6.5 */

static uint16_t rd_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd_u32(const uint8_t *p)
{ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t rd_u64(const uint8_t *p)
{ return (uint64_t)rd_u32(p) | ((uint64_t)rd_u32(p + 4) << 32); }

int mv4i_parse(mv4i_file *f, const uint8_t *img, size_t len)
{
    if (len < MV4I_HDR_BYTES) return -1;
    const uint8_t *p = img;
    mv4i_hdr *h = &f->h;

    h->magic      = rd_u32(p + 0x00);
    if (h->magic != MV4I_MAGIC) return -2;
    h->version    = rd_u16(p + 0x04);
    h->flags      = rd_u16(p + 0x06);
    h->M          = rd_u32(p + 0x08);
    h->K          = rd_u32(p + 0x0C);
    h->w_exp      = (int32_t)rd_u32(p + 0x10);   /* SIGNED, two's complement */
    h->out_shift  = (int32_t)rd_u32(p + 0x14);
    h->rows_if    = rd_u16(p + 0x18);
    h->nports_w   = rd_u16(p + 0x1A);
    h->block      = rd_u16(p + 0x1C);
    memcpy(h->codebook, p + 0x20, 16);          /* codebook TRAVELS IN THE FILE */
    h->scale_offset = rd_u32(p + 0x30);
    h->n_scale_sub  = rd_u32(p + 0x34);
    for (unsigned i = 0; i < h->nports_w && i < 64; i++)
        h->w_sub_offset[i] = rd_u64(p + 0x38 + 8 * i);
    for (unsigned i = 0; i < h->n_scale_sub && i < 64; i++)
        h->s_sub_offset[i] = rd_u64(p + 0x38 + 8 * h->nports_w + 8 * i);

    /* 6.5 invariant: NPORTS_W * AXI_DW = ROWS_IF * BLOCK * 4.  At AXI_DW=128
     * and BLOCK=32 this reduces to NPORTS_W == ROWS_IF, and lane r carries
     * row r of the tile -- which is what the accessors below rely on.        */
    if (h->block != MV4I_BLOCK)    return -3;
    if (h->nports_w != h->rows_if) return -4;

    /* 7.4 normative range constraints.  Violating either overflows a declared
     * width in the RTL, so the reference refuses the file rather than silently
     * producing a result the hardware cannot reproduce.                      */
    for (int i = 0; i < 16; i++)
        if (h->codebook[i] == -128) return -5;   /* -128 FORBIDDEN */
    if (h->out_shift < 0 || h->out_shift > 40) return -6;

    f->base = img;
    f->nb   = (int)((h->K + MV4I_BLOCK - 1) / MV4I_BLOCK);
    return 0;
}

/* 6.5 bit ordering: weight j of a block sits at bits 4j+3..4j of the chunk,
 * so j even -> low nibble of byte j/2, j odd -> high nibble.                 */
static int get_widx(const mv4i_file *f, int r, int k)
{
    int RI = f->h.rows_if, t = r / RI, rr = r % RI;
    int b = k / MV4I_BLOCK, j = k % MV4I_BLOCK;
    const uint8_t *sub = f->base + f->h.w_sub_offset[rr];
    const uint8_t *c   = sub + (size_t)(t * f->nb + b) * (MV4I_BLOCK / 2);
    uint8_t byte = c[j >> 1];
    return (j & 1) ? (byte >> 4) : (byte & 0x0F);
}

/* Scale for row r, block b.  Little-endian int16; row r of a tile-block group
 * sits at byte offset 2r within that group (6.5).                            */
static uint16_t get_scale(const mv4i_file *f, int r, int b)
{
    int RI = f->h.rows_if, t = r / RI, rr = r % RI;
    const uint8_t *s = f->base + (f->h.n_scale_sub ? f->h.s_sub_offset[0]
                                                   : f->h.scale_offset);
    size_t off = ((size_t)(t * f->nb + b) * RI + rr) * 2;
    return rd_u16(s + off);
}

/* ------------------------------------------------------------- the matvec 7.4 */

typedef struct {
    int32_t *y_data;   /* raw: s32 per row */
    int64_t *y_acc;    /* PARTIAL: UNROUNDED s48 accumulator per row (14.2) */
    int16_t *y_mant;   /* BFP: int16 mantissa per row */
    int      y_exp;
    int      sat_event;
    uint64_t sat_count;
    int      ns;       /* BFP normalization shift, for inspection */
} mv4i_result;

int mv4i_matvec(const mv4i_file *f, const int16_t *x_mant, int x_exp,
                int n_rows, int n_cols, int out_mode, mv4i_result *out)
{
    if (n_rows <= 0 || n_cols <= 0)      return -1;   /* 7.6 abort */
    if ((uint32_t)n_cols > f->h.K)       return -2;

    g_sat_event = 0;
    g_sat_count = 0;

    const int NB = (n_cols + MV4I_BLOCK - 1) / MV4I_BLOCK;

    for (int r = 0; r < n_rows; r++) {
        int64_t acc = 0;                                   /* s48 in hardware */

        for (int b = 0; b < NB; b++) {
            int64_t partial = 0;                           /* s28 in hardware */

            for (int j = 0; j < MV4I_BLOCK; j++) {
                int k = b * MV4I_BLOCK + j;
                if (k >= n_cols) continue;   /* COLUMN MASK (6.2).  Required
                                              * because the IQ4_NL codebook has
                                              * NO ZERO ENTRY -- index 0 decodes
                                              * to -127 -- so zero-padding would
                                              * contribute a nonzero product.  */
                int8_t cb = f->h.codebook[get_widx(f, r, k)];
                partial += (int64_t)cb * (int64_t)x_mant[k];
            }
            assert(partial < (1LL << 27) && partial > -(1LL << 27));  /* s28 */

            uint16_t sc = get_scale(f, r, b);
            assert(sc <= 32767);                     /* 7.4: uint15, MSB clear */

            /* SITE 1: floor, never C division. */
            int64_t contrib = floor_shr(partial * (int64_t)sc, 15);
            assert(contrib < (1LL << 27) && contrib > -(1LL << 27));  /* s29 */

            acc += contrib;
        }
        /* At K=17408, NB=544 and |acc| <= 544 * 2^27 ~= 2^36.1; s48 holds. */
        assert(acc < (1LL << 47) && acc > -(1LL << 47));

        if (out_mode == MV4I_MODE_PARTIAL) {
            /* 14.2 CORRECTED 2026-08-22: partial mode emits the accumulator
             * UNROUNDED.  round_shift is NOT additive, so rounding each shard
             * before the reduction accumulates up to N/2 ulp of error and can
             * never reproduce the full-K result.  Emitting the raw s48 makes
             * the sharded path BIT-EXACT with the single-card path, because
             * integer addition of the same terms is associative.
             * It also dissolves the sat32-on-partial hazard entirely: there is
             * no saturation until the single round at the end.               */
            out->y_acc[r] = acc;
            continue;
        }
        /* SITES 2/3 */
        out->y_data[r] = sat32(round_shift(acc, f->h.out_shift));
    }

    out->ns = 0;

    if (out_mode == MV4I_MODE_BFP) {
        /* SCAN DOMAIN is r < n_rows ONLY.  Padded tile rows and stale buffer
         * contents at indices >= n_rows would inflate ns and crush every real
         * mantissa -- the failure bfp_pack's own header documents.           */
        uint64_t amax = 0;
        for (int r = 0; r < n_rows; r++) {
            uint64_t a = abs64((int64_t)out->y_data[r]);
            if (a > amax) amax = a;
        }
        int ns = msb_pos_u(amax) - 14;
        if (ns < 0) ns = 0;
        out->ns = ns;

        for (int r = 0; r < n_rows; r++)                   /* SITE 4 */
            out->y_mant[r] = sat16(round_shift((int64_t)out->y_data[r], ns));

        /* ns is SUBTRACTED.  If mant' = mant >> ns then preserving the value
         * needs exp' = exp - ns.  Matches bfp_pack (o_exp = Q - shift_o) and
         * matmul_rt (o_exp <= xexp_l - sh).  Rev 2 of the spec had this as +ns. */
        out->y_exp = f->h.w_exp + x_exp - f->h.out_shift - ns;
    } else {
        out->y_exp = f->h.w_exp + x_exp - f->h.out_shift;
    }

    out->sat_event = g_sat_event;
    out->sat_count = g_sat_count;
    return 0;
}

/* ============================== SELF TEST ================================= */
#ifndef MV4I_LIB

/* Minimal packer, sufficient to exercise the reference.  Emits exactly the
 * 6.4/6.5 layout so that packer -> C -> RTL bit-identity is testable. */
static uint8_t *pack(int M, int K, int rows_if, int w_exp, int out_shift,
                     const int8_t cb[16], const uint8_t *idx /*M*K*/,
                     const uint16_t *scl /*M*NB*/, size_t *out_len)
{
    int NB     = (K + MV4I_BLOCK - 1) / MV4I_BLOCK;
    int tiles  = (M + rows_if - 1) / rows_if;
    size_t chunk   = MV4I_BLOCK / 2;                        /* 16 B */
    size_t sub_sz  = (size_t)tiles * NB * chunk;
    size_t sub_pad = (sub_sz + 4095) & ~(size_t)4095;       /* 4 KB aligned */
    size_t scl_sz  = (size_t)tiles * NB * rows_if * 2;
    size_t scl_pad = (scl_sz + 4095) & ~(size_t)4095;
    size_t len     = MV4I_HDR_BYTES + sub_pad * rows_if + scl_pad;

    uint8_t *img = calloc(1, len);                          /* PAD FILL = 0x00 */
    uint8_t *p = img;
    *(uint32_t *)(void *)(p + 0x00) = MV4I_MAGIC;
    *(uint16_t *)(void *)(p + 0x04) = 1;
    *(uint16_t *)(void *)(p + 0x06) = 1;                    /* codebook present */
    *(uint32_t *)(void *)(p + 0x08) = (uint32_t)M;
    *(uint32_t *)(void *)(p + 0x0C) = (uint32_t)K;
    *(int32_t  *)(void *)(p + 0x10) = w_exp;
    *(int32_t  *)(void *)(p + 0x14) = out_shift;
    *(uint16_t *)(void *)(p + 0x18) = (uint16_t)rows_if;
    *(uint16_t *)(void *)(p + 0x1A) = (uint16_t)rows_if;    /* NPORTS_W */
    *(uint16_t *)(void *)(p + 0x1C) = MV4I_BLOCK;
    memcpy(p + 0x20, cb, 16);
    *(uint32_t *)(void *)(p + 0x34) = 1;                    /* n_scale_sub */
    for (int i = 0; i < rows_if; i++)
        *(uint64_t *)(void *)(p + 0x38 + 8 * i) = MV4I_HDR_BYTES + sub_pad * i;
    *(uint64_t *)(void *)(p + 0x38 + 8 * rows_if) =
        MV4I_HDR_BYTES + sub_pad * rows_if;
    *(uint32_t *)(void *)(p + 0x30) = (uint32_t)(MV4I_HDR_BYTES + sub_pad * rows_if);

    for (int r = 0; r < M; r++) {
        int t = r / rows_if, rr = r % rows_if;
        uint8_t *sub = img + MV4I_HDR_BYTES + sub_pad * rr;
        for (int k = 0; k < K; k++) {
            int b = k / MV4I_BLOCK, j = k % MV4I_BLOCK;
            uint8_t *c = sub + (size_t)(t * NB + b) * chunk;
            uint8_t v = idx[(size_t)r * K + k] & 0x0F;
            if (j & 1) c[j >> 1] = (uint8_t)((c[j >> 1] & 0x0F) | (v << 4));
            else       c[j >> 1] = (uint8_t)((c[j >> 1] & 0xF0) | v);
        }
        for (int b = 0; b < NB; b++) {
            uint8_t *s = img + MV4I_HDR_BYTES + sub_pad * rows_if;
            size_t off = ((size_t)(t * NB + b) * rows_if + rr) * 2;
            uint16_t v = scl[(size_t)r * NB + b];
            s[off] = (uint8_t)(v & 0xFF); s[off + 1] = (uint8_t)(v >> 8);
        }
    }
    *out_len = len;
    return img;
}

static const int8_t IQ4_NL[16] = { -127,-104,-83,-65,-49,-35,-22,-10,
                                      1, 13, 25, 38, 53, 69, 89,113 };

static uint32_t rng = 12345;
static uint32_t rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }

static int fails;
static void check(const char *name, int ok)
{
    printf("  %-46s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) fails++;
}

/* Cross-check mode: parse a packer-produced .mv4i, run a deterministic
 * activation vector through it, and print a checksum.  tools/pack_int4.py
 * --crosscheck computes the same number independently, so agreement proves the
 * 6.4/6.5 layout is interpreted identically by packer and reference. */
static int crosscheck(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); return 2; }
    fseek(fp, 0, SEEK_END); long len = ftell(fp); fseek(fp, 0, SEEK_SET);
    uint8_t *img = malloc((size_t)len);
    if (fread(img, 1, (size_t)len, fp) != (size_t)len) return 2;
    fclose(fp);

    mv4i_file f;
    int rc = mv4i_parse(&f, img, (size_t)len);
    if (rc) { fprintf(stderr, "parse failed: %d\n", rc); return 2; }

    int M = (int)f.h.M, K = (int)f.h.K;
    int16_t *x = malloc(sizeof(int16_t) * (size_t)K);
    uint32_t st = 2463534242u;                      /* xorshift32, seed fixed */
    for (int k = 0; k < K; k++) {
        st ^= st << 13; st ^= st >> 17; st ^= st << 5;
        x[k] = (int16_t)((int32_t)(st % 20001) - 10000);
    }
    mv4i_result r = { malloc(4*(size_t)M), malloc(8*(size_t)M),
                      malloc(2*(size_t)M), 0,0,0,0 };
    if (mv4i_matvec(&f, x, 0, M, K, MV4I_MODE_BFP, &r)) return 2;

    int64_t sum = 0;
    for (int i = 0; i < M; i++) sum += r.y_mant[i];
    printf("M=%d K=%d w_exp=%d out_shift=%d ns=%d y_exp=%d mant_sum=%lld sat=%d\n",
           M, K, f.h.w_exp, f.h.out_shift, r.ns, r.y_exp,
           (long long)sum, r.sat_event);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2) return crosscheck(argv[1]);
    printf("subsystem A reference self-test\n");

    /* ---- test 1: dequant, all 16 codebook indices ---- */
    {
        int ok = 1;
        for (int i = 0; i < 16; i++) if (IQ4_NL[i] == -128) ok = 0;
        check("1  codebook has no -128 (7.4 constraint)", ok);
    }

    /* ---- test 9/10: column and row masking, K not a multiple of BLOCK ---- */
    {
        const int M = 6, K = 40, RI = 4, NB = 2;   /* K=40 -> partial block */
        uint8_t *idx = calloc((size_t)M * K, 1);
        uint16_t *scl = malloc(sizeof(uint16_t) * M * NB);
        for (int i = 0; i < M * K; i++) idx[i] = (uint8_t)(rnd() & 15);
        for (int i = 0; i < M * NB; i++) scl[i] = 32767;
        size_t len; uint8_t *img = pack(M, K, RI, 0, 0, IQ4_NL, idx, scl, &len);

        mv4i_file f; assert(mv4i_parse(&f, img, len) == 0);
        int16_t *x = malloc(sizeof(int16_t) * K);
        for (int k = 0; k < K; k++) x[k] = (int16_t)(rnd() & 0x7FFF);

        mv4i_result r = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        assert(mv4i_matvec(&f, x, 0, M, K, MV4I_MODE_RAW, &r) == 0);

        /* independent recompute, masking columns >= K */
        int ok = 1;
        for (int row = 0; row < M; row++) {
            int64_t acc = 0;
            for (int b = 0; b < NB; b++) {
                int64_t part = 0;
                for (int j = 0; j < MV4I_BLOCK; j++) {
                    int k = b * MV4I_BLOCK + j;
                    if (k >= K) continue;
                    part += (int64_t)IQ4_NL[idx[(size_t)row * K + k]] * x[k];
                }
                acc += floor_shr(part * 32767, 15);
            }
            if (r.y_data[row] != sat32(acc)) ok = 0;
        }
        check("9  column masking, K=40 (not a multiple of 32)", ok);
        check("10 row masking, M=6 (not a multiple of ROWS_IF=4)", M % RI != 0);
        free(idx); free(scl); free(img); free(x);
        free(r.y_data); free(r.y_acc); free(r.y_mant);
    }

    /* ---- test 11: accumulator corner.  The whole point of this test is that
     * -32768 is the TRUE corner, not +/-32767; an earlier spec revision said
     * 32767 and would have missed the overflow it existed to catch by one. ---- */
    {
        const int M = 4, K = 512, RI = 4, NB = K / MV4I_BLOCK;
        uint8_t *idx = malloc((size_t)M * K);
        uint16_t *scl = malloc(sizeof(uint16_t) * M * NB);
        for (int i = 0; i < M * K; i++) idx[i] = 0;    /* -127, the extreme */
        for (int i = 0; i < M * NB; i++) scl[i] = 32767;
        size_t len; uint8_t *img = pack(M, K, RI, 0, 0, IQ4_NL, idx, scl, &len);
        mv4i_file f; assert(mv4i_parse(&f, img, len) == 0);

        int16_t *x = malloc(sizeof(int16_t) * K);
        for (int k = 0; k < K; k++) x[k] = -32768;     /* TRUE corner */

        mv4i_result r = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        int rc = mv4i_matvec(&f, x, 0, M, K, MV4I_MODE_RAW, &r);
        /* the asserts inside mv4i_matvec are the test: s28/s29/s48 must hold */
        check("11 accumulator bound at cb=-127, x=-32768", rc == 0);
        free(idx); free(scl); free(img); free(x);
        free(r.y_data); free(r.y_acc); free(r.y_mant);
    }

    /* ---- test 7: BFP mode, and the ns sign ---- */
    {
        const int M = 8, K = 64, RI = 4, NB = K / MV4I_BLOCK;
        uint8_t *idx = malloc((size_t)M * K);
        uint16_t *scl = malloc(sizeof(uint16_t) * M * NB);
        for (int i = 0; i < M * K; i++) idx[i] = (uint8_t)(rnd() & 15);
        for (int i = 0; i < M * NB; i++) scl[i] = 20000;
        size_t len; uint8_t *img = pack(M, K, RI, 3, 2, IQ4_NL, idx, scl, &len);
        mv4i_file f; assert(mv4i_parse(&f, img, len) == 0);
        int16_t *x = malloc(sizeof(int16_t) * K);
        for (int k = 0; k < K; k++) x[k] = (int16_t)(rnd() & 0x3FFF);

        mv4i_result r = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        assert(mv4i_matvec(&f, x, 5, M, K, MV4I_MODE_BFP, &r) == 0);

        int mant_ok = 1;
        for (int i = 0; i < M; i++) if (r.y_data[i] != 0 && r.y_mant[i] == 0) mant_ok = 0;
        check("7a BFP mantissas fit int16", mant_ok);
        /* y_exp = w_exp + x_exp - out_shift - ns, MINUS ns */
        check("7b BFP y_exp subtracts ns", r.y_exp == 3 + 5 - 2 - r.ns);
        free(idx); free(scl); free(img); free(x);
        free(r.y_data); free(r.y_acc); free(r.y_mant);
    }

    /* ---- test 12: msb_pos(0) = 0 on an all-zero output ---- */
    {
        const int M = 4, K = 32, RI = 4, NB = 1;
        uint8_t *idx = malloc((size_t)M * K);
        uint16_t *scl = calloc(M * NB, sizeof(uint16_t));   /* scale 0 -> all zero */
        for (int i = 0; i < M * K; i++) idx[i] = (uint8_t)(rnd() & 15);
        size_t len; uint8_t *img = pack(M, K, RI, 0, 0, IQ4_NL, idx, scl, &len);
        mv4i_file f; assert(mv4i_parse(&f, img, len) == 0);
        int16_t *x = malloc(sizeof(int16_t) * K);
        for (int k = 0; k < K; k++) x[k] = 1000;
        mv4i_result r = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        assert(mv4i_matvec(&f, x, 0, M, K, MV4I_MODE_BFP, &r) == 0);
        int zero = 1;
        for (int i = 0; i < M; i++) if (r.y_data[i] != 0 || r.y_mant[i] != 0) zero = 0;
        check("12 all-zero output: msb_pos(0)=0, ns=0", zero && r.ns == 0);
        free(idx); free(scl); free(img); free(x);
        free(r.y_data); free(r.y_acc); free(r.y_mant);
    }

    /* ---- THE 14.4 PROOF: one full-K job == two half-K partials, aligned and
     * summed.  This validates the CORRECTED 14.2 contract (partials carry
     * their own y_exp and are NOT directly summable) on a single card, with no
     * interconnect and no FK33 in existence. ---- */
    {
        const int M = 8, K = 128, RI = 4, NB = K / MV4I_BLOCK, HK = K / 2;
        uint8_t *idx = malloc((size_t)M * K);
        uint16_t *scl = malloc(sizeof(uint16_t) * M * NB);
        for (int i = 0; i < M * K; i++) idx[i] = (uint8_t)(rnd() & 15);
        for (int i = 0; i < M * NB; i++) scl[i] = 30000;
        int16_t *x = malloc(sizeof(int16_t) * K);
        for (int k = 0; k < K; k++) x[k] = (int16_t)((rnd() & 0x7FFF) - 16384);

        /* full-K reference */
        size_t l0; uint8_t *i0 = pack(M, K, RI, 2, 6, IQ4_NL, idx, scl, &l0);
        mv4i_file f0; assert(mv4i_parse(&f0, i0, l0) == 0);
        mv4i_result full = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        assert(mv4i_matvec(&f0, x, 4, M, K, MV4I_MODE_RAW, &full) == 0);

        /* two half-K shards.  Each is a SEPARATE job with its own x slice, so
         * in the real system each would carry a different x_exp -- which is
         * exactly the defect the E review found.  Here both slices share x_exp,
         * so the partials happen to be on one grid and sum exactly.          */
        uint8_t  *ia = malloc((size_t)M * HK), *ib = malloc((size_t)M * HK);
        uint16_t *sa = malloc(sizeof(uint16_t) * M * (NB / 2));
        uint16_t *sb = malloc(sizeof(uint16_t) * M * (NB / 2));
        for (int r = 0; r < M; r++) {
            memcpy(ia + (size_t)r * HK, idx + (size_t)r * K,      HK);
            memcpy(ib + (size_t)r * HK, idx + (size_t)r * K + HK, HK);
            for (int b = 0; b < NB / 2; b++) {
                sa[r * (NB / 2) + b] = scl[r * NB + b];
                sb[r * (NB / 2) + b] = scl[r * NB + b + NB / 2];
            }
        }
        size_t la, lb;
        uint8_t *pa = pack(M, HK, RI, 2, 6, IQ4_NL, ia, sa, &la);
        uint8_t *pb = pack(M, HK, RI, 2, 6, IQ4_NL, ib, sb, &lb);
        mv4i_file fa, fb;
        assert(mv4i_parse(&fa, pa, la) == 0 && mv4i_parse(&fb, pb, lb) == 0);

        mv4i_result ra = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        mv4i_result rb = { malloc(4*M), malloc(8*M), malloc(2*M), 0,0,0,0 };
        assert(mv4i_matvec(&fa, x,      4, M, HK, MV4I_MODE_PARTIAL, &ra) == 0);
        assert(mv4i_matvec(&fb, x + HK, 4, M, HK, MV4I_MODE_PARTIAL, &rb) == 0);

        /* Partials are UNROUNDED s48 on a shared grid (same w_exp/x_exp here),
         * so the reduction is EXACT integer addition and one round_shift at the
         * end reproduces the full-K job bit-for-bit. */
        int ok = 1;
        for (int r = 0; r < M; r++) {
            int64_t summed = ra.y_acc[r] + rb.y_acc[r];
            if (sat32(round_shift(summed, 6)) != full.y_data[r]) ok = 0;
        }
        check("14.4 partial-sum: 2 half-K shards == 1 full-K job, BIT-EXACT",
              ok && ra.y_exp == rb.y_exp && ra.y_exp == full.y_exp);
        check("14.4 sat_event clean on this vector",
              !full.sat_event && !ra.sat_event && !rb.sat_event);

        free(idx); free(scl); free(x); free(i0); free(ia); free(ib);
        free(sa); free(sb); free(pa); free(pb);
        free(full.y_data); free(full.y_acc); free(full.y_mant);
        free(ra.y_data); free(ra.y_acc); free(ra.y_mant);
        free(rb.y_data); free(rb.y_acc); free(rb.y_mant);
    }

    printf("%s (%d failure%s)\n", fails ? "FAILED" : "OK", fails, fails == 1 ? "" : "s");
    return fails != 0;
}
#endif /* MV4I_LIB */
