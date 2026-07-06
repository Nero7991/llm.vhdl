set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd swiglu.vhd} { read_vhdl -vhdl2008 [file join $rtldir $f] }
synth_design -mode out_of_context -top swiglu -part xczu3eg-sfvc784-1-e -generic N=172 -generic Q=12
write_vhdl -mode funcsim -force post_swiglu_net.vhd
puts "FUNCSIM_WRITTEN"
