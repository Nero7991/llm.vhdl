/* ref/gdn_block_cap_vec.c
 *
 * Subsystem B's block oracle, driven from an INTEGRATION-LEVEL capture.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS
 * =====================================================================
 *
 * `tools/ref9b/seamgate.sh` closes every run with the sentence that names its
 * own largest hole:
 *
 *     Every unchecked seam is subsystem B's `R_Y`, which has no
 *     integration-level model.
 *
 * and `tools/ref9b/bisect_scaled.py`'s header states the reason it was
 * believed unreachable:
 *
 *     Subsystem B's is not reachable the same way: its input includes a
 *     recurrent state no region holds.
 *
 * THAT REASON DOES NOT HOLD AT THE CONFIGURATIONS THE GATE RUNS, and the fact
 * is in `rtl/llama_top.vhd`, not in an argument.  Every input its unit-B
 * adapter drives is either a captured region or a deterministic function of an
 * index, so `R_Y` is computable from the capture.  That is a property of THIS
 * top level rather than of subsystem B.
 *
 * THE STATE CARRY IS NOW LIVE, AND THIS FILE ALREADY HAD IT.  When this file
 * was written the adapter drove `b_tk0 <= '1'` on every token ("one token
 * only; there is no token loop yet") and pulsed `b_seq_rst` once per TOKEN, so
 * `rtl/gdn_recur_pipe.vhd`'s TK0_ED masked the state read everywhere and
 * `tvalid` marked ONLY tap `KCONV-1` valid: `R_Y` was a pure function of ONE
 * token's inputs.  Defect B-TOP-1 fixed both drivers on 2026-08-29 -- `b_tk0`
 * follows `tok_pos`, and `b_seq_rst` fires only at `tok_pos = 0`, which is
 * what `rtl/gdn_exp_capture.vhd`'s own header says that port is for -- so the
 * recurrence runs and the conv gains a tap history.
 *
 * NOTHING IN THIS FILE HAD TO CHANGE FOR THAT, which is exactly why `smem` and
 * `semem` were allocated per layer and the loops run layer-major from the
 * start, even while `tk0` was 1 everywhere and the state was inert.
 * `tools/ref9b/gdn_oracle.py` writes the `tk0`, `tvalid` and `e_t` this driver
 * reads, and that is what moved.  The `tk0 = 0 at token 0` refusal below still
 * stands: it means the caller believes in a state no capture carries.
 *
 * =====================================================================
 * INDEPENDENCE
 * =====================================================================
 *
 * The arithmetic is `gdn_block_token()` in `ref/gdn_block_vec.c`, INCLUDED
 * rather than copied, exactly as `ref/attn_block_cap_vec.c` includes
 * `ref/attn_block_vec.c`.  Nothing new is computed here.  What is new is the
 * SOURCE of the stimulus.
 *
 * NO RTL CONSTANT APPEARS IN THIS FILE.  The conv weights, the conv taps, the
 * per-head `ssm_dt_bias` / `ssm_a` scalars and the `ssm_norm` weight are
 * `rtl/llama_top.vhd`'s `m12` stand-ins -- testbench constants, the same
 * standing as `qkn_const` on the attention side -- and they arrive in the
 * stimulus file, written by `tools/ref9b/gdn_oracle.py`.  That is the same
 * split `ref/attn_block_cap_vec.c` states and for the same reason: a model
 * that transcribed a bench constant would go quietly wrong the day the bench
 * changed it.
 *
 * WHAT IS STILL SHARED, and it is `ref/gdn_block_vec.c`'s own limit restated:
 * the per-site fixed-point numerics of the four approximation kernels
 * (`rmsnorm_bf`, `gdn_silu`, `gdn_scalar`, `l2norm_rs`), which that file
 * INCLUDES rather than transcribes.  What is checked here is the COMPOSITION:
 * the segment order, the tap masking, the silu over the whole conv output,
 * which L2 output feeds which path, which key head feeds which value head, the
 * five recurrence stages, the head emit, the output rmsnorm, the z gate and
 * the whole-token renormalisation.
 *
 * =====================================================================
 * USAGE
 * =====================================================================
 *
 *   gdn_block_cap_vec <stimulus> <predictions> [kmap]
 *
 * `kmap` is "mod" (the default, and what the model does) or "div"; it selects
 * which key head feeds value head h, and it exists for the reason
 * `ref/gdn_block_vec.c`'s KMAP note gives -- so that a report can say what the
 * design does instead of only that it disagrees.  It is NOT the oracle moving
 * to accommodate the RTL.
 *
 * The stimulus file is one flat integer stream:
 *
 *   KH VH D KCONV NLAY NTOK W_E KMAP_DIV
 *   cw_exp[3]
 *   wm[D]
 *   per layer l = 0..NLAY-1, per token t = 0..NTOK-1:
 *     tk0 z_exp
 *     e_t[3*KCONV]
 *     tvalid[3*KCONV]
 *     xtap[CHTOT*KCONV]        CHTOT = 2*KH*D + VH*D, channel-major
 *     wtap[CHTOT*KCONV]
 *     sc[VH*8]                 al_m al_e dt_m dt_e a_m a_e b_m b_e
 *     zm[VH*D]
 *
 * The predictions file is:
 *
 *   per layer l, per token t:
 *     Y <l> <t> <y_exp> <VH*D> <err_conv> <err_g> <err_se> <y_sat>
 *     y_mant[VH*D]
 *
 * WHY THE TAPS AND WEIGHTS ARE PER (LAYER, TOKEN) even though the machine's
 * present stand-ins are constant in both: with `B_SRC_REAL` the newest tap
 * comes from `R_QKV` and moves every token, and a format that could not carry
 * that would have to be changed by whoever first runs that configuration --
 * which is the moment they are least likely to notice the format was the thing
 * that limited them.
 *
 * Build: cc -O2 -Wall -o gdn_block_cap_vec gdn_block_cap_vec.c -lm
 */
