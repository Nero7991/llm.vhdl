# TRACK PBLOCK -- phys_opt + route + bitstream from a placed checkpoint.
# NO HARDWARE.  This writes a .bit file; it does not program anything.
# Tag and input checkpoint come from the environment so one script serves all.
set OUT "/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pblock/out"
set TAG $::env(PBLOCK_TAG)
set DCP $::env(PBLOCK_DCP)
set CORE "bd_i/eng/inst/eng/dut/core"
set_param general.maxThreads 6

proc stamp {m} { puts "PBLOCK-STAMP [clock format [clock seconds] -format %H:%M:%S] $m" ; flush stdout }

stamp "route session TAG=$TAG DCP=$DCP"
open_checkpoint $DCP
stamp "opened"

if {[catch {phys_opt_design -directive Explore} e]} { puts "PBLOCK-FATAL physopt: $e" }
stamp "phys_opt done"
catch {write_checkpoint -force $OUT/${TAG}_physopt.dcp}
catch {report_timing_summary -no_detailed_paths -file $OUT/${TAG}_timing_physopt.rpt}
catch {report_clock_interaction -file $OUT/${TAG}_clkint_physopt.rpt}

set route_ok 1
if {[catch {route_design -directive Explore} e]} { puts "PBLOCK-FATAL route: $e" ; set route_ok 0 }
stamp "route_design done ok=$route_ok"
catch {write_checkpoint -force $OUT/${TAG}_routed.dcp}
catch {report_route_status -file $OUT/${TAG}_route_status.rpt}
catch {report_design_analysis -congestion -file $OUT/${TAG}_congestion_routed.rpt}
catch {report_timing_summary -no_detailed_paths -file $OUT/${TAG}_timing_routed.rpt}
catch {report_clock_interaction -file $OUT/${TAG}_clkint_routed.rpt}
catch {report_utilization -file $OUT/${TAG}_util_routed.rpt}

if {$route_ok} {
    set st [get_property STATUS [get_property ROUTE_STATUS [current_design]]]
    stamp "write_bitstream start"
    if {[catch {write_bitstream -force $OUT/${TAG}.bit} e]} {
        puts "PBLOCK-FATAL bitstream: $e"
    } else {
        stamp "write_bitstream done"
    }
}
stamp "ALL DONE $TAG"
