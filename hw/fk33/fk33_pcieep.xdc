# SQRL FK33 example project contraints

########### PCIe ##################################

# REFCLK
set_property PACKAGE_PIN AD8 [get_ports {pcie_refclk_clk_n[0]}]
set_property PACKAGE_PIN AD9 [get_ports {pcie_refclk_clk_p[0]}]
create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_clk_p]

# RESET
set_property -dict {PACKAGE_PIN BE24 IOSTANDARD LVCMOS18} [get_ports pcie_perstn]

# MGT
set_property PACKAGE_PIN AL2 [get_ports {pcie_rxp[0]}]
set_property PACKAGE_PIN AL1 [get_ports {pcie_rxn[0]}]
set_property PACKAGE_PIN  Y5 [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN  Y4 [get_ports {pcie_txn[0]}]
set_property PACKAGE_PIN AM4 [get_ports {pcie_rxp[1]}]
set_property PACKAGE_PIN AM3 [get_ports {pcie_rxn[1]}]
set_property PACKAGE_PIN AA7 [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN AA6 [get_ports {pcie_txn[1]}]
set_property PACKAGE_PIN AK4 [get_ports {pcie_rxp[2]}]
set_property PACKAGE_PIN AK3 [get_ports {pcie_rxn[2]}]
set_property PACKAGE_PIN AB5 [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN AB4 [get_ports {pcie_txn[2]}]
set_property PACKAGE_PIN AN2 [get_ports {pcie_rxp[3]}]
set_property PACKAGE_PIN AN1 [get_ports {pcie_rxn[3]}]
set_property PACKAGE_PIN AC7 [get_ports {pcie_txp[3]}]
set_property PACKAGE_PIN AC6 [get_ports {pcie_txn[3]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AP4 [get_ports {pcie_rxp[4]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AP3 [get_ports {pcie_rxn[4]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AD5 [get_ports {pcie_txp[4]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AD4 [get_ports {pcie_txn[4]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AR2 [get_ports {pcie_rxp[5]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AR1 [get_ports {pcie_rxn[5]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AF5 [get_ports {pcie_txp[5]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AF4 [get_ports {pcie_txn[5]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AT4 [get_ports {pcie_rxp[6]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AT3 [get_ports {pcie_rxn[6]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AE7 [get_ports {pcie_txp[6]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AE6 [get_ports {pcie_txn[6]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AU2 [get_ports {pcie_rxp[7]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AU1 [get_ports {pcie_rxn[7]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AH5 [get_ports {pcie_txp[7]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AH4 [get_ports {pcie_txn[7]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AV4 [get_ports {pcie_rxp[8]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AV3 [get_ports {pcie_rxn[8]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AG7 [get_ports {pcie_txp[8]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AG6 [get_ports {pcie_txn[8]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AW2 [get_ports {pcie_rxp[9]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AW1 [get_ports {pcie_rxn[9]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AJ7 [get_ports {pcie_txp[9]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AJ6 [get_ports {pcie_txn[9]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BA2 [get_ports {pcie_rxp[10]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BA1 [get_ports {pcie_rxn[10]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AL7 [get_ports {pcie_txp[10]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AL6 [get_ports {pcie_txn[10]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BC2 [get_ports {pcie_rxp[11]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BC1 [get_ports {pcie_rxn[11]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AM9 [get_ports {pcie_txp[11]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AM8 [get_ports {pcie_txn[11]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AY4 [get_ports {pcie_rxp[12]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AY3 [get_ports {pcie_rxn[12]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AN7 [get_ports {pcie_txp[12]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AN6 [get_ports {pcie_txn[12]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BB4 [get_ports {pcie_rxp[13]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BB3 [get_ports {pcie_rxn[13]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AP9 [get_ports {pcie_txp[13]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AP8 [get_ports {pcie_txn[13]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BD4 [get_ports {pcie_rxp[14]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BD3 [get_ports {pcie_rxn[14]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AR7 [get_ports {pcie_txp[14]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AR6 [get_ports {pcie_txn[14]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BE6 [get_ports {pcie_rxp[15]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN BE5 [get_ports {pcie_rxn[15]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AT9 [get_ports {pcie_txp[15]}]
# [gen_pcieep] x4 endpoint, lane not present: set_property PACKAGE_PIN AT8 [get_ports {pcie_txn[15]}]

# CLKREQ
set_property PACKAGE_PIN BE25 [get_ports {pcie_clkreq[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {pcie_clkreq[0]}]

########### End PCIe ##################################

########### System Clock ##############################
# [gen_pcieep] EnablePCIe=1, port not present: set_property PACKAGE_PIN BC26 [get_ports {sysref_clk_p[0]}]
# [gen_pcieep] EnablePCIe=1, port not present: set_property PACKAGE_PIN BC27 [get_ports {sysref_clk_n[0]}]
# [gen_pcieep] EnablePCIe=1, port not present: set_property IOSTANDARD LVDS [get_ports {sysref_clk_p[0]}]
# [gen_pcieep] EnablePCIe=1, port not present: set_property IOSTANDARD LVDS [get_ports {sysref_clk_n[0]}]
# [gen_pcieep] EnablePCIe=1, port not present: set_property DIFF_TERM_ADV TERM_100 [get_ports {sysref_clk_p[0]}]
# [gen_pcieep] EnablePCIe=1, port not present: set_property DIFF_TERM_ADV TERM_100 [get_ports {sysref_clk_n[0]}]

# DQS_BIAS only supported by DIFF_SSTL18
#set_property DQS_BIAS TRUE [get_ports hbm_ref_clk_p]
#set_property DQS_BIAS TRUE [get_ports hbm_ref_clk_n]
#set_property EQUALIZATION EQ_LEVEL0 [get_ports hbm_ref_clk_p]
#set_property EQUALIZATION EQ_LEVEL0 [get_ports hbm_ref_clk_n]

# Not needed for this design, since the block diagram instantiates the clock
#create_clock -period 5.000 -name hbm_clk [get_ports hbm_ref_clk_p]
########### End System Clock ##########################

############ LEDs ##################################
set_property -dict {PACKAGE_PIN BD25 IOSTANDARD LVCMOS18} [get_ports led[0]] ;##GREEN LED_A
set_property -dict {PACKAGE_PIN BE26 IOSTANDARD LVCMOS18} [get_ports led[1]] ;##GREEN LED_A
set_property -dict {PACKAGE_PIN BD23 IOSTANDARD LVCMOS18} [get_ports led[2]] ;##GREEN LED_A
set_property -dict {PACKAGE_PIN BF26 IOSTANDARD LVCMOS18} [get_ports led[3]] ;##GREEN LED_A
set_property -dict {PACKAGE_PIN BC25 IOSTANDARD LVCMOS18} [get_ports led[4]] ;##RGB LED_R
set_property -dict {PACKAGE_PIN BB26 IOSTANDARD LVCMOS18} [get_ports led[5]] ;##RGB LED_G
set_property -dict {PACKAGE_PIN BB25 IOSTANDARD LVCMOS18} [get_ports led[6]] ;##RGB LED_B

############# I2C-local (to PMIC) ##################
# [gen_i2cprobe] superseded, port removed: set_property -dict {PACKAGE_PIN BB24 IOSTANDARD LVCMOS18} [get_ports iic_scl_io]
# [gen_i2cprobe] superseded, port removed: set_property -dict {PACKAGE_PIN BA24 IOSTANDARD LVCMOS18} [get_ports iic_sda_io]

###############################################################################
# Additional design / project settings
###############################################################################
# High-speed configuration so FPGA is up in time to negotiate with PCIe root complex
# Available rates: 2.7, 5.3, 8.0, 10.6, 21.3, 31.9, 36.4, 51.0, 56.7, 63.8, 72.9, 85.0, 102.0, 127.5, 170.0
# Should be able to push to 140 (flash part accepts 166; 15% tolerance on internal osc), so 127 really
set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]
#set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN Div-1 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]


###############################################################################
# PBlocks
###############################################################################
create_pblock pblock_bd_i
add_cells_to_pblock [get_pblocks pblock_bd_i] [get_cells -quiet [list bd_i]]
resize_pblock [get_pblocks pblock_bd_i] -add {SLICE_X219Y0:SLICE_X232Y239 SLICE_X0Y0:SLICE_X218Y50}
resize_pblock [get_pblocks pblock_bd_i] -add {DSP48E2_X31Y0:DSP48E2_X31Y89 DSP48E2_X0Y0:DSP48E2_X30Y13}
resize_pblock [get_pblocks pblock_bd_i] -add {LAGUNA_X30Y0:LAGUNA_X31Y119}
resize_pblock [get_pblocks pblock_bd_i] -add {RAMB18_X13Y0:RAMB18_X13Y95 RAMB18_X0Y0:RAMB18_X12Y19}
resize_pblock [get_pblocks pblock_bd_i] -add {RAMB36_X13Y0:RAMB36_X13Y47 RAMB36_X0Y0:RAMB36_X12Y9}
resize_pblock [get_pblocks pblock_bd_i] -add {URAM288_X0Y0:URAM288_X4Y11}
#resize_pblock [get_pblocks pblock_bd_i] -add {SLICE_X0Y0:SLICE_X232Y50}
#resize_pblock [get_pblocks pblock_bd_i] -add {DSP48E2_X0Y0:DSP48E2_X31Y13}
#resize_pblock [get_pblocks pblock_bd_i] -add {RAMB18_X0Y0:RAMB18_X13Y19}
#resize_pblock [get_pblocks pblock_bd_i] -add {RAMB36_X0Y0:RAMB36_X13Y9}
#resize_pblock [get_pblocks pblock_bd_i] -add {URAM288_X0Y0:URAM288_X4Y11}


###############################################################################
# Waivers & FalsePaths
###############################################################################
create_waiver -type CDC -id {CDC-1} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_apb_arbiter_1/apb_mux_sel_r_reg[0]/C}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/CE] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-1} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_apb_arbiter_1/apb_mux_sel_r_reg[0]/C}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/D] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-1} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/C}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_apb_arbiter_1/apb_mux_sel_r_reg*/*] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-4} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_hbm_temp_rd_1/temp_value_r_reg[*]/C}] -to [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_*/xsdb2adb_u0/hbm_temp_r_reg[*]/D}] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-13} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_0/xsdb2adb_u0/*/C}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_two_stack_intf/HBM_ONE_STACK_INTF<1>_INST/HBM_SNGLBLI_INTF_APB_INST/*] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-13} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_two_stack_intf/HBM_ONE_STACK_INTF<1>_INST/HBM_SNGLBLI_INTF_APB_INST/*}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/CE] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-13} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_two_stack_intf/HBM_ONE_STACK_INTF<1>_INST/HBM_SNGLBLI_INTF_APB_INST/*}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/D] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
create_waiver -type CDC -id {CDC-14} -user "Dima" -desc "This is a safe CDC in this design per review with team" -internal -from [get_pins {*/*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.u_xsdb_top_1/xsdb2adb_u0/*/C}] -to [get_pins */*/inst/TWO_STACK.u_hbm_top/TWO_STACK_HBM.hbm_two_stack_intf/HBM_ONE_STACK_INTF<1>_INST/HBM_SNGLBLI_INTF_APB_INST/*] -timestamp "Wed Aug 14 14:20:19 GMT 2019"
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]

############ I2C PROBE (gen_i2cprobe.py) ############
set_property -dict {PACKAGE_PIN BB24 IOSTANDARD LVCMOS18} [get_ports {i2cprobe_tri_io[0]}] ;##was iic_scl
set_property -dict {PACKAGE_PIN BA24 IOSTANDARD LVCMOS18} [get_ports {i2cprobe_tri_io[1]}] ;##was iic_sda


###############################################################################
# PCIe endpoint notes (gen_pcieep.py)
###############################################################################
# Lanes 0-3 are edge lanes 0-3, which are GTY quad 227 channels 3,2,1,0.
# Verified against Vivado's own package file:
#   AL2 = MGTYRXP3_227   AM4 = MGTYRXP2_227
#   AK4 = MGTYRXP1_227   AN2 = MGTYRXP0_227
#   AD9/AD8 = MGTREFCLK0P/N_226
# The lane order is reversed inside the quad, which is normal for a card-edge
# layout; PCIe link training negotiates lane reversal, so it needs no
# constraint here.  What DOES matter is that all four sit in one quad: that is
# what leaves quads 226/225/224 whole for Aurora.
#
# The refclk is in quad 226 and feeds the block in quad 227, so this design
# already depends on inter-quad reference clock routing.  If it builds, that
# routing works, which is one fewer unknown for the Aurora quads later.
#
# CONFIGRATE 127.5 and CONFIG_MODE SPIx4 are inherited from upstream and are
# there so a flash-booted FPGA is configured inside the ~100 ms PCIe gives it
# after PERST# deasserts.  They are irrelevant while configuring over JTAG.

