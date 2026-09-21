# sim/ooc_cbooc.tcl -- TRACK CBOOC, 2026-09-20.
#
# ONE OOC DRAW OF SUBSYSTEM A AT THE CARD'S GEOMETRY, instrumented for the ONE
# question the per-row codebook change (`0b34200`, lever L-CB) has never been
# asked: WHAT DOES A SYNTHESISER DO WITH IT?
#
# THE GAP THIS CLOSES.  `docs/LEVERBOARD.md`'s L-CB row states its scope as
# "no synthesis at all" and its `-19,344 FF` as DERIVED.  Build 11b is the
# first time that RTL has ever met `synth_design`, and it placed at
# WNS -5.136 / TNS -236,998 against build 9's +0.533 / 0.000.  That is a LEAD
# and this harness exists to make it TESTABLE, not to confirm it.  TRACK
# HDRCOST found the same shape hours earlier: a 20-point bit-exact grid, two C
# oracles, a 23-row mutation suite and five green gate groups, all passing, on
# RTL that `synth_design` killed in 49 seconds.
#
# WHAT THIS HARNESS CAN AND CANNOT SETTLE, stated before any number is read:
#
#   CAN   the FF delta (`-19,344` DERIVED), the LUT/LUTRAM/DSP/BRAM deltas,
#         and the FANOUT on the codebook command net -- all of which are
#         properties of the NETLIST and are fully determined at synthesis.
#   CAN   whether the change introduces a new structure a synthesiser dislikes
#         (HDRCOST's failure mode: RTL that does not build at the card shape).
#   CANNOT  exonerate or convict the change on build 11b's WNS.  That number is
#         a PLACEMENT outcome at 99.8% CLB occupancy, and CLAUDE.md records
#         `phys_opt` over-promising by 0.4-0.6 ns and INVERTING the verdict
#         between two runs on this part.  An OOC route would not transfer
#         either: OOC congestion is not the card's congestion.  The card
#         question needs a re-implementation from build 11b's own checkpoint
#         with the change reverted, which is a different and much larger job.
#
# WHY SYNTHESIS AND NOT PLACE-AND-ROUTE, justified rather than assumed.  The
# mechanism CBFANOUT claims is a FANOUT COUNT (1,536 sinks -> 48) and the
# prediction it registered is a FLIP-FLOP COUNT.  Both are synthesis-stage
# netlist facts.  Routing would add a number that cannot be quoted anywhere.
# `CBO_DCP` therefore writes a post-`opt_design` checkpoint per arm, so that if
# a later track does want a routed comparison it costs a `read_checkpoint` and
# not a second synthesis -- the lesson LEVERCOST paid for twice.
#
# THE GEOMETRY IS LOAD-BEARING AND `CB_STYLE=distributed` IS THE LOAD-BEARING
# PART OF IT.  DERIVED from rtl/matvec_core.vhd:
#
#   CB_STYLE=regs         CB_LANES_PER_COPY = CB_ROWS_PER_COPY*BLK = 32
#                         CB_COPIES = 48*32/32 = 48
#                         CB_RANKS  = min(48,48) = 48
#                         cb_rank_of(c) = (c*48)/48 = c        <- THE IDENTITY
#
#   So AT `CB_STYLE=regs` THE TWO ARMS ARE THE SAME NETLIST and a draw there
#   measures nothing at all while printing two full result rows.  The card
#   build is `FK33_CB_STYLE=distributed` (docs/WORKLOG.md:17, and :147 quotes
#   the 1,536 -> 48 fanout), giving CB_LANES_PER_COPY = 1, CB_COPIES = 1,536,
#   CB_RANKS = 48.  This is `docs/debugging/2026-09-20_the-shape-a-bench-runs-at.md`
#   exactly: a harness at the wrong shape measures nothing.  The runner passes
#   `CB_STYLE` explicitly and this file REFUSES to draw at `regs` unless
#   `CBO_ALLOW_REGS=1`, because a silently-identical pair is the worst possible
#   output.
#
# WHY `matvec_int4_desc_axi` AND NOT `matvec_core`, ESTABLISHED FROM THE RTL.
# The codebook's REGISTER cone closes inside `matvec_core`: `cb`, `cbw_v`,
# `cbw_a`, `cbw_d` are all declared in its architecture.  But build 10's
# failing path was `cb_addr_reg[i]/C -> cbw_a_reg[c][i]/D`, and the STARTPOINT
# is NOT in `matvec_core` -- `cb_addr` is an INPUT PORT there
# (rtl/matvec_core.vhd:81), declared as a signal and driven by the S_CB state
# at `rtl/matvec_int4_desc_axi.vhd:474` and `:1002`.  `matvec_int4` passes it
# through as a port too (`rtl/matvec_int4.vhd:95`).  So:
#
#   matvec_core           closes the FANOUT cone, NOT the failing PATH
#   matvec_int4           same: cb_addr is still a port
#   matvec_int4_desc_axi  the SMALLEST entity holding BOTH endpoints
#
# `matvec_core` is still worth drawing because it is cheaper and isolates the
# delta from the descriptor plane; `CBO_TARGET` takes either.  Quote the
# desc_axi pair for anything about the PATH, and never add the two contexts
# together -- CLAUDE.md: the parts do not sum across synthesis contexts.
#
# INHERITED TRAPS, taken from sim/ooc_levercost.tcl rather than rediscovered:
#   1. `REF_NAME =~ DSP*` OVER-COUNTS BY EXACTLY 9x.  `REF_NAME == DSP48E2` is
#      exact.  `PRIMITIVE_GROUP == DSP` matches NOTHING and returns a silent
#      zero with only a WARNING.
#   2. The LUTRAM filter must carry `RAMD*`/`RAMS*` or it under-counts by 4x on
#      this part, silently.
#   3. A PER-CLOCK WNS IS NOT THE REPORTED WNS; the global worst path can live
#      in a domain the change cannot touch.  The Intra Clock Table is parsed
#      out, with the guard against its own `-----` separator row, which has
#      twice taken a 735 s draw down AFTER everything succeeded.
#   4. The log LIES in both directions (`Synth 8-10226`, `Synth 8-7186`); the
#      `get_cells` census is authoritative and the message limit is raised so a
#      count is a census and not the cap.
#   5. The sentinel is LINE-ANCHORED, because this log contains this script's
#      own source text.
#
# NO HARDWARE.  `synth_design` / `opt_design` / `report_*` only.  Never opens a
# target, never programs a device, never touches /dev/xdma*.
#
# USAGE:  CBO_TAG=<tag> CBO_TARGET=<entity> CBO_OUT=<dir> CBO_RTL=<dir>
#         CBO_GEN="BLK=32 ROWS_IF=48 ..." CBO_CLK="s_axi_aclk=13.333 m_aclk=4.000"
#         vivado -mode batch -nojournal -log <log> -source sim/ooc_cbooc.tcl
#
# Prints `CBOOC_DONE <tag>` as its LAST action.  Gate on that line-anchored
# sentinel, NEVER on an exit code: a Vivado run can print full success and then
# die on a Tcl error afterwards, and a waiter's status is a fact about the
# waiter.

