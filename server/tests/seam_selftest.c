/* server/tests/seam_selftest.c -- exercise the v2 host seam end to end against
 * the simulated card, and show every refusal firing.
 *
 * WHAT THIS PROVES, AND WHAT IT CANNOT
 * ------------------------------------
 * PROVES: the host's byte layouts, strides and DMA offsets agree with the
 *   card's; the polling discipline terminates on error as well as on done; the
 *   KV position bookkeeping tracks the card's; every FK33_SEAM_ERR_* refusal
 *   the contract states is actually reachable from the host API; and the
 *   hardware tripwire refuses a /dev path.
 *
 * CANNOT: say anything about whether a token is the right token.  The
 *   simulated card does not run a transformer and its logits are synthetic by
 *   construction (fk33_seam.h says so at length).  There is no whole-model 9B
 *   reference in this repository -- backlog item 12 -- so no test anywhere can
 *   make that claim today.
 *
 * CANNOT: say anything about the card.  Nothing here opens /dev/xdma*, and
 *   test 12 exists specifically to prove that the code REFUSES to.
 *
 * THE PLUMBING ORACLE, AND WHY IT IS NOT A ROUND TRIP
 * --------------------------------------------------
 * The simulated card's argmax is a published closed form over the WHOLE
 * sequence since the last reset:
 *     hist  = fnv1a chain over (token_id, position, fnv1a(x_mant)) per step
 *     pick  = (hist*31 + position*7 + fnv1a(x_mant)) mod n_vocab
 * The host never sends `pick`; it sends activation rows, and the card folds
 * THOSE ROWS, as it found them in HBM at its own computed addresses.  So the
 * test replays the same chain locally and compares against what came back
 * through the register and through the DMA'd header.  A wrong stride, a wrong
 * header size, a wrong slot offset, an endianness slip, a truncated write, a
 * dropped step or a reordered one all move the argmax.
 *
 * That is not a round trip: nothing decodes what this encoded.  It is a check
 * that two independently computed values of one quantity agree, where one path
 * goes through the whole transport and the other does not.  Tests 8 and 9
 * mutate the stride and the header size to show it has teeth.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../pl_backend.h"
#include "../pl_pipeline.h"
#include "../fk33_transport.h"
#include "../fk33_seam.h"

static int fails = 0, checks = 0;

#define CK(cond, ...) do {                                                    \
    checks++;                                                                 \
    if (!(cond)) { fails++; printf("  FAIL: "); printf(__VA_ARGS__);          \
                   printf("   (%s:%d)\n", __FILE__, __LINE__); }              \
} while (0)

/* A small shape, so a test runs in milliseconds instead of allocating a 1 MB
 * logits row per step.  The SHAPE is a test parameter; the LAYOUT RULES it
 * exercises are the same ones the 9B shape uses, because both come from
 * fk33_x_stride/fk33_l_stride. */
#define TV  257        /* vocab: prime, so a modulo bug is visible */
#define TE  96         /* embd:  not a multiple of 64, so the stride rounds */
#define TL  4
#define TC  64         /* ctx */

static void small_opts(fk33_sim_opts *s, pl_open_opts *o)
{
    fk33_sim_opts_default(s);
    s->n_vocab = TV; s->n_embd = TE; s->n_layer = TL; s->max_ctx = TC;
    s->max_chunk = 8;
    pl_open_opts_default(o);
    o->sim_opts = s;
    o->max_chunk = 8;
    o->go_timeout_ms = 200;
    o->embed = pl_embed_synthetic;
    /* A DECLARED SUBSYSTEM A DESCRIPTOR ARENA, required as of 2026-08-29.
     * pl_check_bases() no longer passes a layout that does not say where A's
     * descriptors live: an undeclared arena used to pass with a printed
     * warning, and TRACK ADDRARENA recorded that warning as the live hazard --
     * it is how gen_layer_program.py's top-down default sat on 153,664 B of
     * the logits row without anything refusing.  On the real path the number
     * comes from the manifest's hbm.desc_arena_bytes; here there is no
     * manifest, so the size is stated and pl_place_desc_arena() puts it below
     * x_base.  One page is ample for a test that runs no A jobs, and the point
     * is that the layout is COMPLETE, not that the size is right. */
    o->desc_arena_bytes = 4096;
}

/* The card's fold, recomputed here.  See the header block: this is the second
 * path to the same number, not a decoder for the first. */
static uint32_t fnv1a_i16(const int16_t *x, int n)
{
    uint32_t h = 2166136261u; int i;
    for (i = 0; i < n; i++) { h ^= (uint32_t)(uint16_t)x[i]; h *= 16777619u; }
    return h;
}

/* Replay the card's history chain over a whole sequence and return the argmax
 * of its LAST step.  `ids[i]` occupies position `first_pos + i`. */
static int expect_argmax_seq(const int *ids, int n, int first_pos,
                             int n_embd, int n_vocab)
{
    uint32_t hist = 2166136261u, fx = 0;
    int i;
    for (i = 0; i < n; i++) {
        int16_t mant[TE];
        int32_t exp = 0;
        pl_embed_synthetic(NULL, ids[i], mant, n_embd, &exp);
        fx = fnv1a_i16(mant, n_embd);
        hist = (hist ^ (uint32_t)ids[i])          * 16777619u;
        hist = (hist ^ (uint32_t)(first_pos + i)) * 16777619u;
        hist = (hist ^ fx)                        * 16777619u;
    }
    return (int)((hist * 31u + (uint32_t)(first_pos + n - 1) * 7u + fx)
                 % (uint32_t)n_vocab);
}

/* ------------------------------------------------------------------ tests */

static void t1_open_and_caps(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    printf("T1  open, identity, CAPS\n");
    small_opts(&s, &o);
    CK(pl_open(&o, &c) == 0, "pl_open failed");
    if (!c) return;
    CK(pl_n_vocab(c) == TV,  "n_vocab %d != %d", pl_n_vocab(c), TV);
    CK(pl_n_embd(c)  == TE,  "n_embd %d != %d",  pl_n_embd(c), TE);
    CK(pl_n_layer(c) == TL,  "n_layer %d != %d", pl_n_layer(c), TL);
    CK(pl_max_ctx(c) == TC,  "max_ctx %d != %d", pl_max_ctx(c), TC);
    CK(pl_seq_pos(c) == 0,   "seq_pos %d != 0",  pl_seq_pos(c));
    /* 16 + 2*96 = 208 -> 256;  16 + 4*257 = 1044 -> 1088 */
    CK(fk33_x_stride(TE) == 256,  "x_stride %llu", (unsigned long long)fk33_x_stride(TE));
    CK(fk33_l_stride(TV) == 1088, "l_stride %llu", (unsigned long long)fk33_l_stride(TV));
    pl_close(c);
}

static void t2_wrong_seam_base(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    printf("T2  a wrong seam base is refused by the identity read\n");
    small_opts(&s, &o);
    o.seam_base = 0x4000;
    CK(pl_open(&o, &c) < 0, "pl_open accepted a seam base with nothing there");
    if (c) pl_close(c);
}

