-- rtl/attn_rope.vhd
-- Subsystem C, step 3: the NEOX-paired IMROPE rotation of one head vector.
--
-- WHAT IT COMPUTES.  One head vector of HEAD_DIM int16 mantissas is read from
-- a scratch memory and re-emitted in natural dim order:
--
--   for j in 0 .. NPAIR-1, with the twiddle pair (c, s) for that j:
--     y(j)       : s16 = sat16( round_shift( x(j)*c - x(j+NPAIR)*s, Q ) )
--     y(j+NPAIR) : s16 = sat16( round_shift( x(j)*s + x(j+NPAIR)*c, Q ) )
--   for i in N_ROT .. HEAD_DIM-1:
--     y(i) = x(i)                                          bit-identical
--
-- The block exponent is PRESERVED -- the twiddle >> Q keeps mantissas at the
-- same scale -- so y_exp is x_exp, published before the first output beat.
--
-- Bit-exact against ref/attn_rope_vec.c, whose six oracles share none of this
-- unit's machinery: the rotation against cos/sin at the exact real angle
-- inside a DERIVED bound, NORM PRESERVATION against the orthogonality of a
-- rotation, the unrotated tail as an exact equality, pos = 0 as an exact
-- equality, the rounding mode separated from a floor by an INEQUALITY, and
-- both saturation rails as reachable values.  The reference was
-- mutation-tested before this file existed: **13 of 13 killed, no survivors.**
--
-- ---------------------------------------------------------------------------
-- PAIRING IS (j, j+NPAIR), NOT (2j, 2j+1), AND THEY ARE DIFFERENT ROTATIONS.
-- rtl/rope.vhd was written for stories260K, which is ggml's
-- GGML_ROPE_TYPE_NORMAL and pairs ADJACENT elements.  Qwen3.5/3.8 is
-- GGML_ROPE_TYPE_IMROPE, which dispatches through rotate_pairs(n_dims,
-- n_dims/2, ...) and therefore pairs HALVES.  This file is NOT a wrapper
-- around rope.vhd: that unit indexes a per-position twiddle ROM that the C
-- spec rejects at this geometry, and its NEOX generic still reads the same
-- ROM.  The per-pair ARITHMETIC is the same, deliberately, because the C spec
-- pins it -- but the addressing, the twiddle source, the pass-through region
-- and the interface are all new, so this is a unit and not a rename.
--
-- ONLY THE FIRST N_ROT DIMS ROTATE.  GGUF rope.dimension_count is 64 against a
-- head_dim of 256, so 192 of 256 dims pass through untouched.  Making that the
-- UNIT's responsibility rather than the caller's is what turns it into a
-- testable invariant: the reference's ORACLE 3 is an exact equality over the
-- tail, and an off-by-one at the boundary shows up there and in no other
-- check.
--
-- WHY THE VECTOR IS READ IN THREE PASSES.  The pairing needs x(j) and
-- x(j+NPAIR) in the same cycle, and a single-port memory delivers one element
-- per cycle, so something has to be buffered.  Buffering the FIRST half is the
-- cheapest choice -- NPAIR x MANT_W, 512 bits -- and it makes the output come
-- out in natural dim order with no reordering downstream:
--
--   S_LOAD  read x(0 .. NPAIR-1) into buf, and latch the NPAIR twiddle pairs
--   S_ROT   read x(NPAIR + j), pair it with buf(j), emit y(j), and park
--           y(j+NPAIR) in buf2
--   S_OUT2  emit buf2(0 .. NPAIR-1) as y(NPAIR .. N_ROT-1)
--   S_PASS  read x(N_ROT .. HEAD_DIM-1) and emit it unchanged
--
-- The cost is NPAIR extra cycles of fill against a theoretical HEAD_DIM, which
-- is the "32 pairs + fill" the C spec's own cycle model already carries.
--
-- WHY THE TWIDDLES ARE LATCHED DURING S_LOAD.  S_LOAD is exactly NPAIR cycles
-- of memory reads, and the twiddle stream is exactly NPAIR pairs, so the two
-- fill together and S_ROT then needs no handshake at all.  It also decouples
-- attn_twiddle's pipeline latency from this unit's inner loop entirely: the
-- twiddle can be arbitrarily slow without stalling a multiply.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   start / x_exp / cfg_taken    THE PRODUCER IS STALLABLE -- attn_ctrl issues
--                                one job per head vector and waits for done.
--                                RULE 2: x_exp is read for the whole job, so
--                                it is LATCHED at start and the instant is
--                                made observable by cfg_taken.
--
--   x_raddr / x_re / x_rdata     N/A -- this unit is the MASTER.  A memory
--                                cannot refuse, and x_re is driven so the
--                                memory's output register is frozen exactly
--                                when the pipeline is.  A stall that froze
--                                x_raddr but left the memory ENABLED makes it
--                                overwrite its output register with the item
--                                still in flight; on resume the capture stage
--                                takes the wrong element with the RIGHT index.
--                                attn_kv_quant's M6 is that mutation and it is
--                                an EQUIVALENT MUTANT with no back-pressure.
--
--   tw_valid / tw_cos /          THE PRODUCER IS STALLABLE.  attn_twiddle
--   tw_sin / tw_ready            holds each pair until tw_ready, and this unit
--                                takes exactly NPAIR of them during S_LOAD.
--                                A pair offered outside that window is out of
--                                step rather than merely early, so it raises
--                                `err` instead of being silently ignored.
--
--   hdr_valid / y_exp            Published in S_HDR, which is STRICTLY EARLIER
--                                than any state that can raise y_valid.  From
--                                subsystem B's 2026-08-27 gdn_conv defect: a
--                                scalar that qualifies a stream must be
--                                assigned earlier than the state that first
--                                raises that stream's valid, and a testbench
--                                that samples it at `done` cannot see whether
--                                it was.
--
--   y_valid / y_data / y_index / Producer (this unit) IS stallable and HOLDS.
--   y_ready                      y_ready DEFAULTS TO '1', which is what a
--                                consumer that never stalls presents -- and is
--                                exactly why the hold must be built and
--                                tested, because such a consumer cannot tell a
--                                held valid from a pulsed one.
--
--   done / done_ack              RULE 1: HELD until acked, never pulsed, and
--                                raised only after the LAST element has been
--                                ACCEPTED.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.  The C
-- spec makes the restaging NORMATIVE rather than optional: rope.vhd as built
-- puts the four products and the combine in ONE state and measures 206.4 MHz
-- against a 300 MHz target.
--
--   R1  capture x1, read buf(j) and the latched twiddle -- bus muxes only
--   R2  FOUR MULTIPLIES, in PARALLEL (the rule forbids series, not width)
--   R3  two ADDS, in parallel: the two cross-term combines
--   R4  two ADDS, in parallel: the round bias.  Split from R3 on purpose --
--       a three-input add is two levels, which is what the C spec's
--       "combine/saturate share one state" note is about
--   R5  a constant slice (wiring) and one SATURATE each
--
-- EIGHT DSP48E2 TILES, DERIVED FROM OPERAND WIDTHS AND NOT MEASURED.  No
-- Vivado was run for this file.  Four MANT_W x MANT_W = 16x16 signed products
-- fit one tile each by the 27x18 rule, so the kernel is 4 -- but the C spec's
-- MEASURED 2026-08-25 figure for rope.vhd as built is 8, on the same
-- arithmetic, which says Vivado spends two tiles per product there.  The
-- honest statement is that the DERIVED count is 4 and the MEASURED count for
-- the equivalent kernel is 8, and this file has not been synthesized.  The C
-- DSP skeleton books the rope kernel at 8 and lists "whether it is 4 under a
-- 16x16 rewrite" as its open item 4.
--
-- SATURATION IS A QUALITY EVENT, NOT AN ERROR.  |x0*c - x1*s| / 2^Q can reach
-- |x0| + |x1|, which exceeds the int16 rail whenever both components are large
-- and the angle is near an eighth turn, so it is REACHABLE on legal data.  The
-- C spec 3.4 makes it a sticky `rope_sat` rather than an abort: the clipped
-- mantissa is still described correctly by the preserved exponent, and the C
-- reference saturates identically, so bit-exactness is unaffected.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only indices and the exponent.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;                -- clog2

