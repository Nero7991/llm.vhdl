/* server/test_transport_jc.c -- TEETH for fk33_transport_open_jc().
 *
 * Fix round 1: the review failed the first cut on C1 (coalescing scope),
 * I1 (no receive deadline), I2 (the real ok:false shape), I3 (one socket
 * per die instead of one shared connection) and M1 (sticky broken).  This
 * file's cases were rewritten for the new three-argument open() signature
 * and the new behaviour, and five cases are new (marked below).
 *
 * Each case forks a FAKE BROKER that listens on a real AF_UNIX socket under
 * ~/regress_scratch/, scripts the exact lines it expects to see and answers
 * with, and reports a mismatch by exiting 1.  The parent process is the
 * actual test: it drives fk33_transport_jc.c's public API, checks the
 * return codes and values, and then checks the broker's own exit status.
 * The broker's line matching is hand-rolled (strstr/strtol), independent of
 * fk33_transport_jc.c's own JSON parser, so a wire-format defect is caught
 * twice.
 *
 * NO HARDWARE.  This never touches /dev, tools/jc/jc_broker.py, coe.py, or
 * any JTAG state.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>

#include "fk33_transport.h"

/* The coalesced-window offset every test opens its transport(s) with,
 * unless a test is specifically about a DIFFERENT (non-coalesced) offset.
 * An arbitrary absolute BAR-style offset, distinct from every other offset
 * used below. */
#define T_WIN 0x9000u

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
 * of fk33_transport_jc.c's own line reader. */

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
 * the k-th equal to start+k, nothing else inside the brackets. */
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

static int has_val(const char *line, uint32_t val)
{
    char needle[32];
    snprintf(needle, sizeof needle, "\"val\":%u", val);
    return strstr(line, needle) != NULL;
}

