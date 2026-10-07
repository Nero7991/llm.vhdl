"""hw/jc/card/test_gen_jc_card.py -- structural checks over the GENERATED Jungle Cat
card block design (hw/jc/card/jc_card_bd.tcl, jc_card.xdc, jc_card_top.vhd).

Pure Python over the committed generated text; no Vivado.  Run:
    python3 -m pytest hw/jc/card/test_gen_jc_card.py -q

What these checks are NOT: evidence that the BD validates, synthesises or computes.
They pin the wiring the generator promises (one clock net, the SAXI map, no XDMA, the
BSCAN chains) so a regeneration that breaks one of those fails here, in seconds,
instead of in a --bd-only run.
"""
import getpass
import os
import re
import socket
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
TCL = os.path.join(HERE, "jc_card_bd.tcl")
XDC = os.path.join(HERE, "jc_card.xdc")
TOP = os.path.join(HERE, "jc_card_top.vhd")
LOADER_XDC = os.path.join(REPO, "hw", "jc", "loader", "jc_loader.xdc")


def _import_clean(name, path):
    """Import a generator as a module with no FK33_* in the environment and no
    argv flags, so its module-level code takes the documented defaults."""
    saved_env = {k: v for k, v in os.environ.items() if k.startswith("FK33_")}
    saved_argv = sys.argv
    for k in saved_env:
        del os.environ[k]
    sys.argv = [path]
    sys.path.insert(0, os.path.dirname(path))
    try:
        __import__(name)
        return sys.modules[name]
    finally:
        sys.path.pop(0)
        sys.argv = saved_argv
        os.environ.update(saved_env)


P = _import_clean("gen_pcieep", os.path.join(REPO, "hw", "fk33", "gen_pcieep.py"))
G = _import_clean("gen_jc_card", os.path.join(HERE, "gen_jc_card.py"))


def _read(p):
    with open(p) as f:
        return f.read()


def _code_lines(text, comment="#"):
    """Non-comment lines, with Tcl backslash-newline continuations joined."""
    out, cur = [], ""
    for l in text.splitlines():
        if not cur and (not l.strip() or l.lstrip().startswith(comment)):
            continue
        if l.endswith("\\"):
            cur += l[:-1] + " "
            continue
        out.append(cur + l)
        cur = ""
    if cur:
        out.append(cur)
    return out


_EP = re.compile(r"\[get_bd_(?:pins|ports)\s+([^\]\s]+)\s*\]")
# an interface endpoint may carry one nested Tcl command, e.g. axil2eng/[format M%02d_AXI $n]
_IEP = re.compile(r"\[get_bd_intf_(?:pins|ports)\s+((?:[^\[\]\s]|\[[^\]]*\])+)\s*\]")


def _nets(text):
    """Union-find over every connect_bd_net line (any number of endpoints)."""
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for l in _code_lines(text):
        if "connect_bd_net" not in l:
            continue
        eps = _EP.findall(l)
        assert len(eps) >= 2, "connect_bd_net with <2 endpoints: %r" % l
        for e in eps[1:]:
            parent[find(eps[0])] = find(e)
    groups = {}
    for x in list(parent):
        groups.setdefault(find(x), set()).add(x)
    return list(groups.values())


def _net_of(nets, ep):
    for n in nets:
        if ep in n:
            return n
    return set()


def _intf_nets(text):
    out = []
    for l in _code_lines(text):
        if "connect_bd_intf_net" in l:
            eps = _IEP.findall(l)
            assert len(eps) == 2, l
            out.append(tuple(eps))
    return out


@pytest.fixture(scope="module")
def tcl():
    return _read(TCL)


# ---- the SAXI-to-master map, from gen_pcieep.py's own tables ------------------------
def expected_saxi_map():
    m = {0: "%s/%s" % (G.LOADER_CELL, G.LOADER_INTF), 16: "%s/M00_AXI" % G.HBM_SC_CELL}
    for i, port in enumerate(P.ENG_PORT_MAP):
        m[port] = "%s/m%02d_axi" % (P.ENG_CELL, i)
    for k, port in enumerate(P.CARD_SAXI):
        m[port] = "%s/m%d" % (P.GRANT_CELL, k)
    return m


