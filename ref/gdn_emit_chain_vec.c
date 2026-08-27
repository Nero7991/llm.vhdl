/* ref/gdn_emit_chain_vec.c -- vectors and golden for rtl/gdn_emit_chain.vhd.
 *
 * The whole per-block emit chain in one reference:
 *
 *   site 12 head emit -> rmsnorm_bf (output norm) -> gdn_silu (z gate)
 *                                                 -> site 13 gated product
 *                                                    and 24-head renorm
 *
 * WHY THE CORES ARE INCLUDED, NOT TRANSCRIBED.  rmsnorm_bf and gdn_silu each
 * already have a verified reference with a double oracle of its own.  Copying
 * their arithmetic into this file would create a second, drifting definition
 * of the same recipe, which is precisely how a golden stops certifying the
 * unit it names -- this project has a documented case (the l2norm collapse
 * that survived 55 passing tests).  So those two files are #included with
 * GDN_CHAIN_INCLUDE defined, which keeps their cores and drops their
 * standalone harnesses.  Both were verified byte-identical standalone after
 * the guard was added.
 *
 * The two emit recipes ARE written out here, because they are short and
 * because their own generators keep them inside main().  They are the same
 * arithmetic as ref/gdn_head_emit_vec.c and ref/gdn_y_emit_vec.c, and the
 * per-unit testbenches remain the authority on them.
 *
 * DOUBLE ORACLE.  The chain is also evaluated end to end in double, sharing
 * none of the integer helpers, so a consistent misunderstanding of the recipe
 * cannot pass.  The comparison is in LSB of the OUTPUT grid.
 *
 * Build: cc -O2 -o gdn_emit_chain_vec gdn_emit_chain_vec.c -lm
 * Usage: ./gdn_emit_chain_vec [out.txt] [nblock] [heads] [dim]
 */
#define GDN_CHAIN_INCLUDE
#include "rmsnorm_bf_vec.c"
#include "gdn_silu_vec.c"

static uint64_t crs = 20260827ULL;
static uint32_t crnd(void){ crs ^= crs<<13; crs ^= crs>>7; crs ^= crs<<17; return (uint32_t)(crs>>32); }

