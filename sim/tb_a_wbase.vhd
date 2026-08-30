-- sim/tb_a_wbase.vhd -- THE ADDRESS STREAM subsystem A issues for its weights,
-- checked as a first-class output.  TRACK BASEFAB, 2026-08-30.
--
-- ======================================================================
-- WHY A BENCH FOR ADDRESSES, WHEN EVERY OTHER llama_top ROW IS GREEN
-- ======================================================================
-- `rtl/llama_top.vhd` FABRICATES the weight address of every A job:
--
--     base := A_MEM_BASE + j_step * A_JOB_STRIDE
--     w_base(p) := base + p * A_SUB_BYTES
--     s_base    := base + A_ROWS_IF * A_SUB_BYTES
--
-- The descriptor's base array at offset 0x40 is never fetched -- both
-- `rtl/seq_desc_fetch.vhd`'s header (:113-115) and `rtl/llama_top.vhd`'s
-- own banner say so.  So A reads whatever happens to be at a made-up
-- address, and it reports `done = 1, err = 0` while doing it.
--
-- EVERY EXISTING ROW IS BLIND TO THIS, AND NOT BY OVERSIGHT.  Both weight
-- memories in the tree are the fabrication's own INVERSE:
--
--   * `sim/tb_llama_top_smp.vhd:435` answers on
--     `(addr mod A_JOB_STRIDE) / 16`, so the `j_step * A_JOB_STRIDE` term is
--     divided straight back out and EVERY step reads the same bytes.  That
--     is deliberate there -- its route comparison needs one matrix -- and it
--     means the step term could be deleted with no effect on that row.
--   * `sim/tb_llama_top.vhd:876-890` decodes `stp := off / A_JOB_STRIDE_C`
--     and `sub := rmn / A_SUB_BYTES` and indexes its image by them, i.e. it
--     is the same function the DUT applies, run backwards.  A base is
--     therefore right by construction there, and cannot be wrong.
--
-- A wrong-ADDRESS defect needs an oracle at the level of the ADDRESS, and
-- neither of those is one.  This file is.
--
-- ======================================================================
-- WHAT THIS FILE CAN AND CANNOT ESTABLISH.  STATED FIRST.
-- ======================================================================
-- It CANNOT establish that a base points at the right BYTES.  Nothing in
-- this repository can, at this level, because the only independent statement
-- of where a tensor's sub-regions live is the descriptor's base array and
-- subsystem D does not carry it.  That is the finding, not a gap in this
-- bench, and it is written up in
-- `docs/debugging/2026-08-30_basefab-a-weight-base-provenance.md`.
--
-- What it DOES establish is every property of the address stream that does
-- NOT need to know the answer:
--
--   P1  CONTAINMENT.  A job's reads on port p stay inside the ONE sub-region
--       the fabrication gave port p.  This is the property whose violation is
--       the whole reason this file exists: a job needing more than
--       A_SUB_BYTES/16 beats walks into port p+1's sub-region and reads it as
--       its own weights, successfully.
--   P2  ALIGNMENT.  Every base is 4 KB aligned, which `rtl/axi_rd_port.vhd`
--       requires and nothing above it checked.
--   P3  INTRA-JOB DISJOINTNESS.  Within one job the five ports' extents do
--       not overlap.  Two ports reading one extent is two copies of one
--       weight quarter and a silently wrong dot product.
--   P4  INTER-JOB DISJOINTNESS.  Two different steps never touch a common
--       byte.  This is what the `j_step` term is FOR, and it is the property
--       `tb_llama_top_smp`'s modulo memory structurally cannot see.
--   P5  BEAT ACCOUNTING.  Beats issued per port equal `tiles*nblk` derived
--       HERE from this file's own table, not from the RTL's decode, and the
--       scale port equals `ceil(tiles*nblk*ROWS_IF*2/16)`.
--   P6  CONTIGUITY AND ORDER.  Bursts on a port tile the extent exactly:
--       each starts where the previous ended, none repeats, none gaps.
--   P7  BURST LEGALITY.  INCR only, and `arlen+1 <= A_MAXB`.
--   P8  REFUSAL BEFORE THE FIRST READ.  A job that does not fit its
--       sub-region issues ZERO address beats and raises ERR_UNIT.  Not "is
--       detected afterwards": `matvec_int4_desc_axi`'s header states the rule
--       -- a descriptor rejected after the array has begun consuming weights
--       has already read the wrong memory -- and this checks the ordering,
--       not just the outcome.
--
-- ======================================================================
-- TWO PHASES IN ONE RUN, AND WHY BOTH ARE HERE
-- ======================================================================
-- Phase 1 is a three-A-job token that FITS.  P1..P7 are checked on it.
-- Phase 2 is a one-A-job token that does NOT fit, after a reset, and P8 is
-- checked on it.  They are in one file because a bench that only ran the
-- fitting case would report PASS over a guard it never made fire, which is
-- this project's named defect class ("a check never shown to fail has not
-- been shown to work").  Phase 2 is the teeth of phase 1's P1.
--
-- The overflowing job is a FLG_TO_SMP window with `dst = R_NONE`, because
-- that is the one A opcode whose `n_rows` is not bounded by a region size --
-- `seq_desc_fetch.vhd:496-506` skips the region check when the destination
-- is R_NONE and a route flag names the sink.  520 rows at 64 columns is
-- `ceil(520/4)*ceil(64/32) = 130*2 = 260` beats against the 256-beat
-- capacity of a 4 KB sub-region: over by four, which is the smallest
-- overshoot the shape allows and therefore the hardest one to catch.
--
-- SHAPE NOTE: `mk_shape_scaled` is hardwired to hidden 64 / ffn 128, so the
-- overflow CANNOT be reached through a region-routed job at any argument.
-- That is why phase 2 routes to the sampler and why SMP_EN is on.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;
use work.seq_tbl_pkg.mk_desc;
use work.seq_tbl_pkg.desc_t;

