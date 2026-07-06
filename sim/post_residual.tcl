set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd residual.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top residual -part xczu3eg-sfvc784-1-e -generic N=64
write_vhdl -mode funcsim -force post_residual_net.vhd
puts "FUNCSIM_WRITTEN"
