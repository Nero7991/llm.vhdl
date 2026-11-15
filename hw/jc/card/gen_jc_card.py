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
    tok (jc_tok_top)             the on-fabric token loop (plan 2026-11-04 Task 7):
                                 s_host <- axil2eng at 0xE000 (the host's seam window;
                                 the seam sits BEHIND it on tok/m_seam), s_ctl <- axil2eng
                                 at 0x20000 (64K, the loop's registers), m_hbm -> hbm_sc
                                 S02 (the embedding gather), m_axis_tx/s_axis_rx <-> aur
    gtgclk (jc_gtg_clk)          156.25 MHz for the QPLL's GTGREFCLK (through the netlist
                                 ECO, build_card.tcl) and init_clk 1250/INIT_DIV MHz
    aur (Aurora 64B66B, IP)      1 lane, TX/RX simplex, 10.3125 Gb/s, GTYE4_CHANNEL_X0Y0;
                                 every input not driven by tok/gtgclk is tied from
                                 hw/jc/link/aurora_ties.py (tie_<port> xlconstant cells)
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
HBM temperature outputs.  The Jungle Cat has no fabric thermal guard, so compute_halt
is the OR of the two HBM stacks' DRAM_x_STAT_CATTRIP (ruling, review round 1): an
HBM over-temperature trip stops new A jobs.  There is no die-temperature halt.

THE 27B MODEL PACKAGE.  hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd is written by
gen_pcieep.model_pkg_text() (gen_pcieep.py's own writer for it) and committed; the BD
Tcl adds it to the project, refuses rtl/model_cfg_pkg.vhd, and reads back the card's
hr_addr/hw_addr width (HADDR_W 15, the 27B wrapper's) and the seam's REGMAX/HADDR_W.

INPUTS.  Three, stamped: JC_CLK_CORE_MHZ (integer MHz, 50..250, default 200);
JC_LINK_RATE (10.3125 only: the 1.25 Gb/s core has no GTYE4_COMMON for the gtg ECO and
its quad has no board refclk, Task 5 ruling); JC_LINK_REFCLK (gtg only, the default; pin
is refused, final ruling 2026-11-11: AK38/AK39 are undriven on the board; build_card.tcl
reads it from this GENSTAMP and refuses anything but gtg).  The
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
    link_rate(env)
    link_refclk(env)
    a_split(env)
    return [("env", CLK_CORE_ENV, env.get(CLK_CORE_ENV) or None),
            ("env", LINK_RATE_ENV, env.get(LINK_RATE_ENV) or None),
            ("env", LINK_REFCLK_ENV, env.get(LINK_REFCLK_ENV) or None),
            ("env", A_TILED_ENV, env.get(A_TILED_ENV) or None),
            ("env", A_SPLIT_ENV, env.get(A_SPLIT_ENV) or None)]


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
N_MODULE_REFS = 8     # loader, ctl, eng, fk33_seam_0, card, bcgrant, tok, gtgclk

# ==== the token loop and the die-to-die link (plan 2026-11-04 Task 7) ===================
TOK_MODULE, TOK_CELL = "jc_tok_top", "tok"
GTG_MODULE, GTG_CELL = "jc_gtg_clk", "gtgclk"
AUR_VLNV, AUR_CELL = "xilinx.com:ip:aurora_64b66b:12.0", "aur"
TOK_CTL_BASE = 0x00020000
TOK_N_EMBD = 5120                                 # the 27B model's embedding width
LINK_NLANES = 1                                   # spec 1b.2: first build, GTYE4_CHANNEL_X0Y0
LINK_RATE_ENV, LINK_REFCLK_ENV = "JC_LINK_RATE", "JC_LINK_REFCLK"
AURORA_CFG = os.path.join(REPO, "hw", "jc", "link", "aurora_cfg.tcl")
AUR_WRAP = os.path.join(REPO, "hw", "jc", "link", "rtl", "jc_aurora_wrap_l1.vhd")
GT_TOP_PORTS = [("gt_tx_txp", "out", 1), ("gt_tx_txn", "out", 1),
                ("gt_rx_rxp", "in", 1), ("gt_rx_rxn", "in", 1),
                ("gt_refclk_clk_p", "in", None), ("gt_refclk_clk_n", "in", None)]
# The MMCM site and its input net (IBERT G's; Task 5 ruling: in a BD the module reference
# sits under `inst`, so the plan's *gtgclk/u_mmcm matches nothing; *gtgclk/*u_mmcm matches one).
GTG_MMCM_LOC = "MMCM_X0Y2"
GTG_MMCM_PAT = "*%s/*u_mmcm" % GTG_CELL
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))
import aurora_ties  # noqa: E402


def refclk_pins():
    """[P, N] package pins of the Aurora core's nominal refclk, read from aurora_cfg.tcl's
    JC_REFCLK_PINS (Task 5 ruling: MGTREFCLK0 of quad X0Y0, AK38/AK39, UNDRIVEN on the board;
    the gtg ECO moves the QPLL to GTGREFCLK so the pin is never used). Read, not copied, so
    the IP's pick and the XDC cannot differ."""
    m = re.search(r"^set JC_REFCLK_PINS \{(\w+) (\w+)\}", open(AURORA_CFG).read(), re.M)
    if not m:
        sys.exit("ABORT: no `set JC_REFCLK_PINS {P N}` in %s" % AURORA_CFG)
    return [m.group(1), m.group(2)]


def link_rate(env=None):
    """JC_LINK_RATE. Only 10.3125 is built: the 1.25 Gb/s core (l1slow) runs the CPLL with no
    GTYE4_COMMON, so the gtg ECO cannot give it a refclk and the board drives none on that
    quad (Task 5 ruling: the fallback is not usable on silicon as configured)."""
    env = os.environ if env is None else env
    v = env.get(LINK_RATE_ENV) or "10.3125"
    if v == "1.25":
        sys.exit("ABORT: %s=1.25: the 1.25 Gb/s core has no GTYE4_COMMON, so the gtg ECO cannot "
                 "apply and its quad has no board refclk (Task 5 ruling); not wired into the card"
                 % LINK_RATE_ENV)
    if v != "10.3125":
        sys.exit("ABORT: %s=%s; the built rate is 10.3125 (spec 1b.2)" % (LINK_RATE_ENV, v))
    return v


def link_refclk(env=None):
    env = os.environ if env is None else env
    v = env.get(LINK_REFCLK_ENV) or "gtg"
    if v == "pin":
        pp, pn = refclk_pins()
        sys.exit("ABORT: %s=pin: the IP's nominal refclk pins %s/%s (MGTREFCLK0 of quad X0Y0) are "
                 "undriven on the Jungle Cat board, so the link could never lock (final ruling "
                 "2026-11-11; Task 5 refclk ruling). Use gtg." % (LINK_REFCLK_ENV, pp, pn))
    if v != "gtg":
        sys.exit("ABORT: %s=%s; only gtg (jc_gtg_clk's MMCM on GTGREFCLK, the ECO) is built"
                 % (LINK_REFCLK_ENV, v))
    return v


