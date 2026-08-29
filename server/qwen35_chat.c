/* qwen35_chat.c -- the Qwen3.5 chat template, transcribed from the model's own
 * Jinja source, for the subset in qwen35_chat.h.  READ THAT HEADER FIRST.
 *
 * The transcription is line-for-line against
 * build_artifacts_tok/qwen35_chat_template.jinja (extract it with
 * tools/extract_tokenizer.py --template).  Where a Jinja construct has a
 * non-obvious Python semantic -- `|trim`, `split`, `rstrip('\n')`,
 * `lstrip('\n')`, the reverse loop that finds the last user query -- the
 * comment names the semantic rather than restating the C.
 *
 * C99 + libc, like the tokenizer next to it.  No allocator tricks: one
 * realloc-grown output buffer, or the caller's, and that is all.
 */
#include <stdlib.h>
#include <string.h>

#include "qwen35_chat.h"
#include "qwen35_unicode_data.h"

/* ------------------------------------------------------------------ trim */

/* Python's str.strip() set: Unicode White_Space plus U+001C..U+001F.
 * MEASURED, see the header.  Kept as a function so the four extras cannot
 * drift away from the comment that explains them. */
static int py_isspace_cp(uint32_t cp)
{
    int a, b, m;
    if (cp >= 0x1Cu && cp <= 0x1Fu)
        return 1;
    a = 0; b = qwen35_uni_n_whitespace - 1;
    while (a <= b) {
        m = (a + b) / 2;
        if (qwen35_uni_whitespace[m] == cp) return 1;
        if (qwen35_uni_whitespace[m] <  cp) a = m + 1; else b = m - 1;
    }
    return 0;
}

/* Decode one UTF-8 sequence at s[i..len).  Writes the codepoint and the byte
 * length.  On a malformed sequence, reports one byte and codepoint 0xFFFD, so
 * a trim can never walk off the end or spin. */
static void utf8_at(const char *s, size_t len, size_t i,
                    uint32_t *cp, size_t *adv)
{
    unsigned char c = (unsigned char)s[i];
    size_t need, k;
    uint32_t v;

    if (c < 0x80u)                { *cp = c;            *adv = 1; return; }
    else if ((c & 0xE0u) == 0xC0u) { need = 2; v = c & 0x1Fu; }
    else if ((c & 0xF0u) == 0xE0u) { need = 3; v = c & 0x0Fu; }
    else if ((c & 0xF8u) == 0xF0u) { need = 4; v = c & 0x07u; }
    else                          { *cp = 0xFFFDu; *adv = 1; return; }

    if (i + need > len)           { *cp = 0xFFFDu; *adv = 1; return; }
    for (k = 1; k < need; k++) {
        unsigned char t = (unsigned char)s[i + k];
        if ((t & 0xC0u) != 0x80u) { *cp = 0xFFFDu; *adv = 1; return; }
        v = (v << 6) | (uint32_t)(t & 0x3Fu);
    }
    *cp = v; *adv = need;
}

/* Length of the UTF-8 sequence whose LAST byte is at index `i`, by walking
 * back over continuation bytes.  Used by the trailing trim, which has to move
 * right to left.  Bounded at 4 so a malformed tail cannot loop.
 *
 * DEFECT, FOUND BY THE ORACLE AND FIXED HERE, 2026-08-29.  The first version
 * of this function tested `s[i - n]` starting at n = 1, so it examined the
 * byte BEFORE the last one and never the last one itself.  For "x\xC2\xA0" it
 * returned 1, the caller then decoded a lone \xA0 as malformed, and the
 * trailing trim stopped.  The result: LEADING U+00A0 was stripped and
 * TRAILING U+00A0 was not.  Nothing internal could see this -- both halves of
 * the function were self-consistent -- and it was caught on the first run
 * against Jinja2, on 6 of 47 hand-written cases (U+00A0, U+2028, U+3000, each
 * in a user and a system message).  The correct index is `i - (n - 1)`. */
static size_t utf8_back(const char *s, size_t i)
{
    size_t n = 1;
    while (n < 4 && n - 1 <= i && ((unsigned char)s[i - (n - 1)] & 0xC0u) == 0x80u)
        n++;
    return n;
}

void qwen35_chat_trim(const char *s, size_t len, const char **out, size_t *out_len)
{
    size_t b = 0, e = len;
    while (b < e) {
        uint32_t cp; size_t adv;
        utf8_at(s, e, b, &cp, &adv);
        if (!py_isspace_cp(cp)) break;
        b += adv;
    }
    while (e > b) {
        size_t adv = utf8_back(s, e - 1);
        uint32_t cp; size_t a2;
        if (adv > e - b) adv = 1;
        utf8_at(s, e, e - adv, &cp, &a2);
        /* Only treat it as one character if the backwards walk and the
         * forwards decode agree; otherwise it is a malformed tail and stops
         * the trim, which is what Python does with a lone continuation byte
         * (it is not whitespace). */
        if (a2 != adv || !py_isspace_cp(cp)) break;
        e -= adv;
    }
    *out = s + b; *out_len = e - b;
}

