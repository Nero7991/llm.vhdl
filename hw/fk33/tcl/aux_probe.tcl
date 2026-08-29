# Read the FK33 endpoint bitstream's AUX registers over JTAG, with the PCIe
# link DOWN.
#
# WHAT THIS IS FOR
# ----------------
# Under fk33_pcieep every AXI-Lite transaction on jtag_hbm and jtag_axil fails,
# because those masters are clocked by xdma/axi_aclk and reset by
# xdma/axi_aresetn, and both come out of the PCIe hard block.  A failed
# transaction reports as -1, NOT as an error, so a script that string-compares
# concludes "the bus answered with the wrong value" when it never answered.
#
# jtag_aux is different.  Its whole branch -- the master, its smartconnect and
# its four register slaves -- is clocked by the FK33's 200 MHz board oscillator
# through a plain BUFG, with no MMCM and no connection of any kind to xdma.  So
# these reads are expected to WORK with the link down, and if they do not, the
# fault is upstream of everything this bitstream can report on: the card is
# unpowered, the oscillator is dead, or the FPGA is not configured.
#
# HOW TO READ THE RESULT
# ----------------------
#   UCLK_HZ ~= 250 MHz      the PCIe hard block is clocked and its PLL is
#                           locked, so a down link is a TRAINING failure and
#                           NOT a missing reference clock.
#   UCLK_HZ = 0, PERST# 1   the block is out of reset and still has no clock.
#                           The host is not driving the reference clock; a PCH
#                           that disabled the root port also gates its SRC.
#   UCLK_HZ = 0, PERST# 0   we are simply being held in reset.  This says
#                           nothing at all about the reference clock.
#
#   PERST#@CFG = 1          reset had ALREADY been released when configuration
#                           finished.  That is the flash-boot timing loss, and
#                           it presents exactly as a hidden root port.
#   POT wiper 68 / done     the autonomous VCCINT controller ran and VCCINT is
#                           at 0.717 V with no host and no JTAG involved.
#
# A DIRECT measurement of pcie_refclk is NOT available, and was not skipped out
# of laziness.  It needs a second BUFG_GT on the IBUFDS_GTE4 ODIV2 tap, and DRC
# BFGTL-1 rejects that because two BUFG_GTs on one GT clock source must have
# identical CE and CLR nets -- xdma drives its own from an internal
# BUFG_GT_SYNC that is not exposed as a pin.  route_design fails outright.  Do
# not retry it; see docs/debugging/2026-08-28_fk33-free-running-observability.md.
#
# Nothing here writes anything.

#
# SELF TEST.  Set AUXPROBE_SELFTEST=1 and run this under a plain tclsh: it
# decodes fixed vectors taken from the RTL simulation and exits WITHOUT
# touching any hardware.  It exists because the decode below had a bug that
# aborted the entire script on its first register:
#
#     set v [expr {0x$hz}]     ->  invalid bareword "0x"
#
# Braces stop Tcl substituting, so expr parses the expression itself and sees
# the bareword "0x" followed by a variable.  Every register would then read as
# unreachable and the aux instrumentation would look dead on the card, when in
# fact the card was fine and the script was not.  `scan ... %x` is used
# throughout instead, and it passes the "-1" no-answer sentinel through
# unchanged rather than throwing.
#
# A failed JTAG-AXI transaction reports as -1, NOT as an error.
source [file join [file dirname [info script]] target_select.tcl]

proc isbad {v} { return [expr {$v eq "-1" || $v eq "" || [string match "*-1*" $v]}] }

proc diec {code} { return [expr {$code * 507.5921310 / 1024.0 - 279.42657680}] }

