// llama_server.cpp — zero-dependency OpenAI-compatible HTTP server for the
// fixed-point stories260K model (token-identical to the VHDL engine).
//
// Links the in-process inference (ref/run_fx.c compiled with -DLLAMA_LIB via
// ref/llama_fx.h). No external libraries: POSIX sockets + pthreads + libstdc++.
// Builds for the dev box (g++) and the AXU3EG board (aarch64-linux-gnu-g++
// -static). See server/Makefile.
//
// Endpoints: GET /v1/models, POST /v1/chat/completions (+ stream),
//            POST /v1/completions, OPTIONS * (CORS preflight).
//
// NOTE: stories260K is a TinyStories model — it CONTINUES children's-story
// prose, it does not follow chat instructions. "Chat" concatenates message
// contents into a prompt and continues the story. Greedy (temperature 0) is
// token-identical to the VHDL; temperature>0 uses the C sampler.
//
// --pl runs GREEDY requests on the FPGA transformer instead (see pl_backend.h).
// That is a generation-level offload, not a forward() swap: the core does the
// whole autoregressive loop and only exposes the chosen token per position, so
// there is no logits vector for a host-side sampler to work with.  Requests
// asking for temperature>0 therefore fall back to the CPU rather than silently
// being served greedily, and prompt+completion is capped at the core's MAXPOS.

#include "llama_fx.h"
#include "pl_backend_axu3eg.h"

// ---------------------------------------------------------------------------
// The FK33 arm.  Two models live in this one binary and they do NOT share a
// code path:
//
//   stories260K  the fixed-point CPU model (ref/run_fx.c) plus, with --pl, the
//                AXU3EG generation-level offload.  Unchanged by this commit.
//   qwen35       the FK33 seam: the C tokenizer, the C chat template, and
//                pl_backend v2's prefill/decode-returning-logits against a
//                SIMULATED card.  Selected by --model qwen35.
//
// The second one produces text and that text is MEANINGLESS: there is no
// whole-model 9B numeric reference in this repository (backlog item 12) and
// the simulated card does not run a transformer.  What it demonstrates is that
// the seam composes -- template, tokenizer, prefill, decode, sampler, stop
// strings, SSE -- not that a token is the right token.  /v1/models says so in
// its own description field, on every request.
// ---------------------------------------------------------------------------
#include "pl_backend.h"
#include "fk33_seam.h"
#include "qwen35_tok.h"
#include "qwen35_chat.h"
#include "embed_mv4i.h"
#include "embed_bf16.h"

#include <cmath>
#include <algorithm>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <thread>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <signal.h>

// ----------------------------------------------------------------------------
// Minimal JSON parser (only what the OpenAI request bodies need).
// ----------------------------------------------------------------------------
struct JValue {
    enum T { NUL, BOOL, NUM, STR, ARR, OBJ } type = NUL;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<JValue> arr;
    std::map<std::string, JValue> obj;

    const JValue* find(const std::string& k) const {
        if (type != OBJ) return nullptr;
        auto it = obj.find(k);
        return it == obj.end() ? nullptr : &it->second;
    }
    double as_num(double d) const { return type == NUM ? num : d; }
    bool   as_bool(bool d) const  { return type == BOOL ? b : d; }
    std::string as_str(const std::string& d) const { return type == STR ? str : d; }
};

struct JParser {
    const char* p;
    const char* end;
    bool ok = true;

    void ws() { while (p < end && (*p==' '||*p=='\t'||*p=='\n'||*p=='\r')) p++; }

    JValue parse() { ws(); JValue v = value(); return v; }

    JValue value() {
        ws();
        if (p >= end) { ok = false; return {}; }
        char c = *p;
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"') { JValue v; v.type = JValue::STR; v.str = str(); return v; }
        if (c == 't' || c == 'f') return boolean();
        if (c == 'n') { lit("null"); JValue v; v.type = JValue::NUL; return v; }
        return number();
    }
    void lit(const char* s) { size_t n = strlen(s); if (p+n<=end && !strncmp(p,s,n)) p+=n; else ok=false; }
    JValue boolean() {
        JValue v; v.type = JValue::BOOL;
        if (*p=='t') { lit("true"); v.b = true; } else { lit("false"); v.b = false; }
        return v;
    }
    JValue number() {
        const char* s = p;
        while (p<end && (*p=='-'||*p=='+'||*p=='.'||*p=='e'||*p=='E'||(*p>='0'&&*p<='9'))) p++;
        JValue v; v.type = JValue::NUM;
        v.num = strtod(std::string(s, p).c_str(), nullptr);
        return v;
    }
    std::string str() {
        std::string out;
        if (*p!='"') { ok=false; return out; }
        p++;
        while (p<end && *p!='"') {
            char c = *p++;
            if (c=='\\' && p<end) {
                char e = *p++;
                switch (e) {
                    case 'n': out+='\n'; break; case 't': out+='\t'; break;
                    case 'r': out+='\r'; break; case 'b': out+='\b'; break;
                    case 'f': out+='\f'; break; case '/': out+='/'; break;
                    case '"': out+='"'; break; case '\\': out+='\\'; break;
                    case 'u': {
                        if (p+4<=end) {
                            int cp = (int)strtol(std::string(p,p+4).c_str(), nullptr, 16);
                            p += 4;
                            // minimal UTF-8 encode of the BMP code point
                            if (cp < 0x80) out += (char)cp;
                            else if (cp < 0x800) { out += (char)(0xC0|(cp>>6)); out += (char)(0x80|(cp&0x3F)); }
                            else { out += (char)(0xE0|(cp>>12)); out += (char)(0x80|((cp>>6)&0x3F)); out += (char)(0x80|(cp&0x3F)); }
                        }
                        break;
                    }
                    default: out += e; break;
                }
            } else out += c;
        }
        if (p<end && *p=='"') p++; else ok=false;
        return out;
    }
    JValue object() {
        JValue v; v.type = JValue::OBJ; p++; ws();
        if (p<end && *p=='}') { p++; return v; }
        while (p<end) {
            ws(); std::string k = str(); ws();
            if (p<end && *p==':') p++; else { ok=false; break; }
            v.obj[k] = value(); ws();
            if (p<end && *p==',') { p++; continue; }
            if (p<end && *p=='}') { p++; break; }
            ok=false; break;
        }
        return v;
    }
    JValue array() {
        JValue v; v.type = JValue::ARR; p++; ws();
        if (p<end && *p==']') { p++; return v; }
        while (p<end) {
            v.arr.push_back(value()); ws();
            if (p<end && *p==',') { p++; continue; }
            if (p<end && *p==']') { p++; break; }
            ok=false; break;
        }
        return v;
    }
};