# ---- the a450 subsystem A (plan 2026-11-12-a450-per-port-tiles, Tasks 8 and 9) -------
# JC_A_TILED=1 builds rtl/mv4i_tiled.vhd behind the engine's descriptor plane (the same
# values bit for bit).  JC_A_CLK_SPLIT=1 (needs JC_A_TILED=1) adds aclk_a, a second MMCM
# at ACLK_A_MHZ on clk_out2, moves the engine's hbm_aclk and all 32 HBM AXI ports onto
# it, and puts the four non-engine HBM masters (loader SAXI_00, hbm_sc SAXI_16, the B/C
# grant SAXI_30/31) behind clock converters.  Both unset: the card as it is.
A_TILED_ENV = "JC_A_TILED"
A_SPLIT_ENV = "JC_A_CLK_SPLIT"
ACLK_A = "clk_wiz_a/clk_out1"
ACLK_A_RSTN = "aclk_reset/peripheral_aresetn"
ACLK_A_MHZ = 450


def _flag(env, name):
    v = env.get(name) or "0"
    if v not in ("0", "1"):
        sys.exit("ABORT: %s=%r; it is 0 or 1" % (name, v))
    return v == "1"


def a_tiled(env=None):
    env = os.environ if env is None else env
    return _flag(env, A_TILED_ENV)


def a_split(env=None):
    env = os.environ if env is None else env
    split = _flag(env, A_SPLIT_ENV)
    if split and not a_tiled(env):
        sys.exit("ABORT: %s=1 needs %s=1: only the tiled A has an aclk_a domain"
                 % (A_SPLIT_ENV, A_TILED_ENV))
    return split


def aurora_core_ports():
    """[(name, dir, width or None)] of the Aurora core, from the committed wrapper's component
    (generated from the IP's own stub by hw/jc/link/gen_aurora_wrap.py)."""
    t = open(AUR_WRAP).read()
    comp = t[t.index("component jc_aurora"):t.index("end component")]
    out = []
    for m in re.finditer(r"^\s*(\w+)\s*:\s*(in|out)\s+std_logic(?:_vector\((\d+) (?:downto|to) (\d+)\))?",
                         comp, re.M):
        w = None if m.group(3) is None else abs(int(m.group(3)) - int(m.group(4))) + 1
        out.append((m.group(1), m.group(2), w))
    if not out:
        sys.exit("ABORT: no ports parsed from %s" % AUR_WRAP)
    return out


