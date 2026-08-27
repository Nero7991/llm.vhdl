-- rtl/attn_gate.vhd
-- Subsystem C, sites 6b/6c/6d/6e: the output stage's per-element chain, from
-- the online softmax's accumulator and the raw gate word to the pre-pack
-- value.  One element per cycle.
--
-- WHAT IT COMPUTES.  Per query head a scalar pair (p, r) and one exponent are
-- latched; then N elements stream through:
--
--   t[d]  : s24 = round_shift( o[d] * r, p + 1 )                    site 6b
--   sh          = qg_exp - Q                                        site 6c
--   zg[d] : s32 = round_shift( g_mant[d], sh )        when sh >= 0
--               = sat32( g_mant[d] sll (-sh) )        when sh <  0
--   g15[d]: u16 = SIG(zg[d]), Q15, clamped to [0, 32767]            site 6d
--   y[d]  : s24 = round_shift( t[d] * g15[d], 15 )                  site 6e
--
-- t is o/s expressed in Q(R_Q-1) = Q14, which is what attn_recip's (p, r) pair
-- exists to produce; g15 is the gate; y is what attn_emit packs.
--
-- Bit-exact against ref/attn_gate_vec.c, whose five oracles share none of this
-- unit's integer machinery: site 6b against o*2^14/s in double inside a bound
-- DERIVED from the reciprocal's own floor error, site 6c recomputed exactly in
-- double with ldexp and floor, the sigmoid against libm inside a bound derived
-- from max|sigmoid''| = 1/(6*sqrt 3) with the CHORD DIRECTION asserted
-- separately and the grid points asserted as exact equalities, site 6e's round
-- inside half a count, and the whole chain inside a composed bound.  The
-- reference was mutation-tested before this file existed: 13 of 17 killed, and
-- every one of the four survivors read and shown equivalent.
--
-- WHY THESE FOUR SITES ARE ONE UNIT.  They are the C spec's own
-- element-sequential pipeline (3.5): the reciprocal-multiply and the gate
-- activation run side by side on the same element and meet at the gate
-- multiply.  Splitting them would put an interface in the middle of a single
-- cycle-per-element datapath and buy nothing.
--
-- WHY THIS UNIT AND NOT ANOTHER.  Downstream reach.  It is the ONLY consumer
-- of attn_recip's (p, r) pair and the ONLY producer of attn_emit's input, so it
-- is the single unit that joins the four already-verified ones --
-- attn_kv_quant (step 4), attn_score_q12 (steps 5b/6), attn_softmax (step 7),
-- attn_recip (step 8a) -- to the end of the pipeline, and it is what unblocks
-- attn_emit.  It also carries the last unbuilt nonlinearity in subsystem C.
--
-- ---------------------------------------------------------------------------
-- THE SIGMOID IS NOT THE EXP CONE, AND THE DIFFERENCE IS NOT COSMETIC.
-- fixed_pkg's sigmoid_q spans z in [-16, 16] over SIG_N = 512 intervals, so
-- the step is 1/16 -- the same step as EXP_ROM, over twice the domain with
-- twice the entries.  z = 0 is EXACTLY table entry 256, which is why no
-- interval straddles sigmoid's inflection and why the reference can assert a
-- one-sided chord bound on each side of it.
--
-- The C spec (3.2, site 6d) pins the output stage HERE rather than deferring
-- to sigmoid_q: round_shift(interp, 30 - 15) half toward plus infinity, then
-- clamped to [0, 32767].  32767 and not 32768 is a deliberate 3.1e-5 deviation
-- so the gate fits u16 and the site-6e multiply fits one DSP48E2 tile.  It is
-- REACHABLE from the interpolated branch and not only from the domain clamp:
-- round_shift(SIG_ROM(511), 15) is already 32768, and so is every value from
-- zg = 40927 upward.  The reference counts that reachability as a coverage
-- requirement rather than assuming it.
--
-- ONE resize IS DELIBERATELY NOT WRITTEN, and it is the same one twice before.
-- The cone's offset is zg + 16*2^Q, which lies in (0, 2^17) for the
-- interpolated branch and therefore needs EIGHTEEN signed bits, not
-- seventeen.  numeric_std's `resize` on a `signed` keeps the SIGN bit and
-- drops the top MAGNITUDE bit, so `resize(zg + OFF_MID, 17)` would return the
-- wrong value for every zg >= 0, i.e. for half the domain.  This subsystem has
-- now been bitten by exactly that twice, one unit apart
-- (docs/debugging/2026-08-27_attn-kv-quant-abs-resize.md, where abs(-32768)
-- came out zero, and 2026-08-27_attn-softmax-offset-resize.md, where the same
-- offset stage deleted the top code point at z = 0).  The offset below is a
-- SLICE of the wide sum, which is exact by construction because the value fits
-- OFF_W bits unsigned.  Do not tidy it back into a resize to make the widths
-- line up.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   cfg_valid / p_in / r_in /     THE PRODUCER IS STALLABLE.  attn_recip holds
--   qg_exp / cfg_ready /          its (p, r) pair until r_ready, precisely
--   cfg_taken                     because this unit takes it once and is then
--                                 busy for N elements.  RULE 2: the three
--                                 scalars are read for the WHOLE head, so they
--                                 are LATCHED at the accept instant and the
--                                 instant is made observable by cfg_taken.  A
--                                 producer that advanced them mid-head would
--                                 corrupt the tail of that head and nothing
--                                 else -- the gdn_emit_chain head-23 shape,
--                                 where heads 0 through 22 were bit-exact.
--
--                                 AND THE ORDERING RULE, from subsystem B's
--                                 2026-08-27 gdn_conv defect: a scalar that
--                                 qualifies a stream must be assigned STRICTLY
--                                 EARLIER than the state that first raises
--                                 that stream's valid.  Here cfg is latched in
--                                 S_IDLE and derived in S_CFG1..S_CFG3, and
--                                 x_ready cannot rise before S_RUN, so the
--                                 separation is three states wide and
--                                 structural.  STRICT_PRODUCER asserts it
--                                 anyway, because a structural argument that
--                                 nothing checks is the same unobservable
--                                 contract that defect punished.
--
--   x_valid / o_in / g_in /       THE PRODUCER IS STALLABLE.  x_ready falls
--   x_ready                       whenever the output cannot drain, which
--                                 freezes the WHOLE pipeline rather than
--                                 letting a stage overwrite an element still
--                                 in flight.  A stall that froze the input but
--                                 let the pipeline run would drop elements
--                                 silently, in range and the right count.
--
--   y_valid / y_out / t_out /     Producer (this unit) IS stallable and HOLDS.
--   g_out / y_ready               The consumer is attn_emit's scratch, which
--                                 the C spec says never stalls, so y_ready
--                                 DEFAULTS TO '1' -- and that default is
--                                 exactly why the hold must be built and
--                                 tested: a consumer that genuinely never
--                                 stalls cannot tell a held valid from a
--                                 pulsed one, and the day one does, the loss
--                                 is silent.
--
--   done / done_ack               RULE 1: HELD until acked, never pulsed, and
--                                 raised only after the LAST element has been
--                                 ACCEPTED, not when it was produced.
--
-- WHY t_out AND g_out EXIST.  They are observability only; the datapath does
-- not read them.  attn_kv_quant's write-up records that checking the mantissas
-- alone hid a defect because the mantissa and the exponent were self-consistent
-- with each other, and that only a SEPARATE exact check on the second value
-- caught it.  Here y alone is one number and a wrong t and a wrong g15 look
-- identical in it.  Publishing both, aligned with y, separates them in one run
-- instead of one run each.  The cost is the two stages of pipeline each must
-- be carried past its consumer -- 24 + 16 bits by 2 stages, about 80 flops --
-- and that is the entire price.  zg is deliberately NOT published: it would
-- cost twelve stages of 32 bits, and g15 is monotone in zg, so a zg defect is
-- visible in g15.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.  Seventeen
-- stages, one listed operation each, and the two paths that run side by side
-- read the same source rather than each other:
--
--    1  capture o and g
--    2  MULTIPLY o*r        | ADD g + gbias      | SHIFT g sll lsh
--    3  ADD prod + tbias    | SHIFT (g+gbias) asr rsh
--    4  SHIFT prsum asr tsh | SELECT the branch
--    5  SATURATE to T_W (t) | SATURATE to Z_W (zg)
--    6  cone: the two domain compares and the clamp
--    7  cone: the offset ADD  (a SLICE, see above)
--    8  cone: index and fraction split -- wiring only
--    9  cone: two parallel SIG_N-way ROM bus muxes
--   10  cone: the table delta SUBTRACT
--   11  cone: the MULTIPLY delta*frac
--   12  cone: the interpolation ADD, with a constant slice
--   13  cone: the round bias ADD
--   14  cone: a constant slice, the clamp and the domain select -> g15
--   15  MULTIPLY t*g15
--   16  ADD the round bias
--   17  a constant slice and one SATURATE -> y
--
-- THREE DSP48E2 TILES, DERIVED FROM OPERAND WIDTHS AND NOT MEASURED.  No
-- Vivado was run for this file.  Stage 2 is 36x16, which exceeds 27x18 and
-- takes 2 tiles (the C DSP skeleton books site 6b at 2 for the same reason).
-- Stage 11 is DLT_W x FRAC_W unsigned = 24x12, i.e. 25x13 signed, one tile;
-- BOTH operands are narrowed, because the 2026-08-26 gdn_silu note records
-- that narrowing the interpolation delta ALONE changes no DSP count -- the
-- multiplicand has to be narrowed too.  Stage 15 is 24x16, one tile.  That is
-- 2 + 1 + 1 = 4 against the skeleton's 1 (sigmoid) + 2 (6b) + 1 (6e) = 4.  The
-- skeleton's own estimate of 1 for the narrowed sigmoid cone is what this
-- reproduces; only synthesis settles it.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only shifts, indices and the
-- exponent, which the project rule exempts.  bfp_pack's header records Vivado
-- DROPPING THE SIGN across an integer round-trip in this very design while
-- GHDL evaluated it correctly and every simulation passed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;                -- clog2
use work.fixed_luts_pkg.all;          -- SIG_ROM

