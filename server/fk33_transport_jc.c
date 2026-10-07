/* fk33_transport_jc.c -- the Jungle Cat transport: JSON lines over a Unix
 * socket to tools/jc/jc_broker.py.  See the "THE JUNGLE CAT TRANSPORT"
 * comment in fk33_transport.h for why this exists instead of a chardev.
 *
 * THE WIRE PROTOCOL (docs/superpowers/plans/2026-10-07-jc-engine-composition.md,
 * Task 6; field names taken from tools/jc/jc_broker.py's Broker.handle()).
 * One JSON object per line, sent and answered in strict order -- the broker
 * serves one client, one request at a time, so this file never needs to
 * pipeline or tag a reply back to its request.
 *
 *   {"die":D,"op":"rd32","off":N}                  -> {"ok":true,"val":V}
 *   {"die":D,"op":"wrn","off":N,"fix":true,"vals":[...]} -> {"ok":true}
 *   {"die":D,"op":"memrd","addr":A,"n":K}           -> {"ok":true,"hex":".."}
 *   anything else                                   -> {"ok":false,"err":".."}
 *
 * COALESCING.  pl_backend.c pushes and reads a card row through the
 * FK33_SEAM_WIN_DATA register one 32-bit word at a time: n_embd writes in a
 * row to the exact same BAR offset on the way in (server/pl_backend.c
 * push_row(), pl_push_embedding()), and n_embd reads in a row from the exact
 * same offset on the way out (pl_read_xout()).  This file turns a run of
 * reg_write32() calls that all land on the same offset into ONE `wrn` with
 * `fix:true` covering the whole run -- one socket round trip where the naive
 * translation would be n_embd of them.
 *
 * A READ run is deliberately NOT coalesced.  WIN_DATA is a read-and-advance
 * window: reading element k+1 before the caller has asked for it is reading a
 * register that has not been "asked for" yet, and speculative reads of a
 * stateful window are exactly the shape of bug this project keeps finding
 * (see docs/WORKLOG.md on coalesced reads getting the order wrong). So every
 * reg_read32() issues its own `rd32`, full stop. THE COST OF THAT CORRECTNESS:
 * an n_embd read-out run costs n_embd round trips here, the same as if no
 * transport existed at all. That cost is accepted on purpose; see brief
 * Task 7.
 *
 * FLUSH TIMING, AND WHICH OF THE BRIEF'S TWO OPTIONS THIS FILE TAKES.
 * The brief allows either "a flush failure is reported on the next call" or,
 * better, "the write that triggers the flush reports it". This file always
 * flushes SYNCHRONOUSLY, as the first thing done by whichever call ends the
 * run: a reg_write32() to a different offset, any reg_read32(), mem_read(),
 * mem_write(), or close(). If that flush fails, THAT call returns the
 * flush's error and never attempts its own operation. Because a flush here
 * only ever happens as the first step of handling some "next call", the two
 * descriptions in the brief describe the same observable behaviour in this
 * file, and this is the more specific ("better still") one: there is no
 * separate deferred-error slot, the very call that ends the run IS the
 * report.  The one exception is mem_write(), which is unconditionally
 * refused with -EPERM regardless of whether its own flush attempt
 * succeeded -- see the note on jc_mem_write() below.
 *
 * SIZE BOUND.  A coalesced run is capped at JC_WRN_MAX values; a longer run
 * is flushed early and a new run started, so it becomes two (or more) `wrn`
 * requests rather than one. JC_WRN_MAX (8192) sits comfortably above the one
 * run size this backend ever actually produces -- n_embd items, 5,120 for the
 * shipped 9B shape -- and well under the broker's own MAX_N (65,536), so
 * ordinary operation never splits and the split path exists for whatever
 * wider row drives this transport later.
 *
 * ERROR CODES.  All four struct functions return 0 or a negative
 * errno-like code, per fk33_transport.h:
 *   -EPERM   mem_write(), always (the loader is the only HBM writer).
 *   -EPROTO  a reply that is not a single well-formed, schema-matching
 *            JSON object for the op that asked (wrong/missing/extra
 *            fields, bad JSON, or a reply line over JC_LINE_MAX).
 *   -EIO     a reply that parsed and said {"ok":false,...}, a memrd whose
 *            "hex" was the wrong length (the memrd equivalent of a short
 *            transfer), or a connection that closed before a full line
 *            arrived.
 *   -errno   straight from a failing send()/recv()/socket()/connect().
 *
 * The JSON here is small, flat, and never nested (no reply this file reads
 * contains an array or a sub-object), so it is parsed by a minimal
 * hand-written scanner below rather than pulling in a JSON library -- per
 * the brief.  It is STRICT: an unexpected extra field, a missing required
 * one, or a line over the bound is -EPROTO, not a best-effort skip.  No
 * input, however malformed, is allowed to crash this file; every scan
 * function takes an explicit length and never reads past it.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>

#include "fk33_transport.h"

/* ---------------------------------------------------------------- tuning */

