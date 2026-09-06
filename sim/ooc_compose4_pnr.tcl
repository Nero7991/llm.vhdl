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
# THE TWO PERIODS ARE DIFFERENT, and getting this wrong is optimistic in the
# direction that matters.  hw/fk33/gen_pcieep.py:310 sets ENG_CORE_MHZ = 200.000
# and :800 puts core_clk on clk_wiz_0/clk_out3, so core_clk is 5.000 ns.  But
# :802 connects the engine's hbm_aclk to `xdma/axi_aclk`, NOT to a clk_wiz
# output, and :1255 of the same file says in as many words that the tool would
# otherwise "time every gray pointer ... against a 200/250 MHz common period".
# So hbm_aclk is 250 MHz / 4.000 ns.  Constraining it at 5.0 would have relaxed
# every one of subsystem A's 28 read masters by 25%.
set period  [envdef C4_PERIOD     5.0]
set aperiod [envdef C4_PERIOD_HBM 4.0]
set stage   [envdef C4_STAGE  synth]
set tag     [envdef C4_TAG    c4]
set outdir  [envdef C4_OUT    /mnt/storage/compose4/out]
set rtldir  [envdef C4_RTL    /mnt/storage/compose4/tree/rtl]
set fkdir   [envdef C4_FK33RTL /mnt/storage/compose4/tree/hw/fk33/rtl]
set top     [envdef C4_TOP    compose4_top]
set dcp     [envdef C4_DCP    ""]
set usepb   [envdef C4_PBLOCK 0]
set nthread [envdef C4_THREADS 8]
# IMPLEMENTATION DIRECTIVES, added 2026-09-04.  ALL DEFAULT TO EMPTY, which
# calls each command exactly as before, so every measurement taken before this
# change still describes what it measured.  A directive is passed ONLY when its
# variable is non-empty.
#   MEASURED with all four empty: routed core_clk WNS -0.402 (185.1 MHz) on the
#   shipping config, `impl_pb`, 2026-09-04.
#
#   AMENDED 2026-09-05: DO NOT COMPARE AGAINST THAT NUMBER.  No `impl_pb`
#   artifact survives anywhere in the repo or the session scratch, so its
#   netlist cannot be identified, and the tree changed the following day.  The
#   instruction that used to stand here -- "that is the baseline any directive
#   run must be compared against" -- sent every later run to an unverifiable
#   reference, and `c4nd`'s -0.422 was called a directive LOSS against it on
#   that basis.  That verdict is withdrawn in both directions.
#
#   There is currently NO measured composed baseline with all four empty on the
#   current tree.  Anything calling itself one is either a different netlist
#   (`wire4` carries 327.5 BRAM against `c4nd`'s 253.5) or unrecoverable.
#   See docs/debugging/2026-09-05_the-composed-timing-record-is-not-comparable.md
#
#   The stage caveat still stands: never compare a routed figure against a
#   synthesis one such as the +0.346.
set optdir   [envdef C4_OPT_DIR     ""]
set placedir [envdef C4_PLACE_DIR   ""]
set physdir  [envdef C4_PHYSOPT_DIR ""]
set routedir [envdef C4_ROUTE_DIR   ""]
proc c4_dir_args {d} { return [expr {$d eq "" ? {} : [list -directive $d]}] }

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
    # Stash for the C4_TIMING fingerprint.  A WNS is only comparable against
    # another WNS from the SAME netlist, and BRAM/DSP are the discriminator
    # because they are fixed at synthesis and no implementation directive moves
    # them.  Keeping them one line away from the verdict is what let four
    # composed figures be compared across three different netlists.
    set ::c4_last_util $row
    return $row
}

