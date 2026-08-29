# ooc_compose_bcd.tcl -- TRACK COMPOSE, 2026-08-29.
#
# THE QUESTION.  The FK33 carries subsystem A only: hw/fk33/rtl/fk33_engine.vhd
# instantiates matvec_int4_desc_axi and nothing else, and `llama_top` appears in
# no file under hw/.  A alone MEASURED 1,585 DSP (55.03%) on the routed engine
# build.  The remaining budget for B (Gated DeltaNet), C (gated attention) and
# D (the sequencer) is a MODEL, not a measurement.  This script replaces the
# model with an out-of-context synthesis of each subsystem at the REAL 9B shape.
#
# WHAT AN OOC NUMBER DOES NOT PREDICT, stated up front because the whole point
# of this file is to be honest about its own resolution:
#   - It excludes inter-subsystem routing and any placement effect.
#   - It excludes cross-subsystem resource MERGING: a shared rmsnorm_rs counted
#     once in a composed build is counted twice here (attn_block has one,
#     llama_top has one for the D-vec norm op).
#   - It excludes the FK33 shell entirely (XDMA, HBM controller, clk_wiz, the
#     thermal block, the AXI interconnect).
#   - Synthesis estimates are not implementation results.  The A comparison
#     figure (1,585 DSP / 171,458 LUT) is post-ROUTE for the whole device
#     including the shell, so the LUT columns are not directly comparable and
#     the DSP column is (DSP count does not move between synth and route).
#
# SHAPE PROVENANCE.  Every generic below comes from rtl/model_cfg_pkg.vhd's
# QWEN35_9B record (blocks 32, attn_interval 4, hidden 4096, ffn 12288,
# lin_key_heads 16, lin_val_heads 32, lin_head_dim 128, conv_kernel 4,
# attn_q_heads 16, attn_kv_heads 4, attn_head_dim 256) with NCARDS = 1, or from
# the unit's own default where that default already IS the 9B value.  Nothing
# here is taken from a comment or a spec.
#
# CLOCK.  5.0 ns.  hw/fk33/gen_pcieep.py:294 and :800 put the engine's core_clk
# on clk_wiz_0/clk_out3 at 200 MHz, and the routed build's clock summary
# confirms clk_out3_bd_clk_wiz_0_0 at 5.000 ns / 200.000 MHz.
#
# USAGE:  COMPOSE_TARGET=<name> COMPOSE_OUT=<dir> vivado -mode batch \
#             -source sim/ooc_compose_bcd.tcl
#         One target per vivado invocation, deliberately: the peak RSS of each
#         is then attributable, and a 31 GB box with a systemd-oomd history
#         must not run two.
#
# The script prints COMPOSE_DONE <target> as its LAST action.  A Vivado run can
# print full success and then die on a Tcl error afterwards, so the caller MUST
# gate on that sentinel and not on the last log line.

set part   xcvu33p-fsvh2104-2L-e
set period 5.0

set target [expr {[info exists ::env(COMPOSE_TARGET)] ? $::env(COMPOSE_TARGET) : "gdn_block"}]
set outdir [expr {[info exists ::env(COMPOSE_OUT)]    ? $::env(COMPOSE_OUT)    : "compose_out"}]
set rtldir [expr {[info exists ::env(COMPOSE_RTL)]    ? $::env(COMPOSE_RTL)    : "rtl"}]
file mkdir $outdir

# ---------------------------------------------------------------------------
# The generic sets.  A generic named here is one that DIFFERS from the file's
# own default; a generic absent here is at its default and the default is
# already the 9B value.  Both cases are recorded in the write-up.
# ---------------------------------------------------------------------------
array set GEN {}

# B -- Gated DeltaNet.  rtl/gdn_block.vhd's defaults ARE Qwen3.5-9B on one
# card: its header says so and the numbers agree with model_cfg_pkg
# (KEY_HEADS 16, VAL_HEADS 32, DIM 128, KCONV 4, LAYERS = gdn_layers = 32-8).
set GEN(gdn_block) {}

# C -- gated attention.  rtl/attn_block.vhd's defaults are 27B on ONE OF TWO
# cards (N_QH 12, N_KVH 2, LAYERS 16), so all four shape generics move.
#   HEAD_DIM 256  = QWEN35_9B.attn_head_dim
#   N_QH     16   = attn_q_heads / NCARDS
#   N_KVH    4    = attn_kv_heads / NCARDS
#   LAYERS   8    = attn_layers = blocks / attn_interval = 32/4
# KV_BLOCK 32 and N_ROT 64 stay at the file's defaults, which carry their own
# provenance (C spec 2.1.1 / one 256-bit HBM beat; GGUF rope.dimension_count).
# llama_top's C_KV_BLOCK=4 / C_N_ROT=8 are SIMULATION-scaled and are not used.
set GEN(attn_block) {HEAD_DIM=256 N_QH=16 N_KVH=4 LAYERS=8}

