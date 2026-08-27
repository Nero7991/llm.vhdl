-- sim/tb_attn_recip.vhd
-- Bit-exactness of rtl/attn_recip.vhd (subsystem C step 8a, the softmax
-- reciprocal) against ref/attn_recip_vec.c.
--
-- NO TOLERANCE.  The C generator's four oracles establish that the integer
-- recipe means the right thing -- the floor checked by MULTIPLICATION and never
-- by a second division, the range 2^p <= s < 2^(p+1) and 2^14 <= r <= 2^15 as
-- exact inequalities, the reciprocal one-sided against 1/s in double, and the
-- downstream product o*r >> (p+1) against o*2^14/s within a derived bound.
-- This file's job is the narrower one of proving the RTL reproduces that recipe
-- exactly.
--
-- WHAT IS CHECKED:
--   p, r      both, for every head, exactly.  They must be checked TOGETHER:
--             the pair is self-consistent for a p one too large or one too
--             small, so a check on r alone against a golden derived from the
--             same p proves nothing about the scaling.  The golden carries
--             both independently.
--   s_taken   pulses at the accept instant (RULE 2), and the denominator port
--             is POISONED immediately afterwards.  The divide reads its input
--             for NW + 7 cycles, so a DUT that read s_in live instead of its
--             latched copy divides by the poison -- the gdn_emit_chain w_mant
--             defect reproduced as a test.
--   r_valid   HELD across R_READY_LAG cycles, never falling without a ready.
--             The consumer sweeps 256 elements per head, so a pair it does not
--             take must WAIT, not vanish.
--   done      HELD across ACK_LAG cycles (RULE 1), and raised only after the
--             LAST pair has been ACCEPTED, not when it was produced.  The
--             testbench holds r_ready low over the final head for exactly that
--             reason: with a prompt consumer the two are indistinguishable.
--   s_ready   low for the whole divide.  A DUT that accepted a second
--             denominator mid-divide would overwrite the one being used.
--   err, ovr  must stay clear THROUGH THE MAIN LOOP.  err marks s = 0, which
--             attn_softmax's grid snap makes unreachable; ovr marks r leaving
--             16 bits, which the reference's range oracle proves cannot happen.
--
-- THE ZERO PROBE, at the end, is a deliberate CONTRACT VIOLATION.  The vector
-- generator never emits s = 0 -- it cannot, because the softmax floor is 3849
-- -- so nothing in the main loop exercises the s = 0 trap, and mutation N7
-- (trap removed, divider asked for x/0) SURVIVED every configuration until this
-- phase existed.  A guard that no vector reaches is not a guard, it is a
-- comment.  The probe drives s = 0 once and requires err = '1', r = 0, p = 0
-- and TERMINATION: divider_rs's own header says a zero divisor gives
-- unspecified-but-bounded garbage with no lockup, which is exactly the silent
-- legal-looking value this project has been bitten by, so the point is that the
-- divider is never asked.  The DUT's STRICT_PRODUCER assertion fires once here
-- BY DESIGN and its message is the expected observable, not a failure.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_recip is
  generic( NCASE  : positive := 24;
           NHEAD  : positive := 12;
           S_W    : positive := 26;
           R_W    : positive := 16;
           R_Q    : natural  := 15;
           -- Cycles to hold r_ready low after r_valid rises.  0 = prompt.
           R_READY_LAG : natural := 5;
           ACK_LAG     : natural := 4;
           HEARTBEAT_US : natural := 0;
           VECS   : string := "attn_recip_vec.txt" );
end entity;

