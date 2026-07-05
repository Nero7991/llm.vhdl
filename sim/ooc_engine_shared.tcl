# OOC out-of-context synthesis fit check for rtl/engine_shared.vhd.
# Reports CLB LUT / DSP / BRAM utilization on the XCZU3EG (AXU3EG part).
#
# MAXPOS/NGEN are reduced from the deployment 24 to 8 ONLY for the synthesis
# memory budget (vivado-mem.sh caps RAM; the MAXPOS=24 build peaked at ~24 GB
# and was killed under memory pressure).  The shared MAC (matmul_rt) is 1 DSP
# regardless of MAXPOS; attention_ml's unrolled score/weighted-sum multipliers
# and its KV-bank storage scale with MAXPOS, so this reports a representative
# (slightly smaller) attention footprint.
set part xczu3eg-sfvc784-1-e
set rtldir [file normalize ../rtl]

# Analysis order mirrors sim/Makefile: packages first, then leaf units, then
# attention_ml, then engine_shared.
# weights_pkg (the 227K-literal aggregate) is REPLACED here by rom_init_pkg
# (file-init BRAM loader) + rms_weights_pkg (small split-out RMS constants): the
# big weights now live in mem/rom/*.mem, loaded into BRAM by matmul_rt/embed/
# lm_head, so synthesis no longer constant-folds ~300K literals.
set files [list \
  util_pkg.vhd rom_init_pkg.vhd rms_weights_pkg.vhd wq_l0_rom_pkg.vhd \
  rope_rom_pkg.vhd lmhead_rom_pkg.vhd embed_rom_pkg.vhd fixed_luts_pkg.vhd \
  fixed_pkg.vhd mac_array.vhd kv_mem.vhd matmul_rt.vhd rmsnorm.vhd rope.vhd swiglu.vhd \
  embed.vhd lm_head.vhd sampler.vhd sampler_stream.vhd softmax.vhd attention_ml.vhd \
  residual.vhd bfp_pack.vhd \
  engine_shared.vhd ]

foreach f $files {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}

# The file-init loops in rom_init_pkg read up to 226560 lines; Vivado's default
# synthesis loop limit is 65536 -> [Synth 8-403].  Raise it.
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter maxLoopLimit 4194304"

synth_design -mode out_of_context -top engine_shared -part $part \
  -generic MAXPOS=8 -generic NGEN=8

report_utilization -file util_engine_shared.rpt
report_utilization -hierarchical -hierarchical_depth 2 \
  -file util_engine_shared_hier.rpt

puts "==== engine_shared OOC utilization ===="
report_utilization
puts "OOC_UTIL_DONE"
