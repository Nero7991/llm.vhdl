# server/Makefile — build the OpenAI-compatible server.
#
#   make        -> ./llama_server           (dev box, native g++)
#   make board  -> ./llama_server_arm       (static aarch64 for the AXU3EG PetaLinux)
#   make clean
#
# The inference (../ref/run_fx.c) is compiled as C with -DLLAMA_LIB (no main())
# and linked into the C++ server via ../ref/llama_fx.h (extern "C").
#
# TWO BACKENDS, ONE BINARY, NO RUNTIME CHOICE BETWEEN THEM.
#
#   pl_backend_axu3eg.c  v1, the AXU3EG generation-level offload over /dev/mem
#                        (--pl).  Unchanged; its symbols are now plv1_*.
#   pl_backend.c         v2, the FK33 host seam: prefill + decode returning
#   fk33_transport.c     logits, over a transport that is either the real
#   fk33_sim.c           pread/pwrite chardev code pointed at ordinary files,
#                        or a modelled card.  NOTHING HERE OPENS /dev/xdma*.
#   qwen35_chat.c        the Qwen3.5 chat template, checked byte-for-byte
#                        against Jinja2 by server/verify_chat_template.py.
#
# The Qwen3.5 tokenizer is now LINKED (it was deliberately not, before this
# commit; see the note further down that this replaces).

CC        ?= gcc
CXX       ?= g++
CFLAGS    ?= -O3 -DLLAMA_LIB
CXXFLAGS  ?= -O2 -std=c++17 -Wall
INC       := -I../ref

ARM_CC    ?= aarch64-linux-gnu-gcc
ARM_CXX   ?= aarch64-linux-gnu-g++

CSRC := pl_backend_axu3eg.c pl_backend.c pl_pipeline.c fk33_transport.c fk33_sim.c \
        fk33_imglock.c \
        fk33_manifest.c embed_mv4i.c embed_bf16.c \
        qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c
COBJ := $(CSRC:.c=.o)
CARM := $(CSRC:.c=_arm.o)

DEPS := llama_server.cpp $(CSRC) pl_backend.h pl_backend_axu3eg.h \
        fk33_transport.h fk33_seam.h fk33_manifest.h fk33_imglock.h embed_mv4i.h \
        embed_bf16.h ../ref/embed_bf16.h ../ref/embed_bf16.c \
        qwen35_chat.h qwen35_tok.h \
        qwen35_unicode_data.h ../hw/tok512.h ../hw/tok512_pkg.h \
        ../ref/run_fx.c ../ref/llama_fx.h ../ref/fx.h

CBACK ?= -O2 -std=c99 -Wall -Wextra

llama_server: $(DEPS)
	$(CC)  $(CFLAGS) -c ../ref/run_fx.c -o run_fx_lib.o
	@for f in $(CSRC); do echo "$(CC) $(CBACK) -c $$f"; \
	  $(CC) $(CBACK) -c $$f -o $${f%.c}.o || exit 1; done
	$(CXX) $(CXXFLAGS) $(INC) llama_server.cpp run_fx_lib.o $(COBJ) -o llama_server -lm -lpthread

board: $(DEPS)
	$(ARM_CC)  $(CFLAGS) -c ../ref/run_fx.c -o run_fx_lib_arm.o
	@for f in $(CSRC); do echo "$(ARM_CC) $(CBACK) -c $$f"; \
	  $(ARM_CC) $(CBACK) -c $$f -o $${f%.c}_arm.o || exit 1; done
	$(ARM_CXX) -O2 -std=c++17 -static $(INC) llama_server.cpp run_fx_lib_arm.o $(CARM) -o llama_server_arm -lm -lpthread

# ---------------------------------------------------------------------------
# The seam self-test.  No card, no driver, no FPGA; see tests/seam_selftest.c
# for what it can and cannot prove.
seam_selftest: tests/seam_selftest.c pl_backend.c pl_pipeline.c fk33_transport.c fk33_sim.c \
               fk33_manifest.c fk33_imglock.c pl_backend.h pl_pipeline.h fk33_transport.h fk33_seam.h \
               fk33_manifest.h fk33_imglock.h
	$(CC) $(CBACK) -o $@ tests/seam_selftest.c pl_backend.c pl_pipeline.c fk33_transport.c \
	      fk33_sim.c fk33_manifest.c fk33_imglock.c