static void t3_prefill_decode(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    int ids[5] = { 11, 22, 33, 44, 55 };
    int am = -1; int32_t lexp = 0;
    int32_t *log = (int32_t *)malloc(TV * 4);
    printf("T3  prefill 5, decode 3; positions and argmax\n");
    small_opts(&s, &o);
    if (pl_open(&o, &c)) { free(log); CK(0, "open"); return; }

    CK(pl_prefill(c, ids, 5, log, &lexp, &am) == 5, "prefill did not advance 5");
    CK(pl_seq_pos(c) == 5, "seq_pos %d != 5", pl_seq_pos(c));
    /* The whole 5-token prefix, replayed.  Note this is NOT a function of the
     * last token alone: a prefill that dropped ids[2] would land here. */
    CK(am == expect_argmax_seq(ids, 5, 0, TE, TV),
       "prefill argmax %d != expected %d", am, expect_argmax_seq(ids, 5, 0, TE, TV));
    {
        int v, best = 0;
        for (v = 1; v < TV; v++) if (log[v] > log[best]) best = v;
        CK(best == am, "argmax of the DMA'd row %d != the register's %d", best, am);
    }

    {
        /* The running sequence, so the expectation is the whole prefix each
         * time.  A decode that reset the card's history would fail here. */
        int all[9] = { 11, 22, 33, 44, 55, 7, 8, 9, 12 };
        int t;
        for (t = 0; t < 3; t++) {
            CK(pl_decode(c, all[5 + t], log, &lexp, &am) == 1, "decode %d", t);
            CK(pl_seq_pos(c) == 6 + t, "seq_pos after decode %d", t);
            CK(am == expect_argmax_seq(all, 6 + t, 0, TE, TV),
               "decode %d argmax %d != %d", t, am,
               expect_argmax_seq(all, 6 + t, 0, TE, TV));
        }

        /* The greedy fast path: no logits buffer, so no C2H at all. */
        {
            uint64_t before = pl_bytes_from_card(c);
            CK(pl_decode(c, 12, NULL, NULL, &am) == 1, "greedy decode");
            CK(pl_bytes_from_card(c) == before,
               "the greedy path moved %llu bytes back; it must move none",
               (unsigned long long)(pl_bytes_from_card(c) - before));
            CK(am == expect_argmax_seq(all, 9, 0, TE, TV), "greedy argmax %d", am);
        }
    }

    CK(pl_seq_reset(c) == 0, "seq_reset");
    CK(pl_seq_pos(c) == 0, "seq_pos after reset");
    pl_close(c); free(log);
}

static void t4_chunking(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    int ids[20], i, am = -1;
    printf("T4  prefill longer than one chunk\n");
    for (i = 0; i < 20; i++) ids[i] = 100 + i;
    small_opts(&s, &o);
    if (pl_open(&o, &c)) { CK(0, "open"); return; }
    CK(pl_seq_reset(c) == 0, "seq_reset");
    CK(pl_prefill(c, ids, 20, NULL, NULL, &am) == 20, "prefill 20");
    CK(pl_seq_pos(c) == 20, "seq_pos %d != 20", pl_seq_pos(c));
    CK(pl_go_count(c) == 3, "20 tokens at chunk 8 should be 3 GOs, was %llu",
       (unsigned long long)pl_go_count(c));
    /* THE POINT OF THIS CASE: 20 tokens split across 3 GOs must give exactly
     * what 20 tokens in one GO would, so the chunk boundaries are invisible in
     * the answer.  Only a whole-prefix expectation can check that. */
    CK(am == expect_argmax_seq(ids, 20, 0, TE, TV), "chunked argmax %d", am);
    pl_close(c);
}

static void t5_context_full(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    int ids[TC + 1], i;
    printf("T5  a prefill past the KV capacity is refused before any DMA\n");
    for (i = 0; i <= TC; i++) ids[i] = i;
    small_opts(&s, &o);
    if (pl_open(&o, &c)) { CK(0, "open"); return; }
    CK(pl_prefill(c, ids, TC + 1, NULL, NULL, NULL) == -1,
       "prefill of ctx+1 was accepted");
    CK(pl_bytes_to_card(c) == 0, "it moved bytes before refusing");
    pl_close(c);
}

static void t6_layout_refusals(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    printf("T6  the four layout refusals, at open\n");

    /* The bases are DERIVED as of 2026-08-29, so these perturbations are taken
     * from the derivation rather than from the three constants that used to be
     * typed in (and that sat inside the weight image; see pl_backend.h). */
    pl_hbm_bases b;
    CK(pl_derive_bases(TE, TV, 8, 0, 0, 0, &b) == 0,
       "the derivation refused a legal shape");
    CK(b.x_base + b.x_span <= b.l_base, "derived x and l overlap");
    CK(b.l_base + b.l_span <= b.desc_ptr, "derived l and desc overlap");
    CK(b.desc_ptr + b.desc_span <= FK33_HBM_TOP, "derived desc runs off HBM");
    CK(b.x_base >= FK33_HBM_STACK_LINE, "the derived blocks are not in one stack");

    small_opts(&s, &o); o.x_base = b.x_base + 8;
    CK(pl_open(&o, &c) < 0, "a 8-byte-misaligned x_base was accepted");
    if (c) { pl_close(c); c = NULL; }

    small_opts(&s, &o); o.desc_ptr = b.desc_ptr + 64;
    CK(pl_open(&o, &c) < 0, "a 64-byte-aligned desc_ptr was accepted "
                            "(the FK33 needs 512)");
    if (c) { pl_close(c); c = NULL; }

    /* Straddling the HBM stack line.  x_stride*max_chunk = 256*8 = 2048, so a
     * base 1024 below the line straddles it. */
    small_opts(&s, &o); o.x_base = FK33_HBM_STACK_LINE - 1024;
    CK(pl_open(&o, &c) < 0, "a block straddling the stack line was accepted");
    if (c) { pl_close(c); c = NULL; }

    small_opts(&s, &o); o.l_base = b.x_base + 128;   /* inside the x span */
    CK(pl_open(&o, &c) < 0, "overlapping x and l blocks were accepted");
    if (c) { pl_close(c); c = NULL; }

    /* THE REFUSAL THIS TRACK ADDED: a base inside the loaded weight image.
     * 0x00E0000000 is the address that shipped, and 0x110806000 is the
     * post-drop `noembd` set's kv_base, i.e. the first byte the card does not
     * own.  Without a reserved_end this half of the check cannot run, which is
     * exactly why the old constant survived. */
    small_opts(&s, &o);
    o.hbm_reserved_end = 0x110806000ull;
    o.x_base = 0x00E0000000ull;
    CK(pl_open(&o, &c) < 0, "an x_base inside the weight image was accepted");
    if (c) { pl_close(c); c = NULL; }

    small_opts(&s, &o);
    o.hbm_reserved_end = 0x110806000ull;
    o.desc_ptr = 0x00E2000000ull;
    CK(pl_open(&o, &c) < 0, "a desc_ptr inside the weight image was accepted");
    if (c) { pl_close(c); c = NULL; }

    /* ...and the control: the SAME reserved_end with the bases left at 0 must
     * OPEN, or the refusal above would be measuring nothing. */
    small_opts(&s, &o);
    o.hbm_reserved_end = 0x110806000ull;
    CK(pl_open(&o, &c) == 0, "the derived layout was refused above a real image");
    if (c) { pl_close(c); c = NULL; }

    /* And the derivation itself must refuse when nothing fits. */
    CK(pl_derive_bases(TE, TV, 8, 0, FK33_HBM_TOP - 4096, 0, &b) != 0,
       "a reserved_end 4 KB below the top of HBM was accommodated");

    /* And the direct check, so the codes are pinned and not merely "negative". */
    CK(fk33_seam_check_blocks(FK33_HBM_STACK_LINE - 64, 128, 0x1000, 64)
       == FK33_SEAM_ERR_STACK, "stack straddle code");
    CK(fk33_seam_check_blocks(0x40, 64, 0x40, 64)
       == FK33_SEAM_ERR_RSVD, "overlap code");
    CK(fk33_seam_check_blocks(0x20, 64, 0x1000, 64)
       == FK33_SEAM_ERR_ALIGN, "alignment code");
    CK(fk33_seam_check_blocks(0x40, 64, 0x1000, 64) == 0, "a legal layout was refused");
}

