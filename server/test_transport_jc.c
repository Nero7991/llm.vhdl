/* server/test_transport_jc.c -- TEETH for fk33_transport_open_jc().
 *
 * Each case forks a FAKE BROKER that listens on a real AF_UNIX socket under
 * ~/regress_scratch/ (no hardware, no /dev, nothing jc_broker.py itself
 * touches), scripts the exact lines it expects to see and the exact lines
 * it answers with, and reports a mismatch by exiting 1.  The parent process
 * is the actual test: it drives server/fk33_transport_jc.c's PUBLIC API
 * (fk33_transport_open_jc() and the four struct fk33_transport functions),
 * checks the return codes and values the brief specifies, and then checks
 * that the broker's own script was satisfied (its exit status).
 *
 * Two independent checks per case, deliberately: the broker's hand-rolled
 * line scanning (below, NOT sharing code with fk33_transport_jc.c's parser)
 * catches a wire-format defect even if this file's own assertions would not
 * have noticed one, and the parent's return-code assertions catch an API
 * defect even if the wire happened to look right.
 *
 * NO HARDWARE.  This never touches /dev, tools/jc/jc_broker.py, coe.py, or
 * any JTAG state; it is a textual protocol test against a process this file
 * forked itself.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>

#include "fk33_transport.h"

static int checks, failed;
static char g_dir[512];

static void CK(int cond, const char *fmt, ...)
{
    va_list ap;
    checks++;
    if (cond) return;
    failed++;
    printf("  FAIL ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

/* ============================================================== plumbing
 * A tiny buffered line reader for the BROKER side (the child), independent
 * of fk33_transport_jc.c's own jc_recv_line(). */

#define LB_CAP (256 * 1024)

typedef struct { int fd; char *buf; size_t len; } linebuf;

static void lb_init(linebuf *lb, int fd)
{
    lb->fd = fd; lb->len = 0;
    lb->buf = (char *)malloc(LB_CAP);
    if (!lb->buf) _exit(1);
}

/* 0 = got a line (NUL-terminated in *line, length in *llen); -1 = overflow;
 * -2 = EOF before a full line arrived. */
static int lb_getline(linebuf *lb, char **line, size_t *llen)
{
    for (;;) {
        size_t i;
        ssize_t n;
        for (i = 0; i < lb->len; i++) if (lb->buf[i] == '\n') break;
        if (i < lb->len) {
            size_t rest = lb->len - (i + 1);
            lb->buf[i] = 0;
            *line = lb->buf; *llen = i;
            memmove(lb->buf, lb->buf + i + 1, rest);
            lb->len = rest;
            return 0;
        }
        if (lb->len >= LB_CAP) return -1;
        n = read(lb->fd, lb->buf + lb->len, LB_CAP - lb->len);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) return -2;
        lb->len += (size_t)n;
    }
}

static void send_raw(int fd, const char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);
        if (n < 0) { if (errno == EINTR) continue; _exit(1); }
        done += (size_t)n;
    }
}

static void send_line(int fd, const char *s)
{
    send_raw(fd, s, strlen(s));
    send_raw(fd, "\n", 1);
}

#define BFAIL(...) do { fprintf(stderr, "[broker] " __VA_ARGS__); \
                        fprintf(stderr, "\n"); _exit(1); } while (0)
#define BCK(cond, ...) do { if (!(cond)) BFAIL(__VA_ARGS__); } while (0)

/* Checks that line contains `"vals":[` holding exactly n_expect integers,
 * the k-th equal to start+k, nothing else inside the brackets. Independent
 * of fk33_transport_jc.c's parser, on purpose. */
static int check_vals_seq(const char *line, long start, size_t n_expect)
{
    const char *p = strstr(line, "\"vals\":[");
    size_t idx = 0;
    if (!p) return 0;
    p += strlen("\"vals\":[");
    if (*p == ']') return n_expect == 0;
    for (;;) {
        char *endp;
        long v = strtol(p, &endp, 10);
        if (endp == p) return 0;
        if (v != start + (long)idx) return 0;
        idx++;
        p = endp;
        if (*p == ',') { p++; continue; }
        if (*p == ']') { p++; break; }
        return 0;
    }
    return idx == n_expect;
}

static int has_off(const char *line, uint32_t off)
{
    char needle[32];
    snprintf(needle, sizeof needle, "\"off\":%u", off);
    return strstr(line, needle) != NULL;
}

/* ============================================================ the harness */

