-- rtl/gdn_head_emit.vhd
-- Subsystem B, stage 6 / SITE 12: fold one head to a common grid and BFP
-- requantize it, so the head vector can enter the output norm.
--
-- WHY THIS EXISTS.  gdn_recur_pipe emits the output dot as one (o_acc, e_o)
-- pair PER COLUMN, and e_o[j] = se_new[j] + 18 varies per column because each
-- column renormalises its own state independently.  A per-column exponent is
-- not something rmsnorm can consume: rmsnorm takes a single x_exp for the
-- whole vector.  Something has to pick one grid for the head and move every
-- column onto it.  That is this unit, and until it existed the recurrence
-- output had nowhere to go.
--
-- THE RECIPE, normative in the design spec's stage 6 and implemented exactly
-- as ref/gdn_err.c lines 514-523 implement it:
--
--   e_h      = min over j of e_o[j]
--   o_al[j]  = floor_shr(o_acc[j], e_o[j] - e_h)        -- FLOOR, right only
--   sh_h     = max(0, msb_pos(max|o_al|) - 14)
--   o_head[j]= sat16(round_shift(o_al[j], sh_h))
--   e_head   = e_h - sh_h
--
-- Two details in that recipe are load-bearing and easy to get wrong:
--
--   * The alignment is FLOOR (arithmetic right shift), not round.  The
--     requantize that follows rounds; doing it twice would double-round.
--   * e_h is the MINIMUM, so every shift is a right shift and no column can
--     overflow during alignment.  Taking the max instead would need left
--     shifts and could not be done in place.
--
-- WHY THREE PASSES AND NOT TWO.  amax is over the ALIGNED values o_al, so it
-- cannot be known until every column has been aligned, and the round/saturate
-- needs sh_h which comes from amax.  A tempting shortcut is to compute the
-- amax exponent during the first pass without alignment, using
--
--     msb_pos(o_al[j]) = msb_pos(o_acc[j]) - (e_o[j] - e_h)
--
-- which would remove a whole pass because e_h is a common additive term and
-- drops out of an argmax.  That identity is FALSE for negative values, and the
-- counterexample is small: v = -(2^k - 1) with a shift of 1 floors to -2^(k-1),
-- whose msb is k-1, while msb_pos(|v|) - 1 = k-2.  floor_shr rounds toward
-- minus infinity, so it can round a negative magnitude UP across a power of
-- two.  Do not re-derive this shortcut; it silently under-shifts one head in
-- roughly the fraction of cases where the max lands on such a value, which is
-- exactly the case that then saturates.
--
-- So: pass A captures, pass B aligns and reduces amax, pass C aligns again and
-- emits.  Pass B and pass C both barrel-shift rather than pass B storing o_al,
-- because the shift is one stage of an II=1 pipeline and the storage would be
-- 40 bits x DIM of extra registers for nothing.
--
-- DOUBLE BUFFERED, and that is not an optimisation.  MEASURED with a cycle
-- probe on the correctness testbench: fill is 128 cycles and the two reduce
-- passes are **268**, for 396 total per head.  The first version of this unit
-- had ONE bank, so during those 268 cycles it did not examine `in_valid` at
-- all and had no back-pressure port.  gdn_recur_pipe starts the next head
-- immediately (its own head-boundary double buffer measures 0 wait after any
-- head of 16 columns or more), so the next head's first ~67 column results
-- would have been SILENTLY DROPPED.  That is a correctness bug at integration,
-- not merely a throughput one, and nothing in either unit would have reported
-- it.
--
-- With two banks the reduce hides completely.  gdn_recur_pipe produces one
-- column result every S_DIM/LANES = 4 cycles at LANES = 32, so a 128-column
-- head takes 512 cycles to arrive, against 268 to reduce. `in_ready` is
-- provided anyway: it should never deassert in the intended configuration, and
-- a producer that sees it deassert has learned something worth knowing rather
-- than losing data quietly.
--
-- COST.  Fill is free, running at the rate results arrive.  Reduce is 268
-- cycles per head and at 24 value heads per card **~6,432 cycles per GDN
-- layer**, all of it hidden behind the next head's fill.
--
-- Deliberately NOT stated as a percentage of the state sweep.  An earlier
-- version of this comment said "~1.1% of the 589,824-cycle sweep", which
-- cannot be checked right now: the spec quotes 589,824 for LANES = 8 at
-- section 2.6 and for LANES = 32 at section 3.1, and those cannot both hold,
-- and the per-layer formula it derives from (S*S*H/LANES = 262,144/LANES)
-- uses H = 16, the stale KEY head count, where 24 value heads per card give
-- 393,216.  Until that is resolved the honest figure is the cycle count, not
-- a fraction of a number in dispute.
--
-- The design conclusion does not depend on it: the unit is scalar and has no
-- LANES generic because 270 cycles per head is small against ANY of the
-- candidate sweep figures.
--
-- STRUCTURE.  One operation per state -- never two of {barrel shift, wide add,
-- wide compare, bus mux, multiply} in series.  Here that is expressed as
-- pipeline stages rather than FSM states, since both reduction passes are
-- II=1 streams: memory read, then subtract, then shift, then abs, then reduce.
--
-- The column store is a SYNCHRONOUS-read RAM written before it is read, which
-- is the idiom Vivado maps to block RAM.  It is deliberately not a
-- combinationally-read indexed array: rmsnorm.vhd's S_RAW comment records that
-- such an array was inferred as UNINITIALIZED distributed RAM in the congested
-- engine and produced NON-DETERMINISTIC hardware output.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity gdn_head_emit is
  generic(
    DIM : positive := 128
  );
  port(
    clk   : in  std_logic;
    rst   : in  std_logic;

    -- ---- pass A: capture, driven straight from gdn_recur_pipe -------------
    -- in_valid is that unit's o_res_valid; the pair is its (o_acc, o_e_o).
    -- Columns arrive in order, so no index is carried.
    in_valid : in std_logic;
    in_acc   : in signed(39 downto 0);
    in_e_o   : in signed(7 downto 0);
    -- Low when the bank about to be written still holds an unreduced head.
    -- In the intended configuration it never falls, because the reduce (268
    -- cycles) is shorter than a head's arrival (512); it exists so that a
    -- producer running faster than expected STALLS instead of losing columns.
    in_ready : out std_logic;

    -- ---- result ----------------------------------------------------------
    -- The whole head at once, which is the shape rmsnorm's x_mant takes.
    done     : out std_logic;
    o_mant   : out std_logic_vector(DIM*16-1 downto 0);
    o_e_head : out signed(7 downto 0);
    -- Raised for one cycle with done if any column saturated in sat16.  A
    -- saturation here is not fatal but it means the head lost its top end, so
    -- it is reported rather than swallowed.
    o_sat    : out std_logic
  );
