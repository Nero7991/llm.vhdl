# hw/jc/a450/a450.xdc -- pins of the a450 A+HBM timing design: the module oscillator and
# one LED, exactly as hw/jc/loader/jc_loader.xdc places them.  Timing between clk_core and
# aclk_a is in a450_cdc.tcl, applied to the opened design (an XDC line that matches
# nothing is only a warning; the Tcl stops).
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN BC27 [get_ports sysclk_clk_n]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
create_clock -name sysclk -period 5.000 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN K10 [get_ports led]
set_property IOSTANDARD LVCMOS18 [get_ports led]
set_false_path -to [get_ports led]
