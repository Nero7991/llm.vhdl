/* fk33_transport_jc.c -- the Jungle Cat transport: JSON lines over a Unix
 * socket to tools/jc/jc_broker.py.  See the "THE JUNGLE CAT TRANSPORT"
 * comment in fk33_transport.h for why this exists instead of a chardev.
 *
 * THE WIRE PROTOCOL (docs/superpowers/plans/2026-10-07-jc-engine-composition.md,
 * Task 6; field names taken from tools/jc/jc_broker.py's Broker.handle()).
 * One JSON object per line, sent and answered in strict order -- the broker
 * serves one client, one request at a time.
 *
 *   {"die":D,"op":"rd32","off":N}                  -> {"ok":true,"val":V}
 *   {"die":D,"op":"wr32","off":N,"val":V}          -> {"ok":true}
 *   {"die":D,"op":"wrn","off":N,"fix":true,"vals":[...]} -> {"ok":true}
 *   {"die":D,"op":"memrd","addr":A,"n":K}           -> {"ok":true,"hex":".."}
 *   anything else                                   -> {"ok":false,"err":".."
 *                                                        [,"done_items":I,
 *                                                          "done_items_exact":B]}
 *
 * FIX ROUND 1 (review on the first cut).  Four things changed shape:
 *
 * C1 -- COALESCING SCOPE.  The first cut coalesced any run of writes to the
 * same offset, no matter what that offset was.  That is wrong: pl_backend.c
 * writes CTRL=GO through reg_write32() too (pl_backend.c:1330), and a GO that
 * sits buffered until some unrelated later register access touches the
 * socket is a GO the card never saw -- it breaks pl_pipeline's two-card
 * overlap (pl_pipeline.c, prefill_overlap()) outright and corrupts every
 * timing measurement built on "the GO is on the wire now" (t_go0).  This file
 * now takes the window's ABSOLUTE BAR offset as an explicit, separate
 * argument to fk33_transport_open_jc() (pl_backend.c passes `c->base +
 * FK33_SEAM_WIN_DATA`), coalesces ONLY reg_write32() calls that land on that
 * exact offset, and sends every other write as its own `wr32`, synchronously
 * -- acknowledged before reg_write32() returns, never deferred.
 *
 * I1 -- NO RECEIVE DEADLINE.  recv() used to block forever; a broker that
 * hangs (or a half-dead chain) hung the whole server.  Every socket created
 * here now carries SO_RCVTIMEO (and SO_SNDTIMEO, for the send side of the
 * same failure mode), default 120000 ms, overridable with the
 * FK33_JC_TIMEOUT_MS environment variable (read once, when a new connection
 * is opened).  A timeout returns -ETIMEDOUT and marks the connection broken
 * (see M1).
 *
 * I2 -- THE REAL ok:false SHAPE.  A partial wrn failure
 * (tools/jc/jc_broker.py's err_reply(), jc_broker.py:178-182, reflecting
 * AxiError.done_items/.done_items_exact) carries two extra fields,
 * "done_items" and "done_items_exact", always together.  The old strict
 * 2-field-only check rejected that as -EPROTO and threw the broker's actual
 * error text away.  The false shape is now EITHER {"ok":false,"err":S} OR
 * {"ok":false,"err":S,"done_items":I,"done_items_exact":B} -- nothing else --
 * and the err string (plus done_items when present) is printed to stderr
 * with the die before returning -EIO.
 *
 * I3 -- ONE CONNECTION PER BROKER.  The broker serves exactly one client.
 * The first cut opened one socket per pl_ctx, so a second die got "Busy".
 * Connections are now refcounted per (process, sock_path): opened on first
 * use, closed on last close, and every byte on the wire -- for every die
 * sharing that path -- goes through the one jc_conn's mutex, which is held
 * for an entire request/reply round trip (including the flush it may have
 * to do first), so two dies' requests can never interleave on the wire.
 * Each die still keeps its OWN pending coalesce run (jc_ctx), because the
 * window being coalesced belongs to one die's register file, not the
 * socket; that run is only ever touched while holding its connection's lock.
 *
 * M1 -- STICKY BROKEN.  After any flush failure (of any kind -- see below),
 * any receive timeout, or any protocol error (malformed JSON, wrong/missing/
 * extra fields, an oversized line), the shared connection is marked broken.
 * Every later call on EVERY die sharing it returns -ECONNABORTED without
 * sending anything, until close() releases it.  mem_write() still always
 * returns -EPERM, but if its own flush attempt fails, the connection is
 * marked broken anyway -- the refusal value does not change, but the
 * connection's fate does.
 *
 *   ONE ASYMMETRY ON PURPOSE: an isolated rd32/wr32/memrd round trip that
 *   comes back {"ok":false,...} (a normal in-band AxiError, say) does NOT
 *   mark the connection broken -- that is an ordinary operational failure
 *   for that one call. A FLUSH that comes back {"ok":false,...} DOES mark it
 *   broken, always, even though the reply is perfectly well-formed: a
 *   partial wrn leaves the card's WIN_ADDR sitting at done_items, not at the
 *   n this file asked for, and this transport has no mechanism to
 *   resynchronize that window afterwards, so continuing to drive it is worse
 *   than refusing to.
 *
 * READS ARE STILL NEVER COALESCED.  WIN_DATA is a read-and-advance window:
 * reading element k+1 before the caller has asked for it is reading a
 * register that has not been "asked for" yet, and speculative reads of a
 * stateful window are exactly the shape of bug this project keeps finding.
 * Every reg_read32() issues its own `rd32`, full stop -- an n_embd read-out
 * run costs n_embd round trips here, the same as if no transport existed.
 * That cost is accepted on purpose.
 *
 * ERROR CODES.  All four struct functions return 0 or a negative
 * errno-like code:
 *   -EPERM          mem_write(), always.
 *   -EPROTO         a malformed/schema-violating reply, or a line over the
 *                   JC_LINE_MAX bound.
 *   -EIO            a reply that parsed and said {"ok":false,...}, or a
 *                   memrd whose "hex" was the wrong length.
 *   -ETIMEDOUT      no reply within the configured deadline.
 *   -ECONNABORTED   the connection is already marked broken; nothing was
 *                   sent for this call.
 *   -errno          straight from a failing send()/recv()/socket()/connect().
 *
 * The JSON is small, flat, and never nested, so it is parsed by a minimal
 * hand-written scanner rather than pulling in a library.  It is STRICT: an
 * unexpected extra field, a missing required one, or a line over the bound
 * is -EPROTO.  No input, however malformed, is allowed to crash this file.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>

#include "fk33_transport.h"

/* ---------------------------------------------------------------- tuning */

