#!/usr/bin/env python3
"""Derive build_fk33_hbmbw.tcl from build_fk33_firstlight.tcl.

WHY THIS EXISTS
---------------
Every throughput figure in all five v2 design specs rests on the FK33's HBM
delivering ~460 GB/s, of which subsystem A at ROWS_IF=58 demands ~432.  That
number has never been measured on this card, and it is not a datasheet
constant: 460.8 GB/s is exactly 32 AXI ports x 32 bytes x 450 MHz, so it
assumes ALL 32 ports driven at the HBM AXI ceiling.  Whether the fabric can
actually keep 32 masters fed at 450 MHz, and what the AXI switch costs, are
open questions that only silicon answers.

Derived from FIRST LIGHT rather than from SQRL's original because first light
is already proven to build, configure and run on this card, so the diff below
is the whole risk surface.

FOUR CHANGES, and each one is load-bearing:

 1. SAXI_01..15 re-enabled.  First light disables every port except SAXI_00 and
    SAXI_16, which caps the design at two ports and ~29 GB/s -- an order of
    magnitude below the premise under test.

 2. The HBM AXI clock goes 100 MHz -> 450 MHz.  First light drives
    AXI_00/16_ACLK from clk_out1 at 100 MHz, which is right for poking
    registers over JTAG and useless for bandwidth: 16 ports x 32 B x 100 MHz is
    51.2 GB/s, so a "measurement" there would report the clock, not the memory.
    450 MHz is the frequency the 460 GB/s claim itself assumes, so measuring at
    anything less would confound "HBM cannot" with "we clocked it slow".
    NOTE the IP's own USER_AXI_INPUT_CLK_FREQ is moved to match; leaving it at
    first light's 250 while driving 450 is a silent contract violation.

 3. hbm_tg_ip (rtl/hbm_tg_ip.vhd, generated) is added with its 15 read masters
    on SAXI_01..15, each addressing its OWN 256 MB pseudo-channel.  Port-local
    because that is the access pattern subsystem A has: a contiguous weight
    shard per port.  A cross-channel or random pattern would measure a
    different machine.

    SAXI_00 is deliberately NOT used: first light already connects it to
    jtag_hbm through the pcie2hbm smartconnect, and taking it would mean
    unpicking wiring that is proven to work on this card, plus the
    exclude_seg_if block that references jtag_hbm/Data.  15 ports instead of 16
    costs nothing here -- the quantity of interest is the SHAPE of bandwidth
    against port count, and 1..15 shows it as well as 1..16 does.  Keeping
    jtag_hbm also leaves a way to read HBM directly if a result looks wrong.

 4. A CDC between the 100 MHz control domain and the 450 MHz datapath.  The
    jtag_axi master stays slow -- it only reads counters -- and a smartconnect
    does the clock conversion, which is the one thing it is genuinely good at.

WHAT IS DELIBERATELY NOT CHANGED
--------------------------------
The HBM global switch stays ENABLED, as first light has it.  Turning it off
would very likely measure faster, and that is exactly why it is not done in the
same build as everything else: this run establishes what the configuration we
already trust achieves.  Switch-off is the obvious follow-up and its value
depends on this number.

Stack 1 (SAXI_16..31) is left alone.  16 ports is half the device, and the
QUANTITY OF INTEREST IS THE SHAPE of bandwidth against port count, which one
stack shows completely.  Doubling for the second stack is then a defensible
extrapolation rather than the whole result.
"""
import re, sys, os

SRC = os.path.join(os.path.dirname(__file__), "build_fk33_firstlight.tcl")
DST = os.path.join(os.path.dirname(__file__), "build_fk33_hbmbw.tcl")
NPORT = 15   # SAXI_01..15; SAXI_00 stays with jtag_hbm, see header

src = open(SRC).read()
out = src

# ---- 1. re-enable SAXI_01..15 on stack 0 -----------------------------------
# The global-switch branch turns them all off in one dict.  Strip exactly those
# keys rather than rewriting the line, so any other setting in it survives.
before = out
for i in range(1, 16):
    out = out.replace("CONFIG.USER_SAXI_%02d {false} " % i, "")
    out = out.replace("CONFIG.USER_SAXI_%02d {false}" % i, "")
if out == before:
    sys.exit("FAIL: no USER_SAXI_xx {false} keys found; the upstream branch moved")

# ---- 2. AXI clock 100 -> 450 MHz -------------------------------------------
out = out.replace(
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {250} ] [get_bd_cells hbm]",
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {450} ] [get_bd_cells hbm]")
out = out.replace(
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {250}] [get_bd_cells hbm]",
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}] [get_bd_cells hbm]")

