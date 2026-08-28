-- rtl/attn_rescale_skel.vhd -- SKELETON, NOT AN IMPLEMENTATION.
--
-- WHAT THIS IS.  rtl/attn_lane_skel.vhd measured that dropping the rescale
-- mode off the MAC lane halves the lane's DSP cost, 2 to 1
-- (docs/2026-08-27_attn-lane-rescale-pricing.md).  That number cannot be
-- multiplied by the lane count, because moving rescale off the lane means
-- building a SHARED rescale unit and a mux to feed it, and neither has ever
-- been priced.  The net is
--
--     MACS x 1 DSP  -  (MACS / LANES_SERVED) x (one shared unit)  -  mux
--
-- and the middle term is what this file exists to measure.  At LANES_SERVED = 2
-- a shared unit costing 2 DSP makes the saving EXACTLY ZERO.  So the whole
-- decision reduces to one question -- can the shared unit be built in ONE
-- DSP48E2? -- and to a second the earlier write-up left open: is LANES_SERVED
-- really capped at 2?
--
-- It follows the established pricing method (micro_b_lane, micro_rmsn_narrow,
-- attn_lane_skel): real operand SHAPES, operands registered so they land in
-- the DSP tile's own AREG/BREG, control driven by a free-running counter so
-- synthesis cannot prove a mode dead and fold it away, and a digest so nothing
-- is pruned.  A skeleton that folds reports a number that is not the design's.
--
-- ================= THE ACCEPTANCE TEST, AND IT IS ANCHORED =================
--
-- A pricing skeleton's only evidence that it prices the right thing is that it
-- reproduces a known measurement.  A known one exists here, and it is a strong
-- one:
--
--   C spec 2.6, MEASURED 2026-08-23 and confirmed ROUTED 2026-08-24: the
--   rescale multiply is "a 36 x 13 product that does not fit one DSP48E2
--   (36 > 27), so it needs 2", measured at DSP = 2 with an independent
--   DSP48E2 census agreeing and USE_MULT = MULTIPLY on both tiles.  The same
--   2 was reproduced by attn_lane_skel's RESCALE_ON_LANE = true branch on
--   2026-08-27.
--
-- SEQ_MULT = false is exactly that product, standing alone rather than muxed
-- against the score and PV modes.  IT MUST SYNTHESISE TO 2 DSP.  If it does
-- not, this skeleton is wrong and the SEQ_MULT = true number means nothing.
-- Note this anchor is INDEPENDENT of attn_lane_skel: it is the spec's own
-- 2026-08-23 lane measurement, taken before either skeleton existed.
--
-- ============== THE HYPOTHESIS SEQ_MULT = true IS TESTING ==============
--
-- The lane needs the rescale product in ONE cycle, because on the lane it
-- shares a datapath whose other two modes are the inner loop.  A DEDICATED
-- unit has no such constraint: spec 3.1 puts the rescale in its own pass, and
-- "rescale and MAC never run in the same cycle" (spec 2.6).  So the dedicated
-- unit may take TWO cycles per accumulator and split the wide operand:
--
--     o = a_hi * 2^SPLIT + a_lo,   a_hi signed (ACC_W-SPLIT+1) bits
--                                  a_lo unsigned SPLIT bits
--     o * f = (a_hi * f) * 2^SPLIT + (a_lo * f)
--
-- At SPLIT = 17 that is a 19x14 and an 18x14 product, both of which fit ONE
-- 27x18 DSP48E2 tile, with the recombination a shift-and-add in FABRIC.  That
-- is deliberately the right way round for this die: the coordinator's
-- 2026-08-27 note puts DSP at ~75% after ROWS_IF = 48 was forced and LUT at
-- ~65%, so trading DSP for LUT is worth MORE than it was this morning.
--
-- THE ARITHMETIC IS NOT ASSUMED, IT IS PROVED.  That decomposition is not in
-- the spec; it is arithmetic introduced here, and the sign handling on a_lo is
-- the classic place to get it wrong.  A skeleton that synthesises to 1 DSP
-- while computing the wrong function prices a structure nobody can build.  So
-- ref/attn_rescale_vec.c states the identity as ORACLE 5, pins the chunk
-- WIDTHS (int64 wraparound makes the recombination alone blind to a logical
-- shift -- mutation S6 survived every equality until the width check was
-- added), pins the DSP port fit as ORACLE 9, and was mutation-tested at 12 of
-- 15 killed BEFORE this file was written.  sim/tb_attn_rescale.vhd then checks
-- BOTH branches of this skeleton bit-exactly against that golden, so the
-- SEQ_MULT = true structure is known to compute the same function as the
-- SEQ_MULT = false one before either number is quoted.
--
-- ===================== THE SECOND OPEN QUESTION, THE MUX =====================
--
-- The "at most 2 lanes" bound comes from spec 2.6's measurement that the
-- accumulator read mux is linear to ACC_N = 16 and breaks above it (32
-- measures 543 LUT against a predicted 478; the 32:1 mux exhausts the F7/F8
-- chain and needs a third fabric level).  With ACC_N = 8 per lane, two lanes
-- is 16 entries and sits exactly at the knee.
--
-- But that reading assumes the shared unit muxes 16 accumulator ENTRIES flat.
-- It need not.  Each lane ALREADY has its own ACC_N:1 read mux -- spec 2.6's
-- routed critical path is "accumulator -> 16:1 read mux -> 3:1 operand mux",
-- so it exists regardless -- and during a rescale pass the lane is idle, so
-- that mux is free to use.  The shared unit then needs only a LANES_SERVED:1
-- mux over ACC_W bits, and the 16-entry knee never enters.  MUX_FLAT sweeps
-- the two readings:
--
--   MUX_FLAT = true    a flat (LANES_SERVED x ACC_N):1 mux over ACC_W.  The
--                      conservative reading, the one that produces the cap of
--                      2, and the number to quote if the lane's own mux turns
--                      out not to be reusable.
--   MUX_FLAT = false   a LANES_SERVED:1 mux over ACC_W, the lane's existing
--                      ACC_N:1 mux reused and therefore NOT charged here.
--
-- At MUX_FLAT = false the skeleton reads only LANES_SERVED of the acc_bus
-- entries and synthesis prunes the rest.  THAT PRUNING IS THE INTENDED
-- MODELLING, not the skeleton folding: the unread entries are selected by a
-- mux that already exists in the lane and is already paid for.  It is called
-- out here because "the tool pruned most of a port" is exactly what a folding
-- skeleton also looks like, and the two must not be confused.
--
-- ========================= HOW TO PRICE IT =========================
--
-- OOC synthesis on xcvu33p-fsvh2104-2L-e at 3.333 ns via sim/ooc_micro.tcl,
-- DSP48E2 census reconciled against the utilisation count, over:
--
--     SEQ_MULT     in {false, true}      false MUST give 2 DSP
--     MUX_FLAT     in {true, false}
--     LANES_SERVED in {2, 4, 8}          answers the ratio question
--
-- The exact invocations, so the sweep is a copy-paste rather than a
-- reconstruction.  Twelve runs; the FIRST one is the acceptance test and the
-- rest are void if it does not print DSP = 2.
--
--   V=vivado; T=sim/ooc_micro.tcl; P=xcvu33p-fsvh2104-2L-e
--   S=rtl/attn_rescale_skel.vhd
--
--   # 1. THE ANCHOR.  Must be DSP = 2.  Run this alone and read it first.
--   $V -mode batch -source $T -tclargs $P 3.333 attn_rescale_skel \
--        g:SEQ_MULT=false g:MUX_FLAT=true g:LANES_SERVED=2 $S
--
--   # 2. the hypothesis, and the two sweeps
--   for sm in false true; do for mf in true false; do for ls in 2 4 8; do
--     $V -mode batch -source $T -tclargs $P 3.333 attn_rescale_skel \
--        g:SEQ_MULT=$sm g:MUX_FLAT=$mf g:LANES_SERVED=$ls $S
--   done; done; done
--
-- The DSP48E2 census must be reconciled against the utilisation count in every
-- run, and USE_MULT must read MULTIPLY -- a tile recruited as a wide adder is
-- not a multiplier and would flatter the two-pass branch specifically, since
-- that is the branch with a wide fabric add next to it.
--
-- Do not read Fmax from this.  Both lane branches already clear the binding
-- clock by over 170 MHz at the real voltage (A binds the die at 172.6 MHz
-- post-route at 0.717 V), so timing is not a term in this decision, and any
-- Fmax figure taken at 0.85 V would be misleading anyway
-- (docs/debugging/2026-08-27_tuning-at-the-wrong-voltage.md: 305.4 MHz at
-- 0.85 V against 232.2 MHz at 0.717 V on one netlist, with the binding path
-- changing identity between them).
--
-- ============ WHAT THIS FILE DELIBERATELY DOES NOT MODEL ============
--
-- so its number is a FLOOR, in the same way attn_lane_skel's is:
--   - the accumulator registers themselves, which STAY in the lane files and
--     are already counted there (spec 2.6: FF = 182 + 36.4 x ACC_N per lane)
--   - the write-back path to the lane files, which is a demux of enables
--     rather than of data and should be small, but is not zero
--   - the schedule.  SEQ_MULT = true takes TWO cycles per accumulator, so a
--     rescale pass over LANES_SERVED lanes takes 2 x LANES_SERVED x ACC_N
--     cycles against ACC_N when the rescale is on the lane and all lanes run
--     in parallel: 8 cycles becomes 32 at LANES_SERVED = 2.  y_valid exposes
--     the cadence so that cost is visible rather than buried.  Whether that
--     latency is affordable is attn_ctrl's question, not this file's, and the
--     DSP number must not be quoted without it.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity attn_rescale_skel is
  generic(
    -- FALSE is THE ANCHOR: the single-cycle ACC_W x F_W product the spec
    --       measured at 2 DSP on 2026-08-23.  It must reproduce 2.
    -- TRUE  is the hypothesis: two passes through one tile, expected 1 DSP
    --       plus a fabric shift-and-add.
    SEQ_MULT     : boolean  := false;
    -- TRUE  charges a flat (LANES_SERVED x ACC_N):1 mux over ACC_W.
    -- FALSE charges only LANES_SERVED:1, the lane's own read mux reused.
    MUX_FLAT     : boolean  := true;
    LANES_SERVED : positive := 2;
    ACC_N        : positive := 8;    -- spec 3.1: 1536/192 accumulators per lane
    ACC_W        : positive := 36;   -- spec 2.6, bound 2^30 + margin
    F_W          : positive := 13;   -- spec 5c, f <= 4096
    RSH          : natural  := 12;   -- spec 5d, half toward +infinity
    -- The chunk split.  A GENERIC because it is genuinely free: reference
    -- mutation S12 showed a split of 18 recombines exactly and fits the DSP
    -- ports just as well, so nothing pins 17 except that it is the DSP48E2's
    -- own cascade granularity.  Sweep it if the fabric adder turns out to
    -- matter.  ORACLE 9 is what rejects a split too wide to fit a tile.
    SPLIT        : positive := 17
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- Free-running enable.  No handshake, for the same reason attn_lane_skel
    -- has none: the real unit is driven by the array's central schedule, and
    -- adding a handshake here would price control logic the design does not
    -- have.
    en  : in std_logic;

    -- The accumulator sources, flattened.  Always declared at the FLAT width
    -- so one entity serves both mux topologies; at MUX_FLAT = false only
    -- LANES_SERVED of these are read and synthesis prunes the rest, which is
    -- the intended modelling (see the header).
    acc_bus : in std_logic_vector(LANES_SERVED*ACC_N*ACC_W-1 downto 0);
    f_in    : in unsigned(F_W-1 downto 0);

    -- The rounded result.  A real port, because sim/tb_attn_rescale.vhd checks
    -- it bit-exactly against ref/attn_rescale_vec.c -- the 1 DSP number is
    -- worthless unless the structure that produces it computes the right
    -- function.  Combinational from an existing register, so it costs no FF,
    -- and it is structurally identical in both branches so the DSP and LUT
    -- DELTAS are uncontaminated by it.
    y_out   : out signed(ACC_W-1 downto 0);
    -- The cadence: every cycle at SEQ_MULT = false, every OTHER cycle at
    -- SEQ_MULT = true.  Exposed so the schedule cost is measurable and cannot
    -- be quietly dropped from the decision.
    y_valid : out std_logic;

    -- XOR-fold digest, so the datapath cannot be pruned.  Never read by
    -- anything real.
    digest  : out std_logic_vector(31 downto 0)
  );
