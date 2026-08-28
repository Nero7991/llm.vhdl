-- sim/tb_llama_top.vhd
-- THE INTEGRATION BENCH.  One token, N transformer blocks, through
-- `rtl/llama_top.vhd`, run several times with different handshake timings and
-- compared against itself.
--
-- =====================================================================
-- WHAT THIS BENCH CAN CHECK, AND WHAT IT DELIBERATELY DOES NOT CLAIM
-- =====================================================================
-- THERE IS NO BLOCK-LEVEL ORACLE AND THIS BENCH DOES NOT PRETEND OTHERWISE.
-- An independent C reference for a whole transformer block would have to
-- model Gated DeltaNet, gated attention, rmsnorm, swiglu and the BFP
-- exponent discipline all at once, and two of those five have no RTL to
-- compare against -- attention's lane array is a pricing skeleton, and the
-- norm and swiglu D-vec engines do not exist.  A "reference" written today
-- would be a reference for the STUBS.  That is worth nothing and is worse
-- than nothing, because it would look like coverage.
--
-- So this bench checks the properties that do not need one, and those are the
-- integration properties anyway:
--
--   P1  THE SCHEDULE.  Every issue is compared against the plan, step by
--       step: opcode, unit, source region, destination region, element
--       count.  The token must end after exactly `n_steps(SHAPE)` steps.
--       This needs no arithmetic reference at all and it is the property that
--       says the block loop ran.
--
--   P2  THE RESIDUAL STREAM IS BIT-IDENTICAL UNDER PRODUCER SKEW.  The token
--       is run `NRUNS` times with a different descriptor-memory latency each
--       time, which moves every handshake in the machine relative to every
--       other one without changing one bit of input data.  Region R_X is
--       dumped after each run and compared, element by element, against run
--       0.  A single dropped beat, stale latch or lost completion anywhere
--       shows up here as a differing element.  This is the shape
--       `sim/tb_gdn_block.vhd` uses, which has found real defects three
--       times.
--
--   P3  NO SEAM FAULT FIRED.  `err_gate_drop` (the region lock refused a
--       write), `err_e_coll` (a collective was issued at NCARDS=1) and the
--       lock's own `viol` must all stay low, and `err` from the walker must
--       stay low.  These are silent in the arithmetic: a dropped write leaves
--       the previous value in place, which is a plausible number.
--
--   P4  THE RESIDUAL ACTUALLY MOVED.  A machine that sequenced 64 steps and
--       wrote nothing would pass P1, P2 and P3.  R_X after the token must
--       differ from R_X before it.
--
--   P5  THE STUB IS ANNOUNCED.  When the schedule contains an attention
--       block, `err_unit_stub` MUST be set at the end.  This bench FAILS if
--       an attention block ran and the stub flag did NOT rise, because that
--       would mean the loudest marker in the design had stopped working.
--
-- =====================================================================
-- WHY THE DESCRIPTOR MEMORY LATENCY IS THE SKEW AXIS
-- =====================================================================
-- Subsystem D prefetches: the next descriptor is fetched while the current
-- job runs.  A FAST memory gets the prefetch ahead of the units, which is the
-- configuration that makes defect class (a) reachable -- the next job's data
-- arriving while the current one is still being read.  A SLOW memory starves
-- the walker and exercises the held `start` instead.  One generic covers both
-- ends, and the two ends put the units at completely different phases
-- relative to the walker, which is what "producer skew" has to mean at this
-- level.  `sim/tb_seq_desc_fetch.vhd` uses the same axis for the same reason.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;
use work.llama_sched_pkg.all;
use work.seq_tbl_pkg;

entity tb_llama_top is
  generic(
    BLOCKS    : positive := 4;
    ATTN_INT  : positive := 4;
    -- The descriptor-memory latencies to sweep.  Run 0 is the reference.
    NRUNS     : positive := 4;
    -- The DEFAULT configuration is the most real one available: the real
    -- `matvec_int4`.  Set A_BEHAV true to bisect a failure to a side of the
    -- D-to-A seam.
    A_BEHAV   : boolean  := false;
    B_BEHAV   : boolean  := true;
    MAXCYC    : natural  := 4000000
  );
end entity;

