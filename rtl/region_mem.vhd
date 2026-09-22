-- rtl/region_mem.vhd
-- THE CARD TOP'S REGION FILE.  TRACK CARDTOP, 2026-08-31, backlog row N3.
--
-- A drop-in replacement for llama_top's BEHAVIOURAL flat region array
-- (rtl/llama_top.vhd:1059-1341), implementing the identical port contract
-- over sized per-region BRAM banks instead of one NREGION*REGMAX array with
-- eight muxed client slots -- the structure that blocks Vivado elaboration
-- at the real shape.
--
-- THE CONTRACT, MEASURED from llama_top's `memp` and `elmux`:
--
--   * One element read port, one element write port, one LANES-wide group
--     read port with TWO operand regions, one LANES-wide group write port.
--     Element addresses are per-region: (region, address).
--   * READS ARE REGISTERED, ONE CYCLE.  An address driven in cycle k is
--     readable in cycle k+1, and the adapters' own address registers make
--     it two edges end to end.  Every adapter depends on this
--     (llama_top.vhd:1066-1073).
--   * A read in the same cycle as a write returns the PRE-WRITE data,
--     including a same-address collision, and including a group-read /
--     element-write cross collision.  llama_top's process reads the signal
--     before any assignment takes effect; so does this one.  Xilinx calls
--     it READ_FIRST.
--   * SIMULTANEOUS ELEMENT AND GROUP WRITES ARE A PRECONDITION VIOLATION,
--     not a tie.  llama_top performs BOTH (they are two assignments in one
--     process, so writes to different words both land, and the group wins a
--     same-word tie by being later).  This memory merges the two writers
--     into ONE write port -- Vivado will not infer a RAM otherwise, see the
--     note on the write statement -- so it can serve only one, and it
--     asserts rather than silently dropping the other.
--     THAT IS A REAL DIVERGENCE FROM llama_top, and it is safe only because
--     the case cannot arise: D issues one unit at a time, and MEASURED over
--     a full token there were ZERO cycles with both writers active.
--   * Reads past the region's real size return 0; writes past it are
--     dropped.  That is llama_top's pad: its array is padded to REGMAX per
--     region and zero-initialised, and a correct adapter never writes the
--     pad.  An adapter that DID write the pad is a defect llama_top
--     itself cannot see, and region_mem declines to reproduce it.
--   * The host read window (hr_*) is COMBINATIONAL, exactly as
--     llama_top:1343 has it.  It is a mux, not a BRAM port, and wants no
--     latency.  The host WRITE path is not here at all: llama_top gives it
--     priority inside its own `elmux`, so the element write port below is
--     already the post-mux one, same as llama_top's `memp` sees.
--
-- THE READ STRUCTURE.  Each region's process registers ITS OWN read word
-- into one element of a per-region array, and the region/lane select is
-- registered alongside, so the output mux reads a captured word with a
-- captured select: address in cycle k, data in cycle k+1, exactly one
-- cycle, and no signal has more than one driver.
--
-- LANES must be a power of two: element word/lane extraction is a bit
-- slice, same as llama_top's GA_W = VN_W - LOG2L arithmetic.
--
-- NO HARDWARE in this file.  It is a memory with an opinion about
-- semantics, and nothing else.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity region_mem is
  generic(
    NREGION : positive := 14;
    REGMAX  : positive := 12288;
    LANES   : positive := 8;
    MANT_W  : positive := 16;
    GA_W    : positive := 11;             -- group (word) address width
    SZ      : integer_vector;             -- per-region element counts
    -- THE HOST READ WINDOW, AND WHY IT IS A GENERIC.
    --
    -- llama_top exposes hr_reg/hr_addr/hr_data as TOP-LEVEL PORTS: a
    -- COMBINATIONAL, full-range random read into the region file.  A memory
    -- with a combinational read port CANNOT be a BRAM, so while that port
    -- exists this store is LUTs and registers no matter what shape the array
    -- has.  MEASURED 2026-09-02: Vivado reports
    -- `[Synth 8-11357] ... RAM mem_reg with 2752512 registers`, which is the
    -- SAME 2,752,512 figure as the recorded `HOptDfg::dissolveRam` crash on
    -- llama_top.  Reorganising the array from flat to per-region did not
    -- change it, because the array's shape was never the cause.
    --
    -- Nothing on the CARD drives or consumes that port: it exists for
    -- sim/tb_llama_top.vhd, which reads results through it.  So it is gated.
    --   TRUE  (default) -- simulation.  Identity against llama_top is proven
    --                      in this configuration.
    --   FALSE           -- the card.  hr_data reads zero and the banks can
    --                      infer BRAM.
    -- The two configurations differ by exactly one output port that is dead
    -- on the card.  Oren's call, 2026-09-02.
    HOST_WINDOW : boolean := true;             -- per-region element counts
    -- THE SHADOW (2026-09-22).  With HOST_WINDOW false the host read port is
    -- dead, and the two-card hop needs R_X's mantissas through it.  MEASURED
    -- on build 14: the exponent register read the reference's value and
    -- window 3 read 4,096 zeros (docs/debugging/2026-09-22_the-residual-
    -- window-reads-zero-on-silicon.md).  So ONE region -- this one, R_X on
    -- the card -- is mirrored into a second, single-write-port bank written
    -- by the same merged write that lands in the real bank, and read back
    -- with a ONE-CYCLE REGISTERED read, which is what lets it be a BRAM
    -- where the combinational window could not.  -1 = no shadow (hr_data
    -- reads zero exactly as before).  Ignored when HOST_WINDOW is true.
    --
    -- The consumer is fk33_seam's XOUT window, which presents hr_addr at
    -- AR-accept and samples hr_data two clocked states later
    -- (rtl/fk33_seam.vhd `rd_wait`), so one cycle of read latency is inside
    -- the contract it already keeps.
    SHADOW_REGION : integer := -1
  );
  port(
    clk      : in  std_logic;

    -- element read, registered one cycle
    el_ren   : in  std_logic;
    el_reg   : in  natural range 0 to NREGION-1;
    el_addr  : in  natural range 0 to REGMAX-1;
    el_rdata : out signed(MANT_W-1 downto 0);

    -- element write
    el_we    : in  std_logic;
    el_wreg  : in  natural range 0 to NREGION-1;
    el_waddr : in  natural range 0 to REGMAX-1;
    el_wdata : in  signed(MANT_W-1 downto 0);

    -- group read, two operand regions, registered one cycle
    r_en     : in  std_logic;
    r_rega   : in  unsigned(7 downto 0);
    r_regb   : in  unsigned(7 downto 0);
    r_addr   : in  unsigned(GA_W-1 downto 0);
    x_rdata  : out std_logic_vector(LANES*MANT_W-1 downto 0);
    e_rdata  : out std_logic_vector(LANES*MANT_W-1 downto 0);

    -- group write, per-lane enables
    w_we     : in  std_logic;
    w_regd   : in  unsigned(7 downto 0);
    w_addr   : in  unsigned(GA_W-1 downto 0);
    w_be     : in  std_logic_vector(LANES-1 downto 0);
    w_data   : in  std_logic_vector(LANES*MANT_W-1 downto 0);

    -- host read window, combinational
    hr_reg   : in  natural range 0 to NREGION-1;
    hr_addr  : in  natural range 0 to REGMAX-1;
    hr_data  : out signed(MANT_W-1 downto 0)
  );
