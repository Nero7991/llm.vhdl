#!/bin/sh
# Full subsystem A verification chain, from one source of truth.
#
#   tools/gen_arith.py  -->  ref/mv4i_arith.h  +  rtl/mv4i_arith_pkg.vhd
#                            + sim/arith_vectors.txt   (golden, both sides)
#   ref/matvec_int4     -->  sim/tr.txt                (every 7.4 intermediate)
#   sim/tb_arith        -->  VHDL primitives vs golden vectors
#   sim/tb_matvec_core  -->  RTL vs the C reference, STAGE BY STAGE
#
# The core is swept over shapes rather than run once, because the original
# single case (M=8 K=96 ROWS_IF=4) happened to make M a multiple of ROWS_IF and
# K a multiple of BLOCK, so it exercised neither pad rows nor the column mask.
set -e
cd "$(dirname "$0")/.."
mkdir -p sim/work_mv sim/work_arith

echo "== 1. regenerate shared arithmetic (C + VHDL + vectors) =="
python3 tools/gen_arith.py --check || { python3 tools/gen_arith.py; }

echo "== 2. C reference self-test =="
cc -O2 -Wall -Wextra -o sim/work_mv/mv4i ref/matvec_int4.c
( cd ref && ../sim/work_mv/mv4i )

echo "== 3. VHDL primitives vs golden vectors =="
( cd sim/work_arith \
  && ghdl -a --std=08 --workdir=. ../../rtl/mv4i_arith_pkg.vhd ../tb_arith.vhd \
  && ghdl -e --std=08 --workdir=. tb_arith \
  && ghdl -r --std=08 --workdir=. tb_arith )

echo "== 4. RTL vs C reference, stage by stage, over shapes =="
( cd sim/work_mv \
  && ghdl -a --std=08 --workdir=. ../../rtl/util_pkg.vhd \
        ../../rtl/mv4i_arith_pkg.vhd ../../rtl/matvec_core.vhd \
        ../tb_matvec_core.vhd \
  && ghdl -e --std=08 --workdir=. tb_matvec_core )

#     M    K   ROWS_IF  STALL   what it covers beyond the baseline
#     ----------------------------------------------------------------------
#      8   96      4      0     baseline: both dims exact multiples
#      7  100      4      0     pad rows AND a partial last block
#      9   97      4      0     one valid column in the last block
#      8   96      1      0     degenerate ROWS_IF
#      8   96      2      0     ROWS_IF below the 4 the packer default uses
#     13  129      8      0     ROWS_IF above it, both dims ragged
#      1   33      4      0     single row, mostly pad
#      7  100      4      3     the ragged case under backpressure
#      9   97      4      2     heavier backpressure
#     13  129      8      5     wide and ragged under backpressure
#     16   32      4      7     exactly one block per row
CASES="8:96:4:0 7:100:4:0 9:97:4:0 8:96:1:0 8:96:2:0 13:129:8:0 1:33:4:0
       7:100:4:3 9:97:4:2 13:129:8:5 16:32:4:7"
fail=0
for c in $CASES; do
  M=$(echo "$c" | cut -d: -f1); K=$(echo "$c" | cut -d: -f2)
  R=$(echo "$c" | cut -d: -f3); S=$(echo "$c" | cut -d: -f4)
  ( cd ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt "$M" "$K" "$R" >/dev/null )
  out=$( cd sim/work_mv && ghdl -r --std=08 --workdir=. tb_matvec_core \
           -gTRACE=../tr.txt -gRI="$R" -gSTALL="$S" --stop-time=50ms 2>&1 )
  n=$(echo "$out" | grep -oE 'TOTAL: [0-9]+ stage \+ [0-9]+ output' || true)
  if echo "$out" | grep -q "matches ref/matvec_int4.c"; then
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s  OK   %s\n" "$M" "$K" "$R" "$S" "$n"
  else
    printf "  M=%-3s K=%-4s ROWS_IF=%-2s stall=%-2s  FAIL\n" "$M" "$K" "$R" "$S"
    echo "$out" | head -5
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "== FAILED =="; exit 1; }
echo "== all green =="
