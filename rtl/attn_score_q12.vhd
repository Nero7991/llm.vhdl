-- rtl/attn_score_q12.vhd
-- Subsystem C, steps 5b and 6: align one query head's per-block partial dot
-- products onto a common grid, sum them, and convert the result to Q12 at the
-- point of production.
--
--   e_min     = min over b of e_k[b]
--   score     = sum over b of ( partial[b] asr (e_k[b] - e_min) )
--   score_exp = q_exp + e_min + KQ_SHIFT             kq_scale = 2^-KQ_SHIFT
--   sh        = score_exp - QOUT
--   score_q12 = round_shift(score, sh)               when sh >= 0
--             = sat32( score sll (-sh) )             when sh <  0
--
-- Bit-exact against ref/attn_score_q12_vec.c, which is itself checked against
-- three double-precision oracles that share none of its fixed-point machinery.
--
-- WHY THE CONVERSION IS HERE, which is the reason this is a unit at all.
-- score_exp contains e_min, and e_min is the minimum over the blocks of ONE
-- cached position, so it changes from position to position.  Raw scores from
-- different positions therefore sit on different grids and are NOT comparable;
-- they cannot feed the online softmax's running maximum.  Converting at the
-- point of production is what makes them comparable, and doing it later is
-- not an optimisation choice, it is wrong.
--
-- WHY IT PAIRS WITH attn_kv_quant.  `e_k` is exactly the header that unit
-- emits, and it is emitted BEFORE any mantissa precisely so this unit can know
-- e_min before the first partial arrives.  Header-first is not a layout
-- convenience: it is what lets the alignment run on the fly with no buffer for
-- the partials, which matters because the partial stream CANNOT BE STALLED
-- (see the back-pressure table below).
--
-- BOTH BRANCHES OF STEP 6 ARE REACHABLE, and this is the single easiest thing
-- in the unit to get wrong.  q_exp comes out of the QK-norm, whose shift_total
-- is data-dependent and not derivable from any interface port, so sh is
-- unbounded in both directions.  A unit that implements only the right shift
-- produces plausible numbers on plausible data and is wrong exactly when the
-- scores are small.  The vector file forces both.
--
-- WHY KQ_SHIFT IS 4.  kq_scale = 1/sqrt(head_dim) and head_dim is 256 in BOTH
-- target models (rtl/model_cfg_pkg.vhd: attn_head_dim = 256 for QWEN35_9B and
-- QWEN38_27B alike), so the scale is 2^-4 exactly and folds into the exponent
-- with NO multiply.  That is a property of this head_dim and not a general
-- one; a head_dim that is not an even power of two makes kq_scale irrational
-- and forces a real multiply.  It is a generic so the assumption is visible.
--
-- THE LEFT-SHIFT CLAMP IS EXACT, not an approximation, and that is what lets
-- this be a 32-step barrel shifter instead of a 63-step one.  |score| < 2^31,
-- so a left shift of LSH_CLAMP = 32 already carries any non-zero score past
-- 2^31 and saturates, and a larger shift saturates to the same value with the
-- same sign; a zero score gives zero at every shift.  So clamping changes no
-- output.  The C reference's oracle 2 recomputes step 6 with the TRUE shift
-- and would catch it if that were wrong -- and it did catch a clamp of 16,
-- which is NOT exact.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   hdr_valid / e_k / hdr_taken   RULE 2.  The header is latched at a named
--                                 instant and hdr_taken makes that instant
--                                 observable.  The producer (attn_kv_quant, or
--                                 the AXI read master replaying a record) can
--                                 be stalled: this unit simply does not accept
--                                 a header until it is idle.
--
--   p_valid / p_data / p_ready    THE PRODUCER CANNOT BE STALLED.  The score
--   (the partial stream)          tree is driven by the AXI beat rate on a
--                                 fixed 16-cycle position slot and cannot
--                                 pause mid-slot without desynchronising from
--                                 the K stream.  So p_ready is an OUTPUT that
--                                 must never fall while partials are in
--                                 flight, and this unit is built so that it
--                                 does not: the alignment shift is known
--                                 before the first partial arrives (that is
--                                 what header-first buys), and the accumulate
--                                 is a fixed 3-stage pipeline with no
--                                 feedback into the input.  Service time is
--                                 1 partial per cycle, unconditionally.
--                                 STRICT_PRODUCER asserts p_valid never
--                                 arrives while p_ready is low, which converts
--                                 the failure from silent loss into a loud
--                                 simulation failure.  This is exactly the
--                                 gdn_recur_pipe shape: `o_res_valid`
--                                 free-runs there, so a consumer whose ready
--                                 falls under it LOSES data rather than
--                                 delaying it.
--
--   s_valid / s_q12 / s_ready     Producer (this unit) IS stallable, held
--   (the score, to the softmax)   until s_ready.  What bounds the consumer's
--                                 service time is the sweep schedule: one
--                                 score is produced per (query head, position)
--                                 and the exp cone takes it in one cycle, so
--                                 the budget is the 8-cycle score phase.  If
--                                 a second score completes while the first is
--                                 unaccepted, that is an OVERRUN, and it is
--                                 reported on `ovr` rather than silently
--                                 dropping either.  A zero back-pressure count
--                                 is a question, not a result: the lossy path
--                                 scores BETTER on the obvious metric, which
--                                 is what the 2026-08-27 COL_GAP=3 result
--                                 showed when a bug FIX made 167 refused
--                                 columns appear.
--
--   done / done_ack               RULE 1.  Held until acked, never pulsed.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.
--
--   S_EMIN    one narrow compare per cycle over the NBLK header exponents,
--             or HDR_TREE levels of a balanced min tree per cycle
--   S_SHIFTS  one narrow subtract per cycle, e_k[b] - e_min, precomputed so
--             the accumulate pipeline never has a subtract feeding a shift,
--             or all NBLK of them in one cycle when HDR_TREE > 0
--   S_ACC     capture and mux the shift | barrel shift | wide add
--   S_EXP1/2  q_exp + e_min, then + KQ_SHIFT, two narrow adds not one
--   S_SH      sh = score_exp - QOUT, and the branch decision
--   S_Q1      the round bias (a shift) OR the left shift, never both in series
--   S_Q2      the right shift OR the saturate
--
-- Precomputing the per-block shift in S_SHIFTS is what makes p_ready
-- unconditional: without it the accumulate stage would need e_k[b] - e_min
-- and the shift in the same cycle a partial arrives.
--
-- NO DSP.  Shifts, compares, narrow adds and one mux.  The C DSP skeleton
-- books the score alignment and adder trees at 0 "by construction"; this file
-- is what makes that true rather than assumed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;              -- clog2

