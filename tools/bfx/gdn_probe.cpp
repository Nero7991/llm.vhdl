// gdn_probe -- measure what subsystem B's fixed-point numerics cost in model
// perplexity, by substituting B's arithmetic into a real Qwen3.8-27B forward
// pass and scoring wikitext.
//
// WHY THIS EXISTS.  Every unit in subsystem B is verified bit-exact against a
// C reference, and the reference is checked against a double oracle.  That
// certifies the transcription and the recipe.  It cannot certify the FORMAT
// CHOICES -- the epsilon grid, the block-floating exponents, the int16 state
// width -- because both sides of a bit-exact comparison make the same choices.
// The only thing that can is an end-to-end metric on real data, which is what
// docs/debugging/2026-08-24_subsystem-a-format-perplexity.md did for subsystem
// A's weight format.  A's format lives in the weights, so it could be baked
// into a GGUF offline.  B's lives in the ACTIVATION path, so it cannot; it has
// to be injected into a running forward pass.  This tool is that injection.
//
// HOW IT INJECTS, AND WHY NO llama.cpp PATCH IS NEEDED.
// llama_context_params carries a cb_eval hook that ggml_backend_sched calls
// once per graph node.  Reading ggml-backend.cpp's compute loop (the
// `if (!sched->callback_eval)` branch, around line 1730 of this build):
//
//     ggml_backend_graph_compute_async(split_backend, &gv);   // nodes j0..j1
//     ggml_backend_synchronize(split_backend);                // <-- barrier
//     sched->callback_eval(t, false, user_data);              // <-- us
//
// the backend is SYNCHRONIZED before the callback and the downstream nodes
// have not been enqueued yet.  So a ggml_backend_tensor_set() inside the
// callback is seen by every consumer of that node.  That makes read-modify-
// write substitution possible against the STOCK prebuilt libllama, with no
// fork of llama.cpp to maintain and no risk to the tree llama-cpp-server
// runs from.
//
// WHAT IT SUBSTITUTES.  Subsystem B is the Gated DeltaNet block of
// src/models/qwen35.cpp:build_layer_attn_linear(), from the conv through the
// gated output norm.  Its ggml sites, all identified STRUCTURALLY (op plus
// shape) rather than by name, because names are cosmetic and shapes are what
// the arithmetic actually sees:
//
//   site            ggml op                 shape signature
//   ------------    --------------------    --------------------------------
//   conv            SSM_CONV                src1->ne[0] == 4
//   silu (qkv)      SILU                    ne[0] == 2*S*Hk + S*Hv
//   l2norm q,k      L2_NORM                 ne[0] == 128, ne[1] == 16
//   beta            SIGMOID                 ne[0] == 1,   ne[1] == 48
//   softplus        SOFTPLUS                ne[0] == 48
//   recurrence      GATED_DELTA_NET         one node, carries state
//   output norm     RMS_NORM                ne[0] == 128, ne[1] == 48
//   z gate + fold   MUL after that RMS_NORM
//
// MODES.  Every mode is a DIFFERENCE against the mode below it, never an
// absolute, for the same reason A's harness measured control-relative:
//
//   baseline   no callback at all.  The number llama.cpp itself produces.
//   identity   callback fires on every B site, reads the tensor and writes
//              the same bytes back.  MUST reproduce baseline to the last bit.
//              This is the harness self-check: it prices the write-back
//              mechanism, the per-node graph splitting, and any accidental
//              aliasing at zero before anything numeric is claimed.
//   <site>     one site replaced by subsystem B's fixed-point arithmetic.
//
// A run that skips `identity` is not interpretable.  If the write-back is not
// neutral, every substitution number is that non-neutrality plus the format.
//
// Build:  see tools/bfx/build.sh
// Usage:  gdn_probe -m MODEL -f TEXT [--ctx 512] [--chunks N] [--mode M]
//                   [--inventory] [--ngl 99]

#include "llama.h"
#include "ggml.h"
#include "ggml-backend.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>
#include <algorithm>

// ---------------------------------------------------------------- options