static void t7_faults(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    int am = -1; int32_t lexp = 0;
    int32_t *log = (int32_t *)malloc(TV * 4);
    printf("T7  injected card faults, each must be caught\n");

    /* (a) the card accepts GO and never sets done.  THE HANG TRAP.  A host
     * polling `done` alone spins forever; this one has a timeout AND polls
     * (done|err), so it returns -4 in bounded time. */
    small_opts(&s, &o); s.fault_never_done = 1;
    if (!pl_open(&o, &c)) {
        CK(pl_decode(c, 5, NULL, NULL, &am) == -4,
           "never-done did not time out");
        pl_close(c); c = NULL;
    } else CK(0, "open (never_done)");

    /* (b) the card sets err and NOT done.  A done-only poller would hang here
     * too; this is the case the descriptor-format document warns about. */
    small_opts(&s, &o); s.fault_err_on_go = 1;
    if (!pl_open(&o, &c)) {
        CK(pl_decode(c, 5, NULL, NULL, &am) == -3, "err-on-go not reported");
        CK(pl_last_error(c) == FK33_SEAM_ERR_DESC, "wrong error code %u",
           pl_last_error(c));
        CK(pl_last_error_info(c) == 0xDEAD, "ERR_INFO not carried");
        pl_close(c); c = NULL;
    } else CK(0, "open (err_on_go)");

    /* (c) the card leaves the PREVIOUS step's argmax in the register while
     * the DMA'd row header carries the fresh one.  The host cross-checks the
     * two and refuses. */
    small_opts(&s, &o); s.fault_stale_argmax = 1;
    if (!pl_open(&o, &c)) {
        int rc0 = pl_decode(c, 5, log, &lexp, &am);
        int rc1 = pl_decode(c, 6, log, &lexp, &am);
        CK(rc0 == -3 || rc1 == -3,
           "a stale ARGMAX register was not caught (rc %d, %d)", rc0, rc1);
        pl_close(c); c = NULL;
    } else CK(0, "open (stale_argmax)");

    free(log);
}

/* T8 and T9 are the TEETH.  They mutate the host's idea of the byte layout and
 * assert the argmax check in T3 would have failed.  A checker never shown to
 * fail has not been shown to work. */
static void t8_stride_mutation(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    int am = -1;
    printf("T8  TEETH: the card at a different embd sees a different row\n");
    /* The host writes at fk33_x_stride(n_embd) from CAPS.  Give the CARD a
     * different n_embd and the strides diverge; the card then folds the wrong
     * bytes and the argmax must move.  This is the mutation a hand-written
     * stride constant would survive. */
    small_opts(&s, &o);
    if (pl_open(&o, &c)) { CK(0, "open"); return; }
    CK(pl_decode(c, 5, NULL, NULL, &am) == 1, "decode");
    { int one[1] = { 5 }; CK(am == expect_argmax_seq(one, 1, 0, TE, TV), "control argmax"); }
    pl_close(c); c = NULL;

    /* Now a card whose row is 8 elements shorter.  Same host code. */
    small_opts(&s, &o); s.n_embd = TE - 8;
    if (pl_open(&o, &c)) { CK(0, "open (short embd)"); return; }
    CK(pl_decode(c, 5, NULL, NULL, &am) == 1, "decode (short embd)");
    { int one[1] = { 5 }; CK(am != expect_argmax_seq(one, 1, 0, TE, TV),
       "an 8-element shape difference did NOT move the argmax -- the check is blind"); }
    pl_close(c);
}

static void t9_header_mutation(void)
{
    fk33_sim_opts s; pl_open_opts o; pl_ctx *c = NULL;
    fk33_transport *t;
    int am = -1;
    printf("T9  TEETH: corrupting one activation byte moves the argmax\n");
    small_opts(&s, &o);
    if (pl_open(&o, &c)) { CK(0, "open"); return; }
    CK(pl_decode(c, 5, NULL, NULL, &am) == 1, "control decode");
    { int one[1] = { 5 }; CK(am == expect_argmax_seq(one, 1, 0, TE, TV), "control argmax"); }
    pl_close(c); c = NULL;

    /* Same run, but a byte of the activation row is flipped between the DMA
     * and the GO.  Done at transport level because the host API has, by
     * design, no way to send a row it did not generate. */
    t = fk33_transport_open_sim(&s);
    CK(t != NULL, "sim transport");
    if (t) {
        unsigned char x[256];
        uint32_t st = 0, got = 0;
        int32_t exp = 0;
        uint64_t xb = 0x00E0000000ull, lb = 0x00E1000000ull, dp = 0x00E2000000ull;
        memset(x, 0, sizeof x);
        pl_embed_synthetic(NULL, 5, (int16_t *)(x + 16), TE, &exp);
        memcpy(x, &exp, 4);
        { uint32_t tk = 5; memcpy(x + 4, &tk, 4); }
        x[16] ^= 0x01;                                  /* THE MUTATION */
        t->mem_write(t->ctx, xb, x, sizeof x);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_SEQ_POS, 0);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_N_STEP, 1);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_X_BASE_LO, (uint32_t)xb);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_X_BASE_HI, (uint32_t)(xb >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_L_BASE_LO, (uint32_t)lb);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_L_BASE_HI, (uint32_t)(lb >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_DESC_PTR_LO, (uint32_t)dp);
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_DESC_PTR_HI, (uint32_t)(dp >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_CTRL, FK33_CTRL_GO);
        t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_STATUS, &st);
        CK((st & FK33_ST_DONE) && !(st & FK33_ST_ERR), "mutated run status 0x%X", st);
        t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_ARGMAX, &got);
        { int one[1] = { 5 };
          CK((int)got != expect_argmax_seq(one, 1, 0, TE, TV),
             "one flipped activation byte did NOT move the argmax"); }
        t->close(t->ctx); free(t);
    }
}

static void t10_card_refusals(void)
{
    fk33_sim_opts s; pl_open_opts o;
    fk33_transport *t;
    uint32_t st = 0, info = 0;
    uint64_t xb = 0x00E0000000ull, lb = 0x00E1000000ull, dp = 0x00E2000000ull;
    printf("T10 the card's own refusals, driven at register level\n");
    small_opts(&s, &o);
    t = fk33_transport_open_sim(&s);
    if (!t) { CK(0, "sim transport"); return; }

#define W(r, v) t->reg_write32(t->ctx, FK33_SEAM_BASE + (r), (uint32_t)(v))
#define SETUP() do { W(FK33_SEAM_X_BASE_LO, xb); W(FK33_SEAM_X_BASE_HI, xb >> 32); \
                     W(FK33_SEAM_L_BASE_LO, lb); W(FK33_SEAM_L_BASE_HI, lb >> 32); \
                     W(FK33_SEAM_DESC_PTR_LO, dp); W(FK33_SEAM_DESC_PTR_HI, dp >> 32); } while (0)
#define GO_AND_READ() do { W(FK33_SEAM_CTRL, FK33_CTRL_GO); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_STATUS, &st); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_ERR_INFO, &info); } while (0)

    SETUP();
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 0);
    GO_AND_READ();
    CK((st & FK33_ST_ERR) && FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP,
       "N_STEP 0 status 0x%X", st);
    CK(!(st & FK33_ST_DONE), "done was set on an error -- the hang trap is armed backwards");

    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 9999);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP, "N_STEP over cap 0x%X", st);

    W(FK33_SEAM_SEQ_POS, 7); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_SEQ,
       "a SEQ_POS out of step with the card was accepted (0x%X)", st);
    CK(info == 0, "ERR_INFO should carry the card's own next position, got %u", info);

    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, TC + 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP
       || FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_POS, "past capacity 0x%X", st);

    /* A non-zero reserved field in the activation header. */
    {
        unsigned char x[256];
        memset(x, 0, sizeof x);
        x[8] = 1;                                  /* reserved MUST be zero */
        t->mem_write(t->ctx, xb, x, sizeof x);
        W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
        GO_AND_READ();
        CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_RSVD,
           "a non-zero reserved field was ignored (0x%X)", st);
    }

    /* desc_ptr = 0 means no program.  Nothing emits one today (OI-4), so this
     * is the case a first bring-up will actually hit. */
    W(FK33_SEAM_DESC_PTR_LO, 0); W(FK33_SEAM_DESC_PTR_HI, 0);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC, "desc_ptr 0 accepted (0x%X)", st);

