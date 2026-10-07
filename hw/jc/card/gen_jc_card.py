#!/usr/bin/env python3
"""hw/jc/card/gen_jc_card.py -- the Jungle Cat (VU35P, no PCIe) block design for the
Qwen3.8-27B inference card.  Emits three files beside this script:

    jc_card_bd.tcl   the block design `jcc`, sourced inside a project that already holds
                     the VHDL (Task 9's build_card.tcl);
    jc_card.xdc      pins and the board clock, copied from hw/jc/loader/jc_loader.xdc;
    jc_card_top.vhd  the synthesis top: the BD wrapper plus the USER3 BSCANE2 wrapper.

WHAT IS IN THE BD
-----------------
    sysclk (BC26/BC27, 200 MHz LVDS) -> IBUFDS -> clk_wiz_0
        clk_out1 100 MHz         HBM APB_0/1_PCLK (apb_rst)
        clk_out2 200 MHz         HBM_REF_CLK_0/1
        clk_out3 JC_CLK_CORE_MHZ clk_core: the engine, the card, the seam, the grant,
                                 the loader, the ctl core, jtag_hbm, every interconnect
                                 and EVERY enabled HBM AXI port.  One clock net, no AXI
                                 clock converter anywhere.
    hbm (2 stacks, 8 GB, all 32 SAXI enabled)
        SAXI_00                  loader (jc_loader_top, the USER4 loader, unchanged)
        SAXI_01..15, SAXI_17..29 eng m00..m27 (gen_pcieep.ENG_PORT_MAP)
        SAXI_16                  hbm_sc smartconnect <- jtag_hbm, ctl read master
        SAXI_30, SAXI_31         bcgrant m0, m1 (gen_pcieep.CARD_SAXI): the B/C grant's
                                 POOL.  Neither port is "B's" or "C's": bc_port_grant
                                 gives both to whichever of B and C holds the grant
                                 (B read+write on m0; C read 0 + C write on m0 and C
                                 read 1 on m1).
    eng, fk33_seam_0, card, bcgrant   the FK33 card cells, wired by gen_pcieep.py's own
                                 emission functions (imported, not copied)
    ctl (jc_ctl_core)            the USER3 control core: AXI-Lite master -> axil2eng
                                 (engine control 0x12000, activation writer 0x13000,
                                 seam 0xE000); AXI4 read-only master -> hbm_sc
No XDMA, no PCIe, no aux domain, no SYSMON, no thermal guard (see THERMAL below).

THE CARD WIRING IS gen_pcieep.py's, BY IMPORT
--------------------------------------------
gen_pcieep.py reads its configuration from the environment at import time, so this
generator imports it under a PINNED environment (PCIEEP_ENV below: build 20's card
levers and the 27B model) and calls its section functions: _eng_cell_lines,
_eng_hbm_lines, _seam_block, the _card_*_lines sections, _eng_hbm_addr_text,
_core_clk_sentinel, UNCONNECTED_PIN_CHECK, check_reset_topology, check_seam_tieoff.
Where the FK33 board differs (the HBM AXI clock is xdma/axi_aclk there, the engctl
smartconnect has two clocks, the grant needs clock converters) the functions take a
`one_clock` / clock-net argument whose default is the FK33 text, byte for byte.

THE 27B CARD WRAPPER
--------------------
fk33_card has no generics in the BD: hw/fk33/gen_fk33_card.py folds them into
hw/fk33/rtl/fk33_card.vhd, and gen_pcieep.py derives the seam's REGMAX/HADDR_W, CAPS
and MAXPOS from that file.  The committed wrapper is the 9B, so this generator
REFUSES to run in place unless that file's GENSTAMP carries JC_CARD_ENV (the 27B
build 27B-1 generics).  When it does not, it runs itself in a SCRATCH copy of the
tracked tree (--scratch, default ~/regress_scratch/gen_jc_card): gen_fk33_card.py
under JC_CARD_ENV there, then this generator in place there, emitting back here.
So `python3 hw/jc/card/gen_jc_card.py` reproduces the committed outputs from the
repository as it stands, and a build tree whose card is already the 27B one
(Task 9's run_card.sh) generates in place.

compose4_top.vhd IS NOT USED.  hw/fk33/rtl/compose4_top.vhd is a 9B fit-and-route
top whose nine instances are deliberately NOT wired to each other ("THE SUBSYSTEMS
ARE NOT WIRED TO EACH OTHER", its header).  It is not the FK33 card's composition
and reusing it would be less faithful, not more.

THERMAL.  The FK33's fk33_thermal guard drives eng/compute_halt from SYSMON and the
HBM temperature outputs.  The Jungle Cat has no such guard yet (the loader has none
either), so compute_halt is tied LOW here and says so.  That is a gap, not a choice.

INPUTS.  One: JC_CLK_CORE_MHZ (integer MHz, 50..250, default 200), stamped.  The
FK33_* values are pinned in this file, not read; a caller environment that sets one
of them to a DIFFERENT value is refused rather than silently overridden.

No Vivado runs here.  Check with:  python3 -m pytest hw/jc/card/test_gen_jc_card.py -q
Staleness:                          python3 hw/jc/card/gen_jc_card.py --check
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import genstamp  # noqa: E402

OUT_TCL = "jc_card_bd.tcl"
OUT_XDC = "jc_card.xdc"
OUT_TOP = "jc_card_top.vhd"
LOADER_XDC = os.path.join(REPO, "hw", "jc", "loader", "jc_loader.xdc")
CARD_RTL = os.path.join(REPO, "hw", "fk33", "rtl", "fk33_card.vhd")
SCRATCH_MARK = ".gen_jc_card_scratch"

BD_NAME = "jcc"
PART = "xcvu35p-fsvh2104-2L-e"       # the build's part (Task 9); not used in the BD text

# ---- the one input ------------------------------------------------------------------
CLK_CORE_ENV = "JC_CLK_CORE_MHZ"
CLK_CORE_DEFAULT = 200


def clk_core_mhz(env=None):
    """JC_CLK_CORE_MHZ as an integer.  50..250 is gen_pcieep.py's own bound on the
    core clock (FK33_ENG_CORE_MHZ, which this value is passed as); an integer because
    the HBM IP's USER_AXI_INPUT_CLK_FREQ is an integer MHz."""
    env = os.environ if env is None else env
    v = env.get(CLK_CORE_ENV) or None
    if v is None:
        return CLK_CORE_DEFAULT
    if not re.fullmatch(r"\d+", v):
        sys.exit("ABORT: %s=%r is not an integer number of MHz." % (CLK_CORE_ENV, v))
    mhz = int(v)
    if not 50 <= mhz <= 250:
        sys.exit("ABORT: %s=%d is outside 50..250 MHz." % (CLK_CORE_ENV, mhz))
    return mhz