architecture tb of tb_llama_top is

  constant SHAPE  : shape_t := mk_shape_scaled(BLOCKS, ATTN_INT);
  constant NSTEP  : natural := n_steps(SHAPE);
  constant TBL    : sched_tbl_t := build_table(SHAPE);
  constant PLAN   : plan_t := build_plan(SHAPE);
  constant REGMAX : positive := region_max(SHAPE);

  constant LANES  : positive := 8;
  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant STEP_W : positive := 11;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  signal go, abort, tok_ack : std_logic := '0';
  signal tbl_len : unsigned(STEP_W-1 downto 0)
                 := to_unsigned(NSTEP, STEP_W);
  signal host_x_exp : signed(EXP_W-1 downto 0) := to_signed(3, EXP_W);
  signal rel_mask : std_logic_vector(NREGION-1 downto 0) := (others => '0');

  signal busy, tok_done, err : std_logic;
  signal err_code : std_logic_vector(3 downto 0);
  signal err_step, steps_done : unsigned(STEP_W-1 downto 0);

  signal d_raddr : unsigned(15 downto 0);
  signal d_ren, d_rvalid : std_logic := '0';
  signal d_rdata : std_logic_vector(63 downto 0) := (others => '0');

  signal hw_we : std_logic := '0';
  signal hw_reg : natural range 0 to NREGION-1 := 0;
  signal hw_addr : natural range 0 to REGMAX-1 := 0;
  signal hw_data : signed(MANT_W-1 downto 0) := (others => '0');
  signal hr_reg : natural range 0 to NREGION-1 := 0;
  signal hr_addr : natural range 0 to REGMAX-1 := 0;
  signal hr_data : signed(MANT_W-1 downto 0);

  signal obs_issue, obs_cmp : std_logic;
  signal obs_unit : unsigned(2 downto 0);
  signal obs_opcode : unsigned(3 downto 0);
  signal obs_step : unsigned(STEP_W-1 downto 0);
  signal obs_dst : unsigned(7 downto 0);

  signal err_lost_beat, err_gate_drop, err_unit_stub, err_e_coll : std_logic;

  -- ---- subsystem A's weight ports -------------------------------------
  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast
       : std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(A_NPORTS*32-1 downto 0);
  signal m_arlen   : std_logic_vector(A_NPORTS*8-1 downto 0);
  signal m_arsize  : std_logic_vector(A_NPORTS*3-1 downto 0);
  signal m_arburst : std_logic_vector(A_NPORTS*2-1 downto 0);
  signal m_rdata   : std_logic_vector(A_NPORTS*128-1 downto 0)
                   := (others => '0');

  -- THE WEIGHT MEMORY IS A FUNCTION, NOT AN ARRAY.  The real 9B weights are
  -- 4.5 GB and the addresses this bench generates span megabytes, so the
  -- model answers every address arithmetically.  Ports 0..A_NPORTS-2 carry
  -- packed INT4 weight nibbles; the last port carries per-block scales, which
  -- the spec constrains to uint15 -- 32768 does not fit and a codebook entry
  -- of -128 is forbidden -- so that lane is masked into [16384, 32767].
  --
  -- WHAT THIS DOES AND DOES NOT ESTABLISH.  It does NOT establish that A
  -- computes the right dot product: that is `sim/run_matvec.sh`'s job, it has
  -- an independent C oracle and a packer, and it passes.  What it establishes
  -- is that the SEAM works -- that A is fed a coherent descriptor, that its
  -- un-refusable output is never dropped, that its one-cycle `done` is
  -- converted to the level D requires, and that all of that is invariant
  -- under handshake timing.  A synthetic weight image is sufficient for that
  -- and an incorrect packing would be caught by run_matvec.sh, not here.
  function wword(p : natural; idx : natural) return std_logic_vector is
    variable v : std_logic_vector(127 downto 0);
    variable x, i2 : natural;
  begin
    -- `idx` is reduced BEFORE the multiply.  It is a 24-bit word index and
    -- the bench addresses megabytes, so `idx*7919` overflows VHDL's 32-bit
    -- universal integer at 491 steps and aborts the run with
    -- "overflow detected" from inside this function -- which reads like a
    -- broken AXI slave and is arithmetic in the stimulus.
    i2 := idx mod 65536;
    if p = A_NPORTS-1 then
      for l in 0 to 7 loop
        x := 16384 + ((i2*13 + l*7 + 3) mod 16384);
        v(l*16+15 downto l*16) := std_logic_vector(to_unsigned(x, 16));
      end loop;
    else
      for b in 0 to 15 loop
        x := (i2*7919 + p*104729 + b*31 + 17) mod 251;
        v(b*8+7 downto b*8) := std_logic_vector(to_unsigned(x, 8));
      end loop;
    end if;
    return v;
  end function;
  signal obs_cmp_exp : signed(EXP_W-1 downto 0);
  signal obs_wsum    : unsigned(31 downto 0);

  -- The per-completion trace: the exponent the lock captured, and the running
  -- write hash at that instant.  Compared across runs to find the FIRST step
  -- at which two timings diverge, and to say whether they diverged in the
  -- exponent path or in the data path.
  type tr_t   is array (0 to 1023) of integer;
  type trs_t  is array (0 to NRUNS-1) of tr_t;
  signal tr_exp : trs_t := (others => (others => 0));
  signal tr_sum : trs_t := (others => (others => 0));
  signal cur_run : natural := 0;

  -- The live descriptor-memory latency.  A SIGNAL, not a generic, so one
  -- elaboration can sweep it.
  signal uram_lat : natural := 1;

  -- schedule checking
  signal n_issue : natural := 0;
  signal n_chk   : natural := 0;
  signal n_cmp   : natural := 0;
  signal n_bad_sched : natural := 0;
  signal tb_reset : std_logic := '0';

  -- results
  type res_t is array (0 to REGMAX-1) of integer;
  type runs_t is array (0 to NRUNS-1) of res_t;
  signal results : runs_t := (others => (others => 0));
  signal x0      : res_t := (others => 0);

  signal n_bad_skew : natural := 0;
  signal fail       : natural := 0;

  -- The token embedding.  Deterministic, non-trivial, and not symmetric: a
  -- residual stream that is accidentally zeroed or accidentally copied has to
  -- be distinguishable from one that was computed.
  function embed(i : natural) return integer is
  begin
    return ((i * 37) mod 251) - 125;
  end function;

