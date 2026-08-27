-- rtl/attn_kv_quant.vhd
-- Subsystem C, step 4: the KV-cache WRITE-side block-floating quantizer.
--
-- WHAT IT COMPUTES.  One head vector of HEAD_DIM int16 mantissas sharing ONE
-- source exponent goes in; the cache record goes out -- HEAD_DIM int8
-- mantissas with one exponent PER KV_BLOCK-element block, plus the write-time
-- `v_ref` minimum fold that the read side later uses to align V.
--
--   amax[b] = max over the KV_BLOCK values of block b of |x[d]|
--   sh[b]   = max(0, msb_pos(amax[b]) - 6)          msb_pos(0) = 0
--   mant[d] = sat8( round_shift(x[d], sh[d / KV_BLOCK]) )
--   e[b]    = src_exp - sh[b]
--   v_ref  <- min(v_ref, min over b of e[b])        V vectors only
--
-- Bit-exact against ref/attn_kv_quant_vec.c, which is itself checked against a
-- double-precision oracle that shares none of its fixed-point machinery.
--
-- WHY THIS UNIT FIRST, out of the twelve subsystem C names.  It is the most
-- self-contained and the most reusable of them: it takes no DSP, it depends on
-- no other C unit, and its output IS the cache record format that the score
-- path, the PV path and the AXI masters all read.  A defect here is not
-- confined to this unit -- it silently rescales everything downstream, and it
-- does so in a way that still passes every structural check, because a wrong
-- exponent is still a legal exponent.  It is also unchanged between the two
-- target models: attention.key_length is 256 and KV_BLOCK is 32 for both
-- Qwen3.5-9B and Qwen3.8-27B (rtl/model_cfg_pkg.vhd), so verifying it once
-- covers the bring-up vehicle and the end goal.
--
-- WHY -6, since that constant is the whole record format.  An int8 mantissa
-- carries 7 magnitude bits, so the target is msb_pos = 6: after the shift the
-- block's peak lands in [64, 127] and the block uses at least six of its seven
-- magnitude bits.  -5 throws away a bit of every block; -7 overflows every
-- block's peak.  Neither is visible to a value check that compares a reference
-- against itself, which is why the C generator's second oracle measures the
-- GRID (peak/LSB must be in [64, 128)) and not only the values.  The constant
-- is derived here as MANT_W - 2 rather than written as 6, so a different
-- mantissa width cannot leave it stale.
--
-- SATURATION IS REACHABLE and is not a contrived corner: amax = 255 gives
-- sh = 1, and round_shift(255, 1) = 128, one past int8.  sat8 is therefore
-- load-bearing, and o_sat reports it rather than swallowing it.
--
-- THE v_ref INIT IS NOT NEUTRAL.  It is +127 because the fold is a MINIMUM and
-- the read side right-shifts every V block by (e[b] - v_ref).  An init of 0
-- leaves v_ref at 0 for any sequence whose exponents are all positive, so
-- every V block is right-shifted by its full exponent and the cache's
-- precision is destroyed -- while every structural check still passes, because
-- the shifts are still right shifts and nothing overflows.  That is why
-- kv_seq_rst has an observable seq_rst_taken and why VREF_INIT is a generic
-- with the value argued rather than a literal buried in a reset branch.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.  Required by the project rule: for every
-- interface, whether the producer can be stalled, and if it cannot, what
-- bounds the consumer's service time.
--
--   x_raddr / x_re / x_rdata      This unit is the MASTER.  A memory cannot
--   (the source head vector)      refuse, and the unit never issues an address
--                                 it is not ready to consume.  No loss is
--                                 possible in this direction.  The hazard here
--                                 is NOT back-pressure, it is the read-enable
--                                 contract below.
--
--   m_valid / m_data / m_ready    Producer (this unit) IS stallable.  The
--   (the mantissa stream)         consumer is the HBM write master, whose W
--                                 channel stalls as a matter of course, so a
--                                 non-stallable producer here would be a loss
--                                 path.  m_ready freezes the WHOLE emit
--                                 pipeline, including the read address and the
--                                 read enable; see the contract below for why
--                                 freezing the address alone is not enough.
--                                 m_ready DEFAULTS TO '1', so a consumer that
--                                 never stalls is unaffected.
--
--   done / done_ack               RULE 1 from the two 2026-08-27 subsystem B
--                                 integration defects: `done` is HELD until
--                                 done_ack, never pulsed.  gdn_head_emit's
--                                 one-cycle done with no handshake lost an
--                                 ENTIRE HEAD whenever the consumer was busy
--                                 at the instant it fired, and then went idle
--                                 with both banks empty looking healthy.
--                                 done_ack DEFAULTS TO '1', which reproduces
--                                 the pulse semantics exactly, so adding it is
--                                 strictly a widening.
--
--   start / is_v / src_exp        RULE 2: latched at the accept instant, and
--   (the job descriptor)          the instant is made observable by cfg_taken.
--                                 The read window is ~590 cycles, far longer
--                                 than one, and a producer that advances
--                                 src_exp mid-vector corrupts exactly the tail
--                                 of the record -- the head-23 shape from
--                                 gdn_emit_chain, where heads 0..22 were
--                                 bit-exact.  "Document the timing contract
--                                 instead of latching" was the fix REJECTED
--                                 there: a safe window that a producer cannot
--                                 SEE is a bug waiting on a schedule change.
--
--   kv_seq_rst / seq_rst_taken    A level from D, not a per-token pulse, with
--                                 the same RULE 2 treatment for the reason in
--                                 the v_ref paragraph above.
--
-- THE READ-ENABLE CONTRACT, which is the one non-obvious thing in this file.
-- x_rdata must hold mem[x_raddr] on the cycle after an edge at which x_re was
-- high, AND must be HELD unchanged across any edge at which x_re was low.
-- That is an ordinary synchronous-read RAM with an enable (bfp_pack's read-
-- ahead port without one, because bfp_pack never stalls).  Freezing x_raddr
-- alone is NOT sufficient and the failure is silent: the address register runs
-- one item AHEAD of the capture stage, so when a stall lands, the memory --
-- if left enabled -- overwrites its output register with the value belonging
-- to the item still in flight, and on resume the capture stage takes the WRONG
-- element with the right index.  Every value is in range, the record length is
-- right, and only the data is wrong.  The testbench drives m_ready low on a
-- generic gap for exactly this reason; with M_GAP = 0 the path is never
-- exercised and the defect is invisible.
--
-- STRUCTURE, and the project's timing rule.  Never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.  A unit
-- that broke that rule held at 117.2 MHz and reached 300.8 only after its
-- states were split, and MREG was NOT the fix.  Here every stage is one
-- operation:
--
--   pass A, per block   issue address | (memory) | capture | abs | max-compare
--   block finalize      msb_pos alone | sh = max(0, p - TARGET) alone
--                       | e and bias, which are independent of each other
--   v_ref fold          one compare per cycle, NBLK cycles, V vectors only
--   pass B, emit        issue address | mux sh and bias | capture
--                       | add bias | barrel shift | saturate and drive
--
-- `bias` is precomputed ONCE PER BLOCK rather than per element, so the emit
-- pipeline never has a shift feeding an add: the round-half bias 2^(sh-1) is a
-- shift, and computing it in the same stage as x + bias would put two of the
-- listed operations in series 256 times per vector instead of 8.
--
-- NO DSP.  Every operation is a shift, a compare, a narrow add or a mux.  This
-- matters: the whole-die DSP budget is the binding resource at 90 percent of
-- 2,880, and the C DSP skeleton books the write-side quantizer at 0 "by
-- construction".  This file is what makes that claim true rather than assumed.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only shifts, indices and
-- exponents, which the project rule exempts.  bfp_pack's header records Vivado
-- DROPPING THE SIGN across an integer round-trip in this very design: GHDL
-- evaluated it correctly, every simulation passed, and only the netlist was
-- wrong.  Elements stay `signed` from x_rdata to m_data.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;              -- clog2

