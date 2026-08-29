/* fk33_transport.c -- the chardev/file transport and the shared helpers.
 * The simulated transport is in server/fk33_sim.c.  See fk33_transport.h.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "fk33_transport.h"

/* ---------------------------------------------------------------- chardev */

typedef struct {
    int  fd_user, fd_h2c, fd_c2h;
    char desc[256];
} chardev_ctx;

/* pread/pwrite rather than mmap, following hw/fk33/host/fk33_bringup.c:136
 * verbatim: a pread that fails returns an errno, whereas a load from a bad
 * mmap raises SIGBUS.  Nothing here is in a hot enough loop to care about the
 * ~1 us mmap would save on a BAR access. */
static int cd_reg_read32(void *c, uint32_t off, uint32_t *val)
{
    chardev_ctx *x = (chardev_ctx *)c;
    uint32_t v = 0;
    ssize_t r = pread(x->fd_user, &v, 4, (off_t)off);
    if (r != 4) return -EIO;
    *val = v;
    return 0;
}

static int cd_reg_write32(void *c, uint32_t off, uint32_t val)
{
    chardev_ctx *x = (chardev_ctx *)c;
    ssize_t r = pwrite(x->fd_user, &val, 4, (off_t)off);
    return r == 4 ? 0 : -EIO;
}

/* A SHORT TRANSFER IS A FAILURE.  XDMA can legitimately return short, so the
 * loop is required; what is not permitted is treating an eventual short return
 * as partial success.  A truncated logits row is a plausible-looking wrong
 * token, which is the failure class this project keeps finding. */
static int cd_xfer(int fd, uint64_t addr, void *buf, size_t len, int is_write)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = is_write
            ? pwrite(fd, (char *)buf + done, len - done, (off_t)(addr + done))
            : pread (fd, (char *)buf + done, len - done, (off_t)(addr + done));
        if (n <= 0) return n == 0 ? -EIO : -errno;
        done += (size_t)n;
    }
    return 0;
}

static int cd_mem_read(void *c, uint64_t a, void *b, size_t n)
{ return cd_xfer(((chardev_ctx *)c)->fd_c2h, a, b, n, 0); }

static int cd_mem_write(void *c, uint64_t a, const void *b, size_t n)
{ return cd_xfer(((chardev_ctx *)c)->fd_h2c, a, (void *)(uintptr_t)b, n, 1); }

static void cd_close(void *c)
{
    chardev_ctx *x = (chardev_ctx *)c;
    if (x->fd_user >= 0) close(x->fd_user);
    if (x->fd_h2c  >= 0) close(x->fd_h2c);
    if (x->fd_c2h  >= 0 && x->fd_c2h != x->fd_h2c) close(x->fd_c2h);
    free(x);
}

static const char *cd_describe(void *c) { return ((chardev_ctx *)c)->desc; }

static int is_dev_path(const char *p)
{ return p && !strncmp(p, "/dev/", 5); }

fk33_transport *fk33_transport_open_chardev(const char *dev_user,
                                            const char *dev_h2c,
                                            const char *dev_c2h,
                                            uint32_t allow_hw)
{
    chardev_ctx *x;
    fk33_transport *t;

    if (!dev_user || !dev_h2c || !dev_c2h) {
        fprintf(stderr, "fk33_transport: three paths are required\n");
        return NULL;
    }

    /* THE TRIPWIRE.  An agent destroyed this card's factory flash image by
     * crossing the hardware line.  Nothing in this tree passes the token. */
    if ((is_dev_path(dev_user) || is_dev_path(dev_h2c) || is_dev_path(dev_c2h))
        && allow_hw != FK33_ALLOW_HARDWARE) {
        fprintf(stderr,
            "fk33_transport: REFUSING to open a /dev path without an explicit\n"
            "  FK33_ALLOW_HARDWARE token.  This is a live FK33 and host code\n"
            "  in this tree is not permitted to touch it unattended.  If you\n"
            "  are a human doing bring-up, pass the token from your own\n"
            "  caller; do not add it to a script, a test or a default.\n");
        return NULL;
    }

    x = (chardev_ctx *)calloc(1, sizeof *x);
    if (!x) return NULL;
    x->fd_user = x->fd_h2c = x->fd_c2h = -1;

    x->fd_user = open(dev_user, O_RDWR);
    if (x->fd_user < 0) {
        fprintf(stderr, "fk33_transport: open %s: %s\n", dev_user, strerror(errno));
        cd_close(x); return NULL;
    }
    x->fd_h2c = open(dev_h2c, O_RDWR);
    if (x->fd_h2c < 0) {
        fprintf(stderr, "fk33_transport: open %s: %s\n", dev_h2c, strerror(errno));
        cd_close(x); return NULL;
    }
    if (!strcmp(dev_h2c, dev_c2h)) {
        x->fd_c2h = x->fd_h2c;
    } else {
        x->fd_c2h = open(dev_c2h, O_RDONLY);
        if (x->fd_c2h < 0) {
            fprintf(stderr, "fk33_transport: open %s: %s\n", dev_c2h, strerror(errno));
            cd_close(x); return NULL;
        }
    }

    snprintf(x->desc, sizeof x->desc, "chardev user=%s h2c=%s c2h=%s",
             dev_user, dev_h2c, dev_c2h);

    t = (fk33_transport *)calloc(1, sizeof *t);
    if (!t) { cd_close(x); return NULL; }
    t->reg_read32 = cd_reg_read32;
    t->reg_write32 = cd_reg_write32;
    t->mem_read = cd_mem_read;
    t->mem_write = cd_mem_write;
    t->close = cd_close;
    t->describe = cd_describe;
    t->ctx = x;
    return t;
}

fk33_transport *fk33_transport_open_filedir(const char *dir)
{
    char u[512], d[512];
    int fd;

    if (!dir) return NULL;
    if (mkdir(dir, 0775) < 0 && errno != EEXIST) {
        fprintf(stderr, "fk33_transport: mkdir %s: %s\n", dir, strerror(errno));
        return NULL;
    }
    snprintf(u, sizeof u, "%s/user", dir);
    snprintf(d, sizeof d, "%s/dma",  dir);

    /* Sparse.  The DMA file is nominally 8 GB + the 64 KB BRAM window and
     * occupies only the blocks actually written, which is what
     * hw/fk33/host/selftest_nocard.sh does with truncate. */
    fd = open(u, O_RDWR | O_CREAT, 0664);
    if (fd < 0) { fprintf(stderr, "fk33_transport: %s: %s\n", u, strerror(errno)); return NULL; }
    if (ftruncate(fd, 0x20000) < 0) { close(fd); return NULL; }
    close(fd);

    fd = open(d, O_RDWR | O_CREAT, 0664);
    if (fd < 0) { fprintf(stderr, "fk33_transport: %s: %s\n", d, strerror(errno)); return NULL; }
    if (ftruncate(fd, (off_t)0x200010000ull) < 0) { close(fd); return NULL; }
    close(fd);

    return fk33_transport_open_chardev(u, d, d, 0);
}

/* ---------------------------------------------------------------- helpers */

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int fk33_poll32(fk33_transport *t, uint32_t off, uint32_t mask, uint32_t want,
                int timeout_ms, uint32_t *out)
{
    double t0 = now_s();
    uint32_t v = 0;
    for (;;) {
        int rc = t->reg_read32(t->ctx, off, &v);
        if (rc) { if (out) *out = v; return rc; }
        if ((v & mask) == want) { if (out) *out = v; return 0; }
        if ((now_s() - t0) * 1000.0 > (double)timeout_ms) {
            if (out) *out = v;
            return -1;
        }
    }
}