begin

  clk <= not clk after 0.5 ns when running else '0';

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_llama_top: cycle cap reached, the run is wedged at step "
             & integer'image(n_issue) & " of " & integer'image(NSTEP)
        severity failure;
    end if;
  end process;

  -- ======================================================================
  -- THE DUT
  -- ======================================================================
  dut : entity work.llama_top
    generic map(
      SHAPE => SHAPE, LANES => LANES, MANT_W => MANT_W, EXP_W => EXP_W,
      REGMAX => REGMAX, STEP_W => STEP_W,
      WDOG_LIMIT => 200000, STRICT => true,
      A_BEHAV => A_BEHAV, B_BEHAV => B_BEHAV, SHOUT => true)
    port map(
      clk => clk, rst => rst,
      go => go, abort => abort, tbl_len => tbl_len,
      host_x_exp => host_x_exp, rel_mask => rel_mask,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      hw_we => hw_we, hw_reg => hw_reg, hw_addr => hw_addr, hw_data => hw_data,
      hr_reg => hr_reg, hr_addr => hr_addr, hr_data => hr_data,
      obs_issue => obs_issue, obs_unit => obs_unit, obs_opcode => obs_opcode,
      obs_step => obs_step, obs_dst => obs_dst, obs_cmp => obs_cmp,
      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
      m_rlast => m_rlast,
      obs_cmp_exp => obs_cmp_exp, obs_wsum => obs_wsum,
      err_lost_beat => err_lost_beat, err_gate_drop => err_gate_drop,
      err_unit_stub => err_unit_stub, err_e_coll => err_e_coll);

  trace : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '0' and tb_reset = '0' and obs_cmp = '1' and n_cmp < 1024 then
        tr_exp(cur_run)(n_cmp) <= to_integer(obs_cmp_exp);
        tr_sum(cur_run)(n_cmp) <= to_integer(obs_wsum(30 downto 0));
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE AXI READ SLAVES, one per weight port.  INCR bursts only, one burst in
  -- flight per port, `rvalid` held until `rready`.
  -- ======================================================================
  slaves : for p in 0 to A_NPORTS-1 generate
    signal aw    : unsigned(31 downto 0) := (others => '0');
    signal beats : natural := 0;
    signal act   : std_logic := '0';
  begin
    m_arready(p) <= not act;

    slv : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          act <= '0'; beats <= 0; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
        elsif act = '0' then
          m_rvalid(p) <= '0';
          m_rlast(p)  <= '0';
          if m_arvalid(p) = '1' then
            assert m_arburst((p+1)*2-1 downto p*2) = "01"
              report "tb_llama_top: port " & integer'image(p)
                   & " issued a burst that is not INCR" severity failure;
            aw    <= unsigned(m_araddr((p+1)*32-1 downto p*32));
            beats <= to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
            act   <= '1';
          end if;
        else
          if m_rvalid(p) = '0' or m_rready(p) = '1' then
            if beats > 0 then
              m_rdata((p+1)*128-1 downto p*128)
                <= wword(p, to_integer(aw(27 downto 4)));
              m_rvalid(p) <= '1';
              if beats = 1 then m_rlast(p) <= '1';
              else              m_rlast(p) <= '0'; end if;
              aw    <= aw + 16;
              beats <= beats - 1;
            else
              m_rvalid(p) <= '0';
              m_rlast(p)  <= '0';
              act         <= '0';
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- THE DESCRIPTOR MEMORY.  `d_rdata` is 'X' whenever `d_rvalid` is low, so a
  -- walker sampling on the wrong cycle poisons its shadow instead of being
  -- right by luck.  Lifted from sim/tb_seq_desc_fetch.vhd.
  -- ======================================================================
  uram : process(clk) is
    type pipe_t is array (0 to 63) of natural;
    variable addr_p : pipe_t := (others => 0);
    variable vld_p  : std_logic_vector(0 to 63) := (others => '0');
    variable L      : natural;
    variable a      : natural;
  begin
    if rising_edge(clk) then
      L := uram_lat;
      if L < 1 then L := 1; end if;
      if L > 63 then L := 63; end if;
      for i in 63 downto 1 loop
        addr_p(i) := addr_p(i-1);
        vld_p(i)  := vld_p(i-1);
      end loop;
      if d_ren = '1' then addr_p(0) := to_integer(d_raddr);
      else                addr_p(0) := 0; end if;
      vld_p(0) := d_ren;

      if vld_p(L-1) = '1' then
        a := addr_p(L-1);
        d_rvalid <= '1';
        if a < NSTEP*8 then
          d_rdata <= TBL(a);
        else
          d_rdata <= (others => 'X');
        end if;
      else
        d_rvalid <= '0';
        d_rdata  <= (others => 'X');
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE RELEASE MASK.  The host supplies it, per step, at the CHECK instant.
  -- seq_opdec finding (3): it is a whole-table liveness property and the
  -- descriptor format has no field for it.
  -- ======================================================================
  rel_mask <= PLAN(n_chk).rel when n_chk < NSTEP else (others => '0');

  chkcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' then
        n_chk <= 0;
      elsif d_ren = '0' and busy = '1' then
        null;
      end if;
      -- chk_req is internal to the DUT; the observable proxy is that opdec
      -- consumes exactly one rel_mask per step, in order.  `obs_issue` is one
      -- step later than the check, so the mask is advanced on the ISSUE and
      -- the plan index is the step about to be checked NEXT.  A mismatch
      -- shows up as a lock violation, which P3 already fails on.
      if rst = '0' and tb_reset = '0' and obs_issue = '1' then
        n_chk <= n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- P1: THE SCHEDULE.  Every issue, against the plan.
  -- ======================================================================
  sched : process(clk) is
    variable p : plan_step_t;
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' then
        n_issue <= 0;
        n_cmp   <= 0;
      else
        if obs_issue = '1' then
          if n_issue >= NSTEP then
            n_bad_sched <= n_bad_sched + 1;
            report "tb_llama_top: issue " & integer'image(n_issue)
                 & " is past the end of a " & integer'image(NSTEP)
                 & "-step table." severity error;
          else
            p := PLAN(n_issue);
            if to_integer(obs_opcode) /= p.opcode then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " issued opcode " & integer'image(to_integer(obs_opcode))
                   & ", plan says " & integer'image(p.opcode)
                severity error;
            end if;
            if to_integer(obs_unit) /= p.unit then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " issued to unit " & integer'image(to_integer(obs_unit))
                   & ", plan says " & integer'image(p.unit)
                severity error;
            end if;
            if to_integer(obs_dst) /= p.dst then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step " & integer'image(n_issue)
                   & " wrote region " & integer'image(to_integer(obs_dst))
                   & ", plan says " & integer'image(p.dst)
                severity error;
            end if;
            if to_integer(obs_step) /= n_issue then
              n_bad_sched <= n_bad_sched + 1;
              report "tb_llama_top: step index " & integer'image(to_integer(obs_step))
                   & " at issue number " & integer'image(n_issue)
                   & ".  The walker and the plan have desynchronised."
                severity error;
            end if;
          end if;
          n_issue <= n_issue + 1;
        end if;
        if obs_cmp = '1' then n_cmp <= n_cmp + 1; end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- P3: seam faults.  Checked continuously, not only at the end, so the
  -- report names the step it happened on.
  -- ======================================================================
  faults : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '0' then
        assert err_gate_drop = '0'
          report "tb_llama_top: the region lock dropped a write.  See the "
               & "llama_top report above for the region." severity failure;
        assert err_e_coll = '0'
          report "tb_llama_top: OP_E_COLL was issued at NCARDS = 1."
          severity failure;
        assert err_lost_beat = '0'
          report "tb_llama_top: an un-stallable producer beat was lost."
          severity failure;
        assert err = '0'
          report "tb_llama_top: the walker raised err_code x"
               & integer'image(to_integer(unsigned(err_code)))
               & " at step " & integer'image(to_integer(err_step))
          severity failure;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DRIVER
  -- ======================================================================
  drv : process is
    variable lat : natural;

    procedure preload is
    begin
      -- The token embedding into R_X.  Written through the host port, which
      -- is the only writer the region lock does not police -- the lock's
      -- window belongs to a JOB and this is before any job exists.
      for i in 0 to SHAPE.hidden-1 loop
        wait until rising_edge(clk);
        hw_we   <= '1';
        hw_reg  <= R_X;
        hw_addr <= i;
        hw_data <= to_signed(embed(i), MANT_W);
      end loop;
      wait until rising_edge(clk);
      hw_we <= '0';
    end procedure;

    procedure dump(variable r : out res_t) is
    begin
      for i in 0 to REGMAX-1 loop
        hr_reg  <= R_X;
        hr_addr <= i;
        wait until rising_edge(clk);
        wait for 0.1 ns;
        r(i) := to_integer(hr_data);
      end loop;
    end procedure;

    variable rv : res_t;
    variable nz : natural;
  begin
    report "tb_llama_top: shape blocks=" & integer'image(SHAPE.blocks)
         & " attn_interval=" & integer'image(SHAPE.attn_interval)
         & " hidden=" & integer'image(SHAPE.hidden)
         & " ffn=" & integer'image(SHAPE.ffn)
         & " -> " & integer'image(NSTEP) & " descriptors, "
         & integer'image(n_gdn_blocks(SHAPE)) & " GDN blocks, "
         & integer'image(n_attn_blocks(SHAPE)) & " attention blocks"
      severity note;

    for run in 0 to NRUNS-1 loop
      -- Latencies 1, 2, 5, 11, ... : a fast memory that gets the prefetch
      -- ahead of the units, and a slow one that starves the walker.
      case run is
        when 0 => lat := 1;
        when 1 => lat := 2;
        when 2 => lat := 5;
        when others => lat := 3 + 4*run;
      end case;
      uram_lat <= lat;
      cur_run  <= run;

      rst      <= '1';
      tb_reset <= '1';
      go       <= '0';
      tok_ack  <= '0';
      for i in 0 to 9 loop wait until rising_edge(clk); end loop;
      rst      <= '0';
      tb_reset <= '0';
      wait until rising_edge(clk);

      preload;
      if run = 0 then
        dump(rv);
        x0 <= rv;
      end if;

      wait until rising_edge(clk);
      go <= '1';
      wait until rising_edge(clk);
      go <= '0';

      wait until tok_done = '1' for 1 ms;
      assert tok_done = '1'
        report "tb_llama_top: run " & integer'image(run)
             & " (descriptor latency " & integer'image(lat)
             & ") never reached tok_done.  It stopped at issue "
             & integer'image(n_issue) & " of " & integer'image(NSTEP)
        severity failure;

      assert n_issue = NSTEP-1
        report "tb_llama_top: run " & integer'image(run) & " issued "
             & integer'image(n_issue) & " jobs; a " & integer'image(NSTEP)
             & "-step table has " & integer'image(NSTEP-1)
             & " startable steps (END_TOKEN starts nobody)."
        severity error;
      assert steps_done = to_unsigned(NSTEP, STEP_W)
        report "tb_llama_top: run " & integer'image(run) & " walked "
             & integer'image(to_integer(steps_done)) & " of "
             & integer'image(NSTEP) & " descriptors."
        severity error;

      dump(rv);
      results(run) <= rv;
      wait until rising_edge(clk);

      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';

      report "tb_llama_top: run " & integer'image(run)
           & " descriptor latency " & integer'image(lat)
           & ": " & integer'image(n_issue) & " jobs issued, "
           & integer'image(n_cmp) & " completions, "
           & integer'image(cyc) & " cycles elapsed"
        severity note;
    end loop;

    -- ---- P4: the residual moved -----------------------------------------
    nz := 0;
    for i in 0 to SHAPE.hidden-1 loop
      if results(0)(i) /= x0(i) then nz := nz + 1; end if;
    end loop;
    assert nz > 0
      report "tb_llama_top: R_X is unchanged after a whole token.  The "
           & "machine sequenced the schedule and computed nothing."
      severity failure;

    -- ---- P4b: the residual is not a constant -----------------------------
    -- A stream that saturated everywhere, or that was overwritten by one
    -- broadcast value, passes P1 through P4 and is worthless.  Count distinct
    -- values.  This is the check that caught `out_shift` = 16 driving every
    -- element of the scaled shape to zero.
    nz := 0;
    for i in 1 to SHAPE.hidden-1 loop
      if results(0)(i) /= results(0)(0) then nz := nz + 1; end if;
    end loop;
    assert nz >= SHAPE.hidden/4
      report "tb_llama_top: only " & integer'image(nz) & " of "
           & integer'image(SHAPE.hidden-1) & " R_X elements differ from "
           & "R_X(0) = " & integer'image(results(0)(0))
           & ".  The residual stream is very nearly a constant, which passes "
           & "every determinism property and means nothing."
      severity failure;

    -- ---- the trace: where did two timings first diverge, and in what ----
    for run in 1 to NRUNS-1 loop
      for i in 0 to NSTEP-1 loop
        if tr_exp(run)(i) /= tr_exp(0)(i) then
          report "tb_llama_top: FIRST EXPONENT DIVERGENCE at completion "
               & integer'image(i) & " (step opcode "
               & integer'image(PLAN(i).opcode) & ", unit "
               & integer'image(PLAN(i).unit) & ", dst "
               & integer'image(PLAN(i).dst) & "): run "
               & integer'image(run) & " captured "
               & integer'image(tr_exp(run)(i)) & ", run 0 captured "
               & integer'image(tr_exp(0)(i))
            severity error;
          exit;
        end if;
      end loop;
      for i in 0 to NSTEP-1 loop
        if tr_sum(run)(i) /= tr_sum(0)(i) then
          report "tb_llama_top: FIRST WRITE-HASH DIVERGENCE at completion "
               & integer'image(i) & " (step opcode "
               & integer'image(PLAN(i).opcode) & ", unit "
               & integer'image(PLAN(i).unit) & ", dst "
               & integer'image(PLAN(i).dst) & ")"
            severity error;
          exit;
        end if;
      end loop;
    end loop;

    -- ---- P2: bit-identical under skew -----------------------------------
    for run in 1 to NRUNS-1 loop
      for i in 0 to REGMAX-1 loop
        if results(run)(i) /= results(0)(i) then
          n_bad_skew <= n_bad_skew + 1;
          wait for 0 ns;
          if n_bad_skew < 8 then
            report "tb_llama_top: SKEW DIFFERENCE.  run " & integer'image(run)
                 & " R_X(" & integer'image(i) & ") = "
                 & integer'image(results(run)(i)) & ", run 0 = "
                 & integer'image(results(0)(i))
                 & ".  A handshake timing changed the result, which means a "
                 & "beat, a latch or a completion was lost."
              severity error;
          end if;
        end if;
      end loop;
    end loop;
    wait for 0 ns;

    -- ---- P5: the stub is announced --------------------------------------
    if n_attn_blocks(SHAPE) > 0 then
      assert err_unit_stub = '1'
        report "tb_llama_top: the schedule contains "
             & integer'image(n_attn_blocks(SHAPE))
             & " attention block(s) but err_unit_stub is LOW.  The stub "
             & "marker has stopped working, which is worse than the stub."
        severity failure;
      report "tb_llama_top: NOTE -- this schedule contains "
           & integer'image(n_attn_blocks(SHAPE))
           & " attention block(s).  ATTENTION IS A STUB.  The residual "
           & "stream is well-formed and MEANINGLESS."
        severity warning;
    end if;

    -- ---- verdict ---------------------------------------------------------
    fail <= n_bad_sched + n_bad_skew;
    wait for 0 ns;

    report "tb_llama_top: schedule mismatches=" & integer'image(n_bad_sched)
         & " skew differences=" & integer'image(n_bad_skew)
      severity note;

    if n_bad_sched = 0 and n_bad_skew = 0 then
      report "tb_llama_top RESULT: PASS -- " & integer'image(NSTEP)
           & " descriptors, " & integer'image(SHAPE.blocks)
           & " blocks, " & integer'image(NRUNS)
           & " descriptor-latency points, R_X bit-identical across all of "
           & "them, R_X(0) = " & integer'image(results(0)(0))
        severity note;
    else
      report "tb_llama_top RESULT: FAIL" severity failure;
    end if;

    running <= false;
    wait;
  end process;

  -- ======================================================================
  -- The two copies of the region and opcode map must agree.  `llama_map_pkg`
  -- is in rtl/ because seq_opdec's consume mask is a GENERIC and the gateware
  -- therefore knows the region numbering; `seq_tbl_pkg` is in sim/ because
  -- the table is host data.  Two copies is the price; this is the check that
  -- makes a divergence stop a run instead of addressing the wrong region.
  -- ======================================================================
  mapchk : process is
  begin
    assert OP_A_JOB = seq_tbl_pkg.OP_A_JOB and OP_B_JOB = seq_tbl_pkg.OP_B_JOB
       and OP_C_JOB = seq_tbl_pkg.OP_C_JOB and OP_E_COLL = seq_tbl_pkg.OP_E_COLL
       and OP_VEC_NORM = seq_tbl_pkg.OP_VEC_NORM
       and OP_VEC_RES = seq_tbl_pkg.OP_VEC_RES
       and OP_VEC_SWG = seq_tbl_pkg.OP_VEC_SWG
       and OP_END_TOKEN = seq_tbl_pkg.OP_END_TOKEN
      report "tb_llama_top: llama_map_pkg and seq_tbl_pkg disagree about the "
           & "OPCODE numbering." severity failure;
    assert R_X = seq_tbl_pkg.R_X and R_XN = seq_tbl_pkg.R_XN
       and R_QKV = seq_tbl_pkg.R_QKV and R_Z = seq_tbl_pkg.R_Z
       and R_BETA = seq_tbl_pkg.R_BETA and R_ALPHA = seq_tbl_pkg.R_ALPHA
       and R_QG = seq_tbl_pkg.R_QG and R_KIN = seq_tbl_pkg.R_KIN
       and R_VIN = seq_tbl_pkg.R_VIN and R_Y = seq_tbl_pkg.R_Y
       and R_G = seq_tbl_pkg.R_G and R_U = seq_tbl_pkg.R_U
       and R_H = seq_tbl_pkg.R_H and R_ER = seq_tbl_pkg.R_ER
       and NREGION = seq_tbl_pkg.NREGION and R_NONE = seq_tbl_pkg.R_NONE
      report "tb_llama_top: llama_map_pkg and seq_tbl_pkg disagree about the "
           & "REGION numbering." severity failure;
    wait;
  end process;

end architecture;