# ---------------------------------------------------------------------------
# The host embedding gather (server/embed_mv4i.c), and its checks.
#
#   embed_dump        the C gather, as parseable text.  Built WITH the mutation
#                     hooks, because tools/check_embed_c.py drives them; a
#                     shipped build has none and pl_embed_mv4i_set_mutant fails.
#   embed_ref_oracle  ref/matvec_int4.c's own accessors, reproducing
#                     ref/run9b.c's embed() + reg_put().  Nothing in ref/ is
#                     edited; it is included.
#   embed_e2e         the provider driving the real seam against the SIMULATED
#                     card, plus the base-address refusal on a real manifest.
#
# `make embed-check` needs the packed tensor and the BF16 GGUF and SKIPS
# cleanly when either is absent, rather than failing.
EMBED_MV4I ?= /mnt/storage/llama-models/qwen35-9b-mv4i/token_embd.weight.mv4i
EMBED_MANIFEST ?= /mnt/storage/llama-models/qwen35-9b-mv4i-noembd/manifest.json
EMBED_N ?= 64
EMBED_GGUF ?= /mnt/storage/llama-models/qwen35-9b/Qwen3.5-9B-BF16.gguf
# The two oracles that are not this repository's: llama.cpp's own embedding rows
# inside a rung-1 anchor stream, and ref/run9b.c's own packed R_X.embed seam.
# Both are large artefacts that are not committed; the check runs without them
# and says so, which is why they are a variable and not a hard dependency.
EMBED_BF16_ORACLES ?= $(if $(wildcard /mnt/storage/ref9b/anchor_f32.r9bs),--anchor /mnt/storage/ref9b/anchor_f32.r9bs,) $(if $(wildcard /mnt/storage/ref9b-bf16/ref_bfp_gguf.r9bs),--ref-stream /mnt/storage/ref9b-bf16/ref_bfp_gguf.r9bs,)

embed_dump: tests/embed_dump.c embed_mv4i.c embed_mv4i.h
	$(CC) $(CBACK) -DEMBED_MV4I_MUTANTS -o $@ tests/embed_dump.c embed_mv4i.c

embed_bf16_dump: tests/embed_bf16_dump.c embed_bf16.c embed_bf16.h \
                 ../ref/embed_bf16.c ../ref/embed_bf16.h
	$(CC) $(CBACK) -DEMBED_BF16_MUTANTS -o $@ tests/embed_bf16_dump.c embed_bf16.c -lm

embed_ref_oracle: tests/embed_ref_oracle.c ../ref/matvec_int4.c ../ref/mv4i_arith.h
	$(CC) $(CBACK) -o $@ tests/embed_ref_oracle.c -lm

embed_e2e: tests/embed_e2e.c embed_mv4i.c embed_bf16.c pl_backend.c \
           fk33_transport.c fk33_sim.c fk33_manifest.c fk33_imglock.c
	$(CC) $(CBACK) -o $@ tests/embed_e2e.c embed_mv4i.c embed_bf16.c pl_backend.c \
	      fk33_transport.c fk33_sim.c fk33_manifest.c fk33_imglock.c -lm

embed-check: embed_dump embed_ref_oracle embed_e2e embed_bf16_dump
	@if [ ! -f "$(EMBED_MV4I)" ]; then \
	   echo "SKIP embed-check: $(EMBED_MV4I) is not present"; exit 0; fi
	python3 ../tools/check_embed_c.py --mv4i $(EMBED_MV4I) \
	    --dump ./embed_dump --ref-oracle ./embed_ref_oracle --n $(EMBED_N)
	python3 ../tools/check_embed_c.py --mv4i $(EMBED_MV4I) \
	    --dump ./embed_dump --ref-oracle ./embed_ref_oracle --n $(EMBED_N) --mutate
	@if [ ! -f "$(EMBED_GGUF)" ]; then \
	   echo "SKIP the BF16 half: $(EMBED_GGUF) is not present"; else \
	   python3 ../tools/check_embed_bf16.py --gguf $(EMBED_GGUF) \
	       --dump ./embed_bf16_dump --n $(EMBED_N) $(EMBED_BF16_ORACLES); \
	   python3 ../tools/check_embed_bf16.py --gguf $(EMBED_GGUF) \
	       --dump ./embed_bf16_dump --n $(EMBED_N) $(EMBED_BF16_ORACLES) --mutate; fi
	@if [ ! -f "$(EMBED_MANIFEST)" ]; then \
	   echo "SKIP embed_e2e: $(EMBED_MANIFEST) is not present"; exit 0; fi
	./embed_e2e --mv4i $(EMBED_MV4I) --manifest $(EMBED_MANIFEST) --gguf $(EMBED_GGUF)

