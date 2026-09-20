-- sim/tb_gdn_state_store.vhd -- the property the whole design rests on:
-- PER-LAYER RECURRENT STATE SURVIVES ACROSS TOKENS, THROUGH HBM.
--
-- `rtl/gdn_state_store.vhd` holds ONE GDN layer on-chip because all 24 are
-- 24.0 MB against 14.2 MB of BRAM plus URAM
-- (docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md).  Every layer
-- therefore evicts the previous one, 24 times per token.  The thing that can
-- silently go wrong is not the transfer -- `tb_gdn_state_axi` covers that --
-- it is the COMPOSITION: layer 3's state coming back as layer 2's, or as its
-- own value from the wrong token, in a design where every individual transfer
-- is correct.
--
-- SO THIS BENCH RUNS TOKENS, NOT TRANSFERS.  Token 0 walks the layers writing
-- a value that is a function of (layer, token) through the UNIT's port, the
-- way `gdn_block` would.  Token 1 walks them again, reads what token 0 left,
-- checks it, and writes token 1's value.  Token 2 checks token 1's.  A store
-- that loses a layer, swaps two, or returns a stale token fails; a store that
-- merely moves bytes correctly does not pass by accident.
--
-- THE INTERLEAVE IS THE POINT.  Between writing layer L and reading it back,
-- every OTHER layer has been loaded into and evicted from the same physical
-- URAM.  A design that kept state on-chip would pass this trivially and is
-- exactly what does not fit.
--
-- BOTH HALVES OF THE STATE, AND THEY ARE NOT THE SAME KIND OF MEMORY.  The
-- mantissas live in URAM with a REGISTERED read; the exponents live in
-- distributed RAM with a COMBINATIONAL one, because gdn_block consumes an
-- exponent on the same edge it drives the address.  They are moved by two
-- instances of the SAME mover over ONE shared pair of AXI masters, in
-- sequence, so the failure this bench is really hunting is a phase that
-- steals the other's handshake or writes the other's region of the arena.
-- Layer L's exponents sit at `base + L*stride + MANT_BYTES`, immediately
-- after its mantissas: an off-by-one-region address error is invisible at
-- layer 0 and corrupts every other layer.
--
-- THE FOURTH PHASE, UNDER `CONST_EN` (2026-09-18).  Each layer's learned
-- constants -- conv weights, dt bias, A, ssm norm weight, six exponents --
-- live in a SEPARATE region at `CBASE + L*CONST_STRIDE` that the bench
-- initialises with a known per-layer image and that nothing on the card ever
-- writes.  After every LOAD the bench reads every (seg, grp) of the weight
-- face, every scalar and every exponent back and checks them against the
-- image of THAT layer; because every layer is loaded in turn, this is also
-- the check that a load replaces the previous layer's constants entirely.
-- At the end, every beat of the region is compared with the image it started
-- as, and the slave counts writes landing in it: a SAVE must never touch it.
-- `CONST_EN => false` runs the bench exactly as it was, 7968 checks
-- (MEASURED 2026-09-18 at the same generics), which is the control that the
-- disabled store is the old store.
--
-- CHECKS ARE COUNTED IN VARIABLES, NOT SIGNALS.  A signal incremented twice
-- in one delta keeps only the last value.  The counters here used to be
-- signals with a `wait for 0 ns` after every increment, which was correct;
-- variables need no such rule and cannot be got wrong the same way.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_state_store is
  generic(
    -- SHAPED SO THE EXPONENT PHASE IS MORE THAN ONE BURST.  The exponents are
    -- `VAL_HEADS*DIM` BYTES, so at the previous 2x8 shape they were 16 bytes
    -- against a 4-beat burst of 16-byte beats: BURSTS would round to zero and
    -- the mover's `bad_fewer_beats_than_one_burst` refusal would fire during
    -- elaboration.  Narrowing AXI_DW to 64 rather than widening the geometry
    -- keeps the mantissa side small: at 4x16 the exponents are 64 bytes = 8
    -- beats = 2 bursts, which also exercises the MAXOUT=2 bound on a phase
    -- short enough that a bug in it cannot hide behind the long one.
    VAL_HEADS   : positive := 4;
    DIM         : positive := 16;
    RECUR_LANES : positive := 2;
    -- The conv geometry.  KEY_HEADS must not exceed VAL_HEADS -- the tap
    -- store's `r_grp` range is the WIDEST segment's, which is v -- and
    -- CONV_LANES must divide both segment widths.
    KEY_HEADS   : positive := 2;
    KCONV       : positive := 4;
    CONV_LANES  : positive := 2;
    LAYERS      : positive := 4;
    -- FOUR tokens, not three.  The conv history is KCONV-1 = 3 columns deep,
    -- so a run of three tokens never once presents a FULL history and the
    -- rotation's interesting case goes unchecked.  The mantissa and exponent
    -- checks only ever needed two.
    NTOK        : positive := 4;
    -- The constants phase.  TRUE here so the gate row covers it; FALSE is
    -- the control that reproduces the previous 7968-check run.
    CONST_EN    : boolean  := true;
    AXI_DW      : positive := 64;
    MAXB        : positive := 4;
    MAXOUT      : positive := 2;
    -- TRACK BMOVER 2026-09-20: the mover's per-beat levers.  Defaults are
    -- the shipping behaviour; the gate also runs this bench with each on.
    PIPE        : boolean  := false;
    WIDE        : boolean  := false;
    RD_LAT      : positive := 5;
    B_LAT       : natural  := 4
  );
