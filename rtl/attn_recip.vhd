-- rtl/attn_recip.vhd
-- Subsystem C, step 8a: turn the online softmax's denominator into a
-- multiplicative reciprocal, one query head at a time on ONE shared divider.
--
-- WHAT IT COMPUTES.  A stream of denominators goes in, one per query head; the
-- pair (p, r) comes out for each:
--
--   p = msb_pos(s)                      msb_pos(0) = 0, NORMATIVE
--   r = floor( 2^(p + R_Q) / s )        R_Q = 15
--
-- and the consumer (site 6b, attn_gate) then computes
--
--   t[d] = round_shift( o[d] * r, p + 1 )
--
-- which is o/s expressed in Q(R_Q - 1) = Q14.
--
-- Bit-exact against ref/attn_recip_vec.c, which is itself checked against four
-- oracles that share none of its integer machinery, the first of which NEVER
-- PERFORMS A DIVISION: r = floor(N/s) if and only if r*s <= N < (r+1)*s, and
-- both products are exact in 64 bits.  Checking a division by dividing again
-- would be the restatement trap, not a check.  The reference was
-- mutation-tested before this file existed: 6 of 7 killed, the survivor shown
-- unreachable by the range oracle.
--
-- WHY IT PAIRS WITH attn_softmax.  `s` is exactly that unit's `s_out`, and the
-- two together are the whole of the read path's scalar chain: attn_softmax
-- accumulates the denominator across the position sweep and this unit converts
-- it, once per head, into the form the output stage can multiply by.  It is
-- also the last unit before the gate, so it closes steps 4, 5b, 6, 7 and 8a as
-- a contiguous verified run.
--
-- WHY p, AND WHY THE PAIR TRAVELS TOGETHER.  2^p <= s < 2^(p+1) by the
-- definition of msb_pos, so 2^(p+R_Q)/s lies in (2^(R_Q-1), 2^R_Q] and r lies
-- in [2^(R_Q-1), 2^R_Q] -- a 16-bit unsigned whose top value 2^15 is reached
-- exactly when s is a power of two.  That is the entire reason for normalising
-- by p instead of dividing by a fixed power: it pins the reciprocal to a KNOWN
-- 15-bit window whatever s is, so the downstream multiply is 24 x 16 and fits
-- one DSP48E2 tile, and it bounds the relative error at 2^-14 uniformly.  A p
-- one too small overflows r past 16 bits; a p one too large halves the
-- precision.  NEITHER shows up as a wrong value anywhere, because the pair is
-- self-consistent either way -- which is why the reference checks the RANGE as
-- an exact inequality and not only the values.
--
-- WHY A DIVIDER AND NOT A RECIPROCAL LUT.  rtl/divider_rs.vhd exists because
-- Vivado's `/` produced WRONG quotients on silicon in this design while every
-- operand was bit-perfect; see that file's header for the measured numbers.  A
-- LUT-plus-Newton reciprocal would be an approximation whose error would have
-- to be re-derived; the restoring divider is exact, costs 0 DSP, and runs
-- 12 x 16 = 192 times per token per card at NW cycles each -- under 9,000
-- cycles of a 1.3-million-cycle subsystem.  There is no throughput case for
-- anything cleverer, and this is the C spec's own choice.
--
-- s = 0 IS UNREACHABLE, AND IS TRAPPED ANYWAY.  attn_softmax snaps its running
-- maximum UP to the grid, so the largest score's own z lies in
-- [-(2^GRID_SH - 1), 0] and its weight is at least
-- round(exp(-255/4096) * 4096) = 3849.  So s >= 3849 for any head with at
-- least one position, and p >= 11.  divider_rs's own header says a zero
-- divisor gives unspecified-but-bounded garbage with no lockup -- which is
-- exactly the kind of silent legal-looking value this project has been bitten
-- by twice -- so a zero s skips the divide entirely, emits r = 0, and raises
-- `err`.
--
-- ---------------------------------------------------------------------------
-- BACK-PRESSURE, STATED PER PORT.
--
--   s_valid / s_in / s_ready      THE PRODUCER IS STALLABLE.  attn_softmax's
--   (the denominator stream)      `s_out` is valid from its `done` until its
--                                 next `start`, so refusing a denominator
--                                 delays the next head and does not lose this
--                                 one.  s_ready is low for the whole divide,
--                                 which is NW + 7 cycles, and that is a long
--                                 stall by this design's standards -- it is
--                                 affordable only because it happens 12 times
--                                 per layer and not 12 times per position.
--
--   s_in / s_last / s_taken       RULE 2 from the two 2026-08-27 subsystem B
--   (the job descriptor)          integration defects: the denominator is read
--                                 for NW + 7 cycles, far longer than one, so
--                                 it is LATCHED at the accept instant and the
--                                 instant is made observable by s_taken.  A
--                                 producer that advances s_in mid-divide would
--                                 corrupt exactly the head being divided and
--                                 nothing else -- the gdn_emit_chain head-23
--                                 shape, where heads 0 through 22 were
--                                 bit-exact.  "Document the timing contract
--                                 instead of latching" was the fix REJECTED
--                                 there: a safe window a producer cannot SEE
--                                 is a bug waiting on a schedule change.
--                                 divider_rs latches its own operands too, but
--                                 only from the cycle `start` is high; the
--                                 seven cycles before that are this unit's
--                                 responsibility.
--
--   r_valid / p_out / r_out /     Producer (this unit) IS stallable and HOLDS.
--   r_ready                       The consumer is attn_gate, which sweeps 256
--                                 elements per head, so it takes the pair once
--                                 and is then busy for 256 cycles; a pair it
--                                 does not take must WAIT, not vanish.
--                                 r_ready DEFAULTS TO '1'.
--
--   done / done_ack               RULE 1: `done` is HELD until acked, never
--                                 pulsed, and it is raised only after the LAST
--                                 head's pair has been ACCEPTED.  Raising it at
--                                 production instead would drop the last pair
--                                 under back-pressure, which is the same class
--                                 of defect as a pulsed done and just as quiet.
--
-- STRUCTURE, and the project's timing rule: never two of {barrel shift, wide
-- add, wide compare, bus mux, multiply} in series within one stage.
--
--   S_MSB   the priority encode ALONE, in parallel with the zero test, which
--           shares its operand and so is not in series with it
--   S_SH    the narrow add p + R_Q ALONE
--   S_NUM   the shift 1 << sh ALONE.  Splitting the add out of this state is
--           the whole reason there are three states here and not one: an add
--           feeding a barrel shift is exactly the pair that held rmsnorm_rs at
--           117.2 MHz, and MREG was not the fix there either
--   S_SAT   one compare and one select
--
-- NO DSP.  A priority encoder, a narrow add, a decoder, a compare and a select,
-- plus divider_rs, which was MEASURED at 0 DSP on 2026-08-25.  The C DSP
-- skeleton books the reciprocal at 0; this file is what makes that true rather
-- than assumed.
--
-- NO VHDL INTEGER CARRIES A DATAPATH VALUE.  Only shifts, indices and the
-- exponent p, which the project rule exempts.  bfp_pack's header records
-- Vivado DROPPING THE SIGN across an integer round-trip in this very design:
-- GHDL evaluated it correctly, every simulation passed, and only the netlist
-- was wrong.  Everything here is `unsigned` end to end.
--
-- AND ONE THING THAT IS DELIBERATELY NOT A resize.  The numerator is built by
-- shifting a 1 into an NW-bit register, never by resizing a narrower value:
-- `resize` on a `signed` keeps the sign bit and drops the top magnitude bit,
-- which has now cost this subsystem two defects one unit apart
-- (docs/debugging/2026-08-27_attn-kv-quant-abs-resize.md and
-- 2026-08-27_attn-softmax-offset-resize.md).  Every resize below widens.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;              -- clog2

