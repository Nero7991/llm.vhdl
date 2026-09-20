# sim/ooc_aidle.tcl -- TRACK AIDLE, 2026-09-20.
#
# ONE OOC DRAW OF weight_streamer AT THE FK33 GEOMETRY, with a primitive
# census and a post-synthesis timing estimate at two periods.
#
# THE QUESTION.  Subsystem A's read ports each deliver 2 beats per 3 core
# cycles because rtl/stream_fifo.vhd's and rtl/async_fifo.vhd's read-issue
# condition counts the beat LEAVING the output stage as if it were staying.
# matvec_core accepts a weight word only when all 27 ports present a beat in
# the SAME cycle, so that cadence is the array's rate: MEASURED 1.5101 core
# cycles per weight word on silicon against a structural floor of 1.000.
# FAST_POP fixes it.  This script prices the fix.
#
# WHY weight_streamer AND NOT fk33_engine.  The changed logic is entirely
# inside the FIFOs, and weight_streamer holds all 27 of them (24 weight + 3
# scale) with nothing else of size.  A whole-engine delta would put ~60 LUT of
# signal inside ~92,000 LUT of array noise; here the unit under test IS the
# thing that changed, which is what makes the delta attributable.  The
# descriptor master's 28th FIFO is not in this draw and is charged by
# proportion in the write-up, stated as DERIVED rather than measured.
#
# WHAT THIS NUMBER IS AND IS NOT.  synth_design + opt_design, out of context,
# no placement, no routing.  CLAUDE.md records phys_opt over-promising by
# 0.4-0.6 ns on this part and a synthesis estimate being worse still, so the
# WNS printed here orders the two configurations against EACH OTHER and says
# nothing about a routed card.  Labelled ESTIMATE wherever it is quoted.
#
# THE CENSUS WINS OVER THE LOG (CLAUDE.md: the inference log lies in both
# directions).  report_utilization AND an object-level get_cells census by
# REF_NAME are both written; `PRIMITIVE_GROUP == DSP` matches nothing on a
# post-synth netlist and raises only a WARNING, so REF_NAME =~ DSP* is used.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
#
# USAGE:  AIDLE_TAG=<tag> AIDLE_OUT=<dir> AIDLE_RTL=<dir of the closure>
#         AIDLE_GEN="FAST_POP=true" \
#         vivado -mode batch -nojournal -log <log> -source sim/ooc_aidle.tcl
#
# Prints AIDLE_DONE <tag> as its LAST action.  The caller gates on that
# line-anchored sentinel, because a Vivado run can print full success and then
# die on a Tcl error afterwards.

set part    xcvu33p-fsvh2104-2L-e
set target  weight_streamer

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag     [envor AIDLE_TAG $target]
set outdir  [envor AIDLE_OUT aidle_out]
set rtldir  [envor AIDLE_RTL rtl]
set gens    [envor AIDLE_GEN ""]
file mkdir $outdir

puts "AIDLE_BEGIN tag=$tag target=$target part=$part rtl=$rtldir gen=\"$gens\""
create_project -in_memory -part $part

foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[catch {read_vhdl -vhdl2008 $f} e]} { puts "AIDLE_READ_SKIP $f : $e" }
}

# THE GEOMETRY IS hw/fk33/gen_fk33_engine.py's, PASSED EXPLICITLY.  Every one
# of these equals what the generator emits, and every one is passed anyway so
# the draw cannot silently follow an entity default that moves.
set gl {}
foreach g [concat {NPORTS_W=24 NPORTS_S=3 AXI_DW=256 ADDR_W=40 ROWS_IF=48
                   BLK=32 DEPTH=512 MAXB=16 MAXOUT=16 DUAL_CLK=true} $gens] {
    lappend gl -generic $g
}

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part \
    -flatten_hierarchy none $gl
set tsynth [expr {[clock seconds] - $t0}]

# TWO CLOCKS, because DUAL_CLK = true and the two sides of every FIFO are in
# different domains.  `clk` is the 75 MHz card core clock and is the domain
# the changed logic lives in; `aclk` is the 250 MHz HBM AXI clock.
create_clock -name clk  -period 13.333 [get_ports clk]
create_clock -name aclk -period 4.0    [get_ports aclk]
set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks aclk]

opt_design

proc census {stage tag outdir} {
    set fh [open [file join $outdir census_${stage}_$tag.txt] w]
    foreach pat {LUT* FD* RAM* SRL* CARRY* MUXF* DSP* URAM*} {
        set cells [get_cells -hier -quiet -filter "REF_NAME =~ $pat"]
        set n [llength $cells]
        array unset byref
        foreach c $cells {
            set r [get_property REF_NAME $c]
            if {[info exists byref($r)]} { incr byref($r) } else { set byref($r) 1 }
        }
        puts $fh "CENSUS $stage pattern=$pat total=$n"
        foreach r [lsort [array names byref]] {
            puts $fh "CENSUS $stage   $r $byref($r)"
        }
    }
    close $fh
}
census opt $tag $outdir

report_utilization -file [file join $outdir util_$tag.rpt]
report_timing_summary -delay_type max -max_paths 5 \
    -file [file join $outdir timing_$tag.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]

# The headline numbers, parsed back by the runner from THIS line and not from
# the utilization report's formatting.
set lut   [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
set ff    [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
set carry [llength [get_cells -hier -quiet -filter {REF_NAME =~ CARRY*}]]
set muxf  [llength [get_cells -hier -quiet -filter {REF_NAME =~ MUXF*}]]
set ram   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAM*}]]
set bram  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]

puts "AIDLE_RESULT tag=$tag lut=$lut ff=$ff carry=$carry muxf=$muxf ram=$ram bram=$bram wns=$wns synth_s=$tsynth"
puts "AIDLE_DONE $tag"
