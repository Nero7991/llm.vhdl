# hw/jc/a450/a450_bd.tcl -- block design of the a450 A+HBM timing design (plan
# 2026-11-12-a450-per-port-tiles Task 7, spec 3.2 gate 2).  Sourced by build_a450.tcl.
#
#   sysclk (200 MHz LVDS, BC26/BC27) -> clk_wiz_0: clk_out1 100 (HBM APB), clk_out2 200
#   (HBM ref), clk_out3 125 (clk_core) -> clk_wiz_a: clk_out1 450 (aclk_a), from clk_out2.
#   hbm: 2 stacks, all 32 SAXI on aclk_a at USER_AXI_INPUT_CLK_FREQ 450 (PG276: the switch
#   runs on an AXI port clock, so every port moves with A).
#   top (a450_hbm_top): m00..m23 weight ports, m24..m26 scale ports, on hbm/SAXI_nn per
#   gen_pcieep.ENG_PORT_MAP's first 27 entries (the card's own map).
#   Task 9b: the split-on card's aclk_a-side IP on the card's own ports, so the gate times
#   what the card places beside A (docs/debugging/2026-11-15_a450-card-split-timing.md,
#   fix 7).  Each of the card's other HBM masters is an a450_tg on clk_core (top/x_*_axi),
#   behind the card's IP, IP_CHAIN below: an axi_clock_converter (clk_core -> aclk_a) and
#   an axi_register_slice on aclk_a in front of SAXI 00 (loader), 29 (A's descriptor
#   fetch), 30 and 31 (the B/C grant's pool); and on SAXI 16 the two-clock smartconnect
#   hbm_sc (S00 a jtag_axi exactly as the card's jtag_hbm, S01/S02 the ctl and tok read
#   masters) and a register slice.  All 32 SAXI are enabled, as on the card, and the
#   switch clocks are the card's (AXI_00, AXI_16).  The CONFIG values of the converters,
#   slices and smartconnect are the card's (hw/jc/card/gen_jc_card.py; test_a450.py pins
#   them equal).
# Every CONFIG this file sets is read back (a set_property on a name the object lacks is
# silent).  Sentinels: A450BD_CFG lines, A450BD_RESET (the reset tree's propagated polarity),
# A450BD_DONE; failures are Tcl errors.
create_bd_design a450

proc a4_want {cell key want} {
  set got [get_property CONFIG.$key [get_bd_cells $cell]]
  if {[string toupper $got] ne [string toupper $want]} {
    error "A450BD_CFG FAIL $cell.$key is \"$got\", not \"$want\""
  }
  puts "A450BD_CFG $cell.$key = $got"
}

set PORTMAP {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 17 18 19 20 21 22 23 24 25 26 27 28}
# {source interface, converter, register slice, SAXI}: the card's names and ports
set IP_CHAIN {
  top/x_ld_axi  ld_cdc  ld_rs  0
  top/x_d_axi   d_cdc   d_rs   29
  top/x_bc0_axi bc_cdc0 bc_rs0 30
  top/x_bc1_axi bc_cdc1 bc_rs1 31
}
set SC_SAXI 16

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
# THE RESET TREE: the split-on card's (hw/jc/card/gen_jc_card.py, a450 Task 9 fix; final
# review I3; test_a450.py pins the connections equal).  aclk_reset takes BOTH locks through
# lock_and, and core_reset DESCENDS from it: its ext_reset_in is aclk_reset's
# peripheral_aresetn and its dcm_locked a constant 1.  So the gate times the card's rst ->
# ar1 source and fan-out, not a sibling reset released on clk_wiz_0's lock alone.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 lock_and
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] [get_bd_cells lock_and]
foreach {k v} {C_SIZE 1 C_OPERATION and} { a4_want lock_and $k $v }
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins lock_and/Op1]
connect_bd_net [get_bd_pins clk_wiz_a/locked] [get_bd_pins lock_and/Op2]
connect_bd_net [get_bd_pins lock_and/Res] [get_bd_pins aclk_reset/dcm_locked]
connect_bd_net [get_bd_pins one/dout] [get_bd_pins aclk_reset/ext_reset_in]
connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins core_reset/ext_reset_in]
connect_bd_net [get_bd_pins one/dout] [get_bd_pins core_reset/dcm_locked]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins apb_rst/dcm_locked]
connect_bd_net [get_bd_pins one/dout] [get_bd_pins apb_rst/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins aclk_reset/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins apb_rst/slowest_sync_clk]

create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm
set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \
  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200} \
  CONFIG.USER_AXI_INPUT_CLK_FREQ {450} CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}] [get_bd_cells hbm]
set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]
set SAXI_ON $PORTMAP
foreach {- - - n} $IP_CHAIN { lappend SAXI_ON $n }
lappend SAXI_ON $SC_SAXI
set SAXI_ON [lsort -integer $SAXI_ON]
for {set i 0} {$i < 32} {incr i} {
  set on [expr {[lsearch -exact $SAXI_ON $i] >= 0}]
  set_property [format CONFIG.USER_SAXI_%02d $i] [expr {$on ? "true" : "false"}] [get_bd_cells hbm]
}
if {[llength $SAXI_ON] != 32} { error "A450BD FAIL: [llength $SAXI_ON] SAXI enabled, not 32" }
set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]
# the switch clock of each stack: the card's (AXI_00, AXI_16; all ports are on aclk_a).
# Asked for after the enables (MEASURED, Task 7 pre-flight: asked for before, AXI_01 read
# back as AXI_08), and read back exactly.
set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]
a4_want hbm USER_CLK_SEL_LIST0 AXI_00_ACLK
a4_want hbm USER_CLK_SEL_LIST1 AXI_16_ACLK
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
# the HBM ports' ARESET_N into A's owed-burst clear (mv4i_tiled hbm_aresetn), as the card
# wires eng/hbm_aresetn (final review I3): live nets into mv_rdfsm, not constants
connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins top/hbm_aresetn]
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