entity attn_recip is
  generic(
    -- attn_softmax's s_out width.
    S_W  : positive := 26;
    -- The reciprocal.  16 because r lands in [2^(R_Q-1), 2^R_Q] and 2^15
    -- itself is reachable; see the header.
    R_W  : positive := 16;
    R_Q  : natural  := 15;
    -- divider_rs geometry.  DERIVED, not copied: the numerator is
    -- 2^(p + R_Q) with p <= S_W-1, so it needs S_W + R_Q = 41 bits, and NW is
    -- 44 for margin, which is also what C spec step 8 declares.  DW must hold
    -- the divisor, so DW >= S_W.
    NW   : positive := 44;
    DW   : positive := 28;
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the denominator stream.  RULE 2: latched, s_taken observable. ---
    s_valid : in  std_logic;
    s_in    : in  unsigned(S_W-1 downto 0);
    s_last  : in  std_logic;                 -- final head of this layer
    s_ready : out std_logic;
    s_taken : out std_logic;                 -- one cycle, at the latch
    busy    : out std_logic;

    -- ---- the pair.  Held until r_ready. ---------------------------------
    r_valid : out std_logic;
    p_out   : out unsigned(clog2(S_W)-1 downto 0);
    r_out   : out unsigned(R_W-1 downto 0);
    r_ready : in  std_logic := '1';

    -- ---- completion.  RULE 1: held until acked, never pulsed. -----------
    done     : out std_logic;
    done_ack : in  std_logic := '1';

    -- Sticky, cleared when a head is accepted after a completed layer.
    --   err : s was 0, so no reciprocal exists.  Unreachable given
    --         attn_softmax's grid snap; see the header.
    --   ovr : the quotient left the R_W field.  Unreachable given the range
    --         argument; a width guard, and the reference's oracle 2 is what
    --         proves it cannot fire.
    err : out std_logic;
    ovr : out std_logic
  );
