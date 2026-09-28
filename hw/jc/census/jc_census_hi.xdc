# hw/jc/census/jc_census.xdc -- pins from docs/boards/jungle-cat/JCCL2-JCM35.xdc
# (vendor) and the refclk pins from a Vivado part query (pinq2, 2026-09-27).
# VARIANT (banks 127-131): refclk index i = quad 127 + i/2, MGTREFCLK(i mod 2).
set_property PACKAGE_PIN AB38 [get_ports {refclk_p[0]}]
set_property PACKAGE_PIN AA36 [get_ports {refclk_p[1]}]
set_property PACKAGE_PIN Y38 [get_ports {refclk_p[2]}]
set_property PACKAGE_PIN V38 [get_ports {refclk_p[3]}]
set_property PACKAGE_PIN U36 [get_ports {refclk_p[4]}]
set_property PACKAGE_PIN T38 [get_ports {refclk_p[5]}]
set_property PACKAGE_PIN R36 [get_ports {refclk_p[6]}]
set_property PACKAGE_PIN P38 [get_ports {refclk_p[7]}]
set_property PACKAGE_PIN N36 [get_ports {refclk_p[8]}]
set_property PACKAGE_PIN M38 [get_ports {refclk_p[9]}]

set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN G10  [get_ports sysclk_ext_clk_p]
set_property PACKAGE_PIN F13  [get_ports sysclk_ext2_clk_p]
set_property IOSTANDARD LVDS [get_ports {sysclk_clk_p sysclk_ext_clk_p sysclk_ext2_clk_p}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {sysclk_clk_p sysclk_ext_clk_p sysclk_ext2_clk_p}]
set_property DQS_BIAS TRUE [get_ports {sysclk_clk_p sysclk_ext_clk_p}]

set_property PACKAGE_PIN G9  [get_ports fan_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports fan_ctl]
set_property PACKAGE_PIN D13 [get_ports err_vccint]
set_property IOSTANDARD LVCMOS18 [get_ports err_vccint]
set_property PULLUP TRUE [get_ports err_vccint]
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
set_property IOSTANDARD LVCMOS18 [get_ports {LED_A LED_B LED_C LED_D}]

# Frequencies are what this bitstream measures, so these are generous bounds,
# not claims.  Every domain is asynchronous to every other.
# The XDC reader has no loops or ifs (a CRITICAL WARNING, and the clocks are
# silently absent), so the ten are written out.
create_clock -name ref0 -period 3.100 [get_ports {refclk_p[0]}]
create_clock -name ref1 -period 3.100 [get_ports {refclk_p[1]}]
create_clock -name ref2 -period 3.100 [get_ports {refclk_p[2]}]
create_clock -name ref3 -period 3.100 [get_ports {refclk_p[3]}]
create_clock -name ref4 -period 3.100 [get_ports {refclk_p[4]}]
create_clock -name ref5 -period 3.100 [get_ports {refclk_p[5]}]
create_clock -name ref6 -period 3.100 [get_ports {refclk_p[6]}]
create_clock -name ref7 -period 3.100 [get_ports {refclk_p[7]}]
create_clock -name ref8 -period 3.100 [get_ports {refclk_p[8]}]
create_clock -name ref9 -period 3.100 [get_ports {refclk_p[9]}]
create_clock -name sys0 -period 2.500 [get_ports sysclk_clk_p]
create_clock -name sys1 -period 2.500 [get_ports sysclk_ext_clk_p]
create_clock -name sys2 -period 2.500 [get_ports sysclk_ext2_clk_p]
create_clock -name cfgm -period 15.000 [get_pins u_start/CFGMCLK]
set_clock_groups -asynchronous -group ref0 -group ref1 -group ref2 -group ref3 \
  -group ref4 -group ref5 -group ref6 -group ref7 -group ref8 -group ref9 \
  -group sys0 -group sys1 -group sys2 -group cfgm
set_false_path -to [get_ports {LED_A LED_B LED_C LED_D fan_ctl}]
set_false_path -from [get_ports err_vccint]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
