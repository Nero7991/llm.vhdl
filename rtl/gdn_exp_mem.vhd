-- rtl/gdn_exp_mem.vhd -- ONE GDN layer's state EXPONENTS.
--
-- `VAL_HEADS x DIM` entries of 8 bits: 4,096 bytes at the 9B shape, which is
-- exactly `gdn_state_exp_bytes_per_layer` in the manifest arena.  This is
-- `semem` in `rtl/llama_top.vhd`, sized for ONE layer instead of all 24 for
-- the same reason the mantissa store is
-- (docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md).
--
-- IT CANNOT BE BRAM OR URAM, AND THAT IS NOT A CHOICE.  `rtl/gdn_block.vhd`
-- labels this port "state exponent table, COMBINATIONAL read" (:317) and means
-- it: `se_rhead`/`se_rcol` are driven combinationally from the recurrence
-- pipeline's own address (:632-633) and `se_rdata` is consumed on the SAME
-- edge (:1203, `rp_cse <= se_rdata` in the cycle `st_first_i` is high).  A
-- block RAM has a registered read and a URAM has a registered read; neither
-- can serve an asynchronous port.  This repository has the general lesson on
-- record at cost: `region_mem` inferred ZERO BRAM and 91,073 LUT because of a
-- single combinational read port, and the array's shape was never the cause.
--
-- So this is DISTRIBUTED RAM, deliberately, and the cost is real rather than
-- free.  `STYLE` is a generic so the census can be taken both ways rather
-- than the attribute being asserted to work -- Vivado's inference log has
-- been measured lying in both directions in this project, including
-- `[Synth 8-7186]` claiming `ram_style = "distributed"` was ignored for
-- objects that ARE `RAM32M16` in the same run's mapping report.
--
-- THE WRITE IS SYNCHRONOUS AND THE UNIT'S READ IS NOT.  That asymmetry is
-- what distributed RAM is, and it is also why read-during-write needs no
-- discussion here: an asynchronous read reflects the write the moment it
-- lands, which is the behaviour `llama_top`'s signal-based `semem` had.  The
-- MOVER's read is registered on the way out for a reason that has nothing to
-- do with the array; see the `m_r_data` port comment.
--
-- ---- TRACK BNARROW 2026-09-20: THE BEAT-WIDE PORT ----------------------
-- MEASURED by sim/tb_bmover_phases.vhd at the 9B geometry, with the mantissa
-- mover already at one beat per cycle (PIPE+WIDE, commit 14fa888): the
-- exponent phases cost `ld_exp 4,142` and `sv_exp 4,114` cycles for 128 beats
-- each, i.e. 32 cycles per beat.  That is WPB, the number of 8-bit words in a
-- 256-bit AXI beat, and it is paid because `gdn_state_axi` can only hand this
-- memory ONE word per cycle through `m_w_*`/`m_r_*`.  The array is not the
-- bound; the port width is.
--
-- `WIDE` adds `ww_*`/`wr_*`, which move a whole beat per cycle, and banks the
-- array WPB ways on the LOW bits of the flat byte index so that one beat is
-- exactly one word from each bank at one depth.  This is the same shape
-- `rtl/gdn_state_mem.vhd` already uses for the mantissas, and it is the shape
-- TRACK BMOVERSYN measured as 32 URAM288 with `[Synth 8-10226]` and
-- `[Synth 8-7186]` absent -- for THAT array.  This one is distributed RAM and
-- a different shape, so that census does NOT transfer; it is on the open list
-- in docs/debugging/2026-09-20_b-job-660k-cycles.md.
--
-- EVERY WRITE IN THE WIDE ARM IS A WHOLE 8-BIT WORD.  No sub-word slice with
-- computed bounds appears anywhere in it.  That is deliberate and it is the
-- reason the bank count is WPB rather than one: this repository has already
-- paid once for a variable-offset partial write, in
-- `rtl/gdn_conv_tap_mem.vhd`, where it produced ZERO BRAM and 8% of the part.
-- Banking costs depth; a partial write costs the inference.
--
-- THE NARROW MOVER PORTS SURVIVE IN THE WIDE ARM and keep their contract,
-- with one stated exception: `m_r_data` shares the one mover-side read
-- address with `wr_beat`, so it is meaningless in any cycle where `wr_en` is
-- high.  `rtl/gdn_state_store.vhd` drives both from ONE generic, so the mover
-- that uses `wr_*` is the same mover that leaves `m_r_*` idle and the two can
-- never be live together.  `rtl/gdn_state_mem.vhd` states the identical rule
-- for `r_en` against `wr_en`.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gdn_exp_mem is
  generic(
    VAL_HEADS : positive := 32;
    DIM       : positive := 128;
    -- "distributed" or "auto".  NOT "block" or "ultra": both have a
    -- registered read and cannot serve this port at all, so offering them
    -- would be offering a wrong answer.
    STYLE     : string   := "distributed";
    -- TRACK BNARROW 2026-09-20.  WIDE banks the array WPB ways on the low
    -- bits of the flat byte index, so `ww_*`/`wr_*` below move WPB
    -- consecutive bytes -- one AXI beat -- per cycle.  FALSE is the flat
    -- array as it was, to the character.
    WIDE      : boolean  := false;
    WPB       : positive := 32
  );
  port(
    clk : in std_logic;

    -- combinational read, matching gdn_block's se_* contract exactly
    r_head : in  natural range 0 to VAL_HEADS-1;
    r_col  : in  natural range 0 to DIM-1;
    r_data : out signed(7 downto 0);

    -- synchronous write
    w_en   : in  std_logic;
    w_head : in  natural range 0 to VAL_HEADS-1;
    w_col  : in  natural range 0 to DIM-1;
    w_data : in  signed(7 downto 0);

    -- the mover's port, 8-bit words, flat within the layer.  Separate from
    -- the unit's port because the caller arbitrates; see gdn_state_store.
    --
    -- `m_r_data` IS REGISTERED AND THE UNIT'S `r_data` IS NOT, AND THAT
    -- ASYMMETRY IS DELIBERATE.  `gdn_state_axi` registers the address it
    -- issues and then collects the word TWO edges later, because that is what
    -- `gdn_state_mem` (a block/ultra RAM) does.  Handing it an ASYNCHRONOUS
    -- read would present each word one edge EARLY, and since the mover walks
    -- a new address every cycle the word it collected would be the NEXT one:
    -- every saved exponent block shifted by exactly one byte, wrapping at the
    -- beat.  That is a wrong number, not a hang, and it is the same defect
    -- this project already paid for once on the mantissa path
    -- (docs/debugging/2026-09-02_gdn-state-dma.md, defect D2).
    --
    -- The flop costs 8 FF and changes nothing about the ARRAY: the read is
    -- still asynchronous out of the memory, with a register on the way out.
    -- The unit's port, which must stay asynchronous, is untouched.
    m_r_addr : in  natural range 0 to VAL_HEADS*DIM-1;
    m_r_data : out signed(7 downto 0);
    m_w_en   : in  std_logic;
    m_w_addr : in  natural range 0 to VAL_HEADS*DIM-1;
    m_w_data : in  signed(7 downto 0);

    -- ---- the beat-wide mover port, WIDE only.  Idle otherwise. -----------
    -- Beat b is bytes b*WPB .. b*WPB+WPB-1 of the flat index, byte j at bits
    -- j*8 +: 8, which is the order `gdn_state_axi` packs a beat.  `wr_data`
    -- is valid ONE cycle after `wr_beat`, the same two-edge contract
    -- `m_r_data` has and for the same reason.
    --
    -- THE BEAT RANGE IS A CEILING, NOT A DIVISION.  `VAL_HEADS*DIM/WPB-1` is
    -- a NULL RANGE at any bench shape smaller than one beat, and a port range
    -- is elaborated whether or not the generate that uses it is taken -- so
    -- the obvious form breaks every small-shape bench at WIDE => false too.
    ww_en   : in  std_logic := '0';
    ww_beat : in  natural range 0 to (VAL_HEADS*DIM + WPB - 1)/WPB - 1 := 0;
    ww_data : in  std_logic_vector(WPB*8-1 downto 0) := (others => '0');
    wr_en   : in  std_logic := '0';
    wr_beat : in  natural range 0 to (VAL_HEADS*DIM + WPB - 1)/WPB - 1 := 0;
    wr_data : out std_logic_vector(WPB*8-1 downto 0)
  );
