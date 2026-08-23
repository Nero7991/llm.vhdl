/* hw/mv_driver.c -- board-side driver for subsystem A on the AXU3EG.
 *
 * Implements §10's bring-up steps 4 and 5 and reports §11's acceptance
 * numbers.  Runs on the board's own ARM cores with no host involved, and
 * compares the PL against ref/matvec_int4.c -- the SAME SOURCE, linked with
 * -DMV4I_LIB, not a reimplementation.  A second implementation of the contract
 * written for the comparison would be a second thing to get wrong.
 *
 *   mv_driver --mv4i FILE [--x FILE] [--phys ADDR] [--size BYTES] [--mode M]
 *
 * The weights must sit in physically contiguous DDR the PL can reach.  There is
 * no IOMMU in the path: the PL masters issue physical addresses straight at the
 * HP ports, so a malloc'd buffer is useless -- it is neither contiguous nor at
 * a known physical address.  Reserve a region and pass its base with --phys.
 * See hw/README.md for how.
 *
 * Register map: rtl/matvec_int4_axi.vhd.  The sequence below is the one
 * sim/tb_matvec_axi.vhd already executes in simulation.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MV4I_LIB
#include "../ref/matvec_int4.c"

#define CTRL_BASE   0x80000000UL
#define CTRL_SIZE   0x10000UL

enum {
    R_CTRL = 0, R_STATUS, R_NROWS, R_NCOLS, R_OUTSHIFT, R_WEXP, R_XEXP,
    R_MODE, R_WBASE0, R_WBASE1, R_WBASE2, R_WBASE3, R_WBEATS, R_SBASE,
    R_SBEATS, R_CB, R_XIDX, R_XDATA, R_YIDX, R_YLO, R_YHI, R_YEXP,
    R_CYCLES, R_BEATS, R_STARVED, R_ID
};

static volatile uint32_t *regs;

static inline void  wr(int r, uint32_t v) { regs[r] = v; }
static inline uint32_t rd(int r)          { return regs[r]; }

static void *map_phys(int fd, uint64_t base, size_t len, int prot)
{
    void *p = mmap(NULL, len, prot, MAP_SHARED, fd, (off_t)base);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    return p;
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)n);
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { perror("read"); exit(2); }
    fclose(f); *len = (size_t)n; return b;
}

int main(int argc, char **argv)
{
    const char *mv4i_path = NULL, *x_path = NULL;
    uint64_t phys = 0x50000000ULL;         /* see hw/README.md */
    /* --bw-stride: BANDWIDTH PROBE, results are deliberately garbage.
     *
     * The four weight sub-regions normally sit ~11 MB apart, so the DDR
     * controller sees four sequential read streams far enough apart to be in
     * different rows and bank groups the whole time. The AXU3EG measures 8.50
     * GB/s, 44% of the 19.2 GB/s peak, with the datapath starved 33.6% of
     * cycles -- and it is not obvious whether that is stream contention or a
     * per-port ceiling.
     *
     * This overrides W_BASE1..3 to sit `stride` bytes apart instead, so the
     * four streams walk through DRAM together in one small sliding window.
     * The data each port reads is then wrong and the result is meaningless, so
     * the comparison is skipped -- but BEATS and CYCLES are counted by the PL
     * regardless, and the beat count is identical either way, so the delivered
     * bandwidth is a valid measurement. Address separation is the only variable
     * that changes.
     *
     * Reads only. The PL masters are read-only and every access stays inside
     * the reserved region, so a wrong base cannot corrupt anything. */
    uint64_t bw_stride = 0;
    double   ddr_mts   = 2400.0;   /* DDR4-2400; see the peak note below */
    size_t   region = 256UL << 20;
    int      mode = MV4I_MODE_BFP;
    int      dry  = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mv4i") && i + 1 < argc) mv4i_path = argv[++i];
        else if (!strcmp(argv[i], "--x")    && i + 1 < argc) x_path = argv[++i];
        else if (!strcmp(argv[i], "--phys") && i + 1 < argc) phys = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) region = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dry-run")) dry = 1;
        else if (!strcmp(argv[i], "--bw-stride") && i + 1 < argc)
            bw_stride = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ddr-mts") && i + 1 < argc)
            ddr_mts = atof(argv[++i]);
        else { fprintf(stderr, "usage: %s --mv4i FILE [--x FILE] [--phys A] "
                               "[--size N] [--mode 0|1|2]\n", argv[0]); return 1; }
    }
    if (!mv4i_path) { fprintf(stderr, "--mv4i is required\n"); return 1; }

    size_t img_len; uint8_t *img = slurp(mv4i_path, &img_len);
    mv4i_file f;
    if (mv4i_parse(&f, img, img_len)) { fprintf(stderr, "bad .mv4i\n"); return 2; }
    int M = (int)f.h.M, K = (int)f.h.K;
    printf("matrix  M=%d K=%d  rows_if=%u nports=%u block=%u  w_exp=%d out_shift=%d\n",
           M, K, f.h.rows_if, f.h.nports_w, f.h.block, f.h.w_exp, f.h.out_shift);
    if (f.h.rows_if != 4 || f.h.nports_w != 4) {
        fprintf(stderr, "this bitstream is ROWS_IF=4 NPORTS_W=4 (spec 14.4); "
                        "the file is packed for %u/%u\n", f.h.rows_if, f.h.nports_w);
        return 2;
    }
    if (img_len > region) { fprintf(stderr, "image %zu > region %zu\n", img_len, region); return 2; }

    /* --dry-run computes every register value and prints it without touching
     * /dev/mem, so the descriptor arithmetic -- sub-region bases, beat counts --
     * can be checked against tools/pack_int4.py off the board.  Getting a beat
     * count wrong is a silent wrong answer, not a crash. */
    if (dry) {
        int nb    = (K + MV4I_BLOCK - 1) / MV4I_BLOCK;
        int tiles = (M + f.h.rows_if - 1) / f.h.rows_if;
        printf("DRY N_ROWS %d\nDRY N_COLS %d\nDRY OUT_SHIFT %d\nDRY W_EXP %d\n",
               M, K, f.h.out_shift, f.h.w_exp);
        for (int p = 0; p < 4; p++)
            printf("DRY W_BASE%d 0x%llX (offset %llu)\n", p,
                   (unsigned long long)(phys + f.h.w_sub_offset[p]),
                   (unsigned long long)f.h.w_sub_offset[p]);
        printf("DRY S_BASE 0x%llX (offset %llu)\n",
               (unsigned long long)(phys + f.h.s_sub_offset[0]),
               (unsigned long long)f.h.s_sub_offset[0]);
        printf("DRY W_BEATS %d\nDRY S_BEATS %d\n",
               tiles * nb, (tiles * nb * f.h.rows_if * 2 + 15) / 16);
        for (int i = 0; i < 16; i++) printf("DRY CB %d %d\n", i, f.h.codebook[i]);
        return 0;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 2; }
    regs = map_phys(fd, CTRL_BASE, CTRL_SIZE, PROT_READ | PROT_WRITE);

    uint32_t id = rd(R_ID);
    if (id != 0x4D563449u) {
        fprintf(stderr, "ID reads 0x%08X, expected 0x4D563449 -- wrong bitstream?\n", id);
        return 2;
    }
    printf("PL id    0x%08X  at 0x%08lX\n", id, CTRL_BASE);

    /* weights into the reserved region.  The PL sees physical addresses. */
    uint8_t *buf = map_phys(fd, phys, region, PROT_READ | PROT_WRITE);
    memcpy(buf, img, img_len);
    __builtin___clear_cache((char *)buf, (char *)buf + img_len);
    msync(buf, img_len, MS_SYNC);

    /* activations: from a file of int16, else a deterministic pattern */
    int16_t *x = calloc((size_t)K, sizeof(int16_t));
    if (x_path) {
        size_t xl; uint8_t *xb = slurp(x_path, &xl);
        if (xl < (size_t)K * 2) { fprintf(stderr, "x file too short\n"); return 2; }
        memcpy(x, xb, (size_t)K * 2);
    } else {
        uint32_t st = 12345;
        for (int k = 0; k < K; k++) { st = st * 1103515245u + 12345u;
            x[k] = (int16_t)((int32_t)((st >> 8) % 40001) - 20000); }
    }
    int x_exp = 0;

    /* ---- expected, from the reference, on this machine */
    mv4i_result ref = { malloc(4 * (size_t)M), malloc(8 * (size_t)M),
                        malloc(2 * (size_t)M), 0, 0, 0, 0 };
    if (mv4i_matvec(&f, x, x_exp, M, K, mode, &ref)) {
        fprintf(stderr, "reference rejected the descriptor\n"); return 2;
    }

    /* ---- program the PL, exactly as sim/tb_matvec_axi.vhd does */
    wr(R_NROWS, (uint32_t)M);  wr(R_NCOLS, (uint32_t)K);
    wr(R_OUTSHIFT, (uint32_t)f.h.out_shift);
    wr(R_WEXP, (uint32_t)f.h.w_exp);  wr(R_XEXP, (uint32_t)x_exp);
    wr(R_MODE, (uint32_t)mode);
    for (int p = 0; p < 4; p++) {
        uint64_t b = bw_stride ? (phys + f.h.w_sub_offset[0] + (uint64_t)p * bw_stride)
                               : (phys + f.h.w_sub_offset[p]);
        wr(R_WBASE0 + p, (uint32_t)b);
    }
    wr(R_SBASE, (uint32_t)(phys + f.h.s_sub_offset[0]));

    int nb    = (K + MV4I_BLOCK - 1) / MV4I_BLOCK;
    int tiles = (M + f.h.rows_if - 1) / f.h.rows_if;
    wr(R_WBEATS, (uint32_t)(tiles * nb));                    /* 16 B per beat */
    uint32_t sbeats = (uint32_t)((tiles * nb * f.h.rows_if * 2 + 15) / 16);
    wr(R_SBEATS, sbeats);

    for (int i = 0; i < 16; i++)
        wr(R_CB, ((uint32_t)i << 8) | (uint8_t)f.h.codebook[i]);

    wr(R_XIDX, 0);
    for (int k = 0; k < K; k++) wr(R_XDATA, (uint16_t)x[k]);  /* auto-increments */

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    wr(R_CTRL, 1);
    uint32_t st;
    do { st = rd(R_STATUS); } while (!(st & 1));
    clock_gettime(CLOCK_MONOTONIC, &t1);

    if (st & 4) { fprintf(stderr, "PL rejected the descriptor (err)\n"); return 2; }

    /* ---- compare (skipped under --bw-stride: the ports read the wrong bytes
     * by construction, so a mismatch there would mean nothing) */
    int bad = 0;
    if (bw_stride) {
        printf("BANDWIDTH PROBE: W_BASE spaced %llu B apart, result NOT checked\n",
               (unsigned long long)bw_stride);
        goto report;
    }
    for (int r = 0; r < M; r++) {
        wr(R_YIDX, (uint32_t)r);
        int64_t got;
        if (mode == MV4I_MODE_PARTIAL) {
            uint64_t lo = rd(R_YLO), hi = rd(R_YHI);
            got = (int64_t)((hi << 32) | lo);
        } else if (mode == MV4I_MODE_BFP) {
            got = (int16_t)(rd(R_YLO) & 0xFFFF);
        } else {
            got = (int32_t)rd(R_YLO);
        }
        int64_t want = (mode == MV4I_MODE_PARTIAL) ? ref.y_acc[r]
                     : (mode == MV4I_MODE_BFP)     ? ref.y_mant[r]
                                                   : ref.y_data[r];
        if (got != want) {
            if (bad < 8)
                printf("MISMATCH r=%d got %lld want %lld\n",
                       r, (long long)got, (long long)want);
            bad++;
        }
    }

