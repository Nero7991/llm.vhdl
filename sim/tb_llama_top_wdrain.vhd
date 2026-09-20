-- sim/tb_llama_top_wdrain.vhd
-- THE INTEGRATION BENCH WITH UNIT A's DRAIN ON THE GROUP WRITE PORT.
--
-- TRACK WIDEDRAIN, lever L1 of docs/2026-09-20_d-side-vector-traffic.md.
-- This file contains NO checks, for the reason `sim/tb_llama_top_seq.vhd`
-- states: `sim/regress.sh` keys a test by NAME and cannot run one testbench
-- twice at two generic sets, so a configuration that has to be GATED needs
-- its own top level.  Every property, every fault counter and the PASS line
-- belong to `sim/tb_llama_top.vhd`.
--
-- WHAT IT CHANGES, AND IT IS EXACTLY ONE GENERIC.  `A_DRAIN_WIDE => true`
-- routes `ga_real`'s S_DRAIN through the region file's LANES-wide group write
-- port instead of its one-element write port.  Everything else -- shape,
-- weights, blocks, attention interval, latency sweep -- is
-- `sim/tb_llama_top_real.vhd`'s configuration character for character, so
-- this row and that row are a ONE-VARIABLE PAIR.  A comparison whose two ends
-- come from different configurations is the trap CLAUDE.md records under
-- "a control on the wrong axis reads as rigour"; the only way to avoid it
-- here was to copy the sibling's generic map rather than choose a new one.
--
-- THE LANDMARKS ARE NOT RE-DERIVED AND MUST NOT BE.  The four EXP_* values
-- below are `sim/tb_llama_top_real.vhd`'s, verbatim, MEASURED 2026-08-29 on
-- the NARROW drain at 35e0ed0 and unchanged since.  Re-measuring them from a
-- run of the wide arm would be a round trip against itself, which this
-- project has on record passing for a wrong-but-consistent implementation
-- (the `m7 mutant`).  The wide drain must REPRODUCE them.  That is the value
-- gate: a drain that wrote the right elements to the wrong addresses, or that
-- dropped the final partial group, or that masked one lane too many, moves
-- `hash(R_X)` and this row fails.
--
-- WHY THAT IS AN INDEPENDENT ORACLE AND NOT A LANDMARK COMPARISON.  A
-- landmark is a change detector; on its own it says only that the numbers are
-- what they were when a human last looked.  These four are stronger than
-- that because they were themselves cleared against an independent model:
-- `sim:seamgate_*` compares this family's seams bit for bit against
-- `tools/ref9b/`, and the narrow tree's EXP_X0/EXP_XSUM are the numbers that
-- comparison reports.  So a wide-drain run matching them has matched a Python
-- model transitively, at the element level, through a chain that was
-- established before this row existed.
--
-- THE CYCLE MEASUREMENT.  `tb_llama_top` prints `<n> cycles elapsed` per run
-- and per token.  Because this row and `tb_llama_top_real` differ in one
-- generic and nothing else, the DIFFERENCE between the two rows' cycle counts
-- is the drain saving, MEASURED in the integration top rather than in an
-- extracted copy of the state -- which is the one thing
-- `sim/tb_region_drain.vhd` could not do and listed as open.
--
-- MEASURED 2026-09-20, ghdl-mcode, this tree:
--   tb_llama_top_real   (A_DRAIN_WIDE false)   see docs/2026-09-20_d-side-
--   tb_llama_top_wdrain (A_DRAIN_WIDE true )   vector-traffic.md section 10
--
-- WHAT THIS ROW DOES NOT COVER, stated rather than implied.  `A_ROWS_IF` is
-- 4 here and cannot be anything else in `llama_top`: `A_NPORTS` is the
-- package constant 5 and `ga_real` maps `NPORTS_W => A_ROWS_IF`.  So
-- `A_DW_GRP` is 4, the wide path moves four rows per cycle rather than the
-- card's eight, and every A-job `dst_off` the scaled schedule emits (0, 64,
-- 128) is a multiple of 4 -- so THE MISALIGNED FALLBACK IS UNREACHABLE HERE,
-- at any shape this bench can elaborate.  The fallback is exercised at the
-- card's geometry by `sim/tb_region_drain.vhd` rows `misaligned_37` and
-- `misaligned_64`, where `A_DW_GRP` is LANES and the guard is the same
-- expression.  See the mutation table in the doc: `M_NOFALLBACK` is reported
-- as NOT BITING here, under its own name, with that row named as the guard
-- that does bite.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_wdrain is
end entity;

architecture tb of tb_llama_top_wdrain is
begin
  u : entity work.tb_llama_top
    generic map(
      BLOCKS      => 4,
      ATTN_INT    => 4,
      NRUNS       => 2,
      C_REAL      => true,
      ATTN_HD     => 16,
      NORM_REAL   => true,
      NORM_ANCHOR => false,
      W_IMAGE     => "llama_top_w_b4_pool.hex",
      -- THE ONE VARIABLE.
      A_DRAIN_WIDE => true,
      EXP_X0      => -16364,
      EXP_XSUM    => 91622,
      EXP_XALL    => 91622,
      EXP_STEPH   => 17333);
end architecture;
