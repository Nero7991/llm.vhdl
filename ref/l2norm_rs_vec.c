/* ref/l2norm_rs_vec.c -- stimulus + fixed-point golden for rtl/l2norm_rs.vhd
 * (subsystem B 2.1.3, the per-head L2 norm, both output paths).
 *
 * WHAT THIS FILE IS, AND WHAT IT IS NOT
 * ------------------------------------
 * It is a SECOND TRANSCRIPTION of 2.1.3's recipe, in C, from the recipe as
 * written in rtl/l2norm_rs.vhd's header and from the same RSQRT_ROM the
 * hardware reads.  It exists because until 2026-08-28 l2norm_rs was the only
 * unit in subsystem B with NO reference model in ref/ at all: its bench held
 * it to a 0.75-LSB tolerance against math_real and nothing else.  Every other
 * B unit is checked bit-exactly against a C oracle, and a tolerance against a
 * real-valued expression is a weaker standard -- it cannot see a wrong shift
 * that happens to land inside the bound, a pipeline index off by one that only
 * moves small elements, or a saturation that fires one LSB early.
 *
 * IT IS NOT AN ADEQUACY CHECK, AND MUST NEVER BE TREATED AS ONE.  This is the
 * exact construction that certified the collapsed recipe in
 * docs/debugging/2026-08-25_l2norm-recipe-collapse.md: golden and DUT shared
 * the recipe, both rounded the same collapsed scalar to the same 0, and agreed
 * on 55 cases while the whole q path emitted zeros.  Bit-exactness against a
 * twice-transcribed recipe proves TRANSCRIPTION, not adequacy.
 *
 * So sim/tb_l2norm_rs.vhd runs BOTH checks on every case and neither replaces
 * the other:
 *   1. bit-exact against the k/q columns emitted here    (transcription)
 *   2. the pre-existing real-valued x/||x|| bound in LSB (adequacy)
 * Do not delete check 2 because check 1 exists.  That is the trap.
 *
 * THE RECIPE, transcribed (rtl/l2norm_rs.vhd:36-57):
 *   ssq  = sum xm[i]^2                                      s64, |xm| <= 32768
 *   k path: rsqrt argument is ssq itself,  output exponent 15
 *   q path: rsqrt argument is ssq << log2(N), output exponent 18
 *           (the 1/sqrt(N) fold is a SHIFT OF THE ARGUMENT, not of the output)
 *   m    = msb(arg);  he = m/2 (floor);  y = Q30 Newton rsqrt of arg
 *          normalised to [1,2), times 1/sqrt(2) when m is odd
 *   out[i] = sat16( (xm[i]*y + bias) >> sh ),  sh = 30 - OUT + he,
 *          bias = 1 << (sh-1)      -- round half up, ARITHMETIC shift
 *   ssq = 0 emits zeros on BOTH paths: 2.1.3's deliberate divergence from
 *   ggml_l2_norm, which would emit amplified dust.
 *
 * The Newton engine is transcribed cadence-free: the RTL spreads two Newton
 * iterations over 24 states to buy DSP registers, but the VALUE sequence is
 * y2 = (y*y)>>30 ; d = 3*2^30 - ((smant*y2)>>30) ; y = (d*y)>>31, twice.  The
 * cadence is a timing property and is checked by the testbench observing the
 * unit's own `done`, not by this model.
 *
 * usage: l2norm_rs_vec <out.txt> [N] [seed]
 * emits: line 1     NCASE N
 *        per case   N x values / N k values / N q values, one line each
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Bit-identical to rtl/fixed_luts_pkg.vhd's RSQRT_ROM, which is itself
 * generated from mem/luts/.  Copied rather than re-derived on purpose: the ROM
 * contents are hardware, not recipe, and re-deriving them here would make a
 * ROM typo invisible in exactly the direction that matters. */
static const int64_t RSQRT_ROM[64] = {
    1073741824, 1065450257, 1057347856, 1049427536, 1041682578, 1034106604, 1026693558, 1019437682,
    1012333500, 1005375799,  998559613,  991880210,  985333074,  978913898,  972618566,  966443148,
     960383883,  954437177,  948599586,  942867814,  937238702,  931709222,  926276469,  920937655,
     915690104,  910531246,  905458609,  900469818,  895562589,  890734723,  885984104,  881308694,
     876706528,  872175715,  867714429,  863320910,  858993459,  854730438,  850530263,  846391405,
     842312387,  838291779,  834328203,  830420321,  826566842,  822766514,  819018128,  815320510,
     811672525,  808073073,  804521086,  801015531,  797555404,  794139734,  790767575,  787438013,
     784150157,  780903145,  777696137,  774528319,  771398898,  768307107,  765252196,  762233438
};
/* to_signed(759250125, 32) in rtl/l2norm_rs.vhd:114 == round(2^30/sqrt(2)) */
#define INV_SQRT2_C  759250125LL
#define THREE_Q30    (3LL << 30)

