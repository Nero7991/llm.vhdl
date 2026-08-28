-- sim/tb_attn_twiddle.vhd
-- Bit-exactness of rtl/attn_twiddle.vhd (subsystem C, sites R1/R2) against
-- ref/attn_twiddle_vec.c.
--
-- NO TOLERANCE.  The C generator's seven oracles establish that the integer
-- recipe means the right thing -- the table against libm to half an ulp and
-- against its own exact symmetries, the phase against the real fractional turn
-- inside a bound DERIVED from the W rounding, sin and cos against libm inside
-- a three-term derived bound, the CHORD DIRECTION swept EXHAUSTIVELY over
-- every table interval, Pythagoras on the pair, and pos = 0 and the grid
-- points as exact equalities -- plus the C spec 3.11 deliverable, that the
-- collapsed single-angle form equals the full IMROPE sector dispatch on every
-- enumerated (pos, j).  This file's job is the narrower one of proving the RTL
-- reproduces that recipe exactly.
--
-- WHAT IS CHECKED:
--   phi        SEPARATELY from cos and sin, and that separation is the whole
--              reason a failure is diagnosable.  Every trig value derives from
--              the phase, so a wrong phase and a wrong table look identical in
--              cos and sin alone.  Same lesson as attn_kv_quant's separate
--              block-exponent check.
--   cos, sin   both, for every pair, exactly.
--   tw_j       in order, 0 .. NPAIR-1, with no gaps.  A stream that is right
--              in content and wrong in order is still wrong.
--   cfg_taken  pulses at start, and `pos` is POISONED immediately afterwards.
--              It is read for the whole job, so a DUT that read it live
--              computes the tail of the stream against the poison.
--   ORDERING   cfg_taken must pulse STRICTLY BEFORE the first pair is offered.
--              From subsystem B's 2026-08-27 gdn_conv defect, where a scalar
--              was assigned in the FINAL state and so described beats that had
--              already gone past.
--   tw_valid   HELD when tw_ready is low, and tw_cos / tw_sin / tw_phi / tw_j
--              UNCHANGED across the hold.  A valid held while the data moves
--              underneath it loses the pair just as completely as a pulse and
--              is much quieter, because the COUNT still comes out right.
--   done       HELD across ACK_LAG (RULE 1) and raised only after the LAST
--              pair has been ACCEPTED.
--   err        must stay clear: the interpolation returns a value between two
--              table entries, so it cannot leave the Q15 range.
--
-- THE TWO ZERO CASES ARE NOT THE SAME CASE.  pos = 0 makes every phi zero, so
-- it exercises the frac = 0 path at idx 0 and 256 for all 32 pairs at once;
-- that is the identity case and it is a golden like any other.  It is NOT a
-- substitute for a position whose phase wraps a whole turn, which is what
-- exercises site R1's mod-2^32 truncation, and the generator's coverage
-- assertion requires both.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_twiddle is
  generic( NCASE : positive := 24;
           NPAIR : positive := 32;
           POS_W : positive := 16;
           Q_W   : positive := 16;
           PHI_W : positive := 32;
           -- Period of the consumer's ready.  0 = tie it high, the DEGENERATE
           -- configuration.  Non-zero must exceed the 8-stage pipeline or a
           -- DUT that lets the pipeline run under a held valid cannot be told
           -- from one that freezes it.
           TW_GAP  : natural := 3;
           ACK_LAG : natural := 4;
           HEARTBEAT_US : natural := 0;
           VECS  : string := "attn_twiddle_vec.txt" );
end entity;