static int has_die(const char *line, const char *die)
{
    char needle[32];
    snprintf(needle, sizeof needle, "\"die\":\"%s\"", die);
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
    for (tries = 0; tries < 70; tries++) {
        int status;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            return 0;
        }
        usleep(100000);   /* 100 ms; 70 tries = 7 s bound */
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

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ================================================================= cases */

/* Case 1: an isolated write to a NON-coalesced offset goes out as its own
 * wr32, immediately -- not buffered into a wrn (C1). */
static void broker_write_then_read(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected an immediate wr32");
    BCK(strstr(line, "\"op\":\"wr32\"") != NULL, "not a wr32: %s", line);
    BCK(has_off(line, 0x1000), "wrong off: %s", line);
    BCK(has_val(line, 0xCAFEBABEu), "wrong val: %s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
    BCK(has_off(line, 0x2000), "wrong off: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":305419896}");
    _exit(0);
}

static void test_write_then_read(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "write_then_read");
    if (start_broker(path, broker_write_then_read, &pid) != 0) {
        CK(0, "write_then_read: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "write_then_read: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, 0x1000, 0xCAFEBABEu);
    CK(rc == 0, "write_then_read: reg_write32 rc=%d, expected 0 (sent)", rc);
    rc = t->reg_read32(t->ctx, 0x2000, &v);
    CK(rc == 0 && v == 305419896u,
       "write_then_read: reg_read32 rc=%d val=%u, expected 0/305419896", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "write_then_read: broker script exit=%d", ec);
}

/* Case 2 (NEW, C1): a write to CTRL is on the wire, acknowledged, BEFORE
 * reg_write32() returns -- the broker sees it with no other call made. */
static void broker_ctrl_on_wire(int cfd)
{
    linebuf lb; char *line; size_t llen; int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the CTRL write immediately");
    BCK(strstr(line, "\"op\":\"wr32\"") != NULL, "not a wr32: %s", line);
    BCK(has_off(line, 0x3000), "wrong off: %s", line);
    BCK(has_val(line, 0xDEADBEEFu), "wrong val: %s", line);
    send_line(cfd, "{\"ok\":true}");

    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "something else arrived after the CTRL write: rc=%d line=%s",
        rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void test_ctrl_on_wire_before_return(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; int rc;

    sock_path(path, sizeof path, "ctrl_on_wire");
    if (start_broker(path, broker_ctrl_on_wire, &pid) != 0) {
        CK(0, "ctrl_on_wire: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "ctrl_on_wire: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, 0x3000, 0xDEADBEEFu);
    CK(rc == 0, "ctrl_on_wire: reg_write32 (CTRL) rc=%d, expected 0", rc);
    /* No other call before close(): the write must already be acked. */
    t->close(t->ctx); free(t);

    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "ctrl_on_wire: broker script exit=%d (CTRL was buffered, not sent)", ec);
}

/* Case 3: 5,120 writes to T_WIN become ONE wrn with all 5,120 values in
 * order, and a following rd32 only appears after that flush. */
static void broker_coalesce(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the coalesced wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %.80s", line);
    BCK(has_off(line, T_WIN), "wrong off: %.80s", line);
    BCK(strstr(line, "\"fix\":true") != NULL, "fix not true: %.80s", line);
    BCK(check_vals_seq(line, 0, 5120), "vals not 0..5119 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
    BCK(has_off(line, 0x5000), "wrong off: %s", line);
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "coalesce: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    for (i = 0; i < 5120; i++)
        wrc |= t->reg_write32(t->ctx, T_WIN, i);
    CK(wrc == 0, "coalesce: a buffered reg_write32 returned nonzero");

    rc = t->reg_read32(t->ctx, 0x5000, &v);
    CK(rc == 0 && v == 777,
       "coalesce: reg_read32 rc=%d val=%u, expected 0/777", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "coalesce: broker script exit=%d (wire format or order was wrong)", ec);
}

/* Case 4: a coalesced run longer than JC_WRN_MAX (8192) splits into two wrn
 * requests, in order, rather than one oversized or reordered one. */
static void broker_split(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the first wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %.80s", line);
    BCK(has_off(line, T_WIN), "wrong off: %.80s", line);
    BCK(check_vals_seq(line, 0, 8192), "first chunk not 0..8191 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the split remainder");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %.80s", line);
    BCK(has_off(line, T_WIN), "wrong off: %.80s", line);
    BCK(check_vals_seq(line, 8192, 10), "second chunk not 8192..8201 in order");
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the forcing rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "split: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    for (i = 0; i < 8202; i++)
        wrc |= t->reg_write32(t->ctx, T_WIN, i);
    CK(wrc == 0, "split: a buffered reg_write32 returned nonzero");

    rc = t->reg_read32(t->ctx, 0x8000, &v);
    CK(rc == 0 && v == 999,
       "split: reg_read32 rc=%d val=%u, expected 0/999", rc, v);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "split: broker script exit=%d (the bound/split was wrong)", ec);
}

/* Case 5: mem_write is refused with -EPERM, after flushing any pending
 * write (to T_WIN), and never puts anything on the wire of its own. */
static void broker_memwrite(int cfd)
{
    linebuf lb; char *line; size_t llen;
    int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the flush before refusal");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %s", line);
    BCK(has_off(line, T_WIN), "wrong off: %s", line);
    BCK(check_vals_seq(line, 42, 1), "wrong vals: %s", line);
    send_line(cfd, "{\"ok\":true}");

    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "mem_write put something on the wire: rc=%d line=%s",
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "mem_write: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, T_WIN, 42);
    CK(rc == 0, "mem_write: reg_write32 rc=%d, expected 0 (buffered)", rc);
    rc = t->mem_write(t->ctx, 0xABCULL, "hi", 2);
    CK(rc == -EPERM, "mem_write: rc=%d, expected -EPERM(%d)", rc, -EPERM);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "mem_write: broker script exit=%d", ec);
}

/* Case 6: a well-formed {"ok":false,"err":...} reply (no done_items)
 * returns a negative code and does not mark a lone, non-flush call fatal. */
static void broker_okfalse(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected a rd32");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "ok_false: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x30, &v);
    CK(rc == -EIO, "ok_false: reg_read32 rc=%d, expected -EIO", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "ok_false: broker script exit=%d", ec);
}