end entity;

architecture rtl of gdn_head_emit is

  -- msb position of an unsigned, 0 for zero.  Same convention as
  -- mv4i_msb_pos_u and as gdn_recur.vhd's msb_pos: this is the definition the
  -- masked-operand rule elsewhere in B depends on, so it must not "improve".
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

  -- 48 bits per column: 40 of o_acc and 8 of e_o.  TWO banks, so head h+1
  -- fills while head h reduces; bank b occupies [b*DIM, (b+1)*DIM).
  constant W_MEM : integer := 48;
  type mem_t is array (0 to 2*DIM-1) of std_logic_vector(W_MEM-1 downto 0);
  signal mem : mem_t;
  -- PINNED, not left to inference.  Measured unpinned, Vivado chose
  -- distributed RAM at DIM = 64 and 128 (63 and 126 RAM cells) and then
  -- switched to one RAMB36 at DIM = 256.  An inference that changes primitive
  -- with a generic is a reproducibility problem on its own -- the resource
  -- table stops being comparable across configurations -- and distributed RAM
  -- is the specific primitive rmsnorm.vhd's S_RAW comment records producing
  -- NON-DETERMINISTIC hardware output when inferred UNINITIALIZED in the
  -- congested engine.
  --
  -- This unit does not have that bug: the read is synchronous and pass A
  -- writes every location before pass B reads any of it, so no location is
  -- ever read uninitialized.  Block RAM is chosen anyway, because it makes
  -- that argument structural instead of a property of the FSM that a later
  -- edit could quietly break, and because BRAM is the budget this design has
  -- room in -- DSP is at 90.5-91.9% of 2,880 and this unit uses none.
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
  signal mem_q : std_logic_vector(W_MEM-1 downto 0) := (others => '0');

  -- The reduce FSM no longer owns the fill; they run concurrently.
  type state_t is (S_IDLE, S_AMAX, S_EMIT, S_DONE);
  signal state : state_t := S_IDLE;

  signal wr_idx : integer range 0 to DIM := 0;
  signal wb     : integer range 0 to 1 := 0;   -- bank being filled
  signal rb     : integer range 0 to 1 := 0;   -- bank being reduced
  type pend_t is array (0 to 1) of std_logic;
  signal pending : pend_t := (others => '0');  -- bank holds a full head
  type eh_t is array (0 to 1) of signed(7 downto 0);
  signal e_h_b  : eh_t := (others => (others => '0'));
  signal e_h    : signed(7 downto 0) := (others => '0');
  signal sh_h   : integer range 0 to 63 := 0;
  signal e_head_r : signed(7 downto 0) := (others => '0');

  -- read-side pipeline, shared shape between the two passes
  signal rd_idx  : integer range 0 to DIM := 0;
  signal p1_v, p2_v, p3_v, p4_v : std_logic := '0';
  signal p1_idx, p2_idx, p3_idx, p4_idx : integer range 0 to DIM-1 := 0;
  signal p2_acc  : signed(39 downto 0) := (others => '0');
  signal p2_shj  : integer range 0 to 63 := 0;
  signal p3_al   : signed(39 downto 0) := (others => '0');
  signal p4_abs  : unsigned(39 downto 0) := (others => '0');
  -- Pass C's stage 4 carries a BIASED SIGNED sum, not a magnitude, so it gets
  -- its own register rather than borrowing p4_abs.  Sharing them would work --
  -- the passes are in different states -- and would be a trap for the next
  -- reader, who would reasonably assume anything named _abs is non-negative.
  signal p4_bsum : signed(39 downto 0) := (others => '0');
  signal amax    : unsigned(39 downto 0) := (others => '0');

  signal o_reg   : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal sat_r   : std_logic := '0';
  signal done_r  : std_logic := '0';

  -- Pipeline depth from issuing a read address to the reduce/emit stage.  Both
  -- passes drain for this many cycles after the last address goes out.
  constant DEPTH : integer := 4;
  signal drain : integer range 0 to DEPTH := 0;