# WHY A PLACED VERDICT IS PRINTED BEFORE THE ROUTER RUNS.
# The previous composed attempt was killed mid-route, and the three numbers
# that made its failure attributable -- placed CLB occupancy, the congestion
# LEVEL, and the failing-endpoint count -- had to be dug out of reports
# afterwards.  Printed here they exist even if the run dies later, and they are
# what lets a route failure be attributed to area rather than merely observed.
#
# CONGESTION LEVEL is read from the placed congestion report rather than from a
# property, because `report_design_analysis -congestion` is the only thing that
# produces the per-direction level table on this part.
proc c4_place_verdict {tag phase outdir} {
    set clb [llength [get_sites -quiet -filter {SITE_TYPE =~ SLICE* && IS_USED}]]
    puts "C4_PLACED $phase clb_sites_used $clb"
    # Failing endpoints, both directions, from the timing summary object.
    set ns [get_timing_paths -quiet -delay_type max -max_paths 1]
    if {[llength $ns]} {
        puts "C4_PLACED $phase wns [get_property SLACK $ns]"
    }
    set nfail 0
    foreach p [get_timing_paths -quiet -delay_type max -max_paths 200000 \
                   -slack_lesser_than 0 -nworst 1] {
        incr nfail
    }
    puts "C4_PLACED $phase failing_endpoints_max $nfail"
    report_design_analysis -congestion \
        -file [file join $outdir congestion_${tag}_${phase}.rpt]
}