set part xcvu33p-fsvh2104-2L-e

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag     [envor CBO_TAG    ""]
set target  [envor CBO_TARGET ""]
set outdir  [envor CBO_OUT    ""]
set rtldir  [envor CBO_RTL    ""]
set gens    [envor CBO_GEN    ""]
set clks    [envor CBO_CLK    "clk=13.333"]
set flat    [envor CBO_FLAT   none]

# ---------------------------------------------------------------------------
# FAIL LOUDLY, AND BEFORE ANYTHING EXPENSIVE.  A harness whose missing arm
# degrades to a half-draw is worse than one that stops: it produces a table.
# ---------------------------------------------------------------------------
if {$tag    eq ""} { error "CBOOC_ABORT: CBO_TAG is unset" }
if {$target eq ""} { error "CBOOC_ABORT: CBO_TARGET is unset" }
if {$rtldir eq ""} { error "CBOOC_ABORT: CBO_RTL is unset" }
if {$outdir eq ""} { error "CBOOC_ABORT: CBO_OUT is unset" }
if {![file isdirectory $rtldir]} {
    error "CBOOC_ABORT: CBO_RTL=$rtldir is not a directory"
}
# The arm's whole identity is this one file.  A tree without it is not an arm.
if {![file exists [file join $rtldir matvec_core.vhd]]} {
    error "CBOOC_ABORT: $rtldir holds no matvec_core.vhd -- this is not a\
           subsystem-A arm tree and every number from it would be meaningless"
}
if {[lsearch -exact $gens "CB_STYLE=distributed"] < 0
    && [envor CBO_ALLOW_REGS 0] ne "1"} {
    error "CBOOC_ABORT: CBO_GEN does not contain CB_STYLE=distributed.\
           At CB_STYLE=regs, CB_COPIES = ROWS_IF*BLK/(CB_ROWS_PER_COPY*BLK) =\
           ROWS_IF = 48 = CB_RANKS, so cb_rank_of(c) = c is the IDENTITY and\
           the two arms are the SAME NETLIST.  The draw would succeed, print a\
           full result row, and measure nothing.  The card ships\
           FK33_CB_STYLE=distributed (docs/WORKLOG.md:17).\
           Set CBO_ALLOW_REGS=1 only to run that null control DELIBERATELY,\
           in which case a ZERO delta is the expected and correct answer."
}
file mkdir $outdir

