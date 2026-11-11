-- sim/tb_jc_link.vhd -- jc_link_tx -> channel model -> jc_link_rx (plan 2026-11-04 Task 4).
-- Oracle: the received payload equals the words the bench filled, word for word, or the
-- right fault counter moves and nothing reaches the head of the queue. The CRC is checked
-- against zlib's crc32 of a fixed frame (Python: zlib.crc32 of the 10 little-endian words
-- below = 0x1FA2586E).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.jc_link_pkg.all;

entity tb_jc_link is
end entity;

architecture sim of tb_jc_link is
  constant N : positive := 64;            -- 32 payload words: 4 header + 16 payload + 1 CRC beat
  constant W : positive := 2;
  constant PW : natural := N / 2;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal run_start, fill_we, send, resend, pop : std_logic := '0';
  signal fill_idx, rd_idx : unsigned(11 downto 0) := (others => '0');
  signal fill_data, send_exp, rd_data, head_exp : std_logic_vector(31 downto 0) := (others => '0');
  signal send_pos, head_pos : unsigned(31 downto 0) := (others => '0');
  signal resend_cap : unsigned(31 downto 0) := to_unsigned(100, 32);
  signal busy, exhausted, head_valid, bad, down_f : std_logic;
  signal frames_sent, resends, frames_good, crc_fails, seqpos_bad, link_downs, overruns, consumed : unsigned(31 downto 0);
  signal t_data, r_data, inj_data : std_logic_vector(32*W-1 downto 0) := (others => '0');
  signal t_last, t_valid, t_ready, r_last, r_valid, chan_up, inj_valid, inj_last : std_logic := '0';
  signal down : std_logic := '0';
  signal flip_beat, drop_beat : integer := -1;
  signal flip_bit : natural := 0;
  signal nbeats : natural;
  type words_t is array (0 to PW-1) of std_logic_vector(31 downto 0);