def stamp_inputs(env=None):
    env = os.environ if env is None else env
    return [("env", CLK_CORE_ENV, env.get(CLK_CORE_ENV) or None)]


def stamp_block(comment, env=None):
    inputs = stamp_inputs(env)
    cmd = ([f"{n}={v}" for (_, n, v) in sorted(inputs) if v]
           + ["python3", "hw/jc/card/gen_jc_card.py"])
    return genstamp.stamp(cmd, inputs, comment=comment)


# ---- pinned configuration -----------------------------------------------------------
# hw/fk33/gen_fk33_card.py's environment for the 27B card wrapper: build 27B-1's
# (docs/superpowers/plans/2026-09-23-27b-two-card.md Task 4, and the GENSTAMP of
# /mnt/storage/fk33_builds/wt27/hw/fk33/rtl/fk33_card.vhd).  None = unset.
JC_CARD_ENV = {
    "FK33_A_ROWS_IF": None,
    "FK33_C_KV_BLOCK": "16",
    "FK33_C_MAXPOS": "16384",
    "FK33_MODEL": "QWEN38_27B",
}


def pcieep_env(mhz):
    """gen_pcieep.py's environment: build 20's card levers (FK33_CB_STYLE=distributed)
    and the 27B model, with the core clock at clk_core.  Every one of gen_pcieep's
    STAMP_ENV_NAMES is listed (checked after import), so none is left to the caller."""
    return {
        "FK33_CARD": "1",
        "FK33_CB_STYLE": "distributed",
        "FK33_ENG": None,
        "FK33_ENG_CORE_MHZ": str(mhz),
        "FK33_ENG_FAST_MHZ": None,
        "FK33_ENG_SPLIT_CLK": None,
        "FK33_FLATTEN": None,
        "FK33_MODEL": "QWEN38_27B",
        "FK33_SYNTH_JOBS": None,
        "FK33_SYNTH_THREADS": None,
    }


def _refuse_conflicting_env(mhz, env=None):
    env = os.environ if env is None else env
    want = dict(JC_CARD_ENV)
    want.update(pcieep_env(mhz))
    bad = []
    for k, v in sorted(want.items()):
        got = env.get(k) or None
        if got is None:
            continue
        if k == "FK33_ENG_CORE_MHZ":
            try:
                same = float(got) == float(v)
            except ValueError:
                same = False
        else:
            same = got == v
        if not same:
            bad.append("%s=%s (this generator pins %s)" % (k, got, v or "(unset)"))
    if bad:
        sys.exit("ABORT: the environment sets %d value(s) gen_jc_card.py pins:\n  %s\n"
                 "The Jungle Cat card's configuration is fixed in this file; unset them "
                 "(the core clock is %s)." % (len(bad), "\n  ".join(bad), CLK_CORE_ENV))


# ==== jc_ctl_core PORT TABLE ==========================================================
# THE ONE PLACE THE USER3 CONTROL CORE'S BD FACE IS NAMED.  Its RTL (rtl/jc_ctl_core.vhd,
# plan Task 4) was being written in parallel when this was generated; when it lands,
# update THIS TABLE to its entity and regenerate.  Rules the entity must keep
# (hw/fk33/CLAUDE.md block-design traps): the module-reference top is VHDL-93 with
# std_logic / std_logic_vector ports, literal widths, and inputs WITHOUT defaults.
#
# BSCANE2 PLACEMENT.  Plan Task 4 makes jc_ctl_core the BSCAN-free core (its bench
# drives TCK directly) and hw/jc/ctl/rtl/jc_ctl_rx.vhd the BSCANE2 JTAG_CHAIN => 3 +
# BUFG wrapper, jc_frame_rx's shape.  So jc_card_top.vhd instantiates jc_ctl_rx and the
# six JTAG signals cross into the BD as external ports (CTL_JTAG).  If jc_ctl_core
# instead swallows jc_ctl_rx, empty CTL_JTAG and set CTL_RX_ENTITY = None.
CTL_MODULE = "jc_ctl_core"        # create_bd_cell -type module -reference <this>
CTL_CELL = "ctl"
CTL_CLK = "aclk"                  # clk_core
CTL_RST = "arst"                  # active HIGH, from core_reset/peripheral_reset
CTL_AXIL_INTF = "m_axil"          # AXI-Lite master (32-bit addr/data) -> axil2eng/S00_AXI
CTL_MEM_INTF = "m_axi"            # AXI4 read-only master (33-bit addr, 256-bit data,
                                  #   ARLEN <= 15) -> hbm_sc/S01_AXI -> hbm/SAXI_16
