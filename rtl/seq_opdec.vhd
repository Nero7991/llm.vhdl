-- rtl/seq_opdec.vhd
-- Subsystem D: the opcode-to-region decode and the issue/commit sequencing
-- that joins `seq_desc_fetch` to `seq_region_lock`.  REAL RTL.
--
-- WHAT THIS IS.  `seq_desc_fetch` walks the descriptor table and hands out a
-- decoded 64-byte header.  `seq_region_lock` polices the activation regions
-- and wants a different vocabulary entirely: which regions this step PRODUCES
-- into, which it CONSUMES, which exponent SEGMENT it fills, and which regions
-- it is the LAST reader of.  Nothing turned one into the other.  Until now that
-- translation lived in `sim/tb_seq_region_lock.vhd` as a function, which meant
-- the two shipped units had never been connected to each other: each was
-- exercised against a STUB of the other across the `chk_req`/`chk_bad` verdict
-- channel.  This unit is that translation, in RTL, so the pair closes.
--
-- ======================================================================
-- THE THREE THINGS THE DESCRIPTOR FORMAT CANNOT SAY, AND WHAT IS DONE
-- ======================================================================
-- D design spec section 6.1's header carries `src`, `src2`, `dst`,
-- `dst_offset`, `n_rows`.  The lock needs a CONSUME MASK, an exponent SEGMENT
-- and a RELEASE MASK.  None of the three is derivable from one descriptor:
--
--   1. THE CONSUME MASK.  B reads four regions (QKV, Z, BETA, ALPHA) and C
--      reads three (QG, KIN, VIN).  Two region bytes cannot name four regions.
--      Resolved here with `OPC_CONS`, a per-opcode EXTRA-consume mask supplied
--      as a generic, so the full mask is `bit(src) or OPC_CONS(opcode)`.
--      **This is a decision, not a derivation, and it has a cost worth stating:
--      the region map leaks out of the table and into the build.**  D section
--      4.4's property is that the schedule is DATA -- a smaller model is a
--      shorter table and not different gateware -- and a generic keeps that
--      true across MODEL but not across the section 5.1 PACKED region map,
--      which unions {QKV,QG,G}, {Z,U} and {Y,H} and therefore changes B's and
--      C's consume sets.  A 16-bit `cons_mask` descriptor field would make it
--      data again; word 7 of the header is reserved and checked-zero, so the
--      room exists.  OPEN, and reported rather than silently taken.
--
--   2. THE EXPONENT SEGMENT.  QKV carries three captured exponents because the
--      three-way wqkv split exists precisely so q, k and v do not share a
--      scale (D section 2.2-B).  The descriptor has no segment field, so the
--      segment is INFERRED from `dst_offset` against `MSEG_OFF1`/`MSEG_OFF2`,
--      which are the model's key and value widths.  Same leak as (1), one
--      field narrower.  An offset that is not one of the three boundaries is
--      rejected as ERR_DESC rather than silently mapped to segment 2.
--
--   3. THE RELEASE MASK is not a property of a descriptor at all.  It is a
--      LIVENESS property of the schedule -- "is this the last step that reads
--      region R before something re-produces it" -- so only a whole-table pass
--      knows it, which means the host generator knows it, which means it
--      belongs in the descriptor, and section 6.1 has no field for it.  It
--      arrives here on the `rel_mask` port, exactly as `seq_region_lock`'s
--      `iss_rel` states the shape of the fix without inventing the field.
--
--      `REL_NAIVE` implements the OTHER reading, D section 5.3's own sentence
--      "the consumer's `done` returns R to FREE and clears `fill_ptr`", as a
--      release of every consumed region except an in-place destination.  It is
--      not a fallback: it is there so the testbench can SHOW that D section
--      5.3 contradicts D section 4.2 on the real table instead of asserting it
--      from a reading.  Section 4.2 has XN read by six consecutive A jobs;
--      under 5.3 the first of the six frees XN and the second consumes a
--      region nobody produced.
--
-- ======================================================================
-- THE TWO DEFECT CLASSES, AT THIS SEAM
-- ======================================================================
--
-- Class (a) -- a value read for the DURATION of a long operation while its
-- source moves on underneath.  Two instances here, and the second one is a
-- trap that looks like free lookahead:
--
--   a1. THE CHECK AND THE COMMIT SEE DIFFERENT DESCRIPTORS IF YOU LET THEM.
--       `seq_desc_fetch` asks for a verdict in S_CHECK, driving `chk_*` from
--       the PREFETCH bank, and issues one clocked state later, at which point
--       the banks have SWAPPED and `chk_*` describes the bank the previous job
--       used.  A commit driven from the live `chk_*` port therefore moves the
--       locks for the WRONG step.  Mechanism: the whole decode is latched at
--       the one instant `chk_req` is high, and the commit is driven from the
--       latch.  The `iss_*` ports carry the candidate decode combinationally
--       while `chk_req` is high (so the lock's own verdict is computed on the
--       step being checked) and the latched decode at every other instant.
--
--   a2. `chk_*` IS CONTINUOUSLY DRIVEN, AND READING IT OUTSIDE `chk_req` IS
--       THE SAME BUG ONE LEVEL DOWN.  It is tempting: `chk_*` shows the NEXT
--       descriptor during the current job, which would give the release mask
--       its missing lookahead for free.  It is not free.  The prefetch is
--       eight 64-bit beats and the bank is written beat by beat, so outside
--       `chk_req` the port shows a descriptor that is half step n and half
--       step n+1.  `pf_ready` is not exposed.  Nothing in this file reads
--       `chk_*` outside `chk_req`, and that is deliberate rather than
--       incidental.
--
--   a3. THE PRODUCED EXPONENT.  `seq_region_lock` captures `cmp_y_exp` at
--       `cmp_valid`, which this unit drives from `job_cmp` -- and `job_cmp` is
--       one clocked state AFTER the completion was observed.  A unit's `y_exp`
--       is guaranteed only while it is asserting `done`.  So the exponent is
--       captured HERE, at the first cycle the running unit's `done` is
--       observed, frozen, and presented at `cmp_valid`.  Reading the unit's
--       live `y_exp` port at `job_cmp` would sample it one to several cycles
--       late, which is a plausible wrong scale in one layer rather than a
--       fault.  `y_exp_taken` is the observable instant that makes the rule
--       checkable from outside, per the skeleton spec's normative rule.
--
-- Class (b) -- a completion signalled as a one-cycle pulse and discarded
-- because the consumer was busy:
--
--   b1. `viol` from the lock is a level held until `viol_ack`, and it is
--       captured here in an UNCONDITIONAL branch, sticky, first-offender-wins.
--
--   b2. A LOCK VIOLATION CANNOT BE REPORTED AT THE INSTANT IT HAPPENS, and
--       this is a property of the shipped interface rather than a choice.
--       `seq_desc_fetch` reads `chk_bad` only in S_CHECK.  A write strobe into
--       a HELD region happens in the middle of a job, thousands of cycles from
--       any S_CHECK.  So the violation is latched with the step index it
--       happened on (`viol_step`) and forced into `chk_bad` at the NEXT check,
--       where it aborts the token with ERR_LOCK.  Consequence, stated because
--       it will otherwise be discovered on hardware: **`err_step` in ERR_INFO
--       names the step AFTER the offender.**  `viol_step` here, and
--       `viol_region` on the lock, name the real one.
--
--   b3. THE LOCK HAS NO SOFT RESET AND D SECTION 10 NEEDS ONE.  Section 10's
--       policy on any error is "abort the token, the host re-runs it".  On an
--       aborted token `job_cmp` never fires, so the lock keeps a live
--       committed job and leaves regions HELD, and the next token's first
--       commit lands on top of it.  `seq_region_lock`'s only reset is `rst`.
--       This unit therefore OWNS that reset: `lock_rst` rises for one cycle at
--       every `go_in`.  Every region is FREE at every `go`, which is also what
--       the schedule assumes -- the host writes X afresh each token.
--
-- ======================================================================
-- A FOURTH FINDING: NOBODY PUBLISHED THE HOST'S X
-- ======================================================================
-- D section 3.2 leaves the embedding on the host: it writes the 10,240-byte
-- row into region X and its exponent into X_EXP before each `go`.  Section 5.1
-- lists the host as a producer of X.  But every mechanism that moves a region
-- out of FREE and captures its exponent is driven by a DESCRIPTOR, and the
-- host's write has no descriptor.  With the locks reset at `go`, the first
-- step of the token -- `attn_norm`, which reads X -- consumes a FREE region
-- and is correctly rejected as ERR_LOCK.  The schedule cannot start.
--
-- Discovered by connecting the two units, which is the point of connecting
-- them: neither testbench could see it, because `tb_seq_region_lock` modelled
-- the host write as a synthetic step 0 of its own plan and `tb_seq_desc_fetch`
-- had no locks at all.
--
--   Mechanism here: `go_in` from the host is NOT wired straight to the
--   walker's `go`.  This unit takes it, resets the locks, runs a three-cycle
--   PUBLISH of region `HOST_REG` (issue, commit, complete with `host_x_exp`),
--   and only then raises `go_out`.  So the ordering is by construction and is
--   observable on `host_busy`, rather than being a race between a three-cycle
--   sequence and however long the first descriptor fetch happens to take.
--   That race is the shape this project keeps paying for; making it a
--   handshake costs one state.
--
-- ======================================================================
-- WHAT THIS UNIT DOES NOT DO
-- ======================================================================
-- It does not hold activation data, arbitrate AXI, or decode the base array.
-- It is 0 DSP and 0 BRAM by construction: there is no multiply (the exponent
-- slot address is `region*SEGS`, and SEGS is an elaboration constant), and no
-- array wide or deep enough to infer memory.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_opdec is
  generic(
    NREG    : positive := 14;
    SEGS    : positive := 3;
    ADDR_W  : positive := 16;
    EXP_W   : positive := 16;
    NUNIT   : positive := 5;
    STEP_W  : positive := 11;

    -- Per-opcode EXTRA consume mask, indexed by opcode 0..7, as a bit mask
    -- over regions.  See finding (1) in the header: this is what B's four and
    -- C's three read ports cost, given a header with two region bytes.
    --   0 A_JOB  1 B_JOB  2 C_JOB  3 E_COLL
    --   4 VEC_NORM  5 VEC_RESIDUAL  6 VEC_SWIGLU  7 END_TOKEN
    -- The default is the flat 14-region map of D section 5.1 at the
    -- `sim/seq_tbl_pkg.vhd` numbering: B adds Z|BETA|ALPHA, C adds KIN|VIN,
    -- the residual adds ER, swiglu adds U.
    OPC_CONS : integer_vector := (0, 56, 384, 0, 0, 8192, 2048, 0);

    -- The one region carrying more than one captured exponent, and the two
    -- destination offsets that select its segments 1 and 2.  Finding (2).
    -- NREG disables the mechanism entirely.
    MSEG_REG  : natural := 2;
    MSEG_OFF1 : natural := 2048;
    MSEG_OFF2 : natural := 4096;

    -- false: the release mask comes from `rel_mask` (the host generator knows
    --        the liveness; the descriptor format must grow a field for it).
    -- true : D section 5.3's own sentence, applied literally.  Present so the
    --        contradiction with section 4.2 can be MEASURED.
    REL_NAIVE : boolean := false;

    -- The region the host writes before each token, and how many elements it
    -- writes.  See the fourth finding: without this publish the first step of
    -- every token consumes a FREE region.
    HOST_REG  : natural := 0;
    HOST_ROWS : natural := 4096;

    STRICT  : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ==================== TOKEN START (host -> walker) ==================
    -- The host's `go`.  It does NOT go straight to `seq_desc_fetch`: this unit
    -- resets the locks, publishes the host-written X region with its exponent,
    -- and only then raises `go_out`.  See the fourth finding.
    go_in      : in  std_logic;
    host_x_exp : in  signed(EXP_W-1 downto 0);
    go_out     : out std_logic;
    host_busy  : out std_logic;

    -- =================== CANDIDATE SIDE (seq_desc_fetch) ================
    -- Read ONLY while `chk_req` is high.  See a2 for why that restriction is
    -- load-bearing rather than stylistic.
    chk_req     : in  std_logic;
    chk_opcode  : in  unsigned(3 downto 0);
    chk_src     : in  unsigned(7 downto 0);
    chk_dst     : in  unsigned(7 downto 0);
    chk_dst_off : in  unsigned(31 downto 0);
    chk_n_rows  : in  unsigned(31 downto 0);
    -- The verdict back to the walker, combinational while `chk_req` is high:
    -- this unit's own field checks, ORed with the lock's, ORed with any
    -- violation that happened mid-job and had nowhere to be reported (b2).
    chk_bad     : out std_logic;
    chk_code    : out std_logic_vector(3 downto 0);

    -- The release mask for the step being checked.  Must be stable while
    -- `chk_req` is high.  Ignored when REL_NAIVE.
    rel_mask    : in  std_logic_vector(NREG-1 downto 0);

    -- ====================== LIVE SIDE (seq_desc_fetch) ==================
    job_issue   : in  std_logic;
    job_cmp     : in  std_logic;
    job_unit    : in  unsigned(2 downto 0);
    job_src2    : in  unsigned(7 downto 0);
    job_step    : in  unsigned(STEP_W-1 downto 0);

    -- =========================== UNIT SIDE ==============================
    -- `u_done` is a level held until ack, and `u_y_exp` is only guaranteed
    -- while it is high.  Unit u's exponent is at (u+1)*EXP_W-1 downto u*EXP_W.
    u_done   : in  std_logic_vector(NUNIT-1 downto 0);
    u_y_exp  : in  std_logic_vector(NUNIT*EXP_W-1 downto 0);

    -- ====================== TO/FROM seq_region_lock =====================
    lock_rst   : out std_logic;
    iss_req    : out std_logic;
    iss_commit : out std_logic;
    iss_prod   : out std_logic;
    iss_dst    : out unsigned(7 downto 0);
    iss_seg    : out unsigned(1 downto 0);
    iss_off    : out unsigned(ADDR_W-1 downto 0);
    iss_n_rows : out unsigned(ADDR_W-1 downto 0);
    iss_cons   : out std_logic_vector(NREG-1 downto 0);
    iss_rel    : out std_logic_vector(NREG-1 downto 0);
    iss_ok     : in  std_logic;
    iss_code   : in  std_logic_vector(3 downto 0);
    cmp_valid  : out std_logic;
    cmp_y_exp  : out signed(EXP_W-1 downto 0);
    viol       : in  std_logic;
    viol_code  : in  std_logic_vector(3 downto 0);
    viol_ack   : out std_logic;

    -- =========================== OBSERVATION ============================
    -- One cycle wide, at the instant the produced exponent was frozen.  The
    -- skeleton spec's normative rule requires every latched-by-a-consumer
    -- value to have an observable `_taken`; this is that instant, and the
    -- testbench asserts against it rather than against a schedule argument.
    y_exp_taken : out std_logic;
    y_exp_held  : out signed(EXP_W-1 downto 0);
    -- The step a lock violation actually happened on.  See b2: this is NOT
    -- the step `seq_desc_fetch` will report, which is the next one.
    viol_step   : out unsigned(STEP_W-1 downto 0);
    viol_seen   : out std_logic
  );