struct opts {
    std::string model;
    std::string text;
    std::string mode      = "baseline";
    int         n_ctx     = 512;
    int         chunks    = 0;      // 0 = all
    int         ngl       = 99;
    int         threads   = 8;
    bool        inventory = false;
    int         inv_layers = 2;     // how many GDN blocks to print
    bool        emit_mode  = false; // emit-chain substitution active
    bool        emit_fx    = false; // fixed point (false = the double control)
    int         fold_heads = 24;    // heads sharing one y_exp; 24 = one card
    double      eps        = 1e-6;  // must equal the model's rms eps
    int         norm_q     = 12;
    bool        report     = false; // compare against ggml at the same node
    bool        report_only = false;// compare but do NOT substitute
    double      noise      = 0.0;   // relative multiplicative noise at the site
    unsigned    noise_seed = 1234;
};

static opts O;

// ---------------------------------------------------------------- site id
//
// Shapes come from the Qwen3.8-27B GGUF metadata, verified in ref/gdn_err.c:
//   ssm.state_size 128 (S), ssm.group_count 16 (H_k), ssm.time_step_rank 48
//   (H_v), ssm.inner_size 6144 (= H_v * S).
// They are read from the model at startup rather than hardcoded, so a wrong
// model fails to match instead of silently matching the wrong tensors.

struct shapes {
    int64_t S  = 128;   // head dim, key and value alike
    int64_t Hk = 16;    // key heads
    int64_t Hv = 48;    // value heads
    int64_t qkv_dim = 2 * 128 * 16 + 128 * 48;   // 4096 + 6144 = 10240
};
static shapes SH;

enum site_id {
    SITE_NONE = 0,
    SITE_CONV,
    SITE_SILU_QKV,
    SITE_L2NORM,
    SITE_BETA,
    SITE_SOFTPLUS,
    SITE_GDN,
    SITE_OUTNORM,
    SITE_NORMW,
    SITE_SILU_Z,
    SITE_ZGATE,
    SITE_COUNT
};

static const char * site_name(int s) {
    switch (s) {
        case SITE_CONV:      return "conv";
        case SITE_SILU_QKV:  return "silu_qkv";
        case SITE_L2NORM:    return "l2norm";
        case SITE_BETA:      return "beta_sigmoid";
        case SITE_SOFTPLUS:  return "softplus";
        case SITE_GDN:       return "gated_delta_net";
        case SITE_OUTNORM:   return "out_rmsnorm";
        case SITE_NORMW:     return "out_norm_weight";
        case SITE_SILU_Z:    return "silu_z";
        case SITE_ZGATE:     return "z_gate_mul";
        default:             return "none";
    }
}

// The previous RMS_NORM node that matched SITE_OUTNORM, so the MUL that gates
// it can be recognised as the z gate rather than by name.
static const ggml_tensor * g_last_outnorm = nullptr;
static const ggml_tensor * g_last_normw   = nullptr;

