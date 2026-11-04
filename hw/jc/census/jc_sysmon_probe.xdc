# hw/jc/census/jc_sysmon_probe.xdc -- for jc_sysmon_probe.vhd (2026-11-03).
# SYSMON sites: MEASURED by get_sites/get_slrs (see the .vhd header), and the
# same LOCs the system_management_wiz generation wrote into its sm.xdc.
set_property LOC SYSMONE4_X0Y0 [get_cells u_sm0]   ;# SLR0, master
set_property LOC SYSMONE4_X0Y1 [get_cells u_sm1]   ;# SLR1, SSIT slave 0
set_property DONT_TOUCH true [get_cells {u_sm0 u_sm1}]

# Board pins copied from jc_qpll_census.xdc.
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

# CFGMCLK is nominally 50 MHz; 15 ns is the same generous bound jc_qpll_census uses.
create_clock -name cfgm -period 15.000 [get_pins u_start/CFGMCLK]
set_false_path -to [get_ports {LED_A LED_B LED_C LED_D fan_ctl}]
set_false_path -from [get_ports err_vccint]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
