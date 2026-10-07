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

# The response RAM must be a block RAM whose WRITTEN port is on aclk and whose other (read)
# port is on TCK. A port is "written" if any of its write-enable pins (WEA[*] for port A,
# WEBWE[*] for port B) is on a net that is not a constant. Refuses (Tcl error, so no
# ^JCCTL_OOC_DONE) on: no RAM; a primitive that is not RAMB18E2/RAMB36E2; both ports on
# the same clock (e.g. the read port moved to aclk); not exactly one written port; the
# written port not on clk_a or the read port not on clk_t.
# MEASURED (controller's OOC run /mnt/storage/fk33_builds/jcctl_ooc2): one RAMB18E2,
# CLKARDCLK = tck (port A, read), CLKBWRCLK = aclk (port B, write), WRITE_MODE NO_CHANGE.
proc jctl_we_live {c pfx} {
  set live 0
  foreach p [get_pins -quiet -of_objects $c -filter "REF_PIN_NAME =~ ${pfx}*"] {
    set n [get_nets -quiet -of_objects $p]
    if {[llength $n] && [lsearch -exact {GROUND POWER} [get_property TYPE $n]] < 0} { set live 1 }
  }
  return $live
}
proc jctl_pin_clock {c pn} {
  set p [get_pins -quiet -of_objects $c -filter "REF_PIN_NAME == $pn"]
  if {[llength $p] != 1} { error "JCCTL_RRAM $c has no single $pn pin" }
  set k [get_clocks -quiet -of_objects $p]
  if {[llength $k] != 1} { error "JCCTL_RRAM $c/$pn is on [llength $k] clocks" }
  return [get_property NAME $k]
}
proc jctl_rram {core clk_a clk_t} {
  set an [get_property NAME $clk_a]
  set tn [get_property NAME $clk_t]
  set r [get_cells -quiet -hierarchical -filter "NAME =~ \"${core}rram_reg*\" && IS_PRIMITIVE"]
  if {[llength $r] == 0} { error "JCCTL_RRAM none found (${core}rram_reg*)" }
  foreach c $r {
    set g [get_property REF_NAME $c]
    if {![regexp {^RAMB(18|36)E2$} $g]} { error "JCCTL_RRAM $c is $g, not a RAMB18E2/RAMB36E2" }
    set ca [jctl_pin_clock $c CLKARDCLK]
    set cb [jctl_pin_clock $c CLKBWRCLK]
    set wa [jctl_we_live $c WEA]
    set wb [jctl_we_live $c WEBWE]
    puts "JCCTL_RRAM $g CLKARDCLK=$ca CLKBWRCLK=$cb written_A=$wa written_B=$wb $c"
    if {$ca eq $cb} { error "JCCTL_RRAM $c has both ports on $ca" }
    if {$wa + $wb != 1} { error "JCCTL_RRAM $c has $wa + $wb written ports, expected 1" }
    if {$wa} { set wclk $ca; set rclk $cb } else { set wclk $cb; set rclk $ca }
    if {$wclk ne $an} { error "JCCTL_RRAM $c write port on $wclk, expected $an" }
    if {$rclk ne $tn} { error "JCCTL_RRAM $c read port on $rclk, expected $tn" }
  }
  return [llength $r]
}

# SYNCHRONISER STRUCTURE (fix round 1). A one-flop synchroniser (the consumer taking the
# first stage instead of the second) is invisible to a zero-delay bench, to the endpoint
# audit and to an ASYNC_REG print. jctl_sync_chain refuses unless: both stages exist, every
# cell of both stages has ASYNC_REG true, and every timing endpoint of every first-stage Q
# is a D pin of a second-stage cell (the first stage feeds the second stage and nothing
# else). Run it on the synthesized netlist, before opt_design can replicate a flop.
proc jctl_sync_chain {s1 s2} {
  set c1 [jctl_cells $s1]
  set c2 [jctl_cells $s2]
  set n2 [get_property NAME $c2]
  foreach c [concat $c1 $c2] {
    set v [get_property ASYNC_REG $c]
    if {![string is true -strict $v]} { error "JCCTL_SYNC [get_property NAME $c] ASYNC_REG is '$v'" }
    puts "JCCTL_ASYNC_REG [get_property NAME $c] $v"
  }
  foreach c $c1 {
    set q [get_pins -of_objects $c -filter {REF_PIN_NAME == Q}]
    set ep [all_fanout -endpoints_only -flat $q]
    if {[llength $ep] == 0} { error "JCCTL_SYNC [get_property NAME $c]/Q reaches nothing" }
    foreach e $ep {
      set ec [get_property NAME [get_cells -of_objects $e]]
      if {[lsearch -exact $n2 $ec] < 0 || [get_property REF_PIN_NAME $e] ne "D"} {
        error "JCCTL_SYNC [get_property NAME $c]/Q reaches $e, not only the second stage $s2"
      }
    }
  }
  puts "JCCTL_SYNC_OK [llength $c1] $s1 -> $s2"
}

