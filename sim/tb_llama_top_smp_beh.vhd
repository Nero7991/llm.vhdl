-- sim/tb_llama_top_smp_beh.vhd
-- THE LOGITS EGRESS SEAM AT THE CONFIGURATION THAT HAS A VALUE ORACLE.
--
-- WHY THIS FILE EXISTS AND WHY IT CONTAINS NO CHECKS.  `sim/regress.sh` keys
-- a test by NAME and cannot run one testbench twice at two generic sets, so a
-- configuration that has to be GATED needs its own top level.  The same
-- reason `sim/tb_llama_top_seq.vhd` and `sim/tb_llama_top_real.vhd` exist.
-- Every property belongs to `sim/tb_llama_top_smp.vhd`; this file pins one
-- generic.  Duplicating a checker here would create a second copy that
-- nothing compares against the first.
--
-- WHAT THIS CONFIGURATION ADDS OVER THE DEFAULT ROW.  The default row runs
-- the REAL `matvec_int4` in raw out_mode, where the streamed logits have no
-- independent arithmetic oracle at this level and the value check is a route
-- comparison against the same job written to a region.  This row runs the
-- BEHAVIOURAL A, whose output is a published closed form, so the bench
-- recomputes every logit from the region contents it wrote and checks the
-- value, the vocabulary index and the argmax against numbers it derived
-- without asking the DUT.  The two rows check DISJOINT things and neither
-- replaces the other.
library ieee; use ieee.std_logic_1164.all;

entity tb_llama_top_smp_beh is
end entity;

architecture tb of tb_llama_top_smp_beh is
begin
  u : entity work.tb_llama_top_smp
    generic map(A_BEHAV => true);
end architecture;
