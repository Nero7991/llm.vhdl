-- sim/tb_axi_rd_port_stray.vhd -- rtl/axi_rd_port.vhd at DUAL_CLK = true against
-- a slave that is DELIBERATELY NOT RESET-AWARE, with a SHORT reset asserted
-- while bursts are still outstanding.
--
-- WHY THIS EXISTS, and it is not a duplicate of sim/tb_axi_rd_port_dual.vhd.
--
-- docs/debugging/2026-08-29_a7-dual-clock-run-gate.md section 8b designed this
-- row and handed it off rather than adding it, because sim/regress.sh was held
-- by another track and a new sim/tb_*.vhd becomes a gate row whether its
-- author meant it to or not.  Its words:
--
--   > It fails at rtl/axi_rd_fsm.vhd's `outst <= os` without the clamp, so it
--   > is the row that would have caught tonight's gate failure at its own
--   > level rather than four layers up in tb_matvec_fk33_desc.
--
-- THE DEFECT IT GUARDS.  rtl/axi_rd_fsm.vhd zeroes `outst` in its reset
-- branch.  A reset CANNOT cancel an outstanding AXI read: bursts the slave has
-- already accepted keep returning beats afterwards, and each of those carries
-- an `rlast` that the FSM retires with `os := os - 1` against a count of zero.
-- In simulation `os = -1` is a bound check failure at `outst <= os`.  IN
-- SYNTHESIS THERE IS NO BOUND CHECK: `outst` is clog2(MAXOUT+2) bits, -1 wraps
-- to all-ones, the `os < MAXOUT` guard then reads FALSE, and that port issues
-- no further AR for the rest of time.  A silent, permanent hang -- not a wrong
-- number, and not something any value oracle downstream can see, because the
-- port simply stops.
--
-- On the FK33 the two resets are genuinely different nets: the weight
-- streamer's `rst` is `core_aresetn` while the HBM slave is reset by the
-- XDMA's `axi_aresetn`.  So "the slave keeps returning beats across my reset"
-- is the SHIPPING case, not a bench contrivance, and modelling a slave that
-- helpfully forgets its queue on the DUT's reset is what hides it.
--
-- ---------------------------------------------------------------------------
-- WHAT ACTUALLY MAKES THIS BENCH BITE.  MEASURED, and NOT what was predicted.
-- ---------------------------------------------------------------------------
-- Two variables were expected to be the sensitive ones and only one of them
-- is.  Both arms were run, and the arm that did NOT bite is recorded here
-- because it is the more useful of the two on a re-read.
--
--   1. THE SLAVE IS NOT RESET-AWARE.  THIS IS THE ONE.
--      sim/tb_axi_rd_port_dual.vhd's slave clears its AR queue and its
--      in-flight burst on `rst`, so after a reset there is nothing left to
--      return and no stray `rlast` can exist.  MEASURED (control B in the
--      write-up): give THIS bench that same reset-aware slave and the stray
--      count collapses from 27-32 beats to 1, `strayl` to 0, and the
--      unclamped RTL walks away clean.  It is also why the existing dual row
--      does not catch this at all -- MEASURED (control A1): with the clamp in
--      rtl/axi_rd_fsm.vhd deleted, `tb_axi_rd_port_dual` reports
--      `0 errors across 4 clock ratios` and PASSES.
--
--   2. THE LENGTH OF THE RESET.  MEASURED NOT TO MATTER, and this CORRECTS
--      docs/debugging/2026-08-29_a7-dual-clock-run-gate.md section 7, which
--      attributed its first vacuous control to a 20-core-cycle hold.  With
--      DEPTH at 64 (see DEPTH's own note) this row gives an IDENTICAL
--      `strayl` = 4 at every ratio for holds of 1, 2 and 20 core cycles.  At
--      A7's DEPTH of 16 the port only ever had one burst in flight, so a long
--      hold could drain it; at a depth the shipping design actually uses, the
--      outstanding-burst slots are full and no plausible hold empties them.
--      **The sensitive variable is the FIFO depth, not the reset width.**
--
-- Because a bench of this shape can still pass for the wrong reason, the
-- witnesses are asserted rather than hoped for.  They are counted on the AXI
-- side, where the mechanism lives:
--
--   * `stray` -- R beats of the ABANDONED job that the port accepted after the
--     reset was released.  Zero means the reset did not catch any burst in
--     flight and nothing below tested anything.
--   * `strayl` -- how many of those carried `rlast`.  THIS is the exact
--     precondition for the underflow: an `rlast` retiring a burst the FSM no
--     longer believes it issued.  Zero means the clamp was never reached, and
--     the run is declared a coverage failure rather than a pass.
--
-- ---------------------------------------------------------------------------
-- WHAT IS CHECKED
-- ---------------------------------------------------------------------------
--   * J1, a plain job with a full value and order oracle, BEFORE the
--     interesting part.  If this one fails the rest of the run says nothing.
--   * JA, a long job abandoned by a reset in mid-flight.  No oracle: it is the
--     stimulus, not a subject.
--   * JB and JC, ordinary jobs run AFTER the reset, each with the value oracle
--     and each with a bounded wait.  Between them they catch the two ways the
--     defect can present:
--       - the port stops issuing AR             -> "STALLED, n of N beats
--                                                   never arrived"
--       - a stray beat lands in the new job's
--         FIFO and shifts every word             -> "BEAT got X want Y"
--     The second is the OPEN item in A7's section 8, which the clamp does NOT
--     fix, and this bench has now REPRODUCED IT.  MEASURED (control E in the
--     write-up): drop DRAIN_WAIT from 200 to 4 core cycles, on the COMMITTED
--     RTL with the clamp present, and all three ratios report
--     `BEAT got 3133 want 5120` -- a beat from a burst issued before the reset,
--     delivered to the consumer as the new job's word 0.  A7 stopped at "this
--     is reachable in principle and it is a design decision"; it is reachable
--     in practice, and the number above is what it looks like.
--     THE ROW IS DELIBERATELY SET AT A DRAIN_WAIT THAT DOES NOT REACH IT, so
--     that it goes in GREEN and does not turn the shared gate red for a defect
--     nobody has yet decided how to fix.  See DRAIN_WAIT's own note.
--
-- NOT CHECKED, deliberately: everything sim/tb_axi_rd_port_dual.vhd already
-- covers -- the abandon-with-residue property, the AR throttle's refusal
-- invariant, the full-rate residue bound.  This file is a SECOND stimulus for
-- the same DUT, not a second copy of that bench's checks, and the duplication
-- it does carry (the slave model and the consumer's oracle) is there because
-- the slave is the thing being varied.
--
-- METASTABILITY is out of reach here for the same reason it is there:
-- sim/cdc_teeth.sh is the flow that reaches it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_rd_port_stray is end entity;

architecture sim of tb_axi_rd_port_stray is

  constant NC     : natural  := 3;
  constant AXI_DW : positive := 32;
  constant ADDR_W : positive := 32;
  constant BYTES  : positive := AXI_DW / 8;
  -- DEPTH IS 64 HERE AND 16 IN sim/tb_axi_rd_port_dual.vhd, AND THE DIFFERENCE
  -- IS THE STIMULUS RATHER THAN A PREFERENCE.  MEASURED at DEPTH = 16, with
  -- everything else below unchanged: the reset caught 0, 1 and 1 outstanding
  -- bursts at anear, aslow and afast, and the anear run therefore reported
  -- `stray = 0` and failed its own coverage assert -- correctly, because it
  -- had tested nothing.
  --
  -- DERIVED, and it is the AR throttle in rtl/axi_rd_fsm.vhd that decides it:
  -- a burst issues only while `f_level + promised + want <= DEPTH`.  At
  -- DEPTH = 16 with MAXB = 8 that permits at most two bursts in flight and in
  -- practice one, because `promised` is already 8 after the first.  At
  -- DEPTH = 64 the guard is slack against MAXOUT * MAXB = 32, so all MAXOUT
  -- slots fill and the port runs with 3 to 4 bursts outstanding continuously.
  -- MEASURED after the change: 3, 4 and 4 outstanding at the reset, and
  -- `strayl` = 4 at every ratio.
  --
  -- The FK33 is the DEEP case: rtl/weight_streamer.vhd:75 defaults DEPTH to
  -- 512 and passes it straight into both of its ports, so a shipping port runs
  -- with its outstanding-burst slots FULL, which is exactly the condition a
  -- reset has to catch.  64 is the more representative of the two numbers for
  -- the defect this row is about, and 16 was quietly the easy case.
  constant DEPTH  : positive := 64;    -- power of two: async_fifo requires it
  constant MAXB   : positive := 8;
  constant MAXOUT : positive := 4;

  type tarr is array(0 to NC-1) of time;
  --                afast     aslow     anear
  constant CPER : tarr := (4.0 ns, 3.0 ns, 3.000 ns);   -- core clock
  constant APER : tarr := (3.0 ns, 5.0 ns, 3.001 ns);   -- AXI clock

  type namearr is array(0 to NC-1) of string(1 to 5);
  constant NAMES : namearr := ("afast", "aslow", "anear");

  -- THE RESET HOLD, in CORE cycles.  2 is chosen for ONE reason and it is not
  -- the reason that was expected.
  --
  -- MEASURED, and it is a negative result: holds of 1, 2 and 20 core cycles
  -- all produce `strayl` = 4 at all three ratios on the committed RTL, and a
  -- hold of 20 still kills the unclamped RTL.  So this constant is NOT what
  -- makes the row bite, and nobody should tune it hoping that it is (see the
  -- header, item 2, and the DEPTH note).
  --
  -- What 2 buys is DETERMINISM, and that argument stands on its own.  `rst` is
  -- a core-domain level and the AXI side sees it only through the two-flop
  -- `rst_s1/rst_s2` synchroniser in rtl/axi_rd_port.vhd's g_dc, so a pulse
  -- narrower than one aclk period can fall between two aclk edges and never
  -- cross.  The worst ratio here is `aslow` (core 3.0 ns, aclk 5.0 ns).
  -- DERIVED: a window of 2 core cycles is 6.0 ns > 5.0 ns and therefore
  -- contains an aclk rising edge at EVERY phase alignment; 1 core cycle
  -- (3.0 ns) does not, and although it happens to work at the phases this
  -- bench starts from, a row that depends on that is flaky by construction
  -- rather than by luck.  2 removes the dependence.
  constant RST_HOLD  : natural := 2;

  -- Core cycles between the reset release and the NEXT job's `start`.  Long
  -- enough that every pre-reset burst has returned and been discarded (the
  -- port holds `rready` high outside S_RUN and rtl/axi_rd_port.vhd:184 keeps
  -- `f_iv` low there, so those beats go nowhere).  DERIVED bound: at most
  -- MAXOUT * MAXB = 32 beats can be outstanding, the modelled slave returns a
  -- beat on 6 aclk cycles in 7, so under 40 aclk cycles; at the slowest AXI
  -- clock here that is 200 ns = 67 core cycles.  200 is a 3x margin.
  --
  -- THIS CONSTANT IS THE LINE BETWEEN THE TWO DEFECTS, AND THE SECOND ONE IS
  -- LIVE.  MEASURED at DRAIN_WAIT = 4 on the committed RTL: the stray beats
  -- arrive while the new job is already in S_RUN, they are written into its
  -- FIFO, and the oracle reports `BEAT got 3133 want 5120` at anear,
  -- `got 3108 want 5120` at aslow and `got 3155 want 5120` at afast.  That is
  -- the open item in A7's section 8 -- a WRONG-NUMBERS failure, not a hang,
  -- and the clamp does not touch it.
  --
  -- It is a DESIGN DECISION (the two candidate fixes have opposite costs
  -- depending on whether the slave shares the reset net -- see section 6 of
  -- A7's write-up) and it is NOT fixed.  So this row is deliberately parked on
  -- the safe side of the line: 200 gives every pre-reset burst time to return
  -- and be discarded, and the row goes in green.
  --
  -- DO NOT shrink this to "make the row stronger".  It would turn the shared
  -- gate red for every track over a defect that has an owner and no decision.
  -- The right move is to take the decision, fix rtl/axi_rd_fsm.vhd, and THEN
  -- shrink it -- at which point this file already contains the check.
  constant DRAIN_WAIT : natural := 200;

  -- Word-index ranges, one per job, so a beat's own value says which job it
  -- belongs to.  The slave returns the word index of the address it was asked
  -- for, so the monitor can attribute a stray beat without any side channel.
  constant J1_BASE : natural := 1024;
  constant JA_BASE : natural := 3072;   -- the job the reset abandons
  constant JA_END  : natural := 3072 + 400;
  constant JB_BASE : natural := 5120;
  constant JC_BASE : natural := 7168;

  type iarr is array(0 to NC-1) of integer;
  signal errs    : iarr := (others => 0);
  signal nbeats  : iarr := (others => 0);
  signal nstray  : iarr := (others => 0);
  signal nstrayl : iarr := (others => 0);
  signal fin     : std_logic_vector(0 to NC-1) := (others => '0');

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

    -- Consumer control.  Same shape as sim/tb_axi_rd_port_dual.vhd's, and for
    -- the same reason: an expectation written by both the sequencer and the
    -- consumer is two sources on an unresolved signal and GHDL refuses to
    -- elaborate it, so it is a VARIABLE loaded through a one-cycle handshake.
    signal cons_en   : std_logic := '0';
    signal strict    : std_logic := '0';
    signal ld        : std_logic := '0';
    signal ld_word   : integer := 0;
    signal ld_left   : integer := 0;
    signal exp_left_o: integer := 0;
    signal err_i     : integer := 0;
    signal err_s     : integer := 0;
    signal stall_i   : integer := 0;
    signal beats_i   : integer := 0;

    -- The stray-beat monitor, on the AXI side.
    signal mon_arm   : std_logic := '0';
    signal stray_o   : integer := 0;
    signal strayl_o  : integer := 0;
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
    -- IDENTICAL to sim/tb_axi_rd_port_dual.vhd's slave EXCEPT that it has no
    -- `rst` branch at all: it never sees the DUT's reset, it never drops a
    -- queued burst, and it keeps returning beats straight through.  THAT
    -- SINGLE DIFFERENCE IS THE WHOLE POINT OF THIS FILE.  It is also the more
    -- honest model of the FK33, where the streamer resets on `core_aresetn`
    -- and the HBM slave on the XDMA's `axi_aresetn`.
    --
    -- The AR queue is deeper than MAXOUT so the model never backpressures AR
    -- for a conforming port; `arready` stalls on a fixed pattern so the accept
    -- latency varies.
    slave : process(aclk)
      constant QN : integer := 16;
      type qi is array(0 to QN-1) of integer;
      variable qa   : qi := (others => 0);   -- first word index of the burst
      variable ql   : qi := (others => 0);   -- beats in the burst
      variable qw   : integer := 0;
      variable qr   : integer := 0;
      variable qc   : integer := 0;
      variable cidx : integer := 0;
      variable cleft: integer := 0;
      variable busy : boolean := false;
      variable ph   : integer := 0;
    begin
      if rising_edge(aclk) then
        ph := (ph + 1) mod 7;

        if arready = '1' and arvalid = '1' then
          qa(qw) := to_integer(unsigned(araddr)) / BYTES;
          ql(qw) := to_integer(unsigned(arlen)) + 1;
          qw := (qw + 1) mod QN;
          qc := qc + 1;
        end if;
        if qc < QN-1 and ph /= 3 then arready <= '1'; else arready <= '0'; end if;

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
      end if;
    end process;

    -- ================================================ the stray-beat monitor
    -- Counts, while armed, the R beats the PORT ACCEPTED whose word index
    -- belongs to the ABANDONED job.  Attribution is by the beat's own value,
    -- so no side channel from the slave is needed and a monitor bug cannot
    -- invent a beat that did not cross the R channel.
    --
    -- `strayl` is the one that matters.  Each of those is an `rlast` retiring
    -- a burst that rtl/axi_rd_fsm.vhd zeroed out of `outst` in its reset
    -- branch, which is exactly `os := os - 1` against zero.
    mon : process(aclk)
      variable w  : integer;
      variable s  : integer := 0;
      variable sl : integer := 0;
    begin
      if rising_edge(aclk) then
        if mon_arm = '1' and rvalid = '1' and rready = '1' then
          w := to_integer(unsigned(rdata));
          if w >= JA_BASE and w < JA_END then
            s := s + 1;
            if rlast = '1' then sl := sl + 1; end if;
          end if;
        end if;
        stray_o  <= s;
        strayl_o <= sl;
      end if;
    end process;

    -- ==================================================== the consumer
    cons : process(clk)
      variable ph : integer := 0;
      variable w  : integer;
      variable exp_word : integer := 0;
      variable exp_left : integer := 0;
      variable err      : integer := 0;
      variable stall    : integer := 0;
      variable beats    : integer := 0;
    begin
      if rising_edge(clk) then
        ph := (ph + 1) mod 8;
        q_ready <= '0';
        if cons_en = '1' and ph /= 2 then q_ready <= '1'; end if;

        if ld = '1' then
          exp_word := ld_word;
          exp_left := ld_left;
        end if;

        if rst = '0' and q_valid = '1' and q_ready = '1' then
          w := to_integer(unsigned(q_data));
          beats := beats + 1;
          if strict = '1' then
            if exp_left <= 0 then
              report NAMES(i) & ": A BEAT ARRIVED AFTER THE JOB WAS COMPLETE" &
                     " -- the port delivered more than n_beats"
                severity error;
              err := err + 1;
            elsif w /= exp_word then
              report NAMES(i) & ": BEAT got " & integer'image(w) &
                     " want " & integer'image(exp_word) &
                     " -- a beat was DROPPED, DUPLICATED, REORDERED, or came" &
                     " from a burst issued BEFORE THE RESET and landed in" &
                     " this job's FIFO"
                severity error;
              err := err + 1;
              exp_word := w + 1;          -- resynchronise: one error, one line
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

        if rst = '0' and q_ready = '1' and q_valid = '0' and strict = '1' then
          stall := stall + 1;
        end if;

        exp_left_o <= exp_left;
        err_i      <= err;
        stall_i    <= stall;
        beats_i    <= beats;
      end if;
    end process;

    errs(i)    <= err_i + err_s;
    nbeats(i)  <= beats_i;
    nstray(i)  <= stray_o;
    nstrayl(i) <= strayl_o;

    -- ==================================================== the sequencer
    seq : process
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

      -- THE BOUNDED WAIT IS THE HANG DETECTOR.  Without the clamp in
      -- rtl/axi_rd_fsm.vhd a GHDL run dies on the bound check before it ever
      -- gets here, but a synthesised port does not: it simply stops issuing
      -- AR.  This is the check that would see THAT, and it is the reason the
      -- jobs after the reset are run to completion rather than merely started.
      procedure await_job(nb : integer; what : string) is
      begin
        for t in 0 to 40000 loop
          exit when exp_left_o <= 0;
          wait until rising_edge(clk);
        end loop;
        if exp_left_o > 0 then
          report NAMES(i) & ": " & what & " STALLED -- " &
                 integer'image(exp_left_o) & " of " & integer'image(nb) &
                 " beats never arrived.  The port issued no further AR, which" &
                 " is what an underflowed `outst` looks like in hardware"
            severity error;
          err_s <= err_s + 1;
        end if;
      end procedure;

      -- Drop `cons_en` two cycles before `strict`, never in the same delta:
      -- q_ready is a REGISTER inside the consumer and falls one core cycle
      -- late, so relaxing the oracle together with it lets a legitimate
      -- in-flight beat land in a window where the oracle believes no job is
      -- running.  MEASURED in sim/tb_axi_rd_port_dual.vhd on CORRECT RTL.
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

      -- ---- J1: a plain job BEFORE the interesting part.  If the bench cannot
      -- move a clean job across this DUT, nothing below means anything.
      whole_job(J1_BASE, 20, "J1");

      -- ---- JA: the job the reset abandons.  Long, so that bursts are
      -- certainly in flight and the modelled slave's queue is certainly not
      -- empty at the moment the reset lands.  No oracle: this is stimulus.
      load(JA_BASE, 400);
      pulse_start(JA_BASE, 400);
      strict <= '1'; cons_en <= '1';
      for t in 0 to 59 loop wait until rising_edge(clk); end loop;
      stop_reading;

      -- ---- THE RESET.  Short (see RST_HOLD), and the slave above does not
      -- see it, so the bursts it has already accepted keep returning.
      mon_arm <= '1';
      rst <= '1';
      for t in 0 to RST_HOLD-1 loop wait until rising_edge(clk); end loop;
      rst <= '0';

      -- Let the strays return and be discarded.  See DRAIN_WAIT.
      for t in 0 to DRAIN_WAIT-1 loop wait until rising_edge(clk); end loop;
      mon_arm <= '0';

      -- ---- JB and JC: ordinary jobs across the reset, each fully checked.
      whole_job(JB_BASE, 24, "JB after the reset");
      whole_job(JC_BASE, 13, "JC after the reset");

      -- ---- COVERAGE, asserted rather than printed.  Both of these are the
      -- ways this bench can pass for the wrong reason, and both have actually
      -- happened to the control this row grew out of.
      if stray_o = 0 then
        report NAMES(i) & ": COVERAGE -- NO beat of the abandoned job arrived" &
               " after the reset, so the reset did not catch a burst in" &
               " flight and nothing here was tested.  Check RST_HOLD"
          severity error;
        err_s <= err_s + 1;
      end if;
      if strayl_o = 0 then
        report NAMES(i) & ": COVERAGE -- no stray beat carried `rlast`, so no" &
               " burst was retired against a zeroed `outst` and the clamp in" &
               " rtl/axi_rd_fsm.vhd was never reached"
          severity error;
        err_s <= err_s + 1;
      end if;
      if stall_i = 0 then
        report NAMES(i) & ": COVERAGE -- the consumer NEVER waited on q_valid," &
               " so the FIFO was never the limit on any job here"
          severity error;
        err_s <= err_s + 1;
      end if;

      wait until rising_edge(clk);
      wait until rising_edge(clk);
      report NAMES(i) & ": beats=" & integer'image(beats_i) &
             " stall=" & integer'image(stall_i) &
             " stray=" & integer'image(stray_o) &
             " strayl=" & integer'image(strayl_o) &
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
    report "axi_rd_port_stray: " & integer'image(tot) &
           " errors across " & integer'image(NC) & " clock ratios";
    if tot = 0 then
      report "PASS: tb_axi_rd_port_stray";
    else
      report "FAIL: tb_axi_rd_port_stray" severity error;
    end if;
    wait;
  end process;

end architecture;
