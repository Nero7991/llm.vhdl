-- sim/tb_sigmoid_q_pipe.vhd -- 2026-09-26.  rtl/swiglu_mem.vhd's sigmoid_q_pipe
-- against rtl/fixed_pkg.vhd's sigmoid_q, EXHAUSTIVELY over every z in
-- [-17*2^Q, 17*2^Q] (both saturation edges, z = 0 and every SIG_ROM interval),
-- plus the int32 extremes, with a bubble every 7th cycle.  The input z rides
-- the pipe's tag, so every output is checked against its own input and no
-- queue is needed.  The latency (5 edges) and `busy` are checked too.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_pkg.all;

entity tb_sigmoid_q_pipe is
  generic(Q : natural := 12; LAT : positive := 5);
end entity;

architecture sim of tb_sigmoid_q_pipe is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal i_v, o_v, busy : std_logic := '0';
  signal i_z, o_s : signed(31 downto 0) := (others => '0');
  signal i_tag, o_tag : std_logic_vector(31 downto 0) := (others => '0');
  signal running : boolean := true;
  signal n_in, n_out, n_bad : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.sigmoid_q_pipe
    generic map(Q => Q, TAG_W => 32)
    port map(clk => clk, rst => rst, i_v => i_v, i_z => i_z, i_tag => i_tag,
             o_v => o_v, o_s => o_s, o_tag => o_tag, busy => busy);

  check : process(clk)
    variable want : signed(31 downto 0);
    variable nb, no : integer := 0;      -- counted in VARIABLES (CLAUDE.md)
  begin
    if rising_edge(clk) and o_v = '1' then
      want := sigmoid_q(signed(o_tag), Q);
      no := no + 1;
      if o_s /= want then
        nb := nb + 1;
        if nb <= 10 then
          report "tb_sigmoid_q_pipe: z " & integer'image(to_integer(signed(o_tag)))
               & " got " & integer'image(to_integer(o_s))
               & " want " & integer'image(to_integer(want)) severity error;
        end if;
      end if;
      n_out <= no; n_bad <= nb;
    end if;
  end process;

  stim : process
    variable z, k, sent : integer;
    procedure push(v : integer) is
    begin
      i_v <= '1'; i_z <= to_signed(v, 32); i_tag <= std_logic_vector(to_signed(v, 32));
      wait until rising_edge(clk);
      sent := sent + 1;
    end procedure;
  begin
    sent := 0;
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);
    -- the latency, measured on one isolated sample
    i_v <= '1'; i_z <= to_signed(0, 32); i_tag <= (others => '0');
    wait until rising_edge(clk);
    i_v <= '0'; sent := 1;
    for c in 1 to LAT loop
      assert o_v = '0' report "tb_sigmoid_q_pipe: o_v early at edge " & integer'image(c) severity error;
      wait until rising_edge(clk);
    end loop;
    assert o_v = '1' report "tb_sigmoid_q_pipe: o_v not LAT edges after i_v" severity error;
    -- the sweep
    k := 0;
    z := -17 * 2**Q;
    while z <= 17 * 2**Q loop
      k := k + 1;
      if k mod 7 = 0 then
        i_v <= '0'; wait until rising_edge(clk);
      end if;
      push(z);
      z := z + 1;
    end loop;
    push(integer'low); push(integer'low + 1); push(integer'high); push(integer'high - 1);
    i_v <= '0';
    for c in 1 to LAT + 2 loop wait until rising_edge(clk); end loop;
    assert busy = '0' report "tb_sigmoid_q_pipe: busy after drain" severity error;
    running <= false;
    if n_bad = 0 and n_out = sent then
      report "tb_sigmoid_q_pipe: PASS -- " & integer'image(n_out) & " samples, bit-exact to sigmoid_q" severity note;
    else
      report "tb_sigmoid_q_pipe: FAIL -- " & integer'image(n_bad) & " wrong, "
           & integer'image(n_out) & " out of " & integer'image(sent) & " sent" severity failure;
    end if;
    wait;
  end process;
end architecture;
