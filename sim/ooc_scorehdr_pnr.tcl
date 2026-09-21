# sim/ooc_scorehdr_pnr.tcl -- TRACK HDRCOST, 2026-09-20.
#
# PHASE 2: PLACE AND ROUTE a post-opt checkpoint written by ooc_scorehdr.tcl,
# then report the ROUTED core-clock WNS, the CLB site count (the card's actual
# binding resource) and the SCORE CONE's own worst paths.
#
# WHY IT ROUTES, AND WHY THE CONE IS REPORTED SEPARATELY FROM THE HEADLINE.
#
#  * On this part nothing before `route_design` orders two runs correctly.
#    CLAUDE.md records a phys_opt WNS over-promising by 0.4 to 0.6 ns twice,
#    and once INVERTING the verdict: a composed top read +0.006 with ZERO
#    failing endpoints pre-route and routed at -0.422.  `SCORE_HDR_TREE`'s
#    entire cost is combinational depth, so a pre-route number is not an
#    answer about it.
#
#  * TRACK LEVERCOST measured that NONE of `attn_block`'s top-200 paths lies
#    in this block's score FSM -- the worst core-domain path of both its arms
#    is `u_arr/p_reg_reg[117]/DSP_OUTPUT_INST` -> `u_arr/er_r_reg/D` at 18
#    logic levels, in the PV array.  So the headline WNS can be pinned by an
#    unrelated path and not move even if the lever's own cone got materially
#    worse.  TRACK GDNSYNTH hit exactly that an hour ago: -4.008 to three
#    decimals across four arms spanning 63,000 LUT.  A headline that does not
#    move is a fact about the other path.  The cone rows below are the
#    measurement; the headline is the context.
#
# NO PHYS_OPT.  Deliberate, and it is a control decision rather than a saving:
# phys_opt_design is directive-sensitive and its result is not a result on
# this part, so including it would add a stage whose behaviour differs between
# arms for reasons unrelated to the generic.  opt_design already ran in phase
# 1 and is inside the checkpoint, so every arm enters place_design from the
# same flow position.
#
# NO HARDWARE.  open_checkpoint / place_design / route_design / report_* only.
#
# USAGE: SH_DCP=<file> SH_TAG=<tag> SH_OUT=<dir> SH_PERIOD=13.333
#        SH_NPATH=200 vivado -mode batch -nojournal -source this.tcl
#
# Prints SCOREHDR_PDONE <tag> as its LAST action (line-anchored sentinel).

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set dcp    [envor SH_DCP    ""]
set tag    [envor SH_TAG    unnamed]
set outdir [envor SH_OUT    .]
set period [envor SH_PERIOD 13.333]
set npath  [envor SH_NPATH  200]

if {$dcp eq ""} { error "SCOREHDR_PABORT: SH_DCP is unset" }
file mkdir $outdir
puts "SCOREHDR_PBEGIN tag=$tag dcp=$dcp period=$period"

open_checkpoint $dcp
puts "SCOREHDR_POPENED tag=$tag cells=[llength [get_cells -hier -quiet]]"

# The checkpoint carries phase 1's constraints.  Drop and re-create, so this
# run's constraint is the only one in force and is identical across arms
# rather than inherited from whatever the writing run happened to do.
foreach c [get_clocks -quiet] {
    if {[catch {remove_clock $c} e]} { puts "SCOREHDR_PRMCLK $c : $e" }
}
set cp [get_ports -quiet clk]
if {[llength $cp] == 0} { error "SCOREHDR_PABORT: no port named clk" }
create_clock -period $period -name clk $cp
puts "SCOREHDR_PCLK tag=$tag period=$period"

# EVERY `get_timing_paths` GOES THROUGH HERE, AND THE REASON IS A RECORDED
# FAILURE MODE RATHER THAN CAUTION IN GENERAL.  TRACK LEVERCOST lost TWO
# 735-second draws to a reporting step that runs AFTER synthesis, opt_design,
# the census and the checkpoint have all succeeded: first an ungrouped
# `create_clock` pair, then a table separator handed to `get_clocks`, which
# reported `[Common 17-170] Unknown option` and took the whole run down.  Here
# the expensive phase is `route_design`, so the same class of mistake would
# cost hours rather than minutes.  A named, non-fatal gap in the reporting is
# recoverable from the saved `post_route_<tag>.dcp`; an abort after routing is
# the route thrown away.
proc tpaths {args} {
    if {[catch {set r [eval get_timing_paths $args]} e]} {
        puts "SCOREHDR_TPATHS_FAIL args=\"$args\" : $e"
        return {}
    }
    return $r
}

