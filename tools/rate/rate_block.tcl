# tools/rate/rate_block.tcl -- rate ONE shell: OOC synth, then (mode route) opt/place/phys_opt/route.
#   -tclargs <part> <outdir> <period_ns> <clock,clock> <filelist> <route|pregate>
lassign $argv part outdir period clocks filelist mode
set_param general.maxThreads 8
set fh [open $filelist]; set files [split [string trim [read $fh]] "\n"]; close $fh
foreach f $files { read_vhdl -vhdl2008 $f }
set x [file join $outdir clocks.xdc]; set fh [open $x w]
foreach c [split $clocks ,] { puts $fh "create_clock -name $c -period $period \[get_ports $c\]" }
close $fh
read_xdc -mode out_of_context $x
synth_design -top rate_shell -part $part -mode out_of_context -flatten_hierarchy rebuilt
report_design_analysis -logic_level_distribution -file [file join $outdir levels_synth.rpt]
set wp [get_timing_paths -setup -max_paths 1]
puts "RATE_SYNTH_LEVELS [get_property LOGIC_LEVELS $wp] WNS [get_property SLACK $wp]"
if {$mode eq "pregate"} { puts "RATE_DONE pregate"; exit 0 }
opt_design; place_design; phys_opt_design; route_design
report_timing_summary -max_paths 20 -file [file join $outdir timing_routed.rpt]
report_utilization -file [file join $outdir util_routed.rpt]
report_pulse_width -file [file join $outdir pulse_width.rpt]
report_design_analysis -logic_level_distribution -file [file join $outdir levels_routed.rpt]
set wp [get_timing_paths -setup -max_paths 1]
set wh [get_timing_paths -hold -max_paths 1]
set unr [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == CONFLICTS}]]
puts "RATE_ROUTE WNS [get_property SLACK $wp] WHS [get_property SLACK $wh] LEVELS [get_property LOGIC_LEVELS $wp] UNROUTED $unr START [get_property STARTPOINT_PIN $wp] END [get_property ENDPOINT_PIN $wp]"
set u [report_utilization -return_string]
proc used {u row} { if {[regexp "\\| $row +\\| +(\[0-9.\]+)" $u -> v]} { return $v }; return -1 }
puts "RATE_UTIL LUT [used $u {CLB LUTs}] FF [used $u {CLB Registers}] BRAM [used $u {Block RAM Tile}] URAM [used $u URAM] DSP [used $u DSPs]"
write_checkpoint -force [file join $outdir routed.dcp]
puts "RATE_DONE route"
