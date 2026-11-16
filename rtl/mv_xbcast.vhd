-- rtl/mv_xbcast.vhd -- the a450 distribution tree and the room AND tree (spec 2.2).
--
-- One flit enters per cycle at most and reaches every tile three register levels later:
--   root (1 copy)  ->  mid (NT/G copies, each carrying the scales of its G tiles)
--                  ->  leaf (NT copies, each carrying its own tile's 32 scale bits)
-- Every copy is its own register (dont_touch: the copies are logically equal and
-- equivalent-register removal would otherwise merge them back into the one wide net
-- this tree exists to avoid).  A copy carries only the scale bits its subtree needs,
-- so dont_touch keeps no dead flops.
--
-- room_all is the AND of the tiles' registered rooms through a mid AND register and a
-- root AND register: the only NT-input signal in A, and never on a single-cycle path.
-- Latency: flits 3 cycles in, room 2 cycles back (plus the tile's own room register).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mv_xbcast is
  generic(
    NT : positive := 24;
    G  : positive := 6;      -- tiles per mid copy; NT mod G must be 0
    XW : positive := 512
  );
  port(
    clk, rst : in  std_logic;
    i_v      : in  std_logic;
    i_kind   : in  std_logic_vector(1 downto 0);
    i_x      : in  std_logic_vector(XW-1 downto 0);
    i_s      : in  std_logic_vector(NT*32-1 downto 0);
    i_first  : in  std_logic;
    i_last   : in  std_logic;
    o_v      : out std_logic_vector(NT-1 downto 0);
    o_kind   : out std_logic_vector(NT*2-1 downto 0);
    o_x      : out std_logic_vector(NT*XW-1 downto 0);
    o_s      : out std_logic_vector(NT*32-1 downto 0);
    o_first  : out std_logic_vector(NT-1 downto 0);
    o_last   : out std_logic_vector(NT-1 downto 0);
    rooms    : in  std_logic_vector(NT-1 downto 0);
    room_all : out std_logic
  );
end entity;

architecture rtl of mv_xbcast is
  constant NM : positive := NT / G;
  constant CHK_G : natural := 1 - (NT mod G);   -- out of range unless G divides NT
  type xa_t is array(natural range <>) of std_logic_vector(XW-1 downto 0);
  type ga_t is array(natural range <>) of std_logic_vector(G*32-1 downto 0);
  type ka_t is array(natural range <>) of std_logic_vector(1 downto 0);
  -- root
  signal r_v, r_f, r_l : std_logic := '0';
  signal r_k : std_logic_vector(1 downto 0) := "00";
  signal r_x : std_logic_vector(XW-1 downto 0) := (others => '0');
  signal r_s : std_logic_vector(NT*32-1 downto 0) := (others => '0');
  -- mid
  signal m_v, m_f, m_l : std_logic_vector(NM-1 downto 0) := (others => '0');
  signal m_k : ka_t(0 to NM-1) := (others => "00");
  signal m_x : xa_t(0 to NM-1) := (others => (others => '0'));
  signal m_s : ga_t(0 to NM-1) := (others => (others => '0'));
  -- leaf
  signal l_v, l_f, l_l : std_logic_vector(NT-1 downto 0) := (others => '0');
  signal l_k : ka_t(0 to NT-1) := (others => "00");
  signal l_x : xa_t(0 to NT-1) := (others => (others => '0'));
  signal l_s : std_logic_vector(NT*32-1 downto 0) := (others => '0');
  -- rooms
  signal mr : std_logic_vector(NM-1 downto 0) := (others => '0');
  signal ra : std_logic := '0';
  attribute dont_touch : string;
  attribute dont_touch of m_v : signal is "true";
  attribute dont_touch of m_f : signal is "true";
  attribute dont_touch of m_l : signal is "true";
  attribute dont_touch of m_k : signal is "true";
  attribute dont_touch of m_x : signal is "true";
  attribute dont_touch of l_v : signal is "true";
  attribute dont_touch of l_f : signal is "true";
  attribute dont_touch of l_l : signal is "true";
  attribute dont_touch of l_k : signal is "true";
  attribute dont_touch of l_x : signal is "true";
begin
  p : process(clk)
    variable a : std_logic;
  begin
    if rising_edge(clk) then
      r_k <= i_kind; r_x <= i_x; r_s <= i_s; r_f <= i_first; r_l <= i_last;
      for k in 0 to NM-1 loop
        m_k(k) <= r_k; m_x(k) <= r_x; m_f(k) <= r_f; m_l(k) <= r_l;
        m_s(k) <= r_s((k+1)*G*32-1 downto k*G*32);
      end loop;
      for t in 0 to NT-1 loop
        l_k(t) <= m_k(t / G); l_x(t) <= m_x(t / G);
        l_f(t) <= m_f(t / G); l_l(t) <= m_l(t / G);
        l_s(t*32+31 downto t*32) <= m_s(t / G)((t mod G)*32+31 downto (t mod G)*32);
      end loop;
      for k in 0 to NM-1 loop
        a := '1';
        for i in 0 to G-1 loop a := a and rooms(k*G + i); end loop;
        mr(k) <= a;
      end loop;
      a := '1';
      for k in 0 to NM-1 loop a := a and mr(k); end loop;
      ra <= a;
      if rst = '1' then
        r_v <= '0'; m_v <= (others => '0'); l_v <= (others => '0');
        mr <= (others => '0'); ra <= '0';
      else
        r_v <= i_v;
        m_v <= (others => r_v);
        for t in 0 to NT-1 loop l_v(t) <= m_v(t / G); end loop;
      end if;
    end if;
  end process;

  room_all <= ra;
  o_v <= l_v; o_first <= l_f; o_last <= l_l; o_s <= l_s;
  g_o : for t in 0 to NT-1 generate
    o_kind(t*2+1 downto t*2) <= l_k(t);
    o_x((t+1)*XW-1 downto t*XW) <= l_x(t);
  end generate;
end architecture;
