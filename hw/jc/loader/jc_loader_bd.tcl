# hw/jc/loader/jc_loader_bd.tcl -- block design for the Jungle Cat JTAG-to-HBM loader.
# Sourced by build_loader.tcl inside a project that already holds the loader's VHDL
# (module reference jc_loader_top). Style reference: hw/jc/axiprobe/jc_axiprobe_bd.tcl;
# HBM configuration copied from the FK33's working builds
# (hw/fk33/build_fk33_firstlight.tcl HBMGlobalSwitch=1 branch, build_fk33_pcieep.tcl).
#
#   sysclk (BC26/BC27, 200 MHz LVDS) -> util_ds_buf IBUFDS -> clk_wiz_0
#     clk_out1 100 MHz  HBM APB_0/1_PCLK, apb_rst (proc_sys_reset)
#     clk_out2 200 MHz  HBM_REF_CLK_0/1
#     clk_out3 200 MHz  aclk: loader, HBM AXI_00/AXI_16, both jtag_axi, BRAM, smartconnect
#   loader (jc_loader_top) m_axi -> hbm/SAXI_00 (global addressing: all 8 GB)
#   jtag_hbm (jtag_axi) -> hbm_sc (smartconnect) -> hbm/SAXI_16   [Task 11 spot checks]
#   jtag_axi_0 -> axi_bram_ctrl_0 -> 8 KB BRAM at 0xC0000000      [axiprobe's path, kept]
#
# Every set_property on an IP CONFIG is READ BACK (JCLOADER_CFG lines): Vivado silently
# ignores a CONFIG name an IP does not have.
create_bd_design jcl

proc jcl_want {cell key want} {
  set got [get_property CONFIG.$key [get_bd_cells $cell]]
  if {[string toupper $got] ne [string toupper $want]} {
    error "JCLOADER_CFG FAIL $cell.$key is \"$got\", not \"$want\""
  }
  puts "JCLOADER_CFG $cell.$key = $got"
}

# ---- clocks and resets -------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 sysclk_buf
set_property CONFIG.C_BUF_TYPE {IBUFDS} [get_bd_cells sysclk_buf]
make_bd_intf_pins_external [get_bd_intf_pins sysclk_buf/CLK_IN_D]
set_property name sysclk [get_bd_intf_ports CLK_IN_D_0]
set_property CONFIG.FREQ_HZ 200000000 [get_bd_intf_ports sysclk]

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_0]
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {200.000} \
  CONFIG.USE_RESET {false} \
  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]
foreach {k v} {PRIM_SOURCE No_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 100.000
               CLKOUT2_REQUESTED_OUT_FREQ 200.000 CLKOUT3_REQUESTED_OUT_FREQ 200.000} {
  jcl_want clk_wiz_0 $k $v
}
connect_bd_net [get_bd_pins sysclk_buf/IBUF_OUT] [get_bd_pins clk_wiz_0/clk_in1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells one]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 aclk_rst
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 apb_rst
foreach r {aclk_rst apb_rst} {
  connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins $r/dcm_locked]
  # ext_reset_in is active-low by default: tie it high (not in reset) explicitly; left
  # unconnected it would be tied to zero and hold the domain in reset forever.
  connect_bd_net [get_bd_pins one/dout] [get_bd_pins $r/ext_reset_in]
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins aclk_rst/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins apb_rst/slowest_sync_clk]

# ---- HBM ----------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \
  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200} \
  CONFIG.USER_AXI_INPUT_CLK_FREQ {200} CONFIG.USER_AXI_INPUT_CLK1_FREQ {200}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]
