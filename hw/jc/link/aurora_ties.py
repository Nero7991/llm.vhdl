"""hw/jc/link/aurora_ties.py -- every input of the Aurora 64B66B core that tok_loop does not
drive, and the value it is tied to (plan 2026-11-04 Task 5). Read by gen_aurora_wrap.py (the
xsim wrapper) and by hw/jc/card/gen_jc_card.py (the card's xlconstant cells), so the bench and
the card cannot tie differently.

TRAP: component.xml gives every one of these a default of 0, including gt_txdiffctrl. A core
left at its defaults transmits at the minimum swing. The three TX values below are the IBERT
defaults the lane was measured with (jc_ibert/G/.../ibert_ultrascale_gty_default_port_values.vh
:146-150); the rest are component.xml's own defaults.
"""
import re

# inputs the wrapper exposes as ports (and the card connects to real nets)
MAPPED = {
    # TX/RX_Simplex has no reset_pb: component.xml enables tx_reset_pb and rx_reset_pb only when
    # DATAFLOW_CONFIG = TX/RX_Simplex (and reset_pb only otherwise). Both are driven from the one
    # wrapper port reset_pb, so the core resets as a whole (MEASURED stub, 2026-11-10).
    "init_clk": "init_clk", "tx_reset_pb": "reset_pb", "rx_reset_pb": "reset_pb",
    "pma_init": "pma_init",
    "gt_refclk1_p": "refclk_p", "gt_refclk1_n": "refclk_n",
    "gt_txpolarity": "tx_polarity",
    "s_axi_tx_tdata": "s_tx_tdata", "s_axi_tx_tkeep": "s_tx_tkeep",
    "s_axi_tx_tlast": "s_tx_tlast", "s_axi_tx_tvalid": "s_tx_tvalid",
    "rxp": "rxp", "rxn": "rxn",
}
# outputs the wrapper exposes; every other output is left open
MAPPED_OUT = {
    "s_axi_tx_tready": "s_tx_tready",
    "m_axi_rx_tdata": "m_rx_tdata", "m_axi_rx_tkeep": "m_rx_tkeep",
    "m_axi_rx_tlast": "m_rx_tlast", "m_axi_rx_tvalid": "m_rx_tvalid",
    "txp": "txp", "txn": "txn",
    "tx_channel_up": "tx_channel_up", "rx_channel_up": "rx_channel_up",
    "user_clk_out": "user_clk", "tx_sys_reset_out": "tx_sys_reset",
    "rx_sys_reset_out": "rx_sys_reset", "gt_pll_lock": "gt_pll_lock",
}
# per-lane TX settings the lane was measured with (IBERT defaults), 5 bits per lane
TIES = {
    "gt_txdiffctrl": "11000",
    "gt_txpostcursor": "00000",
    "gt_txprecursor": "00000",
}
# single-bit (not per-lane) inputs tied to their non-zero component.xml default.
# s_axi_bready (default 1): the GT DRP AXI4-Lite slave (drp_mode AXI4_LITE; Disabled is refused on
# this part) is idle, since awvalid/wvalid/arvalid are tied 0, so no B response ever comes; 1 is
# component.xml's own value.
CONST = {
    "s_axi_bready": "1",
}
# inputs whose component.xml default is 0 and whose 0 is the intended value
ZERO_OK = {
    "gt_eyescanreset", "gt_eyescantrigger", "gt_pcsrsvdin", "gt_rxbufreset",
    "gt_rxcdrhold", "gt_rxdfelpmreset", "gt_rxlpmen", "gt_rxpcsreset",
    "gt_rxpmareset", "gt_rxprbscntreset", "gt_rxprbssel", "gt_rxrate",
    "gt_txinhibit", "gt_txpcsreset", "gt_txpmareset", "gt_txprbsforceerr",
    "gt_txprbssel", "power_down", "gt_rxcdrovrden_in",
    # the idle GT DRP AXI4-Lite slave (component.xml defaults all 0): no transaction is ever issued
    "s_axi_awaddr", "s_axi_awvalid", "s_axi_wdata", "s_axi_wstrb", "s_axi_wvalid",
    "s_axi_araddr", "s_axi_arvalid", "s_axi_rready",
}


def _base(name):
    """The DRP slave is per lane: lane 0 is s_axi_awaddr, lanes 1-3 are s_axi_awaddr_lane1..3
    (MEASURED, NLANES 4 stub 2026-11-10). Only s_axi_* names fold onto their lane-0 entry."""
    return re.sub(r"_lane\d+$", "", name) if name.startswith("s_axi_") else name


def tie_value(name, width, nlanes):
    """The tie for input `name` of `width` bits, as a bit string MSB first, or None if the
    port is not in the table (the caller refuses)."""
    name = _base(name)
    if name in TIES:
        per = TIES[name]
        if width != len(per) * nlanes:
            raise ValueError("%s is %d bits, the table expects %d x %d"
                             % (name, width, len(per), nlanes))
        return per * nlanes
    if name in CONST:
        if width != len(CONST[name]):
            raise ValueError("%s is %d bits, the table expects %d" % (name, width, len(CONST[name])))
        return CONST[name]
    if name in ZERO_OK:
        return "0" * width
    return None