static std::string json_escape(const std::string& s) {
    std::string o; o.reserve(s.size()+8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break; case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break; case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break; case '\b': o += "\\b"; break;
            case '\f': o += "\\f"; break;
            default:
                if (c < 0x20) { char buf[8]; snprintf(buf,sizeof buf,"\\u%04x",c); o += buf; }
                else o += (char)c;
        }
    }
    return o;
}

// ----------------------------------------------------------------------------
// Globals: one model, a mutex serializing generation (shared RunState).
// ----------------------------------------------------------------------------
static LlamaCtx* g_ctx = nullptr;
static std::mutex g_gen_mutex;
// true once the FPGA engine is mapped and usable (see --pl / pl_backend.h)
static bool g_use_pl = false;
// Set to the FK33 arm's id by main() under --model qwen35, so every response
// object names the model that actually served it.
static const char* MODEL_ID = "stories260k";

// ---- the FK33 / Qwen3.5 arm ------------------------------------------------
static qwen35_tok* g_tok = nullptr;
static pl_ctx*     g_card = nullptr;
static bool        g_qwen = false;

static long now_sec() { return (long)time(nullptr); }

static std::string gen_id(const char* prefix) {
    static std::mutex m; static unsigned long counter = 0;
    std::lock_guard<std::mutex> lk(m);
    char buf[64]; snprintf(buf, sizeof buf, "%s-%ld%04lu", prefix, now_sec(), counter++ % 10000);
    return buf;
}

// ----------------------------------------------------------------------------
// Socket write helpers.
// ----------------------------------------------------------------------------
static bool send_all(int fd, const char* data, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = ::send(fd, data + sent, n - sent, MSG_NOSIGNAL);
        if (w <= 0) return false;
        sent += (size_t)w;
    }
    return true;
}
static bool send_str(int fd, const std::string& s) { return send_all(fd, s.data(), s.size()); }

static void http_headers(std::string& out, int code, const char* status,
                         const char* content_type, long content_length /*-1 = chunked/sse*/) {
    char buf[256];
    snprintf(buf, sizeof buf, "HTTP/1.1 %d %s\r\n", code, status); out += buf;
    out += "Access-Control-Allow-Origin: *\r\n";
    out += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n";
    out += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n";
    snprintf(buf, sizeof buf, "Content-Type: %s\r\n", content_type); out += buf;
    if (content_length >= 0) { snprintf(buf, sizeof buf, "Content-Length: %ld\r\n", content_length); out += buf; }
    out += "Connection: close\r\n\r\n";
}

static void send_json(int fd, int code, const char* status, const std::string& body) {
    std::string hdr; http_headers(hdr, code, status, "application/json", (long)body.size());
    send_str(fd, hdr); send_str(fd, body);
}
static void send_error(int fd, int code, const char* status, const std::string& msg) {
    std::string body = std::string("{\"error\":{\"message\":\"") + json_escape(msg) +
                       "\",\"type\":\"invalid_request_error\"}}";
    send_json(fd, code, status, body);
}

// ----------------------------------------------------------------------------
// Generation sink passed to llama_generate's callback.
// ----------------------------------------------------------------------------
struct GenSink {
    int fd;
    bool stream;
    int  max_tokens;
    int  generated = 0;
    std::string full;                 // full generated text (non-stream + stop match)
    std::vector<std::string> stops;
    std::string stream_id;            // chatcmpl id for chunk objects
    long created = 0;
    bool is_chat = true;              // chat vs legacy completion chunk shape
    bool ok = true;                   // socket still writable
};

static std::string chat_chunk(const std::string& id, long created, const std::string& delta,
                              const char* finish /*nullptr or "stop"/"length"*/) {
    std::string o = "{\"id\":\"" + id + "\",\"object\":\"chat.completion.chunk\",\"created\":" +
                    std::to_string(created) + ",\"model\":\"" + MODEL_ID + "\",\"choices\":[{\"index\":0,\"delta\":";
    if (finish) o += "{},\"finish_reason\":\"" + std::string(finish) + "\"}]}";
    else        o += "{\"content\":\"" + json_escape(delta) + "\"},\"finish_reason\":null}]}";
    return o;
}
static std::string text_chunk(const std::string& id, long created, const std::string& delta,
                              const char* finish) {
    std::string o = "{\"id\":\"" + id + "\",\"object\":\"text_completion\",\"created\":" +
                    std::to_string(created) + ",\"model\":\"" + MODEL_ID + "\",\"choices\":[{\"index\":0,\"text\":\"" +
                    json_escape(delta) + "\",\"finish_reason\":";
    o += finish ? ("\"" + std::string(finish) + "\"") : "null";
    o += "}]}";
    return o;
}

// extern "C" so it matches llama_piece_cb; returns non-zero to stop.
extern "C" int piece_cb(const char* piece, void* user) {
    GenSink* s = (GenSink*)user;
    s->full += piece;
    s->generated++;

    if (s->stream && s->ok) {
        std::string chunk = s->is_chat ? chat_chunk(s->stream_id, s->created, piece, nullptr)
                                       : text_chunk(s->stream_id, s->created, piece, nullptr);
        std::string sse = "data: " + chunk + "\n\n";
        if (!send_str(s->fd, sse)) s->ok = false;   // client hung up
    }
    if (!s->ok) return 1;

    for (const auto& st : s->stops)
        if (!st.empty() && s->full.find(st) != std::string::npos) return 1;

    if (s->generated >= s->max_tokens) return 1;
    return 0;
}

// ----------------------------------------------------------------------------
// Request handling.
// ----------------------------------------------------------------------------
struct Request { std::string method, path, body; };

