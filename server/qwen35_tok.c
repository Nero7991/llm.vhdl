/* qwen35_tok.c -- byte-level BPE encode/decode for the Qwen3.5 vocabulary.
 *
 * C99, libc only.  A port of tools/qwen35_tokenizer.py's "llamacpp" backend,
 * which is itself a transcription of llama.cpp.  Every stage below names the
 * llama.cpp function it mirrors so a divergence can be located by reading, not
 * by guessing.  The oracle it is checked against is llama.cpp itself
 * (tools/verify_tokenizer_c.py); the Python is a second opinion, not the
 * reference.
 *
 * PIPELINE
 *   1. special-token partition   llama_vocab::impl::tokenizer_st_partition
 *      Operates on RAW BYTES, exactly as llama.cpp does, and only then is each
 *      text fragment decoded to codepoints.  Doing it on codepoints instead
 *      would differ for malformed UTF-8, where the fragment boundary changes
 *      where the U+FFFD substitutions land.
 *   2. pre-tokenizer split       unicode_regex_split_custom_qwen35
 *      The hand-written state machine, NOT a regex engine.  It reads Unicode
 *      categories out of tables copied from the oracle's own build; see
 *      qwen35_unicode_data.c and tools/gen_tokenizer_unicode_tables.py for why
 *      that provenance is the whole point.
 *   3. byte encoding             unicode_byte_encoding_process
 *   4. BPE                       llm_tokenizer_bpe_session::tokenize
 *      Priority queue over (rank asc, left index asc), stale entries skipped.
 *   5. vocabulary lookup, with llama.cpp's per-byte fallback.
 *
 * DECODE mirrors llama_vocab::impl::token_to_piece for LLAMA_VOCAB_TYPE_BPE
 * with escape_whitespaces = false, plus detokenize() with clean_spaces = false
 * and add_space_prefix = false, which for this vocab is plain concatenation.
 *
 * Thread safety: the loaded tables are read-only after qwen35_tok_open() and
 * every scratch buffer is allocated per call, so one qwen35_tok may be used
 * concurrently from several threads.
 */

#include "qwen35_tok.h"
#include "qwen35_unicode_data.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ flags */
/* llama.cpp's unicode_cpt_flags bits, src/unicode.h */
#define UF_UNDEFINED  0x0001u
#define UF_NUMBER     0x0002u
#define UF_LETTER     0x0004u
#define UF_MARK       0x0010u
#define UF_WHITESPACE 0x0100u

#define CPT_OUT_OF_RANGE 0xFFFFFFFFu

/* llama.cpp token_type / llama_token_attr values.  Note 5 is UNUSED and 6 is
 * BYTE -- an off-by-one here is the difference between rendering the tail-end
 * [PADnnnnnn] tokens as text and rendering them as nothing, which is what
 * llama.cpp does. */
#define ATTR_UNDEFINED    0
#define ATTR_NORMAL       1
#define ATTR_UNKNOWN      2
#define ATTR_CONTROL      3
#define ATTR_USER_DEFINED 4
#define ATTR_UNUSED       5
#define ATTR_BYTE         6

/* ---------------------------------------------------------- growable byte/int */

typedef struct { unsigned char *p; size_t n, cap; } buf_t;
typedef struct { int *p; size_t n, cap; } ivec_t;

static int buf_reserve(buf_t *b, size_t need) {
    if (b->n + need <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < b->n + need) cap *= 2;
    unsigned char *q = (unsigned char *) realloc(b->p, cap);
    if (!q) return -1;
    b->p = q; b->cap = cap; return 0;
}
static int buf_put(buf_t *b, const void *src, size_t n) {
    if (buf_reserve(b, n)) return -1;
    memcpy(b->p + b->n, src, n); b->n += n; return 0;
}
static int buf_putc(buf_t *b, unsigned char c) { return buf_put(b, &c, 1); }

static int ivec_push(ivec_t *v, int x) {
    if (v->n == v->cap) {
        size_t cap = v->cap ? v->cap * 2 : 64;
        int *q = (int *) realloc(v->p, cap * sizeof(int));
        if (!q) return -1;
        v->p = q; v->cap = cap;
    }
    v->p[v->n++] = x; return 0;
}

/* ------------------------------------------------------------------- UTF-8 */
/* unicode_cpt_from_utf8 / unicode_cpts_from_utf8: the same acceptance rules,
 * including the absence of overlong / surrogate / >U+10FFFF checks, and the
 * same "advance one byte and emit U+FFFD" recovery. */

static int cpt_from_utf8(const unsigned char *s, size_t n, size_t *off, uint32_t *out) {
    size_t i = *off;
    unsigned char c0 = s[i];
    if (!(c0 & 0x80))                     { *out = c0;            *off = i + 1; return 0; }
    if (!(c0 & 0x40))                     return -1;
    if (!(c0 & 0x20)) {
        if (i + 1 >= n || (s[i+1] & 0xc0) != 0x80) return -1;
        *out = ((uint32_t)(c0 & 0x1f) << 6) | (s[i+1] & 0x3f);
        *off = i + 2; return 0;
    }
    if (!(c0 & 0x10)) {
        if (i + 2 >= n || (s[i+1] & 0xc0) != 0x80 || (s[i+2] & 0xc0) != 0x80) return -1;
        *out = ((uint32_t)(c0 & 0x0f) << 12) | ((uint32_t)(s[i+1] & 0x3f) << 6) | (s[i+2] & 0x3f);
        *off = i + 3; return 0;
    }
    if (!(c0 & 0x08)) {
        if (i + 3 >= n || (s[i+1] & 0xc0) != 0x80 || (s[i+2] & 0xc0) != 0x80 ||
            (s[i+3] & 0xc0) != 0x80) return -1;
        *out = ((uint32_t)(c0 & 0x07) << 18) | ((uint32_t)(s[i+1] & 0x3f) << 12) |
               ((uint32_t)(s[i+2] & 0x3f) << 6) | (s[i+3] & 0x3f);
        *off = i + 4; return 0;
    }
    return -1;
}

