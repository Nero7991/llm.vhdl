-- hw/jc/link/sim/tb_jc_aurora_link.vhd -- xsim, UNISIM + the Aurora IP (not a GHDL row: it
-- lives outside sim/). Two TX/RX-simplex cores, die A's TX lanes wired to die B's RX lanes
-- through the lane map PERM; jc_link_tx on A's user clock, jc_link_rx on B's (plan 2026-11-04
-- Task 5). Oracle: the payload B receives equals what A filled, frame by frame, with zero
-- CRC failures; then B's core alone is reset while A keeps transmitting and B must come back
-- up and receive again (the simplex RX-after-TX question, spec 1b.2 / plan "Not grounded").
-- PERM = 1 rotates the lane wiring: the mutant that must fail at NLANES 4.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity tb_jc_aurora_link is
  generic(NLANES : positive := 1; PERM : natural := 0; N_EMBD : positive := 64;
          NFRAMES : positive := 6; UP_TMO_US : positive := 2000);
end entity;

architecture sim of tb_jc_aurora_link is
  constant W  : positive := 2 * NLANES;
  constant PW : natural := N_EMBD / 2;
  signal refclk, sysclk : std_logic := '0';
  signal pma_a, pma_b, rpb_a, rpb_b : std_logic := '1';
  signal a_txp, a_txn, b_txp, b_txn, a_rxp, a_rxn, b_rxp, b_rxn : std_logic_vector(NLANES-1 downto 0);
  signal ua, ub, a_txu, a_rxu, b_txu, b_rxu, a_lk, b_lk : std_logic;
  signal a_tdata, b_rdata, b_tdata_unused : std_logic_vector(64*NLANES-1 downto 0);
  signal a_tkeep : std_logic_vector(8*NLANES-1 downto 0);
  signal a_tlast, a_tvalid, a_tready, b_rlast, b_rvalid : std_logic;
  signal run_a, run_b, fill_we, send, do_resend : std_logic := '0';
  signal fill_idx, rd_idx : unsigned(11 downto 0) := (others => '0');
  signal fill_data, rd_data, hexp : std_logic_vector(31 downto 0) := (others => '0');
  signal send_pos, hpos : unsigned(31 downto 0) := (others => '0');
  signal busy, exh, hval, rbad, rdown, pop : std_logic := '0';
  signal fs, rs, fg, cf, sp, ld, ov, cn : unsigned(31 downto 0);
  type words_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
  function lane_of(i : natural) return natural is
  begin
    if PERM = 0 then return i; else return (i + 1) mod NLANES; end if;
  end function;
