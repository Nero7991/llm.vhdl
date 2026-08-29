# Characterise the FK33's I2C balls BB24 (scl) / BA24 (sda) as raw GPIO.
#
# SAFETY RULE, enforced structurally below: GPIO_DATA is written ONCE, to zero,
# and never again.  Every state change is made through GPIO_TRI alone.  The pins
# are therefore strict open-drain -- we can only ever pull LOW or release, never
# drive HIGH.  This matters because we do not know whether another controller
# owns that bus; driving a line high against a device pulling it low is the one
# move here that could do real damage.
#
#   0x9000  GPIO_DATA   ch1, bit0 = BB24 (scl), bit1 = BA24 (sda)
#   0x9004  GPIO_TRI    ch1, 1 = released/input, 0 = driven
#   0x9008  GPIO2_DATA  ch2, 7 LEDs via led_inv (active low)

source [file join [file dirname [info script]] target_select.tcl]
source [file join [file dirname [info script]] axi_select.tcl]

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d

proc r {ax addr} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
}
proc w {ax addr data} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}
# The JTAG-AXI master is IDENTIFIED, not assumed.  `get_hw_axis hw_axi_1` was
# right on the two-master bitstreams and is WRONG on the engine bitstream --
# MEASURED, tcl/pcieep_jtag.log: the AXI-Lite master there is hw_axi_2 and
# hw_axi_1 returns the decode sentinel 0xDEC0DEE3.  The failure is SILENT: an
# unmapped read returns a sentinel rather than erroring.  See tcl/axi_select.tcl.
set ax [fk33_axi_pick axil]

proc bits {v} { return [format "scl(bit0)=%d sda(bit1)=%d" [expr {$v & 1}] [expr {($v >> 1) & 1}]] }

# Prove this is the probe bitstream and not the old first-light one: the LEDs
# now hang off GPIO channel 2, so a visible change confirms the swap took.
puts "=== bitstream identity check (LEDs now on GPIO ch2) ==="
puts "  GPIO2_DATA initial = [r $ax 00009008]"
w $ax 00009008 0x0000000f
after 800
w $ax 00009008 0x00000040
puts "  drove LEDs via 0x9008, restored 0x40"

puts "=== channel 1 reset state (must be released) ==="
set tri0 [r $ax 00009004]
puts [format "  GPIO_TRI  = 0x%02x   %s" $tri0 \
    [expr {($tri0 & 3) == 3 ? "both released, as designed" : "UNEXPECTED: a pin is being driven"}]]

# Pin the data register at 0 for the whole run.  Never written again.
w $ax 00009000 0x00000000
puts "  GPIO_DATA pinned to 0x0 for the remainder of this run"

puts ""
puts "=== THE MEASUREMENT: both pins released, what do they read? ==="
puts "    HIGH on both  -> a powered pull-up exists; that bus is real and the"
puts "                     devices are elsewhere or at other addresses."
puts "    LOW or mixed  -> those balls are not a live I2C bus on this board,"
puts "                     and SQRL's 0x2C/0x18/0x19/0x1F never applied here."
w $ax 00009004 0x00000003
for {set i 1} {$i <= 5} {incr i} {
    set v [r $ax 00009000]
    puts [format "  sample %d  DATA=0x%02x   %s" $i $v [bits $v]]
}

puts ""
puts "=== can we pull each line low, and is there a short between them? ==="
foreach {tri label} {2 {drive scl(bit0) LOW, sda released}
                     1 {drive sda(bit1) LOW, scl released}
                     0 {drive BOTH low}
                     3 {release both again}} {
    w $ax 00009004 [format 0x%08x $tri]
    set v [r $ax 00009000]
    puts [format "  TRI=0x%x  %-32s -> DATA=0x%02x  %s" $tri $label $v [bits $v]]
}

puts ""
puts "=== recovery: after releasing, does the line return high? ==="
puts "    a prompt return to high is an active pull-up;  staying low means the"
puts "    line was merely holding charge and is floating, i.e. no pull-up."
w $ax 00009004 0x00000000
puts [format "  both driven low   DATA=0x%02x" [r $ax 00009000]]
w $ax 00009004 0x00000003
for {set i 1} {$i <= 4} {incr i} {
    puts [format "  released, read %d  DATA=0x%02x   %s" $i [r $ax 00009000] [bits [r $ax 00009000]]]
}

# Leave the bus untouched.
w $ax 00009004 0x00000003
puts "  left with both pins RELEASED"
close_hw_target
puts "PROBE_DONE"
