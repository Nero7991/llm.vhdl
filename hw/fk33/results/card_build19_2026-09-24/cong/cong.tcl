# Congestion location on three PLACED checkpoints of the same card design family.
# build18 = control (routed), b19d1 = build 19 default draw (21,809 conflicts), b19r = rescue (264).
set out /mnt/storage/fk33_builds/build19/cong
foreach {tag dcp} {
  b18  /mnt/storage/fk33_builds/KEEP_build18_dcp/bd_wrapper_placed.dcp
  b19d1 /mnt/storage/fk33_builds/KEEP_build19_dcp/draw1/bd_wrapper_placed.dcp
  b19r /mnt/storage/fk33_builds/build19/root/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_placed.dcp
} {
  open_checkpoint $dcp
  report_design_analysis -congestion -file $out/cong_$tag.rpt
  set gwh [get_cells -hier -quiet -filter {NAME =~ *gvr.gwh* && IS_PRIMITIVE}]
  set gnm [get_cells -hier -quiet -filter {NAME =~ *gnm* && IS_PRIMITIVE}]
  set cr {}
  foreach c $gwh { set s [get_sites -quiet -of_objects $c]; if {[llength $s]} { lappend cr [get_property CLOCK_REGION $s] } }
  set h [dict create]; foreach r $cr { dict incr h $r }
  puts "CONG_NORMFETCH $tag gwh=[llength $gwh] gnm=[llength $gnm] regions=$h"
  close_design
  puts "CONG_DONE $tag"
}
puts "CONG_ALL_DONE"