# ---------------------------------------------------------------------------
# The goal harness: a committed prompt through the real seam, its ids compared
# against a committed reference.  Simulated transport only; see the header of
# tests/run_prompt.c for what that does and does not prove.
# The chat template and tokenizer as a shared library, for
# server/llmvhdl_server.py (ctypes).  The SAME three C files run_prompt and
# llama_server link, so the web server renders and tokenizes exactly as the
# verified path does rather than through a second implementation.
libqwen35chat.so: qwen35_tok.c qwen35_chat.c qwen35_unicode_data.c qwen35_tok.h qwen35_chat.h
	$(CC) $(CBACK) -fPIC -shared -I. -o $@ qwen35_tok.c qwen35_chat.c qwen35_unicode_data.c -lm

run_prompt: tests/run_prompt.c pl_backend.c pl_pipeline.c fk33_transport.c fk33_sim.c \
            fk33_manifest.c fk33_imglock.c embed_mv4i.c embed_bf16.c qwen35_tok.c \
            qwen35_chat.c qwen35_unicode_data.c
	$(CC) $(CBACK) -I. -o $@ tests/run_prompt.c pl_backend.c pl_pipeline.c fk33_transport.c \
	      fk33_sim.c fk33_manifest.c fk33_imglock.c embed_mv4i.c embed_bf16.c qwen35_tok.c \
	      qwen35_chat.c qwen35_unicode_data.c -lm

# The chat-template batch driver, for server/verify_chat_template.py.  That
# script builds it itself with --build; this rule exists so `make check` can
# compile it under BOTH toolchains without the Python.
chat_batch: tests/chat_batch.c qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c
	$(CC) $(CBACK) -I. -o $@ tests/chat_batch.c qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c

# Compile-only gate: every C file under both toolchains, plus the C++.  This is
# what a no-card CI runs.
check:
	$(CC) $(CBACK) -fsyntax-only $(CSRC) tests/seam_selftest.c tests/chat_batch.c \
	      tests/embed_dump.c tests/embed_e2e.c tests/embed_bf16_dump.c \
	      tests/run_prompt.c tests/imglock_selftest.c
	$(ARM_CC) $(CBACK) -fsyntax-only fk33_manifest.c fk33_imglock.c embed_mv4i.c embed_bf16.c 2>/dev/null \
	  || echo "  (no aarch64 toolchain; the SBC-side syntax check was skipped)" 
	$(CXX) $(CXXFLAGS) $(INC) -fsyntax-only llama_server.cpp
	@echo "SERVER_COMPILE OK"

test: seam_selftest
	./seam_selftest

# THE IMAGE INTERLOCK, both halves in one command so it can be a single gate
# row (sim/regress.sh runs a row's command unquoted and not through a shell,
# so `a && b` would hand `&&` to argv and only the first half would run).
#   imglock_selftest   pl_open refusing today's incident against the simulated
#                      card, with the attribution control
#   fk33_imgfp.py      the record's own teeth, and the two-language
#                      cross-check in BOTH directions
# Neither needs hardware, a model file, or /mnt/storage.
imglock-check: imglock_selftest
	./imglock_selftest
	python3 ../hw/fk33/host/fk33_imgfp.py selfcheck
	python3 ../hw/fk33/host/fk33_load_weights.py selfcheck

