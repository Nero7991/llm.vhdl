/* qwen35_tok.h -- byte-level BPE encode/decode for the Qwen3.5 vocabulary, in C.
 *
 * A C99 port of tools/qwen35_tokenizer.py, which is itself a transcription of
 * what llama.cpp does for tokenizer.ggml.model == "gpt2" with
 * tokenizer.ggml.pre == "qwen35".  Dependencies: libc only (stdio, stdlib,
 * string).  No C++, no exceptions, no allocator tricks -- it links into
 * server/llama_server.cpp without changing what "zero-dependency" means there,
 * and it cross-compiles static for aarch64 with the rest of the server.
 *
 * Verified against llama.cpp itself (NOT against the Python) by
 * tools/verify_tokenizer_c.py.  See docs/debugging/2026-08-28_qwen35-tokenizer-c.md
 * for the corpus, the exhaustive codepoint sweep and the mutation results.
 *
 * ---------------------------------------------------------------------------
 * HOW A SERVER USES THIS
 * ---------------------------------------------------------------------------
 *
 *     qwen35_tok *tk = qwen35_tok_open("build_artifacts_tok/qwen35_9b.qtk");
 *     int ids[4096];
 *     int n = qwen35_tok_encode(tk, prompt, strlen(prompt), ids, 4096, 1);
 *     if (n < 0) { ... need -n slots ... }
 *     ...
 *     char buf[64];
 *     int m = qwen35_tok_piece(tk, id, buf, sizeof buf, 1);   // per streamed token
 *
 * The .qtk artefact is produced by tools/extract_tokenizer.py from the GGUF and
 * is NOT committed (9 MB); regenerate it, see that tool's header.  Opening it
 * costs one read of the file plus two hash tables, ~35 MB resident for the
 * Qwen3.5-9B vocabulary.  It never touches the model tensors and never touches
 * a GPU.
 *
 * ---------------------------------------------------------------------------
 * WHAT A CHAT ENDPOINT MUST EMIT -- READ THIS BEFORE WIRING /v1/chat/completions
 * ---------------------------------------------------------------------------
 *
 * This file tokenizes text.  It does NOT render the chat template, and the
 * template is not something you can guess from the role names.  The rules that
 * bite, from the model's own tokenizer.chat_template (extract it with
 * tools/extract_tokenizer.py --template):
 *
 *   * ChatML.  Each message is
 *         <|im_start|> role "\n" content <|im_end|> "\n"
 *     Roles: system, user, assistant, tool.  A system message is legal ONLY as
 *     messages[0]; anywhere else the template raises.
 *
 *   * NO BOS, at either level.  The GGUF carries no bos_token_id and no
 *     add_bos_token, llama.cpp's BPE path leaves add_bos false, and the
 *     template emits none.  Do not prepend anything.
 *
 *   * The generation prompt is NOT just "<|im_start|>assistant\n".  With
 *     add_generation_prompt the template appends that AND THEN, ALWAYS, one of
 *     two thinking preambles:
 *
 *         enable_thinking true   ->  "<think>\n"
 *         otherwise, INCLUDING WHEN THE FLAG IS ABSENT
 *                                ->  "<think>\n\n</think>\n\n"
 *
 *     The default branch is the second one, and it is not "emit nothing": it is
 *     an empty, already-closed reasoning block.  A server that appends only
 *     "<|im_start|>assistant\n" is off-distribution on every request.
 *     <think> and </think> are ids 248068 and 248069, both CONTROL, so with
 *     parse_special = 1 they encode as single ids.
 *
 *   * Every message's content is |trim'ed by the template.  Preserving a user's
 *     trailing whitespace will not match the reference rendering.
 *
 *   * Stop tokens: eos is <|im_end|> (248046).  A server should also stop on
 *     <|endoftext|> (248044).  The pad token is <|vision_pad|> (248055), a
 *     vision pad -- do not use it as a text filler.
 *
 *   * Assistant turns AFTER the last user query are re-emitted as
 *     "<think>\n" reasoning "\n</think>\n\n" content, and the template will
 *     split reasoning out of the content on "</think>" if no separate field is
 *     given.  Tools get their own generated system message and an XML, not
 *     JSON, call syntax.  See docs/debugging/2026-08-28_qwen35-tokenizer.md
 *     section 8 for both in full.
 */
#ifndef QWEN35_TOK_H
#define QWEN35_TOK_H

#include <limits.h>
#include <stddef.h>

/* Returned by encode/piece/decode on an allocation failure.  Distinct from the
 * -(bytes needed) / -(ids needed) short-buffer return, whose magnitude is
 * always a real requirement and can legitimately be 1. */
#define QWEN35_TOK_ERR INT_MIN

#ifdef __cplusplus
extern "C" {
#endif

typedef struct qwen35_tok qwen35_tok;

/* Load a .qtk artefact.  Returns NULL and prints to stderr on failure. */
qwen35_tok *qwen35_tok_open(const char *qtk_path);
void        qwen35_tok_free(qwen35_tok *t);

int         qwen35_tok_n_vocab(const qwen35_tok *t);
int         qwen35_tok_eos    (const qwen35_tok *t);   /* -1 if none */
int         qwen35_tok_bos    (const qwen35_tok *t);   /* -1 if none; this vocab has none */
int         qwen35_tok_pad    (const qwen35_tok *t);   /* -1 if none */
int         qwen35_tok_add_bos(const qwen35_tok *t);   /* 0 for this vocab */
const char *qwen35_tok_pre    (const qwen35_tok *t);   /* "qwen35" */
const char *qwen35_tok_model  (const qwen35_tok *t);   /* "gpt2" */

/* The raw Jinja chat template, NUL-terminated, plus its length.  Rendering it
 * is the caller's problem; see the header comment above for what it says. */
const char *qwen35_tok_chat_template(const qwen35_tok *t, size_t *len);

/* Exact text -> id, or -1.  Use it for "<|im_start|>", "<think>", ... */
int qwen35_tok_id_of(const qwen35_tok *t, const char *text, size_t len);

/* llama.cpp's token attribute for an id (the GGUF's token_type):
 * 1 NORMAL, 2 UNKNOWN, 3 CONTROL, 4 USER_DEFINED, 5 UNUSED, 6 BYTE. */
int qwen35_tok_attr(const qwen35_tok *t, int id);

/* Encode `len` bytes of `text`.  parse_special != 0 makes a literal
 * "<|im_start|>" in the input become token 248045, which is what
 * llama-tokenize does by default.
 *
 * Returns the number of ids written, or -(number of ids needed) if `max` was
 * too small, in which case nothing was written.  A safe bound is len + 1.
 * Nothing is prepended or appended: no BOS (this vocab has none), no EOS. */
int qwen35_tok_encode(const qwen35_tok *t, const char *text, size_t len,
                      int *ids, int max, int parse_special);

/* One token's raw bytes, as llama_detokenize would emit them.
 * render_special != 0 renders CONTROL/UNKNOWN tokens as their literal text
 * (llama.cpp's unparse_special); 0 drops them.  Returns bytes written, or
 * -(bytes needed) if `max` was too small.  Not NUL-terminated. */
int qwen35_tok_piece(const qwen35_tok *t, int id, char *buf, int max,
                     int render_special);

/* The concatenation of qwen35_tok_piece over `n` ids.  Same return contract. */
int qwen35_tok_decode(const qwen35_tok *t, const int *ids, int n,
                      char *buf, int max, int render_special);

#ifdef __cplusplus
}
#endif

#endif /* QWEN35_TOK_H */
