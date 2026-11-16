"""hw/fk33/test_fk33_a450_contract.py -- the a450 generics' contract on the FK33 (a450 final
review I2).  No Vivado, no hardware.

fk33_engine forwards A_TILED / A_CLK_SPLIT to matvec_int4_desc_axi.  Under the split the
descriptor master m27 runs on core_clk (D_DUAL), so its HBM port needs a clock converter;
split off, hbm_aclk must be core_clk.  The FK33 block design (gen_pcieep._eng_block) has
neither, so it reads both generics back and refuses anything but false.  The Jungle Cat
card (gen_jc_card.py), which builds the converter, does not go through _eng_block.

    python3 -m pytest -q hw/fk33/test_fk33_a450_contract.py
"""
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "card"))
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))
saved = sys.argv
sys.argv = ["gen_pcieep.py"]
import gen_pcieep as P  # noqa: E402
sys.argv = saved
import gen_jc_card as G  # noqa: E402

TCLSH = subprocess.run(["which", "tclsh"], capture_output=True).returncode == 0
REFUSAL = re.compile(r"^foreach _g \{A_TILED A_CLK_SPLIT\} \{\n.*?^\}$", re.S | re.M)


def _read(rel):
    with open(os.path.join(REPO, rel)) as f:
        return f.read()


def _refusal(text):
    m = REFUSAL.findall(text)
    assert len(m) == 1, len(m)
    return m[0]


def test_fk33_bd_reads_back_and_refuses_the_a450_generics():
    """In the FK33 engine block, after the cell exists, and in the committed reference Tcl
    (regenerated from its GENSTAMP inputs) byte for byte."""
    blk = P._eng_block()
    r = _refusal(blk)
    assert blk.index("create_bd_cell -type module -reference fk33_engine") < blk.index(r)
    assert "FK33_A450 FAIL" in r and "string is false -strict $_v" in r
    assert _refusal(_read("hw/fk33/build_fk33_pcieep.tcl")) == r


def test_jc_card_does_not_carry_the_fk33_refusal():
    for env in ({}, {"JC_A_TILED": "1"}, {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"}):
        assert "FK33_A450" not in G.render_tcl(P, G.CLK_CORE_DEFAULT, env)


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
@pytest.mark.parametrize("tiled,split,ok", [("false", "false", True), ("true", "false", False),
                                            ("false", "true", False), ("true", "true", False)])
def test_fk33_refusal_has_teeth(tiled, split, ok):
    script = """
proc get_bd_cells {c} { return $c }
proc get_property {k c} { return [dict get {CONFIG.A_TILED %s CONFIG.A_CLK_SPLIT %s} $k] }
if {[catch {
%s
} err]} { puts "ERR $err" } else { puts OK }
""" % (tiled, split, _refusal(P._eng_block()))
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    out = r.stdout
    if ok:
        assert re.search(r"^OK$", out, re.M) and "FK33_A450 eng A_TILED false" in out, out
    else:
        assert re.search(r"^ERR FK33_A450 FAIL: eng A_(TILED|CLK_SPLIT) is \"true\"", out, re.M), out


def test_engine_text_states_the_split_clocking():
    """The false "all 28 masters on hbm_aclk" is gone from the generator and its output."""
    for rel in ("hw/fk33/gen_fk33_engine.py", "hw/fk33/rtl/fk33_engine.vhd"):
        t = _read(rel)
        assert "true runs the tiles and all 28 masters on hbm_aclk" not in t, rel
        assert "the DESCRIPTOR master m27 on core_clk" in t, rel
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_fk33_engine.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.startswith("GEN_FK33_ENGINE_CHECK: OK"), r.stdout


def test_desc_axi_refuses_split_without_tiled_and_dual_clk():
    """The out-of-range natural (Vivado stops on it; it ignores assert severity failure)
    and the assert (GHDL says why).  Elaboration evidence is in the fix report (GHDL runs
    of tb_matvec_fk33_desc with the generic overridden)."""
    t = _read("rtl/matvec_int4_desc_axi.vhd")
    assert re.search(r"constant SPLIT_NEEDS : natural :=\s*0 - boolean'pos\(A_CLK_SPLIT and not "
                     r"\(A_TILED and DUAL_CLK\)\);", t)
    assert re.search(r"assert not A_CLK_SPLIT or \(A_TILED and DUAL_CLK\)\s*report \"[^\"]*\"\s*"
                     r"severity failure;", t)
