"""hw/jc/card/test_gen_ooc27_top.py -- Task 10.  Exercises gen_ooc27_top.py
for real (no Vivado): it is pure Python and pure text, so this runs it
against THIS repository's own committed RTL (the 9B fk33_card.vhd) as a
smoke test -- a representative one, not a stand-in, since the wire pairs'
widths and directions are checked the same way regardless of which model is
compiled, only the absolute widths differ (hw_addr/hr_addr: 14 bits at 9B,
15 at 27B) -- and separately proves the generator's own teeth: that its
width/direction checks actually ABORT on a wrong pairing, rather than just
never having been exercised.

    python3 -m pytest hw/jc/card/test_gen_ooc27_top.py -q
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
GEN = os.path.join(HERE, "gen_ooc27_top.py")


def _run(repo_root, out, extra=()):
    return subprocess.run(
        [sys.executable, GEN, repo_root, "--out", out, *extra],
        capture_output=True, text=True)


# ---- the 9B smoke test: the committed repo's own fk33_card.vhd has 14-bit
#      hw_addr/hr_addr, so this needs the matching --haddr-w/--regmax pair
#      (clog2(16384) == 14), NOT build 27B-1's own 15/17408. --------------

def test_smoke_against_the_committed_9b_card(tmp_path):
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    assert re.search(r"^GENOOC27_WROTE ", r.stdout, re.M)
    assert os.path.exists(out)


def test_output_has_the_right_shape(tmp_path):
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    assert "entity jc_ooc27_top is" in text
    assert "end entity;" in text
    assert "architecture rtl of jc_ooc27_top is" in text
    assert "end architecture;" in text
    assert "u_eng : entity work.fk33_engine" in text
    assert "u_seam : entity work.fk33_seam" in text
    assert "u_card : entity work.fk33_card" in text
    # every generic actually bound, matching jc_card_bd.tcl's own CONFIG for
    # these two module-reference cells
    assert 'CB_STYLE => "distributed"' in text
    assert "HADDR_W => 14" in text
    assert "REGMAX => 16384" in text
    assert "CAP_NORM_HBM => 1" in text


def test_output_has_no_dangling_generic_identifiers(tmp_path):
    """Every effective port type this generator emits must be fully
    numeric (a literal width): a bare identifier surviving substitution
    would be an unbound generic reaching the port map, which is exactly
    what width_of()/subst() are supposed to refuse before emission."""
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    for m in re.finditer(r"(std_logic_vector|signed|unsigned)\(([^)]*)\)", text):
        bounds = m.group(2)
        assert re.match(r"^[0-9]+ downto [0-9]+$", bounds), (
            "non-numeric bound %r in %r" % (bounds, m.group(0)))


def test_every_top_port_appears_exactly_once(tmp_path):
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    m = re.search(r"entity jc_ooc27_top is\s*port\(\n(.*?)\n\s*\);\n", text, re.S)
    port_lines = [l for l in m.group(1).splitlines() if ":" in l]
    names = [l.split(":")[0].strip() for l in port_lines]
    assert len(names) == len(set(names)), "a port name was emitted more than once"
    # exactly the 4 shared/control ports plus one per unwired instance port
    assert "clk" in names and "rst" in names and "rstn" in names and "compute_halt" in names


# ---- teeth: the width/direction checks must actually abort on a bad pairing

def test_aborts_on_a_width_mismatched_pair(tmp_path, monkeypatch):
    """Mutation test: wrong --haddr-w (not matching the committed 9B card's
    actual 14-bit hw_addr/hr_addr) must be refused, not silently emit a file
    with a mismatched net -- this is the exact class of error the real
    build 27B-1 vs the committed 9B card differ by."""
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "15", "--regmax", "17408"])
    assert r.returncode != 0
    assert "GENOOC27 ABORT" in r.stderr
    assert "hw_addr" in r.stderr or "hr_addr" in r.stderr
    assert not os.path.exists(out), "a failed generation must not leave a partial file"


def test_aborts_on_a_port_wired_twice(tmp_path):
    """Mutation test on the generator's own pair table: repoint one
    SEAM_CARD pair at a card port ANOTHER pair already claims ("busy", via
    the very first pair). A port wired by two different nets is exactly
    the kind of mis-wiring this generator exists to refuse rather than
    silently resolve to whichever net happens to be looked up first."""
    src = open(GEN).read()
    mutated = src.replace(
        '("d_busy", "busy"), ("d_tok_done", "tok_done"),',
        '("d_busy", "busy"), ("d_tok_done", "busy"),',
        1)
    assert mutated != src, "mutation did not apply; SEAM_CARD's text changed"
    mutant = str(tmp_path / "gen_ooc27_top_mutant.py")
    with open(mutant, "w") as f:
        f.write(mutated)
    out = str(tmp_path / "mutant_jc_ooc27_top.vhd")
    r = subprocess.run(
        [sys.executable, mutant, REPO, "--out", out,
         "--haddr-w", "14", "--regmax", "16384"],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "GENOOC27 ABORT" in r.stderr
    assert "wired more than once" in r.stderr
    assert not os.path.exists(out)


def test_aborts_on_a_direction_mismatched_pair(tmp_path):
    """Mutation test: repoint one SEAM_CARD pair's CARD side at an unwired
    card port of a DIFFERENT width (card.obs_unit, unsigned(2 downto 0), 3
    bits, vs. seam.d_err_code's 4 bits) -- a clean width mismatch, with no
    double-claim involved, so this isolates the width/direction check
    itself from the double-wire check test_aborts_on_a_port_wired_twice
    exercises."""
    src = open(GEN).read()
    mutated = src.replace(
        '("d_err_code", "err_code"),',
        '("d_err_code", "obs_unit"),',
        1)
    assert mutated != src, "mutation did not apply; SEAM_CARD's text changed"
    mutant = str(tmp_path / "gen_ooc27_top_mutant2.py")
    with open(mutant, "w") as f:
        f.write(mutated)
    out = str(tmp_path / "mutant2_jc_ooc27_top.vhd")
    r = subprocess.run(
        [sys.executable, mutant, REPO, "--out", out,
         "--haddr-w", "14", "--regmax", "16384"],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "GENOOC27 ABORT" in r.stderr
    assert not os.path.exists(out)


# ---- fix round 1, CRITICAL C1: jc_card_bd.tcl never connects card's debug/
# observability outputs (obs_wsum and its siblings), the dead "m_*" HBM read
# bus, several of card's own AXI SIZE/BURST/WSTRB/RESP fields, bst_busy/
# done/err, or a_jobs_issued -- 2026-09-30's own "70 MHz" OOC number on
# fk33_card ALONE was obs_wsum's 60-level debug hash (fk33_llama_top.vhd:
# 8243), which drives NOTHING in the real card and is dead-code-eliminated
# there, kept alive only because this generator used to export EVERY
# unwired port, including it.
# A port the BD never connects to anything (inside OR outside the three
# cells) must be tied to `open` (an output) or a quiescent constant (an
# input), never exported, so synthesis can eliminate it exactly as the real
# build does. Only a port the BD connects to something OUTSIDE the three
# cells (HBM AXI, a host AXI4-Lite slave, clocks, reset, CATTRIP) may be
# exported. eng's own AXI ID fields (below) are a SEPARATE case, tied off
# for a different, narrower reason even though the BD DOES connect them --
# see test_bd_unconnected_eng_axi_id_fields_are_not_exported's own docstring.

BD_UNCONNECTED_CARD_OUTPUTS = [
    "obs_wsum", "obs_unit", "obs_opcode", "obs_step", "obs_dst", "obs_cmp",
    "obs_cmp_exp", "obs_res_take", "obs_res_ea", "obs_res_eb", "obs_norm_pub",
    "obs_norm_exp", "obs_norm_ssq", "obs_norm_n",
    "smp_valid", "smp_v", "smp_idx", "smp_done",
    "bst_busy", "bst_done", "bst_err", "a_jobs_issued",
    "m_arvalid", "m_araddr", "m_arlen", "m_arsize", "m_arburst", "m_rready",
]
BD_UNCONNECTED_CARD_INPUTS = [
    "m_arready", "m_rvalid", "m_rdata", "m_rlast",
    "kv0_rresp", "kv1_rresp", "kv_bresp", "bst_rresp", "bst_bresp",
]
BD_UNCONNECTED_ENG_OUTPUTS = ["m00_axi_awid", "m00_axi_arid", "m05_axi_awid"]
BD_UNCONNECTED_ENG_INPUTS = ["m00_axi_bid", "m00_axi_rid", "m05_axi_bid"]


def test_bd_unconnected_card_outputs_are_not_exported(tmp_path):
    """RED (fix round 1, C1): before the fix, every one of these was
    exported as card_<name>, including card_obs_wsum -- the exact debug
    hash the 2026-09-30 artifact note traced the "70 MHz" OOC number to."""
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    for nm in BD_UNCONNECTED_CARD_OUTPUTS:
        assert ("card_%s " % nm) not in text and ("card_%s\n" % nm) not in text, (
            "card.%s is not connected to anything by jc_card_bd.tcl and must "
            "not be exported (tie to open instead)" % nm)
    for nm in BD_UNCONNECTED_CARD_INPUTS:
        assert ("card_%s " % nm) not in text and ("card_%s\n" % nm) not in text, (
            "card.%s is not connected to anything by jc_card_bd.tcl and must "
            "not be exported (tie to a quiescent constant instead)" % nm)


def test_bd_unconnected_card_outputs_are_tied_open(tmp_path):
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    m = re.search(r"u_card : entity work\.fk33_card.*?port map\((.*?)\);", text, re.S)
    card_map = m.group(1)
    for nm in BD_UNCONNECTED_CARD_OUTPUTS:
        pm = re.search(r"\b%s\s*=>\s*(\S+)" % re.escape(nm), card_map)
        assert pm, "card.%s missing from the port map entirely" % nm
        assert pm.group(1).rstrip(",") == "open", (
            "card.%s => %s, expected open" % (nm, pm.group(1)))


def test_bd_unconnected_eng_axi_id_fields_are_not_exported(tmp_path):
    """fix round 2 correction: HBM's SAXI interfaces DO carry
    AXI_xx_ARID/AWID/BID/RID, and jc_card_bd.tcl's interface-level
    `connect_bd_intf_net [get_bd_intf_pins eng/m00_axi] [get_bd_intf_pins
    hbm/SAXI_01]` (and its 27 siblings) DOES wire eng's own
    m*_axi_awid/arid/bid/rid to them, same as every other channel signal --
    these are NOT left unconnected by the BD the way card's debug ports are.
    They are excluded from gen_ooc27_top.py's AXI_SUFFIXES (and so land
    here, tied off rather than exported) for a narrower, eng-specific
    reason: eng drives its own m*_axi_awid/arid to a constant '0' internally
    (fk33_engine.vhd:1422/1432) and never reads bid/rid at all, so the real
    BD connection changes nothing eng actually does, and tying it off at
    this OOC top is harmless. See gen_ooc27_top.py's own AXI_SUFFIXES
    comment for the full reasoning."""
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    for nm in BD_UNCONNECTED_ENG_OUTPUTS + BD_UNCONNECTED_ENG_INPUTS:
        assert ("eng_%s " % nm) not in text and ("eng_%s\n" % nm) not in text


def test_bd_connected_ports_are_still_exported(tmp_path):
    """The fix must not become a blanket tie-off: HBM AXI masters, the host
    AXI4-Lite slaves and card's bst_*/kv_*_* ports the real BD DOES connect
    (to HBM, to the host, or to bcgrant, all outside the three-cell scope)
    must still reach the top level."""
    out = str(tmp_path / "jc_ooc27_top.vhd")
    r = _run(REPO, out, extra=["--haddr-w", "14", "--regmax", "16384"])
    assert r.returncode == 0, r.stdout + r.stderr
    text = open(out).read()
    for nm in ["eng_m00_axi_awvalid", "eng_s_axix_awvalid", "eng_s_axi_arvalid",
               "seam_s_axi_awvalid", "card_bst_arvalid", "card_kv0_arvalid"]:
        assert nm in text, "%s should still be exported (BD-connected outside scope)" % nm


# ---- fix round 1, IMPORTANT I1: every CONFIG.* the BD sets on eng/seam must
# be reproduced here, not just CB_STYLE. jc_card_bd.tcl:299 also sets
# CONFIG.USE_XEXP_PORT {true} on eng, which the original generator missed.

def _bd_generic_overrides(bd_text, cell, skip=()):
    pat = re.compile(
        r"set_property\s+CONFIG\.(\w+)\s+\{([^}]*)\}\s+\[get_bd_cells\s+%s\]" %
        re.escape(cell))
    out = {}
    for name, val in pat.findall(bd_text):
        if name in skip:
            continue
        out[name] = val
    return out


def test_eng_generics_match_the_bd_exactly():
    bd_text = open(os.path.join(REPO, "hw", "jc", "card", "jc_card_bd.tcl")).read()
    bd_eng = _bd_generic_overrides(bd_text, "eng")
    gen_src = open(GEN).read()
    m = re.search(r'ENG_GENERICS = \{([^}]*)\}', gen_src)
    gen_eng = dict(re.findall(r'"(\w+)":\s*\'?"?([^,\'"}]+)', m.group(1)))
    for name, bd_val in bd_eng.items():
        assert name in gen_eng, "eng CONFIG.%s (BD value %r) missing from ENG_GENERICS" % (name, bd_val)


def test_seam_generics_match_the_bd_exactly():
    bd_text = open(os.path.join(REPO, "hw", "jc", "card", "jc_card_bd.tcl")).read()
    bd_seam = _bd_generic_overrides(bd_text, "fk33_seam_0")
    gen_src = open(GEN).read()
    m = re.search(r'SEAM_GENERICS_FIXED = \{([^}]*)\}', gen_src, re.S)
    fixed_names = set(re.findall(r'"(\w+)":', m.group(1)))
    # HADDR_W/REGMAX are CLI-overridable (model-dependent widths), not fixed.
    fixed_names |= {"HADDR_W", "REGMAX"}
    missing = set(bd_seam) - fixed_names
    assert not missing, "seam CONFIG.%s set by the BD but not reproduced here" % missing
