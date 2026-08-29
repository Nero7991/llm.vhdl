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

 9. A FREE-RUNNING AUX DOMAIN, on the 200 MHz board oscillator (BC26/BC27).

    This is the change that makes the bitstream diagnosable when the link is
    down, and it rests on a correction.  A first-fit handoff assumed the ILA
    debug hub survived a dead link because the XDC clocks it from
    `hbm/.../APB_0_PCLK`.  Reading the generator refutes that without a card:
    inside the `EnablePCIe == 1` branch upstream writes

        connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins clk_wiz_0/clk_in1]
        connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins clk_wiz_0/resetn]

    so APB_0_PCLK is an MMCM output whose reference is xdma/axi_aclk and whose
    MMCM is held in reset by xdma/axi_aresetn.  Nothing in the shipped endpoint
    design survives the link being down.

    The FK33 does carry a clock that does: the 200 MHz oscillator on BC26/BC27,
    which is the ONLY clock every EnablePCIe == 0 bitstream in this repository
    has ever used, and all of those have run on this card with no host.  The aux
    domain takes it through a plain BUFG -- no MMCM, so nothing to lock and
    nothing anyone can hold in reset -- and carries:

      * a frequency measurement of the PCIe user clock which, read together
        with the PERST# level, separates "the PCH gated the SRC clock", "we are
        simply held in reset" and "clocked but never trained" -- three cases
        that today all present as the same -1;
      * PERST#, its stickies, and the millisecond timestamp of its first
        deassertion relative to configuration, which is the only way to measure
        the flash-boot configuration-time race from inside the part;
      * xdma/axi_aresetn and user_lnk_up;
      * a third JTAG-AXI master, `jtag_aux`, whose whole branch is clocked by
        the aux domain and touches nothing xdma drives.  That is the structural
        proof that the read path avoids xdma/axi_aclk: there is no wire between
        them, not a constraint saying there should not be.
      * an autonomous VCCINT controller.  See item 10.

    The debug hub's clock moves onto the same domain, because a hub clocked off
    a stopped MMCM cannot answer either.

10. AN AUTONOMOUS VCCINT CONTROLLER, hardcoded to wiper 68 (0.717 V).

    Obstacle 2 of the handoff: the pot needs the probe bitstream's GPIO, and the
    probe bitstream has no PCIe.  On a free-running clock that dissolves -- the
    state machine in rtl/fk33_aux.vhd bit-bangs the same I2C sequence
    tcl/vccint_step.tcl uses, a few milliseconds after configuration, with no
    AXI, no JTAG and no host.  The wiper value is a constant in the RTL and
    appears in exactly one place, so the controller is structurally incapable of
    writing anything else and therefore incapable of overshooting.  It is NOT
    0.850 V and must never become it.  The AXI GPIO path is untouched, so
    host/fk33ctl.py vccint still works once a link is up.

11. THERMAL PROTECTION, and it is the first of any kind in this design.

    Before this, nothing in the bitstream compared a temperature against a
    limit.  SYSMON was a register the host could read at 0x3400, and the HBM
    stacks' own temperature and catastrophic-trip outputs were left dangling.

    The silicon's OT alarm is not a substitute.  It IS armed -- the SYSMONE4
    primitive only accepts an OT limit when the low nibble of register 53h is
    0011, which is itself the automatic-shutdown enable, and
    system_management_wiz forces that nibble unconditionally -- but SQRL sets it
    to 101 C, DS890 Table 33 gives -2LE a sustained Tj of 100 C and recommends a
    maximum of 95 C for the HBM, and its consequence is a shutdown that takes
    the card off the PCIe bus.  It fires after the part is out of spec and it
    makes the card undiagnosable when it does.

    So rtl/fk33_thermal.vhd sits on the free-running aux domain and halts the
    COMPUTE datapath at die 90 C / HBM code 85, resuming at 75 / 70, while
    leaving the link, the AXI fabric, the aux domain and every status register
    alive.  Its sensors:

      * SYSMON temp_out[9:0] (CONFIG.ENABLE_TEMP_BUS, which upstream leaves
        false), plus ot_out and user_temp_alarm_out as two INDEPENDENT hardware
        comparators, the second retuned to the same 90/75 points;
      * hbm/DRAM_x_STAT_TEMP and DRAM_x_STAT_CATTRIP, which need no IP
        reconfiguration at all and were simply never connected.

    Every sensor carries a liveness watchdog and a plausibility band as well as
    a threshold, because a stuck-at-zero sensor and a very cold card produce the
    same value; an invalid sensor is treated as HOT, so the guard comes up
    halted and only releases once it has seen a temperature.  Five status words
    are readable BOTH over jtag_aux with the link down and over the AXI-Lite
    BAR.  Full derivation and the datasheet numbers:
    docs/debugging/2026-08-28_fk33-thermal-protection.md.

Every substitution aborts loudly if its anchor stops matching, so this can
never quietly emit a build that is still x1, or still has the NUM_MI bug.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "build_fk33_i2cprobe.tcl")
DST = os.path.join(HERE, "build_fk33_pcieep.tcl")
XDC_SRC = os.path.join(HERE, "fk33_i2cprobe.xdc")
XDC_DST = os.path.join(HERE, "fk33_pcieep.xdc")
AUX_RTL = os.path.join(HERE, "rtl", "fk33_aux.vhd")
THERM_RTL = os.path.join(HERE, "rtl", "fk33_thermal.vhd")

# Ports that only exist in the EnablePCIe == 0 branch.  Left constrained they
# emit "No ports matched" warnings, which is survivable but drowns the log --
# the i2cprobe build already carries 24 of them for the PCIe lanes and they are
# exactly the kind of noise that hides a real constraint error.
#
# sysref_clk_p/n USED to be in here.  It is not any more: the aux domain
# instantiates the same IBUFDS the EnablePCIe == 0 branch does, with the same
# external interface name, so those ports exist again and must stay constrained.
NO_PCIE_ONLY_PORTS = ()

# ---------------------------------------------------------------------------
# Bring-up peripherals.  None of this is in SQRL's design.
#
# The identity word is ASCII "FK33" so a correct read is recognisable in a hex
# dump and cannot be confused with a bus returning all-ones, all-zeroes, or a
# stale value left by some other design.  The build word is the date in BCD so
# that a card configured with an old bitstream is visible as such from the host
# without touching JTAG.
#
# Both are computed here rather than written as hex literals in the Tcl,
# because xlconstant's CONST_VAL is a numeric parameter and Vivado's handling
# of a "0x..." string in it is not something worth finding out on a build that
# costs an hour.
ID_MAGIC = 0x464B3333          # "FK33"
ID_BUILD = 0x20260828          # yyyymmdd, BCD.  SEE THE CHECK BELOW.

# THE TWO BUILD STAMPS MUST AGREE, AND ON 2026-08-28 THEY DID NOT.
#
# `ID_BUILD` here feeds the id_build constant at AXI-Lite 0xA008, which is what
# `host/fk33ctl.py id` prints as the bitstream's identity.  `C_VERSION` in
# rtl/fk33_aux.vhd feeds AUX_VERSION at the aux base, which is what
# tcl/aux_probe.tcl prints.  They are set independently, and the aux work
# updated one and not the other, so a card running the THERMAL bitstream
# reported `id build 0x20260827` over PCIe and `AUX_VERSION 0x20260828` over
# JTAG at the same moment.
#
# That is not cosmetic.  Three bitstreams were in play that day
# (fk33_pcieep, _aux, _therm) and the id stamp read identically for all of
# them, so the one register whose job is to say WHICH bitstream is loaded
# would have answered wrongly if it had been asked.
#
# Rather than keep two hand-maintained dates in step by discipline, the
# generator now REFUSES to emit a build when they disagree.  Bump both, or
# neither.

# AXI-Lite BAR is 128 KB (0x00000 .. 0x1FFFF).  Existing occupants: SYSMON at
# 0x3000 and the I2C/LED GPIO at 0x9000, both 4 KB.
ID_BASE = 0x0000A000
SCRATCH_BASE = 0x00010000
SCRATCH_SIZE = "8K"
# The DMA BRAM sits ABOVE the 8 GB of HBM in the DMA master's space, so it can
# never be confused with an HBM address and an off-by-one in a host-side offset
# calculation lands on nothing rather than silently in memory.
DMABRAM_BASE = 0x200000000
DMABRAM_SIZE = "64K"