#define JC_DIE_MAX      15u          /* max chars in a die identifier */
#define JC_WRN_MAX      8192u        /* values per coalesced wrn; see header */
#define JC_LINE_MAX     (8u << 20)   /* bytes of one reply line we will buffer */
#define JC_MEMRD_CHUNK  (1u << 20)   /* bytes per memrd request we issue */
#define JC_MAX_FIELDS   8            /* top-level keys a reply may have */
#define JC_MAX_KEY      16           /* bytes, including NUL, per key */

#define JC_ERR_PROTO    (-EPROTO)    /* malformed / schema-violating reply */
#define JC_ERR_FALSE    (-EIO)       /* a well-formed {"ok":false,...} */
#define JC_ERR_CLOSED   (-EIO)       /* socket closed before a full line */

/* --------------------------------------------------------- the minimal JSON
 * scanner.  Flat objects only: no value here is ever an array or a nested
 * object, because no reply this file reads needs one. */

typedef enum { JVT_NULL, JVT_BOOL, JVT_NUM, JVT_STR } jv_type;

typedef struct {
    char    key[JC_MAX_KEY];
    jv_type type;
    int     bval;
    double  nval;
    char   *sval;   /* malloc'd, NUL-terminated; only when type == JVT_STR */
    size_t  slen;
} jv_field;

typedef struct {
    jv_field f[JC_MAX_FIELDS];
    int      n;
} jv_obj;

typedef struct {
    const char *s;
    size_t      len;
    size_t      i;
} jscan;

static void jv_obj_free(jv_obj *o)
{
    int i;
    for (i = 0; i < o->n; i++)
        if (o->f[i].type == JVT_STR) free(o->f[i].sval);
    o->n = 0;
}

static int jv_find(const jv_obj *o, const char *key)
{
    int i;
    for (i = 0; i < o->n; i++)
        if (!strcmp(o->f[i].key, key)) return i;
    return -1;
}

static void sk_ws(jscan *c)
{
    while (c->i < c->len &&
           (c->s[c->i] == ' ' || c->s[c->i] == '\t' ||
            c->s[c->i] == '\r' || c->s[c->i] == '\n'))
        c->i++;
}

static int sk_ch(const jscan *c)
{
    return c->i < c->len ? (unsigned char)c->s[c->i] : -1;
}

/* Parses one JSON string starting at the current '"'.  Returns a malloc'd,
 * NUL-terminated, unescaped buffer in out/outlen, or -1 on any malformed
 * input (unterminated, raw control byte, bad escape, truncated \u).  \u is
 * encoded as UTF-8; a lone surrogate half (0xD800-0xDFFF) becomes U+FFFD
 * rather than being paired up, which this file's replies never need (broker
 * error text is plain exception text). */
