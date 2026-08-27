-- sim/tb_attn_kv_quant.vhd
-- Bit-exactness of rtl/attn_kv_quant.vhd (subsystem C step 4, the KV-cache
-- write-side quantizer) against ref/attn_kv_quant_vec.c.
--
-- NO TOLERANCE.  The C generator's own double oracle is what establishes that
-- the integer recipe means the right thing -- it recomputes every mantissa in
-- floating point from the emitted exponent and requires exact agreement, and
-- it separately requires each block's peak to land in [64, 128) output LSB.
-- This file's job is the narrower one of proving the RTL reproduces that
-- recipe exactly.  A tolerance here could only hide a disagreement between the
-- two.
--
-- WHAT IS CHECKED, and why each item is separate from the others:
--
--   the mantissa stream   the record's payload, element by element, in the
--                         order it is produced.  The index the unit reports
--                         (m_index) is checked against the position in the
--                         stream, so an element delivered in the wrong ORDER
--                         fails even if its VALUE is right.
--   the block exponents   the record's header.  Checked SEPARATELY from the
--                         mantissas: an exponent that is wrong by the same
--                         amount as the shift produces mantissas that are
--                         right, so a payload-only check certifies a unit
--                         whose whole grid has moved.
--   header before payload hdr_valid must have risen before the first m_valid.
--                         The 272-byte record is laid out header-first and the
--                         read side needs all 8 exponents before any mantissa.
--   o_sat                 saturation is REACHABLE here (amax = 255 gives
--                         sh = 1 and round_shift(255,1) = 128), so a unit that
--                         silently wraps instead of clipping must fail.
--   v_ref                 the write-time min fold, per vector, checked against
--                         the generator's running value.  This is the field
--                         whose INIT is not neutral: 0 instead of +127 passes
--                         every other check in this file.
--
-- BACK-PRESSURE IS PART OF THE TEST, not a performance question.  M_GAP drives
-- m_ready low periodically.  The read path runs one address AHEAD of the
-- capture stage, so a stall that freezes the address but not the memory's read
-- enable makes the capture stage take the wrong element with the right index:
-- every value in range, the record the right length, only the data wrong.  The
-- source memory below therefore implements x_re faithfully -- it HOLDS its
-- output register when x_re is low -- because a testbench memory that ignores
-- x_re would make the DUT pass whether or not it drives x_re correctly, and
-- would be testing nothing.  M_GAP = 0 leaves that path unexercised, which is
-- why the run sweeps both.
--
-- A HEARTBEAT, not a guess.  A run producing no output is ambiguous between
-- wedged and slow, and that ambiguity cost about an hour on gdn_head_emit.
-- HEARTBEAT_US reports the DUT's observable state on a wall-clock period so
-- the ambiguity is settled in one run rather than by alternating theories.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_attn_kv_quant is
  generic( HEAD_DIM : positive := 256;
           KV_BLOCK : positive := 32;
           NCASE    : positive := 64;
           -- 0 = never stall.  N > 0 = drive m_ready low for one cycle every
           -- N accepted elements, which is what exercises the read-enable
           -- contract.  Both are run.
           M_GAP    : natural  := 3;
           -- 0 = ack immediately (the default '1' semantics).  N > 0 = hold
           -- done_ack low for N cycles, which is what proves done is HELD and
           -- not pulsed.  A pulsed done passes at 0 and hangs at 5.
           ACK_LAG  : natural  := 5;
           HEARTBEAT_US : natural := 0;
           VECS     : string   := "attn_kv_quant_vec.txt" );
end entity;

