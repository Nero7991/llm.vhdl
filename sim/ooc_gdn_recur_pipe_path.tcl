# Bucket the failing path in gdn_recur_pipe after the double buffer.
# The point is the PATH, not the number: this codebase's rmsnorm_rs work got
# from 117 to 300 MHz by reading the failing path seven times, and got nowhere
# guessing (MREG was predicted to be the fix and was worth 26 MHz of 183).
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
create_project -in_memory -part $part
read_vhdl -vhdl2008 [file join $rtldir gdn_recur_pipe.vhd]
synth_design -mode out_of_context -top gdn_recur_pipe -part $part \
             -generic LANES=32 -generic SLOTS=16
create_clock -period $period -name clk [get_ports clk]
puts "==== UTIL ===="
puts "dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]"
puts "lut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]"
puts "ff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]"
puts "bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] \
              + 0.5*[llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]"
puts "==== WORST PATHS ===="
foreach pth [get_timing_paths -max_paths 6 -nworst 1 -setup] {
  set slack [get_property SLACK $pth]
  set src   [get_property STARTPOINT_PIN $pth]
  set dst   [get_property ENDPOINT_PIN $pth]
  set lvl   [get_property LOGIC_LEVELS $pth]
  puts "PATH slack=$slack levels=$lvl"
  puts "   from $src"
  puts "   to   $dst"
}
puts "PIPE_PATH_DONE"
