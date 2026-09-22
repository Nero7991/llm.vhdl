# Build 15 implementation DRAW 2 (2026-09-22): same synth checkpoint, placer directive AltSpreadLogic_high (Vivado's congestion-spreading placer) in place of ExtraNetDelay_high; strategy, route and phys_opt directives as the rescue recipe.  Draw 1 (ExtraNetDelay_high) failed with 8,932 nets in congestion at 11.75 % Tiles.
# checkpoint with the recipe that rescued card_swg_2026-09-20 from the same
# checkpoint (13.45 -> 9.33 % Tiles, routed, WNS +0.050).  No synthesis, so
# the netlist is identical by construction and this is a one-variable
# implementation control.  Sentinels are line-anchored ^REIMPL_ and never
# echoed by this file (the log echoes the SCRIPT, so a waiter must anchor).
set root /mnt/storage/fk33_builds/build15/root/fk33_pcieep
open_project $root/fk33_pcieep.xpr
set st [get_property STATUS [get_runs synth_1]]
puts "REIMPL_SYNTH_STATUS $st"
if {![string match "synth_design Complete!" $st]} { error "synth_1 is not complete: $st" }
reset_run impl_1
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AlternateCLBRouting [get_runs impl_1]
puts "REIMPL_STRATEGY [get_property strategy [get_runs impl_1]] route=[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] place=[get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]] physopt=[get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE [get_runs impl_1]]"
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
set pr [get_property PROGRESS [get_runs impl_1]]
puts "REIMPL_RUNDONE impl_1 $pr status=$st"
if {![string match "write_bitstream Complete!" $st]} { error "REIMPL_FAIL impl_1 at $pr status $st" }
open_run impl_1
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts [format "REIMPL_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
set rs [report_route_status -return_string]
puts $rs
report_route_status -file $root/fk33_pcieep.runs/impl_1/bd_wrapper_route_status_reimpl2.rpt
report_utilization -file $root/fk33_pcieep.runs/impl_1/bd_wrapper_utilization_routed_reimpl2.rpt
puts "REIMPL_BUILD_DONE"
