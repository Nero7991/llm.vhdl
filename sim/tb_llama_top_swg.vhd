-- sim/tb_llama_top_swg.vhd
-- THE REAL SwiGLU ON THE D-VEC SWG OP, ACROSS THREE TOKENS.
--
-- Every generic below is `sim/tb_llama_top_real.vhd`'s, with THREE changed:
--
--   NTOK => 3, MAXPOS => 8   three tokens, the same shape `qkn` and `bconst`
--                            run, so the seam gate on this configuration
--                            judges twelve R_H seams and not four.
--   SWG_REAL => true         rtl/swiglu_mem.vhd on OP_VEC_SWG behind
--                            rtl/llama_top.vhd's `gsr` adapter: Q12
--                            silu(g)*u with rtl/bfp_pack.vhd's pack, in
--                            place of the `g*u / 2**MANT_W` stand-in every
--                            other row in this family elaborates.  The LAST
--                            stand-in in the composed top, found by
--                            bisecting token 0 on silicon
--                            (docs/debugging/2026-09-19_the-swiglu-on-the-
--                            card-is-a-product-with-no-gate.md).
--
-- THE LANDMARKS BELOW ARE PINNED TO WHAT THIS CONFIGURATION PRODUCES, AND
-- THEY ARE CHANGE DETECTORS, NOT A VERDICT ON VALUES.  `tb_llama_top_real`'s
-- numbers cannot be carried over: every FFN's H is a different vector with a
-- different exponent by design (the stand-in publishes e(G)+e(U)-16; the
-- unit publishes Q - shift).  MEASURED 2026-09-19 on 09f68a0 plus this
-- track's RTL (GHDL 1.0.0 mcode, `P14 landmarks measured` from a run with
-- none pinned):
--
--   EXP_X0 => 10238, EXP_XSUM => 87031, EXP_XALL => 65159, EXP_STEPH => 35900
--
-- against tb_llama_top_qkn's 10837 / 57208 / 43775 / 73528 at the same
-- shape and token count with the stand-in: every landmark moved, as a real
-- H in every FFN must move them.
--
-- THE VERDICT ON VALUES IS `sim:seamgate_swg` (tools/ref9b/seamgate.sh swg):
-- the same configuration captured and every modelled seam checked by
-- tools/ref9b/bisect_scaled.py with `--swg real`, whose R_H model is
-- tools/ref9b/vec_oracle.swg_real (ref/run_fx.c's swiglu_fx + fx_sigmoid_q
-- + bfp_pack's rule, held to the C by tools/ref9b/check_swg_real.py).
-- MEASURED 2026-09-19: R_H-0..3 bit for bit at tokens 0, 1 and 2, and the
-- stand-in model against the same capture FAILS at R_H-0 on every token
-- (the attribution control), so the agreement is the SwiGLU and not a loose
-- comparison.  Read this row's PASS as "the numbers have not moved since
-- they were last judged there"; when it disagrees, re-run that one before
-- re-pinning here.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_swg is
end entity;

architecture tb of tb_llama_top_swg is
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
      EXP_X0      => 10238,
      EXP_XSUM    => 87031,
      EXP_XALL    => 65159,
      EXP_STEPH   => 35900);
end architecture;
