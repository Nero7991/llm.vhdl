/* server/tests/jc_sim_broker.c -- a FAKE tools/jc/jc_broker.py whose dies are
 * the simulated seam (server/fk33_sim.c), for testing run_prompt's --jc path.
 *
 *   jc_sim_broker <sock> <log> [--kv-maxpos N] [--dies A,B]
 *                 [--fail-rd DIE:OFF:NTH:MODE[:TIMES]]
 *                 [--fail-rdn DIE:OFF:NTH:MODE:AT[:TIMES]]
 *                 [--trace FILE] [--loop [--loop-pair A,B [--loop-drop N]]
 *                  [--loop-fail DIE:POS:REASON] [--fail-wr DIE:OFF:NTH:MODE[:TIMES]]]
 *                 [--shape 27b] [--step-model DIE:FILE]
 *
 * Serves the broker's JSON-lines protocol (the subset fk33_transport_jc.c
 * sends: rd32, wr32, wrn with "fix":true, rdn, memrd) on a Unix socket.  Each die
 * named in --dies (default A,B) is its OWN fk33_transport_open_sim() instance
 * with the options run_prompt gives its simulated card under --v2 (version 2,
 * KV_MAXPOS from --kv-maxpos).  A request for any other die is answered
 * {"ok":false,...}, the shape the real broker gives an unknown die.
 *
 * WHAT IT IS FOR.  The same simulated card behind two transports: run_prompt
 * with the sim transport directly, and run_prompt --jc through this broker
 * and fk33_transport_jc.c.  The generated ids must be identical, and the log
 * (one line per request: `die op off_or_addr count`) shows which die every
 * request reached.  It proves the --jc plumbing (option parsing, transport
 * selection, die routing, coalescing, the v2 flow needing no HBM write); it
 * proves nothing about the card's numbers, exactly like the sim itself.
 *
 * FAULT INJECTION (--fail-rd, 2026-10-09).  The real broker answers a read
 * whose frame was in flight when the BMC dropped the link, and whose fate it
 * then cannot prove, with {"ok":false,"err":"WindowUnknown: ..."} (silicon,
 * 2026-10-09, op 3 at 0xe060).  --fail-rd answers the NTH (1-based) rd32 at
 * byte offset OFF on DIE, and the TIMES-1 matching rd32s after it, that way.
 * MODE says what the card saw: `lost` (the read never ran: WIN_ADDR did not
 * move) or `ran` (it ran and advanced WIN_ADDR, and only the answer is lost),
 * the two fates the host cannot tell apart.
 *
 * BULK READS (rdn, 2026-10-16).  {"die":D,"op":"rdn","off":N,"fix":B,"n":K}
 * reads K items at N (fix:true, every item at N: the WIN_DATA window) or at
 * N, N+4, ... (fix:false), and answers {"ok":true,"vals":[...]}, exactly as
 * tools/jc/jc_broker.py's Broker.rdn().  K outside 1..65536 (its MAX_N) is a
 * ValueError, as there.  The log line is `die rdn off K`.
 *
 * --fail-rdn answers the NTH (1-based) rdn at OFF on DIE, and the TIMES-1
 * matching rdns after it, the way the real broker answers a link drop with
 * a frame in flight: the request is cut into frames of 496 items
 * (jc_ctl.MAX_ITEMS), the frames before the one holding item AT (0-based)
 * are done, and that frame's fate is unproven.  The reply is the real
 * broker's _partial() shape for a WindowUnknown on a fixed window:
 *   {"ok":false,"err":"WindowUnknown: ...","done_items":D,"done_items_exact":false}
 * with D = the items of the frames before it.  MODE `lost`: the failing
 * frame never ran (WIN_ADDR moved by D); `ran`: it ran too (WIN_ADDR moved by
 * the end of that frame).  Either way the window moved and only a re-seek
 * makes the next read correct.  The log line is
 * `die rdn off K FAILED mode done=D ran=R` (R = items the sim executed).
 *
 * --trace FILE: one line per register value, `W|R <die> 0x<off> 0x<val>`; wrn
 * and rdn items one line each.
 *
 * THE LOOP MODEL (--loop, plan 2026-11-04 Task 7).  Every die gets a C model of
 * rtl/tok_loop.vhd's host-visible behaviour (tests/jc_sim_loop.c) at 0x20000..0x2FFFF:
 * rd32/wr32/wrn there go to the model, which drives that die's simulated seam itself
 * with tok_loop_fsm's write sequence; while it owns the seam, a host access to
 * 0xE000..0xEFFF is refused (SLVERR), as jc_seam_mux refuses it.  Every model runs
 * until blocked after each loop access and each wrn.  --loop-pair A,B sends A's
 * frames (its R_X row and exponent per position) to B; --loop-drop N corrupts A's
 * Nth frame (B counts a CRC fail and pauses until A's RESEND).  Not an oracle for the
 * RTL (the GHDL benches are): it lets tools/jc/jc_loop.py be tested without hardware.
 * --loop-fail DIE:POS:REASON stops DIE's model with REASON (rtl/tok_loop_pkg.vhd's number,
 * e.g. 5 ENGINE_ERR) when it reaches position POS: a die failing mid-run (final fix pass,
 * 2026-11-11); REASON 0 drops it to IDLE there instead, as a die reset or reloaded mid-run.  --fail-wr DIE:OFF:NTH:MODE[:TIMES] answers the NTH (1-based) wr32 to the
 * loop register at byte offset OFF (0x20000-based) on DIE, and the TIMES-1 matching wr32s
 * after it, with WindowUnknown, as --fail-rd does for reads: MODE `ran` applies the write
 * first (only the answer is lost), `lost` does not.  The log line ends FAILED ran|lost.
 *
 * THE 27B SHAPE (--shape 27b, 2026-11-15).  The sim's default card is the 9B (n_embd 4096,
 * 32 layers, 4096 positions); --shape 27b presents the JC 27B dies' CAPS instead (n_embd 5120,
 * 64 layers, 16384 positions), so run_prompt can be dry-run with the real 27B manifests, the
 * real mv4i embedding and a real 5120-mantissa --x-row file.
 *
 * THE STEP-COUNTER MODEL (--step-model DIE:FILE, 2026-11-15, for the per-step token breakdown
 * sweep).  The sim's CYCLES is 1000 per GO and it has no STEPS_ISS / ISSUE_CYC and no engine
 * map, so a sweep driver that gates on them cannot be dry-run against it.  FILE has one line
 * per descriptor of the FULL token program, `D E`: D = the step's duration in cycles (issue to
 * the next issue), E = the engine CYCLES window (0x12034) the step leaves if it is an A job, or
 * -1.  After a clean GO (STATUS done, no err) with TBL_LEN T, N = T - 1 steps ran and DIE reads
 *     CYCLES    = ISS0 + D[0] + ... + D[N-1] + TAIL
 *     ISSUE_CYC = ISS0 + D[0] + ... + D[N-2]          (the issue of step N-1)
 *     STEPS_ISS = N
 *     0x12034   = E of the last A step below N, 0 if none
 * with ISS0 = 40 and TAIL = 25 (constants a correct analysis recovers without being told).
 * The rd32 log line is the usual one.  It is a model of the CONTRACT the sweep relies on
 * (single-issue, additive steps), not of the card's timing.
 *
 * Prints `JCSIMBROKER_READY <sock>` on stdout once listening.  Serves one
 * client at a time, keeps the dies' state across clients (a card does), and
 * exits on SIGTERM/SIGINT.  NO HARDWARE: no /dev, no coe.py, no BMC.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "../fk33_transport.h"
#include "../fk33_seam.h"
#include "jc_sim_loop.h"

#define MAX_DIES 4

/* --step-model: per-die step durations and engine windows (see the header) */
#define SM_ISS0 40ll
#define SM_TAIL 25ll
static long long *g_sm_d[MAX_DIES], *g_sm_e[MAX_DIES];
static int g_sm_n[MAX_DIES];