#define JC_DIE_MAX      15u          /* max chars in a die identifier */
#define JC_WRN_MAX      8192u        /* values per coalesced wrn; see header */
#define JC_LINE_MAX     (8u << 20)   /* bytes of one reply line we will buffer */
#define JC_MEMRD_CHUNK  (1u << 20)   /* bytes per memrd request we issue */
#define JC_MAX_FIELDS   8            /* top-level keys a reply may have */
#define JC_MAX_KEY      24           /* bytes, including NUL, per key: must
                                      * hold "done_items_exact" (17 with the
                                      * NUL) plus margin */

#define JC_TIMEOUT_ENV         "FK33_JC_TIMEOUT_MS"
#define JC_TIMEOUT_MS_DEFAULT  120000L

#define JC_ERR_PROTO    (-EPROTO)       /* malformed / schema-violating reply */
#define JC_ERR_FALSE    (-EIO)          /* a well-formed {"ok":false,...} */
#define JC_ERR_CLOSED   (-EIO)          /* socket closed before a full line */
#define JC_ERR_TIMEOUT  (-ETIMEDOUT)    /* no reply within the deadline */
#define JC_ERR_BROKEN   (-ECONNABORTED) /* the connection is already dead */

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
 * integers ("val", "done_items"), so a double is exact for every value this
 * file needs. */
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
 * Each returns 0 (success payload extracted), JC_ERR_FALSE (a well-formed
 * false shape -- see jc_check_false), or JC_ERR_PROTO (anything else). */

/* {"ok":false,"err":S} or {"ok":false,"err":S,"done_items":I,
 * "done_items_exact":B} -- the two extra fields always arrive together
 * (tools/jc/jc_broker.py's err_reply()), never alone.  Prints the broker's
 * error text, with the die, to stderr before returning. */
