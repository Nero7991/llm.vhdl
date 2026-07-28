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

#include "tok512.h"   /* vocab + the shared BPE encode/decode */

#define ENGINE_BASE 0x80110000UL
#define MAP_SPAN    0x1000UL
#define REG_CTRL    (0x00 / 4)
#define REG_STATUS  (0x04 / 4)
#define REG_COUNT   (0x08 / 4)
#define REG_CFG     (0x0C / 4)
#define REG_ID      (0x20 / 4)
#define REG_TOKEN0  (0x40 / 4)
#define ENGINE_ID   0x6C6C6D31UL

/* CRL_APB PL0_REF_CTRL -- the PL clock this core runs on.  SRCSEL=2 is RPLL,
 * which the golden BOOT.BIN leaves at 800 MHz, so PL0 = 800 / DIVISOR0.
 * NOTE the BD's PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ does NOT control this: the
 * FSBL's psu_init does, and we deploy by swapping only system.bit.bin.  Hence
 * the board runs 100 MHz regardless of what the BD asked for. */
#define CRL_PL0_REF_CTRL 0xFF5E00C0UL
#define RPLL_MHZ         800

/* Worst-case-corner timing at 100 MHz is WNS = -1.783 ns, i.e. the engine needs
 * 11.783 ns and 10 ns is not enough.  It nevertheless computes the golden token
 * stream because real silicon at nominal voltage/temperature beats the slow
 * corner -- fine on a bench, NOT something to rely on across PVT.  The fastest
 * in-spec clock is 1000/11.783 = 84.9 MHz, so 80 MHz (DIVISOR0=10) is the
 * natural safe operating point: +0.72 ns of worst-case margin, 95.6 tok/s. */
#define SAFE_MHZ 80

/* Runtime prompt: PROMPT[i] is written at word 40+i (0xA0 + 4i) and the length
 * at 0x14.  MAXPOS positions total, so prompt + generated <= MAXPOS -- a longer
 * prompt simply leaves fewer tokens to generate. */
#define REG_PROMPT_LEN (0x14 / 4)
#define REG_PROMPT0    (0xA0 / 4)
#define MAXPOS         24

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* encode_prompt/emit now live in hw/tok512.h (tok_encode/tok_piece) so the
 * on-board CLI and the server's PL backend share ONE implementation. */
static int encode_prompt(const char *text, int *out, int max)
{
    return tok_encode(text, out, max);
}

static void emit(int tok, int prev)
{
    char piece[64];
    int n = tok_piece(tok, prev, piece, sizeof piece);
    if (n > 0)
        fwrite(piece, 1, (size_t)n, stdout);
}

