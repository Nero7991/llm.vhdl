# Build 19 rescue #2: continue routing the rescue's own routed checkpoint (264 conflicts).
# Same netlist, same placement: only the router's work varies.  Sentinels are ^RR_ and
# never echoed by this file's own puts lines being matched (anchor the waiter).
set d /mnt/storage/fk33_builds/build19/reroute
open_checkpoint /mnt/storage/fk33_builds/KEEP_build19_dcp/bd_wrapper_routed_rescue.dcp
proc nbad {} {
  set c [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == CONFLICTS}]]
  set u [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == UNROUTED}]]
  set p [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == PARTIAL}]]
  return [list $c $u $p]
}
puts "RR_BEFORE conflicts/unrouted/partial=[nbad]"
route_design -directive AggressiveExplore
set b [nbad]
puts "RR_AFTER conflicts/unrouted/partial=$b"
report_route_status -file $d/route_status_rr.rpt
report_timing_summary -max_paths 10 -file $d/timing_summary_rr.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts [format "RR_TIMING WNS=%s WHS=%s" $wns $whs]
write_checkpoint -force $d/bd_wrapper_routed_rr.dcp
if {[lindex $b 0] != 0 || [lindex $b 1] != 0 || [lindex $b 2] != 0} { puts "RR_FAIL route not clean: $b"; exit 1 }
report_utilization -file $d/utilization_routed_rr.rpt
report_drc -file $d/drc_rr.rpt
write_bitstream -force $d/bd_wrapper.bit
puts "RR_BUILD_DONE [file size $d/bd_wrapper.bit]"
