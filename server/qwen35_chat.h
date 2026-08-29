/* qwen35_chat.h -- render the Qwen3.5 chat template, in C, for the SUBSET a
 * text server can actually serve, and REFUSE the rest.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * server/qwen35_tok.c tokenizes text.  It does not render the chat template,
 * and its own header says so in capitals, because the template is not
 * guessable from the role names.  Until something renders it, a
 * /v1/chat/completions endpoint on this model is off-distribution on EVERY
 * request -- not on edge cases.  This is that something.
 *
 * THE ORACLE IS THE MODEL'S OWN JINJA TEMPLATE, rendered by Jinja2, not this
 * file's author's reading of it.  server/verify_chat_template.py drives both
 * and compares bytes, then tokenizes both with llama.cpp and compares ids.
 * A round trip through this file alone would prove nothing: see the m7 mutant.
 *
 * WHAT IS RENDERED, AND WHAT IS REFUSED
 * -------------------------------------
 * The shipped template is 150 lines and covers tools, vision, tool_calls, the
 * `tool` role and a multi-step tool protocol.  A server that renders half of
 * that and silently drops the other half produces a prompt that LOOKS right
 * and is off-distribution -- the exact failure this file exists to prevent.
 * So the subset is enforced, not assumed:
 *
 *   RENDERED   roles system (at index 0 only), user, assistant.
 *              content as a string, or as an array of {"type":"text",...}
 *              parts, concatenated in order then trimmed.
 *              The assistant </think> split, including the re-emission of
 *              turns after the last user query as an explicit reasoning block.
 *              add_generation_prompt with both thinking branches.
 *
 *   REFUSED    `tools`, the `tool` role, `tool_calls`, image/video content
 *              parts, a system message anywhere but index 0, and a message
 *              list with no user query.  Each returns a distinct
 *              QWEN35_CHAT_E_* code and renders NOTHING.
 *
 * A refusal is a 400 to the client, which is a worse user experience and a
 * better server than a silently wrong prompt.
 *
 * TRIM IS PYTHON'S str.strip(), NOT isspace() FROM <ctype.h>
 * ----------------------------------------------------------
 * Every message's content is `|trim`ed by the template, and Jinja2's trim is
 * `str.strip()` with no argument, which strips UNICODE whitespace.  MEASURED
 * (python3, all 0x110000 codepoints, against the White_Space table already in
 * server/qwen35_unicode_data.c): Python's set is exactly Unicode White_Space
 * plus U+001C U+001D U+001E U+001F, 29 codepoints against 25, with nothing in
 * White_Space that Python omits.  So the trim here reuses that table and adds
 * those four.  An ASCII-only trim would diverge on a message beginning with
 * U+00A0, which a paste from a web page routinely produces.
 */
#ifndef QWEN35_CHAT_H
#define QWEN35_CHAT_H

#include <stddef.h>
#include "qwen35_tok.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Roles.  The template accepts `tool` as a fourth; this renderer refuses it. */
typedef enum {
    QWEN35_ROLE_SYSTEM = 0,
    QWEN35_ROLE_USER,
    QWEN35_ROLE_ASSISTANT,
    QWEN35_ROLE_TOOL,        /* accepted by the parser so it can be REFUSED */
    QWEN35_ROLE_OTHER        /* anything else; also refused */
} qwen35_role;

typedef struct {
    qwen35_role role;
    const char *content;     /* NOT NUL-terminated is fine; len rules */
    size_t      content_len;
    /* Non-zero when the request carried an explicit reasoning_content field.
     * The template prefers it over splitting the content on </think>. */
    int         has_reasoning;
    const char *reasoning;
    size_t      reasoning_len;
} qwen35_chat_msg;

/* Error codes.  Negative, distinct, and each names the thing refused so the
 * HTTP layer can say which. */
#define QWEN35_CHAT_E_NOMSGS      (-1)  /* empty message list */
#define QWEN35_CHAT_E_SYSPOS      (-2)  /* system message not at index 0 */
#define QWEN35_CHAT_E_ROLE        (-3)  /* unknown role */
#define QWEN35_CHAT_E_TOOLROLE    (-4)  /* the `tool` role: not implemented */
#define QWEN35_CHAT_E_TOOLS       (-5)  /* a `tools` array: not implemented */
#define QWEN35_CHAT_E_TOOLCALLS   (-6)  /* assistant tool_calls: not implemented */
#define QWEN35_CHAT_E_VISION      (-7)  /* image/video content part */
#define QWEN35_CHAT_E_NOQUERY     (-8)  /* no user query in the message list */
#define QWEN35_CHAT_E_OOM         (-9)
/* The output buffer was too small.  A SEPARATE code, not -(bytes needed):
 * a refusal code and a byte count share the negative half-line, and a render
 * of 4 bytes returning -4 would be indistinguishable from QWEN35_CHAT_E_TOOLS.
 * The needed size comes back in *needed instead.  This was a real defect in
 * the first draft of this header, caught by writing the batch driver against
 * it -- the driver could not tell the two apart and neither could a server. */
#define QWEN35_CHAT_E_SHORT       (-10)

/* Human-readable form of a QWEN35_CHAT_E_* code. */
const char *qwen35_chat_strerror(int code);

/* Render `n` messages into `buf`.
 *
 * add_generation_prompt != 0 appends the assistant header AND one of the two
 * thinking preambles.  enable_thinking selects which: non-zero gives
 * "<think>\n", zero gives "<think>\n\n</think>\n\n".  Note the template's own
 * default, when the caller passes no enable_thinking at all, is the SECOND
 * one -- an empty, already-closed reasoning block, not "emit nothing" -- so a
 * server that has no opinion must pass enable_thinking = 0.
 *
 * Returns bytes written (not NUL-terminated), or a QWEN35_CHAT_E_* code.  On
 * QWEN35_CHAT_E_SHORT nothing was written and *needed (if non-NULL) holds the
 * exact byte count required.  Call with buf = NULL, max = 0 to size. */
int qwen35_chat_render(const qwen35_chat_msg *msgs, int n,
                       int add_generation_prompt, int enable_thinking,
                       char *buf, int max, int *needed);

/* Render, then tokenize with parse_special = 1 (the control tokens above MUST
 * become single ids, which is what parse_special does).  Nothing is prepended:
 * this vocabulary has no BOS and the template emits none.
 *
 * Returns ids written, or a QWEN35_CHAT_E_* code.  On QWEN35_CHAT_E_SHORT
 * nothing was written and *needed (if non-NULL) holds the ids required.
 *
 * NOT -(ids needed), for the same reason qwen35_chat_render is not: this
 * function can return BOTH a refusal code and a size, they share the negative
 * half-line, and a prompt needing 4 ids would be indistinguishable from
 * QWEN35_CHAT_E_TOOLS.  The tokenizer's own -(ids needed) contract is safe
 * because qwen35_tok_encode has no refusal codes; this wrapper does. */
int qwen35_chat_tokenize(const qwen35_tok *tk,
                         const qwen35_chat_msg *msgs, int n,
                         int add_generation_prompt, int enable_thinking,
                         int *ids, int max, int *needed);

/* Python's str.strip() over UTF-8, exposed because the server needs the same
 * rule when it trims a completion.  Returns the trimmed span inside `s`. */
void qwen35_chat_trim(const char *s, size_t len,
                      const char **out, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* QWEN35_CHAT_H */
