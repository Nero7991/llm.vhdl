# hw/Makefile -- board-side driver for subsystem A.
#
# NDEBUG is deliberately NOT set: ref/matvec_int4.c refuses to build without
# assertions (#error), because its bounds checks are the contract of 7.4 -- the
# s28 partial, the s48 accumulator, the uint15 scale.  On the board they are the
# only thing that catches a descriptor the PL would silently mis-execute.

CC      ?= gcc
CROSS   ?= aarch64-linux-gnu-
CFLAGS  ?= -O2 -Wall -Wextra -std=c11

all: mv_driver

mv_driver: mv_driver.c ../ref/matvec_int4.c ../ref/mv4i_arith.h
	$(CC) $(CFLAGS) -o $@ mv_driver.c

# static, so it needs nothing from the board's rootfs
board: mv_driver.c ../ref/matvec_int4.c ../ref/mv4i_arith.h
	$(CROSS)gcc $(CFLAGS) -static -o mv_driver_aarch64 mv_driver.c

clean:
	rm -f mv_driver mv_driver_aarch64
.PHONY: all board clean
