/* ref/gdn_block_vec.c
 *
 * Subsystem B's BLOCK-LEVEL oracle: one Gated DeltaNet layer, N tokens,
 * computed end to end in fixed point, bit-exact, plus an independent
 * double-precision oracle over the same stimulus.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS
 * =====================================================================
 *
 * Before it, subsystem B had eleven unit-verified leaves and NO block-level
 * reference of any kind.  `sim/tb_gdn_block.vhd` says so in its own header:
 * "this testbench does not re-check arithmetic.  It checks the property that
 * would have caught all four [seam defects]" -- bit-identity of the dump under
 * every producer skew.  That is a property of the plumbing.  Correct units
 * wired to each other WRONGLY -- the wrong key head feeding a value head, q
 * and k swapped into the two L2 paths, a conv tap paired with the wrong slot
 * exponent, the z gate taken before the norm instead of after -- produce a
 * dump that is bit-identical across every skew and wrong in every one of them.
 *
 * Subsystem C was in exactly this position until `ref/attn_block_vec.c` was
 * written, and the first comparison came back 64 of 64 mantissas wrong in a
 * block that had passed seven properties and 13 of 17 wiring mutations
 * (commit 8baa413).  CLAUDE.md records the lesson as "a per-unit evidence
 * class says nothing about the composition".  This file closes B's instance.
 *
 * =====================================================================
 * INDEPENDENCE: what is shared with the RTL, and where each stage came from
 * =====================================================================
 *
 * The DATAFLOW -- which is the thing under test -- is written from the
 * specification, never from `rtl/gdn_block.vhd`.  Per stage:
 *
 *   stage                        source of the rule
 *   ---------------------------  --------------------------------------------
 *   segment order q, k, v and    spec 1.1(h): wqkv's output layout is plain
 *   head-major channels          [q | k | v], contiguous, head-major.
 *   tap index -> token           spec 1.1(e): x[0..2] are the stored state,
 *                                oldest first, x[3] is the current token.
 *                                The PORT packing (tap t at bits
 *                                [(t+1)*8-1 : t*8], current token in the top
 *                                byte, tvalid(t) = 1 for t >= K-n) is the
 *                                documented interface contract of
 *                                gdn_exp_capture; the spec pins the time
 *                                order but not the bit order, so that one
 *                                mapping is taken from the unit's interface
 *                                and is named here rather than hidden.
 *   masked taps                  spec 1.6 + 2.1.3: taps referring to tokens
 *                                < 0 are excluded from BOTH the products and
 *                                the e_ref minimum.
 *   conv and segment requantize  spec 2.1.3, transcribed; identical to
 *                                ref/gdn_conv_vec.c, whose bench is the
 *                                authority on it.
 *   silu on the WHOLE conv       spec 1.1(e): silu is applied afterwards to
 *   output, q and k included     the whole conv_dim, BEFORE the L2 norms.
 *   L2 norms                     spec 1.1(c) + 2.1.3; recipe from the
 *                                INCLUDED core of ref/l2norm_rs_vec.c.
 *   which head reads which k/q   spec 4 + the model: qwen35.cpp calls
 *                                ggml_repeat_4d(q_conv, head_k_dim,
 *                                num_v_heads), and ggml_repeat TILES, so
 *                                value head h reads key head h % KEY_HEADS.
 *                                Read off llama.cpp, not off the RTL.
 *   scalar path                  spec 2.1.3 as amended to Q18; recipe from
 *                                the INCLUDED core of ref/gdn_scalar_vec.c.
 *   the recurrence               spec 2.1.4 stages 1-5 as amended 2026-08-26
 *                                (D_NORM, TK0_ED, EG0_ED), transcribed;
 *                                identical to ref/gdn_recur_vec.c.
 *   site 12 head emit            spec 2.1.4 stage 6, transcribed.
 *   output rmsnorm               INCLUDED core of ref/rmsnorm_bf_vec.c.
 *   z gate and site 13 renorm    spec 2.1.2 (silu preserves the exponent) and
 *                                2.1.5 row 13, transcribed.
 *
 * WHY THE UNIT CORES ARE INCLUDED AND NOT TRANSCRIBED.  Four of them --
 * rmsnorm_bf, gdn_silu, gdn_scalar and l2norm_rs -- are approximation kernels
 * with their own double oracles and their own benches.  A second transcription
 * of an approximation kernel measures self-consistency and nothing else, which
 * is precisely how the collapsed L2 recipe survived 55 passing cases
 * (docs/debugging/2026-08-25_l2norm-recipe-collapse.md).  ref/gdn_emit_chain_vec.c
 * set this precedent and states the same reason.  The per-unit benches remain
 * the authority on those recipes; this file is the authority on how they are
 * wired together, and that is what it checks.
 *
 * The three transcribed recipes (conv, recurrence, the two emit sites) are
 * short, are pinned in the spec as normative code blocks, and are the same
 * arithmetic as ref/gdn_conv_vec.c, ref/gdn_recur_vec.c, ref/gdn_head_emit_vec.c
 * and ref/gdn_y_emit_vec.c, whose benches remain their authority.
 *
 * THE DOUBLE ORACLE runs the WHOLE block a second time in double precision
 * from the same stimulus, sharing no integer helper, no grid and no exponent.
 * It is the only check here that can see a wrong RECIPE rather than a wrong
 * transcription, and it is what would catch a shared misunderstanding of the
 * dataflow that both this file and the RTL happened to hold.
 *
 * =====================================================================
 * MASKED TAPS CARRY DELIBERATE GARBAGE
 * =====================================================================
 *
 * A tap that refers to a token before the start of the sequence must be
 * excluded from the products AND from the e_ref minimum.  Filling those taps
 * with zeros would make a failure to mask INVISIBLE in the products and
 * visible only through e_ref.  They are filled with large values and a wild
 * exponent instead, so an implementation that fails to mask diverges loudly on
 * the first token rather than subtly.
 *
 * =====================================================================
 * USAGE
 * =====================================================================
 *
 *   gdn_block_vec <outfile> [KEY_HEADS VAL_HEADS DIM TOKENS LAYERS KMAP SEED]
 *
 * KMAP is "mod" (the default, and what the model does) or "div"; see the KMAP
 * note below.
 *
 * Writes the STIMULUS and the expected outputs to <outfile>.  The stimulus is
 * in the file rather than recomputed in VHDL on purpose: a bench that
 * regenerated it would have two sources of truth for the inputs, and a
 * divergence between them would read as an arithmetic failure.
 *
 * Build: cc -O2 -Wall -o gdn_block_vec gdn_block_vec.c -lm
 */
