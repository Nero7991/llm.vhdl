# hw/jc/a450/a450_cdc.tcl -- the clk_core <-> aclk_a crossings of rtl/mv4i_tiled.vhd
# (and of anything else between the two clocks), for an OPENED design.  Used by
# build_a450.tcl (Task 7) and by the split-on card (Task 9).
#
#   proc a450_cdc <core_pin_glob> <aclk_pin_glob>
# finds the two clocks from one register pin each (each pattern must match EXACTLY one
# pin; none or several is an error), then bounds every path between them, datapath only:
#   clk_core -> aclk_a  2 aclk_a periods.  The j_* job values, the bases and the beat
#       counts are held from the start pulse on; aclk_a reads them only after j_go has
#       crossed (three aclk_a edges after the toggle lands, rtl/mv_tsync.vhd), and the
#       gray-coded read pointer of mv_rcross changes one bit per clk_core cycle.
#   aclk_a -> clk_core  1 aclk_a period: the gray-coded write pointer changes one bit per
#       aclk_a cycle, so its skew must stay under one aclk_a period.
# and then, tighter than the clock-wide bound, the two START-CROSSING RESET paths at ONE
# aclk_a period each (Task 5/6 reviews; rtl/mv4i_tcore.vhd's RESETS header):
#   rst -> ar1     (the source register(s) of `rst`, found by fan-in of ar1's D pin)
#   tog -> s1      (rtl/mv_tsync.vhd inside mv4i_tcore's gosync)
# ar3's stretch gives exactly one aclk_a edge of margin, and it holds only while the skew
# between these two INDEPENDENT asynchronous paths stays under one aclk_a period.  Each
# bounded at one period keeps that difference under one period; the clock-wide 2-period
# bound alone would not.  These are pin/cell-level set_max_delay, which take priority over
# the clock-level one; build_a450.tcl reads each routed path's REQUIREMENT back to prove it.
# The mv4i_tcore instance is the cell two levels above the core pin, which must therefore
# be <tcore>/back/go_r_reg/C.  Every query counts its matches and errors on a wrong count.
# Prints A450CDC lines; returns {core_clock aclk_clock}.
proc a450_cdc_one {what pat {want 1}} {
  set r [get_pins -quiet -hierarchical -filter "NAME =~ $pat"]
  if {[llength $r] != $want} {
    error "A450CDC FAIL: $what '$pat' matches [llength $r] pins, not $want"
  }
  return $r
}

proc a450_cdc {core_glob aclk_glob} {
  set cp [a450_cdc_one "core pin" $core_glob]
  set ap [a450_cdc_one "aclk pin" $aclk_glob]
  set cc [get_clocks -quiet -of_objects $cp]
  set ca [get_clocks -quiet -of_objects $ap]
  if {[llength $cc] != 1 || [llength $ca] != 1 || $cc eq $ca} {
    error "A450CDC FAIL: clocks '$cc' and '$ca' are not two distinct clocks"
  }
  set pa [get_property PERIOD $ca]
  set_max_delay -datapath_only -from $cc -to $ca [expr {2.0 * $pa}]
  set_max_delay -datapath_only -from $ca -to $cc $pa
  puts "A450CDC core $cc period [get_property PERIOD $cc] aclk_a $ca period $pa"

  if {![regsub {/back/go_r_reg/C$} [get_property NAME $cp] {} tc]} {
    error "A450CDC FAIL: core pin $cp is not <mv4i_tcore>/back/go_r_reg/C"
  }
  # rst -> ar1: ar1's D pin, and the sequential startpoint(s) of its fan-in (the clk_core
  # register behind `rst`; in a450_hbm_top that is core_reset's peripheral_aresetn).
  set ar1d [a450_cdc_one "ar1 D" "$tc/ar1_reg/D"]
  set rsrc [get_cells -quiet [all_fanin -quiet -flat -startpoints_only -only_cells $ar1d] \
              -filter {IS_SEQUENTIAL}]
  if {[llength $rsrc] < 1} { error "A450CDC FAIL: no sequential startpoint drives $ar1d" }
  foreach c $rsrc {
    if {[get_clocks -quiet -of_objects [get_pins -quiet -of_objects $c -filter {IS_CLOCK}]] ne $cc} {
      error "A450CDC FAIL: rst source $c is not clocked by $cc"
    }
  }
  set_max_delay -datapath_only -from $rsrc -to $ar1d $pa
  puts "A450CDC bound rst->ar1 $pa from [llength $rsrc] cell(s) [lsort $rsrc] to $ar1d"
  # tog -> s1
  set togc [get_cells -quiet "$tc/gosync/tog_reg"]
  if {[llength $togc] != 1} { error "A450CDC FAIL: $tc/gosync/tog_reg matches [llength $togc] cells, not 1" }
  set s1d [a450_cdc_one "s1 D" "$tc/gosync/s1_reg/D"]
  set_max_delay -datapath_only -from $togc -to $s1d $pa
  puts "A450CDC bound tog->s1 $pa from $togc to $s1d"
  return [list $cc $ca]
}

