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

# a450_start_readback <tcore>: the two start-crossing reset paths a450_cdc bounded, read
# back on the ROUTED design.  Shared by build_a450.tcl (the gate) and build_card.tcl (the
# split-on card; final review I3), so the card refuses on exactly the gate's conditions.
# Returns {prst ptog period skew fails}: the one worst setup path rst->ar1 and tog->s1
# ({} when there is not exactly one), aclk_a's period (the clock of ar1's C pin), the
# DATAPATH_DELAY difference of the two, and the refusal reasons, each a string:
#   - not exactly one path of each (the bounds or the cells are gone);
#   - a REQUIREMENT other than one aclk_a period (the clock-wide 2-period bound won);
#   - negative slack against that period;
#   - a skew of one aclk_a period or more (ar3's one edge of margin, rtl/mv4i_tcore.vhd
#     RESETS, holds only while the skew stays under one period).
# The caller prints the paths with its own sentinel prefix and refuses on any reason.
proc a450_start_readback {tc} {
  set ar1d [get_pins -quiet $tc/ar1_reg/D]
  set ca [get_clocks -quiet -of_objects [get_pins -quiet $tc/ar1_reg/C]]
  if {[llength $ar1d] != 1 || [llength $ca] != 1} {
    return [list {} {} 0 0 [list "ar1: [llength $ar1d] D pin(s), [llength $ca] clock(s) on its C pin, not one each"]]
  }
  set pa [get_property PERIOD $ca]
  set rsrc [get_cells -quiet [all_fanin -quiet -flat -startpoints_only -only_cells $ar1d] \
              -filter {IS_SEQUENTIAL}]
  set togc [get_cells -quiet $tc/gosync/tog_reg]
  set s1d [get_pins -quiet $tc/gosync/s1_reg/D]
  set prst {}; set ptog {}
  if {[llength $rsrc] >= 1} { set prst [get_timing_paths -quiet -setup -max_paths 1 -from $rsrc -to $ar1d] }
  if {[llength $togc] == 1 && [llength $s1d] == 1} {
    set ptog [get_timing_paths -quiet -setup -max_paths 1 -from $togc -to $s1d]
  }
  if {[llength $prst] != 1 || [llength $ptog] != 1} {
    return [list {} {} $pa 0 [list "start-crossing reset paths: [llength $prst] rst->ar1, [llength $ptog] tog->s1"]]
  }
  set fails {}
  foreach p [list $prst $ptog] nm {rst->ar1 tog->s1} {
    if {abs([get_property REQUIREMENT $p] - $pa) > 0.001} {
      lappend fails "$nm requirement [get_property REQUIREMENT $p] is not one aclk_a period $pa"
    }
    if {[get_property SLACK $p] < 0} { lappend fails "$nm misses its one-period bound (slack [get_property SLACK $p])" }
  }
  set skew [expr {abs([get_property DATAPATH_DELAY $prst] - [get_property DATAPATH_DELAY $ptog])}]
  if {$skew >= $pa} { lappend fails "rst->ar1 / tog->s1 skew $skew is not under one aclk_a period $pa" }
  return [list $prst $ptog $pa $skew $fails]
}