/* Returns a malloc'd codepoint array (caller frees) and its length. */
static uint32_t *cpts_from_utf8(const unsigned char *s, size_t n, size_t *out_n) {
    uint32_t *cp = (uint32_t *) malloc((n + 1) * sizeof(uint32_t));
    if (!cp) return NULL;
    size_t off = 0, k = 0;
    while (off < n) {
        uint32_t c;
        if (cpt_from_utf8(s, n, &off, &c) == 0) cp[k++] = c;
        else { off++; cp[k++] = 0xFFFD; }
    }
    *out_n = k;
    return cp;
}

/* unicode_cpt_to_utf8.  llama.cpp throws for cpt > 0x10FFFF, which is only
 * reachable from malformed input (a 4-byte lead of 0xF5..0xF7); we emit the
 * 4-byte form instead of aborting.  Documented divergence, valid UTF-8 in,
 * never reached. */
static int cpt_to_utf8(uint32_t c, unsigned char *o) {
    if (c <= 0x7f)   { o[0] = (unsigned char) c; return 1; }
    if (c <= 0x7ff)  { o[0] = 0xc0 | ((c >> 6) & 0x1f); o[1] = 0x80 | (c & 0x3f); return 2; }
    if (c <= 0xffff) { o[0] = 0xe0 | ((c >> 12) & 0x0f); o[1] = 0x80 | ((c >> 6) & 0x3f);
                       o[2] = 0x80 | (c & 0x3f); return 3; }
    o[0] = 0xf0 | ((c >> 18) & 0x07); o[1] = 0x80 | ((c >> 12) & 0x3f);
    o[2] = 0x80 | ((c >> 6) & 0x3f);  o[3] = 0x80 | (c & 0x3f); return 4;
}

/* unicode_len_utf8 */
static size_t len_utf8(unsigned char c) {
    static const size_t lookup[16] = { 1,1,1,1,1,1,1,1, 1,1,1,1, 2,2, 3, 4 };
    return lookup[c >> 4];
}

/* --------------------------------------------------------- unicode category */

/* MUTATION HOOKS.  These exist so tools/verify_tokenizer_c.py can prove the C
 * comparison has teeth by breaking THIS code, not the Python.  They are
 * compiled out unless QWEN35_TOK_MUTATE is defined, so the shipping server
 * cannot be perturbed at runtime. */
#ifdef QWEN35_TOK_MUTATE
int qwen35_mut_drop_mark_flag = 0;   /* clear \p{M} for every codepoint */
int qwen35_mut_drop_nbsp_ws   = 0;   /* forget U+00A0 is White_Space */
int qwen35_mut_bytemap        = 0;   /* byte 0x20 encodes as byte 0x21's char */
int qwen35_mut_inv_bytemap    = 0;   /* U+0120 decodes to 0x21 */
int qwen35_mut_merge_rank     = 0;   /* demote the ("space","t") merge to last */
int qwen35_mut_drop_special   = 0;   /* forget <|im_start|> is special */
int qwen35_mut_unused_text    = 0;   /* render UNUSED tokens as their text */
#else
#  define qwen35_mut_drop_mark_flag 0
#  define qwen35_mut_drop_nbsp_ws   0
#  define qwen35_mut_bytemap        0
#  define qwen35_mut_inv_bytemap    0
#  define qwen35_mut_merge_rank     0
#  define qwen35_mut_drop_special   0
#  define qwen35_mut_unused_text    0
#endif

static uint16_t cpt_flags(uint32_t cpt) {
    /* unicode_cpt_flags_from_cpt: out of table -> UNDEFINED */
    if (cpt >= 0x110000u) return UF_UNDEFINED;
    int lo = 0, hi = qwen35_uni_n_ranges - 1;      /* last entry is the 0x110000 sentinel */
    while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        if (qwen35_uni_range_start[mid] <= cpt) lo = mid; else hi = mid - 1;
    }
    uint16_t f = qwen35_uni_range_flags[lo];
    /* unicode_cpt_flags_array() ORs the whitespace bit in afterwards */
    int a = 0, b = qwen35_uni_n_whitespace - 1;
    while (a <= b) {
        int m = (a + b) / 2;
        if (qwen35_uni_whitespace[m] == cpt) {
            if (!(qwen35_mut_drop_nbsp_ws && cpt == 0x00A0)) f |= UF_WHITESPACE;
            break;
        }
        if (qwen35_uni_whitespace[m] < cpt) a = m + 1; else b = m - 1;
    }
    if (qwen35_mut_drop_mark_flag) f &= (uint16_t) ~UF_MARK;
    return f;
}

/* unicode_tolower */
static uint32_t cpt_tolower(uint32_t cpt) {
    int lo = 0, hi = qwen35_uni_n_lower - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (qwen35_uni_lower_from[mid] == cpt) return qwen35_uni_lower_to[mid];
        if (qwen35_uni_lower_from[mid] < cpt) lo = mid + 1; else hi = mid - 1;
    }
    return cpt;
}

/* ------------------------------------------------------------- GPT-2 bytes */
/* unicode_byte_to_utf8_map: 0x21..0x7E, 0xA1..0xAC, 0xAE..0xFF map to
 * themselves, the remaining 68 bytes map to 0x100.. in ascending byte order. */

static void build_byte_map(uint32_t b2c[256], int16_t c2b[0x144]) {
    int have[256];
    int i;
    for (i = 0; i < 256; i++) have[i] = 0;
    for (i = 0; i < 0x144; i++) c2b[i] = -1;
    for (i = 0x21; i <= 0x7E; i++) have[i] = 1;
    for (i = 0xA1; i <= 0xAC; i++) have[i] = 1;
    for (i = 0xAE; i <= 0xFF; i++) have[i] = 1;
    int n = 0;
    for (i = 0; i < 256; i++) b2c[i] = have[i] ? (uint32_t) i : 0;
    for (i = 0; i < 256; i++) if (!have[i]) b2c[i] = (uint32_t) (256 + n++);
    for (i = 0; i < 256; i++) c2b[b2c[i]] = (int16_t) i;
}

