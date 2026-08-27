-- rtl/seq_desc_fetch.vhd
-- Subsystem D: the descriptor fetch / decode / issue engine.  REAL RTL.
--
-- WHAT THIS IS.  D's schedule is DATA, not gateware: a table of 64-byte
-- descriptors in URAM that the host generates per model, per rank and per
-- topology (D spec section 4.4 -- this is what makes NCARDS=1 Qwen3.5-9B a
-- configuration rather than a variant).  This unit is the thing that walks
-- that table: it fetches a descriptor, decodes it, runs the descriptor-class
-- checks BEFORE any unit starts, issues the job, and waits for completion.
-- Every other part of D hangs off it, which is why it was built first.
--
-- It is deliberately NOT the whole of D-ctrl.  Absent, on purpose: the region
-- address generation, the AXI grant mux and its outstanding counters, D-vec,
-- the base array (`nsub_w + nsub_s` 64-bit bases past the header), and the
-- codebook load.  Those are named in the report as remaining work rather than
-- stubbed here, because a stub in an entity that claims to be real is exactly
-- the thing the surrounding specs keep having to withdraw.
--
-- ======================================================================
-- THE TWO DEFECT CLASSES THIS UNIT IS SHAPED BY
-- ======================================================================
--
-- Class (a), a value read for the DURATION of a long operation while its
-- source moves on underneath.  `docs/debugging/2026-08-27_gdn-emit-chain-
-- w-latch.md`: `w_mant` was an unlatched port read once per head for 24 heads
-- while blocks overlapped, so head 23 of every block normalised with the NEXT
-- block's weights.  23 of 24 heads correct reads as a numeric artefact, not as
-- a wiring fault.  D reproduces this at 1,106 steps per token the moment
-- descriptor PREFETCH exists, because prefetch is by definition the next job's
-- data arriving while the current job runs.
--
--   Mechanism here: a TWO-BANK descriptor shadow.  The fetch FSM writes bank
--   `1 - live_bank` and cannot touch the live one; the banks swap at exactly
--   one instant, the transition into S_ISSUE.  Every `job_*` output is a
--   combinational decode of the LIVE bank only, and the URAM read port never
--   reaches a `job_*` output by any path.
--
--   Detector, not just a fix: a `job_epoch` counter, incremented at that same
--   single instant and presented with the shadow.  A unit latches the epoch
--   with whatever else it latches and echoes it back at `done`; a mismatch
--   raises ERR_EPOCH with the failing step index.  The w-latch document's own
--   conclusion is that the safe window existed and was simply not OBSERVABLE
--   from outside; the epoch is what makes it observable.  Cost is EPOCH_W FF
--   here, EPOCH_W per unit, one comparator.
--
-- Class (b), a completion signalled as a one-cycle pulse and discarded because
-- the consumer was busy.  `docs/debugging/2026-08-27_gdn-head-emit-done-
-- pulse.md`: an entire head was thrown away per missed pulse, and the LOSSY
-- path scored better on the back-pressure metric than the fixed one did.
--
--   D is a multi-hundred-step machine with descriptor checks, error handling
--   and a watchdog.  It is provably not always listening.  The D design spec's
--   section 1 inherits "the one-cycle start/done pulse convention" from
--   `engine_shared`; that sentence is WITHDRAWN and this unit does not
--   implement it.  Instead:
--
--     - every `u_done` is captured into a STICKY per-unit bit in an
--       UNCONDITIONAL process branch that runs in every state in every cycle,
--       and that sticky bit is the SOLE sampler.  No raw `u_done` is read
--       inside a state test anywhere below.  A unit that pulses `done` for one
--       cycle in the middle of S_CHECK is still seen.
--     - `u_err` and the echoed epoch are latched at the FIRST cycle `done` is
--       observed and frozen there, so a unit that drops `err` after `done` (or
--       changes its epoch) cannot erase what it reported.
--     - `u_start` is HELD until the unit's `ready` accepts it, never pulsed
--       into a unit that is not listening.
--     - `u_ack` closes the loop for units that hold `done` as a level.
--     - `tok_done` out to the host is a LEVEL held until `tok_ack`, because D
--       producing a pulse is the same defect facing the other way.
--
--   And the counting rule, which is what actually named the head-emit cause:
--   `steps_done` must equal the table length at `tok_done`.  A throughput
--   metric would not have found it; an accounting identity did.
--
-- ======================================================================
-- WHY A UNIT MUST NOT STILL BE ASSERTING `done` WHEN IT IS RE-STARTED
-- ======================================================================
-- A held-until-ack `done` creates a hazard a pulsed one does not: if the unit
-- has not dropped `done` by the time D issues its NEXT job, the sticky capture
-- fires immediately and D believes a job that has not started has finished.
-- S_ISSUE therefore refuses to accept `ready` while the selected unit's raw
-- `done` is still high, and the watchdog covers a unit that never drops it
-- (ERR_WDOG).  With STRICT_PROTO the wait is reported, because a unit that
-- routinely needs it has a slow ack path that will bite at a different clock.
--
-- ======================================================================
-- DESCRIPTOR FORMAT -- D design spec section 6.1, byte-pinned, little-endian
-- ======================================================================
-- 64-byte header = 8 x 64-bit URAM words.  Pad bytes are 0x00 and this unit
-- CHECKS that, because the format's stated discipline is that two conforming
-- generators produce byte-identical tables; a nonzero pad means the generator
-- and the gateware disagree about the layout, and that is a class of bug that
-- otherwise surfaces as a plausible wrong number.
--
--   word 0 : [7:0] opcode  [15:8] flags  [23:16] src_region
--            [31:24] dst_region  [63:32] dst_offset
--   word 1 : [31:0] n_rows  [63:32] n_cols
--   word 2 : [31:0] w_exp (i32)  [63:32] out_shift (i32)
--   word 3 : [7:0] out_mode  [15:8] ordinal  [31:16] nsub_w
--            [47:32] nsub_s  [55:48] src_region2  [63:56] PAD, must be 0
--   word 4 : [31:0] const_base  [63:32] const_exp (i32)
--   word 5 : codebook bytes 0..7   (valid iff flags bit 2, cb_load)
--   word 6 : codebook bytes 8..15
--   word 7 : PAD, must be 0
--
-- opcode: 0 A_JOB, 1 B_JOB, 2 C_JOB, 3 E_COLL, 4 VEC_NORM, 5 VEC_RESIDUAL,
--         6 VEC_SWIGLU, 7 END_TOKEN.
-- flags:  bit 0 route y to E (partial), bit 1 route y to sampler (raw),
--         bit 2 cb_load, bit 3 an E step follows this job (NCARDS > 1).
-- A region byte of 0xFF means "no region", and is legal on `dst` only when a
-- route flag says where the output went instead.
--
-- The base array (`nsub_w + nsub_s` 64-bit words at offset 0x40) is NOT
-- fetched here.  Its length is open with A section 14.5 and the count is only
-- RANGE-CHECKED against NSUB_MAX at the moment.  Fetching it is remaining work.
--
-- ======================================================================
-- WHAT THIS UNIT DOES NOT DECIDE
-- ======================================================================
-- The region bound check (`dst_offset = fill_ptr`, `dst_offset + n_rows`
-- inside the region, lock state legal) needs the region sizes and the live
-- lock states, which belong to `seq_region_lock`.  It is asked over `chk_req`
-- / `chk_bad` / `chk_code` during S_CHECK, one clocked state before any unit
-- is started, so a bad table aborts before it produces output.  That ordering
-- is the A section 7.6 discipline and it is why S_CHECK is a state of its own
-- rather than a term in S_ISSUE.
--
-- 0 DSP by construction: the descriptor address is `step * 8` for a 64-bit
-- word port, i.e. a shift; there is no multiply anywhere in this file.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_desc_fetch is
  generic(
    -- Activation regions.  14 at 27B (X XN QKV Z BETA ALPHA QG KIN VIN Y G U
    -- H ER); the count is a generic because the region map has a documented
    -- packed fallback at 6 large regions.
    NREG       : positive := 14;
    -- Job epoch width.  Only has to exceed the number of jobs in flight, which
    -- is one (A, B and C are never simultaneously active).  4 bits gives 16
    -- jobs of separation, so a stale echo is unambiguous rather than aliased.
    EPOCH_W    : positive := 4;
    -- A, B, C, E, D-vec.
    NUNIT      : positive := 5;
    -- Bound on the per-job weight/scale base count, pending A section 14.5.
    NSUB_MAX   : positive := 64;
    -- Step index width.  1,106 steps/token at 27B, 546 at 9B; 11 bits covers
    -- both with the table length itself supplied at run time.
    STEP_W     : positive := 11;
    -- Cycles a single job may take before ERR_WDOG.  It also covers a unit
    -- that never drops `done` and a `ready` that never arrives, so it is a
    -- liveness bound on the whole handshake, not only on the computation.
    WDOG_LIMIT : positive := 4096;
    -- Simulation-only protocol assertions.  Same role as gdn_emit_chain's
    -- STRICT_PRODUCER: the testbench drives harder than the real system on
    -- purpose, so these must be switchable rather than unconditional.  They
    -- synthesise to nothing.
    STRICT_PROTO : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ======================= HOST / CONTROL ==========================
    -- `go` is a level or a pulse; it is only read in S_IDLE.
    go        : in  std_logic;
    -- Table length for this token, in descriptors, INCLUDING the END_TOKEN
    -- descriptor.  Latched at `go`.  Checked against the walk: reaching it
    -- without an END_TOKEN opcode is ERR_DESC, and an END_TOKEN before it is
    -- also ERR_DESC.  This is the counting identity, in hardware.
    tbl_len   : in  unsigned(STEP_W-1 downto 0);
    abort     : in  std_logic;
    busy      : out std_logic;
    -- LEVEL, held until `tok_ack`.  Not a pulse: see the header.
    tok_done  : out std_logic;
    tok_ack   : in  std_logic;
    err       : out std_logic;                       -- sticky
    err_code  : out std_logic_vector(3 downto 0);
    err_step  : out unsigned(STEP_W-1 downto 0);
    -- Descriptors fully processed this token, END_TOKEN included.  Must equal
    -- `tbl_len` at a clean `tok_done`; the unit checks it itself.
    steps_done: out unsigned(STEP_W-1 downto 0);

    -- ==================== DESCRIPTOR MEMORY (URAM) ====================
    -- Registered read of arbitrary latency.  `d_ren` is asserted with
    -- `d_raddr`; `d_rvalid` marks the cycle `d_rdata` holds that word.  D is
    -- the only master, so there is no arbitration and no ready.
    d_raddr   : out unsigned(15 downto 0);
    d_ren     : out std_logic;
    d_rdata   : in  std_logic_vector(63 downto 0);
    d_rvalid  : in  std_logic;

    -- ============= JOB SHADOW, LIVE BANK ONLY, BROADCAST ==============
    -- Every one of these is a decode of the live bank, and the live bank
    -- changes at exactly one instant.  None is a live counter or a function
    -- of the URAM read port.  This is the class (a) rule.
    job_valid     : out std_logic;   -- a job is live, shadow is stable
    job_issue     : out std_logic;   -- 1-cycle: the shadow just became live
    job_cmp       : out std_logic;   -- 1-cycle: the live job completed cleanly
    job_epoch     : out unsigned(EPOCH_W-1 downto 0);
    job_unit      : out unsigned(2 downto 0);
    job_opcode    : out unsigned(3 downto 0);
    job_flags     : out std_logic_vector(7 downto 0);
    job_src       : out unsigned(7 downto 0);
    job_src2      : out unsigned(7 downto 0);
    job_dst       : out unsigned(7 downto 0);
    job_dst_off   : out unsigned(31 downto 0);
    job_n_rows    : out unsigned(31 downto 0);
    job_n_cols    : out unsigned(31 downto 0);
    job_w_exp     : out signed(31 downto 0);
    job_out_shift : out signed(31 downto 0);
    job_out_mode  : out std_logic_vector(7 downto 0);
    job_ordinal   : out unsigned(7 downto 0);
    job_const_base: out unsigned(31 downto 0);
    job_const_exp : out signed(31 downto 0);
    job_step      : out unsigned(STEP_W-1 downto 0);

    -- ============ EXTERNAL DESCRIPTOR CHECK (region locks) ============
    -- Asked one clocked state before any unit starts.  `chk_*` are read only
    -- while `chk_req` is high, and they describe the PREFETCH bank, which is
    -- what `chk_*_pf` below presents.
    chk_req    : out std_logic;
    chk_bad    : in  std_logic;
    chk_code   : in  std_logic_vector(3 downto 0);
    -- The candidate descriptor, for the checker.  Separate from `job_*` on
    -- purpose: `job_*` is the live bank and must never show the candidate.
    chk_opcode : out unsigned(3 downto 0);
    chk_src    : out unsigned(7 downto 0);
    chk_dst    : out unsigned(7 downto 0);
    chk_dst_off: out unsigned(31 downto 0);
    chk_n_rows : out unsigned(31 downto 0);

    -- ========================= UNIT HANDSHAKE =========================
    -- One bus, demuxed outside by `job_unit`.  `u_done` MUST be a level held
    -- until `u_ack`; a unit that cannot be changed is still covered, because
    -- the sticky capture below is the sole sampler.
    u_start      : out std_logic_vector(NUNIT-1 downto 0);
    u_ready      : in  std_logic_vector(NUNIT-1 downto 0);
    u_done       : in  std_logic_vector(NUNIT-1 downto 0);
    u_ack        : out std_logic_vector(NUNIT-1 downto 0);
    u_err        : in  std_logic_vector(NUNIT-1 downto 0);
    -- Echoed job epoch, one EPOCH_W field per unit, unit u at
    -- (u+1)*EPOCH_W-1 downto u*EPOCH_W.  Sampled at the first cycle `done` is
    -- observed and frozen there.
    u_done_epoch : in  std_logic_vector(NUNIT*EPOCH_W-1 downto 0)
  );
