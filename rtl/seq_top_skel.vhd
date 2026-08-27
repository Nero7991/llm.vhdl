-- rtl/seq_top_skel.vhd
-- Subsystem D: transformer sequencer -- SKELETON.
--
-- WHAT THIS IS, AND WHAT IT IS NOT.  This is an interface skeleton for review,
-- written alongside docs/superpowers/specs/2026-08-27-D-sequencer-skeleton.md.
-- It has been checked with `ghdl -a --std=08 -frelaxed` and NOTHING ELSE.  It
-- has never been simulated, never been synthesised, and implements no
-- behaviour: the descriptor decode, the region address generation, the AXI
-- grant mux and D-vec are all absent.  Do not read a passing analysis as
-- evidence of anything beyond well-formed VHDL.  Note also that the GHDL here
-- is the mcode backend, where `ghdl -e` produces no binary and silently
-- succeeds, so elaborating it would prove nothing either.
--
-- WHY IT EXISTS AT ALL.  Two integration defects were found on 2026-08-27, one
-- level down in subsystem B, and both are defect CLASSES that D reproduces at
-- 64x the scale:
--
--   (a) docs/debugging/2026-08-27_gdn-emit-chain-w-latch.md
--       `w_mant` was a single unlatched port, read combinationally once per
--       head for all 24 heads of a block, while blocks OVERLAP by design.
--       Head 23 of every block normalised with block b+1's weights.  The safe
--       window existed; it was not OBSERVABLE from outside the unit.
--
--   (b) docs/debugging/2026-08-27_gdn-head-emit-done-pulse.md
--       `done` was a one-cycle pulse with no handshake.  When the consumer
--       happened to be busy the pulse was missed and an ENTIRE HEAD was
--       discarded, silently.  The lossy path scored BETTER on the
--       back-pressure metric than the fixed one did.
--
-- The declarations below exist to make both classes structurally impossible in
-- D, and they are the reason this file is worth having before the real RTL:
--
--   against (a): a two-bank job SHADOW register set written at exactly one
--                instant (the `start` pulse); a `job_epoch` tag echoed back by
--                every unit at `done` and compared, so a unit that latched a
--                value from a different job raises ERR_EPOCH instead of
--                producing a quietly wrong number; and `b_w_taken`, consumed
--                here, gating the block-counter advance.
--
--   against (b): every unit `done` is captured into a STICKY `done_seen` bit
--                which is the SOLE sampler in this file, and every `done` is
--                acknowledged.  `done` is never read inside a state-conditional
--                branch.  Section 5.3 of the spec explains why D in particular
--                cannot be assumed to be listening: it is a 1,106-step machine
--                with error handling, grant switching and watchdogs.
--
-- The spec's section 5.1 carries a stallability verdict for every port.  Five
-- interfaces here CANNOT be stalled; four are safe by a structural argument and
-- the fifth, E's output stream into D-vec's residual, is safe by nothing.  That
-- one is marked UNRESOLVED at its port below and must be settled before D-vec
-- RTL exists.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.util_pkg.all;

