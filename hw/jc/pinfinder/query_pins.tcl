# hw/jc/pinfinder/query_pins.tcl -- vivado -mode batch -source query_pins.tcl
#   -tclargs [part]
#
# One-off part-database query (no project, no files): resolves the LVDS
# diff-pair partner of the three P pins this design repurposes, and their
# I/O bank, so the answer can be hardcoded into pinfinder.xdc with a comment
# citing this query (same convention as hw/jc/census/jc_census.xdc's refclk
# pins). Same link_design -part pattern as
# docs/boards/jungle-cat/pinq_aurora_refclk.tcl.
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xcvu35p-fsvh2104-2L-e"}]
link_design -part $part
foreach p {BC26 G10 F13 K10 K9 J9 J10 K11 L12 L11} {
  set pp [get_package_pins $p]
  set np [get_property DIFF_PAIR_PIN $pp]
  set bk [get_property BANK $pp]
  puts "PINFINDER_NPIN $p -> $np bank=$bk"
}
puts "PINFINDER_PINQ_DONE"
