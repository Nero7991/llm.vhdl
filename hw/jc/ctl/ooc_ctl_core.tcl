# hw/jc/ctl/ooc_ctl_core.tcl -- OOC synth + opt + place + phys_opt + route of jc_ctl_core
# (the USER3 control core) at 200 MHz aclk / 27 MHz TCK, with the CDC constraints of
# jc_ctl_timing.tcl. Modelled on hw/jc/loader/ooc_loader_core.tcl. No hardware access:
# synthesis, implementation and reports only. Written by plan Task 4; run by the controller
# (one Vivado per box, under run_capped.sh; the loader core's measured peak was ~4.4 GB).
#
# Usage: vivado -mode batch -source ooc_ctl_core.tcl -tclargs <repo> <outdir> [part]
# Part: xcvu35p-fsvh2104-2L-e (the plan's part; the loader OOC used -1-e).
#
# Sentinels (anchored):
#   ^JCCTL_OOC_ROUTE routing_errors 0      (else ^JCCTL_OOC_ROUTE_FAIL)
#   ^JCCTL_OOC_WNS <ns>  ^JCCTL_OOC_WHS <ns>
#   ^JCCTL_OOC_CDC unexpected <n>          every aclk<->TCK endpoint that is not a named
#                                          synchroniser; the gate requires 0
#   ^JCCTL_OOC_RRAM <n>                    response RAM primitives (block RAM only)
#   ^JCCTL_OOC_ASYNC_REG <cell> <value>    the core's own synchroniser flops
#   ^JCCTL_OOC_CROSS <name> slack <s> requirement <r>
#   ^JCCTL_OOC_DONE
#   ^JCCTL_SYNC_OK / ^JCCTL_SYNC_DRIVER     synchroniser structure (fix round 1)
# A Tcl error anywhere ends the run WITHOUT ^JCCTL_OOC_DONE: a constraint matching nothing
# (JCCTL_CONSTRAINT_EMPTY), a response RAM that is not a block RAM or whose ports are not
# write-on-aclk / read-on-TCK (JCCTL_RRAM), a synchroniser without ASYNC_REG, with a first
# stage feeding anything but its second stage, or a consumer not on the second stage
# (JCCTL_SYNC).
set repo [file normalize [lindex $argv 0]]
set out  [file normalize [lindex $argv 1]]
set part [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xcvu35p-fsvh2104-2L-e"}]
set ACLK_P 5.000
set TCK_P  37.037
file mkdir $out
puts "JCCTL_OOC_PART $part"
create_project -in_memory -part $part
foreach f {rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/jc_ctl_pkg.vhd rtl/async_fifo.vhd
           rtl/jc_ctl_frame_core.vhd rtl/jc_ctl_exec.vhd rtl/jc_status_sync.vhd
           rtl/jc_ctl_core.vhd} {
  read_vhdl -vhdl2008 $repo/$f
}
synth_design -top jc_ctl_core -part $part -mode out_of_context -generic TMO_CYC=65536
write_checkpoint -force $out/synth.dcp
report_utilization -file $out/util_synth.rpt
report_utilization -hierarchical -file $out/util_synth_hier.rpt

source $repo/hw/jc/ctl/jc_ctl_timing.tcl
# synchroniser structure on the synthesized netlist (fix round 1): ASYNC_REG on both stages,
# first stage feeds only the second, the executor's ack and reset come from the second
jctl_syncs ""
create_clock -name aclk -period $ACLK_P [get_ports aclk]
create_clock -name tck  -period $TCK_P  [get_ports tck]
set A [get_clocks aclk]
set T [get_clocks tck]
# Harness I/O (OOC only). aclk-domain ports: 1.0 ns outside on each side, standing for the
# interconnect's register and route (-min 0.5 for hold, as the loader's harness).
set a_in  [get_ports -filter {DIRECTION == IN && NAME =~ "m_axi*"}]
set a_out [get_ports -filter {DIRECTION == OUT && NAME =~ "m_axi*"}]
set_input_delay  -clock $A -max 1.000 [concat $a_in [get_ports arst]]
set_input_delay  -clock $A -min 0.500 [concat $a_in [get_ports arst]]
set_output_delay -clock $A -max 1.000 $a_out
set_output_delay -clock $A -min 0.000 $a_out
# TCK-domain ports: the TAP changes SEL/CAPTURE/SHIFT/TDI after the falling edge and the
# core samples on the rising edge; TDO is launched on the rising edge and the TAP samples
# it on the falling edge. Both are half a TCK period, as jctl_tdi bounds TDI in the card.
set t_in [get_ports {sel capture shift tdi}]
set_input_delay  -clock $T -clock_fall -max 0.000 $t_in
set_input_delay  -clock $T -clock_fall -min 0.000 $t_in
set_output_delay -clock $T -clock_fall -max 0.000 [get_ports tdo]
set_output_delay -clock $T -clock_fall -min 0.000 [get_ports tdo]
jctl_cdc "" $A $T $ACLK_P $TCK_P

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
report_ram_utilization -file $out/ram_util.rpt

puts "JCCTL_OOC_RRAM [jctl_rram {} $A $T]"
foreach c [get_cells -quiet {rak_s1_reg rak_s2_reg rst_s1_reg rst_s2_reg}] {
  set v [get_property ASYNC_REG $c]
  puts "JCCTL_OOC_ASYNC_REG [get_property NAME $c] $v"
  if {![string is true -strict $v]} { error "JCCTL_OOC_ASYNC_REG [get_property NAME $c] lost ASYNC_REG after route" }
}
puts "JCCTL_OOC_CDC unexpected [jctl_cdc_audit {} $A $T]"

# each named crossing's DATA path: -from the source clock -to the synchroniser D pins
set fh [open $out/cdc_crossings.rpt w]; close $fh
foreach {name src dst} {snap_to_st_r aclk sync/st_r_reg* pub_to_tgl aclk sync/tgl_s1_reg
                        ack_to_ack_s1 tck sync/ack_s1_reg rsp_ack_tgl tck rak_s1_reg
                        wp_gray tck fifo/wp_g_s1_reg* rp_gray aclk fifo/rp_g_s1_reg*} {
  set pins [get_pins -of_objects [get_cells -hier -filter "NAME =~ \"$dst\""] -filter {REF_PIN_NAME == D}]
  set p [get_timing_paths -setup -from [get_clocks $src] -to $pins -max_paths 1]
  puts "JCCTL_OOC_CROSS $name slack [get_property SLACK $p] requirement [get_property REQUIREMENT $p]"
  report_timing -from [get_clocks $src] -to $pins -max_paths 1 -append -file $out/cdc_crossings.rpt
}

set rs [report_route_status -return_string]
if {[regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr] && $nerr == 0} {
  puts "JCCTL_OOC_ROUTE routing_errors 0"
} else {
  puts "JCCTL_OOC_ROUTE_FAIL"
  puts $rs
}
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCCTL_OOC_WNS $wns"
puts "JCCTL_OOC_WHS $whs"
puts "JCCTL_OOC_DONE"