def link_lines():
    """tok, gtgclk, aur and the ties. Emitted BEFORE the seam block, which then connects
    axil2eng's new MI to tok/s_host instead of fk33_seam_0/s_axi (render_tcl)."""
    rate, T = link_rate(), aurora_ties
    L = [
        "",
        "# ---- the token loop (jc_tok_top) and the die-to-die link (plan 2026-11-04) ---------",
        "source [file join $jcc_repo hw jc link aurora_cfg.tcl]",
        "# TXPOL_MASK is the lane table's TX polarity (lane 0 MEASURED 0, aurora_cfg.tcl).",
        "if {[jc_lane_txpol %d] ne \"0\"} {" % LINK_NLANES,
        "  error \"JCCARD_BD FAIL: aurora_cfg.tcl lane TX polarity is [jc_lane_txpol %d], the card emits TXPOL_MASK 0\""
        % LINK_NLANES,
        "}",
        "create_bd_cell -type module -reference %s %s" % (TOK_MODULE, TOK_CELL),
        "set_property -dict [list CONFIG.N_EMBD {%d} CONFIG.NLANES {%d} CONFIG.HAS_GATHER {true} "
        "CONFIG.TXPOL_MASK {0}] [get_bd_cells %s]" % (TOK_N_EMBD, LINK_NLANES, TOK_CELL),
        "foreach {k v} {N_EMBD %d NLANES %d HAS_GATHER true TXPOL_MASK 0} { jcc_want %s $k $v }"
        % (TOK_N_EMBD, LINK_NLANES, TOK_CELL),
        "foreach i [get_bd_intf_pins -quiet %s/*] { puts \"JCCARD_BD INTF %s [file tail $i]\" }"
        % (TOK_CELL, TOK_CELL),
        "foreach i {s_host m_seam s_ctl m_hbm m_axis_tx s_axis_rx} {",
        "  if {[llength [get_bd_intf_pins -quiet %s/$i]] != 1} {" % TOK_CELL,
        "    error \"JCCARD_BD FAIL: no inferred interface %s/$i\"" % TOK_CELL,
        "  }",
        "}",
    ]
    L += [
        "# The clock association is EXACT, not a superset: without rtl/jc_tok_top.vhd's",
        "# X_INTERFACE_PARAMETER attributes Vivado put all six interfaces on aclk (AXIS too) and",
        "# then refused the set (BD 41-737, read-only; MEASURED jcloop_bd1).",
    ]
    for clk, intfs in (("aclk", "s_host:m_seam:s_ctl:m_hbm"), ("user_clk", "m_axis_tx:s_axis_rx")):
        L += [
            "set _ab [get_property CONFIG.ASSOCIATED_BUSIF [get_bd_pins %s/%s]]" % (TOK_CELL, clk),
            "if {[lsort [split $_ab :]] ne [lsort [split {%s} :]]} {" % intfs,
            "  error \"JCCARD_BD FAIL: %s/%s ASSOCIATED_BUSIF is \\\"$_ab\\\", not exactly %s\""
            % (TOK_CELL, clk, intfs),
            "}",
            "puts \"JCCARD_BD %s/%s ASSOCIATED_BUSIF $_ab\"" % (TOK_CELL, clk),
        ]
    L += [
        _c(CORE_CLK, "%s/aclk" % TOK_CELL),
        "if {[get_property TYPE [get_bd_pins %s/arst]] eq \"rst\"" % TOK_CELL,
        "    && [string toupper [get_property CONFIG.POLARITY [get_bd_pins %s/arst]]] ne \"ACTIVE_HIGH\"} {" % TOK_CELL,
        "  set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_pins %s/arst]" % TOK_CELL,
        "}",
        _c(CORE_RST, "%s/arst" % TOK_CELL),
        "connect_bd_intf_net [get_bd_intf_pins %s/m_hbm] [get_bd_intf_pins %s/S02_AXI]" % (TOK_CELL, HBM_SC_CELL),
        "# the GTG clock (hw/jc/link/rtl/jc_gtg_clk.vhd): 156.25 MHz for the QPLL through the ECO,",
        "# and init_clk = 1250 / INIT_DIV MHz for the Aurora core (Task 5 ruling: init_clk is",
        "# this port, not sclk; C_INIT_CLK is set from the same jc_init_div by jc_aurora_config).",
        "create_bd_cell -type module -reference %s %s" % (GTG_MODULE, GTG_CELL),
        "set_property CONFIG.INIT_DIV [jc_init_div %s] [get_bd_cells %s]" % (rate, GTG_CELL),
        "jcc_want %s INIT_DIV [jc_init_div %s]" % (GTG_CELL, rate),
        "# the module reference's output clocks carry no FREQ_HZ of their own (IP_Flow 19-4751,",
        "# MEASURED jcloop_bd1); stated here so the Aurora init_clk and tok/init_clk see the real rate",
        "# (sclk is not inferred as a clock interface and has no FREQ_HZ: BD 41-1411, jcloop_bd3)",
        "foreach {pin hz} [list init_clk [expr {1250000000 / [jc_init_div %s]}] gtg_clk 156250000] {" % rate,
        "  set_property CONFIG.FREQ_HZ $hz [get_bd_pins %s/$pin]" % GTG_CELL,
        "  if {[get_property CONFIG.FREQ_HZ [get_bd_pins %s/$pin]] != $hz} {" % GTG_CELL,
        "    error \"JCCARD_BD FAIL: %s/$pin FREQ_HZ reads [get_property CONFIG.FREQ_HZ [get_bd_pins %s/$pin]], not $hz\"" % (GTG_CELL, GTG_CELL),
        "  }",
        "}",
        _c("sysclk_buf/IBUF_OUT", "%s/sys_i" % GTG_CELL),
        "create_bd_cell -type ip -vlnv %s %s" % (AUR_VLNV, AUR_CELL),
        "set _acfg [jc_aurora_config %d %s card]" % (LINK_NLANES, rate),
        "set_property -dict $_acfg [get_bd_cells %s]" % AUR_CELL,
        "# after the dict: the refclk choice depends on C_UCOLUMN_USED and C_START_QUAD",
        "jc_aurora_refclk [get_bd_cells %s]" % AUR_CELL,
        "jc_aurora_check [get_bd_cells %s] $_acfg" % AUR_CELL,
        "if {abs([get_property CONFIG.C_INIT_CLK [get_bd_cells %s]] - 1250.0 / [get_property CONFIG.INIT_DIV [get_bd_cells %s]]) > 0.001} {"
        % (AUR_CELL, GTG_CELL),
        "  error \"JCCARD_BD FAIL: %s C_INIT_CLK does not match %s INIT_DIV\"" % (AUR_CELL, GTG_CELL),
        "}",
        "foreach i [get_bd_intf_pins -quiet %s/*] { puts \"JCCARD_BD INTF %s [file tail $i]\" }"
        % (AUR_CELL, AUR_CELL),
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_DIFF_REFCLK1]" % AUR_CELL,
        "set_property name gt_refclk [get_bd_intf_ports GT_DIFF_REFCLK1_0]",
        "set_property CONFIG.FREQ_HZ 156250000 [get_bd_intf_ports gt_refclk]",
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_SERIAL_TX]" % AUR_CELL,
        "set_property name gt_tx [get_bd_intf_ports GT_SERIAL_TX_0]",
        "make_bd_intf_pins_external [get_bd_intf_pins %s/GT_SERIAL_RX]" % AUR_CELL,
        "set_property name gt_rx [get_bd_intf_ports GT_SERIAL_RX_0]",
        "foreach p {gt_refclk gt_tx gt_rx} {",
        "  if {[llength [get_bd_intf_ports -quiet $p]] != 1} { error \"JCCARD_BD FAIL: no BD interface port $p\" }",
        "}",
        "connect_bd_intf_net [get_bd_intf_pins %s/m_axis_tx] [get_bd_intf_pins %s/USER_DATA_S_AXIS_TX]" % (TOK_CELL, AUR_CELL),
        "connect_bd_intf_net [get_bd_intf_pins %s/USER_DATA_M_AXIS_RX] [get_bd_intf_pins %s/s_axis_rx]" % (AUR_CELL, TOK_CELL),
        _c("%s/init_clk" % GTG_CELL, "%s/init_clk" % AUR_CELL),
        _c("%s/init_clk" % GTG_CELL, "%s/init_clk" % TOK_CELL),
        _c("%s/user_clk_out" % AUR_CELL, "%s/user_clk" % TOK_CELL),
        _c("%s/tx_channel_up" % AUR_CELL, "%s/tx_channel_up" % TOK_CELL),
        _c("%s/rx_channel_up" % AUR_CELL, "%s/rx_channel_up" % TOK_CELL),
        _c("%s/gt_pll_lock" % AUR_CELL, "%s/gt_pll_lock" % TOK_CELL),
        _c("%s/locked" % GTG_CELL, "%s/gtg_locked" % TOK_CELL),
        "# TX/RX_Simplex has tx_reset_pb and rx_reset_pb, no reset_pb (Task 5): one reset drives both",
        _c("%s/aur_reset_pb" % TOK_CELL, "%s/tx_reset_pb" % AUR_CELL),
        _c("%s/aur_reset_pb" % TOK_CELL, "%s/rx_reset_pb" % AUR_CELL),
        _c("%s/aur_pma_init" % TOK_CELL, "%s/pma_init" % AUR_CELL),
        _c("%s/aur_tx_polarity" % TOK_CELL, "%s/gt_txpolarity" % AUR_CELL),
        "# Every other Aurora input, tied from hw/jc/link/aurora_ties.py.  An IP input left",
        "# open takes component.xml's default, 0 for all of these, and validate_bd_design does",
        "# not warn: gt_txdiffctrl = 0 is the minimum TX swing (Task 5 trap).",
        "# The GT DRP AXI4-Lite slave (s_axi_*) exists only when drp_mode is not Disabled: the BD",
        "# cell defaults to Disabled (MEASURED 2026-11-11, aurprobe: no s_axi_* pins), where the",
        "# packaged IP of Task 5 refused Disabled.  Its ties are emitted for the other case.",
        "set _drp [get_property CONFIG.drp_mode [get_bd_cells %s]]" % AUR_CELL,
        "puts \"JCCARD_BD %s drp_mode $_drp\"" % AUR_CELL,
    ]
    for name, d, w in aurora_core_ports():
        if d != "in" or name in T.MAPPED:
            continue
        v = T.tie_value(name, w or 1, LINK_NLANES)
        if v is None:
            sys.exit("ABORT: Aurora input %s is not in hw/jc/link/aurora_ties.py" % name)
        cell = "tie_%s" % name
        body = [
            "create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 %s" % cell,
            "set_property -dict [list CONFIG.CONST_WIDTH {%d} CONFIG.CONST_VAL {0x%X}] [get_bd_cells %s]"
            % (w or 1, int(v, 2), cell),
            _c("%s/dout" % cell, "%s/%s" % (AUR_CELL, name)),
        ]
        if name.startswith("s_axi_"):
            L += ["if {$_drp ne \"Disabled\"} {"] + ["  " + l for l in body] + [
                  "} elseif {[llength [get_bd_pins -quiet %s/%s]]} {" % (AUR_CELL, name),
                  "  error \"JCCARD_BD FAIL: %s/%s exists with drp_mode Disabled\"" % (AUR_CELL, name),
                  "}"]
        else:
            L += body
    L += [
        "# THE ORACLE FOR THE TIES: every input pin of the Aurora cell carries a net, except the",
        "# members of the three interfaces connected as interfaces (and those must be connected).",
        "foreach i {GT_DIFF_REFCLK1 GT_SERIAL_RX USER_DATA_S_AXIS_TX} {",
        "  if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins %s/$i]]] != 1} {" % AUR_CELL,
        "    error \"JCCARD_BD FAIL: %s/$i is not connected\"" % AUR_CELL,
        "  }",
        "}",
        "set _open {}",
        "set _nin 0",
        "foreach p [get_bd_pins -of_objects [get_bd_cells %s] -filter {DIR == I}] {" % AUR_CELL,
        "  incr _nin",
        "  set n [file tail $p]",
        "  if {[llength [get_bd_nets -quiet -of_objects $p]]} { continue }",
        "  if {$n in {gt_refclk1_p gt_refclk1_n rxp rxn s_axi_tx_tdata s_axi_tx_tkeep s_axi_tx_tlast s_axi_tx_tvalid}} { continue }",
        "  lappend _open $n",
        "}",
        "puts \"JCCARD_BD %s inputs=$_nin open=[llength $_open] $_open\"" % AUR_CELL,
        "if {[llength $_open]} { error \"JCCARD_BD FAIL: %s inputs with no net: $_open\" }" % AUR_CELL,
    ]
    return L