entity attn_gate is
  generic(
    -- Elements per query head.  256 in both target models
    -- (model_cfg_pkg: attn_head_dim).
    N     : positive := 256;
    -- The softmax accumulator's declared width.  C spec 2.1.4 bounds |o| by
    -- 2^30; 36 is what the spec declares for margin.
    O_W   : positive := 36;
    -- attn_recip's pair.  R_W = 16 because r lands in [2^14, 2^15].
    R_W   : positive := 16;
    P_W   : positive := 5;            -- clog2(S_W) with S_W = 26
    -- The gate mantissa, as A's activation memory holds it (qg_rdata is 512
    -- bits = 32 x s16).
    G_W   : positive := 16;
    Z_W   : positive := 32;           -- the Q12 gate argument
    EXP_W : positive := 8;
    Q     : natural  := 12;           -- the gate argument's grid
    GQ    : natural  := 15;           -- the sigmoid output's Q
    T_W   : positive := 24;
    Y_W   : positive := 24;
    -- SIG_ROM intervals over [-16, 16].  Read from the package rather than
    -- assumed; the generic exists so a width change cannot leave a derived
    -- constant stale.
    SIG_N : positive := 512;
    -- EXACT, not an approximation.  |g_mant| < 2^15, so a left shift of 32
    -- already carries any non-zero word past 2^31 and saturates, and a larger
    -- shift saturates to the same rail; a zero word gives zero at every shift.
    -- Lowering it to 31 changes no VALUE but does change the sat32 FLAG on a
    -- word of magnitude 1, which is why the reference's mutation G5 is
    -- recorded as value-equivalent and flag-inequivalent rather than as
    -- equivalent.
    LSH_CLAMP : natural := 32;
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the per-head scalars.  RULE 2: latched, cfg_taken observable. ---
    cfg_valid : in  std_logic;
    p_in      : in  unsigned(P_W-1 downto 0);
    r_in      : in  unsigned(R_W-1 downto 0);
    qg_exp    : in  signed(EXP_W-1 downto 0);
    cfg_ready : out std_logic;
    cfg_taken : out std_logic;               -- one cycle, at the latch
    busy      : out std_logic;

    -- ---- the element stream in ------------------------------------------
    x_valid : in  std_logic;
    o_in    : in  signed(O_W-1 downto 0);
    g_in    : in  signed(G_W-1 downto 0);
    x_ready : out std_logic;

    -- ---- the element stream out.  Held until y_ready. --------------------
    y_valid : out std_logic;
    y_out   : out signed(Y_W-1 downto 0);
    -- Observability, aligned with y_out.  See the header.
    t_out   : out signed(T_W-1 downto 0);
    g_out   : out unsigned(GQ downto 0);
    y_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. -----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared when a new head's scalars are accepted.
    --   zsat : site 6c saturated to s32.  REACHABLE AND LEGAL -- a gate word
    --          with a small qg_exp shifts left past s32 and the sigmoid clamps
    --          anyway -- so it is a golden the testbench checks, not an error.
    --   ovr  : site 6b's s24 saturate fired.  UNREACHABLE under the contract
    --          |o| <= 127*s, which makes |t| < 127*2^14 < 2^21.  A width guard.
    --   ysat : site 6e's s24 saturate fired.  Unreachable once t is bounded,
    --          since g15 < 2^15 makes |y| <= |t|.  A width guard.
    zsat : out std_logic;
    ovr  : out std_logic;
    ysat : out std_logic
  );