# MEASURED 2026-09-20, AND IT COST A COMPLETED 1,416-SECOND ROUTE.  This proc
# first read `LOGIC_DELAY` and `NET_DELAY`, which sound like siblings of
# `DATAPATH_DELAY` and are not:
#   ERROR: [Common 17-54] The object 'timing_path' does not have a property
#   'LOGIC_DELAY'.
# It fired AFTER place_design, route_design and both checkpoints had succeeded
# -- the same position in the flow as LEVERCOST's two lost draws -- and it got
# past the `tpaths` wrapper added an hour earlier because that wrapper guards
# `get_timing_paths`, not `get_property`.  A guard around the call that had
# already failed twice in this project did nothing about the call that had
# not.  Only the four properties below are used, all of them exercised by
# sim/ooc_levercost.tcl, and every read goes through a catch so a fifth
# unknown property degrades to a named gap instead of discarding a route.
proc pget {p prop} {
    if {[catch {set v [get_property $prop $p]} e]} { return "NOPROP:$prop" }
    return $v
}
proc pathline {p} {
    if {$p eq ""} { return "wns=NONE" }
    return "wns=[pget $p SLACK] levels=[pget $p LOGIC_LEVELS]\
 datapath=[pget $p DATAPATH_DELAY]\
 start=[pget $p STARTPOINT_PIN] end=[pget $p ENDPOINT_PIN]"
}

# REPORT-ONLY.  A routed checkpoint already exists; re-derive the reports from
# it rather than spending another route.  This is the project's own rule that
# a constraint or reporting mistake should cost a re-analysis and not a
# re-implementation, and it is only true because the checkpoint was written
# BEFORE the reporting section rather than after it.
set ronly [envor SH_REPORT_ONLY 0]
set t0 [clock seconds]
if {$ronly} {
    set tplace 0
    puts "SCOREHDR_REPORT_ONLY tag=$tag (no place_design, no route_design)"
} else {
place_design
set tplace [expr {[clock seconds] - $t0}]
puts "SCOREHDR_PLACE_SECONDS tag=$tag $tplace"
set pp [lindex [tpaths -delay_type max -max_paths 1 -nworst 1] 0]
if {$pp ne ""} {
    puts "SCOREHDR_PLACED_WNS tag=$tag wns=[pget $pp SLACK]\
 levels=[pget $pp LOGIC_LEVELS]"
}
write_checkpoint -force [file join $outdir post_place_$tag.dcp]
}

set t1 [clock seconds]
if {$ronly} {
    set troute 0
} else {
route_design
set troute [expr {[clock seconds] - $t1}]
puts "SCOREHDR_ROUTE_SECONDS tag=$tag $troute"
write_checkpoint -force [file join $outdir post_route_$tag.dcp]
}

report_route_status -file [file join $outdir routestatus_$tag.rpt]
report_utilization  -file [file join $outdir routeutil_$tag.rpt]
report_utilization  -hierarchical -file [file join $outdir routeutil_hier_$tag.rpt]
set urpt [report_utilization -return_string]

proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}

