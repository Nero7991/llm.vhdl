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
    lappend ::a450_pb_expect [list $p $n $hc [a450_pb_site $n] $tc $x]
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

# ---- Task 9b (docs/debugging/2026-11-15_a450-card-split-timing.md, fixes 1 and 7) --------
# a450_ip_pblocks <chains>: the aclk_a-side IP (clock converters, register slices, the HBM
# smartconnect) beside the HBM port it serves.  chains is a flat list {cell_re saxi ...}:
# cell_re a REGEXP that must match exactly ONE hierarchical cell, saxi the HBM port number.
# The column is the clock region of that port's site (BLI_HBM_AXI_INTF_X<n>Y0, the same
# assumption a450_pblocks makes and a450_pblocks_verify re-checks for the tiles).  The cell
# joins that column's tile pblock pb_a450_x<X> if one exists, else pb_a450_ip_x<X>
# (CLOCKREGION_X<X>Y0:X<X>Y3, SLR0).  Prints A450PB_IP lines; returns the cell count and
# leaves ::a450_pb_ip = list of {cell saxi x pblock} for a450_pblocks_placed.
proc a450_ip_pblocks {chains} {
  set ::a450_pb_ip {}
  foreach {re n} $chains {
    set c [get_cells -quiet -hierarchical -regexp -filter "NAME =~ $re"]
    if {[llength $c] != 1} { error "A450PB FAIL: IP cell '$re' matches [llength $c] cells, not 1" }
    set cr [get_clock_regions -of_objects [a450_pb_site $n]]
    if {![regexp {^X(\d+)Y(\d+)$} $cr -> x y]} { error "A450PB FAIL: clock region '$cr' of SAXI_$n" }
    set pb [get_pblocks -quiet pb_a450_x$x]
    if {[llength $pb] != 1} {
      set pb [get_pblocks -quiet pb_a450_ip_x$x]
      if {[llength $pb] != 1} {
        set pb [create_pblock pb_a450_ip_x$x]
        resize_pblock $pb -add "CLOCKREGION_X${x}Y0:CLOCKREGION_X${x}Y3"
      }
    }
    add_cells_to_pblock $pb $c
    if {[get_pblocks -of_objects $c] ne [get_property NAME $pb]} {
      error "A450PB FAIL: $c is in pblock '[get_pblocks -of_objects $c]', not $pb"
    }
    lappend ::a450_pb_ip [list $c $n $x [get_property NAME $pb]]
    puts "A450PB_IP $c SAXI_$n region $cr pblock [get_property NAME $pb]"
  }
  return [llength $::a450_pb_ip]
}

# a450_ip_chains <bd_re>: the split-on card's aclk_a-side IP cells and their HBM ports, the
# one list the gate (build_a450.tcl, bd_re a450_i) and the card (build_card.tcl, bd_re
# .*/jcc_i) both floorplan: the clock converter and register slice of the loader (SAXI 0),
# A's descriptor fetch (29) and the B/C pool (30, 31), and the HBM smartconnect and its
# slice (16).  Cell names are the block designs' (a450_bd.tcl IP_CHAIN, gen_jc_card.py).
proc a450_ip_chains {bd_re} {
  set r {}
  foreach {c n} {ld_cdc 0 ld_rs 0 d_cdc 29 d_rs 29 bc_cdc0 30 bc_rs0 30 bc_cdc1 31 bc_rs1 31
                 hbm_sc 16 sc_rs 16} {
    lappend r "${bd_re}/$c" $n
  }
  return $r
}

# a450_pb_regions <cell>: for every placed primitive under <cell> (a hierarchical cell),
# the clock region of its SITE, as a dict region -> distinct sites (cells share sites, so
# this counts sites, not cells); and the count of primitives, and of those with no LOC.
# The leaf cells are found from INSIDE the cell (current_instance, the Task 9 diagnosis's
# method): a NAME glob would read a tile's `g_t[0]` as a character class (MEASURED,
# a450_hbm_9b_r1: every tile matched 0 cells), and cells have no IS_PLACED property (the
# same run: the IP cells, with no bracket in their names, matched 0 too).  Macro cells (a
# DSP48E2 is one) carry no LOC of their own; their internal cells do, so MACRO is excluded.
proc a450_pb_regions {c} {
  current_instance -quiet
  current_instance $c
  set leaf [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_LEVEL != MACRO && REF_NAME != GND && REF_NAME != VCC}]
  current_instance -quiet
  set placed [filter -quiet $leaf {LOC != ""}]
  set h [dict create]
  if {[llength $placed] > 0} {
    foreach r [get_property CLOCK_REGION [get_sites -quiet -of_objects $placed]] { dict incr h $r }
  }
  return [list $h [llength $placed] [expr {[llength $leaf] - [llength $placed]}]]
}

