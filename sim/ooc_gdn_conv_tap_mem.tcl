# OOC census of `rtl/gdn_conv_tap_mem.vhd` -- the conv tap history for ONE GDN
# layer, at the shipping 9B geometry.
#
# THE QUESTION.  49,152 bytes per layer is 393,216 bits, which "is 12 RAMB36".
#
# **THAT SENTENCE IS ABOUT BITS AND IT PREDICTED NOTHING.**  MEASURED
# 2026-09-02, four versions of the module, three of them getting ZERO BRAM:
#
#   v1  one array of 192-bit words, mover writes a lane at a computed offset
#         ->  35,726 CLB LUT (8.13% of the device), 0 BRAM, 28,160 LUT-as-mem
#   v2  array-of-array of 16-bit banks, every write a whole word
#         ->  [Synth 8-11357] "3D-RAM ... with 393216 registers", 0 BRAM
#   v3  banks inside a generate, TRUE dual port in one process
#         ->  [Synth 8-4767] "multiple writes via different ports in same
#             process", dissolved into registers, 0 BRAM
#   v4  banks inside a generate, SIMPLE dual port (one write, one read, each
#       muxed between the unit and the mover -- they are mutually exclusive)
#         ->  12 RAMB36, 317 CLB LUT, 8 FF, WNS +3.831
#
# The bench reported the same 107 checks passing at all four, so each rewrite
# was behaviour-preserving and the ONLY thing that distinguished them was this
# census.  Full sequence: docs/debugging/2026-09-02_conv-tap-history.md.
#
# WHAT TO WATCH ON A RE-RUN: `Block RAM Tile` must be 12 and `LUT as Memory`
# must be 0.  A run that reports LUT-as-memory has lost the inference again,
# and the LUT total is then two orders of magnitude out.
#
# `ram_style = "block"` ON PURPOSE, and unlike the URAM case it CAN be
# honoured: this is a run-time-written store with a SYNCHRONOUS read, which is
# what BRAM is for.  **Vivado's inference log lies in both directions in this
# project** ([Synth 8-10226] claiming a resource it does not give, [Synth
# 8-7186] denying one it does), so the mapping report and the primitive census
# below are the authority and the log is not.
#
# THE SITE COUNT IS THE BUDGET.  `get_cells -filter {REF_NAME =~ LUT*}` counts
# LUT PRIMITIVES and does not see distributed RAM at all; `CLB LUTs` in
# `report_utilization` counts SITES.  Measured wrong by 4.5x once already on
# `gdn_exp_mem`.  Both are printed.

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
read_vhdl -vhdl2008 [file join $rtldir gdn_conv_tap_mem.vhd]
# KEY_CH = lin_key_heads * lin_head_dim = 16 * 128; VAL_CH = 32 * 128.  Both
# from rtl/model_cfg_pkg.vhd's QWEN35_9B, and qkv_dim = 2*KEY_CH + VAL_CH =
# 8192, the identity gen_layer_program.Shape and llama_map_pkg both use.
synth_design -mode out_of_context -top gdn_conv_tap_mem -part $part \
  -generic KCONV=4 -generic CONV_LANES=4 \
  -generic KEY_CH=2048 -generic VAL_CH=4096

create_clock -period $period -name clk [get_ports clk]
set rpt [report_timing_summary -no_header -return_string]
set wns 0.0
set matched 0
if {[regexp {WNS\(ns\)[^\n]*\n[^\n]*\n\s*(-?[0-9.]+)} $rpt -> w]} {
  set wns $w; set matched 1
}
set nlut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nb36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set nb18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
set nuram [llength [get_cells -hier -filter {REF_NAME =~ URAM288*}]]
set nram  [llength [get_cells -hier -filter {REF_NAME =~ RAM6*}]]
set ndsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
puts "CENSUS gdn_conv_tap_mem LUT=$nlut FF=$nff RAMB36=$nb36 RAMB18=$nb18 \
URAM288=$nuram RAM64=$nram DSP=$ndsp WNS=$wns WNS_MATCHED=$matched"
puts "---- report_utilization, for cross-check ----"
puts [report_utilization -return_string]
puts "GDN_CONV_TAP_MEM_CENSUS_DONE"