architecture sim of tb_attn_twiddle is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal start     : std_logic := '0';
  signal pos       : unsigned(POS_W-1 downto 0) := (others => '0');
  signal cfg_taken : std_logic;
  signal busy      : std_logic;

  signal tw_valid : std_logic;
  signal tw_j     : unsigned(clog2(NPAIR)-1 downto 0);
  signal tw_cos   : signed(Q_W-1 downto 0);
  signal tw_sin   : signed(Q_W-1 downto 0);
  signal tw_phi   : unsigned(PHI_W-1 downto 0);
  signal tw_ready : std_logic;

  signal done     : std_logic;
  signal done_ack : std_logic := '1';
  signal err      : std_logic;

  type int_arr is array (natural range <>) of integer;
  -- Written by the monitor only, so there is exactly one driver each.
  signal c_got : int_arr(0 to 63) := (others => 0);
  signal s_got : int_arr(0 to 63) := (others => 0);
  signal ph_hi : int_arr(0 to 63) := (others => 0);
  signal ph_lo : int_arr(0 to 63) := (others => 0);
  signal j_got : int_arr(0 to 63) := (others => 0);
  signal n_got : integer := 0;
  signal clr   : std_logic := '0';

  signal mon_err : integer := 0;
  signal ord_err : integer := 0;
  signal nerr    : integer := 0;
  signal tick    : integer := 0;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.attn_twiddle
    generic map ( NPAIR => NPAIR, TBL => 1024, POS_W => POS_W, Q_W => Q_W,
                  PHI_W => PHI_W, STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => start, pos => pos, cfg_taken => cfg_taken,
               busy => busy,
               tw_valid => tw_valid, tw_j => tw_j, tw_cos => tw_cos,
               tw_sin => tw_sin, tw_phi => tw_phi, tw_ready => tw_ready,
               done => done, done_ack => done_ack, err => err );

  -- A FREE-RUNNING ready pattern, not one keyed off the accepted count.
  -- tb_attn_kv_quant's write-up records that a ready derived from the accepted
  -- count DEADLOCKS: nothing is accepted while it is low, so the condition
  -- that lowered it never clears, and the run looks like a DUT hang.
  tickp : process(clk)
  begin
    if rising_edge(clk) then tick <= tick + 1; end if;
  end process;
  tw_ready <= '1' when TW_GAP = 0 else
              '1' when (tick mod (TW_GAP + 1)) = TW_GAP else '0';

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " tw_valid=" & std_logic'image(tw_valid)
           & " done=" & std_logic'image(done) severity note;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- MONITOR.  Samples at the rising edge, which reads the PRE-edge value.
  -- Sampling after the edge reads the post-edge value and, on the last item of
  -- a burst, fires on correct behaviour; that trap cost a run in
  -- tb_attn_score_q12 and is recorded in the kv-quant write-up.
  -- ==================================================================
  mon : process
    variable tv_d, tr_d : std_logic := '0';
    variable c_d, s_d, j_d, hi_d, lo_d : integer := 0;
  begin
    loop
      wait until rising_edge(clk);
      exit when not running;
      if clr = '1' then
        n_got <= 0; tv_d := '0'; tr_d := '0';
      else
        if tw_valid = '1' and tw_ready = '1' then
          if n_got < 64 then
            c_got(n_got) <= to_integer(tw_cos);
            s_got(n_got) <= to_integer(tw_sin);
            j_got(n_got) <= to_integer(tw_j);
            ph_hi(n_got) <= to_integer(tw_phi(PHI_W-1 downto 16));
            ph_lo(n_got) <= to_integer(tw_phi(15 downto 0));
          end if;
          n_got <= n_got + 1;
        end if;

        if tv_d = '1' and tr_d = '0' then
          if tw_valid /= '1' then
            report "tw_valid FELL without a ready -- the pair is a pulse, and "
                 & "a consumer busy at that instant loses the rotation for "
                 & "that dim pair entirely" severity error;
            mon_err <= mon_err + 1;
          elsif to_integer(tw_cos) /= c_d or to_integer(tw_sin) /= s_d
                or to_integer(tw_j) /= j_d
                or to_integer(tw_phi(PHI_W-1 downto 16)) /= hi_d
                or to_integer(tw_phi(15 downto 0)) /= lo_d then
            report "the twiddle CHANGED while tw_valid was held and tw_ready "
                 & "was low -- the pipeline advanced under a blocked output, "
                 & "so the pair standing there is lost while the COUNT still "
                 & "comes out right" severity error;
            mon_err <= mon_err + 1;
          end if;
        end if;

        tv_d := tw_valid;
        tr_d := tw_ready;
        c_d  := to_integer(tw_cos);
        s_d  := to_integer(tw_sin);
        j_d  := to_integer(tw_j);
        hi_d := to_integer(tw_phi(PHI_W-1 downto 16));
        lo_d := to_integer(tw_phi(15 downto 0));
      end if;
    end loop;
    wait;
  end process;

  -- ==================================================================
  -- ORDERING GUARD.  From docs/debugging/2026-08-27_gdn-conv-eseg-published-
  -- late.md: a scalar that qualifies a stream must be assigned in a state
  -- STRICTLY EARLIER than the state that first raises that stream's valid, and
  -- a testbench that samples the scalar at `done` cannot tell you whether that
  -- holds.  Here the scalar is `pos` and the stream is every pair of the job.
  --
  -- to_string, NOT integer'image(to_integer(...)): on a DUT with the defect
  -- the scalar can still be metavalued at the first beat, and to_integer then
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
        if tw_valid = '1' and not seen_cfg then
          report "ORDERING: a twiddle pair was offered before cfg_taken "
               & "pulsed.  pos reads " & to_string(pos)
               & " -- the job's scalar is published LATER than the stream it "
               & "qualifies, which is the gdn_conv e_seg shape and which no "
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
    variable iv, nc, np, tblv, fw : integer;
    variable c_id, c_pos : integer;
    variable v_hi, v_lo, v_c, v_s : int_arr(0 to 63);
    variable ok : boolean;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, nc); read(ln, np); read(ln, tblv); read(ln, fw);
    assert nc = NCASE and np = NPAIR and tblv = 1024
           and fw = PHI_W - clog2(1024)
      report "tb_attn_twiddle: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, c_id); read(ln, c_pos);
      readline(fh, ln);
      for j in 0 to NPAIR-1 loop
        read(ln, iv); v_hi(j) := iv;
        read(ln, iv); v_lo(j) := iv;
        read(ln, iv); v_c(j)  := iv;
        read(ln, iv); v_s(j)  := iv;
      end loop;

      clr <= '1';
      wait until rising_edge(clk);
      clr <= '0';
      wait until rising_edge(clk);

      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      pos <= to_unsigned(c_pos, POS_W);
      wait until rising_edge(clk);
      start <= '1';
      wait until rising_edge(clk);
      -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes
      -- in the SAME delta as the edge, so a pulse the DUT assigns on that edge
      -- still reads as '0' and looks exactly like a missing pulse.  Carried
      -- over from tb_attn_kv_quant; it has now been the right call six times.
      wait for 1 ns;
      assert cfg_taken = '1'
        report "case " & integer'image(c)
             & ": cfg_taken did not pulse at start" severity error;
      start <= '0';
      -- RULE 2: poison the port the instant it has been taken.  It is read for
      -- the whole job; a DUT that reads it live computes the tail of the
      -- stream against the poison.  A polite testbench that held pos valid
      -- until the DUT was finished would pass either way.
      pos <= to_unsigned(12345, POS_W);

      while done /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the position" severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;

      if n_got /= NPAIR then
        report "case " & integer'image(c) & ": " & integer'image(n_got)
             & " pairs came out, want " & integer'image(NPAIR)
             & " -- pairs were dropped, not delayed" severity error;
        nerr <= nerr + 1;
      end if;
      ok := true;
      for j in 0 to NPAIR-1 loop
        if j < n_got then
          if j_got(j) /= j then
            if ok then
              report "case " & integer'image(c) & " beat " & integer'image(j)
                   & ": tw_j got " & integer'image(j_got(j)) & " want "
                   & integer'image(j) & " -- the stream is out of order"
                severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          -- phi CHECKED SEPARATELY.  Site R1 alone; every trig value below
          -- derives from it, so checking only cos and sin cannot tell a wrong
          -- phase from a wrong table.
          if ph_hi(j) /= v_hi(j) or ph_lo(j) /= v_lo(j) then
            if ok then
              report "case " & integer'image(c) & " pair " & integer'image(j)
                   & ": phi got " & integer'image(ph_hi(j)) & ":"
                   & integer'image(ph_lo(j)) & " want "
                   & integer'image(v_hi(j)) & ":" & integer'image(v_lo(j))
                   & "  (site R1, pos " & integer'image(c_pos) & ")"
                severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          if c_got(j) /= v_c(j) then
            if ok then
              report "case " & integer'image(c) & " pair " & integer'image(j)
                   & ": cos got " & integer'image(c_got(j)) & " want "
                   & integer'image(v_c(j)) & "  (site R2 at phi + a quarter "
                   & "turn)" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
          if s_got(j) /= v_s(j) then
            if ok then
              report "case " & integer'image(c) & " pair " & integer'image(j)
                   & ": sin got " & integer'image(s_got(j)) & " want "
                   & integer'image(v_s(j)) & "  (site R2)" severity error;
              ok := false;
            end if;
            nerr <= nerr + 1;
          end if;
        end if;
      end loop;

      if err /= '0' then
        report "case " & integer'image(c) & ": err fired -- an interpolation "
             & "left the Q15 range, which lying between two table entries "
             & "makes impossible" severity error;
        nerr <= nerr + 1;
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    wait until rising_edge(clk);
    if nerr = 0 and mon_err = 0 and ord_err = 0 then
      report "tb_attn_twiddle: PASS -- " & integer'image(NCASE)
           & " positions x " & integer'image(NPAIR) & " pairs bit-exact on "
           & "phi AND cos AND sin, in j order, with cfg_taken pulsing before "
           & "the first pair and pos poisoned immediately after, tw_valid and "
           & "its data held across a blocked ready, and done raised only "
           & "after the last pair was accepted.  TW_GAP="
           & integer'image(TW_GAP) & " ACK_LAG=" & integer'image(ACK_LAG)
        severity note;
    else
      report "tb_attn_twiddle: FAIL -- "
           & integer'image(nerr + mon_err + ord_err) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
