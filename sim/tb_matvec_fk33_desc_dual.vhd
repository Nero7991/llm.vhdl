-- sim/tb_matvec_fk33_desc_dual.vhd -- subsystem A's descriptor control plane
-- with the AXI side on its own faster clock, as a GATE ROW rather than a
-- manual run.
--
-- WHY IT IS A SEPARATE FILE AND NOT A SECOND SET OF ARGUMENTS.  sim/regress.sh
-- keys a test by NAME and cannot run one testbench twice, which is stated in
-- as many words next to sim:tb_matvec_fk33_desc's own argument row.  So the
-- only way to gate a second configuration of that bench is a second entity,
-- and the cheapest honest second entity is a wrapper that instantiates the
-- first one with the generic set.  Nothing is duplicated: the 22-case
-- mutation matrix, the legal-shape sweep and the bit-exact comparison against
-- ref/matvec_int4.c all live in sim/tb_matvec_fk33_desc.vhd and all run here.
--
-- WHY IT IS WORTH A ROW.  DUAL_CLK = true is what the FK33 build instantiates
-- (hw/fk33/rtl/fk33_engine.vhd:1171), and it is not a small switch: it selects
-- axi_rd_port's `g_dc` generate, which replaces stream_fifo with async_fifo
-- and puts a toggle synchroniser on `start` and a level synchroniser on `run`.
-- When TRACK A-CTRL first built that path its absence broke 17 of 22 cases.
-- Until this file existed, the ONLY thing standing between that defect class
-- and the gate was somebody remembering to type -gDUAL=true, and row N8 of
-- docs/WORKLOG.md is the record that nobody had.
--
-- WHAT IT DOES NOT COVER.  The AXI clock is 1.67x the core clock and nothing
-- else; there is no ratio sweep here, and an RTL simulator samples atomically,
-- so a synchroniser cut down to one flop or to none still crosses cleanly.
-- That resolution floor is measured, not guessed -- five of the twenty rows in
-- sim/mutate_axi_rd_port_dual.sh survive for exactly this reason, and
-- sim/cdc_teeth.sh (report_cdc) is the flow that reaches them.  Read the three
-- together; each alone is a misleading picture.
--
-- TRACE is passed explicitly, and it has to be: sim/regress.sh discovers a
-- test's data files from the STRING LITERALS IN THE TESTBENCH FILE ITSELF
-- (files[tb][3]), not from its dependency closure, so a wrapper that inherited
-- the default would be run with no vector generated and would fail on "cannot
-- open mv_fk33_tr.txt".

entity tb_matvec_fk33_desc_dual is
end entity;

architecture sim of tb_matvec_fk33_desc_dual is
begin
  inner : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", DUAL => true);
end architecture;