architecture sim of tb_attn_kv_quant is
  constant NBLK : integer := HEAD_DIM / KV_BLOCK;
  constant AW   : integer := clog2(HEAD_DIM);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal start   : std_logic := '0';
  signal is_v    : std_logic := '0';
  signal src_exp : signed(7 downto 0) := (others => '0');
  signal cfg_taken, busy : std_logic;
  signal kv_seq_rst : std_logic := '0';
  signal seq_rst_taken : std_logic;

  signal x_raddr : std_logic_vector(AW-1 downto 0);
  signal x_re    : std_logic;
  signal x_rdata : std_logic_vector(15 downto 0) := (others => '0');

  signal hdr_valid : std_logic;
  signal e_blk     : std_logic_vector(NBLK*8-1 downto 0);
  signal m_valid   : std_logic;
  signal m_data    : std_logic_vector(7 downto 0);
  signal m_index   : std_logic_vector(AW-1 downto 0);
  signal m_ready   : std_logic := '1';
  signal done      : std_logic;
  signal done_ack  : std_logic := '1';
  signal o_sat     : std_logic;
  signal err       : std_logic;
  signal v_ref     : signed(7 downto 0);

  -- The source head vector.  A synchronous-read RAM WITH AN ENABLE, which is
  -- the contract the DUT's x_re depends on.  Written by the stimulus process
  -- before each vector, read by the DUT.
  type xmem_t is array (0 to HEAD_DIM-1) of std_logic_vector(15 downto 0);
  -- A shared variable, not a signal: it is written by the stimulus process and
  -- read by the memory process, and a signal driven from two processes is an
  -- unresolved-signal elaboration error that GHDL reports with NO LINE NUMBER.
  shared variable xmem : xmem_t;

  type int_arr is array (natural range <>) of integer;
  signal nerr : integer := 0;

  -- The record header, snapshotted AT THE INSTANT hdr_valid rises.
  --
  -- Checking e_blk only at `done` is not enough, and a mutation proved it:
  -- raising hdr_valid at `start` instead of after the last block exponent
  -- SURVIVED that check, because by `done` the exponents are correct whenever
  -- they were raised.  The `hdr_first` flag below catches a hdr_valid that is
  -- too LATE and is blind to one that is too EARLY -- and too early is the
  -- dangerous direction, because a consumer that latches the header on the
  -- rising edge then latches the PREVIOUS vector's exponents.  Snapshotting
  -- here is what makes hdr_valid mean "e_blk is settled" rather than merely
  -- "e_blk will be settled eventually".
  signal hdr_d : std_logic := '0';
  shared variable hdr_snap : std_logic_vector(NBLK*8-1 downto 0);
  shared variable hdr_seen : boolean := false;