end entity;

architecture rtl of region_mem is

  function log2p(n : positive) return natural is
    variable r : natural := 0;
    variable v : positive := 1;
  begin
    while v < n loop v := v * 2; r := r + 1; end loop;
    return r;
  end function;

  constant LOG2L : natural := log2p(LANES);
  subtype word_t is std_logic_vector(LANES*MANT_W-1 downto 0);

  -- per-region word counts, tight packing
  function sz_words(r : natural) return natural is
  begin
    return (SZ(r) + LANES - 1) / LANES;
  end function;

  constant MAXW : natural := (REGMAX + LANES - 1) / LANES;

  type bank_t is array (0 to MAXW-1) of word_t;
  type word_arr_fwd_t is array (0 to NREGION-1) of word_t;

  -- NO SINGLE 3-D `mem` SIGNAL.  Each region declares its own `bank` inside
  -- the generate below, so the tool sees NREGION independent 2-D arrays
  -- rather than one object it must dissolve as a whole.  Vivado warns
  -- specifically about the latter: `[Synth 8-11357] Potential Runtime issue
  -- for 3D-RAM or RAM from Record/Structs`.
  --
  -- The host window's per-region read word, driven inside the generate only
  -- when HOST_WINDOW, and muxed by hr_reg below.
  signal hr_word : word_arr_fwd_t := (others => (others => '0'));

  type word_arr_t is array (0 to NREGION-1) of word_t;

  -- per-region registered read words, and the registered selects
  signal el_word_r : word_arr_t := (others => (others => '0'));
  signal g_word_r  : word_arr_t := (others => (others => '0'));
  signal el_reg_q  : natural range 0 to NREGION-1 := 0;
  signal el_lane_q : natural range 0 to LANES-1 := 0;
  signal ra_q      : natural range 0 to NREGION-1 := 0;
  signal rb_q      : natural range 0 to NREGION-1 := 0;

  -- the shadow's registered read word, lane and region hit; driven only
  -- inside g_shadow below, so without a shadow they hold their zeros
  signal sh_word_r : word_t := (others => '0');
  signal sh_lane_q : natural range 0 to LANES-1 := 0;
  signal sh_hit_q  : std_logic := '0';