static fk33_transport *g_t[MAX_DIES];
static jc_loop *g_loop[MAX_DIES];    /* --loop: a C model of tok_loop at 0x20000 per die */
static char g_name[MAX_DIES][16];
static int g_ndies;
static FILE *g_log;
static char g_fail_die[16];
static unsigned long g_fail_off, g_fail_nth, g_fail_times = 1, g_fail_seen;
static int g_fail_ran = -1;          /* -1: no injection */
static char g_failn_die[16];
static unsigned long g_failn_off, g_failn_nth, g_failn_at, g_failn_times = 1, g_failn_seen;
static int g_failn_ran = -1;         /* -1: no rdn injection */
static FILE *g_trace;                /* --trace: every register value, for tools/jc/gen_tok_loop_vec.py */
static char g_failw_die[16];
static unsigned long g_failw_off, g_failw_nth, g_failw_times = 1, g_failw_seen;
static int g_failw_ran = -1;         /* -1: no wr32 injection (--fail-wr, loop window only) */

#define SIM_MAX_N     65536ul        /* jc_broker.py MAX_N */
#define SIM_MAX_ITEMS 496ul          /* jc_ctl.MAX_ITEMS: items per frame */

static int find_die(const char *line, int *idx)
{
    const char *p = strstr(line, "\"die\":\"");
    char d[16];
    size_t k = 0;
    int i;
    if (!p) return -1;
    p += 7;
    while (*p && *p != '"' && k + 1 < sizeof d) d[k++] = *p++;
    d[k] = 0;
    for (i = 0; i < g_ndies; i++)
        if (!strcmp(d, g_name[i])) { *idx = i; return 0; }
    return -1;
}

