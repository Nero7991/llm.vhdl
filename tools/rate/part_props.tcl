# tools/rate/part_props.tcl -- print resource counts of each part named in argv.
# Property names checked against `report_property [get_parts ...]` (plan Task 1 Step 5).
foreach p $argv {
  set o [get_parts -quiet $p]
  if {[llength $o] != 1} { puts "PARTPROP_MISSING $p"; continue }
  puts [format "PARTPROP %s LUT %s FF %s BRAM %s URAM %s DSP %s" $p \
        [get_property LUT_ELEMENTS $o] [get_property FLIPFLOPS $o] \
        [get_property BLOCK_RAMS $o] [get_property ULTRA_RAMS $o] [get_property DSP $o]]
}
puts "PARTPROP_DONE"
