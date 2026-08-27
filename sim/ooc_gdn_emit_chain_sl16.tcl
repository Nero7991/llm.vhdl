# OOC of gdn_emit_chain at SILU_LANES=16 -- the WHOLE of subsystem B's emit path in one netlist:
# gdn_head_emit -> rmsnorm_bf -> gdn_silu -> gdn_y_emit, plus the sequencer.
#
# WHY THIS RUN, given every unit already has its own OOC number.  Three things
# are only knowable in the assembled netlist:
#
#   * The per-block weight LATCH added 2026-08-27 is DIM*16 = 2048 flops on
#     paper. Paper is where that number is; this says what it actually costs
#     and whether Vivado keeps it as flops or does something else with it.
#   * Fmax of the chain, which the unit numbers cannot give. The parts range
#     from 389.4 MHz (gdn_head_emit, post-double-buffer) to 577.4 MHz, and
#     B's clock target is 299.04 MHz. The chain's critical path may run
#     BETWEEN units -- seam 1 in particular converts he_e_head to an integer
#     and feeds it straight into rmsnorm_bf's exponent arithmetic.
#   * Whether the four units' resources simply add. They should, but
#     `he_mant` and `rn_mant` are 2048-bit buses driven into a second unit,
#     and wide buses across a hierarchy boundary are where synthesis
#     replicates drivers.
#
# RMS_LANES is swept because l2norm_rs at 4 lanes closes only 285.8 MHz, below
# B's 299.04 MHz target, so the norm is the known suspect for the chain's
# critical path and it is worth knowing what a narrower norm buys.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "gdn_emit_chain_sl16.csv" w]
puts $csv "rms_lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach RL {2 4 6 8} {
  puts "======== gdn_emit_chain RMS_LANES=$RL ========"
  create_project -in_memory -part $part
  foreach f {util_pkg fixed_luts_pkg fixed_pkg \
             gdn_head_emit rmsnorm_bf gdn_silu gdn_y_emit gdn_emit_chain} {
    read_vhdl -vhdl2008 [file join $rtldir $f.vhd]
  }
  synth_design -mode out_of_context -top gdn_emit_chain -part $part \
               -generic HEADS=24 -generic DIM=128 \
               -generic SILU_LANES=16 -generic RMS_LANES=$RL -generic Q=12
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
  puts "RESULT RMS_LANES=$RL dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  # The worst path, printed rather than summarized, because "the chain closes
  # at X MHz" is not actionable without knowing which unit or seam owns it.
  puts "---- worst path ----"
  puts [report_timing -max_paths 1 -nworst 1 -return_string]
  puts $csv "$RL,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "CHAIN_OOC_DONE"