# a third clk_wiz output at 450 MHz for the datapath
anchor = ("set_property -dict [list CONFIG.CLKOUT2_USED {true} "
          "CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]")
if anchor not in out:
    sys.exit("FAIL: clk_wiz CLKOUT2 line not found")
out = out.replace(anchor, anchor + "\n" +
    "# hbmbw: the HBM AXI datapath clock.  450 MHz is the ceiling the 460 GB/s\n"
    "# premise assumes; measuring below it would confound the memory with the clock.\n"
    "set_property -dict [list CONFIG.CLKOUT3_USED {true} "
    "CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {450.000}] [get_bd_cells clk_wiz_0]")

# pcie2hbm carries jtag_hbm to SAXI_00/16, which are now in the fast domain
# while jtag_axi stays at 100 MHz.  Without a converter hdl generation fails
# with 41-237 FREQ_HZ mismatch.  smartconnect does the crossing; this is the
# same NUM_CLKS 2 pattern used for axil2tg.
out = out.replace(
    "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells pcie2hbm]",
    "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} "
    "CONFIG.NUM_CLKS {2}] [get_bd_cells pcie2hbm]")
n = out.count("connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2hbm/aclk]")
if n != 1:
    sys.exit("FAIL: expected one pcie2hbm/aclk connect, found %d" % n)
out = out.replace(
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2hbm/aclk]",
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins pcie2hbm/aclk]\n"
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins pcie2hbm/aclk1]")

# drive the HBM AXI clocks from clk_out3, not clk_out1
n = out.count("connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_00_ACLK]")
if n != 1:
    sys.exit("FAIL: expected exactly one AXI_00_ACLK connect, found %d" % n)
out = out.replace(
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_00_ACLK]",
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins hbm/AXI_00_ACLK]")
out = out.replace(
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins hbm/AXI_16_ACLK]",
    "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins hbm/AXI_16_ACLK]")

# ---- 3 + 4. the generator, its CDC, and the port wiring --------------------
# Inserted right before regenerate_bd_layout so every cell it references exists.
tg = ["", "# " + "-"*74,
      "# hbmbw: the traffic generator, its clock crossing, and 16 port hookups.",
      "# " + "-"*74,
      "add_files -norecurse $tgRoot/rtl/hbm_tg.vhd",
      "add_files -norecurse $tgRoot/rtl/hbm_tg_ip.vhd",
      "update_compile_order -fileset sources_1",
      "create_bd_cell -type module -reference hbm_tg_ip tg",
      "",
      "# CDC: jtag_axi runs in the 100 MHz control domain, the generator in the",
      "# 450 MHz datapath domain.  smartconnect does the conversion.",
      "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2tg",
      "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} "
      "CONFIG.NUM_CLKS {2}] [get_bd_cells axil2tg]",
      "set_property -dict [list CONFIG.NUM_MI {3}] [get_bd_cells pcie2axil]",
      "connect_bd_intf_net [get_bd_intf_pins pcie2axil/M02_AXI] "
      "[get_bd_intf_pins axil2tg/S00_AXI]",
      "connect_bd_intf_net [get_bd_intf_pins axil2tg/M00_AXI] "
      "[get_bd_intf_pins tg/s_axi]",
      "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axil2tg/aclk]",
      "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins axil2tg/aclk1]",
      "connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] "
      "[get_bd_pins axil2tg/aresetn]",
      "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins tg/clk]",
      "connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] "
      "[get_bd_pins tg/rstn]",
      "",
      "# THERMAL.  The stock design leaves DRAM_x_STAT_CATTRIP unconnected, so",
      "# the HBM stacks' own catastrophic-temperature signal goes nowhere.  This",
      "# build is the first thing on this card to drive HBM hard, so it is the",
      "# first thing that has to listen.  SYSMON's 101 C trip watches the FPGA",
      "# DIE; the die is not the stack.",
      "connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_TEMP] [get_bd_pins tg/hbm_temp0]",
      "connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_TEMP] [get_bd_pins tg/hbm_temp1]",
      "connect_bd_net [get_bd_pins hbm/DRAM_0_STAT_CATTRIP] "
      "[get_bd_pins tg/hbm_cattrip0]",
      "connect_bd_net [get_bd_pins hbm/DRAM_1_STAT_CATTRIP] "
      "[get_bd_pins tg/hbm_cattrip1]",
      "",
      "# Every ENABLED SAXI port exposes its own ACLK and ARESET_N pin, and",
      "# leaving them dangling fails hdl generation with 41-758.  Setting",
      "# USER_CLK_SEL_LIST0 to AXI_00_ACLK makes them share one clock DOMAIN;",
      "# it does not remove the pins.  First light never hit this because it",
      "# enabled two ports.",
      ]
