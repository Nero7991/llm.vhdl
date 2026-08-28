-- rtl/seq_vec_res.vhd
-- Subsystem D, D-vec: the RESIDUAL ACCUMULATE (descriptor opcode OP_VEC_RES).
-- REAL RTL.  Bit-exact against ref/seq_vec_res_vec.c, which carries six
-- oracles and shares no arithmetic with this file.
--
-- WHAT IT DOES.  Two block-floating-point vectors -- the residual stream X and
-- the mixer/FFN result ER, each `n` int16 mantissas with ONE shared exponent --
-- are added, and the sum is written back as a block-floating-point vector with
-- a NEW shared exponent:
--
--     out[i] * 2^-oexp  ~=  x[i] * 2^-ex  +  e[i] * 2^-ee
--
-- The exponent is a COUNT OF FRACTIONAL BITS, so a larger exponent is a finer
-- scale.  Same convention as rtl/bfp_pack.vhd (`o_exp = Q - shift`); getting it
-- backwards inverts the alignment silently.
--
-- WHY THIS OP, AND WHY FIRST.  It is executed 128 times per token -- twice per
-- block, post-mixer and post-FFN, for all 32 blocks of the 9B target and all 64
-- of the 27B -- against 129 norms and 64 swiglus, and it is the step that CLOSES
-- the residual exponent chain that every subsequent norm reads.  It is also the
-- only D-vec op whose numeric contract is fixed by the block-float rules alone,
-- with no transcendental recipe to pick, so it can pin the two-pass
-- renormalisation skeleton that the norm and the swiglu will both reuse without
-- also pinning a table.
--
-- ======================================================================
-- THE NUMERIC CONTRACT.  D's design spec leaves D-vec's arithmetic entirely
-- open ("D-vec's numeric contract ... does not exist", skeleton spec item 9),
-- so every rule below is a DECISION, taken here and stated with its reason.
-- The C reference is the authority; this is the summary.
-- ======================================================================
--
--  1. ALIGN TO THE FINER GRID, CLAMPED.  Both operands are brought to a common
--     grid q before adding.  q = max(ex,ee) is exact but lets the operand with
--     the SMALLER exponent -- the larger-magnitude one -- be shifted up without
--     bound.  q is therefore clamped to min(ex,ee) + SHMAX, and
--     SHMAX = ACC_W - MANT_W - 1 is the largest left shift a full-scale
--     mantissa survives in the accumulator with room for the second operand.
--     Beyond that the other operand is below half an LSB of the kept grid, so
--     rounding it away is the CORRECT answer and not an approximation of one.
--
--  2. ROUND HALF TOWARD +INFINITY on every right shift, matching bfp_pack.
--     Implemented here as `+ bias` in one pipeline stage and an ARITHMETIC
--     right shift in the next, never as a mux between a left and a right
--     shifter; see the pipeline note below.
--
--  3. THE OUTPUT EXPONENT IS DRIVEN BY THE MAXIMUM, exactly as bfp_pack:
--     p = msb_pos(max |acc|), sh = max(0, p - KEEP) with KEEP = MANT_W - 2,
--     oexp = q - sh.  Two consequences, both checked by the reference:
--       - at sh = 0 the result is EXACT, out[i] = acc[i], no rounding at all;
--       - at sh > 0 at most one element can saturate, by exactly one LSB, and
--         only when the maximum's rounding crosses 2^15.  Negative saturation
--         is unreachable FOR A PARTICIPATING LANE (round-half-toward-+infinity
--         of -(2^(p+1)-1) is exactly -2^15, never below).  The clamp is kept
--         and reported in `o_sat`, not hidden.
--
--         CORRECTION 2026-08-27, from `tb_seq_vec_seam`: that statement was
--         written without the word PARTICIPATING and is too strong as it
--         stood.  A lane MASKED OUT of the final partial group takes no part
--         in the magnitude fold, so `sh` says nothing about its accumulator
--         and a masked lane carrying a large negative value CAN drive the
--         negative clamp.  The unit is right -- `o_sat` is guarded by `m6(i)`
--         and the write by `w_be`, so neither the summary flag nor the region
--         is affected -- but the BRANCH executes, and until the seam bench ran
--         it never had: `tb_seq_vec_res` poisons its padding lanes with
--         +21845, which saturates POSITIVELY.  One sign of one testbench
--         constant was the whole difference.
--
--  4. THE MAXIMUM IS FOUND WITH AN OR, NOT A COMPARE.  msb_pos is monotone and
--     OR preserves the highest set bit, so msb_pos(a or b) = max(msb_pos a,
--     msb_pos b) and the OR of the magnitudes yields the same p as the maximum
--     of them.  An 8-way 32-bit max needs three levels of 32-bit compare, each
--     a carry chain; an 8-way OR is three levels of 32 independent LUT2s.  Same
--     number, and it is the difference between closing 300 MHz and not.
--
--  5. TWO PASSES, NO SCRATCH MEMORY.  The maximum is not known until every
--     element has been formed, so one pass cannot choose the shift.  This unit
--     re-reads BOTH sources and recomputes the sum rather than spilling a
--     32-bit intermediate, which is a deliberate departure from D's skeleton
--     spec section 2.5 ("D-vec s18 two-pass scratch, 8,704 deep, ~6 RAMB36").
--     For THIS op the recomputation is one shift and one add and is free, while
--     the scratch would be 4,096 x 32 bits = 4 RAMB36 buying nothing.  The
--     argument does NOT carry to the swiglu step, whose recomputation is a
--     second LUT read and a second multiply; that is what the spec's scratch is
--     for and it stays budgeted.
--
-- ======================================================================
-- THE PIPELINE, AND WHY IT HAS SEVEN STAGES FOR SIX LINES OF ARITHMETIC
-- ======================================================================
-- Project timing rule: never two of {barrel shift, wide add, wide compare, bus
-- mux, multiply} in series inside one FSM state.  The arithmetic is
--     out = sat( round( align(x) + align(e), sh ) )
-- and every one of those steps is on the list, so each gets its own stage:
--
--   S0  issue    r_addr <= group pointer; lane mask for this group
--   S1  bias     a = sign_extend(mantissa) + round bias          [wide add]
--   S2  left     b = a << shift_left_amount                      [barrel shift]
--   S3  right    c = b >> shift_right_amount (arithmetic)        [barrel shift]
--   S4  add      acc = c_x + c_e                                 [wide add]
--   S5  pass 1: |acc|      pass 2: acc + output round bias       [wide add]
--   S6  pass 1: OR into the magnitude accumulator                [OR tree]
--       pass 2: >> sh                                            [barrel shift]
--   S7  pass 2: saturate to int16 and register the write port    [compare+mux]
--
-- S2 AND S3 ARE NOT A MUX.  Exactly one of the two shift amounts is ever
-- non-zero for a given operand -- the operand with the smaller exponent is
-- shifted up, the other down -- so applying BOTH unconditionally, in series
-- across two stages, is identical to selecting between them and needs no
-- selector at all.  A single stage doing `if right then shr else shl` would put
-- a barrel shift and a bus mux in series, which is the rule this project has.
--
-- THE RIGHT SHIFT IS CLAMPED AT MANT_W + 1 and that is bit-exact, not an
-- approximation.  For |v| <= 2^(MANT_W-1) the biased value v + 2^(sh-1) lies in
-- [0, 2^sh) for every sh >= MANT_W, so the floor is 0 for BOTH signs.  The
-- exponent ports are EXP_W-bit signed and nothing bounds their difference, so
-- without the clamp the shift amount would need the full EXP_W bits and the
-- bias would not fit the accumulator.
--
-- ======================================================================
-- THE THREE DEFECT CLASSES THIS PROJECT HAS ALREADY PAID FOR
-- ======================================================================
--
-- (a) A VALUE READ FOR THE DURATION OF A LONG OPERATION while its source moves
--     on underneath (the `gdn_emit_chain` w_mant defect).  This unit runs for
--     ~2n/LANES cycles and every one of `i_n`, `i_exp_x`, `i_exp_e` is read for
--     all of it.  Mechanism: they are latched into job-scoped registers at the
--     ONE instant `start` is accepted, `i_taken` pulses at that instant so the
--     rule is checkable from outside, and NOTHING in the datapath reads the
--     input ports again.  The testbench poisons all three immediately after
--     `i_taken`.
--
-- (b) A COMPLETION SIGNALLED AS A ONE-CYCLE PULSE and discarded because the
--     consumer was busy (the `gdn_head_emit` defect).  `done` is a LEVEL held
--     until `done_ack`.  Note the shape of the code: `done_r <= '1'` is
--     assigned on the edge INTO S_DONE and there is deliberately no
--     `done_r <= '0'` default at the top of the process.  An explicit clear
--     inside the ack branch is what destroys the pulse when `done_ack` is tied
--     high, and that exact bug was caught in `gdn_head_emit` only by running
--     the OLD testbench; the configuration sweep here keeps ACK_LAG = 0 for the
--     same reason.
--
-- (c) A SCALAR PUBLISHED AFTER THE STREAM IT QUALIFIES (the `gdn_conv` e_seg
--     defect, 2026-08-27).  `o_exp` qualifies every element this unit writes,
--     so it is assigned in S_SHIFT2 -- which is seven pipeline stages and two
--     FSM states BEFORE the first `w_we` of pass 2 -- and is then frozen for
--     the rest of the job.  `o_sat` is the opposite kind of scalar and is
--     deliberately late: it SUMMARISES the stream rather than qualifying it, so
--     it cannot be final before the last beat, and no consumer may scale
--     anything by it.  The distinction is the whole content of the rule.
--
-- ======================================================================
-- UNSTALLABLE PORTS, WHICH MAKES THROUGHPUT A CORRECTNESS PROPERTY
-- ======================================================================
-- Per D's skeleton spec section 5.1, the region read port is a 1-cycle
-- registered read with NO ready and the region write port is a free-running
-- strobe with NO ready.  This unit therefore consumes `x_rdata`/`e_rdata` in
-- the cycle they arrive, unconditionally, and emits at most one write per
-- cycle, unconditionally.  It never stalls mid-pass for any reason.
--
-- IN-PLACE UPDATE.  The residual step reads X and writes X.  D's spec left the
-- semantics undefined and the first two D units recorded the chosen reading as
-- a DECISION.  Here it is made safe by a checkable invariant rather than by
-- convention: pass 2's write of group g happens SEVEN stages after that group
-- was read, and both pointers advance monotonically, so a group is always read
-- before it is overwritten.  `STRICT` asserts exactly that (`w_group < rptr`)
-- on every write, so the property is observable instead of argued.
--
-- AT NCARDS = 1 THERE IS NO E SEAM.  D's skeleton spec hazard B7 -- E's
-- unstallable `o_we` stream pipelined straight into residual pass 1 -- does not
-- arise on the build target: at N = 1 the row-parallel matvec writes ER
-- directly and there is no collective at all.  This unit reads ER as an
-- ordinary region, which is the spec's exit (iii), and at N = 1 that exit costs
-- nothing because there is no landing buffer to add.  B7 returns at NCARDS > 1
-- and is NOT resolved here.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;   -- clog2

