-- rtl/gdn_conv_w_mem.vhd -- ONE GDN layer's CONV WEIGHTS, resident.
--
-- `gdn_conv` multiplies each of its KCONV taps by a learned per-channel
-- weight, `blk.L.ssm_conv1d.weight[KCONV][QKVN]`.  Those weights are
-- CONSTANTS of the model, not state: nothing on the card ever writes them
-- except the load that brings a layer in.  At the 9B shape they are
-- `4 x 8,192 x 16 bits = 65,536 bytes per layer`, and all 24 layers do not fit
-- beside the norm image (docs/2026-09-18_b-constants-path.md), so ONE layer
-- is resident here and `rtl/gdn_state_store.vhd` reloads it from HBM as the
-- fourth, load-only phase of its per-job sequence.
--
-- THIS IS `gdn_conv_tap_mem` WITH THREE THINGS REMOVED, AND NOTHING ADDED.
-- Read that file's header first: three rewrites were needed before Vivado
-- would build it as BRAM, and every one of the reasons applies here
-- unchanged.  What survives is the structure those rewrites arrived at --
-- one 2-D array per bank inside a `for ... generate`, ONE write port, ONE
-- read port, whole 16-bit words, the address computed once outside the
-- generate.  What is removed:
--
--   1. THE ROTATION.  The tap history rotates because a token retires its
--      oldest column; a weight is the same weight at every token, so bank b
--      holds tap `b / CONV_LANES` for the whole life of the layer and the
--      output wiring is a constant permutation.  No `phase`, no `tok_adv`,
--      no captured `rq_ph`.
--   2. THE UNIT WRITE PORT.  The conv unit reads weights and never writes
--      them.  The only writer is the mover, so the write side is one port
--      with no mux in front of it.
--   3. THE MOVER READ PORT.  A constant is never saved back, so the mover
--      that fills this memory only ever LOADS.  `gdn_state_axi`'s `m_r_data`
--      input is tied off by the store.  Dropping the port here means the one
--      read address is the unit's, unmuxed, which is the simplest thing a
--      BRAM can be handed.
--
-- KCONV SLOTS, NOT KCONV-1.  The tap history holds the previous KCONV-1
-- columns and the caller appends the current one; the weights are one per
-- tap INCLUDING the current tap, so there are KCONV of them and `r_w` is
-- `KCONV*CONV_LANES*16` wide -- the exact shape of `gdn_block`'s `cv_w`.
--
-- THE HBM IMAGE IS TAP-MAJOR: word `t*QKVN + ch` is tap t of channel ch,
-- with t = 0 the OLDEST tap and t = KCONV-1 the NEWEST (this token's
-- column), the order `gdn_conv` and llama_top's `cvdata_p` both use.  The
-- mover hands the flat word address across unchanged and the decomposition
-- below is the same one `gdn_conv_tap_mem` performs.  The GGUF tensor is
-- channel-major (`cw[ch*KCONV + t]`); the PACKER transposes it, so that the
-- RTL never does.
--
-- THE READ IS "REGISTERED ADDRESS, COMBINATIONAL DATA", exactly as the tap
-- history's: `r_seg`/`r_grp` are sampled on the rising edge and `r_w` is
-- valid in the following cycle, which is what `gdn_block`'s port comment
-- (:269-272) asks of `cv_w`.

