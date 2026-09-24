# Idle vs gated core clock, build 18 routed DCP, 0.85 V (0.72 V crashes the power engine, see power.log).
open_checkpoint /home/orencollaco/pwr18/bd_wrapper_routed.dcp
set o /home/orencollaco/pwr18
set nets [get_nets -hier -filter {TYPE != GLOBAL_CLOCK}]
puts "PWR2_NETS [llength $nets]"
set_switching_activity -toggle_rate 0 -static_probability 0 $nets
puts "PWR2_STAGE idle_all_clocks"
report_power -verbose -file $o/p2_idle_all_clocks.rpt
# overwrite the core clock at 75 MHz / 250000 = 300 Hz: the gated core, clock tree effectively stopped
create_generated_clock -name clk_out3_bd_clk_wiz_0_0 -source [get_pins bd_i/clk_wiz_0/inst/mmcme4_adv_inst/CLKIN1] -edges {1 2 3} -edge_shift {0 1666666.7 3333333.3} [get_pins bd_i/clk_wiz_0/inst/mmcme4_adv_inst/CLKOUT2]
report_clocks -file $o/p2_clocks_gated.rpt
puts "PWR2_CLK3_PERIOD [get_property PERIOD [get_clocks clk_out3_bd_clk_wiz_0_0]]"
puts "PWR2_STAGE core_gated"
report_power -verbose -file $o/p2_core_gated.rpt
puts "PWR2_DONE"