#define GDN_CHAIN_INCLUDE
#include "rmsnorm_bf_vec.c"     /* rmsnorm_bf_int, bf_resolve_eps, N, EPS   */
#include "gdn_silu_vec.c"       /* to_q12, sigma_q15_from_q12, fx_init      */
#include "gdn_scalar_vec.c"     /* gdn_scalar_int, SP_Q                     */
#include "l2norm_rs_vec.c"      /* l2norm_rs                                */
#include "vec_seed.h"           /* the seed convention; see that header     */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#define KCONV 4
#define SEGS  3

/* ---- shape, from argv ---------------------------------------------------- */
static int KH, VH, D, NTOK, NLAYER;

/* ---------------------------------------------------------------------------
 * KMAP: which key head feeds value head h.  THE DEFAULT IS THE MODEL.
 *
 *   KMAP_MOD (default)  hk = h % KEY_HEADS
 *   KMAP_DIV            hk = h / (VAL_HEADS / KEY_HEADS)
 *
 * The model says MOD, and it says so twice over.  qwen35.cpp broadcasts q and
 * k with `ggml_repeat_4d(q_conv, head_k_dim, num_v_heads, ...)`, and ggml's
 * repeat TILES: `ggml_compute_forward_repeat_f32` writes destination row
 * `i1*ne01 + k1` from source row `k1`, so destination head h reads source head
 * `h % ne01` = `h % num_k_heads`.  The same answer comes from the other
 * direction: in the non-fused decode path `ggml_mul(s, k)` broadcasts a
 * [S, 1, H_k] operand against an [S, S, H_v] one, and every ggml broadcast
 * indexes the smaller operand MODULO its own extent.
 *
 * DIV is the GQA-style contiguous grouping.  It is what
 * `rtl/gdn_block.vhd`'s P_HKQ state implements (`base := (vh/VPK)*DIM*16`),
 * and it is a DIFFERENT permutation for every value head except the first and
 * the last.  It is selectable here for one reason only: so that the gate row
 * can hold every OTHER stage of the composition bit-exact while that defect
 * is open, and so that the defect can be reproduced on demand by running the
 * default.  It is NOT the oracle agreeing with the design.
 *
 * See docs/debugging/2026-08-29_gdn-block-oracle.md, defect B-BLK-1.
 * ------------------------------------------------------------------------- */
static int KMAP_DIV = 0;
static int key_head_of(int h){ return KMAP_DIV ? h / (VH/KH) : h % KH; }

/* ---- deterministic PRNG.  Same splitmix64 the other B generators use. ----- */
static uint64_t rs_;
static uint64_t rnd64(void){ uint64_t z=(rs_+=0x9E3779B97F4A7C15ULL);
  z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL; z=(z^(z>>27))*0x94D049BB133111EBULL;
  return z^(z>>31); }
