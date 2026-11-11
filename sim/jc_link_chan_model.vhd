-- sim/jc_link_chan_model.vhd -- an AXIS channel standing in for Aurora in the GHDL link
-- benches (plan 2026-11-04 Task 4): fixed latency, no RX backpressure (Aurora RX has no
-- tready), a bit flip on one numbered beat, a dropped beat, and link-down (TX stalls,
-- beats in flight are lost, chan_up low). Injected beats let a bench send crafted frames.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jc_link_chan_model is
  generic(W : positive := 2; LAT : positive := 8);
  port(
    clk       : in  std_logic;
    s_tdata   : in  std_logic_vector(32*W-1 downto 0);
    s_tlast   : in  std_logic;
    s_tvalid  : in  std_logic;
    s_tready  : out std_logic;
    m_tdata   : out std_logic_vector(32*W-1 downto 0) := (others => '0');
    m_tlast   : out std_logic := '0';
    m_tvalid  : out std_logic := '0';
    chan_up   : out std_logic := '1';
    down      : in  std_logic := '0';
    flip_beat : in  integer := -1;
    flip_bit  : in  natural := 0;
    drop_beat : in  integer := -1;
    inj_valid : in  std_logic := '0';
    inj_data  : in  std_logic_vector(32*W-1 downto 0) := (others => '0');
    inj_last  : in  std_logic := '0';
    nbeats    : out natural := 0);
end entity;

architecture sim of jc_link_chan_model is
  type d_t is array (0 to LAT-1) of std_logic_vector(32*W-1 downto 0);
begin
  s_tready <= not down;
  process(clk)
    variable dd : d_t := (others => (others => '0'));
    variable dv, dl : std_logic_vector(0 to LAT-1) := (others => '0');
    variable n : natural := 0;
    variable b : std_logic_vector(32*W-1 downto 0);
    variable v, lst : std_logic;
  begin
    if rising_edge(clk) then
      m_tdata <= dd(LAT-1); m_tvalid <= dv(LAT-1) and not down; m_tlast <= dl(LAT-1);
      for k in LAT-1 downto 1 loop dd(k) := dd(k-1); dv(k) := dv(k-1); dl(k) := dl(k-1); end loop;
      v := '0'; b := (others => '0'); lst := '0';
      if s_tvalid = '1' and down = '0' then
        b := s_tdata; lst := s_tlast; v := '1';
        if n = flip_beat then b(flip_bit) := not b(flip_bit); end if;
        if n = drop_beat then v := '0'; end if;
        n := n + 1;
      elsif inj_valid = '1' then
        b := inj_data; lst := inj_last; v := '1';
      end if;
      dd(0) := b; dv(0) := v; dl(0) := lst;
      if down = '1' then dv := (others => '0'); end if;
      chan_up <= not down; nbeats <= n;
    end if;
  end process;
end architecture;
