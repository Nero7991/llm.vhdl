-- rtl/gdn_job_seq.vhd -- run ONE GDN layer for one token.
--
-- load the layer's state from HBM, run `gdn_block`, refill the conv tap
-- history from this token's qkv column, save the state back.  That order is
-- not a preference:
--
--   * the taps must hold the PREVIOUS KCONV-1 columns while `gdn_block` runs,
--     because its conv reads them; so the refill comes AFTER the run.
--   * the refill must land before the save, or the column written this token
--     is not in the image the next token loads.
--   * `tok_adv` is NOT pulsed here.  It belongs to whoever knows where a TOKEN
--     ends, and this module is one LAYER.  Pulsing it per layer would advance
--     the rotation LAYERS times per token and every layer but the last would
--     read its taps in the wrong order -- a wrong number, not a hang.
--
-- WHY THE REFILL IS A SEPARATE PASS AND NOT PIGGYBACKED ON THE CONV READ.
-- `gdn_conv_tap_mem` is a SIMPLE dual port: one read address, one write
-- address.  Writing group g while `gdn_block` reads group g is a same-address
-- collision, and on a Xilinx BRAM that is UNDEFINED unless a write mode is
-- set.  A separate pass costs `qkv_dim/CONV_LANES` cycles -- 2,048 at the 9B
-- shape against `gdn_block`'s ~16,384-cycle state sweep, about 12% -- and it
-- removes the question rather than guarding it.  The pass is PIPELINED, one
-- group per cycle with the write trailing the read by one, so it costs that
-- and not twice it.
--
-- THREE TRAPS THIS FILE IS BUILT AROUND, all of them already paid for
-- elsewhere in this project:
--
--   1. `busy` DOES NOT RISE ON THE START EDGE.  Waiting for it to fall without
--      first seeing it rise completes INSTANTLY.  `llama_top`'s own S_ARM
--      exists for this and `tb_gdn_state_axi` lost an afternoon to it
--      (docs/debugging/2026-09-02_gdn-state-dma.md, defect B1).  So the run
--      phase arms on the RISE.
--   2. `done` IS A ONE-CYCLE PULSE with no acknowledge.  It is waited on, not
--      polled as a level.
--   3. A COMPLETION SIGNAL THAT ALSO FIRES ON FAILURE IS NOT A COMPLETION
--      SIGNAL.  `ss_err` is sticky in the store and is captured here rather
--      than being allowed to look like success; `err` is held until the next
--      `start`.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_job_seq is
  generic(
    VAL_HEADS  : positive := 32;
    DIM        : positive := 128;
    KEY_HEADS  : positive := 16;
    KCONV      : positive := 4;
    CONV_LANES : positive := 4;
    LAYERS     : positive := 24
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- the job ---------------------------------------------------------
    -- ONE-CYCLE pulse.  `busy` covers the whole job and rises the cycle AFTER
    -- `start`; `done` is a one-cycle pulse at the end.  Same contract as
    -- `gdn_state_store` and `gdn_state_axi`, deliberately, so a caller that
    -- drives one correctly drives all of them.
    start : in  std_logic;
    layer : in  integer range 0 to LAYERS-1;
    busy  : out std_logic;
    done  : out std_logic;
    err   : out std_logic;

    -- ---- rtl/gdn_state_store.vhd ------------------------------------------
    ss_load_start : out std_logic;
    ss_save_start : out std_logic;
    ss_layer      : out integer range 0 to LAYERS-1;
    ss_done       : in  std_logic;
    ss_err        : in  std_logic;

    -- the store's conv tap WRITE port
    cvw_en   : out std_logic;
    cvw_seg  : out integer range 0 to 2;
    cvw_grp  : out natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
    cvw_data : out std_logic_vector(CONV_LANES*16-1 downto 0);

    -- ---- rtl/gdn_block.vhd ------------------------------------------------
    b_start : out std_logic;
    b_busy  : in  std_logic;

    -- ---- this token's qkv column, a TWO-EDGE registered read --------------
    -- Addressed the way `gdn_block` addresses its conv taps, so the caller
    -- wires one shape and not two.
    --
    -- THE CONTRACT IS TWO EDGES, NOT ONE, and the distinction is the whole
    -- reason the refill walk has the depth it has.  This module REGISTERS
    -- `q_seg`/`q_grp`, so the source does not see an address until the cycle
    -- after the walk issues it; a registered source then presents `q_data` a
    -- cycle after THAT.  Counting from the edge that issues group g, its data
    -- is sampled two edges later.  This is deliberately the same contract
    -- `gdn_state_axi` reads its memories under (docs/debugging/
    -- 2026-09-02_gdn-state-dma.md, defect D2), so a caller that satisfies one
    -- satisfies both.
    --
    -- Getting this wrong costs a WRONG NUMBER AND NOTHING ELSE: the walk still
    -- visits every group exactly once and in order, each write just carries
    -- its neighbour's data.  MEASURED while building this file -- a one-stage
    -- version failed 31 of 32 data checks with the count and the order both
    -- green.  An asynchronous source needs one stage instead of two, so a
    -- source swap is not a free substitution.
    q_seg  : out integer range 0 to 2;
    q_grp  : out natural range 0 to (VAL_HEADS*DIM)/CONV_LANES-1;
    q_data : in  std_logic_vector(CONV_LANES*16-1 downto 0)
  );
