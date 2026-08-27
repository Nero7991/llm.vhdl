# OOC of gdn_emit_chain across SILU_LANES, run on the BC-250.
#
# Complementary to sim/ooc_gdn_emit_chain.tcl, which sweeps RMS_LANES on the
# workstation. Split this way because the two axes are independent and the
# BC-250 is 2.3x slower end to end but produces bit-identical results (DSP,
# LUT, FF, BRAM, WNS and Fmax match to 13 significant figures), so the two
# halves of the sweep are directly comparable.
#
# WHY SILU_LANES IS WORTH A SWEEP.  It sets how many cycles the gate takes to
# absorb a head: SI_BEATS = DIM/SILU_LANES, so 4 beats at 32 lanes and 2 at 64.
# The chain's S_GATE is not the long pole -- rmsnorm_bf's ~142 cycles is -- so
# the expectation is that WIDENING buys nothing and NARROWING is nearly free.
# If that holds, SILU_LANES should be dropped to 16 or 8 and the LUTs spent
# elsewhere, and this run is what decides it. A sweep that confirms a component
# is oversized is as useful as one that finds it too small.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_emit_chain_silu.csv" w]
puts $csv "silu_lanes,si_beats,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach SL {8 16 32 64} {
  puts "======== gdn_emit_chain SILU_LANES=$SL ========"
  create_project -in_memory -part $part
  foreach f {util_pkg fixed_luts_pkg fixed_pkg \
             gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain} {
    read_vhdl -vhdl2008 [file join $rtldir $f.vhd]
  }
  synth_design -mode out_of_context -top gdn_emit_chain -part $part \
               -generic HEADS=24 -generic DIM=128 \
               -generic SILU_LANES=$SL -generic RMS_LANES=4 -generic Q=12
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
  set beats [expr {128/$SL}]
  puts "RESULT SILU_LANES=$SL beats=$beats dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$SL,$beats,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "CHAIN_SILU_OOC_DONE"
