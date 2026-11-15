"""hw/fk33/test_fk33_pblock.py -- the FK33 floorplan's cell path against the RTL hierarchy
(a450 Task 8 review, I2).  No Vivado.

fk33_pblock.xdc puts the engine's core in pb_core by hierarchical name.  The name is
re-derived here from the VHDL itself (instance labels and generate labels), for both
values of matvec_int4_desc_axi's A_TILED, so a rename under the engine (the a450 g_core
generate was one) turns this red instead of leaving an empty pblock behind a 12-180
warning.  The build's own refusal of an empty pb_core is checked to be present.

    python3 -m pytest -q hw/fk33/test_fk33_pblock.py
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
BD_PREFIX = "bd_i/eng/inst/"          # the BD cell `eng` and its module-reference wrapper


def _read(rel):
    with open(os.path.join(REPO, rel)) as f:
        return f.read()


def _strip(t):
    return "\n".join(l.split("--", 1)[0] for l in t.splitlines())


def _inst(text, entity):
    """label of the (single) `label : entity work.<entity>` in text"""
    m = re.findall(r"^\s*(\w+)\s*:\s*entity\s+work\.%s\b" % entity, _strip(text), re.M)
    assert len(m) == 1, (entity, m)
    return m[0]


def _gen_inst(text, entity, cond):
    """`<generate>.<instance>` for the instance of <entity> inside `g : if <cond> generate`;
    `entity` may be a component (no `entity work.`)."""
    t = _strip(text)
    for g in re.finditer(r"^\s*(\w+)\s*:\s*if\s+(.*?)\s+generate\b(.*?)\bend\s+generate\b",
                         t, re.M | re.S):
        if g.group(2).strip() != cond:
            continue
        m = re.search(r"^\s*(\w+)\s*:\s*(?:entity\s+work\.)?%s\b" % entity, g.group(3), re.M)
        if m:
            return "%s.%s" % (g.group(1), m.group(1))
    raise AssertionError("no %s inside an `if %s generate`" % (entity, cond))


def derived_paths():
    """{A_TILED: the cell the floorplan must hold} from the RTL text."""
    eng = _inst(_read("hw/fk33/rtl/fk33_engine.vhd"), "matvec_int4_desc_axi")
    desc = _read("rtl/matvec_int4_desc_axi.vhd")
    core = _inst(_read("rtl/matvec_int4.vhd"), "matvec_core")
    return {
        False: BD_PREFIX + "%s/%s/%s" % (eng, _gen_inst(desc, "matvec_int4", "not A_TILED"), core),
        True: BD_PREFIX + "%s/%s" % (eng, _gen_inst(desc, "mv4i_tiled", "A_TILED")),
    }


def xdc_cells(xdc):
    """the cell names on the live add_cells_to_pblock pb_core line(s)"""
    out = []
    for l in xdc.splitlines():
        if l.lstrip().startswith("#"):
            continue
        m = re.match(r"^add_cells_to_pblock \[get_pblocks pb_core\] \[get_cells (?:-quiet )?"
                     r"(\{[^}]*\}|\S+?)\]$", l.strip())
        if m:
            out += m.group(1).strip("{}").split()
    return out


def test_pblock_path_resolves_for_both_a_tiled_values():
    want = derived_paths()
    cells = xdc_cells(_read("hw/fk33/fk33_pblock.xdc"))
    assert cells, "fk33_pblock.xdc has no live add_cells_to_pblock pb_core line"
    for tiled, path in want.items():
        assert path in cells, "A_TILED=%s: %s is not in pb_core's cells %s" % (tiled, path, cells)
    for c in cells:
        assert c in want.values(), "pb_core names %s, which no A_TILED value elaborates" % c


def test_pblock_check_teeth_old_path_is_refused():
    """the pre-Task-8 line, `.../eng/dut/core`, resolves for neither value"""
    old = "add_cells_to_pblock [get_pblocks pb_core] [get_cells bd_i/eng/inst/eng/dut/core]"
    cells = xdc_cells(old)
    assert cells == ["bd_i/eng/inst/eng/dut/core"]
    assert not set(cells) & set(derived_paths().values())


def test_build_refuses_an_empty_pb_core():
    t = _read("hw/fk33/build_fk33_pcieep.tcl")
    rng = t.index('puts "FK33_PBLK pb_core $pbr"')
    m = re.search(r"set pbn \[llength \[get_cells -quiet -of_objects \[get_pblocks pb_core\]\]\]\n"
                  r"if \{\$pbn == 0\} \{\n    error \"FK33_PBLK FAIL: pb_core holds no cells", t)
    assert m and m.start() > rng, "no empty-pb_core refusal after the range check"
