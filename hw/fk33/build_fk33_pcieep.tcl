# GENERATED from hw/fk33/build_fk33_i2cprobe.tcl by hw/fk33/gen_pcieep.py
# -- do not hand-edit; regenerate so the probe build's fixes are not lost.
#
# PCIe Gen3 x4 XDMA endpoint for the FK33.  The first bitstream in this project
# with a PCIe endpoint at all.
#
# What the host sees when this works:
#   BAR (XDMA config)     the DMA engine's own registers
#   BAR (AXI-Lite, 128K)  0x3400  SYSMON die temperature
#                         0x3404  SYSMON VCCINT
#                         0x9000  GPIO ch1 DATA  bit0=SCL(BB24) bit1=SDA(BA24)
#                         0x9004  GPIO ch1 TRI   1 = released, 0 = driven low
#                         0x9008  GPIO ch2 DATA  the 7 board LEDs, via led_inv
#                         0xA000  ID magic       READ-ONLY, always 0x464B3333
#                         0xA008  ID build date  READ-ONLY, 0x20260827 (BCD)
#                         0x10000 scratch RAM    8 KB, read/write, drives nothing
#   /dev/xdma0_h2c_0      writes into HBM, file offset == HBM byte address
#   /dev/xdma0_c2h_0      reads  from HBM, same addressing
#     0x0_0000_0000 .. 0x1_FFFF_FFFF   HBM, 8 GB
#     0x2_0000_0000 .. 0x2_0000_FFFF   64 KB BRAM, the DMA loopback target
#
# The identity register is the one read that distinguishes "the whole path
# works" from "a driver loaded".  0x00000000 and 0xFFFFFFFF are what a BAR that
# is mapped but unanswered returns, and neither can be mistaken for "FK33".
#
# HBM is flat and contiguous from the DMA master: 0x0_0000_0000 .. 0x1_FFFF_FFFF,
# 8 GB, MEM00-15 through SAXI_00 and MEM16-31 through SAXI_16, with the
# redundant cross-stack routes excluded so there is exactly one path to each.
#
# WATCH OUT -- the whole AXI fabric above is clocked by xdma/axi_aclk, which is
# derived from the PCIe reference clock, and held in reset until the link is
# up.  On the bench, with no slot, there is no reference clock, so all of it is
# EXPECTED to look completely dead over JTAG.  That is not a broken build.
#
# THE AUX DOMAIN IS THE EXCEPTION, and the reason this build exists in its
# current form.  It runs on the FK33's 200 MHz board oscillator (BC26/BC27)
# through a plain BUFG -- no MMCM, nothing to lock, nothing anyone can hold in
# reset -- and is readable over a THIRD JTAG-AXI master, jtag_aux, whose entire
# branch is on that clock.  There is no wire at all between it and xdma:
#
#   jtag_aux (its own address space, JTAG only, never on the PCIe BAR)
#     0x0000  AUX_MAGIC     0x41555831 = "AUX1"
#     0x0008  AUX_VERSION   0x20260828
#     0x1000  UCLK_TICKS    free-running; 1 tick per 128 xdma/axi_aclk cycles
#     0x1008  UCLK_HZ       measured xdma/axi_aclk in Hz.  250000000 = the PCIe
#                           hard block is clocked, so a down link is a TRAINING
#                           failure.  0 with PERST# HIGH means the host is not
#                           driving a reference clock.  0 with PERST# LOW just
#                           means we are held in reset
#     0x2000  AUX_STATUS    [0] PERST# level     [1] PERST# level at config
#                           [2] PERST# ever low  [3] PERST# ever high
#                           [7:4] PERST# deassertion count, saturating at 15
#                           [8] xdma axi_aresetn [9] axi_aresetn ever released
#                           [10] user_lnk_up     [11] user_lnk_up ever
#                           [12] uclk alive      [13] uclk ever ticked
#                           [14] PERST_MS valid  [15] aux reset released
#                           [31:16] 0xA5A5, fixed
#     0x2008  POT_STATUS    [0] done  [1] failed  [2] bus owned  [3] saw a NACK
#                           [5:4] transaction  [10:8] failure reason
#                           [15:12] attempts    [23:16] wiper last read back
#                           [31:24] the ONLY wiper this bitstream can write.
#                                   It must read 0x44 (68 = 0.717 V).
#     0x3000  AUX_MS        milliseconds since configuration
#     0x3008  PERST_MS      AUX_MS at the FIRST deassertion of PERST#
#
# PERST_MS is the flash-boot timing measurement.  AUX_STATUS[1] = 0 with
# PERST_MS valid means the FPGA was configured and watching BEFORE the host
# released reset.  AUX_STATUS[1] = 1 means reset had already been released when
# configuration finished, which is the loss condition and today is
# indistinguishable from a card that never worked.
#
# The aux domain also raises VCCINT on its own, with no host and no JTAG, a few
# milliseconds after configuration.  See rtl/fk33_aux.vhd.
#
# THERMAL PROTECTION.  rtl/fk33_thermal.vhd, also on the aux domain, halts the
# compute datapath at die 90 C / HBM code 85 and resumes at 75 / 70.  It halts
# ARITHMETIC ONLY: the link, the AXI fabric, the aux domain and every register
# below stay alive, because a card that vanishes when it overheats cannot be
# asked what happened.  SYSMON's own over-temperature alarm is armed at 101 C
# and is a die-destruction backstop, not management -- above the -2LE sustained
# rating of 100 C, silent about the HBM stacks' 95 C recommendation, and its
# consequence is a device shutdown.  The same five words appear twice:
#
#   jtag_aux (link down)          AXI-Lite BAR (host)
#     0x4000 THERM_STATUS           0xB000 THERM_STATUS
#     0x4008 THERM_TEMPS            0xB008 THERM_TEMPS
#     0x5000 THERM_PEAK             0xC000 THERM_PEAK
#     0x5008 THERM_TRIP             0xC008 THERM_TRIP
#     0x6000 THERM_CTL   (write)    0xD000 THERM_CTL   (write)
#     0x6008 THERM_CANARY           0xD008 THERM_CANARY
#
# THERM_STATUS[31] is a fabric constant 1, so a bitstream WITHOUT the guard
# reads 0 there and "is this card protected" is one read.  THERM_CTL needs the
# key 0xC1EA in [31:16]; [0] clears the trip latch, [1] clears the peak-hold,
# both edge triggered, and neither releases a halt the live sensors justify.
#
# GENERATED from build_fk33_firstlight.tcl by hw/fk33/gen_i2cprobe.py
# -- do not hand-edit; regenerate.
#
# I2C PROBE bitstream.  Identical to first light except that axi_iic is replaced
# by a dual-channel axi_gpio, giving raw control of the two I2C balls:
#
#   0x9000  GPIO_DATA   channel 1, bit0 = BB24 (scl), bit1 = BA24 (sda)
#   0x9004  GPIO_TRI    channel 1, 1 = input/released, 0 = driven.  Resets to
#                       all-ones, so this bitstream drives NOTHING until asked.
#   0x9008  GPIO2_DATA  channel 2, the 7 board LEDs (via led_inv, active low)
#   0x900c  GPIO2_TRI   unused, channel 2 is all-outputs
#
# The question it exists to answer: with both pins released, do they read HIGH?
# HIGH means a powered pull-up, so that bus is real and the devices are simply
# elsewhere.  LOW or indeterminate means those balls are not a live I2C bus on
# this board, and SQRL's 0x2C/0x18/0x19/0x1F addresses never applied to it.
#
# GENERATED from SQRL_FK33/projects/fk33_example.tcl by hw/fk33/gen_firstlight.py
# -- do not hand-edit; regenerate so upstream fixes are not lost.
#
# FIRST-LIGHT bitstream for the FK33: JTAG only, no PCIe.
# Four changes from upstream, each of which would otherwise stop the build or
# produce the wrong artifact:
#
#  1. EnablePCIe 0.  docs/fpga-hardware-recon.md establishes that both planned
#     experiments are reachable over JTAG alone, so first light needs nothing
#     resolved about PCIe, ACS or P2P.  Fewer moving parts on the first power-on.
#
#  2. The Vivado version gate is removed.  Upstream hard-errors unless the tool
#     is exactly 2022.2; this install is 2023.2 and installing a second Vivado
#     is ~100 GB.  This is the risky change: block designs carry IP versions, so
#     an explicit upgrade_ip pass is added below and its output must be read,
#     not assumed.
#
#  3. Part forced to xcvu33p-fsvh2104-2L-e, NOT the -2-e upstream hardcodes.
#     Upstream contradicts its own board file, which says -2L
#     (board_files/sqrl_fk33/1.1/board.xml).  -2 is the FASTER grade, so
#     building for it and deploying on -2L silicon signs timing off against
#     hardware we do not have.  -2L is the conservative direction.  Settle it
#     empirically once the card is in: Vivado hardware manager reports the real
#     part from the IDCODE, and if it is genuinely -2 this can be relaxed for
#     free headroom.
#
#  4. Upstream never builds anything -- it creates the project and stops.
#     Synthesis, implementation and write_bitstream are appended.
#

set ProjectName fk33_pcieep
set ProjectFolder ./$ProjectName

set EnablePCIe 1
set HBMGlobalSwitch 1

#Remove unnecessary files.
set file_list [glob -nocomplain webtalk*.*]
foreach name $file_list {
    file delete $name
}

#Delete old project if folder already exists.
if {[file exists .Xil]} { 
    file delete -force .Xil
}