end entity;

architecture rtl of attn_gate is

  -- ---- derived widths, every one from the operands and not from a literal --
  -- o*r.  numeric_std's `*` on `signed` returns left'length + right'length,
  -- and r must be widened by one bit to be signed, so the product is
  -- O_W + R_W + 1 bits.  Declared at exactly that and NOT at O_W + R_W with a
  -- narrowing resize on the result: the value does fit 52 bits (|o| < 2^35 and
  -- r <= 2^15 give |o*r| < 2^50), so the narrowing would even be provably
  -- safe, but this subsystem's rule is that a narrowing `resize` on a `signed`
  -- is a defect until proven otherwise and every resize here WIDENS.  53 bits
  -- costs one flop per stage and removes the question.
  constant PR_W  : integer := O_W + R_W + 1;         -- o*r, 53
  -- The right branch adds a bias of at most 2^(RSH_CLAMP-1) to an s16, so
  -- G_W + 2 bits hold it: 32767 + 32768 = 65535 needs 17 signed bits.
  constant GS_W  : integer := G_W + 2;
  constant LS_W  : integer := G_W + LSH_CLAMP;       -- g sll lsh, 48
  -- EXACT: for any sh >= G_W, round_shift(g, sh) = floor((g + 2^(sh-1))/2^sh)
  -- is 0 for every g in [-2^(G_W-1), 2^(G_W-1)-1], and stays 0 for larger sh.
  -- So clamping the right shift at G_W changes no output, and it is what lets
  -- the bias be a G_W-wide decoder instead of an EXP_W-wide one.
  constant RSH_CLAMP : integer := G_W;
  constant SHW   : integer := clog2(64);             -- shift counts, 0..63

  -- The cone.  Every constant is a DERIVATION, so a change of Q, SIG_N or GQ
  -- cannot leave one of them stale.
  --   the table spans 32.0 in z over SIG_N intervals, so one index step is
  --   32*2^Q/SIG_N Q-counts
  constant GRID_CNT : integer := 32 * (2**Q) / SIG_N;   -- 256
  constant GRID_SH  : integer := clog2(GRID_CNT);       -- 8
  constant IDX_W    : integer := clog2(SIG_N);          -- 9, index 0..SIG_N-1
  constant FRAC_W   : integer := Q;                     -- frac < 2^Q, always
  -- offset = zg + 16*2^Q lies in [0, 2^17] and only (0, 2^17) reaches here,
  -- so OFF_W bits UNSIGNED hold it exactly.  Eighteen signed bits would be
  -- needed to resize into; see the header for why that is not done.
  constant OFF_W    : integer := clog2(32 * (2**Q));    -- 17
  constant ROM_W    : integer := 31;                    -- SIG_ROM(SIG_N) < 2^30

  -- The widest SIG_ROM(k+1) - SIG_ROM(k), computed from the table rather than
  -- written as a literal.  It is 16,771,757 at k = SIG_N/2 - 1, where
  -- sigmoid' = 1/4, so 24 bits and NOT 25 -- which is what makes the stage-11
  -- multiply 24x12 and one DSP48E2 tile.
  function sig_delta_w return integer is
    variable m : integer := 0;
    variable d : integer;
    variable w : integer := 1;
  begin
    for k in 0 to SIG_N-1 loop
      d := SIG_ROM(k+1) - SIG_ROM(k);
      if d > m then m := d; end if;
    end loop;
    while 2**w <= m loop w := w + 1; end loop;
    return w;
  end function;
  constant DLT_W : integer := sig_delta_w;

  constant CONE_SH : integer := 30 - GQ;                -- 15
  constant G15_W   : integer := GQ + 1;                 -- 16, holds 0..32768
  constant G15_MAX : integer := 2**GQ - 1;              -- 32767, the pinned top

  constant Z_LO : signed(Z_W-1 downto 0)
    := to_signed(-16 * (2**Q), Z_W);
  constant Z_HI : signed(Z_W-1 downto 0)
    := to_signed( 16 * (2**Q), Z_W);
  constant OFF_MID : signed(Z_W-1 downto 0)
    := to_signed(16 * (2**Q), Z_W);
  constant CONE_BIAS : unsigned(ROM_W downto 0)
    := to_unsigned(2**(CONE_SH-1), ROM_W+1);

  -- The output multiply: s24 x u16 -> the unsigned needs one sign bit.
  constant YP_W : integer := T_W + G15_W + 1;           -- 41

  -- Built by shifting rather than by an aggregate with a generic-indexed
  -- choice: `(W-1 => '0', others => '1')` is rejected as a non-locally static
  -- choice alongside `others`.
  function smin(w : integer) return signed is
  begin return shift_left(to_signed(-1, w), w-1); end function;
  function smax(w : integer) return signed is
  begin return not shift_left(to_signed(-1, w), w-1); end function;

  constant T_MIN : signed(T_W-1 downto 0) := smin(T_W);
  constant T_MAX : signed(T_W-1 downto 0) := smax(T_W);
  constant Z_MIN : signed(Z_W-1 downto 0) := smin(Z_W);
  constant Z_MAX : signed(Z_W-1 downto 0) := smax(Z_W);
  constant Y_MIN : signed(Y_W-1 downto 0) := smin(Y_W);
  constant Y_MAX : signed(Y_W-1 downto 0) := smax(Y_W);

  -- ---- the pipeline -------------------------------------------------------
  constant DEPTH : integer := 17;
  signal v : std_logic_vector(1 to DEPTH) := (others => '0');

  type state_t is (S_IDLE, S_CFG1, S_CFG2, S_CFG3, S_RUN, S_DRAIN, S_DONE);
  signal state : state_t := S_IDLE;

  -- latched scalars
  signal p_l   : unsigned(P_W-1 downto 0) := (others => '0');
  signal r_l   : unsigned(R_W-1 downto 0) := (others => '0');
  signal qge_l : signed(EXP_W-1 downto 0) := (others => '0');
  -- derived at S_CFG1..S_CFG3
  signal shv     : signed(EXP_W+1 downto 0) := (others => '0');   -- qg_exp - Q
  signal tsh     : unsigned(SHW-1 downto 0) := (others => '0');   -- p + 1
  signal rsh     : unsigned(SHW-1 downto 0) := (others => '0');
  signal lsh     : unsigned(SHW-1 downto 0) := (others => '0');
  signal is_left : std_logic := '0';
  signal tbias   : signed(PR_W-1 downto 0)  := (others => '0');
  signal gbias   : signed(GS_W-1 downto 0)  := (others => '0');

  -- stage registers
  signal s1_o : signed(O_W-1 downto 0) := (others => '0');
  signal s1_g : signed(G_W-1 downto 0) := (others => '0');

  signal s2_pr : signed(PR_W-1 downto 0) := (others => '0');
  signal s2_gs : signed(GS_W-1 downto 0) := (others => '0');
  signal s2_gl : signed(LS_W-1 downto 0) := (others => '0');

  signal s3_pr : signed(PR_W-1 downto 0) := (others => '0');
  signal s3_gr : signed(GS_W-1 downto 0) := (others => '0');
  signal s3_gl : signed(LS_W-1 downto 0) := (others => '0');

  signal s4_t  : signed(PR_W-1 downto 0) := (others => '0');
  signal s4_z  : signed(LS_W-1 downto 0) := (others => '0');

  signal s5_z  : signed(Z_W-1 downto 0)  := (others => '0');

  signal s6_z    : signed(Z_W-1 downto 0) := (others => '0');
  signal s6_lo, s6_hi : std_logic := '0';
  signal s7_off  : unsigned(OFF_W-1 downto 0) := (others => '0');
  signal s7_lo, s7_hi : std_logic := '0';
  signal s8_idx  : unsigned(IDX_W-1 downto 0) := (others => '0');
  signal s8_frac : unsigned(FRAC_W-1 downto 0) := (others => '0');
  signal s8_lo, s8_hi : std_logic := '0';
  signal s9_l, s9_h : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal s9_frac : unsigned(FRAC_W-1 downto 0) := (others => '0');
  signal s9_lo, s9_hi : std_logic := '0';
  signal s10_dlt : unsigned(DLT_W-1 downto 0) := (others => '0');
  signal s10_l   : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal s10_frac: unsigned(FRAC_W-1 downto 0) := (others => '0');
  signal s10_lo, s10_hi : std_logic := '0';
  signal s11_prd : unsigned(DLT_W+FRAC_W-1 downto 0) := (others => '0');
  signal s11_l   : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal s11_lo, s11_hi : std_logic := '0';
  signal s12_int : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal s12_lo, s12_hi : std_logic := '0';
  signal s13_sum : unsigned(ROM_W downto 0) := (others => '0');
  signal s13_lo, s13_hi : std_logic := '0';

  -- t carried from stage 5 to its consumer at stage 15, then two more stages
  -- so that t_out lands with y_out.
  type t_arr_t is array (5 to DEPTH) of signed(T_W-1 downto 0);
  signal t_p : t_arr_t := (others => (others => '0'));
  -- g15 from stage 14 to DEPTH, same reason.
  type g_arr_t is array (14 to DEPTH) of unsigned(G15_W-1 downto 0);
  signal g_p : g_arr_t := (others => (others => '0'));

  signal s15_yp : signed(YP_W-1 downto 0) := (others => '0');
  signal s16_ys : signed(YP_W-1 downto 0) := (others => '0');
  signal s17_y  : signed(Y_W-1 downto 0)  := (others => '0');

  -- control
  signal n_in    : integer range 0 to N := 0;
  signal cfg_tk  : std_logic := '0';
  signal done_r  : std_logic := '0';
  signal zsat_r  : std_logic := '0';
  signal ovr_r   : std_logic := '0';
  signal ysat_r  : std_logic := '0';

  signal adv     : std_logic;
  signal x_rdy   : std_logic;
  signal pipe_e  : std_logic;          -- the pipeline is empty

  -- The argument is `a` and not `v` DELIBERATELY.  VHDL is case-insensitive
  -- and a formal named `v` would HIDE the pipeline's valid vector `v` inside
  -- the function body -- silently, since the body never reads it.  The same
  -- shadowing cost a run in tb_attn_recip, where a variable named `nhead` hid
  -- the generic NHEAD and the failure read as a malformed vector file.  GHDL
  -- warns (-Whide); the warning was there and this is what it was about.
  function sat_t(a : signed) return signed is
  begin
    if    a > resize(T_MAX, a'length) then return T_MAX;
    elsif a < resize(T_MIN, a'length) then return T_MIN;
    else  return resize(a, T_W);
    end if;
  end function;

  function sat_y(a : signed) return signed is
  begin
    if    a > resize(Y_MAX, a'length) then return Y_MAX;
    elsif a < resize(Y_MIN, a'length) then return Y_MIN;
    else  return resize(a, Y_W);
    end if;
  end function;

begin

  -- The whole pipeline advances together or not at all.  A stall that froze
  -- the INPUT but let the pipeline run would drop elements silently: every
  -- value would stay in range and only the count would be short, which is the
  -- gdn_emit_chain shape where three configurations were all bit-exact and
  -- differed only in how many columns they dropped.
  adv <= '1' when (v(DEPTH) = '0' or y_ready = '1') else '0';

  -- COMBINATIONAL, and deliberately so.  A registered ready reports this
  -- unit's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.
  x_rdy <= '1' when (state = S_RUN and n_in < N and adv = '1') else '0';

  pipe_e <= '1' when v = (v'range => '0') else '0';

  cfg_ready <= '1' when state = S_IDLE else '0';
  cfg_taken <= cfg_tk;
  busy      <= '0' when state = S_IDLE else '1';
  x_ready   <= x_rdy;
  y_valid   <= v(DEPTH);
  y_out     <= s17_y;
  t_out     <= t_p(DEPTH);
  g_out     <= g_p(DEPTH);
  done      <= done_r;
  zsat      <= zsat_r;
  ovr       <= ovr_r;
  ysat      <= ysat_r;

  process(clk)
    variable sv    : integer;
    variable off_v : signed(Z_W-1 downto 0);
    variable zsel  : signed(LS_W-1 downto 0);
    variable tv    : signed(PR_W-1 downto 0);
    variable slice : unsigned(G15_W-1 downto 0);
    variable yv    : signed(YP_W-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state  <= S_IDLE;
        v      <= (others => '0');
        n_in   <= 0;
        cfg_tk <= '0';
        done_r <= '0';
        zsat_r <= '0'; ovr_r <= '0'; ysat_r <= '0';
      else
        cfg_tk <= '0';

        if STRICT_PRODUCER then
          -- RULE 2.  The three scalars are read for the whole head; a producer
          -- that offers new ones mid-head is offering them into a window this
          -- unit cannot use.
          assert not (cfg_valid = '1' and state /= S_IDLE)
            report "attn_gate: new scalars offered while a head is in flight."
                 & "  p, r and qg_exp are latched at cfg_taken and read for "
                 & "the whole head; advancing them here would corrupt the tail "
                 & "of this head and nothing else"
            severity error;
          -- THE ORDERING RULE (subsystem B's 2026-08-27 gdn_conv defect): the
          -- scalars must be published before the first beat they qualify.
          assert not (x_valid = '1' and x_rdy = '1' and state /= S_RUN)
            report "attn_gate: an element was accepted outside S_RUN, i.e. "
                 & "before the head's scalars were derived.  A scalar that "
                 & "qualifies a stream must be assigned STRICTLY EARLIER than "
                 & "the state that first raises that stream's valid"
            severity error;
          -- The output must never be withdrawn once offered.
          assert not (v(DEPTH) = '1' and y_ready = '0' and adv = '1')
            report "attn_gate: the pipeline advanced while an unaccepted "
                 & "element was standing at the output -- that element is "
                 & "lost, not delayed"
            severity error;
        end if;

        -- =================================================================
        -- The datapath.  Every stage is gated on adv, so a stalled output
        -- freezes the whole thing and nothing is overwritten in flight.
        -- =================================================================
        if adv = '1' then
          v(1) <= x_valid and x_rdy;
          for i in 2 to DEPTH loop
            v(i) <= v(i-1);
          end loop;

          -- ---- 1: capture ----------------------------------------------
          if x_valid = '1' and x_rdy = '1' then
            s1_o <= o_in;
            s1_g <= g_in;
          end if;

          -- ---- 2: the MULTIPLY, and the two gate pre-shifts in parallel --
          -- The add and the shift both read s1_g and neither reads the other,
          -- so they are one level and not two.
          if v(1) = '1' then
            s2_pr <= s1_o * signed('0' & r_l);
            s2_gs <= resize(s1_g, GS_W) + gbias;
            s2_gl <= shift_left(resize(s1_g, LS_W), to_integer(lsh));
          end if;

          -- ---- 3: the round-bias ADD, and the right-branch SHIFT ---------
          if v(2) = '1' then
            s3_pr <= s2_pr + tbias;
            -- Arithmetic right, i.e. the floor that round_shift's definition
            -- asks for once the bias has been added.
            s3_gr <= shift_right(s2_gs, to_integer(rsh));
            s3_gl <= s2_gl;
          end if;

          -- ---- 4: the t SHIFT, and the branch SELECT --------------------
          if v(3) = '1' then
            s4_t <= shift_right(s3_pr, to_integer(tsh));
            if is_left = '1' then
              s4_z <= s3_gl;
            else
              s4_z <= resize(s3_gr, LS_W);
            end if;
          end if;

          -- ---- 5: two SATURATES, in parallel ----------------------------
          if v(4) = '1' then
            tv := s4_t;
            t_p(5) <= sat_t(tv);
            if tv /= resize(sat_t(tv), PR_W) then
              ovr_r <= '1';   -- unreachable under |o| <= 127*s; a width guard
            end if;
            zsel := s4_z;
            if zsel > resize(Z_MAX, LS_W) then
              s5_z   <= Z_MAX; zsat_r <= '1';
            elsif zsel < resize(Z_MIN, LS_W) then
              s5_z   <= Z_MIN; zsat_r <= '1';
            else
              s5_z <= resize(zsel, Z_W);
            end if;
          end if;

          -- ---- 6: the cone's domain compares, and the clamp -------------
          -- Two compares on the SAME operand, so they are parallel, plus one
          -- select.  Unlike attn_softmax's cone, z here is genuinely
          -- two-sided: sigmoid's domain is [-16, 16] and both ends are
          -- REACHED by real data, so neither branch is a degradation path.
          if v(5) = '1' then
            if s5_z <= Z_LO then s6_lo <= '1'; else s6_lo <= '0'; end if;
            if s5_z >= Z_HI then s6_hi <= '1'; else s6_hi <= '0'; end if;
            s6_z   <= s5_z;
            t_p(6) <= t_p(5);
          end if;

          -- ---- 7: the offset ADD ----------------------------------------
          -- A SLICE of the wide sum, NOT `unsigned(resize(s6_z + OFF_MID,
          -- OFF_W))`.  The value reaches 2^17 - 1, which needs EIGHTEEN signed
          -- bits, and resize on a `signed` keeps the sign bit and drops the
          -- top magnitude bit -- so a resize would return the wrong value for
          -- every zg >= 0.  Twice bitten in this subsystem already; see the
          -- header.  The clamps at stage 6 bound the sum to [0, 2^17] here, so
          -- the low OFF_W bits ARE the value whenever the interpolation runs.
          if v(6) = '1' then
            off_v  := s6_z + OFF_MID;
            s7_off <= unsigned(off_v(OFF_W-1 downto 0));
            s7_lo  <= s6_lo;
            s7_hi  <= s6_hi;
            t_p(7) <= t_p(6);
          end if;

          -- ---- 8: index and fraction.  Muxes and wiring only. ------------
          --   idx  = offset(GRID_SH+IDX_W-1 downto GRID_SH)
          --   frac = offset(GRID_SH-1 downto 0) * 2^(Q-GRID_SH)
          -- offset = 32*2^Q is unreachable here (the stage-6 high clamp takes
          -- it), so idx never needs the SIG_N code point and frac never needs
          -- the 2^Q code point.  That is the one structural difference from
          -- the exp cone, whose z = 0 boundary DOES land on the top entry and
          -- needs FRAC_W = Q+1 for it.
          if v(7) = '1' then
            s8_idx  <= s7_off(GRID_SH+IDX_W-1 downto GRID_SH);
            s8_frac <= s7_off(GRID_SH-1 downto 0)
                       & to_unsigned(0, Q - GRID_SH);
            s8_lo   <= s7_lo;
            s8_hi   <= s7_hi;
            t_p(8)  <= t_p(7);
          end if;

          -- ---- 9: two PARALLEL SIG_N-way bus muxes on the same index -----
          if v(8) = '1' then
            s9_l    <= to_unsigned(SIG_ROM(to_integer(s8_idx)), ROM_W);
            s9_h    <= to_unsigned(SIG_ROM(to_integer(s8_idx) + 1), ROM_W);
            s9_frac <= s8_frac;
            s9_lo   <= s8_lo;
            s9_hi   <= s8_hi;
            t_p(9)  <= t_p(8);
          end if;

          -- ---- 10: the table delta ALONE --------------------------------
          -- SIG_ROM is monotone increasing, so this is non-negative and DLT_W
          -- bits hold it; that is what makes the multiply below one tile.
          if v(9) = '1' then
            s10_dlt  <= resize(s9_h - s9_l, DLT_W);
            s10_l    <= s9_l;
            s10_frac <= s9_frac;
            s10_lo   <= s9_lo;
            s10_hi   <= s9_hi;
            t_p(10)  <= t_p(9);
          end if;

          -- ---- 11: the MULTIPLY ALONE.  24x12 unsigned, one tile. --------
          if v(10) = '1' then
            s11_prd <= s10_dlt * s10_frac;
            s11_l   <= s10_l;
            s11_lo  <= s10_lo;
            s11_hi  <= s10_hi;
            t_p(11) <= t_p(10);
          end if;

          -- ---- 12: the interpolation ADD ALONE --------------------------
          -- The >> Q is a CONSTANT slice, i.e. wiring, and both terms are
          -- non-negative so the slice is exactly the FLOOR that sigmoid_q's
          -- shift gives.  The reference's chord-direction oracle is what
          -- pins this as a floor rather than a round: a round survives every
          -- magnitude bound and is killed there.
          if v(11) = '1' then
            s12_int <= s11_l + resize(s11_prd(DLT_W+FRAC_W-1 downto Q), ROM_W);
            s12_lo  <= s11_lo;
            s12_hi  <= s11_hi;
            t_p(12) <= t_p(11);
          end if;

          -- ---- 13: the round-bias ADD alone -----------------------------
          if v(12) = '1' then
            s13_sum <= resize(s12_int, ROM_W+1) + CONE_BIAS;
            s13_lo  <= s12_lo;
            s13_hi  <= s12_hi;
            t_p(13) <= t_p(12);
          end if;

          -- ---- 14: a constant slice, the u16 clamp, the domain select ----
          -- The slice can reach 32768 -- the whole top interval does, which is
          -- why the clamp is not decorative -- and the C spec pins the clamped
          -- value at 32767 so the gate fits u16.
          if v(13) = '1' then
            slice := s13_sum(CONE_SH+G15_W-1 downto CONE_SH);
            if s13_lo = '1' then
              g_p(14) <= (others => '0');
            elsif s13_hi = '1' then
              g_p(14) <= to_unsigned(G15_MAX, G15_W);
            elsif slice > to_unsigned(G15_MAX, G15_W) then
              g_p(14) <= to_unsigned(G15_MAX, G15_W);
            else
              g_p(14) <= slice;
            end if;
            t_p(14) <= t_p(13);
          end if;

          -- ---- 15: the gate MULTIPLY ALONE.  s24 x u16, one tile. --------
          if v(14) = '1' then
            s15_yp  <= t_p(14) * signed('0' & g_p(14));
            t_p(15) <= t_p(14);
            g_p(15) <= g_p(14);
          end if;

          -- ---- 16: the round-bias ADD alone -----------------------------
          if v(15) = '1' then
            s16_ys  <= s15_yp + to_signed(2**(GQ-1), YP_W);
            t_p(16) <= t_p(15);
            g_p(16) <= g_p(15);
          end if;

          -- ---- 17: a constant slice and one SATURATE --------------------
          if v(16) = '1' then
            yv := shift_right(s16_ys, GQ);
            s17_y <= sat_y(yv);
            if yv /= resize(sat_y(yv), YP_W) then
              ysat_r <= '1';   -- unreachable once t is bounded; a width guard
            end if;
            t_p(17) <= t_p(16);
            g_p(17) <= g_p(16);
          end if;

          if x_valid = '1' and x_rdy = '1' then
            n_in <= n_in + 1;
          end if;
        end if;

        -- =================================================================
        -- The control FSM.  Deliberately OUTSIDE the adv gate: a stalled
        -- output must not freeze the completion handshake, only the data.
        -- =================================================================
        case state is

          when S_IDLE =>
            if cfg_valid = '1' then
              p_l    <= p_in;         -- RULE 2: latched, never read live
              r_l    <= r_in;
              qge_l  <= qg_exp;
              cfg_tk <= '1';          -- RULE 2: the instant, made observable
              n_in   <= 0;
              zsat_r <= '0'; ovr_r <= '0'; ysat_r <= '0';
              state  <= S_CFG1;
            end if;

          -- ---- one narrow subtract and one narrow add, in parallel ------
          -- They share no operand, so this is one level.  Splitting them out
          -- of the shift states below is the whole reason there are three
          -- config states: an add feeding a barrel shift is exactly the pair
          -- that held rmsnorm_rs at 117.2 MHz, and MREG was not the fix there
          -- either.
          when S_CFG1 =>
            shv   <= resize(qge_l, EXP_W+2) - to_signed(Q, EXP_W+2);
            tsh   <= resize(p_l, SHW) + to_unsigned(1, SHW);
            state <= S_CFG2;

          -- ---- the branch decision: one compare and two clamps ----------
          when S_CFG2 =>
            if shv < 0 then
              is_left <= '1';
              sv := -to_integer(shv);
              -- EXACT; see the LSH_CLAMP generic's comment.
              if sv > LSH_CLAMP then sv := LSH_CLAMP; end if;
              lsh <= to_unsigned(sv, SHW);
              rsh <= (others => '0');
            else
              is_left <= '0';
              sv := to_integer(shv);
              -- EXACT; see the RSH_CLAMP constant's comment.
              if sv > RSH_CLAMP then sv := RSH_CLAMP; end if;
              rsh <= to_unsigned(sv, SHW);
              lsh <= (others => '0');
            end if;
            state <= S_CFG3;

          -- ---- two decoders, in parallel --------------------------------
          when S_CFG3 =>
            -- tsh >= 1 always, because p >= 0, so tsh-1 >= 0.
            tbias <= shift_left(to_signed(1, PR_W), to_integer(tsh) - 1);
            if rsh = 0 then
              -- round_shift(v, 0) = v exactly, which is what makes a zero
              -- bias correct rather than merely harmless.
              gbias <= (others => '0');
            else
              gbias <= shift_left(to_signed(1, GS_W), to_integer(rsh) - 1);
            end if;
            state <= S_RUN;

          when S_RUN =>
            if n_in = N and adv = '1' and (x_valid = '0' or x_rdy = '0') then
              state <= S_DRAIN;
            end if;

          -- ---- the head is finished when the PIPELINE is empty -----------
          -- Not when the last element was accepted.  Signalling completion
          -- with elements still in flight publishes a head that is missing its
          -- tail, in range and the right shape -- attn_softmax's S_FIN note,
          -- and the same reason.
          when S_DRAIN =>
            if pipe_e = '1' then
              state <= S_DONE;
            end if;

          -- ================= RULE 1: held, not pulsed ====================
          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then
              -- Do NOT clear done_r here.  The trailing assignment below
              -- clears it once the state leaves S_DONE.  An explicit clear in
              -- this branch is a LATER assignment that wins, which destroys
              -- the pulse outright whenever done_ack is tied high -- exactly
              -- the default a testbench uses.  Written and caught once
              -- already, in gdn_head_emit.
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
