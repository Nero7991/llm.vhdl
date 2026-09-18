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
# Implementation-only floorplan.  Hand-written, NOT generated -- see its header.
PBLOCK_XDC = os.path.join(HERE, "fk33_pblock.xdc")
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
# THE HOST SEAM'S BASE ADDRESS (TRACK SEAMMAP, 2026-08-30).  DECIDED HERE.
#
# `server/fk33_seam.h` has carried `FK33_SEAM_BASE_PROPOSED = 0x0000E000`
# since TRACK SERVER, with its own comment saying "the name stays _PROPOSED
# until `grep -n 0xE000 hw/fk33/gen_pcieep.py` returns a line".  This is that
# line.  Oren resolved board row N2 on 2026-08-30 in favour of option (a) --
# "we don't want host controlling, let's get D working" -- so the block exists
# (`rtl/fk33_seam.vhd`, TRACK DSEAM) and the only thing it lacked was an
# address.
#
# WHY 0xE000 AND NOT SOMETHING ELSE.  Three things had to hold and all three
# were checked against the EMITTED build script rather than against a
# document, because the emitted script is what Vivado reads:
#
#   1. IT IS FREE.  MEASURED occupancy of the PCIe AXI-Lite BAR at
#      d53af73, from `grep assign_bd_address hw/fk33/build_fk33_pcieep.tcl`:
#        0x3000 SYSMON, 0x9000 GPIO, 0xA000 fk33_id, 0xB000/0xC000/0xD000
#        thermal, 0x10000+8K scratch, 0x12000 eng ctl, 0x13000 eng xw.
#      0xE000 and 0xF000 are the only 4 KB holes below the scratch BRAM, and
#      0xE000 is the lower of the two.  NOTE that the occupancy list in
#      `server/fk33_seam.h` said "0x3400 (SYSMON)": that is SYSMON's
#      temperature REGISTER, not the block base, which is 0x3000 with a 4 KB
#      range.  Corrected there in the same commit.  It does not change the
#      answer, and it is exactly the kind of hand-maintained map that
#      check_bar_map below exists to stop trusting.
#   2. IT IS INSIDE THE BAR.  The XDMA IP is asked for a 128 KB AXI-Lite
#      master (`CONFIG.axilite_master_size {128}` /
#      `axilite_master_scale {Kilobytes}`), i.e. 0x00000..0x1FFFF, and
#      0xE000 + 0x1000 = 0xF000 is under it.  READ THE CAVEAT: that is a
#      REQUEST in the Tcl, not an answer, and this project has already been
#      bitten by reading a block-design CONFIG.* as though it were a report.
#      What actually answers it is `assign_bd_address` itself refusing with
#      BD 41-1075 -- which is how 0x11000 was caught colliding with the 8 KB
#      scratch -- i.e. the `--bd-only` gate, not this file.
#   3. IT IS 4 KB ALIGNED.  `rtl/fk33_seam.vhd`'s slave takes
#      `s_axi_awaddr(11 downto 0)`, so anything but a 4 KB-aligned base
#      would alias its own register file.  `FK33_SEAM_SPAN` in the header is
#      0x1000 and matches.
#
# REJECTED, with the reason, so nobody re-opens it: moving the seam to
# 0x14000 to sit next to the engine's 0x12000/0x13000 is purely cosmetic and
# costs an edit to both halves of a host contract that already agrees on
# 0xE000.  A base that only one side believes in is worse than no base.
SEAM_BASE  = 0x0000E000
SEAM_SPAN  = 0x1000            # 4 KB, one AXI-Lite page
SEAM_CELL  = "fk33_seam_0"
SEAM_RTL   = os.path.join(os.path.normpath(os.path.join(HERE, "..", "..",
                                                        "rtl")),
                          "fk33_seam.vhd")
# `rtl/fk33_seam.vhd` and `server/fk33_seam.h` are the two halves of one
# contract and this generator is the third copy of the number.  All three are
# cross-checked in main(); a bare copy here would be a third chance to be
# wrong.
SEAM_MAGIC = 0x4C4C4D32        # "LLM2"
# d_err_code presented to the seam while there is NO subsystem D behind it.
# 0xF is chosen because `rtl/llama_top.vhd` reports 4-bit codes from
# `seq_desc_fetch`/`seq_opdec` and none of them is 0xF, so a host reading
# ERR_INFO[3:0] = 0xF is reading "there is no D in this bitstream" and not a
# real D fault.  See SEAM_BLOCK for why this is tied HIGH rather than low.
SEAM_NO_D_CODE = 0xF

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
# THE CORE CLOCK IS OVERRIDABLE, and the reason is a decision, not a tuning knob.
#
# Oren, 2026-09-05, verbatim: "It's okay if we don't hit 200MHz, let's prioritise
# inference and then optimise once we have that."
#
# That answers a question this repository had left open in writing.  The
# 2026-09-03 WORKLOG entry on the wired top closes: "Also unmeasured: whether
# 200 MHz is needed.  181.7 MHz is 91% of target and no throughput requirement
# here has been checked against it.  That question is worth answering BEFORE
# spending retiming effort."
#
# WHAT IS MEASURED, and why 200 was never reachable by the FULL design:
#
#   shell + subsystem A only (ships today)      core WNS  +0.001   200.0 MHz
#   the WIRED top, `wire4`, routed clean        core WNS  -0.502   181.7 MHz
#   composed top, best directives, `c4nd`       core WNS  -0.422   184.4 MHz
#   composed top, no directives, `c4base`       core WNS  -0.637   177.4 MHz
#
# So 200.000 is met by A ALONE and by nothing containing B, C and D.  Holding
# the constant at 200 does not make the full design faster; it makes it
# unbuildable, which is how a timing target becomes a schedule blocker.
#
# WHAT LOWERING IT COSTS, stated exactly.  The duty identity above is
# `duty = f_core / f_axi`, with no efficiency term because 27 x 256 bits is
# 864 B exactly.  At 250 MHz HBM: 200 -> 80.0% duty, 175 -> 70.0%.  A lower
# core clock therefore RELAXES the HBM side rather than stressing it; the cost
# is compute throughput, proportional and only where compute-bound.
#
# THE DEFAULT STAYS 200.000 DELIBERATELY.  The shipping shell+A bitstream met
# timing at 200 and must remain reproducible byte-for-byte; changing this
# constant in place would silently retarget it.  A full-engine build selects a
# lower value explicitly:
#
#     FK33_ENG_CORE_MHZ=175 python3 hw/fk33/gen_pcieep.py ...
#
# 175.000 is the suggested full-engine value: 181.7 MHz measured leaves 3.8%
# margin, and margin is the point, since every figure above is a ROUTED number
# on an OOC block and the block design adds a shell those runs never saw.
ENG_CORE_MHZ   = float(os.environ.get("FK33_ENG_CORE_MHZ", "200.000"))
# LEVER C.  `fk33_engine`'s CB_STYLE, forwarded to matvec_int4_desc_axi and on
# to matvec_core, where it decides whether the IQ4_NL codebook lives in
# registers ("regs") or in LUTRAM ("distributed").  matvec_core hard-errors on
# any other value.
#
# DEFAULT "regs", UNCHANGED, because that is the shipping value and the one the
# engine's own header calls out as keeping the entity byte-identical in
# behaviour to the bitstream on card 1.  This is opt-in.
#
# WHY IT IS REACHABLE ONLY HERE.  `fk33_engine.vhd:67` states it: `-generic`
# reaches the TOP's generics and never a deep instance, so the value has to be
# set as a CONFIG property on the block-design cell.
#
# WHY IT EXISTS.  MEASURED 2026-09-16: the first full FK33_CARD=1 build
# SYNTHESISED with 0 errors and was then REFUSED by the placer --
# `[DRC UTLZ-1] ... requires 479919 CLB LUTs but only 439680 are available`,
# 109.15%.  Registers (56%), BRAM, DSP and the mux columns all had headroom; it
# is purely LUT-bound.  TRACK LEVERC48 measured this lever at -42,633 CLB LUT
# with MUXF7 24,583 -> 0 and MUXF8 12,288 -> 0, against a ~40,239 LUT overage.
# That figure is 264 commits old and is NOT quoted as a prediction here -- the
# point of making it settable is to MEASURE it on the current tree.
# SUBSYSTEM A, ON OR OFF.  Default ON -- this is opt-OUT and the shipping
# configuration is unchanged.
#
# WHY IT EXISTS.  MEASURED 2026-09-16: the full FK33_CARD=1 design SYNTHESISES,
# PLACES and MEETS TIMING at 75 MHz (WNS +0.222, TNS 0.000) and then fails
# `[Route 35-3] Design is not routable as its global congestion level is 7` at
# 426,882 CLB LUTs, 97.09%.  Congestion-directed place and route
# (AltSpreadLogic_high / Explore) reached the IDENTICAL level 7, so the density
# is not directive-addressable.  Reaching a routable ~90% needs about 31,000
# LUT removed and every knob is spent.
#
# `eng` is 90,874 LUT of the 426,882.  Dropping it leaves roughly 336,000
# (about 76%), which routes with room -- and produces the first bitstream this
# project has ever built containing subsystems B, C and D.
#
# WHAT SUCH A BITSTREAM IS NOT: a working accelerator.  With no engine the
# card's `a_*` inputs have no driver, so an A job issued by D never completes.
# It proves the FLOW -- synthesis, placement, routing, timing and bitstream
# generation over B, C, D, the host seam and the PCIe/HBM shell -- and nothing
# about subsystem A.  Label it that way wherever it is used.
ENG_ON         = os.environ.get("FK33_ENG", "1") == "1"
ENG_CB_STYLE   = os.environ.get("FK33_CB_STYLE", "regs")
if ENG_CB_STYLE not in ("regs", "distributed"):
    raise SystemExit("FK33_CB_STYLE must be regs or distributed, got %r"
                     % ENG_CB_STYLE)
# Refuse a value that cannot be met or cannot be built.  The clocking wizard
# will happily accept nonsense and fail much later, in HDL generation, with a
# message that does not name this variable.
if not (50.0 <= ENG_CORE_MHZ <= 250.0):
    sys.exit("ABORT: FK33_ENG_CORE_MHZ=%r is outside 50..250 MHz. The HBM AXI "
             "side runs at 250 MHz and duty = f_core/f_axi must not exceed 1.0; "
             "below 50 MHz the aux-domain canary counters lose meaning."
             % ENG_CORE_MHZ)
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


# THE CORE CLOCK DOMAIN AND THE CONTROL INTERCONNECT ARE *NOT* PART OF
# SUBSYSTEM A, although they were emitted inside _eng_block until 2026-09-16.
# `core_reset` resets the card as well as the engine, and `axil2eng` is the
# only AXI-Lite path into the core clock domain, so the HOST SEAM hangs off it
# whether or not there is an engine.  MEASURED: with FK33_ENG=0 the whole block
# was skipped and the --bd-only run died at
#   WARNING: [BD 5-230] No cells matched 'get_bd_cells axil2eng'
#   ERROR:   [Common 17-55] 'get_property' expects at least one object.
# in SEAM_BLOCK -- i.e. gating on "subsystem A" took two things with it that
# subsystem A does not own.  They are factored into these two helpers rather
# than duplicated, so the FK33_ENG=1 text stays byte-identical (checked by
# selftest) and the two configurations cannot drift apart.


def _core_reset_lines():
    return [
        "# THE CORE CLOCK.  A third MMCM output rather than a reuse of clk_out2:",
        "# clk_out2 is HBM_REF_CLK_0/1, and sharing the HBM reference clock net with",
        "# a fabric datapath clock would tie two unrelated requirements together for",
        "# no gain.  clk_wiz_0's reference is xdma/axi_aclk in this branch, so the",
        "# core clock stops with the PCIe link -- which is correct: with no host",
        "# there is no job, and the thermal guard is on the aux domain and does not",
        "# stop with it.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset",
        "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins core_reset/slowest_sync_clk]",
        "connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins core_reset/dcm_locked]",
        "connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]",
    ]


def _axil2eng_lines(num_mi):
    """The AXI-Lite bridge from xdma's domain into the core domain.

    NUM_MI is 2 with an engine (s_axi and s_axix) and 1 without, because a
    smartconnect master interface that is created and never connected is not
    prunable -- it reaches HDL generation as a dangling interface.  The host
    seam appends itself to whatever this leaves; see SEAM_BLOCK.
    """
    return [
        "# CONTROL.  A dedicated smartconnect because the engine's AXI-Lite slave is",
        "# in the CORE clock domain (matvec_int4_desc_axi's s_axi_aclk IS the core",
        "# clock) while pcie2axil is in xdma's.  NUM_CLKS 2 with aclk on the incoming",
        "# side and aclk1 on the outgoing side is exactly the shape",
        "# build_fk33_hbmbw.tcl:334-341 used for axil2tg, which built, routed and ran.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2eng",
        "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {%d} CONFIG.NUM_CLKS {2}] [get_bd_cells axil2eng]" % num_mi,
        "set n [get_property CONFIG.NUM_MI [get_bd_cells pcie2axil]]",
        "set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells pcie2axil]",
        "connect_bd_intf_net [get_bd_intf_pins pcie2axil/[format M%02d_AXI $n]] \\",
        "                    [get_bd_intf_pins axil2eng/S00_AXI]",
        "connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins axil2eng/aclk]",
        "connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins axil2eng/aresetn]",
        "connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins axil2eng/aclk1]",
    ]


def _noeng_core_block():
    """FK33_ENG=0: no engine, but the core domain and its AXI-Lite path stay."""
    L = ["",
         "# ---- SUBSYSTEM A OMITTED (FK33_ENG=0) -------------------------------------",
         "# The `eng` cell, its 28 HBM read masters and its AXI-Lite control slave are",
         "# absent.  See ENG_ON for why, and for what a bitstream built this way does",
         "# and does not prove.  What is NOT absent: core_reset, which the card needs,",
         "# and axil2eng, which carries the host seam into the core clock domain.",
         ""]
    L.extend(_core_reset_lines())
    L.append("")
    L.extend(_axil2eng_lines(1))
    L.append("# ---- end core domain ------------------------------------------------------")
    L.append("")
    return "\n".join(L)


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
    if ENG_CB_STYLE != "regs":
        a("")
        a("# LEVER C, opt-in via FK33_CB_STYLE.  A module-reference cell takes a")
        a("# generic as a CONFIG property; `-generic` on synth_design would reach")
        a("# only the top and never this instance (fk33_engine.vhd:67).")
        a("set_property CONFIG.CB_STYLE {%s} [get_bd_cells %s]"
          % (ENG_CB_STYLE, ENG_CELL))
        a("# READ BACK.  Vivado silently ignores a set_property whose target did")
        a("# not match, and this file already does this for every other CONFIG it")
        a("# sets.  A lever that was quietly not applied looks exactly like a")
        a("# lever that did not work.")
        a("set _cb [get_property CONFIG.CB_STYLE [get_bd_cells %s]]" % ENG_CELL)
        a("if {$_cb ne \"%s\"} {" % ENG_CB_STYLE)
        a("    error \"FK33_CB_STYLE FAIL: CONFIG.CB_STYLE is \\\"$_cb\\\", not %s\""
          % ENG_CB_STYLE)
        a("}")
        a("puts \"FK33_CB_STYLE $_cb\"")
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
    L.extend(_core_reset_lines())
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
    L.extend(_axil2eng_lines(2))
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


ENGINE_BLOCK = _eng_block() if ENG_ON else _noeng_core_block()

# ============================================================================
# THE CARD CELL (subsystems B, C, D) AND THE B/C GRANT.  gen_pcieep.py
# ============================================================================
# Gated behind FK33_CARD=1.  With it unset this file emits exactly what it
# emitted before, so the engine-only build that has produced bitstreams is
# not disturbed by work that has never been through --bd-only.
#
# THREE CELLS, NOT ONE.  `hw/fk33/rtl/fk33_card.vhd` wraps fk33_llama_top and
# carries B, C and D; `hw/fk33/rtl/fk33_bc_grant.vhd` wraps bc_port_grant and
# multiplexes B's and C's HBM traffic onto the ports that are left; `eng`
# above is subsystem A.  Both wrappers are GENERATED by
# hw/fk33/gen_fk33_card.py -- edit that, not these -- because a block-design
# cell may not have an `integer` port, may not size a port with a function of
# a generic, and may not present a flattened std_logic_vector where an AXI
# interface is wanted.  None of those three rules is reachable by simulation.
#
# THE PORT BUDGET, and it is exact rather than comfortable:
#   32 HBM SAXI, minus SAXI_00 and SAXI_16 for the host (one per stack),
#   minus subsystem A's 28 in ENG_PORT_MAP, leaves 30 and 31.
# The grant's pool is 2 because of that, not by coincidence: C's write rides
# port 0's idle WRITE channels beside the reads that port already carries.
# See docs/debugging/2026-09-07_the-grant-pool-was-one-port-over-budget.md.
CARD_CELL   = "card"
GRANT_CELL  = "bcgrant"
CARD_SAXI   = [30, 31]          # the two the budget leaves
CARD_RTL    = os.path.join(HERE, "rtl", "fk33_card.vhd")
GRANT_RTL   = os.path.join(HERE, "rtl", "fk33_bc_grant.vhd")

# Dependency closure of the two wrappers, in elaboration order, EXCLUDING the
# files ENG_SRCS already adds.  Listed rather than globbed for the reason
# ENG_SRCS gives: a glob picks up whichever file another track has half
# edited.  Regenerate with the closure walker in
# docs/debugging/2026-09-07_wiring-the-card-into-the-block-design.md.
CARD_SRCS = [
    "bc_port_grant.vhd",
    "a_desc_adapter.vhd", "a_job_counter.vhd",
    "attn_emit.vhd", "fixed_luts_pkg.vhd", "attn_gate.vhd",
    "attn_kv_quant.vhd", "attn_mac_array.vhd", "divider_rs.vhd",
    "attn_recip.vhd", "attn_rope.vhd", "attn_score_q12.vhd",
    "attn_softmax.vhd", "imrope_pkg.vhd", "attn_twiddle.vhd",
    "fixed_pkg.vhd", "rmsnorm_rs.vhd", "attn_block.vhd", "attn_kv_axi.vhd",
    "gdn_conv.vhd", "gdn_head_emit.vhd", "gdn_silu.vhd", "gdn_y_emit.vhd",
    "rmsnorm_bf.vhd", "gdn_emit_chain.vhd", "gdn_exp_capture.vhd",
    "gdn_recur_pipe.vhd", "gdn_scalar.vhd", "l2norm_rs.vhd", "gdn_block.vhd",
    "gdn_job_seq.vhd", "gdn_conv_tap_mem.vhd", "gdn_exp_mem.vhd",
    "gdn_state_axi.vhd", "gdn_state_mem.vhd", "gdn_state_store.vhd",
    "model_cfg_pkg.vhd", "llama_map_pkg.vhd",
    "region_mem.vhd", "vec_mem.vhd", "rmsnorm_rs_mem.vhd",
    "sampler_stream.vhd", "seq_desc_fetch.vhd", "seq_opdec.vhd",
    "seq_region_lock.vhd", "seq_vec_issue.vhd", "seq_vec_res.vhd",
]

# VHDL 2008, STATED RATHER THAN INHERITED.  `add_files` alone leaves a .vhd at
# Vivado's default, which is VHDL-93, and B/C/D do not compile as 93:
# `rtl/a_desc_adapter.vhd` READS ITS OWN `out` PORTS (`m_awvalid` at :269,
# `m_wvalid` at :270, and `u_done`/`u_ready` inside asserts at :318 and :321),
# which 2008 allows and 93 does not.
#
# MEASURED 2026-09-08: without this the card build dies with four
# `[Synth 8-10557] cannot read from 'out' object ...; use 'buffer' or 'inout'
# instead`, then `8-6156 failed synthesizing module 'bd'`. **No bench can reach
# this** -- GHDL is invoked with `--std=08` throughout, so every one of these
# files simulates cleanly and the defect exists only in the synthesis flow.
# AND THE TWO WRAPPER TOPS MUST *NOT* BE VHDL 2008.  The requirements are
# OPPOSITE and each error is invisible until the other is fixed, which is the
# same shape as the IP_Flow 19-734 / 19-627 pair this project already records.
#
# MEASURED 2026-09-08, immediately after setting all 50 files to 2008:
#   ERROR: [filemgmt 56-195] Reference 'fk33_card' contains top file
#   '.../fk33_card.vhd' of type VHDL 2008. This type is not allowed as the top
#   file in the reference.
# then `[BD 41-1690] Unable to resolve module-source` and the create_bd_cell
# fails. A `create_bd_cell -type module -reference` top must be VHDL-93.
#
# That is fine and not a compromise: hw/fk33/gen_fk33_card.py emits both
# wrappers as plain entity-plus-instantiation with every width folded to a
# literal, precisely so they carry no 2008 construct. The 2008 code is all
# BELOW them, in the sources listed here.
_CARD_2008 = ([os.path.join(ENG_SRC_DIR, f) for f in CARD_SRCS]
              + [os.path.join(ENG_SRC_DIR, "fk33_llama_top.vhd")])
_CARD_ALL = _CARD_2008 + [GRANT_RTL, CARD_RTL]

CARD_RTL_ADD = "\n".join(
    ["", "# ---- subsystems B/C/D RTL (gen_pcieep.py) ---------------------------------"]
    + ["add_files -norecurse %s" % f for f in _CARD_ALL]
    + ["set_property FILE_TYPE {VHDL 2008} [get_files {%s}]" % f for f in _CARD_2008]
    + ["# READ BACK.  A path that did not match leaves the file at VHDL-93 and",
       "# the failure is 400 lines later in a generated bd.v, naming neither",
       "# the file nor the standard.",
       "foreach f {%s} {" % " ".join(_CARD_2008),
       "    set t [get_property FILE_TYPE [get_files -quiet $f]]",
       "    if {$t ne \"VHDL 2008\"} {",
       "        error \"FK33_CARD FAIL: $f is FILE_TYPE \\\"$t\\\", not VHDL 2008.\"",
       "    }",
       "}",
       "puts \"FK33_CARD %d sources set to VHDL 2008 (the two wrapper tops stay VHDL-93)\"" % len(_CARD_2008),
       "update_compile_order -fileset sources_1", ""])

# ---- the A seam, engine <-> card.  Signal level, not AXI. -----------------
# (card pin, engine pin).  Direction is card-out/engine-in for the first
# group and engine-out/card-in for the second; connect_bd_net does not care,
# but a mistake here is a driver conflict rather than a missing net, so the
# two groups are kept apart and named.
CARD_SEAM_TO_ENG = [
    ("a_job_index", "job_index"),
    ("a_x_we",      "d_x_we"),
    ("a_x_waddr",   "d_x_waddr"),
    ("a_x_wdata",   "d_x_wdata"),
]
CARD_SEAM_FROM_ENG = [
    ("a_y_we",     "d_y_we"),
    ("a_y_addr",   "d_y_addr"),
    ("a_y_data",   "d_y_data"),
    ("a_y_mask",   "d_y_mask"),
    ("a_y_exp",    "d_y_exp"),
    ("a_job_done", "d_job_done"),
    ("a_job_err",  "d_job_err"),
]