static bool read_request(int fd, Request& req) {
    std::string data;
    char buf[4096];
    // read headers (until \r\n\r\n)
    size_t hdr_end = std::string::npos;
    while (hdr_end == std::string::npos) {
        ssize_t n = ::recv(fd, buf, sizeof buf, 0);
        if (n <= 0) return false;
        data.append(buf, n);
        hdr_end = data.find("\r\n\r\n");
        if (data.size() > (1u<<20)) return false;   // 1 MB header cap
    }
    // request line
    size_t sp1 = data.find(' ');
    size_t sp2 = data.find(' ', sp1 + 1);
    if (sp1 == std::string::npos || sp2 == std::string::npos) return false;
    req.method = data.substr(0, sp1);
    req.path   = data.substr(sp1 + 1, sp2 - sp1 - 1);
    // Content-Length (case-insensitive-ish; clients send "Content-Length")
    long clen = 0;
    {
        std::string hdrs = data.substr(0, hdr_end);
        for (auto& c : hdrs) c = (char)tolower((unsigned char)c);
        size_t cl = hdrs.find("content-length:");
        if (cl != std::string::npos) clen = strtol(hdrs.c_str() + cl + 15, nullptr, 10);
    }
    std::string body = data.substr(hdr_end + 4);
    if (clen < 0 || clen > (8L<<20)) return false;    // 8 MB body cap
    while ((long)body.size() < clen) {
        ssize_t n = ::recv(fd, buf, sizeof buf, 0);
        if (n <= 0) break;
        body.append(buf, n);
    }
    req.body = body;
    return true;
}

static std::string build_prompt_from_messages(const JValue& msgs) {
    std::string prompt;
    if (msgs.type != JValue::ARR) return prompt;
    for (const auto& m : msgs.arr) {
        const JValue* content = m.find("content");
        if (!content) continue;
        std::string c;
        if (content->type == JValue::STR) c = content->str;              // string content
        else if (content->type == JValue::ARR) {                          // array-of-parts content
            for (const auto& part : content->arr) {
                const JValue* t = part.find("text");
                if (t && t->type == JValue::STR) c += t->str;
            }
        }
        if (!c.empty()) { if (!prompt.empty()) prompt += "\n"; prompt += c; }
    }
    return prompt;
}

static std::vector<std::string> parse_stops(const JValue* stop) {
    std::vector<std::string> v;
    if (!stop) return v;
    if (stop->type == JValue::STR) v.push_back(stop->str);
    else if (stop->type == JValue::ARR)
        for (const auto& s : stop->arr) if (s.type == JValue::STR) v.push_back(s.str);
    return v;
}

// ----------------------------------------------------------------------------
// PL backend: hand the whole prompt to the FPGA and stream its tokens back
// through the SAME sink callback, so streaming / stop strings / max_tokens all
// keep working unchanged.
//
// The PL is greedy-only and capped at MAXPOS positions, so it can only serve a
// subset of requests; run_generation() falls back to the CPU otherwise rather
// than silently ignoring what the client asked for.
// ----------------------------------------------------------------------------
static bool pl_try_generate(GenSink& sink, const std::string& prompt) {
    int ids[64];
    int nprompt = plv1_encode(prompt.c_str(), ids, plv1_maxpos());
    if (nprompt < 1) {
        fprintf(stderr, "[llama_server] prompt does not fit in %d tokens -> CPU\n",
                plv1_maxpos());
        return false;
    }

    int stream[64];
    int n = plv1_generate(ids, nprompt, stream, (int)(sizeof stream / sizeof stream[0]));
    if (n < 0) {
        fprintf(stderr, "[llama_server] PL generate failed (%d) -> CPU\n", n);
        return false;
    }

    // out[0 .. nprompt-2] echo the prompt (teacher forcing); real generation
    // starts at nprompt-1.
    int first = nprompt - 1;
    int prev  = (nprompt >= 1) ? ids[nprompt - 1] : 1;
    for (int i = first; i < n; i++) {
        char piece[64];
        plv1_piece(stream[i], prev, piece, sizeof piece);
        prev = stream[i];
        if (piece[0] && piece_cb(piece, &sink))
            break;                       // stop string / max_tokens / client gone
    }
    return true;
}


// ----------------------------------------------------------------------------
// THE FK33 / Qwen3.5 PATH.  Chat template -> tokenizer -> prefill -> decode
// returning logits -> host sampler -> detokenize -> SSE.
//
// Everything the card does not own is here, which is the point of the v2 seam:
// the sampler is ordinary C++ operating on an int32 logits vector, so
// temperature, top_p and seeds work without any hardware support at all.  On
// the AXU3EG they could not (server/pl_backend_axu3eg.h explains why).
// ----------------------------------------------------------------------------

// The card returns int32 mantissas plus ONE shared block exponent for the row.
// For greedy the exponent is irrelevant -- a shared positive scale does not
// move an argmax, which is exactly the property rtl/lm_head.vhd relies on to
// omit its own x_exp multiply.  For temperature it is NOT irrelevant: dividing
// by T before the softmax makes the absolute scale matter.  So it is applied.
static void logits_to_float(const int32_t* mant, int n, int32_t exp,
                            std::vector<float>& out) {
    float scale = ldexpf(1.0f, exp);
    out.resize((size_t)n);
    for (int i = 0; i < n; i++) out[(size_t)i] = (float)mant[i] * scale;
}

// xorshift64*, so a seed reproduces a run without pulling in <random>'s
// implementation-defined engines.
static inline uint64_t rng_next(uint64_t& s) {
    s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
    return s * 2685821657736338717ULL;
}

