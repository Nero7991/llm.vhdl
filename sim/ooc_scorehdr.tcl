# sim/ooc_scorehdr.tcl -- TRACK HDRCOST, 2026-09-20.
#
# PHASE 1 of the SCORE_HDR_TREE cost measurement: one OOC SYNTHESIS of
# `attn_block` at the card's 9B generics, with an object-level census whose
# filters are VALIDATED IN THE SAME RUN against report_utilization, and a
# post-opt checkpoint for phase 2 to place and route.
#
# WHY THIS EXISTS AND sim/ooc_levercost.tcl DOES NOT SERVE.  Two reasons, both
# measured elsewhere in this project:
#
#  1. `grep -cE route_design sim/ooc_levercost.tcl` is ZERO.  SWEEP_PIPE's
#     cost was 64 LUT of extra state and a synthesis number bounded it.
#     SCORE_HDR_TREE's ENTIRE COST IS COMBINATIONAL DEPTH, and on this part
#     nothing before route_design orders two runs correctly: a phys_opt WNS
#     has over-promised by 0.4 to 0.6 ns twice and once INVERTED the verdict
#     (a composed run read +0.006 with zero failing endpoints pre-route and
#     routed at -0.422).  So phase 2 routes.
#
#  2. ooc_levercost.tcl runs `create_clock` AFTER `synth_design`, so its
#     synthesis is NOT timing-driven.  TRACK GDNSYNTH measured the
#     consequence an hour ago in `ooc_gdnadapt`: the core WNS read -4.008 to
#     three decimals across FOUR arms spanning a 63,000-LUT difference,
#     because one common path pinned it and nothing had ever been asked to
#     optimise.  Here the clock is read BEFORE synth_design, so both arms are
#     synthesised against the same 13.333 ns requirement and a depth
#     difference has somewhere to show up.
#
# NO HARDWARE.  synth_design / opt_design / report_* only.
#
# USAGE: SH_TAG=<tag> SH_OUT=<dir> SH_RTL=<dir> SH_GEN="A=1 B=true"
#        SH_PERIOD=13.333 vivado -mode batch -nojournal -source this.tcl
#
# Prints SCOREHDR_SDONE <tag> as its LAST action.  The caller gates on that
# LINE-ANCHORED sentinel: this log contains this script's own source text.

set part xcvu33p-fsvh2104-2L-e

proc envor {name def} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $def}]
}

set tag    [envor SH_TAG    unnamed]
set outdir [envor SH_OUT    .]
set rtldir [envor SH_RTL    rtl]
set gens   [envor SH_GEN    ""]
set period [envor SH_PERIOD 13.333]
set target attn_block

file mkdir $outdir
puts "SCOREHDR_BEGIN tag=$tag target=$target part=$part period=$period"
puts "SCOREHDR_GENERICS tag=$tag gen=\"$gens\""

create_project -in_memory -part $part

# The two messages this project has recorded as lying, in both directions.
# Raised so a COUNT is a census and not the message limit: LEVERCOST measured
# `[Synth 8-7186]` = 101, of which the 101st is `[Common 17-14]` saying the
# limit was reached.
foreach mid {{Synth 8-7186} {Synth 8-10226}} {
    if {[catch {set_msg_config -id $mid -limit 100000} e]} {
        puts "SCOREHDR_MSGLIMIT_FAIL $mid : $e"
    }
}

# Read the whole rtl directory EXCEPT the other tracks' OOC harness tops.
# `rtl/ooc_gdnadapt_top.vhd` does not compile at HEAD (it uses B_CONST_HBM and
# never declares it); `read_vhdl` accepts it silently and synth_design then
# dies on a file the target cannot reach.  LEVERCOST measured exactly that.
set nread 0; set nskip 0; set nexcl 0
foreach f [lsort [glob -directory $rtldir *.vhd]] {
    if {[string match "ooc_*_top.vhd" [file tail $f]]} {
        incr nexcl; continue
    }
    if {[catch {read_vhdl -vhdl2008 $f} e]} {
        puts "SCOREHDR_READ_SKIP $f : $e"; incr nskip
    } else { incr nread }
}
puts "SCOREHDR_READ tag=$tag files=$nread skipped=$nskip excluded=$nexcl"

