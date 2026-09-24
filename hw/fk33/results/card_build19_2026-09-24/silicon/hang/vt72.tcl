# Build 18 vs build 19: the SAME routed netlist analysed at VCCINT 0.85 V (the
# sign-off) and 0.72 V (what the card runs at, 0.717 V measured). Analysis only.
proc worst {tag v what cells} {
  if {[llength $cells] == 0} { puts "VT $tag v=$v $what NOCELLS"; return }
  foreach kind {setup hold} {
    set p [get_timing_paths -$kind -max_paths 1 -nworst 1 -to $cells]
    if {[llength $p] == 0} { puts "VT $tag v=$v $what $kind NOPATH"; continue }
    puts [format "VT %s v=%s %-8s %-5s slack=%s start=%s end=%s" $tag $v $what $kind \
          [get_property SLACK $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
  }
}
proc analyse {tag dcp out} {
  open_checkpoint $dcp
  foreach {what re} {C {.*u_attn/.*} Ckv {.*u_kv/.*} B {.*u_gdn/.*} Bst {.*u_state/.*} D {.*/u_fetch/.*} grant {.*bcgrant.*} A {.*/eng/dut/core/.*}} {
    set sel($what) [get_cells -quiet -hier -regexp -filter {IS_SEQUENTIAL} $re]
    puts "VT $tag cells $what [llength $sel($what)]"
  }
  foreach v {0.85 0.72} {
    if {$v eq "0.72"} { set_operating_conditions -voltage {VCCINT 0.72} }
    puts "VT $tag v=$v operating [report_operating_conditions -voltage -return_string]"
    set clk [get_clocks clk_out3_bd_clk_wiz_0_0]
    set p [get_timing_paths -setup -max_paths 1 -group $clk]
    puts "VT $tag v=$v core_clk setup slack=[get_property SLACK $p] end=[get_property ENDPOINT_PIN $p]"
    set h [get_timing_paths -hold -max_paths 1 -group $clk]
    puts "VT $tag v=$v core_clk hold  slack=[get_property SLACK $h]"
    foreach what {C Ckv B Bst D grant A} { worst $tag $v $what $sel($what) }
    report_timing -setup -max_paths 20 -group $clk -to $sel(C) -file $out/${tag}_v${v}_C_setup.rpt
    report_timing_summary -max_paths 5 -file $out/${tag}_v${v}_summary.rpt
  }
  close_design
  puts "VT_DONE $tag"
}
analyse b18 /mnt/storage/fk33_builds/KEEP_build18_dcp/bd_wrapper_routed.dcp /mnt/storage/fk33_builds/vt72
analyse b19 /mnt/storage/fk33_builds/KEEP_build19_dcp/bd_wrapper_routed_rr.dcp /mnt/storage/fk33_builds/vt72
puts "VT_ALL_DONE"
