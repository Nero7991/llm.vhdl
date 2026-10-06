# hw/jc/loader/jc_loader.xdc -- pins and the board clock. The TCK, dna_clk and CDC
# constraints are NOT here: they live in jc_loader_timing.tcl, applied by
# build_loader.tcl to the opened synthesized design, where an object query that
# matches nothing stops the build (an XDC line that matches nothing is only a warning).
#
# Module oscillator: BC26/BC27, 200 MHz LVDS, bank 65 (docs/boards/jungle-cat/
# JCCL2-JCM35.xdc; N pin measured by hw/jc/pinfinder/query_pins.tcl).
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN BC27 [get_ports sysclk_clk_n]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
create_clock -name sysclk -period 5.000 [get_ports sysclk_clk_p]

# Fan and LEDs: the pins hw/jc/axiprobe/jc_axiprobe.xdc used on silicon.
set_property PACKAGE_PIN G9  [get_ports fan_ctl]
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
set_property IOSTANDARD LVCMOS18 [get_ports {fan_ctl LED_A LED_B LED_C LED_D}]
set_false_path -to [get_ports {fan_ctl LED_A LED_B LED_C LED_D}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
