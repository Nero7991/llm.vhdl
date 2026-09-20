# sim/ooc_levercost_timing.tcl -- TRACK LEVERCOST, 2026-09-20.
#
# TIMING ONLY, FROM A POST-OPT CHECKPOINT WRITTEN BY sim/ooc_levercost.tcl.
# No synthesis, no opt_design: it reads a netlist that already exists, applies
# the constraints, and dumps the intra-domain path DISTRIBUTION.
#
# WHY IT EXISTS.  `matvec_int4_desc_axi` at the card's 27-lane geometry costs
# ~735 s and 8 GB (plus ~4 GB of swap) per draw.  This track threw away four
# such draws to two successive bugs in a constraint/reporting step that runs
# AFTER every expensive phase has finished -- first two `create_clock`s with no
# `set_clock_groups`, then a table-separator row handed to `get_clocks`.  Each
# time, `synth_design`, `opt_design`, both censuses and every `report_*` had
# already succeeded.  **A constraint mistake should cost a re-analysis, not a
# re-synthesis**, and that is only true if the netlist was saved.  It is: the
# main script writes `post_opt_<tag>.dcp`.
#
# WHAT IT ADDS OVER THE WNS.  A lever can add a path slower than its
# neighbours and still not become THE worst path, in which case WNS does not
# move and the arm looks free when it is merely second.  MEASURED here: the
# worst core-domain path of both `FAST_POP` arms is
# `dw_reg[10][56]` -> `err_code_reg[0]/CE` at 16 logic levels, which is
# nowhere near the FIFO cone the lever touches -- so comparing WNS could only
# ever produce a BOUND.  Dumping the top N per arm and diffing the two
# distributions is what turns "the worst path did not move" into "no path in
# the streamer cone moved either".
#
# NO HARDWARE.  read_checkpoint / report_* only.
#
# USAGE:  LC_DCP=<file> LC_TAG=<tag> LC_OUT=<dir> LC_CLK="clk=13.333 ..."
#         LC_NPATH=200 vivado -mode batch -nojournal -source this.tcl
#
# Prints LEVERCOST_TDONE <tag> as its LAST action (line-anchored sentinel).

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set dcp    [envor LC_DCP   ""]
set tag    [envor LC_TAG   unnamed]
set outdir [envor LC_OUT   .]
set clks   [envor LC_CLK   "clk=13.333"]
set npath  [envor LC_NPATH 200]

if {$dcp eq ""} { error "LEVERCOST_TABORT: LC_DCP is unset" }
file mkdir $outdir
puts "LEVERCOST_TBEGIN tag=$tag dcp=$dcp npath=$npath"

open_checkpoint $dcp
puts "LEVERCOST_TOPENED tag=$tag cells=[llength [get_cells -hier -quiet]]"

# The checkpoint carries whatever constraints the writing run had applied.
# Drop them so this run's constraints are the only ones in force -- otherwise
# a second create_clock on the same port silently REPLACES the first and the
# state depends on what the earlier script happened to do before writing.
foreach c [get_clocks -quiet] {
    if {[catch {remove_clock $c} e]} { puts "LEVERCOST_TRMCLK $c : $e" }
}

set made {}
foreach kv $clks {
    set parts [split $kv "="]
    set port  [lindex $parts 0]
    set per   [lindex $parts 1]
    set pobj  [get_ports -quiet $port]
    if {[llength $pobj] == 0} { puts "LEVERCOST_TCLKMISS tag=$tag port=$port"; continue }
    create_clock -period $per -name $port $pobj
    lappend made $port $per
    puts "LEVERCOST_TCLKMADE tag=$tag port=$port period=$per"
}

# Unrelated clocks are asynchronous; without this EVERY reported worst path is
# a CDC crossing timed against the two periods' common multiple.
if {[llength $made] > 2} {
    set groups {}
    foreach {port per} $made { lappend groups -group [get_clocks $port] }
    eval set_clock_groups -asynchronous $groups
    puts "LEVERCOST_TCLKASYNC tag=$tag groups=[expr {[llength $made]/2}]"
}

report_timing_summary -delay_type max -max_paths 3 \
    -file [file join $outdir tsum_$tag.rpt]

# The Intra Clock Table, parsed from the file just written.
# NOTE THE GUARD AND WHY IT IS SHAPED THIS WAY: the table's own separator row
# begins `-----`, and `get_clocks -quiet -----` reports
# `ERROR: [Common 17-170] Unknown option '-----'` -- `-quiet` suppresses "no
# matching object", NOT a malformed option.  The obvious fix, `get_clocks -- $nm`,
# fails the SAME WAY because get_clocks does not accept `--` either.  So the
# token must be REJECTED before the call, never passed to it defensively.
set fh [open [file join $outdir tsum_$tag.rpt] r]
set tsum [read $fh]
close $fh
set inintra 0
foreach line [split $tsum "\n"] {
    if {[string match "*Intra Clock Table*" $line]} { set inintra 1; continue }
    if {[string match "*Inter Clock Table*" $line]} { set inintra 0; continue }
    if {!$inintra} continue
    set f [regexp -all -inline {\S+} $line]
    if {[llength $f] < 5} continue
    set nm [lindex $f 0]
    if {[string index $nm 0] eq "-"} continue
    if {$nm eq "Clock"} continue
    if {[llength [get_clocks -quiet $nm]] == 0} continue
    puts "LEVERCOST_TINTRA tag=$tag clk=$nm wns=[lindex $f 1] tns=[lindex $f 2]\
 failing=[lindex $f 3] endpoints=[lindex $f 4]"
}

# THE DISTRIBUTION.  One line per path, sorted worst-first by construction, in
# a form two arms can be diffed on directly.
foreach {port per} $made {
    set out [open [file join $outdir paths_${port}_$tag.txt] w]
    set n 0
    foreach p [get_timing_paths -delay_type max -max_paths $npath -nworst 1 \
                   -to [get_clocks -quiet $port]] {
        puts $out "[format %.3f [get_property SLACK $p]]\
 [get_property LOGIC_LEVELS $p]\
 [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
        incr n
    }
    close $out
    puts "LEVERCOST_TPATHS tag=$tag clk=$port n=$n file=paths_${port}_$tag.txt"
}

close_project
# THE SENTINEL.  Nothing may follow it.
puts "LEVERCOST_TDONE $tag"
