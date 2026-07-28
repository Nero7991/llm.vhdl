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

clean:
	rm -f llama_server llama_server_arm run_fx_lib.o run_fx_lib_arm.o pl_backend.o pl_backend_arm.o

.PHONY: board clean
