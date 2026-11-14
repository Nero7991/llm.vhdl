-- sim/tb_mv4i_tiled_hbmnr.vhd -- sim/tb_mv4i_tiled.vhd with HOLD_OWED = true: the bursts
-- the new DUTs' memories owe at job 14's mid-job reset (the memories are not reset with A,
-- as the card's HBM is not) arrive only after job 15 has started (a450 Task 7b fix round 1).
-- A separate gate row, so the regression runs both timings.
entity tb_mv4i_tiled_hbmnr is
end entity;

architecture sim of tb_mv4i_tiled_hbmnr is
begin
  b : entity work.tb_mv4i_tiled generic map(HOLD_OWED => true);
end architecture;
