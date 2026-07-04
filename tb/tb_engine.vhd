-- tb/tb_engine.vhd
-- End-to-end testbench for rtl/engine.vhd: runs the full synthesizable
-- autoregressive transformer (embed -> 5x layer_ar with persistent KV ->
-- final rmsnorm -> lm_head -> sampler) for N positions and asserts the emitted
-- token stream matches mem/golden/fx_tokens_greedy.txt (the C fixed-point
-- oracle's greedy generation, ref/run_fx.c) token-for-token.
--
-- Positions 0..NUM_PROMPT-2 are the teacher-forced prompt tail; position
-- NUM_PROMPT-1 is the FIRST truly generated token, and everything past it is
-- autoregressive (previous argmax feeds the next embed), so any KV-persistence,
-- pos-wiring or exponent bug shows up as a token mismatch there.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_engine is end;

architecture sim of tb_engine is
  constant DIM        : integer := 64;
  constant HIDDEN     : integer := 172;
  constant NHEADS     : integer := 8;
  constant NKVH       : integer := 4;
  constant KVDIM      : integer := 32;
  constant HEAD_SIZE  : integer := 8;
  constant VOCAB      : integer := 512;
  constant MAXPOS     : integer := 24;
  constant NLAYERS    : integer := 5;
  constant NUM_PROMPT : integer := 5;

  -- Number of positions to run and check against fx_tokens_greedy.txt.
  -- (tb_e2e checks 16; we check more (24) to further exercise the
  --  autoregressive tail / KV persistence.)
  constant N : integer := 24;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';

  signal token_out   : integer;
  signal pos_out     : integer;
  signal token_valid : std_logic;
  signal run_done    : std_logic;

  type intarr is array(natural range <>) of integer;
  signal got_tok : intarr(0 to N-1) := (others => -1);

begin
  clk <= not clk after 5 ns;

  uut: entity work.engine
    generic map(
      DIM => DIM, HIDDEN => HIDDEN, NHEADS => NHEADS, NKVH => NKVH,
      KVDIM => KVDIM, HEAD_SIZE => HEAD_SIZE, VOCAB => VOCAB, MAXPOS => MAXPOS,
      NLAYERS => NLAYERS, NUM_PROMPT => NUM_PROMPT, NGEN => N
    )
    port map(
      clk => clk, rst => rst, start => start,
      token_out => token_out, pos_out => pos_out,
      token_valid => token_valid, run_done => run_done
    );

  -- Capture emitted tokens as they arrive.
  process(clk)
  begin
    if rising_edge(clk) then
      if token_valid = '1' then
        got_tok(pos_out) <= token_out;
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
    file_open(f_gold, "../mem/golden/fx_tokens_greedy.txt", read_mode);
    for i in 0 to N-1 loop
      readline(f_gold, L); read(L, v); gold(i) := v;
    end loop;
    file_close(f_gold);

    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    start <= '1';
    wait until rising_edge(clk);
    start <= '0';

    wait until run_done = '1' for 400 ms;
    assert run_done = '1'
      report "tb_engine: engine did not assert run_done within timeout"
      severity failure;
    wait for 1 ns;

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
      report "PASS:engine " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens match" severity note;
    else
      report "FAIL:engine " & integer'image(n_matched) & "/" & integer'image(N) &
             " tokens match; first mismatch at pos=" & integer'image(first_fail)
        severity failure;
    end if;

    std.env.finish;
  end process;

end architecture;
