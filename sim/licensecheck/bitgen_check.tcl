# Can this Vivado install actually GENERATE A BITSTREAM for the FK33's part?
#
# Everything done on xcvu33p so far has been synthesis and place-and-route.
# write_bitstream is a SEPARATELY licensed feature, and docs/fpga-hardware-recon.md
# recorded a license warning naming device 'xcvu33p'.  If bitstream generation is
# not covered, the card is unusable on arrival and no amount of RTL work helps --
# so this is worth knowing before the card is plugged in rather than after.
#
# Deliberately a TRIVIAL design: it exercises the same licensed feature as a real
# build while using a fraction of the memory.  A full FK33 example build could
# take 16 GB+ and would be competing with the 2-hour A-format model build for RAM
# on a 31 GB box that has OOM-killed the code-server cgroup before.
create_project -in_memory -part xcvu33p-fsvh2104-2L-e
set src [file join [file dirname [info script]] tiny.v]
read_verilog $src
synth_design -top tiny -part xcvu33p-fsvh2104-2L-e

# Unconstrained I/O is an ERROR for bitstream generation.  Downgrade it: the
# question here is licensing, not pinout, and inventing a pinout would only add a
# way for this check to fail for the wrong reason.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property BITSTREAM.General.UnconstrainedPins {Allow} [current_design]

opt_design -quiet
place_design
route_design
set bit [file join [file dirname [info script]] tiny.bit]
if {[catch {write_bitstream -force $bit} err]} {
  puts "BITGEN_RESULT FAIL: $err"
} else {
  puts "BITGEN_RESULT OK: [file size $bit] bytes"
}
puts "BITGEN_DONE"