int main(int argc, char **argv)
{
    /* Default to the in-spec clock.  U-Boot's preboot does set 80 MHz, but
     * Linux's ZynqMP clock framework reprograms pl0_ref from the device tree
     * during boot and puts it back to 100 MHz (measured: U-Boot md shows
     * 0x01000a02, Linux devmem shows 0x01010802).  Making that stick would need
     * a DT/rootfs rebuild, and image.ub has to stay golden for the U-Boot
     * rollback path -- so the tool sets the clock itself, every run.
     * Use -f 0 to leave whatever the system has alone. */
    int show_ids = 0, show_time = 0, set_mhz = SAFE_MHZ;
    const char *prompt = NULL;
    int ptok[MAXPOS], plen = 0, enc_only = 0;
    int fd, i, n, prev;
    volatile uint32_t *r, *crl;
    void *map, *crlmap;
    uint32_t id, cfg, ngen, status, pl0, div0, plmhz;
    double t0, t1;

    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-i")) show_ids  = 1;
        else if (!strcmp(argv[i], "-t")) show_time = 1;
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) set_mhz = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) prompt   = argv[++i];
        else if (!strcmp(argv[i], "-e")) enc_only = 1;
        else {
            fprintf(stderr,
                    "usage: %s [-i] [-t] [-f MHZ]\n"
                    "  -i      print the raw token ids as well\n"
                    "  -t      print run time and tokens/sec\n"
                    "  -p TEXT set the prompt (BPE-encoded here, written to the\n"
                    "          engine's prompt registers).  Default: the built-in\n"
                    "          \"Once upon a time\".  prompt + generated <= %d tokens.\n"
                    "  -e      just encode -p and print the ids (no hardware needed)\n"
                    "  -f MHZ  PL clock to run at, default %d MHz -- the fastest\n"
                    "          clock that meets worst-case timing.  -f 0 leaves the\n"
                    "          system clock alone (and warns if it is above that).\n",
                    argv[0], MAXPOS, SAFE_MHZ);
            return 2;
        }
    }

    /* -e is a pure tokenizer check: no /dev/mem, works on the host too. */
    if (enc_only) {
        plen = encode_prompt(prompt ? prompt : "Once upon a time", ptok, MAXPOS);
        if (plen < 1) {
            fprintf(stderr, "prompt does not fit in %d tokens\n", MAXPOS);
            return 1;
        }
        for (i = 0; i < plen; i++)
            printf("%d%s", ptok[i], i + 1 < plen ? " " : "\n");
        return 0;
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

    /* PL clock: report it, optionally set it, and warn if it is above the
     * timing-closed maximum (the engine still computes correctly there today,
     * but only because silicon beats the worst-case corner). */
    crlmap = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                  CRL_PL0_REF_CTRL & ~(MAP_SPAN - 1));
    crl = NULL;
    if (crlmap != MAP_FAILED)
        crl = (volatile uint32_t *)((char *)crlmap +
                                    (CRL_PL0_REF_CTRL & (MAP_SPAN - 1)));
    if (crl && set_mhz > 0) {
        int d = (RPLL_MHZ + set_mhz / 2) / set_mhz;
        if (d < 1)  d = 1;
        if (d > 63) d = 63;
        *crl = 0x01000002UL | ((uint32_t)d << 8);   /* CLKACT, DIV1=1, RPLL */
    }
    if (crl) {
        pl0   = *crl;
        div0  = (pl0 >> 8) & 0x3F;
        plmhz = div0 ? (uint32_t)RPLL_MHZ / div0 : 0;
        if (show_time)
            fprintf(stderr, "PL clock ~%u MHz (PL0_REF_CTRL=0x%08X)\n", plmhz, pl0);
        if (plmhz > SAFE_MHZ)
            fprintf(stderr,
                    "warning: PL clock ~%u MHz exceeds the %d MHz that meets\n"
                    "         worst-case timing (WNS -1.783 ns at 100 MHz).  Output is\n"
                    "         still golden on this board, but that relies on silicon\n"
                    "         beating the slow corner.  Use -f %d for an in-spec run.\n",
                    plmhz, SAFE_MHZ, SAFE_MHZ);
    }

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

    /* Load a runtime prompt, if one was given.  Write the tokens first, then the
     * length, then START -- the engine samples all of it at reset. */
    if (prompt) {
        plen = encode_prompt(prompt, ptok, MAXPOS);
        if (plen < 1) {
            fprintf(stderr, "prompt does not fit in %d tokens\n", MAXPOS);
            return 1;
        }
        if (plen >= (int)ngen)
            fprintf(stderr, "note: prompt is %d of the %u positions, so only %d "
                            "token(s) will be generated\n", plen, ngen,
                    (int)ngen - plen);
        for (i = 0; i < plen; i++)
            r[REG_PROMPT0 + i] = (uint32_t)ptok[i];
        r[REG_PROMPT_LEN] = (uint32_t)plen;
        if (show_ids) {
            printf("prompt ids:");
            for (i = 0; i < plen; i++)
                printf(" %d", ptok[i]);
            printf("\n");
        }
    }

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
