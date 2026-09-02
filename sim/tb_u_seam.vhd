-- sim/tb_u_seam.vhd
-- THE BENCH FOR rtl/u_seam.vhd.  TRACK CARDTOP, 2026-09-02.
--
-- The seam converts a start/busy/done unit (B `gdn_block`, C `attn_block`)
-- into D's contract.  This bench drives it from BOTH sides at once: a D model
-- that follows seq_desc_fetch's actual rules, and a unit model whose
-- completion style and latency are stimulus, not assumption.
--
-- WHY THE UNIT MODEL IS PARAMETERISED.  The two units really do differ, and
-- the difference is read off their RTL rather than guessed:
--   "pulse"  B, rtl/gdn_block.vhd:625  -- `done <= ec_done`, one cycle.
--   "ack"    C, rtl/attn_block.vhd:1799 -- a LEVEL held until `done_ack`.
-- The seam claims to serve both.  A bench that drove only one would prove it
-- works for that one and say nothing about the claim, so BOTH are run and the
-- gate carries both rows.
--
-- WHY THE D MODEL IS A REGISTER-LEVEL MIRROR AND NOT A CONVENIENT ONE.  The
-- first version of this bench computed the expected epoch by hand, as
-- `job_epoch + 1` at the issue instant.  That expression encoded MY reading of
-- seq_desc_fetch, and the seam encoded the same reading, so the two agreed and
-- the bench passed a design that D would have rejected on every single job.
-- The same wrong reading had already shipped in rtl/a_desc_adapter.vhd behind
-- a 2,496-check bench.  So the model below mirrors D's actual REGISTERS --
-- `epoch_r` bumped on the issue edge, `job_epoch <= epoch_r` combinational, a
-- sticky capture of the echo at the first `done`, and the compare against
-- `epoch_r` at ack -- with the line numbers it is copied from.  Nothing about
-- the expected value is computed by this bench's author.
--
-- COUNTERS ARE PROCESS VARIABLES, NOT SIGNALS.  A signal assigned twice
-- between two waits keeps only the last write, so a bench built on signal
-- counters silently under-reports.  That defect shipped once in this project
-- (313 checks reported for 311 jobs, six of seven per job invisible) and the
-- only tell was arithmetic.  Every count below is a variable.
--
-- FOREIGN EPOCH BUMPS ARE PART OF THE STIMULUS, and they are what gives the
-- epoch check any teeth at all.  D keeps ONE `epoch_r` shared across all five
-- units and bumps it at every issue to ANY of them.  Without other units in
-- the picture the epoch advances exactly once per job of ours, so a seam that
-- IGNORED D and simply counted its own jobs would agree on every comparison.
-- MEASURED: mutation M8, `ep_q <= ep_q + 1`, SURVIVED the first version of
-- this bench on both completion styles.  The check was not wrong, it was
-- unreachable -- there was no way for a generated epoch to differ from a
-- latched one.  D_FOREIGN below bumps `epoch_r` between our jobs, exactly as
-- a job to A or C would, and M8 then dies.
--
-- WHAT THIS BENCH DOES NOT COVER, stated so it is not mistaken for coverage:
--   * the seam's two `severity failure` guards fire on a MISBEHAVING unit.
--     The unit model here is well-behaved by construction, so those guards are
--     never exercised.  They are checked separately by mutating the model
--     (mutations S and T in the table), not by this default run.
--   * B reports THREE error bits (err_conv, err_g, err_se) and C reports one.
--     The seam takes a single `unit_err`; ORing B's three is the glue's job
--     and is NOT checked here.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- ---------------------------------------------------------------------------
-- THE HARNESS: one seam, one unit model of a given completion style, one
-- register-level D mirror, one monitor.  It reports its counts on ports and
-- asserts nothing, so the top below can run BOTH styles in a SINGLE gate row
-- and still print both summaries even when one of them fails.
--
-- The gate's planner globs sim/tb_*.vhd and runs each with its DEFAULT
-- generics, so a bench parameterised over the style would have put only
-- "pulse" in the gate and left C's real shape -- a level held until its own
-- `done_ack` -- permanently unexercised there.  Instantiating both is what
-- makes the row cover the claim the seam actually makes.
-- ---------------------------------------------------------------------------
entity u_seam_harness is
  generic (
    DONE_STYLE : string := "pulse";  -- "pulse" (B) or "ack" (C)
    NJOB       : integer := 200
  );
  port (
    fin  : out boolean := false;
    nchk : out integer := 0;
    nbad : out integer := 0
  );