static int get_num(const char *line, const char *key, unsigned long long *v)
{
    char pat[32];
    const char *p;
    char *end;
    snprintf(pat, sizeof pat, "\"%s\":", key);
    p = strstr(line, pat);
    if (!p) return -1;
    p += strlen(pat);
    *v = strtoull(p, &end, 10);
    return end == p ? -1 : 0;
}

static int has_op(const char *line, const char *op)
{
    char pat[32];
    snprintf(pat, sizeof pat, "\"op\":\"%s\"", op);
    return strstr(line, pat) != NULL;
}

static void send_all(int fd, const char *s, size_t n)
{
    while (n) {
        ssize_t w = write(fd, s, n);
        if (w < 0) { if (errno == EINTR) continue; return; }
        s += w; n -= (size_t)w;
    }
}

static void reply(int fd, const char *s) { send_all(fd, s, strlen(s)); }

/* --step-model: answer CYCLES, STEPS_ISS, ISSUE_CYC and engine 0x12034 for die d from the
 * table, once a clean GO has run.  Returns 0 with *v set, or -1 to fall through to the sim. */
static int step_model(int d, unsigned long long off, uint32_t *v)
{
    uint32_t st = 0, tl = 0;
    long long acc = SM_ISS0, last_e = 0;
    int n, k;
    if (off != FK33_SEAM_BASE + FK33_SEAM_CYCLES && off != FK33_SEAM_BASE + FK33_SEAM_STEPS_ISS
        && off != FK33_SEAM_BASE + FK33_SEAM_ISSUE_CYC && off != 0x12034ull)
        return -1;
    if (g_t[d]->reg_read32(g_t[d]->ctx, FK33_SEAM_BASE + FK33_SEAM_STATUS, &st)
        || g_t[d]->reg_read32(g_t[d]->ctx, FK33_SEAM_BASE + FK33_SEAM_TBL_LEN, &tl))
        return -1;
    n = (int)tl - 1;
    if (!(st & FK33_ST_DONE) || (st & FK33_ST_ERR) || n < 1 || n > g_sm_n[d]) {
        if (off == 0x12034ull) { *v = 0; return 0; }
        return -1;
    }
    for (k = 0; k < n - 1; k++) { acc += g_sm_d[d][k]; if (g_sm_e[d][k] >= 0) last_e = g_sm_e[d][k]; }
    if (g_sm_e[d][n - 1] >= 0) last_e = g_sm_e[d][n - 1];
    if (off == FK33_SEAM_BASE + FK33_SEAM_ISSUE_CYC) *v = (uint32_t)acc;
    else if (off == FK33_SEAM_BASE + FK33_SEAM_CYCLES) *v = (uint32_t)(acc + g_sm_d[d][n - 1] + SM_TAIL);
    else if (off == FK33_SEAM_BASE + FK33_SEAM_STEPS_ISS) *v = (uint32_t)n;
    else *v = (uint32_t)last_e;
    return 0;
}