# ---- the HOST seam, fk33_seam <-> card ------------------------------------
# Every one of these replaces a constant in _SEAM_TIES.  The tie-offs existed
# because subsystem D was absent; the card carries D, so they come out.  The
# pairs are (seam pin, card pin) and are 1:1 by construction -- _SEAM_TIES has
# twenty entries and so does this list.
SEAM_FROM_CARD = [
    ("d_busy",       "busy"),
    ("d_tok_done",   "tok_done"),
    ("d_err",        "err"),
    ("d_err_code",   "err_code"),
    ("d_err_step",   "err_step"),
    ("d_steps_done", "steps_done"),
    ("d_raddr",      "d_raddr"),
    ("d_ren",        "d_ren"),
    ("hr_data",      "hr_data"),
    ("obs_issue",    "obs_issue"),
    ("obs_tok_pos",  "obs_tok_pos"),
    ("smp_token",    "smp_token"),
    ("smp_n",        "smp_n"),
    ("smp_exp",      "smp_exp"),
    ("f_smp_ovf",    "err_smp_ovf"),
    ("f_lost_beat",  "err_lost_beat"),
    ("f_gate_drop",  "err_gate_drop"),
    ("f_unit_stub",  "err_unit_stub"),
    ("f_e_coll",     "err_e_coll"),
    ("f_kv_err",     "kv_err"),
]
SEAM_TO_CARD = [
    ("d_go",         "go"),
    ("d_abort",      "abort"),
    ("d_tbl_len",    "tbl_len"),
    ("d_host_x_exp", "host_x_exp"),
    ("d_rel_mask",   "rel_mask"),
    ("d_tok_ack",    "tok_ack"),
    ("d_rdata",      "d_rdata"),
    ("d_rvalid",     "d_rvalid"),
    ("hw_we",        "hw_we"),
    ("hw_reg",       "hw_reg"),
    ("hw_addr",      "hw_addr"),
    ("hw_data",      "hw_data"),
    ("hr_reg",       "hr_reg"),
    ("hr_addr",      "hr_addr"),
]

# ---- B and C onto the grant ----------------------------------------------
# (grant pin, card pin).  The card's masters carry five AXI signals the grant
# does not model -- arsize, arburst, wstrb, rresp, bresp -- because the grant
# arbitrates ownership and does not transform a burst.  Those are handled at
# the HBM end by GRANT_TIES below rather than being dropped silently here.
GRANT_B = ["arvalid", "arready", "araddr", "arlen",
           "rvalid", "rready", "rdata", "rlast",
           "awvalid", "awready", "awaddr", "awlen",
           "wvalid", "wready", "wdata", "wlast",
           "bvalid", "bready"]
GRANT_CRD = ["arvalid", "arready", "araddr", "arlen",
             "rvalid", "rready", "rdata", "rlast"]
GRANT_CWR = ["awvalid", "awready", "awaddr", "awlen",
             "wvalid", "wready", "wdata", "wlast", "bvalid", "bready"]


def _card_block():
    L = []
    a = L.append
    a("")
    a("# ---- SUBSYSTEMS B, C, D + THE B/C GRANT (gen_pcieep.py) -------------------")
    a("create_bd_cell -type module -reference fk33_card %s" % CARD_CELL)
    a("create_bd_cell -type module -reference fk33_bc_grant %s" % GRANT_CELL)
    a("")
    a("# WHAT VIVADO ACTUALLY INFERRED, printed rather than assumed.  The name of")
    a("# an inferred interface is the PORT PREFIX, not the prefix plus `_axi`:")
    a("# `a_awvalid` gives an interface called `a`, and the engine's `m00_axi_*`")
    a("# gives `m00_axi` only because `_axi` is part of its port names.  Guessing")
    a("# `card/a_axi` cost a --bd-only run that got through every cell, both")
    a("# clocks and all eleven A-seam nets before failing on BD 5-232.")
    a("foreach c {%s %s} {" % (CARD_CELL, GRANT_CELL))
    a("    foreach i [get_bd_intf_pins -quiet $c/*] {")
    a("        puts \"FK33_CARD INTF $c [file tail $i]\"")
    a("    }")
    a("}")
    a("")
    a("# CLOCKS.  Both cells sit wholly in the CORE domain -- clk_wiz_0/clk_out3 --")
    a("# including the HBM-facing side of the grant, which is why the grant's")
    a("# m0/m1 need a clock converter at the HBM end if the two ever differ.  They")
    a("# do not today: ENGINE_BLOCK already drives every SAXI ACLK from")
    a("# xdma/axi_aclk, so CARD_CDC below is where that assumption is checked")
    a("# rather than assumed.")
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins %s/clk]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins %s/clk]" % GRANT_CELL)
    a("")
    a("# RESET POLARITY, read back rather than assumed.  The card takes an ACTIVE")
    a("# HIGH `rst` and the grant an ACTIVE LOW `rstn`, so one of them gets the")
    a("# inverted form.  Getting this backwards holds a subsystem in reset")
    a("# forever, which looks exactly like a subsystem that never starts.")
    a("set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_pins %s/rst]" % CARD_CELL)
    a("set_property CONFIG.POLARITY ACTIVE_LOW  [get_bd_pins %s/rstn]" % GRANT_CELL)
    a("connect_bd_net [get_bd_pins core_reset/peripheral_reset]   [get_bd_pins %s/rst]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins %s/rstn]" % GRANT_CELL)
    a("")
    if ENG_ON:
        a("# ---- the A seam, card <-> eng --------------------------------------------")
        for cp, ep in CARD_SEAM_TO_ENG + CARD_SEAM_FROM_ENG:
            a("connect_bd_net [get_bd_pins %s/%s] [get_bd_pins %s/%s]"
              % (CARD_CELL, cp, ENG_CELL, ep))
    else:
        a("# ---- the A seam is ABSENT (FK33_ENG=0) ------------------------------------")
        a("# The card's a_* OUTPUTS drive nothing and its a_* INPUTS have no driver,")
        a("# so unit A never reports done and any A job issued by D hangs.  That is")
        a("# expected and is the whole cost of this configuration; see ENG_ON.")
    a("")
    if ENG_ON:
        a("# THE CARD'S AXI-LITE MASTER ONTO THE ENGINE'S CONTROL SLAVE.  Two masters")
        a("# now want eng/s_axi: the host, to place DESC_PTR and the arena base before")
        a("# a run, and the card, to issue one job per A step during it.  The existing")
        a("# net is DELETED and both go through a 2:1 smartconnect, rather than")
        a("# ENGINE_BLOCK being edited, so that block stays exactly what the")
        a("# engine-only build already proved.")
        a("delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins %s/s_axi]]" % ENG_CELL)
        a("create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 engctl")
        a("set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells engctl]")
        a("connect_bd_net [get_bd_pins xdma/axi_aclk]      [get_bd_pins engctl/aclk]")
        a("connect_bd_net [get_bd_pins xdma/axi_aresetn]   [get_bd_pins engctl/aresetn]")
        a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins engctl/aclk1]")
        a("connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins engctl/S00_AXI]")
        a("connect_bd_intf_net [get_bd_intf_pins %s/a]             [get_bd_intf_pins engctl/S01_AXI]" % CARD_CELL)
        a("connect_bd_intf_net [get_bd_intf_pins engctl/M00_AXI]   [get_bd_intf_pins %s/s_axi]" % ENG_CELL)
    else:
        a("# The card's AXI-Lite master `card/a` has no engine to drive and is left")
        a("# unconnected; `axil2eng` likewise terminates nowhere.  Vivado prunes both.")
    a("")
    a("# ---- the host seam, fk33_seam <-> card ------------------------------------")
    a("# Subsystem D is PRESENT now, so _seam_block skipped every _SEAM_TIES")
    a("# constant that stood in for it -- the tie-off is not emitted rather than")
    a("# emitted and deleted, so check_seam_tieoff's reading of the script text")
    a("# stays true.  The xlconstant cells still exist for the pins NOT in")
    a("# SEAM_FROM_CARD; Vivado drops any that end up unused.")
    for sp, cp in SEAM_FROM_CARD:
        a("connect_bd_net [get_bd_pins %s/%s] [get_bd_pins %s/%s]"
          % (SEAM_CELL, sp, CARD_CELL, cp))
    for sp, cp in SEAM_TO_CARD:
        a("connect_bd_net [get_bd_pins %s/%s] [get_bd_pins %s/%s]"
          % (SEAM_CELL, sp, CARD_CELL, cp))
    a("")
    a("# ---- B and C onto the grant -----------------------------------------------")
    for sig in GRANT_B:
        a("connect_bd_net [get_bd_pins %s/b_%s] [get_bd_pins %s/bst_%s]"
          % (GRANT_CELL, sig, CARD_CELL, sig))
    for i in (0, 1):
        for sig in GRANT_CRD:
            a("connect_bd_net [get_bd_pins %s/c%d_%s] [get_bd_pins %s/kv%d_%s]"
              % (GRANT_CELL, i, sig, CARD_CELL, i, sig))
    for sig in GRANT_CWR:
        a("connect_bd_net [get_bd_pins %s/c_%s] [get_bd_pins %s/kv_%s]"
          % (GRANT_CELL, sig, CARD_CELL, sig))
    a("")
    a("# THE REQUESTS.  Neither B nor C exposes a `want the bus` line, and their")
    a("# `busy` outputs are the WRONG signal: busy means `I have traffic in")
    a("# flight`, which cannot be asserted before the grant is held, so using it")
    a("# would be circular -- no grant without traffic, no traffic without a")
    a("# grant.  A master's own VALID is the correct request: AXI requires VALID")
    a("# to stay asserted until READY, so a denied requester holds its request up")
    a("# by the rules of the protocol and no separate handshake is needed.")
    a("create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 b_req_or")
    a("set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells b_req_or]")
    a("connect_bd_net [get_bd_pins %s/bst_arvalid] [get_bd_pins b_req_or/Op1]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins %s/bst_awvalid] [get_bd_pins b_req_or/Op2]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins b_req_or/Res]   [get_bd_pins %s/b_req]" % GRANT_CELL)
    a("create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 c_req_or0")
    a("set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells c_req_or0]")
    a("connect_bd_net [get_bd_pins %s/kv0_arvalid] [get_bd_pins c_req_or0/Op1]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins %s/kv1_arvalid] [get_bd_pins c_req_or0/Op2]" % CARD_CELL)
    a("create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 c_req_or1")
    a("set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells c_req_or1]")
    a("connect_bd_net [get_bd_pins c_req_or0/Res]  [get_bd_pins c_req_or1/Op1]")
    a("connect_bd_net [get_bd_pins %s/kv_awvalid]  [get_bd_pins c_req_or1/Op2]" % CARD_CELL)
    a("connect_bd_net [get_bd_pins c_req_or1/Res]  [get_bd_pins %s/c_req]" % GRANT_CELL)
    a("")
    a("# ---- the grant's pool onto the two SAXI the budget leaves -----------------")
    a("# These two are CONFIG.USER_SAXI_nn {false} in the engine-only build and")
    a("# have to be turned on here.  Every ENABLED port exposes its own ACLK and")
    a("# ARESET_N and leaving them dangling fails HDL generation with 41-758.")
    a("# A CLOCK CONVERTER PER PORT, and the engine is why it is needed HERE and")
    a("# not there.  fk33_engine has TWO clock ports -- core_clk and hbm_aclk --")
    a("# because matvec_int4_desc_axi carries its own async_fifo and crosses the")
    a("# domain INSIDE the unit.  The grant does not: it is one clock domain, and")
    a("# its requesters (the card's B and C) are in the core domain, so its")
    a("# masters come out at clk_out3 while every HBM SAXI is on xdma/axi_aclk.")
    a("# Connecting them directly fails with four BD 41-237 errors -- FREQ_HZ")
    a("# 200000000 against 250000000 and CLK_DOMAIN clk_out1 against axi_aclk --")
    a("# which name the symptom and not the cause.")
    a("#")
    a("# axi_clock_converter rather than a smartconnect: SmartConnect speaks")
    a("# AXI4/AXI4-Lite, and BOTH ends here are AXI3 (the grant's 4-bit length")
    a("# above, and the HBM slave itself), so a smartconnect would have to")
    a("# protocol-convert twice to do a job that is purely a domain crossing.")
    for i, port in enumerate(CARD_SAXI):
        cc = "bc_cdc%d" % i
        a("set_property CONFIG.USER_SAXI_%02d {true} [get_bd_cells hbm]" % port)
        a("create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 %s" % cc)
        a("set_property -dict [list CONFIG.PROTOCOL {AXI3}] [get_bd_cells %s]" % cc)
        a("connect_bd_intf_net [get_bd_intf_pins %s/m%d] [get_bd_intf_pins %s/S_AXI]"
          % (GRANT_CELL, i, cc))
        a("connect_bd_intf_net [get_bd_intf_pins %s/M_AXI] [get_bd_intf_pins hbm/SAXI_%02d]"
          % (cc, port))
        a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins %s/s_axi_aclk]" % cc)
        a("connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins %s/s_axi_aresetn]" % cc)
        a("connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins %s/m_axi_aclk]" % cc)
        a("connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins %s/m_axi_aresetn]" % cc)
        a("connect_bd_net [get_bd_pins xdma/axi_aclk]    [get_bd_pins hbm/AXI_%02d_ACLK]" % port)
        a("connect_bd_net [get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_%02d_ARESET_N]" % port)
        a("# READ BACK.  Vivado silently ignores set_property on a CONFIG name an")
        a("# object does not have, so an IP that quietly stayed AXI4 would fail")
        a("# again at the far end with the same unhelpful 41-237.")
        a("set _p [get_property CONFIG.PROTOCOL [get_bd_cells %s]]" % cc)
        a("if {$_p ne \"AXI3\"} {")
        a("    error \"FK33_CARD FAIL: %s PROTOCOL is \\\"$_p\\\", not AXI3.\"" % cc)
        a("}")
        a("puts \"FK33_CARD %s PROTOCOL $_p -> SAXI_%02d\"" % (cc, port))
    a("foreach i {%s} {" % " ".join("%02d" % p for p in CARD_SAXI))
    a("    set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]")
    a("    if {$v ne \"true\"} {")
    a("        error \"FK33_CARD FAIL: USER_SAXI_$i is \\\"$v\\\", not true. The grant has nowhere to go.\"")
    a("    }")
    a("    puts \"FK33_CARD SAXI_$i ENABLED\"")
    a("}")
    a("")
    if ENG_ON:
        a("# THE CARD'S OWN VIEW OF THE ENGINE, assigned HERE and not in ENGINE_ADDR.")
        a("# `a_awaddr` is 8 bits, so this master can reach 256 bytes; ENGINE_ADDR")
        a("# maps the same slave at 4K for the HOST, and an unqualified")
        a("# assign_bd_address covers EVERY master that can reach the segment. It")
        a("# therefore tried to give this 8-bit master a 4K window and failed with")
        a("# BD 41-1075 -- `the proposed range 4K is greater than the maximum range")
        a("# 256`. Assigning the narrow space first, with an explicit target, leaves")
        a("# ENGINE_ADDR's later call to find this one already mapped and skip it.")
        a("assign_bd_address -offset 0x00000000 -range 256 \\")
        a("    -target_address_space [get_bd_addr_spaces %s/a] \\" % CARD_CELL)
        a("    [get_bd_addr_segs {%s/s_axi/reg0}]" % ENG_CELL)
        a("set _cseg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces %s/a]]" % CARD_CELL)
        a("if {[llength $_cseg] != 1} {")
        a("    error \"FK33_CARD FAIL: %s/a maps [llength $_cseg] segments, not 1. The card cannot issue A jobs.\"" % CARD_CELL)
        a("}")
        a("puts \"FK33_CARD %s/a maps $_cseg\"" % CARD_CELL)
    else:
        a("# THE CARD'S AXI-LITE MASTER MAPS NOTHING (FK33_ENG=0).  There is no")
        a("# eng/s_axi/reg0 to assign, so `card/a` reaches no segment.  Asserted")
        a("# rather than skipped: if a segment ever appears here in this")
        a("# configuration it is a slave this build did not intend to expose to")
        a("# the card, and the assertion is what would say so.")
        a("set _cseg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces %s/a]]" % CARD_CELL)
        a("if {[llength $_cseg] != 0} {")
        a("    error \"FK33_CARD FAIL: %s/a maps [llength $_cseg] segments with no engine in the design: $_cseg\"" % CARD_CELL)
        a("}")
        a("puts \"FK33_CARD %s/a maps nothing: unit A is absent and every A job hangs\"" % CARD_CELL)
    a("")
    a("# ---- end subsystems B, C, D -----------------------------------------------")
    a("")
    return "\n".join(L)


CARD_BLOCK = _card_block()

# THE GATE.  FK33_CARD=1 turns the three-cell card on.  Unset, both strings are
# empty and this file emits byte-for-byte what the engine-only build emitted,
# which is the build that has produced bitstreams.  A half-wired card must not
# be able to break that by merely existing in the file.
CARD_ON = os.environ.get("FK33_CARD", "") == "1"
if not CARD_ON:
    CARD_BLOCK = ""
    CARD_RTL_ADD = ""



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
# THE HOST'S 4K VIEW OF eng/s_axi, and WHY IT NAMES ITS TARGETS WHEN THE CARD
# IS ON.  An unqualified assign_bd_address covers EVERY master that can reach
# the segment.  With the card wired in, `card/a` is one of those masters and
# has an 8-bit address, so the unqualified form tried to give it a 4K window
# and aborted the build with BD 41-1075.  Pre-assigning card/a its 256 bytes
# does NOT make this call skip it -- MEASURED, that was the first fix tried and
# it failed identically -- so the two host spaces are named instead.  They are
# `jtag_axil/Data` and `xdma/M_AXI_LITE`, taken from this call's own log lines
# in the engine-only build rather than guessed.
# The engine's address segments and HBM master mapping, built at module level
# so no conditional indentation can leak into the emitted Tcl.
if CARD_ON:
    _ENG_ADDR_PART = ("foreach sp {jtag_axil/Data xdma/M_AXI_LITE} {\n"
                    "    assign_bd_address -offset 0x%08X -range 4K \\\n"
                    "        -target_address_space [get_bd_addr_spaces $sp] \\\n"
                    "        [get_bd_addr_segs {%s/s_axi/reg0}]\n"
                    "}\n" % (ENG_CTL_BASE, ENG_CELL))
else:
    # `=`, NOT `+=`.  This branch OPENS the string; the card-on branch above
    # opens its own.  MEASURED 2026-09-17: written as `+=` it raised
    # NameError: name '_ENG_ADDR_PART' is not defined for every FK33_CARD-unset
    # run -- i.e. the engine-only build that has produced every bitstream this
    # project owns could not generate at all, while the card build was fine.
    # It survived review because the byte-identity check was run only with
    # FK33_CARD=1: a control applied to the arm that was never broken.
    _ENG_ADDR_PART = ("assign_bd_address -offset 0x%08X -range 4K [get_bd_addr_segs {%s/s_axi/reg0}]\n"
                    % (ENG_CTL_BASE, ENG_CELL))
_ENG_ADDR_PART += ("assign_bd_address -offset 0x%08X -range 4K [get_bd_addr_segs {%s/s_axix/reg0}]\n"
                % (ENG_XW_BASE, ENG_CELL))