begin
  refclk <= not refclk after 3.2 ns;        -- 156.25 MHz
  sysclk <= not sysclk after 4 ns;          -- 125 MHz init_clk (jc_gtg_clk INIT_DIV 10; C_INIT_CLK 125 in l1/l4)

  g_wire : for i in 0 to NLANES - 1 generate
    b_rxp(lane_of(i)) <= a_txp(i);  b_rxn(lane_of(i)) <= a_txn(i);
  end generate;
  a_rxp <= (others => '0');  a_rxn <= (others => '1');   -- the reverse pair is not fitted

  u_a : entity work.jc_aurora_wrap
    port map(init_clk => sysclk, reset_pb => rpb_a, pma_init => pma_a,
             refclk_p => refclk, refclk_n => not refclk, tx_polarity => (others => '0'),
             s_tx_tdata => a_tdata, s_tx_tkeep => a_tkeep, s_tx_tlast => a_tlast,
             s_tx_tvalid => a_tvalid, s_tx_tready => a_tready,
             m_rx_tdata => open, m_rx_tkeep => open, m_rx_tlast => open, m_rx_tvalid => open,
             txp => a_txp, txn => a_txn, rxp => a_rxp, rxn => a_rxn,
             tx_channel_up => a_txu, rx_channel_up => a_rxu, user_clk => ua,
             tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => a_lk);
  u_b : entity work.jc_aurora_wrap
    port map(init_clk => sysclk, reset_pb => rpb_b, pma_init => pma_b,
             refclk_p => refclk, refclk_n => not refclk, tx_polarity => (others => '0'),
             s_tx_tdata => (others => '0'), s_tx_tkeep => (others => '1'), s_tx_tlast => '0',
             s_tx_tvalid => '0', s_tx_tready => open,
             m_rx_tdata => b_rdata, m_rx_tkeep => open, m_rx_tlast => b_rlast, m_rx_tvalid => b_rvalid,
             txp => b_txp, txn => b_txn, rxp => b_rxp, rxn => b_rxn,
             tx_channel_up => b_txu, rx_channel_up => b_rxu, user_clk => ub,
             tx_sys_reset => open, rx_sys_reset => open, gt_pll_lock => b_lk);

  u_tx : entity work.jc_link_tx
    generic map(N_EMBD => N_EMBD, W => W)
    port map(clk => ua, rst => '0', run_start => run_a, fill_we => fill_we, fill_idx => fill_idx,
             fill_data => fill_data, send => send, send_pos => send_pos, send_exp => x"FFFFFFF8",
             resend => do_resend, resend_cap => to_unsigned(3, 32), busy => busy, exhausted => exh,
             frames_sent => fs, resends => rs, m_tdata => a_tdata, m_tkeep => a_tkeep,
             m_tlast => a_tlast, m_tvalid => a_tvalid, m_tready => a_tready);
  u_rx : entity work.jc_link_rx
    generic map(N_EMBD => N_EMBD, W => W, DEPTH => 2)
    port map(clk => ub, rst => '0', run_start => run_b, chan_up => b_rxu,
             s_tdata => b_rdata, s_tlast => b_rlast, s_tvalid => b_rvalid,
             head_valid => hval, head_pos => hpos, head_exp => hexp, rd_idx => rd_idx,
             rd_data => rd_data, pop => pop, bad => rbad, down => rdown,
             frames_good => fg, crc_fails => cf, seqpos_bad => sp, link_downs => ld,
             overruns => ov, consumed => cn);

  main : process
    variable e, c : natural := 0;
    variable sent : words_t;
    variable lfsr : std_logic_vector(31 downto 0) := x"C0FFEE11";
    variable t0 : time;
    variable bad_w : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_jc_aurora_link: " & msg severity error; end if;
    end procedure;
    procedure wait_up(signal s : std_logic; msg : string) is
    begin
      t0 := now;
      while s /= '1' and now - t0 < UP_TMO_US * 1 us loop wait for 100 ns; end loop;
      chk(s = '1', msg);
    end procedure;
    procedure one_frame(p : natural; msg : string) is
    begin
      wait until rising_edge(ua);
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(ua);
      end loop;
      fill_we <= '0'; send_pos <= to_unsigned(p, 32); send <= '1';
      wait until rising_edge(ua); send <= '0';
      t0 := now;
      while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      chk(hval = '1', msg & ": frame arrived");
      if hval = '1' then
        chk(hpos = p, msg & ": position");
        bad_w := 0;
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12);
          wait until rising_edge(ub); wait until rising_edge(ub);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": payload equal");
        pop <= '1'; wait until rising_edge(ub); pop <= '0'; wait until rising_edge(ub);
      end if;
    end procedure;
    -- finding 5: jc_link_rx resyncs on the first tlast after a chan_up fall (rtl/jc_link_rx.vhd
    -- header): the first frame sent after a reset is swallowed even though A never cut it. The
    -- held frame's RESEND is what actually lands; retry once with resend if the plain send times out.
    procedure frame_after_reset(p : natural; msg : string) is
      variable bad_w : natural := 0;
    begin
      wait until rising_edge(ua);
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(ua);
      end loop;
      fill_we <= '0'; send_pos <= to_unsigned(p, 32); send <= '1';
      wait until rising_edge(ua); send <= '0';
      t0 := now;
      while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      if hval = '0' then
        wait until rising_edge(ua); do_resend <= '1'; wait until rising_edge(ua); do_resend <= '0';
        t0 := now;
        while hval /= '1' and now - t0 < 50 us loop wait until rising_edge(ub); end loop;
      end if;
      chk(hval = '1', msg & ": frame arrived (resent once if the first send was eaten by the reset resync)");
      if hval = '1' then
        chk(hpos = p, msg & ": position");
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12);
          wait until rising_edge(ub); wait until rising_edge(ub);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": payload equal");
        pop <= '1'; wait until rising_edge(ub); pop <= '0'; wait until rising_edge(ub);
      end if;
    end procedure;
  begin
    -- PG074 reset order: pma_init and reset_pb high, pma_init low, then reset_pb low
    wait for 2 us; pma_a <= '0'; pma_b <= '0';
    wait for 2 us; rpb_a <= '0'; rpb_b <= '0';
    wait_up(a_txu, "A tx_channel_up");
    wait_up(b_rxu, "B rx_channel_up");
    wait until rising_edge(ua); run_a <= '1'; wait until rising_edge(ua); run_a <= '0';
    wait until rising_edge(ub); run_b <= '1'; wait until rising_edge(ub); run_b <= '0';
    for f in 0 to NFRAMES - 1 loop
      one_frame(f, "frame " & integer'image(f));
      exit when e > 0;
    end loop;
    chk(cf = 0 and sp = 0 and ov = 0, "no CRC, seq/pos or overrun faults");
    -- B's core alone is reset while A's TX stays up
    rpb_b <= '1'; wait for 2 us; rpb_b <= '0';
    wait_up(b_rxu, "B rx_channel_up again with A already up");
    chk(ld >= 1, "the B reset was counted as a link-down");
    frame_after_reset(NFRAMES, "frame after B reset");
    chk(a_txu = '1', "A tx_channel_up stayed up");
    if e = 0 then
      report "AURSIM_PASS tb_jc_aurora_link NLANES=" & integer'image(NLANES) &
             " PERM=" & integer'image(PERM) & " checks=" & integer'image(c) severity note;
    else
      report "AURSIM_FAIL tb_jc_aurora_link NLANES=" & integer'image(NLANES) &
             " PERM=" & integer'image(PERM) & " errors=" & integer'image(e) severity note;
    end if;
    std.env.finish;
  end process;
end architecture;