/* Case 7: three shapes of malformed reply each return -EPROTO and never
 * crash.  Each gets its OWN connection: a protocol error correctly (M1)
 * marks the connection it happened on sticky broken, so a second malformed
 * reply on the SAME connection would read back -ECONNABORTED instead of
 * its own -EPROTO -- which is exercised deliberately as the bonus check
 * below, rather than being a surprise. */
static void broker_malformed_one(int cfd, const char *reply)
{
    linebuf lb; char *line; size_t llen; int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected a rd32");
    send_line(cfd, reply);

    /* A second request on this now-broken connection must never reach the
     * wire -- there is nothing scripted to answer it. */
    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "a second request arrived on a connection a protocol "
        "error should have broken: rc=%d line=%s", rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void broker_malformed_bad_json(int cfd)
{ broker_malformed_one(cfd, "not json at all"); }

static void broker_malformed_missing_field(int cfd)
{ broker_malformed_one(cfd, "{\"ok\":true}"); }           /* rd32 needs "val" */

static void broker_malformed_extra_field(int cfd)
{ broker_malformed_one(cfd, "{\"ok\":true,\"val\":5,\"extra\":1}"); }

static void run_malformed_case(const char *name, void (*broker_fn)(int))
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, name);
    if (start_broker(path, broker_fn, &pid) != 0) {
        CK(0, "%s: could not start the fake broker", name); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "%s: fk33_transport_open_jc failed", name);
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x41, &v);
    CK(rc == -EPROTO, "%s: rc=%d, expected -EPROTO", name, rc);
    rc = t->reg_read32(t->ctx, 0x42, &v);
    CK(rc == -ECONNABORTED,
       "%s: a call after a protocol error rc=%d, expected sticky "
       "-ECONNABORTED (M1)", name, rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0, "%s: broker script exit=%d",
       name, ec);
}

static void test_malformed(void)
{
    run_malformed_case("malformed_bad_json", broker_malformed_bad_json);
    run_malformed_case("malformed_missing_field", broker_malformed_missing_field);
    run_malformed_case("malformed_extra_field", broker_malformed_extra_field);
}

/* Case 8: the broker closes the connection mid-reply; the call must return
 * a negative code, not hang or crash. */
static void broker_closemid(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected a rd32");
    send_raw(cfd, "{\"ok\":true,\"va", 14);   /* deliberately truncated, no \n */
    _exit(0);
}

static void test_broker_closes_mid_reply(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "closemid");
    if (start_broker(path, broker_closemid, &pid) != 0) {
        CK(0, "closemid: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "closemid: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_read32(t->ctx, 0x50, &v);
    CK(rc == -EIO, "closemid: rc=%d, expected -EIO", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "closemid: broker script exit=%d", ec);
}

/* Case 9: mem_read maps to memrd and decodes the hex payload correctly. */
static void broker_memread(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected a memrd");
    BCK(strstr(line, "\"op\":\"memrd\"") != NULL, "not a memrd: %s", line);
    BCK(strstr(line, "\"addr\":38654705664") != NULL, "wrong addr: %s", line);
    BCK(strstr(line, "\"n\":8") != NULL, "wrong n: %s", line);
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
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

/* Case 10: close() flushes a pending T_WIN write with no other access
 * forcing it. */
static void broker_closeflush(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected close() to flush");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %s", line);
    BCK(has_off(line, T_WIN), "wrong off: %s", line);
    BCK(check_vals_seq(line, 123, 1), "wrong vals: %s", line);
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
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "close_flushes: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, T_WIN, 123);
    CK(rc == 0, "close_flushes: reg_write32 rc=%d, expected 0 (buffered)", rc);
    t->close(t->ctx); free(t);   /* no other access -- close must flush */

    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "close_flushes: broker script exit=%d (close did not flush)", ec);
}

