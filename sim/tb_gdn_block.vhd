-- Testbench for gdn_block, subsystem B's top level.
--
-- WHAT THIS CAN AND CANNOT CHECK.  Every unit inside gdn_block is already
-- bit-exact against a double-oracled C reference, individually.  What has
-- never been checked is the SEAMS, and every one of this week's four confirmed
-- defects lived in a seam, was numerically plausible, and was invisible to a
-- value comparison against a testbench that ran its producers maximally ahead.
-- So this testbench does not re-check arithmetic.  It checks the property that
-- would have caught all four:
--
--   THE BLOCK'S OUTPUT MUST BE BIT-IDENTICAL UNDER EVERY PRODUCER SKEW.
--
-- The y stream, the per-token y_exp, the final recurrent state and the final
-- state-exponent table are dumped to OUTFILE.  sim/run_gdn_block.sh runs the
-- same stimulus under a matrix of skews and diffs the dumps.  A latch that is
-- missing, a handshake that is not waited on, a port read across a span longer
-- than the producer holds it -- all of them are skew-dependent by definition,
-- and none of them is visible in any single run.
--
-- FIVE INDEPENDENT PRODUCERS, and the independence is the point.  The z gate,
-- the ssm_norm weight, the scalar group, the conv-weight exponent and the
-- exponent-store capture side each run from their own process with their own
-- skew generic.  gdn_emit_chain's testbench learned this the hard way: an
-- earlier version fed z and columns from ONE process, which coupled them, and
-- a COL_GAP sweep down to one column per cycle then reported ZERO refused
-- columns -- a clean, confident, meaningless result.
--
-- WHAT EACH SKEW GENERIC IS FOR, and what it broke when it was first turned on
-- is recorded in docs/debugging/2026-08-27_gdn-block-top-level.md:
--
--   Z_DELAY   cycles the z producer idles between heads.  0 makes it run
--             maximally ahead, which is exactly what masked defect B-2.  It
--             also probes the class-3 column path: a z producer slow enough
--             stalls the emit chain, col_ready falls, and gdn_recur_pipe --
--             which has no ready input -- LOSES columns rather than waiting.
--   W_MOVE    the ssm_norm producer scrambles w the cycle after w_taken.  A
--             block that reads w through rmsnorm_bf for all VAL_HEADS heads
--             without latching fails on every head but the first.
--   SC_MOVE   the scalar producer scrambles al/dt/a/b the cycle after
--             sc_taken.  gdn_scalar latches NOTHING at start (audit B-4) and
--             reads b_m/b_e at the very END of a ~30-state FSM, so an
--             unlatched top level fails here and only here.
--   CW_MOVE   the conv-weight exponent moves after cv_taken.  gdn_conv reads
--             cw_exp at S_FIN, hundreds of cycles after start (audit B-3b).
--   CAP_BUSY  the exponent store's capture side runs continuously against a
--             DIFFERENT layer while the block is working, so every rd_req has
--             a chance of colliding with a capture.  gdn_exp_capture drops
--             such a read with no acknowledgement of any kind (audit B-12);
--             a top level that pulses rd_req instead of holding it then
--             convolves with a stale (layer, segment)'s tap exponents.
--
-- THE STATE MEMORY IS REAL, NOT A STUB.  It is read AND written across the
-- run, and it carries between tokens, so the final contents are part of the
-- comparison.  A one-column misalignment in the write-back counters -- the
-- shape of defect B-1 -- shows up there and nowhere else.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_block is
  generic(
    -- Shapes.  Small by default: the block is six units deep and one token at
    -- the shipping shape is ~30,000 cycles, which is minutes of GHDL per skew
    -- point.  The seams do not care how many heads there are.
    KEY_HEADS   : positive := 2;
    VAL_HEADS   : positive := 4;
    DIM         : positive := 32;
    LAYERS      : positive := 2;
    CONV_LANES  : positive := 4;
    -- The column issue rate, and therefore the emit chain's deadline.  At
    -- DIM/RECUR_LANES = 8 a head arrives over 8*DIM cycles; at 4 it arrives
    -- twice as fast, which is the setting that stresses gdn_head_emit's
    -- reduce-versus-arrival race.
    RECUR_LANES : positive := 4;
    RECUR_SLOTS : positive := 16;
    L2_LANES    : positive := 4;
    SILU_LANES  : positive := 8;
    RMS_LANES   : positive := 4;

    TOKENS   : integer := 2;
    -- Extra idle cycles per state column, passed straight to the DUT.  This
    -- is the axis that sets the emit chain's per-head deadline.
    -- Idle cycles between conv tap group requests, passed to the DUT.  This
    -- is the axis that stresses the STRAIGHT-THROUGH silu path: it moves
    -- gdn_conv's internal phase boundaries, so the instant e_seg is published
    -- and the instant the first output beat arrives both shift relative to
    -- the block's own sequencing and to every other producer.
    CV_GAP    : natural := 0;
    ISSUE_GAP : natural := 0;
    -- Idle cycles per value head; lengthens the arrival period by exactly
    -- HEAD_GAP and so measures the emit chain deadline to one cycle.
    HEAD_GAP  : natural := 0;

    -- ---- the skew axes ---------------------------------------------------
    Z_DELAY  : integer := 0;
    W_MOVE   : boolean := false;
    SC_MOVE  : boolean := false;
    CW_MOVE  : boolean := false;
    CAP_BUSY : boolean := false;

    STRICT   : boolean := true;
    -- Microseconds between progress reports; 0 disables.  A run that produces
    -- no output is ambiguous between wedged and slow, and that ambiguity has
    -- cost real time on this project's testbenches more than once.
    HEARTBEAT_US : integer := 0;
    OUTFILE  : string  := "gdn_block_out.txt"
  );
