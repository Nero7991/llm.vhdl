/* ref/embed_bf16.c -- see embed_bf16.h for what this is and why it exists.
 *
 * THE PARSE IS DELIBERATELY NARROW.  A general GGUF library would be more code
 * and would still have to be told which tensor matters.  This walks the header
 * once, in file order, skipping every metadata value it does not need, and
 * keeps exactly four numbers: the tensor's dtype, ne0, ne1 and the absolute
 * file offset of its row 0.  Every field it needs is REQUIRED to be present and
 * to make sense; nothing is defaulted silently except `general.alignment`,
 * whose GGUF-specified default is 32 and which is stated in the describe line
 * so a reader can see which one was used.
 *
 * WHAT WOULD MAKE IT CONFIDENTLY WRONG, and how that is closed: a header walk
 * that mis-skips one metadata value lands the tensor table at the wrong offset
 * and then reads garbage -- but garbage that still has to pass a dtype check, a
 * 2-D check and a "row 0 through row ne1-1 fits in the file" check, so it fails
 * loudly.  The subtler failure is landing on the WRONG TENSOR, which in this
 * checkpoint is a live risk because `output.weight` has the SAME dtype and the
 * SAME 4096 x 248320 shape.  Nothing structural can see that; only a value
 * oracle can, which is why mutant 6 exists and why the check compares against
 * llama.cpp's own embedding rows.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include "embed_bf16.h"

#define GGUF_MAGIC 0x46554747u          /* "GGUF" little-endian */
#define GGML_TYPE_BF16 30
#define MAX_NAME 512

/* gguf_metadata_value_type */
enum {
    GT_UINT8 = 0, GT_INT8, GT_UINT16, GT_INT16, GT_UINT32, GT_INT32,
    GT_FLOAT32, GT_BOOL, GT_STRING, GT_ARRAY, GT_UINT64, GT_INT64,
    GT_FLOAT64, GT_COUNT
};

static const int gt_size[GT_COUNT] = {
    1, 1, 2, 2, 4, 4, 4, 1, /*string*/ -1, /*array*/ -1, 8, 8, 8
};

struct emb_bf16_s {
    int fd;
    char path[512];
    char tensor[MAX_NAME];
    char desc[1024];

    uint32_t version;
    uint32_t alignment;
    uint64_t n_tensors, n_kv;

    int32_t  ne0;
    int64_t  ne1;
    uint32_t dtype;
    uint64_t data_start;        /* absolute offset of the data section       */
    uint64_t tensor_off;        /* offset of this tensor inside the section  */
    uint64_t row0;              /* data_start + tensor_off                   */
    uint64_t file_bytes;

    /* mutant 3/4/6 need what the clean walk found, so they are recorded even
     * in a build with no mutants: they cost nothing and they are printed. */
    uint64_t tensor_table_end;  /* offset just past the tensor table         */
    uint64_t first_tensor_off;  /* the tensor at index 0                     */
    char     first_tensor_name[MAX_NAME];

    uint64_t bytes_read, gathers;
    int mutant;

    uint16_t *raw;              /* one row of raw bf16 patterns              */
};

/* ------------------------------------------------------------ the walker */
/* Sequential, on its own FILE*.  Every helper returns 0 or -1 and every -1
 * has already printed why. */
typedef struct { FILE *fp; const char *path; uint64_t end; } wk_t;

static int wk_read(wk_t *w, void *dst, size_t n)
{
    if (fread(dst, 1, n, w->fp) != n) {
        fprintf(stderr, "embed_bf16: %s: short read of %zu bytes at %ld\n",
                w->path, n, ftell(w->fp));
        return -1;
    }
    return 0;
}

