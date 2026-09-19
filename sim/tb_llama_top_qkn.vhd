-- sim/tb_llama_top_qkn.vhd
-- SUBSYSTEM C ON THE MODEL'S QK-NORM GAINS, ACROSS THREE TOKENS.
--
-- Every generic below is `sim/tb_llama_top_real.vhd`'s, with THREE changed:
--
--   NTOK => 3, MAXPOS => 8   three tokens, so the attention path runs past
--                            the position-0 bypass and the gains reach the
--                            scores (at cur_pos = 0 the block never reads the
--                            cache and a q/k gain barely shows: MEASURED, the
--                            ramp model differs from the image machine by 8
--                            of 64 mantissas at token 0 and 63 and 64 of 64
--                            at tokens 1 and 2)
--   C_QKN_IMAGE => ...       blk.3's attn_q_norm and attn_k_norm of the
--                            shipped 9B gguf, sliced to this shape's 16
--                            head elements by tools/gen_qkn_image.py, in
--                            place of rtl/llama_top.vhd's `qkn_const` ramp.
--                            The LAST stand-in in the design after the B
--                            constants path (docs/2026-09-18_b-constants-
--                            path.md); TRACK F, 2026-09-18.
--
-- THE LANDMARKS BELOW ARE PINNED TO WHAT THIS CONFIGURATION PRODUCES, AND
-- THEY ARE CHANGE DETECTORS, NOT A VERDICT ON VALUES.  `tb_llama_top_real`'s
-- numbers cannot be carried over: the gain is a learned weight the ramp
-- stands in for, so the two configurations compute different attention
-- outputs by design.  MEASURED 2026-09-18 on 4e14b4c plus this track's RTL
-- (GHDL mcode, `P14 landmarks measured` from a run with none pinned):
--
--   EXP_X0 => 10837, EXP_XSUM => 57208, EXP_XALL => 43775, EXP_STEPH => 73528
--
-- THE VERDICT ON VALUES IS `sim:seamgate_qkn` (tools/ref9b/seamgate.sh qkn):
-- the same configuration captured and every modelled seam checked by
-- tools/ref9b/bisect_scaled.py, whose attention model reads the SAME image
-- through `--qkn-image`.  MEASURED 2026-09-18: R_Y-3 bit for bit at tokens
-- 0, 1 and 2, and the ramp model against the same capture FAILS at R_Y-3 on
-- every token (the attribution control), so the agreement is the gains and
-- not a loose comparison.  Read this row's PASS as "the numbers have not
-- moved since they were last judged there"; when it disagrees, re-run that
-- one before re-pinning here.
--
-- WHY the image is opened by bare name: sim/regress.sh symlinks every
-- sim/*.hex into a row's run directory, the rule that already serves
-- sim/llama_top_w_b4_pool.hex to tb_llama_top_real.  The committed image is
-- held to today's generator by `sim:qknimage`.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_qkn is
end entity;

architecture tb of tb_llama_top_qkn is
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
      C_QKN_IMAGE => "llama_top_qkn_b4.hex",
      EXP_X0      => 10837,
      EXP_XSUM    => 57208,
      EXP_XALL    => 43775,
      EXP_STEPH   => 73528);
end architecture;
