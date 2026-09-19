/* server/fk33_manifest.c -- see fk33_manifest.h.  Nothing here touches the card.
 *
 * The scan, precisely:
 *   1. walk the file once, tracking JSON string literals (so a `"why"` value
 *      containing a brace cannot corrupt the depth) and brace/bracket depth;
 *   2. find the key `"hbm"` at depth 1 whose value is an object;
 *   3. inside that object, and ONLY at its immediate depth, read `"key":
 *      <integer>` pairs whose key is one this file wants;
 *   4. require every wanted key to have been seen exactly once.
 *
 * Step 3's depth restriction is what stops `kv_extents[0].base` -- which is a
 * real key called `base` nested one level deeper -- from being mistaken for a
 * top-level field, and step 4 is what stops a manifest that simply lacks a key
 * from being read as a zero.  A zero here would read as "no constraint", which
 * is the exact failure mode this file exists to prevent.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fk33_manifest.h"

#define MAX_MANIFEST_BYTES (64u * 1024u * 1024u)

typedef struct { const char *name; uint64_t *slot; int seen; int optional; } field;
#define NFIELD 15

static int fail(const char *path, const char *what)
{
    fprintf(stderr, "fk33_manifest: %s: %s\n", path, what);
    return -1;
}

/* Advance `i` past a JSON string that starts at s[i] == '"'.  Returns the index
 * of the closing quote, or -1. */
static long skip_string(const char *s, long n, long i)
{
    i++;
    while (i < n) {
        if (s[i] == '\\') { i += 2; continue; }
        if (s[i] == '"') return i;
        i++;
    }
    return -1;
}

static long skip_ws(const char *s, long n, long i)
{
    while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
        i++;
    return i;
}

