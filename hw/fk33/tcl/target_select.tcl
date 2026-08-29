# ONE PLACE THAT DECIDES WHICH CARD A HARDWARE OPERATION LANDS ON.
#
# WHY THIS FILE EXISTS.  Every script in this directory used to open the JTAG
# target by BARE INDEX -- fourteen of them as `[lindex [get_hw_targets] 0]` and
# tcl/program.tcl as xsdb's `targets 1`.  With exactly one card on the chain
# that is unambiguous and it worked for months.  A SECOND FK33 arrived on
# 2026-08-29, and an index is then whatever order the enumeration happened to
# come back in.
#
# WHAT THAT WOULD COST.  The scripts selecting by index include tcl/vccint_step
# (sets the core voltage), tcl/flash_common and tcl/flash_status (write and read
# the SPI flash), tcl/i2cbang (drives the I2C bus) and tcl/program (configures
# the device).  An agent already destroyed card 1's SQRL factory flash image by
# aiming a flash operation at the wrong thing; card 2's copy of that image is
# now the ONLY surviving one, and it is card 1's restore path.  An index that
# silently means "whichever card answered first" is the same defect class
# pointed at the last remaining backup.
#
# THE RULE.  Refuse rather than guess.  With one target, proceed.  With more
# than one and no explicit selection, ABORT and print the list -- do NOT fall
# back to index 0, because a fallback is exactly what makes the hazard silent.
#
# HOW TO SELECT.  Two SEPARATE variables, and that separation is load bearing:
#
#     FK33_TARGET=210308B0A123 ./flash.sh --status   # substring of the name
#     FK33_TARGET_INDEX=0      ./flash.sh --status   # index, deliberately
#
# WHY NOT ONE VARIABLE.  The first version of this file took a bare integer in
# FK33_TARGET as an index and everything else as a substring, and its own
# teeth-check killed it: `string is integer -strict` is TRUE for an all-digits
# SERIAL, so FK33_TARGET=210308 was read as index 210308.  Out of range it
# refuses, which is survivable -- but FK33_TARGET=1, meaning "the card whose
# serial contains a 1", would have silently selected card index 1.  That is
# precisely the silent-wrong-card failure this file exists to remove, so the
# convenience of overloading one variable is not available.
#
# Setting both is an error.  Guessing which one the operator meant is the same
# mistake one level up.

proc fk33_target_list {} {
    if {[catch {get_hw_targets} all]} {
        error "get_hw_targets failed: $all\nIs hw_server running, and does anything else hold the FTDI?"
    }
    return $all
}

# Return the single target to act on, or raise. Does not open it.
proc fk33_pick_target {} {
    set all [fk33_target_list]
    set n   [llength $all]

    if {$n == 0} {
        error "NO JTAG TARGETS.  Cable unplugged, hw_server not running, or another\n       process (Vivado, xsdb, an old hw_server) still holds the FTDI."
    }

    set want ""
    set widx ""
    if {[info exists ::env(FK33_TARGET)]}       { set want [string trim $::env(FK33_TARGET)] }
    if {[info exists ::env(FK33_TARGET_INDEX)]} { set widx [string trim $::env(FK33_TARGET_INDEX)] }

    if {$want ne "" && $widx ne ""} {
        error "FK33_TARGET=$want and FK33_TARGET_INDEX=$widx are both set.\n       Set exactly one; choosing between them would be a guess."
    }

    if {$widx ne ""} {
        if {![string is integer -strict $widx]} {
            error "FK33_TARGET_INDEX=$widx is not an integer.  Use FK33_TARGET for a name substring."
        }
        if {$widx < 0 || $widx >= $n} {
            error "FK33_TARGET_INDEX=$widx is out of range: $n target(s) present, valid 0..[expr {$n-1}]."
        }
        return [lindex $all $widx]
    }

    if {$want eq ""} {
        if {$n == 1} { return [lindex $all 0] }
        set msg "REFUSING TO GUESS: $n JTAG targets are present and FK33_TARGET is not set.\n"
        append msg "       Selecting by index would act on an arbitrary card, and this\n"
        append msg "       directory contains flash, voltage and configuration operations.\n\n"
        for {set i 0} {$i < $n} {incr i} {
            append msg "         \[$i\] [lindex $all $i]\n"
        }
        append msg "\n       Re-run with FK33_TARGET=<substring above>, or FK33_TARGET_INDEX=<n>."
        error $msg
    }

    # FK33_TARGET is ALWAYS a substring, never an index, however numeric it
    # looks.  See the note at the top of this file for the measurement that
    # forced that rule.
    set hit {}
    foreach t $all { if {[string first $want $t] >= 0} { lappend hit $t } }
    if {[llength $hit] == 0} {
        set msg "FK33_TARGET=$want matches none of the $n target(s) present:\n"
        foreach t $all { append msg "         $t\n" }
        error $msg
    }
    if {[llength $hit] > 1} {
        set msg "FK33_TARGET=$want is AMBIGUOUS, [llength $hit] targets match:\n"
        foreach t $hit { append msg "         $t\n" }
        error $msg
    }
    return [lindex $hit 0]
}

# Pick and open. Prints what it chose, ALWAYS -- a hardware operation should
# never be silent about which device it landed on.
proc fk33_open_target {} {
    set t [fk33_pick_target]
    puts "JTAG target: $t"
    open_hw_target $t
    return $t
}
