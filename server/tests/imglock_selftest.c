/* server/tests/imglock_selftest.c -- TEETH for the image interlock.
 *
 * THE MUTANT IS TODAY'S INCIDENT.  MEASURED 2026-09-20: the card held the
 * lane-striped image, `fk33_chat.sh` defaulted to the FLAT one, and driving it
 * destroyed 35 weight objects -- both manifests declare
 * `desc_arena_base = 0x1ffadd000`, so the flat descriptor table overwrote the
 * striped one, and `pl_open()` programmed the flat `kv_base = 0x10d93e000`
 * into FK33_SEAM_KVK so subsystem C wrote its records into the weight image.
 *
 * Every row below is built from the REAL region blocks of the three packed
 * sets, so the pair X2 refuses is the pair that did the damage.  The numbers
 * are read out of the manifests and written here as literals rather than
 * being read at run time, because this test must not depend on /mnt/storage
 * being mounted: it builds its own manifests, its own record, and a simulated
 * card whose HBM already holds that record.
 *
 * X3 IS THE ATTRIBUTION CONTROL and it is the most important row.  It is the
 * same incident pair with the interlock removed -- a card carrying no record,
 * which is exactly the state of the world before this change -- and it must
 * be ACCEPTED.  Without it the suite would credit the interlock with a kill
 * that some other check in pl_open() might already have made.
 *
 * NO HARDWARE.  PL_TRANSPORT_SIM only; nothing here can open /dev/xdma*.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "../pl_backend.h"
#include "../fk33_seam.h"
#include "../fk33_manifest.h"
#include "../fk33_imglock.h"

static int checks, failed;
static char dir[512];

static void CK(int cond, const char *fmt, ...)
{
    va_list ap;
    checks++;
    if (cond) return;
    failed++;
    printf("  FAIL ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

/* The three real region blocks, MEASURED from the manifests on 2026-09-20. */
typedef struct {
    const char *name;
    unsigned long long weights_end, gdn_state_base, kv_base, max_ctx;
} regions;

static const regions R_FLAT = {
    "flat",   0x10C006000ull, 0x10C006000ull, 0x10D93E000ull, 233237ull };
static const regions R_SEG27 = {
    "seg27",  0x1ABDE4000ull, 0x1B0000000ull, 0x1B1938000ull, 75181ull };
static const regions R_STRIPED = {
    "striped", 0x1ABDE4000ull, 0x1ABDE4000ull, 0x1AD71C000ull, 79675ull };

/* Write a manifest carrying only the `hbm` block, which is all
 * fk33_manifest_read() reads.  Returns the path (into `out`). */
static const char *write_manifest(char *out, size_t n, const char *tag,
                                  const regions *r,
                                  unsigned long long arena,
                                  unsigned long long arena_bytes,
                                  unsigned long long max_chunk)
{
    FILE *f;
    snprintf(out, n, "%s/manifest_%s.json", dir, tag);
    f = fopen(out, "w");
    if (!f) { perror(out); exit(2); }
    fprintf(f,
        "{\n \"format\": \"imglock selftest\",\n \"hbm\": {\n"
        "  \"size\": 8589934592,\n  \"align\": 4096,\n"
        "  \"stack_bytes\": 4294967296,\n  \"weights_bytes\": 4487442432,\n"
        "  \"weights_end\": %llu,\n"
        "  \"gdn_state_base\": %llu,\n  \"gdn_state_bytes\": 26443776,\n"
        "  \"kv_base\": %llu,\n  \"kv_bytes_per_token\": 17408,\n"
        "  \"max_context_tokens\": %llu,\n"
        "  \"gdn_const_base\": 8586608640,\n  \"gdn_const_bytes\": 1585152,\n"
        "  \"desc_arena_base\": %llu,\n  \"desc_arena_bytes\": %llu,\n"
        "  \"desc_arena_jobs\": 311,\n  \"desc_arena_stride\": 512,\n"
        "  \"host_max_chunk\": %llu\n }\n}\n",
        r->weights_end, r->gdn_state_base, r->kv_base, r->max_ctx,
        arena, arena_bytes, max_chunk);
    fclose(f);
    return out;
}

/* The 512 bytes a full load of `path` would leave in the arena's tail. */
static uint64_t make_record(const char *path, unsigned char *buf, int loaded,
                            int total)
{
    fk33_manifest m;
    fk33_imglock_rec r;
    if (fk33_manifest_read(path, &m)) { printf("  manifest %s\n", path); exit(2); }
    fk33_imglock_from_manifest(&m, &r);
    r.when = 1758300000ull;
    r.objs_loaded = (uint32_t)loaded;
    r.objs_total = (uint32_t)total;
    r.bytes_loaded = 4487442432ull;
    snprintf(r.manifest_path, sizeof r.manifest_path, "%s", path);
    /* The placement fingerprint is Python's to compute; C carries it and does
     * not check it (server/fk33_imglock.h).  A recognisable pattern here
     * makes that explicit rather than leaving zeros that could be mistaken
     * for "not set". */
    memset(r.fp, 0xA5, sizeof r.fp);
    if (fk33_imglock_pack(&r, buf, FK33_IMGLOCK_BYTES)) exit(2);
    return fk33_imglock_addr(&m);
}