proc decode_thermal {th tt tpk ttr tcan} {
    puts ""
    puts "---- thermal guard -----------------------------------------------------"
    if {[isbad $th]} {
        puts "THERMAL  no answer at 0x4000.  Either this bitstream predates the"
        puts "         thermal guard, or the aux branch is only partly alive."
    } else {
        scan $th %x vth
        scan $tt %x vtt
        scan $tpk %x vtpk
        scan $ttr %x vttr
        if {$vth == 0 || $vth == 0xFFFFFFFF} {
            puts [format "THERMAL  THERM_STATUS reads 0x%08X.  That is a DEAD BUS, not" $vth]
            puts "         a reading: bit 31 of a real status word is always 1 and"
            puts "         bits 30:24 are never all-ones.  Treat every field below"
            puts "         as absent rather than as a cold card."
        } elseif {[expr {($vth >> 31) & 1}] == 0} {
            puts "THERMAL  bit 31 is CLEAR: this bitstream has NO thermal guard."
            puts "         The only protection is SYSMON's armed over-temperature"
            puts "         shutdown at 101 C, which is above the -2LE sustained"
            puts "         rating of 100 C, says nothing about the HBM stacks, and"
            puts "         takes the card off the PCIe bus when it fires.  Do not"
            puts "         run a sustained workload on this bitstream."
        } else {
            set causes [list "none" \
                "SYSMON over-temperature alarm (the armed 101 C backstop)" \
                "SYSMON user temperature alarm" \
                "die above the halt threshold" \
                "die sensor STALE or implausible -- treated as hot" \
                "an HBM stack asserted CATTRIP" \
                "HBM above the halt threshold" \
                "HBM sensor STALE or implausible -- treated as hot"]
            puts [format "HALTED  %s     warn=%d  armed=%d  die_valid=%d  hbm_valid=%d" \
                  [expr {($vth & 1) ? "YES" : "no "}] \
                  [expr {($vth >> 1) & 1}] [expr {($vth >> 2) & 1}] \
                  [expr {($vth >> 3) & 1}] [expr {($vth >> 4) & 1}]]
            puts [format "DIE     %.1f C  (code %d)   peak %.1f C" \
                  [diec [expr {$vtt & 0x3ff}]] [expr {$vtt & 0x3ff}] \
                  [diec [expr {$vtpk & 0x3ff}]]]
            puts [format "HBM     code %d / %d   peak %d / %d" \
                  [expr {($vtt >> 10) & 0x7f}] [expr {($vtt >> 17) & 0x7f}] \
                  [expr {($vtpk >> 10) & 0x7f}] [expr {($vtpk >> 17) & 0x7f}]]
            puts "        (RAW stack code.  Its mapping to Celsius is NOT calibrated"
            puts "         on this card; idle codes have measured 25-29 at 22-28 C.)"
            puts [format "CAUSE   %s" [lindex $causes [expr {($vth >> 8) & 7}]]]
            if {[expr {($vth >> 7) & 1}]} {
                puts [format "TRIP    LATCHED: %s" [lindex $causes [expr {($vth >> 12) & 7}]]]
                puts [format "        at die %.1f C, HBM code %d / %d, %d trips since the last clear" \
                      [diec [expr {$vttr & 0x3ff}]] [expr {($vttr >> 10) & 0x7f}] \
                      [expr {($vttr >> 17) & 0x7f}] [expr {($vth >> 16) & 0xff}]]
            } else {
                puts "TRIP    none latched since the last clear"
            }
            foreach {b what} {25 "SYSMON OT alarm has fired" \
                              27 "SYSMON user temperature alarm has fired" \
                              28 "HBM stack 0 asserted CATTRIP" \
                              29 "HBM stack 1 asserted CATTRIP" \
                              30 "the two HBM temperature copies disagreed (a CDC fault)"} {
                if {[expr {($vth >> $b) & 1}]} { puts "        STICKY: $what" }
            }
            puts [format "CANARY  0x%s -- advances ONLY while the compute domain is" $tcan]
            puts "        running AND the guard has released it.  Run this twice: a"
            puts "        frozen canary with HALTED=no means the compute clock is"
            puts "        dead, which is a different fault from a thermal halt."
            if {[expr {$vth & 1}] && [expr {($vth >> 2) & 1}] == 0} {
                puts "THERM_VERDICT halted and NEVER armed.  The guard has not yet seen"
                puts "              a valid reading from both sensors, so it is holding"
                puts "              the datapath off.  With the PCIe link down that is"
                puts "              EXPECTED: SYSMON's temperature bus and the HBM APB"
                puts "              clock are both in PCIe-derived domains."
            } elseif {[expr {$vth & 1}]} {
                puts "THERM_VERDICT HALTED.  Read CAUSE above.  The link, the AXI fabric"
                puts "              and this register set are deliberately still alive."
            } else {
                puts "THERM_VERDICT running, guard armed and both sensors live."
            }
        }
    }
}

