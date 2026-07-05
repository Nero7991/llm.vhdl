# OOC out-of-context synthesis fit check for rtl/llama_engine_axi.vhd
# (the AXI4-Lite wrapper + engine_shared) at the deployment MAXPOS=24/NGEN=24.
set part xczu3eg-sfvc784-1-e
set rtldir [file normalize ../rtl]

set files [list \
  util_pkg.vhd rom_init_pkg.vhd rms_weights_pkg.vhd wq_l0_rom_pkg.vhd \
  rope_rom_pkg.vhd lmhead_rom_pkg.vhd embed_rom_pkg.vhd fixed_luts_pkg.vhd \
  fixed_pkg.vhd mac_array.vhd kv_mem.vhd matmul_rt.vhd rmsnorm.vhd rope.vhd swiglu.vhd \
  embed.vhd lm_head.vhd sampler.vhd sampler_stream.vhd softmax.vhd attention_ml.vhd \
  residual.vhd bfp_pack.vhd \
  engine_shared.vhd llama_engine_axi.vhd ]

foreach f $files {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}

set_param synth.elaboration.rodinMoreOptions "rt::set_parameter maxLoopLimit 4194304"

synth_design -mode out_of_context -top llama_engine_axi -part $part \
  -generic MAXPOS=24 -generic NGEN=24

report_utilization -file util_llama_engine_axi.rpt
puts "==== llama_engine_axi OOC utilization ===="
report_utilization
puts "OOC_UTIL_DONE"