entity tb_a_wbase is
  generic(
    MAXCYC  : natural := 400000;
    VERBOSE : boolean := false
  );
end entity;

architecture tb of tb_a_wbase is

  -- ATTN_HD 16 for the same reason `tb_llama_top_smp` gives: 32 fails
  -- `attn_block`'s even-power-of-two fold and C never runs here anyway.
  constant SHAPE  : shape_t  := mk_shape_scaled(1, 4, 16);
  constant REGMAX : positive := region_max(SHAPE);
  constant HID    : positive := SHAPE.hidden;      -- 64

  constant LANES   : positive := 8;
  constant MANT_W  : positive := 16;
  constant EXP_W   : positive := 16;
  constant STEP_W  : positive := 11;

  -- llama_top's A defaults, restated here so the checks below are computed
  -- from a source the DUT does not also compute from.  A DRIFT between these
  -- and the generics is a FAILURE of this bench, which is the correct
  -- direction: the numbers are pinned in one place and disagreed with here.
  constant ROWS_IF     : positive := 4;
  constant A_BLK       : positive := 32;
  constant A_MAXB      : positive := 16;
  constant A_SUB_BYTES : natural  := 4096;
  constant A_JOB_STRIDE: natural  := 16#8000#;
  constant A_MEM_BASE  : natural  := 16#100000#;
  constant BEAT_B      : natural  := 16;           -- 128-bit masters
  constant SUB_BEATS   : natural  := A_SUB_BYTES / BEAT_B;             -- 256
  constant SCL_BEATS   : natural  :=
    (A_JOB_STRIDE - ROWS_IF * A_SUB_BYTES) / BEAT_B;                   -- 1024

  constant ERR_UNIT : std_logic_vector(3 downto 0) := x"1";

  -- ---------------------------------------------------------------- tables
  constant NS_MAX : natural := 8;

  -- PHASE 1.  Three A jobs that fit, then END_TOKEN.  The row counts are
  -- DISTINCT and none is a multiple of ROWS_IF, so P5's `tiles` term is a
  -- ceiling and not a division, and the three extents have three different
  -- lengths -- an extent length that did not move with `n_rows` would fail
  -- P5 on two of the three rather than on none.
  constant F_ROWS : integer_vector(0 to 2) := (100, 62, 45);
  constant F_COLS : integer_vector(0 to 2) := (HID, HID, HID);
  constant NS_FIT : positive := 4;

  -- PHASE 2.  One A job that does not fit, then END_TOKEN.
  constant O_ROWS : natural := 520;
  constant O_COLS : natural := HID;
  constant NS_OVF : positive := 2;

  type tbl_t is array (0 to NS_MAX*8-1) of std_logic_vector(63 downto 0);

  procedure put(variable t : inout tbl_t; i : natural; dd : desc_t;
                wexp, oshift : integer) is
    variable e : desc_t := dd;
  begin
    e(2)(31 downto 0)  := std_logic_vector(to_signed(wexp, 32));
    e(2)(63 downto 32) := std_logic_vector(to_signed(oshift, 32));
    for w in 0 to 7 loop
      t(i*8 + w) := e(w);
    end loop;
  end procedure;

  function build_fit return tbl_t is
    variable t : tbl_t := (others => (others => '0'));
  begin
    -- Two region-routed jobs and one sampler window.  R_H and R_G are both
    -- `ffn` = 128 elements, so 100 and 62 rows are inside them.
    put(t, 0, mk_desc(OP_A_JOB, src => R_X, dst => R_H,
                      n_rows => F_ROWS(0), n_cols => F_COLS(0),
                      out_mode => 0, ordinal => 1), 4, 4);
    put(t, 1, mk_desc(OP_A_JOB, src => R_X, dst => R_G,
                      n_rows => F_ROWS(1), n_cols => F_COLS(1),
                      out_mode => 0, ordinal => 2), 4, 4);
    put(t, 2, mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_X,
                      dst => R_NONE,
                      n_rows => F_ROWS(2), n_cols => F_COLS(2),
                      out_mode => 1, ordinal => 3), 4, 4);
    put(t, 3, mk_desc(OP_END_TOKEN), 0, 0);
    return t;
  end function;

  function build_ovf return tbl_t is
    variable t : tbl_t := (others => (others => '0'));
  begin
    put(t, 0, mk_desc(OP_A_JOB, flags => FLG_TO_SMP, src => R_X,
                      dst => R_NONE, n_rows => O_ROWS, n_cols => O_COLS,
                      out_mode => 1, ordinal => 1), 4, 4);
    put(t, 1, mk_desc(OP_END_TOKEN), 0, 0);
    return t;
  end function;

  constant TBL_FIT : tbl_t := build_fit;
  constant TBL_OVF : tbl_t := build_ovf;

  -- The release mask.  Every A job consumes R_X and nothing re-produces it,
  -- so the LAST reader releases it -- `build_rel`'s liveness rule applied by
  -- hand to a four-step table, exactly as `tb_llama_top_smp` does.
  function rel_fit(st : natural) return std_logic_vector is
    variable m : std_logic_vector(NREGION-1 downto 0) := (others => '0');
  begin
    if st = 2 then m(R_X) := '1'; end if;
    return m;
  end function;

  function rel_ovf(st : natural) return std_logic_vector is
    variable m : std_logic_vector(NREGION-1 downto 0) := (others => '0');
  begin
    if st = 0 then m(R_X) := '1'; end if;
    return m;
  end function;

  -- The expected beat counts, DERIVED here from this file's own table.
  function n_tiles(rows : natural) return natural is
  begin return (rows + ROWS_IF - 1) / ROWS_IF; end function;
  function n_blk(cols : natural) return natural is
  begin return (cols + A_BLK - 1) / A_BLK; end function;
  function w_beats(rows, cols : natural) return natural is
  begin return n_tiles(rows) * n_blk(cols); end function;
  function s_beats(rows, cols : natural) return natural is
  begin return (w_beats(rows, cols) * ROWS_IF * 2 + 15) / 16; end function;

  -- ================================================================ signals
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;
  signal cyc : natural := 0;

  signal go, abort, tok_ack : std_logic := '0';
  signal tbl_len : unsigned(STEP_W-1 downto 0) := to_unsigned(NS_FIT, STEP_W);
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

  signal phase   : natural := 1;
  signal n_chk   : natural := 0;
  signal cur_st  : natural := 0;

  -- ---- THE CAPTURE.  One row per (step, port). ------------------------
  -- Signals, not shared variables: a second driver is then an elaboration
  -- error rather than a silent last-write-wins.  Two dimensions in one
  -- object rather than a generate of five, because the checks below are
  -- pairwise ACROSS ports and reading five separate objects in a loop is
  -- what makes a pairwise check quietly become a per-port one.
  type mat_t is array (0 to NS_MAX-1, 0 to A_NPORTS-1) of integer;
  signal a_first : mat_t := (others => (others => -1));
  signal a_next  : mat_t := (others => (others => -1));
  signal a_beats : mat_t := (others => (others => 0));
  signal a_burst : mat_t := (others => (others => 0));

  signal n_ar_p2   : natural := 0;   -- ARs seen in phase 2.  Must stay 0.
  signal n_gap     : natural := 0;   -- P6 violations
  signal n_notincr : natural := 0;   -- P7: burst type
  signal n_longb   : natural := 0;   -- P7: arlen+1 > A_MAXB

  signal fail : natural := 0;
  signal done_p1, done_p2 : boolean := false;

