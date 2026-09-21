#!/usr/bin/env python3
"""Emit hw/fk33/rtl/fk33_engine.vhd -- the board-facing wrapper around
subsystem A's descriptor control plane.

WHY THIS EXISTS
---------------
`rtl/matvec_int4_desc_axi.vhd` presents its 27 weight/scale read masters as
FLATTENED std_logic_vectors (`m_araddr` is one 27*40-bit port) plus a 28th,
separately named, descriptor master (`d_*`).  Vivado's block designer cannot
see a flattened vector as AXI at all, so it cannot be connected to
`hbm/SAXI_nn`, which is an interface pin.  This wrapper is the same unit with
its 28 masters exposed as individually NAMED AXI interfaces.

That is exactly what `rtl/hbm_tg_ip.vhd` does for `rtl/hbm_tg.vhd`, and the
port naming and widths below are copied from it deliberately: that shape has
been synthesised, placed, routed and RUN against this exact HBM IP
configuration on this exact card (30 masters, 288.0 GB/s,
`hw/fk33/results/hbmbw_30port_300mhz.txt`).  Deviating from a proven interface
shape to save a few tie-off constants would be trading a known-good recipe for
nothing.

WHAT THIS FILE ADDS THAT IS NOT JUST WIRING.  Three things, each stated here
because each is a decision:

 1. THE THERMAL HALT.  `rtl/fk33_thermal.vhd` produces `compute_halt`, and its
    contract (that file's port comment) is:

        "compute_halt synchronous to compute_clk, active high, RESET VALUE '1'.
         Use it as `if compute_halt = '0' then <issue work> end if` ... Do NOT
         gate a clock with it and do NOT abandon an AXI burst that has already
         been accepted."

    `matvec_int4_desc_axi` has no halt input and `rtl/` is not this track's to
    edit, so the halt is applied at the ONE point in the interface where "new
    work" begins: the AXI-Lite write of GO (register 0x08 bit 0).  While halted
    that bit is masked to '0' before it reaches the engine.  A job already
    running is NOT disturbed -- it runs to completion, which is what completes
    every burst it has issued.  Nothing gates a clock and nothing touches a
    reset.

    The masking is exact rather than blanket -- a blanket "mask bit 0 of every
    write" would also corrupt Y_IDX -- and it is REGISTERED rather than
    combinational.  That distinction is not cosmetic and a scratch bench caught
    it: the engine's slave arms on `awvalid and wvalid` and then performs the
    register write ONE CYCLE LATER, reading `s_axi_wdata` at that later edge
    (`rtl/matvec_int4_desc_axi.vhd:862-882`).  A mask derived combinationally
    from `s_axi_awvalid` is therefore already gone if the master has dropped
    AWVALID by then, and the unmasked GO reaches the engine.  So the wrapper
    mirrors the engine's own arm condition and latches the CTRL decode, then
    masks at the execute cycle.  MEASURED before the fix: the engine went busy
    with the guard asserting halt.

    A masked GO is RECORDED, not silently dropped: ENG_STAT bit 1 is a sticky
    "a GO was refused because the card was halted".  A halt that swallows a
    command without saying so is the silent-success failure mode this project
    keeps finding, and it costs one flip-flop to not have it.

 2. AN ACTIVATION WRITE PORT.  The engine consumes its activation vector on
    `x_we/x_waddr/x_wdata`, one element per cycle, "from the previous stage".
    In this bitstream there is no previous stage, so without a path from the
    host the port would be tied off -- and then the only thing the card could
    compute is a matvec against an all-zero x, which is not arithmetic anyone
    can check.  A second, tiny AXI-Lite slave (`s_axix_*`) writes elements with
    an auto-incrementing index.

 3. ADDRESS TRUNCATION, 40 -> 33 bits, and it is deliberate.  The engine is
    generic in `ADDR_W` and the FK33 build uses 40; the HBM SAXI port is 33
    bits (8 GiB).  `rtl/hbm_tg_ip.vhd:1035` does the same truncation.  An
    address at or above 8 GiB therefore ALIASES rather than erroring.  Nothing
    in this wrapper can catch that -- see the caveat list in the build report.

Regenerate with:  python3 hw/fk33/gen_fk33_engine.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DST = os.path.join(HERE, "rtl", "fk33_engine.vhd")

# The FK33 geometry.  Every one of these is the value
# docs/debugging/2026-08-28_ar-throttle-timing-close.md and
# docs/debugging/2026-08-28_matvec-divide-by-48-core-clock.md synthesised
# out-of-context, so the in-context numbers this build produces are comparable
# with those OOC ceilings and with nothing else.
BLK = 32
ROWS_IF = 48
NPORTS_W = 24
NPORTS_S = 3
AXI_DW = 256
ADDR_W = 40
MAXCOLS = 17408
MAXROWS_BFP = 17408
FIFO_DEPTH = 512
MAXB = 16
MAXOUT = 16
DESC_MAXB = 16

# ---------------------------------------------------------------- LEVER AIDLE
# The DEFAULT of the generated entity's FAST_POP generic.  This is the ONE LINE
# a card build flips, and it is here rather than in the template so that the
# flip is a data change and shows up as a one-line diff in the generated file.
#
# WHAT IT IS.  Every one of the {NLANE} read ports ends in a FIFO whose
# read-issue condition counted the beat LEAVING the output stage as if it were
# staying, so the port sustained 2 beats per 3 core cycles.  The array accepts
# a weight word only when all 27 ports present a beat in the same cycle, so
# that cadence WAS subsystem A's rate: MEASURED 1.5101 core cycles per weight
# word on silicon against a structural floor of 1.000
# (docs/2026-09-20_d-side-vector-traffic.md section 4.1, and
# docs/debugging/2026-09-20_a-accept-port-idle.md for the attribution).
#
# False reproduces the shipping bitstream exactly.  True is the lever.  Values
# and their order are identical either way; only the issue cycle moves.
FAST_POP_DEFAULT = True

NLANE = NPORTS_W + NPORTS_S          # 27 weight+scale masters
NMAST = NLANE + 1                    # + the descriptor master
HBM_ADDR_W = 33                      # the HBM SAXI port, MEASURED from the IP
HBM_ID_W = 6

ENG_MAGIC = 0x454E4731               # "ENG1"


def master_ports():
    out = []
    for i in range(NMAST):
        p = "m%02d_axi" % i
        what = ("descriptor fetch" if i == NLANE else
                ("weight lane %d" % i if i < NPORTS_W else
                 "scale lane %d" % (i - NPORTS_W)))
        out.append("    -- HBM SAXI master %d: %s" % (i, what))
        out.append("    %s_awvalid : out std_logic;" % p)
        out.append("    %s_awready : in  std_logic;" % p)
        out.append("    %s_awaddr  : out std_logic_vector(%d downto 0);" % (p, HBM_ADDR_W - 1))
        out.append("    %s_awid    : out std_logic_vector(%d downto 0);" % (p, HBM_ID_W - 1))
        out.append("    %s_awlen   : out std_logic_vector(3 downto 0);" % p)
        out.append("    %s_awsize  : out std_logic_vector(2 downto 0);" % p)
        out.append("    %s_awburst : out std_logic_vector(1 downto 0);" % p)
        out.append("    %s_wvalid  : out std_logic;" % p)
        out.append("    %s_wready  : in  std_logic;" % p)
        out.append("    %s_wdata   : out std_logic_vector(%d downto 0);" % (p, AXI_DW - 1))
        out.append("    %s_wstrb   : out std_logic_vector(%d downto 0);" % (p, AXI_DW // 8 - 1))
        out.append("    %s_wlast   : out std_logic;" % p)
        out.append("    %s_bvalid  : in  std_logic;" % p)
        out.append("    %s_bready  : out std_logic;" % p)
        out.append("    %s_bid     : in  std_logic_vector(%d downto 0);" % (p, HBM_ID_W - 1))
        out.append("    %s_bresp   : in  std_logic_vector(1 downto 0);" % p)
        out.append("    %s_arvalid : out std_logic;" % p)
        out.append("    %s_arready : in  std_logic;" % p)
        out.append("    %s_araddr  : out std_logic_vector(%d downto 0);" % (p, HBM_ADDR_W - 1))
        out.append("    %s_arid    : out std_logic_vector(%d downto 0);" % (p, HBM_ID_W - 1))
        out.append("    %s_arlen   : out std_logic_vector(3 downto 0);" % p)
        out.append("    %s_arsize  : out std_logic_vector(2 downto 0);" % p)
        out.append("    %s_arburst : out std_logic_vector(1 downto 0);" % p)
        out.append("    %s_rvalid  : in  std_logic;" % p)
        out.append("    %s_rready  : out std_logic;" % p)
        out.append("    %s_rdata   : in  std_logic_vector(%d downto 0);" % (p, AXI_DW - 1))
        out.append("    %s_rlast   : in  std_logic;" % p)
        out.append("    %s_rid     : in  std_logic_vector(%d downto 0);" % (p, HBM_ID_W - 1))
        out.append("    %s_rresp   : in  std_logic_vector(1 downto 0);" % p)
    # strip the trailing semicolon of the last line
    out[-1] = out[-1].rstrip(";")
    return "\n".join(out)


def master_wiring():
    out = []
    for i in range(NMAST):
        p = "m%02d_axi" % i
        if i < NLANE:
            src = {
                "arvalid": "m_arvalid(%d)" % i,
                "arready": "m_arready(%d)" % i,
                "araddr": "m_araddr(%d*ADDR_W + %d downto %d*ADDR_W)" % (i, HBM_ADDR_W - 1, i),
                "arlen": "m_arlen(%d*8 + 3 downto %d*8)" % (i, i),
                "arsize": "m_arsize(%d*3 + 2 downto %d*3)" % (i, i),
                "arburst": "m_arburst(%d*2 + 1 downto %d*2)" % (i, i),
                "rvalid": "m_rvalid(%d)" % i,
                "rready": "m_rready(%d)" % i,
                "rdata": "m_rdata(%d*AXI_DW + %d downto %d*AXI_DW)" % (i, AXI_DW - 1, i),
                "rlast": "m_rlast(%d)" % i,
            }
        else:
            src = {
                "arvalid": "d_arvalid", "arready": "d_arready",
                "araddr": "d_araddr(%d downto 0)" % (HBM_ADDR_W - 1),
                "arlen": "d_arlen(3 downto 0)", "arsize": "d_arsize",
                "arburst": "d_arburst", "rvalid": "d_rvalid", "rready": "d_rready",
                "rdata": "d_rdata", "rlast": "d_rlast",
            }
        out.append("  -- master %d" % i)
        out.append("  %s_arvalid <= %s;" % (p, src["arvalid"]))
        out.append("  %s <= %s_arready;" % (src["arready"], p))
        out.append("  %s_araddr  <= %s;" % (p, src["araddr"]))
        out.append("  %s_arid    <= (others => '0');" % p)
        out.append("  %s_arlen   <= %s;" % (p, src["arlen"]))
        out.append("  %s_arsize  <= %s;" % (p, src["arsize"]))
        out.append("  %s_arburst <= %s;" % (p, src["arburst"]))
        out.append("  %s <= %s_rvalid;" % (src["rvalid"], p))
        out.append("  %s_rready  <= %s;" % (p, src["rready"]))
        out.append("  %s <= %s_rdata;" % (src["rdata"], p))
        out.append("  %s <= %s_rlast;" % (src["rlast"], p))
        # write channel: permanently idle.  Present only so the interface
        # inference matches hbm_tg_ip's proven shape.
        out.append("  %s_awvalid <= '0';" % p)
        out.append("  %s_awaddr  <= (others => '0');" % p)
        out.append("  %s_awid    <= (others => '0');" % p)
        out.append("  %s_awlen   <= (others => '0');" % p)
        out.append("  %s_awsize  <= (others => '0');" % p)
        out.append("  %s_awburst <= (others => '0');" % p)
        out.append("  %s_wvalid  <= '0';" % p)
        out.append("  %s_wdata   <= (others => '0');" % p)
        out.append("  %s_wstrb   <= (others => '0');" % p)
        out.append("  %s_wlast   <= '0';" % p)
        out.append("  %s_bready  <= '1';" % p)
        out.append("")
    return "\n".join(out)


BODY = '''-- rtl/fk33_engine.vhd -- GENERATED by hw/fk33/gen_fk33_engine.py.
-- DO NOT HAND-EDIT; edit the generator.
--
-- Board-facing wrapper around rtl/matvec_int4_desc_axi.vhd (subsystem A's
-- descriptor-in-memory control plane) for the SQRL FK33.
--
--   {NLANE} weight/scale AXI read masters + 1 descriptor master = {NMAST}
--   masters, each on its own HBM SAXI port, each 256 bits wide.
--
-- READ THE GENERATOR'S DOCSTRING BEFORE CHANGING ANYTHING HERE.  The three
-- things in this file that are not pure wiring are the thermal halt, the
-- activation write port and the 40->33 bit address truncation, and each is
-- justified there.
--
-- ======================================================================
-- CLOCK DOMAINS
-- ======================================================================
--   core_clk   the engine's compute clock AND its control AXI-Lite clock.
--              (matvec_int4_desc_axi's s_axi_aclk IS the core clock -- see its
--              port comment.)  Both AXI-Lite slaves below are in this domain.
--   hbm_aclk   the HBM AXI clock, driving all {NMAST} read masters.  The
--              crossing between the two lives inside rtl/axi_rd_port.vhd's
--              per-port async FIFO, which is what DUAL_CLK = true selects.
--
-- The duty identity is `duty = f_core / f_hbm` exactly, because {NLANE} x
-- {AXI_DW} bits is the {BYTES} B the array consumes every core cycle, and each
-- port supplies {PORTB} B per HBM cycle.  So f_hbm MUST exceed f_core; there
-- is no efficiency term to hide behind.
--
-- ======================================================================
-- THE ACTIVATION WRITE PORT, s_axix (4 KB of AXI-Lite)
-- ======================================================================
--   0x00 X_ADDR   RW  element index the next X_DATA write lands at
--   0x04 X_DATA   W   [15:0] one int16 activation element.  Writing it drives
--                     x_we for one core cycle at X_ADDR, then increments
--                     X_ADDR, so a vector is a single burst of writes to one
--                     address with no index bookkeeping on the host.
--   0x08 ENG_STAT R   [0] compute_halt, live
--                     [1] GO_BLOCKED, sticky: a GO was refused while halted.
--                         Write 1 to this bit to clear it.
--                     [2] job_done   [3] job_err
--   0x0C ENG_ID   R   0x{ENG_MAGIC:08X} = "ENG1"
--
-- The engine's OWN map (DESC_PTR, CTRL/GO, STATUS, Y_IDX/Y_LO/Y_HI, CYCLES,
-- BEATS, STARVED) is unchanged and is documented in
-- rtl/matvec_int4_desc_axi.vhd.  Nothing here shadows or duplicates it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fk33_engine is
  generic(
    -- LEVER C, forwarded to matvec_int4_desc_axi -> matvec_int4 ->
    -- matvec_core.  "regs" is the shipping value and keeps this entity
    -- byte-identical in behaviour to the bitstream on card 1; TRACK LEVERC48
    -- (`a4828ab`) MEASURED "distributed" at ROWS_IF = 48 as -42,633 CLB LUT,
    -- MUXF7 24,583 -> 0, MUXF8 12,288 -> 0, +13,195 CLB FF, +12,288 LUTRAM.
    --
    -- ADDED 2026-08-30 BY TRACK ROUTE2, and the reason it had to be added
    -- here: LEVERC48 forwarded CB_STYLE through matvec_int4_desc_axi,
    -- matvec_int4 and matvec_int4_axi, but `fk33_engine` is the entity that
    -- BINDS matvec_int4_desc_axi for the card and for `compose4_top`, and it
    -- had no generics at all.  So the lever was reachable from a unit
    -- synthesis of matvec_core and from NO top the card or the composition
    -- actually builds.  Passing it on the `synth_design` line does not help:
    -- -generic reaches the TOP's generics only, never a deep instance.
    --
    -- Every unrecognised value silently means "regs" -- see the note at
    -- rtl/matvec_core.vhd:238 and its CHK_CB_STYLE typo guard, which is what
    -- catches a misspelling rather than this wrapper.
    CB_STYLE : string := "regs";

    -- THE VERSION-2 A-JOB INDEX CHECK, forwarded to matvec_int4_desc_axi.
    --
    -- Descriptor version 2 stamps the descriptor's own A-job index into
    -- extension word 3, and the descriptor plane refuses a disagreement with
    -- EC_DESC / ED_JOB_INDEX before starting the array.  That closes the
    -- ordering contract an arithmetic descriptor address imposes on the host:
    -- a well-formed descriptor for the WRONG step passes every other check.
    --
    -- DEFAULT FALSE, and that is what keeps the host-driven flow working.  A
    -- build where the HOST writes DESC_PTR per job has no counter, so
    -- `job_index` sits at zero and every v2 descriptor stamped with a nonzero
    -- index would be refused -- which is every A job but the first, now that
    -- tools/gen_layer_program.py stamps them.  That is the flow which produced
    -- 311 of 311 jobs, 1,675,264 result rows element-exact.
    --
    -- A build that drives `job_index` from rtl/a_job_counter.vhd sets this
    -- true and gains the check.  `hw/fk33/gen_compose4_top.py --wire` does.
    -- Opting in is the safe direction: forgetting to opt in loses a check,
    -- forgetting to opt out breaks a working card.
    CHECK_JOB_INDEX : boolean := false;

    -- WHERE x_exp COMES FROM, forwarded to matvec_int4_desc_axi.
    --
    -- false (DEFAULT): the descriptor's own `x_exp` word (ext word 2).  That
    -- is the host-driven flow, where hw/fk33/host/fk33_run_layer.py builds
    -- every descriptor at run time from the exponent of the vector that
    -- actually arrived, and it is the flow that produced 1,675,264 result
    -- rows element-exact.  Nothing drives `d_x_exp` there and it is not read.
    --
    -- true: the `d_x_exp` port, driven per job by subsystem D's ga_desc arm
    -- from the region exponent store.  The CARD build sets this, because on
    -- the card the descriptors are DMA'd once per model load and every A job
    -- of a token carried the same baked scalar --
    -- docs/debugging/2026-09-17_x-exp-is-baked-into-every-a-descriptor.md.
    -- Set as CONFIG.USE_XEXP_PORT on the block-design cell by
    -- hw/fk33/gen_pcieep.py under FK33_CARD=1, for the reason CB_STYLE gives.
    --
    -- Opting in is the safe direction, as with CHECK_JOB_INDEX: forgetting to
    -- opt in on the card gives wrong exponents with FAULTS = 0; forgetting to
    -- opt out on a host-driven build reads a port nothing drives.
    USE_XEXP_PORT : boolean := false;

    -- LEVER AIDLE, forwarded to matvec_int4_desc_axi -> matvec_int4 ->
    -- weight_streamer -> all {NLANE} read ports, and to this engine's own
    -- descriptor read master.
    --
    -- false (the value below is FAST_POP_DEFAULT in
    -- hw/fk33/gen_fk33_engine.py) is the shipping cadence: each read port
    -- delivers 2 beats per 3 core cycles because its FIFO's read-issue
    -- condition counts the beat leaving the output stage as if it were
    -- staying, and since matvec_core accepts a word only when all {NLANE}
    -- ports present one in the SAME cycle, that is the array's rate.
    -- MEASURED on silicon: 1.5101 core cycles per weight word against a
    -- structural floor of 1.000, i.e. the array is idle 34% of the time with
    -- the memory idle 61% of the time.
    --
    -- true removes the bubble.  It changes no value, no order, no register
    -- decode, no port width and no descriptor field, exactly as CB_STYLE
    -- does not -- so it is invisible to a host driver and a build with it set
    -- must produce bit-identical results.
    --
    -- IT IS A GENERIC AND NOT A HARD-CODED true FOR THE SAME REASON CB_STYLE
    -- IS: `-generic` on the synth_design line reaches the TOP's generics
    -- only, never a deep instance, so a lever that is not carried by THIS
    -- entity is not reachable from the card build or from compose4_top at all.
    FAST_POP : boolean := {FAST_POP_DEFAULT}
  );
  port(
    ------------------------------------------------------------------------
    -- clocks and resets
    ------------------------------------------------------------------------
    core_clk     : in  std_logic;
    core_aresetn : in  std_logic;
    hbm_aclk     : in  std_logic;

    ------------------------------------------------------------------------
    -- THE THERMAL GUARD.  Active high, synchronous to core_clk, reset value
    -- '1'.  Blocks a GO; does NOT stop a running job, does not gate a clock
    -- and does not abandon an accepted burst.
    ------------------------------------------------------------------------
    compute_halt : in  std_logic;

    ------------------------------------------------------------------------
    -- engine control, AXI4-Lite, core_clk domain
    ------------------------------------------------------------------------
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_awaddr  : in  std_logic_vector(11 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_araddr  : in  std_logic_vector(11 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);

    ------------------------------------------------------------------------
    -- activation writer, AXI4-Lite, core_clk domain
    ------------------------------------------------------------------------
    s_axix_awvalid : in  std_logic;
    s_axix_awready : out std_logic;
    s_axix_awaddr  : in  std_logic_vector(11 downto 0);
    s_axix_awprot  : in  std_logic_vector(2 downto 0);
    s_axix_wvalid  : in  std_logic;
    s_axix_wready  : out std_logic;
    s_axix_wdata   : in  std_logic_vector(31 downto 0);
    s_axix_wstrb   : in  std_logic_vector(3 downto 0);
    s_axix_bvalid  : out std_logic;
    s_axix_bready  : in  std_logic;
    s_axix_bresp   : out std_logic_vector(1 downto 0);
    s_axix_arvalid : in  std_logic;
    s_axix_arready : out std_logic;
    s_axix_araddr  : in  std_logic_vector(11 downto 0);
    s_axix_arprot  : in  std_logic_vector(2 downto 0);
    s_axix_rvalid  : out std_logic;
    s_axix_rready  : in  std_logic;
    s_axix_rdata   : out std_logic_vector(31 downto 0);
    s_axix_rresp   : out std_logic_vector(1 downto 0);

    ------------------------------------------------------------------------
    -- D-FACING COMPLETION.  TRACK CARDTOP, 2026-09-02.
    --
    -- Until now this engine had NO D-facing interface at all: `job_done` and
    -- `job_err` were internal and reachable only as STATUS bits [2] and [3]
    -- over the AXI-Lite slave, because the engine was built to be driven by
    -- the HOST over PCIe, which is what it is doing on the card today.
    --
    -- rtl/a_desc_adapter.vhd takes completion from PORTS rather than from a
    -- STATUS read, deliberately: a read channel would be a second way to
    -- learn the same fact, free to disagree with the first.  These two
    -- outputs are that path.
    --
    -- PURELY ADDITIVE.  They are OUTPUTS driven from the same two signals
    -- STATUS already presents, so no existing behaviour can change and the
    -- image currently in the card's flash stays valid until a new one is
    -- deliberately built.  An unconnected output is legal VHDL and costs
    -- nothing, so hw/fk33/gen_pcieep.py needs no change to keep working.
    ------------------------------------------------------------------------
    d_job_done     : out std_logic;
    d_job_err      : out std_logic;

    -- Which A descriptor the sequencer believes it is fetching, compared
    -- against the descriptor's own claim in version-2 extension word 3.
    -- Defaulted so every existing instantiation stays legal; with
    -- CHECK_JOB_INDEX false it is not read at all.
    job_index      : in  std_logic_vector(31 downto 0) := (others => '0');

    -- D-FACING ACTIVATION WRITE.  The host path above (s_axix) moves ONE
    -- int16 per AXI-Lite transaction, which is right for a host loading a
    -- vector over PCIe and wrong for D: a 4,096-element activation across
    -- 311 jobs would cost millions of core cycles per token.  This port is
    -- one element per cycle, the same shape llama_top's own A adapter
    -- drives (`llama_top.vhd:3197-3226`).
    --
    -- DEFAULTS MAKE IT INERT.  Left unconnected, d_x_we is '0' and the
    -- s_axix path below is untouched, so the image in the card's flash
    -- keeps working exactly as it does today.
    d_x_we         : in  std_logic := '0';
    d_x_waddr      : in  std_logic_vector(15 downto 0) := (others => '0');
    d_x_wdata      : in  std_logic_vector(15 downto 0) := (others => '0');
    -- The live x exponent for the job, read by the unit only when
    -- USE_XEXP_PORT is true (above).  Held stable by the driver for the whole
    -- job: fk33_llama_top's ga_desc latches it before `u_start` rises and
    -- rewrites it only at the next job's S_GO.
    d_x_exp        : in  std_logic_vector(31 downto 0) := (others => '0');

    -- D-FACING RESULT.  Results currently leave this engine ONLY through the
    -- AXI-Lite Y_IDX/Y_LO/Y_HI registers, one row per two reads, which D
    -- cannot use.  These are the core's own result beats, brought out.
    --
    -- `y_we` HAS NO READY AND A STALL LOSES A BEAT -- that is the core's
    -- contract, not a choice made here (llama_top.vhd:3217-3220 says the
    -- same of the simulation path).  So whatever consumes these must accept
    -- every beat unconditionally; a consumer that can refuse is a consumer
    -- that will silently drop results.
    --
    -- Outputs, so leaving them unconnected changes nothing.
    d_y_we         : out std_logic;
    d_y_addr       : out std_logic_vector(15 downto 0);
    d_y_data       : out std_logic_vector({ROWS_IF}*64-1 downto 0);
    d_y_mask       : out std_logic_vector({ROWS_IF}-1 downto 0);
    d_y_exp        : out std_logic_vector(31 downto 0);

    ------------------------------------------------------------------------
    -- {NMAST} HBM read masters
    ------------------------------------------------------------------------
{MASTER_PORTS}
  );
end entity fk33_engine;

architecture rtl of fk33_engine is

  constant BLK         : positive := {BLK};
  constant ROWS_IF     : positive := {ROWS_IF};
  constant NPORTS_W    : positive := {NPORTS_W};
  constant NPORTS_S    : positive := {NPORTS_S};
  constant AXI_DW      : positive := {AXI_DW};
  constant ADDR_W      : positive := {ADDR_W};
  constant NP_ALL      : positive := NPORTS_W + NPORTS_S;

  -- flattened engine masters
  signal m_arvalid : std_logic_vector(NP_ALL-1 downto 0);
  signal m_arready : std_logic_vector(NP_ALL-1 downto 0);
  signal m_araddr  : std_logic_vector(NP_ALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP_ALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP_ALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP_ALL*2-1 downto 0);
  signal m_rvalid  : std_logic_vector(NP_ALL-1 downto 0);
  signal m_rready  : std_logic_vector(NP_ALL-1 downto 0);
  signal m_rdata   : std_logic_vector(NP_ALL*AXI_DW-1 downto 0);
  signal m_rlast   : std_logic_vector(NP_ALL-1 downto 0);

  -- descriptor master
  signal d_arvalid : std_logic;
  signal d_arready : std_logic;
  signal d_araddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal d_arlen   : std_logic_vector(7 downto 0);
  signal d_arsize  : std_logic_vector(2 downto 0);
  signal d_arburst : std_logic_vector(1 downto 0);
  signal d_rvalid  : std_logic;
  signal d_rready  : std_logic;
  signal d_rdata   : std_logic_vector(AXI_DW-1 downto 0);
  signal d_rlast   : std_logic;

  -- the engine's control write channel, after the halt mask
  signal eng_wdata   : std_logic_vector(31 downto 0);
  signal eng_awready : std_logic;
  signal ctrl_dec    : std_logic;   -- combinational address decode
  signal ctrl_q      : std_logic;   -- the same, latched at the ARM cycle
  signal go_blocked  : std_logic := '0';

  -- activations
  signal x_we    : std_logic := '0';
  signal x_waddr : std_logic_vector(15 downto 0) := (others => '0');
  signal x_wdata : std_logic_vector(15 downto 0) := (others => '0');
  signal x_idx   : unsigned(15 downto 0) := (others => '0');

  -- the x-writer's own AXI-Lite handshake
  signal xawready, xwready, xbvalid, xarready, xrvalid : std_logic := '0';
  signal xrdata : std_logic_vector(31 downto 0) := (others => '0');
  signal xrd_addr : std_logic_vector(11 downto 0) := (others => '0');

  signal job_done, job_err : std_logic;
  signal x_we_mux    : std_logic;
  signal x_waddr_mux : std_logic_vector(15 downto 0);
  signal x_wdata_mux : std_logic_vector(15 downto 0);

  -- results.  Left unconnected on purpose: the host reads results through the
  -- engine's own Y_IDX / Y_LO / Y_HI / Y_EXP registers, and exporting a
  -- ROWS_IF*64 = {YBITS}-bit bus to a block design that has no consumer for it
  -- would be {YBITS} nets to nowhere.  See the caveat list in the build report.
  signal y_we    : std_logic;
  signal y_addr  : std_logic_vector(15 downto 0);
  signal y_data  : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal y_mask  : std_logic_vector(ROWS_IF-1 downto 0);
  signal y_exp_o : std_logic_vector(31 downto 0);

begin

  s_axi_awready <= eng_awready;

  ---------------------------------------------------------------------------
  -- THE THERMAL HALT, applied to the one write that starts new work.
  --
  -- The engine's slave accepts a write only when awvalid AND wvalid are high
  -- in the same cycle (rtl/matvec_int4_desc_axi.vhd:862), and it latches
  -- s_axi_awaddr in that same cycle, so the target register is known
  -- combinationally at the instant the data is presented.  Register 2
  -- (byte 0x08) is CTRL and its bit 0 is GO.
  ---------------------------------------------------------------------------
  ctrl_dec <= '1' when s_axi_awaddr(7 downto 2) = "000010" else '0';

  ctrl_p : process(core_clk)
  begin
    if rising_edge(core_clk) then
      if core_aresetn = '0' then
        ctrl_q <= '0'; go_blocked <= '0';
      else
        -- THE ARM CYCLE, byte for byte the engine's own condition.
        if eng_awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          ctrl_q <= ctrl_dec;
        end if;
        -- THE EXECUTE CYCLE.  This is where the engine samples s_axi_wdata,
        -- so it is where a masked GO actually happened.
        if eng_awready = '1' and ctrl_q = '1' and compute_halt = '1'
           and s_axi_wdata(0) = '1' then
          go_blocked <= '1';
        elsif s_axix_awvalid = '1' and s_axix_wvalid = '1' and xbvalid = '0'
              and s_axix_awaddr(11 downto 2) = "0000000010"
              and s_axix_wdata(1) = '1' then
          go_blocked <= '0';
        end if;
      end if;
    end if;
  end process;

  eng_wdata <= (s_axi_wdata(31 downto 1)
                & (s_axi_wdata(0) and not (ctrl_q and compute_halt)));

  ---------------------------------------------------------------------------
  -- THE ACTIVATION WRITER.  Same handshake shape as the engine's own slave:
  -- one-cycle ready when both address and data are presented together, which
  -- is what SmartConnect issues.
  ---------------------------------------------------------------------------
  s_axix_awready <= xawready;
  s_axix_wready  <= xwready;
  s_axix_bvalid  <= xbvalid;
  s_axix_bresp   <= "00";
  s_axix_arready <= xarready;
  s_axix_rvalid  <= xrvalid;
  s_axix_rdata   <= xrdata;
  s_axix_rresp   <= "00";

  xwr_p : process(core_clk)
  begin
    if rising_edge(core_clk) then
      x_we <= '0';
      if core_aresetn = '0' then
        xawready <= '0'; xwready <= '0'; xbvalid <= '0';
        x_idx <= (others => '0');
      else
        -- xbvalid = '0' in the guard: a master that leaves AWVALID high for
        -- one cycle past the handshake would otherwise re-arm and write the
        -- same element a second time, at the NEXT index.  SmartConnect does
        -- not do that; the guard costs nothing and does not rely on it.
        if xawready = '0' and xbvalid = '0'
           and s_axix_awvalid = '1' and s_axix_wvalid = '1' then
          xawready <= '1'; xwready <= '1';
          case to_integer(unsigned(s_axix_awaddr(11 downto 2))) is
            when 0 =>
              x_idx <= unsigned(s_axix_wdata(15 downto 0));
            when 1 =>
              x_we    <= '1';
              x_waddr <= std_logic_vector(x_idx);
              x_wdata <= s_axix_wdata(15 downto 0);
              x_idx   <= x_idx + 1;
            when others => null;
          end case;
        else
          xawready <= '0'; xwready <= '0';
        end if;

        if xawready = '1' and xwready = '1' then
          xbvalid <= '1';
        elsif xbvalid = '1' and s_axix_bready = '1' then
          xbvalid <= '0';
        end if;
      end if;
    end if;
  end process;

  xrd_p : process(core_clk)
  begin
    if rising_edge(core_clk) then
      if core_aresetn = '0' then
        xarready <= '0'; xrvalid <= '0';
      else
        if xarready = '0' and s_axix_arvalid = '1' and xrvalid = '0' then
          xarready <= '1';
          xrd_addr <= s_axix_araddr;
        else
          xarready <= '0';
        end if;

        if xarready = '1' then
          xrvalid <= '1';
          case to_integer(unsigned(xrd_addr(11 downto 2))) is
            when 0 => xrdata <= x"0000" & std_logic_vector(x_idx);
            when 2 => xrdata <= (0 => compute_halt, 1 => go_blocked,
                                 2 => job_done, 3 => job_err,
                                 others => '0');
            when 3 => xrdata <= x"{ENG_MAGIC:08X}";
            when others => xrdata <= (others => '0');
          end case;
        elsif xrvalid = '1' and s_axix_rready = '1' then
          xrvalid <= '0';
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- SUBSYSTEM A
  ---------------------------------------------------------------------------
  -- The D-facing completion outputs.  Driven from the SAME two signals the
  -- STATUS register presents at bits [2] and [3], on purpose: one source,
  -- so a port and a register read cannot disagree about whether a job
  -- finished.
  d_job_done <= job_done;
  d_job_err  <= job_err;

  -- the result beats, straight out of the core
  d_y_we   <= y_we;
  d_y_addr <= y_addr;
  d_y_data <= y_data;
  d_y_mask <= y_mask;
  d_y_exp  <= y_exp_o;

  -- The activation write, muxed.  D wins when it is driving, and the two
  -- sources must never drive together: on the card D owns the engine during
  -- a token and the host owns it between tokens.  That is a PROTOCOL claim,
  -- so it is asserted rather than assumed.  Simulation only -- Vivado
  -- ignores `severity failure` in synthesis.
  x_we_mux    <= d_x_we when d_x_we = '1' else x_we;
  x_waddr_mux <= d_x_waddr when d_x_we = '1' else x_waddr;
  x_wdata_mux <= d_x_wdata when d_x_we = '1' else x_wdata;

  collide : process(core_clk) is
  begin
    if rising_edge(core_clk) then
      assert not (d_x_we = '1' and x_we = '1')
        report "fk33_engine: D and the host both wrote an activation in one "
             & "cycle; the host write is LOST"
        severity failure;
    end if;
  end process;

  eng : entity work.matvec_int4_desc_axi
    generic map(
      BLK           => BLK,
      ROWS_IF       => ROWS_IF,
      NPORTS_W      => NPORTS_W,
      NPORTS_S      => NPORTS_S,
      AXI_DW        => AXI_DW,
      ADDR_W        => ADDR_W,
      CB_STYLE      => CB_STYLE,
      MAXCOLS       => {MAXCOLS},
      MAXROWS_BFP   => {MAXROWS_BFP},
      FIFO_DEPTH    => {FIFO_DEPTH},
      MAXB          => {MAXB},
      MAXOUT        => {MAXOUT},
      DESC_MAXB     => {DESC_MAXB},
      CHECK_JOB_INDEX => CHECK_JOB_INDEX,
      USE_XEXP_PORT => USE_XEXP_PORT,
      FAST_POP      => FAST_POP,
      DUAL_CLK      => true,
      C_S_AXI_DATA_WIDTH => 32,
      C_S_AXI_ADDR_WIDTH => 8
    )
    port map(
      job_index     => job_index,
      s_axi_aclk    => core_clk,
      s_axi_aresetn => core_aresetn,
      m_aclk        => hbm_aclk,

      s_axi_awaddr  => s_axi_awaddr(7 downto 0),
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => eng_awready,
      s_axi_wdata   => eng_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr(7 downto 0),
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,

      d_arvalid => d_arvalid, d_arready => d_arready, d_araddr => d_araddr,
      d_arlen   => d_arlen,   d_arsize  => d_arsize,  d_arburst => d_arburst,
      d_rvalid  => d_rvalid,  d_rready  => d_rready,  d_rdata   => d_rdata,
      d_rlast   => d_rlast,

      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen   => m_arlen,   m_arsize  => m_arsize,  m_arburst => m_arburst,
      m_rvalid  => m_rvalid,  m_rready  => m_rready,  m_rdata  => m_rdata,
      m_rlast   => m_rlast,

      x_we     => x_we_mux,
      x_waddr  => x_waddr_mux,
      x_wdata  => x_wdata_mux,
      x_exp_in => d_x_exp,

      y_we     => y_we,
      y_addr   => y_addr,
      y_data   => y_data,
      y_mask   => y_mask,
      y_exp_o  => y_exp_o,
      job_done => job_done,
      job_err  => job_err
    );

  ---------------------------------------------------------------------------
  -- MASTER FAN-OUT.  40 -> 33 address bits and 8 -> 4 arlen bits, exactly as
  -- rtl/hbm_tg_ip.vhd does, because the HBM SAXI slave is AXI3 with a 33-bit
  -- address and a 4-bit ARLEN.  MAXB = {MAXB} and DESC_MAXB = {DESC_MAXB} so
  -- arlen never exceeds 15 and the truncation is exact; the address truncation
  -- is NOT checked and cannot be from here.
  ---------------------------------------------------------------------------
{MASTER_WIRING}
end architecture rtl;
'''


USAGE = """usage: python3 hw/fk33/gen_fk33_engine.py [--check]

  (no arguments)  regenerate hw/fk33/rtl/fk33_engine.vhd in place
  --check         regenerate in memory and compare; print
                  GEN_FK33_ENGINE_CHECK: OK or STALE and exit 0 or 1.
                  WRITES NOTHING.

