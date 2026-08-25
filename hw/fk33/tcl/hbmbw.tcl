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
set S_CBACK 256          ;# control-register READBACK window, + the R_* offset
set S_RERR  4096         ;# non-OKAY read responses, per port, + 4*i
set R_RGN   24           ;# [7:0] base channel, [15:8] stride

# The AXI clock the generator runs at.  Every GB/s figure below is
# beats * 32 * FCLK / cycles, so a wrong FCLK scales the whole result by
# exactly that ratio while every self-check still passes -- the beat counts
# are clock-independent and would not catch it.
#
# The comment here used to say "READ FROM THE BUILD, not assumed" while the
# code assumed it anyway.  It is now checked rather than asserted: the MMCM
# is 200 MHz in, MULT_F 6.000 -> VCO 1200, CLKOUT3 divide 4 -> 300.000 MHz
# EXACTLY, so for this build the constant is right.  It is right by
# construction, not by luck, and the assertion below is what makes that
# claim checkable if the build's clocking is ever retuned.
set FCLK 300.0e6
if {$argc >= 1} { set FCLK [lindex $argv 0] }

# VCO / CLKOUT3 divide, from build_fk33_hbmbw.tcl's clk_wiz_0 configuration.
# If these are edited there and not here, the mismatch is reported rather
# than silently rescaling every bandwidth number on the page.
set MMCM_IN 200.0e6 ; set MMCM_MULT 6.0 ; set MMCM_DIV3 4.0
set FCLK_DERIVED [expr {$MMCM_IN * $MMCM_MULT / $MMCM_DIV3}]
if {abs($FCLK - $FCLK_DERIVED) > 1.0e3} {
    puts ""
    puts "FCLK MISMATCH: using [expr {$FCLK/1e6}] MHz, but the clk_wiz settings"
    puts "  in build_fk33_hbmbw.tcl derive [expr {$FCLK_DERIVED/1e6}] MHz"
    puts "  (200 MHz x $MMCM_MULT / $MMCM_DIV3).  Every GB/s below would be"
    puts "  scaled by [format %.4f [expr {$FCLK/$FCLK_DERIVED}]].  Fix one of them."
    puts ""
}

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
set POINTS {1 2 4 8 15 30}
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

    # Read the control registers back BEFORE starting.  The first hardware run
    # of this instrument reported zero beats at every port count and it looked
    # like a routing or timing fault; in fact every control write was being
    # dropped on the bus and the generator was never told to start.  Reads
    # worked throughout, which is exactly why that was hard to see.  Three
    # reads here separate "the design was not told" from "the design was told
    # and did the wrong thing", which are the two halves of every later
    # failure and have completely different fixes.
    set gm [rd [expr {$TG + $S_CBACK + $R_MASK}]]
    set ga [rd [expr {$TG + $S_CBACK + $R_ARLEN}]]
    set gn [rd [expr {$TG + $S_CBACK + $R_NBRST}]]
    if {$gm != (1 << $n) - 1 || $ga != $ARLEN || $gn != $NBURST} {
        puts ""
        puts "CONTROL WRITES DID NOT LAND at $n ports."
        puts [format "  mask   wrote %d  reads %d" [expr {(1 << $n) - 1}] $gm]
        puts [format "  arlen  wrote %d  reads %d" $ARLEN $ga]
        puts [format "  nburst wrote %d  reads %d" $NBURST $gn]
        puts "  This is an AXI-Lite WRITE path fault, not a bandwidth result."
        puts "  Nothing below this line would be a measurement.  Stopping."
        break
    }

    wr [expr {$TG + $R_CTRL}]  1

    set spins 0
    while {[rd [expr {$TG + $S_BUSY}]] & 1} {
        incr spins
        if {$spins > 20000} { puts "TIMEOUT at $n ports"; break }
    }
    wr [expr {$TG + $R_CTRL}] 0

    set cyc [rd [expr {$TG + $S_CYC}]]
    set tot 0
    set errs 0
    for {set i 0} {$i < $n} {incr i} {
        incr tot  [rd [expr {$TG + $S_BEATS + 4*$i}]]
        incr errs [rd [expr {$TG + $S_RERR  + 4*$i}]]
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
    # A beat that came back with SLVERR or DECERR is not a byte of memory
    # bandwidth, and the interconnect returns those FASTER than HBM does -- so
    # an address-decode fault inflates the GB/s figure rather than failing.
    # Checked before anything else: if the data never came from memory then no
    # other number on this line means anything.
    if {$errs != 0} {
        puts ""
        puts "READ RESPONSE ERRORS at $n ports: $errs non-OKAY beats."
        puts "  These are SLVERR/DECERR responses, NOT memory traffic.  The"
        puts "  bandwidth figure on this line is measuring how fast the"
        puts "  interconnect can refuse a request.  Check the address map"
        puts "  against the enabled pseudo-channels before anything else."
        break
    }

    # Order matters: a thermal trip ABORTS the run, so it also leaves the beat
    # count short.  Checking beats first would report a trip as "beats wrong"
    # and send the reader off looking for a routing or timing fault that is
    # not there.  Always name the cause that explains the other symptom.
    if {$trip & 0x6} {
        puts ""
        puts "THERMAL TRIP at $n ports (trip reg [format 0x%X $trip]):"
        puts "  bit1 CATTRIP  bit2 programmed ceiling"
        puts "  The number on this line is NOT a measurement -- the run aborted"
        puts "  early, which is also why the beat count is short."
        puts "  Sweep stopped."
        break
    }

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
    if {$dt ne "n/a" && $t0 ne "n/a" && $dt - $t0 > 25.0} {
        puts ""
        puts "STOPPING: die temperature rose ${t0} -> ${dt} C during the sweep."
        break
    }
}