static int start_broker(const char *path, void (*fn)(int), pid_t *pid_out)
{
    int lfd;
    struct sockaddr_un addr;
    pid_t pid;

    unlink(path);
    lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) return -1;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof addr) < 0) { close(lfd); return -1; }
    if (listen(lfd, 1) < 0) { close(lfd); return -1; }

    pid = fork();
    if (pid < 0) { close(lfd); return -1; }
    if (pid == 0) {
        int cfd = accept(lfd, NULL, NULL);
        close(lfd);
        if (cfd < 0) _exit(1);
        fn(cfd);          /* every fn() ends in _exit(), never returns */
        _exit(0);
    }
    close(lfd);
    *pid_out = pid;
    return 0;
}

/* Bounded wait: a broker script that hangs must not hang the test suite. */
static int wait_broker(pid_t pid, int *exit_code)
{
    int tries;
    for (tries = 0; tries < 50; tries++) {
        int status;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            return 0;
        }
        usleep(100000);   /* 100 ms; 50 tries = 5 s bound */
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    *exit_code = -2;      /* timed out */
    return -1;
}

static void sock_path(char *out, size_t outsz, const char *name)
{
    snprintf(out, outsz, "%s/%s.sock", g_dir, name);
}

/* ================================================================= cases */

/* Case 1: a buffered write flushes when a read to a different address comes
 * in, and the read returns the broker's value. */
static void broker_read_write(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case1: expected the write's flush");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case1: not a wrn: %s", line);
    BCK(has_off(line, 0x1000), "case1: wrong off: %s", line);
    BCK(strstr(line, "\"fix\":true") != NULL, "case1: fix not true: %s", line);
    BCK(check_vals_seq(line, 0xCAFEBABEL, 1), "case1: wrong vals: %s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "case1: expected the rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "case1: not a rd32: %s", line);
    BCK(has_off(line, 0x2000), "case1: wrong off: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":305419896}");
    _exit(0);
}

static void test_read_write(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "read_write");
    if (start_broker(path, broker_read_write, &pid) != 0) {
        CK(0, "read_write: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "read_write: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, 0x1000, 0xCAFEBABEu);
    CK(rc == 0, "read_write: reg_write32 rc=%d, expected 0 (buffered)", rc);
    rc = t->reg_read32(t->ctx, 0x2000, &v);
    CK(rc == 0 && v == 305419896u,
       "read_write: reg_read32 rc=%d val=%u, expected 0/305419896", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "read_write: broker script exit=%d", ec);
}

/* Case 2: 5,120 writes to the same offset become ONE wrn with all 5,120
 * values in order, and a following rd32 only goes out after that flush. */
static void broker_coalesce(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case2: expected the coalesced wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case2: not a wrn: %.80s", line);
    BCK(has_off(line, 0x4000), "case2: wrong off: %.80s", line);
    BCK(strstr(line, "\"fix\":true") != NULL, "case2: fix not true: %.80s", line);
    BCK(check_vals_seq(line, 0, 5120), "case2: vals not 0..5119 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "case2: expected the rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "case2: not a rd32: %s", line);
    BCK(has_off(line, 0x5000), "case2: wrong off: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":777}");
    _exit(0);
}