end entity;

architecture rtl of attn_recip is

  constant PW : integer := clog2(S_W);        -- p in 0 .. S_W-1

  -- msb position of an unsigned, 0 for zero.  The SAME convention as
  -- mv4i_msb_pos_u, attn_kv_quant, gdn_head_emit and gdn_recur.
  -- msb_pos(0) = 0 is NORMATIVE and it is why s = 0 must be trapped BEFORE the
  -- divide rather than relied on to produce something sensible.
  function msb_pos_u(a : unsigned) return integer is
    variable p : integer := 0;
  begin
    for i in a'low to a'high loop
      if a(i) = '1' then p := i; end if;
    end loop;
    return p;
  end function;

  type state_t is (S_IDLE, S_MSB, S_SH, S_NUM, S_DIV, S_WAIT, S_SAT, S_ZERO,
                   S_OUT, S_DONE);
  signal state : state_t := S_IDLE;

  signal s_l    : unsigned(S_W-1 downto 0) := (others => '0');
  signal last_l : std_logic := '0';
  signal p_r    : unsigned(PW-1 downto 0) := (others => '0');
  -- p + R_Q, so it needs to hold S_W-1+R_Q = 40.  Derived from the operands
  -- rather than from NW, because NW carries deliberate margin and a width
  -- taken from it would be right by accident.
  signal sh_r   : unsigned(clog2(S_W + R_Q)-1 downto 0) := (others => '0');
  signal num_r  : unsigned(NW-1 downto 0) := (others => '0');
  signal quo_r  : unsigned(NW-1 downto 0) := (others => '0');
  signal r_r    : unsigned(R_W-1 downto 0) := (others => '0');

  signal div_st   : std_logic := '0';
  signal div_busy : std_logic;
  signal div_done : std_logic;
  signal div_quo  : std_logic_vector(NW-1 downto 0);
  signal div_den  : std_logic_vector(DW-1 downto 0);

  signal r_v_r   : std_logic := '0';
  signal done_r  : std_logic := '0';
  signal s_tk    : std_logic := '0';
  signal err_r   : std_logic := '0';
  signal ovr_r   : std_logic := '0';