/* --------------------------------------------------------------- the object */

struct qwen35_tok {
    unsigned char *blob;
    size_t         blob_size;

    uint32_t n_tokens, n_merges;
    int32_t  eos, pad, bos;
    int      add_bos, clean_spaces;
    char     pre[65], model[65];

    const uint32_t *tok_off;      /* n_tokens + 1 */
    const char     *tok_txt;
    const int32_t  *tok_type;
    const uint32_t *mrg_off;      /* n_merges + 1 */
    const char     *mrg_txt;
    uint32_t       *mrg_split;    /* offset of the ' ' inside merge i */
    const char     *tmpl;
    uint32_t        tmpl_len;

    uint32_t *tok_ht;  uint32_t tok_mask;   /* value id+1, 0 empty */
    uint32_t *mrg_ht;  uint32_t mrg_mask;   /* value rank+1 */

    int *special;  int n_special;           /* ids, longest text first */

    uint32_t b2c[256];
    int16_t  c2b[0x144];
};

static uint64_t fnv1a(const void *p, size_t n, uint64_t h) {
    const unsigned char *s = (const unsigned char *) p;
    size_t i;
    for (i = 0; i < n; i++) { h ^= s[i]; h *= 1099511628211ULL; }
    return h;
}
#define FNV_SEED 1469598103934665603ULL

static uint32_t next_pow2(uint32_t x) { uint32_t v = 8; while (v < x) v <<= 1; return v; }

static const char *tok_text(const qwen35_tok *t, uint32_t id, size_t *len) {
    *len = t->tok_off[id + 1] - t->tok_off[id];
    return t->tok_txt + t->tok_off[id];
}

/* llama.cpp builds token_to_id with operator[], so on duplicate text the LAST
 * id wins.  Mirror that: probe, and overwrite an equal key. */
static void tok_ht_insert(qwen35_tok *t, uint32_t id) {
    size_t len; const char *s = tok_text(t, id, &len);
    uint32_t h = (uint32_t) fnv1a(s, len, FNV_SEED);
    uint32_t i = h & t->tok_mask;
    for (;;) {
        uint32_t v = t->tok_ht[i];
        if (v == 0) { t->tok_ht[i] = id + 1; return; }
        size_t l2; const char *s2 = tok_text(t, v - 1, &l2);
        if (l2 == len && memcmp(s2, s, len) == 0) { t->tok_ht[i] = id + 1; return; }
        i = (i + 1) & t->tok_mask;
    }
}

static int tok_lookup(const qwen35_tok *t, const char *s, size_t len) {
    uint32_t h = (uint32_t) fnv1a(s, len, FNV_SEED);
    uint32_t i = h & t->tok_mask;
    for (;;) {
        uint32_t v = t->tok_ht[i];
        if (v == 0) return -1;
        size_t l2; const char *s2 = tok_text(t, v - 1, &l2);
        if (l2 == len && memcmp(s2, s, len) == 0) return (int) (v - 1);
        i = (i + 1) & t->tok_mask;
    }
}

static void mrg_parts(const qwen35_tok *t, uint32_t rank,
                      const char **a, size_t *na, const char **b, size_t *nb) {
    uint32_t o = t->mrg_off[rank], e = t->mrg_off[rank + 1], sp = t->mrg_split[rank];
    *a = t->mrg_txt + o;  *na = sp - o;
    *b = t->mrg_txt + sp + 1; *nb = e - sp - 1;
}

static uint32_t mrg_hash(const char *a, size_t na, const char *b, size_t nb) {
    return (uint32_t) fnv1a(b, nb, fnv1a(a, na, FNV_SEED));
}

static void mrg_ht_insert(qwen35_tok *t, uint32_t rank) {
    const char *a, *b; size_t na, nb;
    mrg_parts(t, rank, &a, &na, &b, &nb);
    uint32_t i = mrg_hash(a, na, b, nb) & t->mrg_mask;
    for (;;) {
        uint32_t v = t->mrg_ht[i];
        if (v == 0) { t->mrg_ht[i] = rank + 1; return; }
        const char *a2, *b2; size_t na2, nb2;
        mrg_parts(t, v - 1, &a2, &na2, &b2, &nb2);
        if (na2 == na && nb2 == nb && memcmp(a2, a, na) == 0 && memcmp(b2, b, nb) == 0) {
            /* llama.cpp's bpe_ranks is an unordered_map filled with try_emplace-
             * like semantics in rank order; a duplicate pair keeps the FIRST
             * (lowest) rank.  Keep it. */
            return;
        }
        i = (i + 1) & t->mrg_mask;
    }
}

/* find_bpe_rank: -1 when the pair has no merge */
static int mrg_lookup(const qwen35_tok *t, const char *a, size_t na,
                      const char *b, size_t nb) {
    uint32_t i = mrg_hash(a, na, b, nb) & t->mrg_mask;
    for (;;) {
        uint32_t v = t->mrg_ht[i];
        if (v == 0) return -1;
        const char *a2, *b2; size_t na2, nb2;
        mrg_parts(t, v - 1, &a2, &na2, &b2, &nb2);
        if (na2 == na && nb2 == nb && memcmp(a2, a, na) == 0 && memcmp(b2, b, nb) == 0) {
            int rank = (int) (v - 1);
#ifdef QWEN35_TOK_MUTATE
            /* mutation: demote the (U+0120, 't') merge -- byte 0x20 then 't' --
             * to last.  Chosen because it is reachable from any English text;
             * see docs/debugging/2026-08-28_qwen35-tokenizer.md section 6.1 for
             * the two rank perturbations that are structurally toothless. */
            if (qwen35_mut_merge_rank && na == 2 && nb == 1 &&
                (unsigned char) a[0] == 0xC4 && (unsigned char) a[1] == 0xA0 && b[0] == 't')
                rank = (int) t->n_merges;
#endif
            return rank;
        }
        i = (i + 1) & t->mrg_mask;
    }
}

