set rtldir [file normalize ../rtl]
foreach f {util_pkg.vhd fixed_luts_pkg.vhd fixed_pkg.vhd vec_mem.vhd swiglu.vhd bfp_pack.vhd} {
  read_vhdl -vhdl2008 [file join $rtldir $f]
}
read_vhdl -vhdl2008 sw_chain.vhd
synth_design -mode out_of_context -top sw_chain -part xczu3eg-sfvc784-1-e -generic N=172 -generic Q=12
write_vhdl -mode funcsim -force post_swchain_net.vhd
report_utilization -file util_swchain.rpt
puts "FUNCSIM_WRITTEN"