TOK_CTL_MI = 3     # axil2eng M00/M01 engine, M02 tok/s_host (the seam block), M03 tok/s_ctl


def link_ctl_lines(P):
    """After the seam block: tok/m_seam -> the seam, and one more axil2eng MI for tok/s_ctl."""
    return [
        "",
        "# the seam sits BEHIND the loop: tok/s_host took the seam's axil2eng MI above, and",
        "# tok/m_seam (jc_seam_mux: the host's path when the loop does not own the seam) is",
        "# the seam's only master.  tok/s_ctl (the loop's registers) is one more MI.",
        "connect_bd_intf_net [get_bd_intf_pins %s/m_seam] [get_bd_intf_pins %s/s_axi]" % (TOK_CELL, P.SEAM_CELL),
        "set n [get_property CONFIG.NUM_MI [get_bd_cells axil2eng]]",
        "if {$n != %d} { error \"JCCARD_BD FAIL: axil2eng NUM_MI is $n before tok/s_ctl, expected %d\" }"
        % (TOK_CTL_MI, TOK_CTL_MI),
        "set_property CONFIG.NUM_MI %d [get_bd_cells axil2eng]" % (TOK_CTL_MI + 1),
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/M%02d_AXI] [get_bd_intf_pins %s/s_ctl]" % (TOK_CTL_MI, TOK_CELL),
        "",
    ]


def _c(a, b):
    """One connect_bd_net with exactly two endpoints (gen_pcieep's net parser and the
    reset-topology check read two-endpoint lines only)."""
    return "connect_bd_net [get_bd_pins %s] [get_bd_pins %s]" % (a, b)


# ---- board sections (no gen_pcieep needed; the test calls these directly) -------------
def clock_lines(mhz, env=None):
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
    if a_split(env):
        L += [
            "",
            "# aclk_a (JC_A_CLK_SPLIT=1): its own MMCM on clk_out2.  One MMCM cannot make",
            "# clk_core and %d MHz together (their lcm is above the VCO range)." % ACLK_A_MHZ,
            "create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_a",
            "set_property -dict [list CONFIG.PRIM_IN_FREQ.VALUE_SRC USER] [get_bd_cells clk_wiz_a]",
            "set_property -dict [list CONFIG.PRIM_SOURCE {Global_buffer} CONFIG.PRIM_IN_FREQ {200.000} \\",
            "  CONFIG.USE_RESET {false} \\",
            "  CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {%.3f}] [get_bd_cells clk_wiz_a]"
            % ACLK_A_MHZ,
            "foreach {k v} {PRIM_SOURCE Global_buffer USE_RESET false CLKOUT1_REQUESTED_OUT_FREQ %.3f} {"
            % ACLK_A_MHZ,
            "  jcc_want clk_wiz_a $k $v",
            "}",
            _c(REF_CLK, "clk_wiz_a/clk_in1"),
            "create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 aclk_reset",
            _c("clk_wiz_a/locked", "aclk_reset/dcm_locked"),
            _c("one/dout", "aclk_reset/ext_reset_in"),
            _c(ACLK_A, "aclk_reset/slowest_sync_clk"),
        ]
    return L


def hbm_lines(mhz, env=None):
    split = a_split(env)
    amhz = ACLK_A_MHZ if split else mhz
    aclk, arstn = (ACLK_A, ACLK_A_RSTN) if split else (CORE_CLK, CORE_RSTN)
    L = [
        "",
        "# ---- HBM: 2 stacks, 8 GB, all 32 SAXI on clk_core ---------------------------------",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 hbm",
        "set_property -dict [list CONFIG.USER_HBM_DENSITY {8GB} CONFIG.USER_HBM_STACK {2} \\",
        "  CONFIG.USER_MEMORY_DISPLAY {8192}] [get_bd_cells hbm]",
        "set_property -dict [list CONFIG.USER_HBM_REF_CLK_0 {200} CONFIG.USER_HBM_REF_CLK_1 {200}] [get_bd_cells hbm]",
        "# The AXI clock both stacks are told to expect: clk_core, the net every AXI_nn_ACLK",
        "# below is on.",
        "set_property CONFIG.USER_AXI_INPUT_CLK_FREQ {%d} [get_bd_cells hbm]" % amhz,
        "set_property CONFIG.USER_AXI_INPUT_CLK1_FREQ {%d} [get_bd_cells hbm]" % amhz,
        "set_property -dict [list CONFIG.USER_SWITCH_ENABLE_00 {TRUE} CONFIG.USER_SWITCH_ENABLE_01 {TRUE}] [get_bd_cells hbm]",
        "set_property -dict [list CONFIG.USER_CLK_SEL_LIST0 {AXI_00_ACLK} CONFIG.USER_CLK_SEL_LIST1 {AXI_16_ACLK}] [get_bd_cells hbm]",
    ]
    L += ["set_property CONFIG.USER_SAXI_%02d {true} [get_bd_cells hbm]" % n for n in range(32)]
    L += [
        "set_property CONFIG.USER_APB_EN {false} [get_bd_cells hbm]",
        "foreach {k v} {USER_HBM_DENSITY 8GB USER_HBM_STACK 2 USER_HBM_REF_CLK_0 200",
        "               USER_HBM_REF_CLK_1 200 USER_AXI_INPUT_CLK_FREQ %d USER_AXI_INPUT_CLK1_FREQ %d"
        % (amhz, amhz),
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
        _c(aclk, "hbm/AXI_00_ACLK"),
        _c(arstn, "hbm/AXI_00_ARESET_N"),
        _c(aclk, "hbm/AXI_16_ACLK"),
        _c(arstn, "hbm/AXI_16_ARESET_N"),
    ]
    return L


