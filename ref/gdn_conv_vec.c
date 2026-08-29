/* gdn_conv_vec: test vectors for rtl/gdn_conv.vhd, B section 2.1.3's conv.
 *
 * Emits, per case: the inputs, the FIXED expected outputs, and the same
 * segment computed by a DOUBLE-PRECISION ORACLE.  Both, for the same reason as
 * gdn_recur_vec.c: bit-exactness against a second transcription of the recipe
 * catches transcription errors and CANNOT catch an error in the recipe, which
 * is how the l2norm collapse survived 55 passing cases.
 *
 * The conv is depthwise, kernel 4, no bias, no fused activation (spec 1.4(e)).
 * The tap exponents e_t are per SLOT, so all channels of a segment share them
 * and e_ref is a per-segment scalar -- which is why the segment requantizer
 * can carry one e_seg.
 *
 * INVALID TAPS (token index < 0, spec 1.6) are excluded from BOTH the products
 * AND the e_ref minimum.  That second half is the rule the tk = 0 defects in
 * 2.1.4 came from violating, so it is exercised deliberately here: cases sweep
 * the valid mask, including the sequence-start masks 0001, 0011, 0111.
 *
 * Build: cc -O2 -Wall -Wextra -o ref/gdn_conv_vec ref/gdn_conv_vec.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include "mv4i_arith.h"
#include "vec_seed.h"   /* the seed convention; see that header */

#define floor_shr(v, sh)   mv4i_floor_shr((v), (sh))
#define round_shift(v, sh) mv4i_round_shift((v), (sh))
#define msb_pos_u(a)       mv4i_msb_pos_u((a))

#define K   4         /* ssm.conv_kernel */
#define CH  256       /* channels per case; the real segments are 1024/1024/3072 */
#define NCASE 128

static uint64_t rs_;
static uint64_t rnd64(void){ uint64_t z=(rs_+=0x9E3779B97F4A7C15ULL);
  z=(z^(z>>30))*0xBF58476D1CE4E5B9ULL; z=(z^(z>>27))*0x94D049BB133111EBULL;
  return z^(z>>31); }
static int32_t rnd_range(int32_t lo, int32_t hi){
  return lo + (int32_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "sim/gdn_conv_vec.txt";
    FILE *f = fopen(out, "w");
    if (!f) { perror("fopen"); return 1; }
    rs_ = vec_seed(argc, argv, 2, 20260826ULL);
    fprintf(f, "%d %d %d\n", NCASE, CH, K);

    for (int c = 0; c < NCASE; c++) {
        /* valid masks: sweep the sequence-start prefixes explicitly, then
         * random.  Bit t set means tap t is valid. */
        static const int starts[4] = {0x1, 0x3, 0x7, 0xF};
        int vmask;
        if (c < 16)      vmask = starts[c % 4];
        else if (c < 24) vmask = 0xF;
        else             vmask = rnd_range(1, 15);

        /* cw_exp is normally modest, but one class in seven is drawn wide
           enough that e_seg = e_ref + cw_exp - sh_seg can leave int8 and set
           err.  Without it the err path is structurally UNREACHABLE: with
           |e_ref| <= 60 and |cw_exp| <= 30, e_seg is confined to [-108, 90]
           and err was 0 in all 128 cases, so an err_seg tied high passed the
           whole suite. */
        int e_t[K], cw_exp = (c % 7 == 0) ? rnd_range(-110, 110)
                                          : rnd_range(-30, 30);
        for (int t = 0; t < K; t++) e_t[t] = rnd_range(-40, 40);
        /* one case class with a wide tap-exponent spread, so the alignment
         * shifts actually bite rather than all being zero */
        if (c % 5 == 0) for (int t = 0; t < K; t++) e_t[t] = rnd_range(-60, 60);

        int16_t x[CH][K], w[CH][K];
        for (int i = 0; i < CH; i++)
            for (int t = 0; t < K; t++) {
                x[i][t] = (int16_t)rnd_range(-32768, 32767);
                w[i][t] = (int16_t)rnd_range(-32768, 32767);
            }
        if (c % 11 == 0) for (int i = 0; i < CH; i++) for (int t = 0; t < K; t++) x[i][t] = 0;

        /* ---- FIXED: spec 2.1.3 ---- */
        int e_ref = 0, have = 0;
        for (int t = 0; t < K; t++)
            if (vmask & (1 << t)) { if (!have || e_t[t] < e_ref) { e_ref = e_t[t]; have = 1; } }
        assert(have);                      /* at least one tap is always valid */
        int64_t acc[CH]; uint64_t amax = 0;
        for (int i = 0; i < CH; i++) {
            int64_t a = 0;
            for (int t = 0; t < K; t++) {
                if (!(vmask & (1 << t))) continue;
                int sh = e_t[t] - e_ref; if (sh > 63) sh = 63;
                a += floor_shr((int64_t)x[i][t] * (int64_t)w[i][t], sh);
            }
            assert(llabs(a) < (1LL << 33));
            acc[i] = a;
            uint64_t m = (uint64_t)llabs(a); if (m > amax) amax = m;
        }
        int e_acc = e_ref + cw_exp;
        int sh_seg = msb_pos_u(amax) - 14; if (sh_seg < 0) sh_seg = 0;
        int16_t sm[CH];
        for (int i = 0; i < CH; i++) sm[i] = mv4i_sat16(round_shift(acc[i], sh_seg));
        int e_seg = e_acc - sh_seg;
        int err = (e_seg > 127 || e_seg < -128);

        /* ---- ORACLE: the same segment in double ---- */
        double orc[CH];
        for (int i = 0; i < CH; i++) {
            double a = 0.0;
            for (int t = 0; t < K; t++) {
                if (!(vmask & (1 << t))) continue;
                a += ldexp((double)x[i][t], -e_t[t]) * (double)w[i][t];
            }
            orc[i] = a;                    /* still carries the 2^-cw_exp of w */
        }

        fprintf(f, "%d %d %d %d %d %d %d %d %d\n",
                vmask, cw_exp, e_t[0], e_t[1], e_t[2], e_t[3], e_seg, sh_seg, err);
        for (int i = 0; i < CH; i++) { for (int t = 0; t < K; t++) fprintf(f, "%d ", x[i][t]); } fprintf(f,"\n");
        for (int i = 0; i < CH; i++) { for (int t = 0; t < K; t++) fprintf(f, "%d ", w[i][t]); } fprintf(f,"\n");
        for (int i = 0; i < CH; i++) { fprintf(f, "%d ", sm[i]); } fprintf(f,"\n");
        for (int i = 0; i < CH; i++) { fprintf(f, "%.17e ", orc[i]); } fprintf(f,"\n");
    }
    fclose(f);
    fprintf(stderr, "gdn_conv_vec: %d cases, CH=%d K=%d -> %s\n", NCASE, CH, K, out);
    return 0;
}