entity attn_score_q12 is
  generic(
    -- HEAD_DIM / KV_BLOCK = 256 / 32 in both target models.
    NBLK     : positive := 8;
    P_W      : positive := 32;      -- partial dot product width
    EXP_W    : positive := 8;
    -- log2(sqrt(head_dim)).  4 for head_dim 256, which is both models.  See
    -- the header: this is exact only because 256 is an even power of two.
    KQ_SHIFT : natural  := 4;
    -- The Q of the softmax's input grid, C spec step 6.
    QOUT     : natural  := 12;
    -- Derived and exact; see the header.  Not tuning knobs.
    --   LSH_CLAMP  any left shift past this saturates a non-zero score and
    --              leaves a zero score at zero, so clamping changes no output.
    --   RSH_CLAMP  round_shift(score, s) is 0 for EVERY s >= P_W when
    --              |score| <= 2^(P_W-1): score/2^s lands in (-0.5, 0.5], the
    --              round bias moves it into (0, 1] and the floor is 0.  So
    --              clamping the right shift changes no output either, and it
    --              is what keeps the round bias inside ACC_W instead of
    --              needing 2^63.  Both verified numerically over the whole
    --              range, not argued only.
    LSH_CLAMP : positive := 32;
    RSH_CLAMP : positive := 32;
    -- ==================================================================
    -- HDR_TREE -- how many levels of the e_min COMPARISON TREE are folded
    -- per cycle.  0 selects the legacy one-compare-per-cycle scan and is
    -- the default, so every existing instantiation keeps the schedule it
    -- has cycle for cycle.
    --
    -- WHY IT EXISTS, MEASURED.  sim/tb_csweep_rate.vhd 2026-09-20 at the
    -- real 9B geometry: P_SCORE is 23.00 cycles per position per KV head
    -- of which 14.00 are spent with `ar_prdy` LOW, and those 14 are this
    -- unit's header pass.  S_EMIN below is NBLK-1 narrow compares one per
    -- cycle and S_SHIFTS is NBLK narrow subtracts one per cycle; with
    -- the S_IDLE latch that is 2*NBLK = 16 cycles at NBLK = 8 before
    -- p_ready can rise.  The sweep has nothing to do for any of them.
    --
    -- NEITHER PASS IS SERIAL BY NECESSITY, AND THEY ARE SERIAL FOR TWO
    -- DIFFERENT REASONS.
    --   S_EMIN    is a REDUCTION with a genuine loop-carried dependency
    --             AS WRITTEN (`e_min` feeds the next compare), but min is
    --             associative and commutative, so the dependency is a
    --             property of the spelling and not of the function.  A
    --             balanced tree computes the same value in clog2(NBLK)
    --             levels.
    --   S_SHIFTS  has NO dependency at all.  `e_l(b) - e_min` for
    --             different b share only e_min, which is already fixed
    --             when the state is entered.  It is simply a loop written
    --             serially, and every iteration can run in one cycle.
    -- Neither is a shared-comparator or shared-subtractor argument: both
    -- operands are EXP_W = 8 bits wide, so a whole level is NBLK/2 8-bit
    -- compares, and the whole shift pass is NBLK 8-bit subtracts.
    --
    -- WHAT IT COSTS, AND WHY IT IS A DIAL RATHER THAN A SWITCH.  Every
    -- level folded in one cycle is one more 8-bit compare plus mux in
    -- series inside that cycle.  Cycles go as
    --     1 (S_IDLE latch) + ceil(clog2(NBLK)/HDR_TREE) + 1 (S_SHIFTS)
    -- against the legacy 2*NBLK, so at NBLK = 8:
    --     HDR_TREE = 0 -> 16 cycles, combinational depth 1 compare
    --     HDR_TREE = 1 ->  5 cycles, depth 1 compare  (3 tree cycles)
    --     HDR_TREE = 2 ->  4 cycles, depth 2 compares
    --     HDR_TREE = 3 ->  3 cycles, depth 3 compares
    -- HDR_TREE = 1 buys 11 of the 13 available cycles at NO increase in
    -- combinational depth over the legacy scan, which is why it is the
    -- value to set on a design with 0.061 ns of slack.  Going past it
    -- trades a hard timing risk for 1 or 2 cycles.
    --
    -- The project's stage rule is respected in both modes: the tree's
    -- compares and the subtracts are in SEPARATE cycles, so a subtract
    -- never feeds a compare or a barrel shift within one stage, and
    -- p_ready is still raised at the END of S_SHIFTS.
    HDR_TREE : natural := 0;
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the record header, plus this query head's norm exponent ---------
    -- RULE 2: both are latched on accept and hdr_taken marks the instant.
    hdr_valid : in  std_logic;
    e_k       : in  std_logic_vector(NBLK*EXP_W-1 downto 0);
    q_exp     : in  signed(EXP_W-1 downto 0);
    hdr_taken : out std_logic;
    busy      : out std_logic;

    -- ---- the partial stream.  p_ready must never fall; see the header. ---
    p_valid : in  std_logic;
    p_data  : in  signed(P_W-1 downto 0);
    p_ready : out std_logic;

    -- ---- the score, on the Q12 grid the online softmax compares on -------
    s_valid : out std_logic;
    s_q12   : out signed(P_W-1 downto 0);
    -- Reported for observability, not consumed by the softmax: the whole
    -- point of the Q12 conversion is that the grid is now CONSTANT, so a
    -- consumer that reads this exponent has misunderstood the interface.
    s_exp   : out signed(EXP_W-1 downto 0);
    s_sat   : out std_logic;
    s_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked. -------------------------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at the next header accept.
    --   ovr : a score completed while the previous one was still unaccepted.
    --   err : the aligned sum left s32, i.e. the |partial| < 2^27 premise the
    --         width argument rests on was violated by the producer.
    ovr : out std_logic;
    err : out std_logic
  );