int fk33_manifest_read(const char *path, fk33_manifest *m)
{
    FILE *fp;
    char *buf = NULL;
    long n = 0, i, hbm_depth = -1;
    int depth = 0, rc = -1, k;
    field f[NFIELD];  /* f[0..12] required as of 2026-08-29; see the header */

    if (!path || !m) return -1;
    memset(m, 0, sizeof *m);
    snprintf(m->path, sizeof m->path, "%s", path);

    f[0].name = "size";               f[0].slot = &m->size;
    f[1].name = "align";              f[1].slot = &m->align;
    f[2].name = "stack_bytes";        f[2].slot = &m->stack_bytes;
    f[3].name = "weights_bytes";      f[3].slot = &m->weights_bytes;
    f[4].name = "weights_end";        f[4].slot = &m->weights_end;
    f[5].name = "gdn_state_base";     f[5].slot = &m->gdn_state_base;
    f[6].name = "gdn_state_bytes";    f[6].slot = &m->gdn_state_bytes;
    f[7].name = "kv_base";            f[7].slot = &m->kv_base;
    f[8].name = "kv_bytes_per_token"; f[8].slot = &m->kv_bytes_per_token;
    f[9].name = "max_context_tokens"; f[9].slot = &m->max_context_tokens;
    /* THE REGION BLOCK.  Required, on the same terms as everything above it:
     * the manifest is the authority for where the subsystem A descriptor arena
     * lives and for the max_chunk the host blocks were placed under, and an
     * authority that may omit the region it authorises is not one.  These
     * three were optional for one day and the optionality was the defect --
     * see the header. */
    f[10].name = "desc_arena_base";   f[10].slot = &m->desc_arena_base;
    f[11].name = "desc_arena_bytes";  f[11].slot = &m->desc_arena_bytes;
    f[12].name = "host_max_chunk";    f[12].slot = &m->host_max_chunk;
    /* THE GDN CONSTANT IMAGE, optional -- see the header for why this pair
     * alone may be absent.  Absent reads as 0 and pl_open() reports it. */
    f[13].name = "gdn_const_base";    f[13].slot = &m->gdn_const_base;
    f[14].name = "gdn_const_bytes";   f[14].slot = &m->gdn_const_bytes;
    for (k = 0; k < NFIELD; k++) { f[k].seen = 0; f[k].optional = (k >= 13); }

    fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "fk33_manifest: %s: %s\n", path, strerror(errno));
               return -1; }
    if (fseek(fp, 0, SEEK_END)) { fclose(fp); return fail(path, "not seekable"); }
    n = ftell(fp);
    if (n < 0) { fclose(fp); return fail(path, "ftell failed"); }
    if ((unsigned long)n > MAX_MANIFEST_BYTES)
    { fclose(fp); return fail(path, "larger than 64 MiB; refusing to read it"); }
    rewind(fp);
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(fp); return -1; }
    if (fread(buf, 1, (size_t)n, fp) != (size_t)n)
    { free(buf); fclose(fp); return fail(path, "short read"); }
    fclose(fp);
    buf[n] = 0;

    for (i = 0; i < n; i++) {
        char c = buf[i];
        if (c == '"') {
            long q0 = i, q1 = skip_string(buf, n, i);
            long j;
            if (q1 < 0) { free(buf); return fail(path, "unterminated string"); }
            i = q1;
            j = skip_ws(buf, n, q1 + 1);
            if (j >= n || buf[j] != ':')
                continue;                       /* a value, not a key */
            j = skip_ws(buf, n, j + 1);
            if (hbm_depth < 0) {
                if (depth == 1 && (q1 - q0 - 1) == 3
                    && !strncmp(buf + q0 + 1, "hbm", 3)
                    && j < n && buf[j] == '{')
                    hbm_depth = depth + 1;      /* the object we want */
                continue;
            }
            if (depth != hbm_depth) continue;   /* nested: not our key */
            for (k = 0; k < NFIELD; k++) {
                size_t len = strlen(f[k].name);
                if ((size_t)(q1 - q0 - 1) != len) continue;
                if (strncmp(buf + q0 + 1, f[k].name, len)) continue;
                if (j >= n || buf[j] < '0' || buf[j] > '9') {
                    free(buf);
                    fprintf(stderr, "fk33_manifest: %s: hbm.%s is not a "
                            "non-negative integer\n", path, f[k].name);
                    return -1;
                }
                *f[k].slot = strtoull(buf + j, NULL, 10);
                f[k].seen++;
                break;
            }
            continue;
        }
        if (c == '{' || c == '[') depth++;
        else if (c == '}' || c == ']') {
            depth--;
            if (hbm_depth >= 0 && depth < hbm_depth) break;      /* left "hbm" */
        }
    }
    free(buf);

    if (hbm_depth < 0) return fail(path, "no top-level \"hbm\" object");
    for (k = 0; k < NFIELD; k++) {
        if (f[k].seen == 1) continue;
        if (f[k].optional && f[k].seen == 0) continue;
        fprintf(stderr, "fk33_manifest: %s: hbm.%s appears %d times, want "
                "exactly 1.  A missing key would read as zero, and a zero here "
                "reads as \"no constraint\".\n", path, f[k].name, f[k].seen);
        if (k >= 10)
            fprintf(stderr,
                "  hbm.desc_arena_base / hbm.desc_arena_bytes / hbm.host_max_chunk\n"
                "  are the region block.  They are where the subsystem A descriptor\n"
                "  arena is DECLARED; no consumer re-derives it.  A set packed before\n"
                "  the block existed is migrated in place with\n"
                "    python3 tools/hbm_map.py %s --write-manifest-hbm\n",
                path);
        return -1;
    }

    /* Structural sanity, so a manifest that parses but cannot be true is
     * refused here rather than producing a base that looks derived. */
    if (m->size == 0 || m->stack_bytes == 0)
        return fail(path, "hbm.size or hbm.stack_bytes is zero");
    if (m->weights_end > m->size || m->kv_base > m->size)
        return fail(path, "weights_end or kv_base is past hbm.size");
    if (m->gdn_state_base < m->weights_end)
        return fail(path, "gdn_state_base is below weights_end");
    if (m->kv_base < m->gdn_state_base + m->gdn_state_bytes)
        return fail(path, "kv_base is below the end of the GDN state");
    /* The region block, checked as a region rather than accepted as a pair of
     * integers.  pl_check_bases() checks it again against the host blocks; this
     * is the half that can be checked from the file alone, so a manifest that
     * cannot be true is refused before anything derives an address from it. */
    if (m->desc_arena_bytes == 0)
        return fail(path, "hbm.desc_arena_bytes is 0; a declared arena with no "
                          "length is not a declaration");
    if (m->desc_arena_base % 4096ull)
        return fail(path, "hbm.desc_arena_base is not 4 KB aligned");
    if (m->desc_arena_base + m->desc_arena_bytes > m->size)
        return fail(path, "the declared descriptor arena runs past hbm.size");
    if (m->desc_arena_base < m->kv_base)
        return fail(path, "the declared descriptor arena starts below kv_base, "
                          "i.e. inside bytes the card already owns");
    if (m->host_max_chunk == 0)
        return fail(path, "hbm.host_max_chunk is 0; the host blocks cannot have "
                          "been placed under a zero chunk cap");
    /* The GDN constant image, when declared.  One key without the other is
     * refused: a base with no length is not a region and a length with no
     * base is address 0. */
    if ((m->gdn_const_base != 0) != (m->gdn_const_bytes != 0))
        return fail(path, "hbm.gdn_const_base and hbm.gdn_const_bytes must be "
                          "declared together and both nonzero");
    if (m->gdn_const_bytes) {
        if (m->gdn_const_base % 4096ull)
            return fail(path, "hbm.gdn_const_base is not 4 KB aligned");
        if (m->gdn_const_base + m->gdn_const_bytes > m->size)
            return fail(path, "the GDN constant image runs past hbm.size");
        if (m->gdn_const_base < m->kv_base)
            return fail(path, "the GDN constant image starts below kv_base, "
                              "i.e. inside bytes the card already owns");
        if (m->gdn_const_base + m->gdn_const_bytes > m->desc_arena_base
            && m->gdn_const_base < m->desc_arena_base + m->desc_arena_bytes)
            return fail(path, "the GDN constant image overlaps the descriptor "
                              "arena");
    }

    m->reserved_end = m->weights_end;
    if (m->gdn_state_base + m->gdn_state_bytes > m->reserved_end)
        m->reserved_end = m->gdn_state_base + m->gdn_state_bytes;
    if (m->kv_base > m->reserved_end) m->reserved_end = m->kv_base;

    rc = 0;
    return rc;
}

const char *fk33_manifest_describe(const fk33_manifest *m, char *buf, size_t n)
{
    if (!m || !buf) return "(none)";
    snprintf(buf, n,
             "manifest %s: hbm %llu B, weights_end 0x%llX, gdn 0x%llX+%llu, "
             "kv_base 0x%llX, %llu B/token, max_ctx %llu, reserved_end 0x%llX, "
             "A arena 0x%llX+%llu, host_max_chunk %llu, B consts 0x%llX+%llu",
             m->path, (unsigned long long)m->size,
             (unsigned long long)m->weights_end,
             (unsigned long long)m->gdn_state_base,
             (unsigned long long)m->gdn_state_bytes,
             (unsigned long long)m->kv_base,
             (unsigned long long)m->kv_bytes_per_token,
             (unsigned long long)m->max_context_tokens,
             (unsigned long long)m->reserved_end,
             (unsigned long long)m->desc_arena_base,
             (unsigned long long)m->desc_arena_bytes,
             (unsigned long long)m->host_max_chunk,
             (unsigned long long)m->gdn_const_base,
             (unsigned long long)m->gdn_const_bytes);
    return buf;
}