# THE ROUTE MUST BE COMPLETE BEFORE ANY TIMING NUMBER IS QUOTED.  A partially
# routed design reports timing happily and the number means nothing.  This is
# the same shape as gating on a waiter instead of on the work's own sentinel.
set rstat [report_route_status -return_string]
set nunrouted "NA"; set nnets "NA"
foreach line [split $rstat "\n"] {
    if {[regexp {#\s+of\s+unrouted\s+nets[\.\s]*:\s*(\d+)} $line -> v]} { set nunrouted $v }
    if {[regexp {#\s+of\s+logical\s+nets[\.\s]*:\s*(\d+)} $line -> v]} {
        if {$nnets eq "NA"} { set nnets $v }
    }
}
puts "SCOREHDR_ROUTESTATUS tag=$tag nets=$nnets unrouted=$nunrouted"

report_timing_summary -delay_type max -max_paths 5 \
    -file [file join $outdir tsum_$tag.rpt]
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
    # The table's own separator row starts `-----`, and `get_clocks -quiet
    # -----` reports `[Common 17-170] Unknown option` -- `-quiet` suppresses
    # "no matching object", NOT a bad option, and `--` is not accepted either.
    # The token must be REJECTED here, never handed to the command.
    if {[string index $nm 0] eq "-"} continue
    if {$nm eq "Clock"} continue
    if {[llength [get_clocks -quiet $nm]] == 0} continue
    puts "SCOREHDR_INTRA tag=$tag clk=$nm wns=[lindex $f 1] tns=[lindex $f 2]\
 failing=[lindex $f 3] endpoints=[lindex $f 4]"
}

set gp [lindex [tpaths -delay_type max -max_paths 1 -nworst 1] 0]
puts "SCOREHDR_WORST_GLOBAL tag=$tag [pathline $gp]"

# ---------------------------------------------------------------------------
# THE SCORE CONE.  Reported by NAME PATTERN rather than by trusting the
# headline to notice it.  Endpoints and startpoints separately, because a
# deeper compare tree lengthens paths INTO e_min and a wider parallel subtract
# lengthens paths INTO shb, while a tree register feeding the next fold
# lengthens paths OUT of tv.
#
# Each cone is guarded with -quiet and reports NONE rather than erroring when
# the arm does not contain it: `tv_reg` exists only when HDR_TREE > 0, and an
# arm that lacks it is a RESULT, not a failure.
# ---------------------------------------------------------------------------
proc cone {tag outdir name pat npath} {
    set cells [get_cells -hier -quiet -filter "NAME =~ $pat && REF_NAME =~ FD*"]
    if {[llength $cells] == 0} {
        puts "SCOREHDR_CONE tag=$tag cone=$name cells=0 to=NONE from=NONE\
 (no sequential cell matches $pat in this arm)"
        return
    }
    set tp [lindex [tpaths -delay_type max -max_paths 1 -nworst 1 -to $cells] 0]
    set fp [lindex [tpaths -delay_type max -max_paths 1 -nworst 1 -from $cells] 0]
    puts "SCOREHDR_CONE tag=$tag cone=$name cells=[llength $cells]"
    puts "SCOREHDR_CONE_TO   tag=$tag cone=$name [pathline $tp]"
    puts "SCOREHDR_CONE_FROM tag=$tag cone=$name [pathline $fp]"
    set fh [open [file join $outdir cone_${name}_$tag.txt] w]
    puts $fh "# cone=$name tag=$tag  (slack levels start -> end), worst $npath into the cone"
    foreach p [tpaths -delay_type max -max_paths $npath -nworst 1 -to $cells] {
        puts $fh "[pget $p SLACK] [pget $p LOGIC_LEVELS]\
 [pget $p STARTPOINT_PIN] -> [pget $p ENDPOINT_PIN]"
    }
    puts $fh "# --- out of the cone ---"
    foreach p [tpaths -delay_type max -max_paths $npath -nworst 1 -from $cells] {
        puts $fh "[pget $p SLACK] [pget $p LOGIC_LEVELS]\
 [pget $p STARTPOINT_PIN] -> [pget $p ENDPOINT_PIN]"
    }
    close $fh
}

cone $tag $outdir score_all "*u_sq*"        $npath
cone $tag $outdir score_emin "*u_sq*e_min_reg*" 50
cone $tag $outdir score_shb  "*u_sq*shb_reg*"   50
cone $tag $outdir score_tv   "*u_sq*tv_reg*"    50
cone $tag $outdir score_st   "*u_sq*state_reg*" 50

# The global distribution, in a form two arms can be diffed on directly.  A
# lever can add a path slower than its neighbours and still not become THE
# worst path, in which case the WNS does not move and the arm looks free when
# it is merely second.
set fh [open [file join $outdir paths_$tag.txt] w]
puts $fh "# top-$npath routed paths, tag=$tag (slack levels start -> end)"
set n 0
foreach p [tpaths -delay_type max -max_paths $npath -nworst 1] {
    puts $fh "[pget $p SLACK] [pget $p LOGIC_LEVELS]\
 [pget $p STARTPOINT_PIN] -> [pget $p ENDPOINT_PIN]"
    incr n
}
close $fh
puts "SCOREHDR_PATHS tag=$tag n=$n"

# How many of the top-N are in the cone at all.  This is the number that says
# whether the headline was ever capable of answering the question.
set inN 0
foreach p [tpaths -delay_type max -max_paths $npath -nworst 1] {
    if {[string match "*u_sq*" [pget $p ENDPOINT_PIN]]
     || [string match "*u_sq*" [pget $p STARTPOINT_PIN]]} { incr inN }
}
puts "SCOREHDR_CONESHARE tag=$tag top=$npath in_score_cone=$inN"

puts "SCOREHDR_PRESULT tag=$tag clb=[uget $urpt CLB]\
 lut_sites=[uget $urpt {CLB LUTs*}] lut_logic=[uget $urpt {LUT as Logic}]\
 lut_mem=[uget $urpt {LUT as Memory}] ff=[uget $urpt {CLB Registers}]\
 carry8=[uget $urpt CARRY8] f7=[uget $urpt {F7 Muxes}] f8=[uget $urpt {F8 Muxes}]\
 bram=[uget $urpt {Block RAM Tile}] dsp=[uget $urpt DSPs]\
 place_s=$tplace route_s=$troute"

set csv [open [file join $outdir pnr_$tag.csv] w]
puts $csv "tag,clb,lut_sites,lut_logic,lut_mem,ff,carry8,f7,f8,bram,dsp,place_s,route_s,unrouted"
puts $csv "$tag,[uget $urpt CLB],[uget $urpt {CLB LUTs*}],[uget $urpt {LUT as Logic}],[uget $urpt {LUT as Memory}],[uget $urpt {CLB Registers}],[uget $urpt CARRY8],[uget $urpt {F7 Muxes}],[uget $urpt {F8 Muxes}],[uget $urpt {Block RAM Tile}],[uget $urpt DSPs],$tplace,$troute,$nunrouted"
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "SCOREHDR_PDONE $tag"
