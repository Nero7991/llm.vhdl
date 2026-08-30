/* lmhead_raw_oracle.c -- compute the lm_head's 248,320 RAW s32 logits from a
 * supplied activation vector, and write them out so a host tool can hand each
 * of the 15 descriptor windows its expected values.
 *
 * TRACK TOKENRUN.  Written for hw/fk33/host/fk33_run_token.py.
 *
 * WHY A SECOND ORACLE FILE EXISTS AT ALL
 * --------------------------------------
 * hw/fk33/host/mv4i_job_oracle.c (TRACK LAYERRUN) already batches subsystem-A
 * row-window jobs, and this file does NOT replace it: that one emits BFP int16
 * mantissas, because every job inside a transformer layer is a BFP job.  The
 * lm_head is the one A job in the whole token program that is issued in RAW
 * mode (tools/gen_layer_program.py:433-443, rtl/llama_top.vhd:737-741), its
 * payload is s32 and not int16, and there was no path that produced those
 * numbers for a card comparison.  This is that path and nothing else.
 *
 * WHY ONE WHOLE-TENSOR CALL IS A LEGITIMATE EXPECTATION FOR FIFTEEN WINDOWS
 * ------------------------------------------------------------------------
 * The same argument tools/lmhead_window_oracle.c makes, and it holds only in
 * raw mode.  ref/matvec_int4.c:396 is
 *     y_data[r] = sat32(round_shift(acc_r, out_shift))
 * and :436 is  y_exp = w_exp + x_exp - out_shift.  Neither expression reads
 * any row but r, so raw mode has NO cross-row term: a row's value does not
 * depend on how many rows were asked for, and slicing [row0, row0+n) out of a
 * whole-tensor run is exactly what a window must reproduce.  BFP mode does not
 * have that property (:403-413 takes ns from a max over the JOB's rows), which
 * is why the schedule issues the lm_head raw and why this file refuses to run
 * in any other mode.
 *
 * WHAT THIS IS NOT
 * ----------------
 * It is NOT an independent oracle for the arithmetic.  It calls mv4i_matvec,
 * which is the same function ref/run9b.c's lm_head() calls, on the same bytes.
 * Agreement between this and the reference stream's LOGITS record therefore
 * says NOTHING new about the matvec.  What it says, with no hardware in the
 * room, is that the vector fk33_run_token.py pulled out of R_XN.final, at the
 * exponent it read from that seam, reproduces the reference's logits -- i.e.
 * that the host's final-norm step and its exponent plumbing are right.  If the
 * card then disagrees, the disagreement is the card's.
 *
 * It is also NOT a check that the 15 WINDOWS tile the tensor.  That is
 * tools/gen_lmhead_windows.py (geometry) and tools/lmhead_window_check.py
 * (the descriptor bases, judged by ref/matvec_int4.c).  This file computes one
 * whole-tensor run and the caller slices it; the card is what is being asked
 * whether its windows agree.
 *
 * Build:
 *   cc -O2 -w -I ref -o OUT hw/fk33/host/lmhead_raw_oracle.c -lm
 * (No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose, because every
 * width bound of spec 7.4 is enforced by assert() alone.)
 *
 * Usage:
 *   lmhead_raw_oracle <output.weight.mv4i> <x.i16> <x_exp> <y.s32>
 *
 * <x.i16> must be exactly 2*K bytes; a short file is REFUSED rather than
 * padded, because a short x computes a plausible wrong answer against whatever
 * the allocator last held.  <y.s32> is written with M little-endian int32.
 *
 * stdout, one line each, so a caller never has to parse prose:
 *   HEAD <M> <K> <w_exp> <out_shift>
 *   YEXP <e>
 *   SAT  <sat_event>
 *   ARGMAX <index> <value>
 *   OK
 * and on any refusal a single line
 *   BAD <reason-with-no-spaces>
 * with a nonzero exit status, so a caller cannot mistake a skipped run for a
 * clean one.
 *
 * ARGMAX IS PRINTED HERE ON PURPOSE.  rtl/sampler_stream.vhd seeds its
 * candidate with index 0 and displaces it only on a STRICT '>', so the FIRST
 * maximum wins; ref/run9b.c:372 argmax_first is the same rule.  It is restated
 * here over the s32 payload -- which is what the card publishes -- so that the
 * token the card's own numbers imply is computed by the same rule on both
 * sides.  NOTE the rule is UNEXERCISED wherever the logits are all distinct.
 */

