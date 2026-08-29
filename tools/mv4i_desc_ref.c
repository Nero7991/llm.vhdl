/* tools/mv4i_desc_ref.c -- the descriptor builder of
 * docs/2026-08-28_matvec-descriptor-format.md section 7, implemented as a
 * runnable program, so that tools/gen_mv4i_desc.py can be BYTE-COMPARED
 * against something that is not itself.
 *
 * WHY THIS EXISTS AND WHAT IT IS NOT.  A generator checked by its own decoder
 * proves nothing: this project has the m7 mutant on record, where a
 * self-consistent packer and a reversed decoder passed an entire self-test
 * suite.  So this file is written from the DOCUMENT's section 7 pseudo-code,
 * in a different language, and it reads the .mv4i header with
 * ref/matvec_int4.c's own parser -- a code path the Python shares nothing with.
 * It is not a second product; it is a second opinion.
 *
 * It deliberately does NOT re-derive the layout rules.  w_beats/s_beats and
 * the sub-region offsets come from mv4i_parse() plus the two lines of
 * arithmetic ref/mv_fk33_tr.c already uses, which is the point: if the Python
 * and this disagree, one of them is wrong about the FILE, not about the
 * document.
 *
 *   cc -O2 -Wall -Wextra -I ref -o mv4i_desc_ref tools/mv4i_desc_ref.c
 *   ./mv4i_desc_ref FILE.mv4i N_ROWS X_EXP HBM_BASE [OUT_MODE] [ROW_START]
 *
 * writes the descriptor image to stdout as one 64-bit word per line, hex,
 * exactly the form tools/gen_mv4i_desc.py --hex emits.
 *
 * No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose.
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

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s FILE.mv4i N_ROWS X_EXP HBM_BASE "
                        "[OUT_MODE] [ROW_START]\n", argv[0]);
        return 2;
    }
    const char *mv_path = argv[1];
    int      n_rows    = atoi(argv[2]);
    int      x_exp     = atoi(argv[3]);
    uint64_t hbm_base  = strtoull(argv[4], NULL, 0);
    int      out_mode  = argc > 5 ? atoi(argv[5]) : MV4I_MODE_BFP;
    int      row_start = argc > 6 ? atoi(argv[6]) : 0;

    size_t len = 0;
    uint8_t *img = slurp(mv_path, &len);
    if (!img) { fprintf(stderr, "%s: %s\n", mv_path, strerror(errno)); return 3; }

    mv4i_file f;
    int prc = mv4i_parse(&f, img, len);
    if (prc) { fprintf(stderr, "mv4i_parse rejected the file: %d\n", prc); return 4; }

    const int RI  = f.h.rows_if;
    const int NPW = f.h.nports_w;
    const int NPS = (int)f.h.n_scale_sub;
    const int PB  = f.port_b;
    const int GRP = f.grp;
    const int NB  = f.nb;

    if (n_rows <= 0 || n_rows > (int)f.h.M) n_rows = (int)f.h.M;

    /* The two identities.  Same arithmetic ref/mv_fk33_tr.c performs. */
    const int tiles  = (n_rows + RI - 1) / RI;
    const int wbeats = tiles * NB;
    const int sbeats = (wbeats + GRP - 1) / GRP;

    const int skip   = row_start / RI;
    const uint64_t w_skip = (uint64_t)skip * (uint64_t)NB * (uint64_t)PB;
    const uint64_t s_skip = (uint64_t)((skip * NB) / GRP) * (uint64_t)PB;

    const int E = 8 + NPW + NPS;
    const int NW = E + 4;
    uint64_t *d = calloc((size_t)NW, 8);

    /* ---- section 7, line for line ---------------------------------------- */
    d[0]  = 0;                                        /* opcode A_JOB         */
    d[0] |= (uint64_t)(1u << 2) << 8;                 /* flags bit2 = cb_load */
    d[0] |= (uint64_t)0xFF << 16;                     /* src_region  = none   */
    d[0] |= (uint64_t)0x00 << 24;                     /* dst_region  = 0      */
    d[1]  = (uint64_t)(uint32_t)n_rows
          | ((uint64_t)(uint32_t)f.h.K << 32);
    d[2]  = (uint32_t)f.h.w_exp
          | ((uint64_t)(uint32_t)f.h.out_shift << 32);
    d[3]  = (uint64_t)(uint32_t)out_mode
          | ((uint64_t)(uint32_t)NPW << 16)           /* nsub_w               */
          | ((uint64_t)(uint32_t)NPS << 32)           /* nsub_s               */
          | ((uint64_t)0xFF << 48);                   /* src_region2 = none   */
    d[4]  = 0;
    for (int j = 0; j < 8; j++) {
        d[5] |= (uint64_t)(uint8_t)f.h.codebook[j]     << (8 * j);
        d[6] |= (uint64_t)(uint8_t)f.h.codebook[j + 8] << (8 * j);
    }
    d[7]  = 0;
    for (int p = 0; p < NPW; p++)
        d[8 + p]       = hbm_base + f.h.w_sub_offset[p] + w_skip;
    for (int q = 0; q < NPS; q++)
        d[8 + NPW + q] = hbm_base + f.h.s_sub_offset[q] + s_skip;
    d[E + 0] = 0x4D563449ull | (1ull << 32);          /* magic, version 1     */
    d[E + 1] = (uint64_t)(uint32_t)wbeats
             | ((uint64_t)(uint32_t)sbeats << 32);
    d[E + 2] = (uint32_t)x_exp;
    d[E + 3] = 0;

    for (int i = 0; i < NW; i++)
        printf("%016llX\n", (unsigned long long)d[i]);
    free(d);
    free(img);
    return 0;
}
