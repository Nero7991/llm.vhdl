open_checkpoint /mnt/storage/fk33_builds/a450_hbm_r2/proj/routed.dcp
set ca [get_clocks clk_out1_a450_clk_wiz_a_0]
set ps [get_timing_paths -setup -to $ca -max_paths 100000 -nworst 1 -slack_lesser_than 0]
puts "ANA_NFAIL [llength $ps]"
set g [dict create]
foreach p $ps {
  set s [get_property STARTPOINT_PIN $p]
  regsub -all {\[\d+\]} $s {[*]} k
  regsub {g_t\[\*\]} $k {g_t[*]} k
  set sl [get_property SLACK $p]
  if {[dict exists $g $k]} { lassign [dict get $g $k] n w; dict set g $k [list [incr n] [expr {min($w,$sl)}]] } else { dict set g $k [list 1 $sl] }
}
set rows {}
dict for {k v} $g { lappend rows [list $k {*}$v] }
foreach r [lrange [lsort -real -index 2 $rows] 0 39] { puts "ANA_GRP n=[lindex $r 1] worst=[lindex $r 2] [lindex $r 0]" }
proc fo {p} { set m 0; foreach n [get_nets -quiet -of_objects $p] { set f [expr {[get_property FLAT_PIN_COUNT $n]-1}]; if {$f>$m} {set m $f} }; return $m }
set ar2 [get_cells a450_i/top/inst/a/g_split.u/ar2_reg]
set i 0
foreach p [get_timing_paths -setup -to $ca -max_paths 400 -nworst 1] {
  if {[string match *ar2_reg* [get_property STARTPOINT_PIN $p]]} continue
  if {[incr i] > 10} break
  set d [get_property DATAPATH_DELAY $p]; set nd [get_property DATAPATH_NET_DELAY $p]
  puts "ANA_NONRST $i SLACK [get_property SLACK $p] LEVELS [get_property LOGIC_LEVELS $p] FANOUT [fo $p] ROUTE_PCT [expr {round(100.0*$nd/$d)}] START [get_property STARTPOINT_PIN $p] END [get_property ENDPOINT_PIN $p]"
}
set rn [get_nets -of [get_pins a450_i/top/inst/a/g_split.u/ar2_reg/Q]]
puts "ANA_AR2NET $rn FANOUT [expr {[get_property FLAT_PIN_COUNT $rn]-1}] LOC [get_property LOC $ar2]"
puts "ANA_DONE"
