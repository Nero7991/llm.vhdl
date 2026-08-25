# FK33 HBM read-bandwidth sweep.
#
# Drives rtl/hbm_tg.vhd over jtag_axi and reports achieved bandwidth against
# port count.  Run AFTER hw/fk33/tcl/program.tcl has configured the device
# under xsdb -- Vivado's hardware manager cannot configure this die (no `fpga`
# command, and program_hw_devices enforces an ES1 revision check with no
# documented waiver).  Same split as hw/fk33/check.sh.
#
# WHAT THIS IS FOR.  Every throughput figure in all five v2 design specs rests
# on the FK33's HBM delivering ~460 GB/s, of which subsystem A at ROWS_IF=58
# demands ~432.  That number is 32 ports x 32 B x 450 MHz -- an arithmetic
# ceiling, not a measurement -- and nothing on this card has ever moved a byte
# of HBM at speed.
#
# THERMAL.  The generator carries its own watchdog in fabric on the HBM
# stacks' CATTRIP signal, which the stock design leaves unconnected.  This
# script adds the second layer: it ramps the port count UPWARD, reads the
# stack temperature codes and SYSMON around every step, and stops the sweep if
# anything moves.  The ramp order matters -- the first full-power moment is
# the LAST step, not the first, so a thermal problem shows up at 4 or 8 ports
# with a smaller load still applied.

# ---- register map, from rtl/hbm_tg.vhd -------------------------------------
set TG      0x00010000   ;# 64K-aligned, see gen_hbmbw.py
set R_CTRL  0            ;# bit0 go, bit1 clear
set R_MASK  4
set R_ARLEN 8            ;# AXI3: 4 bits, so at most 15 (= 16 beats)
set R_NBRST 12
set R_OUTST 16
set R_TLIM  20           ;# soft ceiling on the RAW temp code; 0 = disabled
set S_ID    0
set S_CYC   4
set S_BUSY  8
set S_NPORT 12
set S_TEMP  16
set S_TRIP  20
set S_BEATS 1024         ;# + 4*i
set S_STALL 2048
set S_RETIR 3072

# The AXI clock the generator runs at.  READ FROM THE BUILD, not assumed: the
# MMCM cannot always hit the requested frequency, and a bandwidth figure
# computed with the requested clock rather than the achieved one is wrong by
# exactly that ratio.  Overridden by -tclargs.
set FCLK 300.0e6
if {$argc >= 1} { set FCLK [lindex $argv 0] }

set BYTES_PER_BEAT 32    ;# 256-bit SAXI

proc rd {addr} {
    set t [create_hw_axi_txn -force rdtxn [get_hw_axis hw_axi_1] \
             -address [format %08x $addr] -type read -len 1]
    run_hw_axi -quiet $t
    # -t d4 returns DECIMAL even though the INFO line beside it prints hex.
    # This cost an afternoon once; see 2026-08-24_fk33-sysmon-vccint-undervolt.md
    set v [lindex [report_hw_axi_txn -t d4 $t] 1]
    return [expr {$v & 0xffffffff}]
}
proc wr {addr val} {
    set t [create_hw_axi_txn -force wrtxn [get_hw_axis hw_axi_1] \
             -address [format %08x $addr] -type write \
             -data [format %08x $val] -len 1]
    run_hw_axi -quiet $t
}

proc stack_temps {} {
    global TG S_TEMP
    set v [rd [expr {$TG + $S_TEMP}]]
    return [list [expr {$v & 0x7f}] [expr {($v >> 7) & 0x7f}] \
                 [expr {($v >> 14) & 0x7f}] [expr {($v >> 21) & 0x7f}]]
}