/* --------------------------------------------------------------- open/free */

static uint32_t rd32(const unsigned char *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

#define QTK_HDR 232
#define QTK_NAME 64

static int cmp_special(const void *pa, const void *pb, const qwen35_tok *t) {
    int a = *(const int *) pa, b = *(const int *) pb;
    size_t la = t->tok_off[a + 1] - t->tok_off[a];
    size_t lb = t->tok_off[b + 1] - t->tok_off[b];
    if (la != lb) return la > lb ? -1 : 1;
    return a < b ? -1 : (a > b);
}
/* qsort has no context argument in C99; the vocabulary is loaded once, so a
 * file-static pointer used only inside qwen35_tok_open() is acceptable and is
 * cleared before returning. */
static const qwen35_tok *g_sort_ctx;
static int cmp_special_thunk(const void *a, const void *b) { return cmp_special(a, b, g_sort_ctx); }

qwen35_tok *qwen35_tok_open(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "qwen35_tok: cannot open %s\n", path); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < QTK_HDR) { fprintf(stderr, "qwen35_tok: %s too small\n", path); fclose(f); return NULL; }
    rewind(f);

    qwen35_tok *t = (qwen35_tok *) calloc(1, sizeof(*t));
    if (!t) { fclose(f); return NULL; }
    t->blob = (unsigned char *) malloc((size_t) sz);
    if (!t->blob || fread(t->blob, 1, (size_t) sz, f) != (size_t) sz) {
        fprintf(stderr, "qwen35_tok: short read on %s\n", path);
        fclose(f); qwen35_tok_free(t); return NULL;
    }
    fclose(f);
    t->blob_size = (size_t) sz;

    const unsigned char *h = t->blob;
    if (memcmp(h, "QTK1", 4) != 0) {
        fprintf(stderr, "qwen35_tok: %s: bad magic\n", path); qwen35_tok_free(t); return NULL;
    }
    uint32_t version = rd32(h + 4);
    if (version != 1) {
        fprintf(stderr, "qwen35_tok: %s: version %u, expected 1\n", path, version);
        qwen35_tok_free(t); return NULL;
    }
    t->n_tokens = rd32(h + 8);
    t->n_merges = rd32(h + 12);
    uint32_t eos = rd32(h + 16), pad = rd32(h + 20), bos = rd32(h + 24);
    t->eos = (eos == 0xFFFFFFFFu) ? -1 : (int32_t) eos;
    t->pad = (pad == 0xFFFFFFFFu) ? -1 : (int32_t) pad;
    t->bos = (bos == 0xFFFFFFFFu) ? -1 : (int32_t) bos;
    t->add_bos      = (int) rd32(h + 28);
    t->clean_spaces = (int) rd32(h + 32);
    memcpy(t->pre,   h + 40,  QTK_NAME);  t->pre[QTK_NAME]   = 0;
    memcpy(t->model, h + 104, QTK_NAME);  t->model[QTK_NAME] = 0;

    uint32_t so[8], sl[8];
    int i;
    for (i = 0; i < 8; i++) { so[i] = rd32(h + 168 + 8 * i); sl[i] = rd32(h + 168 + 8 * i + 4); }
    for (i = 0; i < 8; i++) {
        if ((size_t) so[i] + sl[i] > t->blob_size) {
            fprintf(stderr, "qwen35_tok: %s: section %d out of bounds\n", path, i);
            qwen35_tok_free(t); return NULL;
        }
    }
    if (sl[0] != (t->n_tokens + 1) * 4 || sl[2] != t->n_tokens * 4 ||
        sl[3] != (t->n_merges + 1) * 4) {
        fprintf(stderr, "qwen35_tok: %s: section sizes disagree with the header counts\n", path);
        qwen35_tok_free(t); return NULL;
    }
    if ((so[0] | so[2] | so[3]) & 3u) {
        fprintf(stderr, "qwen35_tok: %s: unaligned section\n", path);
        qwen35_tok_free(t); return NULL;
    }
    t->tok_off  = (const uint32_t *) (t->blob + so[0]);
    t->tok_txt  = (const char *)     (t->blob + so[1]);
    t->tok_type = (const int32_t *)  (t->blob + so[2]);
    t->mrg_off  = (const uint32_t *) (t->blob + so[3]);
    t->mrg_txt  = (const char *)     (t->blob + so[4]);
    t->tmpl     = (const char *)     (t->blob + so[5]);
    t->tmpl_len = sl[5];

    if (strcmp(t->model, "gpt2") != 0 || strcmp(t->pre, "qwen35") != 0) {
        fprintf(stderr, "qwen35_tok: %s is model=%s pre=%s; this implements gpt2/qwen35\n",
                path, t->model, t->pre);
        qwen35_tok_free(t); return NULL;
    }

    build_byte_map(t->b2c, t->c2b);

    /* token_to_id */
    t->tok_mask = next_pow2(t->n_tokens * 4) - 1;
    t->tok_ht = (uint32_t *) calloc((size_t) t->tok_mask + 1, sizeof(uint32_t));
    if (!t->tok_ht) { qwen35_tok_free(t); return NULL; }
    for (i = 0; i < (int) t->n_tokens; i++) tok_ht_insert(t, (uint32_t) i);

    /* merge ranks.  A GGUF merge string is "A B"; neither half can contain a
     * space, because both are byte-mapped (0x20 becomes U+0120). */
    t->mrg_split = (uint32_t *) malloc((size_t) t->n_merges * sizeof(uint32_t));
    if (!t->mrg_split && t->n_merges) { qwen35_tok_free(t); return NULL; }
    for (i = 0; i < (int) t->n_merges; i++) {
        uint32_t o = t->mrg_off[i], e = t->mrg_off[i + 1], j;
        uint32_t sp = e;
        for (j = o; j < e; j++) if (t->mrg_txt[j] == ' ') { sp = j; break; }
        if (sp == e) {
            fprintf(stderr, "qwen35_tok: %s: merge %d has no separating space\n", path, i);
            qwen35_tok_free(t); return NULL;
        }
        t->mrg_split[i] = sp;
    }
    t->mrg_mask = next_pow2(t->n_merges * 4 + 8) - 1;
    t->mrg_ht = (uint32_t *) calloc((size_t) t->mrg_mask + 1, sizeof(uint32_t));
    if (!t->mrg_ht) { qwen35_tok_free(t); return NULL; }
    for (i = 0; i < (int) t->n_merges; i++) mrg_ht_insert(t, (uint32_t) i);

    /* special tokens, longest text first.
     * llama.cpp sorts cache_special_tokens with std::sort on text length ALONE,
     * which is unstable, so the order among equal-length specials is not
     * defined by the reference.  We break the tie on id.  For it to matter, two
     * equal-length specials would have to be able to claim overlapping
     * positions in one string; no corpus string distinguished them.  Recorded
     * as unproven, not as proven equal. */
    t->special = (int *) malloc((size_t) t->n_tokens * sizeof(int));
    if (!t->special) { qwen35_tok_free(t); return NULL; }
    t->n_special = 0;
    for (i = 0; i < (int) t->n_tokens; i++) {
        int a = t->tok_type[i];
        if (a == ATTR_UNKNOWN || a == ATTR_CONTROL || a == ATTR_USER_DEFINED)
            t->special[t->n_special++] = i;
    }
    g_sort_ctx = t;
    qsort(t->special, (size_t) t->n_special, sizeof(int), cmp_special_thunk);
    g_sort_ctx = NULL;

    return t;
}

