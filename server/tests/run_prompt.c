/* server/tests/run_prompt.c -- drive the v2 seam's own loop over a committed
 * prompt and compare the ids it produces against a committed reference.
 *
 * This is the harness for the project's stated goal, which lives as a checkable
 * artefact in hw/fk33/results/goal_dcdc_2026-09-17/:
 *
 *     prompt_tokens.txt      23 ids, the rendered chat prompt
 *     reference_tokens.txt   1,197 ids, llama.cpp's greedy answer
 *     reference_answer.txt   the same ids detokenized, 5,307 bytes
 *
 * WHAT THIS CAN AND CANNOT PROVE, AND THE DISTINCTION IS THE WHOLE POINT
 * ---------------------------------------------------------------------
 * Against the SIMULATED card -- which is the only transport this file will
 * open -- the logits are synthetic by construction (pl_backend.h says so
 * outright), so the generated ids are meaningless and a divergence at position
 * 0 is the EXPECTED result.  Running it against the sim proves the loop: that
 * prefill chunks, that the position advances one per decode, that the stop
 * token ends it, that no call returns a negative, that the byte counters match
 * the fast path taken.  It proves NOTHING about any number.
 *
 * What makes it worth writing before the card exists is that it is the same
 * program that runs against silicon.  On that day the reference file turns
 * from decoration into an oracle, and the useful output is not PASS or FAIL
 * but FIRST DIVERGENCE: the position at which the card's greedy argmax first
 * disagrees with llama.cpp's, which is the one number that localises a
 * numerical defect to a token.
 *
 * THE ARGMAX CROSS-CHECK IS THE ONE CHECK WITH TEETH TODAY
 * -------------------------------------------------------
 * With --check-argmax the full ~1 MB logits row is pulled and the host
 * recomputes the argmax over it, against the card's own running argmax read
 * from a BAR register.  Those are two independent producers of the same
 * quantity: the card's sampler accumulates a global vocab index across the
 * lm_head's shards, and the host just scans a row.  They agree or one of them
 * is wrong, and that holds whether the logits are synthetic or real -- which
 * is exactly the class of defect that a wrong per-shard base produces, a
 * plausible id with no fault raised anywhere.
 *
 * TEETH.  Against the sim that cross-check is TAUTOLOGICAL in the clean case:
 * fk33_sim.c:254 scans its own logit_buf for the argmax and then writes both
 * the row and the register from it, so the two producers are one producer and
 * agreement proves nothing.  --teeth-argmax turns on the sim's
 * `fault_argmax_bias` knob, which offsets the index written to the row header
 * AND to the register so the two AGREE with each other and both disagree with
 * the row, and the check must then fire at every position.  A checker never
 * shown to fail has not been shown to work; that flag is how this one is
 * shown, and it is a self-test rather than a mode for real use.
 *
 * The ATTRIBUTION CONTROL matters here, because pl_backend.c:742 already
 * cross-checks the row header's argmax against the register and returns -3 on
 * a disagreement.  MEASURED: under `fault_stale_argmax` that EXISTING check
 * fires first and prefill returns -3, so this file's check never runs and
 * would have been credited with a kill it did not make.  `fault_argmax_bias`
 * is the state the existing check cannot see -- both copies wrong together --
 * and is therefore the only mutant that attributes a kill to the row scan.  On silicon the two producers are genuinely
 * independent -- the card's sampler accumulates a global index across the
 * lm_head's shards and the host just scans a row -- and the check acquires
 * meaning in the clean case too.
 *
 * HARDWARE, ONLY WHEN A HUMAN TYPES THE TOKEN.  By default this file never
 * opens a /dev path; the transport is pl_open_opts_default's simulated one.
 * `--allow-hardware <TOKEN>` switches to the /dev/xdma0_* char devices and
 * passes the token THE OPERATOR TYPED, packed from its four ASCII characters,
 * as `allow_hardware`.  The literal FK33_ALLOW_HARDWARE is deliberately NOT
 * referenced here: this program cannot open the card unless the person at the
 * prompt supplies the word the transport wants, and a wrong word is refused by
 * the transport with its own message.  That keeps the tripwire in
 * server/fk33_transport.h where it was -- in no test, no default and no
 * script -- while giving the bring-up procedure
 * (docs/2026-09-18_seam-bringup-on-the-card.md, steps 4, 8 and 9) a program
 * to run.  Added 2026-09-18, the day the first bitstream with the sampler and
 * the window seam was loaded.
 *
 * `--open-only` is step 4 on its own: pl_open streams the program into the
 * DESC and REL windows, reads WIN_ADDR back after each and refuses on a
 * mismatch, writes TBL_LEN and the two HBM bases from the manifest, and this
 * program then prints pl_describe() and exits without a GO.
 *
 * --dump-logits: THE TOKEN-0 LOGIT VECTOR, AS AN .r9bs STREAM
 * ------------------------------------------------------------
 * `--dump-logits <path>` writes the FIRST decided position -- the one prefill
 * produces, the only position at which the card and a reference start from
 * identical state -- as a `tools/ref9b/seam_stream.h` stream, so that every
 * instrument already written against that format reads it without a new
 * decoder: `r9bs.py` for the per-record statistics, `check_token.py` for the
 * argmax verdict and its margin, `logit_compare.py` for the vector.
 *
 * The file carries, at tok 0, layer -1:
 *   LOGITS      S32, n = n_vocab, exp = the card's LOGIT_EXP register.  The
 *               RAW s32 the sampler saw, NOT a float: the convention is the
 *               project's `value = mant * 2^-exp`, and seam_stream.h's own
 *               header records why recording it as BFP16 or F32 destroys
 *               exactly the bits an argmax comparison needs.
 *   LOGIT_EXP   S32, n = 1, exp 0.  The exponent AGAIN, as its own record, so
 *               a reader that never decodes a payload can still see it and so
 *               a v2 card (below) can publish it with no vector.
 *   TOKEN       S32, n = 1, exp 0.  The CARD'S OWN argmax, read from the
 *               ARGMAX register.  That makes the row REPORTED rather than
 *               DERIVED in check_token.py's sense: it is the sampler's answer,
 *               not a re-scan of the row.
 *
 * WHAT A v2 CARD CANNOT GIVE, AND WHY THIS DOES NOT PRETEND OTHERWISE.
 * MEASURED by reading the contract rather than the card: pl_backend.c:1243
 * refuses a logits row on `version >= 2` outright, because rtl/fk33_seam.vhd's
 * own header (:91-94) says the block "returns the sampler's ARGMAX and its
 * shared exponent.  It does NOT return 248,320 s32 logits" -- there is no C2H
 * path behind that window.  The bitstream that produced the first inference
 * on 2026-09-20 is v2 (`card seam v2 @BAR+0xE000`, `c2h 0`, `argmax fast
 * path`, in hw/fk33/results/card_swg_2026-09-20/dcdc_prompt_160.txt).
 * So on that card this flag writes LOGIT_EXP and TOKEN and NO LOGITS record,
 * and says so on stdout in one line.  A comparator then reports the vector
 * sections as UNAVAILABLE rather than as agreement, which is the difference
 * between a measurement that was not made and one that passed.
 *
 * Usage:
 *   run_prompt --prompt <ids.txt> [--reference <ids.txt>] [--max-new N]
 *              [--qtk <tokenizer.qtk>] [--mv4i <t.mv4i> --manifest <m.json>]
 *              [--check-argmax] [--dump-logits <path>]
 *              [--max-chunk N] [--stop ID] [--quiet]
 *              [--v2 --dtbl <token.dtbl> --rel <token.rel>]
 *              [--teeth-argmax N]
 *              [--allow-hardware <TOKEN>] [--open-only] [--go-timeout-ms N]
 *
 * An id file is whitespace-separated decimal integers; # to end of line is a
 * comment, so the committed artefacts can carry their own provenance.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../pl_backend.h"
#include "../fk33_seam.h"
/* The .r9bs writer.  Reused rather than reimplemented: tools/ref9b already
 * owns this format, its reader, its version rule and its S32 kind. */