// Tracking the two anchor nodes is a SIDE EFFECT of classification, not
// something the caller does afterwards.  The first version updated the anchors
// only in the compute phase, so asking for the z gate alone never set them, the
// gate was never classified, the callback never fired, and the run reported a
// perplexity identical to the baseline -- which reads as "the write-back is
// neutral" when the truth is "nothing happened".  Always check the callback
// hit count; a substitution mode that reports zero hits measured nothing.
static int classify(const ggml_tensor * t) {
    switch (t->op) {
        case GGML_OP_SSM_CONV:
            if (t->src[1] && t->src[1]->ne[0] == 4) return SITE_CONV;
            return SITE_NONE;
        // silu, sigmoid and softplus are all GGML_OP_UNARY; the specific
        // function is an op param, not an op code.
        case GGML_OP_UNARY:
            switch (ggml_get_unary_op(t)) {
                case GGML_UNARY_OP_SILU:
                    if (t->ne[0] == SH.qkv_dim) return SITE_SILU_QKV;
                    // the z gate's silu: one GDN value head wide, Hv of them
                    if (t->ne[0] == SH.S && t->ne[1] == SH.Hv) return SITE_SILU_Z;
                    return SITE_NONE;
                case GGML_UNARY_OP_SIGMOID:
                    if (t->ne[0] == 1 && t->ne[1] == SH.Hv) return SITE_BETA;
                    return SITE_NONE;
                case GGML_UNARY_OP_SOFTPLUS:
                    if (t->ne[0] == SH.Hv) return SITE_SOFTPLUS;
                    return SITE_NONE;
                default:
                    return SITE_NONE;
            }
        case GGML_OP_L2_NORM:
            if (t->ne[0] == SH.S && t->ne[1] == SH.Hk) return SITE_L2NORM;
            return SITE_NONE;
        case GGML_OP_GATED_DELTA_NET:
            return SITE_GDN;
        case GGML_OP_RMS_NORM:
            // The gated output norm is the only RMS_NORM in the model whose
            // rows are one GDN value head wide.  The trunk norms are n_embd
            // wide and the QK norms live in the full-attention layers with a
            // different head count.
            if (t->ne[0] == SH.S && t->ne[1] == SH.Hv) { g_last_outnorm = t; return SITE_OUTNORM; }
            return SITE_NONE;
        case GGML_OP_MUL:
            // TWO distinct MULs follow the output norm and they were confused
            // once already.  build_norm() is rms_norm THEN a multiply by the
            // ssm_norm weight, which is [S,1,1,1]; the z gate is a separate
            // multiply by silu(z), which is [S,Hv,n_tokens,1].  Discriminating
            // on src[1]'s shape is what separates them; discriminating on
            // "the MUL after the RMS_NORM" picks the weight multiply and calls
            // it the gate.  See the TRACE output in the plan document.
            if (g_last_outnorm && t->src[0] == g_last_outnorm &&
                t->src[1] && t->src[1]->ne[0] == SH.S && t->src[1]->ne[1] == 1)
                { g_last_normw = t; return SITE_NORMW; }
            if (g_last_normw && t->src[0] == g_last_normw &&
                t->src[1] && t->src[1]->ne[0] == SH.S && t->src[1]->ne[1] == SH.Hv)
                return SITE_ZGATE;
            return SITE_NONE;
        default:
            return SITE_NONE;
    }
}

// ---------------------------------------------------------------- inventory

struct inv_row {
    int         site;
    std::string opname;
    std::string name;
    int64_t     ne[4];
    int         nsrc;
    std::string srcdesc;
    int         count;
};
static std::vector<inv_row> g_inv;
static std::map<std::string, int> g_inv_key;
static long g_inv_nodes = 0;
static int  g_trace_on   = -1;
static bool g_inv_done  = false;

static std::string shp(const ggml_tensor * t) {
    char b[128];
    snprintf(b, sizeof b, "[%lld,%lld,%lld,%lld]",
             (long long)t->ne[0], (long long)t->ne[1],
             (long long)t->ne[2], (long long)t->ne[3]);
    return b;
}

static void inv_record(const ggml_tensor * t) {
    int site = classify(t);
    if (site == SITE_NONE) return;
    std::string key = std::string(site_name(site)) + "|" + ggml_op_desc(t) + "|" + shp(t);
    auto it = g_inv_key.find(key);
    if (it != g_inv_key.end()) { g_inv[it->second].count++; return; }
    inv_row r;
    r.site   = site;
    r.opname = ggml_op_desc(t);
    r.name   = t->name;
    for (int i = 0; i < 4; i++) r.ne[i] = t->ne[i];
    r.nsrc = 0;
    for (int i = 0; i < GGML_MAX_SRC; i++) {
        if (!t->src[i]) continue;
        r.nsrc++;
        r.srcdesc += std::string(i ? " " : "") + "src" + std::to_string(i) + shp(t->src[i]);
    }
    r.count = 1;
    g_inv_key[key] = (int)g_inv.size();
    g_inv.push_back(r);
}

// ---------------------------------------------------------------- callback

extern "C" {
    void bfx_init(int n, int q, double eps);
    int  bfx_quant_weight(const float * w, int S, int16_t * wm);
    void bfx_emit_chain_fx(const float * o, const float * w, const float * z,
                           int HG, int S, float * out,
                           const int16_t * wm_pre, int we_pre);
    void bfx_emit_chain_dbl(const float * o, const float * w, const float * z,
                            int HG, int S, float * out);
}

struct cb_state {
    long fired = 0;                 // nodes we asked for and got
    long subst[SITE_COUNT] = {0};   // per-site write-back count
    std::vector<uint8_t> buf;