entity seq_vec_res is
  generic(
    LANES  : positive := 8;      -- LANES_V, elements per region beat
    MANT_W : positive := 16;
    ACC_W  : positive := 32;
    EXP_W  : positive := 16;
    ADDR_W : positive := 13;     -- element address width of a region
    STRICT : boolean  := true );
  port(
    clk      : in  std_logic;
    rst      : in  std_logic;

    -- ---- job issue.  Every field is latched at the accept instant --------
    ready    : out std_logic;                       -- idle and not holding done
    start    : in  std_logic;                       -- LEVEL, held until taken
    i_n      : in  unsigned(ADDR_W-1 downto 0);     -- element count
    i_exp_x  : in  signed(EXP_W-1 downto 0);
    i_exp_e  : in  signed(EXP_W-1 downto 0);
    i_taken  : out std_logic;                       -- 1-cycle: latched HERE

    -- ---- region read port.  1-cycle registered read, NO ready (O25) ------
    r_en     : out std_logic;
    r_addr   : out unsigned(ADDR_W-clog2(LANES)-1 downto 0);   -- GROUP address
    x_rdata  : in  std_logic_vector(LANES*MANT_W-1 downto 0);
    e_rdata  : in  std_logic_vector(LANES*MANT_W-1 downto 0);

    -- ---- region write port.  Free-running strobe, NO ready ---------------
    w_we     : out std_logic;
    w_addr   : out unsigned(ADDR_W-clog2(LANES)-1 downto 0);
    w_be     : out std_logic_vector(LANES-1 downto 0);
    w_data   : out std_logic_vector(LANES*MANT_W-1 downto 0);

    -- ---- completion ------------------------------------------------------
    done     : out std_logic;                       -- LEVEL, held until ack
    done_ack : in  std_logic;
    o_exp    : out signed(EXP_W-1 downto 0);        -- QUALIFIES the writes
    o_shift  : out unsigned(5 downto 0);            -- the chosen sh, for the log
    o_sat    : out std_logic;                       -- SUMMARISES them
    err      : out std_logic );