#include "../../tools/ref9b/seam_stream.h"
#include "../embed_mv4i.h"
#include "../qwen35_tok.h"
#include "../qwen35_chat.h"
#include "../pl_pipeline.h"

/* <|im_end|>, the vocabulary's eos.  qwen35_tok.h:67 states it; when --qtk is
 * given the tokenizer's own answer replaces this, and a disagreement is
 * reported rather than silently resolved. */
#define QWEN35_EOS 248046

/* ------------------------------------------------------------------ id files
 * Whitespace-separated decimals, # to end of line.  Returns the count, or -1;
 * *out is malloc'd on success. */
static int read_ids(const char *path, int **out)
{
    FILE *f = fopen(path, "rb");
    int  *v = NULL, n = 0, cap = 0, c;
    if (!f) { fprintf(stderr, "run_prompt: cannot open %s\n", path); return -1; }
    *out = NULL;
    for (;;) {
        long val;
        int neg = 0;
        do {
            c = fgetc(f);
            if (c == '#') { while (c != EOF && c != '\n') c = fgetc(f); }
        } while (c != EOF && (c == ' ' || c == '\t' || c == '\r' || c == '\n'));
        if (c == EOF) break;
        if (c == '-') { neg = 1; c = fgetc(f); }
        if (c < '0' || c > '9') {
            fprintf(stderr, "run_prompt: %s: junk character '%c' at id %d\n",
                    path, c, n);
            free(v); fclose(f); return -1;
        }
        val = 0;
        while (c >= '0' && c <= '9') { val = val * 10 + (c - '0'); c = fgetc(f); }
        if (c != EOF) ungetc(c, f);
        if (n == cap) {
            int ncap = cap ? cap * 2 : 256;
            int *nv = (int *)realloc(v, (size_t)ncap * sizeof *v);
            if (!nv) { free(v); fclose(f); return -1; }
            v = nv; cap = ncap;
        }
        v[n++] = neg ? (int)-val : (int)val;
    }
    fclose(f);
    *out = v;
    return n;
}

static int argmax_of(const int32_t *row, int n)
{
    int best = 0, i;
    for (i = 1; i < n; i++) if (row[i] > row[best]) best = i;
    return best;
}