static int jv_parse_string(jscan *c, char **out, size_t *outlen)
{
    size_t cap = 32, len = 0;
    char *buf;

    if (sk_ch(c) != '"') return -1;
    c->i++;
    buf = (char *)malloc(cap);
    if (!buf) return -1;

    for (;;) {
        unsigned char ch;
        if (c->i >= c->len) { free(buf); return -1; }
        ch = (unsigned char)c->s[c->i++];
        if (ch == '"') break;
        if (ch < 0x20) { free(buf); return -1; }
        if (ch == '\\') {
            unsigned char e;
            unsigned int cp;
            if (c->i >= c->len) { free(buf); return -1; }
            e = (unsigned char)c->s[c->i++];
            switch (e) {
            case '"':  ch = '"';  break;
            case '\\': ch = '\\'; break;
            case '/':  ch = '/';  break;
            case 'b':  ch = '\b'; break;
            case 'f':  ch = '\f'; break;
            case 'n':  ch = '\n'; break;
            case 'r':  ch = '\r'; break;
            case 't':  ch = '\t'; break;
            case 'u': {
                int k;
                if (c->i + 4 > c->len) { free(buf); return -1; }
                cp = 0;
                for (k = 0; k < 4; k++) {
                    char hc = c->s[c->i++];
                    unsigned int d;
                    if (hc >= '0' && hc <= '9') d = (unsigned)(hc - '0');
                    else if (hc >= 'a' && hc <= 'f') d = (unsigned)(hc - 'a') + 10;
                    else if (hc >= 'A' && hc <= 'F') d = (unsigned)(hc - 'A') + 10;
                    else { free(buf); return -1; }
                    cp = (cp << 4) | d;
                }
                if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
                if (len + 3 + 1 > cap) {
                    size_t nc = cap * 2;
                    char *nb = (char *)realloc(buf, nc);
                    if (!nb) { free(buf); return -1; }
                    buf = nb; cap = nc;
                }
                if (cp < 0x80) {
                    buf[len++] = (char)cp;
                } else if (cp < 0x800) {
                    buf[len++] = (char)(0xC0 | (cp >> 6));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                } else {
                    buf[len++] = (char)(0xE0 | (cp >> 12));
                    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (char)(0x80 | (cp & 0x3F));
                }
                continue;
            }
            default: free(buf); return -1;
            }
        }
        if (len + 1 > cap) {
            size_t nc = cap * 2;
            char *nb = (char *)realloc(buf, nc);
            if (!nb) { free(buf); return -1; }
            buf = nb; cap = nc;
        }
        buf[len++] = (char)ch;
    }
    if (len + 1 > cap) {
        char *nb = (char *)realloc(buf, len + 1);
        if (!nb) { free(buf); return -1; }
        buf = nb;
    }
    buf[len] = 0;
    *out = buf; *outlen = len;
    return 0;
}

/* Non-negative or negative decimal, optional fraction/exponent -- the JSON
 * number grammar, no more.  Only ever used here for small non-negative
 * integers ("val"), so a double is exact for every value this file needs. */
