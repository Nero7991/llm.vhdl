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

CSRC := pl_backend_axu3eg.c pl_backend.c fk33_transport.c fk33_sim.c \
        qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c
COBJ := $(CSRC:.c=.o)
CARM := $(CSRC:.c=_arm.o)

DEPS := llama_server.cpp $(CSRC) pl_backend.h pl_backend_axu3eg.h \
        fk33_transport.h fk33_seam.h qwen35_chat.h qwen35_tok.h \
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
seam_selftest: tests/seam_selftest.c pl_backend.c fk33_transport.c fk33_sim.c \
               pl_backend.h fk33_transport.h fk33_seam.h
	$(CC) $(CBACK) -o $@ tests/seam_selftest.c pl_backend.c fk33_transport.c fk33_sim.c

# The chat-template batch driver, for server/verify_chat_template.py.  That
# script builds it itself with --build; this rule exists so `make check` can
# compile it under BOTH toolchains without the Python.
chat_batch: tests/chat_batch.c qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c
	$(CC) $(CBACK) -I. -o $@ tests/chat_batch.c qwen35_chat.c qwen35_tok.c qwen35_unicode_data.c

# Compile-only gate: every C file under both toolchains, plus the C++.  This is
# what a no-card CI runs.
check:
	$(CC) $(CBACK) -fsyntax-only $(CSRC) tests/seam_selftest.c tests/chat_batch.c
	$(CXX) $(CXXFLAGS) $(INC) -fsyntax-only llama_server.cpp
	@echo "SERVER_COMPILE OK"

test: seam_selftest
	./seam_selftest

# The end-to-end check of the server's OWN request path.  Needs the .qtk
# artefact (9 MB, not committed) and builds its own reference driver; it SKIPS
# cleanly when either is absent rather than failing.
test-e2e: llama_server
	python3 tests/server_e2e.py

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
	rm -f llama_server llama_server_arm seam_selftest chat_batch \
	      run_fx_lib.o run_fx_lib_arm.o $(COBJ) $(CARM) \
	      qwen35_tok_arm.o qwen35_unicode_data_arm.o pl_backend_arm.o

.PHONY: board clean tok tok-board check test test-e2e
