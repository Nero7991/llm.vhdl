# hw/jc/link/jc_link_timing.tcl -- the CDC constraints of rtl/jc_tok_top.vhd (plan
# 2026-11-04 Task 7), in jc_ctl_timing.tcl's shape: every crossing bounded by name,
# every query must match (JCLINK_CONSTRAINT_EMPTY), no set_clock_groups (it would outrank
# the bounds), and an audit counts crossings nobody named.
# Crossings (prefix = the tok cell's hierarchy, e.g. "*/jcc_i/tok/inst/", or "" for an OOC
# synthesis of jc_tok_top alone):
#   txf/wp_g -> txf/wp_g_s1 (aclk -> user_clk) and txf/rp_g -> txf/rp_g_s1 (user -> aclk)
#   rxf/wp_g -> rxf/wp_g_s1 (user -> aclk) and rxf/rp_g -> rxf/rp_g_s1 (aclk -> user)
#   txf/rxf clr_*_s1 (async_fifo's clear handshake; jc_tok_top ties clr '0', kept by KEEP)
#   s_tx/s_rx/s_pll/s_gtg_reg[0] (Aurora / MMCM levels -> aclk), s_ovf_reg[0] (user -> aclk)
#   u_rst_s_reg[0], u_pol_reg[*] (aclk -> user_clk); i_rpb_reg[0], i_pma_reg[0] (aclk -> init_clk)
#   i_lck_reg[0] (final review I5): gtg_locked into init_clk. Its source is the MMCM's LOCKED
#   pin, which no clock times, so it has no bound here and is deliberately NOT on the audit's
#   allowed list: a timed path into it from aclk or user_clk would be a wiring defect.
# Requires jctl_src from hw/jc/ctl/jc_ctl_timing.tcl (build_card.tcl sources it first).
#
# finding 2: a literal [0]/[*] inside a double-quoted Tcl pattern is command-substituted at
# parse time ("invalid command name \"0\""), and even escaped it still reaches string
# match/=~ as a one-character glob class. Every pattern here is bracket-free.
proc jlk_cells {pat} {
  set c [get_cells -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $c] == 0} { error "JCLINK_CONSTRAINT_EMPTY cells $pat" }
  puts "JCLINK_CONSTRAINT_MATCH cells [llength $c] $pat"
  return $c
}
proc jlk_clock_of_pin {pat} {
  set p [get_pins -quiet -hierarchical -filter "NAME =~ \"$pat\""]
  if {[llength $p] == 0} { error "JCLINK_CONSTRAINT_EMPTY pins $pat" }
  set c [get_clocks -quiet -of_objects [lindex $p 0]]
  if {[llength $c] != 1} { error "JCLINK_CONSTRAINT_EMPTY clock on $pat ([llength $c] clocks)" }
  puts "JCLINK_CLOCK $pat [get_property NAME $c] [get_property PERIOD $c]"
  return $c
}
proc jlk_cdc {pre clk_a clk_u clk_i} {
  set pa [get_property PERIOD $clk_a]
  set pu [get_property PERIOD $clk_u]
  set pi [get_property PERIOD $clk_i]
  set g [expr {min($pa, $pu)}]
  # f: the FIFO; src: its write clock; dst: its read clock
  foreach {f src dst} [list txf $clk_a $clk_u rxf $clk_u $clk_a] {
    set w [jlk_cells "${pre}${f}/wp_g_s1_reg*"]
    set r [jlk_cells "${pre}${f}/rp_g_s1_reg*"]
    set_max_delay -datapath_only $g -from $src -to $w
    set_max_delay -datapath_only $g -from $dst -to $r
    set_bus_skew $g -from [jctl_src $w $src] -to $w
    set_bus_skew $g -from [jctl_src $r $dst] -to $r
    # the clear handshake (clr tied '0' in jc_tok_top, the chain kept by ASYNC_REG): clr_r_s1
    # sits in the read domain fed from the write side, clr_a_s1 the reverse. Each only where
    # it exists. -datapath_only needs a -from (Constraints 18-540, MEASURED: the brief's
    # -to-only form stopped the OOC teeth run).
    foreach {c from} [list clr_r_s1_reg $src clr_a_s1_reg $dst] {
      set ca [get_cells -quiet -hierarchical -filter "NAME =~ \"${pre}${f}/$c\""]
      if {[llength $ca]} {
        puts "JCLINK_CONSTRAINT_MATCH cells [llength $ca] ${pre}${f}/$c"
        set_max_delay -datapath_only $g -from $from -to $ca
      }
    }
  }
  # the status levels into aclk: from every clock but aclk (the Aurora user_clk, and the
  # GT/MMCM lock levels where they are clocked at all), so the aclk-internal second stage
  # keeps its normal timing.
  set others [get_clocks -quiet -filter "NAME != [get_property NAME $clk_a]"]
  if {[llength $others] == 0} { error "JCLINK_CONSTRAINT_EMPTY no clock other than [get_property NAME $clk_a]" }
  foreach s {s_tx s_rx s_pll s_gtg s_ovf} {
    set_max_delay -datapath_only $pa -from $others -to [jlk_cells "${pre}${s}_reg*"]
  }
  set_max_delay -datapath_only $pu -from $clk_a -to [jlk_cells "${pre}u_rst_s_reg*"]
  set_max_delay -datapath_only $pu -from $clk_a -to [jlk_cells "${pre}u_pol_reg*"]
  set_max_delay -datapath_only $pi -from $clk_a -to [jlk_cells "${pre}i_rpb_reg*"]
  set_max_delay -datapath_only $pi -from $clk_a -to [jlk_cells "${pre}i_pma_reg*"]
}
# Endpoints crossing aclk <-> user_clk, and aclk -> init_clk, that are none of the above;
# prints each as JCLINK_CDC_UNEXPECTED and returns the count. The allowed list names each
# synchroniser first stage exactly (no "s_*" wildcard, which would also cover any register
# whose name merely contains "s_"). `drop` (teeth checks only) removes the allowed entries
# ending in that string, so a synchroniser the list stops naming must show as unexpected.
proc jlk_cdc_audit {pre clk_a clk_u {clk_i ""} {drop ""}} {
  set ok {}
  foreach f {txf rxf} {
    foreach r {wp_g_s1_reg* rp_g_s1_reg* clr_r_s1_reg clr_a_s1_reg} { lappend ok "${pre}${f}/$r" }
  }
  foreach r {s_tx_reg* s_rx_reg* s_pll_reg* s_gtg_reg* s_ovf_reg* u_rst_s_reg* u_pol_reg* \
             i_rpb_reg* i_pma_reg*} {
    lappend ok "${pre}$r"
  }
  if {$drop ne ""} {
    set keep {}
    foreach k $ok { if {![string match "*$drop" $k]} { lappend keep $k } }
    puts "JCLINK_AUDIT_DROP $drop removed [expr {[llength $ok] - [llength $keep]}]"
    set ok $keep
  }
  set pairs [list $clk_a $clk_u $clk_u $clk_a]
  if {$clk_i ne ""} { lappend pairs $clk_a $clk_i }
  set bad 0
  set n 0
  foreach {from to} $pairs {
    foreach p [get_timing_paths -quiet -setup -from $from -to $to -max_paths 20000 -nworst 1] {
      incr n
      set c [get_property PARENT_CELL [get_property ENDPOINT_PIN $p]]
      set hit 0
      foreach k $ok { if {[string match $k [get_property NAME $c]]} { set hit 1 } }
      if {!$hit} { incr bad; puts "JCLINK_CDC_UNEXPECTED [get_property NAME $c]" }
    }
  }
  puts "JCLINK_CDC_PATHS $n"
  return $bad
}
