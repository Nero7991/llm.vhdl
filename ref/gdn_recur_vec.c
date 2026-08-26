/* gdn_recur_vec: test vectors for rtl/gdn_recur.vhd, subsystem B 2.1.4.
 *
 * Emits, per case: the inputs, the FIXED expected outputs, and the same column
 * computed by a DOUBLE-PRECISION ORACLE.  Both are dumped because they check
 * different things and neither alone is sufficient:
 *
 *   RTL vs FIXED   is bit-exact and catches transcription-into-VHDL errors
 *                  precisely, but it CANNOT catch an error in the recipe
 *                  itself -- both sides would share it.  That is exactly how
 *                  the l2norm recipe collapse survived 55 passing cases; see
 *                  docs/debugging/2026-08-25_l2norm-recipe-collapse.md.
 *
 *   RTL vs ORACLE  is in a different number system entirely, so it does catch
 *                  a wrong recipe.  It is necessarily a TOLERANCE check, since
 *                  the fixed path is meant to differ from the oracle by its
 *                  quantization error.
 *
 * The fixed path here is the same arithmetic as gdn_err.c's, through the same
 * mv4i primitives, restricted to one column of one head so the RTL can be
 * driven directly.
 *
 * Build: cc -O2 -Wall -Wextra -o ref/gdn_recur_vec ref/gdn_recur_vec.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include "mv4i_arith.h"

#define floor_shr(v, sh)   mv4i_floor_shr((v), (sh))
#define round_shift(v, sh) mv4i_round_shift((v), (sh))
#define msb_pos_u(a)       mv4i_msb_pos_u((a))

#define DIM 128
/* 96 physically-shaped columns + 96 adversarial + one FULL-LENGTH head.
 *
 * The long head matters and is not padding: a real head is 128 columns of one
 * k/q streamed continuously, and a pipelined implementation only ever sees a
 * head boundary once per 128 columns.  Testing with 8-column groups leaves the
 * continuous-streaming case -- where every slot is reused many times over and
 * the engines never idle -- completely unexercised.  Slot reuse is exactly the
 * defect class a short group cannot reach. */
#define NPHYS 96
#define NADV  96
#define NLONG 128
/* tk = 0 columns with a WIDE e_v - se_j spread.
 *
 * The other physical groups tie e_v to se_j within +/-8, which is right in
 * steady state: both describe the same activation scale.  AT tk = 0 IT IS
 * WRONG, and wrong in the one place it matters.  There is no state, so se_j is
 * stale header garbage and any spread is physically realizable -- and the
 * spread is exactly what exposes the stage-3 phantom-exponent defect, because
 * at tk = 0 sk_acc is zero, msb_pos(0) = 0, ske = se_j + 17, and
 * e_d = min(e_v, ske) floors v on a grid derived from a state that does not
 * exist.  With the +/-8 tie the min is inert and the defect is invisible.
 *
 * These are PHYS on purpose: they are realizable inputs, so the oracle check
 * applies to them. */
#define NTK0  64
#define NCASE (NPHYS + NADV + NLONG + NTK0)

static uint64_t rs_;
static uint64_t rnd64(void){ uint64_t z=(rs_+=0x9E3779B97F4A7C15ULL);
  z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL; z=(z^(z>>27))*0x94D049BB133111EBULL;
  return z^(z>>31); }
