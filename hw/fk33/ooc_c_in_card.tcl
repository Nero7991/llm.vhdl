# hw/fk33/ooc_c_in_card.tcl -- synthesise the CARD'S OWN TOP with A and B
# STUBBED and C REAL, to isolate subsystem C in the context that ships.
#
# THE QUESTION. Two separate gaps meet here.
#
# 1. FIT. `compose4_top`, where the project's "does it fit" answer comes from,
#    instantiates `gdn_block` and `attn_block` DIRECTLY and contains NEITHER
#    `attn_kv_axi` NOR `gdn_state_store` -- the two blocks the card
#    configuration ADDS. So that answer is missing the whole KV cache
#    interface. `attn_kv_axi` alone is 33,259 LUT at the card's geometry
#    (MEASURED 2026-09-11). But the parts do NOT sum across synthesis contexts
#    -- this repository has already recorded `gdn_block` reporting 22 BRAM
#    alone and 5,472 attributed elsewhere in a composed run -- so adding
#    87,340 + 33,259 would be two unrelated measurements, not a prediction.
#    C has to be measured IN the card top.
#
# 2. THE WALL. `grep -c 'Finished RTL Elaboration'` is ZERO across every
#    surviving card log: twelve attempts, two machines. Every one of them ran
#    with C as a STUB, because the card passed no `C_REAL` until 34a9ce1. With
#    A and B stubbed and C real, this run asks whether C's presence in the card
#    top is what makes elaboration intractable. A previously recorded run with
#    B and C BOTH black-boxed cleared elaboration and stalled in optimisation
#    instead, so the cost is B/C content in the composition -- this halves that.
#
# WHY `fk33_llama_top` AND NOT `fk33_card`. The wrapper declares no generics on
# purpose (it exists to give the packager a cell with nothing to infer), so the
# configuration cannot be varied through it. `hw/fk33/ooc_card_dcp.tcl` targets
# the wrapper and is the right harness for the shipping configuration; this one
# targets the top beneath it so A and B can be stubbed.
#
# NOT `llama_top`: PLAN_TO_FIRST_INFERENCE records that its flat region scratch
# is 2,752,512 bits which Vivado cannot infer, cannot dissolve, and SEGFAULTS
# attempting. `fk33_llama_top` is the D3 transform that replaces it with
# `region_mem`, which is why HOST_WINDOW=false is passed below.
#
# GENERICS ARE THE CARD'S, read from hw/fk33/rtl/fk33_card.vhd rather than
# assumed, EXCEPT A_BEHAV/B_BEHAV which are the variable under test.
set part xcvu33p-fsvh2104-2L-e
puts "CINCARD_BEGIN part=$part flatten=none A_BEHAV=true B_BEHAV=true C_REAL=true"
create_project -in_memory -part $part

# pfRoot -- the repo root, DERIVED from this script's own location rather than
# written in as a literal, so the run works from any checkout path and survives
# the repo directory being renamed (TRACK PATHFREE, 2026-09-20).  Probed rather
# than trusted: a wrong root would otherwise read_vhdl nothing and fail much
# later as a missing entity.
set pfRoot [file normalize [file join [file dirname [info script]] .. ..]]
if {![file exists $pfRoot/rtl/util_pkg.vhd]} {
    error "pfRoot: derived repo root '$pfRoot' does not contain rtl/util_pkg.vhd. Source this script by its path in the tree."
}
read_vhdl -vhdl2008 $pfRoot/hw/fk33/rtl/fk33_aux.vhd
read_vhdl -vhdl2008 $pfRoot/hw/fk33/rtl/fk33_thermal.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/util_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/mv4i_arith_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/matvec_int4_desc_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/stream_fifo.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/async_fifo.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/axi_rd_fsm.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/axi_rd_port.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/weight_streamer.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/act_mem_striped.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/matvec_core.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/matvec_int4.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/matvec_int4_desc_axi.vhd
read_vhdl -vhdl2008 $pfRoot/hw/fk33/rtl/fk33_engine.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/fk33_seam.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/bc_port_grant.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/a_desc_adapter.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/a_job_counter.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_emit.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/fixed_luts_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_gate.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_kv_quant.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_mac_array.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/divider_rs.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_recip.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_rope.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_score_q12.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_softmax.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/imrope_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_twiddle.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/fixed_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/rmsnorm_rs.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_block.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/attn_kv_axi.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_conv.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_head_emit.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_silu.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_y_emit.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/rmsnorm_bf.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_emit_chain.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_exp_capture.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_recur_pipe.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_scalar.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/l2norm_rs.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_block.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_job_seq.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_conv_tap_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_conv_w_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_exp_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_state_axi.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_state_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/gdn_state_store.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/model_cfg_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/llama_map_pkg.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/region_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/vec_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/rmsnorm_rs_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/rmsnorm_bf_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/swiglu_mem.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/sampler_stream.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/seq_desc_fetch.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/seq_opdec.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/seq_region_lock.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/seq_vec_issue.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/seq_vec_res.vhd
read_vhdl -vhdl2008 $pfRoot/rtl/fk33_llama_top.vhd
read_vhdl -vhdl2008 $pfRoot/hw/fk33/rtl/fk33_bc_grant.vhd
read_vhdl -vhdl2008 $pfRoot/hw/fk33/rtl/fk33_card.vhd

set t0 [clock seconds]
set t0 [clock seconds]
synth_design -mode out_of_context -top fk33_llama_top -part $part \
             -flatten_hierarchy none \
             -generic A_BEHAV=true -generic B_BEHAV=true \
             -generic A_DESC=false \
             -generic C_REAL=true -generic C_KV_AXI=true \
             -generic NORM_REAL=true \
             -generic HOST_WINDOW=false \
             -generic C_N_ROT=64 -generic C_KV_BLOCK=32 \
             -generic C_KV_ADDR_W=33 \
             -generic C_K_BASE_CH=282672640 -generic C_V_BASE_CH=353975808 \
             -generic C_MAXPOS=131072 -generic C_CTXLEN=131072
set tsynth [expr {[clock seconds] - $t0}]
puts "CINCARD_SYNTH_SECONDS $tsynth"
set lut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
set ram  [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set uram [llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]
puts "CINCARD_AREA lut=$lut ff=$ff dsp=$dsp ramb=$ram uram=$uram"
puts "CINCARD_DONE"
