/* ref/mv_fk33_tr.c -- trace generator for sim/tb_matvec_fk33.vhd.
 *
 * WHAT THIS IS FOR.  sim/tb_matvec_int4.vhd already drives subsystem A end to
 * end from packed bytes, but only at the AXU3EG geometry: AXI_DW is a constant
 * 128 in that file, NPORTS_W is ROWS_IF, and there is exactly one scale base.
 * The FK33 runs ROWS_IF=48 / AXI_DW=256, which is NPORTS_W=24 weight
 * sub-regions plus n_scale_sub=3 scale sub-regions -- 27 AXI read masters --
 * and NOTHING drove the RTL with data at that geometry.  Both prior debugging
 * notes say so in their own "open, not yet answered" sections:
 *
 *   docs/debugging/2026-08-28_c-reference-general-axi-dw.md
 *     "There is no DATA-level test of matvec_int4 at NPORTS_S = 3."
 *
 * This generator closes that by taking a REAL .mv4i file -- one of the 250
 * packed tensors of the 9B model, written by tools/pack_int4.py at 48/256 --
 * and emitting, for one matvec over it:
 *
 *   * the sub-region BYTES the RTL's 27 AXI masters will actually read, taken
 *     verbatim out of the file at the offsets its own 4 KB header names.  No
 *     re-derivation of the layout: a testbench that rebuilt the bytes from the
 *     6.5a rule would agree with a wrong rule just as happily.
 *   * the descriptor the PS would program (bases, beat counts, codebook,
 *     w_exp, out_shift), read out of the same header.
 *   * the activation vector, deterministic from an LCG so the trace is
 *     reproducible without shipping it.
 *   * the EXPECTED y mantissas, y_exp and sat_event, from mv4i_matvec() --
 *     which reaches those same bytes through get_widx()/get_scale(), a
 *     different code path from the raw sub-region dump above.  That is what
 *     makes this a double oracle rather than a round trip.
 *
 * WHY THE BYTES ARE DUMPED PER PORT AND NOT AS A FLAT IMAGE.  The FK33 tensors
 * start at 112 KB and the useful ones are megabytes; a flat address-indexed
 * memory in the testbench would be mostly padding.  Each AXI master reads one
 * contiguous sub-region, so one array per port is both smaller and a STRONGER
 * check: the testbench's slave can then assert that port p addressed its own
 * region at the expected beat, which a flat memory would silently serve.
 *
 * ROW SUBSETTING IS ALLOWED, COLUMN SUBSETTING IS NOT.  The beats of a
 * sub-region run tile-major then block, with the block stride fixed by the
 * FILE's nb = ceil(K/32).  Taking the first ceil(n_rows/ROWS_IF) tiles is
 * therefore a contiguous prefix of every sub-region and needs no gather, but
 * n_cols < K would change the stride and is refused below.
 *
 *   cc -O2 -Wall -Wextra -I ref -o mv_fk33_tr ref/mv_fk33_tr.c
 *   ./mv_fk33_tr OUT.txt FILE.mv4i [N_ROWS] [X_EXP] [SEED] [XAMP]
 *
 * No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose, because every
 * width bound of spec 7.4 is enforced by assert() alone.
 */

#define MV4I_LIB 1
#include "matvec_int4.c"

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

/* One beat of sub-region `off`, printed MSB byte first so the testbench's
 * hread() lands byte 0 of the beat in the LOW bits -- which is what 6.5a's
 * "row 0 at the LSB" means once the beat becomes a std_logic_vector. */
