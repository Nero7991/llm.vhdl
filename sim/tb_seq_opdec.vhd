-- sim/tb_seq_opdec.vhd
-- Testbench for rtl/seq_opdec.vhd, and the FIRST test that connects the three
-- subsystem-D units to each other: `seq_desc_fetch` -> `seq_opdec` ->
-- `seq_region_lock`, walking the real per-token descriptor table for the build
-- target in `rtl/model_cfg_pkg.vhd`.
--
-- WHY AN INTEGRATION TESTBENCH AND NOT A UNIT ONE.  `seq_desc_fetch` was
-- verified against a STUB region checker and `seq_region_lock` against a STUB
-- sequencer.  Both stubs were written by the same hand as the unit they fed,
-- which is exactly the condition under which a seam defect is invisible: each
-- side tests its own reading of the interface.  The three findings this file
-- produced were all in that gap and none of them is reachable from either unit
-- testbench:
--
--   * nothing published the host-written X region, so with the locks reset at
--     `go` the FIRST descriptor of the token consumes a FREE region;
--   * the walker's candidate port group has no `src2`, so the decode cannot
--     check the second operand before the unit starts;
--   * a mid-job lock violation has nowhere to be reported until the next
--     descriptor check, so ERR_INFO names the step AFTER the offender.
--
-- THE SKEW RULE, inherited and extended.  Every producer gets its own generic
-- and no configuration is privileged.  There are FOUR independent producers
-- here, one more than either predecessor had:
--
--   URAM_LAT    the descriptor memory.  Small = the prefetch runs far ahead,
--               which is the class (a) exposure for the two-bank shadow.  It
--               is counter-intuitive and it is already paid for: the dangerous
--               configuration is a FAST memory and a SLOW unit.
--   JOB_LAT,    the five stub units, skewed against each other by LAT_SKEW so
--   LAT_SKEW    they never move in lockstep, plus DONE_STYLE / DONE_HOLD /
--   ...         STALE_HOLD / READY_EARLY / READY_GAP for the completion
--               discipline.
--   WR_N,       THE REGION WRITE STREAM.  Its phase counter FREE-RUNS: it is
--   WR_GAP,     not derived from the job latency, so write strobes land at
--   WR_TAIL     arbitrary offsets inside a job rather than at a fixed one.  A
--               write stream clocked off the job's own countdown is the
--               head-emit stimulus defect -- one process feeding two producers
--               throttles one of them and reports a clean, meaningless number.
--   EXP_DECAY   THE PRODUCED EXPONENT'S LIFETIME.  A unit's `y_exp` is
--               guaranteed only while it asserts `done`.  EXP_DECAY says how
--               many cycles after `done` rises the stub SCRAMBLES it.  At 0 it
--               is valid for exactly one cycle, which is what a real BFP unit
--               that has already re-armed would give, and it is the only
--               configuration that distinguishes capture-at-first-`done` from
--               capture-at-`job_cmp`.  The two differ by one clocked state and
--               by a wrong scale in one layer.
--
-- WHAT IS CHECKED, beyond "it terminated":
--
--   1. THE DECODE, against an independently written reference plan built from
--      the same table.  Compared at TWO instants: at `chk_req`, where the lock
--      forms its verdict, and at `iss_commit`, where the locks actually move.
--      Those are different descriptors if the latch is wrong, because the
--      descriptor banks swap in between, and a commit for the wrong step is a
--      silent lock corruption rather than a fault.
--   2. THE COUNTING IDENTITY: steps_done = the table length, jobs started and
--      completed = length - 1.  Present from the first run.
--   3. THE EXPONENT, end to end: every producing step's captured exponent is
--      read back out of the lock and compared against what the stub reported
--      at its `done`.  This is O15 across all three units, and it is the check
--      EXP_DECAY exists to make sharp.
--   4. NO SILENT DROP: after any write strobe the lock refuses, `viol` must be
--      asserted on the next cycle.
--   5. REL_NAIVE: D section 5.3's own release rule, applied to D section 4.2's
--      own schedule, must FAIL, at a named step, with ERR_LOCK.  The
--      contradiction was previously an argument from reading; this makes it a
--      measurement.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.seq_tbl_pkg.all;

entity tb_seq_opdec is
  generic(
    -- ---- producer 1: the descriptor memory --------------------------------
    URAM_LAT    : natural := 1;
    -- ---- producer 2: the five units ---------------------------------------
    JOB_LAT     : natural := 40;
    LAT_SKEW    : natural := 7;
    READY_GAP   : natural := 0;
    DONE_STYLE  : natural := 0;   -- 0 level-until-ack, 1 one-cycle pulse, 2 timer
    DONE_HOLD   : natural := 3;
    STALE_HOLD  : natural := 0;
    READY_EARLY : boolean := false;
    -- ---- producer 3: the region write stream ------------------------------
    WR_N        : natural := 4;   -- legal strobes per producing job
    WR_GAP      : natural := 2;   -- free-running phase between strobes
    WR_TAIL     : natural := 0;   -- strobes AFTER the completion (must drop)
    -- ---- producer 4: the produced exponent's lifetime ---------------------
    -- Cycles after `done` rises at which the stub scrambles its `y_exp`.
    EXP_DECAY   : natural := 0;

    -- ---- fault injection, one at a time -----------------------------------
    REL_NAIVE   : boolean := false; -- D section 5.3's release rule, literally
    XW_AT       : integer := -1;    -- rogue exponent write into a HELD region
    SRC2_BAD_AT : integer := -1;    -- src2 naming a region the opcode does not read
    ROWS_BIG_AT : integer := -1;    -- n_rows past ADDR_W with a real destination
    OFF_SEG_AT  : integer := -1;    -- a QKV offset that is not a segment boundary

    TOKENS      : natural := 2;
    HEARTBEAT   : natural := 0;
    STRICT      : boolean := false;
    MAXCYC      : natural := 8000000
  );
