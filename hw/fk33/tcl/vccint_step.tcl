# Raise FK33 VCCINT from its 0.678 V power-up default toward 0.720 V by stepping
# the MCP45XX-class digital pot at I2C 0x2c, verifying on SYSMON after EVERY
# single step.
#
# Target 0.720 V, not SQRL's 0.850 V: 0.698-0.742 V is in spec for BOTH -2L and
# -2LV, so it is safe under every remaining hypothesis about this ES1 die, and
# it validates our model of the pot at low stakes first.
#
# The write is to command 0x00 = VOLATILE wiper 0, so a power cycle restores the
# factory 128 and 0.678 V.  Nothing here is permanent.
#
# SAFETY, enforced in code rather than by care:
#   * the FIRST move is one step in the WRONG direction (wiper UP = voltage
#     DOWN).  That proves the write path, the readback and the sign of dV/dstep
#     while moving AWAY from overvoltage.  If that does not behave, we stop
#     having risked nothing.
#   * every step is followed by a wiper readback AND a SYSMON read;
#   * ABORT and revert to 128 if: VCCINT exceeds V_CEILING, a single step moves
#     more than DV_MAX, the wiper does not read back what we wrote, or VCCINT
#     moves the wrong way;
#   * step size is capped, and shrinks as we approach the target.

source [file join [file dirname [info script]] target_select.tcl]

set POT      0x2c
set W_START  128
set V_TARGET 0.720
set V_ACCEPT_LO 0.716
set V_ACCEPT_HI 0.728
set V_CEILING   0.760   ;# hard abort, well under the 0.825 V floor of -1/-2
set DV_MAX      0.035   ;# a single step must never move the rail more than this
set W_STEP_MAX  4
set W_FLOOR     60      ;# never go below this wiper, whatever the readings say

open_hw_manager
connect_hw_server -allow_non_jtag
fk33_open_target
set d [lindex [get_hw_devices] 0]
current_hw_device $d
refresh_hw_device -quiet $d
set ax [get_hw_axis hw_axi_1]

proc wr {addr data} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -data $data -type write
    run_hw_axi -quiet [get_hw_axi_txns t]
}
proc rdreg {addr} {
    global ax
    create_hw_axi_txn -quiet -force t $ax -address $addr -type read
    run_hw_axi -quiet [get_hw_axi_txns t]
    return [lindex [report_hw_axi_txn -t d4 [get_hw_axi_txns t]] 1]
}
set TRI 0x00009004
set DAT 0x00009000
proc lines {scl sda} { wr $::TRI [format 0x%08x [expr {($scl ? 1 : 0) | ($sda ? 2 : 0)}]] }
proc sda_in {} { return [expr {([rdreg $::DAT] >> 1) & 1}] }
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
    for {set i 0} {$i < 8} {incr i} { set v [expr {($v << 1) | [i2c_rbit]}] }
    i2c_wbit [expr {$ack ? 0 : 1}]
    return $v
}
# MCP45XX volatile wiper 0: [addr+W][cmd 0x00 | d9:d8][d7:d0].  Values here are
# all < 256, so the command byte is always 0x00.
proc pot_write {a v} {
    if {$v < 0 || $v > 255} { error "wiper $v out of range" }
    i2c_start
    set k [i2c_wbyte [expr {($a << 1) & 0xfe}]]
    set k [expr {$k + [i2c_wbyte 0x00] + [i2c_wbyte $v]}]
    i2c_stop
    return $k   ;# 0 means every byte was acknowledged
}
proc pot_read {a} {
    i2c_start
    if {[i2c_wbyte [expr {($a << 1) | 1}]] != 0} { i2c_stop; return -1 }
    set hi [i2c_rbyte 1]
    set lo [i2c_rbyte 0]
    i2c_stop
    return [expr {($hi << 8) | $lo}]
}
proc vccint {} {
    # median of 3 SYSMON reads, to reject a single bad sample
    set s {}
    for {set i 0} {$i < 3} {incr i} { lappend s [expr {[rdreg 3404] * 3.0 / 65536.0}] }
    return [lindex [lsort -real $s] 1]
}
proc dietemp {} { return [expr {[rdreg 3400] * 507.6 / 65536.0 - 279.43}] }

wr $DAT 0x00000000
lines 1 1

set w0 [pot_read $POT]
set v0 [vccint]
puts [format "START   wiper=%d  VCCINT=%.4f V  die=%.1f C" $w0 $v0 [dietemp]]
# Resume from wherever the wiper is, but refuse to start from anywhere outside a
# sane band: below W_FLOOR we would already be in the steep, dangerous region,
# and above 128 something has gone wrong.
if {$w0 < $W_FLOOR || $w0 > 128} {
    puts "ABORT: wiper reads $w0, outside the sane band $W_FLOOR..128. Not touching anything."
    lines 1 1; close_hw_target; exit 1
}
set W_REVERT 128
set W_START $w0