begin
  clk <= not clk after 2.5 ns;

  tx : entity work.jc_link_tx
    generic map(N_EMBD => N, W => W)
    port map(clk => clk, rst => rst, run_start => run_start, fill_we => fill_we,
             fill_idx => fill_idx, fill_data => fill_data, send => send, send_pos => send_pos,
             send_exp => send_exp, resend => resend, resend_cap => resend_cap, busy => busy,
             exhausted => exhausted, frames_sent => frames_sent, resends => resends,
             m_tdata => t_data, m_tkeep => open, m_tlast => t_last, m_tvalid => t_valid,
             m_tready => t_ready);
  ch : entity work.jc_link_chan_model
    generic map(W => W, LAT => 8)
    port map(clk => clk, s_tdata => t_data, s_tlast => t_last, s_tvalid => t_valid,
             s_tready => t_ready, m_tdata => r_data, m_tlast => r_last, m_tvalid => r_valid,
             chan_up => chan_up, down => down, flip_beat => flip_beat, flip_bit => flip_bit,
             drop_beat => drop_beat, inj_valid => inj_valid, inj_data => inj_data,
             inj_last => inj_last, nbeats => nbeats);
  rx : entity work.jc_link_rx
    generic map(N_EMBD => N, W => W, DEPTH => 2)
    port map(clk => clk, rst => rst, run_start => run_start, chan_up => chan_up,
             s_tdata => r_data, s_tlast => r_last, s_tvalid => r_valid,
             head_valid => head_valid, head_pos => head_pos, head_exp => head_exp,
             rd_idx => rd_idx, rd_data => rd_data, pop => pop, bad => bad, down => down_f,
             frames_good => frames_good, crc_fails => crc_fails, seqpos_bad => seqpos_bad,
             link_downs => link_downs, overruns => overruns, consumed => consumed);

  main : process
    variable e, c : natural := 0;
    variable sent : words_t;
    variable lfsr : std_logic_vector(31 downto 0) := x"1234ABCD";
    variable crc : std_logic_vector(31 downto 0);
    variable n0, c0 : natural;
    procedure chk(ok : boolean; msg : string) is
    begin
      c := c + 1;
      if not ok then e := e + 1; report "tb_jc_link: " & msg severity error; end if;
    end procedure;
    procedure tick(n : natural) is
    begin
      for k in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
    procedure pulse(signal s : out std_logic) is
    begin
      s <= '1'; wait until rising_edge(clk); s <= '0';
    end procedure;
    procedure fill is
    begin
      for k in 0 to PW - 1 loop
        lfsr := lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
        sent(k) := lfsr;
        fill_we <= '1'; fill_idx <= to_unsigned(k, 12); fill_data <= lfsr;
        wait until rising_edge(clk);
      end loop;
      fill_we <= '0';
    end procedure;
    procedure tx_idle is
    begin
      tick(2);
      while busy = '1' loop wait until rising_edge(clk); end loop;
      tick(16);                                   -- the channel latency drains
    end procedure;
    procedure do_send(p : natural; x : integer) is
    begin
      send_pos <= to_unsigned(p, 32); send_exp <= std_logic_vector(to_signed(x, 32));
      pulse(send); tx_idle;
    end procedure;
    procedure expect_head(p : natural; x : integer; msg : string) is
      variable bad_w : natural := 0;
    begin
      chk(head_valid = '1', msg & ": a frame is at the head");
      if head_valid = '1' then
        chk(head_pos = p, msg & ": head position");
        chk(head_exp = std_logic_vector(to_signed(x, 32)), msg & ": head exponent");
        for k in 0 to PW - 1 loop
          rd_idx <= to_unsigned(k, 12); tick(2);
          if rd_data /= sent(k) then bad_w := bad_w + 1; end if;
        end loop;
        chk(bad_w = 0, msg & ": every payload word equals what was filled");
        pulse(pop); tick(1);
      end if;
    end procedure;
    procedure inject(seq, p : natural) is
      type fw_t is array (0 to 8 + PW + 1) of std_logic_vector(31 downto 0);
      variable fw : fw_t := (others => (others => '0'));
      variable cr : std_logic_vector(31 downto 0) := LK_CRC_INIT;
    begin
      fw(0) := LK_MAGIC; fw(1) := std_logic_vector(to_unsigned(seq, 32));
      fw(2) := std_logic_vector(to_unsigned(p, 32)); fw(3) := std_logic_vector(to_unsigned(PW, 32));
      fw(4) := x"FFFFFFF8";
      for k in 0 to PW - 1 loop fw(8 + k) := sent(k); end loop;
      for k in 0 to 8 + PW - 1 loop cr := lk_crc_beat(cr, fw(k), 1); end loop;
      fw(8 + PW) := lk_crc_final(cr);
      for b in 0 to (8 + PW) / W loop
        inj_data <= fw(W * b + 1) & fw(W * b);
        inj_last <= '1' when b = (8 + PW) / W else '0';
        inj_valid <= '1'; wait until rising_edge(clk);
      end loop;
      inj_valid <= '0'; inj_last <= '0'; tick(16);
    end procedure;
  begin
    -- C10 first: the CRC against zlib
    crc := LK_CRC_INIT;
    crc := lk_crc_beat(crc, x"00000000" & x"4A4C4B31", 2);
    crc := lk_crc_beat(crc, x"00000002" & x"00000000", 2);
    crc := lk_crc_beat(crc, x"00000000" & x"FFFFFFF8", 2);
    crc := lk_crc_beat(crc, x"00000000" & x"00000000", 2);
    crc := lk_crc_beat(crc, x"00040003" & x"00020001", 2);
    chk(lk_crc_final(crc) = x"1FA2586E", "frame CRC equals zlib.crc32 (0x1FA2586E)");
    tick(5); rst <= '0'; tick(2);
    pulse(run_start); tick(2);
    -- C1 clean
    fill; do_send(0, -8);
    expect_head(0, -8, "C1 clean");
    chk(frames_good = 1 and crc_fails = 0 and bad = '0', "C1 counters");
    -- C2 payload bit flip, then resend
    fill; flip_beat <= nbeats + 6; flip_bit <= 5; do_send(1, 3);
    chk(head_valid = '0', "C2 a corrupted frame never reaches the head");
    chk(crc_fails = 1 and bad = '1', "C2 CRC failure counted, LINK_BAD");
    flip_beat <= -1; pulse(resend); tx_idle;
    expect_head(1, 3, "C2 resend");
    chk(bad = '0' and resends = 1, "C2 bad cleared by the good frame");
    -- C3 header bit flip (seq word): the CRC covers the header
    fill; flip_beat <= nbeats + 0; flip_bit <= 33; do_send(2, 0);
    chk(head_valid = '0' and crc_fails = 2, "C3 header corruption is a CRC failure");
    flip_beat <= -1; pulse(resend); tx_idle;
    expect_head(2, 0, "C3 resend");
    -- C4 a dropped beat: the frame is short, tlast comes early
    fill; drop_beat <= nbeats + 10; do_send(3, 1);
    chk(head_valid = '0' and crc_fails = 3, "C4 a short frame is refused");
    drop_beat <= -1; pulse(resend); tx_idle;
    expect_head(3, 1, "C4 resend");
    -- C5 link down mid-frame
    fill; n0 := to_integer(link_downs);
    send_pos <= to_unsigned(4, 32); send_exp <= x"00000002"; pulse(send);
    tick(8); down <= '1'; tick(50); down <= '0'; tx_idle;
    chk(link_downs = n0 + 1 and down_f = '1', "C5 link-down counted, LINK_DOWN");
    chk(head_valid = '0', "C5 the cut frame never reaches the head");
    pulse(resend); tx_idle;
    expect_head(4, 2, "C5 resend");
    chk(down_f = '0', "C5 LINK_DOWN cleared by the good frame");
    chk(crc_fails = 3, "C5 the resumed tail of the cut frame is discarded, not counted");
    -- C6 stale frame: right seq, old position
    inject(5, 3);
    chk(head_valid = '0' and seqpos_bad = 1 and bad = '1', "C6 a stale position is refused");
    -- C7 wrong seq, right position
    inject(99, 5);
    chk(head_valid = '0' and seqpos_bad = 2, "C7 a wrong sequence number is refused");
    fill; do_send(5, 7);
    expect_head(5, 7, "C7 the next real frame is taken");
    -- C8 the resend cap
    pulse(run_start); tick(2); resend_cap <= to_unsigned(2, 32);
    fill; do_send(0, 0); expect_head(0, 0, "C8 first frame");
    pulse(resend); tx_idle; pulse(resend); tx_idle;
    chk(resends = 2 and exhausted = '0', "C8 two resends under a cap of 2");
    n0 := to_integer(frames_sent);
    pulse(resend); tx_idle;
    chk(exhausted = '1' and resends = 2 and frames_sent = n0, "C8 the third resend is refused: exhausted");
    -- C9 overrun: three frames, two slots
    pulse(run_start); tick(2); resend_cap <= to_unsigned(100, 32);
    fill; do_send(0, 0); fill; do_send(1, 0); fill; do_send(2, 0);
    chk(overruns = 1 and bad = '1', "C9 the third frame overruns a full queue");
    chk(head_valid = '1' and head_pos = 0, "C9 the queue holds frames 0 and 1");
    pulse(pop); tick(2);
    chk(head_valid = '1' and head_pos = 1 and consumed = 2 - 1, "C9 pop advances the head");
    -- C11 a RESEND that arrives while busy is latched and served at T_IDLE, not dropped
    -- (finding 4). The ORIGINAL frame is the one that's corrupted (as in C2), so the
    -- resend -- latched mid-transmission, before die B has even seen the CRC failure --
    -- is the one that actually lands: die B sees exactly one commit (ruling 2026-11-05).
    pulse(run_start); tick(2); resend_cap <= to_unsigned(100, 32);
    fill; n0 := to_integer(frames_sent); c0 := to_integer(crc_fails);
    flip_beat <= nbeats + 6; flip_bit <= 5;
    send_pos <= to_unsigned(0, 32); send_exp <= x"00000005"; pulse(send);
    tick(3); pulse(resend);     -- busy = '1' here: the old RTL drops this pulse on the floor
    tx_idle; tx_idle;           -- flip_beat is a one-shot absolute beat count: it only ever
                                 -- matches during the original's transmission, never the resend's
    flip_beat <= -1;
    chk(to_integer(frames_sent) = n0 + 2 and to_integer(resends) = 1
        and to_integer(crc_fails) = c0 + 1,
        "C11 the busy RESEND was latched and served: one extra frame, one resend, one CRC failure");
    expect_head(0, 5, "C11 the latched resend committed after the original's CRC failure");
    pulse(pop); tick(1);
    chk(head_valid = '0', "C11 pop leaves the queue empty: exactly one commit");
    if e = 0 then
      report "PASS: tb_jc_link checks=" & integer'image(c) severity note;
    else
      report "FAIL: tb_jc_link errors=" & integer'image(e) severity failure;
    end if;
    std.env.finish;
  end process;
end architecture;