static void emit_beat(FILE *o, const uint8_t *base, uint64_t off,
                      int port, int beat, int port_b)
{
    const uint8_t *q = base + off + (size_t)beat * (size_t)port_b;
    int nz = 0;
    for (int i = 0; i < port_b; i++) if (q[i]) { nz = 1; break; }
    if (!nz) return;                    /* zero beats are the array default */
    fprintf(o, "IMG %d %d ", port, beat);
    for (int i = port_b - 1; i >= 0; i--) fprintf(o, "%02X", q[i]);
    fputc('\n', o);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
          "usage: %s OUT.txt FILE.mv4i [N_ROWS] [X_EXP] [SEED] [XAMP]\n",
          argv[0]);
        return 2;
    }
    const char *out_path = argv[1];
    const char *mv_path  = argv[2];
    int  want_rows = argc > 3 ? atoi(argv[3]) : 100;
    int  x_exp     = argc > 4 ? atoi(argv[4]) : 5;
    uint32_t seed  = argc > 5 ? (uint32_t)strtoul(argv[5], NULL, 0) : 20260828u;
    /* Activation amplitude.  The s28 partial bound of 7.4 is
     * BLOCK * max|cb| * max|x| = 32 * 127 * XAMP, so XAMP must stay under
     * 2^27/(32*127) = 33028.  8000 leaves the accumulator well clear of the
     * s32 requant clamp too, so a saturation here would mean a real defect
     * rather than a testbench that chose a hot vector. */
    int  xamp      = argc > 6 ? atoi(argv[6]) : 8000;

    size_t len = 0;
    uint8_t *img = slurp(mv_path, &len);
    if (!img) {
        fprintf(stderr, "%s: %s\n", mv_path, strerror(errno));
        return 3;
    }

    mv4i_file f;
    int prc = mv4i_parse(&f, img, len);
    if (prc) {
        fprintf(stderr, "%s: mv4i_parse rejected the file: %d\n", mv_path, prc);
        return 4;
    }

    const int RI  = f.h.rows_if;
    const int NPW = f.h.nports_w;
    const int NPS = (int)f.h.n_scale_sub;
    const int DW  = f.h.axi_dw;
    const int PB  = f.port_b;
    const int GRP = f.grp;
    const int NB  = f.nb;                       /* ceil(K / BLOCK), the FILE's */

    int n_cols = (int)f.h.K;                    /* NOT subsettable, see header */
    int n_rows = want_rows;
    if (n_rows <= 0 || n_rows > (int)f.h.M) n_rows = (int)f.h.M;

    const int tiles  = (n_rows + RI - 1) / RI;
    const int wbeats = tiles * NB;              /* beats per weight sub-region */
    const int groups = tiles * NB;
    const int sbeats = (groups + GRP - 1) / GRP;/* superwords = beats per sub  */

    int16_t *x = malloc(sizeof(int16_t) * (size_t)n_cols);
    uint32_t st = seed;
    for (int k = 0; k < n_cols; k++) {
        st = st * 1103515245u + 12345u;
        x[k] = (int16_t)((int32_t)((st >> 8) % (uint32_t)(2 * xamp + 1)) - xamp);
    }

    mv4i_result res;
    res.y_data = malloc(4 * (size_t)n_rows);
    res.y_acc  = malloc(8 * (size_t)n_rows);
    res.y_mant = malloc(2 * (size_t)n_rows);
    res.y_exp = 0; res.sat_event = 0; res.sat_count = 0; res.ns = 0;
    int rc = mv4i_matvec(&f, x, x_exp, n_rows, n_cols, MV4I_MODE_BFP, &res);
    if (rc) { fprintf(stderr, "mv4i_matvec failed: %d\n", rc); return 5; }

    FILE *o = fopen(out_path, "w");
    if (!o) { perror(out_path); return 2; }
    fprintf(o, "# GENERATED by ref/mv_fk33_tr -- DO NOT EDIT\n");
    fprintf(o, "# source %s (%zu bytes)\n", mv_path, len);
    fprintf(o, "GEOM %d %d %d %d %d %d\n", RI, NPW, NPS, DW, MV4I_BLOCK, GRP);
    fprintf(o, "DIMS %d %d %d %d %d %d\n",
            n_rows, n_cols, NB, f.h.out_shift, f.h.w_exp, x_exp);
    for (int i = 0; i < 16; i++) fprintf(o, "CB %d %d\n", i, f.h.codebook[i]);
    for (int k = 0; k < n_cols; k++)
        fprintf(o, "X %d %04X\n", k, (uint16_t)x[k]);
    for (int p = 0; p < NPW; p++)
        fprintf(o, "WSUB %d %llu\n", p,
                (unsigned long long)f.h.w_sub_offset[p]);
    for (int q = 0; q < NPS; q++)
        fprintf(o, "SSUB %d %llu\n", q,
                (unsigned long long)f.h.s_sub_offset[q]);
    fprintf(o, "WBEATS %d\n", wbeats);
    fprintf(o, "SBEATS %d\n", sbeats);

    /* The bytes themselves.  Ports 0..NPW-1 are the weight sub-regions, ports
     * NPW..NPW+NPS-1 the scale sub-regions -- the same flattened index order
     * matvec_int4's m_* vectors use. */
    for (int p = 0; p < NPW; p++) {
        if (f.h.w_sub_offset[p] + (size_t)wbeats * (size_t)PB > len) {
            fprintf(stderr, "weight sub-region %d runs past the file\n", p);
            return 6;
        }
        for (int t = 0; t < wbeats; t++)
            emit_beat(o, img, f.h.w_sub_offset[p], p, t, PB);
    }
    for (int q = 0; q < NPS; q++) {
        if (f.h.s_sub_offset[q] + (size_t)sbeats * (size_t)PB > len) {
            fprintf(stderr, "scale sub-region %d runs past the file\n", q);
            return 6;
        }
        for (int t = 0; t < sbeats; t++)
            emit_beat(o, img, f.h.s_sub_offset[q], NPW + q, t, PB);
    }

    fprintf(o, "YEXP %d\n", res.y_exp);
    for (int r = 0; r < n_rows; r++)
        fprintf(o, "YMANT %d %016llX\n", r,
                (unsigned long long)(int64_t)res.y_mant[r]);
    fprintf(o, "SATEV %d\n", res.sat_event ? 1 : 0);
    fprintf(o, "END\n");
    fclose(o);

    int64_t sum = 0;
    for (int r = 0; r < n_rows; r++) sum += res.y_mant[r];
    printf("wrote %s from %s: ROWS_IF=%d NPORTS_W=%d NPORTS_S=%d AXI_DW=%d "
           "GRP=%d n_rows=%d n_cols=%d tiles=%d wbeats=%d sbeats=%d "
           "y_exp=%d mant_sum=%lld sat=%d\n",
           out_path, mv_path, RI, NPW, NPS, DW, GRP, n_rows, n_cols,
           tiles, wbeats, sbeats, res.y_exp, (long long)sum, res.sat_event);
    return 0;
}