static int sample_from(std::vector<float>& f, float temperature, float top_p,
                       uint64_t& seed) {
    const int n = (int)f.size();
    if (temperature <= 0.0f) {                      // greedy, first max on ties
        int best = 0;
        for (int i = 1; i < n; i++) if (f[(size_t)i] > f[(size_t)best]) best = i;
        return best;
    }
    // softmax at temperature, in float, with the max subtracted
    float mx = f[0];
    for (int i = 1; i < n; i++) mx = std::max(mx, f[(size_t)i]);
    double sum = 0.0;
    std::vector<double> p((size_t)n);
    for (int i = 0; i < n; i++) {
        double e = exp((double)((f[(size_t)i] - mx) / temperature));
        p[(size_t)i] = e; sum += e;
    }
    for (int i = 0; i < n; i++) p[(size_t)i] /= sum;

    std::vector<int> idx((size_t)n);
    for (int i = 0; i < n; i++) idx[(size_t)i] = i;
    if (top_p > 0.0f && top_p < 1.0f) {
        std::sort(idx.begin(), idx.end(),
                  [&](int a, int b) { return p[(size_t)a] > p[(size_t)b]; });
        double acc = 0.0; size_t keep = 0;
        for (; keep < idx.size(); keep++) {
            acc += p[(size_t)idx[keep]];
            if (acc >= (double)top_p) { keep++; break; }
        }
        idx.resize(keep ? keep : 1);
    }
    double tot = 0.0;
    for (int i : idx) tot += p[(size_t)i];
    double r = (double)(rng_next(seed) >> 11) / 9007199254740992.0 * tot;
    double acc = 0.0;
    for (int i : idx) { acc += p[(size_t)i]; if (r < acc) return i; }
    return idx.back();
}

// A token's bytes may end mid-UTF-8-sequence.  Emitting that straight into a
// JSON string produces invalid JSON, so incomplete tails are held back until
// the next token completes them.  This is not theoretical for a byte-level BPE
// vocabulary: a single emoji is routinely several tokens.
// Replace anything that is not a well-formed UTF-8 sequence with U+FFFD.
// json_escape passes bytes >= 0x20 through raw, so an ill-formed byte would
// produce a JSON string that is not valid UTF-8 and that some clients reject
// outright.  The gate below never EMITS a truncated sequence -- it holds it
// back or drops it -- so the only way here is genuinely malformed model
// output, but "rare" is not "impossible" for a byte-level BPE vocabulary.
static std::string utf8_sanitize(const std::string& s) {
    std::string o; o.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        size_t need = c < 0x80u ? 1 : (c & 0xE0u) == 0xC0u ? 2
                    : (c & 0xF0u) == 0xE0u ? 3 : (c & 0xF8u) == 0xF0u ? 4 : 0;
        bool ok = need && i + need <= s.size();
        for (size_t k = 1; ok && k < need; k++)
            if (((unsigned char)s[i + k] & 0xC0u) != 0x80u) ok = false;
        if (ok) { o.append(s, i, need); i += need; }
        else    { o += "\xEF\xBF\xBD"; i++; }
    }
    return o;
}

struct Utf8Gate {
    std::string pend;
    std::string feed(const std::string& bytes) {
        pend += bytes;
        size_t cut = pend.size();
        // walk back over at most 3 continuation bytes to find a boundary
        size_t i = pend.size();
        while (i > 0 && i + 4 > pend.size()) {
            unsigned char c = (unsigned char)pend[i - 1];
            if ((c & 0xC0u) == 0x80u) { i--; continue; }
            size_t need = c < 0x80u ? 1 : (c & 0xE0u) == 0xC0u ? 2
                        : (c & 0xF0u) == 0xE0u ? 3 : (c & 0xF8u) == 0xF0u ? 4 : 1;
            if (i - 1 + need > pend.size()) cut = i - 1;
            break;
        }
        std::string out = pend.substr(0, cut);
        pend.erase(0, cut);
        return out;
    }
};

// Build the message list the renderer wants out of the OpenAI request body.
// Refusals are the renderer's, not this function's: anything it cannot express
// (a vision part, a tool call) is turned into the role/flag the renderer will
// refuse, so exactly one place decides what is in scope.
static int build_chat_msgs(const JValue& msgs, std::vector<qwen35_chat_msg>& out,
                           std::vector<std::string>& hold, std::string& why) {
    if (msgs.type != JValue::ARR) { why = "'messages' must be an array"; return -1; }
    hold.reserve(msgs.arr.size() * 2);
    for (const auto& m : msgs.arr) {
        qwen35_chat_msg q{};
        const JValue* r = m.find("role");
        std::string role = r ? r->as_str("") : "";
        q.role = role == "system"    ? QWEN35_ROLE_SYSTEM
               : role == "user"      ? QWEN35_ROLE_USER
               : role == "assistant" ? QWEN35_ROLE_ASSISTANT
               : role == "tool"      ? QWEN35_ROLE_TOOL
                                     : QWEN35_ROLE_OTHER;
        if (m.find("tool_calls")) { why = qwen35_chat_strerror(QWEN35_CHAT_E_TOOLCALLS); return QWEN35_CHAT_E_TOOLCALLS; }

        std::string c;
        const JValue* content = m.find("content");
        if (content && content->type == JValue::STR) c = content->str;
        else if (content && content->type == JValue::ARR) {
            for (const auto& part : content->arr) {
                const JValue* t = part.find("type");
                std::string ty = t ? t->as_str("") : "";
                if (ty == "image_url" || ty == "image" || ty == "video"
                    || part.find("image_url") || part.find("image")) {
                    why = qwen35_chat_strerror(QWEN35_CHAT_E_VISION);
                    return QWEN35_CHAT_E_VISION;
                }
                const JValue* txt = part.find("text");
                if (txt && txt->type == JValue::STR) c += txt->str;
            }
        }
        hold.push_back(c);
        q.content = hold.back().data();
        q.content_len = hold.back().size();

        const JValue* rc = m.find("reasoning_content");
        if (rc && rc->type == JValue::STR) {
            hold.push_back(rc->str);
            q.has_reasoning = 1;
            q.reasoning = hold.back().data();
            q.reasoning_len = hold.back().size();
        }
        out.push_back(q);
    }
    // hold may have reallocated; re-point every span now that it is stable.
    {
        size_t k = 0;
        for (size_t i = 0; i < out.size(); i++) {
            out[i].content = hold[k].data(); out[i].content_len = hold[k].size(); k++;
            if (out[i].has_reasoning) {
                out[i].reasoning = hold[k].data(); out[i].reasoning_len = hold[k].size(); k++;
            }
        }
    }
    return 0;
}