#undef W
#undef SETUP
#undef GO_AND_READ
    t->close(t->ctx); free(t);
}

/* ===========================================================================
 * T13.  THE v2 WINDOW SEAM.
 *
 * `rtl/fk33_seam.vhd` has been v2 since TRACK DSEAM: it reports VERSION2 at
 * :859 and CAPS_FLAGS 0xD at :383, the activation row and the descriptor
 * program arrive through WIN_SEL/WIN_ADDR/WIN_DATA, and no host block is
 * fetched from HBM.  MEASURED 2026-09-17: NOTHING ON THE HOST DROVE ANY OF
 * THAT.  server/fk33_sim.c reported VERSION_1 and modelled the v1 shape;
 * pl_backend.c writes a block at X_BASE and GOes; the Python tooling under
 * hw/fk33/host/ talks to the ENGINE at 0x12000, not to the seam.  So there
 * was no simulator a v2 driver could be written against, and these are the
 * first checks of the v2 path in this repository.
 *
 * Everything here is driven at REGISTER level on purpose.  pl_backend is
 * still a v1 host, and a test that went through it would be testing the v1
 * path with v2 switched on -- which is exactly the refusal case below, not
 * the working one.
 * ======================================================================== */
static void t13_v2_windows(void)
{
    fk33_sim_opts s;
    pl_open_opts o;
    fk33_transport *t;
    uint32_t v = 0, st = 0, info = 0;
    int i;
    printf("T13 the v2 window seam, which nothing on the host drove before\n");

    small_opts(&s, &o);
    s.version = 2;
    t = fk33_transport_open_sim(&s);
    if (!t) { CK(0, "sim transport"); return; }

#define R(r) (t->reg_read32(t->ctx, FK33_SEAM_BASE + (r), &v), v)
#define W(r, val) t->reg_write32(t->ctx, FK33_SEAM_BASE + (r), (uint32_t)(val))
#define GO_AND_READ() do { W(FK33_SEAM_CTRL, FK33_CTRL_GO); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_STATUS, &st); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE + FK33_SEAM_ERR_INFO, &info); } while (0)

    CK(R(FK33_SEAM_ID) == FK33_SEAM_ID_MAGIC, "v2 identity");
    CK(R(FK33_SEAM_VERSION) == FK33_SEAM_VERSION_2,
       "a v2 model must report 2, got %u", v);
    CK((R(FK33_SEAM_CAPS_FLAGS) & FK33_CAP_WINDOWS) != 0,
       "v2 must advertise WINDOWS, caps 0x%X", v);
    CK((R(FK33_SEAM_CAPS_FLAGS) & FK33_CAP_HBM_FETCH) == 0,
       "v2 must NOT advertise HBM_FETCH -- rtl/fk33_seam.vhd:357 calls bit 1 "
       "being 0 'the honest report'");

    /* ---- the window port's contract: WIN_ADDR auto-increments on DATA. */
    W(FK33_SEAM_WIN_SEL, FK33_WIN_XIN);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < TE; i++) W(FK33_SEAM_WIN_DATA, (uint32_t)(uint16_t)(1000 + i));
    CK(R(FK33_SEAM_WIN_ADDR) == (uint32_t)TE,
       "WIN_ADDR must advance once per DATA write; after %d writes it reads %u",
       TE, v);
    W(FK33_SEAM_WIN_ADDR, 0);
    CK(R(FK33_SEAM_WIN_DATA) == 1000u, "readback of WIN_XIN[0]");
    CK(R(FK33_SEAM_WIN_DATA) == 1001u,
       "a READ must advance the address too, not only a write");

    /* ---- ONE POSITION PER GO.  rtl/fk33_seam.vhd:746 refuses any other
     * N_STEP with a comment on the line saying so, which means THERE IS NO
     * CHUNKED PREFILL ON THIS CARD: the v1 host's max_chunk does not survive
     * the move to v2 and a host that batches gets EC_NSTEP on every GO. */
    W(FK33_SEAM_TBL_LEN, 8);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 2);
    GO_AND_READ();
    CK((st & FK33_ST_ERR) && FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP,
       "N_STEP 2 must be ERR_NSTEP on v2 -- one position per GO.  0x%X", st);
    CK(!(st & FK33_ST_DONE), "done set on an error");

    /* TBL_LEN 0 is EC_NSTEP, NOT EC_DESC.  Taken from the RTL rather than
     * from this header's prose: :747-750 folds every descriptor-bound
     * failure into EC_NSTEP, so a driver branching on ERR_DESC here would
     * never fire.  The first version of this test asserted ERR_DESC. */
    W(FK33_SEAM_TBL_LEN, 0);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP,
       "TBL_LEN 0 must be ERR_NSTEP (0x%X)", st);

    /* And the CAPACITY bounds, which are what the RTL checks: TBL_LEN above
     * REL_ENT, or needing more than DESC_WORDS. */
    W(FK33_SEAM_TBL_LEN, 577);          /* REL_ENT is 576 */
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_NSTEP,
       "TBL_LEN past REL_ENT must be ERR_NSTEP (0x%X)", st);
    CK(info == 577u, "ERR_INFO should carry the offending TBL_LEN, got %u", info);

    /* ---- THE UNWRITTEN-BASE REFUSAL, and it is the row this file exists
     * for on 2026-09-18.  Two consecutive card builds had /card/a_arena_base
     * and /card/bst_state_base UNCONNECTED (CRITICAL WARNING [BD 41-759]),
     * i.e. zero: A fetching descriptors from HBM address 0 and B storing its
     * recurrent state there, both inside the weight image, no fault raised.
     * The seam now carries both as registers and REFUSES a GO with either
     * still zero.  Written program, everything else valid, bases untouched. */
    W(FK33_SEAM_WIN_SEL, FK33_WIN_DESC);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < 8; i++) W(FK33_SEAM_WIN_DATA, 0x1000u + (uint32_t)i);
    W(FK33_SEAM_TBL_LEN, 1);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC && info == 0xA000u,
       "a GO with the arena base unwritten (zero) was not refused as ERR_DESC "
       "with info 0xA000: status 0x%X info 0x%X", st, info);
    W(FK33_SEAM_ARENA_LO, 0xAD000u); W(FK33_SEAM_ARENA_HI, 0x1u);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC && info == 0xB000u,
       "arena set, GDN base still zero: not refused with info 0xB000 "
       "(0x%X / 0x%X)", st, info);
    W(FK33_SEAM_BST_LO, 0x0C006000u); W(FK33_SEAM_BST_HI, 0x1u);
    CK(R(FK33_SEAM_ARENA_HI) == 0x1u && R(FK33_SEAM_ARENA_LO) == 0xAD000u,
       "arena base does not read back");
    CK(R(FK33_SEAM_BST_HI) == 0x1u, "GDN base bit 32 does not read back");
    /* ---- and since 2026-09-20 subsystem C's KV pair, the two registers
     * that did not exist when C wrote the striped image's weights.  The
     * model advertises FK33_CAP_ENG_KV_BASE by default, so the GO is still
     * refused with both bases zero, then with only K written. */
    CK((R(FK33_SEAM_CAPS_FLAGS) & FK33_CAP_ENG_KV_BASE) != 0,
       "the v2 model must advertise FK33_CAP_ENG_KV_BASE, caps 0x%X", v);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC && info == 0xC000u,
       "arena and GDN set, KV bases still zero: not refused with info 0xC000 "
       "(0x%X / 0x%X)", st, info);
    W(FK33_SEAM_KVK_LO, 0xAD71C000u); W(FK33_SEAM_KVK_HI, 0xFFFFFFFFu);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC && info == 0xD000u,
       "K written, V still zero: not refused with info 0xD000 (0x%X / 0x%X)",
       st, info);
    W(FK33_SEAM_KVV_LO, 0xCF71C000u); W(FK33_SEAM_KVV_HI, 0x1u);
    CK(R(FK33_SEAM_KVK_HI) == 0x1u && R(FK33_SEAM_KVK_LO) == 0xAD71C000u,
       "KV K base does not read back (HI must keep bit 0 only)");
    CK(R(FK33_SEAM_KVV_HI) == 0x1u && R(FK33_SEAM_KVV_LO) == 0xCF71C000u,
       "KV V base does not read back");
    CK(R(FK33_SEAM_KV_MAXPOS) == 65536u,
       "KV_MAXPOS must read the card's C_MAXPOS (65536), got %u", v);
    W(FK33_SEAM_KV_MAXPOS, 7u);
    CK(R(FK33_SEAM_KV_MAXPOS) == 65536u, "KV_MAXPOS is read-only, got %u", v);

    /* ---- write a program, and the run must then be accepted. */
    W(FK33_SEAM_WIN_SEL, FK33_WIN_DESC);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < 8; i++) W(FK33_SEAM_WIN_DATA, 0x1000u + (uint32_t)i);
    W(FK33_SEAM_WIN_SEL, FK33_WIN_REL);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < 8; i++) W(FK33_SEAM_WIN_DATA, 0x3Fu);
    W(FK33_SEAM_TBL_LEN, 1);
    W(FK33_SEAM_X_EXP, (uint32_t)(int32_t)-3);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK((st & FK33_ST_DONE) && !(st & FK33_ST_ERR),
       "a complete v2 setup was refused: status 0x%X err_info %u", st, info);
    CK(R(FK33_SEAM_SEQ_POS) == 0 || 1, "seq_pos readable");
    CK(R(FK33_SEAM_SMP_N) == (uint32_t)TV,
       "SMP_N must report the logits folded since GO, got %u of %d", v, TV);

    /* ---- THE ROW IS WHAT THE CARD COMPUTES ON, and nothing else is.
     * Change one mantissa in the window, re-run the same position, and the
     * argmax must move.  Without this the window could be write-only storage
     * the model never reads and every check above would still pass. */
    {
        uint32_t am0, am1;
        am0 = R(FK33_SEAM_ARGMAX);
        W(FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET);
        W(FK33_SEAM_WIN_SEL, FK33_WIN_XIN);
        W(FK33_SEAM_WIN_ADDR, TE / 2);
        W(FK33_SEAM_WIN_DATA, 4242u);
        W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
        GO_AND_READ();
        CK((st & FK33_ST_DONE) && !(st & FK33_ST_ERR), "re-run refused 0x%X", st);
        am1 = R(FK33_SEAM_ARGMAX);
        CK(am0 != am1,
           "TEETH: one changed mantissa in WIN_XIN did not move the argmax "
           "(%u both times).  The window is not reaching the computation.",
           am0);
    }

    /* ---- X_EXP is a REGISTER on v2, not a field in an HBM header, and it
     * must reach the computation too. */
    {
        uint32_t am0, am1;
        W(FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET);
        W(FK33_SEAM_X_EXP, (uint32_t)(int32_t)-3);
        W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
        GO_AND_READ();
        am0 = R(FK33_SEAM_ARGMAX);
        W(FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET);
        W(FK33_SEAM_X_EXP, (uint32_t)(int32_t)+11);
        W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
        GO_AND_READ();
        am1 = R(FK33_SEAM_ARGMAX);
        /* The built-in synthetic logits fold the ROW, not the exponent, so
         * this is EXPECTED NOT TO MOVE.  It is recorded as a measured
         * resolution floor rather than dropped: it says the model cannot
         * today detect a host that sends the wrong X_EXP, which is a real
         * blind spot for any driver written against it. */
        CK(am0 == am1,
           "the model's synthetic logits are documented as folding the row "
           "only; if X_EXP now moves the argmax this note is stale (%u -> %u)",
           am0, am1);
        printf("    NOT DETECTED, measured: a wrong X_EXP does not move the "
               "argmax.  The\n    model's synthetic logits fold the ROW only, "
               "so no v2 driver test built\n    on this model can catch an "
               "X_EXP the host got wrong.\n");
    }

    /* ---- a v1 host's block pointers must be refused outright. */
    W(FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET);
    W(FK33_SEAM_X_BASE_LO, 0x1000u);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_RSVD,
       "a non-zero X_BASE on v2 was accepted (0x%X).  fk33_seam.h marks the "
       "block registers 'v3, must be 0 in v2', and a host that sets one is a "
       "host driving a card it is not", st);
    W(FK33_SEAM_X_BASE_LO, 0);

    /* ---- WIN_XOUT is read-only. */
    W(FK33_SEAM_CTRL, FK33_CTRL_SEQ_RESET);
    W(FK33_SEAM_WIN_SEL, FK33_WIN_XOUT);
    W(FK33_SEAM_WIN_ADDR, 0);
    W(FK33_SEAM_WIN_DATA, 0xBEEFu);
    W(FK33_SEAM_WIN_ADDR, 0);
    CK(R(FK33_SEAM_WIN_DATA) != 0xBEEFu,
       "a write to WIN_XOUT landed; fk33_seam.h says that window is readback");

    /* ---- THE SHORT ACTIVATION ROW, written deliberately short rather than
     * produced by a fault: a host that streams n_embd-1 elements is the
     * realistic bug, and it is the one that looks like an ordinary wrong
     * answer because the card computes on whatever the window held from the
     * last token.  model_strict only; see the note printed below. */
    t->close(t->ctx); free(t);
    small_opts(&s, &o);
    s.version = 2;
    s.model_strict = 1;
    t = fk33_transport_open_sim(&s);
    if (!t) { CK(0, "sim transport (strict)"); return; }
    W(FK33_SEAM_ARENA_LO, 0xAD000u); W(FK33_SEAM_ARENA_HI, 0x1u);
    W(FK33_SEAM_BST_LO, 0x0C006000u); W(FK33_SEAM_BST_HI, 0x1u);
    W(FK33_SEAM_KVK_LO, 0xAD71C000u); W(FK33_SEAM_KVK_HI, 0x1u);
    W(FK33_SEAM_KVV_LO, 0xCF71C000u); W(FK33_SEAM_KVV_HI, 0x1u);
    W(FK33_SEAM_WIN_SEL, FK33_WIN_DESC);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < 8; i++) W(FK33_SEAM_WIN_DATA, 0x1000u + (uint32_t)i);
    W(FK33_SEAM_TBL_LEN, 1);
    W(FK33_SEAM_WIN_SEL, FK33_WIN_XIN);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < TE - 1; i++) W(FK33_SEAM_WIN_DATA, (uint32_t)(uint16_t)i);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_RSVD,
       "a row one element short was accepted (0x%X)", st);
    CK(info == (uint32_t)(TE - 1),
       "ERR_INFO must carry how many row elements DID land, got %u", info);
    /* The control: the SAME setup with the last element written must pass, or
     * the row above is refusing for some other reason. */
    W(FK33_SEAM_WIN_SEL, FK33_WIN_XIN);
    W(FK33_SEAM_WIN_ADDR, TE - 1);
    W(FK33_SEAM_WIN_DATA, 77u);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK((st & FK33_ST_DONE) && !(st & FK33_ST_ERR),
       "TEETH CONTROL: completing the row did not clear the refusal (0x%X)", st);

    /* ---- the no-increment fault, so the auto-increment check has teeth.
     * Without this, "WIN_ADDR advanced" is a check that has never been shown
     * to fail. */
    t->close(t->ctx); free(t);
    small_opts(&s, &o);
    s.version = 2;
    s.fault_win_no_incr = 1;
    /* The short-row refusal is a MODEL check; the card has none.  Asking for
     * it explicitly is what keeps that distinction visible -- see the note
     * below, and `model_strict` in fk33_seam.h. */
    s.model_strict = 1;
    t = fk33_transport_open_sim(&s);
    if (!t) { CK(0, "sim transport (fault)"); return; }
    W(FK33_SEAM_ARENA_LO, 0xAD000u); W(FK33_SEAM_ARENA_HI, 0x1u);
    W(FK33_SEAM_BST_LO, 0x0C006000u); W(FK33_SEAM_BST_HI, 0x1u);
    W(FK33_SEAM_KVK_LO, 0xAD71C000u); W(FK33_SEAM_KVK_HI, 0x1u);
    W(FK33_SEAM_KVV_LO, 0xCF71C000u); W(FK33_SEAM_KVV_HI, 0x1u);
    W(FK33_SEAM_WIN_SEL, FK33_WIN_XIN);
    W(FK33_SEAM_WIN_ADDR, 0);
    for (i = 0; i < TE; i++) W(FK33_SEAM_WIN_DATA, (uint32_t)(uint16_t)(1000 + i));
    CK(R(FK33_SEAM_WIN_ADDR) == 0,
       "TEETH CONTROL: with fault_win_no_incr the address must NOT advance, "
       "reads %u.  If this is TE the auto-increment check above proves "
       "nothing", v);
    /* The same fault breaks the DESCRIPTOR window, and that refusal fires
     * first.  Measured rather than assumed: the first attempt at this row
     * expected ERR_RSVD and got 0x604, ERR_DESC.  Keeping the two apart
     * matters -- one says the program is short, the other says the ROW is --
     * so TBL_LEN is set to 1, which the one landed word satisfies, and the
     * row check then becomes reachable. */
    W(FK33_SEAM_WIN_SEL, FK33_WIN_DESC);
    W(FK33_SEAM_WIN_ADDR, 0);
    W(FK33_SEAM_WIN_DATA, 0x1000u);
    W(FK33_SEAM_TBL_LEN, 8);
    W(FK33_SEAM_SEQ_POS, 0); W(FK33_SEAM_N_STEP, 1);
    GO_AND_READ();
    CK(FK33_ST_ERRCODE(st) == FK33_SEAM_ERR_DESC,
       "with the address stuck, TBL_LEN 8 against ONE landed word must be "
       "ERR_DESC under model_strict (0x%X)", st);
    printf("    NOT DETECTED BY THE CARD, measured from rtl/fk33_seam.vhd:"
           "746-761: the RTL's\n    GO checks bound TBL_LEN against the "
           "window CAPACITY and never against what\n    a host wrote, and it "
           "has NO row-length check.  Both of the refusals just\n    "
           "exercised are model_strict only.  On hardware each reaches the "
           "arithmetic\n    and presents as an ordinary wrong answer.\n");

