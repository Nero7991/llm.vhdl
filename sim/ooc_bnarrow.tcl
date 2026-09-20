# sim/ooc_bnarrow.tcl -- TRACK BNARROWSYN, 2026-09-20.
#
# ONE OOC DRAW OF gdn_state_store AT THE 9B GEOMETRY, with a primitive census
# and a post-synthesis timing estimate at TWO periods.  It is
# sim/ooc_bmover.tcl (TRACK BMOVERSYN, 4bc5f48) with three changes and they
# are the only ones: the sentinel and message prefixes are BNARROW_, the
# census carries an extra `dsp48` row counting `REF_NAME == DSP48E2` rather
# than `=~ DSP*` (that track MEASURED the hierarchical walk returning 36 for
# a netlist holding 4, because it sees the macro AND its eight DSP_* leaves),
# and the RAMB rows are split so RAMB36E2 and RAMB18E2 are reported
# separately -- a RAMB18 is half a tile and the budget this has to fit is
# counted in TILES.
#
# THE QUESTION.  TRACK BNARROW (748ff91) added the generic `NWIDE` to
# gdn_state_store: the three NARROW movers -- exponents, conv taps, constants
# -- get a beat-wide port, which needs gdn_exp_mem banked 32 ways and the two
# conv memories banked on a THREE-axis (slot, lane, sub-group) scheme giving
# 48 and 64 banks of 512 x 16.  It cut a 9B B job from 307,784 to 222,805
# cycles in GHDL and NO VIVADO RAN.  Its area claim is DERIVED (+28 BRAM
# tiles) and the placed card has 105 free tiles, so the census is the gate.
#
# WHAT THIS NUMBER IS AND IS NOT.  synth_design + opt_design, out of context,
# no placement, no routing.  CLAUDE.md records phys_opt over-promising by
# 0.4-0.6 ns on this part, once inverting a verdict, and synthesis estimates
# being worse than that.  The WNS printed here orders the arms against EACH
# OTHER and says nothing about a routed card.  Labelled ESTIMATE everywhere.
#
# THE CENSUS WINS OVER THE LOG.  `[Synth 8-10226]` (URAM request refused) and
# `[Synth 8-7186]` (ram_style ignored) are both on record in this project as
# having lied, in both directions.  The runner counts them in every log and
# this script writes an object-level census beside report_utilization so the
# three can be reconciled by hand.  `PRIMITIVE_GROUP == DSP` matches nothing
# on a post-synth netlist (WARNING, not error), so REF_NAME is used.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
#
# USAGE:  BN_TAG=<tag> BN_OUT=<dir> BN_RTL=<dir of the closure>
#         BN_GEN="PIPE=true WIDE=true MAXOUT=8 NWIDE=true" \
#         vivado -mode batch -nojournal -log <log> -source sim/ooc_bnarrow.tcl
#
# Prints BNARROW_DONE <tag> as its LAST action.  The caller gates on that
# line-anchored sentinel, because a Vivado run can print full success and
# then die on a Tcl error afterwards.

set part    xcvu33p-fsvh2104-2L-e
set target  gdn_state_store
set periods {13.333 5.0}

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag     [envor BN_TAG    $target]
set outdir  [envor BN_OUT    bnarrow_out]
set rtldir  [envor BN_RTL    rtl]
set gens    [envor BN_GEN    ""]
file mkdir $outdir

puts "BNARROW_BEGIN tag=$tag target=$target part=$part rtl=$rtldir gen=\"$gens\""
create_project -in_memory -part $part

foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[catch {read_vhdl -vhdl2008 $f} e]} { puts "BNARROW_READ_SKIP $f : $e" }
}

set gl {}
foreach g $gens { lappend gl -generic $g }

# -flatten_hierarchy none, the same choice as sim/ooc_bmover.tcl, so the
# hierarchical report attributes each primitive to u_mem / u_dma / u_exp /
# u_conv / u_cw / u_edma / u_cdma / u_kdma rather than to a rebuilt
# hierarchy, and so the arms are comparable with that track's four draws.
set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part \
    -flatten_hierarchy none $gl
set tsynth [expr {[clock seconds] - $t0}]

# ---------------------------------------------------------------------------
# THE CENSUS.  Object-level, by REF_NAME.  Written once after synthesis and
# once after opt_design; the post-opt one is the quoted one.
# ---------------------------------------------------------------------------
proc census {stage tag outdir} {
    set fh [open [file join $outdir census_${stage}_$tag.txt] w]
    puts $fh "# BNARROW census stage=$stage tag=$tag (get_cells -hier by REF_NAME)"
    set out {}
    foreach {label pat} {
        uram    {REF_NAME =~ URAM*}
        ramb36  {REF_NAME =~ RAMB36*}
        ramb18  {REF_NAME =~ RAMB18*}
        lutram  {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256* || REF_NAME =~ RAM512*}
        dsp48   {REF_NAME == DSP48E2}
        dsp     {REF_NAME =~ DSP*}
        lut     {REF_NAME =~ LUT*}
        ff      {REF_NAME =~ FD*}
        carry   {REF_NAME =~ CARRY*}
        f7      {REF_NAME == MUXF7}
        f8      {REF_NAME == MUXF8}
        srl     {REF_NAME =~ SRL*}
    } {
        set cells [get_cells -hier -quiet -filter $pat]
        set n [llength $cells]
        lappend out "$label=$n"
        puts $fh "## $label $n"
        # Memory-class primitives are the whole question here, so they are
        # listed by NAME: that is what attributes a URAM to u_mem's bank or a
        # RAMB18 to u_conv's, rather than to a total nobody can argue with.
        if {$label in {uram ramb36 ramb18 dsp48}} {
            foreach c [lsort $cells] { puts $fh "$c [get_property REF_NAME $c]" }
        } elseif {$label in {lutram ff lut}} {
            # Too many to name; tally by parent instance, which is the
            # attribution the budget question actually needs.
            array unset byinst
            foreach c $cells {
                set p [file dirname $c]
                if {![info exists byinst($p)]} { set byinst($p) 0 }
                incr byinst($p)
            }
            foreach p [lsort [array names byinst]] { puts $fh "$p $byinst($p)" }
        }
    }
    close $fh
    puts "BNARROW_CENSUS stage=$stage tag=$tag [join $out { }]"
    return $out
}

