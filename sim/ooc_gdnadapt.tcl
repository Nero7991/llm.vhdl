# OOC synthesis of subsystem B's DATA MOVER, extracted from llama_top's
# gb_real block by sim/ooc_gdnadapt_extract.py.  Same method as
# sim/ooc_normadapt_extract.py + the nwrom runs did for the D-vec norm adapter.
#
# WHAT THIS ANSWERS: what B's mover costs, which nothing has ever measured,
# because until now the block could not be built outside llama_top.
# WHAT IT DOES NOT: whether B computes a correct token.  llama_top:4316 still
# refuses B_SRC_REAL past token 0.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
set rtldir $pfRoot/rtl
create_project -in_memory -part $part
foreach f [glob $rtldir/*.vhd] { read_vhdl -vhdl2008 $f }
# MAXROWS is swept from the environment so the 9B default and a small control
# are the SAME script.  See the generic's comment in the extract script.
set mr [expr {[info exists ::env(GDNADAPT_MAXROWS)] ? $::env(GDNADAPT_MAXROWS) : 0}]
puts "=== A_MAXROWS override = $mr (0 = region_max(SHAPE), 12288 at 9B) ==="
# B_STATE_AXI IS THE ARM THE CARD BUILDS, AND THIS HARNESS COULD NOT SET IT.
# `rtl/ooc_gdnadapt_top.vhd` defaults it FALSE; `hw/fk33/rtl/fk33_card.vhd`
# passes TRUE.  The generic selects between two mutually exclusive generates:
#   gen_st_flat : if not B_STATE_AXI  -- the flat all-layers state array
#   gen_st_tier : if     B_STATE_AXI  -- the tiered arm, state over AXI to HBM
# So every figure this harness has produced measures the arm the card does NOT
# build, including the project's headline B blocker of 5,472 RAMB36 against 672
# on the part, which is that flat array.
#
# C_MAXPOS likewise defaults to 4 here against the card's 131072.
#
# Defaults below reproduce every figure taken before this change.
set sax [expr {[info exists ::env(GDNADAPT_STATE_AXI)] ? $::env(GDNADAPT_STATE_AXI) : "false"}]
set mp  [expr {[info exists ::env(GDNADAPT_MAXPOS)]    ? $::env(GDNADAPT_MAXPOS)    : 4}]
# B_RECUR_LANES, swept from the environment for the same reason MAXROWS is:
# the shipping arm and the lever arm must be the SAME SCRIPT against the SAME
# TREE, or the comparison is two unrelated measurements (see CLAUDE.md, "a
# comparison needs both ends drawn from the same tree").  The default is 4,
# which is `rtl/llama_top.vhd:816`'s shipping value and is also this file's
# behaviour before the hook existed, so every figure taken earlier stays
# reproducible by running with no variable set.
#
# THE ARM THIS SELECTS IS NOT THE ARM THE CARD BUILDS.  It rides on top of the
# B_STATE_AXI=false default documented above, so a delta measured here is a
# delta in `gen_st_flat`.  TRACK GDNSYNTH, 2026-09-20.
set rl  [expr {[info exists ::env(GDNADAPT_RECUR_LANES)] ? $::env(GDNADAPT_RECUR_LANES) : 4}]
# B_CONST_HBM, exposed for the same reason and with the same default-FALSE
# discipline.  `hw/fk33/gen_fk33_card.py:171` passes it TRUE, so a run meant to
# resemble the card must set BOTH this and GDNADAPT_STATE_AXI; a run meant to
# reproduce an earlier figure must set neither.  Making it settable is what
# turns "this harness measures a different configuration from the card" from a
# fact you have to remember into one you can control for.
set ch  [expr {[info exists ::env(GDNADAPT_CONST_HBM)] ? $::env(GDNADAPT_CONST_HBM) : "false"}]
puts "GDNADAPT_CONFIG state_axi=$sax const_hbm=$ch maxpos=$mp maxrows=$mr recur_lanes=$rl"

synth_design -mode out_of_context -top ooc_gdnadapt -part $part \
             -generic MAXROWS_OVR=$mr \
             -generic B_RECUR_LANES=$rl \
             -generic B_CONST_HBM=$ch \
             -generic B_STATE_AXI=$sax -generic C_MAXPOS=$mp
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization (the budget numbers) ==="
puts [report_utilization -return_string]
# OBJECT-LEVEL CENSUS, because the utilization total and the inference log have
# each lied here before: `[Synth 8-7186]` claims an inference was ignored for
# objects the mapping report then names as RAM32M16, and `[Synth 8-10226]`
# refuses a URAM request while the run still reports a bram column that three
# documents quoted as URAM.  Census wins where they disagree.
#
# `REF_NAME =~ DSP*`, NOT `PRIMITIVE_GROUP == DSP`: the latter matches nothing
# on this part and returns WARNING [Vivado 12-180], not an error, so a census
# written that way prints zero lines beside a utilization row of 194.
# Every line carries a prefix so a reader can grep it LINE-ANCHORED.  The
# caller invokes this script with `-notrace`, so the source is NOT echoed into
# the log today (MEASURED 2026-09-20) -- the prefix is insurance against a
# caller that drops the flag, which is how `ooc_compose4_pnr.tcl` came to
# report a finished synthesis seconds after launch, twice.
puts "GDNSYNTH_CENSUS ram   [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAM*}]]"
# `DSP48E2`, NOT `DSP*`.  MEASURED 2026-09-20, TRACK GDNSYNTH: the broad form
# returned 1,719 against a utilization row of 191, EXACTLY 9x, because after
# synthesis a DSP is a hierarchy of sub-primitives (DSP_ALU, DSP_MULTIPLIER,
# DSP_M_DATA, DSP_PREADD, DSP_OUTPUT ...) and every one of them matches `DSP*`.
# This file already warns that `PRIMITIVE_GROUP == DSP` matches NOTHING; the
# lesson is that a census is only authoritative when its FILTER is right, and
# a filter can be wrong in either direction.  Both forms are printed so the
# ratio stays visible rather than becoming a silent correction.
puts "GDNSYNTH_CENSUS dsp48 [llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP48*}]]"
puts "GDNSYNTH_CENSUS dspsub [llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP*}]]"
puts "GDNSYNTH_CENSUS ramb36 [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB36*}]]"
puts "GDNSYNTH_CENSUS ramb18 [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB18*}]]"
puts "GDNSYNTH_CENSUS uram  [llength [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]]"
puts "GDNSYNTH_CENSUS ff    [llength [get_cells -quiet -hier -filter {REF_NAME =~ FD*}]]"
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
puts "RESULT ooc_gdnadapt wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
# Second, independent read of the same quantity.  The regex above parses a
# formatted table and a table that changes shape silently yields 0.0, which is
# indistinguishable from a design that meets timing.  This one asks the netlist.
# IT IS WEAKER THAN A POST-SYNTHESIS NUMBER, AND THE ORDER ABOVE IS WHY.
# `create_clock` runs AFTER `synth_design`, so synthesis saw NO clock and was
# not timing-driven; what these two lines report is a static analysis of an
# UNCONSTRAINED netlist against a clock invented afterwards.  Nothing here
# places or routes either, and this project has measured a pre-route WNS
# over-promising 0.4 to 0.6 ns on this part, enough to invert a verdict.
#
# So: comparable BETWEEN ARMS of this script, because both arms are wrong in
# the same way.  It is not an fmax, it is not a blocker, and it must never be
# quoted as either.  Only a routed run answers timing.
set gp [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup]
if {[llength $gp]} {
    puts "GDNSYNTH_WNS [get_property SLACK [lindex $gp 0]] clk_period $period"
} else {
    puts "GDNSYNTH_WNS none clk_period $period"
}
puts "OOC_GDNADAPT_DONE"