#Delete old project if folder already exists.
if {[file exists "$ProjectFolder"]} { 
    file delete -force $ProjectFolder
}

# paths pinned to the upstream checkout -- see header note 7
set scriptPath "/home/orencollaco/GitHub/SQRL_FK33/projects"
set sourceRoot "/home/orencollaco/GitHub/SQRL_FK33"
#puts stdout $scriptPath
#puts stdout [join [lrange [file split [file dirname [info script]]] 0 end-2] "/"]
#return -code 1

# version gate removed -- see header note 2
puts "INFO: building with Vivado [version -short] (upstream targets 2022.2)"

create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"

# ---- aux RTL (gen_pcieep.py) ----------------------------------------------
# Added before the block design so `create_bd_cell -type module -reference
# fk33_aux` can find it.  Absolute path because the build runs in a scratch
# directory, not here.
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_aux.vhd
add_files -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/rtl/fk33_thermal.vhd
update_compile_order -fileset sources_1

#create_project $ProjectName ./$ProjectName -part xcvu33p-fsvh2104-2-e-es1

set_param synth.maxThreads 8
set_param general.maxThreads 12


# injected by gen_firstlight.py -- see header note 6
proc exclude_seg_if {seg space} {
    set sp [get_bd_addr_spaces -quiet $space]
    if {[llength $sp] == 0} {
        return
    }
    set sg [get_bd_addr_segs -quiet $seg]
    if {[llength $sg] == 0} {
        return
    }
    exclude_bd_addr_seg $sg -target_address_space $sp
}

create_bd_design "bd"

create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_1 {200}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {250} ] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {250}] [get_bd_cells hbm]

if {$HBMGlobalSwitch == 0} {
    set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {FALSE} CONFIG.USER_SWITCH_ENABLE_01 {FALSE}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MEMORY_DISPLAY {4608} CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_MC_ENABLE_01 {FALSE} CONFIG.USER_MC_ENABLE_02 {FALSE} CONFIG.USER_MC_ENABLE_03 {FALSE} CONFIG.USER_MC_ENABLE_04 {FALSE} CONFIG.USER_MC_ENABLE_05 {FALSE} CONFIG.USER_MC_ENABLE_06 {FALSE} CONFIG.USER_MC_ENABLE_07 {FALSE} CONFIG.USER_SAXI_01 {false}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MEMORY_DISPLAY {1024} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} CONFIG.USER_MC_ENABLE_09 {FALSE} CONFIG.USER_MC_ENABLE_10 {FALSE} CONFIG.USER_MC_ENABLE_11 {FALSE} CONFIG.USER_MC_ENABLE_12 {FALSE} CONFIG.USER_MC_ENABLE_13 {FALSE} CONFIG.USER_MC_ENABLE_14 {FALSE} CONFIG.USER_MC_ENABLE_15 {FALSE} CONFIG.USER_SAXI_01 {false} CONFIG.USER_SAXI_17 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]
} else {
    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_SAXI_01 {false} CONFIG.USER_SAXI_02 {false} CONFIG.USER_SAXI_03 {false} CONFIG.USER_SAXI_04 {false} CONFIG.USER_SAXI_05 {false} CONFIG.USER_SAXI_06 {false} CONFIG.USER_SAXI_07 {false} CONFIG.USER_SAXI_08 {false} CONFIG.USER_SAXI_09 {false} CONFIG.USER_SAXI_10 {false} CONFIG.USER_SAXI_11 {false} CONFIG.USER_SAXI_12 {false} CONFIG.USER_SAXI_13 {false} CONFIG.USER_SAXI_14 {false} CONFIG.USER_SAXI_15 {false}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} CONFIG.USER_SAXI_17 {false} CONFIG.USER_SAXI_18 {false} CONFIG.USER_SAXI_19 {false} CONFIG.USER_SAXI_20 {false} CONFIG.USER_SAXI_21 {false} CONFIG.USER_SAXI_22 {false} CONFIG.USER_SAXI_23 {false} CONFIG.USER_SAXI_24 {false} CONFIG.USER_SAXI_25 {false} CONFIG.USER_SAXI_26 {false} CONFIG.USER_SAXI_27 {false} CONFIG.USER_SAXI_28 {false} CONFIG.USER_SAXI_29 {false} CONFIG.USER_SAXI_30 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]
    set_property -dict [list CONFIG.USER_MC0_TRAFFIC_OPTION {Random} CONFIG.USER_MC1_TRAFFIC_OPTION {Random} CONFIG.USER_MC2_TRAFFIC_OPTION {Random} CONFIG.USER_MC3_TRAFFIC_OPTION {Random} CONFIG.USER_MC4_TRAFFIC_OPTION {Random} CONFIG.USER_MC5_TRAFFIC_OPTION {Random} CONFIG.USER_MC6_TRAFFIC_OPTION {Random} CONFIG.USER_MC7_TRAFFIC_OPTION {Random} CONFIG.USER_MC8_TRAFFIC_OPTION {Random} CONFIG.USER_MC9_TRAFFIC_OPTION {Random} CONFIG.USER_MC10_TRAFFIC_OPTION {Random} CONFIG.USER_MC11_TRAFFIC_OPTION {Random} CONFIG.USER_MC12_TRAFFIC_OPTION {Random} CONFIG.USER_MC13_TRAFFIC_OPTION {Random} CONFIG.USER_MC14_TRAFFIC_OPTION {Random} CONFIG.USER_MC15_TRAFFIC_OPTION {Random}] [get_bd_cells hbm]
}

set_property CONFIG.USER_APB_EN false [get_bd_cells hbm]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 hbm_reset

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property CONFIG.RESET_TYPE ACTIVE_LOW [get_bd_cells /clk_wiz_0]
set_property -dict [list CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}] [get_bd_cells clk_wiz_0]
set_property -dict [list CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]
                                                                                                     
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_hbm
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]
set_property -dict [list CONFIG.M_HAS_BURST {0}] [get_bd_cells jtag_hbm]

#Add AXI I2C to control voltages
# ---- I2C PROBE ------------------------------------------------------------
# axi_iic replaced by a dual-channel axi_gpio.  Channel 1 is two bidirectional
# bits on the I2C balls BB24 (scl) / BA24 (sda), released at reset:
# C_TRI_DEFAULT is all-ones so the pins come up as inputs and this bitstream
# cannot drive the board's bus until told to.  That matters -- if some other
# controller does own that bus, powering up driving it would be the one way to
# do real damage.  Channel 2 keeps the 7 LED bits so the board stays visibly
# controllable.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict [list CONFIG.C_GPIO_WIDTH {2} CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO2_WIDTH {7} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {0} \
    CONFIG.C_ALL_INPUTS_2 {0} CONFIG.C_ALL_OUTPUTS_2 {1} \
    CONFIG.C_TRI_DEFAULT {0xFFFFFFFF} CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_DOUT_DEFAULT_2 {0x00000040}] [get_bd_cells axi_gpio_0]
# [gen_pcieep] axi_gpio_0/GPIO is NOT made external here any more.  Its
# gpio_io_o / gpio_io_t / gpio_io_i now go into fk33_aux_0, which arbitrates
# between this GPIO and the autonomous VCCINT controller and instantiates the
# IOBUFs itself.  The external inout port is created there with the same name,
# i2cprobe_tri_io, so fk33_pcieep.xdc is unchanged for those two balls.

create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 led_inv
set_property -dict [list CONFIG.C_SIZE {7} CONFIG.C_OPERATION {not} CONFIG.LOGO_FILE {data/sym_notgate.png}] [get_bd_cells led_inv]
connect_bd_net [get_bd_pins led_inv/Op1] [get_bd_pins axi_gpio_0/gpio2_io_o]
make_bd_pins_external  [get_bd_pins led_inv/Res]
set_property name led [get_bd_ports Res_0]

#Add AXI interconnect IP
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 pcie2hbm
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]

connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins pcie2hbm/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/M00_AXI] [get_bd_intf_pins hbm/SAXI_00]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/M01_AXI] [get_bd_intf_pins hbm/SAXI_16]

connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/APB_0_PRESET_N]
connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/APB_1_PRESET_N]

connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins hbm_reset/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_1_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm_reset/slowest_sync_clk]
#connect_bd_net [get_bd_pins clk_wiz_0/clk_in1] [get_bd_pins util_ds_buf_1/IBUF_OUT]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_1]

#PCIe M_AXI_LITE
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 pcie2axil
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]

create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axil
connect_bd_intf_net [get_bd_intf_pins jtag_axil/M_AXI] [get_bd_intf_pins pcie2axil/S00_AXI]


