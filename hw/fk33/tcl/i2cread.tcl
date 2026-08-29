# Read the six devices found on the FK33 I2C bus.  STRICTLY READ-ONLY.
#
# Deliberately uses PLAIN reads (START, addr+R, data..., master NAK, STOP) and
# never writes a register pointer.  On many digital potentiometers the byte
# following the address is an INSTRUCTION, not a pointer, so the usual
# "write reg index, repeated start, read" idiom is not safe against an unknown
# part.  A plain read returns the device's current register on every part we
# might plausibly be talking to, and cannot alter a wiper setting.
#
# GPIO_DATA stays pinned at 0 throughout; all edges via GPIO_TRI. Strict
# open-drain, so we can pull low or release, never drive high.

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
proc wr {addr data} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}
proc rdreg {addr} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
}
set TRI 0x00009004
set DAT 0x00009000
proc lines {scl sda} { wr $::TRI [format 0x%08x [expr {($scl ? 1 : 0) | ($sda ? 2 : 0)}]] }
proc sda_in {} { return [expr {([rdreg $::DAT] >> 1) & 1}] }
proc i2c_start {} { lines 1 1; lines 1 0; lines 0 0 }
proc i2c_stop  {} { lines 0 0; lines 1 0; lines 1 1 }
proc i2c_wbit {b} { lines 0 $b; lines 1 $b; lines 0 $b }
proc i2c_rbit {}  { lines 0 1; lines 1 1; set v [sda_in]; lines 0 1; return $v }
proc i2c_wbyte {v} {
    for {set i 7} {$i >= 0} {incr i -1} { i2c_wbit [expr {($v >> $i) & 1}] }
    return [i2c_rbit]
}
proc i2c_rbyte {ack} {
    set v 0
    for {set i 0} {$i < 8} {incr i} { set v [expr {($v << 1) | [i2c_rbit]}] }
    i2c_wbit [expr {$ack ? 0 : 1}]
    return $v
}
proc plain_read {a n} {
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) | 1}]] != 0} { i2c_stop; return {} }
    set out {}
    for {set i 0} {$i < $n} {incr i} { lappend out [i2c_rbyte [expr {$i < $n-1}]] }
    i2c_stop
    return $out
}

wr $DAT 0x00000000
lines 1 1

puts "=== rheostats: three of them, matching the three documented rails ==="
foreach a {0x2c 0x2d 0x2e} {
    set b [plain_read $a 2]
    if {$b eq ""} { puts [format "  0x%02x  no response" $a]; continue }
    set hex {}
    foreach x $b { lappend hex [format 0x%02x $x] }
    puts [format "  0x%02x  bytes = %s   (byte0 dec=%d, 0x%02x)" \
        $a [join $hex " "] [lindex $b 0] [lindex $b 0]]
}

puts "=== temperature sensors: SQRL's fk33_regulator_temps list ==="
foreach a {0x18 0x19 0x1f} {
    set b [plain_read $a 2]
    if {$b eq ""} { puts [format "  0x%02x  no response" $a]; continue }
    set msb [lindex $b 0]
    set lsb [lindex $b 1]
    # LM75-family: 11-bit left-justified two's complement, 0.125 C/LSB.
    set raw [expr {(($msb << 8) | $lsb) >> 5}]
    if {$raw > 1023} { set raw [expr {$raw - 2048}] }
    puts [format "  0x%02x  bytes = 0x%02x 0x%02x   LM75-style = %.3f C   (msb alone = %d C)" \
        $a $msb $lsb [expr {$raw * 0.125}] $msb]
}
lines 1 1
close_hw_target
puts "READ_DONE"