# (ctl pin, direction seen from the ctl core, BD external port, jc_ctl_rx pin)
CTL_JTAG = [
    ("tck",     "in",  "ctl_tck",     "tck_o"),
    ("sel",     "in",  "ctl_sel",     "sel_o"),
    ("capture", "in",  "ctl_capture", "capture_o"),
    ("shift",   "in",  "ctl_shift",   "shift_o"),
    ("tdi",     "in",  "ctl_tdi",     "tdi_o"),
    ("tdo",     "out", "ctl_tdo",     "tdo_i"),
]
CTL_RX_ENTITY = "jc_ctl_rx"       # in jc_card_top.vhd; BSCANE2 JTAG_CHAIN => 3
# ==== end jc_ctl_core PORT TABLE ======================================================

LOADER_CELL = "loader"
LOADER_INTF = "m_axi"
HBM_SC_CELL = "hbm_sc"
CORE_CLK = "clk_wiz_0/clk_out3"
CORE_RSTN = "core_reset/peripheral_aresetn"
CORE_RST = "core_reset/peripheral_reset"
APB_CLK = "clk_wiz_0/clk_out1"
REF_CLK = "clk_wiz_0/clk_out2"
# Board pins.  The names are the loader BD's, so jc_loader.xdc's lines apply verbatim.
TOP_PORTS = [("sysclk_clk_p", "in"), ("sysclk_clk_n", "in"), ("fan_ctl", "out"),
             ("LED_A", "out"), ("LED_B", "out"), ("LED_C", "out"), ("LED_D", "out")]
LOADER_PINS = [("fan_ctl", "fan_ctl"), ("led_a", "LED_A"), ("led_b", "LED_B"),
               ("led_c", "LED_C"), ("led_d", "LED_D")]
N_MODULE_REFS = 6     # loader, ctl, eng, fk33_seam_0, card, bcgrant


def _c(a, b):
    """One connect_bd_net with exactly two endpoints (gen_pcieep's net parser and the
    reset-topology check read two-endpoint lines only)."""
    return "connect_bd_net [get_bd_pins %s] [get_bd_pins %s]" % (a, b)


# ---- board sections (no gen_pcieep needed; the test calls these directly) -------------
def clock_lines(mhz):
    L = [
        "",
        "# ---- clocks and resets (hw/jc/loader/jc_loader_bd.tcl's, clk_out3 = clk_core) ---",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 sysclk_buf",
        "set_property CONFIG.C_BUF_TYPE {IBUFDS} [get_bd_cells sysclk_buf]",
        "make_bd_intf_pins_external [get_bd_intf_pins sysclk_buf/CLK_IN_D]",
        "set_property name sysclk [get_bd_intf_ports CLK_IN_D_0]",
        "set_property CONFIG.FREQ_HZ 200000000 [get_bd_intf_ports sysclk]",
        "",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0",
        "set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_0]",
        "set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {200.000} \\",
        "  CONFIG.USE_RESET {false} \\",
        "  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \\",
        "  CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \\",
        "  CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {%.3f}] [get_bd_cells clk_wiz_0]" % mhz,
        "foreach {k v} {PRIM_SOURCE No_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ 100.000",
        "               CLKOUT2_REQUESTED_OUT_FREQ 200.000 CLKOUT3_REQUESTED_OUT_FREQ %.3f} {" % mhz,
        "  jcc_want clk_wiz_0 $k $v",
        "}",
        _c("sysclk_buf/IBUF_OUT", "clk_wiz_0/clk_in1"),
        "",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one",
        "set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] [get_bd_cells one]",
        "# core_reset is named as on the FK33 because gen_pcieep.py's card, seam and grant",
        "# sections name it.  Its ext_reset_in is tied high (not in reset): left unconnected",
        "# it would be tied to zero and hold the domain in reset forever.  There is no",
        "# host-link reset on this board; the domain leaves reset when the MMCM locks.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 core_reset",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 apb_rst",
        _c("clk_wiz_0/locked", "core_reset/dcm_locked"),
        _c("clk_wiz_0/locked", "apb_rst/dcm_locked"),
        _c("one/dout", "core_reset/ext_reset_in"),
        _c("one/dout", "apb_rst/ext_reset_in"),
        _c(CORE_CLK, "core_reset/slowest_sync_clk"),
        _c(APB_CLK, "apb_rst/slowest_sync_clk"),
    ]
    return L


