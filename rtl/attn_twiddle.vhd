-- rtl/attn_twiddle.vhd
-- Subsystem C, sites R1/R2: stateless generation of the IMROPE twiddle pair
-- for one position, one (cos, sin) per rotated dim pair, one pair per cycle.
--
-- WHAT IT COMPUTES.  A position is latched; then NPAIR pairs stream out in j
-- order:
--
--   phi(j) : u32 = low32( pos * IMROPE_W(j) )              site R1, exact mod 2^32
--   idx          = phi(31 downto FRACW)   frac = phi(FRACW-1 downto 0)
--   sin(j) : s16 = SIN_TBL(idx) + ( (SIN_TBL(idx+1) - SIN_TBL(idx)) * frac ) asr FRACW
--   cos(j) : s16 = the same lookup evaluated at phi + 2^30  -- an exact quarter turn
--
-- The u32 phase is TURNS, not radians: IMROPE_W(j) is
-- round(2^32 * base^(-j/NPAIR) / (2*pi)), so the whole angle reduction is the
-- natural wrap of a 32-bit product and there is no range reduction anywhere.
--
-- Bit-exact against ref/attn_twiddle_vec.c, whose seven oracles share none of
-- this unit's machinery: the table against libm to half an ulp and against its
-- own exact symmetries, the phase against the real fractional turn computed
-- with fmod inside a bound DERIVED from the W rounding, sin and cos against
-- libm inside a three-term derived bound, the CHORD DIRECTION swept
-- exhaustively over every table interval, Pythagoras on the pair, and pos = 0
-- and the grid points as exact equalities.  The reference was mutation-tested
-- before this file existed: **15 of 15 killed, no survivors.**
--
-- WHY THIS IS NOT rope_rom_pkg.vhd.  That package is a PER-POSITION table and
-- it is what v1.0 uses at 512 positions.  At the 27B geometry the same shape is
-- MAXCTX x NPAIR pairs x 2 tables x 16 b = 58 RAMB36 at 2K context and about
-- 930 at the 32K cap, which the C spec rejects outright.  This unit is 32 u32
-- constants plus one 1,024-entry table and does not scale with the context
-- length at all.  It is also the reason attn_rope can be built now: the twiddle
-- was the only thing standing between the verified step-4 quantizer and the
-- front of the pipeline.
--
-- WHY THE INDEPENDENT ORACLE EXISTS, which is why this unit was built and
-- attn_qk_norm was not.  attn_qk_norm wraps rmsnorm_rs and has no C
-- counterpart, so the only available check is a replay of the same algorithm.
-- Here sin and cos are TRANSCENDENTALS: every value can be checked against
-- libm at the exact real angle inside a bound derived from three named
-- sources, and the exact invariants are properties of the sine function and of
-- the table's symmetry rather than of this arithmetic.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   start / pos / cfg_taken      THE PRODUCER IS STALLABLE -- attn_ctrl issues
--                                one job per (layer, position) and waits.
--                                RULE 2: pos is read for the whole job, so it
--                                is LATCHED at start and the instant is made
--                                observable by cfg_taken.  A producer that
--                                advanced it mid-job would corrupt the tail of
--                                the twiddle stream and nothing else -- the
--                                gdn_emit_chain head-23 shape.
--
--                                AND THE ORDERING RULE (subsystem B's
--                                2026-08-27 gdn_conv defect): pos is latched
--                                in S_IDLE and tw_valid cannot rise until
--                                DEPTH cycles into S_RUN, so the scalar is
--                                published before every beat it qualifies.
--
--   tw_valid / tw_phi / tw_cos / Producer (this unit) IS stallable and HOLDS.
--   tw_sin / tw_j / tw_ready     The consumer is attn_rope, which takes one
--                                pair per rotated slot and is then busy with
--                                the unrotated tail; a pair it does not take
--                                must WAIT, not vanish.  tw_ready DEFAULTS TO
--                                '1', and that default is exactly why the hold
--                                must be built and tested: a consumer that
--                                never stalls cannot tell a held valid from a
--                                pulsed one.
--
--   done / done_ack              RULE 1: HELD until acked, never pulsed, and
--                                raised only after the LAST pair has been
--                                ACCEPTED.
--
-- WHY tw_phi IS PUBLISHED.  Observability only; the datapath does not read it.
-- It is site R1's entire output, and every trig value derives from it, so a
-- wrong phase and a wrong table look identical in cos and sin alone.
-- attn_kv_quant's write-up records the same lesson from the other direction --
-- its mantissas were self-consistent with the wrong exponent and only the
-- SEPARATE exponent check caught the defect.  The cost is carrying 32 bits
-- through five stages, about 160 flops.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.  Eight
-- stages, one listed operation each; the sin and cos paths run side by side
-- and read the same source rather than each other:
--
--   1  one NPAIR-way bus mux on IMROPE_W
--   2  the MULTIPLY pos * W
--   3  the low-32 slice (wiring) and the quarter-turn ADD, in parallel
--   4  index and fraction split -- wiring only
--   5  four TBL-way table bus muxes on two indices
--   6  two table-delta SUBTRACTS, in parallel
--   7  two MULTIPLIES delta*frac, in parallel
--   8  two interpolation ADDS with a constant slice, in parallel
--
-- FOUR DSP48E2 TILES, DERIVED FROM OPERAND WIDTHS AND NOT MEASURED.  No Vivado
-- was run for this file.  Stage 2 is 16x32 unsigned, i.e. 17x33 signed, and 33
-- exceeds 27, so it takes 2 tiles.  Stage 7 is DLT_W x FRACW = 9x22, i.e.
-- 9x23 signed with the wide operand on the 27 side, so 1 tile each.  That is
-- 2 + 2 = 4, which is what the C DSP skeleton books the twiddle at, by the
-- same derivation -- and the 9 is MEASURED from the table rather than taken
-- from the operand range, which would have said 17.  Both operands of the interpolation are narrow: the
-- 2026-08-26 gdn_silu note records that narrowing the delta ALONE changes no
-- DSP count because the multiplicand stays wide.
--
-- NO SATURATION IS NEEDED, and that is a proof rather than an omission.  For
-- frac in [0, 2^FRACW) the interpolation returns a value between SIN_TBL(idx)
-- and SIN_TBL(idx+1) inclusive: with delta >= 0 the floored term lies in
-- [0, delta-1], and with delta < 0 it lies in [delta, 0].  Both endpoints are
-- table entries, so the result never leaves [-32767, 32767].  A width guard is
-- kept under STRICT_PRODUCER rather than in the datapath.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only indices and the pair number.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;                -- clog2
use work.imrope_pkg.all;              -- IMROPE_W, SIN_TBL

