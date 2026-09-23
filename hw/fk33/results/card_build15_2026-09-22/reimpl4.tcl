# Build 15 DRAW 3b (2026-09-22): POST-ROUTE phys_opt_design on draw 3's ROUTED checkpoint.  Draw 3 (default recipe)
# routed legally (Phase 8 clean, 0 overlaps) but ended at WNS -0.610 / TNS -92.4 ns at 75 MHz; the project flow has no
# post-route phys_opt step (only the pre-route one), so this is the one cheap lever left on a legal route before a
# re-place.  One netlist, one route, one added step: a one-variable control against draw 3.  Sentinels ^REIMPL4_.
set root /mnt/storage/fk33_builds/build15/root/fk33_pcieep
set out  /mnt/storage/fk33_builds/build15/draw3b
file mkdir $out
open_checkpoint $root/fk33_pcieep.runs/impl_1/bd_wrapper_routed.dcp
puts "REIMPL4_OPENED [get_property TOP [current_design]]"
set wns0 [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts [format "REIMPL4_WNS_BEFORE %.3f" $wns0]
report_timing -max_paths 300 -slack_lesser_than 0 -path_type summary -file $out/failing_paths_before.rpt
phys_opt_design -directive AggressiveExplore
report_route_status -return_string
set rs [report_route_status -return_string]
puts $rs
report_route_status -file $out/bd_wrapper_route_status_draw3b.rpt
report_timing_summary -max_paths 20 -file $out/bd_wrapper_timing_summary_draw3b.rpt
set wns1 [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs1 [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts [format "REIMPL4_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns1 $whs1]
write_checkpoint -force $out/bd_wrapper_physopt_post_route.dcp
if {$wns1 >= 0.0 && $whs1 >= 0.0} {
  write_bitstream -force $out/bd_wrapper.bit
  puts "REIMPL4_BITSTREAM $out/bd_wrapper.bit"
} else {
  puts "REIMPL4_NOBIT timing not met"
}
report_utilization -file $out/bd_wrapper_utilization_draw3b.rpt
puts "REIMPL4_BUILD_DONE"