def hbm_lines(mhz):
    L = [
        "",
        "# ---- HBM: 2 stacks, 8 GB, all 32 SAXI on clk_core ---------------------------------",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm",
        "set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \\",
        "  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]",
        "set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200}] [get_bd_cells hbm]",
        "# The AXI clock both stacks are told to expect: clk_core, the net every AXI_nn_ACLK",
        "# below is on.",
        "set_property CONFIG.USER_AXI_INPUT_CLK_FREQ {%d} [get_bd_cells hbm]" % mhz,
        "set_property CONFIG.USER_AXI_INPUT_CLK1_FREQ {%d} [get_bd_cells hbm]" % mhz,
        "set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]",
        "set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]",
    ]
    L += ["set_property CONFIG.USER_SAXI_%02d {true} [get_bd_cells hbm]" % n for n in range(32)]
    L += [
        "set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]",
        "foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200",
        "               USER_HBM_REF_CLK_1 200 USER_AXI_INPUT_CLK_FREQ %d USER_AXI_INPUT_CLK1_FREQ %d"
        % (mhz, mhz),
        "               USER_SWITCH_ENABLE_00 TRUE USER_SWITCH_ENABLE_01 TRUE",
        "               USER_CLK_SEL_LIST0 AXI_00_ACLK USER_CLK_SEL_LIST1 AXI_16_ACLK USER_APB_EN false} {",
        "  jcc_want hbm $k $v",
        "}",
        "for {set i 0} {$i < 32} {incr i} { jcc_want hbm [format USER_SAXI_%02d $i] true }",
        _c(APB_CLK, "hbm/APB_0_PCLK"),
        _c(APB_CLK, "hbm/APB_1_PCLK"),
        _c("apb_rst/peripheral_aresetn", "hbm/APB_0_PRESET_N"),
        _c("apb_rst/peripheral_aresetn", "hbm/APB_1_PRESET_N"),
        _c(REF_CLK, "hbm/HBM_REF_CLK_0"),
        _c(REF_CLK, "hbm/HBM_REF_CLK_1"),
        "# SAXI_00 (loader) and SAXI_16 (hbm_sc).  The other 30 ports' ACLK/ARESET_N are",
        "# connected where their masters are: the engine's 28 and the grant's 2, below.",
        _c(CORE_CLK, "hbm/AXI_00_ACLK"),
        _c(CORE_RSTN, "hbm/AXI_00_ARESET_N"),
        _c(CORE_CLK, "hbm/AXI_16_ACLK"),
        _c(CORE_RSTN, "hbm/AXI_16_ARESET_N"),
    ]
    return L


def loader_lines():
    L = [
        "",
        "# ---- the USER4 loader (jc_loader_top, unchanged; hw/jc/loader/jc_loader_bd.tcl) ---",
        "create_bd_cell -type module -reference jc_loader_top %s" % LOADER_CELL,
        "set_property CONFIG.DNA_DIV {10} [get_bd_cells %s]" % LOADER_CELL,
        "jcc_want %s DNA_DIV 10" % LOADER_CELL,
        "# One clock port, so Vivado infers aclk's ASSOCIATED_BUSIF itself (setting it is",
        "# CRITICAL WARNING BD 41-737 on this cell).  Read back.",
        "set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/aclk]]" % LOADER_CELL,
        "if {[lsearch -exact [split $_ab :] %s] < 0} {" % LOADER_INTF,
        "  error \"JCCARD_BD FAIL: %s/aclk ASSOCIATED_BUSIF is \\\"$_ab\\\", %s missing\""
        % (LOADER_CELL, LOADER_INTF),
        "}",
        "puts \"JCCARD_BD %s/aclk ASSOCIATED_BUSIF $_ab\"" % LOADER_CELL,
        "if {[llength [get_bd_intf_pins -quiet %s/%s]] != 1} {" % (LOADER_CELL, LOADER_INTF),
        "  error \"JCCARD_BD FAIL: no inferred %s interface on the loader cell\"" % LOADER_INTF,
        "}",
        _c(CORE_CLK, "%s/aclk" % LOADER_CELL),
        "# arst is a plain active-high data input on this cell (the loader registers it",
        "# with the HBM-ready hold), so it takes peripheral_reset.",
        _c(CORE_RST, "%s/arst" % LOADER_CELL),
        _c("hbm/DRAM_0_STAT_CATTRIP", "%s/hbm_cattrip0" % LOADER_CELL),
        _c("hbm/DRAM_1_STAT_CATTRIP", "%s/hbm_cattrip1" % LOADER_CELL),
        _c("hbm/apb_complete_0", "%s/hbm_ready0" % LOADER_CELL),
        _c("hbm/apb_complete_1", "%s/hbm_ready1" % LOADER_CELL),
        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins hbm/SAXI_00]"
        % (LOADER_CELL, LOADER_INTF),
    ]
    for pin, port in LOADER_PINS:
        L.append("create_bd_port -dir O %s" % port)
        L.append("connect_bd_net [get_bd_pins %s/%s] [get_bd_ports %s]" % (LOADER_CELL, pin, port))
    return L


def jtag_hbm_lines():
    return [
        "",
        "# ---- SAXI_16: jtag_hbm (spot checks) and the ctl core's read master ---------------",
        "# 64-bit address and data, as on the FK33 and the loader; the smartconnect does the",
        "# AXI4 -> AXI3 and 64 -> 256 bit conversion.  One clock (NUM_CLKS 1).",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_hbm",
        "set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]",
        "jcc_want jtag_hbm M_AXI_ADDR_WIDTH 64",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 %s" % HBM_SC_CELL,
        "set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells %s]"
        % HBM_SC_CELL,
        "connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins %s/S00_AXI]" % HBM_SC_CELL,
        "connect_bd_intf_net [get_bd_intf_pins %s/M00_AXI] [get_bd_intf_pins hbm/SAXI_16]" % HBM_SC_CELL,
        _c(CORE_CLK, "jtag_hbm/aclk"),
        _c(CORE_RSTN, "jtag_hbm/aresetn"),
        _c(CORE_CLK, "%s/aclk" % HBM_SC_CELL),
        _c(CORE_RSTN, "%s/aresetn" % HBM_SC_CELL),
    ]