entity attn_twiddle is
  generic(
    -- N_ROT / 2.  64 rotated dims in both target models, so 32 pairs.
    NPAIR : positive := 32;
    -- Sine table entries over one full turn.
    TBL   : positive := 1024;
    -- The declared position width.  MAXCTX is 2048 in the C spec and every
    -- width here is stated against POS_W rather than against that, so a
    -- context change moves one generic.
    POS_W : positive := 16;
    -- Q15 twiddles.
    Q_W   : positive := 16;
    PHI_W : positive := 32;
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the job.  RULE 2: pos latched, cfg_taken observable. -----------
    start     : in  std_logic;                 -- one-cycle request
    pos       : in  unsigned(POS_W-1 downto 0);
    cfg_taken : out std_logic;                 -- one cycle, at the latch
    busy      : out std_logic;

    -- ---- the twiddle stream, in j order.  Held until tw_ready. ---------
    tw_valid : out std_logic;
    tw_j     : out unsigned(clog2(NPAIR)-1 downto 0);
    tw_cos   : out signed(Q_W-1 downto 0);
    tw_sin   : out signed(Q_W-1 downto 0);
    -- Observability only; see the header.  Site R1's whole output.
    tw_phi   : out unsigned(PHI_W-1 downto 0);
    tw_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. ----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at start.  An interpolation left the Q15 range, which
    -- the header proves cannot happen.  A width guard, not a policy.
    err : out std_logic
  );
end entity;

