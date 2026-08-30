-- sim/tb_matvec_fk33_desc_xexp.vhd -- subsystem A's descriptor control plane
-- with the activation block exponent arriving on the WRAPPER PORT instead of
-- in the descriptor.
--
-- WHY IT IS A SEPARATE FILE AND NOT A SECOND SET OF ARGUMENTS.  Same reason as
-- sim/tb_matvec_fk33_desc_dual.vhd: sim/regress.sh keys a test by name and
-- cannot run one testbench twice, so a second configuration needs a second
-- entity.  Everything the inner bench proves is proved again here.
--
-- WHY IT IS WORTH A ROW.  `USE_XEXP_PORT` selects between the two possible
-- sources of x_exp at rtl/matvec_int4_desc_axi.vhd:547:
--
--     v_xexp <= x_exp_in when USE_XEXP_PORT else lo32(dw(EXT0 + 2));
--
-- Until 2026-08-29 the value `true` appeared NOWHERE in the tree -- not in a
-- bench, not in a .tcl, not in the FK33 shell, which hard-codes `false`.  It
-- was named as a survivor in sim/mv4i_desc_mutations.py (row N1, class GEN,
-- "not elaborated in the configuration under test") and as an open hole in
-- docs/debugging/2026-08-29_desc-decode-mutations.md.  A generic with no
-- configuration that elaborates it is a branch of the design that has never
-- been compiled, let alone simulated, and it exists precisely because the
-- sequencer may have to hand x_exp over rather than write it into a
-- descriptor -- i.e. it is a path a later track will need to turn on.
--
-- HOW IT IS TESTED, WHICH IS THE PART THAT MATTERS.  Setting the generic and
-- watching the bench still pass would test nothing: the descriptor also
-- carries the right x_exp, so BOTH sides of the mux give the right answer and
-- the run passes either way.  So under XEXP_PORT the inner bench deliberately
-- writes the descriptor's own x_exp word SEVEN TOO LARGE and drives the true
-- value on `x_exp_in`.  A correct mux therefore still reproduces the reference
-- y_exp; a mux wired the other way does not.
--
-- TEETH, MEASURED 2026-08-29.  With rtl/matvec_int4_desc_axi.vhd:547 rewritten
-- in a scratch copy to `v_xexp <= lo32(dw(EXT0 + 2));` -- the mux forced to the
-- descriptor side -- this configuration reports:
--
--     CASE 0: Y_EXP MISMATCH got 13 want 6
--     tb_matvec_fk33_desc: 22 cases run, 1 failures [DUAL=false XEXP_PORT=true]
--     SUBSYSTEM A'S DESCRIPTOR CONTROL PLANE FAILED 1 CASES
--
-- so the row is not decoration: it fails when the thing it is about is broken.
--
-- WHAT IT DOES NOT COVER.  It elaborates USE_XEXP_PORT = true at DUAL_CLK =
-- false only, and it says nothing about WHICH source the FK33 build should
-- use -- that build sets the generic false and puts x_exp in the descriptor,
-- and this row does not argue with it.  It establishes that the other branch
-- works, so turning it on later is a configuration change and not a rewrite.
--
-- TRACE is passed explicitly for the same reason as in the dual wrapper:
-- sim/regress.sh takes a test's data files from the string literals in the
-- testbench file itself, not from its dependency closure.

entity tb_matvec_fk33_desc_xexp is
end entity;

architecture sim of tb_matvec_fk33_desc_xexp is
begin
  inner : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", XEXP_PORT => true);
end architecture;
