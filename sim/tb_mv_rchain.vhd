-- sim/tb_mv_rchain.vhd -- rtl/mv_rchain.vhd (+ mv_rlink), rtl/mv_rcross.vhd, rtl/mv_tsync.vhd.
--
-- Two systems run side by side: S (split) with the chain on aclk (450 MHz) and the
-- crossing's read side on clk (125 MHz), whose phase rolls against aclk because
-- 8 / 2.222 is not an integer; and E (equal) with both sides on aclk, which is what
-- A_CLK_SPLIT = false builds.  In each, NT producer queues stand in for the tiles: word
-- (tile k, row-tile r) becomes available after a random, per-tile, cumulative delay, so
-- the tiles drift far apart.  The reader takes words under a random ready and checks the
-- one order the chain promises -- for r = 0.., tiles 0..NT-1 -- word for word, 97 bits
-- each, plus that nothing extra arrives.  mv_rcross fails on a write into a full FIFO,
-- so no word can be dropped silently; the reader stalls 150 cycles at random so the
-- crossing fills and its almost-full is exercised (mutant R3).  Last, PULSES start pulses cross clk -> aclk
-- through mv_tsync: exactly PULSES arrive, never two in adjacent cycles.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mv_rchain is
  generic(
    R      : positive := 40;
    PULSES : positive := 50
  );
end entity;

architecture sim of tb_mv_rchain is
  constant NT : positive := 24;
  constant W  : positive := 97;
  signal aclk, clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal done_sim : boolean := false;
  type sv_t is array(0 to 1) of std_logic_vector(NT-1 downto 0);
  type sd_t is array(0 to 1) of std_logic_vector(NT*W-1 downto 0);
  type w_t is array(0 to 1) of std_logic_vector(W-1 downto 0);
  signal own_v, own_rdy : sv_t := (others => (others => '0'));
  signal own_d : sd_t := (others => (others => '0'));
  signal cv, ca, qv, qr : std_logic_vector(0 to 1) := (others => '0');
  signal cd, qd : w_t;
  signal rclk : std_logic_vector(0 to 1);
  signal sp, dp : std_logic := '0';
  signal fin : std_logic_vector(0 to 1) := (others => '0');
  signal npulse : natural := 0;

  function word(k, rt : natural) return std_logic_vector is
    variable v : std_logic_vector(W-1 downto 0) := (others => '0');
    variable h : unsigned(31 downto 0);
  begin
    h := to_unsigned((k * 7919 + rt * 104729 + 13) mod 2147483647, 32);
    v(15 downto 0) := std_logic_vector(to_unsigned(k, 16));
    v(31 downto 16) := std_logic_vector(to_unsigned(rt, 16));
    v(63 downto 32) := std_logic_vector(h);
    v(95 downto 64) := std_logic_vector(h xor x"A5A5A5A5");
    v(96) := h(3);
    return v;
  end function;
