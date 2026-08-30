-- sim/tb_axi_rd_port_dual.vhd -- a direct bench for rtl/axi_rd_port.vhd's DUAL_CLOCK
-- generate: the `start` toggle synchroniser, the `run` level crossing back to
-- the core domain, and the `rst` synchroniser.
--
-- WHY THIS EXISTS.  docs/debugging/2026-08-29_cdc-and-fifo-coverage.md closed
-- rtl/async_fifo.vhd and rtl/axi_rd_fsm.vhd and then named this file as the
-- next thing with no coverage at all:
--
--   > rtl/axi_rd_port.vhd itself at DUAL_CLK = true.  This track benched the
--   > two units the port instantiates, not the port's own dual-clock generate:
--   > the `start` toggle synchroniser, the `run` level crossing back to the
--   > core domain, and the `rst` synchroniser are still covered only by
--   > sim/tb_matvec_fk33_desc.vhd at DUAL = true, which is a MANUAL run and not
--   > a gate row.  That is the obvious next item and it is not closed here.
--
-- Every gate row that instantiates axi_rd_port does so at DUAL_CLK = false, so
-- the `g_dc` generate has never been elaborated on a gate run.  This bench is
-- the DUAL_CLK = true one, and it is a SEPARATE FILE from sim/tb_axi_rd_port
-- rather than a generic on it: sim/regress.sh keys a test by name and cannot
-- run one testbench twice, which is the same reason sim/tb_matvec_fk33_desc's
-- own `-gDUAL=true` configuration is a manual run and not a gate row.  Making
-- the DUAL case a generic here would have meant choosing which of the two
-- configurations the gate covers.
--
-- ---------------------------------------------------------------------------
-- WHAT IS CHECKED, AND WHAT DELIBERATELY IS NOT
-- ---------------------------------------------------------------------------
-- Three clock ratios, run concurrently:
--
--   afast   aclk 3.0 ns against clk 4.0 ns -- the FK33's own direction, where
--           the whole 259.2 GB/s supply figure comes from the AXI side being
--           FASTER than the core
--   aslow   aclk 5.0 ns against clk 3.0 ns -- the other direction, so a
--           check that only works when the producer outruns the consumer is
--           not mistaken for a general one
--   anear   3.000 ns against 3.001 ns -- the phase sweeps through every
--           alignment over the run, which is the only way a fixed-offset bench
--           reaches the coincident-edge case as well as every other
--
-- Per instance, in order:
--
--   * a VALUE AND ORDER oracle.  The modelled slave returns the WORD INDEX of
--     the address it was asked for, so a beat carries its own address and a
--     drop, a duplicate, a reorder and a wrong-address burst are four distinct
--     diagnostics rather than one "mismatch".
--   * every job delivers EXACTLY n_beats and no more.
--   * the `start` toggle is exercised at both extremes: two jobs back to back
--     with a single idle core cycle between them (a toggle that was read as a
--     LEVEL sees one long start; a toggle whose synchroniser is too shallow
--     misses the second), and a job started while the previous one is still
--     streaming.
--   * THE ABANDON, twice, two different ways, because the two ways catch
--     different mutations:
--       - with the consumer's q_ready held LOW across the start, so that the
--         FIFO still holds the old job's beats when the flush runs.  The first
--         beat consumed after q_ready returns MUST be the new job's word 0.
--         This is the property 7.7's flush rule exists for.
--       - with the consumer's q_ready held HIGH across the start, so residue
--         is free to flow.  The `run_c` gate is what bounds it, and the bound
--         is asserted.  Held low, this case cannot exist at all, which is why
--         both are run.
--   * a reset in mid-flight, then a further job, so the rst synchroniser is on
--     a path the value oracle covers.
--   * COVERAGE ASSERTED, NOT PRINTED.  A run in which the FIFO never made the
--     consumer wait, or in which the full-rate abandon found NO residue
--     resident, FAILS -- in the second case the abandon test would have been
--     passing vacuously.
--
-- NOT CHECKED, and it cannot be: metastability, and therefore the reason the
-- 2FF synchronisers exist at all.  sim/mutate_axi_rd_port_dual.sh's P4/P8/PA rows
-- cut a synchroniser to one flop and SURVIVE, exactly as G3/G4/C6 do on
-- async_fifo.  That is the resolution floor of RTL simulation, not a gap in
-- this bench; sim/cdc_teeth.sh is the flow that reaches it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_rd_port_dual is end entity;