# a450_cdc_rules <tcore> <stub>: the report_cdc allowed list of the a450 design, as
# {label src_re dst_re}: ANCHORED regular expressions on the report's pin names.  Every
# crossing report_cdc flags Critical or Warning must match one; anything else fails the
# gate.  Regexps, not string match (Task 7 review): a string-match `*` crosses `/`, so
# `*/*_reset/*` accepted any path at all.  Every rule names its destination register
# exactly; `IX` is one report index, a bit `[5]` or a compressed bus `[3:0]`.  Rules that
# matched no row of a routed run are not kept "in case" (Task 7 review): add a rule
# when a run shows the row, by name.  rst_ar1, tog_s1 and ar_ts_wr1 are the exception:
# report_cdc classes them Info (ASYNC_REG synchronisers), the Task 6 ruling requires
# them on the list regardless, and each names one pin.
proc a450_re_quote {s} { return [regsub -all {[\[\].*+?^$(){}|\\]} $s {\\&}] }
proc a450_cdc_rules {tc stub} {
  set t [a450_re_quote $tc]
  set st [a450_re_quote $stub]
  set IX {\[\d+(?::\d+)?\]}
  set r {}
  # start crossing (mv4i_tcore RESETS, mv_tsync): ar1's D pin has one driver, `rst`
  lappend r [list rst_ar1        {^.*$}                       "^$t/ar1_reg/D\$"]
  lappend r [list tog_s1         "^$t/gosync/tog_reg/C\$"    "^$t/gosync/s1_reg/D\$"]
  # result crossing reset hold (ar_ts synchronised into clk_core)
  lappend r [list ar_ts_wr1      "^$t/ar_ts_reg/C\$"         "^$t/wr1_reg/D\$"]
  # mv_rcross's async_fifo: Gray pointers into their first synchroniser stage
  lappend r [list fifo_wp_gray   "^$t/cross/q/wp_g_reg${IX}/C\$" "^$t/cross/q/wp_g_s1_reg${IX}/D\$"]
  lappend r [list fifo_rp_gray   "^$t/cross/q/rp_g_reg${IX}/C\$" "^$t/cross/q/rp_g_s1_reg${IX}/D\$"]
  # the quasi-static job values: held by mv_back from start to the next start, latched by
  # mv_dist at go, which aclk_a sees only after j_go has crossed (bounded by a450_cdc).
  # Destinations MEASURED in a450_hbm_r2's cdc.rpt (rows_r lands in the D_SET1 multiply's
  # DSP: y_r was absorbed into its A/B and C input registers).
  set D "$t/fast/dist"
  lappend r [list job_cbk     "^$t/back/cbk_reg${IX}/C\$"     "^$D/cb_r_reg${IX}/D\$"]
  lappend r [list job_nb_r    "^$t/back/nb_r_reg${IX}/C\$"    "^$D/nb_m1_r_reg${IX}/D\$"]
  lappend r [list job_lastv_r "^$t/back/lastv_r_reg${IX}/C\$" "^$D/lvm_reg${IX}/(D|S)\$"]
  lappend r [list job_os_r    "^$t/back/os_r_reg${IX}/C\$"    "^$D/os_r_reg${IX}/D\$"]
  lappend r [list job_md_r    "^$t/back/md_r_reg${IX}/C\$"    "^$D/md_r_reg${IX}/D\$"]
  lappend r [list job_rows_r  "^$t/back/rows_r_reg${IX}/C\$" \
                 "^$D/prod_r_reg/(DSP_A_B_DATA_INST/B|DSP_C_DATA_INST/C)${IX}\$"]
  # the stub's per-job base and beat registers (loaded at its T_GO, held through the job)
  # into the read FSMs' p_base/p_beats, which load them at `start`.  w_beats and s_beats
  # carry the same value and synthesis merges them (MEASURED, r2: w_beats_reg reached
  # the scale ports' p_beats too), so each stub source may reach either port kind.
  set PF "$t/fast/(g_t${IX}\\.tile/wport|dist/gen_s${IX}\\.sport)/fsm"
  lappend r [list stub_beats "^$st/(w|s)_beats_reg${IX}/C\$" "^$PF/p_beats_reg${IX}/D\$"]
  # the bases are the stub's wb_r/sb_r registers (MEASURED, a450_hbm_7b_r1: synthesis
  # names them after the internal signals, not the w_base/s_base ports; the offset bits
  # are common to every port and merge, so wb_r also reaches the scale ports)
  lappend r [list stub_base  "^$st/(wb_r|sb_r)_reg${IX}/C\$" "^$PF/p_base_reg${IX}/D\$"]
  return $r
}

