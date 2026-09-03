# OOC census of `rtl/gdn_state_store.vhd` -- the WHOLE resident state tier for
# one GDN layer: the URAM mantissa store, the distributed-RAM exponent store,
# TWO instances of the HBM mover, the sequencer that runs them in turn, and the
# AXI and store arbiters between them.
#
# THE QUESTION this answers that the component censuses do not: whether
# composing them costs anything beyond the sum.  The parts measured 32 URAM288
# (mantissa store), 2,466 CLB LUT (exponent store), and 269 LUT / 703 FF /
# 1 DSP (one mover); this is what the card actually pays for all of it, with
# the second mover instance and the muxes included.  Separately-measured units
# not sharing is the assumption this project keeps getting burned by, so it is
# a hypothesis a composed draw tests.
#
# THE SECOND MOVER IS NOT FREE AND IS NOT FULL PRICE EITHER.  It carries the
# same control FSM at `WORD_BITS => 8, N_GRP => 1`, so its counters are
# narrower (8 bursts against 2,048) while its FSM is identical.  The number to
# watch is whether LUT lands nearer 497 + 269 + 2,466 or well above it.
#
# STYLE IS "ultra" ON PURPOSE.  MEASURED: `auto` gives 228 BRAM and no URAM,
# which does not fit beside the composition.  A run at "auto" is not pricing
# the shipping design.
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
read_vhdl -vhdl2008 [file join $rtldir gdn_state_mem.vhd]
read_vhdl -vhdl2008 [file join $rtldir gdn_exp_mem.vhd]
read_vhdl -vhdl2008 [file join $rtldir gdn_state_axi.vhd]
read_vhdl -vhdl2008 [file join $rtldir gdn_state_store.vhd]
synth_design -mode out_of_context -top gdn_state_store -part $part \
  -generic VAL_HEADS=32 -generic DIM=128 -generic RECUR_LANES=4 \
  -generic LAYERS=24 -generic LAYER_STRIDE=1101824 \
  -generic MANT_BYTES=1048576 -generic EXP_BYTES=4096 \
  -generic AXI_DW=256 -generic ADDR_W=33 -generic MAXB=16 -generic MAXOUT=4

create_clock -period $period -name clk [get_ports clk]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
set matched 0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} {
  set wns $w; set matched 1
}
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nb36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set nb18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
# The exponent store is distributed RAM.  RAM*/SRL* primitives occupy LUT
# SITES that the LUT* filter above cannot see, which is the 4.5x error the
# header warns about; count them so the two numbers can be reconciled.
set nram  [llength [get_cells -hier -filter {REF_NAME =~ RAM6*}]]
set nram3 [llength [get_cells -hier -filter {REF_NAME =~ RAM3*}]]
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
puts "CENSUS gdn_state_store LUT=$nlut FF=$nff RAMB36=$nb36 RAMB18=$nb18 \
URAM288=$nuram DSP=$ndsp RAM64=$nram RAM32=$nram3 WNS=$wns \
WNS_MATCHED=$matched"
puts "---- report_utilization, for cross-check ----"
puts [report_utilization -return_string]
puts "GDN_STATE_STORE_CENSUS_DONE"
