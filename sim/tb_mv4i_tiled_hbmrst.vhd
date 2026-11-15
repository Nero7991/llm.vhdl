-- sim/tb_mv4i_tiled_hbmrst.vhd -- sim/tb_mv4i_tiled.vhd with HBM_RST = true: job 14's
-- mid-job reset is also an HBM AXI port reset (the new DUTs' memories drop every burst
-- they owe, and hbm_aresetn goes low with rst), and job 15 must complete and match the
-- old array (a450 Task 8, carry C1).  Jobs 14 and 15 only.  A separate gate row.
entity tb_mv4i_tiled_hbmrst is
end entity;

architecture sim of tb_mv4i_tiled_hbmrst is
begin
  b : entity work.tb_mv4i_tiled generic map(HBM_RST => true);
end architecture;