end entity;

architecture rtl of gdn_exp_mem is
  constant N : positive := VAL_HEADS * DIM;
  -- Depth of ONE bank in the WIDE arm.  The ceiling keeps it a `positive` at
  -- a bench shape smaller than one beat, where the WIDE arm is not taken and
  -- the value is never used; a bare N/WPB would be 0 and refuse to elaborate
  -- at WIDE => false, which is the trap the port range above records.
  constant DEP : positive := (N + WPB - 1) / WPB;

  -- REFUSALS THAT RUN DURING ELABORATION, gated on WIDE so a narrow bench
  -- shape is not refused for a banking it never performs.  Out-of-range
  -- `natural`s, not asserts: Vivado ignores `assert ... severity failure`.
  function only_if(en : boolean; v : integer) return integer is
  begin
    if en then return v; else return 0; end if;
  end function;
  -- A beat must tile the array exactly.  A remainder would put part of a beat
  -- past the end of every bank, silently.
  constant bad_exp_bytes_not_multiple_of_wpb : natural
         := only_if(WIDE, 0 - (N mod WPB));

  type mem_t is array (0 to N-1) of signed(7 downto 0);
  type bnk_t is array (0 to DEP-1) of signed(7 downto 0);
  type byte_arr_t is array (0 to WPB-1) of signed(7 downto 0);

  -- Refuse a STYLE this port cannot honour, as an out-of-range `natural`
  -- rather than an assert: Vivado ignores `assert ... severity failure` in
  -- synthesis.  Assigned inside a branch rather than declared as a literal
  -- constant, because GHDL folds a literal at ANALYSIS time and then warns on
  -- every legal build.
  function chk_style(s : string) return string is
    variable bad : natural;
  begin
    if s = "distributed" or s = "auto" then
      return s;
    end if;
    bad := -s'length;
    return s;
  end function;

  constant STY : string(1 to STYLE'length) := chk_style(STYLE);

  attribute ram_style : string;
begin
  -- ================= the flat array, as it was ============================
  gflat : if not WIDE generate
    signal mem : mem_t := (others => (others => '0'));
    attribute ram_style of mem : signal is STY;
  begin
    wr_data <= (others => '0');

    -- The unit's read is asynchronous because gdn_block consumes it on the
    -- same edge it drives the address (:632-633 and :1203).  The mover's is
    -- registered because gdn_state_axi expects a two-edge memory; see the
    -- port comment.
    r_data   <= mem(r_head*DIM + r_col);

    p : process(clk) is
    begin
      if rising_edge(clk) then
        m_r_data <= mem(m_r_addr);
        -- The mover and the unit never write together: the caller gates the
        -- unit off while the mover owns the store, and gdn_state_store
        -- asserts that it does.  Written as elsif rather than as two ifs so
        -- that a violation is a lost write in ONE place rather than a race.
        if m_w_en = '1' then
          mem(m_w_addr) <= m_w_data;
        elsif w_en = '1' then
          mem(w_head*DIM + w_col) <= w_data;
        end if;
      end if;
    end process;
  end generate;

  -- ================= WPB banks, one beat per cycle ========================
  -- Bank k holds every byte whose flat index has `index mod WPB = k`, at
  -- depth `index / WPB`.  One beat is therefore exactly one byte from each
  -- bank at ONE depth, which is what makes the wide port a plain parallel
  -- access and not a shifter.
  --
  -- TWO ASYNCHRONOUS READ ADDRESSES, the same count the flat arm has: the
  -- UNIT's (`r_head`/`r_col`, which must stay combinational) and the MOVER's
  -- (`wr_beat` when the wide port is reading, `m_r_addr` otherwise -- they
  -- are the same mover and cannot both be live).  Distributed RAM serves
  -- several asynchronous read ports natively; this is the one memory in the
  -- store where that is true, and it is why the narrow mover read survives
  -- here without costing a third address.
  gwide : if WIDE generate
    signal ubyte, mbyte : byte_arr_t;
    signal rq           : byte_arr_t := (others => (others => '0'));
    signal udep, mdep   : natural range 0 to DEP-1;
    signal usel         : natural range 0 to WPB-1;
    signal msel, msel_q : natural range 0 to WPB-1 := 0;
    signal uidx, widx   : natural range 0 to N-1;
  begin
    uidx <= r_head*DIM + r_col;
    widx <= w_head*DIM + w_col;
    udep <= uidx / WPB;
    usel <= uidx mod WPB;
    -- THE MOVER'S ONE READ ADDRESS.  `wr_en` wins; see the header for why
    -- that does not make `m_r_data` wrong in any reachable cycle.
    mdep <= wr_beat when wr_en = '1' else m_r_addr / WPB;
    msel <= m_r_addr mod WPB;

    r_data   <= ubyte(usel);
    m_r_data <= rq(msel_q);

    gb : for k in 0 to WPB-1 generate
      signal bank : bnk_t := (others => (others => '0'));
      attribute ram_style of bank : signal is STY;
      signal we : std_logic;
      signal wd : signed(7 downto 0);
      signal wa : natural range 0 to DEP-1;
    begin
      ubyte(k) <= bank(udep);
      mbyte(k) <= bank(mdep);
      wr_data((k+1)*8-1 downto k*8) <= std_logic_vector(rq(k));

      -- PRIORITY: the wide mover, then the narrow mover, then the unit.  The
      -- last two are the flat arm's `elsif` written as a mux; the first is
      -- new and cannot coincide with either, because one generic in
      -- gdn_state_store decides which mover port is live.
      we <= '1' when ww_en = '1'
                  or (m_w_en = '1' and (m_w_addr mod WPB) = k)
                  or (ww_en = '0' and m_w_en = '0' and w_en = '1'
                      and (widx mod WPB) = k)
            else '0';
      wa <= ww_beat when ww_en = '1'
            else m_w_addr / WPB when m_w_en = '1'
            else widx / WPB;
      -- `k` is a generate constant, so this slice has STATIC bounds.  Every
      -- write in this arm is a whole 8-bit word; see the header.
      wd <= signed(ww_data((k+1)*8-1 downto k*8)) when ww_en = '1'
            else m_w_data when m_w_en = '1'
            else w_data;

      pb : process(clk) is
      begin
        if rising_edge(clk) then
          rq(k) <= mbyte(k);
          if we = '1' then
            bank(wa) <= wd;
          end if;
        end if;
      end process;
    end generate;

    -- The bank selector is captured WITH the data, so `m_r_data` is still
    -- "the byte at the address presented one cycle ago" and not the byte at
    -- whatever address the mover has moved on to.
    ps : process(clk) is
    begin
      if rising_edge(clk) then
        msel_q <= msel;
      end if;
    end process;
  end generate;
end architecture;
