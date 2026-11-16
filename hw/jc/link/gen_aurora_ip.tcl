# hw/jc/link/gen_aurora_ip.tcl -- create the Aurora 64B66B IP in batch mode, read back every
# CONFIG it was given, check the generated GT LOCs against the lane table, and write the stub
# (plan 2026-11-04 Task 5). No hardware: Vivado project mode, synth only.
#
# usage: vivado -mode batch -source hw/jc/link/gen_aurora_ip.tcl -tclargs <out_dir> <nlanes> <rate> <card|sim>
# env:   JC_AUR_MUTATE=permute  (Step 3 teeth check: set the IP's lane map from a rotated table)
#        JC_AUR_MUTATE=permute_check  (the lane-map check compares against a rotated table)
# prints ^AURORA_IP_OK or errors ^AURORA_CFG_FAIL <what>
set here [file dirname [file normalize [info script]]]
source [file join $here aurora_cfg.tcl]
lassign $argv out nlanes rate mode
set part xcvu35p-fsvh2104-2L-e
file mkdir $out
create_project -force aur $out/prj -part $part
set cfg [jc_aurora_config $nlanes $rate $mode]
if {[info exists ::env(JC_AUR_MUTATE)] && $::env(JC_AUR_MUTATE) eq "permute"} {
  set rot {}
  foreach {k v} $cfg {
    if {[string match CONFIG.C_GT_LOC_* $k]} { set v [expr {$v % $nlanes + 1}] }
    lappend rot $k $v
  }
  set cfg $rot
  puts "AURORA_MUTANT permute"
}
# Second teeth check (MEASURED 2026-11-10: the IP does not take the rotated C_GT_LOC map above; it
# reads back 1 2 3 4, so `permute` dies in jc_aurora_check, never reaching the lane-map check).
# permute_check leaves the IP configured from the real table and rotates the table the lane-map
# check compares against: the check below must refuse it.
if {[info exists ::env(JC_AUR_MUTATE)] && $::env(JC_AUR_MUTATE) eq "permute_check"} {
  set rot {}
  for {set l 0} {$l < $nlanes} {incr l} {
    lappend rot $l [dict get $JC_LANES [expr {($l + 1) % $nlanes}]]
  }
  set JC_LANES $rot
  puts "AURORA_MUTANT permute_check"
}
create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -module_name jc_aurora
set ip [get_ips jc_aurora]

# finding 18: the refclk pick and the readback are jc_aurora_refclk/jc_aurora_check, shared
# from aurora_cfg.tcl (sourced above) since Task 5, never duplicated for Task 7 to extract.
# The refclk is set after the dict (its choices depend on C_UCOLUMN_USED/C_START_QUAD) and the
# full readback then covers it too.
if {[catch {set_property -dict $cfg $ip} msg]} { error "AURORA_CFG_FAIL set_property: $msg" }
lappend cfg CONFIG.C_REFCLK_SOURCE [jc_aurora_refclk $ip]
jc_aurora_check $ip $cfg
set pick [get_property CONFIG.C_REFCLK_SOURCE $ip]

generate_target all $ip
# synth_ip prints CRITICAL WARNING Vivado 12-5447 (not supported in project mode) but does run and
# write the stub and dcp (MEASURED 2026-11-10); the stub is all this script needs from it.
synth_ip $ip
set ipdir [get_property IP_DIR $ip]
# The generated sources live under <prj>.gen, not IP_DIR (<prj>.srcs, the .xci), and the GT
# XDC is three levels down (ip_0/synth/jc_aurora_gt.xdc, MEASURED 2026-11-10): search the whole
# project for the IP's files rather than globbing two levels of IP_DIR.
set gendirs [lsort -unique [concat $ipdir [glob -nocomplain -type d $out/prj/aur.gen/sources_1/ip/jc_aurora]]]
puts "AURORA_IPDIRS $gendirs"
set xdcs [lsort -unique [split [exec sh -c "find $gendirs -name '*.xdc' -type f || true"] "\n"]]
# GT LOCs as the IP wrote them, against the lane table (the configured map, not the intent).
# Format (MEASURED, ip_0/synth/jc_aurora_gt.xdc):
#   set_property LOC GTYE4_CHANNEL_X0Y0 [get_cells -hierarchical -filter {NAME =~
#     *gen_channel_container[0].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
# Ordered by (container, inst) index, the core's channel order, not by file order.
set raw {}
foreach f $xdcs {
  if {$f eq ""} continue
  set fh [open $f]; set t [read $fh]; close $fh
  foreach {all site cont inst} [regexp -all -inline {set_property LOC (GTYE4_CHANNEL_X\d+Y\d+) \[get_cells [^\]]*?gen_channel_container\[(\d+)\][^\]]*?gen_gtye4_channel_inst\[(\d+)\]} $t] {
    lappend raw [list [expr {$cont * 4 + $inst}] $site "gen_channel_container\[$cont\].gen_gtye4_channel_inst\[$inst\]"]
  }
}
set locs {}
set seen {}
foreach r [lsort -integer -index 0 [lsort -unique $raw]] {
  if {[dict exists $seen [lindex $r 0]]} { error "AURORA_CFG_FAIL locs: channel [lindex $r 2] has two LOCs ([dict get $seen [lindex $r 0]], [lindex $r 1])" }
  dict set seen [lindex $r 0] [lindex $r 1]
  lappend locs [lindex $r 1] [lindex $r 2]
}
puts "AURORA_LOCS $locs"
if {[llength $locs] / 2 != $nlanes} { error "AURORA_CFG_FAIL locs: [expr {[llength $locs]/2}] channel LOCs for $nlanes lanes" }
# lane l is the l-th channel of the core's channel order; the IP orders channels by lane
set sites {}
foreach {s c} $locs { lappend sites $s }
for {set l 0} {$l < $nlanes} {incr l} {
  set want [lindex [dict get $JC_LANES $l] 0]
  if {[lindex $sites $l] ne $want} { error "AURORA_CFG_FAIL lane map: lane $l at [lindex $sites $l], table says $want" }
}

# the stub the wrapper generator reads, and the sources the ECO question needs
set stub [lindex [split [exec sh -c "find $gendirs -name jc_aurora_stub.vhdl -type f"] "\n"] 0]
if {$stub eq ""} { error "AURORA_CFG_FAIL no jc_aurora_stub.vhdl under $gendirs" }
file copy -force $stub $out/jc_aurora_stub.vhdl
set gtg [exec sh -c "grep -rln -e GTGREFCLK0 -e QPLL0REFCLKSEL $gendirs || true"]
puts "AURORA_GTG_SOURCES $gtg"
puts "AURORA_IP_OK nlanes=$nlanes rate=$rate mode=$mode refclk=$pick out=$out"
