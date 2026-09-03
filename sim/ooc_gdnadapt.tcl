# OOC synthesis of subsystem B's DATA MOVER, extracted from llama_top's
# gb_real block by sim/ooc_gdnadapt_extract.py.  Same method as
# sim/ooc_normadapt_extract.py + the nwrom runs did for the D-vec norm adapter.
#
# WHAT THIS ANSWERS: what B's mover costs, which nothing has ever measured,
# because until now the block could not be built outside llama_top.
# WHAT IT DOES NOT: whether B computes a correct token.  llama_top:4316 still
# refuses B_SRC_REAL past token 0.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }
# MAXROWS is swept from the environment so the 9B default and a small control
# are the SAME script.  See the generic's comment in the extract script.
set mr [expr {[info exists ::env(GDNADAPT_MAXROWS)] ? $::env(GDNADAPT_MAXROWS) : 0}]
puts "=== A_MAXROWS override = $mr (0 = region_max(SHAPE), 12288 at 9B) ==="
synth_design -mode out_of_context -top ooc_gdnadapt -part $part -generic MAXROWS_OVR=$mr
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "RESULT ooc_gdnadapt wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "OOC_GDNADAPT_DONE"
