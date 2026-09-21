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

 2. The HBM AXI clock goes 100 MHz -> 300 MHz.  First light drives
    AXI_00/16_ACLK from clk_out1 at 100 MHz, which is right for poking
    registers over JTAG and useless for bandwidth: 16 ports x 32 B x 100 MHz is
    51.2 GB/s, so a "measurement" there would report the clock, not the memory.

    450 MHz WAS TRIED FIRST and does not close.  MEASURED 2026-08-25: the
    MMCM delivered 466.67 MHz (period 2.143 ns, not the 450 requested -- the
    request is not the achievement), and the routed design missed by
    WNS = -1.868 ns on 4,597 of 68,237 endpoints.  Two separate reasons not
    to chase it:

      * 4,597 endpoints is 15 generators x their counters, i.e. ONE structural
        problem replicated.  That part is fixed (hbm_tg registers the HBM
        outputs before they reach any counter), but
      * VIVADO SIGNS OFF AT 0.85 V AND THIS CARD RUNS AT 0.717 V, where the
        measured fabric derate is -22.9%.  To RUN at F on the card, Vivado must
        close at 1.30 x F.  450 MHz on the card would need 583 MHz in the tool.
        That is not a timing problem to be optimised; it is out of reach.

    So 300 MHz, and the acceptance criterion is not "WNS >= 0" but
    **WNS >= 0.229 x period = 0.763 ns**, which is what makes the design
    runnable at 0.717 V rather than merely signable at 0.85 V.  Ceiling at 15
    ports is then 144 GB/s.

    NOTE the IP's own USER_AXI_INPUT_CLK_FREQ is moved to match; leaving it at
    first light's 250 while driving something else is a silent contract
    violation.

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

sys.path.insert(0, os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                 "tools")))
import genstamp

SRC = os.path.join(os.path.dirname(__file__), "build_fk33_firstlight.tcl")
DST = os.path.join(os.path.dirname(__file__), "build_fk33_hbmbw.tcl")
# Generator ports.  15 = stack 0 only (SAXI_01..15).  30 = both stacks, adding
# SAXI_17..31 -- SAXI_00 and SAXI_16 stay with jtag_hbm, one per stack.
#
# Ports are the big lever on total bandwidth and the clock is the small one:
# usable GB/s is ports x 32 B x f, so 15 -> 30 ports is 2.00x while 300 -> 350
# MHz is 1.17x.  Stack 1 sat disabled through several builds spent fighting
# 350 MHz for +24 GB/s, while enabling it is worth +144.
NPORT = int(sys.argv[1]) if len(sys.argv) > 1 else 15
if NPORT not in (15, 30):
    sys.exit("FAIL: NPORT must be 15 (stack 0) or 30 (both stacks); SAXI_00 "
             "and SAXI_16 are reserved for jtag_hbm so 16 and 31 are not "
             "reachable without taking the host's path to the card.")

def saxi(i):
    """Generator port i -> SAXI index, skipping SAXI_16 (jtag_hbm's)."""
    return i + 1 if i < 15 else i + 2

src = open(SRC).read()
out = src

# ---- 1. re-enable SAXI_01..15 on stack 0 -----------------------------------
# The global-switch branch turns them all off in one dict.  Strip exactly those
# keys rather than rewriting the line, so any other setting in it survives.
before = out
_en = [saxi(i) for i in range(NPORT)]
for i in _en:
    out = out.replace("CONFIG.USER_SAXI_%02d {false} " % i, "")
    out = out.replace("CONFIG.USER_SAXI_%02d {false}" % i, "")
if out == before:
    sys.exit("FAIL: no USER_SAXI_xx {false} keys found; the upstream branch moved")
for i in _en:
    if "CONFIG.USER_SAXI_%02d {false}" % i in out:
        sys.exit("FAIL: SAXI_%02d is still disabled after the strip" % i)

# ---- 2. the HBM AXI datapath clock -----------------------------------------
# Parameterised so the voltage-derate sweep is reproducible rather than a
# hand-edit: `gen_hbmbw.py <nport> [fclk_mhz]`.  The point of varying it is to
# find where the design STOPS working on the card at 0.717 V, which converts
# the derate from a bound into a measurement -- one build per frequency, and
# the frequency has to appear identically in three places (the HBM IP's two
# input-clock properties and the clk_wiz output) or the build fails late with
# a FREQ_HZ mismatch that does not name the cause.
#
# The MMCM is 200 MHz in.  Only frequencies of the form 200 * M / D with the
# VCO (200*M) inside the part's 600-1440 MHz range are EXACT; anything else
# the MMCM approximates, and then every GB/s number computed from the nominal
# clock is wrong by that ratio while every self-check still passes.  Checked
# below rather than assumed.
FCLK_MHZ = int(sys.argv[2]) if len(sys.argv) > 2 else 300

