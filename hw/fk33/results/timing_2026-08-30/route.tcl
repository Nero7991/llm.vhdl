# route.tcl -- TRACK TIMING, 2026-08-30.
#
# Resume TRACK COMPOSE4's implementation from the PLACED checkpoint that
# survived the 2026-08-30 01:25 box hang.  The original run died inside
# route_design Phase 4.1 (Rip-up And Reroute) when the machine went down under
# six concurrent Vivado processes; place_design's 1,638 s is already paid.
#
# NO HARDWARE.  open_checkpoint / phys_opt_design / route_design / report_*
# and write_checkpoint only.  Nothing here opens a cable, a target, or
# /dev/xdma*.
#
# THE CHECKPOINT IS PRE-phys_opt: ooc_compose4_pnr.tcl writes
# c4dev_placed.dcp and THEN runs phys_opt_design, so phys_opt is re-run here
# to reproduce the same state the lost run reached.
#
# ONE VIVADO ON THIS BOX.  MEASURED peak of the lost place+route run: 16.7 GiB
# (impl_dev.mem).  The box has ~25 GiB available.  It fits, once.
#
# EVERY STAGE PRINTS A SENTINEL.  Vivado can print full success and then die
# on a Tcl error afterwards; gate on the sentinel, never on the exit code.

proc envdef {name dflt} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $dflt
}
set dcp    [envdef TT_DCP /mnt/storage/compose4/out/c4dev_placed.dcp]
set outdir [envdef TT_OUT /mnt/storage/timing_track/out]
set tag    [envdef TT_TAG c4dev]
file mkdir $outdir
set_param general.maxThreads 8

puts "TT_BEGIN route dcp=$dcp"
flush stdout
open_checkpoint $dcp
puts "TT_OPENED"
flush stdout

# ---------------------------------------------------------------------------
# WHERE THE CLBs GO.  Asked here rather than in a second Vivado because only
# one may run on this box.  The hypothesis under test: the F7/F8 mux
# population (65,108 + 25,788) is what drives CLB occupancy to 99.83% while
# LUT occupancy is only 78.91%, because an F7/F8 pair fixes which LUTs must
# sit together and Vivado places those as indivisible shapes.  If that is
# right the muxes concentrate in the units that do RUNTIME-INDEXED slicing of
# wide flat vectors, and the report below says which.
puts "\n===== TT: F7/F8 MUX POPULATION BY TOP-LEVEL INSTANCE ====="
foreach ref {MUXF7 MUXF8} {
    array unset acc
    array set acc {}
    foreach c [get_cells -quiet -hier -filter "REF_NAME == $ref"] {
        set f [split $c "/"]
        set k [lindex $f 0]
        if {[llength $f] > 1} { set k "[lindex $f 0]/[lindex $f 1]" }
        if {![info exists acc($k)]} { set acc($k) 0 }
        incr acc($k)
    }
    set rows {}
    foreach k [array names acc] { lappend rows [list $acc($k) $k] }
    set j 0
    foreach r [lsort -integer -decreasing -index 0 $rows] {
        if {$j >= 15} break
        puts [format "TT_MUX %-6s %7d  %s" $ref [lindex $r 0] [lindex $r 1]]
        incr j
    }
}
flush stdout

# ---------------------------------------------------------------------------
set t0 [clock seconds]
phys_opt_design -quiet
puts "TT_PHYSOPT_SECONDS [expr {[clock seconds] - $t0}]"
report_timing_summary -file [file join $outdir timing_${tag}_physopt.rpt]
set p [get_timing_paths -delay_type max -max_paths 1]
puts "TT_PHYSOPT_WNS [get_property SLACK $p]"
write_checkpoint -force [file join $outdir ${tag}_physopt.dcp]
puts "TT_CKPT physopt"
flush stdout

# ---------------------------------------------------------------------------
set t0 [clock seconds]
set rc [catch {route_design} rerr]
puts "TT_ROUTE_SECONDS [expr {[clock seconds] - $t0}]"
puts "TT_ROUTE_RC $rc"
if {$rc} { puts "TT_ROUTE_ERROR $rerr" }
flush stdout

# Reports are emitted whether or not route_design threw, because a design that
# fails to route is exactly the measured, specific failure this is for.
report_utilization -file [file join $outdir util_${tag}_routed.rpt]
report_utilization -hierarchical \
    -file [file join $outdir util_hier_${tag}_routed.rpt]
report_timing_summary -file [file join $outdir timing_${tag}_routed.rpt]
report_route_status   -file [file join $outdir route_status_${tag}.rpt]
report_drc            -file [file join $outdir drc_${tag}.rpt]
report_design_analysis -congestion \
    -file [file join $outdir congestion_${tag}_routed.rpt]
write_checkpoint -force [file join $outdir ${tag}_routed.dcp]

# ROUTE STATUS, COUNTED.  This top is OUT OF CONTEXT and its 1,180 non-clock
# ports have no buffers, so nets attached to them CANNOT be fully routed and
# Vivado reports them.  That is expected and is NOT a routing failure; a net
# with ROUTE_STATUS ANTENNAS or CONFLICTS is.  Counted separately, because
# reporting "0 nets with routing errors" out of a report that also lists
# thousands of unrouted port nets is the silent-success claim this project
# keeps finding.
set n_err  [llength [get_nets -quiet -hier -filter \
    {ROUTE_STATUS == ANTENNAS || ROUTE_STATUS == CONFLICTS || ROUTE_STATUS == HIERPORT}]]
set n_unr  [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED}]]
set n_part [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == PARTIAL}]]
set n_all  [llength [get_nets -quiet -hier]]
puts "TT_ROUTE_STATUS nets=$n_all errors=$n_err unrouted=$n_unr partial=$n_part"

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "TT_TIMING wns=$wns whs=$whs"
foreach c [get_clocks] {
    set p [get_timing_paths -to [get_clocks $c] -delay_type max -max_paths 1]
    if {[llength $p]} {
        puts "TT_CLKWNS [get_property NAME $c] period=[get_property PERIOD $c]\
 wns=[get_property SLACK $p]"
    }
}
puts "TT_DONE route $tag"
