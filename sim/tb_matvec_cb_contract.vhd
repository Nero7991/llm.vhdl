-- sim/tb_matvec_cb_contract.vhd -- the IQ4_NL codebook's WRITE CONTRACT.
--
-- WHY THIS EXISTS, AND WHY IT IS SEPARATE FROM tb_matvec_cb_lockstep.
--
-- sim/tb_matvec_cb_lockstep.vhd covers the LOAD SCHEDULE: the same codebook
-- loaded twenty cycles before start and one cycle before start must give a
-- bit-identical result.  It says nothing about what happens to a write that
-- arrives when a write is not allowed, because it never issues one.
--
-- That gap is measured, not supposed.  docs/debugging/2026-08-29_subsystem-a-
-- mutations.md scores mutations C2 (`codebook writes are accepted outside
-- idle`) and C3 (`the S_IDLE cb_we interlock is deleted`) as SURVIVORS across
-- all three gate traces, and its section 4.3 gives the reason: every bench in
-- the closure writes the codebook before the first `start` and never again, so
-- the branch those mutations change is never taken.  `matvec_core`'s own
-- P_CB_CHK has the teeth; nothing generates the stimulus.
--
-- THIS BENCH GENERATES THAT STIMULUS, and it does so with a VALUE oracle as
-- well as the core's internal assertions, because the two fail differently and
-- a change that moves the assertions must not silently take the coverage with
-- them.  Every property below is decided by comparing y_data across runs, so
-- it survives P_CB_CHK being deleted, weakened, or restructured -- which is
-- exactly what the pre-authorised congestion fallback (the codebook to
-- LUTRAM, ~32x more replicas) would do to it.
--
-- ---------------------------------------------------------------------------
-- THE CONTRACT, READ OUT OF rtl/matvec_core.vhd AT HEAD
-- ---------------------------------------------------------------------------
-- Symbols, not line numbers: the entity's `cb_we/cb_addr/cb_data` ports, the
-- `cb` / `cbw_v` / `cbw_a` / `cbw_d` declarations, process `P_CB`, process
-- `P_CB_CHK`, the `elsif cb_we = '1' and st = S_IDLE` arm of the main clocked
-- process, and the `cb(rr / CB_ROWS_PER_COPY)(idx)` read in the s1 product
-- stage.
--
--   K1 ACCEPTANCE.   A command is captured into cbw_v/a/d(c) at an edge iff
--                    cb_we = '1' and st = S_IDLE and rst = '0' before it.
--   K2 LATENCY.      cb(c)(a) takes the value one edge after the command is
--                    captured.  Two edges after cb_we is seen.
--   K3 LOCKSTEP.     Every replica writes off its own command register on the
--                    same edge, so no cycle exists in which two replicas hold
--                    different tables.  P_CB_CHK asserts this structurally.
--   K4 IDLE ONLY.    A captured command implies st = S_IDLE and implies no
--                    beat in the compute pipeline.  P_CB_CHK asserts both.
--   K5 DROPPED.      A write offered outside idle, or during reset, is
--                    SILENTLY DROPPED.  No err, no deferral, no effect.  The
--                    RTL states this only by omission; it is a contract term
--                    and it is what runs 4, 5 and 6 below pin down.
--   K6 RESET.        Reset kills a command that has not yet been captured and
--                    deliberately does NOT clear cb.  The table outlives a
--                    reset.
--   K7 INTERLOCK.    cb_we = '1' in S_IDLE makes that edge not also a start
--                    edge.  So the tightest legal schedule is: last cb_we at
--                    edge N, start honoured at edge N+1, which is the edge the
--                    write lands on.  Holding cb_we high holds start off.
--   K8 POWER-UP.     cb initialises to all zeros, so an operation run before
--                    any codebook write decodes every nibble to 0 and emits 0.
--                    This is the only property that tests the INITIALISER, and
--                    it is the property that becomes load-bearing under
--                    LUTRAM, where the initialiser becomes a RAM INIT string.
--
-- NOT A CONTRACT TERM, AND DELIBERATELY SO -- see run 8.  Nothing marks the
-- codebook COMPLETE.  Coherency is guaranteed across REPLICAS and not across
-- the sixteen ENTRIES, so an operation started after a partial load consumes a
-- mixed table and reports success.  Run 8 demonstrates that rather than
-- forbidding it: forbidding it is a design change and belongs to Oren.
--
-- ---------------------------------------------------------------------------
-- SHAPE, AND WHY EACH CHOICE
-- ---------------------------------------------------------------------------
-- ROWS_IF = 4 with CB_ROWS_PER_COPY = 1 gives FOUR replicas, so K3 has
-- something to be false about.  A single-copy configuration would make every
-- divergence property vacuous.
--
-- BLK = 16 with nibble (rr,j) = j means every row touches every one of the
-- sixteen codebook entries exactly once AND every row's stimulus is
-- IDENTICAL.  That is what makes the lane-equality oracle a replica coherency
-- check rather than a tautology; see its comment for the measurement.
--
-- NB = 24 blocks.  The operation must stay in S_RUN long enough to offer a
-- whole sixteen-entry load DURING it (run 4), and long enough for the compute
-- pipeline to be genuinely full when that load is offered, so the second
-- P_CB_CHK invariant (`inflight`) is exercised and not just the first.
--
-- n_cols = NB*BLK exactly, so no column is masked.  The column mask is
-- tb_matvec_core's subject; mixing it in here would make a failure ambiguous.
--
-- out_mode = "01" (raw).  BFP normalisation can map two different codebooks
-- onto the same mantissa and hide a difference that runs 2 and 8 depend on
-- seeing.  Raw emits the int32 straight out of row end.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_matvec_cb_contract is
  generic(
    BLK     : positive := 16;
    ROWS_IF : positive := 4;
    NB      : positive := 24;
    -- 1 = one replica per row, the core's default.  Set to ROWS_IF to collapse
    -- the bank to a single copy, which is how you confirm this bench is not
    -- passing because replication is absent.
    CB_ROWS_PER_COPY : positive := 1
  );
