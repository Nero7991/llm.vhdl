-- sim/tb_realshape_9b.vhd -- TRACK REALFIX, 2026-08-29.
--
-- ELABORATE `llama_top` AT ITS OWN DEFAULT GENERICS, WHICH ARE THE REAL
-- QWEN3.5-9B SHAPE, AND WHICH NOTHING IN THIS REPOSITORY HAD EVER DONE.
--
-- THE POINT, stated so the next reader does not mistake this for a value
-- test.  `rtl/llama_top.vhd`'s `SHAPE` generic defaults to
-- `mk_shape(MODEL, NCARDS)` -- hidden 4096, ffn 12288, 24 GDN layers, 8
-- attention layers -- and that expression occurs EXACTLY ONCE in the whole
-- VHDL tree, as that default.  Every other bench passes
-- `mk_shape_scaled(...)`, which is hidden 64 and ffn 128.  So the one
-- configuration that had never been elaborated in any simulator was the top
-- level's own default: the configuration a synthesis run gets if nobody
-- overrides anything.  TRACK REALSHAPE ran it first and it died with
-- STORAGE_ERROR at 24.9 GB
-- (docs/debugging/2026-08-29_realshape-9b-elaboration.md); six defects came
-- out of it, five of them invisible at the scaled shape.  This bench is the
-- standing check that they stay fixed.
--
-- THIS BENCH DELIBERATELY INSTANTIATES THE DUT WITH NO GENERIC MAP AT ALL.
-- Passing even one generic would make it a different configuration and would
-- defeat its entire purpose.  Do not add one.
--
-- ELABORATING IS NOT COMPUTING, and this bench claims nothing else.  It
-- checks that every generic, array bound, index expression and integer range
-- in the composed design is legal at the true dimensions.  It drives no
-- clock, so no arithmetic happens and none is checked.  The value gates for
-- this file are `sim/tb_llama_top`, `_seq`, `_real` and `_normw`, which run
-- at the scaled shape and have four landmarks each.
--
-- WHAT IT COSTS: about 2.2 GB of GHDL elaboration and 2 s.  Before TRACK
-- REALFIX it was ~46 GB, because subsystem B's per-layer recurrent state was
-- a SIGNAL array of 201,326,592 scalars at ~228 bytes each.
--
-- THE GUARDS THAT MUST *REFUSE* CANNOT LIVE HERE.  A testbench proves a
-- configuration elaborates; it cannot prove one does not, because a refused
-- elaboration takes the whole bench with it.  Those eleven rows -- REGMAX
-- short, VN_W short, NBLK over the header chunk, the KV regions overflowing
-- the address space, ctx_len over the cache -- are in
-- `sim/realshape_gate.sh`, each paired with the neighbouring row one generic
-- away that must still PASS.  Run that by hand; this row is its cheap
-- standing half.
--
-- ONLY THE INPUTS WITHOUT DEFAULTS ARE ASSOCIATED.  Every output is left
-- unassociated, which VHDL permits and which keeps this file from carrying a
-- copy of a 60-port list that would rot on the next port added.  If a NEW
-- input without a default appears on `llama_top`, this bench stops
-- elaborating and says so by name -- that is the intended behaviour, not a
-- maintenance burden to design around.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.model_cfg_pkg.all;
use work.llama_map_pkg.all;

entity tb_realshape_9b is
end entity;

architecture tb of tb_realshape_9b is

  -- The DUT's own defaults, restated here ONLY to size the stimulus signals.
  -- These are not passed to it; it uses its own.
  constant SHAPE_C  : shape_t  := mk_shape(MODEL, NCARDS);
  constant REGMAX_C : positive := region_max(SHAPE_C);
  constant STEP_W_C : positive := 11;
  constant EXP_W_C  : positive := 16;
  constant MANT_W_C : positive := 16;

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal go         : std_logic := '0';
  signal abort      : std_logic := '0';
  signal tbl_len    : unsigned(STEP_W_C-1 downto 0) := (others => '0');
  signal host_x_exp : signed(EXP_W_C-1 downto 0) := (others => '0');
  signal rel_mask   : std_logic_vector(NREGION-1 downto 0)
                    := (others => '0');
  signal tok_ack    : std_logic := '0';
  signal d_rdata    : std_logic_vector(63 downto 0) := (others => '0');
  signal d_rvalid   : std_logic := '0';
  signal hw_we      : std_logic := '0';
  signal hw_reg     : natural range 0 to NREGION-1 := 0;
  signal hw_addr    : natural range 0 to REGMAX_C-1 := 0;
  signal hw_data    : signed(MANT_W_C-1 downto 0) := (others => '0');
  signal hr_reg     : natural range 0 to NREGION-1 := 0;
  signal hr_addr    : natural range 0 to REGMAX_C-1 := 0;

begin

  -- NO GENERIC MAP.  See the header.
  dut : entity work.llama_top
    port map(
      clk => clk, rst => rst, go => go, abort => abort,
      tbl_len => tbl_len, host_x_exp => host_x_exp, rel_mask => rel_mask,
      tok_ack => tok_ack,
      d_rdata => d_rdata, d_rvalid => d_rvalid,
      hw_we => hw_we, hw_reg => hw_reg, hw_addr => hw_addr,
      hw_data => hw_data, hr_reg => hr_reg, hr_addr => hr_addr);

  chk : process is
  begin
    wait for 1 ns;
    report "tb_realshape_9b: elaborated llama_top at its DEFAULT generics -- "
         & "blocks " & integer'image(SHAPE_C.blocks)
         & ", hidden " & integer'image(SHAPE_C.hidden)
         & ", ffn " & integer'image(SHAPE_C.ffn)
         & ", region_max " & integer'image(REGMAX_C)
         & ", attn_head_dim " & integer'image(SHAPE_C.attn_head_dim);
    report "REALSHAPE 9B: PASS -- every generic, array bound, index "
         & "expression and integer range in the composed design is legal at "
         & "the real shape.  No value was checked and none is claimed.";
    wait;
  end process;

end architecture;
