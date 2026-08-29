# Diagnostic: the sweep moved ZERO beats with ZERO cycles, which is not a
# timing-marginality signature (that gives slightly-wrong counts) but a
# "never started" one.  This isolates WHICH of the three possible causes it is:
#   1. the AXI-Lite WRITE path does not reach the generator (reads demonstrably
#      work -- the ID register came back correct);
#   2. writes land but the generator never arms;
#   3. it arms but HBM never asserts ARREADY, in which case arstall climbs.
# The control registers are write-only, which is itself the reason this needs a
# trick rather than a readback.
source [file join [file dirname [info script]] target_select.tcl]
source [file join [file dirname [info script]] axi_select.tcl]

set TG 0x00010000
proc rd {addr} {
    set t [create_hw_axi_txn -force rdtxn $::FK33_AX \
             -address [format %08x $addr] -type read -len 1]
    run_hw_axi -quiet $t
    set v [lindex [report_hw_axi_txn -t d4 $t] 1]
    return [expr {$v & 0xffffffff}]
}
proc wr {addr val} {
    set t [create_hw_axi_txn -force wrtxn $::FK33_AX \
             -address [format %08x $addr] -type write \
             -data [format %08x $val] -len 1]
    run_hw_axi -quiet $t
}
open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -quiet [lindex [get_hw_devices] 0]
set ::FK33_AX [fk33_axi_pick axil]

# THIS SCRIPT IS FOR THE hbmbw BITSTREAM AND NOTHING ELSE, and it used to say so
# nowhere.  $TG = 0x00010000 is build_fk33_hbmbw.tcl's traffic generator.  In
# the fk33_pcieep family that same address is fk33_scratch, an 8 KB BRAM
# (MEASURED, --bd-only FK33_MAP: SEG_fk33_scratch_Mem0 at 0x00010000, range
# 0x2000), so every register below would read and WRITE a scratch RAM and the
# whole run would report plausible-looking nonsense.  Refuse instead.
set diag_id [rd $TG]
puts "ID     [format 0x%08X $diag_id]"
if {$diag_id != 0x48424D31} {
    puts "HBMDIAG REFUSING: the traffic generator's ID at 0x[format %08X $TG] reads"
    puts [format "                  0x%08X, expected 0x48424D31.  This is not the hbmbw" $diag_id]
    puts "                  bitstream.  On the endpoint/engine bitstream that address is"
    puts "                  fk33_scratch and there is no traffic generator to diagnose;"
    puts "                  use tcl/pcieep_jtag.tcl there instead."
    puts "HBMDIAG_DONE"
    close_hw_target
    exit 0
}
puts "NPORT  [rd [expr {$TG+12}]]"
puts "TEMP   [format 0x%08X [rd [expr {$TG+16}]]]"
puts "TRIP   [format 0x%08X [rd [expr {$TG+20}]]]"

# --- TEST 1: does a WRITE land at all?
# Program the soft temperature ceiling to 1.  The stacks read ~28, so if the
# write reaches the generator the watchdog must trip and TRIP bit3 must set.
# This uses only readable state, so it needs no rebuild.
puts ""
puts "TEST 1: writing TEMP_LIMIT=1 (stacks read ~28, so this MUST trip)"
wr [expr {$TG+0}] 2
wr [expr {$TG+20}] 1
after 100
set trip [rd [expr {$TG+20}]]
puts "  TRIP now [format 0x%08X $trip]  (bit3 = programmed ceiling)"
if {$trip & 0x8} {
    puts "  WRITES REACH THE GENERATOR."
} else {
    puts "  WRITES DO NOT REACH THE GENERATOR -- the AXI-Lite write path is the fault,"
    puts "  not the traffic generator.  Reads work, so it is the W/AW channel or the"
    puts "  slave's write decode, not the address map."
}
wr [expr {$TG+0}] 2
wr [expr {$TG+20}] 0

# --- TEST 2: arm one port and watch arstall, which distinguishes
# "never armed" (arstall stays 0) from "armed but HBM never accepts" (climbs).
puts ""
puts "TEST 2: arming port 0 for a short run"
wr [expr {$TG+0}] 2
wr [expr {$TG+4}] 1
wr [expr {$TG+8}] 15
wr [expr {$TG+12}] 64
wr [expr {$TG+16}] 16
wr [expr {$TG+0}] 1
for {set i 0} {$i < 6} {incr i} {
    after 50
    puts [format "  t%d busy=%d cycles=%-10d beats=%-8d arstall=%-10d retired=%d" \
        $i [expr {[rd [expr {$TG+8}]] & 1}] [rd [expr {$TG+4}]] \
        [rd [expr {$TG+1024}]] [rd [expr {$TG+2048}]] [rd [expr {$TG+3072}]]]
}
wr [expr {$TG+0}] 0
puts ""
puts "READING: arstall climbing with beats 0 means the generator IS issuing and"
puts "HBM is not accepting -- most likely the memory controller has not finished"
puts "its initialisation, which nothing in this design waits for or reports."
puts "arstall 0 AND cycles 0 means it never armed, so the fault is upstream."
puts "HBMDIAG_DONE"
