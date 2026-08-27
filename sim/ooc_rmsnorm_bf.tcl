# OOC of rmsnorm_bf against rmsnorm_rs on the FK33 part, same knobs.
#
# WHY: rmsnorm_bf replaces the absolute-grid mean+eps recipe with a
# block-floating one (see the header of rtl/rmsnorm_bf.vhd and
# docs/debugging/2026-08-26_rmsnorm-magnitude-window.md).  The arithmetic case
# for it is settled and measured.  What is NOT settled is what it costs, and
# that matters because the whole-die DSP budget is at 90.5-91.9% of 2,880 --
# there is no room for a fix that adds DSPs.
#
# The S_INV chain changed shape but not state count (6 either way) and gained
# no multiply: it trades a fixed shift, a divide-by-N and a clamp for two
# barrel shifts and an add.  So the expectation is DSP-neutral, LUT-neutral or
# slightly up, and timing-neutral.  Expectations are not measurements, hence
# this file.  Both units are built here in one run so the comparison is against
# the same Vivado, the same part and the same period.
#
# Q is swept because Q keeps a SECOND role in rmsnorm_bf -- the output grid of
# inv32 -- even though it no longer sets the mean grid.  The residual error is
# pure output quantization and scales with it (8.8e-3 at Q=12, 5.2e-4 at
# Q=16), so the cost of buying that accuracy has to be on the table.
set part   xcvu33p-fsvh2104-2L-e
set period 3.3
set rtldir [file normalize [file join [file dirname [info script]] .. rtl]]
set csv [open "rmsnorm_bf.csv" w]
puts $csv "unit,q,lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz"
foreach cfg {{rmsnorm_rs 12} {rmsnorm_bf 12} {rmsnorm_bf 16} {rmsnorm_bf 20}} {
  set unit [lindex $cfg 0]
  set Q    [lindex $cfg 1]
  puts "======== $unit Q=$Q LANES=4 ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir util_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir fixed_luts_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir fixed_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir $unit.vhd]
  synth_design -mode out_of_context -top $unit -part $part \
               -generic N=128 -generic LANES=4 -generic Q=$Q
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
  puts "RESULT $unit Q=$Q dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax"
  puts $csv "$unit,$Q,4,$ndsp,$nlut,$nff,$nbr,$wns,$fmax"
  flush $csv
  close_project
}
close $csv
puts "DONE"