begin
  done     <= done_r;
  -- COMBINATIONAL, deliberately.  A registered in_ready reports the state of
  -- `pending` one cycle late, so a producer that samples it and drives on the
  -- next edge can still hit a full bank -- which is exactly what the overlap
  -- test caught, as an assertion failure inside the DUT rather than as a
  -- wrong result.  This is a 2-to-1 mux on one bit and is not a timing risk;
  -- the unit closes at 440.9 MHz against B's 299.04.
  in_ready <= not pending(wb);
  o_mant   <= o_reg;
  o_e_head <= e_head_r;
  o_sat    <= sat_r;

  process(clk)
    variable shj_v  : integer;
    variable al_v   : signed(39 downto 0);
    variable rnd    : signed(39 downto 0);
    variable m16    : signed(15 downto 0);
    variable bias   : signed(39 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; wr_idx <= 0; rd_idx <= 0; drain <= 0;
        wb <= 0; rb <= 0; pending <= (others => '0');
        p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0';
        amax <= (others => '0'); done_r <= '0'; sat_r <= '0';
      else
        done_r <= '0';

        -- ---- synchronous read, one cycle, shared by both read passes ------
        -- Synchronous read, addressed into the bank being REDUCED.  The write
        -- below targets the bank being FILLED, and the two are never the same
        -- bank, which is what makes this a simple dual-port RAM rather than a
        -- read-write conflict.
        if rd_idx < DIM then
          mem_q <= mem(rb*DIM + rd_idx);
        end if;

        -- ================= FILL, concurrent with the reduce ===============
        -- Not a state any more.  It runs every cycle regardless of what the
        -- reduce FSM is doing, which is the whole point of the second bank.
        -- A proper valid/ready transfer: the column moves on an edge where
        -- BOTH in_valid and in_ready are high.  An earlier version accepted on
        -- in_valid alone and asserted if the bank was full, which gets the
        -- protocol backwards -- holding valid while ready is low is exactly
        -- what a stalled producer is supposed to do, so that assert fired on
        -- correct behaviour.
        if in_valid = '1' and pending(wb) = '0' then
          mem(wb*DIM + wr_idx) <= std_logic_vector(in_acc)
                                & std_logic_vector(in_e_o);
          -- e_h is the running MINIMUM over the head, per bank.  Seeded from
          -- column 0 rather than a sentinel, so no exponent is unrepresentable.
          if wr_idx = 0 or in_e_o < e_h_b(wb) then
            e_h_b(wb) <= in_e_o;
          end if;
          if wr_idx = DIM-1 then
            wr_idx     <= 0;
            pending(wb) <= '1';
            wb         <= 1 - wb;
          else
            wr_idx <= wr_idx + 1;
          end if;
        end if;

        case state is

          -- ============ idle: pick up a filled bank ========================
          when S_IDLE =>
            sat_r <= '0';
            if pending(rb) = '1' then
              e_h    <= e_h_b(rb);
              rd_idx <= 0;
              amax   <= (others => '0');
              drain  <= 0;
              p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0';
              state  <= S_AMAX;
            end if;


          -- ============ pass A: capture the column stream ==================
          -- This costs no cycles of its own: gdn_recur_pipe produces one
          -- column result per column and this consumes them at that rate.
          -- ============ pass B: align and reduce amax ======================
          when S_AMAX =>
            -- stage 1: address issued above, data lands in mem_q next cycle
            if rd_idx < DIM then
              p1_v <= '1'; p1_idx <= rd_idx; rd_idx <= rd_idx + 1;
            else
              p1_v <= '0';
            end if;

            -- stage 2: unpack, and the narrow exponent subtract ALONE
            p2_v <= p1_v; p2_idx <= p1_idx;
            if p1_v = '1' then
              p2_acc <= signed(mem_q(47 downto 8));
              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h);
              -- e_h is the minimum so shj_v >= 0 by construction; the clamp is
              -- the project's shift convention and also stops a corrupted
              -- e_o from producing a negative shift, which would be a LEFT
              -- shift and could overflow s40 silently.
              if shj_v < 0 then shj_v := 0; elsif shj_v > 63 then shj_v := 63; end if;
              p2_shj <= shj_v;
            end if;

            -- stage 3: the barrel shift ALONE.  FLOOR, i.e. arithmetic right.
            p3_v <= p2_v; p3_idx <= p2_idx;
            if p2_v = '1' then
              p3_al <= shift_right(p2_acc, p2_shj);
            end if;

            -- stage 4: absolute value ALONE
            p4_v <= p3_v; p4_idx <= p3_idx;
            if p3_v = '1' then
              if p3_al < 0 then p4_abs <= unsigned(-p3_al);
              else              p4_abs <= unsigned(p3_al);
              end if;
            end if;

            -- stage 5: the compare ALONE
            if p4_v = '1' then
              if p4_abs > amax then amax <= p4_abs; end if;
            end if;

            if rd_idx >= DIM then
              if drain = DEPTH then
                -- sh_h and e_head are settled here, once, not per element.
                if msb_pos(amax) - 14 > 0 then
                  sh_h <= msb_pos(amax) - 14;
                  e_head_r <= e_h - to_signed(msb_pos(amax) - 14, 8);
                else
                  sh_h <= 0;
                  e_head_r <= e_h;
                end if;
                rd_idx <= 0; drain <= 0;
                p1_v <= '0'; p2_v <= '0'; p3_v <= '0'; p4_v <= '0';
                state <= S_EMIT;
              else
                drain <= drain + 1;
              end if;
            end if;

          -- ============ pass C: align again, round, saturate, emit =========
          when S_EMIT =>
            if rd_idx < DIM then
              p1_v <= '1'; p1_idx <= rd_idx; rd_idx <= rd_idx + 1;
            else
              p1_v <= '0';
            end if;

            p2_v <= p1_v; p2_idx <= p1_idx;
            if p1_v = '1' then
              p2_acc <= signed(mem_q(47 downto 8));
              shj_v := to_integer(signed(mem_q(7 downto 0)) - e_h);
              if shj_v < 0 then shj_v := 0; elsif shj_v > 63 then shj_v := 63; end if;
              p2_shj <= shj_v;
            end if;

            p3_v <= p2_v; p3_idx <= p2_idx;
            if p2_v = '1' then
              p3_al <= shift_right(p2_acc, p2_shj);   -- same FLOOR alignment
            end if;

            -- stage 4: the rounding bias ALONE.  round_shift(v, s) is
            -- floor_shr(v + 2^(s-1), s), i.e. round-half-toward-plus-infinity,
            -- which is what mv4i_round_shift does and what every other B site
            -- does.  At sh_h = 0 the bias is zero and this is a no-op.
            p4_v <= p3_v; p4_idx <= p3_idx;
            if p3_v = '1' then
              if sh_h = 0 then
                p4_bsum <= p3_al;
              else
                bias := shift_left(to_signed(1, 40), sh_h - 1);
                -- Width check, stated because it is not obvious and because
                -- s40 overflow here would be silent.  |o_al| <= 2^37, so
                -- msb_pos(amax) <= 37 and sh_h <= 23, hence bias <= 2^22.
                -- The sum is at most 2^37 + 2^22 < 2^38 and fits s40.
                --
                -- The bound is INCLUSIVE, and that is derived rather than
                -- transcribed.  The spec's prose gives |o_acc| < 2^37 from
                -- 128 * 2^15 * 23171, where 23171 is q_s's structural maximum
                -- 2^18/sqrt(128) = 23170.5 -- the 1/sqrt(N) fold l2norm_rs
                -- applies on its q path.  That is 2^36.5, so a strict bound
                -- holds with 29% margin FOR THAT UPSTREAM.  But this unit
                -- cannot see its upstream, and an o_acc built from an
                -- unfolded int16 q would reach 128 * 32768 * 32768 = 2^37
                -- EXACTLY, which s40 handles perfectly well.  A strict assert
                -- would then fire on legal input.
                --
                -- That is not hypothetical: the identical off-by-one was
                -- written into rmsnorm_bf's sum-of-squares assert on the same
                -- day, from the same habit of transcribing a bound out of
                -- prose instead of deriving it.  int16's asymmetric range
                -- (-32768 has no positive twin) is where the two diverge.
                -- Written as a shift rather than the literal to_signed
                -- form: 2^37 is not representable in a VHDL integer (32-bit),
                -- so the literal is a static bounds violation.  ghdl reports
                -- it; other tools may accept it and silently wrap.
                assert p3_al <=  shift_left(to_signed(1, 40), 37)
                   and p3_al >= -shift_left(to_signed(1, 40), 37)
                  report "gdn_head_emit: aligned value exceeds the s38 bound "
                       & "the bias width argument depends on"
                  severity failure;
                p4_bsum <= p3_al + bias;
              end if;
            end if;

            -- stage 5: the shift, the saturate and the store
            if p4_v = '1' then
              rnd := shift_right(p4_bsum, sh_h);
              m16 := sat16(rnd);
              if rnd > to_signed(32767, 40) or rnd < to_signed(-32768, 40) then
                sat_r <= '1';
              end if;
              o_reg((p4_idx+1)*16-1 downto p4_idx*16)
                <= std_logic_vector(m16);
            end if;

            if rd_idx >= DIM then
              if drain = DEPTH then
                drain <= 0;
                state <= S_DONE;
              else
                drain <= drain + 1;
              end if;
            end if;

          when S_DONE =>
            done_r <= '1';
            -- Release the bank ONLY here, after the result register is
            -- complete.  Releasing it at the end of pass C would let the fill
            -- overwrite columns the emit pass is still draining.
            pending(rb) <= '0';
            rb <= 1 - rb;
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