#Add SystemManagement
create_bd_cell -type ip -vlnv xilinx.com:ip:system_management_wiz:1.3 system_management_wiz_0
set_property -dict [list CONFIG.USER_TEMP_ALARM {false} CONFIG.ENABLE_VBRAM_ALARM {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.TEMPERATURE_ALARM_OT_TRIGGER {101} CONFIG.TEMPERATURE_ALARM_OT_RESET {99}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.VCCINT_ALARM_LOWER {0.70} CONFIG.VCCINT_ALARM_UPPER {0.89}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.VCCAUX_ALARM_UPPER {1.85} CONFIG.VBRAM_ALARM_LOWER {0.82}] [get_bd_cells system_management_wiz_0] 
set_property -dict [list CONFIG.VBRAM_ALARM_UPPER {0.88} CONFIG.REFERENCE {External}] [get_bd_cells system_management_wiz_0]
# ---- THERMAL (gen_pcieep.py): see item 11 in the header --------------------
set_property -dict [list CONFIG.ENABLE_TEMP_BUS {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_TEMP_ALARM {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.TEMPERATURE_ALARM_TRIGGER {90} CONFIG.TEMPERATURE_ALARM_RESET {75}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY0_ALARM {true} CONFIG.USER_SUPPLY0_BANK {224} CONFIG.SELECT_USER_SUPPLY0 {AVCC}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY1_ALARM {true} CONFIG.USER_SUPPLY1_BANK {224} CONFIG.SELECT_USER_SUPPLY1 {MGTVCCAUX}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY2_ALARM {true} CONFIG.USER_SUPPLY2_BANK {224} CONFIG.SELECT_USER_SUPPLY2 {AVTT}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY3_ALARM {true} CONFIG.USER_SUPPLY3_BANK {64} CONFIG.SELECT_USER_SUPPLY3 {VCCO}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY0_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY0_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY1_ALARM_LOWER {1.79} CONFIG.USER_SUPPLY1_ALARM_UPPER {1.81}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY2_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY2_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_SUPPLY3_ALARM_LOWER {1.19} CONFIG.USER_SUPPLY3_ALARM_UPPER {1.21}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VUSER0 {true} CONFIG.CHANNEL_ENABLE_VUSER1 {true} CONFIG.CHANNEL_ENABLE_VUSER2 {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VP_VN {false} CONFIG.CHANNEL_ENABLE_VAUXP0_VAUXN0 {false} CONFIG.CHANNEL_ENABLE_VAUXP4_VAUXN4 {false}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP5_VAUXN5 {false} CONFIG.CHANNEL_ENABLE_VAUXP8_VAUXN8 {false} CONFIG.CHANNEL_ENABLE_VAUXP12_VAUXN12 {false}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP13_VAUXN13 {true} CONFIG.ANALOG_BANK_SELECTION {66} CONFIG.COMMON_N_VAUXP13_VAUXN13 {false} CONFIG.COMMON_N_SOURCE {Vaux13}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VP_VN {true} CONFIG.CHANNEL_ENABLE_VAUXP0_VAUXN0 {true} CONFIG.CHANNEL_ENABLE_VAUXP4_VAUXN4 {true} ] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.CHANNEL_ENABLE_VAUXP5_VAUXN5 {true} CONFIG.CHANNEL_ENABLE_VAUXP8_VAUXN8 {true} CONFIG.CHANNEL_ENABLE_VAUXP12_VAUXN12 {true}] [get_bd_cells system_management_wiz_0]

set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/M01_AXI] [get_bd_intf_pins system_management_wiz_0/S_AXI_LITE]

make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vp_Vn]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux0]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux4]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux5]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux8]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux12]
make_bd_intf_pins_external  [get_bd_intf_pins system_management_wiz_0/Vaux13]


set_property name Vp_Vn [get_bd_intf_ports Vp_Vn_0]
set_property name Vaux0 [get_bd_intf_ports Vaux0_0]
set_property name Vaux4 [get_bd_intf_ports Vaux4_0]
set_property name Vaux5 [get_bd_intf_ports Vaux5_0]
set_property name Vaux8 [get_bd_intf_ports Vaux8_0]
set_property name Vaux12 [get_bd_intf_ports Vaux12_0]
set_property name Vaux13 [get_bd_intf_ports Vaux13_0]


if {$EnablePCIe == 1} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma
    set_property -dict [list CONFIG.cfg_mgmt_if {false}] [get_bd_cells xdma]
    # x4 Gen3 = edge lanes 0-3 = GTY quad 227, verified against Vivado's own
    # xcvu33p_fsvh2104.pkg.  Quads 226/225/224 (edge lanes 4-15) stay free for
    # Aurora.  x1 and x2 would free no additional quad, so the width decision
    # cannot be deferred past this line.
    #
    # 128-bit AXI at 250 MHz = 4.0 GB/s, just over the 3.94 GB/s Gen3 x4 raw
    # payload ceiling, so the fabric is not the limit.  Do not raise it: a
    # wider M_AXI only adds smartconnect logic the link can never fill.
    set_property -dict [list CONFIG.pl_link_cap_max_link_width {X4} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axi_data_width {128_bit}] [get_bd_cells xdma]
    # One DMA channel each way.  The weight load is one direction and the token
    # path is bytes; more channels buy nothing here and each one is another
    # thing that can fail to be identified by the driver at probe time.
    set_property -dict [list CONFIG.xdma_rnum_chnl {1} CONFIG.xdma_wnum_chnl {1}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.pl_link_cap_max_link_width {X16} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} CONFIG.axi_data_width {512_bit}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.xdma_rnum_chnl {4} CONFIG.xdma_wnum_chnl {4}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.xdma_pcie_64bit_en {true} CONFIG.pf0_msix_cap_table_bir {BAR_1:0} CONFIG.pf0_msix_cap_pba_bir {BAR_1:0} CONFIG.xdma_pcie_prefetchable {true}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pcie_blk_locn {PCIE4C_X1Y0}] [get_bd_cells xdma]
    # Vendor/device ID overrides REMOVED.  SQRL sets 1E24:1533, which is not in
    # any stock XDMA driver's match table, so the driver would silently not
    # bind and the failure would look like a broken endpoint.  The IP's own
    # defaults are the IDs Xilinx's dma_ip_drivers table was generated from.
    # Whatever it picks, read it out of the build log and out of `lspci -nn`
    # before assuming the driver will bind -- see the host plan.
    puts "FK33_PCIE_IDS vendor=[get_property CONFIG.vendor_id [get_bd_cells xdma]] device=[get_property CONFIG.pf0_device_id [get_bd_cells xdma]]"
    set_property -dict [list CONFIG.pf0_revision_id {A3} CONFIG.pf0_subsystem_vendor_id {1E24} CONFIG.pf0_subsystem_id {0001}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pf0_Use_Class_Code_Lookup_Assistant {true} CONFIG.pf0_base_class_menu {Processing_accelerators} CONFIG.pf0_class_code_base {12} CONFIG.pf0_sub_class_interface_menu {Unknown} CONFIG.pf0_class_code_interface {00} CONFIG.pf0_class_code {120000}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axisten_freq {250}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.axilite_master_en {true} CONFIG.axilite_master_size {128} CONFIG.axilite_master_scale {Kilobytes} CONFIG.pf0_msix_cap_table_bir {BAR_3:2} CONFIG.pf0_msix_cap_pba_bir {BAR_3:2} CONFIG.axil_master_64bit_en {true} CONFIG.axil_master_prefetchable {true}] [get_bd_cells xdma]

    create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0
    set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells util_ds_buf_0]
       
    make_bd_intf_pins_external  [get_bd_intf_pins xdma/pcie_mgt]
    set_property name pcie [get_bd_intf_ports pcie_mgt_0]
    
    make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
    set_property name pcie_refclk [get_bd_intf_ports CLK_IN_D_0]
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_DS_ODIV2] [get_bd_pins xdma/sys_clk]
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins xdma/sys_clk_gt]
 
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins clk_wiz_0/clk_in1]
    
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0
    # CLKREQ# is ACTIVE LOW and it is the endpoint that asserts it to request
    # the reference clock.  Upstream leaves CONST_VAL at its default of 1, i.e.
    # deasserted.  Most desktop slots free-run the refclk and never look, but a
    # host that does honour it would gate the clock and the link would never
    # train -- with no symptom that separates it from a dead transceiver.
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells xlconstant_0]
    make_bd_pins_external  [get_bd_pins xlconstant_0/dout]
    set_property name pcie_clkreq [get_bd_ports dout_0]
    
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]
    connect_bd_intf_net [get_bd_intf_pins xdma/M_AXI] [get_bd_intf_pins pcie2hbm/S01_AXI]
    
    # NUM_MI is 2, not upstream's 1.  Upstream shrinks this smartconnect back to
    # one master AFTER system_management_wiz has already been connected to M01,
    # which deletes that port and orphans SYSMON.  The bug survives in SQRL's
    # script only because that script never synthesises -- it creates the
    # project and stops.  Left as 1, this build fails at address assignment.
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2axil]

    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/aresetn]
    
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/S00_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/S01_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M00_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M01_ACLK]
    #connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2hbm/M02_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins hbm/AXI_00_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins hbm/AXI_16_ACLK]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk]
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins jtag_hbm/aclk]
    
    
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/S00_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/S01_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M00_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M01_ARESETN]
    #connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2hbm/M02_ARESETN]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins jtag_hbm/aresetn]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_00_ARESET_N]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_16_ARESET_N]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm_reset/ext_reset_in]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]
    
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins pcie2axil/aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins pcie2axil/aresetn]
    connect_bd_intf_net [get_bd_intf_pins xdma/M_AXI_LITE] [get_bd_intf_pins pcie2axil/S01_AXI]
    
    connect_bd_net [get_bd_pins jtag_axil/aclk] [get_bd_pins xdma/axi_aclk]
    connect_bd_net [get_bd_pins jtag_axil/aresetn] [get_bd_pins xdma/axi_aresetn]
    
    connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins system_management_wiz_0/s_axi_aclk]
    connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins system_management_wiz_0/s_axi_aresetn]
    
    make_bd_pins_external  [get_bd_pins xdma/sys_rst_n]
    set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n_0]
    set_property name pcie_perstn [get_bd_ports sys_rst_n_0]

    # ---- LINK-UP LED ------------------------------------------------------
    # LED 6 shows the PCIe link state with no host, no JTAG and no instrument.
    # Needed because every other diagnostic in this design sits DOWNSTREAM of
    # the link: xdma drives axi_aclk/axi_aresetn for the whole fabric, so if
    # the link never comes up the JTAG-AXI masters are held in reset and their
    # reads hang -- indistinguishable from an unpowered card.
    #
    # led_inv is a 7-bit NOT, so LED 6 shows the INVERSE of user_lnk_up.  The
    # board's LED polarity is not documented anywhere, so do not predict which
    # way it goes: observe LED 6 with the link down and with it up, and take
    # the CHANGE as the signal.
    if {![info exists ::env(FK33_NO_LNKLED)]} {
        set lnk [get_bd_pins -quiet xdma/user_lnk_up]
        if {[llength $lnk] == 0} {
            puts "FK33_LNKLED SKIP: xdma/user_lnk_up not present on this IP version"
        } elseif {[catch {
            set n [get_bd_nets -quiet -of_objects [get_bd_pins led_inv/Op1]]
            if {[llength $n]} { delete_bd_objs $n }
            create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 gpo_lo
            set_property -dict [list CONFIG.DIN_WIDTH {7} CONFIG.DIN_FROM {5} \
                CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {6}] [get_bd_cells gpo_lo]
            create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 led_cat
            set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {6} \
                CONFIG.IN1_WIDTH {1}] [get_bd_cells led_cat]
            connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_o] [get_bd_pins gpo_lo/Din]
            connect_bd_net [get_bd_pins gpo_lo/Dout] [get_bd_pins led_cat/In0]
            connect_bd_net $lnk [get_bd_pins led_cat/In1]
            connect_bd_net [get_bd_pins led_cat/dout] [get_bd_pins led_inv/Op1]
            puts "FK33_LNKLED OK: LED 6 follows NOT(user_lnk_up)"
        } err]} {
            puts "FK33_LNKLED FAIL: $err"
            puts "FK33_LNKLED reverting to the original GPIO wiring"
            catch {delete_bd_objs [get_bd_cells -quiet {gpo_lo led_cat}]}
            connect_bd_net [get_bd_pins axi_gpio_0/gpio2_io_o] [get_bd_pins led_inv/Op1]
        }
    }

    
} else {
    
    create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1
    set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDS}] [get_bd_cells util_ds_buf_1]
    make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_1/CLK_IN_D]
    set_property name sysref [get_bd_intf_ports CLK_IN_D_0]
    set_property -dict [list CONFIG.FREQ_HZ {200000000}] [get_bd_intf_ports sysref]
    
    connect_bd_net [get_bd_pins util_ds_buf_1/IBUF_OUT] [get_bd_pins clk_wiz_0/clk_in1]
    set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_0]
    set_property -dict [list CONFIG.PRIM_IN_FREQ {200} CONFIG.CLKIN1_JITTER_PS {50.0} CONFIG.MMCM_CLKFBOUT_MULT_F {6.000} CONFIG.MMCM_CLKIN1_PERIOD {5.000} CONFIG.MMCM_CLKIN2_PERIOD {10.0} CONFIG.CLKOUT1_JITTER {106.024} CONFIG.CLKOUT1_PHASE_ERROR {82.655} CONFIG.CLKOUT2_JITTER {92.799} CONFIG.CLKOUT2_PHASE_ERROR {82.655}] [get_bd_cells clk_wiz_0]
    set_property -dict [list CONFIG.USE_RESET {false}] [get_bd_cells clk_wiz_0]
    
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2hbm/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2axil/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins jtag_hbm/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins jtag_axil/aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_gpio_0/s_axi_aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins system_management_wiz_0/s_axi_aclk]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_00_ACLK]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_16_ACLK]
    
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins system_management_wiz_0/s_axi_aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/AXI_00_ARESET_N]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/AXI_16_ARESET_N]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins pcie2hbm/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins pcie2axil/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins jtag_axil/aresetn]
    connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins jtag_hbm/aresetn]
    
    create_bd_port -dir I -type rst pcie_perstn
    connect_bd_net [get_bd_ports pcie_perstn] [get_bd_pins hbm_reset/ext_reset_in]
}





