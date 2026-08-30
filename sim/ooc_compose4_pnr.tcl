# ooc_compose4_pnr.tcl -- TRACK COMPOSE4, 2026-08-29.
#
# THE QUESTION.  TRACK DISTRAM's 217,381 CLB LUT for subsystems B+C+D is the
# SUM of seven independent `synth_design -mode out_of_context
# -flatten_hierarchy none` runs with `opt_design` deliberately NOT run, taken
# across four different pinned trees.  Nothing in this project has ever placed
# or routed `gdn_block`, `attn_block` or any `seq_*` unit, and no RTL top
# composes A+B+C+D at all.  This script takes `compose4_top` -- which does --
# through synthesis, optimisation, placement and ROUTING on the real part, so
# the number stops being a sum of estimates.
#
# WHAT IT ESTABLISHES: fit, placement, routability, post-route timing.
# WHAT IT DOES NOT: arithmetic.  See hw/fk33/gen_compose4_top.py's docstring.
#
# NO HARDWARE.  synth_design / opt_design / place_design / route_design /
# report_* only.  Nothing here opens a cable, a target or a device.
#
# USAGE
#   C4_STAGE=synth C4_TAG=<tag> C4_OUT=<dir> C4_RTL=<dir> C4_FK33RTL=<dir> \
#       vivado -mode batch -source sim/ooc_compose4_pnr.tcl
#   C4_STAGE=impl  C4_TAG=<tag> C4_OUT=<dir> C4_DCP=<synth.dcp> [C4_PBLOCK=1] \
#       vivado -mode batch -source sim/ooc_compose4_pnr.tcl
#
# THE STAGES ARE SEPARATE VIVADO INVOCATIONS ON PURPOSE.  A composed
# place-and-route of all four subsystems is the largest job attempted in this
# project, the box has 31 GB and a systemd-oomd history (2026-07-04), and a
# checkpoint between the two means an implementation that dies does not cost
# the synthesis as well.  It also makes each stage's peak RSS attributable.
#
# EACH STAGE PRINTS `C4_DONE <stage> <tag>` AS ITS LAST ACTION.  Vivado can
# print full success and then die on a Tcl error afterwards, and
# `lsort -stride` failing AFTER a complete synthesis is a measured instance in
# this project, so the caller MUST gate on that sentinel and never on the last
# log line.

proc envdef {name dflt} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $dflt
}

set part    [envdef C4_PART   xcvu33p-fsvh2104-2L-e]
set period  [envdef C4_PERIOD 5.0]
set stage   [envdef C4_STAGE  synth]
set tag     [envdef C4_TAG    c4]
set outdir  [envdef C4_OUT    /mnt/storage/compose4/out]
set rtldir  [envdef C4_RTL    /mnt/storage/compose4/tree/rtl]
set fkdir   [envdef C4_FK33RTL /mnt/storage/compose4/tree/hw/fk33/rtl]
set top     [envdef C4_TOP    compose4_top]
set dcp     [envdef C4_DCP    ""]
set usepb   [envdef C4_PBLOCK 0]
set nthread [envdef C4_THREADS 8]

file mkdir $outdir
set_param general.maxThreads $nthread

# THE PBLOCK RANGE, and why it is this range.
# hw/fk33/fk33_pblock.xdc:92 resizes `pb_core` to CLOCKREGION_X0Y0:X6Y3, and
# hw/fk33/build_fk33_pcieep.tcl:1749 ERRORS if the implemented design's range
# is anything else.  Column X7 is reserved by Tandem PCIe.  Reproducing the
# range is the whole point: an unconstrained OOC placement spreads over the
# die and answers a question the card does not ask.
set PB_RANGE {CLOCKREGION_X0Y0:CLOCKREGION_X6Y3}

proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}

# Numbers come from report_utilization, NOT from get_cells.  MEASURED by
# TRACK COMPOSE 2026-08-29: `get_cells -filter {PRIMITIVE_GROUP == LUT}`
# returns ZERO on an unplaced netlist while report_utilization shows the real
# count, so the get_cells form used by the older ooc_*.tcl silently reports 0.
proc emit_util {tag phase outdir} {
    report_utilization -file [file join $outdir util_${tag}_${phase}.rpt]
    report_utilization -hierarchical \
        -file [file join $outdir util_hier_${tag}_${phase}.rpt]
    set u [report_utilization -return_string]
    set lut [uget $u "CLB LUTs*"]
    if {$lut eq "NA"} { set lut [uget $u "CLB LUTs"] }
    set row [list \
        lut       $lut \
        lut_logic [uget $u "LUT as Logic"] \
        lut_mem   [uget $u "LUT as Memory"] \
        ff        [uget $u "CLB Registers"] \
        carry8    [uget $u "CARRY8"] \
        f7        [uget $u "F7 Muxes"] \
        f8        [uget $u "F8 Muxes"] \
        bram      [uget $u "Block RAM Tile"] \
        uram      [uget $u "URAM"] \
        dsp       [uget $u "DSPs"] \
        clb       [uget $u "CLB"]]
    puts "C4_UTIL $tag $phase $row"
    return $row
}