puts "CBOOC_BEGIN tag=$tag target=$target part=$part rtl=$rtldir flat=$flat"
puts "CBOOC_GENERICS tag=$tag gen=\"$gens\""
puts "CBOOC_CLOCKS tag=$tag clk=\"$clks\""
# The arm's provenance, printed by the TOOL rather than asserted by the runner,
# so the log can be read on its own six months from now.
if {![catch {exec md5sum [file join $rtldir matvec_core.vhd]} mc]} {
    puts "CBOOC_ARM_MD5 tag=$tag $mc"
}

create_project -in_memory -part $part
set_param general.maxThreads 4

# A COUNT PINNED AT THE MESSAGE LIMIT IS THE LIMIT, NOT A CENSUS -- the same
# shape as a capped `memory.peak` read as a footprint.  Raise both.
foreach mid {{Synth 8-7186} {Synth 8-10226}} {
    if {[catch {set_msg_config -id $mid -limit 100000} e]} {
        puts "CBOOC_MSGLIMIT_FAIL $mid : $e"
    }
}

# ---------------------------------------------------------------------------
# READ.  The whole arm's rtl/ directory: files unreachable from -top are parsed
# and then ignored, so a superset costs parse time and nothing else.
#
# EXCEPT `ooc_*_top.vhd`, which MUST be excluded.  Those are OTHER tracks' OOC
# harness TOPS, and `rtl/ooc_gdnadapt_top.vhd` DOES NOT COMPILE AT HEAD
# (`B_CONST_HBM` used and never declared).  `read_vhdl` accepts it silently and
# the failure surfaces at `synth_design`, so a per-file catch does NOT protect
# against it: LEVERCOST measured `synth_design -top matvec_int4_desc_axi` dying
# with 7 errors in 35 s from a file the target cannot reach.
# ---------------------------------------------------------------------------
set nread 0
set nskip 0
set nexcl 0
foreach f [lsort [glob -nocomplain -directory $rtldir *.vhd]] {
    if {[string match "ooc_*_top.vhd" [file tail $f]]} {
        puts "CBOOC_READ_EXCLUDE [file tail $f] (harness top, not a closure member)"
        incr nexcl; continue
    }
    if {[catch {read_vhdl -vhdl2008 $f} e]} {
        puts "CBOOC_READ_SKIP $f : $e"; incr nskip
    } else { incr nread }
}
puts "CBOOC_READ tag=$tag files=$nread skipped=$nskip excluded=$nexcl"
if {$nread == 0} { error "CBOOC_ABORT: read 0 VHDL files from $rtldir" }