begin
  clk <= not clk after 5 ns when running else '0';

  -- The source memory.  It HOLDS x_rdata when x_re is low.  That is not a
  -- convenience: if this process ignored x_re, a DUT that never drove x_re
  -- would still pass, and the whole read-enable contract would be untested.
  xram : process(clk)
  begin
    if rising_edge(clk) then
      if x_re = '1' then
        x_rdata <= xmem(to_integer(unsigned(x_raddr)));
      end if;
    end if;
  end process;

  hdrmon : process(clk)
  begin
    if rising_edge(clk) then
      hdr_d <= hdr_valid;
      if hdr_valid = '1' and hdr_d = '0' then
        hdr_snap := e_blk;
        hdr_seen := true;
      end if;
    end if;
  end process;

  dut : entity work.attn_kv_quant
    generic map ( HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK,
                  IN_W => 16, MANT_W => 8, EXP_W => 8,
                  VREF_INIT => 127, STRICT_PRODUCER => true )
    port map ( clk => clk, rst => rst,
               start => start, is_v => is_v, src_exp => src_exp,
               cfg_taken => cfg_taken, busy => busy,
               kv_seq_rst => kv_seq_rst, seq_rst_taken => seq_rst_taken,
               x_raddr => x_raddr, x_re => x_re, x_rdata => x_rdata,
               hdr_valid => hdr_valid, e_blk => e_blk,
               m_valid => m_valid, m_data => m_data, m_index => m_index,
               m_ready => m_ready,
               done => done, done_ack => done_ack,
               o_sat => o_sat, err => err, v_ref => v_ref );

  hb : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: busy=" & std_logic'image(busy)
           & " hdr=" & std_logic'image(hdr_valid)
           & " m_valid=" & std_logic'image(m_valid)
           & " m_ready=" & std_logic'image(m_ready)
           & " done=" & std_logic'image(done)
           & " x_re=" & std_logic'image(x_re)
        severity note;
    end loop;
    wait;
  end process;

  stim : process
    file fh : text;
    variable ln : line;
    variable iv, nc, nn, nb : integer;
    variable v_x    : int_arr(0 to HEAD_DIM-1);
    variable v_e    : int_arr(0 to NBLK-1);
    variable v_m    : int_arr(0 to HEAD_DIM-1);
    variable v_isv, v_sexp, v_sat, v_vr0, v_vr1 : integer;
    variable got, ne : integer;
    variable ngot   : integer;
    variable hdr_first : boolean;
    variable accepted, tick : integer;
    variable stalled_once : boolean := false;
  begin
    -- M_GAP = 1 makes (tick mod 1) = 0 = M_GAP-1 on EVERY cycle, so m_ready
    -- is never high and the run wedges with m_valid asserted forever.  That is
    -- a degenerate testbench setting, not a DUT defect, and it looks exactly
    -- like a hang.  Refused loudly rather than left as a trap.
    assert M_GAP /= 1
      report "tb_attn_kv_quant: M_GAP = 1 holds m_ready low forever and cannot "
           & "make progress.  Use 0 for no stalls or >= 2 for one stall cycle "
           & "in every M_GAP." severity failure;

    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, nn); read(ln, nb);
    assert nc = NCASE and nn = HEAD_DIM and nb = KV_BLOCK
      report "tb_attn_kv_quant: vector file shape mismatch" severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- The per-sequence reset of the v_ref fold, driven as the LEVEL it is.
    -- The generator starts its own fold at +127, so the DUT must too, and
    -- this is the only place that is established.
    kv_seq_rst <= '1';
    -- 1 ns past the edge, not AT it.  `wait until rising_edge(clk)` resumes in
    -- the same delta the edge occurs in, so a signal the DUT assigns on that
    -- edge has not propagated yet and every _taken pulse reads as '0'.  This
    -- is a testbench artefact, not a DUT defect, and it looks exactly like a
    -- missing pulse.
    wait until rising_edge(clk);
    wait for 1 ns;
    assert seq_rst_taken = '1'
      report "seq_rst_taken did not pulse on the rising edge of kv_seq_rst"
      severity error;
    kv_seq_rst <= '0';
    wait until rising_edge(clk);
    if v_ref /= to_signed(127, 8) then
      report "v_ref after kv_seq_rst is " & integer'image(to_integer(v_ref))
           & ", want 127.  The fold init is NOT neutral: an init of 0 makes "
           & "the read side right-shift every V block by its full exponent."
        severity error;
      nerr <= nerr + 1;
    end if;

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv);      -- case index
      read(ln, v_isv); read(ln, v_sexp); read(ln, v_sat);
      read(ln, v_vr0); read(ln, v_vr1);
      readline(fh, ln);
      for i in 0 to HEAD_DIM-1 loop read(ln, iv); v_x(i) := iv; end loop;
      readline(fh, ln);
      for b in 0 to NBLK-1   loop read(ln, iv); v_e(b) := iv; end loop;
      readline(fh, ln);
      for i in 0 to HEAD_DIM-1 loop read(ln, iv); v_m(i) := iv; end loop;

      for i in 0 to HEAD_DIM-1 loop
        xmem(i) := std_logic_vector(to_signed(v_x(i), 16));
      end loop;

      -- RULE 2 in action.  start is a one-cycle pulse and the descriptor is
      -- presented WITH it, then withdrawn immediately: src_exp is driven to a
      -- deliberately wrong value on the very next cycle, so a DUT that reads
      -- the port live instead of its latched copy gets a wrong exponent for
      -- every block after the first.  That is the gdn_emit_chain w_mant defect
      -- reproduced as a test rather than waited for.
      start <= '1';
      if v_isv = 1 then is_v <= '1'; else is_v <= '0'; end if;
      src_exp <= to_signed(v_sexp, 8);
      wait until rising_edge(clk);
      wait for 1 ns;                     -- see the note on seq_rst_taken above
      assert cfg_taken = '1'
        report "cfg_taken did not pulse at the accept instant" severity error;
      start   <= '0';
      src_exp <= to_signed(-99, 8);      -- poison the descriptor ports
      if v_isv = 1 then is_v <= '0'; else is_v <= '1'; end if;

      ngot := 0;
      accepted := 0;
      tick := 0;
      hdr_seen := false;
      hdr_first := true;
      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;

      -- Collect the stream.  m_ready is deasserted on the M_GAP schedule.
      while ngot < HEAD_DIM loop
        -- Keyed off a free-running CYCLE count, not off the accepted count.
        -- Keying it off `accepted` deadlocks the testbench: while m_ready is
        -- low nothing is accepted, so the condition that lowered it never
        -- clears and the DUT waits forever with m_valid high.  The symptom is
        -- a wedged run that looks like a DUT hang.
        if M_GAP > 0 and (tick mod M_GAP) = (M_GAP - 1) then
          m_ready <= '0';
        else
          m_ready <= '1';
        end if;
        wait until rising_edge(clk);
        tick := tick + 1;
        if m_valid = '1' and hdr_valid = '0' then
          hdr_first := false;
        end if;
        if m_valid = '1' and m_ready = '1' then
          got := to_integer(signed(m_data));
          if got /= v_m(ngot) then
            report "case " & integer'image(c) & " elem " & integer'image(ngot)
                 & ": mant got " & integer'image(got)
                 & " want " & integer'image(v_m(ngot)) severity error;
            nerr <= nerr + 1;
            exit;
          end if;
          if to_integer(unsigned(m_index)) /= ngot then
            report "case " & integer'image(c) & " elem " & integer'image(ngot)
                 & ": m_index got "
                 & integer'image(to_integer(unsigned(m_index)))
                 & " -- the stream is out of order" severity error;
            nerr <= nerr + 1;
            exit;
          end if;
          ngot := ngot + 1;
          accepted := accepted + 1;
        elsif m_valid = '1' and m_ready = '0' then
          stalled_once := true;
        end if;
      end loop;
      m_ready <= '1';

      if not hdr_first then
        report "case " & integer'image(c)
             & ": a mantissa was produced before hdr_valid rose -- the record "
             & "is header-first and the read side needs every block exponent "
             & "before any mantissa" severity error;
        nerr <= nerr + 1;
      end if;

      -- done must be HELD across ACK_LAG cycles, not pulsed.  A pulsed done
      -- passes at ACK_LAG = 0 and hangs here, which is the whole point.
      while done /= '1' loop wait until rising_edge(clk); end loop;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then
          report "case " & integer'image(c)
               & ": done fell before done_ack -- it is a pulse, and a consumer "
               & "busy at that instant loses the whole record"
            severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;

      -- Checked at done, where the record is complete...
      for b in 0 to NBLK-1 loop
        ne := to_integer(signed(e_blk((b+1)*8-1 downto b*8)));
        if ne /= v_e(b) then
          report "case " & integer'image(c) & " block " & integer'image(b)
               & ": exponent got " & integer'image(ne)
               & " want " & integer'image(v_e(b)) severity error;
          nerr <= nerr + 1;
          exit;
        end if;
      end loop;
      -- ...and AGAIN as snapshotted at the rising edge of hdr_valid, which is
      -- the check with teeth against a hdr_valid raised before the exponents
      -- exist.  See the declaration of hdr_snap.
      if not hdr_seen then
        report "case " & integer'image(c)
             & ": hdr_valid never rose during this vector" severity error;
        nerr <= nerr + 1;
      else
        for b in 0 to NBLK-1 loop
          ne := to_integer(signed(hdr_snap((b+1)*8-1 downto b*8)));
          if ne /= v_e(b) then
            report "case " & integer'image(c) & " block " & integer'image(b)
                 & ": exponent AT THE RISING EDGE OF hdr_valid was "
                 & integer'image(ne) & ", want " & integer'image(v_e(b))
                 & " -- hdr_valid rose before the header was settled"
              severity error;
            nerr <= nerr + 1;
            exit;
          end if;
        end loop;
      end if;
      if (o_sat = '1') /= (v_sat = 1) then
        report "case " & integer'image(c) & ": o_sat got "
             & std_logic'image(o_sat) & " want " & integer'image(v_sat)
          severity error;
        nerr <= nerr + 1;
      end if;
      if to_integer(v_ref) /= v_vr1 then
        report "case " & integer'image(c) & ": v_ref got "
             & integer'image(to_integer(v_ref)) & " want "
             & integer'image(v_vr1) severity error;
        nerr <= nerr + 1;
      end if;
      if err /= '0' then
        report "case " & integer'image(c) & ": err asserted" severity error;
        nerr <= nerr + 1;
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      done_ack <= '1';
      while busy = '1' loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    if M_GAP > 0 and not stalled_once then
      report "M_GAP = " & integer'image(M_GAP) & " but m_ready never actually "
           & "refused an element -- the back-pressure path is UNTESTED.  A "
           & "zero back-pressure count is a question, not a result."
        severity error;
      nerr <= nerr + 1;
    end if;

    wait until rising_edge(clk);
    if nerr = 0 then
      report "tb_attn_kv_quant: PASS -- " & integer'image(NCASE) & " vectors x "
           & integer'image(HEAD_DIM) & " (" & integer'image(NBLK)
           & " blocks of " & integer'image(KV_BLOCK)
           & ") bit-exact: mantissas, block exponents, o_sat and the v_ref "
           & "fold, with M_GAP=" & integer'image(M_GAP)
           & " ACK_LAG=" & integer'image(ACK_LAG) severity note;
    else
      report "tb_attn_kv_quant: FAIL -- " & integer'image(nerr) & " mismatches"
        severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