// Returns 0, or a negative code with `why` set.  Fills the sink.
static int qwen_generate(GenSink& sink, const JValue& root, bool is_chat,
                         float temperature, float top_p, unsigned long long seed,
                         std::string& why) {
    std::vector<int> ids;
    std::vector<qwen35_chat_msg> msgs;
    std::vector<std::string> hold;

    if (is_chat) {
        const JValue* jm = root.find("messages");
        if (!jm) { why = "missing 'messages'"; return -1; }
        if (root.find("tools")) { why = qwen35_chat_strerror(QWEN35_CHAT_E_TOOLS); return -1; }
        int rc = build_chat_msgs(*jm, msgs, hold, why);
        if (rc) return -1;

        // enable_thinking defaults to FALSE, which is NOT "emit nothing": the
        // template's own default branch emits an empty, already-closed
        // reasoning block.  See qwen35_tok.h.
        int think = 0;
        const JValue* et = root.find("enable_thinking");
        if (et) think = et->as_bool(false) ? 1 : 0;

        int cap = 8192, n, want = 0;
        for (;;) {
            ids.resize((size_t)cap);
            n = qwen35_chat_tokenize(g_tok, msgs.data(), (int)msgs.size(), 1, think,
                                     ids.data(), cap, &want);
            if (n >= 0) break;
            if (n == QWEN35_CHAT_E_SHORT && want > cap) { cap = want; continue; }
            why = qwen35_chat_strerror(n);
            return -1;
        }
        ids.resize((size_t)n);
    } else {
        const JValue* p = root.find("prompt");
        if (!p) { why = "missing 'prompt'"; return -1; }
        std::string text = p->as_str("");
        int cap = (int)text.size() + 8;
        ids.resize((size_t)cap);
        int n = qwen35_tok_encode(g_tok, text.data(), text.size(), ids.data(), cap, 1);
        if (n < 0) { why = "tokenize failed"; return -1; }
        ids.resize((size_t)n);
    }

    if (ids.empty()) { why = "the rendered prompt tokenized to nothing"; return -1; }
    if ((int)ids.size() >= pl_max_ctx(g_card)) {
        why = "prompt longer than the card's KV capacity";
        return -1;
    }

    const int nv = pl_n_vocab(g_card);
    std::vector<int32_t> logits((size_t)nv);
    std::vector<float>   f;
    int32_t lexp = 0;
    int am = 0;

    if (pl_seq_reset(g_card) < 0) { why = "seq_reset failed"; return -1; }
    int rc = pl_prefill(g_card, ids.data(), (int)ids.size(),
                        logits.data(), &lexp, &am);
    if (rc < 0) {
        why = std::string("prefill failed (") + std::to_string(rc) + "): "
            + pl_last_error_str(g_card);
        return -1;
    }

    const int eos = qwen35_tok_eos(g_tok);
    const int eot = qwen35_tok_id_of(g_tok, "<|endoftext|>", 13);
    uint64_t rs = seed ? seed : 0x9E3779B97F4A7C15ULL;
    Utf8Gate gate;

    for (int step = 0; step < sink.max_tokens; step++) {
        int tok;
        if (temperature <= 0.0f) {
            tok = am;                 // the card's own argmax; no float needed
        } else {
            logits_to_float(logits.data(), nv, lexp, f);
            tok = sample_from(f, temperature, top_p, rs);
        }
        if (tok == eos || (eot >= 0 && tok == eot)) break;

        char buf[512];
        int nb = qwen35_tok_piece(g_tok, tok, buf, (int)sizeof buf, 0);
        if (nb < 0) nb = 0;
        std::string emit = utf8_sanitize(gate.feed(std::string(buf, (size_t)nb)));
        if (!emit.empty() && piece_cb(emit.c_str(), &sink)) break;
        if (!sink.ok) break;

        if (pl_seq_pos(g_card) + 1 >= pl_max_ctx(g_card)) break;
        rc = pl_decode(g_card, tok, temperature > 0.0f ? logits.data() : nullptr,
                       &lexp, &am);
        if (rc < 0) {
            why = std::string("decode failed (") + std::to_string(rc) + "): "
                + pl_last_error_str(g_card);
            return -1;
        }
    }
    return 0;
}

// Run generation under the mutex; fills sink. Returns after generation ends.
// Set by run_generation when the qwen path refuses a request, so the caller
// can turn it into a 400 with the renderer's own words instead of an empty 200.
static thread_local std::string g_qwen_why;

static void run_generation(GenSink& sink, const std::string& prompt,
                           float temperature, float top_p, unsigned long long seed,
                           const JValue* root = nullptr, bool is_chat = true) {
    std::lock_guard<std::mutex> lk(g_gen_mutex);

    if (g_qwen) {
        g_qwen_why.clear();
        if (qwen_generate(sink, *root, is_chat, temperature, top_p, seed,
                          g_qwen_why) < 0)
            fprintf(stderr, "[llama_server] qwen request refused: %s\n",
                    g_qwen_why.c_str());
        return;
    }

    // The hardware has no sampler -- it is a running argmax -- so a request that
    // asks for temperature > 0 genuinely cannot be served by the PL.  Fall back
    // to the CPU (which is token-identical at temperature 0 anyway) instead of
    // pretending we honoured it.
    if (g_use_pl) {
        if (temperature > 0.0f) {
            fprintf(stderr, "[llama_server] temperature=%.3f requested; the PL is "
                            "greedy-only -> CPU for this request\n", temperature);
        } else if (pl_try_generate(sink, prompt)) {
            return;
        }
    }
    // steps = 0 -> llama caps at seq_len; the callback stops at max_tokens/stop.
    llama_generate(g_ctx, prompt.c_str(), 0, temperature, top_p, seed, piece_cb, &sink);
}

static const char* finish_reason(const GenSink& s) {
    for (const auto& st : s.stops)
        if (!st.empty() && s.full.find(st) != std::string::npos) return "stop";
    return s.generated >= s.max_tokens ? "length" : "stop";
}

// Truncate full text at the first stop string (so non-stream responses exclude it).
static std::string apply_stops(const std::string& full, const std::vector<std::string>& stops) {
    size_t cut = std::string::npos;
    for (const auto& st : stops) {
        if (st.empty()) continue;
        size_t pos = full.find(st);
        if (pos != std::string::npos && pos < cut) cut = pos;
    }
    return cut == std::string::npos ? full : full.substr(0, cut);
}

