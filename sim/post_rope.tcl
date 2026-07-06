set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd rope_rom_pkg.vhd rope.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top rope -part xczu3eg-sfvc784-1-e -generic DIM=64 -generic HEAD=8 -generic KVDIM=32
write_vhdl -mode funcsim -force post_rope_net.vhd
puts "FUNCSIM_WRITTEN"