_ENG_ADDR_PART += """
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
_ENG_ADDR_PART += ("foreach pair {"
                + " ".join("{m%02d %d}" % (i, p) for i, p in enumerate(ENG_PORT_MAP))
                + "} {\n")
_ENG_ADDR_PART += """    set m  [lindex $pair 0]
    set sx [lindex $pair 1]
    for {set s 0} {$s < 32} {incr s} {
        assign_bd_address \\
            -target_address_space [get_bd_addr_spaces ENGCELL/${m}_axi] \\
            -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \\
            [get_bd_addr_segs [format "hbm/SAXI_%02d/HBM_MEM%02d" $sx $s]]
    }
}
""".replace("ENGCELL", ENG_CELL)

if ENG_ON:
    ENGINE_ADDR += _ENG_ADDR_PART
else:
    ENGINE_ADDR += ("# subsystem A omitted (FK33_ENG=0): no eng address "
                    "segments, no HBM master assignment\n")


# ---------------------------------------------------------------------------
# THE HOST SEAM ON THE BAR (TRACK SEAMMAP, 2026-08-30)
# ---------------------------------------------------------------------------
# WHAT THIS BLOCK IS AND, MORE IMPORTANTLY, WHAT IT IS NOT.
#
# `rtl/fk33_seam.vhd` is the AXI-Lite face of SUBSYSTEM D.  Subsystem D is NOT
# in this bitstream: `hw/fk33/rtl/fk33_engine.vhd` instantiates
# `matvec_int4_desc_axi` and nothing else, which is board row N3 and is
# blocked.  So what is emitted here is the seam WITH ITS SUBSYSTEM-D FACE TIED
# OFF, and the whole design of the tie-off is about making that state
# UNMISTAKABLE from the host rather than plausible.
#
# THE TIE-OFF THAT MATTERS IS `d_err`, AND IT IS TIED HIGH.
#
# MEASURED by reading rtl/fk33_seam.vhd:549-566: the completion arm runs only
# `if running = '1'`, and `running` is set by a GO and cleared ONLY by
# `d_err`, `d_tok_done` or an explicit ABORT.  Tie `d_err` and `d_tok_done`
# both LOW -- the obvious "unused input" choice -- and a GO sets `running`
# forever: STATUS bit 0 (done) never sets, bit 2 (err) never sets, and a host
# following this seam's own documented poll loop `(done | err)` HANGS.  That
# is precisely the failure mode `rtl/fk33_seam.vhd`'s "ERROR DISCIPLINE"
# section exists to forbid, and a D-less build with lazy tie-offs would ship
# it.
#
# With `d_err` tied HIGH the same GO terminates on the very next cycle with
# `st_err = 1`, `st_code = EC_DESC (6)` and `ERR_INFO[3:0] = SEAM_NO_D_CODE`.
# The host gets a refusal it can print, in-contract, one cycle after asking.
#
# THE OTHER HALF OF SAYING "NO D": CAPS_VOCAB / CAPS_EMBD / CAPS_LAYER /
# CAPS_CTX are left at their RTL defaults of 0.  A host that reads
# CAPS_VOCAB = 0 is reading "this bitstream has no model behind the seam".
# Both facts are checked below rather than assumed.
#
# WHAT IS STILL REAL, AND WHY THIS IS WORTH EMITTING AT ALL.  Everything on
# the host side of the seam works with no D: the ID and VERSION words, the
# CAPS words, CTRL/STATUS/ERR_INFO, and the indirect windows -- the 4,608-word
# descriptor RAM and the 576-entry release RAM -- can be written and read back
# over the BAR.  That is the first time any of `server/fk33_seam.h`,
# `server/pl_backend.c` or `server/fk33_sim.c` can be pointed at silicon
# instead of at a model, and it is a real decode test of the exact block that
# will later carry the real program.
#
# WHAT THIS DOES NOT ANSWER, STATED PLAINLY BECAUSE NOTHING HERE CAN: whether
# the seam RESPONDS at 0xE000 on the card.  No tool in this repository can
# answer that.  The two things that would, in order: (1) `assign_bd_address`
# accepting the offset and the segment name during a `--bd-only` run, which
# proves the address is legal, unique and inside the master's space, and (2) a
# host read of 0xE000 returning 0x4C4C4D32 on a configured card, which is
# Oren's and needs hardware.
#
# WHEN SUBSYSTEM D LANDS (N3), EVERY TIE-OFF BELOW MUST GO.  That is not left
# to memory: check_seam_tieoff() in this file refuses to emit a build whose
# engine wrapper contains a `llama_top` instantiation while these constants
# are still driving the seam.  A tie-off that outlives its reason is the
# guard-passes-for-the-wrong-reason shape this project keeps finding.
SEAM_RTL_ADD = "\n".join([
    "",
    "# ---- host seam RTL (gen_pcieep.py) ----------------------------------------",
    "add_files -norecurse %s" % SEAM_RTL,
    "update_compile_order -fileset sources_1",
    "",
])

# (cell suffix, width, value) for the constant drivers the tie-off needs.
_SEAM_CONSTS = [
    ("z1",  1,  0),
    ("h1",  1,  1),
    ("nd4", 4,  SEAM_NO_D_CODE),
    ("z11", 11, 0),
    ("z16", 16, 0),
    ("z32", 32, 0),
]

# (seam input pin, constant cell suffix).  Every input of fk33_seam that is
# not clk, rst or part of the AXI-Lite slave is here.  Written out rather than
# derived from the VHDL, so that adding a port to fk33_seam.vhd leaves an
# unconnected pin the block designer complains about instead of silently
# tying it to whatever Vivado feels like.
_SEAM_TIES = [
    ("d_busy",       "z1"),
    ("d_tok_done",   "z1"),
    ("d_err",        "h1"),      # THE ONE THAT IS NOT ZERO.  See above.
    ("d_err_code",   "nd4"),
    ("d_err_step",   "z11"),
    ("d_steps_done", "z11"),
    ("d_raddr",      "z16"),
    ("d_ren",        "z1"),
    ("hr_data",      "z16"),
    ("obs_issue",    "z1"),
    ("obs_tok_pos",  "z16"),
    ("smp_token",    "z32"),
    ("smp_n",        "z32"),
    ("smp_exp",      "z16"),
    ("f_smp_ovf",    "z1"),
    ("f_lost_beat",  "z1"),
    ("f_gate_drop",  "z1"),
    ("f_unit_stub",  "z1"),
    ("f_e_coll",     "z1"),
    ("f_kv_err",     "z1"),
]


# THE SEAM'S MODEL GEOMETRY, DERIVED AND NOT TYPED.
#
# CAPS_VOCAB / CAPS_EMBD / CAPS_LAYER / CAPS_CTX are how a host discovers what
# model is behind the seam.  Until 2026-09-17 they were left at the RTL default
# of 0 and this block ASSERTED they must stay 0, because there was no subsystem
# D -- `CAPS_VOCAB = 0` read as "this bitstream has no model".  D is in the card
# cell now, so leaving them at 0 makes the seam lie in the OTHER direction: the
# host refuses a card that is in fact ready.
#
# They are read from the SAME two files the card is built from, so a model or a
# context change cannot leave this claim behind:
#   * rtl/model_cfg_pkg.vhd's QWEN35_9B record -- vocab, hidden, blocks
#   * hw/fk33/gen_fk33_card.py's C_CTXLEN generic -- the context THIS BITSTREAM
#     implements, which is NOT the model's max_context (262,144 in the record
#     against 131,072 the card is built for).  CAPS reports what the bitstream
#     has, and the record's larger number is exactly the sort of plausible
#     figure that would never be questioned afterwards.
def _model_caps():
    import re as _re
    _rtl = os.path.normpath(os.path.join(HERE, "..", "..", "rtl"))
    cfg = open(os.path.join(_rtl, "model_cfg_pkg.vhd")).read()
    m = _re.search(r"constant\s+QWEN35_9B\s*:\s*model_cfg_t\s*:=\s*\((.*?)\);",
                   cfg, _re.S)
    if not m:
        sys.exit("ABORT: cannot find QWEN35_9B in model_cfg_pkg.vhd, so the "
                 "seam's CAPS geometry cannot be derived. Refusing to guess.")
    body = m.group(1)
    def field(name):
        f = _re.search(r"\b%s\s*=>\s*(\d+)" % name, body)
        if not f:
            sys.exit("ABORT: QWEN35_9B has no field %r; the seam's CAPS "
                     "geometry cannot be derived." % name)
        return int(f.group(1))
    card = open(os.path.join(HERE, "gen_fk33_card.py")).read()
    c = _re.search(r'"--generic",\s*"C_CTXLEN=(\d+)"', card)
    if not c:
        sys.exit("ABORT: gen_fk33_card.py does not set C_CTXLEN, so the "
                 "context this bitstream implements is unknown.")
    caps = {"CAPS_VOCAB": field("vocab"), "CAPS_EMBD": field("hidden"),
            "CAPS_LAYER": field("blocks"), "CAPS_CTX": int(c.group(1))}
    # A zero here would reproduce the "no model" reading this exists to end.
    for k, v in caps.items():
        if v <= 0:
            sys.exit("ABORT: derived %s = %d, which a host reads as 'no model "
                     "behind the seam'." % (k, v))
    return caps


MODEL_CAPS = _model_caps()


def _seam_block():
    L = []
    a = L.append
    a("")
    a("# ---- THE HOST SEAM (gen_pcieep.py) ----------------------------------------")
    a("# rtl/fk33_seam.vhd, TRACK DSEAM.  Read the long note above SEAM_BLOCK in")
    a("# gen_pcieep.py before changing anything here: the d_err tie is HIGH on")
    a("# purpose and tying it low makes a host poll loop hang.")
    a("create_bd_cell -type module -reference fk33_seam %s" % SEAM_CELL)
    a("")
    # THE HOST REGISTER ADDRESS MUST REACH THE CARD'S WIDEST REGION.
    # MEASURED 2026-09-09: the seam was instantiated with rtl/fk33_seam.vhd's
    # DEFAULTS -- REGMAX 4096, HADDR_W 12 -- while `card`'s hr_addr/hw_addr are
    # 14 bits because its widest host-visible region is 12,288 elements.  The
    # block design reported it and nothing branched on it:
    #   CRITICAL WARNING: [BD 41-2383] Width mismatch when connecting input pin
    #   '/card/hr_addr'(14) to pin '/fk33_seam_0/hr_addr'(12) - Only lower
    #   order bits will be connected ...
    # so the host could address only 4,096 of the card's 12,288 elements and
    # registers 4096..12287 were UNREACHABLE.  Same defect class as the KV
    # generics fixed in gen_fk33_card.py the same day, and the same reason it
    # survived: the build gates on `^ERROR` and this is a CRITICAL WARNING.
    #
    # clog2(12288) = 14, so HADDR_W = 14 and REGMAX = 12288 satisfy the seam's
    # OWN two-sided guard (`bad_haddr_w_small`/`bad_haddr_w_big` at
    # rtl/fk33_seam.vhd:318), which fails elaboration with an out-of-range
    # natural if the pair ever disagrees.  That guard is the reason this can be
    # set here rather than having to be re-derived: a wrong pair cannot build.
    #
    # REGMAX SIZES NO STORAGE.  It appears only in range constraints
    # (`xw_addr`/`xr_addr`) and bounds tests, so 4096 -> 12288 costs two bits of
    # address width and nothing else.  Checked before changing it, because the
    # obvious fear is that it sizes a register file.
    a("set_property -dict [list CONFIG.REGMAX {12288} CONFIG.HADDR_W {14}] "
      "[get_bd_cells %s]" % SEAM_CELL)
    # A CONFIG.* READ-BACK IS A REQUEST, NOT AN ANSWER (recorded trap), so the
    # real verification is that the [BD 41-2383] width mismatch for hr_addr and
    # hw_addr DISAPPEARS from the build log.  This line is a breadcrumb only.
    a("puts \"FK33_SEAM REGMAX=[get_property CONFIG.REGMAX [get_bd_cells %s]] "
      "HADDR_W=[get_property CONFIG.HADDR_W [get_bd_cells %s]]\""
      % (SEAM_CELL, SEAM_CELL))
    a("")
    a("# THE CLOCK.  The seam rides the engine's CORE clock, not xdma/axi_aclk,")
    a("# and it does so through the smartconnect ENGINE_BLOCK already built.  Two")
    a("# reasons, in order: subsystem D will be in the core domain, so putting the")
    a("# seam anywhere else now buys a move later; and axil2eng is already")
    a("# NUM_CLKS 2 with the incoming side on xdma/axi_aclk and the outgoing side")
    a("# on clk_wiz_0/clk_out3, so this is one more MI on an interconnect that")
    a("# exists rather than a new one.")
    if ENG_ON:
        a("set n [get_property CONFIG.NUM_MI [get_bd_cells axil2eng]]")
    else:
        a("# FK33_ENG=0: axil2eng was created with NUM_MI 1 and no master")
        a("# connected, so the seam takes M00 rather than appending after the")
        a("# engine's two.  Reading NUM_MI here would give 1 and put the seam on")
        a("# M01, leaving M00 dangling -- and a smartconnect MI that is created")
        a("# and never connected is not pruned, it reaches HDL generation.")
        a("set n 0")
    a("set_property CONFIG.NUM_MI [expr {$n + 1}] [get_bd_cells axil2eng]")
    a("connect_bd_intf_net [get_bd_intf_pins axil2eng/[format M%02d_AXI $n]] \\")
    a("                    [get_bd_intf_pins %s/s_axi]" % SEAM_CELL)
    a("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins %s/clk]" % SEAM_CELL)
    a("")
    a("# THE RESET IS ACTIVE HIGH.  fk33_seam's `rst` is `if rst = '1'`, so it")
    a("# takes proc_sys_reset's peripheral_reset and NOT peripheral_aresetn.")
    a("# Wiring the active-low net here would leave the block permanently in")
    a("# reset after the MMCM locks, which reads from the host as a seam that")
    a("# answers 0 to everything -- indistinguishable from an unmapped BAR.")
    a("connect_bd_net [get_bd_pins core_reset/peripheral_reset] [get_bd_pins %s/rst]"
      % SEAM_CELL)
    a("")
    a("# ---- the subsystem-D tie-off ----------------------------------------------")
    for suf, width, val in _SEAM_CONSTS:
        a("create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 seam_%s" % suf)
        a("set_property -dict [list CONFIG.CONST_WIDTH {%d} CONFIG.CONST_VAL {%d}] "
          "[get_bd_cells seam_%s]" % (width, val, suf))
    # WITH THE CARD ON, THE TIE-OFF IS NOT EMITTED AT ALL, rather than emitted
    # and deleted again by CARD_BLOCK.  Deleting it at Tcl run time would leave
    # the tie-off's TEXT in the generated script, and check_seam_tieoff reads
    # that text -- so the guard would see a tie-off that no longer exists and,
    # worse, would keep passing if the delete ever silently matched nothing.
    # Not emitting it makes the guard's reading true by construction.
    _tied_by_card = {p for p, _ in SEAM_FROM_CARD} if CARD_ON else set()
    for pin, suf in _SEAM_TIES:
        if pin in _tied_by_card:
            a("# %s is driven by %s/%s (FK33_CARD): no tie-off." 
              % (pin, CARD_CELL, dict(SEAM_FROM_CARD)[pin]))
            continue
        a("connect_bd_net [get_bd_pins seam_%s/dout] [get_bd_pins %s/%s]"
          % (suf, SEAM_CELL, pin))
    a("")
    # THE MODEL GEOMETRY THE SEAM PUBLISHES.  With the card in the design the
    # host must be able to discover the model; with no card there is nothing
    # behind the seam and 0 is the honest report.  Both arms are checked below
    # against the SAME expectation this emits, so a generic renamed in
    # rtl/fk33_seam.vhd fails the build rather than silently publishing zeros.
    if CARD_ON:
        for _g, _v in sorted(MODEL_CAPS.items()):
            a("set_property CONFIG.%s {%d} [get_bd_cells %s]"
              % (_g, _v, SEAM_CELL))
    a("# READ BACK, DO NOT ASSUME.  Vivado silently ignores set_property on a")
    a("# CONFIG name an object does not have and get_property then returns the")
    a("# empty string, so a generic RENAMED in rtl/fk33_seam.vhd would leave this")
    a("# build claiming a model geometry it does not have -- or, since 2026-09-17,")
    a("# publishing 0 for a model that IS behind the seam, which a host reads as")
    a("# 'no model' and refuses.")
    a("foreach {g want} {%s} {"
      % " ".join("%s %d" % (k, MODEL_CAPS[k] if CARD_ON else 0)
                 for k in ("CAPS_VOCAB", "CAPS_EMBD", "CAPS_LAYER", "CAPS_CTX")))
    a("    set v [get_property CONFIG.$g [get_bd_cells %s]]" % SEAM_CELL)
    a("    if {$v ne $want} {")
    a("        error \"FK33_SEAM FAIL: $g is \\\"$v\\\", not $want. %s\""
      % ("Subsystem D is in this bitstream, so the seam must publish the model "
         "geometry the card was built for." if CARD_ON else
         "There is no subsystem D in this bitstream, so the seam must not "
         "publish a model geometry."))
    a("    }")
    a("    puts \"FK33_SEAM $g = $v\"")
    a("}")
    a("# ---- end host seam --------------------------------------------------------")
    a("")
    return "\n".join(L)


SEAM_BLOCK = _seam_block()

# The segment name is `s_axi/reg0`, not `s_axi/Reg`.  A module-reference cell
# whose AXI4-Lite slave Vivado INFERS from the port names gets `reg0`; the
# axi_gpio and axi_bram_ctrl IP above get `Reg`.  MEASURED from the emitted
# script: the engine, which is the only other module-reference slave in this
# design, is mapped as `eng/s_axi/reg0`.  If this is wrong the build stops at
# `assign_bd_address` in the BD stage, loudly, which is what --bd-only is for.
SEAM_ADDR = """
# ---- host seam address map (gen_pcieep.py) ---------------------------------
# 0xE000, 4 KB, on the PCIe AXI-Lite BAR.  This is board row N2's missing
# line: server/fk33_seam.h has declared this base since TRACK SERVER and
# nothing decoded it.  See the SEAM_BASE block in gen_pcieep.py for why 0xE000
# and not another hole, and check_bar_map() for what stops it colliding.
"""
SEAM_ADDR += ("assign_bd_address -offset 0x%08X -range %dK "
              "[get_bd_addr_segs {%s/s_axi/reg0}]\n"
              % (SEAM_BASE, SEAM_SPAN // 1024, SEAM_CELL))


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
    foreach c {fk33_id fk33_scratch fk33_dmabram core_reset axil2eng} {
        if {![llength [get_bd_cells -quiet $c]]} { puts "FK33_CFG MISSING CELL $c" }
    }
    # SUBSYSTEM A.  Three ways this build can come out looking healthy and be
    # wrong, each read back from the tool rather than assumed:
    #   * a SAXI port that should be enabled is not, so a master is dangling
    #   * an enabled port's ACLK or ARESET_N is undriven (41-758 catches that at
    #     HDL generation, but only if it is still undriven THEN)
    #   * an engine master interface never got connected to an HBM port
    # READ FROM THE DESIGN, not from a generator flag.  Whether the card is in
    # this build is a fact about the block design, and asking the tool means
    # this check cannot disagree with what was actually built.
    set ::fk33_card_on [expr {[llength [get_bd_cells -quiet card]] > 0}]
    # AND WHETHER SUBSYSTEM A IS IN IT, read the same way and for the same
    # reason: FK33_ENG=0 omits the engine deliberately, and every expectation
    # below has to follow the configuration rather than assert the shipping
    # one.  An enabled SAXI port with no master is not a harmless leftover --
    # its ACLK and ARESET_N reach HDL generation undriven and fail with
    # 41-758 -- so with no engine the 28 ports must be OFF, which is a real
    # check and not a skip.
    set ::fk33_eng_on [expr {[llength [get_bd_cells -quiet eng]] > 0}]
    puts "FK33_ENG present=$::fk33_eng_on card=$::fk33_card_on"
    set engbad 0
    foreach i {01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 \
               17 18 19 20 21 22 23 24 25 26 27 28 29} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        set _want [expr {$::fk33_eng_on ? "true" : "false"}]
        if {[string tolower $v] ne $_want} {
            puts "FK33_ENG SAXI_$i = $v, must be $_want"
            incr engbad
        }
        if {$::fk33_eng_on} {
            foreach pin [list hbm/AXI_${i}_ACLK hbm/AXI_${i}_ARESET_N] {
                if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin]]]} {
                    puts "FK33_ENG $pin IS UNDRIVEN"
                    incr engbad
                }
            }
        }
    }
    foreach i {30 31} {
        set v [get_property CONFIG.USER_SAXI_$i [get_bd_cells hbm]]
        # THE EXPECTATION FOLLOWS THE CONFIGURATION.  Without the card these two
        # are spare and MUST stay off, or a later edit could quietly consume the
        # only ports B and C will ever have.  With the card they are the grant's
        # pool and must be ON.  Hardcoding `false` made this check report
        # bad=2 on a correct card build -- and the build passed anyway, which
        # is the more serious half: see the abort added below.
        set _want [expr {$::fk33_card_on ? "true" : "false"}]
        puts "FK33_ENG SAXI_$i = $v (must be $_want)"
        if {[string tolower $v] ne $_want} { incr engbad }
    }
    if {$::fk33_eng_on} {
        for {set m 0} {$m < 28} {incr m} {
            set ip [get_bd_intf_pins -quiet [format "eng/m%02d_axi" $m]]
            if {![llength $ip]} { puts "FK33_ENG eng/m${m}_axi MISSING"; incr engbad; continue }
            if {![llength [get_bd_intf_nets -quiet -of_objects $ip]]} {
                puts [format "FK33_ENG eng/m%02d_axi IS NOT CONNECTED" $m]
                incr engbad
            }
        }
    }
    puts "FK33_ENG portcheck bad=$engbad (must be 0)"
    # AND IT MUST ACTUALLY STOP THE BUILD.  Until 2026-09-07 this counter was
    # printed and never acted on, so `bad=2` sailed through a --bd-only run
    # that reported success.  A check whose result nothing branches on is
    # decoration: every fault it counts -- a dangling master, an undriven
    # ACLK, an unconnected m..._axi, an undriven compute_halt -- was being
    # reported into a log nobody reads and then ignored.
    if {$engbad != 0} {
        error "FK33_ENG FAIL: portcheck bad=$engbad. See the FK33_ENG lines above for which."
    }
    if {$::fk33_eng_on} {
        puts "FK33_ENG masters=28 halt=[llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]"
        if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins eng/compute_halt]]]} {
            puts "FK33_ENG compute_halt IS UNDRIVEN -- the thermal guard cannot stop the array"
            incr engbad
        }
    } else {
        # THE THERMAL GUARD HAS NOTHING TO STOP, and that is the honest state to
        # report rather than a silent pass: with no engine there is no HBM read
        # traffic and no DSP array, so compute_halt has no consumer.  B and C in
        # the card are NOT halt-gated -- that path does not exist -- which is one
        # more thing a bitstream built this way does not prove.
        puts "FK33_ENG absent: no masters, no compute_halt consumer, no thermal throttle path"
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
] if ENG_ON else [
    "",
    "###############################################################################",
    "# SUBSYSTEM A ABSENT (FK33_ENG=0): NO CLOCK-GROUP LINE (gen_pcieep.py)",
    "###############################################################################",
    "# The line this block normally carries addresses bd_i/eng/core_clk and",
    "# bd_i/eng/hbm_aclk.  With no engine `get_pins` matches nothing and",
    "# `get_clocks -of_objects` on an empty object is an ERROR, not the warning",
    "# an empty set_clock_groups would be -- and the XDC is read during",
    "# implementation, so it would abort the build after place_design rather",
    "# than at the start.  There is also nothing left to declare asynchronous:",
    "# the 28 gray-pointer FIFOs it covers live inside the engine.",
    "#",
    "# The card runs wholly on clk_out3, so this configuration has no",
    "# core-to-hbm_aclk crossing of its own.",
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

# NOTHING ABOVE THIS POINT EXISTS UNDER FK33_ENG=0.  Everything from the top of
# this section down to the `set wns` line below reads bd_i/eng off the
# implemented design, so under FK33_ENG=0 it is replaced (see _IMPL_TAIL_AT,
# just after this string) by a line saying the engine is absent.  The tail from
# `set wns` on is configuration-independent and is kept in both.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "FK33_TIMING WNS=%.3f ns  WHS=%.3f ns" $wns $whs]
# -no_detailed_paths: the per-clock table is what the duty identity needs and
# the detailed paths are what make this report expensive.
report_timing_summary -no_detailed_paths -file fk33_pcieep_timing.rpt
report_clock_interaction -file fk33_pcieep_clkint.rpt
report_design_analysis -congestion -file fk33_pcieep_congestion.rpt
report_clock_utilization -file fk33_pcieep_clkutil.rpt

# ---- THE FLOORPLAN, verified on the implemented design (gen_pcieep.py) -----
# Two things have to be true and neither is visible from the source files.
#
#   1. `pb_core` EXISTS with the range fk33_pblock.xdc asked for.  Vivado's XDC
#      reader downgrades a lot to a warning, and a pblock that was silently
#      skipped looks exactly like a pblock that did not help.  GRID_RANGES is
#      read back from the design, not from the file.
#
#   2. `pblock_bd_i` is GONE.  It is the SQRL shell floorplan the probe XDC
#      inherits, it is IS_SOFT, and with the engine present it is
#      oversubscribed by half on LUTs and by 3x on DSPs.  Leaving it in is what
#      made the first engine build unroutable.  gen_pcieep.py comments it out
#      of the emitted XDC; this is the check that the comment-out worked.
set pbs [lsort [get_property NAME [get_pblocks -quiet *]]]
puts "FK33_PBLK pblocks in the implemented design: $pbs"
if {[lsearch $pbs pblock_bd_i] >= 0} {
    error "FK33_PBLK FAIL: pblock_bd_i is in the implemented design. It is a soft pblock covering SLICE_X0Y0:X218Y50 plus the right-hand columns, it cannot hold the engine, and it is what caused the global congestion level 7 that stopped the router. See docs/debugging/2026-08-29_shell-pblock.md."
}
if {[llength [get_pblocks -quiet pb_core]] != 1} {
    error "FK33_PBLK FAIL: pb_core is not in the implemented design. The engine would be free to pack into clock-region column X7, which Tandem PCIe reserves, and the floorplan this build was measured with is not in effect."
}
set pbr [get_property GRID_RANGES [get_pblocks pb_core]]
if {$pbr ne "CLOCKREGION_X0Y0:CLOCKREGION_X6Y3"} {
    error "FK33_PBLK FAIL: pb_core range is '$pbr', not CLOCKREGION_X0Y0:CLOCKREGION_X6Y3."
}
puts "FK33_PBLK pb_core $pbr"
report_utilization -pblocks [get_pblocks pb_core] -file fk33_pcieep_pblock_util.rpt
puts "FK33_PBLK pblock utilization -> fk33_pcieep_pblock_util.rpt\""""

# FK33_ENG=0: KEEP THE TAIL, DROP THE ENGINE.  Everything from the top of
# IMPL_ENG_NEW down to the `set wns` line reads bd_i/eng off the implemented
# design -- the two clocks, the clock-group check, the engine-only utilization
# report -- and every one of those checks would FAIL on a design that is
# correct for this configuration.  The tail (WNS/WHS, the timing summary, the
# congestion and clock reports, the floorplan checks, the bitstream line) is
# configuration-independent and is exactly what a reduced-scope build is being
# run to obtain, so it is kept verbatim rather than re-written.
_IMPL_TAIL_AT = "set wns [get_property SLACK [get_timing_paths -delay_type max"
assert IMPL_ENG_NEW.count(_IMPL_TAIL_AT) == 1, (
    "IMPL_ENG_NEW's tail marker moved; the FK33_ENG=0 form would silently "
    "keep or drop the wrong half")
