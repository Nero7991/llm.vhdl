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

static uint64_t rs_;
static uint64_t rnd64(void){ uint64_t z=(rs_+=0x9E3779B97F4A7C15ULL);
  z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL; z=(z^(z>>27))*0x94D049BB133111EBULL;
  return z^(z>>31); }
static int32_t rnd_range(int32_t lo, int32_t hi){
  return lo + (int32_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "sim/gdn_recur_vec.txt";
    FILE *f = fopen(out, "w");
    if (!f) { perror("fopen"); return 1; }
    rs_ = 20260825ULL;

    int ncase = 0;
    /* header: number of cases, then DIM */
    fprintf(f, "192 %d\n", DIM);

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
    for (int c = 0; c < 192; c++) {
        int phys = (c < 96);
        int tk0, se_j, e_v, eg, beta;
        int16_t smant[DIM], kn[DIM], qs[DIM];
        int32_t v_j;

        if (phys) {
            tk0  = (c % 16 == 0);
            se_j = rnd_range(-40, 40);
            /* v shares the activation scale, so its exponent tracks the
             * state's within a realistic spread rather than roaming freely */
            e_v  = se_j + rnd_range(-8, 8);
            /* exp(g) for this model sits just under 1; the measured per-head
             * table (ref/gdn_eg_qwen3_27b.txt) ranges over roughly
             * 0.85..0.99997, so eg_q15 lives near the top of u16 */
            eg   = (c % 9 == 0) ? 32768 : rnd_range(27853, 32767);
            beta = rnd_range(1, 65535);

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
            tk0   = (a % 8 == 0);
            int smag = 1 + (a % 5);
            se_j  = rnd_range(-40, 40);
            e_v   = rnd_range(-40, 40);
            eg    = (a % 7 == 0) ? 32768 : (a % 7 == 1) ? 1 : rnd_range(28000, 32768);
            beta  = (a % 11 == 0) ? 65535 : rnd_range(1, 65535);
            for (int i = 0; i < DIM; i++) {
                int lim = (1 << (3 * smag)) - 1; if (lim > 32767) lim = 32767;
                smant[i] = (int16_t)rnd_range(-lim, lim);
                kn[i]    = (int16_t)rnd_range(-32768, 32767);
                qs[i]    = (int16_t)rnd_range(-23170, 23170);
            }
            if (a % 13 == 0) { smant[0] = -32768; smant[1] = 32767; }
            if (a % 17 == 0) { for (int i = 0; i < DIM; i++) kn[i] = 0; }
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

        int e_d = (e_v < ske) ? e_v : ske;
        /* Shift counts clamped to 63, exactly as spec 2.1.4 states and as
         * gdn_err.c:383-384 does.  Dropping the clamp when this column was
         * extracted made floor_shr compute 1LL << 64 on wide exponent
         * spreads, which is undefined behaviour in C, and produced a
         * disagreement with the RTL that looked like an RTL bug. */
        int s1 = e_v - e_d, s2 = ske - e_d;
        if (s1 > 63) s1 = 63;
        if (s2 > 63) s2 = 63;
        int64_t diff = floor_shr(v_j, s1) - floor_shr(skm, s2);
        int64_t d_m  = round_shift(diff * (int64_t)beta, 16);

        int e_kd = 15 + e_d;
        int e_u  = tk0 ? e_kd : ((se_j + 2 < e_kd) ? se_j + 2 : e_kd);
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
        fprintf(f, "%d %d %d %d %d %d %d\n", phys, tk0, se_j, e_v, eg, beta, v_j);
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", smant[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", kn[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", qs[i]); } fprintf(f,"\n");
        for (int i=0;i<DIM;i++) { fprintf(f, "%d ", snew[i]); } fprintf(f,"\n");
        fprintf(f, "%d %.1f %d\n", se_new, (double)o_acc, e_o);
        for (int i=0;i<DIM;i++) { fprintf(f, "%.17e ", ur[i]); } fprintf(f,"\n");
        /* The output dot is a 128-term signed sum and cancels heavily, so a
         * RELATIVE error against |sum| is not a measurement -- it explodes
         * wherever the sum is near zero while every term is fine.  Emit the
         * sum of |terms| as well, and let the testbench normalise by that. */
        fprintf(f, "%.17e %.17e\n", orr, onorm);
        ncase++;
    }
    fclose(f);
    fprintf(stderr, "gdn_recur_vec: %d cases -> %s\n", ncase, out);
    return 0;
}