# ---------------------------------------------------------------------------
# CONSTRAIN BEFORE `synth_design`, NOT AFTER.
#
# This is a deliberate difference from sim/ooc_levercost.tcl, which creates its
# clocks after synthesis.  CLAUDE.md records the criticism under subsystem B's
# harness in as many words: "its `create_clock` runs after `synth_design`, so
# synthesis was never timing-driven".  The question here is about a net's
# fanout and the delay across it, so an unconstrained synthesis would be
# answering a different question.  sim/ooc_leverc48_thread.tcl -- the draw that
# produced the only existing matvec_core numbers at this geometry -- does the
# same, and names `ooc_core_sweep.tcl` and `ooc_fk33_a.tcl` as having recorded
# the after-the-fact form as a trap.
#
# A CLOCK NAMED FOR A PORT THE UNIT DOES NOT HAVE IS SKIPPED AND SAID SO.
# ---------------------------------------------------------------------------
#
# NO `if` MAY APPEAR IN THIS XDC.  Vivado's XDC reader FORBIDS it and skips the
# whole block with only a CRITICAL WARNING (CLAUDE.md), so a guarded
# `create_clock` would silently produce an UNCONSTRAINED synthesis -- exactly
# the failure this section exists to avoid, wearing the costume of a
# defensive check.  The runner passes only clocks the chosen target actually
# has; a name that is not a port raises a CRITICAL WARNING here and is caught
# again by the CBOOC_CLKMISS line after synthesis.
set xdcpath [file join $outdir clk_$tag.xdc]
set xf [open $xdcpath w]
puts $xf "# generated by sim/ooc_cbooc.tcl for tag=$tag -- read BEFORE synth_design"
set nclk 0
set clknames {}
foreach kv $clks {
    set parts [split $kv "="]
    set port  [lindex $parts 0]
    set per   [lindex $parts 1]
    puts $xf "create_clock -name $port -period $per \[get_ports $port\]"
    lappend clknames $port $per
    incr nclk
}
# TWO CLOCKS MUST BE DECLARED ASYNCHRONOUS OR EVERY REPORTED PATH IS A CDC
# CROSSING WHOSE REQUIREMENT IS AN ARTEFACT OF THE TWO PERIODS CHOSEN.
# MEASURED by LEVERCOST on this exact unit: a 0.376 ns one-level path through
# the first stage of a two-flop synchroniser came back at wns=0.939 on a
# 13.333 ns period, which is arithmetically impossible unless the requirement
# was not 13.333.  `matvec_int4_desc_axi` at DUAL_CLK=true is genuinely two
# domains and the shipping XDC says asynchronous.
if {$nclk > 1} {
    set g {}
    foreach {port per} $clknames { lappend g "\[get_clocks $port\]" }
    puts $xf "set_clock_groups -asynchronous -group [join $g " -group "]"
}
close $xf
if {[catch {read_xdc -mode out_of_context $xdcpath} e]} {
    puts "CBOOC_XDC_FAIL tag=$tag : $e"
} else {
    puts "CBOOC_XDC tag=$tag $xdcpath nclk=$nclk"
}

set gl {}
foreach g $gens { lappend gl -generic $g }

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part \
    -flatten_hierarchy $flat $gl
set tsynth [expr {[clock seconds] - $t0}]
puts "CBOOC_SYNTH_SECONDS tag=$tag $tsynth"

# Re-issue the clocks against the elaborated design, because the XDC `if`
# guards above may have been skipped by Vivado's reader with only a CRITICAL
# WARNING.  `create_clock` on a clock that already exists redefines it to the
# same value, so this is idempotent rather than additive.
set made {}
foreach kv $clks {
    set parts [split $kv "="]
    set port  [lindex $parts 0]
    set per   [lindex $parts 1]
    set pobj  [get_ports -quiet $port]
    if {[llength $pobj] == 0} {
        puts "CBOOC_CLKMISS tag=$tag port=$port (not a port on this unit)"
        continue
    }
    create_clock -period $per -name $port $pobj
    lappend made $port $per
    puts "CBOOC_CLKMADE tag=$tag port=$port period=$per"
}
if {[llength $made] > 2} {
    set groups {}
    foreach {port per} $made { lappend groups -group [get_clocks $port] }
    eval set_clock_groups -asynchronous $groups
    puts "CBOOC_CLKASYNC tag=$tag groups=[expr {[llength $made]/2}]"
} else {
    puts "CBOOC_CLKASYNC tag=$tag groups=1 (single clock, nothing to group)"
}