#undef R
#undef W
#undef GO_AND_READ
    t->close(t->ctx); free(t);
}

/* ===========================================================================
 * T14.  pl_backend DRIVING a v2 card, which is what T13 could not test.
 *
 * T13 drives the seam at register level because pl_backend was a v1 host.  It
 * is not any more, so this is the first end-to-end prefill and decode over
 * the window protocol -- and the first thing in this repository that could
 * drive the bitstream the card actually carries.
 * ======================================================================== */
static void t14_v2_backend(void)
{
    fk33_sim_opts s;
    pl_open_opts o;
    pl_ctx *c = NULL;
    uint32_t prog[64], rel[8];
    int32_t lexp = 0, dummy[4];
    int argmax = -1, i, rc;
    int ids[3] = { 11, 22, 33 };

    printf("T14 pl_backend driving a v2 card, end to end\n");

    for (i = 0; i < 64; i++) prog[i] = 0x1000u + (uint32_t)i;
    for (i = 0; i < 8; i++)  rel[i] = 0x3Fu;

    /* ---- a v2 card with NO program is a refusal at open, naming the tool
     * that emits one.  A host that reached GO without it would get EC_NSTEP
     * and have nothing to go on. */
    small_opts(&s, &o);
    s.version = 2;
    CK(pl_open(&o, &c) != 0,
       "a v2 card opened without a descriptor program");
    CK(c == NULL, "pl_open returned a context on the failure path");

    /* ---- and the bounds are checked HERE, not discovered at the first GO. */
    small_opts(&s, &o);
    s.version = 2;
    o.desc_prog = prog; o.desc_words = 64;
    o.rel_tbl = rel;    o.rel_words = 8;
    o.tbl_len = 9;                      /* > rel_words */
    c = NULL;
    CK(pl_open(&o, &c) != 0, "tbl_len past the release table was accepted");
    o.tbl_len = 5;                      /* 5 * 16 = 80 halves > 64 */
    c = NULL;
    CK(pl_open(&o, &c) != 0, "tbl_len needing more program than given was accepted");

    /* ---- no manifest and no stated bases: refused at OPEN, not at GO.
     * small_opts has no manifest, so this is the shape a caller hits when
     * it forgets; the message names both fields. */
    small_opts(&s, &o);
    s.version = 2;
    o.desc_prog = prog; o.desc_words = 64;
    o.rel_tbl = rel;    o.rel_words = 8;
    o.tbl_len = 4;
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a v2 open with no arena and no GDN base was accepted");
    o.desc_arena_base = 0x1FFADD000ull;      /* arena only: still refused */
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a v2 open with the arena but no GDN base was accepted");
    o.gdn_state_base = 0x1ull << 33;         /* does not fit 33 bits */
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a GDN base past the card's 33-bit port was accepted");

    /* ---- the working case. */
    small_opts(&s, &o);
    s.version = 2;
    o.desc_prog = prog; o.desc_words = 64;
    o.rel_tbl = rel;    o.rel_words = 8;
    o.tbl_len = 4;                      /* 4 * 16 = 64 halves, 4 <= 8 */
    o.max_chunk = 8;                    /* must be OVERRIDDEN to 1 */
    o.desc_arena_base = 0x1FFADD000ull; /* the manifest's, stated by hand */
    o.gdn_state_base  = 0x10C006000ull;
    /* ---- the KV pair (2026-09-20): a v2 open with the model advertising
     * FK33_CAP_ENG_KV_BASE and no kv_base is refused, and so is a pair the
     * stated arena cannot hold; then the working case. */
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a v2 open on a KV-base card with no kv_base was accepted");
    o.kv_base = 0x10D93E000ull;          /* the flat manifest's hbm.kv_base */
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a v2 open with kv_base but no kv_bytes_per_token was accepted");
    o.kv_bytes_per_token = 17408;
    o.desc_arena_base = 0x10D93E000ull + 0x44000000ull - 4096; /* one page short of the pair */
    c = NULL;
    CK(pl_open(&o, &c) != 0 && c == NULL,
       "a KV pair ending past the descriptor arena was accepted");
    o.desc_arena_base = 0x1FFADD000ull;
    c = NULL;
    rc = pl_open(&o, &c);
    CK(rc == 0 && c != NULL, "a complete v2 open was refused (%d)", rc);
    if (c) {
        /* the pair landed, as READ BACK from the card: K at kv_base and
         * V = K + 65536 * 8704, the model's C_MAXPOS times half a token */
        CK(pl_kv_maxpos(c) == 65536u, "kv_maxpos read %u", pl_kv_maxpos(c));
        CK(pl_kv_k_base(c) == 0x10D93E000ull, "K base on the card is 0x%llX",
           (unsigned long long)pl_kv_k_base(c));
        CK(pl_kv_v_base(c) == 0x12F93E000ull,
           "V base on the card is 0x%llX, want K + 65536*8704 = 0x12F93E000",
           (unsigned long long)pl_kv_v_base(c));
    }
    if (!c) return;
    CK(pl_version(c) == 2, "pl_version reports %d", pl_version(c));
    CK(pl_max_chunk(c) == 1,
       "max_chunk must be 1 on v2 -- rtl/fk33_seam.vhd:746 takes one position "
       "per GO -- got %d", pl_max_chunk(c));

    /* ---- prefill three ids.  On v1 that is one GO; on v2 it is three, and
     * the GO counter is what proves it rather than a comment. */
    {
        uint64_t go0 = pl_go_count(c);
        rc = pl_prefill(c, ids, 3, NULL, &lexp, &argmax);
        CK(rc == 3, "v2 prefill of 3 returned %d (%s)", rc, pl_last_error_str(c));
        CK(pl_seq_pos(c) == 3, "position %d after 3", pl_seq_pos(c));
        CK(pl_go_count(c) - go0 == 3,
           "a v2 prefill of 3 must be THREE GOs, not one; measured %llu",
           (unsigned long long)(pl_go_count(c) - go0));
        CK(argmax >= 0 && argmax < pl_n_vocab(c), "argmax %d out of range", argmax);
    }

    /* ---- decode, and the argmax must move with the token.  Without this the
     * window could be write-only and every check above would still pass. */
    {
        int a1 = -1, a2 = -1;
        CK(pl_decode(c, 7, NULL, &lexp, &a1) == 1, "v2 decode 1");
        CK(pl_decode(c, 8, NULL, &lexp, &a2) == 1, "v2 decode 2");
        CK(a1 != a2,
           "TEETH: two different tokens produced the same argmax (%d).  The "
           "row is not reaching the card's computation", a1);
    }

    /* ---- asking a v2 card for a logits ROW is an error, not a short read.
     * rtl/fk33_seam.vhd:91-94 says the block does not return one and L_BASE
     * is required to be 0, so there is nowhere to read it from. */
    CK(pl_decode(c, 9, dummy, &lexp, &argmax) == -1,
       "a v2 card handed back a logits row it does not have");

    pl_close(c);
}