end entity;

architecture sim of tb_seq_opdec is

  constant EPOCH_W : positive := 4;
  constant NUNIT   : positive := 5;
  constant STEP_W  : positive := 11;
  constant NREG    : natural  := NREGION;
  constant ADDR_W  : positive := 16;
  constant EXP_W   : positive := 16;
  constant SEGS    : positive := 3;
  constant SIZES   : integer_vector := region_sizes;

  constant TBL : tbl_t := build_table;

  -- The per-opcode extra consume masks for the flat 14-region map.  Written
  -- here as region NAMES so the generic passed to the DUT and the reference
  -- plan below are not two copies of the same magic number.
  constant M_B   : integer := 2**R_Z + 2**R_BETA + 2**R_ALPHA;
  constant M_C   : integer := 2**R_KIN + 2**R_VIN;
  constant M_RES : integer := 2**R_ER;
  constant M_SWG : integer := 2**R_U;
  constant OPC_CONS_C : integer_vector :=
    (0, M_B, M_C, 0, 0, M_RES, M_SWG, 0);

  -- ======================================================================
  -- THE REFERENCE PLAN.  Written independently of `seq_opdec`: it reads the
  -- descriptor words out of the table and applies the rules from the D design
  -- spec, so a decode that agrees with it agrees with the spec and not merely
  -- with itself.
  -- ======================================================================
  type step_t is record
    prod : std_logic;
    dst  : natural;                       -- NREG = produces nothing
    seg  : natural;
    off  : natural;
    rows : natural;
    cons : std_logic_vector(NREG-1 downto 0);
    rel  : std_logic_vector(NREG-1 downto 0);
  end record;
  type plan_t is array (0 to TBL_STEPS-1) of step_t;

  function fld(w : std_logic_vector(63 downto 0); hi, lo : natural)
    return natural is
    variable r : unsigned(hi-lo downto 0);
  begin
    r := unsigned(w(hi downto lo));
    return to_integer(r);
  end function;

  function build_plan return plan_t is
    variable p : plan_t;
    variable d0, d1 : std_logic_vector(63 downto 0);
    variable op, src, dst, off, rows : natural;
    variable last_c : integer;
  begin
    for s in 0 to TBL_STEPS-1 loop
      d0   := TBL(s*8 + 0);
      d1   := TBL(s*8 + 1);
      op   := fld(d0, 7, 0);
      src  := fld(d0, 23, 16);
      dst  := fld(d0, 31, 24);
      off  := fld(d0, 63, 32);
      rows := fld(d1, 31, 0);

      p(s).cons := (others => '0');
      p(s).rel  := (others => '0');
      p(s).seg  := 0;
      p(s).off  := off mod 65536;

      -- The consume set: the named source plus whatever the opcode implies.
      -- B reads four regions and C reads three; two region bytes in the
      -- header cannot say that, which is finding (1) of the DUT header.
      case op is
        when OP_B_JOB =>
          p(s).cons(R_Z) := '1'; p(s).cons(R_BETA) := '1';
          p(s).cons(R_ALPHA) := '1';
        when OP_C_JOB =>
          p(s).cons(R_KIN) := '1'; p(s).cons(R_VIN) := '1';
        when OP_VEC_RES =>
          p(s).cons(R_ER) := '1';
        when OP_VEC_SWG =>
          p(s).cons(R_U) := '1';
        when others => null;
      end case;
      if op /= OP_END_TOKEN and src < NREG then
        p(s).cons(src) := '1';
      end if;
      if op = OP_END_TOKEN then
        p(s).cons := (others => '0');
      end if;

      if dst < NREG and op /= OP_END_TOKEN then
        p(s).prod := '1';
        p(s).dst  := dst;
        p(s).rows := rows;
        if dst = R_QKV then
          if    off = 0           then p(s).seg := 0;
          elsif off = KEY_DIM     then p(s).seg := 1;
          else                         p(s).seg := 2;
          end if;
        end if;
      else
        p(s).prod := '0';
        p(s).dst  := NREG;
        -- REGION-SCOPED, and zero when there is no region.  lm_head emits
        -- 248,320 rows into no region at all; passing that count on a
        -- region-scoped port truncates and means nothing.
        p(s).rows := 0;
      end if;
    end loop;

    -- Liveness.  A region is released by the LAST step that reads it before
    -- the next step that produces it FROM SCRATCH; a region that is only ever
    -- updated in place (X, the residual stream) is never released.  This is
    -- the pass a host generator runs, and it is the pass D section 6.1's
    -- descriptor format has no field to carry the result of.
    for r in 0 to NREG-1 loop
      last_c := -1;
      for s in 0 to TBL_STEPS-1 loop
        if p(s).prod = '1' and p(s).dst = r and p(s).cons(r) = '0' then
          if last_c >= 0 then
            p(last_c).rel(r) := '1';
          end if;
          last_c := -1;
        end if;
        if p(s).cons(r) = '1' then
          last_c := s;
        end if;
      end loop;
    end loop;

    return p;
  end function;

  constant PLAN : plan_t := build_plan;

  -- The stub's produced exponent for a given step.  Derived from the step so
  -- that a stale or shared capture is a WRONG NUMBER and not merely a repeat.
  function exp_of(s : integer) return integer is
  begin
    return ((s * 13) mod 97) - 48;
  end function;
  constant EXP_GARBAGE : integer := -9999;

  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal running : boolean   := true;
  signal cyc     : natural   := 0;

  -- ---- seq_desc_fetch ---------------------------------------------------
  signal go_walk, abort_s, busy, tok_done, tok_ack, err : std_logic := '0';
  signal tbl_len_s  : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal err_code   : std_logic_vector(3 downto 0);
  signal err_step   : unsigned(STEP_W-1 downto 0);
  signal steps_done : unsigned(STEP_W-1 downto 0);

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
  signal chk_bad  : std_logic;
  signal chk_code : std_logic_vector(3 downto 0);
  signal chk_opcode : unsigned(3 downto 0);
  signal chk_src, chk_dst : unsigned(7 downto 0);
  signal chk_dst_off, chk_n_rows : unsigned(31 downto 0);

  signal u_start, u_ready, u_done, u_ack, u_err
       : std_logic_vector(NUNIT-1 downto 0);
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0);
  signal u_y_exp      : std_logic_vector(NUNIT*EXP_W-1 downto 0);

  -- ---- seq_opdec --------------------------------------------------------
  signal go_in      : std_logic := '0';
  signal host_x_exp : signed(EXP_W-1 downto 0) := to_signed(5, EXP_W);
  signal host_busy  : std_logic;
  signal rel_mask   : std_logic_vector(NREG-1 downto 0) := (others => '0');

  signal lock_rst   : std_logic;
  signal iss_req, iss_commit, iss_prod : std_logic;
  signal iss_dst    : unsigned(7 downto 0);
  signal iss_seg    : unsigned(1 downto 0);
  signal iss_off, iss_n_rows : unsigned(ADDR_W-1 downto 0);
  signal iss_cons, iss_rel   : std_logic_vector(NREG-1 downto 0);
  signal iss_ok     : std_logic;
  signal iss_code   : std_logic_vector(3 downto 0);
  signal cmp_valid  : std_logic;
  signal cmp_y_exp  : signed(EXP_W-1 downto 0);
  signal viol       : std_logic;
  signal viol_code  : std_logic_vector(3 downto 0);
  signal viol_ack   : std_logic;
  signal viol_reg   : unsigned(7 downto 0);
  signal y_exp_taken: std_logic;
  signal y_exp_held : signed(EXP_W-1 downto 0);
  signal viol_step  : unsigned(STEP_W-1 downto 0);
  signal viol_seen  : std_logic;

  -- ---- seq_region_lock write ports --------------------------------------
  signal wr_we      : std_logic := '0';
  signal wr_region  : unsigned(7 downto 0) := (others => '0');
  signal wr_gate    : std_logic;
  signal xw_we      : std_logic := '0';
  signal xw_region  : unsigned(7 downto 0) := (others => '0');
  signal xw_seg     : unsigned(1 downto 0) := "00";
  signal xw_exp     : signed(EXP_W-1 downto 0) := (others => '0');
  signal xw_gate    : std_logic;
  signal exp_rd_region : unsigned(7 downto 0) := (others => '0');
  signal exp_rd_seg    : unsigned(1 downto 0) := "00";
  signal exp_rd_data   : signed(EXP_W-1 downto 0);
  signal exp_rd_valid  : std_logic;
  signal lock_state    : std_logic_vector(2*NREG-1 downto 0);

  -- ---- observation ------------------------------------------------------
  type nat_arr is array (0 to NUNIT-1) of natural;
  signal n_start_a   : nat_arr := (others => 0);
  signal n_started   : natural;
  signal n_completed : natural := 0;
  signal n_chk       : natural := 0;    -- chk_req pulses seen this token
  signal n_dec_bad   : natural := 0;    -- decode mismatches at chk_req
  signal n_cmt_bad   : natural := 0;    -- decode mismatches at iss_commit
  signal n_exp_bad   : natural := 0;    -- captured exponent wrong
  signal n_exp_chk   : natural := 0;    -- captured exponents verified
  signal n_wr_wrong  : natural := 0;    -- gate disagreed with the expectation
  signal n_wr_ok     : natural := 0;
  signal n_wr_drop   : natural := 0;
  signal n_silent    : natural := 0;    -- drops with no viol on the next cycle
  signal n_taken     : natural := 0;    -- y_exp_taken pulses
  signal tok_reset   : std_logic := '0';

  function sl2i(v : std_logic) return integer is
  begin if v = '1' then return 1; else return 0; end if; end function;

  function sum(a : nat_arr) return natural is
    variable s : natural := 0;
  begin
    for i in a'range loop s := s + a(i); end loop;
    return s;
  end function;

  -- The reference plan's fields as the DUT should present them.
  function ref_dst(s : integer) return unsigned is
  begin
    if PLAN(s).dst < NREG then return to_unsigned(PLAN(s).dst, 8);
    else return x"FF"; end if;
  end function;

