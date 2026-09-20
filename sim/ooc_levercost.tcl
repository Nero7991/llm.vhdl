# sim/ooc_levercost.tcl -- TRACK LEVERCOST, 2026-09-20.
#
# ONE OOC DRAW OF AN ARBITRARY UNIT, with an object-level primitive census and
# a PER-CLOCK post-synthesis timing estimate.  Modelled on sim/ooc_bmover.tcl
# (TRACK BMOVERSYN) and hw/fk33/ooc_card_dcp.tcl, and it inherits three
# recorded traps from them rather than rediscovering them.
#
# THE QUESTION THIS HARNESS SERVES.  Four throughput levers are implemented and
# waiting for a card build, and the device is the constraint: the shipped card
# placed at CLB 54,854 of 54,960 (99.81%) and routed at WNS +0.061 ns.  What
# does enabling each cost?
#
# WHY IT IS A UNIT HARNESS AND NOT A CARD-TOP HARNESS.  THE OBVIOUS EXPERIMENT
# IS NOT AVAILABLE.  `synth_design -top fk33_card` (or `fk33_llama_top`) at the
# 9B geometry HAS NEVER CLEARED RTL ELABORATION: hw/fk33/ooc_c_in_card.tcl
# records `grep -c 'Finished RTL Elaboration'` = ZERO across TWELVE attempts on
# TWO machines, and hw/fk33/ooc_card_dcp.tcl records the best of them running
# 47 h under MemoryHigh=24G while wanting at least 39.1 GiB
# (memory.current 24,352 MiB + memory.swap.current 15,664 MiB) and still not
# finishing.  A five-arm A/B against that top is not a long job, it is a job
# with no recorded instance of termination.  So each lever is drawn in the
# SMALLEST ENTITY THAT CLOSES ITS LOGIC CONE, which is the shape every other
# area result in this project already has.
#
# WHAT THIS NUMBER IS AND IS NOT.  synth_design + opt_design, out of context,
# no placement, no routing.  CLAUDE.md records phys_opt over-promising by
# 0.4-0.6 ns on this part and INVERTING the verdict between two runs, so every
# WNS here is labelled ESTIMATE and orders arms against EACH OTHER only.  It is
# not a routed card number and no line here may be read as one.
#
# THREE INHERITED TRAPS, each of which has already cost this project time:
#
#  1. `REF_NAME =~ DSP*` OVER-COUNTS BY EXACTLY 9x.  Vivado transforms each
#     DSP48E2 into itself plus eight internal primitives (DSP_ALU,
#     DSP_A_B_DATA, DSP_C_DATA, DSP_MULTIPLIER, DSP_M_DATA, DSP_OUTPUT,
#     DSP_PREADD, DSP_PREADD_DATA), all of which match `DSP*`.  The first full
#     fk33_card synthesis reported dsp=4842 against 2,880 on the part -- a
#     false "does not fit" -- when the real figure was 538.  `REF_NAME ==
#     DSP48E2` is exact and is what this file uses.  `PRIMITIVE_GROUP == DSP`
#     is the opposite trap: it matches NOTHING and returns a silent zero with
#     only a WARNING.
#
#  2. A PER-CLOCK WNS IS NOT THE REPORTED WNS.  `get_timing_paths -max_paths 1`
#     returns the worst path ON THE PART.  TRACK AIDLE measured all three of
#     its draws at `wns=1.103` and the lever looked free, because that path is
#     in the 4.000 ns AXI domain and the change lives in the 13.333 ns core
#     domain -- where it DID move, 11.709 to 11.285.  This file reports the
#     global worst AND a worst path per clock, with startpoint, endpoint and
#     logic levels, so a claim can be attributed to a clock and argued with.
#
#  3. THE LOG LIES IN BOTH DIRECTIONS.  `[Synth 8-10226]` (URAM refused) and
#     `[Synth 8-7186]` (ram_style ignored) are both recorded here as having
#     been wrong, one each way.  The census is taken from get_cells and is
#     AUTHORITATIVE over report_utilization; the runner counts both message
#     ids so the two can be reconciled by hand.  A message count of exactly
#     100 is Vivado's message limit, not a census.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
#
# USAGE:  LC_TAG=<tag> LC_TARGET=<entity> LC_OUT=<dir> LC_RTL=<dir>
#         LC_GEN="A=1 B=true" LC_CLK="clk=13.333 m_aclk=4.000"
#         vivado -mode batch -nojournal -log <log> -source sim/ooc_levercost.tcl
#
# Prints LEVERCOST_DONE <tag> as its LAST action.  The caller gates on that
# LINE-ANCHORED sentinel, because a Vivado run can print full success and then
# die on a Tcl error afterwards, and because this log contains this script's
# own source text (the recorded unanchored-grep trap).