static int msb_pos(int64_t v)          /* highest set bit of bits 62..0 */
{
    int p = 0;
    for (int i = 0; i <= 62; i++) if ((v >> i) & 1) p = i;
    return p;
}

static int64_t sat16(int64_t v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return v;
}

/* one rsqrt pass: returns the Q30 mantissa y, writes the exponent he.
 * arg must be > 0. */
static int64_t rsqrt_q30(int64_t arg, int *he_out)
{
    int m = msb_pos(arg);
    uint64_t A = (uint64_t)arg, mant;
    if (m <= 30) mant = A << (30 - m);
    else         mant = A >> (m - 30);
    /* the RTL asserts this; a model that quietly tolerated it would hide a
     * normalisation bug rather than reproduce one */
    if (((mant >> 30) & 1) != 1) {
        fprintf(stderr, "l2norm_rs_vec: rsqrt mantissa not normalised to Q30\n");
        exit(1);
    }
    int64_t y     = RSQRT_ROM[(mant >> 24) & 0x3F];
    int64_t smant = (int64_t)(uint32_t)mant;          /* signed(mant(31 downto 0)) */
    for (int it = 0; it < 2; it++) {
        int64_t y2 = (int64_t)(int32_t)((y * y) >> 30);
        int64_t d  = THREE_Q30 - ((smant * y2) >> 30);
        y = (int64_t)(int32_t)((d * y) >> 31);
    }
    if (m & 1) { *he_out = (m - 1) / 2; y = (y * INV_SQRT2_C) >> 30; }
    else       { *he_out =  m      / 2; }
    return y;
}

/* the whole unit, for one head */
static void l2norm_rs(const int *x, int N, int log2n, int *k, int *q)
{
    int64_t ssq = 0;
    for (int i = 0; i < N; i++) ssq += (int64_t)x[i] * (int64_t)x[i];
    if (ssq == 0) {                       /* 2.1.3's divergence from ggml */
        for (int i = 0; i < N; i++) { k[i] = 0; q[i] = 0; }
        return;
    }
    int he_k, he_q;
    int64_t y_k = rsqrt_q30(ssq, &he_k);
    int64_t y_q = rsqrt_q30(ssq << log2n, &he_q);
    int sh_k = 15 + he_k, sh_q = 12 + he_q;
    int64_t bk = sh_k > 0 ? (1LL << (sh_k - 1)) : 0;
    int64_t bq = sh_q > 0 ? (1LL << (sh_q - 1)) : 0;
    for (int i = 0; i < N; i++) {
        /* >> on a negative int64_t is implementation-defined in C but
         * arithmetic on every compiler this repo builds with; the RTL's
         * shift_right on a signed is arithmetic by definition.  Asserted once
         * in main() rather than assumed. */
        k[i] = (int)sat16(((int64_t)x[i] * y_k + bk) >> sh_k);
        q[i] = (int)sat16(((int64_t)x[i] * y_q + bq) >> sh_q);
    }
}

/* deterministic LCG, so the vector file is reproducible without depending on
 * any libc's rand() */
static uint64_t rs;
static int rnd(int lo, int hi)
{
    rs = rs * 6364136223846793005ULL + 1442695040888963407ULL;
    return lo + (int)((rs >> 33) % (uint64_t)(hi - lo + 1));
}

