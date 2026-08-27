-- rtl/gdn_y_emit.vhd
-- Subsystem B, SITE 13: the gated-norm product and the 24-head renormalization
-- to a single `y_exp`.  This is the last arithmetic stage of a GDN block.
--
-- WHAT IT COMPUTES.  Per the design spec's step 7 and `build_norm_gated`
-- (qwen35.cpp:247-255), each head's output is gated AFTER the norm:
--
--     y_h = rmsnorm(o_h, ssm_norm) * silu(z_h)
--
-- and then all the heads on this card are folded onto ONE exponent, because
-- what consumes them is `ssm_out`, a matvec that takes a single scale for the
-- whole 24 x 128 vector.  The head count is **24, not 16**: the model has 48
-- GDN value heads (`num_v_heads = ssm_dt_rank = 48`) and tensor parallelism
-- splits them by head across 2 cards.  16 is the KEY head count
-- (`ssm_group_count = 16`), a different quantity, and it is 8 per card after
-- the same split.  The spec said 16 in two places until 2026-08-26; both are
-- corrected.  Nothing catches this confusion structurally, because both head
-- types are 128 wide.
--
-- THE RECIPE, in the same block-floating shape gdn_head_emit uses one level
-- down, which is not a coincidence -- it is the same problem (many per-block
-- exponents, one consumer that wants a single grid) at a coarser granularity:
--
--     p[h][j]  = o_mant[h][j] * z_mant[h][j]        -- s32, |p| <= 2^30
--     e_p[h]   = o_exp[h] + z_exp[h]                -- one per head
--     e_y_raw  = min over h of e_p[h]
--     p_al     = floor_shr(p[h][j], e_p[h] - e_y_raw)
--     sh       = max(0, msb_pos(max|p_al|) - 14)
--     y[h][j]  = sat16(round_shift(p_al, sh))
--     y_exp    = e_y_raw - sh
--
-- THE TWO SHIFT BRANCHES the spec calls for (the C MJ5-1 class) are here as
-- the alignment and the requantize respectively, and BOTH are right-shifts:
-- the alignment is right because e_y_raw is a MINIMUM, and the requantize is
-- right because sh is clamped at 0.  There is deliberately no left-shift path.
-- A left shift would be needed only if the common exponent were chosen as a
-- maximum, which would also make the alignment lossy in the opposite and worse
-- direction (dropping the top of the largest head rather than the bottom of
-- the smallest).
--
-- WHY THE PRODUCT IS EXACT.  o_mant and z_mant are both int16, so the product
-- is at most 32768 * 32768 = 2^30 and fits s32 with a bit to spare.  No
-- rounding happens at the multiply; the only rounding in this unit is the
-- single requantize at the end, which is what keeps the gate from
-- double-rounding against the norm that precedes it.
--
-- WHY THREE PASSES.  Identical argument to gdn_head_emit: amax is over the
-- ALIGNED values, so it cannot be known until every element is aligned, and
-- the requantize needs it.  The tempting one-pass shortcut via
-- msb_pos(p_al) = msb_pos(p) - (e_p - e_y_raw) is FALSE for negatives, because
-- floor_shr rounds toward minus infinity and can carry a negative magnitude UP
-- across a power of two: -(2^k - 1) >> 1 is -2^(k-1), msb k-1, against
-- msb_pos(|v|) - 1 = k-2.  See rtl/gdn_head_emit.vhd, where the same shortcut
-- was considered and rejected, and sim/tb_gdn_y_emit.vhd, whose vectors carry
-- the case.
--
-- COST.  Pass A is free: it consumes elements at the rate the norm and gate
-- produce them, and its multiply is the only DSP in the unit.  Passes B and C
-- are HEADS*DIM cycles each, so **~6,150 cycles per GDN layer** at 24 x 128
-- (this unit runs ONCE per layer, spanning all heads, not once per head).
--
-- Deliberately NOT stated as a percentage of the state sweep; see the same
-- note in rtl/gdn_head_emit.vhd.  The spec's 589,824 figure is quoted for two
-- different LANES values in two places and its per-layer formula uses H = 16,
-- the stale KEY head count, so a percentage against it would be arithmetic on
-- a disputed number.  The design conclusion is unaffected: this unit is
-- scalar because ~6,150 cycles per layer is small against any candidate.
--
-- STRUCTURE.  One operation per state -- never two of {barrel shift, wide add,
-- wide compare, bus mux, multiply} in series.  Expressed as pipeline stages,
-- since both reduction passes are II=1 streams.  Note in particular that the
-- per-head exponent lookup is a HEADS-to-1 mux and gets its OWN stage; folding
-- it into the shift stage would put a mux in front of a barrel shift, which is
-- the exact pairing that held rmsnorm_rs at 117.2 MHz.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity gdn_y_emit is
  generic(
    HEADS : positive := 24;    -- VALUE heads per card: 48 / 2.  Not 16.
    DIM   : positive := 128    -- head_v_dim
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;

    -- ---- pass A: the gated product, streamed one element per cycle --------
    -- in_o is rmsnorm_bf's o_mant element, in_z is gdn_silu's output element.
    -- in_e is e_p for the head this element belongs to, i.e. that head's
    -- o_exp + z_exp; it is sampled on in_hfirst and held for the head.
    in_valid  : in std_logic;
    in_hfirst : in std_logic;                  -- first element of a head
    in_o      : in signed(15 downto 0);
    in_z      : in signed(15 downto 0);
    in_e      : in signed(7 downto 0);

    -- ---- result, streamed in the same (head, element) order ---------------
    o_valid : out std_logic;
    o_mant  : out signed(15 downto 0);
    o_last  : out std_logic;
    -- Settled at the end of pass B, so it is already stable when the first
    -- o_valid goes out.  A consumer may latch it on the first element.
    y_exp   : out signed(7 downto 0);
    done    : out std_logic;
    -- One cycle with done if any element saturated.  Not fatal, but it means
    -- the block lost its top end, so it is reported rather than swallowed.
    o_sat   : out std_logic
  );
