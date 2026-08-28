-- sim/probe_abc_ports.vhd
-- MEASUREMENT INSTRUMENT for the question "are subsystems A, B and C ever
-- simultaneously active?", which is item 1 of the must-measure list in
-- docs/2026-08-27_die-allocation-at-rows-if-48.md section 7 and the single
-- claim the phase-multiplexed HBM port mux rests on.
--
-- WHY THIS IS NOT NAMED tb_*.  sim/regress.sh globs sim/tb_*.vhd, and the
-- repo's published verdict today is 69 PASS / 0 FAIL.  Adding a testbench
-- would move that number while other work is gating on it.  Renaming this file
-- to sim/tb_seq_abc_exclusive.vhd is the whole of the promotion and takes the
-- suite to 70; nothing else about the file would change.
--
-- WHAT IT DRIVES.  The REAL descriptor walker rtl/seq_desc_fetch.vhd, walking
-- the REAL 491-descriptor Qwen3.5-9B N=1 token table built by
-- sim/seq_tbl_pkg.vhd from rtl/model_cfg_pkg.vhd.  Nothing about the schedule
-- is hand-written here: 24 GDN blocks x 16 steps + 8 attention blocks x 13
-- steps + final norm + lm_head + END_TOKEN.
--
-- WHAT IT MEASURES, and the distinction is the entire point:
--
--   COMPUTE activity   a unit's window from the issue instant to its ack.
--                      This is what "A, B and C are never simultaneously
--                      active" means in the specs.
--
--   PORT activity      the same window EXTENDED by TAIL_x cycles past the ack.
--                      A unit's `done` does NOT imply its AXI transactions
--                      have retired -- rtl/axi_rd_port.vhd issues bursts with
--                      MAXOUT in flight and keeps accepting R beats after the
--                      last one it needs, and D section 8.2 says so in as many
--                      words.  A port mux that switches on `done` switches
--                      while beats are still in flight, and an AXI read whose
--                      R channel is muxed away does not stall: it is LOST.
--
-- A run with TAIL_x = 0 measures the spec's claim.  A run with TAIL_x > 0
-- measures the claim the port mux actually needs, which is a different and
-- stronger one.
--
-- NEGATIVE CONTROL.  A checker that reports zero overlap on a design that
-- cannot express overlap has proved nothing about itself.  INJECT_LATE makes
-- unit INJECT_UNIT keep computing for N cycles past its own ack -- a unit
-- whose `done` is premature, which is a real defect class in this project (see
-- docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md).  With INJECT_LATE >
-- 0 the run MUST report a non-zero overlap count, and the probe fails if it
-- does not.
--
-- GHDL here is the mcode backend: `ghdl -e` produces no binary and silently
-- succeeds, so `ghdl -r probe_abc_ports` is run directly.  The 491-descriptor
-- table is a function-local temporary, hence --max-stack-alloc=0.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.seq_tbl_pkg.all;

entity probe_abc_ports is
  generic(
    -- Descriptor memory latency.  Small = the prefetch runs far ahead, which
    -- is the configuration in which a walker that could overlap jobs would.
    URAM_LAT : natural := 1;

    -- Job durations, in cycles.  Scaled down from the real ones (A is
    -- 5,187,328 core cycles for the WHOLE token) because the quantity being
    -- measured -- whether two units are ever active at once -- does not depend
    -- on how long a job takes, while the run time does.  The RATIOS are kept
    -- roughly honest so the phase census is readable.
    JOB_A : natural := 300;
    JOB_B : natural := 900;
    JOB_C : natural := 700;
    JOB_E : natural := 40;
    JOB_V : natural := 60;

    -- Cycles a unit's HBM ports stay live AFTER its ack.  ESTIMATE, and the
    -- point of the sweep: 0 reproduces the spec's claim, non-zero asks whether
    -- the mux's stronger claim survives.
    TAIL_A : natural := 0;
    TAIL_B : natural := 0;
    TAIL_C : natural := 0;

    -- Negative control.  Unit INJECT_UNIT keeps its COMPUTE window open this
    -- many cycles past its ack.
    INJECT_LATE : natural := 0;
    INJECT_UNIT : natural := 0;

    TOKENS : natural := 1;
    MAXCYC : natural := 20000000
  );