static void handle_completion(int fd, const JValue& root, bool is_chat) {
    // params
    float temperature = (float)(root.find("temperature") ? root.find("temperature")->as_num(0.0) : 0.0);
    float top_p       = (float)(root.find("top_p") ? root.find("top_p")->as_num(0.9) : 0.9);
    int   max_tokens  = (int)(root.find("max_tokens") ? root.find("max_tokens")->as_num(256) : 256);
    bool  stream      = root.find("stream") ? root.find("stream")->as_bool(false) : false;
    if (max_tokens <= 0) max_tokens = 256;
    int cap = g_qwen ? pl_max_ctx(g_card) : llama_seq_len(g_ctx);
    if (max_tokens > cap) max_tokens = cap;
    unsigned long long seed = root.find("seed") ? (unsigned long long)root.find("seed")->as_num(0) : (unsigned long long)time(nullptr);

    std::string prompt;
    if (!g_qwen) {
        if (is_chat) {
            const JValue* msgs = root.find("messages");
            if (!msgs || msgs->type != JValue::ARR) { send_error(fd, 400, "Bad Request", "missing 'messages'"); return; }
            prompt = build_prompt_from_messages(*msgs);
        } else {
            const JValue* p = root.find("prompt");
            if (!p) { send_error(fd, 400, "Bad Request", "missing 'prompt'"); return; }
            prompt = p->as_str("");
        }
        if (prompt.empty()) prompt = " ";
    }

    GenSink sink;
    sink.fd = fd; sink.stream = stream; sink.max_tokens = max_tokens;
    sink.stops = parse_stops(root.find("stop"));
    sink.stream_id = gen_id(is_chat ? "chatcmpl" : "cmpl");
    sink.created = now_sec();
    sink.is_chat = is_chat;

    if (stream) {
        std::string hdr; http_headers(hdr, 200, "OK", "text/event-stream", -1);
        if (!send_str(fd, hdr)) return;
        run_generation(sink, prompt, temperature, top_p, seed, &root, is_chat);
        // final chunk + [DONE]
        const char* fr = finish_reason(sink);
        std::string last = sink.is_chat ? chat_chunk(sink.stream_id, sink.created, "", fr)
                                        : text_chunk(sink.stream_id, sink.created, "", fr);
        send_str(fd, "data: " + last + "\n\n");
        send_str(fd, "data: [DONE]\n\n");
    } else {
        run_generation(sink, prompt, temperature, top_p, seed, &root, is_chat);
        if (!g_qwen_why.empty()) { send_error(fd, 400, "Bad Request", g_qwen_why); return; }
        std::string text = apply_stops(sink.full, sink.stops);
        const char* fr = finish_reason(sink);
        std::string body;
        if (is_chat) {
            body = "{\"id\":\"" + sink.stream_id + "\",\"object\":\"chat.completion\",\"created\":" +
                   std::to_string(sink.created) + ",\"model\":\"" + MODEL_ID +
                   "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"" +
                   json_escape(text) + "\"},\"finish_reason\":\"" + fr + "\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":" +
                   std::to_string(sink.generated) + ",\"total_tokens\":" + std::to_string(sink.generated) + "}}";
        } else {
            body = "{\"id\":\"" + sink.stream_id + "\",\"object\":\"text_completion\",\"created\":" +
                   std::to_string(sink.created) + ",\"model\":\"" + MODEL_ID +
                   "\",\"choices\":[{\"index\":0,\"text\":\"" + json_escape(text) +
                   "\",\"finish_reason\":\"" + fr + "\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":" +
                   std::to_string(sink.generated) + ",\"total_tokens\":" + std::to_string(sink.generated) + "}}";
        }
        send_json(fd, 200, "OK", body);
    }
}

static void handle_models(int fd) {
    if (g_qwen) {
        std::string body =
            std::string("{\"object\":\"list\",\"data\":[{\"id\":\"qwen3.5-9b-fk33\"")
            + ",\"object\":\"model\",\"created\":" + std::to_string(now_sec())
            + ",\"owned_by\":\"llama.vhdl\",\"backend\":\"fk33-seam-v2\""
            + ",\"backend_detail\":\"" + json_escape(pl_describe(g_card)) + "\""
            + ",\"n_vocab\":" + std::to_string(pl_n_vocab(g_card))
            + ",\"n_ctx\":" + std::to_string(pl_max_ctx(g_card))
            + ",\"description\":\"THE OUTPUT OF THIS MODEL IS NOT INFERENCE. "
              "The FK33 host seam runs against a SIMULATED card that does not "
              "execute a transformer, and no whole-model 9B numeric reference "
              "exists in this repository. What is real: the Qwen3.5 chat "
              "template, the tokenizer (bit-exact vs llama.cpp), the "
              "prefill/decode-returning-logits seam, and the host sampler. "
              "What is not: every token.\"}]}";
        send_json(fd, 200, "OK", body);
        return;
    }
    std::string body =
        std::string("{\"object\":\"list\",\"data\":[{\"id\":\"") + MODEL_ID +
        "\",\"object\":\"model\",\"created\":" + std::to_string(now_sec()) +
        ",\"owned_by\":\"llama.vhdl\",\"description\":\"Fixed-point stories260K (TinyStories) — "
        "token-identical to the AXU3EG VHDL engine. Continues children's-story prose; does NOT follow chat instructions. "
        "Greedy (temperature 0) = hardware-exact.\",\"backend\":\"" +
        std::string(g_use_pl ? "fpga-pl" : "cpu") + "\"" +
        (g_use_pl ? std::string(",\"backend_detail\":\"") + plv1_describe() +
                    "\",\"max_total_tokens\":" + std::to_string(plv1_maxpos()) +
                    ",\"note\":\"greedy requests run on the FPGA; temperature>0 falls back to the CPU\""
                  : std::string()) +
        "}]}";
    send_json(fd, 200, "OK", body);
}

