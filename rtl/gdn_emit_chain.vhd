-- rtl/gdn_emit_chain.vhd
-- Subsystem B: the per-block emit chain, wired and sequenced.
--
-- WHAT THIS IS.  Ten B units are built and unit-verified and NONE of them are
-- connected.  docs/debugging/2026-08-26_gdn-emit-chain-integration.md records
-- why: three of the four seams need glue, and beyond the seams the chain needs
-- a SEQUENCER, because gdn_head_emit and rmsnorm_bf work one head at a time
-- while gdn_y_emit accumulates across all 24 before folding to a single y_exp.
-- This is that sequencer, with the units instantiated inside it.
--
--     gdn_recur_pipe                  (outside: one (o_acc, e_o) per column)
--            |
--     gdn_head_emit    site 12        fold a head to one grid, requantize
--            |  o_mant[DIM] + e_head
--     rmsnorm_bf       output norm    with the model's epsilon
--            |  o_mant[DIM] + o_exp
--            |                        gdn_silu   z gate, exponent PRESERVED
--            |                             |  z_buf[DIM]
--     gdn_y_emit       site 13        gated product, 24-head renorm to y_exp
--            |
--        y stream to ssm_out
--
-- THE THREE SEAMS, and what each needed:
--
--   1. head_emit -> rmsnorm_bf.  Already compatible: both carry the head as a
--      parallel DIM*16 bus.  Needs only a signed-to-integer exponent
--      conversion, which the v1.0-silicon integer ban explicitly excepts for
--      exponents.
--   2. rmsnorm_bf -> y_emit.  A parallel bus into a one-element-per-cycle
--      port.  SERIALIZED here, one element per cycle, honouring y_emit's
--      in_ready.
--   3. gdn_silu -> y_emit.  A SILU_LANES-wide stream into the same
--      one-element port.  Buffered into z_buf and read out one at a time,
--      rather than narrowing the gate: section 3.2 says the nonlinearities
--      dominate the sweep and silu must run near 1 element/cycle, so making
--      it scalar to suit the consumer would give that back.
--
-- The fourth item the integration note called "missing" turned out not to be:
-- y_emit's in_e is o_exp + z_exp, and z_exp is simply gdn_silu's own e_seg
-- input, because silu PRESERVES the exponent (section 2.1.2).  Nothing has to
-- be routed around the gate; the chain already holds it.
--
-- WHY THE COLUMN PATH IS CONCURRENT WITH THE HEAD FSM.  Columns for head h+1
-- arrive from gdn_recur_pipe while head h is still being normed and
-- serialized.  gdn_head_emit is double buffered precisely for this, so the
-- column path here is a straight pass-through with back-pressure and is NOT
-- part of the sequencing FSM.  Making it a state would reintroduce the stall
-- the double buffer exists to remove.
--
-- THE TIMING ARGUMENT, from measured per-unit numbers:
--
--   columns for one head arrive over   512 cycles  (128 columns, one per
--                                                   S_DIM/LANES = 4 cycles)
--   head_emit reduce                   268         (hidden by the next head)
--   rmsnorm_bf                         142
--   gdn_silu at LANES = 32               4 + latency
--   serialize DIM into y_emit          128
--
-- so the serial work after a head's columns land is 142 + 128 = 270 cycles
-- against 512 of arrival.  It fits, and it fits with margin, but note the
-- dependency: head_emit's RESULT register is single (only its column store is
-- double buffered), so head h's o_mant must be consumed before head h+1's
-- reduce completes.  That deadline is 512 + 268 = 780 cycles, against the 270
-- needed.  If gdn_recur_pipe ever gets faster than ~270 cycles per head this
-- becomes a real race and head_emit needs a double-buffered output register
-- too.  It is checked at run time below rather than left as a comment.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity gdn_emit_chain is
  generic(
    HEADS      : positive := 24;   -- VALUE heads per card
    DIM        : positive := 128;  -- head_v_dim
    SILU_LANES : positive := 32;
    RMS_LANES  : positive := 4;
    Q          : integer  := 12;
    EPS        : real     := 1.0e-6;
    -- Set TRUE when the column producer cannot be stalled.  gdn_recur_pipe is
    -- exactly that case: `o_res_valid` free-runs and the unit has no ready
    -- input, so a col_ready that falls under it LOSES a column rather than
    -- delaying one.  Measured 2026-08-27: at DIM/LANES = 4 cycles per column
    -- col_ready never falls, so this is free at LANES = 32; at LANES = 64 it
    -- fires, which is the point.  Simulation only -- an assertion synthesizes
    -- to nothing -- so it costs no area and is worth leaving on.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- per block -------------------------------------------------------
    -- ssm_norm, the per-layer output-norm weight, shared across all heads.
    w_mant : in std_logic_vector(DIM*16-1 downto 0);
    w_exp  : in integer;

    -- ---- column stream from gdn_recur_pipe -------------------------------
    col_valid : in  std_logic;
    col_acc   : in  signed(39 downto 0);
    col_e_o   : in  signed(7 downto 0);
    col_ready : out std_logic;

    -- ---- z gate input, one head at a time --------------------------------
    -- Presented as a parallel bus with its exponent; latched when the head
    -- sequencing picks the head up.  z_exp is carried through unchanged and
    -- becomes half of y_emit's in_e.
    z_mant  : in  std_logic_vector(DIM*16-1 downto 0);
    z_exp   : in  signed(7 downto 0);
    z_valid : in  std_logic;
    z_ready : out std_logic;

    -- ---- block output ----------------------------------------------------
    y_valid : out std_logic;
    y_mant  : out signed(15 downto 0);
    y_last  : out std_logic;
    y_exp   : out signed(7 downto 0);
    done    : out std_logic;
    -- Either emit stage saturating.  Neither is fatal; both mean a head or the
    -- block lost its top end, and no policy exists yet for what to do about it,
    -- so it is surfaced rather than swallowed.
    y_sat   : out std_logic;
    -- Pulses for one cycle at the instant this block's `w_mant` is latched.
    -- The producer may change w any time after it and must have w stable
    -- before it.  Without this the producer has no safe instant at all: see
    -- the note at the top of the architecture.
    w_taken : out std_logic
  );