static int jc_check_false(const jv_obj *o, const char *die)
{
    int i_err = jv_find(o, "err");
    if (i_err < 0 || o->f[i_err].type != JVT_STR) return JC_ERR_PROTO;

    if (o->n == 2) {
        fprintf(stderr, "fk33_transport_jc: die %s: %s\n", die, o->f[i_err].sval);
        return JC_ERR_FALSE;
    }
    if (o->n == 4) {
        int i_di = jv_find(o, "done_items");
        int i_de = jv_find(o, "done_items_exact");
        double v;
        if (i_di < 0 || o->f[i_di].type != JVT_NUM) return JC_ERR_PROTO;
        if (i_de < 0 || o->f[i_de].type != JVT_BOOL) return JC_ERR_PROTO;
        v = o->f[i_di].nval;
        if (v < 0.0 || v > 4294967295.0 || (double)(uint32_t)v != v) return JC_ERR_PROTO;
        fprintf(stderr, "fk33_transport_jc: die %s: %s (done_items=%u exact=%s)\n",
                die, o->f[i_err].sval, (unsigned)v, o->f[i_de].bval ? "true" : "false");
        return JC_ERR_FALSE;
    }
    return JC_ERR_PROTO;
}

/* {"ok":true} alone, or the false shape above.  wr32/wrn's success reply. */
static int jc_reply_plain(const jv_obj *o, const char *die)
{
    int i_ok = jv_find(o, "ok");
    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o, die);
    return o->n == 1 ? 0 : JC_ERR_PROTO;
}

/* {"ok":true,"val":V} (V a 0..2^32-1 integer) or the false shape. rd32. */
static int jc_reply_val(const jv_obj *o, const char *die, uint32_t *val)
{
    int i_ok = jv_find(o, "ok"), i_val;
    double v;
    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o, die);
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
static int jc_reply_hex(const jv_obj *o, const char *die, void *buf, size_t len)
{
    int i_ok = jv_find(o, "ok"), i_hex;
    const char *h;
    unsigned char *b = (unsigned char *)buf;
    size_t k;

    if (i_ok < 0 || o->f[i_ok].type != JVT_BOOL) return JC_ERR_PROTO;
    if (!o->f[i_ok].bval) return jc_check_false(o, die);
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

/* --------------------------------------------------- the shared connection.
 * One per (process, sock_path), refcounted; see I3 in the file header. */

typedef struct jc_conn {
    struct jc_conn *next;
    char            sock_path[256];
    int             fd;
    int             refcount;
    int             broken;          /* sticky; see M1 */
    pthread_mutex_t lock;            /* held for a whole request/reply round
                                       * trip, including any flush first */

    char   *rbuf; size_t rbuf_len, rbuf_cap;   /* bytes not yet a full line */
    char   *sbuf; size_t sbuf_cap;             /* one request is built here */
} jc_conn;

static jc_conn *g_conns = NULL;
static pthread_mutex_t g_registry_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    jc_conn *conn;             /* shared; released, not freed, at close() */
    char     die[JC_DIE_MAX + 1];
    char     desc[256];
    uint32_t win_off;           /* the ABSOLUTE offset this die coalesces */

    /* this die's own pending coalesced run; touched only while holding
     * conn->lock */
    int      pend_active;
    uint32_t pend_n;
    uint32_t pend_vals[JC_WRN_MAX];
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

/* ------------------------------------------------------- the socket itself.
 * Every function below is called with conn->lock already held. */

static int jc_send_all(jc_conn *conn, const char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = send(conn->fd, buf + done, len - done, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return JC_ERR_TIMEOUT;
            return -errno;
        }
        if (n == 0) return JC_ERR_CLOSED;
        done += (size_t)n;
    }
    return 0;
}

/* Returns one reply line (newline stripped, NUL-terminated) in *line_out,
 * valid until the next call on this conn.  JC_ERR_PROTO on a line over
 * JC_LINE_MAX; JC_ERR_CLOSED if the socket closes before a full line
 * arrives; JC_ERR_TIMEOUT if SO_RCVTIMEO elapses first (see I1). */
