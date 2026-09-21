# GENERATED from hw/fk33/fk33_i2cprobe.xdc by hw/fk33/gen_pcieep.py.
# The probe build's pin and clock constraints, with the x4 lane, the
# sysref and the debug-hub edits applied -- do not hand-edit.
# The GENSTAMP naming the environment that produced it is at the END
# of this file, so that adding an input cannot renumber these lines.
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
set_property PACKAGE_PIN BC26 [get_ports {sysref_clk_p[0]}]
set_property PACKAGE_PIN BC27 [get_ports {sysref_clk_n[0]}]
set_property IOSTANDARD LVDS [get_ports {sysref_clk_p[0]}]
set_property IOSTANDARD LVDS [get_ports {sysref_clk_n[0]}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {sysref_clk_p[0]}]
set_property DIFF_TERM_ADV TERM_100 [get_ports {sysref_clk_n[0]}]

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
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: create_pblock pblock_bd_i
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: add_cells_to_pblock [get_pblocks pblock_bd_i] [get_cells -quiet [list bd_i]]
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {SLICE_X219Y0:SLICE_X232Y239 SLICE_X0Y0:SLICE_X218Y50}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {DSP48E2_X31Y0:DSP48E2_X31Y89 DSP48E2_X0Y0:DSP48E2_X30Y13}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {LAGUNA_X30Y0:LAGUNA_X31Y119}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {RAMB18_X13Y0:RAMB18_X13Y95 RAMB18_X0Y0:RAMB18_X12Y19}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {RAMB36_X13Y0:RAMB36_X13Y47 RAMB36_X0Y0:RAMB36_X12Y9}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: resize_pblock [get_pblocks pblock_bd_i] -add {URAM288_X0Y0:URAM288_X4Y11}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: #resize_pblock [get_pblocks pblock_bd_i] -add {SLICE_X0Y0:SLICE_X232Y50}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: #resize_pblock [get_pblocks pblock_bd_i] -add {DSP48E2_X0Y0:DSP48E2_X31Y13}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: #resize_pblock [get_pblocks pblock_bd_i] -add {RAMB18_X0Y0:RAMB18_X13Y19}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: #resize_pblock [get_pblocks pblock_bd_i] -add {RAMB36_X0Y0:RAMB36_X13Y9}
# [gen_pcieep] REMOVED, see fk33_pblock.xdc: #resize_pblock [get_pblocks pblock_bd_i] -add {URAM288_X0Y0:URAM288_X4Y11}


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
# [gen_pcieep] superseded, see the aux domain below: set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
# [gen_pcieep] superseded, see the aux domain below: connect_debug_port dbg_hub/clk [get_nets bd_i/hbm/inst/TWO_STACK.u_hbm_top/APB_0_PCLK]

############ I2C PROBE (gen_i2cprobe.py) ############
set_property -dict {PACKAGE_PIN BB24 IOSTANDARD LVCMOS18} [get_ports {i2cprobe_tri_io[0]}] ;##was iic_scl
set_property -dict {PACKAGE_PIN BA24 IOSTANDARD LVCMOS18} [get_ports {i2cprobe_tri_io[1]}] ;##was iic_sda


###############################################################################
# FREE-RUNNING AUX DOMAIN (gen_pcieep.py) -- read rtl/fk33_aux.vhd first
###############################################################################
# The 200 MHz board oscillator on BC26/BC27.  In the EnablePCIe == 1 branch it
# is the ONLY clock in the design that does not stop when the PCIe link is
# down: xdma/axi_aclk stops, and clk_wiz_0 (hence hbm/APB_0_PCLK, hence the
# debug hub's old clock) is referenced to it AND held in reset by
# xdma/axi_aresetn.
#
# NOTHING BELOW MAY USE if/foreach/set.  See the note in gen_pcieep.py: the
# XDC reader silently skips such a block in both synthesis and implementation.
create_clock -period 5.000 -name sysref_clk [get_ports {sysref_clk_p[0]}]