static void handle_conn(int fd) {
    Request req;
    if (!read_request(fd, req)) { close(fd); return; }

    if (req.method == "OPTIONS") {
        std::string hdr; http_headers(hdr, 204, "No Content", "text/plain", 0);
        send_str(fd, hdr); close(fd); return;
    }
    if (req.method == "GET" && req.path.rfind("/v1/models", 0) == 0) { handle_models(fd); close(fd); return; }

    if (req.method == "POST" &&
        (req.path.rfind("/v1/chat/completions", 0) == 0 || req.path.rfind("/v1/completions", 0) == 0)) {
        bool is_chat = req.path.rfind("/v1/chat/completions", 0) == 0;
        JParser jp{ req.body.data(), req.body.data() + req.body.size() };
        JValue root = jp.parse();
        if (!jp.ok || root.type != JValue::OBJ) { send_error(fd, 400, "Bad Request", "invalid JSON body"); close(fd); return; }
        handle_completion(fd, root, is_chat);
        close(fd); return;
    }

    send_error(fd, 404, "Not Found", "unknown endpoint");
    close(fd);
}

int main(int argc, char** argv) {
    const char* checkpoint = "ref/stories260K.bin";
    const char* tokenizer  = "ref/tok512.bin";
    const char* host = "0.0.0.0";
    int port = 8000;
    bool want_pl = false;
    int  pl_clock = 80;          // fastest clock that meets worst-case timing
    const char* model = "stories260k";
    const char* qtk   = "build_artifacts_tok/qwen35_9b.qtk";
    const char* card  = "sim";
    const char* card_dir = "fk33_file_backend";
    // WHICH COPY OF THE EMBEDDING THE HOST GATHERS.  "auto" means the BF16
    // GGUF if it is present, else the synthetic provider, and the choice is
    // PRINTED either way -- an embedding silently 1,803x coarser than the one
    // the reference evaluated is the exact failure this flag exists to name.
    // See docs/debugging/2026-08-29_embedding-bf16-upgrade.md.
    const char* embed_kind = "auto";
    const char* embed_path = nullptr;
    const char* embed_gguf_default =
        "/mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf";
    const char* embed_mv4i_default =
        "/mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--model") && i+1<argc) model = argv[++i];
        else if (!strcmp(argv[i], "--qtk") && i+1<argc) qtk = argv[++i];
        else if (!strcmp(argv[i], "--card") && i+1<argc) card = argv[++i];
        else if (!strcmp(argv[i], "--card-dir") && i+1<argc) card_dir = argv[++i];
        else if (!strcmp(argv[i], "--checkpoint") && i+1<argc) checkpoint = argv[++i];
        else if (!strcmp(argv[i], "--tokenizer") && i+1<argc) tokenizer = argv[++i];
        else if (!strcmp(argv[i], "--host") && i+1<argc) host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i+1<argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pl")) want_pl = true;
        else if (!strcmp(argv[i], "--pl-clock") && i+1<argc) pl_clock = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--embed") && i+1<argc) embed_kind = argv[++i];
        else if (!strcmp(argv[i], "--embed-path") && i+1<argc) embed_path = argv[++i];
        else { fprintf(stderr,
                "usage: %s [--model stories260k|qwen35] [--host h] [--port p]\n"
                "          [--checkpoint f] [--tokenizer f] [--pl] [--pl-clock MHZ]\n"
                "          [--qtk f] [--card sim|file] [--card-dir d]\n"
                "          [--embed auto|gguf|mv4i|synthetic] [--embed-path f]\n"
                "  --embed     which copy of the EMBEDDING the host gathers.\n"
                "              gguf      the BF16 row from the original GGUF.  This\n"
                "                        is what ref/run9b.c evaluates by default\n"
                "                        since 2026-08-29 and is far more\n"
                "                        accurate at the activation than mv4i\n"
                "                        (roughly 2,000x; see the write-up).\n"
                "              mv4i      the packed INT4 row.  The PRE-2026-08-29\n"
                "                        basis; kept so old results stay\n"
                "                        reproducible.\n"
                "              synthetic NOT A MODEL OF ANYTHING.\n"
                "              auto      (default) gguf if its file is present,\n"
                "                        else synthetic.  The choice is printed.\n"
                "              An EXPLICIT gguf or mv4i whose file will not open is\n"
                "              a refusal, never a quiet downgrade.\n"
                "  --model qwen35\n"
                "              serve Qwen3.5-9B through the FK33 host seam v2:\n"
                "              the C chat template, the C tokenizer and\n"
                "              prefill/decode-returning-logits.  THE TOKENS ARE\n"
                "              NOT INFERENCE -- the only card backends are a\n"
                "              simulation and a file, neither runs a transformer,\n"
                "              and no whole-model 9B reference exists here.\n"
                "  --card      sim (default, the modelled seam engine) or file\n"
                "              (the REAL transport pointed at ordinary files).\n"
                "              There is deliberately no flag that opens /dev/xdma*.\n"
                "  --pl        run greedy (temperature 0) requests on the FPGA engine\n"
                "              over /dev/mem; needs root and the engine bitstream.\n"
                "              Sampling requests still use the CPU -- the PL has no\n"
                "              sampler.  Prompt+completion is capped at the core's\n"
                "              MAXPOS (24) tokens.\n"
                "  --pl-clock  PL clock in MHz (default %d; above ~85 is out of spec)\n",
                argv[0], pl_clock); return 1; }
    }
    signal(SIGPIPE, SIG_IGN);

    if (!strcmp(model, "qwen35")) {
        pl_open_opts o;
        pl_open_opts_default(&o);
        if (!strcmp(card, "file")) { o.transport = PL_TRANSPORT_FILE; o.file_dir = card_dir; }
        else if (!strcmp(card, "sim")) { o.transport = PL_TRANSPORT_SIM; }
        else {
            fprintf(stderr, "[llama_server] --card %s is not available.  The only\n"
                            "  backends are 'sim' and 'file'.  Talking to the actual\n"
                            "  card is deliberately not reachable from this binary:\n"
                            "  see the tripwire in server/fk33_transport.h and the\n"
                            "  hardware boundary in CLAUDE.md.\n", card);
            return 1;
        }
        // ---- the embedding provider.  See --embed in the usage above.
        pl_embed_mv4i_t *emb_mv4i = nullptr;
        pl_embed_bf16_t *emb_bf16 = nullptr;
        const char *chosen = nullptr, *why = "";

        if (!strcmp(embed_kind, "auto")) {
            FILE *probe = fopen(embed_path ? embed_path : embed_gguf_default, "rb");
            if (probe) { fclose(probe); embed_kind = "gguf"; why = " (auto: the BF16 checkpoint is present)"; }
            else       { embed_kind = "synthetic"; why = " (auto: no BF16 checkpoint at the default path)"; }
        }

        if (!strcmp(embed_kind, "gguf")) {
            const char *path = embed_path ? embed_path : embed_gguf_default;
            if (pl_embed_bf16_open(path, nullptr, &emb_bf16) != 0) {
                fprintf(stderr, "[llama_server] --embed gguf could not open %s.\n"
                        "  REFUSED rather than downgraded: falling back to the INT4\n"
                        "  copy would serve an activation ~2,000x coarser than the one\n"
                        "  the reference evaluates, with nothing in the log to say so.\n"
                        "  Pass --embed-path, --embed mv4i, or --embed synthetic.\n", path);
                return 1;
            }
            o.embed = pl_embed_bf16;
            o.embed_user = emb_bf16;
            chosen = pl_embed_bf16_describe(emb_bf16);
        } else if (!strcmp(embed_kind, "mv4i")) {
            const char *path = embed_path ? embed_path : embed_mv4i_default;
            if (pl_embed_mv4i_open(path, PL_EMBED_RECIPE_WIDE, &emb_mv4i) != 0) {
                fprintf(stderr, "[llama_server] --embed mv4i could not open %s\n", path);
                return 1;
            }
            o.embed = pl_embed_mv4i;
            o.embed_user = emb_mv4i;
            chosen = pl_embed_mv4i_describe(emb_mv4i);
        } else if (!strcmp(embed_kind, "synthetic")) {
            o.embed = pl_embed_synthetic;
            chosen = "SYNTHETIC -- not a model of anything";
        } else {
            fprintf(stderr, "[llama_server] --embed %s is not one of "
                            "auto|gguf|mv4i|synthetic\n", embed_kind);
            return 1;
        }
        fprintf(stderr, "[llama_server] embedding: %s%s\n    %s\n",
                embed_kind, why, chosen);

        g_tok = qwen35_tok_open(qtk);
        if (!g_tok) {
            fprintf(stderr, "[llama_server] cannot open %s.  Regenerate it with\n"
                            "  tools/extract_tokenizer.py; it is 9 MB and not committed.\n", qtk);
            return 1;
        }
        if (pl_open(&o, &g_card) != 0) {
            fprintf(stderr, "[llama_server] pl_open failed\n");
            return 1;
        }
        // Two independent artefacts, compared rather than trusted.  MEASURED
        // 2026-08-29: llama.cpp's own loader reports n=248320 for this GGUF,
        // which settles the audit's 248,320-vs-151,936 question for the 9B.
        if (pl_check_vocab(g_card, qwen35_tok_n_vocab(g_tok)) != 0) {
            fprintf(stderr, "[llama_server] refusing to serve with a vocabulary "
                            "disagreement\n");
            return 1;
        }
        g_qwen = true;
        MODEL_ID = "qwen3.5-9b-fk33";
        fprintf(stderr,
            "[llama_server] Qwen3.5 / FK33 seam v2: %s\n"
            "[llama_server] tokenizer %s: n_vocab=%d eos=%d bos=%d add_bos=%d pre=%s\n"
            "[llama_server] *** THE TOKENS THIS SERVER PRODUCES ARE NOT INFERENCE. ***\n"
            "[llama_server]     No transformer runs.  See /v1/models.\n",
            pl_describe(g_card), qtk, qwen35_tok_n_vocab(g_tok),
            qwen35_tok_eos(g_tok), qwen35_tok_bos(g_tok),
            qwen35_tok_add_bos(g_tok), qwen35_tok_pre(g_tok));

        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) { perror("socket"); return 1; }
        int one = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)port);
        addr.sin_addr.s_addr = inet_addr(host);
        if (bind(srv, (sockaddr*)&addr, sizeof addr) < 0) { perror("bind"); return 1; }
        if (listen(srv, 16) < 0) { perror("listen"); return 1; }
        fprintf(stderr, "[llama_server] listening on http://%s:%d/v1 (model: qwen3.5-9b-fk33)\n",
                host, port);
        for (;;) {
            int fd = accept(srv, nullptr, nullptr);
            if (fd < 0) continue;
            std::thread(handle_conn, fd).detach();
        }
    }

    fprintf(stderr, "[llama_server] loading %s + %s ...\n", checkpoint, tokenizer);
    g_ctx = llama_load(checkpoint, tokenizer);
    if (!g_ctx) { fprintf(stderr, "[llama_server] failed to load model\n"); return 1; }
    fprintf(stderr, "[llama_server] model loaded: vocab=%d seq_len=%d\n",
            llama_vocab(g_ctx), llama_seq_len(g_ctx));

    if (want_pl) {
        int rc = plv1_open(pl_clock);
        if (rc == 0) {
            g_use_pl = true;
            fprintf(stderr, "[llama_server] PL backend ENABLED: %s\n", plv1_describe());
            fprintf(stderr, "[llama_server]   greedy requests run on the FPGA; "
                            "temperature>0 falls back to the CPU\n");
            fprintf(stderr, "[llama_server]   prompt+completion capped at %d tokens\n",
                    plv1_maxpos());
        } else {
            fprintf(stderr, "[llama_server] PL backend UNAVAILABLE (pl_open=%d) -- "
                            "running on the CPU.  Need root, /dev/mem and the engine "
                            "bitstream.\n", rc);
        }
    }

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr(host);
    if (bind(srv, (sockaddr*)&addr, sizeof addr) < 0) { perror("bind"); return 1; }
    if (listen(srv, 16) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "[llama_server] listening on http://%s:%d/v1 (model: %s)\n", host, port, MODEL_ID);

    for (;;) {
        int fd = accept(srv, nullptr, nullptr);
        if (fd < 0) continue;
        std::thread(handle_conn, fd).detach();   // thread per connection; generation is mutex-serialized
    }
    return 0;
}
