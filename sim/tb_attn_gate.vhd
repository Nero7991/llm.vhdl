-- sim/tb_attn_gate.vhd
-- Bit-exactness of rtl/attn_gate.vhd (subsystem C, sites 6b/6c/6d/6e) against
-- ref/attn_gate_vec.c.
--
-- NO TOLERANCE.  The C generator's five oracles establish that the integer
-- recipe means the right thing -- site 6b against o*2^14/s in double inside a
-- bound derived from the reciprocal's own floor error, site 6c recomputed
-- exactly in double with ldexp and floor, the sigmoid against libm inside a
-- bound derived from max|sigmoid''| with the CHORD DIRECTION and the grid
-- equalities asserted separately and EXHAUSTIVELY over the interpolated
-- domain, site 6e's round inside half a count, and the whole chain inside a
-- composed bound.  This file's job is the narrower one of proving the RTL
-- reproduces that recipe exactly.
--
-- WHAT IS CHECKED:
--   t, g15, y  all three, for every element, exactly.  They must be checked
--              SEPARATELY: y alone is one number and a wrong t and a wrong
--              sigmoid look identical in it, so a single check names the
--              element and not the site.  attn_kv_quant's write-up records the
--              same lesson from the other direction -- its mantissa and
--              exponent were self-consistent with each other and only the
--              separate exponent check saw the defect.
--   cfg_taken  pulses at the accept instant (RULE 2), and the three scalar
--              ports are POISONED immediately afterwards.  They are read for
--              the whole head, so a DUT that read them live computes the tail
--              of the head against the poison -- the gdn_emit_chain w_mant
--              defect reproduced as a test.
--   ORDERING   cfg_taken must pulse STRICTLY BEFORE the first element is
--              accepted.  From subsystem B's 2026-08-27 gdn_conv defect, where
--              a segment exponent was assigned in the FINAL state and so
--              described beats that had already gone past: the value was right
--              and only its time was wrong, and every value check passed.
--   y_valid    HELD when y_ready is low, and y_out / t_out / g_out UNCHANGED
--              across the hold.  A valid that is held while the data moves
--              underneath it is a subtler loss than a pulse and no value check
--              on a prompt consumer sees either.
--   x_ready    low while the output is blocked.  A DUT that kept accepting
--              would overwrite elements in flight: right count in, short count
--              out, every value in range.
--   done       HELD across ACK_LAG (RULE 1) and raised only after the LAST
--              element has left, not when the last one was accepted.
--   zsat       matches the golden count exactly.  Site 6c's sat32 is REACHABLE
--              and legal, so it is a value to check, not a flag to hope stays
--              clear.
--   ovr, ysat  must stay clear THROUGH THE MAIN LOOP: the generator keeps
--              |o| <= 127*s, which is the contract that makes |t| < 2^21.
--
-- THE OVERRUN PROBE, at the end, is a deliberate CONTRACT VIOLATION, in the
-- style of tb_attn_recip's zero probe and tb_attn_score_q12's overrun phase.
-- The vector set cannot reach site 6b's s24 saturate -- if it did, the golden
-- would be a golden for a contract violation -- so nothing above exercises it
-- and a DUT that removed it would pass.  The probe drives |o| far past
-- 127*s once and requires ovr = '1' and the value pinned at the s24 rail.
-- A guard no vector reaches is not a guard, it is a comment.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_gate is
  generic( NCASE : positive := 35;
           N     : positive := 64;
           O_W   : positive := 36;
           R_W   : positive := 16;
           P_W   : positive := 5;
           G_W   : positive := 16;
           T_W   : positive := 24;
           Y_W   : positive := 24;
           Q     : natural  := 12;
           GQ    : natural  := 15;
           -- Cycles between offered elements.  0 = a producer that never
           -- pauses, which is the DEGENERATE input configuration.
           X_GAP  : natural := 2;
           -- Period of the consumer's ready.  0 = tie it high, the default a
           -- consumer that never stalls presents.  Non-zero exercises the
           -- hold, and it must be LONGER than one pipeline stage or a DUT that
           -- lets the pipeline run under a blocked output is indistinguishable.
           Y_GAP  : natural := 5;
           ACK_LAG : natural := 4;
           HEARTBEAT_US : natural := 0;
           VECS   : string := "attn_gate_vec.txt" );
end entity;

