-- rtl/attn_mac_array.vhd
-- Subsystem C's MAC ARRAY: the replicated element, and the one piece of C that
-- had no RTL at all.
--
-- WHY THIS EXISTS.  Subsystem C shipped eight leaf units, each with a passing
-- testbench, and every one of them sits on the read path DOWNSTREAM of a
-- multiply that did not exist.  attn_score_q12 consumes per-block partial dot
-- products; attn_softmax consumes the scores those become; attn_gate consumes
-- the PV accumulators.  Nothing produced any of the three.  The completeness
-- audit's phrase for it was "C has no multiply array", and rtl/attn_lane_skel
-- is a DSP pricing harness that computes an XOR digest, not a lane.
--
-- This file is attn_lane + attn_score_tree + attn_acc from the C skeleton's
-- section 2 table, as ONE unit.  They are one unit here and three names there
-- because the accumulator file cannot be separated from the lane that writes
-- it: C spec 2.6 measures the read mux going non-linear above 16 entries per
-- lane precisely because the file is INSIDE the lane, and a decomposition that
-- put a port between them would be pricing a structure nobody builds.
--
-- ============================ WHAT IT COMPUTES ============================
--
-- LANES = QH_TILE x DIM_TILE multipliers, sharing three operand modes.  Every
-- mode uses every lane, which is why the array is one shape and not three:
--
--   score    partial[qh][b] = sum over t in [0,DIM_TILE) of
--                             q[qh][b*DIM_TILE+t] * k[b*DIM_TILE+t]
--            q s16 x k s8, ONE BLOCK PER CYCLE, reduced by QH_TILE fabric
--            adder trees of DIM_TILE terms each.
--
--   PV       o[qh][b*DIM_TILE+t] += e[qh] * v[b*DIM_TILE+t]
--            e u13 x v s8, one block per cycle, all QH_TILE heads at once.
--            `v` is ALREADY v_aligned -- the site-3 right shift by
--            (e_v[b] - v_ref) happens in the block, before this unit -- so the
--            operand is s8 and not s16.  That boundary is worth a sentence
--            because it is the difference between a PV operand that fits one
--            DSP48E2 tile and one that does not.
--
--   rescale  o[qh][d] = round_shift(o[qh][d] * f[qh], Q)      C spec site 5d
--            acc s36 x f u13, one accumulator INDEX per cycle across all
--            QH_TILE heads, so a full pass is ACC_N cycles.  Heads whose
--            maximum did not rise ride the same pass with f = 2^Q, which
--            site 5d makes an EXACT identity -- so the pass is uniform and
--            needs no per-head masking.  That identity is checked as an
--            equality by the reference's oracle 5, not asserted.
--
-- ONE BLOCK PER CYCLE IS THE CACHE'S STRUCTURE, NOT A TUNING KNOB.  The KV
-- record carries one exponent per KV_BLOCK = 32 elements (C spec 2.1.1) and
-- attn_score_q12 aligns the partials by those exponents BEFORE summing them.
-- An array that reduced all HEAD_DIM products into one number would make that
-- alignment impossible and would silently add eight different power-of-two
-- grids together.  So DIM_TILE = KV_BLOCK, and a MAC cycle spans exactly one
-- exponent block.
--
-- WHY THE RESCALE MODE IS ON THE LANE.  The accumulator is s36 and 36 > 27, so
-- the rescale operand does not fit one DSP48E2 tile while score (16x8) and PV
-- (13x8) each fit with room to spare.  That single fact makes the lane 2 DSP
-- rather than 1 and is 89% of C's whole DSP budget (C skeleton 3.2, 3.6).  It
-- is modelled here rather than assumed away, and the reference's oracle 6
-- checks the port fit arithmetically so a width change cannot invalidate the
-- budget silently.
--
-- ========================= STRUCTURE AND TIMING =========================
--
-- The project's timing rule: never two of {barrel shift, wide add, wide
-- compare, bus mux, multiply} in series within one stage.  The unit that broke
-- it held at 117.2 MHz and reached 300.8 after its states were split.
--
--   S0   operand mux, REGISTERED.  These are the DSP48E2's AREG/BREG.
--   S1   the multiply, alone in its stage.
--   S2   score: the adder tree and the partial register
--        PV / rescale: the accumulator read-modify-write, ONE shared adder
--        per lane (see below)
--
-- REGISTERING THE OPERAND MUXES IS NORMATIVE, NOT AN OPTIMISATION.  C spec 2.6
-- MEASURED 2026-08-24, place-and-routed at 64 lanes: combinational operand
-- muxes gave 246 MHz, registered ones gave 340 MHz at the SAME 128 DSP and 5%
-- FEWER LUT, because the registers exist inside the tile whether they are used
-- or not.  Cost is one cycle of latency, which the two-position PV lag of the
-- spec's schedule already absorbs.
--
-- ONE SHARED ADDER PER LANE, and this is measured rather than stylistic.  C
-- spec 2.6 MEASURED 2026-08-23: the obvious form
--     for i in 0 to ACC_N-1 loop
--       if idx = i then acc(i) <= acc(i) + prod; end if;
--     end loop;
-- builds an ACC_W-bit adder PER ENTRY -- 1110 LUT and 80 CARRY8 per lane
-- against 318 and 5 for identical arithmetic, i.e. 792 wasted LUT per lane and
-- 35-52% of the device at 192-288 lanes.  Vivado will not share them because
-- proving the enables one-hot is not something synthesis attempts.  The write
-- below is therefore a single indexed read, a single add and a single indexed
-- write, which is what infers one adder plus a read mux and a write demux.
--
-- ============ BACK-PRESSURE, STATED PER PORT (the project rule) ============
--
--   sc_valid / pv_valid / rs_valid   THE PRODUCER IS THE BLOCK'S SCHEDULE and
--                                    it is not stallable mid-slot: the array
--                                    runs on a fixed position slot driven by
--                                    the KV beat rate.  There is deliberately
--                                    no ready on any of the three.  What
--                                    bounds the service time is that every
--                                    mode is a FIXED three-stage pipeline with
--                                    no feedback into its own input, so the
--                                    array accepts one operation per cycle
--                                    unconditionally, forever.
--
--   p_valid / p_data / p_ready       THE CONSUMER (attn_score_q12) CANNOT
--                                    STALL THIS UNIT.  A partial it does not
--                                    take is a LOST partial, not a delayed
--                                    one -- gdn_recur_pipe's free-running
--                                    o_res_valid exactly.  attn_score_q12's
--                                    own contract is that p_ready never falls
--                                    while partials are in flight, and the
--                                    only thing that can check that is an
--                                    assertion here.  `p_ready` therefore
--                                    exists ONLY for STRICT_PRODUCER, defaults
--                                    to '1', and the datapath never reads it.
--
--   rd_valid / o_valid               Registered read, one cycle.  The block is
--                                    master; a memory cannot refuse.
--
-- THE ORDERING RULE.  `p_blk` qualifies the partial stream and is assigned in
-- the same pipeline stage that raises `p_valid`, from the same register set --
-- not from a live counter that has already moved on.  That is the shape of
-- gdn_conv's tvalid defect and of gdn_block's cv_seg defect, and the cheap way
-- to be safe is to carry the qualifier down the pipeline with its data instead
-- of recomputing it at the far end.
--
-- BIT-EXACTNESS.  Against ref/attn_mac_array_vec.c, which is checked against
-- six oracles sharing none of its integer machinery (double precision,
-- __int128 in reverse order, the width bound attn_score_q12 depends on, a full
-- independent replay using FLOOR DIVISION rather than an arithmetic shift, the
-- f = 2^Q identity, and the DSP48E2 port fit).  The reference was
-- mutation-tested before this file was written: 8 of 8 killed.  Two of those
-- eight only became killable after a fix to the reference, and both are worth
-- recording here because they are traps in the reference and not in the RTL:
-- an oracle that read a LOCAL temporary instead of the published partial array
-- let "sum the partials across blocks" survive, and the three plausible
-- rounding modes agree on everything except exact ties, so a random-data
-- vector set cannot tell them apart at all.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use work.util_pkg.all;