# ---- BRING-UP PERIPHERALS (gen_pcieep.py) ---------------------------------
# None of this is in SQRL's design.  It exists because the first time this card
# is in a slot there has to be something testable that is not the inference
# engine, and because each stage of the host path has to fail distinguishably
# from the next.  Without these three, the only host-visible things are SYSMON
# (read-only) and a GPIO wired to real board pins (unsafe to scribble on), and
# there is no DMA target at all except HBM -- which would make "the DMA engine
# is broken" and "HBM is broken" produce the same symptom.
#
#   fk33_id        READ-ONLY, driven from fabric constants, so no host write
#                  and no earlier test can change it.  Reading 0x464b3333
#                  ("FK33" in ASCII) proves, in one access, all of: the link
#                  trained, config space answered, the BIOS placed the BAR, the
#                  AXI-Lite master is clocked and out of reset, the smartconnect
#                  decodes, and the fabric holds THIS bitstream.  A driver that
#                  merely loaded cannot produce that value, and neither can a
#                  floating bus -- which reads as 0x00000000 or 0xFFFFFFFF.
#   fk33_scratch   true read/write BRAM on the same AXI-Lite BAR.  SYSMON is
#                  read-only and the GPIO drives board pins, so before this
#                  there was nowhere safe to prove that MMIO WRITES land.
#   fk33_dmabram   BRAM on the 128-bit DMA master.  A host write-then-read-back
#                  through here uses the same descriptor path, the same M_AXI
#                  and the same smartconnect as the weight load, with HBM taken
#                  out of the loop.
#
# Clocks and resets are joined onto the smartconnect nets rather than wired to
# a named source, because those nets come from xdma when EnablePCIe is 1 and
# from clk_wiz/hbm_reset when it is 0.  Joining keeps this block correct in
# both branches with no duplication.

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 id_magic
set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {1179333427}] [get_bd_cells id_magic]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 id_build
set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {539363367}] [get_bd_cells id_build]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_id
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_id]
connect_bd_net [get_bd_pins id_magic/dout] [get_bd_pins fk33_id/gpio_io_i]
connect_bd_net [get_bd_pins id_build/dout] [get_bd_pins fk33_id/gpio2_io_i]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_scratch
set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.ECC_TYPE {0}] [get_bd_cells fk33_scratch]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_scratch_ram
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM}] [get_bd_cells fk33_scratch_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_scratch/BRAM_PORTA] [get_bd_intf_pins fk33_scratch_ram/BRAM_PORTA]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_dmabram
set_property -dict [list CONFIG.DATA_WIDTH {128} CONFIG.SINGLE_PORT_BRAM {1} \
    CONFIG.ECC_TYPE {0}] [get_bd_cells fk33_dmabram]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_dmabram_ram
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM}] [get_bd_cells fk33_dmabram_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_dmabram/BRAM_PORTA] [get_bd_intf_pins fk33_dmabram_ram/BRAM_PORTA]

# Grow the two smartconnects rather than setting an absolute NUM_MI, so this
# stays correct if a later edit adds a master port before this point.  Growing
# is safe; SHRINKING deletes ports and silently orphans whatever was on them,
# which is exactly the upstream bug fixed above.
set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {$n + 2}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_id/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 1}]]] \
                    [get_bd_intf_pins fk33_scratch/S_AXI]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2hbm]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells pcie2hbm]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_dmabram/S_AXI]

connect_bd_net [get_bd_pins fk33_id/s_axi_aclk]         [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_id/s_axi_aresetn]      [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aclk]    [get_bd_pins pcie2hbm/aclk]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aresetn] [get_bd_pins pcie2hbm/aresetn]
# ---- end bring-up peripherals ---------------------------------------------


# ---- FREE-RUNNING AUX DOMAIN (gen_pcieep.py) ------------------------------
# Read the header of gen_pcieep.py, item 9, before changing anything here.  In
# short: in this bitstream the clock the debug hub uses is an MMCM output whose
# reference is xdma/axi_aclk and whose MMCM is held in reset by
# xdma/axi_aresetn, so NOTHING in the shipped design survives the link being
# down.  The 200 MHz oscillator on BC26/BC27 does, and is the only clock every
# EnablePCIe == 0 bitstream in this repository has ever run from.
if {$EnablePCIe != 1} {
    error "the aux block assumes EnablePCIe 1, and this generated script is only ever built that way"
}

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1
set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDS}] [get_bd_cells util_ds_buf_1]
make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_1/CLK_IN_D]
set_property name sysref [get_bd_intf_ports CLK_IN_D_0]
set_property -dict [list CONFIG.FREQ_HZ {200000000}] [get_bd_intf_ports sysref]

create_bd_cell -type module -reference fk33_aux fk33_aux_0
connect_bd_net [get_bd_pins util_ds_buf_1/IBUF_OUT] [get_bd_pins fk33_aux_0/clk_free_in]

# The PCIe USER clock, measured rather than used.  A direct measurement of the
# raw reference clock was built and REJECTED: it needs a second BUFG_GT on
# util_ds_buf_0/IBUF_DS_ODIV2, and DRC BFGTL-1 kills route_design because two
# BUFG_GTs sharing one GT clock source must have identical CE and CLR nets --
# xdma drives its own from an internal BUFG_GT_SYNC that is not exposed as a
# pin.  Do not retry that; see the debugging note.  axi_aclk plus the PERST#
# level answers the same question by elimination.
connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins fk33_aux_0/xdma_aclk]

