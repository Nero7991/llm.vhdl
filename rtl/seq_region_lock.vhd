-- rtl/seq_region_lock.vhd
-- Subsystem D: the activation-region lock, fill pointer and exponent capture.
-- REAL RTL.
--
-- WHAT THIS IS.  Four of D's obligations from the sibling specs are written as
-- English sentences of the form "region R must not be written until unit U
-- asserts done":
--
--   O7  the `wq` output region must not be written by anyone until C asserts
--       `done`                                                  (C section 2.6 rule 1)
--   O8  C's `y` must be steered to a region disjoint from the `wq` output
--                                                               (C section 2.6 rule 2)
--   O9  B's `z` region must not be written until B asserts `done`, and B's `y`
--       region must be disjoint from `z` and from the qkv regions
--                                                               (B section 2.6)
--   O15 B's six input exponents must be the CAPTURED per-job values of the
--       producing A jobs, never a shared or stale value
--                                        (B section 1.4, the C2/CR3-2 lesson)
--
-- This unit is what turns those from schedule-review obligations into
-- runtime-checked ones.  O8 and the disjointness half of O9 need no logic at
-- all: regions are NAMED, not addressed, so no descriptor can express an
-- overlap between two of them.  What needs logic is O7, the write half of O9,
-- and O15, and that is a lock, a fill pointer and an exponent register file.
--
-- ======================================================================
-- THE FINDING THIS UNIT EXISTS TO FIX
-- ======================================================================
-- D design spec section 5.3 locks a region's DATA.  Section 5.4 captures its
-- exponent at the producer's `done`.  Nothing in either section says the
-- exponent register of a HELD region is also frozen -- and the consumer reads
-- that exponent for the WHOLE of its job, exactly as `gdn_emit_chain` read
-- `w_mant` for the whole of a block.  A later producer aimed at the same
-- exponent slot would overwrite it mid-consumer-job, and the failure would
-- look like a scale error in one layer, not like a wiring fault.  That is
-- hazard A3 of the 2026-08-27 skeleton spec, filed as a NEW finding, and it is
-- the same defect class as the `w_mant` latch one seam over.
--
--   Mechanism here: **the exponent capture register is part of the locked
--   object.**  A write to the exponent slot of a HELD region is DROPPED and
--   raises ERR_LOCK, identically to a data write.  One extra term in a check
--   that already existed, and it converts a silent scale corruption into a
--   named error with the offending region.
--
-- ======================================================================
-- THE COMPLETION EVENT IS A LEVEL, NOT A PULSE
-- ======================================================================
-- `viol` is held until `viol_ack`.  A lock violation is a completion-shaped
-- event and D consumes it from a state machine that is provably not always
-- listening; `docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md` is what a
-- one-cycle event costs.  The violation is also STICKY in its own right: the
-- first offender is latched into `viol_region` / `viol_code` and later ones do
-- not overwrite it, so the report names the cause rather than the last
-- symptom.
--
-- ======================================================================
-- LOCK STATES AND TRANSITIONS
-- ======================================================================
--   FREE   no valid contents; a producer may claim it, starting at offset 0
--   VALID  holds data; readable, and a producer may APPEND at `fill_ptr`
--   HELD   a consumer is reading it right now; EVERY write is dropped and
--          raises ERR_LOCK, and that now includes exponent writes
--
--   issue with `prod` -> dst must be FREE or VALID and `off` must equal its
--                        `fill_ptr`; it moves to VALID
--   issue with `cons` -> every region in `iss_cons` must be VALID; they move
--                        to HELD.  A FREE one means the schedule is consuming
--                        something nobody produced, which is ERR_LOCK rather
--                        than a silent read of whatever the last block left
--   producer completes -> `fill_ptr` advances by `n_rows`, and `y_exp` is
--                        CAPTURED into the destination's exponent slot
--   consumer completes -> held regions return to VALID, or to FREE with
--                        `fill_ptr` cleared if `iss_rel` named them
--
-- TWO PLACES THE SPEC DOES NOT DECIDE, AND WHAT WAS CHOSEN
--
--   1. MULTIPLE READERS.  See the note on `iss_rel` below.  D section 5.3's
--      "the consumer's done returns R to FREE" contradicts D section 4.2's own
--      schedule, where XN is read by six consecutive A jobs.  Resolved with an
--      explicit release mask, which the section 6.1 descriptor format does not
--      currently carry.  OPEN, and reported as such.
--
--   2. IN-PLACE UPDATE.  The residual step reads X and ER and writes X, so X
--      is both consumed and produced by one step.  The two obvious readings
--      disagree: "consume then produce" leaves X HELD with a write pending;
--      "produce then consume" lets a write land on a region the same step is
--      reading.  **Chosen, and flagged as a decision rather than a
--      derivation:** a region appearing in BOTH `iss_cons` and `iss_dst` is
--      IN-PLACE.  It moves to HELD like any consumed region, its own writes
--      are permitted because the write gate keys on the committed job's own
--      destination, its `iss_off` must be 0 (it is rewritten, not appended
--      to), and at completion `fill_ptr` becomes `n_rows` and it returns to
--      VALID.  OPEN, and reported as such.
--
-- ======================================================================
-- WHAT THIS UNIT DOES NOT DO
-- ======================================================================
-- It does not hold activation data.  The region BANKS are separate RTL that
-- does not exist yet (D section 5.1's ten BLOCK-wide banks at 8 RAMB36 each,
-- set by PORT WIDTH and not by capacity).  This unit polices their write
-- strobes and owns their metadata: lock state, fill pointer, exponent.  It is
-- 0 DSP and 0 BRAM by construction -- there is no multiply and no array wide
-- enough to infer memory.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_region_lock is
  generic(
    -- Element capacity of each region, indexed by region number.  Passed as an
    -- unconstrained array so the region map lives with the host generator that
    -- owns it, and NREG is derived rather than declared twice.  The flat map
    -- at 27B is 14 regions; the packed fallback is 6.
    REG_SIZE : integer_vector := (4096, 4096, 8192, 4096, 32, 32,
                                  8192, 1024, 1024, 4096,
                                  12288, 12288, 12288, 4096);
    -- Exponent segments per region.  QKV carries three (q, k, v) because the
    -- wqkv split exists precisely so that each segment gets its own y_exp;
    -- every other region uses segment 0.  Uniform rather than per-region so
    -- the slot address is `region*SEGS + seg`, a shift and an add.
    SEGS    : positive := 3;
    ADDR_W  : positive := 16;
    EXP_W   : positive := 16;
    -- Simulation-only assertions.  Synthesise to nothing.
    STRICT  : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ===================== ISSUE-TIME CHECK AND COMMIT ==================
    -- `iss_req` is asked one clocked state BEFORE the unit starts, which is
    -- the A section 7.6 discipline: a bad table aborts before it produces
    -- output rather than after.  `iss_ok` is combinational and valid while
    -- `iss_req` is high.  `iss_commit` is the separate, later strobe that
    -- actually moves the locks, so the sequencer can refuse a step it does
    -- not like without having already changed state.
    iss_req     : in  std_logic;
    iss_commit  : in  std_logic;
    -- This step produces into `iss_dst`, segment `iss_seg`, at `iss_off`.
    iss_prod    : in  std_logic;
    iss_dst     : in  unsigned(7 downto 0);          -- 0xFF = produces no region
    iss_seg     : in  unsigned(1 downto 0);
    iss_off     : in  unsigned(ADDR_W-1 downto 0);
    iss_n_rows  : in  unsigned(ADDR_W-1 downto 0);
    -- Regions this step CONSUMES.  A bitmask because B reads four and C reads
    -- three; one region number would not express it.
    iss_cons    : in  std_logic_vector(REG_SIZE'length-1 downto 0);
    -- Regions this step is the LAST reader of, and which therefore return to
    -- FREE at its completion instead of back to VALID.
    --
    -- WHY THIS PORT EXISTS, AND A GAP IN THE D DESIGN SPEC.  Section 5.3 says
    -- "the consumer's `done` returns R to FREE and clears `fill_ptr`", which is
    -- written for B and C -- one consumer per region per block.  It
    -- contradicts the spec's OWN schedule: section 4.2 has region XN read by
    -- SIX consecutive A jobs (steps 2 to 7).  Under the section 5.3 rule the
    -- first of those six would return XN to FREE and the second would be
    -- consuming a region nobody produced.  Lifetime is a property of the
    -- schedule, so the host generator is what knows it, so it belongs in the
    -- descriptor -- and the section 6.1 descriptor format has no field for it.
    -- Recorded as an open item; this port is the shape the fix has to take.
    iss_rel     : in  std_logic_vector(REG_SIZE'length-1 downto 0);
    iss_ok      : out std_logic;
    iss_code    : out std_logic_vector(3 downto 0);

    -- ============================ COMPLETION ============================
    -- The producing unit's `done`.  `cmp_y_exp` is only final at `done` (a BFP
    -- exponent is not known until the amax scan finishes), which is why the
    -- capture instant is here and not at issue.
    cmp_valid   : in  std_logic;
    cmp_y_exp   : in  signed(EXP_W-1 downto 0);

    -- ======================= WRITE-STROBE POLICING ======================
    -- The region fabric offers a write; `wr_gate` says whether it lands.  Both
    -- are combinational: A's y port has no ready (A section 5) and the region
    -- write port must accept one element per cycle unconditionally, so this
    -- cannot introduce a stall.  It can only DROP, and a drop is always
    -- accompanied by `viol`.
    wr_we       : in  std_logic;
    wr_region   : in  unsigned(7 downto 0);
    wr_gate     : out std_logic;

    -- Exponent write.  THE A3 FINDING: this is policed identically to a data
    -- write, because the exponent has the same live window as the data.
    xw_we       : in  std_logic;
    xw_region   : in  unsigned(7 downto 0);
    xw_seg      : in  unsigned(1 downto 0);
    xw_exp      : in  signed(EXP_W-1 downto 0);
    xw_gate     : out std_logic;

    -- ============================ OBSERVATION ===========================
    -- Exponent read port for the consumers (B's six, C's three, A's x_exp).
    exp_rd_region : in  unsigned(7 downto 0);
    exp_rd_seg    : in  unsigned(1 downto 0);
    exp_rd_data   : out signed(EXP_W-1 downto 0);
    exp_rd_valid  : out std_logic;   -- the slot has been captured since reset

    -- OBSERVATION ONLY, 2026-09-21 (two-card pipeline, Task 1): what the lock
    -- just captured.  `cap_valid` pulses for one cycle on the cycle a
    -- producer's exponent is captured; `cap_region` is the LATCHED
    -- destination `jb_dst` and `cap_exp` the captured `cmp_y_exp`.  A top that
    -- publishes a region's final exponent (llama_top's `x_exp_out`, for R_X)
    -- reads these.  Nothing inside the lock reads them back, and every
    -- existing instance leaves them open.
    cap_valid   : out std_logic;
    cap_region  : out unsigned(7 downto 0);
    cap_exp     : out signed(EXP_W-1 downto 0);

    lock_state  : out std_logic_vector(2*REG_SIZE'length-1 downto 0);
    -- `viol` is a LEVEL held until `viol_ack`, and the first offender is
    -- sticky.  See the header.
    viol        : out std_logic;
    viol_ack    : in  std_logic;
    viol_code   : out std_logic_vector(3 downto 0);
    viol_region : out unsigned(7 downto 0)
  );
end entity;

architecture rtl of seq_region_lock is

  constant NREG : natural := REG_SIZE'length;

  -- 00 FREE   : no valid contents; a producer may claim it at offset 0
  -- 01 VALID  : holds data; readable, and a producer may APPEND at fill_ptr
  --             (this is the state D section 5.3 calls FILLING; the rename is
  --             a comment, not an encoding change, and it matters because the
  --             state persists after the producing job ends)
  -- 10 HELD   : a consumer is reading it right now; no write of any kind
  constant L_FREE    : std_logic_vector(1 downto 0) := "00";
  constant L_VALID   : std_logic_vector(1 downto 0) := "01";
  constant L_HELD    : std_logic_vector(1 downto 0) := "10";

  constant ERR_NONE : std_logic_vector(3 downto 0) := x"0";
  constant ERR_LOCK : std_logic_vector(3 downto 0) := x"2";
  constant ERR_DESC : std_logic_vector(3 downto 0) := x"3";

  constant NO_REGION : unsigned(7 downto 0) := x"FF";

  type lock_arr is array (0 to NREG-1) of std_logic_vector(1 downto 0);
  signal lock : lock_arr := (others => L_FREE);

  type fill_arr is array (0 to NREG-1) of unsigned(ADDR_W-1 downto 0);
  signal fill_ptr : fill_arr := (others => (others => '0'));

  type exp_arr is array (0 to NREG*SEGS-1) of signed(EXP_W-1 downto 0);
  signal exp_cap : exp_arr := (others => (others => '0'));
  signal exp_vld : std_logic_vector(NREG*SEGS-1 downto 0) := (others => '0');

  -- The committed step, latched at `iss_commit` and held for the whole job.
  -- Class (a) applies to this unit too: `cmp_valid` arrives thousands of
  -- cycles after the issue, and deciding what to do with it from live input
  -- ports would be reading a value whose producer has long moved on.
  signal jb_prod   : std_logic := '0';
  signal jb_dst    : integer range 0 to NREG := NREG;   -- NREG = none
  signal jb_slot   : integer range 0 to NREG*SEGS := 0;
  signal jb_rows   : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal jb_cons   : std_logic_vector(NREG-1 downto 0) := (others => '0');
  signal jb_rel    : std_logic_vector(NREG-1 downto 0) := (others => '0');
  signal jb_inplace: std_logic := '0';
  signal jb_live   : std_logic := '0';

  signal viol_r    : std_logic := '0';
  signal viol_code_r : std_logic_vector(3 downto 0) := ERR_NONE;
  signal viol_reg_r  : unsigned(7 downto 0) := (others => '0');

  -- ---- combinational issue verdict --------------------------------------
  signal ok_c   : std_logic;
  signal code_c : std_logic_vector(3 downto 0);

  -- Set while a verdict has been asked for and not yet acted on.  The only
  -- consumer is the STRICT assertion below: `iss_req` exists so the interface
  -- states WHEN the combinational verdict is meant to be read, which is what
  -- lets a later pipelined verdict slot in without changing the contract.
  signal req_seen : std_logic := '0';

  function reg_idx(r : unsigned) return integer is
  begin
    return to_integer(r(6 downto 0));
  end function;

begin

  -- ======================================================================
  -- ISSUE VERDICT.  Combinational, all compares in parallel, one level of OR.
  -- It is a pure function of the request and the lock state; committing is a
  -- separate strobe so that the sequencer's S_CHECK can reject without having
  -- already mutated anything.
  -- ======================================================================
  verdict : process(iss_prod, iss_dst, iss_seg, iss_off, iss_n_rows, iss_cons,
                    lock, fill_ptr) is
    variable ok   : std_logic;
    variable code : std_logic_vector(3 downto 0);
    variable d    : integer;
    variable inpl : boolean;
  begin
    ok   := '1';
    code := ERR_NONE;
    inpl := false;

    if iss_prod = '1' and iss_dst /= NO_REGION then
      if iss_dst >= NREG then
        ok := '0'; code := ERR_DESC;
      else
        d    := reg_idx(iss_dst);
        inpl := iss_cons(d) = '1';
        -- A producer may claim a FREE or a FILLING region.  A HELD one is
        -- being read by someone; that is O7 and the write half of O9.  The
        -- in-place case is the documented exception: the step that holds it
        -- is the same step that writes it.
        if lock(d) = L_HELD and not inpl then
          ok := '0'; code := ERR_LOCK;
        end if;
        -- Append-only.  This turns intra-region placement from a convention
        -- into a checked invariant: overlapping sub-writes -- the three wqkv
        -- segments landing on top of each other -- cannot be expressed.  An
        -- in-place update rewrites from zero rather than appending.
        if inpl then
          if iss_off /= 0 then
            ok := '0'; code := ERR_DESC;
          end if;
        elsif iss_off /= fill_ptr(d) then
          ok := '0'; code := ERR_DESC;
        end if;
        -- And it must fit.  One add, one compare.
        if (iss_off + iss_n_rows) > to_unsigned(REG_SIZE(REG_SIZE'low + d), ADDR_W+1)
        then
          ok := '0'; code := ERR_DESC;
        end if;
        if iss_seg >= SEGS then
          ok := '0'; code := ERR_DESC;
        end if;
      end if;
    end if;

    -- Every consumed region must actually hold something.  A FREE region in
    -- the mask means the table is consuming what nobody produced, and reading
    -- it would return whatever the last block left behind -- a plausible wrong
    -- number rather than a fault.
    for i in 0 to NREG-1 loop
      if iss_cons(i) = '1' then
        if lock(i) = L_FREE then
          ok := '0'; code := ERR_LOCK;
        elsif lock(i) = L_HELD then
          -- Two consumers at once.  A, B and C are never simultaneously
          -- active, so this can only be a table bug.
          ok := '0'; code := ERR_LOCK;
        end if;
      end if;
    end loop;

    ok_c   <= ok;
    code_c <= code;
  end process;

  iss_ok   <= ok_c;
  iss_code <= code_c;

  -- ======================================================================
  -- WRITE POLICING.  Combinational and never stalling: it can drop, not delay.
  -- A dropped write is ALWAYS accompanied by `viol`; a silent drop would be
  -- worse than no check at all, because it would look like a correct run with
  -- a wrong number in it.
  -- ======================================================================
  -- SINGLE WRITER, and it is strictly stronger than the spec's rule.
  -- D section 5.3 only says a HELD region rejects writes.  That discharges O7
  -- and the write half of O9, but it does NOT catch the hazard section 8.2 is
  -- about: a unit's `done` does not imply its transactions have retired, so
  -- write strobes can arrive after the job that issued them is over.  If the
  -- region has not been consumed by anyone yet, the spec's rule lets those
  -- late strobes land -- silently, into the region the NEXT producer is about
  -- to append to.  So the gate here is: a write lands only while a producing
  -- job is committed AND it targets that job's own destination.  Everything
  -- else is dropped and reported.  This is the same class `tb_axi_rd_port`
  -- caught, at the seam that test could not see.
  wr_gate <= '1' when wr_we = '1' and jb_live = '1' and jb_prod = '1'
                      and jb_dst < NREG and wr_region < NREG
                      and reg_idx(wr_region) = jb_dst
             else '0';

  -- THE A3 FINDING, in one expression: the exponent slot of a HELD region is
  -- protected exactly like its data.
  xw_gate <= '0' when xw_we = '1'
                      and (xw_region >= NREG or xw_seg >= SEGS
                           or (lock(reg_idx(xw_region)) = L_HELD
                               and not (jb_live = '1' and jb_inplace = '1'
                                        and reg_idx(xw_region) = jb_dst)))
             else xw_we;

  exp_rd_data  <= exp_cap(reg_idx(exp_rd_region)*SEGS + to_integer(exp_rd_seg))
                  when exp_rd_region < NREG and exp_rd_seg < SEGS
                  else (others => '0');
  exp_rd_valid <= exp_vld(reg_idx(exp_rd_region)*SEGS + to_integer(exp_rd_seg))
                  when exp_rd_region < NREG and exp_rd_seg < SEGS
                  else '0';

  gen_lock_out : for i in 0 to NREG-1 generate
    lock_state(2*i+1 downto 2*i) <= lock(i);
  end generate;

  viol        <= viol_r;
  viol_code   <= viol_code_r;
  viol_region <= viol_reg_r;

  -- ======================================================================
  -- STATE.
  -- ======================================================================
  seq : process(clk) is
    variable d : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cap_valid  <= '0';
        cap_region <= (others => '0');
        cap_exp    <= (others => '0');
        lock       <= (others => L_FREE);
        fill_ptr   <= (others => (others => '0'));
        exp_cap    <= (others => (others => '0'));
        exp_vld    <= (others => '0');
        jb_prod    <= '0';
        jb_dst     <= NREG;
        jb_slot    <= 0;
        jb_rows    <= (others => '0');
        jb_cons    <= (others => '0');
        jb_rel     <= (others => '0');
        jb_inplace <= '0';
        jb_live    <= '0';
        viol_r     <= '0';
        viol_code_r<= ERR_NONE;
        viol_reg_r <= (others => '0');
        req_seen   <= '0';
      else
        cap_valid <= '0';

        -- ---- violation capture, UNCONDITIONAL -------------------------
        -- Runs in every cycle regardless of what else this unit is doing, and
        -- holds until acknowledged.  The FIRST offender is kept; later ones
        -- do not overwrite it, because the last symptom is not the cause.
        if viol_ack = '1' then
          viol_r      <= '0';
          viol_code_r <= ERR_NONE;
        end if;
        if (wr_we = '1' and wr_gate = '0') then
          if viol_r = '0' then
            viol_r      <= '1';
            viol_code_r <= ERR_LOCK;
            viol_reg_r  <= wr_region;
          end if;
        elsif (xw_we = '1' and xw_gate = '0') then
          if viol_r = '0' then
            viol_r      <= '1';
            viol_code_r <= ERR_LOCK;
            viol_reg_r  <= xw_region;
          end if;
        end if;

        if iss_req = '1' then
          req_seen <= '1';
        elsif iss_commit = '1' then
          req_seen <= '0';
        end if;

        -- ---- commit: THE ONE INSTANT the locks move -------------------
        if iss_commit = '1' and ok_c = '1' then
          jb_prod    <= iss_prod;
          jb_rows    <= iss_n_rows;
          jb_cons    <= iss_cons;
          jb_rel     <= iss_rel;
          jb_live    <= '1';
          jb_inplace <= '0';
          jb_dst     <= NREG;
          jb_slot    <= 0;

          for i in 0 to NREG-1 loop
            if iss_cons(i) = '1' then
              lock(i) <= L_HELD;
            end if;
          end loop;

          if iss_prod = '1' and iss_dst /= NO_REGION and iss_dst < NREG then
            d      := reg_idx(iss_dst);
            jb_dst <= d;
            jb_slot<= d*SEGS + to_integer(iss_seg);
            if iss_cons(d) = '1' then
              jb_inplace <= '1';           -- stays HELD for the duration
            else
              lock(d) <= L_VALID;
            end if;
          end if;
        end if;

        -- ---- completion ----------------------------------------------
        -- Note what is read here: `jb_*`, the LATCHED job, never the live
        -- `iss_*` ports.  The completion arrives thousands of cycles after the
        -- issue, and by then `iss_*` describes whatever the sequencer is
        -- checking next.
        if cmp_valid = '1' and jb_live = '1' then
          jb_live <= '0';

          -- Producer: advance the fill pointer and CAPTURE the exponent.  The
          -- capture instant is `done` and not earlier, because a BFP y_exp is
          -- only final once the amax scan has run; and not later, because a
          -- live read at use time returns whatever job ran last.  That is the
          -- B section 2.1.2 "captured, not re-read" rule, at D's seam.
          if jb_prod = '1' and jb_dst < NREG then
            if jb_inplace = '1' then
              fill_ptr(jb_dst) <= jb_rows;
              lock(jb_dst)     <= L_VALID;
            else
              fill_ptr(jb_dst) <= fill_ptr(jb_dst) + jb_rows;
            end if;
            exp_cap(jb_slot) <= cmp_y_exp;
            exp_vld(jb_slot) <= '1';
            cap_valid  <= '1';
            cap_region <= to_unsigned(jb_dst, 8);
            cap_exp    <= cmp_y_exp;
          end if;

          -- Consumer: every region it held goes back to VALID -- its contents
          -- are still there and the next step may read them -- UNLESS this
          -- step was flagged as the last reader, in which case it goes FREE
          -- and its fill pointer resets so the next producer starts at 0.
          -- The in-place region is excepted: the producer arm above has
          -- already given it its new fill_ptr and returned it to VALID.
          for i in 0 to NREG-1 loop
            if jb_cons(i) = '1'
               and not (jb_inplace = '1' and i = jb_dst) then
              if jb_rel(i) = '1' then
                lock(i)     <= L_FREE;
                fill_ptr(i) <= (others => '0');
              else
                lock(i) <= L_VALID;
              end if;
            end if;
          end loop;
        end if;

      end if;
    end if;
  end process;

  -- ======================================================================
  -- Simulation-only assertions.  A generic and not unconditional, because the
  -- testbench drives illegal sequences on purpose to check they are caught.
  -- ======================================================================
  strict_chk : process(clk) is
  begin
    if rising_edge(clk) and rst = '0' and STRICT then
      assert not (cmp_valid = '1' and jb_live = '0')
        report "seq_region_lock: a completion arrived with no committed job.  "
             & "Either the sequencer completed a step it never committed, or "
             & "one completion was counted twice."
        severity warning;
      assert not (iss_commit = '1' and ok_c = '0')
        report "seq_region_lock: the sequencer committed a step this unit had "
             & "already rejected.  The check must gate the commit, not follow "
             & "it."
        severity warning;
      assert not (iss_commit = '1' and req_seen = '0')
        report "seq_region_lock: a step was committed without the verdict "
             & "ever having been asked for.  `iss_req` marks the cycle the "
             & "verdict is meant to be read; committing without it means the "
             & "check and the commit are looking at different descriptors."
        severity warning;
      assert not (iss_commit = '1' and jb_live = '1')
        report "seq_region_lock: a second step was committed while the first "
             & "was still outstanding.  Only one job runs at a time in D."
        severity warning;
    end if;
  end process;

end architecture;