entity attn_mac_array is
  generic(
    -- Query heads per tile.  The GQA group: 6 at 27B (24 q / 4 kv, N = 2),
    -- 4 at 9B (16 q / 4 kv).  C spec 3.0 requires QH_TILE to divide the group
    -- or the last sub-tile idles.
    QH_TILE  : positive := 6;
    -- Elements per beat.  FORCED to KV_BLOCK by the record's per-32 exponent
    -- structure; see the header.
    DIM_TILE : positive := 32;
    -- Accumulators per lane = HEAD_DIM / DIM_TILE.  C spec 2.6 MEASURED the
    -- read mux linear to 16 and broken above it, so this must stay <= 16.
    ACC_N    : positive := 8;
    Q_W      : positive := 16;    -- normed/roped q mantissa
    K_W      : positive := 8;     -- KV cache mantissa, and v_aligned
    E_W      : positive := 13;    -- e_p and f, u13 (0 .. 2^Q)
    ACC_W    : positive := 36;    -- C spec 2.6: bound 2^30, 4 bits of margin
    P_W      : positive := 32;    -- the partial, attn_score_q12's s32
    Q        : natural  := 12;    -- site 5d's round_shift amount
    -- Simulation-only, gdn_emit_chain's convention.  Asserts the contracts a
    -- value check cannot see.  Synthesizes to nothing.
    STRICT_PRODUCER : boolean := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- accumulator clear.  One cycle, the whole file. ------------------
    -- C spec 3.1 offers the alternative of initialising by OVERWRITE on the
    -- first processed position (the `ns_first` pattern, no clear pass).  A
    -- clear is used here instead because it makes the sweep's first position
    -- structurally identical to every other one, and a file of registers can
    -- be cleared synchronously in one cycle.  The overwrite form saves one
    -- cycle per sweep and adds a mode; that is the wrong trade for a first
    -- assembly, and it is stated so the choice is visible.
    acc_clr : in std_logic;

    -- ---- score mode: one exponent block, all QH_TILE heads ---------------
    sc_valid : in  std_logic;
    sc_blk   : in  unsigned(clog2(ACC_N)-1 downto 0);
    sc_k     : in  std_logic_vector(DIM_TILE*K_W-1 downto 0);
    sc_q     : in  std_logic_vector(QH_TILE*DIM_TILE*Q_W-1 downto 0);

    -- ---- the partial stream out.  See the back-pressure note. ------------
    p_valid : out std_logic;
    p_blk   : out unsigned(clog2(ACC_N)-1 downto 0);
    p_data  : out std_logic_vector(QH_TILE*P_W-1 downto 0);
    p_ready : in  std_logic := '1';        -- STRICT_PRODUCER only

    -- ---- PV mode: one block, all heads, e per head ----------------------
    pv_valid : in std_logic;
    pv_blk   : in unsigned(clog2(ACC_N)-1 downto 0);
    pv_v     : in std_logic_vector(DIM_TILE*K_W-1 downto 0);   -- v_aligned
    pv_e     : in std_logic_vector(QH_TILE*E_W-1 downto 0);

    -- ---- rescale mode: one accumulator index, all heads ------------------
    rs_valid : in std_logic;
    rs_blk   : in unsigned(clog2(ACC_N)-1 downto 0);
    rs_f     : in std_logic_vector(QH_TILE*E_W-1 downto 0);

    -- ---- accumulator readback, one element per cycle ---------------------
    rd_valid : in  std_logic;
    rd_head  : in  unsigned(clog2(QH_TILE)-1 downto 0);
    rd_idx   : in  unsigned(clog2(ACC_N*DIM_TILE)-1 downto 0);
    o_valid  : out std_logic;
    o_data   : out signed(ACC_W-1 downto 0);

    -- Sticky, cleared by acc_clr.
    --   ovr : an accumulator saturated at ACC_W.  UNREACHABLE under C spec
    --         2.1.4's derived bound |o| <= 2^30 with ACC_W = 36; a width
    --         guard, and the reference reports the same event so a vector set
    --         that reaches it is a vector set the bound does not cover.
    --   err : a score partial left the P_W field, i.e. the |partial| < 2^27
    --         premise attn_score_q12's own s32 width argument rests on was
    --         violated.  That premise is the reference's oracle 3.
    ovr : out std_logic;
    err : out std_logic
  );
