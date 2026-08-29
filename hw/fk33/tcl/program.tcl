# Configure the FK33 under xsdb.  Must be xsdb, not Vivado: the Vivado hardware
# manager has no 'fpga' command, and its program_hw_devices enforces the ES1
# revision check and refuses this die ("target device (with IDCODE revision 0)
# is compatible with es1 revision bitstreams") with no way to waive it.
# The IDCODE itself matches xcvu33p, so the check is spurious here.
connect

# `targets 1` WAS HERE, AND IT SELECTED THE CARD BY BARE INDEX.  Unambiguous
# with one card; with the second FK33 that arrived 2026-08-29 the index is
# whatever order enumeration returned.  This is xsdb, not Vivado, so it cannot
# use tcl/target_select.tcl (that file speaks get_hw_targets / open_hw_target);
# the rule is reimplemented here against xsdb's own `targets` list.
#
# REFUSE RATHER THAN GUESS.  With one matching target, proceed.  With more than
# one and no FK33_XSDB_TARGET, abort and print the list.  No fallback to index,
# because a fallback is what makes the hazard silent.
# SELECT BY CABLE SERIAL, VIA -filter.  REFUSE RATHER THAN GUESS.
#
# THE FIRST VERSION OF THIS BLOCK COULD NEVER MATCH.  It scanned the rows of
# `targets` for the serial, but xsdb's DEBUG target names are just "xcvu33p" /
# "Legacy Debug Hub" / "JTAG2AXI" -- the serial lives on the JTAG CABLE, which
# `targets` does not print at all.  So FK33_XSDB_TARGET=153300000607A matched
# 0 of 2 rows and refused every run.  MEASURED 2026-08-29 against both cards.
# The guard failing safe is the only reason that was merely annoying.
#
# `jtag targets` does carry it ("Xilinx SQRL FK 153300000607A"), and the two
# lists are in corresponding order -- but relying on that ordinal
# correspondence is exactly the guess this file exists to remove.  xsdb exposes
# the cable on every debug target as `jtag_cable_name`, so filter on it.
#
# Teeth-checked on real hardware, both cards plus a negative:
#   *0607A* -> [3 xcvu33p]   (the card with 3 JTAG2AXI, i.e. the endpoint)
#   *1366A* -> [1 xcvu33p]
#   *999999999* -> []        (empty, so the refusal below fires)
set _want ""
if {[info exists ::env(FK33_XSDB_TARGET)]} { set _want [string trim $::env(FK33_XSDB_TARGET)] }

set _all [targets -filter {name =~ "xcvu33p"}]
set _nall [llength [split [string trim $_all] "\n"]]
if {[string trim $_all] eq ""} {
    puts "FPGA_PROG_FAIL: no xcvu target in the xsdb target list:\n[targets]"
    exit 1
}

if {$_want ne ""} {
    if {[catch {targets -filter "name =~ \"xcvu33p\" && jtag_cable_name =~ \"*$_want*\""} _hit]} {
        puts "FPGA_PROG_FAIL: target filter failed: $_hit"
        exit 1
    }
    set _rows [split [string trim $_hit] "\n"]
    if {[string trim $_hit] eq "" || [llength $_rows] != 1} {
        puts "FPGA_PROG_FAIL: FK33_XSDB_TARGET=$_want matches [expr {[string trim $_hit] eq "" ? 0 : [llength $_rows]}] of $_nall xcvu targets."
        puts "  Cables present (the serial lives here, not in `targets`):"
        puts [jtag targets]
        exit 1
    }
    if {![regexp {^\s*(\d+)} [lindex $_rows 0] -> _n]} {
        puts "FPGA_PROG_FAIL: could not parse a target id from: [lindex $_rows 0]"
        exit 1
    }
} else {
    if {$_nall > 1} {
        puts "FPGA_PROG_FAIL: REFUSING TO GUESS -- $_nall configurable targets present"
        puts "  and FK33_XSDB_TARGET is not set.  Configuring the wrong card is how this"
        puts "  project already lost one factory flash image.  Cables:"
        puts [jtag targets]
        exit 1
    }
    if {![regexp {^\s*(\d+)} [string trim $_all] -> _n]} {
        puts "FPGA_PROG_FAIL: could not parse a target id from: $_all"
        exit 1
    }
}
puts "JTAG target: id $_n  (selector '${_want}')"
targets $_n

set bit $::env(FK33_BIT)
if {[catch {fpga -no-revision-check -file $bit} err]} {
    puts "FPGA_PROG_FAIL: $err"
    exit 1
}
puts "FPGA_PROG_OK"
puts [targets]

# xsdb DROPS TO AN INTERACTIVE PROMPT at end of script and waits on stdin.
# The failure path above exits; this one did not, so a successful configure
# hung until pcieep.sh's `timeout 300` killed it, and `set -euo pipefail`
# then aborted the whole sequence with EXIT=124 -- after FPGA_PROG_OK had
# already printed, so it read as "programming worked, then nothing happened".
# It only ever appeared to work when stdin was not a tty (xsdb sees EOF and
# leaves on its own); run by hand from a terminal it hangs every time.
# `vivado -mode batch` does NOT need this, which is why tcl/vccint_step.tcl
# and tcl/pcieep_jtag.tcl get away with having no success-path exit.
exit 0