if not ENG_ON:
    IMPL_ENG_NEW = (
        "# ---- SUBSYSTEM A OMITTED (FK33_ENG=0) -------------------------------------\n"
        "# There is no bd_i/eng in this design, so the engine's two clocks, the\n"
        "# set_clock_groups check that rides on them and the engine-only area report\n"
        "# have nothing to read.  The timing and floorplan checks below are kept:\n"
        "# they are what this configuration exists to produce.\n"
        "puts \"==== FK33 subsystem A (implemented design) ====\"\n"
        "if {[llength [get_cells -quiet bd_i/eng]] != 0} {\n"
        "    error \"FK33_ENGI FAIL: bd_i/eng IS in the implemented design, but this\n"
        "build was generated with FK33_ENG=0. The script and the design disagree.\"\n"
        "}\n"
        "puts \"FK33_ENGI absent by request (FK33_ENG=0): no subsystem A, no HBM read\n"
        "masters, and every A job issued by subsystem D hangs.\"\n"
        "\n"
        + IMPL_ENG_NEW[IMPL_ENG_NEW.index(_IMPL_TAIL_AT):])

SAXI0_OLD = ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} "
             + " ".join("CONFIG.USER_SAXI_%02d {false}" % i for i in range(1, 16))
             + "] [get_bd_cells hbm]")
SAXI1_OLD = ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} "
             + " ".join("CONFIG.USER_SAXI_%02d {false}" % i for i in range(17, 32))
             + "] [get_bd_cells hbm]")

# ---------------------------------------------------------------------------
# BUILD-HANG.  A shell build sat blocked on `wait_on_run synth_1` for 27.6
# hours with SEVEN MINUTES of CPU across the whole period.  It was not slow,
# it was stopped: `launch_runs` printed `Time (s): cpu = 00:00:17` and REPORTED
# SUCCESS, but synth_1 never started -- no runme.log, no .vivado.begin.rst, and
# no synth_1 directory in fk33_pcieep.runs/ at all, only the bd_* sub-runs.
# `wait_on_run` then waited forever for a run that did not exist, and the
# symptom is indistinguishable from a legitimately long place-and-route, which
# is why it survived a day and a half.
#
# Two independent defects, so two independent fixes:
#
#   1. The wait was UNBOUNDED.  MEASURED 2026-08-29 against Vivado 2023.2:
#      `wait_on_run -timeout <minutes>` is accepted (an unknown option is
#      rejected with Common 17-170, and -timeout is not), the default is -1
#      meaning no limit, and -- this is the load-bearing part -- ON EXPIRY IT
#      RETURNS NORMALLY, rc 0 with an empty message.  It does NOT raise.  So
#      `-timeout` alone bounds nothing; it only bounds the build if an explicit
#      PROGRESS check follows it.  That is fk33_assert_run_done.
#
#   2. Nothing checked that the run existed.  MEASURED 2026-08-29 on a
#      throwaway xcvu33p project: `get_runs synth_1` succeeds and
#      `get_property DIRECTORY` returns a full path BEFORE the run has ever
#      been launched, with STATUS "Not started" and the directory ABSENT
#      (isdir=0).  So `file isdirectory` on that path is an exact
#      discriminator for the hang condition.
#
# WHICH MARKER TO TEST FOR MATTERS, and getting it wrong would break every
# healthy build.  MEASURED on a real (trivial) synthesis run: immediately after
# `launch_runs` returns, the directory already exists and holds runme.sh,
# runme.bat, rundef.js and .Vivado_Synthesis.queue.rst, with STATUS
# "Queued...".  runme.log, .vivado.begin.rst and .vivado.end.rst appear only
# LATER.  So runme.sh is written synchronously and is safe to require here;
# requiring runme.log would false-fire on every correct launch.  That is why
# this guard needs no polling and cannot race.
RUN_GUARD_TCL = '''
# ---------------------------------------------------------------- run guards
# GENERATED by gen_pcieep.py.  See the BUILD-HANG comment there, and
# docs/debugging/2026-08-29_noguard-three-guards.md, for the measurements each
# line rests on.  Teeth-checked by `python3 hw/fk33/gen_pcieep.py --selftest`,
# which drives these two procs under tclsh with get_runs/get_property stubbed,
# so the guard is exercised without a synthesis.
proc fk33_assert_run_started {run} {
    set r    [get_runs $run]
    set dir  [get_property DIRECTORY $r]
    set st   [get_property STATUS $r]
    if {![file isdirectory $dir]} {
        error "FK33_RUNSTART FAIL: launch_runs reported success but run '$run' has NO run directory at all ($dir), STATUS '$st'. The run never started. This is the 2026-08-29 BUILD-HANG: an unbounded wait_on_run then blocks forever on a run that does not exist -- 27.6 hours, 7 minutes of CPU. Do not wait; read the launch_runs output above this line."
    }
    if {![file exists [file join $dir runme.sh]]} {
        error "FK33_RUNSTART FAIL: run '$run' has a directory ($dir) but no runme.sh in it, STATUS '$st', so no run script was ever written. MEASURED 2026-08-29: launch_runs writes runme.sh synchronously before it returns, so this is a real failure and not a race."
    }
    puts "FK33_RUNSTART $run dir=$dir status=$st"
}
proc fk33_bound {name v} {
    # MEASURED 2026-08-29 while teeth-checking this guard: setting the limit
    # to -1 restores the ORIGINAL unbounded wait -- Vivado documents -1 as
    # "no limit" -- while satisfying every textual check on this script,
    # including the one that refuses a bare `wait_on_run`.  A bound is only a
    # bound if the number is positive, and the environment can supply it.
    if {![string is integer -strict $v] || $v <= 0} {
        error "FK33_RUNBOUND FAIL: $name is '$v'. wait_on_run -timeout treats -1 (and any non-positive value) as NO LIMIT, which is the unbounded wait that blocked a build for 27.6 hours. Give a positive number of minutes."
    }
    return $v
}
proc fk33_assert_run_done {run limit_min} {
    set r    [get_runs $run]
    set dir  [get_property DIRECTORY $r]
    set prog [get_property PROGRESS $r]
    set st   [get_property STATUS $r]
    if {$prog eq "100%"} {
        puts "FK33_RUNDONE $run $prog status=$st"
        return
    }
    error "FK33_RUNDONE FAIL: run '$run' is at $prog with STATUS '$st'. Either it failed -- read $dir/runme.log -- or it exceeded the ${limit_min}-minute bound passed to wait_on_run -timeout. MEASURED 2026-08-29: wait_on_run -timeout RETURNS rc 0 with an empty message when it expires, so this check is the only thing that turns the bound into a stop."
}
'''

# The bounds themselves.  Deliberately generous: the point is to convert an
# infinite hang into a build that ends and says why, not to police a slow
# machine.  Overridable from the environment so nobody has to edit a generated
# file when a box is loaded.
SYNTH_MAX_MIN = 360
IMPL_MAX_MIN = 720

LAUNCH_OLD = '''launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "SYNTH FAILED -- see the run log"
}
puts "==== synthesis done ===="

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "IMPL FAILED -- see the run log"
}'''

# ---- MEMORY.  `-jobs N` on SYNTHESIS launches up to N concurrent
# out-of-context IP runs, EACH ITS OWN VIVADO PROCESS, on a 31 GB box that has
# OOM-killed unrelated services before (the 2026-07-04 systemd-oomd incident
# took down the whole code-server cgroup).  The engine adds a ~135 kLUT module
# to the main run, so this build is materially heavier than every pcieep build
# before it.  Implementation is left at 8: its -jobs is threads inside ONE
# process and does not multiply the footprint.
#
# The value used to be hardcoded, and the comment above it went on saying 8
# after the code had been changed to 4 -- a stale number in the one comment
# whose whole job is to say how much memory this costs.  It is a variable now
# so the two cannot drift again.
#
# MEASURED 2026-09-08, and this is why the default drops with the card on:
# `FK33_CARD=1` with 4 jobs was killed by **systemd-oomd** 2.5 minutes after
# `launch_runs` -- "cardbuild.service: systemd-oomd killed 134 process(es) in
# this unit" -- even though the unit ran under `MemoryHigh=18G` and the cgroup
# never reported a single `memory.events high`.  **`MemoryHigh` throttles; it
# does not stop systemd-oomd**, which fires on memory PRESSURE (PSI) across the
# cgroup, not on the limit.  That is the same distinction CLAUDE.md already
# records for `OOMPolicy=continue`, in a new place.  Four workers all
# allocating hard at once is a pressure spike whatever the ceiling says.
#
# TWO FURTHER MEASUREMENTS THE SAME NIGHT, both correcting the obvious fixes:
#
# (a) **`-jobs N` BOUNDS CONCURRENT RUNS, NOT PROCESSES.** Relaunched at
#     `-jobs 2` and counted **ELEVEN** Vivado processes totalling 22.04 GB,
#     with `MemAvailable` down to 3.8 GB. Each run forks its own parallel
#     synthesis workers, which this file already records elsewhere ("a single
#     Vivado shows five matches ... because Vivado forks parallel-synthesis
#     workers that inherit the parent's argv"). So the process count is roughly
#     `jobs x 5 + 1`, and halving `-jobs` does NOT halve the footprint.
#
# (b) **DO NOT USE `ManagedOOMPreference=avoid` HERE. It is the wrong remedy
#     and it is worse than none.** It was added on the theory that the first
#     kill was oomd's fault. It does not reduce anything: it tells systemd-oomd
#     to spare THIS cgroup, so when the box goes under pressure oomd kills a
#     BYSTANDER instead -- and the bystander on this machine is `code-server`,
#     which is exactly what the 2026-07-04 incident destroyed (275 processes,
#     every claude session in that cgroup). The run was stopped by hand before
#     it fired. **oomd killing the offending build is the SAFETY VALVE, not the
#     bug.** If a hard ceiling is wanted, use `MemoryMax`, which makes the
#     kernel kill THIS cgroup and nothing else.
#
# So the standing recipe for a card build is `-jobs 1`, no oomd exemption, and
# `MemoryMax` if a hard stop is wanted. Even that is unproven: no card build has
# completed.
# Concurrent OOC synthesis runs.  FOUR is what the engine-only build has used;
# with the card in the design that was OOM-killed by systemd-oomd (see above),
# so the default halves when FK33_CARD is on.  Override with FK33_SYNTH_JOBS.
SYNTH_JOBS = int(os.environ.get("FK33_SYNTH_JOBS", "1" if CARD_ON else "4"))
# Workers WITHIN a synthesis run.  Vivado defaults to 8 on this box, which is
# ~8 x 2.4 GB plus a parent and does not fit beside the card. 2 is the value
# that leaves headroom; FK33_SYNTH_THREADS overrides. Left at Vivado's default
# for the engine-only build, which has completed at that setting.
SYNTH_THREADS = int(os.environ.get("FK33_SYNTH_THREADS", "2" if CARD_ON else "8"))

# Empty string means "leave Vivado's default alone", which is what the
# card-free build has always used and which is known to work there (10.66 GB,
# 0 errors, a bitstream).  Only the card build changes strategy, so a
# regression here cannot be blamed on this lever.
SYNTH_FLATTEN = os.environ.get("FK33_FLATTEN", "none" if CARD_ON else "")
assert SYNTH_FLATTEN in ("", "none", "rebuilt", "full"), \
    "FK33_FLATTEN must be one of '', none, rebuilt, full -- got %r" % SYNTH_FLATTEN
if SYNTH_THREADS < 1:
    sys.exit("ABORT: FK33_SYNTH_THREADS must be >= 1, got %d" % SYNTH_THREADS)
if SYNTH_JOBS < 1:
    sys.exit("ABORT: FK33_SYNTH_JOBS must be >= 1, got %d" % SYNTH_JOBS)

LAUNCH_NEW = RUN_GUARD_TCL + '''
set FK33_SYNTH_MAX_MIN [fk33_bound FK33_SYNTH_MAX_MIN %(smin)d]
set FK33_IMPL_MAX_MIN  [fk33_bound FK33_IMPL_MAX_MIN  %(imin)d]
if {[info exists ::env(FK33_SYNTH_MAX_MIN)]} { set FK33_SYNTH_MAX_MIN [fk33_bound FK33_SYNTH_MAX_MIN $::env(FK33_SYNTH_MAX_MIN)] }
if {[info exists ::env(FK33_IMPL_MAX_MIN)]}  { set FK33_IMPL_MAX_MIN  [fk33_bound FK33_IMPL_MAX_MIN  $::env(FK33_IMPL_MAX_MIN)] }
puts "FK33_RUNBOUND synth=$FK33_SYNTH_MAX_MIN min impl=$FK33_IMPL_MAX_MIN min"

# THE PROCESS COUNT IS `general.maxThreads`, NOT `-jobs`.  CORRECTION to the
# reasoning above, MEASURED 2026-09-08 after `synth_checkpoint_mode None` was
# in place: the run directory listing showed exactly ONE run (`synth_1`), so
# global mode HAD removed every per-IP out-of-context run -- and there were
# still TEN Vivado processes at 21.16 GB.
#
# They are not runs. They are the parallel synthesis workers Vivado forks
# INSIDE one run, which this file already records ("four at 2.36 GB each plus
# a 1.41 GB parent") and which `-jobs` has never governed. `-jobs` bounds
# concurrent RUNS; `general.maxThreads` bounds the workers within a run. Every
# earlier attempt turned the wrong knob, including the one that concluded
# `-jobs` "does not bound this build at all" -- it does bound runs, there was
# simply only ever one run to bound once global mode was on.
set_param general.maxThreads %(mthr)d
puts "FK33_CARD general.maxThreads = [get_param general.maxThreads]"

# FLATTEN_HIERARCHY.  Vivado's default is `rebuilt`: flatten the WHOLE design,
# optimise across every boundary, then rebuild the hierarchy for reporting.
# On this design that default is the documented failure, twice over --
# docs/debugging/2026-09-08_card-ooc-synthesis-does-not-finish.md records two
# flat synthesis attempts of the card, ~10 hours of Vivado between them, and
# NEITHER FINISHED.  The second emitted no phase marker in 6 h 34 m while
# sitting at a comfortable 15.52 GB, so the binding constraint there was TIME,
# not memory.  cardbuild9 then hit 24.00 GB on the same flat strategy applied
# to the whole top and was still growing at 144 minutes.
#
# `none` keeps the module boundaries, so the optimiser never builds the single
# enormous flat netlist that both of those runs were grinding on.  It is the
# ONE lever that addresses both failures at once, and grep says it had never
# been set anywhere in this flow -- every previous attempt turned a
# parallelism or memory-cap knob and left the strategy alone.
#
# THE TRADE IS REAL AND IS DELIBERATELY ACCEPTED: forbidding cross-boundary
# optimisation costs QoR, so expect worse timing than the -0.422 the composed
# top reached.  Standing instruction from Oren is that a bitstream comes
# first and 200 MHz is an optimisation for afterwards, which is exactly this
# trade.  Set FK33_FLATTEN=rebuilt to get the old strategy back.
set fk33_flat "%(flat)s"
if {$fk33_flat ne ""} {
  set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY $fk33_flat [get_runs synth_1]
  puts "FK33_CARD FLATTEN_HIERARCHY = [get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY [get_runs synth_1]]"
}
launch_runs synth_1 -jobs %(sjobs)d
fk33_assert_run_started synth_1
wait_on_run -timeout $FK33_SYNTH_MAX_MIN synth_1
fk33_assert_run_done synth_1 $FK33_SYNTH_MAX_MIN
puts "==== synthesis done ===="

launch_runs impl_1 -to_step write_bitstream -jobs 8
fk33_assert_run_started impl_1
wait_on_run -timeout $FK33_IMPL_MAX_MIN impl_1
fk33_assert_run_done impl_1 $FK33_IMPL_MAX_MIN''' % {"smin": SYNTH_MAX_MIN,
                                                     "imin": IMPL_MAX_MIN,
                                                     "sjobs": SYNTH_JOBS,
                                                     "mthr": SYNTH_THREADS,
                                                     "flat": SYNTH_FLATTEN}

SUBS = ([] if not CARD_ON else [
    # ---- GLOBAL SYNTHESIS FOR THE CARD BUILD.
    # MEASURED 2026-09-08: with the card in the design, the per-IP
    # out-of-context runs a block design generates cannot be bounded.
    # `launch_runs synth_1 -jobs 4` was OOM-killed by systemd-oomd in 2.5
    # minutes; `-jobs 2` gave ELEVEN Vivado processes at 22.04 GB; `-jobs 1`
    # gave TEN at 23.91 GB with 2.5 GB of the box left. `-jobs` does not bound
    # this build at all -- see
    # docs/debugging/2026-09-08_the-card-build-and-two-wrong-fixes.md.
    #
    # `synth_checkpoint_mode None` makes the block design synthesise INSIDE the
    # top run instead of spawning a run per IP. That is ONE process, whose
    # footprint a cgroup can actually cap, against ten that it cannot. The
    # trade is losing per-IP incremental rebuild, which is worth nothing on a
    # build that has never completed once.
    #
    # It may still not fit: the card cell ALONE peaked at 15.52 GB as a
    # monolithic OOC. But a single capped process that dies is a RESULT, and
    # ten uncapped ones that take the machine are not.
    ("make_wrapper -files [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd] -top",
     "set_property synth_checkpoint_mode None "
     "[get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd]\n"
     "puts \"FK33_CARD synth_checkpoint_mode = [get_property synth_checkpoint_mode "
     "[get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd]]\"\n"
     "make_wrapper -files [get_files ./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/bd.bd] -top"),
]) + [
    # ---- 7. separate project + artifacts
    ("set ProjectName fk33_i2cprobe",
     "set ProjectName fk33_pcieep"),

    # ---- 9a. the aux RTL, before anything that references it
    ('create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"',
     'create_project $ProjectName ./$ProjectName -part "xcvu33p-fsvh2104-2L-e"\n'
     + AUX_RTL_ADD + ENG_RTL_ADD + SEAM_RTL_ADD + CARD_RTL_ADD),

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
     BRINGUP_BLOCK + AUX_BLOCK + THERM_BLOCK + ENGINE_BLOCK + SEAM_BLOCK
     + CARD_BLOCK
     + "regenerate_bd_layout\nsave_bd_design"),

    ("assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]",
     "assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_gpio_0/S_AXI/Reg}]\n"
     + BRINGUP_ADDR + AUX_ADDR + THERM_ADDR + ENGINE_ADDR + SEAM_ADDR),

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
    # WITH FK33_ENG=0 THESE TWO ARE IDENTITIES, deliberately.  The ports stay
    # DISABLED, because the reason to enable them is the engine's 28 masters and
    # an enabled port whose ACLK/ARESET_N dangle fails HDL generation with
    # 41-758 -- which is exactly what the generator's own port check reported
    # when the engine was first gated out and these substitutions still ran.
    # SAXI_30/31 are re-enabled later by the card block for B and C.
    (SAXI0_OLD,
     ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK}] [get_bd_cells hbm]"
      if ENG_ON else SAXI0_OLD)),
    (SAXI1_OLD,
     ("    set_property -dict [list CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK} "
      "CONFIG.USER_SAXI_30 {false} CONFIG.USER_SAXI_31 {false}] [get_bd_cells hbm]"
      if ENG_ON else SAXI1_OLD)),

    (IMPL_ENG_OLD, IMPL_ENG_NEW),

    # ---- MEMORY and BUILD-HANG.  One substitution, because it is one block:
    # -jobs 4 for memory, and the run guards for the 27.6-hour hang.  Both
    # rationales are with the definitions of LAUNCH_OLD/LAUNCH_NEW above.
    (LAUNCH_OLD, LAUNCH_NEW),

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

    # ---- THE FLOORPLAN.  An implementation-only constraints file, added next
    # to the strategy because it is part of the same decision.
    #
    # `used_in_synthesis false` is doing real work: MEASURED 2026-08-29, the
    # DEFAULT for an added constraints file is used_in_synthesis = 1, so
    # without this line the pblock file WOULD be read during synthesis.
    #
    # CORRECTION, MEASURED the same day (TRACK BUILD-E2E,
    # docs/debugging/2026-08-29_build-e2e-project-run.md).  This comment used
    # to say the file "would error out synthesis" because
    # `bd_i/eng/inst/eng/dut/core` exists only in the LINKED design and
    # `add_cells_to_pblock errors on an empty object`.  THAT IS NOT WHAT
    # VIVADO DOES.  Run as the control -- the same XDC, used_in_synthesis left
    # at its default, on a trivial top -- synthesis COMPLETED
    # (`PROGRESS=100% STATUS=synth_design Complete!`) and the only consequence
    # was one line:
    #
    #   WARNING: [Vivado 12-180] No cells matched 'bd_i/eng/inst/eng/dut/core'.
    #   [hw/fk33/fk33_pblock.xdc:73]
    #
    # So the property is still right and still wanted -- an unmatched
    # constraint that leaves an EMPTY pb_core behind is exactly the silent
    # class this build's other checks exist to catch, and a warning in a
    # Vivado log is a warning nobody reads -- but it buys a clean log, not a
    # rescued build.  Do not describe it as the thing standing between this
    # design and a synthesis failure.
    #
    # The placer directive is NOT changed.  `Performance_RefinePlacement` gives
    # place_design -directive ExtraPostPlacementOpt, and that is the directive
    # every measurement in docs/debugging/2026-08-29_shell-pblock.md that
    # produced a good result used.  MEASURED there and recorded so nobody
    # re-runs it: switching to `AltSpreadLogic_high`, Vivado's own
    # congestion-spreading directive, WITHOUT removing pblock_bd_i moves the
    # core's clock-region distribution by about six points and does not make
    # the design routable.  The constraint was the problem, not the directive.
    # ADDED 2026-09-04: the strategy is overridable from the environment,
    # DEFAULTING TO `Performance_RefinePlacement`, so an unset variable
    # reproduces every earlier build byte for byte.  The lever is provided,
    # NOT pulled.
    #
    # WHY THE PARAGRAPH ABOVE DOES NOT SETTLE IT.  That measurement asked
    # whether a directive change made the design ROUTABLE, and the answer was
    # no -- the constraint was the problem.  The question now is different:
    # the build reaches a bitstream with 0 errors and misses timing by
    # 0.203 ns (192.2 MHz).  MEASURED 2026-09-04 on the composed top
    # (docs/debugging/2026-09-04_composed-top-routed.md), implementation
    # directives moved a routed design 0.402 -> 0.110 ns and a POST-ROUTE
    # phys_opt -- a step `Performance_RefinePlacement` does NOT include --
    # was worth a further 0.051.  `Performance_ExplorePostRoutePhysOpt`
    # carries both.
    #
    # IT IS STILL NOT SWITCHED BY DEFAULT, and deliberately so: this build
    # currently PRODUCES A WORKING BITSTREAM, the pblock interacts with
    # placement, and trading a routable 192.2 MHz for an unrouteable 200 is a
    # bad trade nobody asked for.  Changing it is a judgement about hours of
    # build time against 4% of clock, so it is the operator's call.
    #
    # The readback check is not decoration: a misspelt strategy is accepted
    # silently by `set_property` on some versions and then does not apply,
    # which reads as "the strategy did not help" rather than "the strategy
    # never ran" -- and that mistake costs a whole build to discover.
    ("set_property strategy Performance_RefinePlacement [get_runs impl_1]",
     'set fk33_strategy "Performance_RefinePlacement"\n'
     'if {[info exists ::env(FK33_IMPL_STRATEGY)] '
     '&& $::env(FK33_IMPL_STRATEGY) ne ""} {\n'
     '    set fk33_strategy $::env(FK33_IMPL_STRATEGY)\n'
     '}\n'
     'set_property strategy $fk33_strategy [get_runs impl_1]\n'
     'if {[get_property strategy [get_runs impl_1]] ne $fk33_strategy} {\n'
     '    error "FK33_STRATEGY FAIL: asked for \'$fk33_strategy\', run '
     'reports \'[get_property strategy [get_runs impl_1]]\'. set_property '
     'accepted it silently and it did not apply."\n'
     '}\n'
     'puts "FK33_IMPL_STRATEGY [get_property strategy [get_runs impl_1]]"\n'
     f"add_files -fileset constrs_1 -norecurse {PBLOCK_XDC}\n"
     f"set_property used_in_synthesis false [get_files {PBLOCK_XDC}]\n"
     f"set_property used_in_implementation true [get_files {PBLOCK_XDC}]\n"
     f'if {{[get_property used_in_synthesis [get_files {PBLOCK_XDC}]]}} {{\n'
     '    error "FK33_PBLK FAIL: fk33_pblock.xdc is still used_in_synthesis. '
     'It addresses bd_i/eng/inst/eng/dut/core, a path that exists only in the '
     'LINKED design, so synthesis would read it, match nothing, leave an empty '
     'pb_core behind and say so only as a Vivado 12-180 warning."\n'
     "}\n"
     'puts "FK33_PBLK fk33_pblock.xdc added, implementation only"'),

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