/* Case 11: open() rejects a bad die and a missing/bad socket path. */
static void test_open_rejects_bad_args(void)
{
    fk33_transport *t;

    t = fk33_transport_open_jc(NULL, "A", T_WIN);
    CK(t == NULL, "open: NULL sock_path should fail");

    t = fk33_transport_open_jc("/nonexistent/path/does/not/exist.sock", "A", T_WIN);
    CK(t == NULL, "open: a socket that does not exist should fail");

    t = fk33_transport_open_jc("/tmp/irrelevant.sock", "has a space", T_WIN);
    CK(t == NULL, "open: a die with a space should be rejected before connect()");

    t = fk33_transport_open_jc("/tmp/irrelevant.sock", "\"quote\"", T_WIN);
    CK(t == NULL, "open: a die with a quote should be rejected before connect()");
}

/* Case 12 (NEW, I1): a broker that never answers must not hang the caller.
 * A short FK33_JC_TIMEOUT_MS makes the deadline fire quickly, and the
 * connection must then be STICKY broken (M1). */
static void broker_never_replies(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);
    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rd32 to arrive");
    /* ...and then just go silent, well past the test's configured deadline,
     * before finally going away. */
    struct timespec ts = { 1, 0 };
    nanosleep(&ts, NULL);
    _exit(0);
}

