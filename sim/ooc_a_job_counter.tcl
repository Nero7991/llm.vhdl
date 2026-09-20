# OOC synthesis of a_job_counter at the 9B token program's shape (311 A jobs).
#
# The number to watch is that there is almost nothing here: this module counts,
# and `rtl/a_desc_adapter.vhd` does the addressing.  An earlier version of this
# file synthesised `rtl/a_desc_ptr.vhd`, which computed BASE + n*STRIDE and
# measured 20 LUT / 50 FF / 4 CARRY -- and every one of those CARRYs was a
# second model of an adder `a_desc_adapter` already had.  A CARRY chain here
# now would mean the address arithmetic had crept back in.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
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
create_project -in_memory -part $part
read_vhdl -vhdl2008 [file join $rtldir a_job_counter.vhd]
synth_design -mode out_of_context -top a_job_counter -part $part \
             -generic N_JOBS=311
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
set ncar [llength [get_cells -hier -filter {REF_NAME =~ CARRY*}]]
set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
puts "RESULT a_job_counter dsp=$ndsp carry=$ncar ff=$nff wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "A_JOB_COUNTER_OOC_DONE"
