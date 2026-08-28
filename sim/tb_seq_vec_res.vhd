-- sim/tb_seq_vec_res.vhd
-- Bit-exactness of rtl/seq_vec_res.vhd (subsystem D, D-vec, opcode
-- OP_VEC_RES) against ref/seq_vec_res_vec.c.
--
-- NO TOLERANCE.  The C generator's six oracles establish that the integer
-- recipe means the right thing -- the real-valued error against a derived
-- bound, the normalisation range as exact integer inequalities, the sum formed
-- once in 64 bits and rounded once, the rounding DIRECTION as a two-sided
-- integer inequality, the clamp pinned from both sides by an exactness
-- argument, and invariance under a common shift of both exponents.  This file's
-- job is the narrower one of proving the RTL reproduces that recipe exactly.
--
-- WHAT IS CHECKED
--   out[i]    every element, exactly, read back OUT OF THE REGION MEMORY rather
--             than sampled off the write bus.  Sampling the bus would test the
--             datapath and not the addressing; reading the memory tests both,
--             and it is the only way to see a lane the DUT wrote that it should
--             have masked.
--   o_exp     exactly, and see the ORDERING GUARD below.
--   o_sat     exactly.  It is a SUMMARY of the stream, not a qualifier of it,
--             so unlike o_exp it is sampled at `done` and may not be earlier.
--   the mask   the padding lanes of the final partial group are loaded with a
--             POISON value, and they must still hold it afterwards.  Poison,
--             not zero: a masked lane folded into the magnitude reduction
--             changes `sh` and therefore every element, so the mask failure is
--             loud instead of local.
--   i_taken   pulses at the accept instant, and all three job inputs are
--             POISONED immediately afterwards.  The unit reads them for the
--             whole job; a DUT that read the live ports would use the poison.
--             This is the gdn_emit_chain w_mant defect reproduced as a test.
--   done      HELD across ACK_LAG cycles, and raised only AFTER the last write
--             beat.  The testbench runs ACK_LAG = 0 as well, deliberately: an
--             ack tied high is the only configuration that catches an explicit
--             `done` clear inside the ack branch, which is how the
--             gdn_head_emit defect was found.
--   ready     low for the whole job, and never high while `done` is held.
--   writes    exactly ceil(n/LANES) beats, group addresses strictly ascending
--             from 0, no group written twice, no beat outside the job.
--
-- THE ORDERING GUARD (`ord_chk`), after the gdn_conv e_seg defect of
-- 2026-08-27: `o_exp` qualifies every element the unit writes, so it is
-- captured at the FIRST write beat and required to equal its value at `done`.
-- A guard that only samples at `done` cannot distinguish a scalar published
-- before its stream from one published after it, which is exactly the defect.
--
-- THE ZERO-LENGTH PROBE, at the end, is a deliberate CONTRACT VIOLATION:
-- `seq_desc_fetch` rejects n_rows = 0 as ERR_DESC, so no vector can contain it
-- and the trap would otherwise be a comment.  A DUT that treated it as a no-op
-- would make a table bug look like a fast step.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity tb_seq_vec_res is
  generic(
    NCASE  : positive := 64;
    LANES  : positive := 8;
    MANT_W : positive := 16;
    ACC_W  : positive := 32;
    EXP_W  : positive := 16;
    ADDR_W : positive := 13;
    -- Cycles to hold done_ack LOW after `done` rises.  0 = tied high, which is
    -- NOT the weak configuration: it is the only one that catches a `done`
    -- register cleared inside the ack branch.
    ACK_LAG    : natural := 4;
    -- Cycles `start` stays high AFTER i_taken pulsed.  A DUT that accepted a
    -- second job off the same level would corrupt the one it is running.
    START_TAIL : natural := 0;
    -- Idle cycles between jobs.
    GAP        : natural := 0;
    -- Drive the read buses to 'X' whenever r_en is low.
    RD_POISON  : boolean := true;
    -- Write back into the SOURCE region (the real residual step) or into a
    -- separate one.  In-place is the case whose safety is an invariant.
    IN_PLACE   : boolean := true;
    HEARTBEAT_US : natural := 0;
    -- The value loaded into every lane past `n` and into the out-of-place
    -- destination.  A GENERIC and not a constant since 2026-08-27, and the
    -- SIGN is the point.  With the default +21845 a masked padding lane whose
    -- accumulator overruns the chosen shift saturates POSITIVELY, so the
    -- negative clamp in the DUT was never once executed by this bench; it was
    -- first reached by `tb_seq_vec_seam`, where the poison is negative, and
    -- the branch turned out to contain an out-of-range `to_signed`.  Run the
    -- sweep at both signs.
    POISON : integer := 21845;   -- 0x5555, not 0 and not full scale
    VECS   : string := "seq_vec_res_vec.txt" );