# Thermal registers.  Two views of the SAME five words:
#   on jtag_aux, readable with the PCIe link DOWN, and
#   on the AXI-Lite BAR, readable by the host.
# The AUX_* bases are in jtag_aux's own address space and never appear on the
# BAR; the THERM_* bases are on the BAR and never appear on jtag_aux.
AUX_THERM_BASE  = 0x00004000
AUX_PEAK_BASE   = 0x00005000
AUX_CTL_BASE    = 0x00006000
THERM_BASE      = 0x0000B000
THERMP_BASE     = 0x0000C000
THERMC_BASE     = 0x0000D000
# Written to THERM_CTL[31:16] or the write is ignored.  A clear must be
# deliberate, and a stray MMIO write must not be able to erase a thermal record.
THERM_CTL_KEY   = 0xC1EA
# The reviewed thresholds, repeated here ONLY so the host can report what the
# bitstream is enforcing.  rtl/fk33_thermal.vhd is the authority: these are
# checked against it in main() and the build aborts if they disagree.
# ---------------------------------------------------------------------------
# SUBSYSTEM A ON THE CARD (gen_pcieep.py, 2026-08-29).
#
# Everything from here to ENGINE_ADDR exists to answer one question that no
# out-of-context run can: what does subsystem A cost, and what does it close
# at, WITH the HBM IP, the XDMA shell, the aux domain and the thermal guard
# present and after place and route.
#
# THE PORT ASSIGNMENT.  28 masters -- 24 weight lanes, 3 scale lanes and the
# descriptor fetch -- one per HBM SAXI port:
#
#     m00..m14  ->  SAXI_01..SAXI_15   (stack 0, 15 ports)
#     m15..m27  ->  SAXI_17..SAXI_29   (stack 1, 13 ports)
#
# SAXI_00 and SAXI_16 stay with the host, one per stack, exactly as before.
# SAXI_30 and SAXI_31 are left DISABLED: they are the two spare engine ports
# docs/2026-08-27_hbm-port-contention.md budgets for B and C.
#
# This split is forced, not chosen.  A stack offers at most 15 engine ports
# after the host takes one, and A needs 28, so no assignment of A's masters
# fits inside one stack.  TRACK HBM-PLACE established the consequence
# (docs/debugging/2026-08-28_hbm-stack-boundary-straddle.md section 3): under
# the FLAT packed layout every one of a tensor's 27 sub-regions sits within a
# few hundred MB of the others, i.e. in ONE stack, so at least 13 of the 28
# masters read cross-stack on every tensor.  The 27-lane arena layout is the
# answer to that and it needs a build-time lane -> port -> pseudo-channel
# table that no bitstream in this repo has.  THAT IS A DECISION FOR OREN AND
# IS NOT MADE HERE.  What this build does is the only thing that keeps both
# options open: every engine port is given all 32 segments, so the flat layout
# works today and an arena layout would only ever REMOVE segments.
#
# THE CLOCKS.  Two, and the choice is the whole measurement:
#
#   HBM AXI  xdma/axi_aclk, 250 MHz, the same net that already clocks SAXI_00
#            and SAXI_16.  Using one clock for the entire HBM AXI side means
#            this build asks no new question about mixed per-port clocks.
#   core     clk_wiz_0/clk_out3, 200 MHz.
#
# Because 27 x 256 bits is 864 B exactly, the duty identity has no efficiency
# term: duty = f_core / f_axi = 200/250 = 80.0%.  Running the core at the HBM
# clock would be 100% with zero margin, which
# docs/2026-08-28_can-27-read-masters-be-served.md section 4.3 already
# rejected.  The OOC ceilings this is measured against are 257.33 MHz (AXI)
# and 230.73 MHz (core), so 250/200 sits 2.8% and 13.3% below them.  If the
# AXI side misses, the fix direction is a dedicated slower HBM clock through
# pcie2hbm with NUM_CLKS 2 -- which build_fk33_hbmbw.tcl:136 already does --
# and it is deliberately NOT pre-applied here, because a build that misses at
# 250 MHz measures the routing cost and a build that is pre-slowed does not.
ENG_CELL       = "eng"
ENG_NMAST      = 28
ENG_CTL_BASE   = 0x00012000    # 4 KB, the engine's own register map.
ENG_XW_BASE    = 0x00013000    # 4 KB, the activation writer
ENG_CORE_MHZ   = 200.000
# m00..m27 -> HBM SAXI port index.  Written out rather than computed so the
# mapping is greppable and a future arena table has one place to change.
ENG_PORT_MAP   = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29]

THERM_DIE_WARN_C   = 80
THERM_DIE_HALT_C   = 90
THERM_DIE_RESUME_C = 75
THERM_HBM_WARN_C   = 75
THERM_HBM_HALT_C   = 85
THERM_HBM_RESUME_C = 70


assert len(ENG_PORT_MAP) == ENG_NMAST, "port map length"
assert len(set(ENG_PORT_MAP)) == ENG_NMAST, "port map has a duplicate"
assert 0 not in ENG_PORT_MAP and 16 not in ENG_PORT_MAP, \
    "SAXI_00 and SAXI_16 belong to the host"
assert all(1 <= x <= 31 for x in ENG_PORT_MAP), "port index out of range"

ID_BASE_H = "0x%08X" % ID_BASE
SCRATCH_BASE_H = "0x%08X" % SCRATCH_BASE
DMABRAM_BASE_H = "0x%X" % DMABRAM_BASE

BRINGUP_BLOCK = f'''
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
#                  and no earlier test can change it.  Reading {ID_MAGIC:#010x}
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
set_property -dict [list CONFIG.CONST_WIDTH {{32}} CONFIG.CONST_VAL {{{ID_MAGIC}}}] [get_bd_cells id_magic]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 id_build
set_property -dict [list CONFIG.CONST_WIDTH {{32}} CONFIG.CONST_VAL {{{ID_BUILD}}}] [get_bd_cells id_build]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_id
set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
    CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{1}} CONFIG.C_ALL_INPUTS_2 {{1}} \\
    CONFIG.C_ALL_OUTPUTS {{0}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
    CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells fk33_id]
connect_bd_net [get_bd_pins id_magic/dout] [get_bd_pins fk33_id/gpio_io_i]
connect_bd_net [get_bd_pins id_build/dout] [get_bd_pins fk33_id/gpio2_io_i]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_scratch
set_property -dict [list CONFIG.DATA_WIDTH {{32}} CONFIG.SINGLE_PORT_BRAM {{1}} \\
    CONFIG.ECC_TYPE {{0}}] [get_bd_cells fk33_scratch]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_scratch_ram
set_property -dict [list CONFIG.Memory_Type {{Single_Port_RAM}}] [get_bd_cells fk33_scratch_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_scratch/BRAM_PORTA] [get_bd_intf_pins fk33_scratch_ram/BRAM_PORTA]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fk33_dmabram
set_property -dict [list CONFIG.DATA_WIDTH {{128}} CONFIG.SINGLE_PORT_BRAM {{1}} \\
    CONFIG.ECC_TYPE {{0}}] [get_bd_cells fk33_dmabram]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 fk33_dmabram_ram
set_property -dict [list CONFIG.Memory_Type {{Single_Port_RAM}}] [get_bd_cells fk33_dmabram_ram]
connect_bd_intf_net [get_bd_intf_pins fk33_dmabram/BRAM_PORTA] [get_bd_intf_pins fk33_dmabram_ram/BRAM_PORTA]

# Grow the two smartconnects rather than setting an absolute NUM_MI, so this
# stays correct if a later edit adds a master port before this point.  Growing
# is safe; SHRINKING deletes ports and silently orphans whatever was on them,
# which is exactly the upstream bug fixed above.
set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {{$n + 2}}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \\
                    [get_bd_intf_pins fk33_id/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {{$n + 1}}]]] \\
                    [get_bd_intf_pins fk33_scratch/S_AXI]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2hbm]]
set_property CONFIG.NUM_MI [expr {{$n + 1}}] [get_bd_cells pcie2hbm]
connect_bd_intf_net [get_bd_intf_pins pcie2hbm/[format M%02d_AXI $n]] \\
                    [get_bd_intf_pins fk33_dmabram/S_AXI]

connect_bd_net [get_bd_pins fk33_id/s_axi_aclk]         [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_id/s_axi_aresetn]      [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aclk]    [get_bd_pins pcie2axil/aclk]
connect_bd_net [get_bd_pins fk33_scratch/s_axi_aresetn] [get_bd_pins pcie2axil/aresetn]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aclk]    [get_bd_pins pcie2hbm/aclk]
connect_bd_net [get_bd_pins fk33_dmabram/s_axi_aresetn] [get_bd_pins pcie2hbm/aresetn]
# ---- end bring-up peripherals ---------------------------------------------

'''

BRINGUP_ADDR = f'''
# ---- bring-up peripheral address map (gen_pcieep.py) -----------------------
# On the AXI-Lite BAR, which the XDMA IP sizes at 128 KB.  Everything here must
# fit in 0x00000..0x1FFFF or address assignment fails.
assign_bd_address -offset {ID_BASE_H}  -range 4K  [get_bd_addr_segs {{fk33_id/S_AXI/Reg}}]
assign_bd_address -offset {SCRATCH_BASE_H}  -range {SCRATCH_SIZE}  [get_bd_addr_segs {{fk33_scratch/S_AXI/Mem0}}]
# On the DMA master, deliberately ABOVE the 8 GB of HBM so a bad host offset
# lands on nothing rather than silently in memory.  Left visible to jtag_hbm as
# well as to xdma/M_AXI, so the same bytes can be read back over JTAG -- which
# is what separates "XDMA wrote the wrong thing" from "the readback is wrong".
assign_bd_address -offset {DMABRAM_BASE_H} -range {DMABRAM_SIZE} [get_bd_addr_segs {{fk33_dmabram/S_AXI/Mem0}}]
'''

# ---------------------------------------------------------------------------
# The aux domain.  Everything below this comment runs on the FK33's 200 MHz
# board oscillator and has NO connection of any kind to xdma/axi_aclk or
# xdma/axi_aresetn.  That absence of a wire is the whole guarantee; see the
# module header in rtl/fk33_aux.vhd.
AUX_CELLS = ("aux_id", "aux_clkst", "aux_stat", "aux_time",
             "aux_therm", "aux_peak")
# aux_ctl is created separately: it is the only aux register with an OUTPUT
# channel (the thermal clear), so it cannot come out of the all-inputs loop.
AUX_CELLS_ALL = AUX_CELLS + ("aux_ctl",)
# Thermal registers on the PCIe AXI-Lite BAR.  fk33_thermc likewise carries the
# clear as an output channel.
THERM_PCIE_CELLS = ("fk33_therm", "fk33_thermp", "fk33_thermc")

AUX_BLOCK = f'''
# ---- FREE-RUNNING AUX DOMAIN (gen_pcieep.py) ------------------------------
# Read the header of gen_pcieep.py, item 9, before changing anything here.  In
# short: in this bitstream the clock the debug hub uses is an MMCM output whose
# reference is xdma/axi_aclk and whose MMCM is held in reset by
# xdma/axi_aresetn, so NOTHING in the shipped design survives the link being
# down.  The 200 MHz oscillator on BC26/BC27 does, and is the only clock every
# EnablePCIe == 0 bitstream in this repository has ever run from.
if {{$EnablePCIe != 1}} {{
    error "the aux block assumes EnablePCIe 1, and this generated script is only ever built that way"
}}

create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_1
set_property -dict [list CONFIG.C_BUF_TYPE {{IBUFDS}}] [get_bd_cells util_ds_buf_1]
make_bd_intf_pins_external  [get_bd_intf_pins util_ds_buf_1/CLK_IN_D]
set_property name sysref [get_bd_intf_ports CLK_IN_D_0]
set_property -dict [list CONFIG.FREQ_HZ {{200000000}}] [get_bd_intf_ports sysref]

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
if {{[llength $auxlnk]}} {{
    connect_bd_net $auxlnk [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up wired into the aux status word"
}} else {{
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 aux_lnk_stub
    set_property -dict [list CONFIG.CONST_WIDTH {{1}} CONFIG.CONST_VAL {{0}}] [get_bd_cells aux_lnk_stub]
    connect_bd_net [get_bd_pins aux_lnk_stub/dout] [get_bd_pins fk33_aux_0/user_lnk_up]
    puts "FK33_AUX LNK user_lnk_up ABSENT on this IP version, status bit tied 0"
}}

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
set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {{32}} CONFIG.M_AXI_ADDR_WIDTH {{32}} \\
    CONFIG.M_HAS_BURST {{0}}] [get_bd_cells jtag_aux]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 auxconnect
set_property -dict [list CONFIG.NUM_SI {{1}} CONFIG.NUM_MI {{6}}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins jtag_aux/M_AXI] [get_bd_intf_pins auxconnect/S00_AXI]

set auxi 0
foreach c {{{" ".join(AUX_CELLS)}}} {{
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 $c
    set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
        CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{1}} CONFIG.C_ALL_INPUTS_2 {{1}} \\
        CONFIG.C_ALL_OUTPUTS {{0}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
        CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells $c]
    connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $auxi]] \\
                        [get_bd_intf_pins $c/S_AXI]
    connect_bd_net [get_bd_pins $c/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]
    connect_bd_net [get_bd_pins $c/s_axi_aresetn] [get_bd_pins fk33_aux_0/aux_aresetn]
    incr auxi
}}

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

'''