int main(int argc, char **argv)
{
    const char *out = argc > 1 ? argv[1] : "l2norm_rs_vec.txt";
    int N    = argc > 2 ? atoi(argv[2]) : 128;
    rs       = argc > 3 ? (uint64_t)strtoull(argv[3], 0, 0) : 20260828ULL;

    { int64_t t = -8; if ((t >> 1) != -4) {
        fprintf(stderr, "l2norm_rs_vec: >> on int64_t is not arithmetic\n");
        return 1; } }

    int log2n = 0; while ((1 << log2n) < N) log2n++;
    if ((1 << log2n) != N) {
        fprintf(stderr, "l2norm_rs_vec: N must be a power of two\n"); return 1;
    }

    int *x = malloc(sizeof(int) * N);
    int *k = malloc(sizeof(int) * N);
    int *q = malloc(sizeof(int) * N);

    /* Two passes over the same case list: count, then emit, so the header can
     * carry NCASE and the testbench can assert the shape. */
    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return 1; }
    long hdr = 0;
    fprintf(f, "%*s\n", 20, "");        /* placeholder, rewritten at the end */
    hdr = 0;

    int ncase = 0;
    /* GUARD, and it is here because the first version of this file did not
     * have it.  x[] is a C int, so `1 << 15` is a perfectly good 32768 here
     * and becomes -32768 the moment VHDL's to_signed(...,16) sees it: the
     * testbench then drove a DIFFERENT stimulus from the one this model
     * scored, and reported the DUT as not bit-exact with a clean sign flip on
     * two elements of two cases.  That looked exactly like a DUT sign bug.
     * The stimulus is int16 by construction, so say so once, loudly. */
    #define EMIT() do {                                                     \
        for (int i=0;i<N;i++) if (x[i] < -32768 || x[i] > 32767) {          \
            fprintf(stderr, "l2norm_rs_vec: case %d element %d = %d is "    \
                    "outside int16; the testbench would silently drive a "  \
                    "different value\n", ncase, i, x[i]); exit(1); }        \
        l2norm_rs(x, N, log2n, k, q);                                       \
        for (int i=0;i<N;i++) fprintf(f, "%d ", x[i]); fprintf(f, "\n");    \
        for (int i=0;i<N;i++) fprintf(f, "%d ", k[i]); fprintf(f, "\n");    \
        for (int i=0;i<N;i++) fprintf(f, "%d ", q[i]); fprintf(f, "\n");    \
        ncase++;                                                            \
    } while (0)
    #define ZERO() do { for (int i=0;i<N;i++) x[i] = 0; } while (0)

    /* ---- 1. ssq = 0, the deliberate ggml divergence -------------------- */
    ZERO(); EMIT();

    /* ---- 2. near-zero norms: the sat16 corner and its neighbourhood ----
     * A single tiny element makes 1/sqrt(ssq) enormous, so BOTH paths must
     * saturate.  This is also the "denormal-ish" end of the range asked for:
     * ssq as small as it can be while nonzero. */
    ZERO(); x[0] =  1; EMIT();
    ZERO(); x[0] = -1; EMIT();
    ZERO(); x[N-1] = 1; EMIT();                 /* last lane, not the first */
    ZERO(); x[0] = 1; x[1] = -1; EMIT();        /* ssq = 2, msb ODD */
    ZERO(); x[0] = 1; x[1] = 1; x[2] = 1; EMIT();   /* ssq = 3 */
    ZERO(); x[0] = 2; EMIT();                   /* ssq = 4, msb EVEN */
    ZERO(); x[0] = 3; EMIT();                   /* ssq = 9 */
    ZERO(); x[0] = 1; x[N/2] = 1; EMIT();
    ZERO(); x[0] = 32767; EMIT();               /* one element, max magnitude */
    ZERO(); x[0] = -32768; EMIT();

    /* ---- 3. saturated magnitudes everywhere ---------------------------- */
    for (int i = 0; i < N; i++) x[i] = (i % 2 == 0) ? 32767 : -32768;
    EMIT();

    /* ---- 4. uniform, the typical case ---------------------------------- */
    for (int i = 0; i < N; i++) x[i] =  1000; EMIT();
    for (int i = 0; i < N; i++) x[i] = -1000; EMIT();

    /* ---- 5. powers of two: the rsqrt normalisation and the parity fold -- */
    for (int m = 0; m <= 14; m++) {
        for (int i = 0; i < N; i++) x[i] = 1 << m;
        EMIT();
    }

    /* ---- 6. EVERY msb parity of ssq, both paths ------------------------
     * ssq spans 1 .. N*2^30, so msb(ssq) spans 0 .. 30+log2(N).  The fold
     * branch is selected by that parity and the q path sees msb + log2(N), so
     * a sweep that walks every position exercises both branches on both
     * paths.  Built by putting a single element at 2^h and 2^h+1-ish values,
     * which is the only way to place ssq's msb exactly.  This is the sweep
     * the old bench did not have: it walked |x|, not msb(ssq). */
    for (int h = 0; h <= 14; h++) {          /* 1<<15 is not an int16 */
        ZERO(); x[3] = 1 << h;                 EMIT();   /* ssq = 2^(2h)  */
        ZERO(); x[3] = 1 << h; x[4] = 1 << h;  EMIT();   /* ssq = 2^(2h+1) */
        if (h > 0)  { ZERO(); x[3] = (1 << h) - 1; EMIT(); }
        if (h < 14) { ZERO(); x[3] = (1 << h) + 1; EMIT(); }
    }
    /* A single int16 element only reaches msb(ssq) = 30, and the q path adds
     * log2(N).  The TOP of the range, msb(ssq) = 30 .. 30+log2(N), is only
     * reachable with several large elements, so walk the population count at
     * full magnitude: ssq ~ cnt * 2^30, msb = 30 + floor(log2 cnt).  Without
     * this the sweep never exercises the fold branch at the exponents the
     * unit's own u38 bound is written for. */
    for (int cnt = 1; cnt <= N; cnt = (cnt < 4) ? cnt + 1 : cnt * 2) {
        ZERO(); for (int i = 0; i < cnt; i++) x[i] = 32767; EMIT();
        ZERO(); for (int i = 0; i < cnt; i++) x[i] = (i & 1) ? -32768 : 32767; EMIT();
    }
    for (int cnt = 1; cnt <= N; cnt = (cnt < 4) ? cnt + 1 : cnt * 2) {
        ZERO(); for (int i = 0; i < cnt; i++) x[i] = 23170; EMIT();  /* ~2^14.5 */
    }
    /* ---- 6b. msb(ssq) = 30 + log2(N), THE MAXIMUM LEGAL INPUT ------------
     * x[i] = -32768 for all i is a legal int16 vector and gives
     * ssq = N * 2^30 = 2^37 exactly at N = 128 -- the largest ssq the unit can
     * ever be handed, and the single exponent every other case above misses.
     * The single-element and cnt sweeps reach msb(ssq) 0..36 with both
     * parities; this is 37, and it is also the top of the q path's argument
     * range, msb(ssq << log2 N) = 44.
     *
     * IT WAS DELIBERATELY ABSENT UNTIL THE DUT WAS FIXED, and the reason is
     * worth keeping.  rtl/l2norm_rs.vhd:97 states the bound INCLUSIVELY --
     * "ssq <= N * 32768^2 = N * 2^30" -- while the assertion at :245 compared
     * STRICTLY against 2^SSQ_BITS with SSQ_BITS = 30 + log2 N, so the maximum
     * the comment admits was the one value the assert rejected.  MEASURED
     * 2026-08-28 on the untouched RTL, driving exactly this case:
     *     l2norm_rs.vhd:245:13:@30969ns:(assertion failure):
     *         l2norm_rs: ssq outside the u37 bound implied by N
     * at severity FAILURE, i.e. the unit killed the run rather than
     * saturating.  Worklog OI-7.  Adding the case before fixing the DUT would
     * have turned the regression red, which is not the same thing as reporting
     * a defect, so it was carried here as a comment naming the measurement
     * until the compare became <=.  It is a live case now.
     *
     * This vector is UNIQUE: ssq = 2^37 is the maximum, so msb(ssq) = 37
     * forces ssq = 2^37 exactly, which forces |x[i]| = 32768 for every i.
     * There is no second vector at this exponent, hence one case and not a
     * family.  The case after it is the one immediately BELOW the rail --
     * a single element pulled in by one -- so the sweep brackets the compare
     * from both sides rather than only touching it from the top. */
    for (int i = 0; i < N; i++) x[i] = -32768;
    EMIT();
    for (int i = 0; i < N; i++) x[i] = -32768;
    x[0] = -32767;
    EMIT();

    /* ---- 7. extreme dynamic range within one head ----------------------
     * One large element and 127 tiny ones: the tiny elements' outputs land at
     * or below half an LSB, which is where a dropped or doubled rounding bias
     * is visible and where truncation and round-half-up disagree. */
    for (int e = 0; e < 6; e++) {
        for (int i = 0; i < N; i++) x[i] = (i == 0) ? 32767 : ((i & 1) ? 1 : -1);
        for (int i = 1; i < N; i++) x[i] *= (1 << e);
        EMIT();
    }
    /* the same, with the large element NOT first, so a lane/index gating bug
     * that only mis-places the first block cannot hide */
    for (int i = 0; i < N; i++) x[i] = (i == N-3) ? 32767 : 1;
    EMIT();

    /* ---- 8. the old bench's magnitude sweep, kept verbatim -------------- */
    for (int m = 0; m <= 24; m++) {
        for (int i = 0; i < N; i++)
            x[i] = ((m * 41 + i * 13) % 4000) - 2000 + m * 800;
        EMIT();
    }

    /* ---- 9. random, full range and several narrow ones ------------------ */
    for (int t = 0; t < 24; t++) {
        int lim = (t < 8) ? 32767 : (t < 16) ? 255 : 7;
        for (int i = 0; i < N; i++) x[i] = rnd(-lim, lim);
        EMIT();
    }
    /* random SPARSE: most elements zero, so ssq stays small while individual
     * |x| are large -- the combination that saturates some lanes and not
     * others inside one head */
    for (int t = 0; t < 12; t++) {
        ZERO();
        int nz = 1 + t;
        for (int j = 0; j < nz; j++) x[rnd(0, N-1)] = rnd(-32768, 32767);
        EMIT();
    }

    /* rewrite the header now that ncase is known */
    fseek(f, 0, SEEK_SET);
    fprintf(f, "%d %d", ncase, N);
    fclose(f);
    fprintf(stderr, "l2norm_rs_vec: %d cases (N=%d) -> %s\n", ncase, N, out);
    (void)hdr;
    return 0;
}
