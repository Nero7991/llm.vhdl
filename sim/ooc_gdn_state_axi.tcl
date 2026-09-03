# OOC census of `rtl/gdn_state_axi.vhd` at the real 9B geometry, FK33 part.
#
# THE QUESTION: what does the HBM state mover cost, and does it close 5.0 ns?
# The store it feeds is already measured at 32 URAM288
# (sim/ooc_gdn_state.tcl); this is the other half.
#
# The generics here are the SHIPPING ones, from tools/hbm_map.py::arena_sizes()
# against QWEN35_9B: 24 GDN layers, 1,048,576 mantissa bytes per layer, stride
# 1,052,672.  A run with different numbers is not pricing the card's mover.
# THE `PRIMITIVE_GROUP` FILTER DOES NOT WORK IN THIS VIVADO AND RETURNS ZERO.
# MEASURED 2026-09-02: `get_cells -hier -filter {PRIMITIVE_GROUP == LUT}` and
# `== FLOP_LATCH` both returned 0 on a design whose own report_utilization said
# 269 LUTs and 703 registers in the same run.  A census that reports zero looks
# like a tiny module rather than like a broken filter, which is the worst way
# for a measurement to fail.  Use REF_NAME patterns, and CROSS-CHECK against
# report_utilization every time -- when they disagree the census wins, but only
# once you know both are actually counting something.

#
# THE OBJECT CENSUS DOES NOT SEE DISTRIBUTED RAM, AND THE SITE COUNT IS THE
# BUDGET.  MEASURED 2026-09-02 on `gdn_exp_mem`: `REF_NAME =~ LUT*` reported
# 550 while `report_utilization`'s `CLB LUTs` reported 2,466, because 384
# RAM64M8 primitives occupy 1,920 LUT SITES -- five each -- and the LUT filter
# matches none of them.  Wrong by 4.5x.  Quote `CLB LUTs` for area; use the
# object census to answer WHICH PRIMITIVE was inferred, which is a different
# question.

set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl

create_project -in_memory -part $part
read_vhdl -vhdl2008 [file join $rtldir util_pkg.vhd]
read_vhdl -vhdl2008 [file join $rtldir gdn_state_axi.vhd]
synth_design -mode out_of_context -top gdn_state_axi -part $part \
  -generic VAL_HEADS=32 -generic DIM=128 -generic RECUR_LANES=4 \
  -generic LAYERS=24 -generic LAYER_STRIDE=1052672 \
  -generic MANT_BYTES=1048576 \
  -generic AXI_DW=256 -generic ADDR_W=33 -generic MAXB=16 -generic MAXOUT=4

create_clock -period $period -name clk [get_ports clk]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
set matched 0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} {
  set wns $w; set matched 1
}
# THE REGEX EITHER MATCHED OR IT DID NOT, AND THE REPORT SAYS WHICH.  A
# previous census in this repository printed its initialiser as a measurement
# when the match failed, and the 0.0 sat in the same column as a real number.
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nb36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set nb18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
puts "CENSUS gdn_state_axi LUT=$nlut FF=$nff RAMB36=$nb36 RAMB18=$nb18 \
URAM288=$nuram DSP=$ndsp WNS=$wns WNS_MATCHED=$matched"
puts "---- report_utilization, for cross-check ----"
puts [report_utilization -return_string]
puts "GDN_STATE_AXI_CENSUS_DONE"