end entity;

architecture tb of tb_matvec_cb_contract is
  constant TCK : time := 10 ns;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal start : std_logic := '0';
  signal running : boolean := true;

  signal n_rows, n_cols, out_shift, w_exp, x_exp, y_exp : integer := 0;
  signal out_mode : std_logic_vector(1 downto 0) := "01";

  signal cb_we   : std_logic := '0';
  signal cb_addr : std_logic_vector(3 downto 0) := (others => '0');
  signal cb_data : std_logic_vector(7 downto 0) := (others => '0');

  signal w_valid : std_logic := '0';
  signal w_ready : std_logic;
  signal w_data  : std_logic_vector(ROWS_IF*BLK*4-1 downto 0) := (others => '0');
  signal s_valid : std_logic := '0';
  signal s_ready : std_logic;
  signal s_data  : std_logic_vector(ROWS_IF*16-1 downto 0) := (others => '0');

  signal x_rbaddr : std_logic_vector(15 downto 0);
  signal x_rdata  : std_logic_vector(BLK*16-1 downto 0) := (others => '0');
  signal xword    : std_logic_vector(BLK*16-1 downto 0) := (others => '0');

  signal y_we   : std_logic;
  signal y_addr : std_logic_vector(15 downto 0);
  signal y_data : std_logic_vector(ROWS_IF*64-1 downto 0);
  signal y_mask : std_logic_vector(ROWS_IF-1 downto 0);
  signal done, err, sat_event : std_logic;

  signal cap    : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');
  signal cap_n  : integer := 0;

  constant ZERO_Y : std_logic_vector(ROWS_IF*64-1 downto 0) := (others => '0');

  type cbv_t is array(0 to 15) of integer;
  -- Two codebooks differing in EVERY entry, so no choice of weight nibbles can
  -- make two runs agree by only touching entries they share.
  constant CB1 : cbv_t := (-127, -104, -83, -65, -49, -35, -22, -10,
                             1,   13,  25,  38,  53,  69,  89, 113);
  constant CB2 : cbv_t := ( 113,   89,  69,  53,  38,  25,  13,   1,
                           -10,  -22, -35, -49, -65, -83,-104,-127);

  signal nfail   : integer := 0;
  signal nfail_c : integer := 0;   -- driven by the concurrent lane checker
