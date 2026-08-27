#!/usr/bin/env python3
"""Derive build_fk33_pcieep.tcl from build_fk33_i2cprobe.tcl.

WHY THIS EXISTS
---------------
Nothing on this card has ever enumerated on PCIe.  Every build so far set
`EnablePCIe 0`, so the XDMA endpoint in SQRL's reference block design has never
been synthesised, let alone linked.  PCIe is the only route by which model
weights and input tokens can reach HBM, so it is the highest-risk unstarted
item in the project.  This generator produces the smallest bitstream that can
settle it: a PCIe Gen3 x4 XDMA endpoint whose DMA master reaches all 8 GB of
HBM and whose AXI-Lite master reaches SYSMON and the I2C bit-bang GPIO.

DERIVED FROM THE I2C PROBE, NOT FROM FIRST LIGHT
------------------------------------------------
Deliberately.  The probe build is the newest thing proven to build, configure
and run on this card, AND it carries the GPIO bit-bang peripheral that is the
only working way to move VCCINT.  That matters more than it looks:

    VCCINT powers up at 0.678 V, below the 0.698 V floor of the -2L grade, and
    the fix (digital-pot wiper 68 -> 0.717 V) is VOLATILE.  It is lost on every
    power cycle and has to be re-applied.

Carrying the GPIO into the PCIe build means the same pot can be driven two
ways: over JTAG before the link is up (tcl/vccint_step.tcl, unchanged), and
over the PCIe AXI-Lite BAR from the host once it is (host/fk33ctl.py).  The
second is what eventually removes JTAG from the loop entirely.

WHAT CHANGES, AND WHY EACH CHANGE
---------------------------------
 1. EnablePCIe 1.  The point of the build.

 2. Link width X1 -> X4, speed left at Gen3 8.0 GT/s.

    The PCIe hard block attaches to whole GTY quads, and the FK33's lane-to-
    quad mapping is fixed by the board.  Verified against the package file
    (Vivado's own xcvu33p_fsvh2104.pkg, MGTYRX*_2xx names), NOT assumed:

        edge lanes  0- 3  ->  GTY quad 227 (channels 3,2,1,0 -- reversed)
        edge lanes  4- 7  ->  GTY quad 226
        edge lanes  8-11  ->  GTY quad 225
        edge lanes 12-15  ->  GTY quad 224
        refclk AD8/AD9    ->  MGTREFCLK0_226

    So x4 consumes exactly quad 227 and leaves 226/225/224 -- three whole
    quads, twelve channels -- for Aurora.  x1 or x2 would free no additional
    quad, which is why the width has to be decided now and not later.

 3. Vendor and device ID overrides REMOVED, so the XDMA IP uses its own
    defaults.  SQRL sets 1E24:1533, which no stock driver has in its match
    table; the IP's defaults are exactly the IDs Xilinx's dma_ip_drivers table
    was built from.  Subsystem IDs are kept at 1E24:0001 so `lspci -nn` still
    identifies the board.  If binding still fails, `new_id` is the fallback --
    see the host plan.

 4. CLKREQ# driven LOW (asserted), not left at the xlconstant default of 1.
    CLKREQ# is active-low and the endpoint is the agent that asserts it to
    request the reference clock.  Upstream's bare `create_bd_cell xlconstant`
    leaves CONST_VAL at 1, i.e. deasserted.  On a desktop slot the refclk is
    normally free-running and this does not matter, but a host that honours
    CLKREQ# would gate the clock and the link would never train, with no
    symptom distinguishable from a dead transceiver.  Driving it low costs
    nothing and removes the failure mode.

 5. pcie2axil NUM_MI forced back to 2.  THIS IS AN UPSTREAM BUG.  SQRL's script
    sets the smartconnect to NUM_MI 2 and connects M01 to system_management_wiz,
    then inside the `EnablePCIe == 1` branch sets `NUM_SI {2} NUM_MI {1}`, which
    deletes M01 and orphans SYSMON.  It has never been caught because upstream's
    script stops after creating the project and never synthesises.  Left alone
    this build fails at address assignment or validation.

 6. LED 6 (the RGB blue) driven from xdma/user_lnk_up instead of GPIO bit 6.
    This is the only link-status indicator that needs no host, no JTAG and no
    instrument.  It matters because the alternative diagnostics are all
    downstream of the link: if the link does not train, the AXI fabric is held
    in reset and JTAG-AXI reads hang, so a dead card and an untrained link look
    identical.  Guarded: if `xdma/user_lnk_up` does not exist under this IP
    version the original wiring is kept and a warning is printed, and any
    failure mid-rewire is caught and reverted.  Set FK33_NO_LNKLED=1 to skip.

 7. Its own project directory and XDC, so the probe and first-light bitstreams
    stay intact and are always available to fall back to.

Every substitution aborts loudly if its anchor stops matching, so this can
never quietly emit a build that is still x1, or still has the NUM_MI bug.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "build_fk33_i2cprobe.tcl")
DST = os.path.join(HERE, "build_fk33_pcieep.tcl")
XDC_SRC = os.path.join(HERE, "fk33_i2cprobe.xdc")
XDC_DST = os.path.join(HERE, "fk33_pcieep.xdc")

# Ports that only exist in the EnablePCIe == 0 branch.  Left constrained they
# emit "No ports matched" warnings, which is survivable but drowns the log --
# the i2cprobe build already carries 24 of them for the PCIe lanes and they are
# exactly the kind of noise that hides a real constraint error.
NO_PCIE_ONLY_PORTS = ("sysref_clk_p", "sysref_clk_n")

LNK_LED_BLOCK = r'''
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
'''

SUBS = [
    # ---- 7. separate project + artifacts
    ("set ProjectName fk33_i2cprobe",
     "set ProjectName fk33_pcieep"),

    ("report_utilization -file fk33_firstlight_util.rpt",
     "report_utilization -file fk33_pcieep_util.rpt"),

    # ---- 1. the point of the build
    ("set EnablePCIe 0",
     "set EnablePCIe 1"),

    # ---- 2. x1 -> x4.  See the header for the quad mapping this rests on.
    ("""    set_property -dict [list CONFIG.pl_link_cap_max_link_width {X1} CONFIG.pl_link_cap_max_link_speed {8.0_GT/s}] [get_bd_cells xdma]""",
     """    # x4 Gen3 = edge lanes 0-3 = GTY quad 227, verified against Vivado's own
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
    set_property -dict [list CONFIG.xdma_rnum_chnl {1} CONFIG.xdma_wnum_chnl {1}] [get_bd_cells xdma]"""),

    # ---- 3. let the IP pick IDs the stock driver already matches
    ("""    set_property -dict [list CONFIG.vendor_id {1E24}] [get_bd_cells xdma]
    set_property -dict [list CONFIG.pf0_device_id {1533} CONFIG.PF0_DEVICE_ID_mqdma {1533} CONFIG.PF2_DEVICE_ID_mqdma {1533} CONFIG.PF3_DEVICE_ID_mqdma {1533}] [get_bd_cells xdma]""",
     """    # Vendor/device ID overrides REMOVED.  SQRL sets 1E24:1533, which is not in
    # any stock XDMA driver's match table, so the driver would silently not
    # bind and the failure would look like a broken endpoint.  The IP's own
    # defaults are the IDs Xilinx's dma_ip_drivers table was generated from.
    # Whatever it picks, read it out of the build log and out of `lspci -nn`
    # before assuming the driver will bind -- see the host plan.
    puts "FK33_PCIE_IDS vendor=[get_property CONFIG.vendor_id [get_bd_cells xdma]] device=[get_property CONFIG.pf0_device_id [get_bd_cells xdma]]\""""),

    # ---- 4. CLKREQ# asserted
    ("""    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0
    make_bd_pins_external  [get_bd_pins xlconstant_0/dout]
    set_property name pcie_clkreq [get_bd_ports dout_0]""",
     """    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0
    # CLKREQ# is ACTIVE LOW and it is the endpoint that asserts it to request
    # the reference clock.  Upstream leaves CONST_VAL at its default of 1, i.e.
    # deasserted.  Most desktop slots free-run the refclk and never look, but a
    # host that does honour it would gate the clock and the link would never
    # train -- with no symptom that separates it from a dead transceiver.
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells xlconstant_0]
    make_bd_pins_external  [get_bd_pins xlconstant_0/dout]
    set_property name pcie_clkreq [get_bd_ports dout_0]"""),

    # ---- 5. the upstream NUM_MI bug
    ("""    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]""",
     """    # NUM_MI is 2, not upstream's 1.  Upstream shrinks this smartconnect back to
    # one master AFTER system_management_wiz has already been connected to M01,
    # which deletes that port and orphans SYSMON.  The bug survives in SQRL's
    # script only because that script never synthesises -- it creates the
    # project and stops.  Left as 1, this build fails at address assignment.
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {2}] [get_bd_cells pcie2axil]"""),

    # ---- 6. link-up LED, inserted at the end of the EnablePCIe branch
    ("""    make_bd_pins_external  [get_bd_pins xdma/sys_rst_n]
    set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n_0]
    set_property name pcie_perstn [get_bd_ports sys_rst_n_0]""",
     """    make_bd_pins_external  [get_bd_pins xdma/sys_rst_n]
    set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n_0]
    set_property name pcie_perstn [get_bd_ports sys_rst_n_0]
""" + LNK_LED_BLOCK),

    # ---- 7. our own XDC
    (f"add_files -fileset constrs_1 -norecurse {XDC_SRC}",
     f"add_files -fileset constrs_1 -norecurse {XDC_DST}"),
    (f"set_property target_constrs_file {XDC_SRC} [current_fileset -constrset]",
     f"set_property target_constrs_file {XDC_DST} [current_fileset -constrset]"),
]

