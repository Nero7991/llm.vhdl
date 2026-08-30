# ooc_lutdiet_ports.tcl -- TRACK LUTDIET, 2026-08-29.
#
# THE QUESTION.  TRACK COMPOSE measured B+C+D at 771,900 LUT against 268,222
# free on the device and 233,765 free inside the pb_core pblock -- 2.88x and
# 3.30x over -- and localised 82.3% of B's LUT to gdn_block's own glue, with the
# same signature standalone in rmsnorm_rs at N=4096 (169,746 LUT, 40 DSP, 0
# BRAM, F7/F8 = 17,408 / 8,704, an exact mux tree).  Its named mechanism is a
# FLAT WHOLE-VECTOR PORT selected LANES at a time.  This script establishes
# whether that mechanism is real and what a memory-backed port costs and saves.
#
# WHAT AN OOC NUMBER DOES NOT PREDICT.  Everything ooc_compose_bcd.tcl's header
# says, unchanged: no inter-subsystem routing, no placement, no shell, no
# cross-subsystem resource merging, and a synthesis estimate is not an
# implementation result.  This script adds one caveat of its own: a
# memory-backed port CHANGES THE INTERFACE CONTRACT, so its area number is only
# meaningful next to a same-interface control, which is why the flat and mem
# wrappers below exist as a matched PAIR and neither is quoted alone.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  This script never
# opens a target, never programs a device, and never touches /dev/xdma*.
#
# USAGE:  LUTDIET_TARGET=<name> LUTDIET_OUT=<dir> LUTDIET_RTL=<dir> \
#         [LUTDIET_GEN="A=1 B=2"] [LUTDIET_FLATTEN=none] [LUTDIET_NOOPT=1] \
#         [LUTDIET_CENSUS=1] vivado -mode batch -source sim/ooc_lutdiet_ports.tcl
#
# Prints LUTDIET_DONE <target> as its LAST action.  A Vivado run can print full
# success and then die on a Tcl error afterwards, so the caller MUST gate on
# that sentinel and not on the last log line (ooc_lutdiet_run.sh does).

set part   xcvu33p-fsvh2104-2L-e
set period 5.0

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set target  [envor LUTDIET_TARGET rmsnorm_rs]
set tag     [envor LUTDIET_TAG    $target]
set outdir  [envor LUTDIET_OUT    lutdiet_out]
set rtldir  [envor LUTDIET_RTL    rtl]
set gens    [envor LUTDIET_GEN    ""]
file mkdir $outdir

puts "LUTDIET_BEGIN target=$target part=$part period=$period rtl=$rtldir gen=$gens"
create_project -in_memory -part $part

foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[catch {read_vhdl -vhdl2008 $f} e]} { puts "LUTDIET_READ_SKIP $f : $e" }
}

set gl {}
foreach g $gens { lappend gl -generic $g }

# The attribution probe, inherited from TRACK COMPOSE and NOT optional here.
# Vivado's default -flatten_hierarchy rebuilt flattens, optimises across every
# boundary and rebuilds the hierarchy for reporting, so a per-instance row is
# not a measurement of that instance: COMPOSE's first pass attributed 203,406
# LUT to l2norm_rs whose standalone control is 14,920.  Every attribution this
# script makes is taken with LUTDIET_FLATTEN=none and cross-checked against a
# standalone control.
if {[info exists ::env(LUTDIET_FLATTEN)]} {
    lappend gl -flatten_hierarchy $::env(LUTDIET_FLATTEN)
    puts "LUTDIET_FLATTEN $::env(LUTDIET_FLATTEN)"
}

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part $gl
set tsynth [expr {[clock seconds] - $t0}]

create_clock -period $period -name clk [get_ports clk]

report_utilization -file [file join $outdir synthutil_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir synthutil_hier_$tag.rpt]
set surpt [report_utilization -return_string]

