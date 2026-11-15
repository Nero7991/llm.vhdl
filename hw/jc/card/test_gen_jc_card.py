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
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))


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
    # the GT serial pins and the refclk's N leg are placed by the GT / IBUFDS_GTE4 site
    gt_free = {n for n, _, _ in G.GT_TOP_PORTS if n != "gt_refclk_clk_p"}
    assert ports - gt_free == xp, (ports, xp)


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


# ==== fix round 1 (2026-10-07 review) ===================================================
SYSCLK_INTF_PORTS = {"sysclk_clk_p": "in", "sysclk_clk_n": "in"}   # make_bd_intf_pins_external


def _bd_ports(tcl_text):
    """{name: 'in'|'out'} for every BD external port the tcl creates."""
    ports = dict(SYSCLK_INTF_PORTS)
    assert "make_bd_intf_pins_external [get_bd_intf_pins sysclk_buf/CLK_IN_D]" in tcl_text
    # the Aurora GT interfaces made external and renamed: <port>_<member> in the wrapper
    # (the BD-only build reads the wrapper back against GT_TOP_PORTS, build_card.tcl)
    for intf, port, members in (("GT_DIFF_REFCLK1", "gt_refclk", ("clk_p", "clk_n")),
                                ("GT_SERIAL_TX", "gt_tx", ("txp", "txn")),
                                ("GT_SERIAL_RX", "gt_rx", ("rxp", "rxn"))):
        assert "make_bd_intf_pins_external [get_bd_intf_pins %s/%s]" % (G.AUR_CELL, intf) in tcl_text
        assert "set_property name %s [get_bd_intf_ports %s_0]" % (port, intf) in tcl_text
        for m in members:
            ports["%s_%s" % (port, m)] = dict((n, d) for n, d, _ in G.GT_TOP_PORTS)["%s_%s" % (port, m)]
    for d, n in re.findall(r"^create_bd_port -dir ([IO]) (\w+)\s*$", tcl_text, re.M):
        assert n not in ports, "BD port %s created twice" % n
        ports[n] = "in" if d == "I" else "out"
    return ports


def _component_ports(top_text, comp):
    m = re.search(r"component\s+%s\s+is\s+port\s*\((.*?)\)\s*;\s*end\s+component"
                  % comp, top_text, re.I | re.S)
    assert m, "component %s not declared" % comp
    return {n: d.lower() for n, d in re.findall(r"(\w+)\s*:\s*(in|out)\b", m.group(1), re.I)}


def test_bd_port_directions_match_top_component(tcl):
    """CRITICAL 1: every BD port, ctl_* included, has the wrapper component's direction."""
    top = _strip_vhdl_comments(_read(TOP))
    assert _component_ports(top, "%s_wrapper" % G.BD_NAME) == _bd_ports(tcl)


def test_ctl_rx_outputs_drive_bd_inputs(tcl):
    """jc_ctl_rx's *_o pins drive exactly the BD's ctl inputs; its tdo_i reads the BD's
    ctl output.  One driver per signal."""
    bd = _bd_ports(tcl)
    for _, d, port, rx in G.CTL_JTAG:
        assert bd[port] == d, (port, bd[port], d)
        assert rx.endswith("_o") == (d == "in"), (port, rx)


def test_27b_package_sourced_and_card_readback(tcl):
    """IMPORTANT 2: the BD adds the committed 27B package, refuses the 9B one, and reads
    back a width only the 27B card wrapper has."""
    rel = "hw/fk33/gen/model_cfg_pkg_QWEN38_27B.vhd"
    pkg = os.path.join(REPO, rel)
    assert os.path.isfile(pkg), rel
    ptxt = _read(pkg)
    assert "GENSTAMP" in ptxt and "QWEN38_27B" in ptxt
    assert re.search(r"constant\s+MODEL\s*:\s*model_cfg_t\s*:=\s*QWEN38_27B\s*;", ptxt), \
        "the package does not bind QWEN38_27B"
    code = "\n".join(_code_lines(tcl))
    assert rel in code and "add_files" in code
    assert re.search(r"model_cfg_pkg\.vhd.*\n.*error", code), "the 9B package is not refused"
    # the 27B wrapper's host address ports are 15 bits (HADDR_W 15); the 9B's are 14
    for pin in ("hr_addr", "hw_addr"):
        assert re.search(r"card/%s.*\n.*!= 15" % pin, code) or \
            re.search(r"card/%s\b.*15" % pin, code), pin
    assert re.search(r"JCCARD_27B FAIL", code)
    assert re.search(r"CONFIG\.HADDR_W.*fk33_seam_0", code)


