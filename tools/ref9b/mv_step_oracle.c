/* mv_step_oracle -- run ONE subsystem-A job of sim/tb_llama_top.vhd through
 * ref/matvec_int4.c and print the result, so a captured seam can be compared
 * against something other than the machine that produced it.
 *
 * WHY THIS IS AN ORACLE AND NOT A ROUND TRIP.  Every line of arithmetic here
 * comes from `ref/matvec_int4.c`, which is the project's INT4 matvec reference
 * and is not derived from `rtl/matvec_int4.vhd`; `sim/run_matvec.sh` is the
 * bench that holds the two together at the UNIT level.  What is new is the
 * level: nothing before this compared the integration's A jobs -- the weights
 * the top level actually fetched, the descriptor it actually built, the source
 * region it actually read and the exponent the region lock actually captured --
 * against the reference.  A unit that is right and an integration that feeds
 * it the wrong bytes produce a perfectly plausible wrong number.
 *
 * WHY A HEADER IS SYNTHESISED HERE.  The bench's AXI slaves serve the packed
 * SUB-REGIONS and nothing else: the 4 KB spec-6.4 header never reaches the
 * design, which carries M, K, w_exp, out_shift and the codebook in its
 * descriptor and its generics instead.  So the body bytes exist and the header
 * does not, and `mv4i_parse` needs one.  This file writes the 6.4 header and
 * copies the bench's bytes in behind it.
 *
 * THE BIT LAYOUT IS NOT REIMPLEMENTED, AND THAT IS THE POINT.  Only the
 * HEADER is written here -- twenty scalar fields and two offset tables, every
 * one of them checked by `mv4i_parse` (it refuses -3/-4/-7/-8/-9 on an
 * inconsistent one) and the offsets checked AGAIN below against the addresses
 * the bench actually serves.  The 6.5a bit-slice layout, which is the part a
 * second implementation could get wrong while agreeing with itself, is read by
 * `ref/matvec_int4.c`'s own `get_widx`/`get_scale` and by nothing here.
 *
 * ref/matvec_int4.c is INCLUDED with MV4I_LIB, which is the mode
 * `hw/mv_driver.c` already links it in.  `ref/` belongs to another track and
 * is not edited.
 *
 * Build:  cc -O2 -Wall -DMV4I_LIB -I ref -o tools/ref9b/mv_step_oracle \
 *              tools/ref9b/mv_step_oracle.c -lm
 * Usage:  mv_step_oracle <jobfile>
 *
 * The job file, whitespace separated:
 *      M K w_exp out_shift x_exp
 *      X <K int16 mantissas>
 *      SUB <p> <nbytes> <nbytes hex byte pairs>      (p = 0..NPORTS_W, once each)
 * and the output on stdout:
 *      Y <y_exp> <ns> <M>
 *      <M int16 mantissas>
 */
#define MV4I_LIB 1
#include "../../ref/matvec_int4.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ROWS_IF   4
#define AXI_DW  128
#define SUB    4096                 /* the bench's per-sub-region stride */

/* rtl/llama_top.vhd's `cb_int4`: the two's-complement int4 identity.  NOT
 * IQ4_NL.  The bench never serves the header, so the design's codebook is the
 * one that matters and it is this one. */