# CLKFBOUT_MULT_F is FRACTIONAL in 0.125 steps; the CLKOUT dividers are
# integer.  Searching integer multipliers only would reject frequencies that
# are perfectly reachable -- 325 MHz is 200 x 6.5 / 4, VCO 1300 -- and the
# useful test points for the derate sweep sit exactly in that gap between the
# integer-multiplier values 300 (6/4) and 350 (7/4).
_exact = None
_m8 = 24                      # multiplier in eighths, so 3.000 upward
while _m8 <= 512 and _exact is None:
    _mult = _m8 / 8.0
    _vco = 200.0 * _mult
    if 600.0 <= _vco <= 1440.0:
        for _d in range(1, 129):
            if abs(_vco / _d - FCLK_MHZ) < 1e-9:
                _exact = (_mult, _d, _vco)
                break
    _m8 += 1
if _exact is None:
    sys.exit("FAIL: %d MHz is not exactly synthesisable from a 200 MHz input "
             "with CLKFBOUT_MULT_F in 0.125 steps and the VCO in "
             "600-1440 MHz.  Pick one that is, or the bandwidth numbers "
             "silently inherit the MMCM's rounding error while every "
             "self-check still passes." % FCLK_MHZ)
print("hbmbw: datapath clock %d MHz (VCO %.1f MHz = 200 x %.3f, divide %d)"
      % (FCLK_MHZ, _exact[2], _exact[0], _exact[1]))

out = out.replace(
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {250} ] [get_bd_cells hbm]",
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK_FREQ {%d} ] [get_bd_cells hbm]" % FCLK_MHZ)
out = out.replace(
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {250}] [get_bd_cells hbm]",
    "set_property -dict [list CONFIG.USER_AXI_INPUT_CLK1_FREQ {%d}] [get_bd_cells hbm]" % FCLK_MHZ)

# a third clk_wiz output at 450 MHz for the datapath
anchor = ("set_property -dict [list CONFIG.CLKOUT2_USED {true} "
          "CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}] [get_bd_cells clk_wiz_0]")
if anchor not in out:
    sys.exit("FAIL: clk_wiz CLKOUT2 line not found")
out = out.replace(anchor, anchor + "\n" +
    "# hbmbw: the HBM AXI datapath clock, set by gen_hbmbw.py's fclk_mhz argument.\n"
    "set_property -dict [list CONFIG.CLKOUT3_USED {true} "
    "CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {%d.000}] [get_bd_cells clk_wiz_0]" % FCLK_MHZ)

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
      "# KNOWN ISSUE (found 2026-08-25, deliberately not fixed yet).",
      "# hbm_reset is a proc_sys_reset in the 100 MHz clk_out1 domain, and",
      "# its peripheral_aresetn is used here in the 300 MHz clk_out3 domain",
      "# with no synchroniser.  Vivado therefore TIMES it as a data path, and",
      "# it is the design's reported WNS path (100 -> 300 MHz into the R pins",
      "# of the counters).  That makes the reported WNS misleading: it is a",
      "# reset path exercised once at reset, not the path the traffic runs",
      "# every cycle, and a derate conclusion read off it would be about a",
      "# wire the workload never stresses.  See",
      "# docs/debugging/2026-08-25_voltage-derate-on-hardware.md step 3.",
      "#",
      "# Cost today is 0.029 ns (WNS +0.499 vs the real limiter's +0.528), so",
      "# it is not currently limiting anything.  NOT fixed yet only because",
      "# the frequency sweep in progress needs the two builds to differ in",
      "# nothing but the clock; changing the reset structure mid-sweep would",
      "# confound it.  Fix after: either a second proc_sys_reset clocked by",
      "# clk_out3, or an async-assert / sync-deassert synchroniser inside",
      "# hbm_tg, which also removes the timed CDC.",
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
# AXI_n_ARESET_N is specified SYNCHRONOUS TO AXI_n_ACLK, and this used to be
# driven straight from hbm_reset, a proc_sys_reset in the 100 MHz clk_out1
# domain.  Same CDC defect as the one fixed inside hbm_tg, left on the path
# into the hard block -- and at 350 MHz it was the design's worst path by a
# clear margin: ZERO logic levels and 1.5-1.7 ns of pure routing, from one
# distant driver to fifteen scattered hard-block pins.  It survived at 300 MHz
# only because the period was long enough to absorb the route.
#
# hbm_tg now exports the synchronised reset (MAX_FANOUT 4, so the tool
# replicates the driver next to the loads).  That makes it a same-domain
# path AND a short one; either alone would not have been enough, since a
# single flop feeding fifteen far-apart hard-block pins routes badly whatever
# domain it comes from.
for i in range(NPORT):
    tg.append("connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] "
              "[get_bd_pins hbm/AXI_%02d_ACLK]" % saxi(i))
    tg.append("connect_bd_net [get_bd_pins tg/aresetn_o] "
              "[get_bd_pins hbm/AXI_%02d_ARESET_N]" % saxi(i))