end entity;

architecture sim of tb_gdn_state_store is
  constant NBR   : positive := DIM / RECUR_LANES;
  constant WORDS : positive := VAL_HEADS * DIM * NBR;
  constant WBITS : positive := RECUR_LANES * 16;
  constant WPB   : positive := AXI_DW / WBITS;
  constant BEATS : positive := WORDS / WPB;
  constant BPB   : positive := AXI_DW / 8;
  constant MANT_BYTES   : positive := BEATS * BPB;
  constant EXPN         : positive := VAL_HEADS * DIM;
  constant EXP_BYTES    : positive := EXPN;          -- one byte per entry
  constant EXP_BEATS    : positive := EXP_BYTES / BPB;
  constant NTAP       : positive := KCONV - 1;
  constant KEY_CH     : positive := KEY_HEADS * DIM;
  constant VAL_CH     : positive := VAL_HEADS * DIM;
  constant QKVN       : positive := 2*KEY_CH + VAL_CH;
  constant CONV_WORDS : positive := NTAP * QKVN;
  constant CONV_BYTES : positive := 2 * CONV_WORDS;
  constant CONV_BEATS : positive := CONV_BYTES / BPB;
  -- A GAP AFTER THE EXPONENTS, ON PURPOSE.  `MANT_BYTES + EXP_BYTES` exactly
  -- would make "the end of layer L's exponents" and "the start of layer L+1"
  -- the same address, so a mover that ran one region too long would land on
  -- the next layer's data and be caught only by luck.  With a spare beat, an
  -- overrun writes a hole nothing reads and the CHECK is what catches it.
  constant LAYER_STRIDE : positive := MANT_BYTES + EXP_BYTES + CONV_BYTES
                                     + BPB;
  constant ADDR_W : positive := 33;
  constant BASE   : natural := 8192;

  -- ---- the constants image geometry, the contract's ----------------------
  -- CONST_WORDS = KCONV*QKVN + 256, two bytes per word; the scalar block is
  -- always 256 words and the per-layer size is a multiple of 512 bytes,
  -- which the packer guarantees and the store refuses otherwise.
  constant CW_WORDS    : positive := KCONV * QKVN;
  constant SB_WORDS    : positive := 256;
  constant CONST_WORDS : positive := CW_WORDS + SB_WORDS;
  constant CONST_BYTES : positive := 2 * CONST_WORDS;
  constant CONST_BEATS : positive := CONST_BYTES / BPB;
  -- A GAP after every image, for the same reason LAYER_STRIDE has one: an
  -- overrun lands in a hole nothing reads and the CHECK catches it.
  constant CONST_STRIDE : positive := CONST_BYTES + BPB;
  constant SB_DT  : natural := 0;
  constant SB_A   : natural := VAL_HEADS;
  constant SB_NW  : natural := 2*VAL_HEADS;
  constant SB_EXP : natural := 2*VAL_HEADS + DIM;
  -- The region sits AFTER the whole state arena, with a spare beat between,
  -- so a state mover running one layer too far cannot reach it silently
  -- either: it would land in the gap.
  constant CBASE  : natural := BASE + LAYERS * LAYER_STRIDE + BPB;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal load_start, save_start : std_logic := '0';
  signal layer : integer range 0 to LAYERS-1 := 0;
  signal busy, dn, er : std_logic;

  signal st_ren, st_wen : std_logic := '0';
  signal st_rhead, st_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal st_rcol,  st_wcol  : natural range 0 to DIM-1 := 0;
  signal st_rgrp,  st_wgrp  : natural range 0 to NBR-1 := 0;
  signal st_rdata : std_logic_vector(WBITS-1 downto 0);
  signal st_wdata : std_logic_vector(WBITS-1 downto 0) := (others => '0');

  signal se_rhead, se_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal se_rcol,  se_wcol  : natural range 0 to DIM-1 := 0;
  signal se_rdata : signed(7 downto 0);
  signal se_wen   : std_logic := '0';
  signal se_wdata : signed(7 downto 0) := (others => '0');

  signal cv_seg,  cvw_seg : integer range 0 to 2 := 0;
  signal cv_grp,  cvw_grp : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal cv_x     : std_logic_vector(NTAP*CONV_LANES*16-1 downto 0);
  signal cvw_en   : std_logic := '0';
  signal cvw_data : std_logic_vector(CONV_LANES*16-1 downto 0)
                  := (others => '0');
  signal tok_adv  : std_logic := '0';

  signal cw_seg   : integer range 0 to 2 := 0;
  signal cw_grp   : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal cw_w     : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
  signal cw_exp   : std_logic_vector(23 downto 0);
  signal sc_dt_m, sc_a_m : std_logic_vector(VAL_HEADS*16-1 downto 0);
  signal sn_w     : std_logic_vector(DIM*16-1 downto 0);
  signal sc_dt_e, sc_a_e, sn_exp : signed(7 downto 0);

  signal arvalid, arready, rvalid, rready, rlast : std_logic := '0';
  signal araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst: std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');
  signal rresp  : std_logic_vector(1 downto 0) := "00";

  signal awvalid, awready, wvalid, wready, wlast : std_logic := '0';
  signal awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal awlen  : std_logic_vector(7 downto 0);
  signal awsize : std_logic_vector(2 downto 0);
  signal awburst: std_logic_vector(1 downto 0);
  signal wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);
  signal bvalid, bready : std_logic := '0';
  signal bresp  : std_logic_vector(1 downto 0) := "00";

  constant SLAVE_BEATS : positive := (CBASE - BASE) / BPB
                                    + LAYERS * (CONST_STRIDE / BPB)
                                    + CONST_BEATS;
  constant CFIRST : natural := (CBASE - BASE) / BPB;   -- first const beat
  type smem_t is array (0 to SLAVE_BEATS-1)
                 of std_logic_vector(AXI_DW-1 downto 0);

  -- ---- the constants image of layer L, word w ----------------------------
  -- A FOURTH generator, distinct from val/eval/cval: four regions, and a
  -- mover that wrote one over another must not read back consistent bytes.
  function wgt(L, tap, ch : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(
      ((L*5003 + tap*1013 + ch*37 + 3) mod 65536), 16));
  end function;
  function sdt(L, h : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(((L*211 + h*17 + 5) mod 65536), 16));
  end function;
  function sa(L, h : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(((L*307 + h*23 + 9) mod 65536), 16));
  end function;
  function snw(L, c : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(((L*401 + c*29 + 13) mod 65536), 16));
  end function;
  -- The six exponents: signed, inside the packer's [-64, 63], and NEGATIVE
  -- for some (L, j) so the sign extension from the low byte is exercised.
  function sexp(L, j : natural) return integer is
  begin
    return ((L*19 + j*7 + 40) mod 128) - 64;
  end function;
  function cimg(L, w : natural) return std_logic_vector is
    variable si : natural;
  begin
    if w < CW_WORDS then
      return wgt(L, w / QKVN, w mod QKVN);
    end if;
    si := w - CW_WORDS;
    if    si < SB_A     then return sdt(L, si - SB_DT);
    elsif si < SB_NW    then return sa (L, si - SB_A);
    elsif si < SB_EXP   then return snw(L, si - SB_NW);
    elsif si < SB_EXP+6 then
      return std_logic_vector(to_signed(sexp(L, si - SB_EXP), 16));
    else
      return x"0000";
    end if;
  end function;

  -- The slave's memory at time zero: the state arena zeroed (a sequence
  -- start), the constants region holding every layer's image.  Word w of
  -- layer L is at byte `CBASE + L*CONST_STRIDE + 2w`, little-endian int16,
  -- so word j of a beat is bits j*16 +: 16, which is the order the mover
  -- unpacks.
  function init_smem return smem_t is
    variable m : smem_t := (others => (others => '0'));
    variable b, j : natural;
  begin
    for L in 0 to LAYERS-1 loop
      for w in 0 to CONST_WORDS-1 loop
        b := CFIRST + (L*CONST_STRIDE + 2*w) / BPB;
        j := ((2*w) mod BPB) / 2;
        m(b)((j+1)*16-1 downto j*16) := cimg(L, w);
      end loop;
    end loop;
    return m;
  end function;

  -- Driven by the slave process ONLY; nothing else assigns it.  Two drivers
  -- on one resolved signal resolve rather than take turns, and it costs an
  -- afternoon (see docs/debugging/2026-09-02_gdn-state-dma.md, defect B2).
  -- Its INITIAL value is the image above; an initial value is not a driver.
  signal smem : smem_t := init_smem;

  signal n_stall : natural := 0;
  signal n_cwr   : natural := 0;   -- W beats that landed in the const region
  signal n_crd   : natural := 0;   -- AR bursts that read the const region

  -- the value layer L holds at token T, distinct in every 16-bit lane
  function val(L, T, i : natural) return std_logic_vector is
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for k in 0 to WBITS/16 - 1 loop
      v((k+1)*16-1 downto k*16) := std_logic_vector(to_unsigned(
        ((L*7919 + T*104729 + i*31 + k*613) mod 65536), 16));
    end loop;
    return v;
  end function;

  -- the exponent layer L holds at token T, entry i.  A DIFFERENT generator
  -- from `val`, deliberately: if both regions were filled from one function
  -- a mover that wrote the exponents over the mantissas' address range could
  -- still read back consistent-looking bytes.
  function eval(L, T, i : natural) return signed is
  begin
    return to_signed(((L*23 + T*57 + i*11 + 19) mod 256) - 128, 8);
  end function;

  -- The conv column layer L wrote at token T, channel ch.  A THIRD distinct
  -- generator, for the same reason `eval` is distinct from `val`: three
  -- regions in one layer, and a mover that wrote one over another must not be
  -- able to read back something self-consistent.
  function cval(L, T, ch : integer) return std_logic_vector is
  begin
    if T < 0 then
      return x"0000";   -- older than the sequence: zero, not a stand-in
    end if;
    return std_logic_vector(to_unsigned(
      ((L*4099 + T*1013 + ch*37 + 11) mod 65536), 16));
  end function;

  function chan_of(seg : integer; grp, ln : natural) return natural is
  begin
    if seg = 0 then return grp*CONV_LANES + ln;
    elsif seg = 1 then return KEY_CH + grp*CONV_LANES + ln;
    else return 2*KEY_CH + grp*CONV_LANES + ln; end if;
  end function;

  function grps_in(seg : integer) return natural is
  begin
    if seg = 2 then return VAL_CH/CONV_LANES;
    else return KEY_CH/CONV_LANES; end if;
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_state_store
    -- STYLE = "auto" HERE AND "ultra" ON THE CARD, AND THE DIFFERENCE IS NOT
    -- BEHAVIOURAL IN SIMULATION.  `ram_style` is a synthesis attribute; GHDL
    -- ignores it entirely, so this bench would run identically at "ultra".
    -- It is set to "auto" so the row does not read as though it were
    -- exercising the URAM configuration, WHICH IT IS NOT.
    --
    -- The one place that distinction could bite is recorded as an open item
    -- in docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md: URAM288
    -- read-during-write collision behaviour is not BRAM's, and no simulation
    -- here can settle it because GHDL's answer comes from VHDL signal
    -- semantics rather than from the primitive.
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM,
                RECUR_LANES => RECUR_LANES, LAYERS => LAYERS,
                STYLE => "auto",
                KEY_HEADS => KEY_HEADS, KCONV => KCONV,
                CONV_LANES => CONV_LANES,
                EXP_STYLE => "distributed", CONV_STYLE => "auto",
                LAYER_STRIDE => LAYER_STRIDE, MANT_BYTES => MANT_BYTES,
                EXP_BYTES => EXP_BYTES, CONV_BYTES => CONV_BYTES,
                CONST_EN => CONST_EN, CONST_STRIDE => CONST_STRIDE,
                CONST_BYTES => CONST_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT,
                PIPE => PIPE, WIDE => WIDE)
    port map(clk => clk, rst => rst,
             load_start => load_start, save_start => save_start,
             layer => layer,
             state_base => std_logic_vector(to_unsigned(BASE, ADDR_W)),
             const_base => std_logic_vector(to_unsigned(CBASE, ADDR_W)),
             cw_seg => cw_seg, cw_grp => cw_grp, cw_w => cw_w,
             cw_exp => cw_exp, sc_dt_m => sc_dt_m, sc_a_m => sc_a_m,
             sn_w => sn_w, sc_dt_e => sc_dt_e, sc_a_e => sc_a_e,
             sn_exp => sn_exp,
             busy => busy, done => dn, err => er,
             st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,
             st_rgrp => st_rgrp, st_rdata => st_rdata,
             st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,
             st_wgrp => st_wgrp, st_wdata => st_wdata,
             se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,
             se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,
             se_wdata => se_wdata,
             cv_seg => cv_seg, cv_grp => cv_grp, cv_x => cv_x,
             cvw_en => cvw_en, cvw_seg => cvw_seg, cvw_grp => cvw_grp,
             cvw_data => cvw_data, tok_adv => tok_adv,
             r_arvalid => arvalid, r_arready => arready, r_araddr => araddr,
             r_arlen => arlen, r_arsize => arsize, r_arburst => arburst,
             r_rvalid => rvalid, r_rready => rready, r_rdata => rdata,
             r_rlast => rlast, r_rresp => rresp,
             w_awvalid => awvalid, w_awready => awready, w_awaddr => awaddr,
             w_awlen => awlen, w_awsize => awsize, w_awburst => awburst,
             w_wvalid => wvalid, w_wready => wready, w_wdata => wdata,
             w_wstrb => wstrb, w_wlast => wlast,
             w_bvalid => bvalid, w_bready => bready, w_bresp => bresp);

  -- ---- the AXI3 slave.  Same model as tb_gdn_state_axi. ----------------
  slave : process(clk) is
    type qent_t is record
      addr : natural; len : natural; age : natural; live : boolean;
    end record;
    type q_t is array (0 to 7) of qent_t;
    variable rq, wq : q_t := (others => (0,0,0,false));
    variable seed : unsigned(31 downto 0) := x"5EED1234";
    variable bpend, bage : natural := 0;
    variable head, tail, whead, wtail : natural := 0;
    impure function nxt return natural is
      variable t : unsigned(63 downto 0);
    begin
      t := seed * to_unsigned(1103515245, 32);
      seed := t(31 downto 0) + to_unsigned(12345, 32);
      seed := seed xor shift_right(seed, 15);
      return to_integer(seed(30 downto 0));
    end function;
  begin
    if rising_edge(clk) then
      arready <= '1' when (nxt mod 4) /= 0
                      and not rq((head + 1) mod 8).live else '0';
      awready <= '1' when (nxt mod 4) /= 0
                      and not wq((whead + 1) mod 8).live else '0';
      wready  <= '1' when (nxt mod 3) /= 0 else '0';
      if wvalid = '1' and wready = '0' then n_stall <= n_stall + 1; end if;

      if arvalid = '1' and arready = '1' then
        rq(head) := ((to_integer(unsigned(araddr)) - BASE) / BPB,
                     to_integer(unsigned(arlen)) + 1, 0, true);
        head := (head + 1) mod 8;
        if (to_integer(unsigned(araddr)) - BASE) / BPB >= CFIRST then
          n_crd <= n_crd + 1;
        end if;
      end if;
      if rvalid = '1' and rready = '1' then
        if rq(tail).len = 1 then
          rq(tail).live := false; tail := (tail + 1) mod 8;
          rvalid <= '0'; rlast <= '0';
        else
          rq(tail).addr := rq(tail).addr + 1;
          rq(tail).len  := rq(tail).len - 1;
          rdata <= smem(rq(tail).addr);
          rlast <= '1' when rq(tail).len = 1 else '0';
        end if;
      elsif rvalid = '0' and rq(tail).live then
        if rq(tail).age < RD_LAT then rq(tail).age := rq(tail).age + 1;
        else
          rvalid <= '1'; rdata <= smem(rq(tail).addr);
          rlast <= '1' when rq(tail).len = 1 else '0';
        end if;
      end if;

      if awvalid = '1' and awready = '1' then
        wq(whead) := ((to_integer(unsigned(awaddr)) - BASE) / BPB,
                      to_integer(unsigned(awlen)) + 1, 0, true);
        whead := (whead + 1) mod 8;
      end if;
      if wvalid = '1' and wready = '1' then
        assert wq(wtail).live
          report "tb_gdn_state_store: W beat with no outstanding AW"
          severity failure;
        smem(wq(wtail).addr) <= wdata;
        if wq(wtail).addr >= CFIRST then n_cwr <= n_cwr + 1; end if;
        if wq(wtail).len = 1 then
          assert wlast = '1' report "tb_gdn_state_store: burst without WLAST"
            severity failure;
          wq(wtail).live := false; wtail := (wtail + 1) mod 8;
          bpend := bpend + 1;
        else
          wq(wtail).addr := wq(wtail).addr + 1;
          wq(wtail).len  := wq(wtail).len - 1;
        end if;
      end if;
      if bvalid = '1' and bready = '1' then
        bvalid <= '0'; bpend := bpend - 1; bage := 0;
      elsif bvalid = '0' and bpend > 0 then
        if bage < B_LAT then bage := bage + 1; else bvalid <= '1'; end if;
      end if;

      if rst = '1' then
        rq := (others => (0,0,0,false));
        wq := (others => (0,0,0,false));
        head := 0; tail := 0; whead := 0; wtail := 0;
        bpend := 0; bage := 0;
        rvalid <= '0'; rlast <= '0'; bvalid <= '0';
      end if;
    end if;
  end process;

  -- ---- the stimulus: tokens, each walking every layer -------------------
  stim : process is
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    -- WAIT ON `done`.  `busy` does not rise on the start edge; see
    -- docs/debugging/2026-09-02_gdn-state-dma.md, defect B1.
    procedure wait_done is
      variable n : natural := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when dn = '1';
        n := n + 1;
        assert n < 200 * BEATS + 5000
          report "tb_gdn_state_store: FAIL, the mover never asserted `done`."
          severity failure;
      end loop;
    end procedure;

    variable n_chk, n_bad : natural := 0;
    variable n_exp   : natural := 0;   -- exponent bytes actually checked
    variable n_conv  : natural := 0;   -- conv tap groups actually checked
    variable n_full  : natural := 0;   -- of those, with a FULL history
    variable n_cw    : natural := 0;   -- conv WEIGHT groups checked
    variable n_sc    : natural := 0;   -- scalar and exponent checks
    variable n_cimg  : natural := 0;   -- const-region beats compared at end

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk := n_chk + 1;
      if not cond then
        n_bad := n_bad + 1;
        report "tb_gdn_state_store: " & msg severity error;
      end if;
    end procedure;

    -- the unit's own port, addressed the way gdn_block addresses it
    procedure unit_write(i : natural; d : std_logic_vector) is
    begin
      st_wen   <= '1';
      st_whead <= i / (DIM*NBR);
      st_wcol  <= (i / NBR) mod DIM;
      st_wgrp  <= i mod NBR;
      st_wdata <= d;
      tick;
      st_wen <= '0';
    end procedure;

    procedure unit_read(i : natural) is
    begin
      st_ren   <= '1';
      st_rhead <= i / (DIM*NBR);
      st_rcol  <= (i / NBR) mod DIM;
      st_rgrp  <= i mod NBR;
      tick;
      st_ren <= '0';
      tick;   -- registered read: the data is valid on the second edge
    end procedure;

    -- the exponent port.  Same shape as gdn_block's se_*, including the
    -- absence of a read enable: the read is COMBINATIONAL and there is
    -- nothing to enable.
    procedure unit_ewrite(i : natural; d : signed) is
    begin
      se_wen   <= '1';
      se_whead <= i / DIM;
      se_wcol  <= i mod DIM;
      se_wdata <= d;
      tick;
      se_wen <= '0';
    end procedure;

    -- NO RISING EDGE between driving the address and checking the data.  If
    -- there were one, the check would pass against a REGISTERED exponent
    -- memory, which is the one memory gdn_block cannot use (see the
    -- rtl/gdn_exp_mem.vhd header).
    --
    -- POSITIONED AT A FALLING EDGE AND THEN WAITING A REAL 1 ns, rather than
    -- counting `wait for 0 ns`.  A fixed delta count encodes a private detail
    -- of the DUT's internal wiring -- how many concurrent assignments the
    -- signal passes through on its way out -- so adding one relay inside the
    -- DUT silently shifts every read by one address.  MEASURED: that is
    -- exactly what happened here, and it read as a mover bug until a probe
    -- showed the unit port was already wrong BEFORE any DMA ran.  Half a
    -- clock period is unambiguous and survives any internal rewiring.
    procedure unit_eread(i : natural) is
    begin
      wait until falling_edge(clk);
      se_rhead <= i / DIM;
      se_rcol  <= i mod DIM;
      wait for 1 ns;
    end procedure;

    -- The conv tap port.  REGISTERED address, data in the following cycle --
    -- gdn_block's stated contract and a plain BRAM's behaviour, unlike the
    -- exponent port above which must be combinational.  The two live in one
    -- bench precisely so a reader cannot assume they are the same.
    procedure unit_cread(seg : integer; grp : natural) is
    begin
      cv_seg <= seg; cv_grp <= grp;
      tick;
      wait for 1 ns;
    end procedure;

    procedure unit_cwrite(seg : integer; grp : natural;
                          d : std_logic_vector) is
    begin
      cvw_en <= '1'; cvw_seg <= seg; cvw_grp <= grp; cvw_data <= d;
      tick;
      cvw_en <= '0';
    end procedure;

    -- The conv WEIGHT face: same timing contract as the tap face.
    procedure unit_wread(seg : integer; grp : natural) is
    begin
      cw_seg <= seg; cw_grp <= grp;
      tick;
      wait for 1 ns;
    end procedure;

    -- Every constant of layer L, read back through the store's faces.
    procedure check_consts(L, T : natural) is
      variable wok : boolean;
    begin
      for seg in 0 to 2 loop
        for grp in 0 to grps_in(seg)-1 loop
          unit_wread(seg, grp);
          wok := true;
          for k in 0 to KCONV-1 loop
            for ln in 0 to CONV_LANES-1 loop
              if cw_w(k*CONV_LANES*16 + (ln+1)*16 - 1
                      downto k*CONV_LANES*16 + ln*16)
                 /= wgt(L, k, chan_of(seg, grp, ln)) then
                wok := false;
              end if;
            end loop;
          end loop;
          n_cw := n_cw + 1;
          chk(wok, "token " & integer'image(T) & " layer " & integer'image(L)
                 & " seg " & integer'image(seg) & " grp " & integer'image(grp)
                 & ": the conv weights are not the image's, tap-major; got "
                 & to_hstring(cw_w));
        end loop;
      end loop;
      for h in 0 to VAL_HEADS-1 loop
        n_sc := n_sc + 2;
        chk(sc_dt_m((h+1)*16-1 downto h*16) = sdt(L, h),
            "layer " & integer'image(L) & " dt[" & integer'image(h)
            & "] got " & to_hstring(sc_dt_m((h+1)*16-1 downto h*16)));
        chk(sc_a_m((h+1)*16-1 downto h*16) = sa(L, h),
            "layer " & integer'image(L) & " a[" & integer'image(h)
            & "] got " & to_hstring(sc_a_m((h+1)*16-1 downto h*16)));
      end loop;
      for c in 0 to DIM-1 loop
        n_sc := n_sc + 1;
        chk(sn_w((c+1)*16-1 downto c*16) = snw(L, c),
            "layer " & integer'image(L) & " norm_w[" & integer'image(c)
            & "] got " & to_hstring(sn_w((c+1)*16-1 downto c*16)));
      end loop;
      for j in 0 to 2 loop
        n_sc := n_sc + 1;
        chk(to_integer(signed(cw_exp((j+1)*8-1 downto j*8))) = sexp(L, j),
            "layer " & integer'image(L) & " cw_exp[" & integer'image(j)
            & "] got "
            & integer'image(to_integer(signed(cw_exp((j+1)*8-1 downto j*8))))
            & " want " & integer'image(sexp(L, j)));
      end loop;
      n_sc := n_sc + 3;
      chk(to_integer(sc_dt_e) = sexp(L, 3), "layer " & integer'image(L)
          & " dt_e got " & integer'image(to_integer(sc_dt_e)));
      chk(to_integer(sc_a_e) = sexp(L, 4), "layer " & integer'image(L)
          & " a_e got " & integer'image(to_integer(sc_a_e)));
      chk(to_integer(sn_exp) = sexp(L, 5), "layer " & integer'image(L)
          & " w_exp got " & integer'image(to_integer(sn_exp)));
    end procedure;

    variable ccol : std_logic_vector(CONV_LANES*16-1 downto 0);
    variable cok  : boolean;
    variable ref  : smem_t;
  begin
    rst <= '1'; tick(4); rst <= '0'; tick(2);

    for T in 0 to NTOK-1 loop
      for L in 0 to LAYERS-1 loop
        layer <= L; tick;
        load_start <= '1'; tick; load_start <= '0';
        wait_done;
        chk(er = '0', "err after LOAD, token " & integer'image(T)
                    & " layer " & integer'image(L));

        -- THE CONSTANTS, every load: this layer's image, and since the
        -- previous load was another layer's, all of it replaced.
        if CONST_EN then
          check_consts(L, T);
        end if;

        -- Token 0 has nothing to check: HBM starts zeroed and that is what a
        -- real sequence start means.  From token 1 the layer MUST hold what
        -- this bench wrote to it on the previous token, which is only true if
        -- it survived being evicted by every other layer in between.
        if T > 0 then
          for i in 0 to WORDS-1 loop
            unit_read(i);
            chk(st_rdata = val(L, T-1, i),
                "token " & integer'image(T) & " layer " & integer'image(L)
                & " word " & integer'image(i) & " lost its state: got "
                & to_hstring(st_rdata) & " want "
                & to_hstring(val(L, T-1, i)));
          end loop;
        end if;

        -- The exponents, same rule: token 0 seeds, later tokens must find
        -- what the previous one left after every other layer has passed
        -- through the same distributed RAM.
        if T > 0 then
          for i in 0 to EXPN-1 loop
            unit_eread(i);
            n_exp := n_exp + 1;
            chk(se_rdata = eval(L, T-1, i),
                "token " & integer'image(T) & " layer " & integer'image(L)
                & " exponent " & integer'image(i) & " lost its state: got "
                & integer'image(to_integer(se_rdata)) & " want "
                & integer'image(to_integer(eval(L, T-1, i))));
          end loop;
        end if;

        -- THE CONV TAPS, and the property here is ORDER rather than mere
        -- survival: at token T the store must hand back this layer's columns
        -- T-NTAP .. T-1, OLDEST FIRST, after a save to HBM and a load back.
        -- The rotation lives on-chip and the HBM image is slot-major, so this
        -- is the check that the two agree.  Zeros before the sequence starts
        -- are not a stand-in, they are what those columns are.
        for seg in 0 to 2 loop
          for grp in 0 to grps_in(seg)-1 loop
            unit_cread(seg, grp);
            cok := true;
            for k in 0 to NTAP-1 loop
              for ln in 0 to CONV_LANES-1 loop
                if cv_x(k*CONV_LANES*16 + (ln+1)*16 - 1
                        downto k*CONV_LANES*16 + ln*16)
                   /= cval(L, T - NTAP + k, chan_of(seg, grp, ln)) then
                  cok := false;
                end if;
              end loop;
            end loop;
            n_conv := n_conv + 1;
            if T >= NTAP then n_full := n_full + 1; end if;
            chk(cok, "token " & integer'image(T) & " layer "
                   & integer'image(L) & " seg " & integer'image(seg)
                   & " grp " & integer'image(grp)
                   & ": the conv taps are not columns "
                   & integer'image(T-NTAP) & ".." & integer'image(T-1)
                   & " oldest first; got " & to_hstring(cv_x));
          end loop;
        end loop;

        for i in 0 to WORDS-1 loop
          unit_write(i, val(L, T, i));
        end loop;
        for i in 0 to EXPN-1 loop
          unit_ewrite(i, eval(L, T, i));
        end loop;
        for seg in 0 to 2 loop
          for grp in 0 to grps_in(seg)-1 loop
            for ln in 0 to CONV_LANES-1 loop
              ccol((ln+1)*16-1 downto ln*16)
                := cval(L, T, chan_of(seg, grp, ln));
            end loop;
            unit_cwrite(seg, grp, ccol);
          end loop;
        end loop;

        save_start <= '1'; tick; save_start <= '0';
        wait_done;
        chk(er = '0', "err after SAVE, token " & integer'image(T)
                    & " layer " & integer'image(L));
      end loop;

      -- ONE pulse per TOKEN, after every layer has read and written -- not
      -- one per layer.  Every GDN layer is visited once per token, so all of
      -- them rotate in lockstep and the rotation needs no per-layer state.
      -- Pulsing it per layer would advance it LAYERS times per token and the
      -- taps would come back in the wrong order for every layer but the last.
      tok_adv <= '1'; tick; tok_adv <= '0';
    end loop;

    tick(4);

    -- A SAVE NEVER WRITES THE CONST REGION.  Two independent forms: the
    -- slave counted every W beat landing at or above CFIRST, and every beat
    -- of the region still holds the image it started as.  Both run with
    -- CONST_EN false too, where they say the old store never strayed there.
    ref := init_smem;
    chk(n_cwr = 0, "the slave saw " & integer'image(n_cwr)
        & " W beats land in the constants region; a save must never write it");
    -- LOAD ONLY, AND ONCE PER LOAD: the region is read exactly
    -- CONST_BEATS/MAXB bursts per load job and not at all by a save.  A
    -- sequencer that ran the phase on a save too would still pass every
    -- value check above, because a reload is harmless; this is the check
    -- that sees it.
    if CONST_EN then
      chk(n_crd = NTOK * LAYERS * (CONST_BEATS / MAXB),
          "the constants region was read " & integer'image(n_crd)
          & " bursts; want exactly "
          & integer'image(NTOK * LAYERS * (CONST_BEATS / MAXB))
          & " (one image per LOAD, none per SAVE)");
    else
      chk(n_crd = 0, "CONST_EN is off and the constants region was read "
          & integer'image(n_crd) & " bursts");
    end if;
    -- From the gap beat BEFORE the region, so a state mover that ran one
    -- layer too far is caught here as well as by its own checks.
    for b in CFIRST-1 to SLAVE_BEATS-1 loop
      n_cimg := n_cimg + 1;
      if smem(b) /= ref(b) then
        chk(false, "constants region beat " & integer'image(b)
            & " changed: got " & to_hstring(smem(b)) & " want "
            & to_hstring(ref(b)));
      end if;
    end loop;
    n_chk := n_chk + 1;   -- the loop above is ONE check: "nothing changed"

    report "tb_gdn_state_store: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " tokens=" & integer'image(NTOK)
         & " layers=" & integer'image(LAYERS)
         & " exponent bytes=" & integer'image(n_exp)
         & " conv groups=" & integer'image(n_conv)
         & " (full history " & integer'image(n_full) & ")"
         & " conv weight groups=" & integer'image(n_cw)
         & " scalar+exp checks=" & integer'image(n_sc)
         & " const beats compared=" & integer'image(n_cimg)
         & " const-region W beats=" & integer'image(n_cwr)
         & " const-region AR bursts=" & integer'image(n_crd)
         & " W stalls=" & integer'image(n_stall) severity note;

    -- A run that never reached token 1 checked no persistence at all.
    assert NTOK >= 2
      report "tb_gdn_state_store: FAIL, NTOK < 2 checks nothing."
      severity failure;
    assert n_stall > 0
      report "tb_gdn_state_store: FAIL, the slave never stalled."
      severity failure;
    -- The exponent phase is 0.39% of the traffic and 50% of the state's
    -- correctness.  A run that moved only mantissas and still said PASS is
    -- the exact failure this assertion exists to prevent.
    assert n_exp > 0
      report "tb_gdn_state_store: FAIL, no exponent was ever checked, so the "
           & "second phase of every transfer is UNTESTED."
      severity failure;
    assert n_conv > 0
      report "tb_gdn_state_store: FAIL, no conv tap was ever checked, so the "
           & "THIRD phase of every transfer is UNTESTED."
      severity failure;
    -- COVERAGE OF THE INPUT SPACE IS NOT COVERAGE OF THE OUTPUT SPACE.  Every
    -- conv check before token NTAP is reading a history that is partly zeros,
    -- and a rotation that is wrong only when all KCONV-1 slots are live would
    -- pass every one of them.  This is the assertion that says the
    -- interesting case was actually reached.
    assert n_full > 0
      report "tb_gdn_state_store: FAIL, no conv tap was ever checked with a "
           & "FULL history behind it; NTOK must exceed KCONV-1."
      severity failure;
    -- With the phase on, a run that checked no weight group or no scalar
    -- left the FOURTH phase untested.
    assert (not CONST_EN) or (n_cw > 0 and n_sc > 0)
      report "tb_gdn_state_store: FAIL, CONST_EN is on and no constant was "
           & "ever checked, so the FOURTH phase is UNTESTED."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_state_store RESULT: PASS -- " & integer'image(n_chk)
           & " checks, of which " & integer'image(n_exp)
           & " exponents and " & integer'image(n_conv)
           & " conv tap groups (" & integer'image(n_full)
           & " with a full history) and " & integer'image(n_cw)
           & " conv weight groups + " & integer'image(n_sc)
           & " scalars; every layer's mantissas, exponents AND "
           & "conv taps survived " & integer'image(LAYERS-1)
           & " evictions per token across " & integer'image(NTOK)
           & " tokens, and the constants region was never written."
           severity note;
    else
      report "tb_gdn_state_store RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