def loader_lines(env=None):
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
    ]
    if a_split(env):
        L += [
            "# JC_A_CLK_SPLIT: SAXI_00 is on aclk_a, the loader on clk_core.  A converter with",
            "# the loader's own inferred protocol (read, then set, then read back).",
            "create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 ld_cdc",
            "set _lp [get_property CONFIG.PROTOCOL [get_bd_intf_pins %s/%s]]" % (LOADER_CELL, LOADER_INTF),
            "set_property CONFIG.PROTOCOL $_lp [get_bd_cells ld_cdc]",
            "jcc_want ld_cdc PROTOCOL $_lp",
            "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins ld_cdc/S_AXI]"
            % (LOADER_CELL, LOADER_INTF),
            "connect_bd_intf_net [get_bd_intf_pins ld_cdc/M_AXI] [get_bd_intf_pins hbm/SAXI_00]",
            _c(CORE_CLK, "ld_cdc/s_axi_aclk"),
            _c(CORE_RSTN, "ld_cdc/s_axi_aresetn"),
            _c(ACLK_A, "ld_cdc/m_axi_aclk"),
            _c(ACLK_A_RSTN, "ld_cdc/m_axi_aresetn"),
        ]
    else:
        L.append("connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins hbm/SAXI_00]"
                 % (LOADER_CELL, LOADER_INTF))
    for pin, port in LOADER_PINS:
        L.append("create_bd_port -dir O %s" % port)
        L.append("connect_bd_net [get_bd_pins %s/%s] [get_bd_ports %s]" % (LOADER_CELL, pin, port))
    return L


def jtag_hbm_lines(env=None):
    split = a_split(env)
    return [
        "",
        "# ---- SAXI_16: jtag_hbm (spot checks) and the ctl core's read master ---------------",
        "# 64-bit address and data, as on the FK33 and the loader; the smartconnect does the",
        "# AXI4 -> AXI3 and 64 -> 256 bit conversion.  One clock (NUM_CLKS 1).",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_hbm",
        "set_property -dict [list CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.M_AXI_ADDR_WIDTH {64}] [get_bd_cells jtag_hbm]",
        "jcc_want jtag_hbm M_AXI_ADDR_WIDTH 64",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 %s" % HBM_SC_CELL,
        "# S00 jtag_hbm, S01 the ctl read master, S02 tok/m_hbm (the embedding gather)",
        "set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {%d}] [get_bd_cells %s]"
        % (2 if split else 1, HBM_SC_CELL),
        "jcc_want %s NUM_CLKS %d" % (HBM_SC_CELL, 2 if split else 1),
        "connect_bd_intf_net [get_bd_intf_pins jtag_hbm/M_AXI] [get_bd_intf_pins %s/S00_AXI]" % HBM_SC_CELL,
        "connect_bd_intf_net [get_bd_intf_pins %s/M00_AXI] [get_bd_intf_pins hbm/SAXI_16]" % HBM_SC_CELL,
        _c(CORE_CLK, "jtag_hbm/aclk"),
        _c(CORE_RSTN, "jtag_hbm/aresetn"),
        _c(CORE_CLK, "%s/aclk" % HBM_SC_CELL),
        _c(CORE_RSTN, "%s/aresetn" % HBM_SC_CELL),
    ] + ([
        "# JC_A_CLK_SPLIT: M00 (to SAXI_16) is on aclk_a; the smartconnect crosses.",
        _c(ACLK_A, "%s/aclk1" % HBM_SC_CELL),
    ] if split else [])


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
        # The BD port's direction is the ctl pin's (an input of the ctl core is an
        # input of the BD); jc_card_top's component must declare the same.
        L.append("puts \"JCCARD_BD %s/tck TYPE [get_property TYPE [get_bd_pins %s/tck]]\""
                 % (CTL_CELL, CTL_CELL))
    L += [
        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins %s/S01_AXI]"
        % (CTL_CELL, CTL_MEM_INTF, HBM_SC_CELL),
        "",
        "# axil2eng: the control interconnect, named as on the FK33 because gen_pcieep.py's",
        "# seam section appends its master to it (NUM_MI + 1) and its card section replaces",
        "# M00's net with engctl.  On this board it is a one-clock smartconnect whose only",
        "# slave port is the ctl core, in the core domain.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axil2eng",
        "set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2} CONFIG.NUM_CLKS {1}] [get_bd_cells axil2eng]",
        "connect_bd_intf_net [get_bd_intf_pins %s/%s] [get_bd_intf_pins axil2eng/S00_AXI]"
        % (CTL_CELL, CTL_AXIL_INTF),
        _c(CORE_CLK, "axil2eng/aclk"),
        _c(CORE_RSTN, "axil2eng/aresetn"),
    ]
    return L


# ---- sections built from gen_pcieep.py --------------------------------------------------
def eng_lines(P, env=None):
    tiled, split = a_tiled(env), a_split(env)
    aclk, arstn = (ACLK_A, ACLK_A_RSTN) if split else (CORE_CLK, CORE_RSTN)
    L = P._eng_cell_lines()
    L += [
        "# BUILD 20's LEVERS, READ BACK, NOT SET.  build12_levers_off.patch sets",
        "# fk33_engine's FAST_POP default to false; it is the only lever the patch moves",
        "# that is a generic of a BD cell.  Reading the default back proves the project",
        "# compiled the PATCHED engine; setting it here would hide an unpatched tree.  NWIDE,",
        "# SWEEP_PIPE and SCORE_EARLY are generic maps deep inside fk33_llama_top and are",
        "# not visible at BD time: the build checks their `Parameter ... bound to` lines.",
        "set _fp [get_property CONFIG.FAST_POP [get_bd_cells %s]]" % P.ENG_CELL,
        "if {![string is false -strict $_fp]} {",
        "    error \"JCCARD_LEVER FAIL: %s FAST_POP is \\\"$_fp\\\", not false: the levers patch is not applied to fk33_engine.vhd\"" % P.ENG_CELL,
        "}",
        "puts \"JCCARD_LEVER %s FAST_POP $_fp\"" % P.ENG_CELL,
        "",
        "# THE a450 SUBSYSTEM A (JC_A_TILED / JC_A_CLK_SPLIT), set and read back.",
        "set_property -dict [list CONFIG.A_TILED {%s} CONFIG.A_CLK_SPLIT {%s}] [get_bd_cells %s]"
        % (str(tiled).lower(), str(split).lower(), P.ENG_CELL),
        "jcc_want %s A_TILED %s" % (P.ENG_CELL, str(tiled).lower()),
        "jcc_want %s A_CLK_SPLIT %s" % (P.ENG_CELL, str(split).lower()),
        "",

        "# ON THIS BOARD core_clk AND hbm_aclk ARE THE SAME NET, clk_core.  The engine's",
        "# internal crossing (axi_rd_port's async FIFO) is still present and is crossed",
        "# between equal clocks; no AXI clock converter sits between the engine and HBM.",
        _c(CORE_CLK, "%s/core_clk" % P.ENG_CELL),
        _c(CORE_RSTN, "%s/core_aresetn" % P.ENG_CELL),
        _c(aclk, "%s/hbm_aclk" % P.ENG_CELL),
        "",
        "# THE THERMAL HALT: either HBM stack's catastrophic-temperature trip.  The FK33",
        "# drives compute_halt from fk33_thermal (SYSMON plus the HBM trips); the Jungle Cat",
        "# has no fabric thermal guard, so the HBM trips alone halt new A jobs (the engine",
        "# masks GO; a running job is not interrupted).  The loader's own hbm_cattrip0/1",
        "# inputs are unchanged.  CATTRIP is a sticky level from the HBM IP and is not",
        "# synchronised here: the build's timing Tcl must treat it as asynchronous.",
        "create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 halt_or",
        "set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {or}] [get_bd_cells halt_or]",
        _c("hbm/DRAM_0_STAT_CATTRIP", "halt_or/Op1"),
        _c("hbm/DRAM_1_STAT_CATTRIP", "halt_or/Op2"),
        _c("halt_or/Res", "%s/compute_halt" % P.ENG_CELL),
        "",
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/M00_AXI] [get_bd_intf_pins %s/s_axi]" % P.ENG_CELL,
        "connect_bd_intf_net [get_bd_intf_pins axil2eng/M01_AXI] [get_bd_intf_pins %s/s_axix]" % P.ENG_CELL,
        "",
    ]
    L += P._eng_hbm_lines(aclk, arstn)
    L += ["# ---- end subsystem A ------------------------------------------------------", ""]
    return L