begin

  -- THE ASSUMPTION THE MERGED WRITE PORT RESTS ON, CHECKED NOT ASSUMED.
  -- MEASURED 2026-09-02 over a full token of the card-top identity bench:
  -- zero cycles with both writers active.  That is a property of D's
  -- schedule, not of this memory: a future D with overlap would violate it
  -- and the merged port would silently DROP a write.
  excl : process(clk) is
  begin
    if rising_edge(clk) then
      -- THE PRECONDITION IS PER REGION, not global.  The write mux lives
      -- inside the per-region generate, so an element write to region 3 and
      -- a group write to region 7 in the same cycle BOTH land: region 3's
      -- mux never sees the group write and region 7's never sees the
      -- element write.  A write is lost only when both target the SAME
      -- region, which is the only case this may forbid.
      --
      -- The first version of this assertion was global and fired on the
      -- unit bench immediately.  A precondition stated more strongly than
      -- the mechanism requires is not "safe": it forbids traffic the design
      -- handles correctly, and it would have driven a much larger and
      -- entirely unnecessary restructuring.
      assert not (el_we = '1' and w_we = '1'
                  and el_wreg = to_integer(w_regd))
        report "region_mem: element and group WRITE to the SAME region in "
             & "one cycle; the merged write port serves the group write and "
             & "the element write is LOST"
        severity failure;
    end if;
  end process;

  assert 2**LOG2L = LANES
    report "region_mem: LANES must be a power of two"
    severity failure;

  -- ====================================================================
  -- THE BANKS.  One process per region so every read in a cycle returns
  -- pre-write data no matter which write fires beside it, mirroring
  -- llama_top's single process exactly.  Write order inside the process
  -- is element-then-group, so the group write wins a same-word tie,
  -- mirroring llama_top's assignment order.
  -- ====================================================================
  g_region : for r in 0 to NREGION-1 generate
    constant NW : natural := sz_words(r);
    -- SIZED PER REGION, not MAXW.  `bank_t` is as deep as the WIDEST region
    -- (ffn, 1,536 words at 9B); using it for all fourteen banks made R_BETA
    -- and R_ALPHA -- val_heads elements each -- cost as much as an FFN bank.
    -- D3 always said "sized per-region BRAM ... ~34 RAMB36"; that is the
    -- figure for the 9,480 real words, and this declaration is what makes it
    -- true.  MEASURED 2026-09-02, two readers, OOC on xcvu33p: uniform
    -- `bank_t` costs 224 RAMB36, per-region 100.
    --
    -- THIS IS WHAT MAKES THE WRITE GUARD LOad-BEARING.  With a MAXW-deep
    -- array an unguarded write past the region size landed harmlessly in the
    -- pad; with an NW-deep array it is an out-of-bounds index.  The guard
    -- below was already there, and sim/tb_region_mem.vhd's pad phase now
    -- drives writes past every region's size so the combination is exercised
    -- rather than assumed.
    type bank_sized_t is array (0 to NW-1) of word_t;
    signal bank : bank_sized_t := (others => (others => '0'));
    -- ASK EXPLICITLY.  CLAUDE.md: Vivado's inference log lies in both
    -- directions, so this attribute is a REQUEST and the mapping report plus
    -- an object-level get_cells census are the only authoritative answers.
    -- It is honoured only when HOST_WINDOW is false; with a combinational
    -- read port present no attribute can make this a BRAM.
    attribute ram_style : string;
    attribute ram_style of bank : signal is "block";

    signal wr_en   : std_logic := '0';
    signal wr_addr : natural range 0 to MAXW-1 := 0;
    signal wr_be   : std_logic_vector(LANES-1 downto 0) := (others => '0');
    signal wr_data : word_t := (others => '0');
  begin

    -- the two writers muxed into one port, group first so it wins a tie
    process(el_we, el_wreg, el_waddr, el_wdata, w_we, w_regd, w_addr, w_be, w_data)
      variable ew : natural;
      variable el : natural;
    begin
      wr_en   <= '0';
      wr_addr <= 0;
      wr_be   <= (others => '0');
      wr_data <= (others => '0');
      if w_we = '1' and to_integer(w_regd) = r then
        if to_integer(w_addr) < NW then
          wr_en   <= '1';
          wr_addr <= to_integer(w_addr);
          wr_be   <= w_be;
          wr_data <= w_data;
        end if;
      elsif el_we = '1' and el_wreg = r then
        ew := el_waddr / LANES;
        el := el_waddr mod LANES;
        if ew < NW then
          wr_en   <= '1';
          wr_addr <= ew;
          for i in 0 to LANES-1 loop
            if i = el then
              wr_be(i) <= '1';
            end if;
            wr_data((i+1)*MANT_W-1 downto i*MANT_W)
              <= std_logic_vector(el_wdata);
          end loop;
        end if;
      end if;
    end process;
    process(clk)
      variable ew : natural;
      variable el : natural;
    begin
      if rising_edge(clk) then
        -- ONE WRITE STATEMENT.  This is the ONLY structural change the
        -- tool asked for, and it is not a preference:
        --   [Synth 8-4767] Trying to implement RAM 'g_region[0].bank_reg'
        --   in registers ... 1: RAM has multiple writes via different ports
        --   in same process.
        --   [Synth 8-3391] Unable to infer a block/distributed RAM ...
        -- and the failed dissolve then SEGFAULTS Vivado 2023.2 outright
        -- (`Abnormal program termination (11)`), MEASURED 2026-09-02.
        --
        -- The two writers are muxed AHEAD of the single write, group first
        -- so it still wins a same-word tie exactly as llama_top's assignment
        -- order does.  The element write becomes a one-hot lane enable on
        -- the same byte-enabled port, so both are one primitive.
        --
        -- Sound only because the two writers never fire together.  MEASURED
        -- over a full token: zero coincidences.  That is a property of D's
        -- one-unit-at-a-time schedule and NOT of this memory, so it is
        -- asserted rather than assumed -- see `excl` below.
        --
        -- READS ARE LEFT ALONE.  The tool's complaint named writes only;
        -- multiple readers it can serve by replicating.  An earlier attempt
        -- merged the readers too and BROKE the hold contract, because the
        -- three registered words hold across DIFFERENT intervals and one
        -- shared register cannot: an element read clobbered the group word.
        -- The unit bench caught it. Do not merge the reads.
        if wr_en = '1' then
          for i in 0 to LANES-1 loop
            if wr_be(i) = '1' then
              bank(wr_addr)((i+1)*MANT_W-1 downto i*MANT_W)
                <= wr_data((i+1)*MANT_W-1 downto i*MANT_W);
            end if;
          end loop;
        end if;

        -- reads: pre-write data, one cycle, into this region's own slot
        if el_ren = '1' and el_reg = r then
          ew := el_addr / LANES;
          if ew < NW then
            el_word_r(r) <= bank(ew);
          else
            el_word_r(r) <= (others => '0');
          end if;
        end if;
        -- ONE GROUP READ SITE, serving BOTH operands.
        --
        -- This is what makes the bank a BRAM.  MEASURED 2026-09-02, OOC on
        -- xcvu33p: with THREE read sites (element, x, e) Vivado reports
        -- `[Synth 8-6849] Infeasible attribute ram_style = "block"` on all
        -- fourteen banks and falls back to LUTRAM -- 0 BRAM, 84,836 LUT.
        -- With TWO it reports `[Synth 8-3971] recognized as a true dual port
        -- RAM template` and gives 100 RAMB36, 2,918 LUT.  A TDP BRAM has two
        -- ports and the third reader has nowhere to go.
        --
        -- SOUND BECAUSE x AND e ARE THE SAME READ.  They share `r_addr` and
        -- differ only in which region each selects, so a given bank is asked
        -- for at most one of them, and when `rega = regb` they want the
        -- identical word.  The output mux below picks with the REGISTERED
        -- selects `ra_q`/`rb_q`, captured at this same edge.
        --
        -- AND THIS IS NOT THE MERGE THAT BROKE THE HOLD CONTRACT.  The note
        -- on the write statement above records an earlier attempt that
        -- merged the ELEMENT read in as well; that one failed because the
        -- element read fires on `el_ren` and the group reads on `r_en`, so
        -- the three words hold across DIFFERENT intervals and one register
        -- cannot serve them -- an element read clobbered the group word.
        -- `x` and `e` are both gated by `r_en` alone and therefore always
        -- update together, which is exactly the property the element read
        -- lacks.  The element read stays separate.
        if r_en = '1'
           and (to_integer(r_rega) = r or to_integer(r_regb) = r) then
          if to_integer(r_addr) < NW then
            g_word_r(r) <= bank(to_integer(r_addr));
          else
            g_word_r(r) <= (others => '0');
          end if;
        end if;
      end if;
    end process;

    -- the host window's read for THIS region, combinational, guarded on the
    -- region's real size exactly as llama_top's mux is
    g_hw : if HOST_WINDOW generate
      process(bank, hr_addr)
        variable w : natural;
      begin
        w := hr_addr / LANES;
        if w < NW then
          hr_word(r) <= bank(w);
        else
          hr_word(r) <= (others => '0');
        end if;
      end process;
    end generate;

    -- THE SHADOW of this region (see the SHADOW_REGION generic).  Same
    -- wr_en/wr_addr/wr_be/wr_data as the real bank, so every write that
    -- lands there lands here in the same cycle with the same lane enables;
    -- one write port, one registered read, no other reader: a simple
    -- dual-port BRAM.  The lane and the region hit are registered at the
    -- SAME edge as the word so hr_data is one consistent (word, lane)
    -- sample even if hr_addr moves the cycle after.
    g_shadow : if (not HOST_WINDOW) and r = SHADOW_REGION generate
      signal shadow : bank_sized_t := (others => (others => '0'));
      attribute ram_style of shadow : signal is "block";
    begin
      process(clk)
        variable w : natural;
      begin
        if rising_edge(clk) then
          if wr_en = '1' then
            for i in 0 to LANES-1 loop
              if wr_be(i) = '1' then
                shadow(wr_addr)((i+1)*MANT_W-1 downto i*MANT_W)
                  <= wr_data((i+1)*MANT_W-1 downto i*MANT_W);
              end if;
            end loop;
          end if;
          w := hr_addr / LANES;
          if w < NW then
            sh_word_r <= shadow(w);
          else
            sh_word_r <= (others => '0');
          end if;
          sh_lane_q <= hr_addr mod LANES;
          if hr_reg = r then
            sh_hit_q <= '1';
          else
            sh_hit_q <= '0';
          end if;
        end if;
      end process;
    end generate;
  end generate;

  -- the registered selects, captured at the same edge as the words
  process(clk)
  begin
    if rising_edge(clk) then
      if el_ren = '1' then
        el_reg_q  <= el_reg;
        el_lane_q <= el_addr mod LANES;
      end if;
      if r_en = '1' then
        if to_integer(r_rega) < NREGION then
          ra_q <= to_integer(r_rega);
        end if;
        if to_integer(r_regb) < NREGION then
          rb_q <= to_integer(r_regb);
        end if;
      end if;
    end if;
  end process;

  el_rdata <= signed(el_word_r(el_reg_q)(
                     (el_lane_q+1)*MANT_W-1 downto el_lane_q*MANT_W));
  x_rdata  <= g_word_r(ra_q);
  e_rdata  <= g_word_r(rb_q);

  -- The host window, gated.  When HOST_WINDOW it is combinational and
  -- reads exactly what llama_top:1343 reads; when not, it is tied to zero
  -- and the banks above are free to infer BRAM.
  g_host : if HOST_WINDOW generate
    process(hr_word, hr_reg, hr_addr)
      variable l : natural;
    begin
      l := hr_addr mod LANES;
      hr_data <= signed(hr_word(hr_reg)((l+1)*MANT_W-1 downto l*MANT_W));
    end process;
  end generate;

  g_nohost : if not HOST_WINDOW generate
    -- zero without a shadow (sh_hit_q never rises), the shadow's registered
    -- word otherwise; one cycle after hr_reg/hr_addr
    process(sh_word_r, sh_lane_q, sh_hit_q)
    begin
      if sh_hit_q = '1' then
        hr_data <= signed(sh_word_r((sh_lane_q+1)*MANT_W-1 downto sh_lane_q*MANT_W));
      else
        hr_data <= (others => '0');
      end if;
    end process;
  end generate;

end architecture;
