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
--   * If an element write and a group write hit the same word in one
--     cycle, the GROUP write wins (later assignment in llama_top's
--     process).  The same assignment order is kept here, though D's
--     one-unit-at-a-time rule makes the case unreachable today.
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
    HOST_WINDOW : boolean := true              -- per-region element counts
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
  signal x_word_r  : word_arr_t := (others => (others => '0'));
  signal e_word_r  : word_arr_t := (others => (others => '0'));
  signal el_reg_q  : natural range 0 to NREGION-1 := 0;
  signal el_lane_q : natural range 0 to LANES-1 := 0;
  signal ra_q      : natural range 0 to NREGION-1 := 0;
  signal rb_q      : natural range 0 to NREGION-1 := 0;

begin

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
    signal bank : bank_t := (others => (others => '0'));
    -- ASK EXPLICITLY.  CLAUDE.md: Vivado's inference log lies in both
    -- directions, so this attribute is a REQUEST and the mapping report plus
    -- an object-level get_cells census are the only authoritative answers.
    -- It is honoured only when HOST_WINDOW is false; with a combinational
    -- read port present no attribute can make this a BRAM.
    attribute ram_style : string;
    attribute ram_style of bank : signal is "block";
  begin
    process(clk)
      variable ew : natural;
      variable el : natural;
    begin
      if rising_edge(clk) then
        -- element write first (llama_top's order)
        if el_we = '1' and el_wreg = r then
          ew := el_waddr / LANES;
          el := el_waddr mod LANES;
          if ew < NW then
            bank(ew)((el+1)*MANT_W-1 downto el*MANT_W)
              <= std_logic_vector(el_wdata);
          end if;
        end if;
        -- group write second: it wins a same-word tie, as in llama_top
        if w_we = '1' and to_integer(w_regd) = r then
          if to_integer(w_addr) < NW then
            for i in 0 to LANES-1 loop
              if w_be(i) = '1' then
                bank(to_integer(w_addr))((i+1)*MANT_W-1 downto i*MANT_W)
                  <= w_data((i+1)*MANT_W-1 downto i*MANT_W);
              end if;
            end loop;
          end if;
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
        if r_en = '1' then
          if to_integer(r_rega) = r then
            if to_integer(r_addr) < NW then
              x_word_r(r) <= bank(to_integer(r_addr));
            else
              x_word_r(r) <= (others => '0');
            end if;
          end if;
          if to_integer(r_regb) = r then
            if to_integer(r_addr) < NW then
              e_word_r(r) <= bank(to_integer(r_addr));
            else
              e_word_r(r) <= (others => '0');
            end if;
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
  x_rdata  <= x_word_r(ra_q);
  e_rdata  <= e_word_r(rb_q);

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
    hr_data <= (others => '0');
  end generate;

end architecture;
