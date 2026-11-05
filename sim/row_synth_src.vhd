-- sim/row_synth_src.vhd -- a row source that returns server/pl_backend.c:66-80's
-- pl_embed_synthetic row (the host's default embedding under jc_sim_broker), after LAT
-- cycles, one mantissa per m_ready (plan 2026-11-04 Task 2).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity row_synth_src is
  generic(N_EMBD : positive := 4096; LAT : natural := 12);
  port(
    clk, rst  : in  std_logic;
    req       : in  std_logic;
    tok       : in  unsigned(31 downto 0);
    exp_valid : out std_logic := '0';
    exp_val   : out std_logic_vector(31 downto 0) := (others => '0');
    m_valid   : out std_logic := '0';
    m_data    : out std_logic_vector(15 downto 0) := (others => '0');
    m_ready   : in  std_logic);
end entity;

architecture sim of row_synth_src is
  type row_t is array (0 to N_EMBD-1) of std_logic_vector(15 downto 0);
begin
  process(clk)
    variable row : row_t;
    variable h : unsigned(31 downto 0);
    variable wait_n : integer := -1;
    variable idx : natural := 0;
    variable active : boolean := false;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        exp_valid <= '0'; m_valid <= '0'; active := false; wait_n := -1;
      elsif req = '1' then
        h := x"811C9DC5" xor tok;
        for k in 0 to N_EMBD - 1 loop
          h := h xor to_unsigned(k, 32);
          h := resize(h * x"01000193", 32);
          row(k) := std_logic_vector(h(31 downto 16)) xor x"8000";   -- (h >> 16) - 32768
        end loop;
        wait_n := LAT; idx := 0; active := false; exp_valid <= '0'; m_valid <= '0';
      elsif wait_n > 0 then
        wait_n := wait_n - 1;
      elsif wait_n = 0 then
        wait_n := -1; active := true; exp_valid <= '1'; exp_val <= x"FFFFFFF8";
        m_valid <= '1'; m_data <= row(0);
      elsif active and m_ready = '1' then
        if idx = N_EMBD - 1 then
          active := false; m_valid <= '0'; exp_valid <= '0';
        else
          idx := idx + 1; m_data <= row(idx); m_valid <= '1';
        end if;
      end if;
    end if;
  end process;
end architecture;
