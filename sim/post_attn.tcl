set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd kv_mem.vhd softmax.vhd attention_ml.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top attention_ml -part xczu3eg-sfvc784-1-e -generic MAXPOS=24
write_vhdl -mode funcsim -force post_attn_net.vhd
puts "FUNCSIM_WRITTEN"
