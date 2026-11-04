# hw/jc/census/build_sysmon_probe.tcl -- vivado -mode batch -source build_sysmon_probe.tcl
#   -tclargs <build_dir> [part] [SM1_CFG (1 = b1, 2 = v2)]
# Builds jc_sysmon_probe.vhd (one SYSMONE4 per SLR, GTY rails on VUSER0..3, DRP
# read loop into a VIO).  Default part is -1, which loads on any grade.
# Prints SMP_DONE <bit> or SMP_FAIL <why>.  Build only: no hardware commands.
set bd   [lindex $argv 0]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-1-e"}]
set sm1  [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]
set here [file dirname [file normalize [info script]]]
create_project -force smp $bd -part $part
add_files $here/jc_sysmon_probe.vhd
set_property file_type {VHDL 2008} [get_files jc_sysmon_probe.vhd]
add_files -fileset constrs_1 $here/jc_sysmon_probe.xdc
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_sm
set cfg [list CONFIG.C_NUM_PROBE_IN 21 CONFIG.C_NUM_PROBE_OUT 0 CONFIG.C_EN_PROBE_IN_ACTIVITY 0]
foreach i {0 1 2 3 4 5 6 7 9 10 11 12 13 14 15 16 17 19} { lappend cfg CONFIG.C_PROBE_IN${i}_WIDTH 16 }
lappend cfg CONFIG.C_PROBE_IN8_WIDTH 32 CONFIG.C_PROBE_IN18_WIDTH 32 CONFIG.C_PROBE_IN20_WIDTH 3
set_property -dict $cfg [get_ips vio_sm]
generate_target all [get_ips vio_sm]
set_property top jc_sysmon_probe [current_fileset]
set_property generic "SM1_CFG=$sm1" [current_fileset]
puts "SMP_SM1_CFG $sm1"
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "SMP_FAIL synth"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit [glob -nocomplain $bd/smp.runs/impl_1/*.bit]
if {$bit eq ""} { puts "SMP_FAIL no bitstream"; exit 1 }
open_run impl_1
report_timing_summary -file $bd/timing.rpt
report_drc -file $bd/drc_routed.rpt
report_methodology -file $bd/methodology.rpt
report_utilization -file $bd/util.rpt
write_debug_probes -force $bd/jc_sysmon_probe.ltx
# census of what the bitstream really contains
set bad 0
foreach c {u_sm0 u_sm1} {
  set cell [get_cells $c]
  set line "SMP_CELL $c ref=[get_property REF_NAME $cell] loc=[get_property LOC $cell] slr=[get_slrs -of_objects $cell]"
  foreach p {INIT_41 INIT_42 INIT_44 INIT_45 INIT_46 INIT_48 SYSMON_VUSER0_BANK SYSMON_VUSER0_MONITOR SYSMON_VUSER1_BANK SYSMON_VUSER1_MONITOR SYSMON_VUSER2_BANK SYSMON_VUSER2_MONITOR SYSMON_VUSER3_BANK SYSMON_VUSER3_MONITOR} {
    append line " $p=[get_property $p $cell]"
  }
  puts $line
  foreach pn {DEN DRDY DCLK} {
    set n [get_nets -quiet -of_objects [get_pins $c/$pn]]
    if {$n eq "" || [llength [get_pins -leaf -of_objects $n]] < 2} { puts "SMP_UNCONNECTED $c/$pn"; incr bad }
  }
}
if {[get_property LOC [get_cells u_sm0]] ne "SYSMONE4_X0Y0" || [get_property LOC [get_cells u_sm1]] ne "SYSMONE4_X0Y1"} { incr bad }
set unrouted [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED}]]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "SMP_WNS $wns WHS $whs unrouted_nets=$unrouted"
if {$bad != 0} { puts "SMP_FAIL census bad=$bad"; exit 1 }
puts "SMP_DONE $bit"
