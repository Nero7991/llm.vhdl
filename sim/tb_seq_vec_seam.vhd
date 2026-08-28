-- sim/tb_seq_vec_seam.vhd
-- SUBSYSTEM D, THE D-CTRL / D-VEC SEAM, WITH FIVE REAL UNITS AND NO STUB
-- BETWEEN THEM: `seq_desc_fetch` walks a descriptor table, `seq_opdec`
-- translates opcodes to regions and drives `seq_region_lock`, `seq_vec_issue`
-- turns the broadcast start into a by-value start and looks the source
-- exponents out of the lock, and `seq_vec_res` executes the residual.
--
-- WHY THIS BENCH EXISTS.  Before it, `seq_opdec` decoded `OP_VEC_RES` and
-- issued it to nothing, and `seq_vec_res` executed `OP_VEC_RES` and was
-- started by a testbench that handed it `i_n`, `i_exp_x` and `i_exp_e` out of
-- a vector file.  Each unit was therefore verified against the other unit's
-- STUB, which is precisely the condition that produced four findings when
-- `seq_desc_fetch` and `seq_region_lock` were first connected.
--
-- ======================================================================
-- THE CHAIN IS THE TEST, AND THAT IS THE WHOLE DESIGN OF THIS BENCH
-- ======================================================================
-- The residual is IN PLACE: it reads region X, writes region X, and publishes
-- X's new exponent, which `seq_opdec` captures at the unit's first `done` and
-- `seq_region_lock` latches at the commit.  The NEXT residual then reads that
-- exponent back out of the lock through `seq_vec_issue`.  So the feedback path
-- runs through all five units, and a single lost, stale, swapped or misrouted
-- exponent does not produce one locally wrong step -- it desynchronises every
-- remaining step of the token, with an error that GROWS.
--
-- `ref/seq_vec_chain_vec.c` is the oracle for that chain.  It shares no state
-- machine, no handshake and no control flow with any RTL here; it is a
-- sequential loop with one array of per-region exponents.  Its own oracles are
-- C1 (the exact running sum in __int128, against a bound accumulated from the
-- recipe's rounding rules) and C2 (whole-chain exponent-shift invariance), and
-- it is mutation tested by `sim/mutate_ref_seq_vec_chain.sh` BEFORE this bench
-- was written.
--
-- WHAT THE ORACLE CANNOT SEE, stated up front: the ARBITRATION.  `u_ready`
-- falling at the right instant, a start accepted while a completion is held, a
-- `done` that survives an ack -- none of that is a function of the input data.
-- Those are covered here by counting identities and protocol guards, which are
-- a weaker instrument, and the mutation table in the debugging note says which
-- mutations only they catch.
--
-- ======================================================================
-- THE TABLE IS SYNTHETIC IN LENGTH AND REAL IN FORMAT
-- ======================================================================
-- Descriptors are encoded with `seq_tbl_pkg.mk_desc`, the same function that
-- builds the real 491-descriptor Qwen3.5-9B token, so every field lands in the
-- byte the shipped decoder reads.  What is synthetic is the SCHEDULE: nine
-- steps per block instead of sixteen, `NELEM` elements instead of 4,096, so
-- that a whole configuration sweep runs in seconds rather than tens of
-- minutes.  The nine steps keep every shape the seam has to handle:
--
--   0 VEC_NORM  X  -> XN     a D-vec op with ONE source
--   1 A_JOB     XN -> ER     a stub unit producing the residual's second input
--   2 VEC_RES   X,ER -> X    the IN-PLACE residual, the unit under test
--   3 VEC_NORM  X  -> XN
--   4 A_JOB     XN -> G
--   5 A_JOB     XN -> U
--   6 VEC_SWG   G,U -> H     a D-vec op with TWO sources, out of place
--   7 A_JOB     H  -> ER
--   8 VEC_RES   X,ER -> X
--
-- All three D-vec opcodes therefore arrive at ONE unit slot, which is what
-- `seq_desc_fetch`'s `unit_of` does with them and what makes `seq_vec_issue`'s
-- all-engines-ready rule load bearing.  The norm and the swiglu do not exist
-- yet, so they are stub engines behind the same adapter -- but they are stubs
-- of units this bench does not test, not stubs of the units it does.
--
-- ======================================================================
-- THE SKEW RULE
-- ======================================================================
-- Every producer gets its own generic and no configuration is privileged.
-- Counter-intuitive and already paid for twice in this subsystem: the
-- dangerous configuration for a job shadow is a FAST memory and a SLOW unit,
-- because that is when the prefetch of step n+1 completes while step n is
-- still live.  A throughput-tuned run never gets the prefetch ahead at all.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.seq_tbl_pkg.all;

entity tb_seq_vec_seam is
  generic(
    VECS      : string   := "seq_vec_chain_vec.txt";
    -- Elements per region.  MUST match the vector file's n; the shape header
    -- is asserted, so a mismatch is loud rather than silent.
    NELEM     : natural  := 250;
    -- Chained residual steps.  Two per block, so NRES must be even.
    NRES      : natural  := 8;
    LANES     : positive := 8;

    -- ---- producer 1: the descriptor memory --------------------------------
    URAM_LAT    : natural := 1;
    -- ---- producer 2: the four stub units A, B, C, E -----------------------
    JOB_LAT     : natural := 12;
    LAT_SKEW    : natural := 3;
    READY_GAP   : natural := 0;
    DONE_STYLE  : natural := 0;   -- 0 level-until-ack, 1 one-cycle pulse, 2 timer
    DONE_HOLD   : natural := 3;
    STALE_HOLD  : natural := 0;
    READY_EARLY : boolean := false;
    EXP_DECAY   : natural := 0;
    -- ---- producer 3: the two STUB D-vec engines behind the adapter --------
    -- The real engine is `seq_vec_res` at index 1 and none of these touch it.
    VLAT        : natural := 5;
    VTAKEN_LAG  : natural := 0;   -- cycles the engine leaves `start` unaccepted
    VDONE_STYLE : natural := 0;   -- 0 level-until-ack, 1 pulse, 2 timer
    VDONE_HOLD  : natural := 3;
    VREADY_GAP  : natural := 0;   -- cycles `ready` stays low after a completion
    VREADY_EARLY: boolean := false;
    VEXP_DECAY  : natural := 0;   -- cycles of `done` for which y_exp is valid

    -- ---- fault injection, one at a time -----------------------------------
    -- A D-vec step whose element count does not fit the engines' port.  Set
    -- to 2**VN_W, which the LOCK accepts (the region is that large) and the
    -- ADAPTER must reject -- the lm_head truncation trap, at this seam.
    ROWS_BIG_AT : integer := -1;
    -- A generator that APPENDS into a D-vec destination: the second norm of
    -- every block writes XN at offset NELEM instead of 0, XN is not released,
    -- and the region is sized to hold both.  The lock's append-only rule then
    -- ACCEPTS it and the adapter must reject it, because a two-pass
    -- renormalise cannot append -- the output exponent is a property of the
    -- whole region.
    OFF_APPEND  : boolean := false;

    TOKENS      : natural := 1;
    HEARTBEAT   : natural := 0;
    STRICT      : boolean := false;
    MAXCYC      : natural := 20000000
  );
end entity;

architecture sim of tb_seq_vec_seam is

  constant EPOCH_W : positive := 4;
  constant NUNIT   : positive := 5;
  constant STEP_W  : positive := 11;
  constant NREG    : natural  := NREGION;
  constant ADDR_W  : positive := 16;      -- the lock's element-address width
  constant EXP_W   : positive := 16;
  constant MANT_W  : positive := 16;
  constant ACC_W   : positive := 32;
  constant SEGS    : positive := 3;
  constant VN_W    : positive := 13;      -- the D-vec engines' count width
  constant NVOP    : positive := 3;
  constant VEC_UNIT: natural  := 4;

  constant LOG2L   : natural := clog2(LANES);
  constant GA_W    : natural := VN_W - LOG2L;
  constant NG      : natural := (NELEM + LANES - 1) / LANES;
  constant NGMAX   : natural := NG + 2;
  constant POISON  : integer := -21846;   -- 0xAAAA as a signed 16-bit

  constant NBLK      : natural := NRES / 2;
  constant TBL_STEPS : natural := NBLK * 9 + 1;
  constant TBL_WORDS : natural := TBL_STEPS * 8;

  -- Region capacity.  2**VN_W so that the ROWS_BIG fault reaches the ADAPTER
  -- rather than being rejected one unit earlier by the lock's own bound; XN is
  -- doubled when the append fault is armed, for the same reason.
  function seam_sizes return integer_vector is
    variable s : integer_vector(0 to NREG-1) := (others => 2**VN_W);
  begin
    return s;
  end function;
  constant SIZES : integer_vector := seam_sizes;

  -- The per-opcode EXTRA consume mask, by region NAME so the generic and the
  -- reference plan below are not two copies of one magic number.
  constant M_RES : integer := 2**R_ER;
  constant M_SWG : integer := 2**R_U;
  constant OPC_CONS_C : integer_vector := (0, 0, 0, 0, 0, M_RES, M_SWG, 0);

  type tbl_arr is array (0 to TBL_WORDS-1) of std_logic_vector(63 downto 0);

  -- ======================================================================
  -- THE TABLE.  Encoded with the shipped `mk_desc`, so the byte layout is the
  -- real one; only the schedule is short.
  -- ======================================================================
  function build_seam_table return tbl_arr is
    variable t  : tbl_arr := (others => (others => '0'));
    variable p  : natural := 0;
    variable d  : desc_t;
    variable xo : natural;
    procedure emit(dd : desc_t) is
      variable ds : desc_t := dd;
    begin
      -- Same discipline as `seq_tbl_pkg.emit`: the three job scalars are
      -- stamped from the step index so that a stale or shared value is a
      -- WRONG NUMBER and not merely a repeat.  A field that is the same
      -- constant at every step makes every check on it vacuous.
      ds(2)(31 downto 0)  := std_logic_vector(to_signed(((p * 7) mod 61) - 30, 32));
      ds(2)(63 downto 32) := std_logic_vector(to_signed((p mod 23) - 11, 32));
      ds(4)(63 downto 32) := std_logic_vector(to_signed(((p * 5) mod 41) - 20, 32));
      for w in 0 to 7 loop
        t(p*8 + w) := ds(w);
      end loop;
      p := p + 1;
    end procedure;
  begin
    if OFF_APPEND then xo := NELEM; else xo := 0; end if;
    for b in 0 to NBLK-1 loop
      emit(mk_desc(OP_VEC_NORM, src => R_X,  dst => R_XN, n_rows => NELEM));
      emit(mk_desc(OP_A_JOB,    src => R_XN, dst => R_ER, n_rows => NELEM,
                   n_cols => NELEM));
      emit(mk_desc(OP_VEC_RES,  src => R_X,  src2 => R_ER, dst => R_X,
                   n_rows => NELEM));
      emit(mk_desc(OP_VEC_NORM, src => R_X,  dst => R_XN, dst_off => xo,
                   n_rows => NELEM));
      emit(mk_desc(OP_A_JOB,    src => R_XN, dst => R_G,  n_rows => NELEM,
                   n_cols => NELEM));
      emit(mk_desc(OP_A_JOB,    src => R_XN, dst => R_U,  n_rows => NELEM,
                   n_cols => NELEM));
      emit(mk_desc(OP_VEC_SWG,  src => R_G,  src2 => R_U, dst => R_H,
                   n_rows => NELEM));
      emit(mk_desc(OP_A_JOB,    src => R_H,  dst => R_ER, n_rows => NELEM,
                   n_cols => NELEM));
      emit(mk_desc(OP_VEC_RES,  src => R_X,  src2 => R_ER, dst => R_X,
                   n_rows => NELEM));
    end loop;
    emit(mk_desc(OP_END_TOKEN));
    assert p = TBL_STEPS
      report "tb_seq_vec_seam: emitted " & integer'image(p)
           & " descriptors but TBL_STEPS says " & integer'image(TBL_STEPS)
      severity failure;
    return t;
  end function;

  constant TBL : tbl_arr := build_seam_table;

  -- ======================================================================
  -- THE REFERENCE PLAN, for the release masks and the decode comparison.
  -- Built from the table words and the D spec's rules, not from `seq_opdec`.
  -- ======================================================================
  type step_t is record
    prod : std_logic;
    dst  : natural;
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
      p(s).off  := off mod 65536;
      case op is
        when OP_VEC_RES => p(s).cons(R_ER) := '1';
        when OP_VEC_SWG => p(s).cons(R_U)  := '1';
        when others     => null;
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
      else
        p(s).prod := '0';
        p(s).dst  := NREG;
        p(s).rows := 0;
      end if;
    end loop;

    -- Liveness: a region is released by the LAST step that reads it before
    -- the next step that produces it FROM SCRATCH.  A region only ever
    -- updated in place -- X, the residual stream -- is never released.  Under
    -- OFF_APPEND, XN is deliberately NOT released, which is what lets the
    -- lock's append-only rule accept the appending norm.
    for r in 0 to NREG-1 loop
      last_c := -1;
      for s in 0 to TBL_STEPS-1 loop
        if p(s).prod = '1' and p(s).dst = r and p(s).cons(r) = '0'
           and not (OFF_APPEND and r = R_XN) then
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

  -- Residual index of a step, or -1.  Step b*9+2 is residual 2b and b*9+8 is
  -- residual 2b+1.
  function res_of(s : integer) return integer is
    variable b, r : integer;
  begin
    if s < 0 or s >= TBL_STEPS then return -1; end if;
    b := s / 9;
    r := s mod 9;
    if    r = 2 then return 2*b;
    elsif r = 8 then return 2*b + 1;
    else             return -1;
    end if;
  end function;

  function is_vec(s : integer) return boolean is
    variable r : integer;
  begin
    if s < 0 or s >= TBL_STEPS then return false; end if;
    r := s mod 9;
    return r = 0 or r = 2 or r = 3 or r = 6 or r = 8;
  end function;

  -- The stub units' produced exponent, derived from the step so that a stale
  -- or shared capture is a WRONG NUMBER and not merely a repeat.
  function exp_of(s : integer) return integer is
  begin
    return ((s * 13) mod 97) - 48;
  end function;
  constant EXP_GARBAGE : integer := -9999;

  function sl2i(v : std_logic) return integer is
  begin if v = '1' then return 1; else return 0; end if; end function;

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
       : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal u_done_epoch : std_logic_vector(NUNIT*EPOCH_W-1 downto 0);
  signal u_y_exp      : std_logic_vector(NUNIT*EXP_W-1 downto 0);

  -- ---- seq_opdec --------------------------------------------------------
  signal go_in      : std_logic := '0';
  signal host_x_exp : signed(EXP_W-1 downto 0) := (others => '0');
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

  -- ---- seq_region_lock --------------------------------------------------
  signal wr_we      : std_logic := '0';
  signal wr_region  : unsigned(7 downto 0) := (others => '0');
  signal wr_gate    : std_logic;
  signal xw_we      : std_logic := '0';
  signal xw_region  : unsigned(7 downto 0) := (others => '0');
  signal xw_seg     : unsigned(1 downto 0) := "00";
  signal xw_exp     : signed(EXP_W-1 downto 0) := (others => '0');
  signal xw_gate    : std_logic;
  signal exp_rd_region : unsigned(7 downto 0);
  signal exp_rd_seg    : unsigned(1 downto 0);
  signal exp_rd_data   : signed(EXP_W-1 downto 0);
  signal exp_rd_valid  : std_logic;
  signal lock_state    : std_logic_vector(2*NREG-1 downto 0);

  -- ---- seq_vec_issue ----------------------------------------------------
  signal v_start, v_ready, v_taken, v_done, v_ack, v_err
       : std_logic_vector(NVOP-1 downto 0) := (others => '0');
  signal v_y_exp : std_logic_vector(NVOP*EXP_W-1 downto 0)
                 := (others => '0');
  signal v_n     : unsigned(VN_W-1 downto 0);
  signal v_exp_a, v_exp_b : signed(EXP_W-1 downto 0);
  signal v_reg_a, v_reg_b, v_reg_d : unsigned(7 downto 0);
  signal iss_lat, exp_lat : std_logic;
  signal vi_code  : std_logic_vector(3 downto 0);
  signal vi_epoch : unsigned(EPOCH_W-1 downto 0);
  signal vi_yexp  : signed(EXP_W-1 downto 0);

  -- ---- seq_vec_res ------------------------------------------------------
  signal r_en    : std_logic;
  signal r_addr  : unsigned(GA_W-1 downto 0);
  signal x_rdata, e_rdata : std_logic_vector(LANES*MANT_W-1 downto 0)
                          := (others => 'X');
  signal w_we    : std_logic;
  signal w_addr  : unsigned(GA_W-1 downto 0);
  signal w_be    : std_logic_vector(LANES-1 downto 0);
  signal w_data  : std_logic_vector(LANES*MANT_W-1 downto 0);
  signal vres_exp : signed(EXP_W-1 downto 0);

  -- ---- accounting -------------------------------------------------------
  type nat_arr is array (0 to NUNIT-1) of natural;
  signal n_start_a   : nat_arr := (others => 0);
  signal n_completed : natural := 0;
  signal n_chk       : natural := 0;
  signal n_res_done  : natural := 0;   -- residual steps verified
  signal n_bad_data  : natural := 0;   -- region contents wrong after a residual
  signal n_bad_iss   : natural := 0;   -- n / exponents / regions wrong at issue
  signal n_bad_beat  : natural := 0;   -- write-beat identity broken
  signal n_bad_gate  : natural := 0;   -- a residual write the lock dropped
  signal n_bad_tail  : natural := 0;   -- the region past n was written
  signal n_bad_ord   : natural := 0;   -- u_y_exp moved inside the done window
  signal n_iss_lat   : natural := 0;   -- adapter latch instants seen
  signal n_exp_lat   : natural := 0;
  signal tok_reset   : std_logic := '0';
  -- The exponent the ER-producing stub must report at its `done`.  It comes
  -- out of the CHAIN REFERENCE, not out of a step-index formula, because the
  -- residual's arithmetic depends on it and the reference has already fixed
  -- what the answer is for that value.  Every other stub keeps the step-index
  -- formula, so a shared or stale capture stays a WRONG NUMBER.
  signal er_exp_s    : signed(EXP_W-1 downto 0) := (others => '0');

  function sum(a : nat_arr) return natural is
    variable s : natural := 0;
  begin
    for i in a'range loop s := s + a(i); end loop;
    return s;
  end function;
  signal n_started : natural;

begin

  clk <= not clk after 0.5 ns when running else '0';

  assert (NRES mod 2) = 0
    report "tb_seq_vec_seam: NRES must be even (two residuals per block)"
    severity failure;

  cycles : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_seq_vec_seam: cycle cap reached, the run is wedged"
        severity failure;
    end if;
  end process;

  -- ======================================================================
  -- THE FIVE UNITS UNDER TEST.
  -- ======================================================================
  u_fetch : entity work.seq_desc_fetch
    generic map(
      NREG => NREG, EPOCH_W => EPOCH_W, NUNIT => NUNIT,
      NSUB_MAX => 64, STEP_W => STEP_W,
      WDOG_LIMIT => 200000, STRICT_PROTO => STRICT)
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

  u_opdec : entity work.seq_opdec
    generic map(
      NREG => NREG, SEGS => SEGS, ADDR_W => ADDR_W, EXP_W => EXP_W,
      NUNIT => NUNIT, STEP_W => STEP_W,
      OPC_CONS => OPC_CONS_C,
      MSEG_REG => NREG, MSEG_OFF1 => 0, MSEG_OFF2 => 0,
      REL_NAIVE => false,
      HOST_REG => R_X, HOST_ROWS => NELEM,
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

  -- THE SEAM.  Everything above this line existed and had never met anything
  -- below it.
  u_vissue : entity work.seq_vec_issue
    generic map(
      NVOP => NVOP, OP_BASE => OP_VEC_NORM, MY_UNIT => VEC_UNIT,
      NREG => NREG, EXP_W => EXP_W, VN_W => VN_W,
      EPOCH_W => EPOCH_W, STEP_W => STEP_W, STRICT => STRICT)
    port map(
      clk => clk, rst => rst,
      job_issue => job_issue, job_unit => job_unit, job_opcode => job_opcode,
      job_epoch => job_epoch, job_src => job_src, job_src2 => job_src2,
      job_dst => job_dst, job_dst_off => job_dst_off,
      job_n_rows => job_n_rows, job_step => job_step,
      u_start => u_start(VEC_UNIT), u_ack => u_ack(VEC_UNIT),
      u_ready => u_ready(VEC_UNIT), u_done => u_done(VEC_UNIT),
      u_err => u_err(VEC_UNIT),
      u_done_epoch => vi_epoch, u_y_exp => vi_yexp,
      exp_rd_region => exp_rd_region, exp_rd_seg => exp_rd_seg,
      exp_rd_data => exp_rd_data, exp_rd_valid => exp_rd_valid,
      v_start => v_start, v_ready => v_ready, v_taken => v_taken,
      v_done => v_done, v_ack => v_ack, v_err => v_err, v_y_exp => v_y_exp,
      v_n => v_n, v_exp_a => v_exp_a, v_exp_b => v_exp_b,
      v_reg_a => v_reg_a, v_reg_b => v_reg_b, v_reg_d => v_reg_d,
      iss_lat => iss_lat, exp_lat => exp_lat, err_code => vi_code);

  u_vres : entity work.seq_vec_res
    generic map(LANES => LANES, MANT_W => MANT_W, ACC_W => ACC_W,
                EXP_W => EXP_W, ADDR_W => VN_W, STRICT => true)
    port map(
      clk => clk, rst => rst,
      ready => v_ready(1), start => v_start(1), i_n => v_n,
      i_exp_x => v_exp_a, i_exp_e => v_exp_b, i_taken => v_taken(1),
      r_en => r_en, r_addr => r_addr, x_rdata => x_rdata, e_rdata => e_rdata,
      w_we => w_we, w_addr => w_addr, w_be => w_be, w_data => w_data,
      done => v_done(1), done_ack => v_ack(1),
      o_exp => vres_exp, o_shift => open, o_sat => open, err => v_err(1));

  v_y_exp(2*EXP_W-1 downto EXP_W) <= std_logic_vector(vres_exp);

  -- The residual's write strobe is policed by the lock, exactly as a real
  -- region write would be.  This is the seam's write half: a beat that lands
  -- outside [iss_commit, cmp_valid] is dropped and reported.
  wr_we     <= w_we;
  wr_region <= v_reg_d;

  -- ======================================================================
  -- PRODUCER 1: the descriptor memory.  `d_rdata` is 'X' whenever `d_rvalid`
  -- is low, so a DUT sampling on the wrong cycle poisons its shadow instead
  -- of being right by luck.  The ROWS_BIG fault is a HOST GENERATOR fault and
  -- is applied here, in the table, because that is where such a disagreement
  -- lives.
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
          if ROWS_BIG_AT >= 0 and a = ROWS_BIG_AT*8 + 1 then
            d_rdata <= TBL(a)(63 downto 32)
                     & std_logic_vector(to_unsigned(2**VN_W, 32));
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

  rel_mask <= PLAN(n_chk).rel when n_chk < TBL_STEPS else (others => '0');

  chkcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tok_reset = '1' then
        n_chk <= 0;
      elsif chk_req = '1' then
        n_chk <= n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- PRODUCER 2: four stub units, A B C E.  Unit 4 is the D-vec adapter and is
  -- NOT stubbed.
  -- ======================================================================
  gen_units : for u in 0 to NUNIT-2 generate
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
    signal my_er   : std_logic := '0';
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
            if job_dst = to_unsigned(R_ER, 8) then my_er <= '1';
            else                                   my_er <= '0'; end if;
            have    <= '1';
            rdy     <= '0';
            ep      <= job_epoch;
            lat     <= JOB_LAT + u*LAT_SKEW;
            dn_age  <= 0;
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
              if my_er = '1' then yexp <= er_exp_s;
              else                yexp <= to_signed(exp_of(my_step), EXP_W);
              end if;
            end if;
          end if;

          if dn = '1' then
            dn_age <= dn_age + 1;
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
  -- PRODUCER 3: the two STUB D-VEC ENGINES (norm at 0, swiglu at 2) behind
  -- the adapter.  These are the units that do not exist yet.  They carry the
  -- whole engine-side handshake sweep, because the engine that DOES exist --
  -- `seq_vec_res` at index 1 -- has one fixed completion discipline and its
  -- own sweep lives in `sim/run_seq_vec_res.sh`.
  -- ======================================================================
  gen_vstub : for v in 0 to NVOP-1 generate
    gv : if v /= 1 generate
      signal rdy   : std_logic := '1';
      signal dn    : std_logic := '0';
      signal tk    : std_logic := '0';
      signal have  : std_logic := '0';
      signal cnt   : integer := 0;
      signal tlag  : integer := 0;
      signal dhold : integer := 0;
      signal gap   : integer := 0;
      signal age   : natural := 0;
      signal njob  : natural := 0;
      signal yexp  : signed(EXP_W-1 downto 0) := (others => '0');
    begin
      v_ready(v) <= rdy;
      v_done(v)  <= dn;
      v_taken(v) <= tk;
      v_err(v)   <= '0';
      v_y_exp((v+1)*EXP_W-1 downto v*EXP_W) <= std_logic_vector(yexp);

      vstub : process(clk) is
      begin
        if rising_edge(clk) then
          tk <= '0';
          if rst = '1' then
            rdy <= '1'; dn <= '0'; have <= '0'; cnt <= 0;
            tlag <= VTAKEN_LAG; dhold <= 0; gap <= 0; age <= 0; njob <= 0;
            yexp <= to_signed(EXP_GARBAGE, EXP_W);
          else
            if have = '0' and dn = '0' and v_start(v) = '1' and rdy = '1' then
              if tlag > 0 then
                tlag <= tlag - 1;
              else
                tk   <= '1';
                have <= '1';
                rdy  <= '0';
                cnt  <= VLAT;
                age  <= 0;
                tlag <= VTAKEN_LAG;
                njob <= njob + 1;
                yexp <= to_signed(EXP_GARBAGE, EXP_W);
              end if;
            end if;

            if have = '1' and dn = '0' then
              if cnt > 0 then
                cnt <= cnt - 1;
              else
                dn    <= '1';
                age   <= 0;
                dhold <= VDONE_HOLD;
                -- Derived from the job ordinal, not a constant: a shared or
                -- stale capture must be a WRONG NUMBER and not a repeat.
                yexp  <= to_signed(((njob * 11) mod 71) - 35, EXP_W);
              end if;
            end if;

            if dn = '1' then
              age <= age + 1;
              if age >= VEXP_DECAY then
                -- The garbage MOVES, one step per cycle, and that is the whole
                -- point: a consumer that re-reads this port instead of
                -- capturing it at the first cycle of `done` then sees a value
                -- that CHANGES inside the done window, which the ordering
                -- guard catches.  A constant garbage value would make
                -- "captured once" and "re-read every cycle" indistinguishable
                -- after the first cycle.
                yexp <= to_signed(EXP_GARBAGE + (age mod 13), EXP_W);
              end if;
              case VDONE_STYLE is
                when 1 =>
                  dn <= '0'; have <= '0'; gap <= VREADY_GAP;
                when 2 =>
                  if dhold > 0 then dhold <= dhold - 1;
                  else dn <= '0'; have <= '0'; gap <= VREADY_GAP; end if;
                when others =>
                  if v_ack(v) = '1' then
                    dn <= '0'; have <= '0'; gap <= VREADY_GAP;
                    if VREADY_EARLY then rdy <= '1'; end if;
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
  end generate;

  -- The adapter's two payload outputs onto the walker's shared buses.  A type
  -- conversion, nothing more: the values themselves come out of the DUT, so
  -- the testbench models none of it.
  u_done_epoch((VEC_UNIT+1)*EPOCH_W-1 downto VEC_UNIT*EPOCH_W)
    <= std_logic_vector(vi_epoch);
  u_y_exp((VEC_UNIT+1)*EXP_W-1 downto VEC_UNIT*EXP_W)
    <= std_logic_vector(vi_yexp);

  -- ======================================================================
  -- THE REGION FABRIC, THE ER SOURCE AND EVERY DATA CHECK, IN ONE PROCESS.
  --
  -- One process because all of it needs the same vector-file arrays and VHDL
  -- has no way to share a plain variable between processes.  It owns:
  --   * the X and ER region models -- 1-cycle registered read with NO ready,
  --     free-running write strobe with NO ready, per D's skeleton spec 5.1;
  --   * loading X0 at the start of a token and ER before every residual;
  --   * the bit-exact comparison of X after every residual;
  --   * the write-beat counting identity;
  --   * the issue-time check of n, the two exponents and the three region
  --     numbers against the reference chain.
  --
  -- WRITE-FIRST memory, and that is load bearing: the residual reads X and
  -- writes X, and write-first makes an in-place overtake return the NEW data,
  -- visibly wrong, where read-first would return the old data and the run
  -- would pass on a design that only works because the memory happened to be
  -- read-first.
  --
  -- The read buses are 'X' whenever `r_en` is low AND whenever the adapter
  -- names a region this model does not hold, so a wrong region number poisons
  -- the pipeline instead of silently reading somebody else's data.
  -- ======================================================================
  fabric : process is
    type gvec_t is array (0 to NGMAX-1)
         of std_logic_vector(LANES*MANT_W-1 downto 0);
    type i1_t is array (0 to NELEM-1) of integer;
    type i2_t is array (0 to NRES-1) of i1_t;
    type ir_t is array (0 to NRES-1) of integer;

    variable xm, em : gvec_t := (others => (others => '0'));
    variable x0_v   : i1_t;
    variable ev_v, xv_v : i2_t;
    variable ee_v, oe_v, sh_v, st_v : ir_t;
    variable ex0_v  : integer;

    file fh : text;
    variable ln : line;
    variable iv, fn, fnres, fmw, faw, fsm, fkp : integer;

    variable gv     : std_logic_vector(LANES*MANT_W-1 downto 0);
    variable er_k   : integer := 0;    -- next ER block to publish
    variable cur_r  : integer := -1;   -- residual index of the live job
    variable cur_s  : integer := -1;   -- step index of the live D-vec job
    variable beats  : integer := 0;
    variable seen_b : std_logic_vector(0 to NGMAX-1);
    variable a      : integer;
    variable got, want : integer;
    variable bad    : boolean;

    procedure load_group(constant src : i1_t; variable m : inout gvec_t) is
      variable g : std_logic_vector(LANES*MANT_W-1 downto 0);
    begin
      for gi in 0 to NGMAX-1 loop
        for i in 0 to LANES-1 loop
          if gi*LANES + i < NELEM then
            g((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(src(gi*LANES+i), MANT_W));
          else
            -- POISON, not zero, past the end: a lane the DUT wrote that it
            -- should have masked reads as a plausible 0 against zeros.
            g((i+1)*MANT_W-1 downto i*MANT_W) :=
              std_logic_vector(to_signed(POISON, MANT_W));
          end if;
        end loop;
        m(gi) := g;
      end loop;
    end procedure;
  begin
    -- ---- the vector file, once ------------------------------------------
    file_open(fh, VECS, read_mode);
    readline(fh, ln);
    read(ln, fn); read(ln, fnres); read(ln, ex0_v);
    read(ln, fmw); read(ln, faw); read(ln, fsm); read(ln, fkp);
    assert fn = NELEM and fnres = NRES and fmw = MANT_W and faw = ACC_W
           and fsm = ACC_W - MANT_W - 1 and fkp = MANT_W - 2
      report "tb_seq_vec_seam: vector file shape mismatch -- the generator "
           & "and the generics disagree about n / nres / MANT_W / ACC_W"
      severity failure;
    readline(fh, ln);
    for i in 0 to NELEM-1 loop read(ln, iv); x0_v(i) := iv; end loop;
    for k in 0 to NRES-1 loop
      readline(fh, ln);
      read(ln, iv); read(ln, ee_v(k)); read(ln, oe_v(k));
      read(ln, sh_v(k)); read(ln, st_v(k));
      readline(fh, ln);
      for i in 0 to NELEM-1 loop read(ln, iv); ev_v(k)(i) := iv; end loop;
      readline(fh, ln);
      for i in 0 to NELEM-1 loop read(ln, iv); xv_v(k)(i) := iv; end loop;
    end loop;
    file_close(fh);

    host_x_exp <= to_signed(ex0_v, EXP_W);
    load_group(x0_v, xm);
    seen_b := (others => '0');

    loop
      wait until rising_edge(clk);
      exit when not running;

      -- ---- the region read port, registered, no ready -------------------
      if r_en = '1' then
        a := to_integer(r_addr);
        if a >= NGMAX then a := NGMAX-1; end if;
        if v_reg_a = to_unsigned(R_X, 8) then x_rdata <= xm(a);
        else                                  x_rdata <= (others => 'X'); end if;
        if v_reg_b = to_unsigned(R_ER, 8) then e_rdata <= em(a);
        else                                  e_rdata <= (others => 'X'); end if;
      else
        x_rdata <= (others => 'X');
        e_rdata <= (others => 'X');
      end if;

      -- ---- the region write port, free-running, no ready ----------------
      -- Write-first, so an in-place overtake is visible.
      if w_we = '1' then
        a := to_integer(w_addr);
        if wr_gate /= '1' then
          n_bad_gate <= n_bad_gate + 1;
          report "tb_seq_vec_seam: the region lock DROPPED a residual write "
               & "beat at group " & integer'image(a) & ", cycle "
               & integer'image(cyc) & ".  The unit is emitting outside the "
               & "window [iss_commit, cmp_valid] its own job holds."
            severity error;
        end if;
        if a < NGMAX and v_reg_d = to_unsigned(R_X, 8) then
          for i in 0 to LANES-1 loop
            if w_be(i) = '1' then
              xm(a)((i+1)*MANT_W-1 downto i*MANT_W) :=
                w_data((i+1)*MANT_W-1 downto i*MANT_W);
            end if;
          end loop;
        end if;
        -- The counting identity: one beat per group, ascending from zero,
        -- none twice.  This is what caught the pass-1 exit defect in
        -- `seq_vec_res`, and no value comparison would have: a second beat
        -- for a group overwrites the first, so the region ends up right.
        if a /= beats or a >= NGMAX or seen_b(a) = '1' then
          n_bad_beat <= n_bad_beat + 1;
          report "tb_seq_vec_seam: write group " & integer'image(a)
               & ", expected " & integer'image(beats)
               & ".  Beats must be one per group, ascending from 0, none twice."
            severity error;
        end if;
        if a < NGMAX then seen_b(a) := '1'; end if;
        beats := beats + 1;
      end if;

      -- ---- ER, published just before the residual that reads it ---------
      -- Fired at the A job's ISSUE rather than its completion, because the
      -- lock only lets the data land during that job and the model has no
      -- write port of its own.
      if job_issue = '1' and job_dst = to_unsigned(R_ER, 8) then
        if er_k < NRES then
          load_group(ev_v(er_k), em);
          er_exp_s <= to_signed(ee_v(er_k), EXP_W);
        end if;
      end if;

      -- ---- the ISSUE-TIME check, at the adapter's own instant -----------
      if iss_lat = '1' then
        n_iss_lat <= n_iss_lat + 1;
        cur_s := to_integer(job_step);
        cur_r := res_of(cur_s);
      end if;

      if exp_lat = '1' then
        n_exp_lat <= n_exp_lat + 1;
        beats  := 0;
        seen_b := (others => '0');
        if cur_r >= 0 and cur_r < NRES then
          bad := false;
          if to_integer(v_n) /= NELEM then
            report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                 & " started with n = " & integer'image(to_integer(v_n))
                 & ", the descriptor says " & integer'image(NELEM)
              severity error;
            bad := true;
          end if;
          -- THE FEEDBACK, as a number.  Residual 0 must see the exponent the
          -- HOST published; residual k must see the exponent residual k-1
          -- produced, having travelled seq_vec_res -> seq_vec_issue ->
          -- seq_opdec -> seq_region_lock and back.
          if cur_r = 0 then want := ex0_v; else want := oe_v(cur_r-1); end if;
          if to_integer(v_exp_a) /= want then
            report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                 & " read exponent " & integer'image(to_integer(v_exp_a))
                 & " for region X, the chain says " & integer'image(want)
                 & ".  The exponent the previous residual published did not "
                 & "make it back through the lock."
              severity error;
            bad := true;
          end if;
          if to_integer(v_exp_b) /= ee_v(cur_r) then
            report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                 & " read exponent " & integer'image(to_integer(v_exp_b))
                 & " for region ER, the chain says "
                 & integer'image(ee_v(cur_r))
              severity error;
            bad := true;
          end if;
          if v_reg_a /= to_unsigned(R_X, 8) or v_reg_b /= to_unsigned(R_ER, 8)
             or v_reg_d /= to_unsigned(R_X, 8) then
            report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                 & " named regions a=" & integer'image(to_integer(v_reg_a))
                 & " b=" & integer'image(to_integer(v_reg_b))
                 & " d=" & integer'image(to_integer(v_reg_d))
                 & ", the descriptor says X / ER / X"
              severity error;
            bad := true;
          end if;
          if bad then n_bad_iss <= n_bad_iss + 1; end if;
        end if;
      end if;

      -- ---- the RESULT, bit-exact, after the residual has committed ------
      if job_cmp = '1' and cur_r >= 0 and cur_r < NRES
         and to_integer(job_step) = cur_s then
        n_res_done <= n_res_done + 1;
        bad := false;
        for i in 0 to NELEM-1 loop
          got  := to_integer(signed(xm(i/LANES)
                    ((i mod LANES + 1)*MANT_W-1 downto (i mod LANES)*MANT_W)));
          want := xv_v(cur_r)(i);
          if got /= want and not bad then
            report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                 & " element " & integer'image(i) & " is "
                 & integer'image(got) & ", the chain reference says "
                 & integer'image(want)
              severity error;
            bad := true;
          end if;
        end loop;
        if bad then n_bad_data <= n_bad_data + 1; end if;
        -- The tail: every lane past `n` must still hold its poison.  This is
        -- what an `n` that is too large shows up as, and a zeroed model would
        -- hide it.
        bad := false;
        for gi in 0 to NGMAX-1 loop
          for i in 0 to LANES-1 loop
            if gi*LANES + i >= NELEM then
              if to_integer(signed(xm(gi)((i+1)*MANT_W-1 downto i*MANT_W)))
                 /= POISON and not bad then
                report "tb_seq_vec_seam: residual " & integer'image(cur_r)
                     & " wrote past element " & integer'image(NELEM)
                     & " -- group " & integer'image(gi) & " lane "
                     & integer'image(i)
                  severity error;
                bad := true;
              end if;
            end if;
          end loop;
        end loop;
        if bad then n_bad_tail <= n_bad_tail + 1; end if;

        if beats /= NG then
          n_bad_beat <= n_bad_beat + 1;
          report "tb_seq_vec_seam: residual " & integer'image(cur_r)
               & " emitted " & integer'image(beats) & " write beats, "
               & integer'image(NG) & " groups were expected"
            severity error;
        end if;
        er_k  := er_k + 1;
        cur_r := -1;
      end if;

      if job_cmp = '1' then cur_s := -1; end if;

      -- ---- a new token reloads X and rewinds the chain ------------------
      if tok_reset = '1' then
        load_group(x0_v, xm);
        er_k  := 0;
        cur_r := -1;
        cur_s := -1;
        n_res_done <= 0;
        n_iss_lat  <= 0;
        n_exp_lat  <= 0;
      end if;
    end loop;
    wait;
  end process;

  -- ======================================================================
  -- ORDERING GUARDS.
  --
  -- (c) at the ADAPTER's own port: `u_y_exp` is latched by `seq_opdec` at the
  --     FIRST cycle `u_done` is observed, so it must be final there and must
  --     not move for the rest of the done window.  Capturing at the first
  --     cycle and comparing at every later one is the `ord_chk` shape from
  --     `tb_gdn_conv`, and it is what a scalar published one state late dies
  --     on.
  --
  -- (a) at the same port: `v_n`, `v_exp_a`, `v_exp_b` and the three region
  --     numbers qualify a job that runs for a thousand cycles.  They are
  --     captured at `exp_lat` and must be identical at the completion.  This
  --     is the guard that a live read of `job_*` fails.
  -- ======================================================================
  ord_chk : process(clk) is
    variable seen : boolean := false;
    variable at_d : signed(EXP_W-1 downto 0) := (others => '0');
    variable held : boolean := false;
    variable h_n  : unsigned(VN_W-1 downto 0) := (others => '0');
    variable h_a, h_b : signed(EXP_W-1 downto 0) := (others => '0');
    variable h_ra, h_rb, h_rd : unsigned(7 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if rst = '1' then
        seen := false; held := false;
      else
        if u_done(VEC_UNIT) = '1' then
          if not seen then
            seen := true;
            at_d := signed(u_y_exp((VEC_UNIT+1)*EXP_W-1
                                    downto VEC_UNIT*EXP_W));
          else
            if at_d /= signed(u_y_exp((VEC_UNIT+1)*EXP_W-1
                                       downto VEC_UNIT*EXP_W)) then
              n_bad_ord <= n_bad_ord + 1;
              report "tb_seq_vec_seam: u_y_exp CHANGED after the first cycle "
                   & "of u_done -- " & to_string(at_d) & " then "
                   & to_string(u_y_exp((VEC_UNIT+1)*EXP_W-1
                                        downto VEC_UNIT*EXP_W))
                   & ".  A scalar the region lock is about to latch must be "
                   & "final before the valid that carries it."
                severity error;
            end if;
          end if;
        else
          seen := false;
        end if;

        if exp_lat = '1' then
          held := true;
          h_n  := v_n;  h_a := v_exp_a;  h_b := v_exp_b;
          h_ra := v_reg_a; h_rb := v_reg_b; h_rd := v_reg_d;
        elsif held and u_done(VEC_UNIT) = '1' then
          if h_n /= v_n or h_a /= v_exp_a or h_b /= v_exp_b
             or h_ra /= v_reg_a or h_rb /= v_reg_b or h_rd /= v_reg_d then
            n_bad_ord <= n_bad_ord + 1;
            report "tb_seq_vec_seam: a job-scoped value MOVED between the "
                 & "adapter's latch instant and the completion.  The engine "
                 & "read it for the whole job and its source moved on."
              severity error;
          end if;
          held := false;
        end if;
      end if;
    end if;
  end process;

  -- The seq_opdec-side ordering guard, unchanged in spirit from
  -- `tb_seq_opdec`: the capture must be STRICTLY BEFORE the lock latches it.
  opd_ord : process(clk) is
    variable seen  : boolean := false;
    variable post  : boolean := false;
    variable at_tk : signed(EXP_W-1 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if job_issue = '1' then seen := false; post := false; end if;
      -- THE TOKEN-START HOST PUBLISH IS NOT A JOB COMPLETION, and treating it
      -- as one is how this guard passed for two tokens against a coincidence.
      -- `seq_opdec` raises `cmp_valid` in T_PUB carrying the HOST's exponent
      -- for region X: no unit ran, so there is no `y_exp_taken` to pair it
      -- with, and the guard was still holding the LAST job of the PREVIOUS
      -- token.  It compared that against `host_x_exp` and agreed only because
      -- `exp_of(489) = 4` happens to equal `3 + t` at `t = 1`.  Measured: the
      -- same suite FAILS at TOKENS = 3, where the host exponent is 5.
      -- `host_busy` is high for the whole publish sequence and is the DUT's
      -- own statement that no job is being completed.
      if host_busy = '1' then
        seen := false;
        post := false;
      else
      if y_exp_taken = '1' then
        assert not post
          report "tb_seq_vec_seam: y_exp_taken pulsed AFTER cmp_valid -- the "
               & "exponent was captured at or after the instant the lock "
               & "latched it."
          severity failure;
        seen  := true;
        at_tk := y_exp_held;
      end if;
      if cmp_valid = '1' then
        if seen then
          assert at_tk = cmp_y_exp
            report "tb_seq_vec_seam: the captured exponent CHANGED between "
                 & "y_exp_taken and cmp_valid."
            severity failure;
        end if;
        post := true;
        end if;
      end if;
    end if;
  end process;

  n_started <= sum(n_start_a);

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
             & " step=" & integer'image(to_integer(job_step))
             & " chk=" & integer'image(n_chk)
             & " res=" & integer'image(n_res_done)
             & " u_ready=" & integer'image(to_integer(unsigned(u_ready)))
             & " u_done=" & integer'image(to_integer(unsigned(u_done)))
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

    procedure chk(name : string; got, want : integer) is
    begin
      if got /= want then
        report "tb_seq_vec_seam: " & name & " is " & integer'image(got)
             & ", expected " & integer'image(want) severity error;
        fail := fail + 1;
      else
        report "  ok  " & name & " = " & integer'image(got);
      end if;
    end procedure;
  begin
    report "tb_seq_vec_seam: " & integer'image(TBL_STEPS) & " descriptors, "
         & integer'image(NRES) & " chained residuals of "
         & integer'image(NELEM) & " elements, LANES=" & integer'image(LANES);
    report "  skew: URAM_LAT=" & integer'image(URAM_LAT)
         & " JOB_LAT=" & integer'image(JOB_LAT)
         & " DONE_STYLE=" & integer'image(DONE_STYLE)
         & " VLAT=" & integer'image(VLAT)
         & " VTAKEN_LAG=" & integer'image(VTAKEN_LAG)
         & " VDONE_STYLE=" & integer'image(VDONE_STYLE)
         & " VREADY_GAP=" & integer'image(VREADY_GAP);

    tbl_len_s <= to_unsigned(TBL_STEPS, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    expect_err := (ROWS_BIG_AT >= 0) or OFF_APPEND;

    for t in 0 to TOKENS-1 loop
      tok_reset <= '1';
      wait until rising_edge(clk);
      tok_reset <= '0';
      go_in <= '1';
      wait until rising_edge(clk);
      go_in <= '0';

      wait until tok_done = '1' for 200 ms;
      if tok_done /= '1' then
        report "tb_seq_vec_seam: token " & integer'image(t)
             & " never completed -- the walk is wedged" severity failure;
      end if;
      wait until rising_edge(clk);

      report "---- token " & integer'image(t) & " ----";
      report "  steps_done=" & integer'image(to_integer(steps_done))
           & " started=" & integer'image(n_started)
           & " completed=" & integer'image(n_completed)
           & " residuals verified=" & integer'image(n_res_done)
           & " adapter latches=" & integer'image(n_iss_lat)
           & " err=" & std_logic'image(err)
           & " code=" & integer'image(to_integer(unsigned(err_code)))
           & " step=" & integer'image(to_integer(err_step))
           & " vi_code=" & integer'image(to_integer(unsigned(vi_code)));

      if not expect_err then
        chk("err", sl2i(err), 0);
        chk("steps_done", to_integer(steps_done), TBL_STEPS);
        chk("jobs completed", n_completed, TBL_STEPS-1);
        chk("descriptor checks", n_chk, TBL_STEPS);
        chk("residuals verified", n_res_done, NRES);
        chk("adapter latch instants", n_iss_lat, 5*NBLK);
        chk("adapter exponent lookups", n_exp_lat, 5*NBLK);
        chk("lock violations", sl2i(viol_seen), 0);
      else
        chk("err", sl2i(err), 1);
        -- The adapter rejects the step, so the walker reports ERR_UNIT and
        -- `err_code` on the adapter narrows it.
        chk("err_code (ERR_UNIT)", to_integer(unsigned(err_code)), 1);
        if ROWS_BIG_AT >= 0 then
          chk("err_step", to_integer(err_step), ROWS_BIG_AT);
          chk("adapter code (EC_NROWS)", to_integer(unsigned(vi_code)), 2);
        else
          chk("adapter code (EC_OFF)", to_integer(unsigned(vi_code)), 5);
        end if;
      end if;

      chk("issue-time mismatches", n_bad_iss, 0);
      chk("residual results wrong", n_bad_data, 0);
      chk("write-beat identity broken", n_bad_beat, 0);
      chk("residual writes dropped by the lock", n_bad_gate, 0);
      chk("writes past the element count", n_bad_tail, 0);
      chk("ordering violations", n_bad_ord, 0);

      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';
      wait until rising_edge(clk);
      exit when expect_err;
    end loop;

    if fail = 0 then
      report "tb_seq_vec_seam: PASS";
    else
      report "tb_seq_vec_seam: FAIL -- " & integer'image(fail)
           & " check(s) failed" severity failure;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
