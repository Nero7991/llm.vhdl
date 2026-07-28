/* hw/llama_hw.c -- run the PL transformer on the AXU3EG and print the story.
 *
 * This is the userspace "driver" for the llama_engine_axi core: there is no
 * kernel module, the core is a plain AXI4-Lite slave so we just mmap it through
 * /dev/mem (root).  The 512-entry tokenizer is compiled in (hw/tok512_pkg.h,
 * generated from ref/tok512.bin), so the result is ONE static binary with no
 * data files to copy alongside it.
 *
 *   build (host):   make -C hw llama_hw
 *   deploy:         scp hw/llama_hw root@<board>:/tmp/
 *   run (board):    /tmp/llama_hw            # prints the story
 *                   /tmp/llama_hw -i         # also print the raw token ids
 *                   /tmp/llama_hw -t         # also print timing / tokens-per-sec
 *
 * WHAT THE ENGINE DOES (and does not do):
 *   It is AUTONOMOUS.  One write to CTRL makes it teacher-force the prompt that
 *   was SYNTHESIZED INTO THE BITSTREAM ("Once upon a time" = ids 1,403,407,261,
 *   378) and then greedily generate to NGEN positions.  It takes no prompt input
 *   and does no sampling, so every run returns the SAME text.  Changing the
 *   prompt today means re-synthesizing; making it accept a prompt at runtime is
 *   an RTL change (a writable prompt/token register feeding the embed stage).
 *
 * Register map, base 0x80110000 (AXI decodes addr[7:2], so 0x00..0xFC only):
 *   0x00 CTRL   w  bit0 = START (resets the engine, then runs)
 *   0x04 STATUS r  bit0 = done, bit1 = busy
 *   0x08 COUNT  r  tokens emitted so far (0..NGEN)
 *   0x0C CFG    r  {NGEN[31:16], MAXPOS[15:0]}
 *   0x20 ID     r  0x6C6C6D31 == "llm1"
 *   0x40+4i     r  TOKEN[i]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#include "tok512_pkg.h"

#define ENGINE_BASE 0x80110000UL
#define MAP_SPAN    0x1000UL
#define REG_CTRL    (0x00 / 4)
#define REG_STATUS  (0x04 / 4)
#define REG_COUNT   (0x08 / 4)
#define REG_CFG     (0x0C / 4)
#define REG_ID      (0x20 / 4)
#define REG_TOKEN0  (0x40 / 4)
#define ENGINE_ID   0x6C6C6D31UL

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Mirror llama2.c decode(): the token after BOS(1) loses its leading space, and
 * <0xXX> byte-fallback tokens expand to that raw byte. */
static void emit(int tok, int prev)
{
    const char *p;
    int len;

    if (tok == 1)                       /* BOS prints nothing */
        return;
    if (tok < 0 || tok >= TOK_VOCAB) {
        printf("<bad:%d>", tok);
        return;
    }
    p   = TOK_WORD[tok];
    len = TOK_LEN[tok];
    if (prev == 1 && len > 0 && p[0] == ' ') {
        p++;
        len--;
    }
    if (len == 6 && p[0] == '<' && p[1] == '0' && p[2] == 'x' && p[5] == '>') {
        unsigned byte = (unsigned)strtoul((char[]){ p[3], p[4], 0 }, NULL, 16);
        putchar((int)byte);
        return;
    }
    fwrite(p, 1, (size_t)len, stdout);
}

int main(int argc, char **argv)
{
    int show_ids = 0, show_time = 0;
    int fd, i, n, prev;
    volatile uint32_t *r;
    void *map;
    uint32_t id, cfg, ngen, status;
    double t0, t1;

    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-i")) show_ids  = 1;
        else if (!strcmp(argv[i], "-t")) show_time = 1;
        else {
            fprintf(stderr,
                    "usage: %s [-i] [-t]\n"
                    "  -i  print the raw token ids as well\n"
                    "  -t  print run time and tokens/sec\n", argv[0]);
            return 2;
        }
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }
    map = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ENGINE_BASE);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    r = (volatile uint32_t *)map;

    id = r[REG_ID];
    if (id != ENGINE_ID) {
        fprintf(stderr,
                "no llama engine at 0x%08lX (ID=0x%08X, expected 0x%08lX).\n"
                "Is the engine bitstream loaded?  /tftpboot/system.bit.bin should be\n"
                "the GOLDEN24 build, then power-cycle the board.\n",
                ENGINE_BASE, id, ENGINE_ID);
        return 1;
    }
    cfg  = r[REG_CFG];
    ngen = cfg >> 16;
    if (ngen == 0 || ngen > 256)
        ngen = 24;

    /* STATUS.done LATCHES until the next START, so after a previous run it is
     * still 1.  Polling for done straight away would fall through immediately
     * and read the PREVIOUS run's COUNT/TOKENs (and report a nonsense runtime).
     * Wait for the engine to actually pick the request up -- done clears / busy
     * asserts -- before waiting for completion. */
    t0 = now_s();
    r[REG_CTRL] = 1;                    /* START: reset + run */
    while (now_s() - t0 < 1.0) {        /* ack window: done must drop */
        status = r[REG_STATUS];
        if (!(status & 1))
            break;
    }
    if (r[REG_STATUS] & 1) {
        fprintf(stderr, "engine never cleared STATUS.done after START "
                        "(STATUS=0x%08X) -- is the core held in reset?\n",
                r[REG_STATUS]);
        return 1;
    }
    do {                                /* now wait for the real completion */
        status = r[REG_STATUS];
        if (now_s() - t0 > 120.0) {
            fprintf(stderr, "engine timed out (STATUS=0x%08X COUNT=%u)\n",
                    status, r[REG_COUNT]);
            return 1;
        }
    } while (!(status & 1));
    t1 = now_s();

    n = (int)r[REG_COUNT];
    if (n <= 0 || (uint32_t)n > ngen) {
        fprintf(stderr, "engine returned COUNT=%d (expected %u)\n", n, ngen);
        return 1;
    }

    if (show_ids) {
        printf("ids:");
        for (i = 0; i < n; i++)
            printf(" %d", (int)r[REG_TOKEN0 + i]);
        printf("\n");
    }

    prev = 1;                           /* the stream follows a BOS */
    for (i = 0; i < n; i++) {
        int tok = (int)r[REG_TOKEN0 + i];
        emit(tok, prev);
        prev = tok;
    }
    printf("\n");

    if (show_time)
        fprintf(stderr, "\n%d tokens in %.3f s  (%.2f tok/s)\n",
                n, t1 - t0, n / (t1 - t0));

    munmap(map, MAP_SPAN);
    close(fd);
    return 0;
}