void qwen35_tok_free(qwen35_tok *t) {
    if (!t) return;
    free(t->blob); free(t->tok_ht); free(t->mrg_ht); free(t->mrg_split); free(t->special);
    free(t);
}

int         qwen35_tok_n_vocab(const qwen35_tok *t) { return (int) t->n_tokens; }
int         qwen35_tok_eos    (const qwen35_tok *t) { return t->eos; }
int         qwen35_tok_bos    (const qwen35_tok *t) { return t->bos; }
int         qwen35_tok_pad    (const qwen35_tok *t) { return t->pad; }
int         qwen35_tok_add_bos(const qwen35_tok *t) { return t->add_bos; }
const char *qwen35_tok_pre    (const qwen35_tok *t) { return t->pre; }
const char *qwen35_tok_model  (const qwen35_tok *t) { return t->model; }

const char *qwen35_tok_chat_template(const qwen35_tok *t, size_t *len) {
    if (len) *len = t->tmpl_len;
    return t->tmpl;
}

int qwen35_tok_id_of(const qwen35_tok *t, const char *text, size_t len) {
    return tok_lookup(t, text, len);
}

int qwen35_tok_attr(const qwen35_tok *t, int id) {
    if (id < 0 || id >= (int) t->n_tokens) return -1;
    return (int) t->tok_type[id];
}

/* --------------------------------------------------------- pre-tokenizer */
/* unicode_regex_split_custom_qwen35, transcribed.  `cp[0..n)` is one text
 * fragment.  Emits word end offsets into `ends`. */

/* _get_cpt / _get_flags in the C++.  Deliberately FUNCTIONS, not macros: the
 * C++ calls them as _get_flags(++pos), and a macro that names its argument
 * twice increments pos twice.  That exact bug produced ", " as one word where
 * llama.cpp produces "," and cost the first run of the corpus check. */
static uint32_t get_cpt(const uint32_t *cp, size_t n, size_t i) {
    return i < n ? cp[i] : CPT_OUT_OF_RANGE;
}
static uint16_t get_flags(const uint32_t *cp, size_t n, size_t i);

