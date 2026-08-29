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

static int fails;
#define CK(cond, ...) do { if (!(cond)) { \
    printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

/* The three constants that shipped in pl_open_opts_default before 2026-08-29. */
#define OLD_X 0x00E0000000ull
#define OLD_L 0x00E1000000ull
#define OLD_D 0x00E2000000ull

int main(int argc, char **argv)
{
    const char *mv4i = NULL, *manifest = NULL;
    fk33_manifest man;
    pl_hbm_bases b;
    char mbuf[700];
    int i, rc;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mv4i") && i + 1 < argc) mv4i = argv[++i];
        else if (!strcmp(argv[i], "--manifest") && i + 1 < argc) manifest = argv[++i];
        else { fprintf(stderr, "usage: embed_e2e --mv4i F.mv4i --manifest M.json\n");
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
        pl_close(c); c = NULL;

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