/* ------------------------------------------------------------- out buffer */

typedef struct {
    char  *p;
    size_t len;
    size_t cap;
    int    oom;
} obuf;

static void ob_put(obuf *o, const char *s, size_t n)
{
    if (o->oom) return;
    if (o->len + n > o->cap) {
        size_t nc = o->cap ? o->cap * 2 : 1024;
        char  *np;
        while (nc < o->len + n) nc *= 2;
        np = (char *)realloc(o->p, nc);
        if (!np) { o->oom = 1; return; }
        o->p = np; o->cap = nc;
    }
    memcpy(o->p + o->len, s, n);
    o->len += n;
}
static void ob_lit(obuf *o, const char *s) { ob_put(o, s, strlen(s)); }

/* --------------------------------------------------------------- the split */

/* Find the last occurrence of `needle` in [s, s+len).  Returns -1 if absent. */
static long rfind(const char *s, size_t len, const char *needle)
{
    size_t nl = strlen(needle);
    size_t i;
    if (nl > len) return -1;
    for (i = len - nl + 1; i-- > 0; )
        if (!memcmp(s + i, needle, nl)) return (long)i;
    return -1;
}
static long ffind(const char *s, size_t len, const char *needle)
{
    size_t nl = strlen(needle);
    size_t i;
    if (nl > len) return -1;
    for (i = 0; i + nl <= len; i++)
        if (!memcmp(s + i, needle, nl)) return (long)i;
    return -1;
}

/* ------------------------------------------------------------ the renderer */

/* The template's `content.startswith('<tool_response>') and
 * content.endswith('</tool_response>')`, on the TRIMMED content. */
static int is_tool_response(const char *c, size_t n)
{
    static const char *A = "<tool_response>";
    static const char *B = "</tool_response>";
    size_t la = strlen(A), lb = strlen(B);
    return n >= la && n >= lb && !memcmp(c, A, la) && !memcmp(c + n - lb, B, lb);
}

const char *qwen35_chat_strerror(int code)
{
    switch (code) {
    case QWEN35_CHAT_E_NOMSGS:    return "no messages provided";
    case QWEN35_CHAT_E_SYSPOS:    return "a system message is legal only as messages[0]";
    case QWEN35_CHAT_E_ROLE:      return "unknown message role";
    case QWEN35_CHAT_E_TOOLROLE:  return "the 'tool' role is not implemented by this server";
    case QWEN35_CHAT_E_TOOLS:     return "'tools' is not implemented by this server";
    case QWEN35_CHAT_E_TOOLCALLS: return "assistant 'tool_calls' is not implemented by this server";
    case QWEN35_CHAT_E_VISION:    return "image/video content is not implemented by this server";
    case QWEN35_CHAT_E_NOQUERY:   return "no user query found in messages";
    case QWEN35_CHAT_E_OOM:       return "out of memory";
    case QWEN35_CHAT_E_SHORT:     return "output buffer too small";
    default:                      return "unknown chat-template error";
    }
}