# THE CLOCK, BEFORE SYNTHESIS.  See reason 2 in the header.
set xdc [file join $outdir clk_$tag.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc
puts "SCOREHDR_XDC tag=$tag $xdc period=$period"

set gl {}
foreach g $gens { lappend gl -generic $g }

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part \
    -flatten_hierarchy none $gl
set tsynth [expr {[clock seconds] - $t0}]
puts "SCOREHDR_SYNTH_SECONDS tag=$tag $tsynth"

# ---------------------------------------------------------------------------
# THE CENSUS, AND THE VALIDATION OF ITS OWN FILTERS.
#
# CLAUDE.md records `REF_NAME =~ DSP*` as the working idiom.  TRACK GDNSYNTH
# MEASURED that it OVER-COUNTS BY EXACTLY 9x -- 1,719 against a true 191 --
# because Vivado transforms each DSP48E2 into itself plus eight internal
# primitives (DSP_ALU, DSP_A_B_DATA, DSP_C_DATA, DSP_MULTIPLIER, DSP_M_DATA,
# DSP_OUTPUT, DSP_PREADD, DSP_PREADD_DATA) which all match `DSP*`.  So a
# census is authoritative only when its FILTER is right, and a filter can be
# wrong in EITHER direction: the inherited `RAM32*|RAM64*|...` LUTRAM filter
# UNDER-counted by 4x on gdn_block by missing RAMD32/RAMS32/RAMD64E/RAMS64E.
#
# This proc therefore prints BOTH forms for DSP and reports the ratio, and it
# cross-checks the exact filters against report_utilization's own rows.  A
# filter is quoted only after the run has shown it agrees with a known-good
# total, or has shown exactly how it disagrees and why.
# ---------------------------------------------------------------------------
proc uget {rpt label} {
    foreach line [split $rpt "\n"] {
        if {[string index [string trim $line] 0] ne "|"} continue
        set f [split $line "|"]
        if {[llength $f] < 4} continue
        if {[string trim [lindex $f 1]] eq $label} { return [string trim [lindex $f 2]] }
    }
    return "NA"
}

proc census {stage tag outdir} {
    set fh [open [file join $outdir census_${stage}_$tag.txt] w]
    puts $fh "# HDRCOST census stage=$stage tag=$tag (get_cells -hier by REF_NAME)"
    set out {}
    foreach {label pat} {
        dsp48_exact   {REF_NAME == DSP48E2}
        dsp_wildcard  {REF_NAME =~ DSP*}
        uram288       {REF_NAME == URAM288}
        ramb36        {REF_NAME == RAMB36E2}
        ramb18        {REF_NAME == RAMB18E2}
        lutram        {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256* || REF_NAME =~ RAM512* || REF_NAME =~ RAMD* || REF_NAME =~ RAMS*}
        lut_all       {REF_NAME =~ LUT*}
        lut1          {REF_NAME == LUT1}
        lut2          {REF_NAME == LUT2}
        lut3          {REF_NAME == LUT3}
        lut4          {REF_NAME == LUT4}
        lut5          {REF_NAME == LUT5}
        lut6          {REF_NAME == LUT6}
        ff            {REF_NAME =~ FD*}
        fdre          {REF_NAME == FDRE}
        fdse          {REF_NAME == FDSE}
        fdce          {REF_NAME == FDCE}
        fdpe          {REF_NAME == FDPE}
        carry8        {REF_NAME == CARRY8}
        f7            {REF_NAME == MUXF7}
        f8            {REF_NAME == MUXF8}
        f9            {REF_NAME == MUXF9}
        srl           {REF_NAME =~ SRL*}
    } {
        set n [llength [get_cells -hier -quiet -filter $pat]]
        lappend out "$label=$n"
        puts $fh "## $label $n"
    }
    close $fh
    puts "SCOREHDR_CENSUS stage=$stage tag=$tag [join $out { }]"
    return $out
}

# THE SCORE CONE, COUNTED SEPARATELY.  The whole question is what the four
# `gen_head[*].u_sq` instances cost, and a block-level total of ~87,000 LUT
# cannot resolve an ESTIMATE of +520 to +800 without attributing it.  A total
# that moves is not evidence about WHICH object moved -- this project charged
# a 5,472-tile BRAM array to the wrong instance that way.
proc conecensus {stage tag outdir} {
    set cells [get_cells -hier -quiet -filter {NAME =~ *u_sq*}]
    array unset byref
    foreach c $cells {
        set r [get_property REF_NAME $c]
        if {![info exists byref($r)]} { set byref($r) 0 }
        incr byref($r)
    }
    set out {}
    set nlut 0; set nff 0; set ncar 0; set nmux 0
    foreach r [lsort [array names byref]] {
        lappend out "$r=$byref($r)"
        if {[string match "LUT*" $r]}   { incr nlut $byref($r) }
        if {[string match "FD*" $r]}    { incr nff  $byref($r) }
        if {$r eq "CARRY8"}             { incr ncar $byref($r) }
        if {[string match "MUXF*" $r]}  { incr nmux $byref($r) }
    }
    puts "SCOREHDR_CONE stage=$stage tag=$tag total=[llength $cells]\
 lut=$nlut ff=$nff carry8=$ncar muxf=$nmux"
    puts "SCOREHDR_CONEREF stage=$stage tag=$tag [join $out { }]"
    set fh [open [file join $outdir cone_${stage}_$tag.txt] w]
    puts $fh "# cells under *u_sq* by REF_NAME, stage=$stage tag=$tag"
    foreach r [lsort [array names byref]] { puts $fh "$r $byref($r)" }
    close $fh
    # Per-instance, so a claim can be attributed to one of the four rather
    # than to their sum.
    set fh [open [file join $outdir cone_byinst_${stage}_$tag.txt] w]
    array unset byinst
    foreach c $cells {
        if {[regexp {(gen_head\[[0-9]+\])} $c -> k]} {
            if {![info exists byinst($k)]} { set byinst($k) 0 }
            incr byinst($k)
        }
    }
    foreach k [lsort [array names byinst]] { puts $fh "$k $byinst($k)" }
    close $fh
}

report_utilization -file [file join $outdir synthutil_$tag.rpt]
set surpt [report_utilization -return_string]
census synth $tag $outdir
conecensus synth $tag $outdir

set t1 [clock seconds]
opt_design
set topt [expr {[clock seconds] - $t1}]
puts "SCOREHDR_OPT_SECONDS tag=$tag $topt"

report_utilization -file [file join $outdir optutil_$tag.rpt]
report_utilization -hierarchical -file [file join $outdir optutil_hier_$tag.rpt]
set urpt [report_utilization -return_string]
set ocens [census opt $tag $outdir]
conecensus opt $tag $outdir

# ---- FILTER VALIDATION, printed so it can be argued with ------------------
# Each line is <filter> <census> <report_utilization row> <verdict>.  A filter
# is only quotable in the write-up if its row says AGREE, or if the write-up
# states the exact reason it does not (LUT cells are not LUT sites: Vivado
# combines two 5-input LUTs into one site, so the census necessarily exceeds
# the adjusted `CLB LUTs*` row and the two measure different things).
proc vrow {name cval rval} {
    set verdict [expr {$cval == $rval ? "AGREE" : "DIFFER"}]
    puts "SCOREHDR_FILTERCHK $name census=$cval report=$rval $verdict"
}
set c_ff   [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
set c_dspx [llength [get_cells -hier -quiet -filter {REF_NAME == DSP48E2}]]
set c_dspw [llength [get_cells -hier -quiet -filter {REF_NAME =~ DSP*}]]
set c_car  [llength [get_cells -hier -quiet -filter {REF_NAME == CARRY8}]]
set c_f7   [llength [get_cells -hier -quiet -filter {REF_NAME == MUXF7}]]
set c_f8   [llength [get_cells -hier -quiet -filter {REF_NAME == MUXF8}]]
set c_b36  [llength [get_cells -hier -quiet -filter {REF_NAME == RAMB36E2}]]
vrow "REF_NAME=~FD*"      $c_ff   [uget $urpt "CLB Registers"]
vrow "REF_NAME==DSP48E2"  $c_dspx [uget $urpt "DSPs"]
vrow "REF_NAME=~DSP*"     $c_dspw [uget $urpt "DSPs"]
vrow "REF_NAME==CARRY8"   $c_car  [uget $urpt "CARRY8"]
vrow "REF_NAME==MUXF7"    $c_f7   [uget $urpt "F7 Muxes"]
vrow "REF_NAME==MUXF8"    $c_f8   [uget $urpt "F8 Muxes"]
vrow "REF_NAME==RAMB36E2" $c_b36  [uget $urpt "RAMB36/FIFO*"]
if {$c_dspx > 0} {
    puts "SCOREHDR_DSPRATIO tag=$tag wildcard/exact = [format %.4f [expr {double($c_dspw)/$c_dspx}]]"
} else {
    puts "SCOREHDR_DSPRATIO tag=$tag exact=0 (no DSP48E2 in this unit; the\
 wildcard filter cannot be validated here and is not quoted)"
}

write_checkpoint -force [file join $outdir post_opt_$tag.dcp]
puts "SCOREHDR_DCP tag=$tag [file join $outdir post_opt_$tag.dcp]"

puts "SCOREHDR_SRESULT tag=$tag\
 lut_sites=[uget $urpt {CLB LUTs*}] lut_logic=[uget $urpt {LUT as Logic}]\
 lut_mem=[uget $urpt {LUT as Memory}] ff=[uget $urpt {CLB Registers}]\
 carry8=[uget $urpt CARRY8] f7=[uget $urpt {F7 Muxes}] f8=[uget $urpt {F8 Muxes}]\
 bram=[uget $urpt {Block RAM Tile}] dsp=[uget $urpt DSPs]\
 synth_s=$tsynth opt_s=$topt"

set csv [open [file join $outdir synth_$tag.csv] w]
puts $csv "tag,gen,lut_sites,lut_logic,lut_mem,ff,carry8,f7,f8,bram,dsp,synth_s,opt_s,census"
puts $csv "$tag,\"$gens\",[uget $urpt {CLB LUTs*}],[uget $urpt {LUT as Logic}],[uget $urpt {LUT as Memory}],[uget $urpt {CLB Registers}],[uget $urpt CARRY8],[uget $urpt {F7 Muxes}],[uget $urpt {F8 Muxes}],[uget $urpt {Block RAM Tile}],[uget $urpt DSPs],$tsynth,$topt,\"[join $ocens { }]\""
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "SCOREHDR_SDONE $tag"