#define GDN_BLOCK_VEC_NO_MAIN
#include "gdn_block_vec.c"

static int rd_int(FILE *f, const char *what)
{
    long v;
    if (fscanf(f, "%ld", &v) != 1) {
        fprintf(stderr, "gdn_block_cap_vec: stimulus ended while reading %s\n",
                what);
        exit(2);
    }
    return (int)v;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: gdn_block_cap_vec <stimulus> <predictions> "
                        "[mod|div]\n");
        return 2;
    }
    int kmap_argv = -1;                 /* -1 = not given on the command line */
    if (argc > 3 && argv[3][0]) {
        if      (!strcmp(argv[3], "mod")) kmap_argv = 0;
        else if (!strcmp(argv[3], "div")) kmap_argv = 1;
        else { fprintf(stderr, "gdn_block_cap_vec: kmap must be mod or div\n");
               return 2; }
    }

    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }

    KH = rd_int(f, "KEY_HEADS");
    VH = rd_int(f, "VAL_HEADS");
    D  = rd_int(f, "DIM");
    int kc = rd_int(f, "KCONV");
    NLAYER = rd_int(f, "NLAY");
    NTOK   = rd_int(f, "NTOK");
    int w_e = rd_int(f, "W_E");
    KMAP_DIV = rd_int(f, "KMAP_DIV") ? 1 : 0;
    /* THE COMMAND LINE WINS, and the header is the default.  Two places can
     * say which key map to use, so which one is authoritative has to be
     * written down rather than left to whichever line runs last. */
    if (kmap_argv >= 0) KMAP_DIV = kmap_argv;

    /* The shape assertions `ref/gdn_block_vec.c`'s own main makes, restated
     * here because this driver has a different caller and an out-of-range
     * shape must be a refusal and not a wrong answer. */
    if (kc != KCONV) {
        fprintf(stderr, "gdn_block_cap_vec: this oracle is built for KCONV=%d "
                        "and the stimulus says %d.  KCONV is a compile-time "
                        "constant of ref/gdn_block_vec.c; refusing rather than "
                        "silently modelling a different conv.\n", KCONV, kc);
        return 2;
    }
    if (KH < 1 || VH < KH || VH % KH != 0 || D < 8 || (D & (D - 1)) != 0) {
        fprintf(stderr, "gdn_block_cap_vec: VH must be a multiple of KH and D "
                        "a power of two >= 8 (got KH=%d VH=%d D=%d)\n",
                KH, VH, D);
        return 2;
    }

    fx_init();
    bf_resolve_eps();
    N    = D;      /* rmsnorm_bf_vec.c's global */
    SP_Q = 18;     /* rtl/gdn_block.vhd:220's default, and llama_top does not
                    * override it.  It is a GENERIC of the design, so it is
                    * pinned here next to the other two globals rather than
                    * left at whatever the last includer set. */

    const int SEGS_ = 3;
    const int CHTOT = 2 * KH * D + VH * D;

    int cw_exp[3];
    for (int s = 0; s < SEGS_; s++) cw_exp[s] = rd_int(f, "cw_exp");
    int16_t *wm = calloc((size_t)D, sizeof(int16_t));
    for (int i = 0; i < D; i++) wm[i] = (int16_t)rd_int(f, "wm");

    int16_t *xtap = calloc((size_t)CHTOT * KCONV, sizeof(int16_t));
    int16_t *wtap = calloc((size_t)CHTOT * KCONV, sizeof(int16_t));
    int32_t *sc   = calloc((size_t)VH * 8, sizeof(int32_t));
    int16_t *zm   = calloc((size_t)VH * D, sizeof(int16_t));
    int16_t *y    = calloc((size_t)VH * D, sizeof(int16_t));
    int *e_t = calloc((size_t)SEGS_ * KCONV, sizeof(int));
    int *tv  = calloc((size_t)SEGS_ * KCONV, sizeof(int));

    /* One state per LAYER, carried across tokens.  It is allocated and passed
     * even though `tk0` is 1 in every configuration this file has been run
     * against, because the alternative -- not allocating it -- would make the
     * first `tk0 = 0` run read uninitialised memory and produce a plausible
     * wrong answer instead of an obvious one. */
    int16_t **smem = calloc((size_t)NLAYER, sizeof(int16_t *));
    int     **semem = calloc((size_t)NLAYER, sizeof(int *));
    for (int l = 0; l < NLAYER; l++) {
        smem[l]  = calloc((size_t)VH * D * D, sizeof(int16_t));
        semem[l] = calloc((size_t)VH * D, sizeof(int));
    }

    FILE *o = fopen(argv[2], "w");
    if (!o) { perror(argv[2]); return 2; }
    fprintf(o, "# ref/gdn_block_cap_vec.c: subsystem B's R_Y from the "
               "machine's own captured inputs\n");
    fprintf(o, "# KH=%d VH=%d D=%d KCONV=%d layers=%d tokens=%d kmap=%s\n",
            KH, VH, D, KCONV, NLAYER, NTOK, KMAP_DIV ? "div" : "mod");

    /* LAYER-MAJOR, and it matters for the same reason it does on the attention
     * side: the state is per layer and carried across tokens, so every token
     * of one layer must run in ascending token order before the next layer
     * starts.  The machine's own schedule is token-major, which would fold one
     * layer's state into another's. */
    for (int l = 0; l < NLAYER; l++) {
        for (int t = 0; t < NTOK; t++) {
            int tk0  = rd_int(f, "tk0");
            int z_e  = rd_int(f, "z_exp");
            for (int i = 0; i < SEGS_ * KCONV; i++) e_t[i] = rd_int(f, "e_t");
            for (int i = 0; i < SEGS_ * KCONV; i++) tv[i]  = rd_int(f, "tvalid");
            for (int i = 0; i < CHTOT * KCONV; i++)
                xtap[i] = (int16_t)rd_int(f, "xtap");
            for (int i = 0; i < CHTOT * KCONV; i++)
                wtap[i] = (int16_t)rd_int(f, "wtap");
            for (int i = 0; i < VH * 8; i++) sc[i] = rd_int(f, "sc");
            for (int i = 0; i < VH * D; i++) zm[i] = (int16_t)rd_int(f, "zm");

            /* THE REFUSAL.  `tk0 = 0` at token 0 means the caller believes a
             * state exists that this driver was never given, and the answer it
             * would produce -- a zero state -- is a legal-looking wrong one. */
            if (t == 0 && !tk0) {
                fprintf(stderr, "gdn_block_cap_vec: layer %d token 0 says "
                                "tk0=0, so it reads a recurrent state that no "
                                "capture carries.  Refusing: a zero state here "
                                "is a plausible wrong answer, not a model.\n",
                        l);
                return 2;
            }

            blk_t b;
            memset(&b, 0, sizeof b);
            b.xtap = xtap; b.wtap = wtap; b.e_t = e_t; b.tvalid = tv;
            b.cw_exp = cw_exp; b.sc = sc; b.zm = zm; b.wm = wm;
            b.w_e = w_e; b.z_e = z_e; b.tk0 = tk0;
            b.smem = smem[l]; b.semem = semem[l]; b.y = y;
            gdn_block_token(&b);

            fprintf(o, "Y %d %d %d %d %d %d %d %d\n", l, t, b.y_exp, VH * D,
                    b.err_conv, b.err_g, b.err_se, b.y_sat);
            for (int i = 0; i < VH * D; i++)
                fprintf(o, "%d%c", (int)y[i], (i % 16 == 15) ? '\n' : ' ');
            if ((VH * D) % 16) fprintf(o, "\n");
        }
    }

    /* TRAILING JUNK IS A FORMAT ERROR, NOT A CURIOSITY.  A stimulus with more
     * records than the header's NLAY*NTOK means the writer and this reader
     * disagree about the layout, and every prediction above was then read from
     * the wrong offset. */
    long extra;
    if (fscanf(f, "%ld", &extra) == 1) {
        fprintf(stderr, "gdn_block_cap_vec: the stimulus has data past "
                        "%d layers x %d tokens.  The writer and this reader "
                        "disagree about the layout.\n", NLAYER, NTOK);
        return 2;
    }
    fclose(f);
    fclose(o);
    return 0;
}
