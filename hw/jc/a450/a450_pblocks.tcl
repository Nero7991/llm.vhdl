# hw/jc/a450/a450_pblocks.tcl -- spec 1.2's placement: one pblock per tile COLUMN, in
# SLR0 directly above the tiles' HBM ports.  For an OPENED, linked design.
#
#   proc a450_pblocks <fast_re> <hbm_glob> <portmap>
#     fast_re    a REGEXP for the mv_afast instance, e.g. {.*/g_split\.u/fast}
#     hbm_glob   everything inside the HBM IP, e.g. "*/hbm/*" (without "/*": the IP cell)
#     portmap    the SAXI number of weight tile p, p = 0..23 (scale ports are not tiles)
# For each tile p, re-derived from the NETLIST rather than from the block design's text:
#   the tile cell (fast/g_t[p].tile) and its chain link (fast/chain/g[p].lk), exactly one
#   each; the HBM IP's boundary pin AXI_<n>_ARVALID for n = portmap(p), whose net's one leaf
#   driver must lie inside tile p (so the block design's wiring is checked too), and whose
#   one leaf load inside hbm_glob is the HBM interface cell;
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
  # the HBM IP cell: hbm_glob without its trailing /*
  set hcell [get_cells -quiet -hierarchical -filter "NAME =~ [regsub {/\*$} $hbm_glob {}]"]
  if {[llength $hcell] != 1} { error "A450PB FAIL: HBM IP cell for '$hbm_glob': [llength $hcell] matches" }
  for {set p 0} {$p < [llength $portmap]} {incr p} {
    set n [lindex $portmap $p]
    set tc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/g_t\\\[$p\\\]\\.tile"]
    set lc [get_cells -quiet -hierarchical -regexp -filter "NAME =~ ${fast_re}/chain/g\\\[$p\\\]\\.lk"]
    if {[llength $tc] != 1 || [llength $lc] != 1} {
      error "A450PB FAIL: tile $p: [llength $tc] tile cells, [llength $lc] link cells"
    }
    # Traced FROM the HBM side: the IP's boundary pin AXI_<n>_ARVALID keeps its name, a
    # synthesised tile's boundary pins do not (MEASURED, a450_hbm_r1: flatten_hierarchy
    # rebuilt renames them after their nets, e.g. g_t[0].tile/arv_reg).  The net's one
    # leaf driver must sit inside tile p, so the block design's wiring is checked too.
    # on the IP cell itself only: inside it, each stack names its ports AXI_00..15 again
    # (MEASURED, dry run on a450_hbm_r1's synth: AXI_01 matched SAXI 1 and SAXI 17)
    set bp [get_pins -quiet -of_objects $hcell -filter [format {REF_PIN_NAME == AXI_%02d_ARVALID} $n]]
    if {[llength $bp] != 1} { error "A450PB FAIL: [llength $bp] pins AXI_[format %02d $n]_ARVALID on $hcell" }
    set segs [get_nets -quiet -segments -of_objects $bp]
    set drv [get_pins -quiet -leaf -filter {DIRECTION == OUT} -of_objects $segs]
    if {[llength $drv] != 1} {
      error "A450PB FAIL: SAXI_$n ARVALID has [llength $drv] leaf drivers: $drv"
    }
    if {![regexp "${fast_re}/g_t\\\[(\\d+)\\\]\\.tile/" [get_property NAME $drv] -> dp] || $dp != $p} {
      error "A450PB FAIL: SAXI_$n ARVALID is driven by $drv, not by tile $p"
    }
    set loads {}
    foreach lp [get_pins -quiet -leaf -filter {DIRECTION == IN} -of_objects $segs] {
      if {[string match $hbm_glob [get_property NAME $lp]]} { lappend loads $lp }
    }
    if {[llength $loads] > 1} {
      set loads [get_pins -quiet $loads -filter {REF_NAME =~ HBM*}]
    }
    if {[llength $loads] != 1} {
      error "A450PB FAIL: SAXI_$n ARVALID reaches [llength $loads] leaf pins in $hbm_glob: $loads"
    }
    set lp [lindex $loads 0]
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

# a450_pblocks_verify: after placement, for every tile: the HBM cell its arvalid reaches
# must be placed (have a LOC) at the site a450_pblocks assumed.  Returns the list of
# mismatches AND unverifiable cells (empty = every tile verified); prints A450PB_VERIFY.
proc a450_pblocks_verify {} {
  set bad {}
  foreach e $::a450_pb_expect {
    lassign $e p n hc site
    set loc [get_property LOC $hc]
    set ref [get_property REF_NAME $hc]
    if {$loc eq ""} {
      # not checkable is not checked: a skip is a failure of the verify (Task 7 review),
      # so a pblock assumption nothing confirmed cannot pass the gate
      puts "A450PB_VERIFY tile $p SAXI_$n cell $ref has no LOC (macro primitive): site not checkable"
      lappend bad "tile $p SAXI_$n cell $ref has no LOC: site assumption unverified"
      continue
    }
    if {$loc ne $site} { lappend bad "tile $p SAXI_$n placed at $loc, assumed $site" }
    puts "A450PB_VERIFY tile $p SAXI_$n placed $loc assumed $site [expr {$loc eq $site ? "ok" : "MISMATCH"}]"
  }
  return $bad
}