end entity;

architecture sim of tb_seq_vec_res is
  constant LOG2L : natural := clog2(LANES);
  constant GA_W  : natural := ADDR_W - LOG2L;
  constant NMAX  : natural := 4096;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal ready, start, i_taken : std_logic := '0';
  signal i_n     : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal i_exp_x : signed(EXP_W-1 downto 0) := (others => '0');
  signal i_exp_e : signed(EXP_W-1 downto 0) := (others => '0');

  signal r_en   : std_logic;
  signal r_addr : unsigned(GA_W-1 downto 0);
  signal x_rdata, e_rdata : std_logic_vector(LANES*MANT_W-1 downto 0)
                            := (others => '0');

  signal w_we   : std_logic;
  signal w_addr : unsigned(GA_W-1 downto 0);
  signal w_be   : std_logic_vector(LANES-1 downto 0);
  signal w_data : std_logic_vector(LANES*MANT_W-1 downto 0);

  signal done, done_ack, o_sat, err : std_logic := '0';
  signal o_exp   : signed(EXP_W-1 downto 0);
  signal o_shift : unsigned(5 downto 0);

  -- host load port and checker read port on the region model
  signal ld_en   : std_logic := '0';
  signal ld_addr : unsigned(GA_W-1 downto 0) := (others => '0');
  signal ld_x, ld_e : std_logic_vector(LANES*MANT_W-1 downto 0)
                      := (others => '0');
  signal ld_poison  : std_logic_vector(LANES*MANT_W-1 downto 0);
  signal c_addr : unsigned(GA_W-1 downto 0) := (others => '0');
  signal c_x, c_e, c_o : std_logic_vector(LANES*MANT_W-1 downto 0);

  -- MEASURED, not derived: cycles from the accept instant to `done` rising,
  -- kept for the largest job in the run.  The unit's cost model is
  -- 2*ceil(n/LANES) + a fixed overhead, and the overhead is the part nobody
  -- can read off the state diagram -- it is the two pipeline drains.
  signal fail    : natural := 0;
  signal cyc_job : natural := 0;
  signal cyc_max : natural := 0;
  signal n_max   : natural := 0;
  signal cnt_on  : std_logic := '0';
  -- The job's length, driven by the stimulus and NEVER poisoned.  Reading it
  -- off the `i_n` PORT at the accept does not work and the reason is the point
  -- of the poison: the stimulus overwrites that port 1 ns after the accept
  -- edge, which is inside the same clock cycle, so a process sampling it on
  -- the NEXT edge sees the poison and every job measures as n = 1.
  signal n_now : natural := 0;
  signal n_write : natural := 0;
  signal job_on  : std_logic := '0';   -- high from accept to done, for the monitor

  type int_arr is array (0 to NMAX-1) of integer;
