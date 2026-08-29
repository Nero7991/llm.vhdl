/* ref/attn_block_cap_vec.c
 *
 * Subsystem C's block oracle, driven from an INTEGRATION-LEVEL capture.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS
 * =====================================================================
 *
 * `docs/debugging/2026-08-29_first-bisect.md` closes with the coverage hole
 * that made mutation R7 unkillable on the numbers:
 *
 *     NOT CHECKED  R_Y-3   subsystem C has no integration-level model
 *
 * `tools/ref9b/bisect_scaled.py` recomputes 58 of 63 seams from the machine's
 * own captured inputs.  The four `R_Y` seams are the ones it emits and does
 * not compare, so a wrong `R_Y` is fed forward AS GIVEN and every later
 * comparison still passes.  R7 -- the `v_ref` sequence reset issued per TOKEN
 * rather than per SEQUENCE -- lands exactly there, and could until now be
 * killed only by comparing the machine against ITSELF.
 *
 * `ref/attn_block_vec.c` already contains the oracle.  What was missing was a
 * way to drive it from what `sim/tb_llama_top.vhd` captures rather than from
 * its own synthetic stimulus.  That turns out to be possible for a reason
 * worth stating: subsystem C's ENTIRE input at the integration level is three
 * captured regions, `R_QG`, `R_KIN` and `R_VIN`, plus two layer constants;
 * and the KV cache it reads at token t is exactly the records tokens 0..t-1
 * wrote from THEIR captured `R_KIN`/`R_VIN`.  So the whole sequence state is
 * reconstructible from the capture, with nothing taken from the RTL.
 *
 * =====================================================================
 * INDEPENDENCE
 * =====================================================================
 *
 * The arithmetic is `attn_token()` in `ref/attn_block_vec.c`, INCLUDED rather
 * than copied, for the reason `ref/attn_block_seq_vec.c` states: two copies of
 * an oracle drift, and the drift is invisible because they are never compared
 * against each other.  Nothing new is computed here.  What is new is the
 * SOURCE of the stimulus -- a file the capture reader writes -- and the loop
 * over (layer, token) that keeps one cache and one `v_ref` fold per attention
 * layer for the whole sequence.
 *
 * The QK-norm gains are NOT generated here.  They are a testbench constant of
 * `rtl/llama_top.vhd` (`qkn_const`), not model arithmetic, and they arrive in
 * the stimulus file so that this program contains no transcription of any RTL
 * constant at all.
 *
 * WHAT IS STILL SHARED, and it is `attn_block_vec.c`'s own limit restated:
 * the per-site fixed-point numerics.  This oracle checks the COMPOSITION --
 * which head reads which K, that V is neither normed nor roped, that the gate
 * is the second half of each head's projection, the RoPE pairing, the online
 * softmax order, and now the CACHE across tokens.  It does not independently
 * check each site's rounding rule; that is the business of the ten unit
 * benches.
 *
 * =====================================================================
 * USAGE
 * =====================================================================
 *
 *   attn_block_cap_vec <stimulus> <predictions> [fold]
 *
 * `fold` selects WHICH v_ref fold is modelled, and it exists because the two
 * candidates are the question rather than a detail:
 *
 *   perlayer  (default)  one `v_ref` per (layer, KV head), reset once per
 *                        SEQUENCE.  This is C spec 2.1.4 as
 *                        `ref/attn_block_vec.c` states it and as
 *                        `rtl/attn_block.vhd:111-119` describes its own SEAM 2.
 *   shared               ONE `v_ref` per KV head for the whole design, folded
 *                        in the machine's schedule order (token-major, layer
 *                        ascending within a token).  This is what a single
 *                        time-shared `attn_block` instance with
 *                        `vref_r : e8_arr(0 to N_KVH-1)` actually does when it
 *                        is driven at more than one attention layer.
 *   pertoken             `v_ref` reset per TOKEN.  Mutation R7's behaviour,
 *                        modelled so that a kill can be attributed rather than
 *                        merely observed.
 *
 * Offering all three is the point: a model that only implemented the spec
 * could say the RTL disagrees with it and could not say what the RTL does
 * instead, and "what it does instead" is the half a defect report needs.
 *
 * The stimulus file is one flat integer stream, written by
 * `tools/ref9b/attn_oracle.py` from a capture:
 *
 *   HEAD_DIM N_QH N_KVH KV_BLOCK N_ROT NLAY NTOK
 *   qn_exp kn_exp
 *   qnw[HEAD_DIM]
 *   knw[HEAD_DIM]
 *   per layer l = 0..NLAY-1, per token t = 0..NTOK-1:
 *     cur_pos qg_exp kin_exp vin_exp
 *     qg[2*HEAD_DIM*N_QH]
 *     kin[HEAD_DIM*N_KVH]
 *     vin[HEAD_DIM*N_KVH]
 *
 * The predictions file is:
 *
 *   per layer l, per token t:
 *     Y <l> <t> <y_exp> <N_QH*HEAD_DIM>
 *     y_mant[N_QH*HEAD_DIM]
 *     VREF <l> <t> <v_ref per KV head, after this token>
 *
 * ORDER MATTERS AND IT IS LAYER-MAJOR.  `v_ref` is folded per (layer, KV head)
 * across the whole SEQUENCE, so every token of one layer must be run in
 * ascending token order before the next layer starts, with that layer's own
 * cache and its own `v_ref`.  Interleaving the layers the way the machine's
 * schedule does would fold one layer's records into another layer's minimum
 * and produce a wrong-but-plausible answer.
 */