report: ;
    int32_t y_exp_pl = (int32_t)rd(R_YEXP);
    uint32_t cycles = rd(R_CYCLES), beats = rd(R_BEATS), starved = rd(R_STARVED);

    /* §11: sustained bandwidth as a fraction of DDR peak.  Beats are counted in
     * the PL at the array's own clock, so this is what the datapath actually
     * consumed -- not a wall-clock figure that would fold in the AXI-Lite
     * activation load and the polling.
     *
     * THE PEAK IS 19.2 GB/s.  Read this before "correcting" it again.
     *
     * A previous version of this comment argued the peak was 9.6 GB/s, on the
     * grounds that PSU__DDR__INTERFACE__FREQMHZ is 600 and CRF_APB DDR_CTRL
     * (0xFD1A0080) reads 0x01000200 so DIVISOR0=2 against a 1200 MHz DPLL --
     * making the DRAM clock 600 MHz and the bus 1200 MT/s.  That reasoning is
     * WRONG: 600 MHz is the DDRC/PHY CORE clock, which on ZynqMP runs 2:1 to the
     * DRAM clock.  The DRAM clock is 1200 MHz and the bus is 2400 MT/s, which is
     * what PSU__DDRC__SPEED_BIN {DDR4_2400P} says it should be.
     *
     * MEASURED, because the clock tree was clearly not something to reason about
     * unaided.  Run the PL engine and four PS cores streaming DRAM at the same
     * instant (hw/membw.c):
     *
     *   PL engine            9.56 GB/s
     *   4 PS cores           7.50 GB/s   (7.96 with the PL idle)
     *   total               17.06 GB/s
     *
     * 17.06 cannot come out of a 9.6 GB/s memory system.  It is 89% of 19.2,
     * which is an ordinary DDR efficiency figure.
     *
     * So the engine at 9.56 GB/s is using about HALF the available bandwidth,
     * and the DDR has demonstrable headroom -- the PS pulls 7.5 GB/s more with
     * the engine at full tilt and slows it by 0.02%.  The 33.6% starvation is
     * therefore real and is NOT the memory: it is somewhere in the PL-to-DDR
     * path (the AFI, the FPD interconnect, or DDRC port arbitration).  Stream
     * separation, row geometry, and outstanding-request depth have each been
     * measured and ruled out; see docs/debugging/2026-08-23.
     *
     * Override with --ddr-mts only if the DDR is genuinely re-clocked. */
    double secs   = cycles / 200e6;
    double bytes  = (double)beats * 16.0 * 4.0;   /* 4 lanes per merged word */
    double gbs    = secs > 0 ? bytes / secs / 1e9 : 0.0;
    double peak   = ddr_mts * 8.0 / 1000.0;       /* 64-bit bus, MT/s -> GB/s */
    /* The scale stream has no beat counter in the PL -- only the weight lanes
     * do -- but it is a fixed, fully-determined count that the driver itself
     * programmed, and the port runs for the same span as the weight ports, so
     * this is exact rather than an estimate. */
    double sbytes = (double)sbeats * 16.0;
    double sgbs   = secs > 0 ? sbytes / secs / 1e9 : 0.0;
    double wall   = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    if (!bw_stride) {
        printf("\nresult   %s  (%d of %d rows differ)\n",
               bad ? "MISMATCH" : "bit-exact vs ref/matvec_int4.c", bad, M);
        printf("y_exp    PL %d   ref %d   %s\n", y_exp_pl, ref.y_exp,
               y_exp_pl == ref.y_exp ? "ok" : "DIFFER");
        printf("sat      %s\n", (st & 8) ? "SET (saturation occurred)" : "clear");
    } else {
        printf("\n(correctness intentionally not reported under --bw-stride)\n");
    }
    printf("cycles   %u   (%.3f ms at 200 MHz)\n", cycles, secs * 1e3);
    printf("beats    %u   starved %u  (%.1f%% of cycles)\n",
           beats, starved, cycles ? 100.0 * starved / cycles : 0.0);
    printf("weights  %.2f GB/s   scales %.2f GB/s   total %.2f GB/s\n",
           gbs, sgbs, gbs + sgbs);
    printf("memory   %.1f%% of this board's %.1f GB/s DDR peak (%.0f MT/s x 64 bit)\n",
           100.0 * (gbs + sgbs) / peak, peak, ddr_mts);
    printf("wall     %.3f ms (includes the AXI-Lite activation load and polling)\n",
           wall * 1e3);

    return bad ? 1 : 0;
}
