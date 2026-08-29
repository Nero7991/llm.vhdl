# Verify the raised VCCINT holds, and that the fabric and I2C still work at it.
source [file join [file dirname [info script]] target_select.tcl]
source [file join [file dirname [info script]] axi_select.tcl]

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d
# The JTAG-AXI master is IDENTIFIED, not assumed.  `get_hw_axis hw_axi_1` was
# right on the two-master bitstreams and is WRONG on the engine bitstream --
# MEASURED, tcl/pcieep_jtag.log: the AXI-Lite master there is hw_axi_2 and
# hw_axi_1 returns the decode sentinel 0xDEC0DEE3.  The failure is SILENT: an
# unmapped read returns a sentinel rather than erroring.  See tcl/axi_select.tcl.
set ax [fk33_axi_pick axil]
proc wr {a v} { global ax
    create_hw_axi_txn -quiet -force t $ax -address $a -data $v -type write
    run_hw_axi -quiet [get_hw_axi_txns t] }
proc rdreg {a} { global ax
    create_hw_axi_txn -quiet -force t $ax -address $a -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1] }
proc lines {s d} { wr 0x00009004 [format 0x%08x [expr {($s?1:0)|($d?2:0)}]] }
proc sda_in {} { return [expr {([rdreg 0x00009000] >> 1) & 1}] }
proc i2c_start {} { lines 1 1; lines 1 0; lines 0 0 }
proc i2c_stop  {} { lines 0 0; lines 1 0; lines 1 1 }
proc i2c_wbit {b} { lines 0 $b; lines 1 $b; lines 0 $b }
proc i2c_rbit {}  { lines 0 1; lines 1 1; set v [sda_in]; lines 0 1; return $v }
proc i2c_wbyte {v} { for {set i 7} {$i>=0} {incr i -1} { i2c_wbit [expr {($v>>$i)&1}] }; return [i2c_rbit] }
proc i2c_rbyte {a} { set v 0
    for {set i 0} {$i<8} {incr i} { set v [expr {($v<<1)|[i2c_rbit]}] }
    i2c_wbit [expr {$a?0:1}]; return $v }
proc pot_read {a} { i2c_start
    if {[i2c_wbyte [expr {($a<<1)|1}]] != 0} { i2c_stop; return -1 }
    set hi [i2c_rbyte 1]; set lo [i2c_rbyte 0]; i2c_stop
    return [expr {($hi<<8)|$lo}] }

wr 0x00009000 0x00000000
lines 1 1
puts "=== stability over repeated samples ==="
for {set i 1} {$i <= 8} {incr i} {
    puts [format "  %d  wiper=%3d  VCCINT=%.4f V  VCCBRAM=%.4f V  die=%.1f C" $i \
        [pot_read 0x2c] [expr {[rdreg 3404]*3.0/65536.0}] \
        [expr {[rdreg 3418]*3.0/65536.0}] [expr {[rdreg 3400]*507.6/65536.0-279.43}]]
}
puts "=== the other two rheostats, unchanged (plain read, no writes) ==="
foreach a {0x2d 0x2e} { puts [format "  0x%02x wiper=%d" $a [pot_read $a]] }
set flag [rdreg 34fc]
puts [format "=== FLAG_REG = 0x%04x   VCCINT alarm=%d  bit4=%d ===" \
    $flag [expr {($flag>>1)&1}] [expr {($flag>>4)&1}]]
puts "=== fabric still alive: walking the LEDs on GPIO ch2 ==="
foreach v {0x01 0x02 0x04 0x08 0x10 0x20 0x40} { wr 0x00009008 $v; after 250 }
wr 0x00009008 0x00000040
puts "  LED walk complete, restored"
lines 1 1
close_hw_target
puts "VERIFY_DONE"