report_utilization -file [file join $outdir synthutil_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir synthutil_hier_$tag.rpt]
set surpt [report_utilization -return_string]
set scens [census synth $tag $outdir]

set t1 [clock seconds]
opt_design
set topt [expr {[clock seconds] - $t1}]

report_utilization -file [file join $outdir util_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir util_hier_$tag.rpt]
report_ram_utilization -file [file join $outdir ram_$tag.rpt]
set urpt [report_utilization -return_string]
set ocens [census opt $tag $outdir]

proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}
proc ugetd {rpt label {def 0}} {
    set v [uget $rpt $label]
    return [expr {$v eq "NA" ? $def : $v}]
}
proc utab {rpt} {
    set nlut [uget $rpt "CLB LUTs*"]
    if {$nlut eq "NA"} { set nlut [uget $rpt "CLB LUTs"] }
    return [list lut $nlut \
        lut_logic [uget  $rpt "LUT as Logic"] \
        lut_mem   [uget  $rpt "LUT as Memory"] \
        ff        [uget  $rpt "CLB Registers"] \
        carry8    [ugetd $rpt "CARRY8"] \
        f7        [ugetd $rpt "F7 Muxes"] \
        f8        [ugetd $rpt "F8 Muxes"] \
        bram      [ugetd $rpt "Block RAM Tile"] \
        ramb36    [ugetd $rpt "RAMB36/FIFO*"] \
        ramb18    [ugetd $rpt "RAMB18"] \
        uram      [ugetd $rpt "URAM"] \
        dsp       [ugetd $rpt "DSPs"]]
}
array set S [utab $surpt]
array set U [utab $urpt]

# ---------------------------------------------------------------------------
# TIMING, two periods, the same netlist.  create_clock on a source that
# already carries a clock REPLACES it (no -add), so the second period retimes
# the same design.  ESTIMATE: post-opt, unplaced, unrouted.
# ---------------------------------------------------------------------------
set tim {}
foreach period $periods {
    create_clock -period $period -name clk [get_ports clk]
    set ptag [string map {. p} $period]
    report_timing_summary -delay_type max -max_paths 3 \
        -file [file join $outdir timing_${ptag}_$tag.rpt]
    report_timing -delay_type max -max_paths 3 -nworst 1 \
        -file [file join $outdir worst_${ptag}_$tag.rpt]
    set p [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
    set wns   [get_property SLACK          $p]
    set sp    [get_property STARTPOINT_PIN $p]
    set ep    [get_property ENDPOINT_PIN   $p]
    set lvl   [get_property LOGIC_LEVELS   $p]
    set dly   [get_property DATAPATH_DELAY $p]
    set req   [get_property REQUIREMENT    $p]
    set fmax  [expr {1000.0/($period - $wns)}]
    puts "BNARROW_TIMING_ESTIMATE tag=$tag period=$period wns=$wns fmax_est=[format %.1f $fmax] \
levels=$lvl datapath=$dly req=$req start=$sp end=$ep"
    lappend tim $period $wns $lvl $sp $ep
}

puts "BNARROW_RESULT tag=$tag gen=\"$gens\" lut=$U(lut) lut_logic=$U(lut_logic) \
lut_mem=$U(lut_mem) ff=$U(ff) bram=$U(bram) ramb36=$U(ramb36) ramb18=$U(ramb18) \
uram=$U(uram) dsp=$U(dsp) carry8=$U(carry8) f7=$U(f7) f8=$U(f8) \
wns_13p333=[lindex $tim 1] wns_5p0=[lindex $tim 6] synth_s=$tsynth opt_s=$topt"
puts "BNARROW_SYNTH_VS_OPT tag=$tag synth_lut=$S(lut) opt_lut=$U(lut) \
synth_ff=$S(ff) opt_ff=$U(ff) synth_uram=$S(uram) opt_uram=$U(uram) \
synth_bram=$S(bram) opt_bram=$U(bram) synth_dsp=$S(dsp) opt_dsp=$U(dsp)"

set csv [open [file join $outdir result_$tag.csv] w]
puts $csv "tag,gen,lut,lut_logic,lut_mem,ff,bram_tile,ramb36,ramb18,uram,dsp,carry8,f7,f8,wns_13p333,levels_13p333,wns_5p0,levels_5p0,synth_s,opt_s,synth_lut,synth_ff,census_opt"
puts $csv "$tag,\"$gens\",$U(lut),$U(lut_logic),$U(lut_mem),$U(ff),$U(bram),$U(ramb36),$U(ramb18),$U(uram),$U(dsp),$U(carry8),$U(f7),$U(f8),[lindex $tim 1],[lindex $tim 2],[lindex $tim 6],[lindex $tim 7],$tsynth,$topt,$S(lut),$S(ff),\"[join $ocens { }]\""
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "BNARROW_DONE $tag"
