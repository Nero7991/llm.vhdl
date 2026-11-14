-- rtl/mv_rlink.vhd -- one stage of the a450 result chain (spec 2.3), beside tile K.
--
-- The chain runs from tile NT-1 (the head) down to tile 0 and on to the crossing.  For
-- every row-tile, stage K sends its OWN tile's result first and then passes exactly
-- NT-1-K words from upstream, which are tiles K+1..NT-1's results for that same row-tile
-- (stage K+1 obeys the same rule, so its stream is own(t), pass(t).., own(t+1), ...).
-- The words therefore leave stage 0 in the fixed order tile 0, 1, .., NT-1 per row-tile,
-- whatever the tiles' relative drift, with no tag and no reorder buffer.
--
-- Flow control is local: each stage holds upstream words in a 4-deep FIFO and tells
-- upstream to stop with a REGISTERED u_afull (count >= 2), so no ready signal chains
-- through stages.  With one cycle of decision and one of output register in flight a
-- stage can receive at most two words after asserting it: 4 is enough.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_rlink is
  generic(
    K  : natural  := 0;
    NT : positive := 24;
    W  : positive := 97
  );
  port(
    clk, rst : in  std_logic;
    o_v      : in  std_logic;                       -- own tile's result FIFO
    o_d      : in  std_logic_vector(W-1 downto 0);
    o_rdy    : out std_logic;
    u_v      : in  std_logic;                       -- from stage K+1
    u_d      : in  std_logic_vector(W-1 downto 0);
    u_afull  : out std_logic;
    d_v      : out std_logic;                       -- to stage K-1 (or the crossing)
    d_d      : out std_logic_vector(W-1 downto 0);
    d_afull  : in  std_logic
  );
end entity;

architecture rtl of mv_rlink is
  constant NPASS : natural := NT - 1 - K;
  type uf_t is array(0 to 3) of std_logic_vector(W-1 downto 0);
  signal uf : uf_t := (others => (others => '0'));
  signal uh, ut : natural range 0 to 3 := 0;
  signal un : natural range 0 to 4 := 0;
  signal own_ph : std_logic := '1';
  signal cnt : natural range 0 to NT := 0;
  signal ua_r, dv_r : std_logic := '0';
  signal dd_r : std_logic_vector(W-1 downto 0) := (others => '0');
  signal take_own, take_up : std_logic;
begin
  take_own <= '1' when own_ph = '1' and d_afull = '0' and o_v = '1' else '0';
  take_up  <= '1' when own_ph = '0' and d_afull = '0' and un > 0 else '0';
  o_rdy    <= '1' when own_ph = '1' and d_afull = '0' else '0';
  u_afull  <= ua_r;
  d_v      <= dv_r;
  d_d      <= dd_r;

  p : process(clk)
    variable n : natural range 0 to 5;
  begin
    if rising_edge(clk) then
      n := un;
      if u_v = '1' then
        uf(ut) <= u_d; ut <= (ut + 1) mod 4; n := n + 1;
      end if;
      if take_up = '1' then
        uh <= (uh + 1) mod 4; n := n - 1;
      end if;
      if take_own = '1' then dd_r <= o_d; else dd_r <= uf(uh); end if;
      dv_r <= take_own or take_up;
      if take_own = '1' and NPASS > 0 then
        own_ph <= '0'; cnt <= NPASS;
      elsif take_up = '1' then
        if cnt = 1 then own_ph <= '1'; end if;
        cnt <= cnt - 1;
      end if;
      un <= n;
      if n >= 2 then ua_r <= '1'; else ua_r <= '0'; end if;
      if rst = '1' then
        uh <= 0; ut <= 0; un <= 0; own_ph <= '1'; cnt <= 0; ua_r <= '0'; dv_r <= '0';
      end if;
      assert rst = '1' or not (u_v = '1' and un = 4)
        report "mv_rlink: upstream word into a full stage FIFO" severity failure;
    end if;
  end process;
end architecture;
