# hw/jc/a450/a450_pblocks.tcl -- spec 1.2's placement: one pblock per tile COLUMN, in
# SLR0 directly above the tiles' HBM ports.  For an OPENED, linked design.
#
#   proc a450_pblocks <fast_re> <hbm_glob> <portmap>
#     fast_re    a REGEXP for the mv_afast instance, e.g. {.*/g_split\.u/fast}
#     hbm_glob   the HBM IP instance prefix, e.g. "*/hbm/*"
#     portmap    the SAXI number of weight tile p, p = 0..23 (scale ports are not tiles)
# For each tile p, re-derived from the NETLIST rather than from the block design's text:
#   the tile cell (fast/g_t[p].tile) and its chain link (fast/chain/g[p].lk), exactly one
#   each; the leaf input pin that tile p's `arvalid` reaches inside hbm_glob, exactly one;
#   the HBM IP's boundary pin AXI_<n>_ARVALID on that same net, one distinct n, which must
#   equal portmap(p) (so the block design's wiring is checked too);
#   that HBM cell's LOC if it has one, else the device's SAXI site BLI_HBM_AXI_INTF_X<n>Y0
#   (MEASURED on xcvu35p, devq2: 32 sites X0..X31, Y0, in clock regions X0..X7 Y0; the
#   assumption n = site X is re-checked after placement by a450_pblocks_verify).
# Tile p and its link go in pblock pb_a450_x<X> spanning CLOCKREGION_X<X>Y0:..X<X>Y3
# (SLR0).  Any query matching a wrong count is an error.  Prints A450PB lines; returns
# the pblock count.  Leaves ::a450_pb_expect = list of {p n hbm_cell site} for the verify.
proc a450_pb_site {n} {
  set s [get_sites -quiet "BLI_HBM_AXI_INTF_X${n}Y0"]
  if {[llength $s] != 1} { error "A450PB FAIL: no site BLI_HBM_AXI_INTF_X${n}Y0" }
  return $s
}

proc a450_pblocks {fast_re hbm_glob portmap} {
  set cols [dict create]
  set ::a450_pb_expect {}
  for {set p 0} {$p < [llength $portmap]} {incr p} {
    set n [lindex $portmap $p]
    set tc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/g_t\\\[$p\\\]\\.tile"]
    set lc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/chain/g\\\[$p\\\]\\.lk"]
    if {[llength $tc] != 1 || [llength $lc] != 1} {
      error "A450PB FAIL: tile $p: [llength $tc] tile cells, [llength $lc] link cells"
    }
    # by REF_PIN_NAME: a pin pattern holding the tile's own name would read its [p] as a
    # bus index (MEASURED, Task 7 pre-flight: "<tile>/arvalid" matched nothing)
    set hp [get_pins -quiet -of_objects $tc -filter {REF_PIN_NAME == arvalid}]
    if {[llength $hp] != 1} { error "A450PB FAIL: tile $p: [llength $hp] arvalid pins on $tc" }
    set segs [get_nets -quiet -segments -of_objects $hp]
    set loads {}
    foreach lp [get_pins -quiet -leaf -filter {DIRECTION == IN} -of_objects $segs] {
      if {[string match $hbm_glob [get_property NAME $lp]]} { lappend loads $lp }
    }
    if {[llength $loads] != 1} {
      error "A450PB FAIL: tile $p arvalid reaches [llength $loads] leaf pins in $hbm_glob: $loads"
    }
    set lp [lindex $loads 0]
    # the SAXI number: from the HBM IP's own boundary pin(s) AXI_<n>_ARVALID on this net
    # (the leaf primitive's pin may carry no port number)
    set nums {}
    foreach hpin [get_pins -quiet -of_objects $segs] {
      if {[string match $hbm_glob [get_property NAME $hpin]] &&
          [regexp {^AXI_(\d+)_ARVALID$} [get_property REF_PIN_NAME $hpin] -> pn]} {
        lappend nums [scan $pn %d]
      }
    }
    set nums [lsort -unique -integer $nums]
    if {[llength $nums] != 1} {
      error "A450PB FAIL: tile $p arvalid meets SAXI numbers {$nums} in $hbm_glob, not exactly one"
    }
    if {[lindex $nums 0] != $n} {
      error "A450PB FAIL: tile $p arvalid lands on SAXI [lindex $nums 0] ($lp), portmap says $n"
    }
    set hc [get_cells -of_objects $lp]
    set loc [get_property LOC $hc]
    set how loc
    if {$loc eq ""} { set loc [a450_pb_site $n]; set how assumed }
    set cr [get_clock_regions -of_objects [get_sites $loc]]
    if {![regexp {^X(\d+)Y(\d+)$} $cr -> x y]} { error "A450PB FAIL: clock region '$cr' of $loc" }
    dict lappend cols $x $tc $lc
    lappend ::a450_pb_expect [list $p $n $hc [a450_pb_site $n]]
    puts "A450PB tile $p SAXI_$n leaf [get_property NAME $lp] cell [get_property REF_NAME $hc] site $loc ($how) region $cr"
  }
  foreach x [lsort -integer [dict keys $cols]] {
    set pb [create_pblock pb_a450_x$x]
    add_cells_to_pblock $pb [dict get $cols $x]
    resize_pblock $pb -add "CLOCKREGION_X${x}Y0:CLOCKREGION_X${x}Y3"
    set got [llength [get_cells -quiet -of_objects $pb]]
    if {$got != [llength [dict get $cols $x]]} {
      error "A450PB FAIL: pblock pb_a450_x$x holds $got cells, not [llength [dict get $cols $x]]"
    }
    puts "A450PB pblock pb_a450_x$x cells $got range [get_property GRID_RANGES $pb]"
  }
  return [dict size $cols]
}

# a450_pblocks_verify: after placement, for every tile: if the HBM cell its arvalid
# reaches is a placed SAXI interface cell, its site must be the one a450_pblocks assumed.
# Returns the list of mismatches (empty = verified); prints A450PB_VERIFY lines.
proc a450_pblocks_verify {} {
  set bad {}
  foreach e $::a450_pb_expect {
    lassign $e p n hc site
    set loc [get_property LOC $hc]
    set ref [get_property REF_NAME $hc]
    if {$loc eq ""} {
      puts "A450PB_VERIFY tile $p SAXI_$n cell $ref has no LOC (macro primitive): site not checkable"
      continue
    }
    if {$loc ne $site} { lappend bad "tile $p SAXI_$n placed at $loc, assumed $site" }
    puts "A450PB_VERIFY tile $p SAXI_$n placed $loc assumed $site [expr {$loc eq $site ? "ok" : "MISMATCH"}]"
  }
  return $bad
}