end entity;

architecture rtl of gdn_job_seq is
  constant KEY_CH : positive := KEY_HEADS * DIM;
  constant VAL_CH : positive := VAL_HEADS * DIM;
  constant QKVN   : positive := 2*KEY_CH + VAL_CH;
  constant NG_K   : positive := KEY_CH / CONV_LANES;   -- groups in q, and in k
  constant NG_V   : positive := VAL_CH / CONV_LANES;   -- groups in v
  constant NG     : positive := QKVN / CONV_LANES;     -- groups in the walk

  -- ---- REFUSALS THAT RUN DURING ELABORATION ---------------------------
  -- Out-of-range `natural`s, not asserts: Vivado ignores
  -- `assert ... severity failure` in synthesis.  The NAME is the diagnostic.
  constant bad_kconv_below_two : natural := KCONV - 2;
  constant bad_key_ch_not_group_aligned : natural := 0 - (KEY_CH mod CONV_LANES);
  constant bad_val_ch_not_group_aligned : natural := 0 - (VAL_CH mod CONV_LANES);
  -- `cvw_grp`'s declared range is the WIDEST segment's, which is v.  A q or k
  -- segment wider than v would index past the end of the tap store, silently.
  constant bad_key_wider_than_val : natural := VAL_CH - KEY_CH;

  type st_t is (S_IDLE, S_LOAD, S_LOADW, S_GO, S_ARM, S_RUN,
                S_TAP, S_TAPD, S_SAVE, S_SAVEW, S_DONE);
  signal st : st_t := S_IDLE;

  signal lay_q  : integer range 0 to LAYERS-1 := 0;
  signal done_q : std_logic := '0';
  signal err_q  : std_logic := '0';

  -- The refill walk.  `wi` issues; the write trails it by TWO stages because
  -- the qkv read takes two edges (see the port comment).  `dv1`/`di1` is the
  -- group whose address is on the wires; `dv2`/`di2` is the group whose data
  -- arrives this cycle.
  signal wi  : natural range 0 to NG := 0;
  signal dv1, dv2 : std_logic := '0';
  signal di1, di2 : natural range 0 to NG-1 := 0;

  signal qs, cs : integer range 0 to 2 := 0;
  signal qg, cg : natural range 0 to NG_V-1 := 0;

  -- The flat group index split back into (segment, group).  The inverse of
  -- gdn_conv_tap_mem's `gidx`, and the same q | k | v order llama_top's
  -- `cvdata_p` and seq_opdec's MSEG mechanism use.
  procedure split(g : in natural; seg : out integer; grp : out natural) is
  begin
    if g < NG_K then
      seg := 0; grp := g;
    elsif g < 2*NG_K then
      seg := 1; grp := g - NG_K;
    else
      seg := 2; grp := g - 2*NG_K;
    end if;
  end procedure;