architecture sim of tb_axi_rd_port_dual is

  constant NC     : natural  := 4;
  constant AXI_DW : positive := 32;
  constant ADDR_W : positive := 32;
  constant BYTES  : positive := AXI_DW / 8;
  constant DEPTH  : positive := 16;    -- power of two: async_fifo requires it
  constant MAXB   : positive := 8;
  constant MAXOUT : positive := 4;

  type tarr is array(0 to NC-1) of time;
  --                afast     aslow     anear     awild
  constant CPER : tarr := (4.0 ns, 3.0 ns, 3.000 ns, 10.0 ns);  -- core clock
  constant APER : tarr := (3.0 ns, 5.0 ns, 3.001 ns,  0.5 ns);  -- AXI clock

  type namearr is array(0 to NC-1) of string(1 to 5);
  constant NAMES : namearr := ("afast", "aslow", "anear", "awild");

  type iarr is array(0 to NC-1) of integer;
  signal errs    : iarr := (others => 0);
  signal ndone   : iarr := (others => 0);
  signal nbeats  : iarr := (others => 0);
  signal nstall  : iarr := (others => 0);   -- consumer waited on q_valid
  signal nres    : iarr := (others => 0);   -- residue beats, full-rate abandon
  signal nrqv    : std_logic_vector(0 to NC-1) := (others => '0');
  signal fin     : std_logic_vector(0 to NC-1) := (others => '0');

  -- The residue bound.  TIGHTENED FROM 8 TO 1 on 2026-08-29 by TRACK A7,
  -- together with the core-domain close in rtl/axi_rd_port.vhd's `g_dc`.
  --
  -- The OLD derivation was correct for the OLD RTL and is kept here because it
  -- is what the number 8 meant: after a core-domain `start` the toggle needed
  -- up to 3 aclk edges to become `start_f`, the FSM left S_RUN on the next aclk
  -- edge, and `run_c` fell 2 clk edges after that, so roughly five core cycles
  -- of an abandoned job's residue could legally reach the consumer.  MEASURED
  -- at 0d14a70: 2 beats at afast, 3 at anear, 4 at aslow.
  --
  -- `abort_c` closes the gate on the core clock instead, so the ONLY beat that
  -- can still be delivered is the one whose handshake completes on the very
  -- edge that samples `start` -- hence 1, and hence a bound with almost no
  -- slack left in it, which is the point.  Row PK of
  -- sim/mutate_axi_rd_port_dual.sh removes the close and is killed here.
  --
  -- Ungating q_valid (row P7) lets the consumer keep re-reading the same
  -- residue word until the flush lands, which is what that row is now caught
  -- by.
  constant RES_MAX : integer := 1;