static void usage(void)
{
    fprintf(stderr,
      "usage: run_prompt --prompt <ids.txt> [--reference <ids.txt>]\n"
      "       run_prompt --text \"question\" --qtk <t.qtk> [--stream] ...\n"
      "                        one user message through the chat template\n"
      "                        (thinking off), tokenized with the .qtk; --stream\n"
      "                        prints each token's bytes as the card emits it\n"
      "                  [--max-new N] [--qtk <t.qtk>] [--check-argmax]\n"
      "                  [--dump-logits <p.r9bs>]  token 0's LOGITS (S32 +\n"
      "                  [--dump-xout <file>]  after the LAST GO, the residual R_X\n"
      "                        (window 3 mantissas + XEXP_OUT) as text: `exp E`, then\n"
      "                        n_embd int16 one per line; needs FK33_CAP_XEXP_OUT\n"
      "                        the shared exponent), LOGIT_EXP and the card's\n"
      "                        own TOKEN, in the tools/ref9b stream format.\n"
      "                        A v2 card publishes no logits row, so there the\n"
      "                        file carries LOGIT_EXP and TOKEN only and says\n"
      "                        so; compare with tools/ref9b/logit_compare.py\n"
      "                  [--mv4i <t.mv4i> --manifest <m.json>]\n"
      "                  [--max-chunk N] [--stop ID] [--quiet]\n"
      "                  [--dtbl2 <d.hex> --rel2 <r.bin> --manifest2 <m.json>]  a SECOND\n"
      "                        card (blocks k.. plus the LM head) driven through\n"
      "                        pl_pipeline; [--dev2 /dev/xdma1] its device prefix\n"
      "  --serial-prefill      two cards: prefill serially (the baseline) instead of\n"
      "                        overlapping card 0's next position with card 1\n"
      "                  [--v2 --dtbl <t.dtbl> --rel <t.rel>]  the window seam\n"
      "                  [--teeth-argmax N]   self-test of --check-argmax\n"
      "                  [--sim-kv-maxpos N]  the SIMULATED card's C_MAXPOS\n"
      "                        (KV_MAXPOS register, default 65536); 131072\n"
      "                        against the striped manifest is the 2026-09-20\n"
      "                        defect and pl_open must refuse it\n"
      "                  [--allow-hardware <TOKEN>]  /dev/xdma0_*; the operator\n"
      "                        types the transport's four-letter token\n"
      "                  [--open-only]        stream the program, write the\n"
      "                        bases, read WIN_ADDR back, then exit (no GO)\n"
      "                  [--go-timeout-ms N]  per-GO wait (default 60000)\n"
      "                  [--resume]           start at the card's SEQ_POS\n"
      "                  [--seq-reset]        clear the SEAM's position first\n"
      "Simulated transport unless --allow-hardware is given by a human.\n");
}

/* ------------------------------------------------------- the token-0 dump
 * `logits` may be NULL, which is the v2 card and is not an error: the file is
 * then LOGIT_EXP + TOKEN and a reader sees the vector is ABSENT rather than
 * equal to something.  Returns 0, or -1 with a message.
 *
 * The version declared is R9BS_VERSION_S32 unconditionally, because every
 * record written here is S32 and seam_stream.h's rule is that a file carrying
 * one must declare 2 so an older reader stops loudly. */
static int dump_token0(const char *path, const int32_t *logits, int n_vocab,
                       int32_t lexp, int argmax, int card_version)
{
    FILE *fp = fopen(path, "wb");
    int32_t one;
    if (!fp) { fprintf(stderr, "run_prompt: cannot write %s\n", path); return -1; }
    if (r9bs_write_header_ver(fp, R9BS_VERSION_S32)) goto bad;
    if (logits) {
        if (r9bs_write_s32(fp, "LOGITS", 0, -1, logits, (uint32_t)n_vocab,
                           (int)lexp)) goto bad;
    }
    one = lexp;
    if (r9bs_write_s32(fp, "LOGIT_EXP", 0, -1, &one, 1, 0)) goto bad;
    one = (int32_t)argmax;
    if (r9bs_write_s32(fp, "TOKEN", 0, -1, &one, 1, 0)) goto bad;
    if (fclose(fp)) { fprintf(stderr, "run_prompt: short write on %s\n", path); return -1; }
    printf("dump       %s: %s, LOGIT_EXP %d, TOKEN %d (seam v%d)\n", path,
           logits ? "LOGITS S32 vector present"
                  : "NO LOGITS RECORD -- this card publishes no logits row",
           (int)lexp, argmax, card_version);
    return 0;
bad:
    fprintf(stderr, "run_prompt: write failed on %s\n", path);
    fclose(fp);
    return -1;
}

