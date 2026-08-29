/* server/tests/embed_e2e.c -- the two things this track changed, shown working
 * and shown REFUSING, on the real artefacts.
 *
 *   1. the real embedding provider (server/embed_mv4i.c) driving the real host
 *      seam (server/pl_backend.c) against the SIMULATED card, so the plumbing
 *      from a token id to a DMA'd activation block is executed end to end with
 *      real weight bytes;
 *   2. the base-address fix: bases DERIVED from the loaded set's manifest, and
 *      the three constants that shipped (0x00E0000000 / 0x00E1000000 /
 *      0x00E2000000) REFUSED against that same manifest because they sit inside
 *      the weight image.
 *
 * WHAT THIS DOES NOT SHOW.  The card's logits here are `fk33_sim.c`'s synthetic
 * function of (position, token id, activation).  They are plumbing, not
 * inference, and no token printed by this file means anything.  What IS real is
 * the embedding row: it is gathered from the packed tensor by the same code a
 * driver would use, and it is checked bit-for-bit against two independent
 * decoders and a BF16 oracle by tools/check_embed_c.py, not here.
 *
 * NO HARDWARE.  PL_TRANSPORT_SIM only; this file never names a /dev path.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../pl_backend.h"
#include "../fk33_seam.h"
#include "../fk33_manifest.h"
#include "../embed_mv4i.h"
#include "../embed_bf16.h"

static int fails;
#define CK(cond, ...) do { if (!(cond)) { \
    printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

/* The three constants that shipped in pl_open_opts_default before 2026-08-29. */
#define OLD_X 0x00E0000000ull
#define OLD_L 0x00E1000000ull
#define OLD_D 0x00E2000000ull

