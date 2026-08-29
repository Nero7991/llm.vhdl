# Identify the six FK33 I2C devices.
#
# Two different safety postures, deliberately:
#
#   RHEOSTATS 0x2c/0x2d/0x2e -- PLAIN READS ONLY, never a pointer write.  On
#     AD5245-class parts the byte after the address is an INSTRUCTION byte
#     (carrying reset and shutdown bits), not a register pointer, so the usual
#     "write pointer, repeated start, read" idiom could command the part.  Vary
#     the READ LENGTH instead: that is free information and cannot write.
#
#   TEMP SENSORS 0x18/0x19/0x1f -- pointer writes are safe here.  These sit in
#     the MCP9808 / JC42.4 address range, where the byte after the address is
#     unambiguously a register pointer and registers 0x06/0x07 are the
#     Manufacturer and Device ID.  Reading those identifies the part outright.

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
proc hexlist {b} { set o {}; foreach x $b { lappend o [format %02x $x] }; return [join $o " "] }
proc plain_read {a n} {
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) | 1}]] != 0} { i2c_stop; return {} }
    set out {}
    for {set i 0} {$i < $n} {incr i} { lappend out [i2c_rbyte [expr {$i < $n-1}]] }
    i2c_stop
    return $out
}
proc reg_read {a reg n} {
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) & 0xfe}]] != 0} { i2c_stop; return {} }
    i2c_wbyte $reg
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) | 1}]] != 0} { i2c_stop; return {} }
    set out {}
    for {set i 0} {$i < $n} {incr i} { lappend out [i2c_rbyte [expr {$i < $n-1}]] }
    i2c_stop
    return $out
}

wr $DAT 0x00000000
lines 1 1

puts "=== rheostats: plain reads of varying length (no writes at all) ==="
puts "    if 1 byte returns 0x80 then the leading 0x00 in the 2-byte read was"
puts "    my artefact, and 0x80 is AD5245's documented power-on midscale preset."
foreach a {0x2c 0x2d 0x2e} {
    foreach n {1 2 3 4} {
        set b [plain_read $a $n]
        puts [format "  0x%02x  read %d -> %s" $a $n [expr {$b eq "" ? "NO RESPONSE" : [hexlist $b]}]]
    }
    puts ""
}

puts "=== temperature sensors: Manufacturer and Device ID (pointer writes safe here) ==="
foreach a {0x18 0x19 0x1f} {
    set cap  [reg_read $a 0x00 2]
    set man  [reg_read $a 0x06 2]
    set dev  [reg_read $a 0x07 2]
    set ta   [reg_read $a 0x05 2]
    set line [format "  0x%02x  cap=%s  manuf=%s  device=%s  T_A=%s" $a \
        [hexlist $cap] [hexlist $man] [hexlist $dev] [hexlist $ta]]
    if {[llength $ta] == 2} {
        # JC42.4 / MCP9808 ambient: 13-bit two's complement, 0.0625 C/LSB,
        # with flag bits in the top 3 of the MSB.
        set raw [expr {(([lindex $ta 0] & 0x1f) << 8) | [lindex $ta 1]}]
        if {$raw & 0x1000} { set raw [expr {$raw - 0x2000}] }
        append line [format "  -> %.2f C" [expr {$raw * 0.0625}]]
    }
    puts $line
}
lines 1 1
close_hw_target
puts "IDENT_DONE"