def test_compute_halt_is_hbm_cattrip_or(tcl):
    """IMPORTANT 3: eng/compute_halt = DRAM_0_STAT_CATTRIP or DRAM_1_STAT_CATTRIP."""
    nets = _nets(tcl)
    halt = _net_of(nets, "%s/compute_halt" % P.ENG_CELL)
    res = [e for e in halt if e.endswith("/Res")]
    assert len(res) == 1, halt
    cell = res[0].split("/")[0]
    assert "create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 %s" % cell in tcl
    assert re.search(r"CONFIG\.C_SIZE \{1\} CONFIG\.C_OPERATION \{or\}\] \[get_bd_cells %s\]"
                     % cell, tcl)
    ops = {_net_of(nets, "%s/Op1" % cell).__contains__("hbm/DRAM_0_STAT_CATTRIP"),
           _net_of(nets, "%s/Op2" % cell).__contains__("hbm/DRAM_1_STAT_CATTRIP")}
    assert ops == {True}
    # the loader's own CATTRIP inputs are unchanged
    assert "%s/hbm_cattrip0" % G.LOADER_CELL in _net_of(nets, "hbm/DRAM_0_STAT_CATTRIP")
    assert "%s/hbm_cattrip1" % G.LOADER_CELL in _net_of(nets, "hbm/DRAM_1_STAT_CATTRIP")
    assert "halt_z" not in tcl


def test_fast_pop_read_back_not_set(tcl):
    """Minor 6: build 20's patch sets eng's FAST_POP false; the BD reads it back and
    refuses otherwise, and does NOT set it (setting it would hide an unpatched tree)."""
    code = "\n".join(_code_lines(tcl))
    assert re.search(r"get_property CONFIG\.FAST_POP \[get_bd_cells %s\]" % P.ENG_CELL, code)
    assert re.search(r"CONFIG\.FAST_POP[^\n]*\n[^\n]*string is false[^\n]*\n[^\n]*error", code)
    assert not re.search(r"set_property[^\n]*CONFIG\.FAST_POP", code)


def test_grant_masters_read_back_as_axi3(tcl):
    """Minor 9: bcgrant m0/m1 PROTOCOL read back as AXI3 before they reach SAXI_30/31."""
    for k, port in enumerate(P.CARD_SAXI):
        chk = tcl.find("get_property CONFIG.PROTOCOL [get_bd_intf_pins %s/m%d]" % (P.GRANT_CELL, k))
        con = tcl.find("connect_bd_intf_net [get_bd_intf_pins %s/m%d] [get_bd_intf_pins hbm/SAXI_%02d]"
                       % (P.GRANT_CELL, k, port))
        assert 0 <= chk < con, (k, chk, con)


def test_no_stale_fk33_clock_comments(tcl):
    """Minor 7: no comment claims the FK33's two-domain axil2eng on this board."""
    for l in tcl.splitlines():
        if l.lstrip().startswith("#"):
            assert "xdma/axi_aclk" not in l, l
            assert "NUM_CLKS 2" not in l, l
            assert "xdma's domain" not in l, l


def test_populate_reads_git_not_working_tree():
    """Minor 5: the scratch copy comes from `git archive <rev>`, so an old revision's
    generator text appears there, not the working tree's."""
    import subprocess
    rev = "68439b0"
    scratch = os.path.join(os.path.expanduser("~"), "regress_scratch", "t8_populate_test")
    G._populate(scratch, rev=rev)
    want = subprocess.run(["git", "show", "%s:hw/jc/card/gen_jc_card.py" % rev], cwd=REPO,
                          stdout=subprocess.PIPE, check=True).stdout.decode()
    got = _read(os.path.join(scratch, "hw", "jc", "card", "gen_jc_card.py"))
    assert got == want
    assert got != _read(os.path.join(HERE, "gen_jc_card.py"))
    assert os.path.isfile(os.path.join(scratch, "sim", "check_bd_ports.py"))
    assert not os.path.exists(os.path.join(scratch, "hw", "fk33", "results"))


# ---- the token loop and the link (plan 2026-11-04 Task 7) -------------------------------
def test_link_cells(tcl):
    for kind, ref, cell in (("module -reference", G.TOK_MODULE, G.TOK_CELL),
                            ("module -reference", G.GTG_MODULE, G.GTG_CELL),
                            ("ip -vlnv", G.AUR_VLNV, G.AUR_CELL)):
        n = len(re.findall(r"^create_bd_cell -type %s %s %s$" % (kind, re.escape(ref), cell), tcl, re.M))
        assert n == 1, (ref, cell, n)


