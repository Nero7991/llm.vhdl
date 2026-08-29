// tools/ref9b/dump_llamacpp.cpp -- the EXTERNAL float anchor for Qwen3.5-9B.
//
// WHY THIS EXISTS, AND WHY IT IS NOT A REFERENCE I WROTE.
// This track's central risk is the m7 mutant: a reference and an RTL that
// share their author's wrong idea agree with each other and are both wrong.
// Writing a second implementation of Qwen3.5 from the same reading of the same
// spec would reproduce that failure exactly.  So the ALGORITHMIC truth for the
// 9B is taken from llama.cpp, which nobody here wrote, which is exercised by a
// large user base against the published model, and which is already the oracle
// this project used to certify the tokenizer bit-exactly over 53,409 strings.
//
// It captures the f32 value of every graph node whose name matches a filter,
// for every token of a fixed prompt, into the shared seam-stream format.  The
// fixed-point reference (ref/run9b.c) writes the SAME format, and
// tools/ref9b/seam_bisect.py reports the first seam at which two streams diverge.
//
// WHAT IT CANNOT DO.  It is float.  It can never be bit-exact against
// fixed-point hardware, and this file makes no such claim: it is the
// ALGORITHM oracle, and the fixed-point reference is the BIT oracle.  The gap
// between them is measured, not assumed -- see
// docs/debugging/2026-08-29_9b-whole-model-reference.md.
//
// THE MEASUREMENT TRAP THIS TOOL CAN CREATE, AND THE CHECK FOR IT.
// Asking for a node through cb_eval makes ggml_backend_sched cut the graph at
// that node, which can suppress op fusion that would otherwise happen.  A
// suppressed fusion changes rounding.  So --selfcheck runs the same prompt
// twice, once with the callback installed and once without, and compares the
// argmax and the raw logits of every position.  A run whose numbers are quoted
// without that check is not interpretable.  gdn_probe.cpp records the same
// hazard for its own substitution path and calls its version `identity`.
//
// Build: bash tools/ref9b/build.sh
// No file in the llama.cpp tree is written, rebuilt or relinked.

#include "llama.h"
#include "ggml.h"
#include "ggml-backend.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <map>

#include "seam_stream.h"

// ------------------------------------------------------------------ options
struct Opts {
    std::string model;
    std::string out;
    std::string prompt = "The capital of France is";
    std::vector<std::string> include;
    std::vector<llama_token> toks;      // explicit token ids override prompt
    int  n_ctx   = 512;
    int  threads = 12;
    int  ngl     = 0;                   // CPU by default: the GPUs carry a service
    bool all     = false;
    bool selfcheck = false;
    bool list    = false;
} O;

// The curated seam list.  These are llama.cpp's own node names for arch
// `qwen35`, read off a live `llama-eval-callback` run on the 9B (MEASURED,
// 2026-08-29), not guessed from the spec.  `-L` is the layer index.
//
//   GDN layer (llama.cpp calls it the linear-attention layer):
//     attn_norm             the post-norm activation entering the block
//     linear_attn_qkv_mixed the fused q|k|v projection = subsystem A job
//     conv_output_silu      after the 4-tap causal conv and its SiLU
//     q_conv k_conv         after L2 norm
//     *_predelta            the tensors entering the delta rule
//     alpha a_softplus gate beta beta_sigmoid   the decay/gate scalars
//     attn_output           the recurrence output
//     final_output          after the output RMS norm and the z gate
//     linear_attn_out       the ssm_out projection = subsystem A job
//   attention layer:
//     Qcur_full             q|gate fused projection (attn_q, M = 8192)
//     Qcur_normed Kcur_normed   after q_norm / k_norm
//     Qcur Kcur Vcur        after RoPE, as fed to the attention kernel
//     attn_pregate          the attention kernel output before gating
//     gate_sigmoid attn_gated attn_output
//   both:
//     attn_residual attn_post_norm ffn_gate ffn_up ffn_swiglu ffn_out l_out
//   whole model:
//     result_norm result_output
static const char *DEFAULT_SEAMS[] = {
    "attn_norm-", "linear_attn_qkv_mixed-", "conv_output_silu-",
    "q_conv-", "k_conv-", "q_conv_predelta-", "k_conv_predelta-",
    "v_conv_predelta-", "alpha-", "a_softplus-", "gate-", "beta-",
    "beta_sigmoid-", "z-", "attn_output-", "final_output-", "linear_attn_out-",
    "Qcur_full-", "Qcur_normed-", "Kcur_normed-", "Qcur-", "Kcur-", "Vcur-",
    "attn_pregate-", "gate_sigmoid-", "attn_gated-",
    "attn_residual-", "attn_post_norm-",
    "ffn_gate-", "ffn_up-", "ffn_swiglu-", "ffn_out-", "l_out-",
    "model.input_embed", "result_norm", "result_output",
    nullptr
};

