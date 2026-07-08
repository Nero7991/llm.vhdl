#!/bin/bash
set -e
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
rm -rf xsim.dir/beh xsim.dir/work xsim.dir/tbac 2>/dev/null || true
# behavioral attention_ml + deps -> lib beh
xvhdl -2008 -work beh ../rtl/util_pkg.vhd ../rtl/fixed_luts_pkg.vhd ../rtl/fixed_pkg.vhd ../rtl/kv_mem.vhd ../rtl/softmax.vhd ../rtl/attention_ml.vhd
# netlist (entity attention_ml, slv ports) + wrapper + tb -> work
xvhdl -2008 -work work post_attn_net.vhd
xvhdl -2008 -work work attn_net_wrap.vhd
xvhdl -2008 -work work tb_attn_cmp.vhd
xvlog -work work "/tools/Xilinx/2023.2/Vivado/2023.2/data/verilog/src/glbl.v"
xelab -L beh -L work -L unisim -L secureip work.tb_attn_cmp work.glbl -s tbac -timescale 1ns/1ps >/dev/null
xsim tbac -runall