static void test_recv_timeout(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;
    double t0, dt;

    sock_path(path, sizeof path, "timeout");
    if (start_broker(path, broker_never_replies, &pid) != 0) {
        CK(0, "recv_timeout: could not start the fake broker"); return;
    }
    setenv("FK33_JC_TIMEOUT_MS", "150", 1);
    t = fk33_transport_open_jc(path, "A", T_WIN);
    unsetenv("FK33_JC_TIMEOUT_MS");
    CK(t != NULL, "recv_timeout: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    t0 = now_s();
    rc = t->reg_read32(t->ctx, 0x60, &v);
    dt = now_s() - t0;
    CK(rc == -ETIMEDOUT, "recv_timeout: rc=%d, expected -ETIMEDOUT", rc);
    CK(dt < 1.0, "recv_timeout: took %.3f s, expected well under the 1 s "
                 "broker silence (the 150 ms deadline did not fire)", dt);

    rc = t->reg_read32(t->ctx, 0x61, &v);
    CK(rc == -ECONNABORTED,
       "recv_timeout: a call after the timeout rc=%d, expected sticky "
       "-ECONNABORTED (M1)", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "recv_timeout: broker script exit=%d", ec);
}

/* Case 13 (NEW, I4): a flush that fails (plain {"ok":false,...}) must stop
 * the write that triggered it from sending anything of its own, and must
 * leave the connection sticky broken. */
static void broker_flush_fail_write(int cfd)
{
    linebuf lb; char *line; size_t llen; int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the failing wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %s", line);
    BCK(has_off(line, T_WIN), "wrong off: %s", line);
    BCK(check_vals_seq(line, 99, 1), "wrong vals: %s", line);
    send_line(cfd, "{\"ok\":false,\"err\":\"AxiError: boom\"}");

    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "a wr32 (or anything else) arrived after the failed flush: "
        "rc=%d line=%s", rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void test_flush_fail_blocks_next_write(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "flushfailwr");
    if (start_broker(path, broker_flush_fail_write, &pid) != 0) {
        CK(0, "flush_fail_write: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "flush_fail_write: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, T_WIN, 99);
    CK(rc == 0, "flush_fail_write: buffering write rc=%d, expected 0", rc);
    rc = t->reg_write32(t->ctx, 0x7000, 77);
    CK(rc == -EIO, "flush_fail_write: the triggering write rc=%d, expected "
                   "-EIO (the flush's own failure) and nothing sent for it", rc);
    rc = t->reg_read32(t->ctx, 0x9999, &v);
    CK(rc == -ECONNABORTED,
       "flush_fail_write: a call after a failed flush rc=%d, expected "
       "sticky -ECONNABORTED (M1)", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "flush_fail_write: broker script exit=%d", ec);
}

/* Case 14 (NEW, I2 + M1): the REAL partial-wrn failure shape -- "err" plus
 * done_items/done_items_exact -- must be accepted (not -EPROTO), reported
 * as -EIO, and still mark the connection sticky broken because it IS a
 * flush failure. */
static void broker_flush_fail_done_items(int cfd)
{
    linebuf lb; char *line; size_t llen; int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the failing wrn");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %s", line);
    BCK(has_off(line, T_WIN), "wrong off: %s", line);
    BCK(check_vals_seq(line, 7, 1), "wrong vals: %s", line);
    send_line(cfd,
        "{\"ok\":false,\"err\":\"AxiError: boom\",\"done_items\":37,"
        "\"done_items_exact\":true}");

    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "a rd32 (or anything else) arrived after the failed flush: "
        "rc=%d line=%s", rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void test_flush_fail_done_items(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "flushfaildi");
    if (start_broker(path, broker_flush_fail_done_items, &pid) != 0) {
        CK(0, "flush_fail_done_items: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "flush_fail_done_items: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }

    rc = t->reg_write32(t->ctx, T_WIN, 7);
    CK(rc == 0, "flush_fail_done_items: buffering write rc=%d, expected 0", rc);
    rc = t->reg_read32(t->ctx, 0x8800, &v);
    CK(rc == -EIO, "flush_fail_done_items: the triggering read rc=%d, "
                   "expected -EIO (the done_items shape must parse, not "
                   "-EPROTO) and no rd32 sent", rc);
    rc = t->reg_read32(t->ctx, 0x8801, &v);
    CK(rc == -ECONNABORTED,
       "flush_fail_done_items: a call after rc=%d, expected sticky "
       "-ECONNABORTED (M1)", rc);

    t->close(t->ctx); free(t);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "flush_fail_done_items: broker script exit=%d", ec);
}

/* Case 15 (NEW, I3): two dies on the SAME sock_path share ONE connection;
 * interleaved A/B/A/B/A calls each carry the correct die, in order, and
 * the underlying socket is not closed until the LAST of the two transports
 * is closed. */
static void broker_shared(int cfd)
{
    linebuf lb; char *line; size_t llen; int rc;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected wr32 A");
    BCK(strstr(line, "\"op\":\"wr32\"") && has_die(line, "A") &&
        has_off(line, 0x100) && has_val(line, 11),
        "line 1 wrong: %s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected wr32 B");
    BCK(strstr(line, "\"op\":\"wr32\"") && has_die(line, "B") &&
        has_off(line, 0x200) && has_val(line, 22),
        "line 2 wrong: %s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rd32 A");
    BCK(strstr(line, "\"op\":\"rd32\"") && has_die(line, "A") &&
        has_off(line, 0x300), "line 3 wrong: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":33}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rd32 B");
    BCK(strstr(line, "\"op\":\"rd32\"") && has_die(line, "B") &&
        has_off(line, 0x400), "line 4 wrong: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":44}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected wr32 A again");
    BCK(strstr(line, "\"op\":\"wr32\"") && has_die(line, "A") &&
        has_off(line, 0x500) && has_val(line, 55),
        "line 5 wrong: %s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0,
        "expected a 6th request from B, proving the shared connection "
        "survived A's close");
    BCK(strstr(line, "\"op\":\"wr32\"") && has_die(line, "B") &&
        has_off(line, 0xFFF) && has_val(line, 0),
        "line 6 wrong: %s", line);
    send_line(cfd, "{\"ok\":true}");

    /* Nothing else until BOTH dies have closed. */
    rc = lb_getline(&lb, &line, &llen);
    BCK(rc == -2, "EOF expected only after the last close: rc=%d line=%s",
        rc, rc == 0 ? line : "(none)");
    _exit(0);
}

static void test_shared_connection_interleaved(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *ta, *tb; uint32_t v = 0; int rc;

    sock_path(path, sizeof path, "shared");
    if (start_broker(path, broker_shared, &pid) != 0) {
        CK(0, "shared: could not start the fake broker"); return;
    }

    ta = fk33_transport_open_jc(path, "A", T_WIN);
    CK(ta != NULL, "shared: opening die A failed");
    tb = fk33_transport_open_jc(path, "B", T_WIN);
    CK(tb != NULL, "shared: opening die B on the SAME path failed -- "
                   "connection sharing is broken (a second connect() was "
                   "attempted against a listener nothing accepts any more)");
    if (!ta || !tb) {
        if (ta) { ta->close(ta->ctx); free(ta); }
        if (tb) { tb->close(tb->ctx); free(tb); }
        wait_broker(pid, &ec);
        return;
    }

    rc = ta->reg_write32(ta->ctx, 0x100, 11);
    CK(rc == 0, "shared: A write #1 rc=%d", rc);
    rc = tb->reg_write32(tb->ctx, 0x200, 22);
    CK(rc == 0, "shared: B write #1 rc=%d", rc);
    rc = ta->reg_read32(ta->ctx, 0x300, &v);
    CK(rc == 0 && v == 33, "shared: A read rc=%d val=%u, expected 0/33", rc, v);
    rc = tb->reg_read32(tb->ctx, 0x400, &v);
    CK(rc == 0 && v == 44, "shared: B read rc=%d val=%u, expected 0/44", rc, v);
    rc = ta->reg_write32(ta->ctx, 0x500, 55);
    CK(rc == 0, "shared: A write #2 rc=%d", rc);

    ta->close(ta->ctx); free(ta);   /* refcount 2 -> 1: the fd must survive */
    rc = tb->reg_write32(tb->ctx, 0xFFF, 0);
    CK(rc == 0, "shared: B after A's close rc=%d, expected 0 -- the shared "
                "connection must not have been torn down by A's close", rc);

    tb->close(tb->ctx); free(tb);   /* refcount 1 -> 0: NOW the fd closes */
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "shared: broker script exit=%d", ec);
}