# D -- the sequencer.  Its five leaf units have no sub-instances, so each is
# synthesised alone and the results summed.  Their defaults are already the 9B
# map (NREG 14, STEP_W 11 which the file's own comment says covers 546 steps at
# 9B, REG_SIZE's 4096/12288 which are 9B hidden/ffn, LANES 8 = llama_top's
# LANES).  Nothing moves.
foreach u {seq_desc_fetch seq_opdec seq_region_lock seq_vec_issue seq_vec_res} {
    set GEN($u) {}
}

# The whole composition.  llama_top instantiates matvec_int4 (A), gdn_block (B),
# attn_block (C) and the five seq_* units (D), so at the real SHAPE it is the
# composed design.
#
# ***  THIS TARGET WAS DECLARED AND DELIBERATELY NEVER RUN.  ***
#
# Two independent reasons, and a warning.
#   - It binds `matvec_int4`, not the `matvec_int4_desc_axi` the card runs, so
#     its A is not the shipping A.
#   - Its REGMAX flat region model is disowned by its own header as "what a
#     flat model costs and what a real build would not pay".  TRACK REALFIX
#     raised REGMAX from 4096 to 12288 at `3e93bed` because `region_max` at the
#     9B shape IS 12288, so ANY llama_top area number taken before that sha is
#     of a design that could not address its widest region.  No such number was
#     taken here and none should be quoted from this file.
#   - WARNING, and it is why this comment is this long: merely DECLARING this
#     entry falsifies the project's standing claim that `llama_top` is in no
#     synthesis flow.  It is in one now -- this file.  Anyone adding it to a run
#     list owns the two caveats above plus C's KV map generics, which TRACK
#     REALFIX escalated to Oren as still scaled-shape and illegal at
#     attn_head_dim 256 (C_KV_BLOCK 4, C_K_BASE 16 / C_V_BASE 4064 overlapping,
#     C_KV_ADDR_W 16, C_MAXPOS 4).  Synthesising C THROUGH llama_top hits all of
#     them; synthesising `attn_block` directly, as this file does, does not,
#     because attn_block carries its own port-shape defaults.
set GEN(llama_top) {}

# ---- CONTROLS -------------------------------------------------------------
# Two of B's leaves dominate its LUT count, and both have a pre-existing
# standalone OOC measurement in sim/ooc_micro that is an order of magnitude
# smaller.  These two targets re-measure those leaves ALONE, at exactly the
# generics gdn_block maps onto them (rtl/gdn_block.vhd:594-608), in the same
# Vivado, on the same part, from the same pinned tree, through the same flow.
# Without them the difference cannot be attributed to shape, to RTL drift, to
# the opt_design pass, or to the parent's context, and a number you cannot
# attribute is not a measurement.
set GEN(l2norm_rs) {N=128 LANES=4}
set GEN(gdn_silu)  {LANES=4 ARG_Q=12}

# D's ARITHMETIC, which the five seq_* units do NOT contain.  The sequencer is
# control; the D-vec ops (OP_VEC_NORM / RESIDUAL / SWIGLU) are computed by
# units llama_top instantiates beside it.  The norm one is `rmsnorm_rs` at
# N = SHAPE.hidden = 4096 with NORM_LANES = 4 (rtl/llama_top.vhd:1835 and the
# NORM_REAL/NORM_LANES generics), and it takes the WHOLE vector on one port,
# so N is fixed at elaboration and the port is 4096 x 16 = 65,536 bits wide.
set GEN(rmsnorm_rs) {N=4096 LANES=4}

if {![info exists GEN($target)]} {
    error "COMPOSE FAIL: unknown target '$target'"
}

# ---------------------------------------------------------------------------
puts "COMPOSE_BEGIN target=$target part=$part period=$period rtl=$rtldir"
create_project -in_memory -part $part

# Read every RTL file.  Vivado parses all of them but elaborates only what the
# chosen top references, so this is robust against the per-unit dependency
# graph without hand-maintaining seven file lists.
set files [lsort [glob -directory $rtldir *.vhd]]
foreach f $files {
    if {[catch {read_vhdl -vhdl2008 $f} e]} {
        puts "COMPOSE_READ_SKIP $f : $e"
    }
}

set gl {}
foreach g $GEN($target) { lappend gl -generic $g }
puts "COMPOSE_GENERICS $target : $GEN($target)"

# ATTRIBUTION PROBE.  Vivado's default is -flatten_hierarchy rebuilt: it
# flattens, optimises across every boundary, then REBUILDS the hierarchy for
# reporting.  Cells created by cross-boundary optimisation are attributed to
# whichever module the rebuild names them under, so a per-instance row in
# report_utilization -hierarchical is NOT a measurement of that instance in
# isolation.  Setting COMPOSE_FLATTEN=none keeps the boundaries, which makes
# the per-instance rows honest and gives a second, independent TOTAL from a
# different flow.  It is a probe, not the shipping flow: `none` also forbids
# the cross-boundary optimisation a real build would take, so its total is an
# upper bound and its instance rows are the trustworthy part.
if {[info exists ::env(COMPOSE_FLATTEN)]} {
    lappend gl -flatten_hierarchy $::env(COMPOSE_FLATTEN)
    puts "COMPOSE_FLATTEN $::env(COMPOSE_FLATTEN)"
}