static int split_qwen35(const uint32_t *cp, size_t n, ivec_t *ends) {
    size_t pos = 0, prev_end = 0;

#define GET_CPT(i)   get_cpt(cp, n, (i))
#define GET_FLAGS(i) get_flags(cp, n, (i))
#define ADD_TOKEN(e) do { if ((e) > prev_end) { if (ivec_push(ends, (int) (e))) return -1; } \
                          prev_end = (e); } while (0)

    while (pos < n) {
        uint32_t c = cp[pos];
        uint16_t fl = cpt_flags(c);

        /* regex: (?i:'s|'t|'re|'ve|'m|'ll|'d) */
        if (c == '\'' && pos + 1 < n) {
            uint32_t c1 = cpt_tolower(GET_CPT(pos + 1));
            if (c1 == 's' || c1 == 't' || c1 == 'm' || c1 == 'd') {
                pos += 2; ADD_TOKEN(pos); continue;
            }
            if (pos + 2 < n) {
                uint32_t c2 = cpt_tolower(GET_CPT(pos + 2));
                if ((c1 == 'r' && c2 == 'e') || (c1 == 'v' && c2 == 'e') ||
                    (c1 == 'l' && c2 == 'l')) {
                    pos += 3; ADD_TOKEN(pos); continue;
                }
            }
        }

        /* regex: [^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+
         *
         * The C++ consumes cp[pos] unconditionally once the guard passes, so a
         * lone leading mark is taken as the optional prefix and a lone mark
         * with nothing after it is still emitted by itself.  That is not what
         * the regex literally means; it is what the oracle executes. */
        if (!(c == '\r' || c == '\n' || (fl & UF_NUMBER))) {
            uint16_t f1 = GET_FLAGS(pos + 1);
            if ((fl & (UF_LETTER | UF_MARK)) || (f1 & (UF_MARK | UF_LETTER))) {
                pos++;
                while (GET_FLAGS(pos) & (UF_LETTER | UF_MARK)) pos++;
                ADD_TOKEN(pos); continue;
            }
        }

        /* regex: \p{N}   -- one digit at a time, not a run */
        if (fl & UF_NUMBER) { pos++; ADD_TOKEN(pos); continue; }

        /* regex: <space>?[^\s\p{L}\p{M}\p{N}]+[\r\n]*
         *
         * Transcribed with the C++'s asymmetry intact: the ENTRY test has no
         * "flags2 is in range" term, only the loop does.  `fl != 0` is the
         * C++'s `flags.as_uint()`, which is always true here because pos < n
         * and every in-range codepoint carries at least UNDEFINED. */
        {
            uint16_t f2 = (c == ' ') ? GET_FLAGS(pos + 1) : fl;
            const uint16_t NOT_PUNCT = UF_WHITESPACE | UF_LETTER | UF_MARK | UF_NUMBER;
            if (!(f2 & NOT_PUNCT) && fl != 0) {
                if (c == ' ') pos++;
                while (!(f2 & NOT_PUNCT) && f2 != 0) f2 = GET_FLAGS(++pos);
                {
                    uint32_t c2 = GET_CPT(pos);
                    while (c2 == '\r' || c2 == '\n') c2 = GET_CPT(++pos);
                }
                ADD_TOKEN(pos); continue;
            }
        }

        {
            size_t num_ws = 0, last_nl = 0;
            while (GET_FLAGS(pos + num_ws) & UF_WHITESPACE) {
                uint32_t c2 = GET_CPT(pos + num_ws);
                if (c2 == '\r' || c2 == '\n') last_nl = pos + num_ws + 1;
                num_ws++;
            }
            /* regex: \s*[\r\n]+ */
            if (last_nl > 0) { pos = last_nl; ADD_TOKEN(pos); continue; }
            /* regex: \s+(?!\S) */
            if (num_ws > 1 && GET_CPT(pos + num_ws) != CPT_OUT_OF_RANGE) {
                pos += num_ws - 1; ADD_TOKEN(pos); continue;
            }
            /* regex: \s+ */
            if (num_ws > 0) { pos += num_ws; ADD_TOKEN(pos); continue; }
        }

        /* no matches */
        pos++; ADD_TOKEN(pos);
    }
    return 0;

#undef GET_CPT
#undef GET_FLAGS
#undef ADD_TOKEN
}

static uint16_t get_flags(const uint32_t *cp, size_t n, size_t i) {
    return i < n ? cpt_flags(cp[i]) : (uint16_t) 0;
}

/* ---------------------------------------------------------------- BPE heap */

typedef struct { int rank; int left; size_t size; } bigram_t;
typedef struct { bigram_t *p; size_t n, cap; } heap_t;

/* llm_bigram_bpe::comparator: min by (rank, left) */
static int bg_less(const bigram_t *a, const bigram_t *b) {
    if (a->rank != b->rank) return a->rank < b->rank;
    return a->left < b->left;
}
static int heap_push(heap_t *h, bigram_t v) {
    if (h->n == h->cap) {
        size_t cap = h->cap ? h->cap * 2 : 32;
        bigram_t *q = (bigram_t *) realloc(h->p, cap * sizeof(bigram_t));
        if (!q) return -1;
        h->p = q; h->cap = cap;
    }
    size_t i = h->n++;
    h->p[i] = v;
    while (i > 0) {
        size_t par = (i - 1) / 2;
        if (bg_less(&h->p[i], &h->p[par])) { bigram_t tmp = h->p[i]; h->p[i] = h->p[par]; h->p[par] = tmp; i = par; }
        else break;
    }
    return 0;
}
static bigram_t heap_pop(heap_t *h) {
    bigram_t top = h->p[0];
    h->p[0] = h->p[--h->n];
    size_t i = 0;
    for (;;) {
        size_t l = 2 * i + 1, r = l + 1, m = i;
        if (l < h->n && bg_less(&h->p[l], &h->p[m])) m = l;
        if (r < h->n && bg_less(&h->p[r], &h->p[m])) m = r;
        if (m == i) break;
        { bigram_t tmp = h->p[i]; h->p[i] = h->p[m]; h->p[m] = tmp; i = m; }
    }
    return top;
}

typedef struct { size_t off, n; int prev, next; } sym_t;

/* --------------------------------------------------------------- encode */

/* Byte-encode one word (a codepoint range of the fragment) into `w`, then BPE
 * it and append the resulting ids to `out`.  Mirrors one iteration of
 * llm_tokenizer_bpe_session::tokenize's word loop. */