# ---------------------------------------------------------------------------
# THE CENSUS.  Object-level by REF_NAME and AUTHORITATIVE over
# `report_utilization` wherever the two disagree.
# ---------------------------------------------------------------------------
proc census {stage tag outdir} {
    set fh [open [file join $outdir census_${stage}_$tag.txt] w]
    puts $fh "# CBOOC census stage=$stage tag=$tag (get_cells -hier by REF_NAME)"
    set out {}
    foreach {label pat} {
        dsp48    {REF_NAME == DSP48E2}
        uram288  {REF_NAME == URAM288}
        ramb36   {REF_NAME == RAMB36E2}
        ramb18   {REF_NAME == RAMB18E2}
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
        if {$label in {dsp48 uram288 ramb36 ramb18}} {
            foreach c [lsort $cells] { puts $fh "$c" }
        }
    }
    close $fh
    puts "CBOOC_CENSUS stage=$stage tag=$tag [join $out { }]"
    return $out
}

# ---------------------------------------------------------------------------
# THE CODEBOOK CENSUS.  This is the instrument the question needs, and it is
# split in two on purpose.
#
#   cb_reg*   the TABLE.  At CB_STYLE=distributed it must be RAM cells and not
#             flip-flops.  Unchanged by 0b34200 and therefore a CONTROL: if it
#             moves between the arms, something other than the command register
#             bank changed and no other number here is attributable.
#   cbw_*     the COMMAND REGISTERS.  This is the whole of the change.
#             DERIVED: OLD = 13 * CB_COPIES = 13 * 1,536 = 19,968 flip-flops;
#             NEW = 13 * CB_RANKS = 13 * 48 = 624.  Delta -19,344.
#
# A ZERO ON BOTH IS A BROKEN FILTER, NOT AN ANSWER, and it is a hard error --
# LEVERC48's own guard, kept because the codebook cannot be absent.
# ---------------------------------------------------------------------------
proc cb_census {stage tag outdir} {
    set res {}
    foreach {label pat} {
        cb_ram  {NAME =~ *cb_reg* && REF_NAME =~ RAM*}
        cb_ff   {NAME =~ *cb_reg* && REF_NAME =~ FD*}
        cbw_ff  {NAME =~ *cbw_* && REF_NAME =~ FD*}
        cbw_any {NAME =~ *cbw_*}
        cbwv_ff {NAME =~ *cbw_v* && REF_NAME =~ FD*}
        cbwa_ff {NAME =~ *cbw_a* && REF_NAME =~ FD*}
        cbwd_ff {NAME =~ *cbw_d* && REF_NAME =~ FD*}
    } {
        set n [llength [get_cells -hier -quiet -filter $pat]]
        lappend res "$label=$n"
        set v($label) $n
    }
    puts "CBOOC_CB stage=$stage tag=$tag [join $res { }]"
    if {$v(cb_ram) == 0 && $v(cb_ff) == 0} {
        error "CBOOC_ABORT: the cb census found NEITHER RAM cells NOR\
               flip-flops named cb_reg* at stage=$stage.  That is not an\
               answer, it is a broken filter -- the codebook cannot be absent.\
               Fix the census before reading any number from this run."
    }
    if {$v(cbw_any) == 0} {
        error "CBOOC_ABORT: the cb census found NO cells named cbw_* at\
               stage=$stage.  The command register bank cannot be absent in\
               either arm (OLD has 13*CB_COPIES, NEW has 13*CB_RANKS), so this\
               is a broken filter or the wrong target, not a measurement."
    }
    set fh [open [file join $outdir cb_${stage}_$tag.txt] w]
    foreach kv $res { puts $fh $kv }
    close $fh
    return $res
}