proc revert {why} {
    global POT W_REVERT
    puts "ABORT: $why"
    puts "  reverting wiper to the factory default $W_REVERT"
    pot_write $POT $W_REVERT
    after 200
    puts [format "  wiper now %d, VCCINT %.4f V" [pot_read $POT] [vccint]]
    lines 1 1
    close_hw_target
    exit 1
}

# ---- SAFETY PROBE: one step in the WRONG direction first.
puts ""
puts "SAFETY PROBE: stepping wiper UP (expected to LOWER the rail), so that if"
puts "              anything is misunderstood we find out while moving away"
puts "              from overvoltage."
if {[pot_write $POT [expr {$W_START + 4}]] != 0} { revert "pot did not acknowledge the write" }
after 300
set wp [pot_read $POT]
set vp [vccint]
puts [format "  wiper=%d (wrote %d)  VCCINT=%.4f V   delta=%+.4f V" $wp [expr {$W_START+4}] $vp [expr {$vp - $v0}]]
if {$wp != $W_START + 4} { revert "wiper did not read back what was written (got $wp)" }
if {$vp >= $v0} {
    revert [format "raising the wiper did NOT lower the rail (%.4f -> %.4f). The sign of dV/dwiper is not what we assumed." $v0 $vp]
}
set dv_per_step [expr {abs($vp - $v0) / 4.0}]
puts [format "  CONFIRMED: lower wiper = higher voltage.  sensitivity ~%.4f V per step" $dv_per_step]

pot_write $POT $W_START
after 300
puts [format "  restored wiper=%d  VCCINT=%.4f V" [pot_read $POT] [vccint]]

# ---- Now step down toward the target.
puts ""
puts "STEPPING DOWN toward $V_TARGET V (ceiling $V_CEILING V, max ${DV_MAX} V per step)"
set w $W_START
set vprev [vccint]
while {1} {
    set v [vccint]
    if {$v >= $V_ACCEPT_LO && $v <= $V_ACCEPT_HI} {
        puts [format "REACHED TARGET: wiper=%d  VCCINT=%.4f V" $w $v]
        break
    }
    if {$v > $V_ACCEPT_HI} { revert [format "overshot: %.4f V > %.4f V" $v $V_ACCEPT_HI] }

    # choose a step: never more than W_STEP_MAX, and shrink near the target
    set need [expr {$V_TARGET - $v}]
    set est  [expr {$dv_per_step > 0 ? int($need / $dv_per_step) : 1}]
    if {$est < 1} { set est 1 }
    if {$est > $W_STEP_MAX} { set est $W_STEP_MAX }
    set wnext [expr {$w - $est}]
    if {$wnext < $W_FLOOR} { revert "would step below the wiper floor $W_FLOOR" }

    if {[pot_write $POT $wnext] != 0} { revert "pot did not acknowledge write of $wnext" }
    after 300
    set wrb [pot_read $POT]
    if {$wrb != $wnext} { revert "wiper readback $wrb != written $wnext" }
    set v [vccint]
    set dv [expr {$v - $vprev}]
    puts [format "  wiper %3d -> %3d   VCCINT=%.4f V  (%+.4f V)  die=%.1f C" $w $wnext $v $dv [dietemp]]
    if {$v > $V_CEILING} { revert [format "VCCINT %.4f V exceeded ceiling %.4f V" $v $V_CEILING] }
    if {abs($dv) > $DV_MAX} { revert [format "single step moved the rail %.4f V, more than %.4f V" $dv $DV_MAX] }
    if {$dv < 0} { revert [format "rail moved the WRONG WAY (%+.4f V) on a downward wiper step" $dv] }
    set w $wnext
    set vprev $v
}

puts ""
puts "FINAL STATE"
puts [format "  wiper   = %d  (power-up default 128)" [pot_read $POT]]
puts [format "  VCCINT  = %.4f V" [vccint]]
puts [format "  VCCBRAM = %.4f V" [expr {[rdreg 3418] * 3.0 / 65536.0}]]
puts [format "  die     = %.1f C" [dietemp]]
set flag [rdreg 34fc]
puts [format "  SYSMON FLAG_REG = 0x%04x  (bit1 VCCINT alarm = %d)" $flag [expr {($flag >> 1) & 1}]]
puts "  NOTE: this is the VOLATILE wiper. A power cycle restores 128 and 0.678 V."
lines 1 1
close_hw_target
puts "STEP_DONE"
