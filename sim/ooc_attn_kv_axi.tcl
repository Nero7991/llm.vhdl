# OOC synthesis of attn_kv_axi at the COMPOSED shape, because nothing has ever
# measured it.
#
# WHY THIS MATTERS.  docs/debugging/2026-09-05_does-the-full-design-fit-on-the-
# card.md answers "does it fit" from `compose4_top`, and `compose4_top`
# instantiates `gdn_block` and `attn_block` DIRECTLY -- it has no
# `gdn_state_store` and no `attn_kv_axi`.  Those two are what the `B_STATE_AXI`
# and `C_KV_AXI` generates instantiate inside `llama_top`, and they are the
# blocks that own the HBM masters the port budget is written about.  So the fit
# answer is missing the whole KV cache interface and the whole GDN state store.
# `gdn_state_store` at least HAS a recorded figure (4,028 LUT, 2,004 FF, 32
# URAM288, 12 RAMB36, 3 DSP).  This one has none at all.
#
# SHAPE.  Matched to `compose4_top`'s own C instance -- HEAD_DIM 256, N_KVH 4,
# LAYERS 8 -- so the number can be added to that design's context rather than
# to a different one.  KV_BLOCK 32 is the composed value; note that
# docs/debugging/2026-09-05_kv-block-4-is-a-cost-not-a-lever.md measured
# KV_BLOCK 4 costing 1.309 ns, so 32 is the right point.
#
# MAXCTX IS LEFT AT ITS DEFAULT 2048 AND THAT IS A LIMITATION, NOT A CHOICE.
# The card's real `max_context` is 262,144, and `POS_W = 16` caps MAXCTX at
# 65,536, so the card configuration is NOT this one.  MAXCTX enters address
# arithmetic rather than storage (the cache lives in HBM), so the effect on
# area should be small -- but "should be" is not a measurement, and this run
# does not make one.  Do not quote this figure as the card's.
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
# util_pkg FIRST: attn_kv_axi.vhd:265 is `use work.util_pkg.all` and that is
# where `clog2` lives.  Reading the entity alone fails with
# `[Synth 8-36] 'clog2' is not declared` followed by
# `[Synth 8-439] module 'attn_kv_axi' not found`, which reads like a missing
# top rather than a missing package.
foreach f {util_pkg.vhd attn_kv_axi.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top attn_kv_axi -part $part \
             -generic HEAD_DIM=256 -generic KV_BLOCK=32 -generic N_KVH=4 \
             -generic LAYERS=8
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization ==="
puts [report_utilization -return_string]
puts "=== Report RAM Utilization (the NAMING table -- read this, not the total) ==="
if {[catch {puts [report_ram_utilization -return_string]} e]} { puts "no ram report: $e" }
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
# REF_NAME =~ DSP* , not PRIMITIVE_GROUP == DSP: the latter matches nothing and
# is only a WARNING, so a census silently prints zero while utilization says 194.
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
set nram  [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
set nbram [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
puts "RESULT attn_kv_axi lut=$nlut ff=$nff dsp=$ndsp ram=$nram bram=$nbram uram=$nuram wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "ATTN_KV_AXI_OOC_DONE"