# Both of these are already driven; joining a second load changes nothing about
# what xdma sees, and makes the two states the endpoint cannot currently report
# visible with the link down.
connect_bd_net [get_bd_ports pcie_perstn]       [get_bd_pins fk33_aux_0/perstn]
connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins fk33_aux_0/xdma_aresetn]

# LTSSM is deliberately absent.  xdma 4.1 exposes no LTSSM pin unless
# CONFIG.enable_ltssm_dbg or CONFIG.en_debug_ports is turned on, both of which
# change the IP configuration; user_lnk_up is a pin at the current settings and
# needs nothing.
set auxlnk [get_bd_pins -quiet xdma/user_lnk_up]
if {[llength $auxlnk]} {
    connect_bd_net $auxlnk [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up wired into the aux status word"
} else {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 aux_lnk_stub
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells aux_lnk_stub]
    connect_bd_net [get_bd_pins aux_lnk_stub/dout] [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up ABSENT on this IP version, status bit tied 0"
}

# The two I2C balls now go through the aux block, which arbitrates.  The GPIO
# owns them except while the autonomous controller is mid-transaction, and the
# controller hands them back the moment it finishes, so host/fk33ctl.py vccint
# and tcl/vccint_step.tcl keep working unchanged.  The external port keeps the
# name the XDC already constrains, so no pin constraint moves.
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins fk33_aux_0/gpio_o]
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_t] [get_bd_pins fk33_aux_0/gpio_t]
connect_bd_net [get_bd_pins fk33_aux_0/gpio_i]    [get_bd_pins axi_gpio_0/gpio_io_i]
make_bd_pins_external [get_bd_pins fk33_aux_0/i2c_io]
set_property name i2cprobe_tri_io [get_bd_ports i2c_io_0]

# The aux read path.  A THIRD JTAG-AXI master with its own smartconnect and its
# own slaves, every one of them clocked by fk33_aux_0/aux_clk.  It is not a
# branch off pcie2axil and it is not reachable from xdma: that is deliberate,
# and it is what makes "the read path does not touch xdma/axi_aclk" a property
# of the netlist rather than a claim about it.
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_aux
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32} \
    CONFIG.M_HAS_BURST {0}] [get_bd_cells jtag_aux]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 auxconnect
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins jtag_aux/M_AXI] [get_bd_intf_pins auxconnect/S00_AXI]

set auxi 0
foreach c {aux_id aux_clkst aux_stat aux_time aux_therm aux_peak} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $c
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
        CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
        CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells $c]
    connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $auxi]] \
                        [get_bd_intf_pins $c/S_AXI]
    connect_bd_net [get_bd_pins $c/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]
    connect_bd_net [get_bd_pins $c/s_axi_aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]
    incr auxi
}

connect_bd_net [get_bd_pins jtag_aux/aclk]      [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins jtag_aux/aresetn]   [get_bd_pins fk33_aux_0/aux_aresetn]
connect_bd_net [get_bd_pins auxconnect/aclk]    [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins auxconnect/aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]

connect_bd_net [get_bd_pins fk33_aux_0/stat_magic]    [get_bd_pins aux_id/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_version]  [get_bd_pins aux_id/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_uclkticks] [get_bd_pins aux_clkst/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_uclkhz]    [get_bd_pins aux_clkst/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_status]   [get_bd_pins aux_stat/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_pot]      [get_bd_pins aux_stat/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_ms]       [get_bd_pins aux_time/gpio_io_i]
connect_bd_net [get_bd_pins fk33_aux_0/stat_perstms]  [get_bd_pins aux_time/gpio2_io_i]
# ---- end free-running aux domain ------------------------------------------


# ---- THERMAL PROTECTION (gen_pcieep.py) -----------------------------------
# Read rtl/fk33_thermal.vhd before changing anything here.  In short: nothing in
# this design did ANY thermal management.  SYSMON was a register the host could
# read, the HBM stacks' own temperature and catastrophic-trip outputs were left
# dangling, and no comparison against a limit existed anywhere in the fabric.
#
# The silicon's own protection is a backstop, not management.  The SYSMONE4
# primitive accepts a write to the OT upper-limit register 53h only when the low
# nibble is 0011, which IS the automatic-shutdown enable, and
# system_management_wiz forces that nibble unconditionally -- so this design's
# OT shutdown is armed, at the 101 C SQRL programs.  DS890 Table 33 puts
# sustained Tj for -2LE at 100 C and recommends a maximum of 95 C for the HBM,
# so OT fires after the part is already out of spec, and its consequence is a
# shutdown that takes the card off the PCIe bus.  The guard below fires first,
# inside the datasheet, and halts ARITHMETIC ONLY.

create_bd_cell -type module -reference fk33_thermal fk33_therm_0

# The guard lives on the free-running aux domain, NOT on any PCIe-derived
# clock.  Both sensors are in PCIe-derived domains, so a guard clocked by
# either would lose the thermal record exactly when it is wanted -- after an OT
# shutdown, a host reset or a link drop -- and its staleness watchdogs could
# themselves go stale.
connect_bd_net [get_bd_pins fk33_aux_0/aux_clk]     [get_bd_pins fk33_therm_0/aux_clk]
connect_bd_net [get_bd_pins fk33_aux_0/aux_aresetn] [get_bd_pins fk33_therm_0/aux_aresetn]

# DIE.  system_management_wiz temp_out[9:0] needs CONFIG.ENABLE_TEMP_BUS, and
# user_temp_alarm_out needs CONFIG.USER_TEMP_ALARM -- upstream sets the latter
# FALSE, so both are re-set above and both are read back in the BD check.
# Vivado SILENTLY IGNORES a set_property on a CONFIG name that does not apply,
# so "we asked for it" is not evidence that it happened.
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/sysmon_clk]
connect_bd_net [get_bd_pins system_management_wiz_0/temp_out] \
               [get_bd_pins fk33_therm_0/sysmon_temp]
connect_bd_net [get_bd_pins system_management_wiz_0/ot_out] \
               [get_bd_pins fk33_therm_0/sysmon_ot]
connect_bd_net [get_bd_pins system_management_wiz_0/user_temp_alarm_out] \
               [get_bd_pins fk33_therm_0/sysmon_alarm]
# eoc_out is the LIVENESS source, and it is the reason a stuck ADC is caught.
# A value comparison alone cannot tell a frozen sensor from a cold card.
connect_bd_net [get_bd_pins system_management_wiz_0/eoc_out] \
               [get_bd_pins fk33_therm_0/sysmon_eoc]

# HBM.  These four pins EXIST on hbm_v1_0 with no reconfiguration:
# DRAM_0_STAT_TEMP/CATTRIP are unconditional and DRAM_1_* appear whenever
# USER_HBM_STACK is 2, which this design already sets.  The stock FK33 design
# simply leaves them dangling, so the stacks' own catastrophic-temperature
# signal has been asserting into the void.  hw/fk33/gen_hbmbw.py already wires
# the same four into rtl/hbm_tg.vhd; this is the same wiring in the endpoint.
#
# APB_0_PCLK is clk_wiz_0/clk_out1, the 100 MHz clock the IP's internal
# temperature reader runs on (TEMP_WAIT_PERIOD_0 = 100000 -> a refresh every
# ~1 ms).  It is the only liveness signal HBM offers: the reader's internal
# temp_valid_r is not brought out to a pin.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins fk33_therm_0/hbm_pclk]
connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp0]
connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_TEMP]    [get_bd_pins fk33_therm_0/hbm_temp1]
connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_CATTRIP] [get_bd_pins fk33_therm_0/hbm_cattrip0]
connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_CATTRIP] [get_bd_pins fk33_therm_0/hbm_cattrip1]

# The compute domain.  There is no compute datapath in this bitstream yet, so
# fk33_therm_0/compute_halt is deliberately left UNCONNECTED: it is the
# documented plug-in point and its contract is in the module header.  It is not
# untested for that reason -- the module carries a canary counter in this same
# domain which the halt gates, and the aux domain counts its toggles into
# THERM_CANARY, so "is the compute domain running and un-halted" is one JTAG
# read with no datapath present.
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/compute_clk]
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/ctl_host_clk]

# ---- thermal registers on the AUX (JTAG) side -----------------------------
# aux_therm and aux_peak come out of the all-inputs loop above.  aux_ctl is the
# only aux register with an OUTPUT channel, so it is built here.  Its
# C_DOUT_DEFAULT is 0, which does NOT match the clear key, so a card coming out
# of configuration cannot be clearing anything.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 aux_ctl
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells aux_ctl]
set n [get_property CONFIG.NUM_MI [get_bd_cells auxconnect]]
set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins aux_ctl/S_AXI]
connect_bd_net [get_bd_pins aux_ctl/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]
connect_bd_net [get_bd_pins aux_ctl/s_axi_aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]

connect_bd_net [get_bd_pins fk33_therm_0/stat_therm]  [get_bd_pins aux_therm/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_temps]  [get_bd_pins aux_therm/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_peak]   [get_bd_pins aux_peak/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/stat_trip]   [get_bd_pins aux_peak/gpio2_io_i]
connect_bd_net [get_bd_pins aux_ctl/gpio_io_o]        [get_bd_pins fk33_therm_0/ctl_aux]
connect_bd_net [get_bd_pins fk33_therm_0/stat_canary] [get_bd_pins aux_ctl/gpio2_io_i]