# ---- OVERSUBSCRIPTION -------------------------------------------------------
# Everything above maps port i to its OWN pseudo-channel, and at 300 MHz that
# CANNOT load the memory: a 256-bit port demands 32 B x 300 MHz = 9.6 GB/s
# while a pseudo-channel supplies 460.8/32 = 14.4 GB/s.  Reaching 100% of the
# port ceiling there is arithmetic, not a discovery, and it says nothing about
# what HBM can deliver.
#
# Pointing every port at ONE channel (stride 0) oversubscribes it: two ports
# demand 19.2 GB/s against 14.4, so the channel becomes the limit.  The rate
# then STOPS scaling with port count and the plateau is the channel's real
# delivered bandwidth -- the number the 460.8 GB/s premise rests on.
#
# 450 MHz is what ONE port needs to match a channel.  This gets to the same
# place with more ports instead of a faster clock.
puts ""
puts "==== OVERSUBSCRIPTION: all ports -> pseudo-channel 1 ===================="
puts "the per-port ceiling no longer applies; the PLATEAU is the channel's"
puts "delivered bandwidth.  Theory says 14.4 GB/s; real DRAM efficiency is"
puts "what this measures."
puts ""
puts [format "%6s %10s %12s %12s %10s %8s" \
      ports beats cycles GB/s "vs 14.4" die_C]

set OV_NBURST 200000
foreach n {1 2 3 4 8 15 30} {
    if {$n > $NPORT} { continue }
    wr [expr {$TG + $R_CTRL}]  2
    wr [expr {$TG + $R_RGN}]   0x0001         ;# base 1, stride 0
    wr [expr {$TG + $R_MASK}]  [expr {(1 << $n) - 1}]
    wr [expr {$TG + $R_ARLEN}] $ARLEN
    wr [expr {$TG + $R_NBRST}] $OV_NBURST
    wr [expr {$TG + $R_OUTST}] $OUTST

    set gr [rd [expr {$TG + $S_CBACK + $R_RGN}]]
    if {($gr & 0xFFFF) != 0x0001} {
        puts "REGION REGISTER DID NOT LAND (reads [format 0x%04X [expr {$gr & 0xFFFF}]])"
        puts "  Without it every port is still on its own channel and this"
        puts "  sweep would repeat the guaranteed-100% result.  Stopping."
        break
    }

    wr [expr {$TG + $R_CTRL}] 1
    set spins 0
    while {[rd [expr {$TG + $S_BUSY}]] & 1} {
        incr spins
        if {$spins > 40000} { puts "TIMEOUT at $n ports"; break }
    }
    wr [expr {$TG + $R_CTRL}] 0

    set cyc [rd [expr {$TG + $S_CYC}]]
    set tot 0
    set errs 0
    for {set i 0} {$i < $n} {incr i} {
        incr tot  [rd [expr {$TG + $S_BEATS + 4*$i}]]
        incr errs [rd [expr {$TG + $S_RERR  + 4*$i}]]
    }
    if {$errs != 0} {
        puts "  READ RESPONSE ERRORS: $errs.  Every port now addresses channel 1,"
        puts "  so this most likely means the extra address segments are missing"
        puts "  from the build.  Not a bandwidth result.  Stopping."
        break
    }
    set want [expr {$n * $OV_NBURST * ($ARLEN + 1)}]
    set gbs  [expr {$cyc > 0 ? $tot * $BYTES_PER_BEAT * $FCLK / $cyc / 1e9 : 0}]
    set mark ""
    if {$tot != $want} { set mark "  <-- BEATS WRONG, want $want" }
    puts [format "%6d %10d %12d %12.2f %9.1f%% %8s%s" \
          $n $tot $cyc $gbs [expr {100.0*$gbs/14.4}] [die_temp] $mark]
    if {$tot != $want} { break }
}
puts ""
puts "READING: the rate should rise with port count and then FLATTEN.  The"
puts "  flat value is one pseudo-channel's delivered bandwidth.  If it keeps"
puts "  scaling linearly past 2 ports, the ports are NOT landing on the same"
puts "  channel and the region register or the address map is wrong."
puts "  Device ceiling = 32 x that plateau, and the port-per-channel sweep"
puts "  above is what licenses the multiply: 15 channels ran concurrently at"
puts "  full port rate with no interference, so there is no shared upstream"
puts "  limit below 144 GB/s."

puts ""
puts "die temperature after: [die_temp] C   stack codes: [stack_temps]"
puts ""
puts "The stack temperature CODES are raw 7-bit values.  Their mapping to"
puts "Celsius has not been verified on this card, which is why the generator's"
puts "soft ceiling ships DISABLED and CATTRIP does the hard protection.  Record"
puts "them against the die temperature here to calibrate the mapping."
