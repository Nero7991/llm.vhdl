# potlatch.tcl -- READ the FK33 VCCINT digital-pot wiper.  READ ONLY.
#
# Run through hw/fk33/jtag.sh, with the PROBE bitstream configured:
#     cd hw/fk33 && ./jtag.sh host/potlatch.tcl
# or, preferably, through the wrapper that interprets the result:
#     hw/fk33/host/fk33_powercycle.sh
#
# WHY
# ---
# The MCP45XX-class pot at I2C 0x2c holds VCCINT.  Command 0x00 is the
# VOLATILE wiper: it resets to the factory 128 on a power cycle and SURVIVES a
# warm reboot.  Measured on 2026-08-28:
#
#     after a warm reboot:  wiper=64   VCCINT=0.7203 V
#     after a power cycle:  wiper=128  VCCINT=0.6786 V
#
# That makes it a LATCH recording whether card power was actually interrupted,
# which no other observer on this system reports, and several diagnoses turn on
# knowing which happened.  It was the single most useful probe found in the
# whole first-fit exercise, and it was being read by hand, by remembering to.
#
# SAFETY: THIS SCRIPT NEVER WRITES THE POT.
# -----------------------------------------
# There is deliberately no pot_write proc here and no I2C write of any data
# byte.  The only bytes ever put on the bus are the address byte with the READ
# bit set, and the ACK/NACK bits a read requires.  Raising VCCINT is somebody
# else's job (tcl/vccint_step.tcl over JTAG, host/fk33ctl.py over MMIO), both
# of which are bounded by a wiper floor.  A latch you can accidentally write is
# not a latch.
#
# A FAILED AXI READ IS -1, NOT DATA.
# ----------------------------------
# Every register read below goes through the JTAG-to-AXI master, which in the
# ENDPOINT bitstream is clocked and reset by xdma and is dead until the PCIe
# link is up.  A failed transaction surfaces as -1, not as an error, so a
# caller that string-compares the result concludes "the AXI path answered with
# the wrong value" when it never answered at all.  This script therefore probes
# the path FIRST and reports axi=dead, and the wrapper reports that as a
# different condition from a wrong reading.

set POT 0x2c
set TRI 0x00009004
set DAT 0x00009000
set SYSMON_VCCINT 3404
set SYSMON_TEMP   3400

# Target selection: NEVER by bare index.  With two cards on the chain,
# [lindex [get_hw_targets] 0] is whichever enumerated first, and aiming an
# operation at the wrong card is what destroyed card 1's factory flash.
# MEASURED 2026-08-30: this file's bare index made fk33_powercycle.sh report
# "no_axi_master" for a card that had three -- it was reading the other card.
source [file join [file dirname [info script]] .. tcl target_select.tcl]

proc emit {args} { puts "POTLATCH [join $args]" }

if {[catch {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    fk33_open_target
    set d [lindex [get_hw_devices] 0]
    current_hw_device $d
    # -update_hw_probes false: refreshing probes fails on this ES1 die and
    # aborted an earlier script before it did any work.
    refresh_hw_device -quiet -update_hw_probes false $d
} msg]} {
    emit status=no_target detail=[string map {" " "_"} $msg]
    puts "POTLATCH_DONE"
    return
}

set axl [get_hw_axis]
if {[llength $axl] == 0} {
    emit status=no_axi_master
    puts "POTLATCH_DONE"
    return
}
set ax [lindex $axl 0]

# Raw read: returns the token the tool gave us, verbatim, with no
# interpretation.  "-1" is what a FAILED transaction produces.
proc rdraw {addr} {
    global ax
    set v ""
    if {[catch {
        create_hw_axi_txn -quiet -force t $ax -address $addr -type read
        run_hw_axi -quiet [get_hw_axi_txns t]
        set v [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
    } msg]} {
        return -1
    }
    if {$v eq ""} { return -1 }
    return $v
}
proc dead {v} { return [expr {$v eq "-1" || $v eq "" || [string match "*-1*" $v]}] }

# Numeric read, matching tcl/vccint_step.tcl's proven arithmetic.  Only ever
# called after the path has been shown alive.
proc rdreg {addr} { return [rdraw $addr] }

# ---- PROBE THE AXI PATH BEFORE TRUSTING ANY VALUE FROM IT.
set probe [rdraw $TRI]
if {[dead $probe]} {
    emit status=axi_dead reg=$TRI raw=$probe
    puts "POTLATCH_DONE"
    return
}

# SYSMON through the JTAG DRP works whether or not the AXI fabric is clocked,
# so it is a genuinely independent cross-check on the AXI-side reading.
set drp_v "na"
set drp_t "na"
if {![catch {
    set sm [lindex [get_hw_sysmons] 0]
    refresh_hw_sysmon -quiet $sm
    set drp_v [get_property VCCINT $sm]
    set drp_t [get_property TEMPERATURE $sm]
}]} {}

# ---- bit-banged I2C, READS ONLY.
proc lines {scl sda} { global TRI ax
    create_hw_axi_txn -quiet -force w $ax -address $TRI \
        -data [format 0x%08x [expr {($scl ? 1 : 0) | ($sda ? 2 : 0)}]] -type write
    run_hw_axi -quiet [get_hw_axi_txns w]
}
proc sda_in {} { global DAT
    set v [rdraw $DAT]
    if {[dead $v]} { return -1 }
    return [expr {([format %d 0x$v] >> 1) & 1}]
}
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
    for {set i 0} {$i < 8} {incr i} {
        set b [i2c_rbit]
        if {$b < 0} { return -1 }
        set v [expr {($v << 1) | $b}]
    }
    i2c_wbit [expr {$ack ? 0 : 1}]
    return $v
}
# Read the volatile wiper.  No write of a data byte anywhere in here.
proc pot_read {a} {
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) | 1}]] != 0} { i2c_stop; return -1 }
    set hi [i2c_rbyte 1]
    set lo [i2c_rbyte 0]
    i2c_stop
    if {$hi < 0 || $lo < 0} { return -1 }
    return [expr {($hi << 8) | $lo}]
}

# GPIO_DAT is written once to zero and never again; every edge is made through
# GPIO_TRI, so the pins can only be pulled low or released, never driven high
# against another controller.  Same open-drain rule as tcl/i2cbang.tcl.
create_hw_axi_txn -quiet -force z $ax -address $DAT -data 0x00000000 -type write
run_hw_axi -quiet [get_hw_axi_txns z]
lines 1 1

set wiper [pot_read $POT]

set axi_v "na"
set raw_v [rdraw $SYSMON_VCCINT]
if {![dead $raw_v]} {
    if {![catch {set axi_v [expr {[format %d 0x$raw_v] * 3.0 / 65536.0}]}]} {}
}

lines 1 1
emit status=ok wiper=$wiper vccint_axi=$axi_v vccint_drp=$drp_v die_drp=$drp_t
catch {close_hw_target}
puts "POTLATCH_DONE"