for i in range(1, NPORT + 1):
    tg.append("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] "
              "[get_bd_pins hbm/AXI_%02d_ACLK]" % i)
    tg.append("connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] "
              "[get_bd_pins hbm/AXI_%02d_ARESET_N]" % i)
tg.append("")

# generator i drives SAXI_(i+1): see header note 3 on why SAXI_00 is skipped
for i in range(NPORT):
    tg.append("connect_bd_intf_net [get_bd_intf_pins tg/m%02d_axi] "
              "[get_bd_intf_pins hbm/SAXI_%02d]" % (i, i + 1))
tg.append("")
out = out.replace("regenerate_bd_layout", "\n".join(tg) + "\nregenerate_bd_layout", 1)

# port-local address assignment: generator i owns HBM_MEMi at i*256 MB
addr = ["", "# hbmbw: each generator addresses its OWN pseudo-channel, 256 MB at i*256 MB.",
        "# This matches the address hbm_tg emits (port index in the top bits) and it",
        "# is the access pattern subsystem A actually has.  A cross-channel map would",
        "# measure the AXI switch instead of the memory."]
# The HBM IP FIXES pseudo-channel n at n*256 MB and rejects any other offset,
# so the map is not ours to choose: channel i+1 goes at (i+1)*256 MB.  That is
# why hbm_tg carries a PORT0 generic -- generator i must emit addresses that
# already carry channel index i+1, or it cannot be mapped at all.
for i in range(NPORT):
    addr.append("assign_bd_address -offset 0x%08X -range 256M "
                "[get_bd_addr_segs {hbm/SAXI_%02d/HBM_MEM%02d}]"
                % ((i + 1) * 0x10000000, i + 1, i + 1))
# 64K range must be 64K ALIGNED -- Vivado rejects 0x0000B000 outright.  The
# generator registers therefore live at 0x00010000, clear of the first-light
# map (SYSMON 0x3000, IIC 0x9000), and the readout script must use that.
addr.append("assign_bd_address -offset 0x00010000 -range 64K "
            "[get_bd_addr_segs {tg/s_axi/reg0}]")
anchor2 = "assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_iic_0/S_AXI/Reg}]"
if anchor2 not in out:
    sys.exit("FAIL: axi_iic address anchor not found")
out = out.replace(anchor2, anchor2 + "\n".join(addr), 1)

# repoint the project name so this never overwrites the first-light artifacts
out = out.replace("set ProjectName fk33_example", "set ProjectName fk33_hbmbw", 1)
out = ("# GENERATED by hw/fk33/gen_hbmbw.py from build_fk33_firstlight.tcl\n"
       "# -- do not hand-edit; regenerate so first-light fixes are not lost.\n"
       "# See that script's header for the four changes and what is deliberately\n"
       "# left alone.\n"
       "set tgRoot /home/orencollaco/GitHub/llama.vhdl\n" + out)

open(DST, "w").write(out)
print("wrote", DST)

# Guard: the edits must be visible in the OUTPUT, checked on executable lines
# only.  An earlier generator in this repo tripped on its own comments.
code = [l for l in out.split("\n")
        if l.strip() and not l.strip().startswith("#")]
body = "\n".join(code)
checks = [
    ("SAXI_01 still disabled", "CONFIG.USER_SAXI_01 {false}" not in body),
    ("450 MHz clkout absent", "CLKOUT3_REQUESTED_OUT_FREQ {450.000}" in body),
    ("AXI clock not repointed", "clk_wiz_0/clk_out3] [get_bd_pins hbm/AXI_00_ACLK" in body),
    ("generator not added", "create_bd_cell -type module -reference hbm_tg_ip tg" in body),
    ("last port not wired", "tg/m14_axi" in body),
    ("tg regs unmapped", "tg/s_axi/reg0" in body),
    ("CATTRIP not wired", "tg/hbm_cattrip0" in body),
    ("stack temp not wired", "tg/hbm_temp0" in body),
    ("port clocks unconnected", "hbm/AXI_15_ACLK" in body),
    ("jtag_hbm CDC missing", "pcie2hbm/aclk1" in body),
]
bad = [n for n, ok in checks if not ok]
if bad:
    sys.exit("GUARD FAILED: " + "; ".join(bad))
print("guard: all %d edits present" % len(checks))
