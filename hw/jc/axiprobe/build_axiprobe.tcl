# -tclargs <build_dir> [part]
set here [file normalize [file dirname [info script]]]
set bd   [lindex $argv 0]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-1-e"}]
create_project -force axiprobe $bd -part $part
source $here/jc_axiprobe_bd.tcl
generate_target all [get_files axiprobe.bd]
make_wrapper -files [get_files axiprobe.bd] -top -import
add_files $here/jc_axiprobe.vhd
add_files -fileset constrs_1 $here/jc_axiprobe.xdc
set_property top jc_axiprobe [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "AXIPROBE_SYNTH_FAIL"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "AXIPROBE_IMPL_FAIL"; exit 1 }
set bit [glob -nocomplain $bd/axiprobe.runs/impl_1/*.bit]
set ltx [glob -nocomplain $bd/axiprobe.runs/impl_1/*.ltx]
puts "AXIPROBE_BIT $bit"
puts "AXIPROBE_LTX $ltx"
puts "AXIPROBE_DONE"