# ---- thermal registers on the PCIe AXI-Lite BAR ---------------------------
# The SAME words, resynchronised into the xdma domain inside fk33_thermal.  A
# 32-bit aux-domain word handed straight to an axi_gpio on this clock would tear
# under the host's read; the module's agreement filter is what makes these
# coherent.  These three cells are deliberately NOT part of the aux branch and
# are excluded from the aux clock-isolation check for that reason.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_therm
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_therm]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermp
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_ALL_OUTPUTS {0} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_thermp]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermc
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {0} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} CONFIG.C_ALL_OUTPUTS_2 {0} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_INTERRUPT_PRESENT {0}] [get_bd_cells fk33_thermc]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {$n + 3}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \
                    [get_bd_intf_pins fk33_therm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 1}]]] \
                    [get_bd_intf_pins fk33_thermp/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {$n + 2}]]] \
                    [get_bd_intf_pins fk33_thermc/S_AXI]
connect_bd_net [get_bd_pins fk33_therm/s_axi_aclk]     [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_therm/s_axi_aresetn]  [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_thermp/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_thermp/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_thermc/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_thermc/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]

connect_bd_net [get_bd_pins fk33_therm_0/host_therm]  [get_bd_pins fk33_therm/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_temps]  [get_bd_pins fk33_therm/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_peak]   [get_bd_pins fk33_thermp/gpio_io_i]
connect_bd_net [get_bd_pins fk33_therm_0/host_trip]   [get_bd_pins fk33_thermp/gpio2_io_i]
connect_bd_net [get_bd_pins fk33_thermc/gpio_io_o]    [get_bd_pins fk33_therm_0/ctl_host]
connect_bd_net [get_bd_pins fk33_therm_0/host_canary] [get_bd_pins fk33_thermc/gpio2_io_i]
# ---- end thermal protection -----------------------------------------------

regenerate_bd_layout
save_bd_design

assign_bd_address -offset 0x00003000 -range 4K [get_bd_addr_segs {system_management_wiz_0/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]

# ---- bring-up peripheral address map (gen_pcieep.py) -----------------------
# On the AXI-Lite BAR, which the XDMA IP sizes at 128 KB.  Everything here must
# fit in 0x00000..0x1FFFF or address assignment fails.
assign_bd_address -offset 0x0000A000  -range 4K  [get_bd_addr_segs {fk33_id/S_AXI/Reg}]
assign_bd_address -offset 0x00010000  -range 8K  [get_bd_addr_segs {fk33_scratch/S_AXI/Mem0}]
# On the DMA master, deliberately ABOVE the 8 GB of HBM so a bad host offset
# lands on nothing rather than silently in memory.  Left visible to jtag_hbm as
# well as to xdma/M_AXI, so the same bytes can be read back over JTAG -- which
# is what separates "XDMA wrote the wrong thing" from "the readback is wrong".
assign_bd_address -offset 0x200000000 -range 64K [get_bd_addr_segs {fk33_dmabram/S_AXI/Mem0}]

# ---- aux register map (gen_pcieep.py) --------------------------------------
# In jtag_aux's OWN address space.  Nothing here is reachable from xdma, by
# design: these registers exist precisely for the case where xdma is dead.
#   0x0000  AUX_MAGIC     0x41555831 = "AUX1", read-only fabric constant
#   0x0008  AUX_VERSION   0x20260828
#   0x1000  UCLK_TICKS    free-running, 1 tick per 128 xdma/axi_aclk cycles
#   0x1008  UCLK_HZ       measured xdma/axi_aclk in Hz.  250000000 = the PCIe
#                         hard block is clocked; 0 = it is not, and the PERST#
#                         level says whether that is reset or a missing refclk
#   0x2000  AUX_STATUS    PERST#, its stickies, axi_aresetn, user_lnk_up
#   0x2008  POT_STATUS    the VCCINT controller.  [31:24] is the ONLY wiper
#                         this bitstream is able to write, and must read 0x44
#   0x3000  AUX_MS        milliseconds since configuration
#   0x3008  PERST_MS      AUX_MS at the FIRST deassertion of PERST#
assign_bd_address -offset 0x00000000 -range 4K [get_bd_addr_segs {aux_id/S_AXI/Reg}]
assign_bd_address -offset 0x00001000 -range 4K [get_bd_addr_segs {aux_clkst/S_AXI/Reg}]
assign_bd_address -offset 0x00002000 -range 4K [get_bd_addr_segs {aux_stat/S_AXI/Reg}]
assign_bd_address -offset 0x00003000 -range 4K [get_bd_addr_segs {aux_time/S_AXI/Reg}]

# ---- thermal register map (gen_pcieep.py) ----------------------------------
# On jtag_aux, readable with the PCIe link DOWN:
#   0x4000  THERM_STATUS  halt/warn/valid/cause/trip count/stickies, [31]=1
#   0x4008  THERM_TEMPS   [9:0] die code [16:10] HBM0 [23:17] HBM1 [31:24] die C
#   0x5000  THERM_PEAK    the same fields, peak-hold
#   0x5008  THERM_TRIP    the same code fields captured at the trip + cause
#   0x6000  THERM_CTL     WRITE.  [31:16] must be 0xC1EA, [0] clear trip,
#                         [1] clear peak.  Edge triggered.
#   0x6008  THERM_CANARY  count of compute-domain canary toggles
assign_bd_address -offset 0x00004000 -range 4K [get_bd_addr_segs {aux_therm/S_AXI/Reg}]
assign_bd_address -offset 0x00005000 -range 4K [get_bd_addr_segs {aux_peak/S_AXI/Reg}]
assign_bd_address -offset 0x00006000 -range 4K [get_bd_addr_segs {aux_ctl/S_AXI/Reg}]
# On the PCIe AXI-Lite BAR, the same five words plus the same control:
#   0xB000/0xB008  THERM_STATUS / THERM_TEMPS
#   0xC000/0xC008  THERM_PEAK   / THERM_TRIP
#   0xD000/0xD008  THERM_CTL    / THERM_CANARY
assign_bd_address -offset 0x0000B000 -range 4K [get_bd_addr_segs {fk33_therm/S_AXI/Reg}]
assign_bd_address -offset 0x0000C000 -range 4K [get_bd_addr_segs {fk33_thermp/S_AXI/Reg}]
assign_bd_address -offset 0x0000D000 -range 4K [get_bd_addr_segs {fk33_thermc/S_AXI/Reg}]


if {$HBMGlobalSwitch == 1} {
    assign_bd_address -offset  0x00000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM00 }]
    assign_bd_address -offset  0x10000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM01 }]
    assign_bd_address -offset  0x20000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM02 }]
    assign_bd_address -offset  0x30000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM03 }]
    assign_bd_address -offset  0x40000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM04 }]
    assign_bd_address -offset  0x50000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM05 }]
    assign_bd_address -offset  0x60000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM06 }]
    assign_bd_address -offset  0x70000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM07 }]
    assign_bd_address -offset  0x80000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM08 }]
    assign_bd_address -offset  0x90000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM09 }]
    assign_bd_address -offset  0xA0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM10 }]
    assign_bd_address -offset  0xB0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM11 }]
    assign_bd_address -offset  0xC0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM12 }]
    assign_bd_address -offset  0xD0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM13 }]
    assign_bd_address -offset  0xE0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM14 }]
    assign_bd_address -offset  0xF0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM15 }]
    assign_bd_address -offset 0x100000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]
    assign_bd_address -offset 0x110000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM17 }]
    assign_bd_address -offset 0x120000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM18 }]
    assign_bd_address -offset 0x130000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM19 }]
    assign_bd_address -offset 0x140000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM20 }]
    assign_bd_address -offset 0x150000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM21 }]
    assign_bd_address -offset 0x160000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM22 }]
    assign_bd_address -offset 0x170000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM23 }]
    assign_bd_address -offset 0x180000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM24 }]
    assign_bd_address -offset 0x190000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM25 }]
    assign_bd_address -offset 0x1A0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM26 }]
    assign_bd_address -offset 0x1B0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM27 }]
    assign_bd_address -offset 0x1C0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM28 }]
    assign_bd_address -offset 0x1D0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM29 }]
    assign_bd_address -offset 0x1E0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM30 }]
    assign_bd_address -offset 0x1F0000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM31 }]

    exclude_seg_if hbm/SAXI_16/HBM_MEM00 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM02 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM03 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM04 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM05 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM06 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM07 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM08 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM09 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM10 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM11 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM12 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM13 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM14 xdma/M_AXI
    exclude_seg_if hbm/SAXI_16/HBM_MEM15 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM18 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM19 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM20 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM21 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM22 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM23 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM24 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM25 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM26 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM27 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM28 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM29 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM30 xdma/M_AXI
    exclude_seg_if hbm/SAXI_00/HBM_MEM31 xdma/M_AXI

    exclude_seg_if hbm/SAXI_16/HBM_MEM00 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM02 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM03 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM04 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM05 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM06 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM07 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM08 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM09 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM10 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM11 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM12 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM13 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM14 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM15 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM18 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM19 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM20 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM21 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM22 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM23 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM24 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM25 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM26 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM27 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM28 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM29 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM30 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM31 jtag_hbm/Data
} else {
    assign_bd_address -offset  0x00000000 -range 256M [get_bd_addr_segs {hbm/SAXI_00/HBM_MEM00 }]
    assign_bd_address -offset 0x100000000 -range 256M [get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]

    exclude_seg_if hbm/SAXI_00/HBM_MEM01 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_00/HBM_MEM16 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM00 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM17 jtag_hbm/Data
    exclude_seg_if hbm/SAXI_16/HBM_MEM01 jtag_hbm/Data

    if {$EnablePCIe == 1} {
        exclude_seg_if hbm/SAXI_00/HBM_MEM01 xdma/M_AXI
        exclude_seg_if hbm/SAXI_00/HBM_MEM16 xdma/M_AXI
        exclude_seg_if hbm/SAXI_00/HBM_MEM17 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM00 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM01 xdma/M_AXI
        exclude_seg_if hbm/SAXI_16/HBM_MEM17 xdma/M_AXI
    }
}
   