proc die_temp {} {
    set sm [lindex [get_hw_sysmons -quiet] 0]
    if {$sm eq ""} { return "n/a" }
    refresh_hw_sysmon $sm
    return [format %.1f [get_property TEMPERATURE $sm]]
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target [lindex [get_hw_targets] 0]
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d

set id [rd $TG]
if {$id != 0x48424D31} {
    puts "FATAL: generator ID reads [format 0x%08X $id], expected 0x48424D31."
    puts "       Either the device is not configured with the hbmbw bitstream,"
    puts "       or hw_axi_1 is not jtag_axil.  An unmapped read on this master"
    puts "       returns the smartconnect DECERR magic 0xdec0dee3."
    return
}
set NPORT [rd [expr {$TG + $S_NPORT}]]
puts "generator OK, NPORT=$NPORT, AXI clock [format %.2f [expr {$FCLK/1e6}]] MHz"
puts "ceiling at NPORT ports = [format %.1f \
      [expr {$NPORT * $BYTES_PER_BEAT * $FCLK / 1e9}]] GB/s"

set t0 [die_temp]
puts "die temperature before: $t0 C   stack codes: [stack_temps]"

# ---- the sweep -------------------------------------------------------------
# Ramped, so the largest load is applied last.
set POINTS {1 2 4 8 15}
set ARLEN 15          ;# 16 beats, the AXI3 maximum
set NBURST 200000     ;# ~102 MB per port; ~0.5 ms at ceiling, bounded by design
set OUTST 16

puts ""
puts [format "%6s %10s %12s %12s %10s %8s %s" \
      ports beats cycles GB/s "%ceiling" die_C stacks]

set results {}
foreach n $POINTS {
    if {$n > $NPORT} { continue }
    wr [expr {$TG + $R_CTRL}]  2
    wr [expr {$TG + $R_MASK}]  [expr {(1 << $n) - 1}]
    wr [expr {$TG + $R_ARLEN}] $ARLEN
    wr [expr {$TG + $R_NBRST}] $NBURST
    wr [expr {$TG + $R_OUTST}] $OUTST
    wr [expr {$TG + $R_CTRL}]  1

    set spins 0
    while {[rd [expr {$TG + $S_BUSY}]] & 1} {
        incr spins
        if {$spins > 20000} { puts "TIMEOUT at $n ports"; break }
    }
    wr [expr {$TG + $R_CTRL}] 0

    set cyc [rd [expr {$TG + $S_CYC}]]
    set tot 0
    for {set i 0} {$i < $n} {incr i} {
        incr tot [rd [expr {$TG + $S_BEATS + 4*$i}]]
    }
    set trip [rd [expr {$TG + $S_TRIP}]]
    # SELF-CHECK.  The expected beat count is EXACT: nburst x (arlen+1) per
    # port.  This is what makes the instrument trustworthy on hardware rather
    # than only in simulation -- if the design is running outside its timing
    # envelope, or a port is misrouted, or a burst was dropped, the count will
    # not match and the bandwidth figure on that line means nothing.  A
    # measurement that cannot detect its own failure is not a measurement.
    set want [expr {$n * $NBURST * ($ARLEN + 1)}]
    set gbs  [expr {$cyc > 0 ? $tot * $BYTES_PER_BEAT * $FCLK / $cyc / 1e9 : 0}]
    set ceil [expr {$n * $BYTES_PER_BEAT * $FCLK / 1e9}]
    set dt   [die_temp]
    set mark ""
    if {$tot != $want} { set mark "  <-- BEATS WRONG, want $want" }
    puts [format "%6d %10d %12d %12.1f %9.1f%% %8s %s%s" \
          $n $tot $cyc $gbs [expr {100.0*$gbs/$ceil}] $dt [stack_temps] $mark]
    lappend results [list $n $gbs]
    if {$tot != $want} {
        puts ""
        puts "STOPPING: the generator moved $tot beats where $want are exactly"
        puts "  required.  The number on that line is NOT a bandwidth"
        puts "  measurement.  Most likely causes, in order: the design is"
        puts "  running outside its timing envelope (Vivado signs off at"
        puts "  0.85 V, this card runs 0.717 V, measured derate -22.9%), a"
        puts "  port is mapped to the wrong pseudo-channel, or a burst was"
        puts "  dropped.  Check the routed WNS against 0.229 x period before"
        puts "  anything else."
        break
    }

    # A run that tripped is not a measurement.  Say so and stop.
    if {$trip & 0x6} {
        puts ""
        puts "THERMAL TRIP at $n ports (trip reg [format 0x%X $trip]):"
        puts "  bit1 CATTRIP  bit2 programmed ceiling"
        puts "  The number on this line is NOT a measurement -- the run aborted."
        puts "  Sweep stopped."
        break
    }
    if {$dt ne "n/a" && $t0 ne "n/a" && $dt - $t0 > 25.0} {
        puts ""
        puts "STOPPING: die temperature rose ${t0} -> ${dt} C during the sweep."
        break
    }
}

puts ""
puts "die temperature after: [die_temp] C   stack codes: [stack_temps]"
puts ""
puts "The stack temperature CODES are raw 7-bit values.  Their mapping to"
puts "Celsius has not been verified on this card, which is why the generator's"
puts "soft ceiling ships DISABLED and CATTRIP does the hard protection.  Record"
puts "them against the die temperature here to calibrate the mapping."
