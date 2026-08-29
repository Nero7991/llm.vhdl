-- sim/tb_gdn_block_vec.vhd
--
-- THE VALUE ORACLE FOR SUBSYSTEM B'S TOP LEVEL.
--
-- sim/tb_gdn_block.vhd checks that the block's output is BIT-IDENTICAL under
-- every producer skew, and says in its own header that it "does not re-check
-- arithmetic".  That property is the right one for the four seam defects it
-- was written for, and it is blind to every wiring error: a block that feeds
-- value head h from the wrong key head, that swaps the q and k segments into
-- the two L2 paths, that pairs a conv tap with the wrong slot exponent, or
-- that gates before the norm instead of after, produces a dump that is
-- bit-identical across every skew and wrong in all of them.
--
-- This bench closes that hole.  It drives the SAME DUT from stimulus written
-- by ref/gdn_block_vec.c and asserts, bit for bit:
--
--   * the whole y stream, TOKENS x VAL_HEADS x DIM mantissas
--   * the per-token y_exp
--   * the final recurrent state, VAL_HEADS x DIM x DIM int16
--   * the final state-exponent table, VAL_HEADS x DIM int8
--   * all four status flags -- err_conv, err_g, err_se, y_sat
--
-- The state is checked because it is the block's OTHER output: a token whose
-- y is right and whose state is wrong is a token that has corrupted every
-- token after it, and nothing downstream would say so.
--
-- THE STIMULUS COMES FROM THE FILE, NOT FROM A FUNCTION OF THE INDEX.  A
-- bench that regenerated the stimulus in VHDL would have two sources of truth
-- for the inputs, and a divergence between them would read as an arithmetic
-- failure.  ref/attn_block_vec.c states the same rule for subsystem C.
--
-- THE PRODUCER CONTRACTS ARE THE ONES tb_gdn_block ESTABLISHED, and they are
-- reproduced rather than simplified: the conv tap port is a registered-address
-- BRAM, the scalar port is a REGISTERED source one cycle behind sc_head (a
-- combinational model lets the block get away with sampling on the very next
-- edge, which is the defect P_SCRD exists for), the z gate is a separate
-- process with its own delay, and the exponent store's capture side is driven
-- with the rd_req/rd_ack handshake held.  The skew knobs are present and
-- default OFF: this bench's job is the VALUES, and sim/run_gdn_block.sh
-- remains the place the skew matrix is swept.  Turning one on here checks the
-- values under skew as well, which is strictly more than either bench alone.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;

entity tb_gdn_block_vec is
  generic(
    -- Shapes.  These MUST match the arguments ref/gdn_block_vec.c was run
    -- with; the vector file carries a shape header and this bench asserts it
    -- against these generics, so a mismatch is loud rather than a wrong
    -- answer.  Small on purpose: the seams and the wiring do not care how
    -- many heads there are, and one token at the shipping shape is ~30,000
    -- cycles per skew point.
    --
    -- VAL_HEADS = 2*KEY_HEADS is LOAD BEARING and is not a size choice.  At
    -- VAL_HEADS = KEY_HEADS every mapping from value head to key head is the
    -- identity and the ggml_repeat question -- h mod KEY_HEADS against
    -- h / (VAL_HEADS/KEY_HEADS) -- cannot be asked at all.  With 4 value
    -- heads and 2 key heads the two answers differ on heads 1 and 2.
    KEY_HEADS   : positive := 2;
    VAL_HEADS   : positive := 4;
    DIM         : positive := 32;
    LAYERS      : positive := 2;
    CONV_LANES  : positive := 4;
    RECUR_LANES : positive := 4;
    RECUR_SLOTS : positive := 16;
    L2_LANES    : positive := 4;
    SILU_LANES  : positive := 8;
    RMS_LANES   : positive := 4;
    TOKENS      : integer  := 2;

    CV_GAP    : natural := 0;
    ISSUE_GAP : natural := 0;
    HEAD_GAP  : natural := 0;

    -- The skew axes, defaulting OFF.  See the header: the value check is what
    -- this bench is for, and sim/run_gdn_block.sh sweeps the skews.
    Z_DELAY  : integer := 0;
    W_MOVE   : boolean := false;
    SC_MOVE  : boolean := false;
    CW_MOVE  : boolean := false;
    CAP_BUSY : boolean := false;

    STRICT   : boolean := true;
    HEARTBEAT_US : integer := 0;

    -- WHICH KEY HEAD FEEDS VALUE HEAD h.  This is an OPEN DEFECT, not a
    -- configuration choice, and the generic exists so that the rest of the
    -- composition can still be gated while it is open.
    --
    --   false  hk = h mod KEY_HEADS          -- what the MODEL does
    --   true   hk = h / (VAL_HEADS/KEY_HEADS) -- what rtl/gdn_block.vhd does
    --
    -- ref/gdn_block_vec.c defaults to the model; this generic must agree with
    -- the kmap flag in the vector file's header, which is asserted below, so
    -- the two cannot silently disagree.  Set it back to false and re-point
    -- sim/regress.sh's tb_vector_args row at "mod" when defect B-BLK-1 is
    -- fixed: docs/debugging/2026-08-29_gdn-block-oracle.md.
    KMAP_DIV : boolean := false;

    VECFILE  : string  := "gdn_block_vec.txt"
  );