// ------------------------------------------------------------------- state
static FILE *g_out = nullptr;
static int   g_tok = 0;                          // token index being decoded
static std::map<std::string,int> g_seen;         // name -> occurrences this token
static long  g_records = 0, g_values = 0;
static bool  g_listing = false;
static std::map<std::string,std::string> g_list; // name -> shape, for --list

// MATCHING IS NOT SUBSTRING, AND THAT IS DELIBERATE.  ggml derives node names
// by suffixing: `Qcur-3` spawns `Qcur-3 (view)` and `Qcur-3 (view) (permuted)`.
// A substring filter picks all three up, and the permuted one is NOT
// contiguous, so reading it row-major records a tensor that never existed.
// (It also overruns a buffer sized from ggml_nelements, because ggml_nbytes of
// a permuted view is larger.  That is how this was found: SIGABRT with
// `malloc(): invalid size`.)
//
// So: a filter ending in '-' matches `<prefix><digits>` and nothing else; any
// other filter must match the whole name.  --all still takes everything, and
// the contiguity gate below is what keeps that honest.
static bool name_wanted(const char *nm)
{
    if (O.all) return true;
    for (const auto &s : O.include) {
        if (s.back() == '-') {
            size_t L = s.size();
            if (strncmp(nm, s.c_str(), L) != 0) continue;
            const char *p = nm + L;
            if (!*p) continue;
            bool alldig = true;
            for (; *p; p++) if (*p < '0' || *p > '9') { alldig = false; break; }
            if (alldig) return true;
        } else if (s == nm) {
            return true;
        }
    }
    return false;
}

// A node name is NOT unique within one graph: `norm-3` appears three times in
// an attention layer (the block norm, the q norm, the k norm).  Silently
// keeping the last would make the stream depend on graph order in a way no
// reader could see, so the occurrence index is part of the recorded name.
static std::string unique_name(const char *nm)
{
    std::string base(nm);
    int k = g_seen[base]++;
    if (k == 0) return base;
    char b[32]; snprintf(b, sizeof b, "#%d", k);
    return base + b;
}

static std::string shape_of(const ggml_tensor *t)
{
    char b[96];
    snprintf(b, sizeof b, "%lld,%lld,%lld,%lld",
             (long long)t->ne[0], (long long)t->ne[1],
             (long long)t->ne[2], (long long)t->ne[3]);
    return b;
}

