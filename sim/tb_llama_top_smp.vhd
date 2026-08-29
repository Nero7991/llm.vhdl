-- sim/tb_llama_top_smp.vhd
-- THE LOGITS EGRESS SEAM.  `FLG_TO_SMP`, END TO END, WITH A VALUE ORACLE.
--
-- =====================================================================
-- WHAT THIS FILE IS FOR
-- =====================================================================
-- `rtl/llama_map_pkg.vhd:102` defines FLG_TO_SMP.  Both schedule generators
-- set it on the lm_head step (`sim/llama_sched_pkg.vhd:277`,
-- `sim/seq_tbl_pkg.vhd:341`).  `rtl/seq_desc_fetch.vhd:495` and :504 CHECK it
-- -- `dst = 0xFF` is legal ONLY when a route flag says where the output went,
-- and a named destination WITH a route flag is equally refused -- so the
-- descriptor plane has always been able to express "this job's result leaves
-- the region file".  Nothing consumed it.  `rtl/llama_top.vhd`'s own banner
-- said so: "There is no sampler and no lm_head output.  The final A job is
-- issued with dst = R_NONE and its result is discarded."
--
-- With `SMP_EN` the A adapter routes that job's RAW s32 rows into
-- `rtl/sampler_stream.vhd`.  This bench is the value evidence for the route.
--
-- =====================================================================
-- WHY THE TABLE IS BUILT HERE AND NOT BY `llama_sched_pkg.build_plan`
-- =====================================================================
-- Three reasons, and the first two are the load-bearing ones.
--
-- (1) `build_plan` emits ONE lm_head step.  TRACK LMHEAD measured that the
--     real one cannot be one step: `output.weight` is 248,320 rows against a
--     `MAXROWS_BFP` of 17,408 and `rtl/matvec_int4_desc_axi.vhd`'s `S_CHECK`
--     bounds `n_rows` in EVERY out_mode, so the answer is FIFTEEN raw windows
--     at stride 17,376 (docs/debugging/2026-08-29_lmhead-window-schedule.md).
--     A sampler that is right for one window and wrong across a window
--     boundary is the defect this seam is most likely to have, and one window
--     cannot see it.  This table therefore emits TWO windows.
--
-- (2) Changing `build_plan`'s step count would change `llama_map_pkg.n_steps`,
--     which is `rtl/` and is what every existing landmark's 491-descriptor
--     count is measured against.  A window split belongs in the host
--     generator eventually; it does not belong in a bench's dependency.
--
-- (3) The block loop is irrelevant here.  This seam is one unit's output
--     leaving the machine; four A jobs reach it in seconds where a 491-step
--     token takes minutes.
--
-- Every descriptor is still built by `seq_tbl_pkg.mk_desc`, the same function
-- both real generators use, so the wire format cannot drift.
--
-- =====================================================================
-- THE ORACLE, AND WHAT EACH CONFIGURATION IS AND IS NOT EVIDENCE FOR
-- =====================================================================
-- A_BEHAV = TRUE (`sim/tb_llama_top_smp_beh.vhd`).  The behavioural A is
-- `y(r) = sum_c x(c) * wsyn(r,c,ord) >> out_shift` with `wsyn` a published
-- closed form (`rtl/llama_top.vhd`, function `wsyn`).  This bench recomputes
-- it INDEPENDENTLY from the region contents it wrote, so every logit, the
-- vocabulary index it carries and the final argmax are checked against
-- numbers this file derived without asking the DUT.  That is the VALUE
-- evidence for the seam.
--
-- A_BEHAV = FALSE (the default row).  The real `matvec_int4` in RAW
-- `out_mode`, so the logits are the s32 the real datapath produces.  There is
-- NO independent arithmetic oracle here and this file does not pretend to
-- one: A's arithmetic is `sim/run_matvec.sh`'s claim, against a C oracle and
-- a real packer.  What IS checked, and it is the whole of the new code:
--
--   * the logit COUNT and the vocabulary INDEX SEQUENCE, exactly;
--   * that every streamed value's low 16 bits equal the SAME job routed to a
--     region instead -- a ROUTE COMPARISON, not an oracle.  It cannot see a
--     defect inside `matvec_core`, because both sides come from it.  It CAN
--     see a serialiser that reorders lanes, drops a beat, folds a pad row or
--     numbers a window from zero, which is what this track wrote;
--   * one shared exponent for the whole token.
--
-- The route comparison is only sound because THIS BENCH'S WEIGHT MEMORY IS
-- STEP-INVARIANT (see `wword` below).  `rtl/llama_top.vhd`'s A adapter
-- derives the weight base from `j_step`, so with `tb_llama_top`'s image the
-- streamed job and its region-routed twin would read DIFFERENT weights and
-- the comparison would be vacuous -- it would fail for a legitimate reason
-- and then be "fixed" by loosening it.
--
-- =====================================================================
-- TEETH.  `sim/mutate_llama_top_smp.sh`.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;
use work.seq_tbl_pkg.mk_desc;
use work.seq_tbl_pkg.desc_t;