static int jv_parse_number(jscan *c, double *out)
{
    char tmp[48];
    size_t n = 0;
    char *endp;
    double v;

    if (sk_ch(c) == '-') { tmp[n++] = '-'; c->i++; }
    if (c->i >= c->len || c->s[c->i] < '0' || c->s[c->i] > '9') return -1;
    while (c->i < c->len && c->s[c->i] >= '0' && c->s[c->i] <= '9') {
        if (n >= sizeof tmp - 1) return -1;
        tmp[n++] = c->s[c->i++];
    }
    if (c->i < c->len && c->s[c->i] == '.') {
        if (n >= sizeof tmp - 1) return -1;
        tmp[n++] = c->s[c->i++];
        if (c->i >= c->len || c->s[c->i] < '0' || c->s[c->i] > '9') return -1;
        while (c->i < c->len && c->s[c->i] >= '0' && c->s[c->i] <= '9') {
            if (n >= sizeof tmp - 1) return -1;
            tmp[n++] = c->s[c->i++];
        }
    }
    if (c->i < c->len && (c->s[c->i] == 'e' || c->s[c->i] == 'E')) {
        if (n >= sizeof tmp - 1) return -1;
        tmp[n++] = c->s[c->i++];
        if (c->i < c->len && (c->s[c->i] == '+' || c->s[c->i] == '-')) {
            if (n >= sizeof tmp - 1) return -1;
            tmp[n++] = c->s[c->i++];
        }
        if (c->i >= c->len || c->s[c->i] < '0' || c->s[c->i] > '9') return -1;
        while (c->i < c->len && c->s[c->i] >= '0' && c->s[c->i] <= '9') {
            if (n >= sizeof tmp - 1) return -1;
            tmp[n++] = c->s[c->i++];
        }
    }
    tmp[n] = 0;
    errno = 0;
    v = strtod(tmp, &endp);
    if (endp != tmp + n) return -1;
    *out = v;
    return 0;
}

static int jv_parse_value(jscan *c, jv_field *f)
{
    int ch;
    sk_ws(c);
    ch = sk_ch(c);
    if (ch == '"') {
        char *s; size_t l;
        if (jv_parse_string(c, &s, &l)) return -1;
        f->type = JVT_STR; f->sval = s; f->slen = l;
        return 0;
    }
    if (ch == 't') {
        if (c->i + 4 <= c->len && !memcmp(c->s + c->i, "true", 4)) {
            c->i += 4; f->type = JVT_BOOL; f->bval = 1; return 0;
        }
        return -1;
    }
    if (ch == 'f') {
        if (c->i + 5 <= c->len && !memcmp(c->s + c->i, "false", 5)) {
            c->i += 5; f->type = JVT_BOOL; f->bval = 0; return 0;
        }
        return -1;
    }
    if (ch == 'n') {
        if (c->i + 4 <= c->len && !memcmp(c->s + c->i, "null", 4)) {
            c->i += 4; f->type = JVT_NULL; return 0;
        }
        return -1;
    }
    if (ch == '-' || (ch >= '0' && ch <= '9')) {
        double v;
        if (jv_parse_number(c, &v)) return -1;
        f->type = JVT_NUM; f->nval = v;
        return 0;
    }
    return -1;   /* '{', '[', or garbage: not a value this file accepts */
}

/* Parses one flat {"key":value, ...} object filling `out`, and requires the
 * whole scanned range to be consumed (no trailing garbage after the closing
 * brace).  On ANY failure returns -1; `out->n` still reflects exactly the
 * fields stored before the failure, so jv_obj_free(out) is always safe and
 * always sufficient, whether this returns 0 or -1. */
static int jv_parse_object(jscan *c, jv_obj *out)
{
    out->n = 0;
    sk_ws(c);
    if (sk_ch(c) != '{') return -1;
    c->i++;
    sk_ws(c);
    if (sk_ch(c) == '}') {
        c->i++;
    } else {
        for (;;) {
            char *key; size_t klen;
            int k, dup;

            sk_ws(c);
            if (jv_parse_string(c, &key, &klen)) return -1;
            sk_ws(c);
            if (sk_ch(c) != ':') { free(key); return -1; }
            c->i++;
            if (out->n >= JC_MAX_FIELDS || klen >= sizeof out->f[0].key) {
                free(key); return -1;
            }
            dup = 0;
            for (k = 0; k < out->n; k++)
                if (!strcmp(out->f[k].key, key)) { dup = 1; break; }
            if (dup) { free(key); return -1; }
            strcpy(out->f[out->n].key, key);
            free(key);
            if (jv_parse_value(c, &out->f[out->n])) return -1;
            out->n++;
            sk_ws(c);
            if (sk_ch(c) == ',') { c->i++; continue; }
            if (sk_ch(c) == '}') { c->i++; break; }
            return -1;
        }
    }
    sk_ws(c);
    if (c->i != c->len) return -1;    /* trailing garbage after '}' */
    return 0;
}

