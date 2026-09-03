# gdn_block ALONE, at the generics `gb_real` instantiates it with.
#
# THE ATTRIBUTION CONTROL for sim/ooc_gdnadapt.tcl.  That script synthesises
# the extracted mover, which CONTAINS this instance, so its total is not the
# mover's cost.  This project has been bitten three times by parts that do not
# sum (docs/PLAN_TO_FIRST_INFERENCE.md, the gdn_state_store rows), so the
# component number is measured rather than assumed.
#
# LAYERS=24 is CHECKED, not guessed: model_cfg_pkg 9B has blocks=32 and
# attn_interval=4, so attn_layers = 32/4 = 8 and gdn_layers = 32-8 = 24.
#
# gdn_block has never been synthesised as a whole before this file:
# docs/2026-08-27_die-allocation-at-rows-if-48.md:117 gives B's figure as
# "DERIVED from MEASURED parts", and there was no ooc_gdn_block.tcl.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }
# The 9B shape as gb_real derives it: KEY_HEADS/VAL_HEADS/DIM/KCONV/LAYERS come
# from SHAPE, the lane counts from llama_top's B_* generics.
synth_design -mode out_of_context -top gdn_block -part $part \
             -generic KEY_HEADS=16 -generic VAL_HEADS=32 -generic DIM=128 \
             -generic KCONV=4 -generic LAYERS=24 \
             -generic CONV_LANES=4 -generic RECUR_LANES=4 \
             -generic RECUR_SLOTS=16 -generic L2_LANES=4 \
             -generic SILU_LANES=8 -generic RMS_LANES=4
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "RESULT gdn_block wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "OOC_GDN_BLOCK_DONE"
