# JTAG-side check of the PCIe endpoint bitstream.
#
# What this isolates, and in which direction the evidence runs:
#
# In this bitstream the ENTIRE AXI fabric -- including both JTAG-AXI masters --
# is clocked by xdma/axi_aclk and reset by xdma/axi_aresetn, both of which are
# derived from the PCIe reference clock and released only once the link is up.
# So:
#
#   every read below SUCCEEDS  ->  conclusive.  Reference clock present, PCIe
#                                  user clock running, link up, AXI-Lite path
#                                  and DMA-side HBM path both alive.  If the
#                                  host still cannot see the card, the fault is
#                                  in enumeration or the driver, not the card.
#
#   reads hang or return junk  ->  AMBIGUOUS, and deliberately so.  It could be
#                                  no reference clock, an untrained link, or a
#                                  bitstream that did not configure.  Separate
#                                  them with LED 6 (link status, no instrument)
#                                  and with the ROOT PORT's LnkSta on the host,
#                                  which reports link state even when nothing
#                                  enumerates.  See host/fk33_pcie_check.sh.
#
# Nothing here writes to the board's I2C bus, and the HBM write is confined to
# a 4 KB scratch page at the very top of the address map.

puts "PCIEEP_CHECK begin"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d
puts "IDCODE [get_property REGISTER.IDCODE [current_hw_device]]"
puts "PART   [get_property PART [current_hw_device]]"

# hw_axi_1 is jtag_hbm (64-bit, reaches HBM), hw_axi_2 is jtag_axil.
# Both are named by the block design; if either is missing the bitstream that
# is loaded is not this one.
set axis [get_hw_axis]
puts "AXI_MASTERS $axis"
if {[llength $axis] < 2} {
    puts "PCIEEP_FAIL: expected 2 JTAG-AXI masters, found [llength $axis]."
    puts "             The device is not running the endpoint bitstream."
    puts "PCIEEP_DONE"
    close_hw_target
    exit 0
}
set hbm  [lindex $axis 0]
set axil [lindex $axis 1]

proc rd {ax addr} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
}
proc wr {ax addr data} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}

# ---- 1. AXI-Lite.  The cheapest possible proof that the PCIe user clock runs.
# SYSMON is read-only and has a known-good cross-check: the same numbers came
# out of tcl/telemetry.tcl over the probe bitstream, so a plausible reading here
# is not just "a register responded", it is "the same silicon says the same
# thing through a different clock domain".
if {[catch {
    set traw [rd $axil 3400]
    set vraw [rd $axil 3404]
} err]} {
    puts "PCIEEP_FAIL: AXI-Lite read errored: $err"
    puts "             xdma/axi_aclk is not running or axi_aresetn is held."
    puts "             Link is almost certainly down.  Check LED 6 and the"
    puts "             host root port's LnkSta before touching the bitstream."
    puts "PCIEEP_DONE"
    close_hw_target
    exit 0
}
set temp [expr {$traw * 507.6 / 65536.0 - 279.43}]
set vcc  [expr {$vraw * 3.0 / 65536.0}]
puts [format "SYSMON die=%.1f C  VCCINT=%.4f V  (raw 0x%x 0x%x)" $temp $vcc $traw $vraw]

# The VCCINT reading is the second half of the bring-up order check: if it says
# ~0.678 V the pot was never stepped, or the board was power-cycled after it
# was, and this die is running below its characterised floor.
if {$vcc < 0.698} {
    puts [format "PCIEEP_WARN: VCCINT %.4f V is BELOW the 0.698 V -2L floor." $vcc]
    puts "             Re-run ./pcieep.sh without --no-vccint, or raise it from"
    puts "             the host with host/fk33ctl.py vccint."
} elseif {$vcc > 0.760} {
    puts [format "PCIEEP_WARN: VCCINT %.4f V is above the 0.760 V ceiling used" $vcc]
    puts "             by tcl/vccint_step.tcl.  Investigate before loading anything."
} else {
    puts [format "VCCINT_OK %.4f V" $vcc]
}
if {$temp < 5.0 || $temp > 95.0} {
    puts [format "PCIEEP_WARN: die temperature %.1f C is implausible; SYSMON may" $temp]
    puts "             be returning a stale or unclocked value."
}

# ---- 2. GPIO.  Proves the AXI-Lite path reaches a WRITABLE peripheral, which
# SYSMON cannot show.  Read-only: TRI resets to all-ones (everything released)
# and this reads it back without touching either the data or the tri register,
# so the board's I2C bus is never driven.
set tri [rd $axil 9004]
set dat [rd $axil 9000]
puts [format "GPIO tri=0x%08x data=0x%08x  (tri must be 0x3 or wider all-ones at reset)" $tri $dat]

# ---- 3. HBM through the JTAG master.  Isolates the memory path from the DMA
# path: if this works and host DMA does not, the fault is in XDMA or the driver,
# not in HBM or the smartconnect.  Scratch page is the last 4 KB of the 8 GB map.
set pat {DEADBEEF 0BADC0DE 5A5A5A5A A5A5A5A5}
set ok 1
for {set i 0} {$i < 4} {incr i} {
    set a [format %X [expr {0x1FFFFF000 + $i * 4}]]
    wr $hbm $a [lindex $pat $i]
}
for {set i 0} {$i < 4} {incr i} {
    set a [format %X [expr {0x1FFFFF000 + $i * 4}]]
    set got [rd $hbm $a]
    set want [lindex $pat $i]
    if {[string toupper $got] ne [string toupper $want]} {
        puts "HBM_MISMATCH at 0x$a: wrote $want read $got"
        set ok 0
    }
}
if {$ok} {
    puts "HBM_OK scratch page 0x1FFFFF000 writes and reads back"
    puts "       (this address is in SAXI_16's half, so both stacks are mapped)"
} else {
    puts "PCIEEP_WARN: HBM readback mismatched.  HBM init may not have completed;"
    puts "             tcl/hbmdiag.tcl is the instrument for that."
}

puts "PCIEEP_DONE"
close_hw_target