# a450_pblocks_placed: after placement, the floorplan as PLACED, not as requested: every
# pb_a450_* pblock holds cells; every tile (from a450_pblocks) and every IP cell (from
# a450_ip_pblocks) has no unplaced primitive, and at least A450PB_MIN_IN of its placed
# sites inside its column's clock regions X<X>Y0..X<X>Y3.
# WHY A SHARE AND NOT ALL (MEASURED, 2026-11-15, a450_hbm_7b_r6's routed checkpoint, the
# run that closed 450 MHz): its pblocks read back IS_SOFT 1, and after phys_opt and route
# 19 of its 24 tiles had sites in the neighbouring column (this proc on that checkpoint:
# in_column 0.906 to 1.000, minimum tile 6; the cells outside are SRL16E and FDRE that
# phys_opt moved), so "every primitive inside" would refuse the placement that met timing.  The failure this guards
# against is the unfloorplanned card (jccard_a450s1b: a typical tile 11% to 33% in its
# port's column, smeared over up to 13 regions).  Prints A450PB_PLACED lines (with each
# item's in-column share); returns {failures npblocks ntiles_ok nip_ok min_share}.
set A450PB_MIN_IN 0.80
proc a450_pblocks_placed {} {
  set bad {}
  set pbs [get_pblocks -quiet pb_a450_*]
  foreach pb $pbs {
    set k [llength [get_cells -quiet -of_objects $pb]]
    if {$k == 0} { lappend bad "pblock $pb is empty" }
    puts "A450PB_PLACED pblock $pb cells $k soft [get_property IS_SOFT $pb]"
  }
  set items {}
  if {[info exists ::a450_pb_expect]} {
    foreach e $::a450_pb_expect { lassign $e p n hc site tc x; lappend items [list "tile $p" $tc $x] }
  }
  if {[info exists ::a450_pb_ip]} {
    foreach e $::a450_pb_ip { lassign $e c n x pb; lappend items [list "ip $c" $c $x] }
  }
  set nt 0; set ni 0; set smin 1.0
  foreach it $items {
    lassign $it what c x
    # by exact NAME (==): a tile's name holds `[p]`, which a get_cells pattern would glob
    set co [get_cells -quiet -hierarchical -filter "NAME == \"$c\""]
    if {[llength $co] != 1} { lappend bad "$what: [llength $co] cells named $c"; continue }
    lassign [a450_pb_regions $co] h np nu
    set tot 0; set in 0; set out {}
    dict for {r k} $h {
      incr tot $k
      if {[regexp {^X(\d+)Y(\d+)$} $r -> rx ry] && $rx == $x && $ry <= 3} { incr in $k } else { lappend out "$r:$k" }
    }
    set share [expr {$tot > 0 ? double($in) / $tot : 0.0}]
    if {$share < $smin} { set smin $share }
    set ok [expr {$np > 0 && $nu == 0 && $share >= $::A450PB_MIN_IN}]
    puts "A450PB_PLACED $what column X$x primitives $np unplaced $nu sites $tot in_column [format %.3f $share] outside {$out} [expr {$ok ? "ok" : "BAD"}]"
    if {!$ok} {
      lappend bad "$what: primitives $np unplaced $nu in_column [format %.3f $share] (min $::A450PB_MIN_IN) outside {$out}"
    } elseif {[string match "tile *" $what]} { incr nt } else { incr ni }
  }
  if {[llength $items] == 0} { lappend bad "no tile or IP recorded (a450_pblocks never ran)" }
  return [list $bad [llength $pbs] $nt $ni $smin]
}