static int load_step_model(const char *spec)
{
    char die[16], path[512];
    FILE *f;
    long long dd, ee;
    int k, cap = 0;
    if (sscanf(spec, "%15[^:]:%511s", die, path) != 2) return -1;
    for (k = 0; k < g_ndies; k++) if (!strcmp(g_name[k], die)) break;
    if (k == g_ndies || !(f = fopen(path, "r"))) return -1;
    while (fscanf(f, "%lld %lld", &dd, &ee) == 2) {
        if (g_sm_n[k] == cap) {
            cap = cap ? 2 * cap : 1024;
            g_sm_d[k] = (long long *)realloc(g_sm_d[k], (size_t)cap * sizeof(long long));
            g_sm_e[k] = (long long *)realloc(g_sm_e[k], (size_t)cap * sizeof(long long));
            if (!g_sm_d[k] || !g_sm_e[k]) { fclose(f); return -1; }
        }
        g_sm_d[k][g_sm_n[k]] = dd; g_sm_e[k][g_sm_n[k]] = ee; g_sm_n[k]++;
    }
    fclose(f);
    return g_sm_n[k] ? 0 : -1;
}

static void handle(int fd, const char *line)
{
    int d;
    unsigned long long off = 0, val = 0, addr = 0, n = 0;
    char buf[256];
    if (find_die(line, &d)) {
        reply(fd, "{\"ok\":false,\"err\":\"KeyError: unknown die\"}\n");
        fprintf(g_log, "? refused %s\n", line);
        return;
    }
    if (g_loop[d]) {
        unsigned long long o = 0, vv = 0;
        int is_rd = has_op(line, "rd32"), is_wr = has_op(line, "wr32"), k;
        if ((is_rd || is_wr) && !get_num(line, "off", &o) && o >= JC_LOOP_BASE && o < JC_LOOP_BASE + JC_LOOP_SPAN) {
            uint32_t v = 0;
            if (is_rd) {
                jc_loop_rd(g_loop[d], (uint32_t)(o - JC_LOOP_BASE), &v);
                snprintf(buf, sizeof buf, "{\"ok\":true,\"val\":%u}\n", v);
            } else if (g_failw_ran >= 0 && !strcmp(g_name[d], g_failw_die) && o == g_failw_off
                       && ++g_failw_seen >= g_failw_nth && g_failw_seen < g_failw_nth + g_failw_times) {
                get_num(line, "val", &vv);
                if (g_failw_ran) jc_loop_wr(g_loop[d], (uint32_t)(o - JC_LOOP_BASE), (uint32_t)vv);
                for (k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
                for (k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
                fprintf(g_log, "%s loop wr32 0x%llx FAILED %s\n", g_name[d], o, g_failw_ran ? "ran" : "lost");
                snprintf(buf, sizeof buf, "{\"ok\":false,\"err\":\"WindowUnknown: injected: die %s "
                         "wr32 at %#llx; die %s window state is UNKNOWN\"}\n", g_name[d], o, g_name[d]);
                reply(fd, buf); fflush(g_log); return;
            } else {
                get_num(line, "val", &vv);
                jc_loop_wr(g_loop[d], (uint32_t)(o - JC_LOOP_BASE), (uint32_t)vv);
                snprintf(buf, sizeof buf, "{\"ok\":true}\n");
            }
            fprintf(g_log, "%s loop %s 0x%llx\n", g_name[d], is_rd ? "rd32" : "wr32", o);
            for (k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
            for (k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]);
            reply(fd, buf); fflush(g_log); return;
        }
        if (jc_loop_owns_seam(g_loop[d]) && !get_num(line, "off", &o) && o >= 0xE000 && o < 0xF000) {
            fprintf(g_log, "%s refused seam 0x%llx (loop owns it)\n", g_name[d], o);
            reply(fd, "{\"ok\":false,\"err\":\"AxiError: SLVERR (tok_loop owns the seam)\"}\n");
            fflush(g_log);
            return;
        }
    }
    if (has_op(line, "rd32") && !get_num(line, "off", &off)) {
        uint32_t v = 0;
        int rc;
        if (g_fail_ran >= 0 && !strcmp(g_name[d], g_fail_die) && off == g_fail_off
            && ++g_fail_seen >= g_fail_nth && g_fail_seen < g_fail_nth + g_fail_times) {
            if (g_fail_ran) (void)g_t[d]->reg_read32(g_t[d]->ctx, (uint32_t)off, &v);
            fprintf(g_log, "%s rd32 0x%llx 1 FAILED %s\n", g_name[d], off,
                    g_fail_ran ? "ran" : "lost");
            fflush(g_log);
            snprintf(buf, sizeof buf, "{\"ok\":false,\"err\":\"WindowUnknown: injected: "
                     "die %s rd32 at %#llx; die %s window state is UNKNOWN\"}\n",
                     g_name[d], off, g_name[d]);
            reply(fd, buf);
            return;
        }
        if (g_sm_d[d] && step_model(d, off, &v) == 0) rc = 0;
        else rc = g_t[d]->reg_read32(g_t[d]->ctx, (uint32_t)off, &v);
        fprintf(g_log, "%s rd32 0x%llx 1\n", g_name[d], off);
        if (rc) { reply(fd, "{\"ok\":false,\"err\":\"AxiError: sim read\"}\n"); return; }
        if (g_trace) fprintf(g_trace, "R %s 0x%llx 0x%x\n", g_name[d], off, v);
        snprintf(buf, sizeof buf, "{\"ok\":true,\"val\":%u}\n", v);
        reply(fd, buf);
    } else if (has_op(line, "wr32") && !get_num(line, "off", &off) && !get_num(line, "val", &val)) {
        int rc = g_t[d]->reg_write32(g_t[d]->ctx, (uint32_t)off, (uint32_t)val);
        fprintf(g_log, "%s wr32 0x%llx 1\n", g_name[d], off);
        if (g_trace && !rc) fprintf(g_trace, "W %s 0x%llx 0x%llx\n", g_name[d], off, val);
        reply(fd, rc ? "{\"ok\":false,\"err\":\"AxiError: sim write\"}\n" : "{\"ok\":true}\n");
    } else if (has_op(line, "wrn") && !get_num(line, "off", &off)
               && strstr(line, "\"fix\":true")) {
        const char *p = strstr(line, "\"vals\":[");
        unsigned long cnt = 0;
        int rc = 0;
        if (!p) { reply(fd, "{\"ok\":false,\"err\":\"ValueError: no vals\"}\n"); return; }
        p += 8;
        while (*p && *p != ']') {
            char *end;
            unsigned long long v = strtoull(p, &end, 10);
            if (end == p) { rc = -1; break; }
            if (!rc) rc = (g_loop[d] && off >= JC_LOOP_BASE && off < JC_LOOP_BASE + JC_LOOP_SPAN)
                          ? jc_loop_wr(g_loop[d], (uint32_t)(off - JC_LOOP_BASE), (uint32_t)v)
                          : g_t[d]->reg_write32(g_t[d]->ctx, (uint32_t)off, (uint32_t)v);
            if (g_trace) fprintf(g_trace, "W %s 0x%llx 0x%llx\n", g_name[d], off, v);
            cnt++;
            p = end;
            if (*p == ',') p++;
        }
        fprintf(g_log, "%s wrn 0x%llx %lu\n", g_name[d], off, cnt);
        { int k; for (k = 0; k < g_ndies; k++) if (g_loop[k]) jc_loop_tick(g_loop[k]); }
        reply(fd, rc ? "{\"ok\":false,\"err\":\"AxiError: sim wrn\"}\n" : "{\"ok\":true}\n");
    } else if (has_op(line, "rdn") && !get_num(line, "off", &off) && !get_num(line, "n", &n)) {
        int fix = strstr(line, "\"fix\":true") != NULL;
        unsigned long long i, run_n = n, done = 0;
        uint32_t *vals;
        char *h;
        size_t k;
        int rc = 0, inject = 0;
        if (!fix && !strstr(line, "\"fix\":false")) {
            reply(fd, "{\"ok\":false,\"err\":\"ValueError: fix must be true or false\"}\n");
            return;
        }
        if (n < 1 || n > SIM_MAX_N) {
            snprintf(buf, sizeof buf, "{\"ok\":false,\"err\":\"ValueError: n must be 1..%lu, "
                     "got %llu\"}\n", SIM_MAX_N, n);
            reply(fd, buf);
            return;
        }
        if (g_failn_ran >= 0 && !strcmp(g_name[d], g_failn_die) && off == g_failn_off
            && ++g_failn_seen >= g_failn_nth && g_failn_seen < g_failn_nth + g_failn_times) {
            unsigned long long at = g_failn_at < n ? g_failn_at : n - 1;
            done = at / SIM_MAX_ITEMS * SIM_MAX_ITEMS;
            run_n = g_failn_ran ? (done + SIM_MAX_ITEMS < n ? done + SIM_MAX_ITEMS : n) : done;
            inject = 1;
        }
        vals = (uint32_t *)malloc((size_t)n * sizeof *vals);
        h = (char *)malloc((size_t)n * 11 + 64);
        if (!vals || !h) { free(vals); free(h); reply(fd, "{\"ok\":false,\"err\":\"MemoryError\"}\n"); return; }
        for (i = 0; i < run_n; i++) {
            rc = g_t[d]->reg_read32(g_t[d]->ctx, (uint32_t)(fix ? off : off + 4 * i), &vals[i]);
            if (rc) { done = i / SIM_MAX_ITEMS * SIM_MAX_ITEMS; break; }
        }
        if (inject) {
            fprintf(g_log, "%s rdn 0x%llx %llu FAILED %s done=%llu ran=%llu\n", g_name[d], off, n,
                    g_failn_ran ? "ran" : "lost", done, run_n);
            fflush(g_log);
            snprintf(buf, sizeof buf, "{\"ok\":false,\"err\":\"WindowUnknown: injected: die %s "
                     "rdn at %#llx; die %s window state is UNKNOWN\",\"done_items\":%llu,"
                     "\"done_items_exact\":false}\n", g_name[d], off, g_name[d], done);
            reply(fd, buf);
            free(vals); free(h);
            return;
        }
        fprintf(g_log, "%s rdn 0x%llx %llu\n", g_name[d], off, n);
        if (rc) {
            snprintf(buf, sizeof buf, "{\"ok\":false,\"err\":\"WindowUnknown: sim read; die %s "
                     "window state is UNKNOWN\",\"done_items\":%llu,\"done_items_exact\":false}\n",
                     g_name[d], done);
            reply(fd, buf);
            free(vals); free(h);
            return;
        }
        if (g_trace) for (i = 0; i < n; i++) fprintf(g_trace, "R %s 0x%llx 0x%x\n", g_name[d], off, vals[i]);
        k = (size_t)sprintf(h, "{\"ok\":true,\"vals\":[");
        for (i = 0; i < n; i++) k += (size_t)sprintf(h + k, "%s%u", i ? "," : "", vals[i]);
        k += (size_t)sprintf(h + k, "]}\n");
        send_all(fd, h, k);
        free(vals); free(h);
    } else if (has_op(line, "memrd") && !get_num(line, "addr", &addr) && !get_num(line, "n", &n)) {
        unsigned char *b = (unsigned char *)malloc(n ? n : 1);
        char *h = (char *)malloc(2 * n + 32);
        size_t i, k;
        fprintf(g_log, "%s memrd 0x%llx %llu\n", g_name[d], addr, n);
        if (!b || !h || g_t[d]->mem_read(g_t[d]->ctx, addr, b, n)) {
            free(b); free(h);
            reply(fd, "{\"ok\":false,\"err\":\"AxiError: sim memrd\"}\n");
            return;
        }
        k = (size_t)sprintf(h, "{\"ok\":true,\"hex\":\"");
        for (i = 0; i < n; i++) k += (size_t)sprintf(h + k, "%02x", b[i]);
        k += (size_t)sprintf(h + k, "\"}\n");
        send_all(fd, h, k);
        free(b); free(h);
    } else {
        fprintf(g_log, "%s unknown %s\n", g_name[d], line);
        reply(fd, "{\"ok\":false,\"err\":\"ValueError: unknown op\"}\n");
    }
    fflush(g_log);
    if (g_trace) fflush(g_trace);
}

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

int main(int argc, char **argv)
{
    const char *sock, *logp, *dies = "A,B";
    unsigned long kv_maxpos = 16384;
    struct sockaddr_un a;
    struct sigaction sa;
    int ls, i;
    int loop_on = 0;
    const char *loop_pair = NULL;
    unsigned long loop_drop = 0;
    char lf_die[16] = "";
    unsigned long lf_pos = 0, lf_reason = 0;
    int shape27 = 0, n_sm = 0;
    const char *sm_spec[MAX_DIES];
    if (argc < 3) {
        fprintf(stderr, "usage: jc_sim_broker <sock> <log> [--kv-maxpos N] [--dies A,B] "
                "[--fail-rd DIE:OFF:NTH:MODE[:TIMES]] [--fail-rdn DIE:OFF:NTH:MODE:AT[:TIMES]] "
                "[--trace FILE] [--loop [--loop-pair A,B [--loop-drop N]] "
                "[--loop-fail DIE:POS:REASON] [--fail-wr DIE:OFF:NTH:MODE[:TIMES]]] "
                "[--shape 27b] [--step-model DIE:FILE]\n");
        return 2;
    }
    sock = argv[1]; logp = argv[2];
    /* --loop takes no value; the option loop below reads pairs, so take it out first */
    for (i = 3; i < argc; i++)
        if (!strcmp(argv[i], "--loop")) {
            loop_on = 1;
            memmove(&argv[i], &argv[i + 1], (size_t)(argc - i - 1) * sizeof *argv);
            argc--; i--;
        }
    for (i = 3; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--kv-maxpos")) kv_maxpos = strtoul(argv[i + 1], NULL, 10);
        else if (!strcmp(argv[i], "--dies")) dies = argv[i + 1];
        else if (!strcmp(argv[i], "--fail-rd")) {
            char mode[8] = "";
            int k = sscanf(argv[i + 1], "%15[^:]:%li:%lu:%7[^:]:%lu", g_fail_die,
                           (long *)&g_fail_off, &g_fail_nth, mode, &g_fail_times);
            if (k < 4 || g_fail_nth < 1 || g_fail_times < 1
                || (strcmp(mode, "ran") && strcmp(mode, "lost"))) {
                fprintf(stderr, "jc_sim_broker: --fail-rd DIE:OFF:NTH:ran|lost[:TIMES]\n");
                return 2;
            }
            g_fail_ran = !strcmp(mode, "ran");
        }
        else if (!strcmp(argv[i], "--fail-rdn")) {
            char mode[8] = "";
            int k = sscanf(argv[i + 1], "%15[^:]:%li:%lu:%7[^:]:%lu:%lu", g_failn_die,
                           (long *)&g_failn_off, &g_failn_nth, mode, &g_failn_at,
                           &g_failn_times);
            if (k < 5 || g_failn_nth < 1 || g_failn_times < 1
                || (strcmp(mode, "ran") && strcmp(mode, "lost"))) {
                fprintf(stderr, "jc_sim_broker: --fail-rdn DIE:OFF:NTH:ran|lost:AT[:TIMES]\n");
                return 2;
            }
            g_failn_ran = !strcmp(mode, "ran");
        }
        else if (!strcmp(argv[i], "--trace")) {
            g_trace = fopen(argv[i + 1], "w");
            if (!g_trace) { perror(argv[i + 1]); return 2; }
        }
        else if (!strcmp(argv[i], "--loop-pair")) loop_pair = argv[i + 1];
        else if (!strcmp(argv[i], "--loop-drop")) loop_drop = strtoul(argv[i + 1], NULL, 10);
        else if (!strcmp(argv[i], "--loop-fail")) {
            if (sscanf(argv[i + 1], "%15[^:]:%lu:%lu", lf_die, &lf_pos, &lf_reason) != 3
                || lf_reason > 12) {
                fprintf(stderr, "jc_sim_broker: --loop-fail DIE:POS:REASON (0..12)\n");
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--fail-wr")) {
            char mode[8] = "";
            int k = sscanf(argv[i + 1], "%15[^:]:%li:%lu:%7[^:]:%lu", g_failw_die,
                           (long *)&g_failw_off, &g_failw_nth, mode, &g_failw_times);
            if (k < 4 || g_failw_nth < 1 || g_failw_times < 1
                || (strcmp(mode, "ran") && strcmp(mode, "lost"))) {
                fprintf(stderr, "jc_sim_broker: --fail-wr DIE:OFF:NTH:ran|lost[:TIMES]\n");
                return 2;
            }
            g_failw_ran = !strcmp(mode, "ran");
        }
        else if (!strcmp(argv[i], "--shape")) {
            if (strcmp(argv[i + 1], "27b")) { fprintf(stderr, "jc_sim_broker: --shape 27b\n"); return 2; }
            shape27 = 1;
        }
        else if (!strcmp(argv[i], "--step-model")) {
            if (n_sm >= MAX_DIES) { fprintf(stderr, "jc_sim_broker: too many --step-model\n"); return 2; }
            sm_spec[n_sm++] = argv[i + 1];
        }
        else { fprintf(stderr, "jc_sim_broker: unknown %s\n", argv[i]); return 2; }
    }
    {
        char tmp[64];
        char *tok, *save = NULL;
        snprintf(tmp, sizeof tmp, "%s", dies);
        for (tok = strtok_r(tmp, ",", &save); tok && g_ndies < MAX_DIES;
             tok = strtok_r(NULL, ",", &save)) {
            fk33_sim_opts o;
            fk33_sim_opts_default(&o);
            o.version = 2;
            o.kv_maxpos = (uint32_t)kv_maxpos;
            if (shape27) { o.n_embd = 5120; o.n_layer = 64; o.max_ctx = 16384; }
            snprintf(g_name[g_ndies], sizeof g_name[0], "%s", tok);
            g_t[g_ndies] = fk33_transport_open_sim(&o);
            if (!g_t[g_ndies]) { fprintf(stderr, "jc_sim_broker: sim open failed\n"); return 1; }
            g_ndies++;
        }
    }
    for (i = 0; i < n_sm; i++)
        if (load_step_model(sm_spec[i])) {
            fprintf(stderr, "jc_sim_broker: --step-model %s: want DIE:FILE of `D E` lines for a die in --dies\n", sm_spec[i]);
            return 2;
        }
    if ((loop_pair || loop_drop) && !loop_on) {
        fprintf(stderr, "jc_sim_broker: --loop-pair/--loop-drop need --loop\n"); return 2;
    }
    if ((lf_die[0] || g_failw_ran >= 0) && !loop_on) {
        fprintf(stderr, "jc_sim_broker: --loop-fail/--fail-wr need --loop\n"); return 2;
    }
    if (loop_drop && !loop_pair) {
        fprintf(stderr, "jc_sim_broker: --loop-drop needs --loop-pair\n"); return 2;
    }
    if (loop_on) {
        for (i = 0; i < g_ndies; i++) {
            g_loop[i] = jc_loop_new(g_t[i], shape27 ? 5120 : 4096);   /* the sim's n_embd */
            if (!g_loop[i]) { fprintf(stderr, "jc_sim_broker: loop model alloc failed\n"); return 1; }
        }
        if (loop_pair) {
            char pa[16] = "", pb[16] = "";
            int ia = -1, ib = -1, k;
            if (sscanf(loop_pair, "%15[^,],%15s", pa, pb) != 2) {
                fprintf(stderr, "jc_sim_broker: --loop-pair A,B\n"); return 2;
            }
            for (k = 0; k < g_ndies; k++) {
                if (!strcmp(g_name[k], pa)) ia = k;
                if (!strcmp(g_name[k], pb)) ib = k;
            }
            if (ia < 0 || ib < 0 || ia == ib) {
                fprintf(stderr, "jc_sim_broker: --loop-pair names an unknown die\n"); return 2;
            }
            jc_loop_pair(g_loop[ia], g_loop[ib]);
            if (loop_drop) jc_loop_drop(g_loop[ia], loop_drop);
        }
        if (lf_die[0]) {
            int k, hit = 0;
            for (k = 0; k < g_ndies; k++)
                if (!strcmp(g_name[k], lf_die)) { jc_loop_fail_at(g_loop[k], (uint32_t)lf_pos, (uint32_t)lf_reason); hit = 1; }
            if (!hit) { fprintf(stderr, "jc_sim_broker: --loop-fail names an unknown die\n"); return 2; }
        }
    }
    g_log = fopen(logp, "w");
    if (!g_log) { perror(logp); return 1; }

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sig;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    ls = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (strlen(sock) >= sizeof a.sun_path) { fprintf(stderr, "socket path too long\n"); return 1; }
    strcpy(a.sun_path, sock);
    unlink(sock);
    if (ls < 0 || bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 1)) {
        perror("jc_sim_broker: bind/listen");
        return 1;
    }
    printf("JCSIMBROKER_READY %s\n", sock);
    fflush(stdout);

    while (!g_stop) {
        int cfd = accept(ls, NULL, NULL);
        char *buf;
        size_t len = 0, cap = 1 << 20;
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        buf = (char *)malloc(cap);
        for (;;) {
            char *nl;
            ssize_t r;
            while ((nl = memchr(buf, '\n', len)) != NULL) {
                size_t ll = (size_t)(nl - buf);
                *nl = 0;
                handle(cfd, buf);
                memmove(buf, nl + 1, len - ll - 1);
                len -= ll + 1;
            }
            if (len == cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
            r = read(cfd, buf + len, cap - len);
            if (r < 0 && errno == EINTR) { if (g_stop) break; continue; }
            if (r <= 0) break;
            len += (size_t)r;
        }
        free(buf);
        close(cfd);
        fprintf(g_log, "- client closed\n");
        fflush(g_log);
    }
    close(ls);
    unlink(sock);
    for (i = 0; i < g_ndies; i++) g_t[i]->close(g_t[i]->ctx);
    if (g_trace) fclose(g_trace);
    fclose(g_log);
    return 0;
}
