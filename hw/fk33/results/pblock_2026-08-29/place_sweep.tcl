# TRACK PBLOCK -- placement sweep on TRACK SHELL's post-opt_design checkpoint.
# NO HARDWARE.  place_design / report_* only.  No route in this session.
set OPT   "/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/eng_full/fk33_pcieep/fk33_pcieep.runs/impl_1/bd_wrapper_opt.dcp"
set OUT   "/tmp/claude-1000/-home-orencollaco-GitHub-llama-vhdl/329968a0-29c9-45a8-98b6-3274e5b48f2f/scratchpad/pblock/out"
file mkdir $OUT
set CORE  "bd_i/eng/inst/eng/dut/core"

set_param general.maxThreads 6

proc stamp {m} { puts "PBLOCK-STAMP [clock format [clock seconds] -format %H:%M:%S] $m" ; flush stdout }

# The clock-region row divisors for SLICE / DSP48E2 / RAMB36 Y coordinates are
# MEASURED from the device once, not assumed.  CONGEST's trap: LOC Y indices
# run on different scales per site type, so a single min/max over all LOCs is
# meaningless.
proc measure_divisors {} {
    global DIV
    foreach {t probe} {SLICE SLICE_X0Y DSP48E2 DSP48E2_X0Y RAMB36 RAMB36_X0Y} {
        set found 0
        for {set y 1} {$y < 400} {incr y} {
            set s [get_sites -quiet ${probe}${y}]
            set s0 [get_sites -quiet ${probe}0]
            if {[llength $s] == 0 || [llength $s0] == 0} { continue }
            if {[get_property CLOCK_REGION $s] ne [get_property CLOCK_REGION $s0]} {
                set DIV($t) $y ; set found 1 ; break
            }
        }
        if {!$found} { set DIV($t) 0 }
        puts "PBLOCK-DIV $t rows_per_clockregion=$DIV($t) cr0=[get_property CLOCK_REGION [get_sites -quiet ${probe}0]]"
    }
    flush stdout
}

proc region_hist {cellname tag} {
    global DIV
    set leaves [get_cells -quiet ${cellname}/*]
    set locs [get_property LOC $leaves]
    array set h {}
    set placed 0 ; set unknown 0
    foreach l $locs {
        if {$l eq ""} { continue }
        if {![regexp {^(.+)_X([0-9]+)Y([0-9]+)$} $l -> t x y]} { incr unknown ; continue }
        if {![info exists DIV($t)] || $DIV($t) == 0} { incr unknown ; continue }
        set row [expr {$y / $DIV($t)}]
        incr placed
        if {[info exists h($row)]} { incr h($row) } else { set h($row) 1 }
    }
    set tot 0
    for {set r 0} {$r <= 3} {incr r} { if {[info exists h($r)]} { incr tot $h($r) } }
    puts "PBLOCK-HIST $tag leaves=[llength $leaves] placed=$placed unmapped=$unknown"
    for {set r 3} {$r >= 0} {incr r -1} {
        set v 0 ; if {[info exists h($r)]} { set v $h($r) }
        puts [format "PBLOCK-HIST %s Yrow%d %8d  %6.2f%%" $tag $r $v [expr {$tot ? 100.0*$v/$tot : 0}]]
    }
    flush stdout
}

proc do_one {tag use_pblock pbrange directive} {
    global OPT OUT CORE
    stamp "=== BEGIN $tag pblock=$use_pblock range=$pbrange directive=$directive ==="
    if {[catch {open_checkpoint $OPT} e]} { puts "PBLOCK-FATAL open $tag: $e" ; return }
    stamp "$tag opened"
    measure_divisors

    if {$use_pblock} {
        if {[catch {
            create_pblock pb_core
            add_cells_to_pblock [get_pblocks pb_core] [get_cells $CORE]
            resize_pblock [get_pblocks pb_core] -add $pbrange
        } e]} { puts "PBLOCK-FATAL pblock $tag: $e" ; catch {close_design} ; return }
        puts "PBLOCK-PROOF $tag GRID_RANGES=[get_property GRID_RANGES [get_pblocks pb_core]]"
        puts "PBLOCK-PROOF $tag DERIVED_RANGES=[get_property DERIVED_RANGES [get_pblocks pb_core]]"
        puts "PBLOCK-PROOF $tag cells_in_pblock=[llength [get_cells -quiet -of_objects [get_pblocks pb_core]]]"
        catch {report_utilization -pblocks [get_pblocks pb_core] -file $OUT/${tag}_pblock_util_preplace.rpt}
        catch {write_xdc -force -constraints ALL $OUT/${tag}_constraints.xdc}
    }
    flush stdout

    stamp "$tag place_design start"
    if {[catch {place_design -directive $directive} e]} {
        puts "PBLOCK-FATAL place $tag: $e" ; catch {close_design} ; return
    }
    stamp "$tag place_design done"

    catch {report_utilization -file $OUT/${tag}_util.rpt}
    if {$use_pblock} { catch {report_utilization -pblocks [get_pblocks pb_core] -file $OUT/${tag}_pblock_util_placed.rpt} }
    stamp "$tag congestion start"
    catch {report_design_analysis -congestion -file $OUT/${tag}_congestion.rpt}
    stamp "$tag congestion done"
    catch {report_timing_summary -no_detailed_paths -file $OUT/${tag}_timing_placed.rpt}
    catch {report_clock_interaction -file $OUT/${tag}_clkint_placed.rpt}
    catch {report_clock_utilization -file $OUT/${tag}_clkutil_placed.rpt}
    if {[catch {region_hist $CORE $tag} e]} { puts "PBLOCK-HIST $tag ERROR $e" }
    stamp "$tag write_checkpoint start"
    catch {write_checkpoint -force $OUT/${tag}_placed.dcp}
    stamp "$tag write_checkpoint done"
    close_design
    stamp "=== END $tag ==="
}

# Baseline reference (CONGEST, bd_wrapper_placed.dcp, strategy
# Performance_RefinePlacement => place_design -directive ExtraPostPlacementOpt):
#   Y0 55.3%, Y1 40.8%, Y2 3.7%, Y3 0.2%.  Congestion level 7.

set PB {CLOCKREGION_X0Y1:CLOCKREGION_X7Y3}

do_one A   1 $PB ExtraPostPlacementOpt
do_one S   0 {}  AltSpreadLogic_high
do_one AS  1 $PB AltSpreadLogic_high

stamp "ALL DONE"
