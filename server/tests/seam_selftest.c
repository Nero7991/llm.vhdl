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

    small_opts(&s, &o); o.x_base = 0x00E0000000ull + 8;
    CK(pl_open(&o, &c) < 0, "a 8-byte-misaligned x_base was accepted");
    if (c) { pl_close(c); c = NULL; }

    small_opts(&s, &o); o.desc_ptr = 0x00E2000000ull + 64;
    CK(pl_open(&o, &c) < 0, "a 64-byte-aligned desc_ptr was accepted "
                            "(the FK33 needs 512)");
    if (c) { pl_close(c); c = NULL; }

    /* Straddling the HBM stack line.  x_stride*max_chunk = 256*8 = 2048, so a
     * base 1024 below the line straddles it. */
    small_opts(&s, &o); o.x_base = FK33_HBM_STACK_LINE - 1024;
    CK(pl_open(&o, &c) < 0, "a block straddling the stack line was accepted");
    if (c) { pl_close(c); c = NULL; }

    small_opts(&s, &o); o.l_base = o.x_base + 128;   /* inside the x span */
    CK(pl_open(&o, &c) < 0, "overlapping x and l blocks were accepted");
    if (c) { pl_close(c); c = NULL; }

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
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_SEQ_POS, 0);
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_N_STEP, 1);
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_X_BASE_LO, (uint32_t)xb);
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_X_BASE_HI, (uint32_t)(xb >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_L_BASE_LO, (uint32_t)lb);
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_L_BASE_HI, (uint32_t)(lb >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_DESC_PTR_LO, (uint32_t)dp);
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_DESC_PTR_HI, (uint32_t)(dp >> 32));
        t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_CTRL, FK33_CTRL_GO);
        t->reg_read32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_STATUS, &st);
        CK((st & FK33_ST_DONE) && !(st & FK33_ST_ERR), "mutated run status 0x%X", st);
        t->reg_read32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_ARGMAX, &got);
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

#define W(r, v) t->reg_write32(t->ctx, FK33_SEAM_BASE_PROPOSED + (r), (uint32_t)(v))
#define SETUP() do { W(FK33_SEAM_X_BASE_LO, xb); W(FK33_SEAM_X_BASE_HI, xb >> 32); \
                     W(FK33_SEAM_L_BASE_LO, lb); W(FK33_SEAM_L_BASE_HI, lb >> 32); \
                     W(FK33_SEAM_DESC_PTR_LO, dp); W(FK33_SEAM_DESC_PTR_HI, dp >> 32); } while (0)
#define GO_AND_READ() do { W(FK33_SEAM_CTRL, FK33_CTRL_GO); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_STATUS, &st); \
      t->reg_read32(t->ctx, FK33_SEAM_BASE_PROPOSED + FK33_SEAM_ERR_INFO, &info); } while (0)

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

    printf("\nSEAM_SELFTEST %s  (%d checks, %d failed)\n",
           fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
