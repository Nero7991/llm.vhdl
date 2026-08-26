# OOC sweep of gdn_scalar across the scalar-path grid SP_Q, on the FK33 part.
# Answers 2.8's unpriced "softplus + scalar, believed cheap, +2 to +4 DSP" row,
# and prices the Q12 -> Q18 amendment measured in
# docs/debugging/2026-08-26_gdn-scalar-path.md.
set part   xcvu33p-fsvh2104-2L-e
set period 3.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
set csv [open "gdn_scalar_sweep.csv" w]
puts $csv "sp_q,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach Q {12 15 18} {
  puts "======== gdn_scalar SP_Q=$Q ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir util_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir fixed_luts_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir gdn_scalar.vhd]
  synth_design -mode out_of_context -top gdn_scalar -part $part \
               -generic SP_Q=$Q
  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/($period - $wns)}]
  set dsp  [get_property STATUS [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set nlut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
  set nff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
  set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
  puts "RESULT SP_Q=$Q dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$Q,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "GDN_SCALAR_SWEEP_DONE"