end entity;

architecture rtl of gdn_y_emit is

  constant NTOT : integer := HEADS * DIM;

  -- msb position of an unsigned, 0 for zero.  Same convention as
  -- mv4i_msb_pos_u and gdn_head_emit; the masked-operand rule elsewhere in B
  -- depends on msb_pos(0) = 0, so this must not "improve".
  function msb_pos(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  function sat16(v : signed) return signed is
  begin
    if    v >  to_signed( 32767, v'length) then return to_signed( 32767, 16);
    elsif v < to_signed(-32768, v'length) then return to_signed(-32768, 16);
    else  return resize(v, 16);
    end if;
  end function;

  -- The product store.  PINNED to block RAM rather than inferred, for the same
  -- reason gdn_head_emit pins its column store: unpinned, Vivado switches
  -- primitive with the generics, which makes resource tables incomparable
  -- across configurations, and distributed RAM is the primitive rmsnorm.vhd's
  -- S_RAW comment records producing NON-DETERMINISTIC hardware output when
  -- inferred UNINITIALIZED in the congested engine.  This unit does not have
  -- that bug -- pass A writes every location before pass B reads any -- but
  -- pinning makes that structural rather than a property of the FSM.
  type mem_t is array (0 to NTOT-1) of std_logic_vector(31 downto 0);
  signal mem : mem_t;
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
  signal mem_q : std_logic_vector(31 downto 0) := (others => '0');

  -- Per-head exponents.  HEADS x 8 bits of registers, deliberately NOT stored
  -- alongside each product: that would widen the RAM from 32 to 40 bits and
  -- buy nothing, since e_p is constant within a head and the head index is
  -- regenerated for free by the read counters.
  type ep_t is array (0 to HEADS-1) of signed(7 downto 0);
  signal ep : ep_t := (others => (others => '0'));

  type state_t is (S_FILL, S_AMAX, S_EMIT, S_DONE);
  signal state : state_t := S_FILL;

  -- write side
  signal w_h, w_j : integer range 0 to NTOT := 0;
  signal w_addr   : integer range 0 to NTOT := 0;
  signal a_v      : std_logic := '0';
  signal a_prod   : signed(31 downto 0) := (others => '0');
  signal a_addr   : integer range 0 to NTOT-1 := 0;

  signal e_y_raw  : signed(7 downto 0) := (others => '0');
  signal sh_r     : integer range 0 to 63 := 0;
  signal y_exp_r  : signed(7 downto 0) := (others => '0');

  -- read side, shared shape between the two reduction passes
  signal r_addr : integer range 0 to NTOT := 0;
  signal r_h, r_j : integer range 0 to NTOT := 0;
  signal p1_v, p2_v, p3_v, p4_v, p5_v : std_logic := '0';
  -- The last-element flag rides the pipeline rather than being derived from
  -- the drain counter at the end.  Deriving it there put o_last ONE CYCLE
  -- AFTER the final o_valid: the last element reaches the emit stage at
  -- drain = DEPTH - 1, but the state transition (and so the flag) happens at
  -- drain = DEPTH.  Found by tracing the drain, not by simulation, because a
  -- consumer that only counts elements would never notice.
  signal p1_l, p2_l, p3_l, p4_l, p5_l : std_logic := '0';
  signal p1_h : integer range 0 to HEADS-1 := 0;
  signal p2_ep : signed(7 downto 0) := (others => '0');
  signal p2_prod : signed(31 downto 0) := (others => '0');
  signal p3_shj : integer range 0 to 63 := 0;
  signal p3_prod : signed(31 downto 0) := (others => '0');
  signal p4_al  : signed(31 downto 0) := (others => '0');
  signal p5_abs : unsigned(31 downto 0) := (others => '0');
  signal p5_bsum : signed(31 downto 0) := (others => '0');
  signal amax   : unsigned(31 downto 0) := (others => '0');

  -- Depth from issuing a read address to the reduce/emit stage.
  constant DEPTH : integer := 5;
  signal drain : integer range 0 to DEPTH := 0;

  signal o_valid_r : std_logic := '0';
  signal o_mant_r  : signed(15 downto 0) := (others => '0');
  signal o_last_r  : std_logic := '0';
  signal sat_r     : std_logic := '0';
  signal done_r    : std_logic := '0';

begin
  o_valid <= o_valid_r;
  o_mant  <= o_mant_r;
  o_last  <= o_last_r;
  y_exp   <= y_exp_r;
  done    <= done_r;
  o_sat   <= sat_r;

  assert HEADS > 0 and DIM > 0
    report "gdn_y_emit: HEADS and DIM must be positive" severity failure;

  process(clk)
    variable shj_v : integer;
    variable rnd   : signed(31 downto 0);
    variable bias  : signed(31 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_FILL;
        w_h <= 0; w_j <= 0; w_addr <= 0;
        r_addr <= 0; r_h <= 0; r_j <= 0; drain <= 0;
        a_v <= '0';
        p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0'; p5_v <= '0';
        p1_l <= '0'; p2_l <= '0'; p3_l <= '0'; p4_l <= '0'; p5_l <= '0';
        amax <= (others => '0');
        o_valid_r <= '0'; o_last_r <= '0'; done_r <= '0'; sat_r <= '0';
      else
        done_r    <= '0';
        o_valid_r <= '0';
        o_last_r  <= '0';

        -- synchronous read, one cycle, shared by both read passes
        if r_addr < NTOT then
          mem_q <= mem(r_addr);
        end if;

        case state is

          -- ============ pass A: the gated product =========================
          -- Costs no cycles of its own: it consumes at the rate the norm and
          -- the gate produce.  The multiply is registered before the store, so
          -- the DSP drives a register and not the RAM's data input.
          when S_FILL =>
            sat_r <= '0';
            -- stage 1: multiply
            a_v <= in_valid;
            if in_valid = '1' then
              a_prod <= in_o * in_z;
              a_addr <= w_addr;
              if in_hfirst = '1' then
                ep(w_h) <= in_e;
                -- e_y_raw is the running MINIMUM over heads.  Seeded from head
                -- 0 rather than a sentinel, so no exponent is unrepresentable.
                if w_h = 0 or in_e < e_y_raw then
                  e_y_raw <= in_e;
                end if;
              end if;
              if w_j = DIM-1 then
                w_j <= 0; w_h <= w_h + 1;
              else
                w_j <= w_j + 1;
              end if;
              w_addr <= w_addr + 1;
            end if;
            -- stage 2: store
            if a_v = '1' then
              mem(a_addr) <= std_logic_vector(a_prod);
            end if;

            if w_addr = NTOT and a_v = '0' then
              w_h <= 0; w_j <= 0; w_addr <= 0;
              r_addr <= 0; r_h <= 0; r_j <= 0;
              amax <= (others => '0'); drain <= 0;
              p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0'; p5_v <= '0';
              p1_l <= '0'; p2_l <= '0'; p3_l <= '0'; p4_l <= '0'; p5_l <= '0';
              state <= S_AMAX;
            end if;

          -- ============ pass B: align and reduce amax ======================
          when S_AMAX =>
            -- stage 1: address issued above; also carry the head index, which
            -- the read counters regenerate for free
            if r_addr < NTOT then
              p1_v <= '1'; p1_h <= r_h;
              if r_addr = NTOT-1 then p1_l <= '1'; else p1_l <= '0'; end if;
              r_addr <= r_addr + 1;
              if r_j = DIM-1 then r_j <= 0; r_h <= r_h + 1;
              else                r_j <= r_j + 1; end if;
            else
              p1_v <= '0'; p1_l <= '0';
            end if;

            -- stage 2: the HEADS-to-1 exponent mux ALONE, and the RAM unpack
            p2_v <= p1_v; p2_l <= p1_l;
            if p1_v = '1' then
              p2_ep   <= ep(p1_h);
              p2_prod <= signed(mem_q);
            end if;

            -- stage 3: the narrow exponent subtract ALONE
            p3_v <= p2_v; p3_l <= p2_l;
            if p2_v = '1' then
              shj_v := to_integer(p2_ep - e_y_raw);
              -- e_y_raw is the minimum so shj_v >= 0 by construction.  The
              -- clamp is the project's shift convention and also stops a
              -- corrupted e_p from producing a LEFT shift, which could
              -- overflow s32 silently.
              if shj_v < 0 then shj_v := 0; elsif shj_v > 63 then shj_v := 63; end if;
              p3_shj  <= shj_v;
              p3_prod <= p2_prod;
            end if;

            -- stage 4: the barrel shift ALONE.  FLOOR, i.e. arithmetic right.
            p4_v <= p3_v; p4_l <= p3_l;
            if p3_v = '1' then
              p4_al <= shift_right(p3_prod, p3_shj);
            end if;

            -- stage 5: absolute value ALONE
            p5_v <= p4_v; p5_l <= p4_l;
            if p4_v = '1' then
              if p4_al < 0 then p5_abs <= unsigned(-p4_al);
              else              p5_abs <= unsigned(p4_al);
              end if;
            end if;

            -- stage 6: the compare ALONE
            if p5_v = '1' then
              if p5_abs > amax then amax <= p5_abs; end if;
            end if;

            if r_addr >= NTOT then
              if drain = DEPTH then
                if msb_pos(amax) - 14 > 0 then
                  sh_r    <= msb_pos(amax) - 14;
                  y_exp_r <= e_y_raw - to_signed(msb_pos(amax) - 14, 8);
                else
                  sh_r    <= 0;
                  y_exp_r <= e_y_raw;
                end if;
                r_addr <= 0; r_h <= 0; r_j <= 0; drain <= 0;
                p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0'; p5_v <= '0';
                p1_l <= '0'; p2_l <= '0'; p3_l <= '0'; p4_l <= '0'; p5_l <= '0';
                state <= S_EMIT;
              else
                drain <= drain + 1;
              end if;
            end if;

          -- ============ pass C: align again, round, saturate, stream =======
          when S_EMIT =>
            if r_addr < NTOT then
              p1_v <= '1'; p1_h <= r_h;
              if r_addr = NTOT-1 then p1_l <= '1'; else p1_l <= '0'; end if;
              r_addr <= r_addr + 1;
              if r_j = DIM-1 then r_j <= 0; r_h <= r_h + 1;
              else                r_j <= r_j + 1; end if;
            else
              p1_v <= '0'; p1_l <= '0';
            end if;

            p2_v <= p1_v; p2_l <= p1_l;
            if p1_v = '1' then
              p2_ep   <= ep(p1_h);
              p2_prod <= signed(mem_q);
            end if;

            p3_v <= p2_v; p3_l <= p2_l;
            if p2_v = '1' then
              shj_v := to_integer(p2_ep - e_y_raw);
              if shj_v < 0 then shj_v := 0; elsif shj_v > 63 then shj_v := 63; end if;
              p3_shj  <= shj_v;
              p3_prod <= p2_prod;
            end if;

            p4_v <= p3_v; p4_l <= p3_l;
            if p3_v = '1' then
              p4_al <= shift_right(p3_prod, p3_shj);   -- same FLOOR alignment
            end if;

            -- stage 5: the rounding bias ALONE.  round_shift(v, s) is
            -- floor_shr(v + 2^(s-1), s), i.e. round-half-toward-plus-infinity,
            -- matching mv4i_round_shift and every other B site.  At sh_r = 0
            -- the bias is zero and this is a no-op.
            --
            -- Width: |p_al| <= 2^30 (the product bound) and sh_r <= 30 - 14
            -- = 16, so bias <= 2^15 and the sum is under 2^30 + 2^15 < 2^31.
            -- Fits s32.  This bound is DERIVED, not transcribed: int16's
            -- asymmetric range means the product maximum is (-32768)^2 = 2^30
            -- exactly, attainable, so the bound is INCLUSIVE.  Writing it
            -- strict is the off-by-one that shipped in rmsnorm_bf's assert on
            -- 2026-08-26 and failed on legal input.
            p5_v <= p4_v; p5_l <= p4_l;
            if p4_v = '1' then
              if sh_r = 0 then
                p5_bsum <= p4_al;
              else
                bias := shift_left(to_signed(1, 32), sh_r - 1);
                assert p4_al <=  shift_left(to_signed(1, 32), 30)
                   and p4_al >= -shift_left(to_signed(1, 32), 30)
                  report "gdn_y_emit: aligned product exceeds the 2^30 bound "
                       & "the bias width argument depends on"
                  severity failure;
                p5_bsum <= p4_al + bias;
              end if;
            end if;

            -- stage 6: the shift, the saturate and the emit
            if p5_v = '1' then
              rnd := shift_right(p5_bsum, sh_r);
              o_mant_r  <= sat16(rnd);
              o_valid_r <= '1';
              o_last_r  <= p5_l;
              if rnd > to_signed(32767, 32) or rnd < to_signed(-32768, 32) then
                sat_r <= '1';
              end if;
            end if;

            if r_addr >= NTOT then
              if drain = DEPTH then
                drain <= 0;
                state <= S_DONE;
              else
                drain <= drain + 1;
              end if;
            end if;

          when S_DONE =>
            done_r <= '1';
            w_h <= 0; w_j <= 0; w_addr <= 0;
            state <= S_FILL;

        end case;
      end if;
    end if;
  end process;

end architecture;