def test_saxi_map_matches_gen_pcieep(tcl):
    exp = expected_saxi_map()
    assert sorted(exp) == list(range(32)), "the expected map itself must cover 0..31"
    got = {}
    for a, b in _intf_nets(tcl):
        for src, dst in ((a, b), (b, a)):
            mm = re.fullmatch(r"hbm/SAXI_(\d\d)", dst)
            if mm:
                n = int(mm.group(1))
                assert n not in got, "SAXI_%02d connected twice" % n
                got[n] = src
    assert got == exp


def test_every_saxi_enabled(tcl):
    for n in range(32):
        assert re.search(r"CONFIG\.USER_SAXI_%02d \{true\}" % n, tcl), "SAXI_%02d" % n
    assert not re.search(r"CONFIG\.USER_SAXI_\d\d \{false\}", tcl)


def test_smartconnect_feeds_saxi16(tcl):
    nets = set(_intf_nets(tcl))
    assert ("jtag_hbm/M_AXI", "%s/S00_AXI" % G.HBM_SC_CELL) in nets
    assert ("%s/%s" % (G.CTL_CELL, G.CTL_MEM_INTF), "%s/S01_AXI" % G.HBM_SC_CELL) in nets


# ---- one clock --------------------------------------------------------------------
def test_one_core_clock_net(tcl):
    nets = _net_of(_nets(tcl), G.CORE_CLK)
    aclks = ["hbm/AXI_%02d_ACLK" % n for n in range(32)]
    for p in aclks:
        assert p in nets, "%s is not on %s" % (p, G.CORE_CLK)
    for p in ("%s/core_clk" % P.ENG_CELL, "%s/hbm_aclk" % P.ENG_CELL,
              "%s/clk" % P.CARD_CELL, "%s/clk" % P.GRANT_CELL, "%s/clk" % P.SEAM_CELL,
              "%s/aclk" % G.LOADER_CELL, "%s/%s" % (G.CTL_CELL, G.CTL_CLK),
              "jtag_hbm/aclk", "%s/aclk" % G.HBM_SC_CELL, "axil2eng/aclk", "engctl/aclk"):
        assert p in nets, "%s is not on %s" % (p, G.CORE_CLK)
    # nothing on that net comes from another clock source
    others = [e for e in nets if e.startswith("clk_wiz_0/") and e != G.CORE_CLK]
    assert others == []
    # every hbm/AXI_nn_ACLK appears in exactly one connect line
    for p in aclks:
        n = sum(1 for l in _code_lines(tcl)
                if "connect_bd_net" in l and p in _EP.findall(l))
        assert n == 1, "%s connected %d times" % (p, n)


def test_user_axi_clk_config_is_core(tcl):
    for k in ("USER_AXI_INPUT_CLK_FREQ", "USER_AXI_INPUT_CLK1_FREQ"):
        vals = re.findall(r"CONFIG\.%s \{(\d+)\}" % k, tcl)
        assert vals == [str(G.CLK_CORE_DEFAULT)], (k, vals)
    sel = dict(re.findall(r"CONFIG\.(USER_CLK_SEL_LIST[01]) \{(AXI_\d\d_ACLK)\}", tcl))
    assert sel == {"USER_CLK_SEL_LIST0": "AXI_00_ACLK", "USER_CLK_SEL_LIST1": "AXI_16_ACLK"}


def test_no_clock_converter_and_single_clock_interconnects(tcl):
    code = "\n".join(_code_lines(tcl))
    assert "axi_clock_converter" not in code
    assert not re.search(r"/aclk[12]\]", code), "a second smartconnect clock is wired"
    for m in re.finditer(r"CONFIG\.NUM_CLKS \{(\d+)\}", code):
        assert m.group(1) == "1"


