# hw/jc/ctl/jc_ctl_timing.tcl -- the USER3 control core's CDC constraints and audits, as Tcl
# procs, so that the OOC route (ooc_ctl_core.tcl, core at the top, prefix "") and the card
# build (core under the block design, prefix e.g. "*ctl/inst/") apply the SAME constraints.
# Modelled on hw/jc/loader/jc_loader_timing.tcl (frozen; not sourced here, so the two
# files' procs cannot collide: every proc here is jctl_*). Sourced into an open design
# after synthesis. Every object query must match at least one object or the proc stops
# with JCCTL_CONSTRAINT_EMPTY: a constraint whose target matched nothing is silent in
# Vivado and leaves the path as unconstrained as no constraint at all.
#
# NO set_clock_groups BETWEEN aclk AND TCK, for the loader's reason: -asynchronous
# outranks set_max_delay -datapath_only and would silently drop every bound below. Each
# crossing gets its own bound; jctl_cdc_audit then lists every aclk<->TCK endpoint that is
# NOT one of the named crossings, so a crossing nobody designed (a status bit read raw, a
# RAM read on the wrong clock, an ack used without its synchroniser) is a printed count,
# not a path that hides in the timing summary.
#
# The crossings (rtl/jc_ctl_core.vhd and what it instantiates):
#   sync/snap_reg[*] -> sync/st_r_reg[*]   384-bit status snapshot, aclk -> TCK. snap and
#       pub launch on the same aclk edge; st_r captures two TCK edges after tgl_s1 sees
#       pub. Bounded at ONE TCK period. sim/tb_jc_ctl_core.vhd measured the margin the
#       handshake gives: min 96.5 ns from the snap write to the st_r capture at a 37 ns
#       TCK (>= 2.6 TCK periods), so one period is a bound with slack, not the edge.
#   sync/pub_reg     -> sync/tgl_s1_reg     toggle, aclk -> TCK, ASYNC_REG pair
#   sync/ack_reg     -> sync/ack_s1_reg     toggle, TCK -> aclk, ASYNC_REG pair
#   rx/ack_t_reg     -> rak_s1_reg          rsp_ack_tgl, TCK -> aclk, ASYNC_REG pair (new
#       in this core; the executor sees rak_s2)
#   fifo/wp_g_reg[*] -> fifo/wp_g_s1_reg[*] gray write pointer, TCK -> aclk
#   fifo/rp_g_reg[*] -> fifo/rp_g_s1_reg[*] gray read pointer, aclk -> TCK
#       both gray buses: max delay AND bus skew at min(aclk, TCK) period (the loader's)
#   rram (RAMB18E2)  port A written on aclk, port B read on TCK. A block RAM has no timing
#       arc from one port's clock to the other's, so this crossing has NO path to
#       constrain; its correctness is the protocol (the RAM is not written while a
#       response is presented, except the ack-slot tail, which rsp_crc detects).
#       jctl_rram refuses the build if the RAM is not a block RAM (a LUTRAM would turn
#       the asynchronous read into a real, unconstrained aclk -> TCK path).
#   arst -> rst_s1_reg: aclk domain in the card (proc_sys_reset on clk_core), timed
#       normally; the 2-FF stage only matters if the source were asynchronous.