AUX_ADDR = '''
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
'''

THERM_BLOCK = f'''
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
connect_bd_net [get_bd_pins system_management_wiz_0/temp_out] \\
               [get_bd_pins fk33_therm_0/sysmon_temp]
connect_bd_net [get_bd_pins system_management_wiz_0/ot_out] \\
               [get_bd_pins fk33_therm_0/sysmon_ot]
connect_bd_net [get_bd_pins system_management_wiz_0/user_temp_alarm_out] \\
               [get_bd_pins fk33_therm_0/sysmon_alarm]
# eoc_out is the LIVENESS source, and it is the reason a stuck ADC is caught.
# A value comparison alone cannot tell a frozen sensor from a cold card.
connect_bd_net [get_bd_pins system_management_wiz_0/eoc_out] \\
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

# The compute domain.  compute_halt IS CONNECTED as of 2026-08-29: it reaches
# subsystem A in ENGINE_BLOCK below.  The canary stays and is now doubly
# useful, because it counts toggles of THE ENGINE'S OWN CORE CLOCK -- so
# THERM_CANARY answers "is the compute domain clocked and un-halted" over JTAG
# with the PCIe link down, about the real datapath rather than about a stand-in.
#
# What the halt does to the engine, stated here because the contract is in this
# module's header and the implementation is in rtl/fk33_engine.vhd: it masks
# the GO bit of an AXI-Lite write, so no NEW job can start.  A job already
# running is not disturbed and runs to completion, which is what retires every
# AXI burst it has already issued.  Abandoning an accepted burst would hang
# that HBM channel permanently.
# compute_clk is the ENGINE'S CORE CLOCK (clk_wiz_0/clk_out3), not
# xdma/axi_aclk.  It was xdma/axi_aclk only because there was no compute
# datapath; now there is, and fk33_thermal's contract is that compute_halt is
# SYNCHRONOUS TO compute_clk.  Driving it from a clock the datapath does not
# use would hand the engine an unsynchronised halt, which is precisely the
# torn-word failure this module's own host_* outputs exist to avoid.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins fk33_therm_0/compute_clk]
connect_bd_net [get_bd_pins xdma/axi_aclk] [get_bd_pins fk33_therm_0/ctl_host_clk]

# ---- thermal registers on the AUX (JTAG) side -----------------------------
# aux_therm and aux_peak come out of the all-inputs loop above.  aux_ctl is the
# only aux register with an OUTPUT channel, so it is built here.  Its
# C_DOUT_DEFAULT is 0, which does NOT match the clear key, so a card coming out
# of configuration cannot be clearing anything.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 aux_ctl
set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
    CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{0}} CONFIG.C_ALL_OUTPUTS {{1}} \\
    CONFIG.C_ALL_INPUTS_2 {{1}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
    CONFIG.C_DOUT_DEFAULT {{0x00000000}} \\
    CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells aux_ctl]
set n [get_property CONFIG.NUM_MI [get_bd_cells auxconnect]]
set_property CONFIG.NUM_MI [expr {{$n + 1}}] [get_bd_cells auxconnect]
connect_bd_intf_net [get_bd_intf_pins auxconnect/[format M%02d_AXI $n]] \\
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
set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
    CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{1}} CONFIG.C_ALL_INPUTS_2 {{1}} \\
    CONFIG.C_ALL_OUTPUTS {{0}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
    CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells fk33_therm]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermp
set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
    CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{1}} CONFIG.C_ALL_INPUTS_2 {{1}} \\
    CONFIG.C_ALL_OUTPUTS {{0}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
    CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells fk33_thermp]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 fk33_thermc
set_property -dict [list CONFIG.C_GPIO_WIDTH {{32}} CONFIG.C_GPIO2_WIDTH {{32}} \\
    CONFIG.C_IS_DUAL {{1}} CONFIG.C_ALL_INPUTS {{0}} CONFIG.C_ALL_OUTPUTS {{1}} \\
    CONFIG.C_ALL_INPUTS_2 {{1}} CONFIG.C_ALL_OUTPUTS_2 {{0}} \\
    CONFIG.C_DOUT_DEFAULT {{0x00000000}} \\
    CONFIG.C_INTERRUPT_PRESENT {{0}}] [get_bd_cells fk33_thermc]

set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]
set_property CONFIG.NUM_MI [expr {{$n + 3}}] [get_bd_cells pcie2axil]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \\
                    [get_bd_intf_pins fk33_therm/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {{$n + 1}}]]] \\
                    [get_bd_intf_pins fk33_thermp/S_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI [expr {{$n + 2}}]]] \\
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

'''

# ---------------------------------------------------------------------------
# The engine RTL, and the block-design wiring.  Both are generated so the port
# map above is the single source of truth for which master lands on which
# pseudo-channel.
ENG_RTL = os.path.join(HERE, "rtl", "fk33_engine.vhd")
ENG_SRC_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
# Listed explicitly, in dependency order, and NOT globbed.  A glob would pull
# in whichever half-edited file another track has open; sim/ooc_fk33_a.tcl
# makes the same choice for the same reason, and this list is that script's
# `matvec_int4_desc_axi` list plus the wrapper.
ENG_SRCS = [
    "util_pkg.vhd", "mv4i_arith_pkg.vhd", "matvec_int4_desc_pkg.vhd",
    "stream_fifo.vhd", "async_fifo.vhd", "axi_rd_fsm.vhd", "axi_rd_port.vhd",
    "weight_streamer.vhd", "act_mem_striped.vhd", "matvec_core.vhd",
    "matvec_int4.vhd", "matvec_int4_desc_axi.vhd",
]

ENG_RTL_ADD = "\n".join(
    ["", "# ---- subsystem A RTL (gen_pcieep.py) --------------------------------------"]
    + ["add_files -norecurse %s" % os.path.join(ENG_SRC_DIR, f) for f in ENG_SRCS]
    + ["add_files -norecurse %s" % ENG_RTL,
       "update_compile_order -fileset sources_1", ""])


def _eng_block():
    L = []
    a = L.append
    a("")
    a("# ---- SUBSYSTEM A (gen_pcieep.py) ------------------------------------------")
    a("# rtl/fk33_engine.vhd wraps rtl/matvec_int4_desc_axi.vhd and exposes its 28")
    a("# read masters as named AXI interfaces, because a flattened std_logic_vector")
    a("# is not something the block designer can connect to hbm/SAXI_nn.  Read")
    a("# hw/fk33/gen_fk33_engine.py's docstring for what that wrapper adds beyond")
    a("# wiring: the thermal halt, the activation write port and the 40 -> 33 bit")
    a("# address truncation.")
    a("create_bd_cell -type module -reference fk33_engine %s" % ENG_CELL)
    a("")
    a("# WHICH CLOCK OWNS WHICH INTERFACE.  A module-reference cell with ONE clock")
    a("# port gets this for free -- which is why rtl/hbm_tg_ip.vhd never needed it")
    a("# and build_fk33_hbmbw.tcl has no line like this.  This wrapper has TWO, so")
    a("# Vivado cannot infer the association and every inferred interface defaults")
    a("# to 100 MHz.  MEASURED: without these lines HDL generation dies with 30")
    a("# separate BD 41-237 'FREQ_HZ does not match' errors, one per interface, and")
    a("# not one of them names the missing association as the cause.")
    a("#")
    a("# Read back below rather than assumed: Vivado silently ignores set_property")
    a("# on a CONFIG name an object does not have, which is the project-wide trap")
    a("# that the SYSMON read-back exists for.")
    a("set_property CONFIG.ASSOCIATED_BUSIF {s_axi:s_axix} [get_bd_pins %s/core_clk]" % ENG_CELL)
    a("set_property CONFIG.ASSOCIATED_RESET {core_aresetn} [get_bd_pins %s/core_clk]" % ENG_CELL)
    a("set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_pins %s/core_aresetn]" % ENG_CELL)
    a("set_property CONFIG.ASSOCIATED_BUSIF {%s} [get_bd_pins %s/hbm_aclk]"
      % (":".join("m%02d_axi" % i for i in range(ENG_NMAST)), ENG_CELL))
    a("foreach {pin want} [list %s/core_clk {s_axi:s_axix} %s/hbm_aclk {%s}] {"
      % (ENG_CELL, ENG_CELL, ":".join("m%02d_axi" % i for i in range(ENG_NMAST))))
    a("    set got [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins $pin]]")
    a("    if {$got ne $want} {")
    a("        error \"FK33_ENG FAIL: $pin ASSOCIATED_BUSIF is \\\"$got\\\", not \\\"$want\\\". Every AXI interface would default to 100 MHz.\"")
    a("    }")
    a("    puts \"FK33_ENG ASSOCIATED_BUSIF $pin = $got\"")
    a("}")
    a("")
    a("# THE CORE CLOCK.  A third MMCM output rather than a reuse of clk_out2:")
    a("# clk_out2 is HBM_REF_CLK_0/1, and sharing the HBM reference clock net with")
    a("# a fabric datapath clock would tie two unrelated requirements together for")
    a("# no gain.  clk_wiz_0's reference is xdma/axi_aclk in this branch, so the")
    a("# core clock stops with the PCIe link -- which is correct: with no host")
    a("# there is no job, and the thermal guard is on the aux domain and does not")
    a("# stop with it.")
    a("create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset")
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]")
    a("connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins core_reset/dcm_locked]")
    a("connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]")
    a("")
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins %s/core_clk]" % ENG_CELL)
    a("connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins %s/core_aresetn]" % ENG_CELL)
    a("connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins %s/hbm_aclk]" % ENG_CELL)
    a("")
    a("# THE THERMAL HALT.  fk33_thermal's contract requires compute_halt to be")
    a("# SYNCHRONOUS TO compute_clk, so compute_clk is moved onto the engine's core")
    a("# clock above; it used to be xdma/axi_aclk because there was no datapath.")
    a("# The wrapper consumes the halt by masking the GO bit of an AXI-Lite write.")
    a("# It does NOT gate a clock, does NOT touch a reset, and does NOT interrupt a")
    a("# job that has already started -- so no accepted HBM burst is ever")
    a("# abandoned, which would hang that channel permanently.")
    a("connect_bd_net [get_bd_pins fk33_therm_0/compute_halt] [get_bd_pins %s/compute_halt]" % ENG_CELL)
    a("")
    a("# CONTROL.  A dedicated smartconnect because the engine's AXI-Lite slave is")
    a("# in the CORE clock domain (matvec_int4_desc_axi's s_axi_aclk IS the core")
    a("# clock) while pcie2axil is in xdma's.  NUM_CLKS 2 with aclk on the incoming")
    a("# side and aclk1 on the outgoing side is exactly the shape")
    a("# build_fk33_hbmbw.tcl:334-341 used for axil2tg, which built, routed and ran.")
    a("create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2eng")
    a("set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {2}] [get_bd_cells axil2eng]")
    a("set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]")
    a("set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells pcie2axil]")
    a("connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \\")
    a("                    [get_bd_intf_pins axil2eng/S00_AXI]")
    a("connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins axil2eng/aclk]")
    a("connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins axil2eng/aresetn]")
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins axil2eng/aclk1]")
    a("connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins %s/s_axi]" % ENG_CELL)
    a("connect_bd_intf_net [get_bd_intf_pins axil2eng/M01_AXI] [get_bd_intf_pins %s/s_axix]" % ENG_CELL)
    a("")
    a("# THE 28 HBM MASTERS.  Every ENABLED SAXI port exposes its own ACLK and")
    a("# ARESET_N pin and leaving them dangling fails HDL generation with 41-758;")
    a("# build_fk33_hbmbw.tcl:373-376 records that, and it is why enabling the")
    a("# ports was never a change that could be made ahead of having an engine.")
    for i, port in enumerate(ENG_PORT_MAP):
        a("connect_bd_intf_net [get_bd_intf_pins %s/m%02d_axi] [get_bd_intf_pins hbm/SAXI_%02d]"
          % (ENG_CELL, i, port))
        a("connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_%02d_ACLK]" % port)
        a("connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_%02d_ARESET_N]" % port)
    a("# ---- end subsystem A ------------------------------------------------------")
    a("")
    return "\n".join(L)