# a450_cdc_ip_rules <bd>: the rows the gate's copy of the card's aclk_a-side IP adds (Task
# 9b), as the card's own routed report_cdc shows them (MEASURED, jccard_a450s1b
# reports/cdc.rpt: 686 CDC-15 Warning rows inside hbm_sc, 4 inside dbg_hub, none in the
# axi_clock_converters).  CDC-15 here is an XPM LUTRAM FIFO's write port (one clock) read
# by its own output register (the other clock): the FIFO's Gray pointers order the two,
# inside Xilinx IP.  Each rule names the FIFO memory and its read register, inside one IP
# instance; nothing else of the IP and nothing outside it matches.  <bd> is the block
# design instance (a450_i on the gate).
proc a450_cdc_ip_rules {bd} {
  set b [a450_re_quote $bd]
  set N {\[\d+\]}
  set M "inst/m00_nodes/m00_(ar|aw|w|r|b)_node/inst/inst_mi_handler/(gen_normal_area\\.inst_fifo_node_payld|gen_normal_area\\.gen_fifo_req\\.inst_fifo_req)/gen_xpm_memory_fifo\\.inst_fifo/gen_mem_rep${N}\\.inst_xpm_memory/xpm_memory_base_inst"
  set r {}
  lappend r [list hbm_sc_node_fifo \
    "^$b/hbm_sc/$M/gen_wr_a\\.gen_word_narrow\\.mem_reg\[^/\]*/RAM\[A-H\](_D1)?/CLK\$" \
    "^$b/hbm_sc/$M/gen_rd_b\\.gen_rd_b_synth_template\\.gen_rf_narrow_reg\\.doutb_reg_reg${N}/D\$"]
  set X {dbg_hub/inst/BSCANID\.u_xsdbm_id/CORE_XSDB\.UUT_MASTER/U_ICON_INTERFACE/U_CMD6_(RD/U_RD_FIFO/SUBCORE_FIFO\.xsdbm_v3_0_0_rdfifo_inst|WR/U_WR_FIFO/SUBCORE_FIFO\.xsdbm_v3_0_0_wrfifo_inst)/inst_fifo_gen/gconvfifo\.rf/grf\.rf/gntv_or_sync_fifo\.mem/gdm\.dm_gen\.dm}
  lappend r [list dbg_hub_fifo "^$X/RAM_reg\[^/\]*/DP/CLK\$" "^$X/gpr1\\.dout_i_reg${N}/D\$"]
  return $r
}

# a450_cdc_scan <report_text> <rules>: reads report_cdc -details text against the rules
# above (regexp-matched).  A detail row is `Row ID Severity Description Depth Exception Source Destination`, columns separated by
# two or more spaces (MEASURED format, hw/jc/card/jccard_post.tcl jccard_cdc_scan); source
# and destination are the last two fields.  Rows of severity Critical or Warning are
# checked against the rules.  Returns {nsum nrows bad hits}: the Critical+Warning count
# the report's own summary tables claim, the rows parsed, the rows matching no rule, and
# a dict label -> count.  a450_cdc_verdict (below) is the gate's reading of the four.
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
      if {[regexp -- $sp $src] && [regexp -- $dp $dst]} { set hit $lab; break }
    }
    if {$hit eq ""} { lappend bad "$id $sev $src -> $dst"; continue }
    dict incr hits $hit
  }
  return [list $nsum $nrows $bad $hits]
}

# a450_cdc_verdict <nsum> <nrows> <bad> <hits>: the gate's reading of a450_cdc_scan, as a
# list of failure strings (empty = pass).  Refuses a VACUOUS pass (Task 7 review): the
# result crossing's two Gray pointers are flagged in every a450 design that has the
# crossing (CDC-6, MEASURED r2), so a report with no Critical/Warning rows at all, or one
# that misses either pointer, means the report or the parse is wrong, not that the
# design is clean.
proc a450_cdc_verdict {nsum nrows bad hits} {
  set f {}
  if {$nsum != $nrows} { lappend f "report_cdc: summary counts $nsum Critical+Warning, parsed $nrows rows" }
  if {[llength $bad] > 0} { lappend f "report_cdc: [llength $bad] crossing(s) not on the allowed list" }
  if {$nsum == 0} { lappend f "report_cdc: no Critical or Warning row at all (vacuous)" }
  foreach need {fifo_wp_gray fifo_rp_gray} {
    if {![dict exists $hits $need]} { lappend f "report_cdc: no $need row (vacuous or the crossing moved)" }
  }
  return $f
}
