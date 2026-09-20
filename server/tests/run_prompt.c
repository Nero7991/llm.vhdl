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
 * Usage:
 *   run_prompt --prompt <ids.txt> [--reference <ids.txt>] [--max-new N]
 *              [--qtk <tokenizer.qtk>] [--mv4i <t.mv4i> --manifest <m.json>]
 *              [--check-argmax] [--max-chunk N] [--stop ID] [--quiet]
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
#include "../embed_mv4i.h"
#include "../qwen35_tok.h"
#include "../qwen35_chat.h"

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
      "                  [--mv4i <t.mv4i> --manifest <m.json>]\n"
      "                  [--max-chunk N] [--stop ID] [--quiet]\n"
      "                  [--v2 --dtbl <t.dtbl> --rel <t.rel>]  the window seam\n"
      "                  [--teeth-argmax N]   self-test of --check-argmax\n"
      "                  [--allow-hardware <TOKEN>]  /dev/xdma0_*; the operator\n"
      "                        types the transport's four-letter token\n"
      "                  [--open-only]        stream the program, write the\n"
      "                        bases, read WIN_ADDR back, then exit (no GO)\n"
      "                  [--go-timeout-ms N]  per-GO wait (default 60000)\n"
      "                  [--resume]           start at the card's SEQ_POS\n"
      "                  [--seq-reset]        clear the SEAM's position first\n"
      "Simulated transport unless --allow-hardware is given by a human.\n");
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
    const char *mv4i_path = NULL, *manifest_path = NULL;
    const char *dtbl_path = NULL, *rel_path = NULL;
    uint32_t *dprog = NULL, *drel = NULL;
    int n_dprog = 0, n_drel = 0, want_v2 = 0;
    int max_new = 0, max_chunk = 0, check_argmax = 0, quiet = 0;
    int teeth_bias = 0;
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
        else if (!strcmp(a, "--reference"))    NEXT(ref_path);
        else if (!strcmp(a, "--qtk"))          NEXT(qtk_path);
        else if (!strcmp(a, "--mv4i"))         NEXT(mv4i_path);
        else if (!strcmp(a, "--manifest"))     NEXT(manifest_path);
        else if (!strcmp(a, "--dtbl"))         NEXT(dtbl_path);
        else if (!strcmp(a, "--rel"))          NEXT(rel_path);
        else if (!strcmp(a, "--v2"))           want_v2 = 1;
        else if (!strcmp(a, "--max-new"))    { const char *s; NEXT(s); max_new = atoi(s); }
        else if (!strcmp(a, "--max-chunk"))  { const char *s; NEXT(s); max_chunk = atoi(s); }
        else if (!strcmp(a, "--stop"))       { const char *s; NEXT(s); stop_id = atoi(s); stop_given = 1; }
        else if (!strcmp(a, "--check-argmax")) check_argmax = 1;
        else if (!strcmp(a, "--teeth-argmax")) { const char *s2; NEXT(s2); teeth_bias = atoi(s2); }
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
    if (seq_reset) {
        /* The SEAM's position only.  The card's own tok_pos (attention
         * history, B's tk0) is NOT reset by this; only a reconfiguration
         * does that.  Fine for a probe program that never reaches C or B. */
        int r = pl_seq_reset(c);
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
    if (check_argmax) {
        logits = (int32_t *)malloc((size_t)n_vocab * sizeof *logits);
        if (!logits) { status = 1; goto done; }
    }

    h2c0 = (unsigned long long)pl_bytes_to_card(c);
    c2h0 = (unsigned long long)pl_bytes_from_card(c);

    /* ------------------------------------------------------------- prefill */
    {
        int argmax = -1;
        int32_t lexp = 0;
        rc = pl_prefill(c, prompt, n_prompt, logits, &lexp, &argmax);
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
        rc = pl_decode(c, fed, logits, &lexp, &argmax);
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
    if (c)   pl_close(c);
    if (emb) pl_embed_mv4i_close(emb);
    if (tok) qwen35_tok_free(tok);
    free(logits); free(prompt); free(ref); free(got);
    free(dprog); free(drel);
    return status;
}
