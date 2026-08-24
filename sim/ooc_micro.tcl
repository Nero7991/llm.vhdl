# OOC synthesis of a single-lane micro-skeleton, on a REAL part at a REAL clock.
#
#   vivado -mode batch -source sim/ooc_micro.tcl -tclargs <part> <period_ns> <top> <vhd>...
#
# Separate from ooc_core_sweep.tcl because the question is different.  The sweep
# fits DSP = a + b*ROWS_IF over a subsystem that already exists in RTL; this
# prices ONE LANE of a subsystem that does not exist yet, so the whole output is
# a per-lane triple (DSP, LUT, FF) to be multiplied by a lane count.
#
# The extra thing this does, and the reason it is not just a two-line synth
# call, is the DSP48E2 census after the run.  A bare count answers "how many"
# but not "why", and every previous surprise in this project has been a why:
# whether a multiplier was strength-reduced to a shifter, whether a wide
# operand split across a DSP pair, whether an adder got its own DSP.  So each
# DSP48E2 is dumped with the properties that distinguish those cases, and the
# result is reconciled against a hand count printed by the caller.  If they
# disagree, the utilisation number is not to be believed regardless of which is
# larger.
set part   [lindex $argv 0]
set period [lindex $argv 1]
set top    [lindex $argv 2]
# Trailing args split two ways: "g:NAME=VALUE" is a generic, anything else is a
# source file.  Generics are needed because the interesting question about C's
# register file is how it SCALES, and a scaling question cannot be asked with a
# hardcoded size.
set files {}
set generics {}
set tag $top
foreach a [lrange $argv 3 end] {
  if {[regexp {^g:([A-Za-z_][A-Za-z0-9_]*)=(.+)$} $a -> n v]} {
    lappend generics -generic $n=$v
    append tag "_${n}$v"
  } else {
    lappend files $a
  }
}

set_param general.maxThreads 4
set here   [file normalize [file dirname [info script]]]
set outdir [file normalize [file join $here ooc_micro]]
file mkdir $outdir

create_project -in_memory -part $part
foreach f $files { read_vhdl -vhdl2008 [file normalize $f] }

# Constrained before synthesis: an unconstrained run gives Vivado licence to
# leave the multiply flat and report an Fmax that no placement would meet.
set xdc [file join $outdir clk_${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

# No -max_dsp: natural inference is the question.  Forcing DSP would confirm
# the budget by construction, which is the failure mode this whole exercise is
# meant to avoid.
synth_design -mode out_of_context -top $top -part $part {*}$generics

# opt_design because unoptimised synthesis leaves cones that a real build would
# collapse, and the XOR-fold digest in these skeletons is exactly the kind of
# structure that survives synthesis and dies in opt.  Report after, not before.
opt_design -quiet

set rpt [file join $outdir util_${tag}.rpt]
report_utilization -file $rpt
report_timing_summary -delay_type max -max_paths 3 \
  -file [file join $outdir timing_${tag}.rpt]

set dsp 0; set lut 0; set ff 0; set bram 0.0; set carry 0
set fh [open $rpt r]
foreach line [split [read $fh] \n] {
  if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}            { set dsp $v }
  if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}      { set lut $v }
  if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}   { set ff $v }
  if {[regexp {^\| Block RAM Tile\s+\|\s+([0-9.]+)} $line -> v]}  { set bram $v }
  if {[regexp {^\| CARRY8\s+\|\s+([0-9]+)} $line -> v]}           { set carry $v }
}
close $fh

# The census.  USE_MULT distinguishes a real multiplier from a DSP recruited as
# a wide adder; A/BREG and PREG say how deeply it pipelined, which is what makes
# a reported Fmax believable or not.
set cells [get_cells -hier -filter {REF_NAME == DSP48E2}]
set cens [open [file join $outdir dsp_${tag}.txt] w]
puts $cens [format "%-52s %-10s %-6s %-6s %-6s %s" NAME USE_MULT AREG BREG PREG ALUMODE]
foreach c $cells {
  puts $cens [format "%-52s %-10s %-6s %-6s %-6s %s" \
    [get_property NAME $c] \
    [get_property USE_MULT $c] \
    [get_property AREG $c] [get_property BREG $c] [get_property PREG $c] \
    [get_property ALUMODE $c]]
}
close $cens

set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set fmax [expr {1000.0 / ($period - $wns)}]

puts [format "MICRO %s  DSP=%s (census %s)  LUT=%s  FF=%s  CARRY8=%s  BRAM=%s  WNS=%.3f  Fmax=%.1f MHz" \
      $tag $dsp [llength $cells] $lut $ff $carry $bram $wns $fmax]
if {$dsp != [llength $cells]} {
  puts "WARNING: utilisation DSP=$dsp disagrees with the census [llength $cells] -- do not trust either"
}
puts "MICRO_DONE"
close_project
