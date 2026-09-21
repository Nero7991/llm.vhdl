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
-- LANES-WAY BANKS, DEFAULT 1.  TRACK SWGFAST, 2026-09-20.  This unit used
-- to argue here that a LANES generic was "deliberately absent": one element
-- per cycle is already 4x swiglu.vhd's rate, a LANES-way bank feeds LANES
-- copies of a datapath with two 32x32 multiplies and a sigmoid, and the op
-- sits between two A jobs that dwarf it.  All three are still true, and the
-- generic exists anyway, because the card MEASURED the op: 61,473 cycles
-- per OP_VEC_SWG at N = 12288 (hw/fk33/results/card_swg_2026-09-20/profile/
-- profile_flat_tok0.txt), 5.0 cycles per element, of which this unit's two
-- passes are 2N + 12 = 24,588 (MEASURED by sim/tb_swiglu_mem.vhd's
-- SWGFAST_CYCLES line) and the other 3N are llama_top's serial G load, U
-- load and write-back, one word per cycle each.  The unit's share is the
-- only one a unit change can touch, and LANES is how it is touched:
--   * word i lives in bank (i mod LANES) at offset (i / LANES), the same
--     layout rtl/rmsnorm_bf_mem.vhd uses, decoded from the low LB bits of
--     the write address and selected by the low LB bits of o_raddr;
--   * the four-stage pipeline is replicated per lane; each lane computes
--     exactly the function above on its own element, so every value is the
--     one the LANES = 1 unit computes for that element;
--   * pass 1 keeps ONE RUNNING MAX PER LANE (so the per-cycle fold path is
--     the LANES = 1 path, unchanged) and combines them in one extra state,
--     S_MAX, that exists only when LANES > 1.  A maximum is order-independent,
--     so the combined value is bit-identical to the serial fold;
--   * pass 2 packs LANES words per cycle into LANES output banks.
-- Both passes are NB = N / LANES beats, so start -> done is 2*NB + 12 at
-- LANES = 1 and 2*NB + 13 above it: 24,588 / 12,301 / 6,157 cycles at
-- N = 12288 for LANES = 1 / 2 / 4 (MEASURED, the bench line above).
-- LANES must be a power of two that divides N; both are pinned with the
-- out-of-range-natural idiom because Vivado ignores `severity failure`.
-- BRAM is neutral in bits (LANES banks of N/LANES words); the cost is LANES
-- copies of the sigmoid and the two multiplies.  sim/tb_swiglu_mem.vhd runs
-- the identity bench at LANES 1, 2 and 4 and `cmp`s the read-out dumps.
--
-- At LANES = 1 the elaborated design is the 2026-09-19 unit: one bank per
-- operand, no write decode, no read select (o_rdata is bank 0's registered
-- dout directly), no S_MAX, the same cycle count.
--
-- WIDE_IO, DEFAULT FALSE.  TRACK GSRWIDE, 2026-09-20.  LANES makes the two
-- COMPUTE passes NB beats each; it cannot touch the LOAD and the STORE,
-- which are the parent's and are 3N one-element-per-cycle beats
-- (docs/2026-09-20_d-side-vector-traffic.md section 4.2: 36,870 of the
-- card's 61,473-cycle VEC_SWG step against this unit's 24,588).  That is
-- the other 60% of the step, and it is not a property of this unit's ports
-- either -- it is `llama_top`'s region file having a LANES-wide group port
-- with per-lane enables that carries TWO operand regions at one address,
-- and both D-vec adapters being wired to the ONE-ELEMENT port beside it.
--
-- WIDE_IO is this unit's half of moving the SwiGLU onto that port:
--   * `gw_we` writes ONE WORD INTO EVERY BANK in a single beat -- lane k is
--     element `gw_addr + k`, which lives in bank k at offset
--     `gw_addr / LANES` by the layout above, so a LANES-aligned group maps
--     one-to-one onto the banks and NO shuffle, mask or decode is needed.
--     G and U arrive together on `gw_g`/`gw_u` because the region file's
--     group READ returns both operand regions in the same cycle.
--   * `o_gdata` is the LANES banks' own registered douts, concatenated,
--     addressed by the SAME `o_raddr` the narrow read uses.  There is no
--     second read address and no second read port: the banks are read once
--     and the narrow port merely selects one of the words the wide port
--     publishes whole.  The one-edge latency contract is therefore
--     literally the same contract, not an analogous one.
--
-- WIDE_IO REPLACES THE WORD PORTS, IT DOES NOT SIT BESIDE THEM.  With it
-- true `g_we`/`g_waddr`/`g_wdata` and their u twins drive nothing, so
-- neither bank write port grows a mux and the false configuration is
-- textually the 2026-09-19/SWGFAST unit.  A parent uses one face or the
-- other; a parent that drives the wrong one loads nothing, which is loud.
-- `sim/tb_swiglu_mem.vhd` runs the identity bench through the WIDE face at
-- LANES 1, 2, 4 and 8 against the same `swiglu -> vec_mem -> bfp_pack`
-- reference, and checks `o_gdata` lane by lane against it as well as
-- `o_rdata`, so both faces are held to an independent model.
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
    Q : integer := 12;
    -- Elements per cycle in both passes.  A power of two dividing N.  1 is
    -- the 2026-09-19 unit exactly; see the header.
    LANES : positive := 1;
    -- Load through `gw_*` and read back through `o_gdata`, LANES elements a
    -- beat, instead of the one-word `g_*`/`u_*`/`o_rdata` face.  FALSE is
    -- the shipping unit and elaborates no extra logic at all; see the
    -- header.  The two faces are exclusive by construction.
    WIDE_IO : boolean := false
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
    -- ---- THE WIDE FACE.  WIDE_IO only; see the header.  Every port has a
    -- default so a parent built against the 2026-09-19 entity still
    -- elaborates without naming them.
    --
    -- ONE BEAT = LANES CONSECUTIVE ELEMENTS OF BOTH OPERANDS.  `gw_addr` is
    -- the ELEMENT address of lane 0 and MUST be a multiple of LANES; lane k
    -- carries element `gw_addr + k`.  The unit does not check the alignment
    -- because it has no way to refuse -- the parent's elaboration pin does
    -- (`CHK_SWG_WIDE` in rtl/llama_top.vhd), and N mod LANES = 0 is pinned
    -- here, so every beat of a 0..N-1 sweep is aligned by construction and
    -- there is no partial final group in this unit at any N.
    gw_we   : in  std_logic := '0';
    gw_addr : in  std_logic_vector(clog2(N)-1 downto 0) := (others => '0');
    gw_g    : in  std_logic_vector(LANES*16-1 downto 0) := (others => '0');
    gw_u    : in  std_logic_vector(LANES*16-1 downto 0) := (others => '0');
    -- The LANES banks at the offset `o_raddr` selects, concatenated, lane k
    -- = element `o_raddr - (o_raddr mod LANES) + k`.  Same one-edge
    -- latency as `o_rdata`, because it is the same read of the same banks.
    -- All zeros when WIDE_IO is false.
    o_gdata : out std_logic_vector(LANES*16-1 downto 0) := (others => '0');
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
  constant LB    : natural := clog2(LANES);      -- bank-index width
  constant NB    : natural := N / LANES;         -- beats per pass
  constant AB    : natural := clog2(NB);         -- per-bank address width

  -- ELABORATION PINS (out-of-range natural: an error in GHDL and Vivado).
  -- LANES divides N; LANES is a power of two; the per-bank address is
  -- exactly the element address minus the bank index (two-sided).
  constant bad_lanes_divide : natural := 0 - (N mod LANES);
  constant bad_lanes_pow2   : natural := LANES - 2**LB;
  constant bad_ab_narrow    : natural := AB - (LOG2N - LB);
  constant bad_ab_wide      : natural := (LOG2N - LB) - AB;

  type state_t is (S_IDLE, S_P1, S_MAX, S_P2);
  signal state : state_t := S_IDLE;

  -- The beat index presented to the input banks.  COMBINATIONAL read
  -- address, so the bank's own output register lands the word on the edge
  -- after the one that advanced `idx`.
  signal idx    : natural range 0 to NB := 0;
  signal ram_ra : std_logic_vector(AB-1 downto 0);
  type sl16a is array(0 to LANES-1) of std_logic_vector(15 downto 0);
  signal g_bq, u_bq, o_bq : sl16a;
  signal g_bwe, u_bwe : std_logic_vector(LANES-1 downto 0) := (others => '0');
  -- The banks' write address and per-bank write datum, driven by exactly one
  -- of the two faces (see WIDE_IO in the header).  Naming them makes the
  -- FALSE arm a rename of the expressions the file already had rather than a
  -- mux with a constant select.
  signal gb_wa, ub_wa : std_logic_vector(AB-1 downto 0);
  signal gb_wd, ub_wd : sl16a;
  signal o_rsel : std_logic_vector(LB downto 0) := (others => '0');

  -- The latched exponents.  Seam rule (1) of rtl/llama_top.vhd, applied
  -- inside the unit: read once at start, never again.
  signal ge, ue : integer := 0;

  -- The valid chain, shared by every lane.  vf: an address was issued last
  -- cycle, so the bank outputs hold their words now.  va..vd: the four
  -- arithmetic stages.
  signal vf, va, vb, vc, vd : std_logic := '0';
  type s32a is array(0 to LANES-1) of signed(31 downto 0);
  type u32a is array(0 to LANES-1) of unsigned(31 downto 0);
  -- Stage A: the two Qq operands.
  signal a_vq, a_hq : s32a := (others => (others => '0'));
  -- Stage B: sigmoid, operands carried.
  signal b_sig, b_vq, b_hq : s32a := (others => (others => '0'));
  -- Stage C: silu, up operand carried.
  signal c_silu, c_hq : s32a := (others => (others => '0'));
  -- Stage D: the Q12 result, exactly swiglu.vhd's out_v, per lane.
  signal d_out : s32a := (others => (others => '0'));

  -- Pass 1's running max of |d_out| PER LANE, UNSIGNED VECTORS (bfp_pack's
  -- rule), and the combined max the shift is derived from.
  signal lmax    : u32a := (others => (others => '0'));
  signal max_abs : unsigned(31 downto 0) := (others => '0');
  signal shift_o : integer range 0 to 63 := 0;

  -- Pass 2's write side: registered, so we/addr/data reach the banks on the
  -- same edge and cannot drift apart.  One enable and one address for all
  -- LANES banks; one datum per bank.
  signal widx : natural range 0 to NB := 0;
  signal o_we : std_logic := '0';
  signal o_wa : std_logic_vector(AB-1 downto 0) := (others => '0');
  signal o_wd : sl16a := (others => (others => '0'));

  -- bfp_pack.vhd's msb_pos_u, verbatim: highest set bit, 0 for 0.
  function msb_pos_u(u : unsigned) return integer is
    variable r : integer := 0;
  begin
    for i in 0 to u'length-1 loop
      if u(i) = '1' then r := i; end if;
    end loop;
    return r;
  end function;

  -- The max over the lane maxes.  Order-independent, so bit-identical to
  -- the serial fold whatever the lane count.
  function max_of(a : u32a) return unsigned is
    variable m : unsigned(31 downto 0) := (others => '0');
  begin
    for l in 0 to LANES-1 loop
      if a(l) > m then m := a(l); end if;
    end loop;
    return m;
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
  assert N mod LANES = 0 and LANES = 2**LB
    report "swiglu_mem: LANES must be a power of two dividing N"
    severity failure;

  -- The banks.  vec_mem is the repo's forced-block SDP RAM with a registered
  -- read (rtl/vec_mem.vhd), added for exactly this trade on swiglu/bfp_pack.
  -- Word i lives in bank (i mod LANES) at offset (i / LANES): the low LB
  -- bits of the element address pick the bank, the rest is the offset.
  ram_ra <= std_logic_vector(to_unsigned(idx, AB)) when idx < NB
            else (others => '0');

  -- ---- THE WRITE FACE.  Exactly one of these two generates elaborates, so
  -- neither bank write port carries a mux in either configuration.
  gnarrow : if not WIDE_IO generate
    gb_wa <= g_waddr(LOG2N-1 downto LB);
    ub_wa <= u_waddr(LOG2N-1 downto LB);
    gnl : for k in 0 to LANES-1 generate
      gb_wd(k) <= g_wdata;
      ub_wd(k) <= u_wdata;
      gsel1 : if LANES = 1 generate
        g_bwe(0) <= g_we;
        u_bwe(0) <= u_we;
      else generate
        g_bwe(k) <= g_we when unsigned(g_waddr(LB-1 downto 0)) = k else '0';
        u_bwe(k) <= u_we when unsigned(u_waddr(LB-1 downto 0)) = k else '0';
      end generate;
    end generate;
  end generate;

  gwide : if WIDE_IO generate
    -- ONE BEAT, EVERY BANK.  Lane k is element `gw_addr + k`; with
    -- `gw_addr` a multiple of LANES that element is bank k at offset
    -- `gw_addr / LANES`, which is `gw_addr(LOG2N-1 downto LB)` -- the SAME
    -- slice the narrow face takes, because the low LB bits it drops are the
    -- lane index and they are zero on an aligned beat.  So there is one
    -- write address for all LANES banks and no decode at all.
    gb_wa <= gw_addr(LOG2N-1 downto LB);
    ub_wa <= gw_addr(LOG2N-1 downto LB);
    gwl : for k in 0 to LANES-1 generate
      g_bwe(k) <= gw_we;
      u_bwe(k) <= gw_we;
      gb_wd(k) <= gw_g((k+1)*16-1 downto k*16);
      ub_wd(k) <= gw_u((k+1)*16-1 downto k*16);
    end generate;
  end generate;

  gbank : for k in 0 to LANES-1 generate
    ug : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => g_bwe(k),
               waddr => gb_wa, raddr => ram_ra,
               din => gb_wd(k), dout => g_bq(k));
    uu : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => u_bwe(k),
               waddr => ub_wa, raddr => ram_ra,
               din => ub_wd(k), dout => u_bq(k));
    uo : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => o_we, waddr => o_wa,
               raddr => o_raddr(LOG2N-1 downto LB),
               din => o_wd(k), dout => o_bq(k));
  end generate;

  -- ---- THE WIDE READ.  The banks' own registered douts, concatenated.  No
  -- second read address, no second port, no select: `o_rdata` below picks
  -- one of exactly these words.
  gord : if WIDE_IO generate
    gol : for k in 0 to LANES-1 generate
      o_gdata((k+1)*16-1 downto k*16) <= o_bq(k);
    end generate;
  else generate
    o_gdata <= (others => '0');
  end generate;

  -- The output read: a LANES-to-1 select registered in PARALLEL with the
  -- banks' own output registers, both from the same combinational o_raddr,
  -- so the one-edge latency contract holds at every LANES.  At LANES = 1
  -- the select is the constant 0 and o_rdata is bank 0's dout directly.
  process(clk) begin
    if rising_edge(clk) then
      if LANES = 1 then
        o_rsel <= (others => '0');
      else
        o_rsel <= std_logic_vector(resize(unsigned(o_raddr(LB-1 downto 0)),
                                          LB+1));
      end if;
    end if;
  end process;
  o_rdata <= o_bq(to_integer(unsigned(o_rsel)));

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

    -- The pack shift from a settled max: bfp_pack's rule, once, whichever
    -- state reaches it.
    procedure settle(mx : unsigned(31 downto 0)) is
      variable pm : integer;
      variable s  : integer;
    begin
      pm := msb_pos_u(mx);
      s := pm - 14; if s < 0 then s := 0; end if;
      shift_o  <= s;
      o_exp    <= Q - s;
      o_shift  <= s;
      o_maxabs <= mx;
      idx   <= 0;
      widx  <= 0;
      state <= S_P2;
    end procedure;
  begin
    if rising_edge(clk) then
      done <= '0';
      o_we <= '0';
      if rst = '1' then
        state <= S_IDLE;
        idx <= 0; widx <= 0;
        vf <= '0'; va <= '0'; vb <= '0'; vc <= '0'; vd <= '0';
        lmax <= (others => (others => '0'));
        max_abs <= (others => '0');
      else
        -- ---- the element pipeline, running whenever an address was issued.
        -- Each stage is exactly one of swiglu.vhd's S_CALC states, per lane.
        va <= vf;
        if vf = '1' then
          for l in 0 to LANES-1 loop
            a_vq(l) <= to_qq(signed(g_bq(l)), Q - ge);
            a_hq(l) <= to_qq(signed(u_bq(l)), Q - ue);
          end loop;
        end if;

        vb <= va;
        if va = '1' then
          for l in 0 to LANES-1 loop
            b_sig(l) <= sigmoid_q(a_vq(l), Q);
            b_vq(l)  <= a_vq(l);
            b_hq(l)  <= a_hq(l);
          end loop;
        end if;

        vc <= vb;
        if vb = '1' then
          for l in 0 to LANES-1 loop
            prod1     := b_vq(l) * b_sig(l);
            c_silu(l) <= resize(shift_right(prod1, Q), 32);
            c_hq(l)   <= b_hq(l);
          end loop;
        end if;

        vd <= vc;
        if vc = '1' then
          for l in 0 to LANES-1 loop
            prod2    := c_silu(l) * c_hq(l);
            d_out(l) <= resize(shift_right(prod2, Q), 32);
          end loop;
        end if;

        -- ---- the two passes.
        drained := (vf = '0' and va = '0' and vb = '0' and vc = '0'
                    and vd = '0');
        case state is
          when S_IDLE =>
            if start = '1' then
              ge <= g_exp; ue <= u_exp;
              lmax <= (others => (others => '0'));
              idx <= 0; widx <= 0;
              state <= S_P1;
            end if;

          -- Pass 1: issue every beat once, fold |out_v| into each lane's
          -- running max.
          when S_P1 =>
            if idx < NB then
              vf  <= '1';
              idx <= idx + 1;
            else
              vf <= '0';
            end if;
            if vd = '1' then
              for l in 0 to LANES-1 loop
                if d_out(l)(31) = '1' then av_u := unsigned(-d_out(l));
                else                       av_u := unsigned( d_out(l));
                end if;
                if av_u > lmax(l) then lmax(l) <= av_u; end if;
              end loop;
            end if;
            -- Every beat issued and the pipeline empty: the lane maxes hold
            -- the max over all N (the last fold landed on the previous
            -- edge).  One lane: settle now, the 2026-09-19 schedule.  More:
            -- combine the lanes first, in S_MAX, so the per-cycle fold path
            -- above stays a single compare per lane.
            if idx = NB and drained then
              if LANES = 1 then
                settle(lmax(0));
              else
                max_abs <= max_of(lmax);
                state   <= S_MAX;
              end if;
            end if;

          when S_MAX =>
            settle(max_abs);

          -- Pass 2: recompute, pack, write.  bfp_pack's S_PACK, verbatim in
          -- effect: round half up by shift_o, saturate to int16, per lane.
          when S_P2 =>
            if idx < NB then
              vf  <= '1';
              idx <= idx + 1;
            else
              vf <= '0';
            end if;
            if vd = '1' then
              for l in 0 to LANES-1 loop
                r34 := resize(d_out(l), 34);
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
                o_wd(l) <= std_logic_vector(mant16);
              end loop;
              o_we <= '1';
              o_wa <= std_logic_vector(to_unsigned(widx, AB));
              widx <= widx + 1;
            end if;
            -- The last beat's write is REGISTERED on the edge widx reaches
            -- NB and lands in the banks on the next one; `done` fires on
            -- that next edge, so a reader that acts on `done` sees the whole
            -- vector.
            if o_we = '1' and unsigned(o_wa) = NB-1 then
              done  <= '1';
              state <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