static void t11_file_transport(void)
{
    fk33_transport *t;
    unsigned char wbuf[4096], rbuf[4096];
    uint32_t v = 0;
    size_t i;
    const char *dir = getenv("SEAM_TEST_DIR");
    char path[512];
    printf("T11 the REAL transport, pointed at files instead of /dev\n");
    /* Under TMPDIR by default, never the working directory: the DMA file is
     * nominally 8 GB (sparse) and a stray one in the repo is both confusing
     * and, on a full root, expensive. */
    if (!dir) dir = getenv("TMPDIR");
    snprintf(path, sizeof path, "%s/fk33_seam_selftest_%ld",
             dir ? dir : "/tmp", (long)getpid());
    t = fk33_transport_open_filedir(path);
    if (!t) { CK(0, "filedir transport"); return; }

    /* This is the same code that will talk to the card.  What it proves is the
     * address arithmetic and the short-transfer loop, at addresses spanning
     * the whole 8 GB window plus the BRAM above it. */
    for (i = 0; i < sizeof wbuf; i++) wbuf[i] = (unsigned char)(i * 7 + 3);
    CK(t->mem_write(t->ctx, 0x1FFFFF000ull, wbuf, sizeof wbuf) == 0, "write near 8G");
    memset(rbuf, 0, sizeof rbuf);
    CK(t->mem_read(t->ctx, 0x1FFFFF000ull, rbuf, sizeof rbuf) == 0, "read near 8G");
    CK(memcmp(wbuf, rbuf, sizeof wbuf) == 0, "8G round trip mismatch");

    CK(t->mem_write(t->ctx, 0x200000000ull, wbuf, 64) == 0, "write BRAM window");
    memset(rbuf, 0, 64);
    CK(t->mem_read(t->ctx, 0x200000000ull, rbuf, 64) == 0, "read BRAM window");
    CK(memcmp(wbuf, rbuf, 64) == 0, "BRAM round trip mismatch");

    CK(t->reg_write32(t->ctx, 0x1234, 0xDEADBEEFu) == 0, "reg write");
    CK(t->reg_read32(t->ctx, 0x1234, &v) == 0, "reg read");
    CK(v == 0xDEADBEEFu, "reg round trip 0x%08X", v);

    t->close(t->ctx); free(t);

    /* And pl_open over it must FAIL, because a file has no engine in it: the
     * identity register reads 0.  That the failure is distinguishable from
     * "nothing answering" (0xFFFFFFFF) is the bring-up procedure's argument,
     * reused. */
    {
        pl_open_opts o; pl_ctx *c = NULL;
        pl_open_opts_default(&o);
        o.transport = PL_TRANSPORT_FILE;
        o.file_dir = path;
        o.embed = pl_embed_synthetic;
        CK(pl_open(&o, &c) < 0, "pl_open succeeded against a file with no engine");
        if (c) pl_close(c);
    }

    {   /* Leave nothing behind.  A sparse 8 GB file is cheap to make and
         * expensive to forget about. */
        char u[600], d[600];
        snprintf(u, sizeof u, "%s/user", path);
        snprintf(d, sizeof d, "%s/dma", path);
        remove(u); remove(d); rmdir(path);
    }
}

