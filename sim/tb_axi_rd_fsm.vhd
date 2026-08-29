-- sim/tb_axi_rd_fsm.vhd -- a DIRECT bench for rtl/axi_rd_fsm.vhd, the AR-issue
-- and burst-accounting FSM of every one of the FK33's 27 read masters.
--
-- WHY THIS FILE EXISTS.  Like rtl/async_fifo.vhd, this unit had no bench of its
-- own before 2026-08-29: it was reached only through rtl/axi_rd_port.vhd, and
-- sim/tb_axi_rd_port.vhd runs four jobs against one always-well-behaved slave
-- at MAXOUT=2 / DEPTH=64.  What that bench cannot separate is which of the two
-- units is responsible for what, and it never puts the FSM anywhere near the
-- two limits it exists to enforce.
--
-- THE ONE PROPERTY THE THROTTLE EXISTS FOR, AND HOW IT IS GIVEN TEETH
-- ---------------------------------------------------------------------------
-- rtl/axi_rd_fsm.vhd's own comment says the AR channel is "throttled against
-- FIFO free space INCLUDING beats already requested, so an accepted burst can
-- never overrun the FIFO".  A bench whose modelled FIFO BACKPRESSURES cannot
-- test that at all: backpressure would absorb the overrun and the property
-- would pass by construction.  So the FIFO here NEVER backpressures -- `rready`
-- is tied high -- and the modelled occupancy is asserted never to exceed DEPTH.
-- If the throttle is wrong, the level goes over and the bench says by how much.
--
-- WHAT ELSE IS CHECKED, each against an independently maintained model
-- ---------------------------------------------------------------------------
--   * ADDRESS TILING.  Every accepted AR must carry exactly the next address
--     in sequence and exactly min(beats left, MAXB) beats, so the bursts of a
--     job tile [base, base + n_beats*BYTES) with no gap, no overlap and no
--     short final burst.  A job ends only when the LAST beat has been asked
--     for, and the bench checks the total independently.
--   * arlen is the beat count MINUS ONE, decoded back and compared, which is
--     the one field an off-by-one makes look almost right.
--   * AXI HANDSHAKE RULES: `arvalid` once raised is held until `arready`, and
--     `araddr` / `arlen` do not move while it is high.
--   * OUTSTANDING BURSTS never exceed MAXOUT.
--   * THE FOUR-PHASE CLEAR, as an ORDERED sequence.  After a `start` the bench
--     requires, in this order and no other: every outstanding burst retires,
--     `arvalid` is low, `clr` rises, `clr_done` rises, `clr` falls, `clr_done`
--     falls, and only then `run` rises.  Out-of-order events are named
--     individually.
--   * NO AR IS ISSUED WHILE `run` IS LOW, which is what makes the drain a
--     drain rather than a pause.
--   * A `start` DURING the clear is legal and restarts the whole sequence.
--
-- TWO INSTANCES, and the difference is the clear acknowledgement latency:
-- ACK_LAT = 1 is the single-clock configuration rtl/axi_rd_port.vhd builds
-- (its `ackp` process is one flop), ACK_LAT = 7 stands in for the CDC, where
-- the acknowledgement takes however long the synchronisers take.  The FSM is
-- meant to be configuration-blind -- its own comment says waiting for the ACK
-- rather than for a fixed number of cycles is what makes it so -- and two
-- latencies is the cheapest way to say whether that is true.
--
-- Teeth: sim/mutate_axi_rd_fsm.sh.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fsm_case is
  generic(
    NAME    : string   := "case";
    ADDR_W  : positive := 32;
    BYTES   : positive := 16;
    DEPTH   : positive := 64;
    MAXB    : positive := 16;
    MAXOUT  : positive := 4;
    LVL_MARGIN : natural := 3;
    ACK_LAT : positive := 1;
    SEED    : positive := 1;
    -- AR-accept and R-return stall density, 0 = never stall
    STALL   : natural  := 3
  );
  port(done : out boolean := false; errs : out integer := 0);
end entity;