/* ================================================================== main */

/* ===================================================== bulk reads (rdn)
 * 2026-10-16.  reg_read32n is the one entry point where the caller states a
 * read count; it must go out as {"op":"rdn","off":N,"fix":true,"n":K}, after
 * any pending coalesced write run (order), and its reply's "vals" must land
 * in order, the full 32-bit range included. */

static void send_vals(int cfd, uint32_t (*fn)(uint32_t), uint32_t base, uint32_t n)
{
    char *b = (char *)malloc((size_t)n * 11 + 64);
    size_t k;
    uint32_t i;
    if (!b) _exit(1);
    k = (size_t)sprintf(b, "{\"ok\":true,\"vals\":[");
    for (i = 0; i < n; i++) k += (size_t)sprintf(b + k, "%s%u", i ? "," : "", fn(base + i));
    k += (size_t)sprintf(b + k, "]}");
    send_line(cfd, b);
    free(b);
}

static uint32_t v_top(uint32_t i) { return 4294967295u - i; }
static uint32_t v_id(uint32_t i)  { return i; }

static int is_rdn(const char *line, uint32_t off, uint32_t n)
{
    char needle[48];
    if (!strstr(line, "\"op\":\"rdn\"") || !has_off(line, off) || !has_die(line, "A")
        || !strstr(line, "\"fix\":true")) return 0;
    snprintf(needle, sizeof needle, "\"n\":%u}", n);
    return strstr(line, needle) != NULL;
}

/* Case 16 (NEW 2026-10-16): a pending wrn is flushed first, then ONE rdn of
 * 5,120 items, values in order up to 2^32-1; the connection stays usable. */
static void broker_rdn_5120(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the pending wrn first");
    BCK(strstr(line, "\"op\":\"wrn\"") != NULL, "not a wrn: %.80s", line);
    BCK(check_vals_seq(line, 7, 3), "wrn vals not 7,8,9: %.80s", line);
    send_line(cfd, "{\"ok\":true}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rdn");
    BCK(is_rdn(line, T_WIN, 5120), "not rdn off=T_WIN fix=true n=5120: %s", line);
    send_vals(cfd, v_top, 0, 5120);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rd32 after");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":5}");
    _exit(0);
}

