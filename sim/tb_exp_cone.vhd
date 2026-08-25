-- Confirm that the two micro_exp_cone modes differ in THROUGHPUT and agree in
-- VALUE.  The synthesis run reported near-identical resources for both, which
-- is a claim worth checking rather than believing: identical numbers would also
-- be what you would see if the generate branches had collapsed to one netlist.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_exp_cone is end entity;

architecture sim of tb_exp_cone is
  constant Q : integer := 12;
  constant N : integer := 24;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal iv_p, iv_s : std_logic := '0';
  signal z    : std_logic_vector(63 downto 0) := (others => '0');
  signal ov_p, ov_s : std_logic;
  signal e_p, e_s   : std_logic_vector(31 downto 0);
  signal done : boolean := false;
  type res_t is array(0 to N-1) of std_logic_vector(31 downto 0);
  signal rp, rs : res_t := (others => (others => '0'));
  signal n_p, n_s : integer := 0;
  signal cyc_p, cyc_s : integer := 0;
begin
  clk <= not clk after 5 ns when not done else '0';

  dut_p : entity work.micro_exp_cone
    generic map(Q => Q, PIPELINED => true)
    port map(clk => clk, rst => rst, iv => iv_p, z_q => z, ov => ov_p, e_out => e_p);
  dut_s : entity work.micro_exp_cone
    generic map(Q => Q, PIPELINED => false)
    port map(clk => clk, rst => rst, iv => iv_s, z_q => z, ov => ov_s, e_out => e_s);

  -- collect outputs
  process(clk) begin
    if rising_edge(clk) and rst = '0' then
      if ov_p = '1' and n_p < N then rp(n_p) <= e_p; n_p <= n_p + 1; end if;
      if ov_s = '1' and n_s < N then rs(n_s) <= e_s; n_s <= n_s + 1; end if;
    end if;
  end process;

  stim : process
    variable zi : integer;
    variable errs : integer := 0;
  begin
    wait for 40 ns; rst <= '0'; wait until rising_edge(clk);

    -- PIPELINED: drive one input per cycle and count cycles to N outputs.
    for i in 0 to N-1 loop
      zi := -(i * 512);                       -- spread over the [-16,0] domain
      z    <= std_logic_vector(to_signed(zi, 64));
      iv_p <= '1';
      wait until rising_edge(clk);
    end loop;
    iv_p <= '0';
    while n_p < N loop wait until rising_edge(clk); cyc_p <= cyc_p + 1; end loop;

    -- STAGED, driven IDENTICALLY: one input per cycle for N cycles.  The FSM
    -- samples iv only in S_A, so inputs arriving during S_B/S_C are dropped and
    -- the output count is the throughput ratio, directly measured.
    for i in 0 to N-1 loop
      zi := -(i * 512);
      z    <= std_logic_vector(to_signed(zi, 64));
      iv_s <= '1';
      wait until rising_edge(clk);
    end loop;
    iv_s <= '0';
    for i in 0 to 12 loop wait until rising_edge(clk); end loop;

    wait for 200 ns;
    report "pipelined outputs: " & integer'image(n_p) &
           "   staged outputs: " & integer'image(n_s);
    report "THROUGHPUT: with " & integer'image(N) &
           " back-to-back inputs, pipelined returned " & integer'image(n_p) &
           ", staged returned " & integer'image(n_s) &
           "  (staged drops inputs arriving during S_B/S_C)";
    -- The staged form sampled only every 3rd input, so its output i is the
    -- pipelined form's output 3*i.  Comparing them aligned proves the two
    -- compute the SAME function at different rates.
    for i in 0 to n_s-1 loop
      if 3*i <= N-1 and rp(3*i) /= rs(i) then
        errs := errs + 1;
        report "VALUE MISMATCH at " & integer'image(i) severity error;
      end if;
    end loop;
    if errs = 0 then
      report "VALUES AGREE on the " & integer'image(n_s) & " the staged form produced";
    end if;
    done <= true;
    wait;
  end process;
end architecture;
