# OOC synthesis of attn_kv_axi AT THE CARD'S OWN GENERICS.
#
# WHY THIS EXISTS, and why it is a separate file from sim/ooc_attn_kv_axi.tcl.
# That harness says so itself, and the sentence is the reason this one was
# written:
#
#     "MAXCTX IS LEFT AT ITS DEFAULT 2048 AND THAT IS A LIMITATION, NOT A
#      CHOICE. ... the card configuration is NOT this one. ... Do not quote
#      this figure as the card's."
#
# So `attn_kv_axi` at the geometry the CARD actually instantiates has never
# been synthesised. It is one of exactly two blocks the card configuration
# ADDS -- `C_KV_AXI` brings in this, `B_STATE_AXI` brings in
# `gdn_state_store` -- and `compose4_top`, the design the project's "does it
# fit" answer comes from, contains NEITHER. The fit answer is therefore missing
# the whole KV cache interface.
#
# It is also a suspect for the RTL Elaboration wall (see
# docs/debugging/2026-09-11_the-elaboration-wall-and-an-illegal-trim.md): no
# card build has ever printed `Finished RTL Elaboration`, and this is a block
# the card turns on and no other synthesis flow does.
#
# THE THREE GENERICS THAT DIFFER FROM THE EXISTING HARNESS, all read from
# rtl/llama_top.vhd's `u_kv` instantiation rather than assumed:
#
#     MAXCTX   2048 -> 131072   C_MAXPOS, Qwen3.5-9B's native context
#     POS_W      16 -> 18       POSW = clog2(C_MAXPOS + 1); the block's own
#                               default 16 caps MAXCTX at 65,536, so leaving it
#                               would be a DIFFERENT and illegal design
#     ADDR_W     16 -> 33       C_KV_ADDR_W; clog2 of the top of the V arena
#
# The rest match the card exactly: HEAD_DIM 256, KV_BLOCK 32, N_KVH 4,
# LAYERS 8, CM_W 8, EXP_W 8, AXI_DW 256, MAXB 16 (AXI3 ARLEN is 4 bits),
# MAXOUT 4, RBUF 4.
#
# EXPECTED RESULT IS NOT PINNED, deliberately. The question is whether this
# block is cheap at the card's context or expensive, and pre-registering a
# guess would only make it tempting to read the answer as confirmation.
# MAXCTX enters ADDRESS ARITHMETIC rather than storage -- the cache lives in
# HBM -- so the existing harness reasoned the area effect "should be small".
# That is the claim under test, and "should be" is not a measurement.
set part   xcvu33p-fsvh2104-2L-e
set period 5.0
set rtldir /home/orencollaco/GitHub/llama.vhdl/rtl
create_project -in_memory -part $part
# util_pkg FIRST: attn_kv_axi.vhd:265 is `use work.util_pkg.all` and that is
# where `clog2` lives. Reading the entity alone fails with
# `[Synth 8-36] 'clog2' is not declared` then `[Synth 8-439] module not found`,
# which reads like a missing top rather than a missing package.
foreach f {util_pkg.vhd attn_kv_axi.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top attn_kv_axi -part $part \
             -generic HEAD_DIM=256 -generic KV_BLOCK=32 -generic N_KVH=4 \
             -generic LAYERS=8 -generic MAXCTX=131072 -generic POS_W=18 \
             -generic CM_W=8 -generic EXP_W=8 \
             -generic AXI_DW=256 -generic ADDR_W=33 \
             -generic MAXB=16 -generic MAXOUT=4 -generic RBUF=4
create_clock -period $period -name clk [get_ports clk]
puts "=== report_utilization ==="
puts [report_utilization -return_string]
puts "=== Report RAM Utilization (the NAMING table -- read this, not the total) ==="
if {[catch {puts [report_ram_utilization -return_string]} e]} { puts "no ram report: $e" }
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} { set wns $w }
# REF_NAME =~ DSP*, not PRIMITIVE_GROUP == DSP: the latter matches nothing and
# is only a WARNING, so a census silently prints zero while utilization says 194.
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
set nram  [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
set nbram [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
puts "RESULT attn_kv_axi_card lut=$nlut ff=$nff dsp=$ndsp ram=$nram bram=$nbram uram=$nuram wns=$wns fmax=[expr {1000.0/($period-$wns)}]"
puts "ATTN_KV_AXI_CARD_OOC_DONE"