def pool_split_lines(P):
    """bcgrant/m0, m1 -> axi_clock_converter -> hbm/SAXI_30, SAXI_31 on aclk_a: the FK33
    shape of gen_pcieep._card_pool_lines(one_clock=None), with the Jungle Cat's clocks."""
    L = ["# ---- the grant's pool onto SAXI_30/31 through converters (JC_A_CLK_SPLIT) -----"]
    for i, port in enumerate(P.CARD_SAXI):
        cc = "bc_cdc%d" % i
        L += [
            "set _gp [get_property CONFIG.PROTOCOL [get_bd_intf_pins %s/m%d]]" % (P.GRANT_CELL, i),
            "if {$_gp ne \"AXI3\"} { error \"JCCARD_BD FAIL: %s/m%d PROTOCOL is $_gp, not AXI3\" }"
            % (P.GRANT_CELL, i),
            "set_property CONFIG.USER_SAXI_%02d {true} [get_bd_cells hbm]" % port,
            "create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 %s" % cc,
            "set_property -dict [list CONFIG.PROTOCOL {AXI3}] [get_bd_cells %s]" % cc,
            "jcc_want %s PROTOCOL AXI3" % cc,
            "connect_bd_intf_net [get_bd_intf_pins %s/m%d] [get_bd_intf_pins %s/S_AXI]"
            % (P.GRANT_CELL, i, cc),
            "connect_bd_intf_net [get_bd_intf_pins %s/M_AXI] [get_bd_intf_pins hbm/SAXI_%02d]"
            % (cc, port),
            _c(CORE_CLK, "%s/s_axi_aclk" % cc),
            _c(CORE_RSTN, "%s/s_axi_aresetn" % cc),
            _c(ACLK_A, "%s/m_axi_aclk" % cc),
            _c(ACLK_A_RSTN, "%s/m_axi_aresetn" % cc),
            _c(ACLK_A, "hbm/AXI_%02d_ACLK" % port),
            _c(ACLK_A_RSTN, "hbm/AXI_%02d_ARESET_N" % port),
        ]
    return L


def card_lines(P, env=None):
    one = (CORE_CLK, CORE_RSTN)
    L = P._card_cells_lines()
    L += card_27b_lines(P)
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
    L += pool_split_lines(P) if a_split(env) else P._card_pool_lines(one_clock=one)
    L += P._card_grant_addr_lines()
    L += P._card_a_addr_lines()
    L += ["# ---- end subsystems B, C, D -----------------------------------------------", ""]
    return L


PKG_REL = "hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd"


def pkg_lines():
    """Before the BD: the committed 27B package into the project, the 9B one refused."""
    return [
        "",
        "# ---- THE 27B MODEL PACKAGE -------------------------------------------------------",
        "# rtl/model_cfg_pkg.vhd binds the 9B; the 27B card compiles the rebound copy",
        "# %s (GENERATED by gen_pcieep.py's model_pkg_text, committed)." % PKG_REL,
        "# Both declare package model_cfg_pkg, so the 9B file in the project is refused.",
        "# jcc_repo may be set by the caller (a build that copies this script elsewhere);",
        "# otherwise it is this script's repository.",
        "if {![info exists jcc_repo]} {",
        "  set jcc_repo [file normalize [file join [file dirname [info script]] .. .. ..]]",
        "}",
        "set jcc_pkg [file join $jcc_repo %s]" % PKG_REL,
        "if {![file exists $jcc_pkg]} { error \"JCCARD_27B FAIL: $jcc_pkg does not exist\" }",
        "foreach f [get_files -quiet -of_objects [get_filesets sources_1] *model_cfg_pkg.vhd] {",
        "  error \"JCCARD_27B FAIL: $f (the 9B model package) is in the project\"",
        "}",
        "if {[llength [get_files -quiet $jcc_pkg]] == 0} { add_files -norecurse $jcc_pkg }",
        "set_property FILE_TYPE {VHDL 2008} [get_files $jcc_pkg]",
        "update_compile_order -fileset sources_1",
        "puts \"JCCARD_27B package [file tail $jcc_pkg]\"",
    ]


def card_27b_lines(P):
    """The 27B card wrapper, proved from the inferred cell: its host address ports are
    HADDR_W bits wide (15 for QWEN38_27B, 14 for the 9B wrapper that is committed)."""
    w = P.MODEL_HADDR_W
    L = ["# THE CARD IS THE 27B ONE, read from the inferred cell: hr_addr and hw_addr are",
         "# HADDR_W = %d bits on the QWEN38_27B wrapper and 14 on the committed 9B one." % w]
    for pin in ("hr_addr", "hw_addr"):
        L += ["set _p [get_bd_pins %s/%s]" % (P.CARD_CELL, pin),
              "set _w [expr {[get_property LEFT $_p] - [get_property RIGHT $_p] + 1}]",
              "if {$_w != %d} {" % w,
              "    error \"JCCARD_27B FAIL: %s/%s is $_w bits, not %d: this is not the QWEN38_27B card wrapper\""
              % (P.CARD_CELL, pin, w),
              "}",
              "puts \"JCCARD_27B %s/%s $_w bits\"" % (P.CARD_CELL, pin)]
    return L + [""]