if {[info exists ::env(AUXPROBE_SELFTEST)]} {
    # Vectors from the tail of sim/tb_fk33_thermal.vhd, printed by the RTL
    # itself.  If the decode below ever stops agreeing with them, one of the
    # two moved.
    puts "AUXPROBE_SELFTEST vectors from tb_fk33_thermal"
    decode_thermal 8A0377CD 1E830670 1E830670 57830670 00001186
    puts ""
    puts "---- a bitstream with no thermal guard ----"
    decode_thermal 0000000D 1E830670 1E830670 00000000 00000000
    puts ""
    puts "---- a dead bus ----"
    decode_thermal -1 -1 -1 -1 -1
    decode_thermal 00000000 00000000 00000000 00000000 00000000
    decode_thermal FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF
    puts "AUXPROBE_SELFTEST OK"
    exit 0
}

puts "AUXPROBE begin"

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
# NOT get_property REGISTER.IDCODE: that property does not exist on this
# hw_device and aborts the whole script with [Labtoolstcl 44-56].  And NOT
# -update_hw_probes true, which is slower and buys nothing here.
refresh_hw_device -quiet -update_hw_probes false $d
puts "PART [get_property PART [current_hw_device]]"

set axis [get_hw_axis]
puts "AXI_MASTERS $axis"

