"""hw/jc/card/test_jccard_levers.py -- Task 9 fix round 1, CRITICAL C1.

Runs hw/jc/card/jccard_levers.tcl's pure parsing proc (no Vivado, no project) under
plain `tclsh` against real excerpts of Vivado's own synthesis trace
(hw/jc/card/testdata/*.txt, copied verbatim from three real builds' bd_wrapper.vds),
proving the proc classifies both the OFF and the ON spelling Vivado actually uses
for a boolean generic ("0"/"false" and "1"/"true"), not just the word "false" the
original build_card.tcl compared against (which would have refused build20 itself).

    python3 -m pytest hw/jc/card/test_jccard_levers.py -q
"""
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TCL = os.path.join(HERE, "jccard_levers.tcl")
DATA = os.path.join(HERE, "testdata")


def _status(name, fixture):
    r = subprocess.run(["tclsh", TCL, name, os.path.join(DATA, fixture)],
                        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    status = next(l.split(" ", 1)[1] for l in lines if l.startswith("STATUS "))
    detail = next(l.split(" ", 1)[1] for l in lines if l.startswith("DETAIL "))
    return status, detail


# ---- the OFF spelling: build20, every lever off, real excerpt ---------------------

@pytest.mark.parametrize("lever", ["NWIDE", "SWEEP_PIPE", "SCORE_EARLY"])
def test_build20_excerpt_is_off(lever):
    status, _ = _status(lever, "vds_build20_off.txt")
    assert status == "off"


# ---- the ON spelling: build21 (SWEEP_PIPE/SCORE_EARLY on, NWIDE untouched) and
#      build27b_1 (every lever on, including FAST_POP) -- both real excerpts --------

def test_build21_excerpt_nwide_is_off():
    status, _ = _status("NWIDE", "vds_build21_mixed.txt")
    assert status == "off"


@pytest.mark.parametrize("lever", ["SWEEP_PIPE", "SCORE_EARLY"])
def test_build21_excerpt_c_levers_are_on(lever):
    status, _ = _status(lever, "vds_build21_mixed.txt")
    assert status == "on"


@pytest.mark.parametrize("lever", ["NWIDE", "SWEEP_PIPE", "SCORE_EARLY", "FAST_POP"])
def test_build27b1_excerpt_everything_is_on(lever):
    status, _ = _status(lever, "vds_build27b1_on.txt")
    assert status == "on"


# ---- a missing bind line is refused exactly like a wrong value, never a pass ------

def test_missing_bind_line_is_missing_not_off():
    status, detail = _status("NWIDE", "vds_no_levers.txt")
    assert status == "missing"
    assert "no bind line found" in detail


# ---- the word spelling must still work (a non-bool-typed future lever) ------------

def test_word_false_is_off(tmp_path):
    f = tmp_path / "word.txt"
    f.write_text("\tParameter FOO bound to: false - type: bool \n")
    status, _ = _status("FOO", str(f))
    assert status == "off"


def test_word_true_is_on(tmp_path):
    f = tmp_path / "word.txt"
    f.write_text("\tParameter FOO bound to: true - type: bool \n")
    status, _ = _status("FOO", str(f))
    assert status == "on"


def test_unrecognised_value_is_mixed_not_silently_passed(tmp_path):
    f = tmp_path / "word.txt"
    f.write_text("\tParameter FOO bound to: regs - type: string \n")
    status, detail = _status("FOO", str(f))
    assert status == "mixed"
    assert "regs" in detail


def test_inconsistent_occurrences_are_mixed(tmp_path):
    f = tmp_path / "two.txt"
    f.write_text(
        "\tParameter FOO bound to: 0 - type: bool \n"
        "\tParameter FOO bound to: 1 - type: bool \n"
    )
    status, _ = _status("FOO", str(f))
    assert status == "mixed"