def seam_27b_lines(P):
    return [
        "foreach {g want} {REGMAX %d HADDR_W %d} {" % (P.MODEL_REGMAX, P.MODEL_HADDR_W),
        "  set v [get_property CONFIG.$g [get_bd_cells %s]]" % P.SEAM_CELL,
        "  if {$v != $want} { error \"JCCARD_27B FAIL: CONFIG.$g of %s is $v, not $want\" }" % P.SEAM_CELL,
        "  puts \"JCCARD_27B CONFIG.HADDR_W/REGMAX readback $g = $v on %s\"" % P.SEAM_CELL,
        "}",
    ]


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
                     (P.SEAM_BASE, "%s/s_host/reg0" % TOK_CELL)):
        L.append("assign_bd_address -offset 0x%08X -range 4K -target_address_space "
                 "[get_bd_addr_spaces %s] [get_bd_addr_segs {%s}]" % (off, sp, seg))
    L.append("# the seam is behind the loop: the host's 0xE000 window is tok/s_host, which")
    L.append("# forwards to tok/m_seam -> %s/s_axi at 0 (plan 2026-11-04 Task 7)" % P.SEAM_CELL)
    L.append("assign_bd_address -offset 0x%08X -range 64K -target_address_space "
             "[get_bd_addr_spaces %s] [get_bd_addr_segs {%s/s_ctl/reg0}]" % (TOK_CTL_BASE, sp, TOK_CELL))
    L.append("assign_bd_address -offset 0x00000000 -range 4K -target_address_space "
             "[get_bd_addr_spaces %s/m_seam] [get_bd_addr_segs {%s/s_axi/reg0}]" % (TOK_CELL, P.SEAM_CELL))
    L.append(P._eng_hbm_addr_text().rstrip("\n"))
    L += [
        "# The loader (SAXI_00), jtag_hbm, the ctl read master and the loop's gather (SAXI_16",
        "# through hbm_sc): every one sees all 32 pseudo-channel segments at their absolute",
        "# addresses.",
        "foreach {sp sx} {%s/%s 00 jtag_hbm/Data 16 %s/%s 16 %s/m_hbm 16} {"
        % (LOADER_CELL, LOADER_INTF, CTL_CELL, CTL_MEM_INTF, TOK_CELL),
        "  for {set s 0} {$s < 32} {incr s} {",
        "    assign_bd_address -target_address_space [get_bd_addr_spaces $sp] \\",
        "      -offset [format 0x%X [expr {$s * 0x10000000}]] -range 256M \\",
        "      [get_bd_addr_segs [format \"hbm/SAXI_%s/HBM_MEM%02d\" $sx $s]]",
        "  }",
        "}",
        "# %s 4: engine control, activation writer, tok/s_host (the seam behind it), tok/s_ctl" % sp,
        "foreach {sp want} {%s/%s 32 jtag_hbm/Data 32 %s/%s 32 %s 4 %s/m_hbm 32 %s/m_seam 1} {"
        % (LOADER_CELL, LOADER_INTF, CTL_CELL, CTL_MEM_INTF, sp, TOK_CELL, TOK_CELL),
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
    ]
    body += pkg_lines()
    body += [
        "",
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
    body += clock_lines(mhz, env)
    body += P._core_clk_sentinel().split("\n")
    body += hbm_lines(mhz, env)
    body += loader_lines(env)
    body += jtag_hbm_lines(env)
    body += ctl_lines()
    body += eng_lines(P, env)
    body += link_lines()
    seam = P._seam_block(one_clock=True)
    hook = "                    [get_bd_intf_pins %s/s_axi]" % P.SEAM_CELL
    if seam.count(hook) != 1:
        sys.exit("ABORT: gen_pcieep's seam block no longer connects axil2eng to %s/s_axi in the "
                 "shape gen_jc_card.py rewires (found %d)" % (P.SEAM_CELL, seam.count(hook)))
    body += seam.replace(hook, "                    [get_bd_intf_pins %s/s_host]" % TOK_CELL).split("\n")
    body += link_ctl_lines(P)
    body += seam_27b_lines(P)
    body += card_lines(P, env)
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
    pp, pn = refclk_pins()
    code2 = [
        "",
        "# the Aurora core's nominal refclk (plan 2026-11-04 Task 7; Task 5 ruling): MGTREFCLK0 of",
        "# quad X0Y0, %s/%s, the only refclk the IP offers for lane X0Y0. UNDRIVEN on the" % (pp, pn),
        "# Jungle Cat board: with JC_LINK_REFCLK=gtg the ECO (hw/jc/link/eco_aurora_gtg.tcl) moves",
        "# the running QPLL to GTGREFCLK, and this pin only gives the IBUFDS_GTE4 a legal site.",
        "set_property PACKAGE_PIN %s [get_ports gt_refclk_clk_p]" % pp,
        "create_clock -name gt_refclk -period 6.400 [get_ports gt_refclk_clk_p]",
        "# the GTG MMCM (hw/jc/link/rtl/jc_gtg_clk.vhd, cell %s/inst/u_mmcm in the BD): IBERT G" % GTG_CELL,
        "# needed an explicit site and a dedicated route for the BUFG -> MMCM net (finding 3).",
        "# The BACKBONE property goes on the NET (IBERT G's form; on the pin it reads back on the",
        "# pin but not on the net, Task 5 eco_check). build_card.tcl reads both back.",
        "set_property LOC %s [get_cells -hier -filter {NAME =~ %s}]" % (GTG_MMCM_LOC, GTG_MMCM_PAT),
        "set_property CLOCK_DEDICATED_ROUTE BACKBONE "
        "[get_nets -of_objects [get_pins -hier -filter {NAME =~ %s/CLKIN1}]]" % GTG_MMCM_PAT,
    ]
    out += code2
    return genstamp.append_end("\n".join(out) + "\n", stamp_block("#", env), "#")


def render_top(env=None):
    w = max(len(n) for n, _ in TOP_PORTS + [(p, d) for _, d, p, _ in CTL_JTAG]
            + [(n, d) for n, d, _ in GT_TOP_PORTS])

    def gt(indent):
        return [indent + "%-*s : %-3s %s" % (w, n, d, "std_logic_vector(0 downto 0)" if wd else "std_logic")
                for n, d, wd in GT_TOP_PORTS]
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
    ports = ["    %-*s : %-3s std_logic" % (w, n, d) for n, d in TOP_PORTS] + gt("    ")
    L2 += [p + (";" if i < len(ports) - 1 else "") for i, p in enumerate(ports)]
    L2 += ["  );", "end entity;", "", "architecture rtl of jc_card_top is",
           "  component %s_wrapper is" % BD_NAME, "    port("]
    cports = (["      %-*s : %-3s std_logic" % (w, n, d) for n, d in TOP_PORTS]
              + ["      %-*s : %-3s std_logic" % (w, p, d) for _, d, p, _ in CTL_JTAG]
              + gt("      "))
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
             + ["%s => %s" % (p, p) for _, _, p, _ in CTL_JTAG]
             + ["%s => %s" % (n, n) for n, _, _ in GT_TOP_PORTS])
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


