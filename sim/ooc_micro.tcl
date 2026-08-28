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
#
# "volt=<V>" is a third form.  It re-analyses the SAME synthesized netlist at a
# VCCINT other than the part default, exactly as ooc_core_sweep.tcl does and for
# exactly the same reason: every Fmax this harness has ever printed is Vivado's
# default 0.85 V analysis of a -1/-2/-2L part, while the FK33 is set by hand to
# 0.717 V (docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md).  Applied
# AFTER synth_design and opt_design and with no placement, so the pair of
# numbers this prints is a pure voltage derate of one netlist rather than a
# comparison of two differently-optimised builds.  Contrast ooc_micro_pnr.tcl,
# which must put the conditions in the XDC before create_project and therefore
# lets the tools optimise FOR the low voltage -- a different question.
set files {}
set generics {}
set volt -1
set tag $top
foreach a [lrange $argv 3 end] {
  if {[regexp {^volt=([0-9.]+)$} $a -> v]} {
    set volt $v
    append tag "_v$v"
  } elseif {[regexp {^g:([A-Za-z_][A-Za-z0-9_]*)=(.+)$} $a -> n v]} {
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

# Every row goes to one CSV so a sweep is a file rather than a hand transcription
# out of console scrollback.  The `volt` column carries the literal string
# "default" for the part's own analysis point, because writing 0.85 there would
# be an assumption about what the default IS, and the whole point of the
# exercise is that that assumption was never checked.
set csvpath [file join $outdir volt_results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csvfh [open $csvpath a]
if {$fresh} {
  puts $csvfh "tag,top,part_opened,part_analysed,period_ns,volt,dsp,lut,ff,bram,carry8,wns_ns,fmax_mhz"
}
proc part_now {} { return [get_property PART [current_project]] }
puts $csvfh "$tag,$top,$part,[part_now],$period,default,$dsp,$lut,$ff,$bram,$carry,$wns,$fmax"

if {$volt > 0} {
  # Dump the conditions on both sides.  The reason is a real hazard, not
  # thoroughness: in a place-and-route flow the same constraint makes Vivado
  # RELOAD the part as the -2LV variant ([Vivado 12-4441]), which is a speed
  # grade change and not a derate.  If it also happens here then the "pure
  # derate" claim above is false and the two harnesses are not comparable.  So
  # record what the part is called before and after, and report the conditions
  # themselves, rather than trusting that nothing moved.
  set fh [open [file join $outdir opcond_${tag}_before.rpt] w]
  puts $fh [report_operating_conditions -return_string]
  close $fh
  set part_before [part_now]

  set_operating_conditions -voltage [list VCCINT $volt]

  set fh [open [file join $outdir opcond_${tag}_after.rpt] w]
  puts $fh [report_operating_conditions -return_string]
  close $fh
  set part_after [part_now]
  # MEASUREMENT TRAP, hit 2026-08-27: this property does NOT move.  It still
  # reads xcvu33p-fsvh2104-2L-e after the constraint, while the log one line
  # earlier says `[Vivado 12-4441] ... require changing to the -2LV variant`
  # followed by `[Device 21-403] Loading part xcvu33p-fsvh2104-2LV-e`.  The
  # device under the timing engine changed and the project property did not.
  # Believe the log, not this line.
  puts "VOLTCHECK project PART property before=$part_before after=$part_after"
  puts "VOLTCHECK the authority is the log: grep for 12-4441 and 21-403"

  report_timing_summary -delay_type max -max_paths 3 \
    -file [file join $outdir timing_${tag}_v${volt}.rpt]
  set wns_v  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
  set fmax_v [expr {1000.0 / ($period - $wns_v)}]
  puts $csvfh "$tag,$top,$part,$part_after,$period,$volt,$dsp,$lut,$ff,$bram,$carry,$wns_v,$fmax_v"
  puts [format "MICROVOLT %s  VCCINT=%s  WNS=%.3f  Fmax=%.1f MHz  (derate %.2f%% from %.1f MHz)" \
        $tag $volt $wns_v $fmax_v [expr {100.0*($fmax-$fmax_v)/$fmax}] $fmax]
}
close $csvfh
puts "MICRO_DONE"
close_project
