set part xcvu33p-fsvh2104-2L-e
# (a) plain OOC synthesis, no constraint at all
create_project -in_memory -part $part
read_vhdl -vhdl2008 /mnt/storage/compose4/bufgprobe/probe.vhd
synth_design -mode out_of_context -top c4_bufg_probe -part $part
puts "PROBE_A_BUFG [llength [get_cells -quiet -hier -filter {REF_NAME =~ BUFG*}]]"
puts "PROBE_A_NETTYPE [get_property TYPE [get_nets -quiet -of [get_ports clk]]]"
close_project
# (b) the same, with an out-of-context XDC asking for a BUFG on the clock port
set x /mnt/storage/compose4/bufgprobe/bufg.xdc
set fh [open $x w]
puts $fh "set_property CLOCK_BUFFER_TYPE BUFG \[get_ports clk\]"
close $fh
create_project -in_memory -part $part
read_vhdl -vhdl2008 /mnt/storage/compose4/bufgprobe/probe.vhd
read_xdc -mode out_of_context $x
synth_design -mode out_of_context -top c4_bufg_probe -part $part
puts "PROBE_B_BUFG [llength [get_cells -quiet -hier -filter {REF_NAME =~ BUFG*}]]"
puts "PROBE_DONE2"
