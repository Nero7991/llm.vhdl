"""pytest for gen_aurora_wrap.py: a fixture stub in the format Vivado writes."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_aurora_wrap as G  # noqa: E402

STUB = """entity jc_aurora is
  Port (
    s_axi_tx_tdata : in STD_LOGIC_VECTOR ( 0 to 63 );
    s_axi_tx_tkeep : in STD_LOGIC_VECTOR ( 0 to 7 );
    s_axi_tx_tlast : in STD_LOGIC;
    s_axi_tx_tvalid : in STD_LOGIC;
    s_axi_tx_tready : out STD_LOGIC;
    m_axi_rx_tdata : out STD_LOGIC_VECTOR ( 0 to 63 );
    m_axi_rx_tkeep : out STD_LOGIC_VECTOR ( 0 to 7 );
    m_axi_rx_tlast : out STD_LOGIC;
    m_axi_rx_tvalid : out STD_LOGIC;
    rxp : in STD_LOGIC_VECTOR ( 0 to 0 );
    rxn : in STD_LOGIC_VECTOR ( 0 to 0 );
    txp : out STD_LOGIC_VECTOR ( 0 to 0 );
    txn : out STD_LOGIC_VECTOR ( 0 to 0 );
    gt_refclk1_p : in STD_LOGIC;
    gt_refclk1_n : in STD_LOGIC;
    init_clk : in STD_LOGIC;
    tx_reset_pb : in STD_LOGIC;
    rx_reset_pb : in STD_LOGIC;
    pma_init : in STD_LOGIC;
    power_down : in STD_LOGIC;
    gt_txpolarity : in STD_LOGIC_VECTOR ( 0 to 0 );
    gt_txdiffctrl : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_txpostcursor : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_txprecursor : in STD_LOGIC_VECTOR ( 4 downto 0 );
    gt_rxlpmen : in STD_LOGIC_VECTOR ( 0 to 0 );
    s_axi_awvalid : in STD_LOGIC;
    s_axi_bready : in STD_LOGIC;
    tx_channel_up : out STD_LOGIC;
    rx_channel_up : out STD_LOGIC;
    user_clk_out : out STD_LOGIC;
    tx_sys_reset_out : out STD_LOGIC;
    rx_sys_reset_out : out STD_LOGIC;
    gt_pll_lock : out STD_LOGIC;
    reset2fc : out STD_LOGIC
  );
end jc_aurora;
"""


def test_parse_and_ties():
    ports = G.parse_stub(STUB)
    assert len(ports) == 34
    text = G.render(ports, 1, "x/stub.vhdl")
    assert 'gt_txdiffctrl => "11000"' in text          # the measured swing, not the 0 default
    assert 'gt_rxlpmen => "0"' in text
    assert "power_down => '0'" in text
    assert "s_axi_awvalid => '0'" in text and "s_axi_bready => '1'" in text   # idle DRP slave
    assert "reset2fc => open" in text
    assert "s_axi_tx_tdata => s_tx_tdata" in text
    # TX/RX_Simplex: both core resets from the one wrapper port, which is declared once
    assert "tx_reset_pb => reset_pb" in text and "rx_reset_pb => reset_pb" in text
    assert text.count("    reset_pb : in std_logic") == 1


def test_unknown_input_refuses(tmp_path):
    bad = STUB.replace("    reset2fc : out STD_LOGIC\n", "    reset2fc : out STD_LOGIC;\n    gt_mystery : in STD_LOGIC\n")
    stub = tmp_path / "s.vhdl"
    stub.write_text(bad)
    dst = tmp_path / "w.vhd"
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_aurora_wrap.py"), str(stub), "1", str(dst)],
                       capture_output=True, text=True)
    assert r.returncode != 0 and "AURORA_WRAP_FAIL" in (r.stderr + r.stdout) and "gt_mystery" in (r.stderr + r.stdout)
    assert not dst.exists()


def test_diffctrl_width_checked():
    ports = [p if p[0] != "gt_txdiffctrl" else ("gt_txdiffctrl", "in", 4, "3 downto 0") for p in G.parse_stub(STUB)]
    try:
        G.render(ports, 1, "x")
    except ValueError as e:
        assert "gt_txdiffctrl" in str(e)
    else:
        raise AssertionError("a 4-bit diffctrl was accepted")


def test_drp_lane_suffix_ties():
    """NLANES 4: the DRP slave of lanes 1-3 carries a _laneN suffix; it ties like lane 0."""
    import aurora_ties as T
    assert T.tie_value("s_axi_bready_lane3", 1, 4) == "1"
    assert T.tie_value("s_axi_awaddr_lane1", 32, 4) == "0" * 32
    assert T.tie_value("gt_mystery_lane1", 1, 4) is None