set t0 [clock seconds]
eval synth_design -mode out_of_context -top $target -part $part $gl
set tsynth [expr {[clock seconds] - $t0}]

create_clock -period $period -name clk [get_ports clk]

# BOTH STATES ARE REPORTED, and the reason is a measured trap.  The routed A
# figure this whole exercise compares against is post-IMPLEMENTATION, and
# report_utilization prints its own warning on a synthesized netlist: "The
# Final LUT count, after physical optimizations and full implementation, is
# typically lower.  Run opt_design after synthesis."  The pre-existing
# sim/ooc_micro reports that these numbers are checked against are
# `Design State: Optimized`, so comparing a Synthesized number to them is not
# a like-for-like comparison.  Post-synth is captured first because opt_design
# is destructive, and set COMPOSE_NOOPT=1 to skip the opt pass entirely.
report_utilization -file [file join $outdir synthutil_$target.rpt]
report_utilization -hierarchical -file [file join $outdir synthutil_hier_$target.rpt]
set surpt [report_utilization -return_string]

if {![info exists ::env(COMPOSE_NOOPT)]} {
    set t1 [clock seconds]
    opt_design
    set topt [expr {[clock seconds] - $t1}]
} else {
    set topt -1
}

report_utilization -file [file join $outdir util_$target.rpt]
report_utilization -hierarchical -file [file join $outdir util_hier_$target.rpt]
report_timing_summary -file [file join $outdir timing_$target.rpt]

set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
set fmax [expr {1000.0/($period - $wns)}]

# Numbers come from report_utilization, NOT from get_cells.  Measured here
# 2026-08-29: `get_cells -filter {PRIMITIVE_GROUP == LUT}` returns ZERO on a
# post-synth (unplaced) netlist while report_utilization shows 4,820 CLB LUTs
# for the same design, so the get_cells form used by the older ooc_*.tcl
# scripts silently reports 0 for LUT and FF at this stage.  Parsing the report
# also makes the rows LITERALLY the same rows as the routed A build's
# e2e_util_routed.rpt, which is what the comparison needs.
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
set nlut  [uget $urpt "CLB LUTs*"]
if {$nlut eq "NA"} { set nlut [uget $urpt "CLB LUTs"] }
set nlutl [uget $urpt "LUT as Logic"]
set nlutm [uget $urpt "LUT as Memory"]
set nff   [uget $urpt "CLB Registers"]
set ncar  [uget $urpt "CARRY8"]
set nf7   [uget $urpt "F7 Muxes"]
set nf8   [uget $urpt "F8 Muxes"]
set nbram [uget $urpt "Block RAM Tile"]
set nr36  [uget $urpt "RAMB36/FIFO*"]
set nr18  [uget $urpt "RAMB18"]
set nur   [uget $urpt "URAM"]
set ndsp  [uget $urpt "DSPs"]
if {$ndsp eq "NA"} { set ndsp 0 }
if {$nbram eq "NA"} { set nbram 0 }
if {$nur eq "NA"} { set nur 0 }

set slut [uget $surpt "CLB LUTs*"]
if {$slut eq "NA"} { set slut [uget $surpt "CLB LUTs"] }
set sff  [uget $surpt "CLB Registers"]
set sdsp [uget $surpt "DSPs"]
if {$sdsp eq "NA"} { set sdsp 0 }
set sbr  [uget $surpt "Block RAM Tile"]
if {$sbr eq "NA"} { set sbr 0 }

puts "COMPOSE_RESULT target=$target dsp=$ndsp lut=$nlut lut_logic=$nlutl \
lut_mem=$nlutm ff=$nff ramb36=$nr36 ramb18=$nr18 bram=$nbram uram=$nur \
carry8=$ncar f7=$nf7 f8=$nf8 wns=$wns fmax=$fmax synth_s=$tsynth opt_s=$topt"
puts "COMPOSE_SYNTH_VS_OPT target=$target synth_lut=$slut opt_lut=$nlut \
synth_ff=$sff opt_ff=$nff synth_dsp=$sdsp opt_dsp=$ndsp \
synth_bram=$sbr opt_bram=$nbram"

set csv [open [file join $outdir result_$target.csv] w]
puts $csv "target,dsp,lut,lut_logic,lut_mem,ff,ramb36,ramb18,bram_tile,uram,carry8,f7,f8,wns_ns,fmax_mhz,synth_s,opt_s,synth_lut,synth_ff,synth_dsp,synth_bram"
puts $csv "$target,$ndsp,$nlut,$nlutl,$nlutm,$nff,$nr36,$nr18,$nbram,$nur,$ncar,$nf7,$nf8,$wns,$fmax,$tsynth,$topt,$slut,$sff,$sdsp,$sbr"
close $csv

close_project
# THE SENTINEL.  Nothing may follow it.
puts "COMPOSE_DONE $target"
