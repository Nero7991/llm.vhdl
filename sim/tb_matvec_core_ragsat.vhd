-- sim/tb_matvec_core_ragsat.vhd
-- THE ARITHMETIC CORE AT A SHAPE THAT IS RAGGED *AND* SATURATING.
--
-- WHY THIS FILE EXISTS.  `sim/regress.sh` keys a test by NAME and cannot run
-- one testbench twice at two generic sets -- the same reason
-- `sim/tb_llama_top_seq.vhd` and `sim/tb_llama_top_normw.vhd` exist.  A second
-- stimulus that has to be GATED therefore needs its own top level.  Every
-- property, every fault counter and the PASS line belong to
-- `sim/tb_matvec_core.vhd`; this file pins one generic and nothing else.
--
-- WHAT IT ADDS OVER THE `tb_matvec_core` GATE ROW, which runs `sim/tr.txt`.
-- TRACK A-MUT measured, over 57 mutations of `rtl/matvec_core.vhd` and
-- `rtl/mv4i_arith_pkg.vhd`, that EIGHT of them are invisible to the committed
-- gate, because `sim/tr.txt` has K = 96 = 3*32 exactly, M = 8 = 2*4 exactly
-- and `SATEV 0`:
--
--   D1  D2  D18 B13   need a RAGGED shape  (the spec 6.2 column mask, the
--                     nb_r ceiling, the BFP emit mask)
--   D16 B10 R3  A5    need SATURATION      (sat32 at row end, sat16 on the
--                     emitted mantissa, the sat_event sticky, sat16's rail)
--
-- `D16` is the clamp that keeps a 48-bit accumulator inside an int32 output.
--
-- FOUR AND FOUR READS LIKE TWO NEW ROWS.  IT IS ONE.  `--trace t 6 1000 4 1`
-- is ragged in BOTH dimensions -- M = 6 is not a multiple of ROWS_IF = 4, so
-- PASSES 1 and 2 have a ragged BFP tile, and K = 1000 = 31*32 + 8 is not a
-- multiple of BLK = 32, so the last block carries 24 MASKED columns -- while
-- still reaching `SATEV 1`, because the adversarial mode needs only NB > 16 to
-- push the accumulator past 2^31 and NB = 32 here.
--
-- MEASURED 2026-08-29 (TRACK CDC-BENCH, `sim/mutate_matvec_core.sh` with
-- TRACES="A P S X"), all 57 mutations:
--
--     trace A alone kills 36 of 57      <- the committed gate row
--     trace P alone kills 40 of 57
--     trace S alone kills 30 of 57
--     trace X alone kills 34 of 57      <- THIS ROW
--     A union X            44 of 57
--     A union P union S    44 of 57     <- identical
--
-- So this ONE row reaches exactly what all three of A-MUT's traces reach
-- together, and it closes all eight blind spots. `A5` and `D16`, the two
-- saturation-rail mutations, go from surviving the gate to being killed by it.
--
-- IT MUST RUN ALONGSIDE THE PLAIN ROW, NEVER INSTEAD OF IT.  MEASURED: ten
-- mutations that `sim/tr.txt` kills SURVIVE this trace -- A1 A2 A3 B4 B7 D5
-- D11 D14 D17 R7.  The adversarial construction sets every weight to codebook
-- index 0, every scale to 32767 and every activation to -32768, so every
-- product in the array is the SAME NUMBER: a rounding-mode change is invisible
-- because everything is already at the rail, and a structural adder-tree
-- change is invisible by symmetry.  Saturation coverage and value diversity
-- are opposed, and no single trace supplies both.  A-MUT recorded this for
-- trace S; it is confirmed here for trace X.
--
-- THE VECTOR IS COMMITTED, as `sim/tr.txt` is, and for the same reason: the
-- generator is `ref/matvec_int4.c`, which regress.sh's vector machinery keys
-- by the file's own name, and there is no `ref/tr_ragsat.c`.  It is
--
--     cc -O2 -w -I ref -o mv4i ref/matvec_int4.c -lm
--     ./mv4i --trace sim/tr_ragsat.txt 6 1000 4 1
--
-- and `sim/mutate_matvec_core.sh` REGENERATES it on every run and refuses to
-- run if the committed file differs, exactly as it already does for
-- `sim/tr.txt`.  A golden nothing regenerates is a golden anything can
-- replace in silence.
--
-- Teeth: sim/mutate_matvec_core.sh, the X column.
library ieee; use ieee.std_logic_1164.all;

entity tb_matvec_core_ragsat is
end entity;

architecture tb of tb_matvec_core_ragsat is
begin
  -- RI and STALL are the committed gate row's own values, so the two rows
  -- differ in exactly ONE thing: the trace.
  u : entity work.tb_matvec_core
    generic map(TRACE => "tr_ragsat.txt", RI => 4, STALL => 0);
end architecture;