/* Run pl_open against a simulated card whose HBM already holds `rec` at
 * `addr` (or holds nothing, when rec is NULL).  Returns pl_open's rc and
 * leaves pl_open's stderr in `msg`. */
static int open_with(const char *manifest, const unsigned char *rec,
                     uint64_t addr, int require, int version,
                     char *msg, size_t nmsg)
{
    fk33_sim_opts so;
    pl_open_opts o;
    pl_ctx *c = NULL;
    char errf[600];
    FILE *fp;
    int rc, saved;
    long n;

    fk33_sim_opts_default(&so);
    so.version = version;
    if (rec) { so.preload = rec; so.preload_addr = addr;
               so.preload_len = FK33_IMGLOCK_BYTES; }

    pl_open_opts_default(&o);
    o.transport = PL_TRANSPORT_SIM;
    o.sim_opts = &so;
    o.embed = pl_embed_synthetic;
    o.manifest_path = manifest;
    o.require_image_lock = require;

    /* Capture pl_open's stderr, because WHICH refusal fires is the ordering
     * property this file is here to establish. */
    snprintf(errf, sizeof errf, "%s/err.txt", dir);
    fflush(stderr);
    saved = dup(2);
    fp = freopen(errf, "w", stderr);
    rc = pl_open(&o, &c);
    fflush(stderr);
    if (fp) { dup2(saved, 2); }
    close(saved);
    if (c) pl_close(c);

    msg[0] = 0;
    fp = fopen(errf, "r");
    if (fp) {
        n = (long)fread(msg, 1, nmsg - 1, fp);
        if (n < 0) n = 0;
        msg[n] = 0;
        fclose(fp);
    }
    return rc;
}

static void row(const char *name, int refused, int want_refused,
                const char *needle, const char *msg)
{
    int ok = (refused == want_refused);
    if (ok && needle && needle[0])
        ok = (strstr(msg, needle) != NULL);
    checks++;
    if (!ok) failed++;
    printf("  %-52s %-9s %s\n", name,
           refused ? "REFUSED" : "accepted", ok ? "ok" : "WRONG");
    if (!ok) {
        printf("      expected %s%s%s\n",
               want_refused ? "REFUSED" : "accepted",
               needle && needle[0] ? " containing: " : "",
               needle ? needle : "");
        printf("      pl_open said: %.400s\n", msg);
    }
}

