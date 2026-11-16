-- rtl/mv_rchain.vhd -- the NT stages of the result chain (rtl/mv_rlink.vhd), wired head
-- (NT-1) to tail (0).  Stage K sits beside tile K; the pblock of tile K is meant to hold
-- both (spec 1.2), so every link is a neighbour-to-neighbour wire.
--
-- RESET (a450 Task 7b): one reset per link, rst(k) for link k.  rtl/mv_afast.vhd drives it
-- from tile k's local reset register (mv_tile rst_o), so a link leaves reset on the same
-- edge as its tile and the reset net stays inside the tile's pblock.  A caller with one
-- reset ties every bit to it.
library ieee;
use ieee.std_logic_1164.all;

entity mv_rchain is
  generic(
    NT : positive := 24;
    W  : positive := 97
  );
  port(
    clk      : in  std_logic;
    rst      : in  std_logic_vector(NT-1 downto 0);   -- link k's reset
    own_v    : in  std_logic_vector(NT-1 downto 0);
    own_d    : in  std_logic_vector(NT*W-1 downto 0);
    own_rdy  : out std_logic_vector(NT-1 downto 0);
    d_v      : out std_logic;
    d_d      : out std_logic_vector(W-1 downto 0);
    d_afull  : in  std_logic
  );
end entity;

architecture rtl of mv_rchain is
  signal lv : std_logic_vector(NT downto 0);
  type ld_t is array(0 to NT) of std_logic_vector(W-1 downto 0);
  signal ld : ld_t;
  signal la : std_logic_vector(NT downto 0);
begin
  -- link k's output is lv(k); its upstream is lv(k+1); lv(NT) is the empty head input
  lv(NT) <= '0';
  ld(NT) <= (others => '0');
  la(0)  <= d_afull;
  g : for k in 0 to NT-1 generate
    lk : entity work.mv_rlink
      generic map(K => k, NT => NT, W => W)
      port map(clk => clk, rst => rst(k),
               o_v => own_v(k), o_d => own_d((k+1)*W-1 downto k*W), o_rdy => own_rdy(k),
               u_v => lv(k+1), u_d => ld(k+1), u_afull => la(k+1),
               d_v => lv(k), d_d => ld(k), d_afull => la(k));
  end generate;
  d_v <= lv(0);
  d_d <= ld(0);
end architecture;
