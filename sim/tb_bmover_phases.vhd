-- sim/tb_bmover_phases.vhd -- WHERE DO THE CYCLES OF ONE B JOB GO?
--
-- MEASURED on the FK33 card 2026-09-20 (hw/fk33/results/card_swg_2026-09-20/
-- profile/profile_flat_tok0.txt): every B_JOB step costs 660,600 cycles at
-- 75 MHz, constant to within 30 cycles across all 24 layers and identical on
-- the flat and the lane-striped HBM image.  DERIVED from the geometry, a
-- fully serial load + recurrence + store with the AXI port streaming one beat
-- per cycle would be about 271k.  This bench exists to account for the
-- difference in simulation, phase by phase, so the fix is aimed at the
-- phase that owns the cycles rather than at the phase a document named.
--
-- WHAT IT COMPOSES.  `gdn_job_seq` + `gdn_state_store` at the 9B geometry,
-- exactly as `rtl/llama_top.vhd`'s `gen_st_tier` wires them, against an
-- AXI3 slave model with a PIPELINED read latency (every burst's data is
-- ready RD_LAT cycles after its AR was accepted, independent of the bursts
-- ahead of it) and a full-rate data path.  `gdn_block` is a STAND-IN that
-- holds `b_busy` for exactly B_RUN cycles, because the block's own run is a
-- separate quantity: MEASURED by `sim/tb_gdn_block.vhd` at the 9B generics,
-- 149,579 cycles, and that number is the default here.  The stand-in is not
-- idle: it reads back every state word, exponent, tap and constant the load
-- delivered and checks them against the images the slave was initialised
-- with, then writes a new pattern that the save must carry back.  So the
-- bench is an oracle for the mover as well as a stopwatch, which is what
-- lets it guard a mover rewrite.
--
-- WHAT IT PRINTS.  One `BMOVER_PHASE <name> <cycles>` line per phase and a
-- `BMOVER_TOTAL <cycles>` line, plus AXI channel statistics.  A phase is
-- attributed from the REGION of the most recent AR (load) or AW (save)
-- handshake -- mantissa, exponent, conv, constants are disjoint address
-- ranges -- plus the job sequencer's ports.  GHDL 1.0.0 mcode cannot
-- elaborate an external name on the store's `sel`, so the boundary is one
-- to two cycles late per phase (the next mover's first address), which is
-- ~14 cycles of 660k and is stated rather than hidden.
--
-- TWO PASSES, AND THE DEFAULTS ARE THE PROPOSED MOVER, NOT THE SHIPPING ONE.
-- Pass 1 runs the job against the ideal slave and prints the account.
-- Pass 2 runs it again -- loading what pass 1 saved -- with the slave
-- stalling AR, R, AW, W and B at random.  MEASURED while building this:
-- three mutants of the new save paths (an assembly overrun, a missing FIFO
-- credit, W issued ahead of AW) pass the clean run and are killed only by
-- back-pressure, so a bench with no stalls guards half the mover.  The
-- shipping behaviour (PIPE=false, WIDE=false) is guarded by
-- `tb_gdn_state_store` and `tb_gdn_state_axi` at their defaults; this row
-- guards the paths those defaults do not reach.
--
-- CHECKS ARE COUNTED IN VARIABLES, NOT SIGNALS.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_bmover_phases is
  generic(
    -- The 9B geometry.  These are the card's numbers (rtl/llama_top.vhd
    -- B_RECUR_LANES 4, B_CONV_LANES 4, gen_fk33_card.py B_CONST_HBM true).
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    KEY_HEADS   : positive := 16;
    KCONV       : positive := 4;
    CONV_LANES  : positive := 4;
    LAYERS      : positive := 24;
    LAYER       : natural  := 0;
    CONST_EN    : boolean  := true;

    -- The mover.
    AXI_DW : positive := 256;
    MAXB   : positive := 16;
    MAXOUT : positive := 4;
    -- The mover's own knobs.  DEFAULTED TO THE PROPOSED CONFIGURATION (see
    -- the header); pass -gPIPE=false -gWIDE=false for the shipping mover.
    PIPE   : boolean  := true;
    WIDE   : boolean  := true;
    -- TRACK BNARROW 2026-09-20.  The same lever for the THREE NARROW movers
    -- (exponents, conv taps, constants).  DEFAULTED TO THE PROPOSED
    -- CONFIGURATION, as PIPE and WIDE are; pass -gNWIDE=false for the
    -- 2026-09-20 shipping store, which is what the before/after table in
    -- docs/debugging/2026-09-20_b-job-660k-cycles.md is measured against.
    NWIDE  : boolean  := true;

    -- The slave.  RD_LAT is an ESTIMATE of the HBM read latency at the
    -- 75 MHz core clock and has not been measured on the card; it is a
    -- generic so it can be swept.
    RD_LAT : natural := 40;
    B_LAT  : natural := 10;
    -- Extra cycles per R beat (0 = one beat per cycle).
    RD_GAP : natural := 0;
    -- Run the second, stalling pass.
    STALL_PASS : boolean := true;

    -- The stand-in block's run length.  MEASURED, tb_gdn_block at 9B.
    B_RUN  : positive := 149579;

    -- Fail the bench if the job takes longer than this.  0 disables.
    MAX_CYCLES : natural := 0;

    -- ---- TRACK BNARROW 2026-09-20: the per-phase bound ------------------
    -- THE ONE CHECK IN THIS BENCH THAT A VALUE ORACLE CANNOT STAND IN FOR.
    -- Every other check here compares numbers, and NWIDE does not change a
    -- number: a store that quietly failed to enable a wide path -- a generic
    -- not threaded through, a port left at its default -- would move every
    -- value correctly and simply take 16 or 32 cycles per beat again.  All
    -- 770,965 value checks would pass and the whole lever would be gone,
    -- which is exactly the defect this track exists to prevent.
    --
    -- The bound is 4 cycles per beat plus 256, and both halves are chosen to
    -- DISCRIMINATE rather than to be tight.  MEASURED with NWIDE: 1.01 to
    -- 1.35 cycles per beat (ld_exp 134-247 for 128 beats, ld_conv 1,542-2,403
    -- for 1,536, ld_const 2,069-3,236 for 2,064).  MEASURED without it: 16
    -- cycles per beat on the conv and const phases and 32 on the exponents.
    -- 4 sits above every fast figure including RD_LAT 80 at MAXOUT 4, where
    -- the phases DO become latency-sensitive, and a factor of four below the
    -- slow ones.  The 256 is the fixed per-phase overhead (AR issue, the
    -- drain, the boundary error this bench's own header states) and matters
    -- only for the 128-beat exponent phases.
    --
    -- A generic so the ATTRIBUTION CONTROL can turn it off: a mutant that
    -- this check kills has to be re-run with it disabled, or there is no
    -- telling whether an older property would have caught it anyway.
    NBOUND : boolean := true
  );
