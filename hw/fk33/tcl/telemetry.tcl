# FK33 telemetry: program the first-light bitstream, then read every SYSMON
# channel and scan the board I2C bus.  Read-only with respect to the board:
# the I2C probes are START + slave-addr-READ + STOP and never write a data
# byte, so they cannot alter a regulator setpoint.
#
# Two facts this script depends on, both learned the hard way (see
# docs/debugging/2026-08-24_fk33-sysmon-vccint-undervolt.md):
#   * report_hw_axi_txn -t d4 returns DECIMAL, not hex, even though the
#     "READ DATA is:" INFO line printed beside it is hex;
#   * an unmapped read on the AXI-Lite master returns the smartconnect DECERR
#     magic 0xdec0dee3 (-557785373 signed), which identifies that master
#     POSITIVELY rather than looking like a failure.
#
# CORRECTION 2026-08-29.  This header used to say "hw_axi_1 is jtag_axil and
# hw_axi_2 is jtag_hbm".  That was true of the two-master first-light bitstream
# and is FALSE on the three-master builds: MEASURED in tcl/aux_probe.log:178
# (thermal build) hw_axi_1 is jtag_aux and hw_axi_2 is jtag_axil, and in
# tcl/pcieep_jtag.log (engine build) the AXI-Lite master is hw_axi_2 again.
# Enumeration order is an implementation result, not a contract.  The master is
# now picked by what it ANSWERS -- see tcl/axi_select.tcl.

source [file join [file dirname [info script]] target_select.tcl]
source [file join [file dirname [info script]] axi_select.tcl]

set BIT [file normalize [file join [file dirname [info script]] .. \
          fk33_example fk33_example.runs impl_1 bd_wrapper.bit]]

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d

puts "IDCODE      [get_property IDCODE_HEX $d]"
puts "PART        [get_property PART $d]"

# Configuration is volatile, so a power cycle leaves the device blank.  It is
# programmed by tcl/program.tcl under xsdb BEFORE this script runs: the Vivado
# hardware manager has no 'fpga' command, and program_hw_devices enforces the
# ES1 revision check with no documented way to waive it, so Vivado cannot
# configure this die at all.  See check.sh.

# ---- ground truth: SYSMON over the dedicated JTAG DRP path, Vivado's own
# ---- decode.  Shares no code, transport or address map with the AXI reads.
set sm [lindex [get_hw_sysmons -quiet] 0]
if {$sm ne ""} {
    refresh_hw_sysmon $sm
    puts "=== SYSMON via JTAG DRP (Vivado native decode) ==="
    foreach p {TEMPERATURE VCCINT VCCBRAM VCCAUX VUSER0 VUSER1 VUSER2 VUSER3
               MIN_VCCINT MAX_VCCINT MIN_TEMPERATURE MAX_TEMPERATURE} {
        if {![catch {set v [get_property $p $sm]}]} {
            puts [format "  %-18s %s" $p $v]
        }
    }
}

set axis [get_hw_axis -quiet]
if {[llength $axis] == 0} { puts "NO_AXI_MASTERS"; close_hw_target; exit 0 }
set ax [fk33_axi_pick axil]

proc r {ax addr} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    if {[catch {run_hw_axi -quiet [get_hw_axi_txns t]}]} { return -2 }
    set v [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
    if {$v == -557785373} { return -1 }
    return $v
}
proc w {ax addr data} {
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}
proc drp {ax a} { return [r $ax [format %04x [expr {0x3400 + 4*$a}]]] }

