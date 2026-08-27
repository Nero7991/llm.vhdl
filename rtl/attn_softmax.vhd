-- rtl/attn_softmax.vhd
-- Subsystem C, step 7: the ONLINE softmax for one query head.
--
-- WHAT IT COMPUTES.  A stream of Q12 scores goes in, one per cached position,
-- in the order the sweep produces them; a stream of Q12 PV weights `e_p` comes
-- out for the accumulator array, together with the rescale factors `f` that
-- array needs and the final denominator `s`.
--
--   m'   = ceil_grid( max(m_g, score_q12) )        grid = 2^GRID_SH counts
--   rise = m' > m_g
--   k    = (m' - m_g) asr GRID_SH                  EXACT on every rise
--   f    = round_shift( EXP_ROM(ROM_N - k), 30-Q ) for k <= ROM_N, else 0
--   s    = round_shift( s * f, Q )                 on a rise, before the fold
--   z    = score_q12 - m_g                         always <= 0
--   e_p  = exp_cone(z)                             u13, e_p <= 2^Q
--   s    = s + e_p
--
-- Bit-exact against ref/attn_softmax_vec.c, which is itself checked against
-- four oracles that share none of its fixed-point machinery: the final
-- denominator against a BATCH double-precision sum with a per-case derived
-- bound, every e_p against exp() with a bound derived from the chord error of a
-- convex function over a 1/16 grid step, the DIRECTION of that chord (a chord
-- lies above a convex function, so e_p must not fall below exp), and the grid
-- invariants as exact equalities.  The reference was mutation-tested before any
-- RTL existed: 10 of 13 killed, the 3 survivors shown equivalent by arithmetic
-- and by a paired mutation that IS killed.
--
-- WHY THIS UNIT NEXT, out of the ten remaining subsystem C names.  It is the
-- one every other read-side unit is downstream of.  `attn_score_q12` was built
-- so its output could feed a running maximum; this is the running maximum, and
-- until it exists that unit's whole reason for converting at the point of
-- production is unexercised.  It produces BOTH of the read path's two outputs:
-- `e_p`, which is the weight every PV multiply in the lane array uses, and `s`,
-- which is the denominator the reciprocal and the output stage divide by.  It
-- is also self-contained -- it instantiates nothing, and it depends on no other
-- C unit's RTL -- and it is unchanged between the two target models, because
-- nothing in it scales with head count or head dim.
--
-- WHY THE GRID SNAP IS THE WHOLE DESIGN, and why it is a CEILING.  The running
-- maximum is held snapped UP to a multiple of 2^GRID_SH = 256 Q12 counts, which
-- is 1/16 in real units, which is exactly one EXP_ROM index step (the table
-- spans z in [-16, 0] over ROM_N = 256 intervals).  That makes `k` an exact
-- integer on every rise, so the rescale factor exp(m_old - m_new) is a direct
-- TABLE ENTRY and not a second interpolation -- an unsnapped maximum would need
-- one cone evaluation per rescale and would make the factor inexact in a way
-- that compounds over every later position.  It must be a ceiling and not a
-- floor because z = score - m_g has to stay <= 0 for the score that just SET
-- the maximum; rounding the maximum down makes its own z positive and takes the
-- cone out of domain.  `ceil_grid` here is one wide add followed by clearing
-- the low GRID_SH bits, which is wiring, so it costs one stage and not two.
--
-- THE FIRST POSITION IS NOT A RESCALE, and there is no sentinel.  `first_r`
-- sets m_g directly with no `f` emitted, because s and the array's accumulator
-- are both zero at that instant.  A sentinel of -2^31 would also work -- it
-- gives k far above ROM_N and therefore f = 0 -- but it costs a full rescale
-- pass over 1,536 accumulators per head per layer to multiply zero by zero, and
-- it makes the first position depend on a magic constant instead of a flag.
--
-- THE RISE TEST IS STRICT, and that is invisible to any value check.  With
-- `>=` a repeated maximum emits a rescale with k = 0, hence f = 2^Q, hence
-- s unchanged and every accumulator multiplied by one: arithmetically a no-op,
-- so every mantissa and every denominator still matches.  What it costs is a
-- full rescale pass per repeated maximum, and the only thing that sees it is
-- the rescale COUNT.  `rescale_n` is an output for that reason and the
-- testbench checks it against the golden, which is the sole reason mutation M2
-- is killed rather than surviving as an equivalent mutant.
--
-- k > ROM_N IS A RANGE BRANCH, NOT A VALUE BRANCH.  ROM_N - k is a negative
-- index for k > ROM_N, outside the ROM's address range.  It is NOT needed for
-- the value: clamping the index to 0 instead gives
-- round_shift(EXP_ROM(0), 18) = round_shift(121, 18) = 0, the same answer,
-- because exp(-16) is below half a Q12 count.  That was measured (reference
-- mutation C11 survives, and is equivalent) rather than argued.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.  Required by the project rule: for every
-- interface, whether the producer can be stalled, and if it cannot, what bounds
-- the consumer's service time.
--
--   sc_valid / sc_q12 / sc_ready  THE PRODUCER IS STALLABLE.  attn_score_q12
--   (the score stream)            holds `s_valid` until `s_ready`, so refusing
--                                 a score delays it and does not lose it.  This
--                                 unit lowers sc_ready for the whole rescale
--                                 sequence, which is the discipline the C
--                                 skeleton names as normative: the cone is held
--                                 off at its INPUT, never stalled at its
--                                 output.  The stall is bounded and constant --
--                                 the drain, then five states of sequencing,
--                                 plus however long the array takes to ack --
--                                 and it is longer than the 8-cycle rescale
--                                 slot the C spec's schedule budgets, which is
--                                 why `rs_valid` is raised as soon as `f` is
--                                 known and NOT after `s` has been rescaled:
--                                 the array's pass then overlaps this unit's
--                                 own multiply instead of following it.  A
--                                 producer that cannot wait that long reports
--                                 it on attn_score_q12's `ovr`.
--
--   ep_valid / ep / ep_ready      THE CONSUMER CANNOT STALL THIS UNIT, and
--   (the PV weight, to the array) that is structural, not an oversight.  The
--                                 lane array runs on a fixed 16-cycle position
--                                 slot driven by the AXI beat rate; an `e_p`
--                                 it does not take is a LOST weight, not a
--                                 delayed one -- exactly gdn_recur_pipe's
--                                 free-running `o_res_valid`.  So there is no
--                                 ready in the datapath.  `ep_ready` exists
--                                 ONLY so STRICT_PRODUCER can assert that it
--                                 was never low under a valid, which converts
--                                 an invisible schedule contract into a loud
--                                 simulation failure.  It DEFAULTS TO '1' and
--                                 nothing in the datapath reads it.
--
--   rs_valid / rs_f / rs_ack      Producer (this unit) IS stallable and HOLDS.
--   (the rescale pass)            The array needs 8 cycles to multiply 1,536
--                                 accumulators by `f`; until it acks, no score
--                                 is accepted and no `e_p` is produced, so the
--                                 array cannot be handed a weight belonging to
--                                 the new grid while it still holds the old
--                                 one.  rs_ack DEFAULTS TO '1', which
--                                 reproduces a zero-latency array exactly, so
--                                 adding it is strictly a widening.
--
--   done / done_ack               RULE 1 from the two 2026-08-27 subsystem B
--                                 integration defects: `done` is HELD until
--                                 acked, never pulsed.  gdn_head_emit's
--                                 one-cycle done with no handshake lost an
--                                 ENTIRE HEAD whenever the consumer was busy
--                                 at the instant it fired, then went idle with
--                                 both banks empty looking healthy.
--
--   start / sc_q12 / last         RULE 2: every value read for longer than one
--                                 cycle is latched at a named instant and the
--                                 instant is observable.  `cfg_taken` marks the
--                                 head start; each score is latched into
--                                 `sc_h` at its accept edge and read from there
--                                 for the ~4 cycles the max test and the cone
--                                 push take.  A unit that read `sc_q12` live
--                                 would take the NEXT score's value for the z
--                                 of this one -- the gdn_emit_chain `w_mant`
--                                 shape, where heads 0 through 22 were
--                                 bit-exact and head 23 alone was wrong.  The
--                                 testbench poisons sc_q12 immediately after
--                                 the accept for that reason.
--
-- THE DRAIN IS THE ONE NON-OBVIOUS THING IN THIS FILE.  `s` must be rescaled
-- only after every weight already in flight has been folded into it, because
-- those weights belong to the OLD maximum and the rescale is what converts the
-- old grid to the new one.  The cone is a fixed-latency pipeline, so at the
-- instant a rise is detected there can be up to CONE_LAT weights still inside
-- it.  S_DRAIN waits for `inflight` to reach zero before the rescale sequence
-- starts.  Without it the last weights before a rise are folded in AFTER the
-- multiply and are therefore never scaled: `s` comes out too large by exactly
-- those terms, every value is in range, the record length is right, and the
-- error is a few parts in a thousand -- which is inside any tolerance anyone
-- would pick and outside the derived bound the reference computes.  The
-- mutation table records it as M6.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.  A unit
-- that broke it held at 117.2 MHz and reached 300.8 only after its states were
-- split, and MREG was NOT the fix.  Every stage below is one such operation;
-- constant-distance shifts are wiring and are named as such where used.
--
--   front end   S_CEIL  one wide add, then a constant mask (wiring)
--               S_TEST  one wide compare, in parallel with one wide subtract
--                       that shares its operands
--               S_K     a constant slice (wiring) and one narrow compare
--               S_IDX   one narrow subtract feeding a 2:1 select
--               S_ROM   one ROM_N-way bus mux
--               S_FB    one add            S_F   a slice and a 2:1 select
--               S_MUL   one MULTIPLY       S_SB  one add
--               S_SS    a constant slice, and m_g takes its new value
--               S_ZED   one wide subtract
--   cone        X1 compare | X2 add | X3 muxes | X4 two parallel bus muxes
--               X5 subtract | X6 MULTIPLY | X7 add | X8 add | X9 slice + select
--
-- DSP, DERIVED not measured.  Two multiplies, and both were sized so that they
-- fit ONE DSP48E2 tile each under the 27x18 signed rule:
--
--   the cone interpolation   delta is 26 bits UNSIGNED -- max EXP_ROM(k+1) -
--                            EXP_ROM(k) is 65,054,728 at k = 255, which is 26
--                            bits and NOT 27 -- and frac is 13 bits unsigned,
--                            max 4096.  As signed operands that is 27 x 14,
--                            which is one tile.
--   the s rescale            s is S_W = 26 bits unsigned and f is 13, i.e.
--                            27 x 14 signed, one tile.
--
-- So this unit DERIVES to 2 DSP.  That is worth stating against the C DSP
-- skeleton, which books the exp cone at 8 from a 2026-08-24 measurement of the
-- VERBATIM-width `fixed_pkg.exp_q` (64-bit intermediates, a 64x64 product) and
-- lists "whether the exp cone narrows the way the sigmoid cone did" as open
-- item 3.  This is the narrowing, and it is bit-identical to the verbatim form
-- by construction rather than by tolerance, because every intermediate above is
-- provably inside its declared width.  It is a DERIVATION from operand widths,
-- NOT a synthesis result, and it is the sort of claim that has been wrong here
-- before: the same skeleton records that narrowing the interpolation delta
-- ALONE changed no DSP count on the sigmoid cone, because the multiplicand
-- stayed wide.  Both operands are narrowed here.  Only Vivado settles it.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only shifts, indices and the ROM
-- address, which the project rule exempts.  bfp_pack's header records Vivado
-- DROPPING THE SIGN across an integer round-trip in this very design: GHDL
-- evaluated it correctly, every simulation passed, and only the netlist was
-- wrong.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.fixed_luts_pkg.all;        -- EXP_ROM, Q30, 257 entries
use work.util_pkg.all;              -- clog2

entity attn_softmax is
  generic(
    -- The score width, from attn_score_q12's s_q12.
    P_W      : positive := 32;
    -- The softmax input grid, C spec step 6.  Also the output Q of e_p and f.
    Q        : natural  := 12;
    -- log2 of the Q12 counts in one EXP_ROM index step.  The table spans
    -- z in [-16, 0] over ROM_N intervals, so one step is 16/ROM_N = 1/16 in
    -- real units, which at Q = 12 is 2^12/16 = 2^8 counts.  Derived from Q and
    -- ROM_N rather than written as 8, so a width change cannot leave it stale.
    ROM_N    : positive := 256;
    -- e_p and f are u13: 0 .. 2^Q inclusive, so Q+1 bits.
    E_W      : positive := 13;
    -- The denominator.  |s| <= MAXCTX * 2^Q = 2^11 * 2^12 = 2^23 at the C
    -- spec's MAXCTX of 2048; 26 is the spec's declared width and carries three
    -- bits of margin.  Nothing here is valid at 32K context without
    -- re-deriving it -- the C skeleton's open item 10.
    S_W      : positive := 26;
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- head job.  RULE 2: cfg_taken marks the instant. -----------------
    start     : in  std_logic;                 -- begin a query head
    cfg_taken : out std_logic;
    busy      : out std_logic;

    -- ---- the score stream.  Producer IS stallable; see the header. -------
    sc_valid : in  std_logic;
    sc_q12   : in  signed(P_W-1 downto 0);
    sc_last  : in  std_logic;                  -- with sc_valid: final position
    sc_ready : out std_logic;

    -- ---- the PV weight, to the lane array.  NO ready in the datapath. ----
    ep_valid : out std_logic;
    ep       : out unsigned(E_W-1 downto 0);
    -- Observability only.  STRICT_PRODUCER asserts it was never low under a
    -- valid; the datapath does not read it.  Defaults to '1'.
    ep_ready : in  std_logic := '1';

    -- ---- the rescale pass.  Held until acked. ---------------------------
    rs_valid : out std_logic;
    rs_f     : out unsigned(E_W-1 downto 0);
    rs_ack   : in  std_logic := '1';

    -- ---- results, valid from done to the next start ---------------------
    s_out    : out unsigned(S_W-1 downto 0);
    m_out    : out signed(P_W+1 downto 0);
    -- C spec 3.3 asks for observability on the rescale regime and offers no
    -- mitigation.  This is it.  Also the ONLY thing that separates a strict
    -- rise test from a non-strict one; see the header.
    rescale_n : out unsigned(15 downto 0);

    -- ---- completion.  RULE 1: held until acked, never pulsed. -----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at start.
    --   ovf : s left the S_W-bit field.  Unreachable at MAXCTX = 2048.
    --   err : some z came out positive, i.e. m_g was not an upper bound and
    --         the cone was driven out of domain.  A design invariant, not a
    --         data-dependent event.
    ovf : out std_logic;
    err : out std_logic
  );
end entity;


architecture rtl of attn_softmax is

  -- Q12 counts per EXP_ROM index step.  The table spans 16.0 in z over ROM_N
  -- intervals, so one step is 16 * 2^Q / ROM_N counts.  Written as a derivation
  -- rather than as the literal 256, so a different Q or ROM_N cannot leave it
  -- stale -- the same reason attn_kv_quant derives its TARGET_MSB from MANT_W.
  constant GRID_CNT : integer := 16 * (2**Q) / ROM_N;
  constant GRID_SH  : integer := clog2(GRID_CNT);

  -- The maximum is a CEILING of a P_W-bit score, so it can leave P_W bits:
  -- ceil_grid(2^31 - 1) is 2^31.  Two extra bits, one for that and one spare.
  constant MG_W : integer := P_W + 2;
  -- z = score - m_g.  One bit wider than the wider operand.
  constant Z_W  : integer := MG_W + 1;

  -- ---- the cone's widths, all pinned; see the DSP paragraph in the header --
  constant OFF_W  : integer := clog2(16 * (2**Q)) + 1;   -- offset in [0, 2^17]
  constant IDX_W  : integer := clog2(ROM_N);             -- 0 .. ROM_N-1
  constant FRAC_W : integer := Q + 1;                    -- 0 .. 2^Q INCLUSIVE
  constant ROM_W  : integer := 31;                       -- EXP_ROM(ROM_N)=2^30
  constant CONE_SH : integer := 30 - Q;                  -- Q30 -> Qq, i.e. 18

  -- The widest EXP_ROM(k+1) - EXP_ROM(k) is 65,054,728 at k = ROM_N-1, which
  -- is 26 bits and NOT 27.  Computed FROM THE TABLE rather than written as 26,
  -- because the whole one-DSP-tile claim rests on this number and a different
  -- table would silently invalidate it.
  function rom_delta_w return integer is
    variable d, m : integer := 0;
    variable w    : integer := 1;
  begin
    for k in 0 to ROM_N-1 loop
      d := EXP_ROM(k+1) - EXP_ROM(k);
      if d > m then m := d; end if;
    end loop;
    while 2**w <= m loop w := w + 1; end loop;
    return w;
  end function;
  constant DLT_W : integer := rom_delta_w;               -- 26

  -- round_shift(v, sh) = floor_shr(v + 2^(sh-1), sh); every v shifted here is
  -- non-negative, so the floor is a constant slice and the bias is the whole
  -- of the rounding.
  constant CONE_BIAS : unsigned(ROM_W downto 0)
    := to_unsigned(2**(CONE_SH-1), ROM_W+1);
  constant S_BIAS : unsigned(S_W+E_W-1 downto 0)
    := to_unsigned(2**(Q-1), S_W+E_W);
  constant Z_LO : signed(Z_W-1 downto 0)
    := to_signed(-16 * (2**Q), Z_W);      -- the cone's domain floor
  constant OFF_MID : signed(Z_W-1 downto 0)
    := to_signed(16 * (2**Q), Z_W);

  type state_t is (S_IDLE, S_RUN, S_CEIL, S_TEST, S_DRAIN,
                   S_K, S_IDX, S_ROM, S_FB, S_F, S_MUL, S_SB, S_SS, S_RS,
                   S_ZED, S_FIN, S_DONE);
  signal state : state_t := S_IDLE;

  -- ---- front end -------------------------------------------------------
  signal sc_h    : signed(P_W-1 downto 0) := (others => '0');
  signal last_h  : std_logic := '0';
  signal sc_ceil : signed(MG_W-1 downto 0) := (others => '0');
  signal m_g     : signed(MG_W-1 downto 0) := (others => '0');
  signal first_r : std_logic := '1';
  signal d_r     : signed(MG_W downto 0) := (others => '0');
  signal k_ok    : std_logic := '0';
  signal k_sl    : unsigned(MG_W-GRID_SH downto 0) := (others => '0');
  signal rom_ix  : unsigned(IDX_W downto 0) := (others => '0');
  signal f_lo    : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal f_sum   : unsigned(ROM_W downto 0) := (others => '0');
  signal f_r     : unsigned(E_W-1 downto 0) := (others => '0');
  signal s_r     : unsigned(S_W-1 downto 0) := (others => '0');
  signal sf      : unsigned(S_W+E_W-1 downto 0) := (others => '0');
  signal sf_b    : unsigned(S_W+E_W-1 downto 0) := (others => '0');

  -- ---- the cone.  Fixed latency, no ready anywhere. --------------------
  -- x_v(i) means "stage i's REGISTERS hold valid data".  Stage i's logic reads
  -- stage i's registers and writes stage i+1's, gated on x_v(i).  Writing the
  -- valid and the data on the SAME edge is what keeps them aligned; a `push`
  -- register feeding x_v(1) one edge later would make stage 1 read the
  -- PREVIOUS z, which is the shape rmsnorm_rs's MREG note records as producing
  -- a wrong result with no structural symptom.
  constant CONE_ST : integer := 9;
  signal x_v   : std_logic_vector(1 to CONE_ST) := (others => '0');
  signal x1_z  : signed(Z_W-1 downto 0) := (others => '0');
  signal x2_z  : signed(Z_W-1 downto 0) := (others => '0');
  signal x2_do, x3_do, x4_do, x5_do : std_logic := '0';
  signal x6_do, x7_do, x8_do, x9_do : std_logic := '0';
  signal x3_off  : unsigned(OFF_W-1 downto 0) := (others => '0');
  signal x4_idx  : unsigned(IDX_W-1 downto 0) := (others => '0');
  signal x4_frac, x5_frac, x6_frac : unsigned(FRAC_W-1 downto 0)
                                   := (others => '0');
  signal x5_lo, x5_hi : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal x6_lo, x7_lo : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal x6_dlt  : unsigned(DLT_W-1 downto 0) := (others => '0');
  signal x7_prod : unsigned(DLT_W+FRAC_W-1 downto 0) := (others => '0');
  signal x8_int  : unsigned(ROM_W-1 downto 0) := (others => '0');
  signal x9_sum  : unsigned(ROM_W downto 0) := (others => '0');

  -- Weights inside the cone, from the S_ZED push to the fold.  The DRAIN
  -- condition; see the header.  CONE_ST+2 is the structural maximum and the
  -- range is declared at it so an escape is a simulation failure and not a
  -- wrap.
  signal inflight : integer range 0 to CONE_ST+2 := 0;

  -- ---- outputs ---------------------------------------------------------
  signal ep_v_r  : std_logic := '0';
  signal ep_r    : unsigned(E_W-1 downto 0) := (others => '0');
  signal rs_v_r  : std_logic := '0';
  signal rs_tk   : std_logic := '0';
  signal done_r  : std_logic := '0';
  signal cfg_tk  : std_logic := '0';
  signal ovf_r   : std_logic := '0';
  signal err_r   : std_logic := '0';
  signal nrs_r   : unsigned(15 downto 0) := (others => '0');

begin

  -- COMBINATIONAL, and deliberately so.  A registered ready reports this
  -- unit's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.
  sc_ready  <= '1' when state = S_RUN else '0';
  cfg_taken <= cfg_tk;
  busy      <= '0' when state = S_IDLE else '1';
  ep_valid  <= ep_v_r;
  ep        <= ep_r;
  rs_valid  <= rs_v_r;
  rs_f      <= f_r;
  s_out     <= s_r;
  m_out     <= resize(m_g, P_W+2);
  rescale_n <= nrs_r;
  done      <= done_r;
  ovf       <= ovf_r;
  err       <= err_r;

  process(clk)
    variable ceil_v : signed(MG_W-1 downto 0);
    variable off_v  : signed(Z_W-1 downto 0);
    variable zv     : signed(Z_W-1 downto 0);
    variable acc    : unsigned(S_W downto 0);
    variable inc    : integer range 0 to 1;
    variable dec    : integer range 0 to 1;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state    <= S_IDLE;
        m_g      <= (others => '0');
        first_r  <= '1';
        s_r      <= (others => '0');
        x_v      <= (others => '0');
        inflight <= 0;
        ep_v_r   <= '0';
        rs_v_r   <= '0';
        rs_tk    <= '0';
        done_r   <= '0';
        cfg_tk   <= '0';
        ovf_r    <= '0';
        err_r    <= '0';
        nrs_r    <= (others => '0');
        last_h   <= '0';
        k_ok     <= '0';
      else
        cfg_tk <= '0';

        if STRICT_PRODUCER then
          assert not (start = '1' and state /= S_IDLE)
            report "attn_softmax: start while busy -- this head's descriptor "
                 & "is being dropped, not queued"
            severity error;
          -- The lane array cannot be back-pressured, so an ep_ready that falls
          -- under a valid means a LOST weight, not a delayed one.  This is
          -- gdn_recur_pipe's free-running o_res_valid exactly.
          assert not (ep_v_r = '1' and ep_ready = '0')
            report "attn_softmax: ep_valid asserted while ep_ready was low.  "
                 & "The PV array cannot be stalled, so this weight is lost, "
                 & "not delayed."
            severity error;
          -- The rescale must never run with weights still inside the cone:
          -- those weights belong to the OLD maximum and would be folded in
          -- after the multiply, hence never scaled.  See the drain paragraph.
          assert not (state = S_MUL and inflight /= 0)
            report "attn_softmax: the s rescale started with weights still in "
                 & "the cone -- they are folded in AFTER the multiply and are "
                 & "therefore never scaled"
            severity error;
        end if;

        -- =================================================================
        -- THE CONE.  One listed operation per stage, no ready anywhere.  It
        -- advances unconditionally; the front end guarantees at most one push
        -- per cycle and never pushes while a rescale is in progress.
        -- =================================================================
        x_v(1) <= '0';                      -- default; S_ZED overrides below
        for i in 2 to CONE_ST loop
          x_v(i) <= x_v(i-1);
        end loop;

        -- X1: the domain compare, and the clamp of z to <= 0.  Two compares on
        -- the SAME operand, so they are parallel, plus one 2:1 select -- one
        -- saturate, by attn_kv_quant's convention.  z > 0 is a design
        -- invariant and not a data case; it is clamped so a violation degrades
        -- instead of indexing out of range, and err_r reports it.
        if x_v(1) = '1' then
          if x1_z <= Z_LO then x2_do <= '1'; else x2_do <= '0'; end if;
          if x1_z > 0 then
            x2_z <= (others => '0');
          else
            x2_z <= x1_z;
          end if;
        end if;

        -- X2: the offset add ALONE.  offset = z + 16*2^Q, in [0, 2^17].
        --
        -- The result is taken as a SLICE of the wide sum, not as
        --     unsigned(resize(x2_z + OFF_MID, OFF_W))
        -- and that is not a style choice.  numeric_std's `resize` on a `signed`
        -- keeps the SIGN bit and drops the top MAGNITUDE bit, so resizing the
        -- value 65536 -- which needs 18 signed bits -- down to OFF_W = 17 gives
        -- ZERO.  65536 is reached at exactly z = 0, i.e. at the score that just
        -- set the maximum, so the top code point e_p = 4096 came out as
        -- e_p = 0 and every other value in the unit was right.  This is the
        -- SAME numeric_std trap as the `resize(-ext, IN_W)` defect recorded in
        -- docs/debugging/2026-08-27_attn-kv-quant-abs-resize.md, in the same
        -- subsystem, one unit later.  0 <= sum <= 2^17 here by construction --
        -- x2_z is clamped to (-2^17, 0] by the stage above -- so the low OFF_W
        -- bits ARE the value and no resize is needed at all.  Do not "tidy"
        -- this back into a resize to make the widths line up.
        x3_do <= x2_do;
        if x_v(2) = '1' then
          off_v  := x2_z + OFF_MID;
          x3_off <= unsigned(off_v(OFF_W-1 downto 0));
        end if;

        -- X3: the index and fraction split.  Muxes and wiring only.
        --   idx  = offset(GRID_SH+IDX_W-1 downto GRID_SH)
        --   frac = offset(GRID_SH-1 downto 0) * (2^Q / GRID_CNT)
        -- offset = 16*2^Q exactly (z = 0) would give idx = ROM_N, which the
        -- table does not hold.  fx_exp_q clamps the INDEX and lets frac reach
        -- 2^Q, which makes the interpolation return EXP_ROM(ROM_N) exactly and
        -- is why FRAC_W is Q+1 and not Q.  Clamping frac to 2^Q - 1 instead is
        -- EQUIVALENT (the Q30 shortfall is 15,883 against a rounding step of
        -- 2^18); clamping it to 0 is NOT and loses the top code point.  Both
        -- measured, as reference mutations C3 and C3b.
        x4_do <= x3_do;
        if x_v(3) = '1' then
          if x3_off(OFF_W-1) = '1' then          -- offset = 16*2^Q exactly
            x4_idx  <= to_unsigned(ROM_N-1, IDX_W);
            x4_frac <= to_unsigned(2**Q, FRAC_W);
          else
            x4_idx  <= x3_off(GRID_SH+IDX_W-1 downto GRID_SH);
            x4_frac <= resize(x3_off(GRID_SH-1 downto 0)
                              & to_unsigned(0, Q - GRID_SH), FRAC_W);
          end if;
        end if;

        -- X4: two PARALLEL ROM_N-way bus muxes, both on the same index.
        x5_do <= x4_do;
        if x_v(4) = '1' then
          x5_lo   <= to_unsigned(EXP_ROM(to_integer(x4_idx)), ROM_W);
          x5_hi   <= to_unsigned(EXP_ROM(to_integer(x4_idx) + 1), ROM_W);
          x5_frac <= x4_frac;
        end if;

        -- X5: the table delta ALONE.  EXP_ROM is monotone increasing, so this
        -- is non-negative and DLT_W bits hold it; that is what makes the
        -- multiply below fit one DSP tile.
        x6_do <= x5_do;
        if x_v(5) = '1' then
          x6_dlt  <= resize(x5_hi - x5_lo, DLT_W);
          x6_lo   <= x5_lo;
          x6_frac <= x5_frac;
        end if;

        -- X6: the MULTIPLY ALONE.  DLT_W x FRAC_W unsigned = 26 x 13, i.e.
        -- 27 x 14 signed, one DSP48E2 tile.  BOTH operands are narrowed; the
        -- 2026-08-26 gdn_silu note records that narrowing only the delta
        -- changes no DSP count, because the multiplicand stays wide.
        x7_do <= x6_do;
        if x_v(6) = '1' then
          x7_prod <= x6_dlt * x6_frac;
          x7_lo   <= x6_lo;
        end if;

        -- X7: the interpolation add ALONE.  The >> Q is a CONSTANT slice, i.e.
        -- wiring, not a barrel shift, and both terms are non-negative so the
        -- slice is exactly the floor that fx_exp_q's >> gives.
        x8_do <= x7_do;
        if x_v(7) = '1' then
          x8_int <= x7_lo
                  + resize(x7_prod(DLT_W+FRAC_W-1 downto Q), ROM_W);
        end if;

        -- X8: the round bias ADD alone.
        x9_do <= x8_do;
        if x_v(8) = '1' then
          x9_sum <= resize(x8_int, ROM_W+1) + CONE_BIAS;
        end if;

        -- X9: the constant slice and the domain select.  x9_sum <= 2^30 + 2^17
        -- so the slice is at most 2^Q, which E_W bits hold exactly.
        ep_v_r <= x_v(CONE_ST);
        if x_v(CONE_ST) = '1' then
          if x9_do = '1' then
            ep_r <= (others => '0');
          else
            ep_r <= x9_sum(CONE_SH+E_W-1 downto CONE_SH);
          end if;
        end if;

        -- ---- the fold.  One wide add, at the cone's output. --------------
        -- S_DRAIN is what guarantees a rescale never overlaps this.
        if ep_v_r = '1' then
          acc := resize(s_r, S_W+1) + resize(ep_r, S_W+1);
          if acc(S_W) = '1' then
            s_r   <= (others => '1');
            ovf_r <= '1';
          else
            s_r <= acc(S_W-1 downto 0);
          end if;
        end if;

        -- ---- the in-flight count.  Both edges can land on the same cycle. -
        inc := 0; dec := 0;
        if state = S_ZED then inc := 1; end if;
        if ep_v_r = '1'   then dec := 1; end if;
        inflight <= inflight + inc - dec;

        -- ---- the rescale handshake, independent of the FSM ---------------
        -- rs_valid is raised as soon as f is known, NOT after s has been
        -- rescaled, so the array's 8-cycle pass overlaps this unit's own
        -- multiply instead of following it.
        if rs_v_r = '1' and rs_ack = '1' then
          rs_v_r <= '0';
          rs_tk  <= '1';
        end if;

        case state is

          -- ================= idle: latch the head ========================
          when S_IDLE =>
            if start = '1' then
              cfg_tk  <= '1';       -- RULE 2: the instant, made observable
              first_r <= '1';
              s_r     <= (others => '0');
              m_g     <= (others => '0');
              ovf_r   <= '0';
              err_r   <= '0';
              nrs_r   <= (others => '0');
              last_h  <= '0';
              state   <= S_RUN;
            end if;

          -- ================= accept one score ============================
          when S_RUN =>
            if sc_valid = '1' then
              sc_h   <= sc_q12;     -- RULE 2: latched, never read live
              last_h <= sc_last;
              state  <= S_CEIL;
            end if;

          -- ---- ceil to the grid: one wide add, then a constant mask -----
          -- ceil_grid(v) = (v + GRID_CNT-1) with the low GRID_SH bits cleared.
          -- Clearing bits is WIRING, so this is ONE operation, and it is a true
          -- ceiling for negative v where a C-style divide would truncate
          -- toward zero and be wrong for exactly the scores that dominate.
          when S_CEIL =>
            ceil_v := resize(sc_h, MG_W) + to_signed(GRID_CNT - 1, MG_W);
            ceil_v(GRID_SH-1 downto 0) := (others => '0');
            sc_ceil <= ceil_v;
            state   <= S_TEST;

          -- ---- the rise test.  A compare and a subtract on the SAME
          -- operands, so they are parallel and not in series.
          --
          -- ceil_grid(max(m_g, sc)) = max(m_g, ceil_grid(sc)) because m_g is
          -- ALREADY on the grid.  That identity is what removes a second
          -- ceiling from this path and lets the whole test be one compare.
          when S_TEST =>
            d_r <= resize(sc_ceil, MG_W+1) - resize(m_g, MG_W+1);
            if first_r = '1' then
              m_g     <= sc_ceil;
              first_r <= '0';
              state   <= S_ZED;
            elsif sc_ceil > m_g then      -- STRICT; see the header
              state <= S_DRAIN;
            else
              state <= S_ZED;
            end if;

          -- ---- drain the cone before touching s.  See the header. -------
          when S_DRAIN =>
            if inflight = 0 then
              state <= S_K;
            end if;

          -- ---- k = d asr GRID_SH, a constant slice, and one compare -----
          when S_K =>
            k_sl <= unsigned(d_r(MG_W downto GRID_SH));
            if d_r(MG_W downto GRID_SH)
               <= to_signed(ROM_N, MG_W+1-GRID_SH) then
              k_ok <= '1';
            else
              k_ok <= '0';   -- k > ROM_N: the FACTOR is 0.  A range branch.
            end if;
            state <= S_IDX;

          -- ---- one narrow subtract feeding a 2:1 select -----------------
          when S_IDX =>
            if k_ok = '1' then
              rom_ix <= to_unsigned(ROM_N, IDX_W+1)
                      - resize(k_sl(IDX_W downto 0), IDX_W+1);
            else
              rom_ix <= (others => '0');
            end if;
            state <= S_ROM;

          -- ---- one bus mux ---------------------------------------------
          when S_ROM =>
            f_lo  <= to_unsigned(EXP_ROM(to_integer(rom_ix)), ROM_W);
            state <= S_FB;

          -- ---- one add --------------------------------------------------
          when S_FB =>
            f_sum <= resize(f_lo, ROM_W+1) + CONE_BIAS;
            state <= S_F;

          -- ---- a constant slice and a 2:1 select, and OFFER the pass ----
          when S_F =>
            if k_ok = '1' then
              f_r <= f_sum(CONE_SH+E_W-1 downto CONE_SH);
            else
              f_r <= (others => '0');
            end if;
            rs_v_r <= '1';
            rs_tk  <= '0';
            nrs_r  <= nrs_r + 1;
            state  <= S_MUL;

          -- ---- one MULTIPLY.  S_W x E_W unsigned = 26 x 13, i.e. 27 x 14
          -- signed, one DSP48E2 tile.
          when S_MUL =>
            sf    <= s_r * f_r;
            state <= S_SB;

          -- ---- one add --------------------------------------------------
          when S_SB =>
            sf_b  <= sf + S_BIAS;
            state <= S_SS;

          -- ---- a constant slice, and the maximum takes its new value ----
          -- f <= 2^Q, so s*f >> Q <= s: the result cannot grow and no
          -- saturation is possible here, which is why none is written.
          when S_SS =>
            s_r   <= sf_b(S_W+Q-1 downto Q);
            m_g   <= sc_ceil;
            state <= S_RS;

          -- ---- hold the pass until the array acks.  RULE 1 shape. -------
          when S_RS =>
            if rs_tk = '1' then
              state <= S_ZED;
            end if;

          -- ---- one wide subtract, and push into the cone ----------------
          when S_ZED =>
            zv := resize(sc_h, Z_W) - resize(m_g, Z_W);
            if zv > 0 then
              -- A design invariant, not a data case.  Sticky rather than
              -- fatal, so a job that trips it still terminates and the
              -- consumer sees a flag instead of a hang.
              err_r <= '1';
            end if;
            x1_z   <= zv;
            x_v(1) <= '1';
            if last_h = '1' then
              state <= S_FIN;
            else
              state <= S_RUN;
            end if;

          -- ---- the head is finished when the cone is EMPTY --------------
          -- Not when the last score was accepted.  Signalling done with
          -- weights still in the pipeline publishes an s that is missing its
          -- own last terms, in range and the right shape.
          when S_FIN =>
            if inflight = 0 then
              state <= S_DONE;
            end if;

          -- ================= RULE 1: held, not pulsed ====================
          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then
              -- Do NOT clear done_r here.  The trailing assignment below
              -- clears it once the state leaves S_DONE.  An explicit clear in
              -- this branch is a LATER assignment to the same signal and wins,
              -- which destroys the pulse outright whenever done_ack is tied
              -- high -- exactly the default a testbench uses.  Written and
              -- caught once already, in gdn_head_emit.
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
