/* server/tests/chat_batch.c -- drive server/qwen35_chat.c over a binary
 * protocol on stdin/stdout, so server/verify_chat_template.py can compare it
 * against Jinja2 rendering the model's OWN template.
 *
 * The protocol is deliberately the same SHAPE as tools/tokenizer_c_batch.c's
 * (a u32 count, then length-prefixed records) so the two verifiers read alike.
 * Neither process knows the other exists: this one links only
 * server/qwen35_chat.c, and the oracle is Python plus, for the id leg,
 * llama.cpp's own tokenizer.
 *
 * stdin:
 *     u32  n_cases
 *     per case:
 *         u32 n_msgs
 *         u32 add_generation_prompt
 *         u32 enable_thinking
 *         per message:
 *             u32 role          0 system 1 user 2 assistant 3 tool 4 other
 *             u32 content_len   bytes follow
 *             u32 has_reasoning
 *             u32 reason_len    bytes follow
 *
 * stdout:
 *     u32  n_cases
 *     per case:
 *         i32 rc        >= 0 bytes rendered; < 0 a QWEN35_CHAT_E_* code
 *         u32 len       bytes follow (0 when rc < 0)
 *
 * With --tokenize <qtk> each case also carries, after the bytes:
 *         u32 n_ids     int32 ids follow
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../qwen35_chat.h"
#include "../qwen35_tok.h"

static int rd_u32(FILE *f, unsigned *v)
{
    unsigned char b[4];
    if (fread(b, 1, 4, f) != 4) return -1;
    *v = (unsigned)b[0] | ((unsigned)b[1] << 8)
       | ((unsigned)b[2] << 16) | ((unsigned)b[3] << 24);
    return 0;
}
static void wr_u32(FILE *f, unsigned v)
{
    unsigned char b[4];
    b[0] = (unsigned char)(v & 0xFF); b[1] = (unsigned char)((v >> 8) & 0xFF);
    b[2] = (unsigned char)((v >> 16) & 0xFF); b[3] = (unsigned char)((v >> 24) & 0xFF);
    fwrite(b, 1, 4, f);
}

static char *rd_blob(FILE *f, unsigned *len)
{
    char *p;
    if (rd_u32(f, len)) return NULL;
    p = (char *)malloc(*len + 1u);
    if (!p) return NULL;
    if (*len && fread(p, 1, *len, f) != *len) { free(p); return NULL; }
    p[*len] = 0;
    return p;
}

int main(int argc, char **argv)
{
    qwen35_tok *tk = NULL;
    unsigned n_cases, ci;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--tokenize") && i + 1 < argc) {
            tk = qwen35_tok_open(argv[++i]);
            if (!tk) { fprintf(stderr, "chat_batch: cannot open %s\n", argv[i]); return 2; }
        } else {
            fprintf(stderr, "usage: chat_batch [--tokenize qwen35_9b.qtk] < proto\n");
            return 2;
        }
    }

    if (rd_u32(stdin, &n_cases)) return 2;
    wr_u32(stdout, n_cases);

    for (ci = 0; ci < n_cases; ci++) {
        unsigned n_msgs, agp, think, m;
        qwen35_chat_msg *msgs;
        char **cbuf, **rbuf;
        char *out = NULL;
        int rc;

        if (rd_u32(stdin, &n_msgs) || rd_u32(stdin, &agp) || rd_u32(stdin, &think))
            return 2;
        msgs = (qwen35_chat_msg *)calloc(n_msgs ? n_msgs : 1, sizeof *msgs);
        cbuf = (char **)calloc(n_msgs ? n_msgs : 1, sizeof *cbuf);
        rbuf = (char **)calloc(n_msgs ? n_msgs : 1, sizeof *rbuf);
        if (!msgs || !cbuf || !rbuf) return 2;

        for (m = 0; m < n_msgs; m++) {
            unsigned role, clen, hasr, rlen;
            if (rd_u32(stdin, &role)) return 2;
            cbuf[m] = rd_blob(stdin, &clen);
            if (!cbuf[m]) return 2;
            if (rd_u32(stdin, &hasr)) return 2;
            rbuf[m] = rd_blob(stdin, &rlen);
            if (!rbuf[m]) return 2;
            msgs[m].role = (qwen35_role)role;
            msgs[m].content = cbuf[m];
            msgs[m].content_len = clen;
            msgs[m].has_reasoning = (int)hasr;
            msgs[m].reasoning = rbuf[m];
            msgs[m].reasoning_len = rlen;
        }

        /* Two calls: the sizing call with max 0, then the real one.  This is
         * the contract the header states and exercising it here is deliberate
         * -- a server WILL do it this way, and doing it here is what caught the
         * ambiguity that produced QWEN35_CHAT_E_SHORT. */
        {
            int need = 0;
            rc = qwen35_chat_render(msgs, (int)n_msgs, (int)agp, (int)think,
                                    NULL, 0, &need);
            if (rc == QWEN35_CHAT_E_SHORT) {
                out = (char *)malloc((size_t)need + 1u);
                if (!out) return 2;
                rc = qwen35_chat_render(msgs, (int)n_msgs, (int)agp, (int)think,
                                        out, need, NULL);
            } else if (rc == 0) {
                out = (char *)malloc(1);
            }
        }

        if (rc < 0) {
            wr_u32(stdout, (unsigned)rc);
            wr_u32(stdout, 0);
            if (tk) wr_u32(stdout, 0);
        } else {
            wr_u32(stdout, (unsigned)rc);
            wr_u32(stdout, (unsigned)rc);
            if (rc) fwrite(out, 1, (size_t)rc, stdout);
            if (tk) {
                /* Deliberately qwen35_chat_tokenize, NOT qwen35_tok_encode:
                 * the shipped function is the one a server calls, and the one
                 * that decides parse_special.  An earlier version of this
                 * driver called the tokenizer directly, and the "no-special"
                 * mutation therefore did not bite -- the mutated line was
                 * never executed.  That is the classic "the harness does not
                 * run the code under test" defect and it is recorded in the
                 * write-up rather than quietly fixed. */
                int cap = rc + 8, n;
                int *ids = (int *)malloc((size_t)cap * sizeof(int));
                n = qwen35_chat_tokenize(tk, msgs, (int)n_msgs, (int)agp,
                                         (int)think, ids, cap);
                if (n < 0 && n != QWEN35_TOK_ERR && -n > cap) {
                    cap = -n; free(ids);
                    ids = (int *)malloc((size_t)cap * sizeof(int));
                    n = qwen35_chat_tokenize(tk, msgs, (int)n_msgs, (int)agp,
                                             (int)think, ids, cap);
                }
                if (n < 0) n = 0;
                wr_u32(stdout, (unsigned)n);
                if (n) fwrite(ids, sizeof(int), (size_t)n, stdout);
                free(ids);
            }
        }

        for (m = 0; m < n_msgs; m++) { free(cbuf[m]); free(rbuf[m]); }
        free(cbuf); free(rbuf); free(msgs); free(out);
    }

    fflush(stdout);
    if (tk) qwen35_tok_free(tk);
    return 0;
}