puts "=== SYSMON via AXI-Lite ([get_property NAME $ax], base 0x3000) ==="
foreach {a name nom} {0x00 TEMP - 0x01 VCCINT 0.85/0.72 0x02 VCCAUX 1.80
                      0x06 VCCBRAM 0.85/0.72 0x80 VUSER0_MGTAVCC 0.90
                      0x81 VUSER1_MGTVCCAUX 1.80 0x82 VUSER2_MGTAVTT 1.20
                      0x83 VUSER3_VCCO_B64 notseq} {
    set v [drp $ax $a]
    if {$v < 0} { puts [format "  %-18s READ_FAIL" $name]; continue }
    if {$a == 0x00} {
        puts [format "  %-18s %8.2f C" $name [expr {$v*507.6/65536.0-279.43}]]
    } else {
        puts [format "  %-18s %8.4f V   (nominal %s)" $name [expr {$v*3.0/65536.0}] $nom]
    }
}

puts "=== board channels (external, via board dividers) ==="
foreach {a name note} {0x10 INP12V {x15.2 -> volts} 0x14 LTC3636_A {x400-273.15 -> C}
                       0x18 LTC3636_B {x400-273.15 -> C} 0x15 VCCINT_I {scale UNKNOWN}
                       0x1c VCCHBM_I {scale UNKNOWN} 0x1d VCCBRAM_I {scale UNKNOWN}} {
    set v [drp $ax $a]
    if {$v < 0} { puts [format "  %-12s READ_FAIL" $name]; continue }
    puts [format "  %-12s raw=%5d  frac=%.5f  x15.2=%7.3f V  temp=%7.2f C   %s" \
        $name $v [expr {$v/65536.0}] [expr {$v*15.2/65536.0}] \
        [expr {$v*400.0/65536.0-273.15}] $note]
}

set flag [drp $ax 0x3f]
puts [format "=== alarms: FLAG_REG=0x%04x ===" $flag]
foreach {b n} {1 VCCINT 2 VCCAUX 4 VCCBRAM_or_other} {
    puts [format "  bit%-2s %-18s %s" $b $n [expr {($flag>>$b)&1 ? "ASSERTED" : "clear"}]]
}
puts "  limits: VCCINT [format %.4f [expr {[drp $ax 0x51]*3.0/65536.0}]] upper / [format %.4f [expr {[drp $ax 0x55]*3.0/65536.0}]] lower"

# ---- I2C: prove the core before blaming the bus, then scan read-only.
puts "=== IIC core liveness (GPO scratch) ==="
set g0 [r $ax 00009124]
w $ax 00009124 0x0000002a
set g1 [r $ax 00009124]
w $ax 00009124 [format 0x%08x $g0]
puts [format "  GPO %d -> wrote 0x2a -> read %d -> restored %d   (%s)" \
    $g0 $g1 [r $ax 00009124] [expr {$g1 == 42 ? "CORE OK" : "CORE SUSPECT"}]]

puts "=== I2C scan 0x08-0x77 (read probes only) ==="
set found {}
for {set a 0x08} {$a <= 0x77} {incr a} {
    set ar [expr {($a << 1) | 1}]
    create_hw_axi_txn -quiet -force c0 $ax -address 00009040 -data 0x0000000A -type write
    create_hw_axi_txn -quiet -force c1 $ax -address 00009120 -data 0x00000000 -type write
    create_hw_axi_txn -quiet -force c2 $ax -address 00009100 -data 0x00000000 -type write
    create_hw_axi_txn -quiet -force c3 $ax -address 00009108 -data [format 0x%08x [expr {0x100|$ar}]] -type write
    create_hw_axi_txn -quiet -force c4 $ax -address 00009108 -data 0x00000201 -type write
    create_hw_axi_txn -quiet -force c5 $ax -address 00009100 -data 0x00000001 -type write
    run_hw_axi -quiet c0 c1 c2 c3 c4 c5
    if {!(([r $ax 00009020] >> 1) & 1)} { lappend found [format 0x%02x $a] }
}
if {[llength $found]} {
    puts "  DEVICES ACKED: $found"
} else {
    puts "  NO DEVICES ACKED  (bus silent; on bench power this was the state)"
}

close_hw_target
puts "TELEMETRY_DONE"