begin
  clk <= not clk after 5 ns when running else '0';

  gen_poison : for i in 0 to LANES-1 generate
    ld_poison((i+1)*MANT_W-1 downto i*MANT_W)
      <= std_logic_vector(to_signed(POISON, MANT_W));
  end generate;

  dut : entity work.seq_vec_res
    generic map( LANES => LANES, MANT_W => MANT_W, ACC_W => ACC_W,
                 EXP_W => EXP_W, ADDR_W => ADDR_W, STRICT => true )
    port map( clk => clk, rst => rst,
              ready => ready, start => start, i_n => i_n,
              i_exp_x => i_exp_x, i_exp_e => i_exp_e, i_taken => i_taken,
              r_en => r_en, r_addr => r_addr,
              x_rdata => x_rdata, e_rdata => e_rdata,
              w_we => w_we, w_addr => w_addr, w_be => w_be, w_data => w_data,
              done => done, done_ack => done_ack,
              o_exp => o_exp, o_shift => o_shift, o_sat => o_sat, err => err );

  -- ======================================================================
  -- THE REGION MODEL.  1-cycle registered read, NO ready; free-running write
  -- strobe, NO ready.  Deliberately hostile between reads: the buses go to 'X'
  -- whenever r_en is low, so a DUT that latched the bus on the wrong cycle
  -- poisons its own pipeline instead of getting the right answer by luck.
  --
  -- WRITE-FIRST, and that is the load-bearing choice: the residual step reads
  -- X and writes X, and write-first makes an in-place overtake return the NEW
  -- data -- visibly wrong -- where read-first would return the old data and the
  -- run would pass on a design that only works because the memory happened to
  -- be read-first.
  -- ======================================================================
  mem : process(clk) is
    type gmem_t is array (0 to 2**GA_W-1)
         of std_logic_vector(LANES*MANT_W-1 downto 0);
    variable xm, em, om : gmem_t := (others => (others => '0'));
  begin
    if rising_edge(clk) then
      if ld_en = '1' then
        xm(to_integer(ld_addr)) := ld_x;
        em(to_integer(ld_addr)) := ld_e;
        -- The out-of-place destination is POISONED at load, not zeroed, for
        -- the same reason the padding lanes are: a lane the DUT wrote that it
        -- should have masked reads as a plausible 0 against a zeroed memory.
        om(to_integer(ld_addr)) := ld_poison;
      end if;
      if w_we = '1' then
        for i in 0 to LANES-1 loop
          if w_be(i) = '1' then
            if IN_PLACE then
              xm(to_integer(w_addr))((i+1)*MANT_W-1 downto i*MANT_W)
                := w_data((i+1)*MANT_W-1 downto i*MANT_W);
            else
              om(to_integer(w_addr))((i+1)*MANT_W-1 downto i*MANT_W)
                := w_data((i+1)*MANT_W-1 downto i*MANT_W);
            end if;
          end if;
        end loop;
      end if;
      if r_en = '1' then
        x_rdata <= xm(to_integer(r_addr));
        e_rdata <= em(to_integer(r_addr));
      elsif RD_POISON then
        x_rdata <= (others => 'X');
        e_rdata <= (others => 'X');
      end if;
      c_x <= xm(to_integer(c_addr));
      c_e <= em(to_integer(c_addr));
      c_o <= om(to_integer(c_addr));
    end if;
  end process;

  -- ======================================================================
  -- THE WRITE MONITOR.  Counting identities, not throughput.  A silently lossy
  -- path scores BETTER on any throughput metric than a correct one, so the
  -- load-bearing assertions are "exactly this many beats, in exactly this
  -- order" and they are present from the first run.
  -- ======================================================================
  wmon : process(clk) is
    variable expect : natural := 0;
  begin
    if rising_edge(clk) then
      if w_we = '1' then
        assert job_on = '1'
          report "tb_seq_vec_res: a write beat outside the job window -- the "
               & "unit is still driving strobes after its own completion"
          severity failure;
        assert to_integer(w_addr) = expect
          report "tb_seq_vec_res: write group " & integer'image(to_integer(w_addr))
               & ", expected " & integer'image(expect)
               & ".  Beats must be one per group, ascending from 0, none twice."
          severity failure;
        expect := expect + 1;
        n_write <= n_write + 1;
      end if;
      -- Reset the counting identity at the ACCEPT, not at the completion, and
      -- from THIS process only: two processes assigning one unresolved signal
      -- is an elaboration error that GHDL reports with no line number, which
      -- this project has been bitten by before.
      if i_taken = '1' then expect := 0; n_write <= 0; end if;
    end if;
  end process;

  -- ======================================================================
  -- ORDERING GUARD.  A scalar that qualifies a stream must be published in a
  -- state strictly earlier than the state that first raises that stream's
  -- valid.  `o_exp` qualifies every element written, so it is captured at the
  -- FIRST w_we and compared at `done`.  See docs/debugging/
  -- 2026-08-27_gdn-conv-eseg-published-late.md for the defect this exists for.
  -- ======================================================================
  ord_chk : process(clk) is
    variable seen  : boolean := false;
    variable at_w  : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if i_taken = '1' then seen := false; end if;
      if w_we = '1' and not seen then
        seen := true;
        at_w := o_exp;
      end if;
      if done = '1' and err = '0' and seen then
        -- to_string, NOT integer'image(to_integer(...)).  On a unit that
        -- published the exponent late it is metavalued at the first beat and
        -- to_integer raises INSIDE the report expression, killing the run with
        -- no message at all.
        assert at_w = o_exp
          report "tb_seq_vec_res: o_exp CHANGED after the first write beat -- "
               & to_string(at_w) & " at the first w_we, " & to_string(o_exp)
               & " at done.  The shared exponent qualifies every element it is "
               & "written with, so it must be final before the first of them."
          severity failure;
      end if;
    end if;
  end process;

  cycmon : process(clk) is
  begin
    if rising_edge(clk) then
      if i_taken = '1' then
        cyc_job <= 1; cnt_on <= '1';
      elsif cnt_on = '1' then
        if done = '1' then
          cnt_on <= '0';
          if n_now >= n_max then
            n_max   <= n_now;
            cyc_max <= cyc_job;
          end if;
        else
          cyc_job <= cyc_job + 1;
        end if;
      end if;
    end if;
  end process;

  hb : process is
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when not running;
      report "HB: ready=" & std_logic'image(ready)
           & " done=" & std_logic'image(done)
           & " writes=" & integer'image(n_write) severity note;
    end loop;
    wait;
  end process;

  stim : process is
    file fh : text;
    variable ln : line;
    variable iv, nc, mw, aw, sm, kp : integer;
    variable cn, cex, cee, coexp, csat, csh : integer;
    variable vx, ve, vo : int_arr;
    variable ng, lane, grp : natural;
    variable gv : std_logic_vector(LANES*MANT_W-1 downto 0);
    variable held : boolean;
    variable got  : integer;

    procedure err_msg(msg : string) is
    begin
      report "tb_seq_vec_res: " & msg severity error;
      fail <= fail + 1;
    end procedure;
  begin
    file_open(fh, VECS, read_mode);
    readline(fh, ln); read(ln, nc); read(ln, mw); read(ln, aw);
    read(ln, sm); read(ln, kp);
    assert nc = NCASE and mw = MANT_W and aw = ACC_W
           and sm = ACC_W - MANT_W - 1 and kp = MANT_W - 2
      report "tb_seq_vec_res: vector file shape mismatch -- the generator and "
           & "the generics disagree about MANT_W/ACC_W/SHMAX/KEEP"
      severity failure;

    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to NCASE-1 loop
      readline(fh, ln);
      read(ln, iv); read(ln, cn); read(ln, cex); read(ln, cee);
      read(ln, coexp); read(ln, csat); read(ln, csh);
      readline(fh, ln); for i in 0 to cn-1 loop read(ln, iv); vx(i) := iv; end loop;
      readline(fh, ln); for i in 0 to cn-1 loop read(ln, iv); ve(i) := iv; end loop;
      readline(fh, ln); for i in 0 to cn-1 loop read(ln, iv); vo(i) := iv; end loop;

      ng := (cn + LANES - 1) / LANES;

      -- ---- host load, LANES at a time.  The padding lanes of the final
      -- partial group get POISON, not zero: a masked lane folded into the
      -- magnitude reduction changes `sh` and therefore every element.
      for g in 0 to ng-1 loop
        for i in 0 to LANES-1 loop
          if g*LANES + i < cn then
            gv((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(vx(g*LANES+i), MANT_W));
          else
            gv((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(POISON, MANT_W));
          end if;
        end loop;
        ld_x <= gv;
        for i in 0 to LANES-1 loop
          if g*LANES + i < cn then
            gv((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(ve(g*LANES+i), MANT_W));
          else
            gv((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(POISON, MANT_W));
          end if;
        end loop;
        ld_e    <= gv;
        ld_addr <= to_unsigned(g, GA_W);
        ld_en   <= '1';
        wait until rising_edge(clk);
      end loop;
      ld_en <= '0';
      wait until rising_edge(clk);

      -- ---- issue.  `start` is a LEVEL held until accepted (defect class (b)
      -- from the producer side: a pulse at a unit that is not listening is a
      -- job that never runs).
      if ACK_LAG > 0 then done_ack <= '0'; else done_ack <= '1'; end if;
      n_now   <= cn;
      i_n     <= to_unsigned(cn, ADDR_W);
      i_exp_x <= to_signed(cex, EXP_W);
      i_exp_e <= to_signed(cee, EXP_W);
      start   <= '1';
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      -- 1 ns past the edge, not at it: `wait until rising_edge(clk)` resumes in
      -- the SAME delta as the edge, so a pulse the DUT assigns on that edge
      -- still reads as '0' and looks exactly like a missing pulse.
      wait for 1 ns;
      if i_taken /= '1' then
        err_msg("case " & integer'image(c)
              & ": i_taken did not pulse at the accept instant");
      end if;
      job_on <= '1';
      -- RULE 2: POISON the job ports the instant they have been taken, and
      -- BEFORE the START_TAIL hold rather than after it.  `start` is a request
      -- level; the DATA is captured at the accept, so a producer is entitled to
      -- move it on immediately.  Poisoning after the hold instead was a real
      -- hole: RTL mutation N14 -- the group count read from the LIVE i_n port
      -- rather than the job shadow -- SURVIVED the START_TAIL configuration
      -- for exactly that reason, and it is the polite-testbench failure the
      -- gdn_emit_chain w_mant document warns about, reproduced in a testbench
      -- written to catch it.
      i_n     <= to_unsigned(1, ADDR_W);
      i_exp_x <= to_signed(-999, EXP_W);
      i_exp_e <= to_signed(999, EXP_W);
      for k in 1 to START_TAIL loop wait until rising_edge(clk); end loop;
      start <= '0';

      -- ---- wait for the completion, checking `ready` stays low -----------
      while done /= '1' loop
        if ready = '1' then
          err_msg("case " & integer'image(c)
                & ": ready went high mid-job -- a second start would be taken");
          exit;
        end if;
        wait until rising_edge(clk);
      end loop;
      job_on <= '0';

      held := true;
      for k in 1 to ACK_LAG loop
        wait until rising_edge(clk);
        if done /= '1' then held := false; end if;
        if ready = '1' then
          err_msg("case " & integer'image(c)
                & ": ready went high while done was still held");
        end if;
      end loop;
      if not held then
        err_msg("case " & integer'image(c)
              & ": done FELL before done_ack -- it is a pulse, and a "
              & "sequencer busy at that instant loses the step");
      end if;

      -- ---- the scalars, sampled at `done` -------------------------------
      if to_integer(o_exp) /= coexp then
        err_msg("case " & integer'image(c) & ": o_exp got "
              & integer'image(to_integer(o_exp)) & " want "
              & integer'image(coexp));
      end if;
      if to_integer(o_shift) /= csh then
        err_msg("case " & integer'image(c) & ": o_shift got "
              & integer'image(to_integer(o_shift)) & " want "
              & integer'image(csh));
      end if;
      if (o_sat = '1') /= (csat = 1) then
        err_msg("case " & integer'image(c) & ": o_sat got "
              & std_logic'image(o_sat) & " want " & integer'image(csat));
      end if;
      if err /= '0' then
        err_msg("case " & integer'image(c) & ": err asserted on a legal job");
      end if;
      if n_write /= ng then
        err_msg("case " & integer'image(c) & ": " & integer'image(n_write)
              & " write beats, want " & integer'image(ng)
              & ".  Beats are the counting identity; a lost one is a silently "
              & "wrong activation element.");
      end if;

      done_ack <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      if ACK_LAG > 0 then done_ack <= '0'; end if;

      -- ---- read the region back and compare, element by element ---------
      for g in 0 to ng-1 loop
        c_addr <= to_unsigned(g, GA_W);
        wait until rising_edge(clk);
        wait for 1 ns;
        for i in 0 to LANES-1 loop
          if IN_PLACE then
            got := to_integer(signed(c_x((i+1)*MANT_W-1 downto i*MANT_W)));
          else
            got := to_integer(signed(c_o((i+1)*MANT_W-1 downto i*MANT_W)));
          end if;
          if g*LANES + i < cn then
            if got /= vo(g*LANES + i) then
              err_msg("case " & integer'image(c) & " element "
                    & integer'image(g*LANES + i) & ": got "
                    & integer'image(got) & " want "
                    & integer'image(vo(g*LANES + i)));
            end if;
          else
            -- The padding lane must still hold its poison, in BOTH modes.  A
            -- DUT that wrote it has written past the end of the vector, into
            -- whatever the region map puts next.
            if got /= POISON then
              err_msg("case " & integer'image(c) & " PADDING lane "
                    & integer'image(g*LANES + i) & " was overwritten with "
                    & integer'image(got) & " -- the lane mask does not hold");
            end if;
          end if;
        end loop;
      end loop;

      -- ---- and the SOURCE that was not the destination must be untouched -
      if not IN_PLACE then
        for g in 0 to ng-1 loop
          c_addr <= to_unsigned(g, GA_W);
          wait until rising_edge(clk);
          wait for 1 ns;
          for i in 0 to LANES-1 loop
            if g*LANES + i < cn then
              got := to_integer(signed(c_x((i+1)*MANT_W-1 downto i*MANT_W)));
              if got /= vx(g*LANES + i) then
                err_msg("case " & integer'image(c) & ": source element "
                      & integer'image(g*LANES + i) & " was modified");
              end if;
            end if;
          end loop;
        end loop;
      end if;

      for k in 1 to GAP loop wait until rising_edge(clk); end loop;
    end loop;
    file_close(fh);

    -- ==================================================================
    -- ZERO-LENGTH PROBE.  A deliberate contract violation: `seq_desc_fetch`
    -- rejects n_rows = 0 as ERR_DESC, so no vector can carry it and the trap
    -- is untested by the golden.  A DUT that treated it as a no-op would make
    -- a table bug look like a fast step, which is the silent legal-looking
    -- outcome this project has been bitten by.
    -- ==================================================================
    done_ack <= '1';
    n_now   <= 0;
    i_n     <= to_unsigned(0, ADDR_W);
    i_exp_x <= to_signed(3, EXP_W);
    i_exp_e <= to_signed(3, EXP_W);
    start   <= '1';
    loop
      wait until rising_edge(clk);
      exit when ready = '1';
    end loop;
    wait for 1 ns;
    start <= '0';
    job_on <= '1';
    while done /= '1' loop wait until rising_edge(clk); end loop;
    job_on <= '0';
    if err /= '1' then
      err_msg("ZERO PROBE: a zero-length job completed with err = 0.  It is a "
            & "table bug, not a no-op, and it must be reported as one.");
    end if;
    if n_write /= 0 then
      err_msg("ZERO PROBE: a zero-length job emitted "
            & integer'image(n_write) & " write beats");
    end if;
    wait until rising_edge(clk);

    wait until rising_edge(clk);
    if fail = 0 then
      report "tb_seq_vec_res: PASS -- " & integer'image(NCASE)
           & " cases bit-exact on every element, on o_exp, o_shift and o_sat, "
           & "with i_taken pulsing at every accept and the job ports poisoned "
           & "immediately after, done held across ACK_LAG="
           & integer'image(ACK_LAG) & ", START_TAIL="
           & integer'image(START_TAIL) & ", IN_PLACE="
           & boolean'image(IN_PLACE) & "; the zero-length job reports err."
        severity note;
      report "tb_seq_vec_res: MEASURED " & integer'image(cyc_max)
           & " cycles accept-to-done at n = " & integer'image(n_max)
           & " with LANES = " & integer'image(LANES)
           & " (2*ceil(n/LANES) = "
           & integer'image(2*((n_max + LANES - 1)/LANES)) & ")"
        severity note;
    else
      report "tb_seq_vec_res: FAIL -- " & integer'image(fail)
           & " check(s) failed" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