# CONSUMER TRACE (fix round 2). The first version traced the executor's hierarchical input
# pins (ex/rsp_ack_tgl, ex/rst). MEASURED (controller, /mnt/storage/fk33_builds/jcctl_ooc3):
# synthesis keeps `ex` as a hierarchical cell but not those port pins under their names,
# so the trace refused a correct netlist ("JCCTL_SYNC no single pin ex/rsp_ack_tgl"). This
# version uses only LEAF cells and nets, never a hierarchical port name, and adds no
# KEEP_HIERARCHY or DONT_TOUCH (that would change the implementation under test).

# The leaf input pins on the net driven by cell/Q (empty if Q drives nothing).
proc jctl_q_loads {cell} {
  set q [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == Q}]
  if {[llength $q] != 1} { error "JCCTL_SYNC [get_property NAME $cell] has no single Q pin" }
  set n [get_nets -quiet -of_objects $q]
  if {[llength $n] == 0} { return {} }
  return [lsort -unique [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == IN}]]
}

# Is load cell lc allowed? pats: glob patterns of allowed cells. top_comb 1 also allows a
# combinational cell at the core's own level (directly under core, not in a sub-block).
proc jctl_load_ok {lc pats top_comb core} {
  foreach p $pats { if {[string match $p $lc]} { return 1 } }
  if {$top_comb && [string match "${core}*" $lc] && ![string match "${core}*/*" $lc]
      && ![string is true -strict [get_property IS_SEQUENTIAL [get_cells $lc]]]} { return 1 }
  return 0
}

# The consumer takes the SECOND stage. Refuses (JCCTL_SYNC) unless:
#   * s2 (one cell) drives at least one leaf load;
#   * every leaf load of s2/Q is an allowed cell (pats, or a top-level combinational cell
#     when top_comb is 1);
#   * at least one leaf load matches need (the consumer block is really fed);
#   * no leaf load of any s1 cell's Q matches need (the consumer never takes stage one).
proc jctl_drives {s1 s2 need pats top_comb core} {
  set c2 [jctl_cells $s2]
  if {[llength $c2] != 1} { error "JCCTL_SYNC expected one $s2 cell, got [llength $c2]" }
  set loads [jctl_q_loads $c2]
  if {[llength $loads] == 0} { error "JCCTL_SYNC $s2/Q has no loads" }
  set nneed 0
  foreach p $loads {
    set lc [get_property NAME [get_cells -of_objects $p]]
    if {[string match $need $lc]} { incr nneed }
    if {![jctl_load_ok $lc $pats $top_comb $core]} {
      error "JCCTL_SYNC $s2/Q drives $p, outside {$pats}"
    }
  }
  if {$nneed == 0} { error "JCCTL_SYNC $s2/Q drives nothing matching $need" }
  foreach c1 [jctl_cells $s1] {
    foreach p [jctl_q_loads $c1] {
      if {[string match $need [get_property NAME [get_cells -of_objects $p]]]} {
        error "JCCTL_SYNC first stage [get_property NAME $c1]/Q drives $p"
      }
    }
  }
  puts "JCCTL_SYNC_DRIVER $s2 loads [llength $loads] ($nneed under $need)"
}

# Every synchroniser of the core, structurally (call after synth_design).
#   rak_s2: rtl/jc_ctl_core.vhd's only reader is ex.rsp_ack_tgl  -> loads only under ex/.
#   rst_s2: its readers are ex.rst, and the reset gates q_vx (into ex.q_valid) and
#           q_ready (into fifo.q_ready). Synthesis may place those LUTs at the top level,
#           in ex/ or in fifo/      -> loads under ex/ or fifo/, or top-level combinational.
proc jctl_syncs {core} {
  jctl_sync_chain "${core}rak_s1_reg"        "${core}rak_s2_reg"
  jctl_sync_chain "${core}rst_s1_reg"        "${core}rst_s2_reg"
  jctl_sync_chain "${core}sync/tgl_s1_reg"   "${core}sync/tgl_s2_reg"
  jctl_sync_chain "${core}sync/ack_s1_reg"   "${core}sync/ack_s2_reg"
  jctl_sync_chain "${core}fifo/wp_g_s1_reg*" "${core}fifo/wp_g_s2_reg*"
  jctl_sync_chain "${core}fifo/rp_g_s1_reg*" "${core}fifo/rp_g_s2_reg*"
  jctl_drives "${core}rak_s1_reg" "${core}rak_s2_reg" "${core}ex/*" [list "${core}ex/*"] 0 $core
  jctl_drives "${core}rst_s1_reg" "${core}rst_s2_reg" "${core}ex/*" \
    [list "${core}ex/*" "${core}fifo/*"] 1 $core
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
