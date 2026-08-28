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
#
# 2026-08-27: takes an optional voltage argument.
#
#   vivado -mode batch -source sim/ooc_gdn_emit_chain_silu.tcl -tclargs 0.717 [SL...]
#
# The table this script first produced is what rejected SILU_LANES = 8 ("295.8
# -- misses 299.04") and cost 32 DSP to keep 16 lanes.  Both sides of that
# comparison are 0.85 V numbers, and the card runs at 0.717 V against a
# MEASURED 237.8 MHz.  With a voltage given, each point is re-analysed at that
# VCCINT on the SAME netlist -- no re-synthesis, no placement -- so the pair is
# a pure derate and the two columns are directly subtractable.  The default
# column is re-measured every run rather than quoted from the committed CSV, so
# a failure to reproduce 295.77 / 300.75 / 288.68 / 266.81 is visible
# immediately instead of being carried into the derate.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set volt   -1
set sllist {8 16 32 64}
if {[llength $argv] > 0 && [regexp {^[0-9.]+$} [lindex $argv 0]]} {
  set volt [lindex $argv 0]
  if {[llength $argv] > 1} { set sllist [lrange $argv 1 end] }
}
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csvname [expr {$volt > 0 ? "gdn_emit_chain_silu_volt.csv" : "gdn_emit_chain_silu.csv"}]
set csv [open $csvname w]
if {$volt > 0} {
  puts $csv "silu_lanes,si_beats,dsp,lut,ff,bram,part_default,wns_default,fmax_default,part_volt,volt,wns_volt,fmax_volt,derate_pct"
} else {
  puts $csv "silu_lanes,si_beats,dsp,lut,ff,bram,wns_ns,fmax_mhz"
}
foreach SL $sllist {
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
  if {$volt > 0} {
    report_timing -delay_type max -max_paths 1 \
      -file [file join [file dirname [info script]] ooc_micro path_emit_SL${SL}_default.rpt]
  }
  set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
  set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
  set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
  set nbr  [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
                + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
  set beats [expr {128/$SL}]
  puts "RESULT SILU_LANES=$SL beats=$beats dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  if {$volt > 0} {
    # Record the part name on both sides.  In a place-and-route flow the same
    # constraint makes Vivado reload the part as the -2LV variant
    # ([Vivado 12-4441]), which is a speed grade change rather than a derate.
    # If that happened here too, the "same netlist, one variable" claim would
    # be false, so it is checked rather than assumed.
    set part_before [get_property PART [current_project]]
    set_operating_conditions -voltage [list VCCINT $volt]
    set part_after [get_property PART [current_project]]
    puts "VOLTCHECK SILU_LANES=$SL part before=$part_before after=$part_after"
    # Dump the worst path at BOTH voltages.  A bare Fmax says the design got
    # slower and not which path binds, and on this chain the binding path is
    # known to CHANGE identity with voltage -- gdn_silu's gate at 0.85 V,
    # rmsnorm_bf's rsqrt DSP at 0.717 V.  A single derate ratio cannot describe
    # that, so the path is recorded next to the number rather than inferred.
    report_timing -delay_type max -max_paths 1 \
      -file [file join [file dirname [info script]] ooc_micro path_emit_SL${SL}_v${volt}.rpt]
    set rptv [report_timing_summary -no_header -return_string]
    set wnsv 0.0
    if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rptv -> w]} { set wnsv $w }
    set fmaxv [expr {1000.0/($period - $wnsv)}]
    set der [expr {100.0*($fmax-$fmaxv)/$fmax}]
    puts [format "RESULTVOLT SILU_LANES=%s VCCINT=%s wns=%s fmax=%.3f derate=%.2f%%" \
          $SL $volt $wnsv $fmaxv $der]
    puts $csv "$SL,$beats,$ndsp,$nlut,$nff,$nbr,$part_before,$wns,$fmax,$part_after,$volt,$wnsv,$fmaxv,$der"
  } else {
    puts $csv "$SL,$beats,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  }
  flush $csv
  close_project
}
close $csv
puts "CHAIN_SILU_OOC_DONE"