static void test_rdn_5120(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0, *vals; int rc, bad = 0;
    unsigned i;

    sock_path(path, sizeof path, "rdn5120");
    if (start_broker(path, broker_rdn_5120, &pid) != 0) {
        CK(0, "rdn_5120: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "rdn_5120: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }
    CK(t->reg_read32n != NULL, "rdn_5120: the JC transport does not set reg_read32n");
    vals = (uint32_t *)calloc(5120, sizeof *vals);
    if (!vals || !t->reg_read32n) { t->close(t->ctx); free(t); free(vals); wait_broker(pid, &ec); return; }

    for (i = 7; i < 10; i++) rc = t->reg_write32(t->ctx, T_WIN, i);
    rc = t->reg_read32n(t->ctx, T_WIN, vals, 5120);
    CK(rc == 0, "rdn_5120: reg_read32n rc=%d, expected 0", rc);
    for (i = 0; i < 5120; i++) if (vals[i] != 4294967295u - i) bad++;
    CK(bad == 0, "rdn_5120: %d of 5120 values wrong (vals[0]=%u)", bad, vals[0]);
    rc = t->reg_read32(t->ctx, 0x40, &v);
    CK(rc == 0 && v == 5, "rdn_5120: rd32 after rc=%d val=%u", rc, v);

    t->close(t->ctx); free(t); free(vals);
    CK(wait_broker(pid, &ec) == 0 && ec == 0,
       "rdn_5120: broker script exit=%d (wire format or order was wrong)", ec);
}

/* Case 17 (NEW 2026-10-16): more than the broker's MAX_N (65,536) items
 * splits into two rdns at the same offset, in order. */
static void broker_rdn_split(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rdn 1");
    BCK(is_rdn(line, T_WIN, 65536), "rdn 1 not n=65536: %s", line);
    send_vals(cfd, v_id, 0, 65536);
    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rdn 2");
    BCK(is_rdn(line, T_WIN, 4464), "rdn 2 not n=4464: %s", line);
    send_vals(cfd, v_id, 65536, 4464);
    _exit(0);
}

static void test_rdn_split(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t *vals; int rc, bad = 0;
    unsigned i;

    sock_path(path, sizeof path, "rdnsplit");
    if (start_broker(path, broker_rdn_split, &pid) != 0) {
        CK(0, "rdn_split: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "rdn_split: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }
    vals = (uint32_t *)calloc(70000, sizeof *vals);
    if (!vals || !t->reg_read32n) { t->close(t->ctx); free(t); free(vals); wait_broker(pid, &ec); return; }

    rc = t->reg_read32n(t->ctx, T_WIN, vals, 70000);
    CK(rc == 0, "rdn_split: reg_read32n rc=%d, expected 0", rc);
    for (i = 0; i < 70000; i++) if (vals[i] != i) bad++;
    CK(bad == 0, "rdn_split: %d of 70000 values wrong", bad);

    t->close(t->ctx); free(t); free(vals);
    CK(wait_broker(pid, &ec) == 0 && ec == 0, "rdn_split: broker script exit=%d", ec);
}

/* Case 18 (NEW 2026-10-16): the failure shapes.  The real broker's rdn
 * failure (done_items present) and a wrong-length "vals" are -EIO and do
 * NOT break the connection (the caller re-seeks; pl_backend.c rd_win_n);
 * a malformed array is -EPROTO and does, so the next call sends nothing. */
static void broker_rdn_fail(int cfd)
{
    linebuf lb; char *line; size_t llen;
    lb_init(&lb, cfd);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rdn 1");
    BCK(is_rdn(line, T_WIN, 5120), "rdn 1: %s", line);
    send_line(cfd, "{\"ok\":false,\"err\":\"WindowUnknown: seq 9 in flight; die A window "
                   "state is UNKNOWN\",\"done_items\":496,\"done_items_exact\":false}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected the rd32 (connection still up)");
    BCK(strstr(line, "\"op\":\"rd32\"") != NULL, "not a rd32: %s", line);
    send_line(cfd, "{\"ok\":true,\"val\":3}");

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rdn 2");
    BCK(is_rdn(line, T_WIN, 5120), "rdn 2: %s", line);
    send_vals(cfd, v_id, 0, 5119);

    BCK(lb_getline(&lb, &line, &llen) == 0, "expected rdn 3");
    BCK(is_rdn(line, T_WIN, 3), "rdn 3: %s", line);
    send_line(cfd, "{\"ok\":true,\"vals\":[1,2,\"x\"]}");

    BCK(lb_getline(&lb, &line, &llen) == -2,
        "expected nothing more (connection broken), got: %.80s", line);
    _exit(0);
}

static void test_rdn_fail(void)
{
    char path[600]; pid_t pid; int ec = -1;
    fk33_transport *t; uint32_t v = 0, *vals; int rc;

    sock_path(path, sizeof path, "rdnfail");
    if (start_broker(path, broker_rdn_fail, &pid) != 0) {
        CK(0, "rdn_fail: could not start the fake broker"); return;
    }
    t = fk33_transport_open_jc(path, "A", T_WIN);
    CK(t != NULL, "rdn_fail: fk33_transport_open_jc failed");
    if (!t) { wait_broker(pid, &ec); return; }
    vals = (uint32_t *)calloc(5120, sizeof *vals);
    if (!vals || !t->reg_read32n) { t->close(t->ctx); free(t); free(vals); wait_broker(pid, &ec); return; }

    rc = t->reg_read32n(t->ctx, T_WIN, vals, 5120);
    CK(rc == -EIO, "rdn_fail: done_items failure rc=%d, expected -EIO", rc);
    rc = t->reg_read32(t->ctx, 0x40, &v);
    CK(rc == 0 && v == 3, "rdn_fail: rd32 after an rdn failure rc=%d (connection broken?)", rc);
    rc = t->reg_read32n(t->ctx, T_WIN, vals, 5120);
    CK(rc == -EIO, "rdn_fail: 5119 vals for 5120 rc=%d, expected -EIO", rc);
    rc = t->reg_read32n(t->ctx, T_WIN, vals, 3);
    CK(rc == -EPROTO, "rdn_fail: malformed vals rc=%d, expected -EPROTO", rc);
    rc = t->reg_read32(t->ctx, 0x40, &v);
    CK(rc == -ECONNABORTED, "rdn_fail: call after -EPROTO rc=%d, expected -ECONNABORTED", rc);

    t->close(t->ctx); free(t); free(vals);
    CK(wait_broker(pid, &ec) == 0 && ec == 0, "rdn_fail: broker script exit=%d", ec);
}

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

    test_write_then_read();
    test_ctrl_on_wire_before_return();
    test_coalesce_5120();
    test_split_wrn();
    test_mem_write_refused();
    test_ok_false();
    test_malformed();
    test_broker_closes_mid_reply();
    test_mem_read();
    test_close_flushes();
    test_open_rejects_bad_args();
    test_recv_timeout();
    test_flush_fail_blocks_next_write();
    test_flush_fail_done_items();
    test_shared_connection_interleaved();
    test_rdn_5120();
    test_rdn_split();
    test_rdn_fail();

    /* best-effort cleanup of this run's own scratch directory */
    {
        static const char *names[] = {
            "write_then_read.sock", "ctrl_on_wire.sock", "coalesce.sock",
            "split.sock", "memwrite.sock", "okfalse.sock",
            "malformed_bad_json.sock", "malformed_missing_field.sock",
            "malformed_extra_field.sock",
            "closemid.sock", "memread.sock", "closeflush.sock",
            "timeout.sock", "flushfailwr.sock", "flushfaildi.sock",
            "shared.sock", "rdn5120.sock", "rdnsplit.sock", "rdnfail.sock"
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