entity seq_top_skel is
  generic(
    -- 1,106 steps per token at 27B / N=2 (48 GDN x 18 + 16 attn x 15 + final
    -- norm + lm_head).  Sized with headroom; the table is data, not gateware,
    -- which is what makes N=1 and smaller models a configuration (D section 4.4).
    STEPS_MAX : positive := 2048;
    N_BLOCKS  : positive := 64;
    HIDDEN    : positive := 5120;
    -- Activation regions: X XN QKV Z BETA ALPHA QG KIN VIN Y G U H ER.
    NREG      : positive := 14;
    -- Exponent capture slots.  NREG + 2, because QKV carries three segment
    -- exponents (q, k, v) rather than one.  See hazard A3: these are part of
    -- the LOCKED object, not a separate register file.
    NEXP      : positive := 16;
    -- Job epoch width.  4 bits is 16 jobs of separation, far more than the
    -- pipeline depth of any unit; it only has to be wider than the number of
    -- jobs that can be in flight, which is one.
    EPOCH_W   : positive := 4;
    -- HBM AXI ports whose outstanding counters D watches (section 8.2 rule).
    -- 30 of 32: SAXI_00 and SAXI_16 carry jtag_hbm.
    NPORT     : positive := 30;
    WDOG_W    : positive := 32
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ============================ HOST =================================
    -- Stallable: yes.  The host polls `h_busy`; `h_go` is a W1P register bit.
    h_go        : in  std_logic;
    h_seq_init  : in  std_logic;
    h_abort     : in  std_logic;
    h_ctx_len   : in  unsigned(15 downto 0);
    -- `h_token_done` is a W1C STATUS BIT, not a pulse.  Defect class (b)
    -- applies to D's own outputs as much as to its inputs.
    h_busy      : out std_logic;
    h_token_done: out std_logic;
    h_err       : out std_logic;                       -- sticky
    h_err_code  : out std_logic_vector(3 downto 0);
    h_err_step  : out unsigned(10 downto 0);
    h_cur_pos   : out unsigned(15 downto 0);

    -- ====================== DESCRIPTOR MEMORY (URAM) ====================
    -- Stallable: n/a, D is the only master.  Registered read.
    -- The read port NEVER drives a unit port directly: it writes the prefetch
    -- bank of the shadow set, and the banks swap only at `start`.  That is the
    -- whole of the hazard-A1 mechanism.
    d_raddr  : out unsigned(15 downto 0);
    d_rdata  : in  std_logic_vector(63 downto 0);
    d_rvalid : in  std_logic;

    -- ================== JOB SHADOW, BROADCAST TO ALL UNITS ==============
    -- Every signal in this group is a SHADOW REGISTER written at exactly one
    -- instant, the `start` pulse of the job it belongs to.  None of them is a
    -- live counter or a combinational function of one.  This is the normative
    -- rule of spec section 5.2 and it is what defect (a) violated.
    job_epoch      : out unsigned(EPOCH_W-1 downto 0);
    job_src_region : out unsigned(3 downto 0);
    job_dst_region : out unsigned(3 downto 0);
    job_dst_offset : out unsigned(15 downto 0);
    job_n_rows     : out unsigned(15 downto 0);
    job_n_cols     : out unsigned(15 downto 0);
    job_w_exp      : out signed(15 downto 0);
    job_out_shift  : out signed(15 downto 0);
    job_out_mode   : out std_logic_vector(1 downto 0);
    job_ordinal    : out unsigned(5 downto 0);          -- B: 0..47, C: 0..15

    -- ============================ SUBSYSTEM A ===========================
    -- `a_start` is held until `a_ready` accepts it (hazard B8).
    -- `a_done` MUST be a level held until `a_ack` (hazard B1).  Where a unit
    -- cannot be changed, `done_seen` below is the compensating mechanism and
    -- is the sole sampler.
    a_start      : out std_logic;
    a_ready      : in  std_logic;
    a_done       : in  std_logic;
    a_ack        : out std_logic;
    a_err        : in  std_logic;
    a_sat_event  : in  std_logic;                      -- sticky, logged not fatal
    a_done_epoch : in  unsigned(EPOCH_W-1 downto 0);   -- echoed, compared
    a_x_exp      : out signed(15 downto 0);            -- captured, never live
    a_y_exp      : in  signed(15 downto 0);            -- valid at `a_done`
    -- A's y stream and x read port are NOT in this skeleton.  Both are
    -- UNSTALLABLE by A section 5 and 7.8: the region write port must accept one
    -- element per cycle unconditionally and the region read port must return a
    -- BLOCK-wide word every cycle.  Single-writer and single-reader by the
    -- lock; that structural argument is what makes them safe, and it is an
    -- obligation on the region bank RTL, not on this FSM.

    -- ============================ SUBSYSTEM B ===========================
    b_start      : out std_logic;
    b_ready      : in  std_logic;
    b_done       : in  std_logic;
    b_ack        : out std_logic;
    b_err        : in  std_logic;
    b_done_epoch : in  unsigned(EPOCH_W-1 downto 0);
    b_seq_rst    : out std_logic;                      -- sequence start, NOT per token
    -- ssm_norm select.  THIS IS HAZARD A2, one level up from the defect that
    -- was actually found: the address must be a registered copy latched at job
    -- issue, never the live block counter, and D must not advance the block
    -- counter until `b_w_taken` fires.
    b_w_sel      : out unsigned(5 downto 0);
    b_w_taken    : in  std_logic;
    -- The six independent captured input exponents (O15).  Frozen by the
    -- region lock: see hazard A3, which is the NEW finding of this pass.
    b_exp_qkvq   : out signed(15 downto 0);
    b_exp_qkvk   : out signed(15 downto 0);
    b_exp_qkvv   : out signed(15 downto 0);
    b_exp_z      : out signed(15 downto 0);
    b_exp_beta   : out signed(15 downto 0);
    b_exp_alpha  : out signed(15 downto 0);
    b_y_exp      : in  signed(15 downto 0);

    -- ============================ SUBSYSTEM C ===========================
    c_start      : out std_logic;
    c_ready      : in  std_logic;
    c_done       : in  std_logic;
    c_ack        : out std_logic;
    c_err        : in  std_logic;
    c_rope_sat   : in  std_logic;                      -- sticky, logged not fatal
    c_rescale_max: in  unsigned(15 downto 0);          -- a counter, always valid
    c_done_epoch : in  unsigned(EPOCH_W-1 downto 0);
    c_kv_seq_rst : out std_logic;                      -- sequence start, NOT per token
    -- Latched at C's issue, not driven from the live counters (hazard A4).
    c_cur_pos    : out unsigned(15 downto 0);
    c_ctx_len    : out unsigned(15 downto 0);
    c_exp_qg     : out signed(15 downto 0);
    c_exp_k      : out signed(15 downto 0);
    c_exp_v      : out signed(15 downto 0);
    c_y_exp      : in  signed(15 downto 0);

    -- ============================ SUBSYSTEM E ===========================
    e_start      : out std_logic;
    e_ready      : in  std_logic;
    e_done       : in  std_logic;
    e_ack        : out std_logic;
    e_err        : in  std_logic;
    e_done_epoch : in  unsigned(EPOCH_W-1 downto 0);
    e_seq        : out unsigned(15 downto 0);          -- per-collective, reset by seq_init
    e_y_exp      : out signed(15 downto 0);            -- the producing job's captured y_exp
    -- UNSTALLABLE, AND UNRESOLVED.  E section 2 gives o_we/o_addr/o_data no
    -- ready, and D section 4.5 pipelines that stream straight into D-vec's
    -- residual pass 1.  If pass 1 stalls for one cycle the beat is LOST, and
    -- lost exactly the way gdn_recur_pipe's columns were lost: silently, with
    -- no counter moving.  `e_o_ready` below is a REQUEST to E, not a port E
    -- currently has (spec hazard B7).  Three exits: E gains this ready; or
    -- pass 1 is proven to consume one element per cycle with no arbitration;
    -- or the pipelining is dropped and ER is the landing buffer, at ~2.18 ms
    -- per token, which is 6% and not affordable.
    e_o_we       : in  std_logic;
    e_o_ready    : out std_logic;

    -- ============================== D-vec ===============================
    -- D-vec is 28 DSP MEASURED at LANES_V = 8 when built to share.  D-ctrl,
    -- i.e. everything else in this file, is 0 DSP: no multiply survives here
    -- because the tile counts come from the descriptor, the ordinals come from
    -- the host generator, and the one non-power-of-two stride (the 5120-element
    -- norm-weight vector) is walked with an adder-accumulator rather than
    -- multiplied.  See spec section 4.1.
    v_start      : out std_logic;
    v_ready      : in  std_logic;
    v_done       : in  std_logic;
    v_ack        : out std_logic;
    v_err        : in  std_logic;
    v_done_epoch : in  unsigned(EPOCH_W-1 downto 0);
    v_mode       : out std_logic_vector(1 downto 0);   -- 00 norm, 01 residual, 10 swiglu
    v_const_base : out unsigned(15 downto 0);          -- accumulated, not multiplied
    v_out_exp    : in  signed(15 downto 0);

    -- ==================== HBM PORT GRANT (section 8.2) ==================
    -- Hazard A5: the grant register is read combinationally by the AXI mux for
    -- the whole job, so it is the same shape as defect (a).  The rule is that
    -- it may change only when every port being re-granted reports zero
    -- outstanding, and `grant_taken` makes that instant observable rather than
    -- inferred.  D counts AT THE PORT, independent of what any unit claims:
    -- a unit's `done` does NOT imply its AXI transactions have retired.
    grant_sel    : out std_logic;                      -- 0 = B, 1 = C
    grant_taken  : in  std_logic;
    port_rd_busy : in  std_logic_vector(NPORT-1 downto 0);
    port_wr_busy : in  std_logic_vector(NPORT-1 downto 0);

    -- =================== REGION LOCKS, OBSERVABLE ======================
    -- Exposed so the stub testbench of spec section 5.4 can assert every lock
    -- transition rather than infer it.  `lock_viol` is asserted by the region
    -- fabric when a write strobe hits a HELD region; that write is DROPPED and
    -- raises ERR_LOCK.  Hazard A3 extends the same drop to a write aimed at
    -- the exponent capture slot of a HELD region.
    lock_state   : out std_logic_vector(2*NREG-1 downto 0);
    lock_viol    : in  std_logic
  );