begin

  clk <= (not clk) after TCK/2 when running else '0';

  ------------------------------------------------------------------ act mem
  -- Every block index returns the same word.  The core's contract is a
  -- 1-cycle registered read; this bench is about the codebook, not about the
  -- activation address sequence, which tb_matvec_core already covers against
  -- the C reference.
  process(clk) begin
    if rising_edge(clk) then
      x_rdata <= xword;
    end if;
  end process;

  ------------------------------------------------------------------ capture
  process(clk) begin
    if rising_edge(clk) then
      if y_we = '1' then
        cap   <= y_data;
        cap_n <= cap_n + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------- lane-equality oracle
  -- REPLICA COHERENCY, OBSERVED AT THE OUTPUT.  Every row of this bench's
  -- stimulus is identical -- same nibbles, same scale, same activations -- and
  -- row rr decodes through replica rr / CB_ROWS_PER_COPY.  So two lanes of an
  -- emitted beat can differ ONLY because the replicas they read differ.
  --
  -- This is the property the value oracle needs in order to stand WITHOUT
  -- matvec_core's internal P_CB_CHK.  It runs on every beat of every run,
  -- including the power-up run and the partial-load run, so it costs nothing
  -- to keep, and it is the check that survives a restructuring of the write
  -- path -- which is exactly what the LUTRAM fallback is.
  --
  -- It is deliberately a SEPARATE process from the stimulus: a check that only
  -- runs where the stimulus remembered to call it has a coverage hole shaped
  -- like the author's attention.
  process(clk)
    variable lane0 : std_logic_vector(63 downto 0);
  begin
    if rising_edge(clk) then
      if y_we = '1' then
        lane0 := y_data(63 downto 0);
        for rr in 1 to ROWS_IF-1 loop
          if y_data(rr*64+63 downto rr*64) /= lane0 then
            report "tb_matvec_cb_contract: FAIL -- emitted lane " &
                   integer'image(rr) & " differs from lane 0 on a beat whose " &
                   "rows carry IDENTICAL weights, scale and activations.  " &
                   "Row rr reads codebook replica rr / CB_ROWS_PER_COPY, so " &
                   "this is replica divergence seen at the output."
              severity error;
            nfail_c <= nfail_c + 1;
          end if;
        end loop;
      end if;
    end if;
  end process;

  dut : entity work.matvec_core
    generic map(BLK => BLK, ROWS_IF => ROWS_IF, MAXCOLS => 4096,
                MAXROWS_BFP => 256, CB_ROWS_PER_COPY => CB_ROWS_PER_COPY)
    port map(clk => clk, rst => rst, start => start,
             n_rows => n_rows, n_cols => n_cols, out_shift => out_shift,
             w_exp => w_exp, x_exp => x_exp, out_mode => out_mode,
             cb_we => cb_we, cb_addr => cb_addr, cb_data => cb_data,
             w_valid => w_valid, w_data => w_data, w_ready => w_ready,
             s_valid => s_valid, s_data => s_data, s_ready => s_ready,
             x_rbaddr => x_rbaddr, x_rdata => x_rdata,
             y_we => y_we, y_addr => y_addr, y_data => y_data,
             y_mask => y_mask, y_exp => y_exp, done => done, err => err,
             sat_event => sat_event,
             tp_v => open, tc_v => open, ta_v => open, tm_v => open,
             tp_r => open, tc_r => open, ta_r => open, tm_r => open,
             tp_b => open, tc_b => open,
             tp_val => open, tc_val => open, ta_val => open, tm_val => open,
             tap_ns => open);

  ------------------------------------------------------------------ stimulus
  process
    variable y0, yA, yB, yC, yD, yE, yF, yG, yP : std_logic_vector(ROWS_IF*64-1 downto 0);
    variable nseen : integer;
    variable saw_done : boolean;

    procedure tick(n : natural) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- Report a failed property without stopping, so ONE run reports EVERY
    -- property it breaks rather than the first.  A mutation harness that sees
    -- only the first failure cannot tell a narrow break from a broad one.
    -- The final `nfail = 0` assert is what carries severity failure.
    procedure fail(msg : string) is
    begin
      report "tb_matvec_cb_contract: FAIL -- " & msg severity error;
      nfail <= nfail + 1;
      wait for 0 ns;
    end procedure;

    -- Load the first `cnt` entries.  One cb_we per cycle, back to back, which
    -- is the shape the AXI wrapper produces.  Deliberately NO settling delay:
    -- the caller owns the gap between the last write and start.
    procedure load_cb(cbv : cbv_t; cnt : natural) is
    begin
      for a in 0 to cnt-1 loop
        cb_addr <= std_logic_vector(to_unsigned(a, 4));
        cb_data <= std_logic_vector(to_signed(cbv(a), 8));
        cb_we   <= '1';
        wait until rising_edge(clk);
      end loop;
      cb_we <= '0';
    end procedure;

    -- gap = 0 is the tightest legal schedule (K7).
    procedure run_op(gap : natural; res : out std_logic_vector) is
    begin
      if gap > 0 then tick(gap); end if;
      nseen := cap_n;
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      for i in 1 to 4000 loop
        wait until rising_edge(clk);
        exit when done = '1';
      end loop;
      if done /= '1' then
        fail("the operation never raised done");
      end if;
      if err /= '0' then
        fail("the core reported err on a legal descriptor");
      end if;
      tick(2);
      if cap_n /= nseen + 1 then
        fail("expected exactly one y beat, saw " &
             integer'image(cap_n - nseen));
      end if;
      res := cap;
    end procedure;

    -- Start an operation and then offer a WHOLE sixteen-entry codebook load
    -- while it runs.  `after` cycles of delay puts the offer well inside
    -- S_RUN with the compute pipeline full, so both P_CB_CHK invariants are
    -- in scope, not just the `st` one.
    procedure run_op_illegal_write(after_n : natural; cbv : cbv_t;
                                   res : out std_logic_vector) is
    begin
      nseen := cap_n;
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      tick(after_n);
      load_cb(cbv, 16);
      for i in 1 to 4000 loop
        wait until rising_edge(clk);
        exit when done = '1';
      end loop;
      if done /= '1' then
        fail("the operation never raised done (illegal-write run)");
      end if;
      if err /= '0' then
        fail("the core reported err during the illegal-write run.  The " &
             "contract is that the write is DROPPED, not that it is an error");
      end if;
      tick(2);
      if cap_n /= nseen + 1 then
        fail("expected exactly one y beat from the illegal-write run, saw " &
             integer'image(cap_n - nseen));
      end if;
      res := cap;
    end procedure;
  begin
    -- descriptor: one tile, NB blocks, raw
    n_rows    <= ROWS_IF;
    n_cols    <= NB * BLK;
    out_shift <= 0;
    w_exp     <= 0;
    x_exp     <= 0;
    out_mode  <= "01";

    -- WEIGHTS AND SCALES ARE IDENTICAL ON EVERY ROW, AND THAT IS THE WHOLE
    -- POINT OF THE SHAPE.  nibble (rr,j) = j with BLK = 16 touches every
    -- codebook entry exactly once per row, and every row gets the same
    -- nibbles, the same scale and the same activations.  So the ROWS_IF lanes
    -- of an emitted beat MUST be bit-identical -- and row rr reads replica
    -- rr / CB_ROWS_PER_COPY, so lane inequality IS replica divergence,
    -- observed at the OUTPUT.
    --
    -- That property is the reason this shape was chosen over the obvious
    -- per-row-distinct one.  MEASURED: with per-row-distinct nibbles, a
    -- mutation that leaves replicas 1..3 permanently unwritten changes every
    -- run identically and NO comparison between runs can see it -- only the
    -- core's internal P_CB_CHK can.  With identical rows the value oracle
    -- sees it alone, which is what the LUTRAM fallback needs: it multiplies
    -- the replica count by 32 and is the change most likely to disturb
    -- P_CB_CHK itself.
    for rr in 0 to ROWS_IF-1 loop
      for j in 0 to BLK-1 loop
        w_data((rr*BLK + j)*4 + 3 downto (rr*BLK + j)*4) <=
          std_logic_vector(to_unsigned(j mod 16, 4));
      end loop;
      s_data(rr*16+15 downto rr*16) <=
        std_logic_vector(to_unsigned(4096, 16));
    end loop;
    for j in 0 to BLK-1 loop
      xword(j*16+15 downto j*16) <=
        std_logic_vector(to_signed(97 * (j + 1) - 300, 16));
    end loop;

    rst <= '1';
    tick(4);
    rst <= '0';
    tick(2);
    w_valid <= '1';
    s_valid <= '1';
    tick(1);

    ----------------------------------------------------------------------
    -- RUN 0 -- K8 POWER-UP.  No codebook write has been issued since time
    -- zero, so cb holds its initialiser.  Every nibble decodes to 0, every
    -- product is 0, and raw mode emits 0.
    --
    -- THIS IS THE ONLY PROPERTY IN THE TREE THAT TESTS THE INITIALISER, and
    -- it is here because the initialiser is exactly what the LUTRAM fallback
    -- turns into a RAM INIT string.  Distributed RAM has no reset; if the
    -- initialiser is lost in that change, an un-loaded codebook holds 'U' in
    -- simulation and whatever the bitstream left in hardware, and nothing
    -- else in the tree would notice.
    ----------------------------------------------------------------------
    run_op(2, y0);
    if y0 /= ZERO_Y then
      fail("an operation run before any codebook write did not emit zero.  " &
           "cb's initialiser is what makes an un-loaded codebook decode " &
           "every nibble to 0");
    end if;

    ----------------------------------------------------------------------
    -- RUN 1 -- the reference, and the teeth for everything after it.
    ----------------------------------------------------------------------
    load_cb(CB1, 16);
    run_op(20, yA);
    if yA = ZERO_Y then
      fail("the reference run with a loaded codebook emitted zero, so it is " &
           "indistinguishable from the un-loaded run 0 and every comparison " &
           "below is vacuous");
    end if;

    ----------------------------------------------------------------------
    -- RUN 2 -- a DIFFERENT codebook must give a DIFFERENT answer.  Without
    -- this, every `= yA` below could hold because the codebook reaches
    -- nothing at all.
    ----------------------------------------------------------------------
    load_cb(CB2, 16);
    run_op(20, yC);
    if yC = yA then
      fail("two codebooks that differ in every entry gave identical " &
           "results, so the codebook is not reaching the lanes and every " &
           "comparison in this bench is vacuous");
    end if;

    ----------------------------------------------------------------------
    -- RUN 3 -- a reload restores the original answer.  Catches a write path
    -- that latches once and then ignores every later write.
    ----------------------------------------------------------------------
    load_cb(CB1, 16);
    run_op(20, yB);
    if yB /= yA then
      fail("reloading the original codebook did not restore the original " &
           "result");
    end if;

    ----------------------------------------------------------------------
    -- RUN 4 -- K5, THE GAP THIS BENCH EXISTS FOR.  A whole sixteen-entry
    -- load is offered DURING an operation.  Two things must hold and they
    -- are independent:
    --
    --   (a) the running operation is not disturbed  -- yD = yA
    --   (b) the write was DROPPED and not merely LATE -- the NEXT operation,
    --       with no further writes at all, still gives yA
    --
    -- (b) is the one that has teeth against a deferral.  A design that
    -- queued the write and applied it at the next idle would pass (a) and
    -- fail (b), and a bench that only checked (a) would call that correct.
    ----------------------------------------------------------------------
    run_op_illegal_write(6, CB2, yD);
    if yD /= yA then
      fail("a codebook write offered DURING an operation changed that " &
           "operation's result.  Writes are legal only in idle (spec 6.1) " &
           "and one that lands later decodes earlier lanes with the old " &
           "table and later lanes with the new");
    end if;
    run_op(4, yE);
    if yE /= yA then
      fail("a codebook write offered during an operation took effect on the " &
           "NEXT operation.  The contract is that it is dropped, not " &
           "deferred: a host that saw no error would have no way to know " &
           "which operation its write applied to");
    end if;

    ----------------------------------------------------------------------
    -- RUN 5 -- K5 again, during RESET.  The capture is gated on rst = '0',
    -- so a whole load offered under reset must vanish.
    ----------------------------------------------------------------------
    rst <= '1';
    tick(2);
    load_cb(CB2, 16);
    tick(2);
    rst <= '0';
    tick(3);
    run_op(2, yF);
    if yF /= yA then
      fail("a codebook write offered while rst was asserted took effect.  " &
           "The command capture is gated on rst = '0'");
    end if;

    ----------------------------------------------------------------------
    -- RUN 6 -- K6.  The codebook OUTLIVES a reset.  cb is deliberately not
    -- cleared by rst, and the previous version of this design behaved the
    -- same way, so a change that starts clearing it is a silent regression
    -- for every host that loads the table once at bring-up.
    ----------------------------------------------------------------------
    rst <= '1';
    tick(3);
    rst <= '0';
    tick(3);
    run_op(2, yG);
    if yG /= yA then
      fail("the codebook did not survive a reset.  cb is deliberately not " &
           "cleared by rst; a host that loads the table once at bring-up " &
           "depends on that");
    end if;

    ----------------------------------------------------------------------
    -- RUN 7 -- K7, THE INTERLOCK, FROM BOTH SIDES.
    --
    -- 7a: cb_we held high with start held high must NOT start an operation.
    --     This is a VALUE-level statement of the interlock, and it matters
    --     because the interlock's only other witness is an internal
    --     assertion.  Deleting the interlock is mutation C3, which survived
    --     every trace in the subsystem-A mutation run.
    --
    -- 7b: dropping cb_we then lets it start, and the answer is the one the
    --     codebook loaded on the very last of those held cycles selects.
    --     The held write is CB2 entry by entry, so the operation must give
    --     yC and not yA -- a write accepted on the tightest possible
    --     schedule is visible to the lanes.
    ----------------------------------------------------------------------
    -- Load CB2 but leave cb_we HIGH on the last entry, with start high too.
    for a in 0 to 15 loop
      cb_addr <= std_logic_vector(to_unsigned(a, 4));
      cb_data <= std_logic_vector(to_signed(CB2(a), 8));
      cb_we   <= '1';
      wait until rising_edge(clk);
    end loop;
    -- entry 15 re-offered, idempotently, for the whole hold window
    nseen    := cap_n;
    saw_done := false;
    start    <= '1';
    for i in 1 to 120 loop
      wait until rising_edge(clk);
      if done = '1' then saw_done := true; end if;
    end loop;
    if saw_done then
      fail("an operation started while cb_we was held high.  The empty " &
           "`elsif cb_we = '1' and st = S_IDLE` arm of the main process IS " &
           "the interlock: it is what stops start being honoured on the " &
           "same edge as a codebook write, which is the one schedule where " &
           "the registered write has not landed");
    end if;
    if cap_n /= nseen then
      fail("a y beat was emitted while cb_we was held high with start high");
    end if;
    cb_we <= '0';
    -- start is still high; the very next edge is the first that can take it,
    -- and start is dropped ON that edge.
    --
    -- DROPPING IT LATER IS A TRAP THIS BENCH FELL INTO.  `done` is registered,
    -- so a process that reads it after `wait until rising_edge(clk)` sees it
    -- one edge AFTER the edge that set it -- and `st` returned to S_IDLE on
    -- that earlier edge.  Holding `start` high until the poll notices `done`
    -- therefore launches a SECOND, unwanted operation on the S_IDLE edge in
    -- between, and every later run then loads its codebook into a busy core
    -- and has it dropped.  Measured: it made runs 8 and 9 fail on honest RTL.
    wait until rising_edge(clk);
    start <= '0';
    for i in 1 to 4000 loop
      wait until rising_edge(clk);
      exit when done = '1';
    end loop;
    if done /= '1' then
      fail("the operation never raised done after cb_we was released");
    end if;
    tick(2);
    if cap_n /= nseen + 1 then
      fail("expected exactly one y beat after cb_we was released, saw " &
           integer'image(cap_n - nseen));
    end if;
    if cap /= yC then
      fail("a codebook loaded on the tightest legal schedule -- the write " &
           "released on the same edge the operation starts -- was not " &
           "visible to the lanes");
    end if;

    ----------------------------------------------------------------------
    -- RUN 8 -- THE PARTIAL-LOAD HAZARD.  DEMONSTRATED, NOT FORBIDDEN.
    --
    -- Coherency is guaranteed across REPLICAS and not across the sixteen
    -- ENTRIES.  Nothing in the core marks the codebook complete, so a host
    -- that starts an operation after writing eight of sixteen entries gets a
    -- MIXED table, a plausible answer, and no error.
    --
    -- The assertions here state exactly that and nothing stronger: err is
    -- low, and the answer matches NEITHER of the two tables.  If a future
    -- change adds a completeness guard, this run will start failing, and
    -- that failure is the correct signal -- update it deliberately.
    ----------------------------------------------------------------------
    load_cb(CB1, 16);     -- known base
    run_op(6, yB);
    if yB /= yA then
      fail("restoring CB1 before the partial-load run did not restore yA");
    end if;
    load_cb(CB2, 8);      -- first half of the OTHER table, over CB1
    run_op(6, yP);
    if err /= '0' then
      fail("the partial-load run reported err; this bench documents that it " &
           "does not");
    end if;
    if yP = yA or yP = yC then
      fail("the partial-load run matched a whole table, so the mixed table " &
           "was not consumed and this run demonstrates nothing.  Check the " &
           "weight nibbles still reach entries on both sides of the split");
    end if;
    report "tb_matvec_cb_contract: NOTE -- an operation started after a " &
           "PARTIAL codebook load consumed a mixed table and reported " &
           "success.  Nothing in matvec_core marks the codebook complete.  " &
           "This is a demonstrated hazard, not a failure of the RTL against " &
           "its stated contract." severity note;

    ----------------------------------------------------------------------
    -- restore CB1 and confirm the core is still in the state this bench
    -- believes it is.  A bench that ends on an unverified state has left its
    -- last property untested.
    ----------------------------------------------------------------------
    load_cb(CB1, 16);
    run_op(6, yB);
    if yB /= yA then
      fail("the final restore did not reproduce the reference result");
    end if;

    assert nfail = 0 and nfail_c = 0
      report "tb_matvec_cb_contract: " & integer'image(nfail + nfail_c) &
             " codebook contract properties FAILED (" &
             integer'image(nfail) & " sequenced, " & integer'image(nfail_c) &
             " lane-equality).  See the FAIL lines above."
      severity failure;

    report "tb_matvec_cb_contract: PASS -- 9 runs, 0 failures.  Codebook " &
           "writes outside idle and under reset are dropped; the table " &
           "survives reset; the cb_we/start interlock holds from both " &
           "sides; an un-loaded codebook decodes to zero; a partial load is " &
           "consumed silently (documented, run 8).  CB_ROWS_PER_COPY=" &
           integer'image(CB_ROWS_PER_COPY) & " NB=" & integer'image(NB)
      severity note;
    running <= false;
    wait;
  end process;

end architecture;