static int wk_skip(wk_t *w, uint64_t n)
{
    if (n > w->end) {                       /* cannot possibly be legitimate */
        fprintf(stderr, "embed_bf16: %s: absurd skip of %" PRIu64 " bytes\n",
                w->path, n);
        return -1;
    }
    if (fseeko(w->fp, (off_t)n, SEEK_CUR) != 0) {
        fprintf(stderr, "embed_bf16: %s: seek failed: %s\n",
                w->path, strerror(errno));
        return -1;
    }
    return 0;
}

static int wk_u32(wk_t *w, uint32_t *v) { return wk_read(w, v, 4); }
static int wk_u64(wk_t *w, uint64_t *v) { return wk_read(w, v, 8); }

/* A GGUF string: u64 length then that many bytes, NOT NUL-terminated.
 * `dst` may be NULL to skip it.  A length larger than the file is refused
 * rather than allocated, because that is exactly what a mis-skipped value
 * looks like. */
static int wk_str(wk_t *w, char *dst, size_t cap)
{
    uint64_t n;
    if (wk_u64(w, &n)) return -1;
    if (n > w->end) {
        fprintf(stderr, "embed_bf16: %s: string length %" PRIu64
                " exceeds the file; the header walk has lost its place\n",
                w->path, n);
        return -1;
    }
    if (!dst) return wk_skip(w, n);
    if (n >= cap) {                          /* keep it, truncated, and say so */
        if (wk_read(w, dst, cap - 1)) return -1;
        dst[cap - 1] = 0;
        return wk_skip(w, n - (cap - 1));
    }
    if (wk_read(w, dst, (size_t)n)) return -1;
    dst[n] = 0;
    return 0;
}

/* Skip one metadata value of type `t`.  Arrays recurse once; GGUF permits
 * nesting and this handles it by recursion on the element type. */
static int wk_skip_value(wk_t *w, uint32_t t)
{
    if (t >= GT_COUNT) {
        fprintf(stderr, "embed_bf16: %s: metadata value type %u is not a GGUF "
                "type; the header walk has lost its place\n", w->path, t);
        return -1;
    }
    if (t == GT_STRING) return wk_str(w, NULL, 0);
    if (t == GT_ARRAY) {
        uint32_t et; uint64_t cnt;
        if (wk_u32(w, &et) || wk_u64(w, &cnt)) return -1;
        if (et >= GT_COUNT) {
            fprintf(stderr, "embed_bf16: %s: array element type %u is not a "
                    "GGUF type\n", w->path, et);
            return -1;
        }
        if (gt_size[et] > 0) return wk_skip(w, cnt * (uint64_t)gt_size[et]);
        for (uint64_t i = 0; i < cnt; i++)
            if (wk_skip_value(w, et)) return -1;
        return 0;
    }
    return wk_skip(w, (uint64_t)gt_size[t]);
}

static const char *ggml_type_name(uint32_t t)
{
    switch (t) {
    case 0:  return "F32";
    case 1:  return "F16";
    case 30: return "BF16";
    default: return "(not F32/F16/BF16)";
    }
}