# The end-to-end check of the server's OWN request path.  Needs the .qtk
# artefact (9 MB, not committed) and builds its own reference driver; it SKIPS
# cleanly when either is absent rather than failing.
test-e2e: llama_server
	python3 tests/server_e2e.py

# The DEFAULT path's OpenAI surface: usage accounting and prompt echo.  This is
# the path `./server/llama_server` serves and the only one that does real
# fixed-point inference, and nothing checked it until 2026-09-04, when two
# compatibility defects were found in it (prompt_tokens hardcoded 0, and an
# unconditional prompt echo that was also charged against max_tokens).  Runs
# from the REPO ROOT because the model files are ref/*.bin relative paths.
test-stories: llama_server
	cd .. && python3 server/tests/server_stories_e2e.py

# ---------------------------------------------------------------------------
# Qwen3.5 tokenizer (qwen35_tok.c + the generated qwen35_unicode_data.c).
#
# NOW LINKED, 2026-08-29.  The note that used to stand here said this was
# "deliberately not linked yet", blocked on the descriptor format AND on
# rendering the chat template.  The first is settled
# (docs/2026-08-28_matvec-descriptor-format.md) and the second is now
# server/qwen35_chat.c, checked byte-for-byte against Jinja2 evaluating the
# model's own template.  Both objects are in $(CSRC) above.
#
# The standalone rules below are kept because they are what compiles the C
# under BOTH toolchains without linking a server.
#
#   make tok        -> qwen35_tok.o qwen35_unicode_data.o          (native)
#   make tok-board  -> qwen35_tok_arm.o qwen35_unicode_data_arm.o  (aarch64)
#
# It adds libc only; nothing about "zero-dependency" changes.  MEASURED cost of
# adding both objects to the native llama_server link: 151,144 -> 193,848 bytes,
# +42,704 (+28.3%), of which 25,352 is the Unicode category table.
TOKFLAGS ?= -O2 -std=c99 -Wall -Wextra
TOK_HDR  := qwen35_tok.h qwen35_unicode_data.h

tok: qwen35_tok.o qwen35_unicode_data.o
qwen35_tok.o: qwen35_tok.c $(TOK_HDR)
	$(CC) $(TOKFLAGS) -c qwen35_tok.c -o $@
qwen35_unicode_data.o: qwen35_unicode_data.c qwen35_unicode_data.h
	$(CC) $(TOKFLAGS) -c qwen35_unicode_data.c -o $@

tok-board: qwen35_tok_arm.o qwen35_unicode_data_arm.o
qwen35_tok_arm.o: qwen35_tok.c $(TOK_HDR)
	$(ARM_CC) $(TOKFLAGS) -c qwen35_tok.c -o $@
qwen35_unicode_data_arm.o: qwen35_unicode_data.c qwen35_unicode_data.h
	$(ARM_CC) $(TOKFLAGS) -c qwen35_unicode_data.c -o $@

clean:
	rm -f llama_server llama_server_arm seam_selftest imglock_selftest chat_batch \
	      embed_dump embed_ref_oracle embed_e2e embed_bf16_dump run_prompt libqwen35chat.so \
	      run_fx_lib.o run_fx_lib_arm.o $(COBJ) $(CARM) \
	      qwen35_tok_arm.o qwen35_unicode_data_arm.o pl_backend_arm.o

.PHONY: board clean tok tok-board check test test-e2e test-stories embed-check \
        imglock-check

# THE IMAGE INTERLOCK's teeth.  Today's incident reconstructed against the
# simulated card: a flat manifest driven at a card holding the striped image's
# record must be REFUSED, and the SAME pair with no record -- the state of the
# world before 2026-09-20 -- must be ACCEPTED, which is the attribution
# control.  No hardware, no model file, no /mnt/storage.
imglock_selftest: tests/imglock_selftest.c pl_backend.c fk33_transport.c \
                  fk33_sim.c fk33_manifest.c fk33_imglock.c pl_backend.h \
                  fk33_transport.h fk33_seam.h fk33_manifest.h fk33_imglock.h
	$(CC) $(CBACK) -o $@ tests/imglock_selftest.c pl_backend.c \
	      fk33_transport.c fk33_sim.c fk33_manifest.c fk33_imglock.c
