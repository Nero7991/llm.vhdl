# hw/jc/loader/jc_loader_timing.tcl -- the loader's clock and CDC constraints, as Tcl
# procs so that the OOC route (ooc_loader_core.tcl, core at the top) and the full build
# (build_loader.tcl, core under the block design) apply the SAME constraints with a
# different hierarchy prefix. Sourced into an open design, after synthesis; every
# object query must match at least one object or the build stops (JCLOADER_CONSTRAINT_EMPTY):
# a constraint whose target matched nothing is silent in Vivado and leaves the path
# exactly as unconstrained as no constraint at all.
#
# WHY NO set_clock_groups BETWEEN aclk AND TCK. set_clock_groups -asynchronous outranks
# set_max_delay -datapath_only, so with it in place every bound below would be
# ignored (Task 6 review M5). Instead each crossing gets its own bound, and any
# crossing NOT listed here is timed by Vivado at the (meaningless) aclk/TCK edge
# relationship, which shows up as a failing or suspicious path in the timing report
# rather than vanishing.
#
# The crossings (rtl/jc_loader_core.vhd and what it instantiates):
#   sync/snap_reg[*]  -> sync/st_r_reg[*]   384-bit status snapshot, aclk -> TCK. The
#       toggle handshake launches snap and pub on the SAME aclk edge and captures snap
#       two TCK edges after tgl_s1 sees pub, so snap has a 2-TCK-period tolerance
#       (Task 6 review). Bounded at ONE TCK period: half the tolerance.
#   sync/pub_reg      -> sync/tgl_s1_reg    toggle, aclk -> TCK, ASYNC_REG pair
#   sync/ack_reg      -> sync/ack_s1_reg    toggle, TCK -> aclk, ASYNC_REG pair
#   fifo/wp_g_reg[*]  -> fifo/wp_g_s1_reg[*] gray write pointer, TCK -> aclk
#   fifo/rp_g_reg[*]  -> fifo/rp_g_s1_reg[*] gray read pointer, aclk -> TCK
#       Both gray buses: max delay AND bus skew at min(aclk, TCK) period = 5 ns
#       (the XPM convention; a gray bus is safe while its skew is under one
#       destination sample interval, and 5 ns is the smaller of the two).
#   *             -> trst_s1_reg            arst into TCK (2FF, ASYNC_REG), 5 ns
#   *             -> trip_s1_reg            hbm_cat_trip into aclk (2FF, ASYNC_REG),
#       false path (an HBM hard-block level with no fabric clock; see jcl_cdc)

proc jcl_cells {pat} {
  set c [get_cells -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCLOADER_CONSTRAINT_EMPTY cells $pat" }
  puts "JCLOADER_CONSTRAINT_MATCH cells [llength $c] $pat"
  return $c
}
proc jcl_pins {pat} {
  set c [get_pins -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCLOADER_CONSTRAINT_EMPTY pins $pat" }
  puts "JCLOADER_CONSTRAINT_MATCH pins [llength $c] $pat"
  return $c
}

# dna_clk: jc_dna_reader's ck register, high for DNA_DIV aclk cycles and low for
# DNA_DIV, so its period is 2 * DNA_DIV aclk periods. Vivado places the generated
# clock's edges on aclk edges; the real READ/SHIFT changes are DNA_DIV aclk cycles from
# either dna_clk rising edge, so Vivado's setup/hold checks on the DNA_PORTE2 pins are
# the ONE-aclk worst case of that relationship (a conservative bound on the margin).
proc jcl_dna_clock {core div} {
  set src [jcl_pins "${core}dnar/ck_reg/C"]
  set q   [jcl_pins "${core}dnar/ck_reg/Q"]
  create_generated_clock -name dna_clk -source $src -divide_by [expr {2 * $div}] $q
  puts "JCLOADER_DNA_CLOCK divide_by [expr {2 * $div}] period [get_property PERIOD [get_clocks dna_clk]]"
}

# The startpoints, clocked by clk, of the D inputs of the cells dst: the real source
# registers of a crossing whatever synthesis merged (used for set_bus_skew, which needs
# startpoints rather than a clock).
proc jcl_src {dst clk} {
  set sp [all_fanin -startpoints_only -flat [get_pins -of_objects $dst -filter {REF_PIN_NAME == D}]]
  set keep {}
  foreach p $sp {
    set c [get_clocks -quiet -of_objects $p]
    if {[llength $c] && [lsearch -exact [get_property NAME $c] [get_property NAME $clk]] >= 0} { lappend keep $p }
  }
  if {[llength $keep] == 0} { error "JCLOADER_CONSTRAINT_EMPTY startpoints of $dst on $clk" }
  puts "JCLOADER_CONSTRAINT_MATCH startpoints [llength $keep] -> [llength $dst] cells on [get_property NAME $clk]"
  return $keep
}

# FROM A CLOCK, TO THE SYNCHRONISER CELLS. The first version used -from <source
# register pattern> and the OOC run showed why that is wrong: wp_g_s1_reg has 8 bits but
# only 7 wp_g_reg cells exist, because synthesis merged the gray MSB (equal to the binary
# MSB) into wp_reg[7]; a -from register list would have left that bit unconstrained.
# -from <source clock> -to <destination cells> covers every path of the crossing whatever
# synthesis named or merged on the source side. clk_a is aclk, clk_t is TCK.
proc jcl_cdc {core clk_a clk_t aclk_p tck_p} {
  set gp [expr {min($aclk_p, $tck_p)}]
  set st  [jcl_cells "${core}sync/st_r_reg*"]
  set tg  [jcl_cells "${core}sync/tgl_s1_reg"]
  set ak  [jcl_cells "${core}sync/ack_s1_reg"]
  set wpt [jcl_cells "${core}fifo/wp_g_s1_reg*"]
  set rpt [jcl_cells "${core}fifo/rp_g_s1_reg*"]
  set tr  [jcl_cells "${core}trst_s1_reg"]
  set_max_delay -datapath_only $tck_p  -from $clk_a -to $st
  set_max_delay -datapath_only $aclk_p -from $clk_a -to $tg
  set_max_delay -datapath_only $aclk_p -from $clk_t -to $ak
  set_max_delay -datapath_only $gp -from $clk_t -to $wpt
  set_bus_skew $gp -from [jcl_src $wpt $clk_t] -to $wpt
  set_max_delay -datapath_only $gp -from $clk_a -to $rpt
  set_bus_skew $gp -from [jcl_src $rpt $clk_a] -to $rpt
  set_max_delay -datapath_only $aclk_p -from $clk_a -to $tr
  # hbm_cat_trip: a quasi-static level (HBM catastrophic temperature) into a 2FF
  # ASYNC_REG synchroniser; its source is an HBM hard-block pin with no fabric clock, so
  # it cannot be bounded -from a clock. Latency is irrelevant to a trip flag.
  set_false_path -to [jcl_pins "${core}trip_s1_reg/D"]
}
