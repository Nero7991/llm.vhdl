# LED + fan pins, from hw/jc/census/jc_census.xdc (known-good on the JCM35P).
set_property PACKAGE_PIN G9  [get_ports fan_ctl]
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
set_property IOSTANDARD LVCMOS18 [get_ports {fan_ctl LED_A LED_B LED_C LED_D}]
# CFGMCLK is ~50 MHz nominal; name it so timing has a clock on the fabric.
create_clock -name cfgmclk -period 20.000 [get_pins u_start/CFGMCLK]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
