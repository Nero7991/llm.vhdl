/* server/pl_backend.c -- generation on the PL transformer over /dev/mem.
 * See pl_backend.h for why this is a generation-level seam and not forward_hw().
 *
 * There is no kernel module: llama_engine_axi is a plain AXI4-Lite slave, so we
 * mmap it.  Requires root (as does /dev/mem generally).
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

#include "../hw/tok512.h"
#include "pl_backend.h"

#define ENGINE_BASE 0x80110000UL
#define MAP_SPAN    0x1000UL
#define REG_CTRL       (0x00 / 4)
#define REG_STATUS     (0x04 / 4)
#define REG_COUNT      (0x08 / 4)
#define REG_CFG        (0x0C / 4)
#define REG_PROMPT_LEN (0x14 / 4)
#define REG_ID         (0x20 / 4)
#define REG_TOKEN0     (0x40 / 4)
#define REG_PROMPT0    (0xA0 / 4)
#define ENGINE_ID      0x6C6C6D31UL

/* PL clock: RPLL is left at 800 MHz by the golden BOOT.BIN, so PL0 = 800/DIV0.
 * Linux's clock framework reprograms this to 100 MHz during boot from the DT,
 * which is ABOVE the 84.9 MHz that meets worst-case timing -- so set it here. */
#define CRL_PL0_REF_CTRL 0xFF5E00C0UL
#define RPLL_MHZ         800

static volatile uint32_t *g_reg;
static int   g_ngen, g_maxpos;
static char  g_desc[160];

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int pl_open(int clock_mhz)
{
    int fd;
    void *map;
    uint32_t id, cfg, pl0 = 0, div0;

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0)
        return -1;

    if (clock_mhz > 0) {
        void *cm = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                        CRL_PL0_REF_CTRL & ~(MAP_SPAN - 1));
        if (cm != MAP_FAILED) {
            volatile uint32_t *c = (volatile uint32_t *)
                ((char *)cm + (CRL_PL0_REF_CTRL & (MAP_SPAN - 1)));
            int d = (RPLL_MHZ + clock_mhz / 2) / clock_mhz;
            if (d < 1)  d = 1;
            if (d > 63) d = 63;
            *c  = 0x01000002UL | ((uint32_t)d << 8);   /* CLKACT, DIV1=1, RPLL */
            pl0 = *c;
            munmap(cm, MAP_SPAN);
        }
    }

    map = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ENGINE_BASE);
    close(fd);
    if (map == MAP_FAILED)
        return -2;
    g_reg = (volatile uint32_t *)map;

    id = g_reg[REG_ID];
    if (id != ENGINE_ID) {
        munmap(map, MAP_SPAN);
        g_reg = NULL;
        return -3;
    }
    cfg      = g_reg[REG_CFG];
    g_ngen   = (int)(cfg >> 16);
    g_maxpos = (int)(cfg & 0xFFFF);
    if (g_ngen <= 0 || g_ngen > 256)     g_ngen   = 24;
    if (g_maxpos <= 0 || g_maxpos > 256) g_maxpos = 24;

    div0 = (pl0 >> 8) & 0x3F;
    snprintf(g_desc, sizeof g_desc,
             "PL engine @0x%08lX id=llm1 ngen=%d maxpos=%d clock=%u MHz",
             ENGINE_BASE, g_ngen, g_maxpos, div0 ? (unsigned)RPLL_MHZ / div0 : 0u);
    return 0;
}

int pl_ngen(void)   { return g_ngen; }
int pl_maxpos(void) { return g_maxpos; }
const char *pl_describe(void) { return g_desc; }

int pl_encode(const char *text, int *ids, int max)
{
    return tok_encode(text, ids, max);
}

int pl_piece(int tok, int prev, char *dst, int dstlen)
{
    return tok_piece(tok, prev, dst, dstlen);
}

int pl_generate(const int *prompt, int nprompt, int *out, int max_out)
{
    int i, n;
    double t0;

    if (!g_reg || nprompt < 1 || nprompt > g_maxpos)
        return -1;

    for (i = 0; i < nprompt; i++)
        g_reg[REG_PROMPT0 + i] = (uint32_t)prompt[i];
    g_reg[REG_PROMPT_LEN] = (uint32_t)nprompt;

    /* STATUS.done latches until the next START, so wait for the core to take the
     * request (done drops) before waiting for completion -- otherwise we would
     * fall straight through and read the PREVIOUS run's tokens. */
    t0 = now_s();
    g_reg[REG_CTRL] = 1;
    while (now_s() - t0 < 1.0 && (g_reg[REG_STATUS] & 1))
        ;
    if (g_reg[REG_STATUS] & 1)
        return -2;                       /* never acked -- core held in reset? */
    while (!(g_reg[REG_STATUS] & 1)) {
        if (now_s() - t0 > 120.0)
            return -3;                   /* timed out */
    }

    n = (int)g_reg[REG_COUNT];
    if (n < 0 || n > g_ngen)
        return -4;
    if (n > max_out)
        n = max_out;
    for (i = 0; i < n; i++)
        out[i] = (int)g_reg[REG_TOKEN0 + i];
    return n;
}
