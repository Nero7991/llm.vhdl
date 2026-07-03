-- tb/tb_e2e.vhd
-- End-to-end integration testbench for rtl/seq_ctrl.vhd: runs the full
-- embed -> 5xlayer -> rmsnorm -> lm_head -> sampler pipeline for N
-- positions and asserts the emitted token stream matches
-- mem/golden/fx_tokens_greedy.txt (the C oracle's argmax-greedy generation,
-- ref/run_fx.c) token-for-token.
--
-- fx_tokens_greedy[0..NUM_PROMPT-2] is just the teacher-forced prompt tail
-- (403 407 261 378 for stories260K's 5-token prompt), so those positions
-- exercise embed/layers/KV-build/rmsnorm/lm_head/sampler end-to-end without
-- depending on the sampler's argmax being right. fx_tokens_greedy[NUM_PROMPT-1]
-- (index 4) is the FIRST truly generated token -- the first position whose
-- correctness depends on the whole forward pass being numerically right.
-- Positions beyond that are autoregressive (previous argmax feeds the next
-- embed), so any accumulated int16-BFP noise would first show up there.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_e2e is end;

architecture sim of tb_e2e is
  constant DIM        : integer := 64;
  constant HIDDEN     : integer := 172;
  constant NHEADS     : integer := 8;
  constant NKVH       : integer := 4;
  constant KVDIM      : integer := 32;
  constant HEAD_SIZE  : integer := 8;
  constant VOCAB      : integer := 512;
  constant MAXPOS     : integer := 16;
  constant NLAYERS    : integer := 5;
  constant NUM_PROMPT : integer := 5;

  -- Number of positions to run and check against fx_tokens_greedy.txt.
  constant N : integer := 16;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal emit_token : integer;
  signal emit_pos   : integer;
  signal emit_valid : std_logic;
  signal run_done   : std_logic;

  type intarr is array(natural range <>) of integer;
  signal got_tok : intarr(0 to N-1) := (others => -1);
  signal ntok    : integer := 0;

begin
  clk <= not clk after 5 ns;

  uut: entity work.seq_ctrl
    generic map(
      DIM        => DIM,
      HIDDEN     => HIDDEN,
      NHEADS     => NHEADS,
      NKVH       => NKVH,
      KVDIM      => KVDIM,
      HEAD_SIZE  => HEAD_SIZE,
      VOCAB      => VOCAB,
      MAXPOS     => MAXPOS,
      NLAYERS    => NLAYERS,
      NUM_PROMPT => NUM_PROMPT,
      NGEN       => N
    )
    port map(
      clk        => clk,
      rst        => rst,
      start      => start,
      emit_token => emit_token,
      emit_pos   => emit_pos,
      emit_valid => emit_valid,
      run_done   => run_done
    );

  -- Capture emitted tokens as they arrive.
  process(clk)
  begin
    if rising_edge(clk) then
      if emit_valid = '1' then
        got_tok(emit_pos) <= emit_token;
        ntok <= ntok + 1;
      end if;
    end if;
  end process;

  process
    file f_gold : text;
    variable L  : line;
    variable v  : integer;
    variable gold : intarr(0 to N-1);
    variable n_matched  : integer := 0;
    variable first_fail : integer := -1;
  begin
    -- ---------------------------------------------------------------
    -- Load golden token stream
    -- ---------------------------------------------------------------
    file_open(f_gold, "../mem/golden/fx_tokens_greedy.txt", read_mode);
    for i in 0 to N-1 loop
      readline(f_gold, L);
      read(L, v);
      gold(i) := v;
    end loop;
    file_close(f_gold);

    -- ---------------------------------------------------------------
    -- Reset, then start the sequencer
    -- ---------------------------------------------------------------
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    -- ---------------------------------------------------------------
    -- Wait for the whole run to finish (generous timeout guard)
    -- ---------------------------------------------------------------
    wait until run_done = '1' for 200 ms;
    assert run_done = '1'
      report "tb_e2e: seq_ctrl did not assert run_done within timeout"
      severity failure;
    wait for 1 ns;

    -- ---------------------------------------------------------------
    -- Compare emitted stream to golden, token by token
    -- ---------------------------------------------------------------
    for p in 0 to N-1 loop
      assert got_tok(p) /= -1
        report "position " & integer'image(p) & ": no token emitted"
        severity failure;
      if got_tok(p) = gold(p) then
        n_matched := n_matched + 1;
      else
        if first_fail = -1 then first_fail := p; end if;
        report "MISMATCH pos=" & integer'image(p) &
               " got="      & integer'image(got_tok(p)) &
               " expected=" & integer'image(gold(p))
          severity error;
      end if;
    end loop;

    if first_fail = -1 then
      report "PASS:e2e " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens match" severity note;
    else
      report "FAIL:e2e " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens match; first mismatch at pos=" & integer'image(first_fail)
        severity failure;
    end if;

    std.env.finish;
  end process;

end architecture;