static bool eval_cb(ggml_tensor *t, bool ask, void *)
{
    if (ask) {
        if (g_listing) return true;
        return t->type == GGML_TYPE_F32 && name_wanted(t->name);
    }
    if (g_listing) {
        if (g_list.find(t->name) == g_list.end())
            g_list[t->name] = std::string(ggml_op_desc(t)) + " " + shape_of(t);
        return true;
    }
    if (t->type != GGML_TYPE_F32 || !name_wanted(t->name)) return true;
    if (!ggml_is_contiguous(t)) {
        static std::map<std::string,int> warned;
        if (warned[t->name]++ == 0)
            fprintf(stderr, "dump_llamacpp: SKIPPED non-contiguous node %s "
                            "(%s) -- a row-major read of it is not its value\n",
                    t->name, shape_of(t).c_str());
        return true;
    }

    const size_t n = (size_t)ggml_nelements(t);
    std::vector<float> v(n);
    if (ggml_nbytes(t) != n * sizeof(float)) {
        fprintf(stderr, "dump_llamacpp: %s nbytes %zu != n*4 %zu\n",
                t->name, (size_t)ggml_nbytes(t), n * sizeof(float));
        exit(1);
    }
    ggml_backend_tensor_get(t, v.data(), 0, ggml_nbytes(t));

    // layer index is the trailing "-<int>" of the node name when present
    int layer = -1;
    const char *dash = strrchr(t->name, '-');
    if (dash && dash[1] >= '0' && dash[1] <= '9') layer = atoi(dash + 1);

    std::string nm = unique_name(t->name);
    if (r9bs_write_f32(g_out, nm.c_str(), g_tok, layer, v.data(), (uint32_t)n)) {
        fprintf(stderr, "dump_llamacpp: write failed on %s\n", nm.c_str());
        exit(1);
    }
    g_records++; g_values += (long)n;
    return true;
}

// ------------------------------------------------------------------- main
static void usage(void)
{
    fprintf(stderr,
      "usage: dump_llamacpp -m MODEL.gguf -o OUT.r9bs [options]\n"
      "  -p TEXT          prompt (default: \"The capital of France is\")\n"
      "  --tokens a,b,c   explicit token ids, overrides -p\n"
      "  --include SUBSTR add a node-name filter (repeatable); default is the\n"
      "                   curated seam list\n"
      "  --all            dump every f32 node (large)\n"
      "  --list           print the node inventory and exit, write nothing\n"
      "  --selfcheck      decode twice, with and without the callback, and\n"
      "                   compare the logits.  Required before quoting numbers.\n"
      "  -c N -t N -ngl N\n");
}

