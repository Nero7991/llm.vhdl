# hw/jc/loader/build_loader.tcl -- Jungle Cat loader bitstream. Synthesis,
# implementation and reports only: nothing here opens a hardware target.
#
#   vivado -mode batch -source build_loader.tcl -tclargs <build_dir> [part] [bd_only]
#
# Flow: project mode for the block design and synthesis (synth_1), then the
# implementation runs IN THIS PROCESS on the opened synthesized design, so the
# timing/CDC constraints (jc_loader_timing.tcl) are applied by Tcl that stops the build
# when a query matches nothing, and every check below is a hard error, not a warning.
#
# PART: default xcvu35p-fsvh2104-1-e, the part hw/jc/axiprobe built the bitstream that
# ran on the Jungle Cat with; the OOC route (ooc_loader_core.tcl) uses the same default.
# The module is -2L; -1 timing is the conservative direction.
#
# Anchored sentinels: JCLOADER_BD_DONE, JCLOADER_SYNTH_DONE, JCLOADER_WNS, JCLOADER_WHS,
# JCLOADER_BSCAN, JCLOADER_BIT, JCLOADER_LTX, JCLOADER_DONE; any failure prints
# JCLOADER_FAIL <reason> and exits 1.
set here  [file normalize [file dirname [info script]]]
set repo  [file normalize $here/../../..]
set bd    [file normalize [lindex $argv 0]]
set part  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xcvu35p-fsvh2104-1-e"}]
set bdonly [expr {[llength $argv] > 2 && [lindex $argv 2] eq "bd_only"}]
set DNA_DIV 10
set TCK_P 37.037
set CORE "*u_jc_core/"
proc jcl_fail {msg} { puts "JCLOADER_FAIL $msg"; exit 1 }
puts "JCLOADER_PART $part"

create_project -force jc_loader $bd -part $part
set_param general.maxThreads 8
set rtl08 {rtl/util_pkg.vhd rtl/jc_loader_pkg.vhd rtl/async_fifo.vhd rtl/jc_frame_core.vhd
           rtl/jc_hbm_writer.vhd rtl/jc_hbm_crc.vhd rtl/jc_status_sync.vhd
           rtl/jc_dna_reader.vhd rtl/jc_loader_core.vhd}
