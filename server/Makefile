# server/Makefile — build the OpenAI-compatible server.
#
#   make        -> ./llama_server           (dev box, native g++)
#   make board  -> ./llama_server_arm       (static aarch64 for the AXU3EG PetaLinux)
#   make clean
#
# The inference (../ref/run_fx.c) is compiled as C with -DLLAMA_LIB (no main())
# and linked into the C++ server via ../ref/llama_fx.h (extern "C").
#
# pl_backend.c is the FPGA path (--pl): it mmaps the llama_engine_axi core over
# /dev/mem and runs GENERATION there.  It compiles on the dev box too (pl_open
# just fails without /dev/mem), so the native build stays usable for testing.

CC        ?= gcc
CXX       ?= g++
CFLAGS    ?= -O3 -DLLAMA_LIB
CXXFLAGS  ?= -O2 -std=c++17 -Wall
INC       := -I../ref

ARM_CC    ?= aarch64-linux-gnu-gcc
ARM_CXX   ?= aarch64-linux-gnu-g++

DEPS := llama_server.cpp pl_backend.c pl_backend.h ../hw/tok512.h \
        ../hw/tok512_pkg.h ../ref/run_fx.c ../ref/llama_fx.h ../ref/fx.h

llama_server: $(DEPS)
	$(CC)  $(CFLAGS) -c ../ref/run_fx.c -o run_fx_lib.o
	$(CC)  -O2 -c pl_backend.c -o pl_backend.o
	$(CXX) $(CXXFLAGS) $(INC) llama_server.cpp run_fx_lib.o pl_backend.o -o llama_server -lm -lpthread

board: $(DEPS)
	$(ARM_CC)  $(CFLAGS) -c ../ref/run_fx.c -o run_fx_lib_arm.o
	$(ARM_CC)  -O2 -c pl_backend.c -o pl_backend_arm.o
	$(ARM_CXX) -O2 -std=c++17 -static $(INC) llama_server.cpp run_fx_lib_arm.o pl_backend_arm.o -o llama_server_arm -lm -lpthread

# ---------------------------------------------------------------------------
# Qwen3.5 tokenizer (qwen35_tok.c + the generated qwen35_unicode_data.c).
#
# DELIBERATELY NOT LINKED INTO llama_server YET.  Nothing in llama_server.cpp
# calls it: that server serves the fixed-point stories260K model with its own
# tok512 vocabulary, and the Qwen3.5 /v1/chat/completions seam is blocked on the
# descriptor format and on rendering the chat template (see the big comment at
# the top of qwen35_tok.h -- the generation prompt is NOT just
# "<|im_start|>assistant\n").  These rules exist so that seam is a one-line
# change to the link, and so the C is compiled by BOTH toolchains the server
# uses, including the static aarch64 cross-build, before anyone needs it.
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
	rm -f llama_server llama_server_arm run_fx_lib.o run_fx_lib_arm.o pl_backend.o pl_backend_arm.o \
	      qwen35_tok.o qwen35_unicode_data.o qwen35_tok_arm.o qwen35_unicode_data_arm.o

.PHONY: board clean tok tok-board