set off {}
for {set i 1} {$i < 32} {incr i} {
  if {$i == 16} { continue }
  lappend off [format CONFIG.USER_SAXI_%02d $i] {false}
}
set_property -dict $off [get_bd_cells hbm]
set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]
foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200
               USER_HBM_REF_CLK_1 200 USER_AXI_INPUT_CLK_FREQ 200 USER_AXI_INPUT_CLK1_FREQ 200
               USER_SWITCH_ENABLE_00 TRUE USER_SWITCH_ENABLE_01 TRUE USER_SAXI_00 true
               USER_SAXI_16 true USER_SAXI_01 false USER_SAXI_31 false USER_APB_EN false} {
  jcl_want hbm $k $v
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK] [get_bd_pins hbm/APB_1_PCLK]
connect_bd_net [get_bd_pins apb_rst/peripheral_aresetn] [get_bd_pins hbm/APB_0_PRESET_N] [get_bd_pins hbm/APB_1_PRESET_N]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_0] [get_bd_pins hbm/HBM_REF_CLK_1]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins hbm/AXI_00_ACLK] [get_bd_pins hbm/AXI_16_ACLK]
connect_bd_net [get_bd_pins aclk_rst/peripheral_aresetn] [get_bd_pins hbm/AXI_00_ARESET_N] [get_bd_pins hbm/AXI_16_ARESET_N]

# ---- the loader -----------------------------------------------------------------------
create_bd_cell -type module -reference jc_loader_top loader
set_property CONFIG.DNA_DIV {10} [get_bd_cells loader]
jcl_want loader DNA_DIV 10
# One clock port, so Vivado infers aclk's ASSOCIATED_BUSIF itself (the property is
# read-only on this cell: setting it is CRITICAL WARNING BD 41-737). Read it back.
set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins loader/aclk]]
if {[lsearch -exact [split $_ab :] m_axi] < 0} {
  error "JCLOADER_BD FAIL: loader/aclk ASSOCIATED_BUSIF is \"$_ab\", m_axi missing"
}
puts "JCLOADER_BD loader/aclk ASSOCIATED_BUSIF $_ab"
# arst is not inferred as a reset interface (it is a plain data input to the cell, and
# jc_loader_top registers it with the HBM-ready hold); it is driven from
# aclk_rst/peripheral_reset, which is active high, matching the VHDL.
puts "JCLOADER_BD loader/arst TYPE [get_property TYPE [get_bd_pins loader/arst]]"
if {[llength [get_bd_intf_pins -quiet loader/m_axi]] != 1} {
  error "JCLOADER_BD FAIL: no inferred m_axi interface on the loader cell"
}
puts "JCLOADER_BD loader/m_axi PROTOCOL [get_property CONFIG.PROTOCOL [get_bd_intf_pins loader/m_axi]]"
puts "JCLOADER_BD loader/m_axi ADDR_WIDTH [get_property CONFIG.ADDR_WIDTH [get_bd_intf_pins loader/m_axi]] DATA_WIDTH [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins loader/m_axi]]"
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins loader/aclk]
connect_bd_net [get_bd_pins aclk_rst/peripheral_reset] [get_bd_pins loader/arst]
connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_CATTRIP] [get_bd_pins loader/hbm_cattrip0]
connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_CATTRIP] [get_bd_pins loader/hbm_cattrip1]
connect_bd_net [get_bd_pins hbm/apb_complete_0] [get_bd_pins loader/hbm_ready0]
connect_bd_net [get_bd_pins hbm/apb_complete_1] [get_bd_pins loader/hbm_ready1]
connect_bd_intf_net [get_bd_intf_pins loader/m_axi] [get_bd_intf_pins hbm/SAXI_00]
foreach {pin port} {fan_ctl fan_ctl led_a LED_A led_b LED_B led_c LED_C led_d LED_D} {
  create_bd_port -dir O $port
  connect_bd_net [get_bd_pins loader/$pin] [get_bd_ports $port]
}