static int jc_parse_line(const char *s, size_t len, jv_obj *out)
{
    jscan c; c.s = s; c.len = len; c.i = 0;
    return jv_parse_object(&c, out);
}

/* --------------------------------------------------------- per-op schemas.
 * Each returns 0 (success payload extracted), JC_ERR_FALSE (well-formed
 * {"ok":false,"err":str}, nothing else), or JC_ERR_PROTO (anything that does
 * not match one of those two shapes exactly -- wrong types, missing fields,
 * or EXTRA fields neither shape calls for). */

static int jc_check_false(const jv_obj *o)
{
    int i_err;
    if (o->n != 2) return JC_ERR_PROTO;
    i_err = jv_find(o, "err");
    if (i_err < 0 || o->f[i_err].type != JVT_STR) return JC_ERR_PROTO;
    return JC_ERR_FALSE;
}

/* {"ok":true} alone, or the false shape above.  wr32/wrn's success reply. */
static int jc_reply_plain(const jv_obj *o)
{
    int i_ok = jv_find(o, "ok");
    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o);
    return o->n == 1 ? 0 : JC_ERR_PROTO;
}

/* {"ok":true,"val":V} (V a 0..2^32-1 integer) or the false shape. rd32. */
static int jc_reply_val(const jv_obj *o, uint32_t *val)
{
    int i_ok = jv_find(o, "ok"), i_val;
    double v;
    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o);
    if (o->n != 2) return JC_ERR_PROTO;
    i_val = jv_find(o, "val");
    if (i_val < 0 || o->f[i_val].type != JVT_NUM) return JC_ERR_PROTO;
    v = o->f[i_val].nval;
    if (v < 0.0 || v > 4294967295.0 || (double)(uint32_t)v != v) return JC_ERR_PROTO;
    *val = (uint32_t)v;
    return 0;
}

static int hex_nibble(unsigned char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* {"ok":true,"hex":H} with H exactly 2*len hex digits, or the false shape.
 * memrd. A wrong-length hex is the memrd equivalent of a short transfer, so
 * it is JC_ERR_FALSE (-EIO) rather than JC_ERR_PROTO: the reply was
 * well-formed JSON that answered the wrong amount, not malformed JSON. */
static int jc_reply_hex(const jv_obj *o, void *buf, size_t len)
{
    int i_ok = jv_find(o, "ok"), i_hex;
    const char *h;
    unsigned char *b = (unsigned char *)buf;
    size_t k;

    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o);
    if (o->n != 2) return JC_ERR_PROTO;
    i_hex = jv_find(o, "hex");
    if (i_hex < 0 || o->f[i_hex].type != JVT_STR) return JC_ERR_PROTO;
    if (o->f[i_hex].slen != len * 2) return JC_ERR_FALSE;
    h = o->f[i_hex].sval;
    for (k = 0; k < len; k++) {
        int hi = hex_nibble((unsigned char)h[2 * k]);
        int lo = hex_nibble((unsigned char)h[2 * k + 1]);
        if (hi < 0 || lo < 0) return JC_ERR_PROTO;
        b[k] = (unsigned char)((hi << 4) | lo);
    }
    return 0;
}

/* ---------------------------------------------------------------- the ctx */

typedef struct {
    int  fd;
    char die[JC_DIE_MAX + 1];
    char desc[256];

    /* the pending coalesced write run (see the file header) */
    int      pend_active;
    uint32_t pend_off;
    uint32_t pend_n;
    uint32_t pend_vals[JC_WRN_MAX];

    /* bytes read from the socket not yet consumed as a complete line */
    char   *rbuf;
    size_t  rbuf_len, rbuf_cap;

    /* one request line is built here; sized once for the biggest line this
     * file ever sends (a full JC_WRN_MAX-value wrn) */
    char   *sbuf;
    size_t  sbuf_cap;
} jc_ctx;