begin

  -- COMBINATIONAL, and deliberately so.  A registered ready reports this
  -- unit's state one cycle late, which is precisely the shape that let
  -- gdn_head_emit's producer drive into a bank that was already full.
  s_ready <= '1' when state = S_IDLE else '0';
  s_taken <= s_tk;
  busy    <= '0' when state = S_IDLE else '1';
  r_valid <= r_v_r;
  p_out   <= p_r;
  r_out   <= r_r;
  done    <= done_r;
  err     <= err_r;
  ovr     <= ovr_r;

  div_den <= std_logic_vector(resize(s_l, DW));

  -- The exact divider.  See the header: `/` is not usable in this design.
  u_div : entity work.divider_rs
    generic map ( NW => NW, DW => DW )
    port map ( clk => clk, rst => rst, start => div_st,
               num => std_logic_vector(num_r), den => div_den,
               busy => div_busy, done => div_done, quo => div_quo );

  process(clk)
    variable qv : unsigned(NW-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state  <= S_IDLE;
        div_st <= '0';
        r_v_r  <= '0';
        done_r <= '0';
        s_tk   <= '0';
        err_r  <= '0';
        ovr_r  <= '0';
        last_l <= '0';
      else
        s_tk <= '0';

        if STRICT_PRODUCER then
          -- attn_softmax cannot produce s = 0 for a head with at least one
          -- position: the maximum's own weight is at least 3849.  If this
          -- fires, either the softmax contract is broken or this unit is being
          -- driven by something that is not it.
          assert not (s_valid = '1' and state = S_IDLE and s_in = 0)
            report "attn_recip: s = 0 offered.  attn_softmax's grid snap makes "
                 & "the largest score's own weight at least 3849, so a zero "
                 & "denominator means the producer is not that unit"
            severity error;
          -- The pair must never be withdrawn once offered.
          assert not (r_v_r = '1' and r_ready = '0' and state /= S_OUT)
            report "attn_recip: r_valid is high outside S_OUT -- the pair is "
                 & "not being held for its consumer"
            severity error;
        end if;

        case state is

          -- ================= idle: latch the descriptor ==================
          when S_IDLE =>
            div_st <= '0';
            if s_valid = '1' then
              s_l    <= s_in;       -- RULE 2: latched, never read live
              last_l <= s_last;
              s_tk   <= '1';        -- RULE 2: the instant, made observable
              err_r  <= '0';
              ovr_r  <= '0';
              state  <= S_MSB;
            end if;

          -- ---- the priority encode ALONE, in parallel with the zero test -
          -- Both read s_l and neither reads the other, so they are one level
          -- and not two.
          when S_MSB =>
            p_r <= to_unsigned(msb_pos_u(s_l), PW);
            if s_l = 0 then
              -- msb_pos(0) = 0 would ask the divider for 2^15 / 0.  Trapped
              -- here rather than relied on; see the header.
              err_r <= '1';
              state <= S_ZERO;
            else
              state <= S_SH;
            end if;

          -- ---- the narrow add ALONE -------------------------------------
          -- Split out of S_NUM on purpose: an add feeding a barrel shift is
          -- exactly the pair that held rmsnorm_rs at 117.2 MHz, and MREG was
          -- not the fix there either.
          when S_SH =>
            sh_r  <= resize(p_r, sh_r'length) + to_unsigned(R_Q, sh_r'length);
            state <= S_NUM;

          -- ---- the shift ALONE.  1 << sh is a decoder, not a shifter, but
          -- it is counted as the listed operation for this stage regardless.
          when S_NUM =>
            num_r  <= shift_left(to_unsigned(1, NW), to_integer(sh_r));
            div_st <= '1';
            state  <= S_DIV;

          -- ---- one cycle with start high; divider_rs latches both operands
          -- on this edge and never looks at the ports again.
          when S_DIV =>
            div_st <= '0';
            state  <= S_WAIT;

          when S_WAIT =>
            if div_done = '1' then
              quo_r <= unsigned(div_quo);
              state <= S_SAT;
            end if;

          -- ---- one compare and one select -------------------------------
          when S_SAT =>
            qv := quo_r;
            if qv > to_unsigned(2**R_W - 1, NW) then
              r_r   <= (others => '1');
              ovr_r <= '1';     -- unreachable; the reference's oracle 2 proves
            else                -- r <= 2^R_Q < 2^R_W.  A width guard.
              r_r <= resize(qv, R_W);
            end if;
            r_v_r <= '1';
            state <= S_OUT;

          when S_ZERO =>
            r_r   <= (others => '0');
            r_v_r <= '1';
            state <= S_OUT;

          -- ---- hold the pair until the consumer takes it ----------------
          when S_OUT =>
            if r_ready = '1' then
              r_v_r <= '0';
              if last_l = '1' then
                state <= S_DONE;
              else
                state <= S_IDLE;
              end if;
            end if;

          -- ================= RULE 1: held, not pulsed ====================
          -- Reached only after the last pair has been ACCEPTED, not when it
          -- was produced.  Signalling completion at production would drop the
          -- final pair under back-pressure.
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
