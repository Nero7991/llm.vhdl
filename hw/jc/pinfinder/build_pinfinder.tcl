# hw/jc/pinfinder/build_pinfinder.tcl -- vivado -mode batch -source
#   build_pinfinder.tcl -tclargs <build_dir> <A|B> [part]
#
# Synthesis + implementation only (no hardware access of any kind: no
# program_hw_devices, no open_hw_target, nothing in this script touches a
# cable). Builds one of the two pin-finder bitstreams: variant A drives the
# 11 outputs at 1..11 kHz, variant B at 12..22 kHz, same order, so a net
# shared between two slots reads two different frequencies instead of one
# that could be either side. See pinfinder_top.vhd for the pin order and
# hw/jc/pinfinder/README.md for the resolved table.
set bd      [lindex $argv 0]
set variant [lindex $argv 1]
set part    [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xcvu35p-fsvh2104-2L-e"}]
set here    [file dirname [file normalize [info script]]]

if {$variant ne "A" && $variant ne "B"} {
  puts "PINFINDER_FAIL bad variant '$variant' (want A or B)"
  exit 1
}

create_project -force pinfinder_$variant $bd -part $part
add_files $here/pinfinder_top.vhd
set_property file_type {VHDL 2008} [get_files pinfinder_top.vhd]
add_files -fileset constrs_1 $here/pinfinder.xdc
set_property top pinfinder_top [current_fileset]

# Divisor generics: period = 2*DIVn cycles of the 200 MHz clock, so
# frequency = 100_000_000 / DIVn Hz. Order matches pinfinder_top.vhd's
# gen_sq(0..10) -> out_g10_p, out_g10_n, out_f13_p, out_f13_n, LED_A, LED_B,
# LED_C, LED_D, LED_RGB_R, LED_RGB_G, LED_RGB_B.
if {$variant eq "A"} {
  set gen {DIV0=100000 DIV1=50000 DIV2=33333 DIV3=25000 DIV4=20000 DIV5=16667 \
           DIV6=14286 DIV7=12500 DIV8=11111 DIV9=10000 DIV10=9091}
} else {
  set gen {DIV0=8333 DIV1=7692 DIV2=7143 DIV3=6667 DIV4=6250 DIV5=5882 \
           DIV6=5556 DIV7=5263 DIV8=5000 DIV9=4762 DIV10=4545}
}
set_property generic $gen [current_fileset]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "PINFINDER_FAIL synth_$variant"
  exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "PINFINDER_FAIL impl_$variant"
  exit 1
}

set bit [glob -nocomplain $bd/pinfinder_$variant.runs/impl_1/*.bit]
if {$bit eq ""} {
  puts "PINFINDER_FAIL no_bitstream_$variant"
  exit 1
}

open_run impl_1
report_utilization -file $bd/utilization_$variant.rpt
report_timing_summary -file $bd/timing_summary_$variant.rpt
report_drc -file $bd/drc_$variant.rpt
report_io -file $bd/report_io_$variant.rpt

# Anchored check: every port this design drives lands on the pin the table
# says it should, read back from the PLACED design, not the XDC text.
set expect {
  out_g10_p G10   out_g10_n F10
  out_f13_p F13   out_f13_n F12
  LED_A     K10   LED_B     K9
  LED_C     J9    LED_D     J10
  LED_RGB_R K11   LED_RGB_G L12
  LED_RGB_B L11
  sysclk_clk_p BC26 sysclk_clk_n BC27
}
set pin_fail 0
foreach {port want} $expect {
  set got [get_property PACKAGE_PIN [get_ports $port]]
  if {$got ne $want} {
    puts "PINFINDER_PIN_MISMATCH $port want=$want got=$got"
    set pin_fail 1
  } else {
    puts "PINFINDER_PIN_OK $port $got"
  }
}
if {$pin_fail} {
  puts "PINFINDER_FAIL pin_mismatch_$variant"
  exit 1
}

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "PINFINDER_WNS_$variant $wns"

# write_bitstream already ran as part of impl_1 (-to_step write_bitstream);
# this sentinel prints only once that run reported 100% and the .bit file
# above was found on disk, i.e. only after write_bitstream returned.
puts "PINFINDER_BITSTREAM_DONE $variant $bit"
