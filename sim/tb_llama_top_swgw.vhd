-- sim/tb_llama_top_swgw.vhd -- 2026-09-20.  TRACK GSRWIDE, LEVER L2.
--
-- `sim/tb_llama_top_swg.vhd`'s generic map, CHARACTER FOR CHARACTER, plus
-- two generics:
--
--   SWG_LANES => 8   rtl/swiglu_mem.vhd's own LANES.  It has been 1 since
--                    the unit was written because rtl/llama_top.vhd's `gsr`
--                    never named the generic.  8 is what divides both the
--                    sim shape's SHAPE.ffn = 128 and the card's 12288, and
--                    it is the region file's LANES, which is what lets one
--                    group-port beat fill exactly one word of every bank.
--   SWG_WIDE  => true  the `gsr` adapter's two serial load passes and its
--                    serial write-back move onto the region file's
--                    LANES-wide group READ and group WRITE ports.
--
-- THE FOUR LANDMARKS BELOW ARE sim/tb_llama_top_swg.vhd's, UNCHANGED AND
-- NOT RE-DERIVED.  That is the whole point of the row: the wide path has to
-- REPRODUCE the numbers the narrow path was judged on, not produce a fresh
-- set of its own.  Re-measuring them from a run of the arm under test is a
-- round trip against itself, and this project has a recorded case of that
-- passing for a wrong-but-consistent implementation (the `m7 mutant`).
-- Those four values were themselves cleared against tools/ref9b/ by
-- `sim:seamgate_swg`, so a wide run matching them has matched an
-- independent Python model transitively, element by element.
--
-- EXP_STEPH IS THE ONE THAT MATTERS HERE and the other three are weak, for
-- the reason TRACK WIDEDRAIN's section 10.8 states: EXP_X0, EXP_XSUM and
-- EXP_XALL all read R_X, and this lever changes how R_H is written.  R_H
-- reaches R_X only through the FFN's down projection, so a fault that
-- happened to preserve the down projection's output would leave all three
-- unmoved.  EXP_STEPH hashes EVERY region write the machine makes,
-- region-tagged, address by address, in order -- including every lane of
-- every group write -- so it is the write STREAM that is pinned and not a
-- residual that survived it.  A lane enabled past the vector, which writes
-- elements nobody reads, is visible to EXP_STEPH and to nothing else.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_swgw is
end entity;

architecture tb of tb_llama_top_swgw is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS      => 4,
      ATTN_INT    => 4,
      NRUNS       => 1,
      NTOK        => 3,
      C_REAL      => true,
      ATTN_HD     => 16,
      NORM_REAL   => true,
      NORM_ANCHOR => false,
      W_IMAGE     => "llama_top_w_b4_pool.hex",
      MAXPOS      => 8,
      SWG_REAL    => true,
      SWG_LANES   => 8,
      SWG_WIDE    => true,
      EXP_X0      => 10238,
      EXP_XSUM    => 87031,
      EXP_XALL    => 65159,
      EXP_STEPH   => 35900);
end architecture;