#define MV4I_LIB 1
#include "../../../ref/matvec_int4.c"

#include <errno.h>

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

static int bad(const char *why)
{
    printf("BAD %s\n", why);
    return 3;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr,
                "usage: %s <output.weight.mv4i> <x.i16> <x_exp> <y.s32>\n",
                argv[0]);
        return 2;
    }
    const char *wpath = argv[1], *xpath = argv[2], *ypath = argv[4];
    int x_exp = atoi(argv[3]);

    size_t wlen = 0;
    uint8_t *wimg = slurp(wpath, &wlen);
    if (!wimg) { fprintf(stderr, "%s: %s\n", wpath, strerror(errno)); return 3; }

    mv4i_file f;
    int prc = mv4i_parse(&f, wimg, wlen);
    if (prc) { fprintf(stderr, "%s: mv4i_parse refused it: %d\n", wpath, prc); return 4; }

    int M = (int)f.h.M, K = (int)f.h.K;
    printf("HEAD %d %d %d %d\n", M, K, (int)f.h.w_exp, (int)f.h.out_shift);

    FILE *xf = fopen(xpath, "rb");
    if (!xf) return bad("cannot-open-x");
    if (fseek(xf, 0, SEEK_END)) { fclose(xf); return bad("x-seek"); }
    long xlen = ftell(xf); rewind(xf);
    if (xlen != (long)K * 2) {
        fclose(xf);
        printf("BAD x-is-%ld-bytes-want-%ld\n", xlen, (long)K * 2);
        return 3;
    }
    int16_t *x = malloc(sizeof(int16_t) * (size_t)K);
    if (fread(x, 1, (size_t)xlen, xf) != (size_t)xlen) {
        fclose(xf); return bad("x-short-read");
    }
    fclose(xf);

    int32_t *y = malloc(sizeof(int32_t) * (size_t)M);
    if (!y) return bad("out-of-memory");

    mv4i_result res;
    res.y_data = y; res.y_mant = NULL; res.y_acc = NULL;
    res.y_exp = 0; res.sat_event = 0; res.sat_count = 0; res.ns = 0;
    /* MV4I_MODE_RAW, hard-coded and not a parameter.  A BFP run over the whole
     * tensor would carry an ns scanned across 248,320 rows and could not be
     * sliced into windows at all -- so offering the choice would only offer a
     * way to be wrong. */
    int rc = mv4i_matvec(&f, x, x_exp, M, K, MV4I_MODE_RAW, &res);
    if (rc) { printf("BAD mv4i_matvec-rc-%d\n", rc); return 3; }

    int e = (int)f.h.w_exp + x_exp - (int)f.h.out_shift;
    printf("YEXP %d\n", e);
    printf("SAT %d\n", res.sat_event);

    int bi = 0;
    for (int r = 1; r < M; r++) if (y[r] > y[bi]) bi = r;   /* FIRST maximum */
    printf("ARGMAX %d %d\n", bi, y[bi]);

    FILE *yf = fopen(ypath, "wb");
    if (!yf) return bad("cannot-open-y-for-write");
    if (fwrite(y, sizeof(int32_t), (size_t)M, yf) != (size_t)M) {
        fclose(yf); return bad("y-short-write");
    }
    if (fclose(yf)) return bad("y-close-failed");

    printf("OK\n");
    return 0;
}
