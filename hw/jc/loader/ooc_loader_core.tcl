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
jcl_cdc "" $ACLK_P $TCK_P

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
# each named crossing, so the report shows the bound that covers it
set fh [open $out/cdc_paths.rpt w]; close $fh
foreach {f t} {sync/snap_reg* sync/st_r_reg* sync/pub_reg sync/tgl_s1_reg
               sync/ack_reg sync/ack_s1_reg fifo/wp_g_reg* fifo/wp_g_s1_reg*
               fifo/rp_g_reg* fifo/rp_g_s1_reg*} {
  report_timing -from [get_cells -hier -filter "NAME =~ \"$f\""] \
    -to [get_cells -hier -filter "NAME =~ \"$t\""] -max_paths 1 -append -file $out/cdc_paths.rpt
}
report_timing -to [get_pins -hier -filter {NAME =~ "trst_s1_reg/D"}] -append -file $out/cdc_paths.rpt
report_timing -to [get_pins -hier -filter {NAME =~ "trip_s1_reg/D"}] -append -file $out/cdc_paths.rpt

set rs [report_route_status -return_string]
if {[regexp {routing errors\s*:\s*(\d+)} $rs -> nerr] && $nerr == 0} {
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
