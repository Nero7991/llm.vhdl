/* tools/qkv_pad_equiv.c -- does a matvec over a PADDED qkv segment compute the
 * same numbers as the same rows of the UNPADDED tensor?
 *
 * THE QUESTION.  The GDN block's `attn_qkv` is fused q | k | v (2048 | 2048 |
 * 4096 at the 9B shape) and the layer program issues one job per segment so
 * each gets its own BFP block exponent.  A job that does not start at row 0 is
 * a row WINDOW and a window can only begin on a TILE boundary, but
 * `2048 mod 48 = 32` and `4096 mod 48 = 16`, so two of the three are not
 * expressible.  `tools/pack_model_fk33.py` therefore pads each segment up to a
 * whole tile with ZERO rows, moving the starts to 0, 2064 and 4128.
 *
 * WHAT THIS PROVES.  That the pad is a placement change and not a numeric one:
 * the packed file is REQUANTIZED from the GGUF with 48 extra zero rows in it,
 * so "the real rows are unchanged" is a claim about the quantizer as well as
 * about the layout, and it has to be COMPUTED rather than assumed.
 *
 * WHY RAW MODE for the primary compare.  MODE_BFP normalizes by an `ns`
 * scanned over the rows present in THAT job, so a 2048-row segment job and an
 * 8192-row whole-tensor job legitimately produce different mantissa grids.
 * MODE_RAW emits `sat32(round_shift(acc, out_shift))` per row with NO
 * cross-row term at all, so y_raw[r] is a function of row r alone and slicing
 * it is legitimate.  That is what makes the unpadded whole-tensor job a valid
 * oracle for each padded segment.
 *
 * THE SECOND COMPARE, in BFP.  Segment q is the ONE window that is expressible
 * against both files (row_start 0), so it is run in MODE_BFP on both and the
 * mantissas AND y_exp must match bit for bit.  That is the check that the pad
 * rows do not reach the amax scan: they sit at indices >= n_rows and both
 * `ref/matvec_int4.c` and `rtl/matvec_core.vhd` mask such a row out of the
 * fold, so ns -- and therefore y_exp -- must be identical.
 *
 *   cc -O2 -Wall -Wextra -o qkv_pad_equiv tools/qkv_pad_equiv.c
 *   ./qkv_pad_equiv OLD.mv4i NEW.mv4i --segs 2048,2048,4096 [--mutate N]
 *
 * --mutate is the teeth check: N selects a defect that MUST make the
 * comparison fail.  A checker never shown to fail has not been shown to work.
 */

#define MV4I_LIB 1
#include "../ref/matvec_int4.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *p, size_t *n)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)len);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) {
        fprintf(stderr, "short read on %s\n", p); exit(2);
    }
    fclose(f); *n = (size_t)len; return b;
}

