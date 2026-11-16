-- sim/tb_matvec_fk33_desc_tiled.vhd -- sim/tb_matvec_fk33_desc.vhd with the a450 tiled
-- subsystem A behind the descriptor plane (matvec_int4_desc_axi A_TILED = true,
-- A_CLK_SPLIT = true, the tiles and the A masters on mclk).  A thin wrapper, as
-- tb_matvec_fk33_desc_dual and _xexp are: regress keys a row by bench name and cannot run
-- one bench twice.  The whole 22-case matrix, the element-exact comparison against
-- ref/matvec_int4.c from the real .mv4i bytes, the register reads (BEATS = tiles * nb,
-- Y_EXP, the stale-done window) and the UTIL job-cycle counter run through the tiled
-- array.  Under SPLIT the per-port beat counters are not built (UTIL_SEL[31]); the job-cycle
-- counter is, on the core clock (a450 final review I1).
-- The trace is mv_fk33_tr.txt, the same file the other three rows read.
entity tb_matvec_fk33_desc_tiled is
end entity;

architecture sim of tb_matvec_fk33_desc_tiled is
begin
  b : entity work.tb_matvec_fk33_desc
    generic map(TRACE => "mv_fk33_tr.txt", DUAL => true, TILED => true, SPLIT => true);
end architecture;