static int32_t rr(int32_t lo, int32_t hi){
  return lo + (int32_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

static int   blk_msb_u(uint64_t v){ return mv4i_msb_pos_u(v); }
static int16_t blk_sat16(int64_t v){ return mv4i_sat16(v); }

/* ==========================================================================
 * The block, in fixed point.  One token.
 * ========================================================================== */

typedef struct {
    /* stimulus, owned by the caller */
    const int16_t *xtap;   /* [SEGS][chmax][KCONV], flattened by seg_base    */
    const int16_t *wtap;   /* same shape, token-independent                  */
    const int    *e_t;     /* [SEGS][KCONV]  captured slot exponents         */
    const int    *tvalid;  /* [SEGS][KCONV]  1 = tap refers to a real token  */
    const int    *cw_exp;  /* [SEGS]                                         */
    const int32_t *sc;     /* [VH][8] al_m al_e dt_m dt_e a_m a_e b_m b_e    */
    const int16_t *zm;     /* [VH][D]                                        */
    const int16_t *wm;     /* [D]  ssm_norm                                  */
    int  w_e, z_e;
    int  tk0;
    /* state, updated in place */
    int16_t *smem;         /* [VH][D][D]  column-major: smem[h][j][i]        */
    int     *semem;        /* [VH][D]                                        */
    /* outputs */
    int16_t *y;            /* [VH*D]                                         */
    int      y_exp;
    int      err_conv, err_g, err_se, y_sat;
} blk_t;

/* channel base of segment s in the flattened conv arrays */
static int seg_base(int s){ return (s == 0) ? 0 : (s == 1) ? KH*D : 2*KH*D; }
static int seg_nch (int s){ return (s == 2) ? VH*D : KH*D; }

static void gdn_block_token(blk_t *b)
{
    const int QCH = KH*D, VCH = VH*D;
    const int CHMAX = (QCH > VCH) ? QCH : VCH;
    int s, c, t, i, j, h;

    int  *e_seg  = malloc(SEGS * sizeof(int));
    int  *silu   = malloc(SEGS * CHMAX * sizeof(int));   /* post-silu mantissa */

    /* ---- spec 2.1.3: the conv, then the segment requantizer -------------- */
    for (s = 0; s < SEGS; s++) {
        const int nch = seg_nch(s);
        const int16_t *xs = b->xtap + (size_t)seg_base(s)*KCONV;
        const int16_t *ws = b->wtap + (size_t)seg_base(s)*KCONV;
        const int *et = b->e_t + s*KCONV, *tv = b->tvalid + s*KCONV;

        int e_ref = 0, have = 0;
        for (t = 0; t < KCONV; t++)
            if (tv[t]) { if (!have || et[t] < e_ref) { e_ref = et[t]; have = 1; } }
        if (!have) { fprintf(stderr, "gdn_block_vec: no valid conv tap\n"); exit(1); }

        int64_t *acc = malloc((size_t)nch * sizeof(int64_t));
        uint64_t amax = 0;
        for (c = 0; c < nch; c++) {
            int64_t a = 0;
            for (t = 0; t < KCONV; t++) {
                if (!tv[t]) continue;                 /* spec 1.6 masking */
                int sh = et[t] - e_ref; if (sh > 63) sh = 63;
                a += mv4i_floor_shr((int64_t)xs[(size_t)c*KCONV+t]
                                  * (int64_t)ws[(size_t)c*KCONV+t], sh);
            }
            acc[c] = a;
            uint64_t m = (uint64_t)llabs(a); if (m > amax) amax = m;
        }
        int e_acc  = e_ref + b->cw_exp[s];
        int sh_seg = blk_msb_u(amax) - 14; if (sh_seg < 0) sh_seg = 0;
        e_seg[s] = e_acc - sh_seg;
        if (e_seg[s] > 127 || e_seg[s] < -128) b->err_conv = 1;

        /* ---- spec 1.1(e)/2.1.3: silu over the WHOLE conv output, q and k
         * included, exponent PRESERVED. ---------------------------------- */
        for (c = 0; c < nch; c++) {
            int16_t sm = blk_sat16(mv4i_round_shift(acc[c], sh_seg));
            int32_t xq  = to_q12((int64_t)sm, e_seg[s]);
            int32_t sig = sigma_q15_from_q12(xq);
            silu[s*CHMAX + c] = (int)mv4i_round_shift((int64_t)sm * sig, 15);
        }
        free(acc);
    }

    /* ---- spec 1.1(c)/2.1.3: the per-key-head L2 norms.
     * The q segment produces q_s (exp 18, the 1/sqrt(D) fold); the k segment
     * produces k_n (exp 15, no fold).  One unit computes both outputs from
     * one input, so each segment is normed once and the unused output is
     * discarded -- which is what makes swapping the two segments a real and
     * detectable wiring error rather than a relabelling. ------------------ */
    int lg = 0; { int tt = D; while (tt >>= 1) lg++; }
    int *qs = malloc((size_t)KH*D*sizeof(int));
    int *kn = malloc((size_t)KH*D*sizeof(int));
    {
        int *xin = malloc((size_t)D*sizeof(int));
        int *ok  = malloc((size_t)D*sizeof(int));
        int *oq  = malloc((size_t)D*sizeof(int));
        for (h = 0; h < KH; h++) {
            for (i = 0; i < D; i++) xin[i] = silu[0*CHMAX + h*D + i];   /* q */
            l2norm_rs(xin, D, lg, ok, oq);
            for (i = 0; i < D; i++) qs[h*D+i] = oq[i];
            for (i = 0; i < D; i++) xin[i] = silu[1*CHMAX + h*D + i];   /* k */
            l2norm_rs(xin, D, lg, ok, oq);
            for (i = 0; i < D; i++) kn[h*D+i] = ok[i];
        }
        free(xin); free(ok); free(oq);
    }

    /* ---- spec 2.1.3: the scalar path, per VALUE head --------------------- */
    int *eg = malloc((size_t)VH*sizeof(int)), *beta = malloc((size_t)VH*sizeof(int));
    for (h = 0; h < VH; h++) {
        const int32_t *p = b->sc + (size_t)h*8;
        int e_, b_, g_;
        gdn_scalar_int(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], &e_, &b_, &g_);
        eg[h] = e_; beta[h] = b_; if (g_) b->err_g = 1;
    }

    /* ---- spec 2.1.4: the recurrence, per value head, per column ---------- */
    int64_t *o_acc = malloc((size_t)VH*D*sizeof(int64_t));
    int     *e_o   = malloc((size_t)VH*D*sizeof(int));
    int64_t *w18   = malloc((size_t)D*sizeof(int64_t));
    int64_t *u     = malloc((size_t)D*sizeof(int64_t));
    const int e_v_seg = e_seg[2];

    for (h = 0; h < VH; h++) {
        /* ggml_repeat_4d TILES, so value head h reads key head h % KH.  Not
         * h / (VH/KH): that is GQA grouping, a different tensor op.  See the
         * KMAP note at the top of this file. */
        const int hk = key_head_of(h);
        const int *k_n = kn + (size_t)hk*D, *q_s = qs + (size_t)hk*D;
        const int egh = eg[h], bth = beta[h];

        for (j = 0; j < D; j++) {
            int16_t *scol = b->smem + ((size_t)h*D + j)*D;
            const int se_j = b->semem[h*D + j];
            const int v_j  = silu[2*CHMAX + h*D + j];

            /* stage 1: decay */
            int64_t sk_acc = 0;
            for (i = 0; i < D; i++) {
                int64_t sm = b->tk0 ? 0 : scol[i];
                w18[i] = mv4i_round_shift(sm * (int64_t)egh, 13);
                sk_acc += w18[i] * (int64_t)k_n[i];     /* stage 2: sk dot */
            }
            int sh_sk = blk_msb_u((uint64_t)llabs(sk_acc)) - 14;
            if (sh_sk < 0) sh_sk = 0;
            int64_t skm = mv4i_round_shift(sk_acc, sh_sk);
            int ske = se_j + 17 - sh_sk;

            /* stage 3: delta.  masked = tk0 or eg = 0 (2.1.4 as amended) */
            const int masked = b->tk0 || (egh == 0);
            int e_d = masked ? e_v_seg : ((e_v_seg < ske) ? e_v_seg : ske);
            int s1 = e_v_seg - e_d, s2 = ske - e_d;
            if (s1 > 63) s1 = 63;
            if (s2 > 63) s2 = 63;
            int64_t diff = mv4i_floor_shr(v_j, s1) - mv4i_floor_shr(skm, s2);
            int64_t draw = diff * (int64_t)bth;
            int shd = blk_msb_u((uint64_t)llabs(draw)) - 14; if (shd < 0) shd = 0;
            int64_t d_m  = mv4i_round_shift(draw, shd);
            int e_dm = e_d + 16 - shd;

            /* stage 4: update and write-back quantizer */
            int e_kd = 15 + e_dm;
            int e_u  = masked ? e_kd : ((se_j + 2 < e_kd) ? se_j + 2 : e_kd);
            int su = se_j + 2 - e_u, sk2 = e_kd - e_u;
            if (su  > 63) su  = 63;
            if (sk2 > 63) sk2 = 63;
            uint64_t amax = 0;
            for (i = 0; i < D; i++) {
                int64_t kd = (int64_t)k_n[i] * d_m;
                u[i] = (b->tk0 ? 0 : mv4i_floor_shr(w18[i], su))
                     + mv4i_floor_shr(kd, sk2);
                uint64_t a = (uint64_t)llabs(u[i]); if (a > amax) amax = a;
            }
            int sh = blk_msb_u(amax) - 14; if (sh < 0) sh = 0;
            for (i = 0; i < D; i++) scol[i] = blk_sat16(mv4i_round_shift(u[i], sh));
            int se_new = e_u - sh;
            b->semem[h*D + j] = se_new;

            /* stage 5: output dot, on the REQUANTIZED mantissas */
            int64_t od = 0;
            for (i = 0; i < D; i++) od += (int64_t)scol[i] * (int64_t)q_s[i];
            o_acc[h*D + j] = od;
            e_o  [h*D + j] = se_new + 18;
            if (se_new > 127 || se_new < -128
             || e_o[h*D+j] > 127 || e_o[h*D+j] < -128) b->err_se = 1;
        }
    }

    /* ---- spec 2.1.4 stage 6 (site 12), the output norm, the z gate ------- */
    int16_t *prod_o = malloc((size_t)VH*D*sizeof(int16_t));
    int16_t *prod_z = malloc((size_t)VH*D*sizeof(int16_t));
    int     *ep     = malloc((size_t)VH*sizeof(int));
    int64_t *o_al   = malloc((size_t)D*sizeof(int64_t));
    int16_t *o_head = malloc((size_t)D*sizeof(int16_t));
    N = D;                                    /* rmsnorm_bf_vec.c's global */
    for (h = 0; h < VH; h++) {
        int e_h = e_o[h*D];
        for (j = 1; j < D; j++) if (e_o[h*D+j] < e_h) e_h = e_o[h*D+j];
        uint64_t amax = 0;
        for (j = 0; j < D; j++) {
            int shj = e_o[h*D+j] - e_h; if (shj > 63) shj = 63;
            o_al[j] = mv4i_floor_shr(o_acc[h*D+j], shj);
            uint64_t a = (uint64_t)llabs(o_al[j]); if (a > amax) amax = a;
        }
        int sh_h = blk_msb_u(amax) - 14; if (sh_h < 0) sh_h = 0;
        int e_head = e_h - sh_h;
        for (j = 0; j < D; j++) o_head[j] = blk_sat16(mv4i_round_shift(o_al[j], sh_h));

        bf_out r;
        rmsnorm_bf_int(o_head, e_head, b->wm, b->w_e, &r);

        for (j = 0; j < D; j++) {
            int32_t xq  = to_q12((int64_t)b->zm[(size_t)h*D+j], b->z_e);
            int32_t sig = sigma_q15_from_q12(xq);
            int64_t g   = mv4i_round_shift((int64_t)b->zm[(size_t)h*D+j] * sig, 15);
            prod_o[h*D+j] = r.o[j];
            prod_z[h*D+j] = blk_sat16(g);
        }
        ep[h] = r.o_exp + b->z_e;
    }

    /* ---- spec 2.1.5 row 13: the gated product and the whole-token renorm -- */
    {
        int e_y = ep[0];
        for (h = 1; h < VH; h++) if (ep[h] < e_y) e_y = ep[h];
        int64_t *p_al = malloc((size_t)VH*D*sizeof(int64_t));
        uint64_t amax = 0;
        for (h = 0; h < VH; h++) {
            int shj = ep[h] - e_y; if (shj > 63) shj = 63;
            for (j = 0; j < D; j++) {
                int64_t p = (int64_t)prod_o[h*D+j] * (int64_t)prod_z[h*D+j];
                p_al[h*D+j] = mv4i_floor_shr(p, shj);
                uint64_t a = (uint64_t)llabs(p_al[h*D+j]); if (a > amax) amax = a;
            }
        }
        int sh = blk_msb_u(amax) - 14; if (sh < 0) sh = 0;
        b->y_exp = e_y - sh;
        for (i = 0; i < VH*D; i++) {
            int64_t v = mv4i_round_shift(p_al[i], sh);
            if (v > 32767 || v < -32768) b->y_sat = 1;
            b->y[i] = blk_sat16(v);
        }
        free(p_al);
    }

    free(e_seg); free(silu); free(qs); free(kn); free(eg); free(beta);
    free(o_acc); free(e_o); free(w18); free(u);
    free(prod_o); free(prod_z); free(ep); free(o_al); free(o_head);
}

/* ==========================================================================
 * The same block in DOUBLE.  No grid, no shift, no exponent, no LUT: every
 * quantity is the real number the fixed path is approximating.  Shares only
 * the int16 stimulus and the integer exponents that give it a value.
 * ========================================================================== */
static double dsilu(double x){ return x / (1.0 + exp(-x)); }

static void gdn_block_token_dbl(const blk_t *b, double *sd, double *yd,
                                double *ynorm)
{
    const int QCH = KH*D, VCH = VH*D;
    const int CHMAX = (QCH > VCH) ? QCH : VCH;
    int s, c, t, i, j, h;
    double *sil = malloc((size_t)SEGS*CHMAX*sizeof(double));

    for (s = 0; s < SEGS; s++) {
        const int nch = seg_nch(s);
        const int16_t *xs = b->xtap + (size_t)seg_base(s)*KCONV;
        const int16_t *ws = b->wtap + (size_t)seg_base(s)*KCONV;
        const int *et = b->e_t + s*KCONV, *tv = b->tvalid + s*KCONV;
        for (c = 0; c < nch; c++) {
            double a = 0.0;
            for (t = 0; t < KCONV; t++) {
                if (!tv[t]) continue;
                a += ldexp((double)xs[(size_t)c*KCONV+t], -et[t])
                   * ldexp((double)ws[(size_t)c*KCONV+t], -b->cw_exp[s]);
            }
            sil[s*CHMAX + c] = dsilu(a);
        }
    }

    double *qd = malloc((size_t)KH*D*sizeof(double));
    double *kd = malloc((size_t)KH*D*sizeof(double));
    for (h = 0; h < KH; h++) {
        double nq = 0.0, nk = 0.0;
        for (i = 0; i < D; i++) { double a = sil[0*CHMAX+h*D+i]; nq += a*a; }
        for (i = 0; i < D; i++) { double a = sil[1*CHMAX+h*D+i]; nk += a*a; }
        nq = sqrt(nq); nk = sqrt(nk);
        for (i = 0; i < D; i++) {
            qd[h*D+i] = (nq > 0.0) ? sil[0*CHMAX+h*D+i] / (nq * sqrt((double)D)) : 0.0;
            kd[h*D+i] = (nk > 0.0) ? sil[1*CHMAX+h*D+i] / nk : 0.0;
        }
    }

    double *egd = malloc((size_t)VH*sizeof(double));
    double *btd = malloc((size_t)VH*sizeof(double));
    for (h = 0; h < VH; h++) {
        const int32_t *p = b->sc + (size_t)h*8;
        double al = ldexp((double)p[0], -p[1]);
        double dt = ldexp((double)p[2], -p[3]);
        double aa = ldexp((double)p[4], -p[5]);
        double bb = ldexp((double)p[6], -p[7]);
        double sp = log1p(exp(al + dt));
        if (al + dt > 30.0) sp = al + dt;
        double g = aa * sp;
        if (g > 0.0) g = 0.0;
        if (g < -16.0) g = -16.0;
        egd[h] = exp(g);
        btd[h] = 1.0 / (1.0 + exp(-bb));
    }

    double *od = malloc((size_t)VH*D*sizeof(double));
    /* The output dot is a D-term SIGNED sum and cancels heavily, so an error
     * measured against |sum| explodes wherever the sum is near zero while
     * every term is fine.  ref/gdn_recur_vec.c hit this first and emits the
     * sum of |terms| for the same reason; onm is that quantity here. */
    double *onm = malloc((size_t)VH*D*sizeof(double));
    for (h = 0; h < VH; h++) {
        const int hk = key_head_of(h);
        for (j = 0; j < D; j++) {
            double *scol = sd + ((size_t)h*D + j)*D;
            double v = sil[2*CHMAX + h*D + j];
            double sk = 0.0;
            for (i = 0; i < D; i++) {
                scol[i] = b->tk0 ? 0.0 : scol[i] * egd[h];
                sk += scol[i] * kd[hk*D+i];
            }
            double dl = (v - sk) * btd[h];
            double acc = 0.0, anrm = 0.0;
            for (i = 0; i < D; i++) {
                scol[i] += kd[hk*D+i] * dl;
                acc  += scol[i] * qd[hk*D+i];
                anrm += fabs(scol[i] * qd[hk*D+i]);
            }
            od [h*D+j] = acc;
            onm[h*D+j] = anrm;
        }
    }

    for (h = 0; h < VH; h++) {
        double ms = 0.0;
        for (j = 0; j < D; j++) ms += od[h*D+j]*od[h*D+j];
        ms /= (double)D;
        double gain = 1.0 / sqrt(ms + EPS);
        for (j = 0; j < D; j++) {
            double zr = ldexp((double)b->zm[(size_t)h*D+j], -b->z_e);
            double post = gain * ldexp((double)b->wm[j], -b->w_e) * dsilu(zr);
            yd   [h*D+j] = od [h*D+j] * post;
            ynorm[h*D+j] = onm[h*D+j] * fabs(post);
        }
    }
    free(sil); free(qd); free(kd); free(egd); free(btd); free(od); free(onm);
}

/* ========================================================================== */

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "gdn_block_vec.txt";
    KH     = (argc > 2) ? atoi(argv[2]) : 2;
    VH     = (argc > 3) ? atoi(argv[3]) : 4;
    D      = (argc > 4) ? atoi(argv[4]) : 32;
    NTOK   = (argc > 5) ? atoi(argv[5]) : 2;
    NLAYER = (argc > 6) ? atoi(argv[6]) : 2;
    if (argc > 7 && argv[7][0]) {
        if      (!strcmp(argv[7], "mod")) KMAP_DIV = 0;
        else if (!strcmp(argv[7], "div")) KMAP_DIV = 1;
        else { fprintf(stderr, "gdn_block_vec: KMAP must be mod or div\n"); return 1; }
    }
    rs_    = vec_seed(argc, argv, 8, 20260829ULL);

    if (KH < 1 || VH < KH || VH % KH != 0 || D < 8 || (D & (D-1)) != 0) {
        fprintf(stderr, "gdn_block_vec: VH must be a multiple of KH and D a "
                        "power of two >= 8\n");
        return 1;
    }
    fx_init();
    bf_resolve_eps();
    N = D;
    SP_Q = 18;

    const int QCH = KH*D, VCH = VH*D;
    const int CHTOT = 2*QCH + VCH;
    (void)QCH; (void)VCH;

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }

    /* ---- stimulus ------------------------------------------------------- */
    int16_t *wtap = calloc((size_t)CHTOT*KCONV, sizeof(int16_t));
    int16_t *wm   = calloc((size_t)D, sizeof(int16_t));
    int cw_exp[SEGS], w_e = 12, z_e = 12;
    for (int s = 0; s < SEGS; s++) cw_exp[s] = 11 + s;      /* per segment */
    for (int c = 0; c < CHTOT; c++)
        for (int t = 0; t < KCONV; t++)
            wtap[(size_t)c*KCONV+t] = (int16_t)rr(-2047, 2047);
    /* ssm_norm is a real norm weight: strictly positive, order 1 at exp 12 */
    for (int i = 0; i < D; i++) wm[i] = (int16_t)rr(2000, 6000);

    /* the per-token qkv history, from which the conv taps are drawn */
    int16_t *hist = calloc((size_t)NTOK*CHTOT, sizeof(int16_t));
    int     *cap  = calloc((size_t)NTOK*SEGS, sizeof(int));
    for (int t = 0; t < NTOK; t++) {
        for (int c = 0; c < CHTOT; c++)
            hist[(size_t)t*CHTOT + c] = (int16_t)rr(-2047, 2047);
        for (int s = 0; s < SEGS; s++) cap[t*SEGS + s] = 8 + ((t + s) % 5);
    }

    int32_t *sc = calloc((size_t)NTOK*VH*8, sizeof(int32_t));
    int16_t *zm = calloc((size_t)NTOK*VH*D, sizeof(int16_t));
    for (int t = 0; t < NTOK; t++)
        for (int h = 0; h < VH; h++) {
            int32_t *p = sc + ((size_t)t*VH + h)*8;
            /* the ranges the real Qwen3.8 weights occupy: ssm_a ~ -0.04,
             * dt bias ~ -3.5, alpha small (ref/gdn_scalar_vec.c's PHYSICAL
             * band) */
            p[0] = rr(-1000, 1000);      p[1] = 14;
            p[2] = -rr(2000, 32000);     p[3] = 12;
            p[4] = -rr(1, 3000);         p[5] = 16;
            p[6] = rr(-30000, 30000);    p[7] = 12;
            for (int j = 0; j < D; j++)
                zm[((size_t)t*VH + h)*D + j] = (int16_t)rr(-8192, 8192);
        }

    /* initial recurrent state: a BFP column shape, one element near full
     * scale and the rest spread below, with a NON-uniform exponent per column
     * so a write-back that transposes head and column is visible */
    int16_t *smem = calloc((size_t)VH*D*D, sizeof(int16_t));
    int     *semem= calloc((size_t)VH*D, sizeof(int));
    for (int h = 0; h < VH; h++)
        for (int j = 0; j < D; j++) {
            int top = rr(16384, 32767);
            for (int i = 0; i < D; i++)
                smem[((size_t)h*D + j)*D + i] = (int16_t)rr(-top, top);
            smem[((size_t)h*D + j)*D + rr(0, D-1)] = (int16_t)top;
            semem[h*D + j] = 9 + ((h + j) % 4);
        }

    /* The double oracle's own copy of the initial state.  It then runs free
     * across tokens, exactly as the fixed path does.
     *
     * MEASURED AND REJECTED: re-seeding sd from the dequantized fixed state at
     * every token, on the theory that the token-count dependence of the error
     * was the recurrence's accumulated drift.  It is not: the re-seed moved
     * the worst figure at (1, 3, 16, 4 tokens) from 26481.23 to 26464.24, a
     * change of 0.06%.  The real cause is CANCELLATION in the output dot, and
     * the fix is the term-norm denominator below. */
    double *sd = calloc((size_t)VH*D*D, sizeof(double));

    /* ---- header and the token-independent stimulus ---------------------- */
    fprintf(f, "%d %d %d %d %d %d %d %d %d\n", KH, VH, D, KCONV, NLAYER, NTOK,
            w_e, z_e, KMAP_DIV);
    for (int s = 0; s < SEGS; s++) fprintf(f, "%d ", cw_exp[s]); fprintf(f, "\n");
    for (int i = 0; i < D; i++) fprintf(f, "%d ", (int)wm[i]); fprintf(f, "\n");
    for (int c = 0; c < CHTOT; c++)
        for (int t = 0; t < KCONV; t++) fprintf(f, "%d ", (int)wtap[(size_t)c*KCONV+t]);
    fprintf(f, "\n");
    for (int a = 0; a < VH*D*D; a++) fprintf(f, "%d ", (int)smem[a]); fprintf(f, "\n");
    for (int a = 0; a < VH*D; a++)   fprintf(f, "%d ", semem[a]);     fprintf(f, "\n");

    /* ---- run ------------------------------------------------------------ */
    int16_t *xtap = calloc((size_t)CHTOT*KCONV, sizeof(int16_t));
    int16_t *y    = calloc((size_t)VH*D, sizeof(int16_t));
    double  *yd   = calloc((size_t)VH*D, sizeof(double));
    double  *yn   = calloc((size_t)VH*D, sizeof(double));
    int e_t[SEGS*KCONV], tv[SEGS*KCONV];
    int err_conv = 0, err_g = 0, err_se = 0, y_sat = 0;
    double worst = 0.0; int worst_tok = -1, worst_idx = -1;
    double worst_lsb = 0.0;
    long nsat = 0, nchecked = 0, nbad = 0;

    for (int t = 0; t < NTOK; t++) {
        /* spec 1.1(e): tap KCONV-1 is the CURRENT token, tap 0 the oldest.
         * gdn_exp_capture's counter saturates at KCONV, so after n captures
         * the valid taps are the newest n. */
        int n = t + 1; if (n > KCONV) n = KCONV;
        for (int s = 0; s < SEGS; s++)
            for (int k = 0; k < KCONV; k++) {
                int age = KCONV - 1 - k;          /* 0 = this token */
                int src = t - age;
                int ok  = (k >= KCONV - n);
                tv[s*KCONV+k] = ok;
                /* A masked tap carries GARBAGE, not zero, so that a failure
                 * to mask diverges loudly.  Its exponent is wild for the same
                 * reason: if it entered the e_ref minimum the whole segment
                 * would move by 40 octaves. */
                e_t[s*KCONV+k] = ok ? cap[src*SEGS + s] : -47;
            }
        for (int c = 0; c < CHTOT; c++)
            for (int k = 0; k < KCONV; k++) {
                int age = KCONV - 1 - k, src = t - age;
                xtap[(size_t)c*KCONV+k] = (src >= 0)
                    ? hist[(size_t)src*CHTOT + c]
                    : (int16_t)(-30000 + ((c * 7 + k * 13) % 60000));
            }

        blk_t b;
        memset(&b, 0, sizeof b);
        b.xtap = xtap; b.wtap = wtap; b.e_t = e_t; b.tvalid = tv;
        b.cw_exp = cw_exp; b.sc = sc + (size_t)t*VH*8; b.zm = zm + (size_t)t*VH*D;
        b.wm = wm; b.w_e = w_e; b.z_e = z_e; b.tk0 = (t == 0);
        b.smem = smem; b.semem = semem; b.y = y;
        gdn_block_token(&b);
        err_conv |= b.err_conv; err_g |= b.err_g;
        err_se   |= b.err_se;   y_sat |= b.y_sat;

        gdn_block_token_dbl(&b, sd, yd, yn);
        if (!b.y_sat) {
            double lsb = ldexp(1.0, -b.y_exp);
            for (int a = 0; a < VH*D; a++) {
                double got = ldexp((double)y[a], -b.y_exp);
                /* Denominator: one LSB of the shared y grid OR the element's
                 * own term norm, whichever is LARGER.  The LSB alone is
                 * meaningless where the D-term dot cancels; the term norm
                 * alone is meaningless where the element is genuinely zero. */
                double den = lsb;
                if (yn[a] > den) den = yn[a];
                double e = fabs(got - yd[a]) / den;
                double el = fabs(got - yd[a]) / lsb;
                if (el > worst_lsb) worst_lsb = el;
                nchecked++;
                if (e > 0.05) nbad++;
                if (e > worst) { worst = e; worst_tok = t; worst_idx = a; }
            }
        } else nsat++;

        /* ---- this token's stimulus and its expected output -------------- */
        for (int s = 0; s < SEGS; s++) fprintf(f, "%d ", cap[t*SEGS+s]);
        fprintf(f, "\n");
        for (int c = 0; c < CHTOT; c++)
            for (int k = 0; k < KCONV; k++)
                fprintf(f, "%d ", (int)xtap[(size_t)c*KCONV+k]);
        fprintf(f, "\n");
        for (int h = 0; h < VH; h++) {
            const int32_t *p = sc + ((size_t)t*VH + h)*8;
            for (int q = 0; q < 8; q++) fprintf(f, "%d ", (int)p[q]);
        }
        fprintf(f, "\n");
        for (int a = 0; a < VH*D; a++)
            fprintf(f, "%d ", (int)zm[(size_t)t*VH*D + a]);
        fprintf(f, "\n");
        fprintf(f, "%d\n", b.y_exp);
        for (int a = 0; a < VH*D; a++) fprintf(f, "%d ", (int)y[a]);
        fprintf(f, "\n");
    }

    for (int a = 0; a < VH*D*D; a++) fprintf(f, "%d ", (int)smem[a]); fprintf(f, "\n");
    for (int a = 0; a < VH*D; a++)   fprintf(f, "%d ", semem[a]);     fprintf(f, "\n");
    fprintf(f, "%d %d %d %d\n", err_conv, err_g, err_se, y_sat);
    fclose(f);

    fprintf(stderr,
        "gdn_block_vec: KH=%d VH=%d D=%d KCONV=%d tokens=%d kmap=%s -> %s\n",
        KH, VH, D, KCONV, NTOK, KMAP_DIV ? "div (RTL, defect B-BLK-1)"
                                         : "mod (the model)", out);
    fprintf(stderr, "  flags: err_conv=%d err_g=%d err_se=%d y_sat=%d "
                    "(%ld saturating tokens excluded from the oracle)\n",
            err_conv, err_g, err_se, y_sat, nsat);
    fprintf(stderr, "  worst end-to-end error vs the double oracle: %.6f, "
                    "relative to max(one y LSB, the element term norm) "
                    "(token %d, element %d)\n",
            worst, worst_tok, worst_idx);
    fprintf(stderr, "  elements compared: %ld of %ld;  over 0.05: %ld (%.2f%%)\n",
            nchecked, (long)NTOK*VH*D, nbad,
            nchecked ? 100.0*(double)nbad/(double)nchecked : 0.0);
    fprintf(stderr, "  worst error in bare y LSB, no term norm: %.4f\n", worst_lsb);

    /* SANITY bound, not a derived one.  Seven quantizing stages compose here
     * -- the conv requantize, silu, two L2 norms, the state write-back, the
     * head-emit requantize, the norm's own output grid and the final renorm --
     * and the state carries between tokens, so the per-stage bounds do not add
     * to anything tight.  The per-unit generators carry the derived bounds.
     * What this number has to catch is the failure class the emit chain's own
     * bound caught: an uninitialised shared LUT or epsilon, which produced
     * 9.4e8 and 1.6e11 LSB there.  MEASURED here: see the writeup; the bound
     * is set an order above the measured worst over nine seeds. */
    /* FOUR gates, not one.  A max alone is blind to a distribution shift: a
     * mutation that destroys a unit can read BETTER than the correct design on
     * a maximum while moving the whole distribution.  So the COUNT of elements
     * past 0.05 is gated as well, the bare-LSB max is kept as an unbounded
     * blow-up detector, and the number of elements actually COMPARED is gated
     * with a floor -- a run that compares nothing must not be able to pass,
     * which is the failure a max and a count share.
     *
     * MEASURED over 29 seeds at KH=2 VH=4 D=32 tokens=2, kmap=div:
     *
     *   worst error     0.1224 (seed 1)  ..  0.4973 (seed 77777)
     *   over 0.05       0.00% (most)     ..  10.94% (seed 1)
     *   compared        256 of 256 in every run
     *
     * And across SHAPES, which is what the term-norm denominator bought: with
     * the old LSB-only denominator the same figure ran 9.97 at
     * (2,4,32,2 tokens) to 26481 at (1,3,16,4 tokens), so a bound calibrated
     * on one shape fired spuriously on another.  With this denominator the six
     * shapes measured span 0.135 to 0.544, the top of that range being the
     * real 9B shape (16 key heads, 32 value heads, DIM 128).
     *
     * FOUR GATES, AND THE MAX IS THE WEAKEST OF THEM.  MEASURED: with
     * fx_init() removed, or with bf_resolve_eps() removed -- the two failures
     * that bit ref/gdn_emit_chain_vec.c, each as a silent wrong answer -- the
     * term-norm MAX reads 0.664 and 0.665, BELOW the 2.0 bound, while the
     * COUNT reads 99.22% in both.  The max got SMALLER than a legitimate seed
     * can produce while the design was destroyed, because a term-norm
     * denominator structurally caps the ratio near 1 when the output collapses
     * to zero.  So the count is what carries this bench, the bare-LSB figure
     * is kept as an unbounded blow-up detector -- it reads 3.2e7 and 9.6e30 on
     * those same two -- and the floor on elements compared stops a run that
     * checks nothing from passing.  A max alone would have missed both. */
    int bad = 0;
    if (worst > 2.0) {
        fprintf(stderr, "  FAIL: end-to-end error is far larger than the "
                        "composed quantization can explain\n");
        bad = 1;
    }
    if (nchecked && 100.0*(double)nbad/(double)nchecked > 45.0) {
        fprintf(stderr, "  FAIL: %.2f%% of elements are over 0.05 from the "
                        "double oracle; the DISTRIBUTION has moved, not just "
                        "one element\n", 100.0*(double)nbad/(double)nchecked);
        bad = 1;
    }
    /* The bare-LSB figure is kept as a fourth gate, loose on purpose.  It is
     * shape-sensitive -- 9.97 at (2,4,32,2 tokens) against 26481 at
     * (1,3,16,4 tokens) on identical, correct code -- so it cannot be tight,
     * but it is the only one of the four that grows without bound, and the
     * two uninitialised-global failures reach 3.2e7 and 9.6e30 on it. */
    if (worst_lsb > 1.0e6) {
        fprintf(stderr, "  FAIL: worst bare-LSB error %.4g is a blow-up, not "
                        "quantization\n", worst_lsb);
        bad = 1;
    }
    if (nsat == 0 && nchecked != (long)NTOK*VH*D) {
        fprintf(stderr, "  FAIL: only %ld of %ld elements were compared\n",
                nchecked, (long)NTOK*VH*D);
        bad = 1;
    }
    if (bad) return 1;
    fprintf(stderr, "  OK\n");
    return 0;
}