entity attn_rope is
  generic(
    -- GGUF attention.key_length in both target models.
    HEAD_DIM : positive := 256;
    -- GGUF rope.dimension_count.  Must be even and <= HEAD_DIM.
    N_ROT    : positive := 64;
    MANT_W   : positive := 16;
    -- The twiddle's Q, and therefore the kernel's shift.  15 in both.
    Q        : natural  := 15;
    EXP_W    : positive := 8;
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the job.  RULE 2: x_exp latched, cfg_taken observable. ---------
    start     : in  std_logic;                  -- one-cycle request
    x_exp     : in  signed(EXP_W-1 downto 0);
    cfg_taken : out std_logic;                  -- one cycle, at the latch
    busy      : out std_logic;

    -- ---- the head-vector scratch.  This unit is the MASTER. -------------
    x_raddr : out std_logic_vector(clog2(HEAD_DIM)-1 downto 0);
    x_re    : out std_logic;
    x_rdata : in  std_logic_vector(MANT_W-1 downto 0);

    -- ---- the twiddle stream, NPAIR pairs in j order ---------------------
    tw_valid : in  std_logic;
    tw_cos   : in  signed(MANT_W-1 downto 0);
    tw_sin   : in  signed(MANT_W-1 downto 0);
    tw_ready : out std_logic;

    -- ---- the header, published BEFORE the first output beat -------------
    hdr_valid : out std_logic;
    y_exp     : out signed(EXP_W-1 downto 0);

    -- ---- the rotated stream, in natural dim order.  Held until y_ready. -
    y_valid : out std_logic;
    y_data  : out signed(MANT_W-1 downto 0);
    y_index : out unsigned(clog2(HEAD_DIM)-1 downto 0);
    y_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. ----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared at start.
    --   rope_sat : the int16 saturation fired.  REACHABLE and legal on real
    --              data, so it is a quality event and a golden the testbench
    --              checks, not a flag to hope stays clear.
    --   err      : a twiddle pair was offered outside the load window, i.e.
    --              the producer is out of step with this unit's phases.
    rope_sat : out std_logic;
    err      : out std_logic
  );
