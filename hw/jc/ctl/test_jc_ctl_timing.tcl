# hw/jc/ctl/test_jc_ctl_timing.tcl -- unit check of jc_ctl_timing.tcl's consumer trace
# (jctl_drives, fix round 2) WITHOUT Vivado: run `tclsh hw/jc/ctl/test_jc_ctl_timing.tcl`.
# It mocks the five Vivado commands the trace uses (get_cells, get_pins, get_nets,
# get_property, and the -filter forms the procs pass) over a small netlist. The good
# netlist is the structure the controller MEASURED in /mnt/storage/fk33_builds/jcctl_ooc3
# (rak_s2_reg/Q -> ex/ack_prev_reg/D and ex/s_rvalid_i_1/I1). Each variant must refuse
# with the named JCCTL_SYNC message. Prints JCCTL_TCLTEST_PASS n, or exits 1.
# What this cannot check: that the real Vivado commands behave as mocked (-leaf across
# hierarchy, IS_SEQUENTIAL, net TYPE); only the controller's OOC run checks that.

# ---- mock netlist: cells (name -> IS_SEQUENTIAL), nets (name -> pins); pin = cell/PIN ----
proc net_reset {} {
  global CELLS NETS
  array unset CELLS; array unset NETS
  foreach {c s} {rak_s1_reg 1 rak_s2_reg 1 rst_s1_reg 1 rst_s2_reg 1
                 ex/ack_prev_reg 1 ex/s_rvalid_i_1 0 ex/st_reg 1 ex/have_i_1 0
                 fifo/ob_rp_i_1 0 q_ready_INST_0 0 q_vx_INST_0 0 rx/ack_t_reg 1
                 sync/st_r_reg 1 spare_reg 1 spare_lut 0} { set CELLS($c) $s }
  array set NETS {
    ack_t   {rx/ack_t_reg/Q rak_s1_reg/D}
    rak_s1  {rak_s1_reg/Q rak_s2_reg/D}
    rak_s2  {rak_s2_reg/Q ex/ack_prev_reg/D ex/s_rvalid_i_1/I1}
    rst_s1  {rst_s1_reg/Q rst_s2_reg/D}
    rst_s2  {rst_s2_reg/Q ex/st_reg/R ex/have_i_1/I0 q_ready_INST_0/I1 q_vx_INST_0/I1 fifo/ob_rp_i_1/I2}
  }
}
proc pin_dir {p} { expr {[lindex [split $p /] end] in {Q O} ? "OUT" : "IN"} }
proc pin_cell {p} { join [lrange [split $p /] 0 end-1] / }
proc filt_ok {obj f} {
  if {$f eq ""} { return 1 }
  if {![regexp {^(\w+) == (\w+)$} $f -> k v]} { error "mock: filter $f" }
  switch $k {
    REF_PIN_NAME { return [expr {[lindex [split $obj /] end] eq $v}] }
    DIRECTION    { return [expr {[pin_dir $obj] eq $v}] }
  }
  error "mock: filter key $k"
}
proc opts {argv} {
  set o [dict create quiet 0 hier 0 leaf 0 of {} filter {} obj {}]
  for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
      -quiet { dict set o quiet 1 } -hierarchical { dict set o hier 1 } -leaf { dict set o leaf 1 }
      -of_objects { dict set o of [lindex $argv [incr i]] }
      -filter { dict set o filter [lindex $argv [incr i]] }
      default { dict set o obj $a }
    }
  }
  return $o
}
proc get_cells {args} {
  global CELLS
  set o [opts $args]
  if {[dict get $o of] ne ""} { return [lsort -unique [lmap p [dict get $o of] {pin_cell $p}]] }
  set f [dict get $o filter]
  if {[regexp {NAME =~ "([^"]*)"} $f -> pat]} {
    return [lsort [lmap c [array names CELLS] {if {[string match $pat $c]} {set c} else continue}]]
  }
  set c [dict get $o obj]
  if {[info exists CELLS($c)]} { return $c }
  return {}
}
proc get_nets {args} {
  global NETS
  set o [opts $args]
  set r {}
  foreach p [dict get $o of] {
    foreach n [array names NETS] { if {$p in $NETS($n)} { lappend r $n } }
  }
  return $r
}
proc get_pins {args} {
  global CELLS NETS
  set o [opts $args]
  set f [dict get $o filter]
  set r {}
  if {[dict get $o leaf]} {
    foreach n [dict get $o of] { foreach p $NETS($n) { if {[filt_ok $p $f]} { lappend r $p } } }
    return $r
  }
  if {[dict get $o of] ne ""} {
    foreach c [dict get $o of] {
      # a flop has a Q pin even when no net is attached to it (as in Vivado)
      if {$CELLS($c) && [filt_ok $c/Q $f]} { lappend r $c/Q }
      foreach n [array names NETS] {
        foreach p $NETS($n) { if {[pin_cell $p] eq $c && [filt_ok $p $f]} { lappend r $p } }
      }
    }
    return [lsort -unique $r]
  }
  return [dict get $o obj]
}
proc get_property {prop obj} {
  global CELLS
  switch $prop {
    NAME { return $obj }
    IS_SEQUENTIAL { return $CELLS($obj) }
  }
  error "mock: property $prop"
}

source [file join [file dirname [file normalize [info script]]] jc_ctl_timing.tcl]

set npass 0; set nfail 0
proc case {name expect body} {
  global npass nfail
  net_reset
  uplevel #0 $body
  set rc [catch {
    jctl_drives rak_s1_reg rak_s2_reg "ex/*" [list "ex/*"] 0 ""
    jctl_drives rst_s1_reg rst_s2_reg "ex/*" [list "ex/*" "fifo/*"] 1 ""
  } msg]
  if {$expect eq "ok"} {
    set good [expr {$rc == 0}]
  } else {
    set good [expr {$rc != 0 && [string match "*$expect*" $msg]}]
  }
  if {$good} { incr npass; puts "TCLTEST OK   $name" } else {
    incr nfail; puts "TCLTEST FAIL $name: rc $rc msg {$msg}, expected {$expect}"
  }
}

case "measured netlist (ooc3) accepted" ok {}
case "executor takes the first ack stage" "first stage rak_s1_reg/Q drives" {
  set NETS(rak_s1) {rak_s1_reg/Q rak_s2_reg/D ex/ack_prev_reg/D}
  set NETS(rak_s2) {rak_s2_reg/Q ex/s_rvalid_i_1/I1}
}
case "ack second stage drives nothing" "rak_s2_reg/Q has no loads" { unset NETS(rak_s2) }
case "ack second stage drives outside ex" "outside" {
  lappend NETS(rak_s2) sync/st_r_reg/CE
}
case "ack into a top-level LUT (not allowed for the ack)" "outside" {
  lappend NETS(rak_s2) spare_lut/I0
}
case "executor takes the first reset stage" "first stage rst_s1_reg/Q drives" {
  lappend NETS(rst_s1) ex/st_reg/R
}
case "reset reaches only the FIFO gate, not ex" "drives nothing matching ex/*" {
  set NETS(rst_s2) {rst_s2_reg/Q fifo/ob_rp_i_1/I2 q_ready_INST_0/I1}
}
case "reset into a top-level FLOP" "outside" { lappend NETS(rst_s2) spare_reg/D }
case "reset into the frame core" "outside" { lappend NETS(rst_s2) rx/ack_t_reg/R }
case "reset second stage drives nothing" "rst_s2_reg/Q has no loads" { unset NETS(rst_s2) }

puts "JCCTL_TCLTEST_PASS $npass FAIL $nfail"
if {$nfail || $npass != 10} { exit 1 }
