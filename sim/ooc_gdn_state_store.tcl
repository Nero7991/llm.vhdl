# OOC synthesis of gdn_state_store at its DEFAULT generics, which are already
# the real 9B card shape (VAL_HEADS 32, DIM 128, LAYERS 24, KEY_HEADS 16,
# KCONV 4) -- confirmed against llama_top's own generic map.
#
# WHY RE-MEASURE SOMETHING THAT HAS A RECORDED FIGURE.
# docs/PLAN_TO_FIRST_INFERENCE.md carries "4,028 CLB LUT, 2,004 FF, 32
# URAM288, 12 RAMB36, 3 DSP, WNS +1.400" for this file.  Twice on 2026-09-06 a
# quoted table turned out to describe a different tree than the one being
# reasoned about, and in one of those cases the stale table was internally
# consistent so no arithmetic check could have caught it.  This run establishes
# the number against THIS tree, which is the only tree the fit answer is about.
#
# The control that makes a difference attributable, if one appears: the URAM
# count.  URAM is fixed at synthesis and unmoved by implementation directives,
# and gdn_state_mem is STYLE "ultra", so 32 URAM288 is a structural prediction.
# A run that reports uram=0 has been REFUSED the resource -- see
# `[Synth 8-10226]`, which grants BRAM instead and only WARNS.
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
read_vhdl -vhdl2008 [glob [file join $rtldir *.vhd]]
synth_design -mode out_of_context -top gdn_state_store -part $part
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization ==="
puts [report_utilization -return_string]
puts "=== Report RAM Utilization (the NAMING table) ==="
if {[catch {puts [report_ram_utilization -return_string]} e]} { puts "no ram report: $e" }
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
set nbram [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
puts "RESULT gdn_state_store lut=$nlut ff=$nff dsp=$ndsp bram=$nbram uram=$nuram wns=$wns"
puts "GDN_STATE_STORE_OOC_DONE"