proc jctl_cells {pat} {
  set c [get_cells -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCCTL_CONSTRAINT_EMPTY cells $pat" }
  puts "JCCTL_CONSTRAINT_MATCH cells [llength $c] $pat"
  return $c
}
proc jctl_pins {pat} {
  set c [get_pins -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCCTL_CONSTRAINT_EMPTY pins $pat" }
  puts "JCCTL_CONSTRAINT_MATCH pins [llength $c] $pat"
  return $c
}

# The startpoints, clocked by clk, of the D inputs of the cells dst (set_bus_skew needs
# startpoints, not a clock), whatever synthesis merged on the source side.
proc jctl_src {dst clk} {
  set sp [all_fanin -startpoints_only -flat [get_pins -of_objects $dst -filter {REF_PIN_NAME == D}]]
  set keep {}
  foreach p $sp {
    set c [get_clocks -quiet -of_objects $p]
    if {[llength $c] && [lsearch -exact [get_property NAME $c] [get_property NAME $clk]] >= 0} { lappend keep $p }
  }
  if {[llength $keep] == 0} { error "JCCTL_CONSTRAINT_EMPTY startpoints of $dst on $clk" }
  puts "JCCTL_CONSTRAINT_MATCH startpoints [llength $keep] -> [llength $dst] cells on [get_property NAME $clk]"
  return $keep
}

# FROM A CLOCK, TO THE SYNCHRONISER CELLS (the loader's lesson: a -from register list
# misses a source bit synthesis merged into another register). clk_a is aclk, clk_t TCK.
proc jctl_cdc {core clk_a clk_t aclk_p tck_p} {
  set gp [expr {min($aclk_p, $tck_p)}]
  set st  [jctl_cells "${core}sync/st_r_reg*"]
  set tg  [jctl_cells "${core}sync/tgl_s1_reg"]
  set ak  [jctl_cells "${core}sync/ack_s1_reg"]
  set rk  [jctl_cells "${core}rak_s1_reg"]
  set wpt [jctl_cells "${core}fifo/wp_g_s1_reg*"]
  set rpt [jctl_cells "${core}fifo/rp_g_s1_reg*"]
  # fewer than 384: the executor drives [383:213] and the core-owned fields constant, so
  # synthesis removes those st_r bits; the count is printed, not asserted
  set_max_delay -datapath_only $tck_p  -from $clk_a -to $st
  set_max_delay -datapath_only $aclk_p -from $clk_a -to $tg
  set_max_delay -datapath_only $aclk_p -from $clk_t -to $ak
  set_max_delay -datapath_only $aclk_p -from $clk_t -to $rk
  set_max_delay -datapath_only $gp -from $clk_t -to $wpt
  set_bus_skew $gp -from [jctl_src $wpt $clk_t] -to $wpt
  set_max_delay -datapath_only $gp -from $clk_a -to $rpt
  set_bus_skew $gp -from [jctl_src $rpt $clk_a] -to $rpt
}

# Every timing endpoint reached from one of the two clocks by the other that is NOT one of
# the named synchroniser cells. Prints each as JCCTL_CDC_UNEXPECTED and returns the count;
# the callers print "JCCTL_OOC_CDC unexpected <n>" and the gate requires 0.
proc jctl_cdc_audit {core clk_a clk_t} {
  set ok_at [list "${core}sync/st_r_reg*" "${core}sync/tgl_s1_reg" "${core}fifo/rp_g_s1_reg*"]
  set ok_ta [list "${core}sync/ack_s1_reg" "${core}rak_s1_reg" "${core}fifo/wp_g_s1_reg*"]
  set bad 0
  foreach {from to oks dir} [list $clk_a $clk_t $ok_at a2t $clk_t $clk_a $ok_ta t2a] {
    set paths [get_timing_paths -quiet -setup -from $from -to $to -max_paths 20000 -nworst 1]
    puts "JCCTL_CDC_PATHS $dir [llength $paths]"
    foreach p $paths {
      set ep [get_property ENDPOINT_PIN $p]
      set cell [get_property NAME [get_cells -of_objects [get_pins $ep]]]
      set hit 0
      foreach o $oks { if {[string match $o $cell]} { set hit 1; break } }
      if {!$hit} { incr bad; puts "JCCTL_CDC_UNEXPECTED $dir $ep" }
    }
  }
  return $bad
}

# The response RAM must be a block RAM with its write port on aclk and its read port on
# TCK. Prints each RAM cell with the clock on each of its clock pins.
proc jctl_rram {core clk_a clk_t} {
  set r [get_cells -quiet -hierarchical -filter "NAME =~ \"${core}rram_reg*\" && IS_PRIMITIVE"]
  if {[llength $r] == 0} { error "JCCTL_RRAM none found (${core}rram_reg*)" }
  foreach c $r {
    set g [get_property REF_NAME $c]
    set clks {}
    foreach pn {CLKARDCLK CLKBWRCLK} {
      set p [get_pins -quiet $c/$pn]
      if {[llength $p]} { lappend clks "$pn=[get_property NAME [get_clocks -quiet -of_objects $p]]" }
    }
    puts "JCCTL_RRAM $g $clks $c"
    if {![regexp {^RAMB(18|36)E2$} $g]} { error "JCCTL_RRAM $c is $g, not a RAMB18E2/RAMB36E2" }
  }
  return [llength $r]
}

# BSCANE2 TDI into the TCK-domain receiver (card build only; the loader's jcl_tdi). The
# host drives TDI on the falling TCK edge and the receiver samples on the rising edge.
proc jctl_tdi {bscan_pat half_p} {
  set src [jctl_pins "${bscan_pat}/INTERNAL_TDI"]
  if {[llength $src] != 1} { error "JCCTL_CONSTRAINT_EMPTY expected one INTERNAL_TDI, got [llength $src]" }
  set ep [all_fanout -endpoints_only -flat $src]
  if {[llength $ep] == 0} { error "JCCTL_CONSTRAINT_EMPTY no endpoints from $src" }
  puts "JCCTL_CONSTRAINT_MATCH tdi_endpoints [llength $ep]"
  set_max_delay -datapath_only $half_p -from $src -to $ep
  return $ep
}