architecture sim of tb_attn_recip is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal s_valid : std_logic := '0';
  signal s_in    : unsigned(S_W-1 downto 0) := (others => '0');
  signal s_last  : std_logic := '0';
  signal s_ready : std_logic;
  signal s_taken : std_logic;
  signal busy    : std_logic;

  signal r_valid : std_logic;
  signal p_out   : unsigned(clog2(S_W)-1 downto 0);
  signal r_out   : unsigned(R_W-1 downto 0);
  signal r_ready : std_logic := '1';

  signal done     : std_logic;
  signal done_ack : std_logic := '1';
  signal err, ovr : std_logic;

  type int_arr is array (natural range <>) of integer;
  signal nerr : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_recip
    generic map ( S_W => S_W, R_W => R_W, R_Q => R_Q, NW => 44, DW => 28,
                  STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               s_valid => s_valid, s_in => s_in, s_last => s_last,
               s_ready => s_ready, s_taken => s_taken, busy => busy,
               r_valid => r_valid, p_out => p_out, r_out => r_out,
               r_ready => r_ready,
               done => done, done_ack => done_ack, err => err, ovr => ovr );

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " s_ready=" & std_logic'image(s_ready)
           & " r_valid=" & std_logic'image(r_valid)
           & " done=" & std_logic'image(done) severity note;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nh, swv, rwv, rqv : integer;
    -- NOT `nhead`: VHDL is case-insensitive, so a variable of that name HIDES
    -- the generic NHEAD inside this process, and the shape assertion then
    -- compares the file against an uninitialised integer.  GHDL warns
    -- (-Whide) and the run fails at the assertion, which reads exactly like a
    -- malformed vector file.
    variable nh_c : integer;
    variable v_s, v_p, v_r : int_arr(0 to 63);
    variable held : boolean;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nh); read(ln, swv);
    read(ln, rwv); read(ln, rqv);
    assert nc = NCASE and nh = NHEAD and swv = S_W and rwv = R_W and rqv = R_Q
      report "tb_attn_recip: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln); read(ln, iv); read(ln, nh_c);
      readline(fh, ln);
      for h in 0 to nh_c-1 loop read(ln, iv); v_s(h) := iv; end loop;
      readline(fh, ln);
      for h in 0 to nh_c-1 loop read(ln, iv); v_p(h) := iv; end loop;
      readline(fh, ln);
      for h in 0 to nh_c-1 loop read(ln, iv); v_r(h) := iv; end loop;

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      for h in 0 to nh_c-1 loop
        s_valid <= '1';
        s_in    <= to_unsigned(v_s(h), S_W);
        if h = nh_c-1 then s_last <= '1'; else s_last <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when s_ready = '1';
        end loop;
        -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes
        -- in the SAME delta as the edge, so a pulse the DUT assigns on that
        -- edge still reads as '0' and looks exactly like a missing pulse.
        wait for 1 ns;
        assert s_taken = '1'
          report "case " & integer'image(c) & " head " & integer'image(h)
               & ": s_taken did not pulse at the accept instant"
          severity error;
        s_valid <= '0';
        s_last  <= '0';
        -- RULE 2: poison the port the instant it has been taken.  The divide
        -- reads this value for NW + 7 cycles; a DUT that reads it live divides
        -- by the poison.  A polite testbench that held s_in valid until the
        -- DUT was finished would pass either way.
        s_in    <= to_unsigned(1, S_W);

        -- Refuse the pair for a while, and check it is HELD rather than
        -- withdrawn.  On the LAST head this also separates "done at
        -- production" from "done at acceptance": a DUT that raises done when
        -- the pair is produced raises it here, while the pair is still
        -- unaccepted.
        if R_READY_LAG > 0 then r_ready <= '0'; else r_ready <= '1'; end if;
        while r_valid /= '1' loop wait until rising_edge(clk); end loop;
        held := true;
        for k in 1 to R_READY_LAG loop
          wait until rising_edge(clk);
          if r_valid /= '1' then held := false; end if;
          if h = nh_c-1 and done = '1' then
            report "case " & integer'image(c)
                 & ": done rose while the final pair was still unaccepted -- "
                 & "that pair is dropped under back-pressure" severity error;
            nerr <= nerr + 1;
          end if;
        end loop;
        if not held then
          report "case " & integer'image(c) & " head " & integer'image(h)
               & ": r_valid FELL before r_ready -- the pair is a pulse, and a "
               & "consumer busy at that instant loses the head's scale"
            severity error;
          nerr <= nerr + 1;
        end if;

        if to_integer(p_out) /= v_p(h) then
          report "case " & integer'image(c) & " head " & integer'image(h)
               & ": p got " & integer'image(to_integer(p_out))
               & " want " & integer'image(v_p(h))
               & "  (s " & integer'image(v_s(h)) & ")" severity error;
          nerr <= nerr + 1;
        end if;
        if to_integer(r_out) /= v_r(h) then
          report "case " & integer'image(c) & " head " & integer'image(h)
               & ": r got " & integer'image(to_integer(r_out))
               & " want " & integer'image(v_r(h))
               & "  (s " & integer'image(v_s(h)) & " p "
               & integer'image(v_p(h)) & ")" severity error;
          nerr <= nerr + 1;
        end if;
        if err /= '0' or ovr /= '0' then
          report "case " & integer'image(c) & " head " & integer'image(h)
               & ": err=" & std_logic'image(err) & " ovr="
               & std_logic'image(ovr)
               & " -- both are declared unreachable by the reference's range "
               & "oracle" severity error;
          nerr <= nerr + 1;
        end if;

        r_ready <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        r_ready <= '1';
      end loop;

      while done /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the layer" severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;
      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    -- ==================================================================
    -- ZERO PROBE.  See the header: nothing above reaches s = 0, so the trap
    -- is untested by the golden and a DUT that removed it would pass.  This
    -- deliberately violates attn_softmax's contract; the DUT's own
    -- STRICT_PRODUCER assertion is expected to fire and its message is the
    -- point, not a failure.
    -- ==================================================================
    r_ready  <= '1';
    done_ack <= '1';
    s_valid  <= '1';
    s_in     <= to_unsigned(0, S_W);
    s_last   <= '1';
    loop
      wait until rising_edge(clk);
      exit when s_ready = '1';
    end loop;
    wait for 1 ns;
    s_valid <= '0';
    s_last  <= '0';
    s_in    <= to_unsigned(12345, S_W);
    -- TERMINATION is half the property.  A DUT that handed 0 to divider_rs
    -- would still finish -- the divider always terminates after NW iterations
    -- -- so the check that separates them is the FLAG and the VALUE, not the
    -- absence of a hang.  The stop-time is the backstop for the other half.
    while r_valid /= '1' loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    if err /= '1' then
      report "ZERO PROBE: s = 0 was accepted and err did NOT fire.  Either the "
           & "trap is gone and divider_rs was handed a zero divisor -- whose "
           & "own header calls the result unspecified-but-bounded garbage -- "
           & "or the flag is not wired" severity error;
      nerr <= nerr + 1;
    end if;
    if to_integer(r_out) /= 0 or to_integer(p_out) /= 0 then
      report "ZERO PROBE: s = 0 gave p " & integer'image(to_integer(p_out))
           & " r " & integer'image(to_integer(r_out))
           & ", want 0 and 0" severity error;
      nerr <= nerr + 1;
    end if;
    wait until rising_edge(clk);
    while busy = '1' loop wait until rising_edge(clk); end loop;

    wait until rising_edge(clk);
    if nerr = 0 then
      report "tb_attn_recip: PASS -- " & integer'image(NCASE) & " layers x "
           & integer'image(NHEAD) & " heads bit-exact on BOTH p and r, with "
           & "s_taken pulsing at every accept, the denominator poisoned "
           & "immediately after, r_valid held across R_READY_LAG="
           & integer'image(R_READY_LAG) & " and done raised only after the "
           & "final pair was accepted; the s = 0 trap fires and terminates.  "
           & "ACK_LAG=" & integer'image(ACK_LAG)
        severity note;
    else
      report "tb_attn_recip: FAIL -- " & integer'image(nerr)
           & " mismatches" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
