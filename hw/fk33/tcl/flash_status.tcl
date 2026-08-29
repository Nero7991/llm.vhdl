# Cold-boot forensics for a flash-booted FK33.  READ ONLY: this script never
# configures the FPGA, because doing so would destroy the one piece of evidence
# it exists to collect.
#
# THE QUESTION IT ANSWERS
# -----------------------
# After a power cycle with the image in flash, `lspci` either shows the card or
# it does not.  If it does not, there are two completely different causes and
# they present identically as a hidden root port:
#
#   A. the FPGA never finished configuring inside PCIe's window, so there was
#      nothing to train a link with;
#   B. the FPGA configured fine and the link did not train.
#
# This tells them apart WITHOUT the host, because JTAG works either way:
#
#   DONE high + our two JTAG-AXI masters enumerate  ->  case B.  The FPGA read
#       the flash and started the design.  Configuration time is NOT the
#       problem.  Go look at link training, VCCINT, refclk.
#
#   no device / DONE low / no debug cores           ->  case A, or a bad flash
#       image.  Configuration did not complete.  Re-read the config-time budget
#       in docs/debugging/2026-08-28_fk33-spi-flash-boot.md.
#
# VCCINT DOUBLES AS THE POWER-CYCLE LATCH
# ---------------------------------------
# The VCCINT digital pot's wiper is volatile.  It reads 128 after a power cycle
# and retains whatever was set across a warm reboot.  So SYSMON's VCCINT is a
# latch that says which one just happened, with no GPIO and no reconfiguration:
#
#   ~0.678 V   wiper 128.  Genuine cold boot, pot never touched since.
#   ~0.717 V   wiper 68.   Either a warm reboot, or something raised it.
#
# Read through get_hw_sysmons, which reaches SYSMON over the JTAG DRP and needs
# no design clock.  Do NOT use the JTAG-AXI path for this: in the endpoint
# bitstream the whole AXI fabric is dead until the PCIe link is up, and the 28
# failed transactions that produces read like a card fault and are not one.
#
# Markers out: STATUS_BEGIN / STATUS_DONE, plus CFG_* lines.

source [file join [file dirname [info script]] target_select.tcl]

puts "STATUS_BEGIN"

open_hw_manager
connect_hw_server -allow_non_jtag
if {[catch {fk33_open_target} err]} {
    puts "CFG_NO_TARGET: $err"
    puts "  No JTAG target.  The card is unpowered, or the FTDI is held by a"
    puts "  stale hw_server (flash.sh resets the cable before every run)."
    puts "STATUS_DONE"
    exit 1
}

set devs [get_hw_devices]
puts "CFG_DEVICES [llength $devs] : $devs"
if {![llength $devs]} {
    puts "CFG_NO_DEVICE: the JTAG chain is empty."
    puts "STATUS_DONE"
    exit 1
}
set dev [lindex $devs 0]
current_hw_device $dev
# -update_hw_probes false: see the trap in the handoff.  And never ask for
# REGISTER.IDCODE on this device; the property does not exist and aborts.
catch {refresh_hw_device -quiet -update_hw_probes false $dev}
puts "CFG_PART [get_property PART $dev]"

# Dump every configuration register the hardware manager is willing to give,
# guarded one at a time.  Which ones exist varies by device and by whether the
# device is configured, and a missing one is an error, not an empty string.
foreach p [lsort [list_property $dev]] {
    if {![string match "REGISTER.*" $p]} { continue }
    if {[catch {get_property $p $dev} v]} { continue }
    puts "CFG_REG $p = $v"
}

# DONE and the startup state are the headline.  On UltraScale+ they live in
# REGISTER.CONFIG_STATUS; the exact sub-property names differ between releases,
# so match rather than hard-code.
set done unknown
foreach p [list_property $dev] {
    if {[string match -nocase "*CONFIG_STATUS*DONE*" $p]} {
        if {![catch {get_property $p $dev} v]} { set done $v }
    }
}
puts "CFG_DONE $done"

# SYSMON: JTAG DRP, works with the link down and with no design clock.
if {[catch {get_hw_sysmons} sms] || ![llength $sms]} {
    puts "CFG_SYSMON none"
} else {
    set sm [lindex $sms 0]
    catch {refresh_hw_sysmon $sm}
    set t  [expr {[catch {get_property TEMPERATURE $sm} v] ? "?" : $v}]
    set vi [expr {[catch {get_property VCCINT $sm} v] ? "?" : $v}]
    set va [expr {[catch {get_property VCCAUX $sm} v] ? "?" : $v}]
    puts "CFG_SYSMON TEMP=$t VCCINT=$vi VCCAUX=$va"
    if {$vi ne "?"} {
        if {$vi < 0.70} {
            puts "CFG_WIPER cold: VCCINT $vi V is the power-on default (wiper 128)."
            puts "  This WAS a cold boot and nothing has raised VCCINT since."
            puts "  Note 0.678 V is below the 0.698 V floor for the -2L grade,"
            puts "  so the link had to train undervolted."
        } else {
            puts "CFG_WIPER raised: VCCINT $vi V means the wiper is not 128."
            puts "  Either this was a WARM reboot (the wiper survives one), or"
            puts "  something in the design raised it after configuration."
        }
    }
}

# Is OUR design running?  The endpoint bitstream instantiates two JTAG-AXI
# masters, jtag_hbm and jtag_axil.  They enumerate over JTAG even when the AXI
# fabric they drive is dead, because the debug hub sits on a free-running clock.
# Their PRESENCE proves the FPGA configured with this bitstream.  Their
# transactions failing proves nothing (see pcieep_jtag.tcl).
if {[catch {get_hw_axis} axis]} { set axis {} }
puts "CFG_AXI_MASTERS [llength $axis] : $axis"
if {[llength $axis] >= 2} {
    puts "CFG_VERDICT configured: the flash boot WORKED and the design is live."
    puts "  If the host still shows no bridge, configuration time is NOT the"
    puts "  cause.  The remaining suspects are link training and VCCINT."
} else {
    puts "CFG_VERDICT not-configured-or-wrong-image: no design debug cores."
    puts "  Either the flash image is bad, or configuration did not complete."
    puts "  Do NOT conclude 'the endpoint does not train' from this."
}

puts "STATUS_DONE"
