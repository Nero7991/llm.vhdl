#!/usr/bin/env python3
"""Derive build_fk33_i2cprobe.tcl from build_fk33_firstlight.tcl.

WHY THIS EXISTS
---------------
The FK33's board I2C bus is silent: no device ACKs anywhere in 0x08-0x77, while
the axi_iic core itself is provably healthy and the FPGA drives the LED balls in
the SAME I/O bank correctly.  See docs/debugging/2026-08-24_fk33-sysmon-vccint-
undervolt.md.  Our side is exonerated, but one question remains open and is not
answerable through axi_iic, which exposes no raw pin state:

    Is there a powered pull-up on BB24/BA24 at all?

This build answers it.  axi_iic is replaced by a dual-channel axi_gpio:

  channel 1  2 bidirectional bits on BB24 (scl) and BA24 (sda), tri-stated at
             reset so the board is never driven until we ask for it.  Release
             both and read: HIGH means a live pull-up, so the bus exists and the
             devices are elsewhere or at other addresses;  LOW or indeterminate
             means those balls are not an active I2C bus on this board and
             SQRL's script never applied to it.
  channel 2  the 7 LED bits axi_iic's GPO used to drive, kept deliberately.  The
             LEDs are our only end-to-end liveness indicator that needs no
             instrument, and this build must not lose it.

It also permits bit-banging I2C with per-bit observability, which axi_iic cannot
give, and testing whether SCL/SDA are swapped relative to SQRL's XDC.

Derived from the FIRST-LIGHT script rather than from SQRL's original because
first light is already proven to build, configure and run on this card, so the
diff under test here is exactly one peripheral swap.

Every substitution aborts loudly if its anchor stops matching, so this can never
quietly emit a build that still contains axi_iic and silently answers nothing.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "build_fk33_firstlight.tcl")
DST = os.path.join(HERE, "build_fk33_i2cprobe.tcl")
XDC_SRC = os.path.expanduser("~/GitHub/SQRL_FK33/projects/fk33_example.xdc")
XDC_DST = os.path.join(HERE, "fk33_i2cprobe.xdc")

# SQRL's XDC names for the two balls under test.  bit0 -> scl ball, bit1 -> sda
# ball, keeping SQRL's assignment so that a swap shows up as a finding rather
# than being silently absorbed here.
SCL_PIN, SDA_PIN = "BB24", "BA24"

GPIO_BLOCK = f'''# ---- I2C PROBE ------------------------------------------------------------
# axi_iic replaced by a dual-channel axi_gpio.  Channel 1 is two bidirectional
# bits on the I2C balls {SCL_PIN} (scl) / {SDA_PIN} (sda), released at reset:
# C_TRI_DEFAULT is all-ones so the pins come up as inputs and this bitstream
# cannot drive the board's bus until told to.  That matters -- if some other
# controller does own that bus, powering up driving it would be the one way to
# do real damage.  Channel 2 keeps the 7 LED bits so the board stays visibly
# controllable.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict [list CONFIG.C_GPIO_WIDTH {{2}} CONFIG.C_IS_DUAL {{1}} \\
    CONFIG.C_GPIO2_WIDTH {{7}} CONFIG.C_ALL_INPUTS {{0}} CONFIG.C_ALL_OUTPUTS {{0}} \\
    CONFIG.C_ALL_INPUTS_2 {{0}} CONFIG.C_ALL_OUTPUTS_2 {{1}} \\
    CONFIG.C_TRI_DEFAULT {{0xFFFFFFFF}} CONFIG.C_DOUT_DEFAULT {{0x00000000}} \\
    CONFIG.C_DOUT_DEFAULT_2 {{0x00000040}}] [get_bd_cells axi_gpio_0]
make_bd_intf_pins_external  [get_bd_intf_pins axi_gpio_0/GPIO]
set_property name i2cprobe [get_bd_intf_ports GPIO_0]'''

SUBS = [
    # Separate project directory, so the working first-light bitstream is not
    # clobbered and we can fall back to it at any time.
    ("set ProjectName fk33_example",
     "set ProjectName fk33_i2cprobe"),

    ("""create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0