# ---------------------------------------------------------------------------
# TEETH for the run guards.
#
# The guard cannot be exercised by running a real FK33 shell build: that is
# hours, and reproducing the failure would mean making launch_runs lie.  So the
# two procs are extracted FROM THE EMITTED BUILD SCRIPT -- not from a copy --
# and driven under tclsh with get_runs and get_property stubbed.  Everything
# the guard actually decides on is a stubbed property plus the real
# filesystem, so this covers the whole of its logic.
#
# Every case below is run TWICE: once against the emitted guard, and once
# against a MUTED guard whose body is replaced by a bare `return`.  A case that
# is caught by both is not evidence about the guard; only the cases the muted
# guard lets through are its own kills.  This is the attribution control, and
# it is mandatory.
#
# An analysis failure is VOID, never a kill: `VD` below feeds the harness a
# guard that will not parse, and the harness must report VOID rather than
# scoring a catch.

TCL = "/usr/bin/tclsh"

HARNESS_TCL = r'''
# argv: <guard.tcl> <proc> <DIRECTORY> <STATUS> <PROGRESS> [limit]
set guard [lindex $argv 0]
set pname [lindex $argv 1]
set ::P(DIRECTORY) [lindex $argv 2]
set ::P(STATUS)    [lindex $argv 3]
set ::P(PROGRESS)  [lindex $argv 4]
proc get_runs {n} { return $n }
proc get_property {p o} { return $::P($p) }
if {[catch {source $guard} e]} { puts "VOID $e"; exit 3 }
if {[llength [info commands $pname]] == 0} { puts "VOID no proc $pname"; exit 3 }
set args [list synth_1]
if {[llength $argv] > 5} { lappend args [lindex $argv 5] }
if {[catch {$pname {*}$args} e]} { puts "RAISED $e"; exit 1 }
puts "PASSED"
exit 0
'''


def _extract_proc(text, name):
    """Pull `proc <name> {...} { ... }` out of a Tcl file by brace counting."""
    i = text.find("proc %s " % name)
    if i < 0:
        return None
    j = text.find("{", text.find("}", i))       # opening brace of the body
    if j < 0:
        return None
    depth, k, in_str = 0, j, False
    while k < len(text):
        c = text[k]
        if c == "\\":
            k += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str and c == "{":
            depth += 1
        elif not in_str and c == "}":
            depth -= 1
            if depth == 0:
                return text[i:k + 1]
        k += 1
    return None


def _require_unique(names):
    """A duplicate row name is SILENT otherwise: the table looks full, one
    case is never run and another runs twice."""
    seen = set()
    for n in names:
        if n in seen:
            raise ValueError("duplicate selftest row name %r" % n)
        seen.add(n)


def selftest():
    import subprocess
    import tempfile

    # The gate for the gate.  Teeth-checked immediately below, because a
    # uniqueness check that has never been shown to fire is the same defect
    # this whole track exists to remove.
    try:
        _require_unique(["a", "a"])
    except ValueError:
        pass
    else:
        sys.exit("SELFTEST ABORT: _require_unique does not fire on a "
                 "duplicate, so a duplicated row name would be silent.")

    if not os.path.exists(TCL):
        sys.exit("SELFTEST VOID: %s not found. A missing interpreter is VOID, "
                 "not a pass." % TCL)
    # HERMETIC: the text is GENERATED for this invocation's configuration, not
    # read from build_fk33_pcieep.tcl.  See assemble_script() for what the old
    # coupling cost.  There is no longer a "run gen_pcieep.py first" step, and
    # no artefact on disk can make this verdict wrong.
    built = assemble_script()

    # WHICH CONFIGURATION IS THIS?  Still worth printing, because the rows
    # below differ between them -- but it is now a LABEL and not a hazard: the
    # text was generated from CARD_ON/ENG_ON a few lines up, so it cannot
    # disagree with the expectations it is graded against.
    #
    # The mismatch guard that stood here from earlier today is GONE, and
    # deliberately: it detected the coupling, which was an improvement on the
    # flakiness it replaced, and then took the shared gate red on sim:runguard
    # whenever a build had regenerated the artefact in another configuration.
    # A check that is correct and unactionable still stops the line. Removing
    # the coupling beats reporting it.
    _sel_card = ("create_bd_cell -type module -reference fk33_card" in built)
    _sel_eng  = ("create_bd_cell -type module -reference fk33_engine" in built)
    print("SELFTEST CONFIGURATION: FK33_CARD=%d FK33_ENG=%d (%s), generated in "
          "memory" % (CARD_ON, ENG_ON,
                      "three-cell card" if _sel_card else "no card"))
    if _sel_card != CARD_ON or _sel_eng != ENG_ON:
        sys.exit("SELFTEST VOID: generated text has card=%d eng=%d but this "
                 "invocation is CARD_ON=%d ENG_ON=%d. The emitter and its own "
                 "flags disagree, which is a defect in assemble_script(), not "
                 "a stale file." % (_sel_card, _sel_eng, CARD_ON, ENG_ON))

    procs = {}
    for pname in ("fk33_assert_run_started", "fk33_assert_run_done",
                  "fk33_bound"):
        body = _extract_proc(built, pname)
        if body is None:
            sys.exit("SELFTEST VOID: could not extract %s from %s." % (pname, DST))
        procs[pname] = body
    guard_src = "\n".join(procs[p] for p in sorted(procs)) + "\n"

    # The MUTED guard: same two procs, same names, same arity, bodies gutted.
    # This is the attribution control.  Anything it also catches was caught by
    # the harness or by tclsh, not by the guard.
    muted_src = ("proc fk33_assert_run_started {run} { return }\n"
                 "proc fk33_assert_run_done {run limit_min} { return }\n"
                 "proc fk33_bound {name v} { return $v }\n")
    # A guard that will not parse.  Must be VOID.
    broken_src = "proc fk33_assert_run_started {run} { if { \n"

    tmp = tempfile.mkdtemp(prefix="fk33guard.")
    started_ok = os.path.join(tmp, "started_ok")
    os.makedirs(started_ok)
    open(os.path.join(started_ok, "runme.sh"), "w").write("#!/bin/sh\n")
    # MEASURED shape of a directory that exists but whose run script was never
    # written.  Populated with the queue marker alone so this row cannot pass
    # merely by the directory being empty.
    started_bad = os.path.join(tmp, "started_bad")
    os.makedirs(started_bad)
    open(os.path.join(started_bad, ".Vivado_Synthesis.queue.rst"), "w").write("")
    absent = os.path.join(tmp, "never_created")

    # name, proc, DIRECTORY, STATUS, PROGRESS, limit, expect, msg_needle
    #   expect "RAISED" = the guard must refuse
    #   expect "PASSED" = the guard must NOT refuse
    #   msg_needle, when not None, must appear in the refusal text
    #
    # MEASURED while teeth-checking this table, and worth stating plainly
    # because it corrects the obvious reading of the guard: THE TWO CHECKS IN
    # fk33_assert_run_started ARE NOT INDEPENDENT.  When the directory is
    # absent, `file exists [file join $dir runme.sh]` is also false, so the
    # runme.sh check alone already refuses the BUILD-HANG state.  Neutering
    # the `file isdirectory` test to `if {0}` leaves NODIR still RAISED and is
    # caught by NOTHING on verdict alone.
    #
    # The isdirectory test is therefore not a second detector; it is what
    # makes the refusal SAY "no run directory at all" instead of "no runme.sh
    # in it".  Since the entire 27.6-hour cost of BUILD-HANG was
    # misdiagnosis -- the symptom was indistinguishable from a long
    # place-and-route -- the message is the thing that check buys, so the
    # message is what NODIR_MSG tests.  Without that row the check would be
    # decoration with no teeth of any kind.
    ROWS = [
        # --- the defect this guard exists for.  MEASURED 2026-08-29: this is
        #     the exact state the 27.6-hour build was in.
        ("NODIR", "fk33_assert_run_started", absent, "Not started", "0%",
         None, "RAISED", None),
        # --- same state, but the refusal must NAME it.  This is the only row
        #     that gives the `file isdirectory` test any teeth at all; see the
        #     note above.
        ("NODIR_MSG", "fk33_assert_run_started", absent, "Not started", "0%",
         None, "RAISED", "NO run directory at all"),
        # --- the directory appeared but no run script was written
        ("NOSCRIPT", "fk33_assert_run_started", started_bad, "Queued...", "0%",
         None, "RAISED", "no runme.sh in it"),
        # --- the healthy launch.  MEASURED: immediately after launch_runs
        #     returns, the directory holds runme.sh and STATUS is "Queued...".
        #     If this row ever RAISES, the guard breaks every correct build.
        ("OK_QUEUED", "fk33_assert_run_started", started_ok, "Queued...", "0%",
         None, "PASSED", None),
        # --- and the same directory once the run is finished
        ("OK_DONE", "fk33_assert_run_started", started_ok,
         "synth_design Complete!", "100%", None, "PASSED", None),
        # --- the bound expired.  MEASURED: wait_on_run -timeout returns rc 0
        #     with an empty message, leaving STATUS "Queued...", so without
        #     fk33_assert_run_done the bound would be decoration.
        ("TIMEOUT", "fk33_assert_run_done", started_ok, "Queued...", "0%",
         "360", "RAISED", "360-minute bound"),
        # --- a genuine synthesis failure, the case the ORIGINAL script
        #     already handled.  Kept so a regression here is visible.
        ("SYNTHFAIL", "fk33_assert_run_done", started_ok,
         "synth_design ERROR", "26%", "360", "RAISED", "runme.log"),
        # --- the healthy completion
        ("DONE_OK", "fk33_assert_run_done", started_ok,
         "synth_design Complete!", "100%", "360", "PASSED", None),
        # --- the bound validator.  -1 is the row that matters: it is Vivado's
        #     documented "no limit", so it reinstates the original defect
        #     while leaving every textual check on this script satisfied.
        #     Found by mutation, not by design.
        ("BOUND_NEG", "fk33_bound", "-", "-", "-", "-1", "RAISED",
         "NO LIMIT"),
        ("BOUND_ZERO", "fk33_bound", "-", "-", "-", "0", "RAISED", "NO LIMIT"),
        ("BOUND_JUNK", "fk33_bound", "-", "-", "-", "soon", "RAISED",
         "NO LIMIT"),
        ("BOUND_OK", "fk33_bound", "-", "-", "-", "360", "PASSED", None),
    ]
    _require_unique([r[0] for r in ROWS])

    def run(src_text, row):
        _, pname, d, st, prog, limit = row[:6]
        gf = os.path.join(tmp, "g.tcl")
        open(gf, "w").write(src_text)
        hf = os.path.join(tmp, "h.tcl")
        open(hf, "w").write(HARNESS_TCL)
        argv = [TCL, hf, gf, pname, d, st, prog]
        if limit is not None:
            argv.append(limit)
        p = subprocess.run(argv, capture_output=True, text=True)
        out = (p.stdout + p.stderr).splitlines()
        # The guard PRINTS on the healthy path (FK33_RUNSTART ...), so the
        # verdict is the LAST marker line, not the first.  Taking the first
        # line scored three healthy rows as refusals on the first run of this
        # harness -- a harness defect that would have read as a guard defect.
        verdict = None
        for line in reversed(out):
            head = line.split(" ", 1)[0]
            if head in ("PASSED", "RAISED", "VOID"):
                verdict = head
                break
        if verdict is None or p.returncode == 3:
            return "VOID", ""
        return verdict, "\n".join(out)

    print("row        expect    guard     muted     attribution")
    print("-" * 62)
    bad = []
    guard_alone = both = neither = 0
    for row in ROWS:
        name, exp, needle = row[0], row[6], row[7]
        g, gtext = run(guard_src, row)
        m, _ = run(muted_src, row)
        if needle is not None and g == "RAISED" and needle not in gtext:
            # The refusal happened but did not SAY the right thing.  Treat
            # that as a failure of the row, not as a kill: a message that
            # names the wrong cause is what cost 27.6 hours.
            g = "WRONGMSG"
        if exp == "RAISED":
            gk, mk = (g == "RAISED"), (m == "RAISED")
            if gk and not mk:
                attr, guard_alone = "GUARD ALONE", guard_alone + 1
            elif gk and mk:
                attr, both = "both", both + 1
            elif mk:
                attr = "MUTED ONLY"
            else:
                attr, neither = "NEITHER", neither + 1
        else:
            attr = "n/a (must not refuse)"
        ok = (g == exp)
        if not ok:
            bad.append("%s: expected %s, guard gave %s" % (name, exp, g))
        print("%-10s %-9s %-9s %-9s %s%s"
              % (name, exp, g, m, attr, "" if ok else "   <== WRONG"))

    # VOID row.  A guard that will not parse must NOT be scored as a kill.
    vd, _ = run(broken_src, ROWS[0])
    print("%-10s %-9s %-9s %-9s %s%s"
          % ("VD", "VOID", vd, "-", "unparseable guard",
             "" if vd == "VOID" else "   <== WRONG"))
    if vd != "VOID":
        bad.append("VD: an unparseable guard scored %s, not VOID" % vd)

    # Whole-file Tcl completeness.  This generator injects ~30 lines of Tcl
    # into the build script; an unbalanced brace there would be found only by
    # a build, hours later.  `info complete` is not a full parse, but it is
    # the check that would have caught that.
    cf = os.path.join(tmp, "c.tcl")
    open(cf, "w").write(
        'set fh [open [lindex $argv 0] r]; set t [read $fh]; close $fh\n'
        'if {[info complete $t]} { puts "PASSED" } else { puts "RAISED" }\n')
    # The parse check reads the GENERATED text too, written to the scratch
    # directory, so it cannot disagree with the rows above about what is being
    # graded.
    gf = os.path.join(tmp, "generated.tcl")
    open(gf, "w").write(HEADER + built)
    pc = subprocess.run([TCL, cf, gf], capture_output=True, text=True)
    parse = (pc.stdout + pc.stderr).strip().splitlines()
    parse = parse[-1].split(" ", 1)[0] if parse else "VOID"
    print("%-10s %-9s %-9s %-9s %s%s"
          % ("PARSE", "PASSED", parse, "-", "info complete on the whole file",
             "" if parse == "PASSED" else "   <== WRONG"))
    if parse != "PASSED":
        bad.append("PARSE: %s is not complete Tcl" % DST)

    print("-" * 62)
    print("GUARD ALONE=%d  both=%d  NEITHER=%d" % (guard_alone, both, neither))
    if bad:
        for b in bad:
            print("FAIL " + b)
        sys.exit("SELFTEST FAIL")
    if guard_alone == 0:
        sys.exit("SELFTEST FAIL: the guard earned no kill of its own. Every "
                 "refusal also happened with the guard muted, so nothing here "
                 "measures the guard.")

    reset_topology_teeth()
    addr_map_teeth()
    seam_tieoff_teeth()

    print("SELFTEST PASS")


# ---------------------------------------------------------------------------
# THE RESET TOPOLOGY THAT MAKES STRAY-NEXTJOB UNREACHABLE
# ---------------------------------------------------------------------------
# Added 2026-08-30, TRACK RESETGUARD, on TRACK STRAYREACH's handoff.  Its
# closing words were "today that property is documented, not checked", and this
# is the check.  Everything below is about ONE structural fact and nothing else.
#
# STRAY-NEXTJOB is a real defect in rtl/axi_rd_fsm.vhd: `rst` zeroes `outst`
# and `arv`, so a burst the port issued BEFORE the reset can return AFTER it and
# be retired against the new job's counters -- its first beat becomes the next
# job's word 0.  Silent wrong numbers, no error bit, no stall.  TRACK STRAYREACH
# reproduced it on a bench (E0: `got 3133 want 5120`).
#
# It is unreachable on the shipping FK33 for exactly one reason, and the reason
# is three lines of wiring in this file rather than anything in rtl/:
#
#     xdma/axi_aresetn              -> core_reset/ext_reset_in
#     core_reset/peripheral_aresetn -> eng/core_aresetn
#     xdma/axi_aresetn              -> hbm/AXI_nn_ARESET_N   (all 28 masters)
#
# `eng/core_aresetn` is not a SIBLING of the slave's reset, it is a DESCENDANT
# of it, generated by a proc_sys_reset whose ext_reset_in IS the slave's reset
# net.  So the port's reset cannot assert unless the slave's asserted first, and
# the window the defect needs does not exist.
#
# That argument survives nothing.  Reorganise the reset tree, give the compute
# domain its own reset register, add a second clock domain, or hand core_reset
# an auxiliary reset, and the defect is live again -- WITH EVERY EXISTING TEST
# STILL GREEN, because the defect is in the RTL's reachability, not in its
# structure.  Hence a refusal here rather than a paragraph in a document.
#
# WHAT IS DELIBERATELY NOT CHECKED, and why, because a checker whose scope is
# guessed is a checker that passes for the wrong reason:
#   * hbm/AXI_00_ARESET_N and hbm/AXI_16_ARESET_N.  They are the BRING-UP
#     ports (pcie2hbm, jtag_hbm), not engine masters, so no axi_rd_port ever
#     reads through them and STRAY-NEXTJOB cannot involve them.  They are also
#     the only two ARESET_N pins with a different driver in the EnablePCIe == 0
#     branch, and excluding them is what lets this scan ignore Tcl branch
#     structure entirely rather than parse it badly.  A grep that does not know
#     this reports a mixed topology that exists in no build.
#   * the depth of the trace.  This compares the IMMEDIATE driver pin of each
#     sink.  It catches the reset tree being re-rooted, which is the threat;
#     it does not follow a chain of renaming cells.
_BD_ENDPOINT_RE = re.compile(r"\[get_bd_(?:pins|ports)\s+([^\]\s]+)\s*\]")


def _bd_net_peers(text, endpoint):
    """Every other endpoint a `connect_bd_net` line joins to `endpoint`.

    Order-independent on purpose: `connect_bd_net a b` and `connect_bd_net b a`
    describe the same net, so a checker that assumed "source first" could be
    defeated by a reordering that changes nothing in the hardware.  Full-line
    Tcl comments are skipped, because build_fk33_pcieep.tcl carries
    commented-out connections and counting one as a driver would report a net
    that is not there.
    """
    peers = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") or "connect_bd_net" not in s:
            continue
        ends = _BD_ENDPOINT_RE.findall(s)
        if len(ends) != 2:
            continue
        if ends[0] == endpoint:
            peers.append(ends[1])
        elif ends[1] == endpoint:
            peers.append(ends[0])
    return peers


_RESET_WHY = """
THE PROPERTY.  The engine's core-domain reset must be a DESCENDANT of the same
net that resets every HBM slave port the engine reads from, so that a read port
can never be reset while the slave still holds a burst that port issued before
the reset.

WHY IT MATTERS.  That is the ONLY reason defect STRAY-NEXTJOB is unreachable on
this card.  STRAY-NEXTJOB is a wrong-numbers defect in rtl/axi_rd_fsm.vhd: `rst`
zeroes `outst` and `arv`, so a pre-reset burst returning after the reset is
retired against the NEXT job's counters and its first beat is handed over as
that job's word 0.  It is silent -- no error bit, no stall, no timeout.

WHAT BREAKING THIS COSTS.  Nothing turns red.  Every unit test, every bench row
and every gate row stays green, because the defect is in the RTL's
REACHABILITY, not in its structure.  The wiring in this generator is the whole
guard, which is why it is asserted here.

READ FIRST.  docs/debugging/2026-08-30_strayreach-is-stray-nextjob-reachable.md
measures all of the above, and also measures that the OBVIOUS fix -- preserving
`outst`/`arv` across `rst` so S_DRAIN waits for the strays -- HANGS this card.
Rows sfast/sslow/snear of sim/tb_axi_rd_port_stray.vhd simulate the topology
this function checks.  If you meant to change the reset tree, that document is
the thing to read before deciding what to do about this refusal.
"""


# ---------------------------------------------------------------------------
# THE ADDRESS MAP (TRACK SEAMMAP, 2026-08-30)
# ---------------------------------------------------------------------------
# WHY THIS IS PARSED OUT OF THE EMITTED TEXT AND NOT WRITTEN AS A TABLE HERE.
#
# The obvious shape is a hand-maintained list of (name, base, size) in this
# file, checked for overlap.  That is the defect class this repository keeps
# finding: a descriptor base rule that agreed with its cross-check "by
# coincidence of geometry on every file it had ever seen".  A hand table would
# be a SECOND statement of the map, checked against itself, and it would stay
# green while the emitter drifted away from it.
#
# So the map is read back out of the build script this generator just built.
# There is exactly one statement of the address map and this reads it.
#
# THE PARTITION IS THE WHOLE PROBLEM.  Three DIFFERENT address spaces are
# assigned in one file and their offsets legitimately collide:
#
#   BAR   the 128 KB PCIe AXI-Lite master.  SYSMON at 0x3000, GPIO 0x9000,
#         id 0xA000, thermal 0xB/C/D000, seam 0xE000, scratch 0x10000+8K,
#         engine 0x12000/0x13000.
#   AUX   jtag_aux's own space, reachable with the PCIe link DOWN and never on
#         the BAR.  aux_id at 0x0000 ... aux_ctl at 0x6000.
#   DMA   the XDMA DMA master, where fk33_dmabram sits at 0x200000000, above
#         the 8 GiB of HBM.
#
# A naive "no two offsets may repeat" check would REFUSE the correct design,
# because AUX 0x3000 (aux_time) and BAR 0x3000 (SYSMON) are both real and are
# in different spaces.  So each segment is classified explicitly and an
# UNCLASSIFIED segment is a hard refusal.  That is the direction that fails
# safe: a peripheral added later cannot be silently excluded from the overlap
# check by being unknown to it -- it stops the build until someone says which
# space it is in.
SEG_SPACE = {
    # --- on the PCIe AXI-Lite BAR -------------------------------------------
    "system_management_wiz_0": "BAR",   # SYSMON
    "axi_gpio_0":              "BAR",   # I2C / LED
    "fk33_id":                 "BAR",
    "fk33_scratch":            "BAR",
    "fk33_therm":              "BAR",
    "fk33_thermp":             "BAR",
    "fk33_thermc":             "BAR",
    "eng":                     "BAR",   # both s_axi and s_axix
    SEAM_CELL:                 "BAR",
    # --- jtag_aux's own space, never on the BAR -----------------------------
    "aux_id":                  "AUX",
    "aux_clkst":               "AUX",
    "aux_stat":                "AUX",
    "aux_time":                "AUX",
    "aux_therm":               "AUX",
    "aux_peak":                "AUX",
    "aux_ctl":                 "AUX",
    # --- the XDMA DMA master ------------------------------------------------
    "fk33_dmabram":            "DMA",
    "hbm":                      "DMA",   # SAXI_00 0..4G, SAXI_16 4..8G
}