static int encode_word(const qwen35_tok *t, const uint32_t *cp, size_t a, size_t b,
                       buf_t *w, ivec_t *out, sym_t **syms, size_t *syms_cap, heap_t *heap) {
    unsigned char u8[4], enc[2];
    size_t i;

    w->n = 0;
    for (i = a; i < b; i++) {
        int m = cpt_to_utf8(cp[i], u8);
        int k;
        for (k = 0; k < m; k++) {
            uint32_t c = t->b2c[u8[k]];
#ifdef QWEN35_TOK_MUTATE
            if (qwen35_mut_bytemap && u8[k] == 0x20) c = t->b2c[0x21];
#endif
            int m2 = cpt_to_utf8(c, enc);
            if (buf_put(w, enc, (size_t) m2)) return -1;
        }
    }
    if (w->n == 0) return 0;

    /* one symbol per byte-mapped character */
    size_t nsym = 0;
    {
        size_t off = 0;
        while (off < w->n) {
            size_t cl = len_utf8(w->p[off]);
            if (cl > w->n - off) cl = w->n - off;
            if (nsym == *syms_cap) {
                size_t cap = *syms_cap ? *syms_cap * 2 : 64;
                sym_t *q = (sym_t *) realloc(*syms, cap * sizeof(sym_t));
                if (!q) return -1;
                *syms = q; *syms_cap = cap;
            }
            (*syms)[nsym].off = off; (*syms)[nsym].n = cl;
            (*syms)[nsym].prev = (int) nsym - 1;
            off += cl;
            (*syms)[nsym].next = (off == w->n) ? -1 : (int) nsym + 1;
            nsym++;
        }
    }

    heap->n = 0;
    sym_t *S = *syms;

#define ADD_BIGRAM(L, R) do {                                                       \
        if ((L) >= 0 && (R) >= 0) {                                                 \
            int _r = mrg_lookup(t, (const char *) w->p + S[L].off, S[L].n,          \
                                   (const char *) w->p + S[R].off, S[R].n);         \
            if (_r >= 0) {                                                          \
                bigram_t _bg; _bg.rank = _r; _bg.left = (L);                        \
                _bg.size = S[L].n + S[R].n;                                         \
                if (heap_push(heap, _bg)) return -1;                                \
            }                                                                       \
        }                                                                           \
    } while (0)

    for (i = 1; i < nsym; i++) ADD_BIGRAM((int) i - 1, (int) i);

    while (heap->n) {
        bigram_t bg = heap_pop(heap);
        int l = bg.left, r = S[l].next;
        if (r < 0) continue;
        if (S[l].n == 0 || S[r].n == 0) continue;
        /* llama.cpp compares the concatenated TEXT to the queued text.  The
         * symbols of a word are contiguous and a symbol's start never moves, so
         * "same left index and same total length" is the same predicate. */
        if (S[l].n + S[r].n != bg.size) continue;

        S[l].n += S[r].n;
        S[r].n = 0;
        S[l].next = S[r].next;
        if (S[r].next >= 0) S[S[r].next].prev = l;

        ADD_BIGRAM(S[l].prev, l);
        ADD_BIGRAM(l, S[l].next);
    }
#undef ADD_BIGRAM

    for (i = 0; i < nsym; i++) {
        if (S[i].n == 0) continue;
        const char *s = (const char *) w->p + S[i].off;
        int id = tok_lookup(t, s, S[i].n);
        if (id >= 0) { if (ivec_push(out, id)) return -1; continue; }
        /* llama.cpp's fallback: emit each BYTE of the merged symbol as its own
         * token, silently dropping any byte that has none.  Unreachable for
         * this vocab (every byte-mapped character is present) but kept. */
        size_t j;
        for (j = 0; j < S[i].n; j++) {
            int id2 = tok_lookup(t, s + j, 1);
            if (id2 >= 0) { if (ivec_push(out, id2)) return -1; }
        }
    }
    return 0;
}

/* One RAW_TEXT fragment: decode to codepoints, split, encode each word. */
static int encode_fragment(const qwen35_tok *t, const unsigned char *s, size_t n, ivec_t *out) {
    size_t ncp = 0;
    uint32_t *cp = cpts_from_utf8(s, n, &ncp);
    if (!cp) return -1;

    ivec_t ends = {0, 0, 0};
    buf_t  w    = {0, 0, 0};
    sym_t *syms = NULL; size_t syms_cap = 0;
    heap_t heap = {0, 0, 0};
    int rc = split_qwen35(cp, ncp, &ends);
    if (rc == 0) {
        size_t a = 0, i;
        for (i = 0; i < ends.n; i++) {
            size_t b = (size_t) ends.p[i];
            if (encode_word(t, cp, a, b, &w, out, &syms, &syms_cap, &heap)) { rc = -1; break; }
            a = b;
        }
    }
    free(cp); free(ends.p); free(w.p); free(syms); free(heap.p);
    return rc;
}

/* tokenizer_st_partition + the BPE branch of llama_vocab::impl::tokenize */
typedef struct { int tok; size_t off, len; } frag_t;
typedef struct { frag_t *p; size_t n, cap; } fvec_t;

static int fvec_push(fvec_t *v, int tok, size_t off, size_t len) {
    if (v->n == v->cap) {
        size_t cap = v->cap ? v->cap * 2 : 16;
        frag_t *q = (frag_t *) realloc(v->p, cap * sizeof(frag_t));
        if (!q) return -1;
        v->p = q; v->cap = cap;
    }
    v->p[v->n].tok = tok; v->p[v->n].off = off; v->p[v->n].len = len; v->n++;
    return 0;
}

static const unsigned char *mem_find(const unsigned char *h, size_t hn,
                                     const unsigned char *nd, size_t nn) {
    if (nn == 0 || nn > hn) return NULL;
    const unsigned char *end = h + hn - nn;
    const unsigned char *p = h;
    for (;;) {
        p = (const unsigned char *) memchr(p, nd[0], (size_t) (end - p) + 1);
        if (!p) return NULL;
        if (memcmp(p, nd, nn) == 0) return p;
        if (p >= end) return NULL;
        p++;
    }
}

