set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd rom_init_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd lmhead_rom_pkg.vhd mac_array.vhd lm_head.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter maxLoopLimit 4194304"
synth_design -mode out_of_context -top lm_head -part xczu3eg-sfvc784-1-e -generic DIM=64 -generic VOCAB=512
write_vhdl -mode funcsim -force post_lmhead_net.vhd
puts "FUNCSIM_WRITTEN"
