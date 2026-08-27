# OOC of gdn_y_emit (subsystem B site 13) on the FK33 part.
#
# WHY: the unit is bit-exact and mutation-tested, so what is left is cost and
# clock.  Specific risks:
#
#   * The product store is HEADS*DIM x 32 bits = 98,304 bits at 24 x 128,
#     which should be about 3 RAMB36.  It is PINNED to block RAM, so a result
#     showing zero BRAM would mean the pin was ignored and 98 kbit landed in
#     flops.
#   * The multiply is the only DSP in the unit and should be exactly 1 or 2
#     (int16 x int16 is one DSP48E2, whose primitive is 27x18).  More than
#     that means something else inferred a multiplier.
#   * The per-head exponent lookup is a HEADS-to-1 mux on 8 bits and has its
#     own pipeline stage.  If it were folded into the shift stage it would put
#     a mux in front of a barrel shift, the pairing that held rmsnorm_rs at
#     117.2 MHz.  B's clock is 299.04 MHz.
#
# HEADS is swept because 24 is the per-card value at N=2 cards and 48 is the
# single-card value, and the single-card fallback is a live option
# (docs/2026-08-25_single-card-fallback-decision.md).
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_y_emit.csv" w]
puts $csv "heads,dim,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach H {8 24 48} {
  puts "======== gdn_y_emit HEADS=$H DIM=128 ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir gdn_y_emit.vhd]
  synth_design -mode out_of_context -top gdn_y_emit -part $part \
               -generic HEADS=$H -generic DIM=128
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
  puts "RESULT HEADS=$H dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$H,128,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "DONE"
