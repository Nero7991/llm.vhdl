# Post-synth timing ESTIMATE for llama_engine_axi to size the PL clock before the
# (expensive) design_1 impl.  OOC synth + a clock constraint + report_timing gives
# the worst-slack path and thus achievable Fmax.  Period 20 ns (50 MHz) probe: if
# WNS is very negative, real min period = 20 - WNS.
set part xczu3eg-sfvc784-1-e
set rtldir [file normalize ../rtl]
set files [list \
  util_pkg.vhd rom_init_pkg.vhd rms_weights_pkg.vhd wq_l0_rom_pkg.vhd \
  rope_rom_pkg.vhd lmhead_rom_pkg.vhd embed_rom_pkg.vhd fixed_luts_pkg.vhd \
  fixed_pkg.vhd mac_array.vhd kv_mem.vhd matmul_rt.vhd rmsnorm.vhd rope.vhd swiglu.vhd \
  embed.vhd lm_head.vhd sampler.vhd sampler_stream.vhd softmax.vhd attention_ml.vhd \
  residual.vhd bfp_pack.vhd engine_shared.vhd llama_engine_axi.vhd ]
foreach f $files { read_vhdl -vhdl2008 [file join $rtldir $f] }
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter maxLoopLimit 4194304"
synth_design -mode out_of_context -top llama_engine_axi -part $part \
  -generic MAXPOS=24 -generic NGEN=24
create_clock -name aclk -period 20.000 [get_ports s_axi_aclk]
report_timing_summary -delay_type max -max_paths 3 -file util_timing.rpt
puts "==== WNS / critical path ===="
report_timing -delay_type max -max_paths 1
puts "TIMING_DONE"
