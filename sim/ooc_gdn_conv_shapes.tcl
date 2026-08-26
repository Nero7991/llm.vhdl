# gdn_conv at the REAL per-card segment shapes (q 1024, k 1024, v 3072), not
# the CH=256 toy the 16-DSP row was first measured at.  Checks two things the
# small shape cannot show: that the DSP count is set by LANES alone, and what
# the segment accumulator actually costs in BRAM.
set part xcvu33p-fsvh2104-2L-e
set csv [open "gdn_conv_shapes.csv" w]
puts $csv "ch_max,lanes,dsp,lut,bram,fmax_mhz"
foreach cfg {{256 4} {1024 4} {3072 4} {3072 8}} {
  set CH [lindex $cfg 0]; set L [lindex $cfg 1]
  puts "======== gdn_conv CH_MAX=$CH LANES=$L ========"
  create_project -in_memory -part $part
  read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/util_pkg.vhd
  read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv.vhd
  synth_design -mode out_of_context -top gdn_conv -part $part \
               -generic CH_MAX=$CH -generic LANES=$L
  create_clock -period 2.5 -name clk [get_ports clk]
  set u [report_utilization -return_string]
  set nl 0; set nd 0; set nb 0
  regexp {CLB LUTs\S*\s*\|\s*(\d+)} $u -> nl
  regexp {DSPs\s*\|\s*(\d+)} $u -> nd
  regexp {Block RAM Tile\s*\|\s*([0-9.]+)} $u -> nb
  set rpt [report_timing_summary -no_header -return_string]
  set wns 0.0
  if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
  set fmax [expr {1000.0/(2.5-$wns)}]
  puts "SHAPE CH_MAX=$CH LANES=$L dsp=$nd lut=$nl bram=$nb fmax=$fmax"
  puts $csv "$CH,$L,$nd,$nl,$nb,$fmax"
  flush $csv
  close_project
}
close $csv
puts "CONV_SHAPES_DONE"
