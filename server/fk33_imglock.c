/* server/fk33_imglock.c -- see fk33_imglock.h.  Nothing here touches the card.
 *
 * Compiled into the host as part of pl_backend, and compiled AGAIN, standing
 * alone, by `hw/fk33/host/fk33_imgfp.py selfcheck` with -DFK33_IMGLOCK_MAIN,
 * which packs a record in Python and makes this file read it.  That test is
 * the only thing that makes the two layouts comparable; a mirror is not
 * evidence.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>

#include "fk33_imglock.h"

/* The byte offsets.  Mirrored in hw/fk33/host/fk33_imgfp.py. */
#define OFF_MAGIC        0x000u
#define OFF_VERSION      0x008u
#define OFF_BYTES        0x00Cu
#define OFF_FP           0x010u
#define OFF_REGION       0x020u      /* 11 * 8 = 88 B, ends 0x078 */
#define OFF_WHEN         0x078u
#define OFF_OBJS_LOADED  0x080u
#define OFF_OBJS_TOTAL   0x084u
#define OFF_BYTES_LOADED 0x088u
#define OFF_PATH         0x090u      /* 240 B, NUL padded, ends 0x180 */
#define OFF_FNV          0x1F0u
#define OFF_TAIL         0x1F8u

static const unsigned char MAGIC[8] = { 'F','K','3','3','I','M','G',0x01 };
static const unsigned char TAIL[8]  = { 0x01,'G','M','I','3','3','K','F' };

uint64_t fk33_imglock_fnv1a64(const unsigned char *p, size_t len)
{
    uint64_t h = 0xCBF29CE484222325ull;
    size_t i;
    for (i = 0; i < len; i++) {
        h ^= (uint64_t)p[i];
        h *= 0x100000001B3ull;
    }
    return h;
}

static uint64_t rd64(const unsigned char *p)
{
    uint64_t v = 0;
    int i;
    for (i = 7; i >= 0; i--) v = (v << 8) | p[i];   /* little-endian */
    return v;
}