end entity;

architecture rtl of seq_desc_fetch is

  -- ---- opcodes ----------------------------------------------------------
  constant OP_A_JOB    : integer := 0;
  constant OP_B_JOB    : integer := 1;
  constant OP_C_JOB    : integer := 2;
  constant OP_E_COLL   : integer := 3;
  constant OP_VEC_NORM : integer := 4;
  constant OP_VEC_RES  : integer := 5;
  constant OP_VEC_SWG  : integer := 6;
  constant OP_END_TOKEN: integer := 7;

  -- ---- error codes (D design spec section 10, plus ERR_EPOCH) -----------
  constant ERR_NONE  : std_logic_vector(3 downto 0) := x"0";
  constant ERR_UNIT  : std_logic_vector(3 downto 0) := x"1";
  constant ERR_LOCK  : std_logic_vector(3 downto 0) := x"2";
  constant ERR_DESC  : std_logic_vector(3 downto 0) := x"3";
  constant ERR_WDOG  : std_logic_vector(3 downto 0) := x"4";
  constant ERR_GRANT : std_logic_vector(3 downto 0) := x"5";
  constant ERR_CTX   : std_logic_vector(3 downto 0) := x"6";
  constant ERR_EPOCH : std_logic_vector(3 downto 0) := x"7";
  constant ERR_ABORT : std_logic_vector(3 downto 0) := x"8";

  constant NO_REGION : unsigned(7 downto 0) := x"FF";

  -- ---- the two-bank descriptor shadow ----------------------------------
  -- Raw 64-bit words, not decoded registers: the decode is combinational off
  -- the live bank, so there is exactly one copy of every field and no way for
  -- a decoded register to drift from the words it came from.  The banks are
  -- written by the FETCH process only and read by everything else.
  type word_arr is array (0 to 7) of std_logic_vector(63 downto 0);
  type bank_arr is array (0 to 1) of word_arr;
  signal dw : bank_arr := (others => (others => (others => '0')));

  signal live_bank : integer range 0 to 1 := 0;

  -- ---- fetch side ------------------------------------------------------
  type fstate_t is (F_IDLE, F_REQ, F_WAIT);
  signal fstate    : fstate_t := F_IDLE;
  signal f_bank    : integer range 0 to 1 := 1;
  signal f_beat    : integer range 0 to 7 := 0;
  signal fetch_idx : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal fetch_en  : std_logic := '0';
  signal pf_ready  : std_logic := '0';               -- prefetch bank holds a descriptor
  signal pf_step   : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal pf_take   : std_logic := '0';               -- job FSM consumed it

  -- ---- job side --------------------------------------------------------
  type state_t is (
    S_IDLE,      -- waiting for `go`
    S_WAITPF,    -- waiting for the prefetch bank to hold a descriptor
    S_CHECK,     -- descriptor-class checks, BEFORE any unit starts
    S_ISSUE,     -- THE ONE INSTANT: bank swap, epoch bump, hold start
    S_WAIT,      -- wait on the STICKY done_seen, never on a raw done
    S_COMPLETE,  -- ack, epoch compare, unit-err check
    S_ABORT,     -- drain the in-flight unit, then report
    S_TOKDONE    -- tok_done level, held until tok_ack
  );
  signal state : state_t := S_IDLE;

  signal step_idx   : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal live_step  : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal steps_r    : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal tbl_len_r  : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal epoch_r    : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal cur_unit   : integer range 0 to NUNIT-1 := 0;
  signal busy_r     : std_logic := '0';
  signal tok_r      : std_logic := '0';
  signal err_r      : std_logic := '0';
  signal err_code_r : std_logic_vector(3 downto 0) := ERR_NONE;
  signal err_step_r : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal wdog       : unsigned(31 downto 0) := (others => '0');
  signal issue_r    : std_logic := '0';
  signal cmp_r      : std_logic := '0';
  signal jvalid_r   : std_logic := '0';

  -- ---- sticky completion capture (defect class (b)) ---------------------
  signal armed      : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal done_seen  : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal err_seen   : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  type epoch_arr is array (0 to NUNIT-1) of unsigned(EPOCH_W-1 downto 0);
  signal epoch_seen : epoch_arr := (others => (others => '0'));
  signal start_acc  : std_logic := '0';   -- start accepted this cycle

  -- ---- sticky host abort ------------------------------------------------
  -- The host's `abort` is a register bit, but D only LOOKS at it in two
  -- states.  Reading a host strobe in a state-conditional branch is defect
  -- class (b) with the host as the producer, so it is captured unconditionally
  -- here and cleared only by the `go` that starts the next token.  This was
  -- found by writing the testbench: a one-cycle abort pulse was silently
  -- ignored whenever it landed outside S_WAITPF or S_COMPLETE.
  signal abort_r : std_logic := '0';

  -- Per unit: its completion has been acknowledged but it is still driving
  -- `done`.  Legal -- a double-buffered unit may take a few cycles to release
  -- -- and it is the one case the "done with no job outstanding" assertion
  -- must not flag, or the assertion cries wolf on correct behaviour.
  signal post_ack : std_logic_vector(NUNIT-1 downto 0) := (others => '0');

  -- ---- combinational decode helpers ------------------------------------
  -- Pure functions of one bank's words.  Used for the live bank (the `job_*`
  -- outputs) and for the prefetch bank (the check state) with no shared
  -- register, which is what keeps the candidate off the live outputs.
  -- NOTE ON REINDEXING.  A VHDL slice keeps the parent's index range, so
  -- `w(0)(15 downto 8)` is a vector indexed 15..8 and `(0)` on it is a bounds
  -- error, not bit zero.  Every accessor below therefore assigns through a
  -- declared 0-based variable.  GHDL catches this at run time; synthesis would
  -- have caught it too, but only after the sim had already been believed.
  function f_opcode (w : word_arr) return unsigned is
    variable r : unsigned(3 downto 0);
  begin r := unsigned(w(0)(3 downto 0)); return r; end function;
  function f_opcode8(w : word_arr) return unsigned is
    variable r : unsigned(7 downto 0);
  begin r := unsigned(w(0)(7 downto 0)); return r; end function;
  function f_flags  (w : word_arr) return std_logic_vector is
    variable r : std_logic_vector(7 downto 0);
  begin r := w(0)(15 downto 8); return r; end function;
  function f_src    (w : word_arr) return unsigned is
    variable r : unsigned(7 downto 0);
  begin r := unsigned(w(0)(23 downto 16)); return r; end function;
  function f_dst    (w : word_arr) return unsigned is
    variable r : unsigned(7 downto 0);
  begin r := unsigned(w(0)(31 downto 24)); return r; end function;
  function f_dstoff (w : word_arr) return unsigned is
    variable r : unsigned(31 downto 0);
  begin r := unsigned(w(0)(63 downto 32)); return r; end function;
  function f_nrows  (w : word_arr) return unsigned is
    variable r : unsigned(31 downto 0);
  begin r := unsigned(w(1)(31 downto 0)); return r; end function;
  function f_ncols  (w : word_arr) return unsigned is
    variable r : unsigned(31 downto 0);
  begin r := unsigned(w(1)(63 downto 32)); return r; end function;
  function f_wexp   (w : word_arr) return signed is
    variable r : signed(31 downto 0);
  begin r := signed(w(2)(31 downto 0)); return r; end function;
  function f_oshift (w : word_arr) return signed is
    variable r : signed(31 downto 0);
  begin r := signed(w(2)(63 downto 32)); return r; end function;
  function f_omode  (w : word_arr) return std_logic_vector is
    variable r : std_logic_vector(7 downto 0);
  begin r := w(3)(7 downto 0); return r; end function;
  function f_ord    (w : word_arr) return unsigned is
    variable r : unsigned(7 downto 0);
  begin r := unsigned(w(3)(15 downto 8)); return r; end function;
  function f_nsubw  (w : word_arr) return unsigned is
    variable r : unsigned(15 downto 0);
  begin r := unsigned(w(3)(31 downto 16)); return r; end function;
  function f_nsubs  (w : word_arr) return unsigned is
    variable r : unsigned(15 downto 0);
  begin r := unsigned(w(3)(47 downto 32)); return r; end function;
  function f_src2   (w : word_arr) return unsigned is
    variable r : unsigned(7 downto 0);
  begin r := unsigned(w(3)(55 downto 48)); return r; end function;
  function f_pad3   (w : word_arr) return std_logic_vector is
    variable r : std_logic_vector(7 downto 0);
  begin r := w(3)(63 downto 56); return r; end function;
  function f_cbase  (w : word_arr) return unsigned is
    variable r : unsigned(31 downto 0);
  begin r := unsigned(w(4)(31 downto 0)); return r; end function;
  function f_cexp   (w : word_arr) return signed is
    variable r : signed(31 downto 0);
  begin r := signed(w(4)(63 downto 32)); return r; end function;

  -- Opcode -> unit.  END_TOKEN has no unit and never reaches S_ISSUE.
  function unit_of(op : unsigned) return integer is
  begin
    case to_integer(op(3 downto 0)) is
      when OP_A_JOB     => return 0;
      when OP_B_JOB     => return 1;
      when OP_C_JOB     => return 2;
      when OP_E_COLL    => return 3;
      when OP_VEC_NORM  => return 4;
      when OP_VEC_RES   => return 4;
      when OP_VEC_SWG   => return 4;
      when others       => return 0;
    end case;
  end function;

  -- The prefetch bank index.  Written as a function of live_bank so there is
  -- one statement of the invariant "the fetch side never touches the live
  -- bank" rather than two places that must agree.
  function other(b : integer) return integer is
  begin
    if b = 0 then return 1; else return 0; end if;
  end function;

  -- Initialised, not left to the first delta.  These are concurrent aliases of
  -- a bank; without an initial value the combinational check process runs once
  -- at time zero against 'U' and emits a page of numeric_std metavalue
  -- warnings.  Harmless in itself, but noise at time zero is exactly what
  -- makes a real warning later easy to scroll past.
  signal pf_w : word_arr := (others => (others => '0'));
  signal lv_w : word_arr := (others => (others => '0'));

  -- Descriptor-class verdict on the PREFETCH bank, combinational.  Split out
  -- of the FSM so S_CHECK is one clocked decision and the reason for each
  -- rejection stays readable.
  signal desc_bad  : std_logic;
  signal desc_why  : std_logic_vector(3 downto 0);