end entity;

architecture skel of seq_top_skel is

  -- Error codes.  ERR_EPOCH is the one this pass adds: it is what turns defect
  -- class (a) from "invisible until the output is wrong" into a runtime error
  -- naming the failing step.
  constant ERR_NONE  : std_logic_vector(3 downto 0) := x"0";
  constant ERR_UNIT  : std_logic_vector(3 downto 0) := x"1";
  constant ERR_LOCK  : std_logic_vector(3 downto 0) := x"2";
  constant ERR_DESC  : std_logic_vector(3 downto 0) := x"3";
  constant ERR_WDOG  : std_logic_vector(3 downto 0) := x"4";
  constant ERR_GRANT : std_logic_vector(3 downto 0) := x"5";
  constant ERR_CTX   : std_logic_vector(3 downto 0) := x"6";
  constant ERR_EPOCH : std_logic_vector(3 downto 0) := x"7";
  constant ERR_ABORT : std_logic_vector(3 downto 0) := x"8";

  -- Unit ids, used to index the sticky done capture.
  constant U_A : integer := 0;
  constant U_B : integer := 1;
  constant U_C : integer := 2;
  constant U_E : integer := 3;
  constant U_V : integer := 4;
  constant NUNIT : integer := 5;

  type state_t is (
    S_RESET,     -- locks FREE, counters zero
    S_IDLE,      -- waiting for `go`
    S_FETCH,     -- descriptor read issued into the PREFETCH bank
    S_DECODE,    -- opcode and field decode, still in the prefetch bank
    S_CHECK,     -- descriptor-class checks BEFORE any unit starts (A section 7.6 discipline)
    S_GRANT,     -- wait for outstanding == 0 on every port being re-granted
    S_ISSUE,     -- swap shadow banks, bump epoch, hold `start` until `ready`
    S_WAIT,      -- wait on the STICKY done_seen, never on the raw `done`
    S_COMPLETE,  -- ack, epoch compare, exponent capture, lock release
    S_ABORT,     -- drain the in-flight unit, release grants, latch ERR_INFO
    S_TOKDONE    -- advance cur_pos, latch argmax, raise token_done
  );

  signal state : state_t := S_RESET;

  -- ---- job shadow, TWO BANKS -------------------------------------------
  -- The point of two banks is that the prefetch of step n+1 (D section 4.5,
  -- "zero cost") writes the bank that is NOT being read by the running unit.
  -- With one bank the prefetch IS defect (a): the running unit would see the
  -- next job's n_rows, w_exp and bases partway through.
  type shadow_t is record
    src_region : unsigned(3 downto 0);
    dst_region : unsigned(3 downto 0);
    dst_offset : unsigned(15 downto 0);
    n_rows     : unsigned(15 downto 0);
    n_cols     : unsigned(15 downto 0);
    w_exp      : signed(15 downto 0);
    out_shift  : signed(15 downto 0);
    out_mode   : std_logic_vector(1 downto 0);
    ordinal    : unsigned(5 downto 0);
    opcode     : unsigned(3 downto 0);
    valid      : std_logic;
  end record;

  constant SHADOW_CLR : shadow_t := (
    src_region => (others => '0'), dst_region => (others => '0'),
    dst_offset => (others => '0'), n_rows => (others => '0'),
    n_cols => (others => '0'), w_exp => (others => '0'),
    out_shift => (others => '0'), out_mode => "00",
    ordinal => (others => '0'), opcode => (others => '0'), valid => '0');

  type shadow_arr is array (0 to 1) of shadow_t;
  signal shadow : shadow_arr := (others => SHADOW_CLR);
  signal live_bank : integer range 0 to 1 := 0;   -- bank the running unit reads

  -- ---- job epoch --------------------------------------------------------
  -- Presented alongside the shadow.  Every unit that latches a D-supplied
  -- value latches this with it and echoes it back at `done`.  A mismatch means
  -- the unit latched across a job boundary.  Cost: 4 FF here, 4 per unit, one
  -- comparator.  This is the detector the w-latch document says was missing.
  signal epoch_r : unsigned(EPOCH_W-1 downto 0) := (others => '0');

  -- ---- STICKY done capture (defect class (b)) ---------------------------
  -- Set combinationally-registered from each unit's `done` in EVERY cycle, in
  -- an unconditional process branch, and cleared ONLY when that unit is next
  -- started.  Nothing in the FSM samples a raw `done`.  If a unit ever reverts
  -- to a one-cycle pulse, this still catches it.
  signal done_seen : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal err_seen  : std_logic_vector(NUNIT-1 downto 0) := (others => '0');
  signal cur_unit  : integer range 0 to NUNIT-1 := U_A;

  -- ---- region locks -----------------------------------------------------
  -- 00 FREE, 01 FILLING, 10 HELD.  HELD rejects every write, and per hazard
  -- A3 that now includes a write to the region's EXPONENT capture slot: the
  -- exponent is read by the consumer for the whole job, so it has the same
  -- live window as the data and must have the same protection.
  type lock_arr is array (0 to NREG-1) of std_logic_vector(1 downto 0);
  signal lock : lock_arr := (others => "00");
  type fill_arr is array (0 to NREG-1) of unsigned(13 downto 0);
  signal fill_ptr : fill_arr := (others => (others => '0'));

  -- ---- exponent capture -------------------------------------------------
  -- Captured at the PRODUCER's `done`, never re-read live.  BFP y_exp is only
  -- final after A's amax scan, so any earlier capture instant is wrong, and any
  -- later read gets whatever job ran last.
  type exp_arr is array (0 to NEXP-1) of signed(15 downto 0);
  signal exp_cap : exp_arr := (others => (others => '0'));

  -- ---- counters and status ---------------------------------------------
  signal step_idx   : unsigned(10 downto 0) := (others => '0');
  signal steps_done : unsigned(10 downto 0) := (others => '0');  -- must equal the table length
  signal block_idx  : unsigned(5 downto 0)  := (others => '0');
  signal cur_pos_r  : unsigned(15 downto 0) := (others => '0');
  signal ctx_len_r  : unsigned(15 downto 0) := (others => '0');
  signal seq_ctr    : unsigned(15 downto 0) := (others => '0');  -- E's per-collective seq
  signal wdog       : unsigned(WDOG_W-1 downto 0) := (others => '0');
  signal err_r      : std_logic := '0';
  signal err_code_r : std_logic_vector(3 downto 0) := ERR_NONE;
  signal err_step_r : unsigned(10 downto 0) := (others => '0');
  signal busy_r     : std_logic := '0';
  signal tokdone_r  : std_logic := '0';

  -- ---- block-counter advance gate (hazard A2) ---------------------------
  -- The block counter may not advance while a consumer still holds a
  -- per-block value latched from it.  For B that consumer is the emit chain
  -- and the observable instant is `b_w_taken`.
  signal w_taken_seen : std_logic := '0';

  -- ---- grant ------------------------------------------------------------
  signal grant_r      : std_logic := '0';
  signal grant_ok_seen: std_logic := '0';

  -- True while any port being re-granted still has transactions in flight.
  -- Counted at the port, not inferred from `done`.
  signal ports_busy : std_logic;