begin
  aclk <= not aclk after 1.111 ns when not done_sim else '0';
  clk  <= not clk after 4 ns when not done_sim else '0';
  rclk(0) <= clk;
  rclk(1) <= aclk;

  g : for s in 0 to 1 generate
    ch : entity work.mv_rchain
      generic map(NT => NT, W => W)
      port map(clk => aclk, rst => rst, own_v => own_v(s), own_d => own_d(s),
               own_rdy => own_rdy(s), d_v => cv(s), d_d => cd(s), d_afull => ca(s));
    cx : entity work.mv_rcross
      generic map(W => W, DEPTH => 16)
      port map(wclk => aclk, wrst => rst, w_v => cv(s), w_d => cd(s), w_afull => ca(s),
               rclk => rclk(s), rrst => rst, q_valid => qv(s), q_data => qd(s),
               q_ready => qr(s));

    prod : process
      type n_arr is array(0 to NT-1) of natural;
      variable nxt, due : n_arr := (others => 0);
      variable rng : unsigned(31 downto 0) := to_unsigned(977 + 31*s, 32);
      variable cyc : natural := 0;
      variable all_done : boolean;
    begin
      wait until rst = '0';
      for k in 0 to NT-1 loop due(k) := k * 3; end loop;
      loop
        wait until rising_edge(aclk);
        cyc := cyc + 1;
        all_done := true;
        for k in 0 to NT-1 loop
          if own_v(s)(k) = '1' and own_rdy(s)(k) = '1' then
            nxt(k) := nxt(k) + 1;
            rng := rng xor shift_left(rng, 13); rng := rng xor shift_right(rng, 17);
            rng := rng xor shift_left(rng, 5);
            -- drift: 0..63 cycles, and tile 5 is slow
            due(k) := cyc + to_integer(rng(5 downto 0)) + (k mod 6) * 2;
            if k = 5 then due(k) := due(k) + 90; end if;
          end if;
          if nxt(k) < R and cyc >= due(k) then
            own_v(s)(k) <= '1';
            own_d(s)((k+1)*W-1 downto k*W) <= word(k, nxt(k));
          else
            own_v(s)(k) <= '0';
          end if;
          if nxt(k) < R then all_done := false; end if;
        end loop;
        exit when all_done;
      end loop;
      wait;
    end process;

    cons : process
      variable rng : unsigned(31 downto 0) := to_unsigned(4441 + 7*s, 32);
      variable k, rt, checks, fails, idle, stall : natural := 0;
    begin
      wait until rst = '0';
      loop
        wait until rising_edge(rclk(s));
        if qv(s) = '1' and qr(s) = '1' then
          checks := checks + 1;
          if qd(s) /= word(k, rt) then
            fails := fails + 1;
            report "tb_mv_rchain: MISMATCH system " & integer'image(s) & " expected tile "
                 & integer'image(k) & " row-tile " & integer'image(rt) & " got tile "
                 & integer'image(to_integer(unsigned(qd(s)(15 downto 0)))) & " row-tile "
                 & integer'image(to_integer(unsigned(qd(s)(31 downto 16)))) severity error;
          end if;
          if k = NT-1 then k := 0; rt := rt + 1; else k := k + 1; end if;
        end if;
        rng := rng xor shift_left(rng, 13); rng := rng xor shift_right(rng, 17);
        rng := rng xor shift_left(rng, 5);
        -- random ready, plus a 150-cycle read stall about once per 128 cycles, so the
        -- crossing fills and its almost-full has to hold the chain back
        if stall > 0 then
          stall := stall - 1;
          qr(s) <= '0';
        elsif to_integer(rng(10 downto 4)) = 0 then
          stall := 150;
          qr(s) <= '0';
        elsif to_integer(rng(3 downto 0)) < 11 then qr(s) <= '1'; else qr(s) <= '0'; end if;
        if rt = R then
          idle := idle + 1;
          -- qv is sampled pre-edge, so the cycle of the last pop still shows it high
          assert idle < 3 or qv(s) = '0' report "tb_mv_rchain: a word after the last"
            severity failure;
          exit when idle > 200;
        end if;
      end loop;
      assert fails = 0 report "tb_mv_rchain: FAIL system " & integer'image(s) severity failure;
      report "tb_mv_rchain: system " & integer'image(s) & " " & integer'image(checks)
           & " words in order" severity note;
      fin(s) <= '1';
      wait;
    end process;
  end generate;

  ts : entity work.mv_tsync
    port map(sclk => clk, srst => rst, s_pulse => sp, dclk => aclk, drst => rst, d_pulse => dp);

  main : process
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    for i in 1 to PULSES loop
      sp <= '1';
      wait until rising_edge(clk);
      sp <= '0';
      for j in 1 to 2 + (i mod 5) loop wait until rising_edge(clk); end loop;
    end loop;
    wait until fin = "11";
    assert npulse = PULSES report "tb_mv_rchain: FAIL mv_tsync delivered "
      & integer'image(npulse) & " of " & integer'image(PULSES) & " pulses" severity failure;
    report "PASS: tb_mv_rchain checks=" & integer'image(R * NT * 2 + PULSES) severity note;
    done_sim <= true;
    wait;
  end process;

  count : process(aclk)
    variable n : natural := 0;
    variable prev : std_logic := '0';
  begin
    if rising_edge(aclk) then
      if dp = '1' then
        n := n + 1;
        assert prev = '0' report "tb_mv_rchain: mv_tsync pulsed two cycles running" severity failure;
      end if;
      prev := dp;
      npulse <= n;
    end if;
  end process;
end architecture;