end entity;

architecture sim of probe_abc_ports is

  constant EPOCH_W : positive := 4;
  constant NUNIT   : positive := 5;
  constant STEP_W  : positive := 11;

  constant U_A : natural := 0;
  constant U_B : natural := 1;
  constant U_C : natural := 2;

  constant TBL : tbl_t := build_table;

  type nat_arr is array (0 to NUNIT-1) of natural;
  constant JOB_LAT  : nat_arr := (JOB_A, JOB_B, JOB_C, JOB_E, JOB_V);
  constant JOB_TAIL : nat_arr := (TAIL_A, TAIL_B, TAIL_C, 0, 0);

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal running : boolean   := true;
  signal cyc     : natural   := 0;

  -- ---- DUT ports --------------------------------------------------------
  signal go, abort, busy, tok_done, tok_ack, err : std_logic := '0';
  signal tbl_len_s : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal err_code  : std_logic_vector(3 downto 0);
  signal err_step  : unsigned(STEP_W-1 downto 0);
  signal steps_done: unsigned(STEP_W-1 downto 0);

  signal d_raddr  : unsigned(15 downto 0);
  signal d_ren    : std_logic;
  signal d_rdata  : std_logic_vector(63 downto 0) := (others => 'X');
  signal d_rvalid : std_logic := '0';

  signal job_valid, job_issue, job_cmp : std_logic;
  signal job_epoch  : unsigned(EPOCH_W-1 downto 0);
  signal job_unit   : unsigned(2 downto 0);
  signal job_opcode : unsigned(3 downto 0);
  signal job_flags  : std_logic_vector(7 downto 0);
  signal job_src, job_src2, job_dst : unsigned(7 downto 0);
  signal job_dst_off, job_n_rows, job_n_cols : unsigned(31 downto 0);
  signal job_w_exp, job_out_shift : signed(31 downto 0);
  signal job_out_mode : std_logic_vector(7 downto 0);
  signal job_ordinal  : unsigned(7 downto 0);
  signal job_const_base : unsigned(31 downto 0);
  signal job_const_exp  : signed(31 downto 0);
  signal job_step     : unsigned(STEP_W-1 downto 0);

  signal chk_req  : std_logic;
  signal chk_bad  : std_logic := '0';
  signal chk_code : std_logic_vector(3 downto 0) := x"2";
  signal chk_opcode : unsigned(3 downto 0);
  signal chk_src, chk_dst : unsigned(7 downto 0);
  signal chk_dst_off, chk_n_rows : unsigned(31 downto 0);

  signal u_start, u_ready, u_done, u_ack, u_err : std_logic_vector(NUNIT-1 downto 0);
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0);

  -- ---- activity, the thing being measured -------------------------------
  signal act_c : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal act_p : std_logic_vector(NUNIT-1 downto 0) := (others => '0');

  signal n_start_a : nat_arr := (others => 0);
  signal tot_c     : nat_arr := (others => 0);
  signal tot_p     : nat_arr := (others => 0);

  -- ---- monitor outputs --------------------------------------------------
  signal ov_c_ab, ov_c_ac, ov_c_bc : natural := 0;   -- compute-window overlap
  signal ov_p_ab, ov_p_ac, ov_p_bc : natural := 0;   -- port-window overlap
  signal ov_pa_cbc : natural := 0;   -- A's PORTS live while B or C COMPUTES
  signal gap_a_bc  : integer := 1000000;  -- min cycles, A ack -> B/C issue
  signal gap_bc_a  : integer := 1000000;  -- min cycles, B/C ack -> A issue
  signal gap_any   : integer := 1000000;  -- min cycles between ANY two jobs
  signal n_op      : nat_arr := (others => 0);       -- reused: see op_cnt
  signal op_cnt    : integer_vector(0 to 7) := (others => 0);
  signal n_issue   : natural := 0;
  signal tok_start : std_logic := '0';

  function sum(a : nat_arr) return natural is
    variable s : natural := 0;
  begin
    for i in a'range loop s := s + a(i); end loop;
    return s;
  end function;

