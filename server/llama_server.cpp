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

#include "llama_fx.h"

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
static const char* MODEL_ID = "stories260k";

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

// Run generation under the mutex; fills sink. Returns after generation ends.
static void run_generation(GenSink& sink, const std::string& prompt,
                           float temperature, float top_p, unsigned long long seed) {
    std::lock_guard<std::mutex> lk(g_gen_mutex);
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
    int cap = llama_seq_len(g_ctx);
    if (max_tokens > cap) max_tokens = cap;
    unsigned long long seed = root.find("seed") ? (unsigned long long)root.find("seed")->as_num(0) : (unsigned long long)time(nullptr);

    std::string prompt;
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

    GenSink sink;
    sink.fd = fd; sink.stream = stream; sink.max_tokens = max_tokens;
    sink.stops = parse_stops(root.find("stop"));
    sink.stream_id = gen_id(is_chat ? "chatcmpl" : "cmpl");
    sink.created = now_sec();
    sink.is_chat = is_chat;

    if (stream) {
        std::string hdr; http_headers(hdr, 200, "OK", "text/event-stream", -1);
        if (!send_str(fd, hdr)) return;
        run_generation(sink, prompt, temperature, top_p, seed);
        // final chunk + [DONE]
        const char* fr = finish_reason(sink);
        std::string last = sink.is_chat ? chat_chunk(sink.stream_id, sink.created, "", fr)
                                        : text_chunk(sink.stream_id, sink.created, "", fr);
        send_str(fd, "data: " + last + "\n\n");
        send_str(fd, "data: [DONE]\n\n");
    } else {
        run_generation(sink, prompt, temperature, top_p, seed);
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
    std::string body =
        std::string("{\"object\":\"list\",\"data\":[{\"id\":\"") + MODEL_ID +
        "\",\"object\":\"model\",\"created\":" + std::to_string(now_sec()) +
        ",\"owned_by\":\"llama.vhdl\",\"description\":\"Fixed-point stories260K (TinyStories) — "
        "token-identical to the AXU3EG VHDL engine. Continues children's-story prose; does NOT follow chat instructions. "
        "Greedy (temperature 0) = hardware-exact.\"}]}";
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
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--checkpoint") && i+1<argc) checkpoint = argv[++i];
        else if (!strcmp(argv[i], "--tokenizer") && i+1<argc) tokenizer = argv[++i];
        else if (!strcmp(argv[i], "--host") && i+1<argc) host = argv[++i];
        else if (!strcmp(argv[i], "--port") && i+1<argc) port = atoi(argv[++i]);
        else { fprintf(stderr, "usage: %s [--checkpoint f] [--tokenizer f] [--host h] [--port p]\n", argv[0]); return 1; }
    }
    signal(SIGPIPE, SIG_IGN);

    fprintf(stderr, "[llama_server] loading %s + %s ...\n", checkpoint, tokenizer);
    g_ctx = llama_load(checkpoint, tokenizer);
    if (!g_ctx) { fprintf(stderr, "[llama_server] failed to load model\n"); return 1; }
    fprintf(stderr, "[llama_server] model loaded: vocab=%d seq_len=%d\n",
            llama_vocab(g_ctx), llama_seq_len(g_ctx));

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
