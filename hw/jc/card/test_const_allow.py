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


def test_kv_write_address_beat_alignment_bits_are_allowed():
    # jccard9 (2026-10-10): attn_kv_axi aligns every KV write burst to a 32-byte beat, so
    # c_awaddr[4:0] is 0 by construction; bit 5 is a real address bit and must still refuse.
    ok = [("u_bd/jcc_i/bcgrant/c_awaddr[%d]" % b, "GROUND") for b in range(5)]
    assert _check(ok) == [1] * 5
    bad = [("u_bd/jcc_i/bcgrant/c_awaddr[5]", "GROUND"),
           ("u_bd/jcc_i/bcgrant/c_awaddr[0]", "POWER"),
           ("u_bd/jcc_i/bcgrant/c0_araddr[0]", "GROUND")]
    assert _check(bad) == [0] * 3


def test_tok_seam_response_bits_are_allowed_and_nothing_near_them():
    # jccard_loop1 (2026-11-11): fk33_seam drives s_axi_bresp/rresp "00" (fk33_seam.vhd:763,771),
    # so tok/m_seam_{b,r}resp[1:0] are GROUND by design. Only those bits, only GROUND.
    ok = [("u_bd/jcc_i/tok/m_seam_%s[%d]" % (p, b), "GROUND") for p in ("bresp", "rresp") for b in (0, 1)]
    assert _check(ok) == [1] * 4
    bad = [("u_bd/jcc_i/tok/m_seam_bresp[2]", "GROUND"),
           ("u_bd/jcc_i/tok/m_seam_bresp[0]", "POWER"),
           ("u_bd/jcc_i/tok/m_seam_rresp", "GROUND"),
           ("u_bd/jcc_i/tok/m_hbm_rresp[0]", "GROUND"),
           ("u_bd/jcc_i/tok/m_seam_rdata[0]", "GROUND"),
           ("u_bd/jcc_i/fk33_seam_0/m_seam_bresp[0]", "GROUND")]
    assert _check(bad) == [0] * len(bad)
