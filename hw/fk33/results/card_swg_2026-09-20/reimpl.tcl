# Re-implement impl_1 from the existing synth_1 result with a different strategy.
# No synthesis.  Sentinels are line-anchored ^REIMPL_ and never echoed by this file.
set root /tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/4d84bf97-4b0d-407d-ac40-96158eb597e1/scratchpad/xexp/build8/root/fk33_pcieep
open_project $root/fk33_pcieep.xpr
set st [get_property STATUS [get_runs synth_1]]
puts "REIMPL_SYNTH_STATUS $st"
if {![string match "synth_design Complete!" $st]} { error "synth_1 is not complete: $st" }
reset_run impl_1
set_property strategy Congestion_SpreadLogic_high [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
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
puts "REIMPL_BUILD_DONE"
