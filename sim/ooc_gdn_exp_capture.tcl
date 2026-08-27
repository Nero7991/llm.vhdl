# OOC of gdn_exp_capture (section 2.1.2, the captured conv slot exponents).
#
# WHY: the unit is bookkeeping, so the interesting questions are not DSP but
# (a) does the pinned block RAM actually appear -- at 48 layers x 3 segments x
# 32 bits it is only 4,608 bits, small enough that a tool might fold it into
# flops despite the ram_style attribute, and 4,608 flops would be a real cost
# for a table this cold; and (b) does the combinational tvalid mux over the
# counter array stay off the critical path, since it is read on the same cycle
# the RAM data lands.
#
# LAYERS is swept because 48 is the GDN layer count of Qwen3.8-27B and 64 is
# the total block count; if the capture file were ever indexed by block rather
# than by GDN layer it would be 64, and the cost difference should be on the
# record rather than assumed negligible.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_exp_capture.csv" w]
puts $csv "layers,segs,k,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach L {48 64} {
  puts "======== gdn_exp_capture LAYERS=$L ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_exp_capture.vhd]
  synth_design -mode out_of_context -top gdn_exp_capture -part $part \
               -generic LAYERS=$L -generic SEGS=3 -generic K=4
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
  puts "RESULT LAYERS=$L dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$L,3,4,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "DONE"
