# OOC synthesis of gdn_job_seq at the SHIPPING 9B shape.  The module is an FSM
# plus a two-stage index pipeline, so the number to watch is not its size but
# whether the split arithmetic infers comparators against CONSTANTS: NG_K and
# 2*NG_K are elaboration constants, so the walk must cost two compares and two
# subtracts and nothing that scales with QKVN.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
read_vhdl -vhdl2008 [file join $rtldir gdn_job_seq.vhd]
synth_design -mode out_of_context -top gdn_job_seq -part $part \
             -generic VAL_HEADS=32 -generic DIM=128 -generic KEY_HEADS=16 \
             -generic KCONV=4 -generic CONV_LANES=4 -generic LAYERS=24
create_clock -period $period -name clk [get_ports clk]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
# THE MAPPING REPORT IS AUTHORITATIVE, THE PRIMITIVE CENSUS IS THE CROSS-CHECK.
# A first version of this script used `PRIMITIVE_GROUP == LUT` alone and
# reported lut=0 ff=0 on a design with a 1.09 ns critical path -- a filter that
# matched nothing, reported as a design that contained nothing.  Zero with a
# real timing path is the tell.
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nram [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
set ncar [llength [get_cells -hier -filter {REF_NAME =~ CARRY*}]]
puts "RESULT gdn_job_seq lut=$nlut ff=$nff ram=$nram carry=$ncar wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "GDN_JOB_SEQ_OOC_DONE"