int main(int argc, char **argv)
{
    const char *oldp = NULL, *newp = NULL, *segstr = "2048,2048,4096";
    int mutate = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--segs") && i + 1 < argc) segstr = argv[++i];
        else if (!strcmp(argv[i], "--mutate") && i + 1 < argc) mutate = atoi(argv[++i]);
        else if (!oldp) oldp = argv[i];
        else newp = argv[i];
    }
    if (!oldp || !newp) {
        fprintf(stderr, "usage: %s OLD.mv4i NEW.mv4i [--segs a,b,c] [--mutate N]\n",
                argv[0]);
        return 1;
    }

    int seg[16], nseg = 0;
    for (const char *p = segstr; *p && nseg < 16; ) {
        seg[nseg++] = atoi(p);
        while (*p && *p != ',') p++;
        if (*p == ',') p++;
    }

    size_t lo_n, ln_n;
    uint8_t *oimg = slurp(oldp, &lo_n), *nimg = slurp(newp, &ln_n);
    mv4i_file fo, fn;
    if (mv4i_parse(&fo, oimg, lo_n)) { fprintf(stderr, "parse OLD failed\n"); return 2; }
    if (mv4i_parse(&fn, nimg, ln_n)) { fprintf(stderr, "parse NEW failed\n"); return 2; }

    const int K = (int)fo.h.K, RI = fo.h.rows_if;
    const int NB = fo.nb, GRP = fo.grp, PB = fo.port_b;
    const int NPW = fo.h.nports_w, NPS = (int)fo.h.n_scale_sub;
    printf("old      %s  M=%u K=%u w_exp=%d out_shift=%d\n",
           oldp, fo.h.M, fo.h.K, fo.h.w_exp, fo.h.out_shift);
    printf("new      %s  M=%u K=%u w_exp=%d out_shift=%d\n",
           newp, fn.h.M, fn.h.K, fn.h.w_exp, fn.h.out_shift);
    printf("geom     ROWS_IF=%d nb=%d grp=%d port_b=%d nports_w=%d n_scale_sub=%d\n",
           RI, NB, GRP, PB, NPW, NPS);

    if (fo.h.K != fn.h.K || fo.h.rows_if != fn.h.rows_if
        || fo.h.nports_w != fn.h.nports_w || fo.nb != fn.nb) {
        printf("FAIL the two files are not the same geometry\n"); return 1;
    }
    /* w_exp is GLOBAL (chosen from |W|max).  Zero pad rows cannot move a max,
     * so a different w_exp here would mean the pad changed the quantization of
     * every real row, and every byte comparison below would be meaningless. */
    if (fo.h.w_exp != fn.h.w_exp || fo.h.out_shift != fn.h.out_shift) {
        printf("FAIL w_exp/out_shift moved: the pad changed the quantization\n");
        return 1;
    }
    int logical = 0;
    for (int i = 0; i < nseg; i++) logical += seg[i];
    if ((int)fo.h.M != logical) {
        printf("FAIL old M=%u but the segments sum to %d\n", fo.h.M, logical);
        return 1;
    }

    /* deterministic activation vector, same generator as the reference's own
     * --crosscheck, so the numbers are reproducible and not all one sign */
    int16_t *x = malloc(sizeof(int16_t) * (size_t)K);
    uint32_t st = 2463534242u;
    for (int k = 0; k < K; k++) {
        st ^= st << 13; st ^= st >> 17; st ^= st << 5;
        x[k] = (int16_t)((int32_t)(st % 20001) - 10000);
    }

    /* ---- the oracle: one RAW job over the whole UNPADDED tensor */
    mv4i_result full = { malloc(4 * (size_t)fo.h.M), NULL, NULL, 0, 0, 0, 0 };
    if (mv4i_matvec(&fo, x, 0, (int)fo.h.M, K, MV4I_MODE_RAW, &full)) {
        fprintf(stderr, "whole-tensor OLD job refused\n"); return 2;
    }
    printf("oracle   1 RAW job over the unpadded tensor, %u rows, sat=%d\n",
           fo.h.M, full.sat_event);

    long long checked = 0, bad = 0;
    int first_bad_seg = -1, first_bad_row = -1;
    int lstart = 0, pstart = 0;

    for (int s = 0; s < nseg; s++) {
        int nr = seg[s];
        /* the PACKED start: pad each segment but the last up to a whole tile.
         * `pstart` is advanced at the bottom of this loop. */
        int skip_tiles = pstart / RI;
        if (pstart % RI) {
            printf("FAIL segment %d starts at packed row %d, not a multiple "
                   "of ROWS_IF=%d\n", s, pstart, RI);
            return 1;
        }
        long long w_skip = (long long)skip_tiles * NB * PB;
        long long s_skip = ((long long)skip_tiles * NB / GRP) * PB;

        mv4i_file g = fn;
        for (int p = 0; p < NPW; p++) g.h.w_sub_offset[p] += (uint64_t)w_skip;
        for (int q = 0; q < NPS; q++) g.h.s_sub_offset[q] += (uint64_t)s_skip;
        g.h.M = (uint32_t)nr;

        switch (mutate) {
        case 0: break;
        case 1:  /* the pad was not applied: read the segment at its LOGICAL row */
            for (int p = 0; p < NPW; p++)
                g.h.w_sub_offset[p] += (uint64_t)(((long long)(lstart / RI)
                                                   - skip_tiles) * NB * PB);
            for (int q = 0; q < NPS; q++)
                g.h.s_sub_offset[q] += (uint64_t)((((long long)(lstart / RI)
                                                   - skip_tiles) * NB / GRP) * PB);
            break;
        case 2:  /* one weight base off by a single beat, on segment 1 only */
            if (s == 1) g.h.w_sub_offset[0] += (uint64_t)PB;
            break;
        case 3:  /* one scale base off by a single beat, on segment 1 only */
            if (s == 1) g.h.s_sub_offset[0] += (uint64_t)PB;
            break;
        case 4:  /* the segment reads one row too few */
            if (nr > 1) nr -= 1;
            break;
        case 5:  /* the segment runs into its own pad rows (n_rows + 16) */
            nr += 16; g.h.M = (uint32_t)nr;
            break;
        default: fprintf(stderr, "unknown mutant %d\n", mutate); return 1;
        }

        int32_t *y = malloc(4 * (size_t)nr);
        mv4i_result r = { y, NULL, NULL, 0, 0, 0, 0 };
        if (mv4i_matvec(&g, x, 0, nr, K, MV4I_MODE_RAW, &r)) {
            fprintf(stderr, "segment %d refused\n", s); return 2;
        }
        long long sbad = 0;
        for (int i = 0; i < nr; i++) {
            int lr = lstart + i;
            checked++;
            if (lr >= (int)fo.h.M || y[i] != full.y_data[lr]) {
                if (!bad) { first_bad_seg = s; first_bad_row = lr; }
                bad++; sbad++;
            }
        }
        printf("  seg %d  logical %5d..%5d -> packed %5d..%5d (%4d rows, "
               "tile %4d)  mismatches %lld\n",
               s, lstart, lstart + nr - 1, pstart, pstart + nr - 1, nr,
               skip_tiles, sbad);
        free(y);

        lstart += seg[s];
        pstart += seg[s];
        if (s != nseg - 1 && pstart % RI) pstart += RI - (pstart % RI);
    }

    /* ---- the ROW IDENTITY compare: every quantized nibble and every scale.
     * The two compares above go through the matvec, so they are sensitive to
     * the bases and to the arithmetic.  This one goes through `get_widx` /
     * `get_scale` directly and asks the different question: are the PACKED
     * BYTES of a real row the same in both files, and are the pad rows
     * actually empty?  A requantization that moved a single nibble but
     * happened not to change any dot product would pass the matvec compare and
     * fail here. */
    long long nib_bad = 0, scl_bad = 0, pad_bad = 0, pad_rows = 0;
    if (mutate == 0) {
        int lr = 0, pr = 0;
        for (int s = 0; s < nseg; s++) {
            for (int i = 0; i < seg[s]; i++) {
                for (int b = 0; b < NB; b++) {
                    if (get_scale(&fo, lr + i, b) != get_scale(&fn, pr + i, b))
                        scl_bad++;
                }
                for (int k = 0; k < K; k++) {
                    if (get_widx(&fo, lr + i, k) != get_widx(&fn, pr + i, k))
                        nib_bad++;
                }
            }
            lr += seg[s];
            pr += seg[s];
            int npr = pr;
            if (s != nseg - 1 && npr % RI) npr += RI - (npr % RI);
            for (int i = pr; i < npr; i++) {          /* the pad rows */
                pad_rows++;
                for (int b = 0; b < NB; b++)
                    if (get_scale(&fn, i, b) != 0) pad_bad++;
                for (int k = 0; k < K; k++)
                    if (get_widx(&fn, i, k) != 0) pad_bad++;
            }
            pr = npr;
        }
        printf("  rows     %d real rows compared nibble by nibble: "
               "%lld idx mismatches, %lld scale mismatches\n",
               logical, nib_bad, scl_bad);
        printf("  pad      %lld pad rows: %lld nonzero idx/scale entries\n",
               pad_rows, pad_bad);
    }

    /* ---- the BFP compare, on the one window both files can express */
    mv4i_result bo = { malloc(4 * (size_t)seg[0]), NULL,
                       malloc(2 * (size_t)seg[0]), 0, 0, 0, 0 };
    mv4i_result bn = { malloc(4 * (size_t)seg[0]), NULL,
                       malloc(2 * (size_t)seg[0]), 0, 0, 0, 0 };
    int bfp_bad = 0;
    if (mutate == 0) {
        mv4i_file go = fo, gn = fn;
        go.h.M = gn.h.M = (uint32_t)seg[0];
        if (mv4i_matvec(&go, x, 5, seg[0], K, MV4I_MODE_BFP, &bo)
            || mv4i_matvec(&gn, x, 5, seg[0], K, MV4I_MODE_BFP, &bn)) {
            fprintf(stderr, "BFP segment-0 job refused\n"); return 2;
        }
        for (int i = 0; i < seg[0]; i++)
            if (bo.y_mant[i] != bn.y_mant[i]) bfp_bad++;
        printf("  BFP seg 0  old ns=%d y_exp=%d  new ns=%d y_exp=%d  "
               "mantissa mismatches %d\n", bo.ns, bo.y_exp, bn.ns, bn.y_exp,
               bfp_bad);
        if (bo.y_exp != bn.y_exp) bfp_bad++;
    }

    printf("\nelements compared %lld of %u\n", checked, fo.h.M);
    if (checked != (long long)fo.h.M) {
        printf("FAIL the segments do not cover the unpadded tensor exactly\n");
        return 1;
    }
    if (bad || bfp_bad || nib_bad || scl_bad || pad_bad) {
        printf("FAIL %lld RAW mismatches (first segment %d logical row %d), "
               "%d BFP, %lld idx, %lld scale, %lld pad\n",
               bad, first_bad_seg, first_bad_row, bfp_bad,
               nib_bad, scl_bad, pad_bad);
        return 1;
    }
    printf("PASS every padded segment reproduces the unpadded rows bit for bit\n");
    return 0;
}