This generator takes no out-of-band input: its output depends only on this
script and the constants at the top of it, so --check needs no arguments and
no GENSTAMP block to recover.  Contrast tools/gen_hbm_tg_ip.py, whose
committed NPORT=30 is not its default.
"""


def main(argv=None):
    # UNTIL 2026-09-20 THIS SCRIPT PARSED NOTHING AND WROTE UNCONDITIONALLY,
    # so `--help` rewrote the repo file -- CLAUDE.md records that as the
    # reason it was left ungated, and the file it writes carries FAST_POP,
    # which is in the failing build 11b.  A staleness here would be invisible
    # and expensive.  Argument handling first, side effect afterwards.
    argv = sys.argv[1:] if argv is None else list(argv)
    check = "--check" in argv
    rest = [a for a in argv if a != "--check"]
    if rest:
        sys.stdout.write(USAGE)
        # Unknown arguments are an ERROR, not a silent regeneration.  The
        # failure this closes is a typo like `--chek` quietly writing the file
        # and the caller reading "wrote ..." as a passing check.
        return 0 if ("--help" in rest or "-h" in rest) else 2

    txt = BODY.format(
        NLANE=NLANE, NMAST=NMAST, BLK=BLK, ROWS_IF=ROWS_IF,
        NPORTS_W=NPORTS_W, NPORTS_S=NPORTS_S, AXI_DW=AXI_DW, ADDR_W=ADDR_W,
        MAXCOLS=MAXCOLS, MAXROWS_BFP=MAXROWS_BFP, FIFO_DEPTH=FIFO_DEPTH,
        MAXB=MAXB, MAXOUT=MAXOUT, DESC_MAXB=DESC_MAXB,
        BYTES=NLANE * AXI_DW // 8, PORTB=AXI_DW // 8,
        YBITS=ROWS_IF * 64,
        ENG_MAGIC=ENG_MAGIC,
        FAST_POP_DEFAULT=str(FAST_POP_DEFAULT).lower(),
        MASTER_PORTS=master_ports(),
        MASTER_WIRING=master_wiring(),
    )
    if check:
        have = open(DST).read() if os.path.exists(DST) else None
        if have == txt:
            print("GEN_FK33_ENGINE_CHECK: OK hw/fk33/rtl/fk33_engine.vhd "
                  "(%d bytes, %d masters)" % (len(txt), NMAST))
            return 0
        print("GEN_FK33_ENGINE_CHECK: STALE hw/fk33/rtl/fk33_engine.vhd")
        if have is None:
            print("  the file does not exist")
        else:
            import difflib
            for line in list(difflib.unified_diff(
                    have.splitlines(), txt.splitlines(),
                    "checked-in", "generated", lineterm=""))[:40]:
                print("  " + line)
        return 1

    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "w") as f:
        f.write(txt)
    print("wrote %s (%d bytes, %d masters)" % (DST, len(txt), NMAST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
