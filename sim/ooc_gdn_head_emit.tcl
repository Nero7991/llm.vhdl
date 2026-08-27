# OOC of gdn_head_emit (subsystem B site 12) on the FK33 part.
#
# WHY: the unit is bit-exact and mutation-tested, so what is left to know is
# what it costs and whether it holds B's clock.  Two specific risks:
#
#   * The DIM x 48-bit column store.  It is written as a synchronous-read RAM
#     so Vivado should infer ONE RAMB18.  If it instead lands in distributed
#     RAM or, worse, in flops, that is 6,144 bits of registers and the unit's
#     area argument is wrong.  The cell counts below say which happened.
#   * The two barrel shifts.  Alignment shifts s40 by up to 63, and there are
#     two of them (pass B and pass C).  They are in separate pipeline stages
#     by construction, so the expectation is that neither is the critical
#     path, but B's clock is 299.04 MHz from gdn_recur_pipe and this unit
#     shares it.
#
# DIM is swept because the head_v_dim = 128 figure has been wrong in this
# project's notes before (a 256 briefly propagated through an agent brief), and
# because C may reuse this unit at a different width.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_head_emit.csv" w]
puts $csv "dim,dsp,lut,ff,bram,lutram,wns_ns,fmax_mhz"
foreach D {64 128 256} {
  puts "======== gdn_head_emit DIM=$D ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_head_emit.vhd]
  synth_design -mode out_of_context -top gdn_head_emit -part $part -generic DIM=$D
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
  set nlr  [llength [get_cells -hier -filter {REF_NAME =~ RAM*} -quiet]]
  puts "RESULT DIM=$D dsp=$ndsp lut=$nlut ff=$nff bram=$nbr lutram=$nlr wns=$wns fmax=$fmax"
  puts $csv "$D,$ndsp,$nlut,$nff,$nbr,$nlr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "DONE"
