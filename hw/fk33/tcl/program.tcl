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
set _rows [split [targets] "\n"]
set _dev {}
foreach _r $_rows {
    if {[regexp {^\s*(\d+)\*?\s+(xcvu\S*)} $_r -> _n _name]} {
        lappend _dev [list $_n $_name $_r]
    }
}
if {[llength $_dev] == 0} {
    puts "FPGA_PROG_FAIL: no xcvu target in the xsdb target list:\n[targets]"
    exit 1
}
set _want ""
if {[info exists ::env(FK33_XSDB_TARGET)]} { set _want [string trim $::env(FK33_XSDB_TARGET)] }
if {$_want ne ""} {
    set _hit {}
    foreach _d $_dev { if {[string first $_want [lindex $_d 2]] >= 0} { lappend _hit $_d } }
    if {[llength $_hit] != 1} {
        puts "FPGA_PROG_FAIL: FK33_XSDB_TARGET=$_want matches [llength $_hit] target(s):\n[targets]"
        exit 1
    }
    set _dev $_hit
} elseif {[llength $_dev] > 1} {
    puts "FPGA_PROG_FAIL: REFUSING TO GUESS -- [llength $_dev] configurable targets present"
    puts "  and FK33_XSDB_TARGET is not set.  Configuring the wrong card is how this"
    puts "  project already lost one factory flash image.  Target list:"
    puts [targets]
    exit 1
}
set _sel [lindex $_dev 0]
puts "JTAG target: [lindex $_sel 2]"
targets [lindex $_sel 0]

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
