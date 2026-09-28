# hw/jc/census/build_census.tcl -- vivado -mode batch -source build_census.tcl
#   -tclargs <build_dir> [part]
# Speed grade of the Jungle Cat is UNKNOWN (docs/fpga-hardware-recon.md), so the
# default is -1, which loads on any grade.
set bd   [lindex $argv 0]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-1-e"}]
set here [file dirname [file normalize [info script]]]
create_project -force census $bd -part $part
add_files $here/jc_census.vhd
set_property file_type {VHDL 2008} [get_files jc_census.vhd]
add_files -fileset constrs_1 $here/jc_census_hi.xdc
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_census
set_property -dict [list CONFIG.C_NUM_PROBE_IN 15 CONFIG.C_NUM_PROBE_OUT 0 \
  CONFIG.C_PROBE_IN0_WIDTH 32 CONFIG.C_PROBE_IN1_WIDTH 32 CONFIG.C_PROBE_IN2_WIDTH 32 \
  CONFIG.C_PROBE_IN3_WIDTH 32 CONFIG.C_PROBE_IN4_WIDTH 32 CONFIG.C_PROBE_IN5_WIDTH 32 \
  CONFIG.C_PROBE_IN6_WIDTH 32 CONFIG.C_PROBE_IN7_WIDTH 32 CONFIG.C_PROBE_IN8_WIDTH 32 \
  CONFIG.C_PROBE_IN9_WIDTH 32 CONFIG.C_PROBE_IN10_WIDTH 32 CONFIG.C_PROBE_IN11_WIDTH 32 \
  CONFIG.C_PROBE_IN12_WIDTH 32 CONFIG.C_PROBE_IN13_WIDTH 16 CONFIG.C_PROBE_IN14_WIDTH 2] \
  [get_ips vio_census]
generate_target all [get_ips vio_census]
set_property top jc_census [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "CENSUS_FAIL synth"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit [glob -nocomplain $bd/census.runs/impl_1/*.bit]
if {$bit eq ""} { puts "CENSUS_FAIL no bitstream"; exit 1 }
open_run impl_1
report_timing_summary -file $bd/timing.rpt
set cw [llength [get_clocks -quiet ref*]]
if {$cw != 10} { puts "CENSUS_FAIL refclk clocks $cw of 10"; exit 1 }
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "CENSUS_WNS $wns"
puts "CENSUS_DONE $bit"