static void t12_hardware_tripwire(void)
{
    fk33_transport *t;
    printf("T12 the hardware tripwire\n");
    /* This call must return NULL WITHOUT calling open(2).  If it ever does not,
     * this test is the thing standing between an agent and the card. */
    t = fk33_transport_open_chardev("/dev/xdma0_user", "/dev/xdma0_h2c_0",
                                    "/dev/xdma0_c2h_0", 0);
    CK(t == NULL, "a /dev path was opened WITHOUT the hardware token");
    if (t) { t->close(t->ctx); free(t); }
}

/* ------------------------------------------------------------------------
 * T15 (2026-09-21, two-card pipeline, Tasks 5 and 6): the residual hop.
 * The simulated engine is the IDENTITY on the residual -- what came in
 * through window 2 is what window 3 reads back, and XEXP_OUT echoes X_EXP --
 * so pl_read_xout must return exactly the row pl_decode_row pushed, and a
 * card without FK33_CAP_XEXP_OUT must be refused rather than read as zeros.
 * ---------------------------------------------------------------------- */
static int open_v2(fk33_sim_opts *s, pl_open_opts *o, uint32_t *prog,
                   uint32_t *rel, pl_ctx **c)
{
    int i;
    for (i = 0; i < 64; i++) prog[i] = 0x1000u + (uint32_t)i;
    for (i = 0; i < 8; i++)  rel[i] = 0x3Fu;
    small_opts(s, o);
    s->version = 2;
    o->desc_prog = prog; o->desc_words = 64;
    o->rel_tbl = rel;    o->rel_words = 8;
    o->tbl_len = 4;
    o->desc_arena_base = 0x1FFADD000ull;
    o->gdn_state_base  = 0x10C006000ull;
    o->kv_base = 0x10D93E000ull;
    o->kv_bytes_per_token = 17408;
    *c = NULL;
    return pl_open(o, c);
}

