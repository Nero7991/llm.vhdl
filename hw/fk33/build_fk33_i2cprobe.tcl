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

set ProjectName fk33_i2cprobe
set ProjectFolder ./$ProjectName

set EnablePCIe 0
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

# tgRoot -- the llama.vhdl repo root.  NOT $scriptPath above, which is SQRL's
# vendor tree and a separate repository.
#
# Three candidates, tried in order, each accepted only if it really contains
# the tree.  See the TGROOT_BLOCK comment in hw/fk33/gen_i2cprobe.py for why
# this is not just [file dirname [info script]]: hw/fk33/pcieep_build.sh COPIES
# the generated build script out of the repo before sourcing it, so the
# script's own location is not the repo during a card build.
set tgRoot ""
foreach _cand [list \
        [expr {[info exists ::env(FK33_TGROOT)] ? $::env(FK33_TGROOT) : ""}] \
        [expr {[info script] eq "" ? "" : [file normalize [file join [file dirname [info script]] .. ..]]}] \
        "/home/orencollaco/GitHub/llama.vhdl"] {
    if {$_cand ne "" && [file exists [file join $_cand rtl util_pkg.vhd]]} {
        set tgRoot [file normalize $_cand]
        break
    }
}
unset _cand
if {$tgRoot eq ""} {
    error "tgRoot: no candidate repo root contains rtl/util_pkg.vhd. Set FK33_TGROOT, or re-run hw/fk33/gen_pcieep.py from the checkout you mean to build."
}
puts "FK33_TGROOT $tgRoot"
set sourceRoot "/home/orencollaco/GitHub/SQRL_FK33"
#puts stdout $scriptPath
#puts stdout [join [lrange [file split [file dirname [info script]]] 0 end-2] "/"]
#return -code 1

# version gate removed -- see header note 2
puts "INFO: building with Vivado [version -short] (upstream targets 2022.2)"

create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"
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
make_bd_intf_pins_external  [get_bd_intf_pins axi_gpio_0/GPIO]
set_property name i2cprobe [get_bd_intf_ports GPIO_0]

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
    set_property -dict [list CONFIG.pl_link_cap_max_link_width {X1} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.pl_link_cap_max_link_width {X16} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} CONFIG.axi_data_width {512_bit}] [get_bd_cells xdma]
    #set_property -dict [list CONFIG.xdma_rnum_chnl {4} CONFIG.xdma_wnum_chnl {4}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.xdma_pcie_64bit_en {true} CONFIG.pf0_msix_cap_table_bir {BAR_1:0} CONFIG.pf0_msix_cap_pba_bir {BAR_1:0} CONFIG.xdma_pcie_prefetchable {true}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pcie_blk_locn {PCIE4C_X1Y0}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.vendor_id {1E24}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pf0_device_id {1533} CONFIG.PF0_DEVICE_ID_mqdma {1533} CONFIG.PF2_DEVICE_ID_mqdma {1533} CONFIG.PF3_DEVICE_ID_mqdma {1533}] [get_bd_cells xdma]
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
    make_bd_pins_external  [get_bd_pins xlconstant_0/dout]
    set_property name pcie_clkreq [get_bd_ports dout_0]
    
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]
    connect_bd_intf_net [get_bd_intf_pins xdma/M_AXI] [get_bd_intf_pins pcie2hbm/S01_AXI]
    
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]

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




regenerate_bd_layout
save_bd_design

assign_bd_address -offset 0x00003000 -range 4K [get_bd_addr_segs {system_management_wiz_0/S_AXI_LITE/Reg}]
assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]

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
add_files -fileset constrs_1 -norecurse $tgRoot/hw/fk33/fk33_i2cprobe.xdc
set_property target_constrs_file $tgRoot/hw/fk33/fk33_i2cprobe.xdc [current_fileset -constrset]

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
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
report_utilization -file fk33_firstlight_util.rpt

set bit [glob -nocomplain ./$ProjectName/$ProjectName.runs/impl_1/*.bit]
if {[llength $bit] == 1} {
    puts "FK33_BITSTREAM [lindex $bit 0] ([file size [lindex $bit 0]] bytes)"
} else {
    puts "FK33_BITSTREAM MISSING"
}
puts "FK33_BUILD_DONE"