# ---- Task 9b: the card's aclk_a-side IP -------------------------------------------------
# the CONFIG of each, the card's (gen_jc_card.py RS_CONFIG / ip_chain_lines; pinned equal by
# test_a450.py)
proc a4_rs {name} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $name
  set_property -dict [list CONFIG.PROTOCOL {AXI3} CONFIG.REG_AW {1} CONFIG.REG_AR {1} CONFIG.REG_W {1} CONFIG.REG_R {1} CONFIG.REG_B {1}] [get_bd_cells $name]
  foreach {k v} {PROTOCOL AXI3 REG_AW 1 REG_AR 1 REG_W 1 REG_R 1 REG_B 1} { a4_want $name $k $v }
  connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins $name/aclk]
  connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins $name/aresetn]
}
proc a4_seg32 {sp n} {
  for {set g 0} {$g < 32} {incr g} {
    assign_bd_address -target_address_space [get_bd_addr_spaces $sp] \
      -offset [format 0x%X [expr {$g * 0x10000000}]] -range 256M \
      [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $n $g]]
  }
  set k [llength [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]]]
  if {$k != 32} { error "A450BD FAIL: $sp maps $k segments, not 32" }
}
set busc [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins top/clk_core]]
foreach i {x_ld_axi x_d_axi x_bc0_axi x_bc1_axi x_ctl_axi x_tok_axi} {
  if {[lsearch -exact [split $busc :] $i] < 0} { error "A450BD FAIL: top/clk_core ASSOCIATED_BUSIF \"$busc\" lacks $i" }
}
puts "A450BD ASSOCIATED_BUSIF top/clk_core = $busc"
foreach {src cc rs n} $IP_CHAIN {
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 $cc
  set pr [get_property CONFIG.PROTOCOL [get_bd_intf_pins $src]]
  set_property CONFIG.PROTOCOL $pr [get_bd_cells $cc]
  a4_want $cc PROTOCOL $pr
  if {$pr ne "AXI3"} { error "A450BD FAIL: $src PROTOCOL is $pr, not AXI3 (the card's loader/eng/grant shape)" }
  connect_bd_intf_net [get_bd_intf_pins $src] [get_bd_intf_pins $cc/S_AXI]
  connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins $cc/s_axi_aclk]
  connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins $cc/s_axi_aresetn]
  connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins $cc/m_axi_aclk]
  connect_bd_net [get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins $cc/m_axi_aresetn]
  a4_rs $rs
  connect_bd_intf_net [get_bd_intf_pins $cc/M_AXI] [get_bd_intf_pins $rs/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins $rs/M_AXI] [get_bd_intf_pins [format hbm/SAXI_%02d $n]]
  a4_seg32 $src $n
  puts "A450BD IP $src -> $cc -> $rs -> SAXI_[format %02d $n]"
}
# SAXI 16: jtag_hbm, the ctl and tok read masters -> hbm_sc (two clocks) -> sc_rs
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_hbm
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]
a4_want jtag_hbm M_AXI_ADDR_WIDTH 64
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins jtag_hbm/aclk]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins jtag_hbm/aresetn]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hbm_sc
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells hbm_sc]
foreach {k v} {NUM_SI 3 NUM_MI 1 NUM_CLKS 2} { a4_want hbm_sc $k $v }
connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins hbm_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins top/x_ctl_axi] [get_bd_intf_pins hbm_sc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins top/x_tok_axi] [get_bd_intf_pins hbm_sc/S02_AXI]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins hbm_sc/aclk]
connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins hbm_sc/aresetn]
connect_bd_net [get_bd_pins clk_wiz_a/clk_out1] [get_bd_pins hbm_sc/aclk1]
a4_rs sc_rs
connect_bd_intf_net [get_bd_intf_pins hbm_sc/M00_AXI] [get_bd_intf_pins sc_rs/S_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_rs/M_AXI] [get_bd_intf_pins [format hbm/SAXI_%02d $SC_SAXI]]
foreach sp {jtag_hbm/Data top/x_ctl_axi top/x_tok_axi} { a4_seg32 $sp $SC_SAXI }
puts "A450BD IP jtag_hbm,top/x_ctl_axi,top/x_tok_axi -> hbm_sc -> sc_rs -> SAXI_[format %02d $SC_SAXI]"
create_bd_port -dir O led
connect_bd_net [get_bd_pins top/led] [get_bd_ports led]
validate_bd_design
# the reset tree's propagated polarity, read after validation as the card reads it
# (gen_jc_card.reset_polarity_lines): C_EXT_RESET_HIGH is BD-propagated, and a 1 on
# core_reset would invert A's reset against the HBM ports'
foreach r {core_reset aclk_reset} {
  set erh [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells $r]]
  if {$erh ne "0"} { error "A450BD_RESET FAIL $r CONFIG.C_EXT_RESET_HIGH is \"$erh\", not 0" }
  puts "A450BD_RESET $r C_EXT_RESET_HIGH $erh"
}
save_bd_design
puts "A450BD_DONE"
