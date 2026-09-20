-- sim/tb_attn_score_q12.vhd
-- Bit-exactness of rtl/attn_score_q12.vhd (subsystem C steps 5b and 6)
-- against ref/attn_score_q12_vec.c.
--
-- NO TOLERANCE.  The C generator's three double oracles establish that the
-- integer recipe means the right thing: the whole chain against a
-- floating-point sum within a PER-CASE derived bound, the Q12 conversion
-- recomputed exactly with ldexp and floor, and the DIRECTION of the alignment
-- (the aligned sum must lie in (true - NBLK, true], which is what separates a
-- floor from a round).  This file's job is the narrower one of proving the RTL
-- reproduces that recipe exactly.
--
-- WHAT IS CHECKED:
--   s_q12    the score on the Q12 grid, read as a VHDL `real` because sat32's
--            negative limit -2^31 is NOT representable as a VHDL integer.
--   s_sat    saturation is reachable only on the LEFT branch, and only there
--            is removing it a non-equivalent change.  Checked as a value, so
--            a unit that saturates too eagerly fails too.
--   p_ready  asserted BEFORE the first partial is offered and never lowered
--            while partials are in flight.  This is the property that matters
--            most and it is invisible to a value check: the score tree cannot
--            be stalled, so a p_ready that falls loses a partial rather than
--            delaying it, and the resulting score is merely a bit wrong.  The
--            testbench drives partials with NO regard for p_ready and asserts
--            that it was high every time -- driving them politely would make
--            the test pass whatever the DUT does with p_ready.
--   done     held across ACK_LAG cycles, not pulsed (RULE 1).
--   ovr      the overrun flag.  With S_READY_LAG large enough that a second
--            score would complete before the first is taken, ovr must fire;
--            with the consumer prompt it must not.  A flag that is always
--            clear and a flag that is always set both pass a one-sided check.
--
-- The vector file leads with the cases that are easy to get wrong: equal
-- exponents, an all-zero score, a wide exponent spread, a deep right shift, a
-- LEFT shift, left-branch saturation, negatives one below a power of two, and
-- a small score with a large left shift (the only shape where the shift clamp
-- is observable -- found by mutation, not by inspection).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_attn_score_q12 is
  generic( NBLK  : positive := 8;
           NCASE : positive := 64;
           KQ    : natural  := 4;
           -- Cycles to hold s_ready low after s_valid rises.  0 = prompt.
           -- Large enough and the DUT must report an overrun rather than
           -- silently dropping a score.
           S_READY_LAG : natural := 2;
           ACK_LAG     : natural := 4;
           -- rtl/attn_score_q12.vhd's HDR_TREE.  0 is the legacy serial
           -- header scan.  EVERY VECTOR MUST PRODUCE THE SAME s_q12 AND
           -- THE SAME s_sat AT EVERY VALUE OF IT: the tree computes the
           -- same e_min and the parallel subtracts the same per-block
           -- shifts, so only the number of cycles before p_ready rises
           -- may move.  The p_ready property this bench already checks is
           -- what makes that testable rather than assumed -- partials are
           -- driven with no regard for p_ready, so a tree that raised it
           -- too EARLY would take partials against stale shifts.
           HDR_TREE    : natural := 0;
           HEARTBEAT_US : natural := 0;
           VECS  : string := "attn_score_q12_vec.txt" );
end entity;