# ---------------------------------------------------------------------------
# THE FANOUT CENSUS.  THE NUMBER THIS TRACK EXISTS FOR.
#
# CBFANOUT's claim is exactly this and nothing else: max fanout per command bit
# 1,536 -> 48.  Every other figure in its write-up is downstream of it.  It has
# never been counted by a tool.
#
# Measured TWO ways on purpose, one name-dependent and one not, because a
# name-based filter that matches nothing returns a silent zero:
#
#   A. NAME-INDEPENDENT.  The top-N nets on the whole unit by FLAT_PIN_COUNT.
#      This cannot be fooled by a naming assumption of mine, and it is the form
#      that would have caught build 10 with no prior theory: a 1,537-pin net in
#      a unit whose next-largest is a few hundred is visible on its own.
#   B. NAMED.  The nets on the D pins of the `cbw_*` registers, which IS the
#      net whose delay build 10 failed on.  Reported as a histogram so the
#      answer is a distribution and not a single max.
#
# `FLAT_PIN_COUNT` counts the DRIVER as well, so a net with N sinks reads N+1.
# The runner prints both the raw property and `sinks = FLAT_PIN_COUNT - 1`, and
# no claim is made from the raw number alone.
# ---------------------------------------------------------------------------
proc fanout_census {stage tag outdir topn} {
    # ---- A. name-independent top-N
    #
    # BATCHED ON PURPOSE.  `get_property` takes a LIST of objects and returns a
    # LIST of values in one call; a per-object loop over the ~10^5 nets of this
    # unit is minutes of pure Tcl for a number the tool already has.
    set nets [get_nets -hier -quiet]
    set fps  {}
    if {[llength $nets] > 0} {
        if {[catch {set fps [get_property FLAT_PIN_COUNT $nets]} e]} {
            puts "CBOOC_FANOUT_WARN stage=$stage tag=$tag batched\
 get_property failed ($e); falling back to per-object"
            set fps {}
            foreach n $nets { lappend fps [get_property -quiet FLAT_PIN_COUNT $n] }
        }
    }
    set rows {}
    foreach n $nets fp $fps {
        if {$fp eq "" || ![string is integer -strict $fp]} continue
        lappend rows [list $fp $n]
    }
    set rows [lsort -integer -decreasing -index 0 $rows]
    set fh [open [file join $outdir fanout_top_${stage}_$tag.txt] w]
    puts $fh "# top nets by FLAT_PIN_COUNT, stage=$stage tag=$tag\
 (sinks = FLAT_PIN_COUNT - 1)"
    set i 0
    set top1 "NA"
    foreach r $rows {
        if {$i >= $topn} break
        puts $fh "[lindex $r 0] [lindex $r 1]"
        if {$i == 0} { set top1 [lindex $r 0] }
        incr i
    }
    close $fh
    puts "CBOOC_FANOUT_TOP stage=$stage tag=$tag nets=[llength $rows]\
 max_flat_pin_count=$top1 file=fanout_top_${stage}_$tag.txt"

    # ---- B. named: the command-register input nets
    set cbw [get_cells -hier -quiet -filter {NAME =~ *cbw_* && REF_NAME =~ FD*}]
    set maxfp 0
    set hist {}
    array unset h
    set nnet 0
    if {[llength $cbw] > 0} {
        set dpins [get_pins -quiet -of_objects $cbw -filter {REF_PIN_NAME == D}]
        set dnets [get_nets -quiet -of_objects $dpins]
        # `get_nets -of_objects` de-duplicates, so this list IS the set of
        # distinct command nets.  Its LENGTH is the replication factor and its
        # FLAT_PIN_COUNT is the fanout -- the two halves of CBFANOUT's claim.
        set nnet [llength $dnets]
        set dfps {}
        if {$nnet > 0 && [catch {set dfps [get_property FLAT_PIN_COUNT $dnets]}]} {
            set dfps {}
            foreach n $dnets { lappend dfps [get_property -quiet FLAT_PIN_COUNT $n] }
        }
        foreach n $dnets fp $dfps {
            if {$fp eq "" || ![string is integer -strict $fp]} continue
            if {$fp > $maxfp} { set maxfp $fp }
            if {![info exists h($fp)]} { set h($fp) 0 }
            incr h($fp)
        }
        set fh [open [file join $outdir fanout_cbw_${stage}_$tag.txt] w]
        puts $fh "# distinct nets on cbw_* D pins, stage=$stage tag=$tag"
        puts $fh "# flat_pin_count count_of_nets   (sinks = flat_pin_count - 1)"
        foreach k [lsort -integer -decreasing [array names h]] {
            puts $fh "$k $h($k)"
            lappend hist "${k}x$h($k)"
        }
        close $fh
    }
    puts "CBOOC_FANOUT_CBW stage=$stage tag=$tag cbw_ffs=[llength $cbw]\
 distinct_d_nets=$nnet max_flat_pin_count=$maxfp\
 max_sinks=[expr {$maxfp > 0 ? $maxfp - 1 : 0}] hist=\"[join $hist { }]\""
    return [list $top1 $maxfp $nnet]
}