end entity;

architecture sim of tb_bmover_phases is
  constant ADDR_W : positive := 33;
  constant NBR    : positive := DIM / RECUR_LANES;
  constant WBITS  : positive := RECUR_LANES * 16;
  constant NST    : positive := VAL_HEADS * DIM * NBR;     -- state words
  constant NEXP   : positive := VAL_HEADS * DIM;           -- exponent bytes
  constant KEY_CH : positive := KEY_HEADS * DIM;
  constant VAL_CH : positive := VAL_HEADS * DIM;
  constant QKVN   : positive := 2*KEY_CH + VAL_CH;
  constant NTAP   : positive := KCONV - 1;
  constant CONV_WORDS  : positive := NTAP * QKVN;
  constant CW_WORDS    : positive := KCONV * QKVN;
  constant SB_WORDS    : positive := 256;
  constant CONST_WORDS : positive := CW_WORDS + SB_WORDS;
  constant SB_DT  : natural := 0;
  constant SB_A   : natural := VAL_HEADS;
  constant SB_NW  : natural := 2*VAL_HEADS;
  constant SB_EXP : natural := 2*VAL_HEADS + DIM;

  constant MANT_BYTES   : positive := NST * WBITS / 8;
  constant EXP_BYTES    : positive := NEXP;
  constant CONV_BYTES   : positive := 2 * CONV_WORDS;
  constant LAYER_STRIDE : positive := MANT_BYTES + EXP_BYTES + CONV_BYTES;
  constant CONST_BYTES  : positive := 2 * CONST_WORDS;
  constant CONST_STRIDE : positive := CONST_BYTES;

  constant BPB : positive := AXI_DW / 8;
  -- TRACK BNARROW: the three narrow regions' beat counts, for the bound.
  constant EXP_BEATS  : positive := EXP_BYTES / BPB;
  constant CONV_BEATS : positive := CONV_BYTES / BPB;
  constant KONST_BEATS : positive := CONST_BYTES / BPB;
  constant STATE_BEATS : positive := LAYER_STRIDE / BPB;
  constant CONST_BEATS : positive := CONST_STRIDE / BPB;
  constant MANT_B0 : natural := 0;
  constant EXP_B0  : natural := MANT_BYTES / BPB;
  constant CONV_B0 : natural := (MANT_BYTES + EXP_BYTES) / BPB;

  -- Two arenas far apart, both 32-byte aligned.  The slave holds ONLY
  -- layer LAYER's regions and refuses any other address.  Below 2**31
  -- because the bench does its address arithmetic in `natural`; the mover's
  -- own arithmetic is `unsigned(ADDR_W-1 downto 0)` and does not care.
  constant SBASE : natural := 2**30;
  constant CBASE : natural := 2**30 + 2**26;
  constant SREG  : natural := SBASE + LAYER * LAYER_STRIDE;
  constant CREG  : natural := CBASE + LAYER * CONST_STRIDE;

  constant NG_K : positive := KEY_CH / CONV_LANES;
  constant NG_V : positive := VAL_CH / CONV_LANES;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal cyc : natural := 0;

  -- ---- job control -----------------------------------------------------
  signal start   : std_logic := '0';
  signal js_busy, js_done, js_err : std_logic;
  signal js_ld, js_sv, js_sdone, js_serr : std_logic;
  signal js_layer : integer range 0 to LAYERS-1;
  signal js_cvw_en : std_logic;
  signal js_cvw_seg : integer range 0 to 2;
  signal js_cvw_grp : natural range 0 to VAL_CH/CONV_LANES-1;
  signal js_cvw_data : std_logic_vector(CONV_LANES*16-1 downto 0);
  signal js_b_start, b_busy : std_logic := '0';
  signal js_q_seg : integer range 0 to 2;
  signal js_q_grp : natural range 0 to VAL_CH/CONV_LANES-1;
  signal js_q_data : std_logic_vector(CONV_LANES*16-1 downto 0)
                   := (others => '0');

  -- ---- the store's unit faces ------------------------------------------
  signal st_ren, st_wen : std_logic := '0';
  signal st_rhead, st_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal st_rcol, st_wcol : natural range 0 to DIM-1 := 0;
  signal st_rgrp, st_wgrp : natural range 0 to NBR-1 := 0;
  signal st_rdata, st_wdata : std_logic_vector(WBITS-1 downto 0)
                            := (others => '0');
  signal se_rhead, se_whead : natural range 0 to VAL_HEADS-1 := 0;
  signal se_rcol, se_wcol : natural range 0 to DIM-1 := 0;
  signal se_rdata, se_wdata : signed(7 downto 0) := (others => '0');
  signal se_wen : std_logic := '0';
  signal cv_seg : integer range 0 to 2 := 0;
  signal cv_grp : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal cv_x   : std_logic_vector(NTAP*CONV_LANES*16-1 downto 0);
  signal cw_w   : std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);
  signal cw_exp : std_logic_vector(23 downto 0);
  signal sc_dt_m, sc_a_m : std_logic_vector(VAL_HEADS*16-1 downto 0);
  signal sn_w : std_logic_vector(DIM*16-1 downto 0);
  signal sc_dt_e, sc_a_e, sn_exp : signed(7 downto 0);
  signal st_busy, st_err : std_logic;
  signal state_base, const_base : std_logic_vector(ADDR_W-1 downto 0);

  -- ---- AXI ---------------------------------------------------------------
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

  -- ---- the images --------------------------------------------------------
  -- Every region has its own generator, distinct in form, so a mover that
  -- wrote one region over another cannot read back consistent bytes.
  function f_st(i : natural) return std_logic_vector is     -- loaded state
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for ln in 0 to RECUR_LANES-1 loop
      v((ln+1)*16-1 downto ln*16) :=
        std_logic_vector(to_unsigned((i*7 + ln*3001 + 11) mod 65536, 16));
    end loop;
    return v;
  end function;
  function g_st(i : natural) return std_logic_vector is     -- written state
    variable v : std_logic_vector(WBITS-1 downto 0);
  begin
    for ln in 0 to RECUR_LANES-1 loop
      v((ln+1)*16-1 downto ln*16) :=
        std_logic_vector(to_unsigned((i*13 + ln*977 + 5) mod 65536, 16));
    end loop;
    return v;
  end function;
  function f_ex(i : natural) return integer is
  begin return ((i*3 + 17) mod 128) - 64; end function;
  function g_ex(i : natural) return integer is
  begin return ((i*5 + 29) mod 128) - 64; end function;
  -- conv region: 16-bit word w = slot*QKVN + channel
  function f_cv(w : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((w*11 + 101) mod 65536, 16));
  end function;
  -- this token's qkv column, by channel
  function f_q(ch : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((ch*17 + 202) mod 65536, 16));
  end function;
  -- constants image, word w
  function f_cn(w : natural) return std_logic_vector is
    variable si : natural;
  begin
    if w < CW_WORDS then
      return std_logic_vector(to_unsigned((w*19 + 303) mod 65536, 16));
    end if;
    si := w - CW_WORDS;
    if si < SB_EXP + 6 then
      if si >= SB_EXP then
        return std_logic_vector(to_signed(((si*7 + 40) mod 128) - 64, 16));
      end if;
      return std_logic_vector(to_unsigned((si*23 + 404) mod 65536, 16));
    end if;
    return x"0000";
  end function;
  function ch_of(seg : integer; grp, ln : natural) return natural is
  begin
    if seg = 0 then return grp*CONV_LANES + ln;
    elsif seg = 1 then return KEY_CH + grp*CONV_LANES + ln;
    else return 2*KEY_CH + grp*CONV_LANES + ln; end if;
  end function;

  -- ---- the slave's memory, as SHARED VARIABLES ---------------------------
  -- Not signals.  A signal array of STATE_BEATS x AXI_DW std_logic is ~8.8M
  -- scalar signals at 9B, and GHDL charges ~228 bytes per scalar signal
  -- (docs/WORKLOG.md, the 46 GB `stmem` finding).  Variables cost the bits.
  type sarr_t is array (0 to STATE_BEATS-1) of std_logic_vector(AXI_DW-1 downto 0);
  type carr_t is array (0 to CONST_BEATS-1) of std_logic_vector(AXI_DW-1 downto 0);
  shared variable smem : sarr_t;
  shared variable cmem : carr_t;
  shared variable n_cwr : natural := 0;    -- W beats into the const region
  signal stall_en : boolean := false;      -- pass 2: every channel stalls

  -- ---- phase accounting --------------------------------------------------
  type ph_t is (PH_IDLE, PH_LD_MANT, PH_LD_EXP, PH_LD_CONV, PH_LD_CONST,
                PH_RUN, PH_SEQ, PH_SV_MANT, PH_SV_EXP, PH_SV_CONV);
  type cnt_t is array (ph_t) of natural;
  signal ph_cnt : cnt_t := (others => 0);
  signal is_save : std_logic := '0';
  signal n_ar, n_rbeat, n_rstarve, n_rback, n_aw, n_wbeat, n_wstall,
         n_widle, n_b, n_coinc : natural := 0;
  signal job_cycles : natural := 0;

  -- which region the most recent address handshake named
  signal st_sel : std_logic_vector(1 downto 0) := "00";