static int jc_die_ok(const char *d)
{
    size_t i;
    if (!d || !*d) return 0;
    for (i = 0; d[i]; i++) {
        unsigned char ch = (unsigned char)d[i];
        if (i >= JC_DIE_MAX) return 0;
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
              (ch >= '0' && ch <= '9') || ch == '_' || ch == '-'))
            return 0;
    }
    return 1;
}

/* ------------------------------------------------------------- the socket */

static int jc_send_all(jc_ctx *x, const char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = send(x->fd, buf + done, len - done, MSG_NOSIGNAL);
        if (n < 0) { if (errno == EINTR) continue; return -errno; }
        if (n == 0) return JC_ERR_CLOSED;
        done += (size_t)n;
    }
    return 0;
}

/* Returns one reply line (newline stripped, NUL-terminated) in *line_out,
 * valid until the next call on this ctx -- which is fine, because every
 * caller fully parses and copies out of a line before issuing another
 * request.  JC_ERR_PROTO on a line over JC_LINE_MAX; JC_ERR_CLOSED if the
 * socket closes before a full line arrives. */
static int jc_recv_line(jc_ctx *x, char **line_out, size_t *len_out)
{
    for (;;) {
        size_t i;
        for (i = 0; i < x->rbuf_len; i++)
            if (x->rbuf[i] == '\n') break;
        if (i < x->rbuf_len) {
            size_t rest = x->rbuf_len - (i + 1);
            x->rbuf[i] = 0;
            *line_out = x->rbuf;
            *len_out = i;
            memmove(x->rbuf, x->rbuf + i + 1, rest);
            x->rbuf_len = rest;
            return 0;
        }
        if (x->rbuf_len >= JC_LINE_MAX) return JC_ERR_PROTO;
        if (x->rbuf_len == x->rbuf_cap) {
            size_t newcap = x->rbuf_cap ? x->rbuf_cap * 2 : 4096;
            char *nb;
            if (newcap > JC_LINE_MAX) newcap = JC_LINE_MAX;
            nb = (char *)realloc(x->rbuf, newcap);
            if (!nb) return -ENOMEM;
            x->rbuf = nb; x->rbuf_cap = newcap;
        }
        {
            ssize_t n = recv(x->fd, x->rbuf + x->rbuf_len,
                             x->rbuf_cap - x->rbuf_len, 0);
            if (n < 0) { if (errno == EINTR) continue; return -errno; }
            if (n == 0) return JC_ERR_CLOSED;
            x->rbuf_len += (size_t)n;
        }
    }
}

static int jc_recv_plain(jc_ctx *x)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(x, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_plain(&o);
    jv_obj_free(&o);
    return rc;
}

static int jc_recv_val(jc_ctx *x, uint32_t *val)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(x, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_val(&o, val);
    jv_obj_free(&o);
    return rc;
}

static int jc_recv_hex(jc_ctx *x, void *buf, size_t len)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(x, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_hex(&o, buf, len);
    jv_obj_free(&o);
    return rc;
}

/* ------------------------------------------------------- request encoding
 * By-hand snprintf building, not a generic encoder: the only strings this
 * file ever sends are the fixed op literals and `die`, and `die` was
 * validated by jc_die_ok() to be a plain identifier that needs no escaping. */

static long jc_build_rd32(jc_ctx *x, uint32_t off)
{
    int w = snprintf(x->sbuf, x->sbuf_cap,
                     "{\"die\":\"%s\",\"op\":\"rd32\",\"off\":%u}\n",
                     x->die, off);
    if (w < 0 || (size_t)w >= x->sbuf_cap) return -1;
    return w;
}

