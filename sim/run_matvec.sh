#!/bin/sh
# Full subsystem A verification chain, from one source of truth.
#
#   tools/gen_arith.py  -->  ref/mv4i_arith.h  +  rtl/mv4i_arith_pkg.vhd
#                            + sim/arith_vectors.txt   (golden, both sides)
#   ref/matvec_int4     -->  sim/matvec_trace.txt      (every 7.4 intermediate)
#   sim/tb_arith        -->  VHDL primitives vs golden vectors
#   sim/tb_matvec_core  -->  RTL vs the C reference, STAGE BY STAGE
set -e
cd "$(dirname "$0")/.."
echo "== 1. regenerate shared arithmetic (C + VHDL + vectors) =="
python3 tools/gen_arith.py --check || { python3 tools/gen_arith.py; }

echo "== 2. C reference self-test =="
cc -O2 -Wall -Wextra -o sim/work_mv/mv4i ref/matvec_int4.c
( cd ref && ../sim/work_mv/mv4i )

echo "== 3. emit the stage trace =="
( cd ref && ../sim/work_mv/mv4i --trace ../sim/matvec_trace.txt )

echo "== 4. VHDL primitives vs golden vectors =="
mkdir -p sim/work_arith
( cd sim/work_arith \
  && ghdl -a --std=08 --workdir=. ../../rtl/mv4i_arith_pkg.vhd ../tb_arith.vhd \
  && ghdl -e --std=08 --workdir=. tb_arith \
  && ghdl -r --std=08 --workdir=. tb_arith )

echo "== 5. RTL vs C reference, stage by stage =="
mkdir -p sim/work_mv
( cd sim/work_mv \
  && ghdl -a --std=08 --workdir=. ../../rtl/mv4i_arith_pkg.vhd \
        ../../rtl/matvec_core.vhd ../tb_matvec_core.vhd \
  && ghdl -e --std=08 --workdir=. tb_matvec_core \
  && ghdl -r --std=08 --workdir=. tb_matvec_core --stop-time=20ms )
echo "== all green =="
