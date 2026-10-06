# hw/jc/loader/ooc_loader_core.tcl -- OOC synth + opt + place + route of jc_loader_core
# at 200 MHz aclk / 27 MHz TCK, with the same CDC constraints as the full build
# (jc_loader_timing.tcl). No hardware access: synthesis, implementation and reports only.
#
# Usage: vivado -mode batch -source ooc_loader_core.tcl -tclargs <repo> <outdir> [part]
#
# PART. Default xcvu35p-fsvh2104-1-e: the part string hw/jc/axiprobe/build_axiprobe.tcl
# built the bitstream that ran on the Jungle Cat (axibw_run_2026-10-05.log), and the
# one the full loader bitstream uses. The module is a -2L device; -1 is the slower
# speed grade, so a -1 timing sign-off is the conservative direction for -2L silicon
# (the plan text said -2-e, which is the faster, optimistic direction).
#
# Sentinels (anchored): JCL_OOC_WNS, JCL_OOC_WHS, JCL_OOC_ROUTE, JCL_OOC_DONE.
set repo [file normalize [lindex $argv 0]]
set out  [file normalize [lindex $argv 1]]
set part [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xcvu35p-fsvh2104-1-e"}]
set DNA_DIV 10
set ACLK_P 5.000
set TCK_P  37.037
file mkdir $out
puts "JCL_OOC_PART $part"
create_project -in_memory -part $part
foreach f {rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd
           rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd
           rtl/jc_dna_reader.vhd rtl/jc_loader_core.vhd} {
  read_vhdl -vhdl2008 $repo/$f
}
synth_design -top jc_loader_core -part $part -mode out_of_context \
  -generic ADDR_W=33 -generic DNA_DIV=$DNA_DIV
write_checkpoint -force $out/synth.dcp
report_utilization -file $out/util_synth.rpt

source $repo/hw/jc/loader/jc_loader_timing.tcl
create_clock -name aclk -period $ACLK_P [get_ports aclk]
create_clock -name tck  -period $TCK_P  [get_ports tck]
jcl_dna_clock "" $DNA_DIV
# the two aclk-domain inputs, so -from [get_clocks aclk] reaches them as it does in the
# full build (where arst is a register and hbm_cat_trip an HBM pin)
# (harness only: -min 0.5 stands for a parent register's clock-to-out plus route; at 0
# the unrouted port produced 195 hold "failures" into dnar/ck_reg and its siblings)
set_input_delay -clock aclk -max 2.000 [get_ports {arst hbm_cat_trip}]
set_input_delay -clock aclk -min 0.500 [get_ports {arst hbm_cat_trip}]
jcl_cdc "" [get_clocks aclk] [get_clocks tck] $ACLK_P $TCK_P

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/routed.dcp

report_route_status -file $out/route_status.rpt
report_utilization -file $out/util_routed.rpt
report_utilization -hierarchical -file $out/util_routed_hier.rpt
report_timing_summary -max_paths 20 -report_unconstrained -file $out/timing_routed.rpt
report_clock_interaction -file $out/clock_interaction.rpt
report_cdc -details -file $out/cdc.rpt
report_cdc -file $out/cdc_summary.rpt
report_exceptions -file $out/exceptions.rpt
report_exceptions -ignored -file $out/exceptions_ignored.rpt
report_bus_skew -file $out/bus_skew.rpt
report_methodology -file $out/methodology.rpt
# each named crossing's DATA path: -from the source clock -to the synchroniser D pins
set fh [open $out/cdc_crossings.rpt w]; close $fh
foreach {name src dst} {snap_to_st_r aclk sync/st_r_reg* pub_to_tgl aclk sync/tgl_s1_reg
                        ack_to_ack_s1 tck sync/ack_s1_reg wp_gray tck fifo/wp_g_s1_reg*
                        rp_gray aclk fifo/rp_g_s1_reg* arst_to_trst aclk trst_s1_reg} {
  set pins [get_pins -of_objects [get_cells -hier -filter "NAME =~ \"$dst\""] -filter {REF_PIN_NAME == D}]
  set p [get_timing_paths -setup -from [get_clocks $src] -to $pins -max_paths 1]
  puts "JCL_OOC_CROSS $name slack [get_property SLACK $p] requirement [get_property REQUIREMENT $p]"
  report_timing -from [get_clocks $src] -to $pins -max_paths 1 -append -file $out/cdc_crossings.rpt
}

set rs [report_route_status -return_string]
if {[regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr] && $nerr == 0} {
  puts "JCL_OOC_ROUTE routing_errors 0"
} else {
  puts "JCL_OOC_ROUTE_FAIL"
  puts $rs
}
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCL_OOC_WNS $wns"
puts "JCL_OOC_WHS $whs"
puts "JCL_OOC_DONE"