end entity;

architecture skel of attn_rescale_skel is

  -- The A operand width.  This is the whole point of SEQ_MULT: at false it is
  -- ACC_W = 36, which exceeds the DSP48E2's 27-bit A port and forces a second
  -- tile; at true it is the wider of the two chunks and one tile suffices.
  function hi_bits return positive is begin return ACC_W - SPLIT + 1; end function;
  function lo_bits return positive is begin return SPLIT + 1; end function;
  function a_width return positive is
  begin
    if not SEQ_MULT then return ACC_W; end if;
    if hi_bits > lo_bits then return hi_bits; else return lo_bits; end if;
  end function;

  constant AW  : positive := a_width;          -- 36 at false, 19 at true
  constant BW  : positive := F_W + 1;          -- signed carrier for u13
  -- The product-accumulator width, DELIBERATELY THE SAME IN BOTH BRANCHES so
  -- the round-and-digest stage is width-identical and the LUT delta measures
  -- the multiplier structure rather than a downstream width change.
  constant PW  : positive := ACC_W + F_W + 1;  -- 50
  constant NSRC : positive := LANES_SERVED*ACC_N;
  -- How many acc_bus entries this configuration actually reads.
  function n_read return positive is
  begin
    if MUX_FLAT then return NSRC; else return LANES_SERVED; end if;
  end function;
  constant NRD : positive := n_read;

  -- Free-running entry counter.  Synthesis cannot prove any source dead, so
  -- the mux does not fold.  This is the load-bearing trick in the method.
  --
  -- It advances every cycle at SEQ_MULT = false and every OTHER cycle at
  -- SEQ_MULT = true, because the two passes must see the SAME accumulator.
  -- The first version incremented unconditionally, which fed the high pass a
  -- different entry from the low pass and would have priced a structure that
  -- computes nothing.  Caught by bit-exact simulation against the golden,
  -- which is precisely why a pricing skeleton whose arithmetic is new needs a
  -- functional testbench and not only a digest.
  signal ent : unsigned(31 downto 0) := (others => '0');
  -- The pass toggle, only meaningful at SEQ_MULT = true.
  signal ph  : std_logic := '0';
  -- The phase CARRIED ALONGSIDE the data, rather than re-derived from the
  -- counter's parity at the consuming stage.  Deriving it modularly is correct
  -- only if you get the pipeline depth exactly right, and it fails silently if
  -- you do not; carrying it is the same pattern attn_twiddle and attn_rope use
  -- and it cannot drift when a stage is added.
  signal ph_pipe   : std_logic_vector(1 to 2) := (others => '0');
  signal sum_done  : std_logic := '0';

  signal a_reg : signed(AW-1 downto 0) := (others => '0');
  signal b_reg : signed(BW-1 downto 0) := (others => '0');
  signal p_reg : signed(AW+BW-1 downto 0) := (others => '0');
  signal acc_p : signed(PW-1 downto 0) := (others => '0');
  signal y_reg : signed(ACC_W-1 downto 0) := (others => '0');
  signal v_reg : std_logic := '0';
  signal dig_r : std_logic_vector(31 downto 0) := (others => '0');

  -- One acc_bus entry, by index.
  function acc_at(b : std_logic_vector; i : natural) return signed is
  begin
    return signed(b((i+1)*ACC_W-1 downto i*ACC_W));
  end function;