static int jc_recv_line(jc_conn *conn, char **line_out, size_t *len_out)
{
    for (;;) {
        size_t i;
        for (i = 0; i < conn->rbuf_len; i++)
            if (conn->rbuf[i] == '\n') break;
        if (i < conn->rbuf_len) {
            size_t rest = conn->rbuf_len - (i + 1);
            conn->rbuf[i] = 0;
            *line_out = conn->rbuf;
            *len_out = i;
            memmove(conn->rbuf, conn->rbuf + i + 1, rest);
            conn->rbuf_len = rest;
            return 0;
        }
        if (conn->rbuf_len >= JC_LINE_MAX) return JC_ERR_PROTO;
        if (conn->rbuf_len == conn->rbuf_cap) {
            size_t newcap = conn->rbuf_cap ? conn->rbuf_cap * 2 : 4096;
            char *nb;
            if (newcap > JC_LINE_MAX) newcap = JC_LINE_MAX;
            nb = (char *)realloc(conn->rbuf, newcap);
            if (!nb) return -ENOMEM;
            conn->rbuf = nb; conn->rbuf_cap = newcap;
        }
        {
            ssize_t n = recv(conn->fd, conn->rbuf + conn->rbuf_len,
                             conn->rbuf_cap - conn->rbuf_len, 0);
            if (n < 0) {
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) return JC_ERR_TIMEOUT;
                return -errno;
            }
            if (n == 0) return JC_ERR_CLOSED;
            conn->rbuf_len += (size_t)n;
        }
    }
}

static int jc_recv_plain(jc_conn *conn, const char *die)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(conn, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_plain(&o, die);
    jv_obj_free(&o);
    return rc;
}

static int jc_recv_val(jc_conn *conn, const char *die, uint32_t *val)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(conn, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_val(&o, die, val);
    jv_obj_free(&o);
    return rc;
}

static int jc_recv_hex(jc_conn *conn, const char *die, void *buf, size_t len)
{
    char *line; size_t llen; jv_obj o; int rc;
    rc = jc_recv_line(conn, &line, &llen);
    if (rc) return rc;
    if (jc_parse_line(line, llen, &o)) { jv_obj_free(&o); return JC_ERR_PROTO; }
    rc = jc_reply_hex(&o, die, buf, len);
    jv_obj_free(&o);
    return rc;
}

/* ------------------------------------------------------- request encoding.
 * By-hand snprintf building: the only strings sent are the fixed op
 * literals and `die`, and `die` was validated by jc_die_ok() to need no
 * escaping. */

static long jc_build_rd32(jc_conn *conn, const char *die, uint32_t off)
{
    int w = snprintf(conn->sbuf, conn->sbuf_cap,
                     "{\"die\":\"%s\",\"op\":\"rd32\",\"off\":%u}\n", die, off);
    if (w < 0 || (size_t)w >= conn->sbuf_cap) return -1;
    return w;
}

static long jc_build_wr32(jc_conn *conn, const char *die, uint32_t off, uint32_t val)
{
    int w = snprintf(conn->sbuf, conn->sbuf_cap,
                     "{\"die\":\"%s\",\"op\":\"wr32\",\"off\":%u,\"val\":%u}\n",
                     die, off, val);
    if (w < 0 || (size_t)w >= conn->sbuf_cap) return -1;
    return w;
}

static long jc_build_memrd(jc_conn *conn, const char *die, uint64_t addr, size_t n)
{
    int w = snprintf(conn->sbuf, conn->sbuf_cap,
                     "{\"die\":\"%s\",\"op\":\"memrd\",\"addr\":%llu,\"n\":%zu}\n",
                     die, (unsigned long long)addr, n);
    if (w < 0 || (size_t)w >= conn->sbuf_cap) return -1;
    return w;
}

static long jc_build_wrn(jc_conn *conn, const char *die, uint32_t off,
                         const uint32_t *vals, uint32_t n)
{
    size_t p; int w; uint32_t i;
    w = snprintf(conn->sbuf, conn->sbuf_cap,
                "{\"die\":\"%s\",\"op\":\"wrn\",\"off\":%u,\"fix\":true,\"vals\":[",
                die, off);
    if (w < 0 || (size_t)w >= conn->sbuf_cap) return -1;
    p = (size_t)w;
    for (i = 0; i < n; i++) {
        w = snprintf(conn->sbuf + p, conn->sbuf_cap - p, "%s%u", i ? "," : "", vals[i]);
        if (w < 0 || (size_t)w >= conn->sbuf_cap - p) return -1;
        p += (size_t)w;
    }
    w = snprintf(conn->sbuf + p, conn->sbuf_cap - p, "]}\n");
    if (w < 0 || (size_t)w >= conn->sbuf_cap - p) return -1;
    p += (size_t)w;
    return (long)p;
}