set part xcvu33p-fsvh2104-2L-e

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag     [envor LC_TAG    unnamed]
set target  [envor LC_TARGET ""]
set outdir  [envor LC_OUT    levercost_out]
set rtldir  [envor LC_RTL    rtl]
set gens    [envor LC_GEN    ""]
set clks    [envor LC_CLK    "clk=13.333"]
set flat    [envor LC_FLAT   none]

if {$target eq ""} { error "LEVERCOST_ABORT: LC_TARGET is unset" }
file mkdir $outdir

puts "LEVERCOST_BEGIN tag=$tag target=$target part=$part rtl=$rtldir flat=$flat"
puts "LEVERCOST_GENERICS tag=$tag gen=\"$gens\""
puts "LEVERCOST_CLOCKS tag=$tag clk=\"$clks\""
create_project -in_memory -part $part

# RAISE THE LIMIT ON THE TWO MESSAGES THIS PROJECT COUNTS, OR THE COUNT IS THE
# LIMIT.  MEASURED 2026-09-20: both brecur arms reported `[Synth 8-7186]` = 101,
# which is 100 warnings plus `[Common 17-14] ... appears 100 times and further
# instances of the messages will be disabled`.  A count pinned at the cap tells
# you nothing except that the cap was reached, which is the same shape as a
# capped `memory.peak` being read as a footprint.  At 100000 the count is a
# census again.
foreach mid {{Synth 8-7186} {Synth 8-10226}} {
    if {[catch {set_msg_config -id $mid -limit 100000} e]} {
        puts "LEVERCOST_MSGLIMIT_FAIL $mid : $e"
    }
}

# Read the whole RTL directory.  Files unreachable from -top are parsed and
# then ignored, so a superset costs parse time and nothing else
# (hw/fk33/ooc_card_dcp.tcl says this outright).  A per-file catch means one
# unparseable file -- another track may have one open -- degrades to a named
# skip rather than killing the draw.
#
# EXCEPT `rtl/ooc_*_top.vhd`, WHICH MUST BE EXCLUDED, AND THE REASON IS A
# MEASURED FAILURE OF THIS SCRIPT'S FIRST RUN.  Those four files are OTHER
# tracks' OOC harness TOPS -- alternative roots, never part of any unit's
# closure -- and `rtl/ooc_gdnadapt_top.vhd` DOES NOT COMPILE AT HEAD: it uses
# `B_CONST_HBM` at lines 377, 604, 782, 843, 869 and 903 and never declares it
# as a generic, so it is stale with respect to the 2026-09-18 B-constants
# work.  MEASURED 2026-09-20: `synth_design -top matvec_int4_desc_axi` died
# with `[Synth 8-36] 'b_const_hbm' is not declared` and six siblings, 7 errors,
# in 35 s -- from a file the target cannot reach.
#
# `read_vhdl` ACCEPTS IT WITHOUT COMPLAINT; the failure surfaces at
# synth_design, so the per-file catch above does NOT protect against this and
# a run that looks healthy through the read phase still dies.  Nothing
# schedules that harness, which is why the breakage has been invisible.
set nread 0
set nskip 0
set nexcl 0
foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[string match "ooc_*_top.vhd" [file tail $f]]} {
        puts "LEVERCOST_READ_EXCLUDE [file tail $f] (harness top, not a closure member)"
        incr nexcl; continue
    }
    if {[catch {read_vhdl -vhdl2008 $f} e]} {
        puts "LEVERCOST_READ_SKIP $f : $e"; incr nskip
    } else { incr nread }
}
puts "LEVERCOST_READ_EXCLUDED tag=$tag n=$nexcl"
puts "LEVERCOST_READ tag=$tag files=$nread skipped=$nskip"

