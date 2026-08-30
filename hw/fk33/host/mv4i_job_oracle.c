/* mv4i_job_oracle.c -- run a BATCH of subsystem-A row-window jobs through
 * ref/matvec_int4.c on real packed .mv4i tensors, from activation vectors
 * supplied on disk.
 *
 * TRACK LAYERRUN.  Written for hw/fk33/host/fk33_run_layer.py.
 *
 * WHAT IT IS FOR, AND WHAT IT IS NOT
 * ----------------------------------
 * fk33_run_layer.py drives one transformer layer's subsystem-A matvecs through
 * the card in program order.  Its per-job expectations come from the whole-model
 * reference stream `ref/run9b --acts bfp` writes (`tools/ref9b/seam_stream.h`),
 * and the mapping from a step to the two seams it reads and writes is written in
 * fk33_run_layer.py by hand.
 *
 * THAT MAPPING IS THE THING THIS FILE CHECKS, AND IT IS NOT AN INDEPENDENT
 * ORACLE FOR THE ARITHMETIC.  It calls `mv4i_matvec`, which is the same
 * function `ref/run9b.c`'s `a_job` calls, so agreement between this and the
 * reference stream says NOTHING new about the matvec.  What it does say, with
 * no hardware in the room, is that
 *
 *     the vector fk33_run_layer.py pulled out of seam S, at the exponent it
 *     read from S, applied to rows [row0, row0+n) of tensor T,
 *     reproduces seam D
 *
 * -- i.e. that the step-to-seam mapping, the row window, the segment lookup and
 * the exponent plumbing are right.  If the card then disagrees with seam D, the
 * disagreement is the card's, because this has already excluded the host.
 * A run against the card without this check cannot separate the two.
 *
 * THE WINDOW-AND-SCAN IS COPIED FROM `ref/run9b.c`'s `a_job`, DELIBERATELY.
 * `mv4i_matvec` has no row window, so a windowed job runs in RAW mode over
 * rows [0, row0+n) and the BFP scan is then done over the window alone.  That
 * is six lines and they are the reference's own; copying them makes this a
 * transcription that the whole-layer check below can falsify, rather than a
 * design this file invents.  The 6.5a bit layout -- the part a second
 * implementation could get wrong while agreeing with itself -- is read only by
 * matvec_int4.c's own get_widx()/get_scale().
 *
 * NOTE THE CARD DOES IT DIFFERENTLY, AND THAT IS THE POINT OF RUNNING IT.
 * The card expresses the window by advancing every weight and scale base by
 * whole TILES (tools/gen_mv4i_desc.py's `row_start`) and computes n rows in BFP
 * mode.  This host path computes row0+n rows in RAW mode and slices.  The two
 * agree only if the sub-region layout really is tile-major, which is an
 * assumption the card run tests and this file does not.
 *
 * Build:
 *   cc -O2 -w -I ref -o OUT hw/fk33/host/mv4i_job_oracle.c -lm
 * (No -DNDEBUG: ref/matvec_int4.c #errors under it on purpose, because every
 * width bound of spec 7.4 is enforced by assert() alone.)
 *
 * Usage:
 *   mv4i_job_oracle <jobspec>
 *
 * The jobspec is line oriented.  Blank lines and lines starting '#' are
 * ignored.  Order matters only in that a FILE must precede the JOBs using it.
 *
 *   FILE <id> <path.mv4i>
 *   JOB  <name> <fileid> <row0> <nrows> <x_exp> <xpath.i16> <ypath.i16>
 *
 * <xpath.i16> holds K little-endian int16 mantissas; the job refuses unless the
 * file is exactly 2*K bytes, because a short x would silently compute against
 * whatever followed it in memory.  <ypath.i16> is written with nrows
 * little-endian int16 mantissas.
 *
 * One line per job on stdout:
 *   Y <name> <y_exp> <ns> <nrows> <sat_event> <w_exp> <out_shift> <M> <K>
 * and on any refusal:
 *   BAD <name> <reason with no spaces>
 * with a nonzero exit status, so a caller cannot mistake a skipped job for a
 * clean one.
 */

#define MV4I_LIB 1
#include "../../../ref/matvec_int4.c"

#include <errno.h>

#define MAXFILE 32

typedef struct {
    char      path[512];
    uint8_t  *img;
    size_t    len;
    mv4i_file f;
    int       loaded;
} slot_t;

