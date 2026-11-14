# hw/jc/a450/a450_bd.tcl -- block design of the a450 A+HBM timing design (plan
# 2026-11-12-a450-per-port-tiles Task 7, spec 3.2 gate 2).  Sourced by build_a450.tcl.
#
#   sysclk (200 MHz LVDS, BC26/BC27) -> clk_wiz_0: clk_out1 100 (HBM APB), clk_out2 200
#   (HBM ref), clk_out3 125 (clk_core) -> clk_wiz_a: clk_out1 450 (aclk_a), from clk_out2.
#   hbm: 2 stacks, all 32 SAXI on aclk_a at USER_AXI_INPUT_CLK_FREQ 450 (PG276: the switch
#   runs on an AXI port clock, so every port moves with A).
#   top (a450_hbm_top): m00..m23 weight ports, m24..m26 scale ports, on hbm/SAXI_nn per
#   gen_pcieep.ENG_PORT_MAP's first 27 entries (the card's own map).  SAXI 00, 16, 29, 30,
#   31 carry no master and are DISABLED: an enabled SAXI with nothing on it fails
#   validate_bd_design (BD 41-1380, MEASURED in the Task 7 pre-flight), and there is no
#   master in this design to put on them.  The switch clocks are therefore selected from
#   SAXI_01 and SAXI_17 (both on aclk_a, like every enabled port).
# Every CONFIG this file sets is read back (a set_property on a name the object lacks is
# silent).  Sentinels: A450BD_CFG lines, A450BD_DONE; failures are Tcl errors.
create_bd_design a450

proc a4_want {cell key want} {
  set got [get_property CONFIG.$key [get_bd_cells $cell]]
  if {[string toupper $got] ne [string toupper $want]} {
    error "A450BD_CFG FAIL $cell.$key is \"$got\", not \"$want\""
  }
  puts "A450BD_CFG $cell.$key = $got"
}

set PORTMAP {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25 26 27 28}

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
  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {125.000}] [get_bd_cells clk_wiz_0]
foreach {k v} {PRIM_SOURCE No_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 100.000
               CLKOUT2_REQUESTED_OUT_FREQ 200.000 CLKOUT3_REQUESTED_OUT_FREQ 125.000} {
  a4_want clk_wiz_0 $k $v
}
connect_bd_net [get_bd_pins sysclk_buf/IBUF_OUT] [get_bd_pins clk_wiz_0/clk_in1]

# aclk_a: a second MMCM on clk_out2.  One MMCM cannot make 125 and 450 together (their
# lcm, 2250 MHz, is above the VCO range), so the 450 comes from its own.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_a
set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_a]
set_property -dict [list CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {200.000} \
  CONFIG.USE_RESET {false} \
  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {450.000}] [get_bd_cells clk_wiz_a]
foreach {k v} {PRIM_SOURCE Global_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 450.000} {
  a4_want clk_wiz_a $k $v
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins clk_wiz_a/clk_in1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells one]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 aclk_reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 apb_rst
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins core_reset/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins apb_rst/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_a/locked] [get_bd_pins aclk_reset/dcm_locked]
foreach r {core_reset aclk_reset apb_rst} {
  connect_bd_net [get_bd_pins one/dout] [get_bd_pins $r/ext_reset_in]
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins aclk_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins apb_rst/slowest_sync_clk]

create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \
  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200} \
  CONFIG.USER_AXI_INPUT_CLK_FREQ {450} CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]