set_property -dict [list CONFIG.C_GPO_WIDTH {7} CONFIG.C_DEFAULT_VALUE {0x40}] [get_bd_cells axi_iic_0]
make_bd_intf_pins_external  [get_bd_intf_pins axi_iic_0/IIC]
set_property name iic [get_bd_intf_ports IIC_0]""",
     GPIO_BLOCK),

    # LEDs move from the IIC GPO port to GPIO channel 2.
    ("connect_bd_net [get_bd_pins led_inv/Op1] [get_bd_pins axi_iic_0/gpo]",
     "connect_bd_net [get_bd_pins led_inv/Op1] [get_bd_pins axi_gpio_0/gpio2_io_o]"),

    ("connect_bd_intf_net [get_bd_intf_pins pcie2axil/M00_AXI] [get_bd_intf_pins axi_iic_0/S_AXI]",
     "connect_bd_intf_net [get_bd_intf_pins pcie2axil/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]"),

    ("connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins axi_iic_0/s_axi_aclk]",
     "connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk]"),
    ("connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins axi_iic_0/s_axi_aresetn]",
     "connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]"),
    ("connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_iic_0/s_axi_aclk]",
     "connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_gpio_0/s_axi_aclk]"),
    ("connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins axi_iic_0/s_axi_aresetn]",
     "connect_bd_net [get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]"),

    # Same 0x9000 base as axi_iic had, so the address map stays familiar.
    ("assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_iic_0/S_AXI/Reg}]",
     "assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]"),

    # Our own XDC: SQRL's constrains iic_scl_io/iic_sda_io, ports this build no
    # longer has.
    ("add_files -fileset constrs_1 -norecurse $scriptPath/fk33_example.xdc",
     f"add_files -fileset constrs_1 -norecurse {XDC_DST}"),
    ("set_property target_constrs_file $scriptPath/fk33_example.xdc [current_fileset -constrset]",
     f"set_property target_constrs_file {XDC_DST} [current_fileset -constrset]"),
]

if not os.path.exists(SRC):
    sys.exit(f"ABORT: first-light script not found: {SRC}\n"
             "Run gen_firstlight.py first.")
if not os.path.exists(XDC_SRC):
    sys.exit(f"ABORT: upstream XDC not found: {XDC_SRC}")

text = open(SRC).read()
for old, new in SUBS:
    if old not in text:
        sys.exit(f"ABORT: first-light script no longer contains:\n{old}\n"
                 "The generator would otherwise emit a build that still uses "
                 "axi_iic and answers nothing.")
    text = text.replace(old, new, 1)

# Guard on EXECUTABLE lines only: the explanatory comments above legitimately
# name axi_iic, and a naive substring check trips on our own prose.
_live = [l for l in text.splitlines()
         if "axi_iic" in l and not l.lstrip().startswith("#")]
if _live:
    sys.exit("ABORT: axi_iic still referenced in live Tcl after substitution:\n  " +
             "\n  ".join(_live))

header = f'''# GENERATED from build_fk33_firstlight.tcl by hw/fk33/gen_i2cprobe.py
# -- do not hand-edit; regenerate.
#
# I2C PROBE bitstream.  Identical to first light except that axi_iic is replaced
# by a dual-channel axi_gpio, giving raw control of the two I2C balls:
#
#   0x9000  GPIO_DATA   channel 1, bit0 = {SCL_PIN} (scl), bit1 = {SDA_PIN} (sda)
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
'''

open(DST, "w").write(header + text)
print(f"wrote {DST}")

# --- XDC: keep every upstream constraint except the two IIC pins, which name
# --- ports this build no longer has.
xdc = open(XDC_SRC).read()
n = 0
out = []
for line in xdc.splitlines():
    if "iic_scl_io" in line or "iic_sda_io" in line:
        out.append("# [gen_i2cprobe] superseded, port removed: " + line)
        n += 1
    else:
        out.append(line)
if n != 2:
    sys.exit(f"ABORT: expected exactly 2 iic constraint lines in {XDC_SRC}, "
             f"found {n}. Refusing to emit an XDC that may leave the probe "
             "pins unconstrained or double-constrained.")
out += [
    "",
    "############ I2C PROBE (gen_i2cprobe.py) ############",
    f"set_property -dict {{PACKAGE_PIN {SCL_PIN} IOSTANDARD LVCMOS18}} [get_ports {{i2cprobe_tri_io[0]}}] ;##was iic_scl",
    f"set_property -dict {{PACKAGE_PIN {SDA_PIN} IOSTANDARD LVCMOS18}} [get_ports {{i2cprobe_tri_io[1]}}] ;##was iic_sda",
    "",
]
open(XDC_DST, "w").write("\n".join(out) + "\n")
print(f"wrote {XDC_DST}  ({n} upstream iic constraints superseded)")