int main(void)
{
    char m_seg27[600], m_flat[600], m_striped[600], m_kv[600], m_shape[600];
    char m_ctx[600];
    unsigned char rec[FK33_IMGLOCK_BYTES], torn[FK33_IMGLOCK_BYTES];
    char msg[4096];
    uint64_t addr;
    const char *tmp = getenv("TMPDIR");
    int rc;

    snprintf(dir, sizeof dir, "%s/fk33_imglock_selftest_%ld",
             tmp && tmp[0] ? tmp : "/tmp", (long)getpid());
    if (mkdir(dir, 0700)) { perror(dir); return 2; }

    write_manifest(m_seg27, sizeof m_seg27, "seg27", &R_SEG27,
                   0x1FFADD000ull, 159744ull, 512ull);
    write_manifest(m_flat, sizeof m_flat, "flat", &R_FLAT,
                   0x1FFADD000ull, 159744ull, 512ull);
    write_manifest(m_striped, sizeof m_striped, "striped", &R_STRIPED,
                   0x1FFADD000ull, 159744ull, 512ull);
    {   /* seg27 with kv_base alone moved one page. */
        regions r = R_SEG27; r.kv_base += 4096;
        write_manifest(m_kv, sizeof m_kv, "kvedit", &r,
                       0x1FFADD000ull, 159744ull, 512ull);
    }
    {   /* A different model shape: the arena is somewhere else, so the record
         * is not even at the address this manifest names. */
        write_manifest(m_shape, sizeof m_shape, "shape", &R_SEG27,
                       0x1F0000000ull, 163840ull, 512ull);
    }
    {   /* seg27 with only the declared context cap changed: it moves nothing,
         * so this must NOT bite.  Reported under its own name. */
        regions r = R_SEG27; r.max_ctx = 4096;
        write_manifest(m_ctx, sizeof m_ctx, "ctxcap", &r,
                       0x1FFADD000ull, 159744ull, 512ull);
    }

    addr = make_record(m_seg27, rec, 251, 251);
    memcpy(torn, rec, sizeof torn);
    torn[0x40] ^= 0x01;              /* one bit of kv_base: a torn write */

    printf("IMGLOCK SELFTEST -- the card holds %s, record at 0x%llX\n",
           "seg27", (unsigned long long)addr);
    printf("  %-52s %-9s %s\n", "case", "verdict", "");

    rc = open_with(m_seg27, rec, addr, 1, 1, msg, sizeof msg);
    row("X1 the resident manifest (must be ACCEPTED)", rc < 0, 0,
        "image lock OK", msg);

    rc = open_with(m_flat, rec, addr, 1, 1, msg, sizeof msg);
    row("X2 THE INCIDENT: the flat manifest at a striped card", rc < 0, 1,
        "THE CARD IS NOT HOLDING THIS IMAGE", msg);
    if (rc < 0)
        CK(strstr(msg, "hbm.kv_base") != NULL,
           "X2 refused without naming kv_base, the field that did the damage");

    rc = open_with(m_flat, NULL, 0, 0, 1, msg, sizeof msg);
    row("X3 ATTRIBUTION the same pair, interlock disabled", rc < 0, 0,
        "NO IMAGE RECORD", msg);

    rc = open_with(m_flat, NULL, 0, 1, 1, msg, sizeof msg);
    row("X4 no record at all, on the hardware path", rc < 0, 1,
        "NO IMAGE RECORD", msg);

    rc = open_with(m_seg27, torn, addr, 1, 1, msg, sizeof msg);
    row("X5 a TORN record, on the hardware path", rc < 0, 1,
        "TORN or PARTIAL", msg);

    rc = open_with(m_seg27, torn, addr, 0, 1, msg, sizeof msg);
    row("X5b NOT BITING a torn record off the hardware path", rc < 0, 0,
        "NOTE:", msg);

    rc = open_with(m_striped, rec, addr, 1, 1, msg, sizeof msg);
    row("X6 striped vs seg27: same pieces, different KV", rc < 0, 1,
        "hbm.kv_base", msg);

    rc = open_with(m_kv, rec, addr, 1, 1, msg, sizeof msg);
    row("X7 kv_base edited alone", rc < 0, 1, "hbm.kv_base", msg);

    rc = open_with(m_shape, rec, addr, 1, 1, msg, sizeof msg);
    row("X8 a different model shape (arena elsewhere)", rc < 0, 1,
        "NO IMAGE RECORD", msg);

    rc = open_with(NULL, rec, addr, 1, 1, msg, sizeof msg);
    row("X9 no manifest at all, on the hardware path", rc < 0, 1,
        "no manifest was given", msg);

    rc = open_with(m_ctx, rec, addr, 1, 1, msg, sizeof msg);
    row("X10 NOT BITING max_context_tokens edited alone", rc < 0, 0,
        "image lock OK", msg);

    {   /* A PARTIAL load must not read as a resident image. */
        unsigned char part[FK33_IMGLOCK_BYTES];
        make_record(m_seg27, part, 120, 251);
        rc = open_with(m_seg27, part, addr, 1, 1, msg, sizeof msg);
        row("X11 a PARTIALLY loaded image", rc < 0, 1,
            "PARTIALLY loaded", msg);
    }

    {   /* ORDERING.  A v2 card with no descriptor program has its OWN
         * refusal waiting in pl_open.  If the image lock did not run first,
         * this would report the program, not the image.  That ordering is the
         * whole safety property: the refusal has to land before any base is
         * programmed. */
        rc = open_with(m_flat, rec, addr, 1, 2, msg, sizeof msg);
        row("X12 ORDERING the image lock fires before the v2 program check",
            rc < 0, 1, "THE CARD IS NOT HOLDING THIS IMAGE", msg);
        CK(strstr(msg, "seam version 2, which has NO HBM") == NULL,
           "X12 the v2 program check fired first: the image lock is too late");
    }

    {
        char p[700];
        const char *names[] = { "manifest_seg27.json", "manifest_flat.json",
                                "manifest_striped.json", "manifest_kvedit.json",
                                "manifest_shape.json", "manifest_ctxcap.json",
                                "err.txt" };
        size_t i;
        for (i = 0; i < sizeof names / sizeof names[0]; i++) {
            snprintf(p, sizeof p, "%s/%s", dir, names[i]);
            remove(p);
        }
        rmdir(dir);
    }

    printf("\nIMGLOCK_SELFTEST %s  (%d checks, %d failed)\n",
           failed ? "FAIL" : "PASS", checks, failed);
    return failed ? 1 : 0;
}