static void test_coalesce_5120(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc, wrc = 0;
    unsigned i;

    sock_path(path, sizeof path, "coalesce");
    if (start_broker(path, broker_coalesce, &pid) != 0) {
        CK(0, "coalesce: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "coalesce: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    for (i = 0; i < 5120; i++)
        wrc |= t->reg_write32(t->ctx, 0x4000, i);
    CK(wrc == 0, "coalesce: a buffered reg_write32 returned nonzero");

    rc = t->reg_read32(t->ctx, 0x5000, &v);
    CK(rc == 0 && v == 777,
       "coalesce: reg_read32 rc=%d val=%u, expected 0/777", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "coalesce: broker script exit=%d (wire format or order was wrong)", ec);
}

/* Case 3: a coalesced run longer than JC_WRN_MAX (8192) splits into two wrn
 * requests, in order, rather than one oversized or reordered one. */
static void broker_split(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case3: expected the first wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case3: not a wrn: %.80s", line);
    BCK(has_off(line, 0x7000), "case3: wrong off: %.80s", line);
    BCK(check_vals_seq(line, 0, 8192), "case3: first chunk not 0..8191 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "case3: expected the split remainder");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case3: not a wrn: %.80s", line);
    BCK(has_off(line, 0x7000), "case3: wrong off: %.80s", line);
    BCK(check_vals_seq(line, 8192, 10), "case3: second chunk not 8192..8201 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "case3: expected the forcing rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "case3: not a rd32: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":999}");
    _exit(0);
}

static void test_split_wrn(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc, wrc = 0;
    unsigned i;

    sock_path(path, sizeof path, "split");
    if (start_broker(path, broker_split, &pid) != 0) {
        CK(0, "split: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "split: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    for (i = 0; i < 8202; i++)
        wrc |= t->reg_write32(t->ctx, 0x7000, i);
    CK(wrc == 0, "split: a buffered reg_write32 returned nonzero");

    rc = t->reg_read32(t->ctx, 0x8000, &v);
    CK(rc == 0 && v == 999,
       "split: reg_read32 rc=%d val=%u, expected 0/999", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "split: broker script exit=%d (the bound/split was wrong)", ec);
}

/* Case 4: mem_write is refused with -EPERM, after flushing any pending
 * write, and never puts anything on the wire of its own. */
static void broker_memwrite(int cfd)
{
    linebuf lb; char *line; size_t llen;
    int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case4: expected the flush before refusal");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case4: not a wrn: %s", line);
    BCK(has_off(line, 0x10), "case4: wrong off: %s", line);
    BCK(check_vals_seq(line, 42, 1), "case4: wrong vals: %s", line);
    send_line(cfd, "{\"ok\":true}");

    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "case4: mem_write put something on the wire: rc=%d line=%s",
        rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void test_mem_write_refused(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; int rc;

    sock_path(path, sizeof path, "memwrite");
    if (start_broker(path, broker_memwrite, &pid) != 0) {
        CK(0, "mem_write: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "mem_write: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, 0x10, 42);
    CK(rc == 0, "mem_write: reg_write32 rc=%d, expected 0 (buffered)", rc);
    rc = t->mem_write(t->ctx, 0xABCULL, "hi", 2);
    CK(rc == -EPERM, "mem_write: rc=%d, expected -EPERM(%d)", rc, -EPERM);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "mem_write: broker script exit=%d", ec);
}

/* Case 5: a well-formed {"ok":false,...} reply returns a negative code. */
static void broker_okfalse(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case5: expected a rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "case5: not a rd32: %s", line);
    send_line(cfd, "{\"ok\":false,\"err\":\"AxiError: boom\"}");
    _exit(0);
}

static void test_ok_false(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "okfalse");
    if (start_broker(path, broker_okfalse, &pid) != 0) {
        CK(0, "ok_false: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "ok_false: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x30, &v);
    CK(rc < 0, "ok_false: reg_read32 rc=%d, expected a negative code", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "ok_false: broker script exit=%d", ec);
}

/* Case 6: three shapes of malformed reply (bad JSON, a missing field, an
 * unexpected extra field) each return a negative code and never crash. */
static void broker_malformed(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case6a: expected a rd32");
    send_line(cfd, "not json at all");

    BCK(lb_getline(&lb, &line, &llen) == 0, "case6b: expected a rd32");
    send_line(cfd, "{\"ok\":true}");               /* rd32 success needs "val" */

    BCK(lb_getline(&lb, &line, &llen) == 0, "case6c: expected a rd32");
    send_line(cfd, "{\"ok\":true,\"val\":5,\"extra\":1}");  /* unexpected field */
    _exit(0);
}

static void test_malformed(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "malformed");
    if (start_broker(path, broker_malformed, &pid) != 0) {
        CK(0, "malformed: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "malformed: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x40, &v);
    CK(rc < 0, "malformed: bad JSON rc=%d, expected negative", rc);
    rc = t->reg_read32(t->ctx, 0x41, &v);
    CK(rc < 0, "malformed: missing field rc=%d, expected negative", rc);
    rc = t->reg_read32(t->ctx, 0x42, &v);
    CK(rc < 0, "malformed: extra field rc=%d, expected negative", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "malformed: broker script exit=%d", ec);
}

/* Case 7: the broker closes the connection mid-reply (no trailing newline
 * ever arrives); the call must return a negative code, not hang or crash. */
static void broker_closemid(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case7: expected a rd32");
    send_raw(cfd, "{\"ok\":true,\"va", 14);   /* deliberately truncated, no \n */
    _exit(0);                                 /* closing cfd is the point */
}

static void test_broker_closes_mid_reply(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "closemid");
    if (start_broker(path, broker_closemid, &pid) != 0) {
        CK(0, "closemid: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "closemid: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x50, &v);
    CK(rc < 0, "closemid: rc=%d, expected a negative code", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "closemid: broker script exit=%d", ec);
}

/* Case 8: mem_read maps to memrd and decodes the hex payload correctly. */
static void broker_memread(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case8: expected a memrd");
    BCK(strstr(line, "\"op\":\"memrd\"") != NULL, "case8: not a memrd: %s", line);
    BCK(strstr(line, "\"addr\":38654705664") != NULL, "case8: wrong addr: %s", line);
    BCK(strstr(line, "\"n\":8") != NULL, "case8: wrong n: %s", line);
    send_line(cfd, "{\"ok\":true,\"hex\":\"0011223344556677\"}");
    _exit(0);
}

static void test_mem_read(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; int rc;
    unsigned char buf[8];
    static const unsigned char expect[8] =
        { 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };

    sock_path(path, sizeof path, "memread");
    if (start_broker(path, broker_memread, &pid) != 0) {
        CK(0, "mem_read: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "mem_read: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    memset(buf, 0, sizeof buf);
    rc = t->mem_read(t->ctx, 0x900000000ULL, buf, sizeof buf);
    CK(rc == 0, "mem_read: rc=%d, expected 0", rc);
    CK(memcmp(buf, expect, sizeof buf) == 0, "mem_read: payload mismatch");

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "mem_read: broker script exit=%d", ec);
}

/* Case 9: close() flushes a pending write with no other access forcing it. */
static void broker_closeflush(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "case9: expected close() to flush");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "case9: not a wrn: %s", line);
    BCK(has_off(line, 0x50), "case9: wrong off: %s", line);
    BCK(check_vals_seq(line, 123, 1), "case9: wrong vals: %s", line);
    send_line(cfd, "{\"ok\":true}");
    _exit(0);
}

static void test_close_flushes(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; int rc;

    sock_path(path, sizeof path, "closeflush");
    if (start_broker(path, broker_closeflush, &pid) != 0) {
        CK(0, "close_flushes: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A");
    CK(t != NULL, "close_flushes: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, 0x50, 123);
    CK(rc == 0, "close_flushes: reg_write32 rc=%d, expected 0 (buffered)", rc);
    t->close(t->ctx); free(t);   /* no other access -- close must flush */

    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "close_flushes: broker script exit=%d (close did not flush)", ec);
}

/* Case 10: open() rejects a bad die and a missing socket path without
 * forking anything or touching the filesystem beyond the check itself. */
static void test_open_rejects_bad_args(void)
{
    fk33_transport *t;

    t = fk33_transport_open_jc(NULL, "A");
    CK(t == NULL, "open: NULL sock_path should fail");

    t = fk33_transport_open_jc("/nonexistent/path/does/not/exist.sock", "A");
    CK(t == NULL, "open: a socket that does not exist should fail");

    t = fk33_transport_open_jc("/tmp/irrelevant.sock", "has a space");
    CK(t == NULL, "open: a die with a space should be rejected before connect()");

    t = fk33_transport_open_jc("/tmp/irrelevant.sock", "\"quote\"");
    CK(t == NULL, "open: a die with a quote should be rejected before connect()");
}

/* ================================================================== main */

static int mkdir_ignore(const char *p)
{
    if (mkdir(p, 0700) < 0 && errno != EEXIST) return -1;
    return 0;
}

int main(void)
{
    const char *home = getenv("HOME");
    char base[400];

    if (!home || !*home) home = "/home/orencollaco";
    snprintf(base, sizeof base, "%s/regress_scratch", home);
    mkdir_ignore(base);
    snprintf(g_dir, sizeof g_dir, "%s/task7-jc-transport-%ld",
             base, (long)getpid());
    if (mkdir_ignore(g_dir) < 0) {
        fprintf(stderr, "could not create %s: %s\n", g_dir, strerror(errno));
        return 1;
    }

    test_read_write();
    test_coalesce_5120();
    test_split_wrn();
    test_mem_write_refused();
    test_ok_false();
    test_malformed();
    test_broker_closes_mid_reply();
    test_mem_read();
    test_close_flushes();
    test_open_rejects_bad_args();

    /* best-effort cleanup of this run's own scratch directory */
    {
        static const char *names[] = {
            "read_write.sock", "coalesce.sock", "split.sock", "memwrite.sock",
            "okfalse.sock", "malformed.sock", "closemid.sock", "memread.sock",
            "closeflush.sock"
        };
        size_t i;
        char p[700];
        for (i = 0; i < sizeof names / sizeof names[0]; i++) {
            snprintf(p, sizeof p, "%s/%s", g_dir, names[i]);
            unlink(p);
        }
        rmdir(g_dir);
    }

    printf("\nTRANSPORT_JC_SELFTEST %s  (%d checks, %d failed)\n",
           failed ? "FAIL" : "PASS", checks, failed);
    return failed ? 1 : 0;
}
