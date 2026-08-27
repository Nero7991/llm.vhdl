-- rtl/attn_emit.vhd
-- Subsystem C, site 6f: renormalize the whole layer's gated attention output
-- onto ONE block-floating grid and pack it to int16.
--
-- WHAT IT COMPUTES.  NGRP groups of GRP_N elements sit in a scratch memory,
-- group g on grid e_grid(g).  Two passes over that memory produce one exponent
-- and one mantissa per element:
--
--   e_min     = min over g of e_grid(g)
--   y_al[i]   = y_pre[i] asr (e_grid(g) - e_min)          FLOOR
--   amax      = max over i of |y_al[i]|                   msb_pos(0) = 0
--   shp       = max(0, msb_pos(amax) - TARGET_MSB)
--   y_mant[i] = sat16( round_shift(y_al[i], shp) )        half toward +inf
--   y_exp     = e_min - shp
--
-- Bit-exact against ref/attn_emit_vec.c, whose five oracles share none of this
-- unit's integer machinery: the pack reconstructed in floating point inside a
-- bound DERIVED per case, the peak window as an exact inequality, e_min and
-- the non-negativity of every alignment shift as exact statements, the
-- DIRECTION of the alignment separated from a round by an inequality, and the
-- mantissa range [-32768, 32767] derived from the peak window.
--
-- WHY THE GRIDS DIFFER.  `v_ref` is per KV head, so a card's query heads sit on
-- two grids: e_grid(kvh) = v_ref[layer][kvh] + 14, where the 14 is site 6b's
-- precision gain (R_Q - 1).  One y_exp has to serve all of them.
--
-- WHY THE MINIMUM AND NOT THE MAXIMUM.  Aligning to the minimum makes every
-- shift a RIGHT shift, so no element can grow while being aligned and no wider
-- intermediate is needed.  Aligning to the maximum would need left shifts, and
-- an element already at the s24 rail would have to overflow.  Same policy and
-- same reason as attn_score_q12's block alignment.
--
-- WHY THE ALIGNMENT FLOORS AND THE PACK ROUNDS.  Two roundings in series on
-- one value double-round, so exactly one of them may round.  The pack rounds
-- because its error is the one that reaches the output.  This is invisible to
-- any magnitude check -- the reference's own bound is derived to ADMIT the
-- alignment floor, so a round is strictly inside it -- and is pinned by a
-- separate direction oracle.  attn_score_q12_vec.c records finding exactly
-- that by mutation.
--
-- WHY IT PAIRS WITH attn_gate.  y_pre is that unit's output and this unit is
-- its only consumer.  Together they are the whole of C's step 8 after the
-- reciprocal, and with attn_kv_quant, attn_score_q12, attn_softmax and
-- attn_recip they make steps 4 through 8 a contiguous verified run.
--
-- ---------------------------------------------------------------------------
-- THE HEADER IS PUBLISHED BEFORE THE FIRST MANTISSA, AND THAT IS A RULE.
-- From subsystem B's 2026-08-27 defect
-- (docs/debugging/2026-08-27_gdn-conv-eseg-published-late.md): `gdn_conv`
-- assigned its segment exponent in its FINAL state, so the scalar was
-- published AFTER every beat it describes, and a consumer that needed it for
-- its first beat scaled the whole segment by the PREVIOUS segment's exponent.
-- Every testbench passed, including a bit-exact double-oracle check over 128
-- cases, because they all sample the scalar at or after `done`.  The value was
-- right and only its time was wrong.
--
-- The rule: **a scalar that qualifies a stream must be assigned in a state
-- STRICTLY EARLIER than the state that first raises that stream's valid.**
-- Here y_exp and hdr_valid are assigned in S_HDR, and m_valid cannot rise
-- until six cycles into S_EMIT, so the separation is structural.  It is also
-- CHECKED, in tb_attn_emit's ord_chk process, because a structural argument
-- nothing tests is the unobservable contract that defect punished.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   start / e_grid / cfg_taken   THE PRODUCER IS STALLABLE -- attn_ctrl issues
--                                one job per layer and waits for done.  RULE 2:
--                                e_grid is read across BOTH passes, i.e. for
--                                2*N cycles, so it is LATCHED at start and the
--                                instant is made observable by cfg_taken.  A
--                                producer that advanced it between the passes
--                                would align pass B differently from pass A --
--                                every value in range, the count right, and the
--                                peak window quietly wrong.
--
--   x_raddr / x_re / x_rdata     N/A -- this unit is the MASTER.  A memory
--                                cannot refuse, and x_re is driven so that the
--                                memory's output register is frozen exactly
--                                when the pipeline is.  A stall that froze
--                                x_raddr but left the memory ENABLED makes it
--                                overwrite its output register with the item
--                                still in flight; on resume the capture stage
--                                takes the wrong element with the right index.
--                                attn_kv_quant's M6 is that mutation and it is
--                                an EQUIVALENT MUTANT with no back-pressure.
--
--   hdr_valid / y_exp            Held from S_HDR until the next start.  See the
--                                ordering rule above.
--
--   m_valid / m_data / m_index / Producer (this unit) IS stallable and HOLDS.
--   m_ready                      m_ready DEFAULTS TO '1', which is what a
--                                consumer that never stalls presents -- and is
--                                exactly why the hold must be built and tested,
--                                because such a consumer cannot tell a held
--                                valid from a pulsed one.
--
--   done / done_ack              RULE 1: HELD until acked, never pulsed, and
--                                raised only after the LAST mantissa has been
--                                ACCEPTED.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.
--
--   pass A, per element:  address | (memory) | capture + shift mux | ALIGN
--                         SHIFT | ABS | MAX COMPARE
--   finalize:             S_FIN1 the priority encode ALONE
--                         S_FIN2 the clamped subtract ALONE
--                         S_HDR  the exponent subtract ALONE, and publish
--   pass B, per element:  address | (memory) | capture + shift mux | ALIGN
--                         SHIFT | BIAS ADD | PACK SHIFT | SATURATE
--
-- THE GROUP INDEX IS CARRIED FORWARD, NOT READ LIVE.  The issue stage's group
-- counter advances on the same edge that issues the LAST element of a group,
-- so a later-stage lookup of the live counter would fetch the NEXT group's
-- shift for that one element.  attn_kv_quant's header records the identical
-- defect on its block index: 8 wrong elements out of 256, every element in
-- range, the record the right length -- the gdn_emit_chain head-23 shape.
--
-- ONE resize IS DELIBERATELY NOT WRITTEN.  |y_al| reaches 2^(IN_W-1), which
-- does NOT fit IN_W bits unsigned-of-a-signed-negate: `resize(-ext, IN_W)`
-- keeps the sign bit and drops the top magnitude bit, so abs(-2^23) would come
-- out ZERO and amax would be taken from the next largest element -- one msb
-- too low, every mantissa twice too large, the exponent one too high, and the
-- reconstructed value identical.  That is
-- docs/debugging/2026-08-27_attn-kv-quant-abs-resize.md verbatim, in the unit
-- that does the same job at a different granularity.  a5_abs is IN_W+1 bits
-- wide and there is no resize on the negate.
--
-- NO DSP.  A min scan, subtracts, two barrel shifts, an absolute value, a
-- magnitude compare, a priority encode, an add and a saturate.  No `*` on any
-- datapath value.  DERIVED from the operations, not measured; no Vivado was
-- run for this file.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only shifts, indices and
-- exponents, which the project rule exempts.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;                -- clog2

