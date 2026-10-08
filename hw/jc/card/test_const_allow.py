"""jccard_const_allow.tcl: every jccard2 constant input bit is allowed, and nothing else."""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOW = os.path.join(HERE, "jccard_const_allow.tcl")
CAPTURE = os.path.join(HERE, "results", "jccard2_netlist_const_2026-10-07.txt")


def _check(pins):
    """pins: [(pin, type)] -> [0/1] via tclsh."""
    script = "source {%s}\n" % ALLOW + "".join(
        "puts [jcc_const_allowed {%s} %s]\n" % (p, t) for p, t in pins)
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True, check=True)
    return [int(x) for x in r.stdout.split()]


def _captured():
    out = []
    with open(CAPTURE) as f:
        for line in f:
            body = line.split(None, 1)[1].strip()
            pin, typ = body.rsplit(":", 1)
            out.append((pin, typ))
    return out


def test_all_729_captured_bits_are_allowed():
    pins = _captured()
    assert len(pins) == 729
    assert _check(pins) == [1] * 729


def test_other_bits_polarity_ports_and_cells_are_refused():
    cases = [
        ("u_bd/jcc_i/eng/job_index[8]", "GROUND"),      # job counter uses bits 0..8
        ("u_bd/jcc_i/bcgrant/b_awlen[0]", "GROUND"),    # wrong polarity (entry is POWER)
        ("u_bd/jcc_i/card/hw_data[0]", "GROUND"),       # port not on the list
        ("u_bd/jcc_i/card/m_rdata", "GROUND"),          # vector entry must not match a scalar
        ("u_bd/jcc_i/fk33_seam_0/f_unit_stub[0]", "GROUND"),  # scalar entry, indexed pin
        ("u_bd/jcc_i/ctl/m_axi_rdata[0]", "GROUND"),    # cell with no entries
    ]
    assert _check(cases) == [0] * len(cases)