--
-- ---- TRACK BNARROW 2026-09-20: THE BEAT-WIDE PORT ----------------------
-- MEASURED by sim/tb_bmover_phases.vhd at the 9B geometry, with the mantissa
-- mover already at one beat per cycle (PIPE+WIDE, commit 14fa888): the
-- constants phase costs `ld_const 33,069` cycles for 2,064 beats, i.e. 16
-- cycles per beat.  That is WPB, the number of 16-bit words in a 256-bit AXI
-- beat, and it is paid because `gdn_state_axi` can hand this memory only ONE
-- word per cycle through `m_w_*`.
--
-- `WIDE` is `gdn_conv_tap_mem`'s WIDE arm with the two things this file has
-- always lacked removed: there is no unit write and no mover read, so the one
-- write port takes only the two mover forms and the one read address is the
-- unit's, always.  READ THAT FILE'S HEADER for why the sub-group becomes a
-- bank axis instead of the bank word becoming GS times wider, and for the
-- DERIVED-not-MEASURED tile count; both arguments apply here unchanged, at
-- KCONV banks-of-lanes instead of KCONV-1.
--
-- The HBM image is TAP-MAJOR, so one beat is WPB consecutive words within ONE
-- tap, which is the property that lets a wide write enable exactly the banks
-- of that tap.  `QKVN mod WPB = 0` is refused below because a remainder would
-- make a beat straddle two taps, and that is silent rather than loud.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_conv_w_mem is
  generic(
    KCONV      : positive := 4;      -- model_cfg_pkg conv_kernel
    CONV_LANES : positive := 4;      -- gdn_block CONV_LANES
    KEY_CH     : positive := 2048;   -- KEY_HEADS*DIM: the q and the k segment
    VAL_CH     : positive := 4096;   -- VAL_HEADS*DIM: the v segment
    STYLE      : string   := "block"; -- "block" or "auto".  NOT "distributed".
    -- TRACK BNARROW 2026-09-20.  WIDE adds the sub-group bank axis and the
    -- `ww_*` port below, which moves WPB consecutive 16-bit words -- one AXI
    -- beat -- per cycle.  FALSE is the array as it was, to the character.
    WIDE       : boolean  := false;
    WPB        : positive := 16
  );
  port(
    clk : in std_logic;

    -- ---- the unit's port, shaped exactly like gdn_block's cv_seg/cv_grp ---
    -- Sampled on the rising edge; `r_w` is valid in the following cycle.
    -- The channel is `seg_base(seg) + grp*CONV_LANES + lane`, the same
    -- decomposition `gdn_conv_tap_mem` and llama_top's `cvdata_p` perform.
    r_seg  : in  integer range 0 to 2;
    r_grp  : in  natural range 0 to VAL_CH/CONV_LANES-1;
    -- Bit slice `(t*CONV_LANES + ln)*16 +: 16` is tap t, lane ln, for t in
    -- 0 .. KCONV-1, t = KCONV-1 the NEWEST.  This is `gdn_conv`'s `w_in`
    -- order verbatim.
    r_w    : out std_logic_vector(KCONV*CONV_LANES*16-1 downto 0);

    -- ---- the mover's write, flat 16-bit words within the layer -----------
    -- `addr = t*QKVN + ch`.  The ONLY write port.
    m_w_en   : in  std_logic;
    m_w_addr : in  natural range 0 to KCONV*(2*KEY_CH+VAL_CH)-1;
    m_w_data : in  std_logic_vector(15 downto 0);

    -- ---- the beat-wide mover write, WIDE only.  Idle otherwise. ----------
    -- Beat b is flat words b*WPB .. b*WPB+WPB-1, word q at bits q*16 +: 16.
    -- There is no wide READ because there is no mover read: a constant is
    -- never saved back.
    --
    -- THE BEAT RANGE IS A CEILING, NOT A DIVISION: a bare `WORDS/WPB-1` is a
    -- NULL RANGE at a bench shape below one beat, and a port range elaborates
    -- whether or not the generate that uses it is taken.
    ww_en   : in  std_logic := '0';
    ww_beat : in  natural
              range 0 to (KCONV*(2*KEY_CH+VAL_CH) + WPB - 1)/WPB - 1 := 0;
    ww_data : in  std_logic_vector(WPB*16-1 downto 0) := (others => '0')
  );
end entity;

