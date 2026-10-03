# JTAG-to-AXI master driving an AXI BRAM, for measuring JTAG-AXI write bandwidth
# over CoE/XVC.  External ports: mclk (clock), aresetn (active-low reset).
create_bd_design axiprobe
create_bd_port -dir I -type clk mclk
create_bd_port -dir I -type rst aresetn
set_property CONFIG.ASSOCIATED_RESET aresetn [get_bd_ports mclk]
set_property CONFIG.FREQ_HZ 50000000 [get_bd_ports mclk]

create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl axi_bram_ctrl_0
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32}] [get_bd_cells axi_bram_ctrl_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen blk_mem_gen_0
set_property -dict [list CONFIG.Memory_Type {Single_Port_RAM} CONFIG.use_bram_block {BRAM_Controller} CONFIG.EN_SAFETY_CKT {false}] [get_bd_cells blk_mem_gen_0]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTA]
connect_bd_net [get_bd_ports mclk] [get_bd_pins jtag_axi_0/aclk] [get_bd_pins axi_bram_ctrl_0/s_axi_aclk]
connect_bd_net [get_bd_ports aresetn] [get_bd_pins jtag_axi_0/aresetn] [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn]
assign_bd_address
validate_bd_design
save_bd_design
