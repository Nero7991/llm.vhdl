# hw/jc/a450/build_a450.tcl -- the a450 A+HBM timing design (plan 2026-11-12-a450-per-
# port-tiles Task 7, spec 3.2 gate 2): block design, synthesis, the CDC bounds and the
# tile pblocks, then opt/place/phys_opt/ROUTE in this process, and the routed reports.
# Synthesis and implementation only: nothing here opens a hardware target.
#
#   vivado -mode batch -source build_a450.tcl -tclargs <src_tree> <build_dir> -nonce <n>
#
# Sentinels (anchored): A450HBM_NONCE, A450HBM_SYNTH_DONE, A450HBM_PBLOCKS,
# A450HBM_ROUTE routing_errors, A450HBM_WNS_ACLK, A450HBM_WNS_CORE, A450HBM_WNS,
# A450HBM_WHS, A450HBM_UTIL, A450HBM_RSTAR1, A450HBM_TOGS1, A450HBM_DAFULL*,
# A450HBM_TOP, A450HBM_CDC, A450HBM_DONE.  Any failure BEFORE routing prints
# A450HBM_FAIL <reason> and exits 1 (a constraint that did not apply makes the run
# meaningless).  A post-route check that fails prints A450HBM_CHECK_FAIL <what> and the
# run still writes every report and A450HBM_DONE; run_a450.sh refuses a PASS on any
# CHECK_FAIL.  The gate is A450HBM_WNS_ACLK >= 0 (the worst routed setup slack of every
# path ending in aclk_a), WNS_CORE >= 0, WHS >= 0, and no CHECK_FAIL.
set src   [file normalize [lindex $argv 0]]
set bd    [file normalize [lindex $argv 1]]
set ni    [lsearch -exact $argv -nonce]
set nonce [expr {$ni >= 0 ? [lindex $argv [expr {$ni + 1}]] : ""}]
proc a4_fail {msg} { puts "A450HBM_FAIL $msg"; exit 1 }
proc a4_check_fail {msg} { puts "A450HBM_CHECK_FAIL $msg" }
if {$nonce eq ""} { a4_fail "no -nonce on -tclargs" }
puts "A450HBM_NONCE $nonce"
set part xcvu35p-fsvh2104-2L-e
set here $src/hw/jc/a450
puts "A450HBM_PART $part"

create_project -force a450 $bd -part $part
set_param general.maxThreads 8
# the closure of rtl/mv4i_tiled.vhd (entity work.* re-derived from the files, Task 7), in
# analysis order, plus the stub
set RTL08 {
  rtl/util_pkg.vhd rtl/mv4i_arith_pkg.vhd rtl/stream_fifo.vhd rtl/async_fifo.vhd
  rtl/mv_rdfsm.vhd rtl/mv_rdport.vhd rtl/mv_lfifo.vhd rtl/mv_tile.vhd
  rtl/mv_xbcast.vhd rtl/act_mem_dp.vhd rtl/mv_dist.vhd rtl/mv_rlink.vhd rtl/mv_rchain.vhd
  rtl/mv_rcross.vhd rtl/mv_tsync.vhd rtl/mv_afast.vhd rtl/mv_back.vhd rtl/mv4i_tcore.vhd
  rtl/mv4i_tiled.vhd rtl/a450_stub_seq.vhd
}
foreach f $RTL08 {
  if {![file exists $src/$f]} { a4_fail "missing source $f" }
  add_files -norecurse $src/$f
  set_property file_type {VHDL 2008} [get_files $src/$f]
}
# the module-reference top: VHDL-93
add_files -norecurse $here/a450_hbm_top.vhd
update_compile_order -fileset sources_1
if {[catch {source $here/a450_bd.tcl} err]} { a4_fail "bd: $err" }
generate_target all [get_files a450.bd]
make_wrapper -files [get_files a450.bd] -top -import
add_files -fileset constrs_1 -norecurse $here/a450.xdc
set_property top a450_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { a4_fail "synth_1 [get_property STATUS [get_runs synth_1]]" }
puts "A450HBM_SYNTH_DONE"
open_run synth_1 -name synth_1

# the hierarchy as Vivado elaborated it (the globs below are checked against this, not
# against the plan's text)
foreach c [lsort [get_cells -quiet -hierarchical -regexp -filter {NAME =~ .*/g_split\.u/[^/]+}]] {
  puts "A450HBM_HIER $c"
}