static int32_t rnd_range(int32_t lo, int32_t hi){
  return lo + (int32_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

/* D_NORM: normalize d onto its OWN grid instead of inheriting e_d.
 *
 *   pinned      d_m = round_shift(diff*beta, 16)          e_dm = e_d
 *   normalized  shd = max(0, msb_pos(|diff*beta|) - 14)
 *               d_m = round_shift(diff*beta, shd)         e_dm = e_d + 16 - shd
 *
 * The two collapse to ONE code path: shd = 16 gives e_dm = e_d + 16 - 16 = e_d
 * and reproduces the pinned form exactly, so the flag chooses shd and nothing
 * else.  That is deliberate -- it means the pinned form is not a separate
 * branch that could drift away from the one under test.
 *
 * See docs/debugging/2026-08-26_gdn-first-token-dm-grid.md for why this
 * matters: as pinned, d_m is quantized on a grid set by max(|v|,|sk|) rather
 * than by |d|, and at tk = 0 the state is exactly k_n*d_m so it inherits that
 * error whole.
 */
/* ---------------------------------------------------------------------------
 * The measured per-head decay gate.
 *
 * This used to draw eg from [27853, 32767] on the stated grounds that the
 * table "ranges over roughly 0.85..0.99997".  The table it cited says
 * otherwise: 522 of 2304 heads (22.7%) are below 0.85 at alpha = 0, 162 are
 * below 0.5 and 25 are below 0.05, with a minimum of 1.17e-4.  Every accuracy
 * number measured with the old draw therefore excluded almost a quarter of the
 * real model, including the whole region where the state term is small enough
 * for the update's grid to dominate.  So sample the actual file instead of
 * asserting a range over it.
 * ------------------------------------------------------------------------- */
static int   eg_tab[4096];
static int   eg_n = 0;

static void load_eg_table(void)
{
    FILE *f = fopen("ref/gdn_eg_qwen3_27b.txt", "r");
    char line[512];
    if (!f) { fprintf(stderr, "gdn_eg_qwen3_27b.txt missing\n"); exit(1); }
    while (fgets(line, sizeof line, f) && eg_n < 4096) {
        int L, H; double e, a, b;
        if (line[0] == '#') continue;
        if (sscanf(line, "%d %d %lf %lf %lf", &L, &H, &e, &a, &b) != 5) continue;
        if (!(e > 0.0 && e <= 1.0)) continue;
        long q = lround(e * 32768.0);
        if (q > 32768) q = 32768;
        if (q < 0) q = 0;
        eg_tab[eg_n++] = (int)q;
    }
    fclose(f);
    if (eg_n == 0) { fprintf(stderr, "no eg rows parsed\n"); exit(1); }
}

/* One eg for a head group.  Deliberately stratified rather than uniform, so
 * the two structural corners are always present instead of appearing by luck:
 *   sel 0  eg = 32768  gate fully open (alpha drives softplus to ~0)
 *   sel 5  eg = 0      gate fully SHUT.  Mid-sequence this makes the decayed
 *                      state term identically zero for the whole column --
 *                      the same masked-operand shape as tk = 0, but tk0 does
 *                      not gate it, so se_j still enters e_u's minimum.  That
 *                      is the one member of the class 2.1.4's corrections do
 *                      not cover, and it had never been generated.
 *   else   the measured distribution
 */
static int pick_eg(int sel)
{
    if (sel == 0) return 32768;
    if (sel == 5) return 0;
    return eg_tab[rnd_range(0, eg_n - 1)];
}

int main(int argc, char **argv)
{
    load_eg_table();
    const char *out = argc > 1 ? argv[1] : "sim/gdn_recur_vec.txt";
    /* Default to the ADOPTED recipe (2026-08-26).  Defaulting to 0 emitted the
       superseded form, which no longer matches either RTL unit's defaults. */
    int d_norm  = (argc > 2) ? (atoi(argv[2]) != 0) : 1;
    int tk0_ed  = (argc > 3) ? (atoi(argv[3]) != 0) : 1;
    FILE *f = fopen(out, "w");
    if (!f) { perror("fopen"); return 1; }
    rs_ = 20260825ULL;

    int ncase = 0;
    /* COLUMNS ARE EMITTED IN HEAD-GROUPS.  k_n, q_s, eg, beta and tk0 are
     * per-head-per-token, NOT per column: a head's 128 columns all see the same
     * ones.  Holding them constant across GRP consecutive cases lets a
     * PIPELINED implementation read them straight off its ports, with no
     * per-column storage, while the single-column testbench is unaffected --
     * it simply re-drives identical values.  The file format is unchanged. */
    static int16_t g_kn[DIM], g_qs[DIM];
    int g_eg = 0, g_beta = 0, g_tk0 = 0;
    const int GRP = 8;
    /* group id, so a consumer knows where a head begins without assuming a
     * fixed group size */
    int gid = 0;
    /* header: number of cases, then DIM */
    fprintf(f, "%d %d\n", NCASE, DIM);

    /* TWO GROUPS, and the distinction is load-bearing.
     *
     *   PHYS cases are physically realizable inputs to this recurrence: k_n is
     *   an actual unit-norm vector at exp 15 (that is what l2norm_rs emits),
     *   q_s carries the 1/sqrt(128) fold at exp 18, eg sits near 1 as a decay
     *   gate does, beta is in (0,1), and the exponents of the state and of v
     *   are within a plausible spread of each other.  These are checked BOTH
     *   bit-exactly and against the double oracle, because the accuracy claim
     *   is a claim about inputs the model actually produces.
     *
     *   ADV cases are adversarial corners: full-scale random k (which is NOT a
     *   unit vector and cannot occur), saturation corners, zeros, extreme
     *   exponent spreads that drive the shift clamps.  These are checked
     *   BIT-EXACTLY ONLY.  Holding them to an accuracy tolerance would be
     *   measuring the recipe against inputs it was never designed for, and
     *   would produce either false alarms or a tolerance loosened until it
     *   caught nothing -- the failure mode tb_l2norm_rs already hit from the
     *   other direction.
     */
    for (int c = 0; c < NCASE; c++) {
        int longhead = (c >= NPHYS + NADV) && (c < NPHYS + NADV + NLONG);
        int widetk0  = (c >= NPHYS + NADV + NLONG);
        int phys = (c < NPHYS) || longhead || widetk0;
        int tk0, se_j, e_v, eg, beta;
        int16_t smant[DIM], kn[DIM], qs[DIM];
        int32_t v_j;

        if (widetk0) {
            /* first token, and the e_v/se_j spread swept across the +17 knee */
            int a = c - (NPHYS + NADV + NLONG);
            tk0  = 1;
            se_j = rnd_range(-40, 40);
            e_v  = se_j + (a - 16) * 3;      /* -48 .. +141 relative to se_j */
            if (e_v >  120) e_v =  120;
            if (e_v < -120) e_v = -120;
            if (a % 8 == 0) {
                g_eg   = pick_eg((a / 8) % 6);
                g_beta = rnd_range(1, 65535);
                double kd[DIM], qd[DIM], nk = 0.0, nq = 0.0;
                for (int i = 0; i < DIM; i++) {
                    kd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                    qd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                    nk += kd[i]*kd[i]; nq += qd[i]*qd[i];
                }
                nk = sqrt(nk); nq = sqrt(nq);
                for (int i = 0; i < DIM; i++) {
                    long kv = lround(kd[i] / nk * 32768.0);
                    long qv = lround(qd[i] / nq / sqrt((double)DIM) * 262144.0);
                    if (kv >  32767) { kv =  32767; }
                    if (kv < -32768) { kv = -32768; }
                    if (qv >  32767) { qv =  32767; }
                    if (qv < -32768) { qv = -32768; }
                    g_kn[i] = (int16_t)kv; g_qs[i] = (int16_t)qv;
                }
            }
            eg = g_eg; beta = g_beta;
            memcpy(kn, g_kn, sizeof kn); memcpy(qs, g_qs, sizeof qs);
            int top = rnd_range(16384, 32767);
            for (int i = 0; i < DIM; i++) smant[i] = (int16_t)rnd_range(-top, top);
            v_j = rnd_range(-32768, 32767);
            if (v_j == 0) v_j = 12345;
        } else if (longhead) {
            /* one head, 128 columns, one k/q/eg/beta/tk0 for all of them */
            int a = c - (NPHYS + NADV);
            se_j = rnd_range(-40, 40);
            e_v  = se_j + rnd_range(-8, 8);
            if (a == 0) {
                g_tk0  = 0;            /* steady state: the common case */
                g_eg   = pick_eg(a % 6);
                g_beta = rnd_range(1, 65535);
                double kd[DIM], qd[DIM], nk = 0.0, nq = 0.0;
                for (int i = 0; i < DIM; i++) {
                    kd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                    qd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                    nk += kd[i]*kd[i]; nq += qd[i]*qd[i];
                }
                nk = sqrt(nk); nq = sqrt(nq);
                for (int i = 0; i < DIM; i++) {
                    long kv = lround(kd[i] / nk * 32768.0);
                    long qv = lround(qd[i] / nq / sqrt((double)DIM) * 262144.0);
                    if (kv >  32767) { kv =  32767; }
                    if (kv < -32768) { kv = -32768; }
                    if (qv >  32767) { qv =  32767; }
                    if (qv < -32768) { qv = -32768; }
                    g_kn[i] = (int16_t)kv; g_qs[i] = (int16_t)qv;
                }
            }
            tk0 = g_tk0; eg = g_eg; beta = g_beta;
            memcpy(kn, g_kn, sizeof kn); memcpy(qs, g_qs, sizeof qs);
            int top = rnd_range(16384, 32767);
            for (int i = 0; i < DIM; i++) smant[i] = (int16_t)rnd_range(-top, top);
            smant[rnd_range(0, DIM-1)] = (int16_t)top;
            v_j = rnd_range(-32768, 32767);
        } else if (phys) {
            se_j = rnd_range(-40, 40);
            /* v shares the activation scale, so its exponent tracks the
             * state's within a realistic spread rather than roaming freely */
            e_v  = se_j + rnd_range(-8, 8);
            /* eg comes from the measured per-head table, tail included --
             * see load_eg_table above for why the old [0.85, 1.0] draw was
             * wrong about its own source. */
            if (c % GRP == 0) {
                g_tk0  = ((c / GRP) % 4 == 0);
                g_eg   = pick_eg((c / GRP) % 6);
                /* one group per sweep deliberately lands in the small-beta
                 * range where the tk=0 d_m defect bites */
                g_beta = ((c / GRP) % 5 == 0) ? rnd_range(1, 256)
                                              : rnd_range(1, 65535);
            }
            tk0 = g_tk0; eg = g_eg; beta = g_beta;

            /* a real unit-norm k at exp 15: draw, then scale so sum k^2 = 2^30 */
            double kd[DIM], qd[DIM], nk = 0.0, nq = 0.0;
            for (int i = 0; i < DIM; i++) {
                kd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                qd[i] = (double)rnd_range(-10000, 10000) / 10000.0;
                nk += kd[i]*kd[i]; nq += qd[i]*qd[i];
            }
            nk = sqrt(nk); nq = sqrt(nq);
            for (int i = 0; i < DIM; i++) {
                /* k_n = x/||x|| at exp 15, q_s = x/(||x||*sqrt(128)) at exp 18,
                 * i.e. exactly the two outputs l2norm_rs produces */
                long kv = lround(kd[i] / nk * 32768.0);
                long qv = lround(qd[i] / nq / sqrt((double)DIM) * 262144.0);
                if (kv >  32767) { kv =  32767; }
                if (kv < -32768) { kv = -32768; }
                if (qv >  32767) { qv =  32767; }
                if (qv < -32768) { qv = -32768; }
                kn[i] = (int16_t)kv; qs[i] = (int16_t)qv;
            }
            if (c % GRP == 0) { memcpy(g_kn, kn, sizeof kn); memcpy(g_qs, qs, sizeof qs); }
            memcpy(kn, g_kn, sizeof kn); memcpy(qs, g_qs, sizeof qs);
            /* a state whose mantissas fill the int16 grid the way a BFP column
             * does: one element at or near full scale, the rest spread below */
            int top = rnd_range(16384, 32767);
            for (int i = 0; i < DIM; i++) smant[i] = (int16_t)rnd_range(-top, top);
            smant[rnd_range(0, DIM-1)] = (int16_t)top;
            /* v[j] is INT16 -- spec 2.1.3's table, line 431.  Drawing it from an
             * s18 range instead made diff exceed the s18 the spec assigns it,
             * which looked like a spec width bug until the contract was
             * checked.  It is a generator bug; the spec's widths are right. */
            v_j = rnd_range(-32768, 32767);
        } else {
            int a = c - 96;
            int smag = 1 + (a % 5);
            se_j  = rnd_range(-40, 40);
            e_v   = rnd_range(-40, 40);
            if (a % GRP == 0) {
                g_tk0  = ((a / GRP) % 3 == 0);
                g_eg   = ((a / GRP) % 4 == 0) ? 32768
                       : ((a / GRP) % 4 == 1) ? 1 : rnd_range(28000, 32768);
                g_beta = ((a / GRP) % 4 == 0) ? 65535 : rnd_range(1, 65535);
            }
            tk0 = g_tk0; eg = g_eg; beta = g_beta;
            for (int i = 0; i < DIM; i++) {
                int lim = (1 << (3 * smag)) - 1; if (lim > 32767) lim = 32767;
                smant[i] = (int16_t)rnd_range(-lim, lim);
                kn[i]    = (int16_t)rnd_range(-32768, 32767);
                qs[i]    = (int16_t)rnd_range(-23170, 23170);
            }
            if (a % 13 == 0) { smant[0] = -32768; smant[1] = 32767; }
            if (a % GRP == 0) {
                if ((a / GRP) % 3 == 1) { for (int i = 0; i < DIM; i++) kn[i] = 0; }
                memcpy(g_kn, kn, sizeof kn); memcpy(g_qs, qs, sizeof qs);
            }
            memcpy(kn, g_kn, sizeof kn); memcpy(qs, g_qs, sizeof qs);
            v_j = rnd_range(-32768, 32767);
            if (a % 19 == 0) v_j = 0;
        }

        /* ---------------- FIXED: spec 2.1.4, one column ------------------ */
        int64_t w18[DIM], sk_acc = 0;
        for (int i = 0; i < DIM; i++) {
            int64_t sm = tk0 ? 0 : smant[i];
            int64_t w  = sm * (int64_t)eg;
            w18[i]     = round_shift(w, 13);
            assert(llabs(w18[i]) <= (1LL << 17));
            sk_acc    += w18[i] * (int64_t)kn[i];
        }
        int sh_sk = msb_pos_u((uint64_t)llabs(sk_acc)) - 14;
        if (sh_sk < 0) sh_sk = 0;
        int64_t skm = round_shift(sk_acc, sh_sk);
        int ske = se_j + 17 - sh_sk;
        assert(llabs(skm) <= 32768);

        /* TK0_ED: at tk = 0 the sk term is a masked ZERO, so ske is derived
         * from a state that does not exist (msb_pos(0) = 0 gives
         * ske = se_j + 17) and must not enter the grid minimum -- the identical
         * structural move stage 4 already makes for e_u.  Left in, it floors v
         * on a phantom grid BEFORE beta multiplies it, and d_norm cannot
         * recover that because normalizing zero is zero. */
        int e_d;
        /* The state term is a MASKED ZERO whenever tk = 0 (first token) OR
           eg = 0 (decay gate fully shut mid-sequence).  Both make ske an
           exponent describing nothing.  The eg = 0 arm was added 2026-08-26
           after the oracle's output-dot check caught it. */
        int masked = tk0 || (eg == 0);
        if (masked && tk0_ed) e_d = e_v;
        else                  e_d = (e_v < ske) ? e_v : ske;
        /* Shift counts clamped to 63, exactly as spec 2.1.4 states and as
         * gdn_err.c:383-384 does.  Dropping the clamp when this column was
         * extracted made floor_shr compute 1LL << 64 on wide exponent
         * spreads, which is undefined behaviour in C, and produced a
         * disagreement with the RTL that looked like an RTL bug. */
        int s1 = e_v - e_d, s2 = ske - e_d;
        if (s1 > 63) s1 = 63;
        if (s2 > 63) s2 = 63;
        int64_t diff = floor_shr(v_j, s1) - floor_shr(skm, s2);
        int64_t draw = diff * (int64_t)beta;
        int shd = 16;
        if (d_norm) { shd = msb_pos_u((uint64_t)llabs(draw)) - 14; if (shd < 0) shd = 0; }
        int64_t d_m  = round_shift(draw, shd);
        int e_dm = e_d + 16 - shd;

        int e_kd = 15 + e_dm;
        int e_u  = masked ? e_kd : ((se_j + 2 < e_kd) ? se_j + 2 : e_kd);
        int su = se_j + 2 - e_u, sk2 = e_kd - e_u;
        if (su  > 63) su  = 63;
        if (sk2 > 63) sk2 = 63;
        int64_t u[DIM]; uint64_t amax = 0;
        for (int i = 0; i < DIM; i++) {
            int64_t kd = (int64_t)kn[i] * d_m;
            u[i] = (tk0 ? 0 : floor_shr(w18[i], su)) + floor_shr(kd, sk2);
            uint64_t a = (uint64_t)llabs(u[i]); if (a > amax) amax = a;
        }
        int sh = msb_pos_u(amax) - 14; if (sh < 0) sh = 0;
        int16_t snew[DIM];
        for (int i = 0; i < DIM; i++) snew[i] = mv4i_sat16(round_shift(u[i], sh));
        int se_new = e_u - sh;
        int64_t o_acc = 0;
        for (int i = 0; i < DIM; i++) o_acc += (int64_t)snew[i] * (int64_t)qs[i];
        int e_o = se_new + 18;
        /* 2.1.6: the column exponent is int8 and out of range is an ERROR to
         * be reported, never silently wrapped.  e_o = se_new + 18 is a
         * SEPARATE int8 output, so se_new in [110,127] is in range while e_o
         * is not -- reachable with the wide tk = 0 exponent spreads, and
         * measured: se_new = 117 gives e_o = 135, which wraps to 7. */
        int err = (se_new > 127 || se_new < -128 || e_o > 127 || e_o < -128);

        /* ---------------- ORACLE: the same column in double --------------
         * Independent of every fixed-point choice above: no grids, no shifts,
         * no exponents.  Inputs are dequantized once and never requantized. */
        double sr[DIM], kr[DIM], qr[DIM], wr[DIM], ur[DIM];
        double egr = ldexp((double)eg, -15);
        double ber = ldexp((double)beta, -16);
        double vr  = ldexp((double)v_j, -e_v);
        double skr = 0.0;
        for (int i = 0; i < DIM; i++) {
            sr[i] = tk0 ? 0.0 : ldexp((double)smant[i], -se_j);
            kr[i] = ldexp((double)kn[i], -15);
            qr[i] = ldexp((double)qs[i], -18);
            wr[i] = sr[i] * egr;
            skr  += wr[i] * kr[i];
        }
        double dr = (vr - skr) * ber;
        double orr = 0.0, onorm = 0.0;
        for (int i = 0; i < DIM; i++) {
            ur[i] = wr[i] + kr[i] * dr;
            orr   += ur[i] * qr[i];
            onorm += fabs(ur[i] * qr[i]);
        }

        /* ------------------------------- emit ----------------------------
         * Keyword-free and fixed-order, because VHDL textio parses numbers
         * cheaply and strings expensively.  Reals use %.17e so every value is
         * a legal VHDL real literal (a bare "0" from %g is not).  o_acc is
         * emitted as a real deliberately: it is s38, and every s38 integer is
         * represented EXACTLY by a double, so the bit-exact check survives the
         * round trip while VHDL's 32-bit integer would not hold it. */
        if (longhead)     gid = 1000;
        else if (widetk0) gid = 2000 + (c - (NPHYS+NADV+NLONG)) / 8;
        else              gid = c / GRP;
        fprintf(f, "%d %d %d %d %d %d %d %d\n",
                phys, tk0, se_j, e_v, eg, beta, v_j, gid);
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", smant[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", kn[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", qs[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", snew[i]); } fprintf(f,"\n");
        fprintf(f, "%d %.1f %d %d\n", se_new, (double)o_acc, e_o, err);
        for (int i=0;i<DIM;i++) { fprintf(f, "%.17e ", ur[i]); } fprintf(f,"\n");
        /* The output dot is a 128-term signed sum and cancels heavily, so a
         * RELATIVE error against |sum| is not a measurement -- it explodes
         * wherever the sum is near zero while every term is fine.  Emit the
         * sum of |terms| as well, and let the testbench normalise by that. */
        fprintf(f, "%.17e %.17e\n", orr, onorm);
        ncase++;
    }
    fclose(f);
    fprintf(stderr, "gdn_recur_vec: %d cases -> %s (d_norm=%d tk0_ed=%d)\n", ncase, out, d_norm, tk0_ed);
    return 0;
}