foreach f $rtl08 {
  add_files -norecurse $repo/$f
  set_property file_type {VHDL 2008} [get_files $repo/$f]
}
add_files -norecurse $here/rtl/jc_frame_rx.vhd $here/rtl/jc_loader_top.vhd
update_compile_order -fileset sources_1
if {[catch {source $here/jc_loader_bd.tcl} err]} { jcl_fail "bd: $err" }
puts "JCLOADER_BD_DONE"
if {$bdonly} {
  foreach p [lsort [get_bd_pins -quiet hbm/*]] { puts "JCLOADER_HBMPIN $p" }
  exit 0
}
generate_target all [get_files jcl.bd]
make_wrapper -files [get_files jcl.bd] -top -import
add_files -fileset constrs_1 -norecurse $here/jc_loader.xdc
set_property top jcl_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { jcl_fail "synth_1 [get_property STATUS [get_runs synth_1]]" }
puts "JCLOADER_SYNTH_DONE"
open_run synth_1 -name synth_1

# ---- netlist check: no loader input tied to a constant or left undriven ---------------
set lcell [get_cells -quiet -hierarchical -filter {NAME =~ "*_i/loader" && IS_PRIMITIVE == 0}]
if {[llength $lcell] != 1} { jcl_fail "netlist: loader cell not found ([llength $lcell])" }
set nin 0; set badn {}
foreach pin [get_pins -of_objects $lcell -filter {DIRECTION == IN}] {
  incr nin
  set n [get_nets -quiet -of_objects $pin]
  if {$n eq ""} { lappend badn "$pin:no_net"; continue }
  set t [get_property TYPE $n]
  if {$t eq "GROUND" || $t eq "POWER"} { lappend badn "$pin:$t" }
}
puts "JCLOADER_NETLIST_INPUTS checked=$nin constant_or_open=[llength $badn]"
foreach b $badn { puts "JCLOADER_NETLIST_CONST $b" }

# ---- clocks and CDC ---------------------------------------------------------------------
source $here/jc_loader_timing.tcl
if {[catch {
  # The clock goes on the primitive's INTERNAL_TCK pin, as Vivado's own constraint for the
  # debug hub's BSCANE2 does: on the TCK output pin it is TIMING-2 (invalid primary clock
  # source, the pin has an arc from INTERNAL_TCK) and leaves TDO an unconstrained endpoint
  # (both MEASURED in the first complete build, full2).
  set tckpin [jcl_pins "*u_jc_frx/u_jc_bscan/INTERNAL_TCK"]
  if {[llength $tckpin] != 1} { error "expected one loader BSCANE2 INTERNAL_TCK pin, got [llength $tckpin]" }
  create_clock -name tck_user4 -period $TCK_P $tckpin
  jcl_dna_clock $CORE $DNA_DIV
  set aclk_clk [get_clocks -of_objects [jcl_pins "${CORE}sync/pub_reg/C"]]
  set aclk_p [get_property PERIOD $aclk_clk]
  puts "JCLOADER_ACLK $aclk_clk period $aclk_p"
  if {abs($aclk_p - 5.0) > 0.001} { error "aclk period $aclk_p, expected 5.000" }
  jcl_cdc $CORE $aclk_clk [get_clocks tck_user4] $aclk_p $TCK_P
  # BSCANE2 SEL/SHIFT/CAPTURE/TDI/TDO: no extra bound. A set_max_delay on them works only
  # by path segmentation (CRITICAL WARNING Constraints 18-515, MEASURED in full1), and
  # with the clock on INTERNAL_TCK the primitive's own arcs time them against tck_user4.
} err]} { jcl_fail "constraints: $err" }
if {[llength $badn] > 0} { jcl_fail "netlist: [llength $badn] loader inputs constant or open" }

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $bd/jcl_routed.dcp

set rp $bd/reports
file mkdir $rp
report_route_status -file $rp/route_status.rpt
report_utilization -file $rp/utilization.rpt
report_utilization -hierarchical -file $rp/utilization_hier.rpt
report_timing_summary -max_paths 20 -report_unconstrained -file $rp/timing_summary.rpt
report_clock_interaction -file $rp/clock_interaction.rpt
report_clocks -file $rp/clocks.rpt
report_cdc -details -file $rp/cdc.rpt
report_cdc -file $rp/cdc_summary.rpt
report_exceptions -file $rp/exceptions.rpt
report_exceptions -ignored -file $rp/exceptions_ignored.rpt
report_bus_skew -file $rp/bus_skew.rpt
report_methodology -file $rp/methodology.rpt
report_drc -file $rp/drc.rpt
report_pulse_width -all -file $rp/pulse_width.rpt
check_timing -file $rp/check_timing.rpt
# DNA_PORTE2 pins: setup/hold of READ/SHIFT against dna_clk, DOUT into aclk, and the
# primitive's own CLK period/pulse-width limits.
set dna [get_cells -hierarchical -filter {REF_NAME == DNA_PORTE2}]
puts "JCLOADER_DNA_CELLS [llength $dna] $dna"
if {[llength $dna] != 1} { jcl_fail "expected one DNA_PORTE2, found [llength $dna]" }
set fh [open $rp/dna_timing.rpt w]; close $fh
foreach pn {READ SHIFT DIN} {
  report_timing -setup -to [get_pins $dna/$pn] -max_paths 1 -append -file $rp/dna_timing.rpt
  report_timing -hold  -to [get_pins $dna/$pn] -max_paths 1 -append -file $rp/dna_timing.rpt
}
report_timing -setup -from [get_pins $dna/DOUT] -max_paths 1 -append -file $rp/dna_timing.rpt
report_timing -hold  -from [get_pins $dna/DOUT] -max_paths 1 -append -file $rp/dna_timing.rpt
report_pulse_width -all -cells $dna -file $rp/dna_pulse_width.rpt
# each named crossing, by destination, with the bound that covers it
set fh [open $rp/cdc_paths.rpt w]; close $fh
foreach t {sync/st_r_reg* sync/tgl_s1_reg sync/ack_s1_reg fifo/wp_g_s1_reg*
           fifo/rp_g_s1_reg* trst_s1_reg trip_s1_reg} {
  report_timing -to [get_cells -hier -filter "NAME =~ \"${CORE}$t\""] -max_paths 2 -nworst 1 \
    -append -file $rp/cdc_paths.rpt
}

# ---- BSCAN census: exactly one chain-4 BSCANE2 (ours); nothing else on 4 ----------------
set n4 0; set n4ours 0; set nall 0
foreach c [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] {
  set ch [get_property JTAG_CHAIN $c]
  puts "JCLOADER_BSCAN $c JTAG_CHAIN=$ch"
  incr nall
  if {$ch == 4} { incr n4; if {[string match "*u_jc_frx/u_jc_bscan" $c]} { incr n4ours } }
}
foreach d [get_debug_cores -quiet] {
  # only the hub carries the property; querying it on the jtag_axi cores prints ERROR 12-4444
  if {[llength [list_property $d C_USER_SCAN_CHAIN]]} {
    puts "JCLOADER_DEBUGCORE $d C_USER_SCAN_CHAIN=[get_property C_USER_SCAN_CHAIN $d]"
  } else {
    puts "JCLOADER_DEBUGCORE $d"
  }
}
puts "JCLOADER_BSCAN_SUMMARY total=$nall chain4=$n4 chain4_loader=$n4ours"
if {$n4 != 1 || $n4ours != 1} { jcl_fail "bscan census: chain4=$n4 chain4_loader=$n4ours" }

set rs [report_route_status -return_string]
if {![regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr] || $nerr != 0} { jcl_fail "route status" }
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "JCLOADER_WNS $wns"
puts "JCLOADER_WHS $whs"
if {$wns eq "" || $wns < 0 || $whs eq "" || $whs < 0} { jcl_fail "timing WNS=$wns WHS=$whs" }

write_bitstream -force $bd/jc_loader.bit
write_debug_probes -force $bd/jc_loader.ltx
if {![file exists $bd/jc_loader.bit]} { jcl_fail "no bitstream" }
puts "JCLOADER_BIT $bd/jc_loader.bit"
puts "JCLOADER_LTX [expr {[file exists $bd/jc_loader.ltx] ? "$bd/jc_loader.ltx" : "none"}]"
puts "JCLOADER_DONE"
