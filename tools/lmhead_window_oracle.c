/* tools/lmhead_window_oracle.c -- does a WINDOWED lm_head compute the same
 * logits as one whole-tensor job would?
 *
 * WHY THIS FILE EXISTS.  `tools/gen_lmhead_windows.py` proves the 15 windows
 * TILE `output.weight`: the row cover is exact and the byte cover abuts across
 * all 27 sub-regions.  Neither of those is a statement about NUMBERS.  A base
 * that is well formed and aimed at the wrong bytes is the worklog's OI-3
 * family and the byte cover cannot see it either, because abutment is a
 * property of the arithmetic that produced the bases, not of what those bytes
 * decode to.  `docs/2026-08-28_token-io-path.md` section 10 item 3 names this
 * gap in its own words: "No lm_head result was ever computed."
 *
 * WHAT IT DOES.  One process, one copy of the packed tensor in memory:
 *
 *   1. `mv4i_matvec` over ALL M rows -> the reference logits.  This is the
 *      whole-tensor job the gateware cannot express, computed by the C
 *      reference, which has no MAXROWS_BFP.
 *   2. For each window, `mv4i_matvec` over that window's n_rows, with the 27
 *      sub-region offsets REPLACED by the ones the emitted DESCRIPTOR carries.
 *      Nothing here re-derives a base: the offsets come in on stdin's spec
 *      file, straight out of `Descriptor.fields["w_base"]/["s_base"]` minus
 *      the tensor's HBM offset -- the same 27 numbers the AXI masters will
 *      put on the bus.
 *   3. Compare window row j against whole-tensor row row_start+j, exactly.
 *
 * WHY A WHOLE-TENSOR RUN IS A LEGITIMATE ORACLE FOR A SET OF WINDOWS, and
 * only in raw mode.  `ref/matvec_int4.c:396` is
 *     y_data[r] = sat32(round_shift(acc_r, out_shift))
 * and `:436` is  y_exp = w_exp + x_exp - out_shift.  Neither expression reads
 * any row but r, so raw mode has NO cross-row term and slicing the row range
 * cannot change a value.  BFP mode does: `:403-413` takes `ns` from the max of
 * |y_data| over the JOB's rows, so the same rows in a different job carry
 * different mantissas AND a different exponent.  This program runs both, and
 * the BFP run failing is the measurement that the mode choice is load-bearing
 * rather than a preference.
 *
 * NOT AN ORACLE FOR: the RTL.  This is the C reference judging the
 * DESCRIPTOR's bases and beat counts.  The RTL's own agreement with the C
 * reference is `sim/tb_matvec_core` and `sim/tb_matvec_fk33*`'s business.
 *
 *   cc -O2 -Wall -Wextra -I ref -o lmhead_window_oracle \
 *      tools/lmhead_window_oracle.c
 *   ./lmhead_window_oracle FILE.mv4i SPEC.txt
 *
 * No -DNDEBUG: ref/matvec_int4.c #errors under it, because every width bound
 * of spec 7.4 is enforced by assert() alone.
 */

#define MV4I_LIB 1
#include "matvec_int4.c"

#include <errno.h>

#define MAXWIN 64

typedef struct {
    int      row_start;
    int      n_rows;
    uint64_t w_off[MV4I_MAX_SUB];
    uint64_t s_off[MV4I_MAX_SUB];
    int      have_w, have_s;
} win_t;

static uint8_t *slurp(const char *path, size_t *len_out)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    if (fseek(fp, 0, SEEK_END)) { fclose(fp); return NULL; }
    long n = ftell(fp);
    if (n < 0) { fclose(fp); return NULL; }
    rewind(fp);
    uint8_t *buf = malloc((size_t)n);
    if (!buf) { fclose(fp); return NULL; }
    if (fread(buf, 1, (size_t)n, fp) != (size_t)n) {
        free(buf); fclose(fp); return NULL;
    }
    fclose(fp);
    *len_out = (size_t)n;
    return buf;
}