begin

  -- Any outstanding transaction on any watched port blocks a grant change.
  -- The real design narrows this to the ports actually being re-granted; the
  -- skeleton takes the conservative OR so the intent is unambiguous.
  ports_busy <= '1' when (port_rd_busy /= (port_rd_busy'range => '0'))
                      or (port_wr_busy /= (port_wr_busy'range => '0'))
                else '0';

  -- ---- outputs driven from the LIVE shadow bank only --------------------
  job_epoch      <= epoch_r;
  job_src_region <= shadow(live_bank).src_region;
  job_dst_region <= shadow(live_bank).dst_region;
  job_dst_offset <= shadow(live_bank).dst_offset;
  job_n_rows     <= shadow(live_bank).n_rows;
  job_n_cols     <= shadow(live_bank).n_cols;
  job_w_exp      <= shadow(live_bank).w_exp;
  job_out_shift  <= shadow(live_bank).out_shift;
  job_out_mode   <= shadow(live_bank).out_mode;
  job_ordinal    <= shadow(live_bank).ordinal;

  -- B's ssm_norm select is the LATCHED ordinal, not the live block counter.
  b_w_sel <= shadow(live_bank).ordinal;

  -- Captured exponents.  Slot assignment is descriptor-driven in the real
  -- design; the skeleton wires fixed slots so the shape is reviewable.
  b_exp_qkvq  <= exp_cap(0);
  b_exp_qkvk  <= exp_cap(1);
  b_exp_qkvv  <= exp_cap(2);
  b_exp_z     <= exp_cap(3);
  b_exp_beta  <= exp_cap(4);
  b_exp_alpha <= exp_cap(5);
  c_exp_qg    <= exp_cap(6);
  c_exp_k     <= exp_cap(7);
  c_exp_v     <= exp_cap(8);
  a_x_exp     <= exp_cap(9);
  e_y_exp     <= exp_cap(10);

  c_cur_pos <= cur_pos_r;
  c_ctx_len <= ctx_len_r;
  e_seq     <= seq_ctr;

  h_busy       <= busy_r;
  h_token_done <= tokdone_r;
  h_err        <= err_r;
  h_err_code   <= err_code_r;
  h_err_step   <= err_step_r;
  h_cur_pos    <= cur_pos_r;

  -- E's stream ready.  Held low in the skeleton precisely so that a reviewer
  -- has to decide hazard B7 rather than inherit a default that looks safe.
  e_o_ready <= '0';

  gen_lock_out : for i in 0 to NREG-1 generate
    lock_state(2*i+1 downto 2*i) <= lock(i);
  end generate;

  -- Descriptor fetch address.  64-byte header, so a shift, not a multiply
  -- (spec section 4.1: D-ctrl is 0 DSP and this is one of the reasons).
  d_raddr <= resize(step_idx & "000", 16);

  -- ======================================================================
  -- STICKY done and err capture.  UNCONDITIONAL: this branch runs in every
  -- state, in every cycle.  This is the entire defence against defect class
  -- (b) and it must not be moved inside a state test.
  -- ======================================================================
  capture : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        done_seen    <= (others => '0');
        err_seen     <= (others => '0');
        w_taken_seen <= '0';
        grant_ok_seen<= '0';
      else
        if a_done = '1' then done_seen(U_A) <= '1'; err_seen(U_A) <= a_err; end if;
        if b_done = '1' then done_seen(U_B) <= '1'; err_seen(U_B) <= b_err; end if;
        if c_done = '1' then done_seen(U_C) <= '1'; err_seen(U_C) <= c_err; end if;
        if e_done = '1' then done_seen(U_E) <= '1'; err_seen(U_E) <= e_err; end if;
        if v_done = '1' then done_seen(U_V) <= '1'; err_seen(U_V) <= v_err; end if;

        if b_w_taken = '1' then w_taken_seen <= '1'; end if;
        if grant_taken = '1' then grant_ok_seen <= '1'; end if;

        -- Cleared only at the next issue of that unit.  STUB: the real design
        -- clears exactly one bit, selected by `cur_unit`, in S_ISSUE.
        if state = S_ISSUE then
          done_seen    <= (others => '0');
          err_seen     <= (others => '0');
          w_taken_seen <= '0';
          grant_ok_seen<= '0';
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Master FSM.  OUTLINE ONLY.  Every state below is one clocked decision;
  -- the project's timing rule bans two of {barrel shift, wide add, wide
  -- compare, bus mux, multiply} in series inside one state, and the reason
  -- S_CHECK, S_GRANT and S_ISSUE are separate states rather than one is that
  -- the bound check, the port-busy reduction and the bank mux would otherwise
  -- be three of those in series.
  -- ======================================================================
  fsm : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state      <= S_RESET;
        step_idx   <= (others => '0');
        steps_done <= (others => '0');
        block_idx  <= (others => '0');
        cur_pos_r  <= (others => '0');
        ctx_len_r  <= (others => '0');
        seq_ctr    <= (others => '0');
        epoch_r    <= (others => '0');
        live_bank  <= 0;
        lock       <= (others => "00");
        fill_ptr   <= (others => (others => '0'));
        wdog       <= (others => '0');
        err_r      <= '0';
        err_code_r <= ERR_NONE;
        err_step_r <= (others => '0');
        busy_r     <= '0';
        tokdone_r  <= '0';
        grant_r    <= '0';
        cur_unit   <= U_A;
        shadow     <= (others => SHADOW_CLR);
      else

        -- Per-job watchdog.  It exists because a lost `done` used to be
        -- undetectable; with the sticky capture above it should never fire,
        -- and if it does it means the unit genuinely hung rather than that D
        -- missed a pulse.  Keeping both is deliberate.
        if state = S_WAIT then
          wdog <= wdog + 1;
        else
          wdog <= (others => '0');
        end if;

        case state is

          when S_RESET =>
            state  <= S_IDLE;
            busy_r <= '0';

          when S_IDLE =>
            tokdone_r <= '0';
            if h_go = '1' then
              if cur_pos_r >= ctx_len_r then
                err_r      <= '1';
                err_code_r <= ERR_CTX;
                state      <= S_TOKDONE;   -- token_done with err, host never hangs
              else
                busy_r     <= '1';
                step_idx   <= (others => '0');
                steps_done <= (others => '0');
                block_idx  <= (others => '0');
                if h_seq_init = '1' then
                  ctx_len_r <= h_ctx_len;
                  seq_ctr   <= (others => '0');
                  cur_pos_r <= (others => '0');
                end if;
                state <= S_FETCH;
              end if;
            end if;

          when S_FETCH =>
            -- STUB: assemble the 64-byte header into shadow(1 - live_bank)
            -- over eight 64-bit beats.  The PREFETCH bank only; the running
            -- unit keeps reading `live_bank`.
            if d_rvalid = '1' then
              state <= S_DECODE;
            end if;

          when S_DECODE =>
            -- STUB: opcode decode, unit select into `cur_unit`.
            state <= S_CHECK;

          when S_CHECK =>
            -- Descriptor-class checks run BEFORE the unit starts, so a bad
            -- table aborts before it produces output (A section 7.6).
            -- STUB: dst_offset = fill_ptr; dst_offset + n_rows within region;
            -- opcode known; nsub within NSUB_MAX; dst = 0xFF implies a route
            -- flag.  Any failure -> ERR_DESC.
            if lock_viol = '1' then
              err_r      <= '1';
              err_code_r <= ERR_LOCK;
              err_step_r <= step_idx;
              state      <= S_ABORT;
            else
              state <= S_GRANT;
            end if;

          when S_GRANT =>
            -- Section 8.2: the grant may change only when every port being
            -- re-granted reports zero outstanding.  A unit's `done` does NOT
            -- imply its transactions retired.
            if ports_busy = '0' then
              grant_r <= '1' when cur_unit = U_C else '0';
              state   <= S_ISSUE;
            elsif wdog(WDOG_W-1) = '1' then
              err_r      <= '1';
              err_code_r <= ERR_GRANT;
              err_step_r <= step_idx;
              state      <= S_ABORT;
            end if;

          when S_ISSUE =>
            -- THE ONE INSTANT.  The shadow banks swap and the epoch bumps here
            -- and nowhere else.  Everything a unit reads for the duration of
            -- its job is defined by this edge.
            live_bank <= 1 - live_bank;
            epoch_r   <= epoch_r + 1;
            state     <= S_WAIT;

          when S_WAIT =>
            -- Waits on the STICKY bit, never on the raw `done`.
            if done_seen(cur_unit) = '1' then
              state <= S_COMPLETE;
            elsif wdog(WDOG_W-1) = '1' then
              err_r      <= '1';
              err_code_r <= ERR_WDOG;
              err_step_r <= step_idx;
              state      <= S_ABORT;
            end if;

          when S_COMPLETE =>
            -- Order matters: epoch compare, then unit err, then capture.
            -- STUB: the epoch compare below is written for A only; the real
            -- design selects the echoed epoch by `cur_unit`.
            if (cur_unit = U_A and a_done_epoch /= epoch_r)
            or (cur_unit = U_B and b_done_epoch /= epoch_r)
            or (cur_unit = U_C and c_done_epoch /= epoch_r)
            or (cur_unit = U_E and e_done_epoch /= epoch_r)
            or (cur_unit = U_V and v_done_epoch /= epoch_r) then
              err_r      <= '1';
              err_code_r <= ERR_EPOCH;
              err_step_r <= step_idx;
              state      <= S_ABORT;
            elsif err_seen(cur_unit) = '1' then
              err_r      <= '1';
              err_code_r <= ERR_UNIT;
              err_step_r <= step_idx;
              state      <= S_ABORT;
            else
              -- STUB: capture the producer's y_exp into the destination
              -- region's exponent slot; release the consumer's locks; advance
              -- fill_ptr.  The block counter advance is gated on
              -- `w_taken_seen` for GDN steps (hazard A2).
              steps_done <= steps_done + 1;
              step_idx   <= step_idx + 1;
              if h_abort = '1' then
                err_code_r <= ERR_ABORT;
                state      <= S_ABORT;
              else
                -- STUB: END_TOKEN opcode ends the walk; the skeleton runs on.
                state <= S_FETCH;
              end if;
            end if;

          when S_ABORT =>
            -- D cannot kill a unit mid-job: its AXI transactions are
            -- outstanding.  Wait for `done` or the watchdog, release grants
            -- under the section 8.2 rule, then report.  `cur_pos` does NOT
            -- advance: a failed token may already have written KV[cur_pos] and
            -- GDN state, so the host's safe recovery is a sequence replay.
            if done_seen(cur_unit) = '1' or wdog(WDOG_W-1) = '1' then
              state <= S_TOKDONE;
            end if;

          when S_TOKDONE =>
            -- token_done is raised even on error so the host never hangs.
            if err_r = '0' then
              cur_pos_r <= cur_pos_r + 1;
            end if;
            tokdone_r <= '1';
            busy_r    <= '0';
            state     <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

  -- ---- start / ack strobes ---------------------------------------------
  -- `start` is held through S_ISSUE until the unit's `ready` accepts it
  -- (hazard B8), and `ack` is asserted in S_COMPLETE to release the unit's
  -- held `done` (hazard B1).  Both are levels qualified by state, not pulses.
  a_start <= '1' when state = S_ISSUE and cur_unit = U_A and a_ready = '1' else '0';
  b_start <= '1' when state = S_ISSUE and cur_unit = U_B and b_ready = '1' else '0';
  c_start <= '1' when state = S_ISSUE and cur_unit = U_C and c_ready = '1' else '0';
  e_start <= '1' when state = S_ISSUE and cur_unit = U_E and e_ready = '1' else '0';
  v_start <= '1' when state = S_ISSUE and cur_unit = U_V and v_ready = '1' else '0';

  a_ack <= '1' when state = S_COMPLETE and cur_unit = U_A else '0';
  b_ack <= '1' when state = S_COMPLETE and cur_unit = U_B else '0';
  c_ack <= '1' when state = S_COMPLETE and cur_unit = U_C else '0';
  e_ack <= '1' when state = S_COMPLETE and cur_unit = U_E else '0';
  v_ack <= '1' when state = S_COMPLETE and cur_unit = U_V else '0';

  -- Sequence-scoped resets.  Asserted at sequence start, NOT per token
  -- (O10, O11).  STUB: pulsed before step 1 of the seq_init token.
  b_seq_rst    <= '0';
  c_kv_seq_rst <= '0';

  grant_sel    <= grant_r;
  v_mode       <= shadow(live_bank).out_mode;
  v_const_base <= (others => '0');   -- STUB: adder-accumulated, never multiplied

end architecture;
