# Drive the FK33 board LEDs over JTAG-AXI, slowly, for a card that is hard to
# see once installed.  They hang off the SAME axi_iic core whose I2C bus is
# silent (gpo -> led_inv -> board led pins), and the LED balls
# (BB25/BB26/BC25/BD23/BD25/BE26/BF26) sit in the same bank as the I2C balls
# (BB24/BA24) at the same LVCMOS18 standard.  A visible response proves the
# FPGA drives that bank and localises the I2C fault to the bus or the devices.
#
# led_inv is a NOT gate, so GPO bit set -> led pin low -> LED lit (active low).
#   bit0..3 = four green LEDs,  bit4 = RGB red, bit5 = RGB green, bit6 = RGB blue
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d
set ax [get_hw_axis hw_axi_1]
proc gpo {ax v} {
    create_hw_axi_txn -quiet -force t $ax -address 00009124 -data [format 0x%08x $v] -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}

puts "STAGE 1: everything OFF then everything ON, 3 s each, 3 times"
for {set i 1} {$i <= 3} {incr i} {
    gpo $ax 0x00; puts "   ALL OFF"; after 3000
    gpo $ax 0x7f; puts "   ALL ON";  after 3000
}

puts "STAGE 2: RGB colour cycle, 3 s each, 3 times (colour change is the clearest tell)"
for {set i 1} {$i <= 3} {incr i} {
    gpo $ax 0x10; puts "   RGB = RED";   after 3000
    gpo $ax 0x20; puts "   RGB = GREEN"; after 3000
    gpo $ax 0x40; puts "   RGB = BLUE";  after 3000
}

puts "STAGE 3: the four green LEDs one at a time, 2.5 s each, twice"
for {set i 1} {$i <= 2} {incr i} {
    for {set b 0} {$b < 4} {incr b} {
        gpo $ax [expr {1 << $b}]; puts "   GREEN [expr {$b+1}] of 4"; after 2500
    }
}

gpo $ax 0x40
puts "restored default GPO 0x40 (RGB blue)"
close_hw_target
puts "BLINK_DONE"
