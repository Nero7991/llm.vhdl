set rtldir [file normalize ../rtl]
read_vhdl -vhdl2008 [file join $rtldir sampler_stream.vhd]
synth_design -mode out_of_context -top sampler_stream -part xczu3eg-sfvc784-1-e -generic VOCAB=512
write_vhdl -mode funcsim -force post_sampler_net.vhd
puts "FUNCSIM_WRITTEN"