set SAXI_ON {}
for {set i 0} {$i < 32} {incr i} {
  set on [expr {[lsearch -exact $PORTMAP $i] >= 0}]
  if {$on} { lappend SAXI_ON $i }
  set_property [format CONFIG.USER_SAXI_%02d $i] [expr {$on ? "true" : "false"}] [get_bd_cells hbm]
}
if {[llength $SAXI_ON] != 27} { error "A450BD FAIL: [llength $SAXI_ON] SAXI enabled, not 27" }
set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]
# the switch clock of each stack: any enabled port will do (all are on aclk_a).  Asked
# for after the enables (MEASURED, Task 7 pre-flight: asked for before, AXI_01 read back
# as AXI_08); whatever the IP keeps is checked to be an enabled port's ACLK.
set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_01_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_17_ACLK}] [get_bd_cells hbm]
foreach k {USER_CLK_SEL_LIST0 USER_CLK_SEL_LIST1} {
  set got [get_property CONFIG.$k [get_bd_cells hbm]]
  if {![regexp {^AXI_(\d\d)_ACLK$} $got -> cn] || [lsearch -exact $SAXI_ON [scan $cn %d]] < 0} {
    error "A450BD_CFG FAIL hbm.$k is \"$got\", not an enabled port's ACLK"
  }
  puts "A450BD_CFG hbm.$k = $got"
}
foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200 USER_HBM_REF_CLK_1 200
               USER_AXI_INPUT_CLK_FREQ 450 USER_AXI_INPUT_CLK1_FREQ 450
               USER_SWITCH_ENABLE_00 TRUE USER_SWITCH_ENABLE_01 TRUE
               USER_APB_EN false} {
  a4_want hbm $k $v
}
for {set i 0} {$i < 32} {incr i} {
  a4_want hbm [format USER_SAXI_%02d $i] [expr {[lsearch -exact $SAXI_ON $i] >= 0 ? "true" : "false"}]
}
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_0_PCLK]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/APB_1_PCLK]
connect_bd_net [get_bd_pins apb_rst/peripheral_aresetn] [get_bd_pins hbm/APB_0_PRESET_N]
connect_bd_net [get_bd_pins apb_rst/peripheral_aresetn] [get_bd_pins hbm/APB_1_PRESET_N]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins hbm/HBM_REF_CLK_1]
foreach i $SAXI_ON {
  connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins [format hbm/AXI_%02d_ACLK $i]]
  connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins [format hbm/AXI_%02d_ARESET_N $i]]
}

create_bd_cell -type module -reference a450_hbm_top top
set busif {}
for {set m 0} {$m < 27} {incr m} { lappend busif [format m%02d_axi $m] }
set busif [join $busif :]
# declared in a450_hbm_top.vhd (X_INTERFACE_PARAMETER); set here only if that did not
# take (setting it where it is read-only is CRITICAL WARNING BD 41-737), then read back
set got [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins top/aclk_a]]
if {$got ne $busif} {
  set_property CONFIG.ASSOCIATED_BUSIF $busif [get_bd_pins top/aclk_a]
  set got [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins top/aclk_a]]
}
if {$got ne $busif} { error "A450BD FAIL: top/aclk_a ASSOCIATED_BUSIF is \"$got\"" }
puts "A450BD ASSOCIATED_BUSIF top/aclk_a = 27 interfaces"
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins top/clk_core]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins top/core_rstn]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins top/aclk_a]
for {set m 0} {$m < 27} {incr m} {
  set s [lindex $PORTMAP $m]
  connect_bd_intf_net [get_bd_intf_pins [format top/m%02d_axi $m]] [get_bd_intf_pins [format hbm/SAXI_%02d $s]]
  for {set g 0} {$g < 32} {incr g} {
    assign_bd_address -target_address_space [get_bd_addr_spaces [format top/m%02d_axi $m]] \
      -offset [format 0x%X [expr {$g * 0x10000000}]] -range 256M \
      [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $s $g]]
  }
  set n [llength [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces [format top/m%02d_axi $m]]]]
  if {$n != 32} { error "A450BD FAIL: top/m[format %02d $m]_axi maps $n segments, not 32" }
}
puts "A450BD PORTMAP $PORTMAP"
create_bd_port -dir O led
connect_bd_net [get_bd_pins top/led] [get_bd_ports led]
validate_bd_design
save_bd_design
puts "A450BD_DONE"
