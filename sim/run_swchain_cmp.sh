#!/bin/bash
set -e
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
cd "$(dirname "$0")"
rm -rf xsim.dir/beh xsim.dir/work xsim.dir/tbsc 2>/dev/null || true

# Behavioral RTL wrapper + deps -> lib beh
xvhdl -2008 -work beh ../rtl/util_pkg.vhd ../rtl/fixed_luts_pkg.vhd ../rtl/fixed_pkg.vhd \
      ../rtl/vec_mem.vhd ../rtl/swiglu.vhd ../rtl/bfp_pack.vhd sw_chain.vhd golden_pkg.vhd

# Synthesized netlist (entity sw_chain, slv ports) + tb -> work
xvhdl -2008 -work work post_swchain_net.vhd
xvhdl -2008 -work work tb_swchain_cmp.vhd
xvlog -work work "/tools/Xilinx/2023.2/Vivado/2023.2/data/verilog/src/glbl.v"

xelab -L beh -L work -L unisim -L secureip work.tb_swchain_cmp work.glbl -s tbsc -timescale 1ns/1ps
xsim tbsc -runall
