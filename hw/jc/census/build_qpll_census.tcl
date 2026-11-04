# hw/jc/census/build_qpll_census.tcl -- vivado -mode batch -source build_qpll_census.tcl
#   -tclargs <build_dir> [part] [ctl_q (default 7)] [mmcm_loc (default none)]
# Builds jc_qpll_census.vhd (GTY QPLL-lock census, all 16 quads).  Default part
# is -1, which loads on any grade.  Prints QPLLC_DONE <bit> or QPLLC_FAIL <why>.
set bd   [lindex $argv 0]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-1-e"}]
set ctlq [expr {[llength $argv] > 2 ? [lindex $argv 2] : 7}]
set mmloc [expr {[llength $argv] > 3 ? [lindex $argv 3] : ""}]
set here [file dirname [file normalize [info script]]]
puts "QPLLC_PARAMS ctl_q=$ctlq mmcm_loc=[expr {$mmloc eq "" ? "none" : $mmloc}]"
create_project -force qpllc $bd -part $part
add_files $here/jc_qpll_census.vhd
set_property file_type {VHDL 2008} [get_files jc_qpll_census.vhd]
add_files -fileset constrs_1 $here/jc_qpll_census.xdc
if {$mmloc ne ""} {
  # the XDC reader has no ifs, so the optional MMCM LOC is a generated file
  set fh [open $bd/mmcm_loc.xdc w]
  puts $fh "set_property LOC $mmloc \[get_cells u_mmcm\]"
  close $fh
  add_files -fileset constrs_1 $bd/mmcm_loc.xdc
  set_property used_in_synthesis false [get_files $bd/mmcm_loc.xdc]
}
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_qpll
set cfg [list CONFIG.C_NUM_PROBE_IN 41 CONFIG.C_NUM_PROBE_OUT 1 CONFIG.C_PROBE_OUT0_WIDTH 1 \
  CONFIG.C_PROBE_IN33_WIDTH 16 CONFIG.C_PROBE_IN37_WIDTH 2]
foreach i {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 34 35 36 38} {
  lappend cfg CONFIG.C_PROBE_IN${i}_WIDTH 32
}
set_property -dict $cfg [get_ips vio_qpll]
generate_target all [get_ips vio_qpll]
set_property top jc_qpll_census [current_fileset]
set_property generic "CTL_Q=$ctlq" [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "QPLLC_FAIL synth"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit [glob -nocomplain $bd/qpllc.runs/impl_1/*.bit]
if {$bit eq ""} { puts "QPLLC_FAIL no bitstream"; exit 1 }
open_run impl_1
report_timing_summary -file $bd/timing.rpt
report_drc -file $bd/drc_routed.rpt
report_utilization -file $bd/util.rpt
write_debug_probes -force $bd/jc_qpll_census.ltx
set nib [llength [get_cells -hier -filter {REF_NAME == IBUFDS_GTE4}]]
set ncm [llength [get_cells -hier -filter {REF_NAME == GTYE4_COMMON}]]
puts "QPLLC_CELLS IBUFDS_GTE4=$nib GTYE4_COMMON=$ncm"
# per quad: the common's site, and the package pin behind each GTREFCLK pin it uses
set bad 0
for {set q 0} {$q < 16} {incr q} {
  set c [get_cells "gen_q\[$q\].u_com"]
  set line "QPLLC_QUAD $q site=[get_property LOC $c]"
  set refs {GTREFCLK00 0 GTREFCLK11 1}
  if {$q == $ctlq} {
    # the positive control: QPLL0 from GTGREFCLK0 <- BUFG <- MMCM, REFCLK0 not used
    set refs {GTREFCLK11 1}
    set n0 [get_nets -quiet -of_objects [get_pins $c/GTREFCLK00]]
    # a tied-off pin is driven by a GND cell; count only refclk buffers
    set l0 0; set d0 none
    if {$n0 ne ""} {
      set dc [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n0 -filter {DIRECTION == OUT}]]
      set d0 [join [get_property REF_NAME $dc] ,]
      set l0 [llength [filter $dc {REF_NAME == IBUFDS_GTE4}]]
    }
    set ng [get_nets -of_objects [get_pins $c/GTGREFCLK0]]
    set bg [get_cells -of_objects [get_pins -leaf -of_objects $ng -filter {DIRECTION == OUT}]]
    set mm [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of_objects [get_pins $bg/I]] -filter {DIRECTION == OUT}]]
    set sel ""
    foreach k {2 1 0} { append sel [expr {[string match *const1* [get_nets -of_objects [get_pins "$c/QPLL0REFCLKSEL\[$k\]"]]] ? 1 : 0}] }
    if {$sel ne "111"} { incr bad }
    append line " QPLL0REFCLKSEL=$sel"
    append line " CTL GTGREFCLK0<-[get_property REF_NAME $bg]:$bg<-[get_property REF_NAME $mm]:$mm@[get_property LOC $mm] GTREFCLK00_driver=$d0 refclk_buffers=$l0"
    if {[get_property REF_NAME $mm] ne "MMCME4_ADV" || $l0 != 0} { incr bad }
    set mmlk [get_nets -quiet -of_objects [get_pins $mm/LOCKED]]
    append line " MMCM_LOCKED_net=$mmlk MMCM_SLR=[get_slrs -of_objects $mm] COMMON_SLR=[get_slrs -of_objects $c]"
    if {$mmloc ne "" && [get_property LOC $mm] ne $mmloc} { incr bad }
  }
  foreach {pn r} $refs {
    set net [get_nets -of_objects [get_pins $c/$pn]]
    set drv [get_cells -of_objects [get_pins -leaf -of_objects $net -filter {DIRECTION == OUT}]]
    set port [get_ports -of_objects [get_nets -of_objects [get_pins $drv/I]]]
    set pkg [get_property PACKAGE_PIN $port]
    append line " $pn<-$port@$pkg"
    if {$port ne "refclk_p\[[expr {2*$q + $r}]\]"} { incr bad }
  }
  foreach pn {QPLL0LOCK QPLL1LOCK QPLL0RESET QPLL1RESET QPLL0LOCKDETCLK QPLL1LOCKDETCLK} {
    set net [get_nets -quiet -of_objects [get_pins $c/$pn]]
    if {$net eq "" || [llength [get_pins -leaf -of_objects $net]] < 2} { append line " $pn=UNCONNECTED"; incr bad }
  }
  puts $line
}
set cw [llength [get_clocks -quiet ref*]]
set unrouted [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED}]]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "QPLLC_CLOCKS ref=$cw unrouted_nets=$unrouted"
puts "QPLLC_WNS $wns WHS $whs"
if {$nib != 32 || $ncm != 16 || $cw != 32 || $bad != 0} { puts "QPLLC_FAIL census ib=$nib cm=$ncm clk=$cw bad=$bad"; exit 1 }
puts "QPLLC_DONE $bit"
