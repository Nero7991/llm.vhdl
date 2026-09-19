-- rtl/swiglu_mem.vhd -- 2026-09-19.
--
-- MEMORY-BACKED SwiGLU WITH THE BFP PACK FOLDED IN.  rtl/swiglu.vhd's
-- arithmetic (Q12 silu(g) * u, element by element, `sigmoid_q` from
-- fixed_pkg) behind WORD-STREAM ports into block RAM, on the pattern
-- rtl/rmsnorm_rs_mem.vhd set for rmsnorm_rs, plus rtl/bfp_pack.vhd's pack
-- of the Q12 int32 results into 16-bit block-floating mantissas under ONE
-- exponent, which is the shape the D-vec region file holds.
--
-- WHY.  docs/debugging/2026-09-19_the-swiglu-on-the-card-is-a-product-with-
-- no-gate.md: the composed top's OP_VEC_SWG was a behavioural stand-in
-- `out(i) = (g(i)*u(i)) / 2**MANT_W` with no silu, and rtl/swiglu.vhd -- the
-- real, verified unit -- had no D-vec adapter because it takes the whole
-- vector on two flat N*16 ports and emits one flat N*32 port.  At the 9B
-- shape N = 12288, so a flat port is 196,608 bits and the N*32 output is
-- 393,216 bits; rtl/llama_top.vhd's `gvr` note records what a flat port of
-- that size costs (a 88,640-LUT barrel shifter on the write side alone).
-- Nothing flat and nothing 32-bit-by-N wide exists in this unit as a
-- register: the two inputs live in one 16-bit block RAM each, the output in
-- a third, and the 32-bit intermediate is never stored at all (see below).
--
-- WHAT IS BIT-IDENTICAL TO rtl/swiglu.vhd, per element:
--   * the BFP mantissa -> Qq conversion (64-bit shift_left, or round-half-up
--     shift_right with the `shift_left(1, -sh-1)` bias, then resize to 32),
--     INCLUDING its behaviour at absurd exponents.  The barrel-shift counts
--     are clamped to 64 (left) and 65 (right) and that is EXACT, not an
--     approximation: numeric_std's shift by any count >= the width is the
--     all-zero / all-sign result whatever the count, and the one count that
--     differs from those (64 on the right, where the bias `shift_left(1,63)`
--     is still non-zero) is kept distinct.  sim/tb_swiglu_mem.vhd drives an
--     exponent sweep across the whole EXP_W range against swiglu.vhd itself.
--   * `sig = sigmoid_q(v_q, Q)`, the SAME function from fixed_pkg;
--   * `silu32 = resize(shift_right(v_q * sig, Q), 32)`;
--   * `out_v  = resize(shift_right(silu32 * h2_q, Q), 32)`.
-- Those four are the four states of swiglu.vhd's per-element FSM, one
-- multiply per state, for the timing reason its S_CALC comment records.
-- Here they are four PIPELINE STAGES with the same one-multiply-per-stage
-- property, so the unit computes ONE ELEMENT PER CYCLE instead of one per
-- four.  Every element is independent (swiglu.vhd's own header says so:
-- "no cross-element state; the BFP pack is done by the consumer"), so the
-- values are identical and only the schedule differs.
--
-- WHAT IS BIT-IDENTICAL TO rtl/bfp_pack.vhd:
--   * max_abs = max over |out_v| held as an UNSIGNED 32-bit vector (so that
--     -2**31 folds as 2**31 and nothing is routed through a VHDL integer,
--     which is bfp_pack's recorded silicon trap);
--   * p = msb index of max_abs (0 for 0), shift_o = max(0, p - 14);
--   * mant = saturate16((out_v + 2**(shift_o-1)) >> shift_o), round half
--     toward +infinity, or out_v itself when shift_o = 0;
--   * o_exp = Q - shift_o.
-- The rounding rule, stated once so the Python model (tools/ref9b/
-- vec_oracle.swg_real) can be held to it: ROUND HALF UP (toward +inf) on
-- the pack, ROUND HALF UP on the input conversion, FLOOR (arithmetic right
-- shift) on the two product shifts.  Under the repo's convention
-- value = mant * 2^-exp, value = out_q * 2^-Q = (out_q >> sh) * 2^-(Q-sh),
-- so the exponent published is Q - sh; a right shift of the mantissa by sh
-- SUBTRACTS sh from the exponent, which is the rule rtl/llama_top.vhd's
-- S_DONE comment derives and matvec_core independently confirms.
--
-- TWO PASSES, AND THE INTERMEDIATE IS RECOMPUTED, NOT STORED.  bfp_pack
-- needs the max over ALL N results before it can pack ANY of them, so the
-- pack is a second pass over the data.  engine_shared.vhd keeps the N Q12
-- int32 results in a 32-bit vec_mem between swiglu and bfp_pack (12 RAMB36
-- at N = 12288).  This unit instead runs the element pipeline TWICE over
-- the same g/u banks: pass 1 folds max|out_v| and writes nothing, pass 2
-- recomputes the identical out_v (the pipeline is deterministic and reads
-- banks nothing writes between the passes) and packs it straight into the
-- 16-bit output bank.  Cost: N + pipeline cycles more per op -- 12.3 k
-- cycles at 9B, x32 FFNs, about 0.6% of a 61 M-cycle token (MEASURED token
-- length, the write-up above).  Saving: the 32-bit store, which at N =
-- 12288 is 12 of the 124.5 BRAM tiles the card has left.  BRAM is the
-- resource this design has least of after LUT, so the trade is stated.
--
-- SINGLE-PORT BANKS, NOT LANES-WAY.  rmsnorm_rs_mem banks LANES ways
-- because its element passes consume LANES elements per cycle.  This
-- datapath consumes ONE element per cycle by construction (one sigmoid, two
-- multiplies), so a LANES-way bank would feed LANES copies of that
-- datapath -- LANES times the DSPs, in a design the write-ups record as
-- DSP-bound in every congested window.  One element per cycle is already
-- 4x swiglu.vhd's own rate, and the op sits between two A jobs of
-- 12288 x 4096 that dwarf it.  So: one vec_mem per operand, one for the
-- output, a `LANES` generic deliberately absent.
--
-- READ LATENCY of o_raddr -> o_rdata is ONE EDGE, the same contract as
-- rmsnorm_rs_mem: the output bank's own registered dout IS the port, with no
-- lane select in front of it.  sim/tb_swiglu_mem.vhd MEASURES it.
--
-- `done` is a one-cycle PULSE, fired on the edge the LAST output word lands
-- in the bank, so a reader that presents o_raddr on the cycle after seeing
-- `done` reads a complete vector.  The parent (llama_top's `gsr`) converts
-- it to the level seq_vec_issue wants, as every adapter there does.
--
-- NO HARDWARE.  Synthesis and simulation only.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.fixed_pkg.all;
use work.util_pkg.all;   -- clog2

entity swiglu_mem is
  generic(
    N : positive;
    Q : integer := 12
  );
  port(
    clk     : in  std_logic;
    rst     : in  std_logic;
    -- One-cycle pulse.  g/u must be fully resident (see the parent's
    -- sequencing); g_exp/u_exp are latched HERE, on start, and never re-read.
    start   : in  std_logic;
    -- The gate operand (swiglu.vhd's hb): value = mant * 2^-g_exp.
    g_we    : in  std_logic;
    g_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    g_wdata : in  std_logic_vector(15 downto 0);
    g_exp   : in  integer;
    -- The up operand (swiglu.vhd's hb2): value = mant * 2^-u_exp.
    u_we    : in  std_logic;
    u_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    u_wdata : in  std_logic_vector(15 downto 0);
    u_exp   : in  integer;
    done    : out std_logic := '0';
    -- The packed result: value = o_rdata * 2^-o_exp.  One-edge read latency.
    o_raddr : in  std_logic_vector(clog2(N)-1 downto 0);
    o_rdata : out std_logic_vector(15 downto 0);
    -- Held from the end of pass 1 until the next start.
    o_exp   : out integer := 0;
    -- OBSERVATION ONLY: the pack shift and the max|out_v| it was derived
    -- from, held with o_exp.  A bench or a parent assertion can name the
    -- instant; nothing inside this unit reads them back.
    o_shift : out integer := 0;
    o_maxabs : out unsigned(31 downto 0) := (others => '0')
  );
end entity;

architecture rtl of swiglu_mem is
  constant LOG2N : natural := clog2(N);

  type state_t is (S_IDLE, S_P1, S_P2);
  signal state : state_t := S_IDLE;

  -- The element index presented to the two input banks.  COMBINATIONAL read
  -- address, so the bank's own output register lands the word on the edge
  -- after the one that advanced `idx`.
  signal idx    : natural range 0 to N := 0;
  signal ram_ra : std_logic_vector(LOG2N-1 downto 0);
  signal g_bq, u_bq : std_logic_vector(15 downto 0);

  -- The latched exponents.  Seam rule (1) of rtl/llama_top.vhd, applied
  -- inside the unit: read once at start, never again.
  signal ge, ue : integer := 0;

  -- The valid chain.  vf: an address was issued last cycle, so the bank
  -- output holds its word now.  va..vd: the four arithmetic stages.
  signal vf, va, vb, vc, vd : std_logic := '0';
  -- Stage A: the two Qq operands.
  signal a_vq, a_hq : signed(31 downto 0) := (others => '0');
  -- Stage B: sigmoid, operands carried.
  signal b_sig, b_vq, b_hq : signed(31 downto 0) := (others => '0');
  -- Stage C: silu, up operand carried.
  signal c_silu, c_hq : signed(31 downto 0) := (others => '0');
  -- Stage D: the Q12 result, exactly swiglu.vhd's out_v.
  signal d_out : signed(31 downto 0) := (others => '0');

  -- Pass 1's running max of |d_out|, an UNSIGNED VECTOR (bfp_pack's rule).
  signal max_abs : unsigned(31 downto 0) := (others => '0');
  signal shift_o : integer range 0 to 63 := 0;

  -- Pass 2's write side: registered, so we/addr/data reach the bank on the
  -- same edge and cannot drift apart.
  signal widx : natural range 0 to N := 0;
  signal o_we : std_logic := '0';
  signal o_wa : std_logic_vector(LOG2N-1 downto 0) := (others => '0');
  signal o_wd : std_logic_vector(15 downto 0) := (others => '0');

  -- bfp_pack.vhd's msb_pos_u, verbatim: highest set bit, 0 for 0.
  function msb_pos_u(u : unsigned) return integer is
    variable r : integer := 0;
  begin
    for i in 0 to u'length-1 loop
      if u(i) = '1' then r := i; end if;
    end loop;
    return r;
  end function;

  -- swiglu.vhd's S_CALC_A conversion, as a function so the two operands
  -- cannot be converted by two slightly different copies.  `sh = Q - exp`.
  -- The count clamps are exact; see the header.
  function to_qq(mant_raw : signed(15 downto 0); sh : integer)
    return signed is
    variable mant64 : signed(63 downto 0);
    variable bias64 : signed(63 downto 0);
    variable cl     : natural range 0 to 64;
    variable cr     : natural range 0 to 65;
  begin
    mant64 := resize(mant_raw, 64);
    if sh >= 0 then
      if sh > 64 then cl := 64; else cl := sh; end if;
      return resize(shift_left(mant64, cl), 32);
    else
      if -sh > 65 then cr := 65; else cr := -sh; end if;
      if cr >= 65 then
        -- shift_left(1, 64+) is zero: no bias, and the shift by >= width is
        -- the all-sign word.
        bias64 := (others => '0');
      else
        bias64 := shift_left(to_signed(1, 64), cr - 1);
      end if;
      return resize(shift_right(mant64 + bias64, cr), 32);
    end if;
  end function;
begin
  assert 2**LOG2N >= N
    report "swiglu_mem: clog2(N) does not cover N" severity failure;

  -- The banks.  vec_mem is the repo's forced-block SDP RAM with a registered
  -- read (rtl/vec_mem.vhd), added for exactly this trade on swiglu/bfp_pack.
  ram_ra <= std_logic_vector(to_unsigned(idx, LOG2N)) when idx < N
            else (others => '0');

  ug : entity work.vec_mem generic map(WORDS => N, W => 16)
    port map(clk => clk, we => g_we, waddr => g_waddr, raddr => ram_ra,
             din => g_wdata, dout => g_bq);
  uu : entity work.vec_mem generic map(WORDS => N, W => 16)
    port map(clk => clk, we => u_we, waddr => u_waddr, raddr => ram_ra,
             din => u_wdata, dout => u_bq);
  uo : entity work.vec_mem generic map(WORDS => N, W => 16)
    port map(clk => clk, we => o_we, waddr => o_wa, raddr => o_raddr,
             din => o_wd, dout => o_rdata);

  process(clk)
    variable prod1  : signed(63 downto 0);
    variable prod2  : signed(63 downto 0);
    variable av_u   : unsigned(31 downto 0);
    variable p_msb  : integer;
    variable sh     : integer;
    variable r34    : signed(33 downto 0);
    variable bias34 : signed(33 downto 0);
    variable mant16 : signed(15 downto 0);
    variable drained : boolean;
  begin
    if rising_edge(clk) then
      done <= '0';
      o_we <= '0';
      if rst = '1' then
        state <= S_IDLE;
        idx <= 0; widx <= 0;
        vf <= '0'; va <= '0'; vb <= '0'; vc <= '0'; vd <= '0';
        max_abs <= (others => '0');
      else
        -- ---- the element pipeline, running whenever an address was issued.
        -- Each stage is exactly one of swiglu.vhd's S_CALC states.
        va <= vf;
        if vf = '1' then
          a_vq <= to_qq(signed(g_bq), Q - ge);
          a_hq <= to_qq(signed(u_bq), Q - ue);
        end if;

        vb <= va;
        if va = '1' then
          b_sig <= sigmoid_q(a_vq, Q);
          b_vq  <= a_vq;
          b_hq  <= a_hq;
        end if;

        vc <= vb;
        if vb = '1' then
          prod1  := b_vq * b_sig;
          c_silu <= resize(shift_right(prod1, Q), 32);
          c_hq   <= b_hq;
        end if;

        vd <= vc;
        if vc = '1' then
          prod2 := c_silu * c_hq;
          d_out <= resize(shift_right(prod2, Q), 32);
        end if;

        -- ---- the two passes.
        drained := (vf = '0' and va = '0' and vb = '0' and vc = '0'
                    and vd = '0');
        case state is
          when S_IDLE =>
            if start = '1' then
              ge <= g_exp; ue <= u_exp;
              max_abs <= (others => '0');
              idx <= 0; widx <= 0;
              state <= S_P1;
            end if;

          -- Pass 1: issue every element once, fold |out_v| into max_abs.
          when S_P1 =>
            if idx < N then
              vf  <= '1';
              idx <= idx + 1;
            else
              vf <= '0';
            end if;
            if vd = '1' then
              if d_out(31) = '1' then av_u := unsigned(-d_out);
              else                    av_u := unsigned( d_out);
              end if;
              if av_u > max_abs then max_abs <= av_u; end if;
            end if;
            -- Every element issued and the pipeline empty: max_abs holds the
            -- max over all N (the last fold landed on the previous edge).
            if idx = N and drained then
              p_msb := msb_pos_u(max_abs);
              sh := p_msb - 14; if sh < 0 then sh := 0; end if;
              shift_o  <= sh;
              o_exp    <= Q - sh;
              o_shift  <= sh;
              o_maxabs <= max_abs;
              idx   <= 0;
              widx  <= 0;
              state <= S_P2;
            end if;

          -- Pass 2: recompute, pack, write.  bfp_pack's S_PACK, verbatim in
          -- effect: round half up by shift_o, saturate to int16.
          when S_P2 =>
            if idx < N then
              vf  <= '1';
              idx <= idx + 1;
            else
              vf <= '0';
            end if;
            if vd = '1' then
              r34 := resize(d_out, 34);
              if shift_o /= 0 then
                bias34 := shift_left(to_signed(1, 34), shift_o - 1);
                r34    := shift_right(r34 + bias34, shift_o);
              end if;
              if    r34 > to_signed( 32767, 34) then
                mant16 := to_signed( 32767, 16);
              elsif r34 < to_signed(-32768, 34) then
                mant16 := to_signed(-32768, 16);
              else
                mant16 := resize(r34, 16);
              end if;
              o_we <= '1';
              o_wa <= std_logic_vector(to_unsigned(widx, LOG2N));
              o_wd <= std_logic_vector(mant16);
              widx <= widx + 1;
            end if;
            -- The last word's write is REGISTERED on the edge widx reaches N
            -- and lands in the bank on the next one; `done` fires on that
            -- next edge, so a reader that acts on `done` sees the whole
            -- vector.
            if o_we = '1' and unsigned(o_wa) = N-1 then
              done  <= '1';
              state <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
