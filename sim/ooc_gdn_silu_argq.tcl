# OOC sweep of gdn_silu across the ARGUMENT grid ARG_Q, at the chosen LANES = 4.
#
# The accuracy half of this question is answered by ref/gdn_silu_vec.c, which
# measures each ARG_Q against a double oracle: worst absolute error bottoms out
# at ~1.6 LSB from Q14, Q12 sits 16% above that floor, and Q10 is 4.4 LSB.
# The relative error is bit-identical at every ARG_Q because it comes from the
# Q15 sigma OUTPUT grid, not the argument grid.
#
# This is the cost half: what does moving the argument grid do to DSP, BRAM and
# Fmax?  2.1 pins Q12; the point is to price that choice the way SP_Q's was,
# not to change it.
set part   xcvu33p-fsvh2104-2L-e
set period 3.0
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_silu_argq.csv" w]
puts $csv "arg_q,lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach Q {10 12 14 16 18} {
  puts "======== gdn_silu ARG_Q=$Q LANES=4 ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir fixed_luts_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir gdn_silu.vhd]
  synth_design -mode out_of_context -top gdn_silu -part $part \
               -generic LANES=4 -generic ARG_Q=$Q
  create_clock -period $period -name clk [get_ports clk]
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/($period - $wns)}]
  set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
  set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
  puts "RESULT ARG_Q=$Q dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$Q,4,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "GDN_SILU_ARGQ_DONE"