end entity;

architecture sim of tb_gdn_block_vec is

  constant KCONV  : integer := 4;
  constant QCH    : integer := KEY_HEADS*DIM;
  constant VCH    : integer := VAL_HEADS*DIM;
  constant CHTOT  : integer := 2*QCH + VCH;
  constant NB_R   : integer := DIM/RECUR_LANES;
  constant NCOL   : integer := VAL_HEADS*DIM;
  constant NSTW   : integer := VAL_HEADS*DIM*NB_R;
  constant NSTE   : integer := VAL_HEADS*DIM*DIM;
  constant NY     : integer := TOKENS*VAL_HEADS*DIM;

  type int_arr is array (natural range <>) of integer;

  -- ---- the vector tables.  Shared variables because five independent
  -- producer processes index them at addresses the DUT chooses; none of them
  -- is ever written after the loader completes, so there is no ordering
  -- hazard to protect against.  -frelaxed is passed by sim/regress.sh for
  -- exactly this (tb_rmsnorm_bf needs it too).
  shared variable v_cwe  : int_arr(0 to 2)                   := (others => 0);
  shared variable v_wm   : int_arr(0 to DIM-1)               := (others => 0);
  shared variable v_wtap : int_arr(0 to CHTOT*KCONV-1)       := (others => 0);
  shared variable v_s0   : int_arr(0 to NSTE-1)              := (others => 0);
  shared variable v_se0  : int_arr(0 to NCOL-1)              := (others => 0);
  shared variable v_cap  : int_arr(0 to TOKENS*3-1)          := (others => 0);
  shared variable v_xtap : int_arr(0 to TOKENS*CHTOT*KCONV-1):= (others => 0);
  shared variable v_sc   : int_arr(0 to TOKENS*VAL_HEADS*8-1):= (others => 0);
  shared variable v_z    : int_arr(0 to TOKENS*VAL_HEADS*DIM-1) := (others => 0);
  shared variable v_ye   : int_arr(0 to TOKENS-1)            := (others => 0);
  shared variable v_y    : int_arr(0 to NY-1)                := (others => 0);
  shared variable v_s1   : int_arr(0 to NSTE-1)              := (others => 0);
  shared variable v_se1  : int_arr(0 to NCOL-1)              := (others => 0);
  shared variable v_flag : int_arr(0 to 3)                   := (others => 0);
  shared variable v_we   : integer := 12;
  shared variable v_ze   : integer := 12;

  signal loaded : boolean := false;

  -- Whitespace-tolerant integer reader.  Lifted from sim/tb_gdn_emit_chain.vhd
  -- for the same reason it exists there: VHDL's own integer read stops on the
  -- first non-digit and gives no diagnostic.
  procedure rdi(variable ln : inout line; variable v : out integer) is
    variable c    : character;
    variable good : boolean;
    variable neg  : boolean := false;
    variable acc  : integer := 0;
    variable started : boolean := false;
  begin
    loop
      read(ln, c, good);
      exit when not good;
      if c = ' ' or c = HT then
        if started then exit; end if;
      elsif c = '-' then
        neg := true; started := true;
      elsif c >= '0' and c <= '9' then
        started := true;
        acc := acc * 10 + character'pos(c) - character'pos('0');
      else
        exit;
      end if;
    end loop;
    assert started
      report "tb_gdn_block_vec: expected a number in " & VECFILE
      severity failure;
    if neg then v := -acc; else v := acc; end if;
  end procedure;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal running : boolean := true;

  signal blk_start : std_logic := '0';
  signal tk0       : std_logic := '1';
  signal busy      : std_logic;
  signal tok       : integer := 0;

  signal seq_rst   : std_logic := '0';
  signal dr_req, cb_req : std_logic := '0';
  signal dr_layer, cb_layer : integer := 0;
  signal dr_seg,   cb_seg   : integer := 0;
  signal dr_exp,   cb_exp   : signed(7 downto 0) := (others => '0');
  signal cap_req   : std_logic;
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

  type stmem_t is array (0 to NSTW-1) of std_logic_vector(RECUR_LANES*16-1 downto 0);
  type semem_t is array (0 to NCOL-1) of signed(7 downto 0);
  signal stmem : stmem_t := (others => (others => '0'));
  signal semem : semem_t := (others => (others => '0'));
  signal st_rq : std_logic_vector(RECUR_LANES*16-1 downto 0) := (others => '0');

  type yarr_t is array (0 to NY-1) of integer;
  type tarr_t is array (0 to TOKENS-1) of integer;
  signal y_got : yarr_t := (others => 0);
  signal y_idx : integer := 0;
  signal ye_got : tarr_t := (others => 0);
  signal yn_got : tarr_t := (others => 0);
  signal blk_got : integer := 0;
  signal all_done : boolean := false;

  signal cvq_seg : integer := 0;
  signal cvq_grp : integer := 0;
  signal cvq_tok : integer := 0;

  signal w_dirty  : boolean := false;
  signal sc_dirty : boolean := false;
  signal sc_head_q : integer := 0;
  signal cw_dirty : boolean := false;
  signal cv_seg_q : integer range 0 to 2 := 0;

  -- channel base of segment s in the flattened conv arrays.  Segment order is
  -- q, k, v and channels are head-major within a segment: spec 1.1(h).
  function seg_base(s : integer) return integer is
  begin
    if s = 0 then return 0;
    elsif s = 1 then return QCH;
    else return 2*QCH; end if;
  end function;

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

  -- ======================= the loader ===================================
  -- Runs once, at time 0, before rst is released.  Every other process waits
  -- on `loaded`.
  loader : process
    file     vf : text;
    variable l  : line;
    variable ok : file_open_status;
    variable ti : integer;
    variable h_kh, h_vh, h_d, h_k, h_lay, h_tok, h_kmap : integer;
  begin
    file_open(ok, vf, VECFILE, read_mode);
    assert ok = open_ok
      report "tb_gdn_block_vec: cannot open " & VECFILE severity failure;

    readline(vf, l);
    rdi(l, h_kh); rdi(l, h_vh); rdi(l, h_d); rdi(l, h_k);
    rdi(l, h_lay); rdi(l, h_tok); rdi(l, ti); v_we := ti;
    rdi(l, ti); v_ze := ti;
    rdi(l, h_kmap);
    -- The shape header is asserted against the generics rather than trusted.
    -- A vector file generated at a different shape would otherwise be read
    -- with the wrong strides and produce a confident wrong answer.
    assert h_kh = KEY_HEADS and h_vh = VAL_HEADS and h_d = DIM
       and h_k = KCONV and h_tok = TOKENS
      report "tb_gdn_block_vec: " & VECFILE & " shape "
           & integer'image(h_kh) & "x" & integer'image(h_vh) & "x"
           & integer'image(h_d) & " k" & integer'image(h_k)
           & " tok" & integer'image(h_tok)
           & " does not match this testbench's generics"
      severity failure;
    assert h_lay <= LAYERS
      report "tb_gdn_block_vec: vector file wants more layers than the DUT has"
      severity failure;
    assert (h_kmap /= 0) = KMAP_DIV
      report "tb_gdn_block_vec: " & VECFILE & " was generated with kmap="
           & integer'image(h_kmap) & " and this testbench has KMAP_DIV="
           & boolean'image(KMAP_DIV) & ".  Regenerate the vectors or fix the "
           & "generic; a mismatch here is a wrong answer, not a wrong shape."
      severity failure;
    if KMAP_DIV then
      report "tb_gdn_block_vec: RUNNING AGAINST OPEN DEFECT B-BLK-1.  The "
           & "oracle has been told to use rtl/gdn_block.vhd's key-head "
           & "mapping hk = h/(VAL_HEADS/KEY_HEADS) instead of the model's "
           & "hk = h mod KEY_HEADS, so that every OTHER stage of the "
           & "composition is still gated.  Run with KMAP_DIV=false and "
           & "kmap=mod vectors to reproduce the defect.  See "
           & "docs/debugging/2026-08-29_gdn-block-oracle.md."
        severity note;
    end if;

    readline(vf, l); for s in 0 to 2 loop rdi(l, ti); v_cwe(s) := ti; end loop;
    readline(vf, l); for i in 0 to DIM-1 loop rdi(l, ti); v_wm(i) := ti; end loop;
    readline(vf, l);
    for i in 0 to CHTOT*KCONV-1 loop rdi(l, ti); v_wtap(i) := ti; end loop;
    readline(vf, l);
    for i in 0 to NSTE-1 loop rdi(l, ti); v_s0(i) := ti; end loop;
    readline(vf, l);
    for i in 0 to NCOL-1 loop rdi(l, ti); v_se0(i) := ti; end loop;

    for t in 0 to TOKENS-1 loop
      readline(vf, l);
      for s in 0 to 2 loop rdi(l, ti); v_cap(t*3 + s) := ti; end loop;
      readline(vf, l);
      for i in 0 to CHTOT*KCONV-1 loop
        rdi(l, ti); v_xtap(t*CHTOT*KCONV + i) := ti;
      end loop;
      readline(vf, l);
      for i in 0 to VAL_HEADS*8-1 loop
        rdi(l, ti); v_sc(t*VAL_HEADS*8 + i) := ti;
      end loop;
      readline(vf, l);
      for i in 0 to VAL_HEADS*DIM-1 loop
        rdi(l, ti); v_z(t*VAL_HEADS*DIM + i) := ti;
      end loop;
      readline(vf, l); rdi(l, ti); v_ye(t) := ti;
      readline(vf, l);
      for i in 0 to VAL_HEADS*DIM-1 loop
        rdi(l, ti); v_y(t*VAL_HEADS*DIM + i) := ti;
      end loop;
    end loop;

    readline(vf, l);
    for i in 0 to NSTE-1 loop rdi(l, ti); v_s1(i) := ti; end loop;
    readline(vf, l);
    for i in 0 to NCOL-1 loop rdi(l, ti); v_se1(i) := ti; end loop;
    readline(vf, l);
    for i in 0 to 3 loop rdi(l, ti); v_flag(i) := ti; end loop;
    file_close(vf);

    loaded <= true;
    wait;
  end process;

  -- ======================= memory models ================================
  -- Both carry the vector file's INITIAL contents and are compared against
  -- its FINAL contents at the end of the run.  A one-column misalignment in
  -- the write-back counters -- the shape of defect B-1 -- shows up here and
  -- nowhere else.

  st_rdata <= st_rq;

  stmem_p : process
    variable a : integer;
    variable wd : std_logic_vector(RECUR_LANES*16-1 downto 0);
  begin
    wait until loaded;
    -- element i of column (h, j) lives at group i/RECUR_LANES, lane
    -- i mod RECUR_LANES: the flat order the port names imply.
    for h in 0 to VAL_HEADS-1 loop
      for j in 0 to DIM-1 loop
        for g in 0 to NB_R-1 loop
          for k in 0 to RECUR_LANES-1 loop
            wd((k+1)*16-1 downto k*16) := std_logic_vector(to_signed(
              v_s0((h*DIM + j)*DIM + g*RECUR_LANES + k), 16));
          end loop;
          stmem(h*DIM*NB_R + j*NB_R + g) <= wd;
        end loop;
      end loop;
    end loop;
    loop
      wait until rising_edge(clk);
      if st_wen = '1' then
        a := st_whead*DIM*NB_R + st_wcol*NB_R + st_wgrp;
        stmem(a) <= st_wdata;
      end if;
      if st_ren = '1' then
        a := st_rhead*DIM*NB_R + st_rcol*NB_R + st_rgrp;
        st_rq <= stmem(a);
      end if;
    end loop;
  end process;

  se_rdata <= semem(se_rhead*DIM + se_rcol);

  semem_p : process
  begin
    wait until loaded;
    for i in 0 to NCOL-1 loop
      semem(i) <= to_signed(v_se0(i), 8);
    end loop;
    loop
      wait until rising_edge(clk);
      if se_wen = '1' then
        semem(se_whead*DIM + se_wcol) <= se_wdata;
      end if;
    end loop;
  end process;

  -- ======================= producer 1: conv taps ========================
  -- Registered address, combinational data: a plain BRAM, exactly the
  -- contract gdn_block's port comment states.
  cvaddr_p : process(clk)
  begin
    if rising_edge(clk) then
      cvq_seg <= cv_seg;
      cvq_grp <= cv_grp;
      cvq_tok <= tok;
    end if;
  end process;

  cvdata_p : process(cvq_seg, cvq_grp, cvq_tok, loaded)
    variable xv, wv : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
    variable b, ch  : integer;
  begin
    if loaded then
      for t in 0 to KCONV-1 loop
        for ln in 0 to CONV_LANES-1 loop
          b  := (t*CONV_LANES + ln)*16;
          ch := seg_base(cvq_seg) + cvq_grp*CONV_LANES + ln;
          xv(b+15 downto b) := std_logic_vector(to_signed(
            v_xtap(cvq_tok*CHTOT*KCONV + ch*KCONV + t), 16));
          wv(b+15 downto b) := std_logic_vector(to_signed(
            v_wtap(ch*KCONV + t), 16));
        end loop;
      end loop;
      cv_x <= xv;
      cv_w <= wv;
    end if;
  end process;

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

  -- Per SEGMENT, from the vector file, and reacting to cv_seg one cycle late
  -- like a register file.  A constant would make gdn_conv's cw_exp latch
  -- untestable and hide whether cv_seg is published before the value is
  -- sampled.
  cv_cw_exp <= to_signed(-99, 8) when (CW_MOVE and cw_dirty)
               else to_signed(v_cwe(cv_seg_q), 8) when loaded
               else to_signed(12, 8);

  -- ======================= producer 2: scalar path ======================
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

  -- A REGISTERED source: the index is sc_head_q, one cycle behind the port.
  scdrv : process(sc_head_q, sc_dirty, tok, loaded)
    variable base : integer;
  begin
    if loaded then
      if SC_MOVE and sc_dirty then
        sc_al_m <= to_signed(-31337, 16); sc_dt_m <= to_signed(31337, 16);
        sc_a_m  <= to_signed(-31337, 16); sc_b_m  <= to_signed(31337, 16);
        sc_al_e <= to_signed(-7, 8); sc_dt_e <= to_signed(-7, 8);
        sc_a_e  <= to_signed(-7, 8); sc_b_e  <= to_signed(-7, 8);
      else
        base := (tok*VAL_HEADS + sc_head_q)*8;
        sc_al_m <= to_signed(v_sc(base+0), 16);
        sc_al_e <= to_signed(v_sc(base+1), 8);
        sc_dt_m <= to_signed(v_sc(base+2), 16);
        sc_dt_e <= to_signed(v_sc(base+3), 8);
        sc_a_m  <= to_signed(v_sc(base+4), 16);
        sc_a_e  <= to_signed(v_sc(base+5), 8);
        sc_b_m  <= to_signed(v_sc(base+6), 16);
        sc_b_e  <= to_signed(v_sc(base+7), 8);
      end if;
    end if;
  end process;

  -- ======================= producer 3: the z gate =======================
  zgen : process
    variable h : integer := 0;
  begin
    z_valid <= '0';
    wait until loaded;
    wait until rst = '0';
    while h < TOKENS*VAL_HEADS loop
      for i in 1 to Z_DELAY loop
        wait until rising_edge(clk);
      end loop;
      for j in 0 to DIM-1 loop
        z_mant((j+1)*16-1 downto j*16) <=
          std_logic_vector(to_signed(v_z(h*DIM + j), 16));
      end loop;
      z_exp   <= to_signed(v_ze, 8);
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

  wdrv : process(w_dirty, loaded)
  begin
    if loaded then
      for j in 0 to DIM-1 loop
        if W_MOVE and w_dirty then
          w_mant((j+1)*16-1 downto j*16) <=
            std_logic_vector(to_signed(-32000 + j, 16));
        else
          w_mant((j+1)*16-1 downto j*16) <=
            std_logic_vector(to_signed(v_wm(j), 16));
        end if;
      end loop;
      w_exp <= v_we;
    end if;
  end process;

  -- ======================= producer 5: the capture side =================
  capbusy : process
  begin
    if not CAP_BUSY then wait; end if;
    wait until loaded;
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

  -- ======================= collector ====================================
  collect : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y_idx <= 0; blk_got <= 0;
      else
        if y_valid = '1' then
          assert blk_got < TOKENS and y_idx < NY
            report "tb_gdn_block_vec: more output than the run expects"
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
      report "tb_gdn_block_vec: alive, token " & integer'image(tok)
           & " y " & integer'image(y_idx) & " of " & integer'image(NY);
    end loop;
    wait;
  end process;

  -- ======================= the driver and the checker ===================
  drive : process
    variable nbad_y, nbad_s, nbad_e : integer := 0;
    variable first_y : integer := -1;
    variable got, want : integer;
    variable a : integer;
  begin
    wait until loaded;
    rst <= '1';
    for i in 1 to 8 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    wait until rising_edge(clk);

    seq_rst <= '1';
    wait until rising_edge(clk);
    seq_rst <= '0';
    wait until rising_edge(clk);

    for t in 0 to TOKENS-1 loop
      tok <= t;
      if t = 0 then tk0 <= '1'; else tk0 <= '0'; end if;

      -- One capture per segment per token: that is what advances the conv
      -- state FIFO and what makes tvalid grow one tap at a time.
      for s in 0 to 2 loop
        loop
          wait until rising_edge(clk);
          exit when cap_ready = '1' and cap_req = '0';
        end loop;
        dr_layer <= 0;
        dr_seg   <= s;
        dr_exp   <= to_signed(v_cap(t*3 + s), 8);
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

    -- ---- structural checks, kept from tb_gdn_block ----------------------
    assert y_idx = NY
      report "tb_gdn_block_vec: expected " & integer'image(NY)
           & " output elements, got " & integer'image(y_idx)
      severity failure;
    for t in 0 to TOKENS-1 loop
      assert yn_got(t) = VAL_HEADS*DIM
        report "tb_gdn_block_vec: token " & integer'image(t) & " emitted "
             & integer'image(yn_got(t)) & " elements"
        severity failure;
    end loop;
    assert dbg_col_drop = '0'
      report "tb_gdn_block_vec: gdn_recur_pipe offered a column that "
           & "gdn_emit_chain refused.  That column is LOST, not delayed."
      severity failure;

    -- ---- THE VALUE CHECK ------------------------------------------------
    for i in 0 to NY-1 loop
      if y_got(i) /= v_y(i) then
        nbad_y := nbad_y + 1;
        if first_y < 0 then
          first_y := i;
          report "tb_gdn_block_vec: FIRST y MISMATCH at token "
               & integer'image(i / (VAL_HEADS*DIM))
               & " head " & integer'image((i mod (VAL_HEADS*DIM)) / DIM)
               & " element " & integer'image(i mod DIM)
               & ": got " & integer'image(y_got(i))
               & " expected " & integer'image(v_y(i))
            severity note;
        end if;
      end if;
    end loop;
    for t in 0 to TOKENS-1 loop
      assert ye_got(t) = v_ye(t)
        report "tb_gdn_block_vec: token " & integer'image(t) & " y_exp "
             & integer'image(ye_got(t)) & ", expected "
             & integer'image(v_ye(t))
        severity failure;
    end loop;

    for h in 0 to VAL_HEADS-1 loop
      for j in 0 to DIM-1 loop
        for g in 0 to NB_R-1 loop
          for k in 0 to RECUR_LANES-1 loop
            a := (h*DIM + j)*DIM + g*RECUR_LANES + k;
            got := to_integer(signed(
              stmem(h*DIM*NB_R + j*NB_R + g)((k+1)*16-1 downto k*16)));
            if got /= v_s1(a) then nbad_s := nbad_s + 1; end if;
          end loop;
        end loop;
        if to_integer(semem(h*DIM + j)) /= v_se1(h*DIM + j) then
          nbad_e := nbad_e + 1;
        end if;
      end loop;
    end loop;

    report "tb_gdn_block_vec: y mismatches " & integer'image(nbad_y)
         & " of " & integer'image(NY)
         & ", state mismatches " & integer'image(nbad_s)
         & " of " & integer'image(NSTE)
         & ", state-exponent mismatches " & integer'image(nbad_e)
         & " of " & integer'image(NCOL);

    assert nbad_y = 0
      report "tb_gdn_block_vec: " & integer'image(nbad_y) & " of "
           & integer'image(NY) & " y mantissas disagree with the oracle"
      severity failure;
    assert nbad_s = 0
      report "tb_gdn_block_vec: " & integer'image(nbad_s) & " of "
           & integer'image(NSTE) & " final state mantissas disagree with "
           & "the oracle.  y can be right and this wrong; the state is the "
           & "input to every following token."
      severity failure;
    assert nbad_e = 0
      report "tb_gdn_block_vec: " & integer'image(nbad_e) & " of "
           & integer'image(NCOL) & " final state exponents disagree with "
           & "the oracle"
      severity failure;

    -- ---- THE FOUR STATUS FLAGS, GATED ----------------------------------
    -- gdn_block collects these from four units that each reported into open
    -- air, makes them sticky and publishes them.  They were PRINTED here and
    -- in tb_gdn_block, so nothing could fail on them.  The oracle computes
    -- what each one must be for this stimulus.
    assert (err_conv = '1') = (v_flag(0) /= 0)
      report "tb_gdn_block_vec: err_conv is " & std_logic'image(err_conv)
           & ", the oracle says " & integer'image(v_flag(0))
      severity failure;
    assert (err_g = '1') = (v_flag(1) /= 0)
      report "tb_gdn_block_vec: err_g is " & std_logic'image(err_g)
           & ", the oracle says " & integer'image(v_flag(1))
      severity failure;
    assert (err_se = '1') = (v_flag(2) /= 0)
      report "tb_gdn_block_vec: err_se is " & std_logic'image(err_se)
           & ", the oracle says " & integer'image(v_flag(2))
      severity failure;
    assert (y_sat = '1') = (v_flag(3) /= 0)
      report "tb_gdn_block_vec: y_sat is " & std_logic'image(y_sat)
           & ", the oracle says " & integer'image(v_flag(3))
      severity failure;

    report "tb_gdn_block_vec: PASS, " & integer'image(NY)
         & " y elements, " & integer'image(NSTE) & " state mantissas and "
         & integer'image(NCOL) & " state exponents bit-exact against "
         & VECFILE;
    running <= false;
    wait;
  end process;

end architecture;
