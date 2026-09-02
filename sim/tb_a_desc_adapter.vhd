-- sim/tb_a_desc_adapter.vhd
-- TRACK CARDTOP increment 2.  The card's D-to-A seam, against a slave that
-- MODELS matvec_int4_desc_axi's completion semantics rather than merely
-- acknowledging its writes.
--
-- WHY THE MODEL AND NOT A BARE SINK.  The adapter's whole correctness
-- argument is about WHEN a GO may be issued: the unit clears `done_l` on GO
-- and on nothing else, so a GO issued before D acked the previous
-- completion erases a `done` D never saw, and D then waits forever on a job
-- that already finished.  A slave that only handshakes cannot exhibit that
-- failure, so it cannot witness the fix.  This one clears its `done` on
-- every GO, exactly as rtl/matvec_int4_desc_axi.vhd:712 does.
--
-- VERDICT: prints "tb_a_desc_adapter: PASS -- <n> checks, 0 mismatches".

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_a_desc_adapter is
end entity;

architecture sim of tb_a_desc_adapter is

  constant ADDR_W      : positive := 40;
  constant LITE_AW     : positive := 8;
  constant DESC_STRIDE : positive := 512;
  constant N_JOBS      : positive := 311;

  -- the arena hbm_map.py placed; see tools/hbm_map.py's header
  constant ARENA : unsigned(63 downto 0) := x"00000001FFFD9000";

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal stop : boolean   := false;

  signal arena_base : std_logic_vector(ADDR_W-1 downto 0);
  signal u_start    : std_logic := '0';
  signal u_index    : std_logic_vector(15 downto 0) := (others => '0');
  signal u_ready, u_done, u_err : std_logic;
  signal u_ack      : std_logic := '0';
  constant EPOCH_W  : positive := 4;
  signal job_epoch  : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal u_done_epoch : std_logic_vector(EPOCH_W-1 downto 0);

  signal m_awaddr  : std_logic_vector(LITE_AW-1 downto 0);
  signal m_awvalid : std_logic;
  signal m_awready : std_logic := '0';
  signal m_wdata   : std_logic_vector(31 downto 0);
  signal m_wstrb   : std_logic_vector(3 downto 0);
  signal m_wvalid  : std_logic;
  signal m_wready  : std_logic := '0';
  signal m_bresp   : std_logic_vector(1 downto 0) := "00";
  signal m_bvalid  : std_logic := '0';
  signal m_bready  : std_logic;

  signal job_done : std_logic := '0';
  signal job_err  : std_logic := '0';
  signal jobs_issued : std_logic_vector(31 downto 0);

  -- the slave's write log, one job's worth
  type log_a_t is array (0 to 7) of integer;
  type log_d_t is array (0 to 7) of std_logic_vector(31 downto 0);
  signal log_a  : log_a_t := (others => -1);
  signal log_d  : log_d_t := (others => (others => '0'));
  signal log_n  : integer := 0;


  -- set by the slave when it sees a GO.  The DRIVER may not clear the log
  -- itself: two processes assigning one signal is multiple drivers on an
  -- unresolved type, which GHDL rejects at elaboration.  It requests a
  -- clear and the slave, the log's only driver, performs it.
  signal clr_log    : std_logic := '0';
  signal saw_go     : boolean := false;
  -- THE HAZARD WITNESS.  IT TOOK THREE FORMULATIONS AND THE FIRST TWO BOTH
  -- FAILED TO FIRE ON N8, THE MUTANT THEY WERE WRITTEN FOR.  Recorded in
  -- full because the failure mode is the interesting part.
  --
  --   v1: the DRIVER declared "a completion is standing" and the slave
  --       flagged writes inside that window.  Never fired: the offending
  --       write can land outside the driver's five-cycle hold.  A check
  --       whose firing depends on the testbench's own timing is not an
  --       invariant.
  --   v2: "no AXI write completes while u_done is high", computed from
  --       ports alone.  Sounded stronger and is still WRONG, because the
  --       adapter LEAVES S_DONE to issue the bad write, so u_done is low at
  --       the moment the write lands.  The invariant described the state the
  --       adapter was in, not the obligation it had.
  --   v3, below: latch the OBLIGATION.  From the edge u_done rises until
  --       u_ack is seen, a completion is outstanding; any write completing
  --       in that interval is the defect, whatever state the adapter has
  --       moved to meanwhile.
  --
  -- The lesson is the one CLAUDE.md states about guards that pass for the
  -- wrong reason: a check that has never been shown to fail has not been
  -- shown to work, and both earlier versions read as perfectly sound.
  signal go_unacked : boolean := false;

