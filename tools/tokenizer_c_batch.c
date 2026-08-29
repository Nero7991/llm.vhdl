/* tokenizer_c_batch.c -- drive server/qwen35_tok.c over the SAME wire protocol
 * as tools/tok_oracle_batch.cpp, so tools/verify_tokenizer_c.py can put the C
 * and llama.cpp side by side without either side knowing about the other.
 *
 * Protocol, stdin -> stdout, both binary, little-endian.  Byte-for-byte the
 * protocol tok_oracle_batch speaks:
 *   in : u32 n_items, then n_items records of (u32 len, len bytes)
 *   out: for each record, u32 n_tokens then n_tokens * i32 ids
 * Then, with --detok, the same again in reverse:
 *   in : u32 n_items, then n_items records of (u32 n_tokens, n_tokens * i32)
 *   out: for each record, u32 len then len bytes
 *
 * Note the payload is raw BYTES with a length prefix, not a NUL-terminated or
 * escaped string.  That is deliberate: it can carry the empty string, embedded
 * NULs and malformed UTF-8, none of which survive a command line.
 *
 * Build (also built by tools/verify_tokenizer_c.py --build):
 *   cc -O2 -std=c99 -Wall -Wextra -DQWEN35_TOK_MUTATE \
 *      tools/tokenizer_c_batch.c server/qwen35_tok.c server/qwen35_unicode_data.c \
 *      -Iserver -o build_artifacts_tok/tokenizer_c_batch
 *
 * Usage: tokenizer_c_batch TOK.qtk [--no-parse-special] [--detok] [--mutate NAME]
 *
 * --mutate exists ONLY here and only under -DQWEN35_TOK_MUTATE.  A checker that
 * has never been shown to fail has not been shown to work, and the Python's
 * mutation set proves nothing about this C.
 */

#include "qwen35_tok.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef QWEN35_TOK_MUTATE
extern int qwen35_mut_drop_mark_flag;
extern int qwen35_mut_drop_nbsp_ws;
extern int qwen35_mut_bytemap;
extern int qwen35_mut_inv_bytemap;
extern int qwen35_mut_merge_rank;
extern int qwen35_mut_drop_special;
extern int qwen35_mut_unused_text;
#endif

static void die(const char *m) { fprintf(stderr, "tokenizer_c_batch: %s\n", m); exit(2); }