architecture sim of tb_attn_score_q12 is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal hdr_valid : std_logic := '0';
  signal e_k       : std_logic_vector(NBLK*8-1 downto 0) := (others => '0');
  signal q_exp     : signed(7 downto 0) := (others => '0');
  signal hdr_taken, busy : std_logic;

  signal p_valid : std_logic := '0';
  signal p_data  : signed(31 downto 0) := (others => '0');
  signal p_ready : std_logic;

  signal s_valid : std_logic;
  signal s_q12   : signed(31 downto 0);
  signal s_exp   : signed(7 downto 0);
  signal s_sat   : std_logic;
  signal s_ready : std_logic := '1';
  signal done    : std_logic;
  signal done_ack : std_logic := '1';
  signal ovr, err : std_logic;

  type int_arr is array (natural range <>) of integer;
  signal nerr : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_score_q12
    generic map ( NBLK => NBLK, P_W => 32, EXP_W => 8,
                  KQ_SHIFT => KQ, QOUT => 12, LSH_CLAMP => 32, RSH_CLAMP => 32,
                  HDR_TREE => HDR_TREE,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               hdr_valid => hdr_valid, e_k => e_k, q_exp => q_exp,
               hdr_taken => hdr_taken, busy => busy,
               p_valid => p_valid, p_data => p_data, p_ready => p_ready,
               s_valid => s_valid, s_q12 => s_q12, s_exp => s_exp,
               s_sat => s_sat, s_ready => s_ready,
               done => done, done_ack => done_ack, ovr => ovr, err => err );

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " p_ready=" & std_logic'image(p_ready)
           & " s_valid=" & std_logic'image(s_valid)
           & " done=" & std_logic'image(done) severity note;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nn, nk : integer;
    variable v_p  : int_arr(0 to NBLK-1);
    variable v_e  : int_arr(0 to NBLK-1);
    variable v_qe, v_emin, v_sexp, v_sh, v_sat : integer;
    variable v_q12 : real;
    variable ready_fell : boolean := false;
    variable saw_ovr    : boolean := false;
    variable got_r : real;

    -- s_q12 spans the full s32 range including -2^31, which is one past what
    -- a VHDL integer can hold, so the golden is carried as a real and the
    -- DUT's output is converted to one for comparison.  Reading the golden as
    -- an integer would wrap on exactly the saturation cases the vectors exist
    -- to test.  Same workaround, same reason, as tb_gdn_head_emit's s40.
    function to_real_s32(v : signed(31 downto 0)) return real is
      variable hi : integer := to_integer(signed(v(31 downto 16)));
      variable lo : integer := to_integer(unsigned(v(15 downto 0)));
    begin
      return real(hi) * 65536.0 + real(lo);
    end function;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn); read(ln, nk);
    assert nc = NCASE and nn = NBLK and nk = KQ
      report "tb_attn_score_q12: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);
      read(ln, v_qe); read(ln, v_emin); read(ln, v_sexp); read(ln, v_sh);
      read(ln, v_q12); read(ln, v_sat);
      readline(fh, ln);
      for b in 0 to NBLK-1 loop read(ln, iv); v_p(b) := iv; end loop;
      readline(fh, ln);
      for b in 0 to NBLK-1 loop read(ln, iv); v_e(b) := iv; end loop;

      for b in 0 to NBLK-1 loop
        e_k((b+1)*8-1 downto b*8) <= std_logic_vector(to_signed(v_e(b), 8));
      end loop;
      q_exp     <= to_signed(v_qe, 8);
      hdr_valid <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;      -- 1 ns past the edge; see tb_attn_kv_quant's note
      assert hdr_taken = '1'
        report "hdr_taken did not pulse at the accept instant" severity error;
      hdr_valid <= '0';
      -- Poison the header ports immediately.  RULE 2: a DUT that reads e_k or
      -- q_exp live instead of its latched copy gets garbage for every block,
      -- which is the gdn_emit_chain w_mant defect reproduced as a test.
      e_k   <= (others => '1');
      q_exp <= to_signed(-77, 8);

      -- Wait for p_ready, then drive the partials WITHOUT looking at it again.
      -- Re-checking it every beat would turn the test into a polite handshake
      -- and would pass whatever the DUT does; the contract is that p_ready
      -- does not fall, and the only way to test that is to violate the
      -- handshake and check afterwards.
      while p_ready /= '1' loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
      for b in 0 to NBLK-1 loop
        -- p_ready is checked in the cycle BEFORE the accepting edge, which is
        -- the value the DUT actually uses to accept.  Checking it AFTER the
        -- edge reads the post-accept value, and on the last partial that is
        -- legitimately '0' -- all NBLK have been taken -- so the naive check
        -- fires on correct behaviour.  It did, on the first run.
        if p_ready /= '1' then ready_fell := true; end if;
        p_valid <= '1';
        p_data  <= to_signed(v_p(b), 32);
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;
      p_valid <= '0';
      p_data  <= to_signed(0, 32);

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;
      if S_READY_LAG > 0 then s_ready <= '0'; else s_ready <= '1'; end if;

      while s_valid /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to S_READY_LAG loop wait until rising_edge(clk); end loop;

      got_r := to_real_s32(s_q12);
      if got_r /= v_q12 then
        report "case " & integer'image(c) & ": s_q12 got "
             & real'image(got_r) & " want " & real'image(v_q12)
             & "  (q_exp " & integer'image(v_qe) & " e_min "
             & integer'image(v_emin) & " score_exp " & integer'image(v_sexp)
             & " sh " & integer'image(v_sh) & ")" severity error;
        nerr <= nerr + 1;
      end if;
      if (s_sat = '1') /= (v_sat = 1) then
        report "case " & integer'image(c) & ": s_sat got "
             & std_logic'image(s_sat) & " want " & integer'image(v_sat)
          severity error;
        nerr <= nerr + 1;
      end if;
      if to_integer(s_exp) /= 12 then
        report "case " & integer'image(c) & ": s_exp is "
             & integer'image(to_integer(s_exp))
             & " -- the whole point of the Q12 conversion is that the grid is "
             & "CONSTANT so scores from different positions are comparable"
          severity error;
        nerr <= nerr + 1;
      end if;
      if err /= '0' then
        report "case " & integer'image(c) & ": err asserted -- the aligned sum "
             & "left s32" severity error;
        nerr <= nerr + 1;
      end if;
      s_ready <= '1';

      while done /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the score" severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;
      if ovr = '1' then saw_ovr := true; end if;
      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    if ready_fell then
      report "p_ready FELL while partials were in flight.  The score tree "
           & "cannot be stalled, so those partials are lost, not delayed."
        severity error;
      nerr <= nerr + 1;
    end if;
    -- The consumer here is always prompt enough (it takes the score before the
    -- next header is presented), so an overrun means the DUT is reporting one
    -- that did not happen.  A flag that is always set passes a one-sided
    -- check just as easily as one that is always clear.
    if saw_ovr then
      report "ovr asserted although the consumer took every score before the "
           & "next header was offered" severity error;
      nerr <= nerr + 1;
    end if;

    -- ==================================================================
    -- OVERRUN PHASE.  Everything above establishes that ovr stays CLEAR when
    -- the consumer keeps up; on its own that is a one-sided check and an ovr
    -- tied to '0' would pass it.  This phase holds s_ready low across two
    -- back-to-back headers, so the second score completes while the first is
    -- still unaccepted -- which is a LOSS, not a stall, because this unit's
    -- own producer cannot be stalled and so it cannot wait indefinitely.
    -- ovr MUST fire.
    s_ready <= '0';
    done_ack <= '1';
    for c in 0 to 1 loop
      for b in 0 to NBLK-1 loop
        e_k((b+1)*8-1 downto b*8) <= std_logic_vector(to_signed(8 + b, 8));
      end loop;
      q_exp     <= to_signed(20, 8);
      hdr_valid <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      hdr_valid <= '0';
      while p_ready /= '1' loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
      for b in 0 to NBLK-1 loop
        p_valid <= '1';
        p_data  <= to_signed(1000 + b, 32);
        wait until rising_edge(clk); wait for 1 ns;
      end loop;
      p_valid <= '0';
      while done /= '1' loop wait until rising_edge(clk); end loop;
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    if ovr /= '1' then
      report "OVERRUN PHASE: a second score completed while the first was "
           & "still unaccepted and ovr did NOT fire.  That score is lost and "
           & "nothing reports it -- the gdn_head_emit failure mode exactly."
        severity error;
      nerr <= nerr + 1;
    end if;
    s_ready <= '1';
    wait until rising_edge(clk);

    wait until rising_edge(clk);
    if nerr = 0 then
      report "tb_attn_score_q12: PASS -- " & integer'image(NCASE)
           & " cases x " & integer'image(NBLK)
           & " blocks bit-exact: s_q12, s_sat, s_exp, with p_ready never "
           & "falling under the partial stream, HDR_TREE="
           & integer'image(HDR_TREE) & " S_READY_LAG="
           & integer'image(S_READY_LAG) & " ACK_LAG=" & integer'image(ACK_LAG)
        severity note;
    else
      report "tb_attn_score_q12: FAIL -- " & integer'image(nerr)
           & " mismatches" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
