-- rtl/attn_lane_skel.vhd -- SKELETON, NOT AN IMPLEMENTATION.
--
-- WHAT THIS IS.  Subsystem C's MAC lane is the only replicated element in the
-- design, so it is the only term in C's DSP budget that scales with the
-- parallelism generic.  Everything else in C is a fixed cost.  This file
-- prices the lane and nothing else: it computes no attention, it has no
-- accumulator file, and its outputs are a digest.  It exists so that
-- `2 x MACS` can be replaced by a measured number, and so that the ONE open
-- question in C's DSP budget -- whether the rescale mode must live on the lane
-- -- can be answered by synthesis rather than argued.
--
-- It follows the project's established pricing method (`micro_b_lane`,
-- `micro_rmsn_narrow`): real multiply SHAPES, operands registered, control
-- driven by a free-running counter so synthesis cannot prove which mode is
-- live and fold the others away, and an XOR-fold digest so nothing is pruned.
-- A skeleton that folds reports a number that is not the design's.
--
-- THE THREE OPERAND SHAPES, from the C spec's numeric contract
-- (docs/superpowers/specs/2026-08-21-gated-attention-design.md 3.1, 3.2):
--
--   score mode    q s16 x k s8       -- q is the normed/roped int16 mantissa,
--                                       k is the int8 KV-cache mantissa
--   PV mode       e u13 x v s8       -- e is the EXP_ROM weight (<= 4096),
--                                       v_aligned is the right-shifted int8
--   rescale mode  acc s36 x f u13    -- site 5d, o' = round_shift(o*f, 12)
--
-- WHY THE MODE SET IS THE WHOLE QUESTION.  A DSP48E2 multiplier is 27x18
-- signed.  score and PV both fit ONE tile with room to spare.  rescale does
-- not: 36 > 27, so that mode alone forces a second tile, and it forces it on
-- EVERY lane because the rescale pass sweeps every accumulator.  C spec 2.6
-- measured the three-mode lane at 2 DSP on 2026-08-23 and confirmed it routed
-- at 2 DSP on 2026-08-24, so `MACS = 192` is booked at 384 DSP.  The
-- two-mode lane has never been measured.  If it is 1 DSP -- which the operand
-- widths say it should be -- then moving rescale off the lanes into a smaller
-- dedicated array is worth up to ~96 DSP of a die that is at 90-92%.  See the
-- RESCALE_ON_LANE generic and the caveat with it.
--
-- NORMATIVE STRUCTURE, not an optimisation.  C spec 2.6's MEASURED 2026-08-24
-- block: with combinational operand muxes the routed 64-lane array made
-- 246 MHz; with the muxes REGISTERED, so they land in the DSP tile's own
-- AREG/BREG, the same array made 340 MHz at the same 128 DSP and 5% fewer
-- LUT.  The registers exist in the tile whether they are used or not, so the
-- stage is free.  This skeleton registers the operands for that reason, and a
-- DSP48E2 census on the result must show AREG/BREG = 1 or the number does not
-- describe the design that will be built.
--
-- This also satisfies the project's timing rule directly: mux and multiply are
-- two of {barrel shift, wide add, wide compare, bus mux, multiply} and are
-- here in SEPARATE stages.  The unit that violated that rule held at
-- 117.2 MHz; splitting the stages took it to 300.8 MHz.
--
--   S0  operand mux        registered into AREG/BREG
--   S1  multiply           one DSP op
--   S2  round + digest     stands in for the accumulator write-back
--
-- HOW TO PRICE IT.  OOC synthesis on xcvu33p-fsvh2104-2L-e at 3.333 ns via
-- sim/ooc_micro.tcl, DSP48E2 census reconciled against the utilisation count,
-- swept over RESCALE_ON_LANE in {true, false}.  The true branch must reproduce
-- the measured 2 DSP; if it does not, the skeleton is wrong and the false
-- branch's number means nothing.  Reproducing a known measurement is the only
-- evidence a skeleton can offer that it prices the right thing.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT MODEL, so its number is a FLOOR:
--   - the accumulator file and its read mux (C spec 2.6 measures that
--     separately as LUT = 158 + 10.0 x ACC_N, FF = 182 + 36.4 x ACC_N)
--   - the per-head 32:1 score adder trees (fabric, 0 DSP by the A
--     adder-tree-reclaim precedent)
--   - the broadcast fanout of k, v_aligned, e and f, which C spec 3.13 item 2
--     names as the unmeasured Fmax risk at 192 lanes
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity attn_lane_skel is
  generic(
    -- TRUE  reproduces the shipped three-mode lane C spec 2.6 measured at
    --       2 DSP.  Rescale runs on the lane, so a rescale pass costs
    --       ACC_N cycles (8 at MACS = 192) and needs no accumulator to leave
    --       its own lane.
    -- FALSE prices the two-mode lane.  It should be 1 DSP.  Adopting it
    --       requires a dedicated rescale array, and that array must read
    --       accumulators ACROSS lane files: C spec 2.6 measured the read mux
    --       going non-linear above 16 entries (32 measures 543 LUT against a
    --       predicted 478, the F7/F8 chain exhausted), so a rescale unit may
    --       serve at most 2 lanes' files.  That caps the saving well below
    --       the naive arithmetic.  DO NOT quote the false branch's DSP number
    --       as a saving without pricing that mux.
    RESCALE_ON_LANE : boolean := true;
    ACC_W           : positive := 36;   -- C spec 2.6, bound 2^30 + 4 b margin
    E_W             : positive := 13;   -- EXP_ROM weight, e_p <= 4096
    Q_W             : positive := 16;   -- normed/roped Q mantissa
    K_W             : positive := 8     -- KV cache mantissa
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- Free-running enable.  There is no handshake here ON PURPOSE: this is a
    -- pricing skeleton, and adding one would add control logic that the real
    -- lane does not have (the real lane is driven by the array's central
    -- schedule, which cannot stall mid-slot -- see the entity comment in
    -- rtl/attn_c_ports_skel.vhd for what that costs at the interfaces).
    en   : in std_logic;

    q_in : in signed(Q_W-1 downto 0);
    k_in : in signed(K_W-1 downto 0);
    e_in : in unsigned(E_W-1 downto 0);
    v_in : in signed(K_W-1 downto 0);
    a_in : in signed(ACC_W-1 downto 0);
    f_in : in unsigned(E_W-1 downto 0);

    -- XOR-fold digest.  Stands in for the accumulator write-back so the
    -- product cannot be pruned.  Never read by anything real.
    digest : out std_logic_vector(31 downto 0)
  );