begin

  clk <= not clk after 0.5 ns when running else '0';

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_seq_opdec: cycle cap reached, the run is wedged"
        severity failure;
    end if;
  end process;

  -- ======================================================================
  -- DUT 1: the descriptor walker.  Its `go` comes from `seq_opdec`, not from
  -- the host: the locks must be reset and the host's X published before the
  -- first descriptor is checked.
  -- ======================================================================
  u_fetch : entity work.seq_desc_fetch
    generic map(
      NREG => NREG, EPOCH_W => EPOCH_W, NUNIT => NUNIT,
      NSUB_MAX => 64, STEP_W => STEP_W,
      WDOG_LIMIT => 4096, STRICT_PROTO => STRICT)
    port map(
      clk => clk, rst => rst,
      go => go_walk, tbl_len => tbl_len_s, abort => abort_s,
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
  -- DUT 2: the unit under test.
  -- ======================================================================
  u_opdec : entity work.seq_opdec
    generic map(
      NREG => NREG, SEGS => SEGS, ADDR_W => ADDR_W, EXP_W => EXP_W,
      NUNIT => NUNIT, STEP_W => STEP_W,
      OPC_CONS => OPC_CONS_C,
      MSEG_REG => R_QKV, MSEG_OFF1 => KEY_DIM, MSEG_OFF2 => 2*KEY_DIM,
      REL_NAIVE => REL_NAIVE,
      HOST_REG => R_X, HOST_ROWS => HID,
      STRICT => STRICT)
    port map(
      clk => clk, rst => rst,
      go_in => go_in, host_x_exp => host_x_exp,
      go_out => go_walk, host_busy => host_busy,
      chk_req => chk_req, chk_opcode => chk_opcode, chk_src => chk_src,
      chk_dst => chk_dst, chk_dst_off => chk_dst_off, chk_n_rows => chk_n_rows,
      chk_bad => chk_bad, chk_code => chk_code,
      rel_mask => rel_mask,
      job_issue => job_issue, job_cmp => job_cmp, job_unit => job_unit,
      job_src2 => job_src2, job_step => job_step,
      u_done => u_done, u_y_exp => u_y_exp,
      lock_rst => lock_rst,
      iss_req => iss_req, iss_commit => iss_commit, iss_prod => iss_prod,
      iss_dst => iss_dst, iss_seg => iss_seg, iss_off => iss_off,
      iss_n_rows => iss_n_rows, iss_cons => iss_cons, iss_rel => iss_rel,
      iss_ok => iss_ok, iss_code => iss_code,
      cmp_valid => cmp_valid, cmp_y_exp => cmp_y_exp,
      viol => viol, viol_code => viol_code, viol_ack => viol_ack,
      y_exp_taken => y_exp_taken, y_exp_held => y_exp_held,
      viol_step => viol_step, viol_seen => viol_seen);

  -- ======================================================================
  -- DUT 3: the region lock.
  -- ======================================================================
  u_lock : entity work.seq_region_lock
    generic map(
      REG_SIZE => SIZES, SEGS => SEGS, ADDR_W => ADDR_W, EXP_W => EXP_W,
      STRICT => STRICT)
    port map(
      clk => clk, rst => lock_rst,
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
      viol_region => viol_reg);

  n_started <= sum(n_start_a);

  -- ======================================================================
  -- PRODUCER 1: the descriptor memory.  `d_rdata` is 'X' whenever `d_rvalid`
  -- is low, so a DUT sampling the bus on the wrong cycle poisons its shadow
  -- rather than getting the right answer by luck.  Three of the fault
  -- injections are HOST GENERATOR faults and are applied here, in the table,
  -- because that is where a generator/gateware disagreement lives.
  -- ======================================================================
  uram : process(clk) is
    type pipe_t is array (0 to 63) of natural;
    variable addr_p : pipe_t := (others => 0);
    variable vld_p  : std_logic_vector(0 to 63) := (others => '0');
    variable L      : natural;
    variable a      : natural;
  begin
    if rising_edge(clk) then
      L := URAM_LAT;
      if L < 1 then L := 1; end if;
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
        if a < TBL_WORDS then
          if SRC2_BAD_AT >= 0 and a = SRC2_BAD_AT*8 + 3 then
            -- A second source naming a region this opcode does not read.  The
            -- decode's consume mask would then not cover it, so the step runs
            -- against a region nobody locked.
            d_rdata <= TBL(a)(63 downto 56)
                     & std_logic_vector(to_unsigned(R_BETA, 8))
                     & TBL(a)(47 downto 0);
          elsif ROWS_BIG_AT >= 0 and a = ROWS_BIG_AT*8 + 1 then
            d_rdata <= TBL(a)(63 downto 32) & x"00020000";
          elsif OFF_SEG_AT >= 0 and a = OFF_SEG_AT*8 + 0 then
            d_rdata <= std_logic_vector(to_unsigned(KEY_DIM + 1, 32))
                     & TBL(a)(31 downto 0);
          else
            d_rdata <= TBL(a);
          end if;
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
  -- PRODUCER 2: five stub units, each with its own latency, its own
  -- completion style, and its own produced exponent whose LIFETIME is the
  -- EXP_DECAY generic.
  -- ======================================================================
  gen_units : for u in 0 to NUNIT-1 generate
    signal ep      : unsigned(EPOCH_W-1 downto 0) := (others => '0');
    signal lat     : integer := 0;
    signal dhold   : integer := 0;
    signal gap     : integer := 0;
    signal rdy     : std_logic := '1';
    signal dn      : std_logic := '0';
    signal er      : std_logic := '0';
    signal have    : std_logic := '0';
    signal dn_age  : natural := 0;
    signal my_step : integer := -1;
    signal yexp    : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    u_ready(u) <= rdy;
    u_done(u)  <= dn;
    u_err(u)   <= er;
    u_done_epoch((u+1)*EPOCH_W-1 downto u*EPOCH_W) <= std_logic_vector(ep);
    u_y_exp((u+1)*EXP_W-1 downto u*EXP_W) <= std_logic_vector(yexp);

    stub : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          have <= '0'; rdy <= '1'; dn <= '0'; er <= '0';
          lat <= 0; dhold <= 0; gap <= 0; dn_age <= 0; my_step <= -1;
          n_start_a(u) <= 0;
          yexp <= to_signed(EXP_GARBAGE, EXP_W);
        elsif tok_reset = '1' then
          n_start_a(u) <= 0;
        else
          if job_issue = '1' and to_integer(job_unit) = u then
            my_step <= to_integer(job_step);
            have    <= '1';
            rdy     <= '0';
            ep      <= job_epoch;
            lat     <= JOB_LAT + u*LAT_SKEW;
            dn_age  <= 0;
            -- Between `start` and `done` the exponent is not yet known: a BFP
            -- y_exp is only final once the amax scan has run.  Garbage here is
            -- deliberate -- a capture at ISSUE must not accidentally be right.
            yexp    <= to_signed(EXP_GARBAGE, EXP_W);
            n_start_a(u) <= n_start_a(u) + 1;
          end if;

          if have = '1' and dn = '0' then
            if lat > 0 then
              lat <= lat - 1;
            else
              dn     <= '1';
              dn_age <= 0;
              dhold  <= DONE_HOLD;
              -- Valid AT `done`, and only there.
              yexp   <= to_signed(exp_of(my_step), EXP_W);
            end if;
          end if;

          if dn = '1' then
            dn_age <= dn_age + 1;
            -- PRODUCER 4.  The exponent's lifetime is EXP_DECAY cycles of
            -- `done` and no longer.  At 0 it is valid for exactly one cycle,
            -- which is what a unit that re-arms on its own ack would give, and
            -- it is what separates capture-at-first-`done` from
            -- capture-at-`job_cmp`.
            if dn_age >= EXP_DECAY then
              yexp <= to_signed(EXP_GARBAGE, EXP_W);
            end if;
            case DONE_STYLE is
              when 1 =>
                dn <= '0'; er <= '0'; have <= '0'; gap <= READY_GAP;
              when 2 =>
                if dhold > 0 then dhold <= dhold - 1;
                else dn <= '0'; er <= '0'; have <= '0'; gap <= READY_GAP;
                end if;
              when others =>
                if u_ack(u) = '1' then
                  have <= '0';
                  if READY_EARLY then rdy <= '1'; end if;
                  if STALE_HOLD = 0 then
                    dn <= '0'; er <= '0'; gap <= READY_GAP;
                  else
                    dhold <= STALE_HOLD;
                  end if;
                elsif dhold > 0 then
                  dhold <= dhold - 1;
                  if dhold = 1 then
                    dn <= '0'; er <= '0'; gap <= READY_GAP;
                  end if;
                end if;
            end case;
          end if;

          if dn = '0' and have = '0' and rdy = '0' then
            if gap > 0 then gap <= gap - 1; else rdy <= '1'; end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- PRODUCER 3: the region write stream.  Its phase counter FREE-RUNS and is
  -- not derived from the job latency, so strobes land at arbitrary offsets
  -- inside a job.  A stream clocked off the job's own countdown would put
  -- every write at the same phase and would test one phase.
  -- ======================================================================
  wrgen : process(clk) is
    variable ph   : natural := 0;
    variable n    : natural := 0;
    variable tail : natural := 0;
    variable treg : unsigned(7 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      wr_we <= '0';
      if rst = '1' then
        ph := 0; n := 0; tail := 0;
      else
        ph := ph + 1;
        if job_issue = '1' then n := 0; end if;
        if job_cmp = '1' then
          tail := WR_TAIL;
          treg := job_dst;
        end if;

        if ph > WR_GAP then
          ph := 0;
          if tail > 0 and treg < NREG then
            -- "A unit's `done` does NOT imply its transactions have retired."
            -- Every one of these must be dropped AND reported.
            wr_we     <= '1';
            wr_region <= treg;
            tail := tail - 1;
          elsif job_valid = '1' and job_dst < NREG and n < WR_N then
            wr_we     <= '1';
            wr_region <= job_dst;
            n := n + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- The write-gate checker, and the NO SILENT DROP invariant.
  -- ======================================================================
  wchk : process(clk) is
    variable drop_prev : boolean := false;
    variable expect_ok : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        drop_prev := false;
      else
        if drop_prev and viol = '0' then
          n_silent <= n_silent + 1;
          report "tb_seq_opdec: a write strobe was DROPPED with no violation "
               & "raised on the next cycle.  A silent drop is worse than no "
               & "check: it is a correct-looking run with a wrong number in it."
            severity error;
        end if;
        drop_prev := false;

        if wr_we = '1' then
          -- THE ACCEPTANCE WINDOW IS ONE CYCLE WIDER THAN `job_valid`, and
          -- this model said otherwise for three runs.  `seq_desc_fetch` clears
          -- `job_valid` in S_COMPLETE and raises `job_cmp` the cycle after, so
          -- there is exactly one cycle in which the job is over as far as the
          -- shadow is concerned but the lock's committed job is still live.  A
          -- write arriving there is still that job's own strobe, into its own
          -- destination, before the fill pointer moves, and the lock accepts
          -- it.  The window is [iss_commit, cmp_valid] INCLUSIVE.
          --
          -- Only the instant-unit configurations can see this: with a long
          -- JOB_LAT the write burst is spent long before the completion, so
          -- the emitter never lands a strobe in that cycle.  Which is the
          -- whole argument for sweeping the skew rather than tuning it.
          expect_ok := ((job_valid = '1') or (job_cmp = '1'))
                       and (job_dst < NREG) and (wr_region = job_dst);
          if wr_gate = '1' then
            n_wr_ok <= n_wr_ok + 1;
          else
            n_wr_drop <= n_wr_drop + 1;
            drop_prev := true;
          end if;
          if (wr_gate = '1') /= expect_ok then
            n_wr_wrong <= n_wr_wrong + 1;
            report "tb_seq_opdec: the write gate disagreed with the model at "
                 & "cycle " & integer'image(cyc) & ": gate="
                 & std_logic'image(wr_gate)
                 & " region=" & integer'image(to_integer(wr_region))
                 & " job_valid=" & std_logic'image(job_valid)
              severity error;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DECODE CHECK.  At `chk_req` (where the verdict is formed) and again
  -- at `iss_commit` (where the locks move).  Those are different descriptors
  -- if the latch is wrong: the banks swap in between.
  -- ======================================================================
  rel_mask <= PLAN(n_chk).rel when n_chk < TBL_STEPS else (others => '0');

  dchk : process(clk) is
    variable s : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' or tok_reset = '1' then
        n_chk <= 0;
      else
        if chk_req = '1' then
          s := n_chk;
          -- A step whose descriptor was deliberately corrupted in the URAM
          -- model legitimately decodes to something the reference plan -- built
          -- from the CLEAN table -- does not describe.  Comparing them there
          -- would report the injection as a decode defect and mask a real one.
          if s < TBL_STEPS and s /= ROWS_BIG_AT and s /= OFF_SEG_AT
             and s /= SRC2_BAD_AT then
            if iss_prod /= PLAN(s).prod or iss_dst /= ref_dst(s)
               or to_integer(iss_seg) /= PLAN(s).seg
               or to_integer(iss_off) /= PLAN(s).off
               or to_integer(iss_n_rows) /= PLAN(s).rows
               or iss_cons /= PLAN(s).cons
               or (not REL_NAIVE and iss_rel /= PLAN(s).rel)
            then
              n_dec_bad <= n_dec_bad + 1;
              report "tb_seq_opdec: DECODE MISMATCH at check of step "
                   & integer'image(s) & ": prod=" & std_logic'image(iss_prod)
                   & " dst=" & integer'image(to_integer(iss_dst))
                   & " seg=" & integer'image(to_integer(iss_seg))
                   & " off=" & integer'image(to_integer(iss_off))
                   & " rows=" & integer'image(to_integer(iss_n_rows))
                   & " (reference dst=" & integer'image(PLAN(s).dst)
                   & " seg=" & integer'image(PLAN(s).seg)
                   & " off=" & integer'image(PLAN(s).off)
                   & " rows=" & integer'image(PLAN(s).rows) & ")"
                severity error;
            end if;
          end if;
          n_chk <= n_chk + 1;
        end if;

        -- The commit.  `job_step` is the step whose shadow just went live, so
        -- a commit driven from the live `chk_*` port -- which by now describes
        -- the OTHER bank -- lands here as a mismatch instead of as a silent
        -- lock corruption 400 steps later.
        if iss_commit = '1' and host_busy = '0' then
          s := to_integer(job_step);
          if s < TBL_STEPS and s /= ROWS_BIG_AT and s /= OFF_SEG_AT
             and s /= SRC2_BAD_AT then
            if iss_prod /= PLAN(s).prod or iss_dst /= ref_dst(s)
               or to_integer(iss_seg) /= PLAN(s).seg
               or to_integer(iss_off) /= PLAN(s).off
               or to_integer(iss_n_rows) /= PLAN(s).rows
               or iss_cons /= PLAN(s).cons
            then
              n_cmt_bad <= n_cmt_bad + 1;
              report "tb_seq_opdec: COMMIT MISMATCH at step "
                   & integer'image(s)
                   & ".  The locks are being moved for a different descriptor "
                   & "from the one that was checked -- the check/commit latch "
                   & "has come apart."
                severity error;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE EXPONENT, END TO END (O15).  After every completion of a producing
  -- step, read the captured exponent back out of the lock and compare it with
  -- what the stub reported at its `done`.  With EXP_DECAY = 0 the stub's
  -- `y_exp` is valid for exactly one cycle, so this passes only if the capture
  -- instant is the first cycle of `done`.
  -- ======================================================================
  echk : process(clk) is
    variable pend : integer := -1;      -- step whose exponent to verify
    variable want : integer := 0;
    variable stg  : integer := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pend := -1; stg := 0;
      else
        if stg = 1 then
          stg := 2;                      -- address settling
        elsif stg = 2 then
          n_exp_chk <= n_exp_chk + 1;
          if exp_rd_valid /= '1' or to_integer(exp_rd_data) /= want then
            n_exp_bad <= n_exp_bad + 1;
            report "tb_seq_opdec: CAPTURED EXPONENT WRONG for step "
                 & integer'image(pend) & ": region "
                 & integer'image(to_integer(exp_rd_region)) & " segment "
                 & integer'image(to_integer(exp_rd_seg)) & " reads "
                 & integer'image(to_integer(exp_rd_data)) & ", the unit "
                 & "reported " & integer'image(want) & " at its done.  A value "
                 & "read for the duration of a job was sampled after its "
                 & "producer moved on."
              severity error;
          end if;
          stg := 0;
        end if;

        if job_cmp = '1' then
          pend := to_integer(job_step);
          if pend < TBL_STEPS and PLAN(pend).prod = '1' then
            want := exp_of(pend);
            exp_rd_region <= to_unsigned(PLAN(pend).dst, 8);
            exp_rd_seg    <= to_unsigned(PLAN(pend).seg, 2);
            stg := 1;
          end if;
        end if;

        if y_exp_taken = '1' then
          n_taken <= n_taken + 1;
        end if;
      end if;
    end if;
  end process;

  acct : process(clk) is
  begin
    if rising_edge(clk) then
      if tok_reset = '1' then
        n_completed <= 0;
      elsif job_cmp = '1' then
        n_completed <= n_completed + 1;
      end if;
    end if;
  end process;

  hb : process(clk) is
  begin
    if rising_edge(clk) and HEARTBEAT > 0 then
      if (cyc mod HEARTBEAT) = 0 and cyc > 0 then
        report "HB cyc=" & integer'image(cyc)
             & " busy=" & std_logic'image(busy)
             & " step=" & integer'image(to_integer(job_step))
             & " chk=" & integer'image(n_chk)
             & " steps_done=" & integer'image(to_integer(steps_done))
             & " u_ready=" & integer'image(to_integer(unsigned(u_ready)))
             & " u_done=" & integer'image(to_integer(unsigned(u_done)))
             & " viol=" & std_logic'image(viol)
             & " err=" & std_logic'image(err);
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Stimulus.
  -- ======================================================================
  main : process is
    variable fail : natural := 0;
    variable expect_err : boolean;
    variable want_code  : integer;
    variable want_step  : integer;
    variable held_r     : integer;

    procedure chk(name : string; got, want : integer) is
    begin
      if got /= want then
        report "tb_seq_opdec: " & name & " is " & integer'image(got)
             & ", expected " & integer'image(want) severity error;
        fail := fail + 1;
      else
        report "  ok  " & name & " = " & integer'image(got);
      end if;
    end procedure;
  begin
    report "tb_seq_opdec: model=" & integer'image(MODEL.blocks)
         & " blocks, NCARDS=" & integer'image(NCARDS)
         & ", table = " & integer'image(TBL_STEPS) & " descriptors";
    report "  skew: URAM_LAT=" & integer'image(URAM_LAT)
         & " JOB_LAT=" & integer'image(JOB_LAT)
         & " LAT_SKEW=" & integer'image(LAT_SKEW)
         & " DONE_STYLE=" & integer'image(DONE_STYLE)
         & " STALE_HOLD=" & integer'image(STALE_HOLD)
         & " WR_N=" & integer'image(WR_N)
         & " WR_GAP=" & integer'image(WR_GAP)
         & " WR_TAIL=" & integer'image(WR_TAIL)
         & " EXP_DECAY=" & integer'image(EXP_DECAY);

    tbl_len_s <= to_unsigned(TBL_STEPS, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    expect_err := REL_NAIVE or (XW_AT >= 0) or (SRC2_BAD_AT >= 0)
               or (ROWS_BIG_AT >= 0) or (OFF_SEG_AT >= 0) or (WR_TAIL > 0);

    for t in 0 to TOKENS-1 loop
      tok_reset <= '1';
      wait until rising_edge(clk);
      tok_reset <= '0';
      host_x_exp <= to_signed(3 + t, EXP_W);
      go_in <= '1';
      wait until rising_edge(clk);
      go_in <= '0';

      -- The rogue exponent write, hazard A3, aimed at a region that a live
      -- consumer HOLDS.  Fired from the step counter rather than a cycle
      -- count so it lands in the same place under every skew.
      if XW_AT >= 0 then
        -- Wait for the step to be COMMITTED, not merely checked.  A region
        -- moves to HELD at the commit, so firing on `n_chk` alone lands the
        -- write while the region is still VALID, where a correct lock passes
        -- it and the test reports a design defect that is not there.  A test
        -- whose timing is set by the wrong event tests the wrong event.
        while not (job_valid = '1' and to_integer(job_step) = XW_AT) loop
          wait until rising_edge(clk);
        end loop;
        held_r := -1;
        for r in 0 to NREG-1 loop
          if PLAN(XW_AT).cons(r) = '1'
             and not (PLAN(XW_AT).prod = '1' and PLAN(XW_AT).dst = r) then
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
            report "tb_seq_opdec: hazard A3 -- an exponent write into region "
                 & integer'image(held_r) & ", HELD by the step reading it, "
                 & "was ALLOWED." severity error;
            fail := fail + 1;
          else
            report "  ok  step " & integer'image(XW_AT)
                 & ": exponent write into HELD region "
                 & integer'image(held_r) & " dropped (hazard A3)";
          end if;
          xw_we <= '0';
        end if;
      end if;

      wait until tok_done = '1' for 60 ms;
      if tok_done /= '1' then
        report "tb_seq_opdec: token " & integer'image(t)
             & " never completed -- the walk is wedged" severity failure;
      end if;
      wait until rising_edge(clk);

      report "---- token " & integer'image(t) & " ----";
      report "  steps_done=" & integer'image(to_integer(steps_done))
           & " started=" & integer'image(n_started)
           & " completed=" & integer'image(n_completed)
           & " checks=" & integer'image(n_chk)
           & " err=" & std_logic'image(err)
           & " code=" & integer'image(to_integer(unsigned(err_code)))
           & " step=" & integer'image(to_integer(err_step))
           & " | writes ok=" & integer'image(n_wr_ok)
           & " dropped=" & integer'image(n_wr_drop)
           & " silent=" & integer'image(n_silent)
           & " | exps checked=" & integer'image(n_exp_chk)
           & " taken=" & integer'image(n_taken);

      if not expect_err then
        chk("err", sl2i(err), 0);
        chk("steps_done", to_integer(steps_done), TBL_STEPS);
        chk("jobs started", n_started, TBL_STEPS-1);
        chk("jobs completed", n_completed, TBL_STEPS-1);
        chk("descriptor checks", n_chk, TBL_STEPS);
        chk("lock violations", sl2i(viol_seen), 0);
      else
        chk("err", sl2i(err), 1);
        want_step := -1;
        if REL_NAIVE then
          -- D section 5.3 read literally: the first A job frees XN and the
          -- second consumes a region nobody produced.  Step 2 is the wqkv k
          -- slice, the second of the six consecutive XN readers of section 4.2.
          want_code := 2; want_step := 2;
        elsif ROWS_BIG_AT >= 0 then
          want_code := 3; want_step := ROWS_BIG_AT;
        elsif OFF_SEG_AT >= 0 then
          want_code := 3; want_step := OFF_SEG_AT;
        elsif SRC2_BAD_AT >= 0 then
          -- Reported at the NEXT check: the candidate port group has no
          -- `src2`, so the check necessarily runs at commit.
          want_code := 3; want_step := SRC2_BAD_AT + 1;
        else
          want_code := 2;               -- XW_AT / WR_TAIL, via the violation
        end if;
        chk("err_code", to_integer(unsigned(err_code)), want_code);
        if want_step >= 0 then
          chk("err_step", to_integer(err_step), want_step);
        end if;
        if XW_AT >= 0 then
          chk("viol_step (the REAL offending step)",
              to_integer(viol_step), XW_AT);
        end if;
        -- Finding b2, as an invariant rather than a sentence: a mid-job lock
        -- violation has nowhere to be reported until the next descriptor
        -- check, so the step ERR_INFO names is exactly one past the offender.
        if XW_AT >= 0 or WR_TAIL > 0 then
          chk("err_step - viol_step (must be exactly 1)",
              to_integer(err_step) - to_integer(viol_step), 1);
        end if;
      end if;

      chk("decode mismatches at check", n_dec_bad, 0);
      chk("decode mismatches at commit", n_cmt_bad, 0);
      chk("captured exponents wrong", n_exp_bad, 0);
      chk("write-gate disagreements", n_wr_wrong, 0);
      chk("silent drops", n_silent, 0);

      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';
      wait until rising_edge(clk);
      exit when expect_err;
    end loop;

    if fail = 0 then
      report "tb_seq_opdec: PASS";
    else
      report "tb_seq_opdec: FAIL -- " & integer'image(fail)
           & " check(s) failed" severity failure;
    end if;

    running <= false;
    wait;
  end process;

  -- ======================================================================
  -- ORDERING GUARD (`ord_chk`).  Same rule as `tb_seq_desc_fetch`'s, at this
  -- unit's seam: the captured y_exp is the scalar, and `cmp_valid` is the
  -- instant `seq_region_lock` latches it against a region's data.
  --
  -- TWO separate obligations, and only the first has teeth against the
  -- gdn_conv defect shape:
  --
  --   1. ORDER.  `y_exp_taken` must pulse STRICTLY BEFORE `cmp_valid`, never
  --      at or after it.  A unit that captured at `job_cmp` instead of at the
  --      first `done` would update its register on the SAME edge as
  --      `cmp_valid`, so the lock latches the PREVIOUS job's exponent while
  --      the pulse arrives one cycle late.  Checking only the VALUE cannot
  --      see this: the stale value the lock takes and the value the guard
  --      later reads back are then the same wrong number.
  --   2. VALUE.  Between the capture and the commit the scalar must not move.
  --      This is the a3 freeze, and it is what mutation O3 attacks.
  -- ======================================================================
  ord_chk : process(clk) is
    variable seen  : boolean := false;
    variable post  : boolean := false;
    variable at_tk : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if job_issue = '1' then seen := false; post := false; end if;
      if y_exp_taken = '1' then
        assert not post
          report "tb_seq_opdec: y_exp_taken pulsed AFTER cmp_valid -- the "
               & "exponent was captured at or after the instant the lock "
               & "latched it, so the region is qualified by the PREVIOUS "
               & "job's scale.  Held value at the pulse " & to_string(y_exp_held)
          severity failure;
        seen  := true;
        at_tk := y_exp_held;
      end if;
      if cmp_valid = '1' then
        if seen then
          assert at_tk = cmp_y_exp
            report "tb_seq_opdec: the captured exponent CHANGED between "
                 & "y_exp_taken and cmp_valid -- " & to_string(at_tk)
                 & " at the capture, " & to_string(cmp_y_exp)
                 & " at the commit.  The scalar that qualifies a region's "
                 & "data must be final before the lock latches it."
            severity failure;
        end if;
        post := true;
      end if;
    end if;
  end process;

end architecture;