def test_seam_sits_behind_the_loop(tcl):
    flat = [set(n) for n in _intf_nets(tcl)]
    assert {"%s/m_seam" % G.TOK_CELL, "%s/s_axi" % P.SEAM_CELL} in flat
    assert not any("%s/s_axi" % P.SEAM_CELL in n and any(e.startswith("axil2eng/") for e in n) for n in flat)
    assert any("%s/s_host" % G.TOK_CELL in n and any(e.startswith("axil2eng/") for e in n) for n in flat)


def test_loop_ctl_and_hbm_ports(tcl):
    flat = [set(n) for n in _intf_nets(tcl)]
    assert {"%s/m_hbm" % G.TOK_CELL, "%s/S02_AXI" % G.HBM_SC_CELL} in flat
    assert {"%s/s_ctl" % G.TOK_CELL, "axil2eng/M%02d_AXI" % G.TOK_CTL_MI} in flat
    assert re.search(r"CONFIG\.NUM_SI \{3\} CONFIG\.NUM_MI \{1\} CONFIG\.NUM_CLKS \{1\}\] \[get_bd_cells %s\]"
                     % G.HBM_SC_CELL, tcl)
    assert {"%s/m_axis_tx" % G.TOK_CELL, "%s/USER_DATA_S_AXIS_TX" % G.AUR_CELL} in flat
    assert {"%s/USER_DATA_M_AXIS_RX" % G.AUR_CELL, "%s/s_axis_rx" % G.TOK_CELL} in flat


def test_loop_address_map(tcl):
    assert re.search(r"assign_bd_address -offset 0x0000E000 -range 4K .*\{%s/s_host/reg0\}" % G.TOK_CELL, tcl)
    assert re.search(r"assign_bd_address -offset 0x00020000 -range 64K .*\{%s/s_ctl/reg0\}" % G.TOK_CELL, tcl)
    assert re.search(r"get_bd_addr_spaces %s/m_seam\] \[get_bd_addr_segs \{%s/s_axi/reg0\}\]"
                     % (G.TOK_CELL, P.SEAM_CELL), tcl)
    assert "%s/m_hbm 16" % G.TOK_CELL in tcl
    for sp, n in (("%s/%s" % (G.CTL_CELL, G.CTL_AXIL_INTF), 4), ("%s/m_hbm" % G.TOK_CELL, 32),
                  ("%s/m_seam" % G.TOK_CELL, 1)):
        assert "%s %d" % (sp, n) in tcl, (sp, n)


def test_every_aurora_input_is_driven(tcl):
    import aurora_ties as T
    flat = _nets(tcl)
    intf = {"s_axi_tx_tdata", "s_axi_tx_tkeep", "s_axi_tx_tlast", "s_axi_tx_tvalid",
            "gt_refclk1_p", "gt_refclk1_n", "rxp", "rxn"}       # through BD interfaces
    seen = 0
    for name, d, w in G.aurora_core_ports():
        if d != "in":
            continue
        seen += 1
        if name in intf:
            continue
        net = _net_of(flat, "%s/%s" % (G.AUR_CELL, name))
        if name in T.MAPPED:
            assert len(net) >= 2, name          # a real net, from tok or gtgclk
            continue
        v = T.tie_value(name, w or 1, G.LINK_NLANES)
        assert v is not None, name
        cell = "tie_%s" % name
        m = re.search(r"CONFIG.CONST_WIDTH \{%d\} CONFIG.CONST_VAL \{0x([0-9A-F]+)\}\] \[get_bd_cells %s\]"
                      % (w or 1, cell), tcl)
        assert m and int(m.group(1), 16) == int(v, 2), (name, v)
        assert "%s/dout" % cell in net, name
    assert seen > 30, seen


def test_aurora_resets_and_init_clk(tcl):
    """Task 5 rulings: TX/RX_Simplex has tx_reset_pb and rx_reset_pb, both from aur_reset_pb;
    init_clk of the core and of tok's init domain is jc_gtg_clk's init_clk, not sclk."""
    flat = _nets(tcl)
    rpb = _net_of(flat, "%s/aur_reset_pb" % G.TOK_CELL)
    assert {"%s/tx_reset_pb" % G.AUR_CELL, "%s/rx_reset_pb" % G.AUR_CELL} <= rpb
    ic = _net_of(flat, "%s/init_clk" % G.GTG_CELL)
    assert {"%s/init_clk" % G.AUR_CELL, "%s/init_clk" % G.TOK_CELL} <= ic
    assert not _net_of(flat, "%s/sclk" % G.GTG_CELL) & {"%s/init_clk" % G.AUR_CELL}
    assert "CONFIG.INIT_DIV [jc_init_div 10.3125]" in tcl


