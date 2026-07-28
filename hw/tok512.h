/* hw/tok512.h -- the stories260K tokenizer, shared by the on-board CLI
 * (hw/llama_hw.c) and the OpenAI server's PL backend (server/pl_backend.c).
 *
 * Header-only so both a C binary and a C++ server can use one implementation --
 * there is exactly one BPE here, and it is checked against ref/run_fx.
 * tok512_pkg.h (generated from ref/tok512.bin) supplies the vocabulary, the
 * piece lengths and the merge scores.
 */
#ifndef TOK512_H
#define TOK512_H

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#include "tok512_pkg.h"

/* Sentencepiece BPE encode, the same merges the C oracle uses: start from single
 * bytes (byte-fallback ids are byte+3) and greedily apply the highest-scoring
 * adjacent merge present in the vocabulary.  Writes BOS(1) first.
 * Returns the number of ids written, or -1 if the prompt does not fit in `max`. */
static int tok_encode(const char *text, int *out, int max)
{
    int n = 0, i;
    char buf[1024];

    if (max < 1)
        return -1;
    out[n++] = 1;                       /* BOS */

    if (text && *text) {                /* sentencepiece prepends a space */
        while (*text == ' ')
            text++;
        snprintf(buf, sizeof buf, " %s", text);
    } else {
        buf[0] = 0;
    }

    for (i = 0; buf[i]; i++) {
        int id = -1, v;
        for (v = 0; v < TOK_VOCAB; v++)
            if (TOK_LEN[v] == 1 && TOK_WORD[v][0] == buf[i]) { id = v; break; }
        if (n >= max)
            return -1;
        out[n++] = (id >= 0) ? id : ((unsigned char)buf[i] + 3);
    }

    for (;;) {
        float best = -1e30f;
        int at = -1, id = -1, k, v;
        for (k = 1; k + 1 < n; k++) {   /* never merge across BOS at index 0 */
            char pair[64];
            int la = TOK_LEN[out[k]], lb = TOK_LEN[out[k + 1]];
            if (la + lb >= (int)sizeof pair)
                continue;
            memcpy(pair, TOK_WORD[out[k]], (size_t)la);
            memcpy(pair + la, TOK_WORD[out[k + 1]], (size_t)lb);
            for (v = 0; v < TOK_VOCAB; v++)
                if (TOK_LEN[v] == la + lb && !memcmp(TOK_WORD[v], pair, (size_t)(la + lb))) {
                    if (TOK_SCORE[v] > best) { best = TOK_SCORE[v]; at = k; id = v; }
                    break;
                }
        }
        if (at < 0)
            break;
        out[at] = id;
        for (k = at + 1; k + 1 < n; k++)
            out[k] = out[k + 1];
        n--;
    }
    return n;
}

/* Mirror llama2.c decode(): the token right after BOS(1) loses its leading
 * space, and <0xXX> byte-fallback tokens expand to that raw byte.  Writes the
 * piece (NUL-terminated) into dst and returns its length. */
static int tok_piece(int tok, int prev, char *dst, int dstlen)
{
    const char *p;
    int len;

    if (tok == 1 || tok < 0 || tok >= TOK_VOCAB) {   /* BOS / out of range */
        if (dstlen > 0) dst[0] = 0;
        return 0;
    }
    p   = TOK_WORD[tok];
    len = TOK_LEN[tok];
    if (prev == 1 && len > 0 && p[0] == ' ') {
        p++;
        len--;
    }
    if (len == 6 && p[0] == '<' && p[1] == '0' && p[2] == 'x' && p[5] == '>') {
        char hex[3];
        hex[0] = p[3]; hex[1] = p[4]; hex[2] = 0;
        if (dstlen < 2) return 0;
        dst[0] = (char)(unsigned char)strtoul(hex, NULL, 16);
        dst[1] = 0;
        return 1;
    }
    if (len >= dstlen)
        len = dstlen - 1;
    if (len < 0)
        len = 0;
    memcpy(dst, p, (size_t)len);
    dst[len] = 0;
    return len;
}

#endif /* TOK512_H */