end entity;

architecture sim of tb_gdn_block is

  constant KCONV  : integer := 4;
  constant QCH    : integer := KEY_HEADS*DIM;
  constant VCH    : integer := VAL_HEADS*DIM;
  constant NB_R   : integer := DIM/RECUR_LANES;
  constant NCOL   : integer := VAL_HEADS*DIM;
  constant NSTW   : integer := VAL_HEADS*DIM*NB_R;
  constant NY     : integer := TOKENS*VAL_HEADS*DIM;

  -- Deterministic stimulus.  A function of the index and NOTHING else, so
  -- that changing a skew generic cannot change a single input value.  That is
  -- the whole basis of the cross-skew comparison.
  function hsh(a, b : integer) return unsigned is
    variable x : unsigned(31 downto 0);
    variable t : unsigned(63 downto 0);
  begin
    t := to_unsigned(a mod 1048576, 32) * to_unsigned(1103515245, 32);
    x := t(31 downto 0) + to_unsigned((b mod 100000) * 12345, 32);
    x := x xor shift_right(x, 15);
    t := x * to_unsigned(668265261, 32);
    x := t(31 downto 0);
    x := x xor shift_right(x, 13);
    return x;
  end function;

  -- Mantissas are kept to +-2047 on purpose.  The conv accumulates K products
  -- of two int16s; at full scale that is a saturating segment and every
  -- comparison would then be a comparison of clamps rather than of arithmetic.
  function m12(a, b : integer) return signed is
  begin
    return to_signed(to_integer(hsh(a, b)(11 downto 0)) - 2048, 16);
  end function;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal blk_start : std_logic := '0';
  signal tk0       : std_logic := '1';
  signal busy      : std_logic;
  signal tok       : integer := 0;

  signal seq_rst   : std_logic := '0';
  -- The two capture sources are arbitrated on the way in rather than sharing
  -- a signal: two drivers on one signal elaborate in ghdl with no line number,
  -- which has cost real time on this project twice.
  signal dr_req, cb_req : std_logic := '0';
  signal dr_layer, cb_layer : integer := 0;
  signal dr_seg,   cb_seg   : integer := 0;
  signal dr_exp,   cb_exp   : signed(7 downto 0) := (others => '0');
  signal cap_req   : std_logic;
  -- These carry the DUT's own port subtypes: ghdl rejects a plain integer
  -- actual against a constrained integer port outright.
  signal cap_layer : integer range 0 to LAYERS-1;
  signal cap_seg   : integer range 0 to 2;
  signal cap_exp   : signed(7 downto 0);
  signal cap_ready : std_logic;

  signal cv_seg    : integer range 0 to 2;
  signal cv_ren    : std_logic;
  signal cv_grp    : integer range 0 to VCH/CONV_LANES-1;
  signal cv_x      : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0) := (others => '0');
  signal cv_w      : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0) := (others => '0');
  signal cv_cw_exp : signed(7 downto 0) := to_signed(12, 8);
  signal cv_taken  : std_logic;
  signal eseg_taken : std_logic;

  signal sc_head  : integer range 0 to VAL_HEADS-1;
  signal sc_al_m, sc_dt_m, sc_a_m, sc_b_m : signed(15 downto 0) := (others => '0');
  signal sc_al_e, sc_dt_e, sc_a_e, sc_b_e : signed(7 downto 0)  := (others => '0');
  signal sc_taken : std_logic;

  signal st_ren   : std_logic;
  signal st_rhead : integer range 0 to VAL_HEADS-1;
  signal st_rcol  : integer range 0 to DIM-1;
  signal st_rgrp  : integer range 0 to NB_R-1;
  signal st_rdata : std_logic_vector(RECUR_LANES*16-1 downto 0);
  signal st_wen   : std_logic;
  signal st_whead : integer range 0 to VAL_HEADS-1;
  signal st_wcol  : integer range 0 to DIM-1;
  signal st_wgrp  : integer range 0 to NB_R-1;
  signal st_wdata : std_logic_vector(RECUR_LANES*16-1 downto 0);

  signal se_rhead : integer range 0 to VAL_HEADS-1;
  signal se_rcol  : integer range 0 to DIM-1;
  signal se_rdata : signed(7 downto 0);
  signal se_wen   : std_logic;
  signal se_whead : integer range 0 to VAL_HEADS-1;
  signal se_wcol  : integer range 0 to DIM-1;
  signal se_wdata : signed(7 downto 0);

  signal w_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal w_exp  : integer := 12;
  signal w_taken : std_logic;
  signal z_mant : std_logic_vector(DIM*16-1 downto 0) := (others => '0');
  signal z_exp  : signed(7 downto 0) := to_signed(12, 8);
  signal z_valid : std_logic := '0';
  signal z_ready : std_logic;

  signal y_valid : std_logic;
  signal y_mant  : signed(15 downto 0);
  signal y_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal blk_done : std_logic;

  signal err_conv, err_g, err_se, y_sat : std_logic;
  signal dbg_col_ready, dbg_col_drop : std_logic;

  -- ---- memory models -----------------------------------------------------
  type stmem_t is array (0 to NSTW-1) of std_logic_vector(RECUR_LANES*16-1 downto 0);
  type semem_t is array (0 to NCOL-1) of signed(7 downto 0);
  -- Initialised in the declaration, NOT from the driver process: the memory
  -- process is the only driver of these, and a second one elaborates in ghdl
  -- with no line number at all.  A deliberately NON-zero start state, because
  -- an all-zero state hides every alignment fault in the write-back counters.
  function stmem_init return stmem_t is
    variable m : stmem_t;
  begin
    for i in 0 to NSTW-1 loop
      for k in 0 to RECUR_LANES-1 loop
        m(i)((k+1)*16-1 downto k*16) := std_logic_vector(m12(i, k+1));
      end loop;
    end loop;
    return m;
  end function;
  signal stmem : stmem_t := stmem_init;
  signal semem : semem_t := (others => to_signed(10, 8));
  signal st_rq : std_logic_vector(RECUR_LANES*16-1 downto 0) := (others => '0');

  -- ---- collected output --------------------------------------------------
  type yarr_t is array (0 to NY-1) of integer;
  type tarr_t is array (0 to TOKENS-1) of integer;
  signal y_got : yarr_t := (others => 0);
  signal y_idx : integer := 0;
  signal ye_got : tarr_t := (others => 0);
  signal yn_got : tarr_t := (others => 0);
  signal blk_got : integer := 0;
  signal all_done : boolean := false;

  -- registered conv tap address, so cv_x/cv_w land one cycle after cv_ren,
  -- which is the block's documented contract for that port.
  signal cvq_seg : integer := 0;
  signal cvq_grp : integer := 0;
  signal cvq_tok : integer := 0;

  -- THE CYCLE COUNT.  The whole reason the straight-through form exists is
  -- the schedule, so the block's cost per token is measured rather than
  -- argued.  Counted from the `start` edge to `busy` falling, which is
  -- exactly one layer's work for one token.
  signal cyc      : integer := 0;
  signal tok_cyc  : tarr_t := (others => 0);
  signal counting : boolean := false;

  signal w_dirty  : boolean := false;
  signal sc_dirty : boolean := false;
  signal sc_head_q : integer := 0;
  signal cw_dirty : boolean := false;
  signal cv_seg_q : integer range 0 to 2 := 0;