static uint32_t rd32(const unsigned char *p)
{
    uint32_t v = 0;
    int i;
    for (i = 3; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

uint64_t fk33_imglock_addr(const fk33_manifest *m)
{
    if (!m || m->desc_arena_bytes < FK33_IMGLOCK_BYTES || !m->desc_arena_base)
        return 0;
    return m->desc_arena_base + m->desc_arena_bytes - FK33_IMGLOCK_BYTES;
}

int fk33_imglock_parse(const unsigned char *buf, size_t len,
                       fk33_imglock_rec *r)
{
    uint64_t want, got;
    size_t i;
    int allzero = 1;

    if (!buf || !r || len != FK33_IMGLOCK_BYTES) return -2;
    for (i = 0; i < len; i++) if (buf[i]) { allzero = 0; break; }
    if (allzero) return -1;
    if (memcmp(buf + OFF_MAGIC, MAGIC, 8) != 0) return -2;
    if (rd32(buf + OFF_VERSION) != FK33_IMGLOCK_VERSION) return -3;
    if (rd32(buf + OFF_BYTES) != FK33_IMGLOCK_BYTES) return -4;
    if (memcmp(buf + OFF_TAIL, TAIL, 8) != 0) return -4;
    want = rd64(buf + OFF_FNV);
    got  = fk33_imglock_fnv1a64(buf, OFF_FNV);
    if (want != got) return -4;

    memset(r, 0, sizeof *r);
    r->version = rd32(buf + OFF_VERSION);
    memcpy(r->fp, buf + OFF_FP, 16);
    r->size               = rd64(buf + OFF_REGION + 0 * 8);
    r->weights_end        = rd64(buf + OFF_REGION + 1 * 8);
    r->gdn_state_base     = rd64(buf + OFF_REGION + 2 * 8);
    r->gdn_state_bytes    = rd64(buf + OFF_REGION + 3 * 8);
    r->kv_base            = rd64(buf + OFF_REGION + 4 * 8);
    r->kv_bytes_per_token = rd64(buf + OFF_REGION + 5 * 8);
    r->gdn_const_base     = rd64(buf + OFF_REGION + 6 * 8);
    r->gdn_const_bytes    = rd64(buf + OFF_REGION + 7 * 8);
    r->desc_arena_base    = rd64(buf + OFF_REGION + 8 * 8);
    r->desc_arena_bytes   = rd64(buf + OFF_REGION + 9 * 8);
    r->host_max_chunk     = rd64(buf + OFF_REGION + 10 * 8);
    r->when         = rd64(buf + OFF_WHEN);
    r->objs_loaded  = rd32(buf + OFF_OBJS_LOADED);
    r->objs_total   = rd32(buf + OFF_OBJS_TOTAL);
    r->bytes_loaded = rd64(buf + OFF_BYTES_LOADED);
    memcpy(r->manifest_path, buf + OFF_PATH, FK33_IMGLOCK_PATH_MAX - 1);
    r->manifest_path[FK33_IMGLOCK_PATH_MAX - 1] = 0;
    return 0;
}

static void wr64(unsigned char *p, uint64_t v)
{
    int i;
    for (i = 0; i < 8; i++) { p[i] = (unsigned char)(v & 0xFF); v >>= 8; }
}

static void wr32(unsigned char *p, uint32_t v)
{
    int i;
    for (i = 0; i < 4; i++) { p[i] = (unsigned char)(v & 0xFF); v >>= 8; }
}

int fk33_imglock_pack(const fk33_imglock_rec *r, unsigned char *buf,
                      size_t len)
{
    size_t n;
    if (!r || !buf || len != FK33_IMGLOCK_BYTES) return -1;
    memset(buf, 0, len);
    memcpy(buf + OFF_MAGIC, MAGIC, 8);
    wr32(buf + OFF_VERSION, FK33_IMGLOCK_VERSION);
    wr32(buf + OFF_BYTES, FK33_IMGLOCK_BYTES);
    memcpy(buf + OFF_FP, r->fp, 16);
    wr64(buf + OFF_REGION +  0 * 8, r->size);
    wr64(buf + OFF_REGION +  1 * 8, r->weights_end);
    wr64(buf + OFF_REGION +  2 * 8, r->gdn_state_base);
    wr64(buf + OFF_REGION +  3 * 8, r->gdn_state_bytes);
    wr64(buf + OFF_REGION +  4 * 8, r->kv_base);
    wr64(buf + OFF_REGION +  5 * 8, r->kv_bytes_per_token);
    wr64(buf + OFF_REGION +  6 * 8, r->gdn_const_base);
    wr64(buf + OFF_REGION +  7 * 8, r->gdn_const_bytes);
    wr64(buf + OFF_REGION +  8 * 8, r->desc_arena_base);
    wr64(buf + OFF_REGION +  9 * 8, r->desc_arena_bytes);
    wr64(buf + OFF_REGION + 10 * 8, r->host_max_chunk);
    wr64(buf + OFF_WHEN, r->when);
    wr32(buf + OFF_OBJS_LOADED, r->objs_loaded);
    wr32(buf + OFF_OBJS_TOTAL, r->objs_total);
    wr64(buf + OFF_BYTES_LOADED, r->bytes_loaded);
    n = strlen(r->manifest_path);
    if (n > FK33_IMGLOCK_PATH_MAX - 1) n = FK33_IMGLOCK_PATH_MAX - 1;
    memcpy(buf + OFF_PATH, r->manifest_path, n);
    wr64(buf + OFF_FNV, fk33_imglock_fnv1a64(buf, OFF_FNV));
    memcpy(buf + OFF_TAIL, TAIL, 8);
    return 0;
}

void fk33_imglock_from_manifest(const fk33_manifest *m, fk33_imglock_rec *r)
{
    if (!m || !r) return;
    memset(r, 0, sizeof *r);
    r->version            = FK33_IMGLOCK_VERSION;
    r->size               = m->size;
    r->weights_end        = m->weights_end;
    r->gdn_state_base     = m->gdn_state_base;
    r->gdn_state_bytes    = m->gdn_state_bytes;
    r->kv_base            = m->kv_base;
    r->kv_bytes_per_token = m->kv_bytes_per_token;
    r->gdn_const_base     = m->gdn_const_base;
    r->gdn_const_bytes    = m->gdn_const_bytes;
    r->desc_arena_base    = m->desc_arena_base;
    r->desc_arena_bytes   = m->desc_arena_bytes;
    r->host_max_chunk     = m->host_max_chunk;
}

const char *fk33_imglock_why(int rc)
{
    switch (rc) {
    case 0:  return "a whole record";
    case -1: return "the 512 bytes are all zero: NO IMAGE has been recorded "
                    "as resident";
    case -2: return "not a record at all (wrong magic, or the wrong address)";
    case -3: return "a record version this host does not speak";
    case -4: return "a TORN or PARTIAL write: the checksum, the length or the "
                    "tail magic disagrees";
    default: return "unknown";
    }
}

int fk33_imglock_compare(const fk33_imglock_rec *r, const fk33_manifest *m,
                         char *why, size_t nwhy)
{
    struct { const char *name; uint64_t res, req; } f[11];
    int n = 0, i;
    size_t used = 0;

    if (!r || !m) return -1;
    f[0].name = "hbm.size";               f[0].res = r->size;               f[0].req = m->size;
    f[1].name = "hbm.weights_end";        f[1].res = r->weights_end;        f[1].req = m->weights_end;
    f[2].name = "hbm.gdn_state_base";     f[2].res = r->gdn_state_base;     f[2].req = m->gdn_state_base;
    f[3].name = "hbm.gdn_state_bytes";    f[3].res = r->gdn_state_bytes;    f[3].req = m->gdn_state_bytes;
    f[4].name = "hbm.kv_base";            f[4].res = r->kv_base;            f[4].req = m->kv_base;
    f[5].name = "hbm.kv_bytes_per_token"; f[5].res = r->kv_bytes_per_token; f[5].req = m->kv_bytes_per_token;
    f[6].name = "hbm.gdn_const_base";     f[6].res = r->gdn_const_base;     f[6].req = m->gdn_const_base;
    f[7].name = "hbm.gdn_const_bytes";    f[7].res = r->gdn_const_bytes;    f[7].req = m->gdn_const_bytes;
    f[8].name = "hbm.desc_arena_base";    f[8].res = r->desc_arena_base;    f[8].req = m->desc_arena_base;
    f[9].name = "hbm.desc_arena_bytes";   f[9].res = r->desc_arena_bytes;   f[9].req = m->desc_arena_bytes;
    f[10].name = "hbm.host_max_chunk";    f[10].res = r->host_max_chunk;    f[10].req = m->host_max_chunk;

    if (why && nwhy) why[0] = 0;
    for (i = 0; i < 11; i++) {
        if (f[i].res == f[i].req) continue;
        n++;
        if (why && nwhy > used + 1) {
            int k = snprintf(why + used, nwhy - used,
                             "    %-24s resident 0x%llX, this manifest 0x%llX\n",
                             f[i].name, (unsigned long long)f[i].res,
                             (unsigned long long)f[i].req);
            if (k > 0 && (size_t)k < nwhy - used) used += (size_t)k;
            else { used = nwhy - 1; why[used] = 0; }
        }
    }
    /* A PARTIAL LOAD IS NOT AN IMAGE.  `--only PAT` leaves the record
     * invalidated rather than partial, so this can only be reached by an
     * explicit write, but a host that ran one must not treat the rest of HBM
     * as loaded. */
    if (r->objs_loaded != r->objs_total) {
        n++;
        if (why && nwhy > used + 1) {
            int k = snprintf(why + used, nwhy - used,
                             "    the resident image was only PARTIALLY loaded"
                             " (%u of %u objects)\n",
                             (unsigned)r->objs_loaded, (unsigned)r->objs_total);
            if (k > 0 && (size_t)k < nwhy - used) used += (size_t)k;
        }
    }
    return n;
}

#ifdef FK33_IMGLOCK_MAIN
#include <stdlib.h>
/* The selfcheck harness, built and run by `hw/fk33/host/fk33_imgfp.py
 * selfcheck`:
 *
 *   probe check <record.bin> <manifest.json>
 *       rc 0 only if the record parses AND describes that manifest.
 *   probe pack  <manifest.json> <out.bin> <fp_hex> <when> <loaded> <total>
 *               <bytes> <path>
 *       lay a record out from the manifest, for Python to compare byte for
 *       byte against its own packer.  The cross-check runs BOTH WAYS on
 *       purpose: one direction proves C can read what Python writes, and
 *       says nothing about whether C would write the same thing.
 */
static int hexnib(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int do_pack(int argc, char **argv)
{
    fk33_manifest m;
    fk33_imglock_rec r;
    unsigned char buf[FK33_IMGLOCK_BYTES];
    FILE *fp;
    int i, hi, lo;

    if (argc != 10) {
        fprintf(stderr, "usage: %s pack <manifest.json> <out.bin> <fp_hex> "
                        "<when> <loaded> <total> <bytes> <path>\n", argv[0]);
        return 2;
    }
    if (fk33_manifest_read(argv[2], &m)) return 2;
    fk33_imglock_from_manifest(&m, &r);
    if (strlen(argv[4]) != 32) { fprintf(stderr, "fp must be 32 hex\n"); return 2; }
    for (i = 0; i < 16; i++) {
        hi = hexnib(argv[4][2 * i]); lo = hexnib(argv[4][2 * i + 1]);
        if (hi < 0 || lo < 0) { fprintf(stderr, "fp not hex\n"); return 2; }
        r.fp[i] = (unsigned char)((hi << 4) | lo);
    }
    r.when         = strtoull(argv[5], NULL, 10);
    r.objs_loaded  = (uint32_t)strtoul(argv[6], NULL, 10);
    r.objs_total   = (uint32_t)strtoul(argv[7], NULL, 10);
    r.bytes_loaded = strtoull(argv[8], NULL, 10);
    snprintf(r.manifest_path, sizeof r.manifest_path, "%s", argv[9]);
    if (fk33_imglock_pack(&r, buf, sizeof buf)) return 2;
    fp = fopen(argv[3], "wb");
    if (!fp) { perror(argv[3]); return 2; }
    if (fwrite(buf, 1, sizeof buf, fp) != sizeof buf) { fclose(fp); return 2; }
    fclose(fp);
    printf("PACKED %u bytes\n", (unsigned)sizeof buf);
    return 0;
}

int main(int argc, char **argv)
{
    unsigned char buf[FK33_IMGLOCK_BYTES];
    fk33_imglock_rec r;
    fk33_manifest m;
    char why[2048];
    FILE *fp;
    size_t got;
    int rc, n;

    if (argc >= 2 && strcmp(argv[1], "pack") == 0)
        return do_pack(argc, argv);
    if (argc != 4 || strcmp(argv[1], "check") != 0) {
        fprintf(stderr, "usage: %s check <record.bin> <manifest.json>\n"
                        "       %s pack  <manifest.json> <out.bin> <fp_hex> "
                        "<when> <loaded> <total> <bytes> <path>\n",
                argv[0], argv[0]);
        return 2;
    }
    argv++;                                  /* so argv[1]/argv[2] read below */
    fp = fopen(argv[1], "rb");
    if (!fp) { perror(argv[1]); return 2; }
    got = fread(buf, 1, sizeof buf, fp);
    fclose(fp);
    if (got != sizeof buf) {
        printf("REFUSE short record: %u of %u bytes\n",
               (unsigned)got, (unsigned)sizeof buf);
        return 1;
    }
    rc = fk33_imglock_parse(buf, sizeof buf, &r);
    if (rc) { printf("REFUSE %s\n", fk33_imglock_why(rc)); return 1; }
    if (fk33_manifest_read(argv[2], &m)) {
        printf("REFUSE the manifest did not parse\n");
        return 1;
    }
    n = fk33_imglock_compare(&r, &m, why, sizeof why);
    if (n) {
        printf("%s", why);
        printf("REFUSE %d field(s) disagree; resident %s\n", n,
               r.manifest_path);
        return 1;
    }
    printf("MATCH addr 0x%llX objs %u/%u resident %s\n",
           (unsigned long long)fk33_imglock_addr(&m),
           (unsigned)r.objs_loaded, (unsigned)r.objs_total, r.manifest_path);
    return 0;
}
#endif