report_utilization -file [file join $outdir synthutil_$tag.rpt]
set surpt [report_utilization -return_string]
set scens [census synth $tag $outdir]
set scb   [cb_census synth $tag $outdir]
set sfan  [fanout_census synth $tag $outdir [envor CBO_TOPN 30]]

set t1 [clock seconds]
opt_design
set topt [expr {[clock seconds] - $t1}]
puts "CBOOC_OPT_SECONDS tag=$tag $topt"

report_utilization -file [file join $outdir util_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir util_hier_$tag.rpt]
if {[catch {report_ram_utilization -file [file join $outdir ram_$tag.rpt]} e]} {
    puts "CBOOC_NORAMRPT $tag : $e"
}
set urpt [report_utilization -return_string]
set ocens [census opt $tag $outdir]
set ocb   [cb_census opt $tag $outdir]
set ofan  [fanout_census opt $tag $outdir [envor CBO_TOPN 30]]

# A CHECKPOINT, so a later routed comparison costs a read_checkpoint and not a
# second synthesis.  This track's position is that routing does not answer its
# question; the checkpoint is here so that position can be revisited cheaply by
# someone who disagrees, rather than argued about.
if {[envor CBO_DCP 1]} {
    write_checkpoint -force [file join $outdir post_opt_$tag.dcp]
    puts "CBOOC_DCP tag=$tag [file join $outdir post_opt_$tag.dcp]"
}

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
# TIMING.  Per clock, never the global worst alone.
# ---------------------------------------------------------------------------
proc pathline {p} {
    if {$p eq ""} { return "wns=NA" }
    return "wns=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p]\
 datapath=[get_property DATAPATH_DELAY $p] start=[get_property STARTPOINT_PIN $p]\
 end=[get_property ENDPOINT_PIN $p]"
}

report_timing_summary -delay_type max -max_paths 5 \
    -file [file join $outdir timing_summary_$tag.rpt]

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
    # THE TABLE'S OWN SEPARATOR IS A VALID-LOOKING FIRST TOKEN AND IT HAS
    # KILLED TWO 735 s DRAWS.  `get_clocks -quiet -----` reports
    # `ERROR: [Common 17-170] Unknown option '-----'` -- `-quiet` suppresses
    # "no matching object", not a bad option -- and takes the run down AFTER
    # synthesis, opt_design, the census and the checkpoint have all succeeded.
    # `--` does not help: get_clocks rejects that too.  Reject the token here;
    # never hand it to the command defensively.
    if {[string index $nm 0] eq "-"} continue
    if {$nm eq "Clock"} continue
    if {[llength [get_clocks -quiet $nm]] == 0} continue
    puts "CBOOC_INTRA tag=$tag clk=$nm wns=[lindex $f 1] tns=[lindex $f 2]\
 failing=[lindex $f 3] endpoints=[lindex $f 4]"
}

set gp [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]
puts "CBOOC_WORST_GLOBAL tag=$tag [pathline $gp]"

set timcsv {}
foreach {port per} $made {
    set cp [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
                        -to [get_clocks -quiet $port]] 0]
    puts "CBOOC_WORST_CLK tag=$tag clk=$port period=$per [pathline $cp]"
    set w [expr {$cp eq "" ? "NA" : [get_property SLACK $cp]}]
    lappend timcsv "$port:$w"
    report_timing -delay_type max -max_paths 3 -nworst 1 \
        -to [get_clocks -quiet $port] \
        -file [file join $outdir worst_${port}_$tag.rpt]
    set fh [open [file join $outdir paths50_${port}_$tag.txt] w]
    puts $fh "# top-50 intra-domain paths, clk=$port tag=$tag (slack start end levels)"
    foreach p [get_timing_paths -delay_type max -max_paths 50 -nworst 1 \
                   -to [get_clocks -quiet $port]] {
        puts $fh "[get_property SLACK $p] [get_property STARTPOINT_PIN $p]\
 [get_property ENDPOINT_PIN $p] [get_property LOGIC_LEVELS $p]"
    }
    close $fh
}

