# hw/jc/link/jc_link_timing.tcl -- the CDC constraints of rtl/jc_tok_top.vhd (plan
# 2026-11-04 Task 7), in jc_ctl_timing.tcl's shape: every crossing bounded by netlist pins
# and cells (never by a clock name: see jlk_src), every query must match
# (JCLINK_CONSTRAINT_EMPTY), no set_clock_groups (it would outrank the bounds), an audit
# counts crossings nobody named, and a post-route audit (jlk_exc_audit) refuses unless the
# bounds are still in force after the gtg ECO's clock re-derivation.
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
# The startpoints (clock pins of the launching registers) of dst's D inputs whose launch clock
# is clk (not=0) or is a clock other than clk (not=1); unclocked startpoints are skipped.
# jccard_loop2 root cause 1 (2026-11-11, MEASURED report_exceptions on the routed dcp): a
# constraint written "-from <clock>" is kept by the clock's NAME, and the gtg ECO re-derives
# the Aurora clocks under new names (txoutclk_out[0] -> txoutclk_out[0]_1), so every
# "-from user_clk" bound silently stopped applying (17 crossings timed as synchronous,
# WNS -2.306) and report_exceptions later died on the dangling object (Constraints 18-396).
# Every bound below is therefore anchored to netlist pins and cells, never to a clock; the
# clock is only used here, at apply time, to choose which startpoints belong to the crossing.
proc jlk_src {dst clk {not 0} {optional 0}} {
  set sp [all_fanin -startpoints_only -flat [get_pins -of_objects $dst -filter {REF_PIN_NAME == D}]]
  set cn [get_property NAME $clk]
  set keep {}
  foreach p $sp {
    set c [get_clocks -quiet -of_objects $p]
    if {[llength $c] == 0} continue
    set on [expr {[lsearch -exact [get_property NAME $c] $cn] >= 0}]
    if {$on != $not} { lappend keep $p }
  }
  set what [expr {$not ? "not on $cn" : "on $cn"}]
  if {[llength $keep] == 0} {
    if {$optional} { puts "JCLINK_CONSTRAINT_NOSRC [llength $dst] cells, no clocked startpoint $what"; return {} }
    error "JCLINK_CONSTRAINT_EMPTY startpoints of [lindex $dst 0] ([llength $dst] cells) $what"
  }
  puts "JCLINK_CONSTRAINT_MATCH startpoints [llength $keep] -> [llength $dst] cells $what"
  return $keep
}
# The Aurora user clock and init_clk as they are NOW, each found from a register the tok RTL
# clocks; the user clock must also be the clock on the GT channel's TXOUTCLK pin (its source).
proc jlk_clocks {pre} {
  set clk_u [jlk_clock_of_pin "${pre}rxf/wp_g_reg*/C"]
  set clk_i [jlk_clock_of_pin "${pre}i_rpb_reg*/C"]
  set gt [get_cells -quiet -hierarchical -filter {REF_NAME == GTYE4_CHANNEL}]
  if {[llength $gt] != 1} { error "JCLINK_CONSTRAINT_EMPTY [llength $gt] GTYE4_CHANNEL cells" }
  set tp [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
  set gc [get_clocks -quiet -of_objects $tp]
  if {[llength $gc] != 1 || [get_property NAME $gc] ne [get_property NAME $clk_u]} {
    error "JCLINK_CONSTRAINT_EMPTY user clock [get_property NAME $clk_u] is not the TXOUTCLK clock ([get_property NAME $gc])"
  }
  puts "JCLINK_USER_CLOCK [get_property NAME $clk_u] source $tp"
  return [list $clk_u $clk_i]
}
# Run AFTER the gtg ECO and opt_design (build_card.tcl), with the clocks jlk_clocks finds then.
proc jlk_cdc {pre clk_a clk_u clk_i} {
  set pa [get_property PERIOD $clk_a]
  set pu [get_property PERIOD $clk_u]
  set pi [get_property PERIOD $clk_i]
  set g [expr {min($pa, $pu)}]
  set n 0
  # f: the FIFO; src: its write clock; dst: its read clock
  foreach {f src dst} [list txf $clk_a $clk_u rxf $clk_u $clk_a] {
    set w [jlk_cells "${pre}${f}/wp_g_s1_reg*"]
    set r [jlk_cells "${pre}${f}/rp_g_s1_reg*"]
    set ws [jlk_src $w $src]
    set rs [jlk_src $r $dst]
    set_max_delay -datapath_only $g -from $ws -to $w
    set_max_delay -datapath_only $g -from $rs -to $r
    set_bus_skew $g -from $ws -to $w
    set_bus_skew $g -from $rs -to $r
    incr n 4
    # the clear handshake (clr tied '0' in jc_tok_top, the chain kept by ASYNC_REG): clr_r_s1
    # sits in the read domain fed from the write side, clr_a_s1 the reverse. Each only where
    # it exists and has a clocked source. -datapath_only needs a -from (Constraints 18-540).
    foreach {c from} [list clr_r_s1_reg $src clr_a_s1_reg $dst] {
      set ca [get_cells -quiet -hierarchical -filter "NAME =~ \"${pre}${f}/$c\""]
      if {[llength $ca]} {
        puts "JCLINK_CONSTRAINT_MATCH cells [llength $ca] ${pre}${f}/$c"
        set cs [jlk_src $ca $from 0 1]
        if {[llength $cs]} { set_max_delay -datapath_only $g -from $cs -to $ca; incr n }
      }
    }
  }
  # the status levels into aclk, from every clocked startpoint not on aclk (the Aurora
  # user_clk; the GT/MMCM lock levels where they are clocked at all), so the aclk-internal
  # second stage keeps its normal timing. s_tx/s_rx/s_ovf must have one; s_pll/s_gtg may not.
  foreach {s opt} {s_tx 0 s_rx 0 s_ovf 0 s_pll 1 s_gtg 1} {
    set d [jlk_cells "${pre}${s}_reg*"]
    set ss [jlk_src $d $clk_a 1 $opt]
    if {[llength $ss]} { set_max_delay -datapath_only $pa -from $ss -to $d; incr n }
  }
  foreach {s p} [list u_rst_s $pu u_pol $pu i_rpb $pi i_pma $pi] {
    set d [jlk_cells "${pre}${s}_reg*"]
    set_max_delay -datapath_only $p -from [jlk_src $d $clk_a] -to $d
    incr n
  }
  puts "JCLINK_CDC_APPLIED $n"
  return $n
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
# report_clock_interaction text -> the rows for the given {from to} name pairs, each as
# {from to unsafe line}; unsafe is 1 when the row's classification says "(unsafe)" (e.g.
# "Timed (unsafe)": the two clocks share no node and nothing bounds the crossing). Pure Tcl
# (no Vivado command), so test_jccard_post.py runs it in tclsh against a captured report.
proc jlk_ci_rows {txt pairs} {
  set out {}
  foreach line [split $txt "\n"] {
    set tok [regexp -all -inline {\S+} $line]
    if {[llength $tok] < 3} continue
    set f [lindex $tok 0]; set t [lindex $tok 1]
    foreach {pf pt} $pairs {
      if {$f eq $pf && $t eq $pt} {
        lappend out [list $f $t [expr {[string first "(unsafe)" $line] >= 0}] [string trim $line]]
      }
    }
  }
  return $out
}
# POST-ROUTE refusal (build_card.tcl, after route_design): the link bounds must still be in
# force on the routed design. Returns the number of failures; prints each.
#   1. every setup path from the Aurora user clock and from init_clk into aclk (and back)
#      carries a "MaxDelay ... -datapath_only" exception, and each direction has >= 1 path;
#   2. report_clock_interaction has a row for user_clk -> aclk and no "(unsafe)" row between
#      aclk and the user clock or init_clk.
# Not "report_exceptions -from <clock> -to <clock>": MEASURED on jccard_loop2's routed dcp, it
# prints "No valid timing exceptions found" for aclk -> user_clk although every one of those
# paths carries "MaxDelay Path 6.206ns -datapath_only" (it filters on the constraint's own
# -from/-to objects, which here are pins and cells), so it could neither pass nor refuse.
proc jlk_exc_audit {clk_a clk_u clk_i} {
  set bad 0
  set na [get_property NAME $clk_a]; set nu [get_property NAME $clk_u]; set ni [get_property NAME $clk_i]
  foreach {f t} [list $clk_u $clk_a $clk_i $clk_a $clk_a $clk_u $clk_a $clk_i] {
    set ps [get_timing_paths -quiet -setup -from $f -to $t -max_paths 20000 -nworst 1]
    set nx 0; set wns ""
    foreach p $ps {
      set e [get_property EXCEPTION $p]
      if {![string match "MaxDelay*datapath_only*" $e]} {
        incr nx
        if {$nx <= 20} { puts "JCLINK_EXC_UNBOUND [get_property NAME $f] -> [get_property NAME $t] [get_property ENDPOINT_PIN $p] slack=[get_property SLACK $p] exception=<$e>" }
      }
      set s [get_property SLACK $p]
      if {$s ne "" && ($wns eq "" || $s < $wns)} { set wns $s }
    }
    puts "JCLINK_EXC [get_property NAME $f] -> [get_property NAME $t] paths=[llength $ps] unbound=$nx wns=$wns"
    if {[llength $ps] == 0} { incr bad; puts "JCLINK_EXC_FAIL no paths [get_property NAME $f] -> [get_property NAME $t]" }
    if {$nx > 0} { incr bad }
  }
  set rows [jlk_ci_rows [report_clock_interaction -return_string] \
              [list $na $nu $nu $na $na $ni $ni $na]]
  set seen_ua 0
  foreach r $rows {
    lassign $r f t u line
    if {$f eq $nu && $t eq $na} { set seen_ua 1 }
    puts "JCLINK_CI [expr {$u ? "UNSAFE" : "ok"}] $line"
    if {$u} { incr bad }
  }
  if {!$seen_ua} { incr bad; puts "JCLINK_EXC_FAIL no report_clock_interaction row $nu -> $na" }
  puts "JCLINK_EXC_AUDIT bad=$bad"
  return $bad
}
