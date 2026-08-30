# analyze_paths.tcl -- TRACK TIMING, 2026-08-30.
#
# Characterise the setup-failing endpoints of the composed A+B+C+D design,
# read from TRACK COMPOSE4's PLACED checkpoint (which survived the 01:25 box
# hang).  Report only.  NO HARDWARE: open_checkpoint and report_* only.
#
# THE QUESTION this answers: the brief said "256 of 1,027,089 endpoints fail,
# 0.025%, a small number of specific paths".  That was the POST-SYNTHESIS
# number.  The placed report on disk says 33,767.  So: how many distinct
# paths, through which modules, one structure replicated or many?
#
# AND THE ONE THAT DECIDES THE FIX: is the critical path LOGIC delay (which
# pipelining fixes) or NET delay (which pipelining does not fix, and which at
# 99.83% CLB occupancy and congestion level 7 is the thing to expect)?

proc envdef {name dflt} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $dflt
}
set dcp    [envdef TT_DCP /mnt/storage/compose4/out/c4dev_placed.dcp]
set outdir [envdef TT_OUT /mnt/storage/timing_track/out]
set npath  [envdef TT_NPATH 20000]
file mkdir $outdir
set_param general.maxThreads 8

puts "TT_BEGIN analyze dcp=$dcp npath=$npath"
flush stdout
set t0 [clock seconds]
open_checkpoint $dcp
puts "TT_OPEN_SECONDS [expr {[clock seconds] - $t0}]"
puts "TT_STATE [get_property DESIGN_MODE [current_design]]"
flush stdout

# ---------------------------------------------------------------------------
# 1.  The failing paths, one per endpoint.  -nworst 1 makes each returned path
#     a DISTINCT endpoint, so the count is endpoints and not path permutations.
# ---------------------------------------------------------------------------
set t0 [clock seconds]
set paths [get_timing_paths -delay_type max -max_paths $npath -nworst 1 \
               -slack_lesser_than 0 -sort_by slack]
puts "TT_GETPATHS_SECONDS [expr {[clock seconds] - $t0}]"
puts "TT_NFAIL_RETURNED [llength $paths]"
flush stdout

# Return the first n hierarchy levels of a cell/pin path name.
proc top_n {name n} {
    set f [split $name "/"]
    if {[llength $f] <= $n} { return $name }
    return [join [lrange $f 0 [expr {$n - 1}]] "/"]
}

array set b1 {}   ;# src-top -> dst-top, depth 1
array set b3 {}   ;# dst, depth 3
array set lvl {}  ;# logic levels histogram
set nnetdom 0     ;# paths where net delay > logic delay
set sum_slack 0.0
set sum_logic 0.0
set sum_net   0.0
set worst {}

set i 0
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN   $p]
    set sl [get_property SLACK $p]
    set ll [get_property LOGIC_LEVELS $p]
    set dd [get_property DATAPATH_DELAY $p]
    # Vivado exposes the logic/net split as these two properties on a path.
    set ld 0.0 ; set nd 0.0
    catch { set ld [get_property DATAPATH_LOGIC_DELAY $p] }
    catch { set nd [get_property DATAPATH_NET_DELAY   $p] }

    set k1 "[top_n $sp 1] -> [top_n $ep 1]"
    incr b1($k1)
    set k3 [top_n $ep 3]
    incr b3($k3)
    if {![info exists lvl($ll)]} { set lvl($ll) 0 }
    incr lvl($ll)
    if {$nd > $ld} { incr nnetdom }
    set sum_slack [expr {$sum_slack + $sl}]
    set sum_logic [expr {$sum_logic + $ld}]
    set sum_net   [expr {$sum_net   + $nd}]
    if {$i < 40} {
        lappend worst [format "TT_WORST %2d slack=%-8s lvl=%-3s dly=%-7s logic=%-7s net=%-7s\n          from %s\n          to   %s" \
            $i $sl $ll $dd $ld $nd $sp $ep]
    }
    incr i
}