architecture beh of fsm_case is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal start   : std_logic := '0';
  signal base    : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal n_beats : integer := 0;

  signal arvalid, arready : std_logic := '0';
  signal araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);

  signal beat, rlast : std_logic := '0';
  signal f_level : integer range 0 to 2*DEPTH + LVL_MARGIN := LVL_MARGIN;
  signal clr, clr_done : std_logic := '0';
  signal run : std_logic;

  -- ------------------------------------------------------------- the models
  signal level    : integer := 0;      -- modelled FIFO occupancy, NO backpressure
  signal max_lvl  : integer := 0;
  signal outst    : integer := 0;      -- bursts accepted by the slave, not retired
  signal max_out  : integer := 0;
  signal pop_dens : integer range 0 to 16 := 8;
  -- When true the slave refuses to accept ANY AR.  It exists for one case:
  -- an AR still asserted with every burst already retired, which is the only
  -- state in which the drain's `arv = '0'` term is distinguishable from its
  -- `os = 0` term.  Without it, mutation D2 survives.
  signal ar_slow : boolean := false;
  signal saw_pend_ar : boolean := false;

  -- Expectation for the job currently being ISSUED.  It is owned ENTIRELY by
  -- the monitor; the driver hands over a job through jbase/jbeats/jarm and
  -- never touches the running expectation, because two processes assigning one
  -- unresolved signal is an elaboration error, not a race that shows up later.
  signal exp_addr : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal exp_left : integer := 0;
  signal exp_arm  : boolean := false;   -- an expectation is loaded
  signal nreq     : integer := 0;       -- beats requested for this job
  signal jbase    : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal jbeats   : integer := 0;
  signal jarm     : std_logic := '0';

  signal nerr : integer := 0;   -- FIFO overrun (the fifo model)
  signal nmon : integer := 0;   -- AXI / address / MAXOUT (the monitor)
  signal ncov : integer := 0;   -- coverage and completion (the driver)

  -- clear-sequence observer
  type ph_t is (P_IDLE, P_DRAIN, P_CLR, P_ACK, P_DROP, P_DONE);
  signal ph : ph_t := P_IDLE;
  signal nseq : integer := 0;
  signal nclr_seen : integer := 0;
  signal seen_start : boolean := false;