begin

  g : for i in 0 to NC-1 generate
    signal clk, aclk : std_logic := '0';
    signal rst       : std_logic := '1';
    signal go        : std_logic := '0';

    signal start   : std_logic := '0';
    signal base    : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
    signal n_beats : integer := 0;

    signal arvalid, arready, rvalid, rready, rlast : std_logic := '0';
    signal araddr : std_logic_vector(ADDR_W-1 downto 0);
    signal arlen  : std_logic_vector(7 downto 0);
    signal arsize : std_logic_vector(2 downto 0);
    signal arburst: std_logic_vector(1 downto 0);
    signal rdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

    signal q_valid, q_ready : std_logic := '0';
    signal q_data : std_logic_vector(AXI_DW-1 downto 0);

    -- Consumer control.  EVERY expectation lives in the consumer process as a
    -- VARIABLE and is loaded through a one-cycle `ld` handshake, because a
    -- signal written by both the sequencer and the consumer is two sources on
    -- an unresolved signal and GHDL refuses to elaborate it.  The consumer
    -- publishes what the sequencer needs to read back.
    signal cons_en   : std_logic := '0';   -- consumer may assert q_ready
    signal strict    : std_logic := '0';   -- '1' => the next beat MUST be exp_word
    signal ld        : std_logic := '0';   -- one-cycle load of the expectation
    signal ld_word   : integer := 0;
    signal ld_left   : integer := 0;
    signal res_arm   : std_logic := '0';   -- one-cycle arm of the residue window
    signal slow      : std_logic := '0';   -- consumer takes 1 beat in 8
    signal exp_left_o: integer := 0;       -- published: beats still owed
    signal res_cnt_o : integer := 0;       -- published: residue beats counted
    signal res_qv_o  : std_logic := '0';   -- published: FIFO offering at the abandon
    signal err_i     : integer := 0;       -- consumer's own errors
    signal err_s     : integer := 0;       -- sequencer's own errors
    signal stall_i   : integer := 0;
    signal bp_i      : integer := 0;       -- cycles the FIFO held data the consumer refused
    signal nrf_i     : integer := 0;       -- cycles the port REFUSED an offered R beat
    signal beats_i   : integer := 0;
  begin
    clk  <= not clk  after CPER(i)/2 when go = '1' else '0';
    aclk <= not aclk after APER(i)/2 when go = '1' else '0';

    dut : entity work.axi_rd_port
      generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                  MAXB => MAXB, MAXOUT => MAXOUT, DUAL_CLK => true)
      port map(clk => clk, rst => rst, aclk => aclk,
               start => start, base => base, n_beats => n_beats,
               arvalid => arvalid, arready => arready, araddr => araddr,
               arlen => arlen, arsize => arsize, arburst => arburst,
               rvalid => rvalid, rready => rready, rdata => rdata,
               rlast => rlast,
               q_valid => q_valid, q_data => q_data, q_ready => q_ready);

    -- ================================================== modelled AXI slave
    -- Returns the WORD INDEX of the address it was asked for, so every beat
    -- carries its own address.  A wrong-address burst is then a value error
    -- rather than something only an address-channel checker could see.
    --
    -- The AR queue is deliberately DEEPER than MAXOUT so the slave never
    -- backpressures the AR channel for a conforming port: if it did, an
    -- outstanding-burst defect would be absorbed by the model instead of
    -- showing up.  arready is stalled on a fixed pattern so the accept latency
    -- varies, which is what makes the S_DRAIN "an asserted AR must complete"
    -- path reachable.
    slave : process(aclk)
      constant QN : integer := 16;
      type qi is array(0 to QN-1) of integer;
      variable qa   : qi := (others => 0);   -- first word index of the burst
      variable ql   : qi := (others => 0);   -- beats in the burst
      variable qw   : integer := 0;
      variable qr   : integer := 0;
      variable qc   : integer := 0;          -- entries queued
      variable cidx : integer := 0;          -- current beat's word index
      variable cleft: integer := 0;
      variable busy : boolean := false;
      variable ph   : integer := 0;          -- stall phase
    begin
      if rising_edge(aclk) then
        ph := (ph + 1) mod 7;

        -- AR: accept when the queue has room and the stall pattern allows
        if arready = '1' and arvalid = '1' then
          qa(qw) := to_integer(unsigned(araddr)) / BYTES;
          ql(qw) := to_integer(unsigned(arlen)) + 1;
          qw := (qw + 1) mod QN;
          qc := qc + 1;
        end if;
        if qc < QN-1 and ph /= 3 then arready <= '1'; else arready <= '0'; end if;

        -- R: one beat per cycle when the current beat has been taken
        if rvalid = '0' or rready = '1' then
          if not busy and qc > 0 then
            cidx  := qa(qr);
            cleft := ql(qr);
            qr    := (qr + 1) mod QN;
            qc    := qc - 1;
            busy  := true;
          end if;
          if busy and ph /= 5 then
            rdata  <= std_logic_vector(to_unsigned(cidx, AXI_DW));
            rvalid <= '1';
            if cleft = 1 then rlast <= '1'; busy := false;
            else rlast <= '0'; end if;
            cidx  := cidx + 1;
            cleft := cleft - 1;
          else
            rvalid <= '0';
            rlast  <= '0';
          end if;
        end if;

        if rst = '1' then
          rvalid <= '0'; rlast <= '0';
          qw := 0; qr := 0; qc := 0; busy := false;
        end if;
      end if;
    end process;

    -- ==================================================== R-channel refusals
    -- MEASURED, not argued.  rtl/async_fifo.vhd's header claims the AR
    -- throttle "exists precisely so the FIFO never reaches DEPTH", and
    -- rtl/axi_rd_fsm.vhd's claims "an accepted burst can never overrun the
    -- FIFO".  If both hold then `rready` NEVER goes low while a beat is being
    -- offered, and this counter is 0 for the whole run.  That single number is
    -- what explains five survivors in sim/mutate_axi_rd_port_dual.sh -- PC, PD, PE,
    -- PG and the PP pair all change behaviour ONLY on a cycle where the port
    -- refuses a beat, so on a conforming design they are true equivalents
    -- rather than mutations this bench is too weak to see.
    rfmon : process(aclk)
      variable nrf : integer := 0;
    begin
      if rising_edge(aclk) then
        if rst = '0' and rvalid = '1' and rready = '0' then nrf := nrf + 1; end if;
        nrf_i <= nrf;
      end if;
    end process;

    -- ==================================================== the consumer
    -- q_ready is the sequencer's `cons_en` gated by a stall pattern, so the
    -- FIFO is made to fill rather than being drained the instant a beat lands.
    cons : process(clk)
      variable ph : integer := 0;
      variable w  : integer;
      variable exp_word : integer := 0;
      variable exp_left : integer := 0;
      variable res_open : boolean := false;
      variable res_cnt  : integer := 0;
      -- NON-VACUITY WITNESS.  With the gate closing on the core clock the
      -- honest residue count is 0 or 1, so "res_cnt > 0" can no longer serve as
      -- proof that the FIFO actually held an abandoned job's beats -- and a
      -- residue bound measured against an EMPTY FIFO passes vacuously, which
      -- is a mistake this bench has already made once (see J5/J6 below).  What
      -- is recorded instead is whether the port was OFFERING a beat on the edge
      -- the abandon was armed.  That is the same fact, taken one step earlier,
      -- and it does not move when the gate is tightened.
      variable res_qv   : std_logic := '0';
      variable err      : integer := 0;
      variable stall    : integer := 0;
      variable bp       : integer := 0;
      variable beats    : integer := 0;
    begin
      if rising_edge(clk) then
        ph := (ph + 1) mod 8;
        q_ready <= '0';
        if cons_en = '1' then
          if slow = '1' then
            -- ONE BEAT IN EIGHT.  This duty is not decoration: it is the only
            -- state in which the FIFO is FULL while beats are still arriving,
            -- and three mutations are invisible outside it -- PE (a promise
            -- retired by an OFFERED beat rather than an ACCEPTED one) and PG
            -- (the FIFO's OUT_MARGIN and the FSM's disagreeing) both need
            -- `rready` to actually go low, which only happens when the FIFO is
            -- the limit.  MEASURED: with the consumer at 7-in-8 the FIFO is
            -- EMPTY-limited at every ratio here and both mutations survive.
            if ph = 0 then q_ready <= '1'; end if;
          elsif ph /= 2 then
            q_ready <= '1';
          end if;
        end if;

        if ld = '1' then
          exp_word := ld_word;
          exp_left := ld_left;
        end if;
        if res_arm = '1' then
          res_open := true;
          res_cnt  := 0;
          res_qv   := q_valid;
        end if;

        if rst = '0' and q_valid = '1' and q_ready = '1' then
          w := to_integer(unsigned(q_data));
          beats := beats + 1;
          if res_open then
            -- The full-rate abandon window.  Anything from the OLD job is
            -- residue and is counted; the first NEW-job beat closes it.
            if w = exp_word then
              res_open := false;
              exp_word := exp_word + 1;
              exp_left := exp_left - 1;
            else
              res_cnt := res_cnt + 1;
            end if;
          elsif strict = '1' then
            if exp_left <= 0 then
              report NAMES(i) & ": A BEAT ARRIVED AFTER THE JOB WAS COMPLETE" &
                     " -- the port delivered more than n_beats"
                severity error;
              err := err + 1;
            elsif w /= exp_word then
              report NAMES(i) & ": BEAT got " & integer'image(w) &
                     " want " & integer'image(exp_word) &
                     " -- a beat was DROPPED, DUPLICATED, REORDERED or came" &
                     " from the WRONG ADDRESS"
                severity error;
              err := err + 1;
              exp_word := w + 1;          -- resynchronise so one error is one line
              exp_left := exp_left - 1;
            else
              exp_word := exp_word + 1;
              exp_left := exp_left - 1;
            end if;
          else
            report NAMES(i) & ": A BEAT WAS DELIVERED WHILE NO JOB WAS RUNNING"
              severity error;
            err := err + 1;
          end if;
        end if;

        -- consumer waited: q_ready up, nothing offered.  Counted so the
        -- coverage assert can require that the FIFO was actually a limit.
        if rst = '0' and q_ready = '1' and q_valid = '0' and strict = '1' then
          stall := stall + 1;
        end if;
        -- the other direction: the FIFO had a beat and the consumer refused
        -- it.  This is the coverage proxy for "the FIFO was the limit".
        if rst = '0' and q_valid = '1' and q_ready = '0' and strict = '1' then
          bp := bp + 1;
        end if;

        exp_left_o <= exp_left;
        res_cnt_o  <= res_cnt;
        res_qv_o   <= res_qv;
        err_i      <= err;
        stall_i    <= stall;
        bp_i       <= bp;
        beats_i    <= beats;
      end if;
    end process;

    errs(i)   <= err_i + err_s;
    nbeats(i) <= beats_i;
    nstall(i) <= stall_i;
    nres(i)   <= res_cnt_o;
    nrqv(i)   <= res_qv_o;

    -- ==================================================== the sequencer
    seq : process
      -- Program, then pulse `start` for exactly one CORE cycle.  A one-cycle
      -- pulse is what the descriptor engine produces and it is the shape the
      -- toggle synchroniser exists for.
      procedure pulse_start(bw : integer; nb : integer) is
      begin
        base    <= std_logic_vector(to_unsigned(bw * BYTES, ADDR_W));
        n_beats <= nb;
        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
      end procedure;

      procedure load(bw : integer; nb : integer) is
      begin
        ld_word <= bw; ld_left <= nb;
        wait until rising_edge(clk);
        ld <= '1';
        wait until rising_edge(clk);
        ld <= '0';
      end procedure;

      procedure await_job(nb : integer; what : string) is
      begin
        for t in 0 to 40000 loop
          exit when exp_left_o <= 0;
          wait until rising_edge(clk);
        end loop;
        if exp_left_o > 0 then
          report NAMES(i) & ": " & what & " STALLED -- " &
                 integer'image(exp_left_o) & " of " & integer'image(nb) &
                 " beats never arrived"
            severity error;
          err_s <= err_s + 1;
        end if;
      end procedure;

      -- STOP READING BEFORE RELAXING THE ORACLE, NOT IN THE SAME DELTA.
      -- `q_ready` is a REGISTER inside the consumer, so it falls one core
      -- cycle after `cons_en` does; dropping `strict` at the same time let a
      -- legitimate in-flight beat land in the window where the oracle believes
      -- no job is running.  MEASURED: that produced "A BEAT WAS DELIVERED
      -- WHILE NO JOB WAS RUNNING" on CORRECT RTL at two of the three ratios.
      procedure stop_reading is
      begin
        cons_en <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        strict <= '0';
        wait until rising_edge(clk);
      end procedure;

      procedure whole_job(bw : integer; nb : integer; what : string) is
      begin
        load(bw, nb);
        pulse_start(bw, nb);
        strict  <= '1';
        cons_en <= '1';
        await_job(nb, what);
        stop_reading;
      end procedure;
    begin
      go   <= '1';
      rst  <= '1';
      for t in 0 to 9 loop wait until rising_edge(clk); end loop;
      rst <= '0';
      for t in 0 to 4 loop wait until rising_edge(clk); end loop;

      -- ---- J1: a plain job, ragged against MAXB (20 = 2*8 + 4)
      whole_job(1024, 20, "J1");

      -- ---- J2: started immediately after J1 completed.  A toggle read as a
      -- LEVEL, or a synchroniser one flop too shallow, loses this one.
      whole_job(2048, 13, "J2");

      -- ---- J3/J4: THE ABANDON, consumer HELD OFF across the start.
      -- J3 is started and allowed to fill the FIFO; the consumer never reads
      -- it.  J4 is then started on top.  The first beat the consumer ever sees
      -- must be J4's word 0 -- if the flush left residue, it sees J3's.
      load(3072, 40);
      pulse_start(3072, 40);
      cons_en <= '0';                       -- deliberately NOT reading
      for t in 0 to 199 loop wait until rising_edge(clk); end loop;
      load(4096, 25);
      pulse_start(4096, 25);
      -- long enough for the toggle, the drain, the four-phase clear and the
      -- run_c crossing, at every ratio here
      for t in 0 to 99 loop wait until rising_edge(clk); end loop;
      strict  <= '1';
      cons_en <= '1';
      await_job(25, "ABANDON/HELD-OFF J4");
      stop_reading;

      -- ---- J5/J6: THE ABANDON at FULL RATE.  The consumer keeps reading
      -- across the start, so residue is free to flow and `run_c` is the only
      -- thing bounding it.  Held off, this case cannot exist at all.
      load(5120, 400);
      pulse_start(5120, 400);
      strict <= '1'; cons_en <= '1';
      -- let the stream get going, then STOP READING so the FIFO fills.  A
      -- residue test run against an EMPTY FIFO passes vacuously, and the first
      -- version of this bench did exactly that: J5 was 60 beats, which the
      -- consumer had finished before the abandon, so `res_cnt` was 0 on
      -- correct RTL at all three ratios.  The coverage assert below is what
      -- caught it.
      for t in 0 to 119 loop wait until rising_edge(clk); end loop;
      stop_reading;
      for t in 0 to 59 loop wait until rising_edge(clk); end loop;
      -- Arm the residue window and re-open the consumer ON THE SAME EDGE the
      -- start pulse goes out, so what is counted is exactly what leaks past
      -- the gate AFTER the abandon and not what was read before it.
      load(6144, 30);
      base    <= std_logic_vector(to_unsigned(6144 * BYTES, ADDR_W));
      n_beats <= 30;
      wait until rising_edge(clk);
      start <= '1'; res_arm <= '1'; cons_en <= '1';
      wait until rising_edge(clk);
      start <= '0'; res_arm <= '0';
      strict <= '1';
      await_job(30, "ABANDON/FULL-RATE J6");
      if res_cnt_o > RES_MAX then
        report NAMES(i) & ": RESIDUE " & integer'image(res_cnt_o) &
               " beats of the ABANDONED job leaked past the run gate," &
               " bound is " & integer'image(RES_MAX)
          severity error;
        err_s <= err_s + 1;
      end if;
      stop_reading;

      -- ---- J7: reset in mid-flight, then a job across it.  The rst
      -- synchroniser is the only thing that carries the reset into the AXI
      -- domain, and it is on this path.
      load(7168, 40);
      pulse_start(7168, 40);
      strict <= '1'; cons_en <= '1';
      for t in 0 to 39 loop wait until rising_edge(clk); end loop;
      stop_reading;
      rst <= '1';
      for t in 0 to 19 loop wait until rising_edge(clk); end loop;
      rst <= '0';
      for t in 0 to 19 loop wait until rising_edge(clk); end loop;
      whole_job(8192, 17, "J8 after reset");

      -- ---- J9: a SLOW consumer, so the FIFO is FULL rather than empty and
      -- `rready` really does go low.  Everything above runs with the AXI side
      -- as the bottleneck; without this phase the FIFO is never the limit and
      -- the AR throttle's two accounting terms are never exercised against a
      -- refused beat.
      slow <= '1';
      whole_job(9216, 200, "J9 slow consumer");
      slow <= '0';

      -- ---- COVERAGE, asserted rather than printed
      if stall_i = 0 then
        report NAMES(i) & ": COVERAGE -- the consumer NEVER waited on q_valid," &
               " so no check here was ever exercised against a FIFO that was" &
               " the limit"
          severity error;
        err_s <= err_s + 1;
      end if;
      -- THE AR THROTTLE'S OWN INVARIANT, asserted rather than printed.
      -- rtl/async_fifo.vhd's header says the one-cycle stale full flag "is
      -- unreachable in any case, because the AR throttle above exists
      -- precisely so the FIFO never reaches DEPTH", and rtl/axi_rd_fsm.vhd's
      -- says "an accepted burst can never overrun the FIFO".  Both reduce to
      -- one observable statement: the port NEVER refuses a beat the slave is
      -- offering.  Outside S_RUN `rready` is forced high, and inside it the
      -- throttle is what keeps `w_ready` high, so 0 is the only correct value.
      -- TEETH: mutation PJ in sim/mutate_axi_rd_port_dual.sh tells the FSM the FIFO
      -- is always empty; the design stays functionally CORRECT because the
      -- FIFO backpressures, and this is the only check that sees it.
      if nrf_i /= 0 then
        report NAMES(i) & ": THE PORT REFUSED AN OFFERED R BEAT on " &
               integer'image(nrf_i) & " cycles -- the AR throttle did not keep" &
               " the FIFO out of its full state"
          severity error;
        err_s <= err_s + 1;
      end if;
      if bp_i < 100 then
        report NAMES(i) & ": COVERAGE -- the consumer refused an offered beat" &
               " only " & integer'image(bp_i) & " times, so the FIFO was never" &
               " sustainedly the limit and the AR throttle was not exercised" &
               " against a refused beat"
          severity error;
        err_s <= err_s + 1;
      end if;
      if res_qv_o = '0' then
        report NAMES(i) & ": COVERAGE -- the port was offering NOTHING on the" &
               " edge the full-rate abandon was armed, so the run gate's" &
               " residue bound was tested against an empty FIFO and passed" &
               " vacuously"
          severity error;
        err_s <= err_s + 1;
      end if;

      wait until rising_edge(clk);
      wait until rising_edge(clk);
      report NAMES(i) & ": beats=" & integer'image(beats_i) &
             " stall=" & integer'image(stall_i) &
             " bp=" & integer'image(bp_i) &
             " rrefuse=" & integer'image(nrf_i) &
             " residue=" & integer'image(res_cnt_o) &
             " resarm_qv=" & std_logic'image(res_qv_o) &
             " err=" & integer'image(err_i + err_s);
      fin(i) <= '1';
      go <= '0';
      wait;
    end process;

  end generate;

  verdict : process
    variable tot : integer := 0;
  begin
    wait until fin = (fin'range => '1');
    wait for 1 ns;
    for i in 0 to NC-1 loop tot := tot + errs(i); end loop;
    report "axi_rd_port_dual: " & integer'image(tot) &
           " errors across " & integer'image(NC) & " clock ratios";
    if tot = 0 then
      report "PASS: tb_axi_rd_port_dual";
    else
      report "FAIL: tb_axi_rd_port_dual" severity error;
    end if;
    wait;
  end process;

end architecture;