# THE EMITTED SCRIPT CONTAINS MUTUALLY EXCLUSIVE TCL BRANCHES, AND A STATIC
# SCAN SEES BOTH ARMS.  MEASURED 2026-08-30 while building this check:
# `build_fk33_i2cprobe.tcl` assigns `hbm/SAXI_00/HBM_MEM00` at 0x0 inside
# `if {$HBMGlobalSwitch == 1}` AND again at 0x0 inside the `else`, so 34 of
# the 66 static assignments belong to two arms only one of which ever runs.
#
# A scan that pooled them would refuse the CORRECT design, which is the way a
# guard gets deleted.  A scan that silently dropped duplicates would stop
# seeing a segment genuinely assigned twice.  So: identical (segment, base,
# range) rows are the same decision written in two arms and collapse; a
# segment assigned two DIFFERENT addresses is a defect and refuses.  That
# keeps the whole 8 GiB DMA space inside the overlap check rather than
# carving `hbm` out of it.

# CONFIG.axilite_master_size {128} / axilite_master_scale {Kilobytes}.  This is
# what the design ASKS the XDMA IP for; see the caveat in the SEAM_BASE block
# about a CONFIG.* being a request rather than an answer.
BAR_BYTES = 128 * 1024

# The masters through which the HOST reaches the AXI-Lite BAR.  Anything
# assigned into some OTHER master's address space is that master's private
# view and is not part of the host register map, so it must not be folded
# into the BAR overlap check.  Kept next to the regex because both describe
# the shape of the emitted assign_bd_address lines.
_HOST_MASTERS = ("jtag_axil/Data", "xdma/M_AXI_LITE")

_ASSIGN_RE = re.compile(
    r"^assign_bd_address\s+-offset\s+(0x[0-9A-Fa-f]+)\s+-range\s+(\S+)\s+"
    r"\[get_bd_addr_segs\s*\{([^}]+)\}\]\s*$", re.M)

_RANGE_MUL = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}


def _parse_range(tok):
    m = re.fullmatch(r"(\d+)([KMG]?)", tok)
    if not m:
        return None
    return int(m.group(1)) * _RANGE_MUL[m.group(2)]


def parse_address_map(text):
    """Every static assign_bd_address in `text`, as (space, cell, seg, base, size).

    Lines carrying -target_address_space are the 28 x 32 HBM segment
    assignments and are deliberately not here: they are the engine masters'
    view of HBM, not a slave map, and they are already bounded by the IP.
    """
    rows = []
    # Tcl line continuations first.  The 28 x 32 HBM assignments are written
    # across four lines with trailing backslashes, and a scan that reads only
    # the first line sees `assign_bd_address \` and neither the offset nor the
    # -target_address_space that says it is not a BAR slave.  Joining is not
    # cosmetic: without it the check either crashes or, worse, silently
    # classifies 896 HBM segments as unparseable BAR entries.
    joined = re.sub(r"\\\n\s*", " ", text)
    # THE MASTER CAN BE A TCL VARIABLE.  The host's view of the engine control
    # page is emitted inside `foreach sp {jtag_axil/Data xdma/M_AXI_LITE} {`,
    # so the assignment's -target_address_space reads `$sp` and the master
    # names exist only in the loop header.  Track the binding as the scan walks
    # the file.  This resolves the one shape this generator emits; it is NOT a
    # Tcl interpreter and does not pretend to be.  An unresolved variable is
    # left unresolved and the assignment is skipped rather than guessed at.
    _foreach = {}
    _depth = 0
    for line in joined.splitlines():
        s = line.strip()
        _mfe = re.match(r"^foreach\s+(\w+)\s+\{([^}]*)\}\s*\{", s)
        if _mfe:
            _foreach[_mfe.group(1)] = _mfe.group(2).split()
            _depth += 1
            continue
        if s == "}" and _depth:
            _depth -= 1
            if _depth == 0:
                _foreach = {}
            continue
        if not s.startswith("assign_bd_address"):
            continue
        if "-target_address_space" in s:
            # NOT ALL OF THESE ARE HBM, and assuming so left a REAL BAR PAGE
            # invisible to the overlap check.  MEASURED 2026-09-11 on a
            # card-on file: `eng/s_axi/reg0` is assigned at 0x12000 inside a
            # `foreach sp {jtag_axil/Data xdma/M_AXI_LITE}` loop and carries
            # -target_address_space because it is given to two named masters.
            # Skipping on the FLAG rather than on the SEGMENT meant the guard
            # could not see it, so mutating it onto the 8 KB scratch at
            # 0x11000 -- the exact collision the comment above that block says
            # cost a --bd-only run -- was ACCEPTED by check_bar_map.  The
            # SEG_SPACE entry has said `"eng": "BAR",  # both s_axi and s_axix`
            # the whole time; only one of the two was ever actually covered.
            #
            # Filter by what the line ADDRESSES, not by which flags it uses.
            _mseg = re.search(r"\[get_bd_addr_segs\s*\{([^}]+)\}\]", s)
            if _mseg is None:
                # No explicit segment: an auto-assign of a master's whole view
                # (the engine's view of HBM).  It has no static base, so it is
                # out of this function's contract, which is STATIC assignments.
                continue
            _seg = _mseg.group(1).strip()
            _cell = _seg.split("/")[0]
            if SEG_SPACE.get(_cell) == "DMA":
                continue          # the masters' view of HBM, as before
            # ONE SEGMENT, TWO LEGITIMATE ADDRESSES.  A slave may sit at a
            # different offset in each master's address space, and
            # `eng/s_axi/reg0` genuinely does: 0x0 range 256 in `card/a`'s
            # space (the card's own internal master) and 0x12000 range 4K in
            # the HOST masters' spaces.  Those do not conflict, and keying the
            # collapse below by segment alone reports them as a contradiction.
            #
            # The BAR overlap check is a statement about WHAT THE HOST SEES, so
            # admit only assignments into a host master and let every internal
            # master's view through untouched.
            _mts = re.search(r"-target_address_space\s+\[get_bd_addr_spaces\s+"
                             r"(?:\{\s*)?([^\]\}\s]+)", s)
            if _mts is None:
                continue
            _tgt = _mts.group(1)
            if _tgt.startswith("$"):
                _items = _foreach.get(_tgt[1:])
                if not _items:
                    continue      # unresolved variable: skip, never guess
                if not all(i in _HOST_MASTERS for i in _items):
                    continue      # at least one internal master in the loop
            elif _tgt not in _HOST_MASTERS:
                continue
            _moff = re.search(r"-offset\s+(0x[0-9A-Fa-f]+)", s)
            _mrng = re.search(r"-range\s+(\S+)", s)
            if _moff is None or _mrng is None:
                continue          # not a static assignment
            _size = _parse_range(_mrng.group(1))
            if _size is None:
                sys.exit("ABORT: cannot read the -range token %r on:\n  %s"
                         % (_mrng.group(1), s))
            _space = SEG_SPACE.get(_cell)
            if _space is None:
                sys.exit("ABORT: %r is assigned an address but gen_pcieep.py's "
                         "SEG_SPACE does not say which address space it is in, "
                         "so the overlap check cannot cover it. Add it to "
                         "SEG_SPACE as BAR, AUX or DMA.\n  %s" % (_cell, s))
            rows.append((_space, _cell, _seg, int(_moff.group(1), 16), _size))
            continue
        m = _ASSIGN_RE.match(s)
        if not m:
            sys.exit("ABORT: an assign_bd_address line in the emitted build "
                     "script does not parse, so the address-map overlap check "
                     "would silently skip it:\n  %s" % s)
        base = int(m.group(1), 16)
        size = _parse_range(m.group(2))
        if size is None:
            sys.exit("ABORT: cannot read the -range token %r on:\n  %s"
                     % (m.group(2), s))
        seg = m.group(3).strip()
        cell = seg.split("/")[0]
        space = SEG_SPACE.get(cell)
        if space is None:
            sys.exit("ABORT: %r is assigned an address but gen_pcieep.py's "
                     "SEG_SPACE does not say which address space it is in, so "
                     "the overlap check cannot cover it. Add it to SEG_SPACE "
                     "as BAR, AUX or DMA.\n  %s" % (cell, s))
        rows.append((space, cell, seg, base, size))

    # Collapse the two arms of a Tcl if/else.  See the note above SEG_SPACE.
    seen = {}
    out = []
    for r in rows:
        prev = seen.get(r[2])
        if prev is None:
            seen[r[2]] = r
            out.append(r)
        elif prev[3] != r[3] or prev[4] != r[4]:
            sys.exit("ABORT: segment %s is assigned at %#x range %d AND at "
                     "%#x range %d in the same build script. Only one can be "
                     "the address the host uses and nothing here can say "
                     "which."
                     % (r[2], prev[3], prev[4], r[3], r[4]))
    return out


