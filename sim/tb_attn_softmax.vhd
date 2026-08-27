-- sim/tb_attn_softmax.vhd
-- Bit-exactness of rtl/attn_softmax.vhd (subsystem C step 7, the online
-- softmax for one query head) against ref/attn_softmax_vec.c.
--
-- NO TOLERANCE.  The C generator's four double oracles establish that the
-- integer recipe means the right thing: the final denominator against a BATCH
-- double-precision sum inside a PER-CASE derived bound, every e_p against
-- exp() inside the chord bound of a convex function over a 1/16 grid step, the
-- DIRECTION of that chord, and the grid invariants as exact equalities.  This
-- file's job is the narrower one of proving the RTL reproduces that recipe
-- exactly.
--
-- WHAT IS CHECKED, and why each one is here rather than implied by another:
--
--   e_p        every PV weight, in order, exactly.  This is the value the lane
--              array multiplies by and it is the bulk of the check.
--   rescale_n  the number of rescale passes.  THIS IS NOT REDUNDANT with the
--              values: a non-strict rise test (`>=` instead of `>`) emits an
--              extra pass with k = 0, hence f = 4096, hence s unchanged and
--              every accumulator multiplied by one.  Every e_p and the final s
--              still match.  The count is the ONLY observable that moves, and
--              without it mutation M2 is an equivalent mutant.  The same is
--              true of M10, the first-position sentinel.
--   rs_f       every rescale factor, in order, exactly, including the f = 0
--              case that k > 256 produces.
--   s_out      the final denominator.
--   m_out      the final maximum, read as a VHDL `real`: ceil_grid of a score
--              near 2^31-1 is 2^31, which is one past what a VHDL integer can
--              hold.  Same workaround, same reason, as tb_attn_score_q12's
--              s_q12 and tb_gdn_head_emit's s40.
--   done       HELD across ACK_LAG cycles, not pulsed (RULE 1).
--   rs_valid   HELD across RS_ACK_LAG cycles, not pulsed (RULE 1), and never
--              falling without an ack.
--   sc_ready   LOW for the whole rescale.  This is the C skeleton's normative
--              discipline -- the cone is held off at its INPUT, never stalled
--              at its output -- and it is invisible to any value check.
--   ep_valid   never high while rs_valid is high.  If it were, the array would
--              be handed a weight belonging to the NEW grid while it still
--              holds accumulators on the OLD one, which is a silent scaling
--              error of exactly one position's weight.
--   err, ovf   must stay clear.  err marks z > 0, which is a design invariant
--              (m_g is a ceiling of every score seen) and not a data case.
--
-- THE SCORE PORT IS POISONED IMMEDIATELY AFTER EACH ACCEPT.  RULE 2: a DUT
-- that read sc_q12 live instead of its latched copy would use the NEXT score's
-- value for this one's z.  That is the gdn_emit_chain w_mant defect reproduced
-- as a test, and it is the only thing that catches it -- a polite testbench
-- that held the score valid until the DUT was done with it would pass either
-- way.
--
-- THE VECTOR FILE leads with the cases that are easy to get wrong: monotone
-- rising (a rescale nearly every position), monotone falling (exactly one
-- maximum and NO rescale, where a unit that rescales unconditionally still
-- passes the rising case), constant (the strict-versus-non-strict rise test),
-- a jump past 16.0 (f = 0), a wide spread (e_p = 0), the s32 rails, a single
-- position, a maximum at the LAST position, and constant ON THE GRID, which is
-- the only shape that reaches z = 0 and therefore e_p = 4096.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_attn_softmax is
  generic( NCASE  : positive := 44;
           MAXPOS : positive := 64;
           P_W    : positive := 32;
           E_W    : positive := 13;
           S_W    : positive := 26;
           -- Cycles to hold done_ack low after done rises.  0 = prompt.
           ACK_LAG    : natural := 4;
           -- Cycles to hold rs_ack low after rs_valid rises.  0 = tie it
           -- high, which reproduces a zero-latency array and is the DEGENERATE
           -- configuration.  The default is 9 and not 3 for a measured reason:
           -- the rescale sequence is 5 states long, so at any lag below that
           -- the pass is acked before it would have fallen anyway, and a DUT
           -- that PULSES rs_valid instead of holding it is an equivalent
           -- mutant.  Mutation M6 survives at lag 3 and is killed at 9.  A lag
           -- shorter than the producer's own sequence does not test the hold.
           RS_ACK_LAG : natural := 9;
           HEARTBEAT_US : natural := 0;
           VECS   : string := "attn_softmax_vec.txt" );