def test_diffctrl_is_the_measured_swing(tcl):
    m = re.search(r"CONFIG.CONST_VAL \{0x([0-9A-F]+)\}\] \[get_bd_cells tie_gt_txdiffctrl\]", tcl)
    assert m and int(m.group(1), 16) == 0b11000


def test_module_ref_count_includes_link(tcl):
    assert "if {$_nmr != %d}" % G.N_MODULE_REFS in tcl and G.N_MODULE_REFS == 8


def test_link_stamp_and_refusals():
    assert G.link_refclk({}) == "gtg" and G.link_rate({}) == "10.3125"
    with pytest.raises(SystemExit):
        G.link_refclk({"JC_LINK_REFCLK": "mmcm"})
    for bad in ("5.0", "1.25"):          # 1.25: Task 5 ruling, not wired into the card
        with pytest.raises(SystemExit):
            G.link_rate({"JC_LINK_RATE": bad})
    with pytest.raises(SystemExit):
        G.stamp_inputs({"JC_LINK_RATE": "1.25"})
    names = {n for _, n, _ in G.stamp_inputs({})}
    assert {"JC_LINK_REFCLK", "JC_LINK_RATE"} <= names


def test_link_refclk_pin_is_refused_citing_the_undriven_pins(capsys):
    """Final ruling 2026-11-11: AK38/AK39 (the IP's nominal MGTREFCLK0 of quad X0Y0) are not
    driven on the Jungle Cat board, so a `pin` card's link could never lock. Refused, with the
    pins named; the stamp path refuses it too."""
    for env in ({"JC_LINK_REFCLK": "pin"},):
        with pytest.raises(SystemExit) as e:
            G.link_refclk(env)
        msg = str(e.value)
        assert "AK38" in msg and "AK39" in msg and "undriven" in msg, msg
        with pytest.raises(SystemExit):
            G.stamp_inputs(env)
    assert G.link_refclk({"JC_LINK_REFCLK": "gtg"}) == "gtg"


def test_gt_ports_in_top_and_refclk_pin():
    top = _strip_vhdl_comments(_read(TOP))
    for n, d, w in G.GT_TOP_PORTS:
        want = r"%s\s*:\s*%s\s+std_logic%s" % (n, d, r"_vector\(0 downto 0\)" if w else r"\b")
        assert len(re.findall(want, top)) == 2, n          # entity and component
    xdc = _read(XDC)
    assert G.refclk_pins() == ["AK38", "AK39"]
    assert re.search(r"^set_property PACKAGE_PIN AK38 \[get_ports gt_refclk_clk_p\]$", xdc, re.M)
    assert re.search(r"^create_clock -name gt_refclk -period 6.400 \[get_ports gt_refclk_clk_p\]$", xdc, re.M)


def test_gtg_mmcm_has_a_site_and_a_dedicated_route():
    """finding 3 with the Task 5 ruling's pattern: in a BD the module reference sits under
    `inst`, so *gtgclk/u_mmcm matches nothing; *gtgclk/*u_mmcm matches one. BACKBONE on the
    BUFG -> MMCM net (IBERT G's form)."""
    xdc = _read(XDC)
    assert re.search(r"^set_property LOC MMCM_X0Y2 \[get_cells -hier -filter "
                     r"\{NAME =~ \*gtgclk/\*u_mmcm\}\]$", xdc, re.M)
    assert re.search(r"^set_property CLOCK_DEDICATED_ROUTE BACKBONE \[get_nets -of_objects \[get_pins -hier "
                     r"-filter \{NAME =~ \*gtgclk/\*u_mmcm/CLKIN1\}\]\]$", xdc, re.M)