begin

  clk <= (not clk) after 0.5 ns when running else '0';

  cap_req   <= dr_req or cb_req;
  cap_layer <= dr_layer when dr_req = '1' else cb_layer;
  cap_seg   <= dr_seg   when dr_req = '1' else cb_seg;
  cap_exp   <= dr_exp   when dr_req = '1' else cb_exp;

  dut : entity work.gdn_block
    generic map ( KEY_HEADS => KEY_HEADS, VAL_HEADS => VAL_HEADS, DIM => DIM,
                  KCONV => KCONV, LAYERS => LAYERS,
                  CONV_LANES => CONV_LANES, RECUR_LANES => RECUR_LANES,
                  RECUR_SLOTS => RECUR_SLOTS, L2_LANES => L2_LANES,
                  SILU_LANES => SILU_LANES, RMS_LANES => RMS_LANES,
                  Q => 12, EPS => 1.0e-6, SP_Q => 18,
                  CV_GAP => CV_GAP,
                  ISSUE_GAP => ISSUE_GAP, HEAD_GAP => HEAD_GAP,
                  STRICT_PRODUCER => STRICT )
    port map ( clk => clk, rst => rst,
               start => blk_start, layer => 0, tk0 => tk0, busy => busy,
               seq_rst => seq_rst,
               cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
               cap_exp => cap_exp, cap_ready => cap_ready,
               cv_seg => cv_seg, cv_ren => cv_ren, cv_grp => cv_grp,
               cv_x => cv_x, cv_w => cv_w, cv_cw_exp => cv_cw_exp,
               cv_taken => cv_taken, eseg_taken => eseg_taken,
               sc_head => sc_head,
               sc_al_m => sc_al_m, sc_al_e => sc_al_e,
               sc_dt_m => sc_dt_m, sc_dt_e => sc_dt_e,
               sc_a_m => sc_a_m, sc_a_e => sc_a_e,
               sc_b_m => sc_b_m, sc_b_e => sc_b_e, sc_taken => sc_taken,
               st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,
               st_rgrp => st_rgrp, st_rdata => st_rdata,
               st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,
               st_wgrp => st_wgrp, st_wdata => st_wdata,
               se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,
               se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,
               se_wdata => se_wdata,
               w_mant => w_mant, w_exp => w_exp, w_taken => w_taken,
               z_mant => z_mant, z_exp => z_exp,
               z_valid => z_valid, z_ready => z_ready,
               y_valid => y_valid, y_mant => y_mant, y_last => y_last,
               y_exp => y_exp, done => blk_done,
               err_conv => err_conv, err_g => err_g, err_se => err_se,
               y_sat => y_sat,
               dbg_col_ready => dbg_col_ready, dbg_col_drop => dbg_col_drop );

  -- ======================= memory models ================================

  st_rdata <= st_rq;

  stmem_p : process(clk)
    variable a : integer;
  begin
    if rising_edge(clk) then
      if st_wen = '1' then
        a := st_whead*DIM*NB_R + st_wcol*NB_R + st_wgrp;
        stmem(a) <= st_wdata;
      end if;
      if st_ren = '1' then
        a := st_rhead*DIM*NB_R + st_rcol*NB_R + st_rgrp;
        st_rq <= stmem(a);
      end if;
    end if;
  end process;

  -- Combinational read, which is what gdn_block's port contract says.  The
  -- table is VAL_HEADS*DIM bytes; at 9B that is 4 KiB of distributed RAM.
  se_rdata <= semem(se_rhead*DIM + se_rcol);

  semem_p : process(clk)
  begin
    if rising_edge(clk) then
      if se_wen = '1' then
        semem(se_whead*DIM + se_wcol) <= se_wdata;
      end if;
    end if;
  end process;

  -- ======================= producer 1: conv taps ========================
  -- Registered address, combinational data: a plain BRAM.  The values are a
  -- function of (token, segment, group, tap, lane) only.
  cvaddr_p : process(clk)
  begin
    if rising_edge(clk) then
      cvq_seg <= cv_seg;
      cvq_grp <= cv_grp;
      cvq_tok <= tok;
    end if;
  end process;

  cvdata_p : process(cvq_seg, cvq_grp, cvq_tok)
    variable xv, wv : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    variable b : integer;
  begin
    for t in 0 to KCONV-1 loop
      for ln in 0 to CONV_LANES-1 loop
        b := (t*CONV_LANES + ln)*16;
        xv(b+15 downto b) := std_logic_vector(
          m12(cvq_tok*7919 + cvq_seg*104729 + cvq_grp*31, t*17 + ln));
        -- The conv weights are per (segment, channel, tap) and do NOT depend
        -- on the token; they are model weights.
        wv(b+15 downto b) := std_logic_vector(
          m12(cvq_seg*65537 + cvq_grp*13, t*101 + ln + 5));
      end loop;
    end loop;
    cv_x <= xv;
    cv_w <= wv;
  end process;

  -- The conv-weight exponent.  CW_MOVE scrambles it the cycle after cv_taken,
  -- which gdn_conv would otherwise read at S_FIN (audit B-3b).
  cw_p : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cw_dirty <= false;
      else
        cv_seg_q <= cv_seg;
        if cv_taken = '1' then
          cw_dirty <= true;
        elsif cv_seg /= cv_seg_q or busy = '0' then
          cw_dirty <= false;
        end if;
      end if;
    end if;
  end process;
  -- Per SEGMENT, not constant: a constant makes gdn_conv's cw_exp latch
  -- untestable and hides whether cv_seg is published before the value is
  -- sampled.  The producer reacts to cv_seg one cycle late, like a register
  -- file, which is exactly what the block's port contract must tolerate.
  cv_cw_exp <= to_signed(-99, 8) when (CW_MOVE and cw_dirty)
               else to_signed(12 + cv_seg_q, 8);

  -- ======================= producer 2: scalar path ======================
  -- Combinational on sc_head.  With SC_MOVE the values are scrambled from the
  -- cycle after sc_taken until the block asks for the next head, which is the
  -- exact window gdn_scalar reads b_m/b_e in (audit B-4: it latches nothing at
  -- start and reads b at the very end of a ~30-state FSM).
  sc_p : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sc_dirty <= false; sc_head_q <= 0;
      else
        sc_head_q <= sc_head;
        if sc_taken = '1' then
          sc_dirty <= true;
        elsif sc_head /= sc_head_q then
          sc_dirty <= false;
        end if;
      end if;
    end if;
  end process;

  -- A REGISTERED source: the index is sc_head_q, one cycle behind the port,
  -- which is what a register file or a BRAM gives you.  A combinational model
  -- here would let the block get away with sampling on the very next edge.
  scdrv : process(sc_head_q, sc_dirty, tok)
    variable ix : integer;
  begin
    if SC_MOVE and sc_dirty then ix := 987654; else ix := tok*64 + sc_head_q; end if;
    sc_al_m <= m12(ix*31 + 1, 2);
    sc_dt_m <= m12(ix*31 + 2, 3);
    -- 1.1(b): ssm_a is -exp(A_log), so a is always <= 0 and the decay never
    -- amplifies.  Feeding a positive one would exercise a case the model
    -- cannot produce.
    sc_a_m  <= -abs(m12(ix*31 + 3, 4));
    sc_b_m  <= m12(ix*31 + 4, 5);
    sc_al_e <= to_signed(12, 8);
    sc_dt_e <= to_signed(12, 8);
    sc_a_e  <= to_signed(12, 8);
    sc_b_e  <= to_signed(12, 8);
  end process;

  -- ======================= producer 3: the z gate =======================
  zgen : process
    variable h : integer := 0;
  begin
    z_valid <= '0';
    wait until rst = '0';
    while h < TOKENS*VAL_HEADS loop
      for i in 1 to Z_DELAY loop
        wait until rising_edge(clk);
      end loop;
      for j in 0 to DIM-1 loop
        z_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(h*1013 + 3, j));
      end loop;
      z_exp   <= to_signed(12, 8);
      z_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when z_ready = '1';
      end loop;
      z_valid <= '0';
      h := h + 1;
    end loop;
    wait;
  end process;

  -- ======================= producer 4: ssm_norm weight ==================
  wgen : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        w_dirty <= false;
      else
        if w_taken = '1' then
          w_dirty <= true;
        elsif busy = '0' then
          w_dirty <= false;
        end if;
      end if;
    end if;
  end process;

  wdrv : process(w_dirty)
  begin
    for j in 0 to DIM-1 loop
      if W_MOVE and w_dirty then
        w_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(999999, j));
      else
        w_mant((j+1)*16-1 downto j*16) <= std_logic_vector(m12(4242, j));
      end if;
    end loop;
  end process;

  -- ======================= producer 5: the capture side =================
  -- Free-running captures against a DIFFERENT layer, so the block's own
  -- (layer 0) tap exponents never move; only the collisions do.
  capbusy : process
  begin
    if not CAP_BUSY then wait; end if;
    wait until rst = '0';
    loop
      for i in 1 to 37 loop wait until rising_edge(clk); end loop;
      exit when all_done;
      if dr_req = '0' then
        cb_layer <= 1;
        cb_seg   <= 1;
        cb_exp   <= to_signed(9, 8);
        cb_req   <= '1';
        wait until rising_edge(clk);
        cb_req   <= '0';
      end if;
    end loop;
    wait;
  end process;

  cyccnt : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cyc <= 0; counting <= false;
      else
        if blk_start = '1' then
          cyc <= 0; counting <= true;
        elsif counting then
          if busy = '0' and cyc > 1 then
            counting <= false;
            tok_cyc(tok) <= cyc;
          else
            cyc <= cyc + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ======================= collector ====================================
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert blk_got < TOKENS and y_idx < NY
            report "tb_gdn_block: more output than the run expects"
            severity failure;
          y_got(y_idx) <= to_integer(y_mant);
          y_idx <= y_idx + 1;
          ye_got(blk_got) <= to_integer(y_exp);
          yn_got(blk_got) <= yn_got(blk_got) + 1;
        end if;
        if blk_done = '1' then
          blk_got <= blk_got + 1;
        end if;
      end if;
    end if;
  end process;

  heartbeat : process
  begin
    if HEARTBEAT_US = 0 then wait; end if;
    loop
      wait for HEARTBEAT_US * 1 us;
      exit when all_done;
      report "tb_gdn_block: alive, token " & integer'image(tok)
           & " y " & integer'image(y_idx) & " of " & integer'image(NY);
    end loop;
    wait;
  end process;

  -- ======================= the driver ===================================
  drive : process
    variable l : line;
    file fh : text;
  begin
    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    -- Sequence boundary: clear the tap-validity counters.  gdn_exp_capture
    -- requires the unit to be idle for this, and says so with an assertion.
    seq_rst <= '1';
    wait until rising_edge(clk);
    seq_rst <= '0';
    wait until rising_edge(clk);

    for t in 0 to TOKENS-1 loop
      tok <= t;
      if t = 0 then tk0 <= '1'; else tk0 <= '0'; end if;

      -- One capture per segment per token: that is what advances the conv
      -- state FIFO and what makes tvalid grow 0001 -> 0011 -> 0111 -> 1111.
      for s in 0 to 2 loop
        loop
          wait until rising_edge(clk);
          exit when cap_ready = '1' and cap_req = '0';
        end loop;
        dr_layer <= 0;
        dr_seg   <= s;
        dr_exp   <= to_signed(8 + (t + s) mod 3, 8);
        dr_req   <= '1';
        wait until rising_edge(clk);
        dr_req   <= '0';
        loop
          wait until rising_edge(clk);
          exit when cap_ready = '1';
        end loop;
      end loop;

      blk_start <= '1';
      wait until rising_edge(clk);
      blk_start <= '0';
      wait until rising_edge(clk);
      loop
        wait until rising_edge(clk);
        exit when busy = '0';
      end loop;
    end loop;

    for i in 1 to 16 loop wait until rising_edge(clk); end loop;
    all_done <= true;

    -- ---- checks ---------------------------------------------------------
    assert y_idx = NY
      report "tb_gdn_block: expected " & integer'image(NY)
           & " output elements, got " & integer'image(y_idx)
      severity failure;
    for t in 0 to TOKENS-1 loop
      assert yn_got(t) = VAL_HEADS*DIM
        report "tb_gdn_block: token " & integer'image(t) & " emitted "
             & integer'image(yn_got(t)) & " elements, expected "
             & integer'image(VAL_HEADS*DIM)
        severity failure;
    end loop;
    assert dbg_col_drop = '0'
      report "tb_gdn_block: gdn_recur_pipe offered a column that "
           & "gdn_emit_chain refused.  That column is LOST, not delayed."
      severity failure;
    for t in 0 to TOKENS-1 loop
      report "tb_gdn_block: CYCLES token " & integer'image(t) & " = "
           & integer'image(tok_cyc(t));
    end loop;
    report "tb_gdn_block: err_conv=" & std_logic'image(err_conv)
         & " err_g=" & std_logic'image(err_g)
         & " err_se=" & std_logic'image(err_se)
         & " y_sat=" & std_logic'image(y_sat);

    -- ---- the dump that the cross-skew diff compares ---------------------
    file_open(fh, OUTFILE, write_mode);
    for t in 0 to TOKENS-1 loop
      write(l, string'("blk ") & integer'image(t)
             & " n " & integer'image(yn_got(t))
             & " yexp " & integer'image(ye_got(t)));
      writeline(fh, l);
    end loop;
    for i in 0 to NY-1 loop
      write(l, string'("y ") & integer'image(i) & " " & integer'image(y_got(i)));
      writeline(fh, l);
    end loop;
    for i in 0 to NSTW-1 loop
      for k in 0 to RECUR_LANES-1 loop
        write(l, string'("s ") & integer'image(i) & " " & integer'image(k)
               & " " & integer'image(to_integer(signed(stmem(i)((k+1)*16-1 downto k*16)))));
        writeline(fh, l);
      end loop;
    end loop;
    for i in 0 to NCOL-1 loop
      write(l, string'("e ") & integer'image(i) & " "
             & integer'image(to_integer(semem(i))));
      writeline(fh, l);
    end loop;
    file_close(fh);

    report "tb_gdn_block: PASS, " & integer'image(NY) & " elements, dump in "
         & OUTFILE;
    running <= false;
    wait;
  end process;

end architecture;