def check_bar_map(text):
    """Refuse to emit a build whose address map overlaps or leaves the BAR.

    WHAT WOULD MAKE THIS FAIL, since a check nobody can answer that for is
    decoration: two slaves given the same 4 KB page; a slave whose range runs
    past the 128 KB BAR; a base that is not 4 KB aligned, which aliases a 12-bit
    slave onto itself; and the seam being absent from the map altogether.
    """
    rows = parse_address_map(text)
    bar = [r for r in rows if r[0] == "BAR"]
    if not bar:
        sys.exit("ABORT: the emitted build script assigns NOTHING to the PCIe "
                 "AXI-Lite BAR. The host would have no register map at all.")

    for space, cell, seg, base, size in rows:
        if base % 4096:
            sys.exit("ABORT: %s is at %#x, which is not 4 KB aligned. An "
                     "AXI-Lite slave that decodes 12 address bits would alias "
                     "its own register file." % (seg, base))
        if size % 4096:
            sys.exit("ABORT: %s has a range of %d bytes, which is not a whole "
                     "number of 4 KB pages." % (seg, size))

    for space, cell, seg, base, size in bar:
        if base + size > BAR_BYTES:
            sys.exit("ABORT: %s occupies %#x..%#x, which runs past the %d KB "
                     "AXI-Lite BAR (ends at %#x). Vivado would refuse this "
                     "with BD 41-1075, but only after the whole block design "
                     "has been built."
                     % (seg, base, base + size - 1, BAR_BYTES // 1024,
                        BAR_BYTES - 1))

    for space in ("BAR", "AUX", "DMA"):
        grp = sorted([r for r in rows if r[0] == space], key=lambda r: r[3])
        for a, b in zip(grp, grp[1:]):
            if a[3] + a[4] > b[3]:
                sys.exit("ABORT: in the %s address space, %s occupies "
                         "%#x..%#x and OVERLAPS %s at %#x. One of the two "
                         "would be unreachable, and which one is a property "
                         "of the interconnect rather than of this file."
                         % (space, a[2], a[3], a[3] + a[4] - 1, b[2], b[3]))

    seam = [r for r in bar if r[1] == SEAM_CELL]
    if len(seam) != 1:
        sys.exit("ABORT: the host seam is assigned %d BAR addresses, not 1. "
                 "Board row N2 was resolved in favour of building this block; "
                 "a bitstream that does not decode it leaves "
                 "server/fk33_seam.h driving nothing, which is the state N2 "
                 "was filed about." % len(seam))
    if seam[0][3] != SEAM_BASE or seam[0][4] != SEAM_SPAN:
        sys.exit("ABORT: the host seam is mapped at %#x range %d, not at "
                 "SEAM_BASE %#x range %d. server/fk33_seam.h would name an "
                 "address no bitstream decodes."
                 % (seam[0][3], seam[0][4], SEAM_BASE, SEAM_SPAN))

    print("FK33_SEAMMAP BAR map OK: %d slaves, seam at %#x, %d bytes of %d KB "
          "BAR assigned"
          % (len(bar), SEAM_BASE, sum(r[4] for r in bar), BAR_BYTES // 1024))


def check_seam_tieoff(text, eng_src=None):
    """The tie-off must not outlive the reason for it.

    SEAM_BLOCK drives fk33_seam's subsystem-D face from constants because
    there is no subsystem D in this design.  The moment `hw/fk33/rtl/
    fk33_engine.vhd` gains a `llama_top`, those constants become a bitstream
    that answers ERR to every GO while a real transformer sits behind it, and
    nothing else in this file would notice.
    """
    tied = "[get_bd_pins seam_h1/dout] [get_bd_pins %s/d_err]" % SEAM_CELL
    has_tie = tied in text
    if eng_src is None:
        try:
            eng_src = open(ENG_RTL).read()
        except OSError:
            eng_src = ""
    # STRIP VHDL COMMENTS FIRST, AND MATCH AN INSTANTIATION, NOT THE WORD.
    #
    # This used to be `re.search(r"\bllama_top\b", eng_src)`, which matches the
    # word ANYWHERE -- including a comment.  MEASURED 2026-09-03:
    # `hw/fk33/rtl/fk33_engine.vhd` has carried three COMMENT references to
    # `llama_top.vhd:3197-3226` since 3a145fd ("fk33_engine gains a D-facing
    # surface"), and they are citations of a contract, not an instantiation.
    # So this guard aborted the ENTIRE pcieep build -- `--bd-only` and the full
    # bitstream alike -- with "instantiates llama_top" about a design that does
    # not, and had done since that commit.  Nothing caught it because nothing
    # schedules `pcieep_build.sh`.
    #
    # It is the same trap as `pgrep -f` matching its own command line and as a
    # sentinel grep matching the script embedded in its own log: a haystack
    # that can contain the needle in a context you did not mean.  Anchor it.
    eng_nc = re.sub(r"--[^\n]*", "", eng_src)
    has_d = (re.search(r"entity\s+work\.llama_top\b", eng_nc) is not None
             or re.search(r":\s*llama_top\s", eng_nc) is not None)
    # SUBSYSTEM D MOVED OUT OF fk33_engine, AND THIS GUARD DID NOT FOLLOW IT.
    # The three-cell split puts D inside `card` (fk33_llama_top), so scanning
    # ENG_RTL alone reports has_d = False for a design that certainly has D --
    # a false NEGATIVE, which is the direction that ships the bug rather than
    # blocking the build.  The card being enabled IS D being present.
    #
    # AND DERIVE IT FROM THE TEXT, NOT ONLY FROM THE ENVIRONMENT.  CARD_ON is
    # read from FK33_CARD at import, so grading a file written by a DIFFERENT
    # invocation made this guard's verdict a property of the caller's shell
    # rather than of the file.  MEASURED 2026-09-11 on the same card-on file:
    #
    #   FK33_CARD unset  ->  the SHIPPING file is REFUSED ("the tie-off is
    #                        gone but ..."), and re-adding the tie is ACCEPTED
    #   FK33_CARD=1      ->  the shipping file is accepted, and re-adding the
    #                        tie is REFUSED
    #
    # Exactly inverted, same bytes. During generation the two always agree, so
    # this never fired there; it only bites a checker pointed at a file, which
    # is what the selftest and the gate do. A file that instantiates the card
    # HAS subsystem D whoever is asking.
    if CARD_ON or ("create_bd_cell -type module -reference fk33_card" in text):
        has_d = True
    if has_tie and has_d:
        sys.exit("ABORT: %s instantiates llama_top, so subsystem D IS in this "
                 "design, but SEAM_BLOCK still ties the seam's d_err HIGH. "
                 "Every GO would be refused with FK33_SEAM_ERR_DESC and "
                 "ERR_INFO[3:0] = 0x%X while a real transformer sat behind "
                 "the seam. Remove the tie-off in _SEAM_TIES and wire the "
                 "seam to the engine." % (ENG_RTL, SEAM_NO_D_CODE))
    if not has_tie and not has_d:
        sys.exit("ABORT: the seam's d_err tie-off is gone but %s still has no "
                 "llama_top, so the seam's subsystem-D face is driven by "
                 "nothing. A GO would set `running` and never clear it: STATUS "
                 "would report neither done nor err and a host polling "
                 "(done | err) would hang forever." % ENG_RTL)
    # Name WHERE D is, not just that it is somewhere.  With the card on, D is
    # in `card`, and reporting it against fk33_engine.vhd would be a false
    # statement in the build log of the kind this project keeps being caught by.
    print("FK33_SEAMMAP tie-off %s and subsystem D is %s -- consistent"
          % ("present" if has_tie else "absent",
             ("in the %s cell (FK33_CARD)" % CARD_CELL) if CARD_ON
             else ("in %s" % os.path.basename(ENG_RTL)) if has_d
             else "absent"))


def _reset_abort(detail):
    sys.exit("ABORT: the engine reset topology no longer makes STRAY-NEXTJOB "
             "unreachable.\n\n%s\nWHAT CHANGED: %s\n" % (_RESET_WHY, detail))


def check_reset_topology(text):
    """Refuse to emit a build whose reset tree re-opens STRAY-NEXTJOB.

    SKIPPED ENTIRELY WHEN FK33_ENG=0.  Every rule below is about the engine's
    28 master ports and its core reset descending from theirs; with no engine
    cell there are no such ports, and the check reported all 28 as "driven by
    nothing" -- which is TRUE and is not a defect.  Skipping is right here and
    weakening the rule would not be: the rule protects a hazard
    (STRAY-NEXTJOB) that only exists when the engine exists.

    The SLAVE side defines the reference net and the ENGINE side has to descend
    from it, not the other way round.  Stated that way the rule accepts any
    topology in which the descendancy holds -- including wiring the engine
    reset straight to the slave's net, which is SAFER than what ships today --
    and refuses only the topologies in which the engine's reset can assert
    while the slave's has not.  A rule written the other way round (`the driver
    must literally be core_reset/peripheral_aresetn`) would refuse a
    strictly-safe simplification, and a checker that refuses safe changes is a
    checker that gets deleted.
    """
    # WHETHER THERE IS AN ENGINE IS A FACT ABOUT THE SCRIPT, NOT ABOUT THE
    # ENVIRONMENT.  Keying this on ENG_ON would make the teeth rows below
    # vacuous under FK33_ENG=0 -- every mutation accepted, table still green --
    # which is the "check that passes for the wrong reason" shape this file
    # exists to avoid.  The cell-creation line is the DEFINITION of the engine
    # being present, and it cannot be confused with the wiring this checks:
    # deleting a connect_bd_net leaves it, so a broken topology is still
    # refused.
    if "create_bd_cell -type module -reference fk33_engine" not in text:
        return
    # 1. Every engine master port's ARESET_N, and they must agree.  This is the
    #    reference net: it is the reset of the slaves that hold the in-flight
    #    bursts.
    src = None
    bad = []
    for i, port in enumerate(ENG_PORT_MAP):
        pin = "hbm/AXI_%02d_ARESET_N" % port
        got = _bd_net_peers(text, pin)
        if len(got) != 1:
            bad.append("m%02d_axi -> %s is driven by %s"
                       % (i, pin, ", ".join(got) or "nothing"))
        elif src is None:
            src = got[0]
        elif got[0] != src:
            bad.append("m%02d_axi -> %s is driven by %s, but m00_axi's port is "
                       "driven by %s" % (i, pin, got[0], src))
    if bad or src is None:
        _reset_abort("the %d engine master ports do not share one reset net, "
                     "so there is no single net the engine's own reset can be "
                     "required to descend from:\n  %s"
                     % (len(ENG_PORT_MAP), "\n  ".join(bad) or "no port is "
                        "connected at all"))

    # 2. The engine's core-domain reset.
    sink = "%s/core_aresetn" % ENG_CELL
    got = _bd_net_peers(text, sink)
    if len(got) != 1:
        _reset_abort("%s has %d drivers (%s), not exactly one."
                     % (sink, len(got), ", ".join(got) or "none"))
    eng_src = got[0]

    if eng_src == src:
        print("FK33_RESETGUARD %s and all %d engine hbm/AXI_nn_ARESET_N are the "
              "SAME net, %s" % (sink, len(ENG_PORT_MAP), src))
        return

    # 3. Otherwise it must be the peripheral_aresetn of a proc_sys_reset that
    #    the reference net drives, which is the shipping shape.
    if not eng_src.endswith("/peripheral_aresetn"):
        _reset_abort("%s is driven by %s, which is neither the engine masters' "
                     "own reset net (%s) nor the peripheral_aresetn of a "
                     "reset generator." % (sink, eng_src, src))
    cell = eng_src.rsplit("/", 1)[0]

    if ("create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 %s"
            % cell) not in text:
        _reset_abort("%s is not created as a proc_sys_reset:5.0.  The property "
                     "rests on peripheral_aresetn being GENERATED from "
                     "ext_reset_in inside that specific IP; any other cell "
                     "makes the descendancy an assumption this file cannot "
                     "see." % cell)

    ext = _bd_net_peers(text, "%s/ext_reset_in" % cell)
    if ext != [src]:
        _reset_abort("%s/ext_reset_in is driven by %s, but the engine's HBM "
                     "slave ports are reset by %s.  The engine's reset is now "
                     "a SIBLING of the slave's rather than a DESCENDANT of it, "
                     "so it can assert while the slave stays released and a "
                     "burst issued before the reset can be retired against the "
                     "next job's counters."
                     % (cell, ", ".join(ext) or "nothing", src))

    # proc_sys_reset ORs aux_reset_in and mb_debug_sys_rst into
    # peripheral_aresetn.  They are UNDRIVEN today, which is what lets the
    # descendancy be stated without knowing what a BD ties an unconnected
    # active-low reset input to: an undriven pin is a CONSTANT, and a constant
    # cannot produce a mid-job reset event.  Connect either one -- an engine
    # reset register, a gateware-timed abort, a debug reset -- and the engine
    # gains a reset source the HBM slave does not share, which is exactly the
    # window the defect needs.
    for aux in ("aux_reset_in", "mb_debug_sys_rst"):
        got = _bd_net_peers(text, "%s/%s" % (cell, aux))
        if got:
            _reset_abort("%s/%s is now driven by %s.  proc_sys_reset ORs it "
                         "into peripheral_aresetn, so it can assert the "
                         "engine's reset while %s -- and therefore every HBM "
                         "slave port -- stays released."
                         % (cell, aux, ", ".join(got), src))

    # dcm_locked is the third way in.  It is safe TODAY only because the MMCM
    # that drives it is itself held in reset by `src`, so a lock drop cannot
    # happen without the slave's reset.  Re-root the MMCM on a free-running
    # clock with its own reset and the engine resets on an unlock that the
    # slave never sees.
    lock = _bd_net_peers(text, "%s/dcm_locked" % cell)
    if len(lock) > 1:
        _reset_abort("%s/dcm_locked has %d drivers (%s)."
                     % (cell, len(lock), ", ".join(lock)))
    if lock:
        mmcm = lock[0].rsplit("/", 1)[0]
        mrst = (_bd_net_peers(text, "%s/resetn" % mmcm)
                + _bd_net_peers(text, "%s/reset" % mmcm))
        if mrst != [src]:
            _reset_abort("%s/dcm_locked comes from %s, but %s's own reset is "
                         "%s rather than %s.  An unlock would then assert the "
                         "engine's reset without asserting the HBM slave's."
                         % (cell, lock[0], mmcm,
                            ", ".join(mrst) or "undriven", src))

    print("FK33_RESETGUARD %s descends from %s via %s, and so do all %d engine "
          "hbm/AXI_nn_ARESET_N" % (sink, src, cell, len(ENG_PORT_MAP)))


# ---------------------------------------------------------------------------
# TEETH FOR THE ABOVE (TRACK RESETLAND, 2026-08-30)
# ---------------------------------------------------------------------------
# check_reset_topology has never been shown to REFUSE anything, and a checker
# never shown to fail has not been shown to work.  These rows show it.
#
# THE BASE IS NOT HAND-WRITTEN TCL.  It is ENGINE_BLOCK, the real emitted
# engine wiring, plus the one line the property depends on that comes from the
# probe script rather than from here (clk_wiz_0's own reset).  Writing a
# plausible-looking fake base instead would be the classic guard-passes-for-
# the-wrong-reason shape: the rows would pass against text no build emits, and
# a change to the EMITTER that broke the property would leave them green.
# Mutating the real block means an emitter change that removes one of these
# lines turns a row VOID (anchor absent) rather than silently green.
#
# WHAT THESE ROWS DO NOT COVER.  They are refusals only.  That the SHIPPING
# text is ACCEPTED is not tested here -- it is measured every time the
# generator runs at all, because main() calls check_reset_topology(text) on the
# emitted text before writing anything.  A regression that made the guard
# refuse the real design would fail the build, loudly, not this selftest.
#
# ATTRIBUTION.  The `guard_alone` accounting in the table above is about the
# INJECTED TCL guards and says nothing about this function.  The attribution
# control for these rows was run separately and is recorded in
# docs/debugging/2026-08-30_resetland-orphaned-reset-work.md: with
# check_reset_topology deleted, all seven dangerous mutations reach `wrote
# build_fk33_pcieep.tcl` with rc 0, so no pre-existing guard in this file
# catches any of them.
_RESET_TEETH = [
    # (tag, must_refuse, description, old, new)
    ("T1", True, "ext_reset_in re-rooted onto a free-running reset: the "
     "engine's reset becomes a SIBLING of the slave's",
     "[get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]",
     "[get_bd_pins fk33_aux_0/aux_aresetn] [get_bd_pins core_reset/ext_reset_in]"),

    ("T2", True, "aux_reset_in driven: proc_sys_reset ORs it into "
     "peripheral_aresetn, so the engine gains a reset the slave lacks",
     "[get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]",
     "[get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]\n"
     "connect_bd_net [get_bd_pins fk33_aux_0/aux_aresetn] "
     "[get_bd_pins core_reset/aux_reset_in]"),

    ("T3", True, "core_aresetn driven straight from an unrelated net",
     "[get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins eng/core_aresetn]",
     "[get_bd_pins fk33_aux_0/aux_aresetn] [get_bd_pins eng/core_aresetn]"),

    ("T4", True, "one engine master port reset from a different net, so the "
     "28 slaves no longer share one reset",
     "[get_bd_pins xdma/axi_aresetn] [get_bd_pins hbm/AXI_01_ARESET_N]",
     "[get_bd_pins hbm_reset/peripheral_aresetn] [get_bd_pins hbm/AXI_01_ARESET_N]"),

    ("T5", True, "core_reset is no longer a proc_sys_reset, so "
     "peripheral_aresetn is no longer GENERATED from ext_reset_in",
     "xilinx.com:ip:proc_sys_reset:5.0 core_reset",
     "xilinx.com:ip:util_vector_logic:2.0 core_reset"),

    ("T6", True, "the core_aresetn connection deleted entirely",
     "connect_bd_net [get_bd_pins core_reset/peripheral_aresetn] "
     "[get_bd_pins eng/core_aresetn]",
     "# deleted"),

    ("T7", True, "dcm_locked moved onto an MMCM whose own reset is "
     "free-running: an unlock resets the engine and not the slave",
     "[get_bd_pins clk_wiz_0/locked]   [get_bd_pins core_reset/dcm_locked]",
     "[get_bd_pins clk_wiz_core/locked] [get_bd_pins core_reset/dcm_locked]\n"
     "connect_bd_net [get_bd_pins fk33_aux_0/aux_aresetn] "
     "[get_bd_pins clk_wiz_core/resetn]"),

    # MUST NOT REFUSE.  A checker that rejects a strictly safer topology is a
    # checker someone deletes, and then the property has no guard at all.
    ("T8", False, "SAFE: core_aresetn wired straight to the slaves' own reset "
     "net, which is stronger than the shipping descendancy",
     "[get_bd_pins core_reset/peripheral_aresetn] [get_bd_pins eng/core_aresetn]",
     "[get_bd_pins xdma/axi_aresetn] [get_bd_pins eng/core_aresetn]"),

    ("T9", False, "SAFE: the same net written sink-first.  connect_bd_net is "
     "order-independent and so must this scan be",
     "[get_bd_pins xdma/axi_aresetn]   [get_bd_pins core_reset/ext_reset_in]",
     "[get_bd_pins core_reset/ext_reset_in] [get_bd_pins xdma/axi_aresetn]"),
]


def reset_topology_teeth():
    """Show that check_reset_topology discriminates.  Called from selftest()."""
    import io
    import contextlib

    base = _eng_block() + (
        "\n# from build_fk33_i2cprobe.tcl, the reset of the MMCM that feeds\n"
        "# core_reset/dcm_locked:\n"
        "connect_bd_net [get_bd_pins xdma/axi_aresetn] "
        "[get_bd_pins clk_wiz_0/resetn]\n")

    print()
    print("RESET-TOPOLOGY TEETH (check_reset_topology)")
    print("%-4s %-9s %s" % ("ROW", "RESULT", "MUTATION"))
    print("-" * 62)
    bad = []
    for tag, must_refuse, desc, old, new in _RESET_TEETH:
        n = base.count(old)
        if n != 1:
            print("%-4s %-9s ANCHOR x%d -- TESTED NOTHING -- %s"
                  % (tag, "VOID", n, desc))
            bad.append("%s: anchor %r occurs %d times in ENGINE_BLOCK, not "
                       "once.  The emitter moved; this row tested nothing."
                       % (tag, old[:48], n))
            continue
        text = base.replace(old, new)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                check_reset_topology(text)
            refused = False
        except SystemExit:
            refused = True
        ok = (refused == must_refuse)
        print("%-4s %-9s %s%s" % (tag, "REFUSED" if refused else "accepted",
                                  desc, "" if ok else "   <== WRONG"))
        if not ok:
            bad.append("%s: expected %s, got %s -- %s"
                       % (tag, "a refusal" if must_refuse else "acceptance",
                          "a refusal" if refused else "acceptance", desc))

    # The base itself must be accepted, or every refusal above is meaningless:
    # a checker that refuses everything discriminates nothing.
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            check_reset_topology(base)
        print("%-4s %-9s %s" % ("T0", "accepted", "the UNMUTATED emitted "
                                "engine wiring (the control: a checker that "
                                "refuses everything measures nothing)"))
    except SystemExit as e:
        print("%-4s %-9s %s" % ("T0", "REFUSED", "the UNMUTATED emitted engine "
                                "wiring   <== WRONG"))
        bad.append("T0: the guard refuses the shipping topology: %s" % e)

    print("-" * 62)
    if bad:
        for b in bad:
            print("FAIL " + b)
        sys.exit("SELFTEST FAIL: the reset-topology guard does not "
                 "discriminate as claimed.")


# ---------------------------------------------------------------------------
# TEETH FOR THE ADDRESS MAP (TRACK SEAMMAP, 2026-08-30)
# ---------------------------------------------------------------------------
# THE BASE IS THE EMITTED FILE, not a constructed fragment.  selftest() already
# requires build_fk33_pcieep.tcl to exist and reads it, so these rows mutate
# the artefact a build would actually consume.  A row whose anchor stops
# occurring exactly once goes VOID rather than silently green.
#
# THREE ARMS, BECAUSE A KILL DOES NOT SETTLE IT.  For every mutant, three
# independent checks are run and reported separately:
#
#   OLD    the two address literals that were in this file BEFORE this track
#          (`assign_bd_address -offset 0x00004000` and `... 0x0000B000`).
#          These are the attribution control: anything OLD also catches was
#          already covered and this track's work bought nothing for it.
#   NEEDLE this track's own literal needles for the seam.
#   MAP    check_bar_map(), the parsed overlap/containment/alignment check.
#
# A row where only MAP fires is a row that justifies check_bar_map's
# existence.  A row where only OLD fires is one this track should not claim.
_ADDR_TEETH_ENG_ONLY = {"A5"}

_ADDR_OLD_NEEDLES = [
    "assign_bd_address -offset 0x00004000",
    "assign_bd_address -offset 0x0000B000",
]
# CONFIGURATION-DEPENDENT, and it has to be.  The third needle pins how the
# seam's `d_err` is DRIVEN, and the two configurations drive it from different
# places:
#
#   engine-only   a constant:  [get_bd_pins seam_h1/dout] [get_bd_pins .../d_err]
#   FK33_CARD=1   the card:    [get_bd_pins .../d_err] [get_bd_pins card/err]
#
# MEASURED 2026-09-11: as a flat list pinned to the engine-only spelling, the
# third needle was MISSING from every card-on file, so `_arm_new` reported a
# missing needle for EVERY row including the unmutated control.  The whole
# NEEDLE column read `yes` unconditionally, A0 refused the shipping map, three
# legal relocations (A9/A10/A11) were reported as wrongly refused, and
# `MAP ALONE=0` was an ARTIFACT of that: a needle arm that refuses everything
# cannot leave any kill attributable to check_bar_map alone.  The selftest was
# not detecting a defect in the address map, it was reporting its own.
#
# This is the project's own "a guard that never discriminates is decoration"
# rule, arriving as a guard that discriminates against reality instead.
def _addr_new_needles(text):
    """The seam needles for the configuration `text` is in."""
    card_on = "create_bd_cell -type module -reference fk33_card" in text
    if card_on:
        derr = "[get_bd_pins %s/d_err] [get_bd_pins card/err]" % SEAM_CELL
    else:
        derr = "[get_bd_pins seam_h1/dout] [get_bd_pins %s/d_err]" % SEAM_CELL
    return [
        "assign_bd_address -offset 0x%08X" % SEAM_BASE,
        "create_bd_cell -type module -reference fk33_seam %s" % SEAM_CELL,
        derr,
    ]

_ADDR_TEETH = [
    # (tag, must_refuse, description, old, new)
    ("A1", True, "the seam moved onto the thermal block at 0xB000",
     "assign_bd_address -offset 0x0000E000 -range 4K",
     "assign_bd_address -offset 0x0000B000 -range 4K"),

    ("A2", True, "the seam moved past the end of the 128 KB BAR",
     "assign_bd_address -offset 0x0000E000 -range 4K",
     "assign_bd_address -offset 0x00020000 -range 4K"),

    ("A3", True, "the seam at a base that is not 4 KB aligned, which aliases "
     "a 12-bit slave onto itself",
     "assign_bd_address -offset 0x0000E000 -range 4K",
     "assign_bd_address -offset 0x0000E800 -range 4K"),

    ("A4", True, "the seam's address assignment deleted entirely",
     "assign_bd_address -offset 0x0000E000 -range 4K "
     "[get_bd_addr_segs {fk33_seam_0/s_axi/reg0}]",
     "# deleted"),

    # THE ONE THAT ACTUALLY HAPPENED.  ENGINE_ADDR's own comment records the
    # engine being put at 0x11000, colliding with the second 4 KB of the 8 KB
    # scratch at 0x10000, and being caught by a 90-second --bd-only Vivado run
    # with BD 41-1075.  Nothing in this file could see it before.
    ("A5", True, "the engine control map back at 0x11000, inside the 8 KB "
     "scratch -- the collision that cost a --bd-only run",
     "assign_bd_address -offset 0x00012000 -range 4K",
     "assign_bd_address -offset 0x00011000 -range 4K"),

    # A6's EXPECTATION FOLLOWS THE CONFIGURATION, and it is the only row here
    # that has to.  The 16 KB scratch swallows 0x12000 and 0x13000 -- the
    # engine's two control pages -- so with FK33_ENG=0 there is nothing in that
    # window and ACCEPTANCE is the correct verdict, not a miss.  Hardcoding
    # `True` made this row report "<== WRONG" on an engine-less build that is
    # behaving exactly as it should, which is the same defect as the SAXI_30/31
    # check that reported bad=2 on a correct card build.
    #
    # It is not skipped, because the grown scratch still must not collide with
    # anything that IS mapped in this configuration (the seam at 0xE000, the
    # thermal pages, fk33_id); the row keeps grading that, and A5 self-voids on
    # its missing anchor rather than pretending to test it.
    # A5 mutates `assign_bd_address -offset 0x00012000`, the engine's control
    # page.  FK33_ENG=0 does not emit it, so the row is NOT APPLICABLE there
    # rather than VOID; see the loop in addr_map_teeth().
    ("A6", ENG_ON, "the scratch grown to 16 KB, swallowing both engine pages "
     "without either of them moving"
     + ("" if ENG_ON else " -- SAFE with FK33_ENG=0: those two pages are not "
        "mapped, so nothing is swallowed"),
     "assign_bd_address -offset 0x00010000  -range 8K",
     "assign_bd_address -offset 0x00010000  -range 16K"),

    ("A7", True, "a new peripheral mapped whose address space nobody declared",
     "assign_bd_address -offset 0x0000E000 -range 4K "
     "[get_bd_addr_segs {fk33_seam_0/s_axi/reg0}]",
     "assign_bd_address -offset 0x0000E000 -range 4K "
     "[get_bd_addr_segs {fk33_seam_0/s_axi/reg0}]\n"
     "assign_bd_address -offset 0x0000F000 -range 4K "
     "[get_bd_addr_segs {some_new_block/S_AXI/Reg}]"),

    ("A8", True, "the two arms of the HBM if/else disagreeing: SAXI_16/MEM16 "
     "at a different offset in the else branch",
     "assign_bd_address -offset 0x100000000 -range 256M "
     "[get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]\n\n    exclude_seg_if",
     "assign_bd_address -offset 0x180000000 -range 256M "
     "[get_bd_addr_segs {hbm/SAXI_16/HBM_MEM16 }]\n\n    exclude_seg_if"),

    # MUST NOT REFUSE.  A checker that rejects every rearrangement is a
    # checker that gets deleted, and then nothing guards the map.
    ("A9", False, "SAFE: the scratch relocated to another free, aligned, "
     "in-BAR hole at 0x18000",
     "assign_bd_address -offset 0x00010000  -range 8K",
     "assign_bd_address -offset 0x00018000  -range 8K"),

    ("A10", False, "SAFE: the thermal control page written before the peak "
     "page.  assign_bd_address order carries no meaning and neither may this "
     "scan",
     "assign_bd_address -offset 0x0000C000 -range 4K "
     "[get_bd_addr_segs {fk33_thermp/S_AXI/Reg}]\n"
     "assign_bd_address -offset 0x0000D000 -range 4K "
     "[get_bd_addr_segs {fk33_thermc/S_AXI/Reg}]",
     "assign_bd_address -offset 0x0000D000 -range 4K "
     "[get_bd_addr_segs {fk33_thermc/S_AXI/Reg}]\n"
     "assign_bd_address -offset 0x0000C000 -range 4K "
     "[get_bd_addr_segs {fk33_thermp/S_AXI/Reg}]"),

    # THE RESOLUTION FLOOR.  REPORTED UNDER ITS OWN NAME AND NOT DISCARDED.
    # fk33_id moved from 0xA000 to the free hole at 0xF000 is legal on every
    # rule this check has -- aligned, unique, in the BAR -- and it is WRONG:
    # hw/fk33/host/fk33_regs.h hardcodes FK33_ID_BASE 0x0000A000, so the host
    # would read the empty 0xA000 page and print 0x00000000, which that
    # header's own comment says means "the fabric is in reset".  Nothing in
    # this generator cross-checks fk33_regs.h's non-thermal bases; only
    # THERM_* are pinned.  MAP CANNOT AND SHOULD NOT CATCH THIS.  The fix is
    # a fk33_regs.h cross-check, not a wider address rule.
    ("A11", False, "FLOOR: fk33_id relocated to the free 0xF000 page. Legal, "
     "unique, aligned -- and host/fk33_regs.h still says 0xA000",
     "assign_bd_address -offset 0x0000A000  -range 4K",
     "assign_bd_address -offset 0x0000F000  -range 4K"),
]


def addr_map_teeth():
    """Show that check_bar_map discriminates, and attribute every kill."""
    import io
    import contextlib

    base = assemble_script()

    def _arm_old(t):
        return [n for n in _ADDR_OLD_NEEDLES if n not in t]

    def _arm_new(t):
        return [n for n in _addr_new_needles(t) if n not in t]

    def _arm_map(t):
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                check_bar_map(t)
            return False
        except SystemExit:
            return True

    print()
    print("ADDRESS-MAP TEETH (check_bar_map), with the attribution control")
    print("%-4s %-9s %-4s %-6s %-4s %s"
          % ("ROW", "VERDICT", "OLD", "NEEDLE", "MAP", "MUTATION"))
    print("-" * 100)
    bad, map_alone, both, neither = [], 0, 0, 0
    for tag, must_refuse, desc, old, new in _ADDR_TEETH:
        # A ROW WHOSE ANCHOR CANNOT EXIST IN THIS CONFIGURATION IS NOT DRIFT.
        # A5 mutates the engine's own control page, which FK33_ENG=0 does not
        # map at all.  The VOID-on-missing-anchor rule below is right in
        # general -- a vanished anchor usually means the emitter moved and the
        # row silently tested nothing -- but applying it here reports a defect
        # on a build that is correct, and VOID counts as a failure, so an
        # engine-less selftest could never pass.  Named explicitly rather than
        # made conditional on the anchor being absent: "skip when the anchor is
        # missing" would swallow exactly the drift the rule exists to catch.
        if tag in _ADDR_TEETH_ENG_ONLY and not ENG_ON:
            print("%-4s %-9s NOT APPLICABLE (FK33_ENG=0: the engine's control "
                  "pages are not mapped) -- %s" % (tag, "SKIP", desc))
            continue
        n = base.count(old)
        if n != 1:
            print("%-4s %-9s ANCHOR x%d -- TESTED NOTHING -- %s"
                  % (tag, "VOID", n, desc))
            bad.append("%s: anchor %r occurs %d times in the emitted script, "
                       "not once. The emitter moved; this row tested nothing."
                       % (tag, old[:56], n))
            continue
        t = base.replace(old, new)
        hit_old = bool(_arm_old(t))
        hit_new = bool(_arm_new(t))
        hit_map = _arm_map(t)
        refused = hit_old or hit_new or hit_map
        ok = (refused == must_refuse)
        if must_refuse:
            if hit_map and not (hit_old or hit_new):
                map_alone += 1
            elif hit_map:
                both += 1
            elif refused:
                neither += 1
        print("%-4s %-9s %-4s %-6s %-4s %s%s"
              % (tag, "REFUSED" if refused else "accepted",
                 "yes" if hit_old else "-", "yes" if hit_new else "-",
                 "yes" if hit_map else "-", desc,
                 "" if ok else "   <== WRONG"))
        if not ok:
            bad.append("%s: expected %s, got %s -- %s"
                       % (tag, "a refusal" if must_refuse else "acceptance",
                          "a refusal" if refused else "acceptance", desc))

    # The control.  A checker that refuses everything measures nothing.
    if _arm_map(base) or _arm_old(base) or _arm_new(base):
        print("%-4s %-9s the UNMUTATED emitted script   <== WRONG"
              % ("A0", "REFUSED"))
        bad.append("A0: the guards refuse the shipping address map.")
    else:
        print("%-4s %-9s %-4s %-6s %-4s %s"
              % ("A0", "accepted", "-", "-", "-",
                 "the UNMUTATED emitted script (the control)"))
    print("-" * 100)
    print("MAP ALONE=%d  both=%d  NEITHER=%d" % (map_alone, both, neither))
    if map_alone == 0:
        bad.append("no mutation is caught by check_bar_map alone, so it is "
                   "not paying for its own maintenance: every kill it claims "
                   "was already claimed by a literal needle.")
    if bad:
        for b in bad:
            print("FAIL " + b)
        sys.exit("SELFTEST FAIL: the address-map guard does not discriminate "
                 "as claimed.")


def seam_tieoff_teeth():
    """Show that check_seam_tieoff discriminates in BOTH directions.

    This guard is the one that costs the most if it is decoration, because
    both of the states it refuses are SILENT: a tie-off outliving subsystem D
    gives a bitstream that refuses every GO with a real transformer behind it,
    and a tie-off removed before subsystem D arrives gives a bitstream whose
    documented poll loop hangs. Neither turns anything red anywhere else.
    """
    import io
    import contextlib

    base = assemble_script()
    # CONFIGURATION, NOT A DEFECT.  The tie-off this test grades exists only
    # in the ENGINE-ONLY build.  With FK33_CARD=1 the seam's d_err is driven
    # by `card/err` and gen_pcieep.py deliberately emits no tie at all -- the
    # emitted file says so in as many words ("d_err is driven by card/err
    # (FK33_CARD): no tie-off").  Grading a card-on file against the
    # engine-only anchor produced `SELFTEST VOID: the d_err tie anchor occurs
    # 0 times`, which read as a broken selftest and turned the shared gate red
    # for as long as the card was the build target.
    #
    # Say NOT APPLICABLE and skip, rather than either failing (which blames
    # the wrong thing) or passing (which would be a guard reporting a verdict
    # on something it never looked at).  The anchor stays MANDATORY on an
    # engine-only file, which is the configuration where its absence is a real
    # defect.
    if "create_bd_cell -type module -reference fk33_card" in base:
        # CARD-ON HAS ITS OWN INVARIANT, SO GRADE THAT INSTEAD OF SKIPPING.
        # The engine-only anchor does not exist here (card/err drives d_err),
        # but the SAFETY PROPERTY is the same and is still testable: a tie-off
        # re-appearing beside a present subsystem D gives a bitstream that
        # answers ERR to every GO with a real transformer behind it.
        # "NOT APPLICABLE" would leave that ungraded in the only configuration
        # currently being built.
        drv = ("connect_bd_net [get_bd_pins %s/d_err] [get_bd_pins %s/err]"
               % (SEAM_CELL, CARD_CELL))
        if base.count(drv) != 1:
            sys.exit("SELFTEST VOID: the card-on d_err driver anchor occurs "
                     "%d times, not once." % base.count(drv))
        tie = ("connect_bd_net [get_bd_pins seam_h1/dout] [get_bd_pins "
               "%s/d_err]" % SEAM_CELL)

        def _verdict(t):
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    check_seam_tieoff(t)
                return False
            except SystemExit:
                return True

        print()
        print("SEAM d_err TIE-OFF TEETH (card-on invariant)")
        print("%-4s %-9s %s" % ("ROW", "VERDICT", "MUTATION"))
        print("-" * 78)
        rows = [
            ("C0", False, "the UNMUTATED card-on script (the control)", base),
            ("C1", True,
             "the tie-off re-added beside a present subsystem D",
             base.replace(drv, tie)),
        ]
        bad = []
        for tag, must_refuse, desc, txt in rows:
            got = _verdict(txt)
            ok = (got == must_refuse)
            print("%-4s %-9s %s%s" % (tag, "REFUSED" if got else "accepted",
                                      desc, "" if ok else "   <== WRONG"))
            if not ok:
                bad.append("%s: expected %s, got %s"
                           % (tag, "a refusal" if must_refuse else "acceptance",
                              "a refusal" if got else "acceptance"))
        print("-" * 78)
        if bad:
            for b in bad:
                print("FAIL " + b)
            sys.exit("SELFTEST FAIL: the card-on d_err invariant is not "
                     "enforced as claimed.")
        return

    tie = "[get_bd_pins seam_h1/dout] [get_bd_pins %s/d_err]" % SEAM_CELL
    if base.count(tie) != 1:
        sys.exit("SELFTEST VOID: the d_err tie anchor occurs %d times in the "
                 "emitted script, not once." % base.count(tie))
    no_tie = base.replace(tie, "[get_bd_pins seam_z1/dout] "
                                "[get_bd_pins %s/d_err]" % SEAM_CELL)
    no_d = "entity fk33_engine is\n"
    # A REAL INSTANTIATION.  This used to be a COMMENT:
    #
    #     with_d = no_d + "  -- u_top : entity work.llama_top\n"
    #
    # which is defect 1 written into the guard's own teeth test.  The detector
    # matched `\bllama_top\b` anywhere, so a comment satisfied it, and this
    # selftest was built to agree -- it asserted that a commented-out
    # instantiation MEANS subsystem D is present.  Both were wrong in the same
    # direction, so the selftest passed for the entire period the pcieep build
    # was dead (3a145fd to 2026-09-03).  Fixing the detector is what finally
    # made them disagree.
    #
    # A teeth test whose mutant is built from the same misconception as the
    # check cannot detect that misconception.  Construct the mutant from the
    # THING (a real instantiation), never from the check's notion of it.
    with_d = no_d + "  u_top : entity work.llama_top\n    generic map (\n"
    # And the state that actually ships: comment references only.  This is
    # verbatim the shape `hw/fk33/rtl/fk33_engine.vhd` has carried since
    # 3a145fd, and it is what the old detector false-positived on.
    cmt_d = (no_d
             + "  -- see rtl/llama_top.vhd:3197-3226 for the D-facing "
               "contract\n"
             + "  -- llama_top drives d_x_we/d_x_waddr in that order\n")

    rows = [
        ("S1", False, base,   no_d,   "SHIPPING: tie-off present, "
         "fk33_engine has no llama_top"),
        ("S2", True,  base,   with_d, "the tie-off survives into a build "
         "whose engine DOES instantiate llama_top: every GO refused with a "
         "real transformer behind the seam"),
        ("S3", True,  no_tie, no_d,   "the tie-off removed before subsystem D "
         "exists: d_err low, GO sets `running` forever, a (done | err) poll "
         "hangs"),
        ("S4", False, no_tie, with_d, "N3's future state: no tie-off and a "
         "real llama_top. Must be ACCEPTED or this guard blocks the work it "
         "exists to hand over to"),
        # --- DEFECT 1's REGRESSION, added 2026-09-03.  Neither row existed
        # while the build was dead, which is precisely why it stayed dead.
        ("S5", False, base,   cmt_d,  "SHIPPING TODAY: tie-off present and "
         "fk33_engine mentions llama_top only in COMMENTS. A comment is not "
         "an instantiation; refusing this aborted every pcieep build from "
         "3a145fd until 2026-09-03"),
        ("S6", True,  no_tie, cmt_d,  "no tie-off, and llama_top only in "
         "comments: subsystem D is NOT there, so the seam's D face is driven "
         "by nothing and a (done | err) poll hangs. Same refusal as S3, "
         "reached through the comment path"),
    ]
    # ATTRIBUTION CONTROL, MEASURED 2026-09-03.  The pre-fix detector
    # (`re.search(r"\bllama_top\b", eng_src)`, no comment stripping) was run
    # against all six rows:
    #
    #   S1 accepted   S2 REFUSED   S3 REFUSED   S4 accepted   -- all CORRECT
    #   S5 REFUSED  <== WRONG      S6 accepted <== WRONG
    #
    # So the four ORIGINAL rows are insensitive to the defect in both
    # directions: they pass identically with the broken detector and with the
    # fixed one, and would have passed every day the build was dead.  S5 and
    # S6 are the whole of the discrimination.  Without this control the fix
    # would have been credited to a suite that cannot see it.
    print()
    print("SEAM TIE-OFF TEETH (check_seam_tieoff)")
    print("%-4s %-9s %s" % ("ROW", "RESULT", "STATE"))
    print("-" * 100)
    bad = []
    for tag, must_refuse, txt, eng, desc in rows:
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                check_seam_tieoff(txt, eng_src=eng)
            refused = False
        except SystemExit:
            refused = True
        ok = (refused == must_refuse)
        print("%-4s %-9s %s%s" % (tag, "REFUSED" if refused else "accepted",
                                  desc, "" if ok else "   <== WRONG"))
        if not ok:
            bad.append("%s: expected %s, got %s"
                       % (tag, "a refusal" if must_refuse else "acceptance",
                          "a refusal" if refused else "acceptance"))
    print("-" * 100)
    if bad:
        for b in bad:
            print("FAIL " + b)
        sys.exit("SELFTEST FAIL: the seam tie-off guard does not discriminate "
                 "as claimed.")


def assemble_script():
    """Build the emitted Tcl for the CURRENT configuration and return it.

    EXTRACTED FROM main() SO --selftest CAN GRADE WHAT THIS INVOCATION WOULD
    EMIT, rather than whatever configuration last wrote build_fk33_pcieep.tcl.
    The rows' expectations come from CARD_ON/ENG_ON, i.e. the ENVIRONMENT, and
    the text used to come from DISK -- so a selftest run after a FK33_CARD=1
    build graded a card-on file against card-off expectations and reported four
    seam rows failing in BOTH directions.  MEASURED 2026-09-17: that took the
    shared gate red on sim:runguard while a build was in flight, and the same
    coupling is what this file's own note called out as flakiness -- PASS, then
    FAIL, then PASS, with no code change and only regenerations in between.

    Generating in memory removes the coupling rather than detecting it: there
    is no longer a second configuration for the verdict to be about.
    """
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

    # ---- BUILD-HANG.  Each of these fails SILENTLY: a build with an
    # unbounded wait looks exactly like a long place-and-route, and a build
    # with no post-launch assertion looks exactly like a slow queue.  The one
    # that survived cost 27.6 hours.
    if "wait_on_run synth_1\n" in text or "wait_on_run impl_1\n" in text:
        sys.exit("ABORT: an UNBOUNDED wait_on_run survived into the build "
                 "script. MEASURED 2026-08-29: an unbounded wait blocked for "
                 "27.6 hours on a run that never started, with 7 minutes of "
                 "CPU across the whole period.")
    for need, why in (
        ("proc fk33_assert_run_started",
         "the post-launch_runs assertion that the run directory exists is "
         "gone. launch_runs REPORTS SUCCESS when the run never starts"),
        ("proc fk33_assert_run_done",
         "the post-wait progress check is gone. wait_on_run -timeout RETURNS "
         "rc 0 on expiry rather than raising, so without this check the bound "
         "bounds nothing"),
        ("fk33_assert_run_started synth_1",
         "synthesis is launched without the run-started assertion"),
        ("fk33_assert_run_started impl_1",
         "implementation is launched without the run-started assertion"),
        ("wait_on_run -timeout $FK33_SYNTH_MAX_MIN synth_1",
         "the synthesis wait is not bounded"),
        ("wait_on_run -timeout $FK33_IMPL_MAX_MIN impl_1",
         "the implementation wait is not bounded"),
        ("fk33_assert_run_done synth_1 $FK33_SYNTH_MAX_MIN",
         "nothing converts an expired synthesis bound into a stop"),
        ("fk33_assert_run_done impl_1 $FK33_IMPL_MAX_MIN",
         "nothing converts an expired implementation bound into a stop"),
        # The marker file is the part that is easy to get wrong in the safe-
        # looking direction: runme.log exists only AFTER the run starts
        # executing, so a guard testing for it would refuse every correct
        # launch.  MEASURED on a real trivial synthesis run.
        ("file join $dir runme.sh",
         "the run-started assertion no longer tests for runme.sh. runme.sh is "
         "written SYNCHRONOUSLY by launch_runs; runme.log and "
         ".vivado.begin.rst are not, and testing for either would false-fire "
         "on every healthy launch"),
    ):
        if need not in text:
            sys.exit(f"ABORT: {why} ({need!r} missing).")
    for var in ("FK33_SYNTH_MAX_MIN", "FK33_IMPL_MAX_MIN"):
        # Both the DEFAULT and the ENVIRONMENT OVERRIDE have to go through
        # fk33_bound.  Found by mutation: routing the default through it and
        # letting $::env past unchecked leaves the bound settable to -1 from
        # outside, which is Vivado's "no limit" and reinstates the hang.
        if not re.search(r"set %s\s+\[fk33_bound %s\s+\$::env\(%s\)\]"
                         % (var, var, var), text):
            sys.exit(f"ABORT: the {var} environment override does not go "
                     "through fk33_bound, so a non-positive value from the "
                     "environment would restore the unbounded wait.")
        m = re.search(r"set %s\s+\[fk33_bound %s\s+(-?\d+)\]" % (var, var), text)
        if not m:
            sys.exit(f"ABORT: {var} is not set through fk33_bound, so a "
                     "non-positive limit would silently restore the unbounded "
                     "wait (Vivado reads -1 as 'no limit').")
        if int(m.group(1)) <= 0:
            sys.exit(f"ABORT: {var} is {m.group(1)}. wait_on_run -timeout "
                     "treats any non-positive value as NO LIMIT.")
    if "runme.log]" in text or "file exists [file join $dir runme.log" in text:
        sys.exit("ABORT: the run-started assertion tests for runme.log, which "
                 "does not exist yet when launch_runs returns. That guard "
                 "would refuse every correct launch.")
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

    # The one property that decides whether STRAY-NEXTJOB is reachable.  Run
    # on the EMITTED text rather than on the tree's build_fk33_pcieep.tcl, so a
    # change made here in the generator cannot pass by virtue of the checked-in
    # artefact still being the old one.
    check_reset_topology(text)

    # ---- the host seam.  Each of these is a way this build can come out with
    # a seam that is present, builds, closes timing, and is either unreachable
    # or lying about what is behind it.
    for need, why in (
        ("create_bd_cell -type module -reference fk33_seam %s" % SEAM_CELL,
         "the host seam is not instantiated, so board row N2's decision was "
         "not carried into the bitstream and server/fk33_seam.h still drives "
         "nothing"),
        ("add_files -norecurse %s" % SEAM_RTL,
         "rtl/fk33_seam.vhd is not added to the project, so the module "
         "reference above cannot resolve"),
        ("assign_bd_address -offset 0x%08X" % SEAM_BASE,
         "the seam is not on the PCIe BAR at %#x, so the host cannot reach it"
         % SEAM_BASE),
        ("[get_bd_pins core_reset/peripheral_reset] [get_bd_pins %s/rst]"
         % SEAM_CELL,
         "the seam's ACTIVE-HIGH reset is not driven from proc_sys_reset's "
         "active-high output. Wired to the active-low net it would sit in "
         "reset forever and answer 0 to every read, which from the host is "
         "indistinguishable from an unmapped BAR"),
        # ONE REQUIREMENT, TWO CONFIGURATIONS.  Without the card, d_err MUST be
        # tied high, because nothing else drives it and a GO would hang.  With
        # the card, it must be driven BY THE CARD and must NOT be tied, because
        # a tie-off would answer ERR to every GO with a real transformer behind
        # the seam.  Making the entry conditional keeps a real requirement in
        # both cases; deleting it for FK33_CARD would have left the new path
        # unguarded, which is how the guard for D's absence came to pass green
        # for the whole time the build was dead.
        # The card pin is taken from SEAM_FROM_CARD rather than written out:
        # d_err maps to the card's `err`, and hardcoding `d_err` here made this
        # guard demand a pin that does not exist.
        (("[get_bd_pins %s/d_err] [get_bd_pins %s/%s]"
          % (SEAM_CELL, CARD_CELL, dict(SEAM_FROM_CARD)["d_err"])) if CARD_ON else
         ("[get_bd_pins seam_h1/dout] [get_bd_pins %s/d_err]" % SEAM_CELL),
         ("the seam's d_err is not driven by the card, so with subsystem D "
          "present the seam's D face floats") if CARD_ON else
         ("the seam's d_err is no longer tied HIGH. With no subsystem D in "
          "this design and d_err low, a GO sets `running` and nothing ever "
          "clears it: a host polling (done | err) hangs forever")),
        ("CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {%d}" % SEAM_NO_D_CODE,
         "the no-subsystem-D marker code is gone from ERR_INFO[3:0], so a "
         "refusal caused by D's absence would be indistinguishable from a "
         "real descriptor fault"),
        ("FK33_SEAM FAIL: $g is",
         "the CAPS read-back is gone, so a generic renamed in "
         "rtl/fk33_seam.vhd would leave this build publishing a model "
         "geometry it does not have"),
    ):
        if need not in text:
            sys.exit(f"ABORT: {why} ({need!r} missing).")
    check_bar_map(text)
    check_seam_tieoff(text)

    return text


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
    if not os.path.exists(SEAM_RTL):
        sys.exit(f"ABORT: the host seam RTL not found: {SEAM_RTL}\n"
                 "Board row N2 was resolved in favour of building this block, "
                 "so a build without it decodes nothing at "
                 f"{SEAM_BASE:#x} and server/fk33_seam.h drives nothing.")

    # ---- THE SEAM CONTRACT EXISTS IN THREE COPIES AND THEY ARE CHECKED
    # ---- AGAINST EACH OTHER, NOT TRUSTED.
    #
    # rtl/fk33_seam.vhd is the gateware, server/fk33_seam.h is the host, and
    # this generator is the only thing that can put the two at the same
    # address.  A drift between any pair is silent in exactly the way the
    # thermal base drift would have been: the host reads a different
    # peripheral and prints a plausible number.  Same guard, same reason.
    seam_src = open(SEAM_RTL).read()
    m = re.search(r'constant\s+ID_MAGIC\s*:\s*std_logic_vector\(31 downto 0\)'
                  r'\s*:=\s*x"([0-9A-Fa-f]{8})"', seam_src)
    if not m:
        sys.exit("ABORT: rtl/fk33_seam.vhd no longer declares ID_MAGIC as an "
                 "8-digit hex constant, so the seam's identity word cannot be "
                 "compared with the host's.")
    if int(m.group(1), 16) != SEAM_MAGIC:
        sys.exit("ABORT: rtl/fk33_seam.vhd ID_MAGIC is 0x%s but gen_pcieep.py "
                 "SEAM_MAGIC is 0x%08X. A host probing %#x for the seam would "
                 "not recognise the block that answers."
                 % (m.group(1).upper(), SEAM_MAGIC, SEAM_BASE))
    # The four CAPS generics must DEFAULT to 0.  SEAM_BLOCK deliberately does
    # not override them, so the default is what the bitstream publishes, and a
    # non-zero default would make a D-less build claim a model geometry.
    for gname in ("CAPS_VOCAB", "CAPS_EMBD", "CAPS_LAYER", "CAPS_CTX"):
        m = re.search(r"%s\s*:\s*natural\s*:=\s*(\d+)" % gname, seam_src)
        if not m:
            sys.exit(f"ABORT: {gname} is no longer a natural generic of "
                     "fk33_seam with a default, so a build with no subsystem "
                     "D behind the seam could publish a model geometry it "
                     "does not have.")
        if int(m.group(1)) != 0:
            sys.exit(f"ABORT: rtl/fk33_seam.vhd defaults {gname} to "
                     f"{m.group(1)}, not 0. There is no subsystem D in this "
                     "design and the seam must not report a model that is "
                     "not there.")
    # The AXI-Lite slave must still decode exactly 12 address bits, or
    # SEAM_SPAN and the 4 KB alignment argument for SEAM_BASE are both wrong.
    if "s_axi_awaddr  : in  std_logic_vector(11 downto 0)" not in seam_src:
        sys.exit("ABORT: rtl/fk33_seam.vhd's AXI-Lite write address is no "
                 "longer 12 bits, so SEAM_SPAN = %#x and the 4 KB alignment "
                 "of SEAM_BASE = %#x no longer follow from anything."
                 % (SEAM_SPAN, SEAM_BASE))

    # host-side half.  server/fk33_seam.h is hand-written and compiled into
    # server/, so a base that drifts there does not fail to build: it reads a
    # different peripheral.  Identical treatment to host/fk33ctl.py below.
    seam_h = os.path.normpath(os.path.join(HERE, "..", "..", "server",
                                           "fk33_seam.h"))
    if os.path.exists(seam_h):
        h_src = open(seam_h).read()
        # Matched as a #define, not as a substring: the header keeps a
        # sentence saying what the macro USED to be called, and a loose
        # needle would refuse the very state it is asking for.
        if re.search(r"^#define\s+FK33_SEAM_BASE_PROPOSED\b", h_src, re.M):
            sys.exit("ABORT: server/fk33_seam.h still calls the base "
                     "FK33_SEAM_BASE_PROPOSED. It is no longer proposed -- "
                     "this generator assigns it at %#x -- and its own comment "
                     "says the name changes when `grep 0xE000 "
                     "gen_pcieep.py` returns a line. Leaving the name would "
                     "make every caller read as though the address were still "
                     "a request." % SEAM_BASE)
        for name, value in (("FK33_SEAM_BASE", SEAM_BASE),
                            ("FK33_SEAM_SPAN", SEAM_SPAN),
                            ("FK33_SEAM_ID_MAGIC", SEAM_MAGIC)):
            m = re.search(r"^#define\s+%s\s+0x([0-9A-Fa-f]+)u?\s*$" % name,
                          h_src, re.M)
            if not m:
                sys.exit(f"ABORT: server/fk33_seam.h has no {name} constant, "
                         "so the host cannot find the block this build "
                         "decodes.")
            if int(m.group(1), 16) != value:
                sys.exit(f"ABORT: server/fk33_seam.h {name} is 0x{m.group(1)} "
                         f"but this build puts it at {value:#x}. The host "
                         "would read a different peripheral and print a "
                         "plausible number.")

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
        # --- the HBM divergence bound (added 2026-08-30, TRACK BITPREP, on
        # --- TRACK THERMFIX's handoff).  What these guard is not a threshold
        # --- but the REPLACEMENT for a threshold: hbm_valid used to demand the
        # --- two stacks read EQUAL, and because they are two separate dies it
        # --- halted an idle card 253 times in 1300 s and saturated the 8-bit
        # --- trip counter at 255.  The bound is what makes a stuck sensor still
        # --- detectable once equality is gone, so its ceiling and floor are
        # --- safety numbers in exactly the sense the rows above are.
        ("G_HBM_MAX_DELTA : natural := 20",
         "the HBM divergence bound is no longer 20 codes.  20 is DERIVED so a "
         "sensor stuck at the measured idle code 38 is flagged once the live "
         "stack reaches 58, which is 27 codes below the 85 halt point -- change "
         "it and the stuck-sensor hole the bound exists to close moves"),
        ("constant C_HBM_DELTA_CEILING : natural := 40 - G_HBM_MAX_DELTA;",
         "the SYNTHESIS-time ceiling on the HBM divergence bound is gone.  "
         "Above 40 a stuck sensor is no longer flagged before the live stack "
         "passes the halt point, and Vivado synthesis IGNORES "
         "`assert ... severity failure` (measured 2026-08-28), so a "
         "negative-natural constant is the only thing that stops it"),
        ("constant C_HBM_DELTA_FLOOR   : natural := G_HBM_MAX_DELTA - 2;",
         "the SYNTHESIS-time floor on the HBM divergence bound is gone.  "
         "Below 2 the bound degenerates towards the equality test it replaced, "
         "which is the defect that halted an idle card 255 times"),
        ("assert G_HBM_MAX_DELTA >= 2 and G_HBM_MAX_DELTA <= 40",
         "the elaboration-time bracket on the HBM divergence bound is gone"),
        ("assert G_HBM_MAX_DELTA + G_HBM_MIN_CODE < G_HBM_HALT_C",
         "the elaboration-time check that a stack parked at the plausibility "
         "floor diverges past the bound BEFORE the live stack reaches the halt "
         "threshold is gone, so the stuck-sensor case would not be covered"),
        # --- and the third defect THERMFIX found: hbm_hot, hbm_cool, warn and
        # --- cause all read stack 0 alone.  That was accidentally safe ONLY
        # --- because the equality precondition was there; with equality gone it
        # --- is a live hole, so the reduction over BOTH dies is guarded here.
        ("or hbm_max >= to_unsigned(G_HBM_HALT_C, hbm_max'length)",
         "the HBM halt no longer compares the MAX over both stacks.  These are "
         "two separate dies: a guard reading stack 0 alone cannot halt for a "
         "hot stack 1, and the equality precondition that used to make that "
         "accidentally safe has been removed"),
        ("and hbm_max <= to_unsigned(G_HBM_RESUME_C, hbm_max'length)",
         "the HBM resume no longer requires the MAX over both stacks to be "
         "cool, so the guard could release with one die still hot"),
        ("or syn_cat0(1) = '1' or syn_cat1(1) = '1'",
         "the HBM catastrophic-trip term no longer covers both stacks"),
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

    text = assemble_script()
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
    out, n_lane, n_sysref, n_hub, n_pblock = [], 0, 0, 0, 0
    for line in xdc.splitlines():
        drop_lane = any(f"{sig}[{i}]" in line
                        for i in range(4, 16)
                        for sig in ("pcie_rxp", "pcie_rxn",
                                    "pcie_txp", "pcie_txn"))
        drop_sysref = any(p in line for p in NO_PCIE_ONLY_PORTS)
        drop_hub = ("connect_debug_port dbg_hub/clk" in line
                    or "C_CLK_INPUT_FREQ_HZ" in line)
        drop_pblock = "pblock_bd_i" in line
        if drop_pblock:
            out.append("# [gen_pcieep] REMOVED, see fk33_pblock.xdc: " + line)
            n_pblock += 1
            continue
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
    # ---- pblock_bd_i.  THIS IS WHY THE FIRST ENGINE BUILD DID NOT ROUTE.
    #
    # The probe XDC inherits SQRL's shell floorplan: it assigns the WHOLE block
    # design, `[get_cells bd_i]`, to a pblock covering SLICE_X0Y0:X218Y50 plus
    # the rightmost 14 SLICE columns.  On the probe that was harmless -- there
    # was almost nothing in bd_i.  With subsystem A in it, TRACK SHELL's own
    # place log said, and nobody read it at the time:
    #
    #   WARNING: [Place 30-640] Pblock pblock_bd_i has 173441 Slice LUTs
    #   assigned to it, but only 115752 Slice LUTs are available in the area
    #   range defined.
    #   WARNING: [Place 30-640] This design requires 1585 DSPs but only 524
    #   compatible sites are available in Pblock 'pblock_bd_i'.
    #   WARNING: [Place 30-640] Pblock pblock_bd_i IS_SOFT property set.
    #   Ignoring capacity requirements for cells assigned to Pblock.
    #
    # IS_SOFT is why it did not fail outright: the placer crams what it can into
    # an area holding 67% of the assigned LUTs and 33% of the assigned DSPs and
    # spills the rest.  That spill is the 96%-in-the-bottom-half distribution
    # TRACK CONGEST measured, and it is why the router hit global congestion
    # level 7 and `ERROR: [Route 35-3]`.
    #
    # MEASURED, docs/debugging/2026-08-29_shell-pblock.md: deleting this pblock
    # and changing NOTHING else takes the placed core clock from WNS -0.759 to
    # +0.416 with zero failing endpoints, and congestion from 23 windows with a
    # level 7 to 5 windows with a worst of 6.
    #
    # Commented out rather than deleted, so `diff` against the probe XDC still
    # lines up and so the next reader sees what was there.
    if n_pblock != 13:
        sys.exit(f"ABORT: expected exactly 13 pblock_bd_i lines in "
                 f"{XDC_SRC} (create + add_cells + 6 resize + 5 already "
                 f"commented), found {n_pblock}. The probe's shell floorplan "
                 "has changed shape; re-read it before emitting an XDC that "
                 "may silently reintroduce a soft pblock that cannot hold the "
                 "engine.")

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
    if "--selftest" in sys.argv[1:]:
        selftest()
    else:
        main()