# THE OBJECT-LEVEL CENSUS.  MEASURED twice in this project that Vivado's
# inference log lies in BOTH directions: `[Synth 8-7186]` printed 100 lines
# here saying `cb[*]` was not inferred as RAM, and LEVERC48 found 1,536
# `RAM32M16` rows in the same run's mapping report.  So the lever is verified
# against `get_cells`, never against the log and never against a utilization
# row alone.  The discriminator is exact and stated in advance:
#   lever C ACTIVE   -> cb_reg* FF = 0      and RAM32M16 cells present
#   lever C INACTIVE -> cb_reg* FF = 6,144  and RAM32M16 = 0
proc c4_census {} {
    set ram [get_cells -quiet -hier -filter {REF_NAME =~ RAM*}]
    array set byref {}
    foreach c $ram {
        set r [get_property REF_NAME $c]
        if {[info exists byref($r)]} { incr byref($r) } else { set byref($r) 1 }
    }
    foreach r [lsort [array names byref]] {
        puts "C4_CENSUS ref $r $byref($r)"
    }
    puts "C4_CENSUS ram_cells_total [llength $ram]"
    # NAME =~ *cb_reg* IS A LOOSE FILTER and MEASURED 2026-08-30 to over-match:
    # it returned 3 flip-flops in a run whose codebook is entirely LUTRAM,
    # against the 6,144 the register configuration carries.  The three belong
    # to some other signal whose name merely contains the substring, so the
    # names are printed rather than left as an unexplained residue -- an
    # unexplained residue is exactly what turns a clean verdict into an
    # AMBIGUOUS one.
    set cbffc [get_cells -quiet -hier -filter \
        {NAME =~ *cb_reg* && REF_NAME =~ FD*}]
    set cbff [llength $cbffc]
    puts "C4_CENSUS cb_reg_ff $cbff"
    if {$cbff > 0 && $cbff < 64} {
        foreach c $cbffc { puts "C4_CENSUS cb_reg_ff_name [get_property NAME $c]" }
    }
    set cbram [llength [get_cells -quiet -hier -filter \
        {NAME =~ *cb_reg* && REF_NAME =~ RAM*}]]
    puts "C4_CENSUS cb_reg_ram $cbram"
    # The norm lever, same treatment: the memory-backed unit must be present as
    # a hierarchy, and the flat one must be absent.
    puts "C4_CENSUS rmsmem_cells [llength [get_cells -quiet -hier \
        -filter {NAME =~ *u_rms*}]]"
    # THE DISCRIMINATOR IS THE RAM COUNT, NOT THE FF COUNT.  Both configurations
    # are pinned by LEVERC48 (`a4828ab`) at ROWS_IF = 48:
    #   "distributed" -> 26,112 RAM cells under cb_reg*, 0 registers
    #   "regs"        ->      0 RAM cells,             6,144 registers
    # An exact match against 26,112 is a far stronger statement than "the FF
    # count is zero", and it does not collapse to AMBIGUOUS on a handful of
    # cells the wildcard over-matched.  MEASURED here: 26,112 exact with 3 stray
    # flip-flops, so the first ACTIVE branch fires and the strays are named
    # above rather than absorbed.
    if {$cbram == 26112} {
        puts "C4_LEVERC ACTIVE  cb_reg_ram=$cbram exactly LEVERC48's figure,\
 cb_reg_ff=$cbff against 6144 for the register configuration"
    } elseif {$cbff >= 6144 && $cbram == 0} {
        puts "C4_LEVERC INACTIVE  cb_reg_ff=$cbff cb_reg_ram=0"
    } elseif {$cbff == 0 && $cbram > 0} {
        puts "C4_LEVERC ACTIVE_OFF_FIGURE  cb_reg_ff=0 cb_reg_ram=$cbram,\
 NOT 26112 -- the geometry is not ROWS_IF=48 or the lever changed"
    } else {
        puts "C4_LEVERC AMBIGUOUS  cb_reg_ff=$cbff cb_reg_ram=$cbram"
    }
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
    puts "C4_BEGIN synth tag=$tag part=$part core_period=$period hbm_period=$aperiod"
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

    # THE TWO CLOCKS.  core_clk 200 MHz, hbm_aclk 250 MHz; see the note at the
    # top of this file for where each number comes from in gen_pcieep.py.
    # They are declared ASYNCHRONOUS to each other because the crossing between
    # them is a gray-pointer FIFO per port (rtl/async_fifo.vhd), one for each of
    # the 28 masters -- so paths between the domains are not real paths, and
    # leaving them constrained would report failures the hardware does not have.
    # This is the same declaration sim/ooc_fk33_a.tcl:143 makes for subsystem A
    # alone and gen_pcieep.py:1264 makes in the shipping build.
    create_clock -period $period  -name core_clk [get_ports core_clk]
    create_clock -period $aperiod -name hbm_aclk [get_ports hbm_aclk]
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
    puts "C4_DIRECTIVES opt='$optdir' place='$placedir' physopt='$physdir' route='$routedir'"
    set ::c4_dirs "|$optdir|$placedir|$physdir|$routedir"
    eval opt_design [c4_dir_args $optdir]
    puts "C4_OPT_SECONDS [expr {[clock seconds] - $t0}]"
    emit_util $tag opt $outdir
    write_checkpoint -force [file join $outdir ${tag}_opt.dcp]

    set t0 [clock seconds]
    eval place_design [c4_dir_args $placedir]
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
    c4_place_verdict $tag placed $outdir

    set t0 [clock seconds]
    eval phys_opt_design -quiet [c4_dir_args $physdir]
    puts "C4_PHYSOPT_SECONDS [expr {[clock seconds] - $t0}]"
    write_checkpoint -force [file join $outdir ${tag}_physopt.dcp]
    c4_place_verdict $tag physopt $outdir

    # ROUTE_DESIGN IS WRAPPED, and the wrapper is the point of this stage.
    # `[Route 35-447] Congestion is preventing the router from routing all
    # nets` is an ERROR: in a bare batch script it aborts the run and every
    # report below -- the congestion map, the failing-endpoint attribution, the
    # unrouted-net census -- is never written.  MEASURED: that is exactly what
    # the previous composed attempt (`ac35293`) left behind, a killed run with
    # nothing but the log to reason from.  A negative answer is a RESULT here,
    # so the reports have to survive it.  `C4_ROUTE_RC` is the verdict; it is
    # NOT the sentinel, and the caller must not confuse the two.
    set t0 [clock seconds]
    set rrc [catch {eval route_design [c4_dir_args $routedir]} rmsg]
    puts "C4_ROUTE_SECONDS [expr {[clock seconds] - $t0}]"
    puts "C4_ROUTE_RC $rrc"
    if {$rrc} {
        puts "C4_ROUTE_ERROR $rmsg"
    }

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
    # HIERPORT IS NOT A ROUTING ERROR AND MUST NOT BE COUNTED AS ONE.
    # MEASURED 2026-08-30: this filter reported `errors=93489` on a run whose
    # own `report_route_status` says
    #   # of nets with routing errors.......... : 0
    # with 516,556 routable nets ALL fully routed.  Every one of the 93,489 was
    # HIERPORT -- the ordinary status of a net attached to a hierarchical port,
    # and this top has 1,184 of them by design.  A false alarm of that size on
    # the single question the composition exists to answer would have read as a
    # routing failure, so HIERPORT is now counted and printed SEPARATELY.
    # ANTENNAS and CONFLICTS are the real errors and they stay in `errors`.
    set n_err  [llength [get_nets -quiet -hier -filter \
        {ROUTE_STATUS == ANTENNAS || ROUTE_STATUS == CONFLICTS}]]
    set n_hp   [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == HIERPORT}]]
    puts "C4_ROUTE_HIERPORT $n_hp  (out-of-context port nets, NOT errors)"
    set n_unr  [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == UNROUTED}]]
    set n_part [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == PARTIAL}]]
    set n_all  [llength [get_nets -quiet -hier]]
    puts "C4_ROUTE_STATUS nets=$n_all errors=$n_err unrouted=$n_unr partial=$n_part"

    # WHERE, not merely WHETHER.  If the router does not finish, "it still does
    # not route" is barely a result; the reusable part is which hierarchy the
    # unrouted nets belong to and whether the failure is still net-dominated.
    # `a_eng` is subsystem A, proven on silicon and unchanged, so its share of
    # the unrouted nets is this run's attribution control: a large share means
    # the failure is the composition's density, not any one subsystem.
    array set unr {}
    foreach n [get_nets -quiet -hier -filter \
            {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL || \
             ROUTE_STATUS == ANTENNAS || ROUTE_STATUS == CONFLICTS}] {
        set nm [get_property NAME $n]
        set top [lindex [split $nm "/"] 0]
        if {[info exists unr($top)]} { incr unr($top) } else { set unr($top) 1 }
    }
    foreach k [lsort [array names unr]] {
        puts "C4_UNROUTED_BY_INST $k $unr($k)"
    }

    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    # FINGERPRINT ON THE VERDICT LINE.  Everything after whs is redundant with
    # C4_UTIL and C4_DIRECTIVES; it is repeated here so that comparing two runs
    # is ONE grep and an incomparable pair is visible without a second lookup.
    # Guarded so a stage that never called emit_util still prints the verdict.
    set fp ""
    if {[info exists ::c4_last_util]} {
        catch { append fp " bram=[dict get $::c4_last_util bram] dsp=[dict get $::c4_last_util dsp] lut=[dict get $::c4_last_util lut]" }
    }
    if {[info exists ::c4_dirs]} { append fp " dirs='$::c4_dirs'" }
    puts "C4_TIMING wns=$wns whs=$whs$fp"
    foreach c [get_clocks] {
        set p [get_timing_paths -to [get_clocks $c] -delay_type max -max_paths 1]
        if {[llength $p]} {
            puts "C4_CLKWNS [get_property NAME $c] period=[get_property PERIOD $c]\
 wns=[get_property SLACK $p]"
        }
    }
    puts "C4_DONE impl $tag"

} elseif {$stage eq "census"} {
    # A CHEAP SECOND INVOCATION, deliberately separate.  Opening a checkpoint
    # and running get_cells costs minutes, and the alternative -- folding the
    # census into the synthesis stage -- means a census bug throws away an hour
    # of synthesis.  It also lets a checkpoint written before this proc existed
    # still be censused.
    if {$dcp eq "" || ![file exists $dcp]} {
        error "C4 FAIL: C4_DCP is '$dcp', which does not exist."
    }
    puts "C4_BEGIN census tag=$tag dcp=$dcp"
    open_checkpoint $dcp
    emit_util $tag census $outdir
    c4_census
    puts "C4_DONE census $tag"

} else {
    error "C4 FAIL: unknown C4_STAGE '$stage'"
}