end entity;

architecture sim of u_seam_harness is
  constant EPOCH_W : positive := 4;
  constant TCK     : time := 10 ns;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';

  -- D side
  signal u_start      : std_logic := '0';
  signal u_ready      : std_logic;
  signal u_done       : std_logic;
  signal u_err        : std_logic;
  signal u_ack        : std_logic := '0';
  signal job_epoch    : unsigned(EPOCH_W-1 downto 0);
  signal u_done_epoch : std_logic_vector(EPOCH_W-1 downto 0);

  -- unit side
  signal unit_start : std_logic;
  signal unit_busy  : std_logic := '0';
  signal unit_done  : std_logic := '0';
  signal unit_ack   : std_logic;
  signal unit_err   : std_logic := '0';
  signal err_exp    : std_logic := '0';   -- what the unit reported, held

  type dst_t is (D_FOREIGN, D_ISSUE, D_WAIT, D_COMPLETE, D_STOP);
  signal dst         : dst_t := D_ISSUE;
  signal epoch_r     : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal epoch_seen  : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal done_seen   : std_logic := '0';
  signal err_seen    : std_logic := '0';
  signal n_job       : integer := 0;
  signal n_epoch_bad : integer := 0;
  signal n_epoch_ok  : integer := 0;
  signal n_foreign   : integer := 0;
  signal fl          : unsigned(15 downto 0) := x"BEEF";

  signal running : boolean := true;   -- cleared to wind the models down

  -- observation, driven by the monitor only
  signal n_err   : integer := 0;
  signal n_chk   : integer := 0;
  signal n_iss   : integer := 0;
  signal n_cmp   : integer := 0;
  signal n_pulse : integer := 0;   -- cycles unit_start was high, ALL jobs

  -- MUTATION HOOKS.  Set by the mutation harness, never by the default run.
  -- Kept as constants so an unmutated build is bit-identical to no hooks.
  constant MUT_STALE_DONE : boolean := false;  -- unit holds done into next job
  constant MUT_BUSY_ISSUE : boolean := false;  -- unit still busy at issue

