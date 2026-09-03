# OOC synthesis of a_desc_ptr at the 9B token program's shape: 311 A jobs, a
# 512-byte slot, 40-bit addresses.  The number to watch is CARRY: the address
# is BASE + n*STRIDE with STRIDE an elaboration constant and a power of two, so
# the multiply must vanish into a shift and the only adder should be the
# 40-bit base add.  A DSP here would mean the constant did not fold.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
read_vhdl -vhdl2008 [file join $rtldir util_pkg.vhd]
read_vhdl -vhdl2008 [file join $rtldir a_desc_ptr.vhd]
synth_design -mode out_of_context -top a_desc_ptr -part $part \
             -generic ADDR_W=40 -generic STRIDE=512 \
             -generic DESC_ALIGN=512 -generic N_JOBS=311
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
set ncar [llength [get_cells -hier -filter {REF_NAME =~ CARRY*}]]
set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
puts "RESULT a_desc_ptr dsp=$ndsp carry=$ncar ff=$nff wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "A_DESC_PTR_OOC_DONE"