#include <time.h>
static double pl_now_wall(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
static double t_start;
static int g_embed_bias = 0;
static int embed_biased(void *user, int tok, int16_t *mant, int n_embd, int32_t *exp)
{
    int rc = pl_embed_mv4i(user, tok, mant, n_embd, exp);
    if (!rc) *exp += g_embed_bias;
    return rc;
}

int main(int argc, char **argv)
{
    t_start = pl_now_wall();
    const char *prompt_path = NULL, *ref_path = NULL, *qtk_path = NULL;
    const char *text = NULL;
    int stream = 0;
    int serial_prefill = 0;
    const char *xout_path = NULL;
    const char *mv4i_path = NULL, *manifest_path = NULL;
    const char *dtbl_path = NULL, *rel_path = NULL;
    uint32_t *dprog = NULL, *drel = NULL;
    int n_dprog = 0, n_drel = 0, want_v2 = 0;
    /* THE SECOND CARD (2026-09-21, two-card pipeline).  Given --dtbl2/--rel2,
     * the run goes through pl_pipeline: this card is card 0 (blocks 0..k-1,
     * no LM head) and the second is card 1 (the rest plus the head). */
    const char *dtbl2_path = NULL, *rel2_path = NULL, *manifest2_path = NULL;
    const char *dev2_prefix = "/dev/xdma1";
    uint32_t *dprog2 = NULL, *drel2 = NULL;
    int n_dprog2 = 0, n_drel2 = 0;
    char dev2_user[256], dev2_h2c[256], dev2_c2h[256];
    fk33_sim_opts sim2;
    pl_open_opts o2;
    pl_ctx *c2 = NULL;
    plp_ctx *pp = NULL;
    const char *dump_path = NULL;
    int max_new = 0, max_chunk = 0, check_argmax = 0, quiet = 0;
    int teeth_bias = 0;
    long sim_kv_maxpos = 0;
    const char *hw_token = NULL;
    int open_only = 0, go_timeout_ms = 0, resume = 0, seq_reset = 0;
    int x_exp_bias = 0;
    int stop_id = QWEN35_EOS, stop_given = 0;
    int *prompt = NULL, *ref = NULL, *got = NULL;
    int n_prompt = 0, n_ref = 0, n_got = 0, cap_got = 0;
    int32_t *logits = NULL;
    qwen35_tok *tok = NULL;
    pl_embed_mv4i_t *emb = NULL;
    fk33_sim_opts sim;
    pl_open_opts o;
    pl_ctx *c = NULL;
    int n_vocab = 0, rc = 0, i, first_div = -1, stopped = 0, status = 0;
    int mismatches = 0;
    unsigned long long h2c0, c2h0;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEXT(dst) do { if (++i >= argc) { usage(); return 2; } dst = argv[i]; } while (0)
        if      (!strcmp(a, "--prompt"))       NEXT(prompt_path);
        else if (!strcmp(a, "--text"))         NEXT(text);
        else if (!strcmp(a, "--stream"))       stream = 1;
        else if (!strcmp(a, "--serial-prefill")) serial_prefill = 1;
        else if (!strcmp(a, "--reference"))    NEXT(ref_path);
        else if (!strcmp(a, "--qtk"))          NEXT(qtk_path);
        else if (!strcmp(a, "--mv4i"))         NEXT(mv4i_path);
        else if (!strcmp(a, "--manifest"))     NEXT(manifest_path);
        else if (!strcmp(a, "--dtbl"))         NEXT(dtbl_path);
        else if (!strcmp(a, "--rel"))          NEXT(rel_path);
        else if (!strcmp(a, "--dtbl2"))        NEXT(dtbl2_path);
        else if (!strcmp(a, "--rel2"))         NEXT(rel2_path);
        else if (!strcmp(a, "--manifest2"))    NEXT(manifest2_path);
        else if (!strcmp(a, "--dev2"))         NEXT(dev2_prefix);
        else if (!strcmp(a, "--v2"))           want_v2 = 1;
        else if (!strcmp(a, "--max-new"))    { const char *s; NEXT(s); max_new = atoi(s); }
        else if (!strcmp(a, "--max-chunk"))  { const char *s; NEXT(s); max_chunk = atoi(s); }
        else if (!strcmp(a, "--stop"))       { const char *s; NEXT(s); stop_id = atoi(s); stop_given = 1; }
        else if (!strcmp(a, "--check-argmax")) check_argmax = 1;
        else if (!strcmp(a, "--dump-logits"))  NEXT(dump_path);
        else if (!strcmp(a, "--dump-xout"))    NEXT(xout_path);
        else if (!strcmp(a, "--teeth-argmax")) { const char *s2; NEXT(s2); teeth_bias = atoi(s2); }
        else if (!strcmp(a, "--sim-kv-maxpos")) { const char *s2; NEXT(s2); sim_kv_maxpos = atol(s2); }
        else if (!strcmp(a, "--quiet"))        quiet = 1;
        else if (!strcmp(a, "--allow-hardware")) NEXT(hw_token);
        else if (!strcmp(a, "--open-only"))    open_only = 1;
        else if (!strcmp(a, "--resume"))       resume = 1;
        else if (!strcmp(a, "--seq-reset"))    seq_reset = 1;
        else if (!strcmp(a, "--x-exp-bias"))   { const char *s; NEXT(s); x_exp_bias = atoi(s); }
        else if (!strcmp(a, "--go-timeout-ms")) { const char *s; NEXT(s); go_timeout_ms = atoi(s); }
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
        else { fprintf(stderr, "run_prompt: unknown argument %s\n", a); usage(); return 2; }
        #undef NEXT
    }
    if (!prompt_path && !text) { usage(); return 2; }
    if (text && !qtk_path) { fprintf(stderr, "run_prompt: --text needs --qtk\n"); return 2; }

    if (text) {
        /* ONE user message, add_generation_prompt = 1, enable_thinking = 0:
         * the exact rendering hw/fk33/results/goal_dcdc_2026-09-17 was
         * produced from (prompt_rendered.txt), tokenized with parse_special
         * so the control tokens become single ids (23 for that prompt, not
         * the 31 a text-level tokenizer gives). */
        qwen35_chat_msg m;
        qwen35_tok *tk = qwen35_tok_open(qtk_path);
        int need = 0, n;
        if (!tk) return 2;
        memset(&m, 0, sizeof m);
        m.role = QWEN35_ROLE_USER; m.content = text; m.content_len = strlen(text);
        n = qwen35_chat_tokenize(tk, &m, 1, 1, 0, NULL, 0, &need);
        if (n != QWEN35_CHAT_E_SHORT || need <= 0) {
            fprintf(stderr, "run_prompt: the chat template refused the text (%d)\n", n);
            qwen35_tok_free(tk); return 2;
        }
        prompt = (int *)malloc((size_t)need * sizeof *prompt);
        if (!prompt) { qwen35_tok_free(tk); return 2; }
        n_prompt = qwen35_chat_tokenize(tk, &m, 1, 1, 0, prompt, need, NULL);
        qwen35_tok_free(tk);
        if (n_prompt <= 0) { fprintf(stderr, "run_prompt: tokenize returned %d\n", n_prompt); free(prompt); return 2; }
        printf("text       %d ids from the chat template (thinking off)\n", n_prompt);
    } else {
        n_prompt = read_ids(prompt_path, &prompt);
        if (n_prompt <= 0) { fprintf(stderr, "run_prompt: no ids in %s\n", prompt_path); return 2; }
    }
    if (ref_path) {
        n_ref = read_ids(ref_path, &ref);
        if (n_ref < 0) { free(prompt); return 2; }
    }
    if (max_new <= 0) max_new = n_ref > 0 ? n_ref : 256;

    if (qtk_path) {
        tok = qwen35_tok_open(qtk_path);
        if (!tok) { free(prompt); free(ref); return 2; }
        if (!stop_given) {
            int e = qwen35_tok_eos(tok);
            if (e >= 0 && e != stop_id) {
                printf("NOTE the tokenizer's eos is %d, not the compiled-in %d;"
                       " using the tokenizer's\n", e, stop_id);
                stop_id = e;
            }
        }
    }

    if (mv4i_path) {
        if (pl_embed_mv4i_open(mv4i_path, PL_EMBED_RECIPE_WIDE, &emb) != 0 || !emb) {
            fprintf(stderr, "run_prompt: the packed embedding would not open\n");
            status = 2; goto done;
        }
        printf("embedding  %s\n", pl_embed_mv4i_describe(emb));
    }

    if (want_v2) {
        /* THE REAL PROGRAM, from tools/gen_layer_program.py --token.  The
         * point of driving the sim with it rather than with a synthetic one
         * is that the SIZES are the card's: 505 descriptors is what
         * rtl/fk33_seam.vhd:123-125 predicts and what its windows are sized
         * for, and a program that does not fit here does not fit there. */
        if (!dtbl_path || !rel_path) {
            fprintf(stderr, "run_prompt: --v2 needs --dtbl and --rel\n");
            status = 2; goto done;
        }
        n_dprog = pl_load_hex_words(dtbl_path, PL_FMT_HEX64, &dprog);
        n_drel  = pl_load_hex_words(rel_path, PL_FMT_BIN, &drel);
        if (n_dprog <= 0 || n_drel <= 0) { status = 2; goto done; }
        printf("program    %s: %d 32-bit halves (%d descriptors of 8 64-bit "
               "words)\n", dtbl_path, n_dprog, n_dprog / 16);
        printf("release    %s: %d entries\n", rel_path, n_drel);
        if (dtbl2_path || rel2_path || manifest2_path) {
            if (!dtbl2_path || !rel2_path || !manifest2_path) {
                fprintf(stderr, "run_prompt: a second card needs --dtbl2, --rel2 AND --manifest2\n");
                status = 2; goto done;
            }
            n_dprog2 = pl_load_hex_words(dtbl2_path, PL_FMT_HEX64, &dprog2);
            n_drel2  = pl_load_hex_words(rel2_path, PL_FMT_BIN, &drel2);
            if (n_dprog2 <= 0 || n_drel2 <= 0) { status = 2; goto done; }
            printf("program2   %s: %d 32-bit halves (%d descriptors)\n", dtbl2_path, n_dprog2, n_dprog2 / 16);
            printf("release2   %s: %d entries\n", rel2_path, n_drel2);
        }
    } else if (dtbl2_path) {
        fprintf(stderr, "run_prompt: --dtbl2 needs --v2\n");
        status = 2; goto done;
    }

    fk33_sim_opts_default(&sim);
    if (teeth_bias) {
        sim.fault_argmax_bias = teeth_bias;
        printf("TEETH      the sim will bias BOTH the row header's argmax and"
               " the register by %d; %s\n", teeth_bias,
               check_argmax ? "--check-argmax must fire"
                            : "ATTRIBUTION CONTROL: the row scan is OFF, so"
                              " nothing should complain");
    }
    if (sim_kv_maxpos > 0) {
        sim.kv_maxpos = (uint32_t)sim_kv_maxpos;
        printf("sim        KV_MAXPOS %ld: pl_open lays K and V regions of "
               "%ld * kv_bytes_per_token/2 each at the manifest's kv_base\n",
               sim_kv_maxpos, sim_kv_maxpos);
    }
    pl_open_opts_default(&o);
    o.sim_opts = &sim;                 /* simulated transport; see the header */
    if (hw_token) {
        /* The operator's word, packed big-endian: "HOST" -> 0x484F5354.  No
         * constant from fk33_transport.h appears here on purpose; if the word
         * is wrong the transport refuses and says why. */
        size_t n = strlen(hw_token);
        uint32_t tok32 = 0;
        size_t k;
        if (n != 4) {
            fprintf(stderr, "run_prompt: --allow-hardware takes the transport's"
                            " four-letter token, got %zu characters\n", n);
            status = 2; goto done;
        }
        for (k = 0; k < 4; k++) tok32 = (tok32 << 8) | (uint8_t)hw_token[k];
        o.transport = PL_TRANSPORT_CHARDEV;
        o.allow_hardware = tok32;
        if (teeth_bias) {
            fprintf(stderr, "run_prompt: --teeth-argmax is a sim self-test and"
                            " cannot be combined with --allow-hardware\n");
            status = 2; goto done;
        }
        printf("transport  /dev/xdma0_user + h2c_0/c2h_0 (LIVE CARD, operator"
               " token supplied)\n");
    }
    if (go_timeout_ms > 0) o.go_timeout_ms = go_timeout_ms;
    if (want_v2) {
        sim.version = 2;
        o.desc_prog = dprog; o.desc_words = n_dprog;
        o.rel_tbl   = drel;  o.rel_words  = n_drel;
        o.tbl_len   = n_drel;          /* one release entry per descriptor */
    }
    if (manifest_path) o.manifest_path = manifest_path;
    if (emb) { o.embed = pl_embed_mv4i; o.embed_user = emb; }
    if (x_exp_bias) {
        /* A PROBE, 2026-09-19: hand the card the SAME mantissas with a
         * different block exponent, so X's value is scaled by 2^-bias while
         * rmsnorm (scale-free) keeps XN, and so B, ER, identical.  The one
         * thing that changes is the residual's alignment gap between X and
         * ER, which is what the card's first wrong step exercised and every
         * matching probe did not. */
        if (!emb) { fprintf(stderr, "run_prompt: --x-exp-bias needs --mv4i\n"); status = 2; goto done; }
        g_embed_bias = x_exp_bias;
        o.embed = embed_biased;
        printf("x-exp-bias %+d applied to the host X exponent (a probe)\n", x_exp_bias);
    }
    if (max_chunk > 0) o.max_chunk = (uint32_t)max_chunk;

    if (pl_open(&o, &c) != 0 || !c) {
        fprintf(stderr, "run_prompt: pl_open refused the layout\n");
        status = 1; goto done;
    }
    printf("card       %s\n", pl_describe(c));
    if (dtbl2_path) {
        /* Card 1: the same options with its own program, manifest and devices.
         * The embedding provider is never called on it (pl_decode_row bypasses
         * it) but pl_open requires one, so card 0's is reused. */
        sim2 = sim;
        o2 = o;
        o2.sim_opts = &sim2;
        o2.desc_prog = dprog2; o2.desc_words = n_dprog2;
        o2.rel_tbl   = drel2;  o2.rel_words  = n_drel2;
        o2.tbl_len   = n_drel2;
        o2.manifest_path = manifest2_path;
        if (hw_token) {
            snprintf(dev2_user, sizeof dev2_user, "%s_user",  dev2_prefix);
            snprintf(dev2_h2c,  sizeof dev2_h2c,  "%s_h2c_0", dev2_prefix);
            snprintf(dev2_c2h,  sizeof dev2_c2h,  "%s_c2h_0", dev2_prefix);
            o2.dev_user = dev2_user; o2.dev_h2c = dev2_h2c; o2.dev_c2h = dev2_c2h;
            printf("transport2 %s_user + h2c_0/c2h_0 (LIVE CARD 1)\n", dev2_prefix);
        }
        if (pl_open(&o2, &c2) != 0 || !c2) {
            fprintf(stderr, "run_prompt: pl_open refused card 1\n");
            status = 2; goto done;
        }
        printf("card2      %s\n", pl_describe(c2));
        if (plp_open(c, c2, &pp) != 0 || !pp) {
            fprintf(stderr, "run_prompt: plp_open refused the pair (versions or n_embd differ)\n");
            status = 2; goto done;
        }
        plp_set_serial(pp, serial_prefill);
        if (resume) {
            fprintf(stderr, "run_prompt: --resume is not supported across two cards\n");
            status = 2; goto done;
        }
        printf("pipeline   card 0 -> host (R_X + exponent) -> card 1; card 1's argmax decides\n");
    }
    if (seq_reset) {
        /* The SEAM's position only.  The card's own tok_pos (attention
         * history, B's tk0) is NOT reset by this; only a reconfiguration
         * does that.  Fine for a probe program that never reaches C or B. */
        int r = pp ? plp_seq_reset(pp) : pl_seq_reset(c);
        if (r == 0)
            printf("seq-reset  seam AND engine positions cleared (TOK_POS "
                   "read back 0): the next token is a first token\n");
        else if (r == 1)
            printf("seq-reset  SEAM ONLY (rc 1): this bitstream cannot reset "
                   "the engine's tok_pos; the next token is a first token "
                   "only if the card was reconfigured since its last one\n");
        else
            printf("seq-reset  FAILED rc %d (see stderr)\n", r);
    }
    if (resume) {
        int p = pl_resume_pos(c);
        printf("resume     continuing at the card's position %d (the ids below "
               "are appended to its history)\n", p);
    }
    if (open_only) {
        printf("OPEN_ONLY  program streamed and read back, bases written, no GO"
               " issued.  h2c %llu B, c2h %llu B.\n",
               (unsigned long long)pl_bytes_to_card(c),
               (unsigned long long)pl_bytes_from_card(c));
        status = 0; goto done;
    }
    n_vocab = pl_n_vocab(c);
    if (tok && pl_check_vocab(c, qwen35_tok_n_vocab(tok)) != 0) {
        printf("NOTE the card's n_vocab %d and the tokenizer's %d disagree\n",
               n_vocab, qwen35_tok_n_vocab(tok));
    }
    /* THE DUMP NEEDS THE ROW, AND ON A v2 CARD THERE IS NO ROW TO NEED.
     * Decided here, BEFORE the GO, so the refusal names the contract version
     * rather than arriving as pl_prefill returning -1 after a token of work.
     * pl_backend.c:1243 is the authority; this only reads pl_version(). */
    if (dump_path && pl_version(c) >= 2) {
        printf("dump       NOTE seam v%d publishes no logits row (rtl/"
               "fk33_seam.vhd:91-94: \"It does NOT return %d s32 logits\").\n"
               "           The dump will carry LOGIT_EXP and TOKEN only, and"
               " logit_compare.py will report every\n"
               "           vector section as UNAVAILABLE.  A full vector needs"
               " a bitstream with the logits DMA.\n",
               pl_version(c), n_vocab);
    }
    if (check_argmax || (dump_path && pl_version(c) < 2)) {
        logits = (int32_t *)malloc((size_t)n_vocab * sizeof *logits);
        if (!logits) { status = 1; goto done; }
    }

    h2c0 = (unsigned long long)pl_bytes_to_card(c);
    c2h0 = (unsigned long long)pl_bytes_from_card(c);

    /* ------------------------------------------------------------- prefill */
    {
        int argmax = -1;
        int32_t lexp = 0;
        rc = pp ? plp_prefill(pp, prompt, n_prompt, &argmax)
                : pl_prefill(c, prompt, n_prompt, logits, &lexp, &argmax);
        if (rc != n_prompt) {
            uint32_t info = pl_last_error_info(c);
            fprintf(stderr, "run_prompt: prefill returned %d for %d ids (%s)\n",
                    rc, n_prompt, pl_last_error_str(c));
            if (pl_last_error(c) == FK33_SEAM_ERR_DESC)
                /* rtl/fk33_seam.vhd:921: D code [3:0], step [14:4], done [26:16].
                 * D codes, rtl/seq_desc_fetch.vhd:263: 1 UNIT 2 LOCK 3 DESC
                 * 4 WDOG 5 GRANT 6 CTX 7 EPOCH 8 ABORT. */
                fprintf(stderr, "  ERR_INFO 0x%08X: D code %u, at step %u, "
                                "%u descriptors completed before it%s\n",
                        info, info & 0xFu, (info >> 4) & 0x7FFu,
                        (info >> 16) & 0x7FFu,
                        (info & 0xFu) == 4 ? "  (WDOG: the GO was accepted; a "
                        "unit did not finish within WDOG_LIMIT)" : "");
            status = 1; goto done;
        }
        if (check_argmax) {
            int host = argmax_of(logits, n_vocab);
            if (host != argmax) {
                printf("ARGMAX MISMATCH at prefill: card %d, host %d\n", argmax, host);
                mismatches++;
            }
        }
        printf("prefill    %d ids, pos %d, first argmax %d, exp %d\n",
               rc, pl_seq_pos(c), argmax, (int)lexp);
        /* TOKEN 0 IS THIS POSITION AND ONLY THIS POSITION.  Every later
         * position depends on the card's own previous choice, so a reference
         * and a card that disagree once are no longer running the same
         * sequence and a vector comparison there measures two different
         * inputs.  The dump is written here and nowhere else. */
        if (dump_path
            && dump_token0(dump_path, logits, n_vocab, lexp, argmax,
                           pl_version(c)) != 0) {
            status = 1; goto done;
        }
        cap_got = max_new;
        got = (int *)malloc((size_t)cap_got * sizeof *got);
        if (!got) { status = 1; goto done; }
        got[n_got++] = argmax;
        if (argmax == stop_id) stopped = 1;
        if (stream && tok) {
            char pb[256]; int pl = qwen35_tok_piece(tok, argmax, pb, sizeof pb, 0);
            if (pl > 0) { fwrite(pb, 1, (size_t)pl, stdout); fflush(stdout); }
        }
    }

    /* -------------------------------------------------------------- decode */
    while (!stopped && n_got < max_new) {
        int argmax = -1;
        int32_t lexp = 0;
        int fed = got[n_got - 1];
        rc = pp ? plp_decode(pp, fed, &argmax)
                : pl_decode(c, fed, logits, &lexp, &argmax);
        if (rc != 1) {
            fprintf(stderr, "run_prompt: decode %d returned %d (%s)\n",
                    n_got, rc, pl_last_error_str(c));
            status = 1; goto done;
        }
        if (check_argmax) {
            int host = argmax_of(logits, n_vocab);
            if (host != argmax) {
                printf("ARGMAX MISMATCH at position %d: card %d, host %d\n",
                       n_got, argmax, host);
                mismatches++;
            }
        }
        got[n_got++] = argmax;
        if (argmax == stop_id) stopped = 1;
        if (stream && tok) {
            char pb[256]; int pl = qwen35_tok_piece(tok, argmax, pb, sizeof pb, 0);
            if (pl > 0) { fwrite(pb, 1, (size_t)pl, stdout); fflush(stdout); }
        }
    }
    if (stream) { printf("\n"); fflush(stdout); }

    printf("decode     %d ids generated, pos %d, stopped %s\n",
           n_got, pl_seq_pos(c), stopped ? "on the stop token" : "at --max-new");
    {
        double tp = 0, tw = 0, tg = 0; unsigned long np = 0;
        pl_host_timing(&tp, &tw, &tg, &np);
        printf("timing     %d GOs: run_chunk %.3f s (of which STATUS wait %.3f s over %lu polls), "
               "X pushes %.3f s, wall since start %.3f s\n",
               (int)(pl_go_count(c)), tg, tw, np, tp, pl_now_wall() - t_start);
    }
    if (xout_path) {
        /* THE RESIDUAL, READ BACK THROUGH THE SEAM (2026-09-22).  On one
         * card this is the row the two-card hop would carry, and it can be
         * checked against the reference stream's R_X-<last block> record
         * (mantissas AND exponent) with no second card present. */
        int n = pl_n_embd(c);
        int16_t *m = (int16_t *)calloc((size_t)n, sizeof(int16_t));
        int32_t xe = 0;
        int rc2 = m ? pl_read_xout(pp ? c : c, m, &xe) : -1;
        if (rc2 == 0) {
            FILE *xf = fopen(xout_path, "w");
            if (xf) {
                int i;
                fprintf(xf, "exp %d\n", (int)xe);
                for (i = 0; i < n; i++) fprintf(xf, "%d\n", (int)m[i]);
                fclose(xf);
                printf("xout       R_X after the last GO: exp %d, %d mantissas -> %s\n", (int)xe, n, xout_path);
            } else { fprintf(stderr, "run_prompt: cannot write %s\n", xout_path); status = 2; }
        } else {
            fprintf(stderr, "run_prompt: --dump-xout: pl_read_xout returned %d (%s)\n", rc2,
                    rc2 == -1 ? "no FK33_CAP_XEXP_OUT on this card, or a GO is pending" : "transport");
            status = 2;
        }
        free(m);
    }
    if (pp) {
        double hr = 0, hw = 0; unsigned long hops = 0;
        plp_hop_timing(&hr, &hw, &hops);
        printf("hop        %lu hops: read R_X %.3f s, push+GO card 1 %.3f s; card 1 at pos %d; prefill %s\n",
               hops, hr, hw, plp_seq_pos(pp), plp_serial(pp) ? "serial" : "overlapped");
    }
    printf("bytes      h2c %llu, c2h %llu, go %llu (%s)\n",
           (unsigned long long)pl_bytes_to_card(c) - h2c0,
           (unsigned long long)pl_bytes_from_card(c) - c2h0,
           (unsigned long long)pl_go_count(c),
           logits ? "full logits row per position" : "argmax fast path");

    /* --------------------------------------------------- first divergence */
    if (ref) {
        int n = n_got < n_ref ? n_got : n_ref;
        for (i = 0; i < n; i++) if (got[i] != ref[i]) { first_div = i; break; }
        if (first_div < 0 && n_got != n_ref) first_div = n;
        if (first_div < 0) {
            printf("MATCH      all %d ids equal the reference\n", n_got);
        } else {
            printf("FIRST DIVERGENCE at %d of %d reference ids: ", first_div, n_ref);
            if (first_div < n_got && first_div < n_ref)
                printf("got %d, expected %d\n", got[first_div], ref[first_div]);
            else if (first_div >= n_got)
                printf("ran out of generated ids (expected %d)\n", ref[first_div]);
            else
                printf("ran past the reference (got %d)\n", got[first_div]);
            status = 1;
        }
        if (!quiet && first_div > 0) {
            int lo = first_div > 8 ? first_div - 8 : 0;
            printf("           matched through: ");
            for (i = lo; i < first_div; i++) printf("%d ", got[i]);
            printf("\n");
        }
    }

    /* ---------------------------------------------------------- the answer */
    if (tok && !quiet) {
        int need = n_got;
        int keep = (n_got > 0 && got[n_got - 1] == stop_id) ? n_got - 1 : n_got;
        char *buf = (char *)malloc((size_t)need * 64 + 64);
        if (buf) {
            int len = qwen35_tok_decode(tok, got, keep, buf, need * 64 + 64, 0);
            if (len >= 0) printf("---- generated ----\n%.*s\n-------------------\n",
                                 len, buf);
            free(buf);
        }
    }

    if (check_argmax)
        printf("argmax     %d mismatch(es) between the card's register and the"
               " host's scan of the returned row\n", mismatches);
    if (teeth_bias && check_argmax) {
        /* The teeth run INVERTS the verdict: silence here is the failure. */
        if (mismatches > 0) {
            printf("TEETH PASS the check fired %d time(s) under"
                   " fault_argmax_bias\n", mismatches);
            status = 0;
        } else {
            printf("TEETH FAIL the check was silent under fault_argmax_bias;"
                   " it does not discriminate\n");
            status = 1;
        }
    } else if (teeth_bias) {
        /* The ATTRIBUTION CONTROL: the same mutant with the row scan OFF.  If
         * the run completes clean, no OTHER check in this stack sees it, and
         * the kill above belongs to the row scan rather than to pl_backend's
         * pre-existing header-against-register comparison. */
        printf("TEETH CONTROL the mutant ran with --check-argmax OFF and the"
               " stack reported %s\n",
               status ? "an error (the kill is NOT the row scan's)"
                      : "nothing (the kill belongs to the row scan)");
        if (!status) status = 0;
    } else if (mismatches) {
        status = 1;
    }

done:
    if (pp)  plp_close(pp);
    if (c2)  pl_close(c2);
    if (c)   pl_close(c);
    if (emb) pl_embed_mv4i_close(emb);
    if (tok) qwen35_tok_free(tok);
    free(logits); free(prompt); free(ref); free(got);
    free(dprog); free(drel); free(dprog2); free(drel2);
    return status;
}