begin

  clk <= not clk after 5 ns when not stop else '0';
  arena_base <= std_logic_vector(ARENA(ADDR_W-1 downto 0));

  dut : entity work.a_desc_adapter
    generic map (ADDR_W => ADDR_W, LITE_AW => LITE_AW,
                 DESC_STRIDE => DESC_STRIDE, N_JOBS => N_JOBS,
                 EPOCH_W => EPOCH_W)
    port map (
      clk => clk, rstn => rstn,
      arena_base => arena_base,
      u_start => u_start, u_index => u_index,
      u_ready => u_ready, u_done => u_done, u_err => u_err, u_ack => u_ack,
      job_epoch => job_epoch, u_done_epoch => u_done_epoch,
      m_awaddr => m_awaddr, m_awvalid => m_awvalid, m_awready => m_awready,
      m_wdata => m_wdata, m_wstrb => m_wstrb, m_wvalid => m_wvalid,
      m_wready => m_wready, m_bresp => m_bresp, m_bvalid => m_bvalid,
      m_bready => m_bready,
      job_done => job_done, job_err => job_err,
      jobs_issued => jobs_issued);

  -- ====================================================================
  -- THE SLAVE MODEL.  Accepts AW and W independently with varying delay,
  -- answers B, logs every write, and reproduces the unit's done semantics:
  -- a GO clears `done`, and completion sets it some cycles later.
  -- ====================================================================
  slave : process(clk)
    variable lfsr    : unsigned(15 downto 0) := x"ACE1";
    variable aw_seen : boolean := false;
    variable w_seen  : boolean := false;
    variable a_v     : integer := 0;
    variable d_v     : std_logic_vector(31 downto 0) := (others => '0');
    variable cd      : integer := -1;   -- completion countdown, -1 = idle
    variable pend    : boolean := false; -- a completion is outstanding
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        m_awready <= '0'; m_wready <= '0'; m_bvalid <= '0';
        aw_seen := false; w_seen := false; cd := -1;
        pend := false;
        job_done <= '0';
      else
        lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));

        -- the obligation latch.  ack clears; u_done sets.  Ack wins a tie,
        -- which is correct: the completion has been consumed that cycle.
        if u_ack = '1' then
          pend := false;
        elsif u_done = '1' then
          pend := true;
        end if;

        if clr_log = '1' then
          log_n  <= 0;
          log_a  <= (others => -1);
          saw_go <= false;
        end if;

        -- ready lines wiggle so the adapter cannot depend on same-cycle AW+W
        m_awready <= lfsr(0);
        m_wready  <= lfsr(3);

        if m_bvalid = '1' and m_bready = '1' then
          m_bvalid <= '0';
        end if;

        if m_awvalid = '1' and m_awready = '1' then
          aw_seen := true;
          a_v := to_integer(unsigned(m_awaddr));
        end if;
        if m_wvalid = '1' and m_wready = '1' then
          w_seen := true;
          d_v := m_wdata;
        end if;

        if aw_seen and w_seen and m_bvalid = '0' then
          aw_seen := false; w_seen := false;
          m_bvalid <= '1';

          if log_n < 8 then
            log_a(log_n) <= a_v;
            log_d(log_n) <= d_v;
          end if;
          log_n <= log_n + 1;

          -- THE HAZARD WITNESS v4: REPORT AT THE POINT OF VIOLATION.
          -- v3 was correct and still never fired, for a reason that had
          -- nothing to do with the invariant: it was only EVALUATED by a
          -- chk at the very end of the stimulus process, and the N8 mutant
          -- deadlocks the driver, so the watchdog ends the run with
          -- `severity failure` long before that line is reached.  A check
          -- that only runs at the end of the test cannot fire in any run
          -- that dies before the end -- and the mutants likeliest to
          -- violate a liveness property are exactly the ones that die
          -- early.  So the monitor speaks where it sees the violation, and
          -- the end-of-test chk below is kept only as a summary.
          if pend then
            if not go_unacked then
              report "tb_a_desc_adapter MISMATCH: an AXI write completed "
                     & "while a completion was outstanding: a job was "
                     & "issued on top of a completion D has not consumed"
                     severity error;
            end if;
            go_unacked <= true;
          end if;

          if a_v = 8 and d_v(0) = '1' then
            saw_go   <= true;
            job_done <= '0';                 -- the unit's :712 behaviour
            cd := 3 + to_integer(lfsr(2 downto 0));
          end if;
        end if;

        if cd > 0 then
          cd := cd - 1;
        elsif cd = 0 then
          job_done <= '1';
          cd := -1;
        end if;
      end if;
    end if;
  end process;

  -- ====================================================================
  -- WATCHDOG.  Without this, the N4 mutant (leave S_DONE without waiting
  -- for u_ack) is caught only as a HANG: the driver misses the one-cycle
  -- `done`, blocks forever, and the suite records NOVERDICT after the full
  -- 900 ms stop time.  That is a detection, but a useless one -- it names
  -- no cause and is indistinguishable from any other deadlock.  Worse, the
  -- `go_unacked` witness written specifically for that hazard NEVER FIRES
  -- under N4, because the driver deadlocks before a later write can occur.
  -- The witness covers the case where the adapter keeps running; this
  -- covers the case where it stops.  Both are needed and neither subsumes
  -- the other.
  -- ====================================================================
  watchdog : process(clk)
    variable idle  : integer := 0;
    variable last  : integer := -1;
    constant LIMIT : integer := 20000;
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        idle := 0; last := -1;
      else
        if to_integer(unsigned(jobs_issued)) /= last then
          last := to_integer(unsigned(jobs_issued));
          idle := 0;
        else
          idle := idle + 1;
        end if;
        assert idle < LIMIT
          report "tb_a_desc_adapter: FAIL -- watchdog, no job progressed in "
                 & integer'image(LIMIT) & " cycles after "
                 & integer'image(last) & " jobs; the adapter is deadlocked"
          severity failure;
      end if;
    end if;
  end process;

  -- ====================================================================
  -- THE DRIVER AND THE CHECKS
  -- ====================================================================
  stim : process
    variable exp   : unsigned(63 downto 0);

    -- COUNTERS ARE VARIABLES, NOT SIGNALS, AND THAT IS LOAD-BEARING.
    -- The first version of this bench incremented two SIGNALS.  A signal
    -- assignment takes effect after a wait, so every chk call between two
    -- waits computed the same right-hand side and the last one won: the
    -- suite reported 313 checks for 311 jobs, i.e. ONE of the seven checks
    -- per job was counted and the other six were invisible in the verdict.
    -- A miscounted check is not a cosmetic defect: `n_mismatch` is what the
    -- PASS line is computed from, so two failures in one job would have
    -- been reported as one.  Variables update immediately.
    variable nc    : integer := 0;
    variable nm    : integer := 0;

    procedure chk(cond : boolean; msg : string) is
    begin
      nc := nc + 1;
      if not cond then
        nm := nm + 1;
        report "tb_a_desc_adapter MISMATCH: " & msg severity error;
      end if;
    end procedure;

    procedure issue(i : integer) is
    begin
      clr_log <= '1';
      wait until rising_edge(clk);
      clr_log <= '0';

      -- FOREIGN EPOCH BUMPS.  seq_desc_fetch keeps ONE `epoch_r` shared
      -- across all five units and bumps it at every issue to ANY of them, so
      -- between two A jobs the epoch advances by however many jobs went to
      -- B, C or V.  Without these the epoch advances exactly once per A job
      -- and an adapter that ignored D and counted its own jobs would agree on
      -- every comparison.
      --
      -- MEASURED 2026-09-02, and this is why the loop is here: with the
      -- adapter mutated back to latching the epoch at the issue edge -- the
      -- real off-by-one this bench was supposed to be guarding -- the bench
      -- still reported PASS, 2496 checks, 0 mismatches.  The epoch check was
      -- not wrong, it was unreachable: the old code bumped `job_epoch` two
      -- cycles BEFORE the start and then held it, so latching at issue and
      -- latching a cycle later read the SAME value and no timing error could
      -- be expressed.
      for k in 0 to (i mod 3) loop
        job_epoch <= job_epoch + 1;
        wait until rising_edge(clk);
      end loop;

      u_index <= std_logic_vector(to_unsigned(i, 16));
      u_start <= '1';
      -- D holds start until it sees ready; the accepting edge is the one
      -- where both are high.
      loop
        wait until rising_edge(clk);
        exit when u_ready = '1';
      end loop;
      -- THE ONE INSTANT.  seq_desc_fetch bumps `epoch_r` ON this edge
      -- (rtl/seq_desc_fetch.vhd:790) while `job_epoch <= epoch_r` (:932) is
      -- combinational, so the adapter sees the OLD value during the accepting
      -- cycle and the NEW one from the next cycle on.  S_COMPLETE compares
      -- the echo against the NEW one (:834).  Bumping here rather than
      -- earlier is what makes the two latch timings distinguishable.
      job_epoch <= job_epoch + 1;
      wait until rising_edge(clk);
      u_start <= '0';
    end procedure;

    procedure finish is
    begin
      loop
        wait until rising_edge(clk);
        exit when u_done = '1';
      end loop;
      -- sit on the completion for a few cycles: a GO issued in here is the
      -- failure this bench exists to catch.  The witness does not depend on
      -- this delay any more, but the delay still widens the opportunity.
      for k in 0 to 4 loop wait until rising_edge(clk); end loop;
      u_ack <= '1';
      wait until rising_edge(clk);
      u_ack <= '0';
    end procedure;

  begin
    rstn <= '0';
    for k in 0 to 4 loop wait until rising_edge(clk); end loop;
    rstn <= '1';
    wait until rising_edge(clk);

    -- ---- a token of A jobs -------------------------------------------
    for i in 0 to N_JOBS-1 loop
      issue(i);
      finish;

      exp := ARENA + to_unsigned(i * DESC_STRIDE, 64);

      chk(log_n = 3, "job " & integer'image(i) & ": expected 3 writes, saw "
          & integer'image(log_n));
      if log_n = 3 then
        chk(log_a(0) = 0 and log_a(1) = 4 and log_a(2) = 8,
            "job " & integer'image(i) & ": register order is not LO,HI,GO");
        chk(log_d(0) = std_logic_vector(exp(31 downto 0)),
            "job " & integer'image(i) & ": DESC_PTR_LO wrong");
        chk(log_d(1) = std_logic_vector(exp(63 downto 32)),
            "job " & integer'image(i) & ": DESC_PTR_HI wrong");
        chk(log_d(2)(0) = '1',
            "job " & integer'image(i) & ": CTRL bit0 not set");
      end if;
      chk(u_err = '0', "job " & integer'image(i) & ": spurious error");
      chk(unsigned(u_done_epoch) = job_epoch,
          "job " & integer'image(i) & ": echoed epoch "
          & integer'image(to_integer(unsigned(u_done_epoch)))
          & " but D issued epoch "
          & integer'image(to_integer(job_epoch)));
      -- every descriptor address must meet the unit's own DESC_ALIGN
      chk(exp(8 downto 0) = 0,
          "job " & integer'image(i) & ": descriptor address not 512-aligned");
    end loop;

    chk(not go_unacked,
        "an AXI write completed while u_done was high: a job was issued on top of an unconsumed completion");
    chk(to_integer(unsigned(jobs_issued)) = N_JOBS,
        "jobs_issued is " & integer'image(to_integer(unsigned(jobs_issued)))
        & ", expected " & integer'image(N_JOBS));

    -- ---- REFUSAL: an index past the arena's capacity ------------------
    issue(N_JOBS);
    loop
      wait until rising_edge(clk);
      exit when u_done = '1';
    end loop;
    chk(u_err = '1', "an out-of-capacity index was not refused");
    chk(unsigned(u_done_epoch) = job_epoch,
        "a REFUSED job echoed a stale epoch, so D would reject its own error "
        & "report and wait forever on a job that is never retried");
    chk(log_n = 0, "an out-of-capacity index still issued "
        & integer'image(log_n) & " writes");
    chk(to_integer(unsigned(jobs_issued)) = N_JOBS,
        "a refused job incremented jobs_issued");
    u_ack <= '1'; wait until rising_edge(clk); u_ack <= '0';

    -- ---- the job after a refusal still works -------------------------
    issue(7);
    finish;
    exp := ARENA + to_unsigned(7 * DESC_STRIDE, 64);
    chk(log_n = 3 and log_d(0) = std_logic_vector(exp(31 downto 0)),
        "the job after a refusal did not issue correctly");
    chk(u_err = '0', "the error flag survived into a good job");

    wait until rising_edge(clk);
    if nm = 0 then
      report "tb_a_desc_adapter: PASS -- " & integer'image(nc)
             & " checks, 0 mismatches" severity note;
    else
      report "tb_a_desc_adapter: FAIL -- " & integer'image(nm)
             & " mismatches of " & integer'image(nc) & " checks"
             severity failure;
    end if;
    stop <= true;
    wait;
  end process;

end architecture;
