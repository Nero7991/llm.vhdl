#!/bin/bash
# Post-synthesis FUNCSIM of subsystem A, against the same vectors as the RTL.
#
# The RTL is checked against the C reference by sim/run_matvec.sh.  The NETLIST
# is only argued-equivalent to the RTL, and this subsystem needed four
# synthesis-driven rewrites (spec 7.9a) that simulation could not see.  This
# closes that gap: same testbench, same trace, real UNISIM primitives.
#
# Follows sim/e2_funcsim (the v1.0 gate-level flow): xvhdl + xelab + xsim, since
# GHDL has no UNISIM library here.
set -e
cd "$(dirname "$0")"
NET=../ooc_mv/mv_net.vhd
[ -f "$NET" ] || { echo "no netlist: run sim/ooc_matvec_int4.tcl first"; exit 1; }

source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh

python3 gen_net_tb.py

#     M    K   ROWS_IF   STALL
CASES="8:96:4:3 7:100:4:3 9:97:4:2 16:32:4:5 1:33:4:0"

echo "== compile netlist + testbench =="
rm -rf xsim.dir *.jou *.log *.pb
xvhdl -2008 -work work "$NET"                > xvhdl.log 2>&1
xvhdl -2008 -work work tb_matvec_int4_net.vhd >> xvhdl.log 2>&1
xelab -L work -L unisim -L secureip work.tb_matvec_int4_net \
      -s mvnet -timescale 1ns/1ps > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

fail=0
for c in $CASES; do
  M=$(echo "$c" | cut -d: -f1); K=$(echo "$c" | cut -d: -f2)
  R=$(echo "$c" | cut -d: -f3); S=$(echo "$c" | cut -d: -f4)
  ( cd ../../ref && ../sim/work_mv/mv4i --trace ../sim/tr.txt "$M" "$K" "$R" >/dev/null )
  out=$(xsim mvnet -runall 2>&1)
  n=$(echo "$out" | grep -oE 'end to end: [0-9]+ rows compared[^,]*, [0-9]+ mismatches' || true)
  if echo "$out" | grep -q "from the packed bytes up"; then
    printf "  M=%-3s K=%-4s stall=%-2s  OK   %s\n" "$M" "$K" "$S" "$n"
  else
    printf "  M=%-3s K=%-4s stall=%-2s  FAIL\n" "$M" "$K" "$S"
    echo "$out" | grep -iE "error|mismatch|fail" | head -5
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "== NETLIST DIVERGES =="; exit 1; }
echo "== netlist matches the C reference =="