/* -------------------------------------------------------- the round trips.
 * Each does build+send+recv and marks the connection broken on anything
 * other than success or a well-formed {"ok":false,...} -- see M1's
 * asymmetry note in the file header for why the flush path below does NOT
 * share this leniency. */

static int jc_mark_if_bad(jc_conn *conn, int rc)
{
    if (rc != 0 && rc != JC_ERR_FALSE) conn->broken = 1;
    return rc;
}

static int jc_do_wr32(jc_conn *conn, jc_ctx *x, uint32_t off, uint32_t val)
{
    long len = jc_build_wr32(conn, x->die, off, val);
    int rc;
    if (len < 0) return jc_mark_if_bad(conn, JC_ERR_PROTO);
    rc = jc_send_all(conn, conn->sbuf, (size_t)len);
    if (rc) return jc_mark_if_bad(conn, rc);
    rc = jc_recv_plain(conn, x->die);
    return jc_mark_if_bad(conn, rc);
}

static int jc_do_rd32(jc_conn *conn, jc_ctx *x, uint32_t off, uint32_t *val)
{
    long len = jc_build_rd32(conn, x->die, off);
    int rc;
    if (len < 0) return jc_mark_if_bad(conn, JC_ERR_PROTO);
    rc = jc_send_all(conn, conn->sbuf, (size_t)len);
    if (rc) return jc_mark_if_bad(conn, rc);
    rc = jc_recv_val(conn, x->die, val);
    return jc_mark_if_bad(conn, rc);
}

static int jc_do_memrd(jc_conn *conn, jc_ctx *x, uint64_t addr, void *buf, size_t n)
{
    long len = jc_build_memrd(conn, x->die, addr, n);
    int rc;
    if (len < 0) return jc_mark_if_bad(conn, JC_ERR_PROTO);
    rc = jc_send_all(conn, conn->sbuf, (size_t)len);
    if (rc) return jc_mark_if_bad(conn, rc);
    rc = jc_recv_hex(conn, x->die, buf, n);
    return jc_mark_if_bad(conn, rc);
}

/* Ends x's pending run (if any), succeed or fail, before returning.  ANY
 * nonzero result -- including a well-formed {"ok":false,...} -- marks the
 * connection broken: see the M1 asymmetry note in the file header. A failed
 * run's buffered values are never retried later; replaying them after
 * whatever the caller does next would risk reordering. */
static int jc_flush_locked(jc_conn *conn, jc_ctx *x)
{
    long len; int rc; uint32_t n;

    if (!x->pend_active) return 0;
    x->pend_active = 0;
    n = x->pend_n;
    x->pend_n = 0;
    len = jc_build_wrn(conn, x->die, x->win_off, x->pend_vals, n);
    if (len < 0) { conn->broken = 1; return JC_ERR_PROTO; }
    rc = jc_send_all(conn, conn->sbuf, (size_t)len);
    if (rc) { conn->broken = 1; return rc; }
    rc = jc_recv_plain(conn, x->die);
    if (rc) conn->broken = 1;
    return rc;
}

/* ------------------------------------------------------- the four struct
 * functions (fk33_transport.h). */

static int jc_reg_write32(void *ctx, uint32_t off, uint32_t val)
{
    jc_ctx *x = (jc_ctx *)ctx;
    jc_conn *conn = x->conn;
    int rc;

    pthread_mutex_lock(&conn->lock);
    if (conn->broken) { pthread_mutex_unlock(&conn->lock); return JC_ERR_BROKEN; }

    if (off == x->win_off) {
        if (!(x->pend_active && x->pend_n < JC_WRN_MAX)) {
            rc = jc_flush_locked(conn, x);
            if (rc) { pthread_mutex_unlock(&conn->lock); return rc; }
            x->pend_active = 1;
            x->pend_n = 0;
        }
        x->pend_vals[x->pend_n++] = val;
        pthread_mutex_unlock(&conn->lock);
        return 0;
    }

    /* Not the coalesced window.  Flush whatever run is pending first (order),
     * then THIS write goes out as its own wr32, acknowledged before this
     * call returns: a CTRL/GO write must be on the wire the instant
     * reg_write32() returns, not deferred to whatever happens to touch the
     * socket next (C1). */
    rc = jc_flush_locked(conn, x);
    if (rc) { pthread_mutex_unlock(&conn->lock); return rc; }
    rc = jc_do_wr32(conn, x, off, val);
    pthread_mutex_unlock(&conn->lock);
    return rc;
}