HEADER = '''# GENERATED from hw/fk33/build_fk33_i2cprobe.tcl by hw/fk33/gen_pcieep.py
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
#   /dev/xdma0_h2c_0      writes into HBM, file offset == HBM byte address
#   /dev/xdma0_c2h_0      reads  from HBM, same addressing
#
# HBM is flat and contiguous from the DMA master: 0x0_0000_0000 .. 0x1_FFFF_FFFF,
# 8 GB, MEM00-15 through SAXI_00 and MEM16-31 through SAXI_16, with the
# redundant cross-stack routes excluded so there is exactly one path to each.
#
# WATCH OUT -- the whole AXI fabric is clocked by xdma/axi_aclk, which is
# derived from the PCIe reference clock, and held in reset until the link is
# up.  On the bench, with no slot, there is no reference clock, so this
# bitstream is EXPECTED to look completely dead over JTAG.  That is not a
# broken build.  Use the probe bitstream for bench work.
#
'''


def main():
    if not os.path.exists(SRC):
        sys.exit(f"ABORT: probe build script not found: {SRC}\n"
                 "Run gen_i2cprobe.py first.")
    if not os.path.exists(XDC_SRC):
        sys.exit(f"ABORT: probe XDC not found: {XDC_SRC}\n"
                 "Run gen_i2cprobe.py first.")

    text = open(SRC).read()
    for old, new in SUBS:
        if old not in text:
            sys.exit("ABORT: the probe build script no longer contains:\n"
                     f"{old}\n"
                     "Refusing to emit a PCIe build whose width, IDs, CLKREQ "
                     "polarity or smartconnect fan-out may be wrong.")
        text = text.replace(old, new, 1)

    # Belt and braces on the two substitutions that would fail SILENTLY -- a
    # build that comes out x1 still links, and a build that keeps 1E24:1533
    # still enumerates, so neither would be caught by the build log.
    if "CONFIG.pl_link_cap_max_link_width {X4}" not in text:
        sys.exit("ABORT: link width did not become X4.")
    if "CONFIG.pf0_device_id {1533}" in text:
        sys.exit("ABORT: the 1533 device ID survived the substitution.")
    if "CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells pcie2axil]" in text:
        sys.exit("ABORT: the upstream pcie2axil NUM_MI bug survived.")

    open(DST, "w").write(HEADER + text)
    print(f"wrote {DST}")

    # ---- XDC ---------------------------------------------------------------
    # Two edits, both of which exist to stop this build's log filling with
    # "No ports matched" warnings that would mask a real constraint error:
    #   * lanes 4-15 do not exist on an x4 endpoint
    #   * sysref_clk_* only exists in the EnablePCIe == 0 branch
    xdc = open(XDC_SRC).read()
    out, n_lane, n_sysref = [], 0, 0
    for line in xdc.splitlines():
        drop_lane = any(f"{sig}[{i}]" in line
                        for i in range(4, 16)
                        for sig in ("pcie_rxp", "pcie_rxn",
                                    "pcie_txp", "pcie_txn"))
        drop_sysref = any(p in line for p in NO_PCIE_ONLY_PORTS)
        if drop_lane:
            out.append("# [gen_pcieep] x4 endpoint, lane not present: " + line)
            n_lane += 1
        elif drop_sysref:
            out.append("# [gen_pcieep] EnablePCIe=1, port not present: " + line)
            n_sysref += 1
        else:
            out.append(line)

    if n_lane != 48:
        sys.exit(f"ABORT: expected 48 lane constraint lines for lanes 4-15 "
                 f"(12 lanes x 4 signals), found {n_lane}. Refusing to emit an "
                 "XDC that may leave a used lane unconstrained.")
    if n_sysref != 6:
        sys.exit(f"ABORT: expected 6 sysref_clk constraint lines "
                 f"(PACKAGE_PIN, IOSTANDARD, DIFF_TERM_ADV for p and n), "
                 f"found {n_sysref}.")

    out += [
        "",
        "###############################################################################",
        "# PCIe endpoint notes (gen_pcieep.py)",
        "###############################################################################",
        "# Lanes 0-3 are edge lanes 0-3, which are GTY quad 227 channels 3,2,1,0.",
        "# Verified against Vivado's own package file:",
        "#   AL2 = MGTYRXP3_227   AM4 = MGTYRXP2_227",
        "#   AK4 = MGTYRXP1_227   AN2 = MGTYRXP0_227",
        "#   AD9/AD8 = MGTREFCLK0P/N_226",
        "# The lane order is reversed inside the quad, which is normal for a card-edge",
        "# layout; PCIe link training negotiates lane reversal, so it needs no",
        "# constraint here.  What DOES matter is that all four sit in one quad: that is",
        "# what leaves quads 226/225/224 whole for Aurora.",
        "#",
        "# The refclk is in quad 226 and feeds the block in quad 227, so this design",
        "# already depends on inter-quad reference clock routing.  If it builds, that",
        "# routing works, which is one fewer unknown for the Aurora quads later.",
        "#",
        "# CONFIGRATE 127.5 and CONFIG_MODE SPIx4 are inherited from upstream and are",
        "# there so a flash-booted FPGA is configured inside the ~100 ms PCIe gives it",
        "# after PERST# deasserts.  They are irrelevant while configuring over JTAG.",
        "",
    ]
    open(XDC_DST, "w").write("\n".join(out) + "\n")
    print(f"wrote {XDC_DST}  ({n_lane} lane + {n_sysref} sysref constraints "
          "superseded)")


if __name__ == "__main__":
    main()