end entity;

architecture rtl of gdn_emit_chain is

  -- ---- head_emit ---------------------------------------------------------
  signal he_ready  : std_logic;
  signal he_done   : std_logic;
  signal he_mant   : std_logic_vector(DIM*16-1 downto 0);
  signal he_e_head : signed(7 downto 0);
  signal he_sat    : std_logic;
  signal he_ack    : std_logic := '0';

  -- ---- per-block weight latch --------------------------------------------
  -- WHY THIS REGISTER EXISTS.  rmsnorm_bf reads w combinationally, and it is
  -- read once per head for all HEADS heads of a block.  Blocks OVERLAP: the
  -- state machine leaves S_WAITBLK for S_IDLE immediately, so block b+1's head
  -- 0 reaches its norm roughly (DIM + 268) cycles after its columns start,
  -- which is thousands of cycles before block b's `done`.
  --
  -- The read window is in fact safe -- the chain is never in S_RMS for two
  -- blocks at once -- but the safe instant was not OBSERVABLE from outside.
  -- `done` is far too late, and nothing else marked the boundary, so any
  -- producer driving w from a block counter would silently corrupt the next
  -- block's norm. Latching costs DIM*16 = 2048 FF, 0.23% of the device, and
  -- replaces a timing contract with a handshake.
  signal w_held  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal we_held : integer := 0;

  -- ---- rmsnorm_bf --------------------------------------------------------
  signal rn_start : std_logic := '0';
  signal rn_done  : std_logic;
  signal rn_mant  : std_logic_vector(DIM*16-1 downto 0);
  signal rn_exp   : integer;

  -- ---- silu --------------------------------------------------------------
  signal si_valid  : std_logic := '0';
  signal si_data   : std_logic_vector(SILU_LANES*16-1 downto 0) := (others => '0');
  signal si_e_seg  : signed(7 downto 0) := (others => '0');
  signal so_valid  : std_logic;
  signal so_data   : std_logic_vector(SILU_LANES*16-1 downto 0);

  -- ---- y_emit ------------------------------------------------------------
  signal ye_valid  : std_logic := '0';
  signal ye_ready  : std_logic;
  signal ye_hfirst : std_logic := '0';
  signal ye_o      : signed(15 downto 0) := (others => '0');
  signal ye_z      : signed(15 downto 0) := (others => '0');
  signal ye_e      : signed(7 downto 0)  := (others => '0');
  signal ye_sat    : std_logic;

  -- ---- z buffering and the head FSM --------------------------------------
  signal z_buf   : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_held  : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_e_held : signed(7 downto 0) := (others => '0');
  signal z_have  : std_logic := '0';          -- a head's z is latched

  constant SI_BEATS : integer := DIM / SILU_LANES;
  signal si_wr  : integer range 0 to SI_BEATS := 0;   -- feed counter
  signal si_rd  : integer range 0 to SI_BEATS := 0;   -- collect counter

  type state_t is (S_IDLE, S_GATE, S_RMS, S_SER, S_WAITBLK);
  signal state : state_t := S_IDLE;

  signal head  : integer range 0 to HEADS := 0;
  signal ser_j : integer range 0 to DIM := 0;
  signal ep_r  : signed(7 downto 0) := (others => '0');

  -- The deadline argued in the header, CHECKED rather than asserted in prose:
  -- head h's result register must be consumed before head h+1's reduce
  -- overwrites it.  This counts cycles from he_done to the end of
  -- serialization and fails loudly if it ever approaches the 780-cycle budget.
  constant CONSUME_BUDGET : integer := 780;
  signal consume_cyc : integer range 0 to 4095 := 0;
  signal consuming   : std_logic := '0';