begin

  clk <= not clk after 5 ns when running else '0';

  cycc : process(clk) is
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      assert cyc < MAXCYC
        report "tb_a_wbase: FAIL, the run exceeded " & integer'image(MAXCYC)
             & " cycles" severity failure;
    end if;
  end process;

  dut : entity work.llama_top
    generic map(
      SHAPE => SHAPE, LANES => LANES, MANT_W => MANT_W, EXP_W => EXP_W,
      REGMAX => REGMAX, STEP_W => STEP_W,
      WDOG_LIMIT => 200000, STRICT => true,
      A_BEHAV => false, B_BEHAV => true,
      A_MEM_BASE => A_MEM_BASE, A_JOB_STRIDE => A_JOB_STRIDE,
      A_SUB_BYTES => A_SUB_BYTES,
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
  -- THE AXI READ SLAVES.  One burst in flight, INCR only.  The DATA is a
  -- constant: this bench has no opinion about values and says so, rather
  -- than shipping a synthetic image whose only role would be to look busy.
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
            aw    <= unsigned(m_araddr((p+1)*32-1 downto p*32));
            beats <= to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
            act   <= '1';
          end if;
        else
          if m_rvalid(p) = '0' or m_rready(p) = '1' then
            if beats > 0 then
              -- A scale lane word must be a legal uint15 or `matvec_core`
              -- refuses it; a weight lane takes any nibble.  Constant on
              -- purpose -- see the header note about values.
              if p = A_NPORTS-1 then
                for l in 0 to 7 loop
                  m_rdata(p*128 + l*16 + 15 downto p*128 + l*16)
                    <= std_logic_vector(to_unsigned(20000, 16));
                end loop;
              else
                m_rdata((p+1)*128-1 downto p*128)
                  <= (others => '0');
              end if;
              m_rvalid(p) <= '1';
              if beats = 1 then m_rlast(p) <= '1';
              else              m_rlast(p) <= '0'; end if;
              aw    <= aw + BEAT_B;
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
  -- THE MONITOR.  Every accepted address beat, tagged with the live step.
  -- `cur_st` follows `obs_step` at `obs_issue`, which is the one instant the
  -- live descriptor changes; sampling `obs_step` freely would tag a burst
  -- with the NEXT job's index -- defect class (a) in a testbench.
  -- ======================================================================
  stt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cur_st <= 0;
      elsif obs_issue = '1' then
        cur_st <= to_integer(obs_step);
      end if;
    end if;
  end process;

  mon : process(clk) is
    variable s, n, a, e : integer;
  begin
    if rising_edge(clk) then
      if rst = '0' then
        for p in 0 to A_NPORTS-1 loop
          if m_arvalid(p) = '1' and m_arready(p) = '1' then
            s := cur_st;
            a := to_integer(unsigned(m_araddr((p+1)*32-1 downto p*32)));
            n := to_integer(unsigned(m_arlen((p+1)*8-1 downto p*8))) + 1;
            e := a + n * BEAT_B;
            if phase = 2 then
              n_ar_p2 <= n_ar_p2 + 1;
            end if;
            -- P7
            if m_arburst((p+1)*2-1 downto p*2) /= "01" then
              n_notincr <= n_notincr + 1;
            end if;
            if n > A_MAXB then
              n_longb <= n_longb + 1;
            end if;
            -- P6: this burst must start exactly where the last one ended.
            if a_first(s, p) < 0 then
              a_first(s, p) <= a;
            elsif a /= a_next(s, p) then
              n_gap <= n_gap + 1;
              if VERBOSE then
                report "tb_a_wbase: step " & integer'image(s) & " port "
                     & integer'image(p) & " burst at "
                     & integer'image(a) & " but the previous ended at "
                     & integer'image(a_next(s, p)) severity note;
              end if;
            end if;
            a_next(s, p)  <= e;
            a_beats(s, p) <= a_beats(s, p) + n;
            a_burst(s, p) <= a_burst(s, p) + 1;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DESCRIPTOR MEMORY.  `d_rdata` is 'X' whenever `d_rvalid` is low, so
  -- a walker sampling on the wrong cycle poisons its shadow rather than
  -- being right by luck.  The table is selected by `phase`.
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
        if phase = 1 and a2 < NS_FIT*8 then
          d_rdata <= TBL_FIT(a2);
        elsif phase = 2 and a2 < NS_OVF*8 then
          d_rdata <= TBL_OVF(a2);
        else
          d_rdata <= (others => 'X');
        end if;
      else
        d_rvalid <= '0';
        d_rdata  <= (others => 'X');
      end if;
    end if;
  end process;

  rel_mask <= rel_fit(n_chk) when phase = 1 and n_chk < NS_FIT else
              rel_ovf(n_chk) when phase = 2 and n_chk < NS_OVF else
              (others => '0');

  chkcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or go = '1' then
        n_chk <= 0;
      elsif rst = '0' and obs_issue = '1' then
        n_chk <= n_chk + 1;
      end if;
    end if;
  end process;

  -- ======================================================================
  -- THE DRIVER AND THE CHECKS.
  -- ======================================================================
  drv : process is
    -- A VARIABLE, NOT A SIGNAL, AND THAT IS THE WHOLE REASON THIS COUNTER
    -- IS TRUSTWORTHY.  `chk` is called dozens of times with no wait between
    -- them; a signal assignment would leave the OLD value visible to every
    -- later call and the process would resolve them all to a single
    -- increment, so a bench with forty violations would report one.  That is
    -- a checker that passes for the wrong reason, in the checker itself.
    variable nfail : natural := 0;
    variable lo_i, hi_i, lo_j, hi_j : integer;
    variable wexp, sexp : natural;

    procedure preload is
    begin
      for i in 0 to HID-1 loop
        wait until rising_edge(clk);
        hw_we   <= '1';
        hw_reg  <= R_X;
        hw_addr <= i;
        hw_data <= to_signed(((i*37 + 11) mod 4001) - 2000, MANT_W);
      end loop;
      wait until rising_edge(clk);
      hw_we <= '0';
    end procedure;

    procedure chk(c : boolean; msg : string) is
    begin
      if not c then
        nfail := nfail + 1;
        report "tb_a_wbase: FAIL -- " & msg severity error;
      end if;
    end procedure;
  begin
    report "tb_a_wbase: sub-region capacity is "
         & integer'image(SUB_BEATS) & " weight beats and "
         & integer'image(SCL_BEATS) & " scale beats per job" severity note;

    -- ---------------------------------------------------------- PHASE 1
    phase   <= 1;
    tbl_len <= to_unsigned(NS_FIT, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    preload;

    wait until rising_edge(clk);
    go <= '1';
    wait until rising_edge(clk);
    go <= '0';

    while tok_done = '0' and err = '0' loop
      wait until rising_edge(clk);
    end loop;
    wait until rising_edge(clk);
    done_p1 <= true;

    chk(err = '0', "phase 1 raised err, code 0x"
        & integer'image(to_integer(unsigned(err_code)))
        & " at step " & integer'image(to_integer(err_step)));
    chk(to_integer(steps_done) = NS_FIT,
        "phase 1 steps_done " & integer'image(to_integer(steps_done))
        & " /= tbl_len " & integer'image(NS_FIT));
    chk(err_lost_beat = '0', "phase 1 lost a y beat");
    chk(err_gate_drop = '0', "phase 1 dropped a gated region write");

    tok_ack <= '1';
    wait until rising_edge(clk);
    tok_ack <= '0';

    -- ---- P7, once, over the whole stream
    chk(n_notincr = 0, "a weight port issued a burst that is not INCR ("
        & integer'image(n_notincr) & " of them)");
    chk(n_longb = 0, "a weight port issued arlen+1 > A_MAXB ("
        & integer'image(n_longb) & " of them)");
    -- ---- P6
    chk(n_gap = 0, "the address stream was not contiguous ("
        & integer'image(n_gap) & " gaps or repeats)");

    for s in 0 to 2 loop
      wexp := w_beats(F_ROWS(s), F_COLS(s));
      sexp := s_beats(F_ROWS(s), F_COLS(s));
      for p in 0 to A_NPORTS-1 loop
        -- ---- P5
        if p = A_NPORTS-1 then
          chk(a_beats(s, p) = sexp,
              "step " & integer'image(s) & " scale port issued "
              & integer'image(a_beats(s, p)) & " beats, expected "
              & integer'image(sexp));
        else
          chk(a_beats(s, p) = wexp,
              "step " & integer'image(s) & " port " & integer'image(p)
              & " issued " & integer'image(a_beats(s, p))
              & " beats, expected " & integer'image(wexp));
        end if;
        -- ---- P2
        chk(a_first(s, p) >= 0,
            "step " & integer'image(s) & " port " & integer'image(p)
            & " issued no address at all");
        if a_first(s, p) >= 0 then
          chk(a_first(s, p) mod 4096 = 0,
              "step " & integer'image(s) & " port " & integer'image(p)
              & " base " & integer'image(a_first(s, p))
              & " is not 4 KB aligned");
          -- ---- P1
          if p = A_NPORTS-1 then
            chk(a_next(s, p) - a_first(s, p) <= SCL_BEATS * BEAT_B,
                "step " & integer'image(s)
                & " scale port read past its sub-region: "
                & integer'image(a_next(s, p) - a_first(s, p))
                & " bytes from " & integer'image(a_first(s, p)));
          else
            chk(a_next(s, p) - a_first(s, p) <= A_SUB_BYTES,
                "step " & integer'image(s) & " port " & integer'image(p)
                & " read past its " & integer'image(A_SUB_BYTES)
                & "-byte sub-region: "
                & integer'image(a_next(s, p) - a_first(s, p))
                & " bytes from " & integer'image(a_first(s, p)));
          end if;
        end if;
      end loop;
    end loop;

    -- ---- P3 and P4 in one pass: every (step, port) extent against every
    -- other.  Written as one loop over pairs on purpose -- P3 is the
    -- same-step case and P4 the different-step case of ONE property, and
    -- splitting them is how the cross-step case gets quietly dropped.
    for s in 0 to 2 loop
      for p in 0 to A_NPORTS-1 loop
        if a_first(s, p) >= 0 then
          lo_i := a_first(s, p);
          hi_i := a_next(s, p);
          for t in 0 to 2 loop
            for q in 0 to A_NPORTS-1 loop
              if (t > s) or (t = s and q > p) then
                if a_first(t, q) >= 0 then
                  lo_j := a_first(t, q);
                  hi_j := a_next(t, q);
                  chk(hi_i <= lo_j or hi_j <= lo_i,
                      "extents overlap: step " & integer'image(s) & " port "
                      & integer'image(p) & " ["
                      & integer'image(lo_i) & "," & integer'image(hi_i)
                      & ") and step " & integer'image(t) & " port "
                      & integer'image(q) & " ["
                      & integer'image(lo_j) & "," & integer'image(hi_j) & ")");
                end if;
              end if;
            end loop;
          end loop;
        end if;
      end loop;
    end loop;

    -- ---------------------------------------------------------- PHASE 2
    -- P8.  The overflowing job must issue NOTHING and report ERR_UNIT.
    phase   <= 2;
    tbl_len <= to_unsigned(NS_OVF, STEP_W);
    rst <= '1';
    for i in 0 to 9 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    preload;

    wait until rising_edge(clk);
    go <= '1';
    wait until rising_edge(clk);
    go <= '0';

    while tok_done = '0' and err = '0' loop
      wait until rising_edge(clk);
    end loop;
    for i in 0 to 19 loop wait until rising_edge(clk); end loop;
    done_p2 <= true;

    chk(err = '1',
        "phase 2's job needs " & integer'image(w_beats(O_ROWS, O_COLS))
        & " weight beats per port against a capacity of "
        & integer'image(SUB_BEATS)
        & ", and llama_top ACCEPTED it.  It would have read the next "
        & "sub-region's bytes and reported success.");
    if err = '1' then
      chk(err_code = ERR_UNIT,
          "phase 2 refused with code 0x"
          & integer'image(to_integer(unsigned(err_code)))
          & ", expected ERR_UNIT 0x1");
      chk(to_integer(err_step) = 0,
          "phase 2 blamed step " & integer'image(to_integer(err_step))
          & ", expected 0");
    end if;
    chk(n_ar_p2 = 0,
        "phase 2 issued " & integer'image(n_ar_p2)
        & " address beats before refusing.  The refusal must happen BEFORE "
        & "the array consumes anything, not after.");

    -- ------------------------------------------------------------ verdict
    fail <= nfail;
    if nfail = 0 then
      report "tb_a_wbase: PASS -- P1..P8 hold: "
           & integer'image(3) & " fitting A jobs with contiguous, aligned, "
           & "pairwise-disjoint extents and exact beat counts, and one "
           & "over-capacity job refused with ERR_UNIT before its first "
           & "address beat" severity note;
    else
      report "tb_a_wbase: FAIL, " & integer'image(nfail)
           & " property violation(s)" severity failure;
    end if;

    running <= false;
    wait;
  end process;

end architecture;
