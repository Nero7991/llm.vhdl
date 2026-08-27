# Place-and-route an OOC micro-skeleton and report the timing that ROUTING gives.
#
#   vivado -mode batch -source sim/ooc_micro_pnr.tcl -tclargs <part> <period_ns> <top> [g:N=V]... <vhd>...
#
# WHY THIS IS NOT ooc_micro.tcl WITH EXTRA STEPS.  ooc_micro.tcl stops after
# opt_design, and for a single lane that is fine: the question there was how many
# DSPs a lane infers, which synthesis settles.  It is NOT fine for a fanout
# question.  Post-synthesis timing uses ESTIMATED interconnect; a high-fanout net
# has no more estimated delay than a point-to-point one, because nothing has been
# placed and there is no distance to be far apart over.  Run a 64-lane array to
# synthesis only and it will report roughly the same Fmax as one lane, and the
# conclusion "broadcast is free" would be an artifact of stopping too early.
#
# So this goes all the way to route_design.  The number that comes out the far
# end is the one that has actually paid for the wire.
set part   [lindex $argv 0]
set period [lindex $argv 1]
set top    [lindex $argv 2]

set files {}
set generics {}
set tag $top
# Optional "volt=<V>": analyse timing at a VCCINT other than the part default.
# Exists for the same reason as in ooc_core_sweep.tcl, and matters MORE here:
# every post-route Fmax this harness has produced is a 0.85 V number, while the
# FK33 runs at 0.717 V, and one measured pair on matvec_core put that gap at
# 16.5%.  Applied AFTER route_design so the reported number is a pure voltage
# derate of one placed-and-routed netlist.
set volt -1
foreach a [lrange $argv 3 end] {
  if {[regexp {^volt=([0-9.]+)$} $a -> v]} {
    set volt $v
    append tag "_v$v"
    continue
  }
  if {[regexp {^g:([A-Za-z_][A-Za-z0-9_]*)=(.+)$} $a -> n v]} {
    lappend generics -generic $n=$v
    append tag "_${n}$v"
  } else {
    lappend files $a
  }
}

set_param general.maxThreads 8
set here   [file normalize [file dirname [info script]]]
set outdir [file normalize [file join $here ooc_micro]]
file mkdir $outdir

create_project -in_memory -part $part
foreach f $files { read_vhdl -vhdl2008 [file normalize $f] }

set xdc [file join $outdir pnr_${tag}.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
# Without a source-clock delay OOC timing cannot estimate skew and says so every
# run.  Set it explicitly so the warning is answered rather than ignored, and so
# every point in the sweep is judged against the same clocking assumption.
puts $fh "set_property HD.CLK_SRC BUFGCTRL_X0Y0 \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

synth_design -mode out_of_context -top $top -part $part {*}$generics
opt_design -quiet
place_design
phys_opt_design -quiet
route_design

if {$volt > 0} {
  set_operating_conditions -voltage [list VCCINT $volt]
  puts "  operating conditions: VCCINT = $volt V"
}

set rpt [file join $outdir pnrutil_${tag}.rpt]
report_utilization -file $rpt
report_timing_summary -delay_type max -max_paths 10 \
  -file [file join $outdir pnrtiming_${tag}.rpt]

set dsp 0; set lut 0; set ff 0; set carry 0
set fh [open $rpt r]
foreach line [split [read $fh] \n] {
  if {[regexp {^\| DSPs\s+\|\s+([0-9]+)} $line -> v]}           { set dsp $v }
  if {[regexp {^\| CLB LUTs\*?\s+\|\s+([0-9]+)} $line -> v]}     { set lut $v }
  if {[regexp {^\| CLB Registers\s+\|\s+([0-9]+)} $line -> v]}  { set ff $v }
  if {[regexp {^\| CARRY8\s+\|\s+([0-9]+)} $line -> v]}          { set carry $v }
}
close $fh

# The fanout census.  A bare Fmax says the design got slower but not WHY, and
# "why" is the entire question -- the prediction under test is that control nets
# (fanout = LANES) bite and data nets (fanout = 4) do not.  Dump the widest nets
# with their post-route delay so the answer is attributable to a named net
# rather than inferred from a trend.
set fh [open [file join $outdir fanout_${tag}.txt] w]
puts $fh [format "%-8s %s" FANOUT NET]
set nets {}
foreach n [get_nets -hier -filter {TYPE == SIGNAL}] {
  lappend nets [list [get_property FLAT_PIN_COUNT $n] [get_property NAME $n]]
}
foreach e [lrange [lsort -integer -decreasing -index 0 $nets] 0 24] {
  puts $fh [format "%-8s %s" [lindex $e 0] [lindex $e 1]]
}
close $fh

set path [get_timing_paths -delay_type max -max_paths 1]
set wns  [get_property SLACK $path]
set fmax [expr {1000.0 / ($period - $wns)}]
set fh [open [file join $outdir critpath_${tag}.txt] w]
puts $fh "startpoint: [get_property STARTPOINT_PIN $path]"
puts $fh "endpoint:   [get_property ENDPOINT_PIN $path]"
puts $fh "slack:      $wns"
puts $fh "logic dly:  [get_property DATAPATH_LOGIC_DELAY $path]"
puts $fh "net   dly:  [get_property DATAPATH_NET_DELAY $path]"
close $fh

set csvpath [file join $outdir pnr_results.csv]
set fresh [expr {![file exists $csvpath] || [file size $csvpath] == 0}]
set csv [open $csvpath a]
if {$fresh} { puts $csv "tag,part,period_ns,dsp,lut,ff,carry8,wns_ns,fmax_mhz,logic_ns,net_ns" }
puts $csv "$tag,$part,$period,$dsp,$lut,$ff,$carry,$wns,$fmax,[get_property DATAPATH_LOGIC_DELAY $path],[get_property DATAPATH_NET_DELAY $path]"
close $csv

puts [format "PNR %s  DSP=%s LUT=%s FF=%s CARRY8=%s  WNS=%.3f  Fmax=%.1f MHz  (logic %.3f / net %.3f ns)" \
      $tag $dsp $lut $ff $carry $wns $fmax \
      [get_property DATAPATH_LOGIC_DELAY $path] [get_property DATAPATH_NET_DELAY $path]]
puts "PNR_DONE"
close_project
