// Batch tokenizer oracle: llama.cpp's own vocab code, driven over many strings.
//
// This is NOT part of the FPGA design.  It exists so tools/verify_tokenizer.py
// can check our Python tokenizer against a genuinely independent
// implementation without paying a 0.5 s model open per string.  It is the same
// code path as build/bin/llama-tokenize (vocab_only load, llama_tokenize with
// add_special / parse_special), so anything it says is what llama.cpp says.
//
// Protocol, stdin -> stdout, both binary, little-endian:
//   in : u32 n_items, then n_items records of (u32 len, len bytes of UTF-8)
//   out: for each record, u32 n_tokens then n_tokens * i32 ids
// Then, if --detok is given, the same again in reverse:
//   in : u32 n_items, then n_items records of (u32 n_tokens, n_tokens * i32)
//   out: for each record, u32 len then len bytes
//
// Build (paths are the local llama.cpp checkout, see the header comment of
// tools/verify_tokenizer.py):
//   g++ -O2 -std=c++17 tools/tok_oracle_batch.cpp -o build_artifacts_tok/tok_oracle_batch \
//       -I$HOME/GitHub/llama.cpp.upstream/include \
//       -I$HOME/GitHub/llama.cpp.upstream/ggml/include \
//       -L$HOME/GitHub/llama.cpp.upstream/build/bin -lllama \
//       -Wl,-rpath,$HOME/GitHub/llama.cpp.upstream/build/bin
//
// Usage: tok_oracle_batch MODEL.gguf [--no-parse-special] [--add-special] [--detok]

#include "llama.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

static bool read_exact(void * dst, size_t n) {
    return n == 0 || fread(dst, 1, n, stdin) == n;
}

static uint32_t read_u32() {
    uint32_t v = 0;
    if (!read_exact(&v, 4)) { fprintf(stderr, "oracle: short read\n"); exit(2); }
    return v;
}

static void write_u32(uint32_t v) { fwrite(&v, 4, 1, stdout); }

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s MODEL.gguf [--no-parse-special] [--add-special] [--detok]\n", argv[0]);
        return 1;
    }
    const char * model_path = argv[1];
    bool parse_special = true;
    bool add_special   = false;
    bool do_detok      = false;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--no-parse-special")) parse_special = false;
        else if (!strcmp(argv[i], "--add-special")) add_special = true;
        else if (!strcmp(argv[i], "--detok"))       do_detok = true;
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 1; }
    }

    llama_log_set([](enum ggml_log_level, const char *, void *) {}, nullptr);
    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.vocab_only = true;          // never touches a tensor, never touches a GPU
    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) { fprintf(stderr, "oracle: failed to load %s\n", model_path); return 3; }
    const llama_vocab * vocab = llama_model_get_vocab(model);

    fprintf(stderr, "oracle: vocab n=%d add_bos=%d bos=%d eos=%d parse_special=%d add_special=%d\n",
            llama_vocab_n_tokens(vocab), (int) llama_vocab_get_add_bos(vocab),
            llama_vocab_bos(vocab), llama_vocab_eos(vocab),
            (int) parse_special, (int) add_special);

    // ---- encode pass
    {
        const uint32_t n = read_u32();
        std::vector<char> buf;
        std::vector<llama_token> toks;
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t len = read_u32();
            buf.resize(len);
            if (!read_exact(buf.data(), len)) { fprintf(stderr, "oracle: short text\n"); return 2; }
            toks.resize(len * 4 + 64);
            int32_t k = llama_tokenize(vocab, buf.data(), (int32_t) len,
                                       toks.data(), (int32_t) toks.size(),
                                       add_special, parse_special);
            if (k < 0) {
                toks.resize(-k);
                k = llama_tokenize(vocab, buf.data(), (int32_t) len,
                                   toks.data(), (int32_t) toks.size(),
                                   add_special, parse_special);
                if (k < 0) { fprintf(stderr, "oracle: tokenize failed on item %u\n", i); return 4; }
            }
            write_u32((uint32_t) k);
            fwrite(toks.data(), 4, (size_t) k, stdout);
        }
        fflush(stdout);
    }

    // ---- optional detokenize pass
    if (do_detok) {
        const uint32_t n = read_u32();
        std::vector<llama_token> toks;
        std::vector<char> out;
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t k = read_u32();
            toks.resize(k);
            if (!read_exact(toks.data(), (size_t) k * 4)) { fprintf(stderr, "oracle: short toks\n"); return 2; }
            out.resize(k * 64 + 64);
            int32_t m = llama_detokenize(vocab, toks.data(), (int32_t) k,
                                         out.data(), (int32_t) out.size(),
                                         /*remove_special*/ false, /*unparse_special*/ true);
            if (m < 0) {
                out.resize(-m);
                m = llama_detokenize(vocab, toks.data(), (int32_t) k,
                                     out.data(), (int32_t) out.size(), false, true);
                if (m < 0) { fprintf(stderr, "oracle: detokenize failed on item %u\n", i); return 5; }
            }
            write_u32((uint32_t) m);
            fwrite(out.data(), 1, (size_t) m, stdout);
        }
        fflush(stdout);
    }

    llama_model_free(model);
    llama_backend_free();
    return 0;
}