/* ---------------------------------------------------------------- open */
int emb_bf16_open(const char *path, const char *tensor, emb_bf16_t **out)
{
    if (!path || !out) return -1;
    if (!tensor) tensor = EMB_BF16_TENSOR;
    *out = NULL;

    emb_bf16_t *e = calloc(1, sizeof *e);
    if (!e) return -1;
    snprintf(e->path,   sizeof e->path,   "%s", path);
    snprintf(e->tensor, sizeof e->tensor, "%s", tensor);
    e->alignment = 32;                 /* the GGUF default, overridden below */
    e->fd = -1;

    struct stat st;
    if (stat(path, &st) != 0) {
        fprintf(stderr, "embed_bf16: %s: %s\n", path, strerror(errno));
        free(e); return -1;
    }
    e->file_bytes = (uint64_t)st.st_size;

    wk_t w;
    w.fp = fopen(path, "rb");
    w.path = path;
    w.end = e->file_bytes;
    if (!w.fp) {
        fprintf(stderr, "embed_bf16: %s: %s\n", path, strerror(errno));
        free(e); return -1;
    }

    uint32_t magic;
    if (wk_u32(&w, &magic)) goto fail;
    if (magic != GGUF_MAGIC) {
        fprintf(stderr, "embed_bf16: %s: not a GGUF file (magic 0x%08x)\n",
                path, magic);
        goto fail;
    }
    if (wk_u32(&w, &e->version)) goto fail;
    if (e->version != 2 && e->version != 3) {
        fprintf(stderr, "embed_bf16: %s: GGUF version %u; only 2 and 3 are "
                "read here (v1 counts its tensors in 32 bits, and guessing "
                "would silently misparse)\n", path, e->version);
        goto fail;
    }
    if (wk_u64(&w, &e->n_tensors) || wk_u64(&w, &e->n_kv)) goto fail;
    if (e->n_tensors == 0 || e->n_tensors > 1000000u || e->n_kv > 100000u) {
        fprintf(stderr, "embed_bf16: %s: implausible header: %" PRIu64
                " tensors, %" PRIu64 " kv\n", path, e->n_tensors, e->n_kv);
        goto fail;
    }

    /* ---- metadata.  Only general.alignment is kept. */
    for (uint64_t i = 0; i < e->n_kv; i++) {
        char key[256];
        uint32_t t;
        if (wk_str(&w, key, sizeof key)) goto fail;
        if (wk_u32(&w, &t)) goto fail;
        if (!strcmp(key, "general.alignment")) {
            if (t != GT_UINT32) {
                fprintf(stderr, "embed_bf16: %s: general.alignment is type %u, "
                        "not UINT32\n", path, t);
                goto fail;
            }
            if (wk_u32(&w, &e->alignment)) goto fail;
            if (e->alignment == 0 || (e->alignment & (e->alignment - 1))) {
                fprintf(stderr, "embed_bf16: %s: general.alignment %u is not a "
                        "power of two\n", path, e->alignment);
                goto fail;
            }
        } else if (wk_skip_value(&w, t)) {
            goto fail;
        }
    }

    /* ---- the tensor table. */
    int found = 0;
    for (uint64_t i = 0; i < e->n_tensors; i++) {
        char name[MAX_NAME];
        uint32_t ndim, ty;
        uint64_t dims[8] = {0}, off;
        if (wk_str(&w, name, sizeof name)) goto fail;
        if (wk_u32(&w, &ndim)) goto fail;
        if (ndim == 0 || ndim > 4) {
            fprintf(stderr, "embed_bf16: %s: tensor %s has %u dimensions\n",
                    path, name, ndim);
            goto fail;
        }
        for (uint32_t d = 0; d < ndim; d++)
            if (wk_u64(&w, &dims[d])) goto fail;
        if (wk_u32(&w, &ty) || wk_u64(&w, &off)) goto fail;

        if (i == 0) {
            e->first_tensor_off = off;
            snprintf(e->first_tensor_name, sizeof e->first_tensor_name,
                     "%s", name);
        }
        if (!found && !strcmp(name, e->tensor)) {
            found = 1;
            e->dtype = ty;
            e->tensor_off = off;
            if (ndim != 2) {
                fprintf(stderr, "embed_bf16: %s: %s has %u dimensions, not 2\n",
                        path, name, ndim);
                goto fail;
            }
            if (dims[0] == 0 || dims[0] > (1u << 20) || dims[1] == 0) {
                fprintf(stderr, "embed_bf16: %s: %s shape %" PRIu64 " x %"
                        PRIu64 " is implausible\n", path, name,
                        dims[0], dims[1]);
                goto fail;
            }
            e->ne0 = (int32_t)dims[0];
            e->ne1 = (int64_t)dims[1];
        }
    }
    e->tensor_table_end = (uint64_t)ftello(w.fp);
    if (!found) {
        fprintf(stderr, "embed_bf16: %s holds no tensor named %s\n",
                path, e->tensor);
        goto fail;
    }
    if (e->dtype != GGML_TYPE_BF16) {
        fprintf(stderr, "embed_bf16: %s: %s is ggml type %u %s, not BF16 (30). "
                "Refused rather than reinterpreted: reading an F16 tensor as "
                "BF16 gives plausible-looking numbers that are wrong by 2^112.\n",
                path, e->tensor, e->dtype, ggml_type_name(e->dtype));
        goto fail;
    }

    e->data_start = (e->tensor_table_end + e->alignment - 1)
                    & ~(uint64_t)(e->alignment - 1);
    e->row0 = e->data_start + e->tensor_off;

    uint64_t span = (uint64_t)e->ne0 * (uint64_t)e->ne1 * 2u;
    if (e->row0 > e->file_bytes || span > e->file_bytes - e->row0) {
        fprintf(stderr, "embed_bf16: %s: %s spans [%" PRIu64 ", %" PRIu64
                ") but the file is %" PRIu64 " bytes\n", path, e->tensor,
                e->row0, e->row0 + span, e->file_bytes);
        goto fail;
    }

    fclose(w.fp);
    w.fp = NULL;

    e->fd = open(path, O_RDONLY);
    if (e->fd < 0) {
        fprintf(stderr, "embed_bf16: %s: %s\n", path, strerror(errno));
        free(e); return -1;
    }
    e->raw = malloc(sizeof(uint16_t) * (size_t)e->ne0);
    if (!e->raw) { close(e->fd); free(e); return -1; }

    snprintf(e->desc, sizeof e->desc,
             "gguf %s v%u align=%u tensor=%s BF16 ne0=%d ne1=%" PRId64
             " data_start=0x%" PRIx64 " tensor_off=0x%" PRIx64
             " row0=0x%" PRIx64 " read=%dB x1",
             path, e->version, e->alignment, e->tensor, e->ne0, e->ne1,
             e->data_start, e->tensor_off, e->row0, e->ne0 * 2);

    *out = e;
    return 0;

fail:
    if (w.fp) fclose(w.fp);
    free(e);
    return -1;
}