# ---------------------------------------------------------------------------
proc c4_read_all {rtldir fkdir} {
    set n 0
    foreach f [lsort [glob -directory $rtldir *.vhd]] {
        if {[catch {read_vhdl -vhdl2008 $f} e]} {
            puts "C4_READ_SKIP $f : $e"
        } else { incr n }
    }
    foreach f [lsort [glob -directory $fkdir *.vhd]] {
        if {[catch {read_vhdl -vhdl2008 $f} e]} {
            puts "C4_READ_SKIP $f : $e"
        } else { incr n }
    }
    puts "C4_READ $n files"
}

# ---------------------------------------------------------------------------
if {$stage eq "elab"} {
    # ELABORATION ONLY.  `synth_design -rtl` builds the RTL netlist and stops:
    # minutes rather than an hour, and it catches every binding, width and
    # visibility error in the generated top before the expensive stage runs.
    puts "C4_BEGIN elab tag=$tag part=$part"
    create_project -in_memory -part $part
    c4_read_all $rtldir $fkdir
    synth_design -rtl -mode out_of_context -top $top -part $part
    puts "C4_ELAB_CELLS [llength [get_cells -quiet -hier]]"
    puts "C4_ELAB_PORTS [llength [get_ports -quiet]]"
    puts "C4_DONE elab $tag"

# ---------------------------------------------------------------------------
} elseif {$stage eq "synth"} {
    puts "C4_BEGIN synth tag=$tag part=$part period=$period"
    puts "C4_RTL  $rtldir"
    puts "C4_FK33 $fkdir"

    create_project -in_memory -part $part

    # Read every RTL file.  Vivado parses all of them and elaborates only what
    # the top references, so this needs no hand-maintained dependency list.
    c4_read_all $rtldir $fkdir

    # CLOCK BUFFERS ON AN OUT-OF-CONTEXT TOP -- MEASURED, do not "simplify".
    # `synth_design -mode out_of_context` inserts NO clock buffer: a four-flop
    # probe on this part came back with 0 BUFG cells and the clock net's TYPE
    # reported as LOCAL_CLOCK.  An out-of-context XDC carrying
    # `set_property CLOCK_BUFFER_TYPE BUFG [get_ports clk]` does not insert one
    # either -- also 0.  (And setting that property BEFORE synth_design in a
    # non-project flow is not merely useless, it ERRORS: there are no port
    # objects until synthesis has run.  `Invalid option value '' specified for
    # 'objects'`.)  So `compose4_top` instantiates BUFGCE itself, and the gate
    # after synthesis below refuses to continue without them, because a
    # 300,000-load clock on local routing makes every placement, routing and
    # timing number that follows meaningless.
    set t0 [clock seconds]
    synth_design -mode out_of_context -top $top -part $part
    set tsynth [expr {[clock seconds] - $t0}]
    puts "C4_SYNTH_SECONDS $tsynth"

    # THE TWO CLOCKS.  hw/fk33/results/build_e2e_2026-08-29/
    # e2e_timing_routed_summary.rpt puts clk_out2 and clk_out3 of clk_wiz_0
    # BOTH at 5.000 ns / 200.000 MHz, and hw/fk33/gen_fk33_engine.py's header
    # says core_clk and hbm_aclk are the engine's two domains.  So both get
    # $period, and they are declared ASYNCHRONOUS to each other because the
    # crossing between them lives inside rtl/axi_rd_port.vhd's per-port async
    # FIFO -- timing paths between them are not real paths, and leaving them
    # constrained would report failures that the hardware does not have.
    create_clock -period $period -name core_clk [get_ports core_clk]
    create_clock -period $period -name hbm_aclk [get_ports hbm_aclk]
    set_clock_groups -asynchronous \
        -group [get_clocks core_clk] -group [get_clocks hbm_aclk]

    set nbufg [llength [get_cells -quiet -hier -filter {REF_NAME =~ BUFG*}]]
    puts "C4_BUFG $nbufg"
    if {$nbufg < 2} {
        # An out-of-range natural, not `assert ... severity failure`: MEASURED
        # 2026-08-29 across three OOC runs that Vivado silently ignores the
        # latter in synthesis.  A Tcl `error` here does stop the run.
        error "C4 FAIL: only $nbufg BUFG cells after synthesis, expected 2. The\
clock would be routed on general interconnect and every timing and routing\
number below would be meaningless."
    }

    emit_util $tag synth $outdir
    report_timing_summary -file [file join $outdir timing_${tag}_synth.rpt]

    write_checkpoint -force [file join $outdir ${tag}_synth.dcp]
    puts "C4_DCP [file join $outdir ${tag}_synth.dcp]"
    puts "C4_DONE synth $tag"

# ---------------------------------------------------------------------------
} elseif {$stage eq "impl"} {
    if {$dcp eq "" || ![file exists $dcp]} {
        error "C4 FAIL: C4_DCP is '$dcp', which does not exist."
    }
    puts "C4_BEGIN impl tag=$tag dcp=$dcp pblock=$usepb"
    open_checkpoint $dcp

    if {$usepb} {
        create_pblock pb_core
        add_cells_to_pblock [get_pblocks pb_core] \
            [get_cells -quiet -filter {IS_PRIMITIVE == 0}] -clear_locs
        resize_pblock [get_pblocks pb_core] -add $PB_RANGE
        set r [get_property GRID_RANGES [get_pblocks pb_core]]
        puts "C4_PBLOCK_RANGE $r"
        if {$r ne $PB_RANGE} {
            error "C4 FAIL: pb_core range is '$r', not $PB_RANGE."
        }
        report_utilization -pblocks [get_pblocks pb_core] \
            -file [file join $outdir pbutil_${tag}_preplace.rpt]
    }

    set t0 [clock seconds]
    opt_design
    puts "C4_OPT_SECONDS [expr {[clock seconds] - $t0}]"
    emit_util $tag opt $outdir
    write_checkpoint -force [file join $outdir ${tag}_opt.dcp]

    set t0 [clock seconds]
    place_design
    puts "C4_PLACE_SECONDS [expr {[clock seconds] - $t0}]"
    emit_util $tag placed $outdir
    report_timing_summary -file [file join $outdir timing_${tag}_placed.rpt]
    report_design_analysis -congestion \
        -file [file join $outdir congestion_${tag}_placed.rpt]
    if {$usepb} {
        report_utilization -pblocks [get_pblocks pb_core] \
            -file [file join $outdir pbutil_${tag}_placed.rpt]
    }
    write_checkpoint -force [file join $outdir ${tag}_placed.dcp]

    set t0 [clock seconds]
    phys_opt_design -quiet
    puts "C4_PHYSOPT_SECONDS [expr {[clock seconds] - $t0}]"

    set t0 [clock seconds]
    route_design
    puts "C4_ROUTE_SECONDS [expr {[clock seconds] - $t0}]"

    emit_util $tag routed $outdir
    report_timing_summary -file [file join $outdir timing_${tag}_routed.rpt]
    report_route_status  -file [file join $outdir route_status_${tag}.rpt]
    report_drc           -file [file join $outdir drc_${tag}.rpt]
    report_design_analysis -congestion \
        -file [file join $outdir congestion_${tag}_routed.rpt]
    if {$usepb} {
        report_utilization -pblocks [get_pblocks pb_core] \
            -file [file join $outdir pbutil_${tag}_routed.rpt]
    }
    write_checkpoint -force [file join $outdir ${tag}_routed.dcp]

    # ROUTE STATUS, COUNTED RATHER THAN EYEBALLED.
    # This top is OUT OF CONTEXT and its 1,180 non-clock ports have no
    # buffers, so the nets attached to them CANNOT be fully routed and Vivado
    # reports them.  That is expected and is NOT a routing failure; a net with
    # a ROUTE_STATUS of ANTENNAS or CONFLICTS is.  So the two are counted
    # separately and printed separately, because reporting "0 nets with
    # routing errors" from a report that also lists thousands of unrouted port
    # nets would be the kind of silent-success claim this project keeps
    # finding.
    set n_err  [llength [get_nets -quiet -hier -filter \
        {ROUTE_STATUS == ANTENNAS || ROUTE_STATUS == CONFLICTS || ROUTE_STATUS == HIERPORT}]]
    set n_unr  [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED}]]
    set n_part [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == PARTIAL}]]
    set n_all  [llength [get_nets -quiet -hier]]
    puts "C4_ROUTE_STATUS nets=$n_all errors=$n_err unrouted=$n_unr partial=$n_part"

    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    puts "C4_TIMING wns=$wns whs=$whs"
    foreach c [get_clocks] {
        set p [get_timing_paths -to [get_clocks $c] -delay_type max -max_paths 1]
        if {[llength $p]} {
            puts "C4_CLKWNS [get_property NAME $c] period=[get_property PERIOD $c]\
 wns=[get_property SLACK $p]"
        }
    }
    puts "C4_DONE impl $tag"

} else {
    error "C4 FAIL: unknown C4_STAGE '$stage'"
}