ENGINE_BLOCK = _eng_block()

ENGINE_ADDR = """
# ---- subsystem A address map (gen_pcieep.py) -------------------------------
# On the PCIe AXI-Lite BAR:
#   0x12000  the engine's own map (DESC_PTR, CTRL/GO, STATUS, ERR_INFO, ID,
#            ADDR_CAP, CAPS, DESC_WORDS, Y_IDX/Y_LO/Y_HI/Y_EXP, CYCLES, BEATS,
#            STARVED).  Documented in rtl/matvec_int4_desc_axi.vhd; it does not
#            change shape with geometry, which is the whole point of the
#            descriptor-in-memory decision.
#   0x13000  the activation writer (X_ADDR, X_DATA, ENG_STAT, ENG_ID).
#            Documented in rtl/fk33_engine.vhd.
# Both fit under the 128 KB the XDMA IP sizes the BAR at.  They start at
# 0x12000 and not at 0x11000: fk33_scratch is 8 KB at 0x10000, so it occupies
# 0x10000..0x11FFF, and 0x11000 collides with its second 4 KB.  MEASURED -- the
# --bd-only gate refused it with BD 41-1075 in 90 seconds, which is what that
# gate is for.
"""
ENGINE_ADDR += ("assign_bd_address -offset 0x%08X -range 4K [get_bd_addr_segs {%s/s_axi/reg0}]\n"
                % (ENG_CTL_BASE, ENG_CELL))
ENGINE_ADDR += ("assign_bd_address -offset 0x%08X -range 4K [get_bd_addr_segs {%s/s_axix/reg0}]\n"
                % (ENG_XW_BASE, ENG_CELL))
ENGINE_ADDR += """
# EVERY engine master sees ALL 32 pseudo-channel segments, i.e. the whole 8 GiB.
#
# That is not laziness and it is not a bandwidth claim.  Under the flat packed
# layout the 27 sub-regions of one tensor are contiguous, so a given lane's
# bytes for different tensors are scattered across the whole address space; a
# master restricted to its own stack's 16 segments would DECERR on more than
# half the tensors.  Giving every master the full decode is what makes the
# layout that exists today work at all, and it is a superset of anything the
# residency map's 27-lane arena scheme would later want -- that scheme only
# ever REMOVES segments.  It also costs nothing in the fabric: the engine
# connects DIRECTLY to the HBM IP with no interconnect in the path, so
# assign_bd_address here constrains Vivado's address editor and the IP's own
# switch decode, not a decoder we pay for.
#
# MEASURED, from the IP, docs/2026-08-28_can-27-read-masters-be-served.md 2.1:
# with USER_SWITCH_ENABLE_00/01 TRUE -- which this design sets -- every one of
# the 32 SAXI ports already exposes all 32 HBM_MEM segments.  The stack rule in
# the residency map is a build discipline, not a property of the silicon.
"""
# NOT "%02d" for the port index.  Tcl reads a leading-zero literal as OCTAL, so
# {m07 08} makes `format ... $sx` fail with `expected integer but got "08"` --
# MEASURED, it killed the --bd-only gate after 7 of 28 masters had been mapped.
# The zero padding belongs in the format string on the Tcl side, where it is
# applied to an integer, and nowhere else.
ENGINE_ADDR += ("foreach pair {"
                + " ".join("{m%02d %d}" % (i, p) for i, p in enumerate(ENG_PORT_MAP))
                + "} {\n")
ENGINE_ADDR += """    set m  [lindex $pair 0]
    set sx [lindex $pair 1]
    for {set s 0} {$s < 32} {incr s} {
        assign_bd_address \\
            -target_address_space [get_bd_addr_spaces ENGCELL/${m}_axi] \\
            -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \\
            [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $sx $s]]
    }
}
""".replace("ENGCELL", ENG_CELL)


THERM_ADDR = '''
# ---- thermal register map (gen_pcieep.py) ----------------------------------
# On jtag_aux, readable with the PCIe link DOWN:
#   0x4000  THERM_STATUS  halt/warn/valid/cause/trip count/stickies, [31]=1
#   0x4008  THERM_TEMPS   [9:0] die code [16:10] HBM0 [23:17] HBM1 [31:24] die C
#   0x5000  THERM_PEAK    the same fields, peak-hold
#   0x5008  THERM_TRIP    the same code fields captured at the trip + cause
#   0x6000  THERM_CTL     WRITE.  [31:16] must be 0x%(THERM_CTL_KEY)04X, [0] clear trip,
#                         [1] clear peak.  Edge triggered.
#   0x6008  THERM_CANARY  count of compute-domain canary toggles
assign_bd_address -offset 0x%(AUX_THERM_BASE)08X -range 4K [get_bd_addr_segs {aux_therm/S_AXI/Reg}]
assign_bd_address -offset 0x%(AUX_PEAK_BASE)08X -range 4K [get_bd_addr_segs {aux_peak/S_AXI/Reg}]
assign_bd_address -offset 0x%(AUX_CTL_BASE)08X -range 4K [get_bd_addr_segs {aux_ctl/S_AXI/Reg}]
# On the PCIe AXI-Lite BAR, the same five words plus the same control:
#   0xB000/0xB008  THERM_STATUS / THERM_TEMPS
#   0xC000/0xC008  THERM_PEAK   / THERM_TRIP
#   0xD000/0xD008  THERM_CTL    / THERM_CANARY
assign_bd_address -offset 0x%(THERM_BASE)08X -range 4K [get_bd_addr_segs {fk33_therm/S_AXI/Reg}]
assign_bd_address -offset 0x%(THERMP_BASE)08X -range 4K [get_bd_addr_segs {fk33_thermp/S_AXI/Reg}]
assign_bd_address -offset 0x%(THERMC_BASE)08X -range 4K [get_bd_addr_segs {fk33_thermc/S_AXI/Reg}]
''' % dict(AUX_THERM_BASE=AUX_THERM_BASE, AUX_PEAK_BASE=AUX_PEAK_BASE,
                             AUX_CTL_BASE=AUX_CTL_BASE, THERM_BASE=THERM_BASE,
                             THERMP_BASE=THERMP_BASE, THERMC_BASE=THERMC_BASE,
                             THERM_CTL_KEY=THERM_CTL_KEY)

AUX_RTL_ADD = f'''
# ---- aux RTL (gen_pcieep.py) ----------------------------------------------
# Added before the block design so `create_bd_cell -type module -reference
# fk33_aux` can find it.  Absolute path because the build runs in a scratch
# directory, not here.
add_files -norecurse {AUX_RTL}
add_files -norecurse {THERM_RTL}
update_compile_order -fileset sources_1
'''

# Printed by EVERY build, not only by the no-card check.  The thermal read-back
# used to live inside the FK33_STOP_AFTER_BD block, which meant the build that
# actually produced a bitstream never once proved the SYSMON configuration had
# taken -- the proof came from a separate --bd-only run against a Tcl that was
# not provably the same file.  A guard that does not run on the artefact you
# ship is not a guard.  Found on 2026-08-28 while writing up the first build.
THERM_BD_CHECK = '''
# ---- thermal sensor availability (gen_pcieep.py) --------------------------
# Vivado SILENTLY IGNORES set_property on a CONFIG name that does not apply to
# an IP, so asking for temp_out is not evidence of getting it.  Each check
# below is a way the thermal guard can be built present, timing-clean, and
# BLIND: without ENABLE_TEMP_BUS there is no die temperature in the fabric at
# all, and the guard would then sit permanently halted on a stale die sensor.
# This runs unconditionally.  It costs a few seconds and it is the difference
# between a thermal guard and a thermal guard-shaped hole.
foreach p {ENABLE_TEMP_BUS USER_TEMP_ALARM TEMPERATURE_ALARM_TRIGGER \
           TEMPERATURE_ALARM_RESET TEMPERATURE_ALARM_OT_TRIGGER \
           TEMPERATURE_ALARM_OT_RESET REFERENCE INTERFACE_SELECTION} {
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
'''

