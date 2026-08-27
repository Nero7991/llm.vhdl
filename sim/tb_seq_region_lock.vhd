-- sim/tb_seq_region_lock.vhd
-- Testbench for rtl/seq_region_lock.vhd.
--
-- IT IS DRIVEN BY THE REAL TABLE.  The stimulus is the same 491-descriptor
-- Qwen3.5-9B token that `tb_seq_desc_fetch` walks, decoded here into the
-- (produces, consumes, releases) triple the lock actually needs.  A synthetic
-- sequence of a dozen lock operations would verify the state machine and
-- nothing about whether the SCHEDULE satisfies it, and the schedule is where
-- the interesting failure lives: this testbench is what showed that D section
-- 5.3's release rule contradicts D section 4.2's own step table, because XN is
-- read by six consecutive A jobs and the first of them would have freed it.
--
-- THE CONCURRENCY, AND HOW EACH PRODUCER IS SKEWED INDEPENDENTLY.  There are
-- three streams here and the point of the generics is that none of them is
-- tied to the others:
--
--   WR_GAP     how fast the producing unit emits write strobes.  A slow
--              producer never finishes its region before its `done`; a fast
--              one finishes early and then sits idle.
--   WR_TAIL    how many write strobes arrive AFTER the producer's `done`.
--              This is the hazard D section 8.2 is about -- "a unit's `done`
--              does NOT imply its AXI transactions have retired" -- and it is
--              the class that broke `axi_rd_port` on its first simulation.
--              It is the reason the write gate keys on the committed job
--              rather than only on the lock state.
--   XW_AT      a rogue exponent write aimed at a region while a consumer
--              holds it.  This is hazard A3, the NEW finding of the skeleton
--              spec: the lock freezes a region's DATA and nothing in D
--              section 5.3 or 5.4 freezes its EXPONENT, which the consumer
--              reads for the whole of its job.
--   JOB_LAT    how long each step takes, which sets how far the write stream
--              and the exponent stream drift relative to the lock's own
--              commit/complete edges.
--
-- With all three at their "tidy" settings -- writes finishing early, no tail,
-- no rogue exponent -- every configuration passes and none of the three
-- mechanisms is tested.  That is the same shape as the head-emit testbench
-- reporting zero refused columns because one process fed both producers.
--
-- WHAT IS ASSERTED
--   1. The whole token walks with `iss_ok` high on every step.  A single
--      rejection is a schedule/lock disagreement and is reported with the step
--      index, the opcode and the offending region.
--   2. Exponent VALUES: every consumer reads back exactly the exponent the
--      producer of that region segment reported at ITS done, for every one of
--      the 491 steps.  This is O15 -- "never a shared or stale value" -- as a
--      checked property.  The reference is kept in the testbench, independent
--      of the DUT's registers.
--   3. Every illegal write is dropped AND reported, never one without the
--      other.  A silent drop is worse than no check.
--   4. Region capacity is never exceeded and `fill_ptr` is append-only.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.seq_tbl_pkg.all;

entity tb_seq_region_lock is
  generic(
    -- ---- independent skew of the three streams -------------------------
    JOB_LAT : natural := 12;   -- cycles from commit to completion
    WR_GAP  : natural := 0;    -- idle cycles between write strobes
    WR_N    : natural := 6;    -- write strobes emitted per producing job
    WR_TAIL : natural := 0;    -- extra strobes emitted AFTER the completion
    XW_AT   : integer := -1;   -- step at which a rogue exponent write is aimed
                               -- at a region the running step HOLDS
    -- ---- fault injection ------------------------------------------------
    BAD_OFF_AT  : integer := -1;  -- step whose dst_offset is corrupted
    BAD_CONS_AT : integer := -1;  -- step that consumes a region nobody produced
    -- A step whose row count overruns the destination region.  Separate from
    -- BAD_OFF_AT on purpose: at step 4 (the wqkv v slice, offset 4096 of an
    -- 8192-entry QKV) an offset off by one ALSO overruns the region, so the
    -- capacity check masks the append-only check and a mutation that removed
    -- append-only survived.  Two checks that reject the same stimulus test as
    -- one check.
    BAD_ROWS_AT : integer := -1;
    HEARTBEAT   : natural := 0;
    STRICT      : boolean := false;
    MAXCYC      : natural := 4000000
  );