static long jc_build_memrd(jc_ctx *x, uint64_t addr, size_t n)
{
    int w = snprintf(x->sbuf, x->sbuf_cap,
                     "{\"die\":\"%s\",\"op\":\"memrd\",\"addr\":%llu,\"n\":%zu}\n",
                     x->die, (unsigned long long)addr, n);
    if (w < 0 || (size_t)w >= x->sbuf_cap) return -1;
    return w;
}

static long jc_build_wrn(jc_ctx *x, uint32_t off, const uint32_t *vals, uint32_t n)
{
    size_t p; int w; uint32_t i;
    w = snprintf(x->sbuf, x->sbuf_cap,
                "{\"die\":\"%s\",\"op\":\"wrn\",\"off\":%u,\"fix\":true,\"vals\":[",
                x->die, off);
    if (w < 0 || (size_t)w >= x->sbuf_cap) return -1;
    p = (size_t)w;
    for (i = 0; i < n; i++) {
        w = snprintf(x->sbuf + p, x->sbuf_cap - p, "%s%u", i ? "," : "", vals[i]);
        if (w < 0 || (size_t)w >= x->sbuf_cap - p) return -1;
        p += (size_t)w;
    }
    w = snprintf(x->sbuf + p, x->sbuf_cap - p, "]}\n");
    if (w < 0 || (size_t)w >= x->sbuf_cap - p) return -1;
    p += (size_t)w;
    return (long)p;
}

/* ------------------------------------------------------------- the flush.
 * Ends whatever run is pending, succeed or fail, before this returns: a
 * failed flush is NOT retried with the same buffered values later (that
 * would risk reordering against whatever the caller does next), it is just
 * reported, once, to whichever call forced it. */
static int jc_flush(jc_ctx *x)
{
    long len; int rc;
    uint32_t n;

    if (!x->pend_active) return 0;
    x->pend_active = 0;
    n = x->pend_n;
    x->pend_n = 0;
    len = jc_build_wrn(x, x->pend_off, x->pend_vals, n);
    if (len < 0) return JC_ERR_PROTO;
    rc = jc_send_all(x, x->sbuf, (size_t)len);
    if (rc) return rc;
    return jc_recv_plain(x);
}

/* ------------------------------------------------------- the four struct
 * functions (fk33_transport.h). */

static int jc_reg_write32(void *ctx, uint32_t off, uint32_t val)
{
    jc_ctx *x = (jc_ctx *)ctx;
    if (!(x->pend_active && off == x->pend_off && x->pend_n < JC_WRN_MAX)) {
        int rc = jc_flush(x);
        if (rc) return rc;
        x->pend_active = 1;
        x->pend_off = off;
        x->pend_n = 0;
    }
    x->pend_vals[x->pend_n++] = val;
    return 0;
}

static int jc_reg_read32(void *ctx, uint32_t off, uint32_t *val)
{
    jc_ctx *x = (jc_ctx *)ctx;
    long len; int rc;
    rc = jc_flush(x);
    if (rc) return rc;
    len = jc_build_rd32(x, off);
    if (len < 0) return JC_ERR_PROTO;
    rc = jc_send_all(x, x->sbuf, (size_t)len);
    if (rc) return rc;
    return jc_recv_val(x, val);
}

static int jc_mem_read(void *ctx, uint64_t addr, void *buf, size_t len)
{
    jc_ctx *x = (jc_ctx *)ctx;
    size_t done = 0;
    int rc = jc_flush(x);
    if (rc) return rc;
    while (done < len) {
        size_t chunk = len - done;
        long rl;
        if (chunk > JC_MEMRD_CHUNK) chunk = JC_MEMRD_CHUNK;
        rl = jc_build_memrd(x, addr + done, chunk);
        if (rl < 0) return JC_ERR_PROTO;
        rc = jc_send_all(x, x->sbuf, (size_t)rl);
        if (rc) return rc;
        rc = jc_recv_hex(x, (unsigned char *)buf + done, chunk);
        if (rc) return rc;
        done += chunk;
    }
    return 0;
}

