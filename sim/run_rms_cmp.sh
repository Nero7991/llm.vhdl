#!/bin/bash
# Post-synth funcsim: behavioral rmsnorm (lib beh) vs synthesized netlist
# (rmsnorm_net, lib work) driven by tb_rms_cmp over an xe sweep incl. negatives.
set -e
source /tools/Xilinx/2023.2/Vivado/2023.2/settings64.sh
GLBL=/tools/Xilinx/2023.2/Vivado/2023.2/data/verilog/src/glbl.v
rm -rf xsim.dir/beh xsim.dir/work xsim.dir/tbrr 2>/dev/null || true
# 1) behavioral rmsnorm + deps into lib 'beh'
xvhdl -2008 -work beh ../rtl/util_pkg.vhd ../rtl/fixed_luts_pkg.vhd ../rtl/fixed_pkg.vhd ../rtl/rmsnorm.vhd
# 2) netlist + tb into work
xvhdl -2008 -work work post_rmsnorm_net.vhd
xvhdl -2008 -work work tb_rms_cmp.vhd
xvlog -work work "$GLBL"
# 3) elaborate with unisim + run
xelab -L beh -L work -L unisim -L secureip work.tb_rms_cmp work.glbl -s tbrr -timescale 1ns/1ps >/dev/null
xsim tbrr -runall
