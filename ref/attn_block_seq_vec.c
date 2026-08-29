/* ref/attn_block_seq_vec.c
 *
 * Subsystem C's SEQUENCE oracle: N tokens of gated grouped-query attention
 * over one layer, where the KV cache each token reads is what the earlier
 * tokens WROTE.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS
 * =====================================================================
 *
 * ref/attn_block_vec.c checks ONE token against a SYNTHETIC cache: it makes
 * up the records at positions 0..cur_pos-1 and hands the same numbers to the
 * bench's memory model.  That is exactly the right check for the dataflow
 * inside a token, and it found two real defects.  It cannot see anything
 * about the APPEND, because in it no record is ever both written and later
 * read:
 *
 *   * `v_ref` is a per-SEQUENCE minimum folded over every record ever
 *     written (C spec 2.1.4).  With one token per sequence the fold is
 *     checked at its FIRST value and never across an append.  A design that
 *     reset it per token, or folded the wrong head's record, is bit-exact on
 *     every single-token vector that exists.
 *   * The address equation `((layer*N_KVH + head)*MAXCTX + pos)*REC_B` is
 *     never checked for CONSISTENCY between the write of a record and the
 *     read of it.  Two masters agreeing on a wrong address produce a perfect
 *     single-token result.
 *   * C spec 2.7's rule that `done` must wait for BRESP exists only because
 *     token T's write is read by token T+1 through a different master.  With
 *     one token there is no T+1 and the rule is unfalsifiable.
 *
 * So this generator runs a real sequence.  Token t has cur_pos = t; it
 * attends over [t, 0, 1, ..., t-1]; the records at 0..t-1 are the quantized
 * records tokens 0..t-1 wrote, and `v_ref` folds across all of them.
 *
 * =====================================================================
 * INDEPENDENCE
 * =====================================================================
 *
 * The arithmetic is `attn_token()` in ref/attn_block_vec.c, INCLUDED rather
 * than copied.  That is deliberate and it is the opposite of the usual rule:
 * a second copy of an oracle drifts, and a drift between two oracles is
 * invisible because they are never compared to each other.  What is new here
 * is not arithmetic, it is the CACHE -- the thing under test is whether the
 * RTL's cache after t tokens is the one this file's cache-after-t-tokens
 * says it is, and that is a property of the loop below, not of the fixed
 * point.  The independence argument of attn_block_vec.c carries over
 * unchanged and is not restated.
 *
 * =====================================================================
 * USAGE
 * =====================================================================
 *
 *   attn_block_seq_vec <outfile>
 *       [HEAD_DIM N_QH N_KVH KV_BLOCK N_ROT NTOK NLAY SEED]
 *
 * The file is one flat integer stream:
 *
 *   HEAD_DIM N_QH N_KVH KV_BLOCK N_ROT NTOK CTX_LEN NLAY
 *   qg_exp kin_exp vin_exp qn_exp kn_exp
 *   per layer l = 0 .. NLAY-1:  qnw[HEAD_DIM]
 *   per layer l = 0 .. NLAY-1:  knw[HEAD_DIM]
 *   per STEP s = 0 .. NTOK*NLAY-1, in the schedule order below:
 *     qg[2*HEAD_DIM*N_QH]        the step's Q and gate source
 *     kin[HEAD_DIM*N_KVH]        its K source
 *     vin[HEAD_DIM*N_KVH]        its V source
 *     y_exp
 *     y_mant[N_QH*HEAD_DIM]
 *     per KV head h:             the record this step WRITES, quantized
 *       k_exp[NBLK] k_mant[HEAD_DIM] v_exp[NBLK] v_mant[HEAD_DIM]
 *
 * The record image is emitted because "the block computed the right numbers"
 * and "the record landed at the right address in HBM" are different claims
 * and a bench that only checked y could not tell a wrong address from a
 * wrong value.
 *
 * =====================================================================
 * THE SCHEDULE, AND WHY IT INTERLEAVES
 * =====================================================================
 *
 * The step order is TOKEN-major, LAYER-minor:
 *
 *   s = t*NLAY + l,   t = s / NLAY,   l = s % NLAY
 *
 * so the run is (tok 0, lay 0), (tok 0, lay 1), (tok 1, lay 0), ...  That is
 * the order a transformer actually runs: every layer sees token t before any
 * layer sees token t+1.  It is also the ONLY order in which the per-layer
 * state under test is genuinely contended.  Running layer 0's whole sequence
 * and then layer 1's would leave layer 0 untouched by layer 1 -- half the
 * defect would be invisible and the other half would look like a first-token
 * effect.
 *
 * Three pieces of state are per-LAYER and were unfalsifiable while this
 * generator emitted one layer:
 *
 *   * `v_ref` is a minimum folded per (LAYER, KV head) over every record
 *     ever written -- C spec 2.1.4, and defect C1
 *     (docs/debugging/2026-08-29_c1-vref-layer.md).  `rtl/attn_block.vhd`
 *     holds ONE fold register array and time-shares it across every
 *     attention layer, so a fold indexed by head alone lets each layer's
 *     write-time minimum leak into every other layer's alignment shift.
 *     With one layer in the stream there is nothing to leak from and the
 *     defect is bit-exact on every vector that existed before this change.
 *   * The address equation's `layer` term,
 *     `((layer*N_KVH + head)*MAXCTX + pos)*REC_B`.  With one layer it is
 *     multiplied by a constant and a design that dropped the term entirely
 *     is byte-identical at LAYER_SEL = 0.
 *   * The QK-norm weights are a per-layer property that `attn_block` LATCHES
 *     at `start`.  One set of weights for the whole run cannot tell a latch
 *     from a wire, nor a latch that samples the previous job's weights.
 *
 * So the weights, the activations and the folds below are all per-layer, and
 * a layer index that is dropped, shared or off by one changes the numbers.
 */