static const int8_t CB_INT4[16] = { 0, 1, 2, 3, 4, 5, 6, 7,
                                   -8,-7,-6,-5,-4,-3,-2,-1 };

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: mv_step_oracle <jobfile>\n"); return 2; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }

    int M, K, w_exp, out_shift, x_exp;
    if (fscanf(f, "%d %d %d %d %d", &M, &K, &w_exp, &out_shift, &x_exp) != 5) {
        fprintf(stderr, "bad header\n"); return 2;
    }
    char tag[32];
    if (fscanf(f, "%31s", tag) != 1 || strcmp(tag, "X")) {
        fprintf(stderr, "expected X\n"); return 2;
    }
    int16_t *x = calloc((size_t)K, sizeof *x);
    for (int i = 0; i < K; i++) {
        int v; if (fscanf(f, "%d", &v) != 1) { fprintf(stderr, "short X\n"); return 2; }
        x[i] = (int16_t)v;
    }

    /* The spec-6.4 header, and a body of zeros for the bench's bytes. */
    const int nports = ROWS_IF * MV4I_BLOCK * 4 / AXI_DW;      /* 6.5 invariant */
    const size_t scl_off = (size_t)MV4I_HDR_BYTES + (size_t)SUB * nports;
    size_t len = scl_off + SUB;
    uint8_t *img = calloc(1, len);
    if (!img) { fprintf(stderr, "out of memory\n"); return 2; }
    memcpy(img + 0x00, "\x49\x34\x56\x4D", 4);   /* 'MV4I' little-endian u32 */
    img[0x04] = 1;                                  /* version                  */
    img[0x06] = 1;                                  /* flags: codebook present  */
    { uint32_t v;
      v = (uint32_t)M;         memcpy(img + 0x08, &v, 4);
      v = (uint32_t)K;         memcpy(img + 0x0C, &v, 4);
      v = (uint32_t)w_exp;     memcpy(img + 0x10, &v, 4);
      v = (uint32_t)out_shift; memcpy(img + 0x14, &v, 4);
      v = (uint32_t)scl_off;   memcpy(img + 0x30, &v, 4);
      v = 1u;                  memcpy(img + 0x34, &v, 4); }
    { uint16_t v;
      v = ROWS_IF;             memcpy(img + 0x18, &v, 2);
      v = (uint16_t)nports;    memcpy(img + 0x1A, &v, 2);
      v = MV4I_BLOCK;          memcpy(img + 0x1C, &v, 2);
      v = AXI_DW;              memcpy(img + 0x1E, &v, 2); }
    memcpy(img + 0x20, CB_INT4, 16);
    for (int p2 = 0; p2 < nports; p2++) {
        uint64_t o = (uint64_t)MV4I_HDR_BYTES + (uint64_t)SUB * p2;
        memcpy(img + 0x38 + 8 * p2, &o, 8);
    }
    { uint64_t o = scl_off; memcpy(img + 0x38 + 8 * nports, &o, 8); }

    /* THE LAYOUT ASSUMPTION IS CHECKED, NOT ASSUMED.  The bench places port p
     * at base + p*4096 and the scale sub-region at base + NPORTS_W*4096, which
     * is only the same as the packed file's own offsets while every sub-region
     * pads to exactly 4096 bytes.  It does at every shape this bench runs, and
     * it would stop silently at a larger one. */
    mv4i_file probe;
    int prc = mv4i_parse(&probe, img, len);
    if (prc) { fprintf(stderr, "parse of the synthesised header failed: %d\n", prc); return 2; }
    if ((int)probe.h.nports_w != nports) { fprintf(stderr, "nports disagree\n"); return 2; }
    for (int p = 0; p < nports; p++) {
        if (probe.h.w_sub_offset[p] != (uint64_t)MV4I_HDR_BYTES + (uint64_t)SUB * p) {
            fprintf(stderr, "sub-region %d is at %llu, the bench serves it at %d "
                    "-- the 4096-byte stride assumption has stopped holding\n",
                    p, (unsigned long long)probe.h.w_sub_offset[p],
                    MV4I_HDR_BYTES + SUB * p);
            return 2;
        }
    }
    if (probe.h.n_scale_sub != 1 ||
        probe.h.s_sub_offset[0] != (uint64_t)MV4I_HDR_BYTES + (uint64_t)SUB * nports) {
        fprintf(stderr, "the scale sub-region is not where the bench serves it\n");
        return 2;
    }

    int seen[MV4I_MAX_SUB + 1] = { 0 };
    while (fscanf(f, "%31s", tag) == 1) {
        if (strcmp(tag, "SUB")) { fprintf(stderr, "expected SUB, got %s\n", tag); return 2; }
        int p, nb;
        if (fscanf(f, "%d %d", &p, &nb) != 2) { fprintf(stderr, "bad SUB\n"); return 2; }
        if (p < 0 || p > nports || nb < 0 || nb > SUB) {
            fprintf(stderr, "SUB %d %d out of range\n", p, nb); return 2;
        }
        uint8_t *dst = img + MV4I_HDR_BYTES + (size_t)SUB * p;
        for (int i = 0; i < nb; i++) {
            unsigned v; if (fscanf(f, "%2x", &v) != 1) { fprintf(stderr, "short SUB\n"); return 2; }
            dst[i] = (uint8_t)v;
        }
        seen[p] = 1;
    }
    for (int p = 0; p <= nports; p++)
        if (!seen[p]) { fprintf(stderr, "sub-region %d was not supplied\n", p); return 2; }
    fclose(f);

    mv4i_file mf;
    if (mv4i_parse(&mf, img, len)) { fprintf(stderr, "parse failed\n"); return 2; }
    mv4i_result r;
    memset(&r, 0, sizeof r);
    r.y_data = calloc((size_t)M, sizeof *r.y_data);
    r.y_mant = calloc((size_t)M, sizeof *r.y_mant);
    r.y_acc  = calloc((size_t)M, sizeof *r.y_acc);
    int rc = mv4i_matvec(&mf, x, x_exp, M, K, MV4I_MODE_BFP, &r);
    if (rc) { fprintf(stderr, "mv4i_matvec rc=%d\n", rc); return 2; }

    printf("Y %d %d %d\n", r.y_exp, r.ns, M);
    for (int i = 0; i < M; i++)
        printf("%d%c", (int)r.y_mant[i], (i % 16 == 15 || i == M - 1) ? '\n' : ' ');
    return 0;
}