def ctl_lines():
    intfs = "%s:%s" % (CTL_AXIL_INTF, CTL_MEM_INTF)
    L = [
        "",
        "# ---- the USER3 control core (%s; port table in gen_jc_card.py) -------------" % CTL_MODULE,
        "create_bd_cell -type module -reference %s %s" % (CTL_MODULE, CTL_CELL),
        "foreach i [get_bd_intf_pins -quiet %s/*] { puts \"JCCARD_BD INTF %s [file tail $i]\" }"
        % (CTL_CELL, CTL_CELL),
        "foreach i {%s %s} {" % (CTL_AXIL_INTF, CTL_MEM_INTF),
        "  if {[llength [get_bd_intf_pins -quiet %s/$i]] != 1} {" % CTL_CELL,
        "    error \"JCCARD_BD FAIL: no inferred interface %s/$i (gen_jc_card.py CTL table)\"" % CTL_CELL,
        "  }",
        "}",
        "# TWO clock-like pins (aclk and the BSCAN tck) can defeat ASSOCIATED_BUSIF inference,",
        "# which defaults every interface to 100 MHz (the FK33 engine's BD 41-237 trap).  Set",
        "# it only if inference did not (setting it where it is read-only is BD 41-737).",
        "set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/%s]]" % (CTL_CELL, CTL_CLK),
        "if {[lsearch -exact [split $_ab :] %s] < 0 || [lsearch -exact [split $_ab :] %s] < 0} {"
        % (CTL_AXIL_INTF, CTL_MEM_INTF),
        "  set_property CONFIG.ASSOCIATED_BUSIF {%s} [get_bd_pins %s/%s]" % (intfs, CTL_CELL, CTL_CLK),
        "  set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/%s]]" % (CTL_CELL, CTL_CLK),
        "}",
        "foreach i {%s %s} {" % (CTL_AXIL_INTF, CTL_MEM_INTF),
        "  if {[lsearch -exact [split $_ab :] $i] < 0} {",
        "    error \"JCCARD_BD FAIL: %s/%s ASSOCIATED_BUSIF is \\\"$_ab\\\", $i missing\""
        % (CTL_CELL, CTL_CLK),
        "  }",
        "}",
        "puts \"JCCARD_BD %s/%s ASSOCIATED_BUSIF $_ab\"" % (CTL_CELL, CTL_CLK),
        _c(CORE_CLK, "%s/%s" % (CTL_CELL, CTL_CLK)),
        "if {[get_property TYPE [get_bd_pins %s/%s]] eq \"rst\"} {" % (CTL_CELL, CTL_RST),
        "  set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_pins %s/%s]" % (CTL_CELL, CTL_RST),
        "}",
        _c(CORE_RST, "%s/%s" % (CTL_CELL, CTL_RST)),
    ]
    if CTL_JTAG:
        L.append("# The USER3 BSCANE2 lives in jc_card_top.vhd (%s); its six signals enter"
                 % CTL_RX_ENTITY)
        L.append("# the BD as plain external ports.  TCK's clock constraint goes on the")
        L.append("# primitive's INTERNAL_TCK pin in the build's timing script, as the loader's.")
        for pin, d, port, _ in CTL_JTAG:
            L.append("create_bd_port -dir %s %s" % ("I" if d == "in" else "O", port))
            L.append("connect_bd_net [get_bd_pins %s/%s] [get_bd_ports %s]" % (CTL_CELL, pin, port))
        L.append("puts \"JCCARD_BD %s/tck TYPE [get_property TYPE [get_bd_pins %s/tck]]\""
                 % (CTL_CELL, CTL_CELL))
    L += [
        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins %s/S01_AXI]"
        % (CTL_CELL, CTL_MEM_INTF, HBM_SC_CELL),
        "",
        "# axil2eng: the control interconnect, named as on the FK33 because gen_pcieep.py's",
        "# seam section appends its master to it (NUM_MI + 1) and its card section replaces",
        "# M00's net with engctl.  On the FK33 it crosses from xdma's domain into the core",
        "# domain; here its one slave is the ctl core, on the same clock.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2eng",
        "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {1}] [get_bd_cells axil2eng]",
        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins axil2eng/S00_AXI]"
        % (CTL_CELL, CTL_AXIL_INTF),
        _c(CORE_CLK, "axil2eng/aclk"),
        _c(CORE_RSTN, "axil2eng/aresetn"),
    ]
    return L


# ---- sections built from gen_pcieep.py --------------------------------------------------
def eng_lines(P):
    L = P._eng_cell_lines()
    L += [
        "# ON THIS BOARD core_clk AND hbm_aclk ARE THE SAME NET, clk_core.  The engine's",
        "# internal crossing (axi_rd_port's async FIFO) is still present and is crossed",
        "# between equal clocks; no AXI clock converter sits between the engine and HBM.",
        _c(CORE_CLK, "%s/core_clk" % P.ENG_CELL),
        _c(CORE_RSTN, "%s/core_aresetn" % P.ENG_CELL),
        _c(CORE_CLK, "%s/hbm_aclk" % P.ENG_CELL),
        "",
        "# THE THERMAL HALT IS TIED LOW.  The FK33 drives it from fk33_thermal (SYSMON and",
        "# the HBM temperature outputs); the Jungle Cat has no thermal guard in the fabric",
        "# yet.  A gap, recorded in gen_jc_card.py's docstring, not a design choice.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 halt_z",
        "set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells halt_z]",
        _c("halt_z/dout", "%s/compute_halt" % P.ENG_CELL),
        "",
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins %s/s_axi]" % P.ENG_CELL,
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/M01_AXI] [get_bd_intf_pins %s/s_axix]" % P.ENG_CELL,
        "",
    ]
    L += P._eng_hbm_lines(CORE_CLK, CORE_RSTN)
    L += ["# ---- end subsystem A ------------------------------------------------------", ""]
    return L