end entity;

architecture rtl of seq_opdec is

  constant OP_A_JOB    : integer := 0;
  constant OP_B_JOB    : integer := 1;
  constant OP_C_JOB    : integer := 2;
  constant OP_E_COLL   : integer := 3;
  constant OP_VEC_NORM : integer := 4;
  constant OP_VEC_RES  : integer := 5;
  constant OP_VEC_SWG  : integer := 6;
  constant OP_END_TOKEN: integer := 7;

  constant ERR_NONE : std_logic_vector(3 downto 0) := x"0";
  constant ERR_LOCK : std_logic_vector(3 downto 0) := x"2";
  constant ERR_DESC : std_logic_vector(3 downto 0) := x"3";

  constant NO_REGION : unsigned(7 downto 0) := x"FF";

  -- ---- candidate decode, combinational ---------------------------------
  signal c_prod   : std_logic;
  signal c_dst    : unsigned(7 downto 0);
  signal c_seg    : unsigned(1 downto 0);
  signal c_off    : unsigned(ADDR_W-1 downto 0);
  signal c_rows   : unsigned(ADDR_W-1 downto 0);
  signal c_cons   : std_logic_vector(NREG-1 downto 0);
  signal c_rel    : std_logic_vector(NREG-1 downto 0);
  signal c_bad    : std_logic;
  signal c_code   : std_logic_vector(3 downto 0);

  -- ---- the latch: THE ONE INSTANT the decode is frozen (a1) -------------
  signal l_prod   : std_logic := '0';
  signal l_dst    : unsigned(7 downto 0) := NO_REGION;
  signal l_seg    : unsigned(1 downto 0) := "00";
  signal l_off    : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal l_rows   : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal l_cons   : std_logic_vector(NREG-1 downto 0) := (others => '0');
  signal l_rel    : std_logic_vector(NREG-1 downto 0) := (others => '0');
  signal l_op     : unsigned(3 downto 0) := (others => '0');
  signal l_pend   : std_logic := '0';   -- a latched step not yet committed

  -- ---- produced-exponent capture (a3) -----------------------------------
  signal x_armed  : std_logic := '0';
  signal x_unit   : integer range 0 to NUNIT-1 := 0;
  signal x_taken  : std_logic := '0';
  signal x_pulse  : std_logic := '0';
  signal x_exp    : signed(EXP_W-1 downto 0) := (others => '0');

  -- ---- token start: reset the locks, publish the host's X, release the
  -- walker.  Four states rather than a race; see the fourth finding.
  type tstate_t is (T_IDLE, T_RST, T_REQ, T_CMT, T_PUB, T_GO);
  signal tstate : tstate_t := T_IDLE;

  -- ---- sticky descriptor / lock faults with nowhere to be reported ------
  signal s_err    : std_logic := '0';
  signal s_code   : std_logic_vector(3 downto 0) := ERR_NONE;
  signal s_step   : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal vack     : std_logic := '0';

  -- Mask of an opcode's extra consumed regions.  A function so there is one
  -- statement of the bound rather than two places that must agree.
  function opc_mask(op : unsigned) return std_logic_vector is
    variable r : std_logic_vector(NREG-1 downto 0) := (others => '0');
    variable i : integer;
  begin
    i := to_integer(op);
    if i <= OP_END_TOKEN then
      r := std_logic_vector(to_unsigned(OPC_CONS(OPC_CONS'low + i), NREG));
    end if;
    return r;
  end function;

  function reg_idx(r : unsigned) return integer is
  begin
    return to_integer(r(6 downto 0));
  end function;

begin

  -- Elaboration-time: a consume mask that does not fit NREG would be silently
  -- truncated by to_unsigned, which is the "plausible wrong number" shape.
  gen_chk : for i in OPC_CONS'range generate
    assert OPC_CONS(i) >= 0 and OPC_CONS(i) < 2**NREG
      report "seq_opdec: OPC_CONS entry does not fit NREG regions"
      severity failure;
  end generate;

  assert OPC_CONS'length = 8
    report "seq_opdec: OPC_CONS must have exactly 8 entries, one per opcode"
    severity failure;

  -- ======================================================================
  -- CANDIDATE DECODE.  A pure function of the `chk_*` ports.  Every compare
  -- is in parallel and the verdict is one level of OR, because it sits in
  -- series with the lock's own combinational verdict inside `seq_desc_fetch`'s
  -- single S_CHECK state -- the one timing claim in D that nothing has
  -- synthesised (skeleton spec, open item 4).
  -- ======================================================================
  decode : process(chk_opcode, chk_src, chk_dst, chk_dst_off, chk_n_rows,
                   rel_mask) is
    variable op    : integer;
    variable cons  : std_logic_vector(NREG-1 downto 0);
    variable prod  : std_logic;
    variable seg   : unsigned(1 downto 0);
    variable bad   : std_logic;
    variable why   : std_logic_vector(3 downto 0);
    variable d     : integer;
    variable inpl  : boolean;
  begin
    op   := to_integer(chk_opcode);
    bad  := '0';
    why  := ERR_NONE;
    seg  := "00";

    -- The consume mask: the named source, plus whatever the opcode implies.
    cons := opc_mask(chk_opcode);
    if chk_src /= NO_REGION and chk_src < NREG then
      cons(reg_idx(chk_src)) := '1';
    end if;

    -- The destination.
    if chk_dst = NO_REGION or chk_dst >= NREG then
      prod := '0';
    else
      prod := '1';
    end if;

    -- Segment inference, finding (2).  An offset that is not one of the three
    -- boundaries is a generator/gateware disagreement about the wqkv layout,
    -- not a new placement, so it is rejected rather than mapped to segment 2.
    if prod = '1' and MSEG_REG < NREG and reg_idx(chk_dst) = MSEG_REG then
      if    chk_dst_off = 0                                       then seg := "00";
      elsif chk_dst_off = to_unsigned(MSEG_OFF1, 32)              then seg := "01";
      elsif chk_dst_off = to_unsigned(MSEG_OFF2, 32)              then seg := "10";
      else
        bad := '1'; why := ERR_DESC;
      end if;
      if seg >= SEGS then
        bad := '1'; why := ERR_DESC;
      end if;
    end if;

    -- Width.  `dst_offset` and `n_rows` are 32-bit in the header and the lock
    -- is region-scoped at ADDR_W.  A silent truncation here is exactly the
    -- `TO_UNSIGNED: vector truncated` trap the first D pass hit at lm_head,
    -- and the fix there was to say ZERO when there is no destination region --
    -- lm_head emits 248,320 rows and has none.  A destination region WITH an
    -- out-of-range count is a different thing and is an error.
    c_off  <= resize(chk_dst_off(ADDR_W-1 downto 0), ADDR_W);
    if prod = '1' then
      c_rows <= resize(chk_n_rows(ADDR_W-1 downto 0), ADDR_W);
      if chk_dst_off >= 2**ADDR_W or chk_n_rows >= 2**ADDR_W then
        bad := '1'; why := ERR_DESC;
      end if;
    else
      c_rows <= (others => '0');
    end if;

    -- In-place: a step that both consumes and produces one region.  The
    -- residual reads X and ER and writes X.  The lock's in-place arm requires
    -- offset 0, and this is where a table that appends in place is caught.
    inpl := false;
    if prod = '1' then
      d := reg_idx(chk_dst);
      inpl := cons(d) = '1';
      if inpl and chk_dst_off /= 0 then
        bad := '1'; why := ERR_DESC;
      end if;
    end if;

    -- END_TOKEN and E_COLL at NCARDS = 1 touch nothing.  END_TOKEN reaching
    -- here at all is normal: `seq_desc_fetch` checks it and then leaves.
    if op = OP_END_TOKEN then
      cons := (others => '0');
      prod := '0';
    end if;

    c_prod <= prod;
    c_dst  <= chk_dst;
    c_seg  <= seg;
    c_cons <= cons;
    c_bad  <= bad;
    c_code <= why;

    -- The release mask.  See finding (3): under REL_NAIVE this is D section
    -- 5.3 read literally, and it is wrong on D section 4.2's own schedule.
    if REL_NAIVE then
      for i in 0 to NREG-1 loop
        if cons(i) = '1' and not (prod = '1' and i = reg_idx(chk_dst)) then
          c_rel(i) <= '1';
        else
          c_rel(i) <= '0';
        end if;
      end loop;
    else
      c_rel <= rel_mask;
    end if;
  end process;

  -- ======================================================================
  -- THE LATCH, and the commit.  a1: the commit must move the locks for the
  -- step that was CHECKED, and by the time `job_issue` arrives the descriptor
  -- banks have swapped underneath `chk_*`.
  -- ======================================================================
  latch : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tstate = T_RST then
        l_pend <= '0';
        l_prod <= '0';
        l_dst  <= NO_REGION;
        l_seg  <= "00";
        l_off  <= (others => '0');
        l_rows <= (others => '0');
        l_cons <= (others => '0');
        l_rel  <= (others => '0');
        l_op   <= (others => '0');
      else
        if chk_req = '1' then
          l_prod <= c_prod;
          l_dst  <= c_dst;
          l_seg  <= c_seg;
          l_off  <= c_off;
          l_rows <= c_rows;
          l_cons <= c_cons;
          l_rel  <= c_rel;
          l_op   <= chk_opcode;
          l_pend <= '1';
        elsif job_issue = '1' then
          l_pend <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE PRODUCED EXPONENT (a3).  Captured at the FIRST cycle the running
  -- unit's `done` is observed and frozen there, in an UNCONDITIONAL branch.
  -- `job_cmp`, which is what drives the lock's capture instant, is one clocked
  -- state later, and by then the unit's `y_exp` is not guaranteed.
  -- ======================================================================
  xcap : process(clk) is
  begin
    if rising_edge(clk) then
      x_pulse <= '0';
      if rst = '1' or tstate = T_RST then
        x_armed <= '0';
        x_taken <= '0';
        x_unit  <= 0;
        x_exp   <= (others => '0');
      else
        if x_armed = '1' and x_taken = '0' and u_done(x_unit) = '1' then
          x_exp   <= signed(u_y_exp((x_unit+1)*EXP_W-1 downto x_unit*EXP_W));
          x_taken <= '1';
          x_pulse <= '1';
        end if;

        -- Arming is last so an issue and a completion landing on one edge
        -- cannot leave the capture armed against the previous unit.
        if job_cmp = '1' then
          x_armed <= '0';
          x_taken <= '0';
        end if;
        if job_issue = '1' then
          x_armed <= '1';
          x_taken <= '0';
          x_unit  <= to_integer(job_unit);
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- STICKY FAULTS WITH NOWHERE TO BE REPORTED (b1, b2).  Unconditional.
  -- ======================================================================
  sticky : process(clk) is
    variable extra : std_logic_vector(NREG-1 downto 0);
  begin
    if rising_edge(clk) then
      vack <= '0';
      if rst = '1' or tstate = T_RST then
        s_err  <= '0';
        s_code <= ERR_NONE;
        s_step <= (others => '0');
      else
        -- A lock violation.  Level, held until `viol_ack`; captured here and
        -- forced into `chk_bad` at the next check, because the walker reads
        -- `chk_bad` only in S_CHECK.
        if viol = '1' and vack = '0' then
          vack <= '1';
          if s_err = '0' then
            s_err  <= '1';
            s_code <= viol_code;
            s_step <= job_step;
          end if;
        end if;

        -- The `src2` consistency check.  A named second source must be one of
        -- the regions this opcode is declared to consume; otherwise the host
        -- generator and this decode disagree about what the step reads, and
        -- the step would run against a region nobody locked.  This is the
        -- byte-identical-tables discipline of the descriptor format applied to
        -- a field the CANDIDATE port group does not expose -- `seq_desc_fetch`
        -- carries `chk_opcode/src/dst/dst_off/n_rows` and no `chk_src2` -- so
        -- it necessarily runs at COMMIT, one state after the check, and its
        -- abort lands one step late.  Adding `chk_src2` to `seq_desc_fetch`
        -- would move it before the start; that is an interface change and is
        -- proposed rather than made.
        if job_issue = '1' then
          extra := opc_mask(l_op);
          if job_src2 /= NO_REGION then
            if job_src2 >= NREG then
              if s_err = '0' then
                s_err <= '1'; s_code <= ERR_DESC; s_step <= job_step;
              end if;
            elsif extra(reg_idx(job_src2)) = '0' then
              if s_err = '0' then
                s_err <= '1'; s_code <= ERR_DESC; s_step <= job_step;
              end if;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- TOKEN START.  Reset the locks, publish the host's X region and its
  -- exponent, then release the walker.  The fourth finding: this sequence has
  -- no descriptor, so nothing else in D could have done it, and the ordering
  -- against the walker's first fetch is made a handshake rather than a race.
  -- ======================================================================
  tok_fsm : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        tstate <= T_IDLE;
      else
        case tstate is
          when T_IDLE => if go_in = '1' then tstate <= T_RST;  end if;
          when T_RST  =>                     tstate <= T_REQ;
          when T_REQ  =>                     tstate <= T_CMT;
          when T_CMT  =>                     tstate <= T_PUB;
          when T_PUB  =>                     tstate <= T_GO;
          when T_GO   =>                     tstate <= T_IDLE;
        end case;
      end if;
    end if;
  end process;

  go_out    <= '1' when tstate = T_GO else '0';
  host_busy <= '0' when tstate = T_IDLE else '1';

  -- ======================================================================
  -- OUTPUTS.
  -- ======================================================================
  lock_rst <= '1' when rst = '1' or tstate = T_RST else '0';

  -- The lock's verdict must be computed on the step being CHECKED, so while
  -- `chk_req` is high the issue ports carry the candidate decode; at every
  -- other instant, including the commit, they carry the latch.  One mux, and
  -- it is the whole of mechanism a1.  The host publish overrides both, and it
  -- cannot collide with either: `go_out` has not been raised yet, so the
  -- walker is still in S_IDLE and no check or issue can be outstanding.
  iss_req    <= '1' when tstate = T_REQ
                else chk_req;
  iss_commit <= '1' when tstate = T_CMT
                else '1' when job_issue = '1' and l_pend = '1'
                else '0';

  iss_prod   <= '1'                              when tstate = T_REQ or tstate = T_CMT
                else c_prod when chk_req = '1' else l_prod;
  iss_dst    <= to_unsigned(HOST_REG, 8)         when tstate = T_REQ or tstate = T_CMT
                else c_dst  when chk_req = '1' else l_dst;
  iss_seg    <= "00"                             when tstate = T_REQ or tstate = T_CMT
                else c_seg  when chk_req = '1' else l_seg;
  iss_off    <= to_unsigned(0, ADDR_W)           when tstate = T_REQ or tstate = T_CMT
                else c_off  when chk_req = '1' else l_off;
  iss_n_rows <= to_unsigned(HOST_ROWS, ADDR_W)   when tstate = T_REQ or tstate = T_CMT
                else c_rows when chk_req = '1' else l_rows;
  iss_cons   <= (NREG-1 downto 0 => '0')         when tstate = T_REQ or tstate = T_CMT
                else c_cons when chk_req = '1' else l_cons;
  iss_rel    <= (NREG-1 downto 0 => '0')         when tstate = T_REQ or tstate = T_CMT
                else c_rel  when chk_req = '1' else l_rel;

  cmp_valid  <= '1' when tstate = T_PUB else job_cmp;
  cmp_y_exp  <= host_x_exp when tstate = T_PUB else x_exp;

  viol_ack   <= vack;

  chk_bad  <= '1' when chk_req = '1'
                       and (c_bad = '1' or iss_ok = '0' or s_err = '1')
              else '0';
  chk_code <= c_code when c_bad = '1'
              else iss_code when iss_ok = '0'
              else s_code;

  y_exp_taken <= x_pulse;
  y_exp_held  <= x_exp;
  viol_step   <= s_step;
  viol_seen   <= s_err;

  -- ======================================================================
  -- Simulation-only assertions.  A generic, not unconditional, because the
  -- testbench drives violating sequences on purpose.
  -- ======================================================================
  strict_chk : process(clk) is
  begin
    if rising_edge(clk) and rst = '0' and STRICT then
      assert not (job_issue = '1' and l_pend = '0')
        report "seq_opdec: a job was issued with no checked step latched.  "
             & "The check and the commit have come apart, which means the "
             & "locks would move for a descriptor nobody verified."
        severity warning;
      assert not (job_cmp = '1' and x_armed = '1' and x_taken = '0')
        report "seq_opdec: a step completed without the producing unit's "
             & "y_exp ever having been captured.  The lock is about to latch "
             & "a stale exponent for that region."
        severity warning;
      assert not (chk_req = '1' and job_issue = '1')
        report "seq_opdec: a check and an issue landed on the same cycle.  "
             & "The issue-port mux then presents the candidate to a commit."
        severity warning;
    end if;
  end process;

end architecture;