#set_property PR_FLOW 1 [current_project]
add_files -fileset constrs_1 -norecurse /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc
set_property target_constrs_file /home/orencollaco/GitHub/llama.vhdl/hw/fk33/fk33_pcieep.xdc [current_fileset -constrset]

make_wrapper -files [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd] -top
add_files -norecurse ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/hdl/bd_wrapper.v
update_compile_order -fileset sources_1

set_property strategy Performance_RefinePlacement [get_runs impl_1]

#open_hw
#create_hw_cfgmem -hw_device [lindex [get_hw_devices xcvu33p_0] 0] [lindex [get_cfgmem_parts {mt25qu256-spi-x1_x2_x4}] 0]
#set_property PROGRAM.BLANK_CHECK  0 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.ERASE  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.CFG_PROGRAM  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.VERIFY  1 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#set_property PROGRAM.CHECKSUM  0 [ get_property PROGRAM.HW_CFGMEM [lindex [get_hw_devices xcvu33p_0] 0]]
#close_hw




# ---------------------------------------------------------------- build
# IP upgrade first, and REPORT it.  Crossing 2022.2 -> 2023.2 can revise the HBM
# controller, the smartconnect and xdma; a stale IP either fails to generate or,
# worse, generates with different defaults.  report_ip_status output is the
# thing to read if this build misbehaves.

# ---- thermal sensor availability (gen_pcieep.py) --------------------------
# Vivado SILENTLY IGNORES set_property on a CONFIG name that does not apply to
# an IP, so asking for temp_out is not evidence of getting it.  Each check
# below is a way the thermal guard can be built present, timing-clean, and
# BLIND: without ENABLE_TEMP_BUS there is no die temperature in the fabric at
# all, and the guard would then sit permanently halted on a stale die sensor.
# This runs unconditionally.  It costs a few seconds and it is the difference
# between a thermal guard and a thermal guard-shaped hole.
foreach p {ENABLE_TEMP_BUS USER_TEMP_ALARM TEMPERATURE_ALARM_TRIGGER            TEMPERATURE_ALARM_RESET TEMPERATURE_ALARM_OT_TRIGGER            TEMPERATURE_ALARM_OT_RESET REFERENCE INTERFACE_SELECTION} {
    puts "FK33_SYSMON $p = [get_property CONFIG.$p [get_bd_cells system_management_wiz_0]]"
}
if {[get_property CONFIG.ENABLE_TEMP_BUS [get_bd_cells system_management_wiz_0]] ne "true"} {
    error "FK33_THERM FAIL: CONFIG.ENABLE_TEMP_BUS did not take.  There is no die temperature bus in the fabric, so the thermal guard has no die sensor."
}
if {[get_property CONFIG.USER_TEMP_ALARM [get_bd_cells system_management_wiz_0]] ne "true"} {
    error "FK33_THERM FAIL: CONFIG.USER_TEMP_ALARM did not take, so user_temp_alarm_out does not exist and the die has only ONE comparator instead of two."
}
# The four HBM pins the guard needs.  They exist with no reconfiguration --
# DRAM_0_* unconditionally and DRAM_1_* because USER_HBM_STACK is 2 -- but if a
# future edit ever drops to one stack they would vanish silently.
foreach hp {DRAM_0_STAT_TEMP DRAM_1_STAT_TEMP DRAM_0_STAT_CATTRIP DRAM_1_STAT_CATTRIP} {
    set hpin [get_bd_pins -quiet hbm/$hp]
    if {![llength $hpin]} {
        error "FK33_THERM FAIL: hbm/$hp does not exist at this IP configuration"
    }
    set hn [get_bd_nets -quiet -of_objects $hpin]
    if {![llength $hn]} {
        error "FK33_THERM FAIL: hbm/$hp is UNCONNECTED.  The stacks' own temperature is going nowhere, which is the defect this build exists to fix."
    }
    puts "FK33_THERM hbm/$hp connected"
}