end entity;

architecture rtl of seq_vec_res is

  constant LOG2L : natural := clog2(LANES);
  constant GA_W  : natural := ADDR_W - LOG2L;
  constant SHMAX : natural := ACC_W - MANT_W - 1;   -- 15 at 32/16
  constant KEEP  : natural := MANT_W - 2;           -- 14 at 16
  constant RMAX  : natural := MANT_W + 1;           -- right shifts beyond -> 0

  type mant_arr is array (0 to LANES-1) of signed(MANT_W-1 downto 0);
  type acc_arr  is array (0 to LANES-1) of signed(ACC_W-1 downto 0);

  type state_t is (S_IDLE, S_LAT, S_PREP, S_PREP2, S_PREP3, S_PREP4,
                   S_P1, S_SHIFT, S_SHIFT2, S_P2, S_DONE);
  signal state : state_t := S_IDLE;

  -- ---- job shadow, written at exactly one instant (defect class (a)) -----
  signal j_n    : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal j_ng   : unsigned(GA_W downto 0)     := (others => '0');
  signal j_ex   : signed(EXP_W-1 downto 0)    := (others => '0');
  signal j_ee   : signed(EXP_W-1 downto 0)    := (others => '0');
  signal j_d    : signed(EXP_W downto 0)      := (others => '0');  -- ex - ee
  signal j_diff : unsigned(EXP_W downto 0)    := (others => '0');  -- |ex - ee|
  signal j_c    : natural range 0 to SHMAX    := 0;
  signal j_qmin : signed(EXP_W-1 downto 0)    := (others => '0');
  signal j_q    : signed(EXP_W-1 downto 0)    := (others => '0');
  signal sxl, sel : natural range 0 to SHMAX := 0;   -- left shift amounts
  signal sxr, ser : natural range 0 to RMAX  := 0;   -- right shift amounts
  signal bias_x, bias_e : signed(ACC_W-1 downto 0) := (others => '0');
  signal last_mask : std_logic_vector(LANES-1 downto 0) := (others => '1');

  -- ---- pass control ------------------------------------------------------
  signal pass2  : std_logic := '0';
  signal rptr   : unsigned(GA_W downto 0) := (others => '0');
  signal orv    : unsigned(ACC_W-1 downto 0) := (others => '0');
  signal sh_r   : natural range 0 to 63 := 0;
  signal bias_o : signed(ACC_W-1 downto 0) := (others => '0');
  signal p_r    : natural range 0 to ACC_W-1 := 0;
  -- Groups ACCEPTED into the pipeline, distinct from `rptr`.  They track each
  -- other exactly while the read pointer is advancing, but `rptr` SATURATES at
  -- j_ng during the drain and a valid derived from it alone would re-inject the
  -- last group on every drain cycle.
  signal cptr   : unsigned(GA_W downto 0) := (others => '0');

  -- ---- the seven pipeline stages ----------------------------------------
  signal v1, v2, v3, v4, v5, v6 : std_logic := '0';
  signal m1, m2, m3, m4, m5, m6 : std_logic_vector(LANES-1 downto 0)
                                  := (others => '0');
  signal g1, g2, g3, g4, g5, g6 : unsigned(GA_W-1 downto 0)
                                  := (others => '0');
  signal a_x, a_e, b_x, b_e, c_x, c_e, s4, s5, s6 : acc_arr
         := (others => (others => '0'));

  -- ---- outputs -----------------------------------------------------------
  signal done_r  : std_logic := '0';
  signal err_r   : std_logic := '0';
  signal sat_r   : std_logic := '0';
  signal exp_r   : signed(EXP_W-1 downto 0) := (others => '0');
  signal we_r    : std_logic := '0';
  signal wa_r    : unsigned(GA_W-1 downto 0) := (others => '0');
  signal wbe_r   : std_logic_vector(LANES-1 downto 0) := (others => '0');
  signal wd_r    : std_logic_vector(LANES*MANT_W-1 downto 0) := (others => '0');
  signal taken_r : std_logic := '0';

  -- Highest set bit of an unsigned vector, 0 for zero.  NORMATIVE: msb_pos(0)
  -- = 0 is what makes an all-zero vector keep its grid instead of inventing an
  -- exponent.  Local, not util_pkg.msb_pos, which routes the value through a
  -- VHDL integer -- the round trip Vivado has been observed to drop the sign
  -- across in this design (see rtl/bfp_pack.vhd's header).
  function msb_pos_u(u : unsigned) return natural is
    variable r : natural := 0;
  begin
    for i in 0 to u'length-1 loop
      if u(i) = '1' then r := i; end if;
    end loop;
    return r;
  end function;

  function abs_s(v : signed) return unsigned is
  begin
    if v(v'high) = '1' then return unsigned(-v); else return unsigned(v); end if;
  end function;

  function unpack(sv : std_logic_vector) return mant_arr is
    variable r : mant_arr;
  begin
    for i in 0 to LANES-1 loop
      r(i) := signed(sv((i+1)*MANT_W-1 downto i*MANT_W));
    end loop;
    return r;
  end function;

begin

  -- Elaboration-time bounds.  A generic combination that breaks the accumulator
  -- width argument is a wrong number, not a smaller design, and it would show
  -- up as a saturation somewhere far away.
  assert ACC_W >= MANT_W + SHMAX + 1
    report "seq_vec_res: ACC_W too narrow for MANT_W + SHMAX + 1"
    severity failure;
  assert 2**LOG2L = LANES
    report "seq_vec_res: LANES must be a power of two"
    severity failure;
  assert ADDR_W > LOG2L
    report "seq_vec_res: ADDR_W must exceed log2(LANES)"
    severity failure;

  -- The read address is COMBINATIONAL off the group pointer, clamped so the
  -- trailing drain reads stay in range.  Same read-ahead shape as bfp_pack and
  -- attention_ml: at pointer value R the data for group R-1 is on the bus.
  r_addr <= resize(rptr, GA_W) when rptr < j_ng
            else (others => '0');
  r_en   <= '1' when (state = S_P1 or state = S_P2) and rptr < j_ng else '0';

  ready   <= '1' when state = S_IDLE and done_r = '0' else '0';
  i_taken <= taken_r;
  done    <= done_r;
  err     <= err_r;
  o_sat   <= sat_r;
  o_exp   <= exp_r;
  o_shift <= to_unsigned(sh_r, 6);
  w_we    <= we_r;
  w_addr  <= wa_r;
  w_be    <= wbe_r;
  w_data  <= wd_r;

  main : process(clk) is
    variable xin, ein : mant_arr;
    variable acc_v    : signed(ACC_W downto 0);
    variable orfold   : unsigned(ACC_W-1 downto 0);
    variable sh_v     : integer;
    variable rv       : signed(ACC_W-1 downto 0);
    variable diff_v   : unsigned(EXP_W downto 0);
    variable c_v      : natural;
    variable nrem     : natural;
    variable msk      : std_logic_vector(LANES-1 downto 0);
    variable satx     : std_logic;
    variable exp_new  : signed(EXP_W-1 downto 0);
  begin
    if rising_edge(clk) then
      taken_r <= '0';
      we_r    <= '0';

      if rst = '1' then
        state   <= S_IDLE;
        done_r  <= '0';
        err_r   <= '0';
        sat_r   <= '0';
        rptr    <= (others => '0');
        orv     <= (others => '0');
        pass2   <= '0';
        v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0'; v5 <= '0'; v6 <= '0';
        cptr    <= (others => '0');
        exp_r   <= (others => '0');
        sh_r    <= 0;
      else

        -- =================================================================
        -- THE PIPELINE.  It advances every cycle in S_P1 and S_P2 and is
        -- held flushed everywhere else.  Nothing in it is conditional on
        -- back-pressure, because neither region port has any.
        -- =================================================================
        if state = S_P1 or state = S_P2 then

          -- ---- S1: sign-extend and add the alignment round bias ----------
          xin := unpack(x_rdata);
          ein := unpack(e_rdata);
          for i in 0 to LANES-1 loop
            a_x(i) <= resize(xin(i), ACC_W) + bias_x;
            a_e(i) <= resize(ein(i), ACC_W) + bias_e;
          end loop;
          -- ---- S0 -> S1 bookkeeping: the group whose data is on the bus.
          -- Read-ahead, the same shape as bfp_pack and attention_ml: while the
          -- pointer reads `rptr`, the bus holds group `rptr - 1`.  Only the
          -- LAST group can be partial, so the mask is a compare against
          -- j_ng - 1 and not a per-lane computation.
          if rptr >= 1 and cptr < j_ng then
            v1   <= '1';
            g1   <= resize(cptr, GA_W);
            cptr <= cptr + 1;
            if cptr = j_ng - 1 then m1 <= last_mask;
            else                    m1 <= (others => '1'); end if;
          else
            v1 <= '0';
            m1 <= (others => '0');
          end if;

          -- ---- S2: the left shift ----------------------------------------
          for i in 0 to LANES-1 loop
            b_x(i) <= shift_left(a_x(i), sxl);
            b_e(i) <= shift_left(a_e(i), sel);
          end loop;
          v2 <= v1; m2 <= m1; g2 <= g1;

          -- ---- S3: the arithmetic right shift ----------------------------
          for i in 0 to LANES-1 loop
            c_x(i) <= shift_right(b_x(i), sxr);
            c_e(i) <= shift_right(b_e(i), ser);
          end loop;
          v3 <= v2; m3 <= m2; g3 <= g2;

          -- ---- S4: the sum ------------------------------------------------
          for i in 0 to LANES-1 loop
            acc_v := resize(c_x(i), ACC_W+1) + resize(c_e(i), ACC_W+1);
            s4(i) <= resize(acc_v, ACC_W);
          end loop;
          v4 <= v3; m4 <= m3; g4 <= g3;

          -- ---- S5: pass 1 magnitude / pass 2 output round bias ------------
          for i in 0 to LANES-1 loop
            if pass2 = '0' then
              s5(i) <= signed(resize(abs_s(s4(i)), ACC_W));
            else
              s5(i) <= s4(i) + bias_o;
            end if;
          end loop;
          v5 <= v4; m5 <= m4; g5 <= g4;

          -- ---- S6: pass 1 OR fold / pass 2 requantising shift -------------
          orfold := (others => '0');
          for i in 0 to LANES-1 loop
            if m5(i) = '1' then orfold := orfold or unsigned(s5(i)); end if;
            s6(i) <= shift_right(s5(i), sh_r);
          end loop;
          if pass2 = '0' and v5 = '1' then
            orv <= orv or orfold;
          end if;
          v6 <= v5; m6 <= m5; g6 <= g5;

          -- ---- S7: saturate and drive the write port ----------------------
          if pass2 = '1' and v6 = '1' then
            satx := '0';
            for i in 0 to LANES-1 loop
              rv := s6(i);
              if rv > to_signed(2**(MANT_W-1) - 1, ACC_W) then
                wd_r((i+1)*MANT_W-1 downto i*MANT_W) <=
                  std_logic_vector(to_signed(2**(MANT_W-1) - 1, MANT_W));
                if m6(i) = '1' then satx := '1'; end if;
              elsif rv < -to_signed(2**(MANT_W-1), ACC_W) then
                -- SPELLED `to_signed(-(2**(MANT_W-1)), MANT_W)` AND NOT
                -- `-to_signed(2**(MANT_W-1), MANT_W)`.  The second form asks
                -- numeric_std to convert +32768 into 16 signed bits, which
                -- does not fit: it emits `TO_SIGNED: vector truncated` on
                -- EVERY execution and is correct only because the truncation
                -- and the negation each overflow and the two cancel.  The
                -- first form is -32768, which fits exactly.  Found by
                -- `tb_seq_vec_seam`, which is the first test ever to execute
                -- this branch -- see the note below.
                wd_r((i+1)*MANT_W-1 downto i*MANT_W) <=
                  std_logic_vector(to_signed(-(2**(MANT_W-1)), MANT_W));
                if m6(i) = '1' then satx := '1'; end if;
              else
                wd_r((i+1)*MANT_W-1 downto i*MANT_W) <=
                  std_logic_vector(resize(rv, MANT_W));
              end if;
            end loop;
            we_r  <= '1';
            wa_r  <= g6;
            wbe_r <= m6;
            if satx = '1' then sat_r <= '1'; end if;
          end if;

        end if;

        -- =================================================================
        -- THE SEQUENCER
        -- =================================================================
        case state is

          when S_IDLE =>
            if start = '1' and done_r = '0' then
              -- THE ONE INSTANT.  Everything the job needs is copied here and
              -- the input ports are never read again.
              j_n     <= i_n;
              j_ex    <= i_exp_x;
              j_ee    <= i_exp_e;
              j_d     <= resize(i_exp_x, EXP_W+1) - resize(i_exp_e, EXP_W+1);
              taken_r <= '1';
              sat_r   <= '0';
              err_r   <= '0';
              orv     <= (others => '0');
              pass2   <= '0';
              sh_r    <= 0;
              state   <= S_LAT;
            end if;

          when S_LAT =>
            -- |ex - ee|, and the group count.  A zero-length job is an error
            -- and not a no-op: `seq_desc_fetch` already rejects n_rows = 0 as
            -- ERR_DESC, and a unit that quietly did nothing would make a table
            -- bug look like a fast step.
            if j_d < 0 then j_diff <= unsigned(-j_d);
            else            j_diff <= unsigned(j_d); end if;
            nrem := to_integer(j_n(LOG2L-1 downto 0));
            if nrem = 0 then
              j_ng <= resize(j_n(ADDR_W-1 downto LOG2L), GA_W+1);
              last_mask <= (others => '1');
            else
              j_ng <= resize(j_n(ADDR_W-1 downto LOG2L), GA_W+1) + 1;
              msk := (others => '0');
              for i in 0 to LANES-1 loop
                if i < nrem then msk(i) := '1'; end if;
              end loop;
              last_mask <= msk;
            end if;
            if j_ex < j_ee then j_qmin <= j_ex; else j_qmin <= j_ee; end if;
            if j_n = 0 then
              err_r  <= '1';
              done_r <= '1';
              state  <= S_DONE;
            else
              state <= S_PREP;
            end if;

          when S_PREP =>
            diff_v := j_diff;
            if diff_v > to_unsigned(SHMAX, EXP_W+1) then c_v := SHMAX;
            else c_v := to_integer(diff_v); end if;
            j_c   <= c_v;
            state <= S_PREP2;

          when S_PREP2 =>
            j_q <= j_qmin + to_signed(j_c, EXP_W);
            state <= S_PREP3;

          when S_PREP3 =>
            -- The operand with the SMALLER exponent is shifted UP by c; the
            -- other is shifted DOWN by diff - c, clamped at RMAX because
            -- beyond that a MANT_W mantissa rounds to zero for both signs.
            if j_d >= 0 then            -- ex >= ee, so e is the larger one
              sel <= j_c;
              sxl <= 0;
              ser <= 0;
              if to_integer(j_diff) - j_c > RMAX then sxr <= RMAX;
              else sxr <= to_integer(j_diff) - j_c; end if;
            else
              sxl <= j_c;
              sel <= 0;
              sxr <= 0;
              if to_integer(j_diff) - j_c > RMAX then ser <= RMAX;
              else ser <= to_integer(j_diff) - j_c; end if;
            end if;
            state <= S_PREP4;

          when S_PREP4 =>
            -- Round-half-up biases, as decoders on the shift amounts.
            if sxr > 0 then bias_x <= shift_left(to_signed(1, ACC_W), sxr - 1);
            else            bias_x <= (others => '0'); end if;
            if ser > 0 then bias_e <= shift_left(to_signed(1, ACC_W), ser - 1);
            else            bias_e <= (others => '0'); end if;
            rptr  <= (others => '0');
            cptr  <= (others => '0');
            state <= S_P1;

          when S_P1 =>
            -- THE EXIT NEEDS `cptr = j_ng` AND NOT ONLY AN EMPTY PIPELINE.
            -- `v1` is assigned by the pipeline block on the SAME edge this
            -- test reads it, so at the instant the last group is being latched
            -- into stage 1 every valid still reads '0' and a pipeline-empty
            -- test alone declares the pass finished one group early.  Measured,
            -- not argued: with n = LANES the unit ran pass 1 for zero groups,
            -- entered pass 2 with the in-flight group still in the pipe, and
            -- emitted TWO write beats for group 0 -- one carrying pass 1's
            -- magnitude data.  Caught by the write monitor's counting
            -- identity, which no throughput metric would have shown.
            if rptr < j_ng then
              rptr <= rptr + 1;
            elsif cptr = j_ng
                  and v6 = '0' and v5 = '0' and v4 = '0' and v3 = '0'
                  and v2 = '0' and v1 = '0' then
              state <= S_SHIFT;
            end if;

          when S_SHIFT =>
            -- p in one state (a priority encoder), sh and the exponent in the
            -- next, so no compare sits in series with the subtract.
            p_r   <= msb_pos_u(orv);
            state <= S_SHIFT2;

          when S_SHIFT2 =>
            sh_v := p_r - KEEP;
            if sh_v < 0 then sh_v := 0; end if;
            sh_r <= sh_v;
            -- (c) THE SCALAR IS PUBLISHED HERE, two FSM states and seven
            -- pipeline stages before the first write beat it qualifies.
            exp_new := j_q - to_signed(sh_v, EXP_W);
            exp_r   <= exp_new;
            if sh_v > 0 then
              bias_o <= shift_left(to_signed(1, ACC_W), sh_v - 1);
            else
              bias_o <= (others => '0');
            end if;
            rptr  <= (others => '0');
            cptr  <= (others => '0');
            pass2 <= '1';
            state <= S_P2;

          when S_P2 =>
            if rptr < j_ng then
              rptr <= rptr + 1;
            elsif cptr = j_ng
                  and v6 = '0' and v5 = '0' and v4 = '0' and v3 = '0'
                  and v2 = '0' and v1 = '0' then
              -- (b) `done_r` is raised on the edge INTO S_DONE and there is no
              -- default clear anywhere in this process.
              done_r <= '1';
              state  <= S_DONE;
            end if;

          when S_DONE =>
            if done_ack = '1' then
              done_r <= '0';
              state  <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- Simulation-only assertions.  A generic rather than unconditional, because
  -- the testbench drives a zero-length job on purpose.
  -- ======================================================================
  strict_chk : process(clk) is
  begin
    if rising_edge(clk) and rst = '0' and STRICT then
      -- IN-PLACE SAFETY, as an observable invariant rather than a schedule
      -- argument: pass 2 overwrites X while re-reading it, and the write of a
      -- group must never reach a group that has not been read yet.
      assert not (we_r = '1' and resize(wa_r, GA_W+1) >= rptr)
        report "seq_vec_res: pass 2 wrote a group that had not been read.  "
             & "The in-place update has overtaken its own source and the "
             & "residual is being added to itself."
        severity failure;
      -- The unit must never accept a job while it is still holding a
      -- completion: that would drop the previous job's exponent.
      assert not (taken_r = '1' and done_r = '1')
        report "seq_vec_res: a job was accepted while done was still held"
        severity failure;
    end if;
  end process;

end architecture;
