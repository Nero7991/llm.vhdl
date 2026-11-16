-- sim/tb_embed_gather_27b.vhd -- gate row: embed_gather at the 27B geometry (K 5120), plan Task 3.
entity tb_embed_gather_27b is
end entity;
architecture sim of tb_embed_gather_27b is
begin
  tc : entity work.embed_gather_tc
    generic map(N_EMBD => 5120, VEC => "embed_gather_k5120_vec.txt", TB_NAME => "tb_embed_gather_27b");
end architecture;
