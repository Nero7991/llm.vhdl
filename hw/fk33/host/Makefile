# Host-side FK33 bring-up test.  No dependencies beyond libc, deliberately:
# this has to build and run on a machine that may be mid-recovery, and
# anything that needs a package installed is a thing that can be missing on
# the one day it matters.
CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wshadow -Wconversion -std=c11 -D_FILE_OFFSET_BITS=64
LDFLAGS ?=

BIN = fk33_bringup

all: $(BIN)

$(BIN): fk33_bringup.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Compile-only, for the no-card checks: proves the source is valid C and that
# every printf format matches its argument, without needing a card, a driver,
# or even the XDMA headers.
check: fk33_bringup.c
	$(CC) $(CFLAGS) -fsyntax-only $<
	@echo "FK33_HOST_COMPILE OK"

clean:
	rm -f $(BIN)

.PHONY: all check clean