def generate_in_place(outdir, pkg_outdir):
    mhz = clk_core_mhz()
    ok, got = card_is_jc()
    if not ok:
        sys.exit("ABORT: %s was generated with %s, not the Jungle Cat card's %s. "
                 "Regenerate it with gen_fk33_card.py under that environment, or run "
                 "without --in-place." % (os.path.relpath(CARD_RTL, REPO), got, JC_CARD_ENV))
    P = load_pcieep(mhz)
    if P.MODEL_NAME != "QWEN38_27B" or P.MODEL_HADDR_W != 15:
        sys.exit("ABORT: gen_pcieep.py resolved model %s HADDR_W %d, not QWEN38_27B / 15"
                 % (P.MODEL_NAME, P.MODEL_HADDR_W))
    if os.path.relpath(P.MODEL_PKG_OUT, REPO) != PKG_REL:
        sys.exit("ABORT: gen_pcieep.py's 27B package is %s, the BD sources %s"
                 % (os.path.relpath(P.MODEL_PKG_OUT, REPO), PKG_REL))
    tcl = render_tcl(P, mhz)
    # gen_pcieep.py's own refusals, on THIS text.
    P.check_reset_topology(tcl)
    P.check_seam_tieoff(tcl)
    outs = {OUT_TCL: tcl, OUT_XDC: render_xdc(), OUT_TOP: render_top()}
    for name, text in outs.items():
        with open(os.path.join(outdir, name), "w") as f:
            f.write(text)
        print("wrote %s (%d bytes)" % (os.path.join(outdir, name), len(text)))
    pkg = P.model_pkg_text()
    dst = os.path.join(pkg_outdir, os.path.basename(PKG_REL))
    with open(dst, "w") as f:
        f.write(pkg)
    print("wrote %s (%d bytes)" % (dst, len(pkg)))


def _scratch_dir(argv):
    if "--scratch" in argv:
        i = argv.index("--scratch")
        if i + 1 >= len(argv):
            sys.exit("gen_jc_card.py: --scratch needs a directory")
        return os.path.abspath(argv[i + 1])
    return os.path.join(os.path.expanduser("~"), "regress_scratch", "gen_jc_card")


ARCHIVE_PATHS = ["rtl", "tools", "hw/fk33", "hw/jc", "server", ":(glob)sim/*.py",
                 ":!hw/fk33/results", ":!hw/fk33/bit", ":!hw/jc/loader/results",
                 ":!hw/jc/pinfinder/results"]


def _populate(scratch, rev="HEAD"):
    """`git archive <rev>` of the paths the generators read, into `scratch`: the
    COMMITTED tree, never the working tree (another track's half-edited file must not
    reach a committed output).  sim/*.py because tools/gen_bd_wrapper.py (gen_fk33_card's
    library) imports sim/check_bd_ports.py.  Refuses to reuse a directory it did not make."""
    if os.path.exists(scratch):
        if not os.path.exists(os.path.join(scratch, SCRATCH_MARK)):
            sys.exit("ABORT: %s exists and is not a gen_jc_card scratch directory "
                     "(no %s); refusing to clear it." % (scratch, SCRATCH_MARK))
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    open(os.path.join(scratch, SCRATCH_MARK), "w").write("gen_jc_card.py scratch\n")
    arc = subprocess.run(["git", "archive", "--format=tar", rev, "--"] + ARCHIVE_PATHS,
                         cwd=REPO, stdout=subprocess.PIPE, check=True)
    subprocess.run(["tar", "-x", "-C", scratch], input=arc.stdout, check=True)
    sha = subprocess.run(["git", "rev-parse", rev], cwd=REPO, stdout=subprocess.PIPE,
                         check=True).stdout.decode().strip()
    print("gen_jc_card: git archive %s (%s) extracted into %s" % (rev, sha[:12], scratch))


def generate_via_scratch(outdir, pkg_outdir, scratch):
    _populate(scratch)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FK33_")}
    cenv = dict(env)
    cenv.update({k: v for k, v in JC_CARD_ENV.items() if v is not None})
    r = subprocess.run([sys.executable, "hw/fk33/gen_fk33_card.py"], cwd=scratch, env=cenv)
    if r.returncode != 0:
        sys.exit("ABORT: gen_fk33_card.py failed in %s (rc=%d)" % (scratch, r.returncode))
    me = os.path.join(scratch, os.path.relpath(os.path.abspath(__file__), REPO))
    r = subprocess.run([sys.executable, me, "--in-place", "--emit-to", outdir,
                        "--emit-pkg-to", pkg_outdir],
                       cwd=scratch, env=env)
    if r.returncode != 0:
        sys.exit("ABORT: gen_jc_card.py failed in %s (rc=%d)" % (scratch, r.returncode))


def main(argv):
    _refuse_conflicting_env(clk_core_mhz())
    def _dir_arg(flag, default):
        if flag not in argv:
            return default
        i = argv.index(flag)
        if i + 1 >= len(argv) or not os.path.isdir(argv[i + 1]):
            sys.exit("gen_jc_card.py: %s needs an existing directory" % flag)
        return os.path.abspath(argv[i + 1])
    outdir = _dir_arg("--emit-to", HERE)
    # The 27B package goes beside the emitted files under --emit-to, else to hw/fk33/gen.
    pkg_outdir = _dir_arg("--emit-pkg-to", outdir if "--emit-to" in argv
                          else os.path.join(REPO, os.path.dirname(PKG_REL)))
    if "--check" in argv:
        scratch = _scratch_dir(argv)
        chk = scratch + "_check_out"
        if os.path.exists(chk):
            if not os.path.exists(os.path.join(chk, SCRATCH_MARK)):
                sys.exit("ABORT: %s exists and is not ours" % chk)
            shutil.rmtree(chk)
        os.makedirs(chk)
        open(os.path.join(chk, SCRATCH_MARK), "w").write("gen_jc_card.py check\n")
        generate_via_scratch(chk, chk, scratch)
        stale = []
        for name, real in ((OUT_TCL, os.path.join(HERE, OUT_TCL)),
                           (OUT_XDC, os.path.join(HERE, OUT_XDC)),
                           (OUT_TOP, os.path.join(HERE, OUT_TOP)),
                           (os.path.basename(PKG_REL), os.path.join(REPO, PKG_REL))):
            a = open(real).read() if os.path.exists(real) else None
            b = open(os.path.join(chk, name)).read()
            print("JCCARD_CHECK: %s %s" % ("OK" if a == b else "STALE", name))
            if a != b:
                stale.append(name)
        if stale:
            sys.exit("JCCARD_CHECK: STALE %s" % ", ".join(stale))
        print("JCCARD_CHECK: PASS")
        return
    if "--in-place" in argv or card_is_jc()[0]:
        generate_in_place(outdir, pkg_outdir)
    else:
        generate_via_scratch(outdir, pkg_outdir, _scratch_dir(argv))


if __name__ == "__main__":
    main(sys.argv[1:])
