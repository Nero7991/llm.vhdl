# Build 10 apportionment. READ-ONLY: open_checkpoint + report_* + get_* only.
# No write_*, no program, no hardware.
set here "/home/labuser/b10apportion"
open_checkpoint $here/build10_routed_bd_wrapper.dcp
puts "B10AP_OPENED"

# THE REQUIREMENT FIRST.  Never read a WNS without it.
set ck [get_clocks clk_out3_bd_clk_wiz_0_0]
puts "B10AP_CLOCK name=[get_property NAME $ck] period=[get_property PERIOD $ck]"

# Route legality, the authority.
report_route_status -file $here/route_status.rpt
puts "B10AP_ROUTESTATUS_WRITTEN"

# All violating setup paths on the core clock.
set paths [get_timing_paths -setup -max_paths 20000 -nworst 1 \
             -slack_lesser_than 0 -filter {GROUP == clk_out3_bd_clk_wiz_0_0}]
puts "B10AP_NPATHS [llength $paths]"

# Bucket by endpoint scope.  Buckets are named from the MEASURED candidates.
array set cnt {}
array set worst {}
foreach p $paths {
  set ep [get_property ENDPOINT_PIN $p]
  set sp [get_property STARTPOINT_PIN $p]
  set sl [get_property SLACK $p]
  set epn [get_property NAME $ep]
  set spn [get_property NAME $sp]
  if {[regexp {gcr\.gkvaxi\.u_kv} $epn] || [regexp {gcr\.gkvaxi\.u_kv} $spn]} {
    set k "u_kv"
  } elseif {[regexp {cb_addr|cbw_a|cbw_v|cbw_d} $epn] || [regexp {cb_addr|cbw_a|cbw_v|cbw_d} $spn]} {
    set k "codebook_cmd"
  } elseif {[regexp {/core/} $epn] || [regexp {/core/} $spn]} {
    set k "a_core_other"
  } elseif {[regexp {gcr\.u_attn} $epn] || [regexp {gcr\.u_attn} $spn]} {
    set k "c_attn"
  } elseif {[regexp {gb_real} $epn] || [regexp {gb_real} $spn]} {
    set k "b_gdn"
  } else {
    set k "other"
  }
  if {![info exists cnt($k)]} { set cnt($k) 0 ; set worst($k) 0.0 }
  incr cnt($k)
  if {$sl < $worst($k)} { set worst($k) $sl }
}
foreach k [array names cnt] {
  puts [format "B10AP_BUCKET %-14s count=%7d worst=%8.3f" $k $cnt($k) $worst($k)]
}
puts "B10AP_DONE"