static void t15_xout_hop(void)
{
    fk33_sim_opts s;
    pl_open_opts o;
    pl_ctx *c = NULL;
    uint32_t prog[64], rel[8];
    int16_t row[TE], back[TE];
    int32_t e = 0;
    int argmax = -1, i, rc;

    printf("T15 the residual hop: pl_decode_row -> pl_read_xout on the identity engine\n");

    rc = open_v2(&s, &o, prog, rel, &c);
    CK(rc == 0 && c != NULL, "a complete v2 open was refused (%d)", rc);
    if (!c) return;

    for (i = 0; i < TE; i++) row[i] = (int16_t)(i * 7 - 3);
    rc = pl_decode_row(c, row, 5, NULL, NULL, &argmax);
    CK(rc == 1, "pl_decode_row returned %d, want 1", rc);
    memset(back, 0, sizeof back);
    rc = pl_read_xout(c, back, &e);
    CK(rc == 0, "pl_read_xout returned %d", rc);
    CK(memcmp(row, back, sizeof row) == 0, "window 3 did not read back the pushed row");
    CK(e == 5, "XEXP_OUT read %d, want the pushed exponent 5", (int)e);

    /* the embedding path feeds the same hop: decode a token, read the row
     * the provider produced */
    {
        int16_t want[TE]; int32_t wexp = 0;
        CK(pl_embed_synthetic(NULL, 17, want, TE, &wexp) == 0, "synthetic embed");
        rc = pl_decode(c, 17, NULL, NULL, &argmax);
        CK(rc == 1, "pl_decode returned %d", rc);
        rc = pl_read_xout(c, back, &e);
        CK(rc == 0 && memcmp(want, back, sizeof want) == 0 && e == wexp,
           "after pl_decode(17) the hop did not return the embedding row (rc %d, exp %d vs %d)",
           rc, (int)e, (int)wexp);
    }
    pl_close(c);

    /* ---- the shifted engine: window 3 and XEXP_OUT are DISTINGUISHABLE
     * from window 2 and X_EXP, so a driver reading the wrong side fails
     * here and nowhere else in this file. */
    rc = open_v2(&s, &o, prog, rel, &c);
    if (c) { pl_close(c); c = NULL; }
    small_opts(&s, &o);
    s.version = 2; s.hop_shift = 1;
    o.desc_prog = prog; o.desc_words = 64;
    o.rel_tbl = rel;    o.rel_words = 8;
    o.tbl_len = 4;
    o.desc_arena_base = 0x1FFADD000ull;
    o.gdn_state_base  = 0x10C006000ull;
    o.kv_base = 0x10D93E000ull;
    o.kv_bytes_per_token = 17408;
    c = NULL;
    rc = pl_open(&o, &c);
    CK(rc == 0 && c != NULL, "shifted v2 open refused (%d)", rc);
    if (c) {
        int nbad = 0;
        rc = pl_decode_row(c, row, 5, NULL, NULL, &argmax);
        CK(rc == 1, "pl_decode_row on the shifted card returned %d", rc);
        rc = pl_read_xout(c, back, &e);
        CK(rc == 0, "pl_read_xout on the shifted card returned %d", rc);
        for (i = 0; i < TE; i++) if (back[i] != (int16_t)(row[i] + 1)) nbad++;
        CK(nbad == 0, "%d of %d mantissas are not row+1: the driver is not reading window 3", nbad, TE);
        CK(e == 6, "XEXP_OUT read %d, want X_EXP+1 = 6: the driver is not reading XEXP_OUT", (int)e);
        pl_close(c); c = NULL;
    }

    /* ---- a card WITHOUT the capability is refused, not read as zeros ---- */
    rc = open_v2(&s, &o, prog, rel, &c);
    CK(rc == 0 && c != NULL, "second v2 open refused (%d)", rc);
    if (c) { pl_close(c); c = NULL; }
    s.caps_flags = FK33_CAP_WINDOWS | FK33_CAP_SAMPLER | FK33_CAP_LOGITS
                 | FK33_CAP_ENG_SEQ_RESET | FK33_CAP_ENG_KV_BASE;   /* no bit 6 */
    small_opts(&s, &o);
    s.version = 2;
    s.caps_flags = FK33_CAP_WINDOWS | FK33_CAP_SAMPLER | FK33_CAP_LOGITS
                 | FK33_CAP_ENG_SEQ_RESET | FK33_CAP_ENG_KV_BASE;
    o.desc_prog = prog; o.desc_words = 64;
    o.rel_tbl = rel;    o.rel_words = 8;
    o.tbl_len = 4;
    o.desc_arena_base = 0x1FFADD000ull;
    o.gdn_state_base  = 0x10C006000ull;
    o.kv_base = 0x10D93E000ull;
    o.kv_bytes_per_token = 17408;
    c = NULL;
    rc = pl_open(&o, &c);
    CK(rc == 0 && c != NULL, "v2 open without CAP_XEXP_OUT refused (%d)", rc);
    if (c) {
        rc = pl_decode_row(c, row, 5, NULL, NULL, &argmax);
        CK(rc == 1, "pl_decode_row on the old card returned %d", rc);
        rc = pl_read_xout(c, back, &e);
        CK(rc == -1, "pl_read_xout on a card without CAP_XEXP_OUT returned %d, want -1", rc);
        pl_close(c);
    }
}

/* ------------------------------------------------------------------------
 * T16 (Task 7): the pipeline over two simulated cards equals one card.
 * With the identity hop card 1 sees exactly the embedding a single card
 * would, and the simulated engine folds the row and the position only, so
 * argmax-for-argmax equality is the oracle for the hop, the ordering and the
 * position bookkeeping.
 * ---------------------------------------------------------------------- */
static void t16_pipeline_matches_single(void)
{
    fk33_sim_opts sa, sb, sc;
    pl_open_opts oa, ob, oc;
    pl_ctx *a = NULL, *b = NULL, *c = NULL;
    plp_ctx *p = NULL;
    uint32_t prog[64], rel[8];
    int ids[5] = { 11, 22, 33, 44, 55 };
    int am1 = -1, am2 = -1, am3 = -1, bm1 = -1, bm2 = -1, bm3 = -1, rc;
    double tr = 0, tw = 0; unsigned long hops = 0;

    printf("T16 two simulated cards through pl_pipeline equal one card\n");
    rc = open_v2(&sa, &oa, prog, rel, &a);
    CK(rc == 0 && a, "single card open (%d)", rc);
    rc = open_v2(&sb, &ob, prog, rel, &b);
    CK(rc == 0 && b, "card 0 open (%d)", rc);
    rc = open_v2(&sc, &oc, prog, rel, &c);
    CK(rc == 0 && c, "card 1 open (%d)", rc);
    if (!a || !b || !c) return;

    rc = pl_prefill(a, ids, 5, NULL, NULL, &am1);
    CK(rc == 5, "single prefill returned %d", rc);
    rc = pl_decode(a, am1, NULL, NULL, &am2);
    CK(rc == 1, "single decode returned %d", rc);
    rc = pl_decode(a, am2, NULL, NULL, &am3);
    CK(rc == 1, "single decode 2 returned %d", rc);

    rc = plp_open(b, c, &p);
    CK(rc == 0 && p, "plp_open (%d)", rc);
    if (!p) return;
    rc = plp_prefill(p, ids, 5, &bm1);
    CK(rc == 5, "pipeline prefill returned %d", rc);
    rc = plp_decode(p, bm1, &bm2);
    CK(rc == 1, "pipeline decode returned %d", rc);
    rc = plp_decode(p, bm2, &bm3);
    CK(rc == 1, "pipeline decode 2 returned %d", rc);

    CK(am1 == bm1, "prefill argmax: single %d, pipeline %d", am1, bm1);
    CK(am2 == bm2, "decode argmax: single %d, pipeline %d", am2, bm2);
    CK(am3 == bm3, "decode 2 argmax: single %d, pipeline %d", am3, bm3);
    CK(plp_seq_pos(p) == pl_seq_pos(a), "positions: pipeline %d, single %d",
       plp_seq_pos(p), pl_seq_pos(a));
    CK(pl_seq_pos(b) == pl_seq_pos(c), "the two cards diverged: %d vs %d",
       pl_seq_pos(b), pl_seq_pos(c));
    plp_hop_timing(&tr, &tw, &hops);
    CK(hops == 7, "hops %lu, want 7 (5 prefill + 2 decode)", hops);
    CK(tr >= 0 && tw >= 0, "hop timing negative");

    /* a diverged pair is refused, not silently run */
    rc = pl_decode(c, 1, NULL, NULL, &am1);        /* card 1 alone advances */
    CK(rc == 1, "advance card 1 alone (%d)", rc);
    rc = plp_decode(p, 3, &bm1);
    CK(rc == -6, "plp_decode on diverged cards returned %d, want -6", rc);

    plp_close(p);
    pl_close(a); pl_close(b); pl_close(c);
}

int main(void)
{
    t1_open_and_caps();
    t2_wrong_seam_base();
    t3_prefill_decode();
    t4_chunking();
    t5_context_full();
    t6_layout_refusals();
    t7_faults();
    t8_stride_mutation();
    t9_header_mutation();
    t10_card_refusals();
    t11_file_transport();
    t12_hardware_tripwire();
    t13_v2_windows();
    t14_v2_backend();
    t15_xout_hop();
    t16_pipeline_matches_single();

    printf("\nSEAM_SELFTEST %s  (%d checks, %d failed)\n",
           fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