# ---- no PCIe ------------------------------------------------------------------------
def test_no_xdma_or_pcie(tcl):
    code = "\n".join(_code_lines(tcl)).lower()
    assert "xdma" not in code
    assert "pcie" not in code
    assert not re.search(r"create_bd_cell[^\n]*\bxdma\b", tcl)


# ---- the card cells, with the FK33 connections ---------------------------------------
def test_card_cells_and_seam_connections(tcl):
    for ref, cell in (("fk33_engine", P.ENG_CELL), ("fk33_seam", P.SEAM_CELL),
                      ("fk33_card", P.CARD_CELL), ("fk33_bc_grant", P.GRANT_CELL),
                      ("jc_loader_top", G.LOADER_CELL), (G.CTL_MODULE, G.CTL_CELL)):
        n = len(re.findall(r"^create_bd_cell -type module -reference %s %s$"
                           % (ref, cell), tcl, re.M))
        assert n == 1, (ref, cell, n)
    nets = _nets(tcl)
    pairs = ([("%s/%s" % (P.SEAM_CELL, s), "%s/%s" % (P.CARD_CELL, c))
              for s, c in P.SEAM_FROM_CARD + P.SEAM_TO_CARD]
             + [("%s/%s" % (P.CARD_CELL, c), "%s/%s" % (P.ENG_CELL, e))
                for c, e in P.CARD_SEAM_TO_ENG + P.CARD_SEAM_FROM_ENG])
    for x, y in pairs:
        assert y in _net_of(nets, x), "%s -- %s not connected" % (x, y)


# ---- CLK_CORE_MHZ --------------------------------------------------------------------
def test_clk_core_in_clk_wiz_config(tcl):
    assert "CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}" in tcl
    assert "CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000}" in tcl
    assert ("CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {%.3f}" % G.CLK_CORE_DEFAULT) in tcl


def test_clk_core_parameter_reaches_clk_wiz_and_hbm():
    """Teeth for the one above: the parameter, not a literal, drives both."""
    t = "\n".join(G.clock_lines(175) + G.hbm_lines(175))
    assert "CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {175.000}" in t
    assert "CONFIG.USER_AXI_INPUT_CLK_FREQ {175}" in t
    assert "CONFIG.USER_AXI_INPUT_CLK1_FREQ {175}" in t
    assert "{200.000}" in t          # HBM_REF_CLK stays 200
    assert "CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000}" not in t


def test_clk_core_refuses_bad_values():
    for bad in ("0", "49", "251", "200.5", "abc"):
        with pytest.raises(SystemExit):
            G.clk_core_mhz({"JC_CLK_CORE_MHZ": bad})
    assert G.clk_core_mhz({}) == 200
    assert G.clk_core_mhz({"JC_CLK_CORE_MHZ": "180"}) == 180


# ---- BSCAN census over the design the top elaborates ----------------------------------
_VHD_DIRS = ("rtl", "hw/jc/loader/rtl", "hw/jc/ctl/rtl", "hw/fk33/rtl")


def _strip_vhdl_comments(t):
    return re.sub(r"--[^\n]*", "", t)


