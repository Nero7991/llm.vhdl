# Measure real JTAG-AXI write/read bandwidth over CoE/XVC, for the Jungle Cat
# weight-load feasibility question.  Prereq (main session / Oren, NOT a
# subagent -- this opens the JTAG path):
#   1. carrier powered, modules seated, on the LAN
#   2. sqrl_bridge programming jc_axiprobe.bit with XVC enabled on port 2542
#      (5th arg), e.g.  sqrl_bridge C<bmc_ip> <path>/jc_axiprobe.bit skip 2542
#   3. hw_server running (localhost:3121)
# Then:  vivado -mode batch -source measure_jtag_axi.tcl
# open_hw_target over the CoE bridge is flaky (bringup doc S6): retried up to 8x.
# Every burst length is checked by readback, so a number is only printed for
# writes that actually landed.
set ADDR c0000000       ;# axi_bram_ctrl Mem0, 8 KB
set lens {1 4 16 64 256}
set iters 200
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set a 1} {$a <= 8} {incr a} {
  if {![catch {open_hw_target -xvc_url localhost:2542} err]} { set ok 1; break }
  puts "AXIBW_OPEN_RETRY $a: $err"
  catch {close_hw_target}
  after 3000
}
if {!$ok} { puts "AXIBW_NO_TARGET"; exit 1 }
puts "AXIBW_DEVICES [get_hw_devices]"
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev
set axi [lindex [get_hw_axis] 0]
if {$axi eq ""} { puts "AXIBW_NO_HW_AXI (is jc_axiprobe.bit loaded?)"; exit 1 }
puts "JTAG_AXI measuring on $axi ($dev), BRAM @ 0x$ADDR"
foreach L $lens {
  set bytes [expr {$L*4}]
  # distinct pattern per length so a stale BRAM cannot pass the readback
  set word [format %08X [expr {0x5A000000 + $L}]]
  set data [string repeat $word $L]
  if {[catch {
    delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet {wtx rtx}]
    create_hw_axi_txn wtx $axi -address $ADDR -data $data -len $L -type write
    create_hw_axi_txn rtx $axi -address $ADDR -len $L -type read
    set t0 [clock microseconds]
    for {set i 0} {$i < $iters} {incr i} { run_hw_axi -quiet [get_hw_axi_txns wtx] }
    set t1 [clock microseconds]
    for {set i 0} {$i < $iters} {incr i} { run_hw_axi -quiet [get_hw_axi_txns rtx] }
    set t2 [clock microseconds]
    set rd [string toupper [get_property DATA [get_hw_axi_txns rtx]]]
    set match [expr {$rd eq $data}]
    set wbw [expr {double($iters*$bytes)/(($t1-$t0)/1e6)}]
    set rbw [expr {double($iters*$bytes)/(($t2-$t1)/1e6)}]
    puts [format "AXIBW len=%-4d burst=%-5dB iters=%d  write %.1f KB/s  read %.1f KB/s  readback=%s  -> 7GB write in %.1f h" \
          $L $bytes $iters [expr {$wbw/1024.0}] [expr {$rbw/1024.0}] [expr {$match ? "OK" : "MISMATCH"}] [expr {7.0e9/$wbw/3600.0}]]
    if {!$match} { puts "AXIBW_MISMATCH len=$L got [string range $rd 0 31]..." }
  } err]} { puts "AXIBW len=$L FAILED/HANG: $err"; break }
}
puts "AXIBW_DONE"