void emb_bf16_close(emb_bf16_t *e)
{
    if (!e) return;
    if (e->fd >= 0) close(e->fd);
    free(e->raw);
    free(e);
}

/* ------------------------------------------------------------- the row */
static int row_bytes(emb_bf16_t *e, int row, uint16_t *dst)
{
    if (row < 0 || (int64_t)row >= e->ne1) {
        fprintf(stderr, "embed_bf16: row %d outside 0 .. %" PRId64 "\n",
                row, e->ne1 - 1);
        return -1;
    }

    uint64_t base = e->row0;
    int64_t  r    = row;
    size_t   n    = (size_t)e->ne0;
    int      stride_elems = 1;

#ifdef EMBED_BF16_MUTANTS
    switch (e->mutant) {
    case EMB_BF16_MUT_ROWOFF:
        r = (r + 1 < e->ne1) ? r + 1 : r - 1;
        break;
    case EMB_BF16_MUT_NOBASE:
        base = e->tensor_off;
        break;
    case EMB_BF16_MUT_NOALIGN:
        base = e->tensor_table_end + e->tensor_off;
        break;
    case EMB_BF16_MUT_COLMAJOR:
        stride_elems = (int)e->ne1;
        break;
    case EMB_BF16_MUT_FIRSTTENSOR:
        base = e->data_start + e->first_tensor_off;
        break;
    default:
        break;
    }
#endif

    if (stride_elems == 1) {
        uint64_t off = base + (uint64_t)r * (uint64_t)e->ne0 * 2u;
        ssize_t got = pread(e->fd, dst, n * 2, (off_t)off);
        if (got != (ssize_t)(n * 2)) {
            fprintf(stderr, "embed_bf16: pread of %zu bytes at 0x%" PRIx64
                    " returned %zd: %s\n", n * 2, off, got,
                    got < 0 ? strerror(errno) : "short");
            return -1;
        }
        e->bytes_read += n * 2;
        e->gathers    += 1;
    } else {
        for (size_t j = 0; j < n; j++) {
            uint64_t off = base + ((uint64_t)r + (uint64_t)j
                                   * (uint64_t)stride_elems) * 2u;
            if (off + 2 > e->file_bytes) { dst[j] = 0; continue; }
            if (pread(e->fd, &dst[j], 2, (off_t)off) != 2) return -1;
            e->bytes_read += 2;
        }
        e->gathers += 1;
    }
    return 0;
}