begin
  clkgen : process
  begin
    while running loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.axi_rd_fsm
    generic map(ADDR_W => ADDR_W, BYTES => BYTES, DEPTH => DEPTH,
                MAXB => MAXB, MAXOUT => MAXOUT, LVL_MARGIN => LVL_MARGIN)
    port map(clk => clk, rst => rst, start => start, base => base,
             n_beats => n_beats,
             arvalid => arvalid, arready => arready,
             araddr => araddr, arlen => arlen,
             beat => beat, rlast => rlast,
             f_level => f_level, clr => clr, clr_done => clr_done,
             run => run);

  -- =================================================== the clear acknowledger
  -- ACK_LAT flops each way, which is rtl/axi_rd_port.vhd's `ackp` at 1 and a
  -- stand-in for the CDC at 7.
  ackp : process(clk)
    variable sr : std_logic_vector(15 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sr := (others => '0'); clr_done <= '0';
      else
        sr := sr(14 downto 0) & clr;
        clr_done <= sr(ACK_LAT-1);
      end if;
    end if;
  end process;

  -- ======================================================= behavioural slave
  -- Accepts AR after a random delay, then returns that many beats, also with
  -- random gaps.  `rready` is TIED HIGH: see the header -- a modelled FIFO
  -- that backpressures makes the throttle property untestable.
  slave : process(clk)
    type q_t is array(0 to 63) of integer;
    variable qlen : q_t := (others => 0);
    variable qh, qt, qn : integer := 0;
    variable pend : integer := 0;        -- beats left in the burst being returned
    variable lf : unsigned(15 downto 0) := to_unsigned((SEED*7919+3) mod 65536, 16);
    variable la : unsigned(15 downto 0) := to_unsigned((SEED*104729+5) mod 65536, 16);
    variable o : integer;
  begin
    if rising_edge(clk) then
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      la := la(14 downto 0) & (la(15) xor la(13) xor la(12) xor la(10));
      beat <= '0'; rlast <= '0';
      if rst = '1' then
        arready <= '0'; qh := 0; qt := 0; qn := 0; pend := 0; outst <= 0;
      else
        o := outst;
        -- ---- AR accept
        arready <= '0';
        if arvalid = '1' and arready = '0' and qn < 60 and not ar_slow
           and (STALL = 0 or to_integer(la(3 downto 0)) >= STALL) then
          arready <= '1';
          qlen(qt) := to_integer(unsigned(arlen)) + 1;
          qt := (qt + 1) mod 64; qn := qn + 1;
          o := o + 1;
        end if;
        -- ---- R return
        if pend = 0 and qn > 0 then
          pend := qlen(qh); qh := (qh + 1) mod 64; qn := qn - 1;
        end if;
        if pend > 0 and (STALL = 0 or to_integer(lf(3 downto 0)) >= STALL) then
          beat <= '1';
          if pend = 1 then rlast <= '1'; o := o - 1; end if;
          pend := pend - 1;
        end if;
        outst <= o;
        if o > max_out then max_out <= o; end if;
      end if;
    end if;
  end process;

  -- ==================================== the modelled FIFO, WITHOUT backpressure
  fifo : process(clk)
    variable lv : integer;
    variable lf : unsigned(15 downto 0) := to_unsigned((SEED*31337+11) mod 65536, 16);
  begin
    if rising_edge(clk) then
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
      if rst = '1' then
        level <= 0;
      else
        lv := level;
        if beat = '1' and run = '1' then lv := lv + 1; end if;
        if lv > 0 and to_integer(lf(3 downto 0)) < pop_dens then lv := lv - 1; end if;
        if lv > max_lvl then max_lvl <= lv; end if;
        if lv > DEPTH then
          if nerr < 6 then
            report NAME & ": THE AR THROTTLE OVERRAN THE FIFO -- occupancy " &
                   integer'image(lv) & " with DEPTH " & integer'image(DEPTH)
              severity error;
          end if;
          nerr <= nerr + 1;
        end if;
        level <= lv;
      end if;
    end if;
  end process;
  -- Clamped only so that a mutation that overruns produces a NAMED diagnostic
  -- from the checker above rather than a range error on this port.
  f_level <= (level + LVL_MARGIN) when level <= 2*DEPTH
             else 2*DEPTH + LVL_MARGIN;

  -- ============================================================== the monitor
  mon : process(clk)
    variable av_p : std_logic := '0';
    variable ad_p : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
    variable ln_p : std_logic_vector(7 downto 0) := (others => '0');
    variable ar_p : std_logic := '0';
    variable want : integer;
    procedure bad(msg : string) is
    begin
      if nmon < 12 then report NAME & ": " & msg severity error; end if;
      nmon <= nmon + 1;
    end procedure;
  begin
    if rising_edge(clk) then
      -- The driver hands a job over here, and it holds `jarm` only around the
      -- `start` pulse -- no AR can be issued until `run` rises, which is many
      -- cycles later, so reloading repeatedly for those few cycles is safe.
      if jarm = '1' then
        exp_addr <= jbase; exp_left <= jbeats; nreq <= 0; exp_arm <= true;
      end if;
      if rst = '0' then
        -- ---- AXI handshake stability -------------------------------------
        -- `ar_p` is load bearing in BOTH of these.  The transfer happens at
        -- the edge where arvalid and arready are BOTH high, so at the NEXT
        -- edge arvalid is legitimately low and the address legitimately new.
        -- Comparing against arready sampled at the CURRENT edge instead --
        -- which is what the first version of this file did -- reports every
        -- single completed AR as an AXI rule violation.  Trap 6.6.
        if av_p = '1' and ar_p = '0' and arvalid = '1' then
          if ad_p /= araddr then bad("araddr MOVED while arvalid was high"); end if;
          if ln_p /= arlen  then bad("arlen MOVED while arvalid was high");  end if;
        end if;
        if av_p = '1' and ar_p = '0' and arvalid = '0' then
          bad("arvalid was WITHDRAWN without arready -- an AXI rule violation");
        end if;

        -- ---- an AR RAISED while the port is not running -------------------
        -- Being ACCEPTED while `run` is low is LEGAL and expected: AXI forbids
        -- withdrawing an asserted arvalid, so an AR outstanding when a `start`
        -- arrives is allowed to complete and is drained.  The FSM's own S_DRAIN
        -- comment says exactly that.  What is forbidden is RAISING a new one,
        -- and the first version of this bench checked the wrong one of the two
        -- -- it never fired only because no stimulus had an AR pending at a
        -- start, and it fired five times per instance the moment one did.
        -- Trap 6.7.
        if av_p = '0' and arvalid = '1' and run = '0' then
          bad("arvalid was RAISED while run was low");
        end if;

        -- ---- an accepted AR ----------------------------------------------
        -- Judged against the expectation ONLY when the port is running: an AR
        -- accepted during a drain belongs to the ABANDONED job and has nothing
        -- to do with the expectation just loaded for the new one.
        if arvalid = '1' and arready = '1' and run = '1' then
          if exp_arm then
            want := exp_left; if want > MAXB then want := MAXB; end if;
            if unsigned(araddr) /= exp_addr then
              bad("AR ADDRESS " & integer'image(to_integer(unsigned(araddr))) &
                  " want " & integer'image(to_integer(exp_addr)));
            end if;
            if to_integer(unsigned(arlen)) + 1 /= want then
              bad("ARLEN carries " & integer'image(to_integer(unsigned(arlen))+1) &
                  " beats, want min(left,MAXB) = " & integer'image(want));
            end if;
            exp_addr <= exp_addr + to_unsigned(want * BYTES, ADDR_W);
            exp_left <= exp_left - want;
            nreq     <= nreq + want;
          end if;
        end if;

        -- ---- MAXOUT ------------------------------------------------------
        if outst > MAXOUT then
          bad("OUTSTANDING BURSTS " & integer'image(outst) & " exceeds MAXOUT " &
              integer'image(MAXOUT));
        end if;

        av_p := arvalid; ad_p := araddr; ln_p := arlen; ar_p := arready;
      else
        av_p := '0'; ar_p := '0';
      end if;
    end if;
  end process;

  -- ================================== the four-phase clear, as an ORDERED seq
  -- Every transition is checked for ORDER, not merely for occurrence.  An
  -- acknowledgement that arrives before the request, or a `run` that rises
  -- before `clr_done` has fallen, is the exact one-beat-misalignment class the
  -- S_CLR2 state exists to prevent.
  seqp : process(clk)
    variable dn_p, clr_p, run_p : std_logic := '0';
    procedure bad(msg : string) is
    begin
      if nseq < 8 then report NAME & ": " & msg severity error; end if;
      nseq <= nseq + 1;
    end procedure;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph <= P_IDLE;
      else
        -- `run` MUST be low until a job has been programmed.  The FSM's reset
        -- comment says so in as many words -- it enters S_IDLE and not S_CLR
        -- precisely because entering the clear "would run the port into S_RUN
        -- before any job was programmed" -- and nothing else in this bench
        -- would notice a design that came out of reset already running.
        if not seen_start and run = '1' then
          bad("run was HIGH before any job was programmed");
        end if;
        if start = '1' then
          seen_start <= true;
          ph <= P_DRAIN;
        else
          case ph is
            when P_DRAIN =>
              if clr = '1' and clr_p = '0' then
                if outst /= 0 then
                  bad("clr ROSE with " & integer'image(outst) &
                      " bursts still outstanding -- the drain did not finish");
                end if;
                if arvalid = '1' then
                  bad("clr ROSE with arvalid still high");
                end if;
                nclr_seen <= nclr_seen + 1;
                ph <= P_CLR;
              elsif run = '1' then
                bad("run ROSE without a clear");
              end if;
            when P_CLR =>
              if clr_done = '1' and dn_p = '0' then ph <= P_ACK;
              elsif clr = '0' then
                bad("clr FELL before clr_done rose -- phase 2 was skipped");
                ph <= P_IDLE;
              end if;
            when P_ACK =>
              if clr = '0' then ph <= P_DROP;
              elsif run = '1' then
                bad("run ROSE while clr was still high");
              end if;
            when P_DROP =>
              if clr_done = '0' then ph <= P_DONE;
              elsif run = '1' then
                bad("run ROSE before clr_done FELL -- the read side may still " &
                    "be parked, which is what S_CLR2 exists to prevent");
              end if;
            when others => null;
          end case;
        end if;
        dn_p := clr_done; clr_p := clr; run_p := run;
      end if;
    end if;
  end process;

  -- ================================================================== driver
  drv : process
    variable t0 : time;

    procedure arm_job(constant b : integer; constant nb : integer;
                      constant pd : integer) is
    begin
      pop_dens <= pd;
      base    <= std_logic_vector(to_unsigned(b, ADDR_W));
      n_beats <= nb;
      jbase   <= to_unsigned(b, ADDR_W);
      jbeats  <= nb;
      jarm    <= '1';
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      wait until rising_edge(clk);
      jarm  <= '0';
    end procedure;

    procedure wait_job(constant nb : integer; constant tag : string) is
    begin
      t0 := now;
      while nreq < nb loop
        wait until rising_edge(clk);
        if now - t0 > (nb + 512) * 400 * 10 ns then
          report NAME & ": " & tag & " STALLED -- " & integer'image(nreq) &
                 " of " & integer'image(nb) & " beats requested" severity error;
          ncov <= ncov + 1;
          exit;
        end if;
      end loop;
      -- and nothing more may be asked for once the job is complete
      for i in 0 to 63 loop wait until rising_edge(clk); end loop;
      if nreq /= nb then
        report NAME & ": " & tag & " REQUESTED " & integer'image(nreq) &
               " beats, the job was " & integer'image(nb) severity error;
        ncov <= ncov + 1;
      end if;
    end procedure;

    procedure run_job(constant b : integer; constant nb : integer;
                      constant pd : integer; constant consume_all : boolean;
                      constant tag : string) is
    begin
      arm_job(b, nb, pd);
      if consume_all then wait_job(nb, tag); end if;
    end procedure;
  begin
    rst <= '1';
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    wait until rising_edge(clk); rst <= '0';
    for i in 0 to 3 loop wait until rising_edge(clk); end loop;

    -- J1: many bursts, SLOW consumer, so the FIFO-space throttle is the limit
    run_job(16#00001000#, 8*MAXB + 5, 1, true, "J1 slow consumer");
    -- J2: many bursts, FAST consumer, so MAXOUT is the limit instead
    run_job(16#00040000#, 12*MAXB, 16, true, "J2 fast consumer");
    -- J3: exactly one full burst
    run_job(16#00080000#, MAXB, 8, true, "J3 one burst");
    -- J4: a SINGLE beat -- arlen = 0, the value to_unsigned(-1) would trap on
    run_job(16#000C0000#, 1, 8, true, "J4 single beat");
    -- J5: one beat more than a whole burst, so the last burst is short
    run_job(16#00100000#, MAXB + 1, 8, true, "J5 ragged last burst");
    -- J6: ABANDONED part way, then J7 must start at its own base.  This is
    -- the case 7.7's flush rule exists for.
    run_job(16#00200000#, 40*MAXB, 4, false, "J6 abandoned");
    for i in 0 to 200 loop wait until rising_edge(clk); end loop;
    run_job(16#00300000#, 6*MAXB, 8, true, "J7 after abandon");

    -- J9/J10: a `start` while an AR is STILL ASSERTED and every burst has
    -- already retired.  This is the ONLY state in which the drain's two exit
    -- terms can be told apart: with `os = 0` alone the port would raise `clr`
    -- with an AR still on the wire, and AXI forbids withdrawing it, so that
    -- burst returns AFTER the flush and lands looking like the new job's first
    -- beats -- the exact misalignment 7.7's flush rule exists to prevent.
    -- Without this phase mutation D2 SURVIVES (MEASURED).
    arm_job(16#00600000#, 8*MAXB, 8);
    t0 := now;
    while nreq < 2*MAXB loop
      wait until rising_edge(clk);
      exit when now - t0 > 40000 * 10 ns;
    end loop;
    ar_slow <= true;            -- the slave stops accepting AR
    t0 := now;
    while not (arvalid = '1' and outst = 0) loop
      wait until rising_edge(clk);
      exit when now - t0 > 40000 * 10 ns;
    end loop;
    if arvalid = '1' and outst = 0 then saw_pend_ar <= true; end if;
    arm_job(16#00700000#, 4*MAXB, 8);
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    ar_slow <= false;           -- let the pending AR complete so the drain can
    wait_job(4*MAXB, "J10 start with an AR still pending");

    -- J8: a start DURING the clear of another start.  The FSM restarts the
    -- whole four-phase sequence from S_DRAIN; a design that latched the clear
    -- would hang here.
    pop_dens <= 8;
    base <= std_logic_vector(to_unsigned(16#00400000#, ADDR_W));
    n_beats <= 5*MAXB;
    jbase <= to_unsigned(16#00400000#, ADDR_W); jbeats <= 5*MAXB; jarm <= '1';
    wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until rising_edge(clk); jarm <= '0';
    t0 := now;
    while clr = '0' loop
      wait until rising_edge(clk);
      exit when now - t0 > 20000 * 10 ns;
    end loop;
    run_job(16#00500000#, 5*MAXB, 8, true, "J8 restart during the clear");

    for i in 0 to 63 loop wait until rising_edge(clk); end loop;

    -- ---- COVERAGE, asserted rather than printed -------------------------
    if nclr_seen < 11 then
      report NAME & ": COVERAGE -- only " & integer'image(nclr_seen) &
             " clears were observed, expected 11" severity error;
      ncov <= ncov + 1;
    end if;
    if not saw_pend_ar then
      report NAME & ": COVERAGE -- the stimulus never reached `an AR still " &
             "asserted with nothing outstanding`, so the drain's arv term " &
             "was never under test" severity error;
      ncov <= ncov + 1;
    end if;
    -- WHICH LIMIT BINDS IS A PROPERTY OF THE GENERICS, not of the stimulus,
    -- and asserting the wrong one is how a coverage check becomes noise.
    -- rtl/axi_rd_port.vhd's own MAXOUT comment states the boundary: the AR
    -- throttle is against FIFO FREE SPACE including beats already requested,
    -- so MAXOUT "simply stops being reachable once MAXOUT*MAXB > DEPTH, at
    -- which point DEPTH is the limit and MAXOUT is inert".  Each instance
    -- therefore asserts the limit that CAN bind for it, and the two instances
    -- are chosen so that between them both limits are covered.
    if MAXOUT * MAXB > DEPTH then
      if max_lvl < DEPTH - MAXB then
        report NAME & ": COVERAGE -- the modelled FIFO peaked at " &
               integer'image(max_lvl) & " of " & integer'image(DEPTH) &
               ", so the FIFO-space throttle was never the binding limit"
          severity error;
        ncov <= ncov + 1;
      end if;
    else
      if max_out /= MAXOUT then
        report NAME & ": COVERAGE -- outstanding bursts peaked at " &
               integer'image(max_out) & ", so MAXOUT (" &
               integer'image(MAXOUT) & ") was never the binding limit"
          severity error;
        ncov <= ncov + 1;
      end if;
    end if;

    wait until rising_edge(clk);
    report NAME & ": clears=" & integer'image(nclr_seen) &
           " maxout=" & integer'image(max_out) & "/" & integer'image(MAXOUT) &
           " maxlvl=" & integer'image(max_lvl) & "/" & integer'image(DEPTH) &
           " err=" & integer'image(nerr + nmon + nseq + ncov) severity note;
    errs <= nerr + nmon + nseq + ncov;
    done <= true;
    running <= false;
    wait;
  end process;
end architecture;

-- ===========================================================================
library ieee;
use ieee.std_logic_1164.all;

entity tb_axi_rd_fsm is
end entity;

architecture sim of tb_axi_rd_fsm is
  signal d0, d1 : boolean;
  signal e0, e1 : integer;
begin
  -- ACK_LAT = 1: rtl/axi_rd_port.vhd's SINGLE-CLOCK configuration, whose
  -- `ackp` process is exactly one flop.  MAXOUT*MAXB = 256 against DEPTH = 64,
  -- so here the FIFO-SPACE throttle is the binding limit and MAXOUT is inert.
  c0 : entity work.fsm_case
    generic map(NAME => "ack1", ACK_LAT => 1, MAXOUT => 16, DEPTH => 64,
                MAXB => 16, SEED => 1, STALL => 3)
    port map(done => d0, errs => e0);

  -- ACK_LAT = 7 stands in for the CDC, where the acknowledgement takes as long
  -- as the synchronisers do.  The FSM is meant to be configuration-blind.
  -- MAXOUT = 16 and DEPTH = 512 are the FK33 values from
  -- rtl/axi_rd_port.vhd's generic defaults, and at those MAXOUT*MAXB = 256 is
  -- BELOW DEPTH, so here MAXOUT is the binding limit and the FIFO-space
  -- throttle is inert.  That is the whole reason for running two instances:
  -- between them each of the two limits is the one under test somewhere.
  c1 : entity work.fsm_case
    generic map(NAME => "ack7", ACK_LAT => 7, MAXOUT => 16, DEPTH => 512,
                MAXB => 16, SEED => 2, STALL => 5)
    port map(done => d1, errs => e1);

  fin : process
  begin
    wait until d0 and d1;
    wait for 1 ns;
    report "axi_rd_fsm: " & integer'image(e0 + e1) &
           " errors across 2 acknowledgement latencies" severity note;
    assert e0 + e1 = 0
      report "axi_rd_fsm FAILED: see the per-case diagnostics above"
      severity failure;
    report "PASS: tb_axi_rd_fsm" severity note;
    std.env.stop;
  end process;
end architecture;