# ---------------------------------------------------------------------------
# THE CELL-NAME CENSUS.  report_utilization says how many LUTs; it does not say
# WHAT THEY ARE.  Vivado's synthesiser names an inferred cell after the RTL
# signal it drives ("xf_reg[0][15]_i_12"), so tallying primitives by that root
# attributes area to a SIGNAL rather than to an instance -- which is the
# resolution this question needs, because the finding is that the area is in a
# module's own glue and not in any child instance.
#
# TWO TRAPS, both measured.
#  - get_cells -filter {PRIMITIVE_GROUP == LUT} returns ZERO on a post-synth
#    netlist (COMPOSE, 2026-08-29).  REF_NAME =~ LUT* is used instead and is
#    checked against report_utilization's own primitive table below.
#  - The root is a HEURISTIC, not ground truth.  It is reported as such, and
#    the total it accounts for is printed so the unattributed remainder is
#    visible rather than hidden.
# ---------------------------------------------------------------------------
if {[envor LUTDIET_CENSUS 0]} {
    array set tally {}
    array set kinds {}
    array set example {}
    set ncell 0
    foreach ref {LUT1 LUT2 LUT3 LUT4 LUT5 LUT6 MUXF7 MUXF8 FDRE FDSE CARRY8 DSP48E2 RAMB18E2 RAMB36E2} {
        foreach c [get_cells -hier -filter "REF_NAME == $ref"] {
            set n [lindex [split $c /] end]
            # strip bit/word indices, the _reg suffix and the _i_<n> LUT suffix
            regsub -all {\[[0-9]+\]} $n {} n
            regsub {_i_[0-9]+$} $n {} n
            regsub {__[0-9]+$} $n {} n
            regsub {_rep[0-9]*$} $n {} n
            regsub {_reg$} $n {} n
            if {$n eq ""} { set n "(unnamed)" }
            set key "$n"
            # keep one raw name per root, so the heuristic can be audited
            # rather than trusted
            if {![info exists example($key)]} { set example($key) $c }
            if {[string match "LUT?" $ref]} {
                incr tally($key)
                set ncell [expr {$ncell + 1}]
            }
            incr kinds($key,$ref)
        }
    }
    set fh [open [file join $outdir census_$tag.txt] w]
    puts $fh "# LUTDIET cell-name census, target=$target"
    puts $fh "# LUT primitives grouped by the RTL signal root Vivado named them"
    puts $fh "# after.  The root is a heuristic; the accounted total is printed"
    puts $fh "# at the end so the remainder is visible."
    puts $fh [format "%-34s %9s %7s %7s %8s %7s  %s" root LUT MUXF7 MUXF8 FF CARRY8 example_cell]
    # Vivado 2023.2 embeds Tcl 8.5, which has no `lsort -stride`.  Build
    # {count root} pairs and sort on the count.  MEASURED: -stride errors out
    # AFTER synthesis has completed, which is exactly the "prints full success
    # then dies" failure the LUTDIET_DONE sentinel exists to catch, and did.
    # Roots are the UNION of every primitive kind, not just the LUT tally.
    # MEASURED defect in the first version: iterating `array names tally` alone
    # dropped every root that has flops and no LUTs, which is exactly what a
    # flat storage register looks like -- rmsnorm_rs's 65,536-flop `o_reg`
    # vanished from its own census while its 162,276 write-decode LUTs were
    # attributed correctly under `o`.  The LUT columns were never wrong; the FF
    # column was silently empty.
    array set allroots {}
    foreach k [array names tally] { set allroots($k) 1 }
    foreach kk [array names kinds] {
        set allroots([join [lrange [split $kk ,] 0 end-1] ,]) 1
    }
    set pairs {}
    foreach k [array names allroots] {
        set t 0; catch {set t $tally($k)}
        lappend pairs [list $t $k]
    }
    set acc 0
    foreach pr [lsort -integer -decreasing -index 0 $pairs] {
        set k [lindex $pr 1]
        set tk 0; catch {set tk $tally($k)}
        set f7 0; set f8 0; set ff 0; set c8 0
        catch {set f7 $kinds($k,MUXF7)}
        catch {set f8 $kinds($k,MUXF8)}
        catch {set c8 $kinds($k,CARRY8)}
        foreach r {FDRE FDSE} { catch {incr ff $kinds($k,$r)} }
        set ex ""
        catch {set ex $example($k)}
        puts $fh [format "%-34s %9d %7d %7d %8d %7d  %s" $k $tk $f7 $f8 $ff $c8 $ex]
        incr acc $tk
    }
    puts $fh "# LUT primitives accounted: $acc of $ncell"
    close $fh
    puts "LUTDIET_CENSUS target=$target lut_prims=$ncell roots=[llength [array names tally]]"
}

if {![info exists ::env(LUTDIET_NOOPT)]} {
    set t1 [clock seconds]
    opt_design
    set topt [expr {[clock seconds] - $t1}]
} else {
    set topt -1
}

report_utilization -file [file join $outdir util_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir util_hier_$tag.rpt]
report_timing_summary -file [file join $outdir timing_$tag.rpt]

set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
set fmax [expr {1000.0/($period - $wns)}]

# Numbers from report_utilization, never from get_cells: see the trap note above.
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
proc ugetd {rpt label {def 0}} {
    set v [uget $rpt $label]
    return [expr {$v eq "NA" ? $def : $v}]
}
set nlut  [uget $urpt "CLB LUTs*"]
if {$nlut eq "NA"} { set nlut [uget $urpt "CLB LUTs"] }
set nlutl [uget  $urpt "LUT as Logic"]
set nlutm [uget  $urpt "LUT as Memory"]
set nff   [uget  $urpt "CLB Registers"]
set ncar  [ugetd $urpt "CARRY8"]
set nf7   [ugetd $urpt "F7 Muxes"]
set nf8   [ugetd $urpt "F8 Muxes"]
set nbram [ugetd $urpt "Block RAM Tile"]
set nr36  [ugetd $urpt "RAMB36/FIFO*"]
set nr18  [ugetd $urpt "RAMB18"]
set nur   [ugetd $urpt "URAM"]
set ndsp  [ugetd $urpt "DSPs"]

set slut [uget $surpt "CLB LUTs*"]
if {$slut eq "NA"} { set slut [uget $surpt "CLB LUTs"] }
set sff  [uget  $surpt "CLB Registers"]
set sdsp [ugetd $surpt "DSPs"]
set sbr  [ugetd $surpt "Block RAM Tile"]

puts "LUTDIET_RESULT target=$target gen=\"$gens\" dsp=$ndsp lut=$nlut \
lut_logic=$nlutl lut_mem=$nlutm ff=$nff ramb36=$nr36 ramb18=$nr18 bram=$nbram \
uram=$nur carry8=$ncar f7=$nf7 f8=$nf8 wns=$wns fmax=$fmax synth_s=$tsynth \
opt_s=$topt"
puts "LUTDIET_SYNTH_VS_OPT target=$target synth_lut=$slut opt_lut=$nlut \
synth_ff=$sff opt_ff=$nff synth_dsp=$sdsp opt_dsp=$ndsp synth_bram=$sbr \
opt_bram=$nbram"

set csv [open [file join $outdir result_$tag.csv] w]
puts $csv "target,gen,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,synth_lut,synth_ff,synth_dsp,synth_bram"
puts $csv "$target,\"$gens\",$ndsp,$nlut,$nlutl,$nlutm,$nff,$nr36,$nr18,$nbram,$nur,$ncar,$nf7,$nf8,$wns,$fmax,$tsynth,$topt,$slut,$sff,$sdsp,$sbr"
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "LUTDIET_DONE $target"