begin

  col_ready <= he_ready;

  -- The column back-pressure guard.  Holding valid while ready is low is
  -- perfectly legal for an elastic producer, which is why this is a generic
  -- and not an unconditional assertion: the testbench drives faster than the
  -- real producer on purpose, to find where the cliff is.
  strict_chk : process(clk)
  begin
    if rising_edge(clk) and rst = '0' and STRICT_PRODUCER then
      assert not (col_valid = '1' and col_ready = '0')
        report "gdn_emit_chain: a column was offered and refused while "
             & "STRICT_PRODUCER is set.  The producer cannot stall, so this "
             & "column is LOST, not delayed.  Either widen the arrival period "
             & "or put an elastic buffer in front of the chain."
        severity failure;
    end if;
  end process;
  z_ready   <= '1' when z_have = '0' else '0';
  y_sat     <= he_sat or ye_sat;

  u_head : entity work.gdn_head_emit
    generic map ( DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => col_valid, in_acc => col_acc, in_e_o => col_e_o,
               in_ready => he_ready, o_ack => he_ack,
               done => he_done, o_mant => he_mant, o_e_head => he_e_head,
               o_sat => he_sat );

  u_rms : entity work.rmsnorm_bf
    generic map ( N => DIM, LANES => RMS_LANES, Q => Q, EPS => EPS )
    port map ( clk => clk, rst => rst, start => rn_start,
               -- Seam 1: the only conversion the chain needs.  The integer
               -- ban excepts exponents, so this is legal, not a workaround.
               x_mant => he_mant, x_exp => to_integer(he_e_head),
               w_mant => w_held,  w_exp => we_held,
               done => rn_done, o_mant => rn_mant, o_exp => rn_exp );

  u_silu : entity work.gdn_silu
    generic map ( LANES => SILU_LANES, ARG_Q => Q )
    port map ( clk => clk, rst => rst, e_seg => si_e_seg,
               s_valid => si_valid, s_data => si_data,
               o_valid => so_valid, o_data => so_data );

  u_y : entity work.gdn_y_emit
    generic map ( HEADS => HEADS, DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => ye_valid, in_ready => ye_ready,
               in_hfirst => ye_hfirst,
               in_o => ye_o, in_z => ye_z, in_e => ye_e,
               o_valid => y_valid, o_mant => y_mant, o_last => y_last,
               y_exp => y_exp, done => done, o_sat => ye_sat );

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; head <= 0; ser_j <= 0;
        rn_start <= '0'; si_valid <= '0'; ye_valid <= '0'; ye_hfirst <= '0';
        z_have <= '0'; si_wr <= 0; si_rd <= 0; w_taken <= '0';
        he_ack <= '0';
        consuming <= '0'; consume_cyc <= 0;
      else
        rn_start <= '0';
        he_ack   <= '0';
        w_taken  <= '0';

        -- ---- latch a head's z whenever one is offered and we have none ----
        if z_valid = '1' and z_have = '0' then
          z_held   <= z_mant;
          z_e_held <= z_exp;
          z_have   <= '1';
        end if;

        -- ---- collect silu output into z_buf ------------------------------
        if so_valid = '1' and si_rd < SI_BEATS then
          z_buf((si_rd+1)*SILU_LANES*16-1 downto si_rd*SILU_LANES*16) <= so_data;
          si_rd <= si_rd + 1;
        end if;

        -- ---- the consume-deadline watchdog -------------------------------
        if consuming = '1' then
          consume_cyc <= consume_cyc + 1;
          assert consume_cyc < CONSUME_BUDGET
            report "gdn_emit_chain: head result not consumed within the "
                 & "budget before the next head's reduce can overwrite it; "
                 & "gdn_head_emit needs a double-buffered OUTPUT register"
            severity failure;
        end if;

        case state is

          when S_IDLE =>
            -- head_emit signals a folded head is ready in its result register
            if he_done = '1' then
              consuming <= '1'; consume_cyc <= 0;
              si_wr <= 0; si_rd <= 0;
              -- Head 0 opens the block, so this is the one instant at which w
              -- belongs to the block about to be normalized.  head_emit needed
              -- DIM columns plus its reduce to get here, so the producer has
              -- had that long to present it.
              if head = 0 then
                w_held  <= w_mant;
                we_held <= w_exp;
                w_taken <= '1';
              end if;
              state <= S_GATE;
            end if;

          -- ---- feed z through the gate, SILU_LANES at a time --------------
          when S_GATE =>
            si_e_seg <= z_e_held;
            if si_wr < SI_BEATS then
              si_valid <= '1';
              si_data  <= z_held((si_wr+1)*SILU_LANES*16-1
                                 downto si_wr*SILU_LANES*16);
              si_wr <= si_wr + 1;
            else
              si_valid <= '0';
              -- Start the norm as soon as the gate is fed; they are
              -- independent and the norm is the long pole at 142 cycles
              -- against the gate's SI_BEATS plus latency.
              rn_start <= '1';
              state <= S_RMS;
            end if;

          when S_RMS =>
            if rn_done = '1' and si_rd = SI_BEATS then
              -- Release head_emit's result register HERE and not at pickup:
              -- rmsnorm_bf re-reads x_mant across all three of its passes, so
              -- he_mant has to stand until the norm is finished with it.
              he_ack <= '1';
              ser_j <= 0;
              -- Seam 4: in_e is o_exp + z_exp.  z_exp is the gate's own e_seg,
              -- because silu preserves the exponent.
              ep_r  <= to_signed(rn_exp, 8) + z_e_held;
              state <= S_SER;
            end if;

          -- ---- seam 2 and 3: serialize into y_emit -----------------------
          when S_SER =>
            if ser_j < DIM then
              ye_valid  <= '1';
              if ser_j = 0 then ye_hfirst <= '1'; else ye_hfirst <= '0'; end if;
              ye_o <= signed(rn_mant((ser_j+1)*16-1 downto ser_j*16));
              ye_z <= signed(z_buf((ser_j+1)*16-1 downto ser_j*16));
              ye_e <= ep_r;
              -- A proper valid/ready transfer: advance only on an edge where
              -- y_emit is also ready.
              if ye_ready = '1' then
                ser_j <= ser_j + 1;
              end if;
            else
              ye_valid  <= '0';
              ye_hfirst <= '0';
              consuming <= '0';
              z_have    <= '0';           -- release z for the next head
              if head = HEADS-1 then
                head  <= 0;
                state <= S_WAITBLK;
              else
                head  <= head + 1;
                state <= S_IDLE;
              end if;
            end if;

          -- ---- the block's 24 heads are in; y_emit folds and streams ------
          when S_WAITBLK =>
            -- gdn_y_emit is itself double buffered, so the next block's heads
            -- may begin arriving before this one has finished streaming out.
            -- Returning to S_IDLE immediately is therefore correct, and the
            -- block boundary is visible to the consumer on y_last / done
            -- rather than here.
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture;
