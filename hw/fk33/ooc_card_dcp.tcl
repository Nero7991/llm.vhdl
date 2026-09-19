# hw/fk33/ooc_card_dcp.tcl -- synthesise the `card` cell OUT OF CONTEXT to a
# checkpoint, so the top-level build never elaborates its RTL.
#
# WHY THIS EXISTS.  The whole design does not fit: MEASURED 2026-09-09,
# cardbuild11 (the real 9B geometry) reached 23.73 GB UNTHROTTLED with only
# 26.25 GB available on the box.  But the two HALVES each fit comfortably --
# the card alone was measured at 15.52 GB and a card-free pcieep build at
# 10.66 GB.  It is only their SUM that does not.  Splitting at the card
# boundary turns one job that does not fit into two that do.
#
# WHY THIS IS NOT THE THIRD REPEAT OF A REJECTED EXPERIMENT.
# docs/debugging/2026-09-08_card-ooc-synthesis-does-not-finish.md rejects
# exactly this command: two monolithic OOC syntheses of `fk33_card`, ~10 hours
# between them, NEITHER FINISHED.  Its rule is "do not launch a third without a
# reason to expect a different outcome."  The reason is `-flatten_hierarchy
# none`, which NEITHER rejected run had.
#
# That matters because the recorded failure was TIME, not memory: 6 h 34 m with
# no phase marker at a comfortable 15.52 GB peak and `high 0`.  Vivado's default
# is `rebuilt` -- flatten the WHOLE design, optimise across every boundary, then
# rebuild the hierarchy.  On a cell this size that is the pathology.  `none`
# keeps the boundaries so the optimiser never builds the single enormous flat
# netlist both runs were grinding on.
#
# THE COST IS REAL: `none` forbids cross-boundary optimisation, so the area and
# timing below are an UPPER BOUND on what the shipping flow would get, not a
# prediction of it.  A bitstream first; optimisation afterwards.
#
# CORRECTION 2026-09-13: "THE CARD ALONE WAS MEASURED AT 15.52 GB" IS WITHDRAWN.
# THE CARD HALF DOES NOT FIT COMFORTABLY; IT WANTS AT LEAST 39 GiB.
#
# MEASURED on the workstation, 47 h into this script's own run under
# `MemoryHigh=24G`, read from the job's OWN cgroup rather than from `free` or
# `ps`:
#
#   memory.current       24,352 MiB   (RAM)
#   memory.swap.current  15,664 MiB   (swap, SEPARATE from the above)
#   ------------------------------------------------------------------
#   total                40,016 MiB = 39.1 GiB
#
#   memory.events: high 7215, max 0, oom 0, oom_kill 0
#   memory.peak    24,433 MiB
#
# Two things follow, and the second is the reusable one.
#
# FIRST, 39.1 GiB is a LOWER BOUND, not the peak.  `memory.events high=7215`
# says the cap has been throttling this job continuously, and `memory.peak`
# 24,433 MiB is 143 MiB under `memory.high` -- so that peak is the THROTTLE
# holding it there, not the job's appetite.  This file may not quote 24.4 GiB as
# a footprint; it is the cap, exactly as the project rule about capped
# `memory.peak` figures says.
#
# SECOND, THE 15.52 GB WAS A SAMPLE OF A RUN THAT NEVER FINISHED.  It comes from
# docs/debugging/2026-09-08_card-ooc-synthesis-does-not-finish.md, whose whole
# subject is that NEITHER of two card OOC runs terminated.  A number taken from
# the middle of an unfinished job is a moment, and peak is a property of the JOB,
# not of the moment you looked.  Quoting it as "the card alone fits" turned an
# observation into a fit claim it could not support.
#
# So the premise "two halves that each fit" rests on one figure that is a
# mid-run sample and another (10.66 GB) that IS from a completed build.  Only
# the second is a peak.  Whether splitting at the card boundary actually helps
# is therefore OPEN, not established -- and the 39.1 GiB says the card half
# alone already exceeds the 26.25 GB that the unsplit build was faulted for
# needing.
set part xcvu33p-fsvh2104-2L-e
set out  [lindex $argv 0]
puts "CARDOOC_BEGIN part=$part out=$out flatten=none"

create_project -in_memory -part $part

