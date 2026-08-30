# pblock_squeeze.tcl -- TRACK TIMING, 2026-08-30.
#
# THE QUESTION.  The step that turns a survivable 95.6% LUT into 121% CLB is
# the 6.32 LUT/CLB divisor, and that is an n=1 measurement taken on a placement
# that had THE WHOLE DIE FREE.  A placer with room to spread will spread, so
# 6.32 may be a behaviour of an unconstrained run rather than a property of the
# netlist.  If it is elastic, the 121% collapses and the fit question reopens.
#
# THE EXPERIMENT.  Place the SAME synthesis checkpoint inside a pblock holding
# about 85% of the die's CLBs and see what density it reaches.
#
#   PREDICTION FROM THE CLAIM: place_design FAILS, or density stays near 6.32.
#   FALSIFIED IF: the same netlist packs into <= 48,000 CLBs.
#
# A PLACER FAILURE IS A RESULT, NOT AN ERROR.  It is the outcome that CONFIRMS
# the claim, so place_design is wrapped in catch and every exit path reports.
#
# NO HARDWARE.  open_checkpoint / place_design / report_* only.

proc envdef {n d} { if {[info exists ::env($n)]} { return $::env($n) }; return $d }
set dcp    [envdef PS_DCP /mnt/storage/compose4/out/c4_synth.dcp]
set outdir [envdef PS_OUT /mnt/storage/timing_track/out]
set frac   [envdef PS_FRAC 0.85]
file mkdir $outdir
set_param general.maxThreads 8

puts "PS_BEGIN dcp=$dcp frac=$frac"
flush stdout
open_checkpoint $dcp
puts "PS_OPENED"

# Device-wide CLB total, MEASURED from the device rather than assumed.
set all_clb [llength [get_sites -quiet -filter {SITE_TYPE =~ SLICE*}]]
puts "PS_DEVICE_CLB $all_clb"
set target [expr {int($all_clb * $frac)}]
puts "PS_TARGET_CLB $target"
flush stdout

# Count CLBs per clock region, then take regions in column-major order until the
# target is reached.  Column-major keeps the region contiguous-ish, which is
# what a real floorplan would do; a scattered pblock would test something else.
set rows {}
foreach cr [get_clock_regions] {
    set n [llength [get_sites -quiet -of_objects $cr -filter {SITE_TYPE =~ SLICE*}]]
    if {$n > 0} { lappend rows [list [get_property NAME $cr] $n] }
}
set rows [lsort -index 0 $rows]
set chosen {}
set acc 0
foreach r $rows {
    if {$acc >= $target} break
    lappend chosen [lindex $r 0]
    incr acc [lindex $r 1]
}
puts "PS_CHOSEN_REGIONS [llength $chosen] of [llength $rows] : $chosen"
puts "PS_CHOSEN_CLB $acc  ([format %.1f [expr {100.0*$acc/$all_clb}]]% of device)"
flush stdout

create_pblock pb_squeeze
add_cells_to_pblock [get_pblocks pb_squeeze] \
    [get_cells -quiet -filter {IS_PRIMITIVE == 0}] -clear_locs
foreach cr $chosen { resize_pblock [get_pblocks pb_squeeze] -add $cr }
report_utilization -pblocks [get_pblocks pb_squeeze] \
    -file [file join $outdir pbutil_squeeze_pre.rpt]

set t0 [clock seconds]
set rc [catch {place_design} perr]
puts "PS_PLACE_SECONDS [expr {[clock seconds] - $t0}]"
puts "PS_PLACE_RC $rc"
if {$rc} {
    puts "PS_PLACE_FAILED -- THIS CONFIRMS THE CLAIM"
    puts "PS_PLACE_ERROR $perr"
    flush stdout
    puts "PS_DONE squeeze"
    return
}

report_utilization -file [file join $outdir util_squeeze_placed.rpt]
report_utilization -pblocks [get_pblocks pb_squeeze] \
    -file [file join $outdir pbutil_squeeze_placed.rpt]
set u [report_utilization -return_string]
proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}
set lut [uget $u "CLB LUTs*"]
if {$lut eq "NA"} { set lut [uget $u "CLB LUTs"] }
set clb [uget $u "CLB"]
puts "PS_UTIL lut $lut clb $clb f7 [uget $u {F7 Muxes}] f8 [uget $u {F8 Muxes}]"
if {$clb ne "NA" && $clb > 0} {
    puts "PS_DENSITY [format %.3f [expr {double($lut)/double($clb)}]] LUT per CLB"
}
report_timing_summary -file [file join $outdir timing_squeeze_placed.rpt]
set p [get_timing_paths -delay_type max -max_paths 1]
puts "PS_WNS [get_property SLACK $p]"
write_checkpoint -force [file join $outdir squeeze_placed.dcp]
puts "PS_DONE squeeze"