static int jc_reg_read32(void *ctx, uint32_t off, uint32_t *val)
{
    jc_ctx *x = (jc_ctx *)ctx;
    jc_conn *conn = x->conn;
    int rc;

    pthread_mutex_lock(&conn->lock);
    if (conn->broken) { pthread_mutex_unlock(&conn->lock); return JC_ERR_BROKEN; }
    rc = jc_flush_locked(conn, x);
    if (rc) { pthread_mutex_unlock(&conn->lock); return rc; }
    rc = jc_do_rd32(conn, x, off, val);
    pthread_mutex_unlock(&conn->lock);
    return rc;
}

static int jc_mem_read(void *ctx, uint64_t addr, void *buf, size_t len)
{
    jc_ctx *x = (jc_ctx *)ctx;
    jc_conn *conn = x->conn;
    size_t done = 0;
    int rc;

    pthread_mutex_lock(&conn->lock);
    if (conn->broken) { pthread_mutex_unlock(&conn->lock); return JC_ERR_BROKEN; }
    rc = jc_flush_locked(conn, x);
    if (rc) { pthread_mutex_unlock(&conn->lock); return rc; }
    while (done < len) {
        size_t chunk = len - done;
        if (chunk > JC_MEMRD_CHUNK) chunk = JC_MEMRD_CHUNK;
        rc = jc_do_memrd(conn, x, addr + done, (unsigned char *)buf + done, chunk);
        if (rc) { pthread_mutex_unlock(&conn->lock); return rc; }
        done += chunk;
    }
    pthread_mutex_unlock(&conn->lock);
    return 0;
}

/* THE LOADER IS THE ONLY HBM WRITER.  This always returns -EPERM, no matter
 * what.  A pending write run is still flushed first (if the connection is
 * not already broken) so the attempt does not silently reorder past
 * whatever the caller does after seeing the refusal -- and per M1, a flush
 * failure here still marks the connection broken, even though -EPERM is
 * what this call reports either way: that refusal value is fixed by the
 * brief, the connection's fate is not. */
static int jc_mem_write(void *ctx, uint64_t addr, const void *buf, size_t len)
{
    jc_ctx *x = (jc_ctx *)ctx;
    jc_conn *conn = x->conn;

    pthread_mutex_lock(&conn->lock);
    if (!conn->broken) (void)jc_flush_locked(conn, x);
    pthread_mutex_unlock(&conn->lock);
    (void)buf;
    fprintf(stderr,
        "fk33_transport_jc: die %s: mem_write refused at addr=0x%llx len=%zu: "
        "the loader is the only HBM writer\n",
        x->die, (unsigned long long)addr, len);
    return -EPERM;
}

static void jc_conn_release(jc_conn *conn);

static void jc_close(void *ctx)
{
    jc_ctx *x = (jc_ctx *)ctx;
    jc_conn *conn = x->conn;

    pthread_mutex_lock(&conn->lock);
    if (!conn->broken) {
        int rc = jc_flush_locked(conn, x);
        if (rc)
            fprintf(stderr,
                "fk33_transport_jc: die %s: close: a pending coalesced write "
                "failed to flush (rc=%d); its values were never sent\n",
                x->die, rc);
    }
    pthread_mutex_unlock(&conn->lock);

    jc_conn_release(conn);
    free(x);
}

static const char *jc_describe(void *ctx)
{
    return ((jc_ctx *)ctx)->desc;
}

/* --------------------------------------------------- the connection registry
 * (I3).  g_registry_lock only ever guards the list itself and a refcount;
 * every actual request/reply round trip is serialized by the conn's OWN
 * lock instead, so two dies on two different sockets never contend with
 * each other here. */

static long jc_timeout_ms(void)
{
    const char *e = getenv(JC_TIMEOUT_ENV);
    long v;
    if (!e || !*e) return JC_TIMEOUT_MS_DEFAULT;
    v = strtol(e, NULL, 10);
    return v > 0 ? v : JC_TIMEOUT_MS_DEFAULT;
}