# Printed by the build, and by the no-card BD check, so that a build which
# succeeds with the wrong link width or the wrong device ID is caught by
# reading the log rather than by plugging the card in.
BD_CHECK_BLOCK = '''
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
    foreach p {pl_link_cap_max_link_width pl_link_cap_max_link_speed \\
               axi_data_width xdma_rnum_chnl xdma_wnum_chnl \\
               axilite_master_en axilite_master_size axilite_master_scale \\
               vendor_id pf0_device_id pf0_subsystem_vendor_id pf0_subsystem_id \\
               pcie_blk_locn axisten_freq} {
        if {[llength [get_bd_cells -quiet xdma]]} {
            puts "FK33_CFG xdma.$p = [get_property CONFIG.$p [get_bd_cells xdma]]"
        }
    }
    foreach c {pcie2axil pcie2hbm auxconnect} {
        puts "FK33_CFG $c.NUM_SI = [get_property CONFIG.NUM_SI [get_bd_cells $c]]"
        puts "FK33_CFG $c.NUM_MI = [get_property CONFIG.NUM_MI [get_bd_cells $c]]"
    }
    foreach c {fk33_id fk33_scratch fk33_dmabram eng core_reset axil2eng} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING CELL $c" }
    }
    # SUBSYSTEM A.  Three ways this build can come out looking healthy and be
    # wrong, each read back from the tool rather than assumed:
    #   * a SAXI port that should be enabled is not, so a master is dangling
    #   * an enabled port's ACLK or ARESET_N is undriven (41-758 catches that at
    #     HDL generation, but only if it is still undriven THEN)
    #   * an engine master interface never got connected to an HBM port
    set engbad 0
    foreach i {01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 \
               17 18 19 20 21 22 23 24 25 26 27 28 29} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        if {[string tolower $v] ne "true"} {
            puts "FK33_ENG SAXI_$i IS NOT ENABLED (USER_SAXI_$i = $v)"
            incr engbad
        }
        foreach pin [list hbm/AXI_${i}_ACLK hbm/AXI_${i}_ARESET_N] {
            if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin]]]} {
                puts "FK33_ENG $pin IS UNDRIVEN"
                incr engbad
            }
        }
    }
    foreach i {30 31} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        puts "FK33_ENG SAXI_$i = $v (must be false: spare for B and C)"
        if {[string tolower $v] ne "false"} { incr engbad }
    }
    for {set m 0} {$m < 28} {incr m} {
        set ip [get_bd_intf_pins -quiet [format "eng/m%02d_axi" $m]]
        if {![llength $ip]} { puts "FK33_ENG eng/m${m}_axi MISSING"; incr engbad; continue }
        if {![llength [get_bd_intf_nets -quiet -of_objects $ip]]} {
            puts [format "FK33_ENG eng/m%02d_axi IS NOT CONNECTED" $m]
            incr engbad
        }
    }
    puts "FK33_ENG portcheck bad=$engbad (must be 0)"
    puts "FK33_ENG masters=28 halt=[llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]"
    if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]} {
        puts "FK33_ENG compute_halt IS UNDRIVEN -- the thermal guard cannot stop the array"
        incr engbad
    }
    # The aux domain.  A missing cell here means the bitstream is blind with
    # the link down, which is the exact condition it exists for, so name them.
    foreach c {fk33_aux_0 util_ds_buf_1 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time \
               aux_therm aux_peak aux_ctl fk33_therm_0 fk33_therm fk33_thermp fk33_thermc} {
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
    set auxallow {/fk33_aux_0/xdma_aclk /fk33_aux_0/xdma_aresetn \
                  /fk33_therm_0/sysmon_clk /fk33_therm_0/ctl_host_clk \
                  /fk33_therm_0/compute_clk}
    set auxbad 0
    foreach c {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time \
               aux_therm aux_peak aux_ctl fk33_therm_0} {
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
                puts [format "FK33_MAP %-24s %-42s %-14s %s" \\
                      [get_property PATH $sp] $sg \\
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
'''

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

# ---------------------------------------------------------------------------
# Constraints for the aux domain.  Appended to the XDC.
#
# Two things have to be true and neither may be left to luck:
#   1. the free-running clock is DEFINED, or every path in the aux domain is
#      unconstrained and the CDC into it is not analysed at all;
#   2. it is declared ASYNCHRONOUS to everything else.  Every crossing into it
#      is a single bit through a two-stage ASYNC_REG synchroniser -- there is
#      deliberately no multi-bit CDC anywhere in rtl/fk33_aux.vhd, the
#      reference-clock counter is not transported but reconstructed on this
#      side from a divided single-bit toggle -- so an asynchronous clock group
#      is the correct and sufficient constraint, with no bus-skew obligation.
#      A multi-bit crossing would need set_bus_skew and would not be allowed to
#      rely on this line.
#
# Everything below is written name-independently: the clock is found through
# the PORT, not by the name a create_clock happened to give it, and the hub
# clock net is found by the KEEP/DONT_TOUCH name the RTL pins down.  Each step
# prints what it did, because a constraint that silently matched nothing is the
# failure mode that produces a bitstream which looks fine and is not.
#
# NO TCL CONTROL FLOW IS ALLOWED IN HERE.  Vivado's XDC reader is a restricted
# subset in BOTH synthesis and implementation, and an `if` produces
#
#   CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in
#   the xdc constraint file.
#
# and then SKIPS THE WHOLE BLOCK.  It is a warning, not an error, so the build
# completes and produces a bitstream in which none of these constraints exist.
# That happened once here, on 2026-08-28, and cost a full build: the aux domain
# came out unconstrained and the debug hub was never moved.  Everything below is
# therefore unconditional, and the verification that it actually took effect
# lives in the build script, on the implemented design, where full Tcl is legal.
AUX_XDC = [
    "",
    "###############################################################################",
    "# FREE-RUNNING AUX DOMAIN (gen_pcieep.py) -- read rtl/fk33_aux.vhd first",
    "###############################################################################",
    "# The 200 MHz board oscillator on BC26/BC27.  In the EnablePCIe == 1 branch it",
    "# is the ONLY clock in the design that does not stop when the PCIe link is",
    "# down: xdma/axi_aclk stops, and clk_wiz_0 (hence hbm/APB_0_PCLK, hence the",
    "# debug hub's old clock) is referenced to it AND held in reset by",
    "# xdma/axi_aresetn.",
    "#",
    "# NOTHING BELOW MAY USE if/foreach/set.  See the note in gen_pcieep.py: the",
    "# XDC reader silently skips such a block in both synthesis and implementation.",
    "create_clock -period 5.000 -name sysref_clk [get_ports {sysref_clk_p[0]}]",
    "",
    "# Every crossing into this domain is a SINGLE BIT through a two-stage",
    "# ASYNC_REG synchroniser -- there is deliberately no multi-bit CDC in",
    "# rtl/fk33_aux.vhd, and the reference-clock counter is reconstructed on this",
    "# side from a divided single-bit toggle rather than transported.  That is why",
    "# an asynchronous clock group is a complete constraint here and carries no",
    "# bus-skew obligation.  A multi-bit crossing would need set_bus_skew and",
    "# would NOT be allowed to rely on this line.",
    "set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sysref_clk]",
    "",
    "# The debug hub moves onto the aux clock.  A hub clocked off a stopped MMCM",
    "# cannot answer either, so leaving it where upstream put it would make the",
    "# whole aux domain unreadable in exactly the state it exists for.",
    "#",
    "# Addressed through the module's PIN, not through an internal net name: the",
    "# cell name fk33_aux_0 and the port name aux_clk are both set by this",
    "# generator, whereas the internal net name is whatever synthesis chooses (it",
    "# is bd_i/fk33_aux_0_aux_clk today, and KEEP/DONT_TOUCH did not preserve the",
    "# RTL name across the module's out-of-context run).  If either name ever",
    "# changes, this errors instead of silently matching nothing.",
    "set_property C_CLK_INPUT_FREQ_HZ 200000000 [get_debug_cores dbg_hub]",
    "connect_debug_port dbg_hub/clk [get_nets -of_objects [get_pins bd_i/fk33_aux_0/aux_clk]]",
    "",
    "# pcie_perstn is a genuinely asynchronous input with no launching clock. It",
    "# is deliberately left with no input delay, exactly as it already was for",
    "# xdma/sys_rst_n, so it contributes no timed path; the receiving flip-flops",
    "# in fk33_aux carry ASYNC_REG.",
]


ENG_XDC = [
    "",
    "###############################################################################",
    "# SUBSYSTEM A's CLOCK BOUNDARY (gen_pcieep.py)",
    "###############################################################################",
    "# The engine's core clock and its HBM AXI clock are DIFFERENT DOMAINS by",
    "# design.  27 x 256 bits is 864 B exactly, so duty = f_core / f_axi with no",
    "# efficiency term, and running both at one clock is 100% duty with zero",
    "# margin -- rejected in docs/2026-08-28_can-27-read-masters-be-served.md 4.3.",
    "# The crossing is a gray-pointer FIFO per port (rtl/async_fifo.vhd), one for",
    "# each of the 28 masters, with a four-phase clear handshake.",
    "#",
    "# WHY THIS LINE IS NEEDED HERE AND WAS NOT NEEDED OUT OF CONTEXT.  In the",
    "# OOC runs the two clocks were created independently and were unrelated by",
    "# construction, and sim/ooc_fk33_a.tcl:143 declares them asynchronous",
    "# anyway.  In this build clk_out3 is an MMCM output whose reference IS",
    "# xdma/axi_aclk, so without this the tool would TIME every gray pointer and",
    "# every clear-handshake bit against a 200/250 MHz common period and report",
    "# failures on a crossing that is handled in RTL.",
    "#",
    "# It is addressed through the ENGINE'S OWN PINS, whose names this generator",
    "# controls, rather than through an auto-generated clk_wiz clock name.  The",
    "# impl-stage check in the build script FAILS THE BUILD if this matched",
    "# nothing -- a set_clock_groups with an empty group is a warning, not an",
    "# error, so an unchecked constraint here would be a silent no-op.",
    "#",
    "# NOTHING BELOW MAY USE if/foreach/set.",
    "set_clock_groups -asynchronous \\",
    "    -group [get_clocks -of_objects [get_pins bd_i/eng/core_clk]] \\",
    "    -group [get_clocks -of_objects [get_pins bd_i/eng/hbm_aclk]]",
]