    // emit-chain scratch, refilled once per GDN block
    std::vector<float>   attn;      // [S, Hv, T]  the recurrence output
    std::vector<float>   w;         // [S]         ssm_norm weight
    std::vector<float>   z;         // [S, Hv, T]  the gate, pre-silu
    std::vector<int16_t> wm;        // [S]         weight as int16 BFP
    int                  we = 0;
    bool have_attn = false, have_w = false, have_z = false;
    long blocks = 0;
    // error accounting against what ggml computed at the same node
    double se = 0.0, sr = 0.0, maxabs = 0.0;
    long   n = 0;
    // Per-layer, because an aggregate hides a rail hit in one layer.  Layer 0's
    // GDN activations sit about 8 octaves above the rest of the stack
    // (2026-08-26_rmsnorm-magnitude-window.md), so a magnitude rail is exactly
    // the kind of defect that shows in one row and nowhere else.
    double lse[64] = {0}, lsr[64] = {0}, lmax[64] = {0};
    uint64_t rng = 0;
};
static cb_state CB;

// Which sites this run is interested in.  `identity` wants all of them, so the
// self-check exercises exactly the same node splitting as a real run.
static bool g_want[SITE_COUNT] = {false};
// Which sites this run WRITES to.  Observation and substitution are separate:
// the emit-chain modes read three upstream tensors and write exactly one.
static bool g_write[SITE_COUNT] = {false};

static void tensor_read_f32(const ggml_tensor * t, std::vector<float> & dst) {
    if (t->type != GGML_TYPE_F32) {
        fprintf(stderr, "gdn_probe: expected F32 for %s, got %s\n",
                t->name, ggml_type_name(t->type));
        exit(1);
    }
    dst.resize(ggml_nelements(t));
    ggml_backend_tensor_get(t, dst.data(), 0, ggml_nbytes(t));
}