# ---- no-card block-design check (gen_pcieep.py) ----------------------------
# FK33_STOP_AFTER_BD=1 stops here.  Everything above this line is IP
# configuration and address assignment, which is the part that can be checked
# without a card and without an hour of implementation.  It matters more than
# it sounds: Vivado SILENTLY IGNORES set_property on a CONFIG.* name that does
# not exist for that IP, so a typo in any of the xdma settings above produces a
# perfectly clean build of the wrong design.  Reading the parameters back is
# the only thing that catches it.
if {[info exists ::env(FK33_STOP_AFTER_BD)]} {
    puts "==== FK33_BD_CHECK ===="
    foreach p {pl_link_cap_max_link_width pl_link_cap_max_link_speed \
               axi_data_width xdma_rnum_chnl xdma_wnum_chnl \
               axilite_master_en axilite_master_size axilite_master_scale \
               vendor_id pf0_device_id pf0_subsystem_vendor_id pf0_subsystem_id \
               pcie_blk_locn axisten_freq} {
        if {[llength [get_bd_cells -quiet xdma]]} {
            puts "FK33_CFG xdma.$p = [get_property CONFIG.$p [get_bd_cells xdma]]"
        }
    }
    foreach c {pcie2axil pcie2hbm auxconnect} {
        puts "FK33_CFG $c.NUM_SI = [get_property CONFIG.NUM_SI [get_bd_cells $c]]"
        puts "FK33_CFG $c.NUM_MI = [get_property CONFIG.NUM_MI [get_bd_cells $c]]"
    }
    foreach c {fk33_id fk33_scratch fk33_dmabram} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING CELL $c" }
    }
    # The aux domain.  A missing cell here means the bitstream is blind with
    # the link down, which is the exact condition it exists for, so name them.
    foreach c {fk33_aux_0 util_ds_buf_1 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                aux_therm aux_peak aux_ctl fk33_therm_0 fk33_therm fk33_thermp fk33_thermc} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING AUX CELL $c" }
    }
    # Prove, from the tool rather than from the diagram, that not one pin of the
    # aux branch is driven by xdma.  This is the check that would catch a future
    # edit quietly joining the aux clock or reset onto the PCIe domain.
    # Exactly two aux pins may see something xdma drives, and both are MEASURED
    # SIGNALS rather than parts of the read path:
    #   fk33_aux_0/xdma_aclk     clocks a divider whose only output is a single
    #                            bit through a synchroniser
    #   fk33_aux_0/xdma_aresetn  is an input to a synchroniser
    # If axi_aclk reaches anything else in the aux branch, the read path is no
    # longer independent of the PCIe link and this build is pointless.
    #
    # fk33_therm_0 adds three more MEASURED-OR-CONSUMER pins on the PCIe clock,
    # and each is named individually rather than exempting the cell:
    #   sysmon_clk    clocks a divider on SYSMON's eoc_out, nothing else
    #   ctl_host_clk  clocks the host clear qualifier and the publication filter
    #   compute_clk   the datapath's own clock; the halt is synchronised INTO it
    # The guard's decision logic, its watchdogs and its latches are all on
    # fk33_aux_0/aux_clk, which is the point: they must survive the PCIe domain
    # dying.  If any OTHER thermal pin ever joins xdma/axi_aclk this fails.
    set auxallow {/fk33_aux_0/xdma_aclk /fk33_aux_0/xdma_aresetn                   /fk33_therm_0/sysmon_clk /fk33_therm_0/ctl_host_clk                   /fk33_therm_0/compute_clk}
    set auxbad 0
    foreach c {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                aux_therm aux_peak aux_ctl fk33_therm_0} {
        foreach p [get_bd_pins -quiet $c/*] {
            if {[lsearch -exact $auxallow $p] >= 0} { continue }
            foreach n [get_bd_nets -quiet -of_objects $p] {
                foreach src [get_bd_pins -quiet -of_objects $n] {
                    if {[string match "/xdma/axi_aclk" $src]} {
                        puts "FK33_AUX_VIOLATION $p shares a net with $src"
                        incr auxbad
                    }
                }
            }
        }
    }
    puts "FK33_AUX_CLKCHECK violations=$auxbad"
    puts "FK33_CFG id_magic = [get_property CONFIG.CONST_VAL [get_bd_cells id_magic]]"
    puts "FK33_CFG id_build = [get_property CONFIG.CONST_VAL [get_bd_cells id_build]]"
    puts "==== FK33_MAP (address space / segment / offset / range) ===="
    foreach sp [get_bd_addr_spaces] {
        foreach sg [get_bd_addr_segs -quiet -of_objects $sp] {
            catch {
                puts [format "FK33_MAP %-24s %-42s %-14s %s" \
                      [get_property PATH $sp] $sg \
                      [get_property OFFSET $sg] [get_property RANGE $sg]]
            }
        }
    }
    puts "==== validate_bd_design ===="
    if {[catch {validate_bd_design -force} verr]} {
        puts "FK33_BD_VALIDATE FAIL: $verr"
        puts "FK33_BD_ONLY_DONE"
        return -code error "block design validation failed"
    }
    puts "FK33_BD_VALIDATE OK"
    puts "FK33_BD_ONLY_DONE"
    return
}

puts "==== IP status before upgrade ===="
report_ip_status
set stale [get_ips -filter {IS_LOCKED == 1 || UPGRADE_VERSIONS != ""}]
if {[llength $stale] > 0} {
    puts "==== upgrading [llength $stale] IP ===="
    upgrade_ip $stale
    report_ip_status
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "SYNTH FAILED -- see the run log"
}
puts "==== synthesis done ===="

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "IMPL FAILED -- see the run log"
}

open_run impl_1
puts "==== FK33 aux-domain constraint verification (implemented design) ===="
# 1. the free-running clock must exist, exactly once, at 5 ns
set auxclks [get_clocks -quiet -of_objects [get_ports {sysref_clk_p[0]}]]
puts "FK33_AUXCLK clocks=$auxclks"
if {[llength $auxclks] != 1} {
    error "FK33_AUXCLK FAIL: expected exactly one clock on sysref_clk_p\[0\], got [llength $auxclks]. The aux domain would be unconstrained."
}
puts "FK33_AUXCLK period=[get_property PERIOD [lindex $auxclks 0]] ns"

# 2. it must be asynchronous to everything else.
#
# COUNTING the crossing paths is the WRONG test and gave a false failure once:
# get_timing_paths still ENUMERATES a path that an asynchronous clock group has
# excluded, it just reports it with an EMPTY slack and GROUP "(none)".  The real
# question is whether any crossing path is still ANALYSED.
#
# NOT remove_from_collection either: that is a Synopsys-style command Vivado
# does not have ("invalid command name").  Filter by name.
set others [get_clocks -quiet -filter {NAME != "sysref_clk"}]
set xbad 0
foreach pth [concat [get_timing_paths -quiet -from [lindex $auxclks 0] -to $others -max_paths 8]                     [get_timing_paths -quiet -from $others -to [lindex $auxclks 0] -max_paths 8]] {
    if {[get_property SLACK $pth] ne ""} {
        puts "FK33_AUXCLK TIMED-CROSSING [get_property STARTPOINT_CLOCK $pth] -> [get_property ENDPOINT_CLOCK $pth] slack=[get_property SLACK $pth] ep=[get_property ENDPOINT_PIN $pth]"
        incr xbad
    }
}
puts "FK33_AUXCLK analysed paths crossing the aux boundary: $xbad (must be 0)"
if {$xbad > 0} {
    error "FK33_AUXCLK FAIL: set_clock_groups did not apply; the CDC into the aux domain is being timed rather than declared asynchronous."
}

# 3. the debug hub must be on it.  This is the one that decides whether ANY of
# this is readable with the link down.
set hubpins [get_pins -quiet -hierarchical -filter {NAME =~ "*dbg_hub*" && REF_PIN_NAME == "clk"}]
set hubclks [get_clocks -quiet -of_objects $hubpins]
puts "FK33_HUBCLK pins=$hubpins clocks=$hubclks"
if {[llength $hubclks] == 0} {
    error "FK33_HUBCLK FAIL: no clock reaches the debug hub's clk pin. connect_debug_port did not apply."
}
if {[lsearch -exact [get_property NAME $hubclks] "sysref_clk"] < 0} {
    error "FK33_HUBCLK FAIL: the debug hub is clocked by \"$hubclks\", not sysref_clk. With the PCIe link down it would not answer, which is the whole point of this build."
}
puts "FK33_HUBCLK OK dbg_hub is on sysref_clk"

# 4. and nothing in the aux branch may be clocked by the PCIe user clock
foreach auxcell {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time                  aux_therm aux_peak aux_ctl fk33_therm_0} {
    set c [get_cells -quiet bd_i/$auxcell]
    if {[llength $c] == 0} { error "FK33_AUX FAIL: bd_i/$auxcell is missing from the implemented design" }
}
puts "FK33_AUX all aux cells present in the implemented design"

# 5. the thermal guard's decision logic must be on the free-running clock.  A
# guard clocked by anything the PCIe link can stop is a guard that stops with
# it, and that is the exact failure this whole domain exists to avoid.
set tcell [get_cells -quiet bd_i/fk33_therm_0]
set tclks [get_clocks -quiet -of_objects [get_pins -quiet -of_objects $tcell -filter {REF_PIN_NAME == "aux_clk"}]]
puts "FK33_THERMCLK fk33_therm_0/aux_clk clocks=$tclks"
if {[lsearch -exact [get_property NAME $tclks] "sysref_clk"] < 0} {
    error "FK33_THERMCLK FAIL: the thermal guard's aux_clk is "$tclks", not sysref_clk."
}
puts "FK33_THERMCLK OK the thermal guard runs on the free-running oscillator"

# 6. the alarm thresholds as they exist IN THE ROUTED NETLIST, not as they were
# asked for in the block design.  This is the only check in the build that reads
# what actually reaches the device: the SYSMONE4 primitive's INIT_4x/INIT_5x
# attributes ARE the configuration registers, loaded from the bitstream at
# startup.  A BD CONFIG parameter is a request; these are the answer.
#
# Register map (UG580 / the SYSMONE4 primitive):
#   50h  user temperature upper (alarm trigger)
#   53h  OT upper -- [15:4] limit, [3:0] must be 0011 to ARM automatic shutdown
#   54h  user temperature lower (alarm reset, i.e. the hysteresis floor)
#   57h  OT lower (shutdown reset)
# External-reference transfer function, from the same source:
#   T = code * 507.5921310 / 65536 - 279.42657680
proc sysmon_degc {code} { expr {$code * 507.5921310 / 65536.0 - 279.42657680} }

# Vivado does not promise a format for an INIT attribute.  It has been seen as
# 16'hBA40, as a bare hex string, and as a binary literal; guessing wrong here
# would abort a fifty-minute build on a formatting detail rather than on
# anything about the design, so parse all three and fail loudly only if the
# value is genuinely unreadable.
proc sysmon_parse {name raw} {
    set t [string trim $raw]
    if {[regexp {^[0-9]+'[bB]([01]+)$} $t -> bits]} {
        set v 0
        foreach c [split $bits ""] { set v [expr {$v * 2 + $c}] }
        return $v
    }
    if {[regexp {^[0-9]+'[hH]([0-9a-fA-F]+)$} $t -> hx]} { scan $hx %x v ; return $v }
    if {[regexp {^0[xX]([0-9a-fA-F]+)$} $t -> hx]}       { scan $hx %x v ; return $v }
    if {[regexp {^[0-9a-fA-F]+$} $t]}                    { scan $t  %x v ; return $v }
    error "FK33_SYSMONI FAIL: cannot parse $name = "$raw""
}

set smc [get_cells -quiet -hierarchical -filter {REF_NAME =~ "SYSMONE4*"}]
if {[llength $smc] != 1} {
    error "FK33_SYSMONI FAIL: expected exactly one SYSMONE4 in the routed design, found [llength $smc]: $smc"
}
puts "FK33_SYSMONI cell=[get_property NAME $smc]"
array set smwant {INIT_50 90.0 INIT_54 75.0}
foreach r {INIT_50 INIT_53 INIT_54 INIT_57} {
    set raw [get_property $r $smc]
    if {$raw eq ""} { error "FK33_SYSMONI FAIL: $r is not readable on the SYSMONE4 primitive" }
    set code [sysmon_parse $r $raw]
    puts [format "FK33_SYSMONI %s = 0x%04X -> %.2f C" $r $code [sysmon_degc $code]]
    if {[info exists smwant($r)]} {
        set d [expr {abs([sysmon_degc $code] - $smwant($r))}]
        if {$d > 1.0} {
            error "FK33_SYSMONI FAIL: $r decodes to [format %.2f [sysmon_degc $code]] C, not $smwant($r) C. The threshold in the bitstream is NOT the one this design asked for."
        }
    }
}
# The OT arming nibble.  This is the Task-1 question answered from the artefact
# rather than from documentation: 53h[3:0] == 0011 means SYSMON will power the
# device down by itself at the OT limit.  It is REPORTED, not enforced -- what
# the nibble should be is a decision for the bench, and the fabric guard exists
# precisely because the OT shutdown is a die-destruction backstop rather than a
# thermal-management mechanism.
set c53 [sysmon_parse INIT_53 [get_property INIT_53 $smc]]
set otarm [expr {$c53 & 0xF}]
set otlim [expr {$c53 & 0xFFF0}]
puts [format "FK33_SYSMONI OT limit  = 0x%04X -> %.2f C" $otlim [sysmon_degc $otlim]]
puts [format "FK33_SYSMONI OT arming nibble 53h\[3:0\] = 0x%X (0x3 = automatic power-down ARMED)" $otarm]
if {$otarm == 3} {
    puts "FK33_SYSMONI OT automatic shutdown is ARMED in this bitstream"
} else {
    puts "FK33_SYSMONI OT automatic shutdown is NOT armed; the fabric guard is the only protection"
}

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
report_utilization -file fk33_pcieep_util.rpt

set bit [glob -nocomplain ./$ProjectName/$ProjectName.runs/impl_1/*.bit]
if {[llength $bit] == 1} {
    puts "FK33_BITSTREAM [lindex $bit 0] ([file size [lindex $bit 0]] bytes)"
} else {
    puts "FK33_BITSTREAM MISSING"
}
puts "FK33_BUILD_DONE"