# Every crossing into this domain is a SINGLE BIT through a two-stage
# ASYNC_REG synchroniser -- there is deliberately no multi-bit CDC in
# rtl/fk33_aux.vhd, and the reference-clock counter is reconstructed on this
# side from a divided single-bit toggle rather than transported.  That is why
# an asynchronous clock group is a complete constraint here and carries no
# bus-skew obligation.  A multi-bit crossing would need set_bus_skew and
# would NOT be allowed to rely on this line.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sysref_clk]

# The debug hub moves onto the aux clock.  A hub clocked off a stopped MMCM
# cannot answer either, so leaving it where upstream put it would make the
# whole aux domain unreadable in exactly the state it exists for.
#
# Addressed through the module's PIN, not through an internal net name: the
# cell name fk33_aux_0 and the port name aux_clk are both set by this
# generator, whereas the internal net name is whatever synthesis chooses (it
# is bd_i/fk33_aux_0_aux_clk today, and KEEP/DONT_TOUCH did not preserve the
# RTL name across the module's out-of-context run).  If either name ever
# changes, this errors instead of silently matching nothing.
set_property C_CLK_INPUT_FREQ_HZ 200000000 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets -of_objects [get_pins bd_i/fk33_aux_0/aux_clk]]

# pcie_perstn is a genuinely asynchronous input with no launching clock. It
# is deliberately left with no input delay, exactly as it already was for
# xdma/sys_rst_n, so it contributes no timed path; the receiving flip-flops
# in fk33_aux carry ASYNC_REG.

###############################################################################
# SUBSYSTEM A's CLOCK BOUNDARY (gen_pcieep.py)
###############################################################################
# The engine's core clock and its HBM AXI clock are DIFFERENT DOMAINS by
# design.  27 x 256 bits is 864 B exactly, so duty = f_core / f_axi with no
# efficiency term, and running both at one clock is 100% duty with zero
# margin -- rejected in docs/2026-08-28_can-27-read-masters-be-served.md 4.3.
# The crossing is a gray-pointer FIFO per port (rtl/async_fifo.vhd), one for
# each of the 28 masters, with a four-phase clear handshake.
#
# WHY THIS LINE IS NEEDED HERE AND WAS NOT NEEDED OUT OF CONTEXT.  In the
# OOC runs the two clocks were created independently and were unrelated by
# construction, and sim/ooc_fk33_a.tcl:143 declares them asynchronous
# anyway.  In this build clk_out3 is an MMCM output whose reference IS
# xdma/axi_aclk, so without this the tool would TIME every gray pointer and
# every clear-handshake bit against a 200/250 MHz common period and report
# failures on a crossing that is handled in RTL.
#
# It is addressed through the ENGINE'S OWN PINS, whose names this generator
# controls, rather than through an auto-generated clk_wiz clock name.  The
# impl-stage check in the build script FAILS THE BUILD if this matched
# nothing -- a set_clock_groups with an empty group is a warning, not an
# error, so an unchecked constraint here would be a silent no-op.
#
# NOTHING BELOW MAY USE if/foreach/set.
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins bd_i/eng/core_clk]] \
    -group [get_clocks -of_objects [get_pins bd_i/eng/hbm_aclk]]

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


# GENSTAMP -- the out-of-band inputs that produced THIS file, and
# the only record of them.  This generator's output DEPENDS on the
# values below: regenerating with different ones changes the
# CONFIGURATION, not the formatting, and the diff looks like
# ordinary drift.  Reproduce this exact file with
#     FK33_CARD=1 FK33_CB_STYLE=distributed FK33_ENG_CORE_MHZ=75 python3 hw/fk33/gen_pcieep.py
# inputs ((unset) means the generator's own default was taken):
#     env  FK33_CARD          = 1
#     env  FK33_CB_STYLE      = distributed
#     env  FK33_ENG           = (unset)
#     env  FK33_ENG_CORE_MHZ  = 75
#     env  FK33_ENG_FAST_MHZ  = (unset)
#     env  FK33_ENG_SPLIT_CLK = (unset)
#     env  FK33_FLATTEN       = (unset)
#     env  FK33_SYNTH_JOBS    = (unset)
#     env  FK33_SYNTH_THREADS = (unset)