architecture sim of tb_attn_gate is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal cfg_valid : std_logic := '0';
  signal p_in      : unsigned(P_W-1 downto 0) := (others => '0');
  signal r_in      : unsigned(R_W-1 downto 0) := (others => '0');
  signal qg_exp    : signed(7 downto 0) := (others => '0');
  signal cfg_ready : std_logic;
  signal cfg_taken : std_logic;
  signal busy      : std_logic;

  signal x_valid : std_logic := '0';
  signal o_in    : signed(O_W-1 downto 0) := (others => '0');
  signal g_in    : signed(G_W-1 downto 0) := (others => '0');
  signal x_ready : std_logic;

  signal y_valid : std_logic;
  signal y_out   : signed(Y_W-1 downto 0);
  signal t_out   : signed(T_W-1 downto 0);
  signal g_out   : unsigned(GQ downto 0);
  signal y_ready : std_logic;

  signal done     : std_logic;
  signal done_ack : std_logic := '1';
  signal zsat, ovr, ysat : std_logic;

  type int_arr is array (natural range <>) of integer;
  -- Written by the monitor only, so there is exactly one driver.
  signal y_got : int_arr(0 to 511) := (others => 0);
  signal t_got : int_arr(0 to 511) := (others => 0);
  signal g_got : int_arr(0 to 511) := (others => 0);
  signal y_cnt : integer := 0;
  signal clr   : std_logic := '0';

  signal mon_err : integer := 0;
  signal ord_err : integer := 0;
  signal nerr    : integer := 0;

  signal tick : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_gate
    generic map ( N => N, O_W => O_W, R_W => R_W, P_W => P_W, G_W => G_W,
                  Z_W => 32, EXP_W => 8, Q => Q, GQ => GQ,
                  T_W => T_W, Y_W => Y_W, SIG_N => 512, LSH_CLAMP => 32,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               cfg_valid => cfg_valid, p_in => p_in, r_in => r_in,
               qg_exp => qg_exp, cfg_ready => cfg_ready,
               cfg_taken => cfg_taken, busy => busy,
               x_valid => x_valid, o_in => o_in, g_in => g_in,
               x_ready => x_ready,
               y_valid => y_valid, y_out => y_out, t_out => t_out,
               g_out => g_out, y_ready => y_ready,
               done => done, done_ack => done_ack,
               zsat => zsat, ovr => ovr, ysat => ysat );

  -- A FREE-RUNNING ready pattern, not one keyed off the accepted count.
  -- tb_attn_kv_quant's write-up records that a ready derived from the accepted
  -- count DEADLOCKS -- nothing is accepted while it is low, so the condition
  -- that lowered it never clears -- and the run then looks like a DUT hang.

  -- THE COMPLETION HANDSHAKE, as a property.  See sim/hsk_chk.vhd's header:
  -- one mutation, an explicit `done_r` clear inside the ack branch, is an
  -- ABORT in FIVE harnesses and was detected by a check in none of them.
  -- DEADLINE = 12000.  MEASURED with hsk_chk's NOTE_MAX => true: the worst
  -- start-to-done latency on the clean design is 1360 cycles (configuration C
  -- of sim/mutate_attn_gate.sh, Y_GAP = 20; 404 in A, 85 in B).
  -- 12000 is 8.8x that.  Do not "tighten" it: this clause is a timeout, so
  -- its only job is to be finite, and a deadline near the real latency turns
  -- a wider vector set into a red gate for no gain.
  hsk : entity work.hsk_chk
    generic map ( NAME => "attn_gate", DEADLINE => 12000 )
    port map ( clk => clk, rst => rst, start_ev => cfg_taken,
               done => done, ack => done_ack );

  tickp : process(clk)
  begin
    if rising_edge(clk) then
      tick <= tick + 1;
    end if;
  end process;
  y_ready <= '1' when Y_GAP = 0 else
             '1' when (tick mod (Y_GAP + 1)) = Y_GAP else '0';

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " x_ready=" & std_logic'image(x_ready)
           & " y_valid=" & std_logic'image(y_valid)
           & " done=" & std_logic'image(done) severity note;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- MONITOR.  Samples at the rising edge, which reads the PRE-edge value --
  -- the value the DUT drove for the whole cycle.  Sampling after the edge
  -- reads the post-edge value and, on the last item of a burst, fires on
  -- correct behaviour; that trap cost a run in tb_attn_score_q12 and is
  -- recorded in 2026-08-27_attn-kv-quant-abs-resize.md.
  -- ==================================================================
  mon : process
    variable yv_d, yr_d : std_logic := '0';
    variable y_d, t_d   : integer := 0;
    variable g_d        : integer := 0;
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;

      if clr = '1' then
        y_cnt <= 0;
        yv_d := '0'; yr_d := '0';
      else
        if y_valid = '1' and y_ready = '1' then
          if y_cnt < 512 then
            y_got(y_cnt) <= to_integer(y_out);
            t_got(y_cnt) <= to_integer(t_out);
            g_got(y_cnt) <= to_integer(g_out);
          end if;
          y_cnt <= y_cnt + 1;
        end if;

        -- RULE 1 on the element stream, in its two forms.  A valid that FALLS
        -- without an ack loses the element outright; a valid that is held
        -- while the DATA moves underneath it loses it just as completely and
        -- is much quieter, because the count still comes out right.
        if yv_d = '1' and yr_d = '0' then
          if y_valid /= '1' then
            report "y_valid FELL without a ready -- the element is a pulse, "
                 & "and a consumer busy at that instant loses it entirely"
              severity error;
            mon_err <= mon_err + 1;
          elsif to_integer(y_out) /= y_d or to_integer(t_out) /= t_d
                or to_integer(g_out) /= g_d then
            report "y_out/t_out/g_out CHANGED while y_valid was held and "
                 & "y_ready was low -- the pipeline advanced under a blocked "
                 & "output, so the element that was standing there is lost "
                 & "while the COUNT still comes out right" severity error;
            mon_err <= mon_err + 1;
          end if;
        end if;

        -- x_ready must be low while the output is blocked, or the pipeline is
        -- accepting elements it has nowhere to put.
        if y_valid = '1' and y_ready = '0' and x_ready = '1' then
          report "x_ready was high while an unaccepted element stood at the "
               & "output -- the pipeline is taking in elements it cannot place"
            severity error;
          mon_err <= mon_err + 1;
        end if;

        yv_d := y_valid;
        yr_d := y_ready;
        y_d  := to_integer(y_out);
        t_d  := to_integer(t_out);
        g_d  := to_integer(g_out);
      end if;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- ORDERING GUARD.  From docs/debugging/2026-08-27_gdn-conv-eseg-published-
  -- late.md: a scalar that qualifies a stream must be assigned in a state
  -- STRICTLY EARLIER than the state that first raises that stream's valid, and
  -- a testbench that samples the scalar at `done` cannot tell you whether that
  -- holds.  Here the scalars are p, r and qg_exp, and the stream they qualify
  -- is every element of the head, so the check is that cfg_taken has already
  -- pulsed when the first element is accepted.
  --
  -- to_string, NOT integer'image(to_integer(...)): on a DUT with the defect
  -- the scalars can still be metavalued at the first beat, and to_integer then
  -- raises INSIDE the report expression, so the run dies at
  -- numeric_std-body.vhdl with no message at all.
  -- ==================================================================
  ord_chk : process
    variable seen_cfg : boolean := false;
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        seen_cfg := false;
      else
        if cfg_taken = '1' then seen_cfg := true; end if;
        if x_valid = '1' and x_ready = '1' and not seen_cfg then
          report "ORDERING: an element was accepted before cfg_taken pulsed.  "
               & "p_in reads " & to_string(p_in) & ", r_in reads "
               & to_string(r_in) & ", qg_exp reads " & to_string(qg_exp)
               & " -- the head's scalars are published LATER than the stream "
               & "they qualify, which is the gdn_conv e_seg shape and which no "
               & "value check sampled at done can see" severity error;
          ord_err <= ord_err + 1;
        end if;
      end if;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nv, qv, gqv, twv, ywv : integer;
    variable c_id, c_s, c_p, c_r, c_qge, c_zs : integer;
    variable v_o, v_g, v_t, v_gq, v_y : int_arr(0 to 511);
    variable ok : boolean;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, nv); read(ln, qv); read(ln, gqv);
    read(ln, twv); read(ln, ywv);
    assert nc = NCASE and nv = N and qv = Q and gqv = GQ
           and twv = T_W and ywv = Y_W
      report "tb_attn_gate: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, c_id); read(ln, c_s); read(ln, c_p); read(ln, c_r);
      read(ln, c_qge); read(ln, c_zs);
      readline(fh, ln);
      for d in 0 to N-1 loop read(ln, iv); v_o(d) := iv; end loop;
      readline(fh, ln);
      for d in 0 to N-1 loop read(ln, iv); v_g(d) := iv; end loop;
      readline(fh, ln);
      for d in 0 to N-1 loop read(ln, iv); v_t(d) := iv; end loop;
      readline(fh, ln);
      for d in 0 to N-1 loop read(ln, iv); v_gq(d) := iv; end loop;
      readline(fh, ln);
      for d in 0 to N-1 loop read(ln, iv); v_y(d) := iv; end loop;

      clr <= '1';
      wait until rising_edge(clk);
      clr <= '0';
      wait until rising_edge(clk);

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      -- ---- offer the head's scalars ---------------------------------
      cfg_valid <= '1';
      p_in      <= to_unsigned(c_p, P_W);
      r_in      <= to_unsigned(c_r, R_W);
      qg_exp    <= to_signed(c_qge, 8);
      loop
        wait until rising_edge(clk);
        exit when cfg_ready = '1';
      end loop;
      -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes
      -- in the SAME delta as the edge, so a pulse the DUT assigns on that edge
      -- still reads as '0' and looks exactly like a missing pulse.  Carried
      -- over from tb_attn_kv_quant; it has now been the right call four times.
      wait for 1 ns;
      assert cfg_taken = '1'
        report "case " & integer'image(c)
             & ": cfg_taken did not pulse at the accept instant"
        severity error;
      cfg_valid <= '0';
      -- RULE 2: poison the ports the instant they have been taken.  They are
      -- read for the whole head; a DUT that reads them live computes the tail
      -- of the head against the poison.  A polite testbench that held them
      -- valid until the DUT was finished would pass either way.
      p_in   <= to_unsigned(1, P_W);
      r_in   <= to_unsigned(1, R_W);
      qg_exp <= to_signed(-99, 8);

      -- ---- stream the elements --------------------------------------
      for d in 0 to N-1 loop
        for k in 1 to X_GAP loop
          x_valid <= '0';
          -- Poison between beats too: o_in and g_in are per-beat, so a DUT
          -- that captures on the wrong cycle takes the poison rather than a
          -- neighbouring element, which is visible instead of plausible.
          o_in <= to_signed(-1, O_W);
          g_in <= to_signed(-1, G_W);
          wait until rising_edge(clk);
        end loop;
        x_valid <= '1';
        o_in    <= to_signed(v_o(d), O_W);
        g_in    <= to_signed(v_g(d), G_W);
        loop
          wait until rising_edge(clk);
          exit when x_ready = '1';
        end loop;
      end loop;
      x_valid <= '0';
      o_in <= to_signed(-1, O_W);
      g_in <= to_signed(-1, G_W);

      -- ---- wait for completion, and check the hold ------------------
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

      -- ---- the values ------------------------------------------------
      if y_cnt /= N then
        report "case " & integer'image(c) & ": " & integer'image(y_cnt)
             & " elements came out, want " & integer'image(N)
             & " -- elements were dropped, not delayed" severity error;
        nerr <= nerr + 1;
      end if;
      ok := true;
      for d in 0 to N-1 loop
        if d < y_cnt then
          if t_got(d) /= v_t(d) then
            if ok then
              report "case " & integer'image(c) & " elem " & integer'image(d)
                   & ": t got " & integer'image(t_got(d)) & " want "
                   & integer'image(v_t(d)) & "  (site 6b: o "
                   & integer'image(v_o(d)) & " r " & integer'image(c_r)
                   & " p " & integer'image(c_p) & ")" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          if g_got(d) /= v_gq(d) then
            if ok then
              report "case " & integer'image(c) & " elem " & integer'image(d)
                   & ": g15 got " & integer'image(g_got(d)) & " want "
                   & integer'image(v_gq(d)) & "  (sites 6c/6d: g_mant "
                   & integer'image(v_g(d)) & " qg_exp "
                   & integer'image(c_qge) & ")" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          if y_got(d) /= v_y(d) then
            if ok then
              report "case " & integer'image(c) & " elem " & integer'image(d)
                   & ": y got " & integer'image(y_got(d)) & " want "
                   & integer'image(v_y(d)) & "  (site 6e: golden t "
                   & integer'image(v_t(d)) & " g15 "
                   & integer'image(v_gq(d)) & ")" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
        end if;
      end loop;

      -- zsat is a VALUE, not a hope: site 6c's saturate is reachable and legal.
      if (c_zs > 0 and zsat /= '1') or (c_zs = 0 and zsat /= '0') then
        report "case " & integer'image(c) & ": zsat is "
             & std_logic'image(zsat) & " but the golden says "
             & integer'image(c_zs) & " elements saturated site 6c"
          severity error;
        nerr <= nerr + 1;
      end if;
      if ovr /= '0' or ysat /= '0' then
        report "case " & integer'image(c) & ": ovr=" & std_logic'image(ovr)
             & " ysat=" & std_logic'image(ysat) & " -- both are unreachable "
             & "under the |o| <= 127*s contract the generator respects"
          severity error;
        nerr <= nerr + 1;
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    -- ==================================================================
    -- OVERRUN PROBE.  See the header: the generator cannot reach site 6b's
    -- s24 saturate without emitting a golden for a contract violation, so
    -- nothing above tests it.  This drives |o| far past 127*s once.
    -- ==================================================================
    clr <= '1';
    wait until rising_edge(clk);
    clr <= '0';
    done_ack <= '1';
    cfg_valid <= '1';
    p_in   <= to_unsigned(11, P_W);      -- the smallest p attn_softmax gives
    r_in   <= to_unsigned(32768, R_W);   -- the top of the u16 window, s = 2^11
    qg_exp <= to_signed(12, 8);          -- sh = 0, so zg = g_mant exactly
    loop
      wait until rising_edge(clk);
      exit when cfg_ready = '1';
    end loop;
    wait for 1 ns;
    cfg_valid <= '0';
    for d in 0 to N-1 loop
      x_valid <= '1';
      -- 2^34 * 2^15 >> 12 = 2^37, far past the s24 rail.  A legal o is at most
      -- 127*s = 127*2^11 < 2^18 here.
      if (d mod 2) = 0 then
        o_in <= shift_left(to_signed(1, O_W), 34);
      else
        o_in <= -shift_left(to_signed(1, O_W), 34);
      end if;
      g_in <= to_signed(32767, G_W);     -- g15 saturates to 32767 as well
      loop
        wait until rising_edge(clk);
        exit when x_ready = '1';
      end loop;
    end loop;
    x_valid <= '0';
    while done /= '1' loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    if ovr /= '1' then
      report "OVERRUN PROBE: |o| was driven 2^16 times past the contract and "
           & "ovr did NOT fire.  Either site 6b's s24 saturate is gone -- so a "
           & "producer that violates the bound gets a WRAPPED value rather "
           & "than a clipped one and a flag -- or the flag is not wired"
        severity error;
      nerr <= nerr + 1;
    end if;
    if y_cnt /= N then
      report "OVERRUN PROBE: " & integer'image(y_cnt) & " elements came out, "
           & "want " & integer'image(N) & " -- the probe must still TERMINATE "
           & "and produce, not hang" severity error;
      nerr <= nerr + 1;
    end if;
    -- The saturated value is pinned, not merely flagged: 2^23 - 1 and -2^23.
    for d in 0 to 1 loop
      if d < y_cnt then
        if (d = 0 and t_got(d) /= 2**(T_W-1) - 1)
           or (d = 1 and t_got(d) /= -(2**(T_W-1))) then
          report "OVERRUN PROBE: elem " & integer'image(d) & " t got "
               & integer'image(t_got(d)) & ", want the s24 rail" severity error;
          nerr <= nerr + 1;
        end if;
      end if;
    end loop;
    done_ack <= '1';
    wait until rising_edge(clk);
    while busy = '1' loop wait until rising_edge(clk); end loop;

    wait until rising_edge(clk);
    if nerr = 0 and mon_err = 0 and ord_err = 0 then
      report "tb_attn_gate: PASS -- " & integer'image(NCASE) & " heads x "
           & integer'image(N) & " elements bit-exact on t, g15 AND y, with "
           & "cfg_taken pulsing before the first element and the scalars "
           & "poisoned immediately after, y_valid and its data held across a "
           & "blocked ready, x_ready low while blocked, done raised only after "
           & "the pipeline drained, and zsat matching the golden; the site-6b "
           & "overrun probe fires and terminates.  X_GAP="
           & integer'image(X_GAP) & " Y_GAP=" & integer'image(Y_GAP)
           & " ACK_LAG=" & integer'image(ACK_LAG) severity note;
    else
      report "tb_attn_gate: FAIL -- "
           & integer'image(nerr + mon_err + ord_err) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