end entity;

architecture rtl of attn_mac_array is

  constant LANES : integer := QH_TILE*DIM_TILE;
  constant NACC  : integer := QH_TILE*ACC_N*DIM_TILE;
  -- The A operand is sized by the WIDEST mode, which is rescale at ACC_W.
  -- That is the whole reason the lane is 2 DSP.
  constant A_W   : integer := ACC_W;
  -- The B operand carries the u13 modes as a signed value, so E_W+1.
  constant B_W   : integer := E_W + 1;
  constant PR_W  : integer := A_W + B_W;
  -- The tree sum needs room for DIM_TILE products before it is checked
  -- against P_W.  Wide on purpose: a sum that overflows here would hide the
  -- very overflow `err` exists to report.
  constant T_W   : integer := PR_W + clog2(DIM_TILE) + 1;

  type mode_t is (M_NONE, M_SCORE, M_PV, M_RS);

  type a_arr is array (0 to LANES-1) of signed(A_W-1 downto 0);
  type b_arr is array (0 to LANES-1) of signed(B_W-1 downto 0);
  type p_arr is array (0 to LANES-1) of signed(PR_W-1 downto 0);
  type acc_arr is array (0 to NACC-1) of signed(ACC_W-1 downto 0);

  signal a_reg : a_arr := (others => (others => '0'));
  signal b_reg : b_arr := (others => (others => '0'));
  signal p_reg : p_arr := (others => (others => '0'));
  signal acc   : acc_arr := (others => (others => '0'));

  signal mode1, mode2 : mode_t := M_NONE;
  signal blk1, blk2   : integer range 0 to ACC_N-1 := 0;

  signal pv_r  : std_logic := '0';
  signal pd_r  : std_logic_vector(QH_TILE*P_W-1 downto 0) := (others => '0');
  signal pb_r  : integer range 0 to ACC_N-1 := 0;

  signal ov_r  : std_logic := '0';
  signal er_r  : std_logic := '0';

  signal ov_r2 : std_logic := '0';
  signal od_r  : signed(ACC_W-1 downto 0) := (others => '0');

  -- A PROCEDURE and not a function, because a VHDL function's parameters are
  -- all mode `in` and the saturation event has to come back out.  Returning a
  -- record would work and would cost a type nobody else needs.
  constant ACC_HI : signed(ACC_W-1 downto 0)
    := not shift_left(to_signed(-1, ACC_W), ACC_W-1);
  constant ACC_LO : signed(ACC_W-1 downto 0)
    := shift_left(to_signed(-1, ACC_W), ACC_W-1);

  procedure sat_acc(a : in signed; r : out signed; ovf : out boolean) is
  begin
    if    a > resize(ACC_HI, a'length) then ovf := true;  r := ACC_HI;
    elsif a < resize(ACC_LO, a'length) then ovf := true;  r := ACC_LO;
    else  ovf := false; r := resize(a, ACC_W);
    end if;
  end procedure;

begin

  -- Elaboration-time shape checks.  Each of these, violated, produces silently
  -- wrong numbers rather than an error, which is why they are here and not in
  -- a comment.
  assert ACC_N <= 16
    report "attn_mac_array: ACC_N above 16.  C spec 2.6 MEASURED the "
         & "accumulator read mux going non-linear there (32 entries measures "
         & "543 LUT against a linear prediction of 478; the F7/F8 chain is "
         & "exhausted and a third fabric level appears).  The array still "
         & "computes correctly; it no longer costs what the budget says."
    severity warning;
  assert ACC_W > 27
    report "attn_mac_array: ACC_W has fallen to 27 or less, so the rescale "
         & "operand now FITS one DSP48E2 tile.  C's entire DSP budget assumes "
         & "it does not.  Re-price the lane before trusting any figure in the "
         & "C spec's section 3."
    severity warning;
  assert P_W >= 32
    report "attn_mac_array: P_W below the s32 attn_score_q12 declares"
    severity failure;
  -- clog2(1) is 0, and a zero-width port index is legal VHDL that silently
  -- addresses nothing.  Both of these are >= 2 in every configuration on C
  -- spec 3.0's legal ladder except QH_TILE = 1 (MACS = 32), which is listed
  -- there and chosen nowhere.
  assert QH_TILE >= 2
    report "attn_mac_array: QH_TILE = 1 gives a zero-width rd_head" severity failure;
  assert ACC_N >= 2
    report "attn_mac_array: ACC_N = 1 gives a zero-width block index" severity failure;

  p_valid <= pv_r;
  p_data  <= pd_r;
  p_blk   <= to_unsigned(pb_r, clog2(ACC_N));
  o_valid <= ov_r2;
  o_data  <= od_r;
  ovr     <= ov_r;
  err     <= er_r;

  process(clk)
    variable av   : a_arr;
    variable bv   : b_arr;
    variable md   : mode_t;
    variable t    : signed(T_W-1 downto 0);
    variable idx  : integer;
    variable acv  : signed(ACC_W-1 downto 0);
    variable sum  : signed(ACC_W downto 0);
    variable ovf  : boolean;
    variable rsh  : signed(PR_W-1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        mode1 <= M_NONE; mode2 <= M_NONE;
        blk1 <= 0; blk2 <= 0; pb_r <= 0;
        pv_r <= '0'; ov_r <= '0'; er_r <= '0'; ov_r2 <= '0';
        acc  <= (others => (others => '0'));
      else

        if STRICT_PRODUCER then
          -- At most one mode per cycle.  Two modes in one cycle is not a
          -- stall, it is two operations sharing one multiplier and one of
          -- them is simply gone.
          assert not ((sc_valid = '1' and pv_valid = '1')
                   or (sc_valid = '1' and rs_valid = '1')
                   or (pv_valid = '1' and rs_valid = '1'))
            report "attn_mac_array: two operand modes offered in one cycle.  "
                 & "The lane has ONE multiplier; one of these operations is "
                 & "being dropped, not queued."
            severity error;
          -- The consumer contract attn_score_q12 states and cannot enforce.
          assert not (pv_r = '1' and p_ready = '0')
            report "attn_mac_array: a partial was offered while p_ready was "
                 & "low.  This stream has no ready in the datapath, so that "
                 & "partial is LOST, not delayed -- the gdn_recur_pipe shape."
            severity error;
          -- A read that overlaps an in-flight write TO THE SAME BLOCK INDEX
          -- returns the value from before that write.  Both of the file's
          -- readers are checked, and both checks are INDEX-AWARE rather than
          -- coarse: a rescale pass issues one index per cycle back to back, so
          -- a coarse "any write in flight" test would fire on correct
          -- behaviour and be turned off, which is how a guard stops guarding.
          assert not (rd_valid = '1'
                      and (((mode1 = M_PV or mode1 = M_RS)
                            and blk1 = to_integer(rd_idx)/DIM_TILE)
                        or ((mode2 = M_PV or mode2 = M_RS)
                            and blk2 = to_integer(rd_idx)/DIM_TILE)))
            report "attn_mac_array: accumulator readback issued while a PV or "
                 & "rescale write to the SAME block is still in the pipeline.  "
                 & "The value read is the one BEFORE that write."
            severity error;
          -- The rescale mode reads the accumulator in S0 and writes it in S2,
          -- so it is the one mode whose own input depends on the file.  A
          -- rescale of block b issued while block b's previous write is still
          -- in flight rescales the STALE value and then overwrites the write.
          assert not (rs_valid = '1'
                      and (((mode1 = M_PV or mode1 = M_RS)
                            and blk1 = to_integer(rs_blk))
                        or ((mode2 = M_PV or mode2 = M_RS)
                            and blk2 = to_integer(rs_blk))))
            report "attn_mac_array: rescale of a block whose previous write is "
                 & "still in the pipeline.  It multiplies the STALE "
                 & "accumulator and then overwrites the pending write."
            severity error;
        end if;

        -- ---------------- S0: the operand mux, REGISTERED ----------------
        md := M_NONE;
        av := (others => (others => '0'));
        bv := (others => (others => '0'));

        if sc_valid = '1' then
          md := M_SCORE;
          for h in 0 to QH_TILE-1 loop
            for t2 in 0 to DIM_TILE-1 loop
              av(h*DIM_TILE + t2) := resize(signed(
                 sc_q((h*DIM_TILE + t2 + 1)*Q_W-1 downto
                      (h*DIM_TILE + t2)*Q_W)), A_W);
              bv(h*DIM_TILE + t2) := resize(signed(
                 sc_k((t2+1)*K_W-1 downto t2*K_W)), B_W);
            end loop;
          end loop;
          blk1 <= to_integer(sc_blk);
        elsif pv_valid = '1' then
          md := M_PV;
          for h in 0 to QH_TILE-1 loop
            for t2 in 0 to DIM_TILE-1 loop
              -- e is UNSIGNED and carried in a signed of E_W+1 bits.  Reading
              -- it as signed(E_W-1 downto 0) turns e = 4096 into -4096, which
              -- is mutation M4 of the reference and is killed there.
              av(h*DIM_TILE + t2) := resize(signed('0' &
                 unsigned(pv_e((h+1)*E_W-1 downto h*E_W))), A_W);
              bv(h*DIM_TILE + t2) := resize(signed(
                 pv_v((t2+1)*K_W-1 downto t2*K_W)), B_W);
            end loop;
          end loop;
          blk1 <= to_integer(pv_blk);
        elsif rs_valid = '1' then
          md := M_RS;
          for h in 0 to QH_TILE-1 loop
            for t2 in 0 to DIM_TILE-1 loop
              idx := (h*ACC_N + to_integer(rs_blk))*DIM_TILE + t2;
              av(h*DIM_TILE + t2) := resize(acc(idx), A_W);
              bv(h*DIM_TILE + t2) := resize(signed('0' &
                 unsigned(rs_f((h+1)*E_W-1 downto h*E_W))), B_W);
            end loop;
          end loop;
          blk1 <= to_integer(rs_blk);
        end if;

        a_reg <= av;
        b_reg <= bv;
        mode1 <= md;

        -- ---------------- S1: the multiply, alone in its stage ------------
        for l in 0 to LANES-1 loop
          p_reg(l) <= a_reg(l) * b_reg(l);
        end loop;
        mode2 <= mode1;
        blk2  <= blk1;

        -- ---------------- S2: tree / accumulate ---------------------------
        pv_r  <= '0';
        ov_r2 <= '0';

        case mode2 is
          when M_SCORE =>
            for h in 0 to QH_TILE-1 loop
              t := (others => '0');
              for t2 in 0 to DIM_TILE-1 loop
                t := t + resize(p_reg(h*DIM_TILE + t2), T_W);
              end loop;
              if t > resize(not shift_left(to_signed(-1, P_W), P_W-1), T_W)
                 or t < resize(shift_left(to_signed(-1, P_W), P_W-1), T_W) then
                er_r <= '1';
              end if;
              pd_r((h+1)*P_W-1 downto h*P_W)
                <= std_logic_vector(resize(t, P_W));
            end loop;
            pv_r <= '1';
            pb_r <= blk2;

          when M_PV =>
            -- ONE shared adder per lane; see the header's MEASURED note.
            for h in 0 to QH_TILE-1 loop
              for t2 in 0 to DIM_TILE-1 loop
                idx := (h*ACC_N + blk2)*DIM_TILE + t2;
                sum := resize(acc(idx), ACC_W+1)
                     + resize(p_reg(h*DIM_TILE + t2), ACC_W+1);
                sat_acc(sum, acv, ovf);
                if ovf then ov_r <= '1'; end if;
                acc(idx) <= acv;
              end loop;
            end loop;

          when M_RS =>
            -- Site 5d: round half toward +infinity by Q, then saturate.  The
            -- bias is added in this stage and the shift is the same stage's
            -- wiring, which is one add and one constant shift, not two levels
            -- of arithmetic.
            for h in 0 to QH_TILE-1 loop
              for t2 in 0 to DIM_TILE-1 loop
                idx := (h*ACC_N + blk2)*DIM_TILE + t2;
                rsh := shift_right(p_reg(h*DIM_TILE + t2)
                                   + shift_left(to_signed(1, PR_W), Q-1), Q);
                sat_acc(rsh, acv, ovf);
                if ovf then ov_r <= '1'; end if;
                acc(idx) <= acv;
              end loop;
            end loop;

          when others => null;
        end case;

        -- ---------------- readback, one cycle -----------------------------
        if rd_valid = '1' then
          od_r  <= acc(to_integer(rd_head)*ACC_N*DIM_TILE
                       + to_integer(rd_idx));
          ov_r2 <= '1';
        end if;

        -- The clear wins over everything in the same cycle, which is why it
        -- is last: a clear concurrent with a write must leave the file clear,
        -- not hold the write.  The block issues it before a sweep, when
        -- nothing is in flight, and STRICT_PRODUCER says so.
        if acc_clr = '1' then
          acc  <= (others => (others => '0'));
          ov_r <= '0';
          er_r <= '0';
          if STRICT_PRODUCER then
            assert mode1 = M_NONE and mode2 = M_NONE
              report "attn_mac_array: acc_clr while an operation is in the "
                   & "pipeline.  That operation's write-back is discarded."
              severity error;
          end if;
        end if;

      end if;
    end if;
  end process;

end architecture;