entity attn_kv_quant is
  generic(
    -- GGUF attention.key_length = value_length = 256, identical in Qwen3.5-9B
    -- and Qwen3.8-27B.  Taken from rtl/model_cfg_pkg.vhd (MODEL.attn_head_dim),
    -- not from spec prose: the 128 that circulates with this model is
    -- ssm.state_size, a Gated DeltaNet dimension, and substituting it here
    -- would halve the record and pass every structural check.
    HEAD_DIM  : positive := 256;
    -- C spec 2.1.1, and exactly one 256-bit HBM AXI beat of int8, which is why
    -- DIM_TILE on the read side is forced to the same 32.
    KV_BLOCK  : positive := 32;
    IN_W      : positive := 16;     -- source mantissa width, from rope/rmsnorm
    MANT_W    : positive := 8;      -- cache mantissa width
    EXP_W     : positive := 8;      -- record exponent width
    -- +127, and see the header: this is a maximum because the fold is a
    -- minimum.  Exposed as a generic so a mutation of it is a deliberate act.
    VREF_INIT : integer  := 127;
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- job descriptor.  RULE 2: latched on accept, cfg_taken observable --
    start     : in  std_logic;                  -- one-cycle request
    is_v      : in  std_logic;                  -- '1' = V vector, fold v_ref
    src_exp   : in  signed(EXP_W-1 downto 0);
    cfg_taken : out std_logic;                  -- one cycle, at the latch
    busy      : out std_logic;

    -- ---- per-sequence reset of the v_ref fold.  A LEVEL from D. -----------
    kv_seq_rst    : in  std_logic;
    seq_rst_taken : out std_logic;              -- one cycle, on the rising edge

    -- ---- source vector.  This unit is the master; see the read-enable
    --      contract in the header, which is NOT optional. ------------------
    x_raddr : out std_logic_vector(clog2(HEAD_DIM)-1 downto 0);
    x_re    : out std_logic;
    x_rdata : in  std_logic_vector(IN_W-1 downto 0);

    -- ---- the record.  HEADER FIRST: hdr_valid rises with every block
    --      exponent settled, strictly before m_valid ever does, which is the
    --      order the 272-byte record is laid out in and the order the read
    --      side needs (all 8 exponents before any mantissa). --------------
    hdr_valid : out std_logic;
    e_blk     : out std_logic_vector((HEAD_DIM/KV_BLOCK)*EXP_W-1 downto 0);

    m_valid : out std_logic;
    m_data  : out std_logic_vector(MANT_W-1 downto 0);
    m_index : out std_logic_vector(clog2(HEAD_DIM)-1 downto 0);  -- observability
    m_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. ------------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Any element clipped by sat8.  A quality event, not an error: the value
    -- is clipped but the exponent chain is intact and the C reference clips
    -- identically, so bit-exactness is unaffected.  Reported rather than
    -- swallowed.  Valid from done to the next start.
    o_sat : out std_logic;
    -- Sticky, cleared at start.  Set if src_exp - sh left the exponent field.
    err   : out std_logic;

    -- The write-time fold.  Meaningful from done to the next start, and across
    -- vectors until kv_seq_rst.  Not a port on subsystem C's top level -- C
    -- folds it internally -- but this is a leaf, and a fold nobody can observe
    -- is a fold nobody can test.
    v_ref : out signed(EXP_W-1 downto 0)
  );