end entity;

architecture sim of tb_seq_region_lock is

  constant NREG   : natural := NREGION;
  constant ADDR_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant SEGS   : positive := 3;
  constant SIZES  : integer_vector := region_sizes;

  constant TBL : tbl_t := build_table;

  -- ---- the decoded step plan -------------------------------------------
  -- This is D-ctrl's opcode-to-region decode, which does not exist in RTL yet
  -- (it is the piece between `seq_desc_fetch`'s decoded descriptor and this
  -- unit's issue port).  Written here so that what the lock is asked to do is
  -- derived from the real table rather than invented.
  type step_t is record
    opcode : natural;
    prod   : std_logic;
    dst    : natural;               -- NREG = produces nothing
    seg    : natural;
    off    : natural;
    rows   : natural;
    cons   : std_logic_vector(NREG-1 downto 0);
    rel    : std_logic_vector(NREG-1 downto 0);
  end record;
  type plan_t is array (0 to TBL_STEPS) of step_t;   -- +1 for the host X write

  -- Region byte out of descriptor word 0.
  function fld(w : std_logic_vector(63 downto 0); hi, lo : natural)
    return natural is
    variable r : unsigned(hi-lo downto 0);
  begin
    r := unsigned(w(hi downto lo));
    return to_integer(r);
  end function;

  -- Decode one descriptor into what the lock must be told, then run a
  -- liveness pass to fill in the release masks.  The liveness rule is the one
  -- a host generator would use: a region is released by the LAST step that
  -- consumes it before the next step that re-produces it from scratch.  A
  -- region with no later producer -- X, the residual stream, which is only
  -- ever updated in place -- is never released and lives for the token.
  function build_plan return plan_t is
    variable p    : plan_t;
    variable d0, d1, d3 : std_logic_vector(63 downto 0);
    variable op, src, src2, dst, off, rows : natural;
    variable i, j : integer;
    variable nxt  : integer;
  begin
    -- Step 0: the host writes the embedding row into X (D section 3.2).  The
    -- token cannot start without it, and modelling it is what makes X VALID
    -- for the first norm.
    p(0) := (opcode => 255, prod => '1', dst => R_X, seg => 0, off => 0,
             rows => HID, cons => (others => '0'), rel => (others => '0'));

    for s in 0 to TBL_STEPS-1 loop
      d0 := TBL(s*8 + 0);
      d1 := TBL(s*8 + 1);
      d3 := TBL(s*8 + 3);
      op   := fld(d0, 7, 0);
      src  := fld(d0, 23, 16);
      dst  := fld(d0, 31, 24);
      off  := fld(d0, 63, 32);
      rows := fld(d1, 31, 0);
      src2 := fld(d3, 55, 48);

      p(s+1).opcode := op;
      p(s+1).cons   := (others => '0');
      p(s+1).rel    := (others => '0');
      p(s+1).off    := off;
      p(s+1).rows   := rows;
      p(s+1).seg    := 0;

      if dst < NREG then
        p(s+1).prod := '1';
        p(s+1).dst  := dst;
        -- QKV is the one region with three exponent segments, one per wqkv
        -- job, because the whole reason for the three-way split is that q, k
        -- and v have no reason to share a scale.
        if dst = R_QKV then
          if    off = 0             then p(s+1).seg := 0;
          elsif off = KEY_DIM       then p(s+1).seg := 1;
          else                           p(s+1).seg := 2;
          end if;
        end if;
      else
        p(s+1).prod := '0';
        p(s+1).dst  := NREG;
      end if;

      case op is
        when OP_B_JOB =>
          -- B reads the four regions the six A jobs of the mixer filled.
          p(s+1).cons(R_QKV)   := '1';
          p(s+1).cons(R_Z)     := '1';
          p(s+1).cons(R_BETA)  := '1';
          p(s+1).cons(R_ALPHA) := '1';
        when OP_C_JOB =>
          p(s+1).cons(R_QG)  := '1';
          p(s+1).cons(R_KIN) := '1';
          p(s+1).cons(R_VIN) := '1';
        when OP_END_TOKEN =>
          p(s+1).prod := '0';
          p(s+1).dst  := NREG;
        when others =>
          if src < NREG  then p(s+1).cons(src)  := '1'; end if;
          if src2 < NREG then p(s+1).cons(src2) := '1'; end if;
      end case;
    end loop;

    -- Liveness pass.
    for r in 0 to NREG-1 loop
      i := 0;
      while i <= TBL_STEPS loop
        if p(i).cons(r) = '1' then
          -- find the next step that re-produces r from scratch
          nxt := -1;
          j := i + 1;
          while j <= TBL_STEPS loop
            if p(j).prod = '1' and p(j).dst = r and p(j).cons(r) = '0' then
              nxt := j; exit;
            end if;
            j := j + 1;
          end loop;
          if nxt < 0 then
            i := TBL_STEPS + 1;      -- lives to the end of the token
          else
            -- the last consumer strictly before nxt releases it
            j := nxt - 1;
            while j > 0 and p(j).cons(r) = '0' loop
              j := j - 1;
            end loop;
            if p(j).cons(r) = '1' then
              p(j).rel(r) := '1';
            end if;
            i := nxt;
          end if;
        else
          i := i + 1;
        end if;
      end loop;
    end loop;

    return p;
  end function;

  constant PLAN : plan_t := build_plan;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  signal iss_req, iss_commit, iss_prod : std_logic := '0';
  signal iss_dst  : unsigned(7 downto 0) := (others => '0');
  signal iss_seg  : unsigned(1 downto 0) := (others => '0');
  signal iss_off, iss_n_rows : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal iss_cons, iss_rel : std_logic_vector(NREG-1 downto 0) := (others => '0');
  signal iss_ok   : std_logic;
  signal iss_code : std_logic_vector(3 downto 0);

  signal cmp_valid : std_logic := '0';
  signal cmp_y_exp : signed(EXP_W-1 downto 0) := (others => '0');

  signal wr_we   : std_logic := '0';
  signal wr_region : unsigned(7 downto 0) := (others => '0');
  signal wr_gate : std_logic;
  signal xw_we   : std_logic := '0';
  signal xw_region : unsigned(7 downto 0) := (others => '0');
  signal xw_seg  : unsigned(1 downto 0) := (others => '0');
  signal xw_exp  : signed(EXP_W-1 downto 0) := (others => '0');
  signal xw_gate : std_logic;

  signal exp_rd_region : unsigned(7 downto 0) := (others => '0');
  signal exp_rd_seg    : unsigned(1 downto 0) := (others => '0');
  signal exp_rd_data   : signed(EXP_W-1 downto 0);
  signal exp_rd_valid  : std_logic;

  signal lock_state : std_logic_vector(2*NREG-1 downto 0);
  signal viol       : std_logic;
  signal viol_ack   : std_logic := '0';
  signal viol_code  : std_logic_vector(3 downto 0);
  signal viol_region: unsigned(7 downto 0);

  -- ---- observation ------------------------------------------------------
  signal n_drop_seen : natural := 0;   -- writes the gate refused
  signal n_unreported: natural := 0;   -- drops with no `viol` behind them
  signal cur_step    : integer := -1;
  signal drop_d      : std_logic := '0';
  signal fail        : natural := 0;

  -- The independent exponent reference.  Not read from the DUT.
  type ref_arr is array (0 to NREG*SEGS-1) of integer;
  signal exp_ref : ref_arr := (others => -9999);

begin

  clk <= not clk after 0.5 ns when running else '0';

  cyc_p : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_seq_region_lock: cycle cap reached, the run is wedged"
        severity failure;
    end if;
  end process;

  dut : entity work.seq_region_lock
    generic map(REG_SIZE => SIZES, SEGS => SEGS, ADDR_W => ADDR_W,
                EXP_W => EXP_W, STRICT => STRICT)
    port map(
      clk => clk, rst => rst,
      iss_req => iss_req, iss_commit => iss_commit, iss_prod => iss_prod,
      iss_dst => iss_dst, iss_seg => iss_seg, iss_off => iss_off,
      iss_n_rows => iss_n_rows, iss_cons => iss_cons, iss_rel => iss_rel,
      iss_ok => iss_ok, iss_code => iss_code,
      cmp_valid => cmp_valid, cmp_y_exp => cmp_y_exp,
      wr_we => wr_we, wr_region => wr_region, wr_gate => wr_gate,
      xw_we => xw_we, xw_region => xw_region, xw_seg => xw_seg,
      xw_exp => xw_exp, xw_gate => xw_gate,
      exp_rd_region => exp_rd_region, exp_rd_seg => exp_rd_seg,
      exp_rd_data => exp_rd_data, exp_rd_valid => exp_rd_valid,
      lock_state => lock_state,
      viol => viol, viol_ack => viol_ack, viol_code => viol_code,
      viol_region => viol_region);

  -- ======================================================================
  -- Drop / violation accounting.  A dropped write with no violation, or a
  -- violation with no drop, is itself a failure: a silent drop is worse than
  -- no check, and a violation without a drop means data got through that was
  -- reported as blocked.
  -- ======================================================================
  -- The invariant is NOT that the two counts are equal.  `viol` deliberately
  -- keeps the FIRST offender and does not overwrite it, so a burst of late
  -- writes produces many drops and one report -- which is the intended
  -- behaviour, because the last symptom is not the cause.  The invariant that
  -- matters is that no drop is ever SILENT: after any dropped strobe, `viol`
  -- must be asserted on the next cycle.  Getting this wrong the other way
  -- round is what the first run of this testbench did, and it failed a correct
  -- design.
  drops : process(clk) is
    variable dropped : boolean;
  begin
    if rising_edge(clk) and rst = '0' then
      dropped := (wr_we = '1' and wr_gate = '0')
              or (xw_we = '1' and xw_gate = '0');
      if dropped then
        n_drop_seen <= n_drop_seen + 1;
      end if;
      if drop_d = '1' and viol = '0' then
        n_unreported <= n_unreported + 1;
      end if;
      if dropped then drop_d <= '1'; else drop_d <= '0'; end if;
    end if;
  end process;

  hb : process(clk) is
  begin
    if rising_edge(clk) and HEARTBEAT > 0 then
      if (cyc mod HEARTBEAT) = 0 and cyc > 0 then
        report "HB cyc=" & integer'image(cyc)
             & " step=" & integer'image(cur_step)
             & " locks=" & integer'image(to_integer(unsigned(lock_state)))
             & " viol=" & std_logic'image(viol)
             & " drops=" & integer'image(n_drop_seen);
      end if;
    end if;
  end process;

  -- ======================================================================
  -- The walk.
  -- ======================================================================
  main : process is
    variable slot   : integer;
    variable expect_bad : boolean;
    variable held_r : integer;
    variable nviol  : natural := 0;
    variable ndrop  : natural := 0;

    procedure err(msg : string) is
    begin
      report "tb_seq_region_lock: " & msg severity error;
      fail <= fail + 1;
    end procedure;
  begin
    report "tb_seq_region_lock: table = " & integer'image(TBL_STEPS)
         & " descriptors + 1 host X write, " & integer'image(NREG)
         & " regions, skew JOB_LAT=" & integer'image(JOB_LAT)
         & " WR_GAP=" & integer'image(WR_GAP)
         & " WR_N=" & integer'image(WR_N)
         & " WR_TAIL=" & integer'image(WR_TAIL)
         & " XW_AT=" & integer'image(XW_AT);

    rst <= '1';
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    expect_bad := (BAD_OFF_AT >= 0) or (BAD_CONS_AT >= 0) or (XW_AT >= 0)
               or (BAD_ROWS_AT >= 0);

    for s in 0 to TBL_STEPS loop
      cur_step <= s;

      -- ---- present the step and read the verdict -----------------------
      iss_prod   <= PLAN(s).prod;
      if PLAN(s).dst < NREG then
        iss_dst <= to_unsigned(PLAN(s).dst, 8);
      else
        iss_dst <= x"FF";
      end if;
      iss_seg    <= to_unsigned(PLAN(s).seg, 2);
      if BAD_OFF_AT = s then
        -- An offset that is not the region's fill pointer.  Append-only is
        -- the invariant that makes overlapping sub-writes -- the three wqkv
        -- segments landing on top of each other -- inexpressible.
        iss_off <= to_unsigned(PLAN(s).off + 1, ADDR_W);
      else
        iss_off <= to_unsigned(PLAN(s).off, ADDR_W);
      end if;
      -- `iss_n_rows` is REGION-SCOPED: it is how many elements land in the
      -- destination region, so it is bounded by the largest region (12,288 at
      -- 9B, 17,408 at 27B) and not by the job's output row count.  lm_head
      -- emits 248,320 rows and has NO destination region -- it streams to the
      -- sampler -- so passing its row count here truncates at ADDR_W and means
      -- nothing.  Caught as a `TO_UNSIGNED: vector truncated` warning on the
      -- first run; the fix is to say zero, not to widen the port.
      if BAD_ROWS_AT = s and PLAN(s).dst < NREG then
        iss_n_rows <= to_unsigned(SIZES(SIZES'low + PLAN(s).dst), ADDR_W) + 1;
      elsif PLAN(s).dst < NREG then
        iss_n_rows <= to_unsigned(PLAN(s).rows, ADDR_W);
      else
        iss_n_rows <= (others => '0');
      end if;
      if BAD_CONS_AT = s then
        -- Consume a region nobody has produced.  ALPHA is free during the
        -- attention blocks, so this is a real "read what was never written".
        iss_cons <= PLAN(s).cons or std_logic_vector(
                      to_unsigned(2**R_ALPHA, NREG));
      else
        iss_cons <= PLAN(s).cons;
      end if;
      iss_rel  <= PLAN(s).rel;
      iss_req  <= '1';
      wait until rising_edge(clk);
      iss_req <= '0';

      -- A corrupted step that is NOT rejected is a silent acceptance, and the
      -- first version of this loop did not check for it: it handled "rejected
      -- as intended" and "unexpectedly rejected" and simply fell through the
      -- third case.  Two mutations survived on exactly that gap.
      if iss_ok = '1' and ((BAD_OFF_AT = s) or (BAD_CONS_AT = s)
                           or (BAD_ROWS_AT = s)) then
        err("step " & integer'image(s) & " was deliberately corrupted ("
          & "offset off by one, or consuming a region nobody produced) and "
          & "was ACCEPTED.  The check does not exist or does not cover it.");
        exit;
      end if;

      if iss_ok = '0' then
        if (BAD_OFF_AT = s) or (BAD_CONS_AT = s) or (BAD_ROWS_AT = s) then
          report "  ok  step " & integer'image(s) & " REJECTED as intended, code "
               & integer'image(to_integer(unsigned(iss_code)));
          exit;
        else
          err("step " & integer'image(s) & " (opcode "
            & integer'image(PLAN(s).opcode) & ", dst "
            & integer'image(PLAN(s).dst) & ", off "
            & integer'image(PLAN(s).off) & ") was REJECTED with code "
            & integer'image(to_integer(unsigned(iss_code)))
            & ".  The schedule and the lock model disagree.");
          exit;
        end if;
      end if;

      -- ---- commit ------------------------------------------------------
      iss_commit <= '1';
      wait until rising_edge(clk);
      iss_commit <= '0';

      -- SCRAMBLE THE LIVE ISSUE PORTS.  This is what a real sequencer does:
      -- once a step is committed it moves on to fetching and checking the
      -- next descriptor, so `iss_*` describes something else for the whole of
      -- the job.  Leaving them stable -- which the first version of this
      -- testbench did -- makes "read the latched job" and "read the live
      -- port" indistinguishable, and a mutation that swapped one for the
      -- other survived every configuration.  That is defect class (a) in the
      -- STIMULUS: the testbench was holding a value the real producer would
      -- have moved on from.
      iss_prod   <= '0';
      iss_dst    <= x"FF";
      iss_seg    <= "00";
      iss_off    <= (others => '1');
      iss_n_rows <= (others => '1');
      iss_cons   <= (others => '0');
      iss_rel    <= (others => '0');

      -- ---- the write stream, running concurrently with the job ---------
      -- Every strobe is checked: a legal one must be gated through, and the
      -- gate must never stall (it has no way to -- A's y port has no ready).
      for w in 0 to WR_N-1 loop
        if PLAN(s).prod = '1' then
          wr_we     <= '1';
          wr_region <= to_unsigned(PLAN(s).dst, 8);
          wait until rising_edge(clk);
          if wr_gate = '0' then
            err("a LEGAL write into region " & integer'image(PLAN(s).dst)
              & " at step " & integer'image(s) & " was dropped");
          end if;
          wr_we <= '0';
          for g in 1 to WR_GAP loop wait until rising_edge(clk); end loop;
        end if;
      end loop;

      -- ---- the rogue exponent write, hazard A3 -------------------------
      -- Aimed at a region this step HOLDS, i.e. one a consumer is reading
      -- right now.  D section 5.3 protects that region's DATA and says
      -- nothing about its exponent; the consumer reads the exponent for the
      -- whole of its job, so it has the same live window and needs the same
      -- protection.  The check is that it is DROPPED, and that the reference
      -- exponent for that slot is therefore unchanged afterwards.
      if XW_AT = s then
        held_r := -1;
        for r in 0 to NREG-1 loop
          if PLAN(s).cons(r) = '1' and not (PLAN(s).prod = '1'
                                            and PLAN(s).dst = r) then
            held_r := r;
          end if;
        end loop;
        if held_r >= 0 then
          xw_we     <= '1';
          xw_region <= to_unsigned(held_r, 8);
          xw_seg    <= "00";
          xw_exp    <= to_signed(-777, EXP_W);
          wait until rising_edge(clk);
          if xw_gate = '1' then
            err("hazard A3: an exponent write into region "
              & integer'image(held_r) & ", which is HELD by the step reading "
              & "it, was ALLOWED.  The exponent register is not part of the "
              & "locked object.");
          else
            report "  ok  step " & integer'image(s)
                 & ": exponent write into HELD region "
                 & integer'image(held_r) & " was dropped (hazard A3)";
          end if;
          xw_we <= '0';
        end if;
      end if;

      -- ---- run out the job latency -------------------------------------
      for l in 1 to JOB_LAT loop wait until rising_edge(clk); end loop;

      -- ---- completion, and the exponent capture ------------------------
      -- The exponent is only final at `done`, which is why the capture
      -- instant is here.  A value derived from the step index so that a
      -- stale or shared capture is a WRONG NUMBER and not merely a repeat.
      cmp_y_exp <= to_signed(((s * 7) mod 61) - 30, EXP_W);
      cmp_valid <= '1';
      if PLAN(s).prod = '1' and PLAN(s).dst < NREG then
        slot := PLAN(s).dst*SEGS + PLAN(s).seg;
        exp_ref(slot) <= ((s * 7) mod 61) - 30;
      end if;
      wait until rising_edge(clk);
      cmp_valid <= '0';

      -- ---- the write TAIL: strobes that outlive the job ----------------
      -- "A unit's `done` does NOT imply its AXI transactions have retired"
      -- (D section 8.2).  Every one of these must be dropped AND reported.
      for w in 1 to WR_TAIL loop
        if PLAN(s).prod = '1' then
          wr_we     <= '1';
          wr_region <= to_unsigned(PLAN(s).dst, 8);
          wait until rising_edge(clk);
          if wr_gate = '1' then
            err("a write into region " & integer'image(PLAN(s).dst)
              & " AFTER the completion of step " & integer'image(s)
              & " was allowed through.  The job is over; nothing of its may "
              & "still land.");
          end if;
          wr_we <= '0';
        end if;
      end loop;

      -- ---- read back every captured exponent ---------------------------
      -- O15 as a checked property: for every region segment that has been
      -- captured, the DUT must return exactly what the producing job reported
      -- at ITS done.  A shared or stale value is a wrong number here, not a
      -- missing one.
      for r in 0 to NREG-1 loop
        for g in 0 to SEGS-1 loop
          exp_rd_region <= to_unsigned(r, 8);
          exp_rd_seg    <= to_unsigned(g, 2);
          wait until rising_edge(clk);
          if exp_ref(r*SEGS + g) /= -9999 then
            if exp_rd_valid /= '1' then
              err("region " & integer'image(r) & " segment "
                & integer'image(g) & " has been captured but reads invalid");
            elsif to_integer(exp_rd_data) /= exp_ref(r*SEGS + g) then
              err("region " & integer'image(r) & " segment "
                & integer'image(g) & " exponent is "
                & integer'image(to_integer(exp_rd_data)) & ", the producing "
                & "job reported " & integer'image(exp_ref(r*SEGS + g))
                & " (at step " & integer'image(s) & ")");
            end if;
          end if;
        end loop;
      end loop;

      -- ---- drain any violation ----------------------------------------
      if viol = '1' then
        nviol := nviol + 1;
        viol_ack <= '1';
        wait until rising_edge(clk);
        viol_ack <= '0';
      end if;
    end loop;

    ndrop := n_drop_seen;
    report "---- walk finished at step " & integer'image(cur_step)
         & " of " & integer'image(TBL_STEPS)
         & ", violations " & integer'image(nviol)
         & ", drops " & integer'image(ndrop)
         & ", unreported drops " & integer'image(n_unreported) & " ----";

    -- No drop may be silent.
    if n_unreported /= 0 then
      err(integer'image(n_unreported) & " dropped write(s) were not followed "
        & "by `viol`.  A silent drop looks like a clean run with a wrong "
        & "number in it.");
    end if;
    if ndrop > 0 and nviol = 0 then
      err("writes were dropped but no violation was ever reported");
    end if;

    if not expect_bad then
      if cur_step /= TBL_STEPS then
        err("the walk stopped at step " & integer'image(cur_step)
          & " instead of completing all " & integer'image(TBL_STEPS+1));
      end if;
      if WR_TAIL = 0 and ndrop /= 0 then
        err("a clean walk dropped " & integer'image(ndrop) & " write(s)");
      end if;
      if WR_TAIL > 0 and ndrop = 0 then
        err("WR_TAIL is " & integer'image(WR_TAIL)
          & " but nothing was dropped -- the late-write hazard is not being "
          & "exercised, which is a question about the testbench and not a "
          & "result about the design");
      end if;
    end if;

    wait until rising_edge(clk);
    if fail = 0 then
      report "tb_seq_region_lock: PASS";
    else
      report "tb_seq_region_lock: FAIL -- " & integer'image(fail)
           & " check(s) failed" severity failure;
    end if;
    running <= false;
    wait;
  end process;

end architecture;