# ---- A_TILED / A_CLK_SPLIT (a450 plan, Tasks 8 and 9) ---------------------------------
_SPLIT = {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"}


def _render(env):
    return "\n".join(_code_lines(G.render_tcl(P, G.CLK_CORE_DEFAULT, env)))


def test_a_flags_default_off_and_refusals():
    assert not G.a_tiled({}) and not G.a_split({})
    for bad in ("2", "yes", "true"):
        with pytest.raises(SystemExit):
            G.a_tiled({"JC_A_TILED": bad})
    with pytest.raises(SystemExit):
        G.a_split({"JC_A_CLK_SPLIT": "1"})         # split without tiled
    names = {n for _, n, _ in G.stamp_inputs({})}
    assert {"JC_A_TILED", "JC_A_CLK_SPLIT"} <= names


def test_tiled_split_off_renders_today_s_clocking():
    t = _render({"JC_A_TILED": "1"})
    assert "clk_wiz_a" not in t and "axi_clock_converter" not in t
    assert re.search(r"CONFIG\.A_TILED \{true\}", t)
    assert re.search(r"CONFIG\.A_CLK_SPLIT \{false\}", t)


def test_split_on_puts_hbm_and_engine_ports_on_aclk_a():
    t = _render(_SPLIT)
    assert "clk_wiz_a" in t and "aclk_reset" in t
    assert "CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {450.000}" in t
    assert "CONFIG.USER_AXI_INPUT_CLK_FREQ {450}" in t
    assert "CONFIG.USER_AXI_INPUT_CLK1_FREQ {450}" in t
    assert re.search(r"CONFIG\.A_CLK_SPLIT \{true\}", t)
    nets = _nets(t)
    hbm_clk = _net_of(nets, "hbm/AXI_00_ACLK")
    assert G.ACLK_A in hbm_clk, "SAXI_00 is not on aclk_a"
    for s in list(range(1, 16)) + list(range(17, 32)):
        assert G.ACLK_A in _net_of(nets, "hbm/AXI_%02d_ACLK" % s), s
    assert "%s/hbm_aclk" % P.ENG_CELL in _net_of(nets, G.ACLK_A)


def test_split_on_crosses_read_write_masters_with_converters():
    t = _render(_SPLIT)
    n = len(re.findall(r"create_bd_cell[^\n]*axi_clock_converter", t))
    assert n == 3, "loader + two grant masters need a converter each, got %d" % n
    assert re.search(r"CONFIG\.NUM_CLKS \{2\}", t), "SAXI_16 smartconnect is not two-clock"


def test_split_off_default_render_is_unchanged_by_the_flags():
    assert _render({}) == _render({"JC_A_TILED": "0", "JC_A_CLK_SPLIT": "0"})


# ---- the HBM port reset into A (a450 Task 8, carry C1) --------------------------------
# rtl/mv_rdfsm.vhd's never-reset `owed` count is cleared only by a synchronised copy of
# the HBM AXI port reset; the engine's hbm_aresetn must be on the SAME net as the
# ARESET_N of every HBM port its 28 masters use, in either clocking.
def test_engine_hbm_aresetn_is_the_engine_ports_areset():
    for env in ({}, {"JC_A_TILED": "1"}, _SPLIT):
        nets = _nets(_render(env))
        net = _net_of(nets, "%s/hbm_aresetn" % P.ENG_CELL)
        for port in P.ENG_PORT_MAP:
            assert "hbm/AXI_%02d_ARESET_N" % port in net, (env, port)


def test_split_on_hbm_switch_clock_ports_are_on_aclk_a():
    """Carry C3 (Task 7 finding): the HBM switch clock is taken from the ports named in
    USER_CLK_SEL_LIST0/1 (AXI_00, AXI_16).  With the split on, both must be on aclk_a,
    the clock every engine port runs on, not on clk_core."""
    t = _render(_SPLIT)
    assert re.search(r"CONFIG\.USER_CLK_SEL_LIST0 \{AXI_00_ACLK\} CONFIG\.USER_CLK_SEL_LIST1 "
                     r"\{AXI_16_ACLK\}", t)
    nets = _nets(t)
    for s in (0, 16):
        assert G.ACLK_A in _net_of(nets, "hbm/AXI_%02d_ACLK" % s), s
        assert G.ACLK_A_RSTN in _net_of(nets, "hbm/AXI_%02d_ARESET_N" % s), s


def test_hbm_aresetn_forwarded_engine_to_tiled_array():
    """Task 8 review m5: the two hbm_aresetn links above mv4i_tiled have no bench (the
    descriptor benches leave the port at '1'), so a dropped map line would survive every
    row and leave the clear disconnected behind a default.  Pin both map lines."""
    def code(p):
        return "\n".join(l.split("--", 1)[0] for l in open(os.path.join(REPO, p)))
    eng = code("hw/fk33/rtl/fk33_engine.vhd")
    m = re.search(r"^\s*eng\s*:\s*entity work\.matvec_int4_desc_axi\b(.*?);", eng, re.M | re.S)
    assert m and re.search(r"\bhbm_aresetn\s*=>\s*hbm_aresetn\b", m.group(1))
    desc = code("rtl/matvec_int4_desc_axi.vhd")
    g = re.search(r"^\s*g_tiled\s*:\s*if A_TILED generate(.*?)end generate", desc, re.M | re.S)
    assert g and re.search(r"\bhbm_aresetn\s*=>\s*hbm_aresetn\b", g.group(1))