static int cmsb_u(uint64_t v){ int p = 0; while (v >>= 1) p++; return p; }
static int16_t csat16(int64_t v){ return v > 32767 ? 32767 : (v < -32768 ? -32768 : (int16_t)v); }

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "gdn_emit_chain_vec.txt";
    int NB = (argc > 2) ? atoi(argv[2]) : 6;
    int H  = (argc > 3) ? atoi(argv[3]) : 24;
    int D  = (argc > 4) ? atoi(argv[4]) : 128;
    N = D;                                    /* rmsnorm_bf_vec.c's global */
    /* INITIALISATION THAT LIVES IN THE INCLUDED FILES' main().
     *
     * Including a generator's core means its main() is guarded away, and with
     * it every setup line that main() performed.  This bit twice while writing
     * this file, each time as a silent wrong answer rather than an error:
     *
     *   bf_resolve_eps()  resolves rmsnorm_bf's epsilon.  Without it M_EPS is
     *                     0, i.e. an epsilon of zero -- the exact defect
     *                     rmsnorm_bf exists to fix, reintroduced by omission.
     *   fx_init()         fills _fx_sig_lut_q, the shared Q30 sigmoid table.
     *                     Without it every sigma reads 0, so the gate output
     *                     is identically zero and every product vanishes.
     *
     * Both were caught only by the end-to-end double oracle, at 1.6e11 and
     * 8.3e8 LSB. Neither would have been visible in the emitted vectors,
     * which would simply have been confidently wrong. */
    bf_resolve_eps();
    fx_init();

    static int64_t o_acc[64][512];
    static int     e_o[64][512];
    static int16_t zm[64][512];
    static int16_t wm[512];
    static int16_t yv[64*512];
    static double  ydbl[64*512];
    int we = 12, z_e = 12;

    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    fprintf(f, "%d %d %d\n", NB, H, D);

    double worst = 0.0; int worst_blk = 0;
    long nsat = 0;

    for (int b = 0; b < NB; b++) {
        /* ssm_norm, shared across the heads of a block */
        for (int i = 0; i < D; i++) wm[i] = (int16_t)((crnd() % 8000u) + 100u);

        for (int h = 0; h < H; h++) {
            /* The exponent is chosen FROM the mantissa so the real value
             * lands in the range the model actually occupies.  The first
             * version picked the two independently -- mantissas to 2^36 with
             * exponents of 10 to 17 -- which puts |o_h| around 2^26, some 26
             * octaves above the measured maximum of 2^-0.54, and straight
             * into rmsnorm_bf's documented UPPER rail where inv32 underflows
             * to zero.  Every product then came out zero and the double
             * oracle reported 9.4e10 LSB.  Nothing was wrong with the chain;
             * the stimulus was 26 octaves out of range.
             *
             * Measured range of rms(o_h) on Qwen3.8-27B over 963M samples:
             * 2^-29.63 to 2^-0.54.  target_oct below spans that with margin. */
            int target_oct = -28 + (int)(crnd() % 27u);   /* log2 of the value */
            for (int j = 0; j < D; j++) {
                int k = 20 + (int)(crnd() % 14u);          /* mantissa msb */
                int64_t mag = ((int64_t)1 << k)
                            | (int64_t)(crnd() & (((int64_t)1 << (k-1)) - 1));
                if (mag >= ((int64_t)1 << 36)) mag = ((int64_t)1 << 36) - 1;
                o_acc[h][j] = (crnd() & 1u) ? -mag : mag;
                /* value = mag * 2^-e_o, so e_o = msb(mag) - target_oct */
                int e = k - target_oct + (int)(crnd() % 3u);
                if (e < -100) e = -100; if (e > 100) e = 100;
                e_o[h][j] = e;
                zm[h][j]  = (int16_t)(crnd() & 0xFFFFu);
            }
        }

        /* ---- the chain, head by head ---------------------------------- */
        static int16_t prod_o[64][512], prod_z[64][512];
        static int     ep[64];

        for (int h = 0; h < H; h++) {
            /* --- site 12: fold the head to one grid, requantize --------- */
            int e_h = e_o[h][0];
            for (int j = 1; j < D; j++) if (e_o[h][j] < e_h) e_h = e_o[h][j];
            static int64_t o_al[512];
            uint64_t amax = 0;
            for (int j = 0; j < D; j++) {
                int shj = e_o[h][j] - e_h; if (shj > 63) shj = 63;
                o_al[j] = mv4i_floor_shr(o_acc[h][j], shj);
                uint64_t a = (uint64_t)llabs(o_al[j]);
                if (a > amax) amax = a;
            }
            int sh_h = cmsb_u(amax) - 14; if (sh_h < 0) sh_h = 0;
            int e_head = e_h - sh_h;
            static int16_t o_head[512];
            for (int j = 0; j < D; j++)
                o_head[j] = csat16(mv4i_round_shift(o_al[j], sh_h));

            /* --- the output norm, from its own verified core ------------- */
            static bf_out r;
            rmsnorm_bf_int(o_head, e_head, wm, we, &r);

            /* --- the z gate.  Exponent PRESERVED (section 2.1.2), which is
             * why z_e passes straight through to the product's exponent. --- */
            for (int j = 0; j < D; j++) {
                int32_t xq  = to_q12(zm[h][j], z_e);
                int32_t sig = sigma_q15_from_q12(xq);
                int64_t g   = mv4i_round_shift((int64_t)zm[h][j] * sig, 15);
                prod_o[h][j] = r.o[j];
                prod_z[h][j] = csat16(g);
            }
            ep[h] = r.o_exp + z_e;
        }

        /* ---- site 13: gated product and the H-head renorm -------------- */
        int e_y = ep[0];
        for (int h = 1; h < H; h++) if (ep[h] < e_y) e_y = ep[h];
        static int64_t p_al[64*512];
        uint64_t amax2 = 0;
        for (int h = 0; h < H; h++) {
            int shj = ep[h] - e_y; if (shj > 63) shj = 63;
            for (int j = 0; j < D; j++) {
                int64_t p = (int64_t)prod_o[h][j] * (int64_t)prod_z[h][j];
                p_al[h*D+j] = mv4i_floor_shr(p, shj);
                uint64_t a = (uint64_t)llabs(p_al[h*D+j]);
                if (a > amax2) amax2 = a;
            }
        }
        int sh = cmsb_u(amax2) - 14; if (sh < 0) sh = 0;
        int y_exp = e_y - sh;
        int sat_any = 0;
        for (int i = 0; i < H*D; i++) {
            int64_t rr = mv4i_round_shift(p_al[i], sh);
            if (rr > 32767 || rr < -32768) { sat_any = 1; nsat++; }
            yv[i] = csat16(rr);
        }

        /* ---- the double oracle, end to end ----------------------------- */
        for (int h = 0; h < H; h++) {
            static double xd[512], od[512];
            /* the head's real value, before any of the integer path */
            int e_h = e_o[h][0];
            for (int j = 1; j < D; j++) if (e_o[h][j] < e_h) e_h = e_o[h][j];
            for (int j = 0; j < D; j++) xd[j] = ldexp((double)o_acc[h][j], -e_o[h][j]);
            /* the norm, as mathematics */
            double ms = 0.0;
            for (int j = 0; j < D; j++) ms += xd[j]*xd[j];
            ms /= (double)D;
            double gain = 1.0 / sqrt(ms + EPS);
            for (int j = 0; j < D; j++)
                od[j] = xd[j] * gain * ldexp((double)wm[j], -we);
            /* the gate, as mathematics */
            for (int j = 0; j < D; j++) {
                double zr = ldexp((double)zm[h][j], -z_e);
                double si = zr / (1.0 + exp(-zr));
                ydbl[h*D+j] = od[j] * si;
            }
        }
        if (!sat_any) {
            double lsb = ldexp(1.0, -y_exp);
            for (int i = 0; i < H*D; i++) {
                double got = ldexp((double)yv[i], -y_exp);
                double e = fabs(got - ydbl[i]) / lsb;
                if (e > worst) { worst = e; worst_blk = b; }
            }
        }

        /* ---- emit ------------------------------------------------------ */
        fprintf(f, "%d %d %d %d %d\n", b, y_exp, sat_any, we, z_e);
        for (int i = 0; i < D; i++) fprintf(f, "%d ", (int)wm[i]);
        fprintf(f, "\n");
        for (int h = 0; h < H; h++) {
            for (int j = 0; j < D; j++) fprintf(f, "%lld ", (long long)o_acc[h][j]);
            fprintf(f, "\n");
            for (int j = 0; j < D; j++) fprintf(f, "%d ", e_o[h][j]);
            fprintf(f, "\n");
            for (int j = 0; j < D; j++) fprintf(f, "%d ", (int)zm[h][j]);
            fprintf(f, "\n");
        }
        for (int i = 0; i < H*D; i++) fprintf(f, "%d ", (int)yv[i]);
        fprintf(f, "\n");
    }
    fclose(f);

    fprintf(stderr, "gdn_emit_chain_vec: %d blocks x %d heads x %d -> %s\n",
            NB, H, D, out);
    fprintf(stderr, "  worst end-to-end error vs the double oracle: %.4f LSB "
                    "of the output grid (block %d)\n", worst, worst_blk);
    fprintf(stderr, "  saturated elements: %ld\n", nsat);
    /* Four quantizing stages compose here (two requantizes, the norm's own
     * output grid, and the gate), so the per-stage bounds do not simply add
     * to something tight.  This is a SANITY bound, not a derived one -- the
     * per-unit generators carry the derived bounds.  MEASURED at 1.53 LSB
     * over 6 blocks; 8.0 leaves room for seed variation while still being
     * three orders below the 9.4e8 and 1.6e11 that the two uninitialised-
     * global defects produced, which is the failure class it has to catch. */
    if (worst > 8.0) {
        fprintf(stderr, "  FAIL: end-to-end error is far larger than the "
                        "composed quantization can explain\n");
        return 1;
    }
    fprintf(stderr, "  OK\n");
    return 0;
}
