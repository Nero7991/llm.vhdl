# ooc_gwtwo_bramcensus.tcl -- TRACK GWTWO, 2026-08-30.
#
# THE RULE THIS EXISTS FOR.  CLAUDE.md: "VIVADO'S INFERENCE LOG LIES IN BOTH
# DIRECTIONS.  Only the mapping report and the primitive census are
# authoritative ... Cross-check report_utilization against an object-level
# get_cells census, and when they disagree the census wins."  This track's
# whole conclusion is a BRAM tile count, so that cross-check is not optional.
#
# WHAT IT ADDS BEYOND A COUNT.  It reports each RAMB36E2/RAMB18E2's configured
# port geometry (READ_WIDTH_A/B, RAM_MODE, CASCADE), which is the MECHANISM
# behind the tile count moving with GW.  A count says the number changed; the
# geometry says why, and a why is what survives to the next shape.
#
# NO HARDWARE.  synth_design and report_* only.  Never opens a target.
#
# USAGE: GWC_RTL=<dir> GWC_OUT=<dir> GWC_TAG=<tag> [GWC_GEN="A=B"] \
#        vivado -mode batch -source sim/ooc_gwtwo_bramcensus.tcl
#
# Prints GWTWO_CENSUS_DONE <tag> as its LAST action.  A Vivado run can print
# full success and then die on a Tcl error afterwards, so the caller MUST gate
# on that sentinel and never on the last log line.

set part   xcvu33p-fsvh2104-2L-e
set period 5.0

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set rtldir [envor GWC_RTL rtl]
set outdir [envor GWC_OUT gwc_out]
set tag    [envor GWC_TAG gwc]
set gens   [envor GWC_GEN ""]
file mkdir $outdir

puts "GWTWO_CENSUS_BEGIN tag=$tag rtl=$rtldir gen=$gens"
create_project -in_memory -part $part
foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[catch {read_vhdl -vhdl2008 $f} e]} { puts "GWC_READ_SKIP $f : $e" }
}
set gl {}
foreach g $gens { lappend gl -generic $g }
# -flatten_hierarchy none, same as every other draw on this scale.  A rebuilt
# hierarchy is not a measurement of any instance.
lappend gl -flatten_hierarchy none
eval synth_design -mode out_of_context -top ooc_normadapt -part $part $gl

set fh [open [file join $outdir bramcensus_$tag.txt] w]
puts $fh "# TRACK GWTWO object-level BRAM census, tag=$tag"
puts $fh "# get_cells -hier -filter {REF_NAME == RAMB36E2 | RAMB18E2}."
puts $fh "# This is the AUTHORITY.  report_utilization's row is quoted beside"
puts $fh "# it, and if the two disagree the census wins."

foreach ref {RAMB36E2 RAMB18E2} {
    set cells [get_cells -hier -filter "REF_NAME == $ref"]
    puts $fh ""
    puts $fh "== $ref  count = [llength $cells]"
    # Group by the parent instance path, so a primitive is attributed to the
    # RTL object that made it rather than to the top.
    array unset byparent
    array unset bygeom
    foreach c $cells {
        set p [join [lrange [split $c /] 0 end-1] /]
        if {$p eq ""} { set p "(top)" }
        # strip the bit index Vivado appends so one RTL object is one row
        regsub -all {\[[0-9]+\]} $p {} p
        if {[info exists byparent($p)]} { incr byparent($p) } else { set byparent($p) 1 }
        set g ""
        foreach prop {RAM_MODE READ_WIDTH_A READ_WIDTH_B WRITE_WIDTH_A WRITE_WIDTH_B CASCADE_ORDER_A} {
            if {![catch {set v [get_property $prop $c]}]} { append g "$prop=$v " }
        }
        if {[info exists bygeom($g)]} { incr bygeom($g) } else { set bygeom($g) 1 }
    }
    foreach p [lsort [array names byparent]] {
        puts $fh [format "  %-60s %6d" $p $byparent($p)]
    }
    puts $fh "  -- configured geometries --"
    foreach g [lsort [array names bygeom]] {
        puts $fh [format "  %6d x  %s" $bygeom($g) $g]
    }
}

# report_utilization beside it, for the disagreement check.
set urpt [report_utilization -return_string]
proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}
set r36 [uget $urpt "RAMB36/FIFO*"]
set r18 [uget $urpt "RAMB18"]
set til [uget $urpt "Block RAM Tile"]
puts $fh ""
puts $fh "# report_utilization says: RAMB36/FIFO*=$r36 RAMB18=$r18 BlockRAMTile=$til"
close $fh

puts "GWTWO_CENSUS tag=$tag ramb36_cells=[llength [get_cells -hier -filter {REF_NAME == RAMB36E2}]] \
ramb18_cells=[llength [get_cells -hier -filter {REF_NAME == RAMB18E2}]] \
rpt_ramb36=$r36 rpt_ramb18=$r18 rpt_tile=$til"
puts "GWTWO_CENSUS_DONE $tag"