#define ATTN_BLOCK_VEC_NO_MAIN
#include "attn_block_vec.c"

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "attn_block_seq_vec.txt";
    int N     = (argc > 2) ? atoi(argv[2]) : 64;
    int N_QH  = (argc > 3) ? atoi(argv[3]) : 4;
    int N_KVH = (argc > 4) ? atoi(argv[4]) : 2;
    int KVB   = (argc > 5) ? atoi(argv[5]) : 16;
    int N_ROT = (argc > 6) ? atoi(argv[6]) : 16;
    int NTOK  = (argc > 7) ? atoi(argv[7]) : 4;
    int NLAY  = (argc > 8) ? atoi(argv[8]) : 2;
    int SEED  = (argc > 9) ? atoi(argv[9]) : 0;
    int NSTEP = NTOK * NLAY;
    int l, s;

    int NBLK = N / KVB;
    int AW_D = clog2i(N);
    int G    = N_QH / N_KVH;
    int NY   = N_QH * N;

    int qg_exp = 12, kin_exp = 11, vin_exp = 10, qn_exp = 12, kn_exp = 12;
    int *qg, *kin, *vin, *qnw, *knw;
    int *ckm, *ckh, *cvm, *cvh, *vref;
    int *ymant, *yexpv;
    int t, h, b, d, i;
    FILE *f;

    tables_init();

    if (N % KVB || N_QH % N_KVH || (1 << AW_D) != N || (AW_D & 1)
        || N_ROT % 2 || N_ROT > N || G < 2 || NBLK < 2 || N_KVH < 2
        || NTOK < 2 || NLAY < 2) {
        fprintf(stderr, "attn_block_seq_vec: illegal shape.  N_KVH >= 2 is "
                        "REQUIRED (worklog OI-2's history), NTOK >= 2 is "
                        "the whole point of this generator, and NLAY >= 2 is "
                        "what makes the per-layer v_ref fold, the address "
                        "equation's layer term and the QK-norm latch "
                        "falsifiable at all.\n");
        return 2;
    }
    /* rtl/attn_kv_axi.vhd's record format is a BYTE layout on a 16-byte
     * granule: the mantissa area of one KV block must be a whole number of
     * granules, i.e. KV_BLOCK*CM_W/8 must be a multiple of 16.  Checked here
     * rather than left to the VHDL elaboration assert, because a vector file
     * for a shape the RTL refuses is a wasted run. */
    if ((KVB * 8 / 8) % 16 != 0) {
        fprintf(stderr, "attn_block_seq_vec: KV_BLOCK*CM_W/8 = %d is not a "
                        "multiple of the 16-byte record granule; "
                        "rtl/attn_kv_axi.vhd cannot address it.\n", KVB);
        return 2;
    }
    if (NBLK > 16) {
        fprintf(stderr, "attn_block_seq_vec: NBLK = %d exceeds the 16-byte "
                        "header chunk.\n", NBLK);
        return 2;
    }

    qg    = malloc(sizeof(int) * (size_t)NSTEP * 2 * N * N_QH);
    kin   = malloc(sizeof(int) * (size_t)NSTEP * N * N_KVH);
    vin   = malloc(sizeof(int) * (size_t)NSTEP * N * N_KVH);
    qnw   = malloc(sizeof(int) * (size_t)NLAY * N);
    knw   = malloc(sizeof(int) * (size_t)NLAY * N);
    ckm   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * N);
    ckh   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * NBLK);
    cvm   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * N);
    cvh   = malloc(sizeof(int) * (size_t)NLAY * N_KVH * NTOK * NBLK);
    vref  = malloc(sizeof(int) * (size_t)NLAY * N_KVH);
    ymant = malloc(sizeof(int) * (size_t)NSTEP * NY);
    yexpv = malloc(sizeof(int) * NSTEP);

    /* The norm weights are a LAYER property: they do not move between tokens
     * and they DO move between layers.  `attn_block` latches them at `start`,
     * so a run whose every job carries the same weights cannot tell a latch
     * from a wire.  Held positive and away from zero for the reason
     * attn_block_vec.c states: a weight vector straddling zero makes max|raw|
     * a property of one element and turns the comparison into a comparison of
     * clamps. */
    for (l = 0; l < NLAY; l++) {
        for (i = 0; i < N; i++) {
            int a = m12(31337 + SEED + 5171 * l, i);
            qnw[(size_t)l * N + i] = (a < 0 ? -a : a) + 256;
            a = m12(51501 + SEED + 5171 * l, i);
            knw[(size_t)l * N + i] = (a < 0 ? -a : a) + 256;
        }
    }
    /* Per-STEP activations.  The token AND layer indices go into the hash
     * SEED and not into the element index, so no step's vector is a shifted
     * copy of another's -- a shifted copy would make a cache read at the
     * wrong position, or at the wrong LAYER, look almost right. */
    for (s = 0; s < NSTEP; s++) {
        t = s / NLAY; l = s % NLAY;
        for (i = 0; i < 2 * N * N_QH; i++)
            qg[(size_t)s * 2 * N * N_QH + i]
                = m12(7919 + SEED + 1013 * t + 7717 * l, i);
        for (i = 0; i < N * N_KVH; i++)
            kin[(size_t)s * N * N_KVH + i]
                = m12(104729 + SEED + 1013 * t + 7717 * l, i);
        for (i = 0; i < N * N_KVH; i++)
            vin[(size_t)s * N * N_KVH + i]
                = m12(65537 + SEED + 1013 * t + 7717 * l, i);
    }

    /* v_ref is reset ONCE, per SEQUENCE, and it is a SEPARATE minimum per
     * layer.  Resetting it per token is C spec 2.1.4's silent failure;
     * SHARING it across layers is defect C1.  This array and the interleaved
     * loop below are the only place any oracle in this project can see
     * either. */
    for (i = 0; i < NLAY * N_KVH; i++) vref[i] = 127;

    /* TOKEN-major, LAYER-minor: every layer sees token t before any layer
     * sees token t+1.  See THE SCHEDULE above for why the other order would
     * hide half of what this loop exists to expose. */
    for (s = 0; s < NSTEP; s++) {
        t = s / NLAY; l = s % NLAY;
        attn_token(N, N_QH, N_KVH, KVB, N_ROT, /*CPOS=*/t, SEED,
                   qg  + (size_t)s * 2 * N * N_QH,
                   kin + (size_t)s * N * N_KVH,
                   vin + (size_t)s * N * N_KVH,
                   qnw + (size_t)l * N, knw + (size_t)l * N,
                   qg_exp, kin_exp, vin_exp, qn_exp, kn_exp,
                   /*synth=*/0, /*append=*/1, /*CSTRIDE=*/NTOK,
                   ckm + (size_t)l * N_KVH * NTOK * N,
                   ckh + (size_t)l * N_KVH * NTOK * NBLK,
                   cvm + (size_t)l * N_KVH * NTOK * N,
                   cvh + (size_t)l * N_KVH * NTOK * NBLK,
                   vref + (size_t)l * N_KVH,
                   ymant + (size_t)s * NY, &yexpv[s]);
    }

    f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d %d %d %d %d %d\n",
            N, N_QH, N_KVH, KVB, N_ROT, NTOK, NTOK, NLAY);
    fprintf(f, "%d %d %d %d %d\n", qg_exp, kin_exp, vin_exp, qn_exp, kn_exp);
    for (l = 0; l < NLAY; l++) {
        for (i = 0; i < N; i++) fprintf(f, "%d ", qnw[(size_t)l * N + i]);
        fprintf(f, "\n");
    }
    for (l = 0; l < NLAY; l++) {
        for (i = 0; i < N; i++) fprintf(f, "%d ", knw[(size_t)l * N + i]);
        fprintf(f, "\n");
    }
    for (s = 0; s < NSTEP; s++) {
        size_t cb;
        t = s / NLAY; l = s % NLAY;
        for (i = 0; i < 2 * N * N_QH; i++)
            fprintf(f, "%d ", qg[(size_t)s * 2 * N * N_QH + i]);
        fprintf(f, "\n");
        for (i = 0; i < N * N_KVH; i++)
            fprintf(f, "%d ", kin[(size_t)s * N * N_KVH + i]);
        fprintf(f, "\n");
        for (i = 0; i < N * N_KVH; i++)
            fprintf(f, "%d ", vin[(size_t)s * N * N_KVH + i]);
        fprintf(f, "\n");
        fprintf(f, "%d\n", yexpv[s]);
        for (i = 0; i < NY; i++) fprintf(f, "%d ", ymant[(size_t)s * NY + i]);
        fprintf(f, "\n");
        for (h = 0; h < N_KVH; h++) {
            /* The record this STEP wrote lives in layer l's slice at
             * (head h, position t).  Emitting it in STEP order is what lets
             * the bench check the ADDRESS: it recomputes the address from
             * (l, h, t) and compares against the step's own record, so a
             * design that dropped the layer term writes layer 1's record over
             * layer 0's and the two disagree. */
            cb = (size_t)l * N_KVH * NTOK;
            for (b = 0; b < NBLK; b++)
                fprintf(f, "%d ", ckh[(cb + h * NTOK + t) * NBLK + b]);
            for (d = 0; d < N; d++)
                fprintf(f, "%d ", ckm[(cb + h * NTOK + t) * N + d]);
            for (b = 0; b < NBLK; b++)
                fprintf(f, "%d ", cvh[(cb + h * NTOK + t) * NBLK + b]);
            for (d = 0; d < N; d++)
                fprintf(f, "%d ", cvm[(cb + h * NTOK + t) * N + d]);
            fprintf(f, "\n");
        }
    }
    fclose(f);
    return 0;
}
