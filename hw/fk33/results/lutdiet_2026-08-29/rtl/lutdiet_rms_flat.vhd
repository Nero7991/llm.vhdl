-- rtl-variant, TRACK LUTDIET 2026-08-29.  MEASUREMENT ARTEFACT, not a shipping
-- unit.  Do not move into rtl/.
--
-- The SAME-CONTRACT CONTROL for rmsnorm_rs_mem.  rmsnorm_rs takes the whole
-- vector on three flat N*16 ports, so its area number excludes the storage its
-- parent must provide; rmsnorm_rs_mem provides that storage itself.  Comparing
-- the two bare units would therefore be comparing different functions.
--
-- This wrapper gives the flat unit EXACTLY the port list the memory-backed one
-- has -- a word-at-a-time write stream in, a word-at-a-time read stream out --
-- by doing what rtl/llama_top.vhd's D-vec norm adapter already does at
-- :2024 (xv((k-1)*MANT_W-1 downto (k-2)*MANT_W) <= el_rdata, one word per
-- cycle) and :2060 (the S_WR read pass).  So this is not a straw man: it is
-- the shipping composition's actual data path, written out.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;
entity lutdiet_rms_flat is
  generic(N : positive := 4096; LANES : positive := 4; Q : integer := 12);
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    start   : in  std_logic;
    x_we    : in  std_logic;
    x_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    x_wdata : in  std_logic_vector(15 downto 0);
    x_exp   : in  integer;
    w_we    : in  std_logic;
    w_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    w_wdata : in  std_logic_vector(15 downto 0);
    w_exp   : in  integer;
    done    : out std_logic;
    o_raddr : in  std_logic_vector(clog2(N)-1 downto 0);
    o_rdata : out std_logic_vector(15 downto 0);
    o_exp   : out integer);
end entity;
architecture rtl of lutdiet_rms_flat is
  signal xv, wv : std_logic_vector(N*16-1 downto 0) := (others => '0');
  signal ov     : std_logic_vector(N*16-1 downto 0);
  signal ord    : std_logic_vector(15 downto 0) := (others => '0');
begin
  -- the write side: a variable-index slice assignment into a flat register.
  process(clk)
    variable a : natural;
  begin
    if rising_edge(clk) then
      if x_we = '1' then
        a := to_integer(unsigned(x_waddr));
        xv((a+1)*16-1 downto a*16) <= x_wdata;
      end if;
      if w_we = '1' then
        a := to_integer(unsigned(w_waddr));
        wv((a+1)*16-1 downto a*16) <= w_wdata;
      end if;
      -- the read side: a variable-index slice read out of a flat register,
      -- registered so the latency matches the memory-backed unit's.
      a := to_integer(unsigned(o_raddr));
      ord <= ov((a+1)*16-1 downto a*16);
    end if;
  end process;
  o_rdata <= ord;

  u : entity work.rmsnorm_rs
    generic map(N => N, LANES => LANES, Q => Q)
    port map(clk => clk, rst => rst, start => start,
             x_mant => xv, x_exp => x_exp, w_mant => wv, w_exp => w_exp,
             done => done, o_mant => ov, o_exp => o_exp);
end architecture;