begin

  clk <= not clk after 0.5 ns when running else '0';

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "probe_abc_ports: cycle cap reached, the run is wedged"
        severity failure;
    end if;
  end process;

  dut : entity work.seq_desc_fetch
    generic map(
      NREG => NREGION, EPOCH_W => EPOCH_W, NUNIT => NUNIT,
      NSUB_MAX => 64, STEP_W => STEP_W,
      WDOG_LIMIT => 65535, STRICT_PROTO => false)
    port map(
      clk => clk, rst => rst,
      go => go, tbl_len => tbl_len_s, abort => abort,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      job_valid => job_valid, job_issue => job_issue, job_cmp => job_cmp,
      job_epoch => job_epoch, job_unit => job_unit, job_opcode => job_opcode,
      job_flags => job_flags, job_src => job_src, job_src2 => job_src2,
      job_dst => job_dst, job_dst_off => job_dst_off,
      job_n_rows => job_n_rows, job_n_cols => job_n_cols,
      job_w_exp => job_w_exp, job_out_shift => job_out_shift,
      job_out_mode => job_out_mode, job_ordinal => job_ordinal,
      job_const_base => job_const_base, job_const_exp => job_const_exp,
      job_step => job_step,
      chk_req => chk_req, chk_bad => chk_bad, chk_code => chk_code,
      chk_opcode => chk_opcode, chk_src => chk_src, chk_dst => chk_dst,
      chk_dst_off => chk_dst_off, chk_n_rows => chk_n_rows,
      u_start => u_start, u_ready => u_ready, u_done => u_done,
      u_ack => u_ack, u_err => u_err, u_done_epoch => u_done_epoch);

  -- ======================================================================
  -- Descriptor memory.  'X' between reads so a DUT that samples on the wrong
  -- cycle poisons its shadow rather than getting the right answer by luck.
  -- ======================================================================
  uram : process(clk) is
    type pipe_t is array (0 to 63) of natural;
    variable addr_p : pipe_t := (others => 0);
    variable vld_p  : std_logic_vector(0 to 63) := (others => '0');
    variable L      : natural;
  begin
    if rising_edge(clk) then
      L := URAM_LAT;
      if L < 1 then L := 1; end if;
      for i in 63 downto 1 loop
        addr_p(i) := addr_p(i-1);
        vld_p(i)  := vld_p(i-1);
      end loop;
      if d_ren = '1' then
        addr_p(0) := to_integer(d_raddr);
      else
        addr_p(0) := 0;
      end if;
      vld_p(0) := d_ren;

      if vld_p(L-1) = '1' then
        d_rvalid <= '1';
        if addr_p(L-1) < TBL_WORDS then
          d_rdata <= TBL(addr_p(L-1));
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
  -- Five stub units.  Minimal: `done` is a level held until the ack, which is
  -- the required discipline; the completion-style matrix is tb_seq_desc_fetch's
  -- job and is not repeated here.
  -- ======================================================================
  gen_units : for u in 0 to NUNIT-1 generate
    signal have : std_logic := '0';
    signal rdy  : std_logic := '1';
    signal dn   : std_logic := '0';
    signal lat  : integer   := 0;
    signal ac   : std_logic := '0';
    signal ap   : std_logic := '0';
    signal ac_x : integer   := 0;   -- injected late-compute countdown
    signal ap_x : integer   := 0;   -- AXI tail countdown
    signal ep   : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  begin
    u_ready(u) <= rdy;
    u_done(u)  <= dn;
    u_err(u)   <= '0';
    u_done_epoch((u+1)*EPOCH_W-1 downto u*EPOCH_W) <= std_logic_vector(ep);
    act_c(u)   <= ac;
    act_p(u)   <= ap;

    stub : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          have <= '0'; rdy <= '1'; dn <= '0'; lat <= 0;
          ac <= '0'; ap <= '0'; ac_x <= 0; ap_x <= 0;
          n_start_a(u) <= 0;
        else
          if tok_start = '1' then
            n_start_a(u) <= 0;
          end if;

          if ac = '1' then tot_c(u) <= tot_c(u) + 1; end if;
          if ap = '1' then tot_p(u) <= tot_p(u) + 1; end if;

          -- ---- the two countdowns, FIRST in the process ----------------
          -- ORDER IS LOAD-BEARING.  These must precede the issue branch, so
          -- that a `<= 0` there wins.  With the countdown written last it wins
          -- instead -- the last signal assignment in a process is the one that
          -- takes effect -- so a tail left over from job n kept counting under
          -- job n+1 of the SAME unit and dropped that unit's activity flag in
          -- the middle of a live job.  297 of the 490 jobs are A and A follows
          -- A, so the effect was to make A's port window SHORTER than its
          -- compute window (55,380 cycles against 90,288, MEASURED) and to
          -- report zero port overlap for a reason that had nothing to do with
          -- the DUT.  The negative control is what exposed it.
          if ac_x > 0 then
            ac_x <= ac_x - 1;
            if ac_x = 1 then ac <= '0'; end if;
          end if;
          if ap_x > 0 then
            ap_x <= ap_x - 1;
            if ap_x = 1 then ap <= '0'; end if;
          end if;

          -- ---- take the job at the one instant the shadow goes live ----
          -- The two countdowns are CLEARED here.  Without that, a tail left
          -- running from job n keeps counting under job n+1 of the same unit
          -- and drops the activity flag in the middle of a live job -- which
          -- silently zeroed the port-overlap counters on the first version of
          -- this file, because 297 of the 490 jobs are A and A follows A.
          -- A measurement instrument that reports zero for a reason of its own
          -- is worse than no instrument, which is what the negative control
          -- below exists to catch.
          if job_issue = '1' and to_integer(job_unit) = u then
            have <= '1';
            rdy  <= '0';
            lat  <= JOB_LAT(u);
            ep   <= job_epoch;
            ac   <= '1';
            ap   <= '1';
            ac_x <= 0;
            ap_x <= 0;
            n_start_a(u) <= n_start_a(u) + 1;
          end if;

          -- ---- run the job ---------------------------------------------
          if have = '1' and dn = '0' then
            if lat > 0 then
              lat <= lat - 1;
            else
              dn <= '1';
            end if;
          end if;

          -- ---- completion.  COMPUTE ends at the ack; PORTS do not. ------
          if dn = '1' and u_ack(u) = '1' then
            dn   <= '0';
            have <= '0';
            rdy  <= '1';
            if u = INJECT_UNIT and INJECT_LATE > 0 then
              ac_x <= INJECT_LATE;
            else
              ac <= '0';
            end if;
            if JOB_TAIL(u) > 0 then
              ap_x <= JOB_TAIL(u);
            else
              ap <= '0';
            end if;
          end if;

        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- THE MONITOR.  One process, one driver per signal.
  --
  -- Overlap is counted PER PAIR rather than as a popcount, because "two of the
  -- three were up" and "which two" are different findings and the second is
  -- the one that names the port that has to be muxed.
  -- ======================================================================
  mon : process(clk) is
    variable pc   : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
    variable pp   : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
    variable fall_cyc  : integer := -1;
    variable fall_unit : integer := -1;
    variable g    : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pc := (others => '0');
        pp := (others => '0');
        fall_cyc := -1; fall_unit := -1;
      else
        -- ---- overlap, compute windows -------------------------------
        if act_c(U_A) = '1' and act_c(U_B) = '1' then ov_c_ab <= ov_c_ab + 1; end if;
        if act_c(U_A) = '1' and act_c(U_C) = '1' then ov_c_ac <= ov_c_ac + 1; end if;
        if act_c(U_B) = '1' and act_c(U_C) = '1' then ov_c_bc <= ov_c_bc + 1; end if;

        -- ---- overlap, port windows ----------------------------------
        if act_p(U_A) = '1' and act_p(U_B) = '1' then ov_p_ab <= ov_p_ab + 1; end if;
        if act_p(U_A) = '1' and act_p(U_C) = '1' then ov_p_ac <= ov_p_ac + 1; end if;
        if act_p(U_B) = '1' and act_p(U_C) = '1' then ov_p_bc <= ov_p_bc + 1; end if;

        -- The mux-relevant one: A's 27 ports still carrying beats while B or C
        -- is computing and would be using the muxed ones.
        if act_p(U_A) = '1' and (act_c(U_B) = '1' or act_c(U_C) = '1') then
          ov_pa_cbc <= ov_pa_cbc + 1;
        end if;

        -- ---- inter-job gaps, compute windows only -------------------
        for u in 0 to NUNIT-1 loop
          if pc(u) = '1' and act_c(u) = '0' then
            fall_cyc  := cyc;
            fall_unit := u;
          end if;
        end loop;
        for u in 0 to NUNIT-1 loop
          if pc(u) = '0' and act_c(u) = '1' and fall_cyc >= 0 then
            g := cyc - fall_cyc;
            if g < gap_any then gap_any <= g; end if;
            if fall_unit = U_A and (u = U_B or u = U_C) then
              if g < gap_a_bc then gap_a_bc <= g; end if;
            end if;
            if (fall_unit = U_B or fall_unit = U_C) and u = U_A then
              if g < gap_bc_a then gap_bc_a <= g; end if;
            end if;
          end if;
        end loop;

        -- ---- census --------------------------------------------------
        if job_issue = '1' then
          op_cnt(to_integer(job_opcode)) <= op_cnt(to_integer(job_opcode)) + 1;
          n_issue <= n_issue + 1;
        end if;

        pc := act_c;
        pp := act_p;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Stimulus and verdict.
  -- ======================================================================
  main : process is
    variable fail : natural := 0;
  begin
    report "probe_abc_ports: model = " & integer'image(MODEL.blocks)
         & " blocks (" & integer'image(gdn_layers(MODEL)) & " GDN + "
         & integer'image(attn_layers(MODEL)) & " attention, interval "
         & integer'image(MODEL.attn_interval) & "), NCARDS = "
         & integer'image(NCARDS) & ", table = "
         & integer'image(TBL_STEPS) & " descriptors";
    report "probe_abc_ports: TAIL_A=" & integer'image(TAIL_A)
         & " TAIL_B=" & integer'image(TAIL_B)
         & " TAIL_C=" & integer'image(TAIL_C)
         & " INJECT_LATE=" & integer'image(INJECT_LATE)
         & " on unit " & integer'image(INJECT_UNIT);

    tbl_len_s <= to_unsigned(TBL_STEPS, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    for t in 1 to TOKENS loop
      tok_start <= '1';
      wait until rising_edge(clk);
      tok_start <= '0';
      go <= '1';
      wait until rising_edge(clk);
      go <= '0';

      loop
        wait until rising_edge(clk);
        exit when tok_done = '1';
      end loop;
      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';

      report "  token " & integer'image(t)
           & ": steps_done=" & integer'image(to_integer(steps_done))
           & " err=" & std_logic'image(err)
           & " cyc=" & integer'image(cyc);
    end loop;

    -- let any tail drain before the verdict
    for i in 0 to 4095 loop wait until rising_edge(clk); end loop;

    report "---- phase census, one token ----";
    report "  A_JOB     = " & integer'image(op_cnt(0));
    report "  B_JOB     = " & integer'image(op_cnt(1));
    report "  C_JOB     = " & integer'image(op_cnt(2));
    report "  E_COLL    = " & integer'image(op_cnt(3));
    report "  VEC_NORM  = " & integer'image(op_cnt(4));
    report "  VEC_RES   = " & integer'image(op_cnt(5));
    report "  VEC_SWG   = " & integer'image(op_cnt(6));
    report "  jobs issued = " & integer'image(n_issue)
         & " (table is " & integer'image(TBL_STEPS)
         & " descriptors, END_TOKEN starts nobody)";
    report "  stub starts A/B/C/E/V = "
         & integer'image(n_start_a(0)) & "/" & integer'image(n_start_a(1))
         & "/" & integer'image(n_start_a(2)) & "/" & integer'image(n_start_a(3))
         & "/" & integer'image(n_start_a(4));

    report "  tot_c A/B/C = " & integer'image(tot_c(0)) & "/" & integer'image(tot_c(1)) & "/" & integer'image(tot_c(2));
    report "  tot_p A/B/C = " & integer'image(tot_p(0)) & "/" & integer'image(tot_p(1)) & "/" & integer'image(tot_p(2));
    report "---- overlap, COMPUTE windows (cycles) ----";
    report "  A&B = " & integer'image(ov_c_ab);
    report "  A&C = " & integer'image(ov_c_ac);
    report "  B&C = " & integer'image(ov_c_bc);
    report "---- overlap, PORT windows (cycles) ----";
    report "  A&B = " & integer'image(ov_p_ab);
    report "  A&C = " & integer'image(ov_p_ac);
    report "  B&C = " & integer'image(ov_p_bc);
    report "  A ports live while B or C computes = " & integer'image(ov_pa_cbc);
    report "---- inter-job gaps, COMPUTE windows (cycles) ----";
    report "  min gap, any -> any     = " & integer'image(gap_any);
    report "  min gap, A ack -> B/C   = " & integer'image(gap_a_bc);
    report "  min gap, B/C ack -> A   = " & integer'image(gap_bc_a);

    -- ---- verdict ---------------------------------------------------------
    if INJECT_LATE > 0 then
      -- NEGATIVE CONTROL: the checker must have teeth.
      if (ov_c_ab + ov_c_ac + ov_c_bc) = 0 then
        report "probe_abc_ports: NEGATIVE CONTROL DID NOT FIRE.  A unit was "
             & "made to compute past its own ack and the overlap counters "
             & "still read zero, so a zero from this probe means nothing."
          severity error;
        fail := fail + 1;
      else
        report "  ok  negative control fired: "
             & integer'image(ov_c_ab + ov_c_ac + ov_c_bc)
             & " cycles of A/B/C compute overlap detected";
      end if;
    else
      if (ov_c_ab + ov_c_ac + ov_c_bc) /= 0 then
        report "probe_abc_ports: A, B and C WERE simultaneously active."
          severity error;
        fail := fail + 1;
      else
        report "  ok  zero cycles of A/B/C COMPUTE overlap over "
             & integer'image(TOKENS) & " token(s)";
      end if;
    end if;

    if err /= '0' then
      report "probe_abc_ports: the walk raised err" severity error;
      fail := fail + 1;
    end if;
    if n_issue /= TOKENS * (TBL_STEPS - 1) then
      report "probe_abc_ports: issued " & integer'image(n_issue)
           & " jobs, expected " & integer'image(TOKENS * (TBL_STEPS - 1))
        severity error;
      fail := fail + 1;
    end if;

    if fail = 0 then
      report "PASS probe_abc_ports";
    else
      report "FAIL probe_abc_ports (" & integer'image(fail) & ")" severity error;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
