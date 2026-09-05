/* fk33_transport.h -- the four operations that cross the PCIe boundary.
 *
 * WHY A TRANSPORT ABSTRACTION AT ALL
 * ----------------------------------
 * The card cannot currently run anything: the composed FK33 design does not
 * route (`[Route 35-3] global congestion level 7`, OI-12), so no bitstream
 * exists.  Every line of host software written before that lands is written
 * against nothing.  The choice is between writing it against an implicit
 * nothing -- code that has never executed -- and writing it against an
 * explicit one that can be run, mutated and gated.  This is the explicit one.
 *
 * CORRECTION 2026-09-05: BOTH HALVES OF THAT PREMISE ARE NOW FALSE, and the
 * conclusion still holds for a different reason.
 *
 *   1. The composed top ROUTES.  MEASURED today: 520,701 routable nets,
 *      520,701 fully routed, 0 with routing errors, 0 unrouted, 0 partial.
 *      It misses TIMING, not routability -- best recorded -0.041 ns
 *      (198.4 MHz against a 200 MHz constraint).  The congestion-level-7
 *      failure above belongs to an older geometry.
 *   2. A BITSTREAM EXISTS.  `hw/fk33/pcieep_build.sh` produced one that MEETS
 *      200 MHz (WNS +0.001, later +0.096 with a better strategy), preserved
 *      under `hw/fk33/bit/`.  See
 *      docs/debugging/2026-09-05_card-bitstream-meets-200mhz.md.
 *
 * WHY THE ABSTRACTION IS STILL RIGHT.  That bitstream is the PCIe shell plus
 * subsystem A only -- B, C and D are not in it -- so it cannot run an
 * inference, and this header's code still has no card to talk to.  The reason
 * shifted from "nothing routes" to "what was built is a subset", which is a
 * better position and not a finished one.  Do not read the paragraph above as
 * current: it is kept because it was acted on, per this project's rule that a
 * superseded claim is marked withdrawn rather than deleted.
 *
 * There are exactly FOUR operations, and the whole rest of the host stack is
 * built out of them:
 *
 *     reg_read32 / reg_write32   AXI-Lite BAR, 32 bits, non-posted read.
 *     mem_read   / mem_write     the DMA master space, arbitrary length.
 *
 * That is not a design choice, it is what XDMA gives:
 * `hw/fk33/host/fk33_bringup.c:136` uses `pread`/`pwrite` on
 * `/dev/xdma0_user` for the first pair and on `/dev/xdma0_h2c_0` /
 * `/dev/xdma0_c2h_0` for the second, and for those two the FILE OFFSET IS THE
 * AXI ADDRESS -- which is the stated reason XDMA was chosen over QDMA
 * (`docs/2026-08-27_pcie-host-bringup-plan.md`).
 *
 * THE SWAP POINT IS ONE FUNCTION AND IT IS ALREADY WRITTEN
 * -------------------------------------------------------
 * `fk33_transport_open_chardev()` below IS the real transport.  Nothing about
 * it is a placeholder: it is the same `pread`/`pwrite` loop `fk33_bringup.c`
 * runs on silicon.  Pointing it at `/dev/xdma0_user` talks to the card;
 * pointing it at three ordinary files talks to a file-backed image of the
 * card.  `hw/fk33/host/selftest_nocard.sh` already exercises exactly this
 * substitution for the bring-up program, and this reuses that precedent
 * rather than inventing a second one.
 *
 * So "swap in the real transport" is not a code change at all, it is an
 * argument change.  What is NOT written here is the ENGINE the real transport
 * would be talking to; see server/fk33_seam.h for what that engine must
 * implement and for the fact that it does not exist yet.
 *
 * *** NOTHING IN THIS REPOSITORY MAY OPEN /dev/xdma* WITHOUT A HUMAN. ***
 * An agent destroyed this card's factory flash image by crossing the hardware
 * line.  `fk33_transport_open_chardev()` refuses a path under /dev unless the
 * caller passes FK33_ALLOW_HARDWARE, which no test, no default and no
 * environment variable in this tree ever sets.  That guard is a tripwire, not
 * a security boundary; the boundary is the operator.
 */
#ifndef FK33_TRANSPORT_H
#define FK33_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must be passed to open_chardev for a path under /dev.  Deliberately an
 * awkward literal so it cannot be typed by accident. */
#define FK33_ALLOW_HARDWARE 0x484F5354u   /* "HOST" */

typedef struct fk33_transport fk33_transport;

struct fk33_transport {
    /* All four return 0 on success and a negative errno-like code on failure.
     * A short DMA transfer is a FAILURE, not a partial success: the loop that
     * would hide it lives in the implementation, and callers that treat a
     * short read as "some data arrived" are how a truncated logits vector
     * becomes a plausible-looking wrong token. */
    int  (*reg_read32) (void *ctx, uint32_t off, uint32_t *val);
    int  (*reg_write32)(void *ctx, uint32_t off, uint32_t val);
    int  (*mem_read)   (void *ctx, uint64_t axi_addr, void *buf, size_t len);
    int  (*mem_write)  (void *ctx, uint64_t axi_addr, const void *buf, size_t len);
    void (*close)      (void *ctx);
    const char *(*describe)(void *ctx);
    void *ctx;
};

/* ------------------------------------------------------------------------
 * THE REAL TRANSPORT.  Three character devices, or three ordinary files.
 *
 * `allow_hw` must be FK33_ALLOW_HARDWARE for any path beginning "/dev/".
 * Returns NULL on failure and prints why.
 * ------------------------------------------------------------------------ */
fk33_transport *fk33_transport_open_chardev(const char *dev_user,
                                            const char *dev_h2c,
                                            const char *dev_c2h,
                                            uint32_t allow_hw);

/* Convenience: create the three backing files under `dir` (user, h2c, c2h --
 * the last two the same file, as selftest_nocard.sh does, because H2C and C2H
 * address the same AXI space), sized for a 128 KB BAR and the 8 GB + BRAM DMA
 * window, and open them.  Sparse: the file is nominally 8 GB and occupies
 * only the blocks written. */
fk33_transport *fk33_transport_open_filedir(const char *dir);

/* ------------------------------------------------------------------------
 * THE SIMULATED TRANSPORT.  Register reads are answered by a model of the
 * seam engine (server/fk33_seam.h), so a whole prefill/decode loop runs.
 *
 * `opts` is a `fk33_sim_opts` from fk33_seam.h.  Declared void* here so this
 * header does not drag the seam definition into every translation unit that
 * only wants to move bytes.
 * ------------------------------------------------------------------------ */
fk33_transport *fk33_transport_open_sim(const void *opts);

/* ------------------------------------------------------------------------
 * Small helpers every caller wants, written once.
 * ------------------------------------------------------------------------ */

/* Poll `off` until (value & mask) == want, or `timeout_ms` elapses.
 * Returns 0, -1 on timeout, or the transport's error.  `out` gets the last
 * value read even on timeout, which is what you want in the error message. */
int fk33_poll32(fk33_transport *t, uint32_t off, uint32_t mask, uint32_t want,
                int timeout_ms, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif /* FK33_TRANSPORT_H */