def card_lines(P):
    one = (CORE_CLK, CORE_RSTN)
    L = P._card_cells_lines()
    L += [
        "# CLOCKS.  Both cells sit wholly in the core domain, %s, which on this" % CORE_CLK,
        "# board also clocks every HBM AXI port, so the grant's masters reach the HBM",
        "# directly (the pool section below) with no clock converter.",
        _c(CORE_CLK, "%s/clk" % P.CARD_CELL),
        _c(CORE_CLK, "%s/clk" % P.GRANT_CELL),
        "",
    ]
    L += P._card_reset_lines()
    L += P._card_aseam_lines()
    L += P._card_engctl_lines(one_clock=one)
    L += P._card_hostseam_lines()
    L += P._card_grant_lines()
    L += P._card_pool_lines(one_clock=one)
    L += P._card_grant_addr_lines()
    L += P._card_a_addr_lines()
    L += ["# ---- end subsystems B, C, D -----------------------------------------------", ""]
    return L


def addr_lines(P):
    sp = "%s/%s" % (CTL_CELL, CTL_AXIL_INTF)
    L = [
        "",
        "# ---- address map ------------------------------------------------------------------",
        "# The ctl core's AXI-Lite space carries the FK33 BAR offsets the host code already",
        "# uses: engine control, activation writer, seam.  Named target space, because card/a",
        "# also reaches eng/s_axi (assigned its 256 bytes in the card section above) and an",
        "# unqualified assign_bd_address would try to give it 4K (BD 41-1075).",
    ]
    for off, seg in ((P.ENG_CTL_BASE, "%s/s_axi/reg0" % P.ENG_CELL),
                     (P.ENG_XW_BASE, "%s/s_axix/reg0" % P.ENG_CELL),
                     (P.SEAM_BASE, "%s/s_axi/reg0" % P.SEAM_CELL)):
        L.append("assign_bd_address -offset 0x%08X -range 4K -target_address_space "
                 "[get_bd_addr_spaces %s] [get_bd_addr_segs {%s}]" % (off, sp, seg))
    L.append(P._eng_hbm_addr_text().rstrip("\n"))
    L += [
        "# The loader (SAXI_00), jtag_hbm and the ctl read master (SAXI_16 through hbm_sc):",
        "# every one sees all 32 pseudo-channel segments at their absolute addresses.",
        "foreach {sp sx} {%s/%s 00 jtag_hbm/Data 16 %s/%s 16} {"
        % (LOADER_CELL, LOADER_INTF, CTL_CELL, CTL_MEM_INTF),
        "  for {set s 0} {$s < 32} {incr s} {",
        "    assign_bd_address -target_address_space [get_bd_addr_spaces $sp] \\",
        "      -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \\",
        "      [get_bd_addr_segs [format \"hbm/SAXI_%s/HBM_MEM%02d\" $sx $s]]",
        "  }",
        "}",
        "foreach {sp want} {%s/%s 32 jtag_hbm/Data 32 %s/%s 32 %s 3} {"
        % (LOADER_CELL, LOADER_INTF, CTL_CELL, CTL_MEM_INTF, sp),
        "  set n [llength [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces $sp]]]",
        "  if {$n != $want} { error \"JCCARD_ADDR FAIL: $sp maps $n segments, not $want\" }",
        "  puts \"JCCARD_ADDR $sp maps $n segments\"",
        "}",
    ]
    return L


def check_lines(P):
    L = [P.UNCONNECTED_PIN_CHECK.rstrip("\n")]
    L += [
        "set _nmr [llength [get_bd_cells -hierarchical -quiet -filter {VLNV =~ \"*:module_ref:*\"}]]",
        "if {$_nmr != %d} {" % N_MODULE_REFS,
        "  error \"JCCARD_BD FAIL: expected %d module_ref cells, found $_nmr (the unconnected-pin check would be vacuous)\""
        % N_MODULE_REFS,
        "}",
        "puts \"JCCARD_BD module_ref_cells=$_nmr\"",
        "save_bd_design",
        "puts \"JCCARD_BD_TCL_DONE\"",
    ]
    return L


def render_tcl(P, mhz, env=None):
    head = [
        "# hw/jc/card/jc_card_bd.tcl -- GENERATED by hw/jc/card/gen_jc_card.py.",
        "# DO NOT HAND-EDIT; edit the generator (or hw/fk33/gen_pcieep.py, whose card,",
        "# seam and engine sections are emitted here by import).",
    ]
    body = [
        "#",
        "# The Jungle Cat (VU35P, no PCIe) block design `%s` for the 27B inference card." % BD_NAME,
        "# Read gen_jc_card.py's docstring for the map.  clk_core = clk_wiz_0/clk_out3 at",
        "# %d MHz clocks the engine and every HBM AXI port; there is no XDMA, no PCIe and no"
        % mhz,
        "# AXI clock converter.  Sourced inside a project that already holds the VHDL (the",
        "# 27B fk33_card wrapper, the loader, the ctl core); the build is Task 9's.",
        "#",
        "# Every set_property on an IP CONFIG is READ BACK (JCCARD_CFG lines): Vivado",
        "# silently ignores a CONFIG name an IP does not have.",
        "create_bd_design %s" % BD_NAME,
        "",
        "proc jcc_want {cell key want} {",
        "  set got [get_property CONFIG.$key [get_bd_cells $cell]]",
        "  if {[string toupper $got] ne [string toupper $want]} {",
        "    error \"JCCARD_CFG FAIL $cell.$key is \\\"$got\\\", not \\\"$want\\\"\"",
        "  }",
        "  puts \"JCCARD_CFG $cell.$key = $got\"",
        "}",
    ]
    body += clock_lines(mhz)
    body += P._core_clk_sentinel().split("\n")
    body += hbm_lines(mhz)
    body += loader_lines()
    body += jtag_hbm_lines()
    body += ctl_lines()
    body += eng_lines(P)
    body += P._seam_block().split("\n")
    body += card_lines(P)
    body += addr_lines(P)
    body += check_lines(P)
    return ("\n".join(head) + "\n" + stamp_block("#", env) + "\n".join(body) + "\n")


