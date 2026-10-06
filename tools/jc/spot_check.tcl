# Independent HBM readback for the Jungle Cat loader (plan Task 11). MAIN SESSION ONLY:
# this opens the JTAG path. It reads windows through the jtag_axi master named *jtag_hbm*
# (BSCAN user chain 1, HBM port SAXI_16; selected by CELL_NAME, the hw_axi NAME is generic), which shares nothing with the loader (USER4,
# its own AXI master and HBM port), and prints one SPOT line per window for
# spot_check_compare.py.
# Usage: vivado -mode batch -source spot_check.tcl -tclargs <addr_file> <die_dna_hex> <out_file> <ltx>
#   addr_file: one hex HBM address per line (256-byte windows, 32-byte aligned)
#   die_dna_hex: the target die's DNA as in the die record (24 hex digits); the device is
#                chosen by matching Vivado's REGISTER.DNA.SLR0 (the SLR holding the loader's
#                DNA_PORTE2, MEASURED 2026-10-05), never by list position
#   ltx: the bitstream's debug-probes file, so the jtag_axi masters carry their BD names
# Prereq: sqrl_bridge with XVC on 2542 (5th arg) and hw_server on localhost:3121.
set addr_file [lindex $argv 0]; set want_dna [string tolower [lindex $argv 1]]
set out_file [lindex $argv 2]; set ltx [lindex $argv 3]
set BEATS 32   ;# jtag_hbm is 64 bits wide (MEASURED AXI_DATA_WIDTH), 32 beats = 256 bytes
open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set a 1} {$a <= 8} {incr a} {
  if {![catch {open_hw_target -xvc_url localhost:2542} err]} { set ok 1; break }
  puts "SPOT_OPEN_RETRY $a: $err"; catch {close_hw_target}; after 3000
}
if {!$ok} { puts "SPOT_NO_TARGET"; exit 1 }
set dev ""
foreach d [get_hw_devices] {
  refresh_hw_device -quiet $d
  set dna [string tolower [get_property REGISTER.DNA.SLR0 $d]]
  if {[string range $dna end-23 end] eq $want_dna} { set dev $d }
}
if {$dev eq ""} { puts "SPOT_NO_DEVICE_WITH_DNA"; exit 1 }
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
refresh_hw_device -quiet $dev
set axi [get_hw_axis -quiet -of_objects $dev -filter {CELL_NAME =~ *jtag_hbm}]
if {[llength $axi] != 1} { puts "SPOT_HW_AXI_NOT_UNIQUE [get_hw_axis]"; exit 1 }
puts "SPOT_DEVICE $dev AXI $axi"
set fi [open $addr_file r]; set fo [open $out_file w]
set n 0
while {[gets $fi line] >= 0} {
  set line [string trim $line]; if {$line eq ""} continue
  delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet rtx]
  create_hw_axi_txn rtx $axi -address $line -len $BEATS -type read
  run_hw_axi -quiet [get_hw_axi_txns rtx]
  puts $fo "SPOT $line [get_property DATA [get_hw_axi_txns rtx]]"
  incr n
}
close $fo; close $fi
puts "SPOT_DONE $n"