begin
  clk <= not clk after 5 ns;
  state_base <= std_logic_vector(to_unsigned(SBASE, ADDR_W));
  const_base <= std_logic_vector(to_unsigned(CBASE, ADDR_W));

  u_js : entity work.gdn_job_seq
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM, KEY_HEADS => KEY_HEADS,
                KCONV => KCONV, CONV_LANES => CONV_LANES, LAYERS => LAYERS)
    port map(clk => clk, rst => rst,
             start => start, layer => LAYER,
             busy => js_busy, done => js_done, err => js_err,
             ss_load_start => js_ld, ss_save_start => js_sv,
             ss_layer => js_layer, ss_done => js_sdone, ss_err => js_serr,
             cvw_en => js_cvw_en, cvw_seg => js_cvw_seg,
             cvw_grp => js_cvw_grp, cvw_data => js_cvw_data,
             b_start => js_b_start, b_busy => b_busy,
             q_seg => js_q_seg, q_grp => js_q_grp, q_data => js_q_data);

  -- the one register stage, as llama_top's qcol_p
  qcol_p : process(clk) is
  begin
    if rising_edge(clk) then
      for ln in 0 to CONV_LANES-1 loop
        js_q_data((ln+1)*16-1 downto ln*16) <= f_q(ch_of(js_q_seg, js_q_grp, ln));
      end loop;
    end if;
  end process;

  u_st : entity work.gdn_state_store
    generic map(VAL_HEADS => VAL_HEADS, DIM => DIM, RECUR_LANES => RECUR_LANES,
                LAYERS => LAYERS, KEY_HEADS => KEY_HEADS, KCONV => KCONV,
                CONV_LANES => CONV_LANES,
                STYLE => "block", EXP_STYLE => "distributed",
                CONV_STYLE => "block",
                MANT_BYTES => MANT_BYTES, EXP_BYTES => EXP_BYTES,
                CONV_BYTES => CONV_BYTES, LAYER_STRIDE => LAYER_STRIDE,
                CONST_EN => CONST_EN, CONST_STRIDE => CONST_STRIDE,
                CONST_BYTES => CONST_BYTES,
                AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT,
                PIPE => PIPE, WIDE => WIDE, NWIDE => NWIDE)
    port map(clk => clk, rst => rst,
             load_start => js_ld, save_start => js_sv,
             layer => js_layer, state_base => state_base,
             const_base => const_base,
             busy => st_busy, done => js_sdone, err => js_serr,
             st_ren => st_ren, st_rhead => st_rhead, st_rcol => st_rcol,
             st_rgrp => st_rgrp, st_rdata => st_rdata,
             st_wen => st_wen, st_whead => st_whead, st_wcol => st_wcol,
             st_wgrp => st_wgrp, st_wdata => st_wdata,
             se_rhead => se_rhead, se_rcol => se_rcol, se_rdata => se_rdata,
             se_wen => se_wen, se_whead => se_whead, se_wcol => se_wcol,
             se_wdata => se_wdata,
             cv_seg => cv_seg, cv_grp => cv_grp, cv_x => cv_x,
             cvw_en => js_cvw_en, cvw_seg => js_cvw_seg, cvw_grp => js_cvw_grp,
             cvw_data => js_cvw_data, tok_adv => '0',
             cw_seg => cv_seg, cw_grp => cv_grp, cw_w => cw_w, cw_exp => cw_exp,
             sc_dt_m => sc_dt_m, sc_a_m => sc_a_m, sn_w => sn_w,
             sc_dt_e => sc_dt_e, sc_a_e => sc_a_e, sn_exp => sn_exp,
             r_arvalid => arvalid, r_arready => arready, r_araddr => araddr,
             r_arlen => arlen, r_arsize => arsize, r_arburst => arburst,
             r_rvalid => rvalid, r_rready => rready, r_rdata => rdata,
             r_rlast => rlast, r_rresp => rresp,
             w_awvalid => awvalid, w_awready => awready, w_awaddr => awaddr,
             w_awlen => awlen, w_awsize => awsize, w_awburst => awburst,
             w_wvalid => wvalid, w_wready => wready, w_wdata => wdata,
             w_wstrb => wstrb, w_wlast => wlast,
             w_bvalid => bvalid, w_bready => bready, w_bresp => bresp);

  -- ================= the AXI3 slave: pipelined latency, full rate =========
  slave : process(clk) is
    type qent_t is record
      beat : natural; len : natural; t : natural; live : boolean; cst : boolean;
    end record;
    constant QD : natural := 32;
    type q_t is array (0 to QD-1) of qent_t;
    variable rq, wq : q_t := (others => (0, 0, 0, false, false));
    variable rh, rt, wh, wt : natural := 0;     -- head (push), tail (pop)
    type bq_t is array (0 to QD-1) of natural;
    variable bq : bq_t := (others => 0);
    variable bh, bt : natural := 0;
    variable a, b : natural;
    variable gap : natural := 0;
    variable cst : boolean;
    variable now : natural := 0;
    variable seed : unsigned(31 downto 0) := x"5EED1234";
    variable rnd_ar, rnd_aw, rnd_w, rnd_r, rnd_b : natural := 1;
    -- Long stalls, so a save path's assembly buffers actually fill: a 1/3
    -- per-cycle stall never holds W for the 16+ cycles a WPB=16 mover
    -- needs to overrun.  MEASURED: mutant M3 (assembly overrun) survived
    -- the random stalls alone.
    variable wlong, awlong, blong : natural := 0;
    -- AR synchronised to the RLAST beat, so an AR accept and an RLAST
    -- accept land on ONE edge as often as the mover allows.  That
    -- coincidence is the one the mover's `outst` fold exists for, and a
    -- random stall reaches it with probability ~(1/4)^14.  MEASURED:
    -- mutant M9 (fold removed) survived the random stalls alone.
    variable ar_ok : boolean;
    variable nv, nl : boolean;      -- rvalid / rlast in the coming cycle
    -- xorshift32: shifts and xors only.  MEASURED: the 64-bit LCG the
    -- other benches use costs ~85 s of GHDL time over the stalled pass.
    impure function nxt return natural is
    begin
      seed := seed xor shift_left(seed, 13);
      seed := seed xor shift_right(seed, 17);
      seed := seed xor shift_left(seed, 5);
      return to_integer(seed(30 downto 0));
    end function;
  begin
    if rising_edge(clk) then
      now := now + 1;
      if stall_en then
        rnd_ar := nxt mod 4; rnd_aw := nxt mod 4; rnd_w := nxt mod 3;
        rnd_r := nxt mod 5; rnd_b := nxt mod 3;
        if wlong > 0 then wlong := wlong - 1; rnd_w := 0;
        elsif nxt mod 1500 = 0 then wlong := 48; end if;
        if awlong > 0 then awlong := awlong - 1; rnd_aw := 0;
        elsif nxt mod 1700 = 0 then awlong := 48; end if;
        -- B withheld long enough that MAXOUT throttles AW and W catches
        -- up: the only way to reach a W-ahead-of-AW defect (mutant M7).
        if blong > 0 then blong := blong - 1; rnd_b := 0;
        elsif nxt mod 1100 = 0 then blong := 96; end if;
        -- AR is accepted only on a cycle in which an RLAST beat is being
        -- presented (or when nothing is in flight, so it cannot deadlock).
      else
        rnd_ar := 1; rnd_aw := 1; rnd_w := 1; rnd_r := 1; rnd_b := 1;
        ar_ok := true;
      end if;
      -- ---- R ----
      nv := rvalid = '1'; nl := rlast = '1';
      if rvalid = '1' and rready = '0' then
        null;                                   -- hold the beat
      else
        if rvalid = '1' then n_rbeat <= n_rbeat + 1; end if;
        rvalid <= '0'; nv := false;
        if gap > 0 then
          gap := gap - 1;
        elsif rnd_r = 0 then
          null;                                   -- a random R bubble
        elsif rq(rt).live and now >= rq(rt).t then
          if rq(rt).cst then rdata <= cmem(rq(rt).beat);
          else rdata <= smem(rq(rt).beat); end if;
          rvalid <= '1'; nv := true;
          rlast  <= '1' when rq(rt).len = 1 else '0';
          nl := rq(rt).len = 1;
          gap := RD_GAP;
          if rq(rt).len = 1 then
            rq(rt).live := false; rt := (rt + 1) mod QD;
          else
            rq(rt).beat := rq(rt).beat + 1; rq(rt).len := rq(rt).len - 1;
          end if;
        end if;
      end if;
      -- ---- AR ----
      -- `arready` for the NEXT cycle is decided from the beat the R block
      -- above has just scheduled for that cycle, so an RLAST beat and an
      -- AR accept are offered on the same edge whenever the mover's RREADY
      -- is up.
      if stall_en then
        ar_ok := (not rq(rt).live) or (nv and nl) or ((nxt mod 512) = 0);
      end if;
      arready <= '1' when rnd_ar /= 0 and ar_ok and not rq((rh + 1) mod QD).live else '0';
      if arvalid = '1' and arready = '1' then
        a := to_integer(unsigned(araddr));
        if a >= SREG and a < SREG + LAYER_STRIDE then
          b := (a - SREG) / BPB; cst := false;
        elsif a >= CREG and a < CREG + CONST_STRIDE then
          b := (a - CREG) / BPB; cst := true;
        else
          report "tb_bmover_phases: AR outside both regions: " & integer'image(a)
            severity failure;
        end if;
        rq(rh) := (b, to_integer(unsigned(arlen)) + 1, now + RD_LAT, true, cst);
        rh := (rh + 1) mod QD;
        n_ar <= n_ar + 1;
      end if;
      if rready = '1' and rvalid = '0' then n_rstarve <= n_rstarve + 1; end if;
      if arvalid = '1' and arready = '1' and rvalid = '1' and rready = '1'
         and rlast = '1' then n_coinc <= n_coinc + 1; end if;
      if rvalid = '1' and rready = '0' then n_rback <= n_rback + 1; end if;
      -- ---- AW ----
      awready <= '1' when rnd_aw /= 0 and not wq((wh + 1) mod QD).live else '0';
      if awvalid = '1' and awready = '1' then
        a := to_integer(unsigned(awaddr));
        if a >= SREG and a < SREG + LAYER_STRIDE then
          b := (a - SREG) / BPB; cst := false;
        elsif a >= CREG and a < CREG + CONST_STRIDE then
          b := (a - CREG) / BPB; cst := true;
        else
          report "tb_bmover_phases: AW outside both regions: " & integer'image(a)
            severity failure;
        end if;
        wq(wh) := (b, to_integer(unsigned(awlen)) + 1, now, true, cst);
        wh := (wh + 1) mod QD;
        n_aw <= n_aw + 1;
      end if;
      -- ---- W ----
      wready <= '1' when rnd_w /= 0 else '0';
      if wvalid = '1' and wready = '1' then
        assert wq(wt).live
          report "tb_bmover_phases: W beat with no outstanding AW" severity failure;
        if wq(wt).cst then
          cmem(wq(wt).beat) := wdata; n_cwr := n_cwr + 1;
        else
          smem(wq(wt).beat) := wdata;
        end if;
        n_wbeat <= n_wbeat + 1;
        if wq(wt).len = 1 then
          assert wlast = '1' report "tb_bmover_phases: burst without WLAST"
            severity failure;
          wq(wt).live := false; wt := (wt + 1) mod QD;
          bq(bh) := now + B_LAT; bh := (bh + 1) mod QD;
        else
          wq(wt).beat := wq(wt).beat + 1; wq(wt).len := wq(wt).len - 1;
        end if;
      end if;
      if wvalid = '1' and wready = '0' then n_wstall <= n_wstall + 1; end if;
      -- ---- B ----
      if bvalid = '1' and bready = '1' then
        bvalid <= '0'; bt := (bt + 1) mod QD; n_b <= n_b + 1;
      elsif bvalid = '0' and bt /= bh and now >= bq(bt) and rnd_b /= 0 then
        bvalid <= '1';
      end if;
    end if;
  end process;

  -- ================= phase accounting =====================================
  acct : process(clk) is
    variable p : ph_t;
    variable a : natural;
    function region_of(a : natural) return std_logic_vector is
    begin
      if a >= CREG then return "11";
      elsif a >= SREG + MANT_BYTES + EXP_BYTES then return "10";
      elsif a >= SREG + MANT_BYTES then return "01";
      else return "00"; end if;
    end function;
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
      if js_ld = '1' then is_save <= '0'; st_sel <= "00"; end if;
      if js_sv = '1' then is_save <= '1'; st_sel <= "00"; end if;
      if arvalid = '1' and arready = '1' then
        st_sel <= region_of(to_integer(unsigned(araddr)));
      end if;
      if awvalid = '1' and awready = '1' then
        st_sel <= region_of(to_integer(unsigned(awaddr)));
      end if;
      if js_busy = '0' then
        p := PH_IDLE;
      elsif st_busy = '1' then
        if is_save = '0' then
          case st_sel is
            when "01" => p := PH_LD_EXP;
            when "10" => p := PH_LD_CONV;
            when "11" => p := PH_LD_CONST;
            when others => p := PH_LD_MANT;
          end case;
        else
          case st_sel is
            when "01" => p := PH_SV_EXP;
            when "10" => p := PH_SV_CONV;
            when others => p := PH_SV_MANT;
          end case;
        end if;
      elsif b_busy = '1' then
        p := PH_RUN;
      else
        p := PH_SEQ;
      end if;
      ph_cnt(p) <= ph_cnt(p) + 1;
      if js_busy = '1' then job_cycles <= job_cycles + 1; end if;
      if js_busy = '1' and is_save = '1' and st_busy = '1'
         and wvalid = '0' then n_widle <= n_widle + 1; end if;
    end if;
  end process;

  -- ================= the stand-in block, and the checks ===================
  stim : process is
    variable nchk, nfail : natural := 0;
    procedure chk(cond : boolean; msg : string) is
    begin
      nchk := nchk + 1;
      if not cond then
        nfail := nfail + 1;
        if nfail <= 20 then
          report "tb_bmover_phases: MISMATCH " & msg severity error;
        end if;
      end if;
    end procedure;
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;
    -- ONE JOB.  `pass` 0 loads the f_* images and writes the g_* ones;
    -- pass 1 loads what pass 0 saved and writes f_* back.
    variable pass1_cycles : natural := 0;
    procedure run_job(pass : natural) is
      variable i, w, ch : natural;
      variable v16 : std_logic_vector(15 downto 0);
      variable run_left : integer;
      impure function exp_st(i : natural) return std_logic_vector is
      begin if pass = 0 then return f_st(i); else return g_st(i); end if; end;
      impure function new_st(i : natural) return std_logic_vector is
      begin if pass = 0 then return g_st(i); else return f_st(i); end if; end;
      impure function exp_ex(i : natural) return integer is
      begin if pass = 0 then return f_ex(i); else return g_ex(i); end if; end;
      impure function new_ex(i : natural) return integer is
      begin if pass = 0 then return g_ex(i); else return f_ex(i); end if; end;
      -- conv word w as the load should deliver it: pass 1 sees pass 0's
      -- refilled column in slot 0.
      impure function exp_cv(w : natural) return std_logic_vector is
      begin
        if pass > 0 and w < QKVN then return f_q(w); else return f_cv(w); end if;
      end;
    begin
      -- ---- the job ----
      start <= '1'; tick; start <= '0';
      -- wait for the block to be started
      wait until rising_edge(clk) and js_b_start = '1';
      b_busy <= '1';
      tick;
      -- The stand-in walk: every state word is read and, two edges later,
      -- checked and rewritten; every exponent read (combinational) and
      -- rewritten; every tap group and weight group read and checked.
      run_left := B_RUN;
      for n in 0 to NST + 2 loop
        -- issue read of word n
        if n < NST then
          st_ren <= '1';
          st_rhead <= n / (DIM*NBR); st_rcol <= (n / NBR) mod DIM; st_rgrp <= n mod NBR;
        else
          st_ren <= '0';
        end if;
        -- check word n-2, write it back with the new pattern
        if n >= 2 and n-2 < NST then
          i := n - 2;
          chk(st_rdata = exp_st(i), "state word " & integer'image(i) & " after load");
          st_wen <= '1';
          st_whead <= i / (DIM*NBR); st_wcol <= (i / NBR) mod DIM; st_wgrp <= i mod NBR;
          st_wdata <= new_st(i);
        else
          st_wen <= '0';
        end if;
        -- exponents: address n, check n-1 (combinational read, one edge)
        if n < NEXP then
          se_rhead <= n / DIM; se_rcol <= n mod DIM;
        end if;
        if n >= 1 and n-1 < NEXP then
          i := n - 1;
          chk(to_integer(se_rdata) = exp_ex(i), "exponent " & integer'image(i) & " after load");
          se_wen <= '1'; se_whead <= i / DIM; se_wcol <= i mod DIM;
          se_wdata <= to_signed(new_ex(i), 8);
        else
          se_wen <= '0';
        end if;
        -- taps and weights: (seg, grp) walk, two-edge contract
        if n < 2*NG_K + NG_V then
          if n < NG_K then cv_seg <= 0; cv_grp <= n;
          elsif n < 2*NG_K then cv_seg <= 1; cv_grp <= n - NG_K;
          else cv_seg <= 2; cv_grp <= n - 2*NG_K; end if;
        end if;
        if n >= 2 and n-2 < 2*NG_K + NG_V then
          i := n - 2;
          for k in 0 to NTAP-1 loop
            for ln in 0 to CONV_LANES-1 loop
              if i < NG_K then ch := ch_of(0, i, ln);
              elsif i < 2*NG_K then ch := ch_of(1, i - NG_K, ln);
              else ch := ch_of(2, i - 2*NG_K, ln); end if;
              w := k*QKVN + ch;
              chk(cv_x(k*CONV_LANES*16 + (ln+1)*16-1 downto k*CONV_LANES*16 + ln*16) = exp_cv(w),
                  "tap k=" & integer'image(k) & " group " & integer'image(i)
                  & " lane " & integer'image(ln) & " after load");
            end loop;
          end loop;
          if CONST_EN then
            for t in 0 to KCONV-1 loop
              for ln in 0 to CONV_LANES-1 loop
                if i < NG_K then ch := ch_of(0, i, ln);
                elsif i < 2*NG_K then ch := ch_of(1, i - NG_K, ln);
                else ch := ch_of(2, i - 2*NG_K, ln); end if;
                w := t*QKVN + ch;
                chk(cw_w(t*CONV_LANES*16 + (ln+1)*16-1 downto t*CONV_LANES*16 + ln*16) = f_cn(w),
                    "conv weight t=" & integer'image(t) & " group " & integer'image(i)
                    & " lane " & integer'image(ln) & " after load");
              end loop;
            end loop;
          end if;
        end if;
        tick; run_left := run_left - 1;
      end loop;
      st_ren <= '0'; st_wen <= '0'; se_wen <= '0';
      if CONST_EN then
        for h in 0 to VAL_HEADS-1 loop
          chk(sc_dt_m((h+1)*16-1 downto h*16) = f_cn(CW_WORDS + SB_DT + h), "dt bias " & integer'image(h));
          chk(sc_a_m((h+1)*16-1 downto h*16) = f_cn(CW_WORDS + SB_A + h), "A " & integer'image(h));
        end loop;
        for c in 0 to DIM-1 loop
          chk(sn_w((c+1)*16-1 downto c*16) = f_cn(CW_WORDS + SB_NW + c), "norm w " & integer'image(c));
        end loop;
        for s in 0 to 2 loop
          v16 := f_cn(CW_WORDS + SB_EXP + s);
          chk(cw_exp((s+1)*8-1 downto s*8) = v16(7 downto 0), "cw_exp seg " & integer'image(s));
        end loop;
        v16 := f_cn(CW_WORDS + SB_EXP + 3); chk(std_logic_vector(sc_dt_e) = v16(7 downto 0), "dt_e");
        v16 := f_cn(CW_WORDS + SB_EXP + 4); chk(std_logic_vector(sc_a_e) = v16(7 downto 0), "a_e");
        v16 := f_cn(CW_WORDS + SB_EXP + 5); chk(std_logic_vector(sn_exp) = v16(7 downto 0), "w_exp");
      end if;
      assert run_left > 0
        report "tb_bmover_phases: the check walk is longer than B_RUN; raise B_RUN"
        severity failure;
      tick(run_left - 1);           -- busy for exactly B_RUN edges
      b_busy <= '0';
      tick;

      -- ---- the save ----
      wait until rising_edge(clk) and js_done = '1';
      tick(2);
      chk(js_err = '0', "job error flag");

      -- ---- what landed in HBM ----
      for ii in 0 to NST-1 loop
        chk(smem(MANT_B0 + (ii*WBITS/8) / BPB)
              ((((ii*WBITS/8) mod BPB)*8) + WBITS - 1 downto ((ii*WBITS/8) mod BPB)*8) = new_st(ii),
            "saved state word " & integer'image(ii));
      end loop;
      for ii in 0 to NEXP-1 loop
        chk(smem(EXP_B0 + ii / BPB)(((ii mod BPB)+1)*8-1 downto (ii mod BPB)*8)
              = std_logic_vector(to_signed(new_ex(ii), 8)),
            "saved exponent " & integer'image(ii));
      end loop;
      -- conv: slot 0 (the oldest, phase 0) now holds this token's column;
      -- slots 1.. hold the image.
      for ww in 0 to CONV_WORDS-1 loop
        if ww < QKVN then v16 := f_q(ww); else v16 := f_cv(ww); end if;
        chk(smem(CONV_B0 + (2*ww) / BPB)((((2*ww) mod BPB)/2 + 1)*16-1 downto ((2*ww) mod BPB)/2*16) = v16,
            "saved conv word " & integer'image(ww));
      end loop;
      chk(n_cwr = 0, "the save wrote " & integer'image(n_cwr) & " beats into the const region");
      for ww in 0 to CONST_WORDS-1 loop
        chk(cmem((2*ww) / BPB)((((2*ww) mod BPB)/2 + 1)*16-1 downto ((2*ww) mod BPB)/2*16) = f_cn(ww),
            "const word " & integer'image(ww) & " changed");
      end loop;

    end procedure;
  begin
    -- ---- the images ----
    for bt in 0 to STATE_BEATS-1 loop smem(bt) := (others => '0'); end loop;
    for ii in 0 to NST-1 loop
      smem(MANT_B0 + (ii*WBITS/8) / BPB)
        ((((ii*WBITS/8) mod BPB)*8) + WBITS - 1 downto ((ii*WBITS/8) mod BPB)*8)
        := f_st(ii);
    end loop;
    for ii in 0 to NEXP-1 loop
      smem(EXP_B0 + ii / BPB)(((ii mod BPB)+1)*8-1 downto (ii mod BPB)*8)
        := std_logic_vector(to_signed(f_ex(ii), 8));
    end loop;
    for ww in 0 to CONV_WORDS-1 loop
      smem(CONV_B0 + (2*ww) / BPB)((((2*ww) mod BPB)/2 + 1)*16-1 downto ((2*ww) mod BPB)/2*16)
        := f_cv(ww);
    end loop;
    for bt in 0 to CONST_BEATS-1 loop cmem(bt) := (others => '0'); end loop;
    for ww in 0 to CONST_WORDS-1 loop
      cmem((2*ww) / BPB)((((2*ww) mod BPB)/2 + 1)*16-1 downto ((2*ww) mod BPB)/2*16)
        := f_cn(ww);
    end loop;

    rst <= '1'; tick(4); rst <= '0'; tick(2);

    -- ---- pass 1: the account ----
    run_job(0);
    pass1_cycles := job_cycles;
    -- ---- the account ----
    report "BMOVER_CFG MAXOUT=" & integer'image(MAXOUT) & " MAXB=" & integer'image(MAXB)
         & " RD_LAT=" & integer'image(RD_LAT) & " B_LAT=" & integer'image(B_LAT)
         & " RD_GAP=" & integer'image(RD_GAP) & " PIPE=" & boolean'image(PIPE)
         & " WIDE=" & boolean'image(WIDE) & " NWIDE=" & boolean'image(NWIDE)
         & " B_RUN=" & integer'image(B_RUN);
    report "BMOVER_PHASE ld_mant " & integer'image(ph_cnt(PH_LD_MANT));
    report "BMOVER_PHASE ld_exp " & integer'image(ph_cnt(PH_LD_EXP));
    report "BMOVER_PHASE ld_conv " & integer'image(ph_cnt(PH_LD_CONV));
    report "BMOVER_PHASE ld_const " & integer'image(ph_cnt(PH_LD_CONST));
    report "BMOVER_PHASE run " & integer'image(ph_cnt(PH_RUN));
    report "BMOVER_PHASE seq " & integer'image(ph_cnt(PH_SEQ));
    report "BMOVER_PHASE sv_mant " & integer'image(ph_cnt(PH_SV_MANT));
    report "BMOVER_PHASE sv_exp " & integer'image(ph_cnt(PH_SV_EXP));
    report "BMOVER_PHASE sv_conv " & integer'image(ph_cnt(PH_SV_CONV));
    report "BMOVER_TOTAL " & integer'image(job_cycles);
    report "BMOVER_AXI ar=" & integer'image(n_ar) & " rbeats=" & integer'image(n_rbeat)
         & " r_starved=" & integer'image(n_rstarve) & " r_backpressured=" & integer'image(n_rback)
         & " aw=" & integer'image(n_aw) & " wbeats=" & integer'image(n_wbeat)
         & " w_stalled=" & integer'image(n_wstall) & " w_idle_in_save=" & integer'image(n_widle)
         & " b=" & integer'image(n_b);
    chk(ph_cnt(PH_LD_MANT) + ph_cnt(PH_LD_EXP) + ph_cnt(PH_LD_CONV) + ph_cnt(PH_LD_CONST)
        + ph_cnt(PH_RUN) + ph_cnt(PH_SEQ) + ph_cnt(PH_SV_MANT) + ph_cnt(PH_SV_EXP)
        + ph_cnt(PH_SV_CONV) = job_cycles, "phases sum to the job");
    chk(ph_cnt(PH_RUN) = B_RUN, "run phase is the stand-in's busy");
    chk(ph_cnt(PH_RUN) = B_RUN, "run phase is the stand-in's busy");
    if MAX_CYCLES > 0 then
      chk(job_cycles <= MAX_CYCLES, "job took " & integer'image(job_cycles)
          & " cycles, limit " & integer'image(MAX_CYCLES));
    end if;

    -- ---- TRACK BNARROW: the per-phase bound.  See the generic's comment. --
    -- Reported as well as checked, so a run that is merely SLOWER than
    -- expected without breaching the bound is still visible in the log.
    if NWIDE and NBOUND then
      report "BNARROW_BOUND ld_exp " & integer'image(ph_cnt(PH_LD_EXP))
           & "/" & integer'image(4*EXP_BEATS + 256)
           & " ld_conv " & integer'image(ph_cnt(PH_LD_CONV))
           & "/" & integer'image(4*CONV_BEATS + 256)
           & " ld_const " & integer'image(ph_cnt(PH_LD_CONST))
           & "/" & integer'image(4*KONST_BEATS + 256)
           & " sv_exp " & integer'image(ph_cnt(PH_SV_EXP))
           & "/" & integer'image(4*EXP_BEATS + 256)
           & " sv_conv " & integer'image(ph_cnt(PH_SV_CONV))
           & "/" & integer'image(4*CONV_BEATS + 256);
      chk(ph_cnt(PH_LD_EXP) <= 4*EXP_BEATS + 256,
          "ld_exp " & integer'image(ph_cnt(PH_LD_EXP)) & " cycles for "
          & integer'image(EXP_BEATS) & " beats is not a beat-wide load");
      chk(ph_cnt(PH_LD_CONV) <= 4*CONV_BEATS + 256,
          "ld_conv " & integer'image(ph_cnt(PH_LD_CONV)) & " cycles for "
          & integer'image(CONV_BEATS) & " beats is not a beat-wide load");
      if CONST_EN then
        chk(ph_cnt(PH_LD_CONST) <= 4*KONST_BEATS + 256,
            "ld_const " & integer'image(ph_cnt(PH_LD_CONST)) & " cycles for "
            & integer'image(KONST_BEATS) & " beats is not a beat-wide load");
      end if;
      chk(ph_cnt(PH_SV_EXP) <= 4*EXP_BEATS + 256,
          "sv_exp " & integer'image(ph_cnt(PH_SV_EXP)) & " cycles for "
          & integer'image(EXP_BEATS) & " beats is not a beat-wide save");
      chk(ph_cnt(PH_SV_CONV) <= 4*CONV_BEATS + 256,
          "sv_conv " & integer'image(ph_cnt(PH_SV_CONV)) & " cycles for "
          & integer'image(CONV_BEATS) & " beats is not a beat-wide save");
    end if;

    -- ---- pass 2: the same job under back-pressure ----
    if STALL_PASS then
      stall_en <= true;
      tick(2);
      run_job(1);
      report "BMOVER_STALLED_PASS job_cycles_total=" & integer'image(job_cycles)
           & " w_stalled=" & integer'image(n_wstall)
           & " ar_rlast_coincidences=" & integer'image(n_coinc);
      chk(n_wstall > 0, "the stalling pass never stalled W");
      chk(n_coinc > 0, "the stalling pass never landed an AR accept on an RLAST");
    end if;

    if nfail = 0 then
      report "tb_bmover_phases: PASS, checks=" & integer'image(nchk)
           & " job_cycles=" & integer'image(pass1_cycles);
    else
      report "tb_bmover_phases: FAIL, " & integer'image(nfail) & " of "
           & integer'image(nchk) & " checks" severity failure;
    end if;
    finish;
  end process;
end architecture;
