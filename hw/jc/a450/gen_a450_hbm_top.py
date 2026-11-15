#!/usr/bin/env python3
"""hw/jc/a450/gen_a450_hbm_top.py -- writes hw/jc/a450/a450_hbm_top.vhd, the module-reference
top of the a450 A+HBM timing design (plan 2026-11-12-a450-per-port-tiles Task 7, spec 3.2
gate 2): rtl/mv4i_tiled.vhd at A_CLK_SPLIT = true, driven by rtl/a450_stub_seq.vhd, with
its 27 read masters as 27 AXI3 interfaces m00_axi..m26_axi that the block design wires to
HBM SAXI ports.

Task 9b adds the card's six other HBM masters on clk_core, as hw/jc/a450/a450_tg.vhd traffic
generators of the same interface shape (EXTRA below): x_ld (the loader, AXI3 read/write),
x_d (A's descriptor fetch, AXI3 read only, write channel tied idle as fk33_engine ties m27's),
x_bc0/x_bc1 (the B/C grant's pool ports, AXI3 read/write), x_ctl and x_tok (the ctl and tok
read masters, AXI4 read only, no ID).  a450_bd.tcl puts them behind the same clock converters,
register slices and smartconnect as the split-on card, on the same HBM ports.

The top is VHDL-93 with literal widths and no input defaults (hw/fk33/CLAUDE.md: a
module-reference top), so the 27 x 29 ports are generated, not typed.  The write channels
exist only so the block design infers full AXI3 interfaces; they are tied idle.

    python3 hw/jc/a450/gen_a450_hbm_top.py           write the file
    python3 hw/jc/a450/gen_a450_hbm_top.py --check   compare, print GEN_A450_TOP_CHECK OK|STALE
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import genstamp  # noqa: E402

DST = os.path.join(HERE, "a450_hbm_top.vhd")
NW, NS = 24, 3
NM = NW + NS
AW = 33          # the HBM SAXI address
DW = 256
IDW = 6
# (name, shape, writes): shape "axi3" is the m-port shape with IDs, "axi4r" the ctl/tok
# read-only AXI4 shape (8-bit ARLEN, no ID)
EXTRA = [("x_ld", "axi3", True), ("x_d", "axi3", False), ("x_bc0", "axi3", True),
         ("x_bc1", "axi3", True), ("x_ctl", "axi4r", False), ("x_tok", "axi4r", False)]


def ports():
    out = []
    for i in range(NM):
        p = "m%02d_axi" % i
        out += ["    %s_awvalid : out std_logic;" % p,
                "    %s_awready : in  std_logic;" % p,
                "    %s_awaddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1),
                "    %s_awid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_awlen   : out std_logic_vector(3 downto 0);" % p,
                "    %s_awsize  : out std_logic_vector(2 downto 0);" % p,
                "    %s_awburst : out std_logic_vector(1 downto 0);" % p,
                "    %s_wvalid  : out std_logic;" % p,
                "    %s_wready  : in  std_logic;" % p,
                "    %s_wdata   : out std_logic_vector(%d downto 0);" % (p, DW - 1),
                "    %s_wstrb   : out std_logic_vector(%d downto 0);" % (p, DW // 8 - 1),
                "    %s_wlast   : out std_logic;" % p,
                "    %s_bvalid  : in  std_logic;" % p,
                "    %s_bready  : out std_logic;" % p,
                "    %s_bid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_bresp   : in  std_logic_vector(1 downto 0);" % p,
                "    %s_arvalid : out std_logic;" % p,
                "    %s_arready : in  std_logic;" % p,
                "    %s_araddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1),
                "    %s_arid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_arlen   : out std_logic_vector(3 downto 0);" % p,
                "    %s_arsize  : out std_logic_vector(2 downto 0);" % p,
                "    %s_arburst : out std_logic_vector(1 downto 0);" % p,
                "    %s_rvalid  : in  std_logic;" % p,
                "    %s_rready  : out std_logic;" % p,
                "    %s_rdata   : in  std_logic_vector(%d downto 0);" % (p, DW - 1),
                "    %s_rlast   : in  std_logic;" % p,
                "    %s_rid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1),
                "    %s_rresp   : in  std_logic_vector(1 downto 0);" % p]
    for name, shape, _ in EXTRA:
        p = "%s_axi" % name
        if shape == "axi3":
            out += ["    %s_awvalid : out std_logic;" % p,
                    "    %s_awready : in  std_logic;" % p,
                    "    %s_awaddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1),
                    "    %s_awid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                    "    %s_awlen   : out std_logic_vector(3 downto 0);" % p,
                    "    %s_awsize  : out std_logic_vector(2 downto 0);" % p,
                    "    %s_awburst : out std_logic_vector(1 downto 0);" % p,
                    "    %s_wvalid  : out std_logic;" % p,
                    "    %s_wready  : in  std_logic;" % p,
                    "    %s_wdata   : out std_logic_vector(%d downto 0);" % (p, DW - 1),
                    "    %s_wstrb   : out std_logic_vector(%d downto 0);" % (p, DW // 8 - 1),
                    "    %s_wlast   : out std_logic;" % p,
                    "    %s_bvalid  : in  std_logic;" % p,
                    "    %s_bready  : out std_logic;" % p,
                    "    %s_bid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1),
                    "    %s_bresp   : in  std_logic_vector(1 downto 0);" % p]
        out += ["    %s_arvalid : out std_logic;" % p,
                "    %s_arready : in  std_logic;" % p,
                "    %s_araddr  : out std_logic_vector(%d downto 0);" % (p, AW - 1)]
        if shape == "axi3":
            out += ["    %s_arid    : out std_logic_vector(%d downto 0);" % (p, IDW - 1),
                    "    %s_arlen   : out std_logic_vector(3 downto 0);" % p]
        else:
            out += ["    %s_arlen   : out std_logic_vector(7 downto 0);" % p]
        out += ["    %s_arsize  : out std_logic_vector(2 downto 0);" % p,
                "    %s_arburst : out std_logic_vector(1 downto 0);" % p,
                "    %s_rvalid  : in  std_logic;" % p,
                "    %s_rready  : out std_logic;" % p,
                "    %s_rdata   : in  std_logic_vector(%d downto 0);" % (p, DW - 1),
                "    %s_rlast   : in  std_logic;" % p]
        if shape == "axi3":
            out += ["    %s_rid     : in  std_logic_vector(%d downto 0);" % (p, IDW - 1)]
        out += ["    %s_rresp   : in  std_logic_vector(1 downto 0);" % p]
    out[-1] = out[-1].rstrip(";")
    return "\n".join(out)


def extra_wiring():
    """One a450_tg per EXTRA master, on clk_core, its obs bit into tg_obs."""
    out = []
    for k, (name, shape, wr) in enumerate(EXTRA):
        p = "%s_axi" % name
        lw = 4 if shape == "axi3" else 8
        if shape == "axi3":
            aw = ("awvalid => %s_awvalid, awready => %s_awready, awaddr => %s_awaddr,\n"
                  "             awlen => %s_awlen, wvalid => %s_wvalid, wready => %s_wready,\n"
                  "             wdata => %s_wdata, wlast => %s_wlast, bvalid => %s_bvalid,\n"
                  "             bready => %s_bready, bresp => %s_bresp,"
                  % ((p,) * 11))
        else:
            aw = ("awvalid => open, awready => '0', awaddr => open, awlen => open,\n"
                  "             wvalid => open, wready => '0', wdata => open, wlast => open,\n"
                  "             bvalid => '0', bready => open, bresp => \"00\",")
        out += ["  tg_%s : entity work.a450_tg" % name,
                "    generic map(LEN_W => %d, WR => %s, SEED => %d)" % (lw, "true" if wr else "false", 17 * k + 3),
                "    port map(clk => clk_core, rstn => core_rstn,",
                "             " + aw,
                "             arvalid => %s_arvalid, arready => %s_arready, araddr => %s_araddr,"
                % (p, p, p),
                "             arlen => %s_arlen, rvalid => %s_rvalid, rready => %s_rready," % (p, p, p),
                "             rdata => %s_rdata, rlast => %s_rlast, rresp => %s_rresp," % (p, p, p),
                "             obs => tg_obs(%d));" % k,
                "  %s_arsize <= \"101\"; %s_arburst <= \"01\";" % (p, p)]
        if shape == "axi3":
            out += ["  %s_awid <= (others => '0'); %s_arid <= (others => '0');" % (p, p),
                    "  %s_awsize <= \"101\"; %s_awburst <= \"01\"; %s_wstrb <= (others => '1');"
                    % (p, p, p)]
    return "\n".join(out)


def wiring():
    out = []
    for i in range(NM):
        p = "m%02d_axi" % i
        out += ["  %s_awvalid <= '0'; %s_awaddr <= (others => '0'); %s_awid <= (others => '0');"
                % (p, p, p),
                "  %s_awlen <= (others => '0'); %s_awsize <= \"101\"; %s_awburst <= \"01\";"
                % (p, p, p),
                "  %s_wvalid <= '0'; %s_wdata <= (others => '0'); %s_wstrb <= (others => '0');"
                % (p, p, p),
                "  %s_wlast <= '0'; %s_bready <= '1'; %s_arid <= (others => '0');" % (p, p, p),
                "  %s_arvalid <= m_arvalid(%d); m_arready(%d) <= %s_arready;" % (p, i, i, p),
                "  %s_araddr <= m_araddr(%d downto %d);" % (p, i * AW + AW - 1, i * AW),
                "  %s_arlen <= m_arlen(%d downto %d);" % (p, i * 8 + 3, i * 8),
                "  %s_arsize <= m_arsize(%d downto %d); %s_arburst <= m_arburst(%d downto %d);"
                % (p, i * 3 + 2, i * 3, p, i * 2 + 1, i * 2),
                "  m_rvalid(%d) <= %s_rvalid; %s_rready <= m_rready(%d);" % (i, p, p, i),
                "  m_rdata(%d downto %d) <= %s_rdata; m_rlast(%d) <= %s_rlast;"
                % (i * DW + DW - 1, i * DW, p, i, p)]
    return "\n".join(out)


BODY = """-- hw/jc/a450/a450_hbm_top.vhd -- GENERATED by hw/jc/a450/gen_a450_hbm_top.py.
-- DO NOT HAND-EDIT; edit the generator.
--
{STAMP}--
-- The a450 A+HBM timing design's module-reference top (plan Task 7): rtl/mv4i_tiled.vhd
-- at A_CLK_SPLIT = true (tiles and the 27 masters on aclk_a, the back end on clk_core),
-- jobs from rtl/a450_stub_seq.vhd, everything it emits folded into `led`.  ARLEN is AXI3
-- (4 bits): MAXB = 16 keeps every burst at or below 16 beats, so the truncation is exact.
-- On clk_core, the card's six other HBM masters as a450_tg traffic generators (Task 9b).
library ieee;
use ieee.std_logic_1164.all;

