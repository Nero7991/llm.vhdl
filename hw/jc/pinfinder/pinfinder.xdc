# hw/jc/pinfinder/pinfinder.xdc -- P pins from the vendor
# docs/boards/jungle-cat/JCCL2-JCM35.xdc. The N (diff-pair partner) pins
# below were MEASURED, not guessed, by hw/jc/pinfinder/query_pins.tcl
# (link_design -part xcvu35p-fsvh2104-2L-e; get_property DIFF_PAIR_PIN),
# run on the BC-250 2026-10-05, same convention as the refclk pins in
# hw/jc/census/jc_census.xdc:
#   BC26 -> BC27  bank 65
#   G10  -> F10   bank 67
#   F13  -> F12   bank 67
# (LED_A/B, LED_C/D and LED_RGB_R/LED_RGB_B/LED_RGB_G also turned out to be
# diff-pair partners of each other in bank 67; irrelevant here since they
# stay single-ended LVCMOS18 as in the vendor XDC.)

########### System Clock (onboard oscillator, input) ##################
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property PACKAGE_PIN BC27 [get_ports sysclk_clk_n]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
create_clock -name sysclk -period 5.000 [get_ports sysclk_clk_p]

########### G10 / sysclk_ext pair, repurposed as two single-ended outputs ###
set_property PACKAGE_PIN G10 [get_ports out_g10_p]
set_property PACKAGE_PIN F10 [get_ports out_g10_n]
set_property IOSTANDARD LVCMOS18 [get_ports {out_g10_p out_g10_n}]
set_property DRIVE 4 [get_ports {out_g10_p out_g10_n}]
set_property SLEW SLOW [get_ports {out_g10_p out_g10_n}]

########### F13 / sysclk_ext2 pair, repurposed as two single-ended outputs ##
set_property PACKAGE_PIN F13 [get_ports out_f13_p]
set_property PACKAGE_PIN F12 [get_ports out_f13_n]
set_property IOSTANDARD LVCMOS18 [get_ports {out_f13_p out_f13_n}]
set_property DRIVE 4 [get_ports {out_f13_p out_f13_n}]
set_property SLEW SLOW [get_ports {out_f13_p out_f13_n}]

########### LEDs ##################################
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
set_property PACKAGE_PIN K11 [get_ports LED_RGB_R]
set_property PACKAGE_PIN L12 [get_ports LED_RGB_G]
set_property PACKAGE_PIN L11 [get_ports LED_RGB_B]

set_property IOSTANDARD LVCMOS18 [get_ports {LED_A LED_B LED_C LED_D LED_RGB_R LED_RGB_G LED_RGB_B}]
set_property DRIVE 4 [get_ports {LED_A LED_B LED_C LED_D LED_RGB_R LED_RGB_G LED_RGB_B}]
set_property SLEW SLOW [get_ports {LED_A LED_B LED_C LED_D LED_RGB_R LED_RGB_G LED_RGB_B}]

########### Timing: every output is an asynchronous free-running square
########### wave with nothing downstream to meet setup/hold against.
set_false_path -to [get_ports {out_g10_p out_g10_n out_f13_p out_f13_n \
  LED_A LED_B LED_C LED_D LED_RGB_R LED_RGB_G LED_RGB_B}]

########### Bitstream config: vendor settings kept from the JCCL2-JCM35 XDC
set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
