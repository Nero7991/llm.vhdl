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