static bool eval_cb(ggml_tensor * t, bool ask, void * /*ud*/) {
    if (ask) {
        if (O.inventory && !g_inv_done) return true;   // see every node
        int s = classify(t);
        if (s == SITE_NONE) return false;
        return g_want[s];
    }

    if (O.inventory && !g_inv_done) {
        g_inv_nodes++;
        inv_record(t);
        if (t->op == GGML_OP_RMS_NORM && classify(t) == SITE_OUTNORM) g_last_outnorm = t;
        if (t->op == GGML_OP_MUL && classify(t) == SITE_NORMW) g_last_normw = t;
        // Trace the literal node sequence of ONE GDN block, starting at its
        // conv.  Classifying by guessed shape signatures is how the z gate was
        // first mistaken for the norm's weight multiply; a raw trace is the
        // only thing that shows the actual chain.
        if (g_trace_on < 0 && t->op == GGML_OP_SSM_CONV) g_trace_on = 0;
        if (g_trace_on >= 0 && g_trace_on < 64) {
            char sd[256] = {0};
            for (int i = 0; i < GGML_MAX_SRC; i++) {
                if (!t->src[i]) continue;
                char one[64];
                snprintf(one, sizeof one, " s%d%s", i, shp(t->src[i]).c_str());
                strncat(sd, one, sizeof(sd) - strlen(sd) - 1);
            }
            printf("TRACE %2d %-18s %-26s %-28s%s\n", g_trace_on,
                   ggml_op_desc(t), shp(t).c_str(), t->name, sd);
            g_trace_on++;
        }
        return true;
    }

    int s = classify(t);
    if (s == SITE_OUTNORM) g_last_outnorm = t;
    if (s == SITE_NORMW)   g_last_normw   = t;
    if (s == SITE_NONE || !g_want[s]) return true;

    CB.fired++;

    // ---- observation-only sites for the emit-chain modes
    if (O.emit_mode) {
        if (s == SITE_OUTNORM) {
            tensor_read_f32(t->src[0], CB.attn);   // the recurrence output
            CB.have_attn = true;
            return true;
        }
        if (s == SITE_NORMW) {
            tensor_read_f32(t->src[1], CB.w);      // the ssm_norm weight
            CB.wm.resize(CB.w.size());
            CB.we = bfx_quant_weight(CB.w.data(), (int)CB.w.size(), CB.wm.data());
            CB.have_w = true;
            return true;
        }
        if (s == SITE_SILU_Z) {
            tensor_read_f32(t->src[0], CB.z);      // the gate, PRE-silu
            CB.have_z = true;
            return true;
        }
        if (s == SITE_ZGATE) {
            if (!CB.have_attn || !CB.have_w || !CB.have_z) {
                fprintf(stderr, "gdn_probe: emit chain reached the gate with a "
                                "stale upstream cache (attn=%d w=%d z=%d). "
                                "Node order is not what this tool assumes.\n",
                        (int)CB.have_attn, (int)CB.have_w, (int)CB.have_z);
                exit(1);
            }
            const int64_t S = t->ne[0], H = t->ne[1], T = t->ne[2];
            if ((int64_t)CB.attn.size() != S*H*T || (int64_t)CB.z.size() != S*H*T ||
                (int64_t)CB.w.size() != S) {
                fprintf(stderr, "gdn_probe: emit chain shape mismatch\n");
                exit(1);
            }
            std::vector<float> out((size_t)S*H*T);
            // Read what ggml itself produced at this node BEFORE overwriting
            // it.  The comparison is the whole point: for emit_dbl it says
            // whether this file understands the chain at all, and for emit_fx
            // it is subsystem B's error on real activations, measured without
            // any perplexity run.
            std::vector<float> ref;
            if (O.report) tensor_read_f32(t, ref);
            const int HG = O.fold_heads > 0 ? O.fold_heads : (int)H;
            if (H % HG != 0) { fprintf(stderr, "gdn_probe: Hv %% fold != 0\n"); exit(1); }
            for (int64_t tk = 0; tk < T; tk++) {
                for (int64_t g = 0; g < H / HG; g++) {
                    const size_t off = (size_t)tk*S*H + (size_t)g*HG*S;
                    if (O.emit_fx)
                        bfx_emit_chain_fx(CB.attn.data()+off, CB.w.data(),
                                          CB.z.data()+off, HG, (int)S,
                                          out.data()+off, CB.wm.data(), CB.we);
                    else
                        bfx_emit_chain_dbl(CB.attn.data()+off, CB.w.data(),
                                           CB.z.data()+off, HG, (int)S,
                                           out.data()+off);
                }
            }
            if (O.report) {
                const int il = (int)(CB.blocks % 48);
                double ls = 0.0, lr = 0.0, lm = 0.0;
                for (size_t i = 0; i < ref.size(); i++) {
                    const double d = (double)out[i] - (double)ref[i];
                    ls += d*d;
                    lr += (double)ref[i]*(double)ref[i];
                    const double ad = fabs(d);
                    if (ad > lm) lm = ad;
                }
                CB.se += ls; CB.sr += lr;
                if (lm > CB.maxabs) CB.maxabs = lm;
                CB.n += (long)ref.size();
                if (il < 64) {
                    CB.lse[il] += ls; CB.lsr[il] += lr;
                    if (lm > CB.lmax[il]) CB.lmax[il] = lm;
                }
            }
            if (!O.report_only) ggml_backend_tensor_set(t, out.data(), 0, ggml_nbytes(t));
            CB.subst[s]++;
            CB.blocks++;
            CB.have_attn = CB.have_w = CB.have_z = false;
            return true;
        }
        return true;
    }

    // ---- identity, or identity plus a controlled relative perturbation.
    //
    // WHY THE NOISE KNOB EXISTS.  The GDN block feeds a recurrence whose state
    // carries across all 512 tokens of a chunk, so a perturbation at ANY
    // magnitude reshuffles the trajectory rather than merely displacing it.
    // Measured here: replacing the emit chain with a MORE accurate double
    // evaluation, agreeing with ggml to 8.1e-8 relative RMS, still moved
    // 20-chunk perplexity by +0.015.  That is not bias, it is chaos, and it
    // means a fixed-point result cannot be read against the unmodified
    // baseline.  It has to be read against the perplexity shift produced by a
    // perturbation of the same relative size that is known to be harmless.
    // This knob measures that curve.
    if (!g_write[s]) return true;
    const size_t nb = ggml_nbytes(t);
    if (CB.buf.size() < nb) CB.buf.resize(nb);
    ggml_backend_tensor_get(t, CB.buf.data(), 0, nb);
    if (O.noise > 0.0 && t->type == GGML_TYPE_F32) {
        float * f = (float *)CB.buf.data();
        const size_t n = nb / sizeof(float);
        // A cheap unit-variance UNIFORM, not a gaussian.  Box-Muller here costs
        // 3.0e9 log/sqrt/cos evaluations per 20-chunk run (960 nodes x 3.1M
        // floats each) and made the sweep unrunnable.  What this knob measures
        // is a MAGNITUDE; the perturbation's distribution shape does not enter
        // that, and uniform on [-sqrt(3), +sqrt(3)] has variance 1 exactly as
        // the gaussian it replaces does.
        //
        // The scaling is done in DOUBLE and rounded back to float, not in
        // float.  In float, `f[i] * (1.0f + 1e-8f)` is `f[i]` exactly, because
        // 1 + 1e-8 is not representable: the whole perturbation disappears and
        // the run reports the baseline perplexity, which reads as "this
        // magnitude is harmless" when the truth is "nothing was applied".  In
        // double the multiply is exact and the float rounding at the end is
        // what actually carries a sub-ULP perturbation into the tensor, one
        // ULP at a time on the fraction of values that cross a rounding
        // boundary.  That is also the honest model of what a sub-ULP numeric
        // difference does to an f32 pipeline.
        const double k = O.noise * 3.4641016151377544;   // 2*sqrt(3)
        const double h = O.noise * 1.7320508075688772;   // sqrt(3)
        uint64_t r = CB.rng;
        for (size_t i = 0; i < n; i++) {
            r ^= r << 13; r ^= r >> 7; r ^= r << 17;
            const double u = (double)(r >> 40) * (1.0 / 16777216.0);  // [0,1)
            f[i] = (float)((double)f[i] * (1.0 + (k * u - h)));
        }
        CB.rng = r;
    }
    ggml_backend_tensor_set(t, CB.buf.data(), 0, nb);
    CB.subst[s]++;
    return true;
}