begin

  process(clk)
    variable sel  : integer range 0 to NSRC-1;
    variable o_v  : signed(ACC_W-1 downto 0);
    variable a_v  : signed(AW-1 downto 0);
    variable r_v  : signed(PW-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ent      <= (others => '0');
        ph       <= '0';
        ph_pipe  <= (others => '0');
        sum_done <= '0';
        a_reg   <= (others => '0');
        b_reg   <= (others => '0');
        p_reg   <= (others => '0');
        acc_p   <= (others => '0');
        y_reg   <= (others => '0');
        v_reg   <= '0';
        dig_r   <= (others => '0');
      elsif en = '1' then
        if SEQ_MULT then
          ph <= not ph;
          if ph = '1' then ent <= ent + 1; end if;   -- advance after the high pass
        else
          ent <= ent + 1;
        end if;
        ph_pipe(1) <= ph;
        ph_pipe(2) <= ph_pipe(1);

        -- ---- S0: the read mux, then the operand mux, REGISTERED ----------
        -- Registered so a_reg/b_reg land in the tile's AREG/BREG.  Spec 2.6
        -- measured that as worth 94 MHz on the routed 64-lane array at
        -- identical DSP, and the registers exist in the tile whether they are
        -- used or not, so the stage is free.  It also keeps mux and multiply
        -- in separate stages, which the project's timing rule requires.
        --
        -- At MUX_FLAT = false the modulus is LANES_SERVED, so only that many
        -- entries are ever addressed and the rest of acc_bus is pruned.  The
        -- stride is ACC_N so the entries read come from DIFFERENT lanes, which
        -- is what a hierarchical mux over per-lane outputs would see.
        if MUX_FLAT then
          sel := to_integer(ent(30 downto 0)) mod NSRC;
          o_v := acc_at(acc_bus, sel);
        else
          sel := (to_integer(ent(30 downto 0)) mod LANES_SERVED) * ACC_N;
          o_v := acc_at(acc_bus, sel);
        end if;

        b_reg <= signed('0' & f_in);

        if not SEQ_MULT then
          -- THE ANCHOR.  One ACC_W x F_W product.  ACC_W = 36 exceeds the
          -- 27-bit A port, so this must come out at 2 DSP.
          a_reg <= resize(o_v, AW);
        else
          -- THE HYPOTHESIS.  Two passes over one tile.  a_lo is UNSIGNED --
          -- taking it signed is the classic error and is what reference
          -- mutation S5 plants.  a_hi is an ARITHMETIC shift; S6 shows the
          -- recombination alone cannot tell that apart in int64, which is why
          -- the reference pins the chunk WIDTHS and why a_hi is carried here
          -- in exactly hi_bits bits.
          if ph = '0' then
            a_v := resize(signed('0' & unsigned(o_v(SPLIT-1 downto 0))), AW);
          else
            a_v := resize(o_v(ACC_W-1 downto SPLIT), AW);
          end if;
          a_reg <= a_v;
        end if;

        -- ---- S1: the multiply, alone in its stage ------------------------
        p_reg <= a_reg * b_reg;

        -- ---- S2a: recombine -----------------------------------------------
        -- ph_pipe(2) is the phase of the sample sitting in p_reg RIGHT NOW.
        if not SEQ_MULT then
          acc_p    <= resize(p_reg, PW);
          sum_done <= '1';
        elsif ph_pipe(2) = '0' then
          -- the LOW pass lands first
          acc_p    <= resize(p_reg, PW);
          sum_done <= '0';
        else
          -- the HIGH pass is added shifted left by SPLIT.  The shift is
          -- wiring; the add is fabric, and that is the DSP-for-LUT trade this
          -- whole variant is making -- the right way round for a die at ~75%
          -- DSP and ~65% LUT.
          acc_p    <= acc_p + shift_left(resize(p_reg, PW), SPLIT);
          sum_done <= '1';
        end if;

        -- ---- S2b: round and publish ---------------------------------------
        -- Round half toward +infinity by RSH.  A shift and an add, kept out
        -- of the multiply stage per the timing rule.  Spec 5d.  acc_p and
        -- sum_done are read together and were written together, so the flag
        -- always describes the sum being rounded.
        r_v   := shift_right(acc_p + shift_left(to_signed(1, PW), RSH-1), RSH);
        v_reg <= sum_done;
        -- resize, NEVER a hardcoded slice.  attn_lane_skel carried
        -- `r_v(31 downto 0)`, a width only ONE of its branches had, so the
        -- branch the generic existed to answer was the one that could not
        -- synthesise -- it died with [Synth 8-11324] array index 31 out of
        -- range and the defect stood until 2026-08-27.  Both widths here are
        -- generic-dependent, so every conversion is width-agnostic.
        y_reg <= resize(r_v, ACC_W);
        -- Fold only COMPLETE results, which is what the real unit writes back.
        -- Still every other cycle at worst, so nothing folds away.
        if sum_done = '1' then
          dig_r <= dig_r xor std_logic_vector(resize(unsigned(r_v), 32));
        end if;
      end if;
    end if;
  end process;

  y_out   <= y_reg;
  y_valid <= v_reg;
  digest  <= dig_r;

end architecture;