entity attn_emit is
  generic(
    -- One grid per KV head on the card.  2 at N = 2 tensor parallel on either
    -- target model (model_cfg_pkg: attn_kv_heads = 4).
    NGRP  : positive := 2;
    -- Elements per grid: the GQA group's query heads times head_dim, i.e.
    -- 6 x 256 = 1536 at 27B and 4 x 256 = 1024 at 9B.
    GRP_N : positive := 1536;
    IN_W  : positive := 24;             -- attn_gate's y_pre
    MANT_W: positive := 16;             -- A's activation memory holds int16
    EXP_W : positive := 8;
    -- The peak lands in [2^TARGET_MSB, 2^(TARGET_MSB+1)) after the pack shift.
    -- MANT_W-2 leaves the sign bit and one bit of headroom, which is what
    -- makes the only reachable saturation the single value 2^(MANT_W-1).
    TARGET_MSB : natural := 14;
    -- The project's shift convention.  Every alignment shift is >= 0 by
    -- construction (e_min is a MINIMUM), so this only bounds the barrel
    -- shifter; a corrupted e_grid cannot make it a left shift.
    SH_MAX : natural := 63;
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the job.  RULE 2: e_grid latched, cfg_taken observable. ---------
    start     : in  std_logic;                  -- one-cycle request
    e_grid    : in  std_logic_vector(NGRP*EXP_W-1 downto 0);
    cfg_taken : out std_logic;                  -- one cycle, at the latch
    busy      : out std_logic;

    -- ---- the y_pre scratch.  This unit is the MASTER. -------------------
    x_raddr : out std_logic_vector(clog2(NGRP*GRP_N)-1 downto 0);
    x_re    : out std_logic;
    x_rdata : in  std_logic_vector(IN_W-1 downto 0);

    -- ---- the header, published BEFORE the first mantissa -----------------
    hdr_valid : out std_logic;
    y_exp     : out signed(EXP_W-1 downto 0);

    -- ---- the mantissa stream.  Held until m_ready. ----------------------
    m_valid : out std_logic;
    m_data  : out std_logic_vector(MANT_W-1 downto 0);
    m_index : out std_logic_vector(clog2(NGRP*GRP_N)-1 downto 0);
    m_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. -----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at start.
    --   o_sat : the int16 pack saturated.  REACHABLE and legal -- the peak can
    --           round up to exactly 2^(MANT_W-1) -- so it is a value the
    --           testbench checks against a golden, not a flag to hope stays
    --           clear.  The LOW rail is a pure width guard: the same peak
    --           window makes -2^(MANT_W-1) reachable but never exceeded.
    --   err   : an alignment shift came out negative, i.e. the latched e_min
    --           was not the minimum of the latched e_grid.  Unreachable.
    o_sat : out std_logic;
    err   : out std_logic
  );