# THE SOURCE LIST IS DERIVED FROM build_fk33_pcieep.tcl's OWN `add_files`
# lines, in order, not hand-maintained.  A hand-picked list of 50 was tried
# first and failed in 11 s with `package 'util_pkg' not found in library
# 'work'` -- CARD_SRCS is the card's OWN files and not its dependency closure,
# and the shared packages are added by a different block of the generator.
# Deriving it means this script cannot drift from the build.
#
# EVERYTHING IS READ AS VHDL 2008 HERE, including the two wrapper tops that the
# real build must keep at VHDL-93.  That constraint comes from the block-design
# packager ("a BD cell top may NOT be VHDL 2008"), and there is no block design
# in this flow.  Reading them as 2008 removes a rule that does not apply.
#
# Files unreachable from -top fk33_card are parsed and then ignored, so
# including subsystem A's sources costs parse time and nothing else.
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_aux.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_thermal.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/util_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/mv4i_arith_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4_desc_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/stream_fifo.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/async_fifo.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/axi_rd_fsm.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/axi_rd_port.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/weight_streamer.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/act_mem_striped.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_core.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/matvec_int4_desc_axi.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_engine.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_seam.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/bc_port_grant.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/a_desc_adapter.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/a_job_counter.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_emit.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_luts_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_gate.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_quant.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_mac_array.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/divider_rs.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_recip.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_rope.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_score_q12.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_softmax.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/imrope_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_twiddle.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/fixed_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_block.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/attn_kv_axi.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_head_emit.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_silu.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_y_emit.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_bf.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_emit_chain.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_capture.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_recur_pipe.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_scalar.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/l2norm_rs.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_block.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_job_seq.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv_tap_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_conv_w_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_exp_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_axi.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/gdn_state_store.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/model_cfg_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/llama_map_pkg.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/region_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/vec_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_rs_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/rmsnorm_bf_mem.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/sampler_stream.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/seq_desc_fetch.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/seq_opdec.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/seq_region_lock.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_issue.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/seq_vec_res.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/rtl/fk33_llama_top.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_bc_grant.vhd
read_vhdl -vhdl2008 /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_card.vhd

set t0 [clock seconds]
synth_design -mode out_of_context -top fk33_card -part $part -flatten_hierarchy none
set tsynth [expr {[clock seconds] - $t0}]
puts "CARDOOC_SYNTH_SECONDS $tsynth"

# The area of the REAL 9B card, which has never been measured -- every previous
# number was the 4-position stand-in.
# `REF_NAME =~ DSP*` OVER-COUNTS BY EXACTLY 9x AND THE RESULT LOOKS PLAUSIBLE.
#
# MEASURED 2026-09-16, the first full `fk33_card` synthesis: this line reported
# `dsp=4842` against 2,880 DSP48E2 on the part -- 168%, i.e. "the design does
# not fit" -- and the real figure is 538.  Vivado TRANSFORMS each DSP48E2 into
# itself PLUS EIGHT internal primitives, and the log says so outright:
#   DSP48E2 => DSP48E2 (DSP_ALU, DSP_A_B_DATA, DSP_C_DATA, DSP_MULTIPLIER,
#                       DSP_M_DATA, DSP_OUTPUT, DSP_PREADD, DSP_PREADD_DATA):
#                       538 instances
# All nine match `DSP*`, so 538 * 9 = 4842.
#
# THE OVER-COUNT IS DANGEROUS RATHER THAN MERELY WRONG: it reads as a hard fit
# failure on the one resource this design is most likely to run out of, and it
# would have been quoted as a blocker.  `REF_NAME == DSP48E2` is exact; the
# sub-cells have no independent existence and must not be counted.
#
# This is the same class as the recorded `PRIMITIVE_GROUP == DSP` trap, which
# matched NOTHING and printed a silent zero.  A census filter can be wrong in
# both directions, so anchor it to the primitive you actually mean and
# cross-check against the log's own `Report Cell Usage` table.
set lut  [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff   [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp  [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]
# RAMB36E2 is one tile, RAMB18E2 is half of one; they are reported separately
# so a caller can weight them rather than being handed a sum that means
# neither.  The part has 672 RAMB36 tiles.
set ram36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E2}]]
set ram18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E2}]]
set ram  [expr {$ram36 + $ram18}]
set uram [llength [get_cells -hier -filter {REF_NAME == URAM288}]]
puts "CARDOOC_AREA lut=$lut ff=$ff dsp=$dsp ramb=$ram ramb36=$ram36 ramb18=$ram18 uram=$uram"

write_checkpoint -force $out
puts "CARDOOC_WROTE $out"