# AXI_00 and AXI_16 are the two CLK_SEL masters, and both of their ACLKs are
# already clk_out3 in this build -- so their resets belong in that domain too.
#
# AXI_16 matters far more than it looks.  Stack 1's SAXI_17..31 are DISABLED
# here, but the IP still ties their internal interface resets to the stack's
# master reset input, so ONE slow-domain net was driving the reset pins of
# every interface on stack 1.  After the per-port rewire above, those were
# still the design's worst paths at 350 MHz -- on ports this measurement does
# not even use.  Rewiring only the 15 enabled ports fixed the ports that were
# never the problem.
tg.append("disconnect_bd_net /hbm_reset_peripheral_aresetn "
          "[get_bd_pins hbm/AXI_00_ARESET_N]")
tg.append("disconnect_bd_net /hbm_reset_peripheral_aresetn "
          "[get_bd_pins hbm/AXI_16_ARESET_N]")
tg.append("connect_bd_net [get_bd_pins tg/aresetn_o] "
          "[get_bd_pins hbm/AXI_00_ARESET_N]")
tg.append("connect_bd_net [get_bd_pins tg/aresetn_o] "
          "[get_bd_pins hbm/AXI_16_ARESET_N]")
tg.append("")

# generator i drives SAXI_(i+1): see header note 3 on why SAXI_00 is skipped
for i in range(NPORT):
    tg.append("connect_bd_intf_net [get_bd_intf_pins tg/m%02d_axi] "
              "[get_bd_intf_pins hbm/SAXI_%02d]" % (i, saxi(i)))
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
# EVERY generator port is given EVERY pseudo-channel of the stack, not just
# its own.  With the global switch on (HBMGlobalSwitch = 1) the HBM IP routes
# by address, and SAXI_00 already carries all 16 segments, so this only
# declares what the hardware can already do.
#
# It is what makes the memory's ceiling measurable.  One port at 300 MHz
# demands 9.6 GB/s against a channel's 14.4, so a port-per-channel map can
# never saturate anything and its 100%-of-ceiling result is guaranteed by
# arithmetic.  Pointing several ports at ONE channel oversubscribes it, and
# the rate then plateaus at what the channel really delivers.  Without these
# extra segments those accesses would DECERR instead.
#
# The default mapping is unchanged -- hbm_tg still comes out of reset with
# base = PORT0, stride = 1, i.e. port i on channel i+1 -- so a build that is
# never told otherwise reproduces the earlier measurement exactly.
# The global switch is PER STACK: a port on stack 0 reaches channels 0..15 and
# a port on stack 1 reaches 16..31.  There is no cross-stack path, so the
# segment list has to follow the port's own stack or the assignment fails.
for i in range(NPORT):
    sx = saxi(i)
    lo = 0 if sx < 16 else 16
    for j in range(lo, lo + 16):
        addr.append("assign_bd_address -offset 0x%09X -range 256M "
                    "[get_bd_addr_segs {hbm/SAXI_%02d/HBM_MEM%02d}]"
                    % (j * 0x10000000, sx, j))
# 64K range must be 64K ALIGNED -- Vivado rejects 0x0000B000 outright.  The
# generator registers therefore live at 0x00010000, clear of the first-light
# map (SYSMON 0x3000, IIC 0x9000), and the readout script must use that.
addr.append("assign_bd_address -offset 0x00010000 -range 64K "
            "[get_bd_addr_segs {tg/s_axi/reg0}]")
anchor2 = "assign_bd_address -offset 0x00009000 -range 4K [get_bd_addr_segs {axi_iic_0/S_AXI/Reg}]"
if anchor2 not in out:
    sys.exit("FAIL: axi_iic address anchor not found")
out = out.replace(anchor2, anchor2 + "\n".join(addr), 1)

# Force the top AFTER bd_wrapper is added.  add_files on hbm_tg_ip.vhd puts a
# second root module in the fileset, and update_compile_order re-runs Vivado's
# automatic top detection, which picks hbm_tg_ip over bd_wrapper.  Synthesis
# then succeeds -- on the WRONG design -- and the failure surfaces only in the
# placer as "6009 I/O ports": the generator's 15 AXI masters became top-level
# pins instead of internal connections to HBM.  make_wrapper -top sets the top
# once; it does not defend it.
anchor3 = ("add_files -norecurse "
           "./$ProjectName/$ProjectName.srcs/sources_1/bd/bd/hdl/bd_wrapper.v\n"
           "update_compile_order -fileset sources_1")
