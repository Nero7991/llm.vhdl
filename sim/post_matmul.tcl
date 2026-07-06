# Synthesize matmul_rt OOC and write a FUNCTIONAL-sim netlist (real RAMB/DSP
# UNISIM primitives with baked INIT), to run tb_matmul_rt against the SYNTHESIZED
# unit -- catches file-init-BRAM read/latency/mapping bugs that behavioral sim hides.
set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd rom_init_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd mac_array.vhd matmul_rt.vhd} {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}
set_param synth.elaboration.rodinMoreOptions "rt::set_parameter maxLoopLimit 4194304"
synth_design -mode out_of_context -top matmul_rt -part xczu3eg-sfvc784-1-e \
  -generic MAXROWS=172 -generic MAXCOLS=172
write_vhdl -mode funcsim -force post_matmul_rt_net.vhd
puts "FUNCSIM_WRITTEN"