/* THE LOADER IS THE ONLY HBM WRITER.  This always returns -EPERM, no matter
 * what.  A pending write run is still flushed first so the attempt does not
 * silently reorder past whatever the caller does after seeing the refusal --
 * but a failed flush here does NOT change the return value: -EPERM is what
 * the brief requires this call to report, unconditionally, and swallowing
 * the refusal to report a flush failure instead would be a worse answer to
 * "why did mem_write fail" than the true one. A flush failure immediately
 * before a refused mem_write is therefore silent on this one path, by
 * design. */
static int jc_mem_write(void *ctx, uint64_t addr, const void *buf, size_t len)
{
    jc_ctx *x = (jc_ctx *)ctx;
    (void)jc_flush(x);
    (void)buf;
    fprintf(stderr,
        "fk33_transport_jc: mem_write refused at addr=0x%llx len=%zu: the "
        "loader is the only HBM writer\n",
        (unsigned long long)addr, len);
    return -EPERM;
}

static void jc_close(void *ctx)
{
    jc_ctx *x = (jc_ctx *)ctx;
    int rc = jc_flush(x);
    if (rc)
        fprintf(stderr,
            "fk33_transport_jc: close: a pending coalesced write failed to "
            "flush (rc=%d); its values were never sent\n", rc);
    if (x->fd >= 0) close(x->fd);
    free(x->rbuf);
    free(x->sbuf);
    free(x);
}

static const char *jc_describe(void *ctx)
{
    return ((jc_ctx *)ctx)->desc;
}

/* ---------------------------------------------------------------- open() */

fk33_transport *fk33_transport_open_jc(const char *sock_path, const char *die)
{
    jc_ctx *x;
    fk33_transport *t;
    struct sockaddr_un addr;
    size_t sbuf_cap;

    if (!sock_path || !*sock_path) {
        fprintf(stderr, "fk33_transport_jc: a socket path is required\n");
        return NULL;
    }
    if (!jc_die_ok(die)) {
        fprintf(stderr,
            "fk33_transport_jc: die %s is not a plain identifier (letters, "
            "digits, '_' or '-', max %u chars)\n",
            die ? die : "(null)", JC_DIE_MAX);
        return NULL;
    }
    if (strlen(sock_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "fk33_transport_jc: socket path too long: %s\n", sock_path);
        return NULL;
    }

    x = (jc_ctx *)calloc(1, sizeof *x);
    if (!x) return NULL;
    x->fd = -1;
    strcpy(x->die, die);

    sbuf_cap = 64 + (size_t)JC_WRN_MAX * 11 + 16;
    x->sbuf = (char *)malloc(sbuf_cap);
    if (!x->sbuf) { free(x); return NULL; }
    x->sbuf_cap = sbuf_cap;

    x->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (x->fd < 0) {
        fprintf(stderr, "fk33_transport_jc: socket: %s\n", strerror(errno));
        free(x->sbuf); free(x); return NULL;
    }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, sock_path);   /* length already checked above */
    if (connect(x->fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        fprintf(stderr, "fk33_transport_jc: connect %s: %s\n",
                sock_path, strerror(errno));
        close(x->fd); free(x->sbuf); free(x); return NULL;
    }

    snprintf(x->desc, sizeof x->desc, "jc sock=%s die=%s", sock_path, die);

    t = (fk33_transport *)calloc(1, sizeof *t);
    if (!t) { close(x->fd); free(x->sbuf); free(x); return NULL; }
    t->reg_read32  = jc_reg_read32;
    t->reg_write32 = jc_reg_write32;
    t->mem_read    = jc_mem_read;
    t->mem_write   = jc_mem_write;
    t->close       = jc_close;
    t->describe    = jc_describe;
    t->ctx = x;
    return t;
}
