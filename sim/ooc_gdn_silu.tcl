# OOC sweep of gdn_silu across LANES on the FK33 part.
#
# What this answers: 3.2 prices silu at a "3-cycle FSM rate" over 393,216
# evaluations per token per card = 1,179,648 cycles = 3.93 ms, the second
# largest term in B's whole budget after the output rmsnorm. That rate is a
# scalar assumption. This unit is II = 1 at LANES lanes, so the cycle count is
# 393,216 / LANES, and the question is what that costs in DSP and BRAM and
# whether it still closes timing -- swiglu.vhd's header records that N parallel
# copies of the sigmoid chain cost 360 DSP and 100% of a smaller device, so the
# lane count is not free by assumption.
set part   xcvu33p-fsvh2104-2L-e
set period 3.0
# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
set rtldir $pfRoot/rtl
set csv [open "gdn_silu_sweep.csv" w]
puts $csv "lanes,dsp,lut,ff,bram,wns_ns,fmax_mhz,cycles_per_token_card,ms_at_300"
foreach L {1 2 4 8 16} {
  puts "======== gdn_silu LANES=$L ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 [file join $rtldir fixed_luts_pkg.vhd]
  read_vhdl -vhdl2008 [file join $rtldir gdn_silu.vhd]
  synth_design -mode out_of_context -top gdn_silu -part $part -generic LANES=$L
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
  # 3.2's derivation: silu(conv_out) over the per-card conv width 5,120 plus
  # silu(z_h) over the per-card value width 3,072 = 8,192 per layer x 48.
  set cyc [expr {393216 / $L}]
  set ms  [expr {$cyc / 300.0e6 * 1000.0}]
  puts "RESULT L=$L dsp=$ndsp lut=$nlut ff=$nff bram=$nbr wns=$wns fmax=$fmax cycles=$cyc ms=$ms"
  puts $csv "$L,$ndsp,$nlut,$nff,$nbr,$wns,$fmax,$cyc,$ms"
  flush $csv
  close_project
}
close $csv
puts "GDN_SILU_SWEEP_DONE"