begin
  busy <= '0' when st = S_IDLE else '1';
  done <= done_q;
  err  <= err_q;
  ss_layer <= lay_q;

  q_seg <= qs;  q_grp <= qg;
  cvw_seg <= cs; cvw_grp <= cg;

  p : process(clk) is
    variable s : integer range 0 to 2;
    variable g : natural;
  begin
    if rising_edge(clk) then
      done_q        <= '0';
      ss_load_start <= '0';
      ss_save_start <= '0';
      b_start       <= '0';
      cvw_en        <= '0';

      if rst = '1' then
        st <= S_IDLE; err_q <= '0';
        wi <= 0; di1 <= 0; di2 <= 0; dv1 <= '0'; dv2 <= '0';
      else
        case st is
          when S_IDLE =>
            if start = '1' then
              -- LATCHED HERE AND READ FROM THE LATCH THEREAFTER.  A field read
              -- part-way through a long operation is the defect class every
              -- adapter in this design is built to avoid.
              lay_q <= layer;
              err_q <= '0';
              wi <= 0; di1 <= 0; di2 <= 0; dv1 <= '0'; dv2 <= '0';
              st    <= S_LOAD;
            end if;

          -- ---- load the layer's state ----------------------------------
          when S_LOAD =>
            ss_load_start <= '1';
            st <= S_LOADW;

          when S_LOADW =>
            -- `ss_done` is a PULSE.  `ss_err` is sticky and is captured with
            -- it, so a load that failed cannot look like one that finished.
            if ss_done = '1' then
              if ss_err = '1' then err_q <= '1'; end if;
              st <= S_GO;
            end if;

          -- ---- run the unit --------------------------------------------
          when S_GO =>
            b_start <= '1';
            st <= S_ARM;

          when S_ARM =>
            -- ARM ON THE RISE.  `b_busy` does not rise on the same edge as
            -- `b_start`, so waiting for it to FALL from here completes
            -- instantly and the whole job would run with the unit untouched.
            if b_busy = '1' then st <= S_RUN; end if;

          when S_RUN =>
            if b_busy = '0' then st <= S_TAP; end if;

          -- ---- refill the conv taps from this token's qkv ---------------
          -- One group issued per cycle, the write trailing the read by one.
          -- AFTER the unit, never during: see the header.
          when S_TAP =>
            -- stage 0: issue an address
            if wi < NG then
              split(wi, s, g);
              qs <= s; qg <= g;
              wi  <= wi + 1;
              dv1 <= '1';
              di1 <= wi;
            else
              dv1 <= '0';
            end if;

            -- stage 1: that address is on the wires now
            dv2 <= dv1;
            di2 <= di1;

            -- stage 2: its data arrives now.  `di2`, not `di1` -- pairing the
            -- write with the address currently on the wires is the off-by-one
            -- this pipeline exists to avoid.
            if dv2 = '1' then
              split(di2, s, g);
              cs <= s; cg <= g;
              cvw_en   <= '1';
              cvw_data <= q_data;
            end if;

            -- drain BOTH stages before moving on, or the last group is issued
            -- and never written.
            if wi = NG and dv1 = '0' and dv2 = '0' then st <= S_TAPD; end if;

          when S_TAPD =>
            -- One idle cycle so the last write has landed before `save_start`
            -- is asserted.  The store's own arbitration would hold it off
            -- anyway; this makes the ordering explicit rather than relying on
            -- what another module happens to do.
            st <= S_SAVE;

          -- ---- save it back --------------------------------------------
          when S_SAVE =>
            ss_save_start <= '1';
            st <= S_SAVEW;

          when S_SAVEW =>
            if ss_done = '1' then
              if ss_err = '1' then err_q <= '1'; end if;
              st <= S_DONE;
            end if;

          when S_DONE =>
            done_q <= '1';
            st     <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