static std::vector<float> decode_all(llama_context *ctx, const llama_vocab *vocab,
                                     const std::vector<llama_token> &toks,
                                     int n_vocab, bool cb_on)
{
    // one token per llama_decode, so g_tok is unambiguous and so the stream is
    // in sequence order rather than in batch order
    std::vector<float> last(n_vocab, 0.0f);
    llama_memory_clear(llama_get_memory(ctx), true);
    for (size_t i = 0; i < toks.size(); i++) {
        g_tok = (int)i;
        g_seen.clear();
        llama_token tk = toks[i];
        llama_batch b = llama_batch_get_one(&tk, 1);
        if (llama_decode(ctx, b) != 0) { fprintf(stderr, "decode failed\n"); exit(1); }
        const float *lg = llama_get_logits(ctx);
        if (lg) memcpy(last.data(), lg, sizeof(float) * (size_t)n_vocab);
    }
    (void)vocab; (void)cb_on;
    return last;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](void) -> std::string {
            if (i + 1 >= argc) { usage(); exit(1); }
            return argv[++i];
        };
        if      (a == "-m")          O.model = next();
        else if (a == "-o")          O.out = next();
        else if (a == "-p")          O.prompt = next();
        else if (a == "--include")   O.include.push_back(next());
        else if (a == "--all")       O.all = true;
        else if (a == "--list")      O.list = true;
        else if (a == "--selfcheck") O.selfcheck = true;
        else if (a == "-c")          O.n_ctx = atoi(next().c_str());
        else if (a == "-t")          O.threads = atoi(next().c_str());
        else if (a == "-ngl")        O.ngl = atoi(next().c_str());
        else if (a == "--tokens") {
            std::string s = next();
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                O.toks.push_back((llama_token)atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
        else { usage(); return 1; }
    }
    if (O.model.empty() || (O.out.empty() && !O.list)) { usage(); return 1; }
    if (O.include.empty())
        for (const char **s = DEFAULT_SEAMS; *s; s++) O.include.push_back(*s);

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = O.ngl;
    llama_model *model = llama_model_load_from_file(O.model.c_str(), mp);
    if (!model) { fprintf(stderr, "failed to load %s\n", O.model.c_str()); return 1; }
    const llama_vocab *vocab = llama_model_get_vocab(model);
    const int n_vocab = llama_vocab_n_tokens(vocab);

    std::vector<llama_token> toks = O.toks;
    if (toks.empty()) {
        toks.resize(O.prompt.size() + 8);
        int n = llama_tokenize(vocab, O.prompt.data(), (int)O.prompt.size(),
                               toks.data(), (int)toks.size(), true, true);
        if (n < 0) { toks.resize(-n);
            n = llama_tokenize(vocab, O.prompt.data(), (int)O.prompt.size(),
                               toks.data(), (int)toks.size(), true, true); }
        toks.resize(n);
    }
    fprintf(stderr, "tokens (%zu):", toks.size());
    for (auto t : toks) fprintf(stderr, " %d", t);
    fprintf(stderr, "\n");

    auto make_ctx = [&](bool cb) {
        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = O.n_ctx; cp.n_batch = O.n_ctx; cp.n_ubatch = O.n_ctx;
        cp.n_threads = O.threads; cp.n_threads_batch = O.threads;
        if (cb) { cp.cb_eval = eval_cb; cp.cb_eval_user_data = nullptr; }
        llama_context *c = llama_init_from_model(model, cp);
        if (!c) { fprintf(stderr, "failed to create context\n"); exit(1); }
        return c;
    };

    if (O.list) {
        g_listing = true;
        llama_context *ctx = make_ctx(true);
        decode_all(ctx, vocab, {toks[0]}, n_vocab, true);
        for (auto &kv : g_list) printf("%-40s %s\n", kv.first.c_str(), kv.second.c_str());
        printf("# %zu distinct node names\n", g_list.size());
        llama_free(ctx); llama_model_free(model); llama_backend_free();
        return 0;
    }

    std::vector<float> ref_logits;
    if (O.selfcheck) {
        llama_context *ctx0 = make_ctx(false);
        ref_logits = decode_all(ctx0, vocab, toks, n_vocab, false);
        llama_free(ctx0);
    }

    g_out = fopen(O.out.c_str(), "wb");
    if (!g_out) { perror(O.out.c_str()); return 1; }
    if (r9bs_write_header(g_out)) { perror("write"); return 1; }

    llama_context *ctx = make_ctx(true);
    std::vector<float> cb_logits = decode_all(ctx, vocab, toks, n_vocab, true);
    fclose(g_out);
    fprintf(stderr, "wrote %s: %ld records, %ld values\n",
            O.out.c_str(), g_records, g_values);

    if (O.selfcheck) {
        // The check is on the FULL logit vector, not on the argmax alone: an
        // argmax can survive a change that moved every logit, and this project
        // has already been caught once treating a surviving top-1 as evidence.
        double worst = 0.0; int worst_i = -1; long ndiff = 0;
        for (int i = 0; i < n_vocab; i++) {
            double d = fabs((double)ref_logits[i] - (double)cb_logits[i]);
            if (d != 0.0) ndiff++;
            if (d > worst) { worst = d; worst_i = i; }
        }
        int a0 = 0, a1 = 0;
        for (int i = 1; i < n_vocab; i++) {
            if (ref_logits[i] > ref_logits[a0]) a0 = i;
            if (cb_logits[i]  > cb_logits[a1])  a1 = i;
        }
        printf("SELFCHECK argmax_nocb=%d argmax_cb=%d ndiff=%ld/%d "
               "worst_abs=%.6g at=%d\n", a0, a1, ndiff, n_vocab, worst, worst_i);
        if (a0 != a1 || ndiff != 0)
            printf("SELFCHECK VERDICT: the callback PERTURBS the graph. "
                   "Every number from this stream carries that perturbation.\n");
        else
            printf("SELFCHECK VERDICT: bit-identical with and without the callback.\n");
    }

    llama_free(ctx); llama_model_free(model); llama_backend_free();
    return 0;
}