entity a450_hbm_top is
  port(
    clk_core  : in  std_logic;
    core_rstn : in  std_logic;
    aclk_a    : in  std_logic;
    led       : out std_logic;
{PORTS}
  );
end entity;

architecture rtl of a450_hbm_top is
  -- aclk_a's name is not one the block design infers as a clock, so its clock interface
  -- and the 27 AXI masters on it are declared here (a set_property ASSOCIATED_BUSIF on an
  -- uninferred pin reads back empty: MEASURED, Task 7 pre-flight)
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk_a : signal is "xilinx.com:signal:clock:1.0 aclk_a CLK";
  attribute X_INTERFACE_PARAMETER of aclk_a : signal is "ASSOCIATED_BUSIF {BUSIF}";
  -- clk_core carries the card's other HBM masters (Task 9b): two clock pins, so neither
  -- association can be inferred
  attribute X_INTERFACE_INFO of clk_core : signal is "xilinx.com:signal:clock:1.0 clk_core CLK";
  attribute X_INTERFACE_PARAMETER of clk_core : signal is "ASSOCIATED_BUSIF {CBUSIF}";
  signal rst : std_logic;
  signal s_obs : std_logic;
  signal tg_obs : std_logic_vector({NX}-1 downto 0);
  signal start, cb_we, x_we : std_logic;
  signal n_rows, n_cols, out_shift, w_exp, x_exp, w_beats, s_beats : std_logic_vector(31 downto 0);
  signal out_mode : std_logic_vector(1 downto 0);
  signal w_base : std_logic_vector({NW}*{AW}-1 downto 0);
  signal s_base : std_logic_vector({NS}*{AW}-1 downto 0);
  signal cb_addr : std_logic_vector(3 downto 0);
  signal cb_data : std_logic_vector(7 downto 0);
  signal x_waddr, x_wdata : std_logic_vector(15 downto 0);
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast : std_logic_vector({NM}-1 downto 0);
  signal m_araddr : std_logic_vector({NM}*{AW}-1 downto 0);
  signal m_arlen : std_logic_vector({NM}*8-1 downto 0);
  signal m_arsize : std_logic_vector({NM}*3-1 downto 0);
  signal m_arburst : std_logic_vector({NM}*2-1 downto 0);
  signal m_rdata : std_logic_vector({NM}*{DW}-1 downto 0);
  signal y_we, done, err, sat : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(48*64-1 downto 0);
  signal y_mask : std_logic_vector(47 downto 0);
  signal y_exp : std_logic_vector(31 downto 0);