source $here/a450_cdc.tcl
source $here/a450_pblocks.tcl
if {[catch {
  lassign [a450_cdc "*/g_split.u/back/go_r_reg/C" "*/g_split.u/fast/dist/s_start_reg/C"] cc ca
  set npb [a450_pblocks {.*/g_split\.u/fast} "*/hbm/*" \
           {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25}]
  puts "A450HBM_PBLOCKS $npb"
} err]} { a4_fail "constraints: $err" }
if {$npb < 2} { a4_fail "constraints: only $npb pblock(s)" }
set tc [regsub {/back/go_r_reg/C$} [get_pins -hierarchical -filter {NAME =~ */g_split.u/back/go_r_reg/C}] {}]
set stub [get_cells -hierarchical -filter {NAME =~ */top/*/stub}]
if {[llength $stub] != 1} { a4_fail "constraints: stub instance matches [llength $stub] cells" }
puts "A450HBM_TCORE $tc STUB $stub"

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $bd routed.dcp]
report_route_status -file [file join $bd route_status.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $bd timing_routed.rpt]
report_timing -to $ca -max_paths 10 -nworst 1 -file [file join $bd timing_aclk_top10.rpt]
report_clock_interaction -file [file join $bd clock_interaction.rpt]
report_exceptions -file [file join $bd exceptions.rpt]
report_utilization -file [file join $bd util_routed.rpt]
report_utilization -hierarchical -file [file join $bd util_routed_hier.rpt]
set pbf [file join $bd util_pblocks.rpt]
file delete -force $pbf
foreach pb [lsort [get_pblocks pb_a450_*]] { report_utilization -pblocks $pb -append -file $pbf }
report_cdc -details -file [file join $bd cdc.rpt]
report_design_analysis -logic_level_distribution -file [file join $bd levels_routed.rpt]

set rs [report_route_status -return_string]
if {[regexp {routing errors[ .]*:\s*(\d+)} $rs -> nerr]} {
  puts "A450HBM_ROUTE routing_errors $nerr"
  if {$nerr != 0} { a4_check_fail "route status: $nerr routing error(s)" }
} else { a4_check_fail "route status: could not parse the routing error count" }

proc a4_fanout {path} {
  set m 0
  foreach n [get_nets -quiet -of_objects $path] {
    set f [expr {[get_property FLAT_PIN_COUNT $n] - 1}]
    if {$f > $m} { set m $f }
  }
  return $m
}
proc a4_path {tag p} {
  set d [get_property DATAPATH_DELAY $p]
  set nd [get_property DATAPATH_NET_DELAY $p]
  set share [expr {$d > 0 ? round(100.0 * $nd / $d) : 0}]
  puts "$tag SLACK [get_property SLACK $p] REQ [get_property REQUIREMENT $p] DELAY $d ROUTE_PCT $share LEVELS [get_property LOGIC_LEVELS $p] FANOUT [a4_fanout $p] START [get_property STARTPOINT_PIN $p] END [get_property ENDPOINT_PIN $p]"
}

set pa [get_timing_paths -quiet -setup -max_paths 1 -to $ca]
set pc [get_timing_paths -quiet -setup -max_paths 1 -to $cc]
if {[llength $pa] != 1 || [llength $pc] != 1} { a4_check_fail "no setup path into aclk_a or clk_core" }
puts "A450HBM_WNS_ACLK [get_property SLACK $pa] LEVELS [get_property LOGIC_LEVELS $pa] START [get_property STARTPOINT_PIN $pa] END [get_property ENDPOINT_PIN $pa]"
puts "A450HBM_WNS_CORE [get_property SLACK $pc]"
puts "A450HBM_WNS [get_property SLACK [get_timing_paths -setup -max_paths 1]]"
puts "A450HBM_WHS [get_property SLACK [get_timing_paths -hold -max_paths 1]]"
set u [report_utilization -return_string]
proc used {u row} { if {[regexp "\\| $row +\\| +(\[0-9.\]+)" $u -> v]} { return $v }; return -1 }
set dsp [used $u DSPs]
puts "A450HBM_UTIL LUT [used $u {CLB LUTs}] FF [used $u {CLB Registers}] BRAM [used $u {Block RAM Tile}] DSP $dsp"
# teeth: a trimmed datapath meets any clock.  24 tiles x 66 DSP (MEASURED, a450_tile rating)
if {$dsp < 1584} { a4_check_fail "DSP $dsp < 1584 = 24 tiles x 66: the tiles were trimmed" }

# the top 10 paths into aclk_a, one line each
set i 0
foreach p [get_timing_paths -quiet -setup -max_paths 10 -nworst 1 -to $ca] {
  a4_path "A450HBM_TOP [incr i]" $p
}

# the two start-crossing reset paths: bounded at one aclk_a period each (a450_cdc), read
# back here by REQUIREMENT so a constraint that lost to the clock-wide 2-period bound
# shows; their delay difference is the skew ar3's one edge of margin must cover
set pa_ns [get_property PERIOD $ca]
set ar1d [get_pins $tc/ar1_reg/D]
set rsrc [get_cells [all_fanin -flat -startpoints_only -only_cells $ar1d] -filter {IS_SEQUENTIAL}]
set prst [get_timing_paths -quiet -setup -max_paths 1 -from $rsrc -to $ar1d]
set ptog [get_timing_paths -quiet -setup -max_paths 1 -from [get_cells $tc/gosync/tog_reg] -to [get_pins $tc/gosync/s1_reg/D]]
if {[llength $prst] != 1 || [llength $ptog] != 1} {
  a4_check_fail "start-crossing reset paths: [llength $prst] rst->ar1, [llength $ptog] tog->s1"
} else {
  a4_path A450HBM_RSTAR1 $prst
  a4_path A450HBM_TOGS1 $ptog
  foreach p [list $prst $ptog] nm {rst->ar1 tog->s1} {
    if {abs([get_property REQUIREMENT $p] - $pa_ns) > 0.001} {
      a4_check_fail "$nm requirement [get_property REQUIREMENT $p] is not one aclk_a period $pa_ns"
    }
    if {[get_property SLACK $p] < 0} { a4_check_fail "$nm misses its one-period bound" }
  }
  puts "A450HBM_RSTSKEW [expr {abs([get_property DATAPATH_DELAY $prst] - [get_property DATAPATH_DELAY $ptog])}] PERIOD $pa_ns"
}

# d_afull name-check (Task 5 review): a chain stage's registered afull (ua_r of link k-1)
# is link k's d_afull, which selects dd_r (97 bits) and drives o_rdy into tile k.
set ua [get_cells -quiet -hierarchical -regexp -filter {NAME =~ .*/g_split\.u/fast/chain/g\[\d+\]\.lk/ua_r_reg}]
puts "A450HBM_DAFULL_REGS [llength $ua]"
if {[llength $ua] != 23} { a4_check_fail "chain ua_r registers: [llength $ua], not 23 (NT - 1)" }
set k 12
set uk [get_cells -quiet -hierarchical -regexp -filter "NAME =~ .*/g_split\\.u/fast/chain/g\\\[[expr {$k - 1}]\\\]\\.lk/ua_r_reg"]
if {[llength $uk] != 1} {
  a4_check_fail "d_afull name-check: g\[[expr {$k - 1}]\].lk/ua_r_reg matches [llength $uk] cells"
} else {
  set pk [get_timing_paths -quiet -setup -max_paths 1 -from $uk]
  if {[llength $pk] != 1} { a4_check_fail "d_afull name-check: no path from $uk" } else {
    a4_path "A450HBM_DAFULL k=$k" $pk
    set nk [get_nets -of_objects [get_pins $uk/Q]]
    puts "A450HBM_DAFULL_NET $nk FANOUT [expr {[get_property FLAT_PIN_COUNT $nk] - 1}]"
  }
}
if {[llength $ua] > 0} {
  set pw [get_timing_paths -quiet -setup -max_paths 1 -from $ua]
  if {[llength $pw] == 1} { a4_path A450HBM_DAFULL_WORST $pw }
}

# placement of the HBM ports as assumed by a450_pblocks
set vb [a450_pblocks_verify]
if {[llength $vb] > 0} { a4_check_fail "pblock site assumption: $vb" }

# report_cdc against the allowed list
set fh [open [file join $bd cdc.rpt] r]; set ct [read $fh]; close $fh
lassign [a450_cdc_scan $ct [a450_cdc_rules $tc $stub]] nsum nrows bad hits
foreach lab [lsort [dict keys $hits]] { puts "A450HBM_CDC_RULE $lab [dict get $hits $lab]" }
foreach b [lrange $bad 0 49] { puts "A450HBM_CDC_UNLISTED $b" }
puts "A450HBM_CDC flagged_summary $nsum flagged_rows $nrows unlisted [llength $bad]"
if {$nsum != $nrows} { a4_check_fail "report_cdc: summary counts $nsum Critical+Warning, parsed $nrows rows" }
if {[llength $bad] > 0} { a4_check_fail "report_cdc: [llength $bad] crossing(s) not on the allowed list" }

puts "A450HBM_DONE"