# -1 is what a transaction that never completed reports.  Every read here goes
# through this, and the caller must check for -1 explicitly.
proc rd {ax addr} {
    if {[catch {
        create_hw_axi_txn -quiet -force t $ax -address $addr -type read
        run_hw_axi -quiet [get_hw_axi_txns t]
        set v [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
    } err]} {
        return "-1"
    }
    # `-t d4` returns a SIGNED DECIMAL string.  Every comparison in this file
    # is against a HEX string, so this proc used to hand back e.g. 1096112177
    # and the caller compared it to "41555831" and concluded no master had
    # answered -- while printing "0x1096112177", a decimal with an 0x glued on,
    # which is not a number in any base.  The aux domain was alive and correct
    # the whole time.  Normalise here, once, rather than at every call site.
    #
    # -1 is kept as the distinguished NO ANSWER token even though it is also
    # 0xFFFFFFFF, because that is the convention the rest of this file and
    # docs/2026-08-28_fk33-first-fit-handoff.md already use: a failed AXI
    # transaction reports as -1 rather than raising.
    if {![string is integer -strict $v]} { return "-1" }
    if {$v == -1} { return "-1" }
    return [format "%08X" [expr {$v & 0xFFFFFFFF}]]
}

# Find the aux master by ASKING, not by index.  get_hw_axis returns the masters
# in netlist order, and adding jtag_aux can reorder hw_axi_1/hw_axi_2, so any
# script that hardcodes [lindex $axis 1] is one build away from reading the
# wrong master and blaming the card.
set aux ""
foreach a $axis {
    set m [rd $a 0]
    puts [format "  %-10s 0x00000000 -> 0x%s" $a $m]
    if {[string toupper $m] eq "41555831"} { set aux $a }
}
if {$aux eq ""} {
    puts "AUXPROBE_FAIL no master answered 0x41555831 (\"AUX1\") at 0x0."
    puts "              Either this is not the instrumented bitstream, or the"
    puts "              200 MHz board oscillator on BC26/BC27 is not running,"
    puts "              or the card is not configured at all.  Note that all"
    puts "              -1 above means NO ANSWER, not a wrong value."
    puts "AUXPROBE_DONE"
    close_hw_target
    exit 0
}
puts "AUX_MASTER $aux"

set ver   [rd $aux 8]
set tick  [rd $aux 1000]
set hz    [rd $aux 1008]
set stat  [rd $aux 2000]
set pot   [rd $aux 2008]
set ms    [rd $aux 3000]
set pms   [rd $aux 3008]

foreach n {ver tick hz stat pot ms pms} {
    if {[isbad [set $n]]} {
        puts "AUXPROBE_FAIL register $n did not answer; the aux branch is only"
        puts "              partly alive, which should be impossible."
        puts "AUXPROBE_DONE"
        close_hw_target
        exit 0
    }
}

# TRAP, found on 2026-08-28 by running this decode under tclsh with stub reads:
#   set v [expr {0x$hz}]
# does NOT work.  Braces stop Tcl substituting, so expr itself parses the
# expression and sees the bareword "0x" followed by a variable, which is a hard
# error:  invalid bareword "0x" ... should be "$0x" or "{0x}" or "0x(...)".
# It aborts the whole script on the FIRST decode, so every register below would
# read as unreachable and the aux instrumentation would look dead on hardware.
# This script had never been run on a card when the form was written.  `scan`
# takes the hex string directly, and it also passes the "-1" no-answer sentinel
# through unchanged instead of throwing.
scan $hz %x vhz
scan $stat %x vstat
scan $pot %x vpot
scan $ms %x vms
scan $pms %x vpms

puts ""
puts "AUX_VERSION 0x$ver"
puts [format "AUX_UPTIME  %d ms since configuration" $vms]
if {$vms == 0} {
    puts "AUXPROBE_WARN the millisecond counter is 0.  The aux clock is not"
    puts "              running, so every other reading below is meaningless."
}

puts ""
puts "---- PCIe user clock (xdma/axi_aclk) -----------------------------------"
puts [format "UCLK_TICKS 0x%s  (1 tick = 128 axi_aclk cycles)" $tick]
puts [format "UCLK_HZ    %d  (expect 250000000)" $vhz]
if {[expr {($vstat >> 12) & 1}] == 1} {
    puts "UCLK_VERDICT ALIVE and within 10% of 250 MHz.  The PCIe hard block is"
    puts "             clocked and its PLL is locked, so the reference clock IS"
    puts "             present.  A down link is a TRAINING failure from here on,"
    puts "             not a missing clock and not a reset."
} elseif {[expr {($vstat >> 13) & 1}] == 0 && [expr {$vstat & 1}] == 1} {
    puts "UCLK_VERDICT DEAD with PERST# DEASSERTED.  The block has been let out"
    puts "             of reset and still has no clock.  The host is not driving"
    puts "             the PCIe reference clock -- consistent with a root port"
    puts "             the BIOS disabled and whose SRC clock the PCH gated.  No"
    puts "             amount of endpoint work changes that."
} elseif {[expr {($vstat >> 13) & 1}] == 0} {
    puts "UCLK_VERDICT DEAD, but PERST# is ASSERTED, so this is expected and"
    puts "             says NOTHING about the reference clock.  Get PERST#"
    puts "             deasserted and read again."
} else {
    puts "UCLK_VERDICT ticked but out of range.  The block is clocked at the"
    puts "             wrong rate; check CONFIG.axisten_freq against 250 MHz."
}

puts ""
puts "---- reset and link ----------------------------------------------------"
puts [format "PERST#  level=%d  at-configuration=%d  ever-low=%d  ever-high=%d  deassertions=%d" \
      [expr {$vstat & 1}] [expr {($vstat >> 1) & 1}] [expr {($vstat >> 2) & 1}] \
      [expr {($vstat >> 3) & 1}] [expr {($vstat >> 4) & 15}]]
if {[expr {($vstat >> 14) & 1}]} {
    puts [format "PERST_MS  first deasserted %d ms after configuration" $vpms]
} else {
    puts "PERST_MS  no deassertion has been observed since configuration"
}
if {[expr {($vstat >> 1) & 1}] == 1} {
    puts "PERST_VERDICT PERST# was ALREADY DEASSERTED when this bitstream came"
    puts "              up.  Configuration finished after the host released"
    puts "              reset, so the endpoint missed its window.  On a JTAG"
    puts "              configure that is expected.  On a FLASH boot it is the"
    puts "              configuration-time race, and it is the thing to fix."
} elseif {[expr {$vstat & 1}] == 0} {
    puts "PERST_VERDICT the host is HOLDING us in reset right now."
} else {
    puts "PERST_VERDICT we were configured first and then released.  The"
    puts "              endpoint got its chance."
}
puts [format "XDMA    axi_aresetn=%d  ever-released=%d" \
      [expr {($vstat >> 8) & 1}] [expr {($vstat >> 9) & 1}]]
puts [format "LINK    user_lnk_up=%d  ever-up=%d" \
      [expr {($vstat >> 10) & 1}] [expr {($vstat >> 11) & 1}]]
if {[expr {($vstat >> 16) & 0xffff}] != 0xa5a5} {
    puts "AUXPROBE_WARN the fixed 0xA5A5 field reads back wrong; treat every"
    puts "              status bit above as suspect."
}

puts ""
puts "---- autonomous VCCINT controller --------------------------------------"
set target [expr {($vpot >> 24) & 0xff}]
puts [format "POT     target-in-bitstream=%d (0x%02x)  last-read-back=%d" \
      $target $target [expr {($vpot >> 16) & 0xff}]]
puts [format "        done=%d failed=%d owns-bus=%d saw-nack=%d attempts=%d reason=%d" \
      [expr {$vpot & 1}] [expr {($vpot >> 1) & 1}] [expr {($vpot >> 2) & 1}] \
      [expr {($vpot >> 3) & 1}] [expr {($vpot >> 12) & 15}] [expr {($vpot >> 8) & 7}]]
if {$target != 68} {
    puts "POT_VERDICT  REFUSE TO TRUST THIS BITSTREAM.  The hardcoded wiper is"
    puts "             $target, not 68.  68 is the only value reviewed as safe"
    puts "             for this die.  Do not power the card up in a slot."
} elseif {[expr {$vpot & 1}]} {
    puts "POT_VERDICT  the controller ran and verified wiper 68 with no host"
    puts "             and no JTAG.  VCCINT should read ~0.717 V below."
} elseif {[expr {($vpot >> 1) & 1}]} {
    puts "POT_VERDICT  FAILED, reason [expr {($vpot >> 8) & 7}]:"
    puts "             1 = the pot never acknowledged (bus or address wrong)"
    puts "             2 = the wiper read back outside the 60..128 sane band,"
    puts "                 so it deliberately did NOT write"
    puts "             3 = the write was not acknowledged"
    puts "             5 = the read-back did not match 68"
    puts "             6 = timed out and released the bus"
} else {
    puts "POT_VERDICT  still running or not yet started."
}

set th    [rd $aux 4000]
set tt    [rd $aux 4008]
set tpk   [rd $aux 5000]
set ttr   [rd $aux 5008]
set tcan  [rd $aux 6008]

decode_thermal $th $tt $tpk $ttr $tcan

# SYSMON through the JTAG DRP.  This needs no design clock at all and works
# whatever the link is doing, which is why it is here and not read through AXI.
if {[llength [get_hw_sysmons -quiet]]} {
    set sm [lindex [get_hw_sysmons] 0]
    refresh_hw_sysmon -quiet $sm
    puts [format "SYSMON  VCCINT=%.4f V  die=%.1f C  (JTAG DRP, no design clock)" \
          [get_property VCCINT.DATA $sm] [get_property TEMPERATURE.DATA $sm]]
} else {
    puts "SYSMON  not reachable"
}

puts "AUXPROBE_DONE"
close_hw_target