# ---- jtag_axi readback paths ------------------------------------------------------------
# (1) hw/jc/axiprobe's BRAM path, unchanged in shape (now on aclk instead of CFGMCLK).
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_0
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32}] [get_bd_cells axi_bram_ctrl_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen blk_mem_gen_0
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM} CONFIG.use_bram_block {BRAM_Controller} CONFIG.EN_SAFETY_CKT {false}] [get_bd_cells blk_mem_gen_0]
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTA]

# (2) a second jtag_axi into HBM SAXI_16 (Task 11's independent spot checks). 64-bit
# address (HBM is 33 bits), 64-bit data, as the FK33's jtag_hbm; the smartconnect does
# the AXI4 -> AXI3 and 64 -> 256 bit conversion.
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_hbm
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]
jcl_want jtag_hbm M_AXI_ADDR_WIDTH 64
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hbm_sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells hbm_sc]
connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins hbm_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins hbm_sc/M00_AXI] [get_bd_intf_pins hbm/SAXI_16]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins jtag_axi_0/aclk] \
  [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] [get_bd_pins jtag_hbm/aclk] [get_bd_pins hbm_sc/aclk]
connect_bd_net [get_bd_pins aclk_rst/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
  [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] [get_bd_pins jtag_hbm/aresetn] [get_bd_pins hbm_sc/aresetn]

# ---- addresses ---------------------------------------------------------------------------
# Both HBM masters see all 32 pseudo-channel segments at their absolute addresses
# (global addressing; hw/fk33/build_fk33_pcieep.tcl's engine assignment, same shape).
for {set s 0} {$s < 32} {incr s} {
  assign_bd_address -target_address_space [get_bd_addr_spaces loader/m_axi] \
    -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \
    [get_bd_addr_segs [format "hbm/SAXI_00/HBM_MEM%02d" $s]]
  assign_bd_address -target_address_space [get_bd_addr_spaces jtag_hbm/Data] \
    -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \
    [get_bd_addr_segs [format "hbm/SAXI_16/HBM_MEM%02d" $s]]
}
assign_bd_address -target_address_space [get_bd_addr_spaces jtag_axi_0/Data] \
  -offset 0xC0000000 -range 8K [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0]
foreach seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces loader/m_axi]] {
  puts "JCLOADER_ADDR loader [get_property OFFSET $seg] [get_property RANGE $seg] $seg"
}

# ---- checks ----------------------------------------------------------------------------
if {[catch {validate_bd_design -force} vmsg]} { error "JCLOADER_BD_VALIDATE FAIL: $vmsg" }

# Every module-reference input pin must have a net (hw/fk33/CLAUDE.md FK33_UNCONNECTED):
# an unconnected input is tied to ZERO, and Vivado warns only when the VHDL port has no
# default. Scalar/vector pins need a net; interface pins need an interface net.
set bad {}
foreach cell [get_bd_cells -hierarchical -quiet -filter {VLNV =~ "*:module_ref:*"}] {
  foreach pin [get_bd_pins -quiet -of_objects $cell -filter {DIR == I && INTF == false}] {
    if {[llength [get_bd_nets -quiet -of_objects $pin]] == 0} { lappend bad [get_property PATH $pin] }
  }
  foreach ip [get_bd_intf_pins -quiet -of_objects $cell] {
    if {[llength [get_bd_intf_nets -quiet -of_objects $ip]] == 0} { lappend bad [get_property PATH $ip] }
  }
}
set nmr [llength [get_bd_cells -hierarchical -quiet -filter {VLNV =~ "*:module_ref:*"}]]
puts "JCLOADER_UNCONNECTED module_ref_cells=$nmr count=[llength $bad]"
foreach p $bad { puts "JCLOADER_UNCONNECTED pin $p" }
if {$nmr != 1} { error "JCLOADER_UNCONNECTED FAIL: expected 1 module_ref cell, found $nmr (the check would be vacuous)" }
if {[llength $bad] > 0} { error "JCLOADER_UNCONNECTED FAIL: [llength $bad] unconnected module input pin(s): $bad" }
save_bd_design