static void jc_set_timeout(int fd)
{
    struct timeval tv;
    long ms = jc_timeout_ms();
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

static jc_conn *jc_conn_new(const char *sock_path, int fd)
{
    size_t sbuf_cap = 64 + (size_t)JC_WRN_MAX * 11 + 16;
    jc_conn *c = (jc_conn *)calloc(1, sizeof *c);
    if (!c) return NULL;
    c->sbuf = (char *)malloc(sbuf_cap);
    if (!c->sbuf) { free(c); return NULL; }
    c->sbuf_cap = sbuf_cap;
    strcpy(c->sock_path, sock_path);
    c->fd = fd;
    c->refcount = 1;
    pthread_mutex_init(&c->lock, NULL);
    return c;
}

static void jc_conn_free(jc_conn *c)
{
    pthread_mutex_destroy(&c->lock);
    free(c->rbuf);
    free(c->sbuf);
    free(c);
}

/* Looked up / inserted under g_registry_lock; a NEW socket is created and
 * connected OUTSIDE that lock (connect() can block), so two openers racing
 * on a brand-new path each connect and then re-check under the lock -- the
 * loser's fresh connection is closed and discarded rather than risking two
 * live sockets registered under one path. */
static jc_conn *jc_conn_acquire(const char *sock_path)
{
    jc_conn *c;
    struct sockaddr_un addr;
    int fd;

    if (strlen(sock_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "fk33_transport_jc: socket path too long: %s\n", sock_path);
        return NULL;
    }

    pthread_mutex_lock(&g_registry_lock);
    for (c = g_conns; c; c = c->next) {
        if (!strcmp(c->sock_path, sock_path)) {
            c->refcount++;
            pthread_mutex_unlock(&g_registry_lock);
            return c;
        }
    }
    pthread_mutex_unlock(&g_registry_lock);

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "fk33_transport_jc: socket: %s\n", strerror(errno));
        return NULL;
    }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, sock_path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        fprintf(stderr, "fk33_transport_jc: connect %s: %s\n", sock_path, strerror(errno));
        close(fd);
        return NULL;
    }
    jc_set_timeout(fd);

    c = jc_conn_new(sock_path, fd);
    if (!c) { close(fd); return NULL; }

    pthread_mutex_lock(&g_registry_lock);
    {
        jc_conn *other;
        for (other = g_conns; other; other = other->next) {
            if (!strcmp(other->sock_path, sock_path)) {
                other->refcount++;
                pthread_mutex_unlock(&g_registry_lock);
                close(fd);
                jc_conn_free(c);
                return other;
            }
        }
        c->next = g_conns;
        g_conns = c;
    }
    pthread_mutex_unlock(&g_registry_lock);
    return c;
}

static void jc_conn_release(jc_conn *conn)
{
    pthread_mutex_lock(&g_registry_lock);
    conn->refcount--;
    if (conn->refcount > 0) { pthread_mutex_unlock(&g_registry_lock); return; }
    {
        jc_conn **pp = &g_conns;
        while (*pp && *pp != conn) pp = &(*pp)->next;
        if (*pp == conn) *pp = conn->next;
    }
    pthread_mutex_unlock(&g_registry_lock);

    close(conn->fd);
    jc_conn_free(conn);
}

/* ---------------------------------------------------------------- open() */

fk33_transport *fk33_transport_open_jc(const char *sock_path, const char *die,
                                       uint32_t win_data_off)
{
    jc_ctx *x;
    fk33_transport *t;
    jc_conn *conn;

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

    conn = jc_conn_acquire(sock_path);
    if (!conn) return NULL;

    x = (jc_ctx *)calloc(1, sizeof *x);
    if (!x) { jc_conn_release(conn); return NULL; }
    x->conn = conn;
    strcpy(x->die, die);
    x->win_off = win_data_off;
    snprintf(x->desc, sizeof x->desc, "jc sock=%s die=%s win=0x%x",
             sock_path, die, win_data_off);

    t = (fk33_transport *)calloc(1, sizeof *t);
    if (!t) { free(x); jc_conn_release(conn); return NULL; }
    t->reg_read32  = jc_reg_read32;
    t->reg_write32 = jc_reg_write32;
    t->mem_read    = jc_mem_read;
    t->mem_write   = jc_mem_write;
    t->close       = jc_close;
    t->describe    = jc_describe;
    t->ctx = x;
    return t;
}