IMPL_ENG_OLD = 'set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]\nset whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]\nputs [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]'
IMPL_ENG_NEW = """# ---- SUBSYSTEM A, on the implemented design (gen_pcieep.py) ---------------
# The deliverable of the shell-integration track: the quantities the
# out-of-context runs reported, measured with the HBM IP, the XDMA shell, the
# aux domain and the thermal guard present, after place and route.  The OOC
# ceilings to compare against, both at VCCINT 0.717 V:
#     AXI  257.33 MHz   core  230.73 MHz
#     LUT 134,534   FF 64,067   DSP 1,585   BRAM36 192.5
# (docs/debugging/2026-08-28_ar-throttle-timing-close.md and
#  docs/debugging/2026-08-28_matvec-divide-by-48-core-clock.md.)
puts "==== FK33 subsystem A (implemented design) ===="
if {[llength [get_cells -quiet bd_i/eng]] == 0} {
    error "FK33_ENGI FAIL: bd_i/eng is not in the implemented design"
}

# THE TWO CLOCKS, read off the engine's own pins rather than assumed from the
# clk_wiz request -- a clk_wiz cannot always synthesise what it was asked for.
#
# This is ALSO the check that the XDC's set_clock_groups matched something.
# The XDC addresses the two groups through these exact pins, so if either
# lookup is empty here it was empty there, and a set_clock_groups with an empty
# group is a WARNING rather than an error -- the silent no-op this guards
# against.
#
# WHAT IT DOES NOT PROVE, stated because a stronger check was WRITTEN, RUN AND
# REMOVED: it does not prove the group was APPLIED.  The stronger form is the
# one FK33_AUXCLK uses, enumerating crossing paths and demanding that none has
# a slack -- and on THIS design it does not terminate.  MEASURED 2026-08-29:
# `get_timing_paths -from <core> -to <axi> -max_paths 8` ran over 20 minutes on
# the post-phys_opt checkpoint without returning, because an asynchronous group
# does not stop the enumeration and 28 gray-pointer FIFOs plus their
# four-phase clear handshakes is an enormous one.  The aux-domain check is
# cheap for the opposite reason: that domain is a handful of single-bit
# crossings.  A check that hangs a fifty-minute build is worse than a weaker
# check that runs, so the pair is reported in clkint.rpt below for a human to
# read instead.
set ecore [get_clocks -quiet -of_objects [get_pins bd_i/eng/core_clk]]
set eaxi  [get_clocks -quiet -of_objects [get_pins bd_i/eng/hbm_aclk]]
if {[llength $ecore] != 1 || [llength $eaxi] != 1} {
    error "FK33_ENGI FAIL: expected one clock on each of eng/core_clk and eng/hbm_aclk, got [llength $ecore] and [llength $eaxi]. The XDC clock group matched nothing and the per-port CDC is being timed."
}
foreach cn [list $ecore $eaxi] {
    puts [format "FK33_ENGI clock %-30s period %.3f ns (%.2f MHz)" \
          [get_property NAME $cn] [get_property PERIOD $cn] \
          [expr {1000.0 / [get_property PERIOD $cn]}]]
}

# AREA OF THE ENGINE ALONE, so it can be compared with the OOC figure without
# the shell in it.  report_utilization -cells is the only honest way:
# subtracting a remembered shell number from a design total is how the
# 1,200-LUT error in the previous area comparison happened.
report_utilization -cells [get_cells bd_i/eng] -file fk33_pcieep_engine_util.rpt
puts "FK33_ENGI engine utilization -> fk33_pcieep_engine_util.rpt"

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
# -no_detailed_paths: the per-clock table is what the duty identity needs and
# the detailed paths are what make this report expensive.
report_timing_summary -no_detailed_paths -file fk33_pcieep_timing.rpt
report_clock_interaction -file fk33_pcieep_clkint.rpt
report_design_analysis -congestion -file fk33_pcieep_congestion.rpt
report_clock_utilization -file fk33_pcieep_clkutil.rpt"""

SAXI0_OLD = ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} "
             + " ".join("CONFIG.USER_SAXI_%02d {false}" % i for i in range(1, 16))
             + "] [get_bd_cells hbm]")
SAXI1_OLD = ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} "
             + " ".join("CONFIG.USER_SAXI_%02d {false}" % i for i in range(17, 32))
             + "] [get_bd_cells hbm]")