begin

  -- THE CLOCK IS FREE-RUNNING.  An earlier version gated it on `running`,
  -- and when `running` cleared the monitor's `wait until rising_edge(clk)`
  -- never returned, so its ENTIRE summary -- every count and every one of the
  -- end-of-run checks -- was unreachable and the bench exited 0 in silence.
  -- A check that cannot be reached is not a check, and a silent rc=0 is the
  -- worst possible way to learn that.  `finish` ends the run instead.
  clk <= not clk after TCK/2;

  dut : entity work.u_seam
    generic map (EPOCH_W => EPOCH_W)
    port map (
      clk => clk, rstn => rstn,
      u_start => u_start, u_ready => u_ready, u_done => u_done,
      u_err => u_err, u_ack => u_ack,
      job_epoch => job_epoch, u_done_epoch => u_done_epoch,
      unit_start => unit_start, unit_busy => unit_busy, unit_done => unit_done,
      unit_ack => unit_ack, unit_err => unit_err);

  ------------------------------------------------------------------
  -- THE UNIT MODEL.  Latency varies per job so no check can pass by
  -- coincidence of a fixed schedule.
  ------------------------------------------------------------------
  unit_model : process is
    variable lat  : integer := 0;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
  begin
    unit_busy <= '0'; unit_done <= '0';
    loop
      wait until rising_edge(clk);
      exit when not running;
      if unit_start = '1' then
        -- latency 0..7, deterministic but not periodic, so no check can pass
        -- by coincidence of a fixed schedule
        lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
        lat  := to_integer(lfsr(2 downto 0));
        -- roughly one job in four reports an error, so the seam's err latch
        -- is exercised rather than merely present
        unit_err <= '0';
        unit_busy <= '1';
        for i in 1 to lat loop
          wait until rising_edge(clk);
          exit when not running;
        end loop;
        if MUT_BUSY_ISSUE then
          unit_busy <= '1';          -- never drops; issue lands on a busy unit
        else
          unit_busy <= '0';
        end if;
        if lfsr(5 downto 4) = "11" then
          unit_err <= '1'; err_exp <= '1';
        else
          unit_err <= '0'; err_exp <= '0';
        end if;
        unit_done <= '1';
        if DONE_STYLE = "pulse" then
          -- B: rtl/gdn_block.vhd:625, one cycle and gone
          wait until rising_edge(clk);
          if not MUT_STALE_DONE then
            unit_done <= '0';
          end if;
        else
          -- C: rtl/attn_block.vhd:1799, HELD until its own done_ack
          loop
            wait until rising_edge(clk);
            exit when not running;
            exit when unit_ack = '1';
          end loop;
          if not MUT_STALE_DONE then
            unit_done <= '0';
          end if;
        end if;
      end if;
    end loop;
    wait;
  end process;

  ------------------------------------------------------------------
  -- THE D MODEL: a register-level mirror of seq_desc_fetch's issue /
  -- wait / complete path.  Line references are to rtl/seq_desc_fetch.vhd.
  ------------------------------------------------------------------
  d_model : process(clk) is
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        dst <= D_FOREIGN; epoch_r <= (others => '0'); fl <= x"BEEF";
        n_foreign <= 0;
        done_seen <= '0'; epoch_seen <= (others => '0'); err_seen <= '0';
        n_job <= 0; n_epoch_bad <= 0; n_epoch_ok <= 0; u_ack <= '0';
      else
        u_ack <= '0';

        -- the STICKY capture, :641-644.  The raw u_done is never read by the
        -- compare; only this latch is, exactly as in D.
        if dst /= D_ISSUE and u_done = '1' and done_seen = '0' then
          done_seen  <= '1';
          err_seen   <= u_err;
          epoch_seen <= unsigned(u_done_epoch);
        end if;

        case dst is
          -- Jobs to the OTHER units.  D's epoch_r is global, so these bump it
          -- without this seam being involved.  They happen only BETWEEN our
          -- jobs, never during one, because D is a single sequencer: one job
          -- is in flight at a time (S_ISSUE -> S_WAIT -> S_COMPLETE).
          when D_FOREIGN =>
            fl <= fl(14 downto 0) & (fl(15) xor fl(13) xor fl(12) xor fl(10));
            if fl(1 downto 0) /= "00" then
              epoch_r   <= epoch_r + 1;
              n_foreign <= n_foreign + 1;
            else
              dst <= D_ISSUE;
            end if;

          when D_ISSUE =>
            -- :787  start is a LEVEL, qualified by this state
            if u_ready = '1' and u_done = '0' then
              epoch_r   <= epoch_r + 1;      -- :790, THE ONE INSTANT
              done_seen <= '0'; err_seen <= '0';
              dst       <= D_WAIT;
            end if;

          when D_WAIT =>
            if done_seen = '1' then
              dst <= D_COMPLETE;
            end if;

          when D_COMPLETE =>
            -- :834  epoch first; a mismatch means everything else this unit
            -- reported belongs to a different job
            if epoch_seen /= epoch_r then
              n_epoch_bad <= n_epoch_bad + 1;
            else
              n_epoch_ok <= n_epoch_ok + 1;
            end if;
            u_ack <= '1';                     -- :963
            n_job <= n_job + 1;
            if n_job + 1 >= NJOB then
              dst <= D_STOP;
            else
              dst <= D_FOREIGN;
            end if;

          when D_STOP =>
            null;
        end case;
      end if;
    end if;
  end process;

  -- :962  u_start is a level qualified by the issue state
  u_start   <= '1' when dst = D_ISSUE else '0';
  job_epoch <= epoch_r;                       -- :932, combinational

  stopper : process is
  begin
    wait until dst = D_STOP;
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    running <= false;
    wait;
  end process;


  ------------------------------------------------------------------
  -- THE MONITOR.  Everything asserted about the seam lives here, so
  -- one place holds every obligation and one counter holds every check.
  ------------------------------------------------------------------
  monitor : process is
    variable chk, err, iss, cmp, pul : integer := 0;
    variable n_errjob : integer := 0;
    variable armed      : boolean := false;   -- a job is outstanding
    variable done_prev  : std_logic := '0';
    variable ack_prev   : std_logic := '0';
    variable done_first : boolean := false;   -- this job's done already latched
    variable start_seen : boolean := false;   -- unit_start seen for this job

    procedure chk_true(cond : boolean; msg : string) is
    begin
      chk := chk + 1;
      if not cond then
        err := err + 1;
        report "CHECK FAILED: " & msg severity error;
      end if;
    end procedure;
  begin
    wait until rstn = '1';
    loop
      wait until rising_edge(clk);
      exit when not running;

      -- C1  ready and done are mutually exclusive.  seq_desc_fetch:899
      --     asserts this from its own side; a seam that violated it would
      --     trip D rather than this bench, so it is checked HERE too.
      chk_true(not (u_ready = '1' and u_done = '1'),
               "u_ready and u_done both high");

      -- C2  an UNARMED unit must never assert done.  seq_desc_fetch:909.
      chk_true(not (u_done = '1' and not armed),
               "u_done asserted with no job outstanding");

      -- C3  unit_start must never fire at a unit that is still busy.
      chk_true(not (unit_start = '1' and unit_busy = '1'),
               "unit_start asserted while unit_busy");

      -- C4  unit_start must not fire without D having issued.
      chk_true(not (unit_start = '1' and not armed),
               "unit_start asserted with no job outstanding");

      -- C5  done, once raised, HOLDS until ack.  A gap would let D miss it.
      if done_prev = '1' and u_done = '0' then
        chk_true(u_ack = '1' or ack_prev = '1',
                 "u_done dropped without an ack");
      end if;

      -- C6  the epoch echo is judged by the D MIRROR, not here: it captures
      --     the echo stickily at the first `done` and compares it against its
      --     own `epoch_r` at ack, which is what seq_desc_fetch does.  This
      --     bench deliberately states no expected epoch of its own.
      if u_done = '1' and not done_first then
        done_first := true;
        cmp := cmp + 1;
        chk_true(u_err = err_exp,
                 "echoed u_err " & std_logic'image(u_err)
                 & " /= the unit's " & std_logic'image(err_exp));
        if err_exp = '1' then n_errjob := n_errjob + 1; end if;
      end if;

      -- exactly ONE cycle of unit_start per job
      if unit_start = '1' then
        pul := pul + 1;
        chk_true(not start_seen, "unit_start asserted twice in one job");
        start_seen := true;
      end if;

      -- track the job boundary from D's own handshake
      if u_start = '1' and u_ready = '1' and u_done = '0' then
        iss := iss + 1;
        armed := true; done_first := false; start_seen := false;
      end if;
      if u_ack = '1' and u_done = '1' then
        chk_true(start_seen, "job completed but unit_start never fired");
        armed := false;
      end if;

      done_prev := u_done;
      ack_prev  := u_ack;
    end loop;

    -- C7  LIVENESS.  Every issued job completed.  This is the check that
    --     would be silently absent in any run that dies early, so it is
    --     reported alongside the counts rather than trusted on its own.
    chk := chk + 1;
    if cmp /= iss then
      err := err + 1;
      report "CHECK FAILED: issued " & integer'image(iss)
           & " but completed " & integer'image(cmp) severity error;
    end if;
    chk := chk + 1;
    if pul /= iss then
      err := err + 1;
      report "CHECK FAILED: " & integer'image(iss) & " jobs but "
           & integer'image(pul) & " unit_start cycles" severity error;
    end if;

    -- C8  THE EPOCH VERDICT, from the mirror.  Reported as a COUNT of good
    --     echoes as well as bad ones: a run where the epoch was never checked
    --     at all would show 0 and 0, and is not the same as a run that passed.
    chk := chk + 1;
    if n_epoch_bad /= 0 then
      err := err + 1;
      report "CHECK FAILED: " & integer'image(n_epoch_bad)
           & " completions carried a stale epoch" severity error;
    end if;
    chk := chk + 1;
    if n_epoch_ok /= iss then
      err := err + 1;
      report "CHECK FAILED: epoch compared on " & integer'image(n_epoch_ok)
           & " of " & integer'image(iss) & " jobs" severity error;
    end if;

    -- C9  the stimulus actually happened.  A run with no foreign epoch bumps
    --     cannot distinguish a latched epoch from a generated one, and a run
    --     with no error jobs cannot see the err latch at all.  Both were true
    --     of an earlier version of this bench and both checks passed anyway.
    chk := chk + 1;
    if n_foreign = 0 then
      err := err + 1;
      report "CHECK FAILED: no foreign epoch bumps; the epoch check is "
           & "unreachable in this run" severity error;
    end if;
    chk := chk + 1;
    if n_errjob = 0 then
      err := err + 1;
      report "CHECK FAILED: no job reported an error; the err latch is "
           & "unreachable in this run" severity error;
    end if;

    n_chk <= chk; n_err <= err; n_iss <= iss; n_cmp <= cmp; n_pulse <= pul;
    nchk <= chk; nbad <= err;
    wait for 1 ns;

    report "tb_u_seam[" & DONE_STYLE & "]: issued=" & integer'image(iss)
         & " epoch_ok=" & integer'image(n_epoch_ok)
         & " epoch_bad=" & integer'image(n_epoch_bad)
         & " foreign_bumps=" & integer'image(n_foreign)
         & " err_jobs=" & integer'image(n_errjob)
         & " completed=" & integer'image(cmp)
         & " unit_start_cycles=" & integer'image(pul)
         & " checks=" & integer'image(chk)
         & " mismatches=" & integer'image(err);

    -- Reported, not asserted: the top collects both styles.  `iss /= NJOB`
    -- is folded into the failure count rather than raised separately, because
    -- a run that ended early has counts that UNDERSTATE its coverage and must
    -- not be readable as a pass.
    if iss /= NJOB then
      err := err + 1;
      nbad <= err;
      report "CHECK FAILED: only " & integer'image(iss) & " of "
           & integer'image(NJOB) & " jobs were issued; the run did not reach "
           & "the end and every count above understates coverage"
        severity error;
    end if;
    fin <= true;
    wait;
  end process;

  -- watchdog: a deadlocked seam must fail, not hang the gate
  wd : process is
  begin
    wait for 2 ms;
    if running then
      report "tb_u_seam[" & DONE_STYLE & "]: WATCHDOG -- the run did not "
           & "finish; the seam or the unit model is deadlocked"
        severity failure;
    end if;
    wait;
  end process;

  rst_p : process is
  begin
    rstn <= '0';
    wait for 5*TCK;
    wait until rising_edge(clk);
    rstn <= '1';
    wait;
  end process;

end architecture;

-- ---------------------------------------------------------------------------
-- THE GATE ROW.  Both completion styles, one run.
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_u_seam is
end entity;

architecture sim of tb_u_seam is
  signal fin_p, fin_a : boolean;
  signal chk_p, chk_a : integer;
  signal bad_p, bad_a : integer;
begin
  -- B, rtl/gdn_block.vhd:625 -- `done` is a one-cycle pulse
  h_pulse : entity work.u_seam_harness
    generic map (DONE_STYLE => "pulse")
    port map (fin => fin_p, nchk => chk_p, nbad => bad_p);

  -- C, rtl/attn_block.vhd:1799 -- `done` is a LEVEL held until `done_ack`
  h_ack : entity work.u_seam_harness
    generic map (DONE_STYLE => "ack")
    port map (fin => fin_a, nchk => chk_a, nbad => bad_a);

  verdict : process is
  begin
    wait until fin_p and fin_a;
    wait for 1 ns;
    report "tb_u_seam: pulse checks=" & integer'image(chk_p)
         & " mismatches=" & integer'image(bad_p)
         & " | ack checks=" & integer'image(chk_a)
         & " mismatches=" & integer'image(bad_a);
    assert bad_p = 0 and bad_a = 0
      report "tb_u_seam: FAIL" severity failure;
    report "tb_u_seam: PASS" severity note;
    finish;
  end process;
end architecture;