# a450_cdc_rules <tcore> <stub>: the report_cdc allowed list of the a450 design, as
# {label src_glob dst_glob} (Tcl string match on the report's pin names).  Every crossing
# report_cdc flags Critical or Warning must match one; anything else fails the gate.
# The globs avoid brackets: string match would read them as a character class.
proc a450_cdc_rules {tc stub} {
  set r {}
  # start crossing (mv4i_tcore RESETS, mv_tsync)
  lappend r [list rst_ar1        *                         $tc/ar1_reg/D]
  lappend r [list tog_s1         $tc/gosync/tog_reg/C      $tc/gosync/s1_reg/D]
  # result crossing reset hold (ar_ts synchronised into clk_core; wr1 -> wr2 is clk_core
  # to clk_core and is listed for completeness, report_cdc should not flag it)
  lappend r [list ar_ts_wr1      $tc/ar_ts_reg/C           $tc/wr1_reg/D]
  lappend r [list wr1_wr2        $tc/wr1_reg/C             $tc/wr2_reg/D]
  # mv_rcross's async_fifo: Gray pointers into their two-flop synchronisers, and its RAM
  # (written on aclk_a, read on clk_core)
  lappend r [list fifo_wp_gray   $tc/cross/q/wp_g_reg*     $tc/cross/q/wp_g_s1_reg*]
  lappend r [list fifo_rp_gray   $tc/cross/q/rp_g_reg*     $tc/cross/q/rp_g_s1_reg*]
  lappend r [list fifo_ram       $tc/cross/q/mem*          $tc/cross/q/*]
  # its clear handshake (clr is tied '0' by mv_rcross; listed in case synthesis keeps it)
  lappend r [list fifo_clr       $tc/cross/q/*             $tc/cross/q/clr_*_s1_reg*]
  # act_mem_dp: x written on clk_core, read on aclk_a (a two-clock RAM)
  lappend r [list xmem_ram       $tc/xmem/*                *]
  lappend r [list xmem_ram_in    *                         $tc/xmem/*]
  # the quasi-static job values (held by mv_back from start to the next start, read by
  # aclk_a only after j_go has crossed) and the stub's beat counts, bounded by a450_cdc
  foreach n {nb_r rows_r lastv_r os_r md_r cbk} {
    lappend r [list job_$n $tc/back/${n}_reg* $tc/fast/*]
  }
  foreach n {w_beats s_beats w_base s_base} {
    lappend r [list stub_$n $stub/${n}_reg* $tc/fast/*]
  }
  # vendor IP internals (HBM APB/AXI clocks, proc_sys_reset synchronisers): no A path
  # meets the HBM on a second clock (every SAXI is on aclk_a), so these are the IP's own
  lappend r [list vendor_hbm     */hbm/*                   */hbm/*]
  lappend r [list vendor_rst     *                         */*_reset/*]
  lappend r [list vendor_rst_apb *                         */apb_rst/*]
  return $r
}

# a450_cdc_scan <report_text> <rules>: reads report_cdc -details text.  A detail row is
# `Row ID Severity Description Depth Exception Source Destination`, columns separated by
# two or more spaces (MEASURED format, hw/jc/card/jccard_post.tcl jccard_cdc_scan); source
# and destination are the last two fields.  Rows of severity Critical or Warning are
# checked against the rules.  Returns {nsum nrows bad hits}: the Critical+Warning count
# the report's own summary tables claim, the rows parsed, the rows matching no rule, and
# a dict label -> count.  The caller requires nrows == nsum and bad empty.
proc a450_cdc_scan {txt rules} {
  set nsum 0; set nrows 0; set bad {}; set hits [dict create]
  foreach l [split $txt "\n"] {
    if {[regexp {^(CDC-\d+)\s+(Critical|Warning)\s+(\d+)\s} $l -> id sev cnt]} { incr nsum $cnt; continue }
    if {![regexp {^\s*\d+\s+(CDC-\d+)\s+(Critical|Warning)\s} $l -> id sev]} { continue }
    incr nrows
    set f [regexp -all -inline {\S+(?: \S+)*} [string trim $l]]
    set src [lindex $f end-1]; set dst [lindex $f end]
    set hit ""
    foreach rule $rules {
      lassign $rule lab sp dp
      if {[string match $sp $src] && [string match $dp $dst]} { set hit $lab; break }
    }
    if {$hit eq ""} { lappend bad "$id $sev $src -> $dst"; continue }
    dict incr hits $hit
  }
  return [list $nsum $nrows $bad $hits]
}
