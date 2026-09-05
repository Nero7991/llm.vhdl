# ooc_mover_paths.tcl -- ATTRIBUTE a mover's critical path by hierarchy.
#
# THE OPEN ITEM THIS CLOSES.  docs/debugging/2026-09-03_b-mover-does-not-fit.md
# ends with "the mover's -4.008 is not attributed ... it is B's top open item",
# and docs/debugging/2026-09-04_c-mover-extracted.md leaves C's -1.611 the same
# way.  Both were measured with report_timing_summary, which gives ONE number
# and names nothing.  A WNS is not an attribution.
#
# WHY A CENSUS AND NOT report_timing.  A single worst path is one path.  The
# question is which HIERARCHY owns the failing endpoints, and that needs the
# whole failing population tallied by parent, because a design can miss timing
# through one pathological path or through ten thousand mediocre ones and the
# two want opposite fixes.  This is the same discipline CLAUDE.md records for
# area: read the census, do not reason from the total.
#
# NO HARDWARE.  synth + report only.  Opens no cable, no target, no device.
#
# env:
#   MOVER_TOP      entity to synthesise (required)
#   MOVER_GENERICS Tcl list of NAME=VALUE (optional)
#   MOVER_RTL      rtl dir (default the repo's)
#   MOVER_PERIOD   ns (default 5.0 = 200 MHz, the card's target)
#   MOVER_MAXP     how many failing paths to tally (default 5000)
set part   xcvu33p-fsvh2104-2L-e
set period [expr {[info exists ::env(MOVER_PERIOD)] ? $::env(MOVER_PERIOD) : 5.0}]
set rtldir [expr {[info exists ::env(MOVER_RTL)] ? $::env(MOVER_RTL) \
                  : "/home/orencollaco/GitHub/llama.vhdl/rtl"}]
set top    $::env(MOVER_TOP)
set maxp   [expr {[info exists ::env(MOVER_MAXP)] ? $::env(MOVER_MAXP) : 5000}]
set gens   [expr {[info exists ::env(MOVER_GENERICS)] ? $::env(MOVER_GENERICS) : ""}]

create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }

set cmd [list synth_design -mode out_of_context -top $top -part $part]
foreach g $gens { lappend cmd -generic $g }
puts "=== $cmd ==="
eval $cmd

create_clock -period $period -name clk [get_ports clk]

set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "MOVERPATH_WNS $top $wns fmax=[expr {1000.0/($period-$wns)}]"

# ---- the census -----------------------------------------------------------
# get_timing_paths with -slack_lesser_than 0 returns the FAILING population.
# -nworst 1 keeps one path per endpoint, so this counts ENDPOINTS and not
# paths: an endpoint reachable ten ways would otherwise be counted ten times
# and would look like ten problems.
set paths [get_timing_paths -max_paths $maxp -nworst 1 -slack_lesser_than 0]
puts "MOVERPATH_FAILING [llength $paths] (cap $maxp)"
if {[llength $paths] == 0} { puts "MOVERPATH_DONE"; return }

# Tally by the endpoint's parent hierarchy, at two depths.  Depth is reported
# rather than chosen, because the right depth is not knowable in advance and a
# single depth can hide the answer either by being too coarse (everything in
# one bucket) or too fine (every endpoint its own bucket).
foreach depth {1 2 3} {
  array unset cnt; array unset worst
  foreach p $paths {
    set ep [get_property ENDPOINT_PIN $p]
    if {$ep eq ""} { continue }
    set nm [get_property NAME $ep]
    set parts [split $nm "/"]
    if {[llength $parts] > $depth} {
      set key [join [lrange $parts 0 [expr {$depth-1}]] "/"]
    } else {
      set key "<top-level>"
    }
    set s [get_property SLACK $p]
    if {![info exists cnt($key)]} { set cnt($key) 0; set worst($key) $s }
    incr cnt($key)
    if {$s < $worst($key)} { set worst($key) $s }
  }
  puts "=== MOVERPATH_CENSUS depth=$depth ==="
  set rows {}
  foreach k [array names cnt] { lappend rows [list $cnt($k) $worst($k) $k] }
  foreach r [lsort -integer -decreasing -index 0 $rows] {
    puts [format "MOVERPATH %6d endpoints  worst %8.3f  %s" \
          [lindex $r 0] [lindex $r 1] [lindex $r 2]]
  }
}

puts "=== the single worst path, for the shape of it ==="
puts [report_timing -max_paths 1 -return_string]
puts "MOVERPATH_DONE"