int qwen35_chat_render(const qwen35_chat_msg *msgs, int n,
                       int add_generation_prompt, int enable_thinking,
                       char *buf, int max, int *needed)
{
    obuf o = { NULL, 0, 0, 0 };
    int i, rc = 0;
    int last_query_index;
    int multi_step_tool;

    if (n <= 0) return QWEN35_CHAT_E_NOMSGS;

    /* Roles are validated BEFORE anything is emitted, so a refusal never
     * leaves a half-rendered prompt anywhere. */
    for (i = 0; i < n; i++) {
        if (msgs[i].role == QWEN35_ROLE_TOOL)   return QWEN35_CHAT_E_TOOLROLE;
        if (msgs[i].role == QWEN35_ROLE_OTHER)  return QWEN35_CHAT_E_ROLE;
        if (msgs[i].role == QWEN35_ROLE_SYSTEM && i != 0)
            return QWEN35_CHAT_E_SYSPOS;
    }

    /* ns.last_query_index: the template walks the list BACKWARDS and stops at
     * the first user message whose trimmed content is not a bare
     * <tool_response>...</tool_response>.  Its defaults are
     * multi_step_tool = true and last_query_index = len-1, and the loop only
     * updates while multi_step_tool is still true.  If it never clears, the
     * template raises 'No user query found in messages.' */
    multi_step_tool = 1;
    last_query_index = n - 1;
    for (i = n - 1; i >= 0; i--) {
        if (multi_step_tool && msgs[i].role == QWEN35_ROLE_USER) {
            const char *c; size_t cl;
            qwen35_chat_trim(msgs[i].content ? msgs[i].content : "",
                             msgs[i].content ? msgs[i].content_len : 0, &c, &cl);
            if (!is_tool_response(c, cl)) {
                multi_step_tool = 0;
                last_query_index = i;
            }
        }
    }
    if (multi_step_tool) return QWEN35_CHAT_E_NOQUERY;

    /* The `tools` branch is refused in the header's API (there is no tools
     * argument), so only the else-branch system header can be emitted. */
    if (msgs[0].role == QWEN35_ROLE_SYSTEM) {
        const char *c; size_t cl;
        qwen35_chat_trim(msgs[0].content ? msgs[0].content : "",
                         msgs[0].content ? msgs[0].content_len : 0, &c, &cl);
        ob_lit(&o, "<|im_start|>system\n");
        ob_put(&o, c, cl);
        ob_lit(&o, "<|im_end|>\n");
    }

    for (i = 0; i < n; i++) {
        const char *c; size_t cl;
        qwen35_chat_trim(msgs[i].content ? msgs[i].content : "",
                         msgs[i].content ? msgs[i].content_len : 0, &c, &cl);

        if (msgs[i].role == QWEN35_ROLE_SYSTEM) {
            /* Already emitted above; the template's body loop only checks the
             * position, which we validated. */
            continue;
        }
        if (msgs[i].role == QWEN35_ROLE_USER) {
            ob_lit(&o, "<|im_start|>user\n");
            ob_put(&o, c, cl);
            ob_lit(&o, "<|im_end|>\n");
            continue;
        }

        /* assistant */
        {
            const char *reason = "";
            size_t      reason_len = 0;
            const char *body = c;
            size_t      body_len = cl;

            if (msgs[i].has_reasoning) {
                reason     = msgs[i].reasoning ? msgs[i].reasoning : "";
                reason_len = msgs[i].reasoning ? msgs[i].reasoning_len : 0;
            } else {
                long close = ffind(c, cl, "</think>");
                if (close >= 0) {
                    /* reasoning = content.split('</think>')[0]
                     *               .rstrip('\n').split('<think>')[-1].lstrip('\n')
                     * content   = content.split('</think>')[-1].lstrip('\n')
                     *
                     * split()[0] is the text BEFORE the FIRST '</think>';
                     * split()[-1] is the text after the LAST one.  They are
                     * different occurrences when the content holds two, which
                     * is why one uses ffind and the other rfind. */
                    const char *head = c;
                    size_t      head_len = (size_t)close;
                    long        open;
                    long        lastclose = rfind(c, cl, "</think>");

                    while (head_len > 0 && head[head_len - 1] == '\n') head_len--;
                    open = rfind(head, head_len, "<think>");
                    if (open >= 0) {
                        head     += (size_t)open + strlen("<think>");
                        head_len -= (size_t)open + strlen("<think>");
                    }
                    while (head_len > 0 && head[0] == '\n') { head++; head_len--; }
                    reason = head; reason_len = head_len;

                    body     = c + (size_t)lastclose + strlen("</think>");
                    body_len = cl - ((size_t)lastclose + strlen("</think>"));
                    while (body_len > 0 && body[0] == '\n') { body++; body_len--; }
                }
            }
            /* reasoning_content|trim, unconditionally, in both branches. */
            qwen35_chat_trim(reason, reason_len, &reason, &reason_len);

            ob_lit(&o, "<|im_start|>assistant\n");
            if (i > last_query_index) {
                ob_lit(&o, "<think>\n");
                ob_put(&o, reason, reason_len);
                ob_lit(&o, "\n</think>\n\n");
            }
            ob_put(&o, body, body_len);
            ob_lit(&o, "<|im_end|>\n");
        }
    }

    if (add_generation_prompt) {
        ob_lit(&o, "<|im_start|>assistant\n");
        ob_lit(&o, enable_thinking ? "<think>\n" : "<think>\n\n</think>\n\n");
    }

    if (o.oom) { free(o.p); return QWEN35_CHAT_E_OOM; }
    if (needed) *needed = (int)o.len;
    if ((int)o.len > max || (o.len && !buf)) { rc = QWEN35_CHAT_E_SHORT; }
    else { if (o.len) memcpy(buf, o.p, o.len); rc = (int)o.len; }
    free(o.p);
    return rc;
}

int qwen35_chat_tokenize(const qwen35_tok *tk,
                         const qwen35_chat_msg *msgs, int n,
                         int add_generation_prompt, int enable_thinking,
                         int *ids, int max)
{
    char *txt;
    int   need = 0, got, rc;

    got = qwen35_chat_render(msgs, n, add_generation_prompt, enable_thinking,
                             NULL, 0, &need);
    if (got < 0 && got != QWEN35_CHAT_E_SHORT) return got;
    if (need == 0) return 0;

    txt = (char *)malloc((size_t)need);
    if (!txt) return QWEN35_CHAT_E_OOM;
    got = qwen35_chat_render(msgs, n, add_generation_prompt, enable_thinking,
                             txt, need, NULL);
    if (got < 0) { free(txt); return got; }

    /* parse_special = 1 is REQUIRED: without it "<|im_start|>" tokenizes as
     * ordinary text and every turn boundary is wrong. */
    rc = qwen35_tok_encode(tk, txt, (size_t)got, ids, max, 1);
    free(txt);
    return rc;
}