puts "\n===== TT: THE FORTY WORST PATHS ====="
foreach w $worst { puts $w }
flush stdout

puts "\n===== TT: LOGIC vs NET DELAY, over [llength $paths] failing endpoints ====="
set n [llength $paths]
if {$n > 0} {
    puts [format "TT_MEAN_SLACK      %.3f ns" [expr {$sum_slack / $n}]]
    puts [format "TT_MEAN_LOGIC      %.3f ns" [expr {$sum_logic / $n}]]
    puts [format "TT_MEAN_NET        %.3f ns" [expr {$sum_net   / $n}]]
    puts [format "TT_MEAN_PCT_NET    %.1f %%" \
        [expr {100.0 * $sum_net / ($sum_net + $sum_logic + 1e-12)}]]
    puts [format "TT_NET_DOMINATED   %d of %d  (%.1f%%)" \
        $nnetdom $n [expr {100.0 * $nnetdom / $n}]]
}

puts "\n===== TT: LOGIC LEVELS HISTOGRAM ====="
foreach k [lsort -integer [array names lvl]] {
    puts [format "TT_LVL %3s  %6d" $k $lvl($k)]
}

puts "\n===== TT: FAILING ENDPOINTS BY TOP-LEVEL INSTANCE PAIR ====="
set rows {}
foreach k [array names b1] { lappend rows [list $b1($k) $k] }
foreach r [lsort -integer -decreasing -index 0 $rows] {
    puts [format "TT_B1 %7d  %s" [lindex $r 0] [lindex $r 1]]
}

puts "\n===== TT: FAILING ENDPOINTS BY DESTINATION, 3 LEVELS DEEP (top 40) ====="
set rows {}
foreach k [array names b3] { lappend rows [list $b3($k) $k] }
set rows [lsort -integer -decreasing -index 0 $rows]
set j 0
foreach r $rows {
    if {$j >= 40} break
    puts [format "TT_B3 %7d  %s" [lindex $r 0] [lindex $r 1]]
    incr j
}
puts "TT_B3_DISTINCT [llength $rows]"
flush stdout

# ---------------------------------------------------------------------------
# 2.  The full worst-path detail, for reading.
# ---------------------------------------------------------------------------
report_timing -delay_type max -max_paths 30 -nworst 1 -sort_by slack \
    -input_pins -file [file join $outdir timing_worst30.rpt]

# ---------------------------------------------------------------------------
# 3.  THE URAM LEAD.  Which memory primitives sit on the failing paths, and
#     what is the design's LUTRAM/BRAM population by instance?  URAM is 0 of
#     320.  This says whether anything on a failing path is a memory at all.
# ---------------------------------------------------------------------------
puts "\n===== TT: MEMORY PRIMITIVES ON THE FAILING PATHS ====="
array set memhit {}
set nmem 0
set scan [expr {[llength $paths] < 3000 ? [llength $paths] : 3000}]
for {set k 0} {$k < $scan} {incr k} {
    set p [lindex $paths $k]
    foreach c [get_cells -quiet -of_objects [get_pins -quiet -of_objects $p]] {
        set rn [get_property REF_NAME $c]
        if {[regexp {^(RAMB|URAM|RAM[0-9]+|RAMD|RAMS|SRL)} $rn]} {
            if {![info exists memhit($rn)]} { set memhit($rn) 0 }
            incr memhit($rn)
            incr nmem
        }
    }
}
puts "TT_MEMSCAN scanned=$scan cells_matched=$nmem"
foreach k [lsort [array names memhit]] {
    puts [format "TT_MEMREF %-12s %6d" $k $memhit($k)]
}

puts "\n===== TT: DEVICE MEMORY PRIMITIVE POPULATION ====="
foreach rn {RAMB36E2 RAMB18E2 URAM288 RAMD32 RAMD64E RAMS32 RAMS64E SRL16E SRLC32E} {
    puts [format "TT_POP %-10s %6d" $rn \
        [llength [get_cells -quiet -hier -filter "REF_NAME == $rn"]]]
}

puts "TT_DONE analyze"