#define ATTN_BLOCK_VEC_NO_MAIN
#include "attn_block_vec.c"

static int rdint(FILE *f, const char *what)
{
    int v;
    if (fscanf(f, "%d", &v) != 1) {
        fprintf(stderr, "attn_block_cap_vec: stimulus ended while reading %s\n",
                what);
        exit(2);
    }
    return v;
}

int main(int argc, char **argv)
{
    const char *sin  = (argc > 1) ? argv[1] : "attn_cap_stim.txt";
    const char *out  = (argc > 2) ? argv[2] : "attn_cap_pred.txt";
    const char *fold = (argc > 3) ? argv[3] : "perlayer";
    int MODE;                       /* 0 perlayer, 1 shared, 2 pertoken */
    FILE *f, *g;
    int N, N_QH, N_KVH, KVB, N_ROT, NLAY, NTOK;
    int qn_exp, kn_exp;
    int *qnw, *knw, *qg, *kin, *vin, *cpos, *qge, *kie, *vie;
    int *ckm, *ckh, *cvm, *cvh, *vref, *ymant, *yexpv;
    int NBLK, AW_D, G, NY, l, t, h, i, yexp;
    size_t QGN, KVN;

    if (!strcmp(fold, "perlayer"))      MODE = 0;
    else if (!strcmp(fold, "shared"))   MODE = 1;
    else if (!strcmp(fold, "pertoken")) MODE = 2;
    else {
        fprintf(stderr, "attn_block_cap_vec: fold must be perlayer, shared or "
                        "pertoken, not '%s'\n", fold);
        return 2;
    }

    f = fopen(sin, "r");
    if (!f) { perror(sin); return 1; }
    N     = rdint(f, "HEAD_DIM");
    N_QH  = rdint(f, "N_QH");
    N_KVH = rdint(f, "N_KVH");
    KVB   = rdint(f, "KV_BLOCK");
    N_ROT = rdint(f, "N_ROT");
    NLAY  = rdint(f, "NLAY");
    NTOK  = rdint(f, "NTOK");
    qn_exp = rdint(f, "qn_exp");
    kn_exp = rdint(f, "kn_exp");

    NBLK = N / KVB;
    AW_D = clog2i(N);
    G    = N_QH / N_KVH;
    NY   = N_QH * N;

    /* The shape rules `attn_block` asserts at elaboration.  Checked here so a
     * stimulus for a shape the RTL refuses fails loudly rather than producing
     * a prediction nobody can compare against. */
    if (N % KVB || N_QH % N_KVH || (1 << AW_D) != N || (AW_D & 1)
        || N_ROT % 2 || N_ROT > N || G < 2 || NBLK < 2 || N_KVH < 2
        || NLAY < 1 || NTOK < 1) {
        fprintf(stderr, "attn_block_cap_vec: illegal shape "
                "HEAD_DIM=%d N_QH=%d N_KVH=%d KV_BLOCK=%d N_ROT=%d "
                "NLAY=%d NTOK=%d\n", N, N_QH, N_KVH, KVB, N_ROT, NLAY, NTOK);
        return 2;
    }

    tables_init();

    QGN = (size_t)2 * N * N_QH;
    KVN = (size_t)N * N_KVH;
    qnw   = malloc(sizeof(int) * N);
    knw   = malloc(sizeof(int) * N);
    qg    = malloc(sizeof(int) * QGN * NLAY * NTOK);
    kin   = malloc(sizeof(int) * KVN * NLAY * NTOK);
    vin   = malloc(sizeof(int) * KVN * NLAY * NTOK);
    cpos  = malloc(sizeof(int) * (size_t)NLAY * NTOK);
    qge   = malloc(sizeof(int) * (size_t)NLAY * NTOK);
    kie   = malloc(sizeof(int) * (size_t)NLAY * NTOK);
    vie   = malloc(sizeof(int) * (size_t)NLAY * NTOK);
    /* one cache per attention LAYER, always: the cache is addressed by
     * (layer, head, pos) in every candidate, and only the v_ref fold is in
     * question. */
    ckm   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * N);
    ckh   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * NBLK);
    cvm   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * N);
    cvh   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * NBLK);
    vref  = malloc(sizeof(int) * (size_t)NLAY * N_KVH);
    ymant = malloc(sizeof(int) * NY);
    yexpv = malloc(sizeof(int) * (size_t)NLAY * NTOK);

    for (i = 0; i < N; i++) qnw[i] = rdint(f, "qnw");
    for (i = 0; i < N; i++) knw[i] = rdint(f, "knw");

    for (l = 0; l < NLAY; l++) {
        for (t = 0; t < NTOK; t++) {
            size_t j = (size_t)l * NTOK + t;
            cpos[j] = rdint(f, "cur_pos");
            qge[j]  = rdint(f, "qg_exp");
            kie[j]  = rdint(f, "kin_exp");
            vie[j]  = rdint(f, "vin_exp");
            if (cpos[j] != t) {
                fprintf(stderr, "attn_block_cap_vec: layer %d token %d carries "
                        "cur_pos %d.  This driver models one contiguous "
                        "sequence, so cur_pos must equal the token index; a "
                        "capture that disagrees needs a cache this program "
                        "does not build.\n", l, t, cpos[j]);
                return 2;
            }
            for (i = 0; i < (int)QGN; i++) qg[j * QGN + i]  = rdint(f, "qg");
            for (i = 0; i < (int)KVN; i++) kin[j * KVN + i] = rdint(f, "kin");
            for (i = 0; i < (int)KVN; i++) vin[j * KVN + i] = rdint(f, "vin");
        }
    }
    fclose(f);

    for (i = 0; i < NLAY * N_KVH; i++) vref[i] = 127;
    for (i = 0; i < NLAY * N_KVH * NTOK * N; i++) { ckm[i] = 0; cvm[i] = 0; }
    for (i = 0; i < NLAY * N_KVH * NTOK * NBLK; i++) { ckh[i] = 0; cvh[i] = 0; }

    g = fopen(out, "w");
    if (!g) { perror(out); return 1; }
    fprintf(g, "# ref/attn_block_cap_vec.c: subsystem C's block oracle, driven\n"
               "# from an integration capture.  HEAD_DIM=%d N_QH=%d N_KVH=%d\n"
               "# KV_BLOCK=%d N_ROT=%d NLAY=%d NTOK=%d fold=%s\n",
            N, N_QH, N_KVH, KVB, N_ROT, NLAY, NTOK, fold);

    /* THE ORDER OF THIS DOUBLE LOOP IS THE EXPERIMENT.
     *
     * perlayer / pertoken: layer-major.  Each layer's v_ref is independent, so
     *   the order between layers cannot matter and layer-major is the clearer
     *   statement of that.
     * shared: token-major, layers ascending inside a token, because that is
     *   the machine's own schedule order and a shared fold is order-dependent
     *   by construction.  Running it layer-major would answer a question
     *   nobody asked. */
    {
        int outer = (MODE == 1) ? NTOK : NLAY;
        int inner = (MODE == 1) ? NLAY : NTOK;
        int a, b_;
        for (a = 0; a < outer; a++) {
            for (b_ = 0; b_ < inner; b_++) {
                size_t j;
                int vbase;
                l = (MODE == 1) ? b_ : a;
                t = (MODE == 1) ? a  : b_;
                j = (size_t)l * NTOK + t;
                /* MODE 1 shares ONE v_ref array across every layer; the other
                 * two give each layer its own slice. */
                vbase = (MODE == 1) ? 0 : l * N_KVH;
                if (MODE == 2)
                    for (h = 0; h < N_KVH; h++) vref[vbase + h] = 127;

                attn_token(N, N_QH, N_KVH, KVB, N_ROT, cpos[j], /*SEED=*/0,
                           qg + j * QGN, kin + j * KVN, vin + j * KVN,
                           qnw, knw,
                           qge[j], kie[j], vie[j], qn_exp, kn_exp,
                           /*synth=*/0, /*append=*/1, /*CSTRIDE=*/NTOK,
                           ckm + (size_t)l * N_KVH * NTOK * N,
                           ckh + (size_t)l * N_KVH * NTOK * NBLK,
                           cvm + (size_t)l * N_KVH * NTOK * N,
                           cvh + (size_t)l * N_KVH * NTOK * NBLK,
                           vref + vbase, ymant, &yexp);

                yexpv[j] = yexp;
                fprintf(g, "Y %d %d %d %d\n", l, t, yexp, NY);
                for (i = 0; i < NY; i++) fprintf(g, "%d ", ymant[i]);
                fprintf(g, "\n");
                /* The v_ref fold AFTER this token, per KV head.  Emitted
                 * because the difference between the three folds is entirely
                 * in these numbers, and a report that only showed the y values
                 * would say two models disagree without saying where. */
                fprintf(g, "VREF %d %d", l, t);
                for (h = 0; h < N_KVH; h++) fprintf(g, " %d", vref[vbase + h]);
                fprintf(g, "\n");
            }
        }
    }
    fclose(g);
    return 0;
}
