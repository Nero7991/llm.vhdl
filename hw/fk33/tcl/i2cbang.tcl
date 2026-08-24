# Bit-banged I2C on the FK33's BB24/BA24 balls via the probe bitstream's GPIO.
#
# Worth doing instead of trusting axi_iic because every edge is observable here:
# we can see whether SDA actually goes low when a device should be acknowledging,
# and distinguish "nobody answered" from "the line never moved".  Each GPIO
# access is a JTAG-AXI transaction of order a millisecond, so SCL lands around a
# few hundred Hz.  I2C specifies no minimum clock, so that is legal, just slow.
#
# SAFETY: same rule as i2cprobe.tcl.  GPIO_DATA is written once, to zero, and
# never again; every edge is made through GPIO_TRI.  Strict open-drain, so we can
# pull low or release but never drive high against another device.
#
#   bit0 = BB24 = SCL      bit1 = BA24 = SDA
#   TRI bit 1 = released (pulled up by the board)   TRI bit 0 = driven low

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d
set ax [get_hw_axis hw_axi_1]

proc wr {addr data} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}
proc rd {addr} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
}

set TRI 0x00009004
set DAT 0x00009000
# tri value: bit set = released.  scl=bit0, sda=bit1
proc lines {scl sda} { wr $::TRI [format 0x%08x [expr {($scl ? 1 : 0) | ($sda ? 2 : 0)}]] }
proc sda_in {} { return [expr {([rd $::DAT] >> 1) & 1}] }
proc scl_in {} { return [expr {[rd $::DAT] & 1}] }

proc i2c_start {} { lines 1 1; lines 1 0; lines 0 0 }
proc i2c_stop  {} { lines 0 0; lines 1 0; lines 1 1 }
proc i2c_wbit {b} { lines 0 $b; lines 1 $b; lines 0 $b }
proc i2c_rbit {}  { lines 0 1; lines 1 1; set v [sda_in]; lines 0 1; return $v }
proc i2c_wbyte {v} {
    for {set i 7} {$i >= 0} {incr i -1} { i2c_wbit [expr {($v >> $i) & 1}] }
    return [i2c_rbit]   ;# 0 = ACK
}

wr $DAT 0x00000000
lines 1 1
puts "idle state: SCL=[scl_in] SDA=[sda_in]  (both must read 1 before anything else is meaningful)"
if {[scl_in] == 0 || [sda_in] == 0} {
    puts "ABORT: bus is not idle-high, so no scan result would mean anything."
    lines 1 1
    close_hw_target
    exit 0
}

# Clock-stretch sanity: drive SCL low, confirm we can actually pull it, release,
# confirm it comes back.  If this fails the scan below is meaningless.
lines 0 1
puts "drive SCL low  -> reads [scl_in]  (expect 0)"
lines 1 1
puts "release SCL    -> reads [scl_in]  (expect 1)"

set targets {}
if {[info exists ::env(FK33_I2C_FULL)] && $::env(FK33_I2C_FULL) == 1} {
    for {set a 0x08} {$a <= 0x77} {incr a} { lappend targets $a }
} else {
    set targets {0x2c 0x2e 0x18 0x19 0x1f 0x50 0x51 0x70 0x74}
}

# Recover a bus left held by a device mid-transfer: clock SCL up to 9 times
# with SDA released until SDA comes back high, then issue a STOP.  Without this
# the scan is ORDER-DEPENDENT -- an unterminated read from one address makes the
# next several addresses NAK spuriously, which is exactly what the first version
# of this script did.
proc bus_recover {} {
    if {[sda_in] == 1} { return 1 }
    for {set i 0} {$i < 9} {incr i} {
        lines 0 1
        lines 1 1
        if {[sda_in] == 1} { break }
    }
    i2c_stop
    return [sda_in]
}

# A read must be TERMINATED properly: after the address is acknowledged the
# device starts driving a byte, so we clock all 8 bits out, answer with a master
# NAK (SDA released during the 9th clock), and only then STOP.  Issuing STOP
# straight after the address ACK leaves the device holding SDA.
proc i2c_probe_read {a} {
    i2c_start
    set ack [i2c_wbyte [expr {($a << 1) | 1}]]
    if {$ack == 0} {
        for {set i 0} {$i < 8} {incr i} { i2c_rbit }
        i2c_wbit 1
    }
    i2c_stop
    return $ack
}

puts "=== bit-banged scan of [llength $targets] address(es), properly terminated ==="
set found {}
set dirty {}
foreach a $targets {
    if {[bus_recover] == 0} {
        lappend dirty [format 0x%02x $a]
        puts [format "  0x%02x  BUS STUCK before probe, result not trusted" $a]
        continue
    }
    set ack [i2c_probe_read $a]
    if {$ack == 0} {
        lappend found [format 0x%02x $a]
        puts [format "  0x%02x  ACK" $a]
    } elseif {[llength $targets] < 20} {
        puts [format "  0x%02x  nak" $a]
    }
}
if {[llength $dirty]} { puts "BUS_STUCK_AT: $dirty" }
if {[llength $found]} { puts "BANG_FOUND: $found" } else { puts "BANG_FOUND: none" }
lines 1 1
close_hw_target
puts "BANG_DONE"