def render_xdc(env=None):
    src = open(LOADER_XDC).read()
    code = [l for l in src.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    out = [
        "# hw/jc/card/jc_card.xdc -- GENERATED by hw/jc/card/gen_jc_card.py.",
        "# DO NOT HAND-EDIT; edit the generator.",
        "#",
        "# Pins and the board clock, every directive of hw/jc/loader/jc_loader.xdc copied in",
        "# order (the Jungle Cat pinout proven on silicon by the loader): sysclk on",
        "# BC26/BC27, the fan on G9 and LED_A..D.  The TCK, CDC and clk_core constraints are",
        "# NOT here; as for the loader they belong in the build's timing Tcl, applied to the",
        "# opened synthesized design where a query that matches nothing stops the build.",
        "",
    ] + code
    return genstamp.append_end("\n".join(out) + "\n", stamp_block("#", env), "#")


def render_top(env=None):
    w = max(len(n) for n, _ in TOP_PORTS + [(p, d) for _, d, p, _ in CTL_JTAG])
    L = [
        "-- hw/jc/card/jc_card_top.vhd -- GENERATED by hw/jc/card/gen_jc_card.py.",
        "-- DO NOT HAND-EDIT; edit the generator.",
    ]
    L2 = [
        "--",
        "-- The Jungle Cat 27B card's synthesis top: the block design `%s` (through the" % BD_NAME,
        "-- wrapper make_wrapper writes, instantiated as a COMPONENT so the wrapper's",
        "-- language does not matter) and the USER3 BSCANE2 wrapper %s (JTAG_CHAIN => 3)," % CTL_RX_ENTITY,
        "-- whose six signals enter the BD as the ctl_* ports.  The USER4 BSCANE2 is inside",
        "-- the BD, in jc_loader_top's jc_frame_rx, unchanged.  One of each chain.",
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "",
        "entity jc_card_top is",
        "  port(",
    ]
    ports = ["    %-*s : %-3s std_logic" % (w, n, d) for n, d in TOP_PORTS]
    L2 += [p + (";" if i < len(ports) - 1 else "") for i, p in enumerate(ports)]
    L2 += ["  );", "end entity;", "", "architecture rtl of jc_card_top is",
           "  component %s_wrapper is" % BD_NAME, "    port("]
    cports = (["      %-*s : %-3s std_logic" % (w, n, d) for n, d in TOP_PORTS]
              + ["      %-*s : %-3s std_logic" % (w, p, "out" if d == "in" else "in")
                 for _, d, p, _ in CTL_JTAG])
    L2 += [p + (";" if i < len(cports) - 1 else "") for i, p in enumerate(cports)]
    L2 += ["    );", "  end component;"]
    if CTL_JTAG:
        L2.append("  signal %s : std_logic;" % ", ".join(p for _, _, p, _ in CTL_JTAG))
    L2 += ["begin"]
    if CTL_JTAG and CTL_RX_ENTITY:
        maps = ["%s => %s" % (rx, p) for _, _, p, rx in CTL_JTAG]
        L2 += ["  u_%s : entity work.%s" % (CTL_RX_ENTITY, CTL_RX_ENTITY),
               "    port map(" + ",\n             ".join(maps) + ");", ""]
    bmaps = (["%s => %s" % (n, n) for n, _ in TOP_PORTS]
             + ["%s => %s" % (p, p) for _, _, p, _ in CTL_JTAG])
    L2 += ["  u_bd : %s_wrapper" % BD_NAME,
           "    port map(" + ",\n             ".join(bmaps) + ");",
           "end architecture;"]
    return "\n".join(L) + "\n" + stamp_block("--", env) + "\n".join(L2) + "\n"


# ---- running ----------------------------------------------------------------------------
def card_is_jc(path=CARD_RTL):
    """(True, rows) if the card wrapper's GENSTAMP equals JC_CARD_ENV."""
    rows = genstamp.read_inputs(path)
    got = {n: v for k, n, v in rows if k == "env"}
    return got == JC_CARD_ENV, got


def load_pcieep(mhz):
    """Import hw/fk33/gen_pcieep.py under the pinned environment."""
    want = pcieep_env(mhz)
    for k, v in want.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    saved = sys.argv
    sys.argv = [os.path.join(REPO, "hw", "fk33", "gen_pcieep.py")]
    sys.path.insert(0, os.path.join(REPO, "hw", "fk33"))
    try:
        import gen_pcieep as P
    finally:
        sys.path.pop(0)
        sys.argv = saved
    if set(P.STAMP_ENV_NAMES) != set(want):
        sys.exit("ABORT: gen_pcieep.py's inputs are now %s; gen_jc_card.py pins %s. "
                 "Pin the new one(s) in pcieep_env()." % (sorted(P.STAMP_ENV_NAMES), sorted(want)))
    refusal = P.card_lever_refusal(os.environ)
    if refusal:
        sys.exit(refusal)
    return P


def generate_in_place(outdir):
    mhz = clk_core_mhz()
    ok, got = card_is_jc()
    if not ok:
        sys.exit("ABORT: %s was generated with %s, not the Jungle Cat card's %s. "
                 "Regenerate it with gen_fk33_card.py under that environment, or run "
                 "without --in-place." % (os.path.relpath(CARD_RTL, REPO), got, JC_CARD_ENV))
    P = load_pcieep(mhz)
    tcl = render_tcl(P, mhz)
    # gen_pcieep.py's own refusals, on THIS text.
    P.check_reset_topology(tcl)
    P.check_seam_tieoff(tcl)
    outs = {OUT_TCL: tcl, OUT_XDC: render_xdc(), OUT_TOP: render_top()}
    for name, text in outs.items():
        with open(os.path.join(outdir, name), "w") as f:
            f.write(text)
        print("wrote %s (%d bytes)" % (os.path.join(outdir, name), len(text)))


def _scratch_dir(argv):
    if "--scratch" in argv:
        i = argv.index("--scratch")
        if i + 1 >= len(argv):
            sys.exit("gen_jc_card.py: --scratch needs a directory")
        return os.path.abspath(argv[i + 1])
    return os.path.join(os.path.expanduser("~"), "regress_scratch", "gen_jc_card")


def _populate(scratch):
    """Copy the tracked tree's working-tree files that the generators read into
    `scratch`, plus this generator.  Refuses to reuse a directory it did not make."""
    if os.path.exists(scratch):
        if not os.path.exists(os.path.join(scratch, SCRATCH_MARK)):
            sys.exit("ABORT: %s exists and is not a gen_jc_card scratch directory "
                     "(no %s); refusing to clear it." % (scratch, SCRATCH_MARK))
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    open(os.path.join(scratch, SCRATCH_MARK), "w").write("gen_jc_card.py scratch\n")
    r = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, stdout=subprocess.PIPE, check=True)
    keep = ("rtl/", "tools/", "hw/fk33/", "hw/jc/", "server/")
    skip = ("hw/fk33/results/", "hw/fk33/bit/", "hw/jc/loader/results/",
            "hw/jc/pinfinder/results/")
    # sim/*.py: tools/gen_bd_wrapper.py (gen_fk33_card.py's library) imports
    # sim/check_bd_ports.py.
    files = [f for f in r.stdout.decode().split("\0")
             if (f.startswith(keep) and not f.startswith(skip))
             or (f.startswith("sim/") and f.endswith(".py"))]
    files.append(os.path.relpath(os.path.abspath(__file__), REPO))
    n = 0
    for f in sorted(set(files)):
        src = os.path.join(REPO, f)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(scratch, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        n += 1
    print("gen_jc_card: %d tracked files copied into %s" % (n, scratch))


def generate_via_scratch(outdir, scratch):
    _populate(scratch)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FK33_")}
    cenv = dict(env)
    cenv.update({k: v for k, v in JC_CARD_ENV.items() if v is not None})
    r = subprocess.run([sys.executable, "hw/fk33/gen_fk33_card.py"], cwd=scratch, env=cenv)
    if r.returncode != 0:
        sys.exit("ABORT: gen_fk33_card.py failed in %s (rc=%d)" % (scratch, r.returncode))
    me = os.path.join(scratch, os.path.relpath(os.path.abspath(__file__), REPO))
    r = subprocess.run([sys.executable, me, "--in-place", "--emit-to", outdir],
                       cwd=scratch, env=env)
    if r.returncode != 0:
        sys.exit("ABORT: gen_jc_card.py failed in %s (rc=%d)" % (scratch, r.returncode))


def main(argv):
    _refuse_conflicting_env(clk_core_mhz())
    outdir = HERE
    if "--emit-to" in argv:
        i = argv.index("--emit-to")
        if i + 1 >= len(argv) or not os.path.isdir(argv[i + 1]):
            sys.exit("gen_jc_card.py: --emit-to needs an existing directory")
        outdir = os.path.abspath(argv[i + 1])
    if "--check" in argv:
        scratch = _scratch_dir(argv)
        chk = scratch + "_check_out"
        if os.path.exists(chk):
            if not os.path.exists(os.path.join(chk, SCRATCH_MARK)):
                sys.exit("ABORT: %s exists and is not ours" % chk)
            shutil.rmtree(chk)
        os.makedirs(chk)
        open(os.path.join(chk, SCRATCH_MARK), "w").write("gen_jc_card.py check\n")
        generate_via_scratch(chk, scratch)
        stale = []
        for name in (OUT_TCL, OUT_XDC, OUT_TOP):
            a = open(os.path.join(HERE, name)).read() if os.path.exists(os.path.join(HERE, name)) else None
            b = open(os.path.join(chk, name)).read()
            print("JCCARD_CHECK: %s %s" % ("OK" if a == b else "STALE", name))
            if a != b:
                stale.append(name)
        if stale:
            sys.exit("JCCARD_CHECK: STALE %s" % ", ".join(stale))
        print("JCCARD_CHECK: PASS")
        return
    if "--in-place" in argv or card_is_jc()[0]:
        generate_in_place(outdir)
    else:
        generate_via_scratch(outdir, _scratch_dir(argv))


if __name__ == "__main__":
    main(sys.argv[1:])