# ---------------------------------------------------------------------------
# THE PATH CLASS BUILD 10 FAILED ON, reported under its own name.
#
# A WNS COMPARISON ALONE CAN ONLY EVER PRODUCE A BOUND: a change can add a path
# slower than everything around it and still not become THE worst path, in
# which case the WNS does not move and the arm looks free when it is merely
# second (LEVERCOST measured exactly that on this unit).  So the codebook
# write path is reported directly, by endpoint, whether or not it is worst.
#
# An EMPTY result here is a fact about the filter, not about the design, and is
# printed as `paths=0` rather than as a slack of NA that reads like a pass.
# ---------------------------------------------------------------------------
set cbwcells [get_cells -hier -quiet -filter {NAME =~ *cbw_* && REF_NAME =~ FD*}]
set cbwslack "NA"
set ncbwpath 0
if {[llength $cbwcells] > 0} {
    set eps [get_pins -quiet -of_objects $cbwcells -filter {REF_PIN_NAME == D}]
    if {[llength $eps] > 0} {
        set cps {}
        if {[catch {set cps [get_timing_paths -delay_type max -max_paths 20 \
                                 -nworst 1 -to $eps]} e]} {
            puts "CBOOC_CBW_PATH_WARN tag=$tag : $e"
            set cps {}
        }
        set ncbwpath [llength $cps]
        if {$ncbwpath > 0} {
            set cp [lindex $cps 0]
            set cbwslack [get_property SLACK $cp]
            puts "CBOOC_CBW_PATH tag=$tag paths=$ncbwpath [pathline $cp]"
            set fh [open [file join $outdir cbw_paths_$tag.txt] w]
            puts $fh "# paths ending at a cbw_* D pin, tag=$tag"
            foreach p $cps {
                puts $fh "[get_property SLACK $p] [get_property STARTPOINT_PIN $p]\
 [get_property ENDPOINT_PIN $p] [get_property LOGIC_LEVELS $p]\
 [get_property DATAPATH_DELAY $p]"
            }
            close $fh
        }
    }
}
if {$ncbwpath == 0} {
    puts "CBOOC_CBW_PATH tag=$tag paths=0 (no timed path ends at a cbw_* D pin\
 -- this is a fact about the filter or about OOC port timing, NOT a pass)"
}

puts "CBOOC_RESULT tag=$tag lut=$U(lut) lut_logic=$U(lut_logic)\
 lut_mem=$U(lut_mem) ff=$U(ff) bram=$U(bram) ramb36=$U(ramb36)\
 ramb18=$U(ramb18) uram=$U(uram) dsp=$U(dsp) carry8=$U(carry8)\
 f7=$U(f7) f8=$U(f8) synth_s=$tsynth opt_s=$topt timing=\"[join $timcsv { }]\"\
 cbw_worst=$cbwslack"
puts "CBOOC_SYNTH_VS_OPT tag=$tag synth_lut=$S(lut) opt_lut=$U(lut)\
 synth_ff=$S(ff) opt_ff=$U(ff) synth_bram=$S(bram) opt_bram=$U(bram)\
 synth_dsp=$S(dsp) opt_dsp=$U(dsp) synth_uram=$S(uram) opt_uram=$U(uram)"

set csv [open [file join $outdir result_$tag.csv] w]
puts $csv "tag,target,gen,lut,lut_logic,lut_mem,ff,bram_tile,ramb36,ramb18,uram,dsp,carry8,f7,f8,timing_per_clk,cbw_worst_slack,synth_s,opt_s,cb_synth,cb_opt,fan_synth,fan_opt,census_opt"
puts $csv "$tag,$target,\"$gens\",$U(lut),$U(lut_logic),$U(lut_mem),$U(ff),$U(bram),$U(ramb36),$U(ramb18),$U(uram),$U(dsp),$U(carry8),$U(f7),$U(f8),\"[join $timcsv { }]\",$cbwslack,$tsynth,$topt,\"[join $scb { }]\",\"[join $ocb { }]\",\"$sfan\",\"$ofan\",\"[join $ocens { }]\""
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "CBOOC_DONE $tag"
