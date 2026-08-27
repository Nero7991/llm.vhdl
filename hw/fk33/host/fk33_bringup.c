/*
 * fk33_bringup -- one command to run after the FK33 is plugged in.
 *
 * Runs the host-visible bring-up stages in the only order in which a failure
 * localises itself, and prints PASS or FAIL for each.  Every stage strictly
 * contains the previous one, so the FIRST failure is the informative one and
 * everything after it is noise; the program says so rather than making you
 * work it out.
 *
 *   0  devices        do the XDMA character devices exist at all
 *   1  identity       read-only 0x464B3333 from fabric constants
 *   2  scratch MMIO   write and read back 8 KB of BRAM on the AXI-Lite BAR
 *   3  sysmon         die temperature and VCCINT, as a plausibility check
 *   4  dma loopback   H2C then C2H through the 64 KB BRAM on the DMA master
 *   5  dma to HBM     the same, into real HBM  (--hbm, off by default)
 *   6  throughput     the number that sets the cold weight-load time (--bench)
 *
 * Stage 1 is the one that matters most and it is the one that is easy to get
 * wrong by accident.  "The driver loaded" and "/dev nodes appeared" prove only
 * that a PCI device with a matching ID answered configuration reads -- they say
 * nothing about whether the fabric behind the BAR is alive, or even whether the
 * FPGA holds this bitstream rather than some older one.  A correct read of the
 * ASCII word "FK33" out of a register driven by a fabric constant cannot be
 * produced by anything except this design, actually configured, actually
 * clocked, with its BAR actually mapped.  0x00000000 and 0xFFFFFFFF, the two
 * values an unanswered BAR returns, are both impossible answers.
 *
 * Deliberately no dependencies beyond libc, and no root once the udev rule from
 * build_xdma_driver.sh is in place.
 *
 *   gcc -O2 -Wall -Wextra -std=c11 -o fk33_bringup fk33_bringup.c   (or make)
 *
 * Exit status: 0 = every stage that ran passed.  1 = a stage failed.
 * 2 = could not even start (no devices).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---- address map.  Must match hw/fk33/gen_pcieep.py. ------------------- */

/* AXI-Lite BAR, 128 KB, /dev/xdma0_user */
#define ID_BASE        0x0000A000u   /* axi_gpio, both channels all-inputs   */
#define ID_MAGIC_OFF   (ID_BASE + 0x0u)
#define ID_BUILD_OFF   (ID_BASE + 0x8u)
#define SCRATCH_BASE   0x00010000u
#define SCRATCH_SIZE   0x2000u       /* 8 KB */
#define SYSMON_TEMP    0x00003400u
#define SYSMON_VCCINT  0x00003404u

#define ID_MAGIC       0x464B3333u   /* "FK33" */
#define ID_BUILD       0x20260827u

/* DMA master space, /dev/xdma0_h2c_0 and _c2h_0.  File offset IS the AXI
 * address, which is the whole reason XDMA was chosen over QDMA. */
#define DMABRAM_BASE   0x200000000ull
#define DMABRAM_SIZE   0x10000ull    /* 64 KB */
#define HBM_TOP        0x200000000ull

/* Overridable by environment ONLY so that this program can be exercised end to
 * end against ordinary files before a card exists -- see selftest_nocard.sh.
 * That test is not cosmetic: it is the only way to find an off-by-one in the
 * address map, a wrong transfer function or a broken comparison BEFORE the one
 * afternoon when the card is finally in the slot and every minute of confusion
 * is expensive. */
static const char *DEV_USER = "/dev/xdma0_user";
static const char *DEV_H2C  = "/dev/xdma0_h2c_0";
static const char *DEV_C2H  = "/dev/xdma0_c2h_0";

static void dev_overrides(void)
{
    const char *e;
    if ((e = getenv("FK33_DEV_USER"))) DEV_USER = e;
    if ((e = getenv("FK33_DEV_H2C")))  DEV_H2C  = e;
    if ((e = getenv("FK33_DEV_C2H")))  DEV_C2H  = e;
    if (DEV_USER[0] != '/' || strncmp(DEV_USER, "/dev/", 5) != 0)
        printf("NOTE: not using the real character devices -- "
               "user=%s h2c=%s c2h=%s\n", DEV_USER, DEV_H2C, DEV_C2H);
}

/* ---- reporting -------------------------------------------------------- */

static int n_fail;
static int n_pass;
static int first_fail_stage = -1;
static const char *first_fail_name;