architecture rtl of attn_twiddle is

  constant IDX_W  : integer := clog2(TBL);            -- 10
  constant FRACW  : integer := PHI_W - IDX_W;         -- 22
  -- The widest |SIN_TBL(i+1) - SIN_TBL(i)|, computed FROM THE TABLE rather
  -- than from the operand range.  The operand-range bound is Q_W+1 = 17 bits,
  -- but the table is a smooth sine over TBL points, so the true maximum is
  -- 201 at i = 0 (where sin' = 1 and the step is 2*pi/TBL) and 9 signed bits
  -- hold it.  Written this way for a MEASURED reason: at DLT_W = Q_W + 1 the
  -- mutation "delta one bit narrow" SURVIVED every configuration, because 16
  -- bits still held 201 comfortably -- the width was decorative.  Derived from
  -- the table it is load-bearing, and a table change cannot silently outgrow
  -- it.  Same construction as attn_softmax's rom_delta_w, and the same reason.
  function sin_delta_w return integer is
    variable m : integer := 0;
    variable d : integer;
    variable w : integer := 2;
  begin
    for i in 0 to TBL-1 loop
      d := SIN_TBL((i+1) mod TBL) - SIN_TBL(i);
      if d < 0 then d := -d; end if;
      if d > m then m := d; end if;
    end loop;
    -- signed: the field must hold -m through +m
    while 2**(w-1) - 1 < m loop w := w + 1; end loop;
    return w;
  end function;
  constant DLT_W  : integer := sin_delta_w;           -- 9
  constant PRD_W  : integer := DLT_W + FRACW + 1;     -- 40, signed x signed
  constant JW     : integer := clog2(NPAIR);
  -- An exact quarter turn.  sin(x + pi/2) = cos(x), and a quarter of 2^PHI_W
  -- is exact in binary, which is the entire reason the cosine needs no second
  -- table and no second constant.
  constant QUARTER : unsigned(PHI_W-1 downto 0)
    := to_unsigned(2**(PHI_W-2), PHI_W);
  constant DEPTH : integer := 8;

  constant Q_MAX : signed(Q_W-1 downto 0)
    := not shift_left(to_signed(-1, Q_W), Q_W-1);

  type state_t is (S_IDLE, S_RUN, S_DRAIN, S_DONE);
  signal state : state_t := S_IDLE;

  signal pos_l : unsigned(POS_W-1 downto 0) := (others => '0');
  signal j_iss : integer range 0 to NPAIR := 0;

  signal v : std_logic_vector(1 to DEPTH) := (others => '0');
  type j_pipe_t is array (1 to DEPTH) of integer range 0 to NPAIR-1;
  signal j_p : j_pipe_t := (others => 0);

  -- stage registers
  signal s1_w  : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s2_pr : unsigned(POS_W+PHI_W-1 downto 0) := (others => '0');
  signal s3_ps, s3_pc : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s4_is, s4_ic : unsigned(IDX_W-1 downto 0) := (others => '0');
  signal s4_fs, s4_fc : unsigned(FRACW-1 downto 0) := (others => '0');
  signal s4_phi : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s5_slo, s5_shi, s5_clo, s5_chi : signed(Q_W-1 downto 0)
       := (others => '0');
  signal s5_fs, s5_fc : unsigned(FRACW-1 downto 0) := (others => '0');
  signal s5_phi : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s6_sd, s6_cd : signed(DLT_W-1 downto 0) := (others => '0');
  signal s6_slo, s6_clo : signed(Q_W-1 downto 0) := (others => '0');
  signal s6_fs, s6_fc : unsigned(FRACW-1 downto 0) := (others => '0');
  signal s6_phi : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s7_sp, s7_cp : signed(PRD_W-1 downto 0) := (others => '0');
  signal s7_slo, s7_clo : signed(Q_W-1 downto 0) := (others => '0');
  signal s7_phi : unsigned(PHI_W-1 downto 0) := (others => '0');
  signal s8_sin, s8_cos : signed(Q_W-1 downto 0) := (others => '0');
  signal s8_phi : unsigned(PHI_W-1 downto 0) := (others => '0');

  signal cfg_tk : std_logic := '0';
  signal done_r : std_logic := '0';
  signal err_r  : std_logic := '0';

  signal adv    : std_logic;
  signal pipe_e : std_logic;

begin

  -- The whole pipeline advances together or not at all.  A stall that froze
  -- the ISSUE but let the stages run would drop pairs silently: every value
  -- would stay in range and only the count would be short, which is the
  -- gdn_emit_chain shape where three configurations were all bit-exact and
  -- differed only in how many columns they dropped.
  adv    <= '1' when (v(DEPTH) = '0' or tw_ready = '1') else '0';
  pipe_e <= '1' when v = (v'range => '0') else '0';

  cfg_taken <= cfg_tk;
  busy      <= '0' when state = S_IDLE else '1';
  tw_valid  <= v(DEPTH);
  tw_j      <= to_unsigned(j_p(DEPTH), JW);
  tw_cos    <= s8_cos;
  tw_sin    <= s8_sin;
  tw_phi    <= s8_phi;
  done      <= done_r;
  err       <= err_r;

  process(clk)
    variable lo_v, hi_v : integer;
    variable sd_v, cd_v : signed(Q_W downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state  <= S_IDLE;
        v      <= (others => '0');
        j_iss  <= 0;
        cfg_tk <= '0';
        done_r <= '0';
        err_r  <= '0';
      else
        cfg_tk <= '0';

        if STRICT_PRODUCER then
          assert not (start = '1' and state /= S_IDLE)
            report "attn_twiddle: start while busy -- pos is latched for the "
                 & "whole job and this descriptor is being dropped, not queued"
            severity error;
          -- The output must never be withdrawn once offered.
          assert not (v(DEPTH) = '1' and tw_ready = '0' and adv = '1')
            report "attn_twiddle: the pipeline advanced while an unaccepted "
                 & "pair stood at the output -- that pair is lost, not delayed"
            severity error;
        end if;

        -- =================================================================
        -- The datapath.  Every stage is gated on adv, so a stalled output
        -- freezes the whole thing and nothing is overwritten in flight.
        -- =================================================================
        if adv = '1' then
          v(1) <= '0';
          if state = S_RUN and j_iss < NPAIR then
            v(1)   <= '1';
            j_p(1) <= j_iss;
            -- ---- 1: one NPAIR-way bus mux ALONE ------------------------
            s1_w   <= to_unsigned(IMROPE_W(j_iss), PHI_W);
            j_iss  <= j_iss + 1;
          end if;
          for i in 2 to DEPTH loop
            v(i)   <= v(i-1);
            j_p(i) <= j_p(i-1);
          end loop;

          -- ---- 2: the MULTIPLY ALONE.  UNSIGNED, so no sign extension --
          if v(1) = '1' then
            s2_pr <= pos_l * s1_w;
          end if;

          -- ---- 3: the low-PHI_W slice (wiring) and the quarter-turn ADD,
          -- in parallel.  Both read s2_pr and neither reads the other, so
          -- this is one level and not two.  The slice IS site R1's
          -- "low32", exact mod 2^PHI_W; a wider product is simply not
          -- looked at, which is what makes the wrap free.
          if v(2) = '1' then
            s3_ps <= s2_pr(PHI_W-1 downto 0);
            s3_pc <= s2_pr(PHI_W-1 downto 0) + QUARTER;
          end if;

          -- ---- 4: index and fraction split.  Wiring only. --------------
          if v(3) = '1' then
            s4_is  <= s3_ps(PHI_W-1 downto FRACW);
            s4_fs  <= s3_ps(FRACW-1 downto 0);
            s4_ic  <= s3_pc(PHI_W-1 downto FRACW);
            s4_fc  <= s3_pc(FRACW-1 downto 0);
            s4_phi <= s3_ps;
          end if;

          -- ---- 5: four TBL-way bus muxes on two indices ----------------
          -- The +1 wraps by construction: the index is IDX_W bits and the
          -- table is 2^IDX_W entries, so idx+1 truncated to IDX_W is the
          -- modulo the reference writes as (idx+1) mod TBL.  There is no
          -- sentinel entry and no separate wrap test.
          if v(4) = '1' then
            s5_slo <= to_signed(SIN_TBL(to_integer(s4_is)), Q_W);
            s5_shi <= to_signed(SIN_TBL(to_integer(s4_is + 1)), Q_W);
            s5_clo <= to_signed(SIN_TBL(to_integer(s4_ic)), Q_W);
            s5_chi <= to_signed(SIN_TBL(to_integer(s4_ic + 1)), Q_W);
            s5_fs  <= s4_fs;
            s5_fc  <= s4_fc;
            s5_phi <= s4_phi;
          end if;

          -- ---- 6: the two table deltas ALONE, in parallel --------------
          -- The difference is formed at FULL width and then SLICED to DLT_W.
          -- It is NOT `resize(s5_shi, DLT_W) - resize(s5_slo, DLT_W)`: that
          -- narrows each s16 OPERAND to 9 bits before subtracting, and
          -- numeric_std's resize on a signed keeps the sign bit and drops the
          -- top magnitude bits, so every table entry outside +-255 is
          -- destroyed and the difference is garbage that happens to be small.
          -- Written that way first, and it produced errors of 120 to 210
          -- counts on cos and sin -- the size of a delta, which is the tell.
          -- This is the THIRD appearance of the numeric_std narrowing trap in
          -- subsystem C (attn_kv_quant's abs, attn_softmax's offset) and the
          -- first where the operands, not the result, were the ones narrowed.
          --
          -- The SLICE is exact because the VALUE fits: the widest table step
          -- is 201, which needs 9 signed bits, and taking the low DLT_W bits
          -- of a two's-complement number is exact whenever the value fits
          -- DLT_W bits.  The STRICT_PRODUCER assertion below is what makes
          -- that a checked premise rather than a comment -- if SIN_TBL is ever
          -- regenerated at a different amplitude or a coarser grid, it fires
          -- instead of the value silently truncating.
          if v(5) = '1' then
            sd_v := resize(s5_shi, Q_W+1) - resize(s5_slo, Q_W+1);
            cd_v := resize(s5_chi, Q_W+1) - resize(s5_clo, Q_W+1);
            if STRICT_PRODUCER then
              assert sd_v = resize(sd_v(DLT_W-1 downto 0), Q_W+1)
                     and cd_v = resize(cd_v(DLT_W-1 downto 0), Q_W+1)
                report "attn_twiddle: a SIN_TBL step does not fit DLT_W bits. "
                     & "DLT_W is computed from the table by sin_delta_w, so "
                     & "this means the table in imrope_pkg is not the table "
                     & "that width was derived from"
                severity error;
            end if;
            s6_sd  <= sd_v(DLT_W-1 downto 0);
            s6_cd  <= cd_v(DLT_W-1 downto 0);
            s6_slo <= s5_slo;
            s6_clo <= s5_clo;
            s6_fs  <= s5_fs;
            s6_fc  <= s5_fc;
            s6_phi <= s5_phi;
          end if;

          -- ---- 7: the two MULTIPLIES ALONE, in parallel ----------------
          -- DLT_W x (FRACW+1) signed = 17 x 23, one DSP48E2 tile each.
          if v(6) = '1' then
            s7_sp  <= s6_sd * signed('0' & s6_fs);
            s7_cp  <= s6_cd * signed('0' & s6_fc);
            s7_slo <= s6_slo;
            s7_clo <= s6_clo;
            s7_phi <= s6_phi;
          end if;

          -- ---- 8: the two interpolation ADDS ALONE, in parallel --------
          -- The asr FRACW is a CONSTANT SLICE of a two's-complement value,
          -- which IS the floor -- dropping the low FRACW bits of a signed
          -- number is exactly floor(v / 2^FRACW), including for negative v.
          -- That is the mode the reference's chord-direction oracle pins,
          -- and it is why no round bias appears anywhere in this unit.
          if v(7) = '1' then
            s8_sin <= s7_slo + resize(s7_sp(PRD_W-1 downto FRACW), Q_W);
            s8_cos <= s7_clo + resize(s7_cp(PRD_W-1 downto FRACW), Q_W);
            s8_phi <= s7_phi;
          end if;

          if v(DEPTH-1) = '1' then
            -- A width guard, not a policy.  The header proves the result lies
            -- between the two table entries, so it cannot leave the Q15 range.
            lo_v := to_integer(s7_slo + resize(s7_sp(PRD_W-1 downto FRACW), Q_W));
            hi_v := to_integer(s7_clo + resize(s7_cp(PRD_W-1 downto FRACW), Q_W));
            if lo_v > to_integer(Q_MAX) or lo_v < -to_integer(Q_MAX)
               or hi_v > to_integer(Q_MAX) or hi_v < -to_integer(Q_MAX) then
              err_r <= '1';
            end if;
          end if;
        end if;

        -- =================================================================
        -- The control FSM.  Deliberately OUTSIDE the adv gate: a stalled
        -- output must not freeze the completion handshake, only the data.
        -- =================================================================
        case state is

          when S_IDLE =>
            if start = '1' then
              pos_l  <= pos;          -- RULE 2: latched, never read live
              cfg_tk <= '1';          -- RULE 2: the instant, made observable
              j_iss  <= 0;
              err_r  <= '0';
              state  <= S_RUN;
            end if;

          when S_RUN =>
            if j_iss = NPAIR and adv = '1' then
              state <= S_DRAIN;
            end if;

          -- ---- the job is finished when the PIPELINE is empty ----------
          -- Not when the last pair was issued.  Signalling completion with
          -- pairs still in flight publishes a stream missing its tail, in
          -- range and the right shape -- attn_softmax's S_FIN note.
          when S_DRAIN =>
            if pipe_e = '1' then
              state <= S_DONE;
            end if;

          -- ================= RULE 1: held, not pulsed ==================
          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then
              -- Do NOT clear done_r here.  The trailing assignment below
              -- clears it once the state leaves S_DONE.  An explicit clear in
              -- this branch is a LATER assignment that wins, which destroys
              -- the pulse outright whenever done_ack is tied high -- exactly
              -- the default a testbench uses.  Caught once in gdn_head_emit.
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