int qwen35_tok_encode(const qwen35_tok *t, const char *text, size_t len,
                      int *ids, int max, int parse_special) {
    const unsigned char *s = (const unsigned char *) text;
    fvec_t cur = {0, 0, 0}, nxt = {0, 0, 0};
    ivec_t out = {0, 0, 0};
    int rc = 0, si;

    if (len > 0 && fvec_push(&cur, -1, 0, len)) { rc = -1; goto done; }

    for (si = 0; si < t->n_special && rc == 0; si++) {
        int sid = t->special[si];
        int attr = (int) t->tok_type[sid];
        if (!parse_special && (attr == ATTR_CONTROL || attr == ATTR_UNKNOWN)) continue;
#ifdef QWEN35_TOK_MUTATE
        if (qwen35_mut_drop_special) {
            size_t sl0; const char *st0 = tok_text(t, (uint32_t) sid, &sl0);
            if (sl0 == 12 && memcmp(st0, "<|im_start|>", 12) == 0) continue;
        }
#endif
        size_t slen; const char *stxt = tok_text(t, (uint32_t) sid, &slen);
        if (slen == 0) continue;

        nxt.n = 0;
        size_t fi;
        for (fi = 0; fi < cur.n; fi++) {
            frag_t fr = cur.p[fi];
            if (fr.tok >= 0) { if (fvec_push(&nxt, fr.tok, 0, 0)) { rc = -1; break; } continue; }
            size_t start = fr.off, end = fr.off + fr.len;
            for (;;) {
                const unsigned char *m = mem_find(s + start, end - start,
                                                  (const unsigned char *) stxt, slen);
                if (!m) break;
                size_t at = (size_t) (m - s);
                if (at > start) { if (fvec_push(&nxt, -1, start, at - start)) { rc = -1; break; } }
                if (fvec_push(&nxt, sid, 0, 0)) { rc = -1; break; }
                start = at + slen;
            }
            if (rc) break;
            if (start < end) { if (fvec_push(&nxt, -1, start, end - start)) { rc = -1; break; } }
        }
        if (rc) break;
        { fvec_t tmp = cur; cur = nxt; nxt = tmp; }
    }

    if (rc == 0) {
        size_t fi;
        for (fi = 0; fi < cur.n; fi++) {
            if (cur.p[fi].tok >= 0) { if (ivec_push(&out, cur.p[fi].tok)) { rc = -1; break; } }
            else if (encode_fragment(t, s + cur.p[fi].off, cur.p[fi].len, &out)) { rc = -1; break; }
        }
    }

done:
    free(cur.p); free(nxt.p);
    if (rc) { free(out.p); return QWEN35_TOK_ERR; }
    if ((int) out.n > max) { int need = (int) out.n; free(out.p); return -need; }
    if (out.n) memcpy(ids, out.p, out.n * sizeof(int));
    { int n = (int) out.n; free(out.p); return n; }
}

/* --------------------------------------------------------------- decode */

/* llama_decode_text: undo the GPT-2 byte map, codepoint by codepoint. */
static int decode_text_into(const qwen35_tok *t, const char *txt, size_t n, buf_t *b) {
    size_t off = 0;
    while (off < n) {
        uint32_t c;
        size_t adv = off;
        if (cpt_from_utf8((const unsigned char *) txt, n, &adv, &c) != 0) { adv = off + 1; c = 0xFFFD; }
        unsigned char u8[4];
        int m = cpt_to_utf8(c, u8);
        int16_t by = (c < 0x144u) ? t->c2b[c] : -1;
#ifdef QWEN35_TOK_MUTATE
        if (qwen35_mut_inv_bytemap && c == 0x0120u) by = 0x21;
#endif
        if (by >= 0) { if (buf_putc(b, (unsigned char) by)) return -1; }
        else {
            /* llama.cpp's out_of_range branch, verbatim including the fact that
             * it appends the WHOLE token text after the hex. */
            static const char *hex = "0123456789abcdef";
            int k;
            if (buf_put(b, "[UNK_BYTE_0x", 12)) return -1;
            for (k = 0; k < m; k++) {
                if (buf_putc(b, (unsigned char) hex[u8[k] >> 4])) return -1;
                if (buf_putc(b, (unsigned char) hex[u8[k] & 15])) return -1;
            }
            if (buf_put(b, txt, n)) return -1;
            if (buf_putc(b, ']')) return -1;
        }
        off = adv;
    }
    return 0;
}

static int piece_into(const qwen35_tok *t, int id, buf_t *b, int render_special) {
    if (id < 0 || id >= (int) t->n_tokens) return 0;
    size_t n; const char *txt = tok_text(t, (uint32_t) id, &n);
    int attr = (int) t->tok_type[id];

    if (attr == ATTR_UNKNOWN || attr == ATTR_CONTROL) {
        if (!render_special) return 0;
        return buf_put(b, txt, n);
    }
    if (attr == ATTR_USER_DEFINED) return buf_put(b, txt, n);
    if (attr == ATTR_NORMAL)       return decode_text_into(t, txt, n, b);
    if (attr == ATTR_BYTE) {
        /* llama_vocab::impl::token_to_byte for BPE: text.substr(3,2) parsed as
         * hex, i.e. the "<0xXX>" convention.  This vocabulary has no such
         * tokens; kept because llama.cpp has it. */
        char h[3] = {0, 0, 0};
        if (n >= 5) { h[0] = txt[3]; h[1] = txt[4]; }
        return buf_putc(b, (unsigned char) strtol(h, NULL, 16));
    }
#ifdef QWEN35_TOK_MUTATE
    if (qwen35_mut_unused_text && attr == ATTR_UNUSED) return buf_put(b, txt, n);
#endif
    /* ATTR_UNDEFINED (0) and ATTR_UNUSED (5) fall out of llama.cpp's switch and
     * produce nothing.  The 243 [PADnnnnnn] tokens at the tail of this vocab
     * are UNUSED, so they decode to the empty string -- NOT to their text. */
    return 0;
}

int qwen35_tok_piece(const qwen35_tok *t, int id, char *buf, int max, int render_special) {
    buf_t b = {0, 0, 0};
    if (piece_into(t, id, &b, render_special)) { free(b.p); return QWEN35_TOK_ERR; }
    int n = (int) b.n;
    if (n > max) { free(b.p); return -n; }
    if (n) memcpy(buf, b.p, (size_t) n);
    free(b.p);
    return n;
}

int qwen35_tok_decode(const qwen35_tok *t, const int *ids, int n,
                      char *buf, int max, int render_special) {
    buf_t b = {0, 0, 0};
    int i;
    for (i = 0; i < n; i++) {
        if (piece_into(t, ids[i], &b, render_special)) { free(b.p); return QWEN35_TOK_ERR; }
    }
    int m = (int) b.n;
    if (m > max) { free(b.p); return -m; }
    if (m) memcpy(buf, b.p, (size_t) m);
    free(b.p);
    return m;
}
