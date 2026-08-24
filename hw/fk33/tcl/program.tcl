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