entity tb_llama_top_smp is
  generic(
    -- The A implementation.  FALSE = the real `matvec_int4` in raw out_mode.
    A_BEHAV : boolean := false;
    -- The two lm_head windows.  NEITHER is a multiple of A_ROWS_IF = 4, on
    -- purpose: `matvec_core.vhd:832-835` masks the pad rows of the last tile
    -- and a serialiser that ignored the mask would fold a value that is not a
    -- logit -- but only at row counts that are not a multiple of four, which
    -- is every real vocabulary shard except by accident.
    W0      : positive := 30;
    W1      : positive := 34;
    NTOK    : positive := 2;
    MAXCYC  : natural  := 400000;
    VERBOSE : boolean  := false
  );
end entity;

architecture tb of tb_llama_top_smp is

  -- The shape is used for REGION SIZES ONLY; the schedule is this file's.
  -- ATTN_HD 16 because `mk_shape_scaled`'s default 32 fails `attn_block`'s
  -- even-power-of-two fold, and this bench never runs C anyway.
  constant SHAPE  : shape_t  := mk_shape_scaled(1, 4, 16);
  constant REGMAX : positive := region_max(SHAPE);
  constant HID    : positive := SHAPE.hidden;

  constant LANES  : positive := 8;
  constant MANT_W : positive := 16;
  constant EXP_W  : positive := 16;
  constant STEP_W : positive := 11;
  constant ROWS_IF : positive := 4;      -- llama_top's A_ROWS_IF default
  constant NLOG   : positive := W0 + W1;

  -- The four A jobs plus END_TOKEN.  Steps 0 and 1 are the SAME two
  -- computations routed to a REGION, which is what the route comparison
  -- reads; steps 2 and 3 are the two lm_head windows.
  --
  -- THE WINDOWS COME LAST, IMMEDIATELY BEFORE END_TOKEN, and that ordering is
  -- load bearing.  It is where the real lm_head sits (`seq_tbl_pkg.vhd:341`,
  -- `llama_sched_pkg.vhd:243`), and it is the only ordering in which
  -- `tok_done` can arrive with logits still in the FIFO.  With the windows
  -- first there are two more A jobs of slack before the token ends, and a
  -- `done` that does not wait for the sampler is invisible.  MEASURED: with
  -- the windows first, mutation M9 -- S_SDRAIN not waiting for the drain --
  -- SURVIVED both rows.
  constant NSTEP  : positive := 5;
  constant S_C0   : natural := 0;
  constant S_C1   : natural := 1;
  constant S_W0   : natural := 2;
  constant S_W1   : natural := 3;

  -- The three per-step scalars.  Held IDENTICAL between a window and its
  -- region-routed twin, because they are what the twin has to reproduce.
  -- `out_shift` in [0, 40] or `matvec_core.vhd:850-867` raises `err` at
  -- `start` instead of computing.
  --
  -- THE TWO WINDOWS ARE DELIBERATELY UNBALANCED, and that is a property of
  -- the STIMULUS and not of the design.  Window 1 is shifted four places
  -- less, so its logits are about sixteen times window 0's and the argmax
  -- lands in it.  Without that the argmax would sit in window 0 for most
  -- random data, the vocabulary-index offset would never enter the answer,
  -- and P5 could not see a sampler numbering window 1 from zero.  MEASURED:
  -- with both windows at the same scale the argmax was at index 5 and 4 for
  -- the two tokens, i.e. inside window 0 both times.  P6 keeps this honest.
  --
  -- `w_exp - out_shift` is held CONSTANT across the two, because RAW
  -- `out_mode` publishes `w_exp + x_exp - out_shift` as the ONE exponent the
  -- whole token's logits share (`matvec_core.vhd:1032`).  Two windows of one
  -- tensor have one `w_exp` and one `out_shift` in reality; varying them
  -- here while holding the difference keeps that invariant true and still
  -- moves the payload, so P7 stays a real check rather than a tautology.
  function f_shift(st : natural) return integer is
  begin
    if st = S_W0 or st = S_C0 then return 4; else return 0; end if;
  end function;
  function f_wexp(st : natural) return integer is
  begin
    if st = S_W0 or st = S_C0 then return 4; else return 0; end if;
  end function;
  function f_ord(st : natural) return natural is
  begin
    if st = S_W0 or st = S_C0 then return 5; else return 9; end if;
  end function;
  function f_rows(st : natural) return natural is
  begin
    if st = S_W0 or st = S_C0 then return W0; else return W1; end if;
  end function;

  type tbl_t is array (0 to NSTEP*8-1) of std_logic_vector(63 downto 0);

  function build_smp_table return tbl_t is
    variable t : tbl_t := (others => (others => '0'));
    variable d : desc_t;

    procedure put(i : natural; dd : desc_t; wexp, oshift : integer) is
      variable e : desc_t := dd;
    begin
      e(2)(31 downto 0)  := std_logic_vector(to_signed(wexp, 32));
      e(2)(63 downto 32) := std_logic_vector(to_signed(oshift, 32));
      for w in 0 to 7 loop
        t(i*8 + w) := e(w);
      end loop;
    end procedure;
  begin
    -- The region-routed twins.  Same rows, same cols, same w_exp, same
    -- out_shift, same ordinal, same raw out_mode -- and NO route flag, which
    -- `seq_desc_fetch.vhd:504` requires when a destination is named.
    d := mk_desc(OP_A_JOB, src => R_X, dst => R_H, n_rows => W0,
                 n_cols => HID, out_mode => 1, ordinal => f_ord(S_C0));
    put(S_C0, d, f_wexp(S_C0), f_shift(S_C0));
    d := mk_desc(OP_A_JOB, src => R_X, dst => R_G, n_rows => W1,
                 n_cols => HID, out_mode => 1, ordinal => f_ord(S_C1));
    put(S_C1, d, f_wexp(S_C1), f_shift(S_C1));
    -- The two lm_head windows.  `dst = R_NONE` with FLG_TO_SMP and raw
    -- out_mode is exactly the encoding both real generators emit.
    for k in 0 to 1 loop
      d := mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_X, dst => R_NONE,
                   n_rows => f_rows(S_W0+k), n_cols => HID,
                   out_mode => 1, ordinal => f_ord(S_W0+k));
      put(S_W0+k, d, f_wexp(S_W0+k), f_shift(S_W0+k));
    end loop;
    put(4, mk_desc(OP_END_TOKEN), 0, 0);
    return t;
  end function;

  constant TBL : tbl_t := build_smp_table;

  -- THE RELEASE MASK, hand-computed rather than taken from `build_rel`.
  -- Every step consumes R_X and nothing re-produces it, so the LAST reader
  -- releases it and no earlier one does -- which is `build_rel`'s rule
  -- (`sim/llama_sched_pkg.vhd`, THE LIVENESS PASS) applied to four steps.
  function rel_of(st : natural) return std_logic_vector is
    variable m : std_logic_vector(NREGION-1 downto 0) := (others => '0');
  begin
    if st = S_W1 then m(R_X) := '1'; end if;
    return m;
  end function;

  -- ---- the oracle's weight, for A_BEHAV ---------------------------------
  -- An INDEPENDENT transcription of the closed form in `rtl/llama_top.vhd`'s
  -- `wsyn`.  It is a transcription and not a call, because the function is
  -- private to that architecture; a mutation of the RTL copy is therefore
  -- visible here, which is the point.
  function wsyn_ref(r, c, o : natural) return integer is
  begin
    return ((r*13 + c*7 + o*29) mod 15) - 7;
  end function;

  -- The token embedding.  Depends on BOTH index and token.
  --
  -- MEASURED LIMITATION, STATED HERE RATHER THAN DISCOVERED LATER: the argmax
  -- INDEX does not move between the two tokens (40 and 40 behavioural, 60 and
  -- 60 real) even though every logit VALUE does (218,667 -> 114,543 and
  -- 2,233,467 -> 1,199,035).  Both weight images are fixed across tokens and
  -- one row dominates the row norm, so the winner is a property of the
  -- WEIGHTS and not of x.  P5 therefore gets its teeth from the values and
  -- the indices, not from the argmax moving with the token, and a defect that
  -- froze the argmax at a constant would not be caught by comparing tokens.
  --
  -- THE MAGNITUDE IS CHOSEN, NOT ARBITRARY.  RAW `out_mode` emits an s32
  -- (`matvec_core.vhd:829`) and the whole reason the sampler takes a bare
  -- 32-bit integer is that a logit does not fit in the s16 a region write
  -- carries.  At +/-200 the logits came out around 5,000 and a mutation
  -- narrowing the streamed value to 16 bits was INVISIBLE (M15 SURVIVED).
  -- At +/-20,000 they are comfortably outside s16, so the width is part of
  -- the answer rather than a spare bit.
  function embed(i, t : natural) return integer is
  begin
    return ((i*37 + t*8677 + 11) mod 40001) - 20000;
  end function;

  -- ---- the step-invariant weight memory ---------------------------------
  -- `wword` answers on `(addr mod A_JOB_STRIDE)`, so every step reads the
  -- same image.  See the header: without this the route comparison compares
  -- two different matrices.
  constant A_JOB_STRIDE_C : natural := 16#8000#;
  constant A_MEM_BASE_C   : natural := 16#100000#;

  function wword(p : natural; idx : natural) return std_logic_vector is
    variable v : std_logic_vector(127 downto 0);
    variable x : natural;
  begin
    if p = A_NPORTS-1 then
      -- The scale lane.  Spec constrains a block scale to uint15, so 32768
      -- does not fit; masked into [16384, 32767].
      for l in 0 to 7 loop
        x := 16384 + ((idx*13 + l*7 + 3) mod 16384);
        v(l*16+15 downto l*16) := std_logic_vector(to_unsigned(x, 16));
      end loop;
    else
      for b in 0 to 15 loop
        x := (idx*7919 + p*104729 + b*31 + 17) mod 251;
        v(b*8+7 downto b*8) := std_logic_vector(to_unsigned(x, 8));
      end loop;
    end if;
    return v;
  end function;

  -- ======================================================================
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  signal go, abort, tok_ack : std_logic := '0';
  signal tbl_len : unsigned(STEP_W-1 downto 0) := to_unsigned(NSTEP, STEP_W);
  signal host_x_exp : signed(EXP_W-1 downto 0) := to_signed(3, EXP_W);
  signal rel_mask : std_logic_vector(NREGION-1 downto 0) := (others => '0');

  signal busy, tok_done, err : std_logic;
  signal err_code : std_logic_vector(3 downto 0);
  signal err_step, steps_done : unsigned(STEP_W-1 downto 0);

  signal d_raddr : unsigned(15 downto 0);
  signal d_ren, d_rvalid : std_logic := '0';
  signal d_rdata : std_logic_vector(63 downto 0) := (others => '0');

  signal hw_we : std_logic := '0';
  signal hw_reg : natural range 0 to NREGION-1 := 0;
  signal hw_addr : natural range 0 to REGMAX-1 := 0;
  signal hw_data : signed(MANT_W-1 downto 0) := (others => '0');
  signal hr_reg : natural range 0 to NREGION-1 := 0;
  signal hr_addr : natural range 0 to REGMAX-1 := 0;
  signal hr_data : signed(MANT_W-1 downto 0);

  signal obs_issue, obs_cmp : std_logic;
  signal obs_unit : unsigned(2 downto 0);
  signal obs_opcode : unsigned(3 downto 0);
  signal obs_step : unsigned(STEP_W-1 downto 0);
  signal obs_dst : unsigned(7 downto 0);

  signal err_lost_beat, err_gate_drop, err_unit_stub, err_e_coll : std_logic;
  signal err_smp_ovf : std_logic;

  signal smp_valid : std_logic;
  signal smp_v     : std_logic_vector(31 downto 0);
  signal smp_idx   : unsigned(31 downto 0);
  signal smp_exp   : signed(EXP_W-1 downto 0);
  signal smp_token : unsigned(31 downto 0);
  signal smp_done  : std_logic;
  signal smp_n     : unsigned(31 downto 0);

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast
       : std_logic_vector(A_NPORTS-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(A_NPORTS*32-1 downto 0);
  signal m_arlen   : std_logic_vector(A_NPORTS*8-1 downto 0);
  signal m_arsize  : std_logic_vector(A_NPORTS*3-1 downto 0);
  signal m_arburst : std_logic_vector(A_NPORTS*2-1 downto 0);
  signal m_rdata   : std_logic_vector(A_NPORTS*128-1 downto 0)
                   := (others => '0');

  signal n_chk   : natural := 0;
  signal tb_reset : std_logic := '0';

  -- ---- what the stream said, captured for the checks ------------------
  type ivec is array (natural range <>) of integer;
  signal cap_v   : ivec(0 to NLOG-1) := (others => 0);
  signal cap_i   : ivec(0 to NLOG-1) := (others => -1);
  signal n_cap   : natural := 0;
  signal n_bad_idx : natural := 0;
  signal n_bad_val : natural := 0;
  signal n_bad_exp : natural := 0;
  signal n_done_p  : natural := 0;
  signal exp_seen  : integer := 0;
  signal exp_first : boolean := true;
  signal tok_at_done : integer := -1;
  signal n_over    : natural := 0;

  signal fail : natural := 0;

begin

  clk <= not clk after 5 ns when running else '0';
  cycc : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_llama_top_smp: FAIL, the run exceeded " & integer'image(MAXCYC)
             & " cycles" severity failure;
    end if;
  end process;

  dut : entity work.llama_top
    generic map(
      SHAPE => SHAPE, LANES => LANES, MANT_W => MANT_W, EXP_W => EXP_W,
      REGMAX => REGMAX, STEP_W => STEP_W,
      WDOG_LIMIT => 200000, STRICT => true,
      A_BEHAV => A_BEHAV, B_BEHAV => true,
      A_MEM_BASE => A_MEM_BASE_C, A_JOB_STRIDE => A_JOB_STRIDE_C,
      SMP_EN => true, SMP_FIFO => 64,
      SHOUT => false)
    port map(
      clk => clk, rst => rst,
      go => go, abort => abort, tbl_len => tbl_len,
      host_x_exp => host_x_exp, rel_mask => rel_mask,
      busy => busy, tok_done => tok_done, tok_ack => tok_ack,
      err => err, err_code => err_code, err_step => err_step,
      steps_done => steps_done,
      d_raddr => d_raddr, d_ren => d_ren, d_rdata => d_rdata,
      d_rvalid => d_rvalid,
      hw_we => hw_we, hw_reg => hw_reg, hw_addr => hw_addr, hw_data => hw_data,
      hr_reg => hr_reg, hr_addr => hr_addr, hr_data => hr_data,
      obs_issue => obs_issue, obs_unit => obs_unit, obs_opcode => obs_opcode,
      obs_step => obs_step, obs_dst => obs_dst, obs_cmp => obs_cmp,
      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
      m_rlast => m_rlast,
      smp_valid => smp_valid, smp_v => smp_v, smp_idx => smp_idx,
      smp_exp => smp_exp, smp_token => smp_token, smp_done => smp_done,
      smp_n => smp_n,
      err_smp_ovf => err_smp_ovf,
      err_lost_beat => err_lost_beat, err_gate_drop => err_gate_drop,
      err_unit_stub => err_unit_stub, err_e_coll => err_e_coll);

  -- ======================================================================
  -- THE AXI READ SLAVES.  One per weight port, INCR only, one burst in
  -- flight, `rvalid` held until `rready`.  Step-invariant image; see wword.
  -- ======================================================================
  slaves : for p in 0 to A_NPORTS-1 generate
    signal aw    : unsigned(31 downto 0) := (others => '0');
    signal beats : natural := 0;
    signal act   : std_logic := '0';
  begin
    m_arready(p) <= not act;
    slv : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '1' then
          act <= '0'; beats <= 0; m_rvalid(p) <= '0'; m_rlast(p) <= '0';
        elsif act = '0' then
          m_rvalid(p) <= '0';
          m_rlast(p)  <= '0';
          if m_arvalid(p) = '1' then
            assert m_arburst((p+1)*2-1 downto p*2) = "01"
              report "tb_llama_top_smp: FAIL, port " & integer'image(p)
                   & " issued a burst that is not INCR" severity failure;
            aw    <= unsigned(m_araddr((p+1)*32-1 downto p*32));
            beats <= to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
            act   <= '1';
          end if;
        else
          if m_rvalid(p) = '0' or m_rready(p) = '1' then
            if beats > 0 then
              m_rdata((p+1)*128-1 downto p*128)
                <= wword(p, (to_integer(aw) mod A_JOB_STRIDE_C) / 16);
              m_rvalid(p) <= '1';
              if beats = 1 then m_rlast(p) <= '1';
              else              m_rlast(p) <= '0'; end if;
              aw    <= aw + 16;
              beats <= beats - 1;
            else
              m_rvalid(p) <= '0';
              m_rlast(p)  <= '0';
              act         <= '0';
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- ======================================================================
  -- THE DESCRIPTOR MEMORY.  `d_rdata` is 'X' whenever `d_rvalid` is low, so
  -- a walker sampling on the wrong cycle poisons its shadow instead of being
  -- right by luck.
  -- ======================================================================
  uram : process(clk) is
    variable a1, a2 : natural := 0;
    variable v1, v2 : std_logic := '0';
  begin
    if rising_edge(clk) then
      a2 := a1; v2 := v1;
      if d_ren = '1' then a1 := to_integer(d_raddr); else a1 := 0; end if;
      v1 := d_ren;
      if v2 = '1' then
        d_rvalid <= '1';
        if a2 < NSTEP*8 then d_rdata <= TBL(a2);
        else                 d_rdata <= (others => 'X'); end if;
      else
        d_rvalid <= '0';
        d_rdata  <= (others => 'X');
      end if;
    end if;
  end process;

  rel_mask <= rel_of(n_chk) when n_chk < NSTEP else (others => '0');

  chkcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or tb_reset = '1' or go = '1' then
        n_chk <= 0;
      elsif rst = '0' and tb_reset = '0' and obs_issue = '1' then
        n_chk <= n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE CAPTURE.  Every logit, with the index and the exponent it arrived
  -- with.  A signal per beat, not a shared variable, so a second driver is
  -- an elaboration error rather than a silent last-write-wins.
  -- ======================================================================
  cap : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or go = '1' then
        n_cap     <= 0;
        exp_first <= true;
        cap_i     <= (others => -1);
      else
        if smp_valid = '1' then
          if n_cap < NLOG then
            cap_v(n_cap) <= to_integer(signed(smp_v));
            cap_i(n_cap) <= to_integer(smp_idx);
          else
            n_over <= n_over + 1;
          end if;
          n_cap <= n_cap + 1;
          -- ONE exponent for the whole token.  Raw out_mode publishes
          -- `w_exp + x_exp - out_shift` with no per-job term
          -- (`matvec_core.vhd:1032`); that is the property that lets fifteen
          -- windows feed one comparator, and it is checked and not assumed.
          if exp_first then
            exp_seen  <= to_integer(smp_exp);
            exp_first <= false;
          elsif to_integer(smp_exp) /= exp_seen then
            n_bad_exp <= n_bad_exp + 1;
          end if;
        end if;
        if smp_done = '1' then
          n_done_p    <= n_done_p + 1;
          tok_at_done <= to_integer(smp_token);
        end if;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DRIVER AND THE CHECKS.
  -- ======================================================================
  drv : process is
    variable xb   : ivec(0 to REGMAX-1) := (others => 0);
    variable orc  : ivec(0 to NLOG-1)   := (others => 0);
    variable reg  : ivec(0 to NLOG-1)   := (others => 0);
    variable acc  : integer;
    variable sh   : integer;
    variable best_i, best_v : integer;
    variable vlo  : signed(31 downto 0);
    variable nbad : natural;
    variable r0   : natural;

    procedure preload(t : natural) is
    begin
      for i in 0 to HID-1 loop
        wait until rising_edge(clk);
        hw_we   <= '1';
        hw_reg  <= R_X;
        hw_addr <= i;
        hw_data <= to_signed(embed(i, t), MANT_W);
      end loop;
      wait until rising_edge(clk);
      hw_we <= '0';
    end procedure;

    procedure readback(rg : natural; n : natural; off : natural) is
    begin
      for i in 0 to n-1 loop
        hr_reg  <= rg;
        hr_addr <= i;
        wait until rising_edge(clk);
        wait for 0.1 ns;
        reg(off + i) := to_integer(hr_data);
      end loop;
    end procedure;
  begin
    report "tb_llama_top_smp: A_BEHAV=" & boolean'image(A_BEHAV)
         & " windows " & integer'image(W0) & "+" & integer'image(W1)
         & " = " & integer'image(NLOG) & " logits, " & integer'image(NTOK)
         & " tokens" severity note;

    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for t in 0 to NTOK-1 loop
      preload(t);
      for i in 0 to HID-1 loop
        xb(i) := embed(i, t);
      end loop;

      wait until rising_edge(clk);
      go <= '1';
      wait until rising_edge(clk);
      go <= '0';

      wait until tok_done = '1' for 2 ms;
      assert tok_done = '1'
        report "tb_llama_top_smp: FAIL, token " & integer'image(t)
             & " never reached tok_done" severity failure;

      assert err = '0'
        report "tb_llama_top_smp: FAIL, token " & integer'image(t)
             & " ended with err_code " & integer'image(to_integer(unsigned(err_code)))
             & " at step " & integer'image(to_integer(err_step))
        severity failure;

      -- ---- P1.  THE COUNT.  Every logit, and no pad row.
      assert n_cap = NLOG
        report "tb_llama_top_smp: FAIL, token " & integer'image(t)
             & " streamed " & integer'image(n_cap) & " logits; the two "
             & "windows are " & integer'image(W0) & " + " & integer'image(W1)
             & " = " & integer'image(NLOG) & " rows"
        severity error;
      if n_cap /= NLOG then fail <= fail + 1; wait for 0 ns; end if;

      assert to_integer(smp_n) = NLOG
        report "tb_llama_top_smp: FAIL, the DUT's own smp_n says "
             & integer'image(to_integer(smp_n)) & " and "
             & integer'image(NLOG) & " logits were streamed"
        severity error;
      if to_integer(smp_n) /= NLOG then fail <= fail + 1; wait for 0 ns; end if;

      assert n_over = 0
        report "tb_llama_top_smp: FAIL, " & integer'image(n_over)
             & " logits arrived past the expected count" severity error;

      -- ---- P2.  THE VOCABULARY INDEX.  0 .. NLOG-1, in order.  This is the
      -- window-base property: window 1's rows are numbered 0..W1-1 inside the
      -- job and W0..W0+W1-1 in the vocabulary, and a sampler fed the former
      -- returns an argmax that is a row and not a token.
      nbad := 0;
      for i in 0 to NLOG-1 loop
        if cap_i(i) /= i then nbad := nbad + 1; end if;
      end loop;
      assert nbad = 0
        report "tb_llama_top_smp: FAIL, token " & integer'image(t) & ", "
             & integer'image(nbad) & " of " & integer'image(NLOG)
             & " logits carried the wrong vocabulary index (first window is "
             & "0.." & integer'image(W0-1) & ", second is "
             & integer'image(W0) & ".." & integer'image(NLOG-1) & ")"
        severity error;
      if nbad /= 0 then fail <= fail + 1; wait for 0 ns; end if;

      -- ---- P3.  THE VALUES, against an independent recomputation.
      -- A_BEHAV only; see the header for why the real path has no oracle here.
      if A_BEHAV then
        for w in S_W0 to S_W1 loop
          if w = S_W0 then r0 := 0; else r0 := W0; end if;
          for r in 0 to f_rows(w)-1 loop
            acc := 0;
            for c in 0 to HID-1 loop
              acc := acc + xb(c) * wsyn_ref(r, c, f_ord(w));
            end loop;
            sh := acc / (2**f_shift(w));
            orc(r0 + r) := sh;
          end loop;
        end loop;
        nbad := 0;
        for i in 0 to NLOG-1 loop
          if cap_v(i) /= orc(i) then
            nbad := nbad + 1;
            if nbad <= 4 then
              report "tb_llama_top_smp: logit " & integer'image(i)
                   & " streamed " & integer'image(cap_v(i))
                   & ", oracle " & integer'image(orc(i)) severity note;
            end if;
          end if;
        end loop;
        assert nbad = 0
          report "tb_llama_top_smp: FAIL, token " & integer'image(t) & ", "
               & integer'image(nbad) & " of " & integer'image(NLOG)
               & " logits DIVERGES from the oracle" severity error;
        if nbad /= 0 then fail <= fail + 1; wait for 0 ns; end if;
      end if;

      -- ---- P4.  THE ROUTE COMPARISON.  The same two computations routed to
      -- a region instead of the sampler.  Real A only: the behavioural A
      -- saturates its region write to 16 bits and truncates nothing, so the
      -- two sides carry different arithmetic and a comparison would be a
      -- statement about `sat_m` and not about the route.
      if not A_BEHAV then
        readback(R_H, W0, 0);
        readback(R_G, W1, W0);
        nbad := 0;
        for i in 0 to NLOG-1 loop
          vlo := to_signed(cap_v(i), 32);
          if to_integer(vlo(MANT_W-1 downto 0)) /= reg(i) then
            nbad := nbad + 1;
            if nbad <= 4 then
              report "tb_llama_top_smp: logit " & integer'image(i)
                   & " streamed " & integer'image(cap_v(i))
                   & ", region twin " & integer'image(reg(i)) severity note;
            end if;
          end if;
        end loop;
        assert nbad = 0
          report "tb_llama_top_smp: FAIL, token " & integer'image(t) & ", "
               & integer'image(nbad) & " of " & integer'image(NLOG)
               & " streamed logits DIVERGES from the region-routed twin"
          severity error;
        if nbad /= 0 then fail <= fail + 1; wait for 0 ns; end if;
      end if;

      -- ---- P5.  THE ARGMAX, first-max-on-ties, over the STREAM.
      -- `rtl/sampler_stream.vhd:57` uses a strict '>' so index 0 wins a tie.
      best_i := 0;
      best_v := cap_v(0);
      for i in 1 to NLOG-1 loop
        if cap_v(i) > best_v then
          best_v := cap_v(i);
          best_i := i;
        end if;
      end loop;
      assert tok_at_done = best_i
        report "tb_llama_top_smp: FAIL, token " & integer'image(t)
             & ", the sampler returned " & integer'image(tok_at_done)
             & " and the argmax of the stream it was fed is "
             & integer'image(best_i) & " (value " & integer'image(best_v) & ")"
        severity error;
      if tok_at_done /= best_i then fail <= fail + 1; wait for 0 ns; end if;

      -- ---- P6.  THE STIMULUS HAS TEETH.  If the argmax always fell in
      -- window 0 the window-base bug would be invisible to P5, and P2 would
      -- be the only thing holding it.  This is a check on the BENCH, and it
      -- is an error rather than a note because a stimulus that stops
      -- discriminating stops being evidence.
      assert best_i >= W0
        report "tb_llama_top_smp: FAIL, token " & integer'image(t)
             & ", the argmax is at " & integer'image(best_i)
             & ", inside the FIRST window (0.." & integer'image(W0-1)
             & ").  The stimulus can no longer see a missing window base."
        severity error;
      if best_i < W0 then fail <= fail + 1; wait for 0 ns; end if;

      -- ---- P7.  ONE `smp_done` PER FLG_TO_SMP JOB, and one shared exponent.
      -- TWO per token here, because two windows.  Checked as 2*(t+1) rather
      -- than t+1 deliberately: the machine has no field telling it which
      -- window is the last, so a per-TOKEN pulse would be a claim the design
      -- cannot make.  The token's argmax is final at `tok_done`.
      assert n_done_p = 2*(t+1)
        report "tb_llama_top_smp: FAIL, " & integer'image(n_done_p)
             & " smp_done pulses after " & integer'image(t+1)
             & " tokens of two windows each" severity error;
      if n_done_p /= 2*(t+1) then fail <= fail + 1; wait for 0 ns; end if;

      assert n_bad_exp = 0
        report "tb_llama_top_smp: FAIL, " & integer'image(n_bad_exp)
             & " logits carried an exponent other than "
             & integer'image(exp_seen) severity error;
      if n_bad_exp /= 0 then fail <= fail + 1; wait for 0 ns; end if;

      -- ---- P8.  NO SEAM FAULT.  `y_we` has no ready, so a dropped beat is
      -- silent in the arithmetic and only these say so.
      assert err_smp_ovf = '0'
        report "tb_llama_top_smp: FAIL, the logits FIFO overflowed"
        severity error;
      if err_smp_ovf = '1' then fail <= fail + 1; wait for 0 ns; end if;
      assert err_lost_beat = '0'
        report "tb_llama_top_smp: FAIL, err_lost_beat" severity error;
      if err_lost_beat = '1' then fail <= fail + 1; wait for 0 ns; end if;

      report "tb_llama_top_smp: token " & integer'image(t) & ": "
           & integer'image(n_cap) & " logits, exponent "
           & integer'image(exp_seen) & ", argmax " & integer'image(tok_at_done)
           & " value " & integer'image(best_v) severity note;

      if VERBOSE then
        for i in 0 to NLOG-1 loop
          report "  logit " & integer'image(cap_i(i)) & " = "
               & integer'image(cap_v(i)) severity note;
        end loop;
      end if;

      tok_ack <= '1';
      wait until rising_edge(clk);
      tok_ack <= '0';
      wait until rising_edge(clk);
    end loop;

    if fail = 0 then
      report "tb_llama_top_smp: PASS.  " & integer'image(NTOK) & " tokens, "
           & integer'image(NLOG) & " logits each, two lm_head windows, "
           & "A_BEHAV=" & boolean'image(A_BEHAV) severity note;
    else
      report "tb_llama_top_smp: FAIL, " & integer'image(fail)
           & " properties failed" severity error;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