end entity;

architecture rtl of attn_rope is

  constant NPAIR : integer := N_ROT / 2;
  constant AW    : integer := clog2(HEAD_DIM);
  constant PRD_W : integer := 2*MANT_W;              -- 32
  -- The cross-term combine of two full products needs one more bit, and the
  -- round bias needs no more; two spare bits make an overflow VISIBLE rather
  -- than wrapping.  Derived from the operands, not copied from MANT_W.
  constant ACC_W : integer := 2*MANT_W + 2;          -- 34

  function smin(w : integer) return signed is
  begin return shift_left(to_signed(-1, w), w-1); end function;

  constant M_MIN : signed(MANT_W-1 downto 0) := smin(MANT_W);
  constant M_MAX : signed(MANT_W-1 downto 0) := not smin(MANT_W);
  constant BIAS  : signed(ACC_W-1 downto 0)
    := shift_left(to_signed(1, ACC_W), Q-1);

  -- The argument is `a` and not `v`: VHDL is case-insensitive and a formal
  -- named `v` would silently hide a signal of that name inside the body.  The
  -- same shadowing cost a run in tb_attn_recip.
  function sat_m(a : signed) return signed is
  begin
    if    a > resize(M_MAX, a'length) then return M_MAX;
    elsif a < resize(M_MIN, a'length) then return M_MIN;
    else  return resize(a, MANT_W);
    end if;
  end function;

  type state_t is (S_IDLE, S_HDR, S_LOAD, S_ROT, S_OUT2, S_PASS, S_DONE);
  signal state : state_t := S_IDLE;

  type buf_t is array (0 to NPAIR-1) of signed(MANT_W-1 downto 0);
  signal buf  : buf_t := (others => (others => '0'));   -- x(0 .. NPAIR-1)
  signal buf2 : buf_t := (others => (others => '0'));   -- y(NPAIR .. N_ROT-1)
  type tw_t is array (0 to NPAIR-1) of signed(MANT_W-1 downto 0);
  signal tw_c, tw_s : tw_t := (others => (others => '0'));

  signal exp_l : signed(EXP_W-1 downto 0) := (others => '0');

  -- issue and capture
  signal ri     : integer range 0 to HEAD_DIM := 0;   -- addresses issued
  signal cv     : std_logic_vector(1 to 2) := (others => '0');
  signal raddr_r : unsigned(AW-1 downto 0) := (others => '0');
  signal ld_wr  : integer range 0 to NPAIR := 0;      -- buf writes
  signal tw_n   : integer range 0 to NPAIR := 0;      -- twiddles latched
  signal rot_rd : integer range 0 to NPAIR := 0;      -- pairs fed
  signal o2_rd  : integer range 0 to NPAIR := 0;      -- buf2 emits
  -- The pass-through OUTPUT index.  NOT derived from ri: ri stops at HEAD_DIM
  -- while the last two reads are still in the memory's pipeline, so `ri - 2`
  -- labels the final two elements identically.  Found by inspection before
  -- the first run; a golden compare would have caught it as two wrong values.
  signal pi_o   : integer range 0 to HEAD_DIM := 0;

  -- the rotate pipeline
  signal rv : std_logic_vector(1 to 4) := (others => '0');
  type j_pipe_t is array (1 to 4) of integer range 0 to NPAIR-1;
  signal r_j : j_pipe_t := (others => 0);
  signal r1_x0, r1_x1, r1_c, r1_s : signed(MANT_W-1 downto 0)
       := (others => '0');
  signal r2_p00, r2_p01, r2_p10, r2_p11 : signed(PRD_W-1 downto 0)
       := (others => '0');
  signal r3_d0, r3_d1 : signed(ACC_W-1 downto 0) := (others => '0');
  signal r4_b0, r4_b1 : signed(ACC_W-1 downto 0) := (others => '0');

  -- outputs
  signal y_v_r   : std_logic := '0';
  signal y_d_r   : signed(MANT_W-1 downto 0) := (others => '0');
  signal y_i_r   : unsigned(AW-1 downto 0) := (others => '0');
  signal hdr_r   : std_logic := '0';
  signal yexp_r  : signed(EXP_W-1 downto 0) := (others => '0');
  signal done_r  : std_logic := '0';
  signal cfg_tk  : std_logic := '0';
  signal sat_r   : std_logic := '0';
  signal err_r   : std_logic := '0';
  signal tw_rdy  : std_logic;

  -- COMBINATIONAL, and deliberately so.  A registered stall reports the
  -- consumer's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.
  signal en : std_logic;

begin

  -- Freeze EVERYTHING -- stages, address counter, read enable and the twiddle
  -- handshake together -- whenever the output stage holds an unaccepted
  -- element.  Freezing fewer than all of them is the silent-corruption case
  -- argued in the header's x_re paragraph.
  en <= '0' when (y_v_r = '1' and y_ready = '0') else '1';

  x_raddr   <= std_logic_vector(raddr_r);
  x_re      <= en when (state = S_LOAD or state = S_ROT or state = S_PASS)
               else '0';
  tw_rdy    <= '1' when (state = S_LOAD and tw_n < NPAIR and en = '1')
               else '0';
  tw_ready  <= tw_rdy;
  cfg_taken <= cfg_tk;
  busy      <= '0' when state = S_IDLE else '1';
  hdr_valid <= hdr_r;
  y_exp     <= yexp_r;
  y_valid   <= y_v_r;
  y_data    <= y_d_r;
  y_index   <= y_i_r;
  done      <= done_r;
  rope_sat  <= sat_r;
  err       <= err_r;

  process(clk)
    variable sh0, sh1 : signed(ACC_W-1 downto 0);
    variable meta : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE;
        ri <= 0; ld_wr <= 0; tw_n <= 0; rot_rd <= 0; o2_rd <= 0; pi_o <= 0;
        cv <= (others => '0');
        rv <= (others => '0');
        y_v_r <= '0'; hdr_r <= '0'; done_r <= '0'; cfg_tk <= '0';
        sat_r <= '0'; err_r <= '0';
        raddr_r <= (others => '0');
      else
        cfg_tk <= '0';

        if STRICT_PRODUCER then
          assert not (start = '1' and state /= S_IDLE)
            report "attn_rope: start while busy -- x_exp is latched for the "
                 & "whole job and this descriptor is being dropped, not queued"
            severity error;
          assert not (y_v_r = '1' and y_ready = '0' and en = '1')
            report "attn_rope: the pipeline advanced while an unaccepted "
                 & "element stood at the output -- that element is lost, not "
                 & "delayed"
            severity error;
          -- THE ORDERING RULE.  The exponent must already stand when the first
          -- element is offered; see the header.
          assert not (y_v_r = '1' and hdr_r = '0')
            report "attn_rope: an element is being offered while hdr_valid is "
                 & "low.  A scalar that qualifies a stream must be assigned "
                 & "STRICTLY EARLIER than the state that first raises that "
                 & "stream's valid"
            severity error;
        end if;

        -- A twiddle offered AFTER the load window has closed is out of step:
        -- this unit takes exactly NPAIR pairs per job and cannot buffer a
        -- thirty-third, so the pair would be silently dropped.  Recorded
        -- rather than ignored.
        --
        -- S_HDR and S_IDLE are deliberately NOT errors.  A producer that
        -- HOLDS its first pair from the moment it has it is behaving exactly
        -- as RULE 1 requires, and it will naturally be offering before this
        -- unit has walked through S_HDR into S_LOAD.  The first version of
        -- this guard excluded only S_IDLE and fired at 95 ns -- in S_HDR, on
        -- correct producer behaviour.  It was invisible in the configuration
        -- with a twiddle gap, because a gap of 3 cycles carries the producer
        -- past S_HDR before it ever asserts; only the DEGENERATE
        -- configuration, where the producer offers immediately and never
        -- stalls, can reach it.  Concrete evidence for the rule that a
        -- degenerate handshake is not a weaker test, just a different one.
        if tw_valid = '1'
           and (state = S_ROT or state = S_OUT2 or state = S_PASS) then
          err_r <= '1';
        end if;

        -- The consumer handshake is independent of the FSM: once an element is
        -- driven it stands until y_ready, whatever the unit does next.
        if y_v_r = '1' and y_ready = '1' then
          y_v_r <= '0';
        end if;

        if en = '1' then
          -- ---- the read pipeline: address, memory, capture --------------
          cv(1) <= '0';
          cv(2) <= cv(1);

          -- ---- the rotate pipeline shift --------------------------------
          rv(1) <= '0';
          for i in 2 to 4 loop
            rv(i)   <= rv(i-1);
            r_j(i)  <= r_j(i-1);
          end loop;

          -- ---- R2: FOUR MULTIPLIES, in PARALLEL -------------------------
          if rv(1) = '1' then
            r2_p00 <= r1_x0 * r1_c;
            r2_p01 <= r1_x1 * r1_s;
            r2_p10 <= r1_x0 * r1_s;
            r2_p11 <= r1_x1 * r1_c;
          end if;

          -- ---- R3: the two cross-term ADDS, in parallel -----------------
          if rv(2) = '1' then
            r3_d0 <= resize(r2_p00, ACC_W) - resize(r2_p01, ACC_W);
            r3_d1 <= resize(r2_p10, ACC_W) + resize(r2_p11, ACC_W);
          end if;

          -- ---- R4: the round-bias ADDS, in parallel ---------------------
          -- Split from R3 deliberately: a three-input add is two levels, and
          -- the C spec's measurement of rope.vhd at 206.4 MHz is exactly the
          -- combine and the bias sharing one state.
          if rv(3) = '1' then
            r4_b0 <= r3_d0 + BIAS;
            r4_b1 <= r3_d1 + BIAS;
          end if;

          -- ---- R5: a constant slice and one SATURATE each ---------------
          -- The asr Q is a CONSTANT slice of a two's-complement value, which
          -- IS the floor the round_shift definition asks for once the bias has
          -- been added.
          if rv(4) = '1' then
            sh0 := shift_right(r4_b0, Q);
            sh1 := shift_right(r4_b1, Q);
            if sh0 /= resize(sat_m(sh0), ACC_W)
               or sh1 /= resize(sat_m(sh1), ACC_W) then
              sat_r <= '1';       -- REACHABLE on legal data; a quality event
            end if;
            -- y(j) leaves now; y(j+NPAIR) waits for S_OUT2.
            y_d_r <= sat_m(sh0);
            y_i_r <= to_unsigned(r_j(4), AW);
            y_v_r <= '1';
            buf2(r_j(4)) <= sat_m(sh1);
          end if;

          case state is

            -- ---- phase 1: fill buf and the twiddle file -----------------
            when S_LOAD =>
              if ri < NPAIR then
                raddr_r <= to_unsigned(ri, AW);
                cv(1)   <= '1';
                ri      <= ri + 1;
              end if;
              if cv(2) = '1' then
                if STRICT_PRODUCER then
                  meta := false;
                  for i in x_rdata'range loop
                    if x_rdata(i) /= '0' and x_rdata(i) /= '1' then
                      meta := true;
                    end if;
                  end loop;
                  -- A metavalue read compares equal to 0 through to_integer
                  -- and would pass a value check silently.  That is the
                  -- gdn_exp_capture trap, where unwritten 'U' taps compared
                  -- equal on both sides and the testbench passed.
                  assert not meta
                    report "attn_rope: x_rdata is not 0/1 -- the head-vector "
                         & "scratch was read before it was written"
                    severity error;
                end if;
                buf(ld_wr) <= signed(x_rdata);
                ld_wr <= ld_wr + 1;
              end if;
              if tw_valid = '1' and tw_rdy = '1' then
                tw_c(tw_n) <= tw_cos;
                tw_s(tw_n) <= tw_sin;
                tw_n <= tw_n + 1;
              end if;
              -- Both fills are exactly NPAIR long and neither paces the other,
              -- so the phase ends when BOTH are complete.  Pacing the memory
              -- off the twiddle handshake would couple this unit's inner loop
              -- to attn_twiddle's pipeline latency for no reason.
              if ld_wr = NPAIR and tw_n = NPAIR then
                ri    <= NPAIR;
                state <= S_ROT;
              end if;

            -- ---- phase 2: rotate, emitting the FIRST half ---------------
            when S_ROT =>
              if ri < N_ROT then
                raddr_r <= to_unsigned(ri, AW);
                cv(1)   <= '1';
                ri      <= ri + 1;
              end if;
              -- R1: capture x1 and read buf and the twiddle -- bus muxes only
              if cv(2) = '1' then
                r1_x1 <= signed(x_rdata);
                r1_x0 <= buf(rot_rd);
                r1_c  <= tw_c(rot_rd);
                r1_s  <= tw_s(rot_rd);
                r_j(1) <= rot_rd;
                rv(1)  <= '1';
                rot_rd <= rot_rd + 1;
              end if;
              -- The phase is finished when the PIPELINE is empty, not when the
              -- last pair was issued.  Moving on with pairs in flight would
              -- interleave S_OUT2's emits with them and reorder the stream.
              if rot_rd = NPAIR and rv = (rv'range => '0') then
                o2_rd <= 0;
                state <= S_OUT2;
              end if;

            -- ---- phase 3: emit the parked SECOND half -------------------
            when S_OUT2 =>
              if o2_rd < NPAIR then
                y_d_r <= buf2(o2_rd);
                y_i_r <= to_unsigned(NPAIR + o2_rd, AW);
                y_v_r <= '1';
                o2_rd <= o2_rd + 1;
              else
                ri    <= N_ROT;
                pi_o  <= N_ROT;
                state <= S_PASS;
              end if;

            -- ---- phase 4: the unrotated tail, bit-identical -------------
            when S_PASS =>
              if ri < HEAD_DIM then
                raddr_r <= to_unsigned(ri, AW);
                cv(1)   <= '1';
                ri      <= ri + 1;
              end if;
              if cv(2) = '1' then
                y_d_r <= signed(x_rdata);
                y_i_r <= to_unsigned(pi_o, AW);
                y_v_r <= '1';
                pi_o  <= pi_o + 1;
              end if;
              if ri = HEAD_DIM and cv = (cv'range => '0') and y_v_r = '0' then
                state <= S_DONE;
              end if;

            when others =>
              null;

          end case;
        end if;

        -- =================================================================
        -- The states that do not touch the datapath.  Outside the `en` gate:
        -- a stalled output must not freeze the completion handshake.
        -- =================================================================
        case state is

          when S_IDLE =>
            if start = '1' then
              exp_l  <= x_exp;        -- RULE 2: latched, never read live
              cfg_tk <= '1';          -- RULE 2: the instant, made observable
              ri <= 0; ld_wr <= 0; tw_n <= 0; rot_rd <= 0; o2_rd <= 0;
              pi_o <= 0;
              cv <= (others => '0');
              rv <= (others => '0');
              sat_r <= '0'; err_r <= '0'; hdr_r <= '0';
              state  <= S_HDR;
            end if;

          -- ---- publish the exponent BEFORE any element can be offered ---
          -- The exponent is PRESERVED, so it is known at start; putting it in
          -- its own state is what makes the ordering rule structural rather
          -- than incidental.
          when S_HDR =>
            yexp_r <= exp_l;
            hdr_r  <= '1';
            state  <= S_LOAD;

          -- ================= RULE 1: held, not pulsed ==================
          when S_DONE =>
            if y_v_r = '0' then
              done_r <= '1';
              if done_ack = '1' then
                -- Do NOT clear done_r here.  The trailing assignment below
                -- clears it once the state leaves S_DONE.  An explicit clear
                -- in this branch is a LATER assignment that wins, which
                -- destroys the pulse outright whenever done_ack is tied high
                -- -- exactly the default a testbench uses.  Caught once in
                -- gdn_head_emit.
                state <= S_IDLE;
              end if;
            end if;

          when others =>
            null;

        end case;

        if state /= S_DONE then
          done_r <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture;