if anchor3 not in out:
    sys.exit("FAIL: bd_wrapper add_files anchor not found")
out = out.replace(anchor3, anchor3 +
    "\nset_property top bd_wrapper [current_fileset]"
    "\nupdate_compile_order -fileset sources_1"
    "\nif {[get_property top [current_fileset]] ne \"bd_wrapper\"} {"
    "\n    error \"TOP is [get_property top [current_fileset]], not bd_wrapper\""
    "\n}", 1)

# repoint the project name so this never overwrites the first-light artifacts
out = out.replace("set ProjectName fk33_example", "set ProjectName fk33_hbmbw", 1)
out = ("# GENERATED by hw/fk33/gen_hbmbw.py from build_fk33_firstlight.tcl\n"
       "# -- do not hand-edit; regenerate so first-light fixes are not lost.\n"
       "# See that script's header for the four changes and what is deliberately\n"
       "# left alone.\n"
       # THE BANNER ABOVE SAYS THE FILE IS GENERATED AND NOT WITH WHAT, AND
       # THAT COST TIME ON 2026-09-20.  The committed copy was produced with
       # `30 300`; regenerating it with the defaults (15 ports, 300 MHz) is a
       # 288-line deletion that reads as ordinary drift, and recovering the 30
       # took three attempts plus one false positive (a rejected NPORT=31 left
       # the file unwritten, which compared equal to itself and looked like a
       # perfect reproduction).  The stamp is the fix: see tools/genstamp.py.
       + genstamp.stamp(["python3", "hw/fk33/gen_hbmbw.py", str(NPORT),
                         str(FCLK_MHZ)],
                        [("argv", "NPORT", NPORT),
                         ("argv", "FCLK_MHZ", FCLK_MHZ)],
                        comment="#")
       # The `+` below is required, not style: the stamp above is a CALL, not
       # a literal, so implicit string concatenation stops there and every
       # literal from here on must be joined explicitly.
       +
       # tgRoot DERIVED from the generated script's own location rather than
       # written in as a literal, so the build runs from any checkout path and
       # survives the repo directory being renamed (TRACK PATHFREE,
       # 2026-09-20).  The generated script sits at <repo>/hw/fk33/, hence two
       # levels up.  Probed rather than trusted: a wrong root would add_files
       # nothing and fail later as a missing entity.
       "set tgRoot [file normalize [file join"
       " [file dirname [info script]] .. ..]]\n"
       "if {![file exists $tgRoot/rtl/util_pkg.vhd]} {\n"
       "    error \"tgRoot: derived repo root '$tgRoot' does not contain"
       " rtl/util_pkg.vhd.\"\n"
       "}\n" + out)

open(DST, "w").write(out)
print("wrote", DST)

# Guard: the edits must be visible in the OUTPUT, checked on executable lines
# only.  An earlier generator in this repo tripped on its own comments.
code = [l for l in out.split("\n")
        if l.strip() and not l.strip().startswith("#")]
body = "\n".join(code)
checks = [
    ("SAXI_01 still disabled", "CONFIG.USER_SAXI_01 {false}" not in body),
    ("datapath clkout absent",
     "CLKOUT3_REQUESTED_OUT_FREQ {%d.000}" % FCLK_MHZ in body),
    ("HBM input clock does not match the clk_wiz output",
     ("USER_AXI_INPUT_CLK_FREQ {%d}" % FCLK_MHZ) in body and
     ("USER_AXI_INPUT_CLK1_FREQ {%d}" % FCLK_MHZ) in body),
    ("AXI clock not repointed", "clk_wiz_0/clk_out3] [get_bd_pins hbm/AXI_00_ACLK" in body),
    ("generator not added", "create_bd_cell -type module -reference hbm_tg_ip tg" in body),
    ("last port not wired", "tg/m14_axi" in body),
    ("tg regs unmapped", "tg/s_axi/reg0" in body),
    ("CATTRIP not wired", "tg/hbm_cattrip0" in body),
    ("stack temp not wired", "tg/hbm_temp0" in body),
    ("port clocks unconnected", "hbm/AXI_15_ACLK" in body),
    ("jtag_hbm CDC missing", "pcie2hbm/aclk1" in body),
    ("top not forced", "set_property top bd_wrapper" in body),
]
bad = [n for n, ok in checks if not ok]
if bad:
    sys.exit("GUARD FAILED: " + "; ".join(bad))
print("guard: all %d edits present" % len(checks))