end entity;

architecture rtl of attn_score_q12 is

  constant SHW : integer := clog2(64);            -- shift counts, clamped 0..63
  -- One bit wider than the partial, so the NBLK-term sum has room before the
  -- s32 check.  |partial| < 2^27 and NBLK = 8 gives |sum| < 2^30, so P_W
  -- itself would do; the extra bit makes the OVERFLOW OBSERVABLE instead of
  -- wrapping, which is the difference between an err flag and a silent lie.
  constant ACC_W : integer := P_W + 2;
  -- The left-shift path operates on the SATURATED s32 score, not on the wider
  -- accumulator, so |value| <= 2^(P_W-1) and P_W + LSH_CLAMP bits hold the
  -- shifted result exactly: -2^31 shifted left by 32 is -2^63, which is
  -- precisely the bottom of signed 64.  Shifting the un-saturated ACC_W
  -- accumulator instead would need P_W + LSH_CLAMP + 2 bits and would be
  -- shifting a value the contract says cannot exist.
  constant LSW : integer := P_W + LSH_CLAMP;

  -- Built by shifting rather than by an aggregate with a generic-indexed
  -- choice: `(P_W-1 => '0', others => '1')` is rejected as a non-locally
  -- static choice alongside `others`.
  constant P_MIN : signed(P_W-1 downto 0)
    := shift_left(to_signed(-1, P_W), P_W-1);      -- 100...0 = -2^(P_W-1)
  constant P_MAX : signed(P_W-1 downto 0) := not P_MIN;  -- 011...1

  function sat_p(v : signed) return signed is
  begin
    if    v > resize(P_MAX, v'length) then return P_MAX;
    elsif v < resize(P_MIN, v'length) then return P_MIN;
    else  return resize(v, P_W);
    end if;
  end function;

  type state_t is (S_IDLE, S_EMIN, S_SHIFTS, S_ACC, S_EXP1, S_EXP2, S_SH,
                   S_Q1, S_Q2, S_DONE);
  signal state : state_t := S_IDLE;

  type e_arr_t  is array (0 to NBLK-1) of signed(EXP_W-1 downto 0);
  type sh_arr_t is array (0 to NBLK-1) of unsigned(SHW-1 downto 0);
  signal e_l   : e_arr_t  := (others => (others => '0'));
  signal shb   : sh_arr_t := (others => (others => '0'));
  signal q_l   : signed(EXP_W-1 downto 0) := (others => '0');
  signal e_min : signed(EXP_W-1 downto 0) := (others => '0');

  signal blk : integer range 0 to NBLK-1 := 0;
  signal got : integer range 0 to NBLK-1 := 0;   -- partials accepted

  -- ---- HDR_TREE > 0 only.  Inert, and trimmed, when HDR_TREE = 0. ------
  -- The working set of the comparison tree.  LEVEL 0 IS `e_l` ITSELF, so
  -- this array only ever has to hold the result of the FIRST fold and
  -- everything after it: ceil(NBLK/2) entries, not NBLK.  At NBLK = 8 that
  -- is 4 x EXP_W = 32 flip-flops per unit rather than 64.
  constant TW : integer := (NBLK + 1) / 2;
  type t_arr_t is array (0 to TW-1) of signed(EXP_W-1 downto 0);
  signal tv  : t_arr_t := (others => (others => '0'));
  -- Live entries in the array the NEXT fold reads.  It starts at NBLK
  -- because that first read is of `e_l`.
  signal tn  : integer range 0 to NBLK := 0;
  -- '1' while the source of the next fold is still `e_l`.
  signal tl0 : std_logic := '0';

  -- accumulate pipeline
  signal c1_v, c2_v : std_logic := '0';
  signal c1_p  : signed(P_W-1 downto 0) := (others => '0');
  signal c1_sh : unsigned(SHW-1 downto 0) := (others => '0');
  signal c2_al : signed(ACC_W-1 downto 0) := (others => '0');
  signal acc   : signed(ACC_W-1 downto 0) := (others => '0');
  signal nsum  : integer range 0 to NBLK := 0;   -- terms folded into acc

  -- exponent and conversion
  signal sexp  : signed(EXP_W+2 downto 0) := (others => '0');
  -- The aligned sum, saturated to the s32 the interface declares.  In legal
  -- operation the saturate is a no-op (|sum| < 2^30 by the |partial| < 2^27
  -- premise); it exists so that a producer that violates that premise gets a
  -- clipped value AND an err flag rather than a wrapped one.
  signal score : signed(P_W-1 downto 0) := (others => '0');
  signal rsh   : unsigned(SHW-1 downto 0) := (others => '0');
  signal lsh   : unsigned(SHW-1 downto 0) := (others => '0');
  signal is_left : std_logic := '0';
  signal q1_r  : signed(ACC_W-1 downto 0) := (others => '0');  -- score + bias
  signal q1_l  : signed(LSW-1 downto 0)   := (others => '0');  -- score sll lsh

  signal s_valid_r : std_logic := '0';
  signal s_q12_r   : signed(P_W-1 downto 0) := (others => '0');
  signal s_sat_r   : std_logic := '0';
  signal done_r    : std_logic := '0';
  signal hdr_tk    : std_logic := '0';
  signal ovr_r     : std_logic := '0';
  signal err_r     : std_logic := '0';
  signal p_rdy     : std_logic := '0';

begin

  -- UNCONDITIONAL while partials are expected.  It is an output the producer
  -- is documented not to have to obey, so it must never be a function of
  -- anything downstream; if it ever became one, the score tree would drop a
  -- partial rather than delay it and nothing would report the loss.
  p_ready   <= p_rdy;
  hdr_taken <= hdr_tk;
  busy      <= '0' when state = S_IDLE else '1';
  s_valid   <= s_valid_r;
  s_q12     <= s_q12_r;
  s_exp     <= to_signed(QOUT, EXP_W);
  s_sat     <= s_sat_r;
  done      <= done_r;
  ovr       <= ovr_r;
  err       <= err_r;

  process(clk)
    variable sv   : integer;
    -- HDR_TREE only.  `wv` is a WIRE bundle, not storage: it is written and
    -- read within one evaluation of this process and never read before it is
    -- written in that evaluation.  It is NBLK wide because the first fold
    -- reads `e_l`, which is.
    variable wv   : e_arr_t;
    variable wn   : integer range 0 to NBLK;
    variable nn   : integer range 0 to NBLK;
    variable ext  : signed(ACC_W-1 downto 0);
    variable bias : signed(ACC_W-1 downto 0);
    variable rndv : signed(ACC_W-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; blk <= 0; got <= 0; nsum <= 0;
        c1_v <= '0'; c2_v <= '0';
        acc <= (others => '0');
        s_valid_r <= '0'; s_sat_r <= '0'; done_r <= '0';
        hdr_tk <= '0'; ovr_r <= '0'; err_r <= '0'; p_rdy <= '0';
      else
        hdr_tk <= '0';

        -- The consumer handshake is independent of the FSM: once a score is
        -- driven it stands until s_ready, whatever the unit is doing next.
        if s_valid_r = '1' and s_ready = '1' then
          s_valid_r <= '0';
        end if;

        if STRICT_PRODUCER then
          -- The whole point of p_ready being unconditional.  If this ever
          -- fires, the score tree has offered a partial this unit cannot take,
          -- and since the tree has no ready input that partial is LOST, not
          -- delayed.  It is invisible to a value check on any other vector.
          assert not (p_valid = '1' and p_rdy = '0')
            report "attn_score_q12: a partial was offered while p_ready was "
                 & "low.  The score tree cannot be stalled, so this partial "
                 & "is lost, not delayed."
            severity error;
        end if;

        case state is

          -- ================= latch the header.  RULE 2. ==================
          when S_IDLE =>
            if hdr_valid = '1' then
              for b in 0 to NBLK-1 loop
                e_l(b) <= signed(e_k((b+1)*EXP_W-1 downto b*EXP_W));
              end loop;
              q_l    <= q_exp;
              hdr_tk <= '1';
              -- Seeded from block 0's exponent rather than a sentinel, so no
              -- exponent is unrepresentable.  A sentinel of 0 would be wrong
              -- for an all-positive header, which is the common case.
              e_min  <= signed(e_k(EXP_W-1 downto 0));
              blk    <= 1;
              -- HDR_TREE.  The first fold reads `e_l`, which is being
              -- latched in this very cycle and is therefore readable in the
              -- next one -- the same relationship the legacy scan relies on.
              tn     <= NBLK;
              tl0    <= '1';
              got    <= 0;
              nsum   <= 0;
              acc    <= (others => '0');
              c1_v <= '0'; c2_v <= '0';
              s_sat_r <= '0'; ovr_r <= '0'; err_r <= '0';
              state  <= S_EMIN;
            end if;

          -- ---- one narrow compare per cycle, or HDR_TREE of them --------
          when S_EMIN =>
            if HDR_TREE = 0 then
              if e_l(blk) < e_min then
                e_min <= e_l(blk);
              end if;
              if blk = NBLK-1 then
                blk   <= 0;
                state <= S_SHIFTS;
              else
                blk <= blk + 1;
              end if;
            else
              -- Load this cycle's source.  Level 0 is `e_l`; every later
              -- level is the previous cycle's partial minima.
              --
              -- EVERY ENTRY IS ASSIGNED ON EVERY PATH, INCLUDING THE ONES
              -- THAT ARE NEVER READ.  `wv` is a process variable inside a
              -- clocked process, so an entry left unassigned on some path
              -- is read-before-write and INFERS A REGISTER -- NBLK-TW of
              -- them, feeding muxes that can never select them.  It would
              -- simulate identically and cost flip-flops in the build, and
              -- this project's own rule is that the inference log is not
              -- the place to find out.  `tv(0)` is a filler, not a value:
              -- indices TW..NBLK-1 are unreachable once tl0 is '0' because
              -- wn is then at most TW.
              for i in 0 to NBLK-1 loop
                if tl0 = '1' then
                  wv(i) := e_l(i);
                elsif i < TW then
                  wv(i) := tv(i);
                else
                  wv(i) := tv(0);
                end if;
              end loop;
              if tl0 = '1' then wn := NBLK; else wn := tn; end if;

              -- Fold HDR_TREE levels.  IN PLACE IS SAFE HERE and it is worth
              -- saying why rather than leaving it to be re-derived: level
              -- entry i writes index i and reads indices 2i and 2i+1.  For
              -- i >= 1 both are strictly greater than i, so they are read
              -- before the iteration that writes them; for i = 0 the read of
              -- wv(0) and wv(1) is on the right-hand side of the assignment
              -- that writes wv(0), and VHDL variable assignment is sequential.
              for lv in 1 to HDR_TREE loop
                if wn > 1 then
                  nn := (wn + 1) / 2;
                  for i in 0 to NBLK-1 loop
                    if i < nn then
                      if 2*i + 1 <= wn - 1 then
                        -- STRICTLY LESS, matching the legacy scan's `<`, so
                        -- ties keep the earlier block.  min is associative
                        -- and commutative so the tree's answer is the scan's
                        -- answer whatever the tie rule; the rule is pinned
                        -- anyway because it is the kind of thing a mutant
                        -- flips and nothing else would notice.
                        if wv(2*i + 1) < wv(2*i) then
                          wv(i) := wv(2*i + 1);
                        else
                          wv(i) := wv(2*i);
                        end if;
                      else
                        -- ODD LEVEL: the last entry has no partner and is
                        -- carried forward unchanged.  UNREACHABLE at any
                        -- power-of-two NBLK, which is every geometry this
                        -- design is built at; see the teeth table in
                        -- docs/debugging/2026-09-20_the-score-header-pass.md,
                        -- where it is exercised by running this unit at
                        -- NBLK = 5 and 7 rather than argued to be correct.
                        wv(i) := wv(2*i);
                      end if;
                    end if;
                  end loop;
                  wn := nn;
                end if;
              end loop;

              if wn = 1 then
                e_min <= wv(0);
                blk   <= 0;
                state <= S_SHIFTS;
              else
                for i in 0 to TW-1 loop tv(i) <= wv(i); end loop;
                tn  <= wn;
                tl0 <= '0';
              end if;
            end if;

          -- ---- one narrow subtract per cycle, or all NBLK in one --------
          -- Precomputed so the accumulate stage never has a subtract feeding
          -- a barrel shift, which is what keeps p_ready unconditional.  That
          -- argument requires the shifts to EXIST before the first partial;
          -- it never required them to arrive one per cycle, which is why
          -- HDR_TREE can do them all at once without weakening it.
          when S_SHIFTS =>
            if HDR_TREE = 0 then
              sv := to_integer(e_l(blk)) - to_integer(e_min);
              -- e_min is the minimum, so sv >= 0 by construction.  The clamp
              -- is the project's shift convention and it also stops a
              -- corrupted header from producing a LEFT shift here, which
              -- would overflow the accumulator silently.
              if sv < 0 then sv := 0; elsif sv > 63 then sv := 63; end if;
              shb(blk) <= to_unsigned(sv, SHW);
              if blk = NBLK-1 then
                blk   <= 0;
                p_rdy <= '1';        -- ready BEFORE the first partial can come
                state <= S_ACC;
              else
                blk <= blk + 1;
              end if;
            else
              -- The SAME NBLK subtracts, all in one cycle.  They were never
              -- serial for any reason but the spelling: they share only
              -- `e_min`, which is fixed before this state is entered.  The
              -- clamp is character for character the one above.
              for b in 0 to NBLK-1 loop
                sv := to_integer(e_l(b)) - to_integer(e_min);
                if sv < 0 then sv := 0; elsif sv > 63 then sv := 63; end if;
                shb(b) <= to_unsigned(sv, SHW);
              end loop;
              blk   <= 0;
              p_rdy <= '1';
              state <= S_ACC;
            end if;

          -- ================= align and accumulate ========================
          when S_ACC =>
            -- stage 1: capture, and the NBLK-way shift mux ALONE
            c1_v <= '0';
            if p_valid = '1' and p_rdy = '1' then
              c1_v  <= '1';
              c1_p  <= p_data;
              c1_sh <= shb(got);
              if got = NBLK-1 then
                got   <= 0;
                p_rdy <= '0';        -- exactly NBLK partials, then closed
              else
                got <= got + 1;
              end if;
            end if;

            -- stage 2: the barrel shift ALONE.  Arithmetic right, i.e. FLOOR.
            -- Rounding here would double-round against the Q12 conversion.
            c2_v <= c1_v;
            if c1_v = '1' then
              c2_al <= shift_right(resize(c1_p, ACC_W), to_integer(c1_sh));
            end if;

            -- stage 3: the wide add ALONE
            if c2_v = '1' then
              acc  <= acc + c2_al;
              nsum <= nsum + 1;
            end if;

            if nsum = NBLK then
              -- The premise the s32 declaration rests on: |partial| < 2^27 and
              -- NBLK = 8 gives |sum| < 2^30.  ACC_W is two bits wider than
              -- P_W so a violation is VISIBLE here instead of wrapping.
              if acc > resize(P_MAX, ACC_W) or acc < resize(P_MIN, ACC_W) then
                err_r <= '1';
              end if;
              state <= S_EXP1;
            end if;

          -- ---- score_exp = q_exp + e_min + KQ_SHIFT, two narrow adds ----
          when S_EXP1 =>
            -- Two INDEPENDENT operations, not two in series: the exponent add
            -- and the score saturate share no operand.
            sexp  <= resize(q_l, EXP_W+3) + resize(e_min, EXP_W+3);
            score <= sat_p(acc);
            state <= S_EXP2;

          when S_EXP2 =>
            sexp  <= sexp + to_signed(KQ_SHIFT, EXP_W+3);
            state <= S_SH;

          -- ---- sh = score_exp - QOUT, and the branch decision -----------
          when S_SH =>
            if sexp < to_signed(QOUT, EXP_W+3) then
              is_left <= '1';
              sv := QOUT - to_integer(sexp);
              -- EXACT, not an approximation.  See the header: any shift past
              -- LSH_CLAMP saturates a non-zero score and leaves a zero score
              -- at zero, so clamping changes no output.
              if sv > LSH_CLAMP then sv := LSH_CLAMP; end if;
              lsh <= to_unsigned(sv, SHW);
            else
              is_left <= '0';
              sv := to_integer(sexp) - QOUT;
              -- EXACT; see the RSH_CLAMP note on the generic.
              if sv > RSH_CLAMP then sv := RSH_CLAMP; end if;
              rsh <= to_unsigned(sv, SHW);
            end if;
            state <= S_Q1;

          -- ---- one shift, on whichever branch was chosen ----------------
          when S_Q1 =>
            if is_left = '1' then
              q1_l <= shift_left(resize(score, LSW), to_integer(lsh));
            else
              -- round_shift(v, s) = floor_shr(v + 2^(s-1), s), i.e. round half
              -- toward plus infinity.  At s = 0 the bias is zero and the shift
              -- is a no-op, which is what makes round_shift(v, 0) = v exactly.
              if rsh = 0 then
                bias := (others => '0');
              else
                bias := shift_left(to_signed(1, ACC_W), to_integer(rsh) - 1);
              end if;
              q1_r <= resize(score, ACC_W) + bias;
            end if;
            state <= S_Q2;

          -- ---- the second operation, and drive --------------------------
          when S_Q2 =>
            -- An overrun is a LOSS, so it is recorded rather than allowed to
            -- pass as a stall: this unit's producer cannot be stalled, so it
            -- cannot itself wait indefinitely without desynchronising.
            if s_valid_r = '1' and s_ready = '0' then
              ovr_r <= '1';
            end if;
            if is_left = '1' then
              s_q12_r <= sat_p(q1_l);
              if q1_l /= resize(sat_p(q1_l), LSW) then
                s_sat_r <= '1';
              end if;
            else
              rndv := shift_right(q1_r, to_integer(rsh));
              s_q12_r <= sat_p(rndv);
              if rndv /= resize(sat_p(rndv), ACC_W) then
                s_sat_r <= '1';
              end if;
            end if;
            s_valid_r <= '1';
            state <= S_DONE;

          -- ================= RULE 1: held, not pulsed ====================
          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then
              -- Do NOT clear done_r here; the trailing assignment below does
              -- it once the state leaves S_DONE.  An explicit clear inside
              -- this branch is a LATER assignment that wins, which destroys
              -- the pulse whenever done_ack is tied high -- the default a
              -- testbench uses.  Written and caught once in gdn_head_emit.
              state <= S_IDLE;
            end if;

        end case;

        if state /= S_DONE then
          done_r <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture;