def _entity_index():
    idx = {}
    for d in _VHD_DIRS:
        p = os.path.join(REPO, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f.endswith(".vhd"):
                t = _strip_vhdl_comments(_read(os.path.join(p, f)))
                for m in re.finditer(r"^\s*entity\s+(\w+)\s+is\b", t, re.M | re.I):
                    idx.setdefault(m.group(1).lower(), os.path.join(p, f))
    return idx


def _bscans(text):
    """[(chain)] for every BSCANE2 instance in VHDL text (default chain 1)."""
    out = []
    for m in re.finditer(r":\s*BSCANE2\b(.*?)\bport\s+map", text, re.I | re.S):
        g = re.search(r"JTAG_CHAIN\s*=>\s*(\d+)", m.group(1))
        out.append(int(g.group(1)) if g else 1)
    return out


def _census(tcl_text):
    idx = _entity_index()
    refs = re.findall(r"^create_bd_cell -type module -reference (\w+) \w+$", tcl_text, re.M)
    top = _strip_vhdl_comments(_read(TOP))
    chains, missing, seen = [], [], set()
    chains += [(c, "jc_card_top") for c in _bscans(top)]
    todo = [e.lower() for e in re.findall(r"entity\s+work\.(\w+)", top, re.I)]
    # the BD wrapper is a component instance in the top; its contents are the BD's
    # module references
    assert re.search(r":\s*%s_wrapper\b" % G.BD_NAME, top, re.I), "top does not instantiate the BD"
    todo += [r.lower() for r in refs]
    while todo:
        e = todo.pop()
        if e in seen:
            continue
        seen.add(e)
        f = idx.get(e)
        if f is None:
            missing.append(e)
            continue
        t = _strip_vhdl_comments(_read(f))
        chains += [(c, e) for c in _bscans(t)]
        todo += [x.lower() for x in re.findall(r"entity\s+work\.(\w+)", t, re.I)]
    return chains, missing


def test_bscan_census_chain4_is_the_loader_only(tcl):
    chains, _ = _census(tcl)
    four = [w for c, w in chains if c == 4]
    assert four == ["jc_frame_rx"], chains
    assert all(c in (3, 4) for c, _ in chains), chains


def test_top_instantiates_ctl_rx_once():
    top = _strip_vhdl_comments(_read(TOP))
    assert len(re.findall(r"entity\s+work\.%s\b" % G.CTL_RX_ENTITY, top, re.I)) == 1


def test_bscan_census_exactly_one_per_chain(tcl):
    chains, missing = _census(tcl)
    if G.CTL_RX_ENTITY in missing or G.CTL_MODULE.lower() in missing:
        pytest.skip("USER3 RTL not landed yet (%s): the chain-3 count cannot be "
                    "read from source" % ", ".join(m for m in missing
                                                  if m.startswith("jc_ctl")))
    assert sorted(c for c, _ in chains) == [3, 4], chains


# ---- xdc and top ports --------------------------------------------------------------
def test_xdc_carries_every_loader_pin_line():
    xdc = _code_lines(_read(XDC))
    for l in _code_lines(_read(LOADER_XDC)):
        assert l in xdc, "loader xdc line missing: %r" % l


def test_top_ports_match_xdc():
    top = _strip_vhdl_comments(_read(TOP))
    ent = re.search(r"entity\s+jc_card_top\s+is(.*?)end\s+entity", top, re.I | re.S).group(1)
    ports = set(re.findall(r"(\w+)\s*:\s*(?:in|out)\b", ent))
    xdc_ports = set(re.findall(r"get_ports\s+\{?([^\]\}]+)", _read(XDC)))
    xp = set()
    for s in xdc_ports:
        xp.update(s.split())
    assert ports == xp, (ports, xp)


# ---- GENSTAMP -----------------------------------------------------------------------
def _stamp_block(text, comment):
    lines = text.splitlines()
    i = next(k for k, l in enumerate(lines) if "GENSTAMP" in l)
    j = i
    while j < len(lines) and lines[j].startswith(comment):
        j += 1
    return "\n".join(lines[i:j])


@pytest.mark.parametrize("path,comment", [(TCL, "#"), (XDC, "#"), (TOP, "--")])
def test_genstamp_present_and_clean(path, comment):
    text = _read(path)
    assert "GENSTAMP" in text
    blk = _stamp_block(text, comment)
    assert "python3 hw/jc/card/gen_jc_card.py" in blk
    assert re.search(r"env\s+JC_CLK_CORE_MHZ\s+=", blk)
    assert not re.search(r"\d{4}-\d\d-\d\d[ T]\d\d:\d\d", blk), "timestamp in stamp"
    assert not re.search(r"\b\d\d:\d\d:\d\d\b", blk), "clock time in stamp"
    user, host = getpass.getuser(), socket.gethostname()
    assert user not in blk and host not in blk
    # no absolute path anywhere in the generated file, not only in the stamp
    assert not re.search(r"(?<![\w$])/(home|tmp|mnt|usr|opt|tools)/", text), \
        "absolute path in %s" % os.path.basename(path)
    assert user not in text and host not in text