int main(int argc, char **argv)
{
    const char *mv4i = NULL, *manifest = NULL, *gguf = NULL;
    fk33_manifest man;
    pl_hbm_bases b;
    char mbuf[700];
    int i, rc;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mv4i") && i + 1 < argc) mv4i = argv[++i];
        else if (!strcmp(argv[i], "--manifest") && i + 1 < argc) manifest = argv[++i];
        else if (!strcmp(argv[i], "--gguf") && i + 1 < argc) gguf = argv[++i];
        else { fprintf(stderr, "usage: embed_e2e --mv4i F.mv4i --manifest M.json "
                               "[--gguf G.gguf]\n");
               return 2; }
    }
    if (!mv4i || !manifest) {
        fprintf(stderr, "embed_e2e: --mv4i and --manifest are both required\n");
        return 2;
    }

    /* ------------------------------------------------------------- part 2 */
    printf("A  the manifest, read by server/fk33_manifest.c\n");
    CK(fk33_manifest_read(manifest, &man) == 0, "the manifest was refused");
    if (fails) return 1;
    printf("   %s\n", fk33_manifest_describe(&man, mbuf, sizeof mbuf));

    printf("B  the OLD hardcoded bases against THIS image\n");
    printf("   x 0x%011llX  l 0x%011llX  desc 0x%011llX\n",
           OLD_X, OLD_L, OLD_D);
    printf("   the card owns everything below 0x%011llX\n",
           (unsigned long long)man.reserved_end);
    CK(OLD_X < man.reserved_end && OLD_L < man.reserved_end
       && OLD_D < man.reserved_end,
       "the old constants are NOT inside this image -- the premise moved");
    printf("   all three are inside it: %s\n",
           (OLD_X < man.reserved_end) ? "yes" : "no");

    printf("C  the derivation, from the shape and hbm.size alone\n");
    rc = pl_derive_bases(4096, 248320, 512, man.size, man.reserved_end,
                         man.kv_bytes_per_token, &b);
    CK(rc == 0, "the derivation refused the 9B shape on this image (code %d)", rc);
    printf("   x    0x%011llX  span %llu\n",
           (unsigned long long)b.x_base, (unsigned long long)b.x_span);
    printf("   l    0x%011llX  span %llu\n",
           (unsigned long long)b.l_base, (unsigned long long)b.l_span);
    printf("   desc 0x%011llX  span %llu\n",
           (unsigned long long)b.desc_ptr, (unsigned long long)b.desc_span);
    printf("   costs %llu tokens of KV at %llu B/token (max_ctx %llu -> %llu)\n",
           (unsigned long long)b.kv_tokens_cost,
           (unsigned long long)man.kv_bytes_per_token,
           (unsigned long long)man.max_context_tokens,
           (unsigned long long)(man.max_context_tokens - b.kv_tokens_cost));
    CK(b.x_base >= man.reserved_end, "the derived x_base is inside the image");
    CK(b.x_base >= FK33_HBM_STACK_LINE, "the derived blocks straddle the stack line");

    /* ------------------------------------------------------------- part 1 */
    {
        pl_embed_mv4i_t *e = NULL;
        fk33_sim_opts s;
        pl_open_opts o;
        pl_ctx *c = NULL;
        int ids[5] = { 760, 6511, 314, 9338, 369 };   /* run9b's reference prompt */
        int argmax = -1;
        int32_t lexp = 0;
        unsigned long long h2c_mv4i = 0;

        printf("D  the real provider driving the real seam (simulated card)\n");
        CK(pl_embed_mv4i_open(mv4i, PL_EMBED_RECIPE_WIDE, &e) == 0,
           "the packed embedding would not open");
        if (!e) return 1;
        printf("   %s\n", pl_embed_mv4i_describe(e));

        fk33_sim_opts_default(&s);
        pl_open_opts_default(&o);
        o.sim_opts = &s;
        o.manifest_path = manifest;
        o.embed = pl_embed_mv4i;
        o.embed_user = e;
        o.max_chunk = 8;

        CK(pl_open(&o, &c) == 0, "pl_open refused the derived layout");
        if (!c) { pl_embed_mv4i_close(e); return 1; }
        printf("   %s\n", pl_describe(c));
        CK(pl_n_embd(c) == pl_embed_mv4i_n_embd(e),
           "the card's n_embd %d and the tensor's K %d disagree",
           pl_n_embd(c), pl_embed_mv4i_n_embd(e));
        CK(pl_n_vocab(c) == pl_embed_mv4i_n_vocab(e),
           "the card's n_vocab %d and the tensor's M %d disagree",
           pl_n_vocab(c), pl_embed_mv4i_n_vocab(e));

        rc = pl_prefill(c, ids, 5, NULL, &lexp, &argmax);
        CK(rc == 5, "prefill returned %d", rc);
        printf("   prefilled 5, pos %d, argmax %d (SYNTHETIC logits: meaningless)\n",
               pl_seq_pos(c), argmax);
        printf("   H2C %llu B for %llu GOs; the provider read %llu B in %llu gathers\n",
               (unsigned long long)pl_bytes_to_card(c),
               (unsigned long long)pl_go_count(c),
               (unsigned long long)pl_embed_mv4i_bytes_read(e),
               (unsigned long long)pl_embed_mv4i_gathers(e));
        CK(pl_embed_mv4i_gathers(e) == 5, "5 tokens produced %llu gathers",
           (unsigned long long)pl_embed_mv4i_gathers(e));
        CK(pl_embed_mv4i_bytes_read(e) == 5ull * 2ull * 4096ull,
           "5 tokens read %llu bytes, want 5 * 2 * 4096",
           (unsigned long long)pl_embed_mv4i_bytes_read(e));
        CK(pl_bytes_to_card(c) == 5ull * fk33_x_stride(4096),
           "H2C was %llu B, want 5 * %llu",
           (unsigned long long)pl_bytes_to_card(c),
           (unsigned long long)fk33_x_stride(4096));
        h2c_mv4i = (unsigned long long)pl_bytes_to_card(c);
        pl_close(c); c = NULL;

        printf("D2 the BF16 provider driving the SAME seam, on the SAME tokens\n");
        if (!gguf) {
            printf("   SKIPPED: no --gguf given.  The BF16 provider is the one the\n"
                   "   reference now uses (ref/run9b --embed gguf, the default), so a\n"
                   "   run without it exercises only the superseded INT4 path.\n");
        } else {
            pl_embed_bf16_t *g = NULL;
            pl_ctx *c2 = NULL;
            fk33_sim_opts s2;
            pl_open_opts o2;
            int argmax2 = -1;
            int32_t lexp2 = 0;
            CK(pl_embed_bf16_open(gguf, NULL, &g) == 0,
               "the BF16 embedding would not open");
            if (g) {
                printf("   %s\n", pl_embed_bf16_describe(g));
                fk33_sim_opts_default(&s2);
                pl_open_opts_default(&o2);
                o2.sim_opts = &s2;
                o2.manifest_path = manifest;
                o2.embed = pl_embed_bf16;
                o2.embed_user = g;
                o2.max_chunk = 8;
                CK(pl_open(&o2, &c2) == 0, "pl_open refused the BF16 provider");
                if (c2) {
                    CK(pl_n_embd(c2) == pl_embed_bf16_n_embd(g),
                       "the card's n_embd %d and the tensor's ne0 %d disagree",
                       pl_n_embd(c2), pl_embed_bf16_n_embd(g));
                    CK(pl_n_vocab(c2) == pl_embed_bf16_n_vocab(g),
                       "the card's n_vocab %d and the tensor's ne1 %d disagree",
                       pl_n_vocab(c2), pl_embed_bf16_n_vocab(g));
                    rc = pl_prefill(c2, ids, 5, NULL, &lexp2, &argmax2);
                    CK(rc == 5, "BF16 prefill returned %d", rc);
                    printf("   prefilled 5, pos %d, argmax %d (SYNTHETIC logits: "
                           "meaningless)\n", pl_seq_pos(c2), argmax2);
                    printf("   H2C %llu B for %llu GOs; the provider read %llu B "
                           "in %llu gathers\n",
                           (unsigned long long)pl_bytes_to_card(c2),
                           (unsigned long long)pl_go_count(c2),
                           (unsigned long long)pl_embed_bf16_bytes_read(g),
                           (unsigned long long)pl_embed_bf16_gathers(g));
                    /* ONE contiguous read per token against the INT4 path's two,
                     * and the SAME number of bytes: 8,192 either way.  The H2C
                     * side is identical because the activation format did not
                     * change; only its accuracy did. */
                    CK(pl_embed_bf16_gathers(g) == 5,
                       "5 tokens produced %llu gathers, want 5 (one contiguous "
                       "read per token)",
                       (unsigned long long)pl_embed_bf16_gathers(g));
                    CK(pl_embed_bf16_bytes_read(g) == 5ull * 2ull * 4096ull,
                       "5 tokens read %llu bytes, want 5 * 2 * 4096",
                       (unsigned long long)pl_embed_bf16_bytes_read(g));
                    CK(pl_bytes_to_card(c2) == 5ull * fk33_x_stride(4096),
                       "H2C was %llu B, want 5 * %llu",
                       (unsigned long long)pl_bytes_to_card(c2),
                       (unsigned long long)fk33_x_stride(4096));
                    CK(pl_bytes_to_card(c2) == h2c_mv4i,
                       "the two providers moved different H2C byte counts: "
                       "%llu vs %llu",
                       (unsigned long long)pl_bytes_to_card(c2), h2c_mv4i);
                    /* AND THE ARGMAXES MUST DIFFER.  fk33_sim's logits are a
                     * function of the activation, so if the two providers
                     * produced the same argmax on all five positions this test
                     * would not be able to tell them apart at all, and every
                     * check above would be measuring plumbing only. */
                    CK(argmax2 != argmax,
                       "both providers gave argmax %d: this test cannot "
                       "distinguish them", argmax2);
                    pl_close(c2);
                }
                pl_embed_bf16_close(g);
            }
        }

        printf("E  the OLD x_base, offered to pl_open with this manifest\n");
        fk33_sim_opts_default(&s);
        pl_open_opts_default(&o);
        o.sim_opts = &s;
        o.manifest_path = manifest;
        o.embed = pl_embed_mv4i;
        o.embed_user = e;
        o.max_chunk = 8;
        o.x_base = OLD_X;
        rc = pl_open(&o, &c);
        CK(rc < 0, "the old x_base was ACCEPTED (rc %d)", rc);
        if (c) { pl_close(c); c = NULL; }

        printf("F  and the same offer with NO manifest, which cannot be checked\n");
        fk33_sim_opts_default(&s);
        pl_open_opts_default(&o);
        o.sim_opts = &s;
        o.embed = pl_embed_mv4i;
        o.embed_user = e;
        o.max_chunk = 8;
        o.x_base = OLD_X;
        o.l_base = OLD_L;
        o.desc_ptr = OLD_D;
        /* A DECLARED ARENA, because as of 2026-08-29 pl_check_bases() refuses
         * an incomplete layout and this control is not about the arena.  It is
         * about `reserved_end`: it asserts that E's refusal came from the
         * MANIFEST's knowledge of where the image ends and not from some new
         * constant.  Without this line the open would be refused for a third,
         * unrelated reason and the control would stop isolating what it names.
         * pl_place_desc_arena() puts it below the OLD_X given above. */
        o.desc_arena_bytes = 4096;
        rc = pl_open(&o, &c);
        CK(rc == 0, "the old bases were refused even with no image to compare "
                    "against (rc %d); the refusal must come from the manifest, "
                    "not from a new constant", rc);
        if (c) { pl_close(c); c = NULL; }

        pl_embed_mv4i_close(e);
    }

    printf("\nEMBED_E2E %s  (%d failed)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