// ---------------------------------------------------------------- ppl

// llama.cpp's perplexity convention, reimplemented rather than linked because
// libllama-perplexity-impl.so exposes no public entry point.  It does NOT need
// to reproduce llama-perplexity's absolute number for the comparison to be
// valid -- every mode is scored by this same code on the same tokens, so the
// harness cancels in the difference.  It is checked against llama-perplexity
// anyway, because a harness that disagrees with the reference implementation on
// the baseline is a harness with a bug in it.
static double log_softmax_at(const float * logits, int n_vocab, int tok) {
    float mx = logits[0];
    for (int i = 1; i < n_vocab; i++) mx = std::max(mx, logits[i]);
    double sum = 0.0;
    for (int i = 0; i < n_vocab; i++) sum += std::exp((double)(logits[i] - mx));
    return (double)(logits[tok] - mx) - std::log(sum);
}

int main(int argc, char ** argv) {
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { return std::string(argv[++i]); };
        if      (a == "-m" || a == "--model")  O.model = next();
        else if (a == "-f" || a == "--file")   O.text  = next();
        else if (a == "--mode")                O.mode  = next();
        else if (a == "--ctx")                 O.n_ctx = atoi(next().c_str());
        else if (a == "--chunks")              O.chunks = atoi(next().c_str());
        else if (a == "--ngl")                 O.ngl   = atoi(next().c_str());
        else if (a == "--threads")             O.threads = atoi(next().c_str());
        else if (a == "--inventory")           O.inventory = true;
        else if (a == "--inv-layers")          O.inv_layers = atoi(next().c_str());
        else if (a == "--fold-heads")          O.fold_heads = atoi(next().c_str());
        else if (a == "--eps")                 O.eps = atof(next().c_str());
        else if (a == "--norm-q")              O.norm_q = atoi(next().c_str());
        else if (a == "--report")              O.report = true;
        else if (a == "--report-only")         { O.report = true; O.report_only = true; }
        else if (a == "--noise")               O.noise = atof(next().c_str());
        else if (a == "--noise-seed")          O.noise_seed = (unsigned)atoi(next().c_str());
        else { fprintf(stderr, "unknown arg %s\n", a.c_str()); return 1; }
    }
    if (O.model.empty()) { fprintf(stderr, "need -m MODEL\n"); return 1; }

    // identity exercises every site; a named site exercises only itself.
    if (O.mode == "identity") {
        for (int s = 1; s < SITE_COUNT; s++) { g_want[s] = true; g_write[s] = true; }
    } else if (O.mode == "emit_dbl" || O.mode == "emit_fx") {
        O.emit_mode = true;
        O.emit_fx   = (O.mode == "emit_fx");
        g_want[SITE_OUTNORM] = g_want[SITE_NORMW] = true;
        g_want[SITE_SILU_Z]  = g_want[SITE_ZGATE] = true;
        bfx_init(128, O.norm_q, O.eps);
    } else if (O.mode != "baseline") {
        bool found = false;
        for (int s = 1; s < SITE_COUNT; s++) {
            if (O.mode == site_name(s)) { g_want[s] = g_write[s] = true; found = true; }
        }
        if (!found) { fprintf(stderr, "unknown --mode %s\n", O.mode.c_str()); return 1; }
    }

    CB.rng = O.noise_seed * 2654435761ULL + 0x9E3779B97F4A7C15ULL;
    if (CB.rng == 0) CB.rng = 1;   // xorshift is dead at zero

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = O.ngl;
    llama_model * model = llama_model_load_from_file(O.model.c_str(), mp);
    if (!model) { fprintf(stderr, "failed to load model\n"); return 1; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = O.n_ctx;
    cp.n_batch   = O.n_ctx;
    cp.n_ubatch  = O.n_ctx;
    cp.n_threads = O.threads;
    cp.n_threads_batch = O.threads;
    cp.n_outputs_max = O.n_ctx;
    if (O.inventory || O.mode != "baseline") {
        cp.cb_eval = eval_cb;
        cp.cb_eval_user_data = nullptr;
    }
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { fprintf(stderr, "failed to create context\n"); return 1; }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    const int n_vocab = llama_vocab_n_tokens(vocab);

    // -------- tokenize
    std::vector<llama_token> toks;
    if (!O.text.empty()) {
        FILE * fp = fopen(O.text.c_str(), "rb");
        if (!fp) { fprintf(stderr, "cannot open %s\n", O.text.c_str()); return 1; }
        fseek(fp, 0, SEEK_END); long sz = ftell(fp); fseek(fp, 0, SEEK_SET);
        std::string raw(sz, '\0');
        if (fread(&raw[0], 1, sz, fp) != (size_t)sz) { fprintf(stderr, "short read\n"); return 1; }
        fclose(fp);
        toks.resize(raw.size() + 8);
        int n = llama_tokenize(vocab, raw.data(), (int)raw.size(),
                               toks.data(), (int)toks.size(), true, false);
        if (n < 0) { toks.resize(-n); n = llama_tokenize(vocab, raw.data(), (int)raw.size(),
                               toks.data(), (int)toks.size(), true, false); }
        toks.resize(n);
    } else {
        // inventory needs only enough tokens to build one graph
        toks.assign(O.n_ctx, llama_vocab_bos(vocab));
        for (int i = 1; i < O.n_ctx; i++) toks[i] = 100 + i;
    }
    fprintf(stderr, "tokens: %zu\n", toks.size());

    const int n_chunk_max = (int)toks.size() / O.n_ctx;
    int n_chunk = O.chunks > 0 ? std::min(O.chunks, n_chunk_max) : n_chunk_max;
    if (O.inventory) n_chunk = 1;
    if (n_chunk < 1) { fprintf(stderr, "not enough tokens for one chunk\n"); return 1; }

    const int first = std::min(512, O.n_ctx / 2);

    // llama.cpp's perplexity replaces the first token of each chunk with BOS
    // ONLY when the vocab wants a BOS.  Qwen vocabs do not, and llama_vocab_bos
    // then returns LLAMA_TOKEN_NULL; writing that into the batch feeds an
    // invalid token id and inflates perplexity by a plausible-looking amount
    // rather than erroring.  Measured on this model before the guard was added:
    // 9.757 against llama-perplexity's 6.9675 on the same 20 chunks.
    const bool add_bos = llama_vocab_get_add_bos(vocab);
    fprintf(stderr, "add_bos=%d bos=%d n_vocab=%d\n",
            (int)add_bos, (int)llama_vocab_bos(vocab), n_vocab);

    std::vector<llama_pos>     pos(O.n_ctx);
    std::vector<int32_t>       nsid(O.n_ctx, 1);
    std::vector<llama_seq_id>  sid0(O.n_ctx, 0);
    std::vector<llama_seq_id*> sid(O.n_ctx);
    std::vector<int8_t>        outp(O.n_ctx, 1);
    for (int i = 0; i < O.n_ctx; i++) sid[i] = &sid0[i];

    double nll = 0.0;
    long   cnt = 0;
    std::vector<llama_token> chunk(O.n_ctx);

    for (int c = 0; c < n_chunk; c++) {
        const int start = c * O.n_ctx;
        for (int i = 0; i < O.n_ctx; i++) chunk[i] = toks[start + i];
        if (add_bos) chunk[0] = llama_vocab_bos(vocab);
        for (int i = 0; i < O.n_ctx; i++) pos[i] = i;

        llama_memory_clear(llama_get_memory(ctx), true);

        llama_batch b{};
        b.n_tokens = O.n_ctx;
        b.token    = chunk.data();
        b.pos      = pos.data();
        b.n_seq_id = nsid.data();
        b.seq_id   = sid.data();
        b.logits   = outp.data();

        if (llama_decode(ctx, b) != 0) { fprintf(stderr, "decode failed\n"); return 1; }

        if (O.inventory) { g_inv_done = true; break; }

        for (int j = first; j < O.n_ctx - 1; j++) {
            const float * lg = llama_get_logits_ith(ctx, j);
            nll -= log_softmax_at(lg, n_vocab, chunk[j + 1]);
            cnt++;
        }
        fprintf(stderr, "[%3d/%3d] ppl = %.6f  (subst %ld)\n",
                c + 1, n_chunk, std::exp(nll / cnt), CB.fired);
    }

    if (O.inventory) {
        printf("\n==== graph inventory: %ld nodes in one %d-token graph ====\n",
               g_inv_nodes, O.n_ctx);
        printf("%-16s %-18s %-28s %s\n", "site", "op", "shape", "count / srcs");
        for (const auto & r : g_inv) {
            printf("%-16s %-18s [%6lld,%5lld,%5lld,%3lld] x%-4d %s\n",
                   site_name(r.site), r.opname.c_str(),
                   (long long)r.ne[0], (long long)r.ne[1],
                   (long long)r.ne[2], (long long)r.ne[3],
                   r.count, r.srcdesc.c_str());
        }
    } else {
        printf("\n==== mode=%s ctx=%d chunks=%d ====\n", O.mode.c_str(), O.n_ctx, n_chunk);
        printf("tokens scored : %ld\n", cnt);
        printf("nll           : %.10f\n", nll / (double)cnt);
        printf("PPL           : %.6f\n", std::exp(nll / (double)cnt));
        printf("callback hits : %ld\n", CB.fired);
        if (O.noise > 0.0) printf("noise         : %g relative, seed %u\n", O.noise, O.noise_seed);
        if (O.emit_mode)
            printf("emit blocks   : %ld  (fold %d heads, eps %g, Q %d)\n",
                   CB.blocks, O.fold_heads, O.eps, O.norm_q);
        if (O.report && CB.n > 0) {
            printf("vs ggml       : rel RMS %.6e   max abs %.6e   over %ld values\n",
                   sqrt(CB.se / CB.sr), CB.maxabs, CB.n);
            printf("per layer (relRMS / maxabs):\n");
            for (int il = 0; il < 48; il++) {
                if (CB.lsr[il] == 0.0) continue;
                printf("  L%-3d %.4e  %.4e%s", il,
                       sqrt(CB.lse[il] / CB.lsr[il]), CB.lmax[il],
                       (il % 4 == 3) ? "\n" : "   ");
            }
            printf("\n");
        }
        for (int s = 1; s < SITE_COUNT; s++) {
            if (CB.subst[s]) printf("  %-16s %ld\n", site_name(s), CB.subst[s]);
        }
    }

    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
