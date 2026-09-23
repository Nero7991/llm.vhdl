-- rtl/seq_vec_issue.vhd
-- Subsystem D: THE D-VEC ISSUE ADAPTER.  This is the seam between D-ctrl and
-- D-vec, and until it existed the two halves of D had never met: `seq_opdec`
-- decoded `OP_VEC_RES` and issued it to nothing, and `seq_vec_res` executed
-- `OP_VEC_RES` and was started by a testbench.  Each was verified against a
-- stub of the other, which is exactly the condition that produced four
-- findings when `seq_desc_fetch` and `seq_region_lock` were first connected
-- (`docs/debugging/2026-08-27_d-sequencer-opcode-decode.md`).
--
-- ======================================================================
-- WHY AN ADAPTER IS NEEDED AT ALL, RATHER THAN WIRES
-- ======================================================================
-- The two sides speak different protocols and neither is wrong:
--
--   D-ctrl (`seq_desc_fetch`) issues by BROADCAST.  It raises `u_start(u)` for
--   the selected unit while a 20-signal `job_*` shadow describes the step, and
--   the shadow is only guaranteed from the cycle `job_issue` pulses -- which is
--   the cycle AFTER `u_start` was accepted, because `live_bank` and `issue_r`
--   move on the same edge.  So a unit cannot read its parameters in the cycle
--   it is started.
--
--   D-vec (`seq_vec_res`) issues by VALUE.  It wants `i_n`, `i_exp_x` and
--   `i_exp_e` valid in the cycle it accepts `start`, and it latches all three
--   at that one instant.
--
-- And two of those three values are not in the descriptor at all.  The
-- descriptor names REGIONS (`src`, `src2`); the EXPONENTS of those regions
-- live in `seq_region_lock`'s capture file, written at each producing step's
-- completion.  Nothing read that file before this unit: `exp_rd_region` /
-- `exp_rd_seg` / `exp_rd_data` / `exp_rd_valid` were declared, tested by
-- `tb_seq_region_lock` driving them directly, and connected to no consumer.
--
-- So the adapter's job is: accept the broadcast start, latch the shadow one
-- cycle later when it is valid, LOOK UP the two source exponents in the lock,
-- and only then start the engine by value.  Four clocked states, one action
-- each.
--
-- ======================================================================
-- THE THREE DEFECT CLASSES, AT THIS SEAM
-- ======================================================================
--
-- (a) A VALUE READ FOR THE DURATION OF A LONG OPERATION while its source moves
--     on underneath.  The residual runs for 2*ceil(n/LANES) + 23 cycles --
--     1,047 at the 9B target -- and `job_*` is a combinational decode of a
--     descriptor bank that the walker is free to move as soon as the job is
--     running.  Mechanism: EVERY field this unit uses is copied into a
--     job-scoped register at the ONE instant `job_issue` is high, `iss_lat`
--     pulses there so the instant is observable from outside, and nothing in
--     this file reads a `job_*` port again until the next `job_issue`.  That
--     includes `job_epoch`, which `seq_desc_fetch` compares at completion: a
--     live read of it would be an equivalent mutant TODAY (the walker does not
--     move the epoch mid-job) and would stop being one the moment anything
--     overlaps.
--
-- (b) A COMPLETION SIGNALLED AS A ONE-CYCLE PULSE and discarded because the
--     consumer was busy.  `u_done` out of this unit is a LEVEL, driven from
--     the FSM state and held until `u_ack`, and the engine's `v_done` is
--     captured STICKILY the first cycle it is observed rather than sampled
--     when convenient.  The sticky capture is what makes the adapter correct
--     against an engine that pulses `done` -- which `seq_vec_res` does not do,
--     but which the withdrawn `engine_shared` convention did and which a
--     future D-vec op might.
--
--     Note the shape of the completion register, because this is where the
--     `gdn_head_emit` defect lives: the state is set to V_HOLD on the edge the
--     completion is captured and left there, and it is cleared ONLY in the ack
--     branch of V_HOLD.  There is no `done <= '0'` default anywhere.  A default
--     clear plus a set inside the ack branch is what destroys the pulse when
--     the ack is tied high, and that bug was caught in `gdn_head_emit` only by
--     running the OLD testbench.
--
-- (c) A SCALAR PUBLISHED AFTER THE STREAM IT QUALIFIES.  `u_y_exp` qualifies
--     nothing this unit emits, but it is latched by `seq_opdec` at the FIRST
--     cycle `u_done` is observed, so it must be valid THERE.  `y_r` is
--     assigned on the same edge that moves the state to V_HOLD, and `u_done`
--     is a decode of that state, so the payload and its valid become true on
--     the same edge -- the same relation `seq_opdec`'s own `x_exp` / `x_pulse`
--     pair has, which the ordering audit
--     (`docs/debugging/2026-08-27_d-seq-scalar-ordering-audit.md`) recorded as
--     the correct one for a `_taken`-style pulse.  It is NOT a pass-through of
--     the engine's live `o_exp`: `seq_vec_res` guarantees `o_exp` only while
--     it is asserting `done`, and a pass-through would make this unit's
--     contract depend on the engine's hold time rather than on its own.
--
-- ======================================================================
-- WHY `u_ready` REQUIRES *EVERY* D-VEC ENGINE TO BE IDLE
-- ======================================================================
-- `seq_desc_fetch` maps all three D-vec opcodes -- `OP_VEC_NORM`,
-- `OP_VEC_RES`, `OP_VEC_SWG` -- to ONE unit index, and it tests
-- `u_ready(cur_unit)` in S_ISSUE, which is one clocked state BEFORE this unit
-- can know which opcode is coming.  The candidate opcode is on `chk_opcode`
-- during S_CHECK, but reading the `chk_*` group outside `chk_req` is the
-- documented trap a2 in `seq_opdec` -- the prefetch bank is written beat by
-- beat, so outside `chk_req` those ports show half of one descriptor and half
-- of the next.
--
-- So `u_ready` is the AND of every engine's `ready` plus this unit being idle.
-- That is exactly right rather than merely conservative: D runs one job at a
-- time, so the three engines are idle together or not at all, and the AND
-- costs one gate against a latched-candidate-opcode scheme that would have to
-- take a position on a2.
--
-- ======================================================================
-- WHAT THIS UNIT DOES NOT DO
-- ======================================================================
-- It does not hold activation data and it does not mux the region banks: it
-- PUBLISHES the region numbers (`v_reg_a`, `v_reg_b`, `v_reg_d`) that the
-- region fabric muxes on, latched for the job, and the fabric is somebody
-- else's unit that does not exist yet.  It does not decode the descriptor --
-- `seq_opdec` does that and owns the lock traffic.  It contains no arithmetic
-- beyond compares: 0 DSP and 0 RAMB36 by construction.
--
-- TIMING.  Designed for ~180 MHz, which is the measured post-route figure for
-- subsystem A at the card's real 0.717 V (172.6 MHz at ROWS_IF = 58, 179.7 at
-- the buildable 48) and not the 300 MHz the specs were written against.  No
-- state here holds two of {barrel shift, wide add, wide compare, bus mux,
-- multiply} in series: the deepest is V_RDA, which is one register-file read
-- (a bus mux) into a register, with the range compares done in a different
-- state from the read they qualify.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_vec_issue is
  generic(
    -- D-vec engines behind this one unit slot, in opcode order starting at
    -- OP_BASE: 0 = OP_VEC_NORM, 1 = OP_VEC_RES, 2 = OP_VEC_SWG.
    NVOP    : positive := 3;
    OP_BASE : natural  := 4;
    -- The unit index this adapter occupies on `seq_desc_fetch`'s bus.
    MY_UNIT : natural  := 4;
    NREG    : positive := 14;
    EXP_W   : positive := 16;
    -- Element-count width of the D-vec engines.  Narrower than the
    -- descriptor's 32-bit `n_rows` on purpose: a region-scoped count that does
    -- not fit is an error and not a silent truncation, which is the trap the
    -- first D pass hit at lm_head.
    VN_W    : positive := 13;
    EPOCH_W : positive := 4;
    STEP_W  : positive := 11;
    STRICT  : boolean  := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ============ LIVE JOB SHADOW, from seq_desc_fetch ==================
    -- Read ONLY in the cycle `job_issue` is high.  See defect class (a).
    job_issue   : in  std_logic;
    job_unit    : in  unsigned(2 downto 0);
    job_opcode  : in  unsigned(3 downto 0);
    job_epoch   : in  unsigned(EPOCH_W-1 downto 0);
    job_src     : in  unsigned(7 downto 0);
    job_src2    : in  unsigned(7 downto 0);
    job_dst     : in  unsigned(7 downto 0);
    job_dst_off : in  unsigned(31 downto 0);
    job_n_rows  : in  unsigned(31 downto 0);
    job_step    : in  unsigned(STEP_W-1 downto 0);
    -- The descriptor's word 4 [31:0].  On an OP_VEC_NORM it is the norm ROW
    -- (2*blk, 2*blk+1, 2*blocks for the final norm) that selects the gain
    -- vector; see `v_cb`.  Defaulted so benches of this unit alone need not
    -- drive it.  Added 2026-09-23 (plan Task 2).
    job_const_base : in unsigned(31 downto 0) := (others => '0');

    -- ============ THIS UNIT'S SLOT ON seq_desc_fetch's BUS ==============
    u_start      : in  std_logic;
    u_ack        : in  std_logic;
    u_ready      : out std_logic;
    u_done       : out std_logic;   -- LEVEL, held until `u_ack`
    u_err        : out std_logic;
    u_done_epoch : out unsigned(EPOCH_W-1 downto 0);
    -- The produced exponent, for `seq_opdec` to latch into the region lock.
    -- Valid from the first cycle `u_done` is high.  See defect class (c).
    u_y_exp      : out signed(EXP_W-1 downto 0);

    -- ============ EXPONENT READ PORT on seq_region_lock =================
    -- The only consumer of this port in the design.  Two reads per job, in
    -- two consecutive states, so the register-file mux is never in series
    -- with anything else.
    exp_rd_region : out unsigned(7 downto 0);
    exp_rd_seg    : out unsigned(1 downto 0);
    exp_rd_data   : in  signed(EXP_W-1 downto 0);
    exp_rd_valid  : in  std_logic;

    -- ==================== THE D-VEC ENGINES =============================
    -- One `start`/`ready`/`taken`/`done`/`ack`/`err` per engine and ONE shared
    -- parameter group, the same idiom as `seq_desc_fetch`'s own unit bus one
    -- level up.  Engine v's exponent is at (v+1)*EXP_W-1 downto v*EXP_W.
    v_start  : out std_logic_vector(NVOP-1 downto 0);
    v_ready  : in  std_logic_vector(NVOP-1 downto 0);
    v_taken  : in  std_logic_vector(NVOP-1 downto 0);
    v_done   : in  std_logic_vector(NVOP-1 downto 0);
    v_ack    : out std_logic_vector(NVOP-1 downto 0);
    v_err    : in  std_logic_vector(NVOP-1 downto 0);
    v_y_exp  : in  std_logic_vector(NVOP*EXP_W-1 downto 0);
    -- The job, by value.  Stable from the cycle `v_start` first rises until
    -- the completion is acknowledged.
    v_n      : out unsigned(VN_W-1 downto 0);
    v_exp_a  : out signed(EXP_W-1 downto 0);   -- exponent of `src`
    v_exp_b  : out signed(EXP_W-1 downto 0);   -- exponent of `src2`, 0 if none
    -- Region numbers for the region fabric's source and destination muxes.
    v_reg_a  : out unsigned(7 downto 0);
    v_reg_b  : out unsigned(7 downto 0);
    v_reg_d  : out unsigned(7 downto 0);
    -- The job's `const_base`, latched with the rest.  THE NORM GAIN IS
    -- SELECTED BY THIS, NOT BY COUNTING NORM OPS: a per-token counter is right
    -- only for a program that starts at step 0 (the two-card split, MEASURED
    -- 2026-09-23, docs/debugging/2026-09-23_the-norm-gain-is-indexed-by-a-
    -- per-token-counter.md).
    v_cb     : out unsigned(31 downto 0);

    -- ========================= OBSERVATION ==============================
    -- One cycle wide, at the instant the job shadow was copied.  The skeleton
    -- spec's normative rule: every value latched by a consumer needs an
    -- observable instant, or a testbench sampling at `done` cannot tell a
    -- correct latch from a lucky one.
    iss_lat  : out std_logic;
    -- One cycle wide, at the instant both source exponents were captured.
    exp_lat  : out std_logic;
    -- Why this unit raised `u_err`.  Sticky for the job.
    err_code : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of seq_vec_issue is

  -- Local error codes, reported on `err_code` alongside `u_err`.  The walker
  -- turns any `u_err` into ERR_UNIT with the failing step; this narrows it.
  constant EC_NONE   : std_logic_vector(3 downto 0) := x"0";
  constant EC_OPCODE : std_logic_vector(3 downto 0) := x"1"; -- not a D-vec op
  constant EC_NROWS  : std_logic_vector(3 downto 0) := x"2"; -- count out of range
  constant EC_SRC    : std_logic_vector(3 downto 0) := x"3"; -- src not a region
  constant EC_NOEXP  : std_logic_vector(3 downto 0) := x"4"; -- exponent never captured
  constant EC_OFF    : std_logic_vector(3 downto 0) := x"5"; -- non-zero dst offset
  constant EC_ENGINE : std_logic_vector(3 downto 0) := x"6"; -- the engine erred

  constant NO_REGION : unsigned(7 downto 0) := x"FF";

  type st_t is (V_IDLE, V_ARM, V_RDA, V_RDB, V_ISS, V_RUN, V_HOLD, V_FAIL);
  signal st : st_t := V_IDLE;

  -- ---- the job shadow.  Written at exactly one instant (class (a)) -------
  signal j_sel   : integer range 0 to NVOP-1 := 0;
  signal j_n     : unsigned(VN_W-1 downto 0) := (others => '0');
  signal j_ep    : unsigned(EPOCH_W-1 downto 0) := (others => '0');
  signal j_src   : unsigned(7 downto 0) := NO_REGION;
  signal j_src2  : unsigned(7 downto 0) := NO_REGION;
  signal j_dst   : unsigned(7 downto 0) := NO_REGION;
  signal j_cb    : unsigned(31 downto 0) := (others => '0');
  signal j_hasb  : std_logic := '0';
  -- Latched only so the STRICT reports below can NAME the step.  Not dead: an
  -- adapter that rejects a descriptor reports a code, and a code without a
  -- step index makes two different malformed steps indistinguishable in a
  -- 491-descriptor walk.  It synthesises away when STRICT is false.
  signal j_step  : unsigned(STEP_W-1 downto 0) := (others => '0');

  -- ---- the looked-up exponents ------------------------------------------
  signal e_a, e_b : signed(EXP_W-1 downto 0) := (others => '0');
  signal erd_r    : unsigned(7 downto 0) := (others => '0');

  -- ---- completion capture (class (b) and (c)) ----------------------------
  signal y_r    : signed(EXP_W-1 downto 0) := (others => '0');
  signal eerr   : std_logic := '0';
  signal ecode  : std_logic_vector(3 downto 0) := EC_NONE;

  signal lat_p  : std_logic := '0';
  signal exp_p  : std_logic := '0';
  signal strt   : std_logic_vector(NVOP-1 downto 0) := (others => '0');

  signal rdy_all : std_logic;

  -- Written as a function rather than as VHDL-2008's `and` reduction: this
  -- GHDL build rejects the unary form, and a reduction that has to be spelled
  -- out is one place rather than three that must agree.
  function all_ones(v : std_logic_vector) return std_logic is
    variable r : std_logic := '1';
  begin
    for i in v'range loop
      if v(i) /= '1' then r := '0'; end if;
    end loop;
    return r;
  end function;

begin

  assert MY_UNIT < 8
    report "seq_vec_issue: MY_UNIT must fit seq_desc_fetch's 3-bit job_unit"
    severity failure;

  -- Every engine idle, and nothing outstanding here.  See the header for why
  -- this is an AND over all NVOP rather than a select on the candidate opcode.
  rdy_all <= all_ones(v_ready);

  u_ready <= '1' when st = V_IDLE and rdy_all = '1' else '0';
  u_done  <= '1' when st = V_HOLD or st = V_FAIL else '0';
  u_err   <= eerr;
  u_done_epoch <= j_ep;
  u_y_exp <= y_r;

  exp_rd_region <= erd_r;
  exp_rd_seg    <= "00";

  v_start <= strt;
  v_n     <= j_n;
  v_exp_a <= e_a;
  v_exp_b <= e_b;
  v_reg_a <= j_src;
  v_reg_b <= j_src2;
  v_reg_d <= j_dst;
  v_cb    <= j_cb;

  gen_ack : for v in 0 to NVOP-1 generate
    v_ack(v) <= '1' when st = V_HOLD and v = j_sel and u_ack = '1' else '0';
  end generate;

  iss_lat  <= lat_p;
  exp_lat  <= exp_p;
  err_code <= ecode;

  main : process(clk) is
    variable op   : integer;
    variable sel  : integer;
    variable ok   : boolean;
    variable why  : std_logic_vector(3 downto 0);
  begin
    if rising_edge(clk) then
      lat_p <= '0';
      exp_p <= '0';

      if rst = '1' then
        st    <= V_IDLE;
        strt  <= (others => '0');
        eerr  <= '0';
        ecode <= EC_NONE;
        j_sel <= 0;
        j_n   <= (others => '0');
        j_cb  <= (others => '0');
        j_src <= NO_REGION;
        j_src2<= NO_REGION;
        j_dst <= NO_REGION;
        j_hasb<= '0';
        e_a   <= (others => '0');
        e_b   <= (others => '0');
        y_r   <= (others => '0');
        erd_r <= (others => '0');
      else
        case st is

          when V_IDLE =>
            -- The ACCEPT.  `u_start` is a level held by S_ISSUE until this
            -- unit's `ready` takes it, so the accept is the coincidence of the
            -- two and not the rising edge of either.
            if u_start = '1' and rdy_all = '1' then
              eerr  <= '0';
              ecode <= EC_NONE;
              st    <= V_ARM;
            end if;

          when V_ARM =>
            -- THE ONE INSTANT.  `job_issue` is one clocked state after the
            -- accept, because `live_bank` and `issue_r` move on the same edge
            -- inside `seq_desc_fetch`; before it, `job_*` still describes the
            -- PREVIOUS step.  Everything this job needs is copied here and no
            -- `job_*` port is read again.
            if job_issue = '1' then
              lat_p  <= '1';
              j_ep   <= job_epoch;
              j_step <= job_step;
              j_src  <= job_src;
              j_src2 <= job_src2;
              j_dst  <= job_dst;
              j_cb   <= job_const_base;
              erd_r  <= job_src;

              op  := to_integer(job_opcode);
              ok  := true;
              why := EC_NONE;
              sel := 0;
              if op >= OP_BASE and op < OP_BASE + NVOP then
                sel := op - OP_BASE;
              else
                ok := false; why := EC_OPCODE;
              end if;
              j_sel <= sel;

              -- The count.  A region-scoped element count that does not fit
              -- the engines' port is a table/gateware disagreement, and the
              -- lm_head lesson is that it must be an ERROR and not a resize:
              -- lm_head emits 248,320 rows and would truncate to a plausible
              -- 51,712.  Zero is an error too, not a no-op.
              if job_n_rows = 0 or job_n_rows >= 2**VN_W then
                if ok then ok := false; why := EC_NROWS; end if;
              end if;
              j_n <= resize(job_n_rows(VN_W-1 downto 0), VN_W);

              -- The sources.  A D-vec op always reads at least one region;
              -- `src2` is optional and its absence is spelled 0xFF.
              if job_src >= NREG then
                if ok then ok := false; why := EC_SRC; end if;
              end if;
              if job_src2 = NO_REGION then
                j_hasb <= '0';
              elsif job_src2 >= NREG then
                j_hasb <= '0';
                if ok then ok := false; why := EC_SRC; end if;
              else
                j_hasb <= '1';
              end if;

              -- The D-vec engines write a region from element 0.  A non-zero
              -- destination offset would mean an APPEND, which the two-pass
              -- renormalise cannot do: the output exponent is a property of
              -- the whole region and an append would re-scale what is already
              -- there.  `seq_opdec` already forces offset 0 for an IN-PLACE
              -- step; this covers the out-of-place D-vec ops as well.
              if job_dst /= NO_REGION and job_dst_off /= 0 then
                if ok then ok := false; why := EC_OFF; end if;
              end if;

              if ok then
                st <= V_RDA;
              else
                eerr  <= '1';
                ecode <= why;
                y_r   <= (others => '0');
                st    <= V_FAIL;
              end if;
            end if;

          when V_RDA =>
            -- One register-file read, into a register.  `exp_rd_valid` means
            -- the slot has been WRITTEN since the last lock reset, and it is
            -- the check that separates "the host published X" from "region X
            -- has never been produced and 0 is a plausible exponent".
            e_a   <= exp_rd_data;
            erd_r <= j_src2;
            if exp_rd_valid = '0' then
              eerr  <= '1';
              ecode <= EC_NOEXP;
              st    <= V_FAIL;
            else
              st <= V_RDB;
            end if;

          when V_RDB =>
            exp_p <= '1';
            if j_hasb = '1' then
              e_b <= exp_rd_data;
              if exp_rd_valid = '0' then
                eerr  <= '1';
                ecode <= EC_NOEXP;
                st    <= V_FAIL;
              else
                strt(j_sel) <= '1';
                st          <= V_ISS;
              end if;
            else
              e_b         <= (others => '0');
              strt(j_sel) <= '1';
              st          <= V_ISS;
            end if;

          when V_ISS =>
            -- `start` is a LEVEL held until the engine takes it, never a
            -- pulse at an engine that is not listening.
            if v_taken(j_sel) = '1' then
              strt <= (others => '0');
              st   <= V_RUN;
            end if;

          when V_RUN =>
            -- The completion is captured the FIRST cycle it is observed, in
            -- an unconditional branch, together with its payload.  A raw
            -- sample taken later would depend on the engine's hold time.
            if v_done(j_sel) = '1' then
              y_r   <= signed(v_y_exp((j_sel+1)*EXP_W-1 downto j_sel*EXP_W));
              if v_err(j_sel) = '1' then
                eerr  <= '1';
                ecode <= EC_ENGINE;
              end if;
              st <= V_HOLD;
            end if;

          when V_HOLD =>
            -- No default clear anywhere in this process; the state leaves
            -- V_HOLD only here.  See defect class (b) in the header.
            if u_ack = '1' then
              st <= V_IDLE;
            end if;

          when V_FAIL =>
            if u_ack = '1' then
              st <= V_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Simulation-only assertions.  A generic and not unconditional, because the
  -- testbench drives malformed steps on purpose to check they are caught.
  -- ======================================================================
  strict_chk : process(clk) is
  begin
    if rising_edge(clk) and rst = '0' and STRICT then
      assert not (job_issue = '1' and to_integer(job_unit) = MY_UNIT
                  and st /= V_ARM)
        report "seq_vec_issue: a job was issued to this unit while the adapter "
             & "was not waiting for one.  The broadcast shadow and the start "
             & "handshake have come apart and the job shadow just latched "
             & "belongs to a step this unit never accepted."
        severity warning;
      assert not (st = V_ARM and job_issue = '1'
                  and to_integer(job_unit) /= MY_UNIT)
        report "seq_vec_issue: this adapter accepted a start but the issued "
             & "job names a different unit."
        severity warning;
      assert not (u_start = '1' and st /= V_IDLE)
        report "seq_vec_issue: a start arrived while a job was outstanding."
        severity warning;
      assert not (st = V_RUN and v_done(j_sel) = '1' and v_ready(j_sel) = '1')
        report "seq_vec_issue: at step " & integer'image(to_integer(j_step))
             & ", an engine is asserting ready while still holding a "
             & "completion this unit has not acknowledged."
        severity warning;
      assert not (st = V_FAIL and eerr = '0')
        report "seq_vec_issue: at step " & integer'image(to_integer(j_step))
             & ", the failure state was entered without an error being "
             & "latched, so the walker would see a clean completion for a "
             & "step this unit refused."
        severity warning;
    end if;
  end process;

end architecture;