end entity;

architecture sim of tb_attn_softmax is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal start     : std_logic := '0';
  signal cfg_taken : std_logic;
  signal busy      : std_logic;

  signal sc_valid : std_logic := '0';
  signal sc_q12   : signed(P_W-1 downto 0) := (others => '0');
  signal sc_last  : std_logic := '0';
  signal sc_ready : std_logic;

  signal ep_valid : std_logic;
  signal ep       : unsigned(E_W-1 downto 0);
  signal ep_ready : std_logic := '1';

  signal rs_valid : std_logic;
  signal rs_f     : unsigned(E_W-1 downto 0);
  signal rs_ack   : std_logic;
  signal rs_ack_r : std_logic := '0';

  signal s_out     : unsigned(S_W-1 downto 0);
  signal m_out     : signed(P_W+1 downto 0);
  signal rescale_n : unsigned(15 downto 0);
  signal done      : std_logic;
  signal done_ack  : std_logic := '1';
  signal ovf, err  : std_logic;

  type int_arr is array (natural range <>) of integer;
  -- Written by the monitor only, so there is one driver.
  signal ep_got : int_arr(0 to MAXPOS-1) := (others => -1);
  signal ep_cnt : integer := 0;
  signal rs_got : int_arr(0 to MAXPOS-1) := (others => -1);
  signal rs_cnt : integer := 0;
  signal clr    : std_logic := '0';        -- reset the collectors per case

  signal mon_err : integer := 0;
  -- Its own driver: VHDL allows exactly one process to drive an unresolved
  -- signal, and mon_err already belongs to `mon`.
  signal ord_err : integer := 0;
  signal nerr    : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_softmax
    generic map ( P_W => P_W, Q => 12, ROM_N => 256, E_W => E_W, S_W => S_W,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => start, cfg_taken => cfg_taken, busy => busy,
               sc_valid => sc_valid, sc_q12 => sc_q12, sc_last => sc_last,
               sc_ready => sc_ready,
               ep_valid => ep_valid, ep => ep, ep_ready => ep_ready,
               rs_valid => rs_valid, rs_f => rs_f, rs_ack => rs_ack,
               s_out => s_out, m_out => m_out, rescale_n => rescale_n,
               done => done, done_ack => done_ack, ovf => ovf, err => err );

  -- RS_ACK_LAG = 0 ties the ack high, which is the DEFAULT a consumer that
  -- never stalls presents and the configuration the port's own default
  -- reproduces.  Non-zero exercises the hold.
  rs_ack <= '1' when RS_ACK_LAG = 0 else rs_ack_r;

  ackp : process(clk)
    variable lag : integer := 0;
  begin
    if rising_edge(clk) then
      if RS_ACK_LAG > 0 then
        if rs_valid = '1' then
          if lag = RS_ACK_LAG-1 then
            rs_ack_r <= '1'; lag := 0;
          else
            rs_ack_r <= '0'; lag := lag + 1;
          end if;
        else
          rs_ack_r <= '0'; lag := 0;
        end if;
      end if;
    end if;
  end process;

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " sc_ready=" & std_logic'image(sc_ready)
           & " ep_valid=" & std_logic'image(ep_valid)
           & " rs_valid=" & std_logic'image(rs_valid)
           & " done=" & std_logic'image(done)
           & " ep_cnt=" & integer'image(ep_cnt)
        severity note;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- ==================================================================
  -- ORDERING GUARD on rescale_n.  Added 2026-08-27 after subsystem B's
  -- `gdn_conv` was found publishing its segment exponent in its FINAL state,
  -- i.e. AFTER every data beat that exponent describes
  -- (docs/debugging/2026-08-27_gdn-conv-eseg-published-late.md).  Every
  -- testbench there passed, including a bit-exact double-oracle check over 128
  -- cases, because they all sample the scalar at or after `done`.  The VALUE
  -- was right and only its TIME was wrong, and no value check of any strength
  -- can see that.
  --
  -- The general rule: a scalar that qualifies a stream must be assigned in a
  -- state STRICTLY EARLIER than the state that first raises that stream's
  -- valid.
  --
  -- rescale_n is NOT a per-beat qualifier of `rs_f` -- nothing is scaled by
  -- it, and the port's declared contract is "valid from done to the next
  -- start", the same class as s_out and m_out.  So the guard below is not
  -- "constant across the stream", which would be wrong for a COUNTER that must
  -- change: it is the same ordering question asked in the form this signal can
  -- answer.  At the first rising edge on which rs_valid reads high for the
  -- n-th offer, rescale_n must ALREADY read n -- the event is counted at or
  -- before it is published, never after.  A DUT that increments the counter in
  -- any LATER rescale state (S_MUL, S_SB, S_SS, S_RS or S_ZED) reads n-1 here
  -- and is caught, while its total at `done` is still exactly right and every
  -- other check in this file still passes.  That asymmetry IS the defect
  -- class.
  --
  -- attn_softmax as shipped is CLEAN: `nrs_r <= nrs_r + 1` and
  -- `rs_v_r <= '1'` are both assigned in S_F, so they land on the SAME clock
  -- edge and the count already includes the event in the first cycle the offer
  -- is visible.
  --
  -- VERIFIED to have teeth, and the verification is the point of the guard
  -- existing: with that increment moved into the `rs_tk = '1'` branch of S_RS
  -- -- executed exactly once per rescale, so the TOTAL at done is still
  -- exactly right -- this guard fires at 265 ns on the FIRST offer and every
  -- offer after it, and the count of every OTHER `report error` in this file
  -- over the whole 44-head run is ZERO.  Value right, time wrong, and only
  -- this process sees it.
  --
  -- to_string, NOT integer'image(to_integer(...)).  On a DUT with the defect
  -- the scalar can still be metavalued at the first beat, and to_integer then
  -- raises INSIDE the report expression, so the run dies at
  -- numeric_std-body.vhdl with no message at all and the guard looks like a
  -- testbench bug.
  -- ==================================================================
  ord_chk : process
    variable rs_v_d : std_logic := '0';
    variable seen   : integer := 0;
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        seen   := 0;
        rs_v_d := '0';
      else
        -- The rising edge of rs_valid is the instant the n-th pass is first
        -- OFFERED.  Sampled pre-edge, like the monitor above.
        if rs_v_d = '0' and rs_valid = '1' then
          seen := seen + 1;
          if rescale_n /= to_unsigned(seen, rescale_n'length) then
            report "ORDERING: rescale_n reads " & to_string(rescale_n)
                 & " at the instant rescale pass " & integer'image(seen)
                 & " is first offered on rs_valid; it must already read "
                 & integer'image(seen) & ".  The count is published LATER than "
                 & "the stream it describes -- the gdn_conv e_seg shape.  Its "
                 & "total at done can still be correct, which is why no value "
                 & "check sees this" severity error;
            ord_err <= ord_err + 1;
          end if;
        end if;
        rs_v_d := rs_valid;
      end if;
    end loop;
    wait;
  end process;

  -- MONITOR.  Samples at the rising edge, which reads the PRE-edge value --
  -- the value the DUT drove for the whole cycle.  Sampling after the edge
  -- would read the post-edge value and, on the last item of a burst, would
  -- fire on correct behaviour; that trap cost a run in tb_attn_score_q12 and
  -- is recorded in 2026-08-27_attn-kv-quant-abs-resize.md.
  -- ==================================================================
  mon : process
    variable rs_v_d, rs_a_d : std_logic := '0';
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;

      if clr = '1' then
        ep_cnt <= 0; rs_cnt <= 0;
      else
        if ep_valid = '1' then
          if ep_cnt < MAXPOS then
            ep_got(ep_cnt) <= to_integer(ep);
          end if;
          ep_cnt <= ep_cnt + 1;
          -- A weight produced while the array is still being rescaled belongs
          -- to the NEW grid while the accumulators still hold the OLD one.
          if rs_valid = '1' then
            report "ep_valid rose while rs_valid was still high -- the array "
                 & "is being handed a weight on the new grid while it still "
                 & "holds accumulators on the old one" severity error;
            mon_err <= mon_err + 1;
          end if;
        end if;

        if rs_valid = '1' and rs_ack = '1' then
          if rs_cnt < MAXPOS then
            rs_got(rs_cnt) <= to_integer(rs_f);
          end if;
          rs_cnt <= rs_cnt + 1;
        end if;

        -- RULE 1 on the rescale pass: it must not fall without an ack.
        if rs_v_d = '1' and rs_a_d = '0' and rs_valid = '0' then
          report "rs_valid FELL without an ack -- the rescale pass is a pulse, "
               & "and an array busy at that instant misses it entirely"
            severity error;
          mon_err <= mon_err + 1;
        end if;

        -- The cone is held off at its INPUT, never stalled at its output.
        if rs_valid = '1' and sc_ready = '1' then
          report "sc_ready was high during a rescale -- a score accepted here "
               & "would be weighed on a maximum the array has not yet been "
               & "rescaled to" severity error;
          mon_err <= mon_err + 1;
        end if;
      end if;

      rs_v_d := rs_valid;
      rs_a_d := rs_ack;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, np_f, qv, gv, swv : integer;
    variable np, v_nrs, v_ovf, v_err : integer;
    variable v_s : integer;
    variable v_m : real;
    variable v_sc, v_ep, v_ri, v_f : int_arr(0 to MAXPOS-1);
    variable nrs_seen : integer;
    variable got_m : real;

    -- m_out spans a range one past what a VHDL integer can hold, so the golden
    -- is carried as a real and the DUT's output converted to one.
    function to_real_s(v : signed) return real is
      variable hi : integer := to_integer(signed(v(v'high downto 16)));
      variable lo : integer := to_integer(unsigned(v(15 downto 0)));
    begin
      return real(hi) * 65536.0 + real(lo);
    end function;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, np_f); read(ln, qv);
    read(ln, gv); read(ln, swv);
    assert nc = NCASE and qv = 12 and gv = 8 and swv = S_W
      report "tb_attn_softmax: vector file shape mismatch" severity failure;
    assert np_f <= MAXPOS
      report "tb_attn_softmax: MAXPOS is smaller than the vector file's "
           & "position count" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv); read(ln, np); read(ln, v_nrs); read(ln, v_s);
      read(ln, v_m); read(ln, v_ovf); read(ln, v_err);
      readline(fh, ln);
      for i in 0 to np-1 loop read(ln, iv); v_sc(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to np-1 loop read(ln, iv); v_ep(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to np-1 loop read(ln, iv); v_ri(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to np-1 loop read(ln, iv); v_f(i)  := iv; end loop;

      -- clear the collectors
      clr <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      clr <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;

      start <= '1';
      wait until rising_edge(clk);
      -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes in
      -- the SAME delta as the edge, so a pulse the DUT assigns on that edge
      -- still reads as '0' and looks exactly like a missing pulse.
      wait for 1 ns;
      assert cfg_taken = '1'
        report "case " & integer'image(c)
             & ": cfg_taken did not pulse at the head start" severity error;
      start <= '0';

      for i in 0 to np-1 loop
        sc_valid <= '1';
        sc_q12   <= to_signed(v_sc(i), P_W);
        if i = np-1 then sc_last <= '1'; else sc_last <= '0'; end if;
        -- Offer and wait for the accept.  This producer IS stallable, unlike
        -- the score tree feeding attn_score_q12, so waiting is correct here
        -- and is not the polite-handshake trap.
        loop
          wait until rising_edge(clk);
          exit when sc_ready = '1';
        end loop;
        wait for 1 ns;
        sc_valid <= '0';
        sc_last  <= '0';
        -- RULE 2: poison the port the instant it has been taken.  A DUT that
        -- reads sc_q12 live gets this instead of the score.
        sc_q12   <= to_signed(-1234567, P_W);
      end loop;

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      while done /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the head" severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;
      wait for 1 ns;

      -- ---- the values ----------------------------------------------------
      if ep_cnt /= np then
        report "case " & integer'image(c) & ": produced "
             & integer'image(ep_cnt) & " weights for " & integer'image(np)
             & " scores" severity error;
        nerr <= nerr + 1;
      end if;
      for i in 0 to np-1 loop
        if i < ep_cnt and ep_got(i) /= v_ep(i) then
          report "case " & integer'image(c) & " pos " & integer'image(i)
               & ": e_p got " & integer'image(ep_got(i))
               & " want " & integer'image(v_ep(i))
               & "  (score " & integer'image(v_sc(i)) & ")" severity error;
          nerr <= nerr + 1;
        end if;
      end loop;

      if to_integer(rescale_n) /= v_nrs then
        report "case " & integer'image(c) & ": rescale_n got "
             & integer'image(to_integer(rescale_n)) & " want "
             & integer'image(v_nrs)
             & " -- the VALUES can all match while the number of rescale "
             & "passes is wrong; that is what a non-strict rise test does"
          severity error;
        nerr <= nerr + 1;
      end if;
      if rs_cnt /= v_nrs then
        report "case " & integer'image(c) & ": " & integer'image(rs_cnt)
             & " rescale passes were offered on rs_valid, golden says "
             & integer'image(v_nrs) severity error;
        nerr <= nerr + 1;
      end if;
      nrs_seen := 0;
      for i in 0 to np-1 loop
        if v_ri(i) = 1 then
          if nrs_seen < rs_cnt and rs_got(nrs_seen) /= v_f(i) then
            report "case " & integer'image(c) & " rescale "
                 & integer'image(nrs_seen) & " (at pos " & integer'image(i)
                 & "): f got " & integer'image(rs_got(nrs_seen))
                 & " want " & integer'image(v_f(i)) severity error;
            nerr <= nerr + 1;
          end if;
          nrs_seen := nrs_seen + 1;
        end if;
      end loop;

      if to_integer(s_out) /= v_s then
        report "case " & integer'image(c) & ": s got "
             & integer'image(to_integer(s_out)) & " want "
             & integer'image(v_s) severity error;
        nerr <= nerr + 1;
      end if;
      got_m := to_real_s(m_out);
      if got_m /= v_m then
        report "case " & integer'image(c) & ": m_g got " & real'image(got_m)
             & " want " & real'image(v_m) severity error;
        nerr <= nerr + 1;
      end if;
      if (ovf = '1') /= (v_ovf = 1) then
        report "case " & integer'image(c) & ": ovf got "
             & std_logic'image(ovf) severity error;
        nerr <= nerr + 1;
      end if;
      if (err = '1') /= (v_err = 1) then
        report "case " & integer'image(c) & ": err got "
             & std_logic'image(err)
             & " -- z came out positive, so m_g was not an upper bound and the "
             & "cone was driven out of domain" severity error;
        nerr <= nerr + 1;
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    wait until rising_edge(clk);
    if nerr = 0 and mon_err = 0 and ord_err = 0 then
      report "tb_attn_softmax: PASS -- " & integer'image(NCASE)
           & " heads bit-exact: every e_p, every rescale factor, the rescale "
           & "COUNT, s and m; done and rs_valid both held, sc_ready low across "
           & "every rescale, no weight produced under an unacked pass.  "
           & "ACK_LAG=" & integer'image(ACK_LAG) & " RS_ACK_LAG="
           & integer'image(RS_ACK_LAG)
        severity note;
    else
      report "tb_attn_softmax: FAIL -- " & integer'image(nerr + mon_err + ord_err)
           & " mismatches" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