/* The activation vector.  Same LCG as ref/mv_fk33_tr.c, so a trace produced
 * there and a run produced here see the same x for the same seed. */
static void make_x(int16_t *x, int n, uint32_t seed, int xamp)
{
    uint32_t st = seed;
    for (int k = 0; k < n; k++) {
        st = st * 1103515245u + 12345u;
        x[k] = (int16_t)((int32_t)((st >> 8) % (uint32_t)(2 * xamp + 1)) - xamp);
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s FILE.mv4i SPEC.txt\n", argv[0]);
        return 1;
    }
    FILE *sp = fopen(argv[2], "r");
    if (!sp) { perror(argv[2]); return 2; }

    int x_exp = 0, mode = MV4I_MODE_RAW, nwin = 0, xamp = 8000;
    uint32_t seed = 20260829u;
    static win_t win[MAXWIN];
    char line[512];
    while (fgets(line, sizeof line, sp)) {
        int i, p; long long v;
        if (sscanf(line, "XEXP %d", &x_exp) == 1) continue;
        if (sscanf(line, "SEED %lld", &v) == 1) { seed = (uint32_t)v; continue; }
        if (sscanf(line, "XAMP %d", &xamp) == 1) continue;
        if (sscanf(line, "MODE %d", &mode) == 1) continue;
        if (sscanf(line, "NWIN %d", &nwin) == 1) {
            if (nwin <= 0 || nwin > MAXWIN) {
                fprintf(stderr, "NWIN %d outside 1..%d\n", nwin, MAXWIN);
                return 3;
            }
            continue;
        }
        {
            int rs, nr;
            if (sscanf(line, "WIN %d %d %d", &i, &rs, &nr) == 3) {
                if (i < 0 || i >= MAXWIN) return 3;
                win[i].row_start = rs; win[i].n_rows = nr;
                continue;
            }
        }
        if (sscanf(line, "WOFF %d %d %lld", &i, &p, &v) == 3) {
            if (i < 0 || i >= MAXWIN || p < 0 || p >= MV4I_MAX_SUB) return 3;
            win[i].w_off[p] = (uint64_t)v; win[i].have_w++;
            continue;
        }
        if (sscanf(line, "SOFF %d %d %lld", &i, &p, &v) == 3) {
            if (i < 0 || i >= MAXWIN || p < 0 || p >= MV4I_MAX_SUB) return 3;
            win[i].s_off[p] = (uint64_t)v; win[i].have_s++;
            continue;
        }
    }
    fclose(sp);

    size_t len = 0;
    uint8_t *img = slurp(argv[1], &len);
    if (!img) { fprintf(stderr, "%s: %s\n", argv[1], strerror(errno)); return 2; }

    mv4i_file f;
    int prc = mv4i_parse(&f, img, len);
    if (prc) { fprintf(stderr, "mv4i_parse rejected %s: %d\n", argv[1], prc); return 4; }

    const int M = (int)f.h.M, K = (int)f.h.K;
    int16_t *x = malloc(sizeof(int16_t) * (size_t)K);
    make_x(x, K, seed, xamp);

    printf("GEOM rows_if=%d axi_dw=%d nports_w=%u n_scale_sub=%u grp=%d nb=%d\n",
           f.h.rows_if, f.h.axi_dw, f.h.nports_w, f.h.n_scale_sub, f.grp, f.nb);
    printf("DIMS M=%d K=%d w_exp=%d out_shift=%d x_exp=%d mode=%d\n",
           M, K, f.h.w_exp, f.h.out_shift, x_exp, mode);

    /* ---- 1. the whole tensor, which the gateware cannot express ---------- */
    mv4i_result all;
    all.y_data = malloc(4 * (size_t)M);
    all.y_acc  = malloc(8 * (size_t)M);
    all.y_mant = malloc(2 * (size_t)M);
    if (!all.y_data || !all.y_acc || !all.y_mant) { fprintf(stderr, "oom\n"); return 5; }
    all.y_exp = 0; all.sat_event = 0; all.sat_count = 0; all.ns = 0;
    if (mv4i_matvec(&f, x, x_exp, M, K, mode, &all)) {
        fprintf(stderr, "whole-tensor mv4i_matvec failed\n"); return 5;
    }
    /* A checksum over EVERY row, so a mutation that moves values the window
     * comparison happens not to reach still shows up in the transcript. */
    uint64_t sum = 1469598103934665603ull;
    for (int r = 0; r < M; r++) {
        uint32_t u = (uint32_t)all.y_data[r];
        for (int b = 0; b < 4; b++) { sum ^= (u >> (8 * b)) & 0xFF; sum *= 1099511628211ull; }
    }
    printf("WHOLE rows=%d y_exp=%d ns=%d sat=%d fnv1a=%016llX\n",
           M, all.y_exp, all.ns, all.sat_event ? 1 : 0,
           (unsigned long long)sum);

    /* ---- 2/3. every window, through the descriptor's own bases ----------- */
    mv4i_file g = f;                       /* a copy whose offsets we replace */
    int32_t *wy   = malloc(4 * (size_t)M);
    int64_t *wacc = malloc(8 * (size_t)M);
    int16_t *wmnt = malloc(2 * (size_t)M);
    long total_bad = 0, total_rows = 0;
    int exp_bad = 0;

    for (int i = 0; i < nwin; i++) {
        if (win[i].have_w != (int)f.h.nports_w
            || win[i].have_s != (int)f.h.n_scale_sub) {
            fprintf(stderr, "window %d: %d weight and %d scale offsets, "
                    "geometry needs %u and %u\n", i, win[i].have_w,
                    win[i].have_s, f.h.nports_w, f.h.n_scale_sub);
            return 3;
        }
        for (unsigned p = 0; p < f.h.nports_w; p++)
            g.h.w_sub_offset[p] = win[i].w_off[p];
        for (unsigned q = 0; q < f.h.n_scale_sub; q++)
            g.h.s_sub_offset[q] = win[i].s_off[q];
        g.h.M = (uint32_t)win[i].n_rows;

        mv4i_result w;
        w.y_data = wy; w.y_acc = wacc; w.y_mant = wmnt;
        w.y_exp = 0; w.sat_event = 0; w.sat_count = 0; w.ns = 0;
        if (mv4i_matvec(&g, x, x_exp, win[i].n_rows, K, mode, &w)) {
            fprintf(stderr, "window %d mv4i_matvec failed\n", i); return 5;
        }

        long bad = 0; int first = -1;
        long long got0 = 0, want0 = 0;
        for (int j = 0; j < win[i].n_rows; j++) {
            long long got, want;
            if (mode == MV4I_MODE_BFP) {
                got = w.y_mant[j];  want = all.y_mant[win[i].row_start + j];
            } else if (mode == MV4I_MODE_PARTIAL) {
                got = w.y_acc[j];   want = all.y_acc[win[i].row_start + j];
            } else {
                got = w.y_data[j];  want = all.y_data[win[i].row_start + j];
            }
            if (got != want) {
                if (!bad) { first = win[i].row_start + j; got0 = got; want0 = want; }
                bad++;
            }
        }
        total_bad += bad; total_rows += win[i].n_rows;
        if (w.y_exp != all.y_exp) exp_bad++;
        printf("WIN %-2d rows %7d..%7d  y_exp=%-4d ns=%-3d sat=%d  "
               "mismatch=%ld", i, win[i].row_start,
               win[i].row_start + win[i].n_rows - 1, w.y_exp, w.ns,
               w.sat_event ? 1 : 0, bad);
        if (bad) printf("  first row %d got %lld want %lld", first, got0, want0);
        putchar('\n');
    }

    printf("TOTAL windows=%d rows=%ld mismatch=%ld exp_mismatch=%d\n",
           nwin, total_rows, total_bad, exp_bad);
    printf("VERDICT %s\n",
           (total_bad == 0 && exp_bad == 0 && total_rows == M) ? "PASS" : "FAIL");
    return (total_bad == 0 && exp_bad == 0 && total_rows == M) ? 0 : 1;
}