end entity;

architecture rtl of attn_emit is

  constant NTOT : integer := NGRP * GRP_N;
  constant AW   : integer := clog2(NTOT);
  constant SHW  : integer := clog2(SH_MAX + 1);
  -- The pack's bias add: |y_al| <= 2^(IN_W-1) and the bias is at most
  -- 2^(shp-1) with shp <= IN_W-1-TARGET_MSB, so IN_W+2 bits hold the sum with
  -- room.  Derived from the operands rather than copied from IN_W.
  constant ACC_W : integer := IN_W + 2;
  -- shp lives in 0 .. IN_W-1-TARGET_MSB.
  constant SHP_MAX : integer := IN_W - 1 - TARGET_MSB;
  constant SHPW    : integer := clog2(SHP_MAX + 1);

  -- Drain depths: the number of cycles after the last issue before the last
  -- element has left the final stage.
  constant DEPTH_A : integer := 5;
  constant DEPTH_B : integer := 6;

  function smin(w : integer) return signed is
  begin return shift_left(to_signed(-1, w), w-1); end function;

  constant M_MIN : signed(MANT_W-1 downto 0) := smin(MANT_W);
  constant M_MAX : signed(MANT_W-1 downto 0) := not smin(MANT_W);

  -- The argument is `a` and not `v`: VHDL is case-insensitive and a formal
  -- named `v` would silently hide a signal of that name inside the body.  The
  -- same shadowing cost a run in tb_attn_recip.
  function sat_m(a : signed) return signed is
  begin
    if    a > resize(M_MAX, a'length) then return M_MAX;
    elsif a < resize(M_MIN, a'length) then return M_MIN;
    else  return resize(a, MANT_W);
    end if;
  end function;

  -- msb position of an unsigned, 0 for zero.  The SAME convention as
  -- mv4i_msb_pos_u, attn_kv_quant, attn_recip, gdn_head_emit and gdn_recur.
  function msb_pos_u(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  type state_t is (S_IDLE, S_EMIN, S_SHIFTS, S_SCAN, S_FIN1, S_FIN2, S_HDR,
                   S_EMIT, S_DONE);
  signal state : state_t := S_IDLE;

  type e_arr_t  is array (0 to NGRP-1) of signed(EXP_W-1 downto 0);
  type sh_arr_t is array (0 to NGRP-1) of unsigned(SHW-1 downto 0);
  signal e_l   : e_arr_t  := (others => (others => '0'));
  signal sh_a  : sh_arr_t := (others => (others => '0'));
  signal e_min : signed(EXP_W-1 downto 0) := (others => '0');

  signal grp   : integer range 0 to NGRP-1 := 0;

  -- issue counters, shared by both passes
  signal i_idx : integer range 0 to GRP_N := 0;   -- within the group
  signal i_grp : integer range 0 to NGRP-1 := 0;
  signal i_abs : integer range 0 to NTOT   := 0;  -- flat element index
  signal drain : integer range 0 to DEPTH_B := 0;

  -- pass A pipeline
  signal a1_v, a2_v, a3_v, a4_v, a5_v : std_logic := '0';
  signal a1_g, a2_g : integer range 0 to NGRP-1 := 0;
  signal a3_x  : signed(IN_W-1 downto 0) := (others => '0');
  signal a3_sh : unsigned(SHW-1 downto 0) := (others => '0');
  signal a4_al : signed(IN_W-1 downto 0) := (others => '0');
  -- IN_W+1 bits, not IN_W.  |y_al| reaches 2^(IN_W-1), which does not fit
  -- IN_W bits, and a narrowing resize on the negate would return ZERO for
  -- exactly that value.  See the header.
  signal a5_abs : unsigned(IN_W downto 0) := (others => '0');
  signal amax   : unsigned(IN_W downto 0) := (others => '0');

  signal p_msb : integer range 0 to IN_W := 0;
  signal shp_r : unsigned(SHPW-1 downto 0) := (others => '0');
  signal bias_r : signed(ACC_W-1 downto 0) := (others => '0');

  -- pass B pipeline
  signal m1_v, m2_v, m3_v, m4_v, m5_v, m6_v : std_logic := '0';
  signal m1_g, m2_g : integer range 0 to NGRP-1 := 0;
  type idx_pipe_t is array (0 to 5) of integer range 0 to NTOT-1;
  signal m_idx_p : idx_pipe_t := (others => 0);
  signal m3_x   : signed(IN_W-1 downto 0) := (others => '0');
  signal m3_sh  : unsigned(SHW-1 downto 0) := (others => '0');
  signal m4_al  : signed(IN_W-1 downto 0) := (others => '0');
  signal m5_sum : signed(ACC_W-1 downto 0) := (others => '0');
  signal m6_shf : signed(ACC_W-1 downto 0) := (others => '0');

  -- outputs
  signal raddr_r   : unsigned(AW-1 downto 0) := (others => '0');
  signal m_valid_r : std_logic := '0';
  signal m_data_r  : signed(MANT_W-1 downto 0) := (others => '0');
  signal m_index_r : integer range 0 to NTOT-1 := 0;
  signal hdr_r     : std_logic := '0';
  signal yexp_r    : signed(EXP_W-1 downto 0) := (others => '0');
  signal done_r    : std_logic := '0';
  signal cfg_tk    : std_logic := '0';
  signal sat_r     : std_logic := '0';
  signal err_r     : std_logic := '0';

  -- COMBINATIONAL, and deliberately so.  A registered stall reports the
  -- consumer's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.
  signal emit_en : std_logic;

begin

  -- Freeze the WHOLE emit pass -- stages, address counter AND read enable
  -- together -- whenever the output stage holds an unaccepted element.
  -- Freezing fewer than all three is the silent-corruption case argued in the
  -- header's x_re paragraph.
  emit_en <= '0' when (m_valid_r = '1' and m_ready = '0') else '1';

  x_raddr <= std_logic_vector(raddr_r);
  x_re    <= '1' when state = S_SCAN else
             emit_en when state = S_EMIT else
             '0';

  cfg_taken <= cfg_tk;
  busy      <= '0' when state = S_IDLE else '1';
  hdr_valid <= hdr_r;
  y_exp     <= yexp_r;
  m_valid   <= m_valid_r;
  m_data    <= std_logic_vector(m_data_r);
  m_index   <= std_logic_vector(to_unsigned(m_index_r, AW));
  done      <= done_r;
  o_sat     <= sat_r;
  err       <= err_r;

  process(clk)
    variable ext  : signed(IN_W downto 0);
    variable sh_v : integer;
    variable meta : boolean;
    variable rv   : signed(ACC_W-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state   <= S_IDLE;
        i_idx <= 0; i_grp <= 0; i_abs <= 0; grp <= 0; drain <= 0;
        a1_v <= '0'; a2_v <= '0'; a3_v <= '0'; a4_v <= '0'; a5_v <= '0';
        m1_v <= '0'; m2_v <= '0'; m3_v <= '0'; m4_v <= '0'; m5_v <= '0';
        m6_v <= '0';
        amax  <= (others => '0');
        m_valid_r <= '0';
        hdr_r <= '0'; done_r <= '0'; cfg_tk <= '0';
        sat_r <= '0'; err_r <= '0';
        raddr_r <= (others => '0');
      else
        cfg_tk <= '0';

        if STRICT_PRODUCER then
          assert not (start = '1' and state /= S_IDLE)
            report "attn_emit: start while busy -- the descriptor for this "
                 & "layer is being dropped, not queued"
            severity error;
          -- The output must never be withdrawn once offered.
          assert not (m_valid_r = '1' and m_ready = '0' and emit_en = '1')
            report "attn_emit: the emit pass advanced while an unaccepted "
                 & "mantissa stood at the output -- that mantissa is lost, "
                 & "not delayed"
            severity error;
          -- THE ORDERING RULE.  The header must already stand when the first
          -- mantissa is offered; see the header of this file.
          assert not (m_valid_r = '1' and hdr_r = '0')
            report "attn_emit: a mantissa is being offered while hdr_valid is "
                 & "low.  A scalar that qualifies a stream must be assigned "
                 & "STRICTLY EARLIER than the state that first raises that "
                 & "stream's valid"
            severity error;
        end if;

        -- The consumer handshake is independent of the FSM: once a mantissa is
        -- driven it stands until m_ready, whatever the unit does next.
        if m_valid_r = '1' and m_ready = '1' then
          m_valid_r <= '0';
        end if;

        case state is

          -- ================= idle: latch the descriptor ==================
          when S_IDLE =>
            if start = '1' then
              for g in 0 to NGRP-1 loop
                e_l(g) <= signed(e_grid((g+1)*EXP_W-1 downto g*EXP_W));
              end loop;
              cfg_tk <= '1';          -- RULE 2: the instant, made observable
              -- Seeded from group 0's exponent rather than a sentinel, so no
              -- exponent is unrepresentable.  A sentinel of 0 would be wrong
              -- for an all-positive e_grid, which is the common case.
              e_min  <= signed(e_grid(EXP_W-1 downto 0));
              grp    <= 1;
              amax   <= (others => '0');
              sat_r  <= '0'; err_r <= '0'; hdr_r <= '0';
              i_idx <= 0; i_grp <= 0; i_abs <= 0; drain <= 0;
              a1_v <= '0'; a2_v <= '0'; a3_v <= '0'; a4_v <= '0'; a5_v <= '0';
              raddr_r <= (others => '0');
              if NGRP = 1 then
                state <= S_SHIFTS;
              else
                state <= S_EMIN;
              end if;
            end if;

          -- ---- one narrow compare per cycle -----------------------------
          when S_EMIN =>
            if e_l(grp) < e_min then
              e_min <= e_l(grp);
            end if;
            if grp = NGRP-1 then
              grp   <= 0;
              state <= S_SHIFTS;
            else
              grp <= grp + 1;
            end if;

          -- ---- one narrow subtract per cycle ----------------------------
          -- Precomputed so neither pass ever has a subtract feeding a barrel
          -- shift, and so a per-element lookup is a bus mux and nothing more.
          when S_SHIFTS =>
            sh_v := to_integer(e_l(grp)) - to_integer(e_min);
            if sh_v < 0 then
              -- Unreachable: e_min is the minimum of the SAME latched array.
              -- Trapped rather than allowed to become a LEFT shift, which
              -- would grow an element already at the s24 rail.
              err_r <= '1';
              sh_v  := 0;
            elsif sh_v > SH_MAX then
              sh_v := SH_MAX;
            end if;
            sh_a(grp) <= to_unsigned(sh_v, SHW);
            if grp = NGRP-1 then
              grp   <= 0;
              state <= S_SCAN;
            else
              grp <= grp + 1;
            end if;

          -- ================= pass A: the aligned amax ====================
          -- stage 1 issues, the memory answers on the next edge, stage 3
          -- captures and picks up the group's shift, stage 4 aligns, stage 5
          -- takes the absolute value, stage 6 compares.
          when S_SCAN =>
            -- stage 1: the address ALONE.  The group index is REGISTERED here
            -- and carried forward; a later stage that read i_grp live would
            -- take the NEXT group's shift for the last element of each group.
            if i_abs < NTOT then
              raddr_r <= to_unsigned(i_abs, AW);
              a1_v    <= '1';
              a1_g    <= i_grp;
              if i_idx = GRP_N-1 then
                i_idx <= 0;
                if i_grp < NGRP-1 then i_grp <= i_grp + 1; end if;
              else
                i_idx <= i_idx + 1;
              end if;
              i_abs <= i_abs + 1;
            else
              a1_v <= '0';
            end if;

            -- stage 2: the memory's own registered read.  Nothing here.
            a2_v <= a1_v;
            a2_g <= a1_g;

            -- stage 3: capture, and ONE bus mux on the carried group index
            a3_v <= a2_v;
            if a2_v = '1' then
              if STRICT_PRODUCER then
                meta := false;
                for i in x_rdata'range loop
                  if x_rdata(i) /= '0' and x_rdata(i) /= '1' then
                    meta := true;
                  end if;
                end loop;
                -- A metavalue read compares equal to 0 through to_integer and
                -- would pass a value check silently.  That is the
                -- gdn_exp_capture trap, where unwritten 'U' taps compared
                -- equal on both sides and the testbench passed.
                assert not meta
                  report "attn_emit: x_rdata is not 0/1 -- the y_pre scratch "
                       & "was read before attn_gate wrote it"
                  severity error;
              end if;
              a3_x  <= signed(x_rdata);
              a3_sh <= sh_a(a2_g);
            end if;

            -- stage 4: the alignment SHIFT ALONE.  Arithmetic right, i.e. the
            -- FLOOR.  Rounding here would double-round against the pack.
            a4_v <= a3_v;
            if a3_v = '1' then
              a4_al <= shift_right(a3_x, to_integer(a3_sh));
            end if;

            -- stage 5: the absolute value ALONE.  Widened by one bit BEFORE
            -- the negate and kept wide afterwards; there is no resize here,
            -- for the reason in the header.
            a5_v <= a4_v;
            if a4_v = '1' then
              ext := resize(a4_al, IN_W+1);
              if ext < 0 then
                a5_abs <= unsigned(-ext);
              else
                a5_abs <= unsigned(ext);
              end if;
            end if;

            -- stage 6: the compare ALONE
            if a5_v = '1' then
              if a5_abs > amax then
                amax <= a5_abs;
              end if;
            end if;

            if i_abs >= NTOT then
              if drain = DEPTH_A then
                drain <= 0;
                i_idx <= 0; i_grp <= 0; i_abs <= 0;
                state <= S_FIN1;
              else
                drain <= drain + 1;
              end if;
            end if;

          -- ---- the priority encode ALONE --------------------------------
          when S_FIN1 =>
            p_msb <= msb_pos_u(amax);
            state <= S_FIN2;

          -- ---- the clamped subtract ALONE -------------------------------
          when S_FIN2 =>
            sh_v := p_msb - TARGET_MSB;
            -- msb_pos(0) = 0 makes an all-zero layer give shp = 0, which is
            -- correct: y_exp is then e_min and every mantissa is zero.
            if sh_v < 0 then sh_v := 0; end if;
            if sh_v > SHP_MAX then sh_v := SHP_MAX; end if;
            shp_r <= to_unsigned(sh_v, SHPW);
            state <= S_HDR;

          -- ---- the exponent subtract ALONE, and PUBLISH the header -------
          -- This state is what makes the ordering rule structural: y_exp and
          -- hdr_valid are assigned here, and m_valid cannot rise until six
          -- cycles into S_EMIT.  The round bias is derived here too, in
          -- parallel -- it shares no operand with the exponent subtract, so
          -- this is one level and not two.
          when S_HDR =>
            yexp_r <= e_min - resize(signed('0' & shp_r), EXP_W);
            if shp_r = 0 then
              -- round_shift(v, 0) = v exactly, which is what makes a zero bias
              -- correct rather than merely harmless.
              bias_r <= (others => '0');
            else
              bias_r <= shift_left(to_signed(1, ACC_W),
                                   to_integer(shp_r) - 1);
            end if;
            hdr_r <= '1';
            m1_v <= '0'; m2_v <= '0'; m3_v <= '0'; m4_v <= '0'; m5_v <= '0';
            m6_v <= '0';
            i_idx <= 0; i_grp <= 0; i_abs <= 0; drain <= 0;
            raddr_r <= (others => '0');
            state <= S_EMIT;

          -- ================= pass B: align, round, saturate ==============
          when S_EMIT =>
            if emit_en = '1' then
              -- stage 1: the address ALONE, group index registered
              if i_abs < NTOT then
                raddr_r <= to_unsigned(i_abs, AW);
                m1_v    <= '1';
                m1_g    <= i_grp;
                m_idx_p(0) <= i_abs;
                if i_idx = GRP_N-1 then
                  i_idx <= 0;
                  if i_grp < NGRP-1 then i_grp <= i_grp + 1; end if;
                else
                  i_idx <= i_idx + 1;
                end if;
                i_abs <= i_abs + 1;
              else
                m1_v <= '0';
              end if;

              -- stage 2: the memory's own registered read.  Nothing here.
              m2_v <= m1_v;
              m2_g <= m1_g;
              m_idx_p(1) <= m_idx_p(0);

              -- stage 3: capture, and ONE bus mux on the carried group index
              m3_v <= m2_v;
              m_idx_p(2) <= m_idx_p(1);
              if m2_v = '1' then
                m3_x  <= signed(x_rdata);
                m3_sh <= sh_a(m2_g);
              end if;

              -- stage 4: the alignment SHIFT ALONE.  The FLOOR again, and it
              -- must be bit-identical to pass A's or the peak window is a
              -- statement about a different value than the one emitted.
              m4_v <= m3_v;
              m_idx_p(3) <= m_idx_p(2);
              if m3_v = '1' then
                m4_al <= shift_right(m3_x, to_integer(m3_sh));
              end if;

              -- stage 5: the round bias ADD ALONE
              m5_v <= m4_v;
              m_idx_p(4) <= m_idx_p(3);
              if m4_v = '1' then
                m5_sum <= resize(m4_al, ACC_W) + bias_r;
              end if;

              -- stage 6: the pack SHIFT ALONE
              m6_v <= m5_v;
              m_idx_p(5) <= m_idx_p(4);
              if m5_v = '1' then
                m6_shf <= shift_right(m5_sum, to_integer(shp_r));
              end if;

              -- stage 7: the SATURATE, and drive
              if m6_v = '1' then
                rv := m6_shf;
                m_data_r  <= sat_m(rv);
                if rv /= resize(sat_m(rv), ACC_W) then
                  -- REACHABLE at the top: the peak can round to exactly
                  -- 2^(MANT_W-1).  The bottom rail is a width guard.
                  sat_r <= '1';
                end if;
                m_index_r <= m_idx_p(5);
                m_valid_r <= '1';
              end if;

              if i_abs >= NTOT then
                if drain = DEPTH_B then
                  state <= S_DONE;
                else
                  drain <= drain + 1;
                end if;
              end if;
            end if;

          -- ================= RULE 1: held, not pulsed ====================
          -- Reached only after the last mantissa has left stage 7; the
          -- handshake above then clears m_valid_r when the consumer takes it,
          -- and done_r stands until acked.  Signalling completion at
          -- production would drop the final mantissa under back-pressure.
          -- The `m_valid_r = '0'` guard is DEFENSIVE and provably redundant,
          -- which is worth stating because mutation E19 removes it and is an
          -- EQUIVALENT MUTANT.  The drain counter above lives inside
          -- `if emit_en = '1'`, and emit_en is low whenever an unaccepted
          -- mantissa stands at the output, so once the last one is driven the
          -- counter can only advance in a cycle where m_ready is high -- and
          -- that is the same cycle the handshake clears m_valid_r.  Reaching
          -- S_DONE therefore already implies the last mantissa was accepted.
          -- Verified by instrumenting the mutant: over 40 layers `done` rose
          -- with m_valid = '0' and m_cnt = 96 every single time.  Kept anyway,
          -- because the redundancy is a property of the drain gating and a
          -- later change to that gating would silently make it load-bearing.
          when S_DONE =>
            if m_valid_r = '0' then
              done_r <= '1';
              if done_ack = '1' then
                -- Do NOT clear done_r here.  The trailing assignment below
                -- clears it once the state leaves S_DONE.  An explicit clear
                -- in this branch is a LATER assignment that wins, which
                -- destroys the pulse outright whenever done_ack is tied high
                -- -- exactly the default a testbench uses.  Written and caught
                -- once already, in gdn_head_emit.
                state <= S_IDLE;
              end if;
            end if;

        end case;

        if state /= S_DONE then
          done_r <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture;