static slot_t g_slot[MAXFILE];

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
    if (argc != 2) {
        fprintf(stderr, "usage: %s <jobspec>\n", argv[0]);
        return 2;
    }
    FILE *spec = fopen(argv[1], "r");
    if (!spec) { perror(argv[1]); return 2; }

    char line[2048];
    int  nbad = 0, njob = 0;
    int32_t *ybuf = NULL; long ybuf_n = 0;
    int16_t *xbuf = NULL; long xbuf_n = 0;
    int16_t *mbuf = NULL; long mbuf_n = 0;

    while (fgets(line, sizeof line, spec)) {
        char tag[32];
        if (sscanf(line, "%31s", tag) != 1) continue;
        if (tag[0] == '#') continue;

        if (!strcmp(tag, "FILE")) {
            int id; char path[512];
            if (sscanf(line, "%*s %d %511s", &id, path) != 2 ||
                id < 0 || id >= MAXFILE) {
                fprintf(stderr, "bad FILE line: %s", line); return 2;
            }
            if (g_slot[id].loaded) { fprintf(stderr, "FILE %d twice\n", id); return 2; }
            size_t len = 0;
            uint8_t *img = slurp(path, &len);
            if (!img) { fprintf(stderr, "%s: %s\n", path, strerror(errno)); return 3; }
            int prc = mv4i_parse(&g_slot[id].f, img, len);
            if (prc) {
                fprintf(stderr, "%s: mv4i_parse refused it: %d\n", path, prc);
                return 4;
            }
            g_slot[id].img = img; g_slot[id].len = len; g_slot[id].loaded = 1;
            snprintf(g_slot[id].path, sizeof g_slot[id].path, "%s", path);
            continue;
        }

        if (strcmp(tag, "JOB")) { fprintf(stderr, "unknown tag %s\n", tag); return 2; }

        char name[128], xp[512], yp[512];
        int fid, row0, nrows, x_exp;
        if (sscanf(line, "%*s %127s %d %d %d %d %511s %511s",
                   name, &fid, &row0, &nrows, &x_exp, xp, yp) != 7) {
            fprintf(stderr, "bad JOB line: %s", line); return 2;
        }
        njob++;
        if (fid < 0 || fid >= MAXFILE || !g_slot[fid].loaded) {
            printf("BAD %s no-such-FILE-id\n", name); nbad++; continue;
        }
        mv4i_file *f = &g_slot[fid].f;
        int K = (int)f->h.K, M = (int)f->h.M;
        if (row0 < 0 || nrows <= 0 || row0 + nrows > M) {
            printf("BAD %s window-%d..%d-past-M-%d\n", name, row0,
                   row0 + nrows - 1, M);
            nbad++; continue;
        }

        /* x: exactly 2*K bytes.  A short file would leave the tail of the
         * vector at whatever the allocator last held, which computes a
         * plausible wrong answer with no error anywhere. */
        FILE *xf = fopen(xp, "rb");
        if (!xf) { printf("BAD %s cannot-open-x\n", name); nbad++; continue; }
        if (fseek(xf, 0, SEEK_END)) { fclose(xf); printf("BAD %s x-seek\n", name); nbad++; continue; }
        long xlen = ftell(xf); rewind(xf);
        if (xlen != (long)K * 2) {
            printf("BAD %s x-is-%ld-bytes-want-%ld\n", name, xlen, (long)K * 2);
            fclose(xf); nbad++; continue;
        }
        if (xbuf_n < K) { xbuf = realloc(xbuf, sizeof(int16_t) * (size_t)K); xbuf_n = K; }
        if (fread(xbuf, 1, (size_t)xlen, xf) != (size_t)xlen) {
            printf("BAD %s x-short-read\n", name); fclose(xf); nbad++; continue;
        }
        fclose(xf);

        long need = (long)row0 + nrows;
        if (ybuf_n < need) { ybuf = realloc(ybuf, sizeof(int32_t) * (size_t)need); ybuf_n = need; }
        if (mbuf_n < nrows) { mbuf = realloc(mbuf, sizeof(int16_t) * (size_t)nrows); mbuf_n = nrows; }

        mv4i_result res;
        res.y_data = ybuf; res.y_mant = NULL; res.y_acc = NULL;
        res.y_exp = 0; res.sat_event = 0; res.sat_count = 0; res.ns = 0;
        int rc = mv4i_matvec(f, xbuf, x_exp, (int)need, K, MV4I_MODE_RAW, &res);
        if (rc) { printf("BAD %s mv4i_matvec-rc-%d\n", name, rc); nbad++; continue; }

        /* ref/run9b.c a_job, verbatim: scan the WINDOW only. */
        uint64_t amax = 0;
        for (int r = 0; r < nrows; r++) {
            int64_t a = ybuf[row0 + r]; if (a < 0) a = -a;
            if ((uint64_t)a > amax) amax = (uint64_t)a;
        }
        int ns = mv4i_msb_pos_u(amax) - 14; if (ns < 0) ns = 0;
        for (int r = 0; r < nrows; r++)
            mbuf[r] = mv4i_sat16(mv4i_round_shift((int64_t)ybuf[row0 + r], ns));
        int y_exp = (int)f->h.w_exp + x_exp - (int)f->h.out_shift - ns;

        FILE *yf = fopen(yp, "wb");
        if (!yf) { printf("BAD %s cannot-write-y\n", name); nbad++; continue; }
        if (fwrite(mbuf, sizeof(int16_t), (size_t)nrows, yf) != (size_t)nrows) {
            printf("BAD %s y-short-write\n", name); fclose(yf); nbad++; continue;
        }
        fclose(yf);

        printf("Y %s %d %d %d %d %d %d %d %d\n", name, y_exp, ns, nrows,
               res.sat_event ? 1 : 0, (int)f->h.w_exp, (int)f->h.out_shift,
               M, K);
        fflush(stdout);
    }
    fclose(spec);
    fprintf(stderr, "mv4i_job_oracle: %d jobs, %d refused\n", njob, nbad);
    return nbad ? 1 : 0;
}