architecture rtl of gdn_conv_w_mem is
  constant QKVN  : positive := 2*KEY_CH + VAL_CH;     -- total conv channels
  constant NGRP  : positive := QKVN / CONV_LANES;     -- groups in the store
  constant GW    : positive := CONV_LANES * 16;       -- bits in one group
  constant NBANK : positive := KCONV * CONV_LANES;    -- one 16-bit bank each

  -- ---- the WIDE arm's geometry, as in gdn_conv_tap_mem -----------------
  constant GS    : positive := (WPB + CONV_LANES - 1) / CONV_LANES;
  constant DW    : positive := (NGRP + GS - 1) / GS;
  constant BPS   : positive := (QKVN + WPB - 1) / WPB;   -- beats per tap
  constant NBW   : positive := KCONV * CONV_LANES * GS;

  -- ---- REFUSALS THAT RUN DURING ELABORATION ---------------------------
  -- Out-of-range `natural`s, not asserts: Vivado ignores
  -- `assert ... severity failure` in synthesis.  The NAME is the diagnostic.
  --
  -- Each segment must tile into whole groups, or `seg_base/CONV_LANES` is not
  -- an integer and the q, k and v regions overlap by a fraction of a group.
  constant bad_key_ch_not_group_aligned : natural := 0 - (KEY_CH mod CONV_LANES);
  constant bad_val_ch_not_group_aligned : natural := 0 - (VAL_CH mod CONV_LANES);
  -- The v segment is the widest, so `r_grp`'s declared range is v's.  A q or k
  -- segment WIDER than v would index past the end of the store, silently.
  constant bad_key_wider_than_val : natural := VAL_CH - KEY_CH;

  -- Gated, because these generics are legal at WIDE => false.
  function only_if(en : boolean; v : integer) return integer is
  begin
    if en then return v; else return 0; end if;
  end function;
  constant bad_wpb_not_multiple_of_lanes : natural
         := only_if(WIDE, 0 - (WPB mod CONV_LANES));
  constant bad_ngrp_not_multiple_of_gs : natural
         := only_if(WIDE, 0 - (NGRP mod GS));
  -- A TAP must tile into whole beats; see the header.
  constant bad_qkvn_not_multiple_of_wpb : natural
         := only_if(WIDE, 0 - (QKVN mod WPB));

  function chk_style(s : string) return string is
    variable bad : natural;
  begin
    if s = "block" or s = "auto" then
      return s;
    end if;
    -- NOT the literal -1: GHDL folds a literal at ANALYSIS time and then warns
    -- on every legal build.  `s'length` is a parameter and cannot be folded.
    bad := -s'length;
    return s;
  end function;

  constant STY : string(1 to STYLE'length) := chk_style(STYLE);

  -- The flat group of a (segment, group) pair: q | k | v.
  function gidx(seg : integer; grp : natural) return natural is
  begin
    if seg = 0 then
      return grp;
    elsif seg = 1 then
      return KEY_CH/CONV_LANES + grp;
    else
      return 2*KEY_CH/CONV_LANES + grp;
    end if;
  end function;

  -- The mover's flat word address, decomposed.  TAP-MAJOR: `addr = t*QKVN +
  -- channel`.  Divisions by constants; at the shipping shape both divisors
  -- are powers of two (QKVN 8,192 and CONV_LANES 4) and fold to shifts.
  function m_tap (a : natural) return natural is begin return a / QKVN; end;
  function m_grp (a : natural) return natural is
  begin return (a mod QKVN) / CONV_LANES; end;
  function m_lane(a : natural) return natural is
  begin return (a mod QKVN) mod CONV_LANES; end;
  function m_bank(a : natural) return natural is
  begin return m_tap(a) * CONV_LANES + m_lane(a); end;
  -- The WIDE arm's bank index of a flat word: (tap, lane, sub-group).
  function w_bank(a : natural) return natural is
  begin return (m_tap(a) * CONV_LANES + m_lane(a)) * GS
              + (m_grp(a) mod GS); end;

  signal ra_s  : natural range 0 to NGRP-1 := 0;
  signal mwg_s : natural range 0 to NGRP-1 := 0;
  signal mwb_s : natural range 0 to NBANK-1 := 0;

  attribute ram_style : string;
begin
  -- Addresses computed ONCE, outside the bank generate, so the divisions are
  -- shared rather than replicated NBANK times.
  ra_s  <= gidx(r_seg, r_grp);
  mwg_s <= m_grp(m_w_addr);
  mwb_s <= m_bank(m_w_addr);

  -- ================= KCONV*CONV_LANES banks, as they were =================
  gnarrow : if not WIDE generate
    type word_arr_t is array (0 to NBANK-1) of std_logic_vector(15 downto 0);
    -- ONE set of read registers, because there is one read port.
    signal rq : word_arr_t := (others => (others => '0'));
  begin
    -- ---- ONE BRAM PER BANK, AS A GENERATE, AND THAT IS NOT A STYLE CHOICE -
    -- Declaring the array inside the generate is what makes each bank plainly
    -- TWO-dimensional; as one `array of array of vector` Vivado dissolved the
    -- tap history into 393,216 registers.  See rtl/gdn_conv_tap_mem.vhd's
    -- header for the full sequence of refusals.
    gbank : for b in 0 to NBANK-1 generate
      -- Bank b holds tap `b / CONV_LANES`, lane `b mod CONV_LANES`, for good.
      type bank_t is array (0 to NGRP-1) of std_logic_vector(15 downto 0);
      signal m : bank_t := (others => (others => '0'));
      attribute ram_style of m : signal is STY;

      signal we : std_logic;
    begin
      we <= '1' when m_w_en = '1' and mwb_s = b else '0';

      pb : process(clk) is
      begin
        if rising_edge(clk) then
          if we = '1' then
            m(mwg_s) <= m_w_data;
          end if;
          rq(b) <= m(ra_s);
        end if;
      end process;
    end generate;

    -- ---- the unit read: NBANK words, in bank order ------------------------
    -- No rotation: bank `t*CONV_LANES + ln` IS tap t, lane ln, so the output
    -- is the bank registers laid end to end.  Written as a loop rather than a
    -- direct alias so the tap/lane order is stated where a reader looks for it.
    wire : process(rq) is
    begin
      for t in 0 to KCONV-1 loop
        for ln in 0 to CONV_LANES-1 loop
          r_w(t*GW + (ln+1)*16 - 1 downto t*GW + ln*16)
            <= rq(t*CONV_LANES + ln);
        end loop;
      end loop;
    end process;
  end generate;

  -- ================= KCONV*CONV_LANES*GS banks, one beat per cycle ========
  -- Bank (tap, lane, j) holds group `d*GS + j` of that tap and lane at depth
  -- d.  One read address (the unit's, always -- there is no mover read) and
  -- one write address into every bank.
  gwide : if WIDE generate
    type warr_t is array (0 to NBW-1) of std_logic_vector(15 downto 0);
    signal rqw  : warr_t := (others => (others => '0'));
    signal radw : natural range 0 to DW-1 := 0;
    signal wadw : natural range 0 to DW-1 := 0;
    signal jq_q : natural range 0 to GS-1 := 0;      -- unit's sub-group select
    signal wwtap : natural range 0 to KCONV-1;
    signal wwdep : natural range 0 to BPS-1;
  begin
    wwtap <= ww_beat / BPS;
    wwdep <= ww_beat mod BPS;

    radw <= ra_s / GS;
    wadw <= wwdep when ww_en = '1' else mwg_s / GS;

    gbank : for b in 0 to NBW-1 generate
      -- All three are static in this scope, so every slice below has constant
      -- bounds.  b = (TAP*CONV_LANES + LANE)*GS + JS.
      constant TAP  : natural := b / (CONV_LANES*GS);
      constant LANE : natural := (b / GS) mod CONV_LANES;
      constant JS   : natural := b mod GS;
      -- Word JS*CONV_LANES + LANE of a beat is this bank's word.
      constant BQ   : natural := JS*CONV_LANES + LANE;

      type bank_t is array (0 to DW-1) of std_logic_vector(15 downto 0);
      signal m : bank_t := (others => (others => '0'));
      attribute ram_style of m : signal is STY;

      signal we  : std_logic;
      signal wdt : std_logic_vector(15 downto 0);
    begin
      -- A WIDE write enables every bank of ONE tap; a narrow mover write
      -- enables ONE bank.  The wide port wins, and the two are never live
      -- together: one generic in gdn_state_store decides which.
      we <= '1' when (ww_en = '1' and wwtap = TAP)
                  or (ww_en = '0' and m_w_en = '1' and w_bank(m_w_addr) = b)
            else '0';
      wdt <= ww_data((BQ+1)*16-1 downto BQ*16) when ww_en = '1'
             else m_w_data;

      pb : process(clk) is
      begin
        if rising_edge(clk) then
          if we = '1' then
            m(wadw) <= wdt;
          end if;
          rqw(b) <= m(radw);
        end if;
      end process;
    end generate;

    -- ---- the unit read: one group of every tap and lane ------------------
    -- The sub-group select is captured WITH the data, so `r_w` is still "the
    -- group whose address was presented one cycle ago".
    wire : process(rqw, jq_q) is
    begin
      for t in 0 to KCONV-1 loop
        for ln in 0 to CONV_LANES-1 loop
          r_w(t*GW + (ln+1)*16 - 1 downto t*GW + ln*16)
            <= rqw((t*CONV_LANES + ln)*GS + jq_q);
        end loop;
      end loop;
    end process;

    ctl : process(clk) is
    begin
      if rising_edge(clk) then
        jq_q <= ra_s mod GS;
      end if;
    end process;
  end generate;
end architecture;