SUBS = [
    # ---- 7. separate project + artifacts
    ("set ProjectName fk33_i2cprobe",
     "set ProjectName fk33_pcieep"),

    # ---- 9a. the aux RTL, before anything that references it
    ('create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"',
     'create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"\n'
     + AUX_RTL_ADD + ENG_RTL_ADD),

    # ---- 9b. the AXI GPIO's I2C pins stop being an external interface here and
    # are taken over by the aux block, which arbitrates and owns the IOBUFs.
    # The external port name does not change, so no pin constraint moves.
    ("""make_bd_intf_pins_external  [get_bd_intf_pins axi_gpio_0/GPIO]
set_property name i2cprobe [get_bd_intf_ports GPIO_0]""",
     """# [gen_pcieep] axi_gpio_0/GPIO is NOT made external here any more.  Its
# gpio_io_o / gpio_io_t / gpio_io_i now go into fk33_aux_0, which arbitrates
# between this GPIO and the autonomous VCCINT controller and instantiates the
# IOBUFs itself.  The external inout port is created there with the same name,
# i2cprobe_tri_io, so fk33_pcieep.xdc is unchanged for those two balls."""),

    # ---- 11a. SYSMON: bring the die temperature and the alarms into fabric.
    # Upstream configures SYSMON's limits and then leaves the block as a
    # read-only register.  Three changes, all of them additive:
    #   ENABLE_TEMP_BUS      creates temp_out[9:0], the top ten bits of the
    #                        16-bit DRP temperature word.  Default FALSE.
    #   USER_TEMP_ALARM      creates user_temp_alarm_out.  Upstream sets this
    #                        FALSE explicitly, so it has to be re-set here.
    #   TEMPERATURE_ALARM_*  programs that alarm's own trip and reset points to
    #                        the same 90 C / 75 C the fabric guard uses, giving
    #                        the die a SECOND, independent hardware comparator
    #                        inside SYSMON that shares no logic with ours.
    # The armed OT alarm stays exactly where SQRL put it, 101 C / 99 C.  It is
    # NOT retuned: it is the die-destruction backstop and its consequence is a
    # device shutdown, so the fabric guard is set to fire 11 C before it.
    #
    # Vivado SILENTLY IGNORES set_property on a CONFIG name that does not apply
    # to an IP, so all three are READ BACK in the block-design check.
    ("set_property -dict [list CONFIG.VBRAM_ALARM_UPPER {0.88} CONFIG.REFERENCE {External}] [get_bd_cells system_management_wiz_0]",
     """set_property -dict [list CONFIG.VBRAM_ALARM_UPPER {0.88} CONFIG.REFERENCE {External}] [get_bd_cells system_management_wiz_0]
# ---- THERMAL (gen_pcieep.py): see item 11 in the header --------------------
set_property -dict [list CONFIG.ENABLE_TEMP_BUS {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.USER_TEMP_ALARM {true}] [get_bd_cells system_management_wiz_0]
set_property -dict [list CONFIG.TEMPERATURE_ALARM_TRIGGER {90} CONFIG.TEMPERATURE_ALARM_RESET {75}] [get_bd_cells system_management_wiz_0]"""),

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

    # ---- 8. bring-up peripherals: identity, AXI-Lite scratch, DMA BRAM.
    # Inserted immediately before the layout regeneration, i.e. AFTER the
    # EnablePCIe if/else has wired the smartconnect clocks, so the block can
    # join those nets and be correct in both branches.
    ("regenerate_bd_layout\nsave_bd_design",
     BRINGUP_BLOCK + AUX_BLOCK + THERM_BLOCK + ENGINE_BLOCK
     + "regenerate_bd_layout\nsave_bd_design"),

    ("assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]",
     "assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]\n"
     + BRINGUP_ADDR + AUX_ADDR + THERM_ADDR + ENGINE_ADDR),

    # ---- 9c. verify the aux constraints on the IMPLEMENTED design.
    # This has to live here and not in the XDC, because the XDC reader forbids
    # control flow and skips any block containing it -- silently, with a
    # CRITICAL WARNING that a build log full of pblock warnings buries.  Here
    # full Tcl is legal and the design is real.
    ("open_run impl_1",
     """open_run impl_1
puts "==== FK33 aux-domain constraint verification (implemented design) ===="
# 1. the free-running clock must exist, exactly once, at 5 ns
set auxclks [get_clocks -quiet -of_objects [get_ports {sysref_clk_p[0]}]]
puts "FK33_AUXCLK clocks=$auxclks"
if {[llength $auxclks] != 1} {
    error "FK33_AUXCLK FAIL: expected exactly one clock on sysref_clk_p\\[0\\], got [llength $auxclks]. The aux domain would be unconstrained."
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
foreach pth [concat [get_timing_paths -quiet -from [lindex $auxclks 0] -to $others -max_paths 8] \
                    [get_timing_paths -quiet -from $others -to [lindex $auxclks 0] -max_paths 8]] {
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
    error "FK33_HUBCLK FAIL: the debug hub is clocked by \\"$hubclks\\", not sysref_clk. With the PCIe link down it would not answer, which is the whole point of this build."
}
puts "FK33_HUBCLK OK dbg_hub is on sysref_clk"

# 4. and nothing in the aux branch may be clocked by the PCIe user clock
foreach auxcell {fk33_aux_0 jtag_aux auxconnect aux_id aux_clkst aux_stat aux_time \
                 aux_therm aux_peak aux_ctl fk33_therm_0} {
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
    error "FK33_THERMCLK FAIL: the thermal guard's aux_clk is \"$tclks\", not sysref_clk."
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
    error "FK33_SYSMONI FAIL: cannot parse $name = \"$raw\""
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
"""),

    # ---- 9. the no-card stopping point
    ('puts "==== IP status before upgrade ===="',
     THERM_BD_CHECK + BD_CHECK_BLOCK + '\nputs "==== IP status before upgrade ===="'),


    # ---- the engine's core clock.  A THIRD clk_wiz output; ENGINE_BLOCK says
    # why it is not a reuse of clk_out2, which is HBM_REF_CLK_0/1.
    ("set_property -dict [list CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]",
     "set_property -dict [list CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]\n"
     "set_property -dict [list CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {%.3f}] [get_bd_cells clk_wiz_0]" % ENG_CORE_MHZ),

    # ---- HBM ENGINE PORTS.  The IP defaults all 32 USER_SAXI_nn to true and
    # upstream turns 30 off.  That was CORRECT for every build before this one:
    # an enabled port exposes its own ACLK and ARESET_N pin and HDL generation
    # fails with 41-758 if they dangle (build_fk33_hbmbw.tcl:373-376), and there
    # was no engine to drive them.  There is now.  SAXI_01..15 (stack 0) and
    # SAXI_17..29 (stack 1) stay ENABLED and every one of them gets its clock
    # and reset in ENGINE_BLOCK.  SAXI_30/31 stay off: they are the two spare
    # engine ports docs/2026-08-27_hbm-port-contention.md reserves for B and C.
    (SAXI0_OLD,
     "    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK}] [get_bd_cells hbm]"),
    (SAXI1_OLD,
     "    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} "
     "CONFIG.USER_SAXI_30 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]"),

    (IMPL_ENG_OLD, IMPL_ENG_NEW),

    # ---- MEMORY.  -jobs 8 on SYNTHESIS launches up to 8 concurrent
    # out-of-context IP runs, each its own Vivado process, on a 31 GB box that
    # has OOM-killed unrelated services before (the 2026-07-04 systemd-oomd
    # incident took down the whole code-server cgroup).  The engine adds a
    # ~135 kLUT module to the main run, so this build is materially heavier
    # than every pcieep build before it.  Implementation is left at 8: its
    # -jobs is threads inside ONE process and does not multiply the footprint.
    ("launch_runs synth_1 -jobs 8", "launch_runs synth_1 -jobs 4"),

    # ---- FORCE THE TOP.  This is gen_hbmbw.py:360's trap, reproduced exactly.
    # add_files on the engine RTL puts a SECOND root module in the fileset, and
    # update_compile_order re-runs Vivado's automatic top detection, which picks
    # fk33_engine over bd_wrapper.  Synthesis then SUCCEEDS -- on the wrong
    # design -- and the only symptom is in the placer, as
    #   ERROR: [Place 30-415] IO Placement failed due to overutilization.
    #   This design contains 18348 I/O ports
    # because the engine's 28 AXI masters became top-level pins instead of
    # internal connections to the HBM IP.  MEASURED here on 2026-08-29, an hour
    # after the note in gen_hbmbw.py said it would happen.  `make_wrapper -top`
    # sets the top once; it does not defend it.
    ('add_files -norecurse ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/hdl/bd_wrapper.v\nupdate_compile_order -fileset sources_1',
     'add_files -norecurse ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/hdl/bd_wrapper.v\nupdate_compile_order -fileset sources_1\nset_property top bd_wrapper [current_fileset]\nupdate_compile_order -fileset sources_1\nif {[get_property top [current_fileset]] ne "bd_wrapper"} {\n    error "FK33_TOP FAIL: top is [get_property top [current_fileset]], not bd_wrapper. The engine\'s 28 AXI masters would become top-level I/O."\n}\nputs "FK33_TOP [get_property top [current_fileset]]"'),

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
'''


def main():
    if not os.path.exists(SRC):
        sys.exit(f"ABORT: probe build script not found: {SRC}\n"
                 "Run gen_i2cprobe.py first.")
    if not os.path.exists(XDC_SRC):
        sys.exit(f"ABORT: probe XDC not found: {XDC_SRC}\n"
                 "Run gen_i2cprobe.py first.")
    if not os.path.exists(AUX_RTL):
        sys.exit(f"ABORT: aux RTL not found: {AUX_RTL}\n"
                 "Without it the endpoint bitstream is blind with the link "
                 "down, which is the one condition it has to be readable in.")
    if not os.path.exists(THERM_RTL):
        sys.exit(f"ABORT: thermal RTL not found: {THERM_RTL}\n"
                 "Without it this bitstream has NO thermal protection of any "
                 "kind except SYSMON's 101 C over-temperature shutdown, which "
                 "is above the part's sustained rating, says nothing about "
                 "HBM, and takes the card off the PCIe bus when it fires.")

    # The thermal thresholds are a safety property, checked HERE as well as
    # asserted in the RTL, for the same reason G_POT_WIPER is: a generator that
    # can emit a build whose guard trips at 120 C is a generator that can cook
    # the part and the HBM under it.  See rtl/fk33_thermal.vhd for the DS890
    # numbers each of these is derived from.
    therm_src = open(THERM_RTL).read()

    # The Python copies above exist so the host can REPORT what the bitstream
    # enforces.  A second copy of a safety number is a second chance to be
    # wrong, so it is checked against the RTL rather than trusted.
    for gname, value in (("G_DIE_WARN_C", THERM_DIE_WARN_C),
                         ("G_DIE_HALT_C", THERM_DIE_HALT_C),
                         ("G_DIE_RESUME_C", THERM_DIE_RESUME_C),
                         ("G_HBM_WARN_C", THERM_HBM_WARN_C),
                         ("G_HBM_HALT_C", THERM_HBM_HALT_C),
                         ("G_HBM_RESUME_C", THERM_HBM_RESUME_C)):
        m = re.search(r"%s\s*:\s*natural\s*:=\s*(\d+)" % gname, therm_src)
        if not m:
            sys.exit(f"ABORT: {gname} is no longer a generic of fk33_thermal.")
        if int(m.group(1)) != value:
            sys.exit(f"ABORT: {gname} is {m.group(1)} in rtl/fk33_thermal.vhd "
                     f"but {value} in gen_pcieep.py.  The host would report a "
                     f"threshold the hardware does not enforce.")
    m = re.search(r"G_CTL_KEY\s*:\s*natural\s*:=\s*16#([0-9A-Fa-f]+)#", therm_src)
    if not m or int(m.group(1), 16) != THERM_CTL_KEY:
        sys.exit("ABORT: the thermal clear key in rtl/fk33_thermal.vhd does not "
                 "match THERM_CTL_KEY in gen_pcieep.py, so no host clear would "
                 "ever be accepted.")

    for need, why in (
        ("G_DIE_HALT_C   : natural := 90",
         "the die halt threshold is no longer 90 C.  DS890 Table 33 gives "
         "sustained Tj 100 C for -2LE and the armed SYSMON OT shutdown in this "
         "design is at 101 C"),
        ("G_DIE_RESUME_C : natural := 75",
         "the die resume threshold is no longer 75 C, so the hysteresis band "
         "is not the one that was reviewed"),
        ("G_HBM_HALT_C   : natural := 85",
         "the HBM halt threshold is no longer 85.  DS890 note 1 recommends a "
         "maximum of 95 C for the HBM and the code-to-Celsius mapping of "
         "DRAM_x_STAT_TEMP is NOT calibrated on this card"),
        ("constant C_DIE_HALT_CEILING : natural := 90 - G_DIE_HALT_C;",
         "the SYNTHESIS-time ceiling on the die halt threshold is gone.  "
         "Vivado synthesis IGNORES `assert ... severity failure` (measured "
         "2026-08-28), so a negative-natural constant is the only thing inside "
         "the RTL that can stop an out-of-spec threshold reaching a bitstream"),
        ("constant C_HBM_HALT_CEILING : natural := 85 - G_HBM_HALT_C;",
         "the SYNTHESIS-time ceiling on the HBM halt threshold is gone"),
        ("constant C_DIE_HYST_FLOOR   : natural := G_DIE_HALT_C - G_DIE_RESUME_C - 10;",
         "the SYNTHESIS-time floor on the die hysteresis band is gone"),
        ("assert G_DIE_HALT_C <= 90",
         "the elaboration-time ceiling on the die halt threshold is gone"),
        ("assert G_HBM_HALT_C <= 85",
         "the elaboration-time ceiling on the HBM halt threshold is gone"),
        ("assert G_DIE_RESUME_C + 10 <= G_DIE_HALT_C",
         "the elaboration-time check on the die hysteresis band is gone"),
        ("assert C_DIE_HALT > 700 and C_DIE_HALT < 800",
         "the elaboration-time check that the die threshold converts to a "
         "plausible SYSMON code is gone, so an arithmetic error in the "
         "transfer function would produce a threshold nobody notices"),
        ("signal halted   : std_logic := '1';   -- FAIL SAFE",
         "the guard no longer comes up HALTED.  A guard that powers up "
         "released has no fail-safe: it runs the datapath before it has seen "
         "a single temperature"),
        ("signal halt_sync : std_logic_vector(1 downto 0) := (others => '1')",
         "compute_halt no longer resets to HALTED in the compute domain, so a "
         "datapath whose clock is dead or whose synchroniser has not "
         "propagated would be released"),
    ):
        if need not in therm_src:
            sys.exit(f"ABORT: {why} ({need!r} missing from rtl/fk33_thermal.vhd).")

    # The VCCINT target is a safety property, so it is checked HERE as well as
    # asserted in the RTL.  A generator that can emit a build whose pot
    # controller writes something other than 68 is a generator that can put
    # 0.850 V on an ES1 die.
    aux_src = open(AUX_RTL).read()
    if "G_POT_WIPER  : natural := 68" not in aux_src:
        sys.exit("ABORT: rtl/fk33_aux.vhd no longer defaults G_POT_WIPER to 68. "
                 "Refusing to emit a build whose autonomous controller may move "
                 "VCCINT somewhere else.")
    m = re.search(r'constant\s+C_VERSION\s*:\s*std_logic_vector\(31 downto 0\)\s*:=\s*x"([0-9A-Fa-f]{8})"', aux_src)
    if not m:
        sys.exit("ABORT: rtl/fk33_aux.vhd no longer declares C_VERSION as an 8-digit "
                 "hex constant, so the two build stamps cannot be compared. "
                 "See the ID_BUILD comment.")
    if int(m.group(1), 16) != ID_BUILD:
        sys.exit("ABORT: the two build stamps disagree. "
                 "gen_pcieep.py ID_BUILD = 0x%08X (AXI-Lite 0xA008, what "
                 "fk33ctl.py id prints) but rtl/fk33_aux.vhd C_VERSION = 0x%s "
                 "(AUX_VERSION, what aux_probe.tcl prints). A card would report "
                 "two different identities for one bitstream. Bump both, or "
                 "neither." % (ID_BUILD, m.group(1).upper()))
    if "assert G_POT_WIPER = 68" not in aux_src:
        sys.exit("ABORT: rtl/fk33_aux.vhd lost its elaboration-time assertion "
                 "that the wiper is 68.")

    # host/fk33ctl.py is hand-written, not generated, and it decodes the
    # thermal registers.  A base address that drifts there does not fail: it
    # reads a different peripheral and prints a plausible number.  Pin them.
    ctl_py = os.path.join(HERE, "host", "fk33ctl.py")
    if os.path.exists(ctl_py):
        ctl_src = open(ctl_py).read()
        for name, value in (("THERM_STATUS", THERM_BASE),
                            ("THERM_TEMPS", THERM_BASE + 8),
                            ("THERM_PEAK", THERMP_BASE),
                            ("THERM_TRIP", THERMP_BASE + 8),
                            ("THERM_CTL", THERMC_BASE),
                            ("THERM_CANARY", THERMC_BASE + 8),
                            ("THERM_KEY", THERM_CTL_KEY)):
            m = re.search(r"^%s\s*=\s*0x([0-9A-Fa-f]+)" % name, ctl_src, re.M)
            if not m:
                sys.exit(f"ABORT: host/fk33ctl.py has no {name} constant, so it "
                         "cannot read the thermal guard.")
            if int(m.group(1), 16) != value:
                sys.exit(f"ABORT: host/fk33ctl.py {name} is 0x{m.group(1)} but "
                         f"the block design puts it at {value:#x}.  The host "
                         "would read a different peripheral and print a "
                         "plausible number.")

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
    # The three bring-up peripherals are the entire reason there is anything to
    # test on the day the card goes in.  A build without them enumerates,
    # binds, and tells you nothing.
    for cell in ("fk33_id", "fk33_scratch", "fk33_dmabram"):
        if f"create_bd_cell -type ip -vlnv xilinx.com:ip:{'axi_gpio' if cell == 'fk33_id' else 'axi_bram_ctrl'}" not in text:
            sys.exit(f"ABORT: {cell}'s IP was not instantiated.")
        if f"{cell}/S_AXI" not in text:
            sys.exit(f"ABORT: {cell} is not connected to a smartconnect master.")
    if str(ID_MAGIC) not in text:
        sys.exit("ABORT: the identity constant did not reach the build script.")
    if "FK33_STOP_AFTER_BD" not in text:
        sys.exit("ABORT: the no-card BD check hook is missing.")

    # The aux domain.  Without every one of these the endpoint bitstream is
    # exactly as blind with the link down as the one that produced the
    # first-fit handoff, so a silent regression here costs another afternoon on
    # the bench to notice.
    for need, why in (
        ("create_bd_cell -type module -reference fk33_aux fk33_aux_0",
         "the aux block is not instantiated"),
        ("util_ds_buf_1/IBUF_OUT",
         "the free-running 200 MHz oscillator is not connected"),
        ("fk33_aux_0/xdma_aclk",
         "the PCIe user clock is not tapped, so it cannot be measured"),
        ("fk33_aux_0/perstn",
         "PERST# is not observed"),
        ("fk33_aux_0/xdma_aresetn",
         "the fabric reset state is not observed"),
        ("jtag_aux/M_AXI",
         "there is no JTAG read path on the free-running clock"),
        ("set_property name i2cprobe_tri_io",
         "the I2C balls lost their external port name and the XDC no longer "
         "matches them"),
        # ---- thermal.  Each of these is a way the build can come out with a
        # thermal guard that is present, builds, closes timing, and is blind.
        ("create_bd_cell -type module -reference fk33_thermal fk33_therm_0",
         "the thermal guard is not instantiated, so this bitstream has no "
         "thermal protection except SYSMON's 101 C shutdown"),
        ("CONFIG.ENABLE_TEMP_BUS {true}",
         "SYSMON's temperature bus is not enabled, so there is no die "
         "temperature in the fabric for the guard to compare"),
        ("CONFIG.USER_TEMP_ALARM {true}",
         "SYSMON's user temperature alarm is not enabled, so the die has one "
         "comparator instead of two"),
        ("system_management_wiz_0/temp_out",
         "the die temperature is not wired into the guard"),
        ("system_management_wiz_0/eoc_out",
         "the die LIVENESS strobe is not wired in, so a frozen SYSMON would "
         "read as a cold card -- the exact fail-open this design refuses"),
        ("hbm/DRAM_0_STAT_TEMP",
         "the HBM stack temperature is still going nowhere"),
        ("hbm/DRAM_0_STAT_CATTRIP",
         "the HBM stacks' catastrophic-temperature signal is still asserting "
         "into the void"),
        ("hbm/DRAM_1_STAT_CATTRIP",
         "stack 1's catastrophic-temperature signal is still unconnected"),
        ("clk_wiz_0/clk_out1] [get_bd_pins fk33_therm_0/hbm_pclk",
         "the HBM APB clock is not wired in, so the HBM sensor has no "
         "liveness check at all"),
        # Specific to the CONNECTION, not just the pin name: "/fk33_therm_0/
        # compute_clk" also appears in the block-design check's allowlist, and a
        # loose needle would be satisfied by that and test nothing.  Found by
        # running this guard against a broken copy and watching it NOT bite.
        ("[get_bd_pins fk33_therm_0/compute_clk]",
         "the compute domain is not wired in, so the halt has no domain to "
         "be synchronised into and the canary cannot run"),
        ("assign_bd_address -offset 0x00004000",
         "the thermal registers are not on jtag_aux, so a thermal trip would "
         "be unreadable with the PCIe link down"),
        ("assign_bd_address -offset 0x0000B000",
         "the thermal registers are not on the PCIe BAR, so the host cannot "
         "see why the card stopped computing"),
        # The read-back checks themselves.  A check that only runs in
        # --bd-only mode does not cover the artefact that gets flashed, and a
        # check that reads a BD parameter reads a REQUEST rather than the
        # answer.  Both of those were true until 2026-08-28.
        ("FK33_SYSMONI FAIL: expected exactly one SYSMONE4",
         "the build no longer reads the alarm thresholds out of the ROUTED "
         "netlist, so nothing proves the trip points in the bitstream are the "
         "ones this design asked for"),
        ("OT arming nibble 53h",
         "the build no longer reports whether SYSMON's automatic power-down is "
         "armed, which is the one thermal behaviour that is baked into the "
         "silicon rather than into the fabric"),
    ):
        if need not in text:
            sys.exit(f"ABORT: {why} ({need!r} missing).")
    # STRUCTURAL, not textual.  The thermal read-back used to sit inside the
    # FK33_STOP_AFTER_BD block, so the build that produced the bitstream never
    # ran it -- the only evidence came from a separate --bd-only run against a
    # Tcl that was not provably the same file.  Position is the whole point of
    # that fix, and a needle for the text alone would still pass if someone
    # moved it back inside the gate.
    i_gate = text.find("info exists ::env(FK33_STOP_AFTER_BD)")
    i_sys  = text.find("FK33_SYSMON $p = ")
    i_hbm  = text.find("FK33_THERM hbm/$hp connected")
    if i_gate < 0 or i_sys < 0 or i_hbm < 0:
        sys.exit("ABORT: the thermal block-design read-back is missing entirely.")
    if i_sys > i_gate or i_hbm > i_gate:
        sys.exit("ABORT: the thermal read-back is inside the FK33_STOP_AFTER_BD "
                 "block, so a full build would never run it and the bitstream "
                 "would ship with the SYSMON configuration unverified.")

    # The aux branch must be clocked by fk33_aux_0/aux_clk and by nothing else.
    for cell in ("jtag_aux", "auxconnect") + AUX_CELLS:
        if f"{cell}/aclk] [get_bd_pins fk33_aux_0/aux_clk]" not in text and \
           f"{cell}/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]" not in text and \
           "[get_bd_pins $c/s_axi_aclk]    [get_bd_pins fk33_aux_0/aux_clk]" not in text:
            sys.exit(f"ABORT: {cell} is not clocked from the aux domain.")

    open(DST, "w").write(HEADER + text)
    print(f"wrote {DST}")

    # ---- XDC ---------------------------------------------------------------
    # Three edits:
    #   * lanes 4-15 do not exist on an x4 endpoint, and left constrained they
    #     fill the log with "No ports matched" warnings that would mask a real
    #     constraint error;
    #   * the sysref_clk_* constraints STAY (they used to be commented out).
    #     The aux domain instantiates the same IBUFDS the EnablePCIe == 0
    #     branch does, with the same external interface name, so those ports
    #     exist again;
    #   * the two debug-hub lines are superseded.  The hub currently takes its
    #     clock from hbm/.../APB_0_PCLK, which in THIS branch is an MMCM output
    #     referenced to xdma/axi_aclk with the MMCM held in reset by
    #     xdma/axi_aresetn -- i.e. dead exactly when it is needed.
    xdc = open(XDC_SRC).read()
    out, n_lane, n_sysref, n_hub = [], 0, 0, 0
    for line in xdc.splitlines():
        drop_lane = any(f"{sig}[{i}]" in line
                        for i in range(4, 16)
                        for sig in ("pcie_rxp", "pcie_rxn",
                                    "pcie_txp", "pcie_txn"))
        drop_sysref = any(p in line for p in NO_PCIE_ONLY_PORTS)
        drop_hub = ("connect_debug_port dbg_hub/clk" in line
                    or "C_CLK_INPUT_FREQ_HZ" in line)
        if drop_lane:
            out.append("# [gen_pcieep] x4 endpoint, lane not present: " + line)
            n_lane += 1
        elif drop_sysref:
            out.append("# [gen_pcieep] EnablePCIe=1, port not present: " + line)
            n_sysref += 1
        elif drop_hub:
            out.append("# [gen_pcieep] superseded, see the aux domain below: "
                       + line)
            n_hub += 1
        else:
            out.append(line)

    if n_lane != 48:
        sys.exit(f"ABORT: expected 48 lane constraint lines for lanes 4-15 "
                 f"(12 lanes x 4 signals), found {n_lane}. Refusing to emit an "
                 "XDC that may leave a used lane unconstrained.")
    if n_sysref != 0:
        sys.exit(f"ABORT: {n_sysref} sysref_clk constraint lines were dropped. "
                 "The aux domain needs that oscillator; dropping its pin "
                 "constraints would leave the only free-running clock in the "
                 "design unplaced.")
    if n_hub != 2:
        sys.exit(f"ABORT: expected to supersede exactly 2 debug-hub lines "
                 f"(C_CLK_INPUT_FREQ_HZ and connect_debug_port), found {n_hub}. "
                 "Refusing to emit an XDC that may leave the debug hub on a "
                 "clock that stops when the PCIe link is down.")

    out += AUX_XDC
    out += ENG_XDC
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
    print(f"wrote {XDC_DST}  ({n_lane} lane constraints superseded, "
          f"{n_hub} debug-hub lines superseded, sysref kept)")


if __name__ == "__main__":
    main()
