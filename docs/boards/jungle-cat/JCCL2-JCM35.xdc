########### Aurora ####################################
# REFCLK
set_property PACKAGE_PIN AD38 [get_ports aur_ref_clk_p]

# MGT- don't need to set constraints- pinout is handled in the IP
########### End Aurora ################################

########### System Clock (onboard) ####################
set_property PACKAGE_PIN BC26 [get_ports sysclk_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_clk_p]
set_property DQS_BIAS TRUE [get_ports sysclk_clk_p]
########### End System Clock ##########################

########### System Clock (on carrier) #################
set_property PACKAGE_PIN G10 [get_ports sysclk_ext_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_ext_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_ext_clk_p] 
set_property DQS_BIAS TRUE [get_ports sysclk_ext_clk_p]
########### End System Clock ##########################

###################### Fan sense ######################         
set_property PACKAGE_PIN H9 [get_ports fan_sense]
set_property IOSTANDARD LVCMOS18 [get_ports fan_sense]
set_property PULLUP TRUE [get_ports fan_sense]
#######################################################

################### Fan PWM control ###################         
set_property PACKAGE_PIN G9 [get_ports fan_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports fan_ctl]
set_property PULLDOWN TRUE [get_ports fan_ctl]
#######################################################

######### System Clock 2 (on carrier) #########
set_property PACKAGE_PIN F13 [get_ports sysclk_ext2_clk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_ext2_clk_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports sysclk_ext2_clk_p] 
########### End System Clock ##########################

### GPIO chained across all modules to BMC ###
# Recommend set as open drain on BMC
set_property PACKAGE_PIN H12 [get_ports jcm_sync]
set_property IOSTANDARD LVCMOS18 [get_ports jcm_sync]
set_property PULLUP TRUE [get_ports jcm_sync]
#######################################################

# Input from PMIC when overtemp or overcurrent (A3 only)
# Open collector on PMIC side, so pullup is needed
set_property PACKAGE_PIN D13 [get_ports err_vccint]
set_property IOSTANDARD LVCMOS18 [get_ports err_vccint]
set_property PULLUP TRUE [get_ports err_vccint]
#######################################################

############## UART to BMC ############################
set_property PACKAGE_PIN E10 [get_ports uart_rx]
set_property PACKAGE_PIN E11 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS18 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rx]


         
########### LEDs ##################################
set_property PACKAGE_PIN K10 [get_ports LED_A]
set_property PACKAGE_PIN K9  [get_ports LED_B]
set_property PACKAGE_PIN J9  [get_ports LED_C]
set_property PACKAGE_PIN J10 [get_ports LED_D]
		    
set_property PACKAGE_PIN K11 [get_ports LED_RGB_R]
set_property PACKAGE_PIN L12 [get_ports LED_RGB_G]
set_property PACKAGE_PIN L11 [get_ports LED_RGB_B]

set_property IOSTANDARD LVCMOS18 [get_ports LED_A]    
set_property IOSTANDARD LVCMOS18 [get_ports LED_B]    
set_property IOSTANDARD LVCMOS18 [get_ports LED_C]    
set_property IOSTANDARD LVCMOS18 [get_ports LED_D]    
						      
set_property IOSTANDARD LVCMOS18 [get_ports LED_RGB_R]
set_property IOSTANDARD LVCMOS18 [get_ports LED_RGB_G]
set_property IOSTANDARD LVCMOS18 [get_ports LED_RGB_B]

############ I2C-local (to PMIC) ##################
set_property PACKAGE_PIN E9 [get_ports IIC_scl_io]
set_property PACKAGE_PIN F9 [get_ports IIC_sda_io]
set_property IOSTANDARD LVCMOS18 [get_ports IIC_scl_io] 
set_property IOSTANDARD LVCMOS18 [get_ports IIC_sda_io]
 
################# I2C-Global ######################
set_property PACKAGE_PIN B9  [get_ports GIIC_scl_io]
set_property PACKAGE_PIN B10 [get_ports GIIC_sda_io]
set_property IOSTANDARD LVCMOS18 [get_ports GIIC_scl_io] 
set_property IOSTANDARD LVCMOS18 [get_ports GIIC_sda_io]

###############################################################################
# Secondary SPI flash
###############################################################################
set_property PACKAGE_PIN AV28 [get_ports {SPI_1_io0_io}]
set_property PACKAGE_PIN AW28 [get_ports {SPI_1_io1_io}]
set_property PACKAGE_PIN BB28 [get_ports {SPI_1_io2_io}]
set_property PACKAGE_PIN BC28 [get_ports {SPI_1_io3_io}]
set_property PACKAGE_PIN AW24 [get_ports {SPI_1_ss_io}]

set_property IOSTANDARD LVCMOS18 [get_ports {SPI_1_io0_io}]
set_property IOSTANDARD LVCMOS18 [get_ports {SPI_1_io1_io}]
set_property IOSTANDARD LVCMOS18 [get_ports {SPI_1_io2_io}]
set_property IOSTANDARD LVCMOS18 [get_ports {SPI_1_io3_io}]
set_property IOSTANDARD LVCMOS18 [get_ports {SPI_1_ss_io}]


 
###############################################################################
# Additional design / project settings
###############################################################################

# High-speed configuration so FPGA is up in time to negotiate with PCIe root complex
# Available rates: 2.7, 5.3, 8.0, 10.6, 21.3, 31.9, 36.4, 51.0, 56.7, 63.8, 72.9, 85.0, 102.0, 127.5, 170.0
# Should be able to push to 140 (flash part accepts 166; 15% tolerance on internal osc), so 127 really
set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