begin

  pf_w <= dw(other(live_bank));
  lv_w <= dw(live_bank);

  -- ======================================================================
  -- Descriptor-class checks.  All are on the CANDIDATE (prefetch) bank and
  -- all are pure compares of narrow fields, in parallel, so the whole verdict
  -- is one level of OR after one level of compare.  Nothing here is in series
  -- with the region bound check, which is the external `chk_bad`.
  -- ======================================================================
  desc_chk : process(pf_w, pf_step, tbl_len_r) is
    variable op    : integer;
    variable bad   : std_logic;
    variable why   : std_logic_vector(3 downto 0);
    variable isjob : boolean;
  begin
    op    := to_integer(f_opcode8(pf_w));
    isjob := (op <= OP_VEC_SWG);
    bad   := '0';
    why   := ERR_NONE;

    -- Unknown opcode.  The field is a full byte so anything above 7 is a
    -- generator/gateware mismatch, not a new instruction.
    if op > OP_END_TOKEN then
      bad := '1'; why := ERR_DESC;
    end if;

    -- Pad bytes must be zero.  The format's own discipline is that two
    -- conforming generators produce byte-identical tables; a nonzero pad means
    -- one of them is writing a field this decode does not know about.
    if f_pad3(pf_w) /= x"00" or pf_w(7) /= x"0000000000000000" then
      bad := '1'; why := ERR_DESC;
    end if;

    if isjob then
      -- A job that produces nothing is a table bug, not a no-op.
      if f_nrows(pf_w) = 0 then
        bad := '1'; why := ERR_DESC;
      end if;
      -- dst = 0xFF is legal only when a route flag says where the output went
      -- (bit 0 to E in partial mode, bit 1 to the sampler in raw mode).  This
      -- is what makes "a descriptor cannot simultaneously claim a region and
      -- E" a checked property rather than a convention.
      if f_dst(pf_w) = NO_REGION then
        if f_flags(pf_w)(0) = '0' and f_flags(pf_w)(1) = '0' then
          bad := '1'; why := ERR_DESC;
        end if;
      else
        if f_dst(pf_w) >= NREG then
          bad := '1'; why := ERR_DESC;
        end if;
        -- And the converse: a named destination with a route flag set would
        -- claim a region AND an external sink at once.
        if f_flags(pf_w)(0) = '1' or f_flags(pf_w)(1) = '1' then
          bad := '1'; why := ERR_DESC;
        end if;
      end if;
      -- Source region.  0xFF means "reads no region" and is legal for E_COLL.
      if f_src(pf_w) /= NO_REGION and f_src(pf_w) >= NREG then
        bad := '1'; why := ERR_DESC;
      end if;
      if f_src2(pf_w) /= NO_REGION and f_src2(pf_w) >= NREG then
        bad := '1'; why := ERR_DESC;
      end if;
      -- Base-array length, pending A section 14.5.
      if f_nsubw(pf_w) > NSUB_MAX or f_nsubs(pf_w) > NSUB_MAX then
        bad := '1'; why := ERR_DESC;
      end if;
    end if;

    -- The counting identity, enforced in hardware rather than only asserted in
    -- the testbench: END_TOKEN must be the LAST descriptor and the last
    -- descriptor must be END_TOKEN.  A table that ends early computes a
    -- partial token and reports success; a table that runs long walks into
    -- whatever follows it in URAM.
    if op = OP_END_TOKEN then
      if pf_step /= tbl_len_r - 1 then
        bad := '1'; why := ERR_DESC;
      end if;
    else
      if pf_step >= tbl_len_r - 1 then
        bad := '1'; why := ERR_DESC;
      end if;
    end if;

    desc_bad <= bad;
    desc_why <= why;
  end process;

  -- ======================================================================
  -- FETCH.  Runs CONCURRENTLY with the job FSM: that is the whole point, and
  -- it is also precisely what makes class (a) reachable here.  It writes bank
  -- `other(live_bank)` and never the live bank, and it may not start the next
  -- descriptor until the job FSM has taken the current one (`pf_take`).
  -- ======================================================================
  fetch : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        fstate    <= F_IDLE;
        f_beat    <= 0;
        f_bank    <= 1;
        fetch_idx <= (others => '0');
        pf_ready  <= '0';
        pf_step   <= (others => '0');
        dw        <= (others => (others => (others => '0')));
        d_ren     <= '0';
        d_raddr   <= (others => '0');
      else
        d_ren <= '0';

        case fstate is

          when F_IDLE =>
            if fetch_en = '1' and pf_ready = '0' then
              -- Latched here, one cycle after any possible bank swap, so the
              -- fetch side reads `live_bank` at a defined instant too.
              f_bank <= other(live_bank);
              f_beat <= 0;
              fstate <= F_REQ;
            end if;

          when F_REQ =>
            -- word address = step * 8 + beat.  A shift and an OR: the reason
            -- D-ctrl is 0 DSP starts here.
            d_raddr <= resize(fetch_idx & "000", 16) + to_unsigned(f_beat, 16);
            d_ren   <= '1';
            fstate  <= F_WAIT;

          when F_WAIT =>
            if d_rvalid = '1' then
              dw(f_bank)(f_beat) <= d_rdata;
              if f_beat = 7 then
                pf_ready <= '1';
                pf_step  <= fetch_idx;
                fstate   <= F_IDLE;
              else
                f_beat <= f_beat + 1;
                fstate <= F_REQ;
              end if;
            end if;

        end case;

        -- Consumption by the job FSM.  Placed AFTER the set above so that if a
        -- take and a completion ever landed on one edge the take would win --
        -- they cannot, because a take requires pf_ready already high, but the
        -- ordering is stated rather than left to be re-derived.
        if pf_take = '1' then
          pf_ready  <= '0';
          fetch_idx <= fetch_idx + 1;
        end if;

        if fetch_en = '0' then
          fetch_idx <= (others => '0');
          pf_ready  <= '0';
          fstate    <= F_IDLE;
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- STICKY completion capture.  UNCONDITIONAL: this branch runs in every
  -- state in every cycle.  It is the entire defence against defect class (b)
  -- and it must never be moved inside a state test.
  --
  -- `armed` exists because a held-until-ack `done` from the PREVIOUS job would
  -- otherwise be captured as this job's completion.  It is set at the instant
  -- start is accepted -- including that same cycle, via `start_acc`, so a
  -- zero-latency unit is not a special case.
  --
  -- `err` and the echoed epoch are frozen at the FIRST cycle `done` is
  -- observed (`done_seen = '0'` guard).  Re-latching them while `done` stays
  -- high would let a unit that drops `err` after asserting it erase its own
  -- report, which is the same "the value moved while someone was reading it"
  -- shape as class (a), one signal over.
  -- ======================================================================
  capture : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        done_seen  <= (others => '0');
        err_seen   <= (others => '0');
        armed      <= (others => '0');
        post_ack   <= (others => '0');
        epoch_seen <= (others => (others => '0'));
      else
        for u in 0 to NUNIT-1 loop
          if (armed(u) = '1' or (start_acc = '1' and cur_unit = u))
             and u_done(u) = '1' and done_seen(u) = '0' then
            done_seen(u)  <= '1';
            err_seen(u)   <= u_err(u);
            epoch_seen(u) <= unsigned(u_done_epoch((u+1)*EPOCH_W-1 downto u*EPOCH_W));
          end if;
        end loop;

        if start_acc = '1' then
          armed(cur_unit) <= '1';
        end if;

        for u in 0 to NUNIT-1 loop
          if state = S_COMPLETE and cur_unit = u then
            post_ack(u) <= '1';
          elsif u_done(u) = '0' then
            post_ack(u) <= '0';
          end if;
        end loop;

        -- Cleared for exactly one unit, at its own completion.  A blanket
        -- clear would drop a completion belonging to a different unit, which
        -- matters as soon as anything overlaps.
        if state = S_COMPLETE then
          done_seen(cur_unit) <= '0';
          err_seen(cur_unit)  <= '0';
          armed(cur_unit)     <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- JOB FSM.
  -- ======================================================================
  fsm : process(clk) is
    variable op : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state      <= S_IDLE;
        abort_r    <= '0';
        step_idx   <= (others => '0');
        live_step  <= (others => '0');
        steps_r    <= (others => '0');
        tbl_len_r  <= (others => '0');
        epoch_r    <= (others => '0');
        live_bank  <= 0;
        cur_unit   <= 0;
        busy_r     <= '0';
        tok_r      <= '0';
        err_r      <= '0';
        err_code_r <= ERR_NONE;
        err_step_r <= (others => '0');
        wdog       <= (others => '0');
        fetch_en   <= '0';
        pf_take    <= '0';
        issue_r    <= '0';
        cmp_r      <= '0';
        jvalid_r   <= '0';
        start_acc  <= '0';
      else
        pf_take   <= '0';
        issue_r   <= '0';
        cmp_r     <= '0';
        start_acc <= '0';

        -- Unconditional: runs in every state in every cycle.
        if abort = '1' then
          abort_r <= '1';
        end if;

        -- One watchdog covering the whole handshake: waiting for `ready`,
        -- waiting for a unit to drop a stale `done`, and waiting for the
        -- completion itself.  A lost completion should now be impossible, so
        -- if this fires it means a genuine hang and not a missed pulse --
        -- keeping both mechanisms is deliberate.
        if state = S_WAIT or state = S_ISSUE or state = S_ABORT then
          wdog <= wdog + 1;
        else
          wdog <= (others => '0');
        end if;

        case state is

          when S_IDLE =>
            if tok_ack = '1' then
              tok_r <= '0';
            end if;
            if go = '1' and tok_r = '0' then
              abort_r    <= '0';
              -- `err` is sticky and cleared by the next successful `go`, the
              -- A section 7.6 convention.
              err_r      <= '0';
              err_code_r <= ERR_NONE;
              busy_r     <= '1';
              step_idx   <= (others => '0');
              steps_r    <= (others => '0');
              tbl_len_r  <= tbl_len;
              fetch_en   <= '1';
              state      <= S_WAITPF;
            end if;

          when S_WAITPF =>
            if abort_r = '1' then
              err_r      <= '1';
              err_code_r <= ERR_ABORT;
              err_step_r <= step_idx;
              state      <= S_TOKDONE;
            elsif pf_ready = '1' then
              state <= S_CHECK;
            end if;

          when S_CHECK =>
            -- Checks run BEFORE any unit starts, so a bad table aborts before
            -- it produces output.  `desc_bad` is this unit's own field checks;
            -- `chk_bad` is the region/lock verdict from outside.
            op := to_integer(f_opcode8(pf_w));
            if desc_bad = '1' then
              err_r      <= '1';
              err_code_r <= desc_why;
              err_step_r <= pf_step;
              state      <= S_TOKDONE;
            elsif chk_bad = '1' then
              err_r      <= '1';
              err_code_r <= chk_code;
              err_step_r <= pf_step;
              state      <= S_TOKDONE;
            elsif op = OP_END_TOKEN then
              -- END_TOKEN is a descriptor and is counted as one.  It starts no
              -- unit, so it never reaches S_ISSUE and never bumps the epoch.
              pf_take  <= '1';
              steps_r  <= steps_r + 1;
              step_idx <= step_idx + 1;
              fetch_en <= '0';
              state    <= S_TOKDONE;
            else
              cur_unit <= unit_of(f_opcode8(pf_w));
              state    <= S_ISSUE;
            end if;

          when S_ISSUE =>
            -- THE ONE INSTANT.  The bank swaps and the epoch bumps here and
            -- nowhere else, and only once `ready` is high and any stale `done`
            -- has been dropped.  `u_start` is a level qualified by this state,
            -- so it is held rather than pulsed at a unit that is not
            -- listening.
            if u_ready(cur_unit) = '1' and u_done(cur_unit) = '0' then
              live_bank <= other(live_bank);
              live_step <= pf_step;
              epoch_r   <= epoch_r + 1;
              pf_take   <= '1';
              issue_r   <= '1';
              jvalid_r  <= '1';
              start_acc <= '1';
              state     <= S_WAIT;
            elsif wdog >= WDOG_LIMIT then
              err_r      <= '1';
              err_code_r <= ERR_WDOG;
              err_step_r <= pf_step;
              -- The drain gets its OWN full watchdog window.  Without this reset
              -- the counter is already past the limit on the first cycle of
              -- S_ABORT, so D never waits for the in-flight unit at all and
              -- releases while its external-memory transactions are still
              -- outstanding -- the exact hazard section 8.2 exists to stop.
              wdog       <= (others => '0');
              state      <= S_ABORT;
            end if;

          when S_WAIT =>
            -- Waits on the STICKY bit.  A raw `u_done` is not read here, and
            -- is not read in any state-conditional branch anywhere in this
            -- file except the stale-done guard in S_ISSUE, which is a
            -- different question (has it been RELEASED, not has it FIRED).
            if done_seen(cur_unit) = '1' then
              state <= S_COMPLETE;
            elsif wdog >= WDOG_LIMIT then
              err_r      <= '1';
              err_code_r <= ERR_WDOG;
              err_step_r <= live_step;
              -- The drain gets its OWN full watchdog window.  Without this reset
              -- the counter is already past the limit on the first cycle of
              -- S_ABORT, so D never waits for the in-flight unit at all and
              -- releases while its external-memory transactions are still
              -- outstanding -- the exact hazard section 8.2 exists to stop.
              wdog       <= (others => '0');
              state      <= S_ABORT;
            end if;

          when S_COMPLETE =>
            -- Order matters: epoch first, because a mismatched epoch means
            -- every other value this unit reported belongs to a different job
            -- and none of it should be believed.
            jvalid_r <= '0';
            if epoch_seen(cur_unit) /= epoch_r then
              err_r      <= '1';
              err_code_r <= ERR_EPOCH;
              err_step_r <= live_step;
              state      <= S_TOKDONE;
            elsif err_seen(cur_unit) = '1' then
              err_r      <= '1';
              err_code_r <= ERR_UNIT;
              err_step_r <= live_step;
              state      <= S_TOKDONE;
            else
              cmp_r    <= '1';
              steps_r  <= steps_r + 1;
              step_idx <= step_idx + 1;
              if abort_r = '1' then
                err_r      <= '1';
                err_code_r <= ERR_ABORT;
                err_step_r <= live_step;
                state      <= S_TOKDONE;
              else
                state <= S_WAITPF;
              end if;
            end if;

          when S_ABORT =>
            -- D cannot kill a unit mid-job: its external-memory transactions
            -- are outstanding.  Wait for the completion or the watchdog, then
            -- report.  The error is already latched.
            jvalid_r <= '0';
            if done_seen(cur_unit) = '1' or wdog >= WDOG_LIMIT then
              state <= S_TOKDONE;
            end if;

          when S_TOKDONE =>
            -- The counting identity.  A clean token must have consumed exactly
            -- `tbl_len` descriptors; anything else is a table or a control bug
            -- and is reported as ERR_DESC rather than as success.
            if err_r = '0' and steps_r /= tbl_len_r then
              err_r      <= '1';
              err_code_r <= ERR_DESC;
              err_step_r <= step_idx;
            end if;
            fetch_en <= '0';
            jvalid_r <= '0';
            tok_r    <= '1';
            busy_r   <= '0';
            state    <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Simulation-only protocol assertions.  They synthesise to nothing, and
  -- like gdn_emit_chain's STRICT_PRODUCER they are a generic rather than
  -- unconditional because a testbench that deliberately drives a violating
  -- unit needs to be able to turn them off.
  -- ======================================================================
  strict_chk : process(clk) is
  begin
    if rising_edge(clk) and rst = '0' and STRICT_PROTO then
      -- A unit still holding `done` when D wants to re-start it.  Legal for a
      -- cycle or two while its ack path drains; a unit that does it routinely
      -- has a slow release that will bite at a different clock.
      assert not (state = S_ISSUE and u_ready(cur_unit) = '1'
                  and u_done(cur_unit) = '1')
        report "seq_desc_fetch: unit is ready but is still asserting done from "
             & "its previous job.  D refuses to start it, because the sticky "
             & "capture would read that as an instant completion."
        severity warning;
      -- A unit asserting `done` while nothing of its is in flight.  This is
      -- the shape that would have made the head-emit defect visible from the
      -- consumer side.
      for u in 0 to NUNIT-1 loop
        assert not (armed(u) = '0' and u_done(u) = '1' and done_seen(u) = '0'
                    and start_acc = '0' and post_ack(u) = '0')
          report "seq_desc_fetch: a unit asserted done while it had no job "
               & "outstanding.  Either its done is stale from the previous "
               & "job or D lost track of what it started."
          severity warning;
      end loop;
    end if;
  end process;

  -- ---- outputs ----------------------------------------------------------
  busy       <= busy_r;
  tok_done   <= tok_r;
  err        <= err_r;
  err_code   <= err_code_r;
  err_step   <= err_step_r;
  steps_done <= steps_r;

  -- Every job_* output is a decode of the LIVE bank.  There is no path from
  -- the URAM read port or the fetch counters to any of them.
  job_valid      <= jvalid_r;
  job_issue      <= issue_r;
  job_cmp        <= cmp_r;
  job_epoch      <= epoch_r;
  job_unit       <= to_unsigned(cur_unit, 3);
  job_opcode     <= f_opcode(lv_w);
  job_flags      <= f_flags(lv_w);
  job_src        <= f_src(lv_w);
  job_src2       <= f_src2(lv_w);
  job_dst        <= f_dst(lv_w);
  job_dst_off    <= f_dstoff(lv_w);
  job_n_rows     <= f_nrows(lv_w);
  job_n_cols     <= f_ncols(lv_w);
  job_w_exp      <= f_wexp(lv_w);
  job_out_shift  <= f_oshift(lv_w);
  job_out_mode   <= f_omode(lv_w);
  job_ordinal    <= f_ord(lv_w);
  job_const_base <= f_cbase(lv_w);
  job_const_exp  <= f_cexp(lv_w);
  job_step       <= live_step;

  -- The candidate, for the external checker.  Deliberately a separate port
  -- group: putting it on job_* would be class (a) in its purest form.
  chk_req     <= '1' when state = S_CHECK else '0';
  chk_opcode  <= f_opcode(pf_w);
  chk_src     <= f_src(pf_w);
  chk_dst     <= f_dst(pf_w);
  chk_dst_off <= f_dstoff(pf_w);
  chk_n_rows  <= f_nrows(pf_w);

  gen_hs : for u in 0 to NUNIT-1 generate
    -- Held while in S_ISSUE, not pulsed: a `start` into a unit that is not
    -- listening is the same defect as a `done` into a D that is not listening.
    u_start(u) <= '1' when state = S_ISSUE and cur_unit = u else '0';
    u_ack(u)   <= '1' when state = S_COMPLETE and cur_unit = u else '0';
  end generate;

end architecture;