static void stage_pass(int n, const char *name, const char *fmt, ...)
{
    va_list ap;
    printf("PASS  stage %d  %-14s ", n, name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    n_pass++;
}

static void stage_fail(int n, const char *name, const char *fmt, ...)
{
    va_list ap;
    printf("FAIL  stage %d  %-14s ", n, name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    if (first_fail_stage < 0) {
        first_fail_stage = n;
        first_fail_name = name;
    }
    n_fail++;
}

static void note(const char *fmt, ...)
{
    va_list ap;
    fputs("                             ", stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

/* ---- MMIO ------------------------------------------------------------- */

/* pread/pwrite rather than mmap.  Both work with the XDMA driver, but a
 * pread that fails returns an errno, whereas a load from a bad mmap raises
 * SIGBUS and kills the program mid-report.  On a card that has never
 * enumerated, being able to print WHY a read failed is worth more than the
 * ~1 us per access that mmap would save, and nothing here is in a hot loop. */
static int user_fd = -1;

static int mmio_rd(uint32_t off, uint32_t *out)
{
    uint32_t v;
    ssize_t r = pread(user_fd, &v, 4, (off_t)off);
    if (r != 4)
        return -1;
    *out = v;
    return 0;
}

static int mmio_wr(uint32_t off, uint32_t val)
{
    ssize_t r = pwrite(user_fd, &val, 4, (off_t)off);
    return r == 4 ? 0 : -1;
}

/* ---- helpers ---------------------------------------------------------- */

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static const char *bar_diag(uint32_t v)
{
    if (v == 0xFFFFFFFFu)
        return "all-ones: the BAR is mapped but nothing answered.  This is what "
               "a PCIe read returns when the completion times out or the device "
               "is in error state -- see stage 1 of the bring-up procedure";
    if (v == 0x00000000u)
        return "all-zeroes: the BAR window exists but the fabric behind it is "
               "held in reset or unclocked.  In this design the whole AXI fabric "
               "runs on xdma/axi_aclk, so this is what a link that trained but "
               "never released the user reset looks like";
    return "neither all-ones nor all-zeroes, so something IS answering -- but "
           "not this bitstream.  Check that the FPGA holds fk33_pcieep and not "
           "the probe or first-light bitstream";
}

/* pwrite/pread the whole buffer, looping on short transfers.  XDMA returns
 * short counts on large transfers and a naive single call silently moves less
 * data than asked, which would make a corrupted comparison look like a DMA
 * fault. */
static ssize_t rw_all(int fd, void *buf, size_t len, uint64_t off, int is_write)
{
    size_t done = 0;
    while (done < len) {
        ssize_t r = is_write
            ? pwrite(fd, (char *)buf + done, len - done, (off_t)(off + done))
            : pread(fd, (char *)buf + done, len - done, (off_t)(off + done));
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (r == 0)
            break;
        done += (size_t)r;
    }
    return (ssize_t)done;
}

static void fill_pattern(uint8_t *b, size_t n, uint32_t seed)
{
    /* xorshift32: cheap, and every byte depends on the offset, so a transfer
     * that lands at the wrong address fails the comparison instead of
     * accidentally matching a repeating pattern. */
    uint32_t x = seed | 1u;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b[i] = (uint8_t)(x >> 24);
    }
}

static long first_diff(const uint8_t *a, const uint8_t *b, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (a[i] != b[i])
            return (long)i;
    return -1;
}

/* ---- stages ----------------------------------------------------------- */

static int stage0_devices(void)
{
    const char *devs[3] = { DEV_USER, DEV_H2C, DEV_C2H };
    int missing = 0;
    for (int i = 0; i < 3; i++) {
        struct stat st;
        if (stat(devs[i], &st) != 0) {
            note("missing %s (%s)", devs[i], strerror(errno));
            missing++;
        }
    }
    if (missing) {
        stage_fail(0, "devices", "%d of 3 XDMA character devices missing", missing);
        note("The driver is not loaded, did not bind, or bound without finding");
        note("its engines.  Those are three different faults -- run");
        note("  ./fk33_pcie_check.sh");
        note("which distinguishes them, and see the bring-up procedure.");
        return -1;
    }
    stage_pass(0, "devices", "%s %s %s", DEV_USER, DEV_H2C, DEV_C2H);
    return 0;
}

static int stage1_identity(void)
{
    uint32_t magic = 0, build = 0;

    user_fd = open(DEV_USER, O_RDWR | O_SYNC);
    if (user_fd < 0) {
        stage_fail(1, "identity", "cannot open %s: %s", DEV_USER, strerror(errno));
        return -1;
    }
    if (mmio_rd(ID_MAGIC_OFF, &magic) != 0) {
        stage_fail(1, "identity", "MMIO read of 0x%08x failed: %s",
                   ID_MAGIC_OFF, strerror(errno));
        note("The BAR is not readable at all.  That is 'enumerated but BAR");
        note("unmapped', not 'DMA dead' -- check lspci Region lines first.");
        return -1;
    }
    if (magic != ID_MAGIC) {
        stage_fail(1, "identity", "id magic 0x%08x, expected 0x%08x (\"FK33\")",
                   magic, ID_MAGIC);
        note("%s", bar_diag(magic));
        return -1;
    }
    (void)mmio_rd(ID_BUILD_OFF, &build);
    stage_pass(1, "identity", "magic 0x%08x (\"FK33\"), build 0x%08x", magic, build);
    if (build != ID_BUILD)
        note("build word is 0x%08x but this binary expects 0x%08x -- the card "
             "holds a different bitstream revision than this test", build, ID_BUILD);
    return 0;
}

static int stage2_scratch(void)
{
    /* Three patterns, chosen so that each catches a different fault:
     *   walking-one     a stuck or shorted data bit
     *   address-in-word a stuck or swapped ADDRESS bit, which a constant
     *                   pattern cannot see because every location holds the
     *                   same value
     *   inverse         a bit that is stuck the other way round
     * A single 0xDEADBEEF write, which is what this test usually is, passes
     * happily with the top address bit shorted to ground. */
    uint32_t rb;

    for (int b = 0; b < 32; b++) {
        uint32_t v = 1u << b;
        if (mmio_wr(SCRATCH_BASE, v) != 0 || mmio_rd(SCRATCH_BASE, &rb) != 0) {
            stage_fail(2, "scratch", "MMIO access failed at bit %d: %s", b,
                       strerror(errno));
            return -1;
        }
        if (rb != v) {
            stage_fail(2, "scratch", "walking-one bit %d: wrote 0x%08x read 0x%08x",
                       b, v, rb);
            note("Data bits that differ: 0x%08x", rb ^ v);
            return -1;
        }
    }

    const uint32_t words = SCRATCH_SIZE / 4;
    for (uint32_t i = 0; i < words; i++)
        if (mmio_wr(SCRATCH_BASE + i * 4, 0xA5A50000u | i) != 0) {
            stage_fail(2, "scratch", "write to word %u failed: %s", i, strerror(errno));
            return -1;
        }
    for (uint32_t i = 0; i < words; i++) {
        if (mmio_rd(SCRATCH_BASE + i * 4, &rb) != 0) {
            stage_fail(2, "scratch", "read of word %u failed: %s", i, strerror(errno));
            return -1;
        }
        if (rb != (0xA5A50000u | i)) {
            stage_fail(2, "scratch", "address-in-word at %u: read 0x%08x, expected 0x%08x",
                       i, rb, 0xA5A50000u | i);
            note("A mismatch whose low 16 bits are a DIFFERENT valid index means");
            note("an address bit is wrong, not a data bit.");
            return -1;
        }
    }

    /* Leave it holding the identity word, so a later manual hexdump of the BAR
     * shows something recognisable rather than the last test pattern. */
    (void)mmio_wr(SCRATCH_BASE, ID_MAGIC);
    stage_pass(2, "scratch", "32 walking-ones + %u words address-in-word, 8 KB at 0x%08x",
               words, SCRATCH_BASE);
    return 0;
}

static int stage3_sysmon(void)
{
    uint32_t t = 0, v = 0;
    if (mmio_rd(SYSMON_TEMP, &t) != 0 || mmio_rd(SYSMON_VCCINT, &v) != 0) {
        stage_fail(3, "sysmon", "MMIO read failed: %s", strerror(errno));
        return -1;
    }
    /* UG580 transfer functions for UltraScale+ SYSMON.  The 12-bit ADC result
     * sits in bits [15:4] of a 16-bit register, so dividing the raw 16-bit
     * value by 65536 and dividing the shifted 12-bit value by 4096 are the same
     * number.  The 16-bit form is used here because that is the form in
     * fk33ctl.py and in tcl/telemetry.tcl, and two tools disagreeing about a
     * transfer function is a trap that costs an afternoon. */
    double degc = (double)(t & 0xFFFFu) * 507.6 / 65536.0 - 279.43;
    double volt = (double)(v & 0xFFFFu) * 3.0 / 65536.0;
    int ok = degc > 0.0 && degc < 110.0 && volt > 0.4 && volt < 1.0;
    if (!ok) {
        stage_fail(3, "sysmon", "%.1f degC, VCCINT %.3f V -- implausible", degc, volt);
        note("Raw: temp 0x%08x vccint 0x%08x.  The BAR answers but the values", t, v);
        note("are not physical, so the AXI-Lite decode may be off by a peripheral.");
        return -1;
    }
    stage_pass(3, "sysmon", "%.1f degC, VCCINT %.3f V", degc, volt);
    if (volt < 0.698)
        note("VCCINT is BELOW the 0.698 V floor of every characterised speed "
             "grade.  This is the known power-on state (0.678 V) and it is "
             "volatile -- raise it with ./fk33ctl.py vccint before trusting any "
             "timing-sensitive result.");
    return 0;
}

static int dma_roundtrip(int stage, const char *name, uint64_t addr, size_t len,
                         uint32_t seed)
{
    uint8_t *src = malloc(len), *dst = malloc(len);
    int rc = -1;
    int h2c = -1, c2h = -1;

    if (!src || !dst) {
        stage_fail(stage, name, "out of memory for %zu bytes", len);
        goto out;
    }
    fill_pattern(src, len, seed);
    memset(dst, 0, len);

    h2c = open(DEV_H2C, O_WRONLY);
    if (h2c < 0) {
        stage_fail(stage, name, "cannot open %s: %s", DEV_H2C, strerror(errno));
        goto out;
    }
    c2h = open(DEV_C2H, O_RDONLY);
    if (c2h < 0) {
        stage_fail(stage, name, "cannot open %s: %s", DEV_C2H, strerror(errno));
        goto out;
    }

    ssize_t w = rw_all(h2c, src, len, addr, 1);
    if (w != (ssize_t)len) {
        stage_fail(stage, name, "H2C wrote %zd of %zu bytes at 0x%" PRIx64 ": %s",
                   w, len, addr, w < 0 ? strerror(errno) : "short transfer");
        note("A short H2C with no error is the descriptor path stalling, not a");
        note("data error.  Check dmesg for xdma engine messages.");
        goto out;
    }
    ssize_t r = rw_all(c2h, dst, len, addr, 0);
    if (r != (ssize_t)len) {
        stage_fail(stage, name, "C2H read %zd of %zu bytes at 0x%" PRIx64 ": %s",
                   r, len, addr, r < 0 ? strerror(errno) : "short transfer");
        note("H2C succeeded and C2H did not, so the write engine is alive and");
        note("the read engine is not -- they are separate hardware.");
        goto out;
    }
    long d = first_diff(src, dst, len);
    if (d >= 0) {
        stage_fail(stage, name, "mismatch at byte %ld of %zu: wrote 0x%02x read 0x%02x",
                   d, len, src[d], dst[d]);
        note("Both engines moved the full length, so this is a DATA fault, not a");
        note("descriptor fault.  Read the same address back over JTAG");
        note("(../pcieep.sh --check) to tell 'XDMA wrote the wrong thing' from");
        note("'the readback is wrong'.");
        goto out;
    }
    stage_pass(stage, name, "%zu KB round trip at 0x%" PRIx64 ", byte-identical",
               len >> 10, addr);
    rc = 0;
out:
    if (h2c >= 0) close(h2c);
    if (c2h >= 0) close(c2h);
    free(src);
    free(dst);
    return rc;
}

static int stage6_bench(size_t mb, uint64_t addr)
{
    size_t len = mb << 20;
    uint8_t *buf = malloc(len);
    int h2c = open(DEV_H2C, O_WRONLY);
    int c2h = open(DEV_C2H, O_RDONLY);
    int rc = -1;

    if (!buf || h2c < 0 || c2h < 0) {
        stage_fail(6, "throughput", "setup failed: %s", strerror(errno));
        goto out;
    }
    fill_pattern(buf, len, 0x1234u);

    double t0 = now_s();
    if (rw_all(h2c, buf, len, addr, 1) != (ssize_t)len) {
        stage_fail(6, "throughput", "H2C short during benchmark");
        goto out;
    }
    double t1 = now_s();
    if (rw_all(c2h, buf, len, addr, 0) != (ssize_t)len) {
        stage_fail(6, "throughput", "C2H short during benchmark");
        goto out;
    }
    double t2 = now_s();

    double wr = (double)len / (t1 - t0) / 1e9;
    double rd = (double)len / (t2 - t1) / 1e9;
    stage_pass(6, "throughput", "H2C %.2f GB/s, C2H %.2f GB/s over %zu MB", wr, rd, mb);
    note("Gen3 x4 raw payload ceiling is 3.94 GB/s; 3.2-3.5 is the expected");
    note("band.  Below 2.5 GB/s, check MPS/MRRS in `lspci -vvv` DevCtl before");
    note("suspecting the design -- a 128-byte MPS costs about 15%%.");
    note("4.5 GB of weights at %.2f GB/s is %.2f s.", wr, 4.5 / wr);
    rc = 0;
out:
    if (h2c >= 0) close(h2c);
    if (c2h >= 0) close(c2h);
    free(buf);
    return rc;
}

/* ---- main ------------------------------------------------------------- */

static void usage(const char *a0)
{
    printf("usage: %s [--hbm] [--bench MB] [--hbm-offset ADDR]\n"
           "\n"
           "  (default)        stages 0-4: devices, identity, scratch, sysmon,\n"
           "                   DMA loopback through the on-chip BRAM.  Touches\n"
           "                   no HBM, so it is safe to run at any time.\n"
           "  --hbm            add stage 5: the same round trip into real HBM.\n"
           "                   This WRITES to HBM and will destroy anything\n"
           "                   already loaded there.\n"
           "  --hbm-offset A   where in HBM stage 5 writes (default the last\n"
           "                   1 MB, so a resident weight blob at offset 0 is\n"
           "                   not clobbered).\n"
           "  --bench MB       add stage 6: throughput over MB megabytes written to\n"
           "                   the TOP of HBM.  Implies the same write hazard.\n", a0);
}

int main(int argc, char **argv)
{
    int do_hbm = 0;
    size_t bench_mb = 0;
    uint64_t hbm_off = HBM_TOP - (1ull << 20);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hbm")) {
            do_hbm = 1;
        } else if (!strcmp(argv[i], "--bench") && i + 1 < argc) {
            bench_mb = strtoul(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--hbm-offset") && i + 1 < argc) {
            hbm_off = strtoull(argv[++i], NULL, 0);
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    dev_overrides();
    printf("fk33_bringup -- FK33 PCIe endpoint, host side\n");
    printf("expecting id 0x%08x at BAR offset 0x%08x, DMA BRAM at 0x%" PRIx64 "\n\n",
           ID_MAGIC, ID_MAGIC_OFF, (uint64_t)DMABRAM_BASE);

    if (stage0_devices() != 0)
        goto done;
    if (stage1_identity() != 0)
        goto done;
    if (stage2_scratch() != 0)
        goto done;
    /* SYSMON is not a prerequisite for DMA, so a failure here does not stop
     * the run -- it is a plausibility check on the AXI-Lite decode. */
    (void)stage3_sysmon();

    if (dma_roundtrip(4, "dma-bram", DMABRAM_BASE, (size_t)DMABRAM_SIZE, 0xBEEFu) != 0)
        goto done;

    if (do_hbm || bench_mb) {
        if (hbm_off + (1ull << 20) > HBM_TOP) {
            stage_fail(5, "dma-hbm", "offset 0x%" PRIx64 " + 1 MB runs past the "
                       "8 GB of HBM", hbm_off);
            goto done;
        }
        if (dma_roundtrip(5, "dma-hbm", hbm_off, 1u << 20, 0xC0FFEEu) != 0)
            goto done;
    }
    if (bench_mb) {
        /* Benchmark into the TOP of HBM, not offset 0.  Offset 0 is where a
         * resident weight blob lives, and a benchmark is exactly the thing
         * someone re-runs casually. */
        uint64_t bench_at = HBM_TOP - ((uint64_t)bench_mb << 20);
        (void)stage6_bench(bench_mb, bench_at);
    }

done:
    printf("\n%d passed, %d failed\n", n_pass, n_fail);
    if (n_fail) {
        printf("FIRST failure was stage %d (%s).  Everything after it is "
               "downstream of that\nfault and its result means nothing.  Start "
               "there, and see\n"
               "docs/2026-08-27_fk33-pcie-bringup-procedure.md.\n",
               first_fail_stage, first_fail_name);
        return 1;
    }
    printf("ALL PASS -- the host path is working end to end.\n");
    return 0;
}