begin
  rst <= not core_rstn;

  a : entity work.mv4i_tiled
    generic map(BLK => 32, ROWS_IF => 48, NPORTS_W => {NW}, NPORTS_S => {NS}, AXI_DW => {DW},
                ADDR_W => {AW}, MAXCOLS => 17408, MAXROWS_BFP => 17408, FIFO_DEPTH => 512,
                MAXB => 16, MAXOUT => 16, A_CLK_SPLIT => true)
    port map(clk => clk_core, rst => rst, aclk => aclk_a, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift, w_exp => w_exp,
             x_exp => x_exp, out_mode => out_mode, w_base => w_base, w_beats => w_beats,
             s_base => s_base, s_beats => s_beats, cb_we => cb_we, cb_addr => cb_addr,
             cb_data => cb_data, x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
             m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
             m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
             m_rlast => m_rlast, y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp, done => done, err => err, sat_event => sat,
             dbg_rtile => open, dbg_words => open);

  stub : entity work.a450_stub_seq
    generic map(NPORTS_W => {NW}, NPORTS_S => {NS}, ADDR_W => {AW}, ROWS_IF => 48)
    port map(clk => clk_core, rst => rst, start => start, n_rows => n_rows, n_cols => n_cols,
             out_shift => out_shift, w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             w_base => w_base, w_beats => w_beats, s_base => s_base, s_beats => s_beats,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             x_we => x_we, x_waddr => x_waddr, x_wdata => x_wdata,
             y_we => y_we, y_data => y_data, y_exp => y_exp, done => done, err => err,
             sat_event => sat, jobs => open, obs => s_obs);

  -- the stub's observation and every traffic generator's, so none is trimmed
  p_led : process(clk_core)
    variable v : std_logic;
  begin
    if rising_edge(clk_core) then
      v := s_obs;
      for k in tg_obs'range loop v := v xor tg_obs(k); end loop;
      led <= v;
    end if;
  end process;

{XWIRING}

{WIRING}
end architecture;
"""


def render():
    stamp = genstamp.stamp(["python3", "hw/jc/a450/gen_a450_hbm_top.py"], [], comment="--")
    busif = ":".join("m%02d_axi" % i for i in range(NM))
    cbusif = ":".join("%s_axi" % n for n, _, _ in EXTRA)
    return BODY.format(STAMP=stamp, PORTS=ports(), WIRING=wiring(), XWIRING=extra_wiring(),
                       NW=NW, NS=NS, NM=NM, NX=len(EXTRA), AW=AW, DW=DW, BUSIF=busif,
                       CBUSIF=cbusif)


def main(argv):
    txt = render()
    if argv[1:] == ["--check"]:
        ok = os.path.exists(DST) and open(DST).read() == txt
        print("GEN_A450_TOP_CHECK %s" % ("OK" if ok else "STALE"))
        return 0 if ok else 1
    if argv[1:]:
        print(__doc__)
        return 2
    open(DST, "w").write(txt)
    print("wrote %s (%d masters)" % (DST, NM))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