set gl {}
foreach g $gens { lappend gl -generic $g }

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part \
    -flatten_hierarchy $flat $gl
set tsynth [expr {[clock seconds] - $t0}]
puts "LEVERCOST_SYNTH_SECONDS tag=$tag $tsynth"

# ---------------------------------------------------------------------------
# THE CENSUS.  Object-level, by REF_NAME, and AUTHORITATIVE over
# report_utilization wherever the two disagree.  Exact names for the primitives
# that have a recorded counting trap; wildcards only where the family is the
# thing meant.
# ---------------------------------------------------------------------------
proc census {stage tag outdir} {
    set fh [open [file join $outdir census_${stage}_$tag.txt] w]
    puts $fh "# LEVERCOST census stage=$stage tag=$tag (get_cells -hier by REF_NAME)"
    set out {}
    foreach {label pat} {
        dsp48    {REF_NAME == DSP48E2}
        uram288  {REF_NAME == URAM288}
        ramb36   {REF_NAME == RAMB36E2}
        ramb18   {REF_NAME == RAMB18E2}
        # THE INHERITED LUTRAM FILTER UNDER-COUNTS BY 4x ON THIS PART AND THE
        # ERROR IS SILENT.  `RAM32*`/`RAM64*`/... match `RAM32M` and
        # `RAM32M16` but NOT `RAMD32`, `RAMS32`, `RAMD64E` or `RAMS64E`, which
        # are the UltraScale+ single/dual-port distributed-RAM primitives and
        # are usually the MAJORITY.  MEASURED 2026-09-20 on `gdn_block`'s
        # `qbuf`: the old pattern found 307 of that array's cells and missed
        # **4,904** (RAMD32 4,290 + RAMS32 614).  `RAMD*`/`RAMS*` are added
        # here; the unit total went 1,291 -> ~6,195.  A census that silently
        # sees a quarter of the objects is worse than no census, because it
        # reads as a measurement.
        lutram   {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256* || REF_NAME =~ RAM512* || REF_NAME =~ RAMD* || REF_NAME =~ RAMS*}
        lut      {REF_NAME =~ LUT*}
        lut1     {REF_NAME == LUT1}
        lut2     {REF_NAME == LUT2}
        lut3     {REF_NAME == LUT3}
        lut4     {REF_NAME == LUT4}
        lut5     {REF_NAME == LUT5}
        lut6     {REF_NAME == LUT6}
        ff       {REF_NAME =~ FD*}
        carry8   {REF_NAME == CARRY8}
        f7       {REF_NAME == MUXF7}
        f8       {REF_NAME == MUXF8}
        f9       {REF_NAME == MUXF9}
        srl      {REF_NAME =~ SRL*}
    } {
        set cells [get_cells -hier -quiet -filter $pat]
        set n [llength $cells]
        lappend out "$label=$n"
        puts $fh "## $label $n"
        # Memory and DSP primitives are few enough to name, which is what
        # attributes one to an instance rather than to a total.
        if {$label in {dsp48 uram288 ramb36 ramb18}} {
            foreach c [lsort $cells] { puts $fh "$c" }
        } elseif {$label eq "lutram"} {
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
    puts "LEVERCOST_CENSUS stage=$stage tag=$tag [join $out { }]"
    return $out
}

# THE NAMED-OBJECT CENSUS.  `LC_NAMED=qbuf` tallies every cell whose NAME
# matches, BY REF_NAME, which is the only thing that settles a `[Synth 8-7186]`
# argument.
#
# MEASURED 2026-09-20, both brecur arms: `[Synth 8-7186]` came back at
# **101**, and the 101st line is
# `INFO: [Common 17-14] Message 'Synth 8-7186' appears 100 times and further
# instances of the messages will be disabled.`  **So the count is the MESSAGE
# LIMIT plus its own notice, not a census** -- the true number of objects
# Vivado complained about is at least 100 and is not knowable from the log.
# The warning names `qbuf[0][0]`..`qbuf[6][3]` at `rtl/gdn_block.vhd:396` and
# says `ram_style = "distributed"` was IGNORED.  The parent-level census shows
# 806 LUTRAM cells at exactly that level -- but grouping by parent cannot say
# whether those 806 ARE the qbuf cells or some other array beside them, and
# CLAUDE.md's recorded case is that this message has been WRONG (every object
# it named was a RAM32M16 in the same run's mapping report).
#
# The cheap discriminator this implements is the one that file states: a
# `RAM=0 FF=n` answer means registers, `RAM=n FF=0` means distributed RAM.
proc named_census {stage tag outdir pat} {
    if {$pat eq ""} return
    set cells [get_cells -hier -quiet -filter "NAME =~ *${pat}*"]
    array unset byref
    foreach c $cells {
        set r [get_property REF_NAME $c]
        if {![info exists byref($r)]} { set byref($r) 0 }
        incr byref($r)
    }
    set out {}
    foreach r [lsort [array names byref]] { lappend out "$r=$byref($r)" }
    puts "LEVERCOST_NAMED stage=$stage tag=$tag pat=$pat total=[llength $cells] [join $out { }]"
    set fh [open [file join $outdir named_${stage}_$tag.txt] w]
    puts $fh "# cells matching *${pat}* by REF_NAME, stage=$stage tag=$tag"
    foreach r [lsort [array names byref]] { puts $fh "$r $byref($r)" }
    close $fh
}

report_utilization -file [file join $outdir synthutil_$tag.rpt]
set surpt [report_utilization -return_string]
set scens [census synth $tag $outdir]
named_census synth $tag $outdir [envor LC_NAMED ""]

set t1 [clock seconds]
opt_design
set topt [expr {[clock seconds] - $t1}]
puts "LEVERCOST_OPT_SECONDS tag=$tag $topt"

report_utilization -file [file join $outdir util_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir util_hier_$tag.rpt]
if {[catch {report_ram_utilization -file [file join $outdir ram_$tag.rpt]} e]} {
    puts "LEVERCOST_NORAMRPT $tag : $e"
}
set urpt [report_utilization -return_string]
set ocens [census opt $tag $outdir]
named_census opt $tag $outdir [envor LC_NAMED ""]

# A CHECKPOINT, SO A TIMING QUESTION NEVER COSTS A SYNTHESIS AGAIN.  MEASURED
# 2026-09-20: `matvec_int4_desc_axi` at the card's 27-lane geometry takes 419 s
# of synth_design plus 164 s of opt_design and wants ~9-12 GiB, and this track
# had to throw away two such draws and repeat them because the first pass
# created two clocks without grouping them (see the CLKASYNC note below).  A
# constraint mistake is a `read_checkpoint` and two minutes if the netlist was
# saved, and forty minutes of Vivado if it was not.  Area is already recorded
# above; this exists for the timing side.
if {[envor LC_DCP 1]} {
    write_checkpoint -force [file join $outdir post_opt_$tag.dcp]
    puts "LEVERCOST_DCP tag=$tag [file join $outdir post_opt_$tag.dcp]"
}

# Numbers from report_utilization, kept BESIDE the census rather than instead
# of it.  Where they disagree the census wins; the runner prints both.
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
# TIMING.  Every clock this unit has, each reported SEPARATELY, because the
# global worst path can sit in a domain the lever cannot touch and hide the
# whole effect (TRACK AIDLE, trap 2 in the header).
# ---------------------------------------------------------------------------
proc pathline {p} {
    if {$p eq ""} { return "wns=NA" }
    return "wns=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p]\
 datapath=[get_property DATAPATH_DELAY $p] start=[get_property STARTPOINT_PIN $p]\
 end=[get_property ENDPOINT_PIN $p]"
}

set made {}
foreach kv $clks {
    set parts [split $kv "="]
    set port  [lindex $parts 0]
    set per   [lindex $parts 1]
    set pobj  [get_ports -quiet $port]
    if {[llength $pobj] == 0} {
        puts "LEVERCOST_CLKMISS tag=$tag port=$port (not a port on this unit)"
        continue
    }
    create_clock -period $per -name $port $pobj
    lappend made $port $per
    puts "LEVERCOST_CLKMADE tag=$tag port=$port period=$per"
}

# TWO CLOCKS MUST BE DECLARED ASYNCHRONOUS OR EVERY REPORTED PATH IS A CDC
# CROSSING, AND THIS IS NOT A REFINEMENT -- IT IS THE DIFFERENCE BETWEEN A
# NUMBER AND NOISE.
#
# MEASURED 2026-09-20, apop_ctrl's first draw, with the two clocks created and
# NOT grouped: the worst `s_axi_aclk` path came back at wns=0.939 with a
# DATA PATH DELAY OF 0.376 ns and ONE logic level, from
# `dfetch/g_dc.fsm/st_reg[1]/C` to `dfetch/g_dc.run_s1_reg/D` -- the first
# stage of a two-flop synchroniser.  A 0.376 ns path cannot have 0.939 ns of
# slack on a 13.333 ns period; the requirement was not 13.333 at all.  Vivado
# times two unrelated clocks against their COMMON PERIOD, so an ungrouped
# `create_clock` pair turns every reported worst path into a crossing whose
# requirement is an artefact of the two numbers chosen.
#
# `matvec_int4_desc_axi` at DUAL_CLK=true is deliberately a two-domain design
# and the card drives the two from different sources, so asynchronous is the
# TRUE relationship and the shipping XDC says so.  Without this line the
# intra-domain core-clock path -- the ONLY path a core-domain lever can move --
# is never the worst path and never gets reported, which is TRACK AIDLE's
# recorded "ask which clock the claim lives on" trap one level deeper: there
# the right domain was merely not quoted, here it is not even computed.
if {[llength $made] > 2} {
    set groups {}
    foreach {port per} $made { lappend groups -group [get_clocks $port] }
    eval set_clock_groups -asynchronous $groups
    puts "LEVERCOST_CLKASYNC tag=$tag groups=[expr {[llength $made]/2}]"
} else {
    puts "LEVERCOST_CLKASYNC tag=$tag groups=1 (single clock, nothing to group)"
}

report_timing_summary -delay_type max -max_paths 5 \
    -file [file join $outdir timing_summary_$tag.rpt]

# THE INTRA CLOCK TABLE IS THE ANSWER, AND IT WAS IN THE REPORT ALL ALONG.
# MEASURED 2026-09-20: while `get_timing_paths -to [get_clocks s_axi_aclk]`
# returned 0.939 ns (an INTER-clock crossing, see the CLKASYNC note),
# `report_timing_summary`'s own Intra Clock Table already carried
# `s_axi_aclk 9.088` and `m_aclk 1.103` for the same netlist.  The 1.103
# reproduces TRACK AIDLE's `weight_streamer` figure to the digit at a much
# larger scope, which is what makes it a cross-check rather than a coincidence.
# Parsed out here so no arm depends on a human opening the report.
# Parsed from the file just written, NOT from a second
# `report_timing_summary -return_string`: on this unit that command is minutes
# of work and re-running it to read a table it has already produced is pure
# duplicate cost.
set fh [open [file join $outdir timing_summary_$tag.rpt] r]
set tsum [read $fh]
close $fh
set inintra 0
foreach line [split $tsum "\n"] {
    if {[string match "*Intra Clock Table*" $line]} { set inintra 1; continue }
    if {[string match "*Inter Clock Table*" $line]} { set inintra 0; continue }
    if {!$inintra} continue
    set f [regexp -all -inline {\S+} $line]
    if {[llength $f] < 3} continue
    set nm [lindex $f 0]
    # THE TABLE'S OWN SEPARATOR IS A VALID-LOOKING FIRST TOKEN AND IT KILLED
    # A 735 s DRAW.  MEASURED 2026-09-20: the row `-----   -------  ...` made
    # `$nm` the string `-----`, and `get_clocks -quiet -----` does not treat a
    # leading dash as a name -- it reports
    # `ERROR: [Common 17-170] Unknown option '-----'` and takes the whole run
    # down AFTER synthesis, opt_design, the census and the checkpoint had all
    # succeeded.  `-quiet` suppresses "no matching object", not a bad option.
    # Skip anything that could be read as a switch, and the header row.
    if {[string index $nm 0] eq "-"} continue
    if {$nm eq "Clock"} continue
    # NOT `get_clocks -- $nm`: get_clocks does not accept `--` either, and
    # that "fix" failed identically (`Unknown option '--'`) after another
    # 735 s draw.  The token must be rejected by the guards above, never
    # handed to the command defensively.
    if {[llength [get_clocks -quiet $nm]] == 0} continue
    puts "LEVERCOST_INTRA tag=$tag clk=$nm wns=[lindex $f 1] tns=[lindex $f 2]\
 failing=[lindex $f 3] endpoints=[lindex $f 4]"
}

# The global worst path on the part, which is the number a careless reader
# quotes, printed so it can be SEEN to be in the wrong domain.
set gp [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
puts "LEVERCOST_WORST_GLOBAL tag=$tag [pathline $gp]"

set timcsv {}
foreach {port per} $made {
    set cp [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
                        -to [get_clocks -quiet $port]] 0]
    puts "LEVERCOST_WORST_CLK tag=$tag clk=$port period=$per [pathline $cp]"
    set w [expr {$cp eq "" ? "NA" : [get_property SLACK $cp]}]
    set l [expr {$cp eq "" ? "NA" : [get_property LOGIC_LEVELS $cp]}]
    lappend timcsv "$port:$w:$l"
    report_timing -delay_type max -max_paths 3 -nworst 1 \
        -to [get_clocks -quiet $port] \
        -file [file join $outdir worst_${port}_$tag.rpt]

    # THE PATH DISTRIBUTION, NOT JUST THE WORST PATH.  A lever can add a path
    # that is slower than everything around it and still not become THE worst
    # path, in which case the WNS does not move and the arm looks free when it
    # is merely second.  MEASURED here: apop_ctrl's worst core-domain path is
    # `dw_reg[10][56]` -> `err_code_reg[0]/CE` at 16 logic levels, which has
    # nothing to do with the FIFO cone FAST_POP touches -- so a WNS comparison
    # alone could only ever have produced a bound.  Dumping the top 50 per arm
    # makes the two DISTRIBUTIONS diffable, which is what turns "the worst path
    # did not move" into "no path in the streamer cone moved either".
    set fh [open [file join $outdir paths50_${port}_$tag.txt] w]
    puts $fh "# top-50 intra-domain paths, clk=$port tag=$tag (slack start end levels)"
    foreach p [get_timing_paths -delay_type max -max_paths 50 -nworst 1 \
                   -to [get_clocks -quiet $port]] {
        puts $fh "[get_property SLACK $p] [get_property STARTPOINT_PIN $p]\
 [get_property ENDPOINT_PIN $p] [get_property LOGIC_LEVELS $p]"
    }
    close $fh
}

puts "LEVERCOST_RESULT tag=$tag lut=$U(lut) lut_logic=$U(lut_logic)\
 lut_mem=$U(lut_mem) ff=$U(ff) bram=$U(bram) ramb36=$U(ramb36)\
 ramb18=$U(ramb18) uram=$U(uram) dsp=$U(dsp) carry8=$U(carry8)\
 f7=$U(f7) f8=$U(f8) synth_s=$tsynth opt_s=$topt timing=\"[join $timcsv { }]\""
puts "LEVERCOST_SYNTH_VS_OPT tag=$tag synth_lut=$S(lut) opt_lut=$U(lut)\
 synth_ff=$S(ff) opt_ff=$U(ff) synth_bram=$S(bram) opt_bram=$U(bram)\
 synth_dsp=$S(dsp) opt_dsp=$U(dsp) synth_uram=$S(uram) opt_uram=$U(uram)"

set csv [open [file join $outdir result_$tag.csv] w]
puts $csv "tag,target,gen,lut,lut_logic,lut_mem,ff,bram_tile,ramb36,ramb18,uram,dsp,carry8,f7,f8,timing_per_clk,synth_s,opt_s,census_opt"
puts $csv "$tag,$target,\"$gens\",$U(lut),$U(lut_logic),$U(lut_mem),$U(ff),$U(bram),$U(ramb36),$U(ramb18),$U(uram),$U(dsp),$U(carry8),$U(f7),$U(f8),\"[join $timcsv { }]\",$tsynth,$topt,\"[join $ocens { }]\""
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "LEVERCOST_DONE $tag"