static int read_exact(void *dst, size_t n) {
    return n == 0 || fread(dst, 1, n, stdin) == n;
}
static unsigned read_u32(void) {
    unsigned char b[4];
    if (!read_exact(b, 4)) die("short read");
    return (unsigned) b[0] | ((unsigned) b[1] << 8) | ((unsigned) b[2] << 16) | ((unsigned) b[3] << 24);
}
static void write_u32(unsigned v) {
    unsigned char b[4] = { (unsigned char) v, (unsigned char) (v >> 8),
                           (unsigned char) (v >> 16), (unsigned char) (v >> 24) };
    fwrite(b, 1, 4, stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s TOK.qtk [--no-parse-special] [--detok] [--mutate NAME]\n", argv[0]);
        return 1;
    }
    int parse_special = 1, do_detok = 0;
    const char *mutate = NULL;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--no-parse-special")) parse_special = 0;
        else if (!strcmp(argv[i], "--detok")) do_detok = 1;
        else if (!strcmp(argv[i], "--mutate") && i + 1 < argc) mutate = argv[++i];
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 1; }
    }

    qwen35_tok *tk = qwen35_tok_open(argv[1]);
    if (!tk) return 3;

    if (mutate) {
#ifdef QWEN35_TOK_MUTATE
        const char *desc = NULL;
        if      (!strcmp(mutate, "merge-rank"))    { qwen35_mut_merge_rank = 1;
            desc = "demoted the merge (U+0120,'t') -- byte 0x20 then 't' -- to last rank"; }
        else if (!strcmp(mutate, "byte-map"))      { qwen35_mut_bytemap = 1;
            desc = "GPT-2 byte map: byte 0x20 now encodes as byte 0x21's character"; }
        else if (!strcmp(mutate, "drop-special"))  { qwen35_mut_drop_special = 1;
            desc = "<|im_start|> removed from the special-token partition set"; }
        else if (!strcmp(mutate, "mark-flag"))     { qwen35_mut_drop_mark_flag = 1;
            desc = "Unicode table: \\p{M} cleared for every codepoint (the qwen35-vs-qwen2 difference)"; }
        else if (!strcmp(mutate, "ws-table"))      { qwen35_mut_drop_nbsp_ws = 1;
            desc = "Unicode table: U+00A0 no longer counts as White_Space"; }
        else if (!strcmp(mutate, "decode-bytemap")){ qwen35_mut_inv_bytemap = 1;
            desc = "inverse byte map: U+0120 decodes to 0x21 instead of 0x20"; }
        else if (!strcmp(mutate, "decode-unused")) { qwen35_mut_unused_text = 1;
            desc = "decoder renders UNUSED (token_type 5) tokens as their literal text"; }
        else { fprintf(stderr, "unknown mutation %s\n", mutate); return 1; }
        fprintf(stderr, "MUTATION: %s\n", desc);
#else
        fprintf(stderr, "built without -DQWEN35_TOK_MUTATE\n");
        return 1;
#endif
    }

    /* ---- encode pass */
    {
        unsigned n = read_u32();
        char *buf = NULL; size_t bufcap = 0;
        int *ids = NULL;  size_t idcap = 0;
        for (unsigned i = 0; i < n; i++) {
            unsigned len = read_u32();
            if (len + 1 > bufcap) { bufcap = len + 1; buf = realloc(buf, bufcap); if (!buf) die("oom"); }
            if (!read_exact(buf, len)) die("short text");
            size_t need = (size_t) len + 8;
            if (need > idcap) { idcap = need; ids = realloc(ids, idcap * sizeof(int)); if (!ids) die("oom"); }
            int k = qwen35_tok_encode(tk, buf, len, ids, (int) idcap, parse_special);
            if (k < 0) {
                if (k == QWEN35_TOK_ERR) die("encode failed (out of memory)");
                idcap = (size_t) (-k);
                ids = realloc(ids, idcap * sizeof(int)); if (!ids) die("oom");
                k = qwen35_tok_encode(tk, buf, len, ids, (int) idcap, parse_special);
                if (k < 0) die("encode failed on retry");
            }
            write_u32((unsigned) k);
            for (int j = 0; j < k; j++) write_u32((unsigned) ids[j]);
        }
        free(buf); free(ids);
        fflush(stdout);
    }

    /* ---- optional detokenize pass */
    if (do_detok) {
        unsigned n = read_u32();
        int *ids = NULL;  size_t idcap = 0;
        char *out = NULL; size_t outcap = 0;
        for (unsigned i = 0; i < n; i++) {
            unsigned k = read_u32();
            if (k + 1 > idcap) { idcap = k + 1; ids = realloc(ids, idcap * sizeof(int)); if (!ids) die("oom"); }
            for (unsigned j = 0; j < k; j++) ids[j] = (int) read_u32();
            size_t need = (size_t) k * 64 + 64;
            if (need > outcap) { outcap = need; out = realloc(out, outcap); if (!out) die("oom"); }
            int m = qwen35_tok_decode(tk, ids, (int) k, out, (int) outcap, 1);
            if (m < 0) {
                if (m == QWEN35_TOK_ERR) die("decode failed (out of memory)");
                outcap = (size_t) (-m);
                out = realloc(out, outcap); if (!out) die("oom");
                m = qwen35_tok_decode(tk, ids, (int) k, out, (int) outcap, 1);
                if (m < 0) die("decode failed on retry");
            }
            write_u32((unsigned) m);
            fwrite(out, 1, (size_t) m, stdout);
        }
        free(ids); free(out);
        fflush(stdout);
    }

    qwen35_tok_free(tk);
    return 0;
}