end entity;

architecture rtl of attn_kv_quant is

  constant NBLK   : integer := HEAD_DIM / KV_BLOCK;
  constant AW     : integer := clog2(HEAD_DIM);
  -- 7 magnitude bits in an int8, so the peak should land at msb_pos 6.
  -- Derived from MANT_W so a width change cannot leave it stale.
  constant TARGET_MSB : integer := MANT_W - 2;
  -- |x| <= 2^(IN_W-1), so msb_pos(amax) <= IN_W-1 and sh <= IN_W-1-TARGET_MSB.
  constant SH_MAX : integer := IN_W - 1 - TARGET_MSB;
  -- x + bias must not overflow: |x| < 2^(IN_W-1) and bias <= 2^(SH_MAX-1),
  -- and SH_MAX-1 < IN_W-1, so IN_W+1 bits suffice.  IN_W+2 is carried for
  -- margin, which costs two flip-flops per emit stage.
  constant ACC_W  : integer := IN_W + 2;
  -- Issue-to-reduce depth of pass A: issue, memory, capture, abs, compare.
  constant DEPTH_A : integer := 4;

  -- msb position of an unsigned, 0 for zero.  The SAME convention as
  -- mv4i_msb_pos_u, gdn_head_emit and gdn_recur.  msb_pos(0) = 0 is NORMATIVE
  -- and is what makes the all-zero block take sh = max(0, -6) = 0 rather than
  -- a LEFT shift.  It must not "improve".
  function msb_pos_u(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  function sat_mant(v : signed) return signed is
    constant HI : integer :=  2**(MANT_W-1) - 1;
    constant LO : integer := -(2**(MANT_W-1));
  begin
    if    v > to_signed(HI, v'length) then return to_signed(HI, MANT_W);
    elsif v < to_signed(LO, v'length) then return to_signed(LO, MANT_W);
    else  return resize(v, MANT_W);
    end if;
  end function;

  type state_t is (S_IDLE, S_AMAX, S_FIN1, S_FIN2, S_FIN3, S_VFOLD,
                   S_EMIT, S_DONE);
  signal state : state_t := S_IDLE;

  -- latched descriptor
  signal exp_l  : signed(EXP_W-1 downto 0) := (others => '0');
  signal is_v_l : std_logic := '0';

  -- per-block results
  type sh_arr_t   is array (0 to NBLK-1) of unsigned(clog2(SH_MAX+1)-1 downto 0);
  type bias_arr_t is array (0 to NBLK-1) of signed(ACC_W-1 downto 0);
  type e_arr_t    is array (0 to NBLK-1) of signed(EXP_W-1 downto 0);
  signal sh_arr   : sh_arr_t   := (others => (others => '0'));
  signal bias_arr : bias_arr_t := (others => (others => '0'));
  signal e_arr    : e_arr_t    := (others => (others => '0'));

  signal blk    : integer range 0 to NBLK-1 := 0;
  signal rd_idx : integer range 0 to KV_BLOCK := 0;
  signal drain  : integer range 0 to DEPTH_A := 0;

  -- pass A pipeline.  One operation per stage, in the order the header names.
  signal a1_v, a2_v, a3_v, a4_v : std_logic := '0';
  signal a3_x   : signed(IN_W-1 downto 0) := (others => '0');
  -- IN_W+1 bits, not IN_W.  |x| reaches 2^(IN_W-1) = 32768 at the asymmetric
  -- end of int16, which does not fit IN_W bits.  The first version wrote
  --     a4_abs <= unsigned(resize(-ext, IN_W))
  -- and numeric_std's signed resize keeps the SIGN bit and drops the top
  -- magnitude bit, so +32768 resized to 16 bits is ZERO.  A block containing
  -- -32768 then took its amax from the next largest element -- 32767, whose
  -- msb_pos is 14 rather than 15 -- so sh came out ONE TOO SMALL, every
  -- mantissa in that block came out twice too large, and the block's exponent
  -- was one too high.  Nothing overflowed and every value stayed in int8; only
  -- the grid was wrong.  Caught by the testbench's SEPARATE block-exponent
  -- check, which is why that check is separate: the mantissas alone are
  -- self-consistent with the wrong exponent.
  signal a4_abs : unsigned(IN_W downto 0) := (others => '0');
  signal amax   : unsigned(IN_W downto 0) := (others => '0');
  signal p_msb  : integer range 0 to IN_W-1 := 0;
  signal sh_r   : integer range 0 to SH_MAX := 0;

  -- emit pipeline
  signal e_idx  : integer range 0 to HEAD_DIM := 0;
  signal e_blkc : integer range 0 to NBLK-1 := 0;   -- block of the ISSUE stage
  signal e_cnt  : integer range 0 to KV_BLOCK-1 := 0;
  signal m1_v, m2_v, m3_v, m4_v, m5_v : std_logic := '0';
  type idx_pipe_t is array (0 to 4) of integer range 0 to HEAD_DIM-1;
  signal m_idx_p : idx_pipe_t := (others => 0);
  -- The block index of the element in stage 1, carried FORWARD rather than
  -- read live in stage 2.  e_blkc advances on the same edge that issues the
  -- LAST element of a block, so a stage-2 lookup of e_blkc would fetch the
  -- NEXT block's shift for that one element -- 8 wrong elements out of 256,
  -- every element in range, the record the right length.  Exactly the
  -- head-23 shape, and exactly as quiet.
  signal m1_blk : integer range 0 to NBLK-1 := 0;
  signal m2_sh, m3_sh, m4_sh : unsigned(clog2(SH_MAX+1)-1 downto 0)
                             := (others => '0');
  signal m2_bias, m3_bias : signed(ACC_W-1 downto 0) := (others => '0');
  signal m3_x   : signed(IN_W-1 downto 0) := (others => '0');
  signal m4_sum : signed(ACC_W-1 downto 0) := (others => '0');
  signal m5_rnd : signed(ACC_W-1 downto 0) := (others => '0');
  signal emit_done : std_logic := '0';   -- last element has left stage 6

  -- outputs
  signal m_valid_r : std_logic := '0';
  signal m_data_r  : signed(MANT_W-1 downto 0) := (others => '0');
  signal m_index_r : integer range 0 to HEAD_DIM-1 := 0;
  signal done_r    : std_logic := '0';
  signal hdr_r     : std_logic := '0';
  signal sat_r     : std_logic := '0';
  signal err_r     : std_logic := '0';
  signal v_ref_r   : signed(EXP_W-1 downto 0) := to_signed(VREF_INIT, EXP_W);
  signal cfg_tk    : std_logic := '0';
  signal srst_tk   : std_logic := '0';
  signal srst_d    : std_logic := '0';
  signal raddr_r   : unsigned(AW-1 downto 0) := (others => '0');

  -- COMBINATIONAL, and deliberately so.  A registered stall reports the
  -- consumer's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.  This is
  -- one AND gate.
  signal emit_en : std_logic;

begin

  -- Freeze the whole emit pipeline -- stages, address counter AND read enable
  -- together -- whenever the output stage is holding an unaccepted element.
  -- Freezing fewer of those three is the silent-corruption case argued in the
  -- header.
  emit_en <= '0' when (m_valid_r = '1' and m_ready = '0') else '1';

  x_raddr <= std_logic_vector(raddr_r);
  -- The read enable follows the pipeline exactly.  In pass A nothing can
  -- stall, so it is simply the state; in pass B it is the freeze.
  x_re    <= '1' when state = S_AMAX else
             emit_en when state = S_EMIT else
             '0';

  cfg_taken     <= cfg_tk;
  seq_rst_taken <= srst_tk;
  busy          <= '0' when state = S_IDLE else '1';
  hdr_valid     <= hdr_r;
  m_valid       <= m_valid_r;
  m_data        <= std_logic_vector(m_data_r);
  m_index       <= std_logic_vector(to_unsigned(m_index_r, AW));
  done          <= done_r;
  o_sat         <= sat_r;
  err           <= err_r;
  v_ref         <= v_ref_r;

  gen_e : for b in 0 to NBLK-1 generate
    e_blk((b+1)*EXP_W-1 downto b*EXP_W) <= std_logic_vector(e_arr(b));
  end generate;

  process(clk)
    variable ext   : signed(IN_W downto 0);
    variable sh_v  : integer;
    variable e_v   : integer;
    variable meta  : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state   <= S_IDLE;
        blk     <= 0;  rd_idx <= 0;  drain <= 0;
        e_idx   <= 0;  e_blkc <= 0;  e_cnt <= 0;
        a1_v <= '0'; a2_v <= '0'; a3_v <= '0'; a4_v <= '0';
        m1_v <= '0'; m2_v <= '0'; m3_v <= '0'; m4_v <= '0'; m5_v <= '0';
        amax    <= (others => '0');
        m_valid_r <= '0';
        done_r  <= '0'; hdr_r <= '0'; sat_r <= '0'; err_r <= '0';
        cfg_tk  <= '0'; srst_tk <= '0'; srst_d <= '0';
        emit_done <= '0';
        raddr_r <= (others => '0');
        v_ref_r <= to_signed(VREF_INIT, EXP_W);
      else
        cfg_tk  <= '0';
        srst_tk <= '0';

        -- ---- the per-sequence fold reset, independent of the job FSM -----
        -- Applied while the level is HIGH, not only on its edge, so the fold
        -- cannot be left half-reset; the taken pulse marks the rising edge so
        -- the producer has an observable instant (RULE 2).
        srst_d <= kv_seq_rst;
        if kv_seq_rst = '1' then
          v_ref_r <= to_signed(VREF_INIT, EXP_W);
          if srst_d = '0' then
            srst_tk <= '1';
          end if;
        end if;

        if STRICT_PRODUCER then
          assert not (kv_seq_rst = '1' and state /= S_IDLE)
            report "attn_kv_quant: kv_seq_rst asserted mid-vector -- the "
                 & "v_ref fold for this vector is being discarded"
            severity error;
          assert not (start = '1' and state /= S_IDLE)
            report "attn_kv_quant: start while busy -- the descriptor for "
                 & "this vector is being dropped, not queued"
            severity error;
        end if;

        case state is

          -- ================= idle: latch the descriptor ==================
          when S_IDLE =>
            if start = '1' then
              exp_l  <= src_exp;
              is_v_l <= is_v;
              cfg_tk <= '1';          -- RULE 2: the instant, made observable
              sat_r  <= '0';
              err_r  <= '0';
              hdr_r  <= '0';
              blk    <= 0;
              rd_idx <= 0;
              drain  <= 0;
              amax   <= (others => '0');
              a1_v <= '0'; a2_v <= '0'; a3_v <= '0'; a4_v <= '0';
              raddr_r <= (others => '0');
              state  <= S_AMAX;
            end if;

          -- ================= pass A: per-block amax ======================
          -- stage 1 issues, the memory answers on the next edge, stage 3
          -- captures, stage 4 takes the absolute value, stage 5 compares.
          when S_AMAX =>
            -- stage 1: the address ALONE
            if rd_idx < KV_BLOCK then
              raddr_r <= to_unsigned(blk*KV_BLOCK + rd_idx, AW);
              a1_v    <= '1';
              rd_idx  <= rd_idx + 1;
            else
              a1_v <= '0';
            end if;

            -- stage 2: the memory's own registered read.  Nothing here.
            a2_v <= a1_v;

            -- stage 3: capture ALONE
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
                  report "attn_kv_quant: x_rdata is not 0/1 -- the source "
                       & "memory was read before it was written"
                  severity error;
              end if;
              a3_x <= signed(x_rdata);
            end if;

            -- stage 4: the absolute value ALONE.  Widened by one bit BEFORE
            -- the negate and kept wide afterwards: negating -2^(IN_W-1) inside
            -- IN_W bits gives itself back, and narrowing the widened result
            -- back to IN_W bits throws the magnitude away instead (see the
            -- declaration of a4_abs).  There is no resize here for that
            -- reason.
            a4_v <= a3_v;
            if a3_v = '1' then
              ext := resize(a3_x, IN_W+1);
              if ext < 0 then
                a4_abs <= unsigned(-ext);
              else
                a4_abs <= unsigned(ext);
              end if;
            end if;

            -- stage 5: the compare ALONE
            if a4_v = '1' then
              if a4_abs > amax then
                amax <= a4_abs;
              end if;
            end if;

            if rd_idx >= KV_BLOCK then
              if drain = DEPTH_A then
                drain <= 0;
                state <= S_FIN1;
              else
                drain <= drain + 1;
              end if;
            end if;

          -- ---- block finalize, three states so no two operations chain ---
          -- stage 1: the priority encode ALONE
          when S_FIN1 =>
            p_msb <= msb_pos_u(amax);
            state <= S_FIN2;

          -- stage 2: the clamped subtract ALONE
          when S_FIN2 =>
            sh_v := p_msb - TARGET_MSB;
            if sh_v < 0 then
              sh_v := 0;
            elsif sh_v > SH_MAX then
              sh_v := SH_MAX;     -- unreachable given IN_W, kept as the
            end if;               -- project's shift-clamp convention
            sh_r  <= sh_v;
            state <= S_FIN3;

          -- stage 3: the exponent and the round bias, which are INDEPENDENT
          -- of each other, so they are one operation each and not two in
          -- series.  Precomputing bias per block is what keeps the emit
          -- pipeline free of a shift feeding an add.
          when S_FIN3 =>
            sh_arr(blk) <= to_unsigned(sh_r, sh_arr(0)'length);
            if sh_r = 0 then
              bias_arr(blk) <= (others => '0');   -- round_shift(v,0) = v
            else
              bias_arr(blk) <= shift_left(to_signed(1, ACC_W), sh_r - 1);
            end if;

            e_v := to_integer(exp_l) - sh_r;
            if e_v > 2**(EXP_W-1) - 1 or e_v < -(2**(EXP_W-1)) then
              -- src_exp is EXP_W bits and sh is up to SH_MAX, so the sum can
              -- leave the field: at EXP_W = 8 the worst case is -128 - 9.
              -- Sticky rather than fatal, so a job that trips it still
              -- terminates and D sees the flag instead of a hang.
              err_r <= '1';
            end if;
            e_arr(blk) <= resize(exp_l, EXP_W) - to_signed(sh_r, EXP_W);

            amax   <= (others => '0');
            rd_idx <= 0;
            if blk = NBLK-1 then
              blk   <= 0;
              state <= S_VFOLD;
            else
              blk   <= blk + 1;
              state <= S_AMAX;
            end if;

          -- ================= the v_ref min fold =========================
          -- One compare per cycle, NBLK cycles.  A separate pass rather than
          -- folding inside S_FIN3, because e is COMPUTED there and folding it
          -- in the same state would put a subtract and a wide compare in
          -- series.  NBLK cycles against ~590 is not worth the risk.
          when S_VFOLD =>
            if is_v_l = '1' and e_arr(blk) < v_ref_r then
              v_ref_r <= e_arr(blk);
            end if;
            if blk = NBLK-1 then
              blk       <= 0;
              hdr_r     <= '1';   -- HEADER FIRST: every exponent is settled
              e_idx     <= 0;
              e_blkc    <= 0;
              e_cnt     <= 0;
              emit_done <= '0';
              m1_v <= '0'; m2_v <= '0'; m3_v <= '0'; m4_v <= '0'; m5_v <= '0';
              m1_blk    <= 0;
              raddr_r   <= (others => '0');
              state     <= S_EMIT;
            else
              blk <= blk + 1;
            end if;

          -- ================= pass B: requantize and stream ===============
          when S_EMIT =>
            if emit_en = '1' then
              -- stage 1: the address ALONE, plus the block counter that
              -- avoids a divide by KV_BLOCK in the mux stage below.
              if e_idx < HEAD_DIM then
                raddr_r    <= to_unsigned(e_idx, AW);
                m1_v       <= '1';
                m_idx_p(0) <= e_idx;
                m1_blk     <= e_blkc;
                e_idx      <= e_idx + 1;
                if e_cnt = KV_BLOCK-1 then
                  e_cnt <= 0;
                  if e_blkc < NBLK-1 then
                    e_blkc <= e_blkc + 1;
                  end if;
                else
                  e_cnt <= e_cnt + 1;
                end if;
              else
                m1_v <= '0';
              end if;

              -- stage 2: the NBLK-way bus mux ALONE.  Both lookups take the
              -- same index, so they are parallel, not in series.
              m2_v <= m1_v;
              m_idx_p(1) <= m_idx_p(0);
              if m1_v = '1' then
                m2_sh   <= sh_arr(m1_blk);
                m2_bias <= bias_arr(m1_blk);
              end if;

              -- stage 3: capture ALONE
              m3_v <= m2_v;
              m_idx_p(2) <= m_idx_p(1);
              if m2_v = '1' then
                m3_x    <= signed(x_rdata);
                m3_sh   <= m2_sh;
                m3_bias <= m2_bias;
              end if;

              -- stage 4: the round bias ADD alone.  round_shift(v, s) is
              -- floor_shr(v + 2^(s-1), s), i.e. round half toward plus
              -- infinity, which is mv4i_round_shift and every other site in
              -- this design.  At sh = 0 the bias is zero and this is a no-op,
              -- which is what makes round_shift(v, 0) = v exactly.
              m4_v <= m3_v;
              m_idx_p(3) <= m_idx_p(2);
              if m3_v = '1' then
                m4_sum <= resize(m3_x, ACC_W) + m3_bias;
                m4_sh  <= m3_sh;
              end if;

              -- stage 5: the barrel shift ALONE.  Arithmetic right, so it is
              -- the floor half of round_shift.
              m5_v <= m4_v;
              m_idx_p(4) <= m_idx_p(3);
              if m4_v = '1' then
                m5_rnd <= shift_right(m4_sum, to_integer(m4_sh));
              end if;

              -- stage 6: saturate ALONE, and drive.
              m_valid_r <= m5_v;
              if m5_v = '1' then
                if m5_rnd > to_signed(2**(MANT_W-1) - 1, ACC_W)
                or m5_rnd < to_signed(-(2**(MANT_W-1)), ACC_W) then
                  sat_r <= '1';
                end if;
                m_data_r  <= sat_mant(m5_rnd);
                m_index_r <= m_idx_p(4);
                if m_idx_p(4) = HEAD_DIM-1 then
                  emit_done <= '1';
                end if;
              end if;
            end if;

            -- The vector is finished when the last element has been ACCEPTED,
            -- not when it has been produced.  Testing emit_done alone would
            -- drop the final element under back-pressure, which is the same
            -- class of defect as a pulsed done and just as quiet.
            if emit_done = '1' and (m_valid_r = '0'
                                    or (m_valid_r = '1' and m_ready = '1')) then
              m_valid_r <= '0';
              state     <= S_DONE;
            end if;

          -- ================= completion.  RULE 1: held, not pulsed. ======
          when S_DONE =>
            done_r <= '1';
            if done_ack = '1' then
              -- Do NOT clear done_r here.  The default assignment at the top
              -- of the process clears it on the first cycle the state is no
              -- longer S_DONE.  An explicit clear in this branch is a LATER
              -- assignment to the same signal and wins, which destroys the
              -- pulse outright whenever done_ack is tied high -- that is,
              -- exactly the default configuration a testbench uses.  This bug
              -- was written and caught once already, in gdn_head_emit.
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
