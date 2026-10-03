# Measure real JTAG-AXI write bandwidth over CoE/XVC, for the Jungle Cat
# weight-load feasibility question.  Prereq (main session / Oren, NOT a
# subagent -- this opens the JTAG path):
#   1. carrier powered, modules seated, on the LAN
#   2. sqrl_bridge programming jc_axiprobe.bit with XVC enabled on port 2542
#      (5th arg), e.g.  sqrl_bridge C<bmc_ip> <path>/jc_axiprobe.bit skip 2542
#   3. hw_server running (localhost:3121)
# Then:  vivado -mode batch -source measure_jtag_axi.tcl
set ADDR c0000000       ;# axi_bram_ctrl Mem0, 8 KB
set lens {1 4 16 64 256}
set iters 200
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url localhost:2542
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev
set axi [lindex [get_hw_axis] 0]
if {$axi eq ""} { puts "AXIBW_NO_HW_AXI (is jc_axiprobe.bit loaded?)"; exit 1 }
puts "JTAG_AXI measuring on $axi, BRAM @ 0x$ADDR"
foreach L $lens {
  set bytes [expr {$L*4}]
  set data [string repeat "A5A5A5A5" $L]
  if {[catch {
    delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet wtx]
    create_hw_axi_txn wtx $axi -address $ADDR -data $data -len $L -type write
    set t0 [clock microseconds]
    for {set i 0} {$i < $iters} {incr i} { run_hw_axi -quiet [get_hw_axi_txns wtx] }
    set t1 [clock microseconds]
    set dt [expr {($t1-$t0)/1e6}]
    set bw [expr {double($iters*$bytes)/$dt}]
    puts [format "AXIBW len=%-4d burst=%-5dB iters=%d %.3fs  %.1f KB/s  -> 7GB in %.1f h" \
          $L $bytes $iters $dt [expr {$bw/1024.0}] [expr {7.0e9/$bw/3600.0}]]
  } err]} { puts "AXIBW len=$L FAILED/HANG: $err"; break }
}
puts "AXIBW_DONE"