end entity;

architecture skel of attn_lane_skel is

  -- The A operand is sized by the widest mode present.  This is the whole
  -- point of the generic: at RESCALE_ON_LANE = true it is ACC_W = 36, which
  -- exceeds the DSP48E2's 27-bit A port and forces a second tile.  At false it
  -- is Q_W = 16 and one tile suffices.
  function a_width return positive is
  begin
    if RESCALE_ON_LANE then return ACC_W; else return Q_W; end if;
  end function;

  constant AW : positive := a_width;
  constant BW : positive := E_W + 1;   -- signed carrier for the u13 operands

  -- Free-running mode counter.  Synthesis cannot prove any mode dead, so no
  -- operand path folds away.  This is the load-bearing trick in the method:
  -- a skeleton driven by a constant mode prices one multiplier, not a lane.
  signal mode_cnt : unsigned(1 downto 0) := (others => '0');

  signal a_reg  : signed(AW-1 downto 0)      := (others => '0');
  signal b_reg  : signed(BW-1 downto 0)      := (others => '0');
  signal p_reg  : signed(AW+BW-1 downto 0)   := (others => '0');
  signal dig_r  : std_logic_vector(31 downto 0) := (others => '0');

begin

  -- S0: operand mux, REGISTERED.  These two registers are AREG/BREG.  Moving
  -- them into the fabric is what cost 94 MHz on the routed 64-lane array.
  -- S1: the multiply, alone in its stage.
  -- S2: round and fold.
  process(clk)
    variable a_v : signed(AW-1 downto 0);
    variable b_v : signed(BW-1 downto 0);
    variable r_v : signed(AW+BW-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        mode_cnt <= (others => '0');
        a_reg    <= (others => '0');
        b_reg    <= (others => '0');
        p_reg    <= (others => '0');
        dig_r    <= (others => '0');
      elsif en = '1' then
        mode_cnt <= mode_cnt + 1;

        -- ---- S0 -----------------------------------------------------------
        a_v := (others => '0');
        b_v := (others => '0');
        case to_integer(mode_cnt) is
          when 0 =>                                   -- score: q s16 x k s8
            a_v := resize(q_in, AW);
            b_v := resize(k_in, BW);
          when 1 =>                                   -- PV: e u13 x v s8
            a_v := resize(signed('0' & e_in), AW);
            b_v := resize(v_in, BW);
          when others =>
            if RESCALE_ON_LANE then                   -- rescale: acc s36 x f u13
              a_v := resize(a_in, AW);
              b_v := resize(signed('0' & f_in), BW);
            else
              -- Two-mode lane: the slot still exists in the schedule (the
              -- array idles during a rescale pass) but the operands are the
              -- score shapes, so no wide multiplier is inferred.
              a_v := resize(q_in, AW);
              b_v := resize(k_in, BW);
            end if;
        end case;
        a_reg <= a_v;
        b_reg <= b_v;

        -- ---- S1 -----------------------------------------------------------
        p_reg <= a_reg * b_reg;

        -- ---- S2 -----------------------------------------------------------
        -- Round-half-toward-+infinity by 12, the site 5d shape.  A shift and
        -- an add, kept out of the multiply stage per the timing rule.
        r_v   := shift_right(p_reg + to_signed(2**11, p_reg'length), 12);
        -- resize(unsigned(r_v), 32), NOT r_v(31 downto 0).  The slice is
        -- hardcoded to a width only the RESCALE_ON_LANE = true branch has: at
        -- true the A operand is ACC_W = 36 so p_reg is wide enough, but at
        -- false it is Q_W = 16 and p_reg is 24 bits, so the slice is an
        -- out-of-range index and synthesis dies with
        --   [Synth 8-11324] array index 31 out of range
        -- The false branch is the whole reason this generic exists, so the
        -- skeleton could only ever price the configuration that was already
        -- known.  resize on an unsigned drops leftmost bits when narrowing, so
        -- this is bit-identical to the slice wherever the slice was legal.
        dig_r <= dig_r xor std_logic_vector(resize(unsigned(r_v), 32));
      end if;
    end if;
  end process;

  digest <= dig_r;

end architecture;
