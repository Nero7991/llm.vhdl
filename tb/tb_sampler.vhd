-- tb/tb_sampler.vhd
-- Testbench for rtl/sampler.vhd. Two cases:
--   1. A hand-crafted logit vector with a tie between two indices -- checks
--      first-max-on-ties (matching sample_argmax's strict '>' compare).
--   2. The golden classifier logits from mem/golden/fx_lmhead.txt (dumped by
--      ref/run_fx.c's dump_lmhead) -- checks the DUT's argmax matches the
--      golden argmax index (the oracle "next token").
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.golden_pkg.all;

entity tb_sampler is end;

architecture sim of tb_sampler is
  constant VOCAB : integer := 512;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal start  : std_logic := '0';
  signal done   : std_logic;
  signal logits : std_logic_vector(VOCAB*32-1 downto 0) := (others => '0');
  signal token  : integer;
begin
  clk <= not clk after 5 ns;

  uut: entity work.sampler
    generic map(VOCAB => VOCAB)
    port map(
      clk    => clk,
      rst    => rst,
      start  => start,
      logits => logits,
      done   => done,
      token  => token
    );

  process
    file f_lm : text;

    variable n_x  : integer;
    variable x_e  : integer;
    variable x_d  : integer_vector(0 to 63);
    variable gold_log : integer_vector(0 to VOCAB-1);
    variable L        : line;
    variable gold_argmax : integer;
  begin
    -- =====================================================================
    -- Case 1: hand-crafted tie -- first-max wins (index 10, not 300).
    -- Background -1,000,000 everywhere; two equal peaks at 10 and 300 with
    -- value 500; index 10 must win since it comes first.
    -- =====================================================================
    for v in 0 to VOCAB-1 loop
      logits((v+1)*32-1 downto v*32) <= std_logic_vector(to_signed(-1000000, 32));
    end loop;
    logits((10+1)*32-1 downto 10*32)   <= std_logic_vector(to_signed(500, 32));
    logits((300+1)*32-1 downto 300*32) <= std_logic_vector(to_signed(500, 32));

    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until done = '1';
    wait for 1 ns;

    assert token = 10
      report "case1 (tie, first-max): expected 10, got " & integer'image(token)
      severity failure;
    report "PASS:sampler case1 (tie first-max) token=" & integer'image(token) severity note;

    -- =====================================================================
    -- Case 2: golden classifier logits from fx_lmhead.txt -> expected argmax.
    -- =====================================================================
    file_open(f_lm, "../mem/golden/fx_lmhead.txt", read_mode);
    read_bfp_block(f_lm, n_x, x_e, x_d);  -- x-in BFP block: read and discard
    gold_log := read_int_lines(f_lm, VOCAB);
    readline(f_lm, L);
    read(L, gold_argmax);
    file_close(f_lm);

    for v in 0 to VOCAB-1 loop
      logits((v+1)*32-1 downto v*32) <= std_logic_vector(to_signed(gold_log(v), 32));
    end loop;

    wait until rising_edge(clk);
    rst <= '1';
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until done = '1';
    wait for 1 ns;

    assert token = gold_argmax
      report "case2 (golden lm_head logits): expected " & integer'image(gold_argmax) &
             " got " & integer'image(token) severity failure;

    report "PASS:sampler  case1=10  case2=" & integer'image(token) severity note;
    std.env.finish;
  end process;
end architecture;