int emb_bf16_row_raw(emb_bf16_t *e, int row, uint16_t *dst, int n)
{
    if (!e || !dst) return -1;
    if (n != e->ne0) {
        fprintf(stderr, "embed_bf16: caller wants %d elements, %s has ne0 = %d. "
                "Refused rather than truncated: a short embedding row is a "
                "plausible-looking wrong answer.\n", n, e->tensor, e->ne0);
        return -1;
    }
    return row_bytes(e, row, dst);
}

int emb_bf16_row(emb_bf16_t *e, int row, double *dst, int n)
{
    if (!e || !dst) return -1;
    if (n != e->ne0) {
        fprintf(stderr, "embed_bf16: caller wants %d elements, %s has ne0 = %d. "
                "Refused rather than truncated: a short embedding row is a "
                "plausible-looking wrong answer.\n", n, e->tensor, e->ne0);
        return -1;
    }
    if (row_bytes(e, row, e->raw)) return -1;

    for (int j = 0; j < n; j++) {
        uint32_t bits = (uint32_t)e->raw[j] << 16;    /* bf16 -> f32, exact */
#ifdef EMBED_BF16_MUTANTS
        if (e->mutant == EMB_BF16_MUT_HALFSWAP) bits = (uint32_t)e->raw[j];
        if (e->mutant == EMB_BF16_MUT_NOSIGN)   bits &= 0x7FFFFFFFu;
#endif
        float f;
        memcpy(&f, &bits, 4);
        dst[j] = (double)f;
    }
    return 0;
}

int      emb_bf16_ne0(const emb_bf16_t *e)       { return e ? e->ne0 : 0; }
int64_t  emb_bf16_ne1(const emb_bf16_t *e)       { return e ? e->ne1 : 0; }
uint64_t emb_bf16_data_off(const emb_bf16_t *e)  { return e ? e->row0 : 0; }
uint64_t emb_bf16_bytes_read(const emb_bf16_t *e){ return e ? e->bytes_read : 0; }
uint64_t emb_bf16_gathers(const emb_bf16_t *e)   { return e ? e->gathers : 0; }
const char *emb_bf16_describe(const emb_bf16_t *e){ return e ? e->desc : ""; }

static const char *const mut_names[EMB_BF16_MUT_COUNT] = {
    "clean (control)",
    "bf16 taken as the LOW half of the f32",
    "row + 1",
    "tensor offset treated as absolute",
    "alignment ignored",
    "row read column-major (stride ne1)",
    "tensor found by index 0, not by name",
    "bf16 sign bit dropped",
};

const char *emb_bf16_mutant_name(int m)
{
    if (m < 0 || m >= EMB_BF16_MUT_COUNT) return "(no such mutant)";
    return mut_names[m];
}

int emb_bf16_set_mutant(emb_bf16_t *e, int m)
{
#ifdef EMBED_BF16_MUTANTS
    if (!e || m < 0 || m >= EMB_BF16_MUT_COUNT) return -1;
    e->mutant = m;
    return 0;
#else
    (void)e;
    if (m == EMB_BF16_MUT_NONE) return 0;
    fprintf(stderr, "embed_bf16: mutant %d refused.  A build without "
            "-DEMBED_BF16_MUTANTS cannot select a defect, which is the point\n",
            m);
    return -1;
#endif
}
