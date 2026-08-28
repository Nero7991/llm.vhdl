# Configure the FK33 under xsdb.  Must be xsdb, not Vivado: the Vivado hardware
# manager has no 'fpga' command, and its program_hw_devices enforces the ES1
# revision check and refuses this die ("target device (with IDCODE revision 0)
# is compatible with es1 revision bitstreams") with no way to waive it.
# The IDCODE itself matches xcvu33p, so the check is spurious here.
connect
targets 1
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
